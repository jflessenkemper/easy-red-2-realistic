#!/usr/bin/env bash
# Static release checks for the Realistic mod. No game required.
#
# These exist because every one of them corresponds to a defect that actually shipped at some
# point: a syntax error that bricked every brain, UserData reaching a Lua global (fatal at boot),
# a constant used but never declared, a decision label the verification tool did not know about,
# and machine-specific paths in documentation meant for strangers.
#
# Usage:  tests/check.sh          (exit 0 = all pass)
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }

LUA=$(command -v luajit || command -v luac || true)
BRAIN=Realistic.lua
PHASE=RealisticEvents.lua

echo "== 1. Lua syntax =="
if [ -z "$LUA" ]; then
  bad "no luajit/luac on PATH - cannot syntax-check"
else
  for f in "$BRAIN" "$PHASE" bench_probe.lua bench_watch.lua; do
    [ -f "$f" ] || continue
    if "$LUA" -bl "$f" >/dev/null 2>&1 || "$LUA" -p "$f" >/dev/null 2>&1; then
      ok "$f parses"
    else
      bad "$f FAILS to parse"
    fi
  done
fi

echo "== 2. No UserData can reach a Lua global =="
# A vec3/Soldier/Vehicle/Squad in a Lua global is fatal: it killed every brain at boot (192
# errors). GSET counts writes to Lua globals; it must be zero in both scripts.
if [ -n "$LUA" ] && [ "${LUA##*/}" = "luajit" ]; then
  for f in "$BRAIN" "$PHASE"; do
    n=$("$LUA" -bl "$f" 2>/dev/null | grep -c 'GSET' || true)
    [ "$n" = "0" ] && ok "$f writes no Lua globals (GSET=0)" || bad "$f writes $n Lua global(s)"
  done
else
  echo "  SKIP  (needs luajit bytecode listing)"
fi

echo "== 3. Every constant is declared exactly once and used =="
for f in "$BRAIN" "$PHASE"; do
  bad_consts=""
  while read -r c; do
    [ -z "$c" ] && continue
    d=$(grep -c "^local $c\b" "$f" || true)
    u=$(grep -c "\b$c\b" "$f" || true)
    if [ "$d" != "1" ] || [ "$u" -lt 2 ]; then bad_consts="$bad_consts $c(d=$d,u=$u)"; fi
  done < <(grep -oE '^local [A-Z][A-Z0-9_]+' "$f" | awk '{print $2}' | sort -u)
  [ -z "$bad_consts" ] && ok "$f constants all declared once and used" \
                       || bad "$f suspect constants:$bad_consts"
done

echo "== 4. Banned patterns (comments stripped - these files DOCUMENT the bans) =="
# Strip full-line and trailing Lua comments first. Without this the checks fire on the very
# comments that warn against each pattern, which is a false positive that hides real hits.
strip() { sed -e 's/--.*$//' "$1"; }
# soldier_suppressed NREs inside the engine's own dispatch; pcall cannot catch it.
if strip "$PHASE" | grep -q 'soldier_suppressed' || strip "$BRAIN" | grep -q 'soldier_suppressed'; then
  bad "subscribes to soldier_suppressed (engine NREs inside dispatch)"
else
  ok "no soldier_suppressed subscription"
fi
# .aiParams as a property throws on v2.0.9 (caused 20,689 errors); must go through getAiParams().
if strip "$BRAIN" | grep -qE '\.aiParams\b'; then
  bad ".aiParams accessed as a property (throws on v2.0.9)"
else
  ok "no .aiParams property access"
fi
# uid % N is degenerate: ER2 uids have an even stride of 262.
if strip "$BRAIN" | grep -qE 'uid\s*%\s*[0-9]'; then
  bad "uid % N split found (uids have an even stride of 262 - use floor(uid/2) % N)"
else
  ok "no degenerate uid % N split"
fi

