# Plan ns-x7: `ns note`, an owner instruction channel to a running run

## Goal

The owner can send a running run a timestamped instruction with `ns note <id> "text"` (request ns-x7, no issue). The note is appended to the run ledger's new `owner_notes` field, committed and pushed. The conductor reads unread notes with `ns-conductor owner-notes <id>` at the same between-step checkpoint where it calls `should-stop`, treats them as owner instructions that override the plan's scope (never gates, the guard or protected paths), marks them read, and `ns report <id>` lists them in an `## Owner notes` section. Agents cannot run `ns note`: the guard blocks it like the other owner-only commands. Acceptance criteria: `.nightshift/runs/ns-x7/acceptance.md` (AC-1 to AC-8). Design: `.nightshift/runs/ns-x7/design.md`.

## Current state

- `bin/lib/ns-stop.sh` (47 lines) is the model: `# summary:` line read by `ns help`, `ns_stop_help`, `ns_stop_main`, `ns_usage "$u"` on bad arguments (`bin/lib/common.sh:9`, exits 2 with `usage: ...`), `ns_run_get "$id" >/dev/null || ns_die "unknown run $id"`, the "no ledger for $id" check, then `ns-ledger set`, `event`, `checkpoint` (no `--push`). `bin/ns:18` dispatches `ns <cmd>` to `bin/lib/ns-<cmd>.sh` and `ns_<cmd>_main`; `--help` is handled there.
- `bin/ns-ledger:136` `cmd_set` runs a jq program with `--arg now "$(ns_now)"` and no other `--arg`; `ns_now` honours `NS_NOW` (`bin/lib/common.sh:18`). `cmd_checkpoint` (`bin/ns-ledger:193`) commits the ledger dir and, with `--push`, on a failed push appends a `push-failed` event and only warns (exit 0). Every read validates against `schema/ledger.schema.json`, which has `"additionalProperties": false` at the top (line 7), `$defs.time` (line 10) and `stop_requested` (line 32).
- `bin/ns-conductor`: `usage()` lines 31-43; section `# status, stop, should-stop, park` from line 634; `conductor_should_stop` lines 681-687 (exit 0 stop, 4 budget, 1 continue); `main` dispatch lines 718-725; `lg()` line 72; `load_run` line 52 sets `ledger`. `ns-conductor note` is a different, existing subcommand in `bin/lib/conductor-loop.sh` (the conductor's own `RUN/notes.md`) and stays unchanged.
- `plugins/ns/hooks/lib/guard.py:395-405`: comment listing owner-only commands, `OWNER_SUBS = {"kill", "tag", "desk", "approve", "project", "rm", "purge", "gc"}`, `OWNER_WORDS = OWNER_SUBS | {"merge", "drop"}`. `raw_scan` (line 1030), `check_dynamic` (line 1248), `check_ns` (line 1265, which allows `ns <sub> --help`) and the unparseable-line fallback (line 1755) all read these sets. `LIB_RE` (line 417) and `FUNC_RE` (line 418, `ns_[a-z0-9_]+_main`) already block `bin/lib/ns-note.sh` and `ns_note_main` with `lib_msg` (line 428).
- `plugins/ns/skills/run/SKILL.md` names `should-stop` on lines 21 (Start step 5), 33, 35, 44, 56, 70, 90 and 137 (the summary rule).
- `bin/lib/report.jq`: `esc` (line 7), `ep` (line 6), `stamp` (line 14); the escalations and `report-rerun` blocks end just before `+ ["", "## Timeline", ...]` at line 157. `.` is the ledger there.
- Tests: `tests/bats/kill.bats` setup (lines 5-22: `make_remote`, `ns project add`, `ns new sbx-12 --tier T2 --yes`, `LEDGER=...`) is the fixture to copy for `ns note`; `tests/bats/ledger.bats:153` shows the missing-remote `push-failed` pattern; `tests/bats/conductor.bats:523` tests `should-stop`; `tests/bats/hooks.bats` has `blocked_all` / `allowed_all` (lines 336-358), the `ns kill` test with `ns stop` allowed (line 300) and the lib/function test (line 465); `tests/bats/report.bats` setup copies `tests/fixtures/report/ledger.yaml`.
- Docs: `docs/usage.md` owner-only table (lines 13-23), open-commands sentence (line 28), `### ns stop` (line 148); `docs/security.md` owner-only table (lines 72-85) and "The real boundary" row (line 125); `docs/ledger.md` Format block (lines 15-44) and event types (line 46); `docs/conductor.md` `### should-stop` (line 75); `docs/spec.md` CLI table (lines 139-140) and R-HK-1 (line 244). `tests/docs-check` rule 1 fails unless `docs/usage.md` contains `` `ns note `` once `bin/lib/ns-note.sh` exists.

## Design

The design in `.nightshift/runs/ns-x7/design.md` is settled; this section restates the exact text the briefs use.

### D1. `ns note` (`bin/lib/ns-note.sh`)

```bash
# shellcheck shell=bash
# summary: send a running run an instruction it reads at its next checkpoint
```

Sources `config.sh` and `runs.sh` as `ns-stop.sh` does (not `ns-kill.sh`).

`ns_note_help` prints:

```
usage: ns note <id> "text"

Send the run an instruction. It is added to owner_notes in the ledger, committed and pushed;
the conductor reads it at its next checkpoint and follows it over the plan's scope.
A note never releases a gate, lifts the guard or allows edits to protected paths.
```

`ns_note_main`:

1. `local u='ns note <id> "text"' id ledger text t n`; `[ $# -eq 2 ] && [[ $1 != -* ]] || ns_usage "$u"`; `id=$1 text=$2`; `[[ -n ${text//[[:space:]]/} ]] || ns_usage "$u"`.
2. `ns_run_get "$id" >/dev/null || ns_die "unknown run $id"`; `ledger=$(ns_run_ledger "$id")`; `[ -f "$ledger" ] || ns_die "no ledger for $id: worktree missing, try ns resume $id"`. Any run state is accepted.
3. `t=$(jq -cn --arg t "$text" '$t')` (a JSON string is a valid jq string literal; `\(` is encoded as `\\(`, so no interpolation).
4. `"$NS_HOME/bin/ns-ledger" set "$ledger" '.owner_notes = ((.owner_notes // []) + [{time: $now, text: '"$t"', read: false}])'`.
5. `n=$("$NS_HOME/bin/ns-ledger" get "$ledger" '.owner_notes | length')`.
6. `"$NS_HOME/bin/ns-ledger" event "$ledger" owner-note "owner note $n added"`.
7. `"$NS_HOME/bin/ns-ledger" checkpoint "$ledger" --push` (a failed push records `push-failed` and warns; `ns note` still exits 0).
8. `printf 'note %s sent to %s; it is read at the next checkpoint\n' "$n" "$id"`.

The text is stored unchanged, newlines included.

### D2. Schema (`schema/ledger.schema.json`)

Add after the `stop_requested` property (line 32), not to `required`:

```json
"owner_notes": { "type": "array", "description": "Owner instructions sent with ns note, append-only; the conductor sets read when it has read one (ns-conductor owner-notes).", "items": { "type": "object", "additionalProperties": false, "required": ["time", "text", "read"], "properties": { "time": { "$ref": "#/$defs/time" }, "text": { "type": "string", "minLength": 1 }, "read": { "type": "boolean" } } } },
```

### D3. `ns-conductor owner-notes <id>` (`bin/ns-conductor`)

`usage()` gets `printf '  owner-notes   <id>\n'` after the `should-stop` line. `main` gets `owner-notes) conductor_owner_notes "$@" ;;` after `should-stop)`. The function goes after `conductor_should_stop`:

```bash
# conductor_owner_notes <id>: print the unread owner notes and mark exactly those read
conductor_owner_notes() {
  [ $# -eq 1 ] || ns_usage "ns-conductor owner-notes <id>"
  local sel idx n
  load_run "$1"
  sel=$(lg get "$ledger" '[.owner_notes // [] | to_entries[] | select(.value.read | not)
    | {k: .key, line: "owner note \(.value.time): \(.value.text | gsub("[\r\n]+"; " "))"}] | tostring')
  [ "$sel" != "[]" ] || return 0
  jq -r '.[].line' <<<"$sel"
  idx=$(jq -c 'map(.k)' <<<"$sel")
  n=$(jq length <<<"$sel")
  lg set "$ledger" ".owner_notes |= (to_entries | map(if (.key | IN(${idx}[])) then .value.read = true else . end) | map(.value))"
  lg event "$ledger" owner-note "read $n note(s)"
  lg checkpoint "$ledger"
}
```

No unread notes: no output, no write, exit 0. A note added between the read and the write keeps `read: false`. No budget check. No push (the next step's checkpoint pushes).

### D4. Guard (`plugins/ns/hooks/lib/guard.py`)

`OWNER_SUBS = {"kill", "tag", "desk", "approve", "project", "rm", "purge", "gc", "note"}`. The comment above it starts `# ns kill, tag, desk, approve, project, rm (purge), gc, note, stack merge, stack drop and` and its second sentence gains `send a run owner instructions,` after `release gates,`. Nothing else changes: `owner_msg("note")` gives `ns note is the owner's command`; `ns note --help` stays allowed by `check_ns`; `bin/lib/ns-note.sh` and `ns_note_main` give the existing `lib_msg` text (owner decision Q2 below keeps it).

### D5. Run skill (`plugins/ns/skills/run/SKILL.md`), conductor agent and implement skill

Line 21 (Start step 5) becomes exactly:

```
5. After every step, without exception: `ns-ledger checkpoint "$NS_LEDGER" --push`, then `ns-conductor should-stop <id>`. On exit 0 run `ns-conductor park <id>` and end the session with a one-line summary. On exit 4 the time budget is used up and the run already waits at gate 1.5: end the session with a one-line summary. On exit 1 run `ns-conductor owner-notes <id>`. Each printed line is an instruction from the owner. It overrides the plan's scope and the acceptance criteria where they conflict, and you note it in the step's output. It never releases a gate, lifts the guard, or allows edits to protected paths; if it asks for that, record it as an open question for the gate. A stop wins over notes: unread notes stay for the resumed session.
```

Lines 33, 35, 44, 56, 70 and 90: every occurrence of the phrase ``checkpoint and `should-stop` `` / ``Checkpoint and `should-stop` `` becomes ``checkpoint, `should-stop` and `owner-notes` `` / ``Checkpoint, `should-stop` and `owner-notes` `` (same capitalisation as before; line 33 keeps `(Start step 5)` after it). Line 137 becomes exactly:

```
- Every step ends with `ns-ledger checkpoint "$NS_LEDGER" --push` and `ns-conductor should-stop <id>`; on exit 0 run `ns-conductor park <id>` and end the session; on exit 1 run `ns-conductor owner-notes <id>` and follow its lines as Start step 5 says.
```

Line 19 (Start step 4, the line starting `4. Set state running:`) gets this sentence appended at its end, so notes sent while no session ran are read before the first step of a resumed session:

```
 Then run `ns-conductor owner-notes <id>` and follow its lines as step 5 says.
```

The same per-step rule is repeated in two more plugin files, which the conductor follows during the T2/T3 phase loop; both get the `owner-notes` call:

- `plugins/ns/agents/conductor.md` line 27 becomes exactly:

  ```
  2. After every step run `ns-ledger checkpoint "$NS_LEDGER" --push`, then `ns-conductor should-stop <id>`. On exit 0 run `ns-conductor park <id>` and end the session with a one-line summary. On exit 1 run `ns-conductor owner-notes <id>` and follow its lines as the run skill's Start step 5 says (owner instructions over the plan's scope, never over gates, the guard or protected paths).
  ```

- `plugins/ns/skills/implement/SKILL.md` line 11: the sentence ``After every step run `ns-ledger checkpoint "$NS_LEDGER" --push`, then `ns-conductor should-stop <id>`; on exit 0 run `ns-conductor park <id>` and end the session.`` becomes exactly ``After every step run `ns-ledger checkpoint "$NS_LEDGER" --push`, then `ns-conductor should-stop <id>`; on exit 0 run `ns-conductor park <id>` and end the session; on exit 1 run `ns-conductor owner-notes <id>` and follow its lines as the run skill's Start step 5 says.`` The rest of line 11 stays.

### D6. Report (`bin/lib/report.jq`)

Insert before `+ ["", "## Timeline", ...]` (line 157):

```jq
  + (if ((.owner_notes // []) | length) > 0 then
      ["", "## Owner notes", "", "| Time | Note | Read |", "|---|---|---|"]
      + [.owner_notes[] | "| \(.time | ep | stamp) | \(.text | esc) | \(if .read then "yes" else "no" end) |"]
    else [] end)
```

### D7. Doc texts

- `docs/usage.md`, after `### ns stop`'s paragraph (before `### ns kill`):

  ````
  ### ns note

  ```
  ns note <id> "text"
  ```

  `ns note` sends a run an instruction. It appends `{time, text, read: false}` to `owner_notes` in the ledger, records an `owner-note` event, commits the ledger and pushes it (a failed push is recorded as a `push-failed` event and `ns note` still succeeds). It prints `note <n> sent to <id>; it is read at the next checkpoint`. The conductor reads unread notes after every step (`ns-conductor owner-notes`), follows them over the plan's scope and acceptance criteria, and marks them read; a note never releases a gate, lifts the guard or allows edits to protected paths. It works on a run in any state: a run with no live conductor reads the note at the start of its resumed session. `ns report <id>` lists the notes. Agents cannot run it: the guard hook blocks it.
  ````

  Owner-only table row, after the `ns approve` row: ``| `ns note` | sends the run an instruction the conductor follows over the plan's scope |``.
- `docs/security.md` owner-only table row after `ns approve`: ``| `ns note` | sends a run an instruction that its conductor follows over the plan's scope (bounded: no gates, guard or protected paths) |``. "The real boundary" last row: the parenthesis becomes ``(`ns kill`, `ns rm`, `ns gc`, `ns approve`, `ns note`, `--allow-outside`)``, and the row gains one sentence: ``An agent can still write `owner_notes` with `ns-ledger set`, as it can `stop_requested`; such a note is bounded the same way.``
- `docs/ledger.md` Format block, after the `stop_requested:` line: `owner_notes: []                  # optional; ns note appends {time, text, read: false}, ns-conductor owner-notes sets read: true`. Event types line: add `owner-note` after `stop-requested`.
- `docs/conductor.md`, after the `### should-stop` section's paragraph and before `### park` (line 83):

  ````
  ### owner-notes

  ```
  ns-conductor owner-notes <id>
  ```

  Prints each unread owner note (`ns note`) as `owner note <time>: <text>`, newlines folded to spaces, then sets exactly those notes `read: true`, adds the ledger event `owner-note` with `read <n> note(s)` and checkpoints the ledger (no push). With no unread notes it prints nothing and changes nothing. Exit 0. The conductor calls it after `should-stop` exits 1, and once at the start of every session after it sets the state running. It is not `note` below, which writes the conductor's own `RUN/notes.md`.
  ````
- `docs/spec.md` CLI table, after the `ns stop` row: ``| `ns note <id> "text"` | Send the run an instruction; the conductor reads it at its next checkpoint and follows it over the plan's scope (owner only). |``. R-HK-1: the owner-only list gains `note` after `gc`.

### Rejected alternatives

From the design: reusing `ns-conductor note` (opposite direction, renaming breaks skills); folding notes into `should-stop` output (its 0/1/4 exit codes are a contract); a separate notes file (the ledger already has lock, schema, commit and push, and the report reads it); plain `checkpoint` like `ns stop` (the request asks for a push); `--arg` on `ns-ledger set` (wider interface change than needed).

## ADRs

- ADR 0010 "Owner notes reach the conductor through the ledger": the owner-only `ns note` appends to `owner_notes`; the conductor reads them at its between-step checkpoint and follows them over the plan's scope and acceptance criteria, never over gates, the guard or protected paths; agent writes to `owner_notes` through `ns-ledger set` are not blocked, the bound is the control, as for `stop_requested` (owner decision Q1). Rejected alternatives as above. This moves a trust boundary (a new instruction channel into the conductor), so it meets `docs/adr/README.md`'s bar.

## Manual steps

None. `manual_before` and `manual_after` are empty and there is no `RUN/manual-steps.md`. Every acceptance item runs in bats against temp ledgers.

## Risks and open questions

Owner decisions for gate 1 (the plan follows the default; a different answer means revising this plan before phases start):

- **Q1. Guard agent writes to `owner_notes`?** `ns-ledger set` is open to agents, so a fooled conductor or worker can write a note itself. Default: **no extra guard**; notes are bounded (no gates, guard or protected paths) as `stop_requested` is, and ADR 0010 records this. The alternative (the guard blocks `ns-ledger set` programs and Edit/Write on `ledger.yaml` that name `owner_notes`) would add a phase touching `guard.py` and `hooks.bats`.
- **Q2. Message for `bin/lib/ns-note.sh` and `ns_note_main`.** Default: **keep `lib_msg`** (`... is the owner's to run (ns library code runs only through ns)`), which AC-4's lib forms match via `is the owner's`. The alternative special-cases `lib_msg` to print `ns note is the owner's command`. AC-4 literally asks for that message in every form, so the default holds only with the owner's answer to Q2; the conductor records it in `acceptance.md` at gate 1 so the review board does not flag p2.

Risks a worker should recognise (stop with `status=blocked`, do not improvise):

- **`note` in `OWNER_WORDS`** also makes `check_dynamic` and the unparseable-line fallback refuse lines whose literal words include `note` when the command name is dynamic or the line does not parse. p2 adds `allowed_all` cases for `ns-conductor note`, `ns-conductor owner-notes`, `ns-ledger event ... note ...` and a `git commit -m` naming a note. If an existing hooks.bats test or any of these new allowed cases fails because of `note` in `OWNER_WORDS`, stop: changing `OWNER_WORDS` separately from `OWNER_SUBS` is a design change.
- **Schema validation on read**: every ledger read validates, so a test ledger with `owner_notes` fails anywhere until D2 lands. That is why the report change is in p1, with the schema.
- **jq literal injection**: if a test text with `"`, `\`, `\(`, `$now` or a newline is not stored byte for byte, D1 step 3 is wrong; stop rather than switch to string escaping by hand.
- **Live ledger**: tests use only temp ledgers from `ns_test_setup`; never run the new commands against `$NS_LEDGER` (CLAUDE.md).
- **Guard scanning**: the guard scans scripts and program text named on command lines for owner-only names. Follow the existing `hooks.bats` patterns (commands as `bash_guard` strings) and do not write helper scripts that contain `ns note`.
- A live conductor obeying a note is model behaviour no bats test can check; AC-6 checks only the skill text.
- **Phase order**: p2 depends on p1 because `tests/bats/plugin-complete.bats:33` fails for any `ns-conductor <word>` in the plugin's Markdown that `ns-conductor --help` does not list, and `owner-notes` is listed only once p1 lands. The phases therefore run one after another.
- **Guard scans of the plan**: the installed guard refuses interpreters (`python3 <file>`) given a file that names `bin/lib/ns-*.sh`, and this plan does. Read it with the Read tool, or pipe an extract into `python3 -c`; do not pass the plan path to an interpreter.

## Implementation manifest

```yaml
plan_slug: ns-x7
feature_branch: feature/ns-x7
max_parallel: 2
manual_before: []
manual_after: []
verify_after_merge:
  - tests/lint
  - bats --jobs "$(nproc)" tests/bats
  - tests/docs-check
final_checks:
  - docs/ns-x7-plan.md is deleted
  - docs/adr/0010-owner-notes-channel.md exists and docs/adr/README.md lists 0010
  - CHANGELOG.md has an ns note entry under [Unreleased] / Added
  - tests/docs-check --final exits 0
  - claude plugin validate --strict plugins/ns exits 0
phases:
  - id: p1-note-cli
    title: ns note, the owner_notes schema, ns-conductor owner-notes and the report section
    depends_on: []
    complexity: M
    touches:
      - bin/lib/ns-note.sh
      - schema/ledger.schema.json
      - bin/ns-conductor
      - bin/lib/report.jq
      - tests/bats/note.bats
      - tests/bats/ledger.bats
      - tests/bats/report.bats
      - docs/usage.md
      - docs/ledger.md
      - docs/conductor.md
    brief: |
      Read docs/ns-x7-plan.md sections "Current state" and "Design" D1, D2, D3, D6, D7 first. Test only against temp ledgers (ns_test_setup); never touch $NS_LEDGER.
      1. schema/ledger.schema.json: add the owner_notes property exactly as in D2, right after the stop_requested property. Do not add it to "required".
      2. bin/lib/ns-note.sh (new): write it exactly as D1 (summary line, ns_note_help text, ns_note_main steps 1-8), modelled on bin/lib/ns-stop.sh. Make it shellcheck clean.
      3. bin/ns-conductor: add the usage line, the main case and conductor_owner_notes exactly as D3, the function right after conductor_should_stop.
      4. bin/lib/report.jq: insert the D6 block right before the `+ ["", "## Timeline", ...]` line.
      5. tests/bats/note.bats (new): copy the setup of tests/bats/kill.bats lines 5-22 (fixture profile, make_remote, ns project add, ns new sbx-12 --tier T2 --yes, WT and LEDGER; drop the plan, feature branch and worker script parts). Tests:
         a. AC-1: NS_NOW=2026-10-07T21:04:00Z ns note sbx-12 "use sqlite" exits 0 and prints "note 1 sent to sbx-12; it is read at the next checkpoint"; ns-ledger get "$LEDGER" '.owner_notes | tostring' is [{"time":"2026-10-07T21:04:00Z","text":"use sqlite","read":false}]; exactly one more owner-note event with note "owner note 1 added"; git -C "$WT" status --porcelain -- .nightshift is empty; git -C "$WT" rev-parse HEAD equals git -C "$WT" rev-parse origin/plan/sbx-12 after a git fetch.
         b. AC-1 push failure: git -C "$WT" remote set-url origin "$BATS_TEST_TMPDIR/nowhere.git"; ns note sbx-12 "x" exits 0 and the last event type is push-failed.
         c. Safe text: txt='a "b" \c \(.id) $now'$'\n''second line'; ns note sbx-12 "$txt" exits 0; [ "$(ns-ledger get "$LEDGER" '.owner_notes[0].text')" = "$txt" ] (the text has no trailing newline, so command substitution drops nothing).
         d. AC-2: ns note sbx-12; ns note sbx-12 ""; ns note sbx-12 "   "; ns note sbx-12 a b; ns note -x a each exit 2 with output containing 'usage: ns note <id> "text"'; ns note sbx-99 "x" exits 1 with "unknown run sbx-99"; after all of them the ledger file is byte-identical to a copy taken before. ns note --help exits 0 and prints 'usage: ns note <id> "text"'.
         e. AC-5: with no notes, ns-conductor owner-notes sbx-12 prints nothing and the ledger is byte-identical. Add two notes (NS_NOW pinned, the second text "line one" newline "line two"); ns-conductor owner-notes sbx-12 prints exactly two lines "owner note <time>: use sqlite" and "owner note <time>: line one line two"; both notes are read: true; the last event is owner-note "read 2 note(s)"; a second call prints nothing and leaves the ledger byte-identical. Add a third note: the next call prints only that one.
         f. ns-conductor owner-notes with no argument exits 2.
      6. tests/bats/ledger.bats (AC-3): four separate @test blocks, each starting with init_ledger (no checkpoint, so there is no committed version to restore): (i) a ledger with owner_notes [{time: $now, text: "x", read: false}] set via ns-ledger set passes ns-ledger validate, and a fresh ledger without the field passes too; (ii) setting .owner_notes = [{time: $now, read: false}] (missing text) makes ns-ledger set exit 1 and leaves the file byte-identical, as the existing "set with an invalid state" test (line 58) checks; (iii) an extra key in a note ({time: $now, text: "x", read: false, by: "agent"}) fails the same way; (iv) in the pattern of the "drift ledger with a hard error" test (line 293), append printf 'owner_notes:\n- {time: "2026-10-07T21:04:00Z", read: false}\n' >>"$L" and check that ns-ledger validate "$L" exits 1 with output containing owner_notes.
      7. tests/bats/report.bats (AC-7): after setup, ns-ledger set "$RUNDIR/ledger.yaml" to add two notes, one read: true, one read: false with text containing "|"; ns report sbx-12 output contains "## Owner notes", "| Time | Note | Read |", a row ending "| yes |", a row ending "| no |" and the text with "|" escaped as "\|"; "## Owner notes" comes before "## Timeline". The unchanged fixture's report has no "## Owner notes".
      8. Docs, texts exactly as D7: docs/usage.md (### ns note section after ### ns stop, owner-only table row after ns approve), docs/ledger.md (Format line and owner-note event type), docs/conductor.md (### owner-notes after ### should-stop).
      9. Run tests/lint, bats --jobs "$(nproc)" tests/bats and tests/docs-check; all exit 0.
      Stop conditions: if ns-ledger set rejects the D1 program, or test 5c does not round-trip, stop with status=blocked and report the jq error; do not hand-escape the text. If ns new in the copied setup needs anything kill.bats does not set, stop and report.
    acceptance:
      - bats tests/bats/note.bats passes
      - bats tests/bats/ledger.bats tests/bats/report.bats passes
      - grep -q '"owner_notes"' schema/ledger.schema.json
      - grep -q '^### ns note$' docs/usage.md && grep -q '^### owner-notes$' docs/conductor.md && grep -q 'owner-note' docs/ledger.md
      - tests/lint exits 0
      - bats --jobs "$(nproc)" tests/bats exits 0
      - tests/docs-check exits 0
  - id: p2-guard-skill
    title: Block ns note for agents and make the conductor read owner notes
    depends_on: [p1-note-cli]
    complexity: M
    touches:
      - plugins/ns/hooks/lib/guard.py
      - plugins/ns/skills/run/SKILL.md
      - plugins/ns/agents/conductor.md
      - plugins/ns/skills/implement/SKILL.md
      - tests/bats/hooks.bats
      - tests/bats/plugin.bats
      - docs/security.md
      - docs/spec.md
    brief: |
      Read docs/ns-x7-plan.md sections "Current state", "Design" D4, D5, D7 and "Risks and open questions" first. This phase is in the hooks risk zone.
      1. plugins/ns/hooks/lib/guard.py: add "note" to OWNER_SUBS and edit the comment above it exactly as D4. Change nothing else in the file.
      2. tests/bats/hooks.bats:
         a. In "ns kill is blocked for agents" style, add a test "ns note is blocked for agents": blocked_all "ns note is the owner's command" "ns note sbx-12 \"use sqlite\"" "NS_X=1 ns note sbx-12 x" "cd /tmp && ns note sbx-12 x" "/opt/nightshift/current/bin/ns note sbx-12 x" '"$NS_HOME/bin/ns" note sbx-12 x' "env ns note sbx-12 x" "bash -c 'ns note sbx-12 x'" 'echo $(ns note sbx-12 x)'.
         b. In the same test: allowed_all "ns note --help" "ns stop sbx-12" "ns-conductor note sbx-12 \"follow-up\"" "ns-conductor owner-notes sbx-12" "ns-ledger event \"\$NS_LEDGER\" note \"x\"" "git commit -m \"add a note\"".
         c. In "bin/lib/ns-*.sh and owner-only helpers cannot be run or sourced directly" (line ~465), add "bash bin/lib/ns-note.sh" and "ns_note_main sbx-12 x" to its blocked_all list (message "is the owner's", owner decision Q2 default).
      3. plugins/ns/skills/run/SKILL.md: edit line 19 (append), line 21, lines 33, 35, 44, 56, 70, 90 and line 137 exactly as D5. Change no other line.
      4. plugins/ns/agents/conductor.md line 27 and plugins/ns/skills/implement/SKILL.md line 11: edit exactly as D5. Change no other line.
      5. tests/bats/plugin.bats: add a test "the conductor reads owner notes wherever it calls should-stop": with r=$NS_REPO_ROOT/plugins/ns/skills/run/SKILL.md, [ "$(grep -c 'should-stop' "$r")" -ge 8 ]; then for each f of $r, $NS_REPO_ROOT/plugins/ns/agents/conductor.md and $NS_REPO_ROOT/plugins/ns/skills/implement/SKILL.md: [ "$(grep 'should-stop' "$f" | grep -vc 'owner-notes')" = 0 ] and grep -q 'should-stop' "$f"; finally grep -qF 'It never releases a gate, lifts the guard, or allows edits to protected paths' "$r" and grep -qF "It overrides the plan's scope" "$r".
      6. docs/security.md: the owner-only table row and "The real boundary" row edits exactly as D7. docs/spec.md: the CLI table row after ns stop and the R-HK-1 edit, exactly as D7.
      7. Run tests/lint, bats --jobs "$(nproc)" tests/bats, tests/docs-check and claude plugin validate --strict plugins/ns; all exit 0 (tests/bats/plugin-complete.bats needs p1's owner-notes subcommand, which is merged before this phase starts).
      Stop conditions: if any existing hooks.bats test or a 2b allowed case fails after step 1 because "note" is now in OWNER_WORDS, stop with status=blocked and name the test and the guard function (check_dynamic or the fallback); do not split OWNER_WORDS from OWNER_SUBS. If the 2c forms are not blocked by LIB_RE/FUNC_RE, stop and report; do not change lib_msg.
    acceptance:
      - bats tests/bats/hooks.bats passes, including the new "ns note is blocked for agents" test
      - bats tests/bats/plugin.bats passes, including the new owner-notes test
      - grep -q '"gc", "note"}' plugins/ns/hooks/lib/guard.py
      - grep 'should-stop' plugins/ns/skills/run/SKILL.md plugins/ns/agents/conductor.md plugins/ns/skills/implement/SKILL.md | grep -vc 'owner-notes' prints 0
      - grep -q '`ns note`' docs/security.md
      - grep -q '`ns note <id> "text"`' docs/spec.md
      - bats tests/bats/plugin-complete.bats passes
      - tests/lint exits 0
      - bats --jobs "$(nproc)" tests/bats exits 0
      - claude plugin validate --strict plugins/ns exits 0
  - id: p3-retire
    title: ADR 0010, changelog, retire the plan
    depends_on: [p1-note-cli, p2-guard-skill]
    complexity: S
    touches:
      - docs/adr/0010-owner-notes-channel.md
      - docs/adr/README.md
      - CHANGELOG.md
      - docs/ns-x7-plan.md
    brief: |
      Read docs/ns-x7-plan.md sections "Design", "ADRs" and "Risks and open questions" first.
      1. docs/adr/0010-owner-notes-channel.md: title "# 0010. Owner notes reach the conductor through the ledger", sections Status (Accepted), Context, Decision, Consequences, in the shape of docs/adr/0006-guard-hook-fails-open.md. Context: the owner had no way to steer a running run except ns stop or a gate. Decision: the "ADRs" bullet of the plan, plus the "Rejected alternatives" list of the Design section and, as a rejected alternative, guarding agent writes to owner_notes (Q1: the bound is the control, as for stop_requested). Consequences: a fooled agent can write a note but a note cannot release a gate, lift the guard or allow edits to protected paths; notes are append-only and listed in ns report; a note to a run with no live conductor is read at the start of its resumed session.
      2. docs/adr/README.md: add the row "| [0010](0010-owner-notes-channel.md) | Owner notes reach the conductor through the ledger | Accepted |".
      3. CHANGELOG.md: under ## [Unreleased] add a "### Added" section (before "### Changed") with: "- `ns note <id> \"text\"` sends a running run an instruction. It is appended to the new ledger field `owner_notes`, committed and pushed; the conductor reads unread notes after every step with `ns-conductor owner-notes <id>`, follows them over the plan's scope, and marks them read. `ns report` lists them under `## Owner notes`. Agents cannot run it (guard) (ns-x7)."
      4. git rm docs/ns-x7-plan.md.
      5. Run tests/lint, bats --jobs "$(nproc)" tests/bats, tests/docs-check --final, claude plugin validate --strict . and claude plugin validate --strict plugins/ns; all exit 0.
      Stop condition: if docs/adr/0010-*.md already exists (another run took the number), stop with status=blocked and report the conflicting file.
    acceptance:
      - test -f docs/adr/0010-owner-notes-channel.md
      - grep -q '0010-owner-notes-channel.md' docs/adr/README.md
      - test ! -e docs/ns-x7-plan.md
      - grep -q 'ns note' CHANGELOG.md
      - tests/docs-check --final exits 0
      - bats --jobs "$(nproc)" tests/bats exits 0
      - claude plugin validate --strict plugins/ns exits 0
```
