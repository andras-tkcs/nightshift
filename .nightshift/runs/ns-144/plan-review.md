# Plan review: docs/ns-144-plan.md

Reviewed: the working-tree `docs/ns-144-plan.md` on `plan/ns-144` (local ref `30dc7742f0b378380e4f38a9776618a4d5beae23`; Bash was not available, so I could not run `git fetch`, `git rev-parse origin/plan/ns-144` or any check, and the file may include uncommitted edits). Checked against: plan skill section 4 and "Sizing for Sonnet", the plan-manifest rules, RUN/acceptance.md, RUN/design.md, RUN/manual-steps.md, CLAUDE.md, `templates/caddy/Caddyfile.tmpl`, `bin/bootstrap.sh`, `tests/bats/bootstrap.bats`, `tests/bats/helpers.bash`, `tests/fixtures/bootstrap/bin/*`, `tests/docs-check` and the docs named in D6. No worker log was offered.

## Findings

1. **blocking** · docs/ns-144-plan.md:94 (D4 case 1) · The brief says the `:443` and `:8444` blocks must "contain neither `Content-Security-Policy` nor `@md`" but doesn't say how to check it. The natural way to write that is `! grep -q ... <<<"$block"` or `! printf '%s\n' "$block" | grep -q ...` in the middle of the test. That passes vacuously in bats: bash's `set -e` ignores a pipeline negated with `!`, so the non-goal guard could never fail. (The existing lines `bootstrap.bats:200`, `:201` and `:279` have the same flaw, so the worker will copy it. Lines `:260` and `:305`/`:312` only work because they are the last command.) The form should be spelled out so nothing is left open. · Prescribe a form that fails mid-test, for example `[ "$(printf '%s\n' "$block443" | grep -c -e 'Content-Security-Policy' -e '@md')" -eq 0 ]`. The command substitution's exit status is ignored, and `[ ]` does trigger errexit. Or use `output="$block443" assert_output_not_contains 'Content-Security-Policy'` with the existing helper in `tests/bats/helpers.bash:81`. Do the same for the `:8444` block.

2. **non-blocking** · docs/ns-144-plan.md:98 (D4 case 5) · `! printf '%s\n' "$output" | grep -q "$(printf '\033')"` only works because the plan lists it last. If the worker adds an assertion after it, or reorders, it passes vacuously for the reason in finding 1. · Replace it with `assert_output_not_contains "$(printf '\033')"`, or say explicitly that it must stay the last line of the case.

3. **non-blocking** · docs/ns-144-plan.md:96 (D4 case 3) · "`ls -A ...` prints only `local.caddy`" and "assert the file exists" are left to the worker to phrase. A `! ls ... | grep -v local.caddy` form would be vacuous. · Spell them out: `[ -f "$NS_BS_ROOT/etc/caddy/Caddyfile.d/local.caddy" ]` and `[ "$(ls -A "$NS_BS_ROOT/etc/caddy/Caddyfile.d")" = local.caddy ]`.

4. **non-blocking** · docs/ns-144-plan.md:13-17, :81 · Several line references don't match the code:
   - `render_caddyfile` is at `bin/bootstrap.sh:96`, not 95.
   - `check_1` runs from 102 to 135, not 134.
   - In `apply_1`, `dir="$(P /etc/caddy)"` and `mkdir -p "$dir"` are at lines 154-155, not 152-153, so D3's "(line 153)" should be 155.
   - The step loop is at lines 909-950, not 904-930. The skip `continue` is at 919, and design.md's "line 914" points at `elif check_"$n"`.

   All of these are close enough that p1's stop condition ("lines moved far") should not fire, but the plan should be exact. · Fix the numbers. In D3, anchor on the text `mkdir -p "$dir"` followed by `render_caddyfile "$host" >"$dir/Caddyfile.new"` (it is already named, so this is just the number).

