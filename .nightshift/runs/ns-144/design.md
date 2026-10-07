# Design: ns-144 (T2, lite)

## Modules touched

- `templates/caddy/Caddyfile.tmpl`: CSP and `@md` lines in the `:8443` and `http://127.0.0.1:8080` blocks only (AC-1, AC-2); `import` as the last line (AC-3). `:443` and `:8444` unchanged (non-goal).
- `bin/bootstrap.sh`: `check_1` and `apply_1` only (AC-4, AC-5). Steps 2 to 11 and the step loop unchanged.
- `tests/bats/bootstrap.bats`: `prepare_tree` plus new cases (AC-1 to AC-6).
- New `docs/adr/0010-desk-serves-self-contained-pages.md`, and edits to `docs/adr/README.md`, `docs/security.md`, `docs/setup.md` and `CHANGELOG.md` `[Unreleased]` (AC-7). Also fix `docs/architecture.html` around line 1861, which still says to add the CSP header by hand.
- `bin/lib/desk.sh` unchanged. Its comment at line 12 already points to the template.

## Interfaces

Caddy directives: the same three lines go in both HTML blocks, after `file_server browse` (and after `X-Robots-Tag` in `:8443`):
```
    header Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; img-src data:"
    @md path *.md
    header @md {
        Content-Type "text/plain; charset=utf-8"
        defer
    }
```
`defer` makes Caddy apply the header after `file_server` sets its own Content-Type, so it does not depend on whether `file_server` keeps an existing header. The CSP line stays immediate. Applying it to every response, including `browse` listings, is intended.
Last line of the file, after a blank line: `import /etc/caddy/Caddyfile.d/*.caddy`. Caddy only warns when the glob matches no files.

`check_1`: after the Caddyfile and tailscaled checks, `d="$(P /etc/caddy/Caddyfile.d)"`:
- `[ -e "$d" ] && [ ! -d "$d" ]` sets `CHECK_MSG="needs you: /etc/caddy/Caddyfile.d is not a directory"` and returns 1.
- `[ -d "$d" ] && [ ! -r "$d" ]` sets `unknown: /etc/caddy/Caddyfile.d is not readable` and returns 1.
- `[ ! -d "$d" ]` adds `todo+=("create /etc/caddy/Caddyfile.d")`.
- Otherwise list the names: `local=$(find "$d" -mindepth 1 -maxdepth 1 -name '*.caddy' -printf '%f\n' | LC_ALL=C sort | while IFS= read -r x; do clean "$x"; printf ', '; done | sed 's/, $//')`. `clean` is the existing helper at line 664. `find` follows the same rules as Caddy's glob, so symlinks are listed too. `check_1` only reads the directory and never opens a file in it.
- If `local` is non-empty, append ` (local: $local)` to the final message, both `ok` and `would change: ...`. For example: `[1/11] Caddy and desk certificates: ok (local: local.caddy)`. `ok` stays the prefix, so the prepared-tree test (`: ok`) and the step loop's `ok (not configured)` special case are unaffected.

`apply_1`: after `mkdir -p "$dir"` and before the Caddyfile is rendered, add `[ -d "$dir/Caddyfile.d" ] || install -d -m 755 "$dir/Caddyfile.d"`. The directory gets created before the `import` line goes live. It is never chmodded, chowned, emptied or written into. A second run with `check_1` ok skips `apply_1` entirely through the step loop (line 914). Even when it runs, it touches nothing inside the directory.

Test helper: `prepare_tree` adds `"$r/etc/caddy/Caddyfile.d"` to its `mkdir -p` list. Keeps "eleven ok lines" green (AC-6).
New bats cases (stubs only, `NS_BS_ROOT`):
1. A per-block CSP and `@md` case: render with the fixed host, cut each block out with `awk '/^ns-main.example.ts.net:8443 \{/,/^\}/'` (and the same for `^http:\/\/127\.0\.0\.1:8080 \{`), and `grep -F` the exact policy line, `@md path *.md` and `Content-Type "text/plain; charset=utf-8"` in each. Also assert `:443` and `:8444` blocks have no CSP (non-goal guard).
2. `import` is the last non-blank line (AC-3 command verbatim).
3. `NS_BS_STEPS=1 bootstrap_apply` creates `Caddyfile.d`. Write `local.caddy` and record its sha256. Apply again, then assert the file is present and the hash is equal (AC-4).
4. `prepare_tree`, add `local.caddy`, snapshot, `bootstrap --check`, `[1/11]` line contains `local.caddy` and `ok`, snapshot equal (AC-5).
5. Empty tree `--check`: `[1/11]` mentions `create /etc/caddy/Caddyfile.d` (existing "would change" assertion still holds).
Extend the existing "rendered Caddyfile has the desk..." case only if needed. Do not weaken it.