echo "== 4b. Fill-style APIs are called WITH a table argument =="
# These engine calls FILL a caller-supplied table and return nothing useful. Calling them with no
# argument throws "Expected a table as Nth parameter" on EVERY invocation - getAllMembers() was
# called bare in two per-tick paths and produced 279 errors in a single battle.
# NOTE: counts with `grep -c`, never `grep -q`. `grep -q` exits on the FIRST match, which sends
# SIGPIPE to the `sed` feeding it; with `set -o pipefail` the pipeline then reports 141 and the
# `if` reads a real MATCH as "no match". This check silently passed on a file containing a bare
# getAllMembers() in 6 runs out of 6 while occasionally firing - a safety check that mostly did
# not check. `grep -c` consumes all input, so there is no race.
fill_bad=""
for fn in getAllMembers getSoldiersInArea getVehiclesInArea; do
  nb=$(strip "$BRAIN" | grep -cE "$fn[[:space:]]*\([[:space:]]*\)" || true)
  np=$(strip "$PHASE" | grep -cE "$fn[[:space:]]*\([[:space:]]*\)" || true)
  [ "${nb:-0}" -gt 0 ] && fill_bad="$fill_bad $fn"
  [ "${np:-0}" -gt 0 ] && fill_bad="$fill_bad $fn(phase)"
done
[ -z "$fill_bad" ] && ok "no fill-style API called with an empty argument list" \
                   || bad "called with NO table argument:$fill_bad"

echo "== 4c. Every project helper called is defined in the same file =="
# safe() was called 4x in the phase script while defined only in the brain. A nil-global call
# RAISES, the enclosing pcall swallows it, and the feature silently never runs. luajit cannot see
# it - it is a runtime lookup. Cost two game restarts to find.
python3 tests/undefined_helpers.py "$BRAIN" "$PHASE"
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

echo "== 4d. No local function is ever read as a GLOBAL (forward-reference bug) =="
# Lua resolves a name at COMPILE time. Calling a `local function` before its definition line
# compiles to a GLOBAL read, which is nil at runtime: the call raises and silently kills that
# soldier's brain. It is invisible to a syntax check AND to check 4c, which only asks whether the
# name is defined SOMEWHERE in the file - not whether it is defined BEFORE use.
# Caught for real: rosterIndex() was called at line 637 and defined at 706, so
# ADVANCE-behind-armour went from 367 fires to 0 with no error line anywhere.
# The bytecode is the oracle: any GGET of a name this file also defines locally is this bug.
if [ -n "$LUA" ] && [ "${LUA##*/}" = "luajit" ]; then
  fwd_bad=""
  for f in "$BRAIN" "$PHASE"; do
    locals_defined=$(grep -oE '^(local )?function [A-Za-z_]+' "$f" | awk '{print $NF}' | sort -u)
    globals_read=$("$LUA" -bl "$f" 2>/dev/null | grep -oE 'GGET .*"[A-Za-z_]+"' \
                   | grep -oE '"[A-Za-z_]+"' | tr -d '"' | sort -u)
    for n in $locals_defined; do
      if echo "$globals_read" | grep -qx "$n"; then fwd_bad="$fwd_bad $(basename $f):$n"; fi
    done
  done
  [ -z "$fwd_bad" ] && ok "no local function is read as a global" \
                    || bad "called BEFORE its definition (forward reference):$fwd_bad"
else
  echo "  SKIP  (needs luajit bytecode listing)"
fi

echo "== 4e. Offline brain: the decision cascade actually runs =="
# Executes Realistic.lua against a stubbed ER2 runtime and asserts which decision comes out for
# six scenarios. This is the only check that RUNS the brain rather than reading it, so it catches
# what static analysis and syntax checks cannot: a call that raises at runtime.
# ER2 does not surface a brain-coroutine death as a Lua error - the soldier just stops thinking
# and the log stays clean - so before this, such a bug cost a 15-minute battle and still showed
# only silence. Verified by reintroducing the rosterIndex forward reference: this reports
# "attempt to call global 'rosterIndex' (a nil value)" with the line number, in under a second.
if [ -n "$LUA" ] && [ "${LUA##*/}" = "luajit" ]; then
  if "$LUA" tests/offline_brain.lua >/tmp/er2_offline.$$ 2>&1; then
    ok "offline brain: all scenarios reach their expected decision"
  else
    bad "offline brain FAILED:"
    sed 's/^/        /' /tmp/er2_offline.$$ | tail -8
  fi
  rm -f /tmp/er2_offline.$$
  # The PHASE loop, driven across a battle boundary. Live testing needed a ~15 min battle AND an
  # objective capture to exercise this once; here it runs in milliseconds. It found two further
  # causes of the loop death that three previous fixes had all missed.
  if "$LUA" tests/offline_phase.lua >/tmp/er2_phase.$$ 2>&1; then
    ok "offline phase: loop survives a battle boundary and resumes"
  else
    bad "offline phase FAILED:"
    sed 's/^/        /' /tmp/er2_phase.$$ | tail -8
  fi
  rm -f /tmp/er2_phase.$$
