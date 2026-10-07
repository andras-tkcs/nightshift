# 0010. The desk serves only self-contained pages

## Status

Accepted

## Context

Spec R-DSK-2 says HTML reports are self-contained. The desk serves agent-written HTML from `/srv/ns-space` on `:8443` (tailnet) and `http://127.0.0.1:8080` (the tunnel, behind Cloudflare Access). Agent text is untrusted. Issue #5 asks for no outside loads. Issue #27 asks that Markdown never renders as HTML. Owners also need local Caddy additions that survive a bootstrap rerun (issue #26).

## Decision

1. The HTML listeners send `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:`. A page may use inline CSS and `data:` images only. It may not run scripts of any kind (inline or external), load anything from outside (styles, fonts, images, frames), post forms or fetch.
2. `*.md` is served as `text/plain; charset=utf-8`, so Markdown never renders as HTML.
3. `ns publish` (`ns_desk_check_html` in `bin/lib/desk.sh`) stays the first layer: it refuses a page before it reaches the desk and gives the agent a clear error. The header is the second layer: it catches what the deny-list misses and covers files written to `/srv/ns-space` without `ns publish`.
4. Local additions go in `/etc/caddy/Caddyfile.d/*.caddy`, imported at the end of the rendered Caddyfile. `bootstrap.sh` creates the directory, lists the file names in `--check` and never writes, edits or deletes anything in it.

Not covered: `:443` (SilverBullet needs its own scripts) and `:8444` (ntfy).

Rejected alternatives:

- CSP only: the agent gets no early feedback, and a hand-edited Caddyfile can lose the header.
- The check only: deny-lists miss things.
- A `<meta>` CSP in each page: every page must carry it, and a page without it is unprotected.
- Bootstrap merging local edits into the main Caddyfile: hard to keep idempotent.
- `handle` blocks for `.md`: more lines, same effect.

## Consequences

`browse` listings lose their inline JavaScript (filter, local times) but still render. A broken local snippet makes `systemctl reload caddy` fail; `apply_1` then falls back to `systemctl restart caddy`, which also fails, so Caddy stays stopped (every desk listener is down) until the snippet is fixed, and step 1 reports `needs you: systemctl failed`. Check with `caddy validate --config /etc/caddy/Caddyfile` before adding a snippet. Snippets can add site blocks but cannot change the desk blocks. Needs Caddy 2.4 or newer for `header ... defer` (ns-main has 2.6.2).
