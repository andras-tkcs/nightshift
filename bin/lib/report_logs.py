#!/usr/bin/env python3
"""report_logs.py: read a run's log directory for ns report.

usage: report_logs.py <logs/<id> directory>

Prints one JSON object on stdout; bin/lib/report.jq renders it. Everything read here is
data: nothing is executed, unknown or malformed lines are skipped and counted, and a value
of the wrong type counts as missing. A missing directory gives empty lists, never an error.

Session logs (*.jsonl, Claude Code stream-json):
  conductor.jsonl               the conductor (its launcher appends every session)
  <phase>.jsonl                 the phase worker's latest attempt (ns-conductor start)
  <phase>--attempt<n>.jsonl     an earlier attempt, kept by ns-conductor start
The `result` events of one session are cumulative: total_cost_usd and modelUsage of the last
one hold the whole session (num_turns is per result). A session's cost and tokens are the
last result's; an agent's are the sum over its sessions. Subagents run inside the session
that started them, so their cost is part of it. A foreground subagent's Agent tool result
names its type, model and duration; a background one's result only says async_launched with
its model, so its type comes from the Agent tool_use block (input.subagent_type) and its
duration from the task_notification for that tool use, when there is one.

Each assistant message (deduplicated by message id) gives a time, a model and its tokens,
for the timeline. The stream's usage is partial (output_tokens in particular), so each kind
of token is scaled per session and model to that session's modelUsage. Its cost is the
session's costUSD for that model shared out by weighted tokens (input 1, output 5, cache
read 0.1, cache write 1.25). Both add up to the result events exactly. A session without a
result keeps the stream's tokens and has no cost.

A number that is not finite or above 1e15 counts as missing; a line that is not JSON, or
nested too deep to parse, is skipped and counted.

Checks logs (<target>.checks.log, ns-conductor checks):
  == <stack> <name>: <command>
  == start <stack> <name> <UTC time>
  ...output...
  == end <stack> <name> <UTC time> <PASS|FAIL|SKIP> exit <rc>
An older log without start and end lines gives the check with no result and no times.
Each real run opens with `== run <UTC>`; a cache hit appends `== cached <UTC>` only, which is
not counted in full_runs.
"""
import datetime
import json
import math
import os
import re
import sys

ATTEMPT = re.compile(r"^(?P<phase>.+)--attempt(?P<n>[0-9]+)$")
HEADER = re.compile(r"^== (?P<stack>\S+) (?P<name>\S+): ")
RUN = re.compile(r"^== run \S+$")
START = re.compile(r"^== start (?P<stack>\S+) (?P<name>\S+) (?P<t>\S+)$")
END = re.compile(r"^== end (?P<stack>\S+) (?P<name>\S+) (?P<t>\S+) (?P<r>PASS|FAIL|SKIP) exit (?P<rc>[0-9]+)$")
WEIGHT = {"in": 1.0, "out": 5.0, "cr": 0.1, "cw": 1.25}
KEYS = {
    # modelUsage keys, then usage keys
    "in": ("inputTokens", "input_tokens"),
    "out": ("outputTokens", "output_tokens"),
    "cr": ("cacheReadInputTokens", "cache_read_input_tokens"),
    "cw": ("cacheCreationInputTokens", "cache_creation_input_tokens"),
}


def num(v):
    """A finite JSON number (not a bool) of at most 1e15, else None."""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    if not math.isfinite(v) or abs(v) > 1e15:
        return None
    return v


