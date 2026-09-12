# r-lib.sh —— R1–R5 二阶段扰动公共库（source 前必须先 export R_SCENARIO=R1..R5）
# 依赖 lib/env.sh（api/nms_ssh/check_egress/log/NODE_COUNT/FIRST_HOP_COUNT/CHILD_BUDGET/NODE_PASS）。
# 纪律：P68 check_egress 开头；场景边界 journal 落盘；禁手工 SQL（P66）；断言失败非零退出
# + 现场落盘 evidence/<场景>/fail/；正常落 verdict.json（soak-rebuild-churn-plan §四）。
#
# DRY_RUN 模式（fixture 干跑，无任何 DO/NMS API / ssh 调用）：
#   DRY_RUN=1 R_TOPO_FILE=<topology.json> bash rX-*.sh
#   - 跳过 check_egress 与一切 api()/nms_ssh()；
#   - 目标选取从 R_TOPO_FILE 读（缺省 tests/fixtures/topology-fixture.json）；
#   - 证据根切到 tests/dryrun/evidence/（不污染真实 evidence/）。
# TARGETS_FILE 注入：R_TARGETS_FILE=<targets.json> 跳过脚本内选取，直接用给定目标
#   （r-select.py 的输出格式；供干跑与人工指定目标复用同一通道）。

R_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN="${DRY_RUN:-0}"

if [ "$DRY_RUN" = "1" ]; then
  export R_EVIDENCE_ROOT="$R_LIB_DIR/tests/dryrun/evidence"
else
  export R_EVIDENCE_ROOT="$EVIDENCE"
fi
R_DIR="$R_EVIDENCE_ROOT/${R_SCENARIO}"
mkdir -p "$R_DIR"
exec > >(tee "$R_DIR/log.txt") 2>&1

R_T0=$(date +%s)
R_STARTED_AT=$(date -u +%FT%TZ)
# journal 签名 grep 的场景起点——取 NMS 服务器时钟（journalctl --since 对服务器时钟比较，
# 本地/服务器钟差会把历史签名行误卷入或把场景行滤掉——R5 零签名判据必须时钟同源）。
# DRY_RUN 禁一切网络调用（含 ssh），直接用本地时钟（仅干跑语义，不影响正式波次）。
if [ "$DRY_RUN" != "1" ]; then
  R_SINCE=$(nms_ssh "date -u '+%Y-%m-%dT%H:%M:%SZ'" 2>/dev/null) || R_SINCE=""
  R_SINCE="${R_SINCE:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"   # 服务器时钟不可得时退回本地（journal-start 已留全量尾巴）
else
  R_SINCE=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
fi
R_ASSERTS="$R_DIR/asserts.jsonl"; : > "$R_ASSERTS"
R_NOTES="$R_DIR/notes.txt"; : > "$R_NOTES"
R_CODE_BODY="$R_DIR/last-resp.json"
R_CODE=""
R_TIMINGS_JSON="$R_DIR/timings.json"; echo '{}' > "$R_TIMINGS_JSON"

if [ "$DRY_RUN" != "1" ]; then
  check_egress   # P68：出口 IP 必须 = fw 白名单，否则中止一切
fi
log "[$R_SCENARIO] start（DRY_RUN=$DRY_RUN since=$R_SINCE evidence=$R_DIR）"
# 场景边界 journal 尾部落盘（双保险；签名检索一律 --since $R_SINCE 防历史误匹配）
if [ "$DRY_RUN" != "1" ]; then
  nms_ssh 'journalctl -u nms --no-pager | tail -200' > "$R_DIR/journal-start.log" 2>/dev/null || true
fi

