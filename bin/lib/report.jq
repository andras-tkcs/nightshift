# Run report: ledger JSON in, Markdown out. Arguments: $end (epoch seconds, end of the
# run or now), $cause (one line from escalation.md, may be empty).
# Everything taken from the ledger is data: it is escaped for a Markdown table cell.

def ep: fromdateiso8601;
def esc: gsub("\\\\"; "\\\\") | gsub("\\|"; "\\|") | gsub("[\r\n]+"; " ") | gsub("^ +| +$"; "");
def two: tostring | if length < 2 then "0" + . else . end;
def dur:
  (if . < 0 then 0 else . end) as $s
  | if $s >= 3600 then "\($s / 3600 | floor)h \($s % 3600 / 60 | floor | two)m"
    elif $s >= 60 then "\($s / 60 | floor)m"
    else "\($s)s" end;
def stamp: strftime("%Y-%m-%d %H:%M");
def first_word: split(" ")[0];
def overlap($a; $b; $list):
  [$list[] | ([.[1], $b] | min) - ([.[0], $a] | max) | select(. > 0)] | add // 0;
# remove the wait intervals from one interval
def minus($waits):
  reduce $waits[] as $w ([.];
    [.[] as $p
     | (if $w[0] > $p[0] then [$p[0], ([$p[1], $w[0]] | min)] else empty end),
       (if $w[1] < $p[1] then [([$p[0], $w[1]] | max), $p[1]] else empty end)]
    | map(select(.[1] > .[0])));

.events as $raw
| ($raw | map(. + {t: (.time | ep)})) as $ev
| ($ev | length) as $n
# waits: first gate event to the next approved event
| (reduce $ev[] as $e ({open: null, list: []};
    if $e.type == "gate" and .open == null then
      .open = {s: $e.t, gate: (($e.note | capture("^gate (?<g>[0-9.]+)") | .g) // "?")}
    elif $e.type == "approved" and .open != null then
      .list += [.open + {e: $e.t}] | .open = null
    else . end)) as $w
| ($w.list + (if $w.open then [$w.open + {e: $end}] else [] end)) as $waits
| ($waits | map([.s, .e])) as $wi
# dead gaps: a resume that is not the hand-off from the queue follows a gap with nothing running
| ([range(1; $n) | select($ev[.].type == "resumed" and ($ev[.].note != "resumed from queued"))
    | [$ev[. - 1].t, $ev[.].t] | minus($wi)[]]) as $dead
| (.created | ep) as $t0
| ($t0) as $start
# planning ends at gate 1, else at the first phase-start or review, else at the end
| ([($waits | map(select(.gate == "1")) | .[0].s),
    ($ev | map(select(.type == "phase-start" or .type == "review") | .t) | .[0]),
    $end] | map(select(. != null)) | min) as $plan_end
| def row($label; $s; $e; $own_wait):
    {label: $label, s: $s, e: ([$e, $s] | max)}
    | .wall = (.e - .s)
    | .wait = (if $own_wait then .wall else overlap(.s; .e; $wi) end)
    | .dead = overlap(.s; .e; $dead)
    | .active = ([.wall - .wait - .dead, 0] | max);
  (([row("planning"; $start; $plan_end; false)]
   + [$waits[] | row(if .gate == "1.5" then "escalation (gate 1.5)" else "gate \(.gate) wait" end; .s; .e; true)]
   + [$ev | to_entries[] | select(.value.type == "phase-start") | . as $p
      | ($p.value.note | first_word) as $ph
      | (([$ev[$p.key + 1:][] | select(.type == "phase-end" and (.note | first_word) == $ph) | .t] | .[0]) // $end) as $e
      | row("\($ph) implement"; $p.value.t; $e; false)]
   + [$ev | to_entries[] | select(.value.type == "review") | . as $r
      | ($r.value.note | first_word) as $ph
      | ([$ev[0:$r.key][] | select((.type == "phase-end" or .type == "review") and (.note | first_word) == $ph) | .t] | last) as $s
      | select($s != null)
      | row("\($ph) review " + ($r.value.note | sub("^[^ ]+ "; "") | sub(" (approve|changes)$"; "")); $s; $r.value.t; false)]
   + [$ev | to_entries[] | select(.value.type == "merge") | . as $m
      | ($m.value.note | first_word) as $ph
      | ([$ev[0:$m.key][] | select((.type == "phase-end" or .type == "review") and (.note | first_word) == $ph) | .t] | last) as $s
      | select($s != null)
      | row("\($ph) merge"; $s; $m.value.t; false)]
  ) | sort_by(.s)) as $rows
| ($waits | map(select(.gate == "1.5"))) as $esc
| ($end - $t0) as $wall
| ($waits | map(.e - .s) | add // 0) as $waiting
| ($dead | map(.[1] - .[0]) | add // 0) as $deadsum
| ([$ev[] | select(.type == "review")] | length) as $rounds
| .budget as $b
| ($esc | length) as $nesc
| [
    "# Run report: \(.id | esc)",
    "",
    "- Project: \(.project | esc)",
    "- Tier: \(.tier // "none" | esc)",
    "- State: \(.state | esc)",
    "- Pull request: \(.pr // "none" | esc)",
    "- Times are UTC, built from the run ledger only.",
    "",
    "## Summary",
    "",
    "| Measure | Value |",
    "|---|---|",
    "| Wall time | \($wall | dur) |",
    "| Active time | \([$wall - $waiting - $deadsum, 0] | max | dur) |",
    "| Waiting for you | \($waiting | dur) |",
    "| Dead or stopped | \($deadsum | dur) |",
    "| Budget | \(if $b == null then "none" else "\($b.used // 0) h of \(if $b.limit == null then "no limit" else "\($b.limit) h" end)" end) |",
    "| Review rounds | \($rounds) |",
    "| Escalations | \($nesc) |"
  ]
  + (if $nesc > 0 then
      ["", "Escalations:", ""]
      + [$esc | to_entries[]
         | "- \(.value.s | stamp) (gate \(.value.gate)): \(if .key == ($nesc - 1) and $cause != "" then ($cause | esc) else "cause not recorded" end)"]
    else [] end)
  + ["", "## Timeline", "", "| Step | Start | Wall | Active | Waiting |", "|---|---|---|---|---|"]
  + [$rows[] | "| \(.label | esc) | \(.s | stamp) | \(.wall | dur) | \(.active | dur) | \(.wait | dur) |"]
  | .[]
