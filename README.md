# OpenNexum

Contract-driven multi-agent orchestration for AI coding workflows.

OpenNexum 通过 Contract YAML 定义任务边界，自动编排 generator（写代码）和 evaluator（审代码）的执行、重试、升级全流程。基于 OpenClaw ACP 协议，支持 Claude Code 和 Codex 并行执行。

## 核心特性

- **Contract-first**：每个任务有明确的 scope / deliverables / criteria
- **Cross-review**：Codex 写的由 Claude 审，Claude 写的由 Codex 审
- **事件驱动编排**：callback 触发 eval → retry → unlock → next-task，全自动
- **Webhook dispatch**：通过 OpenClaw `/hooks/agent` 实时唤醒编排者，dispatch-queue 兜底
- **Dispatch Queue 兜底**：callback 写 `nexum/dispatch-queue.jsonl`，watch 心跳重放 webhook，避免丢失唤醒信号
- **自动路由**：`generator: auto` 按任务类型自动选择最优 Agent
- **并行执行**：独立 ACP session，多任务同时运行
- **Escalation**：超过重试上限或 feedback 重复时自动升级，通知人工介入
- **Telegram 通知**：通过 OpenClaw 统一推送，覆盖 8 种通知类型
- **Watch 守护进程**：卡死检测，macOS launchctl / Linux systemd
- **Batch 进度**：`nexum status` 按 batch 显示当前批次进度 + 总体进度

## 安装

```bash
# 前置要求：Node.js >=20, pnpm, openclaw
git clone https://github.com/ayaoplus/OpenNexum.git
cd OpenNexum
pnpm install && pnpm build

# 全局安装 nexum CLI
PNPM_HOME=$HOME/Library/pnpm pnpm add -g ./packages/cli
```

## 快速开始

```bash
# 1. 初始化项目（交互式向导）
nexum init --project /path/to/project

# 2. 写 Contract YAML
# docs/nexum/contracts/TASK-001.yaml

# 3. 注册任务到 active-tasks.json，然后生成 spawn payload
nexum spawn TASK-001 --project /path/to/project

# 4. 编排者读取 payload.runtime / payload.runtimeAgentId，
#    按运行时派发（ACP 用 sessions_spawn，tmux 用 PTY/tmux dispatcher），成功后立刻记录 session
nexum track TASK-001 <sessionKey> --project /path/to/project --role generator

# 5. Agent 完成后调用
nexum callback TASK-001 --project /path/to/project \
  --model gpt-5.4 \
  --input-tokens 12345 \
  --output-tokens 2048
# → 自动写 dispatch-queue + 触发 webhook → 编排者执行 nexum eval + 派发 evaluator

# 6. Evaluator 完成后同样调用 nexum callback --role evaluator
# → 自动 complete/retry/escalate
```

## Contract YAML 格式

```yaml
id: TASK-001
name: "implement feature X"
type: coding
created_at: "2026-03-31T00:00:00Z"
batch: batch-1

agent:
  generator: auto
  evaluator: auto

scope:
  files:
    - src/feature.ts
    - src/feature.test.ts
  boundaries: []
  conflicts_with: []

description: "..."

deliverables:
  - path: src/feature.ts
    description: "..."

eval_strategy:
  type: review   # review | unit | integration | e2e | composite
  criteria:
    - id: C1
      desc: "..."
      weight: 2

max_iterations: 3
depends_on: []
```

`deliverables` 支持对象格式（推荐）和旧的字符串数组格式；criteria 至少需要 `id` + `desc`，可选 `method` / `threshold` / `weight`。

## Agent 命名规范

格式：`<model>-<role>-<number>`

| Agent ID | 默认执行 backend | 用途 |
|---|---|
| codex-gen-01~03 | `acp/codex` | 后端/API 代码 |
| claude-gen-01~02 | `tmux/claude` | 前端/文档 |
| codex-eval-01 | `acp/codex` | 审 claude 的代码 |
| claude-eval-01 | `tmux/claude` | 审 codex 的代码 |
| claude-plan-01 | `tmux/claude` | 架构规划（opus）|

## Spawn Payload 约定

`nexum spawn` / `nexum eval` / `retryPayload` 里的关键字段含义如下：

- `agentId`: 逻辑 agent ID，用于路由、通知、评审归属
- `agentCli`: 该逻辑 agent 对应的 CLI 家族（`codex` / `claude`）
- `runtime`: 编排层应使用的执行 runtime（当前为 `acp` 或 `tmux`）
- `runtimeAgentId`: 编排层真正传给 runtime 的 agent/backend ID

对编排层来说，`sessions_spawn` 或其他执行器应使用 `runtime` + `runtimeAgentId`，不要把 `agentId` 直接当成底层 backend。

## Dispatch 架构

```
generator 完成
    ↓
nexum callback → 写 dispatch-queue.jsonl（兜底）
    + POST /hooks/agent → 实时唤醒编排者
    ↓
编排者（小明）收到通知
    → nexum eval → 按 payload.runtime 派发 evaluator → nexum track --role evaluator

evaluator 完成
    ↓
nexum callback --role evaluator → 写 dispatch-queue.jsonl
    + POST /hooks/agent
    ↓
编排者处理 complete/retry/escalate

[兜底] watch 心跳扫描 dispatch-queue.jsonl → 重放 webhook，重新唤醒编排者
```

## CLI 命令

```bash
nexum init [--project <dir>] [--yes]       # 初始化项目
nexum spawn <taskId> [--project <dir>]     # 生成 spawn payload
nexum track <taskId> <sessionKey> [--role evaluator]  # 记录 ACP session
nexum callback <taskId> [--role evaluator] # 任务完成回调
nexum eval <taskId>                        # 生成 evaluator payload
nexum complete <taskId> <pass|fail|escalated>  # 处理 eval 结果
nexum status [--project <dir>]             # 显示任务进度（按 batch）
nexum archive [--project <dir>]            # 归档 done 任务
nexum health [--project <dir>]             # 卡死检测
nexum watch [--interval <min>]             # dispatch heartbeat + health daemon
nexum ls [--project <dir>]                 # 任务列表
nexum retry <taskId> --force               # 重置 escalated 任务
nexum watch install|status|list            # Watch 守护进程管理
```

## OpenClaw Webhook 配置

在 `~/.openclaw/openclaw.json` 中启用：

```json5
{
  "hooks": {
    "enabled": true,
    "token": "your-secret-token"
  }
}
```

在 nexum 项目 `nexum/config.json` 中配置：

```json
{
  "webhook": {
    "gatewayUrl": "http://127.0.0.1:18789",
    "token": "your-secret-token"
  }
}
```

也可通过环境变量：`OPENCLAW_HOOKS_TOKEN=your-secret-token`

## Git 规范

- 直接 push 到 `main`，快速迭代，出问题直接 revert
- Commit message 使用英文 Conventional Commits：`feat(scope): TASK-ID: description`
