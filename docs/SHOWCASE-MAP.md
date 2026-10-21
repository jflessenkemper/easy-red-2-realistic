# Showcase map: one station per feature, all inside the streamed radius

**Status: designed and verified offline only. Nothing here has been loaded in the game.**
Source of truth: `missions/showcase/stations.json`. Derived files: `data/props/layout_showcase.json`
and `missions/showcase/tx_data_objects.er2f`, both produced by `tools/gen_showcase_layout.py`, which
`tests/check.sh` check **4o** re-runs on every build.

## Why a new layout

The existing range (`missions/scenarios/showcase.lua`) is a 4×4 grid on a 200 m pitch. The
diorama's **heal, reset, scripted casualty and station signs** all call `er2.getSoldiersInArea`, and
that query is **viewer-relative**: it returns only soldiers streamed in near the camera, whatever
centre and radius you pass it. A sweep in one run showed this: `PROBE origin/st8/st13 r=6000 n=15`,
the same 15 men from every centre, while 106 were alive. With the camera at the spawn about 500 m
from station 1, the query kept **0 of 5** (`raw=5 kept=0 keepR=240`). So every station beyond the
grid's near corner was dead.

What is known to work: with the 600 m grid centred on the objective, the query streamed **87
soldiers, 77 of them within 90 m of their station**, with all 13 stations built. That puts the
proven-good envelope at about 300 m from the camera and the known failure at about 500 m.
**Design rule: every unit sits within 250 m of the player spawn at (-28, 66).** The measured
maximum is 247 m.

Separation rule (unchanged from the old range): any unit at one station is at least
`SENSE_RADIUS` 90 + 25 = **115 m** from any unit at another station. Otherwise one station's
enemies enter its neighbour's force ratio, and both demos break. The measured minimum is 120 m.
Thirteen stations with 25–75 m enemy offsets don't fit inside 250 m on a grid, so the positions came
from a packing search and were then frozen. The checker is what enforces the rules, not the search.

## Layout (map-local metres; yaw 0 = +X, counter-clockwise toward +Z)

```
                  z
   S7(-120,295)    S8(84,286)
 S11(-216,222)       S1(32,172)
                 S13(-77,103)*  S10(137,113)
 S12(-270,81)     [B1 B2 B3 + SPAWN (-28,66)]
                        S4(49,31)
 S2(-237,-36)   S3(-55,-36)       S9(160,-41)
                    S5(50,-94)
             S6(-58,-159)                       -> x
```
`*` S13 is the player station, the one nearest the spawn (61 m).

| Stn | Centre | Yaw | From spawn | Enemy / vehicle points | Cover line | Features |
|---|---|---|---|---|---|---|
| S1 | (32,172) | 225 | 122 m | none | – | 1, 4b, 9 |
| S2 | (-237,-36) | 285 | 233 m | (-225,-79) | yes | 3, 2 |
| S3 | (-55,-36) | 165 | 106 m | (-118,-19) | yes | 14 |
| S4 | (49,31) | 135 | 85 m | (31,49) | – | 10 |
| S5 | (50,-94) | 285 | 178 m | tanks (63,-142), (91,-150) | – | 11 |
| S6 | (-58,-159) | 180 | 227 m | halftrack (-78,-159), enemy (-128,-159) | – | 5 |
| S7 | (-120,295) | 0 | 247 m | (-45,295) | yes | 4, 13, 12, 15, 8 |
| S8 | (84,286) | 315 | 247 m | (137,233) | yes | 16, 17 |
| S9 | (160,-41) | 45 | 216 m | tank (167,-23), enemy (213,12) | – | 18, 25 |
| S10 | (137,113) | 15 | 172 m | (209,132) | – | 19 |
| S11 | (-216,222) | 240 | 244 m | truck (-231,196) | – | 7 |
| S12 | (-270,81) | 0 | 242 m | (-195,81) | yes | 5b, 20, 6 |
| S13 | (-77,103) | 105 | 61 m | (-96,175) | – | 22, 23b, 24 (player spawns here) |
| B1 | (-28,91) | – | 25 m | no units | – | 21, 29 |
| B2 | (-3,66) | – | 25 m | no units | – | 26, 28 |
| B3 | (-53,66) | – | 25 m | no units | – | 23, 27 |

Enemy distances and vehicle offsets are copied from the existing station table, so each station
still forces the same branch. All 32 README feature rows (1–29 plus 4b, 5b, 23b) are assigned exactly
once. The checker fails if a feature is assigned twice.

