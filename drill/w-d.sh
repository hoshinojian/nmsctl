#!/bin/bash
# w-d.sh — W-D 生命周期真机（票 0-5；18 变体：PROV-03+STAT-13+SYS-08/09/10/11+SSH-10/11）。
# STAT-13 双停机形态：systemctl restart=优雅排干 vs kill -9 硬切（「重启丢一半」窗口
# 须 kill -9 构造——规划 §7 注记）；W-D 前提回主几何 79 台（runbook 重建栈）。
set -euo pipefail
WAVE_ID=W-D
WAVE_CARRIER="W-D 生命周期真机"
SCENARIOS=(
  "PROV-03.1|prov03-systemd-autostart|nms:systemctl_restart_nms conv g5"
  "STAT-13.1|stat131-graceful-drain|nms:systemctl_restart_nms conv"
  "STAT-13.2|stat132-kill9-hard-cut|nms:kill_-9_nms conv"
  "STAT-13.3|stat133-restart-inflight-window|nms:systemctl_restart_nms conv"
  "STAT-13.4|stat134-restart-mixed|nms:kill_-9_nms conv g5"
  "SYS-08.1|sys08-restart-window-1|nms:systemctl_restart_nms conv"
  "SYS-09.1|sys09-restart-window-2|nms:systemctl_restart_nms conv"
  "SSH-10.1|ssh10-delete-revive-basic|api:DELETE:/nodes/{t}?force=true:200 api:POST:/topology:200 conv"
  "SSH-10.2|ssh10-revive-clear-ledger|api:DELETE:/nodes/{t}?force=true:200 api:POST:/topology:200 conv"
  "SSH-10.3|ssh10-revive-redeploy|api:DELETE:/nodes/{t}?force=true:200 api:POST:/deploy:200 conv"
  "SSH-10.4|ssh10-revive-reattach|api:DELETE:/nodes/{t}?force=true:200 api:POST:/topology:200 g5"
  "SSH-10.5|ssh10-revive-negative|api:DELETE:/nodes/{t}:409 conv"
  "SSH-11.1|ssh11-tofu-first-seen|api:GET:/nodes/{t}:200 unit:power-cycle conv"
  "SSH-11.2|ssh11-hostkey-rotation|api:GET:/nodes/{t}:200 alert:resolved:host_key_tamper"
  "SSH-11.3|ssh11-hostkey-mismatch-refuse|api:GET:/nodes/{t}:200 conv"
  "SSH-11.4|ssh11-tamper-then-heal|api:GET:/nodes/{t}:200 unit:power-cycle conv"
  "SYS-11.1|sys11-inflight-recover|api:POST:/nodes/{t}/dispatch:200 nms:systemctl_restart_nms conv"
  "SYS-10.1|sys10-health-fields|nms:systemctl_restart_nms api:GET:/health:200 conv"
)
source "$(dirname "${BASH_SOURCE[0]}")/wave-lib.sh"
wave_main "$@"
