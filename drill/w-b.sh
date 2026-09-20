#!/bin/bash
# w-b.sh — W-B 断链抖动（票 0-5；15 变体：SSH-14+SYS-03+SSH-01/08/09+STAT-10.3/.4/.5）。
# 断言锚=NMS 侧四条派生信号（link_down/up 真机不可断言，mock 已覆盖——规划 §7 注记）。
set -euo pipefail
WAVE_ID=W-B
WAVE_CARRIER="W-B 断链抖动"
SCENARIOS=(
  "SSH-14.1|ssh14-stop-sshd-old-session-alive|unit:link-block-new:240 alert:resolved:node_unreachable,pull_failed conv"
  "SSH-14.2|ssh14-firewall-new-conns-only|unit:link-block-new:240 conv"
  "SYS-03.1|sys03-three-layer-stable|g5 conv"
  "SSH-01.1|ssh01-depth-matrix|api:GET:/nodes/{t}:200 conv"
  "SSH-01.2|ssh01-per-hop-password-port|api:GET:/nodes/{t}:200 conv"
  "SSH-08.1|ssh08-transient-command|api:POST:/nodes/{t}/dispatch:200 conv"
  "SSH-08.2|ssh08-multi-short-output|api:POST:/nodes/{t}/dispatch:200 conv"
  "SSH-08.3|ssh08-empty-output|api:POST:/nodes/{t}/dispatch:200 conv"
  "SSH-08.4|ssh08-large-output|api:POST:/nodes/{t}/dispatch:200 conv"
  "SSH-08.5|ssh08-nonzero-exit|api:POST:/nodes/{t}/dispatch:200 conv"
  "SSH-09.1|ssh09-halfopen-midhop-blackhole|unit:power-cycle conv"
  "SSH-09.2|ssh09-heartbeat-timeout|unit:slow-agent:300 alert:resolved:pull_degraded,pull_failed conv"
  "STAT-10.3|stat103-relay-link-cut|unit:link-block-new:240 alert:resolved:node_unreachable conv"
  "STAT-10.4|stat104-firsthop-link-cut|unit:power-cycle conv g5"
  "STAT-10.5|stat105-blackhole|unit:link-block-new:600 alert:resolved:node_unreachable,pull_failed conv"
)
source "$(dirname "${BASH_SOURCE[0]}")/wave-lib.sh"
wave_main "$@"
