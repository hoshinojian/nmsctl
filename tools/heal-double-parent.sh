#!/bin/bash
# R5 陈旧边现场修复：对双父节点（有陈旧入边）执行 删→复活，清除残留边重建单父挂接
# 目标清单经 HEAL_TARGETS 注入（空格分隔节点名；本仓不留任何节点/账号名常量）。
export R_SCENARIO="R5HEAL2"
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/tools
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）
source "$SOAK_SELF_DIR/../churn/r-lib.sh"
read -r -a TARGETS <<< "${HEAL_TARGETS:?缺 HEAL_TARGETS（空格分隔的待修复节点名清单）}"
[ "${#TARGETS[@]}" -gt 0 ] || { echo "ABORT: HEAL_TARGETS 为空" >&2; exit 1; }

for ID in "${TARGETS[@]}"; do
  log "── 修复 $ID ──"
  r_snap "node-before-$ID.json" "/nodes/$ID" || r_fatal "读目标" "GET /nodes/$ID 失败"
  python3 -c "import json;n=json.load(open('$R_DIR/node-before-$ID.json'));assert n['role']=='managed' and n['domain']==1, n"
  r_api_code DELETE "/nodes/$ID"
  [ "$R_CODE" = "200" ] || r_fatal "叶子删除" "$ID -> HTTP $R_CODE"
  sleep 2
  PAYLOAD=$(python3 - "$R_DIR/node-before-$ID.json" "${NODE_PASS:?}" <<'PYEOF'
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
  r_wait_managed "$ID" 300 > /dev/null || r_fatal "收敛" "$ID 300s 未转正"
  log "$ID 修复完成"
done

log "── 终验：links 数与双父复核 ──"
r_snap topology-healed.json /topology
python3 - "$R_DIR/topology-healed.json" <<'PYEOF'
import json, sys
from collections import Counter
t = json.load(open(sys.argv[1]))
targets = [l['target'] for l in t['links']]
dup = [x for x in set(targets) if targets.count(x) > 1]
assert not dup, f"仍有双父: {dup}"
attached = len(set(targets))
print(f"links={len(t['links'])}（应等于挂接数 {attached}）")
assert len(t['links']) == attached, "links 数与挂接数不一致——仍有陈旧边"
print("HEAL OK：无双父、无陈旧边")
PYEOF
r_verdict pass "R5 现场修复：3 台双父节点复活清边"
log "HEAL COMPLETE"
