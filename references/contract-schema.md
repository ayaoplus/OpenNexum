# Contract YAML Schema

Contract 是 nexum 任务系统的核心数据结构，定义了一个 AI agent 任务的边界、
交付物和评估策略。文件存放在 `docs/nexum/contracts/<ID>.yaml`。

对应 TypeScript 类型：`packages/core/src/types.ts` → `Contract` interface。

---

## 顶层字段

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `id` | `string` | ✓ | 任务唯一标识符，如 `NX2-001` |
| `name` | `string` | ✓ | 人类可读的任务名称 |
| `type` | `"coding" \| "task" \| "creative"` | ✓ | 任务类型 |
| `created_at` | `string` (ISO 8601) | ✓ | 创建时间，如 `"2026-03-29T09:00:00Z"` |
| `scope` | `ContractScope` | ✓ | 文件范围与边界约束（见下） |
| `deliverables` | `string[]` | ✓ | 交付物列表，每条为一句话描述 |
| `eval_strategy` | `ContractEvalStrategy` | ✓ | 评估策略（见下） |
| `generator` | `string` | ✓ | 生成 agent 的 ID，对应 `nexum/config.json` 的 `agents` 键 |
| `evaluator` | `string` | ✓ | 评估 agent 的 ID，同上 |
| `max_iterations` | `number` | ✓ | 最大重试次数，超过后任务标记 Failed |
| `depends_on` | `string[]` | ✓ | 前置任务 ID 列表，为空时写 `[]` |

---

## `scope` 字段

```yaml
scope:
  files:
    - packages/core/src/types.ts    # generator 被允许修改的文件
  boundaries:
    - packages/spawn/               # 禁止修改的目录/文件（只读边界）
    - packages/prompts/
  conflicts_with:
    - NX2-003                       # 与本任务存在文件冲突的其他任务 ID
```

| 子字段 | 类型 | 说明 |
|--------|------|------|
| `files` | `string[]` | generator 的工作文件范围，prompt 中会列出这些路径 |
| `boundaries` | `string[]` | 明确禁止修改的路径（用于 prompt 中的约束说明） |
| `conflicts_with` | `string[]` | 与本任务存在并发冲突的任务 ID，编排者应避免同时运行 |

---

## `eval_strategy` 字段

```yaml
eval_strategy:
  type: unit
  criteria:
    - id: C1
      desc: "Task interface 包含所有新字段"
      method: "review: 检查 types.ts 的 Task interface"
      threshold: pass
    - id: C2
      desc: "pnpm build && pnpm test 通过"
      method: "unit: 运行构建和测试"
      threshold: pass
```

### `eval_strategy.type`

| 值 | 说明 |
|----|------|
| `unit` | 单元测试 / 构建验证 |
| `integration` | 集成测试 |
| `review` | 代码审查（evaluator agent 阅读代码判断） |

### `criteria` 数组（`ContractCriterion`）

| 子字段 | 类型 | 说明 |
|--------|------|------|
| `id` | `string` | 标准唯一 ID，如 `C1`、`C2` |
| `desc` | `string` | 验收标准的人类可读描述 |
| `method` | `string` | 检验方法，格式为 `"<type>: <说明>"`，`type` 可为 `review`、`unit`、`integration` |
| `threshold` | `string` | 通过阈值，目前固定为 `pass` |

---

## `generator` / `evaluator` agent ID

对应 `nexum/config.json` 中 `agents` 对象的键名。系统通过 `resolveAgentCli(config, agentId)`
将其映射为具体的 CLI 类型（`"claude"` 或 `"codex"`）。

**内置 agent ID 示例：**

| ID | CLI | 用途 |
|----|-----|------|
| `cc-frontend` | claude | 前端/TypeScript 编码 |
| `cc-writer` | claude | 文档撰写 |
| `eval` | codex | 代码评估（高推理模式） |
| `codex-frontend` | codex | 前端编码（codex） |
| `plan` | claude | 规划任务 |
| `gardener` | claude | 维护任务 |

未在 `config.json` 中配置的 agent ID 默认使用 `"codex"` CLI。

---

## 完整示例

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
    - packages/notify/
    - packages/cli/
  conflicts_with: []

deliverables:
  - "Task interface 补充以下字段（均可选）：acp_session_key、acp_stream_log、started_at、completed_at、eval_result_path、base_commit、last_error"
  - "TaskStatus 枚举补充 Evaluating = 'evaluating' 和 Cancelled = 'cancelled'"
  - "pnpm build 和 pnpm test 均通过，无 TypeScript 编译错误"

eval_strategy:
  type: unit
  criteria:
    - id: C1
      desc: "Task interface 包含所有新字段，均为可选类型"
      method: "review: 检查 types.ts 的 Task interface"
      threshold: pass
    - id: C2
      desc: "TaskStatus 包含 Evaluating 和 Cancelled"
      method: "review: 检查 TaskStatus 枚举"
      threshold: pass
    - id: C3
      desc: "pnpm build && pnpm test 通过"
      method: "unit: 运行构建和测试"
      threshold: pass

generator: cc-frontend
evaluator: eval
max_iterations: 3
depends_on: []
```

---

## 运行时任务状态（Task）

Contract 被加载后，编排者在 `nexum/active-tasks.json` 中维护对应的 `Task` 记录：

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | `string` | 与 Contract `id` 相同 |
| `name` | `string` | 与 Contract `name` 相同 |
| `status` | `TaskStatus` | 当前状态（见下） |
| `contract_path` | `string` | Contract YAML 文件的相对路径 |
| `depends_on` | `string[]` | 同 Contract |
| `iteration` | `number?` | 当前重试次数，从 0 开始 |
| `acp_session_key` | `string?` | openclaw 分配的 session key |
| `acp_stream_log` | `string?` | ACP stream log 文件路径（JSONL） |
| `eval_result_path` | `string?` | evaluator 写入结果的 YAML 路径 |
| `base_commit` | `string?` | spawn 时的 git HEAD |
| `head_commit` | `string?` | 完成时的 git HEAD |
| `last_error` | `string?` | 失败时的错误信息 |
| `started_at` | `string?` | 首次 spawn 的 ISO 时间戳 |
| `completed_at` | `string?` | 完成时的 ISO 时间戳 |
| `updated_at` | `string?` | 最后更新时间戳 |

### TaskStatus 枚举

| 值 | 说明 |
|----|------|
| `pending` | 等待调度（所有依赖已满足） |
| `blocked` | 有未完成的前置任务 |
| `running` | generator agent 正在运行 |
| `evaluating` | evaluator agent 正在评估 |
| `done` | 任务完成 |
| `failed` | 超过最大重试次数或被标记失败 |
| `cancelled` | 已取消 |
