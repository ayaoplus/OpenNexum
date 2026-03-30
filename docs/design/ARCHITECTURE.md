# OpenNexum 架构设计文档

> 最后更新：2026-03-30
> 版本：v2（全面重构后）

---

## 一、系统概述

OpenNexum 是一个 **Contract-driven 多 Agent 编排系统**，通过 TypeScript CLI 管理 AI 编码任务的全生命周期。

**核心理念：**
- Contract 先行：每个任务在执行前必须有 YAML 定义（scope / deliverables / criteria）
- Generator ≠ Evaluator：写代码和审代码由不同 Agent 完成（GAN 原则）
- 事件驱动：callback 触发 eval/retry/unlock，不依赖轮询
- Watch 兜底：守护进程只做卡死检测，不做 dispatch

---

## 二、包结构

```
packages/
├── core/          # 基础能力：类型、任务管理、配置、Contract 解析、Git
├── prompts/       # Prompt 模板渲染（generator / evaluator / retry）
├── spawn/         # ACP session 管理（直接调 acpx）
├── notify/        # 通知模板 + 发送（通过 openclaw message send）
└── cli/           # nexum 命令行入口
    ├── commands/  # 各子命令实现
    └── lib/       # 工具库（auto-route / detect / daemon / global-config / archive）
```

---

## 三、任务生命周期

```
pending → running → generator_done → evaluating → done
                                        ↓
                                      fail → running (retry)
                                        ↓
                                    escalated (人工介入)
```

### 状态说明

| 状态 | 含义 | 触发方式 |
|------|------|---------|
| `pending` | 等待执行，依赖已满足 | 任务注册 或 依赖解锁 |
| `blocked` | 等待依赖完成 | 任务注册时有 depends_on |
| `running` | Generator 正在执行 | `nexum spawn` |
| `generator_done` | 代码编写完成，等待审查 | `nexum callback --role generator` |
| `evaluating` | Evaluator 正在审查 | `nexum eval` |
| `done` | 审查通过，任务完成 | `nexum complete pass` |
| `failed` | 任务失败 | 异常 |
| `escalated` | 超过重试上限，需人工介入 | `nexum complete` 检测到 |
| `cancelled` | 手动取消 | `nexum cancel` |

---

## 四、编排流程（事件驱动）

```
1. 编排者写 Contract YAML → 注册到 active-tasks.json
2. nexum spawn <taskId> → 生成 prompt → 状态: running
3. spawnAcpSession → acpx <cli> -s <session> exec -f <prompt> --no-wait
4. Generator 完成 → git commit + push → nexum callback --role generator
   ↓ callback 自动执行:
   a. 状态 → generator_done
   b. 发通知 [1/2] 代码编写完成
   c. 自动 spawn evaluator (acpx claude -s claude-eval-<taskId>)

5. Evaluator 完成 → 写 eval YAML → nexum callback --role evaluator
   ↓ callback 自动执行:
   a. 读 eval YAML → 判断 verdict
   b. verdict=pass → complete → 状态: done → 发通知 [2/2] 审查通过
      → 解锁下游任务 → 自动 spawn 下一个 pending generator
   c. verdict=fail → complete → retry → 发通知 审查失败
      → 自动 spawn retry generator
   d. iteration >= max → escalated → 发通知 任务升级 → 停止

6. Watch 守护进程（兜底）:
   - 每 5 分钟检查所有项目
   - 发现 30 分钟无更新的 running/evaluating 任务 → 发卡死告警
   - 不做 dispatch（dispatch 由 callback 事件驱动）
```

---

## 五、Agent 命名规范

格式：`<model>-<role>-<number>`

| Agent ID | CLI | 模型 | 用途 |
|----------|-----|------|------|
| codex-gen-01~03 | codex | gpt-5.4 (high) | 后端/API/逻辑代码 |
| codex-frontend-01 | codex | gpt-5.4 (medium) | Admin/非用户端页面 |
| codex-eval-01 | codex | gpt-5.4 (high) | Code review（review Claude 代码）|
| codex-e2e-01 | codex | gpt-5.4 (medium) | E2E 测试 |
| claude-gen-01~02 | claude | sonnet-4-6 | 用户端 WebUI |
| claude-eval-01 | claude | sonnet-4-6 | Code review（review Codex 代码）|
| claude-plan-01 | claude | opus-4-6 | 架构/计划 |
| claude-write-01 | claude | sonnet-4-6 | 文档/creative |

**Cross-review 原则：** Codex 写 → Claude review；Claude 写 → Codex review

**自动路由：** Contract 里写 `generator: auto` / `evaluator: auto` 时，`auto-route.ts` 按任务名关键词自动选择。

---

## 六、ACP Session 管理

