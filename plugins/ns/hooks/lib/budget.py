#!/usr/bin/env python3
"""Nightshift PreToolUse budget check (R-BUD-1).

Stops a conductor session that keeps working past its wall-clock budget without calling
ns-conductor (whose subcommands check the budget themselves). When the run is running, at no
gate, and budget.used plus the unpaused time since budget.since reaches budget.limit, it runs
`ns-conductor budget-check <id>` (which stops the workers, writes RUN/escalation.md and opens
gate 1.5) and denies the tool call. While the run waits at gate 1.5 over its budget, every tool
call is denied. Once stack-base has passed (step integrate, stacked_on set) the integrator may
finish, so the hook allows. Exit 2 denies; anything else allows. An unreadable ledger allows (fails
open); without PyYAML it says so on stderr and allows.
"""
import datetime
import os
import subprocess
import sys

UTC = datetime.timezone.utc
# seconds budget-check may take (checkpoint --push, ns publish); hooks.json allows the hook more
CHECK_TIMEOUT = 60


def parse_time(value):
    if isinstance(value, datetime.datetime):
        return value if value.tzinfo else value.replace(tzinfo=UTC)
    return datetime.datetime.strptime(str(value), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)


def now():
    fixed = os.environ.get("NS_NOW")
    return parse_time(fixed) if fixed else datetime.datetime.now(UTC)


def status(doc, at):
    """'over' (running past the budget), 'gate' (at gate 1.5 over the budget) or 'ok'."""
    budget = doc.get("budget") or {}
    limit = budget.get("limit")
    if limit is None:
        return "ok", None
    used = float(budget.get("used") or 0)
    state, gate = doc.get("state"), doc.get("gate")
    if state == "running" and gate is None and doc.get("step") == "integrate" and doc.get("stacked_on"):
        return "ok", limit
    if state == "running" and gate is None:
        if not budget.get("paused"):
            used += max(0.0, (at - parse_time(budget["since"])).total_seconds()) / 3600
        return ("over" if used >= float(limit) else "ok"), limit
    if state == "waiting" and str(gate) == "1.5" and used >= float(limit):
        return "gate", limit
    return "ok", limit


def load(yaml, path):
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    return doc if isinstance(doc, dict) else {}


def conductor_cmd():
    home = os.environ.get("NS_RUN_HOME")
    if home and os.path.exists(os.path.join(home, "bin", "ns-conductor")):
        return os.path.join(home, "bin", "ns-conductor")
    return "ns-conductor"


def main():
    try:
        sys.stdin.read()
    except Exception:
        pass
    run_id = os.environ.get("NS_RUN_ID")
    ledger = os.environ.get("NS_LEDGER")
    if not run_id or not ledger or os.environ.get("NS_WORKER"):
        return 0
    try:
        import yaml
    except ImportError:
        print("ns budget: PyYAML is not importable; the budget hook did not check this call", file=sys.stderr)
        return 0
    try:
        doc = load(yaml, ledger)
        st, limit = status(doc, now())
    except Exception:
        return 0
    if st == "ok":
        return 0
    if st == "over":
        try:
            subprocess.run([conductor_cmd(), "budget-check", run_id], stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=CHECK_TIMEOUT,
                           check=False)
        except Exception:
            pass
        try:
            doc = load(yaml, ledger)
        except Exception:
            doc = {}
    if doc.get("state") == "waiting" and str(doc.get("gate")) == "1.5":
        print(f"ns budget: run {run_id} used its {limit} h wall-clock budget and waits at gate 1.5 for the "
              "owner (RUN/escalation.md). Do not continue: end the session now with a one-line summary.",
              file=sys.stderr)
    else:
        print(f"ns budget: run {run_id} used its {limit} h wall-clock budget, but the budget check could "
              f"not escalate it (state {doc.get('state', 'unknown')}). Do not continue: end the session "
              "now with a one-line summary.", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
