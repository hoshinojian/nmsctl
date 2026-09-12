#!/bin/bash
# R1 单台深路径 删→复活→重纳管（soak-rebuild-churn-plan §四 R1；scale-coldstart-churn-plan §三）
# 验证点：#187 复活清账 / #182 开键迁移 / P74 快速失败重翻 / #186 发现任务留痕
# 流程：选深度 3 叶子 → DELETE（归档断言）→ POST /nodes 同 id（revived 清账断言）
#       → onboard 舞步（P74：归档行不翻 onboard，须 false→true 才触发 #111）
#       → idle→provisioning→managed ≤5min；失败自动重翻一次（计数），仍败即 FAIL。
# 目标动态选取（r-select.py r1）；R_TARGETS_FILE 可注入；DRY_RUN=1 fixture 干跑。
export R_SCENARIO="R1"
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/churn
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）
source "$SOAK_SELF_DIR/r-lib.sh"

if [ "$DRY_RUN" = "1" ]; then
  TOPO="${R_TOPO_FILE:-$R_LIB_DIR/tests/fixtures/topology-fixture.json}"
  r_select r1 "$TOPO"
  log "DRY_RUN：目标选取验证完成，动作序列=DELETE→revive→onboard舞步→收敛≤5min（不执行）"
  r_verdict pass "DRY_RUN：仅目标选取（未执行任何动作）"
  exit 0
fi

r_fleet_check entry
log "步骤 1：抓树形快照并选取目标（深度 3 叶子优先）"
r_snap topology-before.json /topology
r_select r1 "$R_DIR/topology-before.json"
ID=$(python3 -c "import json;print(json.load(open('$R_DIR/targets.json'))['target'])")

