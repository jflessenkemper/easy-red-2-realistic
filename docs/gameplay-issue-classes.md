# Gameplay issues the verification could not see, and what to do about them

Written 2026-09-10 after a play report — "lots of errors in the logs for stonne, and the germans
clump along the river, probably because its low terrain" — found a real defect that every gate,
harness and live run had passed.

## The root cause is a measurement gap, not a coding mistake

Everything verified so far measured **decision labels and counts**. `ROAD-MARCH 17` proves the
branch fired. It says nothing about **where the soldier went**. So an entire class of defect is
invisible: *the right branch fires and produces bad behaviour.*

Two compounding blind spots made it worse:

1. **`tests/offline_brain.lua` stubbed `getTerrainHeight` as a flat `0`.** The approach march is
   scored by terrain flatness as a road proxy, so on flat ground the entire heuristic is
   mathematically inert — every candidate ties. The one test that RUNS the brain could not have
   caught this.
2. **The showcase test map is flat desert.** So the live range could not show it either. A test map
   with no slope cannot test terrain-sensitive movement.

## What was actually wrong (and my first diagnosis was wrong too)

I initially blamed a preference for descending into valleys. Working the arithmetic disproved it:
flatness is `max-min` elevation along the segment, so **descending always scored badly**. The real
failure is refusing to climb OUT:

| from the valley floor | flatness | straightness (old 0.02/deg) | total |
|---|---|---|---|
| sideways along the floor (60°) | 0.0 | 1.2 | **1.2 — wins** |
| toward the objective, up the bank (0°) | 2.5 | 0.0 | 2.5 |

So squads slid along the river rather than crossing it, and bunched. Fixed by raising the
progress weight to 0.15/degree, so a 60° detour costs 9.0 and only a genuine ridge justifies it.
Asserted by "in a river valley -> approach march CROSSES it", which was confirmed RED at the old
weight (`z=17.5 x=18.0`, 46° off-axis) and green at the new one.

A second, independent cause was the spawn itself: trimming took the first 3 of a 12-Gruppe line
spread over 420 m, so the attack began crammed into 76 m of one bank.

## The remaining candidates in the same class — untested, ranked by risk

1. **The Donchery layout assumes an axis it never measured.** The OOB derives ORIGIN from the
   mission's first objective, then lays the Germans at `z = origin - 40` and the French at
   `z = origin + 260`, i.e. it ASSUMES the Meuse runs east-west with the attackers to the north.
   Nothing verifies that against the real map. If the river runs otherwise, the whole force is
   mis-oriented and some of it may be standing in water. **This is the top suspect for any
   remaining "wrong place" behaviour and is not yet checked.**
2. **`RALLY-on-MG` converges the squad on one man.** Clumping by design, with no minimum spacing —
   the same symptom class as the river bunching, and a mortar round's dream.
3. **`findCover` has no directional preference.** It can legitimately move a man toward the enemy;
   it already faked "breaking contact" once (measured -7.59 m/frame toward the enemy). Cover is
   feature 2 and is still NOT PROVEN.
4. **`ADVANCE-behind-armour` hugs 6 m off the hull** with no check on which side. Nothing stops it
   placing men in front of the gun, or on the exposed flank.
5. **No obstacle or water awareness anywhere.** Destinations are chosen geometrically; buildings,
   walls and water are invisible to the brain. `moveTo` may simply fail or pin men on a wall.
6. **Objective attraction can pull squads across impassable ground**, since attraction is a
   straight-line pull with no route check.
7. **Emplaced weapons could face the wrong way.** Rotation was wrong for weeks (Euler degrees
   misread as a direction vector) and nothing asserted facing until a gate was added.

## The design: assert world state, not labels

Four layers, cheapest first. The first two are the ones that would have caught this bug.

1. **Model the world in the offline harness.** Terrain is now injectable per scenario
   (`S.terrain`) — DONE. Extend the same way with a water plane and simple box obstacles, then
   assert destination properties: not below a water level, not inside a box, not more than N metres
   below the soldier, progress toward the objective above a floor.
2. **Geometry assertions per movement branch, not label assertions.** Every branch that issues a
   `moveTo` gets a scenario asserting a PROPERTY of the destination. `CREW-onfoot` already does
   this by direction, and it is the model to copy — it is the only branch that has ever been
   asserted this way, and it is the only movement bug that was caught before play.
3. **A dispersion metric in the live audit.** `tools/movement_audit.py` should report the
   nearest-neighbour distance distribution per squad and per side over time. Clumping is a number:
   median nearest-neighbour distance collapsing toward zero. Also report the elevation profile of
   occupied positions, so "everyone is on the valley floor" is visible without a screenshot.
4. **A test map with real terrain.** The current range is flat, which is why it proves nothing about
   terrain. It needs a slope, a valley with a watercourse, a ridge and a built-up block — then the
   existing 13 stations become terrain-sensitive instead of terrain-blind.

## The standing rule this produces

**A decision label is not proof of behaviour — and a decision COUNT is not either.** Any feature
whose output is a position must be asserted on the position. Any harness stub that returns a
constant is a blind spot, and the constant is usually the value that hides the bug.
