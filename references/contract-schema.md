# Contract YAML Schema

参考：设计文档 §3.1、需求文档 §5.1/§5.2。

## 顶层字段

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `id` | string | 是 | Task ID。建议格式：`[A-Z]+-[0-9]+`，如 `TASK-001`、`WRITE-001`。 |
| `name` | string | 是 | 任务名称，面向人类可读。 |
| `type` | enum | 是 | 任务类型。枚举：`coding` \| `task` \| `creative`。 |
| `created_at` | string | 是 | Contract 创建时间，使用 ISO 8601 UTC 时间戳。 |
| `scope` | object | 是 | 文件范围、禁止边界、串行冲突声明。详见下节。 |
| `deliverables` | string[] | 是 | 交付物清单。每项都应能被 evaluator 逐条核验。 |
| `eval_strategy` | object | 是 | 验证策略定义。详见下节。 |
| `generator` | string | 是 | 执行 agent 标识，如 `codex-1`、`cc-writer`。 |
| `evaluator` | string | 是 | 评估 agent 标识，通常为 `eval`。 |
| `max_iterations` | integer | 是 | 最大反馈循环次数。超过后应升级为人工处理。 |
| `depends_on` | string[] | 是 | 上游依赖 task id 列表；未满足前通常保持 `blocked`。 |

## `scope`

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `scope.files` | string[] | 是 | 允许修改的文件列表。generator 的提交范围必须受此约束。 |
| `scope.boundaries` | string[] | 是 | 明确禁止修改的范围、组件、模块或系统边界。 |
| `scope.conflicts_with` | string[] | 是 | 与哪些 task id 存在语义冲突，需串行执行。无冲突时填空数组。 |

## `eval_strategy`

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `eval_strategy.type` | enum | 是 | 验证策略类型。枚举：`unit` \| `integration` \| `e2e` \| `review` \| `composite`。 |
| `eval_strategy.tools` | string[] | 否 | 该策略依赖的工具，如 `playwright`、测试命令或其他执行器。 |
| `eval_strategy.local_url` | string | 条件必填 | 本地应用地址。`type: e2e` 时必须提供。 |
| `eval_strategy.evaluator_model` | string | 否 | 覆盖默认 evaluator 模型的可选字段，常用于创作/主观评审。 |
| `eval_strategy.criteria` | object[] | 是 | 逐条验证标准列表。为空通常表示 Contract 设计不完整。 |
| `eval_strategy.sub_strategies` | object[] | 条件必填 | 仅 `type: composite` 时使用，定义子策略序列。 |

### `eval_strategy.sub_strategies[]`

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `type` | enum | 是 | 子策略类型。枚举同 `eval_strategy.type`，但通常不再嵌套 `composite`。 |

## `eval_strategy.criteria[]`

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `id` | string | 是 | criterion 唯一标识，如 `C1`。 |
| `desc` | string | 是 | 需要被验证的结果描述。 |
| `method` | string | 是 | evaluator 的验证方法说明，如 `review: checklist`、`playwright: check URL after submit`。 |
| `threshold` | enum | 是 | 通过门槛。枚举：`pass` \| `score`。 |
| `min_score` | number | 否 | 仅当 `threshold: score` 时有意义，表示最低通过分。 |

## 枚举约束

### Contract `type`

- `coding`
- `task`
- `creative`

### Runtime `status`

说明：`status` 不属于静态 Contract 文件，而是运行态字段，存储在 `active-tasks.json`。

- `pending`
- `blocked`
- `running`
- `evaluating`
- `done`
- `failed`
- `escalated`
- `cancelled`

### `eval_strategy.type`

- `unit`
- `integration`
- `e2e`
- `review`
- `composite`

### `criteria[].threshold`

- `pass`
- `score`

## 条件规则

- `eval_strategy.type: e2e` 时，`eval_strategy.local_url` 为必填。
- `criteria[].min_score` 仅在 `criteria[].threshold: score` 时有意义；`threshold: pass` 时应省略或设为 `null`。
- `scope.files`、`scope.boundaries`、`scope.conflicts_with`、`deliverables`、`depends_on` 即使为空，也应使用显式数组，避免省略后产生歧义。
- Contract 创建后保持静态；`status`、`iteration`、`commit_hash`、`eval_result_path` 等运行态信息不应写回 Contract。
