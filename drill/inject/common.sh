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
  # node_ssh 经 NMS 跳板（-J，六波前置修复 2026-09-21）：编排机→NMS→节点:22。
  # 为什么恒走跳板：编排机直连节点 22 会撞本地代理 TUN 截杀（ISS-001 同形态——stunnel
  # 只有 NMS user-data 预置，节点没有）；NMS 侧网络干净（witness→target 全程实证），
  # 且编排机→NMS 段由 ~/.ssh/config 托管块自适应（auto/direct/stunnel443）——两段都不在
  # 截杀面上，开不开梯子都通。跳板腿用默认身份（与节点同一把 DRILL_SSH_KEY 对应公钥，
  # NMS user-data 同样注入 AUTHORIZED_KEY）。两段 IP 均过 IPv4 字面量门。
  node_ssh() { # node_ssh <management_ip> <远端命令…>
    local ip=$1; shift
    case "$ip" in (*[!0-9.]*|'') W_LOG "ABORT: 非法节点 IP $ip"; return 1;; esac
    local nip; nip=$(cat "$REBUILD_DIR/evidence/nms-ip.txt" 2>/dev/null || true)
    case "$nip" in (*[!0-9.]*|'') W_LOG "ABORT: nms-ip.txt 缺失或非 IPv4 字面量"; return 1;; esac
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        -J "root@$nip" -i "$DRILL_SSH_KEY" "root@$ip" "$@"
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
