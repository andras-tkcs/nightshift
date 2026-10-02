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
        content = (ev.get("message") or {}).get("content") or []
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        for item in content:
            if not isinstance(item, dict):
                continue
            if item.get("type") == "text" and str(item.get("text", "")).strip():
                out.append(f"{hhmm()} text: {one_line(item['text'], 300)}")
            elif item.get("type") == "tool_use":
                inp = json.dumps(item.get("input", {}), ensure_ascii=False)
                out.append(f"{hhmm()} tool: {item.get('name', '?')} {inp[:120]}")
    elif t == "result":
        cost = ev.get("total_cost_usd") or 0
        out.append(f"{hhmm()} done: {ev.get('subtype', '?')}, {ev.get('num_turns', 0)} turns, ${float(cost):.2f}")
    return out


def main():
    for line in sys.stdin:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict):
            continue
        for text in render(ev):
            print(text, flush=True)


if __name__ == "__main__":
    main()
