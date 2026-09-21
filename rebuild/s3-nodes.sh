#!/bin/bash
# S3 建 64 台测试节点 + 1 NMS（S2 已建）= 65 台
# T3 分布表（scale-coldstart-churn-plan §一 T3；区域/账号分布为注入参数——coldstart §四
#   「无任何账号名常量」，账号列由 env.local 的 SOAK_BATCHES 提供，样例见 env.local.example：
#   sgp1 <账号A> 11（含 9 第一跳）/ nyc1 <账号A> 8 / lon1 <账号B> 8 / tor1 <账号B> 8 /
#   blr1 <账号B> 6 / fra1 <账号C> 8 / syd1 <账号C> 7 / atl1 <账号C> 8（amd 机型））
# T3 必改：
#   - 重试按缺口补建：每轮先盘点该区域实有 active 数，只补差额（整批重试在部分成功后会超建）；
#   - 前置配额预检：裸 GET /v2/account 取 droplet_limit，断言各账号 limit ≥ 计划数（NMS 记
#     NMS_ACCOUNT 名下，含 1 台），不足 ABORT（token 只在内存使用，不落日志）；
#   - 总盘点断言 $((NODE_COUNT+1))=65、区域计数对表、重名/重复 id 断言保留。
# DRY_RUN=1：静态验证模式——不调任何 DO API（含配额预检）、不建机，只打印将执行的断言。
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/rebuild
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）
cd "$REBUILD_DIR"
mkdir -p "$EVIDENCE/s3"
exec > >(tee "$EVIDENCE/s3/log.txt") 2>&1

# 区域 账号 台数 机型（合计必须 == NODE_COUNT=64；区域→账号在本表内一一对应）
# 分布表本体由 env.local 的 SOAK_BATCHES 注入（每行一批，账号列不得写进本仓）
BATCHES=()
while IFS= read -r _line; do [ -n "$_line" ] && BATCHES+=("$_line"); done \
  <<< "${SOAK_BATCHES:?env.local 缺 SOAK_BATCHES（区域 账号 台数 机型，每行一批；样例见 env.local.example）}"

# 对账：BATCHES 合计 == NODE_COUNT（防分布表与全局标量漂移）
SUM=0; for line in "${BATCHES[@]}"; do set -- $line; SUM=$((SUM + $3)); done
[ "$SUM" = "$NODE_COUNT" ] || { echo "ABORT: BATCHES 合计 $SUM != NODE_COUNT=$NODE_COUNT——分布表与全局标量（lib/env.sh）不一致，先对表" >&2; exit 1; }

# 各账号计划数（节点合计 + NMS 记 NMS_ACCOUNT 名下 1 台）与期望区域分布（含 NMS 记 NMS_REGION）
declare -A ACCT_PLAN EXPREG
for line in "${BATCHES[@]}"; do set -- $line
  ACCT_PLAN[$2]=$(( ${ACCT_PLAN[$2]:-0} + $3 ))
  EXPREG[$1]=$(( ${EXPREG[$1]:-0} + $3 ))
done
ACCT_PLAN[$NMS_ACCOUNT]=$(( ${ACCT_PLAN[$NMS_ACCOUNT]:-0} + 1 ))
EXPREG[$NMS_REGION]=$(( ${EXPREG[$NMS_REGION]:-0} + 1 ))
PLAN_STR="$(for k in "${!ACCT_PLAN[@]}"; do echo "$k:${ACCT_PLAN[$k]}"; done | tr '\n' ' ')"
REGION_EXPECT="$(for k in "${!EXPREG[@]}"; do echo -n "$k=${EXPREG[$k]},"; done | sed 's/,$//')"
# 分布表落盘，供 S4 断言区域计数（单一来源，S4 不复写表）
printf '%s\n' "${BATCHES[@]}" | awk '{a[$1]+=$3} END {for (r in a) print r, a[r]}' > "$EVIDENCE/s3/distribution.txt"  # 按区域聚合：同区域多账号时逐行会产生重复键，S4 dict 读取互覆

# 区域内 env:soak active 台数（剔除 NMS 机；<inv.json> <region>）
region_active_count() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, os, sys
d = json.load(open(sys.argv[1]))
items = d if isinstance(d, list) else d.get('items', d.get('droplets', []))
n = sum(1 for i in items
        if i.get('region') == sys.argv[2] and i.get('account') == sys.argv[3]
        and i.get('status') == 'active'
        and not i.get('name', '').startswith(os.environ['NMS_NAME_PREFIX']))
print(n)
PYEOF
}

