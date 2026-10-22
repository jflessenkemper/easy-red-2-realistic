#!/usr/bin/env bash
# Release-review gate: everything offline, one command.   tests/review.sh   (exit 0 = all gating pass)
#
# Runs, in order: tests/check.sh (the original static gate), luacheck, lua-language-server --check,
# the main-chunk local budget, busted specs (pure logic + property + harnesses + flags), semgrep
# project rules (+ negative fixture), ruff, shellcheck, golden files, eval-scorer fixtures - then
# regenerates the evidence site. Results go to artifacts/review/*.txt|json (gitignored).
# Mutation testing is SEPARATE (about 1 min): tools/mutate.py --json artifacts/review/mutation.json
#
# Known, explained non-gating failure: check.sh 4l (deployed-vs-repo drift). The deployed game copy
# is the test/visual-check diagnostic build and nothing may be deployed offline, so 4l is EXPECTED
# red here. review.sh reports it but does not let it fail the review; set STRICT_4L=1 to gate on it.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/env.sh
. tests/env.sh
OUT=artifacts/review; mkdir -p "$OUT"
PASS=0; FAIL=0; SKIP=0
declare -A RES
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$2"; PASS=$((PASS+1)); RES[$1]="pass|$2"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$2"; FAIL=$((FAIL+1)); RES[$1]="fail|$2"; }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$2"; SKIP=$((SKIP+1)); RES[$1]="skip|$2"; }
have() { command -v "$1" >/dev/null 2>&1; }
LUAF="Realistic.lua RealisticEvents.lua bench_probe.lua bench_watch.lua"

echo "== R1. tests/check.sh =="
bash tests/check.sh > "$OUT/check.txt" 2>&1
sed 's/\x1b\[[0-9;]*m//g' "$OUT/check.txt" > "$OUT/check.plain.txt"
cp=$(grep -c '^  PASS' "$OUT/check.plain.txt"); cf=$(grep -c '^  FAIL' "$OUT/check.plain.txt")
other=$(grep '^  FAIL' "$OUT/check.plain.txt" | grep -vc 'deploy.py --check' || true)
if [ "$other" = 0 ] && { [ "$cf" = 0 ] || [ "${STRICT_4L:-0}" != 1 ]; }; then
  ok check "check.sh $cp pass / $cf fail$([ "$cf" -gt 0 ] && echo ' (only 4l deployed-drift: expected offline)')"
else bad check "check.sh $cp pass / $cf fail - see $OUT/check.plain.txt"; fi

echo "== R2. luacheck (gate: errors + undefined/set globals W1xx) =="
if have luacheck; then
  luacheck $LUAF > "$OUT/luacheck.txt" 2>&1
  g=$(luacheck --only 1 -- $LUAF 2>&1 | tail -1)
  tot=$(tail -1 "$OUT/luacheck.txt")
  case "$g" in *"0 warnings / 0 errors"*) ok luacheck "luacheck: 0 global/0 errors; advisory: $tot";; *) bad luacheck "luacheck globals: $g";; esac
else skip luacheck "luacheck not installed"; fi

echo "== R3. lua-language-server --check =="
if have lua-language-server; then
  rm -rf /tmp/er2-luals.$$
  lua-language-server --check . --checklevel=Warning --logpath /tmp/er2-luals.$$ > "$OUT/luals.txt" 2>&1
  if grep -q 'no problems found' "$OUT/luals.txt"; then ok luals "lua-language-server: no problems (Warning level)"; else bad luals "lua-language-server: $(grep -o 'Found [0-9]* problems[^]]*' "$OUT/luals.txt" | tail -1)"; fi
  rm -rf /tmp/er2-luals.$$
else skip luals "lua-language-server not installed"; fi

echo "== R4. main-chunk local budget (Lua limit 200) =="
if python3 tests/local_count.py Realistic.lua RealisticEvents.lua > "$OUT/locals.txt" 2>&1; then
  ok locals "$(tr '\n' ' ' < "$OUT/locals.txt" | sed 's/ok    //g')"
