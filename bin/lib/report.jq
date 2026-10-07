# Run report: ledger JSON in, Markdown out. Arguments: $end (epoch seconds, end of the
# run or now), $cause (one line from escalation.md, may be empty), $logs (a one-element
# array: what bin/lib/report_logs.py read from logs/<id>/, or [null] when it failed).
# Everything taken from the ledger and the logs is data: it is escaped for a Markdown table cell.

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
def dec($n): (. * $n | round) as $x | "\($x / $n | floor).\($x % $n | tostring | if length < 2 and $n == 100 then "0" + . else . end)";
# a value that is not a finite number is no data; 999950 and up is shown in M, never 1000.0k
def finite: type == "number" and (isinfinite or isnan | not);
def tok: if finite | not then "no data" elif . < 1000 then "\(. | floor)" elif . < 999950 then "\(. / 1000 | dec(10))k" else "\(. / 1000000 | dec(100))M" end;
def money: if finite | not then "no data" else "$" + dec(100) end;
# the cost cell of a timeline row: part of it has no cost when a session ended without a result
def rowcost: if .none == true then "no data" elif .part == true then "at least \(.cost | money)" else (.cost | money) end;
def sumtok: if . == null then null else .in + .out + .cr + .cw end;
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
      .open = {s: $e.t, gate: (($e.note | capture("^gate (?<g>[0-9.]+)") | .g) // "?"),
               q: (($e.note | capture("^gate [0-9.]+: waiting for the owner: (?<q>.+)$") | .q) // null)}
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
    {label: $label, s: $s, e: ([$e, $s] | max), kind: (if $own_wait then "wait" else "step" end)}
    | .wall = (.e - .s)
    | .wait = (if $own_wait then .wall else overlap(.s; .e; $wi) end)
    | .dead = overlap(.s; .e; $dead)
    | .active = ([.wall - .wait - .dead, 0] | max);
  (([row("planning"; $start; $plan_end; false)]
   + [$waits[] | row(if .gate == "1.5" then "escalation (gate 1.5)" else "gate \(.gate) wait" end; .s; .e; true)]
   + [$ev | to_entries[] | select(.value.type == "phase-start") | . as $p
      | ($p.value.note | first_word) as $ph
      | (([$ev[$p.key + 1:][] | select(.type == "phase-end" and (.note | first_word) == $ph) | .t] | .[0]) // $end) as $e
      | row("\($ph) implement"; $p.value.t; $e; false) + {kind: "impl", phase: $ph}]
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
  )) as $steps
# conductor work: running time (not waiting, not dead) that no other row covers, over a minute
| ([[$t0, $end] | minus($wi + $dead)[]]) as $running
| ([$steps[] | select(.kind != "wait") | [.s, .e]]) as $covered
| ([$running[] | minus($covered)[] | select(.[1] - .[0] > 60) | row("conductor work"; .[0]; .[1]; false)]) as $work
| (($steps + $work) | sort_by(.s) | to_entries | map(.value + {i: .key})) as $rows0
# tokens and cost from the logs: each message goes to one row
| ($logs[0]) as $L
| (if $L == null or ($L.agents | length) == 0 then null else $L end) as $L
| (if $L == null then [] else
    [$L.messages[] | . as $m
     | (if $m.phase != null then
          [$rows0[] | select(.kind == "impl" and .phase == $m.phase and .s <= $m.t)] | max_by(.s)
        else
          # the step it falls in, else a phase, else a wait; in a dead gap the last step
          # before it; before the first row the first row
          ([$rows0[] | select(.s <= $m.t and $m.t < .e)]) as $in
          | ([$in[] | select(.kind == "step")] | max_by(.s))
            // ([$in[] | select(.kind == "impl")] | max_by(.s))
            // ([$in[] | select(.kind == "wait")] | max_by(.s))
            // ([$rows0[] | select(.kind != "wait" and .s <= $m.t)] | max_by(.s))
            // ([$rows0[] | select(.s > $m.t)] | min_by(.s))
        end) as $r
     | {i: ($r.i // -1), tok: $m.tok, cost: $m.cost}]
  end) as $placed
| ($placed | group_by(.i)
   | map({key: (.[0].i | tostring),
          value: {tok: (map(.tok) | add), cost: (map(.cost // 0) | add), part: any(.[]; .cost == null), none: all(.[]; .cost == null)}})
   | from_entries) as $by_row
| ($rows0 | map(. + (if $L == null then {tok: null, cost: null} else ($by_row[.i | tostring] // {tok: 0, cost: 0}) end))) as $rows
| ($by_row["-1"]) as $unplaced
| ($L.total // null) as $total
| ($logs[0].checks // []) as $checks
| ($logs[0] != null and ($logs[0].checks | length) > 0) as $has_checks
| ($waits | map(select(.gate == "1.5"))) as $esc
| ($end - $t0) as $wall
| ($waits | map(.e - .s) | add // 0) as $waiting
| ($dead | map(.[1] - .[0]) | add // 0) as $deadsum
| ([$ev[] | select(.type == "review")] | length) as $rounds
| .budget as $b
| ($esc | length) as $nesc
# phase reports that ns-conductor report --rerun wrote instead of the worker
| [$ev[] | select(.type == "report-rerun")] as $rerun
| [
    "# Run report: \(.id | esc)",
    "",
    "- Project: \(.project | esc)",
    "- Tier: \(.tier // "none" | esc)",
    "- State: \(.state | esc)",
    "- Pull request: \(.pr // "none" | esc)",
    "- Times are UTC and come from the run ledger. Tokens, cost and check results come from the run's logs (`logs/\(.id | esc)/` in the Nightshift config directory).",
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
    "| Cost | \($total.cost // null | money) |",
    "| Tokens | \(if $total == null then "no data" else "\($total.tok | sumtok | tok) (input \($total.tok.in | tok), output \($total.tok.out | tok), cache read \($total.tok.cr | tok), cache write \($total.tok.cw | tok))" end) |",
    "| Review rounds | \($rounds) |",
    "| Escalations | \($nesc) |",
    "| Checks | \(if $has_checks | not then "no data" else
        ([("PASS", "FAIL", "SKIP") as $k | [$checks[] | select(.result == $k)] | length | select(. > 0) | "\(.) \($k)"]
         + ([$checks[] | select(.result == null)] | length | if . > 0 then ["\(.) no data"] else [] end)) | join(", ") end) |"
  ]
  + (if $nesc > 0 then
      ["", "Escalations:", ""]
      + [$esc | to_entries[]
         | "- \(.value.s | stamp) (gate \(.value.gate)): \(if .value.q != null then (.value.q | esc) elif .key == ($nesc - 1) and $cause != "" then ($cause | esc) else "cause not recorded" end)"]
    else [] end)
  + (if ($rerun | length) > 0 then
      ["", "Phase reports regenerated by `ns-conductor report --rerun`, not written by the worker:", ""]
      + [$rerun[] | (.note | split(" ")) as $w
         | "- \(.t | stamp): \($w[0] | esc) at \(($w[1] // "unknown")[0:12] | esc)"]
    else [] end)
  + (if ((.owner_notes // []) | length) > 0 then
      ["", "## Owner notes", "", "| Time | Note | Read |", "|---|---|---|"]
      + [.owner_notes[] | "| \(.time | ep | stamp) | \(.text | esc) | \(if .read then "yes" else "no" end) |"]
    else [] end)
  + ["", "## Timeline", "", "| Step | Start | Wall | Active | Waiting | Tokens | Cost |", "|---|---|---|---|---|---|---|"]
  + [$rows[] | "| \(.label | esc) | \(.s | stamp) | \(.wall | dur) | \(.active | dur) | \(.wait | dur) | \(.tok | tok) | \(rowcost) |"]
  + (if $unplaced != null then
      ["", "Not in any row (log entries outside the run's steps): \($unplaced.tok | tok) tokens, \($unplaced | rowcost)."]
    else [] end)
  + ["", "## Tokens and cost", ""]
  + (if $L == null then ["No session logs in `logs/\(.id | esc)/`: no data."] else
      ["By agent. A subagent's tokens and cost are part of the agent that started it.", "",
       "| Agent | Log | Sessions | Turns | Input | Output | Cache read | Cache write | Cost |",
       "|---|---|---|---|---|---|---|---|---|"]
      + [$L.agents[] | "| \(.agent | esc) | \(.log | esc) | " + (if .cost == null then "no data | no data | no data | no data | no data | no data | no data |"
          else "\(.sessions) | \(.turns) | \(.tok.in | tok) | \(.tok.out | tok) | \(.tok.cr | tok) | \(.tok.cw | tok) | \(.cost | money) |" end)]
      + ([$L.agents[]
          | (select(.bad > 0) | "- \(.log | esc): \(.bad) \(if .bad == 1 then "line is" else "lines are" end) not JSON and \(if .bad == 1 then "was" else "were" end) skipped."),
            (select(.open > 0) | "- \(.log | esc): \(.open) \(if .open == 1 then "session has" else "sessions have" end) no result event (cut off); \(if .open == 1 then "its" else "their" end) tokens and cost are not in the totals.")]
         | if length > 0 then [""] + . else . end)
      + ["", "By model:", "", "| Model | Input | Output | Cache read | Cache write | Cost |", "|---|---|---|---|---|---|"]
      + [$L.models[] | "| \(.model | esc) | \(.tok.in | tok) | \(.tok.out | tok) | \(.tok.cr | tok) | \(.tok.cw | tok) | \(.cost | money) |"]
      + (if $total == null then ["| Total | no data | no data | no data | no data | no data |"] else
          ["| Total | \($total.tok.in | tok) | \($total.tok.out | tok) | \($total.tok.cr | tok) | \($total.tok.cw | tok) | \($total.cost | money) |"] end)
      + (if ($L.subagents | length) > 0 then
          ["", "Subagents:", "", "| Subagent | Started by | Model | Runs | Time |", "|---|---|---|---|---|"]
          + [$L.subagents[] | "| \(.type | esc) | \(.by | esc) | \(.model | esc) | \(.runs) | \(if .unknown == .runs then "no data" elif .unknown > 0 then "at least \(.s | dur)" else (.s | dur) end) |"]
        else [] end)
    end)
  + ["", "## Checks", ""]
  + (if $has_checks | not then ["No checks log in `logs/\(.id | esc)/`: no data."] else
      ["The last run of `ns-conductor checks` for each target.", "",
       "| Target | Check | Result | Time | Start |", "|---|---|---|---|---|"]
      + [$checks[] | "| \(.target | esc) | \("\(.stack) \(.name)" | esc) | " + (if .result == null then "no data | no data | no data |"
          else "\(.result) | \(.end - .start | dur) | \(.start | stamp) |" end)]
      + ([$checks[] | select(.result == "SKIP") | "\(.target) \(.stack) \(.name)" | esc]
         | if length > 0 then ["", "SKIP (pytest collected no tests; not a failure, but check it was meant): \(join(", "))."] else [] end)
    end)
  | .[]
