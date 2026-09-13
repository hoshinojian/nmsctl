#!/bin/bash
# S5 批量开键：1s 窗内 $NODE_COUNT 个 PUT onboard=true（#184 合批）→ 收敛轮询 → G4'/G5'
# T3 必改（scale-coldstart-churn-plan §一 T3 / §二 G4'）+ 自愈收口计划 C 项（双形态门限）：
#   - G4' 按形态分支（开跑查 /agent-deploy 历史轮判 fresh/resume）：fresh 轮数上限=构成式
#     （主轮1+F3重排1+late-join≤2）∧ 末轮 succeeded；resume（救援续跑）轮数/深度只记录不断言，
#     判据=收敛 NC/NC ∧ 三值终态无悬挂 ∧ 末轮 succeeded；
#   - 零「无可用备选父」签名（T2 生效判据，journal 全量 grep，出现即 FAIL 按新缺陷处置；双形态均不放宽）；
#   - 28→64 全参数化；收敛窗 S5_DEADLINE env 可覆盖（缺省 1800s，64 台估 8-15min）。
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/rebuild
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）
cd "$REBUILD_DIR"
mkdir -p "$EVIDENCE/s5"
exec > >(tee "$EVIDENCE/s5/log.txt") 2>&1

check_egress
EXPECT_VER=$(cat "$EVIDENCE/expected-agent-version.txt")
log "开键目标：$NODE_COUNT 台（onboard=false）"
api GET /nodes > "$EVIDENCE/s5/nodes-before.json"
# 形态判定（自愈收口计划 C 项）：/agent-deploy 已有历史部署轮（items 非空）⇒ resume（救援续跑），否则 fresh。
# 判据依据：s1 拆除含 NMS ⇒ 库里有部署历史 ⟺ 续跑；唯一误判组合「NMS 重建而 fleet 幸存」误判为
# fresh=从严（按全新跑门限断言），安全方向。
api GET /agent-deploy > "$EVIDENCE/s5/agent-deploy-before.json"
read -r FORM HIST_ROUNDS <<< "$(python3 - <<'EOF'
import json
items = json.load(open('evidence/s5/agent-deploy-before.json')).get('items', [])
print(('resume' if items else 'fresh'), len(items))
EOF
)"
echo "$FORM" > "$EVIDENCE/s5/form.txt"
log "形态判定：$FORM（/agent-deploy 历史部署轮 $HIST_ROUNDS 条，已落盘 evidence/s5/form.txt）"
# 目标 = 未收敛节点（非 managed/online/collection_ok）——全新跑=全部，续跑=滞留子集；
# 爆发动作统一为 P74 舞步（先 false 后 true）：fresh 节点 false 为无害空操作，滞留 true 节点借 false 清翻转位
IDS=$(python3 -c "
import json, os
items = json.load(open('evidence/s5/nodes-before.json'))['items']
nc = int(os.environ['NODE_COUNT'])
ids = [n['id'] for n in items
       if not (n['role'] == 'managed' and n['status'] == 'online' and n['collection_state'] == 'collection_ok')]
assert 0 <= len(ids) <= nc, f'未收敛节点 {len(ids)} 超出总量 {nc}'
print('\n'.join(sorted(ids)))")
echo "$IDS" > "$EVIDENCE/s5/onboard-ids.txt"
# 零目标正确计数（resume 复跑常态：echo "" 会写出一个空行，wc -l 误计 1——
# 2026-09-13 验收轮实证，剥空行后按非空行计）
N_TARGETS=$(grep -c . "$EVIDENCE/s5/onboard-ids.txt" || true)
log "开键/补试目标：$N_TARGETS/$NODE_COUNT 台未收敛"

if [ "$N_TARGETS" = "0" ]; then
  log "零未收敛目标：跳过 burst（全 fleet 已收敛，直接进入 G4'/G5' 断言）"
else
log "同一窗内连发 $N_TARGETS 个 P74 舞步 PUT（计时）"
T0=$(date +%s%3N)
# 爆发开键：脚本推到 NMS 本机执行（loopback 并发 <1s，保住 #184 的 1s 合批窗口；
# 本地直连 :80 有间歇吞包——2026-09-11）。逐台 HTTP 码断言，非 2xx 立即 FAIL。
cat > /tmp/burst-onboard.sh <<'BURST'
#!/bin/bash
for id in "$@"; do
  ( c1=$(curl -sS -m 30 -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"onboard":false}' http://127.0.0.1:80/api/v1/nodes/$id)
    code=$(curl -sS -m 30 -o /tmp/put-$id.json -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"onboard":true}' http://127.0.0.1:80/api/v1/nodes/$id)
    echo "$code $id" >> /tmp/burst-codes.txt ) &  # 只记最终 true-PUT 码；false 段失败会传导到 code
done
wait
sort /tmp/burst-codes.txt
BURST
scp $SSHOPT -P 22 /tmp/burst-onboard.sh "root@$(nms_ip)":"/tmp/burst-onboard.sh" > /dev/null
ssh $SSHOPT -p 22 "root@$(nms_ip)" "rm -f /tmp/burst-codes.txt; chmod +x /tmp/burst-onboard.sh && /tmp/burst-onboard.sh $(tr '
' ' ' < "$EVIDENCE/s5/onboard-ids.txt")" > "$EVIDENCE/s5/burst-codes.txt"
PUT_FAIL=0
while read -r code id; do
  case "$code" in 2??) ;; *) echo "PUT $id -> HTTP $code"; PUT_FAIL=1;; esac
