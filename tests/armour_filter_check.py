#!/usr/bin/env python3
"""Check isArmour()'s name filter against the vehicle names this install actually uses.

WHY THIS EXISTS. Feature 5 (advance behind armour) decides what counts as armour by matching
substrings of `Vehicle.getName()`, because Vehicle has no getClassName(). That filter silently
mis-classified three of the eight vehicle names present in the real missions:

  * "Sdkfz251 1939" and "Sdkfz222" -- the game's own names have NO space or dot, but the allow
    list only carried "sdkfz 251" / "sd.kfz. 251" / "sd.kfz 251". Neither matched, no deny token
    matched either, so both fell through as UNCLASSIFIED and isArmour() returned false. The
    primary German halftrack and armoured car were invisible to the branch, which is why
    ADVANCE-behind-armour fired ZERO times at a halftrack station on 2026-09-08.
  * "Hotchkiss Stationary Ground" -- an EMPLACED MACHINE GUN, matched by "hotchkiss", which is on
    the allow list for the H35 TANK. An emplacement was being offered as something to advance
    behind.

A mis-classification here is silent in-game: the branch simply never fires, or fires against
cover that is not cover. Nothing errors. Hence a static gate.

The expectations below are the vehicle names read out of the real ME_Stonne mission file, so they
are what this install genuinely contains. Add a row whenever a new vehicle enters a mission.

Usage: tests/armour_filter_check.py     (run from the repo root; exit 0 = all classify correctly)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# name -> True if it must count as ARMOUR (something a rifleman can advance behind)
EXPECT = {
    "Panzer II C":                 True,
    "Panzer II Ausf. B":           True,
    "Char B1":                     True,
    "Sdkfz251 1939":               True,   # the primary German APC
    "Sdkfz222":                    True,   # armoured car
    "Opel Blitz":                  False,  # truck
    "Bofors 40mm":                 False,  # towed AA gun
    "Hotchkiss Stationary Ground": False,  # EMPLACED MG, not a vehicle to hide behind
}

# Hard exclusions applied BEFORE the allow list, inlined in isArmour() rather than tabled because
# Realistic.lua is at the Lua 200-local ceiling. Keep in sync with that function.
NEVER = ["stationary", "emplac", "static"]


def tokens(src, name):
    m = re.search(r"local %s = \{(.*?)\n\}" % name, src, re.S)
    if not m:
        return None
    return [t.lower() for t in re.findall(r'"([^"]+)"', m.group(1))]


def classify(nm, allow, deny):
    nm = nm.lower()
    if any(t in nm for t in NEVER):
        return False, "hard exclusion"
    for t in allow:
        if t in nm:
            return True, "allow '%s'" % t
    for t in deny:
        if t in nm:
            return False, "deny '%s'" % t
    return False, "UNCLASSIFIED (falls through to not-armour)"


def main():
    src = open(os.path.join(ROOT, "Realistic.lua"), encoding="utf-8").read()
    allow = tokens(src, "ARMOUR_ALLOW")
    deny = tokens(src, "ARMOUR_DENY")
    if allow is None or deny is None:
        print("FAIL  could not parse ARMOUR_ALLOW / ARMOUR_DENY out of Realistic.lua")
        return 1

    # The inlined hard exclusions must actually be present in isArmour(), or this checker is
    # asserting a rule the code does not implement.
    fn = re.search(r"local function isArmour\(v\).*?\nend", src, re.S)
    if not fn:
        print("FAIL  could not find isArmour()")
        return 1
    for t in NEVER:
        if t not in fn.group(0):
            print("FAIL  isArmour() no longer checks the hard exclusion '%s'" % t)
            return 1

    # DIRECT STRUCTURAL ASSERTION. Classification alone did not gate this half: removing the
    # space-free tokens still left all eight names classifying correctly, so the "negative test"
    # was vacuous and the gate only LOOKED effective. Asserting the tokens' PRESENCE cannot be
    # fooled that way. The game's own names carry no space or dot.
    for t in ("sdkfz251", "sdkfz222"):
        if t not in allow:
            print("FAIL  ARMOUR_ALLOW is missing the space-free token '%s'. The game names its "
                  "vehicles 'Sdkfz251 1939' and 'Sdkfz222'; the spaced spellings match neither, "
                  "so the halftrack and armoured car fall through as not-armour." % t)
            return 1

    bad = 0
    for name in sorted(EXPECT):
        want = EXPECT[name]
        got, why = classify(name, allow, deny)
        if got != want:
            bad += 1
            print("FAIL  %-30s -> %s (%s); expected %s"
                  % (name, "ARMOUR" if got else "soft", why,
                     "ARMOUR" if want else "soft"))
    if bad:
        print("      a silent mis-classification means feature 5 never fires, or fires against "
              "cover that is not cover")
        return 1
    print("ok    armour filter classifies all %d known vehicle names correctly" % len(EXPECT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
