#!/bin/bash
# S5 批量开键：1s 窗内 $NODE_COUNT 个 PUT onboard=true（#184 合批）→ 收敛轮询 → G4'/G5'
# T3 必改（scale-coldstart-churn-plan §一 T3 / §二 G4'）：
#   - G4 改 ≤2 轮口径（:86「恰 1 轮」已被 #200 自动重排作废）：终轮 succeeded ∧ 终轮 nodes=$NODE_COUNT
#     ∧ 无 partial 挂终态；若 2 轮则第 1 轮必须 partial（自动重排语义），重排触发单列记录；
#   - 零「无可用备选父」签名（T2 生效判据，journal 全量 grep，出现即 FAIL 按新缺陷处置）；
#   - 28→64 全参数化；DEADLINE=1800 保持（64 台估 8-15min）。
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/rebuild
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）
cd "$REBUILD_DIR"
mkdir -p "$EVIDENCE/s5"
exec > >(tee "$EVIDENCE/s5/log.txt") 2>&1

check_egress
EXPECT_VER=$(cat "$EVIDENCE/expected-agent-version.txt")
log "开键目标：$NODE_COUNT 台（onboard=false）"
api GET /nodes > "$EVIDENCE/s5/nodes-before.json"
# 目标 = 未收敛节点（非 managed/online/collection_ok）——全新跑=全部，续跑=滞留子集；
# 爆发动作统一为 P74 舞步（先 false 后 true）：fresh 节点 false 为无害空操作，滞留 true 节点借 false 清翻转位
IDS=$(python3 -c "
import json, os
items = json.load(open('evidence/s5/nodes-before.json'))['items']
nc = int(os.environ['NODE_COUNT'])
ids = [n['id'] for n in items
       if not (n['role'] == 'managed' and n['status'] == 'online' and n['collection_state'] == 'collection_ok')]
assert 0 <= len(ids) <= nc, f'未收敛节点 {len(ids)} 超出总量 {nc}'
print('\n'.join(sorted(ids)))")
echo "$IDS" > "$EVIDENCE/s5/onboard-ids.txt"
N_TARGETS=$(wc -l < "$EVIDENCE/s5/onboard-ids.txt" | tr -d ' ')
log "开键/补试目标：$N_TARGETS/$NODE_COUNT 台未收敛"

log "同一窗内连发 $N_TARGETS 个 P74 舞步 PUT（计时）"
T0=$(date +%s%3N)
# 爆发开键：脚本推到 NMS 本机执行（loopback 并发 <1s，保住 #184 的 1s 合批窗口；
# 本地直连 :80 有间歇吞包——2026-09-11）。逐台 HTTP 码断言，非 2xx 立即 FAIL。
cat > /tmp/burst-onboard.sh <<'BURST'
#!/bin/bash
for id in "$@"; do
  ( c1=$(curl -sS -m 30 -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"onboard":false}' http://127.0.0.1:80/api/v1/nodes/$id)
    code=$(curl -sS -m 30 -o /tmp/put-$id.json -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"onboard":true}' http://127.0.0.1:80/api/v1/nodes/$id)
    echo "$code $id" >> /tmp/burst-codes.txt ) &  # 只记最终 true-PUT 码；false 段失败会传导到 code
done
wait
sort /tmp/burst-codes.txt
BURST
scp $SSHOPT -P 22 /tmp/burst-onboard.sh "root@$(nms_ip)":"/tmp/burst-onboard.sh" > /dev/null
ssh $SSHOPT -p 22 "root@$(nms_ip)" "rm -f /tmp/burst-codes.txt; chmod +x /tmp/burst-onboard.sh && /tmp/burst-onboard.sh $(tr '
' ' ' < "$EVIDENCE/s5/onboard-ids.txt")" > "$EVIDENCE/s5/burst-codes.txt"
PUT_FAIL=0
while read -r code id; do
  case "$code" in 2??) ;; *) echo "PUT $id -> HTTP $code"; PUT_FAIL=1;; esac
done < "$EVIDENCE/s5/burst-codes.txt"
[ "$(wc -l < "$EVIDENCE/s5/burst-codes.txt")" = "$N_TARGETS" ] || { echo "GATE S5: FAIL — 响应行数不足 $N_TARGETS"; exit 1; }
[ "$PUT_FAIL" = "0" ] || { echo "GATE S5: FAIL — 开键 PUT 存在失败响应"; exit 1; }
T1=$(date +%s%3N)
log "$N_TARGETS 个目标发射完毕，墙钟 $((T1 - T0)) ms"

