# OpenNexum v2 重设计方案 — 实施记录

> 创建：2026-03-30
> 状态：**全部完成** ✅

---

## 问题清单与解决状态

| # | 问题 | 状态 | 解决方式 |
|---|------|------|---------|
| 1 | ACP 只用单 session，并行互相干扰 | ✅ | spawn.ts 直接调 acpx，-s <agentId> 命名 session |
| 2 | 任务类型自动路由全靠手写 | ✅ | auto-route.ts，Contract 支持 generator: auto |
| 3 | 编排靠 LLM 手动操作 | ✅ | callback 事件驱动 auto-dispatch eval/retry/next-task |
| 4 | 反复 fail 无 escalation | ✅ | complete.ts 检测 max_iterations + feedback 相似度 |
| 5 | 通知两阶段语义不清 | ✅ | [1/2] 代码编写完成 / [2/2] 审查通过 |
| 6 | 通知字段不统一 | ✅ | 全部走模板函数，字段对齐 |
| 7 | Criteria 0/0 bug | ✅ | readEvalSummary 完整解析 criteria blocks |
| 8 | Agent ID 含混 | ✅ | <model>-<role>-<number> 格式 |
| 9 | 两阶段通知没有关联 | ✅ | [1/2] / [2/2] 标记同一任务 |
| 10 | Agent ID 命名不统一 | ✅ | 11 个标准 agent ID，同时作为 session name |
| 11 | 通知不展开 Criteria | ✅ | fail 时逐条展开 ✅/❌ |
| 12 | 文档无标准 | ✅ | ARCHITECTURE.md + COMMIT-CONVENTION.md |

## 额外完成的改进

| 改进 | 说明 |
|------|------|
| spawn.ts 重写 | 从 openclaw sessions spawn（错误）改为直接 acpx |
| fail/escalated 通知补全 | callback evaluator 覆盖 done/retry/escalated 三种场景 |
| watch 职责简化 | 只做卡死检测，不做 dispatch |
| readEvalSummary 统一 | callback.ts 完整版，解析 criteria blocks |
| TaskStatus.Escalated | 正式加入枚举，移除运行时 hack |
| getDaemonStatus 修复 | launchctl plist 格式用正则匹配 PID |
| 通知模板全面重构 | 8 种通知类型全部模板化，无内联字符串 |
| 模型名标准化 | 从 config agents 映射，过滤非标准名 |
| 任务批次管理 | batch 字段 + 历史归档 + 进度按批次 |
| commit message 带入通知 | git log -1 读取并显示 |

## 实施批次

| Batch | 任务 | 状态 |
|-------|------|------|
| A（基础重构） | NEXUM-006 Agent 重命名 + NEXUM-007 多 session | ✅ |
| B（编排自动化） | NEXUM-008 watch 自动化 + NEXUM-009 Escalation | ✅ |
| C（通知体验） | NEXUM-010 批次管理 + NEXUM-011 通知 bug + NEXUM-012 callback dispatch | ✅ |
| 手动重构 | spawn.ts 重写 + callback.ts 拆分 + 通知模板全面重构 | ✅ |
