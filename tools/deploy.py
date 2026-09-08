#!/usr/bin/env python3
"""Deploy the mod to every mission that runs it, atomically and verifiably.

WHY THIS EXISTS
    Deployment used to be a hand-run `cp` loop. Twice that loop was pointed at only the
    mission under test, which left the other three missions running a stale brain. The
    symptom is the worst kind: the map you are testing behaves correctly, so you conclude
    the build is good, and then a different map contradicts it an hour later. A script that
    always writes all four missions, and then re-reads and hashes what it wrote, makes that
    class of bug impossible rather than merely unlikely.

WHAT SHIPS WHERE
    Realistic.lua        -> <mission>/scripts/mission/Realistic.lua   (verbatim, all 4)
    RealisticEvents.lua  -> <mission>/scripts/mission/phase_0.lua     (the game's loader
                            names the phase script by index, not by our filename)

    Three of the four missions get the phase script VERBATIM, which means INERT: its
    TEST_SPAWNS / TEST_VEHICLES / TEST_MOUNTED rig tables are empty, so the script drives
    only whatever the mission editor placed. That inert state is the repo's shipping build
    and tests/check.sh check 6 gates it. We do not un-inert the repo copy.

    ME_Stonne_38n85202 gets a VARIANT with the Donchery historical order of battle switched
    on. The switch is three assignments and nothing else, produced HERE at deploy time so
    the repo copy stays clean.
"""

import argparse
import filecmp
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MISSION_ROOT = os.path.expanduser(
    "~/.config/unity3d/Corvostudio/Easy Red 2/mission_editor"
)

# Every mission that runs this mod. Adding a mission here is the ONLY place it needs to be
# registered - the point of the script is that no caller gets to pick a subset.
MISSIONS = [
    "ME_VirtualScene_66v1d2nn",
    "ME_Realistic Test map_o6526q70",
    "ME_Kos_y1pfi3zz",
    "ME_Stonne_38n85202",
]

# The one mission that gets the Donchery order of battle rather than the inert build.
STONNE = "ME_Stonne_38n85202"

BRAIN_SRC = os.path.join(REPO, "Realistic.lua")
PHASE_SRC = os.path.join(REPO, "RealisticEvents.lua")

BRAIN_DST_NAME = "Realistic.lua"
PHASE_DST_NAME = "phase_0.lua"


# ---------------------------------------------------------------------------------------
# The Stonne variant
# ---------------------------------------------------------------------------------------
#
# The rig tables are declared as three `local` statements. The Donchery OOB is INLINED into
# the phase script (by tools/gen_donchery_inline.py) as `local DONCHERY = ...` and, crucially,
# that inlining happens EARLIER IN THE FILE than the declarations. So `DONCHERY` is already
# in scope at the declaration site and we can assign there directly - no separate
# re-assignment block is needed, and no forward reference is created.
#
# build_stonne_phase() ASSERTS that ordering instead of trusting this comment. If someone
# moves the generated OOB block below the declarations, the assert fires and deployment
# stops, rather than silently shipping `TEST_SPAWNS = nil` (which would spawn nothing while
# logging no error at all - the exact failure mode this project has already paid for twice).

DECL_RE = re.compile(
    r"^local (TEST_SPAWNS|TEST_VEHICLES|TEST_MOUNTED)(\s*)= \{\}\s*$", re.M
)

# Which DONCHERY field each rig table takes. Field names verified against RealisticEvents.lua
# line 475: `local DONCHERY = { squads = {}, vehicles = {}, mounted = {} }`.
RIG_FIELDS = {
    "TEST_SPAWNS": "DONCHERY.squads",
    "TEST_VEHICLES": "DONCHERY.vehicles",
    "TEST_MOUNTED": "DONCHERY.mounted",
}

INJECT_TAG = "-- injected by tools/deploy.py: Stonne runs the Donchery order of battle"