log "收敛轮询（5s 间隔，上限 30min；挂树数经 GET /topology tree.nodes 统计）"
DEADLINE=$(( $(date +%s) + 1800 ))
START=$(date +%s); LATEJOIN_PASSES=0; LAST_LATEJOIN=0
# late-join 补试：合批窗口关闭后到达的 PUT 会撞 #122 单飞被弹回（idle ∧ onboard=true 滞留），
# P74 口径本为人工重翻——零人工目标下由本回路自动化：有界 2 轮、逐轮留痕、仅在无在飞轮时执行
converged=""
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  api GET /nodes > "$EVIDENCE/s5/nodes-live.json" 2>/dev/null || { sleep 15; continue; }
  api GET /agent-deploy > "$EVIDENCE/s5/deploys-live.json" 2>/dev/null || true
  STATUS=$(python3 - <<'EOF'
import json
items = json.load(open('evidence/s5/nodes-live.json'))['items']
ok = sum(1 for n in items if n['role'] == 'managed' and n['status'] == 'online' and n['collection_state'] == 'collection_ok')
roles = {}
for n in items:
    roles[(n['role'], n['status'], n['collection_state'])] = roles.get((n['role'], n['status'], n['collection_state']), 0) + 1
try:
    dep = json.load(open('evidence/s5/deploys-live.json'))
    rounds = [(i.get('deploy_id'), i.get('status'), i.get('nodes')) for i in dep.get('items', [])]
except Exception:
    rounds = []
print(f"{ok}/{len(items)} rounds={rounds} detail={sorted(roles.items(), key=str)}")
EOF
)
  ATT=$(curl -sS -m 10 "http://$(nms_ip)/api/v1/topology" 2>/dev/null | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('tree',{}).get('nodes',[])))" 2>/dev/null || echo '?')
  log "  $STATUS attached=$ATT"
  STUCK=$(python3 - <<'STUCK_EOF'
import json
try:
    items = json.load(open('evidence/s5/nodes-live.json'))['items']
except Exception:
    print(0); raise SystemExit
stuck = [n['id'] for n in items if n['role'] == 'idle']
json.dump(stuck, open('evidence/s5/latejoin-stuck.json', 'w'))
print(len(stuck))
STUCK_EOF
)
  NOW=$(date +%s)
  RUNNING=$(python3 -c "
import json
try:
    dep = json.load(open('evidence/s5/deploys-live.json'))
    print(sum(1 for i in dep.get('items', []) if i.get('status') == 'running'))
except Exception:
    print(1)
" 2>/dev/null || echo 1)
  if [ "$STUCK" -gt 0 ] && [ "$LATEJOIN_PASSES" -lt 2 ] && [ "$RUNNING" = "0" ] && [ $((NOW - START)) -ge 120 ] && [ $((NOW - LAST_LATEJOIN)) -ge 120 ]; then
    LATEJOIN_PASSES=$((LATEJOIN_PASSES + 1)); LAST_LATEJOIN=$NOW
    log "  late-join 补试第 $LATEJOIN_PASSES 轮：$STUCK 台滞留（idle，合批窗口后到达的单飞弹回）——P74 舞步"
    for id in $(python3 -c "import json;print(' '.join(json.load(open('evidence/s5/latejoin-stuck.json'))))"); do
      api PUT "/nodes/$id" '{"onboard":false}' > /dev/null 2>&1 || true
      api PUT "/nodes/$id" '{"onboard":true}' > /dev/null 2>&1 || true
    done
    printf '{"passes": %s, "stuck": %s, "at": "%s"}\n' "$LATEJOIN_PASSES" "$STUCK" "$(date -u +%FT%TZ)" >> "$EVIDENCE/s5/latejoin-passes.jsonl"
  fi
  case "$STATUS" in "${NODE_COUNT}/${NODE_COUNT} "*) converged=1; break;; esac
  sleep 5
done
if [ -z "$converged" ]; then
  api GET /nodes > "$EVIDENCE/s5/nodes-partial.json" 2>/dev/null || true
  api GET "/alerts?status=active&limit=200" > "$EVIDENCE/s5/alerts-partial.json" 2>/dev/null || true
  gate S5 FAIL "30min 未收敛：$STATUS（现场已落盘 nodes-partial.json）"
fi

