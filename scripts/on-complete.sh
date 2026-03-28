#!/bin/bash
# Unified completion callback for generator/evaluator workers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
PROJECT_DIR="${NEXUM_PROJECT_DIR:-$(pwd -P)}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"
ACTIVE_TASKS_FILE="${PROJECT_DIR}/nexum/active-tasks.json"
EVENTS_FILE="${PROJECT_DIR}/nexum/events.jsonl"
UPDATE_TASK_STATUS_SCRIPT="${SCRIPT_DIR}/update-task-status.sh"
DISPATCH_SCRIPT="${SCRIPT_DIR}/dispatch.sh"
DISPATCH_EVALUATOR_SCRIPT="${SCRIPT_DIR}/dispatch-evaluator.sh"
SWARM_CONFIG_SCRIPT="${SCRIPT_DIR}/swarm-config.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  on-complete.sh <task_id> <exit_code> --role <generator|evaluator>
EOF
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

resolve_config_value() {
  local path="$1"
  NEXUM_PROJECT_DIR="$PROJECT_DIR" "$SWARM_CONFIG_SCRIPT" resolve "$path" 2>/dev/null || true
}

resolve_notify_target() {
  local target
  target="$(resolve_config_value "notify.target")"
  if [ -z "$target" ] || [ "$target" = "null" ]; then
    printf '%s\n' "/dev/null"
    return 0
  fi
  printf '%s\n' "$target"
}

send_notification() {
  local message="$1"
  local target

  target="$(resolve_notify_target)"
  if [ "$target" = "/dev/null" ]; then
    return 0
  fi
  if ! command -v openclaw >/dev/null 2>&1; then
    return 0
  fi

  openclaw message send --channel telegram --target "$target" -m "$message" >/dev/null 2>&1 || true
}

send_system_event() {
  local text="$1"
  if ! command -v openclaw >/dev/null 2>&1; then
    return 0
  fi
  openclaw system event --mode now --text "$text" >/dev/null 2>&1 || true
}

send_formatted_notification() {
  local title="$1"
  local body="$2"
  send_notification "$(printf '%s\n%s\n%s' "$title" "━━━━━━━━━━━━━━━" "$body")"
}

append_event() {
  local event_name="$1"

  mkdir -p "$(dirname "$EVENTS_FILE")"
  EVENT_NAME="$event_name" EVENTS_FILE="$EVENTS_FILE" TASK_ID="$TASK_ID" python3 - <<'PY'
import fcntl
import json
import os
from datetime import datetime, timezone

events_file = os.environ["EVENTS_FILE"]
task_id = os.environ["TASK_ID"]
event_name = os.environ["EVENT_NAME"]


def maybe_set(payload, key, env_key):
    value = os.environ.get(env_key, "")
    if value == "":
        return
    payload[key] = value


def maybe_set_int(payload, key, env_key):
    value = os.environ.get(env_key, "")
    if value == "":
        return
    payload[key] = int(value)


def maybe_set_json(payload, key, env_key):
    value = os.environ.get(env_key, "")
    if value == "":
        return
    payload[key] = json.loads(value)


payload = {
    "event": event_name,
    "task_id": task_id,
    "ts": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}

maybe_set(payload, "role", "EVENT_ROLE")
maybe_set(payload, "reason", "EVENT_REASON")
maybe_set(payload, "verdict", "EVENT_VERDICT")
maybe_set(payload, "commit_hash", "EVENT_COMMIT_HASH")
maybe_set(payload, "completed_at", "EVENT_COMPLETED_AT")
maybe_set(payload, "batch_id", "EVENT_BATCH_ID")
maybe_set(payload, "feedback", "EVENT_FEEDBACK")
maybe_set_int(payload, "iteration", "EVENT_ITERATION")
maybe_set_int(payload, "next_iteration", "EVENT_NEXT_ITERATION")
maybe_set_int(payload, "exit_code", "EVENT_EXIT_CODE")
maybe_set_int(payload, "max_iterations", "EVENT_MAX_ITERATIONS")
maybe_set_json(payload, "extra_files", "EVENT_FILES_JSON")
maybe_set_json(payload, "system_errors", "EVENT_SYSTEM_ERRORS_JSON")

directory = os.path.dirname(events_file)
if directory:
    os.makedirs(directory, exist_ok=True)

with open(events_file, "a", encoding="utf-8") as handle:
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    handle.write(json.dumps(payload, ensure_ascii=False))
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
PY
}

