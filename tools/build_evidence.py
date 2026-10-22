#!/usr/bin/env python3
"""Build the local evidence gallery: evidence/index.html + evidence/f-<id>.html per feature.

Driven ONLY by data/features.json (status, evidence links) plus whatever offline results exist in
artifacts/review/ (review.json, busted.tap, mutation.json, eval_synthetic.json, locals.txt).
STATUS IS NEVER COMPUTED HERE. A status above `baseline_status` is refused (exit 1) unless the
feature carries BOTH evidence.clip (an existing file, recorded at 30 fps) AND evidence.eval_pass (an
eval_telemetry.py JSON in which this feature's verdict is PASS). Offline results can never promote.

Usage: tools/build_evidence.py            (regenerated at the end of tests/review.sh)
"""
import html, json, os, re, sys, datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "evidence")
REV = os.path.join(ROOT, "artifacts", "review")
RANK = {"unproven": 0, "partial": 1, "proven": 2}
DIAGRAMS = {"4": "docs/images/tactics-bounding-and-armour.svg", "5": "docs/images/tactics-bounding-and-armour.svg",
            "4b": "docs/images/formation-staggered-file.svg", "3": "docs/images/decision-cascade.svg"}
E = html.escape

def jload(p, default=None):
    try: return json.load(open(p, encoding="utf-8"))
    except Exception: return default

def readtxt(p):
    try: return open(p, encoding="utf-8", errors="replace").read()
    except Exception: return ""

def gate(f):
    """Return an error string if this feature's status is an unearned promotion."""
    if RANK[f["status"]] <= RANK[f["baseline_status"]]: return None
    ev = f.get("evidence", {})
    clip, evp = ev.get("clip"), ev.get("eval_pass")
    if not clip or not os.path.isfile(os.path.join(ROOT, clip)):
        return "status %s > baseline %s but evidence.clip is missing" % (f["status"], f["baseline_status"])
    r = jload(os.path.join(ROOT, evp)) if evp else None
    if not r or not any(x["id"] == f["id"] and x["verdict"] == "PASS" for x in r.get("features", [])):
        return "status %s > baseline %s but evidence.eval_pass does not show this feature PASSING" % (f["status"], f["baseline_status"])
    return None

