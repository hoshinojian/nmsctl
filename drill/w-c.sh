#!/bin/bash
# w-c.sh — W-C 容量共享（票 0-5；6 变体：SYS-02+SYS-05+SSH-15 R 半边+PROV-01）。
# 波级前置（runbook）：饱和几何切换——FH=1+PUT max_depth=6（容量 63<79→真 pending），
# SOAK_BATCHES/NODE_COUNT 同步改（s3 对账），补扫后 max_depth 上调；SSH-15 L 半边随 L 批。
set -euo pipefail
WAVE_ID=W-C
WAVE_CARRIER="W-C 容量共享"
SCENARIOS=(
  "SYS-02.1|sys02-parent-capacity-full|api:POST:/topology:200 conv g5"
  "SYS-05.1|sys05-multi-target-same-relay|api:POST:/nodes/{t}/dispatch:200 conv"
  "SSH-15.1|ssh15-maxsessions-pressure|unit:threshold-stress conv"
  "SSH-15.2|ssh15-deploy-pull-dispatch-shared|api:POST:/nodes/{t}/dispatch:200 conv"
  "PROV-01.1|prov01-version-matrix|api:POST:/deploy:200 conv"
  "PROV-01.2|prov01-arch-matrix|api:POST:/deploy:200 conv"
)
source "$(dirname "${BASH_SOURCE[0]}")/wave-lib.sh"
wave_main "$@"
