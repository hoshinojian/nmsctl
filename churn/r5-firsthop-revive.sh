#!/bin/bash
# R5 第一跳复活（T2 实战验收样本；soak-rebuild-churn-plan §四 R5；scale-coldstart-churn-plan §三）
# 验证点：#185/#124 T2 换路补全——满树下第一跳删除→子女疏散（跨层/缝内等待落位）→重录直连复活。
# 流程：选第一跳（domain=0，出度 ≥2 优先）→ 记录子女清单 → 裸 DELETE 断言 409（携子闸门一致）→
#       DELETE ?force=true（子女疏散：R3 同款轨迹 A/B）→ 断言子女全部重挂 + journal 零
#       「无可用备选父」（T2 生效判据）→ POST /nodes 重录同 id（domain=0 资格保真）→ onboard 舞步 →
#       断言第一跳不等挂树直接部署（journal 内联 TOFU 特征）+ 单台 ≤5min + 全程轮数 ≤2。
# journal 签名（代码锚点）：errNoCandidate="discover: 无可用备选父（空位/负事实过滤后）"（discover/reparent.go）
#       缝内等待="换父无可用候选（第 N 轮重查）"——出现记为 T2 缝内等待生效证据（非失败）。
export R_SCENARIO="R5"
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/churn
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）
source "$SOAK_SELF_DIR/r-lib.sh"

if [ "$DRY_RUN" = "1" ]; then
  TOPO="${R_TOPO_FILE:-$R_LIB_DIR/tests/fixtures/topology-fixture.json}"
  r_select r5 "$TOPO"
  log "DRY_RUN：目标选取验证完成，动作序列=409→force 疏散→子女重挂断言→重录直连复活（不执行）"
  r_verdict pass "DRY_RUN：仅目标选取（未执行任何动作）"
  exit 0
fi

r_fleet_check entry
log "步骤 1：抓树形快照并选取目标第一跳（出度 ≥2 优先）+ 子女清单"
r_snap topology-before.json /topology
r_select r5 "$R_DIR/topology-before.json"
ID=$(python3 -c "import json;print(json.load(open('$R_DIR/targets.json'))['target'])")
OUT_DEG=$(python3 -c "import json;print(json.load(open('$R_DIR/targets.json'))['out_degree'])")
python3 -c "
import json
print('\n'.join(json.load(open('$R_DIR/targets.json'))['descendants']))" > "$R_DIR/descendants.txt"
r_snap "node-before-$ID.json" "/nodes/$ID" || r_fatal "读目标节点" "GET /nodes/$ID 失败"
python3 -c "
import json; n=json.load(open('$R_DIR/node-before-$ID.json'))
assert n['domain']==0 and n['role']=='managed', (n['domain'], n['role'])" \
  || r_fatal "目标画像" "非 managed 第一跳"
r_assert "目标画像" 1 "第一跳 $ID 出度=$OUT_DEG（疏散面）"

