# Checks failed for p1-caddy-bootstrap

`bats --jobs "$(nproc)" tests/bats` fails (exit 1):

not ok 39 step 1 with a failing apt-get does not report changed and exits non-zero
# (in test file tests/bats/bootstrap.bats, line 425)
#   `printf '%s\n' "$output" | grep -E '^\[1/11\].*needs you: apt-get failed'' failed

This existing case must pass unchanged. Probably your D3 guard or the new check_1 logic changes the output of step 1 when apt-get fails (or the test tree lacks Caddyfile.d). Fix the code in check_1/apply_1 (not the existing assertion), rerun the full suite, and push.
