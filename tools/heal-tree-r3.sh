#!/bin/bash
# R3 失败现场树形修复：把 R3 疏散时被 rehome 堆到超预算父（出度 > child_budget）的叶子
# 删→复活，让它们走预算内的新鲜挂接路径回到合规位置。
# 复用 r1 的复活载荷构造与 P74 舞步；终结断言 = g5-tree.py 不变量。
# 目标清单经 HEAL_TARGETS 注入（空格分隔节点名；本仓不留任何节点/账号名常量）。
export R_SCENARIO="R3HEAL"
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/tools
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）
source "$SOAK_SELF_DIR/../churn/r-lib.sh"

read -r -a TARGETS <<< "${HEAL_TARGETS:?缺 HEAL_TARGETS（空格分隔的待修复节点名清单）}"
[ "${#TARGETS[@]}" -gt 0 ] || { echo "ABORT: HEAL_TARGETS 为空" >&2; exit 1; }

r_fleet_check entry

for ID in "${TARGETS[@]}"; do
  log "── 修复 $ID ──"
  r_snap "node-before-$ID.json" "/nodes/$ID" || r_fatal "读目标" "GET /nodes/$ID 失败"
  python3 -c "import json;n=json.load(open('$R_DIR/node-before-$ID.json'));assert n['role']=='managed' and n['domain']==1, n"

  r_api_code DELETE "/nodes/$ID"
  [ "$R_CODE" = "200" ] || r_fatal "叶子删除" "$ID -> HTTP $R_CODE"
  sleep 2
  r_snap "topology-after-delete-$ID.json" /topology
  python3 - "$R_DIR/topology-after-delete-$ID.json" "$ID" <<'PYEOF'
import json, sys
t = json.load(open(sys.argv[1])); nid = sys.argv[2]
assert nid not in {n['id'] for n in t['nodes']}, "仍在 nodes[]"
assert not any(l['target'] == nid for l in t['links']), "links 仍有其入边"
print("归档 OK")
PYEOF

  PAYLOAD=$(python3 - "$R_DIR/node-before-$ID.json" "${NODE_PASS:?NODE_PASS 未设置}" <<'PYEOF'
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
  log "$ID 修复完成（saw_provisioning=$SAW）"
done

log "── 终验：g5 不变量（出度 ≤ child_budget 全树复核）──"
r_snap topology-healed.json /topology
python3 - "$R_DIR/topology-healed.json" <<'PYEOF'
import json, sys
from collections import Counter
t = json.load(open(sys.argv[1]))
kids = Counter(l['source'] for l in t['links'])
over = {n: c for n, c in kids.items() if c > 3}
assert not over, f"仍有出度>3: {over}"
print("g5 不变量 OK：全树出度 ≤3，links =", len(t['links']))
PYEOF
r_verdict pass "R3 现场修复：3 台 syd1 复活回预算内挂接，全树出度合规"
log "HEAL COMPLETE"
