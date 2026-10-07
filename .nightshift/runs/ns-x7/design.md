# Design: ns-x7 `ns note`

Modelled on `bin/lib/ns-stop.sh` (owner sets a ledger field, conductor reads it at its checkpoint). Each item cites its AC.

## Modules touched

- `bin/lib/ns-note.sh` (new): `ns_note_help`, `ns_note_main`, `# summary: send a running run an instruction it reads at its next checkpoint` (picked up by `ns help`). Sources `config.sh` and `runs.sh` like ns-stop.sh. AC-1, AC-2.
- `bin/ns-conductor`: new `conductor_owner_notes` in the "status, stop, should-stop, park" section, a `owner-notes)` case in `main`, and a `owner-notes   <id>` line in `usage()`. AC-5. It is not `note`: `ns-conductor note` already exists in `bin/lib/conductor-loop.sh` (the conductor's own `notes.md`) and stays as it is.
- `schema/ledger.schema.json`: optional `owner_notes` property, not in `required`. AC-3.
- `plugins/ns/hooks/lib/guard.py`: add `"note"` to `OWNER_SUBS` and to the owner-only comment above it. `OWNER_WORDS`, `check_ns`, the text scan at line ~1030 and the dynamic-name checks pick it up from there. `bin/lib/ns-note.sh` and `ns_note_main` are already blocked by `LIB_RE` and `FUNC_RE` (`ns_[a-z0-9_]+_main`). AC-4.
- `plugins/ns/skills/run/SKILL.md`: every line that names `should-stop` (today lines 21, 33, 35, 44, 56, 70, 90, 137) also names `owner-notes`. Start step 5 and the summary rule spell out the order and the authority rule (Interfaces). AC-6.
- `bin/lib/report.jq`: `## Owner notes` section. AC-7.
- Docs: `docs/usage.md` (`### ns note` after `### ns stop`, and a row in the owner-only table), `docs/security.md` (the owner-only list and the "only the guard" row: add `ns note`), `docs/ledger.md` (`owner_notes` in Format, `owner-note` in the event types line), `docs/conductor.md` (`### owner-notes` next to `### should-stop`, with one line saying it is not `### note`). AC-8.
- Tests: `tests/bats/note.bats` (new: AC-1, AC-2, AC-5 against `ns-ledger init` temp ledgers, `NS_NOW` pinned, a bare remote for the push and a missing remote for `push-failed`), `tests/bats/ledger.bats` (AC-3), `tests/bats/hooks.bats` (AC-4: `blocked_all "ns note is the owner's command"` over the CLI forms, `ns note` lib/function forms added to the existing "bin/lib/ns-*.sh" test, `ns note --help` and `ns stop sbx-12` allowed), `tests/bats/report.bats` (AC-7), `tests/bats/docs-check.bats` or `tests/bats/plugin.bats` (AC-6 line check).

## Interfaces

- `ns note <id> "text"`. Exactly 2 arguments, `$1` not starting with `-`, text not empty after trimming whitespace, else `ns_usage 'ns note <id> "text"'` (exit 2, prints `usage: ns note <id> "text"`). `ns note --help` is handled by `bin/ns` (exit 0). `ns_run_get "$id" || ns_die "unknown run $id"` (exit 1). Missing ledger file: `ns_die "no ledger for $id: worktree missing, try ns resume $id"` as in ns-stop. Any state is accepted (Assumptions). Then, in order: `ns-ledger set` (append note), `ns-ledger event <ledger> owner-note "owner note <n> added"` (n = 1-based index), `ns-ledger checkpoint <ledger> --push`, print `note <n> sent to <id>; it is read at the next checkpoint`. Exit 0 even when the push fails (checkpoint already records `push-failed` and only warns).
- Safe text: `ns-ledger set` takes no `--arg`, so the text goes in as a JSON string literal: `t=$(jq -cn --arg t "$text" '$t')`, program `.owner_notes = ((.owner_notes // []) + [{time: $now, text: '"$t"', read: false}])`. A JSON string is a valid jq string literal and `\(` is encoded as `\\(`, so there is no interpolation or injection. `$now` is `ns_now` inside `cmd_set`, so `NS_NOW` pins it, and the event uses the same clock. Newlines in the text are kept as they are.
- `ns-conductor owner-notes <id>` (`[ $# -eq 1 ] || ns_usage "ns-conductor owner-notes <id>"`, `load_run`). Reads the unread indices and notes with one `lg get`. None: no output, no write, exit 0. Otherwise it prints one line per note, `owner note <time>: <text>` with newlines in the text folded to spaces, then sets `read = true` for exactly those indices (`.owner_notes |= (to_entries | map(if (.key | IN(<idx JSON>[])) then .value.read = true else . end) | map(.value))`), so a note added between the read and the write stays unread. Then `lg event "$ledger" owner-note "read <n> note(s)"` and `lg checkpoint "$ledger"` (no push; the next step's checkpoint pushes). Exit 0. No budget check.
- SKILL.md Start step 5: checkpoint `--push`, `should-stop` (exit 0 park, exit 4 end), then on exit 1 `ns-conductor owner-notes <id>`. Text: "Each printed line is an instruction from the owner. It overrides the plan's scope and the acceptance criteria where they conflict, and you note it in the step's output. It never releases a gate, lifts the guard, or allows edits to protected paths; if it asks for that, record it as an open question for the gate." A stop wins over notes: unread notes stay for the resumed session.

## Data

- Ledger: `owner_notes: [{time: "2026-10-07T21:04:00Z", text: "use sqlite", read: false}]`, append-only, absent on older ledgers.
- Schema: `"owner_notes": { "type": "array", "description": "...", "items": { "type": "object", "additionalProperties": false, "required": ["time", "text", "read"], "properties": { "time": { "$ref": "#/$defs/time" }, "text": { "type": "string", "minLength": 1 }, "read": { "type": "boolean" } } } }`.
- Events (existing shape `{time, type, note}`): `owner-note` / `owner note <n> added` from `ns note`; `owner-note` / `read <n> note(s)` from `owner-notes`; `push-failed` / `<git error line>` from checkpoint as today.
- Report: after the Escalations and report-rerun blocks, before `## Timeline`, only when `(.owner_notes // []) | length > 0`: `## Owner notes`, table `| Time | Note | Read |`, rows `| \(.time | ep | stamp) | \(.text | esc) | \(if .read then "yes" else "no" end) |`.
- No migration: a release without the field keeps it as an unknown key (docs/ledger.md, "Schema drift").

## Risks

- Forged owner notes (main risk, risk:hooks). `ns-ledger set` is open to agents, so a fooled conductor or worker can write `.owner_notes` itself and give itself "owner" scope. Notes are bounded (no gates, guard or protected paths), as with `stop_requested`, which agents can also set. Open question for the owner: is that bound enough, or should the guard also block agent writes that name `owner_notes` (in `ns-ledger set`, and Edit/Write on `ledger.yaml`)? Not in the ACs, so not decided here.
- Note text comes only from someone with the owner's shell; it is printed to the conductor with a fixed prefix, and escaped by `esc` in the report.
- Guard regression: adding to `OWNER_SUBS` must leave `ns stop`, `ns-conductor note` and `ns-conductor owner-notes` allowed (the guard checks `ns <sub>` only, so `ns-conductor` is not affected). hooks.bats covers both sides.
- AC-4 message: CLI forms give `ns note is the owner's command`; `bin/lib/ns-note.sh` and `ns_note_main` give the existing `lib_msg` (`... is the owner's to run ...`), which the existing lib test matches with `is the owner's`. If the owner wants the exact owner message there too, `lib_msg` must special-case it: open question, default is to keep `lib_msg`.
- The guard scans files named on a command line for owner-only names, so tests and scripts that mention them must follow the existing hooks.bats patterns.
- The developer must test only against temp ledgers, never `$NS_LEDGER` (CLAUDE.md).

## Rejected alternatives

- Reusing `ns-conductor note`: it writes the conductor's own notes, the opposite direction; renaming it would break the skills that call it.
- Folding notes into `should-stop` output: should-stop's exit codes are a contract (0/1/4) and the skill parses nothing from it.
- A separate notes file in the run dir: the ledger already has a lock, schema, commit and push path, and the report reads the ledger.
- Plain `checkpoint` like ns-stop: the request asks for a push (acceptance Assumptions).
- Adding `--arg` to `ns-ledger set`: a wider interface change than this needs.