event_exists() {
  local event_name="$1"
  local iteration="${2:-}"
  EVENT_NAME="$event_name" EVENTS_FILE="$EVENTS_FILE" TASK_ID="$TASK_ID" EVENT_ITERATION="${iteration}" python3 - <<'PY'
import json
import os
import sys

events_file = os.environ["EVENTS_FILE"]
event_name = os.environ["EVENT_NAME"]
task_id = os.environ["TASK_ID"]
iteration = os.environ.get("EVENT_ITERATION", "")

try:
    with open(events_file, "r", encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.strip()
            if not raw:
                continue
            try:
                item = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if item.get("event") != event_name or item.get("task_id") != task_id:
                continue
            if iteration:
                if str(item.get("iteration")) != iteration:
                    continue
            raise SystemExit(0)
except FileNotFoundError:
    pass

raise SystemExit(1)
PY
}

json_value() {
  local json_payload="$1"
  local json_path="$2"
  JSON_PAYLOAD="$json_payload" JSON_PATH="$json_path" python3 - <<'PY'
import json
import os
import sys

payload = json.loads(os.environ["JSON_PAYLOAD"])
path = [segment for segment in os.environ["JSON_PATH"].split(".") if segment]

value = payload
for segment in path:
    if not isinstance(value, dict) or segment not in value:
        raise SystemExit(1)
    value = value[segment]

if value is None:
    raise SystemExit(0)
if isinstance(value, str):
    sys.stdout.write(value)
else:
    sys.stdout.write(json.dumps(value, ensure_ascii=False))
PY
}

json_array_lines() {
  local json_payload="$1"
  local json_path="$2"
  JSON_PAYLOAD="$json_payload" JSON_PATH="$json_path" python3 - <<'PY'
import json
import os
import sys

payload = json.loads(os.environ["JSON_PAYLOAD"])
path = [segment for segment in os.environ["JSON_PATH"].split(".") if segment]

value = payload
for segment in path:
    if not isinstance(value, dict) or segment not in value:
        raise SystemExit(1)
    value = value[segment]

if not isinstance(value, list):
    raise SystemExit(1)

for item in value:
    if isinstance(item, str):
        print(item)
    else:
        print(json.dumps(item, ensure_ascii=False))
PY
}

build_json_array() {
  python3 - "$@" <<'PY'
import json
import sys

items = [item for item in sys.argv[1:] if item]
sys.stdout.write(json.dumps(items, ensure_ascii=False))
PY
}

format_duration() {
  local started_at="$1"
  local ended_at="$2"
  STARTED_AT="$started_at" ENDED_AT="$ended_at" python3 - <<'PY'
import os
from datetime import datetime

started = os.environ["STARTED_AT"].strip()
ended = os.environ["ENDED_AT"].strip()

if not started or not ended:
    print("unknown")
    raise SystemExit(0)

try:
    start_dt = datetime.fromisoformat(started.replace("Z", "+00:00"))
    end_dt = datetime.fromisoformat(ended.replace("Z", "+00:00"))
except ValueError:
    print("unknown")
    raise SystemExit(0)

seconds = int((end_dt - start_dt).total_seconds())
if seconds < 0:
    seconds = 0

hours, remainder = divmod(seconds, 3600)
minutes, secs = divmod(remainder, 60)
parts = []
if hours:
    parts.append(f"{hours}h")
if minutes:
    parts.append(f"{minutes}m")
if secs or not parts:
    parts.append(f"{secs}s")
print(" ".join(parts))
PY
}

format_bullet_list() {
  local raw="$1"
  BULLET_TEXT="$raw" python3 - <<'PY'
import os

lines = [line.strip() for line in os.environ["BULLET_TEXT"].splitlines() if line.strip()]
if not lines:
    print("- none")
else:
    print("\n".join(f"- {line}" for line in lines))
PY
}

summarize_text() {
  local text="$1"
  local limit="${2:-200}"
  TEXT_TO_SUMMARIZE="$text" TEXT_LIMIT="$limit" python3 - <<'PY'
import os

text = os.environ["TEXT_TO_SUMMARIZE"].replace("\n", " ").replace("\r", " ").strip()
limit = int(os.environ["TEXT_LIMIT"])
print(text[:limit])
PY
}

get_progress_summary() {
  ACTIVE_TASKS_FILE="$ACTIVE_TASKS_FILE" python3 - <<'PY'
import json
import os
from json import JSONDecodeError

task_file = os.environ["ACTIVE_TASKS_FILE"]

try:
    with open(task_file, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except (FileNotFoundError, JSONDecodeError):
    print("0 done | 0 running | 0 blocked | 0 pending")
    raise SystemExit(0)

tasks = data.get("tasks")
if not isinstance(tasks, list):
    print("0 done | 0 running | 0 blocked | 0 pending")
    raise SystemExit(0)

counts = {
    "done": 0,
    "running": 0,
    "blocked": 0,
    "pending": 0,
}

for task in tasks:
    if not isinstance(task, dict):
        continue
    status = task.get("status")
    if status in counts:
        counts[status] += 1

print(
    f"{counts['done']} done | "
    f"{counts['running']} running | "
    f"{counts['blocked']} blocked | "
    f"{counts['pending']} pending"
)
PY
}

get_unlocked_tasks() {
  local completed_task_id="$1"
  ACTIVE_TASKS_FILE="$ACTIVE_TASKS_FILE" COMPLETED_TASK_ID="$completed_task_id" python3 - <<'PY'
import json
import os
from json import JSONDecodeError

task_file = os.environ["ACTIVE_TASKS_FILE"]
completed_task_id = os.environ["COMPLETED_TASK_ID"]

try:
    with open(task_file, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except (FileNotFoundError, JSONDecodeError):
    raise SystemExit(0)

tasks = data.get("tasks")
if not isinstance(tasks, list):
    raise SystemExit(0)

for task in tasks:
    if not isinstance(task, dict):
        continue
    depends_on = task.get("depends_on")
    if not isinstance(depends_on, list) or completed_task_id not in depends_on:
        continue
    if task.get("status") != "pending":
        continue
    task_id = str(task.get("id") or "?")
    name = str(task.get("name") or task_id)
    print(f"{task_id} | {name}")
PY
}

get_failed_criteria() {
  local result_path="$1"
  RESULT_PATH="$result_path" YAML_TO_JSON_SCRIPT="$SCRIPT_DIR/yaml-to-json.sh" python3 - <<'PY'
import json
import os
import subprocess
from json import JSONDecodeError

result_path = os.environ["RESULT_PATH"]
yaml_to_json_script = os.environ["YAML_TO_JSON_SCRIPT"]

result = subprocess.run([yaml_to_json_script, result_path], capture_output=True, text=True)
if result.returncode != 0:
    raise SystemExit(0)

try:
    payload = json.loads(result.stdout)
except JSONDecodeError:
    raise SystemExit(0)

strategy_results = payload.get("strategy_results")
if not isinstance(strategy_results, list):
    raise SystemExit(0)

for strategy in strategy_results:
    if not isinstance(strategy, dict):
        continue
    criteria_results = strategy.get("criteria_results")
    if not isinstance(criteria_results, list):
        continue
    for criterion in criteria_results:
        if not isinstance(criterion, dict):
            continue
        if criterion.get("result") != "fail":
            continue
        criterion_id = criterion.get("id")
        if criterion_id not in (None, ""):
            print(criterion_id)
PY
}

all_tasks_done_json() {
  ACTIVE_TASKS_FILE="$ACTIVE_TASKS_FILE" PROJECT_DIR="$PROJECT_DIR" python3 - <<'PY'
import json
import os
from json import JSONDecodeError

task_file = os.environ["ACTIVE_TASKS_FILE"]
project_dir = os.environ["PROJECT_DIR"]


def duration_parts(started_at, completed_at):
    from datetime import datetime

    if not isinstance(started_at, str) or not started_at.strip():
        return None, "unknown"
    if not isinstance(completed_at, str) or not completed_at.strip():
        return None, "unknown"

    try:
        start_dt = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
        end_dt = datetime.fromisoformat(completed_at.replace("Z", "+00:00"))
    except ValueError:
        return None, "unknown"

    seconds = int((end_dt - start_dt).total_seconds())
    if seconds < 0:
        seconds = 0

    hours, remainder = divmod(seconds, 3600)
    minutes, secs = divmod(remainder, 60)
    parts = []
    if hours:
        parts.append(f"{hours}h")
    if minutes:
        parts.append(f"{minutes}m")
    if secs or not parts:
        parts.append(f"{secs}s")
    return seconds, " ".join(parts)


def format_total_duration(total_seconds, known_duration_count):
    if known_duration_count == 0:
        return "unknown"

    hours, remainder = divmod(total_seconds, 3600)
    minutes, secs = divmod(remainder, 60)
    parts = []
    if hours:
        parts.append(f"{hours}h")
    if minutes:
        parts.append(f"{minutes}m")
    if secs or not parts:
        parts.append(f"{secs}s")
    return " ".join(parts)

try:
    with open(task_file, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except (FileNotFoundError, JSONDecodeError):
    print("{}")
    raise SystemExit(0)

tasks = data.get("tasks")
if not isinstance(tasks, list):
    print("{}")
    raise SystemExit(0)

done_count = sum(1 for task in tasks if isinstance(task, dict) and task.get("status") == "done")
total_count = sum(1 for task in tasks if isinstance(task, dict))
all_done = total_count > 0 and done_count == total_count
task_summaries = []
total_duration_seconds = 0
known_duration_count = 0
total_iterations = 0

for task in tasks:
    if not isinstance(task, dict):
        continue
    task_id = str(task.get("id") or "?")
    task_name = str(task.get("name") or task_id)
    task_status = str(task.get("status") or "unknown")
    duration_seconds, duration_text = duration_parts(task.get("started_at"), task.get("completed_at"))
    if duration_seconds is not None:
        total_duration_seconds += duration_seconds
        known_duration_count += 1
    iteration = task.get("iteration")
    total_iterations += max(iteration, 0) + 1 if isinstance(iteration, int) else 1
    task_summaries.append(f"{task_id} | {task_name} | {task_status} | {duration_text}")

print(json.dumps({
    "all_done": all_done,
    "batch_id": data.get("batch_id"),
    "project": data.get("project") or os.path.basename(project_dir),
    "done_count": done_count,
    "total_count": total_count,
    "task_summaries": task_summaries,
    "total_estimated_duration": format_total_duration(total_duration_seconds, known_duration_count),
    "total_iterations": total_iterations,
}, ensure_ascii=False))
PY
}

load_task_context() {
  TASK_ID="$1" PROJECT_DIR="$PROJECT_DIR" ACTIVE_TASKS_FILE="$ACTIVE_TASKS_FILE" YAML_TO_JSON_SCRIPT="$SCRIPT_DIR/yaml-to-json.sh" python3 - <<'PY'
import json
import os
import subprocess
import sys
from json import JSONDecodeError

task_id = os.environ["TASK_ID"]
project_dir = os.environ["PROJECT_DIR"]
active_tasks_file = os.environ["ACTIVE_TASKS_FILE"]
yaml_to_json_script = os.environ["YAML_TO_JSON_SCRIPT"]


def fail(message, code=1):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def load_yaml(path):
    result = subprocess.run([yaml_to_json_script, path], capture_output=True, text=True)
    if result.returncode != 0:
        fail(result.stderr.strip() or f"Failed to parse YAML: {path}")
    try:
        data = json.loads(result.stdout)
    except JSONDecodeError as exc:
        fail(f"Invalid JSON from {yaml_to_json_script}: {exc}")
    if not isinstance(data, dict):
        fail(f"YAML root must be a mapping: {path}")
    return data


try:
    with open(active_tasks_file, "r", encoding="utf-8") as handle:
        active_data = json.load(handle)
except FileNotFoundError:
    fail(f"Task file not found: {active_tasks_file}")
except JSONDecodeError as exc:
    fail(f"Invalid JSON in {active_tasks_file}: {exc}")

tasks = active_data.get("tasks")
if not isinstance(tasks, list):
    fail(f"Invalid task file structure: {active_tasks_file}")

task = None
for candidate in tasks:
    if isinstance(candidate, dict) and candidate.get("id") == task_id:
        task = candidate
        break

if task is None:
    fail(f"Task not found in active-tasks.json: {task_id}")

contract_path = task.get("contract_path")
if not isinstance(contract_path, str) or not contract_path:
    fail(f"Task {task_id} missing contract_path")

contract_file = contract_path
if not os.path.isabs(contract_file):
    contract_file = os.path.join(project_dir, contract_file)
contract_file = os.path.normpath(contract_file)
contract = load_yaml(contract_file)

iteration = task.get("iteration")
if not isinstance(iteration, int):
    iteration = 0

max_iterations = contract.get("max_iterations")
if not isinstance(max_iterations, int):
    max_iterations = 1

eval_result_path = os.path.join(project_dir, "nexum", "runtime", "eval", f"{task_id}-iter-{iteration}.yaml")

payload = {
    "batch_id": active_data.get("batch_id"),
    "task": task,
    "contract": contract,
    "eval_result_path": eval_result_path,
}
print(json.dumps(payload, ensure_ascii=False))
PY
}

load_eval_result() {
  local result_path="$1"
  RESULT_PATH="$result_path" YAML_TO_JSON_SCRIPT="$SCRIPT_DIR/yaml-to-json.sh" python3 - <<'PY'
import json
import os
import subprocess
import sys

result_path = os.environ["RESULT_PATH"]
yaml_to_json_script = os.environ["YAML_TO_JSON_SCRIPT"]


def fail(message, code=1):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def load_yaml(path):
    result = subprocess.run([yaml_to_json_script, path], capture_output=True, text=True)
    if result.returncode != 0:
        fail(result.stderr.strip() or f"Failed to parse YAML: {path}")
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        fail(f"Invalid JSON from {yaml_to_json_script}: {exc}")
    if not isinstance(data, dict):
        fail(f"YAML root must be a mapping: {path}")
    return data


result = load_yaml(result_path)
system_errors = result.get("system_errors")
if not isinstance(system_errors, list):
    system_errors = []

strategy_results = result.get("strategy_results")
if not isinstance(strategy_results, list):
    strategy_results = []

total_count = 0
pass_count = 0
for strategy in strategy_results:
    if not isinstance(strategy, dict):
        continue
    criteria = strategy.get("criteria_results")
    if not isinstance(criteria, list):
        continue
    for item in criteria:
        if not isinstance(item, dict):
            continue
        total_count += 1
        if item.get("result") == "pass":
            pass_count += 1

feedback = result.get("feedback")
if not isinstance(feedback, str):
    feedback = ""

payload = {
    "verdict": result.get("verdict"),
    "feedback": feedback,
    "system_errors": system_errors,
    "pass_count": pass_count,
    "total_count": total_count,
}
print(json.dumps(payload, ensure_ascii=False))
PY
}

build_agent_command() {
  local agent="$1"
  local cli

  cli="$(resolve_config_value "agents.${agent}.cli")"

  if [ -z "$cli" ] || [ "$cli" = "null" ]; then
    cli="codex"
  fi

  AGENT_COMMAND=()
  case "$cli" in
    codex)
      AGENT_COMMAND=(codex exec -c model_reasoning_effort=high --dangerously-bypass-approvals-and-sandbox)
      ;;
    claude)
      AGENT_COMMAND=(claude --model claude-sonnet-4-6 --permission-mode bypassPermissions --no-session-persistence --print --output-format json)
      ;;
    *)
      fail "Unsupported CLI '${cli}' for agent '${agent}'"
      ;;
  esac
}

build_retry_prompt() {
  local context_json="$1"
  local verdict="$2"
  local feedback="$3"
  local system_errors_json="$4"
  local next_iteration="$5"
  local prompt_file="/tmp/nexum-feedback-${TASK_ID}.txt"
  local generator_template="${SKILL_ROOT}/references/prompt-generator-coding.md"

  CONTEXT_JSON="$context_json" \
  VERDICT="$verdict" \
  FEEDBACK="$feedback" \
  SYSTEM_ERRORS_JSON="$system_errors_json" \
  NEXT_ITERATION="$next_iteration" \
  GENERATOR_TEMPLATE="$generator_template" \
  PROMPT_FILE="$prompt_file" \
  python3 - <<'PY'
import json
import os

context = json.loads(os.environ["CONTEXT_JSON"])
verdict = os.environ["VERDICT"]
feedback = os.environ["FEEDBACK"]
system_errors = json.loads(os.environ["SYSTEM_ERRORS_JSON"])
next_iteration = os.environ["NEXT_ITERATION"]
generator_template = os.environ["GENERATOR_TEMPLATE"]
prompt_file = os.environ["PROMPT_FILE"]

task = context.get("task", {}) if isinstance(context.get("task"), dict) else {}
contract = context.get("contract", {}) if isinstance(context.get("contract"), dict) else {}
scope = contract.get("scope", {}) if isinstance(contract.get("scope"), dict) else {}
eval_strategy = contract.get("eval_strategy", {}) if isinstance(contract.get("eval_strategy"), dict) else {}
contract_type = contract.get("type") or "coding"
if contract_type in ("creative", "task"):
    writing_template = os.path.join(os.path.dirname(generator_template), "prompt-generator-writing.md")
    if os.path.exists(writing_template):
        generator_template = writing_template


def as_list(value):
    return value if isinstance(value, list) else []


def bullet_lines(items):
    values = [str(item) for item in items if item not in (None, "")]
    return "\n".join(f"- {value}" for value in values) if values else "- none"


def criteria_lines(criteria):
    rendered = []
    for item in criteria:
        if not isinstance(item, dict):
            continue
        criterion_id = item.get("id", "?")
        desc = str(item.get("desc", "")).strip()
        method = str(item.get("method", "")).strip()
        threshold = item.get("threshold")
        line = f"- [{criterion_id}] {desc}".rstrip()
        details = []
        if method:
            details.append(f"method: {method}")
        if threshold not in (None, ""):
            details.append(f"threshold: {threshold}")
        if details:
            line = f"{line} ({'; '.join(details)})"
        rendered.append(line)
    return "\n".join(rendered) if rendered else "- none"


base_prompt = ""
if os.path.exists(generator_template):
    with open(generator_template, "r", encoding="utf-8") as handle:
        base_prompt = handle.read().strip()

retry_block = f"""
## Retry Context

This is a retry after evaluator verdict `{verdict}`.
Task iteration should now target: {next_iteration}

### Deliverables
{bullet_lines(as_list(contract.get("deliverables")))}

### Scope Files
{bullet_lines(as_list(scope.get("files")))}

### Evaluation Criteria
{criteria_lines(as_list(eval_strategy.get("criteria")))}

### Evaluator Feedback
{feedback or "(empty)"}
""".strip()

if system_errors:
    retry_block += "\n\n### System Errors\n" + "\n".join(f"- {item}" for item in system_errors)

rendered = retry_block if not base_prompt else base_prompt + "\n\n---\n\n" + retry_block

with open(prompt_file, "w", encoding="utf-8") as handle:
    # TODO(Phase 3): inject relevant lessons from docs/lessons/ filtered by task tags
    # For now, RELEVANT_LESSONS is intentionally left empty
    handle.write(rendered)
    if not rendered.endswith("\n"):
        handle.write("\n")
PY

  printf '%s\n' "$prompt_file"
}

[ "$#" -ge 4 ] || usage
TASK_ID="$1"
EXIT_CODE="$2"
shift 2

ROLE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --role)
      [ "$#" -ge 2 ] || usage
      ROLE="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

