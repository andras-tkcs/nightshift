#!/usr/bin/env python3
"""Nightshift PreToolUse guard. A seatbelt, not the boundary (ADR 0006).

Shell commands are parsed with a small bash-like parser (quotes, escapes, $'...', variables,
$(...), backticks, <(...), here-documents, pipes, chains, subshells, groups) so that an
owner-only ns command is found in every form an agent can write it: by path, behind wrapper
words, inside bash -c, eval, a sourced or executed script, a substitution, or through a
variable. What cannot be resolved is blocked when it may hide an owner-only command.
"""
import json
import os
import re
import shutil
import subprocess
import sys

EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
SEARCH_TOOLS = {"Grep", "Glob", "LS"}
FILE_TOOLS = EDIT_TOOLS | {"Read"}
PROFILE_RE = re.compile(r"(?:^|/)\.claude/project-profile\.yaml$")
PROFILE_PATH = ".claude/project-profile.yaml"
# git hooks and config run commands the guard never sees
GIT_DIR_RE = re.compile(r"(?:^|/)\.git/(?:.*/)?(?:hooks/|config$)")
GIT_DIR_MSG = "git hooks and git config are off limits (they run commands the guard cannot see)"
GIT_HOOK_KEYS_RE = re.compile(
    r"^(?:core\.(?:hookspath|fsmonitor|sshcommand|pager|editor|askpass)|diff\.external|"
    r"diff\..*\.(?:command|textconv)|merge\..*\.driver|filter\..*\.(?:clean|smudge|process)|"
    r"sequence\.editor|.*\.(?:command|cmd|program|helper|tool)|pager\..*)$", re.I)
GIT_SAFE_VALUES = {"", "cat", "true", ":", "less", "less -R", "more", "vi", "vim", "nano"}
WORKTREE_SOURCE = "the worktree's .claude/project-profile.yaml; no origin/<base> profile"


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


# ---------------------------------------------------------------------------
# the project profile: origin/<base> first, the worktree only when that ref has none


def parse_profile(text):
    try:
        import yaml
        data = yaml.safe_load(text)
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def load_profile(root):
    """The worktree's own profile (agent-editable: only a fallback)."""
    if not root:
        return {}
    try:
        with open(os.path.join(root, ".claude", "project-profile.yaml")) as fh:
            return parse_profile(fh.read())
    except Exception:
        return {}


# the guard's own git calls: a repository's config must not run commands inside the guard
GIT = ["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]


def git_env():
    return dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_OPTIONAL_LOCKS="0")


def git_out(root, *args):
    try:
        r = subprocess.run([*GIT, "-C", root, *args], capture_output=True, text=True,
                           timeout=10, env=git_env())
    except Exception:
        return None
    return r.stdout if r.returncode == 0 else None


def profile_base(data, default):
    git = data.get("git")
    if isinstance(git, dict) and git.get("base_branch"):
        return str(git["base_branch"])
    return default


class Profile:
    def __init__(self, data, source, base, guarded):
        self.data, self.source, self.base, self.guarded = data, source, base, guarded


_PROFILES = {}


def project_profile(root):
    """The profile of root, read once per hook call (see read_project_profile)."""
    if root not in _PROFILES:
        _PROFILES[root] = read_project_profile(root)
    return _PROFILES[root]


def read_project_profile(root):
    """Profile, where it came from, the base branch and the branches pushes may not reach.

    The profile is read from origin/<default branch> (origin/HEAD, else main or master) and,
    when that names another git.base_branch, from origin/<base>. Only when none of these refs
    has a profile does the worktree's own file count, and the source says so."""
    if not root:
        return Profile({}, WORKTREE_SOURCE, "main", {"main"})
    head = (git_out(root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD") or "").strip()
    default = head.split("/", 1)[1] if "/" in head else None
    for b in [default] if default else ["main", "master"]:
        text = git_out(root, "show", f"refs/remotes/origin/{b}:{PROFILE_PATH}")
        if text is None:
            continue
        data, src = parse_profile(text), f"origin/{b}"
        base = profile_base(data, b)
        if base != b:
            text = git_out(root, "show", f"refs/remotes/origin/{base}:{PROFILE_PATH}")
            if text is not None:
                data, src = parse_profile(text), f"origin/{base}"
        return Profile(data, f"{src}:{PROFILE_PATH}", base, {base, b})
    data = load_profile(root)
    base = profile_base(data, "main")
    return Profile(data, WORKTREE_SOURCE, base, {base} | ({default} if default else set()))


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


# ---------------------------------------------------------------------------
# file and search tools


def check_glob_pattern(pat, toks):
    prefix = re.split(r"[*?\[{]", pat, maxsplit=1)[0]
    real = os.path.realpath(prefix) if prefix else "/"
    if under(real, toks) or (("**" in pat or "*" in pat) and under(toks, real)
                             and prefix.endswith("/")):
        raise Block("token files are off limits")


def check_search(tool, inp, cwd):
    """Grep/Glob/LS: refuse a search root or pattern that equals or contains the token directory.
    A call without a path searches the working directory, so that is the root then."""
    toks = tokens_dir()
    path = inp.get("path")
    pattern = inp.get("pattern")
    if path or tool != "Glob":
        root = os.path.expanduser(path) if path else cwd
        if not os.path.isabs(root):
            root = os.path.join(cwd, root)
        real = os.path.realpath(root)
        if under(real, toks) or under(toks, real):
            raise Block("token files are off limits")
    if isinstance(pattern, str) and pattern:
        if ".config/ns/tok" in pattern or toks in pattern:
            raise Block("token files are off limits")
        pat = os.path.expanduser(pattern)
        if os.path.isabs(pat):
            check_glob_pattern(pat, toks)
        elif tool == "Glob" and not path:
            check_glob_pattern(os.path.join(cwd, pat), toks)


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
    if GIT_DIR_RE.search(real):
        raise Block(GIT_DIR_MSG)
    root = repo_root(real)
    if not root:
        return
    prof = project_profile(root)
    globs = prof.data.get("protected_paths") or []
    rel = os.path.relpath(real, os.path.realpath(root))
    for g in globs if isinstance(globs, list) else []:
        if isinstance(g, str) and glob_re(g).match(rel):
            raise Block(f"{rel} is protected (protected_paths in {prof.source})")


# ---------------------------------------------------------------------------
# git push and gh


def current_branch(directory):
    try:
        r = subprocess.run([*GIT, "-C", directory, "rev-parse", "--abbrev-ref", "HEAD"],
                           capture_output=True, text=True, timeout=10, env=git_env())
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


def git_sub(words):
    """(index of the git subcommand, -C directory) after the global options."""
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
    return i, directory


def parse_push(words):
    """Return (directory or None, push args) when words are a git push."""
    words = strip_env(words)
    if argv0(words) != "git":
        return None
    i, directory = git_sub(words)
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
    guarded = project_profile(repo_root(wd)).guarded
    for r in refspecs:
        dest = r.split(":", 1)[1] if ":" in r else r
        for b in sorted(guarded):
            if dest in (b, f"refs/heads/{b}"):
                raise Block(f"pushing to {b} is blocked; open a pull request")
    if not delete and all(r == "HEAD" for r in refspecs):
        cb = current_branch(wd)
        if cb in guarded:
            raise Block(f"pushing to {cb} is blocked; open a pull request")


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


GIT_WRITE_RE = re.compile(
    r"(?:>>?\s*|\b(?:tee|cp|mv|install|ln)\b[^;&|\n]*?)[\"']?[^\s;&|\"'<>]*"
    r"\.git/(?:[^\s;&|\"'<>]*/)?(?:hooks\b|config\b)")
PROFILE_WRITE_RE = re.compile(
    r"(?:>>?\s*|\b(?:tee|cp|mv|install)\b[^;&|\n]*?)[\"']?[^\s;&|\"'<>]*"
    r"\.claude/project-profile\.yaml")


# ---------------------------------------------------------------------------
# owner-only commands
#
# ns kill, tag, desk, approve, project, rm (purge), gc, note, stack merge, stack drop and
# new --allow-outside are the owner's: they stop runs, release gates, send a run owner instructions, push tags, merge or
# close pull requests, delete branches, open pull requests with the owner's token, or read
# any file into a run. ns-launch starts a run session with the project owner's token and
# ns-gh apply changes repository settings. The bin/lib/ns-*.sh files and their functions
# are only run through ns.

OWNER_SUBS = {"kill", "tag", "desk", "approve", "project", "rm", "purge", "gc", "note"}
OWNER_WORDS = OWNER_SUBS | {"merge", "drop"}
STACK_MSG = "ns stack merge and ns stack drop are the owner's commands"
NEW_MSG = ("ns new --allow-outside is the owner's command "
           "(it reads any file into the run's request, which is pushed to GitHub)")
NS_DYN_MSG = ("cannot tell which ns command this runs (the subcommand is built at run time); "
              "write it literally, owner-only ns commands are blocked")
NEW_DYN_MSG = ("cannot tell whether ns new gets --allow-outside (an argument is built at run "
               "time); write the arguments literally")
CMD_DYN_MSG = ("cannot tell which command this runs, and it may be an owner-only ns command; "
               "write the command literally")
LAUNCH_MSG = "ns-launch is the owner's helper (it starts a run with the owner's token)"
GH_APPLY_MSG = "ns-gh apply is the owner's command"
LIB_RE = re.compile(r"^ns-[a-z][a-z0-9-]*\.sh$")
FUNC_RE = re.compile(r"^(?:ns_[a-z0-9_]+_main|ns_kill_(?:teardown|group)|ns_approve_onboard\w*|"
                     r"ns_project_add|ns_stack_(?:merge|drop)\w*|ns_desk_cleanup|ns_token_export|"
                     r"gc_run\w*|rm_inner)$")
DISPATCH_RE = re.compile(r"bin/lib/ns-\$cmd\.sh")


def owner_msg(sub):
    return f"ns {sub} is the owner's command"


def lib_msg(name):
    return f"{name} is the owner's to run (ns library code runs only through ns)"


# ---------------------------------------------------------------------------
# a small bash parser


class ParseError(Exception):
    pass


NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
ARRAY_REF_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\[[^\]]*\]")
ASSIGN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)(?:\[[^\]]*\])?\+?=")
BRACE_RE = re.compile(r"\{([^{}]*)\}")
BRACE_WORD_RE = re.compile(r"\{[^{}\s]*(?:,|\.\.)[^{}\s]*\}")
REDIR_OPS = ["<<<", "<<-", "<<", "&>>", "&>", ">>", ">|", ">&", "<&", "<>", ">", "<"]
WORD_END = set(" \t\n;&|()<>")
DYN = "\x00"
MAXV = 32
MAX_DEPTH = 8