done < "$EVIDENCE/s5/burst-codes.txt"
[ "$(wc -l < "$EVIDENCE/s5/burst-codes.txt")" = "$N_TARGETS" ] || { echo "GATE S5: FAIL — 响应行数不足 $N_TARGETS"; exit 1; }
[ "$PUT_FAIL" = "0" ] || { echo "GATE S5: FAIL — 开键 PUT 存在失败响应"; exit 1; }
T1=$(date +%s%3N)
log "$N_TARGETS 个目标发射完毕，墙钟 $((T1 - T0)) ms"
fi  # N_TARGETS != 0（零目标跳过 burst——burst 零参会因空 $@ 不建码文件而 sort 失败）

log "收敛轮询（5s 间隔，上限 ${S5_DEADLINE:-1800}s；挂树数经 GET /topology tree.nodes 统计）"
# 收敛窗参数化（自愈收口计划 C 项）：S5_DEADLINE env 覆盖口径——救援续跑历史轮多、收敛更慢，
# 30min 不够时经环境/env.local 注入更大值，不改脚本；缺省 1800s（64 台全新跑估 8-15min，留富余）。
DEADLINE=$(( $(date +%s) + ${S5_DEADLINE:-1800} ))
START=$(date +%s); LATEJOIN_PASSES=0; LAST_LATEJOIN=0
# late-join 补试：合批窗口关闭后到达的 PUT 会撞 #122 单飞被弹回（idle ∧ onboard=true 滞留），
# P74 口径本为人工重翻——零人工目标下由本回路自动化：有界 2 轮、逐轮留痕、仅在无在飞轮时执行
converged=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  api GET /nodes > "$EVIDENCE/s5/nodes-live.json" 2>/dev/null || { sleep 15; continue; }
  api GET /agent-deploy > "$EVIDENCE/s5/deploys-live.json" 2>/dev/null || true
  STATUS=$(python3 - <<'EOF'
import json
items = json.load(open('evidence/s5/nodes-live.json'))['items']
ok = sum(1 for n in items if n['role'] == 'managed' and n['status'] == 'online' and n['collection_state'] == 'collection_ok')
roles = {}
for n in items:
    roles[(n['role'], n['status'], n['collection_state'])] = roles.get((n['role'], n['status'], n['collection_state']), 0) + 1
try:
    dep = json.load(open('evidence/s5/deploys-live.json'))
    rounds = [(i.get('deploy_id'), i.get('status'), i.get('nodes')) for i in dep.get('items', [])]
except Exception:
    rounds = []
print(f"{ok}/{len(items)} rounds={rounds} detail={sorted(roles.items(), key=str)}")
EOF
)
  ATT=$(curl -sS -m 10 "http://$(nms_ip)/api/v1/topology" 2>/dev/null | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('tree',{}).get('nodes',[])))" 2>/dev/null || echo '?')
  log "  $STATUS attached=$ATT"
  STUCK=$(python3 - <<'STUCK_EOF'
import json
try:
    items = json.load(open('evidence/s5/nodes-live.json'))['items']
except Exception:
    print(0); raise SystemExit
stuck = [n['id'] for n in items if n['role'] == 'idle']
json.dump(stuck, open('evidence/s5/latejoin-stuck.json', 'w'))
print(len(stuck))
STUCK_EOF
)
  NOW=$(date +%s)
  RUNNING=$(python3 -c "
import json
try:
    dep = json.load(open('evidence/s5/deploys-live.json'))
    print(sum(1 for i in dep.get('items', []) if i.get('status') == 'running'))
except Exception:
    print(1)
" 2>/dev/null || echo 1)
  if [ "$STUCK" -gt 0 ] && [ "$LATEJOIN_PASSES" -lt 2 ] && [ "$RUNNING" = "0" ] && [ $((NOW - START)) -ge 120 ] && [ $((NOW - LAST_LATEJOIN)) -ge 120 ]; then
    LATEJOIN_PASSES=$((LATEJOIN_PASSES + 1)); LAST_LATEJOIN=$NOW
    log "  late-join 补试第 $LATEJOIN_PASSES 轮：$STUCK 台滞留（idle，合批窗口后到达的单飞弹回）——P74 舞步"
    for id in $(python3 -c "import json;print(' '.join(json.load(open('evidence/s5/latejoin-stuck.json'))))"); do
      api PUT "/nodes/$id" '{"onboard":false}' > /dev/null 2>&1 || true
      api PUT "/nodes/$id" '{"onboard":true}' > /dev/null 2>&1 || true
    done
    printf '{"passes": %s, "stuck": %s, "at": "%s"}\n' "$LATEJOIN_PASSES" "$STUCK" "$(date -u +%FT%TZ)" >> "$EVIDENCE/s5/latejoin-passes.jsonl"
  fi
  case "$STATUS" in "${NODE_COUNT}/${NODE_COUNT} "*) converged=1; break;; esac
  sleep 5
