#!/bin/bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <project_path>" >&2
  exit 1
fi

PROJECT_PATH="$1"

if [ ! -d "$PROJECT_PATH" ]; then
  echo "Error: project path does not exist: $PROJECT_PATH" >&2
  exit 1
fi

if [ ! -d "$PROJECT_PATH/.git" ]; then
  echo "Error: not a git repository: $PROJECT_PATH" >&2
  exit 1
fi

HOOKS_DIR="$PROJECT_PATH/.git/hooks"
POST_HOOK_PATH="$HOOKS_DIR/post-commit"
POST_BACKUP_PATH="$HOOKS_DIR/post-commit.bak"
PRE_HOOK_PATH="$HOOKS_DIR/pre-commit"
PRE_BACKUP_PATH="$HOOKS_DIR/pre-commit.bak"

if [ ! -w "$PROJECT_PATH/.git" ]; then
  echo "Error: no write permission for git directory: $PROJECT_PATH/.git" >&2
  exit 1
fi

mkdir -p "$HOOKS_DIR" || {
  echo "Error: failed to create hooks directory: $HOOKS_DIR" >&2
  exit 1
}

if [ -e "$POST_HOOK_PATH" ]; then
  cp "$POST_HOOK_PATH" "$POST_BACKUP_PATH" || {
    echo "Error: failed to back up existing hook to $POST_BACKUP_PATH" >&2
    exit 1
  }
fi

if [ -e "$PRE_HOOK_PATH" ]; then
  cp "$PRE_HOOK_PATH" "$PRE_BACKUP_PATH" || {
    echo "Error: failed to back up existing hook to $PRE_BACKUP_PATH" >&2
    exit 1
  }
fi

cat > "$PRE_HOOK_PATH" <<'EOF'
#!/bin/bash
# OpenNexum pre-commit hook

set -u

PROJECT_DIR="$(git rev-parse --show-toplevel)"
SCRIPT_DIR="${NEXUM_SKILL_DIR:-$PROJECT_DIR/scripts}"
LINT_SCRIPT="$SCRIPT_DIR/nexum-lint.sh"

if [ ! -x "$LINT_SCRIPT" ]; then
  echo "Warning: nexum-lint.sh not found or not executable at $LINT_SCRIPT; skipping Contract YAML validation." >&2
  exit 0
fi

mapfile -t CONTRACT_FILES < <(
  git diff --cached --name-only --diff-filter=ACMR -- 'docs/nexum/contracts/*.yaml'
)

if [ "${#CONTRACT_FILES[@]}" -eq 0 ]; then
  exit 0
fi

for contract_file in "${CONTRACT_FILES[@]}"; do
  if ! "$LINT_SCRIPT" --contract "$contract_file"; then
    echo "❌ nexum-lint failed for: $contract_file" >&2
    echo "Run: scripts/nexum-lint.sh --contract $contract_file" >&2
    echo "Fix the issues above and re-stage the file." >&2
    exit 1
  fi
done

exit 0
EOF

cat > "$POST_HOOK_PATH" <<'EOF'
#!/bin/bash
# OpenNexum post-commit hook
# DO NOT add any git commit operations here - use dispatch.sh instead

PROJECT_DIR="$(git rev-parse --show-toplevel)"
TASK_ID="${NEXUM_TASK_ID:-unknown}"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HASH="$(git rev-parse HEAD)"

# 1. Write event to events.jsonl (persistent)
echo "{\"event\":\"commit\",\"task_id\":\"$TASK_ID\",\"hash\":\"$HASH\",\"ts\":\"$TIMESTAMP\"}" \
  >> "$PROJECT_DIR/nexum/events.jsonl"

# 2. Push (log failure only; do not block, do not exit non-zero)
git push origin main 2>/dev/null || \
  echo "{\"event\":\"push_failed\",\"task_id\":\"$TASK_ID\",\"hash\":\"$HASH\",\"ts\":\"$TIMESTAMP\"}" \
  >> "$PROJECT_DIR/nexum/events.jsonl"

exit 0
EOF

chmod +x "$PRE_HOOK_PATH" || {
  echo "Error: failed to mark hook executable: $PRE_HOOK_PATH" >&2
  exit 1
}

chmod +x "$POST_HOOK_PATH" || {
  echo "Error: failed to mark hook executable: $POST_HOOK_PATH" >&2
  exit 1
}

if [ ! -f "$PRE_HOOK_PATH" ] || [ ! -x "$PRE_HOOK_PATH" ]; then
  echo "Error: hook installation verification failed: $PRE_HOOK_PATH" >&2
  exit 1
fi

if [ ! -f "$POST_HOOK_PATH" ] || [ ! -x "$POST_HOOK_PATH" ]; then
  echo "Error: hook installation verification failed: $POST_HOOK_PATH" >&2
  exit 1
fi

echo "OpenNexum hooks installed successfully"
echo "Project: $PROJECT_PATH"
echo "Pre-commit hook: $PRE_HOOK_PATH"
if [ -e "$PRE_BACKUP_PATH" ]; then
  echo "Pre-commit backup: $PRE_BACKUP_PATH"
else
  echo "Pre-commit backup: none"
fi
echo "Post-commit hook: $POST_HOOK_PATH"
if [ -e "$POST_BACKUP_PATH" ]; then
  echo "Post-commit backup: $POST_BACKUP_PATH"
else
  echo "Post-commit backup: none"
fi
