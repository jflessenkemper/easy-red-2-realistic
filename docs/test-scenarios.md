# Test scenarios — one per feature, built to force its branch

Donchery is a bad test rig and this session proved it three times over. 350 soldiers, most features
firing a handful of times, a battle that takes ~13 minutes, and **run-to-run variance larger than
the effects being measured** — two identical configurations gave along/across ratios of 1.19 and
1.39. Conclusions drawn from one battle there are worth very little.

These scenarios fix that. Each one:

- **isolates** a feature by removing the conditions that would let a higher branch pre-empt it
  (the cascade is strictly first-match, so this is the whole trick — see `docs/images/decision-cascade.svg`)
- **forces the trigger** using the mod's real constants, listed per scenario
- is **small and short**, so it can be run 3+ times to establish the variance band before anything
  is claimed
- states a **PASS criterion** a tool can check, not an impression

## Build them on VirtualScene

**Use the `[Vanilla] Virtual Scene` map, not Stonne.** VirtualScene needs **no DLC**, which means the
whole suite runs with `er2_launch {"via_steam": false}` — no Steam launch-options dance, no
`Needs DLCs: Ardennes` dead row, and none of the Steam fragility that blocked verification
repeatedly today. It is flat and featureless, which is a *feature* here: no terrain confound.

Two scenarios genuinely need terrain (T6 defilade, T12 two objectives). Note them and run those on
Stonne when entitlement is available.

## Settings for every scenario

| Setting | Value | Why |
|---|---|---|
| `respawn_delay` | **disabled** | A respawning enemy changes the force ratio mid-test and invalidates morale results |
| `DEBUG` | `true` | Needed for the decision trace |
| `TELEMETRY` | `true` | Needed for `battle_map.py` / `movement_audit.py` |
| `WATCH` | `true` | The stuck/moving counts |
| **`DBG_SAMPLE`** | **`1`** | **Critical.** It ships at 6, so with a 10-man scenario only 1–2 men are ever traced. Set it to 1 or the test sees almost nothing |

Run each **three times** and compare with `movement_audit.py runA.log runB.log runC.log`. The tool
prints the spread and refuses to let a difference smaller than it count as evidence.

---

## T1 — Approach march, file, and the Schützenkette
**Features:** 1 approach march · 4b staggered file · 9 MG-centric Kette · 27 logging

**Forces:** one German rifle Gruppe (10 men, incl. 1 Support gunner). **No enemies at all.**
**Layout:** squad at one end, objective **400 m** away. Place the **Support gunner 40 m off to one
flank** at spawn — `RALLY-on-MG` only fires when the gunner is more than `MG_COHESION` (25 m) away.

**Why it isolates:** with zero enemies, `threatened` is false, so every branch above `DEFEND-hold`
is unreachable. Only the no-contact path can run.

**PASS:**
- `ROAD-MARCH` fires and its median speed **> 0.5 m/s** (`movement_audit.py`, intent-vs-outcome)
- `RALLY-on-MG` fires
- **along/across ratio drops below 1** — a Kette is wide across the axis and thin along it, the
  inverse of the 1.19–1.45 blob. *This is the unverified prediction for feature 9.*
- `inv_frozen_pct` = 0

---

## T2 — Suppression and cover
**Features:** 3 pinned · 14 fight from cover · 2 engine cover

**Forces:** one German Gruppe. **Three** French Hotchkiss MG teams, emplaced, **40 m** away with
clear line of sight. Give the Germans no covered approach.
**Layout:** open ground, 40 m separation.

**Why it isolates:** 3 enemies within `PINNED_RADIUS` (50 m) exceeds `PINNED_ENEMIES` (2), so
`PINNED` pre-empts everything below it. Keep the German force ratio *above* `ROUT_COLLAPSE` (0.60)
or rout will fire first — so 10 Germans against 3 MG teams, not fewer.

**PASS:** `PINNED` dominates the decision mix · pinned men's median speed **< 0.3 m/s** (they should
be on the deck) · `FIGHT-from-cover` appears once suppression lifts.

---

## T3 — Morale and rout
**Feature:** 14 rout

**Forces:** **four** German riflemen versus **twenty** French, at **60 m**.
**Layout:** open, no cover for the Germans.

**Why it forces it:** rout needs force ratio below `ROUT_COLLAPSE` (0.60) **and** a casualty signal
(`ROUT_CASUALTIES` 1, or own HP under `ROUT_HURT_HP` 65). 4 v 20 gives ratio ≈ 0.17, and casualties
arrive immediately. 60 m keeps most enemies outside `PINNED_RADIUS` so `PINNED` does not pre-empt —
note rout is evaluated **above** pinned anyway, deliberately, so a surrounded man breaks rather than
hugging the deck.

**PASS:** `ROUT` / `ROUT-cover` fires · net displacement is **away from** the enemy centroid ·
`ROUT_FALLBACK` (40 m) roughly matches the distance broken.

---

## T4 — Close assault
**Feature:** 10 close assault