case "$ROLE" in
  generator|evaluator) ;;
  *) usage ;;
esac

[[ "$EXIT_CODE" =~ ^-?[0-9]+$ ]] || fail "exit_code must be an integer"
[ -f "$ACTIVE_TASKS_FILE" ] || fail "Task file not found: $ACTIVE_TASKS_FILE"
[ -x "$UPDATE_TASK_STATUS_SCRIPT" ] || fail "Missing required script: $UPDATE_TASK_STATUS_SCRIPT"
[ -x "$DISPATCH_SCRIPT" ] || fail "Missing required script: $DISPATCH_SCRIPT"
[ -x "$SWARM_CONFIG_SCRIPT" ] || fail "Missing required script: $SWARM_CONFIG_SCRIPT"

CONTEXT_JSON="$(load_task_context "$TASK_ID")"
ITERATION="$(json_value "$CONTEXT_JSON" "task.iteration" || true)"
if [ -z "$ITERATION" ]; then
  ITERATION="0"
fi
CONTRACT_PATH="$(json_value "$CONTEXT_JSON" "task.contract_path" || true)"
TASK_NAME="$(json_value "$CONTEXT_JSON" "contract.name" || true)"
STARTED_AT="$(json_value "$CONTEXT_JSON" "task.started_at" || true)"
COMMIT_HASH="$(json_value "$CONTEXT_JSON" "task.commit_hash" || true)"
GENERATOR_AGENT="$(json_value "$CONTEXT_JSON" "contract.generator" || true)"
MAX_ITERATIONS="$(json_value "$CONTEXT_JSON" "contract.max_iterations" || true)"
EVAL_RESULT_PATH="$(json_value "$CONTEXT_JSON" "eval_result_path" || true)"
if [ -z "$MAX_ITERATIONS" ]; then
  MAX_ITERATIONS="1"
