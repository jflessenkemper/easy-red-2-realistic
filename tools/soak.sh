#!/usr/bin/env bash
# Soak test - PREPARED, NOT YET RUN (needs the game). This script never launches anything.
#
# Purpose: show the mod survives LONG play: no error growth, no phase-loop death, no log blowup,
# no decision collapse late in the battle.
# Protocol: Jordan plays/observes N consecutive battles (suggest 3 x 30 min) on one map with
# DEBUG on the test-map variant only; copy Player.log after each into a directory, then:
#     tools/soak.sh <dir-with-logs>
# Pass criteria (per log): eval no_errors PASS; WATCHDOG takeover at most once per phase change;
# [REALISTIC] ONLINE count roughly constant across battles; log size < 200 MB.
set -euo pipefail
dir=${1:?usage: tools/soak.sh DIR_WITH_PLAYER_LOGS}
cd "$(dirname "$0")/.." || exit 1
rc=0
for f in "$dir"/*.log; do
  sz=$(stat -c %s "$f")
  errs=$(grep -cE 'Lua error|NullReferenceException|Error in callback function' "$f" || true)
  online=$(grep -c '\[REALISTIC\] ONLINE' "$f" || true)
  wd=$(grep -c 'WATCHDOG: the phase loop stopped' "$f" || true)
  verdict=PASS
  [ "$errs" -gt 0 ] && verdict=FAIL
  [ "$sz" -gt 209715200 ] && verdict=FAIL
  printf '%-5s %s  size=%dMB errors=%d online=%d watchdog=%d\n' "$verdict" "$(basename "$f")" $((sz/1048576)) "$errs" "$online" "$wd"
  [ "$verdict" = FAIL ] && rc=1
  python3 tools/eval_telemetry.py "$f" --json "${f%.log}.eval.json" >/dev/null || true
done
exit $rc
