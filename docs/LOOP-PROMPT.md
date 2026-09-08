# Loop prompt — verify the AI, rebuild Donchery, release

Written for **Opus 5 at LOW reasoning effort**. Everything below the line is self-contained: a
fresh session with no memory of this one can act on it. Paste it into `/loop`.

Design note: at low effort, do not improvise. Every task below has an exact command and an exact
accept/reject test. If a step is ambiguous, do the literal thing, write down what you did, and move
on. Do not redesign the plan.

---

You are finishing a WW2 soldier-AI mod for **Easy Red 2 v2.0.9** and its Claude Code plugin, then
releasing both. Two repos:

- **`/var/home/jflessenkemper/er2-realistic`** — the mod. `Realistic.lua` (per-soldier brain),
  `RealisticEvents.lua` (mission phase script, master client only).
- **`/var/home/jflessenkemper/er2-plugin`** — the `easy-red-2` Claude plugin (MCP server + tools).

**You are running at LOW reasoning effort. Follow the queue in order. Do not re-derive facts that
are already written down.** The approved plan is at
`/home/jflessenkemper/.claude/plans/plan-out-all-the-buzzing-thompson.md` — read it once, first. It
is the contract. Do not change its decisions.

## Read these before touching anything (in this order)

1. The plan file above.
2. `er2-realistic/.llm/kette-measurement.md` — **authoritative** where it conflicts with
   `docs/test-scenarios.md` (it is newer and measured).
3. `er2-realistic/docs/verified-api.md` — the API truth. It **outranks** `realistic.md`.
4. `er2-plugin/docs/ui-map.md` — every editor coordinate and failure mode already diagnosed.
5. `er2-realistic/docs/donchery-build-sheet.md` — the sourced historical shopping list.

## Facts already established — do not re-investigate these

- **The full script-spawn API exists** (`docs/verified-api.md:117-123`): `spawnSoldier(pos, faction,
  rank, loadout)`, `spawnSquad_script(pos, radius, faction, squadId, scriptFile)` (squad **with
  brain**), `spawnSquadOnVehicle_script(...)`, `spawnVehicle(vehicle_id, pos, rot)`,
  `spawnMissionObjective(pos, radius, text, icon, attractor)`. The phase script already has a
  `TEST_SPAWNS` hook that uses it (`RealisticEvents.lua:287-315`).
- **Direct behavioural reads exist and are unused** (`docs/verified-api.md:300-369`): `isOnCover()`,
  `isMoving`, `isRunning`, `isCrawling`, `getVelocity()`, `getSuppressionValue()`, `setPose`,
  `isCarryingBody`, `getCarriedBody`, `getNearestInjured`, and squad orders `followLeader`,
  `attackFromPoint`, `coverArea`, `charge`, `holdFire`, `fireAtWill`, `setClosestObjective`.
- **`getSquad()` works from inside a brain** — 315/371 soldiers resolved real rosters. Poll
  `isSquadReady()` first; never treat a nil squad as permanent.
- **VirtualScene is a dead test rig.** Its Germans are **defenders** — measured 504/504
  `DEFEND-hold`, `ed=-1`. Every attacker-side branch is unreachable there. **Use Stonne.**
- **All 13 scenarios in `docs/test-scenarios.md` are paper.** None has ever been run.
- **`.mer2` mission format** carries `placed_objects` + `prop_id`/`position`/`rotation`/`scale`
  (props ARE placeable, editor-only — no Lua API), plus `invadersFaction`, `invadersBatalion_num`,
  `customSquads`, `custom_squad_id`, `respawn_delay`, `ai_script_file`.
- **Squad/vehicle ids are NOT recoverable from game assets.** The editor's loadout **search box** is
  the only authority. Greyed-out entries are DLC-locked.
- Current state: mod gate 29/29, plugin gate 9/9, feature table 31 ✅ / 1 🔧, tags `v1.0.0` `v1.1.0`.

---

# WORK QUEUE — do these in order

## Phase 0 — safety net (do this first, once)

```bash
cd /var/home/jflessenkemper/er2-realistic && git add -A && git commit -F - <<'EOF'
Bank the Kette measurement note before the verification campaign

It was untracked and it supersedes docs/test-scenarios.md.
EOF
```