fi

if [ "$ROLE" = "generator" ]; then
  if [ "$EXIT_CODE" -ne 0 ]; then
    NEXUM_PROJECT_DIR="$PROJECT_DIR" "$UPDATE_TASK_STATUS_SCRIPT" \
      "$TASK_ID" \
      failed \
      "last_error=exit ${EXIT_CODE}"
    EVENT_ROLE="generator" EVENT_EXIT_CODE="$EXIT_CODE" EVENT_REASON="exit_${EXIT_CODE}" append_event "task_failed"
    send_formatted_notification "❌ Generator 执行失败" "任务ID: ${TASK_ID}
任务名: ${TASK_NAME}
角色: generator
退出码: ${EXIT_CODE}"
    exit 0
  fi

  BASE_COMMIT="$(json_value "$CONTEXT_JSON" "task.base_commit" || true)"
  [ -n "$BASE_COMMIT" ] || fail "Task ${TASK_ID} missing base_commit"
  [ -n "$CONTRACT_PATH" ] || fail "Task ${TASK_ID} missing contract_path"

  SCOPE_FILES=()
  while IFS= read -r scope_file; do
    SCOPE_FILES+=("$scope_file")
  done < <(json_array_lines "$CONTEXT_JSON" "contract.scope.files")
  CHANGED_FILES=()
  while IFS= read -r changed_file; do
    CHANGED_FILES+=("$changed_file")
  done < <(git -C "$PROJECT_DIR" diff "${BASE_COMMIT}..HEAD" --name-only)
  VIOLATIONS=()
  for path in "${CHANGED_FILES[@]}"; do
    in_scope=0
    [ -n "$path" ] || continue
    for scope_file in "${SCOPE_FILES[@]}"; do
      if [ "$path" = "$scope_file" ]; then
        in_scope=1
        break
      fi
    done
    if [ "$in_scope" -eq 0 ]; then
      VIOLATIONS+=("$path")
    fi
  done

  if [ "${#VIOLATIONS[@]}" -gt 0 ]; then
    violations_json="$(build_json_array "${VIOLATIONS[@]}")"
    head_commit="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
    NEXUM_PROJECT_DIR="$PROJECT_DIR" "$UPDATE_TASK_STATUS_SCRIPT" \
      "$TASK_ID" \
      failed \
      "last_error=scope_violation"
    EVENT_ROLE="generator" \
      EVENT_REASON="scope_violation" \
      EVENT_FILES_JSON="$violations_json" \
      append_event "task_failed"
    send_formatted_notification "⚠️ Scope 违规，任务已冻结" "任务ID: ${TASK_ID}
