#!/usr/bin/env python3
"""health-gate.py — R+L 演练三级健康闸（票 0-9，规划 §4 第 9 项 / §0 运行口径 1）。

三级（--level；窗口宽度内联在各调用点的字面量 argv 里，不经 CLI、不经变量拼接——
subprocess.run 逐调用点内联全字面量 argv，无包装间接层）：
  scene  轻量：journal 窗口扫描（panic/「无可用备选父」签名/ERROR 计数）+ 活跃告警计数；
  wave   scene + DB 面：节点 role/status/collection_state 分布、孤儿/pending、在飞 dispatch、
         metrics 增量与 metrics_hourly 水位、bgw job 无 failed、长锁等待、连接数、迁移版本；
  round  wave + 全量 log（journal 全量而非窗）+ 24h 审计行数对账（SYS-14 锚，首轮校准期
         WARN 不 FAIL）。

纪律：
  - DB 只读 + 参数绑定：psql 变量经 SQL 文件头部 `\\set` 注入、查询里 :'var' 字面量转义；
    SQL 一律落盘文件经 stdin 喂 docker exec -i（P86：多层 shell 禁 heredoc 直拼）；
  - 子进程逐调用点内联字面量 argv（P86 每语句可见输出的同款取向）：ssh 经同目录
    nms-ssh.sh 包装（目标 IP 的读取与 IPv4 字面量校验在包装脚本内，证据根经
    DRILL_EVIDENCE_ROOT 环境变量传递）。改窗宽=改各调用点的内联字面量+本 docstring；
  - 证据：每查询输出落 evidence/health/<level>-<ts>/；结束进程内写一行 verdict JSONL
    （rl-drill-verdict/1，scenario=health-gate-<level>，carrier=非矩阵；八字段哈希复用
    observe/verdict.py）；
  - --fixture-dir <dir>：干跑模式——alerts/nodes 从本地 JSON 读、ssh/psql 全跳过
    （票 0-5 DRY_RUN 用；输出仍走同一断言链）。

FAIL 即 exit 1（除注明的 WARN 项）；--expect-converged 要求全 fleet
managed/online/collection_ok（轮/波建议开，场景级默认关）。

用法:
  python3 drill/health-gate.py --level wave \
      [--expect-converged] [--expect-zero-alerts] [--evidence-root ~/nms-r-drill-20260920] \
      [--fixture-dir fixture] [--commit <hash>] [--notes …]
"""
import argparse
import datetime
import json
import os
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "observe"))
import verdict as verdict_mod  # noqa: E402  复用八字段哈希（与 verdict.py 同仓同构）

WRAPPER = str(HERE / "nms-ssh.sh")  # ssh 包装（IP 读取+校验在包装内；DRILL_EVIDENCE_ROOT）
API_BASE = os.environ.get("NMS_API_ADDR", "10.100.0.1") + ":80"  # v3.4：API 腿=WG 隧道地址（80 单绑）
QUERIES = {  # 全只读；role/orphaned 在 nodes、status/collection_state 在 node_latest_state（Round1 轮末闸实录：nodes 表无此二列）；:lag/:lockwait/:since 经头部 \set 绑定（:'var' 字面量转义）
    "nodes_distribution": ("SELECT n.role,nls.status,nls.collection_state,count(*) FROM nodes n "
                           "JOIN node_latest_state nls ON nls.node_id=n.id "
                           "WHERE n.deleted_at IS NULL GROUP BY 1,2,3 ORDER BY 4 DESC;"),
    "orphans_pending": "SELECT count(*) FILTER (WHERE orphaned_at IS NOT NULL), count(*) FILTER (WHERE role='idle'), count(*) FILTER (WHERE role='provisioning') FROM nodes;",
    "dispatch_inflight": "SELECT status,count(*) FROM dispatch_tasks WHERE status IN ('pending','running') GROUP BY 1;",
    "metrics_freshness": ("\\set lag 45min\n"
                          "SELECT coalesce(max(ts)::text,'none'), count(*) FROM metrics WHERE ts > now() - :'lag'::interval;"),
    "cagg_watermark": "SELECT coalesce(max(bucket)::text,'none') FROM metrics_hourly;",
    "bgw_jobs": ("SELECT j.job_id::text, j.application_name, "
                 "COALESCE(s.last_run_status,'-'), COALESCE(s.job_status,'-') "
                 "FROM timescaledb_information.jobs j "
                 "LEFT JOIN timescaledb_information.job_stats s ON s.job_id=j.job_id;"),
    "lock_waits": ("\\set lockwait 10s\n"
                   "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND state='active' AND now()-query_start > :'lockwait'::interval;"),
    "conn_count": "SELECT count(*) FROM pg_stat_activity WHERE datname='nms';",
    "migration_version": "SELECT version FROM schema_migrations;",
    "audit_rows": ("\\set since 24h\n"
                   "SELECT count(*) FROM audit_log WHERE ts >= now() - :'since'::interval;"),
}


