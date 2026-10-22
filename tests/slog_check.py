#!/usr/bin/env python3
"""State-log pipeline check on SYNTHETIC fixtures (proves the tooling, not the mod).

  1. make_synthetic.py writes deterministic a/b/fail runs, and two generations are byte-identical
  2. every record validates against the slog contract
  3. eval_slog: run a PASSes 3/16/17/B8; run fail FAILs 3 and 16; NO-SLOG leaves verdicts alone
  4. run_diff: a vs b is COMPARABLE and flags the 17 regression; a vs a re-framed seed is NOT comparable
  5. the capture gate refuses a clip without an eval PASS, and allows one with it
  6. replay_viz builds a self-contained HTML (skipped if plotly.js is absent; then it says so)
Usage: slog_check.py OUTDIR [--demo evidence/replays/synthetic-demo.html]
"""
import filecmp, io, json, os, subprocess, sys, contextlib
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
import slog as SL, eval_telemetry as E, run_diff as RD, clip_gate as G

out = sys.argv[1]; bad = []
gen = os.path.join(HERE, "fixtures", "slog", "make_synthetic.py")
for d in (out, out + "/regen"):
    subprocess.run([sys.executable, gen, d], check=True, capture_output=True)
for v in ("a", "b", "fail"):
    p = os.path.join(out, "synthetic_%s.jsonl" % v)
    if not filecmp.cmp(p, os.path.join(out, "regen", "synthetic_%s.jsonl" % v), shallow=False):
        bad.append("fixture %s is not deterministic" % v)
    hdr, recs = SL.load(p)
    if not hdr.get("synthetic"): bad.append("fixture %s header lacks synthetic=true" % v)
    errs = SL.validate(recs)
    if errs: bad.append("fixture %s: %d invalid records, e.g. %s" % (v, len(errs), errs[0]))
F = json.load(open(os.path.join(ROOT, "data", "features.json")))["features"]
def slogv(run):
    r = E.evaluate(os.devnull, F, {"3", "16", "17", "B8"}, os.path.join(out, "synthetic_%s.jsonl" % run))
    return {f["id"]: [c["verdict"] for c in f["criteria"] if c["type"].startswith("slog_")] for f in r["features"]}
a, fl = slogv("a"), slogv("fail")
for k in ("3", "16", "17", "B8"):
    if set(a[k]) != {"PASS"}: bad.append("run a: feature %s slog verdicts %s, want all PASS" % (k, a[k]))
for k in ("3", "16"):
    if "FAIL" not in fl[k]: bad.append("run fail: feature %s slog verdicts %s, want a FAIL" % (k, fl[k]))
r0 = E.evaluate(os.path.join(HERE, "fixtures", "eval", "synthetic_pass.trace"), F)
if any(c["verdict"] == "NO-SLOG" and f["verdict"] == "FAIL" for f in r0["features"] for c in f["criteria"]):
    bad.append("NO-SLOG changed a verdict on a log without state records")
A = RD.summarise(os.path.join(out, "synthetic_a.jsonl"), F); B = RD.summarise(os.path.join(out, "synthetic_b.jsonl"), F)
comp, _ = RD.framing(A["hdr"], B["hdr"])
if not comp: bad.append("run_diff: a vs b should be comparable")
if not (A["verdicts"].get("17") == "PASS" and B["verdicts"].get("17") == "FAIL"): bad.append("run_diff: missed the 17 regression")
if RD.framing(A["hdr"], dict(A["hdr"], seed=1))[0]: bad.append("run_diff: different seed was called comparable")
# capture gate
evp = os.path.join(out, "eval_a.json")
json.dump(E.evaluate(os.devnull, F, {"3"}, os.path.join(out, "synthetic_a.jsonl")), open(evp, "w"))
evf = os.path.join(out, "eval_fail.json")
json.dump(E.evaluate(os.devnull, F, {"3"}, os.path.join(out, "synthetic_fail.jsonl")), open(evf, "w"))
if G.check(["3"], None)[0]: bad.append("clip gate allowed a clip with no eval JSON")
if G.check(["3"], evf)[0]: bad.append("clip gate allowed a clip whose eval FAILED")
ok_s, why = G.check(["3"], evp, allow_synthetic=True)
if not ok_s: bad.append("clip gate refused a slog-PASS eval (synthetic allowed): %s" % why)
if G.check(["3"], evp)[0]: bad.append("clip gate accepted a SYNTHETIC eval as real")
# replay
demo = sys.argv[sys.argv.index("--demo") + 1] if "--demo" in sys.argv else os.path.join(out, "demo.html")
import replay_viz as RV
if os.path.exists(RV.PLOTLY):
    with contextlib.redirect_stdout(io.StringIO()):
        r = RV.build([os.path.join(out, "synthetic_%s.jsonl" % v) for v in ("a", "b", "fail")], demo, "SYNTHETIC demo replay")
    html = open(demo, encoding="utf-8").read()
    for needle in ("SYNTHETIC FIXTURE", "plotly.js v2.35.2", "histogram2d", "decision timeline", "id=\"scrub\""):
        if needle not in html: bad.append("replay html lacks %r" % needle)
    if "cdn.plot.ly" in html.split("plotly.js v2.35.2")[0] or "<script src=" in html: bad.append("replay is not self-contained")
    rep = "replay demo %s (%d KB)" % (os.path.relpath(demo, ROOT), r["bytes"] // 1024)
else:
    rep = "replay SKIPPED (no plotly.js at %s)" % RV.PLOTLY
for b in bad: print("FAIL  " + b)
if not bad: print("ok    slog pipeline: 3 deterministic SYNTHETIC runs valid; eval_slog PASS/FAIL as scripted; run_diff framing + regression; clip gate; " + rep)
sys.exit(1 if bad else 0)
