# Orchestrator Guide — AI 编排者工作流程

本文档面向 AI 编排者（orchestrator agent），说明如何使用 nexum-ts CLI
驱动完整的任务生命周期。

---

## 概览

编排者的职责：
1. 读取 `nexum status --json` 了解当前任务状态
2. 对 `pending` 任务调用 `nexum spawn` 获取 SpawnPayload
3. 调用 `openclaw sessions spawn` 启动 generator agent，保存 `sessionKey` 和 `streamLogPath`
4. 轮询 heartbeat，等待 agent 完成
5. 调用 `nexum eval` 启动 evaluator agent，重复步骤 3-4
6. 读取 eval result YAML，调用 `nexum complete <verdict>` 推进状态
7. 对 `retry` 结果重复步骤 3-4；对 `pass` 结果检查新解锁的任务

---

## Step 1：查询任务状态

```bash
nexum status --json
```

**返回示例：**
```json
[
  { "id": "NX2-001", "name": "完善 Task 类型定义", "status": "done" },
  { "id": "NX2-002", "name": "nexum init 命令", "status": "pending" },
  { "id": "NX2-003", "name": "Spawn/Eval/Complete 整合", "status": "blocked" }
]
```

选取 `status === "pending"` 的任务进入 Step 2。

---

## Step 2：派发 Generator — `nexum spawn`

```bash
nexum spawn <taskId> [--project-dir <path>]
```

**stdout 输出（JSON SpawnPayload）：**
```json
{
  "taskId": "NX2-002",
  "taskName": "nexum init 命令",
  "agentId": "cc-frontend",
  "agentCli": "claude",
  "promptFile": "/abs/path/nexum/runtime/prompts/NX2-002-gen-iter0.md",
  "promptContent": "# Task: NX2-002\n...",
  "label": "NX2-002-gen-iter0",
  "cwd": "/abs/path/to/project"
}
```

**字段说明：**

| 字段 | 说明 |
|------|------|
| `agentId` | Contract 中配置的 generator ID |
| `agentCli` | 解析后的 CLI 类型：`"claude"` 或 `"codex"` |
| `promptFile` | prompt 已写入磁盘的绝对路径 |
| `label` | 用于 openclaw 的 session 标签 |
| `cwd` | agent 工作目录 |

> `nexum spawn` 已将任务状态更新为 `running` 并记录 `base_commit`。

---

## Step 3：调用 openclaw sessions spawn

根据 `agentCli` 选择不同调用方式：

### agentCli === "claude"（Claude Code）

```bash
openclaw sessions spawn \
  --runtime acp \
  --agent <agentId> \
  --mode code \
  --cwd <cwd> \
  --label <label> \
  --task-file <promptFile>
```

### agentCli === "codex"（OpenAI Codex）

```bash
openclaw sessions spawn \
  --runtime acp \
  --agent <agentId> \
  --mode code \
  --cwd <cwd> \
  --label <label> \
  --task-file <promptFile>
```

**openclaw 返回示例（JSON）：**
```json
{
  "childSessionKey": "sess_abc123xyz",
  "streamLogPath": "/tmp/acp-streams/sess_abc123xyz.jsonl"
}
```

**必须保存：**
- `sessionKey`（即 `childSessionKey` / `sessionKey` / `key` 三者之一）
- `streamLogPath`（ACP stream log 文件路径，用于 heartbeat 读取）

> openclaw 也会直接更新 `nexum/active-tasks.json` 中的 `acp_session_key` 字段。

---

## Step 4：Heartbeat 轮询

轮询直到 agent 完成：

```bash
# 查询 session 状态
openclaw sessions status <sessionKey>
```

或直接读取 streamLogPath（JSONL 格式），检测 `type: "done"` 或 `type: "error"` 事件。

**轮询建议：**
- 间隔：30 秒
- 超时：根据任务复杂度，建议 30 分钟
- 若超时，可将任务标记为 failed：`nexum complete <taskId> escalated`

**判断完成的信号：**
1. `openclaw sessions status` 返回 `status: "done"` / `"error"`
2. streamLogPath 中出现 `{"type":"session_end",...}` 事件

---

## Step 5：派发 Evaluator — `nexum eval`

```bash
nexum eval <taskId> [--project-dir <path>]
```

输出与 `nexum spawn` 相同格式的 `SpawnPayload`，但 `agentId` 来自 Contract 的 `evaluator` 字段。

同时 nexum 已将任务状态更新为 `evaluating`，并在 `eval_result_path` 记录评估结果的预期写入路径：

```
nexum/runtime/eval/<taskId>-iter-<n>.yaml
```

