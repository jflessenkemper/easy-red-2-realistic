# Loop prompt — finish the mod and make it releasable

Copy everything below the line into `/loop`. It is written to be self-contained: a fresh session
with no memory of this one should be able to act on it.

---

You are finishing a WW2 soldier-AI mod for **Easy Red 2 v2.0.9** and its Claude Code plugin, then
releasing both. Two repos, both public and pushed:

- **`/var/home/jflessenkemper/er2-realistic`** — the mod. `Realistic.lua` (per-soldier brain) and
  `RealisticEvents.lua` (mission phase script, master client only).
- **`/var/home/jflessenkemper/er2-plugin`** — the `easy-red-2` Claude plugin (MCP server + tools).

**Read these first, in this order. They are the accumulated findings and will save you hours:**
1. `er2-realistic/docs/test-scenarios.md` — thirteen scenarios, one per feature, each engineered to
   force its branch. **This is your work queue.**
2. `er2-plugin/docs/ui-map.md` — every UI coordinate and every failure mode already diagnosed.
3. `er2-realistic/README.md` — the feature table with what is and is not proven.
4. `er2-realistic/.llm/squad-formations.md` and `.llm/donchery-oob.md` — sourced 1940 doctrine.

## Current state

Gates: mod **29/29** (`tests/check.sh`), plugin **9/9**, offline brain 13/13, offline phase 3/3.
Feature table: **31 ✅, 1 🔧**. Plugin tagged to v1.4.0. All four missions deployed and
byte-identical to source. Zero Lua errors in every recent battle.

## Goal

Everything verified or honestly marked, both repos tagged, and a stranger able to install and use
the mod from the README alone.

## Work queue, in priority order

**1. Run the T1–T12 scenario suite.** Most run on **VirtualScene, which needs no DLC**, so use
`er2_launch {"via_steam": false}` and avoid Steam entirely. Build each in the Mission Editor per
the doc's forces and geometry.

**2. T1 carries the one open prediction.** Feature 9's `Schützenkette` is implemented but never
measured. Prediction: the along/across ratio **drops below 1** (a line is wide across the axis and
thin along it), against a measured blob band of **1.19–1.45**. If it fires and the ratio inverts,
mark feature 9 ✅ with the numbers. **If it does not, revert it** — two previous formation attempts
were already rejected on evidence and a third unproven one should not ship. The rejection notes in
`Realistic.lua` above `boundTeam()` explain exactly why each failed; read them before touching
formation code.

**3. T10 is the only route to a barrage actually landing.** No fire mission has ever been accepted,
because `FIRE_DANGER_R` is 90 m and in a close fight a friendly is always inside it — all six
observed responses were correct `REFUSED danger close`. Put the enemy at **130 m** so the target
clears 90 m from every friendly. On success, update feature 19's wording.

**4. Then release.** Re-check both gates, restore shipping defaults, redeploy to all four missions
and verify with `cmp`, tag both repos, and make sure the README install section works for someone
who has never seen the project.

## Things that need the user, not you

Ask; do not burn ticks on them.

- **Playing as a soldier (T13).** Synthetic clicks never reached the deploy control in any attempt.
- **The historical Donchery rebuild.** The `.mer2` is a .NET BinaryFormatter blob and editor
  world-object picking ignores synthetic clicks. `docs/donchery-build-sheet.md` is the shopping
  list; the mission is backed up as `.mer2.bak-preedit`. Offer: they drive the editor, you read the
  list and check results in-game.
- **Clearing the harness launch options** so they can play normally. Requires closing Steam:
  `python3 er2-plugin/tools/fix_steam_launch_options.py --clear --apply`

## NEVER list — every one of these cost real time

**Measurement**
- **Never conclude from one battle.** Run-to-run spread is **0.23** on the formation ratio and
  **0.73** on `roadmarch_mps`. `movement_audit.py logA logB logC` prints the spread and marks
  anything smaller as not-evidence. The only metric that proved stable is `inv_frozen_pct`.
