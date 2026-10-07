#!/usr/bin/env python3
"""Turn claude stream-json lines on stdin into one readable line per event."""
import json
import os
import re
import sys
import textwrap
from datetime import datetime, timezone


def hhmm(ev=None):
    ts = ev.get("timestamp") if isinstance(ev, dict) else None
    if isinstance(ts, str) and re.match(r"\d{4}-\d\d-\d\dT\d\d:\d\d", ts):
        return ts[11:16]
    now = os.environ.get("NS_NOW")
    if now and len(now) >= 16:
        return now[11:16]
    return datetime.now(timezone.utc).strftime("%H:%M")


def one_line(s):
    return " ".join(str(s).split())


def width():
    try:
        w = int(os.environ.get("COLUMNS", ""))
    except ValueError:
        w = 80
    return w if w >= 20 else 80


def wrap(s):
    s = one_line(s)
    w = width()
    # words stay whole unless one alone cannot fit a hanging-indented line
    longest = max(len(x) for x in s.split()) if s else 0
    return textwrap.fill(
        s,
        width=w,
        subsequent_indent=" " * 6,
        break_long_words=longest > w - 6,
        break_on_hyphens=False,
    )


PRIMARY = ("command", "file_path", "notebook_path", "pattern", "url")


def tool_input(inp):
    if isinstance(inp, dict):
        for key in PRIMARY:
            if isinstance(inp.get(key), str) and inp[key].strip():
                return inp[key]
    return json.dumps(inp, ensure_ascii=False, separators=(",", ":"), default=str)


def result_text(content):
    if isinstance(content, list):
        content = "\n".join(
            str(c.get("text", "")) for c in content if isinstance(c, dict)
        )
    return str(content or "")


def result_line(item):
    if not item.get("is_error"):
        return "result: ok"
    lines = [l.strip() for l in result_text(item.get("content")).splitlines() if l.strip()]
    code = ""
    if lines:
        m = re.match(r"Exit code (\d+)$", lines[0])
        if m:
            code = m.group(1)
            lines = lines[1:]
    head = f"error, exit {code}" if code else "error"
    return f"result: {head}: {lines[0]}" if lines else f"result: {head}"


def render(ev):
    out = []
    t = ev.get("type")
    msg = ev.get("message")
    content = msg.get("content") if isinstance(msg, dict) else None
    if isinstance(content, str):
        content = [{"type": "text", "text": content}]
    if not isinstance(content, list):
        content = []
    if t == "assistant":
        for item in content:
            if not isinstance(item, dict):
                continue
            if item.get("type") == "text" and str(item.get("text") or "").strip():
                out.append(wrap(f"{hhmm(ev)} text: {item['text']}"))
            elif item.get("type") == "tool_use":
                inp = tool_input(item.get("input", {}))
                out.append(wrap(f"{hhmm(ev)} tool: {item.get('name') or '?'} {inp}"))
    elif t == "user":
        for item in content:
            if isinstance(item, dict) and item.get("type") == "tool_result":
                out.append(wrap(f"{hhmm(ev)} {result_line(item)}"))
    elif t == "result":
        try:
            cost = float(ev.get("total_cost_usd") or 0)
        except (TypeError, ValueError):
            cost = 0.0
        out.append(f"{hhmm(ev)} done: {ev.get('subtype') or '?'}, {ev.get('num_turns') or 0} turns, ${cost:.2f}")
    return out


def main():
    # A viewer must never take the pipe (and with it the conductor) down.
    try:
        sys.stdin.reconfigure(errors="replace")
    except (AttributeError, ValueError):
        pass
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
