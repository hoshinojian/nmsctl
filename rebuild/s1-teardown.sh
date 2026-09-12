#!/bin/bash
# S1 拆除：删除全部 env:soak（含 NMS），核实 DO 侧清零；保护账号（env.local GUARD_ACCOUNT，可选）不动
# T3 必改（scale-coldstart-churn-plan §一 T3）：
#   - 盘点断言 = 与 run-benchmark 传入的 S0 实测数（EXPECT_TEARDOWN_COUNT，源自
#     evidence/baseline/fleet-count.txt）一致 ∧ 盘点全部带 env:soak tag（宁可漏删不可误删）；
#   - 唯一良性情况「盘点数==0 ∧ S0 已判定无现网 fleet」自行 exit 0（打印 SKIP）；
#     其余任何失败都非零退出——run-benchmark 对 S1 失败会中止主流程（防新旧 fleet 并存）。
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/rebuild
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）
cd "$REBUILD_DIR"
mkdir -p "$EVIDENCE/s1"
exec > >(tee "$EVIDENCE/s1/log.txt") 2>&1

check_egress
FLEET_FILE="$EVIDENCE/baseline/fleet-count.txt"
[ -f "$FLEET_FILE" ] || { echo "ABORT: S0 fleet 盘点（$FLEET_FILE）缺失——不许在无实测数时拆机（计划红线）" >&2; exit 1; }
S0_N="$(cat "$FLEET_FILE")"
EXPECT_N="${EXPECT_TEARDOWN_COUNT:-$S0_N}"
[ "$EXPECT_N" = "$S0_N" ] || { echo "ABORT: EXPECT_TEARDOWN_COUNT=$EXPECT_N 与 S0 实测 $S0_N 不一致——以 S0 落盘为准，先查来源" >&2; exit 1; }

log "S1 前置盘点（tag=env:soak，应恰 $EXPECT_N 台 = S0 实测）"
"$VPSCTL" list -tag env:soak -output "$EVIDENCE/s1/pre-inventory.json" > /dev/null
read -r PRE_N BADTAG_N <<< "$(python3 -c "
import json; d=json.load(open('$EVIDENCE/s1/pre-inventory.json'))
items = d if isinstance(d, list) else d.get('items', d.get('droplets', []))
bad = [i.get('name') for i in items if 'env:soak' not in (i.get('tags') or [])]
print(len(items), len(bad))
if bad: print('BADTAG:', bad, file=__import__('sys').stderr)")"

if [ "$PRE_N" = "0" ] && [ "$S0_N" = "0" ]; then
  log "SKIP：盘点 0 台 ∧ S0 已判定无现网 fleet（上轮已拆）——无可拆，良性退出"
  exit 0
fi

if [ "$PRE_N" != "$EXPECT_N" ]; then
  echo "ABORT: env:soak 台数 $PRE_N != S0 实测 $EXPECT_N——盘点与预期不符，宁可漏删不可误删" >&2
  exit 1
fi
[ "$BADTAG_N" = "0" ] || gate S1 FAIL "盘点中 $BADTAG_N 台缺 env:soak tag（过滤异常，不许删）"

log "盘点确认 $PRE_N 台且全带 env:soak，开始删除（不可逆；授权：用户 2026-09-10/09-11）"
"$VPSCTL" delete -tag env:soak -confirm "$EXPECT_N" -output "$EVIDENCE/s1/delete-result.json" > /dev/null

log "删除后复核（应零残留）"
"$VPSCTL" list -tag env:soak -output "$EVIDENCE/s1/post-inventory.json" > /dev/null
POST_N=$(python3 -c "
import json; d=json.load(open('$EVIDENCE/s1/post-inventory.json'))
items = d if isinstance(d, list) else d.get('items', d.get('droplets', []))
print(len(items))")
[ "$POST_N" = "0" ] || gate S1 FAIL "DO 侧仍剩 $POST_N 台 env:soak"

# 保护账号断言（注入参数，无账号名常量）：env.local 设 GUARD_ACCOUNT/GUARD_ACCOUNT_EXPECT 才执行
if [ -n "${GUARD_ACCOUNT:-}" ]; then
  : "${GUARD_ACCOUNT_EXPECT:?env.local 设了 GUARD_ACCOUNT 就必须同时设 GUARD_ACCOUNT_EXPECT}"
  log "保护账号不动断言：$GUARD_ACCOUNT（应仍 $GUARD_ACCOUNT_EXPECT 台）"
  "$VPSCTL" list -only "$GUARD_ACCOUNT" -output "$EVIDENCE/s1/guard-untouched.json" > /dev/null
  G_N=$(python3 -c "
import json; d=json.load(open('$EVIDENCE/s1/guard-untouched.json'))
items = d if isinstance(d, list) else d.get('items', d.get('droplets', []))
print(len(items))")
  [ "$G_N" = "$GUARD_ACCOUNT_EXPECT" ] || gate S1 FAIL "$GUARD_ACCOUNT 台数 $G_N != $GUARD_ACCOUNT_EXPECT——误伤"
else
  log "未设 GUARD_ACCOUNT，跳过保护账号断言"
fi

gate S1 PASS "$EXPECT_N 台删除、DO 侧清零、保护账号完好"