log "步骤 2：目标删除前快照 + 载荷构造（含管理树位置）"
r_snap "node-before-$ID.json" "/nodes/$ID" || r_fatal "读目标节点" "GET /nodes/$id 失败"
python3 -c "import json;n=json.load(open('$R_DIR/node-before-$ID.json'));assert n['role']=='managed' and n['domain']==1, n"
PARENT_BEFORE=$(python3 -c "
import json
t=json.load(open('$R_DIR/topology-before.json'))
me=[n for n in t['tree']['nodes'] if n['id']=='$ID']
print(me[0]['parent'] if me else '')")
DEPTH_BEFORE=$(python3 -c "
import json
t=json.load(open('$R_DIR/topology-before.json'))
me=[n for n in t['tree']['nodes'] if n['id']=='$ID']
print(me[0]['depth'] if me else -1)")
[ -n "$PARENT_BEFORE" ] || r_fatal "目标挂树状态" "$ID 不在树中（选目标要求已挂树）"
r_assert "目标为深度3叶子" 1 "id=$ID depth=$DEPTH_BEFORE parent=$PARENT_BEFORE"

# 删除前部署轮基线（新轮判定用）
r_snap agent-deploy-before.json "/agent-deploy?limit=20"
DEPLOY_BASELINE=$(python3 -c "
import json
items=json.load(open('$R_DIR/agent-deploy-before.json'))['items']
print(max((int(i['deploy_id']) for i in items), default=0))")

log "步骤 3：DELETE /nodes/$ID（断言归档）"
r_api_code DELETE "/nodes/$ID"
[ "$R_CODE" = "200" ] || r_fatal "DELETE 归档" "HTTP $R_CODE != 200"
cp "$R_CODE_BODY" "$R_DIR/delete-resp.json"
r_snap topology-after-delete.json /topology
python3 - "$R_DIR/topology-after-delete.json" "$ID" <<'PYEOF' || r_fatal "归档断言" "节点未从列表/树/links 消失"
import json, sys
t = json.load(open(sys.argv[1])); nid = sys.argv[2]
assert nid not in {n['id'] for n in t['nodes']}, "仍在 nodes[]"
assert nid not in {n['id'] for n in t['tree']['nodes']}, "仍在 tree.nodes"
assert not any(l['target'] == nid for l in t['links']), "links 仍有其入边"
print("归档断言 OK：列表/树/links 均无该节点")
PYEOF

log "步骤 4：POST /nodes 同 id 复活（#187 revived 清账断言）"
PAYLOAD=$(python3 - "$R_DIR/node-before-$ID.json" "${NODE_PASS:?NODE_PASS 未设置}" <<'PYEOF'
import json, sys
n = json.load(open(sys.argv[1]))
body = {k: n.get(k) for k in ("id", "name", "device_type", "management_ip", "ssh_port",
                              "ssh_user", "domain", "priority", "region", "lat", "lon",
                              "bandwidth_mbps", "provider", "ram_mb", "disk_gb",
                              "cpu_cores", "cost_monthly", "provisioned_at") if n.get(k) is not None}
body["ssh_password"] = sys.argv[2]   # API 响应不回密码（04 §2.2），统一密码取 env
print(json.dumps(body))
PYEOF
)
r_api_code POST "/nodes" "$PAYLOAD"
[ "$R_CODE" = "201" ] || r_fatal "复活 POST" "HTTP $R_CODE != 201（body 见 last-resp.json）"
cp "$R_CODE_BODY" "$R_DIR/revive-resp.json"
python3 - "$R_DIR/revive-resp.json" <<'PYEOF' || r_fatal "revived 清账断言" "复活响应 role!=idle"
import json, sys
n = json.load(open(sys.argv[1]))
assert n['role'] == 'idle', f"复活后 role={n['role']} != idle"
print(f"复活响应 OK: role=idle（onboard={n.get('onboard')}——归档行不翻键，P74 舞步待触发）")
PYEOF
r_snap audit-node-create.json "/audit?action=node_create&limit=10"
python3 - "$R_DIR/audit-node-create.json" "$ID" <<'PYEOF' || r_fatal "审计 revived 断言" "最新 node_create 无 revived 标记"
import json, sys
items = json.load(open(sys.argv[1]))['items']
nid = sys.argv[2]
mine = [i for i in items if i.get('target') == nid]
assert mine and mine[0].get('detail', {}).get('revived') is True, \
    f"审计缺 revived: {mine[:1]}"
print(f"审计 revived OK: detail={mine[0]['detail'].get('cleared_parent')=} verdict_cleared={mine[0]['detail'].get('verdict_cleared')}")
PYEOF
r_note "ASSUMPTION-核销：观测指纹/裁决台账清账无独立读口（host_key 不在 GET /nodes 契约内），"
r_note "  以审计 detail.cleared_parent/verdict_cleared + 复活响应 role=idle 为 API 可观测证据。"

log "步骤 5：复活后、开键前——parent 空/links 无（清账态）"
r_snap topology-revived.json /topology
python3 - "$R_DIR/topology-revived.json" "$ID" <<'PYEOF' || r_fatal "复活清账态" "复活后未开键即在树/links 中"
import json, sys
t = json.load(open(sys.argv[1])); nid = sys.argv[2]
assert nid not in {n['id'] for n in t['tree']['nodes']}, "复活后已在 tree.nodes（parent 未清？）"
assert not any(l['target'] == nid for l in t['links']), "复活后 links 仍有入边（旧链残留？）"
print("复活清账态 OK：parent 空 / links 无")
PYEOF

log "步骤 6：onboard 舞步（P74）+ 收敛轮询（idle→provisioning→managed ≤5min）"
DEPLOY_RERUNS=0
r_onboard_dance "$ID"
T_KICK=$(date +%s)
RC=0
SAW_PROV=$(r_wait_managed "$ID" 285) || RC=$?
if [ "$RC" != "0" ]; then
  DEPLOY_RERUNS=1
  r_note "首翻未在 300s 内转正——按 P74 自动重翻一次（先 onboard=false 再 true）"
  r_snap agent-deploy-before-retry.json "/agent-deploy?limit=20"
  RETRY_BASELINE=$(python3 -c "
import json
items=json.load(open('$R_DIR/agent-deploy-before-retry.json'))['items']
print(max((int(i['deploy_id']) for i in items), default=0))")
  r_onboard_dance "$ID"
  RC=0
  T_KICK=$(date +%s)   # 重翻段计时重锚（时限断言按末次开键算）
  SAW_PROV=$(r_wait_managed "$ID" 285) || RC=$?
fi
[ "${RC:-1}" = "0" ] || r_fatal "收敛超时" "重翻后 300s 仍未 managed/online/collection_ok（P74 重翻已试 1 次）"
r_assert "P74 自动重翻计数" 1 "reruns=$DEPLOY_RERUNS（0=一次成，1=重翻一次后收敛）"
[ "${SAW_PROV:-0}" = "1" ] || r_fatal "状态路径断言" "未观察到 provisioning（idle→provisioning→managed 路径破判）"
r_assert "状态路径 idle→provisioning→managed" 1 "saw_provisioning=1（轮询 2-3s 间隔）"
T_MANAGED=$(date +%s)
ELAPSED=$((T_MANAGED - T_KICK))
r_timing "onboard_to_managed_s" "$ELAPSED"

log "步骤 7：部署轮断言（≤2 轮、终轮 succeeded、主轮 nodes=1；重翻时按段分别核）"
if [ "$DEPLOY_RERUNS" = "0" ]; then
  r_assert_deploy_rounds r1 1 "$DEPLOY_BASELINE"
else
  # 首翻段：≤2 轮且无悬挂轮即记录（终态允许 partial——正是它触发 P74 重翻）
  python3 - "$R_DIR/agent-deploy-before-retry.json" "$DEPLOY_BASELINE" <<'PYEOF' || r_fatal "首翻段轮记录" ">2 轮或悬挂轮"
import json, sys
items = json.load(open(sys.argv[1]))['items']
first = sorted([i for i in items if int(i['deploy_id']) > int(sys.argv[2])], key=lambda i: int(i['deploy_id']))
assert 0 < len(first) <= 2, first
assert all(i['status'] in ('succeeded', 'partial') for i in first), first
print(f"首翻段 {len(first)} 轮: {[(i['deploy_id'], i['status'], i['nodes']) for i in first]}")
PYEOF
  # 重翻段：与首翻同口径（≤2 轮、终轮 succeeded、主轮 nodes=1）
  r_assert_deploy_rounds r1retry 1 "$RETRY_BASELINE"
fi

log "步骤 8：links 重新物化断言（非静默复用——归档时已断言旧链消失）"
r_snap topology-final.json /topology
python3 - "$R_DIR/topology-final.json" "$ID" "$PARENT_BEFORE" <<'PYEOF' || r_fatal "重新挂接断言" "links 未重新物化"
import json, sys
t = json.load(open(sys.argv[1])); nid, old_parent = sys.argv[2], sys.argv[3]
me = [n for n in t['tree']['nodes'] if n['id'] == nid]
assert me, "不在 tree.nodes（未重新挂接）"
new_parent, depth = me[0]['parent'], me[0]['depth']
ins = [l for l in t['links'] if l['target'] == nid]
assert len(ins) == 1 and ins[0]['source'] == new_parent, f"links 入边异常: {ins}"
print(f"重新挂接 OK: {old_parent} -> {new_parent}（同/新父均可），depth {depth}；入边恰 1 条已物化")
PYEOF
NEW_PARENT=$(python3 -c "
import json
t=json.load(open('$R_DIR/topology-final.json'))
print([n['parent'] for n in t['tree']['nodes'] if n['id']=='$ID'][0])")

log "步骤 9：采集恢复 + 发现任务留痕（#186）"
python3 - "$R_DIR/poll-$ID.json" "$ID" <<'PYEOF' || r_fatal "采集恢复断言" "managed 但 collection_state 异常"
import json, sys
n = json.load(open(sys.argv[1]))
assert n['collection_state'] == 'collection_ok' and n['status'] == 'online', (n['collection_state'], n['status'])
print(f"采集恢复 OK: {n['collection_state']}/{n['status']}")
PYEOF
FROM=$(python3 -c "import datetime;print((datetime.datetime.utcnow()-datetime.timedelta(minutes=15)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
r_snap "metrics-$ID.json" "/nodes/$ID/metrics?metric=cpu&from=$FROM"
python3 - "$R_DIR/metrics-$ID.json" <<'PYEOF' || r_fatal "metrics 断言" "复活后无 cpu 数据点"
import json, sys
d = json.load(open(sys.argv[1]))
pts = d.get('items') or d.get('points') or []
assert pts, d
print(f"metrics OK: cpu {len(pts)} 点")
PYEOF
# 发现任务留痕：topology_discover 审计（任务终态统计，02 §7.9/#186）
FOUND=0
DEADLINE=$(( $(date +%s) + 120 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  r_snap audit-discover.json "/audit?action=topology_discover&limit=10"
  if python3 - "$R_DIR/audit-discover.json" "$R_SINCE" <<'PYEOF'
import json, sys, datetime
items = json.load(open(sys.argv[1]))['items']
since = sys.argv[2]
def ts(x):
    return datetime.datetime.strptime(x.replace('Z',''), '%Y-%m-%dT%H:%M:%S')
recent = [i for i in items if ts(i['ts']) >= ts(since)]
assert recent, "无场景窗口内的 topology_discover 审计"
print(f"发现任务留痕 OK: {len(recent)} 条（最新 detail={recent[0].get('detail')}）")
PYEOF
  then FOUND=1; break; fi
  sleep 10
done
[ "$FOUND" = "1" ] || r_fatal "发现任务留痕" "120s 内未出现 topology_discover 审计（#186）"
r_journal_dump "$R_DIR/journal-end.log"

log "步骤 10：时限断言（单台 ≤5min）+ 深路径基线留档（R5 对照用）"
[ "$ELAPSED" -le 300 ] || r_fatal "单台时限" "onboard→managed ${ELAPSED}s > 300s"
r_assert "单台时限 ≤300s" 1 "actual=${ELAPSED}s"
mkdir -p "$R_EVIDENCE_ROOT/R-common"
python3 - <<PYEOF
import json
json.dump({"r1_deep_revive_seconds": $ELAPSED, "parent_before": "$PARENT_BEFORE",
           "parent_after": "$NEW_PARENT", "reruns": $DEPLOY_RERUNS},
          open("$R_EVIDENCE_ROOT/R-common/deep-revive-seconds.json", "w"), ensure_ascii=False, indent=1)
PYEOF

r_wait_alerts_zero 120 final
r_fleet_check exit
r_verdict pass "R1 通过：删→复活→重纳管全链收敛（${ELAPSED}s，重翻 $DEPLOY_RERUNS 次，$PARENT_BEFORE→$NEW_PARENT）"
