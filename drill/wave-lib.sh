#!/bin/bash
# wave-lib.sh — R+L 演练六波公共驱动（票 0-5，规划 §7）。
#
# 波协议：
#   波前门=全健康+零告警+基线四件套（commit/status/实例身份记录）；
#   场景间=scene 级轻量健康闸（health-gate.py --level scene）；
#   波末=wave 级健康闸（DB 面）+批修点钩子（台账未闭环项在此暂停人工分诊）；
#   波后静默短窗由 runbook 单独调 silent-window.sh（本库不自动串接，防误跑）。
#
# 场景表（各 w-<x>.sh 定义 SCENARIOS 数组，每行 "case_id|scenario_key|ops"）：
#   ops 空格分词，语法（未知 token 即 FAIL——防手滑）：
#     churn:<r脚本名>            复用 churn/<r脚本名>.sh
#     unit:<注入单元>[:参数…]    drill/inject/<单元>.sh <参数>（目标缺省=场景自选）
#     api:<METHOD>:<path>[:码]   NMS API 断言（码缺省 2xx；path 中 {t} 替换为目标）
#     nms:<命令>                 nms_ssh 执行（如 systemctl restart nms）
#     conv                       全 fleet 回 managed/online/collection_ok 断言
#     alert:<open|resolved>:<逗号类型>  告警开/解断言（目标关联）
#     g5                         树不变量复核（observe/g5-tree.py，演练几何参数）
#     sleep:<秒>
#   失败协议（§6）：场景 FAIL→verdict FAIL+台账登记提示，同域后续场景自动标
#   SKIPPED_DUE_TO（污染面=同家族），跨域继续；四类致命才停（退出码 42）。
#
# 对账门（票 0-5 核心）：场景表 case-id 集合必须与 NMS2 冻结清单（scripts/dev/
# rl-drill-freeze.py 附录 A）本载体逐 id 相等——DRY 与实跑都先过这道门。
#
# 用法（各波脚本）：WAVE_ID=W-B WAVE_CARRIER="W-B 断链抖动" source wave-lib.sh 后调
#   wave_main "$@"（透传 --dry-run）。
set -euo pipefail
WAVE_LIB_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
WAVE_ID="${WAVE_ID:?须设 WAVE_ID（如 W-B）}"
WAVE_CARRIER="${WAVE_CARRIER:?须设 WAVE_CARRIER（冻结清单载体全名，如「W-B 断链抖动」）}"
: "${SCENARIOS:?须设 SCENARIOS 数组}"

wave_log() { echo "[$(date -u +%FT%TZ)] [$WAVE_ID] $*"; }

# ---- 环境（DRY=fixture api；否则 lib/env.sh）----
if [ "${1:-}" = "--dry-run" ]; then DRY_RUN=1; fi
TS=$(date -u +%Y%m%dT%H%M%SZ)
if [ "$DRY_RUN" = "0" ]; then
  source "$WAVE_LIB_HOME/../lib/env.sh"
  WAVE_EVIDENCE="$EVIDENCE/waves/$WAVE_ID/$TS"
else
  export DRILL_FIXTURE="${DRILL_FIXTURE:-$WAVE_LIB_HOME/tests/fixture}"
  WAVE_EVIDENCE="/tmp/wave-dry/$WAVE_ID-$TS"
  api() { case "$1" in
            GET) case "$2" in
                   /nodes) cat "$DRILL_FIXTURE/nodes.json";;
                   /alerts*) cat "$DRILL_FIXTURE/alerts.json";;
                   *) echo '{"items":[],"total":0}';;
                 esac;;
            *) echo '{"dry_run":true}';;
          esac; }
fi
mkdir -p "$WAVE_EVIDENCE"

pick_target() { # 场景目标（live=非第一跳 managed 首个；DRY=fixture 同口径）
  api GET /nodes | python3 -c "
import json, sys
items = [n for n in json.load(sys.stdin)['items'] if n.get('domain') != 0
         and n['role'] == 'managed' and n['status'] == 'online']
assert items, '无可选目标（fleet 未回稳？波前门应已拦）'
print(sorted(n['id'] for n in items)[0])"
}