- **A decision label is not proof of behaviour, and absence of log lines is not absence of
  behaviour.** Trace output is sampled (`DBG_SAMPLE`) and throttled. Verify by displacement.
- **Filter mounted soldiers out of any spacing, density or formation statistic.** Men in a vehicle
  all report the vehicle's position, so a truckload reads as nine men on one spot. This produced a
  phantom 1.0 m median spacing that was really 32 m.
- **When a whole class of results looks wrong at once, suspect the measurement first.**

**The engine**
- `getClassName()` has **no** crew/tank/driver/pilot classes. Only: rifleman, squad leader,
  radioman, medic, engineer, support gunner, marksman, at unit. Identify crew by what they were
  **riding**.
- `distance()` is an **engine global** and measures in **3D** (probe: `distance((0,0,0),(0,4,3))`
  returns 5). Its ~19 call sites are interop hops; `vec3` component reads are too, so swapping it
  for inline maths is not obviously a win.
- `log()` costs ~1.1 KB plus a stack walk. **Pack telemetry**; never one call per soldier per frame.
- Fill-style APIs (`getAllSoldiers`, `getAllMembers`, `getVehiclesInArea`) take a table and must
  never be called bare — a bare call throws on every invocation (279 errors in one battle).
- **`Realistic.lua` is at the Lua 200-local ceiling.** Adding two top-level locals broke every
  brain with *"main function has more than 200 local variables"*. Group new state in a table.
  Note `luajit -bl` **passes** while the real loader rejects it — check 4e is the gate that catches
  this.
- The engine **kills the phase script's loop** when the mission advances a phase: traced to
  `sleep(1)` never returning. A watchdog on `soldier_died` keeps the periodic work alive, so its
  cadence becomes casualty-driven (~7 s) and would stall in a lull.
- **No soldier's destination may depend on another soldier's live position.** Follow-the-leader
  stalled six move-decisions to exactly 0.00 m/s, because one stationary man froze everyone behind
  him. Derive from the man's own roster index.
- **Doctrinal intervals are all sub-σ.** `Schützenkette` interval is 4–5 m against ~13 m of pathing
  scatter. Formation must be encoded as **axis and extent**, never interval.

**Workflow**
- **`DBG_SAMPLE` ships at 6.** For a 10-man scenario set it to **1** or you will trace one man.
- **Never restart Steam to fix a stuck launch — it makes it worse.** Three restarts left it unable
  to launch anything. The one-call bisect is `er2_launch {"via_steam": false}`: if direct mode comes
  up, the harness is fine and the fault is Steam's. Direct mode gets **no DLC entitlement**, so DLC
  maps show an inert `Needs DLCs: <name>` row.
- **Deploy to all four missions and verify with `cmp`.** Deploying only to the one under test left
  three stale, twice.
- **Restore shipping defaults before every commit** (`DEBUG`, `VERBOSE`, `WATCH`, `TELEMETRY`,
  `TRACE_LOOP`, `PROBE_*` all false; `DBG_SAMPLE` 6). Check 6 gates this.
- Mission-list rows are **toggles** — use `{"reliable": false}` or a double-click collapses them.
- The scratchpad gets cleared; `er2call.py` may need recreating.
- Commit messages: never backticks in `-m`, use a heredoc with `-F -`.

## Standing rules

- **Enumerate causes before declaring a fix.** The phase-loop death was misdiagnosed **four**
  times. Do not write a second fix until the first has *reported* something.
- **Mark honestly.** ✅ means measured in a live battle. If it is not, say exactly what is and is
  not proven — several features were ✅ on offline evidence alone and had to be corrected.
- **Prefer reverting an unproven change to shipping it.** Three formation attempts, two reverted on
  evidence, and that was the right call each time.
- Delegate research to sub-agents on **opus** and require sources; the doctrine research corrected
  a central premise and killed two invented German terms.

Stop when the queue is empty and both repos are tagged, or when the only remaining items are the
ones that need the user — then say so plainly rather than looping on them.
