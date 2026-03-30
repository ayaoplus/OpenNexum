# OpenNexum

Contract-driven multi-agent orchestration for AI coding workflows.

OpenNexum 通过 Contract YAML 定义任务边界，自动编排 generator（写代码）和 evaluator（审代码）的执行、重试、升级全流程。基于 OpenClaw ACP 协议，支持 Claude Code 和 Codex 并行执行。

## 核心特性

- **Contract-first**：每个任务有明确的 scope / deliverables / criteria
- **Cross-review**：Codex 写的由 Claude 审，Claude 写的由 Codex 审
- **事件驱动编排**：callback 触发 eval → retry → unlock → next-task，全自动
- **自动路由**：`generator: auto` 按任务类型自动选择最优 Agent
- **并行执行**：独立 ACP session，多任务同时运行
- **Escalation**：超过重试上限或 feedback 重复时自动升级，通知人工介入
- **Telegram 通知**：通过 OpenClaw 统一推送，覆盖 8 种通知类型
- **Watch 守护进程**：卡死检测，macOS launchctl / Linux systemd

## 安装

```bash
# 前置要求：Node.js >=20, pnpm, openclaw, acpx
git clone https://github.com/ayaoplus/OpenNexum.git
cd OpenNexum
pnpm install && pnpm build
```

## 快速开始

```bash
# 1. 初始化项目（交互式向导）
nexum init --project /path/to/your/project

# 2. 创建 Contract YAML
# docs/nexum/contracts/TASK-001.yaml

# 3. 注册任务到 active-tasks.json

# 4. 启动任务
nexum spawn TASK-001 --project /path/to/project
# 输出 spawn payload → 调 spawnAcpSession 或手动 acpx

# 5. 后续自动流转
# generator 完成 → nexum callback → 自动 eval → 自动 complete → 自动下一个
```

## CLI 命令

| 命令 | 功能 |
|------|------|
| `nexum init` | 交互式初始化（CLI 检测、git 配置、通知配置） |
| `nexum spawn <taskId>` | 生成 generator prompt + spawn payload |
| `nexum eval <taskId>` | 生成 evaluator prompt + spawn payload |
| `nexum callback <taskId>` | 处理回调，自动 dispatch 下一步 |
| `nexum complete <taskId> <verdict>` | 处理 eval 结果 |
| `nexum retry <taskId> --force` | 重置 escalated 任务 |
| `nexum status` | 查看任务状态 |
| `nexum health` | 卡死检测 |
| `nexum watch` | 守护进程模式 |
| `nexum archive` | 归档已完成任务 |

## Agent 命名规范

`<model>-<role>-<number>`

- `codex-gen-01` — 后端/API 代码
- `claude-gen-01` — 用户端 WebUI
- `codex-eval-01` — Review Claude 代码
- `claude-eval-01` — Review Codex 代码
- `claude-plan-01` — 架构设计（opus）

## 通知类型

| 通知 | 说明 |
|------|------|
| 🚀 派发任务 | 任务开始执行 |
| 🔨 [1/2] 代码编写完成 | Generator 提交代码 |
| ✅ [2/2] 审查通过 | Evaluator 审查通过 |
| ❌ [2/2] 审查失败 | Evaluator 审查失败，自动重试 |
| 🚨 任务升级 | 超过重试上限，需人工介入 |
| ⚠️ commit 缺失 | Generator 未执行 git commit |
| 🚨 卡死告警 | 任务超时无更新 |
| 🎉 批次完成 | 一批任务全部完成 |

## 文档

- [架构设计](docs/design/ARCHITECTURE.md)
- [Commit 规范](docs/design/COMMIT-CONVENTION.md)
- [v2 重设计记录](docs/design/NEXUM-V2-REDESIGN.md)

## License

MIT
