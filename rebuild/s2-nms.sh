#!/bin/bash
# S2 重建 NMS：构建(main) → 建机(user-data6) → 推二进制 → 健康 → 配置四键
#（v3.3/v3.4 零防火墙口径：原「防火墙收口」段已删除——NMS 不挂任何云防火墙；
#  80 公网可达性由票 2 WG 单绑接管，公网:80 不通∧隧道:80 通双断言见 env-verify）
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/rebuild
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）
cd "$REBUILD_DIR"
mkdir -p "$EVIDENCE/s2"
exec > >(tee "$EVIDENCE/s2/log.txt") 2>&1

# ---- 票 1-B：检查点分段 + DRY（v3.4）----
# DRILL_S2_STOP_AFTER=create（阶段 1 判据：droplet active+网络活）| ssh（阶段 2：高位口
# ssh/scp 通；WG 握手随票 2 在此插桩）| full（缺省：全程含 bin/health/四键）。
# DRILL_ATTEMPT=ladder attempt 序号（连续绿计数依据，默认 1）；DRY_RUN=1 零网络只跑本地断言。
STOP_AFTER="${DRILL_S2_STOP_AFTER:-full}"
DRY_RUN="${DRY_RUN:-0}"
DRILL_ATTEMPT="${DRILL_ATTEMPT:-1}"
case "$STOP_AFTER" in create|ssh|full) ;; *) echo "ABORT: DRILL_S2_STOP_AFTER=$STOP_AFTER 非法（create|ssh|full）" >&2; exit 1;; esac
if [ "$DRY_RUN" = "1" ]; then
  log "DRY：零网络——只跑本地断言（STOP_AFTER=$STOP_AFTER/ATTEMPT=$DRILL_ATTEMPT 仅记录）"
  mkdir -p "$EVIDENCE/s2"
  # 密钥经文件句柄传递（NMS_WG_PRIV_FILE/PEER_PUB_FILE）：进程环境/命令行零私钥值
  WGTMP=$(mktemp -d)
  wg genkey > "$WGTMP/nms.priv"; wg genkey > "$WGTMP/orch.priv"
  wg pubkey < "$WGTMP/orch.priv" > "$WGTMP/orch.pub"
  NMS_WG_PRIV_FILE="$WGTMP/nms.priv" NMS_WG_PEER_PUB_FILE="$WGTMP/orch.pub" \
    instantiate_user_data "$SOAK_HOME/rebuild/nms-user-data6-ascii.sh" "$REBUILD_DIR/dry-nms-user-data.sh"
  instantiate_user_data "$SOAK_HOME/rebuild/node-user-data-ascii.sh" "$REBUILD_DIR/dry-node-user-data.sh"
  rm -f "$REBUILD_DIR/dry-nms-user-data.sh" "$REBUILD_DIR/dry-node-user-data.sh"
  rm -rf "$WGTMP"
  bash "$SOAK_HOME/tools/port22-gate.sh"
  log "DRY：模板实例化（含 WG 占位符）+端口门全过（s2 真网动作全部跳过）"
  exit 0
