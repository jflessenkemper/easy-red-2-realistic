# Realistic — specification

Per-soldier WW2 infantry behaviour for **Easy Red 2**. Two Lua files: `Realistic.lua` (the
per-soldier brain) and `RealisticEvents.lua` (the mission phase script, master client only).

**This document is generated from the source, not maintained alongside it.** The previous version
drifted badly — the cascade order was wrong in four places, four tunables carried stale values, and
nine constants were listed as absent that had existed for weeks. Where this file and the code
disagree, **the code is right**; and where this file and `docs/verified-api.md` disagree about the
engine, **`docs/verified-api.md` is right**.

> **VERSION CAVEAT.** Everything in `docs/verified-api.md` was probed against **v2.0.9**. The
> installed build is **v2.1.0**, and one documented signature has already been found wrong there:
> `spawnVehicle`'s third argument is a `vec3` direction, not degrees, and passing a number throws
> *past* `pcall` and kills the phase script. Treat every API entry as "verified on 2.0.9,
> unconfirmed on 2.1.0" until re-probed. The editor UI also changed layout in 2.1.0.

---

# 0. INSTALL

Copy two files into a mission's script folders:

```
~/.config/unity3d/Corvostudio/Easy Red 2/mission_editor/<YourMission>/scripts/
    AI/Realistic.lua          <- the brain
    mission/phase_0.lua       <- RealisticEvents.lua, renamed
```

That is all. **You do not need to set the Squad Spawner's `Brain` field** — the phase script
attaches the brain to every soldier the engine reports, via `soldier_spawned` plus a sweep at phase
start. Observed at 350 soldiers in one battle.

Nothing else is required: no per-map configuration, no editor setup, and it works with any two
belligerents.

---

# 1. THE DECISION CASCADE

Strictly **first-match**, and every branch is terminal. **The order IS the feature set** — a branch
placed below something that pre-empts it does not exist, which is how three features once shipped
unreachable. Verified against `Realistic.lua` by extracting the assignment order directly.

| # | Branch | Fires when | Behaviour |
|---|---|---|---|
| 1 | `CREW-onfoot` | lost an armoured ride < `CREW_SHOCK` 45 s ago, now on foot | **breaks contact** — a rearward `moveTo`, then cover on a later tick |
| 2 | `MOUNTED/CREW-defer` | in a vehicle | hands control to base AI; never ground-orders a passenger |
| 3 | `ROUT` / `ROUT-cover` | `shaken`: force ratio under the nation's `moraleFloor`, worse if bloodied | falls back `ROUT_FALLBACK` 40 m, covers `ROUT_COVER_DELAY` 3 s later |
| 4 | `AT-stalk` / `AT-hunt` | AT man with an enemy vehicle ≤ `AT_RANGE` 120 m | stalks beyond `AT_EFFECTIVE` 60 m, engages inside it. *Assigned via a variable, which is why a literal-string scan misses it* |
| 5 | `ASSAULT` / `ASSAULT-cover` | aggressive doctrine, enemy ≤ `assaultRange`, morale headroom, dice | closes one `ASSAULT_BOUND` 15 m, via cover per `coverDiscipline` |
| 6 | `PINNED` | `isSuppressed()`, or ≥ `PINNED_ENEMIES` 2 inside `PINNED_RADIUS` 50 m | goes to ground |
| 7 | `MEDIC-sortie` | medic, casualty ≤ `MEDIC_REACH` 60 m, no enemy inside 50 m | treats the casualty |
| 8 | `MEDIC-hold-cover` | medic, threatened | holds cover |
| 9 | `DRAG-approach` → `pickup` → `to-cover` / `abandon` | nearest healthy man to a casualty ≤ `DRAG_RADIUS` 30 m | carries him to cover; `CARRY_MAX_TRIES` 3, `DRAG_MAX_TIME` 12 s |
| 10 | `RADIO-fire-mission` | radioman stalled `STALL_WINDOW` 30 s with ≥ `RADIO_MIN_ENEMIES` 3 | requests a barrage, then covers |
| 11 | `LEADER-cover` | squad leader, threatened | preserves himself |
| **12** | ***threatened* sub-cascade** | | |
| 12a | `SUPPORT-hold-fire` | MG or mortar | holds a base of fire, never rushes |
| 12b | `ADVANCE-behind-armour` | friendly **armour** within `ARMOUR_SCAN` 45 m | line abreast `ARMOUR_HUG` 6 m behind the hull |
| 12c | `BOUND-move` / `-move-cover` / `-overwatch` | attacker, morale ok | half the roster moves while half watches, swapping every `BOUND_PERIOD` 8 s |
| 12d | `FIGHT-from-cover` | otherwise | fights from cover |
| **13** | ***no-contact* sub-cascade** | | |
| 13a | `DEFEND-hold` | defender | holds the line. **No `moveTo` at any range** |
| 13b | `CONSOLIDATE` | attacker within `ARRIVE_RADIUS` 30 m of the objective | digs in |
| 13c | `RETURN-to-transport` / `REBOARD-transport` | objective > `REBOARD_MIN_DIST` 120 m, transport intact and near | remounts (experimental) |
| 13d | `RALLY-on-MG` *or* `FORM-followLeader` | `mgCentric` doctrine, gunner > `MG_COHESION` 25 m | forms on the gun — see §4 |
| 13e | `ROAD-MARCH` | attacker with a known objective | flatness-biased approach march, laterally staggered |
| 13f | `ADVANCE-baseAI` | no objective at all | releases to base AI |

