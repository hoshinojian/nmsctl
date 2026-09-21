#!/bin/bash
# S1.5 fleet-only 拆除+DB 台账清理（v3.4 票 4 / P0 地基保留支撑）：
#   DO 侧：只拆测试节点（剔 $NMS_NAME_PREFIX 前缀机，vpsctl -ids 精确路径），保留已绿 NMS 地基；
#   DB 侧：陈旧节点行叶子优先逐台 DELETE——stale 行来源：NMS+DB 保留而 fleet 拆重建（新
#   droplet=新 id，upsert 覆盖不到旧行），污染 s5 NC/NC 收敛分母与阶段 4 出口计数
#  （v3.4.1 审核定案）。删除循环天然叶子优先（子先删，父 409 随之解除）；不用 force
#   （破坏性安全：provisioning 滞留两轮无进展即 FAIL 留人工，不自动强删）。
# 出口断言：DO 侧节点残留=0 ∧ NMS 仍 active ∧ GET /nodes=0；落 evidence/s1/post-inventory.json
#   （s2 前置强等该文件——s1.5 语境下由本脚本承接 s1 的落盘责任）。
# DRY_RUN=1：只盘点+打印将执行动作，零删除零 API 写。
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SOAK_SELF_DIR/../lib/env.sh"
cd "$REBUILD_DIR"
mkdir -p "$EVIDENCE/s1.5"
exec > >(tee "$EVIDENCE/s1.5/log.txt") 2>&1

check_egress
DRY_RUN="${DRY_RUN:-0}"

log "盘点 env:soak（只读）"
"$VPSCTL" list -tag env:soak -no-check-ssh -output "$EVIDENCE/s1.5/pre-inventory.json" > /dev/null
python3 - <<'EOF'
import json, os
d = json.load(open('evidence/s1.5/pre-inventory.json'))
items = d if isinstance(d, list) else d.get('items', d.get('droplets', []))
prefix = os.environ['NMS_NAME_PREFIX']
nms = [i for i in items if str(i.get('name', '')).startswith(prefix)]
nodes = [i for i in items if not str(i.get('name', '')).startswith(prefix)]
with open('evidence/s1.5/delete-ids.txt', 'w') as f:
    for i in nodes:
        f.write(f"{i['account']}/{i['id']} {i['name']}\n")
json.dump([{k: i.get(k) for k in ('id', 'name', 'ipv4_public', 'status')} for i in nms],
          open('evidence/s1.5/nms-kept.json', 'w'), indent=1)
print(f"INVENTORY nms={len(nms)} nodes={len(nodes)}")
EOF
N_NODES=$(wc -l < "$EVIDENCE/s1.5/delete-ids.txt" | tr -d ' ')
NMS_N=$(python3 -c "import json;print(len(json.load(open('evidence/s1.5/nms-kept.json'))))")
log "盘点：NMS=$NMS_N 台（保留） 节点=$N_NODES 台（拆除）"

if [ "$N_NODES" -gt 0 ]; then
  IDS=$(awk '{print $1}' "$EVIDENCE/s1.5/delete-ids.txt" | paste -sd, -)
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY：将执行 vpsctl delete -ids（$N_NODES 台）——$IDS"
  else
    log "DO 侧拆除节点（-ids 精确路径，宁可漏删不可误删）"
    "$VPSCTL" delete -ids "$IDS" -confirm "$N_NODES" -output "$EVIDENCE/s1.5/delete.json" > /dev/null
  fi
else
  log "无节点在网（阶段 1–3 语境或已拆净）——DO 侧跳过"
fi

log "拆除后盘点（s1.5 语境承接 s1 的 post-inventory 落盘责任——s2 前置强等该文件）"
if [ "$DRY_RUN" = "1" ]; then
  cp "$EVIDENCE/s1.5/pre-inventory.json" "$EVIDENCE/s1.5/post-inventory.json"
else
  "$VPSCTL" list -tag env:soak -no-check-ssh -output "$EVIDENCE/s1.5/post-inventory.json" > /dev/null
fi
mkdir -p "$EVIDENCE/s1"
if [ "$DRY_RUN" != "1" ]; then
  cp "$EVIDENCE/s1.5/post-inventory.json" "$EVIDENCE/s1/post-inventory.json"
fi

python3 - "$EVIDENCE/s1.5/post-inventory.json" <<'EOF'
import json, os, sys
d = json.load(open(sys.argv[1]))
items = d if isinstance(d, list) else d.get('items', d.get('droplets', []))
prefix = os.environ['NMS_NAME_PREFIX']
residue = [i['name'] for i in items if not str(i.get('name', '')).startswith(prefix)]
nms = [i for i in items if str(i.get('name', '')).startswith(prefix)]
assert not residue, f"节点残留 {len(residue)} 台: {residue[:8]}（拆除不净）"
if nms:
    assert len(nms) == 1 and nms[0].get('status') == 'active', f"NMS 状态异常: {nms}"
print(f"POST nms={len(nms)}(active) nodes=0")
EOF

# ---- DB 台账清理（叶子优先=循环逐删；provisioning/带子 409 随子删/终态自然解除）----
if [ "$NMS_N" -eq 0 ]; then
  log "NMS 不在网（等价 s1 全拆语境）——DB 清账无载体，跳过"
elif [ "$DRY_RUN" = "1" ]; then
  log "DRY：将执行 DB 陈旧行逐台 DELETE 循环（跳过）"
else
  log "DB 台账清理：循环 GET /nodes → 逐台 DELETE → 至空（HTTP 码留痕；两轮无进展 FAIL 留人工）"
  stall=0; prev=-1
  for round in $(seq 1 10); do
    N_NOW=$(api GET /nodes | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('items',[])))")
    if [ "$N_NOW" = "0" ]; then log "第 $round 轮：/nodes 已空"; break; fi
    log "第 $round 轮：残留 $N_NOW 行，逐台 DELETE"
    api GET /nodes | python3 -c "import json,sys;[print(i['id']) for i in json.load(sys.stdin)['items']]" \
      | while read -r NID; do
          code=$(nms_ssh "curl -sS -m 30 -o /dev/null -w '%{http_code}' -X DELETE http://$NMS_API_ADDR:80/api/v1/nodes/$NID")
          log "  DELETE $NID → HTTP $code"
        done
    if [ "$N_NOW" = "$prev" ]; then stall=$((stall+1)); else stall=0; fi
    prev="$N_NOW"
    if [ "$stall" -ge 2 ]; then
      api GET /nodes > "$EVIDENCE/s1.5/db-stuck.json" || true
      gate S1.5 FAIL "DB 清账两轮无进展（provisioning 滞留/带子守卫）——残留清单 db-stuck.json，人工定性后再跑"
    fi
  done
  FINAL_N=$(api GET /nodes | python3 -c "import json,sys;print(len(json.load(sys.stdin).get('items',[])))")
  [ "$FINAL_N" = "0" ] || gate S1.5 FAIL "DB 残留 $FINAL_N 行（10 轮未尽）"
fi

gate S1.5 PASS "fleet-only 拆除+DB 清账完成（NMS 地基保留、/nodes=0、post-inventory 已落）"
