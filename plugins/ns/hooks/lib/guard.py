#!/usr/bin/env python3
"""Nightshift PreToolUse guard. A seatbelt, not the boundary (ADR 0006)."""
import json
import os
import re
import shlex
import subprocess
import sys

EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
SEARCH_TOOLS = {"Grep", "Glob", "LS"}
FILE_TOOLS = EDIT_TOOLS | {"Read"}
PROFILE_RE = re.compile(r"(?:^|/)\.claude/project-profile\.yaml$")


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


def check_search(inp, cwd):
    """Grep/Glob/LS: refuse a path that equals or contains the token directory."""
    toks = tokens_dir()
    path = inp.get("path")
    if path:
        path = os.path.expanduser(path)
        if not os.path.isabs(path):
            path = os.path.join(cwd, path)
        real = os.path.realpath(path)
        if under(real, toks) or under(toks, real):
            raise Block("token files are off limits")
    pattern = inp.get("pattern")
    if isinstance(pattern, str) and pattern:
        if ".config/ns/tok" in pattern or toks in pattern:
            raise Block("token files are off limits")
        pat = os.path.expanduser(pattern)
        if os.path.isabs(pat):
            prefix = re.split(r"[*?\[{]", pat, maxsplit=1)[0]
            real = os.path.realpath(prefix) if prefix else "/"
            if under(real, toks) or (("**" in pat or "*" in pat) and under(toks, real)
                                     and prefix.endswith("/")):
                raise Block("token files are off limits")


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
    if PROFILE_RE.search(real):
        raise Block(".claude/project-profile.yaml is protected (an agent may not edit its own guard)")
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
PREFIX_WORDS = {"command", "exec", "nohup", "time", "env", "nice", "builtin"}
GIT_VALUE_OPTS = {"--git-dir", "--work-tree", "--namespace", "--exec-path"}
GH_VALUE_OPTS = {"-R", "--repo", "--hostname"}
TAG_LIKE = re.compile(r"^v\d")


def strip_env(words):
    """Drop leading NAME=value words and prefix words (env, command, ...)."""
    i = 0
    while i < len(words):
        w = words[i]
        if ENV_RE.match(w):
            i += 1
        elif os.path.basename(w) in PREFIX_WORDS:
            i += 1
            while i < len(words) and (words[i].startswith("-") or ENV_RE.match(words[i])):
                i += 1
        else:
            break
    return words[i:]


def argv0(words):
    return os.path.basename(words[0]) if words else ""


def parse_push(words):
    """Return (directory or None, push args) when words are a git push."""
    words = strip_env(words)
    if argv0(words) != "git":
        return None
    directory, i = None, 1
    while i < len(words):
        w = words[i]
        if w == "-C" and i + 1 < len(words):
            directory = words[i + 1]
            i += 2
        elif (w == "-c" or w in GIT_VALUE_OPTS) and i + 1 < len(words):
            i += 2
        elif w.startswith("-"):
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
        if w.startswith("--force") or w.startswith("--mirror"):
            raise Block("force pushes are blocked")
        if re.match(r"^-[A-Za-z]+$", w) and "f" in w:
            raise Block("force pushes are blocked")
        if w in ("--all", "--branches"):
            raise Block("pushing all branches is blocked; name the branch")
        if w in ("--tags", "--follow-tags"):
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
    if tags or any("refs/tags/" in r or TAG_LIKE.match(r.lstrip("+").split(":")[0])
                   for r in refspecs):
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


def gh_args(words):
    """Return the words after `gh` with leading -R/--repo options removed."""
    words = strip_env(words)
    if argv0(words) != "gh":
        return None
    out, i = [], 1
    while i < len(words):
        w = words[i]
        if w in GH_VALUE_OPTS and i + 1 < len(words):
            i += 2
        elif w.startswith("--repo=") or w.startswith("--hostname="):
            i += 1
        else:
            out.append(w)
            i += 1
    return out


def check_gh(args):
    if args[:2] == ["pr", "merge"]:
        raise Block("merging pull requests is the owner's job")
    if args[:2] == ["release", "create"]:
        raise Block("releases are cut by the owner")
    if args[:1] == ["api"]:
        method, write, merge = "", False, False
        rest = args[1:]
        for j, w in enumerate(rest):
            if w in ("-X", "--method") and j + 1 < len(rest):
                method = rest[j + 1]
            elif w.startswith("--method="):
                method = w.split("=", 1)[1]
            elif w.startswith("-X") and len(w) > 2:
                method = w[2:]
            elif w in ("-f", "-F", "--field", "--raw-field", "--input"):
                write = True
            elif not w.startswith("-") and w.split("?")[0].rstrip("/").endswith("/merge"):
                merge = True
        if merge and (write or method.upper() in ("PUT", "POST", "PATCH", "DELETE")):
            raise Block("merging pull requests is the owner's job")


PROFILE_WRITE_RE = re.compile(
    r"(?:>>?\s*|\b(?:tee|cp|mv|install)\b[^;&|\n]*?)[\"']?[^\s;&|\"'<>]*"
    r"\.claude/project-profile\.yaml")


def check_bash(cmd, cwd):
    toks = tokens_dir()
    base = os.environ.get("NS_CONFIG_DIR") or ""
    if (".config/ns/tok" in cmd or toks in cmd
            or (base and (base.rstrip("/") + "/tok") in cmd)):
        raise Block("token files are off limits")
    if PROFILE_WRITE_RE.search(cmd):
        raise Block(".claude/project-profile.yaml is protected (an agent may not edit its own guard)")
    for seg in re.split(r";|&&|\|\||\||\n", cmd):
        try:
            words = shlex.split(seg)
        except ValueError:
            continue
        sw = strip_env(words)
        if argv0(sw) == "ns" and sw[1:2] == ["kill"]:
            raise Block("ns kill is the owner's command")
        if argv0(sw) == "ns" and sw[1:2] == ["stack"] and sw[2:3] in (["merge"], ["drop"]):
            raise Block("ns stack merge and ns stack drop are the owner's commands")
        if argv0(sw) == "ns" and sw[1:2] == ["tag"]:
            raise Block("ns tag is the owner's command")
        gh = gh_args(words)
        if gh is not None:
            check_gh(gh)
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
        elif tool in SEARCH_TOOLS:
            check_search(inp, cwd)
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