**Forces:** one German Gruppe (aggression 0.75, assault range 35 m) versus **two** French riflemen
at **25 m**, in the open.
**Layout:** 25 m separation, no cover.

**Why it isolates:** German aggression 0.75 clears `ASSAULT_MIN_AGGR` (0.50); 25 m is inside the 35 m
assault range. Only **two** enemies, so `PINNED_ENEMIES` (2) is only just met — keep it at two or
below, or PINNED wins. Assault sits **above** pinned in the cascade precisely so it can fire at all.
Repeat with **France** (aggression 0.40) as the control: it should **not** assault.

**PASS:** `ASSAULT` / `ASSAULT-cover` fires for Germany and **not** for France · net displacement
toward the enemy · closing distance drops below 10 m.

---

## T5 — Anti-tank teams
**Feature:** 11 AT teams

**Forces:** one German **Anti-Tank Gruppe** versus **two** French tanks (or the 25 mm on a carrier),
starting at **100 m** and closing.
**Layout:** 100 m, open. Add **no** enemy infantry.

**Why it isolates:** 100 m is inside `AT_RANGE` (120) but outside `AT_EFFECTIVE` (60), so the first
decision must be `AT-stalk`; as the tanks close inside 60 m it must become `AT-hunt`. No enemy
infantry means `ASSAULT` cannot pre-empt — and the AT branch sits **above** assault anyway, by
design, so the battalion's AT capability is not spent charging riflemen.

**PASS:** `AT-stalk` at range then `AT-hunt` inside 60 m · AT men close on the vehicles · `ASSAULT`
never fires for AT-classed men.

---

## T6 — Advance behind armour *(needs terrain — run on Stonne)*
**Feature:** 5 advance behind armour

**Forces:** one German Gruppe plus **one Sd.Kfz. 251**. One French MG team at **200 m**.
**Layout:** the halftrack between squad and enemy, squad within `ARMOUR_SCAN` (45 m) of it.

**PASS:** `ADVANCE-behind-armour` fires · men sit **~`ARMOUR_HUG` (6 m)** behind the hull, spread
`ARMOUR_SPREAD` (2.5 m) apart · the hull stays between the men and the enemy (check the angle in
`battle_map.py`, colour-by-decision).

**Control worth running:** swap the 251 for an **Opel Blitz**. The name filter should refuse it —
a lorry is not cover — and the branch must **not** fire.

---

## T7 — Bounding overwatch
**Feature:** 4 bounding overwatch

**Forces:** one German Gruppe versus **exactly one** French rifleman at **150 m**.
**Layout:** open, 150 m.

**Why the single enemy matters:** `THREAT_ENEMIES` is 1, so one enemy makes the squad *threatened*
and opens the bounding branch. But `PINNED_ENEMIES` is 2 — so with one enemy, `PINNED` can never
fire and steal the test. 150 m also keeps him outside `PINNED_RADIUS` (50 m). This is the narrow
window where bounding is observable at all.

**PASS:** `BOUND-move` : `BOUND-overwatch` ≈ **1:1** (they alternate on an 8 s `BOUND_PERIOD`) ·
movers' median speed **> 0.5 m/s** while watchers' is **< 0.2 m/s** — intent-vs-outcome separates
them directly · bounds are roughly `BOUND_STEP` (20 m).

---

## T8 — Medic and casualty drag
**Features:** 16 medics · 17 wounded drag

**Forces:** one German Gruppe **including a medic**, plus one French **marksman at 120 m** to
generate casualties slowly.
**Layout:** 120 m — deliberately outside `PINNED_RADIUS` (50 m) so the squad is not pinned and the
medic can actually sortie.

**Why the distance matters:** `MEDIC-sortie` requires no enemy inside `PINNED_RADIUS`; a close-range
firefight makes the branch structurally unreachable, which is how it was broken once before.

**PASS:** `MEDIC-sortie` and `MEDIC-hold-cover` both fire · `DRAG-approach` → `DRAG-pickup` →
`DRAG-to-cover` sequence appears · **exactly one** man is elected per casualty (count distinct uids
on `DRAG-*` per casualty — the election is the interesting part, and it uses no messaging).

---

## T9 — Crew bail-out
**Feature:** 18 crew bail-out

**Forces:** one German **Panzer II** with crew, one French **25 mm AT gun** emplaced at **300 m**.
Nothing else.
**Layout:** clear line of sight so the gun kills the tank promptly.

**Why it works:** the branch needs a *destroyed or disabled armoured vehicle whose occupants get
out*. Trucks will not do it — occupants are passengers, and this is the exact reason the feature sat
unobserved for the whole project until a Panzer II finally brewed up.

**PASS:** `bail-out: N crew left vehicle Panzer II` in the log · `CREW-onfoot` fires for those men
within `CREW_SHOCK` (45 s) · they move **away** from the enemy rather than joining a firing line.

---

## T10 — Fire mission, and finally a barrage that lands
**Feature:** 19 fire support

