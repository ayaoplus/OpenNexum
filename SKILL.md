---
name: opennexum
version: 2.1.0
description: Contract-driven multi-agent orchestration with ACP. Event-driven dispatch, cross-review, auto-retry, parallel session support.
requires:
  node: ">=20"
  tools: [pnpm, openclaw, acpx]
---

# OpenNexum

Contract-driven coding agent orchestration via OpenClaw ACP.

## When to use
- Coordinating multiple AI coding agents (Codex + Claude)
- Running generator/evaluator pairs with automatic retry and escalation
- Parallel task execution with independent ACP sessions
- Tracking task progress with Telegram notifications

## Architecture
- **Event-driven**: callback triggers eval → complete → next-task (no polling for dispatch)
- **Watch daemon**: health-only, stuck task detection (dispatch by callback)
- **Cross-review**: codex-gen → claude-eval, claude-gen → codex-eval
- **Auto-routing**: `generator: auto` in Contract YAML → system selects agent by task type

## Agent Naming: `<model>-<role>-<number>`
- codex-gen-01~03: backend/API code
- claude-gen-01~02: user-facing WebUI
- codex-eval-01 / claude-eval-01: cross-review
- claude-plan-01: architecture (opus)
- claude-write-01: docs/creative

## Quick Start
1. `pnpm install && pnpm build`
2. `nexum init --project <dir>` — interactive setup
3. Create Contract YAML in `docs/nexum/contracts/`
4. Register task in `nexum/active-tasks.json`
5. `nexum spawn <taskId>` → spawn via acpx
6. Generator completes → `nexum callback <taskId>` → auto eval → auto complete

## Key Commands
- `nexum init` — interactive project setup
- `nexum spawn/eval <taskId>` — generate spawn payload
- `nexum callback <taskId> --role generator|evaluator` — process callback + auto-dispatch
- `nexum status` — task overview
- `nexum health` — stuck detection
- `nexum watch install` — register daemon

## Notification (8 types, via openclaw message send)
🚀 Dispatch → 🔨 [1/2] Code Done → ✅ [2/2] Review Pass / ❌ Fail / 🚨 Escalate
⚠️ Commit Missing / 🚨 Health Alert / 🎉 Batch Done

## Docs
- Architecture: docs/design/ARCHITECTURE.md
- Commit Convention: docs/design/COMMIT-CONVENTION.md
- V2 Redesign: docs/design/NEXUM-V2-REDESIGN.md
