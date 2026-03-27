---
name: opennexum
description: "Contract-driven multi-agent orchestration skill for OpenClaw. Use when: coordinating parallel coding agents, dispatching generator/evaluator pairs, or managing multi-task project execution."
---

# OpenNexum

Contract-driven multi-agent orchestration for OpenClaw.
Define verifiable deliverables (Contracts) before dispatching work.
Generators produce code; independent Evaluators verify each task.
Knowledge accumulates via lessons across iterations (Phase 3).

## Quick Start

1. **Initialize project:**
   ```bash
   nexum-init.sh --project <name> --tech "<stack>"
   ```
2. **Create a Contract** at `docs/nexum/contracts/TASK-ID.yaml` (see `references/contract-schema.md` for field spec).
3. **Dispatch a generator:**
   ```bash
   dispatch.sh <agent> <task_id> --role generator <cli_command...>
   ```

## Scripts

| Script | Usage | Purpose |
|--------|-------|---------|
| `nexum-init.sh` | `--project <name> [--tech "<stack>"] [--type <coding\|mixed>]` | Initialize project directory structure + tmux sessions |
| `dispatch.sh` | `<agent> <task_id> --role <generator\|evaluator> [--prompt-file <path>] <cli_command...>` | Unified generator/evaluator dispatch entry point |
| `on-complete.sh` | `<task_id> <exit_code> --role <generator\|evaluator>` | Completion callback: scope check, eval dispatch, feedback loop |
| `dispatch-evaluator.sh` | `<task_id>` | Build evaluator prompt from contract + dispatch eval agent |
| `update-task-status.sh` | `<task_id> <status> [--output-batch-done] [key=value ...]` | Atomic active-tasks.json write (flock + fcntl fallback) |
| `swarm-config.sh` | `get\|set\|show\|resolve <dot.path> [<value>]` | Read/write skill + project config (defaults + overrides) |
| `install-hooks.sh` | `<project_path>` | Install post-commit hook (events.jsonl + push) |
| `health-check.sh` | `[--project <path>] [--threshold <minutes>]` | Detect stuck/dead agents (default 15min threshold) |
| `nexum-revert.sh` | `<task_id>` | Revert commits for a failed task, mark it cancelled |

## References

| File | Description |
|------|-------------|
| `references/contract-schema.md` | Contract YAML field spec (id, name, type, scope, deliverables, eval_strategy, generator, evaluator, max_iterations, depends_on) |
| `references/defaults.json` | Skill-level default config (agent CLIs, models, thresholds) |
| `references/prompt-generator-coding.md` | Coding generator prompt template |
| `references/prompt-evaluator.md` | Evaluator prompt template |
| `references/agents-md-template.md` | AGENTS.md generation template |
| `references/lesson-template.md` | Lesson document template |

## Key Data Files (in project, not skill)

| Path | Description |
|------|-------------|
| `nexum/active-tasks.json` | Task status registry (the only runtime truth) |
| `nexum/events.jsonl` | Append-only event log |
| `nexum/config.json` | Project-level config overrides |
| `nexum/runtime/eval/TASK-ID-iter-N.yaml` | Evaluator result per iteration |
| `docs/nexum/contracts/TASK-ID.yaml` | Static task contract (immutable after creation) |

## Task Status Lifecycle

```
pending → running → evaluating → done | failed | escalated | cancelled
```

## Agent Naming Convention

Tmux sessions are prefixed `nexum-`: `nexum-plan`, `nexum-codex-1`, `nexum-eval`, etc.

## Orchestrator Rules

- **Always create a Contract YAML before dispatching.** No contract = no dispatch.
- **Task ID format:** Must match `^[A-Z]+-[0-9]+$` (e.g., `TASK-001`, `FIX-007`). IDs like `T001` or `task-1` are rejected by dispatch.sh.
- Use `dispatch.sh --role generator` for coding work; `dispatch-evaluator.sh <task_id>` (or `dispatch.sh --role evaluator`) for evaluation.
- On `task_done` system event: read the eval result at `nexum/runtime/eval/TASK-ID-iter-N.yaml`.
- On `eval_done` pass: scan `active-tasks.json` for newly unblocked tasks (all `depends_on` satisfied) and dispatch them.
- On escalation: read the last eval feedback, then either fix the contract and retry or escalate to the human operator.
- Run `health-check.sh` periodically (e.g., from a heartbeat loop) to detect stuck agents.

## Design Document

Full architecture: `docs/design/v1.md`

## Contract YAML Top-Level Fields (quick ref)

```yaml
id: TASK-001
name: "Human-readable task name"
type: coding          # coding | task | creative
created_at: "2026-03-27T00:00:00Z"
scope:
  files: [src/foo.ts]
  boundaries: [src/auth/]
  conflicts_with: []
deliverables:
  - "Deliverable that the evaluator can verify"
eval_strategy:
  type: unit          # unit | integration | e2e | review | composite
  criteria:
    - id: C1
      desc: "Criterion description"
generator: codex-1
evaluator: eval
max_iterations: 3
depends_on: []
```
