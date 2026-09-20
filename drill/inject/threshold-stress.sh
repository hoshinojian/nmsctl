#!/bin/bash
# inject/threshold-stress.sh — 可回收故障③阈值触发（票 0-10；节点本机 stress-ng 限时压 CPU
# →采集越阈→cpu 告警开→压测自止→恢复解条）。自止式（timeout），无残留。
# 前置：节点装有 stress-ng（W-E 同款前置；缺失则记台账 SKIP——非缺陷）。
# 用法: inject/threshold-stress.sh <node-id> [stress-seconds=300]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
NID=${1:?用法: threshold-stress.sh <node-id> [stress-seconds]}
DUR=${2:-300}
mkdir -p "${SILENT_EVIDENCE:-/tmp/silent}"
W_LOG "threshold-stress: 目标 $NID 压 ${DUR}s（stress-ng --cpu 2 --cpu-load 90，timeout 自止）"

CMD="timeout ${DUR}s stress-ng --cpu 2 --cpu-load 90"
if [ "$DRY_RUN" = "1" ]; then
  W_LOG "DRY: $CMD（跳过）"; exit 0
fi
IP=$(node_mgmt_ip "$NID")
set +e
node_ssh "$IP" "command -v stress-ng >/dev/null || { echo NO_STRESS_NG; exit 3; }; $CMD" \
  2>&1 | tee -a "${SILENT_EVIDENCE:-/tmp/silent}/stress-$NID.log"
RC=${PIPESTATUS[0]}
set -e
if [ "$RC" = "3" ]; then
  W_LOG "SKIP: $NID 无 stress-ng（记台账，W-E 前置未满足非缺陷）"
  exit 0
fi
W_LOG "threshold-stress 注入完成（自止，恢复解条由窗末断言）"