Then confirm the baseline is green:

```bash
cd /var/home/jflessenkemper/er2-realistic && which luajit && bash tests/check.sh 2>&1 | tail -3
```

**Accept:** `luajit` found AND `PASS 29 FAIL 0`. **If `luajit` is missing, stop and tell the user** —
without it, 5 checks silently skip and the score is meaningless.

## Phase 1 — fix the audited defects (no measurement until this is done)

Do all of these, then re-run the gate once.

1. **`huntArmour()` must not issue orders outside the cascade.** It is called unconditionally at
   `Realistic.lua:1193`, before any branch, and internally calls `takeCover` (`:877`). Make the
   pre-cascade call **acquire-and-label only, no side effects**; move the `forceTarget` /
   `alertFor` / `say` / `takeCover` calls into branch 4 (`:1282`). This currently gives mounted AT
   men orders that branch 2 exists to prevent, and makes a shaken AT man's cover order countermand
   his own ROUT `moveTo`.
2. **Guard the two bare `global.get` calls** at `Realistic.lua:372-373` with `safeGet`, like every
   other engine call in the file.
3. **Log `amInvader` resolution failure.** `Realistic.lua:368-370` fails safe to *defender*, which
   means no move orders at all. Keep the fail-safe; add a one-shot log line so it is not silent.
4. **Delete the dead `AT-hold-cover` label** (`Realistic.lua:459`) — `huntArmour` never returns it.
5. **Fix the doc pointer.** Both scripts cite `.llm/api/verified-api.md`, which is an **empty
   directory**. The file is `docs/verified-api.md`. (`Realistic.lua:4`, `RealisticEvents.lua:13`,
   `:372-374`.)
6. **Fix the stale `[TELEM]` header comment.** `RealisticEvents.lua:1116-1117` documents 4 fields;
   the emitter at `:1180-1181` writes **9**: `uid,x,y,z,flag,squad,inVeh,dec,ri`.
7. **Add three checks to `tests/check.sh`:**
   - `DBG_SAMPLE` must be `6` in `Realistic.lua`. It is **not gated today** even though
     `LOOP-PROMPT` used to claim it was, so a scenario build ships green with it at 1.
   - Assert `luajit` is present instead of silently skipping 5 checks while printing `FAIL 0`.
   - The `DEC` code→label map must agree across `Realistic.lua:455-467` (authoritative),
     `er2-plugin/tools/movement_audit.py` and `er2-plugin/tools/battle_map.py`. Today they name
     31 / 19 / 26 codes respectively and nothing cross-checks them.

**Gate:** `bash tests/check.sh` → `FAIL 0`, count now 32. If adding brain locals breaks with *"main
function has more than 200 local variables"*, group state in a table — `luajit -bl` **passes** where
the real loader rejects it, so check 4e is the only gate that catches it.

## Phase 2 — make "any nation, any squad" true (Part 5 of the plan)

1. **`DOCTRINE_DEFAULT` silently removes two features.** `Realistic.lua:174` sets `aggression 0.45`
   against `ASSAULT_MIN_AGGR 0.50` (`:74`) and `mgCentric false`. So an unrecognised or modded
   nation can **never** `ASSAULT` and **never** `RALLY-on-MG`. Raise `aggression` to at least 0.50
   and set `mgCentric true` so every branch stays reachable.
2. **The MG gunner is found by an English substring** — `isMG = myClass:find("support")`
   (`Realistic.lua:320`). He is the **anchor** of the formation branch (`RALLY-on-MG` forms on
   `mgPos`), so a custom or non-English squad silently stops forming up. Broaden the token list
   (`support`, `mg`, `lmg`, `machine`, `gunner`, `mitrailleur`, `pulemet`), corroborate with
   `isAmmoBoxCarrier()`, and add a `global` override pair mirroring the existing
   `realistic_nation_invaders` / `_defenders` hook (`:372-373`) so a mission author can name their
   own gunner class. Same for `isMortar` (`:321`).
3. Document the fallback's exact behaviour in `README.md` — what an unknown nation gets, precisely.

