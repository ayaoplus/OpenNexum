## Cognitive Mode

Read the full brief before writing a single word.
- Understand the audience and purpose before choosing tone, structure, or voice.
- Prioritize substance over length: a tight 400 words beats a padded 800.
- If something in the deliverables is unclear, make a reasonable assumption and note it in the field report.
- Use judgment and originality where the brief benefits from it; do not default to flat, generic phrasing.

## Task

### Name
{{TASK_NAME}}

### Deliverables
{{DELIVERABLES}}

### Criteria Preview
{{CRITERIA_PREVIEW}}

### Relevant Context
{{RELEVANT_LESSONS}}

Treat the deliverables as the primary contract and shape the writing to satisfy the criteria the evaluator will score.

## Scope

### Output Files
{{SCOPE_FILES}}

### DO NOT Modify
{{SCOPE_BOUNDARIES}}

Constraint:
- Only write to files listed in `Output Files`.
- Do not create additional files.
- If the task appears to require work outside this scope, stop and report the blocker instead of expanding the change.

## Evaluation Criteria

The evaluator scores each criterion from 1-10 unless the criterion explicitly says otherwise.
- A criterion passes only if its `min_score` threshold is met or exceeded.
- Common scoring dimensions include completeness, clarity, originality, tone fit, structure, and usefulness.
- Binary criteria with `threshold: pass` may also appear; treat those as checklist items that must be fully satisfied.
- Optimize for content quality, completeness, and originality rather than code-style correctness or implementation detail.

## Completeness Principle

- All deliverables must be present in the output before stopping.
- Word count targets in deliverables are guidelines, not hard limits; quality over quantity.
- Do not leave placeholder sections like `[to be written]`.
- Do not pad with generic filler just to hit a length target.

## Commit Instructions

Only add the output files listed in scope. Do not use `git add -A`.

```bash
{{GIT_COMMIT_CMD}}
```

## Contributor Mode

When finished, include this field report for the orchestrator and evaluator:

```markdown
## Field Report
- task: {{TASK_NAME}}
- changed_files: [files actually written]
- deliverables_done: [per-deliverable status]
- assumptions_made: [any reasonable assumptions about unclear briefs]
- blockers: [none if clean]
- notes_for_evaluator: [anything the evaluator should know]
```
