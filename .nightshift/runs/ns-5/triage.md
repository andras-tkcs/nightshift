tier: T2
size_tier: T2
risk_floor: none
tags: [shell, caddy, security, bats]
budget_hours: 8
summary: Harden the review desk HTML self-containment check (multiline, URL and script rejection) and add a CSP header to the Caddy template, with bats cases

## Reasons

- Size signals: about 3 files (bin/lib/desk.sh, templates/caddy/Caddyfile.tmpl, tests/bats/desk.bats), plus a docs update if the desk docs describe the check (spec section 15). The check logic changes from line-based to multiline (grep -z) with several new rejection rules, and there is a new server-side behaviour (a CSP header on :8443 and :8080). That is more than a T1 small fix.
- Risk zones: none of the profile's zones match. Their paths are plugins/ns/hooks/** (hooks) and bin/lib/config.sh and bin/ns-launch (credentials). protected_paths (.github/workflows/**) are not touched. No platform_paths are declared, so no platform floor applies.
- Risk floor is none by the profile. The issue is security-flavoured (a bypass of a self-containment check), but it does not clearly alter a declared invariant or open a new trust boundary. The CSP is defence in depth on an existing boundary. The implementer should still run the ns:secure-code-review checklist.
- The profile has no budgets and no specialists section, so budget_hours uses the rubric default for T2 (8 hours) and no specialist tags are added.
- Owner set tier T2 (tier_source owner). Triage independently agrees: tier = max(T2, none) = T2.
- Watch for: a stricter check may reject legitimate existing desk pages, so existing templates and fixtures need checking. A CSP that is too strict could break the desk pages' inline styles.