class Gate:
    def __init__(self, a):
        self.a = a
        self.fails, self.warns, self.evidence = [], [], {}

    def record(self, name, value):
        self.evidence[name] = value

    def check(self, ok, msg_fail, warn=False):
        if not ok:
            (self.warns if warn else self.fails).append(msg_fail)

    def tail_count(self, cp):
        lines = cp.stdout.strip().splitlines()
        return lines[-1] if lines else "0"

    def journal_counts(self):
        """journal 四签名计数：scene=30min 窗 / wave=2h 窗 / round=全量（字面量内联）。"""
        if self.a.level == "round":
            panic = self.tail_count(subprocess.run(
                ["bash", WRAPPER, "journalctl", "-u", "nms", "--no-pager", "|", "grep", "-c", "panic", ";", "true"],
                capture_output=True, text=True))
            nocand = self.tail_count(subprocess.run(
                ["bash", WRAPPER, "journalctl", "-u", "nms", "--no-pager", "|", "grep", "-c", "无可用备选父", ";", "true"],
                capture_output=True, text=True))
            errlv = self.tail_count(subprocess.run(
                ["bash", WRAPPER, "journalctl", "-u", "nms", "--no-pager", "|", "grep", "-c", "level=ERROR", ";", "true"],
                capture_output=True, text=True))
            audit = self.tail_count(subprocess.run(
                ["bash", WRAPPER, "journalctl", "-u", "nms", "--no-pager", "|", "grep", "-c", "audit", ";", "true"],
                capture_output=True, text=True))
        elif self.a.level == "wave":
            panic = self.tail_count(subprocess.run(
                ["bash", WRAPPER, "journalctl", "-u", "nms", "--no-pager", "--since", "-2h", "|", "grep", "-c", "panic", ";", "true"],
                capture_output=True, text=True))
            nocand = self.tail_count(subprocess.run(
                ["bash", WRAPPER, "journalctl", "-u", "nms", "--no-pager", "--since", "-2h", "|", "grep", "-c", "无可用备选父", ";", "true"],
                capture_output=True, text=True))
            errlv = self.tail_count(subprocess.run(
                ["bash", WRAPPER, "journalctl", "-u", "nms", "--no-pager", "--since", "-2h", "|", "grep", "-c", "level=ERROR", ";", "true"],
                capture_output=True, text=True))
            audit = self.tail_count(subprocess.run(
                ["bash", WRAPPER, "journalctl", "-u", "nms", "--no-pager", "--since", "-2h", "|", "grep", "-c", "audit", ";", "true"],
                capture_output=True, text=True))
        else:
            panic = self.tail_count(subprocess.run(
                ["bash", WRAPPER, "journalctl", "-u", "nms", "--no-pager", "--since", "-30min", "|", "grep", "-c", "panic", ";", "true"],
                capture_output=True, text=True))
            nocand = self.tail_count(subprocess.run(
                ["bash", WRAPPER, "journalctl", "-u", "nms", "--no-pager", "--since", "-30min", "|", "grep", "-c", "无可用备选父", ";", "true"],
                capture_output=True, text=True))
            errlv = self.tail_count(subprocess.run(
                ["bash", WRAPPER, "journalctl", "-u", "nms", "--no-pager", "--since", "-30min", "|", "grep", "-c", "level=ERROR", ";", "true"],
                capture_output=True, text=True))
            audit = self.tail_count(subprocess.run(
                ["bash", WRAPPER, "journalctl", "-u", "nms", "--no-pager", "--since", "-30min", "|", "grep", "-c", "audit", ";", "true"],
                capture_output=True, text=True))
        out = {"panic": panic, "nocandidate_signature": nocand,
               "error_level": errlv, "audit_lines": audit}
        for k, v in out.items():
            self.record(f"log_{k}", v)
        return out

    def psql(self, name):
        f = self.evdir / f"{name}.sql"
        f.write_text(QUERIES[name] + "\n")
        cp = subprocess.run(
            # -F'|'：分隔符字面量穿远端 shell（裸 | 会被当管道，Round1 轮末闸实录）
            ["bash", WRAPPER, "docker", "exec", "-i", "nms-timescaledb",
             "psql", "-U", "nms", "-d", "nms", "-X", "-v", "ON_ERROR_STOP=1", "-At", "-F'|'"],
            stdin=open(f, "rb"), capture_output=True, text=True)
        if cp.returncode != 0:
            raise RuntimeError(f"psql {name} 失败: {cp.stderr[:200]}")
        self.record(name, cp.stdout.strip())
        return cp.stdout.strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--level", required=True, choices=["scene", "wave", "round"])
    ap.add_argument("--expect-converged", action="store_true")
    ap.add_argument("--expect-zero-alerts", action="store_true")
    ap.add_argument("--pool-max", type=int, default=0, help="连接池上限（>0 才断言；0=只记录）")
    ap.add_argument("--evidence-root", default=os.path.expanduser("~/nms-r-drill-20260920"))
    ap.add_argument("--fixture-dir", default=None, help="干跑：alerts/nodes 读本地 JSON，跳过 ssh/psql")
    ap.add_argument("--commit", default="unknown")
    ap.add_argument("--notes", default="")
    a = ap.parse_args()
    os.environ["DRILL_EVIDENCE_ROOT"] = a.evidence_root  # nms-ssh.sh 读；不进任何命令 argv

    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    g = Gate(a)
    g.evdir = (pathlib.Path(a.fixture_dir, "health-out") if a.fixture_dir
               else pathlib.Path(a.evidence_root, "evidence", "health", f"{a.level}-{ts}"))
    g.evdir.mkdir(parents=True, exist_ok=True)

    # ---- log 面（scene 起；round 全量）----
    logs = g.journal_counts()
    g.check(logs["panic"] == "0", f"journal 窗口 panic {logs['panic']} 次")
    g.check(logs["nocandidate_signature"] == "0",
            f"「无可用备选父」签名 {logs['nocandidate_signature']} 次（T2 判据）")

    # ---- 告警面（API；fixture 可替代）----
    fx = pathlib.Path(a.fixture_dir, "alerts.json") if a.fixture_dir else None
    if fx and fx.exists():
        alerts = json.loads(fx.read_text())
    else:
        cp = subprocess.run(["bash", WRAPPER, "curl", "-sS", "-m", "30",
                             f"http://{API_BASE}/api/v1/alerts?status=active&limit=200"],
                            capture_output=True, text=True)
        alerts = json.loads(cp.stdout)
    n_active = int(alerts.get("total", len(alerts.get("items", []))))
    g.record("alerts_active_total", n_active)
    if a.expect_zero_alerts:
        g.check(n_active == 0,
                f"活跃告警 {n_active} 条（预期 0）：{[i.get('alert_type') for i in alerts.get('items', [])][:8]}")

    # ---- 节点分布（API；wave 起）----
    if a.level in ("wave", "round"):
        fx = pathlib.Path(a.fixture_dir, "nodes.json") if a.fixture_dir else None
        if fx and fx.exists():
            items = json.loads(fx.read_text()).get("items", [])
        else:
            cp = subprocess.run(["bash", WRAPPER, "curl", "-sS", "-m", "30",
                                 f"http://{API_BASE}/api/v1/nodes"], capture_output=True, text=True)
            items = json.loads(cp.stdout).get("items", [])
        dist = {}
        for n in items:
            k = f"{n.get('role')}|{n.get('status')}|{n.get('collection_state')}"
            dist[k] = dist.get(k, 0) + 1
        g.record("nodes_distribution_api", dist)
        g.record("nodes_total", len(items))
        if a.expect_converged:
            bad = {k: v for k, v in dist.items() if k != "managed|online|collection_ok"}
            g.check(not bad, f"未收敛分布 {bad}")

    # ---- DB 面（wave/round；fixture 模式跳过）----
    if a.level in ("wave", "round") and not a.fixture_dir:
        g.psql("nodes_distribution")
        g.psql("orphans_pending")
        g.psql("dispatch_inflight")
        g.psql("metrics_freshness")
        latest, cnt = (g.evidence["metrics_freshness"].split("|") + ["0", "0"])[:2]
        g.check(latest != "none" and int(cnt) > 0, "metrics 窗口零增量（lag=45min）")
        g.psql("cagg_watermark")
        g.psql("bgw_jobs")
        bad_jobs = [l for l in g.evidence["bgw_jobs"].splitlines()
                    if any(x.strip() in ("failed", "error", "crashed") for x in l.split("|"))]
        g.check(not bad_jobs, f"bgw job 非 success：{bad_jobs}")
        g.psql("lock_waits")
        g.check(g.evidence["lock_waits"] == "0", f"长锁等待 {g.evidence['lock_waits']} 条（>10s）")
        g.psql("conn_count")
        if a.pool_max > 0:
            g.check(int(g.evidence["conn_count"]) <= a.pool_max,
                    f"连接数 {g.evidence['conn_count']} > 池上限 {a.pool_max}")
        g.psql("migration_version")
        mig_dir = pathlib.Path(os.environ.get("NMS2_REPO", os.path.expanduser("~/NMS2")), "db/migrations")
        expected = max(int(p.name.split("_")[0]) for p in mig_dir.glob("[0-9]*_*.up.sql"))
        g.check(int(g.evidence["migration_version"]) == expected,
                f"迁移版本 {g.evidence['migration_version']} != 仓内最新 {expected}（真机只跑 MigrateUp，#23）")
        if a.level == "round":
            g.psql("audit_rows")
            db_audit = int(g.evidence["audit_rows"])
            j_audit = int(logs.get("audit_lines", "0"))
            # SYS-14 锚：DB audit 行 vs journal audit 行——首轮校准期 WARN 不 FAIL
            g.check(db_audit >= j_audit or j_audit == 0,
                    f"审计对账异常：journal {j_audit} > DB {db_audit}（SYS-14 锚）", warn=True)

    # ---- 落证据 + verdict 行（进程内写，schema 同 observe/verdict.py）----
    report = {"level": a.level, "ts": ts, "checks": g.evidence,
              "fails": g.fails, "warns": g.warns, "verdict": "FAIL" if g.fails else "PASS"}
    (g.evdir / "health-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=1))
    print(json.dumps(report, ensure_ascii=False, indent=1))
    rb = {
        "inject": f"level={a.level}", "proof_before": "gate 输入参数",
        "proof_effective": "queries/greps 见 checks", "exercise": "health-gate.py",
        "observe": f"evidence/health/{a.level}-{ts}", "recover": "n/a（只读闸）",
        "proof_after": "report verdict", "cleanup": "无（只读）",
    }
    rec = {
        "schema": verdict_mod.SCHEMA, "carrier": "非矩阵（健康闸/静默窗等）",
        "scenario": f"health-gate-{a.level}", "case": None,
        "runbook_hash": verdict_mod.eight_field_hash(rb),
        "verdict": report["verdict"],
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "commit": a.commit, "evidence": [str(g.evdir)],
        "notes": a.notes or f"fails={len(g.fails)} warns={len(g.warns)}",
    }
    if not a.fixture_dir:
        out = pathlib.Path(a.evidence_root, "verdicts", "health.jsonl")
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "a") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    if g.fails:
        print(f"HEALTH GATE FAIL: {len(g.fails)} 条（{g.fails}）")
        sys.exit(1)
    print(f"HEALTH GATE PASS（level={a.level}；warns={g.warns}）")
    sys.exit(0)


if __name__ == "__main__":
    main()