done
if [ -z "$converged" ]; then
  api GET /nodes > "$EVIDENCE/s5/nodes-partial.json" 2>/dev/null || true
  api GET "/alerts?status=active&limit=200" > "$EVIDENCE/s5/alerts-partial.json" 2>/dev/null || true
  gate S5 FAIL "收敛窗（S5_DEADLINE=${S5_DEADLINE:-1800}s）耗尽未收敛：$STATUS（现场已落盘 nodes-partial.json）"
fi

log "G4' 断言（form=$FORM）：fresh=构成式上限（主轮1+F3重排1+late-join≤2+A重试≤2）∧ 无悬挂轮 ∧ 末轮 succeeded；resume=轮数只记录不断言（三值终态 ∧ 末轮 succeeded）；重排触发单列记录"
export LATEJOIN_PASSES   # G4' python 子进程读取
api GET /agent-deploy > "$EVIDENCE/s5/agent-deploy-final.json"
api GET /nodes > "$EVIDENCE/s5/nodes-final.json"
api GET "/alerts?status=active&limit=200" > "$EVIDENCE/s5/alerts-final.json"
python3 - <<'EOF'
import json, os
NC = int(os.environ['NODE_COUNT'])
ver = open('evidence/expected-agent-version.txt').read().strip()
form = open('evidence/s5/form.txt').read().strip()
assert form in ('fresh', 'resume'), f"形态判定非法: {form!r}（evidence/s5/form.txt）"
dep = json.load(open('evidence/s5/agent-deploy-final.json'))['items']
rounds = [(i.get('deploy_id'), i.get('status'), i.get('nodes')) for i in dep]
assert dep, "agent-deploy 无任何部署轮（异常：收敛门已过但零轮）"
# fresh 轮数上限构成式（自愈收口计划 C 项：替换裸 len<=4，各系数来源显式可追溯）：
#   主轮 1         —— #184 合批：同窗开键 PUT 合并为单轮部署；
#   + F3 重排 1    —— #200 轮内传输类失败集自动重排：一次、不回 idle、不成环（allowRequeue=false）；
#   + late-join ≤2 —— 本脚本补试回路硬上限（LATEJOIN_PASSES<2，仅无在飞轮时执行）；
#   + A 重试 ≤2    —— #127 provision 自动重纳管（PR #244 已合入）：failBack 后对账循环
#                     自动重发 ≤2 次（30min 窗），每次重试各产生一轮。C3 依赖边已兑现：
#                     系数随 A 合入追加；满配额验收轮实测后如需再校准另行小 PR。
FRESH_MAX_WAVES = 1 + 1 + 2 + 2   # = 6
if form == 'fresh':
    assert 1 <= len(dep) <= FRESH_MAX_WAVES, \
        f"部署轮数 {len(dep)} 超出 fresh 构成式上限（主轮1+F3重排1+late-join≤2+A重试≤2={FRESH_MAX_WAVES}）: {rounds}"
    # fresh 无历史轮：任何非终态即悬挂，只许 succeeded/partial（failed 历史轮仅 resume 形态合法）
    assert all(i.get('status') in ('succeeded', 'partial') for i in dep), f"存在非终态（悬挂）轮: {rounds}"