**Gate:** offline brain scenarios still pass; add one scenario asserting an unknown faction string
reaches `ASSAULT` and one asserting a custom gunner class name is detected as MG.

## Phase 3 — build the measurement tools (before any live run)

Extend existing tools; do not start new ones.

1. **`er2-plugin/tools/movement_audit.py` — add per-decision + per-squad filtering with `n`
   reported.** `headline()` pools every moving dismounted invader, but `RALLY-on-MG` is **5.48%** of
   samples (1142/20842), diluted ~18:1 — a battle-wide ratio **can never** test a squad feature.
   The entry tuple from `load()` is `(x, z, flag, squad, inVeh, dec, y)`; `dec` is index 5.
   **Calibrate against the free banked control first:** `.llm/runs/base1.telem` and `base2.telem`
   are a deliberate pre-Kette two-run pair. Expected, already computed — do not re-derive:
   base2 `RALLY-on-MG` ratio **1.12** (89 squad-frames, 447 samples), base2 `ROAD-MARCH` **1.21**,
   base1 `RALLY-on-MG` **0 frames**, base1 `ROAD-MARCH` **0.74**. If your new code reproduces those,
   it is correct.
2. **Make `compare()` refuse a claim inside the spread** — non-zero exit, not the current advisory
   sentence. Carry `n` through. Recorded spread: **0.20–0.23** on the formation ratio, **0.73** on
   `roadmarch_mps`. Only `inv_frozen_pct` has ever proven stable.
3. **Add reference-point geometry** — displacement toward/away from an enemy centroid, and
   soldier-to-named-vehicle joins (`V` lines carry vehicle position + name). Six scenario criteria
   need this and none of it exists.
4. **Add sequence / ratio / uniqueness assertions** — `DRAG-approach→pickup→to-cover`, the
   `BOUND-move : BOUND-overwatch` ≈1:1 alternation on the 8 s `BOUND_PERIOD`, "exactly one man
   elected per casualty".
5. **Add a semantic `[EVENTS]` parser.** `analyse_run.py:145-157` reduces those lines to *shapes* by
   replacing digits with `N`, destroying the numbers — and T9/T10/T12 are all judged phase-side
   (`bail-out: N crew left vehicle X`, fire-mission accept/refuse, `obj1 ... held=true ... CAPTURED`,
   `rounds away: N shells`).
6. **Extend `bench_watch.lua`** (repo root; read-only observer, issues no orders, safe alongside
   anything) to log `isOnCover()`, `isMoving`, `getVelocity()`, `getSuppressionValue()`,
   `isCarryingBody`, and roster index — then **write the parser it has never had**. This is the
   primary evidence from now on, and it keeps instrumentation out of the brain.

**Gate:** `python3 tools/movement_audit.py ../er2-realistic/.llm/runs/base1.telem
../er2-realistic/.llm/runs/base2.telem` reproduces the four numbers in item 1.

## Phase 4 — settle formation OFFLINE (cheap, deterministic, do it before any battle)

`.llm/kette-measurement.md:31-37` argues the Kette's prediction may be **geometrically
unachievable**: `KETTE_FRONT = 36` implies σ_across ≈ 10.4 m for a *perfect* line, **narrower** than
the 17.4 m measured — and narrowing across *raises* along/across. So a live T1 can fail with working
code or pass with broken code. Do not book a live run to answer this.

1. **Extend `tests/offline_brain.lua`** to drive **N synthetic squads** and report the along/across
   **distribution** under an injectable ~13 m pathing-scatter model. Today it drives one brain per
   scenario, `moveTo` only sets a boolean (`:54`), there is no scatter model, and stubbed
   `distance()` is **2D** while the engine's is **3D** — fix those two infidelities too
   (`getTerrainHeight` also always returns 0).
2. **Decide from the distribution, and write the number down:**
   - If the Kette's effect is inside the noise band → **revert the Kette** and say so in the README
     with the number. Two previous formation attempts were correctly reverted on evidence; a third
     unproven one must not ship.
   - Then try **leader-only `Squad.followLeader` / `attackFromPoint`**, measured the same way
     offline first. Issue it **only** when `isSquadLeader()` is true, or every man spams the same
     order every tick. This is the engine's own formation system and it structurally cannot cause
     the cascade stall that killed attempt 1.

