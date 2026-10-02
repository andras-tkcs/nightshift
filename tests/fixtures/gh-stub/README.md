# gh stub

A stand-in for the `gh` CLI used by the bats tests. Put this directory on `PATH` (the bats helpers do).

Every call appends `gh <args joined by spaces>` to `$GH_STUB_LOG`, followed by ` [token]` when `GH_TOKEN` is non-empty. The token value is never written.

Built-ins:

- `gh auth status` exits with `${GH_STUB_AUTH_EXIT:-0}`.
- `gh repo clone <owner>/<repo> [<dir>] [-- ...]` runs `git clone -q "$GH_STUB_REMOTES/<owner>/<repo>.git" <dir or repo name>`.

Everything else is looked up in `$GH_STUB_RESPONSES/map`. Each line has three tab-separated fields:

```
<exit code>	<response file or ->	<ERE>
```

The ERE is matched against the joined arguments; the first match wins. The response file is relative to the map's directory and is printed as is (`-` prints nothing); the stub then exits with the code. When the arguments contain `--jq <expr>` or `-q <expr>`, the flag and expression are removed before matching and the response is piped through `jq -r <expr>`.

No match prints `gh-stub: no response for: <args>` to stderr and exits 99.

Response sets live in `responses/<scenario>/`. Their JSON follows the GitHub REST API documentation and is hand-written.
