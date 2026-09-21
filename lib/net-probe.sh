#!/bin/bash
# net-probe.sh — 编排机网络形态探测与自适应（ISS-001/005 家族根治；用户 2026-09-21 需求：
# 出口 IP 会漂、TUN 时开时关——nmsctl 要自己判断当前状态并决定怎么做）。
#
# 用法：
#   bash lib/net-probe.sh              # 只读探测，人读结论（P86：每步可见输出）
#   bash lib/net-probe.sh --apply      # 零防火墙口径（v3.3/v3.4）已停用——打印 skip 不动云
#   bash lib/net-probe.sh --eval       # 只输出 eval 用变量行（MODE=.../EGRESS=.../TUN=...）
#
# 探测项与判据：
#   egress  出口 IP：3 回显源冗余取一（v3.4 起仅记录——零防火墙口径无白名单，漂移由
#           WG roaming/通道自适应容忍）
#   fakeip  github.com 解析命中 198.18.0.0/15 → fake-IP TUN 在环（RFC 2544 保留段特征）
#   raw22   已知公网主机裸 22（python socket 实现，目标 IP 只作 argv 参数不进命令串）：
#           TCP 通+读到 SSH banner=净；TCP 通而 banner 前断/零字节=TUN 截杀；TCP 不通=不可判
#           （22 是探测语义：探测「公网裸 TCP 是否被截」，与 fleet 端口无关）
#   nms_ssh/nms443  NMS 双通道探测（nms-ip.txt 存在时）：高位 sshd 直连
#           （$SSHD_PORT，v3.4）/ 443 stunnel TLS（自签 CN=soak-nms）
#
# 决策（MODE）：
#   fakeip 命中 或 raw22 截杀                → stunnel443
#   raw22 净 且 nms_ssh 可用                 → direct
#   raw22 净 但 nms_ssh 不可用且 nms443 可用  → stunnel443
#   探测不可判（断网/全败）                   → stunnel443（演练实证过的兜底通道）
#
# --apply（v3.3 零防火墙口径停用）：原「fw-soak-nms 幂等补源」段删除——无云防火墙可写。
#   结论 JSON 落 $SOAK_ENV/evidence/net-probe.json。
set -euo pipefail
MODE_ARG="${1:-}"

log() { [ "$MODE_ARG" = "--eval" ] || echo "[net-probe] $*" >&2; }

# ---- egress ----
EGRESS=""
for svc in icanhazip.com api.ipify.org ifconfig.me; do
  EGRESS=$(timeout 8 curl -sS "https://$svc" 2>/dev/null | tr -d '[:space:]') && [ -n "$EGRESS" ] && break || EGRESS=""
done
case "$EGRESS" in
  (*[!0-9.]*|'') EGRESS=""; log "egress: 三回显源全败（网络状态不明）";;
  (*) log "egress: $EGRESS";;
esac

# ---- fakeip ----
# DNS 是可污染源（fake-IP 即其形态）：解析结果过严格 IPv4 字面量门，非纯数字点串
# 一律不进后续任何命令（注入面封死）。
FAKEIP=0
GITHUB_IP=$(getent hosts github.com 2>/dev/null | awk '{print $1; exit}' || true)
case "$GITHUB_IP" in
  (*[!0-9.]*|'') GITHUB_IP="";;
esac
if [ -n "$GITHUB_IP" ]; then
  case "$GITHUB_IP" in
    198.18.*|198.19.*) FAKEIP=1; log "fakeip: github.com → $GITHUB_IP（198.18/15 命中——fake-IP TUN 在环）";;
    (*) log "fakeip: github.com → $GITHUB_IP（正常解析）";;
  esac
else
  log "fakeip: 解析失败或非 IPv4 字面量（不判）"
fi

# ---- raw22 ----
RAW22="unknown"
if [ -n "$GITHUB_IP" ] && [ "$FAKEIP" = "0" ]; then
  RAW22=$(python3 - "$GITHUB_IP" <<'PYEOF'
import socket, sys
ip = sys.argv[1]
try:
    s = socket.create_connection((ip, 22), timeout=6)
    s.settimeout(4)
    try:
        banner = s.recv(16)
    except Exception:
        banner = b""
    s.close()
    if banner.startswith(b"SSH-"):
        print("clean")
    else:
        print("intercepted")   # TCP 通而 banner 前断/超时零字节=截杀形态
except Exception:
    print("unreachable")
PYEOF
)
  case "$RAW22" in
    clean) log "raw22: SSH banner 净通道";;
    intercepted) log "raw22: TCP 通而无 banner——TUN 截杀形态";;
    unreachable) log "raw22: TCP 不通——探测不可判";;
  esac
