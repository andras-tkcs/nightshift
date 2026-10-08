#!/usr/bin/env python3
"""Risk floor of a diff: ns-conductor risk-check.

Usage: riskcheck.py <profile json file>   (the changed paths, one per line, on stdin)
Prints one JSON object: {"tags": [...], "floor": "T0"|"T1"}.

A path in a risk zone's paths gives the tags sec-compliance and risk:<zone>; a path in
platform_paths for a platform whose verify is ci gives platform:<p>. Any tag means floor T1.
Globs: ** matches across directories (a leading **/ also matches no directory), * and ? stay
within one path segment.
"""
import json
import re
import sys


def rx(glob):
    out, i = "", 0
    while i < len(glob):
        c = glob[i]
        if glob.startswith("**/", i):
            out += "(?:.*/)?"
            i += 3
        elif glob.startswith("**", i):
            out += ".*"
            i += 2
        elif c == "*":
            out += "[^/]*"
            i += 1
        elif c == "?":
            out += "[^/]"
            i += 1
        else:
            out += re.escape(c)
            i += 1
    return re.compile("^" + out + "$")


def main():
    with open(sys.argv[1], encoding="utf-8") as f:
        prof = json.load(f)
    files = [p for p in sys.stdin.read().split("\n") if p]
    tags = []

    def add(t):
        if t not in tags:
            tags.append(t)

    for zone, v in sorted((prof.get("risk_zones") or {}).items()):
        pats = [rx(g) for g in (v or {}).get("paths", [])]
        if any(p.match(f) for p in pats for f in files):
            add("sec-compliance")
            add("risk:" + zone)
    plats = prof.get("platforms") or {}
    for plat, globs in sorted((prof.get("platform_paths") or {}).items()):
        if (plats.get(plat) or {}).get("verify") != "ci":
            continue
        if any(rx(g).match(f) for g in globs for f in files):
            add("platform:" + plat)
    json.dump({"tags": tags, "floor": "T1" if tags else "T0"}, sys.stdout)
    sys.stdout.write("\n")


main()
