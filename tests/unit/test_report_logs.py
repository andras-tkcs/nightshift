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


def test_non_finite_numbers_and_deep_nesting_are_skipped(tmp_path):
    write(tmp_path / "conductor.jsonl", [
        '{"type":"result","session_id":"z","total_cost_usd":1,"num_turns":1e400}',
        '{"type":"result","session_id":"y","total_cost_usd":NaN}',
        "[" * 100000 + "]" * 100000,
    ])
    agent, _, _ = report_logs.read_session_log(str(tmp_path / "conductor.jsonl"))
    assert agent["cost"] == 1 and agent["turns"] == 0 and agent["bad"] == 1


def test_background_subagents_are_counted_with_their_type(tmp_path):
    write(tmp_path / "conductor.jsonl", [
        {"type": "assistant", "session_id": "a", "timestamp": "2026-10-02T10:00:00Z",
         "message": {"id": "x", "model": "m", "usage": {}, "content": [
             {"type": "tool_use", "id": "t1", "name": "Agent", "input": {"subagent_type": "ns:triage"}}]}},
        {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1"}]},
         "tool_use_result": {"status": "async_launched", "resolvedModel": "m2"}},
    ])
    _, _, subs = report_logs.read_session_log(str(tmp_path / "conductor.jsonl"))
    assert subs == [{"type": "ns:triage", "by": "conductor", "model": "m2", "s": None}]


def test_message_tokens_are_scaled_to_the_session_model_usage(tmp_path):
    # stream events carry partial output_tokens; modelUsage of the last result is the truth
    write(tmp_path / "conductor.jsonl", [
        {"type": "assistant", "session_id": "a", "timestamp": "2026-10-02T10:00:00Z",
         "message": {"id": "x", "model": "m", "usage": {"input_tokens": 1, "output_tokens": 2}}},
        {"type": "assistant", "session_id": "a", "timestamp": "2026-10-02T10:01:00Z",
         "message": {"id": "y", "model": "m", "usage": {"input_tokens": 1, "output_tokens": 2}}},
        result("a", 1.0, 2, {"m": mu(2, 40, 1.0)}),
    ])
    _, msgs, _ = report_logs.read_session_log(str(tmp_path / "conductor.jsonl"))
    assert sum(m["tok"] for m in msgs) == 42
