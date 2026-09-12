#!/bin/bash
# R2 批量 删→批量重导→同窗开键 8 台（soak-rebuild-churn-plan §四 R2；scale-coldstart-churn-plan §三）
# 验证点：#183 批量护栏 / #184 合批（8 台合 1 轮 ProvisionBatch）/ #123 F3 自动重排口径
# 流程：选 8 台深度 ≥2 叶子（跨 ≥2 父；syd1/atl1/fra1 优先非硬性）→ DELETE×8 →
#       POST /topology 重导 8 台 → burst false×8 + 1s 窗内 8×PUT true（P74：重导不翻键，
#       须真实 false→true 翻转才触发 #111）→ 收敛断言（全转正、≤2 轮、终轮 succeeded）。
# 判定：partial 出现即记录（≤2 轮口径观察自动重排）；总时长记录不判 FAIL（verdict 备注）。
export R_SCENARIO="R2"
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/churn
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）
source "$SOAK_SELF_DIR/r-lib.sh"
R2_N="${R2_N:-8}"   # 批量台数（spec=8）

if [ "$DRY_RUN" = "1" ]; then
  TOPO="${R_TOPO_FILE:-$R_LIB_DIR/tests/fixtures/topology-fixture.json}"
  r_select r2 "$TOPO"
  log "DRY_RUN：目标选取验证完成，动作序列=DELETE×$R2_N→重导→同窗开键→1 轮断言（不执行）"
  r_verdict pass "DRY_RUN：仅目标选取（未执行任何动作）"
  exit 0
fi

