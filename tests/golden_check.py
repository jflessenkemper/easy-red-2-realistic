#!/usr/bin/env python3
"""Golden-file tests for the prop/layout generators.

Regenerates every generator output into a temp dir and byte-compares it with tests/golden/.
A diff means the generator's output CHANGED - maybe intentionally; if so, review the diff and run
`tests/golden_check.py --update`. It proves determinism and catches silent output drift; it does
NOT prove the props load in the map editor (that is the pending prop-id step).
"""
import os, shutil, subprocess, sys, tempfile, difflib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
G = os.path.join(ROOT, "tests", "golden")
PY = sys.executable

def outputs(tmp):
    res = {}
    for name in ("layout_feature_range", "layout_showcase"):
        src = os.path.join(ROOT, "data", "props", name + ".json")
        for st in ("confirmed", "palette-read"):
            out = os.path.join(tmp, "%s.%s.er2f" % (name, st))
            p = subprocess.run([PY, "tools/gen_prop_layout.py", src, "--min-status", st, "-o", out],
                               cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            res[os.path.basename(out)] = open(out, "rb").read() if p.returncode == 0 else ("EXIT %d\n%s" % (p.returncode, p.stdout)).encode()
    # gen_showcase_layout writes fixed repo paths; run it in a scratch COPY of the repo so the
    # golden check never touches the working tree.
    scratch = os.path.join(tmp, "repo")
    shutil.copytree(ROOT, scratch, ignore=shutil.ignore_patterns(".git", "artifacts", "docs", "evidence"))
    p = subprocess.run([PY, "tools/gen_showcase_layout.py"], cwd=scratch, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True)
    res["gen_showcase_layout.stdout"] = p.stdout.encode()
    res["layout_showcase.json"] = open(os.path.join(scratch, "data/props/layout_showcase.json"), "rb").read()
    res["showcase_tx_data_objects.er2f"] = open(os.path.join(scratch, "missions/showcase/tx_data_objects.er2f"), "rb").read()
    return res

def main():
    update = "--update" in sys.argv
    with tempfile.TemporaryDirectory() as tmp:
        res = outputs(tmp)
    os.makedirs(G, exist_ok=True)
    bad = 0
    for k, v in sorted(res.items()):
        path = os.path.join(G, k)
        if update:
            open(path, "wb").write(v); print("wrote %s" % k); continue
        if not os.path.exists(path):
            print("FAIL  no golden for %s (run --update)" % k); bad += 1; continue
        if open(path, "rb").read() != v:
            bad += 1
            print("FAIL  %s differs from golden" % k)
            a = open(path, "rb").read().decode("utf-8", "replace").splitlines()
            b = v.decode("utf-8", "replace").splitlines()
            for l in list(difflib.unified_diff(a, b, "golden", "now", lineterm=""))[:20]: print("      " + l)
    if not update and not bad:
        print("ok    %d generator outputs match their golden files byte-for-byte" % len(res))
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
