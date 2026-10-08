| Check | Result | Detail |
|---|---|---|
| python lint (`tests/lint`) | PASS | tree a223f2ec |
| python test (`bats --jobs "$(nproc)" tests/bats`) | FAIL | only `kill.bats` "ns_kill_group gives up after about 2 s" (#58) failed under suite load (`[ $(($(date +%s) - start)) -le 5 ]`); it passes when run alone. Unrelated to the diff. |
| judgement rows | n/a | profile has no docs.dod |
