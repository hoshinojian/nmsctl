#!/bin/bash
# S6 建联与上下行验证（用户裁决口径）：上行=采集+metrics；下行=dispatch 指令回读；+ pg_dump 基线备份
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/rebuild
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）
cd "$REBUILD_DIR"
mkdir -p "$EVIDENCE/s6"
exec > >(tee "$EVIDENCE/s6/log.txt") 2>&1

check_egress
log "选取验证目标：min(5,NODE_COUNT) 台=第一跳优先+深路径补余（S6'；ISS-015 档位语境参数化，深路径优先深度 3）"
api GET /topology > "$EVIDENCE/s6/topology.json"
TARGETS=$(python3 - <<'EOF'
import json, os
nc, fh_n = int(os.environ['NODE_COUNT']), int(os.environ['FIRST_HOP_COUNT'])
t = json.load(open('evidence/s6/topology.json'))
want_fh = min(2, fh_n)                      # 第一跳样本上限（小档位按 FH 收缩）
want_deep = min(3, max(nc - want_fh, 0))    # 深路径补余（总量 ≤ min(5, nc)）
fh = sorted(n['id'] for n in t['nodes'] if n['domain'] == 0)[:want_fh]
deep_pool = sorted(n['id'] for n in t['tree']['nodes'] if n['depth'] == 3) \
    or sorted(n['id'] for n in t['tree']['nodes'] if n['depth'] >= 3)      # 深度3不足时退而取≥3
deep = [i for i in deep_pool if i not in fh][:want_deep]
targets = fh + deep
cap = min(5, nc)
assert len(targets) == min(cap, len(t['nodes'])), f"抽测目标不足 {cap} 台: {targets}"
assert len(t['nodes']) == nc, f"nodes {len(t['nodes'])} != {nc}"
print('\n'.join(targets))
EOF
)
echo "$TARGETS" | tee "$EVIDENCE/s6/targets.txt"
log "目标：$(echo "$TARGETS" | tr '\n' ' ')"

FROM=$(python3 -c "import datetime;print((datetime.datetime.utcnow()-datetime.timedelta(minutes=15)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
for id in $TARGETS; do
  log "上行 $id：metrics(cpu) 有数据点"
  api GET "/nodes/$id/metrics?metric=cpu&from=$FROM" > "$EVIDENCE/s6/metrics-$id.json"
  python3 - "$id" <<'EOF'
import json, sys
d = json.load(open(f"evidence/s6/metrics-{sys.argv[1]}.json"))
pts = d.get('items') or d.get('points') or []
assert pts, f"metrics 空: {d}"
print(f"  {sys.argv[1]}: {len(pts)} 点")
EOF
  log "下行 $id：dispatch echo 回读"
  api POST "/nodes/$id/dispatch" '{"command":"echo dispatch-ok"}' > "$EVIDENCE/s6/dispatch-$id.json"
  python3 - "$id" <<'EOF'
import json, sys
d = json.load(open(f"evidence/s6/dispatch-{sys.argv[1]}.json"))
assert d.get('status') == 'succeeded' and d.get('exit_code') == 0, d
assert 'dispatch-ok' in (d.get('stdout') or ''), d
print(f"  {sys.argv[1]}: dispatch succeeded, stdout={d['stdout'].strip()!r}")
EOF
done

log "全局复核：$NODE_COUNT/$NODE_COUNT collection_ok"
api GET /nodes > "$EVIDENCE/s6/nodes-final.json"
python3 -c "
import json, os
items = json.load(open('evidence/s6/nodes-final.json'))['items']
nc = int(os.environ['NODE_COUNT'])
bad = [n['id'] for n in items if n['collection_state'] != 'collection_ok']
assert len(items) == nc and not bad, (len(items), bad)
print(f'{nc}/{nc} collection_ok')"

log "pg_dump 全量基线备份 + pg_restore --list 可恢复验证"
ssh $SSHOPT -p "$SSHD_PORT" "root@$(nms_ip)" 'docker exec nms-timescaledb pg_dump -U nms -Fc nms' > "$EVIDENCE/s6/nms-fresh-baseline.dump"
SIZE=$(stat -c%s "$EVIDENCE/s6/nms-fresh-baseline.dump")
[ "$SIZE" -gt 10240 ] || gate S6 FAIL "dump 仅 $SIZE 字节"
ssh $SSHOPT -p "$SSHD_PORT" "root@$(nms_ip)" 'docker exec -i nms-timescaledb pg_restore --list' < "$EVIDENCE/s6/nms-fresh-baseline.dump" > "$EVIDENCE/s6/dump-toc.txt"
TOC_N=$(wc -l < "$EVIDENCE/s6/dump-toc.txt")
[ "$TOC_N" -gt 100 ] || gate S6 FAIL "TOC 仅 $TOC_N 行"
log "dump $SIZE 字节，TOC $TOC_N 行，可恢复"

log "journal 尾部快照（volatile，落盘证据）"
nms_ssh 'journalctl -u nms --no-pager | tail -300' > "$EVIDENCE/s6/nms-journal-tail.log" || true
nms_ssh 'journalctl --no-pager | grep -iE "discover|provision" | tail -200' > "$EVIDENCE/s6/discover-provision-log.log" || true
# 票 7：阶段 5 出口接健康闸（wave 级，期望已收敛）——阶梯绿=判据+闸双绿
python3 "$SOAK_HOME/drill/health-gate.py" --level wave --expect-converged \
  --evidence-root "$SOAK_ENV" --commit "$(git -C "$NMS2_REPO" rev-parse --short HEAD)" \
  --notes "s6 末=阶段 5 出口" || gate S6 FAIL "健康闸（wave）红——阶段 5 出口不绿"
gate S6 PASS "上下行双向通 + 基线备份可恢复 —— PHASE-1 COMPLETE"
