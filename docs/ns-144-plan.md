# ns-144: the desk sends a CSP header, serves Markdown as text, and keeps local Caddy additions

## Goal

Issue [#144](https://github.com/andras-tkcs/nightshift/issues/144) (closes #5, #26, #27). The desk's two HTML listeners (`:8443` on the tailnet and `http://127.0.0.1:8080` behind the tunnel) send a `Content-Security-Policy` header, so a page on the desk cannot run scripts or load anything from outside, even if it never went through `ns publish`. `*.md` files on those listeners are served as `text/plain; charset=utf-8` and never render as HTML. Owners put local Caddy additions in `/etc/caddy/Caddyfile.d/*.caddy`, which the rendered Caddyfile imports last and which `bootstrap.sh` creates, lists in `--check` and never touches, so a bootstrap rerun no longer wipes them. ADR 0010 records why both the header and the `ns publish` check exist.

Acceptance criteria: `.nightshift/runs/ns-144/acceptance.md` (AC-1 to AC-8). Design: `.nightshift/runs/ns-144/design.md`.

## Current state

- `templates/caddy/Caddyfile.tmpl` (27 lines) has four site blocks: `@TS_HOST@` (lines 1-6, SilverBullet), `@TS_HOST@:8443` (lines 8-15, `root * /srv/ns-space`, `file_server browse`, `header X-Robots-Tag "noindex"`), `@TS_HOST@:8444` (lines 17-22, ntfy) and `http://127.0.0.1:8080` (lines 24-27, `root`, `file_server browse`). No CSP, no Markdown rule, no `import`.
- `bin/bootstrap.sh`:
  - `render_caddyfile` (line 96) seds the host into the template.
  - `check_1` (lines 102-135) collects `todo` items (install caddy, write/update Caddyfile, `TS_PERMIT_CERT_UID`) and ends with `CHECK_MSG="ok"` (line 130) or `CHECK_MSG="would change: ..."` (line 133).
  - `apply_1` (lines 137-167) does `dir="$(P /etc/caddy)"; mkdir -p "$dir"` (lines 154-155) and ends with `systemctl reload caddy || systemctl restart caddy` (line 164), then renders `Caddyfile.new` and moves it into place.
  - `clean` (line 664) strips control characters; it is defined later in the file but only called at run time, so `check_1` can use it.
  - The step loop (lines 910-950, `elif check_"$n"` at line 914) prints `CHECK_MSG` as is in `--check` mode; in a real run, a step whose check returns 0 is skipped unless `CHECK_MSG` is exactly `ok (not configured)` or the step is 11. `--upgrade` runs only steps 8, 9, 10 (line 885), so it never rewrites the Caddyfile.
- `tests/bats/bootstrap.bats`: helpers `bootstrap`, `bootstrap_apply` (`NS_BS_TEST=1 RUNUSER_STUB_EXEC=1`), `snapshot`, `prepare_tree` (lines 52-80, `mkdir -p "$r/etc/caddy" ...`). Relevant cases: "--check on an empty tree reports each step and changes nothing" (line 82), "--check on a prepared tree prints eleven ok lines and exits 0" (line 96, counts lines matching `: ok`), "the rendered Caddyfile has the desk, the HTML listener and the tunnel listener" (line 250), "step 1 with failing systemctl reload and restart does not report changed" (line 308, shows `NS_BS_STEPS=1 run bootstrap_apply` works on an empty tree).
- ns-main has Caddy 2.6.2 at `/usr/bin/caddy`. The planner rendered the template with the design's lines added and `caddy adapt --adapter caddyfile --config <file>` succeeded as user `ns` (it only warns "No files matching import glob pattern" and "input is not formatted", both expected).
- Docs: `docs/setup.md` step 1 (line 68 and the manual block lines 70-82); `docs/security.md` "What lives where" table ending around line 34; `docs/adr/README.md` lists 0001-0009; `docs/architecture.html` lines 1860-1869 tell the owner to add the CSP header by hand; `docs/spec.md` line 279 describes bootstrap step 1; `docs/operations.md` "Updates" (line 90) describes `--upgrade`; `CHANGELOG.md` has an empty `## [Unreleased]` at line 8.
- `bin/lib/desk.sh` (`ns_desk_check_html`) stays unchanged (non-goal).

## Design

All decisions come from `RUN/design.md` and are not reopened here. This section spells them out exactly for the workers.

### D1. Caddy template

Insert these six lines (4-space indent, exactly as shown) in two places:

```
    header Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; img-src data:"
    @md path *.md
    header @md {
        Content-Type "text/plain; charset=utf-8"
        defer
    }
```

- In the `@TS_HOST@:8443` block: directly after the line `    header X-Robots-Tag "noindex"`, before the closing `}`.
- In the `http://127.0.0.1:8080` block: directly after the line `    file_server browse`, before the closing `}`.
- The `@TS_HOST@` (`:443`) and `@TS_HOST@:8444` blocks are unchanged.
- At the end of the file, after the `http://127.0.0.1:8080` block's closing `}`, add one blank line and then the line `import /etc/caddy/Caddyfile.d/*.caddy`, followed by a final newline. It must be the last non-blank line.

`defer` makes the header apply after `file_server` sets its own Content-Type. The CSP line stays immediate and applies to every response of the block, `browse` listings included.

### D2. `check_1`

In `bin/bootstrap.sh`, change `check_1` as follows:

1. Change its first line to `local todo=() host f d names="" suffix=""`.
2. After the `TS_PERMIT_CERT_UID` block (the `if ! grep -qs '^TS_PERMIT_CERT_UID=caddy$' "$f"; then ... fi`) and before `if [ "${#todo[@]}" -eq 0 ]; then`, insert:

```bash
  d="$(P /etc/caddy/Caddyfile.d)"
  if [ -e "$d" ] && [ ! -d "$d" ]; then
    CHECK_MSG="needs you: /etc/caddy/Caddyfile.d is not a directory"
    return 1
  fi
  if [ -d "$d" ] && [ ! -r "$d" ]; then
    CHECK_MSG="unknown: /etc/caddy/Caddyfile.d is not readable"
    return 1
  fi
  if [ ! -d "$d" ]; then
    todo+=("create /etc/caddy/Caddyfile.d")
  else
    # local additions are listed, never opened: names only, control characters dropped
    names="$(find "$d" -mindepth 1 -maxdepth 1 -name '*.caddy' -printf '%f\n' 2>/dev/null \
      | LC_ALL=C sort | while IFS= read -r x; do clean "$x"; printf ', '; done | sed 's/, $//')"
  fi
  [ -z "$names" ] || suffix=" (local: $names)"
```

3. Change `CHECK_MSG="ok"` (line 130) to `CHECK_MSG="ok$suffix"`.
4. Change the final `CHECK_MSG="would change: $(printf '%s, ' "${todo[@]}" | sed 's/, $//')"` to `CHECK_MSG="would change: $(printf '%s, ' "${todo[@]}" | sed 's/, $//')$suffix"`.

The variable `x` in the `while` loop runs in a subshell, so it needs no `local`. Example output on a prepared tree with one snippet: `[1/11] Caddy and desk certificates: ok (local: local.caddy)`. On an empty tree: `... would change: install caddy, write /etc/caddy/Caddyfile, set TS_PERMIT_CERT_UID=caddy, create /etc/caddy/Caddyfile.d` (the `install caddy` item depends on the host).

### D3. `apply_1`

In `apply_1`, directly after `mkdir -p "$dir"` (line 155) and before `render_caddyfile "$host" >"$dir/Caddyfile.new"`, insert:

```bash
  if [ -e "$dir/Caddyfile.d" ] && [ ! -d "$dir/Caddyfile.d" ]; then
    APPLY_MSG="needs you: /etc/caddy/Caddyfile.d is not a directory"
    return 1
  fi
  [ -d "$dir/Caddyfile.d" ] || install -d -m 755 "$dir/Caddyfile.d"
```

The guard is needed because the step loop skips `apply_1` only for `unknown*` check messages, so a `needs you` from `check_1` still reaches `apply_1`; without it, `install -d` would fail with a less clear message.

Nothing else touches `Caddyfile.d`: no `chmod`, `chown`, `rm`, write or copy into it, ever.

### D4. Tests in `tests/bats/bootstrap.bats`

- `prepare_tree`: add `"$r/etc/caddy/Caddyfile.d"` to its first `mkdir -p` list (keeps "eleven ok lines" green).
- "--check on an empty tree reports each step and changes nothing": add one line after the `for n in ...` loop: `printf '%s\n' "$output" | grep -E '^\[1/11\].*create /etc/caddy/Caddyfile\.d'`. Change nothing else in it.
- New cases, placed directly after "the rendered Caddyfile has the desk, the HTML listener and the tunnel listener" (do not change that case). Use these exact titles:
  1. `@test "the HTML listeners send the CSP header and serve Markdown as text, per block (#5, #27)"`: render with `sed 's/@TS_HOST@/ns-main.example.ts.net/g' "$NS_REPO_ROOT/templates/caddy/Caddyfile.tmpl" >"$out"`; cut each block with `awk '/^ns-main\.example\.ts\.net:8443 \{/,/^\}/' "$out"` and `awk '/^http:\/\/127\.0\.0\.1:8080 \{/,/^\}/' "$out"`; for each block, `[ -n "$block" ]` and `grep -F` for each of the three strings `header Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; img-src data:"`, `@md path *.md`, `Content-Type "text/plain; charset=utf-8"`. Then cut the `:443` block (`awk '/^ns-main\.example\.ts\.net \{/,/^\}/'`) and the `:8444` block (`awk '/^ns-main\.example\.ts\.net:8444 \{/,/^\}/'`), assert each is non-empty (`[ -n "$block" ]`) and contains neither string, with exactly this form (a `! grep` in the middle of a bats test passes vacuously, so do not use it): `[ "$(printf '%s\n' "$block" | grep -c -e 'Content-Security-Policy' -e '@md')" -eq 0 ]`.
  2. `@test "the Caddyfile template imports Caddyfile.d last (#26)"`: `[ "$(grep -v '^[[:space:]]*$' "$NS_REPO_ROOT/templates/caddy/Caddyfile.tmpl" | tail -n1)" = 'import /etc/caddy/Caddyfile.d/*.caddy' ]`.
  3. `@test "step 1 apply creates Caddyfile.d and a rerun keeps a local snippet byte-identical (#26)"`: `NS_BS_STEPS=1 run bootstrap_apply`, `assert_success`, `[ -d "$NS_BS_ROOT/etc/caddy/Caddyfile.d" ]`, `[ "$(stat -c %a "$NS_BS_ROOT/etc/caddy/Caddyfile.d")" = 755 ]`; write `printf 'localhost:9999 {\n    respond "hi"\n}\n' >"$NS_BS_ROOT/etc/caddy/Caddyfile.d/local.caddy"`, record `sum="$(sha256sum <"$NS_BS_ROOT/etc/caddy/Caddyfile.d/local.caddy")"`; run `NS_BS_STEPS=1 run bootstrap_apply` again and `assert_success`; then append `echo '# edited' >>"$NS_BS_ROOT/etc/caddy/Caddyfile"` so step 1 really applies, and run `NS_BS_STEPS=1 run bootstrap_apply` a third time, `assert_success`, `printf '%s\n' "$output" | grep -E '^\[1/11\].*changed'`. After each of the second and third applies assert exactly these three lines: `[ -f "$NS_BS_ROOT/etc/caddy/Caddyfile.d/local.caddy" ]`, `[ "$(sha256sum <"$NS_BS_ROOT/etc/caddy/Caddyfile.d/local.caddy")" = "$sum" ]` and `[ "$(ls -A "$NS_BS_ROOT/etc/caddy/Caddyfile.d")" = local.caddy ]`. Fallback, only if the first `NS_BS_STEPS=1 run bootstrap_apply` on the empty tree does not exit 0 because of the stubs (not because of D2/D3): start the case with `prepare_tree`, then `rmdir "$NS_BS_ROOT/etc/caddy/Caddyfile.d"`, then the first `NS_BS_STEPS=1 run bootstrap_apply`, and keep the rest of the case unchanged; say so in the report.
  4. `@test "--check lists local Caddy snippets on the step 1 line and changes nothing (#26)"`: `prepare_tree`; write `local.caddy` as in case 3; `before="$(snapshot)"`; `run bootstrap --check`; `assert_success`; `printf '%s\n' "$output" | grep -E '^\[1/11\].*: ok \(local: local\.caddy\)'`; `[ "$(snapshot)" = "$before" ]`.
  5. `@test "--check drops control characters from snippet names"`: `prepare_tree`; `: >"$NS_BS_ROOT/etc/caddy/Caddyfile.d/$(printf 'a\033b.caddy')"`; `run bootstrap --check`; `printf '%s\n' "$output" | grep -E '^\[1/11\].*\(local: ab\.caddy\)'`; `assert_output_not_contains "$(printf '\033')"` (helper in `tests/bats/helpers.bash:81`).
  6. `@test "--check says needs you when Caddyfile.d is not a directory"`: `prepare_tree`; `rmdir "$NS_BS_ROOT/etc/caddy/Caddyfile.d"`; `: >"$NS_BS_ROOT/etc/caddy/Caddyfile.d"`; `run bootstrap --check`; `assert_failure 1`; `printf '%s\n' "$output" | grep -E '^\[1/11\].*needs you: /etc/caddy/Caddyfile\.d is not a directory'`.
  7. `@test "step 1 apply says needs you when Caddyfile.d is not a directory"`: `mkdir -p "$NS_BS_ROOT/etc/caddy"`; `: >"$NS_BS_ROOT/etc/caddy/Caddyfile.d"`; `NS_BS_STEPS=1 run bootstrap_apply`; `assert_failure 1`; `printf '%s\n' "$output" | grep -E '^\[1/11\].*needs you: /etc/caddy/Caddyfile\.d is not a directory'`; `[ -f "$NS_BS_ROOT/etc/caddy/Caddyfile.d" ]`; `[ ! -e "$NS_BS_ROOT/etc/caddy/Caddyfile" ]`.

All new cases run only through the stubs and `NS_BS_ROOT` set by `setup()`, never as root, and never with the run's `$NS_LEDGER`.

### D5. ADR 0010

File `docs/adr/0010-desk-serves-self-contained-pages.md`, title `# 0010. The desk serves only self-contained pages`, sections `## Status` (`Accepted`), `## Context`, `## Decision`, `## Consequences`, the same shape as `docs/adr/0009-e2e-keep-in-build-a.md`. Content, in plain sentences:

- Context: spec R-DSK-2 (HTML reports are self-contained). The desk serves agent-written HTML from `/srv/ns-space` on `:8443` (tailnet) and `http://127.0.0.1:8080` (the tunnel, behind Cloudflare Access). Agent text is untrusted. Issues #5 (outside loads) and #27 (Markdown rendering). Owners need local Caddy additions that survive a bootstrap rerun (#26).
- Decision, four numbered points:
  1. The HTML listeners send `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:`. A page may use inline CSS and `data:` images only. It may not run scripts of any kind (inline or external), load anything from outside (styles, fonts, images, frames), post forms or fetch.
  2. `*.md` is served as `text/plain; charset=utf-8`, so Markdown never renders as HTML.
  3. `ns publish` (`ns_desk_check_html` in `bin/lib/desk.sh`) stays the first layer: it refuses a page before it reaches the desk and gives the agent a clear error. The header is the second layer: it catches what the deny-list misses and covers files written to `/srv/ns-space` without `ns publish`.
  4. Local additions go in `/etc/caddy/Caddyfile.d/*.caddy`, imported at the end of the rendered Caddyfile. `bootstrap.sh` creates the directory, lists the file names in `--check` and never writes, edits or deletes anything in it.
  - Not covered: `:443` (SilverBullet needs its own scripts) and `:8444` (ntfy).
  - Rejected alternatives (a bullet each): CSP only (no early feedback for the agent, and a header can be lost in a hand-edited Caddyfile); the check only (deny-lists miss things); a `<meta>` CSP in each page (every page must carry it, and a page without it is unprotected); bootstrap merging local edits into the main Caddyfile (hard to keep idempotent); `handle` blocks for `.md` (more lines, same effect).
- Consequences: `browse` listings lose their inline JavaScript (filter, local times) but still render. A broken local snippet makes `systemctl reload caddy` fail; `apply_1` then falls back to `systemctl restart caddy`, which also fails, so Caddy stays stopped (every desk listener is down) until the snippet is fixed, and step 1 reports `needs you: systemctl failed`. Check with `caddy validate --config /etc/caddy/Caddyfile` before adding a snippet. Snippets can add site blocks but cannot change the desk blocks. Needs Caddy 2.4 or newer for `header ... defer` (ns-main has 2.6.2).

### D6. Doc edits

- `docs/adr/README.md`: append the row `| [0010](0010-desk-serves-self-contained-pages.md) | The desk serves only self-contained pages | Accepted |`.
- `docs/security.md`: directly after the paragraph that starts `Nothing prints a token:` (the paragraph after the "What lives where" table), add a paragraph starting `The desk:` that says: the `:8443` and `http://127.0.0.1:8080` listeners send `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:` (no scripts, no outside loads); `*.md` is served as `text/plain`; `ns publish` refuses unsafe HTML first and the header is the second layer for anything it misses or that reached `/srv/ns-space` another way; SilverBullet on `:443` and ntfy on `:8444` do not get the header; link `[ADR 0010](adr/0010-desk-serves-self-contained-pages.md)`.
- `docs/setup.md` step 1 (line 68): extend the paragraph so it also says that the `:8443` and `:8080` listeners send the CSP header `default-src 'none'; style-src 'unsafe-inline'; img-src data:`, serve `*.md` as `text/plain`, and that the Caddyfile imports `/etc/caddy/Caddyfile.d/*.caddy` last: local additions go there, bootstrap creates the directory, lists the files in `--check` and never touches them. Link `[ADR 0010](adr/0010-desk-serves-self-contained-pages.md)`. In the manual block, add the line `install -d -m 755 /etc/caddy/Caddyfile.d` directly before the `sed "s/@TS_HOST@/...` line. After the block's sentence about `get_certificate tailscale`, add: `A snippet in Caddyfile.d with an error makes the reload fail, and bootstrap's restart fallback then leaves Caddy stopped until the snippet is fixed; check with caddy validate --config /etc/caddy/Caddyfile before systemctl reload caddy.` (with the two commands in backticks).
- `docs/operations.md` "Updates": after the paragraph at line 100 that starts ``It installs `/opt/nightshift/<tag>` if missing``, add a paragraph: `--upgrade` does not rewrite `/etc/caddy/Caddyfile`; when a release changes `templates/caddy/Caddyfile.tmpl` (the changelog says so), run `/opt/nightshift/current/bin/bootstrap.sh` once as root after the upgrade; it rewrites the Caddyfile and leaves `/etc/caddy/Caddyfile.d/*.caddy`, the place for local additions, untouched.
- `docs/spec.md` line 279 (bootstrap step 1): replace the final `.` of the line with: `; the two HTML listeners send the desk CSP header and serve *.md as text/plain (ADR 0010); the Caddyfile imports /etc/caddy/Caddyfile.d/*.caddy last for local additions, which bootstrap creates and lists but never changes.` (code spans as in the surrounding text).
- `docs/architecture.html` lines 1860-1869 (the `<h4 class="sub">Desk pages may not load anything from outside (issue #5)</h4>` subsection): keep the `<h4>`. Replace the `<p>` with: `<p>The Content-Security-Policy header and Markdown as text/plain are part of <code>templates/caddy/Caddyfile.tmpl</code> (issues #5 and #27, ADR 0010): a plain run of <code>bootstrap.sh</code> after the upgrade writes them. Not on SilverBullet (<code>:443</code>), which needs its own scripts. Local Caddy additions go in <code>/etc/caddy/Caddyfile.d/*.caddy</code>, which bootstrap never touches.</p>`. In the following `<div class="code"><pre>`, delete the comment line, the `nano` line, the commented `header` line and the `caddy validate` line, keeping only the two `curl -sI ... | grep -i content-security` lines. Replace the `<p class="note">` after it with `<p class="note"><code>bootstrap.sh --upgrade</code> leaves the Caddyfile alone; run <code>bootstrap.sh</code> once after an upgrade that changes the Caddy template.</p>`. Touch nothing else in the file.
- `CHANGELOG.md` under `## [Unreleased]`, add:

```
### Security

- The desk's HTML listeners (`:8443` and `http://127.0.0.1:8080`) send `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:`, so a desk page cannot run scripts or load anything from outside, also when it did not go through `ns publish`; directory listings lose their inline JavaScript. ADR 0010 (issue #5).
- `*.md` files on those listeners are served as `text/plain; charset=utf-8` and never render as HTML (issue #27).

### Added

- Local Caddy additions go in `/etc/caddy/Caddyfile.d/*.caddy`, imported at the end of the rendered Caddyfile. `bootstrap.sh` step 1 creates the directory, `--check` lists the snippet names (`ok (local: <names>)`), and a rerun never touches them. After installing this release, run `bootstrap.sh` once as root to rewrite the Caddyfile (`--upgrade` leaves it alone) (issue #26).
```

## ADRs

- ADR 0010 (`docs/adr/0010-desk-serves-self-contained-pages.md`, Accepted): the desk's HTML listeners send a strict CSP and serve Markdown as text, `ns publish` stays the first layer, and local Caddy additions live in `/etc/caddy/Caddyfile.d/`. Written in phase `p2-docs-retire` from D5.

## Manual steps

- `manual_before`: none.
- `manual_after`: `ma1-apply-caddy-on-ns-main`: after the owner tags and installs the release, move any hand edits from `/etc/caddy/Caddyfile` into `/etc/caddy/Caddyfile.d/`, run `bootstrap.sh` once as root so step 1 rewrites the Caddyfile, and check the headers with `curl`. Details in `.nightshift/runs/ns-144/manual-steps.md`.

## Risks and open questions

- Caddy syntax is not exercised by bats (acceptance assumption). Phase 1 runs `caddy adapt` on the rendered template with the Caddy 2.6.2 on ns-main as an extra mechanical check. If `caddy adapt` exits non-zero with an error (not a warning) about the inserted lines, the brief is wrong: stop with `status=blocked` and quote the error.
- Known leftover, out of this run's scope (the design names only the subsection around `docs/architecture.html:1861`): the historical hand-setup Caddyfile snippets in `docs/architecture.html` (the ntfy `cat >> /etc/caddy/Caddyfile` around lines 1907-1917 and the full Caddyfile around lines 2091-2109) do not show the CSP, `@md` or `import` lines. The template rendered by `bootstrap.sh` is the source of truth. p2 must not edit them.
- Existing `! ...` negations in the middle of `tests/bats/bootstrap.bats` cases (around lines 200, 201, 279) cannot fail; out of scope here (no weakening and no unrelated test edits), worth a follow-up issue.
- `defer` and the CSP on `browse` listings are intended (design); listings lose their inline JavaScript.
- If "--check on a prepared tree prints eleven ok lines and exits 0" fails after D2, the most likely cause is a missing `Caddyfile.d` in `prepare_tree`; fix only `prepare_tree`, never the assertion.
- Open owner questions, carried from the design and not part of this run: add `X-Content-Type-Options: nosniff` to the two HTML blocks? Should step 1 run `caddy validate` before reload to catch a bad snippet? Neither blocks the plan.

## Implementation manifest

```yaml
plan_slug: ns-144
feature_branch: feature/ns-144
max_parallel: 2
manual_before: []
manual_after:
  - id: ma1-apply-caddy-on-ns-main
    title: Rewrite the Caddyfile on ns-main with bootstrap.sh and check the CSP and text/plain headers
    why: The real Caddy and /etc/caddy are root-owned; tests only use stubs and --upgrade does not rewrite the Caddyfile
verify_after_merge:
  - "bats tests/bats/bootstrap.bats"
  - "tests/lint"
final_checks:
  - "docs/ns-144-plan.md is deleted"
  - "docs/adr/0010-desk-serves-self-contained-pages.md exists with Status Accepted and is listed in docs/adr/README.md"
  - "CHANGELOG.md has [Unreleased] entries for #5, #27 and #26"
  - "tests/docs-check --final exits 0"
phases:
  - id: p1-caddy-bootstrap
    title: CSP and Markdown rules in the Caddy template, Caddyfile.d import, bootstrap step 1 creates and lists it, bats cases
    depends_on: []
    complexity: S
    touches:
      - templates/caddy/Caddyfile.tmpl
      - bin/bootstrap.sh
      - tests/bats/bootstrap.bats
    brief: |
      Read docs/ns-144-plan.md, sections Design D1 to D4, and .nightshift/runs/ns-144/acceptance.md. Change only the three files in touches.
      1. templates/caddy/Caddyfile.tmpl: apply D1 exactly (the six lines in the :8443 block after the X-Robots-Tag line and in the http://127.0.0.1:8080 block after file_server browse; a blank line and `import /etc/caddy/Caddyfile.d/*.caddy` as the last line). Leave the :443 and :8444 blocks unchanged.
      2. bin/bootstrap.sh check_1: apply D2 steps 1 to 4 exactly. Use the existing helpers P and clean; do not add new helpers.
      3. bin/bootstrap.sh apply_1: apply D3 (the guard and the install line after `mkdir -p "$dir"`). Change nothing else in bootstrap.sh: not steps 2 to 11, not the step loop.
      4. tests/bats/bootstrap.bats: update prepare_tree and the empty-tree case as in D4, and add the seven new cases from D4 with their exact titles after the case "the rendered Caddyfile has the desk, the HTML listener and the tunnel listener". Do not change or weaken any existing assertion. Run tests only through the stubs (NS_BS_ROOT, NS_BS_TEST=1), never as root and never with $NS_LEDGER.
      5. Run `bats tests/bats/bootstrap.bats`, then `tests/lint`, then `bats --jobs "$(nproc)" tests/bats`.
      6. Run the caddy check: `t="$(mktemp -d)"; sed 's/@TS_HOST@/ns-main.example.ts.net/g' templates/caddy/Caddyfile.tmpl >"$t/Caddyfile"; caddy adapt --adapter caddyfile --config "$t/Caddyfile" >/dev/null; echo "rc=$?"; rm -rf "$t"`. Warnings "No files matching import glob pattern" and "input is not formatted" are expected. If `command -v caddy` finds nothing, write "caddy adapt: SKIP (caddy not installed)" in your report and go on.
      Stop conditions (stop with status=blocked and quote the output): caddy adapt prints an error and rc is not 0; an existing bootstrap.bats case other than the two named in D4 fails and the fix would need a change outside D2/D3; check_1 or apply_1 does not look like the plan's "Current state" describes (lines moved far, different variable names).
      No docs or CHANGELOG changes in this phase; phase p2 does them.
    acceptance:
      - "bats tests/bats/bootstrap.bats passes, including the seven new cases named in D4, \"--check on an empty tree reports each step and changes nothing\" and \"--check on a prepared tree prints eleven ok lines and exits 0\""
      - "grep -v '^[[:space:]]*$' templates/caddy/Caddyfile.tmpl | tail -n1 prints: import /etc/caddy/Caddyfile.d/*.caddy"
      - "grep -c \"header Content-Security-Policy \\\"default-src 'none'; style-src 'unsafe-inline'; img-src data:\\\"\" templates/caddy/Caddyfile.tmpl prints 2"
      - "grep -c 'Caddyfile.d' bin/bootstrap.sh is at least 4, and git diff on bin/bootstrap.sh changes only check_1 and apply_1"
      - "the caddy adapt command from brief step 6 prints rc=0 (or SKIP when caddy is not installed)"
      - "tests/lint exits 0"
      - "bats --jobs \"$(nproc)\" tests/bats passes"
  - id: p2-docs-retire
    title: ADR 0010, security, setup, operations, spec and architecture docs, changelog, delete the plan
    depends_on: [p1-caddy-bootstrap]
    complexity: M
    touches:
      - docs/adr/0010-desk-serves-self-contained-pages.md
      - docs/adr/README.md
      - docs/security.md
      - docs/setup.md
      - docs/operations.md
      - docs/spec.md
      - docs/architecture.html
      - CHANGELOG.md
      - docs/ns-144-plan.md
    brief: |
      Read docs/ns-144-plan.md sections D5 and D6 and .nightshift/runs/ns-144/acceptance.md (AC-7). Write in the plain, short-sentence style of the surrounding docs.
      1. Create docs/adr/0010-desk-serves-self-contained-pages.md from D5, in the shape of docs/adr/0009-e2e-keep-in-build-a.md (Status Accepted).
      2. docs/adr/README.md: append the 0010 row from D6.
      3. docs/security.md: add the "The desk:" paragraph from D6 with the link to adr/0010-desk-serves-self-contained-pages.md.
      4. docs/setup.md step 1: apply D6 (paragraph extension with the CSP header, Markdown as text/plain, /etc/caddy/Caddyfile.d/*.caddy for local additions bootstrap never touches; the install -d line in the manual block; the caddy validate sentence).
      5. docs/operations.md "Updates": add the paragraph from D6.
      6. docs/spec.md line 279: append the text from D6.
      7. docs/architecture.html: replace the subsection content as D6 says, touching only lines around 1860-1869.
      8. CHANGELOG.md: add the Security and Added entries from D6 under [Unreleased].
      9. Delete docs/ns-144-plan.md (git rm) as the last change.
      10. Run tests/docs-check --final, tests/lint and bats --jobs "$(nproc)" tests/bats.
      Stop condition (stop with status=blocked): docs/adr/0010-* already exists or another ADR already uses number 0010; the architecture.html subsection is not at about lines 1860-1869 or reads differently from D6's description.
      Do not change bin/, templates/ or tests/ in this phase.
    acceptance:
      - "test -f docs/adr/0010-desk-serves-self-contained-pages.md && grep -q '^Accepted' docs/adr/0010-desk-serves-self-contained-pages.md"
      - "grep -q \"default-src 'none'; style-src 'unsafe-inline'; img-src data:\" docs/adr/0010-desk-serves-self-contained-pages.md"
      - "grep -q '0010-desk-serves-self-contained-pages.md' docs/adr/README.md"
      - "grep -q 'Content-Security-Policy' docs/security.md && grep -q 'adr/0010-desk-serves-self-contained-pages.md' docs/security.md"
      - "grep -q 'Content-Security-Policy\\|CSP' docs/setup.md && grep -q 'text/plain' docs/setup.md && grep -q '/etc/caddy/Caddyfile.d/\\*.caddy' docs/setup.md"
      - "grep -c 'nano /etc/caddy/Caddyfile' docs/architecture.html prints 0"
      - "sed -n '/^## \\[Unreleased\\]/,/^## \\[0/p' CHANGELOG.md mentions #5, #27 and #26"
      - "test ! -e docs/ns-144-plan.md"
      - "tests/docs-check --final exits 0"
      - "tests/lint exits 0 and bats --jobs \"$(nproc)\" tests/bats passes"
```
