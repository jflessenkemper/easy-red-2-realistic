# ER2 Lua API — Official-docs cross-check (v2.0.9)

Cross-check of our reverse-engineered API assumptions against the **official** Easy Red 2
scripting docs at easyred2.com/wiki, plus community sources. Engine confirmed = **MoonSharp**.
Every function on our checklist exists in the official API index (verified against the full
function listing on `scripting.php`). Method/arg details quoted below with URLs.

Confidence labels: **[DOC]** = quoted from official docs · **[REPO]** = confirmed by our own
shipped scripts · **[INFER]** = reasoned, not explicitly documented.

---

## Sources

Fetched OK:
- https://easyred2.com/wiki/ — wiki hub / index
- https://easyred2.com/wiki/scripting.php — full API function index (all categories)
- https://easyred2.com/wiki/scripting_callbacks.php — callbacks list + arg table
- https://easyred2.com/wiki/guide.html — scripting guide (execution model, phase vs AI scripts)
- Per-function pages via `scripting.php?id=<name>`: getaiparams, setcallback, resetcallback,
  resetcallbacks, set, get, getclassname, gethealth, setbrain, setattractor, isattractor,
  getsoldiersinarea, getvehiclesinarea, getnearestobjective, getallobjectives, sleep,
  spawnsquad, spawnsquad_script, findCover, explosion, getplayer, getinvadersfaction,
  isSameFaction_global, getsquad, getFaction, getterrainheight, enableaibehaviour,
  allowmovements, say, alertfor, carrybody, healsoldier, setCallback_soldier, moveTo,
  forcetarget, getcurrentvehicle, damage.
- Web search: Steam news V1.4.10 scripting-system announcement; Nexus "AI Tweaks"; general
  MoonSharp GitHub/error-type pages.

404 / wrong target / not found:
- `scripting.php` / `scripting_callbacks.php` / `guide.html` are the real pages; the
  bare `/wiki/scripting` and `/wiki/guide` in the hub are redirects to the `.php`/`.html` forms.
- Steam guide id=3336229318 ("Understanding Lua Errors") turned out to be a **Tabletop
  Simulator** guide, NOT Easy Red 2 — discard it. No ER2-specific "Lua errors" guide found.
- No forum/Reddit/Discord page surfaced the verbatim string
  `"Type 'UserData' is not allowed as global variable"` for ER2 (see Gotchas).

Local ground-truth grepped: `the mod's own *.lua sources`
(Realistic.lua, RealisticEvents.lua, WatchSquad.lua, bench_probe.lua, bench_watch.lua).

---

## Confirmed