else
  echo "  SKIP  (needs luajit)"
fi

echo "== 4f. Showcase range layout =="
# The showcase is a PLAYABLE demo, so its failure mode is a ruined demonstration rather than a
# crash: a station's enemies within SENSE_RADIUS of a neighbour's centre, or an attracting label
# dragging a neighbour's squad out of position. Both are silent in-game and both are caught here.
if [ -f missions/scenarios/showcase.lua ]; then
  if [ -n "$LUA" ] && command -v luajit >/dev/null 2>&1; then
    if out=$(luajit tests/offline_showcase.lua 2>&1); then
      ok "showcase range layout coherent ($(echo "$out" | sed -n 's/^LAYOUT OK  *//p'))"
    else
      bad "showcase range layout: $(echo "$out" | grep -E 'LAYOUT ERROR|^FAIL' | head -2 | tr '\n' ' ')"
    fi
  else
    echo "  SKIP  showcase layout needs luajit"
  fi
fi

echo "== 4g. Armour name filter classifies the real vehicle names =="
# Vehicle has no getClassName(), so feature 5 decides what counts as armour by matching substrings
# of getName(). A mis-match is SILENT in-game: the branch just never fires, or fires against cover
# that is not cover. Three of the eight names in the real missions were wrong at once -
# "Sdkfz251 1939" and "Sdkfz222" fell through UNCLASSIFIED because the allow list only had the
# SPACED spellings, and "Hotchkiss Stationary Ground" (an emplaced MG) was allowed by the token
# meant for the H35 tank.
if python3 tests/armour_filter_check.py > /tmp/armour.$$ 2>&1; then
  ok "$(sed -n 's/^ok    //p' /tmp/armour.$$ | head -1)"
else
  while read -r line; do bad "${line#FAIL  }"; done < <(grep '^FAIL' /tmp/armour.$$)
  grep -q '^FAIL' /tmp/armour.$$ || bad "armour_filter_check.py: $(head -1 /tmp/armour.$$)"
fi
rm -f /tmp/armour.$$

echo "== 4h. Donchery order of battle is coherent =="
# The OOB is data, and every way it can be wrong is SILENT in-game: an unconfirmed id spawns
# nothing, a numeric spawnVehicle direction throws past pcall and kills the phase script, and a
# historically REMOVED unit creeping back (Sdkfz251, Panzer 38, Char B1, RenaultR35 - all present
# in the game) just quietly makes the mission wrong.
if [ -f missions/donchery_oob.lua ] && [ -n "$LUA" ] && command -v luajit >/dev/null 2>&1; then
  if out=$(luajit tests/offline_donchery.lua 2>&1); then
    ok "$(echo "$out" | sed -n 's/^ok    //p' | head -1)"
  else
    while read -r line; do bad "${line#FAIL  }"; done < <(echo "$out" | grep '^FAIL')
    echo "$out" | grep -q '^FAIL' || bad "offline_donchery: $(echo "$out" | head -1)"
  fi
fi

echo "== 4i. Inlined Donchery OOB is in sync with its source =="
# The OOB is inlined rather than loaded, because loadfile() resolves from an unlocatable
# '<mission>/globals/' and its failure ABORTS the phase script even inside pcall. So the inlined
# copy can silently drift from the reviewable data file that check 4h validates.
if [ -f tools/gen_donchery_inline.py ]; then
  if out=$(python3 tools/gen_donchery_inline.py --check 2>&1); then
    ok "$(echo "$out" | sed -n 's/^ok    //p' | head -1)"
  else
    bad "$(echo "$out" | sed -n 's/^FAIL  //p' | head -1)"
  fi
fi

