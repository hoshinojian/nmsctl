#!/bin/bash
# ladder-run.sh — 全阶梯协议单遍驱动（执行文件 §3；用户指令：完整跑两遍确认）。
# 用法: SOAK_ENV=<运行时目录> bash rebuild/ladder-run.sh <pass 编号>
# 形态：阶段 1–3 各 ×2（NMS 单机建/拆循环）；阶段 4 5vps ×2（a1 建 NMS、a2 复用地基）；
#       阶段 5 1node ×2 + 10node ×2 **全冷启动**（每 attempt s1 全拆+s2 全新 DB——TOFU
#       天然归零，规避 ISS-016 时序）；pass 末 s1 全拆清零。
# 编码教训：EXPECT_HEAD 随 main 自动对齐（三撞实录）；每步显式 grep GATE 非空判据
# （ISS-011）；s0 先于 s1（计数对齐红线）；verdict 全程留痕（票 6 stage 字段）。
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS="${1:?用法: ladder-run.sh <pass 编号>}"
: "${SOAK_ENV:?未设置 SOAK_ENV}"
R="$(cd "$SOAK_ENV" && pwd)"
E="$R/evidence/ladder/pass$PASS"
mkdir -p "$E"
exec > >(tee "$E/log.txt") 2>&1
log(){ echo "[$(date -u +%FT%TZ)] [pass$PASS] $*"; }

# ---- EXPECT_HEAD 自动对齐（ISS 三撞实录：docs PR 合并后忘更必撞 s2 断言）----
NMS2_REPO="${NMS2_REPO:-$HOME/NMS2}"
HEAD=$(git -C "$NMS2_REPO" describe --tags --always)
python3 - "$R/env.local" "$HEAD" <<'PYEOF'
import sys
p, head = sys.argv[1], sys.argv[2]
lines = open(p).read().splitlines()
out, seen = [], False
for l in lines:
    if l.startswith("EXPECT_HEAD="): out.append(f"EXPECT_HEAD={head}"); seen = True
    else: out.append(l)
if not seen: out.append(f"EXPECT_HEAD={head}")
open(p, "w").write("\n".join(out) + "\n")
PYEOF
export EXPECT_HEAD="$HEAD"
log "EXPECT_HEAD → $HEAD"

# step <名> <命令...>：rc==0 ∧ 日志含结果行（GATE 或「良性退出」——s1 的 SKIP 路径
# 不写 GATE；ISS-011 纪律=非空结果行而非特定字样），否则 ABORT。
step(){ local n=$1; shift
  "$@" > "$E/$n.log" 2>&1; local rc=$?
  local g; g=$(grep -E "GATE |良性退出" "$E/$n.log" | tail -1)
  log "$n rc=$rc ${g:-<无结果行>}"
  if [ $rc -ne 0 ] || [ -z "$g" ]; then log "ABORT：$n 未过（rc=$rc）——按分诊协议处置后从断点续跑"; exit 1; fi
}
S="$SOAK_SELF_DIR"
# verd <scenario> <phase> <rung> <attempt> <form> <notes> <evidence>：阶段 4/5 留痕。
verd(){ local sc=$1 ph=$2 rg=$3 at=$4 fm=$5 notes=$6 ev=$7
  python3 - "$E/vb-$sc.json" "$sc" "$ph" "$notes" <<'PYEOF'
import json, sys
sc, ph, notes = sys.argv[2], sys.argv[3], sys.argv[4]
f = {"inject": f"ladder-pass {sc}", "proof_before": f"evidence/ladder/ 下 {sc} 各步 log",
     "proof_effective": notes, "exercise": f"阶段 {ph} 判据", "observe": "各步 log",
     "recover": "attempt 收尾拆净", "proof_after": "GATE PASS", "cleanup": "同 recover"}
json.dump(f, open(sys.argv[1], "w"), ensure_ascii=False)
PYEOF
  python3 "$S/../observe/verdict.py" write "$R/verdicts/ladder.jsonl" \
    --carrier "阶梯点亮（非矩阵）" --scenario "pass$PASS-$sc" --runbook "$E/vb-$sc.json" \
    --verdict PASS --commit "$(git -C "$NMS2_REPO" rev-parse --short HEAD)" \
    --evidence "$ev" --notes "$notes" \
    --stage "{\"phase\":${ph},\"rung\":\"${rg}\",\"attempt\":${at},\"form\":\"${fm}\"}" \
    --channel "{\"nms_ssh_via\":\"auto\",\"wg_handshake\":null}" >/dev/null
  log "verdict: pass$PASS-$sc PASS"
}
# 单机阶段（1–3）一个 attempt：skip-skip 对 → s2 检查点 → 复点-拆除 对。
solo_attempt(){ local stage=$1 sa=$2 at=$3
  step "s$stage-a$at-pre0"  bash "$S/s0-baseline.sh"
  step "s$stage-a$at-pre1"  bash "$S/s1-teardown.sh"
  DRILL_S2_STOP_AFTER=$sa DRILL_ATTEMPT=$at bash "$S/s2-nms.sh" > "$E/s$stage-a$at-s2.log" 2>&1
  local rc=$? g; g=$(grep -E "GATE " "$E/s$stage-a$at-s2.log" | tail -1)
  log "s$stage-a$at-s2 rc=$rc $g"; { [ $rc -eq 0 ] && [ -n "$g" ]; } || { log ABORT; exit 1; }
  step "s$stage-a$at-post0" bash "$S/s0-baseline.sh"
  step "s$stage-a$at-post1" bash "$S/s1-teardown.sh"
}