r_fleet_check entry
log "步骤 1：抓树形快照并选取 $R2_N 台目标（深度≥2 叶子、跨≥2 父、syd1/atl1/fra1 优先）"
r_snap topology-before.json /topology
r_select r2 "$R_DIR/topology-before.json"
python3 - "$R_DIR/targets.json" "$R2_N" <<'PYEOF' || r_fatal "目标清单校验" "targets 不满足台数/跨父要求"
import json, sys
t = json.load(open(sys.argv[1])); n = int(sys.argv[2])
assert len(t['targets']) == n, t['targets']
assert len(t['parents']) >= 2, t['parents']
PYEOF
mapfile -t IDS < <(python3 -c "
import json
print('\n'.join(json.load(open('$R_DIR/targets.json'))['targets']))")
printf '%s\n' "${IDS[@]}" > "$R_DIR/target-ids.txt"

log "步骤 2：逐台删除前快照 + 部署轮基线"
mkdir -p "$R_DIR/before"
for id in "${IDS[@]}"; do
  r_snap "before/$id.json" "/nodes/$id" || r_fatal "读目标节点" "GET /nodes/$id 失败"
done
python3 - "$R_DIR" "${IDS[0]}" <<'PYEOF' || r_fatal "目标状态校验" "存在非 managed/domain!=1 台"
import json, sys, os
rdir, first = sys.argv[1], sys.argv[2]
n = json.load(open(f'{rdir}/before/{first}.json'))
assert n['role'] == 'managed' and n['domain'] == 1, (first, n['role'], n['domain'])
print("目标状态 OK（managed/domain=1，抽查首台）")
PYEOF
r_snap agent-deploy-before.json "/agent-deploy?limit=20"
DEPLOY_BASELINE=$(python3 -c "
import json
items=json.load(open('$R_DIR/agent-deploy-before.json'))['items']
print(max((int(i['deploy_id']) for i in items), default=0))")

log "步骤 3：DELETE×$R2_N（叶子删除，逐台断言 200）"
for id in "${IDS[@]}"; do
  r_api_code DELETE "/nodes/$id"
  [ "$R_CODE" = "200" ] || r_fatal "DELETE $id" "HTTP $R_CODE != 200"
done
r_snap topology-after-delete.json /topology
python3 - "$R_DIR/topology-after-delete.json" "$R_DIR/target-ids.txt" <<'PYEOF' || r_fatal "归档断言" "仍有目标在 nodes[]/树中"
import json, sys
t = json.load(open(sys.argv[1]))
ids = {l.strip() for l in open(sys.argv[2]) if l.strip()}
left = {n['id'] for n in t['nodes']} & ids
assert not left, f"未归档: {left}"
assert not ({n['id'] for n in t['tree']['nodes']} & ids), "树中仍有目标"
print(f"归档断言 OK：{len(ids)} 台从列表/树消失")
PYEOF

log "步骤 4：POST /topology 重导 $R2_N 台（载荷=删除前快照 + 统一密码）"
PAYLOAD=$(python3 - "$R_DIR" "$R_DIR/target-ids.txt" "${NODE_PASS:?NODE_PASS 未设置}" <<'PYEOF'
import json, sys
rdir, ids_file, pw = sys.argv[1], sys.argv[2], sys.argv[3]
ids = [l.strip() for l in open(ids_file) if l.strip()]
out = []
for i in ids:
    n = json.load(open(f'{rdir}/before/{i}.json'))
    m = {k: n.get(k) for k in ("id", "name", "device_type", "management_ip", "ssh_port", "ssh_user",
                               "domain", "priority", "region", "lat", "lon", "bandwidth_mbps",
                               "provider", "ram_mb", "disk_gb", "cpu_cores", "cost_monthly",
                               "provisioned_at") if n.get(k) is not None}
    m["ssh_password"] = pw
    out.append(m)
print(json.dumps({"nodes": out}))
PYEOF
)
printf '%s' "$PAYLOAD" > "$R_DIR/import-payload.json"
r_api_code POST "/topology" "$(cat "$R_DIR/import-payload.json")"
cp "$R_CODE_BODY" "$R_DIR/import-resp.json"
python3 - "$R_DIR/import-resp.json" "$R2_N" <<'PYEOF' || r_fatal "重导断言" "status/nodes 计数不符"
import json, sys
d = json.load(open(sys.argv[1])); n = int(sys.argv[2])
assert d.get('status') == 'imported' and d.get('nodes') == n, d
print(f"重导 OK: imported {n} 台")
PYEOF
r_snap nodes-after-import.json /nodes
python3 - "$R_DIR/nodes-after-import.json" "$R_DIR/target-ids.txt" <<'PYEOF' || r_fatal "重导后状态" "存在非 idle 台"
import json, sys
items = json.load(open(sys.argv[1]))['items']
ids = {l.strip() for l in open(sys.argv[2]) if l.strip()}
bad = [n['id'] for n in items if n['id'] in ids and n['role'] != 'idle']
assert not bad, f"非 idle: {bad}"
print(f"重导后 OK: {len(ids)} 台全 idle（onboard 继承 true——归档/导入均不翻键，#99）")
PYEOF

log "步骤 5：P74 舞步 + 1s 窗内 8×PUT onboard=true（#184 合批窗口；NMS 本机爆发保窗）"
cat > /tmp/r2-burst.sh <<'BURST'
#!/bin/bash
# phase F：逐台翻 false（串行快）；phase T：窗内并行翻 true（s5 同款）
for id in "$@"; do
  curl -sS -m 30 -o /dev/null -X PUT -H 'Content-Type: application/json' \
    -d '{"onboard":false}' http://127.0.0.1:80/api/v1/nodes/$id
done
for id in "$@"; do
  ( code=$(curl -sS -m 30 -o /tmp/r2-put-$id.json -w "%{http_code}" -X PUT -H 'Content-Type: application/json' \
      -d '{"onboard":true}' http://127.0.0.1:80/api/v1/nodes/$id)
    echo "$code $id" >> /tmp/r2-codes.txt ) &
done
wait
sort /tmp/r2-codes.txt
BURST
scp $SSHOPT -P 22 /tmp/r2-burst.sh "root@$(nms_ip)":"/tmp/r2-burst.sh" > /dev/null
ssh $SSHOPT -p 22 "root@$(nms_ip)" "rm -f /tmp/r2-codes.txt; chmod +x /tmp/r2-burst.sh && /tmp/r2-burst.sh $(tr '\n' ' ' < "$R_DIR/target-ids.txt")" \
  > "$R_DIR/burst-codes.txt"
T_KICK=$(date +%s)
N_FAIL=0
while read -r code id; do
  case "$code" in 2??) ;; *) log "PUT true $id -> HTTP $code"; N_FAIL=$((N_FAIL+1));; esac
done < "$R_DIR/burst-codes.txt"
[ "$(wc -l < "$R_DIR/burst-codes.txt" | tr -d ' ')" = "$R2_N" ] || r_fatal "开键响应数" "不足 $R2_N 行"
[ "$N_FAIL" = "0" ] || r_fatal "开键 PUT" "$N_FAIL 个失败响应（见 burst-codes.txt）"

log "步骤 6：收敛轮询（≤15min，8/8 managed/online/collection_ok）"
DEADLINE=$(( $(date +%s) + 900 )); CONV=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  r_snap nodes-live.json /nodes || { sleep 10; continue; }
  OK=$(python3 - "$R_DIR/nodes-live.json" "$R_DIR/target-ids.txt" <<'PYEOF'
import json, sys
items = {n['id']: n for n in json.load(open(sys.argv[1]))['items']}
ids = [l.strip() for l in open(sys.argv[2]) if l.strip()]
print(sum(1 for i in ids
          if i in items and items[i]['role'] == 'managed'
          and items[i]['status'] == 'online'
          and items[i]['collection_state'] == 'collection_ok'))
PYEOF
)
  log "  收敛进度 $OK/$R2_N"
  [ "$OK" = "$R2_N" ] && { CONV=1; break; }
  sleep 5
done
T_CONV=$(date +%s)
[ "$CONV" = "1" ] || r_fatal "收敛超时" "15min 内未 8/8 转正（现场见 nodes-live.json）"
DUR=$((T_CONV - T_KICK))
r_timing "burst_to_converged_s" "$DUR"

log "步骤 7：部署轮断言（合 1 轮主轮 nodes=$R2_N；≤2 轮口径含 F3 自动重排；终轮 succeeded）"
r_assert_deploy_rounds r2 "$R2_N" "$DEPLOY_BASELINE"
if python3 -c "
import json; d=json.load(open('$R_DIR/r2deploy-rounds.json')); exit(0 if d['new_rounds'] == 1 else 1)"; then
  r_assert "合批=1 轮" 1 "新轮数=1（#184 合批生效）"
else
  r_note "partial→自动重排触发：新轮数=2（首轮 partial 传输类失败集 stay-provisioning 重排，#123）——按 ≤2 轮口径记录，原因见 deploy 轮详情与 journal"
  r_snap "r2-deploy-detail.json" "/agent-deploy/$(python3 -c "
import json; print(json.load(open('$R_DIR/r2deploy-rounds.json'))['rounds'][0][0])")" \
    || true
fi

log "步骤 8：树形不变量 + 告警清零 + 总时长记录（对照折算不判 FAIL）"
r_snap topology-final.json /topology
python3 "$SOAK_HOME/observe/g5-tree.py" "$R_DIR/topology-final.json" "$R_DIR/tree-analysis.json" \
  --nodes "$NODE_COUNT" --first-hop "$FIRST_HOP_COUNT" --child-budget "$CHILD_BUDGET" \
  || r_fatal "树形不变量" "g5-tree.py 违规（见 tree-analysis.json）"
# 折算基线：28 台全量 4m02s@dc12（run-benchmark 头条）线性折算 8 台 ≈ 69s——记录进备注
BASELINE_SCALED=$((242 * R2_N / 28))
r_note "总时长 ${DUR}s（burst→8/8 收敛）；对照折算基线 ≈${BASELINE_SCALED}s（28 台 242s 线性折算，dc=12）——按计划口径记录不判 FAIL"
r_wait_alerts_zero 180 final
r_journal_dump "$R_DIR/journal-end.log"
r_fleet_check exit
r_verdict pass "R2 通过：8 台删→重导→同窗开键（${DUR}s，轮情况见 r2deploy-rounds.json）"
