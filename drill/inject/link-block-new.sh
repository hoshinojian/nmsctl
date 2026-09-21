#!/bin/bash
# inject/link-block-new.sh — 可回收故障②断链自愈（票 0-10；P50 口径：iptables 仅拦 NEW 连，
# 旧会话存活——NMS 侧观察拉取失败→告警开→解封后自愈）。到点自动解封（trap 保回收）。
# 期望自愈信号（首轮校准）：node_unreachable 或 pull_failed/pull_degraded 开+解。
# 用法: inject/link-block-new.sh <node-id> [block-seconds=240]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
NID=${1:?用法: link-block-new.sh <node-id> [block-seconds]}
BLOCK=${2:-240}
mkdir -p "${SILENT_EVIDENCE:-/tmp/silent}"
W_LOG "link-block-new: 目标 $NID 拦新连 ${BLOCK}s（P50：仅 NEW，旧会话存活）"

# 双引号=本地展开（SSHD_PORT 来自 lib/env.sh；单引号会让远端 shell 展开未定义变量→坏规则）
RULE="iptables -w -I INPUT -p tcp --dport $SSHD_PORT -m conntrack --ctstate NEW -j DROP"
UNRULE="iptables -w -D INPUT -p tcp --dport $SSHD_PORT -m conntrack --ctstate NEW -j DROP"
if [ "$DRY_RUN" = "1" ]; then
  W_LOG "DRY: $RULE（跳过）"; sleep 1; W_LOG "DRY: $UNRULE（跳过）"; exit 0
fi
IP=$(node_mgmt_ip "$NID")
unblock() { node_ssh "$IP" "$UNRULE" && W_LOG "解封完成 $NID" || W_LOG "WARN: 解封命令失败 $NID（P58 回收清单核对）"; }
trap unblock EXIT INT TERM
node_ssh "$IP" "$RULE" | tee -a "${SILENT_EVIDENCE:-/tmp/silent}/link-block-$NID.log"
W_LOG "已拦新连 $NID（$IP），${BLOCK}s 后自动解封"
sleep "$BLOCK"
unblock
trap - EXIT INT TERM
