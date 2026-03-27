#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
PROJECT_DIR="${NEXUM_PROJECT_DIR:-$(pwd -P)}"
PROJECT_DIR="$(cd "${PROJECT_DIR}" && pwd -P)"
SCRIPTS_DIR="${SCRIPT_DIR}"
YAML_TO_JSON_SCRIPT="${SCRIPTS_DIR}/yaml-to-json.sh"
SWARM_CONFIG_SCRIPT="${SCRIPTS_DIR}/swarm-config.sh"

STATE_FILE="${PROJECT_DIR}/nexum/.harvest-state.json"
ACTIVE_TASKS_FILE="${PROJECT_DIR}/nexum/active-tasks.json"
LESSONS_DIR="${PROJECT_DIR}/docs/lessons"
AGENTS_FILE="${PROJECT_DIR}/AGENTS.md"
PROCESS_LESSONS_DIR="${SKILL_ROOT}/references/lessons"

usage() {
  cat >&2 <<'EOF'
Usage:
  harvest.sh
EOF
  exit 1
}

timestamp_utc() {
  python3 - <<'PY'
from datetime import datetime, timezone

print(datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z"))
PY
}

send_notification() {
  local target

  target="$(NEXUM_PROJECT_DIR="$PROJECT_DIR" "$SCRIPTS_DIR/swarm-config.sh" get notify.target 2>/dev/null || echo "/dev/null")"
  if [ -z "$target" ] || [ "$target" = "null" ] || [ "$target" = "/dev/null" ]; then
    return 0
  fi
  if ! command -v openclaw >/dev/null 2>&1; then
    return 0
  fi

  openclaw message send --channel telegram --target "$target" -m "$1" >/dev/null 2>&1 || true
}

[ "$#" -eq 0 ] || usage
[ -x "$YAML_TO_JSON_SCRIPT" ] || {
  echo "Missing dependency: $YAML_TO_JSON_SCRIPT" >&2
  exit 1
}

summary_json="$(
  PROJECT_DIR="$PROJECT_DIR" \
  SKILL_ROOT="$SKILL_ROOT" \
  YAML_TO_JSON_SCRIPT="$YAML_TO_JSON_SCRIPT" \
  STATE_FILE="$STATE_FILE" \
  ACTIVE_TASKS_FILE="$ACTIVE_TASKS_FILE" \
  LESSONS_DIR="$LESSONS_DIR" \
  AGENTS_FILE="$AGENTS_FILE" \
  PROCESS_LESSONS_DIR="$PROCESS_LESSONS_DIR" \
  HARVESTED_AT="$(timestamp_utc)" \
  python3 - <<'PY'
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from difflib import unified_diff
from pathlib import Path

project_dir = Path(os.environ["PROJECT_DIR"])
skill_root = Path(os.environ["SKILL_ROOT"])
yaml_to_json_script = Path(os.environ["YAML_TO_JSON_SCRIPT"])
state_file = Path(os.environ["STATE_FILE"])
active_tasks_file = Path(os.environ["ACTIVE_TASKS_FILE"])
lessons_dir = Path(os.environ["LESSONS_DIR"])
agents_file = Path(os.environ["AGENTS_FILE"])
process_lessons_dir = Path(os.environ["PROCESS_LESSONS_DIR"])
harvested_at = os.environ["HARVESTED_AT"]

START_MARKER = "<!-- nexum:lessons:start -->"
END_MARKER = "<!-- nexum:lessons:end -->"
DEFAULT_INTERVAL_LINE = "<!-- 由 gardener 自动维护，请勿手动修改此区间 -->"
NEGATION_TOKENS = {"not", "never", "no", "avoid", "dont", "don't", "cannot", "can't", "without"}
STOPWORDS = {
    "a",
    "an",
    "and",
    "the",
    "to",
    "of",
    "for",
    "in",
    "on",
    "or",
    "be",
    "is",
    "are",
    "with",
    "that",
    "this",
    "when",
    "then",
    "do",
    "does",
    "did",
    "always",
    "must",
    "should",
    "use",
}


def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_iso8601(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def ensure_parent(path):
    path.parent.mkdir(parents=True, exist_ok=True)


def atomic_write_json(path, payload):
    ensure_parent(path)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=str(path.parent), encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
        tmp_path = handle.name
    os.replace(tmp_path, path)


def atomic_write_text(path, content):
    ensure_parent(path)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=str(path.parent), encoding="utf-8") as handle:
        handle.write(content)
        tmp_path = handle.name
    os.replace(tmp_path, path)


def load_state():
    if state_file.exists():
        with state_file.open("r", encoding="utf-8") as handle:
            try:
                data = json.load(handle)
            except json.JSONDecodeError as exc:
                raise SystemExit(f"Invalid JSON in {state_file}: {exc}") from exc
        if not isinstance(data, dict):
            raise SystemExit(f"Harvest state must be an object: {state_file}")
    else:
        data = {}

    processed = data.get("processed_files")
    if not isinstance(processed, list):
        processed = []

    state = {
        "last_batch_id": data.get("last_batch_id") or "",
        "last_harvest_at": data.get("last_harvest_at") or "",
        "processed_files": [str(item) for item in processed if isinstance(item, str)],
    }

    if not state_file.exists():
        atomic_write_json(state_file, state)

    return state


def resolve_batch_id(previous_batch_id):
    if active_tasks_file.exists():
        try:
            with active_tasks_file.open("r", encoding="utf-8") as handle:
                payload = json.load(handle)
            batch_id = payload.get("batch_id")
            if isinstance(batch_id, str) and batch_id:
                return batch_id
        except (OSError, json.JSONDecodeError):
            pass
    return previous_batch_id or ""


def rel_project(path):
    try:
        return path.relative_to(project_dir).as_posix()
    except ValueError:
        return path.as_posix()


def normalize_text(value):
    if value is None:
        return ""
    if isinstance(value, list):
        value = " ".join(str(item) for item in value)
    text = str(value).strip()
    text = re.sub(r"\s+", " ", text)
    return text


def tokenize_words(value):
    return {token for token in re.findall(r"\w+", normalize_text(value).lower()) if token}


def similarity(left, right):
    left_words = tokenize_words(left)
    right_words = tokenize_words(right)
    if not left_words and not right_words:
        return 1.0
    if not left_words or not right_words:
        return 0.0
    union = left_words | right_words
    if not union:
        return 0.0
    return len(left_words & right_words) / len(union)


def contradiction(left, right):
    left_text = normalize_text(left).lower()
    right_text = normalize_text(right).lower()
    left_words = tokenize_words(left_text) - STOPWORDS
    right_words = tokenize_words(right_text) - STOPWORDS
    overlap_union = left_words | right_words
    overlap_score = 0.0
    if overlap_union:
        overlap_score = len(left_words & right_words) / len(overlap_union)

    left_neg = any(token in NEGATION_TOKENS for token in tokenize_words(left_text))
    right_neg = any(token in NEGATION_TOKENS for token in tokenize_words(right_text))
    if left_neg != right_neg and overlap_score >= 0.25:
        return True

    return False


def parse_markdown_lesson(path):
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SystemExit(f"Failed to read lesson file {path}: {exc}") from exc

    title = ""
    mapping_lines = []
    for line in raw.splitlines():
        match = re.match(r"^##\s+Lesson:\s*(.+?)\s*$", line)
        if match:
            title = match.group(1).strip()
            continue
        bullet = re.match(r"^\s*-\s*([A-Za-z0-9_]+)\s*:\s*(.*)\s*$", line)
        if bullet:
            key = bullet.group(1).strip()
            value = bullet.group(2).strip()
            mapping_lines.append(f"{key}: {value}")

    if not mapping_lines:
        raise SystemExit(f"Lesson file does not contain YAML bullet fields: {path}")

    yaml_lines = [f"title: {json.dumps(title, ensure_ascii=False)}", *mapping_lines]
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".yaml", encoding="utf-8") as handle:
        handle.write("\n".join(yaml_lines))
        handle.write("\n")
        tmp_yaml = handle.name

    try:
        result = subprocess.run(
            [str(yaml_to_json_script), tmp_yaml],
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.strip() or exc.stdout.strip()
        raise SystemExit(f"Failed to parse lesson file {path}: {stderr}") from exc
    finally:
        try:
            os.unlink(tmp_yaml)
        except OSError:
            pass

    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON returned while parsing {path}: {exc}") from exc

    tags = payload.get("tags")
    if tags is None:
        tags_list = []
    elif isinstance(tags, list):
        tags_list = [normalize_text(item) for item in tags if normalize_text(item)]
    else:
        tag_text = normalize_text(tags)
        if tag_text.startswith("[") and tag_text.endswith("]"):
            tag_text = tag_text[1:-1]
        tags_list = [part.strip() for part in tag_text.split(",") if part.strip()]

    record = {
        "tags": tags_list,
        "source": rel_project(path),
        "mtime": path.stat().st_mtime,
    }
    for key, value in payload.items():
        if key == "tags":
            continue
        record[key] = normalize_text(value)

    record.setdefault("title", "")
    record.setdefault("trigger", "")
    record.setdefault("wrong", "")
    record.setdefault("right", "")
    record.setdefault("affected", "")
    record.setdefault("agent_note", "")

    if not record["title"]:
        record["title"] = path.stem

    return record


def discover_lesson_files():
    if not lessons_dir.exists():
        return []
    files = []
    for path in sorted(lessons_dir.glob("*.md")):
        if path.name.upper() == "TEMPLATE.MD":
            continue
        files.append(path)
    return files


def classify_lesson(record):
    has_affected = bool(record["affected"])
    has_agent_note = bool(record["agent_note"])
    if has_affected and not has_agent_note:
        return "technical"
    if has_agent_note and not has_affected:
        return "process"
    return "invalid"


def compare_lesson(candidate, accepted):
    for existing in accepted:
        if candidate["affected"] != existing["affected"]:
            continue
        if similarity(candidate["right"], existing["right"]) > 0.8:
            return "DUPLICATE", existing
        if similarity(candidate["trigger"], existing["trigger"]) >= 0.8 and contradiction(candidate["right"], existing["right"]):
            return "CONTRADICTION", existing
    return None, None


def render_interval(lessons):
    lines = [DEFAULT_INTERVAL_LINE]
    for lesson in lessons:
        meta = {
            "source": lesson["source"],
            "title": lesson["title"],
            "affected": lesson["affected"],
            "trigger": lesson["trigger"],
            "right": lesson["right"],
            "wrong": lesson["wrong"],
            "tags": lesson["tags"],
        }
        summary_bits = []
        if lesson["trigger"]:
            summary_bits.append(f"When {lesson['trigger']}")
        if lesson["right"]:
            summary_bits.append(lesson["right"])
        if lesson["wrong"]:
            summary_bits.append(f"Avoid {lesson['wrong']}")
        if lesson["tags"]:
            summary_bits.append("Tags: " + ", ".join(lesson["tags"]))
        summary_bits.append(f"Source: {lesson['source']}")

        lines.append(f"<!-- nexum:lesson {json.dumps(meta, ensure_ascii=False, separators=(',', ':'))} -->")
        lines.append(f"- `{lesson['affected']}` — {'; '.join(summary_bits)}")
    return "\n".join(lines)


def find_interval(content):
    lines = content.splitlines()
    try:
        start = lines.index(START_MARKER)
        end = lines.index(END_MARKER)
    except ValueError:
        return None
    if end <= start:
        return None
    current = "\n".join(lines[start + 1:end])
    return {"lines": lines, "start": start, "end": end, "current": current}


def git_blame_detects_manual_changes(interval, last_harvest_at_value):
    if not last_harvest_at_value:
        return False

    harvest_dt = parse_iso8601(last_harvest_at_value)
    if harvest_dt is None:
        return False

    if interval["end"] <= interval["start"] + 1:
        return False

    rel_agents = rel_project(agents_file)
    try:
        result = subprocess.run(
            [
                "git",
                "blame",
                "--line-porcelain",
                f"-L{interval['start'] + 2},{interval['end']}",
                "--",
                rel_agents,
            ],
            cwd=str(project_dir),
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError:
        return False

    author_time = None
    for raw_line in result.stdout.splitlines():
        if raw_line.startswith("author-time "):
            try:
                author_time = int(raw_line.split(" ", 1)[1])
            except ValueError:
                author_time = None
        elif raw_line.startswith("\t"):
            line_text = raw_line[1:].strip()
            if not line_text:
                continue
            if author_time is None:
                continue
            if author_time > int(harvest_dt.timestamp()):
                return True
    return False


def update_agents_file(rendered_interval, last_harvest_at_value):
    result = {
        "updated": False,
        "blocked": False,
        "reason": "",
        "diff_excerpt": "",
    }

    if not agents_file.exists():
        result["blocked"] = True
        result["reason"] = f"Missing AGENTS.md at {rel_project(agents_file) if agents_file.is_relative_to(project_dir) else agents_file}"
        return result

    original = agents_file.read_text(encoding="utf-8")
    interval = find_interval(original)
    if interval is None:
        result["blocked"] = True
        result["reason"] = "AGENTS.md is missing nexum lesson markers"
        return result

    if git_blame_detects_manual_changes(interval, last_harvest_at_value) and interval["current"] != rendered_interval:
        diff_lines = list(
            unified_diff(
                interval["current"].splitlines(),
                rendered_interval.splitlines(),
                fromfile="AGENTS.md current",
                tofile="AGENTS.md proposed",
                lineterm="",
            )
        )
        result["blocked"] = True
        result["reason"] = "AGENTS.md lesson interval has committed changes after the last harvest"
        result["diff_excerpt"] = "\n".join(diff_lines[:24])
        return result

    if interval["current"] == rendered_interval:
        return result

    new_lines = interval["lines"][: interval["start"] + 1] + rendered_interval.splitlines() + interval["lines"][interval["end"] :]
    new_content = "\n".join(new_lines)
    if original.endswith("\n"):
        new_content += "\n"
    atomic_write_text(agents_file, new_content)
    result["updated"] = True
    return result


def slugify(value):
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-")
    return slug or "lesson"


def build_process_mirror(project_name, lesson):
    tags = ", ".join(lesson["tags"])
    lines = [
        f"## Lesson: {lesson['title']}",
        f"- trigger: {json.dumps(lesson['trigger'], ensure_ascii=False)}",
        f"- wrong: {json.dumps(lesson['wrong'], ensure_ascii=False)}",
        f"- right: {json.dumps(lesson['right'], ensure_ascii=False)}",
        f"- agent_note: {json.dumps(lesson['agent_note'], ensure_ascii=False)}",
        f"- tags: [{tags}]" if tags else "- tags: []",
        f"- source_project: {json.dumps(project_name, ensure_ascii=False)}",
        f"- source_file: {json.dumps(lesson['source'], ensure_ascii=False)}",
    ]
    return "\n".join(lines) + "\n"


def load_existing_process_notes():
    existing_notes = {}
    existing_sources = {}
    if not process_lessons_dir.exists():
        return existing_notes, existing_sources

    for path in sorted(process_lessons_dir.glob("*.md")):
        if path.stem == "TEMPLATE":
            continue
        try:
            record = parse_markdown_lesson(path)
        except SystemExit as exc:
            parse_errors.append({"path": str(path), "error": str(exc)})
            continue
        note_key = normalize_text(record.get("agent_note", "")).lower()
        source_project = normalize_text(record.get("source_project", ""))
        source_file = normalize_text(record.get("source_file", ""))
        source_key = f"{source_project}::{source_file}".strip(":")
        if note_key:
            existing_notes.setdefault(note_key, str(path))
        if source_key:
            existing_sources[source_key] = str(path)
    return existing_notes, existing_sources


parse_errors = []
state = load_state()
last_harvest_at = state["last_harvest_at"]
last_harvest_dt = parse_iso8601(last_harvest_at)

lesson_files = discover_lesson_files()
parsed_lessons = []
for lesson_path in lesson_files:
    try:
        parsed_lessons.append(parse_markdown_lesson(lesson_path))
    except SystemExit as exc:
        parse_errors.append({"path": str(lesson_path), "error": str(exc)})

new_sources = set()
if last_harvest_dt is None:
    new_sources = {lesson["source"] for lesson in parsed_lessons}
else:
    for lesson in parsed_lessons:
        if lesson["mtime"] > last_harvest_dt.timestamp():
            new_sources.add(lesson["source"])

technical_all = []
process_all = []
invalid_lessons = []
for lesson in parsed_lessons:
    lesson_type = classify_lesson(lesson)
    lesson["type"] = lesson_type
    if lesson_type == "technical":
        technical_all.append(lesson)
    elif lesson_type == "process":
        process_all.append(lesson)
    else:
        invalid_lessons.append(lesson)

technical_all.sort(key=lambda item: item["source"])
accepted_technical = []
all_conflicts = []
new_conflicts = []
new_accepted_technical = []
for lesson in technical_all:
    conflict_type, existing = compare_lesson(lesson, accepted_technical)
    if conflict_type:
        conflict = {
            "type": conflict_type,
            "source": lesson["source"],
            "against": existing["source"],
            "affected": lesson["affected"],
            "trigger": lesson["trigger"],
            "right": lesson["right"],
            "existing_right": existing["right"],
        }
        all_conflicts.append(conflict)
        if lesson["source"] in new_sources:
            new_conflicts.append(conflict)
        continue

    accepted_technical.append(lesson)
    if lesson["source"] in new_sources:
        new_accepted_technical.append(lesson)

project_name = project_dir.name
existing_process_notes, existing_process_sources = load_existing_process_notes()
process_lessons_dir.mkdir(parents=True, exist_ok=True)
process_written = 0
for lesson in process_all:
    if lesson["source"] not in new_sources:
        continue
    source_key = f"{project_name}::{lesson['source']}"
    note_key = normalize_text(lesson["agent_note"]).lower()
    source_stub = lesson["source"]
    if source_stub.endswith(".md"):
        source_stub = source_stub[:-3]
    target_name = slugify(f"{project_name}--{source_stub.replace('/', '--')}")
    target_path = process_lessons_dir / f"{target_name}.md"
    content = build_process_mirror(project_name, lesson)

    if note_key and note_key in existing_process_notes and existing_process_notes[note_key] != str(target_path):
        continue

    previous_content = None
    if target_path.exists():
        previous_content = target_path.read_text(encoding="utf-8")

    if previous_content != content:
        atomic_write_text(target_path, content)
        process_written += 1

    if note_key:
        existing_process_notes[note_key] = str(target_path)
    existing_process_sources[source_key] = str(target_path)

rendered_interval = render_interval(accepted_technical)
agents_result = {
    "updated": False,
    "blocked": False,
    "reason": "",
    "diff_excerpt": "",
}
if agents_file.exists() or new_accepted_technical:
    agents_result = update_agents_file(rendered_interval, last_harvest_at)

processed_sources = []
if new_sources:
    processed_sources = sorted(new_sources)
    seen = set(state["processed_files"])
    merged_processed = list(state["processed_files"])
    for source in processed_sources:
        if source not in seen:
            merged_processed.append(source)
            seen.add(source)

    new_state = {
        "last_batch_id": resolve_batch_id(state["last_batch_id"]),
        "last_harvest_at": harvested_at,
        "processed_files": merged_processed,
    }
    atomic_write_json(state_file, new_state)

duplicate_count = sum(1 for item in new_conflicts if item["type"] == "DUPLICATE")
contradiction_count = sum(1 for item in new_conflicts if item["type"] == "CONTRADICTION")
issue_count = len(new_conflicts)
if invalid_lessons:
    issue_count += len([item for item in invalid_lessons if item["source"] in new_sources])
if agents_result["blocked"] and new_accepted_technical:
    issue_count += 1

message = ""
if new_sources:
    if issue_count == 0:
        message = f"🌱 Harvested {len(new_sources)} lessons (auto-merged)"
    else:
        message = f"🌱 Harvest: {len(new_sources)} lessons, {issue_count} conflicts need review"

    details = []
    if duplicate_count:
        details.append(f"duplicates={duplicate_count}")
    if contradiction_count:
        details.append(f"contradictions={contradiction_count}")
    if process_written:
        details.append(f"process_written={process_written}")
    if agents_result["updated"]:
        details.append("agents=updated")
    elif new_accepted_technical:
        details.append("agents=unchanged")

    if details:
        message += "\n" + " | ".join(details)

    for invalid in invalid_lessons:
        if invalid["source"] in new_sources:
            message += f"\n- invalid lesson: {invalid['source']} (must set exactly one of affected or agent_note)"

    for conflict in new_conflicts[:3]:
        prefix = "duplicate" if conflict["type"] == "DUPLICATE" else "contradiction"
        message += (
            f"\n- {prefix}: {conflict['source']} vs {conflict['against']} "
            f"on {conflict['affected']}"
        )
        if conflict["type"] == "CONTRADICTION":
            message += (
                f"\n  new: {conflict['right']}"
                f"\n  old: {conflict['existing_right']}"
            )

    if agents_result["blocked"]:
        message += f"\n- agents blocked: {agents_result['reason']}"
        if agents_result["diff_excerpt"]:
            message += "\n```diff\n" + agents_result["diff_excerpt"] + "\n```"

summary = {
    "new_sources": sorted(new_sources),
    "processed_count": len(new_sources),
    "technical_accepted_count": len(new_accepted_technical),
    "process_written_count": process_written,
    "parse_errors": parse_errors,
    "duplicate_count": duplicate_count,
    "contradiction_count": contradiction_count,
    "conflict_count": issue_count,
    "agents_updated": agents_result["updated"],
    "agents_blocked": agents_result["blocked"],
    "message": message,
}
print(json.dumps(summary, ensure_ascii=False))
PY
)"

message="$(
  SUMMARY_JSON="$summary_json" python3 - <<'PY'
import json
import os

summary = json.loads(os.environ["SUMMARY_JSON"])
print(summary.get("message", ""))
PY
)"

agents_updated="$(
  SUMMARY_JSON="$summary_json" python3 - <<'PY'
import json
import os

summary = json.loads(os.environ["SUMMARY_JSON"])
print("true" if summary.get("agents_updated") else "false")
PY
)"

if [ "$agents_updated" = "true" ]; then
  git -C "$PROJECT_DIR" add -- AGENTS.md
  git -C "$PROJECT_DIR" commit -m "chore(nexum): harvest — update AGENTS.md lessons interval" \
    --no-verify 2>&1 || true
fi

if [ -n "$message" ]; then
  send_notification "$message"
fi
