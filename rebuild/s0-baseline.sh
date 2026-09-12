#!/bin/bash
# S0 基线采集（只读）：现网端点快照 + SSH 通道探测 + syd1-02 状态
# T3 必改(a)配套：本脚本新增 DO 侧 env:soak 盘点并落盘 fleet-count.txt——
# 这是 S1 拆除数（EXPECT_TEARDOWN_COUNT）的唯一权威来源（首跑=29、重建后重跑=65 都成立）；
# fleet==0 时判定「无现网 fleet」并 SKIP（exit 0），供 S1 的良性跳过判定。
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/rebuild
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）
cd "$REBUILD_DIR"
mkdir -p "$EVIDENCE/baseline"
exec > >(tee "$EVIDENCE/baseline/log.txt") 2>&1

check_egress
B="$EVIDENCE/baseline"

# ---- DO 侧现网盘点（只读）：tag=env:soak 台数 → fleet-count.txt（run-benchmark 读后导出给 S1）----
log "盘点现网 env:soak fleet（DO 侧，-no-check-ssh 只读）"
"$VPSCTL" list -tag env:soak -no-check-ssh -output "$B/do-inventory.json" > /dev/null
FLEET_N=$(python3 -c "
import json; d=json.load(open('$B/do-inventory.json'))
items = d if isinstance(d, list) else d.get('items', d.get('droplets', []))
print(len(items))")
echo "$FLEET_N" > "$B/fleet-count.txt"
log "现网 env:soak 共 $FLEET_N 台（含 NMS）→ 已写入 fleet-count.txt"

if [ "$FLEET_N" = "0" ]; then
  log "现网无 env:soak fleet（上轮已拆或首跑前）——S0 判定无可基线，SKIP"
  gate S0 PASS "无现网 fleet（0 台），S0 SKIP；S1 将据此良性跳过"
fi

# 基线目标机：优先用盘点里的 soaknms 前缀机（重建重跑时 env.sh 的 OLD_NMS_IP 已过时）
NMS_TARGET="$OLD_NMS_IP"
CUR_NMS_IP=$(python3 -c "
import json; d=json.load(open('$B/do-inventory.json'))
items = d if isinstance(d, list) else d.get('items', d.get('droplets', []))
c = sorted(i.get('ipv4_public','') for i in items if i.get('name','').startswith('$NMS_NAME_PREFIX'))
print(c[0] if len(c) == 1 else '')")
if [ -n "$CUR_NMS_IP" ] && [ "$CUR_NMS_IP" != "$OLD_NMS_IP" ]; then
  log "现网 NMS 机实测 IP=$CUR_NMS_IP（env.sh OLD_NMS_IP=$OLD_NMS_IP 已过时——重建重跑场景，基线打现网机）"
  NMS_TARGET="$CUR_NMS_IP"
fi

log "抓取现网端点 + 配置（整块最多 5 轮——本地出口有阵发坏窗口，2026-09-11 实测）"
for try in 1 2 3 4 5; do
  ok=1
  for ep in "nodes|api/v1/nodes" "topology|api/v1/topology" "alerts-active|api/v1/alerts?status=active&limit=200" "agent-deploy|api/v1/agent-deploy" "config|api/v1/config"; do
    name="${ep%%|*}"; path="${ep#*|}"
    ssh $SSHOPT -p 22 "root@$NMS_TARGET" "curl -sS -m 15 http://127.0.0.1:80/$path" > "$B/$name.json" || ok=0
  done
  [ "$ok" = "1" ] && [ -s "$B/nodes.json" ] && { log "第 $try 轮抓取成功"; break; }
  [ "$try" = "5" ] && { echo "ABORT: 5 轮抓取均失败"; exit 1; }
  log "第 $try 轮失败（坏窗口），20s 后重试"
  sleep 20
done

log "探测本地→NMS 的 SSH 通道（22 疑似协议级阻断；2222 应通）"
for p in 22 2222; do
  if ssh $SSHOPT -p $p -o ConnectTimeout=6 "root@$NMS_TARGET" true 2>"$B/ssh-$p.err"; then
    echo "ssh:$p OK" | tee -a "$B/ssh-probe.txt"
  else
    echo "ssh:$p FAIL" | tee -a "$B/ssh-probe.txt"
  fi
done

python3 - <<'EOF'
import json, collections
d = json.load(open('evidence/baseline/nodes.json'))
items = d['items'] if isinstance(d, dict) else d
summary = {
  "total": len(items),
  "by_role_status": {f"{r}|{s}": c for (r, s), c in collections.Counter((n['role'], n['status']) for n in items).items()},
  "not_ok": [n['id'] for n in items if n['status'] != 'online' or n['collection_state'] != 'collection_ok'],
  "domain0": sorted(n['id'] for n in items if n['domain'] == 0),
}
alerts = json.load(open('evidence/baseline/alerts-active.json'))
summary['active_alerts'] = alerts.get('total', len(alerts.get('items', [])))
json.dump(summary, open('evidence/baseline/summary.json', 'w'), ensure_ascii=False, indent=1)
print(json.dumps(summary, ensure_ascii=False, indent=1))
EOF

gate S0 PASS "基线落盘 $B（fleet=$FLEET_N 台）"
