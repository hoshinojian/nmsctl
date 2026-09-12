#!/bin/bash
# 单台复活（目标已归档场景）：POST /nodes 存量载荷 + P74 舞步 + 收敛等待
export R_SCENARIO="R4HEAL"
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/tools
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）
source "$SOAK_SELF_DIR/../churn/r-lib.sh"
ID="${1:?用法: revive-one.sh <node_name> <payload.json>}"
PAYLOAD_SRC="${2:?缺 payload 源}"
# heal 场景进场检查：目标缺席 + 其余 63 台健康（不能要求满员——缺的那台正是要复活的）
NMS_IP=$(cat "$NMS_IP_FILE")
curl -sS -m 10 "http://$NMS_IP/api/v1/nodes" | python3 -c "
import json, sys
items = json.load(sys.stdin).get('items', [])
ok = sum(1 for n in items if n['role']=='managed' and n['status']=='online' and n['collection_state']=='collection_ok')
assert all(n['name'] != '$ID' for n in items), '目标已在列，无需复活'
assert ok >= 60, f'其余节点健康数异常: {ok}'
print(f'进场 OK：{ok} 台健康，目标缺席待复活')
"
PAYLOAD=$(python3 - "$PAYLOAD_SRC" "${NODE_PASS:?}" <<'PYEOF'
import json, sys
n = json.load(open(sys.argv[1]))
body = {k: n.get(k) for k in ("id", "name", "device_type", "management_ip", "ssh_port",
                              "ssh_user", "domain", "priority", "region", "lat", "lon",
                              "bandwidth_mbps", "provider", "ram_mb", "disk_gb",
                              "cpu_cores", "cost_monthly", "provisioned_at") if n.get(k) is not None}
body["ssh_password"] = sys.argv[2]
print(json.dumps(body))
PYEOF
)
r_api_code POST "/nodes" "$PAYLOAD"
[ "$R_CODE" = "201" ] || r_fatal "复活" "$ID -> HTTP $R_CODE"
r_onboard_dance "$ID"
SAW=$(r_wait_managed "$ID" 300) || r_fatal "收敛" "$ID 300s 未转正"
log "$ID 复活完成（saw_provisioning=$SAW）"
r_verdict pass "$ID 复活归队"