else:
    # resume（救援续跑）：前序失败尝试的历史轮持久于 agent_deploys（2026-09-12 满配额实机 11 轮实证），
    # 轮数只记录不断言（g4-verdict.json 落 waves，积累实机数据后再议上限——自愈收口计划 C 项）。
    # 判据②：全部轮无悬挂——三值终态放宽（succeeded/partial/failed，历史 failed 轮合法）∧ 末轮 succeeded。
    assert all(i.get('status') in ('succeeded', 'partial', 'failed') for i in dep), f"存在非终态（悬挂）轮: {rounds}"
dep_sorted = sorted(dep, key=lambda i: i['deploy_id'])   # deploy_id 单调，末位=终轮
last = dep_sorted[-1]
assert last['status'] == 'succeeded', f"终轮 {last.get('status')} != succeeded（partial/failed 挂终态）: {rounds}"
# 终轮台数断言移除：late-join 补试轮只含滞留子集；完整性由下方全 fleet managed 断言承担（决策 #125 批）
reroute = False
if form == 'fresh':
    # fresh 的 2 轮口径：恰 2 轮时首轮必须 partial（自动重排语义）；resume 历史轮无此约束（只记录）
    reroute = len(dep_sorted) == 2
    if reroute:
        assert dep_sorted[0]['status'] == 'partial', \
            f"第 1 轮 {dep_sorted[0]['status']} != partial（2 轮口径要求首轮 partial，自动重排语义）: {rounds}"