def build_stonne_phase(src):
    """Return (variant_source, injected_lines).

    Rewrites the three inert `local TEST_x = {}` declarations into assignments from the
    inlined DONCHERY table. Raises if the file does not look the way we expect.
    """
    lines = src.split("\n")

    def line_of(pattern):
        for i, line in enumerate(lines):
            if re.match(pattern, line):
                return i + 1
        return None

    donchery_line = line_of(r"^local DONCHERY\b")
    if donchery_line is None:
        raise SystemExit(
            "REFUSING TO DEPLOY: no top-level `local DONCHERY` in RealisticEvents.lua. "
            "The OOB is supposed to be inlined by tools/gen_donchery_inline.py; without it "
            "the variant would assign from a nil global and spawn nothing, silently."
        )

    decl_lines = [
        line_of(r"^local %s\s*= \{\}\s*$" % name) for name in RIG_FIELDS
    ]
    if any(n is None for n in decl_lines):
        raise SystemExit(
            "REFUSING TO DEPLOY: could not find all three inert rig declarations "
            "(`local TEST_SPAWNS = {}` etc.) in RealisticEvents.lua. Either the repo copy is "
            "no longer inert - which check 6 should have caught - or the declarations were "
            "renamed and this script needs updating."
        )
    first_decl = min(decl_lines)

    # ORDERING IS THE WHOLE CORRECTNESS ARGUMENT. Assigning at the declaration is only valid
    # because DONCHERY is defined above it.
    if donchery_line >= first_decl:
        raise SystemExit(
            "REFUSING TO DEPLOY: `local DONCHERY` is at line %d but the rig declarations "
            "start at line %d. Assigning at the declaration would capture a nil upvalue. "
            "Move the generated OOB block back above the declarations, or change this script "
            "to emit a re-assignment placed after DONCHERY and before runSpawnRig()."
            % (donchery_line, first_decl)
        )

    run_line = line_of(r"^runSpawnRig\(\)")
    if run_line is None:
        raise SystemExit(
            "REFUSING TO DEPLOY: no top-level `runSpawnRig()` invocation found. Nothing would "
            "consume the rig tables, so the variant would be a no-op."
        )
    if run_line <= max(decl_lines):
        raise SystemExit(
            "REFUSING TO DEPLOY: runSpawnRig() is invoked at line %d, at or before the rig "
            "declarations at line %d." % (run_line, max(decl_lines))
        )

    injected = []

    def replace(m):
        name, pad = m.group(1), m.group(2)
        new = "local %s%s= %s   %s" % (name, pad, RIG_FIELDS[name], INJECT_TAG)
        injected.append(new)
        return new

    out, n = DECL_RE.subn(replace, src)
    if n != 3:
        raise SystemExit(
            "REFUSING TO DEPLOY: expected to rewrite exactly 3 rig declarations, rewrote %d." % n
        )

    # Keep the injected lines in file order for the human-readable printout.
    order = {name: i for i, name in enumerate(RIG_FIELDS)}
    injected.sort(key=lambda l: order[l.split()[1]])
    return out, injected


# ---------------------------------------------------------------------------------------
# Plan / write / verify
# ---------------------------------------------------------------------------------------


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read(path):
    with open(path, "rb") as fh:
        return fh.read()


def build_plan():
    """Return [(mission, dst_path, expected_bytes, label)] plus the injected Lua lines.

    Everything downstream - deploy, --check and check.sh's gate - works off this one plan,
    so there is no way for the verifier and the writer to disagree about what should be
    on disk.
    """
    brain = read(BRAIN_SRC)
    phase_inert_text = open(PHASE_SRC, encoding="utf-8").read()
    phase_inert = phase_inert_text.encode("utf-8")
    stonne_text, injected = build_stonne_phase(phase_inert_text)
    stonne = stonne_text.encode("utf-8")

    plan = []
    for mission in MISSIONS:
        dst_dir = os.path.join(MISSION_ROOT, mission, "scripts", "mission")
        plan.append((mission, os.path.join(dst_dir, BRAIN_DST_NAME), brain, "brain"))
        if mission == STONNE:
            plan.append(
                (mission, os.path.join(dst_dir, PHASE_DST_NAME), stonne, "phase (Donchery)")
            )
        else:
            plan.append(
                (mission, os.path.join(dst_dir, PHASE_DST_NAME), phase_inert, "phase (inert)")
            )
    return plan, injected