fi
stage_verdict() { # stage_verdict <phase 1|2|3> <rung|null> <note>
  local ph=$1 rg_=$2 note=$3
  mkdir -p "$SOAK_ENV/verdicts" "$EVIDENCE/s2"
  local rb="$EVIDENCE/s2/stage-runbook-p$ph-a$DRILL_ATTEMPT.json"
  python3 - "$rb" "$ph" "$STOP_AFTER" "$note" <<'PYEOF'
import json, sys
ph, stop, note = sys.argv[2], sys.argv[3], sys.argv[4]
fields = {"inject": f"DRILL_S2_STOP_AFTER={stop}", "proof_before": "evidence/s2/log.txt 全程",
          "proof_effective": note, "exercise": f"阶段 {ph} 判据", "observe": "s2 log.txt",
          "recover": "attempt 收尾按阶梯口径拆净（s1/s1.5）", "proof_after": "verdict 本行",
          "cleanup": "同 recover"}
json.dump(fields, open(sys.argv[1], "w"), ensure_ascii=False)
PYEOF
  python3 "$SOAK_HOME/observe/verdict.py" write "$SOAK_ENV/verdicts/ladder.jsonl" \
    --carrier "阶梯点亮（非矩阵）" --scenario "stage${ph}-${STOP_AFTER}-attempt${DRILL_ATTEMPT}" \
    --runbook "$rb" --verdict PASS --commit "$(git -C "$NMS2_REPO" rev-parse --short HEAD)" \
    --evidence "evidence/s2/log.txt" --notes "$note" \
    --stage "{\"phase\":${ph},\"rung\":${rg_:-null},\"attempt\":${DRILL_ATTEMPT},\"form\":null}" \
    --channel "{\"nms_ssh_via\":\"${NMS_SSH_VIA}\",\"wg_handshake\":${WG_HANDSHAKE_TS:-null}}"
}

check_egress
[ -f "$EVIDENCE/s1/post-inventory.json" ] || { echo "ABORT: S1 未执行" >&2; exit 1; }

log "断言仓库状态：main == $EXPECT_HEAD 且工作区干净"
cd "$NMS2_REPO"
HEAD_SHA=$(git describe --tags --always --dirty)
[ "$HEAD_SHA" = "$EXPECT_HEAD" ] || gate S2 FAIL "HEAD=$HEAD_SHA != $EXPECT_HEAD"
[ -z "$(git status --porcelain --untracked-files=no)" ] || gate S2 FAIL "已跟踪文件不干净（未跟踪文档不进构建，放行）"
log "构建 server + agent 发布物"
make build build-agent >> "$EVIDENCE/s2/build.log" 2>&1
sha256sum bin/nms bin/nms-agent-linux | tee "$EVIDENCE/s2/bin-sha256.txt"
cd "$REBUILD_DIR"

log "建 NMS 机（s-4vcpu-8gb/$NMS_REGION，user-data6，等 active；已有 nms.json 则续跑复用）"
# P70①：账号 ssh_password 与 --user-data 互斥——NMS 建机用去掉密码的临时账号配置
# （密码由 user-data 模板自设，同一值）；临时配置只含 NMS_ACCOUNT（env.local 注入）。
# 复用探针带重试（Round1 实录：stunnel443 通道冷启动瞬断一次即判死，白重建一台机）：
# 3 次×10s 间隔，全败才清记录重建。
reuse_ok=""
if [ -f "$EVIDENCE/s2/nms.json" ]; then
  OLD_IP=$(python3 -c "import json;print(json.load(open('evidence/s2/nms.json'))['ip'])")
  for _try in 1 2 3; do
    if ssh $SSHOPT -p "$SSHD_PORT" "root@$OLD_IP" true 2>/dev/null; then reuse_ok=1; break; fi
    [ "$_try" = "3" ] || sleep 10
  done
fi
# 复用但密钥缺失=远端 wg0.conf 配不回（握手必败）——降级重建（v3.4 票 2）
if [ -n "$reuse_ok" ] && [ ! -f "$EVIDENCE/s2/wg/nms.priv" ]; then
  log "复用机但 evidence/s2/wg 密钥缺失——降级重建"
  reuse_ok=""
fi
if [ -n "$reuse_ok" ]; then
  log "续跑：复用已建 droplet $(python3 -c "import json;d=json.load(open('evidence/s2/nms.json'));print(d['name'],d['ip'],d['id'])")"
  export NMS_WG_PRIV_FILE="$EVIDENCE/s2/wg/nms.priv" NMS_WG_PEER_PUB_FILE="$EVIDENCE/s2/wg/orch.pub"
