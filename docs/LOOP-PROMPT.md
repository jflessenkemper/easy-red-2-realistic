# Autonomous loop prompt — finish the mod

Paste the block below into `/loop`. Self-contained: a tick may start after compaction.

---

You are finishing a WW2 soldier-AI Lua mod for Easy Red 2 and its Claude Code plugin, without user
input. Repos: `/var/home/jflessenkemper/er2-realistic` (mod), `/var/home/jflessenkemper/er2-plugin`
(plugin). LOW reasoning effort. Decide, record the evidence, continue. Do not ask questions.

**Clip rule (2026-10-23):** README/evidence clips are recorded at **30 fps**, downscaled to **≤960 px
wide** (replaces 6–14 fps). Check the fps the recorder actually achieved; a clip below 30 fps is not evidence.
The release review pack is `tests/review.sh` + `docs/RELEASE-READINESS.md` + `evidence/index.html`.

## THE METHOD RULES — these cost more time than every bug combined

1. **PRINT THE VALUE. DO NOT DEDUCE IT.** Five consecutive hypotheses about one symptom were all
   wrong, each offline-validated first, each costing a ~15-minute in-game run. What solved it was
   logging what the call actually returned. If a guarded call might be failing, log its result AND
   its error before theorising — `safe()` swallows errors, so use `pcall` and log `err` when
   diagnosing.
2. **WAIT FOR EVIDENCE, NEVER FOR TIME.** One run was collected 11 seconds before the thing under
   test first executed, and the result was reported as a failure. Poll the log for the event count
   you need (e.g. `grep -c 'DIORAMA hurt:'`) with a timeout. The rig places 29 squads with frame
   pacing before the main loop starts, so wall-clock timing is meaningless.
3. **BREAK EVERY GATE AND WATCH IT GO RED.** About thirteen tests-that-cannot-fail have been found
   here, several written in a single session: inserted at an anchor that did not exist; matching
   `radius = 10` from inlined data instead of `CYC.radius`; a threshold of 5 that passed both the
   fixed build (912 orders) and the broken one (12); asserting on a code path the feature never
   uses.
4. **A COUNT IS NOT BEHAVIOUR.** "11 of 13 stations working" came from 41 log lines. "The range
   collapsed to one station" came from reading log VOLUME as activity, when the brain simply logs
   on change. Report distinct soldiers, positions and distances first; decisions last.
5. **FOLLOW THIS CODEBASE'S GUARDED-INTEROP IDIOMS** — they are load-bearing, and inventing your
   own fails SILENTLY: `safeGet(...) ~= false` for aliveness (nil means alive); the cached `INV`
   compared `== true` for side; a FRESH `vec3` built at the point of use, never a stored one.

## STATE — verified, do NOT re-derive

Gates: mod `tests/check.sh` **PASS 41**, plugin **PASS 12**, offline brain 19/19, offline phase
4/4. Mod tagged v1.4.0 (v1.5.0 prepared, untagged — RELEASE-CHECKLIST.md), plugin v1.6.0. Both repos clean. Game **v2.1.0**. Official API docs exist
at **https://easyred2.com/wiki/scripting** — READ THEM BEFORE PROBING ANYTHING.

- **TEST MAP** (`[TEST] Realistic Feature Range`, renamed from `sdgsdg`): builds 29/29 squads, 7/7
  vehicles, 1/1 crew, 0 failures, 0 errors, ~110 brains, squads spread across all 13 stations.
  Usable as a STATIC exhibit.
- **DONCHERY / Stonne**: 7 squads + 25 vehicles + 1 crew place cleanly, 0 errors. Trimmed to an
  8-spawn-squad engine budget (mounted crews count against it). The full researched force is
  preserved under `DONCHERY.researched` and still gated.
- **FEATURE 19 PROVEN** (24 shells). **FORMATION SETTLED** — both modes sit inside the 0.23 noise
  floor, default stays kette, do not revisit. **Features 5 and 18** need editor-placed vehicles.
- `"Pak 36"` is NOT a valid vehicle id — it NREs and kills the phase script. Gated.
- `spawnVehicle` arg 3 is **Euler DEGREES**, not a direction, and it DOES return a usable handle.
  The phase loop already waits-and-resumes across battles — do NOT "fix" it.

