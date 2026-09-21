#!/usr/bin/env python3
"""verdict.py — R+L 演练 verdict JSONL 写入/校验（票 0-3）。

schema 见同目录 verdict-schema.md（rl-drill-verdict/1）。两个子命令：
  write  写一行 verdict（波脚本/churn r-lib 从 shell 调用；runbook 八字段哈希在此计算）
  check  校验一个/多个 JSONL 并聚合（任一违例 exit 1）

八字段哈希口径（与 schema 文档绑定，改=同步文档）：
  {inject, proof_before, proof_effective, exercise, observe, recover, proof_after, cleanup}
  → json.dumps(sort_keys=True, ensure_ascii=False, separators=(',', ':')) → sha256。

用法:
  python3 observe/verdict.py write <out.jsonl> --carrier "W-B 断链抖动" \
      --scenario ssh-14.1-sshd-stop-old-session --case SSH-14.1 \
      --runbook <八字段.json> --verdict PASS --commit <hash> \
      [--requestid <id>] [--evidence path ...] [--notes ...] \
      [--stage '{"phase":2,"rung":null,"attempt":1,"form":null}'   # 仅「阶梯点亮」载体 \
       --channel '{"nms_ssh_via":"auto","wg_handshake":null}']      # 任意载体，漂移回放
  python3 observe/verdict.py check <a.jsonl> [b.jsonl ...] [--cases cases.json]
"""
import argparse
import datetime
import hashlib
import json
import re
import sys

SCHEMA = "rl-drill-verdict/1"
CARRIERS = {  # 矩阵载体与 NMS2 scripts/dev/rl-drill-freeze.py R_CARRIERS/L 载体同名（跨仓约定）；
    # 非矩阵载体（阶梯/健康闸/静默窗）只在本表登记，不进冻结分母（freeze.py 只数矩阵载体）
    "W-A 树韧性疏散", "W-B 断链抖动", "W-C 容量共享", "W-D 生命周期真机",
    "W-E 指令阈值", "W-F 部署环境收口",
    "第一部分建树循环（SYS-01 以循环证据登记）", "SYS-15 真机全形态票",
    "SYS-16 24h 长静默窗",
    "L 本地（LIFE-AG-04/COLL-16/SSH-16/API-07）", "L 真机搭车", "非矩阵（健康闸/静默窗等）",
    "阶梯点亮（非矩阵）",  # v3.4.1 票 6：bring-up 阶梯 attempt 留痕载体（连续绿计数依据）
}
LADDER_CARRIER = "阶梯点亮（非矩阵）"
STAGE_FORMS = ("fresh", "resume")
TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
EIGHT_FIELDS = ("inject", "proof_before", "proof_effective", "exercise",
                "observe", "recover", "proof_after", "cleanup")
CASE_RE = re.compile(r"^[A-Z]+-\d+(\.\d+)?$")
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{7,40}$")


def parse_opt_json(flag_name: str, raw: str):
    """--stage/--channel 接受内联 JSON 或 @file（与 --runbook 同源数据）。"""
    try:
        text = open(raw[1:]).read() if raw.startswith("@") else raw
        return json.loads(text)
    except (OSError, json.JSONDecodeError) as e:
        sys.exit(f"ERROR: {flag_name} 解析失败（内联 JSON 或 @file）: {e}")


