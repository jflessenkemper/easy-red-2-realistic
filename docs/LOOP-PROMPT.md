# Loop prompt — finish the mod unattended

Written for **Opus 5 at LOW reasoning effort**, to run to completion **without the user**. Paste
everything below the line into `/loop`.

Design note: at low effort, do not improvise. Every task has an exact command and an exact
accept/reject test. If a step is ambiguous, do the literal thing, write down what you did, and move
on. Do not redesign the plan. **Do not stop to ask questions — decide, record the decision and its
evidence, and continue.**

---

You are finishing a WW2 soldier-AI mod for **Easy Red 2** and its Claude Code plugin, then releasing
both, **without user input**. Two repos:

- **`/var/home/jflessenkemper/er2-realistic`** — the mod. `Realistic.lua` (per-soldier brain),
  `RealisticEvents.lua` (phase script), `missions/scenarios/showcase.lua` (demo range).
- **`/var/home/jflessenkemper/er2-plugin`** — the `easy-red-2` plugin (MCP server + tools).

Read once, first: this file, then `.llm/kette-measurement.md`, then `docs/verified-api.md` (the API
truth — **it outranks `realistic.md`**), then `er2-plugin/docs/ui-map.md`, then
`docs/donchery-build-sheet.md`. The approved plan is
`/home/jflessenkemper/.claude/plans/plan-out-all-the-buzzing-thompson.md`.

## STATE — done, do not redo

Phases 0–5 complete. Gates: mod `tests/check.sh` **PASS 34 FAIL 0**, plugin **9/9**, offline brain
**18/18**, `dec_map_check` 31 codes, showcase layout gated. Shipping defaults restored
(`DEBUG`/`VERBOSE`/`WATCH`/`TELEMETRY`/`TRACE_LOOP`/`PROBE_*` false, `DBG_SAMPLE` 6,
`FORM.mode="kette"`). Stonne / Test map / Kos run the shipping build; **VirtualScene deliberately
runs the showcase**.

Tooling available — use it, do not rebuild it:
- `movement_audit.py`: `formation(sol,veh,dec)` (per-decision anisotropy, reproduces the banked
  control exactly), `DEC_NAMES`, formation-BY-DECISION table, `compare()` refusing weak claims with
  exit 2 (`--claim METRIC=DELTA`, `--no-strict`), `approach()` (signed direction vs the **local**
  sensed enemy), `near_vehicle()`, `sequences()`, a 0.5 m/frame STATIC deadband.
- `analyse_run.py`: semantic `[EVENTS]` parser keeping the VALUES; `FORM-followLeader` is EXEMPT.
- `watch_audit.py`: parses `[WATCH]` and cross-tabulates decisions against engine ground truth.
- `bench_watch.lua`: logs `isOnCover`/`isMoving`/`isCrawling`/`isCarryingBody`/
  `getSuppressionValue`/`getVelocity`.
- `tests/offline_formation.lua`, `tests/offline_showcase.lua`, `tests/dec_map_check.py`.

## FINDINGS — carry forward, never re-derive

- **Feature 19 was mathematically unreachable.** `FIRE_DANGER_R` was 90, equal to `SENSE_RADIUS`.
  The radioman publishes the enemy centroid as his target; it is within 90 m of him by
  construction; danger-close refuses if any friendly is within 90 m of the target; he is one. Every
  request refused, always. **Fixed to 50**, gated by check 5b. This explains the whole history of
  "no barrage has landed".
- **The Kette is settled.** Calibrated (scatter 19 m, fitted so the control reproduces the live
  17.4 m): blob ratio 0.95, Kette 0.78 — effect **−0.17** against a **0.23** live noise floor, so it
  works but can never be verified in a battle. The old "KETTE_FRONT 36 implies 10.4 m so the ratio
  RISES" arithmetic is **WRONG** (observed = ordered ⊕ scatter in quadrature). Do not restate it.