**Hard rule:** formation must be encoded as **axis and extent, never interval**. Every doctrinal
interval is sub-σ against ~13 m scatter (Schützenkette 4–5 m is 0.31–0.38 σ), so no interval-based
formation is measurable, ever.

## Phase 5 — the SHOWCASE scenario (the user watches every feature, live)

This is a **playable demonstration**, not a log rig. The user must be able to spawn in, move between
stations, and *see* every feature fire, with an on-screen readout naming what each soldier is doing.
Build it as `missions/scenarios/showcase.lua`, spawned entirely from Lua.

**The hard design constraint:** the cascade is strictly first-match, so features pre-empt each other
— you cannot show them all in one firefight. `PINNED` alone will swallow assault, bounding and
formation. So the showcase is a **demonstration range: spatially separated stations**, each
engineered to force exactly one branch.

**Station spacing must exceed `SENSE_RADIUS` 90 m — use ≥ 250 m between stations** so no station's
enemies leak into another's force ratio. Lay them out on a grid with `P`-captured coordinates on open
Stonne terrain.

### Stations (one per feature, conditions taken from `docs/test-scenarios.md`)

| # | Station | Setup | What the user sees |
|---|---|---|---|
| 1 | Approach march + formation | 1 Gruppe (10 men), **zero** enemies, objective 400 m; gunner 40 m off a flank | `ROAD-MARCH`, `RALLY-on-MG`, lateral stagger |
| 2 | Pinned + fight from cover | 1 Gruppe vs 3 emplaced MG teams at 40 m, open ground | `PINNED` → `FIGHT-from-cover` as suppression lifts |
| 3 | Rout | **4** Germans vs **20** French at 60 m | `ROUT`, falling back ~40 m, then cover |
| 4 | Close assault | 1 Gruppe vs **exactly 2** French at 25 m | `ASSAULT`, closing to contact |
| 5 | AT hunts armour | German AT Gruppe vs 2 tanks at 100 m closing, **no** enemy infantry | `AT-stalk` → `AT-hunt` inside 60 m |
| 6 | Advance behind armour | 1 Gruppe + 1 halftrack, enemy MG at 200 m | line abreast 6 m behind the hull |
| 7 | Bounding overwatch | 1 Gruppe vs **exactly one** rifleman at 150 m | half move, half watch, swapping every 8 s |
| 8 | Medic + wounded drag | Gruppe + medic + a casualty, marksman at **120 m** | `MEDIC-sortie`, `DRAG-approach`→`pickup`→`to-cover` |
| 9 | Crew bail-out | 1 Panzer II + French 25 mm AT gun at 300 m, clear LOS | crew leave the wreck, then `CREW-onfoot` away from the enemy |
| 10 | Fire mission | Gruppe with radioman, ≥3 French at **130 m**, squad blocked so it stalls | `RADIO-fire-mission`, then a barrage that **lands** |
| 11 | Transport reuse | Gruppe starting **mounted**, no enemies, objective > 120 m | dismount, `RETURN`/`REBOARD-transport` |
| 12 | Consolidate + objective flow | 20 Germans vs 8 French, **two** objectives 250 m apart | `CONSOLIDATE`, capture, then flow to objective 2 |
| 13 | Kill feed + callouts | **the player's own squad** + one marksman at 100 m | on-screen kill feed, one squadmate callout per death |

Station 10 is the only place a barrage has ever been able to land — 130 m clears `FIRE_DANGER_R` 90 m
from every friendly. Station 13 is the one that needs the user in a squad.

### The on-screen readout — this is what makes it observable