def epoch(s):
    if not isinstance(s, str):
        return None
    try:
        return int(datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def tokens(d, idx):
    """{in, out, cr, cw} from a modelUsage (idx 0) or usage (idx 1) object, else None."""
    if not isinstance(d, dict):
        return None
    out = {}
    for k, names in KEYS.items():
        v = num(d.get(names[idx]))
        out[k] = int(v) if v is not None else 0
    return out


def add(a, b):
    return {k: a.get(k, 0) + b.get(k, 0) for k in KEYS}


def agent_of(stem):
    """(agent label, phase or None, attempt or None) for a log file name without .jsonl."""
    if stem == "conductor":
        return "conductor", None, None
    m = ATTEMPT.match(stem)
    if m:
        return "%s worker (attempt %s)" % (m["phase"], m["n"]), m["phase"], int(m["n"])
    return "%s worker" % stem, stem, None


def read_session_log(path):
    """Parse one .jsonl file; returns (agent dict, messages list, subagent list)."""
    stem = os.path.basename(path)[: -len(".jsonl")]
    label, phase, attempt = agent_of(stem)
    bad = 0
    sessions = {}  # session id -> last costed result
    turns = 0
    msgs = {}  # message id -> message
    order = []
    subs = {}  # tool use id (or a counter) -> subagent run
    agent_types = {}  # Agent tool use id -> subagent_type
    durations = {}  # tool use id -> seconds, from task_notification
    last_asst = 0  # epoch of the latest assistant message
    use_t = {}  # Agent tool use id -> epoch of the call
    result_t = {}  # tool use id -> epoch of its tool_result
    launched = set()  # tool use ids of background launches (their result comes at once)
    anon = 0
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        lines = []
        bad = 1
    for line in lines:
        if not line.strip():
            continue
        try:
            e = json.loads(line)
        except (ValueError, RecursionError):
            bad += 1
            continue
        if not isinstance(e, dict):
            bad += 1
            continue
        typ = e.get("type")
        sid = e.get("session_id") if isinstance(e.get("session_id"), str) else ""
        if typ == "result":
            t = num(e.get("num_turns"))
            if t is not None:
                turns += int(t)
            cost = num(e.get("total_cost_usd"))
            if cost is None:
                continue
            if not sid:
                anon += 1
                sid = "\0%d" % anon
            prev = sessions.get(sid)
            if prev is None or cost >= prev["cost"]:
                sessions[sid] = {"cost": float(cost), "models": e.get("modelUsage"), "usage": e.get("usage")}
        elif typ == "assistant":
            m = e.get("message")
            if not isinstance(m, dict):
                continue
            for c in m.get("content") if isinstance(m.get("content"), list) else []:
                if (isinstance(c, dict) and c.get("type") == "tool_use" and isinstance(c.get("id"), str)
                        and isinstance(c.get("input"), dict) and isinstance(c["input"].get("subagent_type"), str)):
                    agent_types[c["id"]] = c["input"]["subagent_type"]
                    ut = epoch(e.get("timestamp"))
                    if ut is not None:
                        use_t[c["id"]] = ut
            t = epoch(e.get("timestamp"))
            if t is not None and t > last_asst:
                last_asst = t
            tok = tokens(m.get("usage"), 1)
            if t is None or tok is None:
                continue
            mid = m.get("id") if isinstance(m.get("id"), str) else "\0%d" % len(order)
            if mid not in msgs:
                order.append(mid)
            model = m.get("model") if isinstance(m.get("model"), str) else "unknown"
            # the last event of a message carries its final usage
            msgs[mid] = {"t": t, "sid": sid, "model": model, "tok": tok}
        elif typ == "user":
            um = e.get("message")
            rt = epoch(e.get("timestamp"))
            for c in (um.get("content") if isinstance(um, dict) and isinstance(um.get("content"), list) else []):
                if (rt is not None and isinstance(c, dict) and c.get("type") == "tool_result"
                        and isinstance(c.get("tool_use_id"), str)):
                    result_t.setdefault(c["tool_use_id"], rt)
            r = e.get("tool_use_result")
            if not isinstance(r, dict):
                continue
            tid = None
            msg = e.get("message")
            for c in (msg.get("content") if isinstance(msg, dict) and isinstance(msg.get("content"), list) else []):
                if isinstance(c, dict) and isinstance(c.get("tool_use_id"), str):
                    tid = c["tool_use_id"]
            key = tid or "\0sub%d" % len(subs)
            # a tool use id is counted once; a second completed result with it is another run
            if key in subs and subs[key]["type"] is not None:
                key = "\0sub%d" % len(subs)
            model = r.get("resolvedModel") if isinstance(r.get("resolvedModel"), str) else "unknown"
            if isinstance(r.get("agentType"), str):
                ms = num(r.get("totalDurationMs"))
                subs[key] = {"type": r["agentType"], "by": label, "model": model,
                             "s": int(ms / 1000) if ms is not None else None, "tid": tid}
            elif r.get("status") == "async_launched" and isinstance(r.get("resolvedModel"), str):
                if tid:
                    launched.add(tid)
                subs.setdefault(key, {"type": None, "by": label, "model": model, "s": None, "tid": tid})
        elif typ == "system" and e.get("subtype") == "task_notification":
            u = e.get("usage")
            ms = num(u.get("duration_ms")) if isinstance(u, dict) else None
            if isinstance(e.get("tool_use_id"), str) and ms is not None:
                durations[e["tool_use_id"]] = int(ms / 1000)

    # an Agent call with no result at all (the session was cut off) is still a run
    for tid in agent_types:
        if tid not in subs:
            subs[tid] = {"type": agent_types[tid], "by": label, "model": "unknown", "s": None, "tid": tid}
    sub_list = []
    for x in subs.values():
        tid = x.pop("tid")
        if x["type"] is None:
            x["type"] = agent_types.get(tid, "unknown")
        if x["s"] is None and tid in durations:
            x["s"] = durations[tid]
        elif (x["s"] is None and tid in use_t and tid in result_t and tid not in launched
              and result_t[tid] >= use_t[tid]):
            # no task notification: the time from the Agent call to its result
            x["s"] = int(result_t[tid] - use_t[tid])
        elif (x["s"] is None and tid in use_t and tid not in result_t and tid not in launched
              and last_asst >= use_t[tid]):
            # cut off, no result: to the latest assistant message
            x["s"] = int(last_asst - use_t[tid])
        sub_list.append(x)

    # per session and model: tokens and cost of the last result
    models = {}
    tot = {k: 0 for k in KEYS}
    cost = 0.0
    session_model_cost = {}
    session_model_tok = {}
    for sid, r in sessions.items():
        cost += r["cost"]
        mu = r["models"]
        if isinstance(mu, dict) and mu:
            for name, d in mu.items():
                tk = tokens(d, 0)
                if tk is None:
                    continue
                c = num(d.get("costUSD"))
                m = models.setdefault(str(name), {"tok": {k: 0 for k in KEYS}, "cost": 0.0})
                m["tok"] = add(m["tok"], tk)
                m["cost"] = (m["cost"] or 0.0) + (float(c) if c is not None else 0.0)
                tot = add(tot, tk)
                session_model_cost[(sid, str(name))] = float(c) if c is not None else 0.0
                session_model_tok[(sid, str(name))] = tk
        else:
            tk = tokens(r["usage"], 1)
            if tk is not None:
                tot = add(tot, tk)
                m = models.setdefault("unknown", {"tok": {k: 0 for k in KEYS}, "cost": 0.0})
                m["tok"] = add(m["tok"], tk)
                m["cost"] += r["cost"]
            session_model_cost[(sid, "*")] = r["cost"]

    # scale each message's tokens to its session's modelUsage, kind by kind
    raw = {}
    for mid in order:
        m = msgs[mid]
        key = (m["sid"], m["model"]) if (m["sid"], m["model"]) in session_model_cost else (m["sid"], "*")
        m["key"] = key
        raw[key] = add(raw.get(key, {}), m["tok"])
    for mid in order:
        m = msgs[mid]
        want = session_model_tok.get(m["key"])
        if want is not None:
            have = raw[m["key"]]
            m["tok"] = {k: (m["tok"][k] * want[k] / have[k] if have[k] else 0) for k in KEYS}
    # share each session's cost per model out over its messages by weighted tokens
    weight = {}
    for mid in order:
        m = msgs[mid]
        weight[m["key"]] = weight.get(m["key"], 0.0) + sum(WEIGHT[k] * m["tok"][k] for k in KEYS)
    # sessions with messages but no result: their tokens, summed over the messages, are partial
    partial_tok = {k: 0 for k in KEYS}
    partial = False
    for mid in order:
        m = msgs[mid]
        # only a log with no result at all falls back to the messages
        if m["key"] not in session_model_cost and not sessions:
            partial = True
            partial_tok = add(partial_tok, m["tok"])
            pm = models.setdefault(m["model"], {"tok": {k: 0 for k in KEYS}, "cost": None})
            pm["tok"] = add(pm["tok"], m["tok"])
    out_msgs = []
    for mid in order:
        m = msgs[mid]
        c = None
        if m["key"] in session_model_cost:
            w = sum(WEIGHT[k] * m["tok"][k] for k in KEYS)
            total_w = weight[m["key"]]
            c = session_model_cost[m["key"]] * w / total_w if total_w > 0 else 0.0
        out_msgs.append({"t": m["t"], "agent": label, "phase": phase, "attempt": attempt,
                         "tok": round(sum(m["tok"].values())), "cost": c})

    agent = {
        "agent": label,
        "log": os.path.basename(path),
        "phase": phase,
        "attempt": attempt,
        "sessions": len(sessions),
        "turns": turns,
        "tok": add(tot, partial_tok) if (sessions or partial) else None,
        "partial": partial,
        "cost": cost if sessions else None,
        "models": models,
        "bad": bad,
        # sessions that wrote messages but no result with a cost (killed, or cut off)
        "open": len({msgs[m]["sid"] for m in order if msgs[m]["sid"]} - set(sessions)),
    }
    return agent, out_msgs, sub_list


def count_full_runs(path):
    """Real runs in a checks log: its `== run` lines. `== cached` lines (a cache hit) are not runs."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
        n = sum(1 for line in lines if RUN.match(line))
        # an older log without `== run` lines is one run
        return n or (1 if any(HEADER.match(line) for line in lines) else 0)
    except OSError:
        return 0


def read_checks_log(path):
    target = os.path.basename(path)[: -len(".checks.log")]
    rows = []
    cur = None
    run = 0  # a log without `== run` lines is one run
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    for line in lines:
        if RUN.match(line):
            run += 1
            continue
        m = START.match(line)
        if m and cur and (m["stack"], m["name"]) == (cur["stack"], cur["name"]):
            cur["start"] = epoch(m["t"])
            continue
        m = END.match(line)
        if m and cur and (m["stack"], m["name"]) == (cur["stack"], cur["name"]):
            end = epoch(m["t"])
            if cur["start"] is not None and end is not None:
                cur["end"] = end
                cur["result"] = m["r"]
            continue
        m = HEADER.match(line)
        if m:
            cur = {"target": target, "run": run, "stack": m["stack"], "name": m["name"], "start": None, "end": None, "result": None}
            rows.append(cur)
    last = max((r["run"] for r in rows), default=0)
    for r in rows:
        r["last"] = r["run"] == last
    return rows


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: report_logs.py <log dir>\n")
        return 2
    d = sys.argv[1]
    try:
        names = sorted(os.listdir(d))
    except OSError:
        names = []
    agents, messages, subs, checks = [], [], [], []
    full_runs = 0
    for n in names:
        p = os.path.join(d, n)
        if not os.path.isfile(p):
            continue
        if n.endswith(".jsonl"):
            a, m, s = read_session_log(p)
            agents.append(a)
            messages += m
            subs += s
        elif n.endswith(".checks.log"):
            checks += read_checks_log(p)
            full_runs += count_full_runs(p)

    # conductor first, then the workers by phase and attempt (the latest attempt last)
    def akey(a):
        if a["phase"] is None:
            return (0, "", 0)
        return (1, a["phase"], a["attempt"] if a["attempt"] is not None else 1 << 30)
    agents.sort(key=akey)

    models = {}
    for a in agents:
        for name, m in a["models"].items():
            x = models.setdefault(name, {"model": name, "tok": {k: 0 for k in KEYS}, "cost": None})
            x["tok"] = add(x["tok"], m["tok"])
            if m["cost"] is not None:
                x["cost"] = (x["cost"] or 0.0) + m["cost"]
        del a["models"]
    withtok = [a for a in agents if a["tok"] is not None]
    total = None
    if withtok:
        tok = {k: 0 for k in KEYS}
        for a in withtok:
            tok = add(tok, a["tok"])
        costed = [a for a in agents if a["cost"] is not None]
        total = {"tok": tok, "cost": sum(a["cost"] for a in costed) if costed else None,
                 "partial": any(a["partial"] for a in agents)}

    grouped = {}
    for s in subs:
        g = grouped.setdefault((s["by"], s["type"], s["model"]),
                               {"by": s["by"], "type": s["type"], "model": s["model"], "runs": 0, "s": 0, "unknown": 0})
        g["runs"] += 1
        if s["s"] is None:
            g["unknown"] += 1
        else:
            g["s"] += s["s"]
    sub_rows = [grouped[k] for k in sorted(grouped, key=lambda k: (akey_label(k[0], agents), k[1], k[2]))]

    json.dump({"agents": agents, "models": [models[k] for k in sorted(models)], "total": total,
               "messages": messages, "subagents": sub_rows, "checks": checks, "full_runs": full_runs}, sys.stdout)
    sys.stdout.write("\n")
    return 0


def akey_label(label, agents):
    for i, a in enumerate(agents):
        if a["agent"] == label:
            return i
    return len(agents)


if __name__ == "__main__":
    sys.exit(main())
