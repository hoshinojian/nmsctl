#!/bin/bash
# S4 入池：vpsctl 导出载荷 → 后处理（剔 NMS/root/密码/domain/唯一性）→ POST /topology → G3
# T3 必改（scale-coldstart-churn-plan §一 T3）：
#   - domain 标注改显式清单：第一跳区域（FIRST_HOP_REGION，v3.4 票 5 参数化，缺省 sgp1）
#     批次内按名称排序取前 FIRST_HOP_COUNT 台 domain0、其余 domain1；选取清单落盘 evidence 供审计；
#   - 断言 domain0==9 / domain1==55、总数 64、区域计数与 s3 落盘分布表一致；28→64 参数化。
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/rebuild
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）
cd "$REBUILD_DIR"
mkdir -p "$EVIDENCE/s4"
exec > >(tee "$EVIDENCE/s4/log.txt") 2>&1

check_egress
log "导出 NMS 载荷（tag=env:soak，-ssh-port=$SSHD_PORT 显式携带高位口——产品导入缺省回退 22，漏带即死台账；预检跳过：编排机直探受 TUN 干扰不可靠）"
"$VPSCTL" list -format nms -no-check-ssh -ssh-port "$SSHD_PORT" -tag env:soak -output "$EVIDENCE/s4/raw-payload.json" > /dev/null

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

# T3 必改：domain 显式清单——第一跳区域（FIRST_HOP_REGION，v3.4 票 5 参数化——原硬编码
# 'sgp1'；档位几何首跳区可换，缺省 sgp1 保持 79 台主几何口径）批次内按名称排序取前 FH 台
# domain0，其余全部 domain1
fh_region = os.environ.get('FIRST_HOP_REGION', 'sgp1')
assert fh_region.replace('-', '').replace('_', '').isalnum(), f'FIRST_HOP_REGION 非法: {fh_region!r}'
fh_sorted = sorted((n for n in nodes if n['region'] == fh_region), key=lambda n: n['name'])
assert len(fh_sorted) >= FH, f"{fh_region} 只有 {len(fh_sorted)} 台，不足第一跳配额 {FH}"
domain0_ids = {n['id'] for n in fh_sorted[:FH]}
json.dump({"rule": f"{fh_region} 按名称排序前 {FH} 台 domain0，其余 domain1",
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
log "导入前快照（D2：全集口径断言仅在 NMS 侧为空=全新导入时启用，续跑免挂）"
api GET /nodes > "$EVIDENCE/s4/nodes-before-import.json"
ssh $SSHOPT -p "$SSHD_PORT" "root@$(nms_ip)" \
  "curl -sS -m 60 -X POST -H 'Content-Type: application/json' --data-binary @- http://$NMS_API_ADDR:80/api/v1/topology" \
  < "$EVIDENCE/s4/import-payload.json" > "$EVIDENCE/s4/import-resp.json"
cat "$EVIDENCE/s4/import-resp.json"; echo
python3 -c "
import json, os; d=json.load(open('evidence/s4/import-resp.json'))
assert d.get('status') == 'imported' and d.get('nodes') == int(os.environ['NODE_COUNT']), d
print('import resp OK')"

log "G3 断言（D2 状态无关化）：payload id 集为准——入库齐全 + domain 对齐审计件；全集状态分布只记录，全集口径断言仅全新导入启用"
api GET /nodes > "$EVIDENCE/s4/nodes-after-import.json"
python3 - <<'EOF'
import collections, json, os
NC = int(os.environ['NODE_COUNT'])
payload_ids = [n['id'] for n in json.load(open('evidence/s4/import-payload.json'))['nodes']]
before = json.load(open('evidence/s4/nodes-before-import.json'))['items']
after = json.load(open('evidence/s4/nodes-after-import.json'))['items']
by_id = {n['id']: n for n in after}

# 实质门①：payload 全部入库（总入库数==NC 已由 import resp 断言）
missing = [i for i in payload_ids if i not in by_id]
assert not missing, f"payload 未入库: {missing}"

# 实质门②：payload id 的 domain 标注对齐 domain0-selection.json 审计件
d0sel = set(json.load(open('evidence/s4/domain0-selection.json'))['domain0'])
mismatch = sorted(i for i in payload_ids if (by_id[i]['domain'] == 0) != (i in d0sel))
assert not mismatch, f"domain 标注与审计件不符: {mismatch}"

# 全集状态分布只记录不断言（D2）：续跑重导入会把在树 id 的 role 覆写回 idle
#（payload 不带 role，导入缺省 idle）而 onboard 不触碰——分布显形该设计内状态，留痕。
dist = dict(collections.Counter(f"role={n['role']}|onboard={n['onboard']}" for n in after))
fresh = len(before) == 0
json.dump({"fresh_import": fresh, "before": len(before), "after": len(after),
           "distribution": dist,
           "note": "续跑重导入 role 缺省覆写 idle、onboard 不触碰，属设计内状态（post-campaign-fixes-plan D2）"},
          open('evidence/s4/g3-distribution.json', 'w'), ensure_ascii=False, indent=1)

# 全集口径断言（「导入后全 idle∧onboard=false」全新库假设）仅在导入前为空时启用
if fresh:
    bad = [n['id'] for n in after if n['role'] != 'idle' or n['onboard'] is not False]
    assert not bad, f"非 idle/onboard: {bad}"
    print(f"G3 OK (fresh): {len(after)} 台全 idle ∧ onboard=false")
else:
    print(f"G3 OK (resume): payload {NC} 台入库齐全 ∧ domain 对齐审计件；全集分布（记录不断言）: {dist}")
EOF
# 凭据落库对账（v3.4 票 5：API 设计不回密码——04 契约密码不外显，故对账走 NMS 本机只读
# psql：未归档（deleted_at IS NULL——DELETE /nodes 为软删归档，行留档含密码不计入，ISS-012）
# 节点的 ssh_password 非空计数==NC；只读查询、无参数拼接，AGENTS「脚本 DB 只读」口径）
log "凭据落库对账（psql 只读：未归档 nodes.ssh_password 非空计数 == $NODE_COUNT）"
CRED_N=$(nms_ssh "docker exec nms-timescaledb psql -U nms -d nms -tAc \
  \"SELECT count(*) FROM nodes WHERE deleted_at IS NULL AND ssh_password IS NOT NULL AND ssh_password <> ''\"")
[ "$CRED_N" = "$NODE_COUNT" ] || gate S4 FAIL "凭据落库 $CRED_N != $NODE_COUNT（导入载荷密码段丢失？）"
log "凭据落库 $CRED_N/$NODE_COUNT ✓"

gate S4 PASS "$NODE_COUNT 台入池（D2 口径：payload id 集，状态无关）+凭据落库对账"
