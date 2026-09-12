#!/bin/bash
# S4 入池：vpsctl 导出载荷 → 后处理（剔 NMS/root/密码/domain/唯一性）→ POST /topology → G3
# T3 必改（scale-coldstart-churn-plan §一 T3）：
#   - domain 标注改显式清单：sgp1 批次内按名称排序取前 FIRST_HOP_COUNT(9) 台 domain0、其余 domain1
#     （旧 region=='sgp1'→domain0 硬规则在新分布 sgp1 11=9+2 下会错标 2 台）；选取清单落盘 evidence 供审计；
#   - 断言 domain0==9 / domain1==55、总数 64、区域计数与 s3 落盘分布表一致；28→64 参数化。
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/rebuild
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）
cd "$REBUILD_DIR"
mkdir -p "$EVIDENCE/s4"
exec > >(tee "$EVIDENCE/s4/log.txt") 2>&1

check_egress
log "导出 NMS 载荷（tag=env:soak，跳过 SSH 预检）"
"$VPSCTL" list -format nms -no-check-ssh -tag env:soak -output "$EVIDENCE/s4/raw-payload.json" > /dev/null

python3 - <<'EOF'
import collections, json, os
NC = int(os.environ['NODE_COUNT'])
FH = int(os.environ['FIRST_HOP_COUNT'])
d = json.load(open('evidence/s4/raw-payload.json'))
items = d['nodes'] if isinstance(d, dict) and 'nodes' in d else (d if isinstance(d, list) else d.get('items', []))
nodes = [n for n in items if not n['id'].startswith(os.environ['NMS_NAME_PREFIX'])]
assert len(nodes) == NC, f"剔除 NMS 后 {len(nodes)} != {NC}"
ids = [n['id'] for n in nodes]; ips = [n['management_ip'] for n in nodes]
assert len(set(ids)) == NC and len(set(ips)) == NC, "id/IP 不唯一"

# 区域计数对表（表由 S3 落盘：evidence/s3/distribution.txt，区域 节点数）
dist = {}
for line in open('evidence/s3/distribution.txt'):
    r, c = line.split()
    dist[r] = int(c)
assert sum(dist.values()) == NC, f"分布表合计 {sum(dist.values())} != {NC}"
regions = collections.Counter(n['region'] for n in nodes)
assert dict(regions) == dist, f"区域计数 {dict(regions)} != 分布表 {dist}"

# T3 必改：domain 显式清单——sgp1 批次内按名称排序取前 FH 台 domain0，其余全部 domain1
sgp1_sorted = sorted((n for n in nodes if n['region'] == 'sgp1'), key=lambda n: n['name'])
assert len(sgp1_sorted) >= FH, f"sgp1 只有 {len(sgp1_sorted)} 台，不足第一跳配额 {FH}"
domain0_ids = {n['id'] for n in sgp1_sorted[:FH]}
json.dump({"rule": f"sgp1 按名称排序前 {FH} 台 domain0，其余 domain1",
           "domain0": sorted(domain0_ids)},
          open('evidence/s4/domain0-selection.json', 'w'), ensure_ascii=False, indent=1)

KEEP = ["id", "name", "device_type", "management_ip", "ssh_port", "ssh_user", "ssh_password",
        "region", "provider", "ram_mb", "disk_gb", "cpu_cores", "cost_monthly",
        "provisioned_at", "domain"]
out = []
for n in nodes:
    m = {k: n[k] for k in KEEP if k in n}
    m['ssh_user'] = 'root'
    m['ssh_password'] = os.environ['NODE_PASS']
    m['domain'] = 0 if n['id'] in domain0_ids else 1
    out.append(m)
d0 = sum(1 for m in out if m['domain'] == 0)
d1 = sum(1 for m in out if m['domain'] == 1)
assert d0 == FH and d1 == NC - FH, f"domain0={d0} domain1={d1} != {FH}/{NC - FH}"
json.dump({"nodes": out}, open('evidence/s4/import-payload.json', 'w'), ensure_ascii=False)
print(f"payload OK: {NC} nodes (domain0={d0} domain1={d1}), 区域={dict(regions)}")
print("domain0 清单 =", sorted(domain0_ids), "（审计件 evidence/s4/domain0-selection.json）")
EOF

log "POST /topology（$NODE_COUNT 台入池，onboard 缺省 false）"
ssh $SSHOPT -p 22 "root@$(nms_ip)" \
  "curl -sS -m 60 -X POST -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:80/api/v1/topology" \
  < "$EVIDENCE/s4/import-payload.json" > "$EVIDENCE/s4/import-resp.json"
cat "$EVIDENCE/s4/import-resp.json"; echo
python3 -c "
import json, os; d=json.load(open('evidence/s4/import-resp.json'))
assert d.get('status') == 'imported' and d.get('nodes') == int(os.environ['NODE_COUNT']), d
print('import resp OK')"

log "G3 断言：$NODE_COUNT 台全 idle ∧ onboard=false ∧ domain0 恰 $FIRST_HOP_COUNT"
api GET /nodes > "$EVIDENCE/s4/nodes-after-import.json"
python3 - <<'EOF'
import json, os
NC = int(os.environ['NODE_COUNT']); FH = int(os.environ['FIRST_HOP_COUNT'])
items = json.load(open('evidence/s4/nodes-after-import.json'))['items']
assert len(items) == NC, len(items)
bad = [n['id'] for n in items if n['role'] != 'idle' or n['onboard'] is not False]
assert not bad, f"非 idle/onboard: {bad}"
d0 = sorted(n['id'] for n in items if n['domain'] == 0)
assert len(d0) == FH, d0
print(f"G3 OK: {NC} idle, domain0 ={d0}")
EOF
gate S4 PASS "$NODE_COUNT 台入池全 idle"
