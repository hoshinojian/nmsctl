#!/bin/bash
# evidence 备份（post-campaign-fixes-plan D8 卫生批）：tar.gz + sha256 + 轮转。
# 用法：SOAK_ENV=<运行时目录> scripts/soak/observe/backup.sh [备份目录，缺省 $SOAK_ENV/backups]
# 备份件含 env.local（机密）——备份目录强制 0700、文件 0600 原样保留；备份目录不属于
# 任何 git 仓（SOAK_ENV 仓内会被 lib/env.sh fail-fast 拒绝，D8 双保险）。
# 轮转：保留最近 $BACKUP_KEEP 份（缺省 3），旧的自动删除。
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # scripts/soak
source "$SOAK_SELF_DIR/lib/env.sh"

BACKUP_DIR="${1:-$SOAK_ENV/backups}"
KEEP="${BACKUP_KEEP:-3}"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$BACKUP_DIR/evidence-$STAMP.tar.gz"
# env.local 缺席（如复用旧运行时目录）不阻断备份——evidence 本体优先
tar -C "$SOAK_ENV" -czf "$OUT" evidence env.local 2>/dev/null \
  || tar -C "$SOAK_ENV" -czf "$OUT" evidence
sha256sum "$OUT" > "$OUT.sha256"
log "backup OK: $OUT（$(du -h "$OUT" | cut -f1)，sha256 见 $OUT.sha256）"

# 轮转：按时间倒序保留前 KEEP 份
ls -1t "$BACKUP_DIR"/evidence-*.tar.gz 2>/dev/null | tail -n +"$((KEEP + 1))" | while read -r old; do
  rm -f "$old" "$old.sha256"
  log "rotation: 删过期备份 $old"
done
log "在档 $(ls -1 "$BACKUP_DIR"/evidence-*.tar.gz 2>/dev/null | wc -l)/$KEEP 份"