任务名: ${TASK_NAME}
违规文件: ${VIOLATIONS[*]}
操作: 执行 nexum-revert.sh ${TASK_ID} 可回滚"
    exit 0
  fi

  head_commit="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
  NEXUM_PROJECT_DIR="$PROJECT_DIR" "$UPDATE_TASK_STATUS_SCRIPT" \
    "$TASK_ID" \
    evaluating \
    "commit_hash=${head_commit}" \
    "eval_result_path=${EVAL_RESULT_PATH}" \
    "last_error=null"

  if [ ! -x "$DISPATCH_EVALUATOR_SCRIPT" ]; then
    NEXUM_PROJECT_DIR="$PROJECT_DIR" "$UPDATE_TASK_STATUS_SCRIPT" \
      "$TASK_ID" \
      failed \
      "last_error=dispatch_evaluator_missing"
    EVENT_ROLE="generator" EVENT_REASON="dispatch_evaluator_missing" append_event "task_failed"
    send_formatted_notification "❌ Evaluator 派发失败" "任务ID: ${TASK_ID}
任务名: ${TASK_NAME}
原因: 缺少 dispatch-evaluator.sh"
    exit 0
  fi

  if ! NEXUM_PROJECT_DIR="$PROJECT_DIR" "$DISPATCH_EVALUATOR_SCRIPT" "$TASK_ID"; then
    NEXUM_PROJECT_DIR="$PROJECT_DIR" "$UPDATE_TASK_STATUS_SCRIPT" \
      "$TASK_ID" \
      failed \
      "last_error=dispatch_evaluator_failed"
    EVENT_ROLE="generator" EVENT_REASON="dispatch_evaluator_failed" append_event "task_failed"
    send_formatted_notification "❌ Evaluator 派发失败" "任务ID: ${TASK_ID}
