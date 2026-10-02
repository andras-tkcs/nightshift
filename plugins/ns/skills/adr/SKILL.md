---
name: adr
description: Architecture decision record format (Nygard template), when one is needed, numbering and the status lifecycle; load when writing or reviewing an ADR.
user-invocable: false
---

# ADR

An architecture decision record captures one decision, its context and its consequences, so a later reader need not guess why.

## When an ADR is needed

Write one when the change does any of these: adds a trust boundary or changes who can do what; adds a dependency, service or storage format; changes a public interface or file format; picks one of several reasonable designs that a future change could reverse; or is T3. Do not write one for a bug fix, a refactor that keeps interfaces, or a choice any competent reader would make.

## Numbering and location

Records live in the profile's `docs.adr_dir` as `NNNN-<slug>.md`. `NNNN` is the highest existing number plus one, zero-padded to four digits. Never reuse or renumber a record. During a run the draft is `RUN/adr-<slug>.md`; it moves to `docs.adr_dir` with its number when the run is integrated.

## Template (Nygard)

```markdown
# ADR NNNN: <short noun phrase>

Status: Proposed
Date: YYYY-MM-DD

## Context
The forces at play: requirements, constraints, what exists. Facts, not advocacy.

## Decision
"We will ..." in full sentences.

## Consequences
What becomes easier and harder, new obligations, risks, follow-ups.

## Alternatives considered
Each rejected option and the reason.
```

## Status lifecycle

`Proposed` (draft, awaiting the owner), then `Accepted` (the owner approved; set at merge), then `Superseded by ADR MMMM` when a later record replaces it. A record may also be `Rejected`. Accepted records are not edited except for the status line; a changed decision is a new ADR that supersedes the old one, and the old one gets a link to it.

## Rules

- One decision per record, short (one page).
- Link the acceptance criteria or issue that forced the decision.
- Do not decide owner-level questions; list them under Context as open.
