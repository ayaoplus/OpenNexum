#!/bin/bash
# Revert commits for a failed task and mark it cancelled.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="${NEXUM_PROJECT_DIR:-$(pwd -P)}"
TASK_FILE="${PROJECT_DIR}/nexum/active-tasks.json"

usage() {
  echo "Usage: nexum-revert.sh <task_id>" >&2
  exit 1
}

fail() {
  echo "$1" >&2
  exit 1
}

[ "$#" -eq 1 ] || usage
TASK_ID="$1"

[ -d "$PROJECT_DIR" ] || fail "Project directory not found: $PROJECT_DIR"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"
TASK_FILE="${PROJECT_DIR}/nexum/active-tasks.json"

task_fields="$(
  TASK_FILE="$TASK_FILE" TARGET_TASK_ID="$TASK_ID" python3 - <<'PY'
import json
import os
import sys
from json import JSONDecodeError

task_file = os.environ["TASK_FILE"]
task_id = os.environ["TARGET_TASK_ID"]

try:
    with open(task_file, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except FileNotFoundError:
    print(f"Task file not found: {task_file}", file=sys.stderr)
    raise SystemExit(1)
except JSONDecodeError as exc:
    print(f"Invalid JSON in {task_file}: {exc}", file=sys.stderr)
    raise SystemExit(1) from exc

tasks = data.get("tasks")
if not isinstance(tasks, list):
    print(f"Invalid task file structure: {task_file}", file=sys.stderr)
    raise SystemExit(1)

for task in tasks:
    if isinstance(task, dict) and task.get("id") == task_id:
        status = task.get("status") or ""
        base_commit = task.get("base_commit")
        print(f"{status}\t{'' if base_commit is None else base_commit}")
        raise SystemExit(0)

print(f"Task not found: {task_id}", file=sys.stderr)
raise SystemExit(1)
PY
)"

IFS=$'\t' read -r task_status base_commit <<<"$task_fields"

[ "$task_status" = "failed" ] || fail "Task ${TASK_ID} must be in failed status to revert (current: ${task_status})"
[ -n "$base_commit" ] || fail "Task ${TASK_ID} does not have a base_commit"

cd "$PROJECT_DIR"

commit_log="$(git log --oneline "${base_commit}..HEAD")" || fail "Failed to inspect commits from ${base_commit}..HEAD"
if [ -n "$commit_log" ]; then
  printf '%s\n' "$commit_log"
else
  echo "(no commits to revert)"
fi

printf 'Are you sure you want to revert %s commits? [y/N] ' "$TASK_ID"
read -r confirm

case "$confirm" in
  y|Y)
    ;;
  *)
    exit 0
    ;;
esac

commit_count="$(git rev-list --count "${base_commit}..HEAD")" || fail "Failed to count commits from ${base_commit}..HEAD"
if [ "$commit_count" -gt 0 ]; then
  git revert "${base_commit}..HEAD" --no-commit
  git commit -m "revert(nexum): roll back ${TASK_ID} commits"
  git push || echo "⚠️  Warning: git push failed. Local revert committed but not pushed. Run 'git push' manually."
fi

"$SCRIPT_DIR/update-task-status.sh" "$TASK_ID" cancelled
echo "✅ ${TASK_ID} reverted successfully. Status → cancelled."
