# ns-5 test strategy

Inputs: `acceptance.md` (AC-1..AC-8), `design.md`, `docs/ns-5-plan.md` (D-tests). Test framework: bats 1.13 (`tests/bats/`).

## Expected-failure marker (bats)

Bats has no xfail marker and `skip` would hide the test, so each acceptance call is wrapped in a strict expected-failure helper defined at the top of the test file (`tests/bats/helpers.bash` is "never edited afterwards", so the helper lives in `desk.bats` and `bootstrap.bats`):

```bash
ns_xfail "ns:ns-5 acceptance" refused '<img src="https://x">\n'
```

`ns_xfail` runs the command in a background subshell (`"$@" & wait "$!"`) so errexit stays on inside it; bats' own `run` turns errexit off, which would hide a failing `[ ]`. The case passes when the command fails, and fails with `XPASS (...)` when it succeeds (strict). Each `refused` call in the multi-call cases is wrapped on its own, so each one must fail today.

Removing the marker: the phase that implements a criterion deletes the `ns_xfail "ns:ns-5 acceptance" ` prefix from its lines in the same commit as the code (p1: `desk.bats`; p2: `bootstrap.bats`). Once no test uses `ns_xfail`, that phase deletes the helper too. `grep -n 'ns_xfail' tests/bats/*.bats` must print nothing after p2 and p1 are merged.

Already done on `plan/ns-5` (differs from the p1/p2 briefs): the `refused()`/`published()` helpers, every D-tests case and the bootstrap CSP case are committed. The CSP case body is the plan's text, moved into the function `csp_on_html_listeners_only` that the `@test` calls. p1 and p2 do not re-add them; p1 still changes the old message assertion at `desk.bats` ("HTML with an external script is refused") to the new D-message text, because changing it now would break an existing passing test.

## Pyramid

- Unit (1): `the filled handoff template passes the check` calls `ns_desk_check_html` directly.
- Integration (21 desk, 1 bootstrap): each desk case runs the real `ns publish` CLI against a temp desk and run worktree (exit code, message, file absent/present). The bootstrap case renders the real template and, where a real `caddy` is on PATH, runs `caddy adapt`.
- End to end (0): no sandbox flow changes; the publish path and Caddy rendering are fully covered locally. The CSP on the live server is a hand change already in place (plan, Manual steps).

Why mostly integration: the contract under test is the `ns publish` exit code, message and "nothing copied", which only the CLI path shows; each case is fast (temp dirs, no network).

## AC to test mapping

| AC | Proof | Kind | Marker now |
|---|---|---|---|
| AC-1 | `desk.bats`: `issue #5 bypass a: protocol-relative link href is refused`, `... b: script with src on the next line ...`, `... c: img with an https src ...`, `... d: inline script ...` (exit 1, full message, no desk copy). Negative check: p1 step 7 runs `bats -f 'issue #5 bypass'` with `origin/main`'s `desk.sh` and sees 4 failures | test + command | xfail |
| AC-2 | `desk.bats`: bypass b, `link with href on the next line is refused` | test | xfail |
| AC-3 | `desk.bats`: `uppercase SCRIPT is refused`, bypass d | test | xfail |
| AC-4 | `desk.bats`: `single-quoted protocol-relative src is refused`, `unquoted http src is refused`, bypass c | test | xfail |
| AC-5 | `desk.bats`: existing `HTML with an inline style only is published`; `inline style, a data: image and an a href link are published`; `prose with = and a bare URL is published`; `the filled handoff template passes the check` | test (regression guard) | none: they pass on today's code and must keep passing |
| AC-6 | `bootstrap.bats`: `the rendered Caddyfile sends the CSP on the HTML listeners only` (header in `:8443` and `:8080` blocks, absent from the bare-host block, count 2, `caddy adapt` exits 0 when a real caddy exists, else `skip` of that part) | test | xfail |
| AC-7 | Command: `tests/docs-check` exits 0 and `grep -n 'Content-Security-Policy' docs/spec.md` finds the R-DSK-2 line; plus the p3 manifest greps on `docs/usage.md`, `docs/setup.md` | command | n/a |
| AC-8 | Command: `tests/lint`, `env -u NS_NTFY_URL -u NS_CMD -u NS_PROJECT bats tests/bats`, `tests/docs-check` (and `--final` at the end) all exit 0 | command | n/a |

Design extras (no AC of their own, under the goal statement and design rules 1, 5, 7, 8, 9): `an onerror handler is refused`, `a remote CSS url() is refused`, `a quoted > does not end the tag early`, `a handler right after a closing quote is refused`, `a handler after a stray quote is refused`, `svg href and xlink:href are refused`, `srcset, meta refresh and javascript: are refused`, `a file with a NUL byte is refused`. All xfail now.

## Verification done

- With the markers: `bats tests/bats/desk.bats` reports 36 ok; the bootstrap CSP case reports ok.
- With the prefixes stripped (scratch copy), every xfail case fails for the right reason: `expected failure, got status 0` (the file is published today), and the CSP case fails on the first `:8443` header assertion. None errors.
- In a scratch copy with the plan's D-check function, D-message and D-csp lines applied and the markers stripped, all 36 desk cases and the CSP case pass, and the CSP case ran `caddy adapt` with `/usr/bin/caddy` (not skipped). So the tests are satisfiable by the planned code.

## Fixtures

None new. Cases build their HTML inline with `printf '%b'` through `refused`/`published`; the handoff case uses the checked-in `plugins/ns/skills/handoff-report/template.html`; the CSP case renders `templates/caddy/Caddyfile.tmpl` with a fixed host. Existing `setup()` (sbx-12 run, temp desk) and the caddy stub in `tests/fixtures/bootstrap/bin` are reused; the CSP case looks past the stub for a real caddy.

## Environment note

Run bats as `env -u NS_NTFY_URL -u NS_CMD -u NS_PROJECT bats ...`: a Nightshift session exports those variables and `ns_test_setup` does not unset them (pre-existing, 4 unrelated cases; see plan Risks).
