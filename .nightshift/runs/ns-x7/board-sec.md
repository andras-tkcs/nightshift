# Board: security and compliance review, ns-x7 (post)

Scope: `git diff origin/main...origin/feature/x7` at `58b95c3` (20 files), read in full, plus the code around it (`bin/ns`, `bin/ns-ledger` `cmd_set`/`cmd_checkpoint`/`git_retry`, `bin/ns-conductor` worker launch, `bin/lib/report.jq` `esc`). Inputs used: the diff, `docs/ns-x7-plan.md`, `RUN/acceptance.md`, `.claude/project-profile.yaml`, `docs/security.md`. No worker log or reasoning was read.

## Findings

- blocking · docs/ns-x7-plan.md:167 (missing docs/adr/0011-*.md) · The plan says this change moves a trust boundary (a new instruction channel into the conductor) and that ADR "Owner notes reach the conductor through the ledger" must record it, including the owner's Q1 decision to leave agent writes to `owner_notes` unguarded. The diff has no such ADR: phase p3-retire is not in the ledger and ADR number 0010 is already taken by `docs/adr/0010-desk-content-policy.md`. The accepted residual risk exists only in the plan, which is meant to be deleted (checklist 5, missing required control). · Add `docs/adr/0011-owner-notes-channel.md` with the content p3 specifies (Q1 among the rejected alternatives, consequences as in the plan), add its row to `docs/adr/README.md`, add the CHANGELOG entry and retire the plan, as p3 describes.
- non-blocking · docs/security.md:128 · Agents can still forge owner instructions. A fooled conductor or worker can append to `owner_notes` with `ns-ledger set` (guard allows it; confirmed: `ns-ledger set "$NS_LEDGER" '.owner_notes += [...]'` passes the feature guard), and the conductor then follows that text as the owner's, over the plan's scope and acceptance criteria. This launders untrusted text into instructions (checklist 4, R-SEC-3). The owner accepted it as Q1, and gates, the guard, protected paths and the `review-round`/`merge` checks still hold, so this is not blocking. But "bounded the same way" as `stop_requested` is wrong: `stop_requested` can only make a run do less, while a note can widen what the conductor does. · Change the sentence to say that a forged note can change scope and acceptance criteria but not gates, the guard or protected paths, and that the owner sees every note in `ns report`. Follow-up: the Q1 alternative (guard refuses `ns-ledger set` programs and Edit/Write on `ledger.yaml` that name `owner_notes`).
- non-blocking · bin/ns-conductor:691 · Any agent can consume the owner's notes. `ns-conductor owner-notes <id>` takes only the id (no `NS_LEDGER`), the guard allows it, and it marks notes read. A phase worker (`NS_WORKER=1`, `NS_LEDGER` empty) that runs it, or `ns-ledger set '.owner_notes[].read = true'`, hides an owner instruction from the conductor. The notes stay visible in `ns report` (checklist 5). · Make `owner-notes` refuse when `NS_WORKER` is set (defence in depth, as a worker can unset it), and say in docs/security.md that `ns report` is where the owner checks that a note was read.
- non-blocking · bin/ns-conductor:696 · Only CR and LF are folded before note text enters the conductor's context. Other control characters (ESC sequences, other C0 characters, DEL) and Unicode line separators (U+0085, U+2028, U+2029) pass through unchanged. Low impact, because the text is the owner's or falls under the accepted Q1 risk (checklist 9). · Fold `[\u0000-\u001f\u007f\u0085  ]+` to a space.
- non-blocking · bin/lib/ns-note.sh:27 · `set`, `get` (length) and `event` each take the ledger lock separately. If another note is written in between, the `owner note <n> added` event and the printed `n` can name the wrong note. The stored notes are still correct (append-only, no loss) (checklist 10, audit accuracy). · Take `n` in the same `set` (for example, record the event inside the set program), or document that `n` is approximate under concurrent writes.
- non-blocking · bin/ns-ledger:228 · The new commit of the `push-failed` event goes through `git_retry`, which calls `ns_die` on failures other than `index.lock`. A failed commit therefore makes `checkpoint --push` exit non-zero, against the documented "still exits 0". This fails loud rather than unsafe (checklist 10). · Use `|| ns_warn` for that commit, or document the exit code.

Checked and clean:
- Secrets (checklist 1): the diff has no match for the token ERE, no `Authorization:` header and no key block. `push-failed` notes carry git's first error line; remotes hold no token in their URL.
- Injection and quoting (checklists 2 and 3): `ns-note.sh:25` splices `jq -cn --arg` output into the `ns-ledger set` program. A JSON string is a valid jq string literal and `\(` arrives as `\\(`. I checked quotes, backslashes, `\(.x)`, `$`, C0 characters, DEL, tab, non-ASCII and invalid UTF-8: all round-trip unchanged except invalid UTF-8, which becomes U+FFFD (lossy, not exploitable). In `ns-conductor:701`, `${idx}` comes from `jq -c 'map(.k)'` over integer keys only. `[[ $1 != -* ]]` stops option injection into `<id>`. A text over about 128 KB fails at exec (E2BIG) before anything is written, so it fails closed.
- Owner-only guard (checklists 5 and 12): I probed the feature guard with 17 forms. All of these were blocked with "ns note is the owner's command": `xargs`, `find -exec`, `timeout`, `nice`, `command`, `exec`, `sudo -u`, `parallel`, the quoted forms `"no"te`, `$'note'` and `no\te`, the variable `N=note; ns $N`, a `$(...)` argument, and `--help;` chained. Library forms (`bin/lib/ns-note.sh`, `ns_note_main`) are blocked by the existing `LIB_RE`/`FUNC_RE`. `ns -- note` is allowed by the guard, but `bin/ns` rejects `--` as an unknown command, so it is not a bypass. `ns note --help`, `ns-conductor note` and `ns-conductor owner-notes` stay allowed, as designed.
- Ledger writes: every write goes through `ns-ledger` under `flock` with schema validation. `owner_notes` items are `additionalProperties: false` with a non-empty `text`. `owner-notes` marks exactly the indices it printed, so a note added in between stays unread. The commit is limited to the ledger directory.
- Report (checklist 11): `.text | esc` escapes `|`, `\` and newlines. `ns report` writes Markdown to the terminal, and the desk serves `*.md` as text/plain (ADR 0010-desk-content-policy).
- Supply chain (checklist 7): no new dependencies.

## Risk zones

| Zone | Touched | Required | Met |
|---|---|---|---|
| hooks (`plugins/ns/hooks/**`) | yes: `plugins/ns/hooks/lib/guard.py:397-404` (`note` added to `OWNER_SUBS`) and `tests/bats/hooks.bats` | sec-compliance review | Yes, this review. The guard change is one set entry and fails closed on dynamic forms (probed above). The tests cover the blocked and allowed forms. |
| credentials (`bin/lib/config.sh`, `bin/ns-launch`) | no (`ns-note.sh` only sources `config.sh`) | none | n/a |

Protected paths (`.github/workflows/**`): not touched.

## Compliance

The profile docs name no compliance regime, so there is no compliance table.

## Summary

The owner-only guard for `ns note` holds against every form I tried. The ledger write is injection-safe and goes through the locked, schema-validated `ns-ledger` path. The remaining risk is by design: agents can forge or consume owner notes through `ns-ledger set` and `ns-conductor owner-notes` (owner decision Q1). It is bounded by gates, the guard and protected paths, but not by scope. The one blocking item: the ADR that records this trust-boundary decision is missing from the diff (p3 did not run, and number 0010 is taken). Add it as 0011, together with the rest of p3.

REVIEW verdict=changes