The brain already publishes its decision as an integer to `global "D"..uid` on change
(`Realistic.lua:1499-1502`), and the `DEC` map is at `:455-467`. So the phase script can read it back
with **no extra brain cost**. Add a spectator HUD to `RealisticEvents.lua`, behind a
`SHOWCASE_HUD = false` flag (must ship `false`; add it to check 6's flag list):

- every ~1 s, for soldiers within ~120 m of the player, print `<role> — <DECISION>` using the
  existing `announce`/`print` path the kill feed already uses (`RealisticEvents.lua:69`)
- name the station the player is standing in, so the user knows what they are meant to be watching
- keep it to a few lines per refresh — this is a HUD, not a log; `log()` costs ~1.1 KB per call

Label each station with `spawnMissionObjective(pos, radius, text, icon, attractor)` carrying the
station name as its `text`. **Pass `attractor = false` for every label except the real objectives at
stations 1 and 12** — an attractor changes AI behaviour and would wreck the neighbouring stations.

### Accept

The user can walk the range and see all 13 labels appear, with no cross-contamination between
stations (verify: no soldier at one station ever senses an enemy from another — check `ne` in the
trace). Then **ask the user to try it** and take their feedback before moving on.

## Phase 6 — the isolation scenario suite, on Stonne

Each scenario is now a **Lua spawn table**, not editor work. Put them in
`er2-realistic/missions/scenarios/T<N>.lua`, loaded through the phase script's `TEST_SPAWNS` hook.
Disable the mission's existing editor spawners (spawn type **`Disabled`** — proven to work; the
panel opens by placing a spawner with the tool at `1604,1033` then clicking its base at `952,533`,
prev/next arrows at `851,212` / `1223,212`) so they cannot double up.

Per scenario, every time:
- `DBG_SAMPLE = 1` (it ships at 6; at 6 a ten-man scenario traces one man)
- `DEBUG`, `WATCH`, `TELEMETRY` true
- no respawns
- **three runs**, compared with the spread rule
- run the negative control where the design has one: **T4** France must NOT assault (aggression 0.40
  < 0.50); **T6** an Opel Blitz must NOT qualify as armour
- record a **run manifest** (flags, mission, commit, scenario id) — nothing currently ties a log to
  the configuration that produced it

Work T1→T12 in the doc's recommended order: **T1, T2, T7, then T10, then the rest.** T10 is the only
route to a barrage actually landing — put the enemy at **130 m** so the target clears `FIRE_DANGER_R`
90 m from every friendly. All six fire-mission responses so far were correct `REFUSED danger close`.

Mark each feature ✅ **only** with a live measurement and its number. Otherwise say exactly what is
and is not proven.

## Phase 7 — Donchery historical rebuild

1. **Enumerate the catalogue FIRST.** Open the editor's loadout search box and confirm which of
   these actually exist: BMW R12 sidecar, Kfz.11/15/18, Kfz.69, assault/rubber boats, Panzer I / III
   / IV, Sd.Kfz. 231, blockhaus/sandbag props. **Do not write an order of battle against items you
   have not confirmed.** Record every substitution in `docs/donchery-build-sheet.md`.
2. **Write the order of battle as code** — `missions/donchery_oob.lua`, consumed by `TEST_SPAWNS`,
   using `spawnSquad_script` / `spawnSquadOnVehicle_script` / `spawnVehicle(id, pos, rot)` /
   `spawnSoldier(pos, faction, rank, loadout)`. Script-spawned squads spawn once, so **no respawns
   by construction**. Capture positions with the editor's **`P` = copy cursor position** binding.
   Target **~205 German vs ~135 French** — the researched scale, already chosen. Do not scale up.
3. **Apply the sourced corrections** from `docs/donchery-build-sheet.md`: halftracks → BMW R12
   sidecars (the battalion had **zero** Sd.Kfz. 251); squads are **TEN** men (KStN 131c, 10 Oct
   1939); do **not** split the squad into l.MG-Trupp + Schützentrupp (abolished by the same order);
   French are **III/147e RIF** + 1 Cie/11e BM with Hotchkiss teams **in concrete**; remove French
   tanks and Panzer 35(t)/38(t). Leave the **MP38/40 row as it is and keep the conflict note** — two
   research passes disagree and the honest move is to record the dispute.
4. **Props stay editor work** (no Lua API). Placement is at the **camera aim point**, no world
   picking. Scope: French blockhouses, south-bank barricades, the railway embankment firing
   positions. In the editor, do **NOT** press Escape to leave transform mode — it opens the pause
   menu.
