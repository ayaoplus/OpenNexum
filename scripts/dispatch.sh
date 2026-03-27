#!/bin/bash
# Dispatch a generator or evaluator task into the agent's tmux session.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
PROJECT_DIR="${NEXUM_PROJECT_DIR:-$(pwd -P)}"
[ -d "$PROJECT_DIR" ] || {
  echo "Error: project directory does not exist: $PROJECT_DIR" >&2
  exit 1
}
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"
REFERENCES_DIR="${SKILL_ROOT}/references"
UPDATE_TASK_STATUS_SCRIPT="${SCRIPT_DIR}/update-task-status.sh"
ON_COMPLETE_SCRIPT="${SCRIPT_DIR}/on-complete.sh"
ACTIVE_TASKS_FILE="${PROJECT_DIR}/nexum/active-tasks.json"
EVENTS_FILE="${PROJECT_DIR}/nexum/events.jsonl"

usage() {
  cat >&2 <<'EOF'
Usage:
  dispatch.sh <agent> <task_id> --role <generator|evaluator> [--prompt-file <path>] <cli_command...>
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

shell_quote() {
  printf "%q" "$1"
}

cleanup_files() {
  if [ -n "${CONTRACT_JSON_FILE:-}" ] && [ -f "${CONTRACT_JSON_FILE:-}" ]; then
    rm -f "$CONTRACT_JSON_FILE"
  fi
}

append_event() {
  local payload="$1"
  mkdir -p "$(dirname "$EVENTS_FILE")"
  EVENTS_FILE="$EVENTS_FILE" EVENT_PAYLOAD="$payload" python3 - <<'PY'
import fcntl
import os
import sys

events_file = os.environ["EVENTS_FILE"]
payload = os.environ["EVENT_PAYLOAD"]

directory = os.path.dirname(events_file)
if directory:
    os.makedirs(directory, exist_ok=True)

with open(events_file, "a", encoding="utf-8") as handle:
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    handle.write(payload)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
PY
}

write_contract_cache() {
  local contract_file="$1"
  "$SCRIPT_DIR/yaml-to-json.sh" "$contract_file"
}

json_get() {
  local path="$1"
  CONTRACT_JSON_FILE="$CONTRACT_JSON_FILE" JSON_PATH="$path" python3 - <<'PY'
import json
import os
import sys

contract_file = os.environ["CONTRACT_JSON_FILE"]
path = os.environ["JSON_PATH"].split(".")

with open(contract_file, "r", encoding="utf-8") as handle:
    data = json.load(handle)

value = data
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

json_array_to_lines() {
  local path="$1"
  CONTRACT_JSON_FILE="$CONTRACT_JSON_FILE" JSON_PATH="$path" python3 - <<'PY'
import json
import os
import sys

contract_file = os.environ["CONTRACT_JSON_FILE"]
path = os.environ["JSON_PATH"].split(".")

with open(contract_file, "r", encoding="utf-8") as handle:
    data = json.load(handle)

value = data
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

require_active_task() {
  local task_id="$1"
  ACTIVE_TASKS_FILE="$ACTIVE_TASKS_FILE" TASK_ID="$task_id" python3 - <<'PY'
import json
import os
import sys
from json import JSONDecodeError

task_file = os.environ["ACTIVE_TASKS_FILE"]
task_id = os.environ["TASK_ID"]

try:
    with open(task_file, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except FileNotFoundError:
    print(f"Task file not found: {task_file}", file=sys.stderr)
    raise SystemExit(1)
except JSONDecodeError as exc:
    print(f"Invalid JSON in {task_file}: {exc}", file=sys.stderr)
    raise SystemExit(1)

tasks = data.get("tasks")
if not isinstance(tasks, list):
    print(f"Invalid task file structure: {task_file}", file=sys.stderr)
    raise SystemExit(1)

for task in tasks:
    if isinstance(task, dict) and task.get("id") == task_id:
        raise SystemExit(0)

print(f"Task not found in active-tasks.json: {task_id}", file=sys.stderr)
raise SystemExit(1)
PY
}

read_iteration() {
  local task_id="$1"
  ACTIVE_TASKS_FILE="$ACTIVE_TASKS_FILE" TASK_ID="$task_id" python3 - <<'PY'
import json
import os
import sys
from json import JSONDecodeError

task_file = os.environ["ACTIVE_TASKS_FILE"]
task_id = os.environ["TASK_ID"]

try:
    with open(task_file, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except FileNotFoundError:
    print(f"Task file not found: {task_file}", file=sys.stderr)
    raise SystemExit(1)
except JSONDecodeError as exc:
    print(f"Invalid JSON in {task_file}: {exc}", file=sys.stderr)
    raise SystemExit(1)

tasks = data.get("tasks")
if not isinstance(tasks, list):
    print(f"Invalid task file structure: {task_file}", file=sys.stderr)
    raise SystemExit(1)

for task in tasks:
    if isinstance(task, dict) and task.get("id") == task_id:
        iteration = task.get("iteration", 0)
        if isinstance(iteration, int):
            print(iteration)
        else:
            print(0)
        raise SystemExit(0)

print(f"Task not found in active-tasks.json: {task_id}", file=sys.stderr)
raise SystemExit(1)
PY
}

check_generator_busy() {
  local tmux_session="$1"
  ACTIVE_TASKS_FILE="$ACTIVE_TASKS_FILE" TMUX_SESSION="$tmux_session" python3 - <<'PY'
import json
import os
import sys
from json import JSONDecodeError

task_file = os.environ["ACTIVE_TASKS_FILE"]
tmux_session = os.environ["TMUX_SESSION"]

try:
    with open(task_file, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except FileNotFoundError:
    print(f"Task file not found: {task_file}", file=sys.stderr)
    raise SystemExit(1)
except JSONDecodeError as exc:
    print(f"Invalid JSON in {task_file}: {exc}", file=sys.stderr)
    raise SystemExit(1)

tasks = data.get("tasks")
if not isinstance(tasks, list):
    print(f"Invalid task file structure: {task_file}", file=sys.stderr)
    raise SystemExit(1)

for task in tasks:
    if not isinstance(task, dict):
        continue
    if task.get("status") == "running" and task.get("tmux_session") == tmux_session:
        existing_id = task.get("id")
        if isinstance(existing_id, str) and existing_id:
            print(existing_id)
        else:
            print(tmux_session)
        raise SystemExit(0)

raise SystemExit(2)
PY
}

task_name_short() {
  local name="$1"
  TASK_NAME="$name" python3 - <<'PY'
import os
import re

name = os.environ["TASK_NAME"].strip().lower()
slug = re.sub(r"[^a-z0-9]+", " ", name)
slug = "-".join(slug.split())
slug = slug[:48].strip("-")
print(slug or "task")
PY
}

lowercase_ascii() {
  printf "%s" "$1" | tr '[:upper:]' '[:lower:]'
}

render_prompt() {
  local template_file="$1"
  local prompt_output="$2"
  local git_commit_cmd="$3"
  local eval_result_path="$4"
  TEMPLATE_FILE="$template_file" PROMPT_OUTPUT="$prompt_output" GIT_COMMIT_CMD="$git_commit_cmd" EVAL_RESULT_PATH="$eval_result_path" CONTRACT_JSON_FILE="$CONTRACT_JSON_FILE" python3 - <<'PY'
import json
import os
import sys

template_file = os.environ["TEMPLATE_FILE"]
prompt_output = os.environ["PROMPT_OUTPUT"]
git_commit_cmd = os.environ["GIT_COMMIT_CMD"]
eval_result_path = os.environ["EVAL_RESULT_PATH"]
contract_file = os.environ["CONTRACT_JSON_FILE"]


def as_list(value):
    if isinstance(value, list):
        return value
    return []


def bullet_lines(items):
    values = [str(item) for item in items if item not in (None, "")]
    if not values:
        return "- none"
    return "\n".join(f"- {value}" for value in values)


def criteria_preview(criteria):
    lines = []
    for item in criteria:
        if not isinstance(item, dict):
            continue
        criterion_id = item.get("id", "?")
        desc = item.get("desc", "")
        method = item.get("method", "")
        threshold = item.get("threshold", "")
        parts = [f"[{criterion_id}] {desc}".strip()]
        details = []
        if method:
            details.append(f"method: {method}")
        if threshold:
            details.append(f"threshold: {threshold}")
        if details:
            parts.append(f"({' ; '.join(details)})")
        lines.append("- " + " ".join(parts).strip())
    return "\n".join(lines) if lines else "- none"


with open(contract_file, "r", encoding="utf-8") as handle:
    contract = json.load(handle)

with open(template_file, "r", encoding="utf-8") as handle:
    template = handle.read()

scope = contract.get("scope") if isinstance(contract.get("scope"), dict) else {}
eval_strategy = contract.get("eval_strategy") if isinstance(contract.get("eval_strategy"), dict) else {}
criteria = as_list(eval_strategy.get("criteria"))

replacements = {
    "{{TASK_NAME}}": str(contract.get("name", "")),
    "{{SCOPE_FILES}}": bullet_lines(as_list(scope.get("files"))),
    "{{SCOPE_BOUNDARIES}}": bullet_lines(as_list(scope.get("boundaries"))),
    "{{DELIVERABLES}}": bullet_lines(as_list(contract.get("deliverables"))),
    "{{CRITERIA_PREVIEW}}": criteria_preview(criteria),
    "{{CRITERIA_LIST}}": criteria_preview(criteria),
    # TODO(Phase 3): inject relevant lessons from docs/lessons/ filtered by task tags
    # For now, RELEVANT_LESSONS is intentionally left empty
    "{{RELEVANT_LESSONS}}": "",
    "{{GIT_COMMIT_CMD}}": git_commit_cmd,
    "{{EVAL_RESULT_PATH}}": eval_result_path,
}

rendered = template
for key, value in replacements.items():
    rendered = rendered.replace(key, value)

with open(prompt_output, "w", encoding="utf-8") as handle:
    handle.write(rendered)
    if not rendered.endswith("\n"):
        handle.write("\n")
PY
}

ensure_tmux_session() {
  local session="$1"
  if tmux has-session -t "$session" 2>/dev/null; then
    return 0
  fi
  tmux new-session -d -s "$session" -c "$PROJECT_DIR"
}

queue_tmux_runner() {
  local session="$1"
  local log_file="$2"
  local base_commit="$3"
  local eval_result_path="$4"
  local i

  local exports=()
  exports+=("export TASK_ID=$(shell_quote "$TASK_ID")")
  exports+=("export PROJECT_DIR=$(shell_quote "$PROJECT_DIR")")
  exports+=("export ROLE=$(shell_quote "$ROLE")")
  exports+=("export AGENT=$(shell_quote "$AGENT")")
  exports+=("export BASE_COMMIT=$(shell_quote "$base_commit")")
  exports+=("export PROMPT_FILE_PATH=$(shell_quote "$PROMPT_TEMP_FILE")")
  exports+=("export LOG_FILE=$(shell_quote "$log_file")")
  exports+=("export TMUX_SESSION=$(shell_quote "$session")")
  exports+=("export UPDATE_TASK_STATUS_SCRIPT=$(shell_quote "$UPDATE_TASK_STATUS_SCRIPT")")
  exports+=("export ON_COMPLETE_SCRIPT=$(shell_quote "$ON_COMPLETE_SCRIPT")")
  exports+=("export EVAL_RESULT_PATH=$(shell_quote "$eval_result_path")")
  exports+=("export NEXUM_TASK_ID=$(shell_quote "$TASK_ID")")
  exports+=("export CLI_ARG_COUNT=$(shell_quote "${#CLI_COMMAND[@]}")")
  exports+=("export SCOPE_FILE_COUNT=$(shell_quote "${#SCOPE_FILES[@]}")")

  for i in "${!CLI_COMMAND[@]}"; do
    exports+=("export CLI_ARG_${i}=$(shell_quote "${CLI_COMMAND[$i]}")")
  done

  for i in "${!SCOPE_FILES[@]}"; do
    exports+=("export SCOPE_FILE_${i}=$(shell_quote "${SCOPE_FILES[$i]}")")
  done

  local line
  for line in "${exports[@]}"; do
    tmux send-keys -t "$session" -l -- "$line"
    tmux send-keys -t "$session" C-m
  done

  tmux send-keys -t "$session" -l -- "/bin/bash -s <<'SCRIPT' 2>&1 | tee $(shell_quote "$log_file")"
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'set -euo pipefail'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'cd "$PROJECT_DIR"'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'CALLBACK_DONE=0'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'declare -a CLI_COMMAND=()'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'declare -a SCOPE_FILES=()'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'idx=0'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'while [ "$idx" -lt "${CLI_ARG_COUNT:-0}" ]; do'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  eval "CLI_COMMAND+=(\"\${CLI_ARG_${idx}}\")"'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  idx=$((idx + 1))'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'done'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'idx=0'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'while [ "$idx" -lt "${SCOPE_FILE_COUNT:-0}" ]; do'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  eval "SCOPE_FILES+=(\"\${SCOPE_FILE_${idx}}\")"'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  idx=$((idx + 1))'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'done'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'run_on_complete() {'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  local exit_code="$1"'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  if [ "${CALLBACK_DONE:-0}" -eq 1 ]; then'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '    return 0'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  fi'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  CALLBACK_DONE=1'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  if [ ! -x "$ON_COMPLETE_SCRIPT" ]; then'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '    echo "Warning: on-complete script not found or not executable: $ON_COMPLETE_SCRIPT" >&2'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '    return 0'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  fi'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  set +e'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  "$ON_COMPLETE_SCRIPT" "$TASK_ID" "$exit_code" --role "$ROLE"'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  local callback_status=$?'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  set -e'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  if [ "$callback_status" -eq 0 ]; then'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '    return 0'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  fi'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  echo "Error: on-complete callback failed for $TASK_ID (exit $callback_status)" >&2'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  "$UPDATE_TASK_STATUS_SCRIPT" "$TASK_ID" failed "last_error=on-complete callback failed (exit $callback_status)" || true'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  return "$callback_status"'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '}'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'cleanup() {'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  local exit_code=$?'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  run_on_complete "$exit_code" || true'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  exit "$exit_code"'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '}'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'trap cleanup EXIT'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'set +e'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'if [ -n "${PROMPT_FILE_PATH:-}" ] && [ -f "$PROMPT_FILE_PATH" ]; then'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  "${CLI_COMMAND[@]}" < "$PROMPT_FILE_PATH"'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'else'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  "${CLI_COMMAND[@]}"'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'fi'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'CLI_EXIT=$?'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'set -e'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'if [ "$CLI_EXIT" -ne 0 ]; then'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  exit "$CLI_EXIT"'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'fi'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'if [ "$ROLE" = "generator" ]; then'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  if [ -n "$(git status --porcelain)" ]; then'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '    git add -- "${SCOPE_FILES[@]}"'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '    if ! git diff --cached --quiet -- "${SCOPE_FILES[@]}"; then'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '      git commit -m "chore(nexum): force-commit for $TASK_ID [skip ci]"'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '    fi'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  fi'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  if git diff "$BASE_COMMIT"..HEAD --name-only 2>/dev/null | grep -q "^AGENTS.md$"; then'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '    cp AGENTS.md CLAUDE.md'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '    git add CLAUDE.md'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '    if ! git diff --cached --quiet -- CLAUDE.md; then'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '      git commit -m "chore(nexum): sync CLAUDE.md from AGENTS.md" --no-verify'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '    fi'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- '  fi'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'fi'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'run_on_complete 0'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'exit 0'
  tmux send-keys -t "$session" C-m
  tmux send-keys -t "$session" -l -- 'SCRIPT'
  tmux send-keys -t "$session" C-m
}

if [ "$#" -lt 4 ]; then
  usage
fi

AGENT="$1"
TASK_ID="$2"
shift 2

ROLE=""
PROMPT_FILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --role)
      [ "$#" -ge 2 ] || usage
      ROLE="$2"
      shift 2
      ;;
    --prompt-file)
      [ "$#" -ge 2 ] || usage
      PROMPT_FILE="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

[ -n "$ROLE" ] || fail "--role is required"
[ "$#" -ge 1 ] || fail "cli_command is required"

case "$ROLE" in
  generator|evaluator)
    ;;
  *)
    fail "Unsupported role: $ROLE"
    ;;
esac

if [[ ! "$TASK_ID" =~ ^[A-Z]+-[0-9]+$ ]]; then
  fail "Invalid task_id '$TASK_ID'. Expected format ^[A-Z]+-[0-9]+$"
fi

CLI_COMMAND=("$@")
TMUX_SESSION="nexum-${AGENT}"
CONTRACT_FILE="${PROJECT_DIR}/docs/nexum/contracts/${TASK_ID}.yaml"
PROMPT_TEMP_FILE="/tmp/nexum-prompt-${TASK_ID}.txt"
LOG_FILE="/tmp/nexum-${TASK_ID}.log"

trap cleanup_files EXIT

[ -x "$UPDATE_TASK_STATUS_SCRIPT" ] || fail "Missing required script: $UPDATE_TASK_STATUS_SCRIPT"
[ -f "$CONTRACT_FILE" ] || fail "Contract not found: $CONTRACT_FILE"
[ -f "$ACTIVE_TASKS_FILE" ] || fail "Task file not found: $ACTIVE_TASKS_FILE"
command -v tmux >/dev/null 2>&1 || fail "tmux is required but was not found in PATH"

if ! git -C "$PROJECT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
  fail "Project directory is not a git repository: $PROJECT_DIR"
fi

CONTRACT_JSON_FILE="$(mktemp "/tmp/nexum-contract-${TASK_ID}.XXXXXX")"
write_contract_cache "$CONTRACT_FILE" > "$CONTRACT_JSON_FILE"

CONTRACT_NAME="$(json_get "name" || true)"
CONTRACT_TYPE="$(json_get "type" || true)"
CONTRACT_GENERATOR="$(json_get "generator" || true)"
CONTRACT_EVALUATOR="$(json_get "evaluator" || true)"

[ -n "$CONTRACT_NAME" ] || fail "Contract missing required field: name"
[ -n "$CONTRACT_GENERATOR" ] || fail "Contract missing required field: generator"
[ -n "$CONTRACT_EVALUATOR" ] || fail "Contract missing required field: evaluator"

if [ "$ROLE" = "evaluator" ]; then
  EVAL_TYPE="$(json_get "eval_strategy.type" || true)"
  case "${EVAL_TYPE:-}" in
    unit|integration|e2e|review|composite)
      ;;
    "")
      fail "Contract eval_strategy.type is missing"
      ;;
    *)
      fail "Unsupported eval_strategy.type: ${EVAL_TYPE}"
      ;;
  esac

  if [ "$EVAL_TYPE" = "composite" ]; then
    if ! CONTRACT_JSON_FILE="$CONTRACT_JSON_FILE" python3 - <<'PY'
import json
import os
import sys

valid_types = {"unit", "integration", "e2e", "review", "composite"}

with open(os.environ["CONTRACT_JSON_FILE"], "r", encoding="utf-8") as handle:
    contract = json.load(handle)

eval_strategy = contract.get("eval_strategy")
sub_strategies = eval_strategy.get("sub_strategies") if isinstance(eval_strategy, dict) else None

if not isinstance(sub_strategies, list) or not sub_strategies:
    print("Contract eval_strategy.sub_strategies must be a non-empty array when eval_strategy.type=composite", file=sys.stderr)
    raise SystemExit(1)

for index, sub_strategy in enumerate(sub_strategies):
    if not isinstance(sub_strategy, dict):
        print(f"Contract eval_strategy.sub_strategies[{index}] must be an object", file=sys.stderr)
        raise SystemExit(1)
    sub_type = sub_strategy.get("type")
    if sub_type not in valid_types:
        print(
            f"Unsupported eval_strategy.sub_strategies[{index}].type: {sub_type}",
            file=sys.stderr,
        )
        raise SystemExit(1)
PY
    then
      fail "Invalid composite eval_strategy configuration"
    fi
  fi
fi

case "$ROLE" in
  generator)
    [ "$CONTRACT_GENERATOR" = "$AGENT" ] || fail "Contract generator '$CONTRACT_GENERATOR' does not match agent '$AGENT'"
    ;;
  evaluator)
    [ "$CONTRACT_EVALUATOR" = "$AGENT" ] || fail "Contract evaluator '$CONTRACT_EVALUATOR' does not match agent '$AGENT'"
    ;;
esac

SCOPE_FILES=()
while IFS= read -r path; do
  SCOPE_FILES+=("$path")
done < <(json_array_to_lines "scope.files")
[ "${#SCOPE_FILES[@]}" -gt 0 ] || fail "Contract scope.files must contain at least one file"

require_active_task "$TASK_ID"
ensure_tmux_session "$TMUX_SESSION"

if [ "$ROLE" = "generator" ]; then
  BUSY_TASK_ID=""
  set +e
  BUSY_TASK_ID="$(check_generator_busy "$TMUX_SESSION")"
  BUSY_CHECK_STATUS=$?
  set -e
  case "$BUSY_CHECK_STATUS" in
    0)
      fail "Agent '$AGENT' is busy in tmux session '$TMUX_SESSION' with running task '$BUSY_TASK_ID'"
      ;;
    2)
      ;;
    *)
      fail "Failed to inspect running tasks for tmux session '$TMUX_SESSION'"
      ;;
  esac