def run_check_sh():
    """Run tests/check.sh and return (green, final_line).

    Deploying a red build has to be impossible, so this gates the whole write. We parse the
    script's own final `PASS n   FAIL m` line rather than trusting the exit code alone -
    this project has already shipped tests that reported FAIL 0 while silently no-opping,
    so the count is the evidence.

    NOTE: --check deliberately does NOT call this. check.sh's own check 4l invokes
    `deploy.py --check`, and running check.sh from there would recurse forever.
    """
    proc = subprocess.run(
        ["bash", "tests/check.sh"],
        cwd=REPO,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    final = None
    for line in proc.stdout.split("\n"):
        m = re.match(r"^PASS (\d+)\s+FAIL (\d+)\s*$", line.strip())
        if m:
            final = (int(m.group(1)), int(m.group(2)), line.strip())
    if final is None:
        return False, "no 'PASS n   FAIL m' line in check.sh output", proc.stdout
    npass, nfail, text = final
    return (nfail == 0 and npass > 0), text, proc.stdout


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument(
        "--check",
        action="store_true",
        help="verify the deployed files match what deploy.py would write; change nothing, "
        "exit non-zero on drift",
    )
    args = ap.parse_args()

    plan, injected = build_plan()

    if args.check:
        drift = []
        for mission, dst, expected, label in plan:
            if not os.path.exists(dst):
                drift.append("%s: %s MISSING (%s)" % (mission, os.path.basename(dst), label))
            elif read(dst) != expected:
                drift.append(
                    "%s: %s STALE (%s) deployed=%s expected=%s"
                    % (
                        mission,
                        os.path.basename(dst),
                        label,
                        sha(read(dst))[:12],
                        sha(expected)[:12],
                    )
                )
        if drift:
            for d in drift:
                print("DRIFT  " + d)
            print("FAIL   %d of %d deployed files do not match the repo build" % (len(drift), len(plan)))
            return 1
        print("ok     all %d deployed files match what deploy.py would write" % len(plan))
        return 0

    # --- gate: never deploy a red build -------------------------------------------------
    green, final, output = run_check_sh()
    if not green:
        print(output.rstrip())
        print()
        print("REFUSING TO DEPLOY: tests/check.sh is not green (%s). Nothing was written." % final)
        return 1
    print("tests/check.sh: %s -- proceeding" % final)
    print()

    print("Stonne variant injects these lines (rewriting the inert declarations in place):")
    for line in injected:
        print("    " + line)
    print()

    # --- write ---------------------------------------------------------------------------
    rows = []
    failures = 0
    for mission, dst, expected, label in plan:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        # Write to a temp file in the destination directory, then replace. A half-written
        # phase script is worse than a stale one: the game's loader would fail mid-file.
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dst), prefix=".deploy.")
        try:
            with os.fdopen(fd, "wb") as fh:
                fh.write(expected)
            os.replace(tmp, dst)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise

        # Verify by re-reading from disk. filecmp for the verbatim copies (it is the same
        # question a human would ask), plus a hash compare against the exact expected bytes
        # so the generated Stonne variant is covered too.
        got = read(dst)
        same = got == expected
        if label == "brain":
            same = same and filecmp.cmp(BRAIN_SRC, dst, shallow=False)
        rows.append((mission, label, "PASS" if same else "FAIL", sha(got)[:12]))
        if not same:
            failures += 1

    width = max(len(m) for m in MISSIONS)
    print("%-*s  %-16s  %-4s  %s" % (width, "mission", "file", "", "sha256"))
    for mission, label, verdict, digest in rows:
        print("%-*s  %-16s  %-4s  %s" % (width, mission, label, verdict, digest))
    print()

    brain_ok = sum(1 for _, l, v, _ in rows if l == "brain" and v == "PASS")
    inert_ok = sum(1 for _, l, v, _ in rows if l == "phase (inert)" and v == "PASS")
    stonne_ok = all(v == "PASS" for _, l, v, _ in rows if l == "phase (Donchery)")
    print(
        "brain %d/%d, phase inert %d/%d, Stonne variant %s"
        % (brain_ok, len(MISSIONS), inert_ok, len(MISSIONS) - 1, "ok" if stonne_ok else "FAILED")
    )
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
