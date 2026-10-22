#!/usr/bin/env python3
"""State-log (SLOG) contract, extractor and loader.

The brain (feature/state-logger) writes `[SLOG] <rec>\t<rec>...` lines into Player.log, where
each <rec> is one JSON object. This module turns those into JSONL with one record per line and a
leading run header, which is the shape tools/replay_viz.py, tools/eval_telemetry.py (slog_*
criteria) and tools/run_diff.py all consume.

Record kinds
  run  {"k":"run","mission","seed","mod_sha","build","flags","synthetic"}  (added by `extract`)
  s    per-entity sample: t,id,tm,x,y,z,hdg,hsrc,spd,crawl,run,aim,rld,cover,sup,supv,hp,down,
       veh,seat,arm,carry,dec,role,fr
  e    event: t,id,tm,x,y,z,ev[,from,to,dhp,veh]

Deterministic framing: a run is only comparable to another with the SAME mission + seed + mod
sha + flags. ER2's engine RNG is not seedable from Lua. The seed fixes the Lua side only (each
brain already calls math.randomseed(uid)), so run-to-run spread still has to be measured.

Usage
  slog.py extract Player.log out.jsonl --mission NAME --seed N [--build ID] [--synthetic]
  slog.py validate run.jsonl
"""
import json, os, re, subprocess, sys

SLOG_LINE = re.compile(r"\[SLOG\]\s(.*)")
SAMPLE_KEYS = ("t", "id", "tm", "x", "y", "z")
EVENT_KEYS = ("t", "id", "ev")
KNOWN_EVENTS = {"suppressed", "unsuppressed", "went_prone", "stood_up", "mounted", "rode_tank",
                "dismounted", "hit", "healed", "incapacitated", "drag_start", "drag_end",
                "decision", "died", "out_of_range", "in_range"}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def parse_log_lines(lines):
    recs = []
    for line in lines:
        m = SLOG_LINE.search(line)
        if not m: continue
        for chunk in m.group(1).rstrip("\n").split("\t"):
            chunk = chunk.strip()
            if not chunk: continue
            try: recs.append(json.loads(chunk))
            except ValueError: recs.append({"k": "bad", "raw": chunk[:200]})
    return recs

def mod_sha():
    try:
        return subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"],
                              capture_output=True, text=True).stdout.strip() or None
    except OSError:
        return None

def load(path):
    """-> (header dict, list of records). Accepts JSONL or a raw Player.log."""
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    if lines and lines[0].lstrip().startswith("{"):
        recs = [json.loads(l) for l in lines if l.strip()]
    else:
        recs = parse_log_lines(lines)
    hdr = recs[0] if recs and recs[0].get("k") == "run" else {"k": "run"}
    body = [r for r in recs if r.get("k") in ("s", "e")]
    return hdr, body

def validate(recs):
    errs = []
    for i, r in enumerate(recs):
        k = r.get("k")
        if k == "bad": errs.append("rec %d: not JSON: %s" % (i, r["raw"])); continue
        if k == "s":
            miss = [x for x in SAMPLE_KEYS if x not in r]
            if miss: errs.append("rec %d: sample missing %s" % (i, miss))
            if r.get("tm") not in ("I", "D", "?"): errs.append("rec %d: bad team %r" % (i, r.get("tm")))
        elif k == "e":
            miss = [x for x in EVENT_KEYS if x not in r]
            if miss: errs.append("rec %d: event missing %s" % (i, miss))
            elif r["ev"] not in KNOWN_EVENTS: errs.append("rec %d: unknown event %r" % (i, r["ev"]))
        elif k != "run":
            errs.append("rec %d: unknown kind %r" % (i, k))
    return errs

def main(argv):
    if not argv or argv[0] in ("-h", "--help"): print(__doc__); return 0
    if argv[0] == "extract":
        src, dst = argv[1], argv[2]
        opt = lambda n, d=None: argv[argv.index(n) + 1] if n in argv else d
        with open(src, encoding="utf-8", errors="replace") as f:
            recs = parse_log_lines(f)
        hdr = {"k": "run", "mission": opt("--mission"), "seed": opt("--seed"), "build": opt("--build"),
               "mod_sha": mod_sha(), "synthetic": "--synthetic" in argv, "source": os.path.abspath(src)}
        errs = validate(recs)
        with open(dst, "w") as o:
            o.write(json.dumps(hdr) + "\n")
            for r in recs: o.write(json.dumps(r, separators=(",", ":")) + "\n")
        print("extracted %d records (%d invalid) -> %s" % (len(recs), len(errs), dst))
        for e in errs[:10]: print("  " + e)
        return 1 if errs else 0
    if argv[0] == "validate":
        hdr, body = load(argv[1]); errs = validate(body)
        print("%s: %d records, %d invalid, mission=%s seed=%s synthetic=%s" %
              (argv[1], len(body), len(errs), hdr.get("mission"), hdr.get("seed"), hdr.get("synthetic")))
        for e in errs[:10]: print("  " + e)
        return 1 if errs or not body else 0
    print(__doc__); return 2

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
