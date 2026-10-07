# ns-x7 test strategy

Inputs: `acceptance.md` (AC-1..AC-8), `design.md`, `docs/ns-x7-plan.md` (D1-D7, manifest p1-p3). Framework: bats (`tests/bats/`).

## Expected-failure marker (bats)

Bats has no xfail marker, and `skip` would hide the test. This run follows the convention of `plan/ns-5`, `plan/ns-144` and `plan/ns-x5`. Each touched test file gets its own strict wrapper `ns_xfail`, because `helpers.bash` is never edited. Each acceptance case body is a function, and the `@test` calls it like this:

```bash
ns_xfail "ns:ns-x7 acceptance" x7_note_appends
```

`ns_xfail` runs the function in a background subshell (`"$@" & wait "$!"`), so errexit stays on inside it. The case passes when the function fails. When the function succeeds, the case fails with `XPASS (ns:ns-x7 acceptance): ...` (strict). Every new title ends with `(ns-x7)`. Duplicate titles break bats.

Verified on `plan/ns-x7` before the commit:

- All 13 cases report `ok` under `ns_xfail`. `tests/lint` is ok.
- With the prefixes stripped (in temporary copies, deleted afterwards), every case fails at the assertion about the missing behaviour:
  - `ns: usage: unknown command: note`
  - `ns-conductor --help` without `owner-notes`
  - `ledger has unknown field owner_notes; kept` (today `owner_notes` is schema drift)
  - no `## Owner notes` line
  - `SKILL.md: should-stop without owner-notes`
  - `not blocked as "ns note is the owner's command"`

## What is already on plan/ns-x7 (phases must not add these again)

| File | Cases | Helpers | Removed by |
|---|---|---|---|
| `tests/bats/note.bats` (new, setup copied from `kill.bats` without the plan, feature branch and worker scripts) | 6 | `ns_xfail`, `x7_owner_events`, `x7_usage` | p1-note-cli |
| `tests/bats/ledger.bats` (appended) | 4 | `ns_xfail`, `x7_one_note` | p1-note-cli |
| `tests/bats/report.bats` (appended) | 1 | `ns_xfail` | p1-note-cli |
| `tests/bats/plugin.bats` (appended) | 1 | `ns_xfail` | p2-guard-skill |
| `tests/bats/hooks.bats` (appended) | 1 | `ns_xfail` | p2-guard-skill |

These cases cover p1 brief items 5a-5f, 6 (i)-(iv) and 7, and p2 brief items 2a-2c and 5. Item 5f (owner-notes with no argument exits 2) is folded into the no-notes case.

Deviations from the briefs. Each one stops a case from passing on today's code without the implementation:

- AC-3 (ledger.bats): today `owner_notes` is accepted as an unknown root field with a drift warning. That means "set exits 1" and "validate fails" would not prove the schema change. So:
  - Each case first writes a valid note and requires that it reads back with no `unknown field` warning (`x7_one_note`), or that `validate` prints no warning.
  - Only then does it check that the invalid note (missing `text`, extra key `by`) is refused and the file stays byte-identical.
  - Case (iv) appends a valid note in YAML first, validates it, and then removes `text:` with `sed`.
- AC-2: also checks that `HEAD` of the plan worktree is unchanged, not only the ledger bytes.
- AC-5 no-notes case: also checks that `ns-conductor --help` lists `owner-notes   <id>`. Without that, `ns-conductor owner-notes` with no argument already exits 2 today, as an unknown subcommand.
- AC-5 read case: also checks that the stored text keeps its newline (only the printed line folds it), that the ledger is committed after the read, and that the third call's event is `read 1 note(s)`.
- AC-7: the second note's text is `a | b\nnext`, so the row checks both `\|` escaping and newline folding. The "no section" check runs first in the same case, because on its own it passes today.
- AC-6 (plugin.bats): also checks that Start step 4 (`4. Set state running:`) names `ns-conductor owner-notes <id>` (D5).
- AC-4 (hooks.bats): the lib forms `bash bin/lib/ns-note.sh`, `source bin/lib/ns-note.sh` and `ns_note_main sbx-12 x` are already blocked today by `LIB_RE`/`FUNC_RE`. They are inside the new xfail case, after the CLI forms, not in the existing lib test. If p2 also adds them to the existing "bin/lib/ns-*.sh ..." test (brief 2c), that is harmless duplication.
- AC-4 adds `/usr/local/bin/ns note sbx-12 x` to the brief's CLI forms (the absolute-path form of the existing owner-only tests).

## Removing the markers

- p1-note-cli: in the commit that implements D1, D2, D3 and D6, deletes every `ns_xfail "ns:ns-x7 acceptance" ` prefix in `note.bats`, `ledger.bats` and `report.bats`, and then each file's `ns_xfail` helper and its comment. Inlining a function body into its `@test` is allowed if no assertion changes.
- p2-guard-skill: the same for `plugin.bats` and `hooks.bats`.
- Check after p2: `grep -n 'ns_xfail\|ns:ns-x7 acceptance' tests/bats/*.bats` prints nothing.

## Pyramid

