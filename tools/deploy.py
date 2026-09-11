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

    TWO of the four get a VARIANT, produced HERE at deploy time so the repo copy stays clean:
      ME_Stonne_38n85202             -> the Donchery historical order of battle (DONCHERY.*)
      ME_Realistic Test map_...      -> the showcase demonstration range (SHOWCASE.*)
    The switch is three assignments and nothing else. Without the test-map variant, loading
    "Realistic Test map" gives you an INERT phase script: the range exists as data in
    missions/scenarios/showcase.lua and is inlined into the phase script, but nothing consumes
    it, so you spawn in and see nothing at all.
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

# The two missions that get an armed variant rather than the inert build.
STONNE = "ME_Stonne_38n85202"
TESTMAP = "ME_Realistic Test map_o6526q70"

BRAIN_SRC = os.path.join(REPO, "Realistic.lua")
PHASE_SRC = os.path.join(REPO, "RealisticEvents.lua")

BRAIN_DST_NAME = "Realistic.lua"
PHASE_DST_NAME = "phase_0.lua"


# ---------------------------------------------------------------------------------------
# The armed variants
# ---------------------------------------------------------------------------------------
#
# The rig tables are declared as three `local` statements. Both data sets are INLINED into
# the phase script - the Donchery OOB by tools/gen_donchery_inline.py as `local DONCHERY = ...`,
# the showcase range by tools/gen_showcase_inline.py as `local SHOWCASE = ...` - and, crucially,
# both inlinings happen EARLIER IN THE FILE than the declarations. So the source table is already
# in scope at the declaration site and we can assign there directly - no separate re-assignment
# block is needed, and no forward reference is created.
#
# build_variant() ASSERTS that ordering instead of trusting this comment. If someone moves a
# generated block below the declarations, the assert fires and deployment stops, rather than
# silently shipping `TEST_SPAWNS = nil` (which would spawn nothing while logging no error at all -
# the exact failure mode this project has already paid for twice).

RIG_NAMES = ("TEST_SPAWNS", "TEST_VEHICLES", "TEST_MOUNTED")

DECL_RE = re.compile(
    r"^local (TEST_SPAWNS|TEST_VEHICLES|TEST_MOUNTED)(\s*)= \{\}\s*$", re.M
)

# Which field of the source table each rig table takes. Both tables carry the same three field
# names, verified against RealisticEvents.lua:
#   `local DONCHERY = { squads = {}, vehicles = {}, mounted = {} }`
#   `local SHOWCASE = { squads = {}, vehicles = {}, mounted = {} }`
RIG_FIELDS = {
    "TEST_SPAWNS": "squads",
    "TEST_VEHICLES": "vehicles",
    "TEST_MOUNTED": "mounted",
}

# (lua table name, what the variant is, the tool that inlines it)
VARIANTS = {
    STONNE: ("DONCHERY", "Stonne runs the Donchery order of battle",
             "tools/gen_donchery_inline.py"),
    TESTMAP: ("SHOWCASE", "the test map runs the showcase demonstration range",
              "tools/gen_showcase_inline.py"),
}


DIORAMA_OFF = "    on     = false,"
DIORAMA_ON  = "    on     = true,    -- injected by tools/deploy.py: the test map runs the diorama"


def enable_diorama(src):
    """Switch CYC.on true. Test map only.

    The diorama heals its actors every few seconds to keep them alive for repeat performances,
    which would be absurd in a real battle - so this must never reach Stonne or a shipping build.
    Asserted rather than trusted: if the flag is not found exactly once, deployment stops instead
    of silently shipping a range that never resets (or a battle where nobody can die).
    """
    if src.count(DIORAMA_OFF) != 1:
        raise SystemExit(
            "REFUSING TO DEPLOY: expected exactly one %r in RealisticEvents.lua, found %d. The "
            "diorama flag was renamed or duplicated; the test map would either never reset or the "
            "healing tick could reach a mission where it makes no sense."
            % (DIORAMA_OFF.strip(), src.count(DIORAMA_OFF))
        )
    return src.replace(DIORAMA_OFF, DIORAMA_ON, 1)


