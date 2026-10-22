#!/usr/bin/env python3
"""Run-to-run diff of two state-log runs under deterministic-scenario framing.

A run is framed by its header: mission + seed + mod sha + flags. Two runs are only COMPARABLE when
mission and seed match. A different mod sha is the A/B case (the thing being tested). Different flags
are reported as a confound. ER2's engine RNG is NOT seedable from Lua (the seed fixes only the
brains' math.random, already seeded per uid), so identical framing still yields different battles.
Judge a delta against the measured run-to-run spread of repeated runs (tools/soak.sh), never as
a single A-vs-B number.

Reports: framing check, event counts, decision-transition counts, deaths, time-to-first per event,
per-feature eval_slog verdicts and their changes.

Usage: run_diff.py A.jsonl B.jsonl [--json out.json] [--fail-on-regression]
"""
import json, os, sys
from collections import Counter
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import slog as SL, eval_telemetry as E

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def summarise(path, feats):
    hdr, recs = SL.load(path)
    ev = [r for r in recs if r["k"] == "e"]
    first = {}
    for r in ev: first.setdefault(r["ev"], r["t"])
    verd = {}
    for f in feats:
        if not f.get("eval_slog"): continue
        vs = [E.check_slog(c, recs)[0] for c in f["eval_slog"]]
        verd[f["id"]] = "FAIL" if "FAIL" in vs else ("PASS" if all(v == "PASS" for v in vs) else "NO-SLOG")
    return {"hdr": hdr, "events": Counter(r["ev"] for r in ev),
            "decisions": Counter(r.get("to") for r in ev if r["ev"] == "decision"),
            "entities": len({r["id"] for r in recs}), "first": first, "verdicts": verd}

def framing(a, b):
    notes, comparable = [], True
    for k in ("mission", "seed"):
        if a.get(k) != b.get(k): comparable = False; notes.append("%s differs: %r vs %r" % (k, a.get(k), b.get(k)))
    if a.get("mod_sha") != b.get("mod_sha"): notes.append("mod sha differs (A/B): %s vs %s" % (a.get("mod_sha"), b.get("mod_sha")))
    if a.get("flags") != b.get("flags"): notes.append("CONFOUND: flags differ %r vs %r" % (a.get("flags"), b.get("flags")))
    if a.get("synthetic") or b.get("synthetic"): notes.append("SYNTHETIC input: this diff proves the tool, not the mod")
    return comparable, notes

def table(title, ca, cb):
    keys = sorted(set(ca) | set(cb), key=str)
    rows = ["%s" % title] + ["  %-24s %6s %6s %+6d" % (k, ca.get(k, 0), cb.get(k, 0), cb.get(k, 0) - ca.get(k, 0)) for k in keys]
    return rows

def main(argv):
    if len(argv) < 2 or argv[0] in ("-h", "--help"): print(__doc__); return 0
    feats = json.load(open(os.path.join(ROOT, "data", "features.json")))["features"]
    A, B = summarise(argv[0], feats), summarise(argv[1], feats)
    comp, notes = framing(A["hdr"], B["hdr"])
    out = ["FRAMING  %s" % ("COMPARABLE (same mission+seed)" if comp else "NOT COMPARABLE")] + ["  " + n for n in notes]
    out += ["entities %d vs %d" % (A["entities"], B["entities"])]
    out += table("events                      A      B  delta", A["events"], B["events"])
    out += table("decision transitions (to)   A      B  delta", A["decisions"], B["decisions"])
    out += ["time to first event"] + ["  %-24s %6s %6s" % (k, A["first"].get(k, "-"), B["first"].get(k, "-"))
                                      for k in sorted(set(A["first"]) | set(B["first"]))]
    regress = []
    out += ["feature eval_slog verdicts"]
    for k in sorted(set(A["verdicts"]) | set(B["verdicts"])):
        va, vb = A["verdicts"].get(k, "-"), B["verdicts"].get(k, "-")
        mark = "  REGRESSION" if va == "PASS" and vb == "FAIL" else ("  fixed" if va == "FAIL" and vb == "PASS" else "")
        if mark.strip() == "REGRESSION": regress.append(k)
        out.append("  %-6s %-8s %-8s%s" % (k, va, vb, mark))
    print("\n".join(out))
    if "--json" in argv:
        json.dump({"comparable": comp, "notes": notes, "a": A, "b": B, "regressions": regress},
                  open(argv[argv.index("--json") + 1], "w"), indent=1, default=dict)
    return 1 if ("--fail-on-regression" in argv and regress) or not comp else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
