#!/usr/bin/env python3
"""manifest.py: read the Implementation manifest of a plan document.

phases <plan.md>        JSON array of the phases
phase <plan.md> <id>    JSON object of one phase; exit 1 if absent
"""
import json
import re
import sys

import yaml

USAGE = "usage: manifest.py phases <plan.md> | phase <plan.md> <id>"
HEADING = re.compile(r"^#{1,6}\s+.*Implementation manifest\s*$")


def err(msg):
    print(f"manifest.py: {msg}", file=sys.stderr)


def load_manifest(path):
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    start = None
    for i, line in enumerate(lines):
        if HEADING.match(line):
            start = i + 1
            break
    if start is None:
        raise ValueError("no Implementation manifest heading")
    block = None
    for line in lines[start:]:
        if block is None:
            if re.match(r"^\s*```yaml\s*$", line):
                block = []
            elif re.match(r"^#{1,6}\s", line):
                break
        elif re.match(r"^\s*```\s*$", line):
            break
        else:
            block.append(line)
    if block is None:
        raise ValueError("no yaml block under the Implementation manifest heading")
    doc = yaml.safe_load("\n".join(block))
    if not isinstance(doc, dict) or not isinstance(doc.get("phases"), list):
        raise ValueError("the manifest has no phases list")
    return doc["phases"]


def main(argv):
    if len(argv) >= 2 and argv[1] in ("-h", "--help"):
        print(USAGE)
        return 0
    if len(argv) == 3 and argv[1] == "phases":
        want = None
    elif len(argv) == 4 and argv[1] == "phase":
        want = argv[3]
    else:
        err(USAGE)
        return 2
    try:
        phases = load_manifest(argv[2])
    except (OSError, ValueError, yaml.YAMLError) as e:
        err(f"{argv[2]}: {' '.join(str(e).split())}")
        return 1
    if want is None:
        print(json.dumps(phases, ensure_ascii=False))
        return 0
    for p in phases:
        if isinstance(p, dict) and p.get("id") == want:
            print(json.dumps(p, ensure_ascii=False))
            return 0
    err(f"phase not found: {want}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