### Callbacks
- **Registration** — `er2.setCallback(eventId, fn)` (global), `Soldier.setCallback(eventId, fn)`,
  `Vehicle.setCallback(eventId, fn)`. Soldier/Vehicle variants return **bool** ("True if the
  callback was correctly set"). [DOC ?id=setcallback, ?id=setCallback_soldier]
- **Overwrite semantics (item 8)** — CONFIRMED. "Only a callback can be tied to an event Id, so
  when this is called again on the same Id, the new callback reference will override previous
  one." [DOC ?id=setcallback]
- **resetCallback / resetCallbacks exist (item 8)** — `er2.resetCallback(string)` → bool ("Unassign
  a callback by it's Id", "True if the callback was correctly unassigned"); `er2.resetCallbacks()`
  → void ("Unassign all global callbacks"). Soldier/Vehicle-scoped variants also exist
  (`resetCallback_soldier`, `resetCallbacks_soldier`, plus vehicle forms). [DOC]
- **soldier_died (item 1)** — `fn(Soldier)` — the victim only. [DOC callbacks table]
- **soldier_suppressed (item 2)** — `fn(Soldier suppressed, Soldier shooter)` — arg order
  (suppressed, shooter) CONFIRMED. [DOC callbacks table]
- **soldier_target_inf_acquired (item 3)** — `fn(Soldier acquiring, Soldier target)` i.e.
  `(attacker, target)`. CONFIRMED. (Vehicle target variant is a separate event
  `soldier_target_veh_acquired(Soldier, Vehicle)`.) [DOC callbacks table]
- **soldier_damaged (item 4)** — `fn(Soldier, number damage)`. **Does NOT carry a shooter.**
  CONFIRMED — corroborated by `damageSoldier` having no source arg (see below). [DOC]
- **soldier_incapacitated / _rescued / _surrendered (item 5)** — each `fn(Soldier)`, one arg. [DOC]
- **battle_ended (item 6)** — `fn(string winningFaction, bool forced)` = `(winner, forced)`.
  CONFIRMED. [DOC]
- **Full valid event list (item 7)** [DOC callbacks table]:
  `battle_ended`, `phase_changed(number,number)`, `soldier_damaged`, `soldier_died`,
  `soldier_finished_order(Soldier,string)`, `soldier_incapacitated`, `soldier_pose_changed(Soldier,number)`,
  `soldier_rescued`, `soldier_spawned`, `soldier_spotted(Soldier,Soldier)`, `soldier_suppressed`,
  `soldier_surrendered`, `soldier_target_inf_acquired`, `soldier_target_lost(Soldier)`,
  `soldier_target_veh_acquired(Soldier,Vehicle)`, `squad_created(Squad)`,
  `squad_leader_changed(Squad,Soldier)`, `squad_ready(Squad)`, and the full `vehicle_*` family
  (`vehicle_damaged_engine/_fueltank/_hull/_wheels/_wing`, `vehicle_destroyed`, `vehicle_disabled`,
  `vehicle_entered(Vehicle,Soldier,number)`, `vehicle_exited(Vehicle,Soldier)`, `vehicle_loose_parts`,
  `vehicle_loose_wing`, `vehicle_repaired`, `vehicle_seat_changed(Vehicle,Soldier,number)`,
  `vehicle_spawned`).
- **Soldier-scoped callbacks drop the implicit soldier arg** — the docs' soldier-scoped section
  says callbacks "mirror global events... (soldier removed as it's implicit)", e.g. a soldier-scoped
  `soldier_damaged` receives only the damage amount; the `setCallback_soldier` example reads the
  subject via `myself()`. [DOC — medium confidence; args not individually tabulated per soldier event]

### AiParams (items 9-10)
- **Obtain via `me.getAiParams()` — CONFIRMED; `me.aiParams` property is NOT valid on v2.0.9.**
  Docs list only the method `Soldier.getAiParams()` → returns `AiParams` ("Reference to the AI
  parameters management class. If soldier is not an AI ... returns Nil"); there is **no** `aiParams`
  property in the API index. [DOC ?id=getaiparams] Our own `bench_probe.lua`/`Realistic.lua` confirm:
  "the .aiParams PROPERTY throws on v2.0.9; the getter works". [REPO]
- **All 8 toggles take a bool** — `enableAiBehaviour(bool)`, `allowMovements(bool)`,
  `allowFollowOrders(bool)`, `allowFindCoverWhenSuppressed(bool)`, `allowCheckForEnemies(bool)`,
  `allowBeingTargeted(bool)`, `allowDoMedic(bool)`, `allowChangePose(bool)` — all present in the
  AiParams index, each param "Set the AI functionality enabled". [DOC]
- **`enableAiBehaviour` is a master switch**: it "enables or disables all AI functionalities
  together, including: allowChangePose, allowCheckForEnemies, allowFindCoverWhenSuppressed,
  allowLeaveVehicle, allowMovements, allowOpenWindows, allowOrders and allowRadioOrders". So calling
  it flips the whole group — set it FIRST, then the individual overrides after. [DOC ?id=enableaibehaviour]
- **Call form** — official examples use **dot** notation on the chain:
  `myself().getAiParams().allowMovements(false)` and `...getAiParams().enableAiBehaviour(false)`.
  [DOC] See Gotchas re dot-vs-colon (MoonSharp accepts both; our WatchSquad.lua hedges with pcall).

### Soldier methods (items 11-12)
- `moveTo(vec3)` — CONFIRMED, "Moves the soldier to a specified position..."; example
  `soldier.moveTo(vec3(10,0,5))`. [DOC ?id=moveTo]
- `forceTarget(target)` — CONFIRMED. "Force a Soldier to target a specific Soldier **or Vehicle**."
  Arg may be a Soldier, a Vehicle, or **nil** (to clear). Returns bool ("True if a correct target
  (or nil) was given"). [DOC ?id=forcetarget]
- `findCover(vec3 center, float radius)` — CONFIRMED present. Return value = **void** (it's a
  command, not a query — does NOT return a position). Example `soldier.findCover(vec3(20,0,10), 5.0)`.
  [DOC ?id=findCover]
- `stop()`, `alertFor(float seconds)` ("Puts the soldier in an alert state for a defined time"),
  `getCurrentVehicle()` → Vehicle or **null** if not aboard, `getSquad()` → Squad,
  `isSquadLeader()`, `getUniqueId()`, `getPosition()`, `isAlive()`, `isIncapacitated()` — all
  CONFIRMED present with the expected shapes. [DOC]
- `getFaction()` → **string** faction ID ("Gets the soldier's faction ID"). [DOC ?id=getFaction]
- `carryBody(Soldier)` — CONFIRMED. "Force the soldier to carry a[nother] incapacitated soldier."
  Arg is the target body. [DOC ?id=carrybody]
- `say(VoiceClip, float)` — CONFIRMED it takes a **VoiceClip enum** (see enum table
  `scripting.php?type_id=20`), NOT a string, plus a float second arg. [DOC ?id=say]
- `getUniqueId()` int is the canonical cross-client handle — resolve back with `er2.findSoldier(id)`
  / `er2.findVehicle(id)`. [DOC ?id=set]

### er2 / globals (items 13-18)
- `er2.getSoldiersInArea(vec3 pos, float radius, Table out)` — CONFIRMED out-param. "fills the Table
  given as parameter with the found soldiers, indexing it from 1..n ordered by distance ... **and
  returns the filled table**." So it BOTH fills the passed table and returns it. [DOC ?id=getsoldiersinarea]
- `er2.getVehiclesInArea(vec3 pos, float radius, Table out)` — CONFIRMED out-param; "Vehicles are
  inserted in a non precise[d] order"; return type **void** (only fills the table — do not rely on a
  return value here, unlike the soldiers variant). [DOC ?id=getvehiclesinarea]
- `er2.getNearestObjective(vec3 pos [, float maxDist=100] [, bool includeNonAttractor=true])` →
  `Objective`. Position is **required**; 2nd arg optional max search dist (defaults 100m); 3rd
  optional bool controlling whether non-attractor scriptable objectives are included. [DOC ?id=getnearestobjective]
- `er2.getAllObjectives(Table out [, bool excludeNonAttractor=true])` — fills an out-table, returns
  **void**. Optional 2nd bool "exclude Scriptable Mission Objectives that have been set to
  non-attractor" (default includes all). [DOC ?id=getallobjectives]
- `Objective:setAttractor(bool, string faction?)` — CONFIRMED arg order (**bool first**, optional
  faction id second; nil/empty = all factions). "default AI will try to reach and fight inside the
  area." [DOC ?id=setattractor] Our RealisticEvents.lua uses exactly this:
  `o.setAttractor(invAttract, INV)` / `o.isAttractor(INV)`. [REPO]
- `Objective:isAttractor(string faction?)` → bool. Optional faction; empty/Nil = "for at least a
  faction". [DOC ?id=isattractor]
- `er2.isSameFaction(string a, string b)` → bool — "Check if two faction Ids are part of the same
  faction (Allies or Axis)". Takes two **faction-id strings**. [DOC ?id=isSameFaction_global]
  (A soldier-scoped `Soldier.isSameFaction` also exists.)
- `er2.getInvadersFaction()` / `er2.getDefendersFaction()` — each returns a **string** faction Id.
  [DOC ?id=getinvadersfaction]
- `er2.getTerrainHeight(vec3)` → float, "terrain height from sea level of the given x and z
  coordinates". [DOC ?id=getterrainheight]
- `er2.getPlayer()` → Soldier, "Null if any" — CONFIRMED it **can be nil** (docs' own example
  guards with `not (er2:getPlayer() == nil)`). On a dedicated/headless master client there is no
  local player, so expect nil there. [DOC ?id=getplayer]
- `global.set(value, key)` — **CONFIRMED value-first order.** "Set a global variable that can be
  referenced from any script and by any player in the room"; net-synchronised. Accepted types:
  **bool, float, int, string only**. Example `global.set(100, "some_stored_integer")`. Our
  WatchSquad.lua uses `global.set(true, "realistic_watch_active")`. [DOC ?id=set][REPO]
- `global.get(key)` — CONFIRMED. Takes the string key, returns the value (bool/float/int/string)
  or **nil** if never set. [DOC ?id=get]
- **Storing UserData in globals is forbidden (item 18)** — CONFIRMED via the set docs: only
  bool/float/int/string are accepted; "Complex objects like vehicles and soldiers cannot be stored
  directly — only their unique IDs ... then retrieved and resolved using er2.findVehicle() /
  er2.findSoldier()." So store `getUniqueId()` (int), not the object/vec3. [DOC ?id=set]

### Base / spawning (items 19-20)
- `sleep(float seconds)` — CONFIRMED. "Pause the execution of the LUA script for some time";
  examples `sleep(3)`, `sleep(0.01)` (=10ms); "very helpful to give some pause to the CPU,
  especially during 'while' and 'for' loops." A phase script running a `while ... sleep()` loop is
  the **documented, recommended** pattern. [DOC ?id=sleep, guide.html]
- `spawnSquad(vec3 pos, float radius, string faction, string squadId)` → Squad. [DOC ?id=spawnsquad]
- `spawnSquad_script(vec3 pos, float radius, string faction, string squadId, string scriptFile)`
  → Squad. CONFIRMED arg order (pos, radius, faction, squadId, scriptFile); "Spawn an AI squad and
  assign a script to each AI." [DOC ?id=spawnsquad_script] (Vehicle variants: `spawnSquadOnVehicle`,
  `spawnSquadOnVehicle_script`.)
- `Soldier.damageSoldier(float 0-100)` — CONFIRMED "between 0 and 100", and **no shooter/source
  arg** (confirms soldier_damaged carries no shooter). [DOC ?id=damage]

---

## Contradicted (FIX NEEDED)

1. **`er2.explosion` — 3rd argument is PENETRATION (mm), NOT a second radius.** (item 17)
   - Assumed: `explosion(pos, damage, r, r)` (two radii).
   - Docs: `er2.explosion(vec3 position, float maxDamage, float maxPenetration_mm, float radius)`
     — "Maximum penetration capacity (mm)" is param 3; there is exactly **one** radius (param 4).
     [DOC ?id=explosion]
   - Our code: `RealisticEvents.lua:231` → `er2.explosion(vec3(x,y,z), BARRAGE_DAMAGE, 10, 10)`.
     This currently means **penetration = 10 mm, radius = 10 m** — not "radius 10, radius 10".
     If the intent was a blast radius, the effective radius is only the 4th arg (10 m here). Decide
     the intended penetration deliberately (10 mm is low — barely defeats light cover; raise it if
     the barrage should hurt armoured/entrenched targets) and set the radius independently.
   - Confidence: **[DOC] high.**

2. **`healSoldier` takes a heal AMOUNT (float 0-100), not a target soldier.** (item 11)
   - Assumed: `healSoldier(target)` — heal some other soldier passed as arg.
   - Docs: `Soldier.healSoldier(float 0-100)` — "Heals soldier of a certain amount." It heals the
     soldier the method is invoked on. To heal a specific medic-target, call it **on that object**:
     `target.healSoldier(amount)`. There is no "target" parameter. [DOC ?id=healsoldier]
   - Blast radius: LOW — repo only names `healSoldier` in a probe list, not in live logic, so no
     shipped call is wrong yet. But fix the mental model before wiring the medic behaviour.
   - Confidence: **[DOC] high.**

3. **`setBrain` folder path — docs say `"/script/ai/"`, we deploy to `<mission>/scripts/AI/`.** (item 12)
   - Docs: brain lua "must be placed in `/script/ai/`" (singular "script", lowercase "ai"), filename
     ending `.lua`, or `"Default"`. [DOC ?id=setbrain]
   - We use `<mission>/scripts/AI/` (plural "scripts", uppercase "AI"). The `setBrain("Realistic.lua")`
     *filename-only* call form is correct [DOC][REPO WatchSquad.lua], but the **folder name differs**.
     On a case-insensitive FS "AI" vs "ai" is harmless, but `scripts` vs `script` is a *different
     directory* and would make the brain fail to load.
   - ACTION: verify the exact folder on a working deployed mission. If brains currently load from
     `scripts/AI/`, the docs are stale/loose; if they silently fall back to Default, the folder is
     wrong. Do not assume — confirm on disk in-game.
   - Confidence: **medium** (single doc source; the summariser quoted `/script/ai/` twice, but we
     have no in-game confirmation either way).

4. **Faction values are plain STRINGS, not "handles that stringify".** (item 16)
   - Assumed: getInvadersFaction/getDefendersFaction "return a faction handle that stringifies like
     Germany_axis".
   - Docs: they return a **string** Id directly; `getFaction()` returns a **string**; `isSameFaction`
     takes two **strings**. So don't `tostring()` them or treat them as objects — compare strings
     directly. [DOC ?id=getinvadersfaction, ?id=getFaction, ?id=isSameFaction_global]
   - Blast radius: NONE in shipped code — Realistic.lua/RealisticEvents.lua already treat factions as
     bare strings and compare via `isSameFaction`. Listed here only to correct the assumption's wording.
   - The exact string format (e.g. `"Germany_axis"`) is NOT stated in docs — see Not-found. Faction
     Ids come from Script Settings → Id tables. Confidence: **[DOC] high** (that they're strings).

---

## Not found in docs

- **`getClassName` return strings (item 11).** Docs: `Soldier.getClassName()` → string "the soldier's
  class name", but the **enumeration of possible values is NOT listed** on that page. Our own
  `bench_probe.lua` is itself probing for these (expects "Rifleman/Support/Assault/Medic/..."), and a
  community discussion mentions classes Squad Leader / Rifleman / Marine / AT / Tanker — so treat the
  exact strings as **unverified**. Recommend: log `getClassName()` in-game once and pin the real
  strings; do case-insensitive substring matches (as Realistic.lua already does with `:lower()`)
  rather than exact equality. Confidence in the specific strings: **low.**
- **`getHealth` numeric range (item 11).** Docs: `Soldier.getHealth()` → "float", **range unspecified.**
  Strong indirect evidence for **0-100**: both `damageSoldier` and `healSoldier` are documented as
  "between 0 and 100". [INFER, medium] Our `bench_probe.lua` still runs a runtime scale-probe
  (">1 => 0..100, <=1 => 0..1"), i.e. we haven't hard-confirmed it either — keep that probe until a
  live sample settles it.
- **Coroutine model beyond `sleep` (item 19).** Docs describe `sleep()` + while-loops as the pattern
  and never expose a coroutine API. There is **no documentation** of creating your own child
  coroutines or how to drive them (resume-once vs per-tick). Mechanism is implicit: each phase/AI
  script behaves as its own coroutine that yields at `sleep()`. Rolling your own `coroutine.*` is
  undocumented and unverified — avoid relying on it. Confidence: **[INFER].**
- **`math.random` per-brain seeding (item / gotcha).** No ER2 doc mentions seeding at all. Standard
  Lua `math.random`/`math.randomseed` are presumably available (MoonSharp), but there is **no official
  guidance** and no confirmation that brains are auto-seeded differently per instance. See Gotchas.
- **Verbatim `"Type 'UserData' is not allowed as global variable"`** — not found in any ER2 doc or
  forum page. It's a **MoonSharp engine** error, not an ER2-documented one. The ER2-documented
  equivalent is the `global.set` "primitives only" restriction. See Gotchas.
- **master-client note on `er2.setCallback` specifically** — the callbacks page says nothing about
  where callbacks fire; the execution model comes from guide.html (see Gotchas).

---

## Gotchas / holes discovered

1. **Master-client vs local execution (from guide.html — quote-backed).**
   - Phase scripts: "When playing offline, your machine runs all the scripts. In online matches, the
     phase script runs on the **master client only**." And: "If the master client leaves, a new one is
     assigned and the phase script will **run from the beginning** on that machine." → Phase scripts
     MUST be idempotent; guard already-done work with `global.set/get` flags (docs explicitly
     recommend this; our WatchSquad.lua already does `global.set(true, "realistic_watch_active")`).
   - AI/brain scripts: "AI scripts run **locally on the owner's machine**", BUT "AI squads are
     ultimately managed by the master client — including their Lua scripts", and "If a player leaves
     ... their units (and associated scripts) transfer to the master client, where the scripts will
     **restart**." → A brain can restart mid-life under a new owner; don't assume one-shot init state
     survives an ownership handover — persist anything critical via `global` or re-derive it on start.

2. **`global` only holds primitives — the real "UserData is not allowed" fix.** You cannot put a
   Soldier/Vehicle/vec3 into `global.set` (or, at the MoonSharp level, into a plain Lua global). Store
   `getUniqueId()` as an int and re-resolve via `er2.findSoldier(id)`/`er2.findVehicle(id)`. This is
   the documented pattern and matches the MoonSharp "not allowed as global variable" restriction the
   assumption referenced. Also: **spread vec3 as separate x/z floats** if you must persist a position.

3. **`math.random` desync/repeat risk is real but undocumented.** Because every brain instance runs
   the *same* Lua file locally, if brains rely on `math.random` without a per-instance seed they can
   all make the same "random" choice (e.g. identical cover pick / identical jitter). ER2 gives no
   seeding guidance. Recommendation (INFER, not doc-backed): seed per-brain from something unique like
   `getUniqueId()` (+ a time component) at brain start — `math.randomseed(me.getUniqueId() + math.floor(time()*1000))`
   — rather than trusting a shared default seed. Verify `time()`/`timeScaled` availability (both are in
   the er2 index) since `os.time` may be sandboxed out.

4. **Dot-vs-colon calling is genuinely fuzzy.** Official examples use **dot** throughout
   (`soldier.moveTo(...)`, `getAiParams().allowMovements(false)`, `o.setAttractor(...)`), which works
   because MoonSharp binds the instance for registered userdata; colon (`me:getAiParams()`) also works.
   Our WatchSquad.lua hedges: `if not pcall(function() me.setBrain(...) end) then pcall(function() me:setBrain(...) end)`.
   That belt-and-braces pattern is fine to keep, but the docs' canonical form is **dot** — standardise
   on dot to match examples unless a specific call proves otherwise.

5. **`getSquad` can be unavailable right after spawn (confirms the spawner-attached nil gotcha).**
   Docs: "The squad might not be available immediately after a soldier is spawned, so make sure to wait
   for it to be ready." So a brain that calls `getSquad()` on its first tick for a script-spawned unit
   can get nil — poll with `isSquadReady()` / retry-with-sleep before using the squad. [DOC ?id=getsquad]

6. **`getVehiclesInArea` returns void (fill-only) and is UNORDERED**, whereas `getSoldiersInArea`
   returns the filled table AND is distance-ordered. Don't assume vehicle[1] is nearest, and don't
   rely on a return value from the vehicles variant — read the table you passed in.

7. **Objective attraction is documented only for "default AI" infantry behaviour.** `setAttractor`
   says "**default AI** will try to reach and fight inside the area." The docs do NOT state it steers
   **vehicles** specifically (item 15's "incl. vehicles" is unconfirmed). If vehicle steering is
   needed, test it explicitly; don't assume attractors move armour. Also note the non-attractor flag
   on `getNearestObjective`/`getAllObjectives` only affects **Scriptable** objectives — attraction/
   enumeration logic keys off the objective being a scriptable/mission-objective type.

8. **Performance:** the only official perf note found is on `sleep` ("give some pause to the CPU,
   especially during while/for loops") and that weather changes are CPU-intensive. No documented log
   rate-limit or script sandbox size limit was found — but keep `while true` loops behind a `sleep`
   (even `sleep(0.01)`), which the docs insist on.

9. **`getPlayer()` is nil on headless/master.** On a dedicated server or when the script runs on a
   master client that isn't a local player, `er2.getPlayer()` returns nil — guard every use (docs' own
   example does). Don't anchor mission logic on the local player existing.

---

### One-line status
Most assumptions hold. **Real fixes:** `explosion` arg3 = penetration(mm) not radius (RealisticEvents.lua:231);
`healSoldier(amount 0-100)` not `healSoldier(target)`; verify the `setBrain` folder (`script/ai` vs our
`scripts/AI`). Factions are plain strings (code already correct). Health scale and `getClassName` strings
remain doc-unspecified — keep the runtime probes.