else
  log "raw22: 跳过（无已验证 IP 或 fakeip 命中即已定形态）"
fi

# ---- NMS 双通道（有 nms-ip.txt 才探；IP 同过字面量门）----
# v3.4：sshd 腿探 $SSHD_PORT（全 fleet 高位口）——原 nms22 探测钉死 22 会让 auto 决策树
# 恒落 stunnel 兜底（票 1 实录审核点）。json 字段名同步 nms22→nms_ssh。
NMSSSH="absent"; NMS443="absent"
NP_EVIDENCE_DIR="${SOAK_ENV:-/tmp}"
NMSIP=""
NP_SSH_PORT="${SSHD_PORT:-40222}"
case "$NP_SSH_PORT" in (*[!0-9]*|'') NP_SSH_PORT=40222;; esac
if [ -f "$NP_EVIDENCE_DIR/evidence/nms-ip.txt" ]; then
  NMSIP=$(tr -d '[:space:]' < "$NP_EVIDENCE_DIR/evidence/nms-ip.txt")
fi
case "$NMSIP" in
  (*[!0-9.]*|'') NMSIP="";;
esac
if [ -n "$NMSIP" ]; then
  if timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
       -p "$NP_SSH_PORT" "root@$NMSIP" true >/dev/null 2>&1; then NMSSSH="ok"; else NMSSSH="fail"; fi
  TLS=$(timeout 10 openssl s_client -connect "$NMSIP:443" </dev/null 2>/dev/null | grep -m1 "^subject=" || true)
  if echo "$TLS" | grep -q "soak-nms"; then NMS443="ok"; else NMS443="fail"; fi
  log "nms: ssh($NP_SSH_PORT)=$NMSSSH 443-stunnel=$NMS443（$NMSIP）"
fi

# ---- 决策 ----
if [ "$FAKEIP" = "1" ] || [ "$RAW22" = "intercepted" ]; then
  MODE="stunnel443"; WHY="fakeip/raw22 判 TUN 截杀"
elif [ "$RAW22" = "clean" ] && [ "$NMSSSH" = "ok" ]; then
  MODE="direct"; WHY="净通道且 NMS sshd($NP_SSH_PORT) 可用"
elif [ "$RAW22" = "clean" ] && [ "$NMS443" = "ok" ]; then
  MODE="stunnel443"; WHY="净通道但 NMS sshd($NP_SSH_PORT) 不可用（服务未起/通道抖动）"
else
  MODE="stunnel443"; WHY="兜底（探测不可判：raw22=$RAW22 nms_ssh=$NMSSSH nms443=$NMS443）"
fi
log "决策：MODE=$MODE（$WHY）"

# ---- --apply：v3.3 零防火墙口径停用（无云防火墙可写；保留旗标兼容旧调用）----
APPLIED="skip-zero-firewall"
if [ "$MODE_ARG" = "--apply" ]; then
  log "fw 补源：--apply 已停用（零防火墙口径 v3.3/v3.4——fw-soak-nms 机制退役，Round 1 遗留云资源随盘点清理）"
fi

# ---- 输出 ----
if [ "$MODE_ARG" = "--eval" ]; then
  # KEY=VALUE 原值行（消费方 sed 解析，不做 eval——避免执行不可信串的注入面）
  printf 'NP_MODE=%s\nNP_EGRESS=%s\nNP_TUN=%s\nNP_WHY=%s\n' "$MODE" "$EGRESS" "$FAKEIP" "$WHY"
else
  mkdir -p "$NP_EVIDENCE_DIR/evidence" 2>/dev/null || true
  python3 - "$NP_EVIDENCE_DIR/evidence/net-probe.json" "$EGRESS" "$GITHUB_IP" "$FAKEIP" "$RAW22" "$NMSSSH" "$NMS443" "$MODE" "$WHY" "$APPLIED" "$NP_SSH_PORT" <<'PYEOF'
import json, sys
json.dump({"ts": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),
           "egress": sys.argv[2], "github_ip": sys.argv[3], "fakeip": sys.argv[4] == "1",
           "raw22": sys.argv[5], "nms_ssh": sys.argv[6], "nms443": sys.argv[7],
           "sshd_port": sys.argv[11],
           "mode": sys.argv[8], "why": sys.argv[9], "fw_apply": sys.argv[10]},
          open(sys.argv[1], "w"), ensure_ascii=False, indent=1)
PYEOF
  echo "结论：MODE=$MODE EGRESS=${EGRESS:-?} —— $WHY（fw:$APPLIED）"
fi
