#!/bin/bash
# w-e.sh — W-E 指令阈值（票 0-5；16 变体：CMD-15+CMD-07/08/12+AGENT-15+SYS-06/12+CMD-01+SYS-04/13）。
# 前置：节点装有 stress-ng（W-E 同款前置；缺失记台账 SKIP 非缺陷）。
set -euo pipefail
WAVE_ID=W-E
WAVE_CARRIER="W-E 指令阈值"
SCENARIOS=(
  "CMD-15.1|cmd15-threshold-put-cross|api:PUT:/config:200 unit:threshold-stress alert:resolved:cpu_critical conv"
  "CMD-07.1|cmd07-command-matrix|api:POST:/nodes/{t}/dispatch:200 conv"
  "CMD-08.1|cmd08-output-contract|api:POST:/nodes/{t}/dispatch:200 conv"
  "CMD-12.1|cmd12-batch-inject|api:POST:/nodes/{t}/dispatch:200 conv"
  "AGENT-15.1|agent15-deploy-basic|api:POST:/deploy:200 api:GET:/agent-deploy conv"
  "AGENT-15.2|agent15-deploy-retry|api:POST:/deploy:200 conv"
  "AGENT-15.3|agent15-deploy-partial|api:POST:/deploy:200 api:GET:/agent-deploy"
  "AGENT-15.4|agent15-deploy-version-skew|api:POST:/deploy:200 conv"
  "AGENT-15.5|agent15-deploy-cleanup|api:POST:/deploy:200 conv"
  "SYS-06.1|sys06-config-hot-reload|api:PUT:/config:200 unit:threshold-stress conv"
  "SYS-12.1|sys12-config-badvalue|api:PUT:/config:200 conv"
  "CMD-01.1|cmd01-echo-basic|api:POST:/nodes/{t}/dispatch:200 conv"
  "CMD-01.2|cmd01-echo-timeout|api:POST:/nodes/{t}/dispatch:200 conv"
  "CMD-01.3|cmd01-echo-large|api:POST:/nodes/{t}/dispatch:200 conv"
  "SYS-04.1|sys04-health-liveness|api:GET:/health:200 conv"
  "SYS-13.1|sys13-alert-feed|api:GET:/alerts?status=active&limit=200 conv"
)
source "$(dirname "${BASH_SOURCE[0]}")/wave-lib.sh"
wave_main "$@"
