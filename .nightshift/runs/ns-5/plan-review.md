# ns-5 plan review

Reviewed: `docs/ns-5-plan.md` against `plugins/ns/skills/plan/SKILL.md`, `plugins/ns/skills/plan-manifest/SKILL.md`, `RUN/acceptance.md`, `RUN/design.md`, `CLAUDE.md`, `docs/adr/README.md`, `.claude/project-profile.yaml` and the code at `150b655`. No worker log was given.

How I checked: I copied the D-check function into `/tmp/ns5r` and ran it against every D-tests case plus extra probes. I shellchecked it with `--shell=bash`. I ran the real `/usr/bin/caddy adapt` on the rendered template with the two CSP lines, and ran the bootstrap test's `awk`/`grep` block logic on its own. I parsed the manifest with PyYAML. I did not run any bats suite.

## Findings

1. **blocking** · plan "Design / D-check", line 34 (`tag=`), used by rules 5 and 8 · **The regex can be bypassed in a way the design did not accept.** The tag-body pattern `([^>"']|"[^"]*"|'[^']*')*` always takes a quoted value whole, closing quote included. So when the next attribute follows a closing quote with no space, nothing is left to match the separator class `[[:space:]/"']`. Browsers treat that as a new attribute: it is a "missing-whitespace-between-attributes" parse error, and the name is still read. A stray quote inside an unquoted value, or a `="` before an attribute name, also stops any match. All of these return 0 (published) with the function exactly as written:
   - `<img src="data:x"onerror=fetch(1)>`
   - `<img src=data:x title=a"b onerror=fetch(1)>`
   - `<svg><image title=a"b href=//x></svg>`
   - `<img src=data:x =" onerror=fetch(1)>`

   Design rule 8 says an event handler is refused when "preceded by whitespace, `/` or a quote", and its accepted-evasion list (tab inside a scheme, CSS escapes, `poster`/`data`/`action`/`formaction`) does not cover this. The CSP would still block it, but the brief forbids the worker from changing patterns, so the fix has to be made in the plan.

   **Fix:** let the single-character unit also take quotes: `tag='([^>]|"[^"]*"|'\''[^'\'']*'\'')*'`. Matching is existential, so a quoted `>` still parses through the quoted unit. The deny-list only grows: I checked that every D-tests case keeps its expected result, the filled handoff template still passes, the function stays shellcheck clean, and a 470 KB adversarial file of unbalanced quotes runs in 0.03 s. Add `refused '<img src="data:image/png;base64,AA=="onerror="fetch(1)">\n'` and `refused '<img src=data:x title=a"b onerror=fetch(1)>\n'` to the D-tests table.

2. **blocking** · plan "Design / D-tests", bootstrap.bats case lines 166-170; "Manual steps" line 214; p2 brief step 4 and acceptance 1 · **The `caddy adapt` check in the bats case always passes.** `tests/bats/bootstrap.bats` `setup()` puts `tests/fixtures/bootstrap/bin` first on `PATH`, and that directory has a `caddy` stub that logs its arguments and always exits 0 (`tests/fixtures/bootstrap/bin/caddy`). So `command -v caddy` always finds the stub, the case never skips, and it never runs the real caddy. The plan states the opposite twice: "`caddy adapt` runs in the bats case on ns-main, so no human check is needed", and "it must report ok, not skip". p2's acceptance item 4 does run the real caddy on a `/tmp` render, so AC-6 is still met by a command. The bats case and its stated rationale are still wrong.

   **Fix:** in the case, look for a caddy outside the fixture tree and skip if there is none, for example:

   ```bash
   real=""
   for c in $(type -ap caddy); do
     case "$c" in "$NS_REPO_ROOT"/*) ;; *) real="$c"; break ;; esac
   done
   [ -n "$real" ] || skip "caddy not installed"
   run "$real" adapt ...
   ```

   Then correct the "Manual steps" sentence and p2 step 4. I ran the real `/usr/bin/caddy adapt` on the rendered template with both CSP lines: it exits 0 and prints only the usual "not formatted" warning.

3. non-blocking · plan "Design / D-tests", row `a quoted > does not end the tag early` · **This test does not exercise the quoted-`>` handling.** Its input is `<link title=">" href=//x>`, and rule 3 refuses any `<link` before the tag-body logic matters, so the case passes whatever `$tag` does. **Fix:** use a tag that only rule 5 can catch: `refused '<svg><image title=">" href=//x/></svg>\n'`. It is refused both with the plan's regex and with the fix in finding 1.

4. non-blocking · plan "Design / D-check", rule 7 (`url\(...`) · **The `url(` rule has no `&` alternative, though the `src`/`href` value test (`$remote`) does.** So `<p style="background:url(&#104;ttps://x)">` is published: the browser decodes entities in attribute values before the CSS parser sees them. The CSP (`img-src data:`) blocks the load, and the design's rule 7 lists only `http:`, `https:` and `//`, so this is a gap in the defence rather than a broken contract. **Fix:** add `|&` to the rule 7 alternatives for consistency, or list entity-encoded `url(` with the evasions in D-docs/R-DSK-2 that are left to the CSP.

