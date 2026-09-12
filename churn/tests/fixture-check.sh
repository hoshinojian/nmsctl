#!/bin/bash
# fixture 干跑静态验证（不触任何 DO/NMS API / ssh）：
#   1. bash -n 全部脚本；python3 -m py_compile 全部 python
#   2. 生成假 topology（9 第一跳/深度 2-3/每 fh 出度 3）
#   3. r-select.py 五场景选取断言（目标画像正确性）
#   4. DRY_RUN=1 全脚本走通（选取+落盘 targets.json+verdict，零网络调用）
# 注入链路自证：本脚本自造假运行时目录（占位 env.local）并 export SOAK_ENV——
# 占位值（203.0.113.0/24 文档段、零密码）不可能误触任何真实资源。
# 用法: bash scripts/soak/churn/tests/fixture-check.sh
set -euo pipefail
SOAK_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # scripts/soak
T="$SOAK_HOME/churn/tests"
FIX="$T/fixtures/topology-fixture.json"
FAILS=0
say()  { echo "[fixture-check] $*"; }
bad()  { say "FAIL: $*"; FAILS=$((FAILS+1)); }

say "0) 构造假运行时目录（占位 env.local）并注入 SOAK_ENV——验证 source 注入链路"
FAKE_RT="$(mktemp -d)"
trap 'rm -rf "$FAKE_RT"' EXIT
cat > "$FAKE_RT/env.local" <<'EOF'
NODE_PASS='<fixture-check-placeholder>'
EGRES_EXPECT='203.0.113.1'
OLD_NMS_IP='203.0.113.2'
FW_SOAK_NMS_ID='00000000-0000-0000-0000-000000000000'
NMS_ACCOUNT='dryrun-placeholder'
SOAK_BATCHES='sgp1 dryrun-placeholder 64 s-1vcpu-1gb'
EOF
export SOAK_ENV="$FAKE_RT"

say "1) 语法静态检查"
for f in lib/env.sh churn/r-lib.sh churn/run-r-wave.sh \
         churn/r1-revive-deep.sh churn/r2-batch8.sh churn/r3-parent-removal.sh \
         churn/r4-negative-guards.sh churn/r5-firsthop-revive.sh \
         rebuild/run-benchmark.sh rebuild/s0-baseline.sh rebuild/s1-teardown.sh \
         rebuild/s2-nms.sh rebuild/s2-repair.sh rebuild/s3-nodes.sh rebuild/s4-import.sh \
         rebuild/s5-onboard.sh rebuild/s6-verify.sh rebuild/nms-user-data6-ascii.sh \
         tools/heal-tree-r3.sh tools/heal-double-parent.sh tools/revive-one.sh \
         churn/tests/fixture-check.sh; do
  bash -n "$SOAK_HOME/$f" || bad "bash -n $f"
done
python3 -m py_compile "$SOAK_HOME/churn/r-select.py" "$SOAK_HOME/observe/witness.py" \
  "$SOAK_HOME/observe/g5-tree.py" "$T/make-fixture.py" || bad "py_compile"

say "2) 生成 fixture"
python3 "$T/make-fixture.py" "$FIX"

say "3) r-select 五场景选取断言"
check() { # check <scenario> <python断言表达式（变量 t=输出对象）>
  local s=$1 expr=$2 out
  out=$(python3 "$SOAK_HOME/churn/r-select.py" "$s" "$FIX") || { bad "r-select $s 退出非零"; return; }
  OUT="$out" python3 -c "
import json, os, sys
t = json.loads(os.environ['OUT'])
$expr" || bad "r-select $s 断言: $expr（输出=$out）"
  say "  $s -> $out"
}
check r1 "assert t['target']=='d3-01' and t['depth']==3 and t['fallback_used'] is False, t"
check r2 "
assert len(t['targets'])==8 and len(t['parents'])>=2, t
assert t['preferred_region_hits']==t['targets'], t        # 优先区(syd1/atl1/fra1)候选充足时命中 8/8
assert all(t['regions'][i] in ('syd1','atl1','fra1') for i in t['targets']), t"
check r3 "
assert t['depth']==2 and t['children_count']==3, t                 # 子女最多的深度 2 节点
assert t['target']=='d2-09', t                                     # 3 子并列取 id 序最大
assert len(t['descendants'])==3 and all(d.startswith('d3-') for d in t['descendants']), t"
check r4 "
assert t['provision_target']=='d3-01' and t['flip_target']=='d3-02', t
assert t['guard_live_target']=='fh-01' and len({t['provision_target'],t['flip_target'],t['guard_live_target']})==3, t"
check r5 "
assert t['target']=='fh-09' and t['domain']==0 and t['out_degree']==3, t
assert t['children']==['d2-24','d2-25','d2-26'], t
assert t['descendants']==t['children'], t                          # fixture 中 d2-24..26 为叶子"

say "3b) g5-tree.py 不变量对 fixture 自洽（64 台/9 第一跳/出度 3 应全绿）"
mkdir -p "$T/dryrun"
python3 "$SOAK_HOME/observe/g5-tree.py" "$FIX" "$T/dryrun/g5-fixture-analysis.json" \
  --nodes 64 --first-hop 9 --child-budget 3 > /dev/null || bad "g5-tree 对 fixture 报违规"

say "4) DRY_RUN=1 五脚本走通（零网络调用；证据根切至 churn/tests/dryrun/）"
rm -rf "$T/dryrun/evidence"
for s in r1-revive-deep r2-batch8 r3-parent-removal r4-negative-guards r5-firsthop-revive; do
  SC="${s%%-*}"; SC="$(echo "$SC" | tr '[:lower:]' '[:upper:]')"
  if DRY_RUN=1 R_TOPO_FILE="$FIX" bash "$SOAK_HOME/churn/$s.sh" > "$T/dryrun-$s.log" 2>&1; then
    grep -q '"verdict": "pass"' "$T/dryrun/evidence/$SC/verdict.json" \
      || bad "DRY_RUN $s verdict 非 pass"
    [ -s "$T/dryrun/evidence/$SC/targets.json" ] || bad "DRY_RUN $s targets.json 缺失"
    if grep -qE 'ssh|curl' "$T/dryrun-$s.log"; then bad "DRY_RUN $s 疑似发生网络调用"; fi
    say "  $s DRY_RUN OK"
  else
    bad "DRY_RUN $s 退出非零（见 $T/dryrun-$s.log 尾部: $(tail -3 "$T/dryrun-$s.log")）"
  fi
done

say "5) 干跑产物清理提示：churn/tests/dryrun/ 与 churn/tests/dryrun-*.log 为验证产物，可删（已 gitignore）"
if [ "$FAILS" = "0" ]; then say "ALL PASS"; else say "$FAILS 项失败"; exit 1; fi
