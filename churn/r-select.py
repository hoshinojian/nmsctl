#!/usr/bin/env python3
"""r-select.py —— R1–R5 目标节点动态选取（唯一实现；脚本经 r-lib.sh r_select 调用，
亦可独立执行做 fixture 干跑）。

用法: r-select.py <scenario> <topology.json>   # scenario ∈ r1|r2|r3|r4|r5
输出: 单行 JSON（各场景 shape 不同，落 evidence/<R>/targets.json）

输入 = GET /topology 快照（04 §1.2）：
  nodes[]  全量节点（含 domain/region/role——第一跳=domain 0，只在 nodes[] 不在 tree.nodes）
  links[]  已物化边（深度≥2）
  tree.nodes[]  挂树节点 {id, depth, parent, jumps}

选取规则（scale-coldstart-churn-plan §三）：
  r1  深度 3 叶子优先；无深度 3 叶子时回退最深叶子（fallback_used=true 记入输出）
  r2  8 台深度 ≥2 叶子、跨 ≥2 个不同父；syd1/atl1/fra1 深路径优先非硬性
  r3  「子女最多的深度 2 节点」（2-3 皆可，child_budget=3 下至多 3）
  r4  三台互异：provision/flip 用深度 ≥2 叶子，guard 用一台第一跳（domain=0）
  r5  第一跳（domain=0）优先取出度 ≥2 者
全部确定性（排序 + id 决胜），不写死主机名。
"""
import collections
import json
import sys

PREFERRED_REGIONS = ("syd1", "atl1", "fra1")  # R2 深路径优先区（非硬性）


def load(path):
    t = json.load(open(path))
    return t["nodes"], t.get("links", []), t["tree"]["nodes"]


def build(nodes, tree_nodes):
    """返回: by_id, children(直接子女), descendants(全部后代), attached ids"""
    by_id = {n["id"]: n for n in nodes}
    kids = collections.defaultdict(list)
    for tn in tree_nodes:
        kids[tn["parent"]].append(tn["id"])
    attached = {n["id"] for n in tree_nodes}

    def descendants(nid):
        out, stack = [], list(kids.get(nid, []))
        while stack:
            x = stack.pop()
            out.append(x)
            stack.extend(kids.get(x, []))
        return out

    depth = {n["id"]: n["depth"] for n in tree_nodes}
    parent = {n["id"]: n["parent"] for n in tree_nodes}
    return by_id, kids, descendants, attached, depth, parent


def sel_r1(nodes, tree_nodes):
    by_id, kids, desc, attached, depth, parent = build(nodes, tree_nodes)
    leaf = lambda i: not kids.get(i)
    pool = sorted(i for i in attached if depth[i] == 3 and leaf(i))
    fallback = False
    if not pool:  # 回退：最深叶子（记录偏差，不静默降级）
        maxd = max(depth.values())
        pool = sorted(i for i in attached if depth[i] == maxd and leaf(i))
        fallback = True
        assert pool, "树中不存在叶子（每台都有子女）——r1 无合法目标"
    tid = pool[0]
    return {"scenario": "r1", "target": tid, "depth": depth[tid], "parent": parent[tid],
            "fallback_used": fallback, "pool_size": len(pool)}


def sel_r2(nodes, tree_nodes):
    by_id, kids, desc, attached, depth, parent = build(nodes, tree_nodes)
    n_take = 8
    leaf = lambda i: not kids.get(i)
    deep_leaves = [i for i in attached if depth[i] >= 2 and leaf(i)]
    pref = [i for i in deep_leaves if (by_id.get(i, {}).get("region") or "").startswith(PREFERRED_REGIONS)]
    rest = sorted(set(deep_leaves) - set(pref))
    # 优先区在前（id 序），其余区在后（id 序）——确定性
    ordered = sorted(pref) + rest
    assert len(ordered) >= n_take, f"深度≥2 叶子仅 {len(ordered)} 台，不足 {n_take}"
    picked = ordered[:n_take]
    parents = {parent[i] for i in picked}
    assert len(parents) >= 2, f"8 台目标仅跨 {len(parents)} 个父（要求 ≥2）"
    return {"scenario": "r2", "targets": picked,
            "parents": sorted(parents),
            "regions": {i: by_id.get(i, {}).get("region") for i in picked},
            "preferred_region_hits": sorted(pref) and [i for i in picked if i in set(pref)]}


def sel_r3(nodes, tree_nodes):
    by_id, kids, desc, attached, depth, parent = build(nodes, tree_nodes)
    d2 = sorted(i for i in attached if depth[i] == 2)
    assert d2, "无深度 2 节点"
    # 子女最多的深度 2 节点；并列取后代多者，再取 id 序
    best = max(d2, key=lambda i: (len(kids.get(i, [])), len(desc(i)), [ord(c) for c in i]))
    nk = len(kids.get(best, []))
    assert nk >= 1, f"选中的深度 2 节点 {best} 无子女（场景无意义）"
    return {"scenario": "r3", "target": best, "depth": depth[best],
            "children": sorted(kids.get(best, [])),
            "descendants": sorted(desc(best), key=lambda x: (-depth[x], x)),
            "children_count": nk}


def sel_r4(nodes, tree_nodes):
    by_id, kids, desc, attached, depth, parent = build(nodes, tree_nodes)
    leaf = lambda i: not kids.get(i)
    deep_leaves = sorted((i for i in attached if depth[i] >= 2 and leaf(i)),
                         key=lambda i: (-depth[i], i))
    assert len(deep_leaves) >= 2, "深度≥2 叶子不足 2 台（r4 需要 provision/flip 两台）"
    fhs = sorted(n["id"] for n in nodes if n.get("domain") == 0)
    assert fhs, "无第一跳（domain=0）"
    a, b = deep_leaves[0], deep_leaves[1]
    return {"scenario": "r4", "provision_target": a, "flip_target": b,
            "guard_live_target": fhs[0], "depths": {a: depth[a], b: depth[b]}}


def sel_r5(nodes, tree_nodes):
    by_id, kids, desc, attached, depth, parent = build(nodes, tree_nodes)
    fhs = [n["id"] for n in nodes if n.get("domain") == 0]
    assert fhs, "无第一跳（domain=0）"
    # 出度 ≥2 优先（T2 疏散样本有意义），再取出度大者，id 决胜
    best = max(sorted(fhs), key=lambda i: (len(kids.get(i, [])) >= 2, len(kids.get(i, [])), [ord(c) for c in i]))
    kids_n = len(kids.get(best, []))
    assert kids_n >= 1, f"第一跳 {best} 无挂树子女（疏散面为空，场景退化）"
    return {"scenario": "r5", "target": best, "domain": 0,
            "out_degree": kids_n, "children": sorted(kids.get(best, [])),
            "descendants": sorted(desc(best), key=lambda x: (-depth[x], x))}


SEL = {"r1": sel_r1, "r2": sel_r2, "r3": sel_r3, "r4": sel_r4, "r5": sel_r5}


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    scenario, path = sys.argv[1], sys.argv[2]
    nodes, links, tree_nodes = load(path)
    out = SEL[scenario](nodes, tree_nodes)
    out["links_total"] = len(links)
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
