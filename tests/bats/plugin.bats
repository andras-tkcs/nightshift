load helpers

setup() { ns_test_setup; }

# Print the value of a frontmatter key of a Markdown file.
fm() {
  awk -v k="$2" '
    NR==1 && $0!="---" {exit}
    NR>1 && $0=="---" {exit}
    NR>1 { i=index($0, ":"); if (i>0 && substr($0,1,i-1)==k) { v=substr($0,i+1); sub(/^[ \t]+/,"",v); print v; exit } }
  ' "$1"
}

@test "every agent has valid frontmatter and the four required sections" {
  local f name n=0 h
  for f in "$NS_REPO_ROOT"/plugins/ns/agents/*.md; do
    [ -e "$f" ] || continue
    n=$((n + 1))
    name="$(basename "$f" .md)"
    [ "$(fm "$f" name)" = "$name" ] || { echo "$f: name != $name"; return 1; }
    [ -n "$(fm "$f" description)" ] || { echo "$f: empty description"; return 1; }
    case "$(fm "$f" model)" in haiku|sonnet|opus|fable) ;; *) echo "$f: bad model"; return 1 ;; esac
    [ -n "$(fm "$f" tools)" ] || { echo "$f: empty tools"; return 1; }
    for h in "## Inputs" "## Outputs" "## Procedure" "## Stop conditions"; do
      grep -qx "$h" "$f" || { echo "$f: missing $h"; return 1; }
    done
  done
  [ "$n" -gt 0 ]
}

@test "every skill has valid frontmatter" {
  local f dir n=0
  for f in "$NS_REPO_ROOT"/plugins/ns/skills/*/SKILL.md; do
    [ -e "$f" ] || continue
    n=$((n + 1))
    dir="$(basename "$(dirname "$f")")"
    [ "$(fm "$f" name)" = "$dir" ] || { echo "$f: name != $dir"; return 1; }
    [ -n "$(fm "$f" description)" ] || { echo "$f: empty description"; return 1; }
    case "$dir" in
      run|plan|implement|dod|status|resume|review) ;;
      *) [ "$(fm "$f" user-invocable)" = "false" ] || { echo "$f: user-invocable must be false"; return 1; } ;;
    esac
  done
  [ "$n" -gt 0 ]
}

@test "no file under plugins mentions the seed project" {
  run grep -rli "privacy""fence" "$NS_REPO_ROOT/plugins"
  [ "$status" -eq 1 ]
}

@test "the conductor reads owner notes wherever it calls should-stop" {
  local r="$NS_REPO_ROOT/plugins/ns/skills/run/SKILL.md" f
  [ "$(grep -c 'should-stop' "$r")" -ge 8 ]
  for f in "$r" "$NS_REPO_ROOT/plugins/ns/agents/conductor.md" "$NS_REPO_ROOT/plugins/ns/skills/implement/SKILL.md"; do
    grep -q 'should-stop' "$f" || { echo "$f: no should-stop"; return 1; }
    [ "$(grep 'should-stop' "$f" | grep -vc 'owner-notes')" = 0 ] || { echo "$f: should-stop without owner-notes"; return 1; }
  done
  grep -q '^4\. Set state running:.*ns-conductor owner-notes <id>' "$r"
  grep -qF "It overrides the plan's scope" "$r"
  grep -qF 'It never releases a gate, lifts the guard, or allows edits to protected paths' "$r"
}
