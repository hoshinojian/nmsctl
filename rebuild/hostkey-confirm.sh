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

PUBS=$(node_ssh "$IP" 'cat /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_rsa_key.pub /etc/ssh/ssh_host_ecdsa_key.pub 2>/dev/null')
FPS=$(printf '%s\n' "$PUBS" | while read -r line; do
  case "$line" in ssh-*) printf '%s\n' "$line" | ssh-keygen -lf - | awk '{print $2}';; esac
done | sort -u)
[ -n "$FPS" ] || { echo "ABORT: 节点 host key 读取异常" >&2; exit 1; }

# 观测指纹（confirm 的法定分母——握手协商的那把，算法族不定）只读取自 DB；
# 可信渠道核对=观测值必须 ∈ 节点真实指纹集合，否则真异常拒确认。
OBSERVED=$(nms_ssh "docker exec nms-timescaledb psql -U nms -d nms -tAc \
  \"SELECT last_seen_host_key FROM nodes WHERE id='$NID'\"" | tr -d '[:space:]')
if [ -z "$OBSERVED" ]; then
  # 无观测=无待确认变化（从未拨号的新名，或 mismatch 已清）：409 语境，幂等跳过——
  # 复用名节点的 TOFU 要等 NMS 拨过才有观测值（s5 拨→last_seen 落→再 confirm）
  log "$NID 无待确认观测指纹（last_seen 空）——跳过（新名或已确认）"
  exit 0
fi
case "${OBSERVED^^}" in SHA256:*) :;;
  *) gate HKC FAIL "$NID 观测指纹字段异常：$OBSERVED";;
esac
# 前缀大小写归一（DB=sha256:/ssh-keygen=SHA256:——第四次迭代实录：精确比对被大小写骗两次）
if ! printf '%s\n' "$FPS" | awk -v obs="${OBSERVED^^}" 'toupper($0)==obs{f=1} END{exit !f}'; then
  gate HKC FAIL "$NID 观测指纹 $OBSERVED 不在节点真实集合（$(echo $FPS | tr '\n' ' ')）——疑似中间人/串机，人工核查"
fi
FP=$OBSERVED

log "确认 $NID 指纹 $FP（观测值∈节点真实集合，核对通过）"
# URL 的 $NMS_API_ADDR 在编排机侧展开（远端无此变量——首版误写 \$ 致空 host，PUT 打空）
code=$(nms_ssh "curl -sS -m 30 -o /tmp/hkc.json -w '%{http_code}' -X PUT -H 'Content-Type: application/json' \
  --data '{\"fingerprint\":\"$FP\"}' http://$NMS_API_ADDR:80/api/v1/nodes/$NID/host-key/confirm")
echo "confirm HTTP $code: $(nms_ssh 'cat /tmp/hkc.json 2>/dev/null; rm -f /tmp/hkc.json')"
case "$code" in
  200) log "$NID host key 确认成功（覆写+解除拒绝）";;
  409) log "$NID 无活跃 mismatch（409）——幂等跳过";;
  *)   gate HKC FAIL "$NID confirm HTTP $code（400=指纹与 NMS 观测不符，查节点/中转）";;
esac