5. **non-blocking** · docs/ns-144-plan.md:56-58, :84 (D2/D3) · Only `unknown*` messages skip apply in the step loop (`bootstrap.sh:927-933`). So in a real run, when `Caddyfile.d` is a regular file, `check_1` returns `needs you: ... is not a directory` and `apply_1` still runs. `install -d` then fails under the ERR trap, and the owner sees `needs you: install failed` instead of the clearer message. The Caddyfile is not rewritten, which is safe. No test covers the apply path. This is consistent with how the design specified D3, so it does not block. · Optionally, have D3 re-check like the tailscale case: `if [ -e "$dir/Caddyfile.d" ] && [ ! -d "$dir/Caddyfile.d" ]; then APPLY_MSG="needs you: /etc/caddy/Caddyfile.d is not a directory"; return 1; fi` before the `install -d` line. Or keep it and mention it in Risks.

6. **non-blocking** · docs/ns-144-plan.md:115 (D5 Consequences) · `apply_1` runs `systemctl reload caddy || systemctl restart caddy` (`bootstrap.sh:164`). With a broken snippet, the reload fails and the restart fallback stops Caddy and cannot start it again. So all desk listeners go down, not only the reload failing, and the new Caddyfile is already in place. The ADR, setup.md and manual-steps.md step 4 only say "the reload fails". · Add to the ADR's Consequences and the setup.md sentence that a bad snippet can leave Caddy stopped until it is fixed. Keep the existing pointer to `caddy validate` (already an owner open question).

7. **non-blocking** · docs/ns-144-plan.md:200-213 (p2 `complexity: S`) · p2 touches 9 files: one new ADR and 8 edits. "Sizing for Sonnet" defines S as up to about 3 source files. These are docs, not source, and each edit is small and fully dictated in D5/D6, so the phase is still mechanical. · Either mark it `M` or add a sentence in the plan saying the S count excludes docs.

8. **non-blocking** · docs/ns-144-plan.md:122 (D6 operations.md) · The anchor `It installs /opt/nightshift/<tag> if missing` does not match the text literally. `docs/operations.md:100` reads ``It installs `/opt/nightshift/<tag>` if missing``, with backticks, so a worker's `grep -F` would miss it. · Quote the anchor with the backticks, or say "the paragraph at line 100 that starts `It installs`".

9. **non-blocking** · docs/ns-144-plan.md:123 (D6 spec.md) · "append to the sentence: `; the two HTML listeners ...`". `docs/spec.md:279` ends with a period, so appending literally gives `....; the two ...`. · Say "replace the final `.` of line 279 with the text".

10. **non-blocking** · docs/ns-144-plan.md:124 (D6 architecture.html) · "Touch nothing else" leaves the hand-setup Caddyfile at `docs/architecture.html:2091-2109`, which has no CSP, no `@md` and no `:8080` block. It also leaves the ntfy `cat >> /etc/caddy/Caddyfile` at 1907-1917. After this change both contradict the template. The design only asked to fix "around line 1861", so this is scope, not an error. · Either add one `<p class="note">` near 2109 saying the template (rendered by `bootstrap.sh`) is the source of truth and adds the CSP and Markdown rules, or list it under Risks as a known leftover.

11. **non-blocking** · tests/bats/bootstrap.bats:200, :201, :279 (pre-existing, outside touches of intent) · These are existing negated pipelines in the middle of tests, so they can't fail. Out of scope for this plan, and p1's brief rightly forbids weakening tests. · Optionally, open a follow-up issue to convert them to `[ ... ]` or `assert_output_not_contains` forms.

## Checked and fine

