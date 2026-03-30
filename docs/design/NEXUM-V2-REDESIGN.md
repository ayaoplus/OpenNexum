# OpenNexum v2 重设计方案

> 创建时间：2026-03-30
> 背景：今天一天的实战暴露了 12 个问题，统一设计后一次性解决。

---

## 一、问题清单

| # | 问题 | 优先级 |
|---|------|--------|
| 1 | ACP 只用单 session，并行任务互相干扰 | P0 |
| 2 | 任务类型自动路由 CLI（codex 优先），现在全靠手写 | P0 |
| 3 | 编排靠 LLM 手动操作，不自动化，不可重复 | P0 |
| 4 | 反复 fail 无 escalation 机制，永远卡着 | P1 |
| 5 | 通知两阶段语义不清（Generator 完成 vs 任务通过）| P1 |
| 6 | 通知字段不统一（一个有 token，另一个有进度）| P1 |
| 7 | Criteria 0/0 bug（eval 结果未传入 formatComplete）| P1 |
| 8 | Agent ID 含混（cc-frontend 是什么？）| P1 |
| 9 | 两阶段通知没有关联，看不出是同一个任务 | P1 |
| 10 | Agent ID 命名不统一，非语义化 | P2 |
| 11 | 通知不展开 Criteria，fail 时无法快速审查 | P2 |
| 12 | 文档无标准（结构/模板/写入时机/可配置）| P2 |

---

## 二、Agent ID 重命名规范

### 命名格式：`<model>-<role>-<number>`

| 新 ID | CLI | 模型 | Reasoning | 用途 |
|-------|-----|------|-----------|------|
| `codex-gen-01` | codex | gpt-5.4 | high | 后端/API/逻辑代码，实例 1 |
| `codex-gen-02` | codex | gpt-5.4 | high | 后端/API/逻辑代码，实例 2（并行）|
| `codex-gen-03` | codex | gpt-5.4 | high | 实例 3 |
| `codex-frontend-01` | codex | gpt-5.4 | medium | Admin/非用户端页面 |
| `codex-eval-01` | codex | gpt-5.4 | high | Code review（review Claude 写的）|
| `codex-e2e-01` | codex | gpt-5.4 | medium | E2E 测试执行 |
| `claude-gen-01` | claude | sonnet-4-6 | - | 用户端 WebUI，实例 1 |
| `claude-gen-02` | claude | sonnet-4-6 | - | 用户端 WebUI，实例 2（并行）|
| `claude-eval-01` | claude | sonnet-4-6 | - | Code review（review Codex 写的）|
| `claude-plan-01` | claude | opus-4-6 | - | 计划/架构设计 |
| `claude-write-01` | claude | sonnet-4-6 | - | 文档/creative |

### 命名同时作为 acpx session name
```bash
acpx -s codex-gen-01 codex exec -f prompt.md   # session 名 = agent ID
acpx -s codex-gen-02 codex exec -f prompt.md   # 并行第二个，独立 session
```

---

## 三、自动路由规则

### Contract 字段支持 `auto`
```yaml
generator: auto   # 系统自动选
evaluator: auto   # 遵循 cross-review 原则
```

### 路由决策树（generator）

```
contract.type == "creative"  → claude-write-01
contract.type == "task"      → codex-gen-01
contract.type == "coding":
  name 含 webui/frontend/用户端/portal → claude-gen-01
  name 含 admin/dashboard/管理         → codex-frontend-01
  name 含 e2e/test/测试                → codex-e2e-01
  其他（默认）                          → codex-gen-01
```

### Cross-review 原则（evaluator）
```
generator 是 codex-* → evaluator = claude-eval-01
generator 是 claude-* → evaluator = codex-eval-01
```

### 手写覆盖 auto
Contract 中手写 generator/evaluator 则优先使用，不走 auto 逻辑。

---

## 四、ACP 多 Session 并行

### 当前问题
`spawn.ts` 没有指定 session name，所有任务复用同一个 cwd session，并行时互相干扰。

### 解决方案
spawn 时固定 session 命名：
```
session name = <agentId>   (即 codex-gen-01, claude-gen-01 等)
```

同一个 agent ID 的多个并行任务需要不同编号（codex-gen-01, codex-gen-02）。

### spawn.ts 改动
```typescript
// 生成 acpx 命令时加 -s <agentId>
const args = ['-s', agentId, cliName, 'exec', '-f', promptFile, '--ttl', '0']
```

---

## 五、编排自动化

### 当前问题
现在的编排靠 LLM（小明）手动：
1. 看到 generator 完成 → 手动 `nexum eval`
2. 看到 eval 完成 → 手动读 yaml → 手动 `nexum complete`
3. 看到 complete → 手动 `nexum spawn` 下一个任务

这个链路不可靠、不自动化。

### 目标架构
generator/evaluator 完成后，由 **nexum daemon（watch）** 驱动后续步骤：

```
generator 完成
  → nexum callback → status: generator_done
  → watch 检测到 generator_done
  → 自动 spawn evaluator

evaluator 完成
  → nexum callback --role eval → 写 eval yaml + status: evaluating→done/failed
  → watch 检测到 eval 结果
  → pass → nexum complete → unlock → spawn 下一个 pending 任务
  → fail + iteration < max → nexum retry → spawn generator（retry prompt）
  → fail + iteration >= max → status: escalated → Telegram 通知人工介入
```

### 关键改动

