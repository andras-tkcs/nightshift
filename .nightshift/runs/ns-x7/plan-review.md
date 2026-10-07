# Plan review: ns-x7

Reviewed `docs/ns-x7-plan.md` on `plan/ns-x7` (working tree at 4a4ad99f11581e837901835844a9197c4fb7fdc4). I checked it against the `plan` and `plan-manifest` skills, `RUN/acceptance.md`, `RUN/design.md`, CLAUDE.md, `.claude/project-profile.yaml`, `docs/adr/` and the code it cites. No worker log or reasoning was offered.

1. **blocking** · manifest `p2-guard-skill` `depends_on: []` · p1 and p2 run in the same wave, but p2 writes `ns-conductor owner-notes` into `plugins/ns/skills/run/SKILL.md`, and that subcommand only exists in `ns-conductor --help` once p1 lands. `tests/bats/plugin-complete.bats:33` ("every ns-conductor word in the plugin is a listed subcommand") fails on p2's branch on its own. So p2's acceptance `bats --jobs "$(nproc)" tests/bats exits 0` cannot pass, and if p2 merges first, `verify_after_merge` fails too. · Give p2 `depends_on: [p1-note-cli]` (p3 still depends on both, and the graph stays acyclic). Or move the SKILL.md edit and its plugin.bats test into p1, which would put p1 at 8 source files, the M limit. Add this to "Risks".
2. **blocking** · `plugins/ns/agents/conductor.md:27`, `plugins/ns/skills/implement/SKILL.md:11` · Both files restate the per-step rule ("checkpoint --push, then `should-stop`; on exit 0 park") without `owner-notes`. The conductor runs the T2/T3 phase loop by `/ns:implement`, which is the longest stretch of a run. So notes go unread there, and the model gets two conflicting versions of the step rule. That misses the plan's own Goal ("at the same between-step checkpoint where it calls `should-stop`"). · Add both files to p2's `touches`. In D5, give the exact replacement text for those two lines (same wording as run SKILL line 137). Extend the p2 plugin.bats test so every line in the three files that names `should-stop <id>` also names `owner-notes`. Leave `plugins/ns/skills/budget-guard/SKILL.md:13` unchanged: it is about the budget, not the step loop. p2 stays S (one-line edits).
3. **non-blocking** · Risks Q2 / AC-4 · AC-4 as written asks for `ns note is the owner's command` in every form, including `bin/lib/ns-note.sh` and `ns_note_main`. The plan's default (keep `lib_msg`) only satisfies it if the owner accepts Q2 at gate 1, and the board's acceptance check reads `RUN/acceptance.md`, not the plan. · Ask the conductor to record the owner's answer to Q2 in AC-4 (or in a gate note the board reads), so the board does not flag p2.
4. **non-blocking** · Design D1 step 1 · `id=$1 text=$2` with no `local`. The model, `ns-stop.sh:19`, declares its variables local. · Write `local id=$1 text=$2 ledger t n` in D1.
5. **non-blocking** · p1 brief step 5c · The worker has to work out the bash literal for the tricky text. · Spell it out: `txt='a "b" \c \(.id) $now'$'\n''second line'`. Note that `run` drops trailing newlines, so the text must not end with a newline. Compare with `[ "$(ns-ledger get "$LEDGER" '.owner_notes[0].text')" = "$txt" ]`.
6. **non-blocking** · p1 brief step 6 · Several AC-3 cases are listed together. If a worker puts them in one `@test`, the final drift append adds a second `owner_notes:` key after the valid `set`. PyYAML silently keeps the last value, so the test passes for the wrong reason. · Say "one `@test` per case, each starting with `init_ledger`".
7. **non-blocking** · Design D7 `docs/conductor.md` · "after `### should-stop`" can be read as straight after the heading. · Say "after the `should-stop` section, before `### park` (line 83)".
8. **non-blocking** · Design D5 / D7 usage text / ADR consequences · A note sent to a parked or gated run is read only after the first step of the resumed session (Start step 5), not "when it resumes", as the usage text and ADR say. After gate 1, that first step can be a whole phase. · Either add `ns-conductor owner-notes <id>` to Start step 4, after the state is set to running, and update the plugin.bats count. Or change the wording to "after the first step of the resumed session".
9. **non-blocking** · p2 vs p3 `docs/spec.md` · p2 changes the guard, but R-HK-1 is only updated in p3. CLAUDE.md says every phase updates the docs it affects. This is allowed, because the retirement phase updates reference docs. · Optional: move the R-HK-1 edit into p2. `spec.md` is in no other phase of p2's wave, and p3 depends on p2.
10. **check, no finding** · Design snippets ·
    - D1: `jq -cn --arg t … '$t'` gives a JSON string, which is a valid jq string literal. `\(` becomes `\\(` and `$now` stays literal, so nothing is interpolated or injected. `$now` is bound by `cmd_set` (`bin/ns-ledger:139`), and the whitespace-only check and the 2-argument check are correct.
    - D3: `.owner_notes // [] | to_entries[]` has the right precedence. `lg get` uses `jq -r`, so `tostring` returns `[]` when there are none. `IN([..][])` works on CI's jq 1.7.1 and is already used in `bin/ns-launch:40`. Marking by index keeps notes appended in between unread. `ns_usage` exits 2, as test 5f expects.
    - D6: `.` is the ledger at line 157, and `ep`, `stamp` and `esc` exist.
    - D2: the JSON is valid at line 32 (a property follows, so the trailing comma is right).
    - D4: `bash bin/lib/ns-note.sh` and `ns_note_main` are blocked by `LIB_RE`/`FUNC_RE` even before the file exists. `check_ns` allows `ns note --help`.
    - The anchors in the docs line references, the hooks.bats helpers and the kill.bats setup all match the code.
11. **check, no finding** · Manifest and process ·
    - Ids exist, there is no cycle, the last phase depends on all others and is the retirement phase, every phase has a `brief` and `acceptance`, complexity is S/M and `max_parallel` is 2.
    - p1/p2 `touches` are disjoint, but see finding 1.
    - No open decisions in the briefs, no manual steps and nothing that `ci-dispatch` could run.
    - ADR 0010 is the next free number and meets `docs/adr/README.md`'s bar.
    - The CHANGELOG section order is right (Added before Changed).
    - No protected path is touched, and the hooks risk zone is called out.
    - AC-1 to AC-8 are each covered by a named test or check.

Verdict: changes, because of findings 1 (a p1/p2 wave conflict that breaks p2's own acceptance) and 2 (the implement skill and the conductor agent never read notes).
REVIEW verdict=changes head=4a4ad99f11581e837901835844a9197c4fb7fdc4

## Planner's response

All findings were accepted and fixed in docs/ns-x7-plan.md:

1. p2 now has `depends_on: [p1-note-cli]`, and "Risks" explains why (plugin-complete.bats). The phases run one after another.
2. D5 now gives the exact text for `plugins/ns/agents/conductor.md:27` and `plugins/ns/skills/implement/SKILL.md:11`. Both files are in p2's `touches`, and the plugin.bats test covers all three files.
3. Q2 now states that AC-4 holds under the default only with the owner's answer, recorded at gate 1.
4. D1 declares `local id ledger text t n`.
5. The 5c literal is spelled out.
6. The AC-3 cases are four separate @test blocks.
7. The conductor.md insertion point is "before `### park` (line 83)".
8. Start step 4 (SKILL.md line 19) now also calls `owner-notes`, and the usage, conductor and ADR texts say "at the start of its resumed session".
9. Both docs/spec.md edits moved to p2.