log "==== 阶段 1 申请 NMS ×2 ===="
solo_attempt 1 create 1
solo_attempt 1 create 2
log "==== 阶段 2 SSH/WG ×2 ===="
solo_attempt 2 ssh 1
solo_attempt 2 ssh 2
log "==== 阶段 3 bin+配参 ×2 ===="
solo_attempt 3 full 1
solo_attempt 3 full 2

log "==== 阶段 4 五台档 ×2（a2 复用 NMS 地基）===="
export GEOMETRY_FILE="$R/geometry-5vps.env"
if [ "${LADDER_FROM:-start}" != "s4a2" ]; then
step s4-a1-s2  bash "$S/s2-nms.sh"                       # full（STOP_AFTER 缺省）
step s4-a1-s3  bash "$S/s3-nodes.sh"
step s4-a1-s4  bash "$S/s4-import.sh"
step s4-a1-s15 bash "$S/s1.5-fleet-only.sh"
verd stage4-5vps-a1 4 5vps 1 fresh "5 台入池+凭据对账+拆净保 NMS" "ladder/pass$PASS/s4-a1-s4.log"
fi
step s4-a2-s3  bash "$S/s3-nodes.sh"
step s4-a2-s4  bash "$S/s4-import.sh"
step s4-a2-s15 bash "$S/s1.5-fleet-only.sh"
verd stage4-5vps-a2 4 5vps 2 resume "地基保留语境复用 NMS" "ladder/pass$PASS/s4-a2-s4.log"

log "==== 阶段 5 建树（全冷启动 ×2 每档）===="
for rung in 1node 10node; do
  export GEOMETRY_FILE="$R/geometry-$rung.env"
  for at in 1 2; do
    step "s5-$rung-a$at-s0"  bash "$S/s0-baseline.sh"
    step "s5-$rung-a$at-s1"  bash "$S/s1-teardown.sh"     # 全拆（含 NMS）→ 全新 DB
    step "s5-$rung-a$at-s2"  bash "$S/s2-nms.sh"
    step "s5-$rung-a$at-s3"  bash "$S/s3-nodes.sh"
    step "s5-$rung-a$at-s4"  bash "$S/s4-import.sh"
    step "s5-$rung-a$at-s5"  bash "$S/s5-onboard.sh"
    step "s5-$rung-a$at-s6"  bash "$S/s6-verify.sh"
    verd "stage5-$rung-a$at" 5 "$rung" "$at" fresh "全冷启动整轮绿" "ladder/pass$PASS/s5-$rung-a$at-s5.log"
  done
done
unset GEOMETRY_FILE

log "==== pass 末清零 ===="
step final-s0 bash "$S/s0-baseline.sh"
step final-s1 bash "$S/s1-teardown.sh"
log "PASS $PASS COMPLETE（阶梯五阶段全绿+云上清零）"
