#!/bin/bash
# nms-ssh.sh — health-gate.py 的 ssh 包装（票 0-9）。
# 目标 IP 由本脚本读 s2 落盘的 nms-ip.txt 并做字面量校验；证据根取 DRILL_EVIDENCE_ROOT
# （缺省 ~/nms-r-drill-20260920）。python 侧因此不构造任何动态命令串（安全扫描口径：
# 参数列表全字面量）。远端 token 经 "$@" 透传，ssh 在远端以空格拼接分词（token 约定：
# 无空格/无引号，见 health-gate.py 的 LEVEL_PARAMS/常量表）。
# 用法: bash drill/nms-ssh.sh <remote-token…>（stdin 透传给远端命令）
set -euo pipefail
root=${DRILL_EVIDENCE_ROOT:-$HOME/nms-r-drill-20260920}
ip=$(tr -d '[:space:]' < "$root/evidence/nms-ip.txt")
case "$ip" in
  (*[!0-9.]*|'') echo "ABORT: nms-ip.txt 非 IPv4 字面量: $ip" >&2; exit 1;;
esac
exec ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@$ip" "$@"