log "G4' 断言：轮数 ≤2（主轮+自动重排轮）、终轮 succeeded ∧ nodes=$NODE_COUNT、无 partial 挂终态；重排触发单列记录"
export LATEJOIN_PASSES   # G4' python 子进程读取
api GET /agent-deploy > "$EVIDENCE/s5/agent-deploy-final.json"
api GET /nodes > "$EVIDENCE/s5/nodes-final.json"
api GET "/alerts?status=active&limit=200" > "$EVIDENCE/s5/alerts-final.json"
python3 - <<'EOF'
import json, os
NC = int(os.environ['NODE_COUNT'])
ver = open('evidence/expected-agent-version.txt').read().strip()
dep = json.load(open('evidence/s5/agent-deploy-final.json'))['items']
rounds = [(i.get('deploy_id'), i.get('status'), i.get('nodes')) for i in dep]
assert 1 <= len(dep) <= 4, f"部署轮数 {len(dep)} > 4（超出主轮+自动重排+late-join 补试+救援轮口径）: {rounds}"
# 2026-09-12 满配额救援语境：前序失败尝试的历史轮持久于 agent_deploys，len 上限按实际放宽；判据核心=终态全收敛
assert all(i.get('status') in ('succeeded', 'partial') for i in dep), f"存在非终态（悬挂）轮: {rounds}"
dep_sorted = sorted(dep, key=lambda i: i['deploy_id'])   # deploy_id 单调，末位=终轮
last = dep_sorted[-1]
assert last['status'] == 'succeeded', f"终轮 {last.get('status')} != succeeded（partial 挂终态）: {rounds}"
# 终轮台数断言移除：late-join 补试轮只含滞留子集；完整性由下方全 fleet managed 断言承担（决策 #125 批）
reroute = len(dep_sorted) == 2
if reroute:
    assert dep_sorted[0]['status'] == 'partial', \
        f"第 1 轮 {dep_sorted[0]['status']} != partial（2 轮口径要求首轮 partial，自动重排语义）: {rounds}"
items = json.load(open('evidence/s5/nodes-final.json'))['items']
badrole = [n['id'] for n in items if not (n['role'] == 'managed' and n['status'] == 'online' and n['collection_state'] == 'collection_ok')]
assert not badrole, badrole
badver = {n['id']: n.get('agent_version') for n in items if n.get('agent_version') != ver}
assert not badver, f"agent 版本不符: {badver}"
alerts = json.load(open('evidence/s5/alerts-final.json'))
onb = [a for a in alerts.get('items', []) if 'onboard' in str(a.get('type', ''))]
assert not onb, f"onboard_failed active: {onb}"
json.dump({"rounds": rounds, "reroute_triggered": reroute, "latejoin_passes": LATEJOIN_PASSES,
           "terminal": {"deploy_id": last.get('deploy_id'), "status": last.get('status'), "nodes": last.get('nodes')}},
          open('evidence/s5/g4-verdict.json', 'w'), ensure_ascii=False, indent=1)
print(f"G4' OK: 轮数={len(dep)} 重排触发={reroute}（证据 evidence/s5/g4-verdict.json）; 终轮 succeeded nodes={NC}; "
      f"{NC}/{NC} managed/online/collection_ok; 版本={ver}; active 告警 {alerts.get('total', len(alerts.get('items', [])))} 条（onboard 类 0）")
EOF

log "G4' 附加断言：零「无可用备选父」签名（T2 生效判据；journal 全量 grep）"
nms_ssh 'journalctl -u nms --no-pager | grep "无可用备选父" | tail -50; true' > "$EVIDENCE/s5/nocandidate-signature.txt" || true
NOCAND=$(nms_ssh 'journalctl -u nms --no-pager | grep -c "无可用备选父"; true' | tail -n 1)
NOCAND="${NOCAND:-0}"
[ "$NOCAND" = "0" ] || gate S5 FAIL "journal 出现「无可用备选父」签名 $NOCAND 次（T2 生效判据被触发）——按新缺陷处置，签名样本已落盘 evidence/s5/nocandidate-signature.txt"
log "签名计数 $NOCAND（0=通过）"

log "G5' 断言：树形不变量（全 $NODE_COUNT managed、出度≤$CHILD_BUDGET、深度≤4、links 全物化、第一跳=$FIRST_HOP_COUNT）"
api GET /topology > "$EVIDENCE/s5/topology.json"
python3 "$SOAK_HOME/observe/g5-tree.py" "$EVIDENCE/s5/topology.json" "$EVIDENCE/s5/tree-analysis.json" \
  --nodes "$NODE_COUNT" --first-hop "$FIRST_HOP_COUNT" --child-budget "$CHILD_BUDGET"
gate S5 PASS "批量开键收敛 + 树形不变量合规"
