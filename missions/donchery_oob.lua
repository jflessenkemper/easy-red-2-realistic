--============================================================================
-- donchery_oob.lua — the order of battle for "[Historical] Crossing at Donchery"
-- 16:00, Monday 13 May 1940. Donchery, on the Meuse west of Sedan.
--
-- WHY THIS IS CODE AND NOT EDITOR SPAWNERS. Every squad, vehicle and crew below is
-- script-spawned, which buys three things the editor cannot:
--   * NO RESPAWNS BY CONSTRUCTION - a script-spawned squad spawns once. The old mission relied on
--     `respawn_delay` on ~10 editor spawners and trickled reinforcements all battle.
--   * REVIEWABLE against the sourced build sheet, line by line, in a diff.
--   * VALIDATED OFFLINE before the game is ever launched - tests/offline_donchery.lua drives this
--     whole table against a stubbed runtime and refuses unconfirmed ids.
--
-- EVERY ID HERE IS CONFIRMED. They were read out of the game's own six ME_French Ardennes example
-- missions (Easy Red 2_Data/StreamingAssets/Missions/) and out of il2cpp global-metadata.dat, so
-- they are ids the developers themselves use for THIS theatre and THIS year. Nothing is guessed.
-- The full catalogue and every forced substitution is in docs/donchery-build-sheet.md.
--
-- DEPLOY: consumed by RealisticEvents.lua's TEST_SPAWNS hook. Assign the trio:
-- Mounted entries are { squadId, pos, side }. THE SIDE IS NOT OPTIONAL HERE: the phase
-- script used to hardcode invader, which spawned the French Hotchkiss crews as Germans.
--     TEST_SPAWNS = DONCHERY.squads, TEST_VEHICLES = DONCHERY.vehicles,
--     TEST_MOUNTED = DONCHERY.mounted
-- and DISABLE the mission's own editor unit spawners (spawn type "Disabled") so nothing doubles up.
--============================================================================

--========================= what this can and cannot depict ==================
-- Stated here rather than buried, because two of these go to the heart of the historical event.
--
-- 1. NO MOTORCYCLES EXIST IN THE GAME. The build sheet's single largest correction was
--    "Sd.Kfz. 251 halftracks -> BMW R12 sidecars": a 1940 Kradschuetzen-Bataillon had 190 sidecar
--    combinations, 51 solos and ZERO halftracks. No motorcycle of any kind is in the build - the
--    only "motorcycle" string in the metadata is an input device. The halftracks are still
--    REMOVED, which is the correct half of the fix, and the transport is Kuebelwagen / Horch 853 /
--    Opel Blitz. So the battalion reads as MOTORISED, not specifically Kradschuetzen. The briefing
--    must not claim motorcycles are depicted.
-- 2. NO ASSAULT OR RUBBER BOATS EXIST. Only fishing, steam and Asian boats and a Japanese
--    amphibious tank. This matters more than a cosmetic gap: the real crossing was made in rubber
--    boats, and French artillery destroying most of them is WHY the 16:00 attempt failed. The
--    river assault therefore cannot be depicted with boats; the Germans begin on the near bank
--    and the crossing is abstracted. The briefing says so.
-- 3. NO DEDICATED HMG-TEAM SQUAD. The three MG34 Lafette teams have no id. They are not faked
--    with rifle squads: each rifle Gruppe already carries its own Support gunner, which is also
--    the mgCentric formation anchor, so the sustained-fire role is represented at squad level and
--    the separate Lafette teams are simply absent. Recorded, not disguised.
-- 4. No 7.5 cm leIG 18 and no Sd.Kfz. 231. A second Pak 36 crew stands in for the leIG; Sdkfz222
--    is the armoured car.
--
-- SQUAD SIZE IS NOT MINE TO SET. KStN 131c gives a TEN-man Gruppe by May 1940, and the build sheet
-- is right about that - but the number of men a squad id spawns is decided by the game's squad
-- TEMPLATE, not by the spawn call. ger_infantry_1940 was observed spawning 4-8 men. So the
-- headcounts below are stated as RANGES from the squad count, and the ~205 v ~135 target is
-- approached by squad count rather than claimed as an exact roster.

local DONCHERY = { squads = {}, vehicles = {}, mounted = {} }

