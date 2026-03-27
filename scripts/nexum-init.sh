#!/bin/bash
# Initialize an OpenNexum project workspace and runtime scaffolding.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  nexum-init.sh --project <name> [--tech "<stack>"] [--type <coding|mixed>]
EOF
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

PROJECT_NAME=""
TECH_STACK=""
AGENT_TYPE="coding"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      [ "$#" -ge 2 ] || fail "--project requires a value"
      PROJECT_NAME="$2"
      shift 2
      ;;
    --tech)
      [ "$#" -ge 2 ] || fail "--tech requires a value"
      TECH_STACK="$2"
      shift 2
      ;;
    --type)
      [ "$#" -ge 2 ] || fail "--type requires a value"
      AGENT_TYPE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[ -n "$PROJECT_NAME" ] || fail "--project is required"
case "$AGENT_TYPE" in
  coding|mixed)
    ;;
  *)
    fail "--type must be one of: coding, mixed"
    ;;
esac

require_command python3
require_command tmux

BASE_DIR="${NEXUM_PROJECT_DIR:-$(pwd -P)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
REFERENCES_DIR="${ROOT_DIR}/references"

[ -d "$BASE_DIR" ] || fail "base directory does not exist: $BASE_DIR"
[ -f "${REFERENCES_DIR}/agents-md-template.md" ] || fail "missing template: ${REFERENCES_DIR}/agents-md-template.md"
[ -f "${REFERENCES_DIR}/defaults.json" ] || fail "missing defaults: ${REFERENCES_DIR}/defaults.json"
[ -f "${REFERENCES_DIR}/lesson-template.md" ] || fail "missing lesson template: ${REFERENCES_DIR}/lesson-template.md"

PROJECT_DIR="${BASE_DIR}/${PROJECT_NAME}"
CURRENT_DATE="$(date -u +%Y-%m-%d)"
TIMESTAMP_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p \
  "${PROJECT_DIR}/docs/design" \
  "${PROJECT_DIR}/docs/lessons" \
  "${PROJECT_DIR}/docs/nexum/contracts" \
  "${PROJECT_DIR}/nexum/runtime/eval" \
  "${PROJECT_DIR}/nexum/runtime/screenshots" \
  "${PROJECT_DIR}/nexum/history"

touch \
  "${PROJECT_DIR}/docs/nexum/contracts/.gitkeep" \
  "${PROJECT_DIR}/nexum/runtime/eval/.gitkeep" \
  "${PROJECT_DIR}/nexum/runtime/screenshots/.gitkeep" \
  "${PROJECT_DIR}/nexum/history/.gitkeep"

render_agents_md() {
  local target_file="$1"
  TEMPLATE_FILE="${REFERENCES_DIR}/agents-md-template.md" \
  TARGET_FILE="$target_file" \
  PROJECT_NAME="$PROJECT_NAME" \
  TECH_STACK="${TECH_STACK:-not specified}" \
  CURRENT_DATE="$CURRENT_DATE" \
  AGENT_TYPE="$AGENT_TYPE" \
  python3 - <<'PY'
import os
import pathlib

template_path = pathlib.Path(os.environ["TEMPLATE_FILE"])
target_path = pathlib.Path(os.environ["TARGET_FILE"])
content = template_path.read_text(encoding="utf-8")

replacements = {
    "{{PROJECT_NAME}}": os.environ["PROJECT_NAME"],
    "{{TECH_STACK}}": os.environ["TECH_STACK"],
    "{{DATE}}": os.environ["CURRENT_DATE"],
    "{{AGENT_TYPE}}": os.environ["AGENT_TYPE"],
    "{{TYPE}}": os.environ["AGENT_TYPE"],
    "{{INJECTED_ANTIPATTERNS}}": "",
}

for placeholder, value in replacements.items():
    content = content.replace(placeholder, value)

target_path.write_text(content, encoding="utf-8")
PY
}

