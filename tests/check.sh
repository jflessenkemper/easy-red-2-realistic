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
for flag in PROBE_APIS PROBE_GLOBALS TRACE_LOOP WATCH; do
  if grep -qE "^local $flag\s*=" "$PHASE"; then
    if grep -qE "^local $flag\s*=\s*false" "$PHASE"; then ok "$flag=false"
    else bad "$flag must ship false (diagnostic left enabled)"; fi
  fi
done

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
