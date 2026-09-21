#!/bin/bash
# port22-gate.sh — 22 端口字面量回归门（v3.4 票 1 验收件，P89 精神：防高位口迁移后 22 回流）。
# 口径：fleet 的一切 SSH 接触点必须走 $SSHD_PORT；允许的 22 仅限白名单语义——
#   1) net-probe raw22 探测（探测「公网裸 TCP 是否被 TUN 截」这一环境事实，与 fleet 端口无关）
#   2) s0 探测清单的 22 对照腿（历史口对照，注释注明）
#   3) 纯注释/文档行
# 用法：bash tools/port22-gate.sh（仓根执行；违例 exit 1，P86 每条可见）
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
rc=0
while IFS=: read -r file lineno text; do
  case "$file" in tools/port22-gate.sh) continue;; esac          # 本文件自身豁免
  printf '✗ %s:%s: %s\n' "$file" "$lineno" "$text"
  rc=1
done < <(grep -rn --exclude-dir=.git --exclude-dir=__pycache__ \
             -e '-p 22[^0-9]' -e '-P 22[^0-9]' -e '--dport 22[^0-9]' -e ':22/' \
             lib rebuild churn drill observe tools env.local.example 2>/dev/null \
        | grep -v '^\s*#' \
        | grep -v 'lib/net-probe.sh:.*raw22' \
        | grep -v 'socket.create_connection((ip, 22)')
if [ "$rc" = "0" ]; then echo "port22-gate: 零违例（SSHD_PORT 单源口径成立）"; fi
exit $rc
