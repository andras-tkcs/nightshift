tier: T2
size_tier: T2
risk_floor: none
tags: [bash, caddy, docs, adr]
budget_hours: 8
summary: Add CSP header and Markdown-as-text/plain to the Caddy template, import Caddyfile.d snippets (bootstrap and --check), new ADR 0010, docs and bats tests

## Reasons
- Size: about 7 to 9 files across templates/caddy/Caddyfile.tmpl, the bootstrap script, tests/bats/bootstrap.bats, a new ADR 0010, docs/security.md and docs/setup.md. Three related items (#5, #26, #27).
- New public surface: the Caddyfile.d drop-in directory, a changed bootstrap step 1 and a new `--check` listing. Docs must change with it, and a new ADR is needed.
- Risk: no risk_zones path matched. The profile lists only plugins/ns/hooks/** and bin/lib/config.sh and bin/ns-launch. No platform_paths are declared. Floor is none.
- Not T1 because it spans modules and docs, adds a new surface and needs an ADR.
- Not T3 because there is no new trust boundary and no unknown scope. The CSP tightens an existing web surface.
- The profile has no `budgets` section, so the rubric default of 8 hours for T2 applies. The profile lists no specialists.
- Advisory: the CSP and the security.md claims are security-relevant. Reviewers should apply ns:secure-code-review even though no floor fires.
- Used 2 tool calls.
