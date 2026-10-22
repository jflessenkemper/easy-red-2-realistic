#!/usr/bin/env python3
"""Score a run log (Player.log with DEBUG and/or TELEMETRY on) against each feature's explicit,
measurable pass criteria in data/features.json.

Criterion types
  label_min      >= min brain decisions whose label starts with `label` (or contains it, if `label`
                 starts with '-'), parsed from `[REALISTIC] #uid ... -> LABEL` trace lines
  label_ratio    count(num)/count(den) in [lo, hi], with at least min_den samples
  event_min      >= min lines matching `regex`
  no_errors      zero Lua/engine error lines (same regex as er2-plugin/tools/analyse_run.py)
  tally_vs_telem final `tally invaders:N defenders:M` within `tol` of deaths counted independently
                 from [TELEM] frames (uids whose flag goes to `x`, by last known side)
  manual         cannot be decided from a log - reported as NEEDS-HUMAN, never as PASS

Verdict per feature: PASS (all automatic criteria pass, none manual) | FAIL | NEEDS-HUMAN |
NO-DATA (the log has nothing this feature emits). A PASS here is ONE input to promoting a status;
data/features.json still needs a clip and a hand edit. Synthetic fixtures (tests/fixtures/eval/)
prove the SCORER works; they prove nothing about the mod.

Usage: tools/eval_telemetry.py LOG [--json out.json] [--features data/features.json] [--only id,id]
"""
import json, os, re, sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TRACE = re.compile(r"\[REALISTIC\]\s+#-?\d+\s.*?->\s+(?P<label>[A-Za-z/-]+)")
ERRORS = re.compile(r"Lua error|guard\(once\)|not allowed as global variable|cannot access field|"
                    r"Error in callback function|NullReferenceException")
TALLY = re.compile(r"tally invaders:(\d+)\s+defenders:(\d+)")
TELEM_S = re.compile(r"\[TELEM\]\s+([\d.]+)\s+S\s+(.*)")

def parse(path):
    labels, lines, telem = Counter(), [], []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            lines.append(line)
            m = TRACE.search(line)
            if m: labels[m.group("label")] += 1
            m = TELEM_S.search(line)
            if m: telem.append(m.group(2))
    return labels, lines, telem

def count_label(labels, lab):
    if lab.startswith("-"):
        return sum(c for k, c in labels.items() if lab in k)
    return sum(c for k, c in labels.items() if k == lab or k.startswith(lab + "-") or k.startswith(lab + "/"))

def telem_deaths(telem):
    side, dead = {}, set()
    for batch in telem:
        for ent in batch.split(";"):
            p = ent.split(",")
            if len(p) < 5: continue
            uid, flag = p[0], p[4]
            if flag in "IiDd" and flag: side[uid] = flag.upper()
            elif flag == "x": dead.add(uid)
    inv = sum(1 for u in dead if side.get(u) == "I")
    de = sum(1 for u in dead if side.get(u) == "D")
    return inv, de

def check(c, labels, lines, telem):
    t = c["type"]
    if t == "label_min":
        n = count_label(labels, c["label"])
        return ("PASS" if n >= c["min"] else ("NO-DATA" if n == 0 else "FAIL")), "%s=%d (need >=%d)" % (c["label"], n, c["min"])
    if t == "label_ratio":
        a, b = count_label(labels, c["num"]), count_label(labels, c["den"])
        if b < c.get("min_den", 1): return ("NO-DATA" if b == 0 else "FAIL"), "%s=%d too few" % (c["den"], b)
        r = a / b
        return ("PASS" if c["lo"] <= r <= c["hi"] else "FAIL"), "%s/%s=%.2f (need %.2f..%.2f)" % (c["num"], c["den"], r, c["lo"], c["hi"])
    if t == "event_min":
        rx = re.compile(c["regex"]); n = sum(1 for l in lines if rx.search(l))
        return ("PASS" if n >= c["min"] else ("NO-DATA" if n == 0 else "FAIL")), "/%s/=%d (need >=%d)" % (c["regex"], n, c["min"])
    if t == "no_errors":
        if not lines: return "NO-DATA", "empty log"
        n = sum(1 for l in lines if ERRORS.search(l))
        return ("PASS" if n == 0 else "FAIL"), "error lines=%d" % n
    if t == "tally_vs_telem":
        ts = [TALLY.search(l) for l in lines]; ts = [m for m in ts if m]
        if not ts or not telem: return "NO-DATA", "needs both a tally line and [TELEM] frames"
        ti, td = int(ts[-1].group(1)), int(ts[-1].group(2)); ei, ed = telem_deaths(telem)
        ok = abs(ti - ei) <= c["tol"] and abs(td - ed) <= c["tol"]
        return ("PASS" if ok else "FAIL"), "tally inv=%d def=%d vs telemetry inv=%d def=%d (tol %d)" % (ti, td, ei, ed, c["tol"])
    if t == "manual":
        return "NEEDS-HUMAN", c["what"]
    return "FAIL", "unknown criterion type " + t

def evaluate(log, features, only=None):
    labels, lines, telem = parse(log)
    out = []
    for f in features:
        if only and f["id"] not in only: continue
        res = [dict(zip(("verdict", "detail"), check(c, labels, lines, telem)), type=c["type"]) for c in f["eval"]]
        vs = [r["verdict"] for r in res]
        if "FAIL" in vs: v = "FAIL"
        elif "NEEDS-HUMAN" in vs: v = "NEEDS-HUMAN"
        elif vs and all(x == "PASS" for x in vs): v = "PASS"
        else: v = "NO-DATA"
        out.append({"id": f["id"], "name": f["name"], "verdict": v, "criteria": res})
    return {"log": os.path.abspath(log), "labels": dict(labels), "telem_frames": len(telem), "features": out}

def main(argv):
    if not argv or argv[0] in ("-h", "--help"): print(__doc__); return 0
    log = argv[0]
    fp = argv[argv.index("--features") + 1] if "--features" in argv else os.path.join(ROOT, "data", "features.json")
    only = set(argv[argv.index("--only") + 1].split(",")) if "--only" in argv else None
    r = evaluate(log, json.load(open(fp, encoding="utf-8"))["features"], only)
    for f in r["features"]:
        print("%-12s %-5s %s" % (f["verdict"], f["id"], f["name"]))
        for c in f["criteria"]: print("               %-11s %s" % (c["verdict"], c["detail"]))
    tally = Counter(f["verdict"] for f in r["features"])
    print("SUMMARY " + "  ".join("%s=%d" % kv for kv in sorted(tally.items())))
    if "--json" in argv: json.dump(r, open(argv[argv.index("--json") + 1], "w"), indent=1)
    return 1 if tally.get("FAIL") else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
