#!/bin/bash
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "Usage: yaml-to-json.sh <yaml_file>" >&2
  exit 1
}

python3 - "$1" <<'PY'
import json
import re
import sys

yaml_file = sys.argv[1]


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


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


try:
    with open(yaml_file, "r", encoding="utf-8") as handle:
        raw = handle.read()
except OSError as exc:
    fail(f"Failed to read YAML file {yaml_file}: {exc}")

try:
    import yaml  # type: ignore
except Exception:
    yaml = None

if yaml is not None:
    try:
        data = yaml.safe_load(raw)
    except Exception as exc:
        fail(f"Failed to parse YAML {yaml_file}: {exc}")
else:
    tokens = tokenize(raw)
    if not tokens:
        fail(f"YAML file is empty: {yaml_file}")
    data, index = parse_block(tokens, 0, tokens[0][0])
    if index != len(tokens):
        fail(f"Unsupported YAML structure in {yaml_file}")

if not isinstance(data, dict):
    fail(f"YAML root must be a mapping: {yaml_file}")

json.dump(data, sys.stdout, ensure_ascii=False)
PY
