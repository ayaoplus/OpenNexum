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
GENERATOR_TEMPLATE="${SKILL_ROOT}/references/prompt-generator-coding.md"

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
  openclaw system event --mode next-heartbeat --text "$text" >/dev/null 2>&1 || true
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
maybe_set_json(payload, "files", "EVENT_FILES_JSON")
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
  if [ "$#" -eq 0 ]; then
    printf '[]'
    return 0
  fi
  printf '%s\n' "$@" | python3 - <<'PY'
import json
import sys

items = [line.rstrip("\n") for line in sys.stdin if line.rstrip("\n")]
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

all_tasks_done_json() {
  ACTIVE_TASKS_FILE="$ACTIVE_TASKS_FILE" python3 - <<'PY'
import json
import os
from json import JSONDecodeError

task_file = os.environ["ACTIVE_TASKS_FILE"]

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

print(json.dumps({
    "all_done": all_done,
    "batch_id": data.get("batch_id"),
    "done_count": done_count,
    "total_count": total_count,
}, ensure_ascii=False))
PY
}

load_task_context() {
  TASK_ID="$1" PROJECT_DIR="$PROJECT_DIR" ACTIVE_TASKS_FILE="$ACTIVE_TASKS_FILE" python3 - <<'PY'
import json
import os
import re
import sys
from json import JSONDecodeError

task_id = os.environ["TASK_ID"]
project_dir = os.environ["PROJECT_DIR"]
active_tasks_file = os.environ["ACTIVE_TASKS_FILE"]


def fail(message, code=1):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def strip_comments(line):
    in_single = False
    in_double = False
    escaped = False
    result = []
    for char in line:
        if char == "\\" and in_double and not escaped:
            escaped = True
            result.append(char)
            continue
        if char == "'" and not in_double:
            in_single = not in_single
        elif char == '"' and not in_single and not escaped:
            in_double = not in_double
        elif char == "#" and not in_single and not in_double:
            break
        result.append(char)
        escaped = False
    return "".join(result).rstrip()


def parse_scalar(value):
    value = value.strip()
    if value == "":
        return ""
    if value in {"null", "Null", "NULL", "~"}:
        return None
    if value in {"true", "True"}:
        return True
    if value in {"false", "False"}:
        return False
    if value == "[]":
        return []
    if value == "{}":
        return {}
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        inner = value[1:-1]
        if value[0] == '"':
            inner = bytes(inner, "utf-8").decode("unicode_escape")
        else:
            inner = inner.replace("''", "'")
        return inner
    if re.fullmatch(r"-?[0-9]+", value):
        return int(value)
    return value


def tokenize(text):
    tokens = []
    for raw_line in text.splitlines():
        cleaned = strip_comments(raw_line)
        if not cleaned.strip():
            continue
        indent = len(cleaned) - len(cleaned.lstrip(" "))
        tokens.append((indent, cleaned.strip()))
    return tokens


def parse_block(tokens, start, indent):
    if start >= len(tokens):
        return None, start
    current_indent, current_text = tokens[start]
    if current_indent != indent:
        fail(f"Unsupported YAML indentation near: {current_text}")
    if current_text.startswith("- "):
        return parse_list(tokens, start, indent)
    return parse_mapping(tokens, start, indent)


def consume_block_scalar(tokens, start, parent_indent):
    lines = []
    index = start
    while index < len(tokens):
        current_indent, text = tokens[index]
        if current_indent <= parent_indent:
            break
        lines.append(text)
        index += 1
    return "\n".join(lines), index


def parse_mapping(tokens, start, indent):
    data = {}
    index = start
    while index < len(tokens):
        current_indent, text = tokens[index]
        if current_indent < indent:
            break
        if current_indent > indent:
            fail(f"Unexpected indentation near: {text}")
        if text.startswith("- "):
            break
        if ":" not in text:
            fail(f"Invalid YAML mapping entry: {text}")
        key, raw_value = text.split(":", 1)
        key = key.strip()
        raw_value = raw_value.strip()
        index += 1
        if raw_value == "":
            if index < len(tokens) and tokens[index][0] > indent:
                value, index = parse_block(tokens, index, tokens[index][0])
            else:
                value = None
        elif raw_value in {"|", "|-", "|+", ">", ">-", ">+"}:
            value, index = consume_block_scalar(tokens, index, indent)
        else:
            value = parse_scalar(raw_value)
        data[key] = value
    return data, index


def parse_list(tokens, start, indent):
    data = []
    index = start
    while index < len(tokens):
        current_indent, text = tokens[index]
        if current_indent < indent:
            break
        if current_indent > indent:
            fail(f"Unexpected indentation near: {text}")
        if not text.startswith("- "):
            break

        item_text = text[2:].strip()
        index += 1

        if item_text == "":
            if index < len(tokens) and tokens[index][0] > indent:
                value, index = parse_block(tokens, index, tokens[index][0])
            else:
                value = None
            data.append(value)
            continue

        if ":" in item_text:
            key, raw_value = item_text.split(":", 1)
            key = key.strip()
            raw_value = raw_value.strip()
            item = {}
            if raw_value == "":
                if index < len(tokens) and tokens[index][0] > indent:
                    nested, index = parse_block(tokens, index, tokens[index][0])
                    if isinstance(nested, dict):
                        item[key] = None
                        item.update(nested)
                    else:
                        item[key] = nested
                else:
                    item[key] = None
            elif raw_value in {"|", "|-", "|+", ">", ">-", ">+"}:
                value, index = consume_block_scalar(tokens, index, indent)
                item[key] = value
            else:
                item[key] = parse_scalar(raw_value)
                if index < len(tokens) and tokens[index][0] > indent:
                    nested, index = parse_block(tokens, index, tokens[index][0])
                    if isinstance(nested, dict):
                        item.update(nested)
                    else:
                        fail(f"Unsupported YAML list structure near: {item_text}")
            data.append(item)
            continue

        data.append(parse_scalar(item_text))

    return data, index


def load_yaml(path):
    try:
        import yaml  # type: ignore
    except Exception:
        yaml = None

    with open(path, "r", encoding="utf-8") as handle:
        raw = handle.read()

    if yaml is not None:
        data = yaml.safe_load(raw)
    else:
        tokens = tokenize(raw)
        if not tokens:
            fail(f"YAML file is empty: {path}")
        data, index = parse_block(tokens, 0, tokens[0][0])
        if index != len(tokens):
            fail(f"Unsupported YAML structure in {path}")

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
  RESULT_PATH="$result_path" python3 - <<'PY'
import json
import os
import re
import sys

result_path = os.environ["RESULT_PATH"]


def fail(message, code=1):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def strip_comments(line):
    in_single = False
    in_double = False
    escaped = False
    result = []
    for char in line:
        if char == "\\" and in_double and not escaped:
            escaped = True
            result.append(char)
            continue
        if char == "'" and not in_double:
            in_single = not in_single
        elif char == '"' and not in_single and not escaped:
            in_double = not in_double
        elif char == "#" and not in_single and not in_double:
            break
        result.append(char)
        escaped = False
    return "".join(result).rstrip()


def parse_scalar(value):
    value = value.strip()
    if value == "":
        return ""
    if value in {"null", "Null", "NULL", "~"}:
        return None
    if value in {"true", "True"}:
        return True
    if value in {"false", "False"}:
        return False
    if value == "[]":
        return []
    if value == "{}":
        return {}
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        inner = value[1:-1]
        if value[0] == '"':
            inner = bytes(inner, "utf-8").decode("unicode_escape")
        else:
            inner = inner.replace("''", "'")
        return inner
    if re.fullmatch(r"-?[0-9]+", value):
        return int(value)
    return value


def tokenize(text):
    tokens = []
    for raw_line in text.splitlines():
        cleaned = strip_comments(raw_line)
        if not cleaned.strip():
            continue
        indent = len(cleaned) - len(cleaned.lstrip(" "))
        tokens.append((indent, cleaned.strip()))
    return tokens


def parse_block(tokens, start, indent):
    if start >= len(tokens):
        return None, start
    current_indent, current_text = tokens[start]
    if current_indent != indent:
        fail(f"Unsupported YAML indentation near: {current_text}")
    if current_text.startswith("- "):
        return parse_list(tokens, start, indent)
    return parse_mapping(tokens, start, indent)


def consume_block_scalar(tokens, start, parent_indent):
    lines = []
    index = start
    while index < len(tokens):
        current_indent, text = tokens[index]
        if current_indent <= parent_indent:
            break
        lines.append(text)
        index += 1
    return "\n".join(lines), index


def parse_mapping(tokens, start, indent):
    data = {}
    index = start
    while index < len(tokens):
        current_indent, text = tokens[index]
        if current_indent < indent:
            break
        if current_indent > indent:
            fail(f"Unexpected indentation near: {text}")
        if text.startswith("- "):
            break
        if ":" not in text:
            fail(f"Invalid YAML mapping entry: {text}")
        key, raw_value = text.split(":", 1)
        key = key.strip()
        raw_value = raw_value.strip()
        index += 1
        if raw_value == "":
            if index < len(tokens) and tokens[index][0] > indent:
                value, index = parse_block(tokens, index, tokens[index][0])
            else:
                value = None
        elif raw_value in {"|", "|-", "|+", ">", ">-", ">+"}:
            value, index = consume_block_scalar(tokens, index, indent)
        else:
            value = parse_scalar(raw_value)
        data[key] = value
    return data, index


def parse_list(tokens, start, indent):
    data = []
    index = start
    while index < len(tokens):
        current_indent, text = tokens[index]
        if current_indent < indent:
            break
        if current_indent > indent:
            fail(f"Unexpected indentation near: {text}")
        if not text.startswith("- "):
            break

        item_text = text[2:].strip()
        index += 1

        if item_text == "":
            if index < len(tokens) and tokens[index][0] > indent:
                value, index = parse_block(tokens, index, tokens[index][0])
            else:
                value = None
            data.append(value)
            continue

        if ":" in item_text:
            key, raw_value = item_text.split(":", 1)
            key = key.strip()
            raw_value = raw_value.strip()
            item = {}
            if raw_value == "":
                if index < len(tokens) and tokens[index][0] > indent:
                    nested, index = parse_block(tokens, index, tokens[index][0])
                    if isinstance(nested, dict):
                        item[key] = None
                        item.update(nested)
                    else:
                        item[key] = nested
                else:
                    item[key] = None
            elif raw_value in {"|", "|-", "|+", ">", ">-", ">+"}:
                value, index = consume_block_scalar(tokens, index, indent)
                item[key] = value
            else:
                item[key] = parse_scalar(raw_value)
                if index < len(tokens) and tokens[index][0] > indent:
                    nested, index = parse_block(tokens, index, tokens[index][0])
                    if isinstance(nested, dict):
                        item.update(nested)
                    else:
                        fail(f"Unsupported YAML list structure near: {item_text}")
            data.append(item)
            continue

        data.append(parse_scalar(item_text))

    return data, index


def load_yaml(path):
    try:
        import yaml  # type: ignore
    except Exception:
        yaml = None

    with open(path, "r", encoding="utf-8") as handle:
        raw = handle.read()

    if yaml is not None:
        data = yaml.safe_load(raw)
    else:
        tokens = tokenize(raw)
        if not tokens:
            fail(f"YAML file is empty: {path}")
        data, index = parse_block(tokens, 0, tokens[0][0])
        if index != len(tokens):
            fail(f"Unsupported YAML structure in {path}")

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
  local model
  local reasoning

  cli="$(resolve_config_value "agents.${agent}.cli")"
  model="$(resolve_config_value "agents.${agent}.model")"
  reasoning="$(resolve_config_value "agents.${agent}.reasoning")"

  if [ -z "$cli" ] || [ "$cli" = "null" ]; then
    cli="codex"
  fi
  if [ "$model" = "null" ]; then
    model=""
  fi
  if [ "$reasoning" = "null" ]; then
    reasoning=""
  fi

  AGENT_COMMAND=()
  case "$cli" in
    codex)
      AGENT_COMMAND=(codex exec)
      if [ -n "$model" ]; then
        AGENT_COMMAND+=(--model "$model")
      fi
      ;;
    claude)
      AGENT_COMMAND=(claude --print --permission-mode bypassPermissions)
      if [ -n "$model" ]; then
        AGENT_COMMAND+=(--model "$model")
      fi
      if [ -n "$reasoning" ]; then
        AGENT_COMMAND+=(--effort "$reasoning")
      fi
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
  local prompt_file="/tmp/nexum-generator-feedback-${TASK_ID}.txt"

  CONTEXT_JSON="$context_json" \
  VERDICT="$verdict" \
  FEEDBACK="$feedback" \
  SYSTEM_ERRORS_JSON="$system_errors_json" \
  NEXT_ITERATION="$next_iteration" \
  GENERATOR_TEMPLATE="$GENERATOR_TEMPLATE" \
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
      "last_error=generator_exit_${EXIT_CODE}"
    EVENT_ROLE="generator" EVENT_EXIT_CODE="$EXIT_CODE" EVENT_REASON="generator_exit" append_event "task_failed"
    send_notification "❌ ${TASK_ID} generator 退出失败（exit ${EXIT_CODE}）"
    exit 0
  fi

  BASE_COMMIT="$(json_value "$CONTEXT_JSON" "task.base_commit" || true)"
  [ -n "$BASE_COMMIT" ] || fail "Task ${TASK_ID} missing base_commit"
  [ -n "$CONTRACT_PATH" ] || fail "Task ${TASK_ID} missing contract_path"

  mapfile -t SCOPE_FILES < <(json_array_lines "$CONTEXT_JSON" "contract.scope.files")
  declare -A ALLOWED_FILES=()
  for path in "${SCOPE_FILES[@]}"; do
    ALLOWED_FILES["$path"]=1
  done

  mapfile -t CHANGED_FILES < <(git -C "$PROJECT_DIR" diff "${BASE_COMMIT}..HEAD" --name-only)
  VIOLATIONS=()
  for path in "${CHANGED_FILES[@]}"; do
    [ -n "$path" ] || continue
    if [ -z "${ALLOWED_FILES[$path]+x}" ]; then
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
      EVENT_COMMIT_HASH="$head_commit" \
      EVENT_FILES_JSON="$violations_json" \
      append_event "scope_violation"
    send_notification "⚠️ ${TASK_ID} scope 违规，已冻结
