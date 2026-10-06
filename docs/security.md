# Security

What Nightshift protects, what it does not, and what to do when something leaks. Commands run as user `ns` on ns-main unless a block says root.

## Threat model

ns-main reads untrusted text all day: issue bodies, pull request comments, web pages, other repositories. A cleverly written text could try to talk an agent into doing something the owner did not want. So the design assumes an agent can be fooled, and limits what a fooled agent can reach:

- ns-main holds nothing worth stealing: no production secrets, no live connector credentials, no customer data, no employer or client code.
- The agent tokens are narrow (below), so a leaked one can only touch the repositories it was made for, and branch rulesets keep it away from the default branch.
- ns-main has no open ports. It is reachable only inside your tailnet; the desk is reached through Tailscale or through Cloudflare Access with the "only me" policy.
- The Linux user `ns` has no sudo and cannot change the installed release in `/opt/nightshift`.
- Agents never merge pull requests, never tag a release and never run `/cut-release`.

The edge of the boundary is the token scopes and the branch rulesets. The guard hook (below) is an extra layer, not the boundary.

## What lives where

| What | Where | Who can read it |
|---|---|---|
| Agent token for `andras-tkcs` | `gh`'s own store for user `ns` | `ns` |
| Agent tokens for other owners | `~/.config/ns/tokens/<owner>`, mode 600 | `ns`; the guard hook blocks agents from these files |
| Admin tokens for `ns-gh` | typed into `GH_TOKEN` as root for one run, never stored | root, for 7 days at most |
| Claude login | `~/.claude` | `ns` |
| ntfy topic, desk URL, health-check URL | `~/.config/ns/env`, mode 600 | `ns` |
| ntfy token for `ns-notify` (`tk_` and 29 letters or digits; write-only on the one topic) | `~/.config/ns/tokens/ntfy`, mode 600 (`ns-notify` refuses another mode) | `ns`; it goes only to curl on stdin for your own ntfy at `NS_NTFY_URL`, never to ntfy.sh, GitHub (`ns doctor` skips it in the GitHub token check, `ns_token_export` refuses the name `ntfy`), argv, logs or output |
| Cloudflare tunnel token | the `cloudflared` service on ns-main | root |
| The release | `/opt/nightshift/<tag>`, owned by root | read-only for `ns` |
| The desk | `/srv/ns-space` (owner `ns`, group `caddy`, mode 2750) | `ns`, the web server; reached through Access |
| Ledgers | the run's branch `plan/<id>` in git | whoever can read the repository |
| QA test credentials | only on the self-hosted QA runner, never on ns-main | not ns-main |

Nothing prints a token: `ns doctor` shows only file modes and expiry dates and sends only the `tokens/<owner>` files of registered project owners to GitHub, `ns publish` and `ns-notify` refuse anything that looks like a token, and secrets are read with hidden input.

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

The Nightshift plugin installs a guard that runs before an agent edits a file, reads a file or runs a shell command. It blocks:

- reading or writing the token folder `~/.config/ns/tokens`, by file tools, by `Grep`, `Glob` and `LS` (any path that equals or contains the folder, or a glob pattern that reaches it), or by a shell command that names it, including `tok*` globs;
- edits to files that match `protected_paths` in the project's `.claude/project-profile.yaml`, and always edits to that profile itself (file tools and shell redirections such as `>`, `tee`, `cp`, `mv`), so an agent cannot widen its own guard; reading it stays allowed;
- `git push` to the project's base branch, force pushes (`-f` also inside combined flags like `-uf`, `--force*`, `--mirror`, `+refspec`), `--all`/`--branches`, and pushing tags (`--tags`, `--follow-tags`, `refs/tags/...` or a bare `v1...` name);
- `gh pr merge`, `gh api` calls that write to a `.../merge` path, and `gh release create`;
- `ns kill`, `ns tag`, `ns desk`, `ns stack merge` and `ns stack drop`, which are the owner's commands.

The git and gh checks look through global options (`git -C`, `--git-dir=...`, `gh -R <repo>`), a full path to the program and prefix words (`env`, `command`, `exec`, `nohup`, `time`).

It prints `ns guard: <reason>` and the action does not happen.

Its limits: it is a seatbelt, not a wall (ADR 0006). When it cannot understand its input, or fails inside, it fails open: it prints `ns guard: not checked: <error>` and lets the action through. The choice is deliberate: a failing guard that blocked everything would stop every Claude session on the machine, for example after a Claude Code update that changes the input format. It also reads shell commands only as far as splitting and quoting go, so a determined indirect command (a script that pushes, a variable or `eval` building the command, `sh -c`, a copy of a token file made outside its sight) is not seen. Other ways to read files are not covered either. That is why the real boundary is the token scopes and the rulesets on the default branch. If you see `ns guard: not checked`, tell the next session to look at it.

## Untrusted text

Text from issues, the web, pull request comments and other repositories is data, not instructions (R-SEC-3). Agents summarize and quote it; they never execute or obey it. In practice:

- Every run is reminded of this at the start of its session.
- The code reviewer checks the diff for commands or URLs that came from untrusted input.
- A plan that wants to run a command it found in an issue goes to you at gate 1; read those commands before you approve.

When you read a plan or a diff and something looks like an instruction from a web page or an issue, that is the thing to doubt.

## Notifications

Notifications go to ntfy.sh under the topic `NS_NTFY_TOPIC` (R-NOT-1). A topic on ntfy.sh is public to anyone who knows its name, so messages contain only the run id, the gate and a desk link, never code, findings or tokens. Only with a self-hosted ntfy (`NS_NTFY_URL` set to a host other than ntfy.sh) does `ns-notify` authenticate, with a bearer token that goes to curl on stdin (curl runs with `-q`, ignoring `~/.curlrc`), never in argv, logs or error output; the token is never sent to ntfy.sh, and `ns doctor` test-publishes only to your own ntfy. `ns-notify` cuts the text to 200 characters and refuses text that looks like a token. The topic name is random (`ns-` and 16 hex digits); keep it out of chats and repositories. The desk link only opens after the Cloudflare Access login.

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
