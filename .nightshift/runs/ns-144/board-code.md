# Review board (code): ns-144

Range: `git diff origin/main...origin/feature/144`, head `e15bbe7f025a252d9f350c62df4771e53ef76b22` (p1-caddy-bootstrap and p2-docs-retire merged). Judged against `docs/ns-144-plan.md` (plan/ns-144), `RUN/design.md`, `RUN/acceptance.md` and CLAUDE.md. No worker log was offered or read. kill.bats #58 flake ignored as instructed. Project checks were not run (not asked).

## Findings

- non-blocking · tests/bats/bootstrap.bats:90 · The empty-tree assertion `grep -E '^\[1/11\].*create /etc/caddy/Caddyfile\.d'` was added in the fix commit 43d03d1, not in the test-first commit 6a21abd, so it never failed first. The plan (D4) asks for this line and the behaviour is also covered by the AC-4 case, which did fail first, so this is not blocking. · In future runs, put every new assertion in the test-first commit.
- non-blocking · tests/bats/bootstrap.bats:286,296,323,339,352,366,381 · The new `@test` bodies are not indented (`csp_and_md_per_block` sits at column 0). This happened when the `ns_xfail` prefixes were removed. · Indent them two spaces like the other cases.
- non-blocking · tests/bats/bootstrap.bats:416-427 · Commit bc5fdc4 edits an existing case outside D4: it adds `tests/fixtures/bin/*` (the tmux stub) to the "failing apt-get" PATH. No assertion is weakened. The `bootstrap/bin` stubs are still linked last, so `systemctl` keeps its bootstrap stub. This makes the test more robust while a live run exists. The case's last `! printf ... | grep` is still a vacuous negation (already in the plan's Risks). · Mention it in the PR body. Open the follow-up issue for the vacuous `!` negations (lines ~200, 201, 279, 427).
- non-blocking · bin/bootstrap.sh:142 · `--check` lists snippet names even when it returns `would change`. That is intended (design D2). The `while` loop variable `x` is not declared `local`, which is fine because it runs in a subshell, as the plan says. · None.
- non-blocking · templates/caddy/Caddyfile.tmpl:15-20,33-38 · `.md` is served as `text/plain` without `X-Content-Type-Options: nosniff`. Browsers do not sniff `text/plain` up to HTML in practice, and the open owner question already covers this. · Leave it to the owner question. Do not change it in this run.
- non-blocking · docs/architecture.html (~1907-1917, ~2091-2109) · The historical hand-setup Caddyfile snippets still lack the CSP, `@md` and `import` lines. The plan records this as a known leftover that p2 must not touch. · Track it as a follow-up.
- non-blocking · (branch) · The manifest names `feature_branch: feature/ns-144`, but the run uses `feature/144` and `feature/144--<phase>`. · Make sure the PR and the manual step use the real branch name.

## Summary

- **Correctness:** The template, `check_1` and `apply_1` match plan D1 to D3 line for line.
  - The CSP and `@md`/`defer` rules are only in the `:8443` and `http://127.0.0.1:8080` blocks. `:443` and `:8444` are unchanged.
  - `import /etc/caddy/Caddyfile.d/*.caddy` is the last line.
  - `check_1` reports `needs you` for a non-directory and `unknown` for an unreadable directory. It adds `create` to the todo list and lists snippet names through `clean`, without opening any file.
  - `apply_1` guards against a non-directory before writing the Caddyfile and creates the directory with 755 only when it is missing. Nothing writes, chmods or deletes inside `Caddyfile.d`.
  - Steps 2 to 11 and the step loop are untouched.
- **Tests:** All seven D4 cases are in the test-first commit 6a21abd behind a strict `ns_xfail`. The fix commit removes only the prefixes and the helper. No existing assertion is weakened. The negative checks use the `grep -c ... -eq 0` form, not vacuous `!`.
- **Acceptance:**
  - AC-1 to AC-6 are each covered by a bats case.
  - AC-7: ADR 0010 is Accepted, covers what a page may serve and why there are two layers, and is listed in the ADR README. `security.md`, `setup.md`, `operations.md`, `spec.md`, `architecture.html` and the CHANGELOG `[Unreleased]` (#5, #27, #26) are updated as D5/D6 say. `docs/ns-144-plan.md` is absent at head.
  - AC-8 was not re-run by this reviewer.
- **Hygiene:**
  - No `.nightshift/` files on the feature branch.
  - No secrets.
  - Only files listed in the phase touches.
  - The cloudsmith URLs in `setup.md` and `bootstrap.sh` were already there, not copied from issue text.
  - No R-SEC-3 issue.

No blocking findings.

REVIEW verdict=approve head=e15bbe7f025a252d9f350c62df4771e53ef76b22
