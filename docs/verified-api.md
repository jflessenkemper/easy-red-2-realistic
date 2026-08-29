# Easy Red 2 — VERIFIED Lua API (mined from shipped scripts)

## OFFICIAL DOCS CROSS-CHECK (easyred2.com/wiki, 2026-08-09) — see forum-crosscheck.md
CONFIRMED by official docs (no code change needed):
- Callbacks all match: `soldier_died(victim)`, `soldier_suppressed(suppressed, shooter)`,
  `soldier_target_inf_acquired(attacker, target)`, `soldier_damaged(soldier, amount)` (NO shooter),
  `battle_ended(winner, forced)`. `er2.setCallback` OVERWRITES same-event; `resetCallback(id)`/`resetCallbacks()` exist.
- `me.getAiParams()` correct; `.aiParams` property invalid on v2.0.9. Toggles take a bool, DOT call. `enableAiBehaviour` is the master switch (set first).
- `global.set(value, key)` value-first; PRIMITIVES ONLY (bool/float/int/string), net-synced — never store a vec3/soldier (that is the UserData-in-global crash).
- `getSoldiersInArea(pos,r,table)` fills+returns distance-ordered; `getVehiclesInArea` fills (unordered).
- **`Objective:setAttractor(bool, faction)` is BOOL-FIRST** (matches our attraction manager) — steering arg order is correct.
- `spawnSquad_script(pos,radius,faction,squadId,scriptFile)` confirmed.

CORRECTED (code fixed):
- **`findCover(center, radius)` is a COMMAND that returns VOID** — it orders the soldier to move
  into cover; it does NOT return a cover position. We WRONGLY treated it as a query
  (`orderMove(coverNear(pos) or pos)`), which returned nil and then moveTo'd the soldier's CURRENT
  spot — countermanding the cover order. Now call `me.findCover(center, radius)` directly (throttled)
  and issue NO moveTo after it. This had broken ALL cover-in-place behaviour (PINNED/medic/support/fight).
- **`er2.explosion(pos, damage, penetration_mm, blast_radius_m)`** — arg3 = PENETRATION (mm), arg4 = RADIUS (m).
  Was passing (10,10); now explicit BARRAGE_PENETRATION/BARRAGE_BLAST.
- **`healSoldier(amount 0-100)` heals the soldier it is called ON** — to heal another: `target.healSoldier(amount)`.
  There is NO `healSoldier(target)`. (We don't call it yet; medic relies on `allowDoMedic`.)
- **`getSquad()`/`isSquadLeader()` are nil right after spawn** — poll `isSquadReady()` first (now done in the brain bootstrap; fixes leader detection).
- Factions are plain STRING ids (e.g. "Germany_axis"), not opaque handles — `tostring()` on them is a no-op, so nationFromFaction still works.

STILL UNCONFIRMED (needs a play-test):
- **Attraction is documented for "default AI" only** — vehicle/tank steering via setAttractor is NOT doc-confirmed. Must verify in-game that tanks actually advance/hold/push on objectives.
- `setBrain` folder: docs say `script/ai`; we deploy `scripts/AI` — but the earlier 33k-line run PROVES `scripts/AI` loads on this build, so empirically correct.
- Health scale: docs say getHealth "float"; damageSoldier/healSoldier are "0-100" -> 0..100 assumed.



## Faction handle strings (enables map-agnostic nation detection)
`tostring(er2.getInvadersFaction())` etc. yield "<Nation>_<alliance>" — observed:
"Germany_axis", "France_allies". So a soldier's nation is derivable from
`tostring(me.getFaction())` by substring match (SovietUnion, UnitedStates, UnitedKingdom,
Japan, Italy, Finland, Romania, Hungary, ...). Realistic.lua uses this so doctrine works on
ANY map, not just Germany-vs-France; unknown/modded nations fall back to a default profile.

## FORENSICS ROUND 2 (post play-test #2, 2026-08-08) — build v2.0.9
- **AiParams accessor is `me.getAiParams()` (a METHOD). The `.aiParams` PROPERTY THROWS**
  ("cannot access field aiParams of userdata<Lua_Soldier>"). Resolve once, getter-first,
  route toggles through a cached helper. (The property idiom in SDKFZ.lua is a different build.)
- **`log()` is EXPENSIVE**: each call = a reflection invoke + ~13-frame managed stack walk +
  ~1.1 KB to Player.log. Never log unthrottled inside the per-tick loop (one bug wrote 22 MB /
  44% of a 51 MB log). Dedupe guard logs; rate-limit per-tick chatter.
- **`er2.getPlayer()` is nil during the phase script's load** (it runs inside BattleManager.Start()
  before any soldier spawns). Resolve player side LAZILY + memoise, or the battalion labels invert.