**Props (27, all `Trench 1`, the only confirmed id):** for each station, a marker 12 m behind
the German squad (moved to the side if behind would leave the map), plus a 3-trench cover line 8 m
ahead at S2, S3, S7, S8 and S12, where the branch needs cover. **Optional layer, unconfirmed:**
`--min-status palette-read` adds barbed wire 15 m beyond each enemy point and an Ammunition Refill
Box at each board. Those ids were read off the palette and have never been loaded from a
hand-written file, so they stay out of the default file.

## Station by station: what you should see

Status uses the README's terms: **proven** (measured live), **partial** (part of the claim
measured), **unproven**.

- **S1 Approach march / formation / MG-centric** (1, 4b, 9). No enemies. The squad marches toward
  its objective on the flattest line, strung out in a staggered file, then coheres on the MG gunner.
  Sign: `ROAD-MARCH`, `RALLY-on-MG`. 1 proven · **4b partial** (the branch fires, the geometry has
  never been measured) · **9 unproven** (the Schützenkette shape: riflemen front-right/rear-left of
  the gunner).
- **S2 Pinned + taking cover** (3, 2). Two MG teams at 45 m. The squad goes to ground (`PINNED`),
  then fights from the trench line as suppression lifts. 3 proven · **2 partial**: the engine picks
  the cover, and the mod only decides when to ask.
- **S3 Rout** (14). Outnumbered 3:2 at 65 m. Men break and fall back about 40 m away from the enemy
  (`ROUT`/`ROUT-cover`). Proven (the direction is only weakly measured).
- **S4 Close assault** (10). One enemy squad at 25 m. They close and finish it (`ASSAULT`). Proven.
- **S5 AT team** (11). Two French tanks, no infantry. The AT man stalks beyond 60 m and holds and
  shoots inside it (`AT-stalk`/`AT-hunt`), and never joins a charge. Proven.
- **S6 Advance behind armour** (5). A halftrack 20 m out. Riflemen form line-abreast about 6 m
  behind the hull (`ADVANCE-behind-armour`). Proven on Panzers only; it can't be re-proved on a
  scripted rig.
- **S7 Bounding overwatch + support + leaders + doctrine + cover discipline** (4, 12, 15, 8, 13).
  One enemy at 75 m. Half the squad moves while half fires, swapping every 8 s; the MG holds as the
  base of fire; the leader directs from cover. 4 proven · **12 partial** (MG yes, mortar never
  seen) · **15 partial** ("never walks point" isn't tested) · **8 partial** (the profile table is
  verified, its behavioural effect isn't) · **13 unproven** (no two-nation comparison of how often
  bounds route through cover).
- **S8 Medic + wounded drag** (16, 17). Enemy at 75 m, outside the 50 m pinned radius. The diorama
  hurts one man each round. Watch the medic sortie and a squadmate carry the casualty to the trench
  line (`MEDIC-sortie`, `DRAG-*`). 16 proven · **17 partial** (only 2 completed drags ever
  observed).
- **S9 Crew bail-out + non-infantry deferral** (18, 25). A crewed Panzer II. When it's knocked out,
  the crew bail and move away from the enemy (`CREW-onfoot`); while mounted they defer
  (`MOUNTED-defer`). Proven.
- **S10 Radio fire mission** (19). A pinned radioman calls a barrage. A 12 s warning, then shells
  land on the enemy at 75 m. Proven (once, inlined build).
- **S11 Transport reuse** (7). No contact, truck 30 m away, objective at least 120 m off. Men walk
  back to the truck and remount (`RETURN-`/`REBOARD-transport`). **Unproven** (n=2 labels, boarding
  never confirmed). Place the objective inside 250 m and at least 115 m from other stations' units.
- **S12 Consolidate / objective flow / defenders** (5b, 20, 6). They take a small objective, dig in
  facing the counter-attack, and the attraction releases them to the next one. The French hold
  (`DEFEND-hold`). 5b is offline-only (no live count) · 20 and 6 proven.
- **S13 Player station: kill feed, callouts, voice** (22, 23b, 24). Spawn here. Your own squad's
  deaths appear as `<name> (<role>) killed by <weapon>`, one squadmate calls each death, and
  situational voice lines play. 23b proven · **22** is NOT PROVEN in the README (needs a human at
  the keyboard) · **24** has 1 of 8 kinds confirmed.
- **B1 Setup + squad resolution** (21, 29). Log only: every soldier gets the brain, and about 15%
  resolve their squad late. Proven.
- **B2 Faction awareness + role detection** (26, 28). Signs and log show the nation and doctrine
  each side resolved to, plus native role flags. 26 proven · **28 partial**.