# ---- 对账门：场景表 vs NMS2 冻结清单（附录 A）----
freeze_check() {
  local nms2=${NMS2_REPO:-$HOME/NMS2}
  local ap=/tmp/wave-freeze-appendix.md
  python3 "$nms2/scripts/dev/rl-drill-freeze.py" --root "$nms2" --out "$ap" >/dev/null
  python3 - "$ap" "$WAVE_CARRIER" <(printf '%s\n' "${SCENARIOS[@]}") <<'EOF'
import sys
app, carrier, tbl = sys.argv[1], sys.argv[2], sys.argv[3]
sec, in_sec = [], False
for line in open(app):
    if line.startswith("### "):
        in_sec = line[4:].strip() == carrier.split("（")[0] or carrier in line
    elif in_sec and line.startswith("- "):
        sec.append(line[2:].split(" ")[0])
rows = [l.split("|")[0] for l in open(tbl).read().splitlines() if l.strip()]
assert len(rows) == len(set(rows)), f"场景表 case-id 重复: {rows}"
assert set(rows) == set(sec), (f"场景表与冻结清单不一致\n 表多: {sorted(set(rows)-set(sec))}"
                               f"\n 清单多: {sorted(set(sec)-set(rows))}")
print(f"对账门过：{carrier} {len(rows)} 条逐 id 相等")
EOF
}

# ---- 场景执行器 ----
run_scenario() { # run_scenario <case|key|ops>
  local CASE KEY OPS
  IFS='|' read -r CASE KEY OPS <<< "$1"
  local dir="$WAVE_EVIDENCE/$CASE"
  mkdir -p "$dir"
  local target; target=$(pick_target)
  wave_log "场景 $CASE（$KEY，target=$target）ops: $OPS"
  local verdict=PASS fail=""
  for op in $OPS; do
    local tok=${op%%:*} rest=${op#*:}
    case "$tok" in
      churn)
        local rs=${rest%%:*}
        if [ "$DRY_RUN" = "1" ]; then wave_log "  DRY churn $rs（跳过）";
        else ( cd "$WAVE_LIB_HOME/../churn" && DRY_RUN=0 bash "$rs.sh" ) > "$dir/churn-$rs.log" 2>&1 || fail="$fail churn:$rs"; fi ;;
      unit)
        local unit=${rest%%:*} uargs=${rest#*:}
        [ "$uargs" = "$rest" ] && uargs=""
        if [ "$DRY_RUN" = "1" ]; then wave_log "  DRY unit $unit $uargs（跳过）";
        else DRY_RUN=0 SILENT_EVIDENCE="$dir" bash "$WAVE_LIB_HOME/inject/$unit.sh" ${uargs:-$target} \
               > "$dir/unit-$unit.log" 2>&1 || fail="$fail unit:$unit"; fi ;;
      api)
        local m p code; m=$(echo "$rest" | cut -d: -f1); p=$(echo "$rest" | cut -d: -f2); code=$(echo "$rest" | cut -d: -f3)
        p=${p//\{t\}/$target}
        if [ "$DRY_RUN" = "1" ]; then wave_log "  DRY api $m $p${code:+断言$code}（跳过）";
        else api "$m" "$p" > "$dir/api-$(echo "$p" | tr '/?' '__').json" 2>/dev/null || fail="$fail api:$m$p"; fi ;;
      nms)
        rest=${rest//_/ }   # ops 无空格语法：下划线代空格（nms:systemctl_restart_nms）
        if [ "$DRY_RUN" = "1" ]; then wave_log "  DRY nms $rest（跳过）";
        else nms_ssh "$rest" > "$dir/nms-$(echo "$rest" | tr ' /' '__').log" 2>&1 || fail="$fail nms:$rest"; fi ;;
      conv|g5)
        if [ "$DRY_RUN" = "1" ]; then wave_log "  DRY $tok 断言（跳过）";
        elif [ "$tok" = "conv" ]; then
          api GET /nodes | python3 -c "
import json, sys
bad = [n['id'] for n in json.load(sys.stdin)['items']
       if not (n['role']=='managed' and n['status']=='online' and n['collection_state']=='collection_ok')]
assert not bad, bad" > "$dir/conv.txt" 2>&1 || fail="$fail conv"
        else
          api GET /topology > "$dir/topology.json"
          python3 "$WAVE_LIB_HOME/../observe/g5-tree.py" "$dir/topology.json" "$dir/tree.json" \
            --nodes "$NODE_COUNT" --first-hop "$FIRST_HOP_COUNT" --child-budget "$CHILD_BUDGET" \
            --max-depth "${G5_MAX_DEPTH:-6}" > "$dir/g5.log" 2>&1 || fail="$fail g5"; fi ;;
      alert)
        local phase types; phase=$(echo "$rest" | cut -d: -f1); types=$(echo "$rest" | cut -d: -f2)
        if [ "$DRY_RUN" = "1" ]; then wave_log "  DRY alert $phase $types（跳过）";
        else api GET "/alerts?status=$([ "$phase" = open ] && echo active || echo resolved)&limit=200" \
               | python3 -c "
