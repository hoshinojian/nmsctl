# verdict JSONL schema（R+L 演练，票 0-3）

> 证据根：`~/nms-r-drill-20260920/verdicts/*.jsonl`（波/轮/长窗各一文件）。
> 工具：`observe/verdict.py`（write 写一行 / check 校验聚合）。改 schema 必须同步本文件与工具。

## 记录字段（rl-drill-verdict/1，每行一个 JSON 对象）

| 字段 | 类型 | 语义 |
|---|---|---|
| `schema` | str | 恒 `"rl-drill-verdict/1"` |
| `carrier` | str | 载体名。矩阵载体（W-A…W-F / 第一部分建树循环 / SYS-15 真机全形态票 / SYS-16 24h 长静默窗 / L 本地×4）与 NMS2 `scripts/dev/rl-drill-freeze.py` 的载体表同名；非矩阵载体（`非矩阵（健康闸/静默窗等）`、`阶梯点亮（非矩阵）`）只在本 schema 登记、不进冻结分母 |
| `scenario` | str | 场景键（脚本内稳定标识，kebab-case；健康闸/静默窗等非矩阵场景用 `health-gate` / `silent-window` 等） |
| `case` | str\|null | 家族.变体编号（如 `SSH-14.1`）；非矩阵场景为 null |
| `runbook_hash` | str | 八字段哈希 `sha256:<64hex>`——场景 runbook 八字段（inject/proof-before/proof-effective/exercise/observe/recover/proof-after/cleanup）规范 JSON（sort_keys、ensure_ascii=False、分隔符 `,`/`:`）的 sha256。verdict 与场景定义由此绑定，改八字段=换哈希 |
| `verdict` | str | `PASS` \| `FAIL` \| `SKIPPED_DUE_TO` |
| `skipped_due_to` | str | 仅 `SKIPPED_DUE_TO` 时必填：引用问题台账条目 ID（污染面判定） |
| `ts` | str | UTC ISO8601（`2026-09-21T02:33:11Z`） |
| `commit` | str | 被测 NMS main 构建 commit（40hex 或短哈希≥7hex） |
| `requestid` | str | **可选**。覆盖面（复审核定，2026-09-20）：HTTP 访问与处理器日志、`POST /topology/discover` 异步任务体、dispatch finishCtx（WithoutCancel 保 values）**带**；周期后台（sweeps/collect/reconciler/retryer）、provision 部署轮（即使 POST /deploy 触发）、开键自动化 bg **整字段不出现**（不是空串）。journal 签名检索不依赖本字段 |
| `evidence` | [str] | 相对证据根的路径列表（≥1） |
| `notes` | str | 备注（可空） |
| `stage` | obj | **可选**（v3.4.1 票 6，阶梯 attempt 留痕）。`{"phase":1..5, "rung":"nms"/"5vps"/"1node"/"10node"/null, "attempt":≥1, "form":"fresh"/"resume"/null}`——phase=阶梯阶段、attempt=attempt 序号（**连续绿计数依据**）、form=s5 形态判定（P82 双语境）。**仅 carrier=`阶梯点亮（非矩阵）` 可带**；不进八字段哈希 |
| `channel` | obj | **可选**（v3.4.1 票 6，通道漂移回放）。`{"nms_ssh_via":"auto"/"direct"/"stunnel443", "wg_handshake":"<UTC ISO8601>"/null}`——实际生效通道值+`wg show` 最近握手时戳；任意载体可带；不进八字段哈希 |

## 校验规则（verdict.py check，任一违例 exit 1）

1. `schema` 标签精确匹配；每行可解析为 JSON 对象。
2. `carrier` ∈ 已知载体集；`verdict` ∈ 三值；`ts` 可解析且 UTC。
3. `case` 非空时匹配 `^[A-Z]+-\d+(\.\d+)?$`；`--cases cases.json` 给定时须存在于 variant_frozen。
4. `runbook_hash` 匹配 `sha256:[0-9a-f]{64}`。
5. `SKIPPED_DUE_TO` 必带 `skipped_due_to`；`PASS/FAIL` 不得带。
6. `requestid` 要么整字段不出现，要么非空字符串（禁止空串——「不带」的语义是字段不出现）。
7. `evidence` 非空列表且元素为字符串；`commit` 匹配 `^[0-9a-f]{7,40}$`。
8. 聚合输出：按载体×verdict 计数、FAIL/SKIP 清单、总行数——贴波末/轮末报告。
9. `stage` 若出现：须为对象，`phase∈1–5` 整数、`attempt≥1` 整数、`rung` 非空字符串或 null、`form∈{fresh,resume}` 或 null；**carrier 必须为 `阶梯点亮（非矩阵）`**（矩阵载体不得带——冻结语义隔离）。stage 与 channel 均不进八字段哈希（自由附注，replay 哈希不变）。
10. `channel` 若出现：须为对象，`nms_ssh_via` 非空字符串、`wg_handshake` 为 UTC ISO8601（`…Z`）或 null；任意载体可带（波/轮也记，通道漂移可回放）。
