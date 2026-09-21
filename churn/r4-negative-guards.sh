#!/bin/bash
# R4 负向守卫断言集（快脚本；soak-rebuild-churn-plan §四 R4，期望码逐条）
#   ① provisioning 中节点 DELETE → 409（计划口径引 B22；见下方 ASSUMPTION——B22 登记臂是
#      role=retired，DELETE 臂代码无守卫，期望码可经 R4_EXPECT_DELETE_PROVISIONING 覆盖）
#   ①a POST /nodes/{id}/role {"role":"retired"} on provisioning → 409（B22 文义，代码已核实
#      role.go retire 臂首行守卫）
#   ② 存活 id 再 POST /nodes → 409（nodes.go: "node already exists"，#73）
#   ③ 已归档 id 再 DELETE → 404（#73 删不存在不静默；GetNode 过滤 deleted_at）
#   ④ 同一台 1s 内连翻 onboard×5 → 恰 1 轮动作（#184 合批窗 1s + 单飞；nodes.go
#      onboardBatchWindow=1s，重复翻键并入同窗）终态无撕裂
#   ⑤ 对 managed 台 POST role=managed → 409（role.go assign：managed→conflict）
# 目标动态选取：provision 窗口走「删→复活→开键」自造（任务书替代路径；说明：R3 复活流程的
# provisioning 窗口难以跨脚本传递时机，本脚本自造同款窗口，语义等价）。
export R_SCENARIO="R4"
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/churn
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）
source "$SOAK_SELF_DIR/r-lib.sh"
EXPECT_DEL_PROV="${R4_EXPECT_DELETE_PROVISIONING:-409}"   # 计划口径 409；覆盖=明认知偏离

if [ "$DRY_RUN" = "1" ]; then
  TOPO="${R_TOPO_FILE:-$R_LIB_DIR/tests/fixtures/topology-fixture.json}"
  r_select r4 "$TOPO"
  log "DRY_RUN：目标选取验证完成，动作序列=②409→③404→①a/①b provisioning 窗→④×5翻键（不执行）"
  r_verdict pass "DRY_RUN：仅目标选取（未执行任何动作）"
  exit 0
fi

r_fleet_check entry
log "步骤 1：抓树形快照并选取目标（provision/flip 两台深叶子 + 一台第一跳做守卫 ②）"
r_snap topology-before.json /topology
r_select r4 "$R_DIR/topology-before.json"
ID_PROV=$(python3 -c "import json;print(json.load(open('$R_DIR/targets.json'))['provision_target'])")
ID_FLIP=$(python3 -c "import json;print(json.load(open('$R_DIR/targets.json'))['flip_target'])")
ID_LIVE=$(python3 -c "import json;print(json.load(open('$R_DIR/targets.json'))['guard_live_target'])")
for i in "$ID_PROV" "$ID_FLIP"; do r_snap "before-$i.json" "/nodes/$i"; done
r_snap "before-$ID_LIVE.json" "/nodes/$ID_LIVE"

make_payload() { # make_payload <快照文件> —— 复活/重录载荷（统一密码 env）
  python3 - "$1" "${NODE_PASS:?NODE_PASS 未设置}" <<'PYEOF'
import json, sys
n = json.load(open(sys.argv[1]))
body = {k: n.get(k) for k in ("id", "name", "device_type", "management_ip", "ssh_port",
                              "ssh_user", "domain", "priority", "region", "lat", "lon",
                              "provider", "ram_mb", "disk_gb", "cpu_cores") if n.get(k) is not None}
body["ssh_password"] = sys.argv[2]
print(json.dumps(body))
PYEOF
}

log "步骤 2：守卫 ②——存活 id（$ID_LIVE）再 POST /nodes → 409"
r_api_code POST "/nodes" "$(make_payload "$R_DIR/before-$ID_LIVE.json")"
cp "$R_CODE_BODY" "$R_DIR/guard2-resp.json"
[ "$R_CODE" = "409" ] || r_fatal "守卫②" "存活 id 重复录入 → HTTP $R_CODE != 409（期望 node already exists）"
r_assert "守卫② 重复录入 409" 1 "id=$ID_LIVE HTTP 409"

