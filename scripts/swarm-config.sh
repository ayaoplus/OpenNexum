#!/bin/bash
# Merge OpenNexum skill defaults with project overrides and expose config helpers.
set -euo pipefail

PROJECT_DIR="${NEXUM_PROJECT_DIR:-$(pwd -P)}"
CONFIG_FILE="${PROJECT_DIR}/nexum/config.json"
DEFAULTS_FILE="${HOME}/.openclaw/workspace/skills/opennexum/references/defaults.json"

usage() {
  cat >&2 <<'EOF'
Usage:
  swarm-config.sh get <dot.path>
  swarm-config.sh set <dot.path> <value>
  swarm-config.sh show
  swarm-config.sh resolve <dot.path>
EOF
  exit 1
}

python_read() {
  python3 - "$@" <<'PY'
import json
import os
import re
import sys
from json import JSONDecodeError

DEFAULTS_FILE = os.environ["DEFAULTS_FILE"]
CONFIG_FILE = os.environ["CONFIG_FILE"]


def fallback_defaults():
    return {
        "agents": {
            "plan": {"cli": "claude", "model": "claude-opus-4-6"},
            "codex-1": {"cli": "codex", "model": "gpt-5.4", "reasoning": "high"},
            "codex-frontend": {"cli": "codex", "model": "gpt-5.4", "reasoning": "medium"},
            "cc-frontend": {"cli": "claude", "model": "claude-sonnet-4-6"},
            "cc-writer": {"cli": "claude", "model": "claude-sonnet-4-6"},
            "eval": {"cli": "codex", "model": "gpt-5.4", "reasoning": "high"},
            "gardener": {"cli": "claude", "model": "claude-sonnet-4-6"},
        },
        "notify": {"verbose_dispatch": True},
        "harvest": {"auto_trigger": True},
    }


def load_json_file(path, *, optional=False, fallback=None):
    if optional and not os.path.exists(path):
        return fallback() if fallback is not None else {}

    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        if fallback is not None:
            return fallback()
        raise
    except JSONDecodeError as exc:
        print(f"Invalid JSON in {path}: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc

    if not isinstance(data, dict):
        print(f"Top-level JSON value in {path} must be an object", file=sys.stderr)
        raise SystemExit(1)
    return data


def deep_merge(base, override):
    merged = dict(base)
    for key, value in override.items():
        if isinstance(merged.get(key), dict) and isinstance(value, dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def get_by_path(data, dot_path):
    current = data
    for segment in dot_path.split("."):
        if not isinstance(current, dict) or segment not in current:
            return False, None
        current = current[segment]
    return True, current


def resolve_env(value):
    if isinstance(value, str):
        return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", lambda m: os.environ.get(m.group(1), ""), value)
    if isinstance(value, list):
        return [resolve_env(item) for item in value]
    if isinstance(value, dict):
        return {key: resolve_env(item) for key, item in value.items()}
    return value


def emit(value, *, pretty=False):
    if isinstance(value, str):
        sys.stdout.write(value)
        return
    kwargs = {"ensure_ascii": False}
    if pretty:
        kwargs["indent"] = 2
    sys.stdout.write(json.dumps(value, **kwargs))


command = sys.argv[1]
dot_path = sys.argv[2] if len(sys.argv) > 2 else None

defaults = load_json_file(DEFAULTS_FILE, optional=True, fallback=fallback_defaults)
project = load_json_file(CONFIG_FILE, optional=True, fallback=dict)
merged = deep_merge(defaults, project)

if command == "show":
    emit(merged, pretty=True)
    sys.stdout.write("\n")
elif command in {"get", "resolve"}:
    if not dot_path:
        print("dot.path is required", file=sys.stderr)
        raise SystemExit(1)
    found, value = get_by_path(merged, dot_path)
    if not found:
        raise SystemExit(0)
    if command == "resolve":
        value = resolve_env(value)
    emit(value)
    if not isinstance(value, str):
        sys.stdout.write("\n")
else:
    print(f"Unsupported command: {command}", file=sys.stderr)
    raise SystemExit(1)
PY
}

python_set() {
  python3 - "$@" <<'PY'
import json
import os
import sys
import tempfile
import fcntl
from json import JSONDecodeError

CONFIG_FILE = os.environ["CONFIG_FILE"]
DOT_PATH = sys.argv[1]
RAW_VALUE = sys.argv[2]
LOCK_FILE = os.environ.get("LOCK_FILE")


def parse_value(raw):
    try:
        return json.loads(raw)
    except JSONDecodeError:
        return raw


def load_project():
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as handle:
                project = json.load(handle)
        except JSONDecodeError as exc:
            print(f"Invalid JSON in {CONFIG_FILE}: {exc}", file=sys.stderr)
            raise SystemExit(1) from exc
        if not isinstance(project, dict):
            print(f"Top-level JSON value in {CONFIG_FILE} must be an object", file=sys.stderr)
            raise SystemExit(1)
        return project
    return {}


def write_project(project):
    directory = os.path.dirname(CONFIG_FILE)
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".config.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(project, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_path, CONFIG_FILE)
    finally:
        if os.path.exists(tmp_path):
            os.unlink(tmp_path)


def update_config():
    project = load_project()
    segments = DOT_PATH.split(".")
    cursor = project
    for segment in segments[:-1]:
        existing = cursor.get(segment)
        if existing is None:
            cursor[segment] = {}
            existing = cursor[segment]
        if not isinstance(existing, dict):
            print(f"Cannot set nested path through non-object at '{segment}'", file=sys.stderr)
            raise SystemExit(1)
        cursor = existing

    cursor[segments[-1]] = parse_value(RAW_VALUE)
    write_project(project)


if LOCK_FILE:
    with open(LOCK_FILE, "a+", encoding="utf-8") as lock_handle:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        update_config()
else:
    update_config()
PY
}

if [ "$#" -lt 1 ]; then
  usage
fi

COMMAND="$1"
shift

case "$COMMAND" in
  get)
    [ "$#" -eq 1 ] || usage
    DEFAULTS_FILE="$DEFAULTS_FILE" CONFIG_FILE="$CONFIG_FILE" python_read get "$1"
    ;;
  set)
    [ "$#" -eq 2 ] || usage
    mkdir -p "$(dirname "$CONFIG_FILE")"
    LOCK_FILE="${CONFIG_FILE}.lock"
    if command -v flock >/dev/null 2>&1; then
      (
        flock -x 200
        CONFIG_FILE="$CONFIG_FILE" python_set "$1" "$2"
      ) 200>"$LOCK_FILE"
    else
      LOCK_FILE="$LOCK_FILE" CONFIG_FILE="$CONFIG_FILE" python_set "$1" "$2"
    fi
    ;;
  show)
    [ "$#" -eq 0 ] || usage
    DEFAULTS_FILE="$DEFAULTS_FILE" CONFIG_FILE="$CONFIG_FILE" python_read show
    ;;
  resolve)
    [ "$#" -eq 1 ] || usage
    DEFAULTS_FILE="$DEFAULTS_FILE" CONFIG_FILE="$CONFIG_FILE" python_read resolve "$1"
    ;;
  *)
    usage
    ;;
esac
