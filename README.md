# nexum-ts

nexum 任务编排系统的 TypeScript 实现。通过 Contract YAML 定义任务边界，
由 AI 编排者协调多个 agent 完成编码任务、自动评估、重试与下游解锁。

## 与 OpenNexum bash 版的区别

| 特性 | bash 版 | nexum-ts |
|------|---------|----------|
| 语言 | bash | TypeScript |
| 类型安全 | 无 | 完整 TypeScript 类型 |
| 包结构 | 单文件脚本 | pnpm monorepo（core/cli/spawn/prompts/notify） |
| 错误码 | 无统一规范 | `NexumError` + `ErrorCode` 枚举 |
| 并发安全 | 无锁机制 | 文件锁 + atomic write (tmpfile rename) |
| 配置 | 硬编码 | `nexum/config.json` 可配置 agent 映射 |
| 通知 | 无 | Telegram Bot API 集成 |
| 测试 | 无 | vitest 单元测试 |

---

## 安装

```bash
# 安装依赖
pnpm install

# 构建所有包
pnpm build

# 运行测试
pnpm test
```

**前置依赖：** Node.js ≥ 20，pnpm，openclaw（ACP session 调度器）

---

## 环境变量

| 变量 | 必填 | 说明 |
|------|------|------|
| `TELEGRAM_BOT_TOKEN` | 否 | Telegram Bot Token，与 `TELEGRAM_CHAT_ID` 同时设置时启用通知 |
| `TELEGRAM_CHAT_ID` | 否 | 接收通知的 Telegram Chat ID |

也可在 `nexum/config.json` 的 `notify.target` 中配置 Chat ID（优先级低于环境变量）。

---

## 工作流程

```
nexum init
    │
    ▼
[编写 Contract YAML]  →  docs/nexum/contracts/<ID>.yaml
    │
    ▼
nexum spawn <taskId>          # 生成 generator SpawnPayload
    │
    ▼ (编排者调用 openclaw sessions spawn)
[openclaw sessions spawn ...]  →  返回 sessionKey
    │
    ▼
[heartbeat 轮询 ACP session 状态]
    │
    ▼
nexum eval <taskId>           # 生成 evaluator SpawnPayload
    │
    ▼ (编排者调用 openclaw sessions spawn)
[evaluator agent 写入 eval result YAML]
    │
    ▼
nexum complete <taskId> <verdict>
    ├── pass       →  TaskStatus=Done，解锁下游任务
    ├── fail       →  iteration++，返回 retry SpawnPayload（回到 spawn 步骤）
    └── escalated  →  TaskStatus=Failed，人工介入
```

---

## Contract YAML 示例

```yaml
id: NX2-001
name: "完善 Task 类型定义 + core 类型修复"
type: coding
created_at: "2026-03-29T09:00:00Z"

scope:
  files:
    - packages/core/src/types.ts
    - packages/core/src/tasks.ts
    - packages/core/src/__tests__/tasks.test.ts
  boundaries:
    - packages/spawn/
    - packages/prompts/
  conflicts_with: []

deliverables:
  - "Task interface 补充 acp_session_key、acp_stream_log 等可选字段"
  - "pnpm build 和 pnpm test 均通过"

eval_strategy:
  type: unit
  criteria:
    - id: C1
      desc: "Task interface 包含所有新字段，均为可选类型"
      method: "review: 检查 types.ts 的 Task interface"
      threshold: pass
    - id: C2
      desc: "pnpm build && pnpm test 通过"
      method: "unit: 运行构建和测试"
      threshold: pass

generator: cc-frontend
evaluator: eval
max_iterations: 3
depends_on: []
```

完整字段说明见 [`references/contract-schema.md`](references/contract-schema.md)。

---

## 命令参考

### `nexum init`

初始化 nexum 目录结构，生成 `nexum/active-tasks.json`、`nexum/config.json`、
`docs/nexum/contracts/.gitkeep`。

```bash
nexum init [--project-dir <path>]
```

### `nexum spawn <taskId>`

为指定任务准备 generator prompt，输出 JSON `SpawnPayload`。
同时将任务状态更新为 `running`，记录 `base_commit`。

```bash
nexum spawn NX2-001 [--project-dir <path>]
```

**输出（stdout JSON）：**
```json
{
  "taskId": "NX2-001",
  "taskName": "完善 Task 类型定义",
  "agentId": "cc-frontend",
  "agentCli": "claude",
  "promptFile": "/path/to/nexum/runtime/prompts/NX2-001-gen-0.md",
  "promptContent": "...",
  "label": "NX2-001-gen-iter0",
  "cwd": "/path/to/project"
}
```

### `nexum eval <taskId>`

为指定任务准备 evaluator prompt，输出 JSON `SpawnPayload`。
同时将任务状态更新为 `evaluating`，记录 `eval_result_path`。

```bash
nexum eval NX2-001 [--project-dir <path>]
```

### `nexum complete <taskId> <verdict>`

处理评估结果，推进任务状态。`verdict` 为 `pass`、`fail` 或 `escalated`。

```bash
nexum complete NX2-001 pass [--project-dir <path>]
```

**输出（stdout JSON）：**
```json
// pass
{ "action": "done", "taskId": "NX2-001", "unlockedTasks": ["NX2-003"] }

// fail（未超过 max_iterations）
{ "action": "retry", "taskId": "NX2-001", "retryPayload": { /* SpawnPayload */ } }

// escalated 或超过 max_iterations
{ "action": "escalated", "taskId": "NX2-001" }
```

### `nexum status`

显示所有任务的当前状态。

```bash
nexum status [--json] [--project-dir <path>]
```

`--json` 输出机器可读的 JSON 数组：
```json
[
  {
    "id": "NX2-001",
    "name": "完善 Task 类型定义",
    "status": "done",
    "iteration": 0,
    "acp_session_key": "session-abc123",
    "acp_stream_log": "/path/to/stream.jsonl"
  }
]
```

### `nexum track <taskId>`

追踪运行中任务的实时 ACP session 日志。

```bash
nexum track NX2-001 [--project-dir <path>]
```

---

## 项目结构

```
packages/
  core/       # 类型定义、Contract 解析、任务状态管理、配置
  cli/        # CLI 命令入口（init/spawn/eval/complete/status/track）
  spawn/      # ACP session 调度（封装 openclaw CLI）
  prompts/    # Prompt 渲染（generator/evaluator/retry）
  notify/     # Telegram 通知
docs/
  nexum/contracts/   # Contract YAML 文件
  design/            # 设计文档
  lessons/           # 踩坑记录
nexum/
  active-tasks.json  # 任务状态（运行时数据）
  config.json        # Agent 映射与通知配置
  runtime/           # 生成的 prompt 文件和 eval 结果
```

---

## 参考文档

- [Contract Schema](references/contract-schema.md) — Contract YAML 完整字段说明
- [Orchestrator Guide](references/orchestrator-guide.md) — AI 编排者工作流程