5. **The player's lever** — the AI attack fails as it historically did at 16:00; the player gets
   what actually broke the deadlock: direct fire on the blockhouses from behind the railway
   embankment (Panzer IV short 7.5 cm). No artificial buff. Briefing must say it is a *plausible
   reconstruction*, that the assault failed at this hour, and that the crossing succeeded ~20:00
   after 1. Pz.Div. turned the flank from Floing.
6. **Measure framerate at ~340 brains and report the number.** Tune `TICK` if needed — it is a pure
   framerate knob (2.0 → 3.0 costs a third, **changes no decision**). **`SENSE_RADIUS` is NOT a free
   knob** — it feeds the force ratio and rout test, and cost scales with its square.

## Phase 8 — release

1. Restore shipping defaults: `DEBUG`, `VERBOSE`, `WATCH`, `TELEMETRY`, `TRACE_LOOP`, `PROBE_*`
   all `false`; `DBG_SAMPLE` `6`. **Verify by grep, not by memory** — `sed` misses lines with
   trailing comments.
2. Deploy to **all four** missions and verify with `cmp`:
   ```bash
   B="$HOME/.config/unity3d/Corvostudio/Easy Red 2/mission_editor"
   cd /var/home/jflessenkemper/er2-realistic
   for m in ME_Stonne_38n85202 "ME_Realistic Test map_o6526q70" ME_VirtualScene_66v1d2nn ME_Kos_y1pfi3zz; do
     D="$B/$m/scripts"; [ -d "$D/AI" ] && cp -f Realistic.lua "$D/AI/Realistic.lua" && cp -f RealisticEvents.lua "$D/mission/phase_0.lua"
   done
   ok=0; for m in ME_Stonne_38n85202 "ME_Realistic Test map_o6526q70" ME_VirtualScene_66v1d2nn ME_Kos_y1pfi3zz; do
     D="$B/$m/scripts"; cmp -s Realistic.lua "$D/AI/Realistic.lua" && cmp -s RealisticEvents.lua "$D/mission/phase_0.lua" && ok=$((ok+1)); done
   echo "deployed identical: $ok/4"
   ```
3. Both gates green. Regenerate `realistic.md` **from source** — it is stale on cascade order in
   four places, lists four tunables at wrong values, and calls nine existing constants absent.
4. Rewrite `README.md` so **every feature row names the measurement that proves it**, with an
   install section that works for someone who has never seen the project.
5. Tag both repos.

---

# HARD RULES — every one of these cost real time

## Measurement
- **Never conclude from one battle.** Spread is **0.20–0.23** on the formation ratio and **0.73** on
  `roadmarch_mps`. Only `inv_frozen_pct` proved stable. `movement_audit.py logA logB logC` prints
  the spread; anything smaller is **not evidence**.
- **A decision label is not proof of behaviour, and absence of log lines is not absence of
  behaviour** — output is sampled (`DBG_SAMPLE`) and throttled (`DBG_GAP` 8 s). Prefer a direct
  engine read (`isOnCover()`, `isMoving`) over inference.
- **Filter mounted soldiers out of every spacing/formation statistic.** Men in a vehicle all report
  the vehicle's position; this faked a **1.0 m** median spacing that was really **32 m**, and 69% of
  invader samples were riders.
- **A battle-wide metric cannot test a squad-level feature** (18:1 dilution). Filter by decision code.
- **When a whole class of results looks wrong at once, suspect the measurement first.**
- **Check a test rig's LOADOUTS and its attacker/defender sides before trusting its geometry.**
  VirtualScene's bayonet-only loadouts produced a useless melee stalemate, and its Germans are
  defenders.

## Engine
- `getClassName()` has **no** crew/tank/driver/pilot classes. The full list is: rifleman, squad
  leader, radioman, medic, engineer, support gunner, marksman, at unit. Identify crew by what they
  were **riding**.
- **`findCover` is a VOID COMMAND, not a query.** Never pair `findCover` and `moveTo` in one tick —
  they cancel.
- **Fill-style APIs must be called WITH a table** (`getAllMembers`, `getSoldiersInArea`,
  `getVehiclesInArea`, `getAllSoldiers`, `getAllObjectives`). A bare call throws every time — 279
  errors in one battle.
