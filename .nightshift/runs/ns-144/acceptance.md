# Acceptance: ns-144 (issue #144, closes #5, #26, #27)

Goal: the desk's HTML listeners send a CSP header and serve `*.md` as plain text, and local Caddy additions in `/etc/caddy/Caddyfile.d/` survive a bootstrap rerun, with ADR 0010 and docs that match.

## Criteria

- AC-1 (#5) The rendered template (`sed 's/@TS_HOST@/ns-main.example.ts.net/g' templates/caddy/Caddyfile.tmpl`) contains `header Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; img-src data:"` (exact policy value) inside both the `ns-main.example.ts.net:8443 {` block and the `http://127.0.0.1:8080 {` block. Checked by a bats case in `tests/bats/bootstrap.bats` that inspects each block separately, not the file as a whole.
- AC-2 (#27) Both of those blocks define an `@md` matcher on `path *.md` and set `Content-Type "text/plain; charset=utf-8"` for it. Checked by the same or a sibling bats case, per block.
- AC-3 (#26) The last non-blank line of `templates/caddy/Caddyfile.tmpl` is `import /etc/caddy/Caddyfile.d/*.caddy`. Check: `grep -v '^[[:space:]]*$' templates/caddy/Caddyfile.tmpl | tail -n1` prints that line.
- AC-4 (#26) Step 1 apply creates `$NS_BS_ROOT/etc/caddy/Caddyfile.d`, and a second step 1 apply leaves a pre-existing `Caddyfile.d/local.caddy` byte-identical and present. Checked by a bats case using `NS_BS_STEPS=1 bootstrap_apply` twice through the existing stubs.
- AC-5 (#26) `bootstrap.sh --check` with a file `Caddyfile.d/local.caddy` prints the name `local.caddy` on the `[1/11]` line and changes nothing (the `snapshot` before and after are equal). Checked by a bats case.
- AC-6 Existing behaviour holds: `bats tests/bats/bootstrap.bats` passes in full, including "--check on a prepared tree prints eleven ok lines and exits 0" and "--check on an empty tree reports each step and changes nothing" (test helpers such as `prepare_tree` may be updated). All new tests run only through the stubs (`NS_BS_ROOT`, `NS_BS_TEST=1`), never as root.
- AC-7 `docs/adr/0010-*.md` exists with Status Accepted and covers what the desk may serve, why both the CSP header and the `ns publish` check exist, and what a page may not do (no scripts, no external loads); `docs/adr/README.md` lists 0010. `docs/security.md` names the CSP header and links ADR 0010; `docs/setup.md` step 1 mentions the CSP header, Markdown served as `text/plain`, and `/etc/caddy/Caddyfile.d/*.caddy` as the place for local additions that bootstrap never touches. Check: read the files; `tests/docs-check` exits 0.
- AC-8 `tests/lint` exits 0 (shellcheck clean) and `bats --jobs "$(nproc)" tests/bats` passes.

## Assumptions

- The exact Caddy directive spelling (for example `header @md Content-Type ...` vs a `handle` block) is free as long as AC-1 and AC-2 hold per block; tests check the policy string and the `@md` matcher, not formatting.
- The `--check` output format for the listing is free (for example `ok (local: local.caddy)`), as long as the file name is on the `[1/11]` line and step 1 still reports `ok` on a prepared tree. A missing `Caddyfile.d` may count as a step 1 change.
- Caddy accepts an `import` glob that matches no files; the real Caddy is not run in tests.

## Non-goals

- No CSP header and no Markdown change on the `:443` SilverBullet block or the `:8444` ntfy block.
- `ns_desk_check_html` in `bin/lib/desk.sh` (the `ns publish` check) stays unchanged.
- Bootstrap never writes, edits or deletes files inside `Caddyfile.d/`; no example snippet is shipped there.
- No real `bootstrap.sh` run as root and no change to steps 2 to 11.
