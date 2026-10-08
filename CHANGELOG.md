# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `ns note <id> "text"` sends a running run an instruction. It is appended to the new ledger field `owner_notes`, committed and pushed; the conductor reads unread notes after every step with `ns-conductor owner-notes <id>`, follows them over the plan's scope, and marks them read. `ns report` lists them under `## Owner notes`. Agents cannot run it (guard) (ns-x7).

## [0.1.10] - 2026-10-08

### Changed

- Conductor overhead (issue #174, part 1 of #169): the conductor waits for subagents through the Agent call's return or the task notification and for workers with `ns-conductor wait`, never with fetch, sleep or file-poll loops; it runs no tests, checks or edits in a worktree while an implementer works there (`ns-conductor checks` only after the implementer returned); it skips `ns:triage` when the owner gave the tier. New `ns-conductor risk-check <id>` runs at Sync: it matches the diff against `risk_zones` and `platform_paths`, records the tags and `risk_floor`, and sets `tier_recommended` (named in the ntfy line) only when the floor is above the owner's tier. A checks cache hit appends `== cached <UTC>` to the checks log. The run report's Summary has a `Full suite runs` row (cache hits not counted; flagged for a T0/T1 run with more than one).

### Fixed

- `ns report`: the dead or stopped gap before a `resumed` event starts at the last assistant or user message in the session logs, not at the previous ledger event, so work done before the crash is no longer counted as dead time. Without logs the ledger rule stays (issue #156).

## [0.1.9] - 2026-10-08

### Security

- The desk's HTML listeners (`:8443` and `http://127.0.0.1:8080`) send `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:`, so a desk page cannot run scripts or load anything from outside, also when it did not go through `ns publish`; directory listings lose their inline JavaScript. ADR 0010 (issue #5).
- `*.md` files on those listeners are served as `text/plain; charset=utf-8` and never render as HTML (issue #27).

### Added

- Local Caddy additions go in `/etc/caddy/Caddyfile.d/*.caddy`, imported at the end of the rendered Caddyfile. `bootstrap.sh` step 1 creates the directory, `--check` lists the snippet names (`ok (local: <names>)`), and a rerun never touches them. After installing this release, run `bootstrap.sh` once as root to rewrite the Caddyfile (`--upgrade` leaves it alone) (issue #26).

### Changed

- `ns health-check` is now `ns check` (the `ns-health.*` systemd units keep their names and run `ns check`). `ns health-check` still works as a deprecated alias (ns-x4).
- `ns-conductor checks` takes a per-worktree lock (a second call waits and reports the first call's result), caches a pass by tree SHA, canonical target and the profile's checks (`logs/<id>/<canonical target>.checks.json`; a dirty worktree, a changed tree, a failure or `--force` reruns), treats `fix` as `feature` for T0/T1, and warns on stderr when the worktree's HEAD lacks the run's pushed code branch or an unmerged phase branch; `stack-base` also merges the base branch when the code branch is behind and pushes it, and runs at the end of implement, before review; workers run only the tests covering their files, and the integrator and `/ns:dod` get the full suite from `ns-conductor checks` (ns-x5).

### Fixed

- Run report and `ns log` gaps (ns-x6): `ns log` stamps each line with the event's own time; the report timeline of T0 and T1 runs follows `step` events (`ns-ledger set` now appends a `step` event when `.step` changes); a session without a result event gives partial tokens summed from its assistant messages; a subagent without a task notification takes its time from its Agent call to its tool result; a new Checks breakdown table counts runs and total time per check (`ns-conductor checks` now appends to the checks log, each run opening with `== run <UTC>`).
- The desk through Cloudflare Access no longer fails with "Failed to register a ServiceWorker ... The script resource is behind a redirect": `docs/accounts.md` adds a `Nightshift desk static` Access application with a Bypass policy for SilverBullet's `/service_worker.js` and `/.client/*`, as SilverBullet's authentication proxy notes require. `docs/setup.md` gets a curl check for it, and `docs/security.md` and `docs/operations.md` list the bypass and its teardown.

## [0.1.8] - 2026-10-06

### Security

- `ns-conductor report --rerun` can no longer certify a phase the worker never finished: it refuses a phase branch with no changes of its own against the feature branch and records a `report-rerun` event (shown by `ns status` and the run report). `review-round` records its verdict and the phase head it reviewed; `approve` needs this round's `RUN/review-<phase>-<n>.md` ending with `REVIEW verdict=approve head=<sha>` for the current phase head (the code reviewer now writes `head=`), and a missing file, a missing or contradicting verdict line or another head exits 9 and records nothing. `merge` exits 8 unless the last round approved exactly the current phase head, and refuses a phase branch with no changes of its own. Board fix rounds (`fix-<n>`) are reviewed like a phase. The review files are conductor-writable, so this stops a confused conductor, not a malicious one. The e2e t1 scenario matches Claude Code's own auto mode classifier denial text and reads `notes.md` from the run's worktree (issue #71). A second refusal (exit 9) on the same review round escalates, and a malformed `head=` gets its own message.

### Added

- The run report (`ns report`) shows tokens and cost per agent (conductor, each phase worker attempt), per model and in total, from the `result` events in `logs/<id>/*.jsonl` (each session counted once, as its results are running totals), lists the subagents with model, runs and time, gives each timeline row its tokens and cost, and has a Checks section with one row per check (target, PASS/FAIL/SKIP, time, start); SKIP is listed below it, and the integrator and `/ns:dod` keep SKIP rows in the PR's Checks table. `ns-conductor checks` writes `== start` and `== end` lines with UTC times and the result per check into the checks log, and `ns-conductor start` keeps an earlier attempt's log as `<phase>--attempt<n>.jsonl`. Missing or malformed logs give `no data` cells, never a failed report; background subagents are counted, timeline tokens are scaled to each session's `modelUsage`, and a token-shaped string is redacted before the report is written. `ns_escalation_question` drops control characters and cuts at 200 characters, not bytes (issues #65, #62).
- The run report has a `conductor work` row for running time that no phase or review row covers (the work after a gate 1.5 answer was missing; ns-5 lost 3h 33m of its 5h 52m active time that way), and `ns-conductor gate <id> 1.5` keeps the escalation's question in its gate event note, so every escalation shows its cause; older ledgers keep `cause not recorded` (issue #118).

### Changed

- One live-job guard for every `bootstrap.sh` mode that changes the install (a plain run, `--upgrade`, any step): it refuses with exit 1 while a run has a live job (its tmux session, the conductor pid in `logs/<id>/conductor.pid` that `ns-launch` now writes, or a worker pid file) and lists each as `id  state  release  pid`; `--force` applies to every mode. A run that is `running` in its ledger with nothing alive is a warning (`looks dead: ns kill <id> or ns stop <id>`), and runs at a gate, queued or parked are listed as information: they no longer block an upgrade, since they resume on their own release. `--check` stays read-only and reports the jobs. While it runs, `bootstrap.sh` holds `/opt/nightshift/.upgrade.lock`; `ns new`, `ns resume` (and `ns dequeue`) and `ns approve` refuse to start a conductor meanwhile, and a run that passed that check just before the lock was taken (for example during `ns new`'s triage) is queued instead of started, and `bootstrap.sh` waits for the queue lock before it lists the jobs, so a start in flight is seen. A lock whose pid is not a running `bootstrap.sh` is ignored with a warning; one without a readable pid counts as held (remove it as root). `bootstrap.sh` reads pid files only when they are regular files, not symlinks, and only their first bytes, and drops control characters from the ledger fields it prints. Plugins are updated only through `bootstrap.sh` (step 9), behind the same guard (issues #72, #78).
- A run pinned to a release other than `/opt/nightshift/current` loads that release's plugins: `ns-launch` starts the conductor with `--plugin-dir <release>/plugins/ns` and the release's plugin of each stack the project uses, instead of the marketplace plugins that `bootstrap.sh` re-pins to the current release; an explicit `NS_PLUGIN_DIRS` still wins (issue #72).
- `ns-conductor finish` publishes the run report best effort but fails again (exit 1, after the ledger is recorded and pushed) when the handoff report of a T2/T3 run cannot be published; bats cases prove that `finish` and the owner's kill command each leave a committed `run-report.md` (issue #118).

### Fixed

- The review-round cap no longer costs an extra review. Interface change: `ns-conductor review-round <id> <phase> <approve|changes>` now needs the review's verdict (a two-argument call exits 2; the bundled skills pass it). An approval always proceeds (a T2 approval on round 3 merges), and `changes` exits 7 when the count reaches `budgets.<tier>.review_rounds`, so at most that many reviews run; the run report's timeline label leaves the verdict out (issue #12).
- `ns-conductor wait` treats a worker as hitting a usage limit only when its last `result` is an error (`is_error` or a non-success `subtype`) whose message starts with one of Claude Code's limit texts, which now includes the current "You've hit your session limit · resets ..." text; a successful report that mentions a rate limiter, or an error for another reason, is a normal finish. A usage limit pauses the budget until the reset time (`budget.paused_until`; 15 minutes doubling to at most 4 hours when no time can be read), `start` exits 8 meanwhile, the conductor parks the run and `ns health-check` resumes it after the reset, instead of restarting the phase in a loop. A limit that does not reset (spend limit, no usage credits) or the fourth limit of a phase escalates to gate 1.5. When the conductor's own session ends on a usage limit, `ns-launch` pauses and parks the run (or escalates a limit that does not reset), and it also parks a run that `wait` had paused when the conductor died before parking; `ns health-check` runs `ns dequeue` first and then wakes such runs (parked, or running with a dead conductor, never at a gate), reporting resumed and queued ones separately; `ns stop` stops a run parked on a usage limit for good. A conductor launch after `paused_until` clears the pause (the wall-clock budget counts again), and the fourth conductor-side usage limit without progress escalates to gate 1.5. A capacity 429 or a 529 overload is retried once after a minute (`wait` prints `retry <phase>` when it is due), then takes the normal failure path (issue #11).
- The worker pool limit (`max_workers`, R-CON-2) holds across runs: `ns-conductor start` counts the live workers again, spawns the worker and waits for its pid file holding an `flock` on `workers/.lock`, so two conductors can no longer both take the last slot; the worker does not inherit the lock, a stale lock file never blocks, a symlinked one is not truncated, and a lock busy for `NS_POOL_LOCK_WAIT` seconds (default 60) queues the phase (exit 3). A `queued` phase no longer strands: `ns resume` resets it to `pending`, `/ns:implement` treats it as ready, and `ns-conductor wait` with no live worker of the run sleeps until a pool slot frees instead of returning at once. New `tests/e2e/pool-watch.sh` prints the live worker count of a Nightshift home (by pid file and by `ns-worker` session leader), the most seen, and fails when the two disagree with no worker process at all (issue #10).
- `ns resume` reconciles merged phases with the run's profile (the project's prefix and `--branch`), so a custom `git.phase_trailer` on a project added with `--branch` is honored and a merged phase is no longer reset to `pending` and run again (issue #14).
- Budgets are enforced on every tier: the new `ns-conductor budget-check`, run by `should-stop` (after every step), `start`, `fix-branch`, `checks`, `review-round` and `stack-base`, stops a running run once `budget.used` reaches the limit, writes `RUN/escalation.md` with a `budget_hours:` line, opens gate 1.5 and exits 4, so T0 and T1 runs no longer rely on the model to stop; a new `budget` PreToolUse hook escalates a conductor that works past its budget without calling `ns-conductor` and denies its tool calls, and the `checkpoint` Stop hook escalates a session that ends over budget; `ns approve` takes a raised `budget_hours` as the new limit; `ns-ledger budget-exceeded` is true from `used >= limit`. A resumed run no longer counts the gap as budget used: `ns-ledger set` and `state` restart the clock whenever a run goes back to `running` (`ns resume`, `ns resume --all`, `ns dequeue`, `ns approve`, a new conductor) and charge the running time up to a gate, park or pause, and `ns resume` (also when it queues the run), `ns drain` and `ns kill` restart it for a crashed run; checkpoints carry the time below the 0.01 h step to the next one instead of dropping it; once `stack-base` has passed, the integrator's own calls may finish over budget by at most max(0.5 h, 25 % of the limit), only in the same running stretch (`budget.integrate_from`, cleared when the run leaves `running` or is resumed); a stale budget escalation document is rewritten; the Stop hook has a timeout (issue #9).
- `bootstrap.sh --upgrade` also runs step 10, so it installs and enables the `ns-health` timer (and takes the units from the release it installs) (issue #56).
- No false `silent` during a long check: the checks log and `.checks.rc` marker count as output, and a run whose conductor is running `ns-conductor checks <id>` (under its tmux pane) is not silent while the check has run for less than `NS_CHECKS_MAX_SECS` (default 3600); `NS_SILENT_SECS` stays 1200. `ns health-check` no longer notifies twice after a tick that could not read a run's ledger (issue #56).
- `ns-ledger init` records a `release` only when `NS_HOME` is `${NS_OPT:-/opt/nightshift}/<tag>` with a tag matching `^v[0-9][0-9A-Za-z._-]*$`, the check `ns resume` uses (issue #72).

- A budget escalation writes a `gate` event with its cause (`budget used up: <used> h of <limit> h`), so the run report counts the wait as a gate wait and shows the cause (integration of #140 with #157).

## [0.1.7] - 2026-10-06

### Security

- The live-ledger guard checks the running script's own resolved directory, not only `NS_HOME`: a checkout's `bin/ns-ledger` that inherited a run's `NS_HOME` no longer writes the run's ledger. For a run started from a release, the home is the release the ledger records (`${NS_OPT:-/opt/nightshift}/<release>`), so setting `NS_HOME` or `NS_RUN_HOME` to a checkout, or linking it into `NS_OPT`, no longer passes. `NS_HOME` and `NS_OPT` are both resolved, so a symlinked `NS_OPT` works. Exported shell functions named after the guard's tools do not change its answer. It is a seatbelt against the accidental case, not a boundary: a copy of a checkout under a fake `NS_OPT` named after the tag still passes, and so do writes that bypass `ns-ledger`. `docs/security.md` lists what it trusts (issue #120).
- `ns doctor` sends only token files named after a registered project owner (`tokens/<owner>`) to GitHub; it no longer sends `tokens/ntfy` or any other file there. It checks `tokens/ntfy` on its own: mode 600, ntfy's token format and a test publish to `NS_NTFY_URL`. `ns-notify` refuses a token file that is not mode 600 or does not hold an ntfy token (`tk_` and 29 letters or digits), so nothing can break out of the curl config, and prints curl's error line after `could not reach ntfy`. After a security review: curl runs with `-q` (no `~/.curlrc`) and a non-numeric HTTP code prints as `HTTP ?`; the ntfy token is never sent to ntfy.sh (`ns-notify` sends without it and warns; `ns doctor` skips the test publish with a warning); the doctor test publish has priority `min` (new `NS_NTFY_PRIORITY`); token file names must match an owner exactly; an owner file holding an ntfy token is a `FAIL`; the token format check no longer depends on the locale; `ns publish` and `ns-notify` refuse text holding an ntfy token; `ns_token_export` refuses the owner name `ntfy`. The token goes only to an allowlisted `NS_NTFY_URL` (`https://<host>[:port]`, host not ntfy.sh or a subdomain, no `%`, `@` or `\`), so no other spelling of ntfy.sh gets it; `ns gc` names the real reason when an owner's token file is unusable. docs/security.md lists the ntfy token, docs/usage.md its path. After the release, rotate the ntfy token on ns-main, since earlier `ns doctor` runs sent it to api.github.com. The review checklist asks for the failing test, with all its assertions, in its own commit before the fix (issues #87, #33, #34, #35).
- The guard blocks owner-only commands in every form it can parse, not only a literal `ns kill`: any path to `ns` or a link or copy of it, wrapper words (`env`, `command`, `exec`, `nohup`, `timeout`, `xargs`, `sudo`, `nice`, `time`, `setsid`, `stdbuf`, ...), `bash -c`/`sh -c`/`eval`/`source`, scripts it reads before they run, `$(...)`, backticks, pipes and chains, quoting and escaping tricks, and variables or arrays holding the name; what it cannot resolve is refused when it may hide one. Owner-only are now `ns kill`, `tag`, `desk`, `approve`, `project`, `rm`/`purge`, `gc`, `stack merge`/`drop`, `ns new --allow-outside`, `ns-launch`, `ns-gh apply` and running or sourcing `bin/lib/ns-*.sh`. Pushes and merges hidden in `sh -c`, `eval` or substitutions are checked too; git hooks, `.git/config`, command-running git settings and `NS_HOME` are off limits. A shell script is checked as strictly as the command line unless it lies in the run's repository and is identical to `origin/<base>`; reading `bin/lib/ns-*.sh` with a viewer, `awk` or `sed` stays allowed (issues #16, #58, #81, #117).
- The guard reads `protected_paths` and the base branch from `origin/<base>:.claude/project-profile.yaml` instead of the worktree (the worktree's file only when origin has none, and the message says so), checks a `Grep` or `Glob` without a path against the working directory, and docs/security.md describes the real boundary: what the token scopes and the ruleset stop, and what only the guard stops (issue #16).
- No tmux server started by `ns` keeps a `GH_TOKEN` (bats-tested for `ns new`, `ns resume`, `ns up` and `ns dequeue`); the ledger push of a run that `ns resume` or `ns dequeue` starts gets that run's owner token (else `gh`'s login, never the caller's `GH_TOKEN`) in the push's environment only; `ns drain` keeps an owner's pending `ns stop`; `logs/` and `logs/<id>/` are created (or set) mode 700 and `dequeue.log` mode 600; a symlinked `queue.lock` is never truncated (issue #96).

### Added

- `ns rm <id> --forget` drops a removed run from `runs.yaml` so its id can be reused (it refuses while `plan/<id>` is on origin unless `--remote` is given in the same call, and refuses runs `ns rm` may not remove); `ns rm` on a run whose worktree is gone reads the ledger from `origin/plan/<id>`, so `ns rm <id> --remote` after a plain `ns rm <id>` deletes the remote branches; `ns new` on an archived id says the run is archived and names `ns rm <id> --forget --remote` instead of `ns resume`; `ns rm` and `ns gc` delete only the branches the profile gives the run (a feature or phase branch in the ledger that is not the run's own is skipped with a warning), and a reused id's desk archive gets a `-2` suffix instead of colliding (issue #91).

### Changed

- The release tag command refuses when `CHANGELOG.md` has entries under `[Unreleased]` or no section for the version being tagged, and says to move the entries in the release pull request; repositories without `CHANGELOG.md` are not checked (issue #88).
- `ns_kill_teardown` takes named options `--session` and `--keep-state` instead of the positional words `session` and `keep`; `ns kill` and `ns stop` are updated (issue #58).
- `ns desk import` refuses a `<repo path>` under `.github/workflows/`, one that is not normalized (`./`, `//`) and one that is or goes through a symlink on the base branch, and prints an open `nightshift/desk-*` pull request for the same `<repo path>` instead of opening a second one; `ns new --allow-outside` without `--from-desk` is a usage error (issue #117).
- `ns tag` keeps running the project checks locally even when CI on the commit is green (decision recorded in docs/usage.md; issue #81).
- `ns resume --all` no longer restarts runs that are `stopped` (by `ns stop`, `ns kill` or a declined triage): it names them and `ns resume <id>` restarts them; parked and crashed runs are resumed as before (issue #96).
- Stacking (issues #85, #119): a stack belongs to one base branch, so `ns-conductor stack-base`, `ns stack`, `ns stack merge` and `ns stack drop` only count run PRs whose chain bottoms out at the profile's base branch (run PRs of earlier e2e runs on other bases no longer make `stack-base` exit 7), and exit 7 names the profile's base branch as a choice instead of `main`. Red base: `stack-base` prunes red leaf PRs (pending counts as not failing; a PR already merged into the run's branch is never pruned) before counting chains, stacks on what is left, records the pruned PRs (`stack_skipped`, a `stack` event) and the PR body says `Stacked on #N (checks failing on #M)`. A chain whose bottom targets a closed or merged run branch counts only when that PR's base leads to the profile's base branch; an unknown base goes to gate 1.5. Open and closed PRs are read with `gh api graphql --paginate` (no limit of 100), and the closed search only runs when a base can be a closed PR and warns when it fails. `ns stack merge` and `ns-conductor checks` share one check runner; merge prints `SKIP no checks configured` and tells a failed check from checks that could not run. A cycle of PR bases is warned about and each PR is listed once. The stack e2e scenario only counts leftovers on its own base branch and pages its lists.

### Fixed

- Ledger reads keep Python's stderr apart from the JSON line, so a warning on stderr no longer breaks a read; after a recovery the `unknown field <k>; kept` warning names the restored version's unknown fields only (documented in `docs/ledger.md`); the drift classification in `nsyaml.py` is commented and tested; ADR 0004 is back to its accepted Decision with a dated note, and the `nsyaml.py` subcommands are listed in `docs/architecture.md` (issue #120).
- `ns kill` waits after SIGKILL, up to about 2 s, until no live process is left in a killed process group, so the ledger is written only after the conductor is gone and cannot interleave with its last checkpoint; this also fixes the flaky `kill.bats` test (issue #58).
- The `ns tag` message also lists squash-merged pull requests (`<title> (#N)`), not only merge commits (issue #81).
- `ns resume` and `ns dequeue` roll a run back to its previous state and queue mark when the `resumed` event, the ledger commit (or a token file with the wrong mode) or the tmux start fails after the ledger was set to `running` (before, the run stayed `running` with no session, or lost its place in the queue), and a failed ledger write while phases are reconciled stops the resume (issue #96).

## [0.1.6] - 2026-10-06

### Security

- `ns new --from-desk` resolves the path and refuses a file outside the desk directory unless `--allow-outside` is given, and refuses a note that looks like it contains a token; the guard blocks agents from running `ns desk` (issue #95).

### Changed

- Docs and settings describe the 16 GB ns-main (8 vCPU, `max_runs` 3, `max_workers` 4 in its `config.yaml`; the code defaults stay 2, for the 4 GB minimum), and every place that runs the bats suite uses the parallel form `bats --jobs "$(nproc)" tests/bats`: Nightshift's profile `commands.test`, the `ns tag` fallback, the final reviewer and `/implement-local` (issue #116).
- `ns stack` and `ns-conductor stack-base` treat a base as closed only when the closed PR was closed at or after the dependent PR was created and no open PR has that head name; a fork of run PRs is now several chains (`stack-base` exits 7); the stack e2e scenario only counts open PRs of runs with a `plan/<run id>` branch as leftovers (issue #97).

- CI is split into parallel jobs `lint`, `bats` and `plugin-validate`, plus an aggregate job `checks` (the required status check, unchanged) that fails unless all three succeed, so lint failures no longer wait behind the bats suite (issue #103).
- `ns_ledger_read` validates and parses a ledger in one Python launch (new `nsyaml.py read <file> <schema.json>`), halving the launches per ledger read (issue #101).
- The bats suite runs in parallel: CI installs GNU `parallel` and runs `bats --jobs "$(nproc)"`, and CLAUDE.md and docs/development.md document `bats --jobs 2` for local runs (issue #102).

### Added

- `ns stack merge [project] [--dry-run]` lands the stack bottom to top (the profile checks run once on the top of the stack first; each PR needs an approval, no failing checks and no conflicts; the next PR is retargeted to the base branch before the one below is merged; it stops at the first PR that is not ready and lists what is left), and `ns stack drop <id> [--dry-run]` closes a run's PR, restacks the PR above it onto the layer below and reverts the dropped change in it (it stops and names the PR when the revert does not apply). Both are blocked for agents (issue #74).
- `ns report <id>` writes `runs/<id>/run-report.md` from the run ledger: a summary (wall, active and waiting time, budget, review rounds, escalations) and a timeline with one row per step. It is written automatically when a run finishes or is killed, published to the desk at finish and linked from the PR body; it reads `origin/plan/<id>` when the worktree is gone (issue #64).
- `tests/lint` guards against jq version drift: it fails on a bare `reduce`/`foreach` expression followed by `as $name` (accepted by jq 1.8, rejected by CI's jq 1.7.1; write `(reduce ...) as $name`) and warns when local jq differs from CI; `NS_LINT_STRICT_JQ=1` makes the warning a failure (issue #105).
- `max_runs` (config, default 2) limits live run conductors: `ns new`, `ns resume`, `ns resume --all` and `ns approve` queue a run past the limit, the new `ns dequeue` starts queued runs oldest first when a conductor ends, `ns new --now` skips the limit, `ns ls` shows `runs` in WAITING-ON and `ns status` the queue position (issue #75).
- `ns new <prefix> --from-desk <path.md>` starts a run from a desk note (the request is copied into the ledger; nothing in the repo, no PR), and `ns desk import <path.md> <repo path>` lands a desk note in the repo via a pull request that is never merged (issue #76).
- Stacked PRs, follow-ups: a run PR needs `plan/<run id>` on origin and `{n}` matches digits only; `stacked_on` records the profile base branch; `stack-base` refuses to merge over untracked files and exits 7 (gate 1.5) when open run PRs form more than one chain; `ns stack` prints each chain and marks a PR whose base was closed unmerged (`base closed`), and `stack-base` warns about it; new `stack` e2e scenario (issue #84).
- `ns tag` warns when Nightshift runs are active, since `bootstrap.sh --upgrade` refuses while they are, and its docs name the profile's base branch instead of `main` (issue #80).

### Fixed

- A ledger with an unknown top-level key (schema drift between releases) is read with a warning `ledger has unknown field <k>; kept` instead of being treated as corrupt; missing fields and wrong types stay errors, and the message names the field and points to `ns-ledger validate <ledger>`. A Nightshift command started from a checkout that is not an installed release (`NS_HOME` differs from `NS_RUN_HOME`, the home that launched the run) refuses to write the ledger of the live run marked by `NS_RUN_ID` and `NS_LEDGER`; temp ledgers stay allowed (issue #83).

## [0.1.5] - 2026-10-05

### Added

- Stacked PRs, part 1: `ns-conductor stack-base <id>` merges the top open run PR into the run's branch and prints the PR base (exit 6 on a conflict), the ledger records `stacked_on`, `ns stack [project]` lists the stack bottom to top, `ns status` shows a `stacked` line, and the integrator opens the PR against the stack top (issue #73). The end-to-end scenario is still to do.
- `ns tag <vX.Y.Z>` tags and pushes a release after checking that main is clean and equal to origin, the version is the next step, the tag is new and the project checks pass; it warns on CI that is not green and prints the upgrade command. The guard blocks agents from running it (issue #50).

## [0.1.4] - 2026-10-05

### Added

- Runs keep the Nightshift release they started on: the ledger records `release`, `ns resume` and `ns-launch` use it (failing clearly if it is gone), `ns status` shows it, and `bootstrap.sh --upgrade` refuses while runs are active unless `--force`. A ledger `release` that is not a tag is refused, and runs whose ledger cannot be read count as active for the upgrade check (ns-46).
- `ns-conductor note` records follow-ups in `RUN/notes.md` (listed in the PR body) and `ns-conductor report --rerun` regenerates a phase report record; `ns status` and the gate 1.5 notification show the escalation question (issue #47).

## [0.1.3] - 2026-10-05

### Added

- `ns kill <id>` ends a run's session, conductor and worker process groups at once and marks it `stopped`; the guard blocks agents from running it (ns-42).
- `ns ls` and `ns status` show run health (`ok`, `dead`, `silent <N>m`) and `ns ls` has ELAPSED and LAST-OUT columns; `ns health-check` and the `ns-health.timer` notify once per dead or silent run (issue #43).
- `ns rm <id>` (alias `ns purge`) removes a stopped, failed, parked or done run: worktrees, branches, tmux session and desk folder, with `--remote`, `--force`, `--dry-run`, `--yes` and `--all-stopped` (issue #60).
- `ns log <id> [-f] [--phase <p>] [--raw]` shows a run's session logs as readable, wrapped text.

### Fixed

- `ns-conductor checks` runs each check in a clean environment with no `NS_*` variables (issue #37), writes a non-zero `.rc` marker when the body dies or a check fails (issue #39), and reports a pytest exit 5 as `SKIP` instead of `FAIL`. `report` accepts a short head sha that is a prefix of the real head.
- `ns-conductor merge` detects an already merged phase on long histories; the `git log | grep -q` pipe failed under pipefail (issue #40).
- `ns stop` on a run with no live conductor (at a gate, or dead) now stops it at once instead of waiting for a checkpoint that never comes (ns-42).
- `stream-view.py` survives malformed events and a closed stdout instead of killing the conductor's pipe (issue #43, #13).
- The session stream view no longer truncates tool input at 120 characters; it wraps to the terminal width with a hanging indent and shows tool results as one short line (issue #44).

## [0.1.2] - 2026-10-04

### Changed

- The bats suite no longer inherits `NS_CMD` and `NS_NTFY_URL` from the caller, and a pytest unit suite covers the `nsyaml`, manifest and profile libraries (part of issue #37).

### Fixed

- `ns publish` checks the whole HTML file instead of single lines, so a tag split over several lines no longer slips past the self-containment check (issue #5, part 1; the Content-Security-Policy header is still to do).

## [0.1.1] - 2026-10-04

### Added

- `ns-notify` sends the ntfy bearer token (via curl stdin) and fails on a non-2xx answer; the Caddyfile template serves ntfy on `:8444`.

### Changed

- Nightshift's own profile protects workflow files, and CI is pinned to ubuntu-24.04 (issue #21).
- The build plan and specification cover usage monitoring and the self-hosted ntfy for Build B.

### Fixed

- `ns-conductor checks` writes `logs/<id>/<target>.checks.rc` with its exit code on every path, and the conductor prompts forbid `pgrep` wait loops that matched themselves and never ended (ns-x2).
- `ns-notify` sends text literally with `--data-raw`, so text starting with `@` is no longer read as a file (issue #7).
- `ns project add` adopts an existing clone only when its origin matches the repository name after a `/` or `:`, so `evilacme/widget` no longer matches `acme/widget` (issue #8).

## [0.1.0] - 2026-10-03

### Added

- Plugins and agents: the `ns` plugin with agents (triage, conductor, implementer, code-reviewer, integrator, planner, product-analyst, architect, test-architect, researcher, sec-compliance) and skills for running, planning, implementing, reviewing, resuming and reporting (`/ns:run`, `/ns:plan`, `/ns:implement`, `/ns:dod`, `/ns:status`, `/ns:resume`, `/ns:review`); the `ns-python` stack plugin with Python conventions, packaging and testing skills.
- The ns CLI and helpers: the `ns` dispatcher with `ns help`, `ns new`, `ns ls`, `ns status`, `ns attach`, `ns stop`, `ns project`, `ns profile`, `ns publish` and `ns approve`; the common bash library, the `nsyaml.py` YAML helper, `ns-launch` and `ns-conductor` (worker pool, branches, checks, review rounds, merge, gates, finish, pause).
- Profile and schema: the project profile schema, stack schema and ledger schema, `ns profile check` and `ns profile show`, a generated profile reference, example profiles and the Python CI template.
- Ledger and resume: the per-run ledger (`ns-ledger`) kept on `plan/<id>` for every tier (ADR 0002) and `ns resume`, which adopts detached workers (ADR 0008).
- Desk and notifications: `ns publish`, the desk index and `ns-notify`.
- Hooks: guard (fails open, ADR 0006), checkpoint and session-start hooks.
- Operations (drain, up, gc, doctor): `ns drain`, `ns up` with systemd unit templates, `ns gc` housekeeping with a timer, and `ns doctor`.
- ns-gh: the `ns-gh` wrapper around `gh` with repository name validation, tested against a gh stub.
- Bootstrap: `bootstrap.sh` with `--check`, the server setup steps, a Caddyfile template, release install under `/opt` and `--upgrade`.
- Tests and CI: bats suites in `tests/bats`, `tests/lint`, `tests/docs-check` (including `--final`) and a GitHub Actions workflow; stubs for `tmux`, `claude` and `gh`.
- End-to-end harness: `tests/e2e/run.sh` with scenarios t0, t1, t2, t3 and resume against `andras-tkcs/nightshift-sandbox`, run with `--keep` in Build A (ADR 0009); results in `tests/e2e/results.md`.
- Documentation: the specification, build plan, architecture, usage, ledger, conductor, agents, projects, accounts, server, operations, security, setup and development guides, and architecture decision records 0001 to 0009. The `v0.1.0` tag is set by the owner after merge (ADR 0007).

[Unreleased]: https://github.com/andras-tkcs/nightshift/compare/v0.1.10...HEAD
[0.1.10]: https://github.com/andras-tkcs/nightshift/compare/v0.1.9...v0.1.10
[0.1.9]: https://github.com/andras-tkcs/nightshift/compare/v0.1.8...v0.1.9
[0.1.8]: https://github.com/andras-tkcs/nightshift/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/andras-tkcs/nightshift/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/andras-tkcs/nightshift/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/andras-tkcs/nightshift/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/andras-tkcs/nightshift/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/andras-tkcs/nightshift/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/andras-tkcs/nightshift/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/andras-tkcs/nightshift/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/andras-tkcs/nightshift/releases/tag/v0.1.0