任务名: ${TASK_NAME}
状态: generator 已完成，但 evaluator 启动失败"
    send_system_event "eval_dispatch_failed: ${TASK_ID}"
    exit 0
  fi

  if ! event_exists "eval_started" "$ITERATION"; then
    EVENT_ROLE="generator" EVENT_ITERATION="$ITERATION" EVENT_COMMIT_HASH="$head_commit" append_event "eval_started"
  fi
  send_system_event "eval_started: ${TASK_ID}"
  send_formatted_notification "🔍 开始评估" "任务ID: ${TASK_ID}
任务名: ${TASK_NAME}
当前迭代: ${ITERATION}
commit: ${head_commit}"
  exit 0
fi

if [ ! -f "$EVAL_RESULT_PATH" ]; then
  NEXUM_PROJECT_DIR="$PROJECT_DIR" "$UPDATE_TASK_STATUS_SCRIPT" \
    "$TASK_ID" \
    failed \
    "last_error=eval_result_missing"
  EVENT_ROLE="evaluator" EVENT_REASON="eval_result_missing" EVENT_ITERATION="$ITERATION" EVENT_EXIT_CODE="$EXIT_CODE" append_event "task_failed"
  send_formatted_notification "❌ Evaluator 结果缺失" "任务ID: ${TASK_ID}
