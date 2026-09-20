#!/bin/bash
# inject/slow-agent.sh — 可回收故障④慢响应（票 0-10；SIGSTOP 冻结 agent 进程 = 拉取超时/
# 慢响应形态，限时后 SIGCONT 解冻——自愈窗口内 NMS 观察 pull 超时或 degraded）。
# 期望自愈信号（首轮校准）：pull_failed/pull_degraded 或 node_unreachable 开+解。
# 用法: inject/slow-agent.sh <node-id> [freeze-seconds=180]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
NID=${1:?用法: slow-agent.sh <node-id> [freeze-seconds]}
FREEZE=${2:-180}
mkdir -p "${SILENT_EVIDENCE:-/tmp/silent}"
W_LOG "slow-agent: 目标 $NID 冻结 agent ${FREEZE}s（SIGSTOP→SIGCONT，trap 保解冻）"

if [ "$DRY_RUN" = "1" ]; then
  W_LOG "DRY: pkill -STOP nms-agent; sleep ${FREEZE}; pkill -CONT nms-agent（跳过）"
  exit 0
fi
IP=$(node_mgmt_ip "$NID")
thaw() { node_ssh "$IP" "pkill -CONT nms-agent" && W_LOG "解冻完成 $NID" || W_LOG "WARN: 解冻失败 $NID（P58 回收清单核对）"; }
trap thaw EXIT INT TERM
node_ssh "$IP" "pkill -STOP nms-agent" | tee -a "${SILENT_EVIDENCE:-/tmp/silent}/slow-agent-$NID.log"
W_LOG "已冻结 $NID（$IP）agent，${FREEZE}s 后解冻"
sleep "$FREEZE"
thaw
trap - EXIT INT TERM