if [ "${DRY_RUN:-0}" = "1" ]; then
  log "DRY_RUN=1：静态验证模式——不调任何 DO API、不建机，以下为将执行的断言（T3 验证口径）"
  echo "  [配额预检将执行] 裸 GET /v2/account 取 droplet_limit，token 取自 \$VPSCTL_ACCOUNTS（不落日志）："
  for kv in $PLAN_STR; do echo "    断言 ${kv%%:*} droplet_limit >= ${kv##*:}"; done
  echo "  [建机计划] （重试按缺口补建：每轮盘点存量后只补差额，最多 3 轮/区域）"
  for line in "${BATCHES[@]}"; do echo "    create $line"; done
  echo "  [总盘点将断言] tag=env:soak 共 $((NODE_COUNT + 1)) 台（$NODE_COUNT 节点 + NMS@$NMS_REGION）；区域分布 $REGION_EXPECT；全 active；重名/duplicate id 拒绝"
  log "DRY_RUN 结束（未执行任何 DO API 调用）"
  exit 0
fi

check_egress
[ -f "$NMS_IP_FILE" ] || { echo "ABORT: S2 未执行" >&2; exit 1; }

# ---- S3 前置配额预检（T3 必改）：vpsctl 无配额命令，裸 GET /v2/account ----
# D4（同批）：配额预检同时做账号凭据防呆——无 ssh_password 账号若不传 user-data 即裸机
#（P81：机器无法 SSH 管理 → 探针负事实 → 拉黑死锁）。D3 落地后本预检退化为「自动分叉
# 提示」：无密码批次将自动传实例化 user-data（密码同源 NODE_PASS），缺 AUTHORIZED_KEY
# 则在此 fail-fast，不等到建机才发现。
log "配额预检：droplet_limit vs 计划（$PLAN_STR）+ 凭据防呆（D4）——token 只在内存使用，不落日志"
PLAN_STR="$PLAN_STR" python3 - <<'PYEOF'
import json, os, urllib.request
plan = dict(kv.split(':') for kv in os.environ['PLAN_STR'].split())
cfg = json.load(open(os.environ['VPSCTL_ACCOUNTS']))
accts = cfg['accounts'] if isinstance(cfg, dict) else cfg
rows, fail, passwordless = [], False, []
for a in accts:
    name = a.get('name')
    if name not in plan:
        continue
    req = urllib.request.Request('https://api.digitalocean.com/v2/account',
                                 headers={'Authorization': 'Bearer ' + a['token']})
    acc = json.load(urllib.request.urlopen(req, timeout=20))['account']
    limit = int(acc['droplet_limit'])
    ok = limit >= int(plan[name])
    fail = fail or not ok
    if not a.get('ssh_password'):
        passwordless.append(name)
    rows.append((name, int(plan[name]), limit, 'OK' if ok else '不足',
                 'user-data 分叉' if not a.get('ssh_password') else 'ssh_password 注入'))
print('配额预检结果（账号: 计划/limit/判定/凭据模式）:')
for r in rows:
    print(f'  {r[0]}: {r[1]} / {r[2]} / {r[3]} / {r[4]}')
with open('evidence/s3/passwordless-accounts.txt', 'w') as f:
    f.writelines(n + '\n' for n in passwordless)
if passwordless and not os.environ.get('AUTHORIZED_KEY', '').strip():
    raise SystemExit('ABORT(D4): 无 ssh_password 账号 %s 但 AUTHORIZED_KEY 未设置——user-data 分叉无法实例化，先补 env.local' % passwordless)
if passwordless:
    print(f'D3 分叉：{passwordless} 批次建机将传实例化 user-data（node-user-data-ascii.sh，密码同源 NODE_PASS）')
if fail:
    raise SystemExit('ABORT: 配额不足——按计划先调分布再建机（分布表见 scale-coldstart-churn-plan §一 T3）')
PYEOF

