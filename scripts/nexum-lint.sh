#!/bin/bash
# Validate OpenNexum contracts and project structure.
# Exit 0 = all checks pass. Exit 1 = one or more violations found.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  nexum-lint.sh [--contract <path>] [--project <path>] [--fix-hints|--no-fix-hints]
EOF
  exit 1
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
YAML_TO_JSON_SCRIPT="${SCRIPT_DIR}/yaml-to-json.sh"

[ -x "$YAML_TO_JSON_SCRIPT" ] || fail "required script not found or not executable: $YAML_TO_JSON_SCRIPT"

PROJECT_DIR="${NEXUM_PROJECT_DIR:-$(pwd -P)}"
CONTRACT_PATH=""
CHECK_PROJECT=0
FIX_HINTS=1
DEFAULT_MODE=1

while [ "$#" -gt 0 ]; do
  DEFAULT_MODE=0
  case "$1" in
    --contract)
      [ "$#" -ge 2 ] || fail "--contract requires a value"
      CONTRACT_PATH="$2"
      shift 2
      ;;
    --project)
      [ "$#" -ge 2 ] || fail "--project requires a value"
      PROJECT_DIR="$2"
      CHECK_PROJECT=1
      shift 2
      ;;
    --fix-hints)
      FIX_HINTS=1
      shift
      ;;
    --no-fix-hints)
      FIX_HINTS=0
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

if [ "$DEFAULT_MODE" -eq 1 ]; then
  CHECK_PROJECT=1
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)" || fail "project directory does not exist: $PROJECT_DIR"

PROJECT_DIR="$PROJECT_DIR" \
CONTRACT_PATH="$CONTRACT_PATH" \
CHECK_PROJECT="$CHECK_PROJECT" \
FIX_HINTS="$FIX_HINTS" \
DEFAULT_MODE="$DEFAULT_MODE" \
YAML_TO_JSON_SCRIPT="$YAML_TO_JSON_SCRIPT" \
python3 - <<'PY'
import json
import os
import re
import subprocess
import sys
from pathlib import Path


VALID_CONTRACT_TYPES = {"coding", "task", "creative"}
VALID_EVAL_TYPES = {"unit", "integration", "e2e", "review", "composite"}
LESSONS_START = "<!-- nexum:lessons:start -->"
LESSONS_END = "<!-- nexum:lessons:end -->"

project_dir = Path(os.environ["PROJECT_DIR"])
contract_path_env = os.environ["CONTRACT_PATH"].strip()
check_project = os.environ["CHECK_PROJECT"] == "1"
fix_hints = os.environ["FIX_HINTS"] == "1"
default_mode = os.environ["DEFAULT_MODE"] == "1"
yaml_to_json_script = os.environ["YAML_TO_JSON_SCRIPT"]

error_count = 0
warning_count = 0


def add_result(symbol, label, code, fix=None):
    global error_count, warning_count
    print(f"{symbol} {label} — {code}")
    if fix_hints and fix:
        print(f"   Fix: {fix}")
    if symbol == "❌":
        error_count += 1
    elif symbol == "⚠️":
        warning_count += 1


def add_ok(label):
    print(f"✅ {label} — OK")


def is_nonempty_text(value):
    return isinstance(value, str) and value.strip() != ""


def has_nonempty_items(value):
    return isinstance(value, list) and any(is_nonempty_text(item) for item in value)


