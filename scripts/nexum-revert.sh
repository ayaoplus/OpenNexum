#!/bin/bash
# Revert commits for a failed task and mark it cancelled.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="${NEXUM_PROJECT_DIR:-$(pwd -P)}"
TASK_FILE="${PROJECT_DIR}/nexum/active-tasks.json"

usage() {
  echo "Usage: nexum-revert.sh <task_id> [--force]" >&2
  exit 1
}

fail() {
  echo "$1" >&2
  exit 1
}

FORCE=false
TASK_ID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=true
      shift
      ;;
    --*)
      usage
      ;;
    *)
      if [ -n "$TASK_ID" ]; then
        usage
      fi
      TASK_ID="$1"
      shift
      ;;
  esac
done

[ -n "$TASK_ID" ] || usage

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

case "$task_status" in
  failed|escalated)
    ;;
  *)
    fail "Task ${TASK_ID} must be in failed or escalated status to revert (current: ${task_status})"
    ;;
esac
[ -n "$base_commit" ] || fail "Task ${TASK_ID} does not have a base_commit"

cd "$PROJECT_DIR"

commit_log="$(git log --oneline "${base_commit}..HEAD")" || fail "Failed to inspect commits from ${base_commit}..HEAD"
if [ -n "$commit_log" ]; then
  printf '%s\n' "$commit_log"
else
  echo "(no commits to revert)"
fi

if [ "$FORCE" = false ]; then
  printf 'Are you sure you want to revert %s commits? [y/N] ' "$TASK_ID"
  read -r confirm

  case "$confirm" in
    y|Y)
      ;;
    *)
      exit 0
      ;;
  esac
fi

commit_count="$(git rev-list --count "${base_commit}..HEAD")" || fail "Failed to count commits from ${base_commit}..HEAD"
if [ "$commit_count" -gt 0 ]; then
  git revert "${base_commit}..HEAD" --no-commit
  git commit -m "revert(nexum): roll back ${TASK_ID} commits"
  git push || echo "⚠️  Warning: git push failed. Local revert committed but not pushed. Run 'git push' manually."
fi

# Auto-escalate downstream blocked tasks that depended on the reverted task.
NEXUM_PROJECT_DIR="$PROJECT_DIR" REVERTED_TASK_ID="$TASK_ID" \
  TASK_FILE="$TASK_FILE" \
  UPDATE_SCRIPT="$SCRIPT_DIR/update-task-status.sh" \
  python3 - <<'PY'
import json
import os
import subprocess
import sys

task_file = os.environ["TASK_FILE"]
reverted_id = os.environ["REVERTED_TASK_ID"]
update_script = os.environ["UPDATE_SCRIPT"]
project_dir = os.environ["NEXUM_PROJECT_DIR"]

with open(task_file, encoding="utf-8") as f:
    data = json.load(f)

downstream = [
    t for t in data.get("tasks", [])
    if isinstance(t, dict)
    and t.get("status") == "blocked"
    and reverted_id in (t.get("depends_on") or [])
]

for task in downstream:
    tid = task["id"]
    env = {**os.environ, "NEXUM_PROJECT_DIR": project_dir}
    result = subprocess.run(
        [update_script, tid, "escalated", f"last_error=upstream_{reverted_id}_cancelled"],
        env=env,
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        print(f"↑ Escalated downstream task {tid} (was blocked on {reverted_id})")
    else:
        print(f"Warning: failed to escalate {tid}: {result.stderr.strip()}", file=sys.stderr)
PY

# Notify via Telegram if configured.
notify_target="$(NEXUM_PROJECT_DIR="$PROJECT_DIR" "$SCRIPT_DIR/swarm-config.sh" get notify.target 2>/dev/null || echo "")"
if [ -n "$notify_target" ] && [ "$notify_target" != "null" ] && command -v openclaw >/dev/null 2>&1; then
  openclaw message send --channel telegram --target "$notify_target" \
    -m "↩️ ${TASK_ID} reverted → cancelled. Downstream blocked tasks escalated if any." \
    >/dev/null 2>&1 || true
fi

"$SCRIPT_DIR/update-task-status.sh" "$TASK_ID" cancelled --field
echo "✅ ${TASK_ID} reverted successfully. Status → cancelled."
