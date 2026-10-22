#!/usr/bin/env python3
"""Main-chunk local-variable budget check (Lua's hard limit: 200 active locals per function).

ORACLE, NOT A REGEX. Counting `^local` lines is wrong both ways: `local a, b, c` is three slots,
`local function f` is one, and locals inside closed blocks free their slots. Instead we ask the
compiler: append `local _lc1,...,_lcK` at the end of the main chunk and binary-search the largest K
that still compiles. Active main-chunk locals = 200 - K. One extra top-level local past the ceiling
fails compilation and kills EVERY brain at load, so headroom 0 is legal but -1 is fatal.

Usage: tests/local_count.py [--min-headroom N] file.lua [...]   (exit 1 if any file is over)
"""
import os, subprocess, sys, tempfile

LIMIT = 200
LUAJIT = os.environ.get("LUAJIT", "luajit")

def compiles(src):
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
        f.write(src)
        p = f.name
    try:
        return subprocess.run([LUAJIT, "-bl", p], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0
    finally:
        os.unlink(p)

def headroom(path):
    src = open(path, encoding="utf-8").read()
    lines = src.rstrip("\n").split("\n")
    tail = ""
    # a top-level trailing `return` must stay last, so inject before it
    if lines and lines[-1].startswith("return"):
        tail = "\n" + lines.pop()
    body = "\n".join(lines)
    if not compiles(body + tail):
        return None
    lo, hi = 0, LIMIT
    while lo < hi:
        mid = (lo + hi + 1) // 2
        extra = "\nlocal " + ",".join("_lc%d" % i for i in range(mid)) + "\n"
        if compiles(body + extra + tail): lo = mid
        else: hi = mid - 1
    return lo

def main(argv):
    minh = 0
    if argv[:1] == ["--min-headroom"]:
        minh = int(argv[1]); argv = argv[2:]
    rc = 0
    for path in argv:
        h = headroom(path)
        if h is None:
            print("FAIL  %s does not compile (over the %d-local limit or a syntax error)" % (path, LIMIT)); rc = 1
        elif h < minh:
            print("FAIL  %s: %d main-chunk locals, headroom %d < required %d" % (path, LIMIT - h, h, minh)); rc = 1
        else:
            print("ok    %s: %d/%d main-chunk locals (headroom %d)" % (path, LIMIT - h, LIMIT, h))
    return rc

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
