#!/bin/bash
# hostkey-confirm.sh — 同名重建节点的 TOFU 指纹确认（ISS-016；契约 04 §2.14 / 决策 #64）。
# 场景：s1.5 拆除→s3 同名重建→新机新 host key，NMS 首连记录（旧指纹）不符 → 按设计拒连。
# 本工具=演练语境的「管理员确认」自动化：经 NMS 跳板用编排机密钥直接读节点真实指纹
#（可信渠道：机器是我们建的、authorized_keys 是我们注入的）→ PUT /nodes/{id}/host-key/confirm。
# 400=NMS 观测指纹与提交不符（防抄错，先查节点）；409=无活跃 mismatch（容忍，幂等）。
# 用法：hostkey-confirm.sh <node-id> <management_ip>（批量由调用方循环）
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SOAK_SELF_DIR/../drill/inject/common.sh"   # node_ssh（-J NMS 跳板+askpass 密码腿）
NID="${1:?用法: hostkey-confirm.sh <node-id> <management_ip>}"
IP="${2:?缺 management_ip}"

PUB=$(node_ssh "$IP" 'cat /etc/ssh/ssh_host_ed25519_key.pub')
case "$PUB" in ssh-ed25519*' '*' '*) :;; *) echo "ABORT: 节点公钥读取异常" >&2; exit 1;; esac
FP=$(printf '%s\n' "$PUB" | ssh-keygen -lf - | awk '{print $2}')
case "$FP" in SHA256:*) :;; *) echo "ABORT: 指纹格式异常: $FP" >&2; exit 1;; esac

log "确认 $NID 指纹 $FP（经跳板实测，可信渠道）"
code=$(nms_ssh "curl -sS -m 30 -o /tmp/hkc.json -w '%{http_code}' -X PUT -H 'Content-Type: application/json' \
  --data '{\"fingerprint\":\"$FP\"}' http://\$NMS_API_ADDR:80/api/v1/nodes/$NID/host-key/confirm")
nms_ssh 'cat /tmp/hkc.json 2>/dev/null; rm -f /tmp/hkc.json'; echo
case "$code" in
  200) log "$NID host key 确认成功（覆写+解除拒绝）";;
  409) log "$NID 无活跃 mismatch（409）——幂等跳过";;
  *)   gate HKC FAIL "$NID confirm HTTP $code（400=指纹与 NMS 观测不符，查节点/中转）";;
esac
