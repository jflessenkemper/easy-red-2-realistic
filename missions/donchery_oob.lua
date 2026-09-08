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
-- ORIGIN is derived at load from the mission's first objective, exactly as showcase.lua does, so
-- no coordinate has to be captured by hand and the layout travels with the mission. The Meuse
-- runs roughly east-west; the Germans are on the NORTH bank at -Z, the French dug in on the SOUTH
-- bank at +Z, with the railway embankment behind the German line.
local RIVER_GAP   = 260   -- m between the German assault line and the French positions
local EMBANKMENT  = -90   -- m behind the German line: the armour fires from here, in defilade
local FRONTAGE    = 420   -- m of river frontage the attack is spread across

local function add(t, squadId, side, x, z, radius)
    t[#t + 1] = { squad = squadId, side = side, pos = vec3(x, 0, z), radius = radius or 12 }
end
local function addVeh(t, name, x, z, dirx, dirz)
    -- ARG 3 OF spawnVehicle IS A vec3 DIRECTION, NOT DEGREES. A number throws inside the engine's
    -- own argument marshalling and the throw ESCAPES pcall, killing the phase script outright.
    t[#t + 1] = { name, vec3(x, 0, z), vec3(dirx or 0, 0, dirz or 1) }
end

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
    addVeh(DONCHERY.vehicles, a[1], a[2], EMBANKMENT, 0, 1)   -- facing +Z, across the river
    -- Crews spawn ABOARD, which is the only way the crew bail-out branch is reachable: it keys
    -- off what the man was RIDING. Editor-placed vehicles carry a faction; script-spawned ones do
    -- not, so features 5 and 18 are only re-provable here if these are converted to editor
    -- spawners. See docs/donchery-build-sheet.md.
    DONCHERY.mounted[#DONCHERY.mounted + 1] = { "ger_tankCrew_1940", vec3(a[2], 0, EMBANKMENT) }
end

-- Soft-skin transport. NOT motorcycles - see the note at the top.
addVeh(DONCHERY.vehicles, "Horch 853",  -60, EMBANKMENT - 40, 0, 1)
addVeh(DONCHERY.vehicles, "Horch 853",   60, EMBANKMENT - 40, 0, 1)
addVeh(DONCHERY.vehicles, "Kubelwagen", -20, EMBANKMENT - 40, 0, 1)
addVeh(DONCHERY.vehicles, "Kubelwagen",  20, EMBANKMENT - 40, 0, 1)
for i = 0, 2 do
    addVeh(DONCHERY.vehicles, "Opel Blitz", -80 + i * 80, EMBANKMENT - 60, 0, 1)
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
    addVeh(DONCHERY.vehicles, "Hotchkiss Stationary Ground", x, RIVER_GAP + 15, 0, -1)
    DONCHERY.mounted[#DONCHERY.mounted + 1] = { "fr_artilleryCrew", vec3(x, 0, RIVER_GAP + 15) }
end

-- Three 25 mm SA-L Mle 1934 AT positions, emplaced.
for i = 0, 2 do
    local x = -140 + i * 140
    add(DONCHERY.squads, "fr_reservist_ATsquad", "defender", x, RIVER_GAP + 35, 8)
    addVeh(DONCHERY.vehicles, "Pak 36", x, RIVER_GAP + 40, 0, -1)   -- stands in for the 25 mm
end

-- Mortars: one 81 mm Mle 27/31 and one 60 mm Mle 1935.
add(DONCHERY.squads, "fr_mortarCrew", "defender", -50, RIVER_GAP + 70, 8)
add(DONCHERY.squads, "fr_mortarCrew", "defender",  50, RIVER_GAP + 70, 8)

-- NO FRENCH TANKS. Char B1 and RenaultR35 both exist in the game and are deliberately ABSENT:
-- 4e and 7e BCC did not arrive until 14 May, the day after this action.

return DONCHERY
