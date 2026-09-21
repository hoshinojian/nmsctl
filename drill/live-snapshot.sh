#!/bin/bash
# live-snapshot.sh — 活系统快照采集（env-verify 的 IO 半边：网络全在本脚本，python 只对账）。
# 产出 $EVIDENCE/env-verify/{config.json,nodes.json,fw-tcp-sources.json,egress.txt}——幂等。
# 依赖 SOAK_ENV（env.sh 全套：通道 auto/direct/stunnel443 自适应）。
set -euo pipefail
SNAP_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SNAP_HOME/../lib/env.sh"
OUT="$EVIDENCE/env-verify"
mkdir -p "$OUT"

# 1 egress（复用 net-probe 的探测与字面量门）
bash "$SNAP_HOME/../lib/net-probe.sh" --eval > "$OUT/net-probe.env" 2>/dev/null || true
sed -n 's/^NP_EGRESS=//p' "$OUT/net-probe.env" > "$OUT/egress.txt"

# 2 NMS /config 与 /nodes（经 env.sh 通道打 NMS 本机 loopback）
if [ -f "$EVIDENCE/nms-ip.txt" ]; then
  nms_ssh "curl -sS -m 30 http://127.0.0.1:80/api/v1/config" > "$OUT/config.json"
  nms_ssh "curl -sS -m 30 http://127.0.0.1:80/api/v1/nodes"  > "$OUT/nodes.json"
else
  : > "$OUT/config.json"; : > "$OUT/nodes.json"   # NMS 未建：空文件=对账器按"未建"处理
fi

# 3 fw tcp 源清单（DO API；FW id 过 UUID 门）
python3 - "$VPSCTL_ACCOUNTS" "$FW_SOAK_NMS_ID" "$NMS_ACCOUNT" "$OUT/fw-tcp-sources.json" <<'PYEOF'
import json, re, sys, urllib.request
accounts_path, fw_id, acct_name, out_path = sys.argv[1:5]
if not re.fullmatch(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}", fw_id):
    open(out_path, "w").write("[]"); raise SystemExit
cfg = json.load(open(accounts_path))
arr = cfg["accounts"] if isinstance(cfg, dict) else cfg
tok = next((a.get("token") or a.get("api_token") for a in arr if a["name"] == acct_name), None)
if not tok:
    open(out_path, "w").write("[]"); raise SystemExit
req = urllib.request.Request(f"https://api.digitalocean.com/v2/firewalls/{fw_id}",
                             headers={"Authorization": f"Bearer {tok}"})
fw = json.load(urllib.request.urlopen(req, timeout=15))["firewall"]
srcs = sorted({s for r in fw["inbound_rules"] if r["protocol"] == "tcp"
               for s in r["sources"]["addresses"]})
json.dump(srcs, open(out_path, "w"), indent=1)
PYEOF

echo "[live-snapshot] 快照落 $OUT（config/nodes/fw/egress）"