**Forces:** one German Gruppe **with a radioman**, and **three or more** French infantry at
**130 m**.
**Layout:** critical geometry — block the squad so it moves **less than `STALL_DIST` (15 m) in
`STALL_WINDOW` (30 s)**, e.g. put them behind a wall or against the map edge.

**Why no barrage has ever landed:** the phase script refuses danger-close if any friendly of the
requesting side is within **`FIRE_DANGER_R` (90 m)** of the target. In a close infantry fight that
is *always* true, which is why every one of the six observed responses was `REFUSED danger close`.
Putting the enemy at **130 m** puts the target beyond 90 m from every German — so the mission can
finally be **accepted**.

**PASS:** brain-side `RADIO-fire-mission` · phase-side **`accepted`** (not refused) ·
`rounds away: N shells` · shells actually land. Needs `RADIO_MIN_ENEMIES` (3) enemies sensed.

---

## T11 — Transport reuse
**Feature:** 7 transport reuse

**Forces:** one German Gruppe that starts **mounted** in an Opel Blitz. **No enemies.**
**Layout:** dismount them (or let them dismount), then place the objective **more than
`REBOARD_MIN_DIST` (120 m)** away, with the truck **within `REBOARD_SCAN` (60 m)** and roughly
toward the objective.

**Why all five conditions matter:** re-boarding requires no contact, not carrying a casualty,
objective farther than 120 m, transport intact and within 60 m, and pointing the right way. Zero
enemies satisfies the contact cooldown that otherwise suppresses it mid-assault.

**PASS:** `RETURN-to-transport` then `REBOARD-transport` · men reach `BOARD_ADJACENT` (6 m) of the
truck · they end up mounted (`inVeh` = 1 in telemetry).

---

## T12 — Objective flow and the watchdog *(needs two objectives — Stonne or a custom map)*
**Features:** 5b consolidate · 20 objective attraction

**Forces:** small — 20 Germans, 8 French — so the first objective falls in a couple of minutes.
**Layout:** two objectives **250 m** apart in sequence.

**Why small forces:** this is the only scenario that needs the battle to *progress*, and the whole
point is to reach the **phase change** quickly. That is where the engine kills the phase loop and
the `soldier_died` watchdog takes over.

**PASS:** `CONSOLIDATE` fires on the first objective (within `ARRIVE_RADIUS` 30 m) ·
`obj1 … held=true … CAPTURED` · **attraction output continues after the loop's tick freezes** —
that is the watchdog working · units then flow to objective 2.

**Also worth watching:** telemetry cadence degrades after the loop dies (measured ~6.7 s against the
2 s nominal), because the watchdog only pumps on deaths. In a lull it would stall entirely. That is
a real known limitation and this scenario is where it shows.

---

## T13 — Kill feed and squad callouts *(needs a human at the keyboard)*
**Features:** 22 kill feed · 23b squadmate deaths · 24 voice

**Forces:** you spawn into a German Gruppe. One French marksman at 100 m killing your squadmates
one at a time.

**Why manual:** the feed is scoped to **the player's own squad**, so it needs a player. Synthetic
clicks could not reach the deploy control in any attempt this session — this one is yours.

**PASS:** on-screen line reads `<name> (<role>) killed by <weapon>` — **weapon only, never the
killer's name** · nothing else is drawn on screen · **exactly one** squadmate calls out per death ·
silence for roles the engine has no clip for (only radioman, MG gunner and leader have one — that
silence is deliberate, a wrong line is worse than none).

---

## Coverage

| Feature | Scenario |
|---|---|
| 1 approach march · 4b file · 9 Kette · 27 logging | **T1** |
| 2 cover · 3 pinned · 14 fight from cover | **T2** |
| 14 rout | **T3** |
| 10 close assault (+ France control) | **T4** |
| 11 AT teams · 12 support weapons | **T5** |
| 5 advance behind armour (+ lorry control) | **T6** |
| 4 bounding overwatch · 13 cover discipline | **T7** |
| 16 medics · 17 wounded drag | **T8** |
| 18 crew bail-out · 25 non-infantry | **T9** |
| 19 fire support | **T10** |
| 7 transport reuse | **T11** |
| 5b consolidate · 20 objective flow · watchdog | **T12** |
| 22 kill feed · 23b callouts · 24 voice | **T13** |
| 6 defenders · 8 doctrine · 15 leaders · 21 setup · 23 tally · 26 faction · 28 roles · 29 squads | fall out of **every** scenario |

**Not covered by any scenario, because they are impossible on this build:** aircraft/CAS control,
real road pathing, smoke on demand, engine formation orders, `ADVANCE-baseAI`.

## Suggested order

**T1, T2, T7** first — they cover the movement and formation questions that are still open, need no
DLC, and T1 carries the one unverified prediction (feature 9's Kette). **T10** next, because it is
the only route to seeing a barrage actually land. **T9** whenever a tank can be arranged. The rest
are regression cover.
