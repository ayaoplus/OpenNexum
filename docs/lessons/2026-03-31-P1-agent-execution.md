---

## Lesson: 逻辑 agent 和执行 backend 必须分开建模
- trigger: spawn/eval payload 同时要表达“谁负责这项任务的语义归属”和“编排层到底该用哪个 runtime/backend 去启动它”时，只保留 `agentId` 会让 orchestrator 直接把逻辑 agent 当成 runtime 参数
- wrong: 用 `payload.agentId` 同时承载路由身份、通知身份、以及 `sessions_spawn` / tmux dispatcher 的底层 agent 参数
- right: payload 至少要同时暴露 `agentId`（逻辑 agent）和 `runtime` + `runtimeAgentId`（执行目标）；Claude 默认走 `tmux/claude`，不要默认走 ACP
- affected: packages/core/src/config.ts, packages/cli/src/commands/spawn.ts, packages/cli/src/commands/eval.ts, packages/cli/src/commands/complete.ts, references/orchestrator-guide.md
- tags: orchestration, agent-modeling, runtime, acp, tmux, claude, codex
