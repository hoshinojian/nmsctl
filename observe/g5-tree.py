#!/usr/bin/env python3
"""G5' 树形不变量断言（T3：精确分布断言改不变量式，scale-coldstart-churn-plan §一 T3 / §二 G5'）。

断言集（全部参数化，旧「每 fh 出度恰 3 / 深度分布 9-16 / links==25」精确模式已删）：
  1. 全量 managed：nodes[] 恰 --nodes 台且 role 全 managed；
  2. 第一跳：深度 2 节点的父集合恰 --first-hop 个，且与「未挂进 tree.nodes 的节点」一一对应
     （有脱队节点或假第一跳即 FAIL）；第一跳全 managed；
  3. 出度：所有已挂接节点的出度 ≤ --child-budget；
  4. 深度：全部 ≤ --max-depth（缺省 4）；
  5. links 全物化：每个挂接节点恰一条入边且 source==parent，links 数 == 挂接节点数。
     注意 API 语义：links[] 只物化深度≥2 的边（28 台实证 links=25=tree.nodes，第一跳→root
     的边不在 links[]），故 64 台期望 55 条而非算术满树的 63 条——计划文中「63 条」为 N-1 口径。

用法: g5-tree.py <topology.json> <out-analysis.json> --nodes 64 --first-hop 9 --child-budget 3 [--max-depth 4]
"""
import argparse
import collections
import json
import sys

ap = argparse.ArgumentParser(description="G5' 树形不变量断言")
ap.add_argument('topology')
ap.add_argument('out')
ap.add_argument('--nodes', type=int, required=True, help='期望 managed 节点总数')
ap.add_argument('--first-hop', type=int, required=True, help='期望第一跳（深度 2 节点的父）数量')
ap.add_argument('--child-budget', type=int, required=True, help='单节点最大出度')
ap.add_argument('--max-depth', type=int, default=4, help='允许的最大深度（缺省 4）')
args = ap.parse_args()

t = json.load(open(args.topology))
nodes, links, tree = t['nodes'], t['links'], t['tree']
tree_nodes = tree['nodes']  # 只含 parent 非空（深度≥2）；第一跳只在 nodes[]

errors = []

# 1 全量 managed
if len(nodes) != args.nodes:
    errors.append(f"nodes 总数 {len(nodes)} != {args.nodes}")
not_managed = [n['id'] for n in nodes if n.get('role') != 'managed']
if not_managed:
    errors.append(f"非 managed: {not_managed}")

# id 唯一
ids = [n['id'] for n in tree_nodes]
dup = [k for k, v in collections.Counter(ids).items() if v > 1]
if dup:
    errors.append(f"tree.nodes id 重复: {dup}")

children = collections.Counter(n['parent'] for n in tree_nodes)
depths = collections.Counter(n['depth'] for n in tree_nodes)

# 2 第一跳——从权威台账字段 nodes[].domain==0 推导（契约：domain0 直连 NMS、不入 tree）。
# 不可从「depth=2 的 parent 集合」反推：R5 复活的第一跳合法地无子女（疏散子女去新父），
# 会被该推导漏计（2026-09-11 R5 五轮实测踩中）。
first_hops = {n['id'] for n in nodes if n.get('domain') == 0}
if len(first_hops) != args.first_hop:
    errors.append(f"第一跳 {len(first_hops)} != {args.first_hop}: {sorted(first_hops)}")
attached = {n['id'] for n in tree_nodes}
all_ids = {n['id'] for n in nodes}
detached = all_ids - attached
if detached != first_hops:
    errors.append(f"未挂树节点集 {sorted(detached)} != 第一跳集 {sorted(first_hops)}（存在脱队节点或假第一跳）")
fh_missing = first_hops - all_ids
if fh_missing:
    errors.append(f"第一跳不在 nodes[]（非 managed）: {sorted(fh_missing)}")

# 3 出度 ≤ child_budget
over = {p: c for p, c in children.items() if c > args.child_budget}
if over:
    errors.append(f"出度超 child_budget={args.child_budget}: {over}")

# 4 深度 ≤ max-depth
too_deep = {n['id']: n['depth'] for n in tree_nodes if n['depth'] > args.max_depth}
if too_deep:
    errors.append(f"深度超 {args.max_depth}: {too_deep}")
shallow = [n['id'] for n in tree_nodes if n['depth'] < 2]
if shallow:
    errors.append(f"tree.nodes 出现深度<2（该层节点应只在 nodes[]）: {shallow}")

# 5 links 全物化
link_by_target = collections.Counter(l['target'] for l in links)
for n in tree_nodes:
    if link_by_target[n['id']] != 1:
        errors.append(f"{n['id']} links 入边 {link_by_target[n['id']]} != 1")
    if not any(l['source'] == n['parent'] and l['target'] == n['id'] for l in links):
        errors.append(f"{n['id']} 无 ({n['parent']} -> {n['id']}) 边")
if len(links) != len(tree_nodes):
    errors.append(f"links {len(links)} != 挂接节点数 {len(tree_nodes)}（API 只物化深度≥2 的边，见 docstring）")

analysis = {
    "mode": "invariant",
    "params": {"nodes": args.nodes, "first_hop": args.first_hop,
               "child_budget": args.child_budget, "max_depth": args.max_depth},
    "managed_total": len(nodes),
    "attached": len(tree_nodes),
    "first_hops": sorted(first_hops),
    "depth_distribution": {str(k): v for k, v in sorted(depths.items())},
    "max_depth_seen": max(depths) if depths else None,
    "out_degree": dict(sorted(children.items())),
    "links": len(links),
    "errors": errors,
}
json.dump(analysis, open(args.out, 'w'), ensure_ascii=False, indent=1)
print(json.dumps(analysis, ensure_ascii=False, indent=1))
if errors:
    sys.exit(f"G5 FAIL: {len(errors)} 处违规")
print("G5' OK（不变量式）")
