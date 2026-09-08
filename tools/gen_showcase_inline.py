#!/usr/bin/env python3
"""Splice the RIG-DATA PREFIX of missions/scenarios/showcase.lua INLINE into RealisticEvents.lua.

WHY INLINE AND NOT loadfile(). Same reason as tools/gen_donchery_inline.py: loadfile() exists in
ER2 but resolves from '<mission>/globals/', a root that could not be located from outside the game
(the file was placed in BOTH <mission>/globals/ and <mission>/scripts/globals/ and the engine still
reported "Couldn't load file"), and its failure is a HARD engine error that ABORTS the phase script
even though the call sits inside pcall. Runtime file access is not usable here, so data is inlined.

WHY A SIBLING TOOL RATHER THAN GENERALISING gen_donchery_inline.py. The two sources need DIFFERENT
transforms, not one parameterised transform:
  * donchery_oob.lua is a pure data module. The transform is "drop the trailing `return DONCHERY`",
    because a bare `return` in an inlined block ends the phase script.
  * showcase.lua is ALSO a working standalone phase script (that is its second role, and
    tests/offline_showcase.lua drives it in that role). Its transform is "TRUNCATE at the
    --@@ SHOWCASE INLINE CUT marker", because its tail contains a top-level `return`, a spawn
    emitter that must not run before setCallback registration, and a `while true ... sleep(1)` HUD
    loop. Inlining that tail would mean RealisticEvents.lua never registers a single callback.
A single tool switching on which of two unrelated transforms to apply is more code and more risk
than two small explicit ones, and keeping gen_donchery_inline.py untouched means check 4i - a gate
that already passes and has already been proven able to fail - is not disturbed at all.

missions/scenarios/showcase.lua stays the single reviewable source of truth and stays gated by
check 4f (tests/offline_showcase.lua); check 4m asserts the inlined copy is in sync.

Usage: tools/gen_showcase_inline.py            (rewrites RealisticEvents.lua in place)
       tools/gen_showcase_inline.py --check    (exit non-zero if the inlined copy has drifted)
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "missions", "scenarios", "showcase.lua")
PHASE = os.path.join(ROOT, "RealisticEvents.lua")

BEGIN = ("-- >>> BEGIN GENERATED SHOWCASE RANGE - edit missions/scenarios/showcase.lua, "
         "then run tools/gen_showcase_inline.py")
END = "-- <<< END GENERATED SHOWCASE RANGE"

# The line in showcase.lua that separates its rig-data prefix from its standalone-only tail.
CUT = "--@@ SHOWCASE INLINE CUT"


def body():
    src = open(SRC, encoding="utf-8").read()
    if CUT not in src:
        raise SystemExit(
            "FAIL  missions/scenarios/showcase.lua has no '%s' marker. Without it this tool "
            "cannot tell the inlineable rig-data prefix from the standalone tail, and inlining "
            "the tail would abort RealisticEvents.lua before any callback is registered." % CUT
        )
    prefix = src.split(CUT, 1)[0]
    # Belt and braces. A top-level `return` or a blocking loop in the prefix is unsurvivable once
    # this text sits in RealisticEvents.lua's main chunk, and both are silent: the phase script
    # simply stops, with no Lua error, which this project has already misread as success.
    for lineno, line in enumerate(prefix.split("\n"), 1):
        code = line.split("--", 1)[0]
        stripped = code.strip()
        if stripped == "return" or stripped.startswith("return "):
            # An indented `return` inside a local function is fine; only column 0 is top level.
            if not code.startswith((" ", "\t")):
                raise SystemExit(
                    "FAIL  showcase.lua:%d has a TOP-LEVEL `return` above the inline cut: %r. "
                    "Inlined, that would abort the phase script." % (lineno, stripped)
                )
        if stripped.startswith("while true"):
            raise SystemExit(
                "FAIL  showcase.lua:%d has `while true` above the inline cut. Inlined, nothing "
                "after it - including every setCallback - would ever run." % lineno
            )
    return prefix.rstrip() + "\n"


def main():
    check = "--check" in sys.argv
    ph = open(PHASE, encoding="utf-8").read()
    if BEGIN not in ph or END not in ph:
        print("FAIL  generated-SHOWCASE markers missing from RealisticEvents.lua")
        return 1
    pre, rest = ph.split(BEGIN, 1)
    cur, post = rest.split(END, 1)
    want = "\n" + body()
    if check:
        if cur != want:
            print("FAIL  the inlined showcase range is STALE - run tools/gen_showcase_inline.py")
            return 1
        print("ok    inlined showcase range is in sync with missions/scenarios/showcase.lua")
        return 0
    open(PHASE, "w", encoding="utf-8").write(pre + BEGIN + want + END + post)
    print("ok    inlined %d lines of showcase range data" % body().count("\n"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