def load_contract(contract_path):
    path = Path(contract_path)
    if not path.is_file():
        return None, "CONTRACT_NOT_FOUND", f"contract file does not exist: {path}"

    result = subprocess.run(
        [yaml_to_json_script, str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        message = result.stderr.strip() or f"Failed to parse YAML: {path}"
        return None, "CONTRACT_PARSE_FAILED", message

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        return None, "CONTRACT_PARSE_FAILED", f"invalid JSON from yaml-to-json.sh: {exc}"

    if not isinstance(data, dict):
        return None, "CONTRACT_PARSE_FAILED", "contract YAML root must be a mapping"
    return data, None, None


def validate_contract(contract_path):
    label = Path(contract_path).name
    contract, parse_code, parse_fix = load_contract(contract_path)
    if contract is None:
        add_result("❌", label, parse_code, parse_fix)
        return

    issues = []

    contract_id = contract.get("id")
    if not (isinstance(contract_id, str) and re.fullmatch(r"[A-Z]+-[0-9]+", contract_id)):
        issues.append(
            (
                "CONTRACT_ID_INVALID",
                "id must match pattern [A-Z]+-[0-9]+ (e.g. TASK-001, FIX-007)",
            )
        )

    contract_type = contract.get("type")
    if contract_type not in VALID_CONTRACT_TYPES:
        issues.append(
            ("CONTRACT_TYPE_INVALID", "type must be one of: coding, task, creative")
        )

    contract_name = contract.get("name")
    if not is_nonempty_text(contract_name):
        issues.append(("NAME_MISSING", "name must be a nonempty string"))

    created_at = contract.get("created_at")
    if not is_nonempty_text(created_at):
        issues.append(("CREATED_AT_MISSING", "created_at must be an ISO 8601 UTC timestamp"))

    max_iterations = contract.get("max_iterations")
    if not isinstance(max_iterations, int) or max_iterations <= 0:
        issues.append(("MAX_ITERATIONS_INVALID", "max_iterations must be a positive integer"))

    depends_on = contract.get("depends_on")
    if not isinstance(depends_on, list):
        issues.append(("DEPENDS_ON_MISSING", "depends_on must be a list (use [] if no dependencies)"))

    scope = contract.get("scope")
    scope_files = scope.get("files") if isinstance(scope, dict) else None
    if not has_nonempty_items(scope_files):
        issues.append(
            (
                "SCOPE_FILES_EMPTY",
                "scope.files must list at least one file the generator may modify",
            )
        )

    scope_boundaries = scope.get("boundaries") if isinstance(scope, dict) else None
    if not isinstance(scope_boundaries, list):
        issues.append(("SCOPE_BOUNDARIES_MISSING", "scope.boundaries must be a list (use [] if unrestricted)"))

    scope_conflicts = scope.get("conflicts_with") if isinstance(scope, dict) else None
    if not isinstance(scope_conflicts, list):
        issues.append(("SCOPE_CONFLICTS_MISSING", "scope.conflicts_with must be a list (use [] if no conflicts)"))

    deliverables = contract.get("deliverables")
    if not has_nonempty_items(deliverables):
        issues.append(
            (
                "DELIVERABLES_EMPTY",
                "deliverables must contain at least one verifiable outcome",
            )
        )

    eval_strategy = contract.get("eval_strategy")
    eval_type = eval_strategy.get("type") if isinstance(eval_strategy, dict) else None
    if eval_type not in VALID_EVAL_TYPES:
        issues.append(
            (
                "EVAL_TYPE_INVALID",
                "eval_strategy.type must be one of: unit, integration, e2e, review, composite",
            )
        )

    if eval_type == "e2e":
        local_url = eval_strategy.get("local_url") if isinstance(eval_strategy, dict) else None
        if not is_nonempty_text(local_url):
            issues.append(
                (
                    "E2E_MISSING_LOCAL_URL",
                    "e2e eval requires eval_strategy.local_url (e.g. http://localhost:3000)",
                )
            )

    criteria = eval_strategy.get("criteria") if isinstance(eval_strategy, dict) else None
    if not isinstance(criteria, list) or len(criteria) == 0:
        issues.append(
            (
                "CRITERIA_EMPTY",
                "eval_strategy.criteria must contain at least one criterion",
            )
        )
    else:
        for index, criterion in enumerate(criteria):
            missing = []
            if not isinstance(criterion, dict):
                missing = ["id", "desc", "method"]
            else:
                for field in ("id", "desc", "method"):
                    if not is_nonempty_text(criterion.get(field)):
                        missing.append(field)
            if missing:
                issues.append(
                    (
                        "CRITERION_INCOMPLETE",
                        f"criterion at index {index} is missing required field: {'/'.join(missing)}",
                    )
                )
            if isinstance(criterion, dict):
                threshold = criterion.get("threshold")
                if threshold not in {"pass", "score"}:
                    issues.append(
                        (
                            "CRITERION_INCOMPLETE",
                            f"criterion at index {index}: threshold must be 'pass' or 'score'",
                        )
                    )
                elif threshold == "score":
                    min_score = criterion.get("min_score")
                    if not isinstance(min_score, (int, float)):
                        issues.append(
                            (
                                "CRITERION_INCOMPLETE",
                                f"criterion at index {index}: min_score must be a number when threshold=score",
                            )
                        )

    if eval_type == "composite":
        sub_strategies = (
            eval_strategy.get("sub_strategies") if isinstance(eval_strategy, dict) else None
        )
        if not isinstance(sub_strategies, list) or len(sub_strategies) == 0:
            issues.append(
                (
                    "COMPOSITE_NO_SUBS",
                    "composite eval requires eval_strategy.sub_strategies",
                )
            )

    generator = contract.get("generator")
    if not is_nonempty_text(generator):
        issues.append(
            (
                "GENERATOR_MISSING",
                "generator must specify the agent (e.g. codex-1, cc-frontend, cc-writer)",
            )
        )

    evaluator = contract.get("evaluator")
    if not is_nonempty_text(evaluator):
        issues.append(
            (
                "EVALUATOR_MISSING",
                "evaluator must specify the agent (e.g. eval)",
            )
        )

    if contract_type == "coding" and generator == "cc-writer":
        issues.append(
            (
                "TYPE_AGENT_MISMATCH",
                "coding contracts should not use cc-writer; use codex-1 or cc-frontend",
            )
        )
    elif contract_type in {"creative", "task"} and is_nonempty_text(generator) and generator != "cc-writer":
        issues.append(
            (
                "TYPE_AGENT_MISMATCH",
                "creative/task contracts should use cc-writer as generator",
            )
        )

    if not issues:
        add_ok(label)
        return

    for code, fix in issues:
        add_result("❌", label, code, fix)


def validate_project(target_dir):
    issues = []
    agents_md = target_dir / "AGENTS.md"
    if not agents_md.is_file():
        issues.append(("AGENTS_MD_MISSING", "Run nexum-init.sh to create AGENTS.md"))
    else:
        content = agents_md.read_text(encoding="utf-8")
        if LESSONS_START not in content or LESSONS_END not in content:
            issues.append(
                (
                    "AGENTS_MD_NO_MARKER",
                    "Add <!-- nexum:lessons:start --> and <!-- nexum:lessons:end --> markers to AGENTS.md",
                )
            )

    if not (target_dir / "nexum" / "active-tasks.json").is_file():
        issues.append(
            (
                "ACTIVE_TASKS_MISSING",
                "Run nexum-init.sh or create nexum/active-tasks.json",
            )
        )

    hook_path = target_dir / ".git" / "hooks" / "post-commit"
    if not hook_path.is_file() or not os.access(hook_path, os.X_OK):
        issues.append(
            (
                "HOOKS_NOT_INSTALLED",
                "Run install-hooks.sh <project_path> to install git hooks",
            )
        )

    if not (target_dir / "nexum" / "runtime" / "eval").is_dir():
        issues.append(
            (
                "EVAL_DIR_MISSING",
                "Run nexum-init.sh or mkdir -p nexum/runtime/eval",
            )
        )

    if not issues:
        add_ok("project")
        return

    for code, fix in issues:
        add_result("⚠️", "project", code, fix)


contract_paths = []
if contract_path_env:
    contract_paths = [Path(contract_path_env).expanduser()]
elif default_mode:
    contracts_dir = project_dir / "docs" / "nexum" / "contracts"
    if contracts_dir.is_dir():
        contract_paths = sorted(
            path for path in contracts_dir.glob("*.yaml") if path.is_file()
        )

if default_mode and not contract_paths:
    print("No contracts found")

for path in contract_paths:
    validate_contract(path)

if check_project:
    validate_project(project_dir)

error_label = "error" if error_count == 1 else "errors"
warning_label = "warning" if warning_count == 1 else "warnings"
summary = f"{error_count} {error_label}, {warning_count} {warning_label}."
if not fix_hints and (error_count > 0 or warning_count > 0):
    summary += " Run with --fix-hints for repair instructions."
print(summary)

raise SystemExit(1 if error_count > 0 else 0)
PY
