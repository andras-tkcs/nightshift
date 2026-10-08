# Security

What Nightshift protects, what it does not, and what to do when something leaks. Commands run as user `ns` on ns-main unless a block says root.

## Threat model

ns-main reads untrusted text all day: issue bodies, pull request comments, web pages, other repositories. A cleverly written text could try to talk an agent into doing something the owner did not want. So the design assumes an agent can be fooled, and limits what a fooled agent can reach:

- ns-main holds nothing worth stealing: no production secrets, no live connector credentials, no customer data, no employer or client code.
- The agent tokens are narrow (below), so a leaked one can only touch the repositories it was made for, and branch rulesets keep it away from the default branch.
- ns-main has no open ports. It is reachable only inside your tailnet; the desk is reached through Tailscale or through Cloudflare Access with the "only me" policy.
- The Linux user `ns` has no sudo and cannot change the installed release in `/opt/nightshift`.
- Agents never merge pull requests, never tag a release and never run `/cut-release`.

The edge of the boundary is the token scopes and the branch rulesets. The guard hook (below) is an extra layer, not the boundary; [The real boundary](#the-real-boundary) lists what each of them stops, and what only the guard stops.

## What lives where

| What | Where | Who can read it |
|---|---|---|
| Agent token for `andras-tkcs` | `gh`'s own store for user `ns` | `ns` |
| Agent tokens for other owners | `~/.config/ns/tokens/<owner>`, mode 600 | `ns`; the guard hook blocks agents from these files |
| Admin tokens for `ns-gh` | typed into `GH_TOKEN` as root for one run, never stored | root, for 7 days at most |
| Claude login | `~/.claude` | `ns` |
| ntfy topic, desk URL, health-check URL | `~/.config/ns/env`, mode 600 | `ns` |
| ntfy token for `ns-notify` (`tk_` and 29 letters or digits; write-only on the one topic) | `~/.config/ns/tokens/ntfy`, mode 600 (`ns-notify` refuses another mode) | `ns`; it goes only to curl on stdin for your own ntfy at `NS_NTFY_URL`, never to ntfy.sh, GitHub (`ns doctor` skips it in the GitHub token check, `ns_token_export` refuses the name `ntfy`), argv, logs or output |
| Run logs (session streams, prompts, check output, `dequeue.log`) | `~/.config/ns/logs/` and `logs/<id>/`, mode 700; `dequeue.log` mode 600 | `ns` |
| Cloudflare tunnel token | the `cloudflared` service on ns-main | root |
| The release | `/opt/nightshift/<tag>`, owned by root | read-only for `ns` |
| The desk | `/srv/ns-space` (owner `ns`, group `caddy`, mode 2750) | `ns`, the web server; reached through Access. Only SilverBullet's static client files (`/service_worker.js`, `/.client/*`) bypass the login, so the service worker can register; they hold no desk content |
| Ledgers | the run's branch `plan/<id>` in git | whoever can read the repository |
| QA test credentials | only on the self-hosted QA runner, never on ns-main | not ns-main |

Nothing prints a token: `ns doctor` shows only file modes and expiry dates and sends only the `tokens/<owner>` files of registered project owners to GitHub, `ns publish` and `ns-notify` refuse anything that looks like a token, and secrets are read with hidden input.

The desk: the `:8443` and `http://127.0.0.1:8080` listeners send `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:` (no scripts, no outside loads), and `*.md` is served as `text/plain`. `ns publish` refuses unsafe HTML first; the header is the second layer for anything it misses or that reached `/srv/ns-space` another way. SilverBullet on `:443` and ntfy on `:8444` do not get the header. See [ADR 0010](adr/0010-desk-content-policy.md).

A token never reaches a tmux server: every tmux session in `bin/` is started through one function that drops `GH_TOKEN`, so a server started by `ns new`, `ns resume`, `ns approve`, `ns up` or `ns dequeue` does not keep the caller's token in its global environment; each conductor loads its own owner's token in `ns-launch`. When a conductor ends, `ns-launch` runs `ns dequeue` without the ending run's token. The ledger push of a run that `ns dequeue` or `ns resume` starts or queues runs with the token of that run's project owner (`tokens/<owner>` when it exists, else `gh`'s own login; a `GH_TOKEN` of the caller is dropped first), set only in the environment of that one `ns-ledger checkpoint --push` (its git commit, push and the repo's hooks).

## Token scopes

- Agent token, one per owner (a fine-grained GitHub token covers one owner only): only the repositories of that owner that Nightshift works on; Contents, Issues, Pull requests and Actions read and write; Commit statuses read. The token for `andras-tkcs` also has Workflows; the one for `privacyfence` has not. No Administration, Secrets or Environments. Expiry 90 days. Details in [accounts.md](accounts.md).
- Admin token, one per owner, used only by `ns-gh audit` and `ns-gh apply`: Administration, Environments and Issues write. It is typed into `GH_TOKEN` as root for that one run and expires after 7 days. The agents' tokens deliberately cannot do what `ns-gh` does.
- `ns` picks the token by the project's owner, so a run for one owner can never use the other owner's token.

Run `ns-gh` as root:

```bash
GH_TOKEN=<admin token> ns-gh audit <owner/repo>
GH_TOKEN=<admin token> ns-gh apply <owner/repo>
```

`audit` shows wanted against current settings and changes nothing. `apply` asks, then fixes only what differs. Do it for a project after its onboarding pull request is merged, because `ns-gh` reads `.claude/ns-github.env` from the default branch.

## The guard hook

The Nightshift plugin installs a guard that runs before an agent edits a file, reads a file, searches or runs a shell command. It blocks:

- reading or writing the token folder `~/.config/ns/tokens`, by file tools, by `Grep`, `Glob` and `LS` (any path that equals or contains the folder, or a glob pattern that reaches it; a call without a path searches the working directory, so that directory is checked as the search root), or by a shell command that names it, including `tok*` globs;
- edits to files that match `protected_paths` in the project's `.claude/project-profile.yaml`, and always edits to that profile itself (file tools and shell redirections such as `>`, `tee`, `cp`, `mv`), so an agent cannot widen its own guard; reading it stays allowed;
- edits to git hooks and `.git/config` (file tools and shell redirections), and git settings that run commands (`core.hooksPath`, `core.sshCommand`, `core.pager`, `core.editor`, `*.command`, diff, merge and filter drivers, credential helpers) set with `git -c` or `git config`, because git would run them where the guard cannot look;
- `git push` to the project's base branch or to the repository's default branch, force pushes (`-f` also inside combined flags like `-uf`, `--force*`, `--mirror`, `+refspec`), `--all`/`--branches`, and pushing tags (`--tags`, `--follow-tags`, `refs/tags/...` or a bare `v1...` name);
- `gh pr merge`, `gh api` calls that write to a `.../merge` path, and `gh release create`;
- the owner-only commands below, and setting `NS_HOME` or `NS_RUN_HOME`, which decide which Nightshift code runs.

The guard reads `protected_paths` and `git.base_branch` from the project's base branch on origin, not from the worktree: from `origin/<default branch>:.claude/project-profile.yaml` (the default branch is `origin/HEAD`, else `main` or `master`), and from `origin/<base>` when that profile names another base branch. A run cannot loosen them by changing its own copy. Only when origin has no profile, for example a project that is still being onboarded, does the guard use the worktree's file, and its message says so: `(protected_paths in the worktree's .claude/project-profile.yaml; no origin/<base> profile)`.

It prints `ns guard: <reason>` and the action does not happen.

### Owner-only commands

These commands are the owner's, because each one either decides something only you decide, uses the project owner's GitHub token for something a run must not do, or reaches outside the run:

| Command | Why it is the owner's |
|---|---|
| `ns kill` | ends a run's session and kills its processes at once |
| `ns tag` | tags a release and pushes the tag; Nightshift never tags (R-SEC-2) |
| `ns desk` (every subcommand) | pushes a branch and opens a pull request with the project owner's token |
| `ns stack merge`, `ns stack drop` | merge pull requests into the base branch, or close one, revert and push, with the project owner's token |
| `ns approve` | releases a gate, which is where you decide; for an onboarding run it pushes a branch and opens a pull request with the owner's token |
| `ns note` | sends a run an instruction that its conductor follows over the plan's scope (bounded: no gates, guard or protected paths) |
| `ns project` | clones a repository with the owner's token, registers it and starts its onboarding run |
| `ns rm`, `ns purge` | deletes worktrees and branches, with `--remote` also remote branches, and closes pull requests with the owner's token |
| `ns gc` | the daily housekeeping (run by a timer, not an agent): deletes remote branches of merged runs with the owner's token |
| `ns new ... --allow-outside` | reads any file user `ns` can read into the run's request, which is pushed to `plan/<id>` on GitHub; the token check only catches a few token shapes |
| `ns-launch` | starts a run's conductor session with the project owner's token (`ns new` and `ns resume` call it) |
| `ns-gh apply` | changes repository settings (it needs an admin token, which agents never have; blocked anyway) |
| `bin/lib/ns-*.sh`, run or sourced directly, and their functions (`ns_*_main`, `ns_stack_merge`, `ns_kill_teardown`, `ns_token_export`, ...) | the code of the commands above; it runs only through `ns` |

Allowed, because runs need them or they change nothing that matters: `ns ls`, `status`, `log`, `report`, `stack` (the list), `stop`, `resume`, `publish`, `profile`, `doctor` (it reads the token files to show their expiry, never their content), `dequeue`, `drain`, `up`, `check` (and its deprecated alias `health-check`), `help`, `ns new` without `--allow-outside`, `--help` of every command, and `ns-conductor`, `ns-ledger`, `ns-notify` and `ns-gh audit`.

The guard does not trust the command to be written plainly. It parses a shell command line the way bash does (quotes, backslashes, `$'...'`, variables and arrays set earlier in the same line, brace expansion, `$(...)`, backticks, `<(...)`, here-documents, `|`, `&&`, `||`, `;`, subshells, groups, functions, `case` branches) and finds an owner-only command in any of these forms:

- by any path: `/usr/local/bin/ns`, `/opt/nightshift/<tag>/bin/ns`, `"$NS_HOME/bin/ns"`, `./bin/ns`, `~/Coding/*/bin/ns`, or a link or copy of the `ns` dispatcher under another name (also through a `PATH=` set in the same line);
- behind wrapper words: `env` (also `env -S`), `command`, `builtin`, `exec`, `nohup`, `timeout`, `xargs`, `parallel`, `sudo`, `nice`, `time`, `setsid`, `stdbuf`, `ionice`, `flock`, `watch`, `strace`, `uv run` and similar;
- inside `bash -c`, `sh -c`, `zsh -c`, `eval`, `trap`, `alias`, `find -exec`, a here-document or here-string fed to a shell, a script run with `bash`, `sh`, `source`, `.` or by its path (the guard reads the script), `python3 -c`, `perl -e`, `node -e`, `awk` and their script files, `tmux`, `screen`, `ssh`, `su -c`, `script -c`, editors and database shells, git aliases and `GIT_*` command variables;
- with quoting and escaping (`'ns'`, `n\s`, `$'\x6e\x73'`, `{ns,stack}`), or with the command name or subcommand in a variable set in the same line.

What it cannot resolve it refuses when it may hide an owner-only command: a command name or an `ns` subcommand built at run time (`$(...) kill`, `ns "$X"`, `xargs ns`), `eval`, `sh -c`, `env -S` or `watch` of a string built at run time, a shell or interpreter that reads commands from a pipe fed by anything but `echo`, `printf` or `cat` of a file it can read, a script that does not exist yet when the line is checked (write it first, then run it), `sed`'s `e` command, and a command line it cannot parse that names an owner-only subcommand. The price is that a few unusual but harmless lines are refused too; write them out plainly.

A shell script the agent runs is held to the same rules as its command line unless it is the project's own code: it must lie in the run's repository (the one the session works in, whose profile the guard reads) and be identical to that repository's `origin/<base>`, the same trusted ref the profile comes from. Everything else is strict: untracked or changed files, files committed on the run's own branch, files in any other repository (cloned or created with `git init`), and files outside a repository. So a script written with one tool call, even committed, and run with the next cannot use a command name or first argument built at run time. In the project's own code only owner-only commands it names (literally or through `ns "$X"`) are refused. The guard's own git calls ignore the system git config and run with `core.fsmonitor` and `core.hooksPath` disabled, so a repository's config cannot run commands inside the guard. `bin/lib/ns-*.sh` given to a viewer, an editor, `awk`, `sed` or as a data file to a script is only read and stays allowed; in program text (`python3 -c`, an awk program, `vim -c`) it is refused.

### Its limits

The guard is a seatbelt, not a wall (ADR 0006). When it cannot read its input at all, or fails inside, it fails open: it prints `ns guard: not checked: <error>` and lets the action through. The choice is deliberate: a failing guard that blocked everything would stop every Claude session on the machine, for example after a Claude Code update that changes the input format. If you see `ns guard: not checked`, tell the next session to look at it.

What remains outside its sight, precisely:

- programs in other languages that build a command from data while they run: the guard only finds owner-only commands written out in their text, so Python, Perl, Node, Ruby or awk code that decodes or assembles `ns` and its subcommand and runs it is not caught, whether given with `-c`/`-e` or as a script file (shell scripts are parsed; other languages are only scanned);
- anything it cannot read when the tool call is made: a file the agent wrote that a test runner or build tool later runs (`conftest.py`, a `Makefile`, `package.json` scripts), a binary, a library preloaded with `LD_PRELOAD`, a file larger than 1 MB, a script sourced by a path built at run time inside a tracked script;
- commands that run later or elsewhere: `at`, cron and systemd timers set up indirectly, or a process started earlier.

So a determined agent can still reach an owner-only action; the guard makes that deliberate and visible, not impossible. The control that has to hold for the owner-only actions with effects on GitHub (merging, tags) or on runs (gate release) is the one tracked in issue #127. It reads the profile from the local `origin/<base>` ref, which an indirect command could forge with `git update-ref`. Copies of token files made outside its sight are not seen either. Other ways to read files are not covered.

## The real boundary

Behind the guard, this is what stops a fooled agent. Only some of it is enforced outside ns-main:

| What a fooled agent tries | What stops it |
|---|---|
| work in another repository or another owner's repositories | the token's repository selection (one owner per token) |
| change repository settings, secrets, environments, rulesets | the token has no Administration, Secrets or Environments permission |
| push to the default branch, force-push it, delete it | the ruleset `ns-default-branch` on the default branch (pull request required, force pushes blocked, deletion restricted) |
| edit `.github/workflows/` | the token's missing Workflows permission, for `privacyfence` only; the `andras-tkcs` token has Workflows |
| merge an open pull request (`ns stack merge`, `gh pr merge`) | **only the guard**, apart from the required status checks the ruleset names (a pull request with failing required checks cannot be merged). The ruleset requires a pull request with 0 approvals, and the agent token is your own fine-grained token, so GitHub cannot tell its merge from yours. The merge is visible in the pull request's timeline. |
| push a tag or create a release (`ns tag`) | **only the guard.** Contents write covers tags. A tag changes nothing on ns-main by itself: the upgrade is a root command you run. |
| read the token files of other owners | **only the guard and the file mode**: the files belong to user `ns`, which agents run as. A leaked token is limited by its scopes above. |
| stop or remove runs, release a gate, read files outside the desk into a run (`ns kill`, `ns rm`, `ns gc`, `ns approve`, `ns note`, `--allow-outside`) | **only the guard**: these act as user `ns` on ns-main. An agent can still write `owner_notes` with `ns-ledger set`, as it can `stop_requested`; a stop can only reduce work, but a forged note can widen scope, though it cannot release a gate, lift the guard or touch protected paths (ADR 0011). |

Check the part GitHub enforces in Review 1 and after every onboarding, as root with an admin token: `GH_TOKEN=<admin token> ns-gh audit <owner/repo>` lists the wanted ruleset, merge settings and workflow permissions against the current ones and changes nothing; `ns-gh apply` fixes what differs (see [Token scopes](#token-scopes)).

## Live-ledger guard

A Nightshift command from a checkout must not write the ledger of a live run (`docs/ledger.md`, "Schema drift and live runs"). `CLAUDE.md`, "Developing Nightshift with Nightshift", says to run new `bin/` code only against test fixtures or temp ledgers. The guard is a seatbelt for that rule: it catches the accidental case, where a checkout's `bin/ns-ledger` is run on the run's own `$NS_LEDGER` or inherits the run's environment. It is not a boundary. An agent running as `ns` can always edit the YAML file directly, which `docs/ledger.md` forbids.

What it trusts:

- The running script's own location: the outermost `BASH_SOURCE`, resolved with `readlink -f` when `ledger.sh` is sourced.
- The `release` field of the ledger file on disk, written by the release that started the run.
- `NS_OPT` (default `/opt/nightshift`) as the release root, together with the rule that the release's resolved directory is named after its tag.
- `NS_RUN_ID` and `NS_LEDGER` to tell which ledger is live. A command started with them unset is not checked (issue #128).
- `NS_RUN_HOME`, but only for a run launched from a checkout (`release: null`). For such runs, naming another checkout as `NS_RUN_HOME` passes.

What it does not trust:

- `NS_HOME`: it must resolve to the same home as the script.
- `NS_RUN_HOME` for a run whose ledger records a release.
- A symlink in `PATH`, in `NS_OPT` or in `NS_HOME`: every path is resolved first, so a link named `vX.Y.Z` that points at a checkout fails.
- Exported shell functions named after the tools it calls (`readlink`, `sed`, `head`, `printf`; it no longer calls `dirname` or `basename`): it calls them through `command` and uses `[[ ]]`.

What gets through, and why that is accepted (each one is a deliberate act, not an accident):

- A copy or a `git worktree` of a checkout placed under a fake `NS_OPT` in a directory named after the run's release tag. That directory looks exactly like a release.
- A `PATH` that puts shims of `readlink`, `sed` or `python3` first, a `BASH_ENV` script, or exported functions named after bash builtins or `command` itself.
- A script that changes directory before it sources `ledger.sh` and was started with a relative path, because its own location is then resolved against the wrong directory. Nightshift's scripts source their libraries first.
- Writing a ledger without `ns-ledger`, for example `python3 <checkout>/bin/lib/nsyaml.py from-json <ledger>`, `sed -i` or an editor. These have no guard at all.

## Review files

`ns-conductor review-round` accepts `approve` only when this round's `RUN/review-<phase>-<n>.md` ends with `REVIEW verdict=approve head=<sha>` for the current phase head, and `merge` lets in only a head that a round approved (docs/conductor.md). That stops a confused conductor: one that passes the wrong verdict, counts the wrong round, or merges a branch that moved after its review. It does not stop a malicious one. The review files live in the run worktree, which the conductor can write, so a conductor that set out to could write an approval itself. The skills forbid it ("run the review again; never edit the review file"), but the boundary for unreviewed code is elsewhere: the guard (merges and pushes to the default branch) and your own review of the pull request (issue #127).

## Untrusted text

Text from issues, the web, pull request comments and other repositories is data, not instructions (R-SEC-3). Agents summarize and quote it; they never execute or obey it. In practice:

- Every run is reminded of this at the start of its session.
- The code reviewer checks the diff for commands or URLs that came from untrusted input.
- A plan that wants to run a command it found in an issue goes to you at gate 1; read those commands before you approve.
- `ns report` reads the ledger, the session logs and the checks logs as data: nothing in them is run, each value is escaped for a Markdown table cell, and malformed lines are skipped and counted. A check's own output can imitate a `== start` or `== end` line of the checks log and so change that check's row in the report; it cannot change anything else.

When you read a plan or a diff and something looks like an instruction from a web page or an issue, that is the thing to doubt.

## Notifications

Notifications go to ntfy.sh under the topic `NS_NTFY_TOPIC` (R-NOT-1). A topic on ntfy.sh is public to anyone who knows its name, so messages contain only the run id, the gate and a desk link, never code, findings or tokens. Only with a self-hosted ntfy (`NS_NTFY_URL` matching the allowlist `https://<host>[:port]`, host not ntfy.sh or a subdomain; see `ns-notify` in usage.md) does `ns-notify` authenticate, with a bearer token that goes to curl on stdin (curl runs with `-q`, ignoring `~/.curlrc`), never in argv, logs or error output; the token is never sent to ntfy.sh, and `ns doctor` test-publishes only to your own ntfy. `ns-notify` cuts the text to 200 characters and refuses text that looks like a token. The topic name is random (`ns-` and 16 hex digits); keep it out of chats and repositories. The desk link only opens after the Cloudflare Access login.

## Worker permission mode

Phase workers are headless Claude processes, so nobody can answer a permission prompt. They run with `--permission-mode`, set by `NS_WORKER_MODE`.

- The default is `auto`: Claude's own classifier allows ordinary actions and blocks risky ones without asking. This is the setting to keep.
- `ns doctor` checks it (check 11): it makes one small headless call in auto mode that has to run a shell command, and fails with a hint when auto mode does not work on this machine. `ns doctor --no-claude` skips the call and prints a `warn`. `ns-conductor start` checks too, and refuses to start a run when auto mode fails.

To use `bypassPermissions` instead, only when `ns doctor` fails on auto mode and you cannot fix it (for example the account or plan does not offer auto mode), add this line to `~/.config/ns/env` as `ns`:

```bash
echo "export NS_WORKER_MODE='bypassPermissions'" >> ~/.config/ns/env
```

To go back, delete that line.

What this gives up: with `bypassPermissions` every tool call of a worker is allowed without any check. Nothing stops a fooled worker from running a command it should not, apart from the guard hook (a seatbelt), the token scopes and the rulesets. That is acceptable on ns-main only because the machine holds nothing worth stealing and the tokens are narrow. Do not use it on a machine that holds other secrets, and set it back to `auto` as soon as auto mode works again.

## When something leaks

Do the matching step at once, then look at recent pushes and pull requests.

- A GitHub agent token: revoke it under Developer settings, then create a new one ([accounts.md](accounts.md)). Branch rulesets kept it away from the default branch; check recent pushes and the Actions runs anyway.
- An admin token: revoke it under Developer settings (it expires after 7 days anyway).
- The Claude login: `/logout` on ns-main, then sign out other sessions on claude.ai.
- Tailscale: remove the machine in the admin console.
- Cloudflare: Networking, Tunnels, `ns-main`, refresh the token (or delete the tunnel and make a new one), then rerun `bootstrap.sh` as root.
- The ntfy topic: change `NS_NTFY_TOPIC` in `~/.config/ns/env` and subscribe to the new topic in the ntfy app.
- A QA or connector credential: rotate it at its provider; these never live on ns-main.

Where your data goes: code and conversations go to Anthropic for the model, and transcripts are deleted from ns-main after 30 days. Cloudflare decrypts traffic to the desk, which is fine for public projects; use the Tailscale addresses for private ones. Keep employer or client code off this server.
