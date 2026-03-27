#!/bin/bash
# Build an evaluator prompt from the task contract and dispatch it via dispatch.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
PROJECT_DIR="${NEXUM_PROJECT_DIR:-$(pwd -P)}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"
ACTIVE_TASKS_FILE="${PROJECT_DIR}/nexum/active-tasks.json"
DISPATCH_SCRIPT="${SCRIPT_DIR}/dispatch.sh"
SWARM_CONFIG_SCRIPT="${SCRIPT_DIR}/swarm-config.sh"
PROMPT_TEMPLATE="${SKILL_ROOT}/references/prompt-evaluator.md"

usage() {
  cat >&2 <<'EOF'
Usage:
  dispatch-evaluator.sh <task_id>
EOF
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

resolve_config_value() {
  local path="$1"
  NEXUM_PROJECT_DIR="$PROJECT_DIR" "$SWARM_CONFIG_SCRIPT" get "$path" 2>/dev/null || true
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

[ "$#" -eq 1 ] || usage
TASK_ID="$1"

[ -f "$ACTIVE_TASKS_FILE" ] || fail "Task file not found: $ACTIVE_TASKS_FILE"
[ -x "$DISPATCH_SCRIPT" ] || fail "Missing required script: $DISPATCH_SCRIPT"
[ -x "$SWARM_CONFIG_SCRIPT" ] || fail "Missing required script: $SWARM_CONFIG_SCRIPT"
[ -f "$PROMPT_TEMPLATE" ] || fail "Prompt template not found: $PROMPT_TEMPLATE"

context_output="$(
  TASK_ID="$TASK_ID" \
  PROJECT_DIR="$PROJECT_DIR" \
  ACTIVE_TASKS_FILE="$ACTIVE_TASKS_FILE" \
  PROMPT_TEMPLATE="$PROMPT_TEMPLATE" \
  YAML_TO_JSON_SCRIPT="$SCRIPT_DIR/yaml-to-json.sh" \
  python3 - <<'PY'
import json
import os
import subprocess
import sys
from json import JSONDecodeError

task_id = os.environ["TASK_ID"]
project_dir = os.environ["PROJECT_DIR"]
active_tasks_file = os.environ["ACTIVE_TASKS_FILE"]
prompt_template = os.environ["PROMPT_TEMPLATE"]
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
if isinstance(contract_path, str) and contract_path:
    contract_file = contract_path
    if not os.path.isabs(contract_file):
        contract_file = os.path.join(project_dir, contract_file)
    contract_file = os.path.normpath(contract_file)
else:
    contract_file = os.path.join(project_dir, "docs", "nexum", "contracts", f"{task_id}.yaml")

contract = load_yaml(contract_file)
eval_strategy = contract.get("eval_strategy") if isinstance(contract.get("eval_strategy"), dict) else {}
scope = contract.get("scope") if isinstance(contract.get("scope"), dict) else {}
criteria = as_list(eval_strategy.get("criteria"))

evaluator_agent = contract.get("evaluator")
if not isinstance(evaluator_agent, str) or not evaluator_agent:
    fail(f"Contract missing evaluator agent: {contract_file}")

eval_type = str(eval_strategy.get("type") or "review")
iteration = task.get("iteration")
if not isinstance(iteration, int):
    iteration = 0

max_iterations = contract.get("max_iterations")
if not isinstance(max_iterations, int):
    max_iterations = 1

local_url = eval_strategy.get("local_url")
if not isinstance(local_url, str) or not local_url:
    local_url = ""

eval_dir = os.path.join(project_dir, "nexum", "runtime", "eval")
os.makedirs(eval_dir, exist_ok=True)
eval_result_path = f"nexum/runtime/eval/{task_id}-iter-{iteration}.yaml"

with open(prompt_template, "r", encoding="utf-8") as handle:
    template = handle.read()

rendered = template
replacements = {
    "{{DELIVERABLES}}": bullet_lines(as_list(contract.get("deliverables"))),
    "{{SCOPE_FILES}}": bullet_lines(as_list(scope.get("files"))),
    "{{CRITERIA_LIST}}": criteria_lines(criteria),
    "{{EVAL_RESULT_PATH}}": eval_result_path,
}

for placeholder, value in replacements.items():
    rendered = rendered.replace(placeholder, value)

if eval_type == "e2e":
    local_url = local_url or "http://localhost:3000"
elif not local_url:
    local_url = ""

if local_url:
    rendered = rendered.rstrip() + f"\n\n## Local App\n\n- Eval type: {eval_type}\n- Local URL: {local_url}\n"
else:
    rendered = rendered.rstrip() + f"\n\n## Eval Strategy\n\n- Eval type: {eval_type}\n"

prompt_path = f"/tmp/nexum-eval-prompt-{task_id}.txt"
with open(prompt_path, "w", encoding="utf-8") as handle:
    handle.write(rendered)
    if not rendered.endswith("\n"):
        handle.write("\n")

lines = {
    "EVALUATOR_AGENT": evaluator_agent,
    "ITERATION": str(iteration),
    "MAX_ITERATIONS": str(max_iterations),
    "EVAL_TYPE": eval_type,
    "EVAL_RESULT_PATH": eval_result_path,
    "PROMPT_FILE": prompt_path,
}
for key, value in lines.items():
    print(f"{key}\t{value}")
PY
)"

EVALUATOR_AGENT=""
ITERATION=""
MAX_ITERATIONS=""
EVAL_TYPE=""
EVAL_RESULT_PATH=""
PROMPT_FILE=""

while IFS=$'\t' read -r key value; do
  case "$key" in
    EVALUATOR_AGENT) EVALUATOR_AGENT="$value" ;;
    ITERATION) ITERATION="$value" ;;
    MAX_ITERATIONS) MAX_ITERATIONS="$value" ;;
    EVAL_TYPE) EVAL_TYPE="$value" ;;
    EVAL_RESULT_PATH) EVAL_RESULT_PATH="$value" ;;
    PROMPT_FILE) PROMPT_FILE="$value" ;;
  esac
done <<<"$context_output"

[ -n "$EVALUATOR_AGENT" ] || fail "Failed to resolve evaluator agent for ${TASK_ID}"
[ -n "$PROMPT_FILE" ] || fail "Failed to render evaluator prompt for ${TASK_ID}"
[ -n "$EVAL_RESULT_PATH" ] || fail "Failed to compute eval_result_path for ${TASK_ID}"

build_agent_command "$EVALUATOR_AGENT"

NEXUM_PROJECT_DIR="$PROJECT_DIR" \
  "$DISPATCH_SCRIPT" \
  "$EVALUATOR_AGENT" \
  "$TASK_ID" \
  --role evaluator \
  --prompt-file "$PROMPT_FILE" \
  "${AGENT_COMMAND[@]}"
