#!/usr/bin/env python3
"""Judge a diorama run on WORLD STATE, not on decision labels.

WHY THIS EXISTS. Every earlier verdict on the demonstration range was wrong in a different way,
and each time the mistake was reading a count as if it were behaviour:

  * "11 of 13 stations working" - from 41 log lines across 13 stations, most of them defender-side
    squads correctly holding. Meaningless.
  * "the range collapsed to one busy station" - from station 1 carrying 36% of the log lines. It
    carried 8 of 113 soldiers. The brain logs on CHANGE, so a road-march demo is loud and a
    holding squad is silent; log volume is not activity.

So this tool reports the things that are actually true of the world: how many DISTINCT soldiers
were at each station, how far they drifted from their marks, whether the scripted casualty fired,
and only then which decisions appeared - clearly labelled as the weakest of the four signals.

Usage: tools/diorama_audit.py <player.log>
"""
import math
import re
import sys
from collections import defaultdict


def main(path):
    txt = open(path, encoding="utf-8", errors="replace").read()

    stations = {}
    for m in re.finditer(r"\[SHOWCASE\] station (\d+)\s+@\((-?\d+),(-?\d+)\)\s+(.*)", txt):
        stations[int(m.group(1))] = (float(m.group(2)), float(m.group(3)), m.group(4).strip())
    if not stations:
        print("no [SHOWCASE] station lines - was the range built at all?")
        return 1

    samples = []
    for m in re.finditer(
        r"\[REALISTIC\] #(-?\d+) t=([\d.]+) (\w+)/([\w-]+) @\((-?\d+),(-?\d+)\).*?-> ([A-Za-z-]+)",
        txt,
    ):
        samples.append((m.group(1), float(m.group(2)), m.group(3),
                        float(m.group(5)), float(m.group(6)), m.group(7)))

    def nearest(x, z):
        best, bd = None, 1e18
        for n, (sx, sz, _) in stations.items():
            d = math.hypot(x - sx, z - sz)
            if d < bd:
                best, bd = n, d
        return best, bd

    uids = defaultdict(set)
    decs = defaultdict(lambda: defaultdict(int))
    last = {}
    for uid, t, doc, x, z, dec in samples:
        n, d = nearest(x, z)
        if d <= 220:
            uids[n].add(uid)
            if doc == "germany":
                decs[n][dec] += 1
        last[uid] = (x, z)

    rounds = len(re.findall(r"DIORAMA: round \d+ over", txt))
    hurt = len(re.findall(r"a man is down", txt))
    deaths = len(re.findall(r"killed by", txt))
    errs = len(re.findall(r"(?i)exception|attempt to |bad argument", txt))

    print("rounds completed      %d" % rounds)
    print("scripted casualties   %d   (station 8 needs one per round)" % hurt)
    print("deaths                %d   (heal tick should hold this at 0)" % deaths)
    print("error lines           %d" % errs)
    print("distinct soldiers     %d" % len({s[0] for s in samples}))
    print("samples               %d" % len(samples))

    drift = []
    for uid, (x, z) in last.items():
        _, d = nearest(x, z)
        drift.append(d)
    if drift:
        drift.sort()
        beyond = sum(1 for d in drift if d > 220)
        print("\nDRIFT at last sample: median %.0f m, 90th %.0f m, max %.0f m; %d of %d beyond 220 m"
              % (drift[len(drift) // 2], drift[int(len(drift) * 0.9)], drift[-1], beyond, len(drift)))

    print("\n%-4s %-6s %s" % ("st", "men", "decisions seen on the INVADER side (weakest signal)"))
    thin = []
    for n in sorted(stations):
        men = len(uids[n])
        if men <= 2:
            thin.append(n)
        top = ", ".join("%s x%d" % (k, v)
                        for k, v in sorted(decs[n].items(), key=lambda kv: -kv[1])[:3])
        print("%-4d %-6d %s" % (n, men, top or "--"))
    if thin:
        print("\nUNDER-POPULATED stations (<=2 men sampled): %s" % ", ".join(map(str, thin)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else
                  "%s/.config/unity3d/Corvostudio/Easy Red 2/Player.log" % __import__("os").environ["HOME"]))
