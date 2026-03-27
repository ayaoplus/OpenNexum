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
HOOK_PATH="$HOOKS_DIR/post-commit"
BACKUP_PATH="$HOOKS_DIR/post-commit.bak"

if [ ! -w "$PROJECT_PATH/.git" ]; then
  echo "Error: no write permission for git directory: $PROJECT_PATH/.git" >&2
  exit 1
fi

mkdir -p "$HOOKS_DIR" || {
  echo "Error: failed to create hooks directory: $HOOKS_DIR" >&2
  exit 1
}

if [ -e "$HOOK_PATH" ]; then
  cp "$HOOK_PATH" "$BACKUP_PATH" || {
    echo "Error: failed to back up existing hook to $BACKUP_PATH" >&2
    exit 1
  }
fi

cat > "$HOOK_PATH" <<'EOF'
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

chmod +x "$HOOK_PATH" || {
  echo "Error: failed to mark hook executable: $HOOK_PATH" >&2
  exit 1
}

if [ ! -f "$HOOK_PATH" ] || [ ! -x "$HOOK_PATH" ]; then
  echo "Error: hook installation verification failed: $HOOK_PATH" >&2
  exit 1
fi

echo "OpenNexum hooks installed successfully"
echo "Project: $PROJECT_PATH"
echo "Hook: $HOOK_PATH"
if [ -e "$BACKUP_PATH" ]; then
  echo "Backup: $BACKUP_PATH"
else
  echo "Backup: none"
fi
