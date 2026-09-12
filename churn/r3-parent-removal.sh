#!/bin/bash
# R3 父节点摘除与子树自愈（soak-rebuild-churn-plan §四 R3；scale-coldstart-churn-plan §三）
# 目标：「子女最多的深度 2 节点」（2-3 皆可）——本场景验证既有疏散语义（rehome+pending+补扫，
# rehome 不查 child_budget 为设计内豁免 #124），不是 T2 换路样本。
# 流程：裸 DELETE 断言 409 subtree attached 且 descendants 清单与树形一致 →
#       DELETE ?force=true（轨迹 A=200 同步全安置 / 轨迹 B=409 evacuation incomplete→
#       父空节点轮询 ≤8min 等补扫踢轮挂接→重发 force 200）→ 父归档断言 →
#       重录父 + onboard 舞步（P74）→ 父挂回 + 全树 NODE_COUNT/NODE_COUNT + g5 不变量 +
#       期间级联告警恢复自解（轮询归零）。
export R_SCENARIO="R3"
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/churn
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）
source "$SOAK_SELF_DIR/r-lib.sh"

if [ "$DRY_RUN" = "1" ]; then
  TOPO="${R_TOPO_FILE:-$R_LIB_DIR/tests/fixtures/topology-fixture.json}"
  r_select r3 "$TOPO"
  log "DRY_RUN：目标选取验证完成，动作序列=裸DELETE 409→force→疏散收敛→重录父→收敛（不执行）"
  r_verdict pass "DRY_RUN：仅目标选取（未执行任何动作）"
  exit 0
fi

r_fleet_check entry
log "步骤 1：抓树形快照并选取目标（子女最多的深度 2 节点）"
r_snap topology-before.json /topology
r_select r3 "$R_DIR/topology-before.json"
ID=$(python3 -c "import json;print(json.load(open('$R_DIR/targets.json'))['target'])")
r_snap "node-before-$ID.json" "/nodes/$ID" || r_fatal "读目标节点" "GET /nodes/$ID 失败"
python3 -c "
import json
print('\n'.join(json.load(open('$R_DIR/targets.json'))['descendants']))" > "$R_DIR/descendants.txt"
DESC_N=$(wc -l < "$R_DIR/descendants.txt" | tr -d ' ')
r_assert "目标画像" 1 "$(cat "$R_DIR/targets.json")（后代 $DESC_N 台，清单见 descendants.txt）"