CSS = """
:root{--bg:#f2f3f7;--ink:#1d1d1f;--mute:#6e6e73;--glass:rgba(255,255,255,.62);--line:rgba(0,0,0,.08);
--ok:#1f9d55;--part:#c27c0e;--no:#c2410c;--acc:#0a66d8}
@media (prefers-color-scheme:dark){:root{--bg:#0f1115;--ink:#f5f5f7;--mute:#a1a1a6;--glass:rgba(30,32,38,.62);--line:rgba(255,255,255,.09)}}
*{box-sizing:border-box}body{margin:0;font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Inter",system-ui,sans-serif;
color:var(--ink);background:radial-gradient(1200px 600px at 10% -10%,rgba(10,102,216,.10),transparent),
radial-gradient(900px 500px at 110% 10%,rgba(194,124,14,.08),transparent),var(--bg);min-height:100vh}
main{max-width:1080px;margin:0 auto;padding:40px 24px 80px}
h1{font-size:30px;letter-spacing:-.02em;margin:0 0 4px}h2{font-size:19px;margin:32px 0 12px;letter-spacing:-.01em}
.sub{color:var(--mute);margin:0 0 24px}a{color:var(--acc);text-decoration:none}a:hover{text-decoration:underline}
.glass{background:var(--glass);backdrop-filter:blur(20px) saturate(160%);-webkit-backdrop-filter:blur(20px) saturate(160%);
border:1px solid var(--line);border-radius:18px;padding:18px 20px;box-shadow:0 1px 2px rgba(0,0,0,.04),0 8px 30px rgba(0,0,0,.05)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:14px}
.card{display:block;color:inherit;transition:transform .15s ease}.card:hover{transform:translateY(-2px);text-decoration:none}
.badge{display:inline-block;font-size:12px;font-weight:600;padding:2px 10px;border-radius:999px;color:#fff}
.b-proven{background:var(--ok)}.b-partial{background:var(--part)}.b-unproven{background:var(--no)}
.pill{display:inline-block;font-size:12px;padding:1px 8px;border-radius:999px;border:1px solid var(--line);color:var(--mute);margin-right:4px}
table{width:100%;border-collapse:collapse;font-size:14px}td,th{text-align:left;padding:7px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--mute);font-weight:500}.pass{color:var(--ok);font-weight:600}.fail{color:var(--no);font-weight:600}.skip,.na{color:var(--mute)}
.slot{aspect-ratio:16/9;border-radius:14px;border:1px dashed var(--line);display:flex;align-items:center;justify-content:center;color:var(--mute);background:rgba(127,127,127,.06)}
video,img.shot{width:100%;max-width:960px;border-radius:14px}
.row{display:grid;grid-template-columns:1fr 1fr;gap:14px}@media(max-width:760px){.row{grid-template-columns:1fr}}
.kpi{display:flex;gap:14px;flex-wrap:wrap}.kpi .glass{flex:1;min-width:150px}.kpi b{font-size:26px;display:block}
.check{list-style:none;padding:0;margin:0}.check li{padding:6px 0;border-bottom:1px solid var(--line)}
.check li:before{content:"\\25CB  ";color:var(--mute)}.check li.done:before{content:"\\25CF  ";color:var(--ok)}
code{font:13px ui-monospace,SFMono-Regular,Menlo,monospace;background:rgba(127,127,127,.12);padding:1px 5px;border-radius:6px}
"""

def page(title, body):
    return ("<!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
            "<title>%s</title><style>%s</style><body><main>%s</main></body></html>") % (E(title), CSS, body)

def badge(s): return "<span class='badge b-%s'>%s</span>" % (s, s.upper())

def busted_results():
    tap = readtxt(os.path.join(REV, "busted.tap"))
    return re.findall(r"^(ok|not ok) \d+ (.*)$", tap, re.M)

