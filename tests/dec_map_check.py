#!/usr/bin/env python3
"""Cross-check the DEC decision-code map across the brain and both plugin tools.

The map exists in THREE places and nothing checked that they agree:

  * Realistic.lua        DEC.code   -- AUTHORITATIVE (label -> integer)
  * movement_audit.py    MOVE/HOLD  -- intent-vs-outcome verdicts, keyed by integer
  * battle_map.py        DECCOL     -- colour per integer

Two failure modes, both silent and both real:

  1. A tool references a code the brain no longer emits. Retiring `AT-hold-cover` (code 7) left
     battle_map.py colouring a code that can never appear.
  2. The brain emits a code battle_map.py does not colour, so it falls through to '#4a5058' --
     the SAME grey as code 0, "unknown". Those decisions become visually indistinguishable from
     missing data. This was true of DRAG-abandon, RADIO-fire-mission, ADVANCE-baseAI,
     RETURN-to-transport and REBOARD-transport.

movement_audit.py is deliberately NOT required to name every code -- its tables are only the
move/hold classifications, and cover-seeking orders are ungateable by a speed threshold. It is
only checked for stale references.

Usage: tests/dec_map_check.py            (run from the repo root; exit 0 = agree)
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TOOLS = os.path.join(ROOT, "..", "er2-plugin", "tools")


def brain_codes(path):
    """label -> int, from the DEC.code table."""
    src = open(path, encoding="utf-8").read()
    m = re.search(r"local DEC\s*=\s*\{.*?\bcode\s*=\s*\{(.*?)\n    \},", src, re.S)
    if not m:
        return None
    return {lab: int(num) for lab, num in re.findall(r'\["([^"]+)"\]\s*=\s*(\d+)', m.group(1))}


def ints_in_block(path, pattern):
    """Set of integer keys appearing in the first block matching `pattern`."""
    try:
        src = open(path, encoding="utf-8").read()
    except OSError:
        return None
    m = re.search(pattern, src, re.S)
    if not m:
        return None
    return {int(n) for n in re.findall(r"(?<![\w.])(\d+)\s*:", m.group(1))}


def main():
    brain = os.path.join(ROOT, "Realistic.lua")
    codes = brain_codes(brain)
    if not codes:
        print("FAIL  could not parse DEC.code out of Realistic.lua")
        return 1
    valid = set(codes.values()) | {0}          # 0 = unknown/not published, legitimate everywhere

    problems = []

    bm = os.path.join(TOOLS, "battle_map.py")
    colours = ints_in_block(bm, r"const DECCOL\s*=\s*\{(.*?)\};")
    if colours is None:
        print("SKIP  battle_map.py DECCOL not found (%s)" % bm)
    else:
        stale = sorted(colours - valid)
        if stale:
            problems.append("battle_map.py colours retired code(s) %s" % stale)
        missing = sorted(set(codes.values()) - colours)
        if missing:
            names = ", ".join(
                "%d=%s" % (c, lab) for lab, c in sorted(codes.items(), key=lambda kv: kv[1])
                if c in missing)
            problems.append(
                "battle_map.py does not colour %s - these render as the same grey as 'unknown'"
                % names)

    ma = os.path.join(TOOLS, "movement_audit.py")
    mh = ints_in_block(ma, r"MOVE\s*=\s*\{(.*?)\bNAMES\s*=")
    if mh is None:
        print("SKIP  movement_audit.py MOVE/HOLD not found (%s)" % ma)
    else:
        stale = sorted(mh - valid)
        if stale:
            problems.append("movement_audit.py references retired code(s) %s" % stale)

    if problems:
        for p in problems:
            print("FAIL  " + p)
        return 1
    print("ok    DEC map agrees across Realistic.lua, battle_map.py, movement_audit.py "
          "(%d codes)" % len(codes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