else
  [ -f "$EVIDENCE/s2/nms.json" ] && log "记录的 droplet 3 次探活全败——清记录重建"
  rm -f "$EVIDENCE/s2/nms.json"
  log "生成 WG 密钥对（本轮专用、跨演练不复用；0600 落 evidence/s2/wg/ 不入库，经文件句柄传递零环境值）"
  mkdir -p "$EVIDENCE/s2/wg" && chmod 700 "$EVIDENCE/s2/wg"
  wg genkey > "$EVIDENCE/s2/wg/nms.priv"
  wg genkey > "$EVIDENCE/s2/wg/orch.priv"
  wg pubkey < "$EVIDENCE/s2/wg/nms.priv"  > "$EVIDENCE/s2/wg/nms.pub"
  wg pubkey < "$EVIDENCE/s2/wg/orch.priv" > "$EVIDENCE/s2/wg/orch.pub"
  chmod 600 "$EVIDENCE/s2/wg/"*.priv "$EVIDENCE/s2/wg/"*.pub
  export NMS_WG_PRIV_FILE="$EVIDENCE/s2/wg/nms.priv" NMS_WG_PEER_PUB_FILE="$EVIDENCE/s2/wg/orch.pub"
TMPACCT="$EVIDENCE/s2/accounts-nms.json"
python3 - <<'EOF'
import json, os
cfg = json.load(open(os.environ['VPSCTL_ACCOUNTS']))
accts = cfg['accounts'] if isinstance(cfg, dict) else cfg
nms_acct = [dict(a) for a in accts if a['name'] == os.environ['NMS_ACCOUNT']]
assert len(nms_acct) == 1
nms_acct[0].pop('ssh_password', None)
json.dump({"accounts": nms_acct}, open('evidence/s2/accounts-nms.json', 'w'))
os.chmod('evidence/s2/accounts-nms.json', 0o600)
EOF
log "实例化 user-data 模板（__NODE_PASS__ ← env.local NODE_PASS；仓内模板零凭据，实例化件落运行时目录不入库）"
instantiate_user_data "$SOAK_HOME/rebuild/nms-user-data6-ascii.sh" "$REBUILD_DIR/nms-user-data6-ascii.sh"
"$VPSCTL" create -accounts "$TMPACCT" -image ubuntu-24-04-x64 -region "$NMS_REGION" -size s-4vcpu-8gb \
  -count 1 -name-prefix "$NMS_NAME_PREFIX" \
  -user-data "$REBUILD_DIR/nms-user-data6-ascii.sh" -tags env:soak -wait 600s \
  -output "$EVIDENCE/s2/create-nms.json" > /dev/null
python3 - <<'EOF'
import json
d = json.load(open('evidence/s2/create-nms.json'))
c = [x for x in d['created'] if x.get('status') == 'active']
assert len(c) == 1, f"created active != 1: {d}"
n = c[0]
json.dump({"id": n['id'], "name": n['name'], "ip": n['ipv4_public'],
           "region": n['region'], "size": n['size']}, open('evidence/s2/nms.json', 'w'), indent=1)
print("NMS:", n['name'], n['ipv4_public'], "droplet", n['id'])
EOF
fi
NMS_ID=$(python3 -c "import json;print(json.load(open('evidence/s2/nms.json'))['id'])")
nms_ip_from_json=$(python3 -c "import json;print(json.load(open('evidence/s2/nms.json'))['ip'])")
echo "$nms_ip_from_json" > "$NMS_IP_FILE"
log "生成编排机侧 wg0.conf（10.100.0.2/32 → $nms_ip_from_json:51820，keepalive 25，MTU 1420）"
{
  printf '[Interface]\nAddress = 10.100.0.2/32\nMTU = 1420\nPrivateKey = '
  cat "$EVIDENCE/s2/wg/orch.priv"
  printf '\n[Peer]\nPublicKey = '
  cat "$EVIDENCE/s2/wg/nms.pub"
  printf '\nEndpoint = %s:51820\nAllowedIPs = 10.100.0.1/32\nPersistentKeepalive = 25\n' "$nms_ip_from_json"
} > "$EVIDENCE/s2/wg/wg0.conf"
chmod 600 "$EVIDENCE/s2/wg/wg0.conf"
#（ISS-006：conf 文件名即 wg-quick 接口名——原名 wg0-client.conf 起的接口叫 wg0-client，
# 而 wg show/ping 写死 wg0 → 握手检查必炸；更名后接口名=wg0，与全部探针一致）
# stunnel443 形态：新机 IP 落盘即刷新 ~/.ssh/config 托管块——Round 协议每轮拆旧建新换 IP，
# 仅靠 env.sh source 期刷新会滞后一轮（attempt2/3 实录两次 sshd 等待窗空烧）。
declare -F nms_ssh_cfg_update >/dev/null && nms_ssh_cfg_update
log "出生网络探针（TCP $SSHD_PORT socket 级，无需凭据；30×10s 窗——首机 user-data 需 1-2min）"
ok=""
for i in $(seq 1 30); do
  python3 -c "import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=8).close()" \
    "$nms_ip_from_json" "$SSHD_PORT" 2>/dev/null && { ok=1; break; }
  sleep 10
