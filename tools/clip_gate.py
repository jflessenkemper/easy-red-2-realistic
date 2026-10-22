#!/usr/bin/env python3
"""'Record a clip only after the eval passes' gate.

A clip is evidence of something the DATA already showed, not a substitute for it. So before any
capture tool records a clip for feature X, this gate needs an eval_telemetry.py JSON from a REAL run
(header not synthetic) in which X has no FAIL criterion and at least one automatic criterion
(label/event/slog) PASSES. Manual-only features (22, 24, ...) have nothing automatic to pass, so
they need --manual: their clip IS the evidence and is reviewed by a human.

Usage: clip_gate.py --features 3,16 --eval run_eval.json [--manual] [--allow-synthetic]
Exit 0 = allowed. Library: check(ids, eval_path, manual=False, allow_synthetic=False) -> (ok, why)
"""
import json, os, sys

AUTO = ("label_min", "label_ratio", "event_min", "no_errors", "tally_vs_telem", "slog_event_min", "slog_reaction")

def check(ids, eval_path, manual=False, allow_synthetic=False):
    if not eval_path or not os.path.isfile(eval_path):
        return False, "no eval JSON: run tools/eval_telemetry.py LOG --json out.json first"
    r = json.load(open(eval_path, encoding="utf-8"))
    if (r.get("run") or {}).get("synthetic") and not allow_synthetic:
        return False, "eval came from a SYNTHETIC run; clips must follow a real run"
    by = {f["id"]: f for f in r.get("features", [])}
    for i in ids:
        f = by.get(i)
        if not f: return False, "feature %s was not scored in %s" % (i, eval_path)
        cr = f["criteria"]
        if any(c["verdict"] == "FAIL" for c in cr):
            return False, "feature %s has a FAILING criterion" % i
        auto = [c for c in cr if c["type"] in AUTO]
        if not auto:
            if not manual: return False, "feature %s is manual-only; pass --manual (the clip is then the evidence)" % i
            continue
        if not any(c["verdict"] == "PASS" for c in auto):
            return False, "feature %s: no automatic criterion PASSED (all NO-DATA/NO-SLOG)" % i
    return True, "eval %s passes for %s" % (os.path.basename(eval_path), ",".join(ids))

def main(argv):
    if "--features" not in argv: print(__doc__); return 2
    ids = argv[argv.index("--features") + 1].split(",")
    ev = argv[argv.index("--eval") + 1] if "--eval" in argv else None
    ok, why = check(ids, ev, "--manual" in argv, "--allow-synthetic" in argv)
    print(("ALLOWED  " if ok else "REFUSED  ") + why)
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