### spawn 方式
```bash
acpx --approve-all --ttl 0 <cli> -s <agentId> -f <prompt> --no-wait
```

- `--ttl 0`：防止 idle timeout 杀死 session
- `-s <agentId>`：命名 session，实现并行隔离
- `--no-wait`：异步执行，不阻塞调用方
- `--approve-all`：自动批准所有文件操作

### session 命名
- Generator: `codex-gen-01` / `claude-gen-01`（复用 agent ID）
- Evaluator: `claude-eval-<taskId>`（每个任务独立 session）
- Retry generator: 复用原 agent session

---

## 七、通知系统

### 通知类型（8 种）

| # | 类型 | 模板函数 | 触发点 |
|---|------|---------|--------|
| ① | 🚀 派发任务 | `formatDispatch` | track.ts / auto-dispatch |
| ② | 🔨 [1/2] 代码编写完成 | `formatGeneratorDone` | callback --role generator |
| ③ | ✅ [2/2] 审查通过 | `formatReviewPassed` | callback --role evaluator (pass) |
| ④ | ❌ [2/2] 审查失败 | `formatReviewFailed` | callback --role evaluator (fail) |
| ⑤ | 🚨 任务升级 | `formatEscalation` | callback --role evaluator (escalated) |
| ⑥ | ⚠️ commit 缺失 | `formatCommitMissing` | callback --role generator |
| ⑦ | 🚨 卡死告警 | `formatHealthAlert` | watch 守护进程 |
| ⑧ | 🎉 批次完成 | `formatBatchDone` | 最后一个任务 done 时 |

### 通知通道
通过 `openclaw message send` 发送，不直接调 Telegram API。OpenClaw 负责路由到 Telegram/Discord/飞书等。

### 模型名显示规则
1. Generator 自报的模型名如果是标准名（如 claude-sonnet-4-6）→ 直接使用
2. 非标准名（如 codex / gpt-5）→ 从 config.agents 映射
3. 都没有 → 从 agentId 前缀推断

---

## 八、配置体系

### 项目级配置 `nexum/config.json`

```json
{
  "project": { "name": "MyProject", "stack": "TypeScript, Node.js" },
  "git": { "remote": "origin", "branch": "main" },
  "notify": { "target": "8449051145" },
  "watch": { "enabled": false, "intervalMin": 5, "timeoutMin": 30 },
  "agents": {
    "codex-gen-01": { "cli": "codex", "model": "gpt-5.4", "reasoning": "high" },
    "claude-gen-01": { "cli": "claude", "model": "claude-sonnet-4-6" },
    ...
  },
  "routing": {
    "rules": [
      { "match": "webui|frontend", "generator": "claude-gen-01", "evaluator": "codex-eval-01" }
    ]
  }
}
```

### 全局配置 `~/.nexum/config.json`

```json
{
  "projects": ["/path/to/project1", "/path/to/project2"],
  "watch": { "intervalMin": 5, "timeoutMin": 30 }
}
```

---

## 九、Commit 规范

格式：`<type>(<scope>): <taskId>: <description>`

- type 从 task name 关键词自动推断
- scope = task ID（大写）
- Generator 在任务完成时自动 `git add → commit → push`
- `config.git.remote` 为空时不 push（本地模式）

详见 `docs/design/COMMIT-CONVENTION.md`

---

## 十、CLI 命令一览

| 命令 | 功能 |
|------|------|
| `nexum init` | 交互式初始化项目 |
| `nexum spawn <taskId>` | 生成 generator spawn payload |
| `nexum eval <taskId>` | 生成 evaluator spawn payload |
| `nexum track <taskId> <key>` | 记录 ACP session + 发派发通知 |
| `nexum callback <taskId>` | 处理回调（generator/evaluator），自动 dispatch 下一步 |
| `nexum complete <taskId> <verdict>` | 处理 eval 结果（pass/fail/escalated） |
| `nexum retry <taskId> --force` | 重置 escalated 任务 |
| `nexum status` | 查看所有任务状态 |
| `nexum archive` | 归档已完成任务 |
| `nexum health` | 单次卡死检测 |
| `nexum watch` | 守护进程（卡死检测） |
| `nexum watch install/uninstall` | 注册/卸载守护进程 |
| `nexum watch add-project/remove-project` | 管理监控项目 |
| `nexum watch list/status` | 查看监控状态 |

---

## 十一、任务批次管理

- `Task.batch` 字段标记任务所属批次
- `ActiveTasksFile.currentBatch` 标记当前默认批次
- `nexum status --batch <name>` 过滤显示
- 进度格式：`📊 v2-redesign: 3/6  |  总体: 13/15`
- done 任务超过 20 个时自动归档到 `nexum/history/<batch>.json`