## THE ONE BLOCKING UNKNOWN — start here

`er2.getSoldiersInArea` returns men for stations 1, 2 and 5 and **ZERO** for the rest, with no
error and sane coordinates:

    DIORAMA query st1: ok=true n=9 err=nil centre=(372,1,466) r=640
    DIORAMA query st3: ok=true n=0 err=nil centre=(1372,1,466) r=640
    DIORAMA query st8: ok=true n=0 err=nil centre=(1872,1,966) r=640

The soldiers ARE there: their own logged positions put 8 near station 8, 13 near station 3 and 14
near station 10, spanning x −42..1996, z −78..1972. The diorama's heal, reset, scripted casualty
and station signs all depend on this query, so all four are dead beyond the near corner of the
grid.

Do ONE focused experiment, not another fix. Does the result depend on distance from the world
origin, from the player, or from the first objective? Is there a cap on the returned count? Does a
smaller radius at a far station work? Write a single dbg-logged sweep that queries several points
with several radii in ONE run and logs every result. If the query turns out to be origin- or
player-relative, the station-local design must go and everything should be driven from one global
sweep — which `CYC.doReset` already does and is the model to copy.

## QUEUE, in order

1. **Resolve the query mystery above.** The whole diorama is blocked on it.
2. **Verify the station signs.** `Objective.setText` is wired and never confirmed; it shares the
   broken query, so it may simply start working. Read one in-game and say so.
3. **Donchery editor spawners.** The `.mer2` is a .NET BinaryFormatter stream and `spawnType` is a
   bare enum int — guessing would corrupt the user's mission. If the user supplies the "disabled"
   integer, automate it; otherwise leave the README instruction.
4. **Close what is closable of the six NOT PROVEN features.** Cover (feature 2) is the best
   candidate: `isOnCover` exists and has never been sampled, and `tools/watch_audit.py` already
   cross-tabulates decisions against engine ground truth.
5. **Plugin**: MCP resources for the UI map and API reference, a `playtest-runner` agent with
   `memory: project`, skill `allowed-tools` + `disable-model-invocation`. Do NOT add tool
   annotation hints or MCP `outputSchema` — both are absent from the official docs.
6. **Housekeeping**: keep README / realistic.md / CHANGELOG true, sync check counts, and tag both
   repos when a phase lands.

## HARD RULES

- **NEVER force-kill Steam.** A SIGKILL destroyed the login session once and blocked everything.
  Wait out `steam -shutdown` for 2+ minutes; if it will not exit, abandon the Steam-mode task and
  report it. Steam often refuses to relaunch the game until IT is restarted — that is the known
  fix, and it is not optional.
- **AUDIO: move only the game's own `FMOD*` sink-input to the `er2_silence` null sink.** Never mute
  `@DEFAULT_SINK@`, and never loop over all sink-inputs — that silenced the user's other game and a
  live voice call. `PULSE_SINK` alone is NOT sufficient: move the stream after launch and verify.
- **Never leave a diagnostic build deployed.** `tools/deploy.py` restores it; verify by grep. The
  test map legitimately ships `DBG_SAMPLE = 1`; `DEBUG` must be false everywhere.
- The `-f` variants of pgrep/pkill are BLOCKED here (they match the calling shell). Use `pidof`, or
  `pkill -9 -x <exact-comm>`.
- **The brain is AT the Lua 200-local ceiling and the phase script is near it** — this bit three
  times in one session. New state goes in a table; constants go inline.
- **Check 2 is not optional**: a Lua global write is fatal on this build. A `str.replace` without a
  count once injected counters into a second function and produced two global writes.
- `deploy.py` refuses to write when the gate is red and luajit-validates every generated variant —
  it once shipped an unparseable test map because nothing checked the variants.
- Navigation: `play_mission` is evidence-driven — trust its refusals. Escape on the credits screen
  QUITS the game.

## STOP CONDITIONS

Stop when the queue is empty and both repos are tagged and clean; or a tick makes no measurable
progress; or a gate fails twice for the same reason. Do NOT stop merely because an item needs the
user. Before stopping: restore shipping defaults, redeploy, verify by grep, clear the Steam launch
options and restart Steam, state what is proven versus not, and send one `PushNotification`.
