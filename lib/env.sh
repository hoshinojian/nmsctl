# soak fleet driver 公共环境（NMS2/scripts/soak/lib/env.sh——唯一权威版本）
# 口径见 NMS2/docs/engineering/{soak-rebuild-churn,scale-coldstart-churn,coldstart-selfheal-plan}.md
#
# 运行时关系（coldstart-selfheal-plan §四）：本文件入库零凭据；机密与部署事实
# （节点密码/出口白名单/防火墙 ID/NMS 账号/区域账号分布表）全部经运行时目录的
# env.local 注入。使用方式：export SOAK_ENV=<运行时目录> 后再跑任何 driver 脚本；
# 运行时目录只存 env.local 与 evidence/（含运行时实例化的 user-data），清单见
# scripts/soak/README.md 与 env.local.example。

: "${SOAK_ENV:?未设置 SOAK_ENV=<运行时目录>（内含 env.local 与 evidence/；用法见 scripts/soak/README.md）}"
SOAK_ENV="$(cd "$SOAK_ENV" && pwd)"

# driver 脚本仓内根（lib/ 的上级）；场景/阶段脚本彼此经 SOAK_HOME 定位
SOAK_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SOAK_HOME
# D8 fail-fast 双保险（在 env.local 检查之前）：SOAK_ENV 不得指向仓内——env.local
#（凭据）与 evidence/ 落仓内即有入库风险（.gitignore 只是兜底；真机密一律只在运行时目录）。
case "$SOAK_ENV" in
  "$SOAK_HOME"|"$SOAK_HOME"/*)
    echo "ABORT(D8): SOAK_ENV=$SOAK_ENV 在仓内（$SOAK_HOME）——env.local/evidence 会污染仓库，换独立运行时目录" >&2
    exit 1;;
esac

[ -f "$SOAK_ENV/env.local" ] || { echo "ABORT: $SOAK_ENV/env.local 不存在——从 scripts/soak/env.local.example 复制并填写" >&2; exit 1; }
# shellcheck source=/dev/null
source "$SOAK_ENV/env.local"

# 运行时目录承担旧 $HOME/nms-rebuild-20260910 的角色：各阶段 cd 进去后，
# 嵌入 python 里的相对路径 evidence/... 与 $EVIDENCE 同一目录，语义不变。
export REBUILD_DIR="$SOAK_ENV"
export EVIDENCE="$SOAK_ENV/evidence"

# ---- 机密/部署事实（必填，env.local 注入；无任何入库常量，coldstart §四）----
: "${NODE_PASS:?env.local 缺 NODE_PASS（节点统一密码）}"
: "${EGRES_EXPECT:?env.local 缺 EGRES_EXPECT（fw-soak-nms 白名单出口，P68/P71）}"
: "${OLD_NMS_IP:?env.local 缺 OLD_NMS_IP（现网 NMS；重建后由 S0 经 DO 盘点自动纠正）}"
: "${FW_SOAK_NMS_ID:?env.local 缺 FW_SOAK_NMS_ID（DO 防火墙 ID）}"
: "${NMS_ACCOUNT:?env.local 缺 NMS_ACCOUNT（NMS 固定账号；禁止在 driver 写账号名常量）}"
export NODE_PASS EGRES_EXPECT OLD_NMS_IP FW_SOAK_NMS_ID NMS_ACCOUNT AUTHORIZED_KEY

# ---- 非机密缺省（可被 env.local 覆盖）----
export NMS2_REPO="${NMS2_REPO:-$HOME/NMS2}"
export VPSCTL="${VPSCTL:-$HOME/vpsctl/bin/vpsctl}"
export VPSCTL_ACCOUNTS="${VPSCTL_ACCOUNTS:-$HOME/.config/vpsctl/accounts.json}"
export NMS_NAME_PREFIX="${NMS_NAME_PREFIX:-soaknms}"   # s4 剔除 NMS 机的识别前缀
export NMS_REGION="${NMS_REGION:-sgp1}"                # S2 NMS 固定建区（s3 总盘点按区域核数时含这 1 台）
export EXPECT_HEAD="${EXPECT_HEAD:-2c31e89}"           # 被测 main；run-benchmark 以当轮 main 终点覆盖
# T3 65 台参数化单一来源（scale-coldstart-churn-plan §一 T3，2026-09-11）：
# 节点 64 + NMS 1 = 65；分布表本体（区域/账号/机型，账号列注入）在 env.local 的
# SOAK_BATCHES（s3 消费），此处只放全局标量。改分布时：先改 SOAK_BATCHES，
# 再同步这三个标量，s3 会对账（合计 != NODE_COUNT 直接 ABORT）。
export NODE_COUNT="${NODE_COUNT:-64}"           # 测试节点数（不含 NMS）
export FIRST_HOP_COUNT="${FIRST_HOP_COUNT:-9}"  # 第一跳（domain0）台数，sgp1 批次前 9 台
export CHILD_BUDGET="${CHILD_BUDGET:-3}"        # 与 S2 PUT config 的 child_budget 同值（g5 不变量用）

export NMS_IP_FILE="$EVIDENCE/nms-ip.txt"
# 新 NMS IP（s2 之后才有）；读不到则报错
nms_ip() {
  [ -f "$NMS_IP_FILE" ] || { echo "ERROR: $NMS_IP_FILE 不存在（s2 未跑？）" >&2; return 1; }
  cat "$NMS_IP_FILE"
}
# NMS API 基址在 api() 内动态取（nms-ip.txt 由 s2 写出）

# 管理通道（R+L 演练 Step0 实录 2026-09-20 双形态）：缺省直连 22（2026-08 阻断已消失，
# fw-soak-nms 放行 22；2222 因 Ubuntu 24.04 sshd socket 激活不生效，弃用）。
# NMS_SSH_VIA=stunnel443：编排机本地代理 TUN 截直连 22 裸流（TCP 建连后 kex 前被断，
# github:22 同症 fake-IP 198.18.x），443 裸 IP 放行——走 user-data6 预置的 stunnel
# ssh-over-443。实现=维护 ~/.ssh/config 托管 Match 块（按 nms-ip.txt 幂等更新，见下），
# 全部裸 ssh/scp $SSHOPT 调用点零改动自动生效；fw-soak-nms 须放行 443。
export NMS_SSH_VIA="${NMS_SSH_VIA:-direct}"
export SSHOPT="-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=5"
if [ "$NMS_SSH_VIA" = "stunnel443" ]; then
  nms_ssh_cfg_update() {  # 幂等维护 ~/.ssh/config 的 nmsctl 托管块（s2 前 nms-ip.txt 缺失则跳过）
    local ip cfg="$HOME/.ssh/config" begin="# BEGIN nmsctl-managed (stunnel443)" end="# END nmsctl-managed"
    [ -f "$NMS_IP_FILE" ] || return 0
    ip=$(cat "$NMS_IP_FILE") || return 0
    case "$ip" in (*[!0-9.]*|'') return 0;; esac
    local block="$begin
Match host $ip
  ProxyCommand openssl s_client -quiet -verify_quiet -connect %h:443 2>/dev/null
$end"
    mkdir -p "$HOME/.ssh" && touch "$cfg"
    if grep -qF "$begin" "$cfg"; then
      python3 - "$cfg" "$block" "$begin" "$end" <<'PYEOF'
import sys
cfg, block, begin, end = sys.argv[1:5]
lines = open(cfg).read().splitlines()
try:
    i, j = lines.index(begin), lines.index(end)
    lines[i:j + 1] = block.splitlines()
except ValueError:
    lines += [""] + block.splitlines()
open(cfg, "w").write("\n".join(lines) + "\n")
PYEOF
    else
      printf '\n%s\n' "$block" >> "$cfg"
    fi
    chmod 600 "$cfg"
  }
  nms_ssh_cfg_update
fi
nms_ssh() { ssh $SSHOPT -p 22 "root@$(nms_ip)" "$@"; }
nms_scp() { scp $SSHOPT -P 22 "$@"; }

# NMS API 调用：统一走 ssh 打 NMS 本机 loopback（2026-09-11：本地→NMS:80 直连
# 间歇被本地出口吞包，ssh 通道全程零故障——绕开之）。body 经 stdin 传递避免引号地狱。
api() {
  local method=$1 path=$2 body=${3:-}
  local ip; ip=$(nms_ip)
  if [ -n "$body" ]; then
    printf '%s' "$body" | ssh $SSHOPT -p 22 "root@$ip" \
      "curl -sS -m 60 -X $method -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:80/api/v1$path"
  else
    ssh $SSHOPT -p 22 "root@$ip" "curl -sS -m 60 http://127.0.0.1:80/api/v1$path"
  fi
}

# P68 代理护栏：出口 IP 必须等于白名单值，否则中止一切（多回显服务降级，单一站点被掐不误报）
check_egress() {
  local ip got svc
  for svc in icanhazip.com api.ipify.org ifconfig.me; do
    got=$(curl -sS -m 10 "https://$svc" 2>/dev/null | tr -d '[:space:]') || { log "egress: $svc 不可达，换下一个"; continue; }
    ip="$got"
    break
  done
  if [ -z "${ip:-}" ]; then echo "ABORT(P68): 所有出口回显服务均不可达，网络状态不明" >&2; exit 42; fi
  if [ "$ip" != "$EGRES_EXPECT" ]; then
    echo "ABORT(P68): 出口 IP $ip != 白名单 $EGRES_EXPECT——代理模式不对或 IP 已变，先改防火墙再跑" >&2
    exit 42
  fi
}

log()  { echo "[$(date -u +%FT%TZ)] $*"; }
gate() { # gate <Sx> PASS|FAIL <说明>
  log "GATE $1: $2 — $3"
  [ "$2" = "PASS" ] || exit 1
}

# ---- D3 共用实例化链路（自 s2 内联片段抽取；s2/s3 共用）----
# instantiate_user_data <模板路径> <输出路径>：__NODE_PASS__/__AUTHORIZED_KEY__ 注入。
# 仓内模板零凭据；实例化件落运行时目录（0600）不入库。密码同源：模板密码与 s4 载荷
# ssh_password 同用 env NODE_PASS。
instantiate_user_data() {
  python3 - "$1" "$2" <<'PYEOF'
import os, sys
tpl_path, out_path = sys.argv[1], sys.argv[2]
tpl = open(tpl_path).read()
assert '__NODE_PASS__' in tpl, "user-data 模板缺 __NODE_PASS__ 占位"
assert '__AUTHORIZED_KEY__' in tpl, "user-data 模板缺 __AUTHORIZED_KEY__ 占位"
pw = os.environ['NODE_PASS']
assert '__NODE_PASS__' not in pw
ak = os.environ.get('AUTHORIZED_KEY', '').strip()
assert ak and '__AUTHORIZED_KEY__' not in ak, 'AUTHORIZED_KEY 未设置（节点 root authorized_keys 注入用）'
open(out_path, 'w').write(tpl.replace('__NODE_PASS__', pw).replace('__AUTHORIZED_KEY__', ak))
os.chmod(out_path, 0o600)
PYEOF
}

# account_has_password <账号名>：读 VPSCTL_ACCOUNTS 判该账号是否配了 ssh_password
#（1=有/0=无）。D3 分叉判据：无密码账号批次建机须传实例化 user-data，否则裸机（P81）。
account_has_password() {
  VPSCTL_ACCOUNTS="$VPSCTL_ACCOUNTS" ACCT="$1" python3 - <<'PYEOF'
import json, os
cfg = json.load(open(os.environ['VPSCTL_ACCOUNTS']))
accts = cfg['accounts'] if isinstance(cfg, dict) else cfg
a = next((x for x in accts if x.get('name') == os.environ['ACCT']), None)
print('1' if a and a.get('ssh_password') else '0')
PYEOF
}
