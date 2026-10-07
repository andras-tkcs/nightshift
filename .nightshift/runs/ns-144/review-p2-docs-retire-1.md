# Review p2-docs-retire, round 1

Range: `origin/feature/144...origin/feature/144--p2-docs-retire` (one commit, 1b04385).

## Findings

- non-blocking · docs/setup.md:85 · "A snippet in Caddyfile.d" names the directory without a code span, while the paragraph above uses `/etc/caddy/Caddyfile.d/*.caddy`. The text matches D6 word for word, so this is style only · if you touch the line again, write `/etc/caddy/Caddyfile.d` as a code span.

No blocking findings.

## Summary

- D5: `docs/adr/0010-desk-content-policy.md` has the D5 title, the Status/Context/Decision/Consequences sections in the shape of ADR 0009, `Accepted`, the four decision points, the "not covered" note, the five rejected alternatives and the consequences, including the restart-fallback outage and Caddy 2.4+ for `defer`. The claims match the p1 code on the branch: the template has `@md`/`header ... defer` in both HTML blocks and `import /etc/caddy/Caddyfile.d/*.caddy` last, and `bootstrap.sh` prints `(local: <names>)`. R-DSK-2 exists in the spec.
- D6: the ADR README row, the security.md "The desk:" paragraph (placed after "Nothing prints a token:"), the setup.md step 1 extension, the `install -d` line before `sed`, the `caddy validate` sentence, the operations.md "Updates" paragraph after the "It installs" paragraph, the spec.md line 279 text, and the CHANGELOG Security and Added entries (issues #5, #27, #26) all match D6. architecture.html changes only the #5 subsection: the `<h4>` stays, the `<p>` is replaced, the code block keeps only the two `curl` lines, and the note is replaced. The historical Caddyfile snippets that the plan says p2 must leave alone are untouched.
- The plan is deleted as step 9 says, and no file on the branch still refers to `ns-144-plan`.
- Scope: only the nine files the manifest lists. There are no `bin/`, `templates/`, `tests/` or `.nightshift/` changes, and no secrets. Nothing was copied from untrusted text (R-SEC-3).
- I did not run the checks (docs-check, lint, bats) because the caller did not ask for them. The acceptance greps for this phase hold on the diff as read.

REVIEW verdict=approve head=1b04385b6f291bb893244f7558096a087087a425