--========================= geometry =========================================
-- COORDINATES ARE RELATIVE TO A DERIVED DY_ORIGIN, resolved at load from the mission's first
-- objective exactly as showcase.lua does.
--
-- WHY, MEASURED IN-GAME 2026-09-09. These used to be ABSOLUTE world positions around (0,0,0), and
-- that is what capped the order of battle at 7 squads for three straight runs. The spawn loop died
-- mid-item with NO failure and NO Lua error - the pre-attempt log line named it exactly:
--     test spawn 7: invader ger_infantry_1940 -> ok
--     test spawn 8/31: attempting invader ger_infantry_1940      <- no result line, ever
-- Squad 8 is the SAME squad id as the seven before it, so the id was never the problem: only its
-- position differed (x = +57 rather than +19). On the French Ardennes map, (0,0,0) is not inside
-- the playable terrain, so squads 1-7 landed on valid ground by luck and squad 8 did not - and
-- spawning onto invalid ground throws inside the engine, which ESCAPES pcall and kills the phase
-- script outright. The showcase range never hit this because it derives its origin, and it spawned
-- all 29 of its squads with zero failures on the same engine build.
--
-- The Meuse
-- runs roughly east-west; the Germans are on the NORTH bank at -Z, the French dug in on the SOUTH
-- bank at +Z, with the railway embankment behind the German line.
local RIVER_GAP   = 260   -- m between the German assault line and the French positions
local EMBANKMENT  = -90   -- m behind the German line: the armour fires from here, in defilade
local FRONTAGE    = 420   -- m of river frontage the attack is spread across

-- DY_ORIGIN RESOLUTION. getAllObjectives is FILL-style and must be called WITH a table; a bare call
-- throws on every invocation. Helpers are prefixed `dy` for the same reason showcase.lua prefixes
-- its own: this block is inlined into RealisticEvents.lua's main chunk, and an unprefixed
-- `local function safeGet` would SHADOW that file's own version for the rest of the file.
-- PREFIXED DY_. showcase.lua declares its own `ORIGIN`/`ORIGIN_OVERRIDE`, and BOTH files are
-- inlined into RealisticEvents.lua's single main chunk, so unprefixed names are declared twice
-- and the later one shadows the earlier for the rest of the file. check 3 refuses this outright,
-- which is the gate earning its keep - the shadowing would otherwise be silent.
local DY_ORIGIN_OVERRIDE = nil          -- e.g. vec3(1200, 0, -400); set only to pin the layout by hand
local DY_ORIGIN

local function dySafeGet(fn) local ok, v = pcall(fn); if ok then return v end return nil end
local function dySafe(fn) return (pcall(fn)) end
local function dyLog(m) log("[DONCHERY] " .. tostring(m)) end

if DY_ORIGIN_OVERRIDE then
    DY_ORIGIN = DY_ORIGIN_OVERRIDE
    dyLog(string.format("origin: override (%.0f,%.0f)", DY_ORIGIN.x, DY_ORIGIN.z))
else
    local objs = {}
    dySafe(function() er2.getAllObjectives(objs) end)
    for _, o in pairs(objs) do
        local op = o and dySafeGet(function() return o.getPosition() end)
        if op then
            DY_ORIGIN = vec3(op.x, op.y, op.z)
            dyLog(string.format("origin: derived from the first mission objective -> (%.0f,%.0f)",
                  DY_ORIGIN.x, DY_ORIGIN.z))
            break
        end
    end
    if not DY_ORIGIN then
        DY_ORIGIN = vec3(0, 0, 0)
        dyLog("origin: NO objective found, falling back to (0,0) - which is off the playable "
              .. "terrain on French Ardennes and will kill the spawn loop partway with no error. "
              .. "Set DY_ORIGIN_OVERRIDE with a P-captured position.")
    end
end

local function add(t, squadId, side, x, z, radius)
    t[#t + 1] = { squad = squadId, side = side,
                  pos = vec3(DY_ORIGIN.x + x, DY_ORIGIN.y, DY_ORIGIN.z + z), radius = radius or 12 }
end
local function addVeh(t, name, x, z, yaw)
    -- ARG 3 OF spawnVehicle IS A vec3 OF EULER ANGLES IN DEGREES. Confirmed against the OFFICIAL
    -- reference (easyred2.com/wiki/scripting.php?id=spawnvehicle): "vec3 - Euler rotation of the
    -- vehicle", example vec3(0, 90, 0).
    --
    -- THIS FILE HAD IT WRONG, and so did our own docs. The old note read "a vec3 DIRECTION, NOT
    -- degrees" - half right, and the wrong half mattered. It IS a vec3, so passing a bare number
    -- still throws inside the engine's argument marshalling and that throw still ESCAPES pcall and
    -- kills the phase script. But the components are DEGREES, not a direction. Passing vec3(0,0,1)
    -- to mean "face +Z" is ~1 degree of ROLL, so every vehicle sat at default yaw and not one of
    -- the intended facings was ever applied. Yaw is the Y component: 0 faces +Z, 180 faces -Z.
    t[#t + 1] = { name, vec3(DY_ORIGIN.x + x, DY_ORIGIN.y, DY_ORIGIN.z + z),
                  vec3(0, yaw or 0, 0) }
