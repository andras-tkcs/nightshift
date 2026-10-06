#!/usr/bin/env python3
"""usage_limit.py: classify the final stream-json result of a worker.

usage: usage_limit.py <now epoch> < result.json

Prints one line, tab separated: <kind> <until epoch or -> <message>
  none         a normal finish (a success, or an error for another reason)
  usage        a usage limit that resets; until is the reset time + 60 s when the
               message names one Nightshift can read, else -
  usage-final  a usage limit that does not reset by itself (spend limit, credits)
  transient    a capacity 429 or a 529 overload: worth one retry after a short wait

Only an error result counts (is_error true, or a subtype other than success), and the
message must start with one of Claude Code's own texts; a report that mentions a rate
limiter is never a usage limit.
"""
import datetime
import json
import re
import sys

# Limits that do not reset on a schedule: the owner must act (checked first).
FINAL = (
    "You've hit your monthly spend limit",
    "You've hit your channel's monthly spend limit",
    "You've hit your monthly limit",
    "You've hit your team's shared budget",
    "You're out of usage credits",
    "You're out of extra usage",
    "Your org is out of usage",
    "Your seat type doesn't include usage",
)
FINAL_RE = re.compile(r"^[\w.\- ]{1,40} requires usage credits\.")
# Limits that reset (session, weekly, model limits).
LIMIT = (
    "You've hit your",
    "You've reached your",
    "Claude AI usage limit reached",
)
# Capacity problems that are not the account's limit.
TRANSIENT = (
    "Request rejected (429)",
    "Repeated 529 Overloaded",
    "Server is temporarily limiting requests",
    "Opus is experiencing high load",
    "Fable is experiencing high load",
    "API Error: 429",
    "API Error: 529",
    "API Error: Repeated 529",
)
MONTHS = {m: i for i, m in enumerate(
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], 1)}
RESET_RE = re.compile(r"resets (?P<when>[^()·]+?)\s*(?:\((?P<tz>[^)]+)\))?\s*(?:·|$)")
WHEN_RE = re.compile(
    r"^(?:(?P<mon>[A-Z][a-z]{2}) (?P<day>\d{1,2})(?:, (?P<year>\d{4}))?,? )?"
    r"(?P<h>\d{1,2})(?::(?P<m>\d{2}))?\s?(?P<ap>am|pm)$", re.I)
MARGIN = 60
HORIZON = 8 * 86400


def tzinfo(name):
    if name:
        try:
            from zoneinfo import ZoneInfo
            return ZoneInfo(name.strip())
        except Exception:  # noqa: BLE001 - unknown zone: fall back to local time
            pass
    return datetime.datetime.now().astimezone().tzinfo


def reset_epoch(msg, now):
    """The reset time named in msg as an epoch (+ margin), or None."""
    m = re.match(r"^Claude AI usage limit reached\|(\d{9,11})", msg)
    if m:
        t = int(m.group(1)) + MARGIN
        return t if now < t <= now + HORIZON else None
    m = RESET_RE.search(msg)
    if not m:
        return None
    w = WHEN_RE.match(m.group("when").strip())
    if not w:
        return None
    tz = tzinfo(m.group("tz"))
    nowdt = datetime.datetime.fromtimestamp(now, tz)
    hour = int(w.group("h")) % 12 + (12 if w.group("ap").lower() == "pm" else 0)
    minute = int(w.group("m") or 0)
    try:
        if w.group("mon"):
            mon = MONTHS.get(w.group("mon").title())
            if mon is None:
                return None
            year = int(w.group("year") or nowdt.year)
            dt = datetime.datetime(year, mon, int(w.group("day")), hour, minute, tzinfo=tz)
            if not w.group("year") and dt.timestamp() < now - 86400:
                dt = dt.replace(year=year + 1)
        else:
            dt = nowdt.replace(hour=hour, minute=minute, second=0, microsecond=0)
            if dt.timestamp() <= now:
                dt += datetime.timedelta(days=1)
    except ValueError:
        return None
    t = int(dt.timestamp()) + MARGIN
    return t if now < t <= now + HORIZON else None


def classify(res, now):
    if not isinstance(res, dict):
        return "none", None, ""
    if not (res.get("is_error") is True or (res.get("subtype") or "success") != "success"):
        return "none", None, ""
    texts = [res.get("result")] + list(res.get("errors") or [])
    texts = [t.strip() for t in texts if isinstance(t, str) and t.strip()]
    for t in texts:
        if t.startswith(FINAL) or FINAL_RE.match(t):
            return "usage-final", None, t
    for t in texts:
        if t.startswith(LIMIT):
            return "usage", reset_epoch(t, now), t
    for t in texts:
        if t.startswith(TRANSIENT):
            return "transient", None, t
    if res.get("api_error_status") in (429, 529):
        return "transient", None, texts[0] if texts else ""
    return "none", None, ""


def main():
    if len(sys.argv) != 2 or not sys.argv[1].isdigit():
        print(__doc__.splitlines()[2], file=sys.stderr)
        return 2
    try:
        res = json.loads(sys.stdin.read())
    except ValueError:
        res = None
    kind, until, msg = classify(res, int(sys.argv[1]))
    msg = re.sub(r"\s+", " ", msg)[:200]
    print(f"{kind}\t{until if until else '-'}\t{msg}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
