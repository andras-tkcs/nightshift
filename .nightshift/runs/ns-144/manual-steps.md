# ns-144 manual steps

## Before implementation

None.

## After implementation

### ma1-apply-caddy-on-ns-main: rewrite the Caddyfile on ns-main and check the headers

Why: tests use stubs only; the real `/etc/caddy` is root's, and `bootstrap.sh --upgrade` does not rewrite the Caddyfile. Do this after the PR is merged, the release is tagged (`ns tag vX.Y.Z`) and installed with `/opt/nightshift/current/bin/bootstrap.sh --upgrade vX.Y.Z` ([docs/operations.md, "Updates"](../../../docs/operations.md#updates)). About 10 minutes.

- [ ] 1. As root on ns-main, compare the live Caddyfile with the new template: `diff <(sed "s/@TS_HOST@/$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')/g" /opt/nightshift/current/templates/caddy/Caddyfile.tmpl) /etc/caddy/Caddyfile`. Lines starting with `>` are your own hand edits (for example the CSP line added by hand for #5); the CSP and `@md` lines are now in the template.
- [ ] 2. For each hand edit that is not in the template (for example an extra site block), create `/etc/caddy/Caddyfile.d/` with `install -d -m 755 /etc/caddy/Caddyfile.d` and put the edit in a file such as `/etc/caddy/Caddyfile.d/local.caddy`. Skip this when there are none. Keep a backup: `cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak-$(date +%F)`.
- [ ] 3. Run `/opt/nightshift/current/bin/bootstrap.sh --check`. Expect `[1/11] Caddy and desk certificates: would change: update /etc/caddy/Caddyfile` (plus `create /etc/caddy/Caddyfile.d` if you skipped step 2), and `(local: local.caddy)` at the end if you made a snippet.
- [ ] 4. Run `/opt/nightshift/current/bin/bootstrap.sh` (no flags). It refuses while a job is live; wait or `ns drain` first ([docs/operations.md](../../../docs/operations.md#updates)). Expect `[1/11] ...: changed` and no `needs you`. If it says `needs you: systemctl failed`, run `caddy validate --config /etc/caddy/Caddyfile` and fix the snippet it names.
- [ ] 5. Check the tailnet listener: `curl -sI https://<ns-main>.<tailnet>.ts.net:8443/ | grep -i content-security`. Expect `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:`.
- [ ] 6. Check the tunnel listener: `curl -sI http://127.0.0.1:8080/ | grep -i content-security`. Same line expected.
- [ ] 7. Check Markdown: put a file there as `ns` (`echo '# hi' > /srv/ns-space/ns-144-test.md`), then `curl -sI http://127.0.0.1:8080/ns-144-test.md | grep -i content-type`. Expect `Content-Type: text/plain; charset=utf-8`. Remove the file afterwards.
- [ ] 8. Run `/opt/nightshift/current/bin/bootstrap.sh --check` again: step 1 says `ok` (with `(local: ...)` if you have snippets).

Report back in the PR: `ma1: pass` or `ma1: fail at step <n>: <what you saw>`.