---

# 2. THE PHASE SCRIPT

Master client only. Auto-attaches the brain; runs objective attraction (advance → hold → next);
handles crew bail-out on `vehicle_destroyed` / `_disabled` / `_damaged_fueltank`; consumes
fire-mission requests with a danger-close gate; prints the kill feed and squadmate death callouts;
tallies the battalion; and carries a `soldier_died` **watchdog** that keeps the periodic work alive
across the engine's phase-loop death (`sleep()` never returns after a phase advance). The watchdog's
cadence becomes casualty-driven, ~7 s, and would stall in a lull.

It also carries the scenario rigs (`TEST_SPAWNS` / `TEST_VEHICLES` / `TEST_MOUNTED`), all shipping
inert.

---

# 3. DOCTRINE — 10 nations plus a fallback

Resolved from the soldier's own faction string via 31 tokens, with a `global` override
(`realistic_nation_invaders` / `_defenders`).

| nation | moraleFloor | mgCentric | aggression | assaultRange | coverDiscipline |
|---|---:|:---:|---:|---:|---:|
| germany | 0.22 | yes | 0.75 | 35 | 0.80 |
| france | 0.30 | yes | 0.40 | 20 | 0.80 |
| britain | 0.28 | yes | 0.50 | 25 | 0.85 |
| unitedstates | 0.32 | no | 0.60 | 30 | 0.65 |
| soviet | 0.20 | no | 0.85 | 45 | 0.35 |
| japan | 0.18 | yes | 0.85 | 40 | 0.50 |
| italy | 0.38 | yes | 0.42 | 18 | 0.65 |
| finland | 0.20 | yes | 0.55 | 25 | 0.90 |
| romania | 0.36 | yes | 0.42 | 18 | 0.65 |
| hungary | 0.36 | yes | 0.42 | 18 | 0.65 |
| **`DOCTRINE_DEFAULT`** | **0.30** | **yes** | **0.50** | **20** | **0.6** |

The fallback keeps **every branch reachable**. It did not until 2026-09-08: `aggression` was 0.45
against `ASSAULT_MIN_AGGR` 0.50 and `mgCentric` was false, so any unrecognised nation silently lost
close assault *and* the whole formation branch. Regression-tested offline.

**Roles.** Leader, AT, medic, radioman and marksman come from native engine flags, so they work in
any language. The **LMG gunner and mortar have no native flag** on this build and are matched on the
class name — a broadened token list, `isAmmoBoxCarrier()` as corroboration, and a
`realistic_mg_class` / `realistic_mortar_class` override. This matters because the gunner is the
*anchor* of the formation branch.

---

# 4. FORMATION — settled, and the honest answer is "not measurable"

`FORM.mode` selects between two implementations of the same intent:

- **`"kette"`** (default) — per-soldier `Schützenkette` slots on the gunner. 4 m interval, frontage
  capped at 36 m, sourced from 1939–40 German doctrine.
- **`"followleader"`** — the engine's own `Squad.followLeader`, issued by the **leader only** and
  throttled to `FORM.gap` 8 s.

Both work. **Neither is measurable in a battle.**