echo "== 4j. Mounted crews spawn on the correct side =="
# A crew spawned on the wrong faction is a perfectly SUCCESSFUL spawn: no error, no failed line,
# nothing in the log to show for it. The mounted loop hardcoded INV, which put Donchery's six
# French Hotchkiss crews on the German side, manning the French emplacements and firing the wrong
# way across the river. Only a static check catches this class.
python3 - RealisticEvents.lua missions/donchery_oob.lua <<'PY'
import re, sys
phase, oob = (open(p, encoding="utf-8").read() for p in sys.argv[1:3])

fail = []
loop = re.search(r"for i, m in ipairs\(TEST_MOUNTED\) do.*?\nend", phase, re.S)
if not loop:
    fail.append("could not find the TEST_MOUNTED loop in RealisticEvents.lua")
else:
    body = loop.group(0)
    if "m[3]" not in body:
        fail.append("the TEST_MOUNTED loop ignores m[3] (the side). It will spawn every mounted "
                    "crew as the invader, which puts the French Hotchkiss crews on the German "
                    "side - a silent, error-free wrong-faction spawn.")
    if not re.search(r"spawnSquadOnVehicle_script\([^)]*\bfac\b", body):
        fail.append("spawnSquadOnVehicle_script is not being passed the resolved `fac`; a "
                    "hardcoded INV/DEF there defeats the m[3] side entirely.")

entries = re.findall(r"DONCHERY\.mounted\[#DONCHERY\.mounted \+ 1\] = \{(.*?)\}", oob)
if not entries:
    fail.append("no DONCHERY.mounted entries found - has the OOB table been renamed?")
sides = []
for e in entries:
    m = re.search(r'"(invader|defender)"', e)
    if not m:
        fail.append("a DONCHERY.mounted entry has no explicit side: {%s}" % e.strip())
    else:
        sides.append(m.group(1))
# The assertion that actually catches the original bug: the French crews must be defenders.
if sides and "defender" not in sides:
    fail.append("every mounted crew in the OOB is an invader. The six French Hotchkiss crews "
                "must be 'defender' or they man the French guns for the Germans.")

if fail:
    for f in fail:
        print("FAIL  " + f)
    sys.exit(1)
print("ok    %d mounted crews all carry an explicit side (%d defender), and the loop honours it"
      % (len(entries), sides.count("defender")))
PY
if [ $? -eq 0 ]; then ok "mounted crew sides are explicit and honoured"; else bad "mounted crew side check failed"; fi

echo "== 4k. The spawn rig runs AFTER every callback is registered =="
# ORDERING IS THE WHOLE FEATURE SET HERE. When the spawn rig executed before registration, a
# spawn death partway through Donchery's 77 calls meant soldier_spawned, soldier_died and
# vehicle_destroyed never registered - so brain auto-attach, the kill feed and crew bail-out were
# all dead while the log showed 6 successful spawns and ZERO errors. Three runs were spent on
# that. If anyone moves the invocation back above the callbacks, this must go red.
python3 - RealisticEvents.lua <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
lines = src.split("\n")

def lineno(pred):
    return [i + 1 for i, l in enumerate(lines) if pred(l)]

call = [n for n in lineno(lambda l: l.startswith("runSpawnRig()"))]
defn = lineno(lambda l: l.startswith("local function runSpawnRig"))
cbs = {}
for i, l in enumerate(lines):
    m = re.search(r'setCallback\("(\w+)"', l)
    if m and not l.lstrip().startswith("--"):
        cbs.setdefault(m.group(1), i + 1)

fail = []
if not defn:
    fail.append("runSpawnRig() is not defined - the spawn rig must stay a function so it can be "
                "deferred past callback registration.")
if len(call) != 1:
    fail.append("expected exactly one top-level runSpawnRig() invocation, found %d" % len(call))
required = ("soldier_spawned", "soldier_died", "vehicle_destroyed")
missing = [c for c in required if c not in cbs]
if missing:
    fail.append("could not find setCallback for: %s" % ", ".join(missing))
if call and not missing:
    for c in required:
        if cbs[c] > call[0]:
            fail.append("runSpawnRig() is invoked at line %d, BEFORE setCallback(\"%s\") at line "
                        "%d. A spawn death would then disarm that callback entirely and the log "
                        "would show zero errors." % (call[0], c, cbs[c]))

