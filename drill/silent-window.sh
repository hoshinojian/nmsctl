#!/bin/bash
# silent-window.sh — 静默窗（票 0-10；v2.3 口径：短窗=恢复自稳+常规密度注入 4 个、
# 24h 长窗=翻倍 9 个；全程大模型不在环——本脚本自动 注入→等窗→窗末复核→verdict）。
#
# 用法: silent-window.sh <minutes> [--density short|long] [--dry-run]
#   minutes：窗宽（短窗 60–120；长窗 1440）
#   density：short=4 故障（缺省）/ long=9 故障（SYS-16 判据：注入全部自愈+零人工 API）
#   --dry-run：零网络（fixture nodes/alerts + 单元全 DRY；排期数学照常断言）
#
# 窗末复核（SYS-16 判据的短窗同构）三判据全过才 PASS：
#   ①全目标回 managed/online/collection_ok ②active 告警=0 ③每注入目标 ≥1 条窗内
#   triggered 的 resolved 告警。verdict 落 <运行时目录>/verdicts/silent.jsonl。
# witness：非 DRY 自动起 observe/witness.py 采样，窗末停（P58 回收清单对照）。
# DRILL_COMMIT env：被测 NMS commit（verdict 行）。
# cron 驱动（可选，长窗防编排机断连）：crontab 一行
#   `0 9 * * * cd <nmsctl> && SOAK_ENV=<运行时目录> drill/silent-window.sh 1440 --density long`
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0; DENSITY=short
MIN=${1:?用法: silent-window.sh <minutes> [--density short|long] [--dry-run]}
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --density) DENSITY=${2:?--density 缺值}; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    *) echo "未知参数 $1" >&2; exit 2;;
  esac
done
case "$DENSITY" in
  short) N_FAULTS=4;;
  long)  N_FAULTS=9;;
  *) echo "density 须 short|long" >&2; exit 2;;
esac
E0=$(( $(date +%s) / 60 ))   # 排期锚：脚本启动的分钟粒度墙钟（DRY 同时钟）

TS=$(date -u +%Y%m%dT%H%M%SZ)
START_ISO=$(date -u +%FT%TZ)
if [ "$DRY_RUN" = "0" ]; then
  source "$SOAK_SELF_DIR/../lib/env.sh"
  export SILENT_EVIDENCE="$EVIDENCE/silent/$TS"
else
  export SILENT_EVIDENCE="/tmp/silent-dry/$TS"
  export DRILL_FIXTURE="${DRILL_FIXTURE:-$SOAK_SELF_DIR/tests/fixture}"
  api() { case "$1" in
            GET) case "$2" in
                   /nodes) cat "$DRILL_FIXTURE/nodes.json";;
                   /alerts*) cat "$DRILL_FIXTURE/alerts.json";;
                   *) echo '{"items":[],"total":0}';;
                 esac;;
            *) echo '{"dry_run":true}';;
          esac; }
fi
mkdir -p "$SILENT_EVIDENCE"
exec > >(tee "$SILENT_EVIDENCE/log.txt") 2>&1
log() { echo "[$(date -u +%FT%TZ)] $*"; }
log "静默窗开始：${MIN}min density=$DENSITY（$N_FAULTS 个注入）dry=$DRY_RUN 证据=$SILENT_EVIDENCE"

# ---- witness 常驻采样（非 DRY）----
WITNESS_PID=""
if [ "$DRY_RUN" = "0" ]; then
  SOAK_ENV="$SOAK_ENV" nohup python3 "$SOAK_HOME/observe/witness.py" >/dev/null 2>&1 &
  WITNESS_PID=$!
  log "witness 已启动 pid=$WITNESS_PID（evidence/witness.jsonl）"
fi
stop_witness() { if [ -n "$WITNESS_PID" ]; then kill "$WITNESS_PID" 2>/dev/null && log "witness 已停" || true; fi; }
trap stop_witness EXIT INT TERM

