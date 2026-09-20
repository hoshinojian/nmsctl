#!/bin/bash
# inject/power-cycle.sh — 可回收故障①断电复活（票 0-10；断电→NMS 判离→开机→自愈回管）。
# 手段白名单：vpsctl power（硬断电语义，DO 动作 off=硬关）；不经 NMS、不删机——可回收。
# 期望自愈信号（首轮校准，可经 EXPECT_TYPES 覆盖）：node_offline 或 node_reboot 开+解；
# 目标回 managed/online/collection_ok。
# 用法: inject/power-cycle.sh <node-id> [settle-seconds=600]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
NID=${1:?用法: power-cycle.sh <node-id> [settle-seconds]}
SETTLE=${2:-600}
mkdir -p "${SILENT_EVIDENCE:-/tmp/silent}"
W_LOG "power-cycle: 目标 $NID（droplet 按 id 匹配；settle ${SETTLE}s）"

if [ "$DRY_RUN" = "1" ]; then
  vpsctl_run power -action off -ids "dry/$NID"
  sleep 1
  vpsctl_run power -action on -ids "dry/$NID"
  W_LOG "power-cycle DRY 完成（off→on）"
  exit 0
fi

DROPLET_ID=$(vpsctl_run list | python3 -c "
import json, sys
drops = json.load(sys.stdin)
arr = drops if isinstance(drops, list) else drops.get('items', drops.get('droplets', []))
for d in arr:
    if str(d.get('name')) == sys.argv[1]:
        print(d.get('account', d.get('account_name', '')) + '/' + str(d.get('id')))
        break" "$NID")
[ -n "$DROPLET_ID" ] || { W_LOG "ABORT: vpsctl list 未匹配到 droplet（name=$NID）"; exit 1; }
W_LOG "power off $DROPLET_ID"
vpsctl_run power -action off -ids "$DROPLET_ID" | tee -a "${SILENT_EVIDENCE:-/tmp/silent}/power-off-$NID.json"
sleep 30
W_LOG "power on $DROPLET_ID"
vpsctl_run power -action on -ids "$DROPLET_ID" | tee -a "${SILENT_EVIDENCE:-/tmp/silent}/power-on-$NID.json"
W_LOG "power-cycle 注入完成，等待自愈窗 ${SETTLE}s（复核由 silent-window.sh 窗末统一断言）"