fi

NOW="$(timestamp_utc)"
BASE_COMMIT="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
ITERATION="$(read_iteration "$TASK_ID")"
EVAL_RESULT_PATH=""

if [ "$ROLE" = "generator" ]; then
  set +e
  NEXUM_PROJECT_DIR="$PROJECT_DIR" "$UPDATE_TASK_STATUS_SCRIPT" \
    "$TASK_ID" \
    running \
    "base_commit=${BASE_COMMIT}" \
    "tmux_session=${TMUX_SESSION}" \
    "started_at=${NOW}"
  UPDATE_STATUS_RESULT=$?
  set -e
  case "$UPDATE_STATUS_RESULT" in
    0)
      ;;
    2)
      BUSY_TASK_ID=""
      set +e
      BUSY_TASK_ID="$(check_generator_busy "$TMUX_SESSION")"
      BUSY_CHECK_STATUS=$?
      set -e
      if [ "$BUSY_CHECK_STATUS" -eq 0 ] && [ -n "$BUSY_TASK_ID" ]; then
        fail "Agent '$AGENT' is busy in tmux session '$TMUX_SESSION' with running task '$BUSY_TASK_ID'"
      fi
      fail "Agent '$AGENT' is busy in tmux session '$TMUX_SESSION'"
      ;;
    *)
      fail "Failed to update task '$TASK_ID' to running"
      ;;
  esac
  append_event "{\"event\":\"task_started\",\"task_id\":\"${TASK_ID}\",\"base_commit\":\"${BASE_COMMIT}\",\"ts\":\"${NOW}\"}"
