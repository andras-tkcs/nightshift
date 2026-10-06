import json

import report_logs


def result(sid, cost, turns, models):
    return {"type": "result", "session_id": sid, "total_cost_usd": cost, "num_turns": turns, "modelUsage": models}


def mu(i, o, cost):
    return {"inputTokens": i, "outputTokens": o, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0, "costUSD": cost}


def write(path, events):
    path.write_text("".join((e if isinstance(e, str) else json.dumps(e)) + "\n" for e in events))


def test_results_of_one_session_are_cumulative(tmp_path):
    # Claude Code repeats the running total in every result of a session
    write(tmp_path / "conductor.jsonl", [
        result("a", 1.0, 3, {"m": mu(1, 10, 1.0)}),
        result("a", 1.5, 2, {"m": mu(2, 15, 1.5)}),
        result("b", 0.25, 1, {"m": mu(1, 1, 0.25)}),
    ])
    agent, _, _ = report_logs.read_session_log(str(tmp_path / "conductor.jsonl"))
    assert agent["sessions"] == 2
    assert agent["cost"] == 1.75
    assert agent["turns"] == 6
    assert agent["tok"] == {"in": 3, "out": 16, "cr": 0, "cw": 0}


def test_malformed_lines_and_wrong_types_are_skipped(tmp_path):
    write(tmp_path / "p1.jsonl", ["not json", "[1]", {"type": "result", "total_cost_usd": True}, {"type": "result", "num_turns": "x"}])
    agent, msgs, subs = report_logs.read_session_log(str(tmp_path / "p1.jsonl"))
    assert agent["bad"] == 2
    assert agent["cost"] is None and agent["tok"] is None
    assert agent["agent"] == "p1 worker"
    assert msgs == [] and subs == []


def test_message_costs_add_up_to_the_session_cost(tmp_path):
    def msg(mid, ts, out):
        return {"type": "assistant", "session_id": "a", "timestamp": ts,
                "message": {"id": mid, "model": "m", "usage": {"input_tokens": 1, "output_tokens": out}}}
    write(tmp_path / "conductor.jsonl", [
        msg("x", "2026-10-02T10:00:00.5Z", 10), msg("x", "2026-10-02T10:00:01Z", 10),
        msg("y", "2026-10-02T10:05:00Z", 30), result("a", 0.9, 2, {"m": mu(2, 40, 0.9)}),
    ])
    _, msgs, _ = report_logs.read_session_log(str(tmp_path / "conductor.jsonl"))
    assert len(msgs) == 2
    assert abs(sum(m["cost"] for m in msgs) - 0.9) < 1e-9
    assert msgs[0]["tok"] == 11


def test_attempt_logs_name_the_attempt():
    assert report_logs.agent_of("p1--attempt2") == ("p1 worker (attempt 2)", "p1", 2)
    assert report_logs.agent_of("conductor") == ("conductor", None, None)


def test_checks_log_with_and_without_times(tmp_path):
    (tmp_path / "feature.checks.log").write_text(
        "== python lint: ruff\n"
        "== python test: pytest\n== start python test 2026-10-02T10:00:00Z\n"
        "== end python test 2026-10-02T09:00:00Z PASS exit 0\n== end python test 2026-10-02T10:00:07Z SKIP exit 5\n")
    rows = report_logs.read_checks_log(str(tmp_path / "feature.checks.log"))
    assert [(r["name"], r["result"]) for r in rows] == [("lint", None), ("test", "SKIP")]
    assert rows[1]["end"] - rows[1]["start"] == 7