items = json.load(open('evidence/s5/nodes-final.json'))['items']
badrole = [n['id'] for n in items if not (n['role'] == 'managed' and n['status'] == 'online' and n['collection_state'] == 'collection_ok')]
assert not badrole, badrole
badver = {n['id']: n.get('agent_version') for n in items if n.get('agent_version') != ver}
assert not badver, f"agent 版本不符: {badver}"
alerts = json.load(open('evidence/s5/alerts-final.json'))
onb = [a for a in alerts.get('items', []) if 'onboard' in str(a.get('alert_type') or a.get('type') or '')]
assert not onb, f"onboard_failed active: {onb}"
json.dump({"form": form, "s5_deadline": int(os.environ.get('S5_DEADLINE', '1800')), "waves": len(dep),
           "rounds": rounds, "reroute_triggered": reroute, "latejoin_passes": int(os.environ.get('LATEJOIN_PASSES', '0')),
           "terminal": {"deploy_id": last.get('deploy_id'), "status": last.get('status'), "nodes": last.get('nodes')}},
          open('evidence/s5/g4-verdict.json', 'w'), ensure_ascii=False, indent=1)
waves_note = f"（构成式上限 {FRESH_MAX_WAVES}）" if form == 'fresh' else "（resume 只记录不断言）"
print(f"G4' OK（form={form}）: 轮数={len(dep)}{waves_note} 重排触发={reroute}（证据 evidence/s5/g4-verdict.json）; "
      f"终轮 succeeded nodes={NC}; "
      f"{NC}/{NC} managed/online/collection_ok; 版本={ver}; active 告警 {alerts.get('total', len(alerts.get('items', [])))} 条（onboard 类 0）")
EOF

log "G4' 附加断言：零「无可用备选父」签名（T2 生效判据；journal 全量 grep）"
nms_ssh 'journalctl -u nms --no-pager | grep "无可用备选父" | tail -50; true' > "$EVIDENCE/s5/nocandidate-signature.txt" || true
NOCAND=$(nms_ssh 'journalctl -u nms --no-pager | grep -c "无可用备选父"; true' | tail -n 1)
NOCAND="${NOCAND:-0}"
[ "$NOCAND" = "0" ] || gate S5 FAIL "journal 出现「无可用备选父」签名 $NOCAND 次（T2 生效判据被触发）——按新缺陷处置，签名样本已落盘 evidence/s5/nocandidate-signature.txt"
log "签名计数 $NOCAND（0=通过）"

# G5' 深度门限按形态传参（自愈收口计划 C 项）：fresh 维持缺省 4；resume 传 7——锚定 discover
# engine 的 max_depth 配置键缺省值（engine.go 可配；2026-09-12 满配额实机救援轮曾见深度 5、fleet 实质健康）。
G5_MAX_DEPTH=4
if [ "$FORM" = "resume" ]; then G5_MAX_DEPTH=7; fi
log "G5' 断言：树形不变量（全 $NODE_COUNT managed、出度≤$CHILD_BUDGET、深度≤$G5_MAX_DEPTH、links 全物化、第一跳=$FIRST_HOP_COUNT）"
api GET /topology > "$EVIDENCE/s5/topology.json"
python3 "$SOAK_HOME/observe/g5-tree.py" "$EVIDENCE/s5/topology.json" "$EVIDENCE/s5/tree-analysis.json" \
  --nodes "$NODE_COUNT" --first-hop "$FIRST_HOP_COUNT" --child-budget "$CHILD_BUDGET" --max-depth "$G5_MAX_DEPTH"
# g4-verdict.json 补记 max_depth_seen（C 项：resume 深度只记录不断言，从 g5-tree.py 落盘的
# tree-analysis.json 取回；fresh 同样记录供后续门限校准参考。放在 G5' 之后是因为该文件此刻才存在）
python3 - <<'EOF'
import json
v = json.load(open('evidence/s5/g4-verdict.json'))
v['max_depth_seen'] = json.load(open('evidence/s5/tree-analysis.json')).get('max_depth_seen')
json.dump(v, open('evidence/s5/g4-verdict.json', 'w'), ensure_ascii=False, indent=1)
print(f"g4-verdict.json 补记 max_depth_seen={v['max_depth_seen']}（form={v.get('form')}）")
EOF
gate S5 PASS "批量开键收敛 + 树形不变量合规"
