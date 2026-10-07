# Acceptance: ns-x7 `ns note`

Goal: the owner can send a running run a timestamped instruction with `ns note <id> "text"`, which the conductor picks up at its next between-step checkpoint, obeys over the plan's scope, marks read and lists in the run report.

## Criteria

- AC-1 Command: against a temp ledger fixture, `ns note <id> "use sqlite"` exits 0, appends `{time: "<YYYY-MM-DDTHH:MM:SSZ>", text: "use sqlite", read: false}` (NS_NOW pins the time) to `owner_notes`, adds one `owner-note` event, and commits the ledger dir with `ns-ledger checkpoint --push` (a failed push leaves a `push-failed` event and still exits 0). Checked by a new bats test.
- AC-2 Errors: `ns note` with no text, an empty text, or more than 2 arguments exits non-zero with the `usage: ns note <id> "text"` line; an unknown id exits 1 with `unknown run <id>`; the ledger is unchanged in each case. `ns note --help` exits 0. Checked by bats.
- AC-3 Schema: `owner_notes` is in `schema/ledger.schema.json` as an optional array of `{time, text, read}` with no extra keys; `ns-ledger validate` passes for a ledger with notes and for one without the field (older ledgers stay valid), and fails for a note missing `text`. Checked by bats (`tests/bats/ledger.bats` or a new file).
- AC-4 Guard: `plugins/ns/hooks/lib/guard.py` blocks `ns note` in every form the existing owner-only tests cover (full path, `env`, `bash -c`, `$(...)`, `bin/lib/ns-note.sh` and `ns_note_main`), with message `ns note is the owner's command`; `ns stop` and other open commands stay allowed. Checked in `tests/bats/hooks.bats`.
- AC-5 Conductor read: a conductor-side `ns-conductor` subcommand (name chosen in the plan) prints each unread note's time and text, sets those notes `read: true`, adds an event (for example `owner-note` with note `read <n> note(s)`), and prints nothing and changes nothing when there are no unread notes. Checked by bats against a temp ledger, including a second call printing nothing.
- AC-6 Conductor skill: `plugins/ns/skills/run/SKILL.md` calls that subcommand at every place it calls `should-stop` (Start step 5 and the summary rule), and says unread notes are owner instructions that override the plan's scope but not gates, the guard or protected paths. Check: `grep -c should-stop` and the new subcommand's name give matching counts in the procedure; a bats or docs-check test asserts it.
- AC-7 Report: `ns report <id>` on a ledger with notes shows an `## Owner notes` section listing each note's time, text (escaped like other ledger text) and read status; a ledger with no notes has no such section. Checked in `tests/bats/report.bats`.
- AC-8 Docs and suite: `docs/usage.md` has an `### ns note` section and an `ns note` row in the owner-only table; `docs/ledger.md` lists `owner_notes` in the format and `owner-note` in the event types; `docs/conductor.md` documents the new subcommand; `tests/lint`, `bats --jobs "$(nproc)" tests/bats`, `tests/docs-check --final` and `claude plugin validate --strict plugins/ns` all exit 0.

## Non-goals

- No change to `ns stop`, `stop_requested` or `ns-conductor park` behaviour.
- No editing or deleting notes, no notes on a phase-worker level, no desk or notification for notes.
- Notes do not release gates, lift the guard, or allow edits to `protected_paths`.

## Assumptions

- "Committed and pushed like stop_requested": `ns stop` only commits (`checkpoint` without `--push`); the request asks for push, so AC-1 uses `--push`.
- `ns note` works on any run with a ledger, whatever its state; a note on a run with no live conductor is read when the run resumes.
- "Run report" means `ns report` (bin/lib/report.jq).
