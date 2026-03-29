# Commit 规范与即时 Push 流程

> 本文档定义 OpenNexum 系统的 Commit 行为规范。

## 1. 核心理念

**每次任务完成后即时 Commit + Push**，不攒批。

- 原子性：每个 commit 对应一个独立任务变更
- 零成本：AI 时代 commit 没有负担，秒级完成
- 更安全：代码随时 push 到远程，不依赖本地备份
- 冲突少：小步提交每次只涉及少量文件，冲突概率极低
- 可追溯：每个任务独立 commit，回溯和 revert 都清晰

## 2. Commit Message 格式

采用 [Conventional Commits](https://www.conventionalcommits.org/)：

```
<type>(<scope>): <taskId>: <description>
```

### 示例

```
feat(INFRA-001): INFRA-001: 骨架搭建 + Client 封装
fix(CLI-042): CLI-042: 修复 eval 状态推进逻辑
refactor(NX-007): NX-007: 重构 spawn 模块为 async
docs(README): 更新部署说明
```

### 字段说明

| 字段 | 来源 | 说明 |
|------|------|------|
| `type` | 从 task name 关键词推断 | feat / fix / refactor / docs / test / perf / ci / chore |
| `scope` | contract 文件名 | 即 TASK-ID（不含横线前缀） |
| `taskId` | 任务 ID | 如 `INFRA-001`、`NX-007` |
| `description` | `task.name` | 任务描述，简洁 |

### Type 判断规则

| 规则 | Type |
|------|------|
| task name 含 fix / bug / hotfix / 修复 / 修补 | `fix` |
| task name 含 refactor / 重构 | `refactor` |
| task name 含 docs / 文档 / readme | `docs` |
| task name 含 test / 测试 | `test` |
| task name 含 perf / 性能 / optimize / 优化 | `perf` |
| task name 含 ci / cd / pipeline / github | `ci` |
| task name 含 chore / 杂务 | `chore` |
| 默认（大多数 coding 任务） | `feat` |

## 3. 实现逻辑

### 触发时机

`nexum callback <taskId>` 被调用时，即 generator 或 evaluator 完成任务后。

### 流程（`callback.ts`）

```
1. getChangedFiles() — git diff --name-only HEAD
   → 如果没有变更，直接跳过 commit/push

2. buildCommitMessage() — 组装 Conventional Commits message
   → 从 task.name 推断 type，从 contract_path 提取 scope

3. commitFiles() — git add <changed files> + git commit -m <msg>
   → 只 commit 实际变更的文件，不碰无关文件

4. gitPush() — git push -u origin HEAD
   → 推送当前分支到远程

5. updateTask() — status → GeneratorDone

6. sendMessage() — Telegram 通知编排者
```

### 无变更处理

如果 `git diff --name-only HEAD` 返回空，视为无变更，跳过步骤 3-4，直接推进状态并通知。

### 冲突处理

- **原则**：通过 `git revert` 解决，不手动 merge
- 实操：冲突极少发生；一旦发生，回滚单次 commit 成本极低

## 4. 分支策略

- 默认直接 push 到 `main` 分支（单人或小团队，无需 PR review）
- 多人协作场景：由 `nexum init` 时确定分支策略，当前为 direct-to-main

## 5. Git 配置前置要求

确保本地已配置 git remote：

```bash
git remote add origin https://github.com/ayaoplus/OpenNexum.git
# 或使用 SSH
git remote add origin git@github.com:ayaoplus/OpenNexum.git
```

首次 push 时 `git push -u origin HEAD` 会自动设置 upstream。