任务名: ${TASK_NAME}
期望路径: ${EVAL_RESULT_PATH}
evaluator exit: ${EXIT_CODE}"
  send_system_event "eval_result_missing: ${TASK_ID}"
  exit 0
fi

EVAL_JSON="$(load_eval_result "$EVAL_RESULT_PATH")"
VERDICT="$(json_value "$EVAL_JSON" "verdict" || true)"
FEEDBACK="$(json_value "$EVAL_JSON" "feedback" || true)"
SYSTEM_ERRORS_JSON="$(json_value "$EVAL_JSON" "system_errors" || true)"
PASS_COUNT="$(json_value "$EVAL_JSON" "pass_count" || true)"
TOTAL_COUNT="$(json_value "$EVAL_JSON" "total_count" || true)"
if [ -z "$SYSTEM_ERRORS_JSON" ]; then
  SYSTEM_ERRORS_JSON="[]"
fi
if [ -z "$PASS_COUNT" ]; then
  PASS_COUNT="0"
fi
if [ -z "$TOTAL_COUNT" ]; then
  TOTAL_COUNT="0"
fi
if [ -z "$VERDICT" ]; then
  VERDICT="error"
fi

case "$VERDICT" in
  pass)
    completed_at="$(timestamp_utc)"
    if [ -z "$COMMIT_HASH" ]; then
      COMMIT_HASH="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
    fi
    update_status_output="$(
      NEXUM_PROJECT_DIR="$PROJECT_DIR" "$UPDATE_TASK_STATUS_SCRIPT" \
        "$TASK_ID" \
        done \
        --output-batch-done \
        "completed_at=${completed_at}" \
        "last_error=null"
    )"
    EVENT_ROLE="evaluator" \
      EVENT_ITERATION="$ITERATION" \
      EVENT_COMPLETED_AT="$completed_at" \
      EVENT_COMMIT_HASH="$COMMIT_HASH" \
      append_event "task_done"

    duration="$(format_duration "$STARTED_AT" "$completed_at")"
    completed_iterations=$((ITERATION + 1))
    unlocked_tasks_raw="$(get_unlocked_tasks "$TASK_ID" || true)"
    unlocked_tasks_display="$(format_bullet_list "$unlocked_tasks_raw")"
    progress_summary="$(get_progress_summary)"
    send_formatted_notification "✅ 任务评估通过" "任务名: ${TASK_NAME}
用时: ${duration}
迭代次数: ${completed_iterations}
criteria: ${PASS_COUNT}/${TOTAL_COUNT}
已解锁下游任务:
${unlocked_tasks_display}
当前总进度: ${progress_summary}"

    if printf '%s\n' "$update_status_output" | grep -qx 'BATCH_DONE=true'; then
      batch_json="$(all_tasks_done_json)"
      batch_id="$(json_value "$batch_json" "batch_id" || true)"
      project_name="$(json_value "$batch_json" "project" || true)"
      done_count="$(json_value "$batch_json" "done_count" || true)"
      total_count="$(json_value "$batch_json" "total_count" || true)"
      total_estimated_duration="$(json_value "$batch_json" "total_estimated_duration" || true)"
      total_iterations="$(json_value "$batch_json" "total_iterations" || true)"
      batch_task_summaries_raw="$(json_array_lines "$batch_json" "task_summaries" || true)"
      batch_task_summaries_display="$(format_bullet_list "$batch_task_summaries_raw")"
      send_formatted_notification "🎉 BATCH_DONE" "项目名: ${project_name:-$(basename "$PROJECT_DIR")}
Batch: ${batch_id:-unknown}
任务完成状态:
${batch_task_summaries_display}
总用时估算: ${total_estimated_duration:-unknown}
总迭代次数: ${total_iterations:-0}
批次进度: ${done_count:-0}/${total_count:-0} done"

      # Check if harvest.auto_trigger is enabled
      harvest_auto="$(NEXUM_PROJECT_DIR="$PROJECT_DIR" "$SCRIPT_DIR/swarm-config.sh" get harvest.auto_trigger 2>/dev/null || echo "true")"
      if [ "$harvest_auto" = "true" ] && [ -x "$SCRIPT_DIR/harvest.sh" ]; then
        send_formatted_notification "🌾 开始 harvest" "任务: 批次已完成
项目名: ${project_name:-$(basename "$PROJECT_DIR")}"
        if NEXUM_PROJECT_DIR="$PROJECT_DIR" "$SCRIPT_DIR/harvest.sh" 2>&1; then
          send_formatted_notification "✅ harvest 完成" "项目名: ${project_name:-$(basename "$PROJECT_DIR")}"
        else
          send_formatted_notification "⚠️ harvest 失败" "项目名: ${project_name:-$(basename "$PROJECT_DIR")}