重复 Step 3-4，等待 evaluator agent 完成并将结果写入该路径。

---

## Step 6：读取 Eval Result

evaluator agent 完成后，读取 `eval_result_path` 文件：

```yaml
# nexum/runtime/eval/NX2-002-iter-0.yaml
task_id: NX2-002
verdict: pass          # pass | fail | escalated
feedback: "所有交付物已验证通过"
failed_criteria: []
pass_count: 3
total_count: 3
criteria_results:
  - id: C1
    passed: true
    notes: "init.ts 已创建，目录结构正确"
  - id: C2
    passed: true
    notes: "config.json 加载逻辑实现正确"
  - id: C3
    passed: true
    notes: "pnpm build && pnpm test 通过"
evaluated_at: "2026-03-29T10:30:00Z"
iteration: 0
commit_hash: "d963745"
summary: "任务完成，所有标准通过"
```

---

## Step 7：处理结果 — `nexum complete`

```bash
nexum complete <taskId> <verdict> [--project-dir <path>]
```

### verdict: pass

```json
{
  "action": "done",
  "taskId": "NX2-002",
  "unlockedTasks": ["NX2-003"]
}
```

- 任务状态 → `done`
- 返回 `unlockedTasks`：依赖本任务的下游任务现已解锁（状态 `blocked` → `pending`）
- 对每个 unlockedTasks 重新进入 Step 2

### verdict: fail（未超过 max_iterations）

```json
{
  "action": "retry",
  "taskId": "NX2-002",
  "retryPayload": {
    "taskId": "NX2-002",
    "agentId": "cc-frontend",
    "agentCli": "claude",
    "promptFile": "/abs/path/nexum/runtime/prompts/NX2-002-retry-iter1.md",
    "promptContent": "...",
    "label": "NX2-002-retry-iter1",
    "cwd": "/abs/path/to/project"
  }
}
```

- `retryPayload` 包含带有前次失败反馈的 retry prompt
- 直接用 `retryPayload` 重新调用 openclaw（Step 3）

### verdict: escalated 或超过 max_iterations

```json
{
  "action": "escalated",
  "taskId": "NX2-002"
}
```

- 任务状态 → `failed`
- 需要人工介入，检查 `nexum/runtime/eval/` 中的评估历史

---

## 错误处理

所有 nexum 命令在出错时返回非零退出码，并输出 JSON 错误对象（当任务以 `--json` 模式调用时）：

```json
{
  "error": "TASK_NOT_FOUND",
  "message": "Task NX2-999 not found in active-tasks.json"
}
```

**常见错误码：**

| 错误码 | 说明 | 处理建议 |
|--------|------|----------|
| `TASK_NOT_FOUND` | 任务 ID 不存在 | 检查 active-tasks.json |
| `CONTRACT_NOT_FOUND` | Contract YAML 文件缺失 | 检查 contract_path |
| `INVALID_VERDICT` | verdict 参数不合法 | 只允许 pass/fail/escalated |
| `CONFIG_INVALID` | nexum/config.json 格式错误 | 修复配置文件 |
| `GIT_ERROR` | git 操作失败 | 检查工作区是否干净 |
| `SESSION_TIMEOUT` | ACP session 超时 | 增大超时或检查 agent 日志 |

---

## 完整编排伪代码

```typescript
async function orchestrate(projectDir: string) {
  while (true) {
    const tasks = await runJson("nexum status --json");
    const pending = tasks.filter(t => t.status === "pending");

    if (pending.length === 0) break;

    for (const task of pending) {
      // Step 2: spawn generator
      const spawnPayload = await runJson(`nexum spawn ${task.id}`);

      // Step 3: call openclaw
      const { sessionKey, streamLogPath } = await callOpenclaw(spawnPayload);

      // Step 4: heartbeat
      await waitForSession(sessionKey, streamLogPath);

      // Step 5: spawn evaluator
      const evalPayload = await runJson(`nexum eval ${task.id}`);
      const { sessionKey: evalKey } = await callOpenclaw(evalPayload);
      await waitForSession(evalKey, evalPayload.streamLogPath);

      // Step 6: read eval result
      const evalResult = readYaml(task.eval_result_path);

      // Step 7: complete
      const result = await runJson(`nexum complete ${task.id} ${evalResult.verdict}`);

      if (result.action === "retry") {
        // retry: 用 retryPayload 重新 spawn
        await callOpenclaw(result.retryPayload);
        // ... continue heartbeat + eval loop
      } else if (result.action === "done") {
        // 新解锁的任务在下次循环中处理
        console.log("Unlocked:", result.unlockedTasks);
      }
    }
  }
}
```