- **D2 bash under `set -euo pipefail`:** `check_1` is always called as `elif check_"$n"` (`bootstrap.sh:914`), so errexit is off inside it. Even so, a failing `find` in the `names="$(...)"` pipeline only sets `$?`. `[ -z "$names" ] || suffix=...` is safe. `clean` (line 664) is defined before the loop runs and is inherited by the pipeline subshells. The `while` output has no newline, and GNU `sed 's/, $//'` handles a last line without one. `local todo=() host f d names="" suffix=""` is valid. The `\`-continued line ending before `| LC_ALL=C sort` is valid and shellcheck-clean.
- **D3 under the step loop's `set -Eeuo pipefail` subshell:** a failing `install -d` as the last element of `||` triggers errexit and the ERR trap. `install -m 755` is not affected by umask. The `stat` stub passes `-c %a` through to the real `stat`.
- **D4 cases 1, 3, 4, 6 and the empty-tree line:**
  - The positive `grep`/`[ ]` assertions all fail properly.
  - The awk ranges stop at the first column-0 `}`, so the indented `tls {...}` and `header @md {...}` don't end a block early.
  - The `caddy` and `tailscale` stubs make the empty-tree `NS_BS_STEPS=1` apply avoid apt.
  - In case 3, the second apply is skipped by the step loop (check is `ok (local: ...)`) and the third really runs `apply_1`, so AC-4 is covered both ways.
  - `prepare_tree` gets `Caddyfile.d`, so "eleven ok lines" stays green. "--check with a changed Caddyfile" still matches.
- **D1:** matches the design. `grep -c` gives 2 for the CSP line. The `import` line is last. `:443` and `:8444` are untouched.
- **Manifest:**
  - YAML escaping in the acceptance strings decodes to valid shell.
  - Ids are unique. `depends_on` is valid with no cycle.
  - p1 and p2 are serial, so there is no shared-touches conflict.
  - Complexity is S/S and `max_parallel` is 2.
  - The last phase depends on all others and is the retirement phase: ADR, docs, changelog, plan deletion.
  - The `ma1-...` id prefix is right and has `id/title/why`. `manual_before: []`.
  - No `model` is set, so `model_reason` is not needed. Validation passes.
- **Manual steps:** only `manual_after`. `ma1` really needs root on the live server and the real Caddy, and no CI workflow can do it. The checklist has expected output and a report line.
- **CLAUDE.md:** tests go only through stubs and `NS_BS_ROOT`, never use `$NS_LEDGER`, and never run as root. Both phases run the full bats suite, but serially, so at most one runs at a time.
- **ADR 0010:** the number is free (0001-0009 exist), it has the 0009 shape, and `^Accepted` matches the 0009 layout.
- **docs-check:** the new links (`adr/0010-...` from `docs/security.md` and `docs/setup.md`) will resolve once the ADR exists.
- **R-SEC-3:** nothing was copied from untrusted text. The policy string comes from the repo's own `architecture.html:1864` and design.md.

## Summary

The plan is well specified and almost entirely mechanical. The manifest validates, the D2/D3 bash is correct under `set -euo pipefail` and inside the step loop's errexit subshell, and the bats cases cover AC-1 to AC-6. One blocking issue: D4 case 1 leaves the negative "no CSP / no `@md` in `:443`/`:8444`" check unspecified, and the obvious `! grep` form passes vacuously in bats. Prescribe a `[ "$(... | grep -c ...)" -eq 0 ]` or `assert_output_not_contains` form, and tighten case 5 the same way. The rest are corrections and clarifications:
- line numbers off by 1-5
- the operations.md anchor and the spec.md period
- the apply-mode message for a non-directory `Caddyfile.d`
- the restart-fallback consequence of a bad snippet
- p2's S label
- the stale Caddyfile copies in architecture.html

REVIEW verdict=changes head=30dc7742f0b378380e4f38a9776618a4d5beae23

## Planner response

- 1, 2, 3: fixed. D4 now prescribes `[ "$(... | grep -c ...)" -eq 0 ]`, `assert_output_not_contains` and exact `[ ... ]` lines.
- 4: fixed, line numbers corrected.
- 5: fixed. D3 has a not-a-directory guard with `APPLY_MSG`, and a new bats case 7 covers the apply path.
- 6: fixed in the ADR consequences (D5), the setup.md sentence (D6) and manual-steps step 4.
- 7: p2 is now complexity M.
- 8, 9: fixed (operations.md anchor with backticks; spec.md replaces the final period).
- 10: listed under Risks as a known leftover; the design limits the architecture.html edit to the #5 subsection.
- 11: not changed, out of scope; listed under Risks as a follow-up.
