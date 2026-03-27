#!/bin/bash
# Dispatch the gardener agent to prune and maintain the shared lesson library.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
PROJECT_DIR="${NEXUM_PROJECT_DIR:-$(pwd -P)}"
LESSONS_DIR="${SKILL_ROOT}/references/lessons"
PROMPT_TEMPLATE="${SKILL_ROOT}/references/prompt-gardener.md"
PROMPT_OUTPUT="/tmp/nexum-gardener-prompt.txt"
DISPATCH_SCRIPT="${SCRIPT_DIR}/dispatch.sh"
SWARM_CONFIG_SCRIPT="${SCRIPT_DIR}/swarm-config.sh"
TASK_DATE_UTC="$(date -u +%Y%m%d)"
TASK_ID="GARDENER-${TASK_DATE_UTC}"
REPORT_DATE_UTC="$(date -u +%F)"
REPORT_PATH="references/gardener-report-${REPORT_DATE_UTC}.md"
ACTIVE_TASKS_FILE=""
CONTRACT_FILE=""
LESSON_COUNT="0"
RECENT_LESSONS=""
RECENT_BASENAMES=()

usage() {
  cat >&2 <<'EOF'
Usage:
  dispatch-gardener.sh [--project <path>]
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
  local model

  cli="$(resolve_config_value "agents.${agent}.cli")"
  model="$(resolve_config_value "agents.${agent}.model")"

  if [ -z "$cli" ] || [ "$cli" = "null" ]; then
    cli="claude"
  fi

  if [ -z "$model" ] || [ "$model" = "null" ]; then
    model="claude-sonnet-4-6"
  fi

  AGENT_COMMAND=()
  case "$cli" in
    codex)
      AGENT_COMMAND=(codex exec -c model_reasoning_effort=high --dangerously-bypass-approvals-and-sandbox)
      ;;
    claude)
      AGENT_COMMAND=(claude --model "$model" --permission-mode bypassPermissions --no-session-persistence --print --output-format json)
      ;;
    *)
      fail "Unsupported CLI '${cli}' for agent '${agent}'"
      ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      [ "$#" -ge 2 ] || usage
      PROJECT_DIR="$2"
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

[ -d "$PROJECT_DIR" ] || fail "project directory does not exist: $PROJECT_DIR"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"
ACTIVE_TASKS_FILE="${PROJECT_DIR}/nexum/active-tasks.json"
CONTRACT_FILE="${PROJECT_DIR}/docs/nexum/contracts/${TASK_ID}.yaml"

if [ ! -f "$PROMPT_TEMPLATE" ]; then
  echo "Error: prompt-gardener.md not found" >&2
  exit 1
fi

if [ ! -x "$DISPATCH_SCRIPT" ]; then
  echo "Error: dispatch.sh not found or not executable" >&2
  exit 1
fi

[ -x "$SWARM_CONFIG_SCRIPT" ] || fail "swarm-config.sh not found or not executable"
command -v python3 >/dev/null 2>&1 || fail "python3 is required but was not found in PATH"
command -v tmux >/dev/null 2>&1 || fail "tmux is required but was not found in PATH"

if [ -d "$LESSONS_DIR" ]; then
  LESSON_COUNT="$(
    find "$LESSONS_DIR" -maxdepth 1 -type f -name '*.md' ! -name 'TEMPLATE.md' -print 2>/dev/null \
      | wc -l \
      | awk '{print $1}'
  )"

  while IFS= read -r lesson_file; do
    [ -n "$lesson_file" ] || continue
    RECENT_BASENAMES+=("$(basename "$lesson_file")")
  done < <(
    find "$LESSONS_DIR" -maxdepth 1 -type f -name '*.md' ! -name 'TEMPLATE.md' -mtime -7 -print 2>/dev/null \
      | LC_ALL=C sort
  )
fi

if [ "${#RECENT_BASENAMES[@]}" -gt 0 ]; then
  RECENT_LESSONS="$(
    RECENT_BASENAMES_JSON="$(printf '%s\n' "${RECENT_BASENAMES[@]}")" python3 - <<'PY'
import os

items = [line.strip() for line in os.environ["RECENT_BASENAMES_JSON"].splitlines() if line.strip()]
print(",".join(items))
PY
  )"
fi

LESSONS_DIR="$LESSONS_DIR" \
LESSON_COUNT="$LESSON_COUNT" \
RECENT_LESSONS="${RECENT_LESSONS:-none}" \
PROMPT_TEMPLATE="$PROMPT_TEMPLATE" \
PROMPT_OUTPUT="$PROMPT_OUTPUT" \
python3 - <<'PY'
import os
import sys

prompt_template = os.environ["PROMPT_TEMPLATE"]
prompt_output = os.environ["PROMPT_OUTPUT"]

with open(prompt_template, "r", encoding="utf-8") as handle:
    rendered = handle.read()

replacements = {
    "{{LESSONS_DIR}}": os.environ["LESSONS_DIR"],
    "{{LESSON_COUNT}}": os.environ["LESSON_COUNT"],
    "{{RECENT_LESSONS}}": os.environ["RECENT_LESSONS"] or "none",
}

for placeholder, value in replacements.items():
    rendered = rendered.replace(placeholder, value)

