#!/usr/bin/env python3
"""Turn claude stream-json lines on stdin into one readable line per event."""
import json
import os
import sys
from datetime import datetime, timezone


def hhmm():
    now = os.environ.get("NS_NOW")
    if now and len(now) >= 16:
        return now[11:16]
    return datetime.now(timezone.utc).strftime("%H:%M")


def one_line(s, n):
    return " ".join(str(s).split())[:n]


def render(ev):
    out = []
    t = ev.get("type")
    if t == "assistant":
        msg = ev.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        if not isinstance(content, list):
            content = []
        for item in content:
            if not isinstance(item, dict):
                continue
            if item.get("type") == "text" and str(item.get("text") or "").strip():
                out.append(f"{hhmm()} text: {one_line(item['text'], 300)}")
            elif item.get("type") == "tool_use":
                inp = json.dumps(item.get("input", {}), ensure_ascii=False, default=str)
                out.append(f"{hhmm()} tool: {item.get('name') or '?'} {inp[:120]}")
    elif t == "result":
        try:
            cost = float(ev.get("total_cost_usd") or 0)
        except (TypeError, ValueError):
            cost = 0.0
        out.append(f"{hhmm()} done: {ev.get('subtype') or '?'}, {ev.get('num_turns') or 0} turns, ${cost:.2f}")
    return out


def main():
    # A viewer must never take the pipe (and with it the conductor) down.
    for line in sys.stdin:
        try:
            ev = json.loads(line)
            if not isinstance(ev, dict):
                continue
            texts = render(ev)
        except Exception:
            continue
        for text in texts:
            try:
                print(text, flush=True)
            except BrokenPipeError:
                try:
                    sys.stdout = open(os.devnull, "w")
                except OSError:
                    pass
            except Exception:
                pass


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
    sys.exit(0)