if fail:
    for f in fail:
        print("FAIL  " + f)
    sys.exit(1)
print("ok    runSpawnRig() at line %d runs after all %d callbacks (latest at %d)"
      % (call[0], len(required), max(cbs[c] for c in required)))
PY
if [ $? -eq 0 ]; then ok "spawn rig is deferred past callback registration"; else bad "spawn rig ordering check failed"; fi

echo "== 4l. tools/deploy.py exists and what is deployed matches the repo build =="
# Deployment used to be a hand-run cp loop. Twice it was pointed at only the mission under
# test, leaving the other three missions on a stale brain - and the map you were testing
# behaved correctly, so the build looked good until a different map contradicted it an hour
# later. tools/deploy.py writes all four missions and hashes back what it wrote; this gate
# makes sure it still exists and that nobody has since hand-edited a deployed file or
# changed the repo without redeploying. deploy.py --check does NOT re-enter check.sh (that
# would recurse), so this is safe to call from here.
#
# DEADLOCK, FOUND 2026-09-08 AND THIS IS THE FIX. deploy.py refuses to write anything unless
# check.sh is green - correctly, a red build must never ship. But this check goes red on exactly
# the drift that deploying would REMOVE, so the moment anyone edited Realistic.lua or
# RealisticEvents.lua, deployment became impossible: check.sh was red because the repo was not
# deployed, and deploy.py would not deploy because check.sh was red. "Is what is deployed
# current?" is a POST-condition of deploying, not a pre-condition of it. So deploy.py sets
# SKIP_DEPLOY_DRIFT_CHECK=1 for its own gating run and this check reports SKIP; every other
# caller - a human, CI, a bare `bash tests/check.sh` - still gets the full gate, and deploy.py
# re-reads and hashes back every file it writes afterwards regardless.
if [ "${SKIP_DEPLOY_DRIFT_CHECK:-0}" = "1" ]; then
  echo "  SKIP  deployed-vs-repo drift (deploy.py is the caller; it is about to fix any drift)"
else
python3 - <<'PY'
import os, subprocess, sys
repo = os.getcwd()
deploy = os.path.join(repo, "tools", "deploy.py")

fail = []
if not os.path.isfile(deploy):
    fail.append("tools/deploy.py is missing - deployment is back to a hand-run cp loop, "
                "which has already shipped three stale missions twice.")
elif not os.access(deploy, os.X_OK):
    fail.append("tools/deploy.py is not executable")
