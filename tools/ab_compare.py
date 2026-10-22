#!/usr/bin/env python3
"""A/B comparison: stock AI vs Realistic on the SAME seeded mission. PREPARED, NOT YET RUN.

Protocol (needs the game; Jordan at the keyboard; nothing here launches anything):
  1. Pick one mission and fix everything that can be fixed: same map, same OOB, same spawn
     positions, same camera, same duration (e.g. ME_Stonne_38n85202, 15 min).
  2. Arm A = stock brains (deploy WITHOUT Realistic), Arm B = Realistic with TELEMETRY=true.
     Telemetry must be on in BOTH arms or the comparison is not like-for-like.
  3. Run each arm >= 3 times (the formation metric's own run-to-run spread is 0.20-0.23, so
     single runs cannot separate effect from variance). Save Player.log per run.
  4. tools/eval_telemetry.py <log> --json <arm>-<n>.json   for every run
  5. tools/ab_compare.py A-1.json A-2.json A-3.json -- B-1.json B-2.json B-3.json
  6. Restore the shipping build; verify TELEMETRY/DEBUG=false on the DEPLOYED files.

Output: per-label mean count per arm, the B-A difference, and whether |diff| exceeds the larger
arm's min-max spread (a crude but honest "outside the noise" test). Only a difference outside
the noise band may be quoted as an effect.
"""
import json, sys
from statistics import mean

def load(paths): return [json.load(open(p)) for p in paths]

def main(a):
    if "--" not in a or a[0] in ("-h", "--help"): print(__doc__); return 0
    i = a.index("--"); A, B = load(a[:i]), load(a[i + 1:])
    labs = sorted(set().union(*[r["labels"] for r in A + B]))
    print("%-26s %9s %9s %9s  %s" % ("label", "A mean", "B mean", "B-A", "outside noise?"))
    for l in labs:
        xa = [r["labels"].get(l, 0) for r in A]; xb = [r["labels"].get(l, 0) for r in B]
        spread = max(max(xa) - min(xa), max(xb) - min(xb))
        d = mean(xb) - mean(xa)
        print("%-26s %9.1f %9.1f %+9.1f  %s" % (l, mean(xa), mean(xb), d, "YES" if abs(d) > spread else "no"))
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