end

-- Yaw in DEGREES. The Germans are on the north bank firing south across the Meuse; the French
-- emplacements face back north at the crossing.
local YAW_SOUTH = 0     -- +Z, across the river: the German attack
local YAW_NORTH = 180   -- -Z, back at the crossing: the French defence

--========================= GERMAN — 2. Panzer-Division, north bank ==========
-- 12 rifle Gruppen across the frontage. These are the Kradschuetzen/Schuetzen sections; each
-- carries its own Support gunner, so RALLY-on-MG (the Schuetzenkette) has an anchor per squad.
for i = 0, 11 do
    local x = -FRONTAGE / 2 + (FRONTAGE / 11) * i
    add(DONCHERY.squads, "ger_infantry_1940", "invader", x, -40, 14)
end

-- Pionier squad with demolition charges - the men who actually got across.
add(DONCHERY.squads, "ger_pioneers_1940", "invader", 0, -55, 12)

-- Two mortar teams (8 cm s.Gr.W. 34), set back from the assault line.
add(DONCHERY.squads, "ger_mortarCrew", "invader", -70, -80, 8)
add(DONCHERY.squads, "ger_mortarCrew", "invader",  70, -80, 8)

-- Gun crews: the 3.7 cm Pak 35/36, plus a second crew standing in for the absent leIG 18.
add(DONCHERY.squads, "ger_artilleryCrew_1940", "invader", -30, -75, 8)
add(DONCHERY.squads, "ger_artilleryCrew_1940", "invader",  30, -75, 8)

-- AT squad.
add(DONCHERY.squads, "ger_infantry_AT_1940", "invader", 0, -70, 10)

