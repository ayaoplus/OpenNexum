# OpenNexum 架构设计文档

> 最后更新：2026-03-31
> 版本：v2.1（webhook dispatch + dispatch-queue 兜底）

---

## 一、系统概述

OpenNexum 是一个 **Contract-driven 多 Agent 编排系统**，通过 TypeScript CLI 管理 AI 编码任务的全生命周期。

**核心理念：**
- Contract 先行：每个任务在执行前必须有 YAML 定义（scope / deliverables / criteria）
- Generator ≠ Evaluator：写代码和审代码由不同 Agent 完成（GAN 原则）
- 事件驱动：callback 触发 eval/retry/unlock，不依赖轮询
- 双路 dispatch 兜底：webhook 实时 + dispatch-queue 心跳兜底，不丢任务
- Watch 守护进程：只做卡死检测，检测到卡死时自动唤醒编排者处理

---

## 二、包结构

```
packages/
├── core/          # 基础能力：类型、任务管理、配置、Contract 解析（js-yaml）、Git、parseEvalResult
├── prompts/       # Prompt 模板渲染（generator / evaluator / retry）
├── spawn/         # ACP session 状态查询（spawnAcpSession 已为 no-op，spawn 由编排者调用 sessions_spawn）
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
| `running` | Generator 正在执行 | `nexum track --role generator` |
| `generator_done` | 代码编写完成，等待审查 | `nexum callback --role generator` |
| `evaluating` | Evaluator 正在审查 | `nexum track --role evaluator` |
| `done` | 审查通过，任务完成 | `nexum complete pass` |
| `failed` | 任务失败 | 异常 |
| `escalated` | 超过重试上限，需人工介入 | `nexum complete` 检测到 |
| `cancelled` | 手动取消 | `nexum cancel` |

---

## 四、编排流程（事件驱动 + 双路 dispatch）

```
1. 编排者写 Contract YAML → 注册到 active-tasks.json
2. nexum spawn <taskId> → 生成 prompt 文件（不提前标记 running）
3. 编排者按 payload.runtime 派发（`acp` → sessions_spawn，`tmux` → PTY/tmux dispatcher）
4. nexum track <taskId> <sessionKey> --role generator → 状态: running，记录 session + 发派发通知

5. Generator 完成 → git commit + push → nexum callback --role generator
   ↓ callback 自动执行:
   a. 状态 → generator_done
   b. 发通知 [1/2] 代码编写完成
   c. 写 nexum/dispatch-queue.jsonl（兜底）
   d. POST /hooks/agent → 实时唤醒编排者
   e. 编排者收到 webhook → nexum eval → 按 payload.runtime 派发 evaluator → nexum track --role evaluator → 状态: evaluating

6. Evaluator 完成 → 写 eval YAML → nexum callback --role evaluator
   ↓ callback 自动执行:
   a. 读 eval YAML → 判断 verdict
   b. verdict=pass → complete → 状态: done → 发通知 [2/2] 审查通过
      → 如果当前 batch 全部完成 → 发批次总结通知 🎉
      → 解锁下游任务 → 写 dispatch-queue + POST /hooks/agent
      → 编排者 spawn 下一个 pending generator → nexum track --role generator
   c. verdict=fail → retry → 发通知 审查失败
      → 写 dispatch-queue + POST /hooks/agent
      → 编排者 spawn retry generator → nexum track --role generator
   d. iteration >= max 或 feedback 相似度 > 80% → escalated → 发通知 → 停止

7. 兜底机制（dispatch-queue）:
   - callback 每次 dispatch 前写 nexum/dispatch-queue.jsonl（带文件锁，原子写）
   - watch 心跳扫描 queue，未处理的 entry 会重放 webhook，重新唤醒编排者
   - queue entry 在 `track` 或后续状态推进后 ack，避免重复派发

8. Watch 守护进程（dispatch heartbeat + 卡死检测）:
   - 每 5 分钟检查所有项目
   - 先扫描 dispatch-queue，重放未处理 webhook
   - 再检查 30 分钟无更新的 running/evaluating 任务 → 发 Telegram 告警
   - 同时 POST /hooks/agent 唤醒编排者自动处理
```

---

## 五、Agent 命名规范

格式：`<model>-<role>-<number>`

| Agent ID | CLI | 默认执行 backend | 模型 | 用途 |
|----------|-----|------------------|------|------|
| codex-gen-01~03 | codex | `acp/codex` | gpt-5.4 (high) | 后端/API/逻辑代码 |
| codex-frontend-01 | codex | `acp/codex` | gpt-5.4 (medium) | Admin/非用户端页面 |
| codex-eval-01 | codex | `acp/codex` | gpt-5.4 (high) | Code review（review Claude 代码）|
| codex-e2e-01 | codex | `acp/codex` | gpt-5.4 (medium) | E2E 测试 |
| claude-gen-01~02 | claude | `tmux/claude` | sonnet-4-6 | 用户端 WebUI |
| claude-eval-01 | claude | `tmux/claude` | sonnet-4-6 | Code review（review Codex 代码）|
| claude-plan-01 | claude | `tmux/claude` | opus-4-6 | 架构/计划 |
| claude-write-01 | claude | `tmux/claude` | sonnet-4-6 | 文档/creative |

**Cross-review 原则：** Codex 写 → Claude review；Claude 写 → Codex review

**自动路由：** Contract 里写 `generator: auto` / `evaluator: auto` 时，`auto-route.ts` 按任务名关键词自动选择。

---

## 六、执行 Runtime 管理

### spawn 方式
`nexum spawn` / `nexum eval` 输出的 payload 里，需要区分两层身份：

- `agentId`: 逻辑 agent，用于路由、通知、评审归属
- `runtime` + `runtimeAgentId`: 编排层真正调用的执行 backend

默认策略：Codex logical agents → `acp/codex`；Claude logical agents → `tmux/claude`。除非显式覆写，不要把 Claude 当成 ACP backend。

当 `runtime = "acp"` 时，由**编排者（小明）**调用 OpenClaw `sessions_spawn` 工具派发：
```
sessions_spawn(promptFile, runtimeAgentId, label, cwd, mode="run")
→ 返回 childSessionKey
```

当 `runtime = "tmux"` 时，改走 tmux / PTY dispatcher，`runtimeAgentId` 通常为 `claude`。

`spawnAcpSession` 函数保留但为 no-op stub，不再调用 acpx CLI。

### session 命名（顺序递增）
- Generator: `codex-gen-01`, `codex-gen-02`, `codex-gen-03`...（全局递增，存 `nexum/session-counter.json`）
- Evaluator: `claude-eval-01`, `claude-eval-02`...（同一计数器，role=eval）
- 通知中显示格式：`codex-gen-01 (NEXUM-023)`，并行任务可区分

### session 并行
- 每个任务独立 runtime session，互不干扰
- scope 文件不重叠时可安全并行
- scope 有重叠时用 `depends_on` 串行化

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
    "codex-gen-01": {
      "cli": "codex",
      "model": "gpt-5.4",
      "reasoning": "high",
      "execution": { "runtime": "acp", "agentId": "codex" }
    },
    "claude-gen-01": {
      "cli": "claude",
      "model": "claude-sonnet-4-6",
      "execution": { "runtime": "tmux", "agentId": "claude" }
    },
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
- 进度格式：两行显示 `📊 当前批次 (batch-3): 3/6` 和 `📊 总体: 13/15`
- done 任务超过 20 个时自动归档到 `nexum/history/<batch>.json`
