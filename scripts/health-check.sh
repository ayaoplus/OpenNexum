#!/bin/bash
# Check active task sessions and surface stuck/dead workers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="${NEXUM_PROJECT_DIR:-$(pwd -P)}"
THRESHOLD=15

usage() {
  cat >&2 <<'EOF'
Usage: health-check.sh [--project <path>] [--threshold <minutes>]
EOF
  exit 1
}

fail() {
  echo "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      [ "$#" -ge 2 ] || usage
      PROJECT_DIR="$2"
      shift 2
      ;;
    --threshold)
      [ "$#" -ge 2 ] || usage
      THRESHOLD="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

[[ "$THRESHOLD" =~ ^[0-9]+$ ]] || fail "Threshold must be a non-negative integer"
[ -d "$PROJECT_DIR" ] || fail "Project directory not found: $PROJECT_DIR"

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"
TASK_FILE="${PROJECT_DIR}/nexum/active-tasks.json"

NOTIFY_TARGET=""
NOTIFY_TARGET_READY=0

resolve_notify_target() {
  if [ "$NOTIFY_TARGET_READY" -eq 1 ]; then
    printf '%s\n' "$NOTIFY_TARGET"
    return 0
  fi

  NOTIFY_TARGET="$(
    NEXUM_PROJECT_DIR="$PROJECT_DIR" "$SCRIPT_DIR/swarm-config.sh" get notify.target 2>/dev/null || printf '/dev/null'
  )"
  if [ -z "$NOTIFY_TARGET" ] || [ "$NOTIFY_TARGET" = "null" ]; then
    NOTIFY_TARGET="/dev/null"
  fi
  NOTIFY_TARGET_READY=1
  printf '%s\n' "$NOTIFY_TARGET"
}

send_notification() {
  local message="$1"
  local target

  target="$(resolve_notify_target)"
  if [ "$target" = "/dev/null" ]; then
    return 0
  fi

  openclaw message send --channel telegram --target "$target" -m "$message" >/dev/null 2>&1 || true
}

minutes_since_updated() {
  local updated_at="$1"

  UPDATED_AT="$updated_at" python3 - <<'PY'
import os
import sys
from datetime import datetime, timezone

updated_at = os.environ["UPDATED_AT"].strip()
if not updated_at:
    print("missing updated_at", file=sys.stderr)
    raise SystemExit(1)

try:
    updated = datetime.fromisoformat(updated_at.replace("Z", "+00:00"))
except ValueError as exc:
    print(f"invalid updated_at: {updated_at}", file=sys.stderr)
    raise SystemExit(1) from exc

now = datetime.now(timezone.utc)
minutes = int((now - updated).total_seconds() / 60)
print(minutes if minutes >= 0 else 0)
PY
}

task_output="$(
  TASK_FILE="$TASK_FILE" python3 - <<'PY'
import json
import os
import sys
from json import JSONDecodeError

task_file = os.environ["TASK_FILE"]

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
    if not isinstance(task, dict):
        continue
    status = task.get("status")
    if status not in {"running", "evaluating"}:
        continue
    session_key = "tmux_session" if status == "running" else "eval_tmux_session"
    values = [
        str(task.get("id", "")),
        status,
        str(task.get(session_key) or ""),
        str(task.get("updated_at") or ""),
    ]
    print("\t".join(values))
PY
)"

task_records=()
if [ -n "$task_output" ]; then
  while IFS= read -r line; do
    task_records+=("$line")
  done <<EOF
$task_output
EOF
fi

if [ "${#task_records[@]}" -eq 0 ]; then
  echo "✅ All tasks healthy (no running tasks)"
  exit 0
fi

checked_count=0
ok_count=0
stuck_count=0
dead_count=0
summary_lines=()

for record in "${task_records[@]}"; do
  [ -n "$record" ] || continue

  IFS=$'\t' read -r task_id task_status session_name updated_at <<<"$record"
  [ -n "$task_id" ] || fail "Encountered running task without id"

  checked_count=$((checked_count + 1))
  session_label="${session_name:-<missing session>}"

  if [ -z "$session_name" ] || ! tmux has-session -t "$session_name" 2>/dev/null; then
    "$SCRIPT_DIR/update-task-status.sh" "$task_id" failed "last_error=session_dead"
    send_notification "⚠️ ${task_id} agent session 已消失（${session_label} not found），任务标记为 failed"
    summary_lines+=("❌ ${task_id}: ${session_label} DEAD — marked failed")
    dead_count=$((dead_count + 1))
    continue
  fi

  if ! minutes_ago="$(minutes_since_updated "$updated_at")"; then
    fail "Failed to parse updated_at for ${task_id}: ${updated_at}"
  fi

  if [ "$minutes_ago" -gt "$THRESHOLD" ]; then
    send_notification "⚠️ ${task_id} 疑似卡死：${session_name} 已 ${minutes_ago} 分钟无响应，请检查 tmux capture-pane -t ${session_name} -p"
    summary_lines+=("⚠️  ${task_id}: ${session_name} STUCK (updated ${minutes_ago}m ago) — notified")
    stuck_count=$((stuck_count + 1))
  else
    summary_lines+=("✅ ${task_id}: ${session_name} OK (updated ${minutes_ago}m ago)")
    ok_count=$((ok_count + 1))
  fi
done

echo "=== OpenNexum Health Check ==="
for line in "${summary_lines[@]}"; do
  echo "$line"
done
echo "==="
echo "Total: ${checked_count} checked, ${ok_count} ok, ${stuck_count} stuck, ${dead_count} dead"

if [ "$stuck_count" -gt 0 ] || [ "$dead_count" -gt 0 ]; then
  exit 1
fi

exit 0