┣ 违规文件: ${VIOLATIONS[*]}
┣ Commit: ${head_commit}（已保留现场）
┗ 建议: 执行 nexum-revert.sh ${TASK_ID} 回滚，或手动检查后继续"
    exit 0
  fi

  head_commit="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
  NEXUM_PROJECT_DIR="$PROJECT_DIR" "$UPDATE_TASK_STATUS_SCRIPT" \
    "$TASK_ID" \
    evaluating \
    "commit_hash=${head_commit}" \
    "eval_result_path=${EVAL_RESULT_PATH}" \
    "last_error=null"
  EVENT_ROLE="generator" EVENT_ITERATION="$ITERATION" EVENT_COMMIT_HASH="$head_commit" append_event "eval_started"

  if [ ! -x "$DISPATCH_EVALUATOR_SCRIPT" ]; then
    NEXUM_PROJECT_DIR="$PROJECT_DIR" "$UPDATE_TASK_STATUS_SCRIPT" \
      "$TASK_ID" \
      failed \
      "last_error=dispatch_evaluator_missing"
    EVENT_ROLE="generator" EVENT_REASON="dispatch_evaluator_missing" append_event "task_failed"
    send_notification "❌ ${TASK_ID} 无法启动 evaluator：缺少 dispatch-evaluator.sh"
    exit 0
  fi

  (
    NEXUM_PROJECT_DIR="$PROJECT_DIR" "$DISPATCH_EVALUATOR_SCRIPT" "$TASK_ID"
  ) >/tmp/nexum-dispatch-evaluator-"$TASK_ID".log 2>&1 &

  send_system_event "OpenNexum task ${TASK_ID} generator finished; evaluator dispatch requested."
  send_notification "🧪 ${TASK_ID} generator 完成，正在进入 eval
