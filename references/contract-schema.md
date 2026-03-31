# Contract Schema Reference

本文档描述 OpenNexum TS 使用的 Contract YAML 字段。说明以 `packages/core/src/types.ts` 的 `Contract` 接口和 `packages/core/src/contract.ts` 的归一化/校验逻辑为准。

## Overview

Contract 是任务的单一事实来源。CLI 会根据它决定：

- 任务名称和类型
- 可修改文件范围
- 交付物清单
- 评估策略与判定标准
- generator / evaluator 的 agent 选择
- 最大重试次数
- 依赖关系

## Required Fields

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `id` | string | Yes | Unique task ID, such as `NX2-005` |
| `name` | string | Yes | Human-readable task name |
| `type` | `coding | task | creative` | No | Contract category. Defaults to `coding` |
| `created_at` | string | No | ISO timestamp metadata |
| `scope` | object | Yes | File scope, boundaries, and conflict declarations |
| `deliverables` | deliverable[] | Yes | Expected outputs of the task |
| `eval_strategy` | object | Yes | Evaluation mode and criteria |
| `generator` / `agent.generator` | string | Yes | Agent ID used for implementation |
| `evaluator` / `agent.evaluator` | string | Yes | Agent ID used for review/evaluation |
| `max_iterations` | number | Yes | Maximum retry count before final failure |
| `depends_on` | string[] | No | Upstream task IDs that must be done first. Defaults to `[]` |

## Field Details

### `id`

任务唯一标识。建议使用稳定、可排序的编号，例如 `NX-001` 或 `NX2-005`。该字段同时会被用于：

- `nexum spawn <taskId>`
- `nexum eval <taskId>`
- `nexum complete <taskId> <verdict>`
- prompt 文件命名
- retry commit message 命名

### `name`

任务可读名称。CLI 会在 prompt、状态输出、通知消息中使用它。应避免过长，但要足够具体。

### `type`

允许值：

- `coding`
- `task`
- `creative`

当前实现中，`type` 主要作为分类元数据；并不会自动切换不同执行器逻辑，但评估器和编排者可以基于它做路由。

### `scope`

`scope` 是一个对象，包含以下子字段：

| Subfield | Type | Required | Description |
| --- | --- | --- | --- |
| `files` | string[] | Yes | Files expected to be changed or delivered |
| `boundaries` | string[] | No | Paths that must stay out of scope. Defaults to `[]` |
| `conflicts_with` | string[] | No | Task IDs that conflict with this task. Defaults to `[]` |

#### `scope.files`

列出本任务应直接涉及的文件路径。`nexum spawn` 会把它们拼入建议的 `git add -- ...` 命令中，因此这里应尽量精确。

#### `scope.boundaries`

列出禁止扩散修改的目录、模块或区域。这个字段是给 agent 和 reviewer 的边界提醒，帮助降低无关修改的风险。

#### `scope.conflicts_with`

用于标记互斥任务。当前 CLI 没有自动执行冲突调度，但该字段对上层 orchestrator 很重要，可用于避免同时派发相互覆盖的任务。

### `deliverables`

推荐使用对象数组，每项包含：

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `path` | string | No | Primary file or artifact path |
| `description` | string | Conditionally | Human-readable deliverable description |

运行时也兼容旧的字符串数组格式；字符串会被归一化为 `{ description: "<string>" }`。

### `eval_strategy`

`eval_strategy` 是一个对象，包含：

| Subfield | Type | Required | Description |
| --- | --- | --- | --- |
| `type` | `unit | integration | review` | Yes | Evaluation strategy category |
| `criteria` | array | Yes | Criteria list used by the evaluator |

#### `eval_strategy.type`

允许值：

- `unit`
- `integration`
- `review`
- `e2e`
- `composite`

当前仓库里，文档任务通常使用 `review`。即便选择 `unit` 或 `integration`，是否真的执行自动化测试仍取决于 evaluator prompt 和外部 orchestrator。

#### `eval_strategy.criteria`

criteria 为对象数组，每项包含：

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `id` | string | Yes | Criterion ID such as `C1` |
| `desc` | string | Yes | What the evaluator should verify |
| `method` | string | No | How to verify it |
| `threshold` | string | No | Passing threshold, often `pass` |
| `weight` | number | No | Relative importance / scoring weight |

`nexum complete` 在失败时会尝试从 evaluator 结果文件中提取失败 criteria，并据此构建 retry prompt。

### `generator` / `evaluator`

运行时支持两种写法：

- 顶层字段：`generator` / `evaluator`
- 嵌套字段：`agent.generator` / `agent.evaluator`

解析时会优先使用嵌套写法，再回退到顶层字段，并归一化为运行时的 `contract.generator` / `contract.evaluator`。

### `max_iterations`

数字。表示 evaluator 返回 `fail` 后，最多允许重试多少轮。`nexum complete` 的行为如下：

- `fail` 且当前 `iteration < max_iterations`：返回 retry payload
- `fail` 且已达到上限：任务进入 `failed`
- `escalated`：直接进入 `failed`，并标记需要人工介入

### `depends_on`

字符串数组，表示当前任务依赖的上游任务 ID。任务完成后，`nexum complete` 会尝试解锁依赖它的下游任务；只有当所有依赖都已经 `done` 时，下游任务才会从 `blocked` 转为 `pending`。

## Example

```yaml
id: NX2-005
name: "SKILL.md + README + Contract Schema 文档"
type: coding
created_at: "2026-03-29T09:00:00Z"

scope:
  files:
    - SKILL.md
    - README.md
    - references/contract-schema.md
    - references/orchestrator-guide.md
  boundaries:
    - packages/
    - nexum/
  conflicts_with: []

deliverables:
  - "ClawHub-compatible skill description"
  - "Bilingual README"
  - "Contract schema reference"
  - "Orchestrator workflow reference"

eval_strategy:
  type: review
  criteria:
    - id: C1
      desc: "Docs are complete"
      method: "review"
      threshold: pass

generator: codex
evaluator: claude
max_iterations: 3
depends_on:
  - NX2-003
  - NX2-004
```

## Authoring Notes

- Keep `scope.files` narrow and explicit.
- Prefer including `created_at`, even though runtime no longer requires it.
- Write `deliverables` and criteria so an evaluator can judge them without guessing.
- Use stable `generator` / `evaluator` IDs that exist in `nexum/config.json`.
- Treat `depends_on` as scheduling truth whenever dependencies exist.