- **`followLeader`** exists as `FORM.mode="followleader"`, leader-only, guarded, falls back to the
  Kette. Issuing discipline passes offline (leader 2 orders/16 s at an 8 s gap, non-leader 0). Its
  **geometry cannot be measured offline** — squad order, no `moveTo` to capture.
- **Two candidate defects, not yet confirmed:** `CREW-onfoot` −6.85 m/frame (n=49) and `ROUT` −0.91
  (n=14) both move TOWARD the enemy. The log predates the Phase 1 fixes and ROUT ends in
  `findCover`, which may legitimately pick enemy-ward cover. Confirm with three post-fix runs before
  touching either.

---

# WORK QUEUE — in order

## Phase 6a — WHY DON'T THE SHOWCASE SQUADS ENGAGE? (do this first)

The range builds all 13 stations, 0 failures, no Lua errors — but **0–3 of 13 stations demonstrate
their feature**. Invader squads only ever reach no-contact branches (`ROAD-MARCH`, `RALLY-on-MG`)
and never sense their enemy even at 25 m. The French DO spawn (their `DEFEND-hold` was visible
before the census was filtered to invaders), so the two sides are not meeting.

**This is not answerable from decision codes.** Get the brain's own trace:

1. Set `DEBUG = true` and `DBG_SAMPLE = 1` in `Realistic.lua`; deploy to VirtualScene only.
2. Run the showcase (see OPERATING THE GAME below). Wait past the 120 s census warmup.
3. Read the `[REALISTIC]` trace: `python3 ../er2-plugin/tools/analyse_run.py --from-line <mark>`.
   The fields that answer it are **`ne` / `nec` / `ed`** per soldier — what each man actually senses.

