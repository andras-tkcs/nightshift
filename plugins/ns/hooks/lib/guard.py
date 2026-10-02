#!/usr/bin/env python3
"""Nightshift PreToolUse guard. A seatbelt, not the boundary (ADR 0006)."""
import json
import os
import re
import shlex
import subprocess
import sys

EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
FILE_TOOLS = EDIT_TOOLS | {"Read"}


class Block(Exception):
    pass


def tokens_dir():
    base = os.environ.get("NS_CONFIG_DIR") or os.path.expanduser("~/.config/ns")
    return os.path.realpath(os.path.join(base, "tokens"))


def under(path, parent):
    return path == parent or path.startswith(parent.rstrip("/") + "/")


def repo_root(path):
    d = path if os.path.isdir(path) else os.path.dirname(path)
    d = os.path.abspath(d)
    while True:
        if os.path.exists(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def load_profile(root):
    if not root:
        return {}
    try:
        import yaml
        with open(os.path.join(root, ".claude", "project-profile.yaml")) as fh:
            data = yaml.safe_load(fh)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def glob_re(glob):
    out, i = "", 0
    while i < len(glob):
        c = glob[i]
        if glob.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
            continue
        if glob.startswith("**", i):
            out += ".*"
            i += 2
            continue
        if c == "*":
            out += "[^/]*"
        elif c == "?":
            out += "[^/]"
        else:
            out += re.escape(c)
        i += 1
    return re.compile("^" + out + "$")


def check_file(tool, inp, cwd):
    path = inp.get("file_path") or inp.get("notebook_path")
    if not path:
        return
    path = os.path.expanduser(path)
    if not os.path.isabs(path):
        path = os.path.join(cwd, path)
    real = os.path.realpath(path)
    if under(real, tokens_dir()):
        raise Block("token files are off limits")
    if tool not in EDIT_TOOLS:
        return
    root = repo_root(real)
    if not root:
        return
    globs = load_profile(root).get("protected_paths") or []
    rel = os.path.relpath(real, os.path.realpath(root))
    for g in globs:
        if isinstance(g, str) and glob_re(g).match(rel):
            raise Block(f"{rel} is protected (protected_paths in .claude/project-profile.yaml)")


def base_branch(directory):
    root = repo_root(directory)
    git = load_profile(root).get("git")
    if isinstance(git, dict) and git.get("base_branch"):
        return str(git["base_branch"])
    return "main"


def current_branch(directory):
    try:
        r = subprocess.run(["git", "-C", directory, "rev-parse", "--abbrev-ref", "HEAD"],
                           capture_output=True, text=True, timeout=10)
        return r.stdout.strip()
    except Exception:
        return ""


ENV_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
PUSH_VALUE_OPTS = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}


def strip_env(words):
    i = 0
    while i < len(words) and ENV_RE.match(words[i]):
        i += 1
    return words[i:]


def parse_push(words):
    """Return (directory or None, push args) when words are a git push."""
    words = strip_env(words)
    if not words or words[0] != "git":
        return None
    directory, i = None, 1
    while i < len(words):
        w = words[i]
        if w == "-C" and i + 1 < len(words):
            directory = words[i + 1]
            i += 2
        elif w == "-c" and i + 1 < len(words):
            i += 2
        elif w == "--no-pager":
            i += 1
        else:
            break
    if i < len(words) and words[i] == "push":
        return directory, words[i + 1:]
    return None


def check_push(directory, args, cwd):
    wd = cwd
    if directory:
        wd = directory if os.path.isabs(directory) else os.path.join(cwd, directory)
    positional, delete, tags = [], False, False
    skip = False
    for w in args:
        if skip:
            skip = False
            continue
        if w in PUSH_VALUE_OPTS:
            skip = True
            continue
        if w == "-f" or w.startswith("--force") or w.startswith("--mirror"):
            raise Block("force pushes are blocked")
        if w == "--tags":
            tags = True
        elif w in ("--delete", "-d"):
            delete = True
        elif w.startswith("-") and w != "-":
            continue
        else:
            positional.append(w)
    refspecs = positional[1:]
    if any(r.startswith("+") for r in refspecs):
        raise Block("force pushes are blocked")
    if tags or any("refs/tags/" in r for r in refspecs):
        raise Block("pushing tags is blocked")
    base = base_branch(wd)
    msg = f"pushing to {base} is blocked; open a pull request"
    for r in refspecs:
        dest = r.split(":", 1)[1] if ":" in r else r
        if dest in (base, f"refs/heads/{base}"):
            raise Block(msg)
    if not delete and all(r == "HEAD" for r in refspecs):
        if current_branch(wd) == base:
            raise Block(msg)


def check_bash(cmd, cwd):
    if ".config/ns/tokens" in cmd or tokens_dir() in cmd:
        raise Block("token files are off limits")
    for seg in re.split(r";|&&|\|\||\||\n", cmd):
        try:
            words = shlex.split(seg)
        except ValueError:
            continue
        w = strip_env(words)
        if w[:3] == ["gh", "pr", "merge"]:
            raise Block("merging pull requests is the owner's job")
        if w[:3] == ["gh", "release", "create"]:
            raise Block("releases are cut by the owner")
        parsed = parse_push(words)
        if parsed:
            check_push(parsed[0], parsed[1], cwd)


def main():
    try:
        data = json.load(sys.stdin)
        tool = data.get("tool_name", "")
        inp = data.get("tool_input") or {}
        cwd = data.get("cwd") or os.getcwd()
        if tool in FILE_TOOLS:
            check_file(tool, inp, cwd)
        elif tool == "Bash":
            check_bash(inp.get("command") or "", cwd)
    except Block as b:
        print(f"ns guard: {b}", file=sys.stderr)
        return 2
    except Exception as e:  # fail open
        print(f"ns guard: not checked: {e}", file=sys.stderr)
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