┣ Commit: ${head_commit}
┗ Iteration: ${ITERATION}"
  exit 0
fi

if [ ! -f "$EVAL_RESULT_PATH" ]; then
  NEXUM_PROJECT_DIR="$PROJECT_DIR" "$UPDATE_TASK_STATUS_SCRIPT" \
    "$TASK_ID" \
    failed \
    "last_error=eval_result_missing"
  EVENT_ROLE="evaluator" EVENT_REASON="eval_result_missing" EVENT_ITERATION="$ITERATION" EVENT_EXIT_CODE="$EXIT_CODE" append_event "task_failed"
  send_notification "❌ ${TASK_ID} evaluator 未产出结果文件
┣ 期望路径: ${EVAL_RESULT_PATH}
┗ Evaluator exit: ${EXIT_CODE}"
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
    NEXUM_PROJECT_DIR="$PROJECT_DIR" "$UPDATE_TASK_STATUS_SCRIPT" \
      "$TASK_ID" \
      done \
      "completed_at=${completed_at}" \
      "last_error=null"
    EVENT_ROLE="evaluator" \
      EVENT_ITERATION="$ITERATION" \
      EVENT_COMPLETED_AT="$completed_at" \
      EVENT_COMMIT_HASH="$COMMIT_HASH" \
      append_event "task_done"

    duration="$(format_duration "$STARTED_AT" "$completed_at")"
    send_notification "✅ ${TASK_ID} 完成（${ITERATION} 轮迭代）