r_snap agent-deploy-before.json "/agent-deploy?limit=20"
DEPLOY_BASELINE=$(python3 -c "
import json
items=json.load(open('$R_DIR/agent-deploy-before.json'))['items']
print(max((int(i['deploy_id']) for i in items), default=0))")

log "步骤 2：裸 DELETE 断言 409 subtree attached + descendants 清单与树形一致"
r_api_code DELETE "/nodes/$ID"
[ "$R_CODE" = "409" ] || r_fatal "裸 DELETE 期望 409" "HTTP $R_CODE != 409（携子双闸门 04 §2.5）"
cp "$R_CODE_BODY" "$R_DIR/delete-409-body.json"
python3 - "$R_DIR/delete-409-body.json" "$R_DIR/descendants.txt" <<'PYEOF' || r_fatal "409 后代清单" "与树形推导不一致"
import json, sys
body = json.load(open(sys.argv[1]))
want = {l.strip() for l in open(sys.argv[2]) if l.strip()}
got = set((body.get('detail') or {}).get('descendants') or [])
assert body.get('code') == 409 and 'subtree attached' in body.get('message', ''), body
assert got == want, f"descendants 不一致:\n 409体={sorted(got)}\n 树形={sorted(want)}"
print(f"409 清单 OK：{len(got)} 台与树形一致（爆炸半径可见）")
PYEOF
# 裸删被拒后目标必须原样健在（负向断言：拒绝 = 无副作用）
r_snap node-after409.json "/nodes/$ID"
python3 -c "
import json; n=json.load(open('$R_DIR/node-after409.json'))
assert n['role']=='managed' and n['status']=='online', n" \
  || r_fatal "409 无副作用" "被拒删除后目标状态变化"

log "步骤 3：DELETE ?force=true 疏散后代（轨迹 A/B 自适应，共用 r-lib 语义）"
T_FORCE=$(date +%s)
EVAC_SYNC=$(r_force_delete_wait "$ID" "$R_DIR/descendants.txt" 480)
r_timing "force_delete_and_evacuation_s" "$(( $(date +%s) - T_FORCE ))"
r_assert "疏散轨迹" 1 "evacuated_sync=$EVAC_SYNC（1=force 200 当场全安置；0=409→补扫收敛后重发）"

log "步骤 4：父归档断言（列表/树消失）+ 后代全部重新挂接"
r_snap topology-after-force.json /topology
python3 - "$R_DIR/topology-after-force.json" "$ID" "$R_DIR/descendants.txt" <<'PYEOF' || r_fatal "归档/重挂断言" "父未归档或后代未全部在树"
import json, sys
t = json.load(open(sys.argv[1])); nid = sys.argv[2]
desc = [l.strip() for l in open(sys.argv[3]) if l.strip()]
tree = {n['id'] for n in t['tree']['nodes']}
assert nid not in {n['id'] for n in t['nodes']}, "父仍在 nodes[]（未归档）"
assert nid not in tree, "父仍在树中"
not_back = [d for d in desc if d not in tree]
assert not not_back, f"后代未重新挂接: {not_back}"
print(f"归档 OK + 后代 {len(desc)} 台全部在树（同/新父均可）")
PYEOF
r_snap nodes-count.json /nodes
python3 -c "
import json, os
items = json.load(open('$R_DIR/nodes-count.json'))['items']
assert len(items) == int(os.environ['NODE_COUNT']) - 1, len(items)" \
  || r_fatal "删除后计数" "fleet != NODE_COUNT-1"

log "步骤 5：级联告警恢复自解（轮询 ≤10min 归零；白名单豁免见 R_ALERT_WHITELIST）"
r_wait_alerts_zero 600 evacuation

log "步骤 6：重录原父节点（POST /nodes 同 id）+ onboard 舞步（P74）"
PAYLOAD=$(python3 - "$R_DIR/node-before-$ID.json" "${NODE_PASS:?NODE_PASS 未设置}" <<'PYEOF'
import json, sys
n = json.load(open(sys.argv[1]))
body = {k: n.get(k) for k in ("id", "name", "device_type", "management_ip", "ssh_port",
                              "ssh_user", "domain", "priority", "region", "lat", "lon",
                              "bandwidth_mbps", "provider", "ram_mb", "disk_gb",
                              "cpu_cores", "cost_monthly", "provisioned_at") if n.get(k) is not None}
body["ssh_password"] = sys.argv[2]
assert body["domain"] == 1, f"重录载荷 domain={body['domain']} != 1"
print(json.dumps(body))
PYEOF
)
r_api_code POST "/nodes" "$PAYLOAD"
[ "$R_CODE" = "201" ] || r_fatal "重录父" "HTTP $R_CODE != 201"
cp "$R_CODE_BODY" "$R_DIR/revive-resp.json"
r_onboard_dance "$ID"

log "步骤 7：收敛断言（父挂回，≤8min；补扫接通 + 一轮部署）"
T_KICK=$(date +%s)
RC=0
SAW_PROV=$(r_wait_managed "$ID" 450) || RC=$?
[ "$RC" = "0" ] || r_fatal "父复活收敛超时" "8min 内未 managed/online/collection_ok"
[ "${SAW_PROV:-0}" = "1" ] || r_fatal "状态路径断言" "父复活未观察到 provisioning"
r_assert "父挂回状态路径" 1 "saw_provisioning=1"
DUR_REV=$(( $(date +%s) - T_KICK ))
r_timing "parent_revive_s" "$DUR_REV"
[ "$DUR_REV" -le 480 ] || r_fatal "父复活时限" "${DUR_REV}s > 480s"
r_assert_deploy_rounds r3 1 "$DEPLOY_BASELINE"

log "步骤 8：全树断言（NODE_COUNT/NODE_COUNT managed + g5 不变量）"
r_snap topology-final.json /topology
python3 "$SOAK_HOME/observe/g5-tree.py" "$R_DIR/topology-final.json" "$R_DIR/tree-analysis.json" \
  --nodes "$NODE_COUNT" --first-hop "$FIRST_HOP_COUNT" --child-budget "$CHILD_BUDGET" \
  || r_fatal "树形不变量" "g5-tree.py 违规（出度/深度/links/第一跳集，见 tree-analysis.json）"
NEW_PARENT=$(python3 -c "
import json
t=json.load(open('$R_DIR/topology-final.json'))
m=[n for n in t['tree']['nodes'] if n['id']=='$ID']
print(m[0]['parent'] if m else '')")
[ -n "$NEW_PARENT" ] || r_fatal "父挂回断言" "复活父不在树中"
r_assert "父挂回" 1 "new parent=$NEW_PARENT（同/新父均可）"
r_wait_alerts_zero 120 final
r_journal_dump "$R_DIR/journal-end.log"
r_fleet_check exit
r_verdict pass "R3 通过：父摘除→后代疏散自愈→父复活挂回（疏散同步=$EVAC_SYNC，父复活 ${DUR_REV}s）"
