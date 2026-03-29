---
name: opennexum-ts
version: 0.1.0
description: >
  TypeScript 实现的 nexum 编排器工具集。提供 init/spawn/eval/complete/status/track
  命令，通过 ACP (Agent Coordination Protocol) 驱动多 AI agent 协作完成编码任务。
requires:
  - node>=20
  - pnpm
  - openclaw
---

# opennexum-ts

nexum-ts 是 nexum 任务编排系统的 TypeScript 实现，取代原始 bash 版本。
通过 Contract YAML 定义任务边界，由 AI 编排者（orchestrator）调用各命令驱动
generator agent 编写代码、evaluator agent 审核结果、自动处理重试与下游解锁。

## 触发场景

当以下情况发生时，使用此 skill：

- 需要在项目中初始化 nexum 任务系统（`nexum init`）
- 需要为某个 Contract 派发 generator agent（`nexum spawn`）
- 需要为某个 Contract 派发 evaluator agent（`nexum eval`）
- 需要处理评估结果、推进任务状态（`nexum complete`）
- 需要查看当前所有任务状态（`nexum status`）
- 需要追踪运行中 ACP session 的实时日志（`nexum track`）

## Quick Start

```bash
# 1. 安装依赖并构建
pnpm install
pnpm build

# 2. 初始化 nexum 目录结构
nexum init

# 3. 编写 Contract（见 docs/nexum/contracts/）
# 4. 将任务写入 nexum/active-tasks.json

# 5. 编排者派发 generator
SPAWN_PAYLOAD=$(nexum spawn NX2-001)
# → 输出 JSON SpawnPayload，编排者用其调用 openclaw sessions spawn

# 6. 轮询 heartbeat，等待 agent 完成

# 7. 编排者派发 evaluator
EVAL_PAYLOAD=$(nexum eval NX2-001)

# 8. 处理评估结果
nexum complete NX2-001 pass
# → pass：任务 Done，解锁下游任务
# → fail：自动生成 retry prompt，返回新 SpawnPayload
# → escalated：任务标记 Failed，人工介入
```

## 安装说明

### 前置条件

| 依赖 | 版本 | 说明 |
|------|------|------|
| Node.js | ≥ 20 | 运行时 |
| pnpm | ≥ 9 | 包管理器 |
| openclaw | 最新 | ACP session 调度器，需在 PATH 中 |

### 安装步骤

```bash
# 克隆仓库
git clone <repo-url>
cd nexum-ts

# 安装依赖
pnpm install

# 构建所有包
pnpm build

# （可选）全局链接 CLI
pnpm link --global
# 或直接使用：node packages/cli/dist/index.js
```

### 环境变量（可选）

```bash
# Telegram 通知（两者均设置时启用）
export TELEGRAM_BOT_TOKEN=<your-bot-token>
export TELEGRAM_CHAT_ID=<your-chat-id>
```

也可通过 `nexum/config.json` 的 `notify.target` 配置 chat ID。

## 配置文件

`nexum init` 生成 `nexum/config.json`，包含 agent 映射：

```json
{
  "notify": {
    "verbose_dispatch": true,
    "target": "<TELEGRAM_CHAT_ID>"
  },
  "agents": {
    "cc-frontend": { "cli": "claude", "model": "claude-sonnet-4-6" },
    "eval": { "cli": "codex", "model": "gpt-5.4", "reasoning": "high" }
  }
}
```

## 参考文档

- Contract 字段说明 → `references/contract-schema.md`
- 编排者工作流 → `references/orchestrator-guide.md`
- 架构说明 → `ARCHITECTURE.md`
