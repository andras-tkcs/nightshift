# Review: ns-144 phase p1-caddy-bootstrap, round 1

Range: origin/feature/144...origin/feature/144--p1-caddy-bootstrap (head bc5fdc43226f4c572e6c2bbda4f32265436311d9)

## Findings

- non-blocking · tests/bats/bootstrap.bats:287,296,323,339,352,366,381 · removing the `ns_xfail "ns:ns-144 acceptance" ` prefix left each test body at column 0 instead of the file's two-space indent · re-indent the seven bodies by two spaces in a later touch (no behaviour change).

No blocking findings.

## Summary

- Template (D1): the six lines are in the :8443 block after X-Robots-Tag and in the 127.0.0.1:8080 block after file_server browse, verbatim. :443 and :8444 are unchanged. A blank line plus `import /etc/caddy/Caddyfile.d/*.caddy` is the last line. Matches the AC greps (CSP count 2, import last).
- check_1 (D2) and apply_1 (D3): match the plan text line for line. They use the existing P and clean helpers and add no new helpers. Nothing else in bootstrap.sh changes. Caddyfile.d is only created (install -d -m 755), never written into, chmodded or removed. Snippet names are listed, the files are never opened, and control characters are dropped.
- Tests (D4): prepare_tree already had Caddyfile.d on the base (acceptance commit 6a21abd). The empty-tree case gets exactly the one grep line D4 asks for. The seven acceptance cases were committed on the base as strict expected failures. This phase removes only the ns_xfail prefixes and the helper, as the helper's own comment says to, so the tests failed first. No assertion was changed.
- The fix to "step 1 with a failing apt-get": the four assertions are unchanged (assert_failure 1, the "needs you: apt-get failed" line, no "changed" line). Only the PATH the test builds changes. It now also links tests/fixtures/bin/* (the tmux, claude, curl and systemctl stubs), with tests/fixtures/bootstrap/bin/* linked last so the bootstrap stubs still win (for example systemctl). caddy is still excluded. This is the stub set the other cases already get from setup(), so a host tmux session no longer blocks the step. It does not weaken the test.
- Untrusted text (R-SEC-3): none. The Cloudsmith URLs are pre-existing, outside the diff.
- Commit hygiene: three files, all in the phase's touches list. No .nightshift/ files, no secrets. Clear messages with #144.
- As briefed, I ran no checks (bats, lint, caddy adapt). The worker's acceptance evidence for those is not judged here.

REVIEW verdict=approve head=bc5fdc43226f4c572e6c2bbda4f32265436311d9
