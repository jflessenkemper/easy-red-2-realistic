#!/usr/bin/env python3
"""Splice missions/donchery_oob.lua INLINE into RealisticEvents.lua between markers.

WHY THE LOADER WAS REMOVED. loadfile() exists in ER2 but resolves from '<mission>/globals/', and
that root could not be located from outside the game: the file was placed in BOTH
<mission>/globals/ and <mission>/scripts/globals/ and the engine still reported
    Couldn't load file 'donchery_oob.lua' at '<mission>/globals/'.
Worse, the failure is a HARD engine error that ABORTS the phase script even though the call sits
inside pcall - the same unsurvivable class as spawnVehicle's bad-argument throw. So runtime file
access is not usable here.

missions/donchery_oob.lua stays the single reviewable source of truth and stays gated by
check 4h; this script copies its BODY inline so the phase script needs no file access at all.
check 4i asserts the inlined copy is in sync.

Usage: tools/gen_donchery_inline.py        (rewrites RealisticEvents.lua in place)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OOB = os.path.join(ROOT, "missions", "donchery_oob.lua")
PHASE = os.path.join(ROOT, "RealisticEvents.lua")
BEGIN = ("-- >>> BEGIN GENERATED DONCHERY OOB - edit missions/donchery_oob.lua, "
         "then run tools/gen_donchery_inline.py")
END = "-- <<< END GENERATED DONCHERY OOB"


def body():
    src = open(OOB, encoding="utf-8").read()
    # The inline copy must NOT return - a bare `return` here would end the phase script.
    src = re.sub(r"\nreturn DONCHERY\s*$", "\n", src)
    return src.rstrip() + "\n"


def main():
    check = "--check" in sys.argv
    ph = open(PHASE, encoding="utf-8").read()
    if BEGIN not in ph or END not in ph:
        print("FAIL  generated-OOB markers missing from RealisticEvents.lua")
        return 1
    pre, rest = ph.split(BEGIN, 1)
    cur, post = rest.split(END, 1)
    want = "\n" + body()
    if check:
        if cur != want:
            print("FAIL  the inlined Donchery OOB is STALE - run tools/gen_donchery_inline.py")
            return 1
        print("ok    inlined Donchery OOB is in sync with missions/donchery_oob.lua")
        return 0
    open(PHASE, "w", encoding="utf-8").write(pre + BEGIN + want + END + post)
    print("ok    inlined %d lines of Donchery OOB" % body().count("\n"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
