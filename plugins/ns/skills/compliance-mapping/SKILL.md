---
name: compliance-mapping
description: Method for mapping a regime's requirements to controls and evidence in a table; load when a profile's docs name a compliance regime.
user-invocable: false
---

# Compliance mapping

Use this only when the profile's docs (security policy, contributing guide, compliance notes) name a regime or standard. Do not invent a regime.

## Method

1. Name the regime and version exactly as the project's docs do, and cite the doc.
2. List the requirements that the change can affect. Take them from the project's own docs; do not paraphrase from memory a standard you have not read in the repo.
3. For each requirement find the control: the code, config, process or test that satisfies it, with `path:line` or a doc section.
4. For each control find the evidence: a test, a CI check, a log, a commit or a doc that shows it works. A control with no evidence is a gap.
5. Write the table:

   | Requirement | Control | Evidence | Status |
   | --- | --- | --- | --- |
   | (id and short text) | (path:line or doc) | (test, check or doc) | met, partial or gap |

6. A `gap` or `partial` on a requirement the diff touches is a finding: `blocking` if the change makes things worse or removes a control, otherwise `non-blocking` with the fix.

## Wording

The table is a working aid, not a certification. State in the output: "This mapping is not a certification or an audit result; it shows how this change relates to the named requirements as far as the repository shows." Never write that the project "is compliant" or "certified".