else
  EVAL_RESULT_PATH="${PROJECT_DIR}/nexum/runtime/eval/${TASK_ID}-iter-${ITERATION}.yaml"
  NEXUM_PROJECT_DIR="$PROJECT_DIR" "$UPDATE_TASK_STATUS_SCRIPT" \
    "$TASK_ID" \
    evaluating \
    "eval_tmux_session=${TMUX_SESSION}"
  append_event "{\"event\":\"eval_started\",\"task_id\":\"${TASK_ID}\",\"iteration\":${ITERATION},\"ts\":\"${NOW}\"}"
fi

if [ -n "$PROMPT_FILE" ]; then
  [ -f "$PROMPT_FILE" ] || fail "Prompt file not found: $PROMPT_FILE"
  cp "$PROMPT_FILE" "$PROMPT_TEMP_FILE"
else
  case "$ROLE" in
    generator)
      case "${CONTRACT_TYPE:-coding}" in
        creative|task)
          TEMPLATE_FILE="${REFERENCES_DIR}/prompt-generator-writing.md"
          ;;
        *)
          TEMPLATE_FILE="${REFERENCES_DIR}/prompt-generator-coding.md"
          ;;
      esac
      if [ ! -f "$TEMPLATE_FILE" ]; then
        echo "Warning: template $TEMPLATE_FILE not found, falling back to coding template" >&2
        TEMPLATE_FILE="${REFERENCES_DIR}/prompt-generator-coding.md"
      fi
      ;;
    evaluator)
      TEMPLATE_FILE="${REFERENCES_DIR}/prompt-evaluator.md"
      ;;
  esac
  [ -f "$TEMPLATE_FILE" ] || fail "Prompt template not found: $TEMPLATE_FILE"

  TASK_NAME_SHORT="$(task_name_short "$CONTRACT_NAME")"
  TASK_ID_LOWER="$(lowercase_ascii "$TASK_ID")"
  GIT_ADD_ARGS=()
  for path in "${SCOPE_FILES[@]}"; do
    GIT_ADD_ARGS+=("$(shell_quote "$path")")
  done
  GIT_COMMIT_CMD="git add -- ${GIT_ADD_ARGS[*]} && git commit -m \"feat(${TASK_ID_LOWER}): implement ${TASK_NAME_SHORT}\""
  render_prompt "$TEMPLATE_FILE" "$PROMPT_TEMP_FILE" "$GIT_COMMIT_CMD" "$EVAL_RESULT_PATH"
fi

queue_tmux_runner "$TMUX_SESSION" "$LOG_FILE" "$BASE_COMMIT" "$EVAL_RESULT_PATH"

echo "Dispatched ${ROLE} task ${TASK_ID} to ${TMUX_SESSION}"
