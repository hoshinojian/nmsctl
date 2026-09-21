#!/bin/bash
# 终验 benchmark 入口（onboard-speedup-plan.md §三；拆机重建已经用户 2026-09-11 授权；
# T3 65 台参数化：scale-coldstart-churn-plan.md §一 T3 / §二）
# 用法：EXPECT_HEAD=<当轮 main 终点> bash run-benchmark.sh
# 前置断言：T2 两 PR 已全部合入 main；本文件 EXPECT_HEAD 已回填。
set -euo pipefail
SOAK_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # 仓内定位：scripts/soak/rebuild
source "$SOAK_SELF_DIR/../lib/env.sh"   # SOAK_ENV(运行时目录)+env.local 注入（零凭据入库，coldstart §四）

# S0 基线打现网 NMS——重建后 IP 会变：OLD_NMS_IP 由运行时目录 env.local 注入，
# 过时值由 S0 经 DO 盘点（soaknms 前缀机实测 IP）自动纠正，无需改仓内任何文件。
# preflight 已移除：拆机重建场景旧 NMS 必不可达；黑壳现象靠重开任务解决
export DEPLOY_CONCURRENCY=12   # T3 必改(c)：dc 口径统一 12（计划 §〇；不显式导出会被 s2 兜底缺省吃掉）
# 树参数注入口（R+L 演练票 0 复核补）：env.local 预设优先，缺省维持 #122/#123 bench 键。
# 演练主几何经 env.local 注入 '"relay_fanout":4,"child_budget":2,"max_depth":8'。
# ISS-003 教训（Round1 attempt3 实录）：预设分支曾漏 export——env.local 经 env.sh source
# 进来的是本 shell 变量，s2 是子进程不继承非导出变量 → PUT 悟空（GET 全是注册表缺省
# 3/7/4/2）。无论走哪个分支都必须 export。
if [ -z "${BENCH_EXTRA_CONFIG:-}" ]; then
  BENCH_EXTRA_CONFIG='"relay_fanout":4,"race_parents":2'  # 决策 #122/#123 新键
fi
export BENCH_EXTRA_CONFIG
T0=$(date -u +%FT%TZ)
echo "=== BENCH START $T0 (EXPECT_HEAD=$EXPECT_HEAD NODE_COUNT=$NODE_COUNT) ==="

# T3 必改(a)：S1 拆除数不许写死——取 S0 落盘的现网 env:soak 盘点实数（fleet-count.txt，
# 首跑=29、重建后重跑=65 都成立）。先清陈旧文件，S0 没产出就中止，绝不盲拆。
rm -f "$EVIDENCE/baseline/fleet-count.txt"
# 幂等重跑：S0（无现网可采则自行 SKIP exit 0）；S2 前清陈旧 droplet 记录
bash "$SOAK_HOME/rebuild/s0-baseline.sh" || echo "S0 SKIPPED（容错保留：S0 异常不阻拆——但缺 fleet 盘点时下方中止）"
T_S0=$(date -u +%FT%TZ)
[ -f "$EVIDENCE/baseline/fleet-count.txt" ] || {
  echo "ABORT: S0 未产出 fleet 盘点（evidence/baseline/fleet-count.txt 缺失）——S1 拒绝在无实测数时拆机" >&2
  exit 1
}
export EXPECT_TEARDOWN_COUNT="$(cat "$EVIDENCE/baseline/fleet-count.txt")"
log "S1 拆除目标 = S0 现网盘点实数：$EXPECT_TEARDOWN_COUNT 台（含 NMS）"

# T3 必改(b)：S1 失败（盘点数不符 ABORT 等）必须中止主流程，不再被 || 吞——
# 防新旧 fleet 并存 94 台；「无可拆 SKIP」的良性情况由 s1 自行 exit 0（打印 SKIP）。
bash "$SOAK_HOME/rebuild/s1-teardown.sh"
T_S1=$(date -u +%FT%TZ)
rm -f "$EVIDENCE/s2/create-nms.json"   # nms.json 交由 s2 存活判定决定去留
bash "$SOAK_HOME/rebuild/s2-nms.sh";       T_S2=$(date -u +%FT%TZ)
# 环境↔代码对账门（2026-09-21 用户新增，ISS-003 泛化）：活系统快照（含通道探测自适应）
# 与 env.local 逐项配位——出口/配置实效/台数/树参/防火墙，不配位即中止（不带着错配跑 79 台）。
python3 "$SOAK_HOME/drill/env-verify.py" --refresh --require-live
bash "$SOAK_HOME/rebuild/s3-nodes.sh";     T_S3=$(date -u +%FT%TZ)
bash "$SOAK_HOME/rebuild/s4-import.sh";    T_S4=$(date -u +%FT%TZ)
bash "$SOAK_HOME/rebuild/s5-onboard.sh";   T_S5=$(date -u +%FT%TZ)   # 头条：开键→$NODE_COUNT/$NODE_COUNT 零介入
bash "$SOAK_HOME/rebuild/s6-verify.sh";    T_S6=$(date -u +%FT%TZ)

{
  echo "六段计时（UTC；NODE_COUNT=$NODE_COUNT）"
  echo "S0 基线结束:        $T_S0"
  echo "S1 拆除完成:        $T_S1"
  echo "S2 NMS 健康:        $T_S2"
  echo "S3 $NODE_COUNT 台就绪:       $T_S3"
  echo "S4 入池完成:        $T_S4"
  echo "S5 开键→$NODE_COUNT/$NODE_COUNT 收敛: $T_S5   ← 头条指标（28 台基线 4m02s@dc12；64 台预期 8-15min，30min 门内）"
  echo "S6 上下行验证:      $T_S6"
} | tee "$EVIDENCE/bench-timings.txt"
echo "=== BENCH COMPLETE ==="