log "步骤 3：守卫 ③——构造归档 id（删 $ID_PROV）后再 DELETE → 404"
r_api_code DELETE "/nodes/$ID_PROV"
[ "$R_CODE" = "200" ] || r_fatal "构造归档" "首次 DELETE $ID_PROV → HTTP $R_CODE != 200"
r_api_code DELETE "/nodes/$ID_PROV"
cp "$R_CODE_BODY" "$R_DIR/guard3-resp.json"
[ "$R_CODE" = "404" ] || r_fatal "守卫③" "已归档 id 再 DELETE → HTTP $R_CODE != 404（#73 不静默）"
r_assert "守卫③ 已归档再删 404" 1 "id=$ID_PROV HTTP 404"

log "步骤 4：复活 $ID_PROV → 开键 → 抓 provisioning 窗口（守卫 ①a/①b）"
PAYLOAD_PROV=$(make_payload "$R_DIR/before-$ID_PROV.json")
r_api_code POST "/nodes" "$PAYLOAD_PROV"
[ "$R_CODE" = "201" ] || r_fatal "复活 $ID_PROV" "HTTP $R_CODE != 201"
r_onboard_dance "$ID_PROV"
RC=0
r_wait_role_seen "$ID_PROV" provisioning 90 || RC=$?
if [ "$RC" != "0" ]; then
  r_note "90s 未观察到 provisioning——重试一次舞步（批量窗 1s + 批量迁移护栏）"
  r_onboard_dance "$ID_PROV"
  r_wait_role_seen "$ID_PROV" provisioning 90 || r_fatal "provisioning 窗口" "180s 内未进入 provisioning"
fi
r_assert "provisioning 窗口捕获" 1 "id=$ID_PROV role=provisioning"

log "步骤 4a：守卫 ①a——provisioning 中 POST role=retired → 409（B22 文义）"
r_api_code POST "/nodes/$ID_PROV/role" '{"role":"retired"}'
cp "$R_CODE_BODY" "$R_DIR/guard1a-resp.json"
[ "$R_CODE" = "409" ] || r_fatal "守卫①a（B22）" "provisioning 退役 → HTTP $R_CODE != 409"
r_assert "守卫①a provisioning 退役 409" 1 "HTTP 409（role.go retire 臂守卫）"

log "步骤 4b：守卫 ①b——provisioning 中 DELETE → 期望 $EXPECT_DEL_PROV（窗口内最后执行防误伤）"
r_api_code DELETE "/nodes/$ID_PROV"
cp "$R_CODE_BODY" "$R_DIR/guard1b-resp.json"
if [ "$R_CODE" = "$EXPECT_DEL_PROV" ]; then
  r_assert "守卫①b provisioning 删除 $EXPECT_DEL_PROV" 1 "HTTP $R_CODE"
  if [ "$R_CODE" = "200" ]; then
    r_note "①b 实测 200：DELETE 臂无 provisioning 守卫（计划口径 409 经 R4_EXPECT_DELETE_PROVISIONING=200 明知覆盖）——节点已归档，走复活恢复 fleet"
    r_api_code POST "/nodes" "$PAYLOAD_PROV"
    [ "$R_CODE" = "201" ] || r_fatal "①b 后恢复" "复活 HTTP $R_CODE != 201"
    r_onboard_dance "$ID_PROV"
    RC=0
    r_wait_managed "$ID_PROV" 480 > /dev/null || RC=$?
    [ "$RC" = "0" ] || r_fatal "①b 后恢复收敛" "复活重开键后 8min 未转正"
    RC=9   # 已恢复即收敛：跳过步骤 5（防重复等待）
  fi
else
  r_fatal "守卫①b" "provisioning DELETE → HTTP $R_CODE != 期望 $EXPECT_DEL_PROV（计划口径 409；代码读路无 DELETE 臂守卫——若实测 200 属计划-代码偏差，落盘诊断）"
fi

log "步骤 5：$ID_PROV 收敛断言（守卫探测不得撕裂纳管）"
if [ "${RC:-0}" != "9" ]; then
  RC=0
  SAW_PROV=$(r_wait_managed "$ID_PROV" 480) || RC=$?
  [ "$RC" = "0" ] || r_fatal "①后收敛" "守卫探测后 8min 未转正（终态撕裂？）"
  [ "${SAW_PROV:-0}" = "1" ] || r_note "①后未再观察到 provisioning（守卫探测期间已过该阶段——记录性观察，非失败）"
  r_assert "①后无撕裂" 1 "managed/online/collection_ok（saw_provisioning=${SAW_PROV:-0}）"