# ---------- 断言与结论 ----------
r_note() { # r_note <文本> —— 记入 notes（进 verdict）与日志
  echo "$1" | tee -a "$R_NOTES"
}
r_assert() { # r_assert <名称> <ok:0/1> <明细> —— 记录型断言（不中止）
  local name=$1 ok=$2 detail=$3
  printf '{"name":%s,"ok":%s,"detail":%s}\n' \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$name")" \
    "$ok" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$detail")" >> "$R_ASSERTS"
  if [ "$ok" = "1" ]; then log "  ASSERT OK  $name — $detail"; else log "  ASSERT FAIL $name — $detail"; fi
}
r_fatal() { # r_fatal <名称> <明细> —— 断言失败：落盘现场 → verdict fail → 非零退出
  r_assert "$1" 0 "$2"
  r_fail "assertion failed: $1 — $2"
}
r_fail() { # r_fail <原因> —— fail 路径唯一出口（现场 evidence/<R>/fail/ + verdict）
  local reason=$1
  log "[$R_SCENARIO] FAIL — $reason（落盘现场）"
  if [ "$DRY_RUN" != "1" ]; then
    mkdir -p "$R_DIR/fail"
    r_api_get /nodes                             "$R_DIR/fail/nodes.json"        2>/dev/null || true
    r_api_get /topology                          "$R_DIR/fail/topology.json"     2>/dev/null || true
    r_api_get "/alerts?status=active&limit=200"  "$R_DIR/fail/alerts-active.json" 2>/dev/null || true
    r_api_get "/agent-deploy?limit=20"           "$R_DIR/fail/agent-deploy.json" 2>/dev/null || true
    nms_ssh "journalctl -u nms --since '$R_SINCE' --no-pager | tail -2000" \
      > "$R_DIR/fail/journal-since-start.log" 2>/dev/null || true
    nms_ssh 'journalctl -u nms --no-pager | tail -300' > "$R_DIR/fail/journal-tail.log" 2>/dev/null || true
    echo "reason: $reason" > "$R_DIR/fail/README.txt"
  fi
  r_verdict fail "$reason"
  exit 1
}