## Data

- New directory `/etc/caddy/Caddyfile.d/`, root:root 755. Bootstrap creates it and lists it. The owner owns its contents. No migration: on an existing server the next `bootstrap.sh` run reports `would change: update /etc/caddy/Caddyfile, create /etc/caddy/Caddyfile.d`.

## ADR 0010 outline (`0010-desk-serves-self-contained-pages.md`, Accepted)

- Context: R-DSK-2. The desk serves agent-written HTML from `/srv/ns-space` on `:8443` (tailnet) and `127.0.0.1:8080` (tunnel, Access). Agent text is untrusted. Issues #5 and #27. Owners need local Caddy additions that survive reruns (#26).
- Decision: (1) The HTML listeners send `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:`. Pages may use inline CSS and `data:` images only. No scripts of any kind, no external loads (styles, fonts, images, frames), no form posts or fetches. (2) `*.md` is served as `text/plain; charset=utf-8`, so Markdown never renders as HTML. (3) `ns publish` (`ns_desk_check_html`) stays as the first layer. It refuses a page before it reaches the desk and gives the agent a clear error. The header is the second layer. It catches what the deny-list misses and covers files written to `/srv/ns-space` without `ns publish`. (4) Local additions go in `/etc/caddy/Caddyfile.d/*.caddy`, imported last. Bootstrap creates the directory, lists it in `--check` and never touches its contents.
- Not covered: `:443` (SilverBullet needs its own scripts) and `:8444` (ntfy).
- Rejected: CSP only (no early feedback, and a header can be lost in a hand-edited Caddyfile). Check only (deny-lists miss things). A `<meta>` CSP (needs every page to carry it). Letting bootstrap merge local edits into the main Caddyfile (hard to keep idempotent). `handle` blocks for `.md` (more lines, same effect).
- Consequences: `browse` listings lose their inline JS (filter, local times) but still render. A broken local snippet makes `systemctl reload caddy` fail, and step 1 reports `needs you: systemctl failed`. Snippets can add site blocks but cannot change the desk blocks.

## Doc edits

- `docs/adr/README.md`: row `| 0010 (file 0010-desk-serves-self-contained-pages.md) | The desk serves only self-contained pages | Accepted |`.
- `docs/security.md`: after the "What lives where" paragraph at line 34, add a short "The desk" paragraph. It names the CSP header and its value, says `.md` is served as text/plain and that `ns publish` is the first layer, and links `adr/0010-desk-serves-self-contained-pages.md`.
- `docs/setup.md` step 1 (line 68): CSP header on `:8443` and `:8080`, Markdown as `text/plain`, and `/etc/caddy/Caddyfile.d/*.caddy` for local additions that bootstrap never touches. Add `install -d -m 755 /etc/caddy/Caddyfile.d` to the manual block, and a note that a bad snippet stops the reload.
- `CHANGELOG.md` `[Unreleased]`: one entry each for #5, #27 and #26.

## Risks

- Caddy `header` with `defer` syntax: needs Caddy 2.4 or newer. The current apt `caddy` is newer. Not exercised in tests, because the real Caddy is not run (acceptance assumption).
- Directory listings and any existing desk page that uses scripts stop running scripts. This is intended (R-DSK-2).
- `.md` as text/plain changes how the owner sees Markdown on `:8443` and `:8080`. SilverBullet on `:443` still renders it.
- Filenames in `--check` output come from a root-owned directory. `clean` strips control characters anyway.

## Rejected alternatives

- Writing a placeholder or example `local.caddy`: excluded by the non-goals.
- Failing `check_1` when snippets exist: the owner's additions are legitimate, so they are listed and not flagged.
- Validating snippets with `caddy validate` in `check_1`: it adds a dependency on the real binary in tests. Left as an open question.

## Open questions (owner)

- Add `X-Content-Type-Options: nosniff` on the two HTML blocks? It hardens the text/plain change, but no acceptance criterion asks for it. Not included.
- Should a later step-1 change run `caddy validate` before reload to catch a bad snippet? Not in this run.
