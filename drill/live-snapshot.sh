#!/bin/bash
# live-snapshot.sh — 活系统快照采集（env-verify 的 IO 半边：网络全在本脚本，python 只对账）。
# 产出 $EVIDENCE/env-verify/{config.json,nodes.json,api80-public.txt,api80-tunnel.txt,egress.txt}——幂等。
# 依赖 SOAK_ENV（env.sh 全套：通道 auto/direct/stunnel443 自适应+SSHD_PORT/NMS_API_ADDR）。
#（v3.3/v3.4 零防火墙口径：原 fw tcp 源采集段删除——无云防火墙可对账，替代=80 翻转双探测。）
set -euo pipefail
SNAP_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SNAP_HOME/../lib/env.sh"
OUT="$EVIDENCE/env-verify"
mkdir -p "$OUT"

# 1 egress（复用 net-probe 的探测与字面量门；v3.4 起仅记录——零防火墙口径漂移容忍）
bash "$SNAP_HOME/../lib/net-probe.sh" --eval > "$OUT/net-probe.env" 2>/dev/null || true
sed -n 's/^NP_EGRESS=//p' "$OUT/net-probe.env" > "$OUT/egress.txt"

# 2 NMS /config 与 /nodes（经 env.sh 通道打 NMS 本机——API 腿=隧道地址）
if [ -f "$EVIDENCE/nms-ip.txt" ]; then
  nms_ssh "curl -sS -m 30 http://$NMS_API_ADDR:80/api/v1/config" > "$OUT/config.json"
  nms_ssh "curl -sS -m 30 http://$NMS_API_ADDR:80/api/v1/nodes"  > "$OUT/nodes.json"
else
  : > "$OUT/config.json"; : > "$OUT/nodes.json"   # NMS 未建：空文件=对账器按"未建"处理
fi

# 3 80 翻转双探测（v3.4 票 3：公网 :80 必须不通 ∧ 隧道 :80 必须通——比读配置强的实证）
if [ -f "$EVIDENCE/nms-ip.txt" ]; then
  if curl -sS -m 6 "http://$(nms_ip)/api/v1/health" > "$OUT/api80-public.json" 2>/dev/null; then
    echo reachable > "$OUT/api80-public.txt"
  else
    echo unreachable > "$OUT/api80-public.txt"
  fi
  if curl -sS -m 8 "http://$NMS_API_ADDR/api/v1/health" > "$OUT/api80-tunnel.json" 2>/dev/null \
     && grep -q '"status":"ok"' "$OUT/api80-tunnel.json" 2>/dev/null; then
    echo ok > "$OUT/api80-tunnel.txt"
  else
    echo bad > "$OUT/api80-tunnel.txt"
  fi
else
  : > "$OUT/api80-public.txt"; : > "$OUT/api80-tunnel.txt"
fi

echo "[live-snapshot] 快照落 $OUT（config/nodes/api80 双探测/egress）"
