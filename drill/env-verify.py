#!/usr/bin/env python3
"""env-verify.py — 环境↔代码对账器（用户 2026-09-21 口径：「判断当前环境和代码上的
环境是否能够配得上」；ISS-003 教训的泛化）。

职责分工：网络 IO 全在 live-snapshot.sh（bash，通道自适应）；本工具只读快照与
env.local 做逐项对账，任何 ✗ 即 exit 1：

  1 出口   快照实测出口 vs EGRES_EXPECT（漂移=✗——net-probe --apply 或开 DRILL_EGRES_AUTO）
  2 配置   s2 PUT 集（基础四键+DEPLOY_CONCURRENCY+BENCH_EXTRA_CONFIG）vs 快照 GET /config 实效
  3 台数   NODE_COUNT vs /nodes 台数；FIRST_HOP_COUNT vs domain=0 台数（NMS 未建按跳过/--require-live 计 ✗）
  4 树参   CHILD_BUDGET(env) vs config child_budget；G5_MAX_DEPTH(env) ≤ config max_depth
  5 防火墙 fw tcp 源 ⊇ {实测出口}

用法:
  python3 drill/env-verify.py [--root <SOAK_ENV>] [--refresh] [--require-live]
    --refresh     先调 live-snapshot.sh 重采快照（bash 子进程，路径为仓内常量）
    --require-live NMS 未建时活系统检查项计 ✗（s2 后必挂）；缺省跳过并注明
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent


def parse_env(path):
    env = {}
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        v = v.strip()
        if v.startswith(("'", '"')):
            q = v[0]
            v = v[1:v.find(q, 1)] if q in v[1:] else v[1:]
        else:
            v = v.split("#")[0].strip()
        env.setdefault(k.strip(), v)
    return env


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.environ.get("SOAK_ENV", ""),
                    help="运行时目录（含 env.local 与 evidence/）")
    ap.add_argument("--refresh", action="store_true", help="先重采活系统快照")
    ap.add_argument("--require-live", action="store_true")
    ap.add_argument("--no-fleet", action="store_true",
                    help="跳过 fleet 台数项（s2 后节点未建时用——Round2 实录：门原设 s2 后，"
                         "0/79 必红；台数检查归 s4 后的第二道门）")
    a = ap.parse_args()
    root = pathlib.Path(a.root).resolve() if a.root else None
    if not root or not root.is_dir() or not (root / "env.local").exists():
        sys.exit(f"ABORT: root 非实存运行时目录（须含 env.local）: {a.root!r}")

    if a.refresh:
        cp = subprocess.run(["bash", str(HERE / "live-snapshot.sh")],
                            capture_output=True, text=True)
        if cp.returncode != 0:
            sys.exit(f"live-snapshot 失败: {cp.stderr[:200]}")

    snap = root / "evidence" / "env-verify"
    env = parse_env(root / "env.local")
    rows, bad = [], []

    def row(name, ok, detail):
        rows.append((name, "✓" if ok else "✗", detail))
        if not ok:
            bad.append(name)

    # 1 出口
    eg = (snap / "egress.txt").read_text().strip() if (snap / "egress.txt").exists() else ""
    want_eg = env.get("EGRES_EXPECT", "")
    row("egress", bool(eg) and eg == want_eg,
        f"实测={eg or '不可达'} 期望={want_eg}" + ("" if eg == want_eg else "（漂移——net-probe --apply / DRILL_EGRES_AUTO=1）"))

    # 2/3 活系统（快照空文件=NMS 未建）
    cfg = nodes = None
    if (snap / "config.json").exists() and (snap / "config.json").stat().st_size > 0:
        cfg = json.loads((snap / "config.json").read_text())
        nodes = json.loads((snap / "nodes.json").read_text())
    if cfg is None:
        row("config", not a.require_live, "NMS 未建，跳过（--require-live 时计 ✗）")
        if not a.no_fleet:
            row("fleet", not a.require_live, "NMS 未建，跳过")
    else:
        want = {"child_budget": 3, "deploy_concurrency": int(env.get("DEPLOY_CONCURRENCY", "12")),
                "discover_concurrency": 16, "handshake_pace": 100, "resweep_interval": 60,
                "dial_timeout_ms": 20000}
        if env.get("BENCH_EXTRA_CONFIG"):
            want.update(json.loads("{" + env["BENCH_EXTRA_CONFIG"] + "}"))
        got = {i["key"]: i["value"] for i in cfg["items"]}
        diff = {k: (got.get(k), v) for k, v in want.items() if got.get(k) != v}
        row("config", not diff, f"{len(want)} 键 GET 实效全等" if not diff else f"不符: {diff}")

        if a.no_fleet:
            row("fleet", True, "按 --no-fleet 跳过（s2 门：节点未建，台数归 s4 后门）")
        else:
            items = nodes["items"]
            fh = sum(1 for n in items if n.get("domain") == 0)
            row("fleet", len(items) == int(env.get("NODE_COUNT", "-1")) and fh == int(env.get("FIRST_HOP_COUNT", "-1")),
                f"nodes={len(items)}/{env.get('NODE_COUNT')} domain0={fh}/{env.get('FIRST_HOP_COUNT')}")

        # 4 树参交叉
        cb_ok = got.get("child_budget") == int(env.get("CHILD_BUDGET", got.get("child_budget")))
        g5 = int(env.get("G5_MAX_DEPTH", "0"))
        md_ok = g5 == 0 or got.get("max_depth", 0) >= g5
        row("tree-params", cb_ok and md_ok,
            f"CHILD_BUDGET(env)={env.get('CHILD_BUDGET')} vs config={got.get('child_budget')}；"
            f"G5 门限={g5 or '-'} ≤ config max_depth={got.get('max_depth')}")

    # 5 防火墙（期望集=实测出口 ∪ DRILL_FW_EXTRA_SOURCES——附加稳定源缺任一即 ✗：
    #     attempt6 实录该键曾因未导出漏出 s2 塑形，防回归）
    fw = json.loads((snap / "fw-tcp-sources.json").read_text()) if (snap / "fw-tcp-sources.json").exists() else []
    extra = [x.strip() + "/32" for x in env.get("DRILL_FW_EXTRA_SOURCES", "").split(",") if x.strip()]
    want_srcs = ({f"{eg}/32"} if eg else set()) | set(extra)
    fw_ok = bool(eg) and want_srcs and want_srcs <= set(fw)
    row("firewall", fw_ok,
        f"tcp 源={fw} 期望集={sorted(want_srcs) if want_srcs else '?'}——"
        + ("全在列" if fw_ok else "缺失"))

    print(f"== env-verify（root={root} require-live={a.require_live}）==")
    for name, mark, detail in rows:
        print(f"  {mark} {name:12} {detail}")
    if bad:
        print(f"== 不配位 {len(bad)} 项：{bad} ==")
        sys.exit(1)
    print("== 环境↔代码全配位 ==")
    sys.exit(0)


if __name__ == "__main__":
    main()
