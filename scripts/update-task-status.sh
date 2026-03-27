#!/bin/bash
# Atomically update a task in active-tasks.json and unlock downstream dependencies.
set -euo pipefail

PROJECT_DIR="${NEXUM_PROJECT_DIR:-$(pwd -P)}"
TASK_FILE="${PROJECT_DIR}/nexum/active-tasks.json"

usage() {
  echo "Usage: update-task-status.sh <task_id> <status> [--output-batch-done] [key=value ...]" >&2
  exit 1
}

[ "$#" -ge 2 ] || usage

TASK_ID="$1"
STATUS="$2"
shift 2

OUTPUT_BATCH_DONE=0
FIELD_ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--output-batch-done" ]; then
    OUTPUT_BATCH_DONE=1
    continue
  fi
  FIELD_ARGS+=("$arg")
done

LOCK_FILE="${TASK_FILE}.lock"
mkdir -p "$(dirname "$TASK_FILE")"

run_update() {
  TASK_FILE="$TASK_FILE" LOCK_FILE="${LOCK_FILE:-}" OUTPUT_BATCH_DONE="$OUTPUT_BATCH_DONE" python3 - "$TASK_ID" "$STATUS" "$@" <<'PY'
import json
import os
import sys
import tempfile
import fcntl
from datetime import datetime, timezone
from json import JSONDecodeError

TASK_FILE = os.environ["TASK_FILE"]
LOCK_FILE = os.environ.get("LOCK_FILE")
OUTPUT_BATCH_DONE = os.environ.get("OUTPUT_BATCH_DONE") == "1"
TASK_ID = sys.argv[1]
STATUS = sys.argv[2]
RAW_FIELDS = sys.argv[3:]

VALID_STATUSES = {
    "pending",
    "blocked",
    "running",
    "evaluating",
    "done",
    "failed",
    "escalated",
    "cancelled",
}
ALLOWED_FIELDS = {
    "base_commit",
    "commit_hash",
    "tmux_session",
    "eval_tmux_session",
    "eval_result_path",
    "started_at",
    "completed_at",
    "last_error",
    "iteration",
}


def fail(message, code=1):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def parse_field(raw):
    if raw == "--field":
        return None
    if "=" not in raw:
        fail(f"Invalid field assignment: {raw}")
    key, value = raw.split("=", 1)
    if key not in ALLOWED_FIELDS:
        fail(f"Unsupported field: {key}")
    if key == "iteration":
        try:
            return key, int(value)
        except ValueError as exc:
            fail("iteration must be an integer")
            raise exc
    if value == "null":
        return key, None
    return key, value


if STATUS not in VALID_STATUSES:
    fail(f"Invalid status: {STATUS}")

fields = {}
for raw_field in RAW_FIELDS:
    parsed = parse_field(raw_field)
    if parsed is None:
        continue
    key, value = parsed
    fields[key] = value

def load_data():
    try:
        with open(TASK_FILE, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        fail(f"Task file not found: {TASK_FILE}")
    except JSONDecodeError as exc:
        fail(f"Invalid JSON in {TASK_FILE}: {exc}")

    if not isinstance(data, dict) or not isinstance(data.get("tasks"), list):
        fail(f"Invalid task file structure: {TASK_FILE}")
    return data


def write_data(data):
    directory = os.path.dirname(TASK_FILE)
    fd, tmp_path = tempfile.mkstemp(prefix=".active-tasks.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_path, TASK_FILE)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)


def update_task_file():
    data = load_data()
    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    tasks = data["tasks"]
    task_by_id = {task.get("id"): task for task in tasks if isinstance(task, dict) and "id" in task}

    target = task_by_id.get(TASK_ID)
    if target is None:
        raise SystemExit(2)

    if STATUS == "running":
        new_tmux_session = fields.get("tmux_session")
        if new_tmux_session:
            for other in tasks:
                if not isinstance(other, dict) or other.get("id") == TASK_ID:
                    continue
                if other.get("status") == "running" and other.get("tmux_session") == new_tmux_session:
                    fail(
                        f"Conflict: task {other.get('id', '<unknown>')} already running on {new_tmux_session}",
                        code=2,
                    )

    target["status"] = STATUS
    target["updated_at"] = now
    for key, value in fields.items():
        target[key] = value

    if STATUS == "done":
        for task in tasks:
            if not isinstance(task, dict) or task.get("status") != "blocked":
                continue
            depends_on = task.get("depends_on") or []
            if not isinstance(depends_on, list):
                continue
            dependency_statuses = [task_by_id.get(dep_id, {}).get("status") for dep_id in depends_on]
            if dependency_statuses and any(status in {"escalated", "cancelled"} for status in dependency_statuses):
                task["status"] = "escalated"
                task["updated_at"] = now
            elif all(status == "done" for status in dependency_statuses):
                task["status"] = "pending"
                task["updated_at"] = now

    write_data(data)
    return all(
        isinstance(task, dict) and task.get("status") == "done"
        for task in tasks
    ) if STATUS == "done" and tasks else False


if LOCK_FILE:
    with open(LOCK_FILE, "a+", encoding="utf-8") as lock_handle:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        batch_done = update_task_file()
else:
    batch_done = update_task_file()

if OUTPUT_BATCH_DONE and batch_done:
    print("BATCH_DONE=true")
PY
}

if command -v flock >/dev/null 2>&1; then
  (
    flock -x 200
    LOCK_FILE="" run_update "${FIELD_ARGS[@]}"
  ) 200>"$LOCK_FILE"
else
  LOCK_FILE="$LOCK_FILE" run_update "${FIELD_ARGS[@]}"
fi