**1. `nexum callback` 加 `--role` 参数**
```bash
nexum callback <taskId> --role generator  # 现在的行为
nexum callback <taskId> --role evaluator  # 新增：读 eval yaml，推进到 done/fail/escalated
```

**2. `nexum watch` 加主动推进逻辑**
```typescript
// watch 轮询时不只是检查卡死，还要推进状态机：
for (task with status == generator_done) → spawnEvaluator(task)
for (task with eval yaml written, status == evaluating) → processEvalResult(task)
for (task newly done) → unlockAndSpawnNext(task)
```

**3. `nexum spawn` 改为代码直接调 acpx，不再依赖 LLM**
```typescript
// spawn.ts 直接 execFile('acpx', ['-s', agentId, ...])
// 返回 session key，自动 track
```

---

## 六、Escalation 机制

### 触发条件
- `iteration >= max_iterations` → escalated
- 连续 2 次 fail 的 feedback 相似度 > 80% → 提前 escalated（可能是 Contract 写错）

### Escalated 行为
- 状态改为 `escalated`
- 停止自动 retry
- 发 Telegram 通知（全量信息：所有迭代的 fail reason + feedback）
- 等待人工处理（`nexum retry <taskId> --force` 或 `nexum cancel <taskId>`）

---

## 七、通知重新设计

### 两阶段统一格式

**阶段 1：代码提交（generator 完成）**
```
🔨 [1/2] 代码已提交 — NEXUM-002
━━━━━━━━━━━━━━━
📋 重写 @nexum/notify：通过 openclaw CLI...
🤖 codex-gen-01 (claude-sonnet-4-6)
🪙 Token: 15,234 in / 2,891 out
📦 commit: abc1234  🔁 第 1 次迭代
⏳ 等待代码审查...
```

**阶段 2：审查通过（eval pass）**
```
✅ [2/2] 审查通过 — NEXUM-002
━━━━━━━━━━━━━━━
📋 重写 @nexum/notify：通过 openclaw CLI...
🔍 codex-eval-01  ⏱️ 25m16s
🎯 Criteria: 5/5 全部通过
🔓 解锁: NEXUM-003  📊 进度: 9/11
```

**审查失败**
```
❌ [2/2] 审查失败 — NEXUM-002 (第 1 次)
━━━━━━━━━━━━━━━
📋 重写 @nexum/notify...
🎯 Criteria: 3/5
  ✅ C1 ✅ C2 ✅ C3 ❌ C4 ❌ C5
💬 C4: botToken 字段未删除；C5: 测试未更新
🔁 自动重试中...
```

**Escalated**
```
🚨 任务升级 — NEXUM-002 (已迭代 3 次)
━━━━━━━━━━━━━━━
📋 重写 @nexum/notify...
🎯 最终 Criteria: 3/5
❌ C4: botToken 字段未删除（3次均失败）
❌ C5: 测试未更新（3次均失败）
💬 可能是 Contract criteria 有问题
👉 nexum retry NEXUM-002 --force  或  nexum cancel NEXUM-002
```

---

## 八、文档标准化

### 文档结构（每个项目）

```
<project>/
├── AGENTS.md              # 项目规范 + lessons（gardener 维护）
├── CLAUDE.md              # 派生自 AGENTS.md，给 ACP agent 读
├── docs/
│   ├── design/            # 架构决策文档（人工写）
│   │   └── *.md
│   ├── lessons/           # 踩坑记录（generator 自动写）
│   │   ├── TEMPLATE.md    # 模板
│   │   └── YYYY-MM-DD-TASK-ID.md
│   └── nexum/
│       └── contracts/     # 任务合约
│           └── TASK-ID.yaml
└── nexum/
    ├── config.json        # 项目配置
    ├── active-tasks.json  # 任务状态（运行时，不进 git）
    └── runtime/           # 运行时数据（不进 git）
```

### 写入时机

| 时机 | 动作 | 执行者 |
|------|------|--------|
| generator 完成后 | 写 `docs/lessons/YYYY-MM-DD-TASK-ID.md` | generator（可选）|
| eval pass 后 | gardener 收割 lesson → AGENTS.md | gardener（auto）|
| nexum init 时 | 生成 config + 注入 CLAUDE.md | nexum CLI |
| 架构变更时 | 更新 `docs/design/` | 人工 |

### 用户可配置项（nexum/config.json）

```json
{
  "docs": {
    "lessons": {
      "enabled": true,
      "template": "docs/lessons/TEMPLATE.md",
      "dir": "docs/lessons"
    },
    "design": {
      "dir": "docs/design"
    },
    "agentsFile": "AGENTS.md"
  }
}
```

---

## 九、实施计划

### 分批次实施（按依赖顺序）

**Batch A（基础重构，其他都依赖它）**
- `NEXUM-006`：Agent ID 重命名 + config 更新 + 自动路由逻辑
- `NEXUM-007`：ACP 多 session 支持（spawn.ts 加 -s 参数 + --ttl 0）

**Batch B（编排自动化，依赖 A）**
- `NEXUM-008`：编排自动化（watch 驱动 eval/complete/retry/unlock 全链路）
- `NEXUM-009`：Escalation 机制

**Batch C（通知和体验，可与 B 并行）**
- `NEXUM-010`：通知重新设计（两阶段统一格式 + Criteria 展开 + bug 修复）

**Batch D（文档标准化，最后）**
- `NEXUM-011`：文档标准化（config.docs 字段 + 模板 + 写入时机规范）
