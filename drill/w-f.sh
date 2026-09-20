#!/bin/bash
# w-f.sh — W-F 部署环境收口（票 0-5；11 变体：PROV-02×4+PROV-05+OPS-09×5+SYS-14）。
# SYS-01 不在本波（以第一部分循环证据登记——冻结清单独立载体）；OPS-08 O 层核对与
# fra1 复核为 runbook 人工节；跨波审计观察者=SYS-14 锚。
set -euo pipefail
WAVE_ID=W-F
WAVE_CARRIER="W-F 部署环境收口"
SCENARIOS=(
  "PROV-02.1|prov02-restart-rollback-basic|api:POST:/deploy:200 conv"
  "PROV-02.2|prov02-restart-fail-keeps-conn|api:POST:/deploy:200 api:POST:/nodes/{t}/dispatch:200 conv"
  "PROV-02.3|prov02-rollback-version|api:POST:/deploy:200 api:GET:/agent-deploy"
  "PROV-02.4|prov02-rollback-partial|api:POST:/deploy:200 conv"
  "PROV-05.1|prov05-deploy-env|api:POST:/deploy:200 conv"
  "OPS-09.1|ops09-audit-put|api:GET:/audit:200 conv"
  "OPS-09.2|ops09-audit-delete|api:GET:/audit:200 conv"
  "OPS-09.3|ops09-audit-dispatch|api:GET:/audit:200 conv"
  "OPS-09.4|ops09-audit-config|api:GET:/audit:200 conv"
  "OPS-09.5|ops09-audit-onboard|api:GET:/audit:200 conv"
  "SYS-14.1|sys14-cross-wave-audit-observer|api:GET:/audit:200 conv"
)
source "$(dirname "${BASH_SOURCE[0]}")/wave-lib.sh"
wave_main "$@"
