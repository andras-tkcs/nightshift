# ns-144 test strategy

Inputs: `acceptance.md` (AC-1..AC-8), `design.md`, `docs/ns-144-plan.md` (D1-D4). Test framework: bats 1.13 (`tests/bats/`).

## Expected-failure marker (bats)

Bats has no xfail marker, and `skip` would hide the test. This run reuses the convention from `plan/ns-5` (`test-strategy.md` there): a strict wrapper `ns_xfail` defined in `tests/bats/bootstrap.bats` (`helpers.bash` stays unchanged). Each acceptance case body is a function, and the `@test` calls it as:

```bash
ns_xfail "ns:ns-144 acceptance" csp_and_md_per_block
```

`ns_xfail` runs the function in a background subshell (`"$@" & wait "$!"`), so errexit stays on inside it. The case passes when the function fails. It fails with `XPASS (ns:ns-144 acceptance): ...` when the function succeeds (strict).

## What is already on plan/ns-144 (differs from the p1 brief)

The seven D4 cases are committed with their exact D4 titles, placed directly after "the rendered Caddyfile has the desk, the HTML listener and the tunnel listener". The `prepare_tree` line from D4 (`"$r/etc/caddy/Caddyfile.d"` in the `mkdir -p` list) is also committed. It is harmless on today's code because `check_1` ignores the directory. Phase p1 must **not** add these cases again, because duplicate titles break bats. p1 instead:

1. Implements D1-D3.
2. In the same commit, deletes every `ns_xfail "ns:ns-144 acceptance" ` prefix (leaving the plain function call), then deletes the `ns_xfail` helper and its comment. Inlining the function bodies into the `@test` is allowed if no assertion changes. Check: `grep -n 'ns_xfail' tests/bats/*.bats` prints nothing.
3. Still adds the D4 line to the existing case "--check on an empty tree reports each step and changes nothing": `printf '%s\n' "$output" | grep -E '^\[1/11\].*create /etc/caddy/Caddyfile\.d'`. It is not added now, so that an existing passing case is left untouched.

## Pyramid

- Unit (2): template-only checks with no subprocess beyond `sed`/`awk`/`grep`. These are the per-block CSP and `@md` case (AC-1, AC-2, plus the non-goal guard for `:443`/`:8444`) and the "import last" case (AC-3).
- Integration (5): each runs the real `bin/bootstrap.sh` against a temp `NS_BS_ROOT` with the fixture stubs (`tests/fixtures/bootstrap/bin`, `NS_BS_TEST=1`, never root, never `$NS_LEDGER`). They cover apply idempotence for a local snippet (AC-4), `--check` listing without side effects (AC-5), control-character cleaning in names, and `needs you` on a non-directory `Caddyfile.d` in both check and apply.
- End to end (0): the real Caddy and `/etc/caddy` are root-owned, and the acceptance criteria assume Caddy is not run in tests. The live header check is manual step `ma1-apply-caddy-on-ns-main` (curl). p1 also runs `caddy adapt` on the rendered template as a mechanical check (plan brief step 6).

## AC to test mapping

| AC | Proof | Kind | Marker now |
|---|---|---|---|
| AC-1 | `bootstrap.bats`: `the HTML listeners send the CSP header and serve Markdown as text, per block (#5, #27)`. It cuts the `ns-main.example.ts.net:8443 {` and `http://127.0.0.1:8080 {` blocks separately and `grep -F`s the exact policy line in each | test | xfail |
| AC-2 | Same case: `@md path *.md` and `Content-Type "text/plain; charset=utf-8"` per block | test | xfail |
| AC-3 | `the Caddyfile template imports Caddyfile.d last (#26)` (the AC's command verbatim, as an `[ = ]`) | test + command | xfail |
| AC-4 | `step 1 apply creates Caddyfile.d and a rerun keeps a local snippet byte-identical (#26)`: the directory is created with mode 755. The sha256 of `local.caddy` and the directory listing are unchanged after a skipped second apply, and after a third apply that really rewrites the Caddyfile (`changed`) | test | xfail |
| AC-5 | `--check lists local Caddy snippets on the step 1 line and changes nothing (#26)`: `[1/11] ...: ok (local: local.caddy)` and `snapshot` equal | test | xfail |
| AC-6 | Existing cases "--check on a prepared tree prints eleven ok lines and exits 0" and "--check on an empty tree reports each step and changes nothing" (plus the line p1 adds), and the whole of `bats tests/bats/bootstrap.bats`. Every new case uses `setup()`'s `NS_BS_ROOT` and stubs | test (regression) + command | none |
| AC-7 | Commands: the p2 manifest greps (ADR 0010 Status Accepted and the policy string, README row, `docs/security.md` CSP and link, `docs/setup.md` CSP/`text/plain`/`Caddyfile.d/*.caddy`), a reviewer reading the ADR for "what may be served, why both layers, no scripts, no external loads", and `tests/docs-check` exits 0 (`--final` at the end) | command + review | n/a |
| AC-8 | Commands: `tests/lint` exits 0 and `bats --jobs "$(nproc)" tests/bats` passes | command | n/a |

Design extras (no AC of their own; design `check_1`/`apply_1` rules and the `clean` risk): `--check drops control characters from snippet names`, `--check says needs you when Caddyfile.d is not a directory`, `step 1 apply says needs you when Caddyfile.d is not a directory`. All are xfail now.

No AC lacks a test or command.

## Verification done

- On plan/ns-144 with the markers in place, all seven new cases report `ok` (expected failure), and none errors at collection. `tests/lint` exits 0.
- With the prefixes stripped (scratch worktree, current code), each case fails on the assertion about the missing behaviour. CSP: the first policy `grep -F`. Import: the last-line comparison. AC-4: `[ -d Caddyfile.d ]` after a successful apply. AC-5: the `ok (local: local.caddy)` grep. Cleaning: the `(local: ab.caddy)` grep. Check and apply non-directory: `assert_failure` (status 0 today).
- With D1-D3 applied verbatim in a scratch worktree (never committed) and the prefixes stripped, all seven new cases pass, and so do both prepared-tree and empty-tree cases. With the markers kept, all seven report `XPASS`, so the markers are strict.

## Fixtures

None new on disk. The snippet text `localhost:9999 { respond "hi" }` is the variable `LOCAL_SNIPPET` in `bootstrap.bats`. The cases reuse `setup()`, `prepare_tree`, `snapshot`, `bootstrap`/`bootstrap_apply` and the stubs in `tests/fixtures/bootstrap/bin`. The template is rendered with the fixed host `ns-main.example.ts.net`.

## Environment notes

- Run bats as `env -u NS_NTFY_URL -u NS_CMD -u NS_PROJECT bats ...` inside a Nightshift session (pre-existing, see `plan/ns-5`).
- Pre-existing failure here, not caused by this commit: "step 1 with a failing apt-get does not report changed and exits non-zero" fails on unchanged HEAD when run inside a live Nightshift run. The live-job guard sees this run, and `bootstrap.sh` refuses with "refusing to change the install while jobs are live ... ns-144". It should pass where no run is live (CI). Workers should not treat it as a regression from p1.
- `plan/ns-5` (unmerged) defines its own `ns_xfail` and a CSP case in `bootstrap.bats`. If that branch is ever revived, it overlaps with this run (#5).
