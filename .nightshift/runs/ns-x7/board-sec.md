# Board: security and compliance review, ns-x7 (post)

Scope: I read all of `git diff origin/main...origin/feature/x7` at `608f0111555371149a4a4d29e1a43e1b265616a5` (20 files), plus the code around it: `bin/ns` dispatch, `bin/ns-ledger` (`cmd_set`, `cmd_checkpoint`, `git_retry`), `bin/ns-conductor` (`load_run`, worker launch), `bin/lib/report.jq` `esc`, and `bin/lib/runs.sh` `ns_run_ledger`. Inputs: the diff, `docs/ns-x7-plan.md`, `RUN/design.md`, `.claude/project-profile.yaml` and `docs/security.md`. I read no worker log or reasoning. The previous version of this file covered `58b95c3`. The only ns-x7 commit since then is `6383887`, a reflow of the run skill's step 5 with the same text. The other new commits are merges from `origin/main`.

Scope note from the caller: phase p3-retire (ADR, changelog, plan retirement) is not in this branch on purpose; the integrator adds it. This review therefore does not grade the missing ADR as a defect of this head. It does carry it forward as a required control below.

## Findings

- non-blocking · docs/security.md:128 · Agents can forge owner instructions. A fooled conductor or worker can append to `owner_notes` with `ns-ledger set`. I checked that the feature guard allows `ns-ledger set "$NS_LEDGER" '.owner_notes += [...]'` (exit 0). The conductor then follows that text as the owner's, over the plan's scope and acceptance criteria, which turns untrusted text into instructions (checklist 4, R-SEC-3). The owner accepted this as Q1. Gates, the guard, protected paths and the `review-round`/`merge` checks still hold, so it does not block. But the sentence "bounded the same way" as `stop_requested` is inaccurate: `stop_requested` can only make a run do less, while a note can widen what the conductor does. · Say that a forged note can change scope and acceptance criteria but not gates, the guard or protected paths, and that the owner sees every note in `ns report`. Keep the Q1 alternative as a follow-up: the guard refuses `ns-ledger set` programs and Edit/Write on `ledger.yaml` that name `owner_notes`.
- non-blocking · bin/ns-conductor:691 · Any agent can consume the owner's notes. `ns-conductor owner-notes <id>` takes only the id and `load_run` makes no worker check. The guard allows the command (checked, exit 0). A phase worker (`NS_WORKER=1`, `NS_LEDGER` empty) can run it, or run `ns-ledger set '.owner_notes[].read = true'` (guard allows it, checked), and so hide an owner instruction from the conductor. The notes stay visible in `ns report` (checklist 5). · Make `owner-notes` refuse when `NS_WORKER` is set (defence in depth). In docs/security.md, say that `ns report` is where the owner checks that a note was read.
- non-blocking · bin/ns-conductor:696 · Only CR and LF are folded before note text enters the conductor's context. Other C0 control characters, ESC sequences, DEL and U+0085/U+2028/U+2029 pass through unchanged. Impact is low because the text is the owner's, or falls under the accepted Q1 risk (checklist 9). · Fold `[\u0000-\u001f\u007f\u0085  ]+` to one space.
- non-blocking · bin/lib/ns-note.sh:33 · `set`, `get` (length) and `event` each take the ledger lock separately. When two notes are written at the same time, the `owner note <n> added` event and the printed `n` can name the wrong note. The stored notes are still correct: they are append-only and none is lost (checklist 10, audit accuracy). · Compute `n` and append the event in the same `set` program, or document that `n` is approximate under concurrent writes.
- non-blocking · bin/ns-ledger:228 · The new commit of the `push-failed` event goes through `git_retry`, which calls `ns_die` on any failure other than `index.lock`. If that commit fails, `checkpoint --push`, and with it `ns note`, exits non-zero, although the docs and AC-1 say it still exits 0. It fails loudly, not unsafely (checklist 10). · Commit with `|| ns_warn "..."`, or document the exit code.
- non-blocking · bin/ns-ledger:224 (pre-existing, newly reached from an owner command) · `checkpoint --push` pushes `HEAD:refs/heads/<.branch>`, and `.branch` comes from the ledger, which agents can write (schema: any non-empty string). `ns note` now runs this push from the owner's shell. It adds no new capability: the push is not a force push, it runs as the same user with the same token that the conductor's own `checkpoint --push` already uses, and the GitHub ruleset requires a pull request on the base branch. Still, a forged `.branch` would turn the owner's `ns note` into a push to that branch (checklists 5 and 2). · In `cmd_checkpoint --push`, refuse a `.branch` that equals the profile's base branch or the default branch, or that does not match the run branch pattern (follow-up, not part of this change).