- **`getSquad()` EXISTS but returns nil** for spawner-attached brains on v2.0.9 (8/8 BENCH probes);
  `isSquadLeader()` is therefore always false. No squad-identity API => feed is side-scoped, not
  squad-scoped; morale cannot use squad strength (use local force-ratio instead).
- **`soldier_damaged` does NOT carry the shooter** — the engine drops the attacker Soldier before
  any Lua callback (proven from death stacks). Only 1 soldier arg (the victim). Weapon attribution
  must come from soldier_suppressed / soldier_target_inf_acquired (side-filtered + TTL'd) or a
  nearest-enemy-at-death fallback; infer weapon from the killer's CLASS.
- Soldier methods CONFIRMED present (BENCH functions): carryBody, healSoldier, findCover, stop,
  damageSoldier, killSoldier, isIncapacitated, isCarried, isCarryingBody, getHealth (0..100),
  say, sayClip, getName, getClassName, alertFor, moveTo, forceTarget, getCurrentVehicle, setBrain.
  ABSENT: getId, dropBody, rescue, reviveSoldier.
- **`er2.getNearestObjective` / `getAllObjectives` / `findObjective` exist** (Lua_API binding table).
  getNearestObjective drives the road-march objective target. Vehicle has getFaction/getPosition.
- **Roads are NOT bound to Lua** (RoadSystem/RoadNetwork/Pathfinder are engine-internal only).
  Approximate road-following via terrain-flatness (engine flattens terrain under roads).
- `say(VoiceClip.<name>)` WORKS at runtime (react:* fired 1408x with zero guard errors); VoiceClip
  is userdata (not pairs-iterable) but indexes by member name.



## PLAY-TEST CONFIRMED on this build (v2.0.9), from [BENCH] output 2026-08-08
- **CRITICAL: a vec3 (UserData) CANNOT be stored in a global** — `global.set(vec3,key)`
  throws "Type 'UserData' is not allowed as global variable!" and aborts the script
  (it fired 192x and killed every brain at bootstrap). Store positions in LOCAL upvalues,
  or split into numeric x/z globals. Strings/numbers/bools in globals are fine.
- **`aiParams` property is MISSING** on v2.0.9 (SDKFZ.lua's `soldier.aiParams` no longer
  resolves). Brain guards it and also tries `me.getAiParams()`. Next probe confirms the
  real accessor; until then the brain relies on moveTo/forceTarget overrides (both work).
- Soldier methods CONFIRMED to EXIST (function): getUniqueId, getPosition, getFaction,
  isAlive, forceTarget, alertFor, moveTo, getSquad, isSquadLeader, isSquadReady,
  getCurrentVehicle, setBrain, getHealth, isIncapacitated, isCarried, isCarryingBody,
  getName, getClassName, stop, findCover, boardVehicle, leaveVehicle, damageSoldier,
  killSoldier, say, sayClip, carryBody, healSoldier.
- Soldier methods that DON'T exist here: getId, dropBody, rescue, reviveSoldier.
- **getHealth() is 0..100** (sample=100), not 0..1.
- **getClassName() returns clean PascalCase strings** e.g. "Rifleman" (so "Support"=MG works).
- Vehicle: getVehiclesInArea works (found 8), getNearestVehicle exists; Vehicle has
  getPosition/getFaction/getName/isEmpty/getUniqueId/playerIsInside (NOT getClassName/
  getHealth/isAlive). => advanceBehindArmour's v.getFaction()/v.getPosition() are valid.
- **VoiceClip is userdata, NOT pairs-iterable** (dump via Script Settings->Id tables in-game;
  the 52 names below came from the binary). say()/sayClip() exist -> me.say(VoiceClip.X) is the path.
- Faction handles: INV="Germany_axis", DEF="France_allies"; side detection via isSameFaction WORKS.
- **No death-weapon API** (only a lone "deathReason"): kill feed infers weapon from the
  KILLER'S class (Support->MG, Rifleman->rifle, ...). Attribution-by-name works via
  soldier_suppressed / soldier_target_inf_acquired (confirmed firing).
- Full callback catalog: soldier_spawned, soldier_spotted, soldier_damaged, soldier_suppressed,
  soldier_died, soldier_incapacitated, soldier_healed, soldier_rescued, soldier_surrendered,
  soldier_pose_changed, soldier_finished_order, soldier_target_inf_acquired,
  soldier_target_veh_acquired, soldier_target_lost, battle_ended, vehicle_*.



**Source of truth:** the 154 shipped mission scripts under
`.../Easy Red 2/Easy Red 2_Data/StreamingAssets/Missions/` (game v2.0.9,
Unity 2022.3.62f3, IL2CPP native Linux, MoonSharp Lua). Every entry below is
DEMONSTRATED in a shipped script with a file:line citation. Anything from the
handoff that is NOT here was NOT found in the corpus — treat as documented-only
(guard it).

Key reference files (read in full):
- `SHARED/gamemode_defend.lua` — sophisticated phase script (objectives, tickets, callbacks, main loop idiom).
- `SHARED/briefing.lua` — a real AI brain (leader filter, voice clip, per-player state).
- `ME_Nanking_8402g37b/scripts/ai/SDKFZ.lua` — a real COMBAT brain (aiParams, forceTarget, moveTo). **Closest template to Realistic.lua.**
- `ME_Kwajalein_181al3mz/scripts/mission/phase_0.lua` — scripted artillery barrage (er2.explosion + getTerrainHeight + coroutines).

## Built-in Lua prelude (recovered from global-metadata.dat @ ~228000-262000)
The engine ships a Lua prelude of GLOBAL wrappers (all coroutine-based on er2.*WithCallback):
- `spawnSoldier(pos, faction, rank, loadout)` -> Soldier   (loadout ''=default)
- `spawnSoldierOnVehicle(pos, faction, rank, loadout, veh)`
- `spawnSquad(pos, radius, faction, squad_id)` -> Squad
- `spawnSquad_script(pos, radius, faction, squad_id, script_file)` -> Squad WITH BRAIN attached
- `spawnSquadOnVehicle(pos, radius, faction, squad_id, veh)` / `..._script(...)`
- `spawnVehicle(vehicle_id, pos, rot)` / `spawnVehicle_camo(id,pos,rot,camoId)` / `_dest(...)`
- `spawnMissionObjective(pos, radius, text, icon, attractor)` -> Objective
- `sayMissionClip(soldier, clipName)` -> length  (calls soldier:sayMissionClipWithCallback)
- `print(msg[, time])`, `distance(a,b)`, `round(f,dp)`, `log(t)`, `sleep(t)`
- `waitUntil(condFn...)`, `waitForAny(condFn...)`  (poll every 0.5s)
=> **script-spawning IS possible** (these are engine-provided, absent from shipped scripts).
`faction` param = a faction value (use er2.getInvadersFaction()/getDefendersFaction()).
`squad_id` / `vehicle_id` / `loadout` = template ids (game/editor-specific; confirm in editor).
NOTE: "DLC vehicles/loadouts/squads not allowed yet in scripting" (engine error string) — base only.

## Soldier class + faction (for doctrine / MG-centric behaviour)
- `getClassName()` and `getClass()` exist (metadata). Class VALUE strings seen:
  **Support** (=the LMG/machine-gunner class, by far most-referenced), Rifleman, Assault,
  Sniper, Marksman, Medic, Officer, SquadLeader, Radioman, Bazooka/Panzerschreck (AT),
  Flamethrower, Scout. Exact getClassName() return casing -> confirm via bench_probe.
- Faction roster (nation value strings): Germany, UnitedStates, Soviet, Britain/UnitedKingdom,
  Japan, Italy, France, Finland, Romania, Hungary.
- Side detection (verified): `er2.isSameFaction(me.getFaction(), er2.getInvadersFaction())`.
  Nation string is not obviously accessible from a soldier -> Realistic.lua takes it as
  config (global realistic_nation_invaders/_defenders), defaulting germany/france for Stonne.

## Method-call syntax
BOTH work (MoonSharp userdata). `gamemode_defend.lua` uses COLON (`obj:getPosition()`);
`SDKFZ.lua` uses DOT (`soldier.getPosition()`). The handoff's "dot only" was incomplete.
**Convention chosen for our brain: DOT** (matches SDKFZ, the closest template).

## Globals (verified)
- `myself()` -> Soldier (nil-guard it: `local me=myself(); if not me then return end`). [SDKFZ:5, briefing:17]
- `vec3(x,y,z)`; fields `.x .y .z`. Press **P** in editor to copy a world pos. [Kwajalein:3,33]
- `distance(a, b)` -> number. [SDKFZ:44]
- `sleep(sec)`. [everywhere]
- `log(text)` -> F3 console + Player.log. `print(msg)` -> on-screen. [everywhere]
- `er2.explosion(vec3 pos, damage, r1, r2)` — used 47x. Barrage = loop of these. [Kwajalein:38]
- `er2.nuke(...)`. [rare]
- `spawnMissionObjective(pos, radius, name, iconId, bool)` -> Objective. [gamemode_defend:138]
- `sayMissionClip(soldierOrMe, "clip.wav")` -> length(sec); plays from mission `sounds/` folder; <=0 means load failed. **This is the real voice mechanism.** [briefing:99]
- `global.set(value, key)` / `global.get(key)` — value FIRST. Cross-phase + cross-client KV store. Can store a vec3. [SDKFZ:22, everywhere]
- `global.myplayerset(value, key)` / `global.myplayerget(key)` — per-player persistence. [briefing:73,113]
- `coroutine.*` — standard Lua coroutines usable (barrage pattern). [Kwajalein:43-51]

## er2.* (verified, with usage counts)
- `er2.run("file.lua")` — run script from `<MISSION>/scripts/general` (separate chunk; NOT killed on phase change). [43x]
- `er2.runEveryoneOnce(...)` [8x]
- `er2.isMasterClient()` -> bool (host gate). [39x]
- `er2.explosion` [47x], `er2.setTimeOfDay` [32x], `er2.destroyAll` [22x], `er2.setTimeAndWeather` [19x]
- `er2.timeScaled` [15x], `er2.time()` -> seconds [12x]
- `er2.setVictoryDefenders()` [8x], `er2.setVictoryInvaders()` [3x]
- `er2.synchWeather` [6x], `er2.getPlayer()` [6x]
- `er2.getCurrentPhaseId()` -> 0-based phase id [5x]
- `er2.isSameFaction(a, b)` -> bool [4x], `er2.getTerrainHeight(vec3(x,0,z))` -> groundY [4x]
- `er2.getInvadersFaction()` / `er2.getDefendersFaction()` -> faction. **Player = attacker = INVADERS.** [gamemode_defend:65-66]
- `er2.setTaskTextInvaders(locKey, paramsTable)` / `...Defenders` [3x each]
- `er2.resetCallback("id")` / `er2.resetCallbacks()` [3x/1x]
- `er2.getSoldiersInArea(centreVec3, radius, outTable)` — FILLS outTable; iterate with pairs/ipairs. [gamemode_defend:103, SDKFZ:33]
- `er2.findObjective(id)` -> Objective (id from o.getUniqueId()) [gamemode_defend:156]
- `er2.setPhase(n)` / `er2.nextPhase()` [gamemode_defend:256,268]
- `er2.countDeceasedDefenders()` -> int (battalion tally) [gamemode_defend:88]
- `er2.getSettingUnitCountMultiplier()` [1,3], `er2.getSettingTicketsMultiplier()` [gamemode_defend:73-74]
- `er2.setCallback("event", fn)` — OVERRIDES any previous callback on same id. [gamemode_defend:169]
- `er2.isOnline()`, `er2.setSnowing`, `er2.getTimeOfDayHour/Minute`, `er2.achievement` [rare]

## Soldier (verified — DOT in SDKFZ, COLON in briefing)
- `.getUniqueId()` -> stable id (**use this, not getId()**). [SDKFZ:6]
- `.aiParams` — PROPERTY (not a method). Returns AiParams. [SDKFZ:10]
- `.getPosition()` -> vec3. [SDKFZ:22]
- `.getFaction()`. [SDKFZ:36]
- `.isAlive()`. [SDKFZ:28]
- `.forceTarget(enemySoldier)`. [SDKFZ:37]
- `.alertFor(seconds)` — force alert state. [SDKFZ:38]
- `.moveTo(vec3)`. [SDKFZ:45]
- `.getSquad()` -> Squad or nil. [briefing:36]
- `.isSquadLeader()` -> bool. [briefing:36]
- `.isSquadReady()` -> bool. [briefing:32]
- `.getCurrentVehicle()` -> Vehicle or nil. [briefing:41]
- `.setBrain("relative/path.lua")` — path relative to the brain file. [briefing:11]
- `.setAnimatorController(id)` / `.setAnimatorBool(name, bool)`. [briefing:117-119]

## AiParams (verified — DOT, each takes a bool)  [SDKFZ:10-19]
`params = soldier.aiParams` then:
- `.enableAiBehaviour(bool)`
- `.allowMovements(bool)`
- `.allowFollowOrders(bool)`
- `.allowFindCoverWhenSuppressed(bool)`
- `.allowCheckForEnemies(bool)`
- `.allowBeingTargeted(bool)`
Handoff-listed but NOT demonstrated (guard before use): allowChangePose, allowDoMedic,
allowGiveOrders, allowLeaveVehicle, allowOpenWindows, allowRadioOrders,
followCustomDirectCommands, followCustomSquadOrders, setTargetPlanesOften.

## Vehicle + vehicle queries
- `.playerIsInside()` -> bool. [briefing:59]
- `getVehiclesInArea(pos, radius, outTable)` — CONFIRMED to exist (engine error string
  "Expected a table as 3rd parameter when calling 'getVehiclesInArea'"). Same shape as
  getSoldiersInArea, so almost certainly **er2.getVehiclesInArea**. Resolves handoff
  unknown #7 (guess "getVehiclesInRadius" was WRONG). Confirm namespace via bench_probe.
- `getNearestVehicle`, `getAllVehicles(table)` also exist (metadata @ 945922 / error string).
- Vehicle methods getFaction()/getPosition() assumed by parallel with Soldier — guarded.
- **Armour-as-cover IS a native AI behaviour:** engine has a `vehicleCovers`/`new_vehicleCovers`
  cover type (metadata @ 1140964/1141061) feeding GetCoveredPositionInArea + SendUnitsToCovers.
  Realistic.lua's advanceBehindArmour() layers on top: keeps nearest friendly vehicle between
  soldier and enemy while advancing under threat.

## Objective (verified)  [gamemode_defend]
- `.getPosition()` -> vec3, `.getRadius()` -> number, `.getUniqueId()` -> id.
- `.setProgress(0..0.99)` — 1.0 auto-triggers next phase, avoid.
- `.setIcon(n)` / `.setIconDefenders(n)`, `.setText(key)` / `.setTextDefenders(key)`.
- `.isAttractor(faction)` -> bool, `.setAttractor(bool, faction)` — **steers squad movement**.

## Callback signatures (verified)
- `er2.setCallback("soldier_died", function(soldier) ... end)` — 1 arg. [gamemode_defend:166-169]
- Overrides previous callback on same id; `er2.resetCallback("soldier_died")` to drop.

## Idioms
- **Brain skeleton:** `local me=myself(); if not me then return end` then a
  `while me.isAlive() do ... sleep(n) end` loop. [SDKFZ]
- **Per-soldier init-once:** guard with a uid-keyed global:
  `local k="init_"..me.getUniqueId(); if not global.get(k) then ... global.set(true,k) end`. [SDKFZ:7-24]
- **Leader-only logic in a brain (brain runs on every unit):**
  `if me.getSquad()~=nil and not me.isSquadLeader() then return end`. [briefing:36]
- **Phase script:** `#include "../../../SHARED/x.lua"` (single chunk, shares locals)
  vs `er2.run("x.lua")` (separate chunk). er2.run children survive phase change ->
  add a stale guard: `if er2.getCurrentPhaseId()~=MY_PHASE then return end`. [gamemode_defend:32-42,175]
- **Master-only work + run-once:** `if not er2.isMasterClient() then return end` +
  a boolean global guard. [Kwajalein:12-19]
- **Scripted fire support (CAS/artillery):** coroutine per target, loop
  `er2.explosion(vec3(x, er2.getTerrainHeight(vec3(x,0,z)), z), dmg, r, r)` over a
  random disc. **This is our Stuka/artillery substitute — verified, effect-only.** [Kwajalein:28-51]

## VoiceClip enum — COMPLETE (from global-metadata.dat @ byte 1160024-1160755)
Ordered, verbatim (52 members). HOW to say one is still guarded (handoff: `soldier.say(VoiceClip.X)`).
```
iVeBeenHit, imReloading, imUnderFire, AAAAAH, scream_long, yes, yesSir, watchYourFire,
enemyInfantrySpotted, enemyTankSpotted, enemyArtillerySpotted, enemyDown, thankYou,
coveringFire, imMoving, imCharging, iSurrender, imTakingTheLead, moveThere, attackThere,
attackThatTank, attackThatVehicle, followMe, letsSpreadOut, lineFormation, columnFormation,
timeToRetreat, getOut, getIn, letsMoveTank, fireTank, gunReloadedTank, enemyHittedTank,
enemyDestroyedtank, enemyMissedTank, enemyNotPenetratedTank, gotHitTank, radiomanIsDead,
gunnerIsDead, commanderIsDead, driverIsDead, illTakeHisSeat, getOutTankOnFire,
getOutTankDestroyed, numbers, artillerySupportAt, tankSupportRequest,
artilleryStrikeIncomingAt, keepYourHeadDown, noArtilleryAvailable, tankSupportIncoming,
noTankAvailable
```
Mapping used in Realistic.lua: scared="AAAAAH" (the agony scream = the fire/burn cry),
hit="iVeBeenHit", enemySpot="enemyInfantrySpotted", fallback="timeToRetreat".
No separate infantry "burning" clip exists; AAAAAH is the panic/agony scream.

## Radio support — ENGINE INTERNALS (from metadata @ ~1158000-1160755)
CAS/aircraft: **CONFIRMED IMPOSSIBLE** — support enum is artillery + armour ONLY
(artillerySupportAt, tankSupportRequest, noArtilleryAvailable, noTankAvailable; NO plane clip).
BUT a radioman + artillery/tank request system DOES exist in the engine (C# names):
HasRadioman, GetRadioman, GetMedic, CountMembers, TryAssignRadioOrder,
RadioRequestIsExplosiveArtillery, ThereAreActiveRadioOrders_Artillery/_Tanks,
radioRequestPosition, radRequestDuration. Squad-order internals also present:
SendUnitsToCharge, SendUnitsToCovers, SendUnitsToVehicle, GiveWaypointToUnits,
OrderLeaveVehicle, GetClosestNonSecuredMissionObjective, GetRandomNonSecuredMissionObjective.
=> the handoff's Squad order list (charge/coverArea/setClosestObjective) is plausibly real
(Lua-bound name casing may differ); confirm exact Lua names via bench_probe.lua Squad section.
Our Stuka = scripted er2.explosion barrage (RealisticEvents.lua) — correct, no plane API.

## STILL UNVERIFIED (bench_probe.lua settles these on this build)
- HOW to say a VoiceClip (say/sayClip method + whether VoiceClip is a Lua global).
- carry/drag/rescue, heal/revive — NO script API in corpus; base-AI automatic (aiParams.allowDoMedic).
- smoke on demand — none.
- getHealth scale, isIncapacitated, isCarried — undemonstrated; guarded.
- Squad roster enumeration + exact Lua order-method names — probe the Squad section.

## ENGINE BUG — do not subscribe to `soldier_suppressed` (v2.0.9) [VERIFIED IN-GAME]
Subscribing makes the engine throw on every bullet impact that has no attributable shooter:
```
Lua error at 'Global Callbacks' ... Object reference not set to an instance of an object.
LuaCallbackHandler:Call(String, Delegate, DynValue[])
Soldier:Suppress(Int32, Soldier)  <- Bullet:BulletDamage -> BulletInstance:OnHit
```
The NRE is raised inside the engine's own dispatch while marshalling a NULL Soldier argument,
i.e. BEFORE the Lua handler body runs — so `pcall`-wrapping the handler does NOT suppress it
(tested: 12 further errors after hardening). It fires on the projectile hot path.
**Mitigation: do not register a soldier_suppressed callback.** Use
`soldier_target_inf_acquired` (supplies attacker+target) plus a nearest-enemy-at-death
fallback for weapon attribution. Cost of ignoring this: continuous exceptions + ~1.1 KB of
stack trace per hit.

# ============================================================================
# API PROBE 2026-08-29 — in-game, phase-script context, live battle
# ============================================================================
# Method: one-shot probe in RealisticEvents.lua against a live soldier from
# er2.getAllSoldiers, its squad, and a vehicle from getVehiclesInArea. Members tested by
# INDEXING; read-only getters also CALLED for type + sample value. Mutators never called.

## *** MAJOR CORRECTION: getSquad() WORKS ***
Previously recorded as "returns nil for spawner-attached brains (8/8 probes)". That probe ran
inside a BRAIN. From the PHASE SCRIPT, against a soldier obtained via getAllSoldiers():
    getSquad() -> Lua_Squad   (a real object)
    getSquadSize() -> 2 · getAllMembers(t) FILLED 2 members
    hasAliveMembers() -> true · hasFullySpawned() -> true · hasObjective() -> true
    isPlayerInSquad() -> false
=> SQUAD IDENTITY AND ROSTERS ARE AVAILABLE. This invalidates the "no squad roster" limitation
   and everything built around it (proximity cohesion, clock-faked bounding, the WatchSquad
   marker, the drag "nearest man" election).
!! STILL TO CONFIRM: whether getSquad() also works from inside a BRAIN (the old nil result came
   from that context). Probe brain-side before deleting the proximity fallbacks.

## Soldier — ALL CONFIRMED present (function) and callable
isSuppressed() -> boolean          getSuppressionValue() -> number   (REAL suppression: replaces
                                                                      our enemy-proximity proxy)
isATSoldier() -> boolean           isMedic() -> boolean              isRadioman() -> boolean
isMarksman() -> boolean            isMechanic() -> boolean           hasRadio() -> boolean
isAmmoBoxCarrier() · isFlameThrowerCarrier()   (native role flags: replace getClassName strings)
isOnCover() -> boolean             (proof a cover order actually worked)
getVelocity() -> userdata (vec3)   getMoveDirection()   (in-game movement verification)
isMoving/isRunning/isCrawling/isCharging/isAiming/isReloading/isOnFire/isOutOfStamina/isAlerted
setPose · resetPose                (real prone/crouch)
surrender · isSurrendering · stopSurrendering      (FORCE-SURRENDER IS POSSIBLE)
carryBody · isCarryingBody · getCarriedBody · getNearestInjured   (wounded drag, target lookup
                                   built in; getNearestInjured -> nil when none, as expected)
incapacitate · stopIncapacitate · applyBleeding · isBleeding · setOnFire · killSoldier
containsItem · addNewItem · addMagazine · addAmmo   (inventory)
wearUniform · getUniformId · wearVest · wearHeadgear   (appearance)
getHealth() -> number = 100        getClassName() -> string, e.g. "Squad Leader"
jump · isPlayer · isAI · isInsideVehicle · getDistanceFromGround · getNearestVehicleToRepair

## Squad — ALL CONFIRMED except one
getAllMembers (FILLS a table) · getSquadSize · isPlayerInSquad · getLeader · getMedic ·
getRadioman · getMechanic · charge · coverArea · attackFromPoint · followLeader · holdFire ·
fireAtWill · alertEnemies · setClosestObjective · setRandomObjective · hasObjective ·
getObjectivePosition · getObjectiveRadius · hasAliveMembers · hasFullySpawned · addSoldier ·
removeSoldier · cancelRadioRequest · repairVehicle
**ABSENT: Squad.waypoint -> err** (it appears in the metadata as a PARAMETER name, not a method)
=> Squad-level tactical orders EXIST. "Formation orders impossible" was wrong for tactical
   orders; true line/column formation is still not exposed.

## Vehicle — ALL CONFIRMED
kickEveryoneOut · kickUnits · getPassengers · getDriver · getGunner · isDestroyed ·
isArtilleryVehicle · getDamage · getEngineDamage · getFueltankDamage · getTracksDamage ·
countPeopleInside · countEmptySeats · isEmpty · isFull · hasDriver · isDriverAlive · getName ·
repair · brake
Samples: getName() -> "Bofors 40mm L/60" · countPeopleInside() -> 2 · isArtilleryVehicle() ->
false · isDestroyed() -> false
!! Vehicle.getDamage() returned **250** — vehicle damage is NOT the 0..100 soldier scale.
   Treat it as raw HP; do not compare against soldier thresholds.
=> Crew bail-out is directly supported (kickEveryoneOut / getPassengers), no area scan needed.
=> Vehicle.getName() gives the armour-vs-truck filter we needed (Vehicle has no getClassName).

## Revised "not possible on this build"
IMPOSSIBLE (confirmed):  aircraft/CAS control · real road pathing from Lua
PARTIAL: smoke — smoke grenade ITEMS exist and addNewItem/containsItem can equip them, but
         nothing binds a throw; base AI decides when to use them.
NOW POSSIBLE (was wrongly listed impossible): squad rosters · squad tactical orders ·
         force-surrender · real suppression · pose control · native role flags

## BRAIN-CONTEXT CONFIRMATION (2026-08-29, 371 soldiers, live battle)
`getSquad()` WORKS FROM THE BRAIN TOO. Per-soldier ONLINE probe:
    squad=yes  315 soldiers (sizes 1..9 — real rosters)
    squad=NIL   56 soldiers
The NILs are a TIMING artefact, not a context limit: the bootstrap isSquadReady() poll caps at
3 s, and a soldier probed at the instant of spawn has no squad yet. FIX: re-resolve the squad
lazily inside the tick loop instead of once at bootstrap; do not treat nil as permanent.
=> The old "no squad identity on this build" limitation is RETRACTED. Rosters, squad orders and
   isPlayerInSquad are all usable from the brain.

## NATIVE ROLE FLAGS CONFIRMED — replace getClassName string matching
Measured distribution over one battle (clean and correct):
    264 plain rifleman (all flags false)
     42 isSquadLeader   31 isMedic   14 isRadioman   12 isATSoldier   8 isMarksman
These are language-proof and mod-proof, unlike substring matching on getClassName (which also
had an ordering hazard: isCrew matched "tank" and would swallow a "Tank Hunter" class).
ACTION: switch isMG/isMortar/isMedic/isAT/isRadio/isLeader detection to the native flags;
keep a getClassName fallback only for Support-gunner/mortar, which have no native flag.

## 2026-08-29 — `global` IS shared between a brain and the phase script (PROVEN)

**Question:** the brain (client-local, one Lua context per soldier) writes `global.set(...)`; the
phase script runs on the MASTER CLIENT. Are those the same global store? The whole `RQ_*` integer
fire-mission protocol (feature 19) depends on it, and it had never been proven.

**Probe:** brain writes `global.set(4242, "PROBE_B2P")` once at boot; phase script logs what it
reads every 30 loop cycles.

```
[EVENTS] gprobe: RQ_T=-1 PROBE_B2P=nil    <- immediately after phase load, no brain booted yet
[EVENTS] gprobe: RQ_T=-1 PROBE_B2P=4242   <- after brains booted: the value IS visible
```

**CONFIRMED: shared.** A brain-written global is readable by the master-client phase script. The
`RQ_*` protocol is architecturally sound. `RQ_T=-1` in both samples simply means no fire mission
was pending at those instants — the consumer clears it within one cycle, so a 30-cycle sampler
will almost never catch a live request.

**Still integers/strings/booleans ONLY.** This says globals CROSS contexts; it does NOT relax the
UserData ban, which is a separate and still-fatal rule.

## 2026-08-29 — SMOKE ON DEMAND IS ⛔ NOT SCRIPTABLE (probed, not assumed)

**What the engine has.** `global-metadata.dat` contains `RequestArtilleryHE`,
`RequestArtilleryAPHE`, **`RequestArtillerySMOKE`**, `RequestArtillerySMOKE_AsRadioman`,
`OnSmokeAccepted`, `marker_request_artillerySmoke`, and item strings `smokeGrenade` /
`SmokeGrenade` / `smokeGranade` / `VirtualSmokeGrenade`. So a radioman-called smoke SCREEN
plainly exists inside the game.

**What Lua can reach: none of it.** An in-game probe indexed 15 candidate spellings on `er2`,
`Soldier` and `Squad` — `RequestArtillerySMOKE`, `requestArtillerySmoke`,
`RequestArtillerySMOKE_AsRadioman`, `RequestArtilleryHE`, `TryAssignRadioOrder`,
`requestSmoke`, `requestArtillery`, `RequestAmmoDrop` and case variants. **Zero were present.**
The artillery-request system is engine-internal and unbound.

**Equipping is not a workaround.** `containsItem("smokeGrenade")` returns `false` cleanly (so the
method works and takes a string), but a `false` cannot distinguish "valid item, not carried" from
"invalid identifier". Even if `addNewItem` did equip one, **nothing binds a THROW** — base AI
alone decides when to use smoke. Scripting *who carries* smoke is not the same as scripting
*smart smoke usage*, and shipping it as the latter would be a lie.

**Conclusion:** smoke stays ⛔. The honest substitute already in the mod is the scripted
`er2.explosion` barrage (feature 19), which is HE, not smoke.