- Unit (0): the behaviour is shell around `ns-ledger`, jq and git. The only pure part is the report jq. It is tested through `ns report` against the checked-in fixture, as the other report cases are.
- Integration (13): every case runs the real `bin/ns`, `bin/ns-conductor`, `bin/ns-ledger` or guard against temp state from `ns_test_setup`:
  - a temp config
  - a bare fake remote (`make_remote`), plus a missing remote for `push-failed`
  - temp ledgers from `ns new` or `ns-ledger init`, with `NS_NOW` pinned
  - guard JSON on stdin through `bash_guard`

  No case touches `$NS_LEDGER`, the network or the sandbox. There are no sleeps.
- End to end (0): a live conductor obeying a note is model behaviour (plan, Risks). No e2e scenario is added. AC-6 checks the skill text only.

## AC to test mapping

| AC | Proof | Kind | Marker now |
|---|---|---|---|
| AC-1 note appended, event, commit, push | `note.bats`: "ns note appends a timestamped unread note, records owner-note, commits and pushes (ns-x7)"; "ns note exits 0 and records push-failed when the push fails (ns-x7)"; "ns note stores quotes, backslashes, jq interpolation and newlines unchanged (ns-x7)" (D1 safe text) | test | xfail |
| AC-2 errors | `note.bats`: "ns note rejects missing, empty or extra arguments and unknown runs without touching the ledger (ns-x7)" (no text, `""`, `"   "`, 3 args, `-x`: exit 2 + usage line; `sbx-99`: exit 1 + `unknown run sbx-99`; ledger and HEAD unchanged; `--help` exit 0) | test | xfail |
| AC-3 schema | `ledger.bats`: "owner_notes is a schema field: a ledger with or without notes validates without drift warnings (ns-x7)"; "set with an owner note missing text exits 1 ..."; "set with an owner note with an extra key exits 1 ..."; "validate fails for a ledger whose owner note has no text (ns-x7)" | test | xfail |
| AC-4 guard | `hooks.bats`: "ns note is blocked for agents (ns-x7)" (blocked as `ns note is the owner's command`: plain, `NS_X=1`, `cd &&`, `/usr/local/bin/ns`, `/opt/nightshift/current/bin/ns`, `"$NS_HOME/bin/ns"`, `env`, `bash -c`, `$(...)`; blocked as `is the owner's`: `bin/lib/ns-note.sh` run/sourced, `ns_note_main`; allowed: `ns note --help`, `ns stop`, `ns-conductor note`, `ns-conductor owner-notes`, `ns-ledger event ... note`, `git commit -m "add a note"`) | test | xfail |
| AC-5 conductor read | `note.bats`: "ns-conductor owner-notes with no notes prints nothing and changes nothing (ns-x7)"; "ns-conductor owner-notes prints unread notes, marks exactly those read and prints nothing the second time (ns-x7)" | test | xfail |
| AC-6 conductor skill | `plugin.bats`: "the conductor reads owner notes wherever it calls should-stop (ns-x7)" (run skill, conductor agent, implement skill: no `should-stop` line without `owner-notes`; run skill has at least 8 such lines, Start step 4 and the authority sentences). The AC's count command: `grep 'should-stop' plugins/ns/skills/run/SKILL.md plugins/ns/agents/conductor.md plugins/ns/skills/implement/SKILL.md \| grep -vc owner-notes` prints `0` | test + command | xfail |
| AC-7 report | `report.bats`: "ns report lists owner notes with escaped text and read status, and has no section without notes (ns-x7)" | test | xfail |
| AC-8 docs and suite | Commands, not tests: `grep -q '^### ns note$' docs/usage.md`; `grep -q '\| \`ns note\` \|' docs/usage.md`; `grep -q 'owner_notes' docs/ledger.md && grep -q 'owner-note' docs/ledger.md`; `grep -q '^### owner-notes$' docs/conductor.md`; `tests/lint`, `bats --jobs "$(nproc)" tests/bats`, `tests/docs-check --final`, `claude plugin validate --strict plugins/ns` all exit 0. `tests/docs-check` rule 1 also fails if `bin/lib/ns-note.sh` exists while `docs/usage.md` lacks `` `ns note `` | command | n/a |

## Fixtures

- No new checked-in fixtures. `note.bats` builds its run in `setup()`, as `kill.bats` does: a fixture profile, `make_remote`, `ns project add`, `ns new sbx-12 --tier T2 --yes`. `ledger.bats` uses its own `init_ledger`. `report.bats` uses `tests/fixtures/report/ledger.yaml` and adds notes with `ns-ledger set` in the test, so the golden `expected.md` is unchanged.
- Times are pinned with `NS_NOW` (2026-10-07T21:04/05/06Z). Report rows use 2026-10-02T13:00/05Z, inside the fixture's run.

## Open points for the conductor

- AC-4 asks for the message `ns note is the owner's command` in every form. For `bin/lib/ns-note.sh` and `ns_note_main`, the tests accept the existing `lib_msg` (`is the owner's`), following the plan's owner decision Q2 default. `acceptance.md` does not record the Q2 answer yet. If the owner picks the exact message, the hooks case's second `blocked_all` reason must change in its own commit.
