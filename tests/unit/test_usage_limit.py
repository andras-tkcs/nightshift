import datetime
import json

import pytest

import usage_limit


def epoch(iso):
    return int(datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp())


def iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


NOW = epoch("2026-10-02T21:00:00Z")  # 23:00 in Budapest (CEST), 17:00 in New York (EDT)


def limit(text):
    return {"type": "result", "subtype": "success", "is_error": True, "api_error_status": 429, "result": text}


@pytest.mark.parametrize("msg, now, want", [
    # Budapest is already past 3pm today: tomorrow 15:00 CEST
    ("You've hit your session limit · resets 3pm (Europe/Budapest)", NOW, "2026-10-03T13:01:00Z"),
    # New York is at 17:00: today 21:00 EDT
    ("You've hit your session limit · resets 9pm (America/New_York)", NOW, "2026-10-03T01:01:00Z"),
    ("You've hit your weekly limit · resets Oct 4, 9:30pm (UTC)", NOW, "2026-10-04T21:31:00Z"),
    ("You've hit your weekly limit · resets Jan 2, 2027, 9pm (UTC)", epoch("2026-12-30T12:00:00Z"), "2027-01-02T21:01:00Z"),
    # a time of day already past today means tomorrow
    ("You've hit your session limit · resets 8pm (UTC)", NOW, "2026-10-03T20:01:00Z"),
    ("You've hit your session limit · resets 9:15pm (UTC) · progress saved", NOW, "2026-10-02T21:16:00Z"),
    # the old form carries the epoch
    ("Claude AI usage limit reached|" + str(epoch("2026-10-02T23:00:00Z")), NOW, "2026-10-02T23:01:00Z"),
])
def test_reset_time(msg, now, want):
    kind, until, _ = usage_limit.classify(limit(msg), now)
    assert kind == "usage"
    assert iso(until) == want


@pytest.mark.parametrize("msg, now", [
    # more than 8 days ahead
    ("You've hit your weekly limit · resets Oct 20, 3pm (UTC)", NOW),
    ("You've hit your weekly limit · resets Jan 2, 2027, 9pm (UTC)", NOW),
    # an epoch in the past
    ("Claude AI usage limit reached|" + str(epoch("2026-10-01T23:00:00Z")), NOW),
    # unreadable
    ("You've hit your session limit · resets soon", NOW),
    ("You've hit your session limit", NOW),
])
def test_no_usable_reset_time(msg, now):
    kind, until, _ = usage_limit.classify(limit(msg), now)
    assert kind == "usage"
    assert until is None


def test_ambiguous_dst_hour_takes_the_later_one():
    # 2:30am on 25 Oct 2026 happens twice in Budapest (CEST, then CET): wait for the second
    kind, until, _ = usage_limit.classify(
        limit("You've hit your session limit · resets Oct 25, 2:30am (Europe/Budapest)"),
        epoch("2026-10-24T12:00:00Z"))
    assert kind == "usage"
    assert iso(until) == "2026-10-25T01:31:00Z"


def test_unknown_zone_falls_back_to_local_time():
    kind, until, _ = usage_limit.classify(limit("You've hit your session limit · resets 11pm (Mars/Olympus)"), NOW)
    assert kind == "usage"
    assert until is not None and NOW < until <= NOW + 86400 + 60


@pytest.mark.parametrize("res, kind", [
    ({"is_error": False, "subtype": "success", "result": "You've hit your session limit · resets 3pm"}, "none"),
    ({"is_error": True, "result": "API Error: 500; You've hit your session limit"}, "none"),
    ({"is_error": True, "subtype": "error_max_turns", "errors": ["Reached maximum number of turns (40)"]}, "none"),
    ({"is_error": True, "subtype": "error_during_execution", "errors": ["You've hit your session limit · resets 3pm (UTC)"]}, "usage"),
    ({"is_error": True, "result": "You've hit your monthly spend limit."}, "usage-final"),
    ({"is_error": True, "result": "Opus requires usage credits."}, "usage-final"),
    ({"is_error": True, "api_error_status": 429, "result": "Request rejected (429) · this may be a temporary capacity issue."}, "transient"),
    ({"is_error": True, "api_error_status": 529, "result": "Repeated 529 Overloaded errors"}, "transient"),
    ({"is_error": True, "api_error_status": 429, "result": "something else"}, "transient"),
])
def test_classify(res, kind):
    assert usage_limit.classify(res, NOW)[0] == kind


def test_main_prints_a_dash_without_a_reset_time(monkeypatch, capsys):
    monkeypatch.setattr("sys.argv", ["usage_limit.py", str(NOW)])
    monkeypatch.setattr("sys.stdin", __import__("io").StringIO(json.dumps(limit("You've hit your session limit"))))
    assert usage_limit.main() == 0
    assert capsys.readouterr().out == "usage\t-\tYou've hit your session limit\n"
