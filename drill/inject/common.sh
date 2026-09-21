#!/bin/bash
# inject/common.sh — 静默窗注入单元公共库（票 0-10）。
# 依赖（非 DRY_RUN）：SOAK_ENV 运行时目录 + lib/env.sh（api/nms_ssh）；DRILL_SSH_KEY
#（与注入节点 authorized_keys 的 AUTHORIZED_KEY 配对的 WSL 私钥路径，Step 0 项 1 实测）。
# DRY_RUN=1：零网络——api() 读 $DRILL_FIXTURE/*.json，node_ssh/vpsctl 只落日志。
#
# 约定：单元脚本被 silent-window.sh 以 `inject/<unit>.sh <node-id> [args]` 调用；
# 每单元自带 注入→等待自愈→回收确认 语义与 evidence 落盘（P86：每语句可见输出）。
set -euo pipefail
INJECT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN="${DRY_RUN:-0}"
DRILL_FIXTURE="${DRILL_FIXTURE:-$INJECT_HOME/../tests/fixture}"
W_LOG() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "${SILENT_EVIDENCE:-/tmp/silent}/units.log"; }
# DRY 分支不 source lib/env.sh（零网络），SSHD_PORT 在此给共用缺省（与 env.sh 同值；
# DRY 日志里的规则文本才能如实呈现，注入单元 `set -u` 不因未定义崩——票 1 DRY 冒烟实录）。
SSHD_PORT="${SSHD_PORT:-40222}"

if [ "$DRY_RUN" = "1" ]; then
  api() { # DRY_RUN fixture：GET 读文件，其余只回 {"dry_run":true}
    local method=$1 path=$2
    case "$method" in
      GET) case "$path" in
             /nodes) cat "$DRILL_FIXTURE/nodes.json";;
             /alerts*) cat "$DRILL_FIXTURE/alerts.json";;
             *) echo '{"items":[],"total":0}';;
           esac;;
      *) echo '{"dry_run":true}';;
    esac
  }
  node_ssh() { W_LOG "DRY node_ssh $*（跳过）"; }
  vpsctl_run() { W_LOG "DRY vpsctl $*（跳过）"; }
else
  source "$INJECT_HOME/../../lib/env.sh"
  : "${DRILL_SSH_KEY:?DRY_RUN=0 时须设 DRILL_SSH_KEY（与 AUTHORIZED_KEY 配对的私钥路径）}"
  # node_ssh 经 NMS 跳板（-J，六波前置修复 2026-09-21）：编排机→NMS→节点:$SSHD_PORT。
  # 为什么恒走跳板：编排机直连节点高位 sshd 同样会撞本地代理 TUN 截杀（ISS-001 同形态
  # ——stunnel 只有 NMS user-data 预置，节点没有）；NMS 侧网络干净（witness→target 全程
  # 实证），且编排机→NMS 段由 ~/.ssh/config 托管块自适应（auto/direct/stunnel443）——
  # 两段都不在截杀面上，开不开梯子都通。-J 语法 root@host:port（跳板=NMS 高位口），
  # 目标节点同为高位口（v3.4 全 fleet 统一 SSHD_PORT）。
  # 节点腿认证=NODE_PASS 密码（P81/D3：有密码账号建机走裸机路径，不注入 authorized_keys
  # ——DRILL_SSH_KEY 公钥在节点上不存在，askpass 注入密码；helper 只从 env 读密码不含密文）。
  # 跳板腿用默认身份密钥（NMS user-data 注入 AUTHORIZED_KEY）。
  node_ssh() { # node_ssh <management_ip> <远端命令…>
    local ip=$1; shift
    case "$ip" in (*[!0-9.]*|'') W_LOG "ABORT: 非法节点 IP $ip"; return 1;; esac
    local nip; nip=$(cat "$REBUILD_DIR/evidence/nms-ip.txt" 2>/dev/null || true)
    case "$nip" in (*[!0-9.]*|'') W_LOG "ABORT: nms-ip.txt 缺失或非 IPv4 字面量"; return 1;; esac
    local ap; ap=$(mktemp /tmp/.nmsctl-ap.XXXXXX)
    printf '#!/bin/sh\nprintf "%%s\\n" "$NODE_PASS"\n' > "$ap"; chmod 700 "$ap"
    SSH_ASKPASS="$ap" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
    ssh -o BatchMode=no -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        -o NumberOfPasswordPrompts=1 -p "$SSHD_PORT" \
        -J "root@$nip:$SSHD_PORT" -i "$DRILL_SSH_KEY" "root@$ip" "$@"
    local rc=$?
    rm -f "$ap"
    return $rc
  }
  vpsctl_run() { "$VPSCTL" "$@"; }
fi

node_mgmt_ip() { # node_mgmt_ip <node-id> → management_ip（从 /nodes 台账取）
  local nid=$1
  api GET /nodes | python3 -c "
import json, sys
items = json.load(sys.stdin)['items']
m = [n.get('management_ip') for n in items if n['id'] == sys.argv[1]]
assert m and m[0], 'node not found or no management_ip: ' + sys.argv[1]
print(m[0])" "$nid"
}