else:
    p = subprocess.run([sys.executable, deploy, "--check"], cwd=repo,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if p.returncode != 0:
        for line in p.stdout.strip().split("\n"):
            if line.strip():
                fail.append("deploy.py --check: " + line.strip())

if fail:
    for f in fail:
        print("FAIL  " + f)
    sys.exit(1)
print("ok    deploy.py --check agrees with all deployed files")
PY
if [ $? -eq 0 ]; then ok "deployed files match the repo build (deploy.py --check)"; else bad "deploy.py --check reports drift or deploy.py is missing"; fi
fi   # SKIP_DEPLOY_DRIFT_CHECK

echo "== 4m. Inlined showcase range is in sync with its source =="
# Mirrors 4i, for the other inlined data set. The showcase range is inlined rather than loaded for
# the same reason the Donchery OOB is: loadfile() resolves from an unlocatable '<mission>/globals/'
# and its failure ABORTS the phase script even inside pcall. So the inlined copy can silently drift
# from missions/scenarios/showcase.lua - the file that check 4f actually validates - and the drift
# is invisible in-game, because a stale range still builds and still looks like a range.
#
# It also re-asserts the CUT: only the text above showcase.lua's `--@@ SHOWCASE INLINE CUT` marker
# may be inlined. Below that marker are a top-level `return`, a spawn emitter that must not run
# before setCallback registration, and a `while true ... sleep(1)` HUD loop - inlining any of it
# would stop RealisticEvents.lua dead, silently, before a single callback registered.
python3 - <<'PY'
import os, subprocess, sys
repo = os.getcwd()
tool = os.path.join(repo, "tools", "gen_showcase_inline.py")
fail = []
if not os.path.isfile(tool):
    fail.append("tools/gen_showcase_inline.py is missing - the showcase range can no longer be "
                "inlined, so the test map's phase script would ship inert and spawn nothing.")
else:
    p = subprocess.run([sys.executable, tool, "--check"], cwd=repo,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if p.returncode != 0:
        for line in p.stdout.strip().split("\n"):
            if line.strip():
                fail.append(line.strip())
    else:
        # The tool proves sync. This proves the inlined block is actually WIRED: the source table
        # must be declared above the rig declarations, which is what deploy.py's variant assigns at.
        # WORD-BOUNDARY REGEX, not str.startswith. Caught while red-testing this very gate:
        # `l.startswith("local SHOWCASE")` also matches `local SHOWCASE_RENAMED`, so renaming the
        # table - which leaves the inlined copy perfectly in sync while destroying the name
        # deploy.py assigns from - sailed straight through. deploy.py itself uses `\b` and would
        # have refused, but a gate that only fails when a later tool also fails is not a gate.
        import re
        src = open(os.path.join(repo, "RealisticEvents.lua"), encoding="utf-8").read()
        lines = src.split("\n")
        def line_of(pattern):
            for i, l in enumerate(lines):
                if re.match(pattern, l):
                    return i + 1
            return None
        sc = line_of(r"^local SHOWCASE\b")
        decl = line_of(r"^local TEST_SPAWNS\b")
        run = line_of(r"^runSpawnRig\(\)")
        if sc is None:
            fail.append("no top-level `local SHOWCASE` in RealisticEvents.lua - the inlined block "
                        "no longer defines the table deploy.py assigns from, and the test-map "
                        "variant would ship `TEST_SPAWNS = nil`: no spawns, no error, no log line.")
        elif decl is None or run is None:
            fail.append("could not locate `local TEST_SPAWNS` and/or `runSpawnRig()`")
        elif not (sc < decl < run):
            fail.append("ordering is wrong: local SHOWCASE at %s, local TEST_SPAWNS at %s, "
                        "runSpawnRig() at %s - must be strictly increasing or the assignment "
                        "captures a nil upvalue." % (sc, decl, run))
if fail:
    for f in fail:
        print("FAIL  " + f)
    sys.exit(1)
print("ok    inlined showcase range is in sync and defined above the rig it feeds")
PY
if [ $? -eq 0 ]; then ok "inlined showcase range in sync with missions/scenarios/showcase.lua"; else bad "inlined showcase range is stale or mis-ordered"; fi

echo "== 5. Decision labels match the verification tool =="
TOOL=../er2-plugin/tools/analyse_run.py
if [ -f "$TOOL" ]; then
  python3 - "$BRAIN" "$TOOL" <<'PY'
import re, sys
src, tool = open(sys.argv[1]).read(), open(sys.argv[2]).read()
emitted = set(re.findall(r'decision(?:, detail)? = "([A-Z][A-Za-z/-]+)"', src))
emitted |= set(re.findall(r'return "([A-Z][A-Za-z/-]+)"', src))
emitted |= set(re.findall(r'"(AT-[a-z]+)"', src))
known = set(re.findall(r'"([A-Z][A-Za-z/-]+)"', tool.split('# Thresholds')[0]))
unknown = sorted(emitted - known)
print(("  \033[31mFAIL\033[0m  labels the tool does not know: " + ", ".join(unknown))
      if unknown else "  \033[32mPASS\033[0m  every emitted label is known to analyse_run.py")
sys.exit(1 if unknown else 0)
PY
  [ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
else
  echo "  SKIP  analyse_run.py not found at $TOOL"
fi

echo "== 6. Shipping defaults =="
# Every diagnostic flag must ship OFF. This has slipped twice: DEBUG=true flooded the in-game
# overlay so badly it was reported as "a ton of errors" (the log had ZERO), and PROBE_APIS=true
# re-ran the one-shot bench probe every battle. check.sh used to guard only VERBOSE.
for flag in VERBOSE DEBUG; do
  for f in "$BRAIN" "$PHASE"; do
    if grep -qE "^local $flag\s*=" "$f"; then
      if grep -qE "^local $flag\s*=\s*false" "$f"; then ok "$(basename $f): $flag=false"
      else bad "$(basename $f): $flag must ship false"; fi
    fi
  done
done
for flag in PROBE_APIS PROBE_GLOBALS TRACE_LOOP WATCH TELEMETRY SHOWCASE_HUD; do
  if grep -qE "^local $flag\s*=" "$PHASE"; then
    if grep -qE "^local $flag\s*=\s*false" "$PHASE"; then ok "$flag=false"
    else bad "$flag must ship false (diagnostic left enabled)"; fi
  fi
done

# DBG_SAMPLE is a SHIPPING DEFAULT, not a flag, and it was ungated until 2026-09-08 even though
# docs/LOOP-PROMPT.md claimed check 6 covered it. Every test scenario sets it to 1 (at 6, a ten-man
# scenario traces one man), so a scenario build shipped 29/29 green with tracing wide open. It also
# lives in the BRAIN, while the loop above only scans the phase script.
if grep -qE '^local DBG_SAMPLE\s*=\s*6\b' "$BRAIN"; then
  ok "DBG_SAMPLE=6 (shipping default)"
else
  bad "DBG_SAMPLE must ship 6 - found: $(grep -oE '^local DBG_SAMPLE\s*=\s*[0-9]+' "$BRAIN" || echo none)"
fi

echo "== 5b. Fire support is reachable at all =="
# FIRE_DANGER_R must stay BELOW the brain's SENSE_RADIUS. If they are equal, feature 19 is
# mathematically unreachable: the radioman publishes the enemy centroid as the target, that
# centroid is within SENSE_RADIUS of him by construction, and danger-close then refuses because HE
# is a friendly inside the radius of his own target. That was the state for the project's whole
# history - six observed requests, six refusals, and it read as bad luck rather than arithmetic.
sr=$(grep -oE '^local SENSE_RADIUS[[:space:]]*=[[:space:]]*[0-9]+' "$BRAIN" | grep -oE '[0-9]+$')
fd=$(grep -oE '^local FIRE_DANGER_R[[:space:]]*=[[:space:]]*[0-9]+' "$PHASE" | grep -oE '[0-9]+$')
if [ -n "$sr" ] && [ -n "$fd" ]; then
  if [ "$fd" -lt "$sr" ]; then
    ok "FIRE_DANGER_R $fd < SENSE_RADIUS $sr (a barrage can be accepted)"
  else
    bad "FIRE_DANGER_R $fd >= SENSE_RADIUS $sr - feature 19 is UNREACHABLE, every request refuses"
  fi
fi

echo "== 6b. Toolchain is capable =="
# Without luajit, checks 2, 4d and 4e SKIP and are simply not counted - the script still printed
# "FAIL 0" on a 24-check run and that read as a full pass. Worse, 4e (which LOADS the brain) is the
# only gate that catches the Lua 200-local ceiling, because `luajit -bl` can pass a file the real
# loader rejects. So a missing luajit is itself a failure, not a skip.
if command -v luajit >/dev/null 2>&1; then
  ok "luajit present ($(luajit -v 2>&1 | head -1 | cut -d' ' -f1-2)) - bytecode and load checks ran"
else
  bad "luajit missing - checks 2, 4d and 4e did NOT run; this score is not a release gate"
fi

echo "== 6c. DEC decision-code map agrees across all three copies =="
if python3 tests/dec_map_check.py > /tmp/decmap.$$ 2>&1; then
  ok "$(sed -n 's/^ok    //p' /tmp/decmap.$$ | head -1)"
else
  while read -r line; do bad "${line#FAIL  }"; done < <(grep '^FAIL' /tmp/decmap.$$)
  grep -q '^FAIL' /tmp/decmap.$$ || bad "dec_map_check.py failed: $(head -1 /tmp/decmap.$$)"
fi
rm -f /tmp/decmap.$$

echo "== 7. Docs are usable by a stranger =="
if grep -qE 'jflessenkemper|/tmp/claude|ME_Stonne' realistic.md; then
  bad "realistic.md contains machine-specific paths"
else
  ok "realistic.md has no machine-specific paths"
fi
grep -q '# 0. INSTALL' realistic.md && ok "install instructions present" || bad "no install section"
for f in "$BRAIN" "$PHASE"; do
  grep -q "$f" realistic.md && ok "$f documented" || bad "$f not mentioned in realistic.md"
done

echo
echo "-------------------------------------------"
printf 'PASS %d   FAIL %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
