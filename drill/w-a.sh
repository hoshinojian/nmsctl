#!/bin/bash
# w-a.sh — W-A 树韧性疏散（票 0-5；覆盖冻结清单 26 变体：SYS-07+NODE-05+DISC-01/17/18+LIFE 族）。
# 主力=churn R1–R5 复用（规划 §7）；DISC/SYS-07 走 API/树复核。
# 波级前置：主几何 79 台/FH=2/出度 2（runbook 负责建栈；脚本只做波前门）。
set -euo pipefail
WAVE_ID=W-A
WAVE_CARRIER="W-A 树韧性疏散"
SCENARIOS=(
  "SYS-07.1|sys07-deep-descendant|api:GET:/topology g5 conv"
  "NODE-05.1|node05-managed-release-ok|unit:power-cycle conv"
  "NODE-05.2|node05-managed-release-sqlfail|api:GET:/nodes/{t}:200 conv"
  "DISC-01.1|disc01-domain0-onboard-window|api:PUT:/nodes/{t}:200 conv"
  "DISC-01.2|disc01-archive-verdict|api:DELETE:/nodes/{t}?force=true:200 conv"
  "DISC-01.3|disc01-firsthop-direct-fail|unit:power-cycle conv g5"
  "DISC-17.1|disc17-capacity-recover|churn:r2-batch8 conv g5"
  "DISC-18.1|disc18-probe-deep-target|api:GET:/topology g5"
  "DISC-18.2|disc18-parent-chain-error|api:GET:/topology g5"
  "DISC-18.3|disc18-target-not-found|api:GET:/nodes/{t}:200"
  "DISC-18.4|disc18-ctx-cancel|api:GET:/topology conv"
  "LIFE-01.1|life01-active-removal|churn:r3-parent-removal g5 conv"
  "LIFE-03.1|life03-descendants-unplaceable|churn:r3-parent-removal g5"
  "LIFE-03.2|life03-remote-stop-fail|churn:r3-parent-removal g5 conv"
  "LIFE-03.3|life03-store-fail|churn:r3-parent-removal g5"
  "LIFE-06.1|life06-evacuate-contend-capacity|churn:r3-parent-removal g5"
  "LIFE-06.2|life06-recommit-reread|churn:r3-parent-removal g5"
  "LIFE-07.1|life07-only-full-witness-reachable|api:GET:/topology g5"
  "LIFE-09.1|life09-reparent-with-subtree|churn:r5-firsthop-revive g5 conv"
  "LIFE-10.1|life10-agent-dead-sshd-alive|unit:slow-agent:180 conv"
  "LIFE-10.2|life10-restart-success-fail-none|unit:power-cycle conv"
  "LIFE-11.1|life11-channel-fault-calm-period|unit:link-block-new:240 alert:resolved:node_unreachable,pull_failed conv"
  "LIFE-13.1|life13-old-parent-recovers|churn:r1-revive-deep conv g5"
  "LIFE-13.2|life13-new-witness-appears|churn:r1-revive-deep g5"
  "LIFE-13.3|life13-all-candidates-unreachable|churn:r1-revive-deep g5 conv"
  "LIFE-14.1|life14-hostkey-tamper-queue-full|api:GET:/nodes/{t}:200 alert:resolved:host_key_tamper"
)
source "$(dirname "${BASH_SOURCE[0]}")/wave-lib.sh"
wave_main "$@"