# ---- 建机：按缺口补建（每轮补建前重新盘点存量，防部分成功后整批重试超建）----
# ISS-013（v3.4 高位口）：全批次统一走 user-data 路径——节点模板（禁 ssh.socket+Port
# $SSHD_PORT+authorized_keys）必须在每台节点上运行；有密码账号经「strip ssh_password 的
# 临时账号配置」绕 P70① 互斥（s2 NMS 建机同款），密码由模板 chpasswd 设同值 NODE_PASS
#（与 s4 载荷 ssh_password 同源）。裸机交付路径退役。
NODE_UD="$EVIDENCE/s3/node-user-data.sh"   # 统一实例化件（0600 落运行时目录，不入库）
[ -f "$NODE_UD" ] || instantiate_user_data "$SOAK_HOME/rebuild/node-user-data-ascii.sh" "$NODE_UD"
[ -n "${AUTHORIZED_KEY:-}" ] || { echo "ABORT: AUTHORIZED_KEY 未设置——user-data 统一路径必需（authorized_keys 注入）" >&2; exit 1; }
strip_account_cfg() { # strip_account_cfg <账号名> → 临时配置路径（密码剔除，0600）
  python3 - "$1" <<'PYEOF'
import json, os, sys
name = sys.argv[1]
cfg = json.load(open(os.environ['VPSCTL_ACCOUNTS']))
arr = cfg['accounts'] if isinstance(cfg, dict) else cfg
one = [dict(a) for a in arr if a['name'] == name]
assert len(one) == 1, f'账号 {name} 不在 accounts 配置'
one[0].pop('ssh_password', None)
out = f"evidence/s3/accounts-{name}-stripped.json"
json.dump({"accounts": one}, open(out, 'w'))
os.chmod(out, 0o600)
print(out)
PYEOF
}
for line in "${BATCHES[@]}"; do
  set -- $line; region=$1; acct=$2; want=$3; size=$4
  ACCT_CFG=$(strip_account_cfg "$acct")
  ud_args=(-user-data "$NODE_UD" -accounts "$ACCT_CFG")
  log "统一 user-data 路径：$acct（strip 密码临时配置+模板自设同值；高位口 $SSHD_PORT）"
  done_flag=""
  for try in 1 2 3; do
    inv="$EVIDENCE/s3/have-$region-$acct-try$try.json"
    "$VPSCTL" list -tag env:soak -no-check-ssh -output "$inv" > /dev/null
    have=$(region_active_count "$inv" "$region" "$acct")
    need=$((want - have))
    if [ "$need" -le 0 ]; then
      if [ "$have" -gt "$want" ]; then
        gate S3 FAIL "$region 存量 $have 超过计划 $want（超建，人工核查）"
      fi
      log "$region 存量 $have/$want，无需补建"
      done_flag=1; break
    fi
    out="$EVIDENCE/s3/create-$region-$acct-try$try.json"
    log "create $region/$acct x$need（存量 $have/$want，$size）第 $try 轮"
    if "$VPSCTL" create -image ubuntu-24-04-x64 -region "$region" -size "$size" \
         -only "$acct" -count "$need" -name-prefix soak -tags env:soak -wait 420s \
         ${ud_args[@]+"${ud_args[@]}"} \
         -output "$out" > /dev/null; then
      got=$(python3 -c "
import json; d=json.load(open('$out'))
print(sum(1 for c in d.get('created', []) if c.get('status') == 'active'))")
      log "$region 第 $try 轮创建 $got/$need active"
      if [ "$got" = "$need" ]; then
        done_flag=1   # 本轮恰好补满（have+need=want），无需再盘点
        break
      fi
    else
      log "$region 第 $try 轮 create 命令非零退出（可能部分成功），下一轮按缺口重盘"
    fi
    sleep 20
  done
  [ -n "$done_flag" ] || gate S3 FAIL "$region 3 轮补建后仍不足 $want 台（容量/配额问题，人工介入）"
done

# ---- 总盘点断言：65 = 64 节点 + NMS；区域计数对表；全 active；唯一性 ----
log "总盘点（tag=env:soak 应 $((NODE_COUNT + 1)) = $NODE_COUNT 节点 + NMS）"
"$VPSCTL" list -tag env:soak -no-check-ssh -output "$EVIDENCE/s3/inventory.json" > /dev/null
REGION_EXPECT="$REGION_EXPECT" python3 - <<'PYEOF'
import collections, json, os
d = json.load(open('evidence/s3/inventory.json'))
items = d if isinstance(d, list) else d.get('items', d.get('droplets', []))
total_expect = int(os.environ['NODE_COUNT']) + 1
assert len(items) == total_expect, f"总台数 {len(items)} != {total_expect}"
not_active = [i['name'] for i in items if i.get('status') != 'active']
assert not not_active, f"非 active: {not_active}"
no_tag = [i['name'] for i in items if 'env:soak' not in (i.get('tags') or [])]
assert not no_tag, f"缺 env:soak tag: {no_tag}"
regions = collections.Counter(i['region'] for i in items)
expect = {k: int(v) for k, v in (kv.split('=') for kv in os.environ['REGION_EXPECT'].split(','))}
assert dict(regions) == expect, f"区域分布 {dict(regions)} != 计划 {expect}"
names = [i['name'] for i in items]
assert len(set(names)) == len(names), "重名（P69）"
assert len({i['id'] for i in items}) == len(items), "droplet id 重复"
print("inventory OK:", dict(regions))
PYEOF
gate S3 PASS "$NODE_COUNT 台测试节点 + NMS 全部 active"
