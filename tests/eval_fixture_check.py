#!/usr/bin/env python3
"""Proves tools/eval_telemetry.py SCORES correctly on synthetic logs (not that the mod works)."""
import json, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import eval_telemetry as E
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
F = json.load(open(os.path.join(ROOT, "data/features.json")))["features"]
fx = lambda n: os.path.join(ROOT, "tests/fixtures/eval", n)
v = lambda r: {f["id"]: f["verdict"] for f in r["features"]}
p, f = v(E.evaluate(fx("synthetic_pass.trace"), F)), v(E.evaluate(fx("synthetic_fail.trace"), F))
bad = []
manual = {x["id"] for x in F if any(c["type"] == "manual" for c in x["eval"])}
for k, verdict in p.items():
    want = "NEEDS-HUMAN" if k in manual else "PASS"
    if verdict != want: bad.append("pass fixture: %s=%s want %s" % (k, verdict, want))
for k in ("4", "23", "26", "27", "29"):
    if f.get(k) != "FAIL": bad.append("fail fixture: %s=%s want FAIL" % (k, f.get(k)))
if "PASS" in {p[k] for k in manual}: bad.append("a manual criterion scored PASS")
# The evidence gate: a hand-promoted status without clip + eval PASS must be refused.
import build_evidence as BE
probe = dict(F[0], status="proven", baseline_status="partial", evidence={"clip": None, "eval_pass": None})
if BE.gate(probe) is None: bad.append("evidence gate accepted a promotion with no clip/eval")
probe["evidence"] = {"clip": "README.md", "eval_pass": None}
if BE.gate(probe) is None: bad.append("evidence gate accepted a promotion with a clip but no eval PASS")
if any(BE.gate(x) for x in F): bad.append("data/features.json contains an unearned promotion")
for b in bad: print("FAIL  " + b)
if not bad: print("ok    eval scorer: %d features PASS/NEEDS-HUMAN on the pass fixture, 5 forced FAILs caught; evidence gate refuses unearned promotions" % len(p))
sys.exit(1 if bad else 0)