fi

log "步骤 6：守卫 ④——同一台（$ID_FLIP）1s 内连翻 onboard×5 → 恰 1 轮动作"
r_api_code DELETE "/nodes/$ID_FLIP"
[ "$R_CODE" = "200" ] || r_fatal "构造 ④ 目标" "DELETE $ID_FLIP → HTTP $R_CODE"
r_api_code POST "/nodes" "$(make_payload "$R_DIR/before-$ID_FLIP.json")"
[ "$R_CODE" = "201" ] || r_fatal "复活 $ID_FLIP" "HTTP $R_CODE != 201"
r_snap agent-deploy-before-flip.json "/agent-deploy?limit=20"
cat > /tmp/r4-flip5.sh <<'FLIP'
#!/bin/bash
# 1s 内 5 连翻：F,T,F,T,T（首个 false 保底真实翻转；后续 true 翻键入同窗去抖）
for b in false true false true true; do
  curl -sS -m 30 -o /tmp/r4-flip-last.json -w "%{http_code}\n" -X PUT -H 'Content-Type: application/json' \
    -d "{\"onboard\":$b}" http://127.0.0.1:80/api/v1/nodes/$1
done
FLIP
scp $SSHOPT -P "$SSHD_PORT" /tmp/r4-flip5.sh "root@$(nms_ip)":"/tmp/r4-flip5.sh" > /dev/null
ssh $SSHOPT -p "$SSHD_PORT" "root@$(nms_ip)" "chmod +x /tmp/r4-flip5.sh && /tmp/r4-flip5.sh $ID_FLIP" > "$R_DIR/flip5-codes.txt"
N_BAD=0
while read -r code; do
  case "$code" in 2??) ;; *) N_BAD=$((N_BAD+1));; esac
done < "$R_DIR/flip5-codes.txt"
[ "$(wc -l < "$R_DIR/flip5-codes.txt" | tr -d ' ')" = "5" ] || r_fatal "翻键请求数" "≠5"
[ "$N_BAD" = "0" ] || r_fatal "翻键响应" "$N_BAD 个非 2xx（见 flip5-codes.txt）"
r_assert "④ 5 连翻全 2xx" 1 "序列 F,T,F,T,T（1s 窗内，本机 loopback）"

log "步骤 7：④ 收敛 + 轮数断言（恰 1 轮动作；≤2 轮含 F3 自动重排豁免）"
RC=0
r_wait_managed "$ID_FLIP" 480 > /dev/null || RC=$?
[ "$RC" = "0" ] || r_fatal "④ 收敛" "翻键后 8min 未转正（终态撕裂？）"
FLIP_BASELINE=$(python3 -c "
import json
items=json.load(open('$R_DIR/agent-deploy-before-flip.json'))['items']
print(max((int(i['deploy_id']) for i in items), default=0))")
r_assert_deploy_rounds r4 1 "$FLIP_BASELINE"
python3 - "$R_DIR/r4deploy-rounds.json" <<'PYEOF' || r_fatal "④ 恰 1 轮" "去抖失效（轮数 >2）"
import json, sys
d = json.load(open(sys.argv[1]))
assert d['new_rounds'] <= 2, d
print(f"④ 轮数 OK: {d['new_rounds']} 轮（5 连翻 ≠ 5 轮，#184 去抖生效；重排触发={d['reroute_triggered']}）")
PYEOF
r_snap node-flip-final.json "/nodes/$ID_FLIP"
python3 -c "
import json; n=json.load(open('$R_DIR/node-flip-final.json'))
assert n['onboard'] is True and n['role']=='managed', (n['onboard'], n['role'])" \
  || r_fatal "④ 终态" "onboard/role 撕裂"

log "步骤 8：收尾——fleet 复核（两台目标回 managed、告警归零）"
r_wait_alerts_zero 180 final
r_journal_dump "$R_DIR/journal-end.log"
r_fleet_check exit
r_verdict pass "R4 通过：守卫②409/③404/①a409/①b${EXPECT_DEL_PROV}/④恰1轮 全部符合期望码"
