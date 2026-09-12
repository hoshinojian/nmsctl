#!/usr/bin/env python3
"""fixture 生成：假 topology JSON（64 台=9 第一跳 + 55 挂树，每 fh 出度 2-3（fh-04 为 2、
其余 3），深度 2=26 / 深度 3=29，深度 2 叶子 16 台，d2-01..09 各挂 3 子、d2-10 挂 2 子）。
形状与 G5' 实测树（evidence/s5/tree-analysis.json）同构，专供 r-select/DRY_RUN 干跑。
用法: make-fixture.py [输出路径]   # 缺省 tests/fixtures/topology-fixture.json
"""
import json
import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "fixtures", "topology-fixture.json")

REGION_D2 = ["nyc1", "lon1", "tor1", "blr1", "fra1", "syd1", "atl1", "sgp1", "nyc1"]
REGION_D3 = ["syd1"] * 5 + ["atl1"] * 3 + ["fra1"] * 5 + ["nyc1", "lon1", "tor1", "blr1"] * 4 + ["syd1", "atl1"]  # 29 台

nodes, tree = [], []

def add(nid, domain, region, parent=None, depth=None):
    nodes.append({"id": nid, "name": nid, "device_type": "vps",
                  "management_ip": f"10.0.0.{len(nodes) + 1}", "domain": domain,
                  "role": "managed", "region": region, "onboard": True})
    if parent is not None:
        tree.append({"id": nid, "depth": depth, "parent": parent,
                     "jumps": [parent, nid]})

for i in range(1, 10):                      # 9 第一跳（domain=0，只在 nodes[]）
    add(f"fh-{i:02d}", 0, "sgp1")
# 深度 2：26 台（fh-04 出度 2，其余 3）
FH_KIDS = {1: 3, 2: 3, 3: 3, 4: 2, 5: 3, 6: 3, 7: 3, 8: 3, 9: 3}
k = 1
for f in range(1, 10):
    for _ in range(FH_KIDS[f]):
        add(f"d2-{k:02d}", 1, REGION_D2[(k - 1) % len(REGION_D2)], f"fh-{f:02d}", 2)
        k += 1
assert k == 27, k
# 深度 3：29 台（d2-01..09 各 3 子、d2-10 2 子；d2-11..26 为叶子——深度 2 叶子 16 台）
k = 1
for d in range(1, 11):
    n_kids = 3 if d <= 9 else 2
    for _ in range(n_kids):
        add(f"d3-{k:02d}", 1, REGION_D3[(k - 1) % len(REGION_D3)], f"d2-{d:02d}", 3)
        k += 1
assert k == 30 and len(nodes) == 64 and len(tree) == 55, (k, len(nodes), len(tree))

os.makedirs(os.path.dirname(OUT), exist_ok=True)
json.dump({"nodes": nodes, "links": [{"source": t["parent"], "target": t["id"]} for t in tree],
           "tree": {"root": "nms", "nodes": tree}},
          open(OUT, "w"), ensure_ascii=False, indent=1)
print(f"fixture -> {OUT}（nodes={len(nodes)} links={len(tree)}，fh 出度 2-3）")