| variant | across σ | along σ | ratio |
|---|---:|---:|---:|
| blob (live, pre-Kette) | 17.4 | 19.1 | 1.12 |
| Kette (offline, calibrated) | 21.9 | 17.3 | 0.78 |
| followLeader (live) | 15.1 | 16.4 | 1.06 |

The metric's **live run-to-run spread is 0.23**. The Kette's effect is −0.17 and followLeader's is
−0.06 — both inside it. So no number of battles can attribute either. The default stays `kette`
because it is sourced doctrine at zero per-tick cost.

**Formation must be encoded as axis and extent, never interval.** Every doctrinal interval is
sub-σ against the engine's pathing scatter, so a file and a line are indistinguishable unless you
measure σ_along against σ_across.

---

# 5. TUNABLES

**Brain** — `TICK` 2.0 s (a pure framerate knob; 2.0 → 3.0 costs a third and *changes no decision*)
· `SENSE_RADIUS` 90 m (**not** a free knob: it feeds the force ratio and the rout test, and cost
scales with its square) · `THREAT_ENEMIES` 1 · `PINNED_ENEMIES` 2 · `PINNED_RADIUS` 50 ·
`COVER_RADIUS` 22 · `ROUT_FALLBACK` 40 · `ROUT_COLLAPSE` 0.60 · `ROUT_HURT_HP` 65 ·
`ROUT_CASUALTIES` 1 · `ROUT_COVER_DELAY` 3 · `ASSAULT_MIN_AGGR` 0.50 · `ASSAULT_MARGIN` 0.15 ·
`ASSAULT_BOUND` 15 · `MEDIC_REACH` 60 · `SQUAD_RETRY` 20 · `MOVE_DEADBAND` 6 · `MOVE_REISSUE` 4 ·
`ROAD_FOLLOW` true · `ROAD_STEP` 25 · `USE_ARMOUR_COVER` true · `ARMOUR_SCAN` 45 · `ARMOUR_HUG` 6 ·
`ARMOUR_SPREAD` 2.5 · `CREW_SHOCK` 45 · `COLUMN_STAGGER` 2.5 · `AT_RANGE` 120 · `AT_EFFECTIVE` 60 ·
`DRAG_RADIUS` 30 · `DRAG_MAX_TIME` 12 · `CARRY_MAX_TRIES` 3 · `CARRY_ADJACENT` 3 ·
`ARRIVE_RADIUS` 30 · `BOUND_PERIOD` 8 · `BOUND_STEP` 20 · `STALL_DIST` 15 · `STALL_WINDOW` 30 ·
`RADIO_MIN_ENEMIES` 3 · `RADIO_COOLDOWN` 120 · `REUSE_TRANSPORT` true · `REBOARD_MIN_DIST` 120 ·
`REBOARD_SCAN` 60 · `BOARD_ADJACENT` 6 · `BOARD_REISSUE` 5 · `VOICE_COOLDOWN` 6 · `MG_COHESION` 25 ·
`KETTE_INTERVAL` 4 · `KETTE_FRONT` 36 · `DBG_GAP` 8 · `DBG_SAMPLE` 6.

*The last nine of the drag/bound/stall group were listed as "constants the source does not contain"
in the previous version of this document. They exist and are load-bearing.*

**Phase script** — `BARRAGE_SHELLS` 24 · `BARRAGE_SCATTER` 70 · `BARRAGE_DAMAGE` 55 ·
`BARRAGE_PENETRATION` 80 mm · `BARRAGE_BLAST` 10 · `SHELL_INTERVAL` 0.8 · `SUPPORT_WARNING` 12 ·
`THREAT_TTL` 12 · `NEAR_ENEMY_R` 60 · `FEED_RADIUS` 120 · **`FIRE_DANGER_R` 50** ·
`FIRE_MIN_GAP` 150 · `FIRE_MAX` 3 · `FIRE_SHELLS_TICK` 3 · `ROLE_REFRESH` 5 ·
`ROLE_REFRESH_MAX` 60 · `BAIL_RADIUS` 10 · `BAIL_ALERT` 20 · `BAIL_PER_TICK` 4 ·
`BAIL_QUEUE_MAX` 24 · `ATTRACT_EVERY` 4 · `OBJ_REFRESH` 40 · `LOOP_STALE` 6 · `PUMP_GAP` 4.

