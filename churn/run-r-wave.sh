#!/bin/bash
# R-wave 串行驱动器：r1→r2→r3→r4→r5（soak-rebuild-churn-plan §四 判定纪律）
#   - 每场景进场前置检查：全 fleet NODE_COUNT managed/online/collection_ok + active 告警 0；
#   - 任一断言失败（场景脚本非零退出）→ 停止后续场景（不继续），汇总落 evidence/R-wave-summary.json；
#   - 总计时 + 逐场景耗时落盘。场景本体自带 P68 check_egress 与 journal 落盘（r-lib.sh）。
# 用法：bash run-r-wave.sh   （可 SCENARIOS="r1 r3" 子集重跑——判定纪律要求全绿才继续，
#       子集重跑仅用于单场景修复后的回归，正式波次必须全序）
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/churn
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）

ALL_SCENARIOS=(r1-revive-deep r2-batch8 r3-parent-removal r4-negative-guards r5-firsthop-revive)
if [ -n "${SCENARIOS:-}" ]; then
  REQUESTED=($SCENARIOS)
  SCENARIOS=()
  for want in "${REQUESTED[@]}"; do
    hit=""
    for s in "${ALL_SCENARIOS[@]}"; do
      if [ "$s" = "$want" ] || [ "${s%%-*}" = "$want" ]; then  # 接受 r1 / r1-revive-deep 两种写法
        SCENARIOS+=("$s"); hit=1
      fi
    done
    [ -n "$hit" ] || { echo "ABORT: 未知场景 '$want'（可选: r1..r5 或 ${ALL_SCENARIOS[*]}）" >&2; exit 2; }
  done
else
  SCENARIOS=("${ALL_SCENARIOS[@]}")
fi

mkdir -p "$EVIDENCE"
SUMMARY="$EVIDENCE/R-wave-summary.json"
ENTRIES="$EVIDENCE/.r-wave-entries.jsonl"; : > "$ENTRIES"
WAVE_T0=$(date +%s)
WAVE_START=$(date -u +%FT%TZ)
log "=== R-WAVE START $WAVE_START（场景序: ${SCENARIOS[*]}；NODE_COUNT=$NODE_COUNT）==="

fleet_precheck() { # 驱动器侧进场门：全 managed/online/collection_ok + active 告警 0
  local n bad
  api GET /nodes > "$EVIDENCE/.r-wave-precheck-nodes.json" 2>/dev/null \
    || { log "ABORT: 前置检查 GET /nodes 失败"; return 1; }
  bad=$(python3 - "$EVIDENCE/.r-wave-precheck-nodes.json" "$NODE_COUNT" <<'PYEOF'
import json, sys
items = json.load(open(sys.argv[1]))['items']
nc = int(sys.argv[2])
bad = [x['id'] for x in items
       if not (x['role'] == 'managed' and x['status'] == 'online'
               and x['collection_state'] == 'collection_ok')]
if len(items) != nc:
    bad = [f"<fleet {len(items)} != {nc}>"] + bad
print(len(bad))
PYEOF
)
  [ "$bad" = "0" ] || { log "前置检查 FAIL：$bad 台异常（.r-wave-precheck-nodes.json）"; return 1; }
  api GET "/alerts?status=active&limit=200" > "$EVIDENCE/.r-wave-precheck-alerts.json" 2>/dev/null || return 1
  n=$(python3 -c "import json;d=json.load(open('$EVIDENCE/.r-wave-precheck-alerts.json'));print(d.get('total', len(d.get('items',[]))))")
  [ "$n" = "0" ] || { log "前置检查 FAIL：active 告警 $n 条 != 0"; return 1; }
  log "前置检查 OK：$NODE_COUNT/$NODE_COUNT managed/online/collection_ok，active 告警 0"
}

FAILED=""
for s in "${SCENARIOS[@]}"; do
  log "── 场景 $s：前置检查 ──"
  if ! fleet_precheck; then
    FAILED="$s(precheck)"
    break
  fi
  log "── 场景 $s：执行 ──"
  S_T0=$(date +%s)
  RC=0
  bash "$SOAK_HOME/churn/$s.sh" || RC=$?
  S_DUR=$(( $(date +%s) - S_T0 ))
  SC_UP="$(echo "${s%%-*}" | tr '[:lower:]' '[:upper:]')"   # 证据目录为大写 R1..R5（R_SCENARIO）
  VERDICT="fail"
  if [ "$RC" = "0" ] && [ -f "$EVIDENCE/$SC_UP/verdict.json" ]; then
    VERDICT=$(python3 -c "import json;print(json.load(open('$EVIDENCE/$SC_UP/verdict.json'))['verdict'])")
  fi
  printf '{"scenario":"%s","script":"%s","verdict":"%s","rc":%s,"duration_s":%s,"ended_at":"%s"}\n' \
    "$SC_UP" "$s" "$VERDICT" "$RC" "$S_DUR" "$(date -u +%FT%TZ)" >> "$ENTRIES"
  log "── 场景 $SC_UP 完成：verdict=$VERDICT rc=$RC 耗时=${S_DUR}s ──"
  if [ "$VERDICT" != "pass" ] || [ "$RC" != "0" ]; then
    FAILED="$s(rc=$RC verdict=$VERDICT)"
    break   # 判定纪律：任一断言失败即停，不继续后续场景
  fi
done

WAVE_DUR=$(( $(date +%s) - WAVE_T0 ))
python3 - "$ENTRIES" "$SUMMARY" "$WAVE_START" "$WAVE_DUR" "$FAILED" "${SCENARIOS[*]}" <<'PYEOF'
import datetime, json, sys
entries_f, summary_f, start, dur, failed, planned = sys.argv[1:7]
entries = [json.loads(l) for l in open(entries_f) if l.strip()]
out = {
    "wave": "R1-R5",
    "started_at": start,
    "ended_at": datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    "total_duration_s": int(dur),
    "planned_scenarios": planned.split(),
    "stopped_at": failed or None,
    "all_pass": failed == "",
    "scenarios": entries,
}
json.dump(out, open(summary_f, 'w'), ensure_ascii=False, indent=1)
print(json.dumps(out, ensure_ascii=False, indent=1))
PYEOF

if [ -n "$FAILED" ]; then
  log "=== R-WAVE STOPPED：$FAILED（现场见 evidence/<场景>/fail/；汇总 $SUMMARY）==="
  exit 1
fi
log "=== R-WAVE COMPLETE：${#SCENARIOS[@]} 场景全绿，总耗时 ${WAVE_DUR}s（汇总 $SUMMARY）==="