5. non-blocking · plan "Risks and open questions" · **This run's own gate-2 handoff page will probably be refused.** Rules 4 (`src=` remote, not tied to a tag), 7 (`url(`), 9 (`javascript:`) and `@import` match escaped prose as well as markup. The ns-5 `RUN/handoff.html` will almost certainly describe these bypasses, and `handoff-report/SKILL.md:9` only tells the filler to escape `&`, `<` and `>`. If it is refused, the gate-2 publish fails. **Fix:** add a risk line telling the gate-2 filler to put such strings in `<code>` with `:` → `&#58;`, `@` → `&#64;` and `(` → `&#40;`. Optionally add the same sentence to `handoff-report/SKILL.md` in p3's touches.

6. non-blocking · plan "Implementation manifest", `verify_after_merge`/`final_checks`, and AC-8 · **AC-8 says `bats tests/bats` exits 0, but the plan only ever runs it as `env -u NS_NTFY_URL bats ...`.** I confirmed `NS_NTFY_URL` is set in this session environment and is not in `helpers.bash`'s `unset` list (line 19-20). The workaround is reasonable, and `helpers.bash` says it is never edited, so the AC holds in CI. But the leak is a real pre-existing bug. **Fix:** name it in the hand-back note and file a follow-up issue to add `NS_NTFY_URL` to the `unset` in `helpers.bash`, so the owner knows AC-8 is met only with this caveat on ns-main.

7. non-blocking · plan "Design / D-tests", bootstrap case line 164 · **The "absent from the bare-host block" assertion would pass without checking anything if the header line did not match.** If `block 'ns-main.example.ts.net {'` matched nothing, `grep -c` would print 0 and the assertion would pass. Today it extracts 6 lines, which I checked. **Fix:** also assert `[ "$(block 'ns-main.example.ts.net {' | grep -c reverse_proxy)" -eq 1 ]`.

## Checked and fine

- Manifest: PyYAML parses it. Ids are unique and follow `p<n>-<kebab>`. The `depends_on` ids exist and there is no cycle. p1 and p2 run in the same wave and their `touches` do not overlap. p3 depends on both and is the retirement phase (ADR, docs, changelog, `git rm` of the plan). Every phase has a brief and acceptance and is complexity S. `max_parallel: 2`, and two bats-running workers is within CLAUDE.md's limit. No `manual_*` items, so no `RUN/manual-steps.md` is needed.
- Briefs: numbered, name files and line numbers, have stop conditions (code drift, ADR collision, pattern failure, docs text not found) and no open choices. The gate-1 defaults (D1-D3) are spelled out.
- Acceptance coverage:
  - AC-1: four "issue #5 bypass" cases, plus the negative check against `origin/main` in step 7.
  - AC-2: next-line `<script` and `<link` cases.
  - AC-3: `<SCRIPT>` case.
  - AC-4: `src='//x'` and unquoted `src=http://x` cases.
  - AC-5: the published cases and the handoff template test. I checked that the template passes.
  - AC-6: the template lines and test. With finding 2 fixed, the bats case also checks it.
  - AC-7: spec, usage, setup, review-desk and architecture text.
  - AC-8: the lint, bats and docs-check commands (see finding 6).
- Every quoted current text matches the code: `bin/lib/desk.sh:10-16`, `ns-publish.sh:58`, `desk.bats:64`, `bootstrap.bats:246-255`, `spec.md:222`, `usage.md:171`, `review-desk/SKILL.md:29`, `setup.md:68`, `architecture.html:1861/1869`, and the empty `## [Unreleased]` in CHANGELOG.md. ADR 0010 is the next free number, and the section layout of 0006 matches the brief.
- No accepted ADR or profile setting is contradicted. No risk zone or protected path is touched.
- R-SEC-3: the issue's bypass strings appear only as test data. No command or URL from untrusted text goes into code, scripts or docs as an instruction.
- The planned CSP block test logic is correct apart from findings 2 and 7. The real `caddy adapt` accepts the header, and the `awk` block extraction gives 1/1/0/2 as intended.

## Summary

The plan is well structured, its manifest is valid, and it covers AC-1..AC-8. There are two blocking problems. First, the D-check tag-body regex lets an event handler or `href` through when it directly follows a closing quote or a stray quote (`<img src="data:x"onerror=fetch(1)>`). Design rule 8 explicitly covers this case, and a one-character-class change fixes it. Second, the bootstrap bats case's `caddy adapt` always runs the fixture stub, so it proves nothing, and the plan's "no manual step needed" reasoning relies on it. Fix both in the Design and add the matching test cases. The rest are improvements.

REVIEW verdict=changes
