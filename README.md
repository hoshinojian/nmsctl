# nmsctl —— NMS 测试编排器（fleet tester）

**nmsctl 是 [NMS](https://github.com/hoshinojian/nms)（YB 网管平台服务端）的测试器**：一套把「拆机 → 重建 NMS → 批量建节点 → 纳管 → 收敛验证 → 增删扰动」全流程脚本化的测试编排器，设计目标是**零人工**——每一步带断言门，断言失败即停、落盘现场，人工只在门失败时介入诊断。

它能对一套自建 NMS 做：

- **全删重建冷启动验证**（S0–S6）：从云上零机器开始，脚本全自动建 NMS、批量建测试节点、导入、开键纳管，测「从开键到全部节点纳管收敛」的时长与成功率；
- **增删扰动韧性波**（R1–R5）：对运行中的 fleet 做单台删复活、批量重导、父节点摘除、负向守卫、第一跳复活等场景，验证管理树的自愈能力；
- **持续观测**：周期采样 fleet 状态/告警面/部署轮，落 JSONL 时间线；
- **树形不变量验收**：对管理树做「第一跳数/出度上限/深度上限/挂接边一致性」的不变量断言。

> **本仓库不含 NMS 本体**——nmsctl 只是被测系统的测试器，通过 REST API 与 NMS 交互、通过云 CLI 操作虚拟机。NMS 本体与 vpsctl（云资源 CLI）是独立项目。

---

## 架构总览

```
                    ┌────────────────────────────┐
                    │   nmsctl（本仓库，编排机）   │
                    │   shell 驱动 + 断言 + 证据   │
                    └──────┬──────────────┬──────┘
                 REST API  │              │  CLI 子进程
                 (curl)    │              │  (vpsctl)
                    ┌──────┴──────┐  ┌────┴─────────┐
                    │  NMS 服务端  │  │  云厂商 API   │
                    │  + TimescaleDB│ │ (建/删/盘点 VM)│
                    └──────┬──────┘  └────┬─────────┘
                    SSH/ProxyJump        │ 创建
                    管理树               ▼
                    ┌────────────────────────────┐
                    │  测试节点 fleet（装 agent）  │
                    └────────────────────────────┘
```

nmsctl 运行在一台 **fleet 之外的编排机**上（这是结构性要求：S1 会删掉包括 NMS 在内的全部机器，编排者不能在被编排系统里面）。

---

## 目录结构与各脚本作用

```
nmsctl/
├── env.local.example   # 运行时注入样例（机密与部署事实全走这个文件，永不入库）
├── lib/
│   └── env.sh          # 公共层：SOAK_ENV/env.local 装载、api()（REST 带重试）、
│                       #   nms_ssh、check_egress（出口 IP 断言）、log/gate、全局标量缺省
├── rebuild/            # —— 全删重建冷启动流水线（S0–S6）——
│   ├── run-benchmark.sh    # 总驱动：按序跑 S0–S6，六段计时，任一门失败中止
│   ├── s0-baseline.sh      # 采集现网基线（5 端点快照+树形分布）→ 产出 fleet 实测台数
│   ├── s1-teardown.sh      # 拆除：按 tag 盘点→数量与 S0 实测强等→逐台校验 tag→删除→清零复核
│   ├── s2-nms.sh           # 重建 NMS：构建→建机→推二进制→等自举→挂防火墙→PUT 配置
│   ├── s2-repair.sh        # 自举失败时的幂等重放工具
│   ├── s3-nodes.sh         # 批量建测试节点（区域/账号/台数分布表注入；配额预检；缺口补建）
│   ├── s4-import.sh        # 生成载荷→POST /topology 入池（domain 标注显式清单）
│   ├── s5-onboard.sh       # 批量开键（1s 窗合批）→ 收敛轮询 → G4 部署轮断言 → G5 树形断言
│   ├── s6-verify.sh        # 双向验证：上行采集有数据点 + 下行指令回读 + 全局复核 + pg_dump
│   └── nms-user-data6-ascii.sh  # 节点自举 user-data 模板（ASCII-only，占位符运行时实例化）
├── churn/              # —— 增删扰动韧性波（R1–R5）——
│   ├── run-r-wave.sh       # 串行驱动：逐场景进场前置检查（全 fleet 健康+零告警），失败即停
│   ├── r-lib.sh            # 场景公共库：带 HTTP 码的 API 助手/断言台账/verdict 落盘/fail 现场
│   ├── r-select.py         # 目标动态选取（从 topology 快照按场景画像选，不写死主机名）
│   ├── r1-revive-deep.sh   # R1 深路径叶子：删→复活→重纳管（验证复活清账与重新挂接）
│   ├── r2-batch8.sh        # R2 批量：N 台删→重导→同窗开键（验证合批为一轮部署）
│   ├── r3-parent-removal.sh# R3 父节点摘除：裸删 409→强制删疏散后代→重录→全树不变量
│   ├── r4-negative-guards.sh# R4 负向守卫：重复录入/重复删除/状态机非法转移等期望码
│   ├── r5-firsthop-revive.sh# R5 第一跳复活：直连路径删→复活（验证不等挂树直接部署）
│   └── tests/              # fixture 干跑：假树 JSON + 全脚本零网络自检
├── observe/
│   ├── witness.py          # 30s 采样 nodes/alerts/agent-deploy → JSONL 时间线
│   └── g5-tree.py          # 树形不变量断言：全量纳管/第一跳数/出度≤上限/深度≤上限/边一致
└── tools/                  # 现场修复工具（处理历史脏数据的 surgical 工具）
    ├── revive-one.sh           # 单台复活（已归档 id → 重录 → 开键 → 收敛）
    ├── heal-double-parent.sh   # 双父节点修复（删→复活清边）
    └── heal-tree-r3.sh         # 疏散后树形修复
```

---

## 脚本之间如何配合

### 重建流水线（S0→S6，数据流）

```
s0 基线 ──产出──▶ fleet 实测台数 ──强等校验──▶ s1 拆除（tag 圈定+双计数门）
                                                  │ 删除后 DO 清零复核
s2 建 NMS ◀──需要「零残留」────────────────────────┘
  │ 产出：NMS IP 写入证据目录 + 配置 PUT + agent 版本断言
  ▼
s3 建节点 ──消耗──▶ 配额预检（云账号限额 vs 计划数，不足即停）
  │ 产出：65 台节点 + 分布表落盘
  ▼
s4 入池 ──消费分布表──▶ domain 标注（前缀机=直连第一跳）──▶ POST /topology
  ▼
s5 开键 ──▶ 收敛轮询（每 5s 查树）──▶ G4 部署轮断言（≤2 轮/终轮全成）──▶ G5 树形断言（g5-tree.py）
  ▼
s6 双向验证（采集上行 + 指令下行）──▶ pg_dump 基线备份
```

配合的三个关键纪律：

1. **门与门之间靠证据文件交接**：每步把状态快照落 `evidence/<步>/`，下一步的断言读上一步的落盘（如 s1 只信 s0 落盘的实测台数，不信环境变量）；
2. **断言失败 = 立即中止 + 现场落盘**（API 快照/journal 尾部/verdict.json），绝不停在半途等人工；
3. **幂等可重跑**：已完成步骤的产物存在则跳过（如 s2 发现 NMS 机存活则复用，只补推送不一致的二进制）。

### 扰动波（R1→R5）

`run-r-wave.sh` 串行驱动，每个场景进场前先过**前置检查**（全 fleet 纳管/在线/采集正常 + active 告警为零），场景内：`r-select.py` 从实时 topology 按画像动态选目标（深度/出度/区域画像）→ 动作 → 逐条断言 → verdict 落盘。任一断言失败即停整波，现场（API 快照 + journal 段落）落 `evidence/R*/fail/`。

---

## 与 NMS 如何配合

nmsctl 对 NMS 的全部交互走 **REST API**（`lib/env.sh` 的 `api()` 助手：curl 封装 + 非 2xx 退避重试 + 证据落盘），不碰数据库、不进 NMS 主机改状态（唯一例外：s2 推送 NMS/agent 二进制走 SSH——那是装机动作，属于置备阶段）。

| NMS API | 用途 | 使用者 |
|---|---|---|
| `GET /api/v1/health` | s2 健康轮询 | s2 |
| `PUT /api/v1/config` | 写运行配置（树形/并发/超时参数，见下） | s2 |
| `POST /api/v1/topology` | 节点入池/批量重导（幂等 upsert） | s4, R2 |
| `GET /api/v1/nodes` `GET /nodes/{id}` | fleet 状态轮询、单台画像 | s5/s6, R*, witness |
| `PUT /api/v1/nodes/{id}` | `onboard` 开键（false→true 触发纳管流水线） | s5, R1/R2/R3/R5 |
| `DELETE /api/v1/nodes/{id}`（可选 `?force=true`） | 删除/携子树强制摘除（409 语义断言） | R1/R2/R3/R5 |
| `GET /api/v1/topology` | 树形结构（第一跳/深度/父子边）→ 树形断言与目标选取 | s5/g5, r-select |
| `GET /api/v1/alerts` | 告警面（进场零告警门、级联告警自解断言） | run-r-wave, R3 |
| `GET /api/v1/agent-deploy` | 部署轮断言（轮数/终态/台数） | s5, R2, witness |
| `POST /api/v1/nodes/{id}/dispatch` | 下行指令回读（双向验证的"下"） | s6 |

**NMS 侧行为契约**（nmsctl 依赖这些设计，改 NMS 时注意）：

- `PUT onboard=true` 有 **1s 去抖合批**：1 秒窗口内的多个开键合并为一个部署批次——s5/R2 靠它把几十台合成一轮部署；
- 部署轮有**部分失败自动重排**语义：终态允许 ≤2 轮（主轮 partial → 自动重排轮 succeeded），G4 断言按此口径；
- 配置键热生效：`PUT /config` 后无需重启（`deploy_concurrency`/`resweep_interval`/`dial_timeout_ms` 等逐轮现读）；
- **纳管失败快速回 idle 并开 `onboard_failed` 告警**——重新纳管需先置 `onboard=false` 再 `true`（R 系列的"P74 舞步"封装在 r-lib）。

**二进制分发**：s2 从编排机的构建产物向 NMS 主机推送 server 二进制与 agent 二进制（sha256 一致则跳过），agent 版本在 S5 断言与预期一致。

**自举协议**（s2 等 NMS 就绪的方式）：节点/主机的 user-data 在云侧执行自举脚本，完成后写 `BOOTSTRAP-OK` 标记；s2 轮询该标记（失败路径有 `BOOTSTRAP-FAILED` fast-path），不猜时间。

## 与 vpsctl 如何配合

[vpsctl](https://github.com/hoshinojian/vpsctl) 是一个云资源 CLI（示例实现面向 DigitalOcean，任何能脚本化「建/删/盘点 VM + 管防火墙」的工具都可平移替换）。nmsctl 把它当作**云资源生命周期**的唯一通道：

| vpsctl 能力 | 用途 | 使用者 |
|---|---|---|
| `create -image -region -size -count -name-prefix -tags -wait -user-data -output` | 批量建 VM（等 active、带 tag、带自举脚本、结果落 JSON） | s2, s3 |
| `list -tag env:soak --no-check-ssh -output` | 按 tag 盘点（拆机前对账、s3 存量盘点、配额预检的存量项） | s0, s1, s3 |
| `delete -tag env:soak -confirm N` | 按圈定+台数确认删除（数目不符拒执行） | s1 |
| 防火墙规则 API | NMS 自举成功后程序化挂载防火墙并逐条断言（P71：先自举后挂墙） | s2 |
| 多账号配置（accounts.json） | 跨账号分发建机（分布表注入），token 只在内存 | s2, s3 |

配合的三个纪律：

1. **一切删除按 tag 圈定 + 台数确认**：`delete -tag env:soak -confirm N` 的 N 必须等于盘点数，双计数门之下「宁可漏删不可误删」；
2. **出口 IP 断言（check_egress）**：任何云 API 调用前先核对本机出口 IP 与白名单一致（防代理/网络漂移导致误判或误操作），不符退出码 42；
3. **配额预检**：建机前用云 API 查账号限额，计划数超限直接 ABORT（而不是建到一半失败留半残 fleet）。

---

## 快速上手

```bash
# 0. 前提：一台 fleet 之外的编排机；可用的 vpsctl（或等价云 CLI）+ accounts 配置；
#    一套 NMS server/agent 构建产物；SSH 能通 NMS。

# 1. 建运行时目录并注入配置（机密永不入库）
mkdir -p ~/nms-rebuild-run && cp env.local.example ~/nms-rebuild-run/env.local
$EDITOR ~/nms-rebuild-run/env.local        # 填节点密码/出口白名单/账号分布表等
export SOAK_ENV=~/nms-rebuild-run

# 2. 自检（零网络）
churn/tests/fixture-check.sh               # 假树断言 + 全脚本语法 + DRY_RUN

# 3. 干跑编排链（不碰任何真实资源，验证注入与门）
DRY_RUN=1 bash rebuild/s3-nodes.sh

# 4. 真跑：全删重建冷启动验证
EXPECT_HEAD=<你的 NMS main 提交> bash rebuild/run-benchmark.sh

# 5. 韧性波（对运行中的 fleet 做增删扰动）
bash churn/run-r-wave.sh                   # 或 SCENARIOS="r1 r3" 跑子集
```

## 运行时注入（env.local）

机密与部署事实**全部**经 `$SOAK_ENV/env.local` 注入，仓库内容零凭据、零账号名、零真实 IP（占位符一律 `<...>` 形式）。完整清单见 [`env.local.example`](env.local.example)，要点：

| 变量 | 说明 |
|---|---|
| `NODE_PASS` | 测试节点统一 root 密码（导入载荷/复活载荷） |
| `AUTHORIZED_KEY` | 注入节点 `/root/.ssh/authorized_keys` 的公钥（整行文本） |
| `EGRES_EXPECT` | 出口白名单 IPv4（P68/P71 护栏） |
| `SOAK_BATCHES` | 区域/账号/台数/机型分布表（多行，账号列注入） |
| `NMS_ACCOUNT` / `FW_SOAK_NMS_ID` / `OLD_NMS_IP` | NMS 所在账号 / 防火墙 ID / 基线目标 |
| `GUARD_ACCOUNT`(+`_EXPECT`) | 可选：S1 保护账号断言（不设则跳过，误伤无检测） |

## 关键设计决策（为什么是现在这个形状）

- **先自举后挂防火墙**：建机瞬间挂安全组会卡死云侧自举——自举成功后程序化挂墙并逐条断言；
- **自举用标记协议**：等 `BOOTSTRAP-OK` 标记而不是猜时间（失败有 fast-path，静默失败是大坑）；
- **断言不依赖异步时序**：收敛看终态与轮询，不 sleep 赌运气；
- **删除类操作永不裸奔**：tag 圈定 + 台数双计数 + 删后清零复核；
- **ASCII-only user-data**：云厂商链路可能对非 ASCII 二次编码毁掉自举脚本（血泪教训），模板内禁非 ASCII；
- **每步留证据**：所有断言的输入输出落盘，报告里的每个数字都能回放。

## 边界声明

- nmsctl 是**测试器**，不是 NMS 产品的组成部分，也不做云资源的长生命周期管理；
- 不做「出生即网络死」的自动重建状态机（当前人工/脚本外处置）；不做节点压测流量注入；
- 云厂商层是示例实现（DigitalOcean + vpsctl），平移到其他厂商 = 替换 `vpsctl` 调用层与 user-data 模板，编排逻辑不变。