class Word:
    __slots__ = ("parts", "brace", "glob")

    def __init__(self):
        self.parts = []  # (kind, value, quoted); kind: lit | var | dyn | sub
        self.brace = False
        self.glob = False


class Cmd:
    def __init__(self):
        self.words = []
        self.redirs = []    # (op, Word)
        self.heredocs = []  # (body, expanding, [command lists found in the body])
        self.pipe_in = False
        self.pipe_prev = []
        self.pattern = False  # a case pattern: only its substitutions run


SIMPLE_ESC = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n", "r": "\r",
              "t": "\t", "v": "\v", "\\": "\\", "'": "'", '"': '"', "?": "?"}


def ansi_c(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c != "\\" or i + 1 >= len(s):
            out.append(c)
            i += 1
            continue
        d = s[i + 1]
        if d in SIMPLE_ESC:
            out.append(SIMPLE_ESC[d])
            i += 2
        elif d in "01234567":
            m = re.match(r"[0-7]{1,3}", s[i + 1:])
            out.append(chr(int(m.group(0), 8) & 0xFF))
            i += 1 + len(m.group(0))
        elif d in "xuU":
            n = {"x": 2, "u": 4, "U": 8}[d]
            m = re.match(r"[0-9a-fA-F]{1,%d}" % n, s[i + 2:])
            if m:
                out.append(chr(int(m.group(0), 16)))
                i += 2 + len(m.group(0))
            else:
                out.append("\\" + d)
                i += 2
        elif d == "c" and i + 2 < len(s):
            out.append(chr(ord(s[i + 2]) & 31))
            i += 3
        else:
            out.append("\\" + d)
            i += 2
    return "".join(out)


def word_lit(words):
    """The literal text of the first word, or None when it is not a plain literal."""
    if not words or any(k != "lit" for k, v, q in words[0].parts):
        return None
    return "".join(v for k, v, q in words[0].parts)


class Parser:
    def __init__(self, text):
        self.s, self.i, self.n = text, 0, len(text)
        self.pending = []  # here-documents whose body starts after the next newline

    def peek(self, k=0):
        j = self.i + k
        return self.s[j] if j < self.n else ""

    def parse_all(self):
        return self.parse_list(None)

    def parse_list(self, stop):
        cmds, pipeline, depth = [], [], 0
        in_case, expect_pattern = 0, False  # inside case ... esac; before a pattern's )
        cur = Cmd()

        def finish(sep):
            nonlocal cur, pipeline, in_case, expect_pattern
            if cur.words or cur.redirs:
                cmds.append(cur)
                pipeline.append(cur)
                if word_lit(cur.words[:1]) == "case" and not cur.pattern:
                    in_case, expect_pattern = in_case + 1, True
            nxt = Cmd()
            if sep == "|":
                nxt.pipe_in, nxt.pipe_prev = True, list(pipeline)
            elif sep != ")":
                pipeline = []
            cur = nxt

        def head_is_case():
            return word_lit(cur.words[:1]) == "case"

        while self.i < self.n:
            c = self.s[self.i]
            if c in " \t":
                self.i += 1
            elif c == "\\" and self.peek(1) == "\n":
                self.i += 2
            elif c == "#":
                while self.i < self.n and self.s[self.i] != "\n":
                    self.i += 1
            elif c == "\n":
                self.i += 1
                finish("\n")
                self.read_heredocs()
            elif c == ";":
                self.i += 2 if self.peek(1) in (";", "&") else 1
                case_end = self.s[self.i - 2:self.i] in (";;", ";&")
                finish(";")
                if case_end and in_case:
                    expect_pattern = True
            elif c == "&":
                if self.peek(1) == "&":
                    self.i += 2
                    finish("&&")
                elif self.peek(1) == ">":
                    self.read_redirect(cur)
                else:
                    self.i += 1
                    finish("&")
            elif c == "|":
                if self.peek(1) == "|":
                    self.i += 2
                    finish("||")
                elif (in_case and expect_pattern) or head_is_case():
                    self.i += 1  # a | between case patterns
                else:
                    self.i += 2 if self.peek(1) == "&" else 1
                    finish("|")
            elif c == "(":
                self.i += 1
                if in_case and expect_pattern and not cur.words:
                    continue  # the optional ( before a case pattern
                if cur.words:
                    finish("(")
                depth += 1
            elif c == ")":
                self.i += 1
                if depth == 0 and head_is_case():
                    # case WORD in PATTERN) on one line: the head ends at the first pattern
                    finish(";")
                    expect_pattern = False
                    continue
                if depth == 0 and in_case and expect_pattern:
                    cur.pattern = True
                    finish(";")
                    expect_pattern = False
                    continue
                if depth == 0:
                    if stop == ")":
                        finish(")")
                        return cmds
                    raise ParseError("unbalanced )")
                depth -= 1
                finish(")")
            elif c in "<>" and self.peek(1) == "(":
                self.i += 2
                w = Word()
                w.parts.append(("sub", self.parse_list(")"), False))
                cur.words.append(w)
            elif c in "<>":
                self.read_redirect(cur)
            elif c.isdigit() and self.fd_redirect():
                self.read_redirect(cur)
            else:
                w = self.read_word()
                if not cur.words and in_case and word_lit([w]) == "esac":
                    in_case, expect_pattern = in_case - 1, False
                cur.words.append(w)
        if stop == ")":
            raise ParseError("unterminated $( or (")
        if depth:
            raise ParseError("unbalanced (")
        finish("")
        self.read_heredocs()
        return cmds

    def fd_redirect(self):
        j = self.i
        while j < self.n and self.s[j].isdigit():
            j += 1
        if j < self.n and self.s[j] in "<>":
            self.i = j
            return True
        return False

    def read_redirect(self, cur):
        op = next(o for o in REDIR_OPS if self.s.startswith(o, self.i))
        self.i += len(op)
        while self.peek() in (" ", "\t"):
            self.i += 1
        w = self.read_word()
        if op in ("<<", "<<-"):
            delim = "".join(v for k, v, q in w.parts if k == "lit")
            quoted = any(q for k, v, q in w.parts)
            self.pending.append((cur, delim, op == "<<-", not quoted))
        else:
            cur.redirs.append((op, w))

    def read_heredocs(self):
        pending, self.pending = self.pending, []
        for cmd, delim, strip, expand in pending:
            lines = []
            while self.i < self.n:
                j = self.s.find("\n", self.i)
                line = self.s[self.i:j] if j >= 0 else self.s[self.i:]
                self.i = j + 1 if j >= 0 else self.n
                if (line.lstrip("\t") if strip else line) == delim:
                    break
                lines.append(line)
            body = "\n".join(lines)
            subs = []
            if expand:
                w = Word()
                Parser(body).read_dq_body(w)
                subs = [v for k, v, q in w.parts if k == "sub"]
            cmd.heredocs.append((body, expand, subs))

    def read_word(self):
        w, unquoted = Word(), []
        while self.i < self.n:
            c = self.s[self.i]
            if c in WORD_END:
                break
            if c == "\\":
                nx = self.peek(1)
                self.i += 2
                if nx and nx != "\n":
                    w.parts.append(("lit", nx, True))
            elif c == "'":
                j = self.s.find("'", self.i + 1)
                if j < 0:
                    raise ParseError("unterminated '")
                w.parts.append(("lit", self.s[self.i + 1:j], True))
                self.i = j + 1
            elif c == '"':
                self.i += 1
                self.read_dq(w)
            elif c == "`":
                w.parts.append(("sub", self.read_backtick(), False))
            elif c == "$":
                self.read_dollar(w, False)
            else:
                if c in "*?[":
                    w.glob = True
                unquoted.append(c)
                w.parts.append(("lit", c, False))
                self.i += 1
        if BRACE_WORD_RE.search("".join(unquoted)):
            w.brace = True
        return w

    def read_dq(self, w):
        while True:
            if self.i >= self.n:
                raise ParseError('unterminated "')
            c = self.s[self.i]
            if c == '"':
                self.i += 1
                return
            self.dq_char(w, c)

    def read_dq_body(self, w):
        """A here-document body: like a double-quoted string without the closing quote."""
        while self.i < self.n:
            self.dq_char(w, self.s[self.i])

    def dq_char(self, w, c):
        if c == "\\":
            nx = self.peek(1)
            if nx in ("$", "`", '"', "\\"):
                w.parts.append(("lit", nx, True))
                self.i += 2
            elif nx == "\n":
                self.i += 2
            else:
                w.parts.append(("lit", "\\", True))
                self.i += 1
        elif c == "`":
            w.parts.append(("sub", self.read_backtick(), True))
        elif c == "$":
            self.read_dollar(w, True)
        else:
            w.parts.append(("lit", c, True))
            self.i += 1

    def read_backtick(self):
        j, buf = self.i + 1, []
        while j < self.n:
            c = self.s[j]
            if c == "\\" and j + 1 < self.n and self.s[j + 1] in "`\\$":
                buf.append(self.s[j + 1])
                j += 2
                continue
            if c == "`":
                self.i = j + 1
                return Parser("".join(buf)).parse_all()
            buf.append(c)
            j += 1
        raise ParseError("unterminated `")

    def read_dollar(self, w, quoted):
        nx = self.peek(1)
        if nx == "'" and not quoted:
            j, buf = self.i + 2, []
            while j < self.n and self.s[j] != "'":
                if self.s[j] == "\\" and j + 1 < self.n:
                    buf.append(self.s[j:j + 2])
                    j += 2
                else:
                    buf.append(self.s[j])
                    j += 1
            if j >= self.n:
                raise ParseError("unterminated $'")
            w.parts.append(("lit", ansi_c("".join(buf)), True))
            self.i = j + 1
        elif nx == '"' and not quoted:
            self.i += 2
            self.read_dq(w)
        elif nx == "(" and self.peek(2) == "(":
            self.i += 3
            self.read_arith(w, quoted)
        elif nx == "(":
            self.i += 2
            w.parts.append(("sub", self.parse_list(")"), quoted))
        elif nx == "{":
            self.i += 2
            self.read_braced(w, quoted)
        else:
            m = NAME_RE.match(self.s, self.i + 1)
            if m:
                w.parts.append(("var", m.group(0), quoted))
                self.i = m.end()
            elif nx and nx in "@*#?$!-0123456789":
                w.parts.append(("dyn", "$" + nx, quoted))
                self.i += 2
            else:
                w.parts.append(("lit", "$", quoted))
                self.i += 1

    def read_braced(self, w, quoted):
        start, depth, tmp = self.i, 0, Word()
        while True:
            if self.i >= self.n:
                raise ParseError("unterminated ${")
            c = self.s[self.i]
            if c == "}" and depth == 0:
                break
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            if c == "\\":
                self.i += 2
            elif c == "'" and not quoted:
                j = self.s.find("'", self.i + 1)
                if j < 0:
                    raise ParseError("unterminated '")
                self.i = j + 1
            elif c == '"':
                self.i += 1
                self.read_dq(tmp)
            elif c == "`":
                tmp.parts.append(("sub", self.read_backtick(), quoted))
            elif c == "$":
                self.read_dollar(tmp, True)
            else:
                self.i += 1
        inner = self.s[start:self.i]
        self.i += 1
        arr = ARRAY_REF_RE.fullmatch(inner)
        if NAME_RE.fullmatch(inner):
            w.parts.append(("var", inner, quoted))
        elif arr:
            w.parts.append(("avar", arr.group(1), quoted))
        else:
            w.parts.append(("dyn", inner, quoted))
            w.parts.extend(("sub", v, quoted) for k, v, q in tmp.parts if k == "sub")

    def read_arith(self, w, quoted):
        depth, tmp = 0, Word()
        while True:
            if self.i >= self.n:
                raise ParseError("unterminated $((")
            c = self.s[self.i]
            if c == ")" and depth == 0 and self.peek(1) == ")":
                self.i += 2
                break
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            if c == "$":
                self.read_dollar(tmp, True)
            elif c == "`":
                tmp.parts.append(("sub", self.read_backtick(), True))
            else:
                self.i += 1
        w.parts.append(("dyn", "$((...))", quoted))
        w.parts.extend(("sub", v, quoted) for k, v, q in tmp.parts if k == "sub")


# ---------------------------------------------------------------------------
# expansion: every word becomes the strings it can stand for; DYN marks what is unknown


class Arg:
    __slots__ = ("text", "dyn", "glob")

    def __init__(self, text, glob=False):
        self.text, self.dyn, self.glob = text, DYN in text, glob


class Ctx:
    def __init__(self, cwd, full, strict=True, home=None):
        self.cwd, self.full, self.strict = cwd, full, strict
        # the run's repository: where the session works (the hook's cwd), never a later cd
        self.home = home if home is not None else (repo_root(cwd) or "")
        self.vars = {}
        self.ifs = False

    def child(self, strict):
        c = Ctx(self.cwd, self.full, strict, self.home)
        c.vars, c.ifs = self.vars, self.ifs
        return c


def part_values(part, ctx):
    kind, val, _ = part
    if kind == "lit":
        return [val]
    if kind == "var" and ctx.vars.get(val):
        return sorted(ctx.vars[val])
    if kind == "avar" and ctx.vars.get(val):
        return sorted(v[1:-1] if v.startswith("(") and v.endswith(")") else v
                      for v in ctx.vars[val])
    return [DYN]


def word_values(w, ctx):
    vals = [""]
    for p in w.parts:
        pv = part_values(p, ctx)
        vals = [a + b for a in vals for b in pv][:MAXV]
    return vals


def brace_expand(s, limit=16):
    out, todo = [], [s]
    while todo and len(out) < limit:
        x = todo.pop(0)
        for m in BRACE_RE.finditer(x):
            body = m.group(1)
            r = re.fullmatch(r"(-?\d+)\.\.(-?\d+)", body)
            c = re.fullmatch(r"([A-Za-z])\.\.([A-Za-z])", body)
            if "," in body:
                alts = body.split(",")
            elif r:
                a, b = int(r.group(1)), int(r.group(2))
                alts = [str(k) for k in (range(a, b + 1) if a <= b else range(a, b - 1, -1))][:limit]
            elif c:
                a, b = ord(c.group(1)), ord(c.group(2))
                alts = [chr(k) for k in (range(a, b + 1) if a <= b else range(a, b - 1, -1))][:limit]
            else:
                continue
            todo[:0] = [x[:m.start()] + a + x[m.end():] for a in alts]
            break
        else:
            out.append(x)
    return (out + todo)[:limit]


def split_fields(text, ctx):
    if ctx.ifs:
        return [p for p in re.split(r"[^A-Za-z0-9_./~\x00-]+", text) if p]
    return text.split()


def expand_word(w, ctx):
    """The alternatives for one word; each alternative is a list of Args (splitting, braces)."""
    alts = []
    split = any((k in ("var", "dyn", "sub") and not q) or k == "avar" for k, v, q in w.parts)
    for v in word_values(w, ctx):
        out = []
        for x in brace_expand(v) if w.brace else [v]:
            for piece in split_fields(x, ctx) if split else [x]:
                out.append(Arg(piece, w.glob))
        alts.append(out)
    return alts


def variants(words, ctx):
    combos = [[]]
    for w in words:
        alts = expand_word(w, ctx)
        combos = [c + a for c in combos for a in alts][:MAXV]
    return combos


def split_assign(w):
    pre = ""
    for k, v, q in w.parts:
        if k != "lit" or q:
            break
        pre += v
    m = ASSIGN_RE.match(pre)
    if not m:
        return None
    cut, consumed, val = m.end(), 0, Word()
    for p in w.parts:
        if consumed >= cut:
            val.parts.append(p)
        else:
            take = cut - consumed
            if len(p[1]) > take:
                val.parts.append(("lit", p[1][take:], False))
            consumed += min(len(p[1]), take)
    return m.group(1), val


CODE_VAR_RE = re.compile(r"(COMMAND|EDITOR|PAGER|SSH|SHELL|PROMPT|ASKPASS|EXEC|HOOK|DIFF|"
                         r"_CMD$|^ENV$)")
HOME_VARS = {"NS_HOME", "NS_RUN_HOME"}


def assign(ctx, name, values, depth):
    if name in HOME_VARS and ctx.strict:
        raise Block(f"{name} decides which Nightshift code runs; agents may not set it")
    ctx.vars.setdefault(name, set()).update(values)
    if name == "IFS":
        ctx.ifs = True
    if CODE_VAR_RE.search(name) or name == "BASH_ENV":
        for v in values:
            hit = raw_scan(v)
            if hit:
                raise Block(hit)
            if name in ("BASH_ENV", "ENV") and DYN not in v:
                scan_file(resolve(v, ctx), ctx, depth, True)


# ---------------------------------------------------------------------------
# raw scan: for text that is code but not shell (python -c, a script, a pipe into bash)

RAW_SPLIT_RE = re.compile(r"[\s;|&()<>,\[\]{}=!]+")


def decode_escapes(t):
    t = re.sub(r"\\x([0-9a-fA-F]{1,2})", lambda m: chr(int(m.group(1), 16)), t)
    t = re.sub(r"\\u([0-9a-fA-F]{4})", lambda m: chr(int(m.group(1), 16)), t)
    return re.sub(r"\\0?([0-7]{3})", lambda m: chr(int(m.group(1), 8) & 0xFF), t)


def raw_scan(text, libs=True):
    """The reason when text (any language) names an owner-only ns command, else None.
    libs=False skips the bin/lib/ns-*.sh file names: for file operands that are only read."""
    if not text:
        return None
    t = decode_escapes(text.replace(DYN, "$")).replace("\\\n", "")
    t = re.sub(r"['\"\\`]", "", t)
    for line in t.splitlines():
        toks = [x for x in RAW_SPLIT_RE.split(line) if x]
        for k, tok in enumerate(toks):
            base = tok.rstrip("/").rsplit("/", 1)[-1]
            nxt = toks[k + 1] if k + 1 < len(toks) else ""
            if (libs and LIB_RE.match(base)) or FUNC_RE.match(tok):
                return lib_msg(base)
            if base == "ns-launch":
                return LAUNCH_MSG
            if base == "ns-gh" and nxt == "apply":
                return GH_APPLY_MSG
            if base != "ns" or not nxt:
                continue
            if nxt in OWNER_SUBS:
                return owner_msg(nxt)
            if nxt == "stack" and k + 2 < len(toks) and toks[k + 2] in ("merge", "drop"):
                return STACK_MSG
            if nxt == "new" and any(x.startswith("--allow-outside") for x in toks[k + 2:]):
                return NEW_MSG
            if "$" in nxt:
                return NS_DYN_MSG
    return None


def read_text(path, limit=1 << 20):
    try:
        if not os.path.isfile(path) or os.path.getsize(path) > limit:
            return None
        with open(path, "rb") as fh:
            data = fh.read(limit)
    except Exception:
        return None
    if b"\0" in data[:4096]:
        return None
    return data.decode("utf-8", "replace")


def resolve(text, ctx):
    t = os.path.expanduser(text)
    return t if os.path.isabs(t) else os.path.join(ctx.cwd, t)


def locate(text, ctx):
    """The file a command word runs, when it can be found."""
    if DYN in text:
        return None
    if "/" in text or text.startswith("~"):
        p = resolve(text, ctx)
        return p if os.path.isfile(p) else None
    for value in sorted(ctx.vars.get("PATH", ())):
        dirs = [d for d in value.split(":") if d and DYN not in d]
        found = shutil.which(text, path=os.pathsep.join(resolve(d, ctx) for d in dirs))
        if found:
            return found
    return shutil.which(text)


def owner_kind(name, text, ctx):
    if name == "ns":
        return "ns"
    if name == "ns-launch":
        return "launch"
    if name == "ns-gh":
        return "gh"
    if LIB_RE.match(name):
        return "lib"
    if "/" not in text and FUNC_RE.match(name):
        return "func"
    path = locate(text, ctx)
    if path:
        real = os.path.realpath(path)
        rb = os.path.basename(real)
        if rb == "ns":
            return "ns"
        if rb == "ns-launch":
            return "launch"
        if LIB_RE.match(rb):
            return "lib"
        head = read_text(real)
        if head and DISPATCH_RE.search(head):
            return "ns"
    return None


def scan_file(path, ctx, depth, shell):
    """Check a script that will run: a raw scan, then (for shell) the parser. The same command
    line may write the script first, so the whole line is scanned too, and a script that does
    not exist yet is refused: write it first, then run it, so the guard can read it. The line
    may name bin/lib/ns-*.sh as a file to read, so the line scan skips those file names."""
    hit = raw_scan(ctx.full, libs=False)
    if hit:
        raise Block(hit)
    content = read_text(path)
    if content is None:
        if not os.path.exists(path):
            raise Block(f"{path} does not exist yet, so the guard cannot read it; "
                        "write the script first, then run it in a separate command")
        return
    hit = raw_scan(content)
    if hit:
        raise Block(f"{hit} (in {path})")
    if shell is None:
        first = content.split("\n", 1)[0]
        shell = not first.startswith("#!") or bool(re.search(r"\b(ba|z|da|k|mk)?sh\b", first))
    if shell:
        # the repo's own code (tracked and clean at HEAD) is read leniently; a script the agent
        # wrote or changed is held to the same rules as its command line
        analyze_text(content, ctx.child(not trusted_script(path, ctx)), depth + 1)


def trusted_script(path, ctx):
    """True when path lies in the run's own repository and is identical to origin/<base> there,
    the ref the profile comes from. Commits on the run's branch, other repositories (cloned or
    git init'ed) and a repository without an origin profile do not count."""
    real = os.path.realpath(path)
    root = repo_root(real)
    if not root or not ctx.home or os.path.realpath(root) != os.path.realpath(ctx.home):
        return False
    prof = project_profile(root)
    if prof.source == WORKTREE_SOURCE:
        return False
    ref = f"refs/remotes/origin/{prof.base}"
    rel = os.path.relpath(real, os.path.realpath(root))
    return (bool((git_out(root, "ls-tree", ref, "--", rel) or "").strip())
            and git_out(root, "diff", "--quiet", ref, "--", rel) is not None)


# ---------------------------------------------------------------------------
# analysis of parsed commands


RESERVED = {"!", "{", "}", "if", "then", "else", "elif", "fi", "do", "done", "while", "until",
            "esac", ";;", "coproc"}
SHELLS = {"bash", "sh", "dash", "zsh", "ksh", "mksh", "ash", "yash", "posh", "fish", "rbash"}
INTERP_RE = re.compile(r"^(?:python[0-9.]*|pypy[0-9.]*|perl[0-9.]*|ruby[0-9.]*|node|nodejs|deno|"
                       r"bun|php[0-9.]*|lua[0-9.]*|luajit|tclsh[0-9.]*|wish|Rscript|julia|"
                       r"osascript|awk|gawk|mawk|nawk|jshell|groovy|expect|irb)$")
# wrapper: (options that take a value, positional words before the command)
WRAPPERS = {
    "command": (set(), 0), "builtin": (set(), 0), "exec": ({"-a"}, 0), "nohup": (set(), 0),
    "timeout": ({"-s", "--signal", "-k", "--kill-after"}, 1),
    "nice": ({"-n", "--adjustment"}, 0),
    "time": ({"-f", "--format", "-o", "--output"}, 0),
    "setsid": (set(), 0),
    "stdbuf": ({"-i", "-o", "-e", "--input", "--output", "--error"}, 0),
    "sudo": ({"-u", "-g", "-h", "-p", "-C", "-r", "-t", "-U", "-D", "-T", "-R", "--user",
              "--group", "--host", "--prompt", "--close-from", "--role", "--type",
              "--other-user", "--chdir", "--command-timeout", "--chroot"}, 0),
    "doas": ({"-u", "-C"}, 0),
    "ionice": ({"-c", "-n", "-p", "-P", "-u", "--class", "--classdata"}, 0),
    "xargs": ({"-I", "-d", "-E", "-L", "-n", "-P", "-s", "-a", "--arg-file", "--delimiter",
               "--eof", "--max-lines", "--max-args", "--max-procs", "--max-chars",
               "--process-slot-var", "--replace"}, 0),
    "flock": ({"-w", "--timeout", "-E", "--conflict-exit-code"}, 1),
    "watch": ({"-n", "--interval", "-q", "--equexit"}, 0),
}
GENERIC_WRAPPERS = {"chrt", "taskset", "unbuffer", "catchsegv", "fakeroot", "proxychains",
                    "proxychains4", "torsocks", "dbus-run-session", "firejail", "bwrap",
                    "nsenter", "unshare", "chroot", "setpriv", "strace", "ltrace", "valgrind",
                    "perf", "gdb", "faketime", "rlwrap", "cgexec", "systemd-run",
                    "systemd-inhibit", "prlimit", "numactl", "eatmydata", "busybox", "nocache",
                    "trickle", "schroot", "pkexec", "npx", "pnpx", "bunx", "chronic", "lxc-attach"}
# like xargs: run a command template with arguments from stdin or after :::
PARALLELS = {"parallel", "sem"}
RUNNERS = {"uv", "poetry", "pipenv", "pdm", "hatch", "rye", "conda", "mamba", "micromamba",
           "bundle", "pnpm", "yarn", "npm", "pipx", "cargo", "dotnet", "mise", "asdf", "direnv"}
RAW_ARG_CMDS = {"tmux", "screen", "ssh", "su", "runuser", "script", "at", "batch",
                "xterm", "dtach", "abduco", "byobu", "sshpass", "mosh", "sg", "newgrp",
                "vim", "vi", "nvim", "view", "ex", "ed", "emacs", "less", "more", "man", "sqlite3",
                "psql", "mysql", "gdb", "lldb", "ftp", "lftp"}
# these also read commands from stdin (a pipe, a here-document or a here-string)
STDIN_CODE_CMDS = {"vim", "vi", "nvim", "ex", "ed", "sqlite3", "psql", "mysql", "gdb", "lldb",
                   "ftp", "lftp", "at", "batch"}
CODE_OPT_CMDS = {"su", "runuser", "script"}
# these show or edit files: bin/lib/ns-*.sh as an operand is only read
VIEWERS = {"vim", "vi", "nvim", "view", "ex", "ed", "emacs", "less", "more", "man"}
INTERP_CODE_OPTS = {"-c", "-e", "-E", "--eval", "-p", "--print", "-r", "--command", "--exec"}
AWK_RE = re.compile(r"^[gmn]?awk$")
AWK_VALUE_OPTS = {"-v", "-F", "--assign", "--field-separator", "-i", "--include", "-l", "--load"}
SED_EXEC_RE = re.compile(r"(?:^|[;\n{}])\s*e(?:\s|$|;)|s(.)(?:\\.|(?!\1).)*\1(?:\\.|(?!\1).)*\1[a-zA-Z0-9]*e")


def analyze_text(text, ctx, depth):
    if depth > MAX_DEPTH:
        raise Block("commands nested too deep to check; write them out")
    try:
        cmds = Parser(text).parse_all()
    except ParseError:
        if ctx.strict:
            unparsable(text)
        return  # a script file: the raw scan in scan_file covers it
    analyze_cmds(cmds, ctx, depth)


def analyze_cmds(cmds, ctx, depth):
    if depth > MAX_DEPTH:
        raise Block("commands nested too deep to check; write them out")
    for cmd in cmds:
        analyze_cmd(cmd, ctx, depth)


def analyze_cmd(cmd, ctx, depth):
    for w in cmd.words + [w for _, w in cmd.redirs]:
        for k, v, _ in w.parts:
            if k == "sub":
                analyze_cmds(v, ctx, depth + 1)
    for _, _, subs in cmd.heredocs:
        for s in subs:
            analyze_cmds(s, ctx, depth + 1)
    if cmd.pattern:
        return
    words = list(cmd.words)
    while words:
        a = split_assign(words[0])
        if not a:
            break
        assign(ctx, a[0], word_values(a[1], ctx), depth)
        words.pop(0)
    if not words:
        return
    for argv in variants(words, ctx):
        check_argv(argv, cmd, ctx, depth)


def static_basename(text):
    seg = text.rsplit("/", 1)[-1]
    return None if DYN in seg or not seg else seg


def check_dynamic(args, ctx):
    texts = [a.text for a in args if not a.dyn]
    if OWNER_WORDS & set(texts) or any(t.startswith("--allow-outside") for t in texts):
        raise Block(CMD_DYN_MSG)
    if raw_scan(" ".join(texts)) or raw_scan(ctx.full):
        raise Block(CMD_DYN_MSG)
    if ctx.strict and (not args or args[0].dyn):
        raise Block(CMD_DYN_MSG)


def check_ns(args, xargs):
    if not args:
        if xargs:
            raise Block(NS_DYN_MSG)
        return
    s, rest = args[0], args[1:]
    if s.dyn or s.glob:
        raise Block(NS_DYN_MSG)
    sub = s.text
    if sub in OWNER_SUBS:
        if not xargs and len(rest) == 1 and rest[0].text in ("-h", "--help"):
            return
        raise Block(owner_msg(sub))
    if sub == "stack":
        if rest:
            if rest[0].dyn or rest[0].glob:
                raise Block(NS_DYN_MSG)
            if rest[0].text in ("merge", "drop"):
                raise Block(STACK_MSG)
        elif xargs:
            raise Block(NS_DYN_MSG)
    if sub == "new":
        if any(not a.dyn and a.text.startswith("--allow-outside") for a in rest):
            raise Block(NEW_MSG)
        if xargs or any(a.dyn for a in rest):
            raise Block(NEW_DYN_MSG)


def owner_dispatch(kind, name, args, xargs):
    if kind == "ns":
        check_ns(args, xargs)
    elif kind == "launch":
        raise Block(LAUNCH_MSG)
    elif kind == "gh":
        if xargs or (args and (args[0].dyn or args[0].text == "apply")):
            raise Block(GH_APPLY_MSG)
    elif kind in ("lib", "func"):
        raise Block(lib_msg(name))


def unwrap(args, value_opts, npos):
    i = 0
    while i < len(args):
        a, t = args[i], args[i].text
        if a.dyn:
            break
        if t == "--":
            i += 1
            break
        if t.startswith("-") and len(t) > 1:
            i += 2 if t in value_opts else 1
            continue
        break
    return args[i + npos:], args[:i]


def check_stdin_code(cmd, ctx, depth, shell):
    """A shell or interpreter that reads its program from stdin."""
    for body, _, _ in cmd.heredocs:
        if shell:
            analyze_text(body, ctx.child(True), depth + 1)
        else:
            hit = raw_scan(body)
            if hit:
                raise Block(hit)
    for op, w in cmd.redirs:
        if op not in ("<<<", "<"):
            continue
        alts = expand_word(w, ctx)
        if any(a.dyn for alt in alts for a in alt):
            raise Block("a shell or interpreter reading commands built at run time is not checked")
        for alt in alts:
            text = " ".join(a.text for a in alt)
            if op == "<":
                scan_file(resolve(text, ctx), ctx, depth, shell)
            elif shell:
                analyze_text(text, ctx.child(True), depth + 1)
            elif raw_scan(text):
                raise Block(raw_scan(text))
    if cmd.pipe_in:
        hit = raw_scan(ctx.full)
        if hit:
            raise Block(hit)
        for prev in cmd.pipe_prev:
            for argv in variants(prev.words, ctx)[:1]:
                if not argv:
                    continue
                name = os.path.basename(argv[0].text)
                if name not in ("echo", "printf", "cat") or any(a.dyn for a in argv):
                    raise Block("a shell or interpreter reading commands from a pipe is not "
                                "checked; run the commands directly")
                if name == "cat":
                    for a in argv[1:]:
                        if not a.text.startswith("-"):
                            scan_file(resolve(a.text, ctx), ctx, depth, shell)


def check_shell(args, cmd, ctx, depth):
    i, has_c, noexec, stdin = 0, False, False, False
    while i < len(args):
        a, t = args[i], args[i].text
        if a.dyn:
            break
        if t == "--":
            i += 1
            break
        if t in ("-o", "+o", "-O", "+O", "--rcfile", "--init-file"):
            if t in ("--rcfile", "--init-file") and i + 1 < len(args):
                scan_file(resolve(args[i + 1].text, ctx), ctx, depth, True)
            i += 2
            continue
        if t.startswith("--"):
            i += 1
            continue
        if t[:1] in "-+" and len(t) > 1:
            flags = t[1:] if t[0] == "-" else ""
            has_c = has_c or "c" in flags
            noexec = noexec or "n" in flags
            stdin = stdin or "s" in flags
            i += 1
            continue
        break
    rest = args[i:]
    if noexec:
        return
    if has_c:
        if not rest:
            return
        if rest[0].dyn:
            raise Block("a shell command built at run time is not checked "
                        "(sh -c with a variable or $(...)); write it literally")
        analyze_text(rest[0].text, ctx.child(True), depth + 1)
        return
    if rest and not stdin:
        check_script(rest[0], rest[1:], ctx, depth, True)
        return
    check_stdin_code(cmd, ctx, depth, True)


def check_script(p, rest, ctx, depth, shell):
    """A script given to a shell, source or an interpreter."""
    if p.dyn:
        base = static_basename(p.text)
        if base is None:
            if not ctx.strict:
                return  # inside a script file: the raw scan covers it
            raise Block("cannot tell which script this runs (its path is built at run time); "
                        "write it literally")
        kind = {"ns": "ns", "ns-launch": "launch", "ns-gh": "gh"}.get(base)
        if LIB_RE.match(base):
            kind = "lib"
        owner_dispatch(kind, base, rest, False)
        return
    if p.text.startswith("/dev/fd/") or p.text in ("/dev/stdin", "-"):
        raise Block("sourcing or running a stream is not checked; run the commands directly")
    base = os.path.basename(p.text)
    kind = owner_kind(base, p.text if "/" in p.text else "./" + p.text, ctx)
    if kind:
        owner_dispatch(kind, base, rest, False)
        return
    scan_file(resolve(p.text, ctx), ctx, depth, shell)


def interp_code_args(name, args):
    """The arguments that are program text: -c/-e/... values, or awk's program operand."""
    code, k, has_file = [], 0, False
    while k < len(args):
        t = args[k].text
        if t in INTERP_CODE_OPTS and k + 1 < len(args):
            code.append(args[k + 1].text)
            k += 2
            continue
        m = re.fullmatch(r"-[A-Za-z]*[ceEr](.+)", t) if not t.startswith("--") else None
        if m and not AWK_RE.match(name):
            code.append(m.group(1))
        if AWK_RE.match(name):
            if t in ("-f", "--file") or t.startswith("-f"):
                has_file = True
            if t in AWK_VALUE_OPTS:
                k += 2
                continue
            if not t.startswith("-") and not has_file:
                code.append(t)
                break
        k += 1
    return code


def check_interp(name, args, cmd, ctx, depth):
    for a in args:
        hit = raw_scan(a.text, libs=False)
        if hit:
            raise Block(hit)
    for code in interp_code_args(name, args):
        hit = raw_scan(code)
        if hit:
            raise Block(hit)
    for a in args:
        if a.dyn or a.text.startswith("-"):
            continue
        p = resolve(a.text, ctx)
        if os.path.isfile(p):
            scan_file(p, ctx, depth, False)
        break
    if all(a.text.startswith("-") for a in args):
        check_stdin_code(cmd, ctx, depth, False)


def check_find(args, ctx, depth):
    i = 0
    while i < len(args):
        if args[i].text in ("-exec", "-execdir", "-ok", "-okdir"):
            j = i + 1
            while j < len(args) and args[j].text not in (";", "+"):
                j += 1
            sub = [Arg(DYN) if "{}" in a.text else a for a in args[i + 1:j]]
            if sub:
                check_argv(sub, Cmd(), ctx, depth + 1)
            i = j
        i += 1


def check_git(argv, ctx):
    texts = [a.text for a in argv]
    for k, t in enumerate(texts):
        val = texts[k + 1] if t == "-c" and k + 1 < len(texts) else (t[2:] if t.startswith("-c") else "")
        hit = raw_scan(val)
        if hit:
            raise Block(hit)
    for k, t in enumerate(texts):
        val = texts[k + 1] if t == "-c" and k + 1 < len(texts) else ""
        key, _, value = val.partition("=")
        if val and GIT_HOOK_KEYS_RE.match(key) and value not in GIT_SAFE_VALUES:
            raise Block(f"git -c {val.split('=', 1)[0]} runs commands the guard cannot see")
    i, _ = git_sub(texts)
    if i < len(texts) and texts[i] == "config":
        keys = [t for t in texts[i + 1:] if not t.startswith("-")]
        if len(keys) > 1 and GIT_HOOK_KEYS_RE.match(keys[0]) and keys[1] not in GIT_SAFE_VALUES:
            raise Block(f"git config {keys[0]} runs commands the guard cannot see")
    if i < len(texts) and texts[i] in ("config", "submodule", "bisect", "rebase", "filter-branch",
                                       "difftool", "mergetool"):
        hit = raw_scan(" ".join(texts[i + 1:]))
        if hit:
            raise Block(hit)
    parsed = parse_push([t.replace(DYN, "$?") for t in texts])
    if parsed:
        check_push(parsed[0], parsed[1], ctx.cwd)


def check_argv(argv, cmd, ctx, depth, xargs=False):
    if depth > MAX_DEPTH:
        raise Block("commands nested too deep to check; write them out")
    i = 0
    while i < len(argv) and not argv[i].dyn and argv[i].text in RESERVED:
        i += 1
    argv = argv[i:]
    while argv and not argv[0].dyn and ASSIGN_RE.match(argv[0].text):
        name, _, val = argv[0].text.partition("=")
        assign(ctx, name.rstrip("+").split("[")[0], [val], depth)
        argv = argv[1:]
    if not argv:
        return
    a0, args = argv[0], argv[1:]
    if a0.dyn or a0.glob:
        base = static_basename(a0.text)
        if base is None or a0.glob:
            check_dynamic(args, ctx)
            return
        name = base
    else:
        name = os.path.basename(a0.text.rstrip("/")) or a0.text
    if re.fullmatch(r"=[\w.-]+", name):
        name = name[1:]  # zsh: =cmd is the path of cmd
    texts = [a.text for a in args]
    if name in ("function", "coproc") or (texts[:1] == ["{"] and name not in ("echo", "printf")):
        # function f [()] { body; } and coproc NAME { body; }: check the body
        k = texts.index("{") + 1 if "{" in texts else (1 if name == "function" else 0)
        if k < len(args):
            check_argv(args[k:], cmd, ctx, depth + 1)
        return

    if name in ("for", "select"):
        if args:
            vals = [a.text for a in args[2:]] if len(args) > 1 and texts[1] == "in" else [DYN]
            ctx.vars.setdefault(args[0].text, set()).update(vals or [DYN])
        return
    if name in ("case", "[[", "[", "test", "let"):
        return
    if name == "cd":
        if args and not args[0].dyn and not texts[0].startswith("-"):
            ctx.cwd = resolve(texts[0], ctx)
        return
    if name in ("export", "declare", "typeset", "local", "readonly"):
        for a in args:
            if not a.dyn and ASSIGN_RE.match(a.text):
                n, _, v = a.text.partition("=")
                assign(ctx, n.rstrip("+").split("[")[0], [v], depth)
            elif not a.text.startswith("-"):
                ctx.vars.setdefault(a.text.split("=")[0], set()).add(DYN)
        return
    if name in ("read", "mapfile", "readarray", "getopts", "printf"):
        for k, a in enumerate(args):
            if name == "printf" and not (k > 0 and texts[k - 1] == "-v"):
                continue
            if NAME_RE.fullmatch(a.text):
                ctx.vars.setdefault(a.text, set()).add(DYN)
        return

    kind = owner_kind(name, name if a0.dyn else a0.text, ctx)
    if kind:
        owner_dispatch(kind, name, args, xargs)
        return
    if name == "env":
        check_env(args, cmd, ctx, depth)
        return
    if name in WRAPPERS:
        check_wrapper(name, args, cmd, ctx, depth)
        return
    if name in PARALLELS:
        for k in range(len(args)):
            if not args[k].text.startswith("-"):
                end = next((j for j in range(k, len(args)) if args[j].text in (":::", "::::")),
                           len(args))
                sub = [Arg(DYN) if re.search(r"\{[^}]*\}", a.text) else a for a in args[k:end]]
                if sub:
                    check_argv(sub, Cmd(), ctx.child(False), depth + 1, xargs=True)
        hit = raw_scan(" ".join(texts))
        if hit:
            raise Block(hit)
        return
    if name in GENERIC_WRAPPERS or (name in RUNNERS and texts[:1] and
                                    texts[0] in ("run", "exec", "x", "dlx")):
        start = 1 if name in RUNNERS else 0
        for k in range(start, len(args)):
            if not args[k].text.startswith("-"):
                check_argv(args[k:], Cmd(), ctx.child(False), depth + 1)
        return
    if name in SHELLS:
        check_shell(args, cmd, ctx, depth)
        return
    if name == "eval":
        if any(a.dyn for a in args):
            raise Block("eval of a string built at run time is not checked; write the command literally")
        analyze_text(" ".join(texts), ctx.child(True), depth + 1)
        return
    if name in ("source", "."):
        if args:
            check_script(args[0], args[1:], ctx, depth, True)
        else:
            check_stdin_code(cmd, ctx, depth, True)
        return
    if name in ("alias", "trap"):
        if name == "alias":
            codes = [a.text.partition("=")[2] for a in args if "=" in a.text]
        else:
            codes = [a.text for a in args[:1] if not a.text.startswith("-")]
        for code in codes:
            if DYN in code:
                raise Block(f"{name} with a command built at run time is not checked")
            analyze_text(code, ctx.child(True), depth + 1)
        return
    if INTERP_RE.match(name):
        check_interp(name, args, cmd, ctx, depth)
        return
    if name == "find":
        check_find(args, ctx, depth)
        return
    if name == "git":
        check_git(argv, ctx)
        return
    if name == "gh":
        gh = gh_args([a.text for a in argv])
        if gh is not None:
            check_gh(gh)
            if gh[:2] == ["alias", "set"]:
                hit = raw_scan(" ".join(gh[2:]))
                if hit:
                    raise Block(hit)
        return
    if name in RAW_ARG_CMDS:
        if name in CODE_OPT_CMDS:
            for k, t in enumerate(texts[:-1]):
                if (t == "--command" or re.fullmatch(r"-[A-Za-z]*c", t)) and not args[k + 1].dyn:
                    analyze_text(texts[k + 1], ctx.child(True), depth + 1)
        hit = raw_scan(" ".join(texts), libs=name not in VIEWERS)
        if hit:
            raise Block(hit)
        if name in STDIN_CODE_CMDS:
            check_stdin_code(cmd, ctx, depth, False)
        return
    if name == "sed" and any(SED_EXEC_RE.search(t) for t in texts if not t.startswith("-")):
        raise Block("sed's e command runs shell commands and is not checked")
    if ("/" in a0.text or a0.text.startswith("~")) and not a0.dyn:
        p = locate(a0.text, ctx)
        if p:
            scan_file(p, ctx, depth, None)
        elif not os.path.exists(resolve(a0.text, ctx)):
            hit = raw_scan(ctx.full)
            if hit:
                raise Block(hit)
            if len(re.findall(r"(?<![\w.-])" + re.escape(name) + r"(?![\w.-])", ctx.full)) > 1:
                raise Block(f"{a0.text} is created in this same command line, so the guard cannot "
                            "read it; create it first, then run it in a separate command")


def check_env(args, cmd, ctx, depth):
    i = 0
    while i < len(args):
        a, t = args[i], args[i].text
        if a.dyn:
            break
        if t in ("-S", "--split-string") or t.startswith("-S") or t.startswith("--split-string="):
            if t in ("-S", "--split-string"):
                s, nxt = (args[i + 1].text if i + 1 < len(args) else ""), i + 2
            else:
                s, nxt = (t.split("=", 1)[1] if t.startswith("--") else t[2:]), i + 1
            if DYN in s:
                raise Block("env -S with a string built at run time is not checked")
            rest = " ".join(x.text for x in args[nxt:])
            analyze_text(s + " " + rest, ctx.child(ctx.strict), depth + 1)
            return
        if t in ("-u", "--unset", "-C", "--chdir"):
            i += 2
            continue
        if t == "--":
            i += 1
            break
        if t.startswith("-") and len(t) > 1:
            i += 1
            continue
        break
    if i < len(args):
        check_argv(args[i:], cmd, ctx, depth + 1)


def check_wrapper(name, args, cmd, ctx, depth):
    value_opts, npos = WRAPPERS[name]
    texts = [a.text for a in args]
    if name == "command" and any(t in ("-v", "-V") for t in texts[:2]):
        return
    if name == "flock":
        for k, t in enumerate(texts):
            if t in ("-c", "--command") and k + 1 < len(args):
                if args[k + 1].dyn:
                    raise Block("flock -c with a command built at run time is not checked")
                analyze_text(texts[k + 1], ctx.child(True), depth + 1)
                return
    if name == "watch" and not any(t in ("-x", "--exec") for t in texts):
        inner, _ = unwrap(args, value_opts, 0)
        if any(a.dyn for a in inner):
            raise Block("watch with a command built at run time is not checked")
        analyze_text(" ".join(a.text for a in inner), ctx.child(True), depth + 1)
        return
    inner, opts = unwrap(args, value_opts, npos)
    xargs = name == "xargs"
    if xargs:
        rep = None
        for k, o in enumerate(opts):
            t = o.text
            if t in ("-I", "--replace") and k + 1 < len(opts):
                rep = opts[k + 1].text
            elif t.startswith("-I") and len(t) > 2:
                rep = t[2:]
            elif t.startswith("--replace="):
                rep = t.split("=", 1)[1]
            elif t.startswith("-i"):
                rep = t[2:] or "{}"
        if rep:
            inner = [Arg(DYN) if rep in a.text else a for a in inner]
    if inner:
        check_argv(inner, cmd, ctx, depth + 1, xargs=xargs)


def check_bash(cmd, cwd):
    toks = tokens_dir()
    base = os.environ.get("NS_CONFIG_DIR") or ""
    if (".config/ns/tok" in cmd or toks in cmd
            or (base and (base.rstrip("/") + "/tok") in cmd)):
        raise Block("token files are off limits")
    if PROFILE_WRITE_RE.search(cmd):
        raise Block(".claude/project-profile.yaml is protected (an agent may not edit its own guard)")
    if GIT_WRITE_RE.search(cmd):
        raise Block(GIT_DIR_MSG)
    try:
        cmds = Parser(cmd).parse_all()
    except ParseError:
        unparsable(cmd)
        check_bash_fallback(cmd, cwd)
        return
    analyze_cmds(cmds, Ctx(cwd, cmd, True), 0)


def unparsable(text):
    """Text the parser cannot read: block when it may name an owner-only command at all."""
    hit = raw_scan(text)
    if hit:
        raise Block(f"cannot parse this command line, and it may run an owner-only command: {hit}")
    t = re.sub(r"['\"\\`]", "", decode_escapes(text))
    words = set(RAW_SPLIT_RE.split(t))
    if OWNER_WORDS & words or any(w.startswith("--allow-outside") for w in words):
        raise Block("cannot parse this command line, and it names an owner-only ns subcommand; "
                    "write it so that it parses")


def check_bash_fallback(cmd, cwd):
    """Pushes and merges in a line the parser cannot read: split it as well as possible."""
    import shlex
    for seg in re.split(r";|&&|\|\||\||\n", cmd):
        try:
            words = shlex.split(seg)
        except ValueError:
            continue
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
            check_search(tool, inp, cwd)
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