missing = [placeholder for placeholder in replacements if placeholder in rendered]
if missing:
    print(f"Unresolved prompt placeholders: {', '.join(missing)}", file=sys.stderr)
    raise SystemExit(1)

with open(prompt_output, "w", encoding="utf-8") as handle:
    handle.write(rendered)
    if not rendered.endswith("\n"):
        handle.write("\n")
PY

mkdir -p "$(dirname "$ACTIVE_TASKS_FILE")"
if [ ! -f "$ACTIVE_TASKS_FILE" ]; then
  printf '{\n  "tasks": []\n}\n' > "$ACTIVE_TASKS_FILE"
fi

mkdir -p "$(dirname "$CONTRACT_FILE")"

LESSONS_DIR="$LESSONS_DIR" \
PROJECT_DIR="$PROJECT_DIR" \
REPORT_PATH="$REPORT_PATH" \
CONTRACT_FILE="$CONTRACT_FILE" \
TASK_ID="$TASK_ID" \
python3 - <<'PY'
import os
from datetime import datetime, timezone

project_dir = os.environ["PROJECT_DIR"]
lessons_dir = os.environ["LESSONS_DIR"]
contract_file = os.environ["CONTRACT_FILE"]
task_id = os.environ["TASK_ID"]
report_path = os.environ["REPORT_PATH"]

scope_files = []

if os.path.isdir(lessons_dir):
    for name in sorted(os.listdir(lessons_dir)):
        if not name.endswith(".md") or name == "TEMPLATE.md":
            continue
        path = os.path.join("references", "lessons", name)
        scope_files.append(path)

scope_files.append(report_path)

agents_path = os.path.join(project_dir, "AGENTS.md")
if os.path.isfile(agents_path):
    scope_files.append("AGENTS.md")

scope_files = list(dict.fromkeys(scope_files))

def yaml_quote(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

created_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

lines = [
    f"id: {task_id}",
    f"name: {yaml_quote('Gardener: prune and maintain shared lesson library')}",
    "type: task",
    f"created_at: {yaml_quote(created_at)}",
    "scope:",
    "  files:",
]

for path in scope_files:
    lines.append(f"    - {path}")

lines.extend([
    "  boundaries:",
    "    - references/lessons/",
    "    - references/",
    "  conflicts_with: []",
    "deliverables:",
    "  - Review and prune the shared lesson library under references/lessons/",
    "  - Write the daily gardener report under references/",
    "eval_strategy:",
    "  type: review",
    "  criteria:",
    "    - id: C1",
    "      desc: Rendered gardener prompt was executed against the current lesson library",
    "    - id: C2",
    "      desc: Gardener report and any lesson changes stay within the declared scope",
    "generator: gardener",
    "evaluator: eval",
    "max_iterations: 1",
    "depends_on: []",
])

os.makedirs(os.path.dirname(contract_file), exist_ok=True)
with open(contract_file, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines))
    handle.write("\n")
PY

NEXUM_PROJECT_DIR="$PROJECT_DIR" \
TASK_ID="$TASK_ID" \
CONTRACT_PATH="docs/nexum/contracts/${TASK_ID}.yaml" \
python3 - <<'PY'
import datetime
import json
import os
from json import JSONDecodeError

task_file = os.path.join(os.environ["NEXUM_PROJECT_DIR"], "nexum", "active-tasks.json")
task_id = os.environ["TASK_ID"]
contract_path = os.environ["CONTRACT_PATH"]

directory = os.path.dirname(task_file)
if directory:
    os.makedirs(directory, exist_ok=True)

try:
    with open(task_file, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except (FileNotFoundError, JSONDecodeError):
    data = {"tasks": []}

if not isinstance(data, dict):
    data = {"tasks": []}

tasks = data.get("tasks")
if not isinstance(tasks, list):
    data["tasks"] = []
    tasks = data["tasks"]

existing_ids = {task.get("id") for task in tasks if isinstance(task, dict)}

if task_id not in existing_ids:
    tasks.append({
        "id": task_id,
        "name": "Gardener: prune and maintain shared lesson library",
        "domain": "docs",
        "status": "pending",
        "agent": "gardener",
        "review_level": "skip",
        "depends_on": [],
        "contract_path": contract_path,
        "created_at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    })
    with open(task_file, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print(f"Registered {task_id}")
else:
    for task in tasks:
        if not isinstance(task, dict) or task.get("id") != task_id:
            continue
        task["name"] = "Gardener: prune and maintain shared lesson library"
        task["domain"] = "docs"
        task["agent"] = "gardener"
        task["review_level"] = "skip"
        task["contract_path"] = contract_path
        task.setdefault("depends_on", [])
        break
    with open(task_file, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print(f"Already registered {task_id}")
PY

build_agent_command "gardener"

if ! tmux has-session -t "nexum-gardener" 2>/dev/null; then
  tmux new-session -d -s "nexum-gardener" -c "$PROJECT_DIR"
fi

NEXUM_PROJECT_DIR="$PROJECT_DIR" \
  "$DISPATCH_SCRIPT" \
  gardener \
  "$TASK_ID" \
  --role generator \
  --prompt-file "$PROMPT_OUTPUT" \
  "${AGENT_COMMAND[@]}"