┣ ⏱ 耗时: ${duration}
┣ 💾 Commit: ${COMMIT_HASH}
┗ 🎯 Eval: ${PASS_COUNT}/${TOTAL_COUNT} criteria passed"

    batch_json="$(all_tasks_done_json)"
    if [ "$(json_value "$batch_json" "all_done" || true)" = "true" ]; then
      batch_id="$(json_value "$batch_json" "batch_id" || true)"
      done_count="$(json_value "$batch_json" "done_count" || true)"
      total_count="$(json_value "$batch_json" "total_count" || true)"
      send_notification "🎉 批次完成
┣ Batch: ${batch_id:-unknown}
┗ Done: ${done_count:-0}/${total_count:-0}"
    fi

    send_system_event "OpenNexum task ${TASK_ID} marked done."
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
        append_event "eval_fail"

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
        send_notification "❌ ${TASK_ID} eval 后重派 generator 失败"
        exit 0
      fi

      retry_hint=""
      if [ "$VERDICT" = "error" ] || [ "$VERDICT" = "inconclusive" ]; then
        retry_hint="
┗ system_errors: $(json_value "$EVAL_JSON" "system_errors" || printf '[]')"
      fi
      send_notification "🔁 ${TASK_ID} eval ${VERDICT}，进入第 ${next_iteration} 轮
┣ Generator: ${GENERATOR_AGENT}
┗ 反馈已注入重试 prompt${retry_hint}"
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

    send_notification "🚨 ${TASK_ID} 需要人工介入（超过 ${MAX_ITERATIONS} 次迭代）
┣ verdict: ${VERDICT}
┣ system_errors: ${SYSTEM_ERRORS_JSON}
┗ 最后 eval 反馈:
${FEEDBACK}"
    send_system_event "OpenNexum task ${TASK_ID} escalated after evaluator verdict ${VERDICT}."
    exit 0
    ;;
  *)
    NEXUM_PROJECT_DIR="$PROJECT_DIR" "$UPDATE_TASK_STATUS_SCRIPT" \
      "$TASK_ID" \
      failed \
      "last_error=unknown_eval_verdict_${VERDICT}"
    EVENT_ROLE="evaluator" EVENT_REASON="unknown_eval_verdict" EVENT_VERDICT="$VERDICT" EVENT_ITERATION="$ITERATION" append_event "task_failed"
    send_notification "❌ ${TASK_ID} evaluator 返回未知 verdict: ${VERDICT}"
    exit 0
    ;;
esac
