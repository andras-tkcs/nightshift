# ns-5 design (T2): self-contained HTML check and desk CSP

## Modules touched

- `bin/lib/desk.sh`: rewrite `ns_desk_check_html` (AC-1..AC-5). Same name, same 0/1 contract; only caller is `bin/lib/ns-publish.sh:57`.
- `bin/lib/ns-publish.sh:58`: message becomes `$name: HTML must be self-contained (no scripts, no external resources)`. Prefix unchanged (AC-1); update the assertion at `tests/bats/desk.bats:64`.
- `templates/caddy/Caddyfile.tmpl`: one `header Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; img-src data:"` line in the `@TS_HOST@:8443` block (next to `X-Robots-Tag`) and in the `http://127.0.0.1:8080` block. The `@TS_HOST@` block stays as it is (AC-6).
- Tests: `tests/bats/desk.bats`, `tests/bats/bootstrap.bats`.
- Docs: `docs/spec.md` R-DSK-2, the `ns publish` paragraph in `docs/usage.md:171`, `plugins/ns/skills/review-desk/SKILL.md:29`, the #5 note in `docs/architecture.html` (around lines 1861 and 1871: the template now carries the header), and a `CHANGELOG.md` `[Unreleased]` entry under Security (AC-7).

## Interfaces

`ns_desk_check_html <file>` returns 1 when any rule below matches, else 0. The whole file is one record: `grep -Eiqz` (GNU grep 3.12 on ns-main), so `[[:space:]]` and `[^>]` also match newlines (AC-2), and `-i` covers letter case (AC-3). Keep the patterns in a local array in `desk.sh`, one per rule, with a comment saying what each refuses. Refuse when:

1. The file contains a NUL byte. `-z` splits records at NUL, which would reopen the multiline bypass. This also refuses UTF-16 files that grep cannot read.
2. Any `<script` (AC-1d, AC-3).
3. Any `<link`, `<base`, `<iframe`, `<frame`, `<object` or `<embed` tag, whatever its attributes. These tags only load things, and a self-contained page has no use for them. This covers AC-1a and AC-2 for `<link` without parsing attributes.
4. `src` or `srcset` on any element (preceded by whitespace, `/` or a quote), then `=`, then an optional quote and whitespace, then a value starting with `http:`, `https:`, `//`, `\` or `/\`, or with `&` (an entity-encoded scheme). This covers AC-1b, AC-1c and AC-4.
5. `href` on any tag other than `<a>` (including SVG `<image>`/`<use>` and `xlink:href`), with the same remote value test as rule 4. Inside the tag, match quoted strings as whole units (`([^>"']|"[^"]*"|'[^']*')*`) so that a quoted `>` cannot end the tag early. `<a href>` is allowed by the decision below.
6. `@import` anywhere (existing rule).
7. CSS `url(` followed by an optional quote and whitespace, then `http:`, `https:` or `//`. Inline `background:url(//evil)` loads off the page today. AC-1 does not list it, but it falls under the goal statement.
8. An inline event handler: `on[a-z]+[[:space:]]*=` inside a tag, using the same tag-body form as rule 5 so prose like "one = two" passes. The goal is "send anything", and `<img onerror=fetch(..)>` is script without `<script`.
9. `javascript:` anywhere, and `http-equiv` with the value `refresh` (an automatic request off the page).

### The href decision (from the acceptance assumption)

Plain `<a href="https://...">` navigation links stay allowed. Only resource-loading hrefs are refused: rule 3 refuses `<link>` and `<base>` outright, and rule 5 refuses remote hrefs on every tag other than `<a>`. The reasons are that the handoff template (`plugins/ns/skills/handoff-report/template.html:42`) links to the PR on purpose, and that CSP does not govern navigation. The owner can still choose to refuse every absolute href (see the open question).

## Data

There are no new files, schemas or migrations, and `.published` and `index.md` are unchanged. Desk files that were published before this change are not rechecked.

## Tests

`tests/bats/desk.bats` (publish path: exit 1, the message, no file on the desk):
- One case each for AC-1 a-d.
- `<link` with `href=` on the next line, and `<script` with `src=` on the next line (AC-2).
- `<SCRIPT>alert(1)</SCRIPT>` (AC-3).
- `<img src='//x'>` and `<img src=http://x>` (AC-4).
- `<img src="data:..." onerror="fetch(1)">`, `<p style="background:url(//x)">`, and `<link title=">" href=//x>`, for the extra rules and the quoted-`>` case.
- A file with a NUL byte.
- Pass cases (AC-5): the existing "inline style only" case, then inline `<style>` plus `<img src="data:image/png;base64,...">` plus `<a href="https://github.com/o/r/pull/1">`. Also: `sed 's#{{PR_URL}}#https://github.com/o/r/pull/1#g'` on the handoff template, then call `ns_desk_check_html` directly (source the libs as other cases do) and expect 0.
- Prose such as `<p>one = two, see https://x</p>` passes, to guard against false positives.

`tests/bats/bootstrap.bats`, next to the case at line 246, a new case "the rendered Caddyfile sends the CSP on the HTML listeners only":
- Render with a fixed host.
- Cut each block with awk from its opening line to the first `^}`. Assert the exact header line in the `:8443` and `:8080` blocks and that it is absent from the bare-host block.
- If `command -v caddy` finds caddy, run `caddy adapt --config "$out" --adapter caddyfile` and expect exit 0; otherwise `skip` that part (AC-6).

Before writing the code, check that the AC-1 cases fail against `origin/main`'s `desk.sh` (AC-1 check line). Afterwards, check that `tests/lint`, `bats tests/bats` and `tests/docs-check` pass (AC-8).

## Risks

- Regex check versus a real HTML parser: the check refuses the known bypass classes but is not a parser. Remaining evasions, such as a tab or newline inside a scheme (`ht<TAB>tps:`), CSS escapes, or rare loading attributes like `poster`, `data`, `action` and `formaction`, are left to the CSP. That split is why R-DSK-2 gets both layers. Name it in R-DSK-2.
- False positives: rule 9 refuses prose that contains `javascript:`, and rule 3 refuses a harmless `<link rel=canonical>`. Authors can escape the text (`javascript&#58;`). The handoff template passes, because it has only two `<meta>` tags, inline `<style>` and one `<a href>`.
- The CSP drops the inline-script features of Caddy's `browse` listing. This is accepted in acceptance.md. Relative images on desk pages stop loading (`img-src data:`), as intended.
- Fact correction to an acceptance assumption: `bootstrap.sh --upgrade` runs only steps 8-9 (`bin/bootstrap.sh:656-661`) and never rewrites the Caddyfile. The template change matters for a plain `bootstrap.sh` rerun, which rewrites it in step 1. Phrase the docs that way. This does not change any criterion.
- `grep -z` and `-E` alternations: GNU grep uses a DFA for these patterns (no backreferences), so there is no catastrophic backtracking.

## Rejected alternatives

- Python `html.parser` (stdlib, as in ADR 0004's helper pattern): it parses better, but it moves a shell check into Python, still needs URL normalising, and is more than T2 needs. Keep it in mind if evasions show up in practice.
- An allowlist (only `data:`/`#` values allowed in loading attributes): it is more robust, but it refuses relative paths, which the AC does not ask for. Left as an owner choice.
- Line-based grep with `tr '\n' ' '` first: the same effect as `-z` with an extra pipe, and it still has the NUL issue.
- Sanitising or rewriting the HTML: a non-goal.

## Open questions (owner)

- Should every absolute `href`, `<a>` included, be refused? That would require the handoff template to show the PR URL as text.
- Should the CSP be extended with `base-uri 'none'; form-action 'none'; frame-ancestors 'none'`, which `default-src` does not cover? AC-6 pins the exact header string, so this design keeps it as written.