原因: 请检查 harvest 日志"
        fi
      fi
    fi

    send_system_event "Done: ${TASK_ID} (iter ${ITERATION})"
    exit 0
    ;;
  fail|error|inconclusive)
    if [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; then
      next_iteration=$((ITERATION + 1))
      NEXUM_PROJECT_DIR="$PROJECT_DIR" "$UPDATE_TASK_STATUS_SCRIPT" \
        "$TASK_ID" \
        running \
        "iteration=${next_iteration}" \
        "last_error=null"
      EVENT_ROLE="evaluator" \
        EVENT_VERDICT="$VERDICT" \
        EVENT_ITERATION="$ITERATION" \
        EVENT_NEXT_ITERATION="$next_iteration" \
        EVENT_FEEDBACK="$FEEDBACK" \
        EVENT_SYSTEM_ERRORS_JSON="$SYSTEM_ERRORS_JSON" \
        append_event "eval_done"

      [ -n "$GENERATOR_AGENT" ] || fail "Contract missing generator agent for ${TASK_ID}"
      retry_prompt="$(build_retry_prompt "$CONTEXT_JSON" "$VERDICT" "$FEEDBACK" "$SYSTEM_ERRORS_JSON" "$next_iteration")"
      build_agent_command "$GENERATOR_AGENT"

      if ! NEXUM_PROJECT_DIR="$PROJECT_DIR" \
        "$DISPATCH_SCRIPT" \
        "$GENERATOR_AGENT" \
        "$TASK_ID" \
        --role generator \
        --prompt-file "$retry_prompt" \
        "${AGENT_COMMAND[@]}"; then
        NEXUM_PROJECT_DIR="$PROJECT_DIR" "$UPDATE_TASK_STATUS_SCRIPT" \
          "$TASK_ID" \
          failed \
          "last_error=generator_redispatch_failed"
        EVENT_ROLE="evaluator" EVENT_REASON="generator_redispatch_failed" EVENT_ITERATION="$ITERATION" append_event "task_failed"
        send_formatted_notification "❌ Generator 重派失败" "任务ID: ${TASK_ID}
任务名: ${TASK_NAME}
当前迭代: ${ITERATION}
目标 agent: ${GENERATOR_AGENT}"
        exit 0
      fi

      failed_criteria_raw="$(get_failed_criteria "$EVAL_RESULT_PATH" || true)"
      failed_criteria_display="$(format_bullet_list "$failed_criteria_raw")"
      feedback_source="${FEEDBACK:-$(json_value "$EVAL_JSON" "system_errors" || printf '[]')}"
      feedback_excerpt="$(summarize_text "$feedback_source" 200)"
      send_formatted_notification "🔁 任务待重试" "任务名: ${TASK_NAME}
当前迭代: ${ITERATION}
下一迭代: ${next_iteration}
criteria: ${PASS_COUNT}/${TOTAL_COUNT}
失败 criteria:
${failed_criteria_display}
feedback 摘要: ${feedback_excerpt}"
      send_system_event "generator_retry: ${TASK_ID} iter ${next_iteration}"
      exit 0
    fi

    NEXUM_PROJECT_DIR="$PROJECT_DIR" "$UPDATE_TASK_STATUS_SCRIPT" \
      "$TASK_ID" \
      escalated \
      "last_error=eval_${VERDICT}"
    EVENT_ROLE="evaluator" \
      EVENT_VERDICT="$VERDICT" \
      EVENT_ITERATION="$ITERATION" \
      EVENT_MAX_ITERATIONS="$MAX_ITERATIONS" \
      EVENT_FEEDBACK="$FEEDBACK" \
      EVENT_SYSTEM_ERRORS_JSON="$SYSTEM_ERRORS_JSON" \
      append_event "task_escalated"

    failed_criteria_raw="$(get_failed_criteria "$EVAL_RESULT_PATH" || true)"
    failed_criteria_display="$(format_bullet_list "$failed_criteria_raw")"
    feedback_source="${FEEDBACK:-$(json_value "$EVAL_JSON" "system_errors" || printf '[]')}"
    feedback_excerpt="$(summarize_text "$feedback_source" 200)"
    send_formatted_notification "🚨 任务需人工介入" "任务名: ${TASK_NAME}
当前迭代: ${ITERATION}
criteria: ${PASS_COUNT}/${TOTAL_COUNT}
失败 criteria:
${failed_criteria_display}
feedback 摘要: ${feedback_excerpt}"
    send_system_event "Escalated: ${TASK_ID} (verdict ${VERDICT})"
    exit 0
    ;;
  *)
    NEXUM_PROJECT_DIR="$PROJECT_DIR" "$UPDATE_TASK_STATUS_SCRIPT" \
      "$TASK_ID" \
      failed \
      "last_error=unknown_eval_verdict_${VERDICT}"
    EVENT_ROLE="evaluator" EVENT_REASON="unknown_eval_verdict" EVENT_VERDICT="$VERDICT" EVENT_ITERATION="$ITERATION" append_event "task_failed"
    send_formatted_notification "❌ Evaluator 返回未知 verdict" "任务ID: ${TASK_ID}
任务名: ${TASK_NAME}
verdict: ${VERDICT}"
    exit 0
    ;;
esac