def eight_field_hash(runbook: dict) -> str:
    missing = [k for k in EIGHT_FIELDS if not str(runbook.get(k, "")).strip()]
    if missing:
        sys.exit(f"ERROR: runbook 八字段缺 {missing}（哈希分母不完整）")
    canon = {k: str(runbook[k]) for k in EIGHT_FIELDS}
    blob = json.dumps(canon, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(blob.encode()).hexdigest()


def cmd_write(a):
    runbook = json.loads(open(a.runbook).read())
    rec = {
        "schema": SCHEMA, "carrier": a.carrier, "scenario": a.scenario,
        "case": a.case, "runbook_hash": eight_field_hash(runbook),
        "verdict": a.verdict, "ts": datetime.datetime.now(datetime.timezone.utc)
                          .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "commit": a.commit, "evidence": a.evidence, "notes": a.notes,
    }
    if a.requestid:
        rec["requestid"] = a.requestid   # 不带=字段不出现（schema 规则 6）
    if a.stage:                          # 阶梯 attempt 留痕（票 6）——不进八字段哈希
        rec["stage"] = parse_opt_json("--stage", a.stage)
    if a.channel:                        # 通道漂移回放（票 6）——不进八字段哈希
        rec["channel"] = parse_opt_json("--channel", a.channel)
    if a.verdict == "SKIPPED_DUE_TO":
        rec["skipped_due_to"] = a.skipped_due_to or "UNSET"
    with open(a.out, "a") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print(f"verdict written: {a.scenario} {a.verdict} -> {a.out}")


def check_record(rec, cases, path, lineno, errs):
    def bad(msg):
        errs.append(f"{path}:{lineno}: {msg}")
    if rec.get("schema") != SCHEMA:
        bad(f"schema 标签 {rec.get('schema')!r} != {SCHEMA!r}")
    if rec.get("carrier") not in CARRIERS:
        bad(f"carrier {rec.get('carrier')!r} 不在已知载体集")
    if rec.get("verdict") not in ("PASS", "FAIL", "SKIPPED_DUE_TO"):
        bad(f"verdict {rec.get('verdict')!r} 非法")
    v = rec.get("verdict")
    if v == "SKIPPED_DUE_TO" and not str(rec.get("skipped_due_to", "")).strip():
        bad("SKIPPED_DUE_TO 缺 skipped_due_to")
    if v in ("PASS", "FAIL") and "skipped_due_to" in rec:
        bad(f"{v} 不得带 skipped_due_to")
    c = rec.get("case")
    if c is not None:
        if not CASE_RE.match(str(c)):
            bad(f"case {c!r} 不匹配 家族.变体 格式")
        elif cases is not None and str(c) not in cases:
            bad(f"case {c!r} 不在 cases.json variant_frozen")
    if not HASH_RE.match(str(rec.get("runbook_hash", ""))):
        bad(f"runbook_hash {rec.get('runbook_hash')!r} 非 sha256:<64hex>")
    if not COMMIT_RE.match(str(rec.get("commit", ""))):
        bad(f"commit {rec.get('commit')!r} 非 hex 短/全哈希")
    try:
        datetime.datetime.strptime(rec.get("ts", ""), "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        bad(f"ts {rec.get('ts')!r} 非 UTC ISO8601（…Z）")
    if "requestid" in rec and not str(rec["requestid"]).strip():
        bad("requestid 为空串——「不带」的语义是整字段不出现")
    ev = rec.get("evidence")
    if not isinstance(ev, list) or not ev or not all(isinstance(x, str) and x for x in ev):
        bad(f"evidence {ev!r} 须非空字符串列表")
    if not str(rec.get("scenario", "")).strip():
        bad("scenario 为空")


def check_stage_channel(rec, path, lineno, errs):
    """stage/channel 可选字段校验（v3.4.1 票 6；两字段均不入八字段哈希）。"""
    def bad(msg):
        errs.append(f"{path}:{lineno}: {msg}")
    st = rec.get("stage")
    if st is not None:
        if not isinstance(st, dict):
            bad(f"stage {st!r} 须为对象"); return
        if rec.get("carrier") != LADDER_CARRIER:
            bad(f"stage 仅 {LADDER_CARRIER!r} 载体可带（当前 {rec.get('carrier')!r}）")
        ph = st.get("phase")
        if not (isinstance(ph, int) and not isinstance(ph, bool) and 1 <= ph <= 5):
            bad(f"stage.phase {ph!r} 须为 1–5 整数（阶梯阶段）")
        at = st.get("attempt")
        if not (isinstance(at, int) and not isinstance(at, bool) and at >= 1):
            bad(f"stage.attempt {at!r} 须为 ≥1 整数（attempt 序号，连续绿计数依据）")
        rg = st.get("rung")
        if rg is not None and not (isinstance(rg, str) and rg):
            bad(f"stage.rung {rg!r} 须非空字符串或 null（档位：nms/5vps/1node/10node…）")
        fm = st.get("form")
        if fm is not None and fm not in STAGE_FORMS:
            bad(f"stage.form {fm!r} 须为 {'/'.join(STAGE_FORMS)} 或 null（s5 形态判定，P82）")
    ch = rec.get("channel")
    if ch is not None:
        if not isinstance(ch, dict):
            bad(f"channel {ch!r} 须为对象"); return
        via = ch.get("nms_ssh_via")
        if not (isinstance(via, str) and via):
            bad(f"channel.nms_ssh_via {via!r} 须非空字符串（auto/direct/stunnel443 实际生效值）")
        wg = ch.get("wg_handshake")
        if wg is not None and not (isinstance(wg, str) and TS_RE.match(wg)):
            bad(f"channel.wg_handshake {wg!r} 须 UTC ISO8601（…Z）或 null（wg show 最近握手）")


def cmd_check(a):
    cases = None
    if a.cases:
        frozen = set()
        for c in json.loads(open(a.cases).read())["case_families"]:
            fam = c["id"]
            for v in c.get("variant_frozen") or []:
                frozen.add(v.split(" ")[0])
        cases = frozen
    errs, agg, n = [], {}, 0
    for path in a.jsonl:
        for lineno, line in enumerate(open(path), 1):
            line = line.strip()
            if not line:
                continue
            n += 1
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as e:
                errs.append(f"{path}:{lineno}: JSON 解析失败 {e}")
                continue
            check_record(rec, cases, path, lineno, errs)
            check_stage_channel(rec, path, lineno, errs)
            key = (rec.get("carrier", "?"), rec.get("verdict", "?"))
            agg[key] = agg.get(key, 0) + 1
    print(f"== verdict check ==  文件 {len(a.jsonl)} 行 {n}")
    for (carrier, verdict), cnt in sorted(agg.items()):
        print(f"  {carrier}\t{verdict}\t{cnt}")
    if errs:
        print(f"== 违例 {len(errs)} 条 ==")
        for e in errs:
            print("  ✗", e)
        sys.exit(1)
    print("== 校验全过（schema/载体/枚举/case/哈希/ts/requestid 语义/evidence）==")
    sys.exit(0)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("write")
    w.add_argument("out")
    w.add_argument("--carrier", required=True)
    w.add_argument("--scenario", required=True)
    w.add_argument("--case", default=None)
    w.add_argument("--runbook", required=True, help="八字段 JSON 文件")
    w.add_argument("--verdict", required=True, choices=["PASS", "FAIL", "SKIPPED_DUE_TO"])
    w.add_argument("--commit", required=True)
    w.add_argument("--requestid", default=None)
    w.add_argument("--skipped-due-to", default=None)
    w.add_argument("--evidence", nargs="*", default=[])
    w.add_argument("--notes", default="")
    w.add_argument("--stage", default=None,
                   help='阶梯 attempt 结构化对象（内联 JSON 或 @file）：{"phase":1..5,"rung":"nms|5vps|1node|10node|null","attempt":N,"form":"fresh|resume|null"}——仅「阶梯点亮」载体可带')
    w.add_argument("--channel", default=None,
                   help='通道字段（内联 JSON 或 @file）：{"nms_ssh_via":"auto|direct|stunnel443","wg_handshake":"<UTC ISO8601>|null"}——任意载体可带，漂移可回放')
    c = sub.add_parser("check")
    c.add_argument("jsonl", nargs="+")
    c.add_argument("--cases", default=None, help="cases.json（校验 case 存在于 variant_frozen）")
    args = ap.parse_args()
    (cmd_write if args.cmd == "write" else cmd_check)(args)


if __name__ == "__main__":
    main()
