#!/usr/bin/env python3
"""Mutation testing for the pure-logic functions the busted specs extract.

Each mutant is ONE textual change (relational/arithmetic/logical operator swap, boolean flip,
numeric constant +1/x0) inside one target function or constant. The mutant is written to a temp
copy of Realistic.lua, spec/brain_pure_spec.lua is run against it via REALISTIC_SRC, and the mutant
counts as KILLED if busted fails. Kill rate = killed / total. Surviving mutants are listed: each is
either a missing assertion or an equivalent mutant (a change that cannot alter behaviour).

This says how sharp the SPECS are. It says nothing about in-game behaviour.

Usage: tools/mutate.py [--json out.json] [--limit N]      (separate from check.sh: ~1-2 min)
"""
import json, os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Realistic.lua")
TARGETS = ["nationFromFaction", "classMatches", "segFlatness", "staggerAcross", "ketteSlot",
           "isArmour", "KETTE_INTERVAL", "KETTE_FRONT", "COLUMN_STAGGER"]
OPS = [(r"<=", ">"), (r">=", "<"), (r"(?<![<>=~])<(?!=)", ">="), (r"(?<![<>=~-])>(?!=)", "<="),
       (r"==", "~="), (r"~=", "=="), (r"(?<![-\w])\+(?!\+)", "-"), (r"(?<!-)-(?![-\d])", "+"),
       (r"\*", "/"), (r"\band\b", "or"), (r"\bor\b", "and"), (r"\btrue\b", "false"),
       (r"\bfalse\b", "true"), (r"\bnot\b ", "")]
NUM = re.compile(r"(?<![\w.])(\d+(?:\.\d+)?)(?![\w.])")

def ranges(lines):
    out = []
    for name in TARGETS:
        for i, l in enumerate(lines):
            if re.match(r"^local (function )?%s\b" % name, l):
                j = i
                if l.startswith("local function") or l.rstrip().endswith("{"):
                    j = next(k for k in range(i + 1, len(lines)) if re.match(r"^(end|})", lines[k]))
                out.append((name, i, j)); break
    return out

def code_part(line):
    k = line.find("--")
    return line if k < 0 else line[:k]

def mutants(lines):
    for name, a, b in ranges(lines):
        for i in range(a, b + 1):
            code = code_part(lines[i])
            if '"' in code and name in ("nationFromFaction",):  # skip string-table noise
                pass
            for pat, rep in OPS:
                for m in re.finditer(pat, code):
                    if _in_string(code, m.start()): continue
                    yield name, i, code[:m.start()] + rep + code[m.end():] + lines[i][len(code):], "%s->%s" % (m.group(0), rep)
            for m in NUM.finditer(code):
                if _in_string(code, m.start()): continue
                v = m.group(1)
                for rep in (str(float(v) + 1) if "." in v else str(int(v) + 1), "0"):
                    if rep == v: continue
                    yield name, i, code[:m.start()] + rep + code[m.end():] + lines[i][len(code):], "%s->%s" % (v, rep)

def _in_string(code, pos):
    return code[:pos].count('"') % 2 == 1

def run(path):
    env = dict(os.environ, REALISTIC_SRC=path)
    p = subprocess.run(["busted", "spec/brain_pure_spec.lua"], cwd=ROOT, env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    return p.returncode != 0

def main():
    args = sys.argv[1:]
    out = args[args.index("--json") + 1] if "--json" in args else None
    limit = int(args[args.index("--limit") + 1]) if "--limit" in args else None
    lines = open(SRC, encoding="utf-8").read().split("\n")
    if run(SRC):
        print("FAIL  specs do not pass on the unmutated source; mutation score is meaningless"); return 2
    res, survivors = {}, []
    fd, tmp = tempfile.mkstemp(suffix=".lua"); os.close(fd)
    try:
        for n, (name, i, new, desc) in enumerate(mutants(lines)):
            if limit and n >= limit: break
            m = list(lines); m[i] = new
            open(tmp, "w", encoding="utf-8").write("\n".join(m))
            killed = run(tmp)
            r = res.setdefault(name, [0, 0]); r[1] += 1; r[0] += killed
            if not killed: survivors.append("%s:%d %s   %s" % (name, i + 1, desc, new.strip()[:90]))
    finally:
        os.unlink(tmp)
    k = sum(v[0] for v in res.values()); t = sum(v[1] for v in res.values())
    for name, (kk, tt) in res.items(): print("  %-18s %3d/%-3d killed" % (name, kk, tt))
    print("MUTATION SCORE %d/%d = %.1f%%" % (k, t, 100.0 * k / max(t, 1)))
    for s in survivors: print("  survived  " + s)
    if out:
        json.dump({"killed": k, "total": t, "score": round(100.0 * k / max(t, 1), 1),
                   "per_function": res, "survivors": survivors}, open(out, "w"), indent=1)
    return 0

if __name__ == "__main__":
    sys.exit(main())
