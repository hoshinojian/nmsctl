# 六波 runbook 八字段评审（票 0-5，2026-09-20）

> 评审对象：`drill/wave-lib.sh` + `w-a..w-f.sh` 场景表 + `inject/` 四单元 + `silent-window.sh`。
> 评审判据（规划 §4 第 5 项）：①注入手段白名单（禁批量杀 sshd）②每语句可见输出（P86）
> ③回收清单（P58）④fresh-resume 双语境（P82）。每场景八字段由 wave-lib 自动物化
> （runbook.json：inject/proof_before/proof_effective/exercise/observe/recover/proof_after/cleanup，
> 哈希入 verdict——改场景=换哈希，verdict 与定义绑定）。

## ① 注入手段白名单

| 手段 | 载体 | 批量性 | 回收 |
|---|---|---|---|
| vpsctl power off→on | power-cycle.sh / NODE-05/DISC-01.3/SSH-09.1/STAT-10.4 | 单台 | power on |
| iptables 仅拦 NEW（P50） | link-block-new.sh | 单台 | trap 自动解封 |
| stress-ng 限时压测 | threshold-stress.sh | 单台 | timeout 自止 |
| SIGSTOP/SIGCONT agent | slow-agent.sh | 单台 | trap 自动解冻 |
| systemctl restart nms / kill -9 nms | w-d PROV-03/STAT-13/SYS-08/09/10/11 | NMS 单机 | systemd 自启/重拉 |
| API 动作（DELETE/PUT/POST/dispatch） | 各波 api: op | 单目标 | conv/g5 断言收口 |

**结论：✓** 无任何 `pkill sshd`/批量停机形态；kill -9 仅用于 NMS 自身（STAT-13 硬切形态，
规划 §7 明示要求），节点侧全部可回收手段。

## ② 每语句可见输出（P86）

- 每 op 落 `$WAVE_EVIDENCE/<case>/`：unit/churn/api/nms/conv/alert 各自 .log/.json；
- DRY_RUN 同链路（`DRY …（跳过）` 逐条入 log.txt 与 units.log）；
- verdict notes 携 fail 明细；对账门输出「N 条逐 id 相等」。**✓**

## ③ 回收清单（P58）

- link-block：iptables -D 由 trap EXIT/INT/TERM 保证（含脚本被杀）；
- slow-agent：SIGCONT 同 trap 保障；
- power-cycle：脚本内 off→on 成对，失败即日志 ABORT；
- threshold-stress：timeout 双保险；
- NMS restart/kill：systemd 拉起；波末 wave 级健康闸复核。
- 波后由 silent-window 窗末三判据+P58 对照清点。**✓**

## ④ fresh-resume 双语境（P82）

- 波前门 live=API 实测全健康+零告警，DRY=fixture 同断言链；
- churn 复用沿用其 R 波进场前置（同口径）；
- SYS-01 不入波（第一部分循环证据独立载体，冻结清单对账门强制）。**✓**

## 对账门（六波 DRY 实测，2026-09-20）

```
W-A 26 / W-B 15 / W-C 6 / W-D 18 / W-E 16 / W-F 11 —— 与 NMS2 rl-drill-freeze.py
附录 A 逐 id 相等；六波全场景 PASS exit=0（fixture 79 节点全绿）
```

## 首轮 Round 1 校准点（登记，非缺陷）

1. 注入↔告警类型映射（node_unreachable/pull_failed/cpu_critical/host_key_tamper）首轮实测校准；
2. W-C 波级几何切换（FH=1+max_depth=6+SOAK_BATCHES/NODE_COUNT 同步改）在 runbook 人工节，
   脚本只做波前门；
3. api 断言码细粒度（409 负例已写死、其余缺省 2xx）随首轮回填；
4. 审计对账（SYS-14 锚）在 health-gate round 级按 WARN 起步，首轮后收紧。
