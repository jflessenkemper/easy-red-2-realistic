#!/usr/bin/env python3
"""Record the README feature clips end to end, in one command.

Why this exists
---------------
This run has been done by hand several times and fumbled every time: a recording
window spent on bare ground, a clip captured at 0.9 fps because nobody passed
--region, a diagnostic build left deployed, the wrong resolution so every menu
click missed. Each mistake cost a ~15-minute game cycle.

Everything below is mechanical. Making it one script means the last step of the
job is atomic and verifiable instead of a sequence of judgement calls made while
tired.

What it does
------------
  1. refuses if another Steam game is running (the overlay hazard -- see the
     plugin's guard; this is the second line of defence, not the first)
  2. deploys a DIAGNOSTIC test-map build so clips can be LABELLED by the decisions
     that actually fired (shipping has DEBUG=false and logs nothing at all)
  3. launches DIRECT (no Steam launch options, so no Steam shutdown at any point)
  4. drives into the test map and the squad-follow spectator
  5. records each clip with --region (cost is proportional to pixel AREA: full
     frame ~660 ms/1.5 fps vs 640x360 ~69 ms/14 fps), rejecting empty frames
  6. RESTORES the shipping build and verifies by grep on the DEPLOYED files
  7. encodes small mp4 + gif into docs/clips/

Usage
  python3 tools/capture_clips.py --dry-run     # everything except the game
  python3 tools/capture_clips.py
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
MOD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN = os.path.join(HOME, "er2-plugin", "plugins", "easy-red-2")
ER2 = os.path.join(PLUGIN, "bin", "er2")
RECORD = os.path.join(PLUGIN, "tools", "record.py")
PROBE = os.path.join(PLUGIN, "tools", "visual_probe.py")
TOOLS = os.path.join(PLUGIN, "tools")
LOG = os.path.join(HOME, ".config/unity3d/Corvostudio/Easy Red 2/Player.log")
CFG = os.path.join(HOME, ".config/unity3d/Corvostudio/Easy Red 2/mission_editor")
TESTMAP = "ME_Realistic Test map_o6526q70"
CLIPS = os.path.join(MOD, "docs", "clips")

# Region crops the action while keeping the frame rate usable. Centre-ish, since
# the spectator keeps its subject near the middle.
REGION = "560,300,800,450"
FPS = 9

SHOTS = [
    # name            seconds  wait-log regex (None = record immediately)
    ("squad-tactics",  16, None),
    ("transport",      16, None),
    ("diorama-reset",  48, r"round .* over"),
    ("casualty",       22, r"a man is down"),
]


def say(msg):
    print("[clips] %s" % msg, flush=True)


def run(cmd, timeout=900, check=True):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise RuntimeError("%s -> rc=%d\n%s%s" % (" ".join(cmd[:3]), r.returncode,
                                                  r.stdout[-400:], r.stderr[-400:]))
    return r.stdout.strip()


def foreign_games():
    sys.path.insert(0, TOOLS)
    import virtual_pad
    return virtual_pad.foreign_steam_games()


def set_debug(on):
    """Flip DEBUG in the DEPLOYED test-map brain only; Stonne is never touched."""
    changed = []
    for sub in ("mission", "AI"):
        p = os.path.join(CFG, TESTMAP, "scripts", sub, "Realistic.lua")
        if not os.path.exists(p):
            continue
        src = open(p, encoding="utf-8").read()
        want, other = ("true", "false") if on else ("false", "true")
        new = src.replace("local DEBUG = %s" % other, "local DEBUG = %s" % want, 1)
        if new != src:
            open(p, "w", encoding="utf-8").write(new)
            changed.append(p)
    return changed


def verify_shipping():
    """Grep the DEPLOYED files. A sed that missed a trailing comment has silently
    left diagnostics on before, so never trust the repo copy for this."""
    bad = []
    for root, _dirs, files in os.walk(CFG):
        for f in files:
            if f != "Realistic.lua":
                continue
            p = os.path.join(root, f)
            for line in open(p, encoding="utf-8", errors="replace"):
                if line.startswith("local DEBUG = true"):
                    bad.append(p)
                    break
    return bad


def encode(name):
    src = os.path.join("/tmp/er2_mcp/clips", "%s.mp4" % name)
    if not os.path.exists(src):
        return False
    os.makedirs(CLIPS, exist_ok=True)
    mp4 = os.path.join(CLIPS, "%s.mp4" % name)
    gif = os.path.join(CLIPS, "%s.gif" % name)
    pal = "/tmp/pal_%s.png" % name
    run(["ffmpeg", "-y", "-loglevel", "error", "-i", src, "-vf", "scale=800:-2",
         "-c:v", "libx264", "-crf", "30", "-preset", "slow",
         "-pix_fmt", "yuv420p", "-an", mp4])
    run(["ffmpeg", "-y", "-loglevel", "error", "-i", mp4,
         "-vf", "fps=6,scale=560:-1:flags=lanczos,palettegen", pal])
    run(["ffmpeg", "-y", "-loglevel", "error", "-i", mp4, "-i", pal,
         "-lavfi", "fps=6,scale=560:-1:flags=lanczos[x];[x][1:v]paletteuse", gif])
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true",
                    help="check every precondition and tool path; touch no game")
    args = ap.parse_args()

    # --- preconditions, all of them, before anything is changed -----------------
    missing = [p for p in (ER2, RECORD, PROBE) if not os.path.exists(p)]
    if missing:
        sys.exit("missing tooling: %s" % ", ".join(missing))
    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg is required to encode the clips")
    if not os.path.isdir(os.path.join(CFG, TESTMAP)):
        sys.exit("test map not deployed at %s" % os.path.join(CFG, TESTMAP))

    games = foreign_games()
    if games:
        sys.exit("REFUSING: Steam game(s) running with AppId %s. Launching ER2 now would push a "
                 "DLC store page through the SHARED Steam overlay and can leave their game with an "
                 "input grab. Wait until they have finished." % ", ".join(games))

    if args.dry_run:
        say("dry run: tooling present, no foreign game, test map deployed")
        say("would record: %s" % ", ".join(n for n, _s, _w in SHOTS))
        say("would write:  %s" % CLIPS)
        return 0

    deployed_diag = []
    try:
        say("deploying diagnostic build (DEBUG=true) so clips can be labelled")
        deployed_diag = set_debug(True)
        say("  patched %d file(s)" % len(deployed_diag))

        say("launching DIRECT at 1920x1080 (no Steam launch options, no shutdown)")
        say(run([ER2, "launch", json.dumps({"via_steam": False,
                                            "width": 1920, "height": 1080, "fps": 30})],
                timeout=700))

        say("entering the test map")
        out = run([ER2, "play_mission", json.dumps({"name": "Realistic Test map"})], timeout=900)
        if "REFUSING" in out or "STOPPED" in out:
            raise RuntimeError("could not reach the mission:\n%s" % out)
        time.sleep(20)

        # faction, then the squad-follow spectator; coords are 1920x1080-calibrated
        run([ER2, "click", json.dumps({"x": 813, "y": 887, "reliable": True})])
        time.sleep(14)
        run([ER2, "click", json.dumps({"x": 55, "y": 940, "reliable": True})])
        time.sleep(5)

        made = []
        for name, secs, waitlog in SHOTS:
            # cycle to a different squad so the clips are not all the same men
            for _ in range(3):
                run([ER2, "key", json.dumps({"key": "right"})])
                time.sleep(2)
            cmd = [sys.executable, RECORD, "clip", "--seconds", str(secs),
                   "--fps", str(FPS), "--name", name, "--region", REGION, "--cols", "6"]
            if waitlog:
                cmd += ["--wait-log", waitlog, "--wait-timeout", "240"]
            say("recording %s (%ss%s)" % (name, secs, ", on /%s/" % waitlog if waitlog else ""))
            print(run(cmd, timeout=secs + 320, check=False))
            if encode(name):
                made.append(name)

        say("recorded and encoded: %s" % (", ".join(made) or "NOTHING"))
        return 0 if made else 1

    finally:
        # Always restore, even on failure. A diagnostic build left deployed means
        # the user's next session runs with DEBUG logging on.
        say("stopping the game and restoring the shipping build")
        subprocess.run([ER2, "stop"], capture_output=True, text=True, timeout=200)
        set_debug(False)
        subprocess.run([sys.executable, os.path.join(MOD, "tools", "deploy.py")],
                       capture_output=True, text=True, timeout=300)
        left = verify_shipping()
        if left:
            say("WARNING: DEBUG=true still deployed in: %s" % ", ".join(left))
        else:
            say("verified by grep: no diagnostic build deployed")


if __name__ == "__main__":
    sys.exit(main())
