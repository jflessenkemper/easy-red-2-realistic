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
grep -qE '^local VERBOSE\s*=\s*false' "$BRAIN" && ok "VERBOSE=false" || bad "VERBOSE must ship false"

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