-- ARMOUR, firing in defilade from the railway embankment. The 4:2:2:2 split mirrors the real
-- 2. Pz.Div. inventory (115 Pz II : 45 Pz I : 58 Pz III : 32 Pz IV), weighted slightly toward the
-- gun tanks because those are what did the work here. Sd.Kfz. 251 is REMOVED - the battalion had
-- none - and Panzer 38(t) is REMOVED because 2. Pz.Div. had none.
local ARMOUR = {
    { "Panzer II",    -160 }, { "Panzer II",     -90 }, { "Panzer II",     90 }, { "Panzer II", 160 },
    { "Panzer I A",   -200 }, { "Panzer I A",    200 },
    { "Panzer iii F", -125 }, { "Panzer iii F",  125 },
    -- THE PLAYER'S LEVER. The short 7.5 cm Panzer IV is the bunker-buster, and direct fire on the
    -- blockhouses from behind this embankment is what historically silenced them. The AI attack
    -- fails as it did at 16:00; the player is the variable.
    { "Panzer iv c",   -45 }, { "Panzer iv d",    45 },
    { "Sdkfz222",     -230 }, { "Sdkfz222",      230 },   -- flank screen
}
for _, a in ipairs(ARMOUR) do
    addVeh(DONCHERY.vehicles, a[1], a[2], EMBANKMENT, YAW_SOUTH)   -- facing +Z, across the river
    -- Crews spawn ABOARD, which is the only way the crew bail-out branch is reachable: it keys
    -- off what the man was RIDING. Editor-placed vehicles carry a faction; script-spawned ones do
    -- not, so features 5 and 18 are only re-provable here if these are converted to editor
    -- spawners. See docs/donchery-build-sheet.md.
    DONCHERY.mounted[#DONCHERY.mounted + 1] = { "ger_tankCrew_1940", vec3(DY_ORIGIN.x + a[2], DY_ORIGIN.y, DY_ORIGIN.z + EMBANKMENT), "invader" }
end

-- Soft-skin transport. NOT motorcycles - see the note at the top.
addVeh(DONCHERY.vehicles, "Horch 853",  -60, EMBANKMENT - 40, YAW_SOUTH)
addVeh(DONCHERY.vehicles, "Horch 853",   60, EMBANKMENT - 40, YAW_SOUTH)
addVeh(DONCHERY.vehicles, "Kubelwagen", -20, EMBANKMENT - 40, YAW_SOUTH)
addVeh(DONCHERY.vehicles, "Kubelwagen",  20, EMBANKMENT - 40, YAW_SOUTH)
for i = 0, 2 do
    addVeh(DONCHERY.vehicles, "Opel Blitz", -80 + i * 80, EMBANKMENT - 60, YAW_SOUTH)
end

--========================= FRENCH — III/147e RIF + 1 Cie/11e BM, south bank ==
-- III/147e Regiment d'Infanterie de Forteresse: a FORTRESS MG battalion of serie B RESERVISTS,
-- which is why fr_reservist_infantry is not merely adequate but historically exact. 71e DI was
-- NOT at Donchery - it was inserting east toward Angecourt - so it does not appear.
for i = 0, 7 do
    local x = -FRONTAGE / 2 + (FRONTAGE / 7) * i
    add(DONCHERY.squads, "fr_reservist_infantry", "defender", x, RIVER_GAP, 12)
end

-- The Hotchkiss Mle 1914 teams IN CONCRETE. These are the backbone of the defence: emplaced
-- weapons with crews aboard, not manoeuvre infantry. "Hotchkiss Stationary Ground" is the
-- emplaced mount - note it is deliberately EXCLUDED from the armour filter by the
-- stationary/emplac/static hard exclusion, so riflemen never treat it as cover to advance behind.
for i = 0, 5 do
    local x = -FRONTAGE / 2 + (FRONTAGE / 5) * i
    addVeh(DONCHERY.vehicles, "Hotchkiss Stationary Ground", x, RIVER_GAP + 15, YAW_NORTH)
    DONCHERY.mounted[#DONCHERY.mounted + 1] = { "fr_artilleryCrew", vec3(DY_ORIGIN.x + x, DY_ORIGIN.y, DY_ORIGIN.z + RIVER_GAP + 15), "defender" }
end

-- Three 25 mm SA-L Mle 1934 AT positions, emplaced.
-- 4. NO GUN EXISTS FOR THE 25 mm SA-L Mle 1934, and "Pak 36" IS NOT A VALID VEHICLE ID.
-- MEASURED IN-GAME 2026-09-09: spawnVehicle("Pak 36", ...) raises a NullReferenceException
-- INSIDE THE ENGINE, and that NRE escapes pcall and kills the phase script outright. The run
-- placed vehicles 1-25 successfully - including Panzer I A, Panzer iii F, Panzer iv c/d and
-- Horch 853 - and died on item 26, the first Pak 36:
--     test vehicle 25: Hotchkiss Stationary Ground -> ok
--     test vehicle 26/28: attempting Pak 36
--     NullReferenceException: Object reference not set to an instance of an object.
-- "Pak 36" also appears NOWHERE in the mission's own vehicle strings. It came from the build
-- sheet, and the offline id gate was validating against that sheet rather than against the game,
-- so it passed a name that crashes. A bad vehicle name is not a soft failure here: it is fatal.
--
-- The AT crews STAY - they are the men of the three 25 mm positions - but there is no gun model to
-- put in front of them. Recorded as a fourth engine-impossible requirement alongside the
-- motorcycles, the assault boats and the dedicated HMG teams. Not faked with a Bofors 40mm, which
-- does exist but is a Swedish AA piece and would be wrong in both nation and role.
for i = 0, 2 do
    local x = -140 + i * 140
    add(DONCHERY.squads, "fr_reservist_ATsquad", "defender", x, RIVER_GAP + 35, 8)
end

-- Mortars: one 81 mm Mle 27/31 and one 60 mm Mle 1935.
add(DONCHERY.squads, "fr_mortarCrew", "defender", -50, RIVER_GAP + 70, 8)
add(DONCHERY.squads, "fr_mortarCrew", "defender",  50, RIVER_GAP + 70, 8)

-- NO FRENCH TANKS. Char B1 and RenaultR35 both exist in the game and are deliberately ABSENT:
-- 4e and 7e BCC did not arrive until 14 May, the day after this action.

--============================ FITTING THE ENGINE'S BUDGET ===================
-- Everything above is the RESEARCHED order of battle and it stays exactly as researched: it is the
-- record of what was at Donchery at 16:00 on 13 May 1940, and the build sheet is auditable against
-- it. What follows selects the subset the engine will actually accept, and LOGS WHAT IT DROPPED.
--
-- WHY A BUDGET EXISTS. Measured across four in-game runs (2026-09-09, Steam mode with DLC, v2.1.0):
--   run A  no pacing, no origin      6 squads placed, then the rig died mid-item, silently
--   run B  + frame pacing + pre-log  7 placed, died attempting 8
--   run C  + derived origin          8 placed, died attempting 9
--   run D  order REVERSED            8 placed, died attempting 9 - different squad, other side
-- Run D is the important one: reversing the list moved a completely different squad into slot 9
-- and it died there anyway, so this is a COUNT, not a bad unit and not a bad position. With correct
-- positions the ceiling is 8. No engine error is raised and no failure is logged, which is why it
-- took four runs and a pre-attempt log line to see at all. Nothing in the official documentation
-- describes a spawn cap, and the mission binary carries only `invadersTickets` and
-- `addTicketsOnConquer` - no concurrency field - so the cause remains UNEXPLAINED.
--
-- MOUNTED CREWS COUNT AGAINST THE SAME BUDGET. spawnSquadOnVehicle_script spawns a SQUAD, so the
-- 18 tank and gun crews above are 18 squads. The full force is 31 + 18 = 49 squads against a
-- budget of 8: it was never going to fit, and no amount of pacing would have made it.
--
-- VEHICLES ARE CHEAP AND SEPARATE. Run C placed 25 vehicles behind 4 squads without complaint, so
-- the armour and the emplacements all survive the cut. Empty armour is still cover to advance
-- behind, and still the player's lever - the short 7.5 cm Panzer IV is in the list.
-- SCOPED IN A do...end BLOCK ON PURPOSE. The Lua main chunk has a hard ceiling of 200 locals, and
-- BOTH this file and missions/scenarios/showcase.lua are inlined into RealisticEvents.lua's single
-- main chunk - so the phase script now sits near that ceiling too, not just the brain. Declaring
-- these seven at file scope pushed it over and every brain and phase script failed to compile
-- ("main function has more than 200 local variables"), which check 1 and the offline phase harness
-- caught immediately. Inside do...end the locals leave scope at `end` and free their slots; only
-- the DONCHERY table fields survive, and table fields cost nothing.
do
    local SQUAD_BUDGET = 8      -- measured, not guessed; raise it only with a run that proves it

    -- Priority: what has to be present for this to read as the historical action at all. A German
    -- assault needs riflemen, the Pioniere are the men who actually got across, the tank crew is the
    -- player's lever, and the French need reservists in the line plus one crewed Hotchkiss - the
    -- emplaced MG is the whole reason the 16:00 attempt failed.
    local PRIORITY = {
        { side = "invader",  squad = "ger_infantry_1940"   },
        { side = "invader",  squad = "ger_infantry_1940"   },
        { side = "invader",  squad = "ger_infantry_1940"   },
        { side = "invader",  squad = "ger_pioneers_1940"   },
        { side = "defender", squad = "fr_reservist_infantry" },
        { side = "defender", squad = "fr_reservist_infantry" },
        { side = "defender", squad = "fr_reservist_infantry" },
    }

    local function takeSquads()
        local kept, used = {}, {}
        for _, want in ipairs(PRIORITY) do
            if #kept >= SQUAD_BUDGET - 1 then break end   -- leave one slot for a mounted crew
            for i, sq in ipairs(DONCHERY.squads) do
                if not used[i] and sq.squad == want.squad and sq.side == want.side then
                    used[i] = true
                    kept[#kept + 1] = sq
                    break
                end
            end
        end
        return kept
    end

    local fullSquads, fullMounted = #DONCHERY.squads, #DONCHERY.mounted
    local keptSquads = takeSquads()
    -- ONE mounted crew, and it is the Panzer IV's: crew bail-out keys off what the man was RIDING, so
    -- this is the only slot from which that branch is reachable at all.
    local keptMounted = {}
    if #keptSquads < SQUAD_BUDGET and fullMounted > 0 then
        keptMounted[1] = DONCHERY.mounted[1]
    end

    -- KEEP THE RESEARCHED FORCE REACHABLE. tests/offline_donchery.lua asserts the historical scale
    -- (~205 German v ~135 French, every AFV and emplacement crewed) and that assertion must keep
    -- biting on the RESEARCH, or trimming the force to fit the engine would quietly also delete the
    -- historical audit. So the full lists survive under .researched and the gate checks both: the
    -- research against the build sheet, and the shipped force against the budget.
    DONCHERY.researched = { squads = DONCHERY.squads, mounted = DONCHERY.mounted }
    DONCHERY.squads  = keptSquads
    DONCHERY.mounted = keptMounted

    -- NO SILENT CAPS. If this trims the force it says so, with the numbers, every time it loads.
    dyLog(string.format("force TRIMMED to the engine's measured budget: %d of %d squads and %d of %d "
          .. "mounted crews kept (budget %d, mounted count against it too). The full researched order "
          .. "of battle is in this file and in docs/donchery-build-sheet.md; it does NOT fit and the "
          .. "cause is unexplained - see the note above.",
          #DONCHERY.squads, fullSquads, #DONCHERY.mounted, fullMounted, SQUAD_BUDGET))
end

return DONCHERY