else bad locals "$(grep FAIL "$OUT/locals.txt" | head -1)"; fi

echo "== R5. busted specs =="
if have busted; then
  busted -o TAP > "$OUT/busted.tap" 2>&1; rc=$?
  n=$(grep -c '^ok ' "$OUT/busted.tap"); nf=$(grep -c '^not ok ' "$OUT/busted.tap")
  [ $rc = 0 ] && ok busted "busted: $n ok / $nf not ok" || bad busted "busted: $n ok / $nf not ok"
else skip busted "busted not installed"; fi

echo "== R6. semgrep project rules =="
if have semgrep; then
  semgrep scan --metrics=off --disable-version-check -q --config .semgrep/er2.yml --json Realistic.lua RealisticEvents.lua > "$OUT/semgrep.json" 2>/dev/null
  hits=$(python3 -c "import json;print(len(json.load(open('$OUT/semgrep.json'))['results']))")
  neg=$(semgrep scan --metrics=off --disable-version-check -q --config .semgrep/er2.yml --json tests/fixtures/semgrep_bad.lua 2>/dev/null | python3 -c "import json,sys;print(len({r['check_id'] for r in json.load(sys.stdin)['results']}))")
  if [ "$hits" = 0 ] && [ "$neg" = 5 ]; then ok semgrep "semgrep: 0 hits in shipping Lua; all 5 rules fire on the negative fixture"
  else bad semgrep "semgrep: $hits hits in shipping Lua; $neg/5 rules fire on the fixture"; fi
else skip semgrep "semgrep not installed"; fi

echo "== R7. ruff (gate: E9 syntax + F pyflakes) =="
if have ruff; then
  ruff check --select E9,F --output-format concise tools tests > "$OUT/ruff.txt" 2>&1 && ok ruff "ruff E9,F clean" || bad ruff "ruff: $(tail -1 "$OUT/ruff.txt")"
else skip ruff "ruff not installed"; fi

echo "== R8. shellcheck (warning+) =="
if have shellcheck; then
  shellcheck -S warning tests/check.sh tests/review.sh tests/env.sh tools/soak.sh > "$OUT/shellcheck.txt" 2>&1 && ok shellcheck "shellcheck clean (4 scripts)" || bad shellcheck "shellcheck: $(grep -c '^In ' "$OUT/shellcheck.txt") findings"
else skip shellcheck "shellcheck not installed"; fi

echo "== R9. golden files (prop/layout generators) =="
python3 tests/golden_check.py > "$OUT/golden.txt" 2>&1 && ok golden "$(sed -n 's/^ok    //p' "$OUT/golden.txt")" || bad golden "golden: $(grep -c FAIL "$OUT/golden.txt") outputs differ"

echo "== R10. eval scorer on synthetic fixtures =="
python3 tests/eval_fixture_check.py > "$OUT/evalfix.txt" 2>&1 && ok evalfix "$(sed -n 's/^ok    //p' "$OUT/evalfix.txt")" || bad evalfix "$(head -1 "$OUT/evalfix.txt")"
python3 tools/eval_telemetry.py tests/fixtures/eval/synthetic_pass.trace --json "$OUT/eval_synthetic.json" > /dev/null 2>&1

{
  echo "{"
  first=1
  for k in "${!RES[@]}"; do
    v=${RES[$k]}; [ $first = 1 ] || echo ","; first=0
    printf '  "%s": {"status": "%s", "detail": %s}' "$k" "${v%%|*}" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "${v#*|}")"
  done
  printf ',\n  "_when": "%s", "_commit": "%s"\n}\n' "$(date '+%Y-%m-%d %H:%M %Z')" "$(git rev-parse --short HEAD)"
} > "$OUT/review.json"

echo "== R11. evidence site =="
python3 tools/build_evidence.py > "$OUT/evidence.txt" 2>&1 && ok evidence "$(tail -1 "$OUT/evidence.txt")" || bad evidence "build_evidence.py failed: $(tail -1 "$OUT/evidence.txt")"

echo
echo "review: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" = 0 ]
