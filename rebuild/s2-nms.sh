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
if [ -n "$reuse_ok" ]; then
  log "续跑：复用已建 droplet $(python3 -c "import json;d=json.load(open('evidence/s2/nms.json'));print(d['name'],d['ip'],d['id'])")"
else
  [ -f "$EVIDENCE/s2/nms.json" ] && log "记录的 droplet 3 次探活全败——清记录重建"
  rm -f "$EVIDENCE/s2/nms.json"
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
# stunnel443 形态：新机 IP 落盘即刷新 ~/.ssh/config 托管块——Round 协议每轮拆旧建新换 IP，
# 仅靠 env.sh source 期刷新会滞后一轮（attempt2/3 实录两次 sshd 等待窗空烧）。
declare -F nms_ssh_cfg_update >/dev/null && nms_ssh_cfg_update
log "等待 sshd($SSHD_PORT) 就绪"
ok=""
for i in $(seq 1 80); do
  if ssh $SSHOPT -p "$SSHD_PORT" "root@$nms_ip_from_json" true 2>/dev/null; then ok=1; break; fi
  sleep 15
done
[ -n "$ok" ] || gate S2 FAIL "sshd 20min 未就绪"
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
log "重启 nms 服务并轮询 /health"
ssh $SSHOPT -p "$SSHD_PORT" "root@$nms_ip_from_json" 'systemctl restart nms'
ok=""
for i in $(seq 1 60); do
  if curl -sS -m 8 "http://$nms_ip_from_json/api/v1/health" 2>/dev/null | grep -q '"status":"ok"'; then ok=1; break; fi
  sleep 5
done
[ -n "$ok" ] || gate S2 FAIL "health 5min 未就绪"
curl -sS "http://$nms_ip_from_json/api/v1/health" | tee "$EVIDENCE/s2/health.json"; echo

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
gate S2 PASS "NMS=$nms_ip_from_json 健康（sshd:$SSHD_PORT）、零防火墙、配置就位"
