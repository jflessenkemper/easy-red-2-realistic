# Easy Red 2 scripting API — OFFICIAL documentation exists

Researched 2026-09-09, inline (both research sub-agents died on the org spend limit; per
`deep-research-cap-resume-burn` they were NOT re-dispatched).

## THE HEADLINE: there is an official scripting wiki, and this project never used it

* **https://easyred2.com/wiki/scripting** — "Reference every Lua function, callback, and data
  structure supported by Easy Red 2." Per-function pages at `scripting.php?id=<name>`.
* **https://easyred2.com/wiki/scripting_callbacks.php** — the Callbacks API.
* **https://easyred2.com/wiki/guide.html** — the scripting guide (概 concepts, `myself()`,
  `er2.nextPhase()`, `global.get/set`, "sleep() recommended in loops").
* Hub: https://easyred2.com/wiki/ and https://wiki.easyred2.com
* The callbacks page states its content is **version 2.1.0+**, i.e. CURRENT for our install.

Everything in `docs/verified-api.md` was reverse-engineered by trial and error in-game. That was
avoidable. **Check the wiki BEFORE probing.**

## CONFIRMED CORRECTION: spawnVehicle arg 3 is EULER DEGREES, not a direction vector

Official page `scripting.php?id=spawnvehicle`:

    Vehicle spawnVehicle(string id, vec3 location, vec3 eulerRotation)
      1. string - Id of the vehicle to spawn
      2. vec3   - Location where to spawn the vehicle
      3. vec3   - Euler rotation of the vehicle          example: vec3(0, 90, 0)

Our note said "arg 3 is a vec3 direction, NOT degrees". **Half right, and the wrong half
mattered.** It IS a vec3 (so passing a bare number throws, as we measured), but its components are
EULER ANGLES IN DEGREES. We were passing direction vectors like `vec3(0,0,1)` to mean "face +Z";
as an Euler rotation that is ~1 degree of roll, so every vehicle sat at default yaw. The intended
facings were never applied. FIXED in `missions/donchery_oob.lua` (yaw degrees) and gated.

## Callbacks — official list (2.1.0+), via er2.setCallback

| name | args |
|---|---|
| `soldier_spawned` | Soldier |
| `soldier_died` | Soldier |
| `soldier_suppressed` | Soldier (suppressed), Soldier (shooter) |
| `vehicle_destroyed` | Vehicle |
| `vehicle_disabled` | Vehicle |
| `vehicle_damaged_fueltank` | Vehicle, Number (damage) |
| `phase_changed` | Number (current phase), Number (next phase id) |
| `battle_ended` | string (winning faction), boolean (forced) |

`Soldier.setCallback` and `Vehicle.setCallback` expose per-instance equivalents with the implicit
subject dropped from the args.

**All seven names we register are CORRECT** (`battle_ended`, `soldier_died`, `soldier_spawned`,
`vehicle_damaged_fueltank`, `vehicle_destroyed`, `vehicle_disabled`). We also register
`soldier_target_inf_acquired`, which the extraction did not list — the page notes further
per-instance events exist, so treat it as unlisted rather than invalid.

### TWO discrepancies to keep OUR empirical finding on
1. **`soldier_suppressed` is documented and NOT flagged unsafe**, but we measured it NRE-ing inside
   the engine's own dispatch, uncatchable by pcall, and `check 4` bans subscribing to it. Keep the
   ban — a measured crash outranks silence in the docs. Re-test before ever lifting it.
2. `loadfile()` is NOT documented at all, consistent with our finding that it resolves from an
   unlocatable `<mission>/globals/` and its failure aborts the script even inside pcall.

## ACTIONABLE, not yet implemented: `phase_changed` solves the phase-loop death

Our phase script polls `getCurrentPhaseId()` and BREAKS its main loop at a battle boundary, after
which the game does not reload the script — objective attraction, bail-out drain and fire-mission
consumption all go dead while callbacks still look alive. `phase_changed(current, nextId)` and
`battle_ended(faction, forced)` are first-class callbacks. Subscribing to `phase_changed` to
RESUME (rather than polling to break) is the documented fix. Needs testing; behaviour change.

## Still NOT answered by the docs
* **No documented spawn limit.** Nothing about max concurrent soldiers/squads, per-mission unit
  budgets or reinforcement pools. So the Donchery ceiling (8 of 31 on one mission, 29 of 29 on
  another) is NOT explained by a published cap. The mission's own standing force remains the best
  hypothesis.
* **Exact parameter lists** for `spawnSquad_script` / `spawnSquadOnVehicle_script` /
  `spawnMissionObjective` were not extracted — the per-function pages exist
  (`scripting.php?id=spawnsquad_script` etc.) and should be read individually before trusting our
  reverse-engineered signatures.
* **The `.mer2` `spawnType` "disabled" integer is still unknown.** Not covered. A sub-agent noted
  "the official SDK ships 259 real engine C# sources" before dying, and there IS an official
  Modding SDK (Steam Workshop tooling, tutorial playlist) — if those C# sources are obtainable they
  would contain the enum and would let us automate disabling Donchery's spawners. NOT verified: no
  SDK and zero `.cs` files exist in the local game install (checked).

## Other resources found (not yet mined)
* Easy Red wiki (Fandom): https://easy-red.fandom.com/wiki/Easy_Red_2
* Steam guide "Gameplay Mods in Easy Red II": https://steamcommunity.com/sharedfiles/filedetails/?id=3482039608
* ModDB addons/downloads: https://www.moddb.com/games/easy-red-2/addons
* Official Modding SDK tutorials (YouTube playlist):
  https://www.youtube.com/playlist?list=PLLo17ahM0Ask7n7g9uppPRPhhrRDB2UBP
* Developer: Corvostudio di Amadei Marco — https://corvostudio.it/other.php
* Nexus Mods is Cloudflare-blocked to automated access.
