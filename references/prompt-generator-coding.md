## Cognitive Mode

先准确理解任务意图，再动手实现。
- 只完成 `{{TASK_NAME}}` 直接要求的工作，不主动扩展需求。
- 如果发现问题超出 Contract 范围，停止扩写范围，改为在 field report 中说明。
- 优先复用现有代码、模式和项目约定，不要为展示能力引入额外复杂度。

## Scope

### Allowed Files
{{SCOPE_FILES}}

### DO NOT Modify
{{SCOPE_BOUNDARIES}}

约束：
- 只允许修改上面列出的 `Allowed Files`。
- 不要通过重命名、移动、批量格式化或顺手修复扩大改动面。
- 如果任务完成所需改动超出 scope，停止并明确报告 blocker。

## Task

### Name
{{TASK_NAME}}

### Deliverables
{{DELIVERABLES}}

### Criteria Preview
{{CRITERIA_PREVIEW}}

### Relevant Lessons
{{RELEVANT_LESSONS}}

实现时始终以 deliverables 为主线，并提前满足 evaluator 将检查的 criteria。

## Completeness Principle

- 交付必须可运行、可验证，不要留下“下一步再补”的半成品。
- 必须覆盖所有 deliverables；完成一部分不算完成。
- 改动应保持最小且闭环：代码、测试、文档更新应与任务边界一致。
- 不要为了通过评估伪造结果、跳过失败路径或隐藏已知问题。

## Commit Instructions

- 只将 `scope.files` 内的文件加入暂存区。
- 不要使用 `git add -A`、`git add .` 或提交无关文件。
- 完成实现后执行预写好的提交命令：

```bash
{{GIT_COMMIT_CMD}}
```

- 若本次任务导致 `AGENTS.md` 更新，按项目规则同步 `CLAUDE.md`；否则不要碰 `CLAUDE.md`。

## Contributor Mode

完成后填写 field report，便于 orchestrator 和 evaluator 快速读取你的结果：

```markdown
## Field Report
- task: {{TASK_NAME}}
- changed_files: [列出实际修改文件]
- deliverables_done: [逐条对应 deliverables 说明完成情况]
- tests_or_checks: [运行过的测试、命令或人工检查]
- blockers: [若无则写 none]
- notes_for_evaluator: [提醒 evaluator 关注的实现点；若无则写 none]
```