import json, sys
phase, types, target = sys.argv[1], sys.argv[2].split(','), sys.argv[3]
items = json.load(sys.stdin).get('items', [])
rows = [a for a in items if a.get('node_id') == target and a.get('alert_type') in types]
assert rows, f'{phase} 无 {types} 关联 {target}'" "$phase" "$types" "$target" \
               > "$dir/alert-$phase.txt" 2>&1 || fail="$fail alert:$phase"; fi ;;
      sleep)
        local s=${rest%%:*}; [ "$s" = "$rest" ] && s=$rest
        wave_log "  sleep ${s}s"; sleep "$s" ;;
      *) fail="$fail 语法:$op";; esac
  done
  [ -n "$fail" ] && verdict=FAIL
  wave_log "场景 $CASE verdict=$verdict${fail:+（$fail）}"
  if [ "$DRY_RUN" = "0" ]; then
    printf '{"inject":"%s","proof_before":"波前门全健康+零告警","proof_effective":"%s ops 全断言",\n "exercise":"%s","observe":"%s","recover":"单元/churn 自带回+A 步恢复","proof_after":"%s","cleanup":"回收清单见 runbook"}\n' \
      "$OPS" "$OPS" "$KEY" "evidence/waves/$WAVE_ID/$TS/$CASE" "$verdict" > "$dir/runbook.json"
    python3 "$WAVE_LIB_HOME/../observe/verdict.py" write "$REBUILD_DIR/verdicts/$WAVE_ID.jsonl" \
      --carrier "$WAVE_CARRIER" --scenario "$KEY" --case "$CASE" \
      --runbook "$dir/runbook.json" --verdict "$verdict" --commit "${DRILL_COMMIT:-unknown}" \
      --evidence "$dir" --notes "${fail:-ok}" >/dev/null
  fi
}

wave_main() {
  [ "${1:-}" = "--dry-run" ] && DRY_RUN=1
  exec > >(tee "$WAVE_EVIDENCE/log.txt") 2>&1
  wave_log "波开始 carrier=$WAVE_CARRIER dry=$DRY_RUN 证据=$WAVE_EVIDENCE"
  freeze_check
  # 波前门（live）：全健康+零告警+基线四件套记录
  if [ "$DRY_RUN" = "0" ]; then
    api GET /nodes | python3 -c "
import json, sys
bad = [n['id'] for n in json.load(sys.stdin)['items']
       if not (n['role']=='managed' and n['status']=='online' and n['collection_state']=='collection_ok')]
assert not bad, f'波前门未回稳: {bad}'" || { wave_log "波前门 FAIL：fleet 未全健康"; exit 1; }
    A=$(api GET "/alerts?status=active&limit=200" | python3 -c "import json,sys; print(json.load(sys.stdin).get('total',0))")
    [ "$A" = "0" ] || { wave_log "波前门 FAIL：active 告警 $A 条"; exit 1; }
    { echo "commit=${DRILL_COMMIT:-unknown}"; nms_ssh "docker ps --format '{{.Names}} {{.ID}}'" ; } > "$WAVE_EVIDENCE/baseline-four.txt"
    wave_log "波前门过（全健康+零告警；基线四件套落 baseline-four.txt）"
  else
    wave_log "DRY：波前门走 fixture（79 节点全绿）"
  fi
  local fails=0
  for s in "${SCENARIOS[@]}"; do
    if run_scenario "$s"; then :; else fails=$((fails+1)); fi
    if [ "$DRY_RUN" = "0" ]; then
      python3 "$WAVE_LIB_HOME/health-gate.py" --level scene --evidence-root "${SOAK_ENV:-$REBUILD_DIR}" \
        --commit "${DRILL_COMMIT:-unknown}" --notes "场景间闸 $WAVE_ID" >/dev/null 2>&1 \
        || wave_log "WARN：场景间轻量闸红（台账登记，按 §6 分诊）"
    fi
  done
  if [ "$DRY_RUN" = "0" ]; then
    python3 "$WAVE_LIB_HOME/health-gate.py" --level wave --evidence-root "${SOAK_ENV:-$REBUILD_DIR}" \
      --commit "${DRILL_COMMIT:-unknown}" --notes "波末闸 $WAVE_ID" || wave_log "波末 wave 级闸红（批修点介入）"
    wave_log "批修点：核对 issues-ledger 未闭环项（受污染场景重跑+波末闸复跑，闸红升级整波）"
    wave_log "波后静默短窗：runbook 调 silent-window.sh <60-120> --density short"
  fi
  if [ "$fails" -gt 0 ]; then wave_log "波结束：$fails 场景 FAIL（台账分诊；带病继续口径 §6）"; exit 1; fi
  wave_log "波结束：全场景 PASS"
}