r_snap agent-deploy-before.json "/agent-deploy?limit=20"
DEPLOY_BASELINE=$(python3 -c "
import json
items=json.load(open('$R_DIR/agent-deploy-before.json'))['items']
print(max((int(i['deploy_id']) for i in items), default=0))")

log "步骤 2：裸 DELETE 断言 409（携子闸门与 R3 同款，先记录爆炸半径）"
r_api_code DELETE "/nodes/$ID"
[ "$R_CODE" = "409" ] || r_fatal "裸 DELETE 期望 409" "HTTP $R_CODE != 409"
cp "$R_CODE_BODY" "$R_DIR/delete-409-body.json"
python3 - "$R_DIR/delete-409-body.json" "$R_DIR/descendants.txt" <<'PYEOF' || r_fatal "409 后代清单" "与树形推导不一致"
import json, sys
body = json.load(open(sys.argv[1]))
want = {l.strip() for l in open(sys.argv[2]) if l.strip()}
got = set((body.get('detail') or {}).get('descendants') or [])
assert got == want, f"409体={sorted(got)} 树形={sorted(want)}"
print(f"409 清单 OK：{len(got)} 台后代（含二级）")
PYEOF

log "步骤 3：DELETE ?force=true——子女疏散（R3 同款轨迹 A/B）+ 重挂收敛"
T_FORCE=$(date +%s)
EVAC_SYNC=$(r_force_delete_wait "$ID" "$R_DIR/descendants.txt" 480)
r_timing "evacuation_s" "$(( $(date +%s) - T_FORCE ))"
r_snap topology-after-evac.json /topology
python3 - "$R_DIR/topology-after-evac.json" "$ID" "$R_DIR/descendants.txt" <<'PYEOF' || r_fatal "疏散重挂断言" "父未归档或子女未全部重挂"
import json, sys
t = json.load(open(sys.argv[1])); nid = sys.argv[2]
desc = [l.strip() for l in open(sys.argv[3]) if l.strip()]
tree = {n['id'] for n in t['tree']['nodes']}
assert nid not in {n['id'] for n in t['nodes']} and nid not in tree, "第一跳未归档"
lost = [d for d in desc if d not in tree]
assert not lost, f"疏散子女未全部重新挂接: {lost}"
print(f"疏散子女 {len(desc)} 台全部重挂（同/新父均可，跨层允许——#124 D3）")
PYEOF

log "步骤 4：T2 生效判据——journal 零「无可用备选父」签名（--since 场景起点）"
r_journal_dump "$R_DIR/journal-evac.log"
NOCAND=$(r_journal_count "无可用备选父")
NOCAND="${NOCAND:-0}"
[ "$NOCAND" = "0" ] || r_fatal "T2 生效判据" "出现「无可用备选父」$NOCAND 次——按新缺陷处置（样本见 journal-evac.log）"
r_assert "T2 判据：零 errNoCandidate" 1 "count=0"
SEAM_WAIT=$(r_journal_count "轮重查")
SEAM_WAIT="${SEAM_WAIT:-0}"
if [ "$SEAM_WAIT" != "0" ]; then
  r_note "T2 缝内等待生效证据：「第 N 轮重查」出现 $SEAM_WAIT 次（非失败——#124 D2 等待预算内落位留痕）"
fi
FAILOVER=$(r_journal_count "部署失败换父")
FAILOVER="${FAILOVER:-0}"
r_assert "T2 换路记录" 1 "deploy_failover 换父=$FAILOVER 次，缝内等待重查=$SEAM_WAIT 次"

log "步骤 5：重录第一跳（POST /nodes 同 id，domain=0 资格保真）+ onboard 舞步（P74）"
PAYLOAD=$(python3 - "$R_DIR/node-before-$ID.json" "${NODE_PASS:?NODE_PASS 未设置}" <<'PYEOF'
import json, sys
n = json.load(open(sys.argv[1]))
body = {k: n.get(k) for k in ("id", "name", "device_type", "management_ip", "ssh_port",
                              "ssh_user", "domain", "priority", "region", "lat", "lon",
                              "bandwidth_mbps", "provider", "ram_mb", "disk_gb",
                              "cpu_cores", "cost_monthly", "provisioned_at") if n.get(k) is not None}
assert body.get("domain") == 0, f"重录载荷 domain={body.get('domain')} != 0（第一跳资格必须保真）"
body["ssh_password"] = sys.argv[2]
print(json.dumps(body))
PYEOF
)
r_api_code POST "/nodes" "$PAYLOAD"
[ "$R_CODE" = "201" ] || r_fatal "重录第一跳" "HTTP $R_CODE != 201"
cp "$R_CODE_BODY" "$R_DIR/revive-resp.json"
# 时钟起点必须在舞步之前：deploy 行在 PUT onboard=true 处理器内同步创建（#184），
# 时间戳早于响应返回——起点取在舞步后会出现负 DELAY 的伪信号
T_KICK=$(r_now)          # 服务器时钟（与 deploy created_at 同源，消跨机钟差）
T_KICK_LOCAL=$(date +%s) # 本地时钟（纯时长测量同源）
r_onboard_dance "$ID"

log "步骤 6：收敛断言——第一跳不等挂树直接部署（≤5min，对照深路径基线）"
RC=0
r_wait_managed "$ID" 285 > /dev/null || RC=$?
[ "$RC" = "0" ] || r_fatal "第一跳复活收敛超时" "285s 轮询窗内未 managed/online/collection_ok（时限 300s）"
DUR=$(( $(date +%s) - T_KICK_LOCAL ))
r_timing "fh_onboard_to_managed_s" "$DUR"
[ "$DUR" -le 300 ] || r_fatal "单台时限" "${DUR}s > 300s（深路径基线）"
r_assert "单台时限 ≤300s" 1 "actual=${DUR}s"
if [ -f "$R_EVIDENCE_ROOT/R-common/deep-revive-seconds.json" ]; then
  DEEP_S=$(python3 -c "import json;print(json.load(open('$R_EVIDENCE_ROOT/R-common/deep-revive-seconds.json'))['r1_deep_revive_seconds'])")
  r_note "时长对照：第一跳 ${DUR}s vs R1 深路径实测 ${DEEP_S}s（第一跳更快/持平即符合预期，仅记录）"
fi

log "步骤 7：不等挂树特征——部署轮即时启动（第一跳无 waitAttached 前置，#185/#124）"
r_assert_deploy_rounds r5 1 "$DEPLOY_BASELINE"
DEPLOY_CREATED=$(python3 -c "
import json
items = json.load(open('$R_DIR/r5-agent-deploy.json'))['items']
new = [i for i in items if int(i['deploy_id']) > $DEPLOY_BASELINE]
print(sorted(new, key=lambda i: int(i['deploy_id']))[0]['created_at'])")
DELAY=$(python3 - "$DEPLOY_CREATED" "$T_KICK" <<'PYEOF'
import json, sys, datetime
c = sys.argv[1].strip()
c = c[:-1] + '+00:00' if c.endswith('Z') else c
if len(c) == 19:  # API 返回无时区后缀的 UTC 裸格式（04 §2.1 时间字段口径）
    c += '+00:00'
created = datetime.datetime.fromisoformat(c)
kick = datetime.datetime.fromtimestamp(int(sys.argv[2]), datetime.timezone.utc)
print(int((created - kick).total_seconds()))
PYEOF
)
[ "$DELAY" -ge 0 ] && [ "$DELAY" -le 60 ] \
  || r_fatal "不等挂树特征" "部署轮在开键后 ${DELAY}s 才创建（>60s——疑似走了挂树等待路径）"
r_assert "第一跳部署即时启动" 1 "deploy 轮 created_at 滞后开键 ${DELAY}s（<60s；深路径须先等发现轮 ≥23s+）"
r_note "ASSUMPTION-内联 TOFU：TOFU 拨号在 journal 无独立日志行（transport/ssh_conn.go 静默回调），"
r_note "  「内联 TOFU 特征」以代理观测定证：部署轮 created_at 滞后开键 ${DELAY}s + 第一跳无挂树等待段"
r_note "  （pipeline.go waitAttached/unattachedIDs 的 domain<>0 过滤即第一跳跳过等挂树，代码已核实）。"

log "步骤 8：全程轮数 ≤2 复核 + 疏散子女保持挂接 + 告警清零"
python3 -c "
import json; d=json.load(open('$R_DIR/r5deploy-rounds.json'))
assert d['new_rounds'] <= 2, d" || r_fatal "轮数口径" "R5 全程新轮 >2"
r_snap topology-final.json /topology
python3 - "$R_DIR/topology-final.json" "$R_DIR/descendants.txt" <<'PYEOF' || r_fatal "子女保持挂接" "复活完成后有疏散子女掉树"
import json, sys
t = json.load(open(sys.argv[1]))
desc = [l.strip() for l in open(sys.argv[2]) if l.strip()]
tree = {n['id'] for n in t['tree']['nodes']}
lost = [d for d in desc if d not in tree]
assert not lost, f"掉树: {lost}"
print(f"疏散子女 {len(desc)} 台保持挂接")
PYEOF
python3 "$SOAK_HOME/observe/g5-tree.py" "$R_DIR/topology-final.json" "$R_DIR/tree-analysis.json" \
  --nodes "$NODE_COUNT" --first-hop "$FIRST_HOP_COUNT" --child-budget "$CHILD_BUDGET" \
  || r_fatal "树形不变量" "g5-tree.py 违规（第一跳集/出度/深度/links）"
r_wait_alerts_zero 180 final
r_journal_dump "$R_DIR/journal-end.log"
r_fleet_check exit
r_verdict pass "R5 通过：第一跳删→子女疏散重挂（同步=$EVAC_SYNC）→直连复活 ${DUR}s，零 errNoCandidate，轮数符合 ≤2"