done
[ -n "$ok" ] || gate S2/CREATE FAIL "出生网络 5min 未活（TCP $SSHD_PORT 全败——查 DO 控制台/console）"
if [ "$STOP_AFTER" = "create" ]; then
  stage_verdict 1 null "droplet active 且网络活（TCP $SSHD_PORT）"
  gate S2/CREATE PASS "阶段 1 判据达成（STOP_AFTER=create；attempt 收尾按阶梯口径拆净）"
  exit 0
fi
log "等待 sshd($SSHD_PORT) 就绪"
ok=""
for i in $(seq 1 80); do
  if ssh $SSHOPT -p "$SSHD_PORT" "root@$nms_ip_from_json" true 2>/dev/null; then ok=1; break; fi
  sleep 15
done
[ -n "$ok" ] || gate S2 FAIL "sshd 20min 未就绪"
log "scp 冒烟（阶段 2 判据：scp 通——推/回读/清理三步）"
printf 'nmsctl-scp-probe-%s\n' "$(date -u +%FT%TZ)" > "$EVIDENCE/s2/scp-probe.txt"
nms_scp "$EVIDENCE/s2/scp-probe.txt" "root@$nms_ip_from_json:/tmp/nmsctl-scp-probe" > /dev/null
nms_ssh 'cat /tmp/nmsctl-scp-probe' | grep -q '^nmsctl-scp-probe-' || gate S2/SSH FAIL "scp 回读不一致"
nms_ssh 'rm -f /tmp/nmsctl-scp-probe'
log "WG 隧道置备（编排机侧 wg-quick 幂等重启 → 握手 → 隧道 ping → 公网 :80 负断言）"
sudo wg-quick down "$EVIDENCE/s2/wg/wg0.conf" >/dev/null 2>&1 || true
sudo wg-quick up "$EVIDENCE/s2/wg/wg0.conf" >/dev/null
WG_HANDSHAKE_TS=null
hs_ok=""
for i in $(seq 1 24); do
  _hs=$(sudo wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
  if [ -n "$_hs" ] && [ "$_hs" -gt 0 ] 2>/dev/null; then
    WG_HANDSHAKE_TS="$(date -u -d "@$_hs" +%FT%TZ)"; hs_ok=1; break
  fi
  sleep 5
done
if [ -z "$hs_ok" ]; then
  sudo wg-quick down "$EVIDENCE/s2/wg/wg0.conf" >/dev/null 2>&1 || true
  gate S2/SSH FAIL "WG 握手 2min 未成（UDP 51820/密钥/端点——对照 C0 结论与 evidence/s2/wg/）"
fi
ping -c 3 -W 2 10.100.0.1 >/dev/null 2>&1 || gate S2/SSH FAIL "隧道 ping 10.100.0.1 不通（握手成而包不通=路由/MTU）"
if curl -sS -m 5 "http://$nms_ip_from_json/api/v1/health" >/dev/null 2>&1; then
  gate S2/SSH FAIL "公网 :80 意外可达（v3.4 应只在隧道 10.100.0.1 上）"
fi
log "WG 握手 $WG_HANDSHAKE_TS；隧道 ping 通；公网 :80 不可达 ✓（隧道 :80 正向断言随 STOP_AFTER=full 的 health+票 3 env-verify）"
if [ "$STOP_AFTER" = "ssh" ]; then
  stage_verdict 2 null "高位口 ssh/scp 通+WG 握手+隧道 ping+公网 :80 拒（通道=$NMS_SSH_VIA）"
  gate S2/SSH PASS "阶段 2 判据达成（STOP_AFTER=ssh）"
  exit 0
fi
log "推送（或 sha 校验跳过）二进制——运行中的 nms 会 ETXTBSY，不一致时先停服务"
REMOTE_NMS_SHA=$(ssh $SSHOPT -p "$SSHD_PORT" "root@$nms_ip_from_json" 'sha256sum /opt/nms/nms 2>/dev/null | cut -d" " -f1' || echo none)
LOCAL_NMS_SHA=$(sha256sum "$NMS2_REPO/bin/nms" | cut -d' ' -f1)
if [ "$LOCAL_NMS_SHA" = "$REMOTE_NMS_SHA" ]; then
  log "nms 二进制 sha 一致，跳过推送"
else
  ssh $SSHOPT -p "$SSHD_PORT" "root@$nms_ip_from_json" 'systemctl stop nms 2>/dev/null || true'
  nms_scp "$NMS2_REPO/bin/nms" "root@$nms_ip_from_json:/opt/nms/nms" > /dev/null
fi
REMOTE_AG_SHA=$(ssh $SSHOPT -p "$SSHD_PORT" "root@$nms_ip_from_json" 'sha256sum /opt/nms/agents/nms-agent-linux 2>/dev/null | cut -d" " -f1' || echo none)
LOCAL_AG_SHA=$(sha256sum "$NMS2_REPO/bin/nms-agent-linux" | cut -d' ' -f1)
if [ "$LOCAL_AG_SHA" = "$REMOTE_AG_SHA" ]; then
  log "agent 发布物 sha 一致，跳过推送"
else
  nms_scp "$NMS2_REPO/bin/nms-agent-linux" "root@$nms_ip_from_json:/opt/nms/agents/nms-agent-linux" > /dev/null
fi
ssh $SSHOPT -p "$SSHD_PORT" "root@$nms_ip_from_json" 'chmod 755 /opt/nms/nms /opt/nms/agents/nms-agent-linux && mkdir -p /var/log/journal && systemctl restart systemd-journald'

log "等待 TimescaleDB 容器就绪（user-data apt+compose 需数分钟）"
ok=""
for i in $(seq 1 60); do
  if ssh $SSHOPT -p "$SSHD_PORT" "root@$nms_ip_from_json" \
    'docker ps --format "{{.Names}}" | grep -q nms-timescaledb' 2>/dev/null; then ok=1; break; fi
  sleep 15
done
[ -n "$ok" ] || gate S2 FAIL "PG 容器 15min 未就绪（查 /var/log/bootstrap.log）"
log "PG 就绪；等自举完成标记（BOOTSTRAP-OK = unit 文件/stunnel 全就位，P75 教训）"
ssh $SSHOPT -p "$SSHD_PORT" "root@$nms_ip_from_json" 'for i in $(seq 1 60); do grep -q BOOTSTRAP-OK /var/log/bootstrap.log 2>/dev/null && exit 0; sleep 5; done; echo MARKER-TIMEOUT; exit 1'
log "重启 nms 服务并轮询 /health（API 腿=隧道 $NMS_API_ADDR）"
ssh $SSHOPT -p "$SSHD_PORT" "root@$nms_ip_from_json" 'systemctl restart nms'
ok=""
for i in $(seq 1 60); do
  if curl -sS -m 8 "http://$NMS_API_ADDR/api/v1/health" 2>/dev/null | grep -q '"status":"ok"'; then ok=1; break; fi
  sleep 5
done
[ -n "$ok" ] || gate S2 FAIL "health 5min 未就绪（隧道 $NMS_API_ADDR——先核 WG 握手）"
curl -sS "http://$NMS_API_ADDR/api/v1/health" | tee "$EVIDENCE/s2/health.json"; echo

#（v3.3 零防火墙口径：原 P71「防火墙收口+塑形断言」段整体删除——出口白名单/
#  FW_SOAK_NMS/DRILL_FW_EXTRA_SOURCES 机制退役，Round 1 遗留云 fw 资源随盘点清理，
#  替代断言=env-verify 公网:80 不通 ∧ 隧道:80 通（v3.4 票 3）。）

log "写入配置（python 构造 JSON——防 shell 引号拼接出字面 \$）"
CONF=$(python3 -c "
import json, os
d = {'child_budget': 3, 'deploy_concurrency': int(os.environ.get('DEPLOY_CONCURRENCY', '12')),
     'discover_concurrency': 16, 'handshake_pace': 100, 'resweep_interval': 60,
     'dial_timeout_ms': 20000}  # P78 根治 #125：拨号段独立预算；拉取两键回缺省 2500/2000（临时缓解 10000/8000 退役）
if os.environ.get('BENCH_EXTRA_CONFIG'):
    d.update(json.loads('{' + os.environ['BENCH_EXTRA_CONFIG'] + '}'))
print(json.dumps(d))")
api PUT /config "$CONF" > "$EVIDENCE/s2/config-put.json"
api GET /config > "$EVIDENCE/s2/config-get.json"
python3 - <<'EOF'
import json, os
want = {"child_budget": 3, "deploy_concurrency": int(os.environ.get("DEPLOY_CONCURRENCY", "12")), "discover_concurrency": 16, "handshake_pace": 100, "resweep_interval": 60,
        "dial_timeout_ms": 20000}
if os.environ.get("BENCH_EXTRA_CONFIG"):
    import json as _j
    want.update(_j.loads("{" + os.environ["BENCH_EXTRA_CONFIG"] + "}"))
# 实效对账（ISS-003 教训，2026-09-21 用户口径：「判断当前环境和代码上的环境配不配得上」）：
# 对 GET 回读断言而非 PUT 回显——回显只证明"我们发了什么"，不证明"系统收下了什么"
# （attempt3 实录：BENCH 未传到子进程时 PUT 悟空、GET 全注册表缺省，回显断言照样绿）。
got = {i['key']: i['value'] for i in json.load(open('evidence/s2/config-get.json'))['items']}
bad = {k: {"got": got.get(k), "want": v} for k, v in want.items() if got.get(k) != v}
assert not bad, f"配置实效不符（GET≠want）: {bad}"
print("config OK（GET 实效对账）:", want)
EOF
git -C "$NMS2_REPO" describe --tags --always > "$EVIDENCE/expected-agent-version.txt"
log "期望 agent 版本：$(cat "$EVIDENCE/expected-agent-version.txt")"
# 票 7：阶梯出口接健康闸（wave 级）——防「阶梯绿但正式轮轮末闸必红」断层；结果入 verdict（票 0-9 语义）
python3 "$SOAK_HOME/drill/health-gate.py" --level wave --expect-converged \
  --evidence-root "$SOAK_ENV" --commit "$(git -C "$NMS2_REPO" rev-parse --short HEAD)" \
  --notes "s2 STOP_AFTER=full 阶段 3 出口" || gate S2 FAIL "健康闸（wave）红——阶梯出口不绿"
stage_verdict 3 null "health ok+迁移版本最新+四键 GET 实效对账+健康闸 wave 绿（零防火墙）"
gate S2 PASS "NMS=$nms_ip_from_json 健康（sshd:$SSHD_PORT）、零防火墙、配置就位"