Required control carried to the integrator (not graded against this head, by scope):

- [ ] The plan's trust-boundary ADR exists with the content p3-retire specifies, including Q1 among the rejected alternatives and the consequence that a forged note is bounded by gates, the guard and protected paths but not by scope. The number must be **0011**, because `docs/adr/0010-desk-content-policy.md` is already on `origin/main`. p3's stop condition ("docs/adr/0010-*.md already exists") fires as written, so the integrator must renumber the file, the README row and p3's checks. The README row and the CHANGELOG entry are also added, and the plan is retired. Without this ADR, the accepted residual risk Q1 is recorded only in a plan that is about to be deleted.

## Checked and clean

- Secrets (checklist 1): the diff has no match for the token ERE, no `Authorization:` header and no private key block. `push-failed` notes carry only git's first error line.
- Injection and quoting (checklists 2 and 3):
  - `ns-note.sh:31-33` splices the output of `jq -cn --arg t "$text" '$t'` into the `ns-ledger set` program. I checked these payloads against jq: `") | .gate = null | ("`, `\(.gate)`, `\\(1+1)`, `$__loc__`, `"+(input)+"`, a single quote, and text with newlines, C0 characters and DEL. In every case the text round-tripped exactly and `.gate` was unchanged, so nothing is interpolated or executed.
  - `cmd_set` passes the program to jq as one argument, with no `eval`.
  - In `ns-conductor:701`, `${idx}` comes from `jq -c 'map(.k)'` over integer keys only.
  - `[[ $1 != -* ]]` stops option injection through `<id>`. All expansions are quoted.
- Owner-only guard (checklists 5 and 12): I ran the feature branch's `guard.sh` against 21 command forms.
  - Blocked with "ns note is the owner's command": a plain call, an absolute path, `env`, `bash -c`, `eval` with split quoting, a variable subcommand, `n\ote`, `$'\x6eote'`, and Python `subprocess`.
  - Blocked with "cannot tell which ns command": `$(...)` and `xargs`.
  - Blocked as library or `NS_HOME` forms: `bin/lib/ns-note.sh` and `ns_note_main`.
  - Allowed by the guard but rejected by `bin/ns`, so not a bypass: `ns NOTE` (fails `^[a-z][a-z0-9-]*$`) and `ns -- note` (unknown command).
  - Allowed as designed: `ns note --help`, `ns-conductor owner-notes`, `ns-conductor note` and `ns stop`. `bin/ns` treats `--help` only as the sole argument.
- Ledger writes: every write goes through `ns-ledger`, under the lock and with schema validation. `owner_notes` items are `additionalProperties: false`, with a non-empty `text` and a validated `time`. `owner-notes` marks read exactly the indices it printed. Commits are limited to the ledger directory.
- Push behaviour: `ns note` uses `checkpoint --push`, which is not a force push, pushes to the run branch and records `push-failed` without aborting (see the exit-code finding above). Git hooks cannot be used to run code during the owner's commit: `core.hooksPath` writes are guarded, and the guard's own git calls null it.
- Report (checklist 11): `.text | esc` escapes `\`, `|` and newlines in the Markdown table. The desk serves `*.md` as text/plain (ADR 0010-desk-content-policy).
- Supply chain (checklist 7): there are no new dependencies.

## Risk zones

| Zone | Touched | Required | Met |
|---|---|---|---|
| hooks (`plugins/ns/hooks/**`) | yes: `plugins/ns/hooks/lib/guard.py:397-404` adds `note` to `OWNER_SUBS`, plus `tests/bats/hooks.bats` | sec-compliance review | Yes, this review. The guard change adds one entry to a set, and dynamic forms fail closed (probed above). The tests cover the blocked and allowed forms. |
| credentials (`bin/lib/config.sh`, `bin/ns-launch`) | no (`ns-note.sh` only sources `config.sh`) | none | n/a |

Protected paths (`.github/workflows/**`) are not touched.

## Compliance

The profile docs name no compliance regime, so this review has no compliance table.

## Summary

The owner-only guard for `ns note` holds against every form I probed. The note text cannot inject into the jq program, the report or the shell. Ledger writes stay on the locked, schema-validated `ns-ledger` path, and the push is a normal push to the run branch.

The remaining risk is by design (owner decision Q1): agents can forge or consume owner notes through `ns-ledger set` and `ns-conductor owner-notes`. Gates, the guard and protected paths bound a forged note; scope does not. None of the findings blocks this head.

The ADR that records this trust-boundary decision is still required. The integrator must add it in p3-retire, numbered 0011 because 0010 is taken. This approval assumes that happens.

REVIEW verdict=approve head=608f0111555371149a4a4d29e1a43e1b265616a5