**`FIRE_DANGER_R` was 90 and that made feature 19 mathematically unreachable.** It equalled
`SENSE_RADIUS`, and since the radioman publishes the *enemy centroid* as his target — a centroid he
can only have formed from enemies within 90 m — he was always inside the danger radius of his own
target. Every request in the project's history was refused. At 50 there is a usable 50–90 m window,
and `tests/check.sh` check 5b fails the build if the relationship ever inverts again.

**Internal state tables** (grouped, because the file is at the Lua **200-local ceiling** and one
extra top-level local breaks every brain at compile time): `AT` (target/failure/handle), `CLS`
(class string, MG/mortar/crew flags, matcher, overrides), `FORM` (mode/gap/lastT/failed), `DEC`
(31-entry label→code map), `DBGV` (debug counters).

---

# 6. HOW THIS IS VERIFIED

Four layers. `tests/check.sh` runs the static ones — **37 checks**.

**Static.** Lua syntax · no UserData reaching a Lua global (fatal at boot) · constants declared
once and used · banned patterns (`soldier_suppressed`, `.aiParams`, `uid % N`) · fill-style APIs
called with a table · helper locality · no local function read as a global (the forward-reference
bug that silently zeroed a feature) · **`DBG_SAMPLE` ships 6** · **`luajit` present is required, not
optional** · the `DEC` map agrees across all three copies · the armour name filter classifies every
real vehicle name · the Donchery OOB is coherent · `FIRE_DANGER_R < SENSE_RADIUS` · shipping
defaults · docs usable by a stranger.

**Offline, no game.** `offline_brain.lua` runs the real brain against a stubbed runtime through 18
scenarios and asserts the decision — and now, where it matters, the **direction** of the resulting
`moveTo`. `offline_phase.lua` drives the phase loop across a battle boundary.
`offline_formation.lua` drives N synthetic squads through the real `ketteSlot` under an injectable
scatter model and reports the ratio's *distribution*. `offline_showcase.lua` and
`offline_donchery.lua` validate the two spawn tables.

**Live.** `analyse_run.py` parses the `[REALISTIC]` trace and gates move/hold orders by pooled
speed, judging `ROAD-MARCH` on **objective closure** rather than pace. `movement_audit.py` parses
`[TELEM]` and reports per-decision formation anisotropy, signed direction relative to the **local
sensed enemy** (plus the soldier's *own* motion along a fixed axis, because distance to a moving
centroid cannot distinguish "ran the wrong way" from "ran the right way and got chased"), and
soldier-to-vehicle joins. `watch_audit.py` cross-tabulates decisions against the engine's own state
(`isOnCover`, `isMoving`, `getSuppressionValue`).

**Rules that survived contact.** Never conclude from one battle. A decision label is not proof of
behaviour. Filter mounted soldiers from every spacing statistic — they share the vehicle's position,
which once faked a 1.0 m median spacing that was really 32 m. A battle-wide metric cannot test a
squad-level feature (~18:1 dilution). When a whole class of results looks wrong at once, suspect the
measurement — that has been the right call three times. **After writing a gate, break the thing and
confirm the gate goes red**: seven "tests that cannot fail" were found this way, including `$?` read
through a pipe, a `sed` anchor that never matched, and an assertion reading a field the stub never
wrote.

---

# 7. KNOWN LIMITS

**Impossible on this build:** aircraft/CAS control · real road pathing from Lua · smoke on demand ·
true line/column formation *orders* (though squad tactical orders exist and `followLeader` works).

**Not verifiable as things stand:**
- **Features 5 and 18** (advance behind armour, crew bail-out) cannot be re-verified on a scripted
  rig: `spawnVehicle()` has **no faction parameter**, so a script-spawned vehicle has no owning
  side. `advanceBehindArmour()` requires `isSameFaction(vehicle, soldier)`, and the enemy will not
  engage a factionless vehicle either. They need an **editor-placed** vehicle spawner.
- **Feature 9's geometry** — verified offline, effect below the live noise floor. See §4.
- **The kill feed** needs a human in a squad; synthetic clicks have never reached the deploy control.
- **The Donchery order of battle** is coherent and gated but **has not been spawned in a battle**:
  Stonne needs the Ardennes DLC, which needs Steam mode, which needs Steam closed.

**Squad size is not settable.** KStN 131c gives a ten-man Gruppe for May 1940 and the build sheet is
right about that, but the number of men a squad id spawns comes from the game's squad *template*,
not the spawn call — `ger_infantry_1940` was observed at 4–8. Order-of-battle targets are therefore
expressed in squads, not men.