- **B3 Battalion tally + logging** (23, 27). Tally lines in the log; diagnostics ship off.
  **23 unproven** (never checked against an independent casualty count) · 27 is static-gated.

## Station-to-station controls (arrow keys): not available. The alternative is unproven.

**The scripting API has no key input.** The official callback list (`docs/verified-api.md`,
2.1.0+) is `soldier_spawned, soldier_died, soldier_suppressed, vehicle_destroyed, vehicle_disabled,
vehicle_damaged_fueltank, phase_changed, battle_ended`. It has no key, input or UI event, and no
`getKey`/`isKeyDown` appears anywhere in the verified API, the probe catalog or the wiki. There's
also no camera setter: the only camera call is `cameraPosition()` (read-only), and the wiki
(`er2-free-camera-not-automatable`) records that the free camera can't even be aimed from outside.
A Lua "Left/Right = previous/next station" binding **can't be built**.

**Closest working alternative: the engine's own spectator squad-cycling.** The wiki's verified
technique for touring a map is to cycle squads in the spectator view with the game's next/previous
squad keys. That wraps, and it moves the camera, which also moves the streamed set, so each
station's heal and signs come alive as you arrive. To make that cycling step through the stations
in order, the rig should spawn the stations' German squads in S1…S13 order.
**Unproven:** whether spectator cycle order follows spawn order hasn't been observed. Fallbacks,
also unproven: a per-station spawn point in the editor (pick a station from the deploy screen), or
`Soldier.setPlayer()` for a timed guided tour. That call appears in the official API docs (noted in a past session) but has never
been exercised by this mod.

## Station demos that loop forever: design. Unproven, and not yet wired to these positions.

The mod already has a looping diorama (`CYC` in `RealisticEvents.lua`): **act 60 s → reset 45 s →
act…**, with a heal tick, a scripted casualty per round and a station sign. Jordan's ask maps to it
like this:

1. **Run the feature** (act). The casualty is re-chosen each round, so S8 re-triggers by itself.
2. **Hold the result.** Proposed: a 15 s hold between act and reset, where the heal keeps everyone
   alive and the sign keeps showing the decision. Not yet implemented: `CYC` is act/reset only.
3. **Reset.** Men walk back to their marks. There's no soldier teleport, so reset is a march, and
   the gate in `tests/offline_phase.lua` requires `reset × 3 m/s ≥ radius`. The diorama re-orders
   them home **every tick** so the brain can't override it.
4. **Repeat** with no re-triggering.

**No pile-up, by construction.** Units are spawned **once** at mission start. Each loop heals and
walks the same men home; it never respawns them. The unit count can't grow, so there's nothing to
clean up. That's the strongest cleanup guarantee available, because the API has **no confirmed
despawn**: `Squad.removeSoldier` only detaches a man from his squad, `killSoldier` leaves a body,
and `er2.destroyAll`'s semantics are unverified. S9 (a destroyed vehicle) and S10 (shell damage)
are the exceptions. They need a fresh hull or crew each round, which the existing loop doesn't do.
Until a despawn is proven, those two stay one-shot per battle. A respawning loop for them would grow
the unit count every round.

**What's wired today:** the loop runs on the old grid (`showcase.lua`'s `STATIONS`), not on these
positions. To make it run here, the rig has to read the station centres from `stations.json`
(inlined like the existing showcase prefix, under the 200-local ceiling), and the hold phase has to
be added. That needs luajit on PATH for checks 2/4d/4e before it could be trusted. Both the loop and
the controls are **unproven until loaded in game**.

## What only an in-game load can confirm

1. All 27 `Trench 1` records load from a generated (not editor-written) file, at y = 1.00531 on
   this terrain (the heightmap hasn't been read; props may float or sink), with yaw in the expected
   sense.
2. `getSoldiersInArea` sees every station from the spawn, i.e. signs and heal are live at S7/S8
   (247 m).
3. Each station fires its labels once the rig is pointed at these coordinates.
4. Spectator cycle order vs spawn order; the loop's hold phase; whether S9/S10 can re-arm.
5. That map units are metres (`size 500`, `terrainScaleMultiplier 0.5`). The ±295 m extent relies
   on the 600 m grid having already built on this map.

## Rules this design keeps

Offline only; nothing written into `map_editor/` (the generator refuses without `--into-game`); no
1000×1000 resize and no water `yPosition` change (both need Jordan's approval); no `.mer2` patch.
To try it, Jordan backs up the map and copies `missions/showcase/tx_data_objects.er2f` into it
himself.