def feature_page(f, ctx):
    ev = f.get("evidence", {})
    clip = ev.get("clip")
    if clip and os.path.isfile(os.path.join(ROOT, clip)):
        media = "<video controls preload=metadata src='../%s'></video><p class=sub>Clip: <code>%s</code> (rule: 30 fps, &le;960 px wide)</p>" % (E(clip), E(clip))
    else:
        media = "<div class=slot>No clip yet &middot; 30 fps, &le;960 px wide &middot; pending in-game capture</div>"
    shots = "".join("<img class=shot src='../%s' alt=''>" % E(s) for s in ev.get("screenshots", []))
    if f["id"] in DIAGRAMS:
        shots += "<p class=sub>Diagram (explanatory, not evidence):</p><img class=shot src='../%s' alt=''>" % DIAGRAMS[f["id"]]
    if not shots: shots = "<div class=slot style='aspect-ratio:4/1'>No screenshots yet</div>"
    # offline tests: busted lines naming this feature
    key = "feature %s " % f["id"]
    bl = [(s, n) for s, n in ctx["busted"] if key in n + " "]
    trs = "".join("<tr><td class=%s>%s</td><td>%s</td></tr>" % ("pass" if s == "ok" else "fail", "PASS" if s == "ok" else "FAIL", E(n)) for s, n in bl)
    tests = "<p>Declared offline coverage: %s</p>" % (" ".join("<span class=pill>%s</span>" % E(t) for t in f["offline_tests"]) or "<span class=na>none</span>")
    tests += "<table><tr><th>busted</th><th>spec</th></tr>%s</table>" % trs if trs else "<p class=na>No busted spec names this feature (its coverage, if any, is in the offline harnesses above).</p>"
    mut = ctx["mutation"]
    mut_s = ("Project-wide pure-logic mutation score: <b>%s%%</b> (%s/%s killed). See RELEASE-READINESS.md." % (mut["score"], mut["killed"], mut["total"])) if mut else "<span class=na>tools/mutate.py not run yet</span>"
    evs = ctx["eval"].get(f["id"])
    evrows = "".join("<tr><td>%s</td><td>%s</td><td>%s</td></tr>" % (E(c["type"]), E(c["verdict"]), E(c["detail"])) for c in (evs["criteria"] if evs else []))
    crit = "".join("<li>%s</li>" % E(json.dumps(c)) for c in f["eval"])
    ab = ev.get("ab_result")
    body = """<p><a href=index.html>&larr; All features</a></p>
<h1>%s &nbsp;%s</h1><p class=sub>Feature %s &middot; branch <code>%s</code></p>
<div class=glass><b>Expected behaviour.</b> %s<br><span class=sub>%s</span></div>
<h2>Clip</h2>%s<h2>Screenshots</h2>%s
<h2>Offline tests</h2><div class=glass>%s</div>
<h2>Lint &amp; mutation</h2><div class=glass>Lint gates apply to the whole script (see summary): %s<br>%s</div>
<h2>Eval criteria</h2><div class=glass><ul>%s</ul>
<p class=sub>Scored below against the <b>synthetic</b> fixture only &mdash; proves the scorer, not the mod.</p>
<table><tr><th>type</th><th>verdict</th><th>detail</th></tr>%s</table></div>
<h2>A/B result</h2><div class=glass>%s</div>""" % (
        E(f["name"]), badge(f["status"]), E(f["id"]), E(f["branch"]), E(f["expected"]), E(f["note"]),
        media, shots, tests, ctx["lint_line"], mut_s, crit, evrows,
        E(ab) if ab else "<span class=na>Pending: tools/ab_compare.py protocol, needs the game (not run).</span>")
    return page("%s — %s" % (f["id"], f["name"]), body)

GO = [
    ("Offline review gate green (tests/review.sh; 4l drift explained)", "review"),
    ("No feature status above its baseline without clip + eval PASS", "gate"),
    ("Main-chunk locals <= 200 in both scripts on the release branch", "locals"),
    ("In-game visual check done (needs Steam launch option)", None),
    ("Donchery telemetry run on ME_Stonne_38n85202; 7, 9, 13, 23 decided from positions", None),
    ("README clips re-recorded at 30 fps, <=960 px wide; 22 and 24 captured", None),
    ("Prop ids harvested (palette-read) and one file loaded into a backed-up map", None),
    ("Shipping build restored; TELEMETRY/DEBUG=false verified on DEPLOYED files; check.sh 4l green", None),
    ("Jordan's explicit go-ahead to tag v1.5.0", None),
]

