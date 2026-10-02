# Test stubs

Each stub is owned by one phase; later phases only use them. Every stub appends `<name> <args>` to `$NS_STUB_LOG`.

| Stub | Phase | Behaviour |
|---|---|---|
| `tests/fixtures/gh-stub/gh` | p08 | See the `ns-gh` design (D18) |
| `tests/fixtures/bin/tmux` | p09 | Sessions as files in `$TMUX_STUB_DIR`: `new-session -d -s N [-c DIR] [-e VAR=value]... CMD` creates `N` containing `DIR`, one `ENV VAR=value` line per `-e` and `CMD`; `has-session -t N`; `kill-session -t N`; `list-panes -t N -F ...` prints `${TMUX_STUB_PANE_PID:-999999}`; `attach-session -t N` prints `attached N`; `ls`. A leading `=` of the `-t` target is stripped, and a target must equal a session name exactly |
| `tests/fixtures/bin/claude` | p09 | Records args (one per line), stdin, the cwd and `token=set\|unset` (whether `GH_TOKEN` is non-empty, never its value) in `${CLAUDE_STUB_DIR:-$(dirname "$NS_STUB_LOG")/claude}` as `call-<n>.args`/`.stdin`/`.env`; `CLAUDE_STUB_MODE`: `ok` (default; prints `{"type":"result","subtype":"success","is_error":false,"result":"${CLAUDE_STUB_RESULT:-ok}"}`), `fail` (exit 1), `script:<file>` (runs the file with bash in the cwd, then prints the ok line); `plugin validate` exits 0 |
| `tests/fixtures/bin/curl` | p13 | Prints `${CURL_STUB_HTTP_CODE:-200}` when `-w` is present; exit `${CURL_STUB_EXIT:-0}` |
| `tests/fixtures/bin/systemctl` | p27 | `is-active <units...>` prints `inactive` and exits 3 for any unit listed in `$SYSTEMCTL_STUB_INACTIVE`, else `active`; `--user` ignored |
| `tests/fixtures/bootstrap/bin/*` | p29 | `apt-get`, `runuser`, `tailscale`, `getent`, `caddy`, `cloudflared`, `sshd`, `systemctl`, `openssl`, `id` (only on the bootstrap test's PATH) |
