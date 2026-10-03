#!/usr/bin/env python3
"""Project profile tooling: check, show, defaults."""
import copy
import json
import os
import sys

import jsonschema
import yaml

NS_HOME = os.environ.get("NS_HOME") or os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCHEMA = os.path.join(NS_HOME, "schema", "profile.schema.json")
USAGE = "usage: profile.py check <file> [--repo <dir>] | show <file> | defaults"


def json_path(parts):
    out = "$"
    for p in parts:
        out += f"[{p}]" if isinstance(p, int) else f".{p}"
    return out


def load_schema():
    with open(SCHEMA, encoding="utf-8") as fh:
        return json.load(fh)


def load_profile(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if not text.strip():
        raise ValueError("empty file")
    return yaml.safe_load(text)


def apply_defaults(schema, value):
    """Fill defaults from the schema into value, recursively."""
    if not isinstance(value, dict):
        return value
    for key, sub in schema.get("properties", {}).items():
        if key not in value and "default" in sub:
            value[key] = copy.deepcopy(sub["default"])
        if key in value:
            value[key] = apply_defaults(sub, value[key])
    return value


def resolve(doc, schema):
    doc = apply_defaults(schema, copy.deepcopy(doc))
    budgets = schema["properties"]["budgets"]["default"]
    for tier, vals in budgets.items():
        merged = copy.deepcopy(vals)
        merged.update(doc["budgets"].get(tier, {}))
        doc["budgets"][tier] = merged
    stacks = []
    for s in doc.get("stacks", []):
        if isinstance(s, str):
            s = {"name": s, "paths": ["."]}
        stacks.append(s)
    doc["stacks"] = stacks
    return doc


def stack_commands(name):
    path = os.path.join(NS_HOME, "plugins", f"ns-{name}", "stack.yaml")
    try:
        data = load_profile(path)
    except (OSError, ValueError, yaml.YAMLError):
        return {}
    return (data or {}).get("commands", {}) or {}


def checks_for(doc):
    checks = []
    for s in doc["stacks"]:
        sc = stack_commands(s["name"])
        for name in ("lint", "test"):
            cmd = doc["commands"].get(name) or sc.get(name)
            if cmd:
                checks.append({"stack": s["name"], "name": name, "cmd": cmd})
    return checks


def agents_dir():
    return os.environ.get("NS_AGENTS_DIR") or os.path.join(
        NS_HOME, "plugins", "ns", "agents")


def default_repo(path):
    d = os.path.dirname(os.path.abspath(path))
    if os.path.basename(d) == ".claude":
        return os.path.dirname(d)
    return d


def cmd_check(path, repo):
    problems = []
    try:
        doc = load_profile(path)
    except (OSError, ValueError, yaml.YAMLError) as e:
        print(f"{path}: not valid YAML: {' '.join(str(e).split())}")
        return 1
    validator = jsonschema.Draft202012Validator(load_schema())
    errors = sorted(validator.iter_errors(doc),
                    key=lambda e: (json_path(e.absolute_path), e.message))
    for e in errors:
        problems.append(f"{path}: {json_path(e.absolute_path)}: {e.message}")
    if not problems:
        repo = repo or default_repo(path)

        def exists(rel):
            return os.path.exists(os.path.join(repo, rel))

        for key, val in doc.get("docs", {}).items():
            rel = val.split("#", 1)[0]
            if not exists(rel):
                problems.append(f"docs.{key}: file not found: {rel}")
        for name in doc.get("domain_skills", []):
            rel = f".claude/skills/{name}/SKILL.md"
            if not exists(rel):
                problems.append(f"domain_skills: skill not found: {rel}")

        def wf(where, files):
            for f in files:
                rel = f".github/workflows/{f}"
                if not exists(rel):
                    problems.append(f"{where}: workflow not found: {rel}")

        wf("ci.workflows", doc.get("ci", {}).get("workflows", {}))
        for p, v in doc.get("platforms", {}).items():
            wf(f"platforms.{p}.workflows", v.get("workflows", []))
        for s in doc["stacks"]:
            name = s if isinstance(s, str) else s["name"]
            if not os.path.isfile(os.path.join(
                    NS_HOME, "plugins", f"ns-{name}", "stack.yaml")):
                problems.append(f"stacks: unknown stack: {name}")

        def agent(where, name):
            if not os.path.isfile(os.path.join(agents_dir(), f"{name}.md")):
                problems.append(f"{where}: agent not available: {name}")

        for name in doc.get("specialists", []):
            agent("specialists", name)
        for zone, v in doc.get("risk_zones", {}).items():
            for name in v.get("require", []):
                agent(f"risk_zones.{zone}.require", name)
    if problems:
        print("\n".join(problems))
        return 1
    print(f"ok: {path}")
    return 0


def cmd_show(path):
    try:
        doc = load_profile(path)
    except (OSError, ValueError, yaml.YAMLError) as e:
        print(f"profile.py: {path}: {' '.join(str(e).split())}", file=sys.stderr)
        return 1
    if not isinstance(doc, dict):
        print(f"profile.py: {path}: not a mapping", file=sys.stderr)
        return 1
    out = resolve(doc, load_schema())
    out["checks"] = checks_for(out)
    json.dump(out, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def cmd_defaults():
    out = resolve({"git": {}, "commands": {}, "stacks": []}, load_schema())
    json.dump(out, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def main(argv):
    a = argv[1:]
    if a and a[0] in ("--help", "-h"):
        print(USAGE)
        return 0
    if len(a) == 2 and a[0] == "check":
        return cmd_check(a[1], None)
    if len(a) == 4 and a[0] == "check" and a[2] == "--repo":
        return cmd_check(a[1], a[3])
    if len(a) == 2 and a[0] == "show":
        return cmd_show(a[1])
    if len(a) == 1 and a[0] == "defaults":
        return cmd_defaults()
    print(f"profile.py: {USAGE}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