Enumerate before fixing. The candidate causes, in order of likelihood:
- the French spawn somewhere other than where the script asked (check their `@(x,z)` in the trace
  against the station's `enemyD` offset);
- `er2.getDefendersFaction()` returns something the German-id squads are not hostile to, so
  `isSameFaction` never reports an enemy (the pinned doctrine override does NOT change faction
  hostility — it only picks a doctrine profile);
- spawn radius/terrain on VirtualScene dropping squads somewhere unexpected.

Then fix, redeploy, and re-run until the census reports **≥10/13 stations OK**. Record the
before/after numbers in `missions/scenarios/showcase.lua`'s header.

**Station 13 (kill feed) needs a human and cannot be verified unattended.** Mark it honestly as
"requires a player" and do NOT let it block the ≥10/13 target — 12 stations is a pass.

## Phase 6b — the isolation scenario suite

Each scenario is a Lua spawn table in `missions/scenarios/T<N>.lua`, loaded like the showcase.
Work T1, T2, T7, then T10, then the rest. **Run on VirtualScene** (DLC-free). Per scenario, every
time: `DBG_SAMPLE = 1`, `DEBUG`/`WATCH`/`TELEMETRY` true, no respawns, **three runs**, compared with
the spread rule, plus the negative control where one exists (T4 France must NOT assault; T6 an Opel
Blitz must NOT qualify as armour). Record a run manifest (flags, mission, commit, scenario id).

**T10 is now winnable** — `FIRE_DANGER_R` is 50, so put the enemy at 70–85 m: inside `SENSE_RADIUS`
90 so the radioman senses ≥3, and outside 50 so the barrage is accepted. Confirm `rounds away: N
shells` in the `[EVENTS]` stream. This is the first barrage in the project's history; report the
number.

Also settle, with three runs each: the **`kette` vs `followLeader` head-to-head**
(`movement_audit.formation(dec=27)` vs `formation(dec=32)`) — keep the winner, revert the loser —
and the **two candidate defects** above.

Mark a feature ✅ **only** with a live measurement and its number. Otherwise say exactly what is and
is not proven.

## Phase 7 — Donchery historical rebuild

1. **Enumerate the catalogue FIRST** in the editor's loadout **search box**, and record every id in
   `docs/donchery-build-sheet.md`: BMW R12 sidecar, Kfz.11/15/18, Kfz.69, assault/rubber boats,
   Panzer I/III/IV, Sd.Kfz. 231, blockhaus/sandbag props, **and a French RIFLE squad** (none is
   confirmed — the mission has only `fr_ATsquad`, `fr_artilleryCrew`, `fr_tankCrew`, and the
   showcase currently stands in with `fr_ATsquad`). **Do not write an order of battle against
   unconfirmed ids.** Record every substitution.
2. **Order of battle as code** — `missions/donchery_oob.lua`, using `spawnSquad_script` /
   `spawnSquadOnVehicle_script` / `spawnVehicle(id, pos, vec3_dir)` / `spawnSoldier`. Script-spawned
   squads spawn once, so **no respawns by construction**. Target **~205 German vs ~135 French** —
   the chosen scale. Do not scale up.
3. **Sourced corrections** from the build sheet: halftracks → BMW R12 sidecars (the battalion had
   **zero** Sd.Kfz. 251); squads are **TEN** men (KStN 131c); do **not** split into l.MG-Trupp +
   Schützentrupp; French are **III/147e RIF** + 1 Cie/11e BM with Hotchkiss teams **in concrete**;
   remove French tanks and Panzer 35(t)/38(t). Leave the **MP38/40 row as-is with its conflict
   note** — two research passes disagree and recording the dispute is the honest move.
4. **The player's lever:** the AI attack fails as it historically did at 16:00; the player gets what
   actually broke the deadlock — direct fire on the blockhouses from behind the railway embankment
   (Panzer IV short 7.5 cm). No artificial buff. Briefing must say it is a *plausible
   reconstruction*, that the assault failed at this hour, and that the crossing succeeded ~20:00
   after 1. Pz.Div. turned the flank from Floing.
5. Props (blockhouses, barricades, embankment positions) are **editor-only, no Lua API**. Placement
   is at the **camera aim point**; `P` copies the cursor position. Do NOT press Escape to leave
   transform mode — it opens the pause menu.
6. **Measure framerate at ~340 brains and report the number.** `TICK` is a pure framerate knob
   (2.0 → 3.0 costs a third, changes no decision). **`SENSE_RADIUS` is NOT a free knob** — it feeds
   the force ratio and rout test, and cost scales with its square.

**Stonne needs the Ardennes DLC**, which needs Steam mode — see the DLC rule below. If it is
blocked, build and validate the OOB offline (`tests/offline_showcase.lua` is the pattern), commit
it, and say plainly it is unverified in-game.

## Phase 8 — release

1. Restore shipping defaults; **verify by grep, not memory** (`sed` misses trailing comments).
2. Deploy to all four missions and verify with `cmp` — **except VirtualScene if it is still hosting
   the showcase**; say which build each mission carries.
3. Both gates green. Regenerate `realistic.md` **from source** (it is stale on cascade order in four
   places, four tunables wrong, nine existing constants called absent).
4. Rewrite `README.md` so **every feature row names the measurement that proves it**, with an
   install section that works for a stranger. State the 2.1.0 caveat.
5. Tag both repos.

---

# OPERATING THE GAME (v2.1.0 — the plugin's coordinates are STALE)

The installed build is **2.1.0**, not the 2.0.9 everything was probed against, and the editor hub UI
changed. Measured working route, 1920×1080 internal:

```
er2_launch {"via_steam": false}          # direct mode; NO DLC entitlement
er2_key    {"key":"space"}               # clear the splash - clicks are SWALLOWED on it while
                                         # every step still reports OK
click 1490,417   # MISSION EDITOR panel (new side-by-side hub layout)
click 1554,78    # first mission row      (rows are TOGGLES - always {"reliable": false})
click 1554,182   # third row / VIRTUALSCENE
click 1554,242   # the mission sub-row
click  960,371   # Edit Mission           (the properties dialog has NO Play)
click   49,1044  # the Sigma drawer
click  380,1044  # Save/Play
click  300,184   # Play
click 1824,1007  # Exit, from the in-battle pause menu, back to the editor
```

A phase script is loaded at battle start, so **exit to the editor and Play again** after every
deploy or the old script keeps running.

**AUDIO — mute Easy Red 2 ONLY.** Mute the sink-input whose `application.name` is `FMOD Ex App`.
Do **NOT** mute `@DEFAULT_SINK@` and do **NOT** loop over every sink-input: doing that muted the
user's other game and a live voice call. A relaunch creates a fresh stream, so re-mute after each
one.

**DLC — never close Steam yourself.** Direct mode gets no DLC entitlement, so DLC maps show an inert
`NEEDS DLCS: <name>` row (the Realistic Test Map needs **Hungary**; Stonne needs **Ardennes**).
Steam mode needs the harness launch options written, which needs Steam closed — and the user runs
other games (Hell Let Loose was live at 380% CPU). So: **use VirtualScene for everything you can.**
If `ps -eo comm=` shows no `steam` and no other game, you may
`python3 er2-plugin/tools/fix_steam_launch_options.py --apply`, launch via Steam, and use DLC maps —
then clear the options again when done. Never restart Steam to fix a stuck launch; bisect with
`er2_launch {"via_steam": false}`.

The scratchpad is cleared between sessions; `er2call.py` may need recreating (see any earlier
session, or drive the MCP tools directly).

---

# HARD RULES — every one cost real time

## The engine
- **`spawnVehicle(id, pos, rot)` — `rot` IS A vec3, NOT DEGREES.** Passing a number throws
  `bad argument #3 to 'spawnVehicleWithCallback' (userdata expected, got number)`, and **the throw
  ESCAPES pcall**, rethrowing through Unity's coroutine machinery and killing the whole phase
  script. Same uncatchable class as `soldier_suppressed`. A guard is not protection — only the right
  type is.
- **`spawnVehicle` returns nothing usable.** To get a handle, spawn then locate with
  `er2.getVehiclesInArea(pos, r, tbl)`.
- **Fill-style APIs must be called WITH a table** (`getAllMembers`, `getSoldiersInArea`,
  `getVehiclesInArea`, `getAllSoldiers`, `getAllObjectives`) — a bare call throws every time.
- **Never subscribe to `soldier_suppressed`** — engine NRE inside its own dispatch, before the Lua
  body. Poll `isSuppressed()` / `getSuppressionValue()`.
- **`.aiParams` as a property throws.** Use `getAiParams()`.
- **Never put UserData in a Lua global** — vec3/Soldier/Vehicle/Squad all throw and killed every
  brain at boot. Primitives only; `global.set(value, key)` is value-first.
- **`findCover` is a VOID COMMAND.** Never pair it with `moveTo` in one tick — they cancel.
- **A `local function` called above its definition** compiles to a nil global read and silently
  kills the brain with no error line. Forward-declare, assign without `local`, don't move the block.
- **`Realistic.lua` is AT the Lua 200-local ceiling.** Group new state in a table, and run
  `luajit -bl Realistic.lua` after **every** edit. `luajit -bl` can pass a file the real loader
  rejects, so check 4e is the real gate.
- **Defenders do not obey `moveTo`** (attackers 122 m median displacement, defenders 7 m). Every
  move branch is attacker-gated.
- **No soldier's destination may depend on another soldier's live position** — follow-the-leader
  stalled six move-decisions to exactly 0.00 m/s.
- **The transport branch keys off `myTransportId`**, remembered only while MOUNTED — a squad that
  never rode anything can never return to a vehicle. Use `spawnSquadOnVehicle_script`.
- **The engine kills the phase loop on a phase advance** (`sleep(1)` never returns). The
  `soldier_died` watchdog covers it, but cadence becomes casualty-driven (~7 s) and stalls in a lull.
- `log()` costs ~1.1 KB plus a stack walk. Pack telemetry.
- **Everything in `docs/verified-api.md` is "verified on 2.0.9, unconfirmed on 2.1.0".** Re-probe
  before relying on anything never actually called — that is exactly how the `spawnVehicle` bug got
  through.

## Designing a test rig
- **Enemies must be inside `SENSE_RADIUS` 90 m** or the squad is never threatened and just marches.
  Stations at 200/150/130 m all failed this way.
- **Every squad needs a LOCAL objective**, or it marches up to 1500 m to the nearest one and
  abandons its station.
- **Put the objective BEYOND the enemy on the same axis**, so marching drives contact. Perpendicular
  means marching away from the thing being demonstrated.
- **Never put an objective at the squad's own position** — inside `ARRIVE_RADIUS` 30 it consolidates
  instead of demonstrating.
- **At most one attracting objective.** `setAttractor` steers base AI map-wide and drags other
  stations' squads across the range.
- **Check a rig's LOADOUTS and its attacker/defender sides before trusting its geometry.**
  VirtualScene's bayonet-only loadouts once produced a useless melee stalemate, and its Germans are
  the DEFENDERS.
- **Give a rig time.** 29 squads arrive over a coroutine and then have to close; judging at 15 s
  reported 2/13 purely because squads were still marching.

## Measurement
- **Never conclude from one battle.** Spread is 0.20–0.23 on the formation ratio and 0.73 on
  `roadmarch_mps`. Only `inv_frozen_pct` proved stable.
- **A battle-wide metric cannot test a squad-level feature** (~18:1 dilution). Filter by decision
  code.
- **Filter mounted soldiers out of every spacing/formation statistic** — they share the vehicle's
  position; this faked a 1.0 m median spacing that was really 32 m.
- **A decision label is not proof of behaviour.** Prefer a direct engine read (`isOnCover()`,
  `isMoving`) over inference.
- **When a whole class of results looks wrong at once, suspect the measurement.** A global enemy
  centroid inverted both ROUT and ASSAULT.
- **CALIBRATE a model against observed data before trusting its verdict.** 13 m vs 19 m scatter
  flipped the Kette conclusion.
- **Beware the test that cannot fail.** Four were found this campaign: `$?` read through a pipe, a
  `sed` anchor that never matched, a substitution whose own `assert` never ran, and an assertion
  looking at the wrong signal. **Negative-test every new gate** — break the thing and confirm the
  gate goes red.

## Workflow
- **Deploy to all four missions and verify with `cmp`** — deploying only to the one under test left
  three stale, twice.
- **Never leave a diagnostic build deployed.** Restore shipping defaults and redeploy before
  stopping, or the user is log-spammed next time they play.
- Commit messages: **never backticks in `-m`**; use a heredoc with `-F -`.
- **Enumerate causes before declaring a fix.** The phase-loop death was misdiagnosed four times.
- **Mark honestly.** ✅ means measured live with a number.
- **Prefer reverting an unproven change to shipping it** — unless it is *proven offline and
  unverifiable live*, which is a different state (see the Kette).
- Sub-agents on **opus**; if one is static at 139 bytes for >5 minutes it died — do the work
  yourself rather than re-spawning.

---

# STOP CONDITIONS — read every iteration

**Stop only when one of these is true.**

1. The queue is empty and both repos are tagged.
2. **An iteration made no measurable progress on its current queue item.** One no-progress tick is a
   signal; do not take a third. A `/loop` here once ran ~20 hours re-attempting one blocked
   measurement.
3. A phase gate fails **twice in a row for the same reason**.

**Do NOT stop for any of these** — they are the mistake that ended the last loop early:
- an individual item needs a human (**station 13 / T13 kill feed**) — mark it "requires a player"
  and carry on with the rest;
- a DLC map is unreachable — use VirtualScene, note what is unverified, continue;
- you would like a decision confirmed — decide it, write down the decision and its evidence, and
  continue. **You are running unattended; there is nobody to ask.**

Before stopping: restore shipping defaults, redeploy, verify `cmp`, state which build each mission
carries, and say plainly what is proven, what is not, and why. Send one `PushNotification` line with
the outcome.