# ---- 目标选取：非第一跳 managed 节点按 id 排序散布取 N ----
mapfile -t CAND < <(api GET /nodes | python3 -c "
import json, sys
items = [n for n in json.load(sys.stdin)['items'] if n.get('domain') != 0]
ids = sorted(n['id'] for n in items)
need = int(sys.argv[1])
assert len(ids) >= need, f'非第一跳 managed 候选不足: {len(ids)} < {need}'
step = len(ids) / need
for i in range(need):
    print(ids[int(i * step)])" "$N_FAULTS")
log "注入目标：${CAND[*]}"

# ---- 排期：窗 [15%,75%] 内散布，尾段 25%+60s 留自愈复核 ----
UNITS=(power-cycle link-block-new threshold-stress slow-agent)
plan="$SILENT_EVIDENCE/plan.tsv"
: > "$plan"
for i in $(seq 0 $((N_FAULTS - 1))); do
  OFF=$(python3 -c "print(int($MIN * (0.15 + 0.60 * $i / max($N_FAULTS - 1, 1))))")
  printf '%s\t%s\t%s\n' "$OFF" "${UNITS[$((i % 4))]}" "${CAND[$i]}" >> "$plan"
done
sort -n "$plan" -o "$plan"
log "注入排期（分钟\t单元\t目标）："; cat "$plan"
python3 - "$plan" "$MIN" <<'EOF'
import sys
rows = [l.split("\t") for l in open(sys.argv[1]).read().splitlines() if l]
mins = [int(r[0]) for r in rows]
w = int(sys.argv[2])
assert rows and all(0 <= m <= int(w * 0.75) for m in mins), f"排期越界: {mins} vs 窗 {w}"
assert len({(r[1], r[2]) for r in rows}) == len(rows), "排期存在重复 (unit,node)"
print(f"排期断言过：{len(rows)} 条，首 {mins[0]}min 尾 {mins[-1]}min ≤75% 窗宽")
EOF

# ---- 执行（到点派发；单元自带回收语义，后台并行）----
while IFS=$'\t' read -r OFF UNIT NID; do
  WAIT=$(( (E0 + OFF - $(date +%s) / 60) * 60 ))
  [ "$WAIT" -lt 0 ] && WAIT=0
  log "排定 $UNIT@$NID 于 +${OFF}min（sleep ${WAIT}s）"
  sleep "$WAIT"
  DRY_RUN=$DRY_RUN SILENT_EVIDENCE="$SILENT_EVIDENCE" \
    bash "$SOAK_SELF_DIR/inject/$UNIT.sh" "$NID" &
  log "已派发 $UNIT@$NID（后台 pid=$!）"
done < "$plan"
log "全部注入派发完毕，等窗尾自稳（$(( MIN * 25 / 100 ))min+60s）"
sleep $(( MIN * 25 / 100 * 60 + 60 ))
wait || true

# ---- 窗末复核（三判据）----
api GET /nodes > "$SILENT_EVIDENCE/nodes-final.json"
api GET "/alerts?status=active&limit=200" > "$SILENT_EVIDENCE/alerts-active.json"
api GET "/alerts?status=resolved&limit=500" > "$SILENT_EVIDENCE/alerts-resolved.json"
set +e
VERDICT=$(python3 - "$SILENT_EVIDENCE" "$START_ISO" "${CAND[@]}" 2> "$SILENT_EVIDENCE/verify-errors.log" <<'EOF'
import json, sys, datetime
ev, start_iso, targets = sys.argv[1], sys.argv[2], sys.argv[3:]
nodes = json.load(open(ev + "/nodes-final.json"))["items"]
bad = [n["id"] for n in nodes if n["id"] in targets
       and not (n["role"] == "managed" and n["status"] == "online"
                and n["collection_state"] == "collection_ok")]
act = json.load(open(ev + "/alerts-active.json"))
n_act = int(act.get("total", len(act.get("items", []))))
res = json.load(open(ev + "/alerts-resolved.json")).get("items", [])
t0 = datetime.datetime.fromisoformat(start_iso.replace("Z", "+00:00"))
healed = set()
for a in res:
    if a.get("node_id") in targets and a.get("triggered_at"):
        if datetime.datetime.fromisoformat(a["triggered_at"].replace("Z", "+00:00")) >= t0:
            healed.add(a["node_id"])
unhealed = [t for t in targets if t not in healed]
fails = []
if bad:
    fails.append(f"未回稳: {bad}")
if n_act:
    fails.append(f"active 告警 {n_act} 条")
if unhealed:
    fails.append(f"无窗内 resolved 告警（注入未自愈）: {unhealed}")
print("PASS" if not fails else "FAIL")
if fails:
    print("; ".join(fails), file=sys.stderr)
EOF
)
VRC=$?
set -e
[ "$VRC" = 0 ] && [ "$VERDICT" = "PASS" ] || VERDICT=FAIL
log "窗末复核：$VERDICT（证据 nodes-final.json/alerts-*.json；stderr 见 verify-errors.log）"

# ---- verdict 行（rl-drill-verdict/1；非 DRY 落正式 verdicts/）----
CARRIER="非矩阵（健康闸/静默窗等）"
if [ "$DENSITY" = "long" ]; then CARRIER="SYS-16 24h 长静默窗"; fi
if [ "$DRY_RUN" = "0" ]; then
  cat > "$SILENT_EVIDENCE/runbook.json" <<'RB'
{"inject": "自动注入（密度由 --density 决定）", "proof_before": "窗前波末健康闸",
 "proof_effective": "三判据：全目标回稳+零 active+每目标窗内 resolved≥1",
 "exercise": "silent-window.sh", "observe": "evidence/silent/<ts>",
 "recover": "注入单元自带回收（trap/timeout/自止）", "proof_after": "nodes-final/alerts-*",
 "cleanup": "witness 停止+iptables/agent 状态复核（P58）"}
RB
  python3 "$SOAK_HOME/observe/verdict.py" write "$REBUILD_DIR/verdicts/silent.jsonl" \
    --carrier "$CARRIER" --scenario "silent-window-$DENSITY" \
    --runbook "$SILENT_EVIDENCE/runbook.json" \
    --verdict "$VERDICT" --commit "${DRILL_COMMIT:-unknown}" \
    --evidence "$SILENT_EVIDENCE" --notes "${MIN}min/$N_FAULTS 注入"
else
  log "DRY：跳过正式 verdict 落盘（fixture 复核已走同一断言链）"
fi
if [ "$VERDICT" != "PASS" ]; then
  log "SILENT WINDOW FAIL"
  exit 1
fi
log "SILENT WINDOW PASS（density=$DENSITY ${MIN}min，$N_FAULTS 注入全部自愈）"