write_defaults_json() {
  local target_file="$1"
  DEFAULTS_FILE="${REFERENCES_DIR}/defaults.json" TARGET_FILE="$target_file" python3 - <<'PY'
import json
import os
import pathlib
from json import JSONDecodeError

source_path = pathlib.Path(os.environ["DEFAULTS_FILE"])
target_path = pathlib.Path(os.environ["TARGET_FILE"])

try:
    data = json.loads(source_path.read_text(encoding="utf-8"))
except JSONDecodeError as exc:
    print(f"Invalid JSON in {source_path}: {exc}", file=os.sys.stderr)
    raise SystemExit(1) from exc

if not isinstance(data, dict):
    print(f"Top-level JSON value in {source_path} must be an object", file=os.sys.stderr)
    raise SystemExit(1)

target_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

write_active_tasks_json() {
  local target_file="$1"
  TARGET_FILE="$target_file" PROJECT_NAME="$PROJECT_NAME" TIMESTAMP_UTC="$TIMESTAMP_UTC" python3 - <<'PY'
import json
import os
import pathlib

target_path = pathlib.Path(os.environ["TARGET_FILE"])
timestamp = os.environ["TIMESTAMP_UTC"]
payload = {
    "batch_id": "init",
    "project": os.environ["PROJECT_NAME"],
    "repo": "",
    "created_at": timestamp,
    "updated_at": timestamp,
    "tasks": [],
}
target_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

write_initial_event() {
  local target_file="$1"
  TARGET_FILE="$target_file" PROJECT_NAME="$PROJECT_NAME" TIMESTAMP_UTC="$TIMESTAMP_UTC" python3 - <<'PY'
import json
import os
import pathlib

target_path = pathlib.Path(os.environ["TARGET_FILE"])
event = {
    "event": "project_initialized",
    "project": os.environ["PROJECT_NAME"],
    "ts": os.environ["TIMESTAMP_UTC"],
}
target_path.write_text(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
PY
}

copy_if_missing() {
  local source_file="$1"
  local target_file="$2"
  if [ ! -e "$target_file" ]; then
    cp "$source_file" "$target_file"
  fi
}

if [ ! -e "${PROJECT_DIR}/AGENTS.md" ]; then
  render_agents_md "${PROJECT_DIR}/AGENTS.md"
fi

if [ ! -e "${PROJECT_DIR}/CLAUDE.md" ] && [ -f "${PROJECT_DIR}/AGENTS.md" ]; then
  cp "${PROJECT_DIR}/AGENTS.md" "${PROJECT_DIR}/CLAUDE.md"
fi

copy_if_missing "${REFERENCES_DIR}/lesson-template.md" "${PROJECT_DIR}/docs/lessons/TEMPLATE.md"

if [ ! -e "${PROJECT_DIR}/nexum/config.json" ]; then
  write_defaults_json "${PROJECT_DIR}/nexum/config.json"
fi

if [ ! -e "${PROJECT_DIR}/nexum/active-tasks.json" ]; then
  write_active_tasks_json "${PROJECT_DIR}/nexum/active-tasks.json"
fi

if [ ! -e "${PROJECT_DIR}/nexum/events.jsonl" ]; then
  write_initial_event "${PROJECT_DIR}/nexum/events.jsonl"
fi

GITIGNORE_FILE="${PROJECT_DIR}/.gitignore"
SCREENSHOT_RULE="nexum/runtime/screenshots/"
if [ -f "$GITIGNORE_FILE" ]; then
  if ! grep -Fxq "$SCREENSHOT_RULE" "$GITIGNORE_FILE"; then
    printf '%s\n' "$SCREENSHOT_RULE" >> "$GITIGNORE_FILE"
  fi
else
  printf '%s\n' "$SCREENSHOT_RULE" > "$GITIGNORE_FILE"
fi

if command -v install-hooks.sh >/dev/null 2>&1; then
  HOOK_INSTALLER="$(command -v install-hooks.sh)"
else
  HOOK_INSTALLER="${SCRIPT_DIR}/install-hooks.sh"
fi
[ -f "$HOOK_INSTALLER" ] || fail "install-hooks.sh not found"
if [ ! -d "${PROJECT_DIR}/.git" ]; then
  git init "$PROJECT_DIR" >/dev/null
  echo "🔧 git init: ${PROJECT_DIR}"
fi
"$HOOK_INSTALLER" "$PROJECT_DIR" >/dev/null

for session_name in \
  nexum-plan \
  nexum-codex-1 \
  nexum-codex-frontend \
  nexum-cc-frontend \
  nexum-eval
do
  if ! tmux has-session -t "$session_name" 2>/dev/null; then
    tmux new-session -d -s "$session_name" -c "$PROJECT_DIR"
  fi
done

echo "✅ OpenNexum initialized: ${PROJECT_NAME}"
echo "📁 Project dir: ${PROJECT_DIR}"
echo "📋 AGENTS.md generated"
echo "🔧 Config: nexum/config.json"
echo "🪝 Git hooks installed"
echo "🖥️  tmux sessions: nexum-plan, nexum-codex-1, nexum-codex-frontend, nexum-cc-frontend, nexum-eval"