r_verdict() { # r_verdict <pass|fail> <摘要> —— 汇总 asserts/notes/timings/targets 落 verdict.json
  local verdict=$1 summary=$2
  R_T1=$(date +%s)
  python3 - "$R_SCENARIO" "$verdict" "$summary" "$R_STARTED_AT" "$R_DIR" "$((R_T1 - R_T0))" <<'PYEOF'
import json, os, sys
scenario, verdict, summary, started, rdir, dur = sys.argv[1:7]
asserts = [json.loads(l) for l in open(f'{rdir}/asserts.jsonl') if l.strip()]
notes = [l.rstrip('\n') for l in open(f'{rdir}/notes.txt') if l.strip()]
def load(name, default=None):
    p = f'{rdir}/{name}'
    try:
        return json.load(open(p))
    except Exception:
        return default
out = {
    "scenario": scenario, "verdict": verdict, "summary": summary,
    "started_at": started,
    "ended_at": __import__('datetime').datetime.now(__import__('datetime').timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    "duration_s": int(dur),
    "targets": load('targets.json'),
    "timings": load('timings.json', {}),
    "asserts": asserts,
    "asserts_total": len(asserts),
    "asserts_failed": sum(1 for a in asserts if not a['ok']),
    "notes": notes,
}
json.dump(out, open(f'{rdir}/verdict.json', 'w'), ensure_ascii=False, indent=1)
print(f"verdict -> {rdir}/verdict.json（{verdict}，断言 {out['asserts_total']} 条 / 失败 {out['asserts_failed']}）")
PYEOF
}

r_timing() { # r_timing <键> <秒> —— 记录分段耗时进 verdict
  python3 - "$R_TIMINGS_JSON" "$1" "$2" <<'PYEOF'
import json, sys
p, k, v = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = json.load(open(p)); d[k] = v
json.dump(d, open(p, 'w'), ensure_ascii=False, indent=1)
PYEOF
  log "  timing $1 = ${2}s"
}

# ---------- API 助手 ----------
# 注意：env.sh api() 的 URL 在远端 shell 未加引号，`?a=b&c=d` 会被远端按 `&` 拆命令
# （limit 静默丢失，s5 既有隐患）——R 波一律走 r_api_get/r_api_code（URL 远端单引号保护）。
r_api_get() { # r_api_get <path[?query]> <outfile>
  local path=$1 out=$2
  ssh $SSHOPT -p 22 "root@$(nms_ip)" "curl -sS -m 60 'http://127.0.0.1:80/api/v1$path'" > "$out"
}
r_snap() { # r_snap <名称> <path[?query]> —— GET 快照落 evidence
  r_api_get "$2" "$R_DIR/$1" || return 1
}
r_api_code() { # r_api_code <METHOD> <path[?query]> [json-body] —— 带状态码调用；R_CODE=码，响应体落 $R_CODE_BODY
  local method=$1 path=$2 body=${3:-}
  local remote="/tmp/r-body-$$.json" code
  if [ -n "$body" ]; then
    code=$(printf '%s' "$body" | nms_ssh "curl -sS -m 60 -X '$method' -H 'Content-Type: application/json' --data-binary @- -o '$remote' -w '%{http_code}' 'http://127.0.0.1:80/api/v1$path'" | tail -n1 || true)
  else
    code=$(nms_ssh "curl -sS -m 60 -X '$method' -o '$remote' -w '%{http_code}' 'http://127.0.0.1:80/api/v1$path'" | tail -n1 || true)
  fi
  nms_ssh "cat '$remote'; rm -f '$remote'" > "$R_CODE_BODY" 2>/dev/null || true
  R_CODE=$(echo "$code" | tr -d '[:space:]')
  log "  API $method $path -> HTTP ${R_CODE:-<无响应>}"
}

# ---------- fleet 前置检查（场景入口/出口通用） ----------
r_fleet_check() { # r_fleet_check <标签> —— 全 NODE_COUNT managed/online/collection_ok；失败落盘中止
  local tag=$1
  r_snap "fleet-$tag-nodes.json" /nodes || r_fail "fleet 检查：GET /nodes 失败"
  python3 - "$R_DIR/fleet-$tag-nodes.json" "$NODE_COUNT" <<'PYEOF' || r_fatal "fleet 前置检查($tag)" "存在非 managed/online/collection_ok 节点（见 fleet-$tag-nodes.json）"
import json, sys
items = json.load(open(sys.argv[1]))['items']
nc = int(sys.argv[2])
bad = [n['id'] for n in items if not (n['role'] == 'managed' and n['status'] == 'online' and n['collection_state'] == 'collection_ok')]
assert len(items) == nc and not bad, f"{len(items)} 台 != {nc} 或异常: {bad}"
print(f"fleet 检查($tag) OK: {nc}/{nc} managed/online/collection_ok")
PYEOF
  r_snap "fleet-$tag-alerts.json" "/alerts?status=active&limit=200" || r_fail "fleet 检查：GET /alerts 失败"
  local n
  n=$(python3 -c "import json;d=json.load(open('$R_DIR/fleet-$tag-alerts.json'));print(d.get('total', len(d.get('items',[]))))") \
    || r_fail "fleet 检查：alerts 响应解析失败（$R_DIR/fleet-$tag-alerts.json）"
  [ "$n" = "0" ] || r_fatal "fleet 前置检查($tag)" "active 告警 $n 条 != 0（见 fleet-$tag-alerts.json）"
  log "fleet 检查($tag) OK：active 告警 0"
}

# ---------- 目标选取（r-select.py 统一实现；R_TARGETS_FILE 可注入覆盖） ----------
r_select() { # r_select <scenario> <topology快照文件> —— 输出落 targets.json
  local scenario=$1 topo=$2
  if [ -n "${R_TARGETS_FILE:-}" ]; then
    cp "$R_TARGETS_FILE" "$R_DIR/targets.json" || r_fail "R_TARGETS_FILE 注入失败" "无法复制 $R_TARGETS_FILE"
    log "目标（注入 R_TARGETS_FILE）：$(cat "$R_DIR/targets.json")"
    return 0
  fi
  python3 "$R_LIB_DIR/r-select.py" "$scenario" "$topo" > "$R_DIR/targets.json" \
    || r_fail "目标选取失败（scenario=$scenario，topo=$topo）"
  log "目标（动态选取）：$(cat "$R_DIR/targets.json")"
}

# ---------- 复活/重录通道的 P74 开键舞步 ----------
# 归档行与导入 upsert 均不翻 onboard（db/queries/topology/topology.sql UpsertImportNode 列集
# 无 onboard；#99 人工专属）——被删节点复活后 onboard 仍为 true，true→true 不触发 #111 自动
# 纳管（P74 实录同象）。故统一：先 PUT false 再 PUT true，保证 false→true 翻转真实发生。
r_onboard_dance() { # r_onboard_dance <node_id> —— 幂等保证触发 #111；失败中止
  local id=$1 body
  r_snap "dance-before-$id.json" "/nodes/$id" || r_fail "onboard 舞步：读节点失败 $id"
  local cur
  cur=$(python3 -c "import json;print(json.load(open('$R_DIR/dance-before-$id.json')).get('onboard'))")
  if [ "$cur" = "True" ]; then
    body='{"onboard":false}'
    r_api_code PUT "/nodes/$id" "$body"
    [ "$R_CODE" = "200" ] || r_fatal "onboard 舞步 false" "$id PUT onboard=false -> HTTP $R_CODE"
    sleep 1
  fi
  r_api_code PUT "/nodes/$id" '{"onboard":true}'
  [ "$R_CODE" = "200" ] || r_fatal "onboard 舞步 true" "$id PUT onboard=true -> HTTP $R_CODE"
  r_snap "dance-after-$id.json" "/nodes/$id"
  local now
  now=$(python3 -c "import json;print(json.load(open('$R_DIR/dance-after-$id.json')).get('onboard'))")
  [ "$now" = "True" ] || r_fatal "onboard 舞步终态" "$id onboard=$now != True"
  log "onboard 舞步 OK：$id（false→true 触发 #111，P74 口径）"
}

# ---------- provisioning/managed 收敛轮询 ----------
r_wait_role_seen() { # r_wait_role_seen <id> <要观察到的role> <上限秒> —— 观察到即 0；超时 1
  local id=$1 want=$2 deadline=$(( $(date +%s) + $3 )) role
  while [ "$(date +%s)" -lt "$deadline" ]; do
    r_snap "poll-$id.json" "/nodes/$id" || { sleep 3; continue; }
    role=$(python3 -c "import json;print(json.load(open('$R_DIR/poll-$id.json')).get('role'))" 2>/dev/null || echo '?')
    [ "$role" = "$want" ] && { log "  观察到 $id role=$role"; return 0; }
    sleep 2
  done
  return 1
}
r_wait_managed() { # r_wait_managed <id> <上限秒> —— 转 managed/online/collection_ok 即 0（顺带观察 provisioning）
  local id=$1 budget=$2 role st col saw_prov=0
  local deadline=$(( $(date +%s) + budget ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    r_snap "poll-$id.json" "/nodes/$id" || { sleep 3; continue; }
    read -r role st col <<< "$(python3 -c "
import json
n = json.load(open('$R_DIR/poll-$id.json'))
print(n.get('role'), n.get('status'), n.get('collection_state'))" 2>/dev/null || echo '? ? ?')"
    [ "$role" = "provisioning" ] && saw_prov=1
    if [ "$role" = "managed" ] && [ "$st" = "online" ] && [ "$col" = "collection_ok" ]; then
      echo "$saw_prov"; return 0
    fi
    sleep 3
  done
  echo "$saw_prov"; return 1
}

# ---------- force 删除 + 疏散收敛（R3/R5 共用，02 §7.6/§7.8 语义） ----------
# 轨迹 A（同步全安置）：force 200 → 后代当场全部重挂（在树）；
# 轨迹 B（部分未安置）：force 409 evacuation incomplete（节点不归档）→ unplaced 台父空
# → 轮询 ≤8min 等补扫自动踢轮挂接 → 重发 force 200 完成归档。
r_force_delete_wait() { # r_force_delete_wait <id> <后代清单文件：每行一个id> <总上限秒>
  local id=$1 desc_file=$2 budget=$3
  local deadline=$(( $(date +%s) + budget ))
  local evacuated_sync=0
  r_api_code DELETE "/nodes/$id?force=true"
  if [ "$R_CODE" = "200" ]; then
    evacuated_sync=1
    log "force DELETE $id -> 200（轨迹 A：后代同步全安置）"
  elif [ "$R_CODE" = "409" ]; then
    cp "$R_CODE_BODY" "$R_DIR/force-409-evacuation-incomplete.json"
    log "force DELETE $id -> 409 evacuation incomplete（轨迹 B：unplaced 留 pending，等补扫）"
  else
    r_fatal "force DELETE" "$id -> HTTP $R_CODE（期望 200/409）"
  fi
  if [ "$evacuated_sync" != "1" ]; then
    # 轨迹 B：unplaced 清单必须父空（在 nodes[]、不在 tree.nodes）；轮询等补扫挂接
    python3 - "$R_DIR/force-409-evacuation-incomplete.json" "$desc_file" > "$R_DIR/unplaced.txt" <<'PYEOF' || r_fatal "疏散 409 解析" "evacuation incomplete 体或后代清单异常"
import json, sys
detail = json.load(open(sys.argv[1])).get('detail') or {}
unplaced = [u['id'] for u in detail.get('unplaced', [])]
desc = [l.strip() for l in open(sys.argv[2]) if l.strip()]
assert unplaced, f"409 但 unplaced 空: {detail}"
assert set(unplaced) <= set(desc), f"unplaced 超出后代清单: {unplaced}"
print('\n'.join(unplaced))
PYEOF
    log "unplaced（父空待补扫）：$(tr '\n' ' ' < "$R_DIR/unplaced.txt")"
    local attached=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
      r_snap "evac-poll-topology.json" /topology || { sleep 5; continue; }
      attached=$(python3 - "$R_DIR/evac-poll-topology.json" "$R_DIR/unplaced.txt" <<'PYEOF'
import json, sys
tree = {n['id'] for n in json.load(open(sys.argv[1])).get('tree', {}).get('nodes', [])}
want = [l.strip() for l in open(sys.argv[2]) if l.strip()]
print(sum(1 for w in want if w in tree))
PYEOF
)
      local total; total=$(wc -l < "$R_DIR/unplaced.txt" | tr -d ' ')
      log "  补扫等待：$attached/$total 已重新挂接"
      [ "$attached" = "$total" ] && break
      sleep 10
    done
    [ "$attached" = "$total" ] || r_fatal "补扫疏散收敛" "8min 内 unplaced 未全部重新挂接（$attached/$total）"
    # 全部安置后重发 force 完成归档
    r_api_code DELETE "/nodes/$id?force=true"
    [ "$R_CODE" = "200" ] || r_fatal "force DELETE 重发" "$id -> HTTP $R_CODE（补扫安置后应 200）"
  fi
  echo "$evacuated_sync"
}

# ---------- 部署轮断言（R1/R2/R3/R4/R5 共用口径：≤2 轮、终轮 succeeded） ----------
r_assert_deploy_rounds() { # r_assert_deploy_rounds <快照前缀> <期望主轮台数> <新轮判定基线文件:最新旧deploy_id>
  local prefix=$1 expect_nodes=$2 baseline=$3
  r_snap "$prefix-agent-deploy.json" "/agent-deploy?limit=20" || r_fail "GET /agent-deploy 失败"
  python3 - "$R_DIR/$prefix-agent-deploy.json" "$expect_nodes" "$baseline" "$R_DIR" "$prefix" <<'PYEOF' || r_fatal "部署轮断言($prefix)" "轮数/终态不符（≤2 轮且终轮 succeeded，见 agent-deploy 快照）"
import json, sys
dep = json.load(open(sys.argv[1]))['items']
expect = int(sys.argv[2])
baseline = int(sys.argv[3])   # 场景动作前的最大 deploy_id
rdir, prefix = sys.argv[4], sys.argv[5]
new = sorted([i for i in dep if int(i['deploy_id']) > baseline], key=lambda i: int(i['deploy_id']))
assert new, f"无新部署轮（baseline={baseline}）"
assert len(new) <= 2, f"新轮 {len(new)} > 2（主轮+自动重排口径）: {[(i['deploy_id'], i['status'], i['nodes']) for i in new]}"
first, last = new[0], new[-1]
assert first['nodes'] == expect, f"主轮 nodes={first['nodes']} != {expect}（合批破判）"
assert all(i['status'] in ('succeeded', 'partial') for i in new), f"存在悬挂轮: {new}"
assert last['status'] == 'succeeded', f"终轮 {last['status']} != succeeded"
if len(new) == 2:
    assert first['status'] == 'partial', f"两轮口径要求首轮 partial: {new}"
reroute = len(new) == 2
json.dump({"new_rounds": len(new), "reroute_triggered": reroute,
           "rounds": [(i['deploy_id'], i['status'], i['nodes']) for i in new]},
          open(f'{rdir}/{prefix}deploy-rounds.json', 'w'), ensure_ascii=False, indent=1)
print(f"部署轮($prefix) OK: {len(new)} 轮 {[(i['deploy_id'], i['status'], i['nodes']) for i in new]} 重排触发={reroute}")
PYEOF
}

# ---------- 告警清零轮询 ----------
r_wait_alerts_zero() { # r_wait_alerts_zero <上限秒> <标签> —— 归零即过；超时 fatal（白名单经 R_ALERT_WHITELIST 注因豁免）
  local budget=$1 tag=$2 n
  local deadline=$(( $(date +%s) + budget ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    r_snap "alerts-poll-$tag.json" "/alerts?status=active&limit=200" || { sleep 5; continue; }
    n=$(python3 -c "import json;d=json.load(open('$R_DIR/alerts-poll-$tag.json'));print(d.get('total', len(d.get('items',[]))))")
    [ "$n" = "0" ] && { log "告警清零($tag) OK"; return 0; }
    sleep 10
  done
  if [ -n "${R_ALERT_WHITELIST:-}" ]; then
    r_note "告警未归零但命中 R_ALERT_WHITELIST 注因豁免（$tag）：残留 $n 条，见 alerts-poll-$tag.json（白名单=$R_ALERT_WHITELIST）"
    return 0
  fi
  r_fatal "告警清零($tag)" "active 告警 $n 条未在 ${budget}s 内归零（见 alerts-poll-$tag.json）"
}

# ---------- journal 签名检索（一律 --since 场景起点） ----------
r_now() { # r_now -> NMS 服务器 epoch 秒（跨机时间比较一律用服务器时钟）
  nms_ssh 'date +%s' 2>/dev/null | tail -n1 | tr -d '[:space:]'
}
r_journal_count() { # r_journal_count <固定串> -> stdout 计数
  local sig=$1
  nms_ssh "journalctl -u nms --since '$R_SINCE' --no-pager | grep -cF '$sig'; true" 2>/dev/null | tail -n1 | tr -d '[:space:]'
}
r_journal_dump() { # r_journal_dump <outfile> —— 场景窗口内全量 journal 落盘
  nms_ssh "journalctl -u nms --since '$R_SINCE' --no-pager" > "$1" 2>/dev/null || true
}