def luajit_ok(text, label):
    """Syntax-check generated Lua before it can reach the game.

    THIS CHECK EXISTS BECAUSE ITS ABSENCE SHIPPED A DEAD TEST MAP. The diorama flag was injected
    with a `#` comment - Python's comment marker, not Lua's, where `#` is the LENGTH OPERATOR - so
    the generated file could not parse. deploy.py wrote it, hashed it, reported PASS, and
    tests/check.sh reported 41/41, because check 1 only ever syntax-checked the REPO sources and
    nothing checked the VARIANTS this script generates. The variants are the only thing the game
    actually loads.
    """
    lj = shutil.which("luajit")
    if not lj:
        return None      # cannot check; caller decides whether that is acceptable
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as fh:
        fh.write(text)
        tmp = fh.name
    try:
        r = subprocess.run([lj, "-bl", tmp], capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            raise SystemExit(
                "REFUSING TO DEPLOY: the generated %s variant is not valid Lua.\n%s"
                % (label, (r.stderr or r.stdout).strip()[:500])
            )
        return True
    finally:
        os.unlink(tmp)


def full_logging(src):
    """Sample EVERY soldier on the test map, not one in six.

    The shipping default DBG_SAMPLE = 6 exists to keep Player.log manageable in a real battle. On
    the demonstration range it makes the range unverifiable: a 25-minute run over 11 diorama
    rounds produced FORTY-ONE brain state lines across thirteen stations - about three per station
    - and most of them were defender-side squads correctly holding, which says nothing about what
    any station demonstrates. The test map exists to be measured, so it samples everyone.

    DEBUG itself is deliberately NOT forced on here: that stays a conscious choice, because the
    per-line cost is ~1.1 KB plus a stack walk and the Stop hook refuses to end a session with a
    diagnostic build deployed.
    """
    m = re.search(r"^local DBG_SAMPLE\s*=\s*(\d+)", src, re.M)
    if not m:
        raise SystemExit(
            "REFUSING TO DEPLOY: no `local DBG_SAMPLE = <n>` found in Realistic.lua, so the test "
            "map cannot be switched to full sampling and the range would stay unverifiable. "
            "NOTE: DBG_SAMPLE is declared in the BRAIN, not the phase script."
        )
    return src[:m.start()] + "local DBG_SAMPLE = 1" + src[m.end():]


def build_variant(src, table, what, tool):
    """Return (variant_source, injected_lines).

    Rewrites the three inert `local TEST_x = {}` declarations into assignments from the
    inlined `table`. Raises if the file does not look the way we expect.
    """
    lines = src.split("\n")

    def line_of(pattern):
        for i, line in enumerate(lines):
            if re.match(pattern, line):
                return i + 1
        return None

    src_line = line_of(r"^local %s\b" % table)
    if src_line is None:
        raise SystemExit(
            "REFUSING TO DEPLOY: no top-level `local %s` in RealisticEvents.lua. It is supposed "
            "to be inlined by %s; without it the variant would assign from a nil global and "
            "spawn nothing, silently." % (table, tool)
        )

    decl_lines = [line_of(r"^local %s\s*= \{\}\s*$" % name) for name in RIG_NAMES]
    if any(n is None for n in decl_lines):
        raise SystemExit(
            "REFUSING TO DEPLOY: could not find all three inert rig declarations "
            "(`local TEST_SPAWNS = {}` etc.) in RealisticEvents.lua. Either the repo copy is "
            "no longer inert - which check 6 should have caught - or the declarations were "
            "renamed and this script needs updating."
        )
    first_decl = min(decl_lines)

    # ORDERING IS THE WHOLE CORRECTNESS ARGUMENT. Assigning at the declaration is only valid
    # because the source table is defined above it.
    if src_line >= first_decl:
        raise SystemExit(
            "REFUSING TO DEPLOY: `local %s` is at line %d but the rig declarations start at "
            "line %d. Assigning at the declaration would capture a nil upvalue. Move the "
            "generated block back above the declarations, or change this script to emit a "
            "re-assignment placed after %s and before runSpawnRig()."
            % (table, src_line, first_decl, table)
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

    tag = "-- injected by tools/deploy.py: " + what
    injected = []

    def replace(m):
        name, pad = m.group(1), m.group(2)
        new = "local %s%s= %s.%s   %s" % (name, pad, table, RIG_FIELDS[name], tag)
        injected.append(new)
        return new

    out, n = DECL_RE.subn(replace, src)
    if n != 3:
        raise SystemExit(
            "REFUSING TO DEPLOY: expected to rewrite exactly 3 rig declarations, rewrote %d." % n
        )

    # Keep the injected lines in file order for the human-readable printout.
    order = {name: i for i, name in enumerate(RIG_NAMES)}
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
    # THE TEST MAP GETS A BRAIN VARIANT: DBG_SAMPLE = 1 so every soldier is sampled. At the
    # shipping default of 6, an 11-round diorama produced 41 state lines across 13 stations - about
    # three each - which cannot verify anything. The range exists to be measured.
    brain_testmap = full_logging(brain.decode("utf-8")).encode("utf-8")
    phase_inert_text = open(PHASE_SRC, encoding="utf-8").read()
    phase_inert = phase_inert_text.encode("utf-8")

    # Build every armed variant up front, so a failed assert stops deployment before a single
    # byte is written rather than halfway through the four missions.
    variants, injected = {}, {}
    for mission, (table, what, tool) in VARIANTS.items():
        text, lines = build_variant(phase_inert_text, table, what, tool)
        if table == "SHOWCASE":
            text = enable_diorama(text)
        checked = luajit_ok(text, table)
        if checked is None:
            raise SystemExit(
                "REFUSING TO DEPLOY: luajit is not on PATH, so the generated %s variant cannot be "
                "syntax-checked. Deploying an unparseable variant is silent in-game - the mission "
                "simply does nothing - so this is a hard stop, not a skip." % table
            )
        variants[mission] = text.encode("utf-8")
        injected[mission] = (table, lines)

    plan = []
    for mission in MISSIONS:
        dst_dir = os.path.join(MISSION_ROOT, mission, "scripts", "mission")
        if mission == TESTMAP:
            plan.append((mission, os.path.join(dst_dir, BRAIN_DST_NAME), brain_testmap,
                         "brain (sampled 1:1)"))
        else:
            plan.append((mission, os.path.join(dst_dir, BRAIN_DST_NAME), brain, "brain"))
        # THE BRAIN LIVES IN TWO PLACES AND BOTH MATTER. scripts/AI/ is what the mission editor's
        # Squad Spawner "Brain" dropdown enumerates (er2-plugin/docs/ui-map.md:179), so a brain
        # selected in the editor is loaded from THERE, not from scripts/mission/. This tool
        # originally wrote only scripts/mission/, which meant the two copies silently diverged the
        # moment Realistic.lua was edited - and the game would keep running the OLD brain from
        # scripts/AI/ while every check, hash and cmp in this repo confirmed the NEW one was
        # "deployed". That is precisely the stale-build failure this tool exists to prevent, one
        # directory over. They happened to still match when this was found, only because
        # Realistic.lua had not changed since the plugin's own deploy last wrote both.
        ai_dir = os.path.join(MISSION_ROOT, mission, "scripts", "AI")
        if mission == TESTMAP:
            plan.append((mission, os.path.join(ai_dir, BRAIN_DST_NAME), brain_testmap,
                         "brain (sampled 1:1, AI dir)"))
        else:
            plan.append((mission, os.path.join(ai_dir, BRAIN_DST_NAME), brain, "brain (AI dir)"))
        if mission in variants:
            label = "phase (%s)" % VARIANTS[mission][0]
            plan.append(
                (mission, os.path.join(dst_dir, PHASE_DST_NAME), variants[mission], label)
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

    SKIP_DEPLOY_DRIFT_CHECK=1 suppresses check 4l for THIS run only. 4l asks "is what is deployed
    current?", which is a post-condition of deploying and not a pre-condition of it: gating the
    write on it deadlocked deployment outright, because every repo edit made 4l red and a red
    check.sh blocked the very deploy that would have cleared it. Nothing else is relaxed, and
    every file written below is still re-read and hashed against the exact expected bytes.
    """
    env = dict(os.environ, SKIP_DEPLOY_DRIFT_CHECK="1")
    proc = subprocess.run(
        ["bash", "tests/check.sh"],
        cwd=REPO,
        env=env,
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

    # PRINT THE INJECTED LUA. The whole point of generating a variant at deploy time is that
    # nobody has to trust it - so it is shown, verbatim, every run.
    for mission in MISSIONS:
        if mission not in injected:
            continue
        table, lines = injected[mission]
        print("%s -> %s variant injects these lines (rewriting the inert declarations in place):"
              % (mission, table))
        for line in lines:
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
        # filecmp only for the VERBATIM brains. The test map's brain is deliberately different
        # (DBG_SAMPLE = 1), so comparing it to the source would fail by design; it is verified by
        # hashing the exact expected bytes, same as the phase variants.
        if label in ("brain", "brain (AI dir)"):
            same = same and filecmp.cmp(BRAIN_SRC, dst, shallow=False)
        rows.append((mission, label, "PASS" if same else "FAIL", sha(got)[:12]))
        if not same:
            failures += 1

    width = max(len(m) for m in MISSIONS)
    print("%-*s  %-16s  %-4s  %s" % (width, "mission", "file", "", "sha256"))
    for mission, label, verdict, digest in rows:
        print("%-*s  %-16s  %-4s  %s" % (width, mission, label, verdict, digest))
    print()

    # SUMMARY. Every count here is derived from the rows actually written and re-read, not from
    # the plan, so it cannot claim a variant shipped that did not.
    brain_ok = sum(1 for _, l, v, _ in rows if l == "brain" and v == "PASS")
    brain_ai_ok = sum(1 for _, l, v, _ in rows if l == "brain (AI dir)" and v == "PASS")
    inert_ok = sum(1 for _, l, v, _ in rows if l == "phase (inert)" and v == "PASS")
    n_inert = len(MISSIONS) - len(VARIANTS)
    parts = ["brain %d/%d" % (brain_ok, len(MISSIONS)),
             "brain AI-dir %d/%d" % (brain_ai_ok, len(MISSIONS)),
             "phase inert %d/%d" % (inert_ok, n_inert)]
    for mission in MISSIONS:
        if mission not in VARIANTS:
            continue
        table = VARIANTS[mission][0]
        label = "phase (%s)" % table
        got = [v for _, l, v, _ in rows if l == label]
        parts.append("%s variant %s"
                     % (table, "ok" if got and all(v == "PASS" for v in got) else "FAILED"))
    print(", ".join(parts))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
