## Summary

Desk content policy for Caddy (issues #5, #26, #27): the HTML listeners (`:8443`, `http://127.0.0.1:8080`) send a CSP header (`default-src 'none'; style-src 'unsafe-inline'; img-src data:`), serve `*.md` as `text/plain; charset=utf-8`, and the Caddyfile template ends with `import /etc/caddy/Caddyfile.d/*.caddy` for local additions. `bootstrap.sh` step 1 creates the directory and `--check` lists snippet names; it never touches their contents. ADR 0010 records the policy. T2, one review round per phase.

## Phases

| Phase | Merge commit | Content |
|---|---|---|
| p1-caddy-bootstrap | bc5fdc4 | Caddyfile template, `check_1`/`apply_1`, seven bats cases |
| p2-docs-retire | 1b04385 | ADR 0010, security, setup, operations, spec, architecture, changelog |

Feature head before the base merge: e15bbe7. Branch name is `feature/144` (the manifest says `feature/ns-144`).

## Checks

| Check | Result |
|---|---|
| `tests/lint` | PASS |
| `bats --jobs "$(nproc)" tests/bats` | PASS (853 ok, 0 not ok) |
| typecheck / audit | n/a (not in profile) |

The earlier kill.bats #58 timing flake on the feature merge checks was accepted by the owner and is handled in a separate job; it did not fail on the final run. Details: `RUN/dod.md` in the run files.

## Non-blocking findings and open items

- tests/bats/bootstrap.bats:90 (board-code): one assertion was added in the fix commit, not the test-first commit.
- tests/bats/bootstrap.bats:286-381 (board-code, board-acceptance): the seven new `@test` bodies are not indented.
- tests/bats/bootstrap.bats:416-427 (board-code): commit bc5fdc4 adds the tmux stub to the "failing apt-get" PATH of an existing case, outside D4 and without weakening an assertion; the trailing `! ... | grep` stays vacuous (also lines ~200, 201, 279).
- templates/caddy/Caddyfile.tmpl:15-20,33-38 (board-code): `.md` text/plain has no `nosniff`; left to the open owner question.
- docs/architecture.html (~1907-1917, ~2091-2109): historical hand-setup Caddyfile snippets lack CSP, `@md` and `import`.

## Follow-ups

- bootstrap.bats 'step 1 with a failing apt-get' fails on base 6a21abd on ns-main (pre-existing); kill.bats #58 timing test is flaky under load.

## Manual verification

- [ ] ma1-apply-caddy-on-ns-main: after merge, tag and `bootstrap.sh --upgrade`, as root on ns-main rewrite the Caddyfile and check the headers. Steps: compare the live Caddyfile with the template, move hand edits into `/etc/caddy/Caddyfile.d/local.caddy` (back up first), `bootstrap.sh --check` then `bootstrap.sh`, `curl -sI` the :8443 and 127.0.0.1:8080 listeners for the CSP line, check a `.md` file is `text/plain; charset=utf-8`, rerun `--check`. Full steps: `manual-steps.md` in the run files. Report `ma1: pass` or `ma1: fail at step <n>`.

## Stack

Base `main`; no other open run PR. `origin/main` was merged into the branch (df81e02); the only conflict was CHANGELOG.md [Unreleased], resolved by keeping both sides.

## Run report

`.nightshift/runs/ns-144/run-report.md` on branch `plan/ns-144` (`ns-conductor finish` publishes the final version).

## Desk link

The run's files are published on the desk by `ns-conductor finish` (handoff report, plan, acceptance, design, review boards).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
