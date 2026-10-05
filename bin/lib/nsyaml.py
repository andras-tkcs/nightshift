#!/usr/bin/env python3
"""YAML helper for Nightshift: to-json, from-json, validate."""
import json
import os
import sys
import tempfile

import yaml

USAGE = "usage: nsyaml.py to-json <file> | from-json <file> | validate <file> <schema.json>"


def err(msg):
    print(f"nsyaml: {msg}", file=sys.stderr)


def load_doc(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if not text.strip():
        raise ValueError("empty file")
    return yaml.safe_load(text)


def cmd_to_json(path):
    try:
        doc = load_doc(path)
    except (OSError, ValueError, yaml.YAMLError) as e:
        err(f"{path}: {' '.join(str(e).split())}")
        return 1
    json.dump(doc, sys.stdout, ensure_ascii=False, default=str)
    sys.stdout.write("\n")
    return 0


def cmd_from_json(path):
    try:
        doc = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        err(f"invalid JSON on stdin: {e}")
        return 1
    directory = os.path.dirname(os.path.abspath(path))
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=directory, prefix=".nsyaml.")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            yaml.safe_dump(doc, fh, sort_keys=False, allow_unicode=True,
                           default_flow_style=False)
        os.replace(tmp, path)
        tmp = None
    except OSError as e:
        err(f"{path}: {e}")
        return 1
    finally:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)
    return 0


def json_path(parts):
    out = "$"
    for p in parts:
        out += f"[{p}]" if isinstance(p, int) else f".{p}"
    return out


def cmd_validate(path, schema_path):
    try:
        doc = load_doc(path)
        with open(schema_path, encoding="utf-8") as fh:
            schema = json.load(fh)
    except (OSError, ValueError, yaml.YAMLError) as e:
        err(f"{path}: {' '.join(str(e).split())}")
        return 1
    import jsonschema  # lazy: ~100 ms, only needed when validating
    validator = jsonschema.Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(doc),
                    key=lambda e: (json_path(e.absolute_path), e.message))
    for e in errors:
        print(f"{path}: {json_path(e.absolute_path)}: {e.message}")
    return 1 if errors else 0


def main(argv):
    if len(argv) >= 2 and argv[1] in ("--help", "-h"):
        print(USAGE)
        return 0
    if len(argv) == 3 and argv[1] == "to-json":
        return cmd_to_json(argv[2])
    if len(argv) == 3 and argv[1] == "from-json":
        return cmd_from_json(argv[2])
    if len(argv) == 4 and argv[1] == "validate":
        return cmd_validate(argv[2], argv[3])
    print(f"nsyaml: {USAGE}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
