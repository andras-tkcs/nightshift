# Security review (post): ns-x7, `git diff origin/main...origin/feature/x7`

Reviewed: the diff at origin/feature/x7 (merge 056cab2, which contains only phase p1-note-cli), docs/ns-x7-plan.md, `.nightshift/runs/ns-x7/acceptance.md`, `.claude/project-profile.yaml` (risk_zones), and the code around the diff (`plugins/ns/hooks/lib/guard.py`, `bin/ns`, `bin/lib/runs.sh`, `bin/ns-ledger`). I did not read any worker log or reasoning.

## Findings

- blocking · plugins/ns/hooks/lib/guard.py:404 · `ns note` is not owner-only. `OWNER_SUBS` on feature/x7 is still `{"kill", "tag", "desk", "approve", "project", "rm", "purge", "gc"}`, so `check_ns`, `raw_scan`, `check_dynamic` and the unparseable-line fallback all let an agent run `ns note <id> "..."` (plain, by full path, through `env`, `bash -c` or `$(...)`). Phase p2-guard-skill, which makes this change, is not in the ledger's phases and is not merged, but the ledger is already at `step: board`. The new hooks.bats test "ns note is blocked for agents (ns-x7)" is still wrapped in `ns_xfail`, so it passes because the guard does not block. This breaks AC-4 and the request's own requirement (checklist 5 and 12: a required control is missing). · Run p2-guard-skill as planned: add `"note"` to `OWNER_SUBS` and update the comment as in D4, remove the `ns_xfail` wrapper and the helper in hooks.bats, and add the lib forms to the existing lib test. Then run this review again over the guard diff, because that is the hooks risk zone.
- blocking · docs/usage.md:20,163 · The docs say the guard blocks `ns note` ("Agents cannot run it: the guard hook blocks it", and the row in the owner-only table). That is not true at this head. A security claim with no control behind it misleads the owner (checklist 5). · This is fixed by the same p2 merge. Do not ship p1 alone.
- blocking · plugins/ns/skills/run/SKILL.md, plugins/ns/agents/conductor.md, plugins/ns/skills/implement/SKILL.md (unchanged) · The conductor never calls `ns-conductor owner-notes`. So the rule that bounds what a note can do is missing: "It never releases a gate, lifts the guard, or allows edits to protected paths; ... record it as an open question". Q1 accepts that agents can write notes only because of that bound (`ns-ledger set` is open to agents), so the bound is a required control. The plugin.bats test for it is still `ns_xfail`. Nothing reads notes today, so this is not exploitable yet, but the feature cannot ship without it. · Merge p2's D5 edits so that every `should-stop` line also names `owner-notes` and the bound sentence is in the run skill, and remove the `ns_xfail` wrapper in plugin.bats.
- non-blocking · bin/lib/ns-note.sh:25-27 · The note text goes into the `ns-ledger set` jq program as a JSON literal from `jq -cn --arg`. I checked that this is safe: a JSON string is a valid jq string literal, `\(` comes out as `\\(` so nothing is interpolated, and test 5c round-trips `"`, `\`, `\(.id)`, `$now` and a newline. Still, building a program from a string is fragile, and a large text hits `E2BIG` (about 128 KiB per argument). The command then fails before writing, so it fails closed. · Optionally give `ns-ledger set` an `--arg name value` passthrough to `jq --arg` and use `$t` in the program, or cap the note length (for example 4 KiB) with a usage error.
- non-blocking · bin/ns-conductor:697 · `owner-notes` folds only CR and LF. Other control characters in a note (ANSI escapes, `\v`, `\f`, U+2028/U+2029) reach the conductor's context and terminal unchanged. Folding newlines means one note cannot forge a second `owner note ...:` line, which is the main spoofing risk, and that holds. · Optionally also replace `[\u0000-\u001f\u007f  ]` with a space there and in report.jq `esc`.
- non-blocking · bin/ns-conductor:701 · The indices that get marked read are spliced into the program as `${idx}`. They come from `jq -c 'map(.k)'` over integer keys, so this is safe. A note appended between the `get` and the `set` keeps a higher index, stays unread and is read at the next call (no lost notes). · No change needed. Optionally pass the indices with `--argjson` once `ns-ledger set` supports arguments.
- non-blocking · bin/ns-ledger:227-228 · After a failed push, the new local commit uses `$id` and `$state` from the ledger as one quoted `-m` argument, so there is no injection. The push error reaches `event_filter` as an argument, not as program text. A failing `git commit` here (for example a commit hook) now aborts the checkpoint under `set -e`, where before it exited 0. That fails visibly, which is acceptable. · Optional: document that the checkpoint exits non-zero when this local commit fails.
- non-blocking · docs/ns-x7-plan.md (Q1) · An agent can write `owner_notes` with `ns-ledger set` or by editing `ledger.yaml`, and the conductor then treats that text as an owner instruction. The owner accepted this at gate 1 (Q1 default) on the condition that the bound in the run skill holds, and ADR 0010 is to record it. ADR 0010 (phase p3-retire) does not exist yet. · Merge p3 so that the accepted risk is on record. The guard alternative is still available if the owner revisits Q1.

## Checklist walk (whole diff)

- Secrets: the diff has no matches for the token ERE, `Authorization:` or private key blocks. Pass.
- Injection and quoting: ns-note.sh, `conductor_owner_notes` and the ns-ledger change quote every expansion and pass data through `--arg`, or as JSON that jq produced itself. There is no `eval` and no `bash -c`. `[[ $1 != -* ]]` rejects option-like ids. The id must match a registered run (`ns_run_get` uses `jq --arg`) before the code builds a path from it, so there is no traversal. Pass.
- Untrusted text: a note is stored as data, escaped in `ns report` (`esc`), and has CR/LF folded when the conductor reads it. Whether its content is trusted depends on who can write it, which the open blocking findings above cover. Partial.
- Authorization: `ns note` has no guard entry (blocking, above). The lib forms `bin/lib/ns-note.sh` and `ns_note_main` are already blocked by `LIB_RE`/`FUNC_RE` (guard.py:417-418, `lib_msg`). Fail.
- Supply chain: no new dependencies. Pass.
- Logging: events record only "owner note N added" and "read N note(s)", not the note text. Pass.
- Tests: note.bats uses temp fixtures (`make_remote`, `ns_test_setup`) and never touches `$NS_LEDGER` or a real remote. Pass.

## Risk zones (.claude/project-profile.yaml)

| Zone | Paths | Touched by this diff | Required control | Met |
|---|---|---|---|---|
| hooks | `plugins/ns/hooks/**` | No, but the request requires a change there (owner-only list) and it is missing | sec-compliance review of the guard change; `ns note` owner-only | No. The p2 guard change is not merged |
| credentials | `bin/lib/config.sh`, `bin/ns-launch` | No (ns-note.sh only sources config.sh) | n/a | n/a |

## Compliance

The profile and its docs name no compliance regime, so there is no compliance table. Nothing here claims certification.

## Summary

Phase p1 (CLI, schema, conductor reader, report, the push-failed commit) is clean: quoting and jq data handling are correct, and I found no injection paths or secrets. But feature/x7 contains only p1 while the ledger is at `board`. The guard change that makes `ns note` owner-only (p2) is missing, the conductor skill text that limits what a note can do is missing, and the docs already claim the guard blocks the command. Both acceptance tests for these items are still expected failures. Merge p2 (and p3 for ADR 0010), remove the `ns_xfail` wrappers, and send the guard diff back to this review.

REVIEW verdict=changes