- **Never subscribe to `soldier_suppressed`** — the engine NREs inside its own dispatch, before the
  Lua body, so `pcall` cannot help. Poll `isSuppressed()` / `getSuppressionValue()`.
- **`.aiParams` as a property throws** (20,689 errors in one battle). Use `getAiParams()`.
- **Never put UserData in a Lua global** — vec3/Soldier/Vehicle/Squad all throw and killed every
  brain at boot. Primitives only; `global.set(value, key)` is value-first.
- **A `local function` called above its definition** compiles to a nil global read and silently kills
  the brain with no error line. Forward-declare, then assign without `local`; do not move the block.
- **`Realistic.lua` is at the Lua 200-local ceiling.** Group new state in a table. `luajit -bl`
  passes where the real loader rejects it.
- **Defenders do not obey `moveTo`** (attackers 122 m median displacement, defenders 7 m). Every
  move branch is attacker-gated. Issuing it anyway "reads as a working feature in the log", which is
  worse than useless.
- **No soldier's destination may depend on another soldier's live position.** Follow-the-leader
  stalled six move-decisions to exactly 0.00 m/s because one stationary man froze the whole file.
- **The engine kills the phase loop on a phase advance** — `sleep(1)` never returns. A
  `soldier_died` watchdog covers it, but the cadence becomes casualty-driven (~7 s) and stalls in a
  lull, which degrades every Δt-based metric.
- `log()` costs ~1.1 KB plus a stack walk. Pack telemetry; never one call per soldier per frame.
- `distance()` is an **engine global measuring in 3D**; the Python tools compute 2D on `(x, z)`.

## Workflow
- **Never restart Steam to fix a stuck launch — it makes it worse.** Three restarts left it unable
  to launch anything. Bisect with `er2_launch {"via_steam": false}`; direct mode gets **no DLC
  entitlement**, so DLC maps show an inert `Needs DLCs:` row.
- **Deploy to all four missions and verify with `cmp`** — deploying only to the one under test left
  three stale, **twice**.
- **Never leave a diagnostic build deployed.** If you stop, restore shipping defaults and redeploy
  first, or the user gets log-spammed the next time they play.
- Mission-list rows are **toggles** — use `{"reliable": false}` or a double-click collapses them.
- In the editor, **do NOT press Escape** to leave transform mode; it opens the pause menu.
- Commit messages: **never backticks in `-m`**; use a heredoc with `-F -`.
- The scratchpad gets cleared; `er2call.py` may need recreating.
- Delegate research to sub-agents on **opus** and require sources. Sub-agents sometimes die at
  launch producing a 139-byte output file — if one is static for >5 minutes, do the work yourself
  rather than re-spawning.

## Standing rules
- **Enumerate causes before declaring a fix.** The phase-loop death was misdiagnosed **four** times.
  Do not write a second fix until the first has *reported* something.
- **Mark honestly.** ✅ means measured in a live battle with a number. Several features were ✅ on
  offline evidence alone and had to be retracted.
- **Prefer reverting an unproven change to shipping it.** Three formation attempts, two reverted on
  evidence, and that was right each time.

---

# STOP CONDITIONS — read these every iteration

**Stop and report** when any of these is true. Do not keep looping.

1. The queue is empty and both repos are tagged.
2. **An iteration made no measurable progress on its current queue item.** One no-progress tick is a
   signal; do not take a third. A `/loop` on this project once ran ~20 hours re-attempting a single
   blocked measurement — that is the failure mode to avoid above all others.
3. The only remaining items are the ones that need the user (below).
4. A phase gate fails twice in a row for the same reason.

Before stopping: restore shipping defaults, redeploy to all four missions, verify `cmp` 4/4, and say
plainly what is proven, what is not, and why.

# NEEDS THE USER — ask, do not burn ticks

- **T13, the kill feed** — requires a human spawned into a squad. Synthetic clicks have never
  reached the deploy control in any attempt.
- **Clearing the harness launch options** so they can play normally (requires closing Steam):
  `python3 er2-plugin/tools/fix_steam_launch_options.py --clear --apply`
- **Any editor work needing world-object picking** — offer to read the list while they drive.
