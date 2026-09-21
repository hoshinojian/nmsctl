#!/bin/bash
# ⚠ 未参数化（28/29 台 era 应急脚本），勿不加检查直接用于 65 台 fleet（T3 2026-09-11）。
# S2 修复：DO user-data 链路把非 ASCII 注释二次编码产生 C1 控制字符 → docker compose YAML 拒绝。
# 动作：保留首次自举日志 → 远端重放 ASCII 版自举脚本（幂等）→ 等 PG 就绪。之后续跑 s2-nms.sh。
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/rebuild
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）
mkdir -p "$EVIDENCE/s2"
exec > >(tee "$EVIDENCE/s2/repair-log.txt") 2>&1

IP=$(cat "$NMS_IP_FILE")
log "保留首次自举日志副本（证据）"
ssh $SSHOPT -p "$SSHD_PORT" "root@$IP" 'cp -n /var/log/bootstrap.log /var/log/bootstrap.log.attempt1 2>/dev/null || true'
log "重放 ASCII 版自举脚本（nms-user-data6-ascii.sh）"
ssh $SSHOPT -p "$SSHD_PORT" "root@$IP" 'bash -s' < "$REBUILD_DIR/nms-user-data6-ascii.sh" || true
log "检查远端自举标记与 PG"
ssh $SSHOPT -p "$SSHD_PORT" "root@$IP" 'tail -3 /var/log/bootstrap.log; docker exec nms-timescaledb pg_isready -U nms'
log "修复完成，请重跑 s2-nms.sh 续跑"
