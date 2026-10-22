# Bugbot review rules — Easy Red 2 "Realistic" mod

Context: two Lua scripts run inside Easy Red 2 (MoonSharp/LuaJIT-style Lua 5.1 surface).
`Realistic.lua` is a per-soldier brain coroutine; `RealisticEvents.lua` is the mission phase script.
A runtime error does NOT show up as an error in-game: the soldier silently stops thinking.
Treat every finding below as **blocking** unless marked advisory.

## Hard limits
1. **200 main-chunk locals.** Lua refuses to compile a function with more than 200 active locals.
   `RealisticEvents.lua` has headroom 3, `Realistic.lua` ~43 (`python3 tests/local_count.py`).
   Flag any PR that adds a top-level `local` to `RealisticEvents.lua` without removing one or
   grouping into an existing table. Prefer fields on existing tables (`CLS`, `DEC`, `RX`, `SHOWCASE`).
2. **No UserData in Lua globals.** A vec3/Soldier/Vehicle/Squad stored in a Lua global (or via
   `global.set`) killed every brain at boot. Only primitives under string keys.
3. **No forward references to `local function`s.** Calling one before its definition compiles to a
   global read (nil at runtime). Use a forward `local name` declaration.
4. Fill-style APIs (`getAllMembers`, `getSoldiersInArea`, `getVehiclesInArea`) must be passed a
   table. `.aiParams` property access, `soldier_suppressed` callbacks and `uid % N` are banned.

## Shipping flags
5. `DEBUG`, `VERBOSE`, `TELEMETRY`, `WATCH`, `TRACE_LOOP`, `PROBE_APIS`, `PROBE_GLOBALS`,
   `SHOWCASE_HUD` must be `false` on master; `DBG_SAMPLE` must be `6`. Diagnostic flips belong in
   `tools/deploy.py` variants for the test map only, never in the committed source.

## Honesty of claims
6. **Never accept "proven" without in-game evidence.** Any change to README/CHANGELOG/
   `docs/RELEASE-READINESS.md`/`data/features.json` that upgrades a feature to proven must cite a
   game log measurement and, under the 2026-10-23 rule, a 30 fps clip (≤960 px wide) plus an
   `tools/eval_telemetry.py` PASS. Offline tests, lint, or mutation scores prove internal
   consistency only. `status` above `baseline_status` without both is a bug.
7. Behaviour changes go on a `feature/*` branch, not master, and are labelled UNPROVEN.

## Process
8. `tests/review.sh` must stay green (4l deployed-drift is expected red offline; CI skips it).
9. Generator output changes must update `tests/golden/` deliberately (`tests/golden_check.py --update`)
   with the diff explained in the PR.
10. Advisory: luacheck shadowing/unused warnings, ruff style, stylua formatting.