def main():
    data = jload(os.path.join(ROOT, "data", "features.json"))
    feats = data["features"]
    errs = [(f["id"], g) for f in feats for g in [gate(f)] if g]
    review = jload(os.path.join(REV, "review.json"), {}) or {}
    mutation = jload(os.path.join(REV, "mutation.json"))
    evj = jload(os.path.join(REV, "eval_synthetic.json"), {}) or {}
    ctx = {"busted": busted_results(), "mutation": mutation,
           "eval": {x["id"]: x for x in evj.get("features", [])}}
    lint = [(k, review.get(k)) for k in ("luacheck", "luals", "semgrep", "locals", "ruff", "shellcheck")]
    ctx["lint_line"] = " ".join("<span class=pill>%s: %s</span>" % (k, (v or {}).get("status", "not run")) for k, v in lint)
    os.makedirs(OUT, exist_ok=True)
    for f in feats:
        open(os.path.join(OUT, "f-%s.html" % f["id"]), "w", encoding="utf-8").write(feature_page(f, ctx))
    counts = {s: sum(1 for f in feats if f["status"] == s) for s in RANK}
    gating = [v for k, v in review.items() if not k.startswith("_")]
    review_green = bool(gating) and all(v["status"] != "fail" for v in gating)
    done = {"review": review_green, "gate": not errs,
            "locals": (review.get("locals") or {}).get("status") == "pass"}
    checklist = "".join("<li class='%s'>%s</li>" % ("done" if k and done.get(k) else "", E(t)) for t, k in GO)
    verdict = "NO-GO" if not all(done.get(k, False) if k else False for _, k in GO) else "GO"
    rrows = "".join("<tr><td>%s</td><td class=%s>%s</td><td>%s</td></tr>" % (E(k), v["status"], v["status"].upper(), E(v["detail"]))
                    for k, v in sorted(review.items()) if not k.startswith("_"))
    cards = "".join("<a class='glass card' href='f-%s.html'><div>%s</div><b>%s</b><div class=sub style='margin:4px 0 0'>%s &middot; <code>%s</code></div></a>"
                    % (E(f["id"]), badge(f["status"]), E(f["id"] + " " + f["name"]), "clip: yes" if f["evidence"].get("clip") else "no clip yet", E(f["branch"]))
                    for f in feats)
    gerr = "".join("<li class=fail>%s: %s</li>" % (E(i), E(g)) for i, g in errs)
    mut = ("%s%% (%s/%s)" % (mutation["score"], mutation["killed"], mutation["total"])) if mutation else "not run"
    body = """<h1>Realistic v1.5.0 &mdash; evidence review</h1>
<p class=sub>Generated %s from <code>data/features.json</code> and <code>artifacts/review/</code> (review run %s @ %s). Statuses are hand-set; this page never promotes one.</p>
<div class=kpi><div class=glass><span class=sub>Verdict</span><b class=%s>%s</b></div>
<div class=glass><span class=sub>Proven (in-game log)</span><b>%d</b></div><div class=glass><span class=sub>Partial</span><b>%d</b></div>
<div class=glass><span class=sub>Unproven</span><b>%d</b></div><div class=glass><span class=sub>Mutation score</span><b>%s</b></div></div>
<h2>Go / no-go</h2><div class=glass><ul class=check>%s</ul>%s</div>
<h2>Offline review results</h2><div class=glass><table><tr><th>check</th><th></th><th>detail</th></tr>%s</table>
<p class=sub>Rerun: <code>tests/review.sh</code> &middot; mutation: <code>tools/mutate.py --json artifacts/review/mutation.json</code> &middot; full notes: <a href='../docs/RELEASE-READINESS.md'>docs/RELEASE-READINESS.md</a></p></div>
<h2>Features</h2><p class=sub>&ldquo;Proven&rdquo; = measured in a running game via log analysis. No feature has a 30 fps clip yet. Legacy v1.4.0 clips in docs/clips are 2 fps and do not count.</p>
<div class=grid>%s</div>""" % (
        datetime.datetime.now().strftime("%Y-%m-%d %H:%M %Z").strip(), E(review.get("_when", "never")), E(review.get("_commit", "-")),
        "fail" if verdict == "NO-GO" else "pass", verdict, counts["proven"], counts["partial"], counts["unproven"], mut,
        checklist, ("<ul>%s</ul>" % gerr) if gerr else "", rrows or "<tr><td colspan=3 class=na>tests/review.sh not run yet</td></tr>", cards)
    open(os.path.join(OUT, "index.html"), "w", encoding="utf-8").write(page("Realistic v1.5.0 evidence", body))
    for i, g in errs: print("FAIL  feature %s: %s" % (i, g))
    print("evidence site: %s (%d feature pages, verdict %s)" % (os.path.join(OUT, "index.html"), len(feats), verdict))
    return 1 if errs else 0

if __name__ == "__main__":
    sys.exit(main())
