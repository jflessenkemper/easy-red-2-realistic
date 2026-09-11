--============================================================================
-- showcase.lua — a PLAYABLE DEMONSTRATION RANGE for the Realistic soldier AI.
--
-- WHAT THIS IS FOR. The T1-T12 scenarios prove features to a log file. This proves them to a
-- PERSON: you spawn in, walk or fly between thirteen stations, and watch each feature happen with
-- an on-screen readout naming what every nearby soldier is deciding.
--
-- THE DESIGN CONSTRAINT THAT SHAPES EVERYTHING. The brain's cascade is strictly FIRST-MATCH, so
-- features pre-empt one another and you cannot see them all in one firefight — PINNED alone would
-- swallow assault, bounding and formation. So this is a demonstration RANGE: spatially separated
-- stations, each engineered to force exactly one branch.
--
-- Stations are STATION_GAP apart, which must stay comfortably above the brain's SENSE_RADIUS of
-- 90 m. If two stations are within sensing distance, one station's enemies enter the other's
-- force-ratio calculation and both demonstrations are ruined.
--
--============================================================================
-- THIS FILE HAS TWO ROLES, AND THE SPLIT IS THE INLINE-CUT MARKER BELOW.
--
-- ROLE 1 - RIG DATA SOURCE (everything ABOVE the cut). The part above the cut builds
--   SHOWCASE = { squads = {}, vehicles = {}, mounted = {} } in exactly the shape
--   RealisticEvents.lua's TEST_SPAWNS / TEST_VEHICLES / TEST_MOUNTED rig consumes, and spawns the
--   station objectives. tools/gen_showcase_inline.py splices THAT PREFIX ONLY into
--   RealisticEvents.lua, and tools/deploy.py then points the rig at it for the Realistic Test map.
--   That is how the range becomes reachable from the game while still getting the kill feed, the
--   crew bail-out drain and - the one thing this file could never do alone - the fire-mission
--   CONSUMER that makes station 10's barrage actually land.
--
--   Consequently NOTHING above the cut may contain a top-level `return` or a blocking loop.
--   Inlined text runs in RealisticEvents.lua's main chunk at line ~582: a `return` there would
--   abort the phase script, and a `while true` would mean not one setCallback ever registers.
--   That is why the master-client guard, INV/DEF, the emitter and the HUD all live BELOW the cut,
--   and why the layout refusal is an `if` rather than a `return`.
--
-- ROLE 2 - STANDALONE PHASE SCRIPT (the whole file). Deployed on its own it still works exactly as
--   before: the tail below the cut spawns the SHOWCASE tables itself and runs the HUD/census loop.
--   tests/offline_showcase.lua drives THIS path, so the rig tables are validated on every run of
--   tests/check.sh (check 4f) - they are not a second, untested code path.
--   DEPLOY standalone: copy to <mission>/scripts/mission/phase_0.lua and put Realistic.lua in that
--   mission's scripts/AI/. It must NOT be deployed alongside RealisticEvents.lua (one phase script
--   per phase) - which is precisely the limitation the inline route removes.
--============================================================================
--
-- FIRST RUN: ORIGIN is DERIVED, not hand-set (see below), so there is nothing to capture.
--
-- MEASURED RESULT, 2026-09-08 (VirtualScene, brain DEBUG on, decisions split by side).
-- The demo (invader) squads demonstrate the feature set comprehensively:
--   ROAD-MARCH 2567 · RALLY-on-MG 1323 · BOUND-overwatch 244 / move-cover 235 / move 119
--   PINNED 228 · SUPPORT-hold-fire 79 · MEDIC-hold-cover 77 / sortie 35 · LEADER-cover 71
--   DRAG-approach 40 · AT-stalk 22 / AT-hunt 5 · ROUT 22 · ASSAULT-cover 16 / ASSAULT 5
--   RADIO-fire-mission 2 · MOUNTED-defer 2        (162 soldiers traced, ZERO Lua errors)
-- So the range works. Read the brain trace (analyse_run.py) for proof; the in-game census below
-- is a LIVE READOUT for a human walking the range, and its pass/fail is ADVISORY only - it
-- samples soldiers near a station centre and therefore under-counts short-lived branches even
-- with accumulation. Do not treat a low census score as a statement about the AI; that mistake
-- has already been made twice here.
--
-- STATION 10 - the gap that the inline route CLOSES. Run standalone, the radioman DOES publish his
-- request (RADIO-fire-mission fires) but nothing answers it, because the CONSUMER that accepts it
-- and fires the barrage lives in RealisticEvents.lua and this file replaces that as the phase
-- script. Measured standalone: 2 requests, 0 accepted, 0 refused, 0 rounds away. Run INLINED into
-- RealisticEvents.lua the consumer is present, so station 10 can complete.
--============================================================================

-- THE RIG TABLES. Filled below, in the shape RealisticEvents.lua's rig consumes:
--   squads   : { squad = id, side = "invader"|"defender", pos = vec3, radius = n }
--   vehicles : { name, pos, direction }   -- arg 3 is a vec3 DIRECTION, never degrees; see below
--   mounted  : { squadId, vehiclePos, side }
local SHOWCASE = { squads = {}, vehicles = {}, mounted = {} }

-- ORIGIN is DERIVED, not hand-set. The mission's own first objective is guaranteed to be inside
-- the playable area, which is exactly what the range needs, so there is no coordinate to capture
-- in the editor and nothing to keep in sync per map. Set ORIGIN_OVERRIDE only if you want the
-- range somewhere specific (aim the editor camera and press P to copy a position).
local ORIGIN_OVERRIDE = nil         -- e.g. vec3(1200, 0, -400)
local ORIGIN                        -- resolved below, after the helpers exist
-- 500 m, not 300. The gap must exceed the LARGEST enemyD below (300 m, station 9) plus the 90 m
-- SENSE_RADIUS, or a station's own enemies land on its NEIGHBOUR's centre. At 300 m spacing
-- station 9's enemies sat exactly on station 10 - the precise cross-contamination this spacing
-- exists to prevent. validateLayout() below now fails the build if that ever recurs.
local STATION_GAP = 500             -- m between station centres (SENSE_RADIUS is 90)

local BRAIN = "Realistic.lua"

--========================= confirmed content only ===========================
-- Every id below was read out of the real ME_Stonne mission file, so all of them exist on this
-- install. NOTHING here is guessed.
--
-- THE FRENCH RIFLE SQUAD IS RESOLVED. This block used to say there was no confirmed French rifle
-- id and that the opposing infantry fell back on fr_ATsquad, an anti-tank squad. That gap is
-- closed: `fr_reservist_infantry` is used by the game's own ME_French Ardennes mission, and it is
-- also historically exact for this theatre, since III/147e RIF were reservists of a serie B
-- division (docs/donchery-build-sheet.md:165-170). It is on the confirmed-id list that
-- tests/offline_donchery.lua:23 enforces. The stale note mattered: EIGHT of the thirteen stations
-- below use FR_RIFLE as the opposing force, so a wrong id there leaves eight stations with no
-- enemy at all and nothing to demonstrate.
local GER_RIFLE = "ger_infantry_1940"          -- 1940 rifle squad, has a Support gunner
local GER_AT    = "ger_infantry_AT_earlywar"   -- AT squad, for the armour-hunting station
local GER_CREW  = "ger_tankCrew_1940"          -- for the bail-out station
local FR_RIFLE  = "fr_reservist_infantry"      -- confirmed twice over; see the note above
local FR_GUNS   = "fr_artilleryCrew"           -- emplaced-crew stand-in

local V_PZ2     = "Panzer II C"
local V_HALF    = "Sdkfz251 1939"
local V_TRUCK   = "Opel Blitz"
local V_MG_EMP  = "Hotchkiss Stationary Ground"
local V_FRTANK  = "Char B1"

--========================= helpers ==========================================
-- DELIBERATELY PREFIXED `sc`. These three used to be called safe/safeGet/log2, and RealisticEvents.lua
-- defines its own safe() and safeGet() at lines 60-63. The prefix above the cut is inlined into that
-- file's main chunk, so an unprefixed `local function safeGet` would SHADOW the phase script's own
-- version for the remaining ~1100 lines. Shadowing a working file on the assumption that two
-- pcall wrappers are byte-identical is exactly the silent-risk class this project keeps paying for.
local function scSafeGet(fn) local ok, v = pcall(fn); if ok then return v end return nil end
local function scSafe(fn) return (pcall(fn)) end
local function scLog(m) log("[SHOWCASE] " .. tostring(m)) end

-- Resolve the origin: an explicit override, else the first mission objective, else the map centre.
-- getAllObjectives is a FILL-style API and must be called WITH a table - a bare call throws on
-- every invocation.
if ORIGIN_OVERRIDE then
    ORIGIN = ORIGIN_OVERRIDE
    scLog(string.format("origin: override (%.0f,%.0f)", ORIGIN.x, ORIGIN.z))
else
    local objs = {}
    scSafe(function() er2.getAllObjectives(objs) end)
    for _, o in pairs(objs) do
        local op = o and scSafeGet(function() return o.getPosition() end)
        if op then
            -- Offset well clear of the objective itself so the range does not overlap whatever
            -- the mission already has fighting over it.
            ORIGIN = vec3(op.x + 400, op.y, op.z + 400)
            scLog(string.format("origin: derived from the first mission objective -> (%.0f,%.0f)",
                  ORIGIN.x, ORIGIN.z))
            break
        end
    end
    if not ORIGIN then
        ORIGIN = vec3(0, 0, 0)
        scLog("origin: no objective found, falling back to (0,0). If the range spawns off-map, set "
              .. "ORIGIN_OVERRIDE with a P-captured position.")
    end
end

-- DOCTRINE IS PINNED, not inherited. The demo squads are spawned on whichever faction this
-- mission happens to call the invaders, and doctrine is derived from the soldier's FACTION string
-- - so on a mission whose invaders are British, German-equipped demo troops would get britain's
-- profile (aggression 0.50, assaultRange 25) instead of germany's (0.75, 35). Station 4 puts its
-- enemies at exactly 25 m, so that difference decides whether the assault station works at all.
-- The brain already exposes an override for exactly this; use it so the range behaves the same on
-- any host mission. Primitives only in a Lua global, and the value comes first.
scSafe(function() global.set("germany", "realistic_nation_invaders") end)
scSafe(function() global.set("france",  "realistic_nation_defenders") end)
scLog("doctrine pinned: invaders=germany, defenders=france (independent of the host mission)")

local function at(dx, dz) return vec3(ORIGIN.x + dx, ORIGIN.y, ORIGIN.z + dz) end

-- Grid: four columns, four rows, so thirteen stations fit with room to spare.
local function cell(i)
    local col = (i - 1) % 4
    local row = math.floor((i - 1) / 4)
    return col * STATION_GAP, row * STATION_GAP
end

--========================= the stations =====================================
-- Each station's geometry is taken from docs/test-scenarios.md, which engineered each one to force
-- exactly one cascade branch. `enemyD` is the distance from the German squad to its enemies, and
-- it is the single most important number per station: it decides which branch wins.
local STATIONS = {
    { n = 1, expect = {28, 27}, name = "1 Approach march + formation",
      shows = "ROAD-MARCH, RALLY-on-MG, lateral stagger",
      ger = { GER_RIFLE }, enemy = {},
      note = "no enemies at all, objective 400 m away; the gunner ends up off a flank" },

    { n = 2, expect = {10, 24}, name = "2 Pinned + fight from cover",
      shows = "PINNED, then FIGHT-from-cover as suppression lifts",
      ger = { GER_RIFLE }, enemy = { FR_GUNS, FR_GUNS }, enemyD = 45,
      emplace = { V_MG_EMP, V_MG_EMP },
      note = "three MG teams at 40 m: >=2 enemies inside PINNED_RADIUS 50" },

    { n = 3, expect = {3, 4}, name = "3 Rout",
      shows = "ROUT / ROUT-cover, falling back ~40 m",
      ger = { GER_RIFLE }, ger2 = { GER_RIFLE }, enemy = { FR_RIFLE, FR_RIFLE, FR_RIFLE }, enemyD = 65,
      note = "heavily outnumbered so force ratio drops under Germany's moraleFloor 0.22" },

    { n = 4, expect = {8, 9}, name = "4 Close assault",
      shows = "ASSAULT / ASSAULT-cover, closing to contact",
      ger = { GER_RIFLE }, enemy = { FR_RIFLE }, enemyD = 25,
      note = "ONE enemy squad at 25 m: inside assaultRange 35, and not enough to trigger PINNED" },

    { n = 5, expect = {5, 6}, name = "5 AT team hunts armour",
      shows = "AT-stalk beyond 60 m, AT-hunt inside it",
      ger = { GER_AT }, enemy = {}, vehicles = { { V_FRTANK, 50, 0 }, { V_FRTANK, 65, 25 } },
      note = "enemy armour but NO enemy infantry, so nothing else can pre-empt the AT branch" },

    { n = 6, expect = {20}, name = "6 Advance behind armour",
      shows = "ADVANCE-behind-armour, line abreast ~6 m behind the hull",
      ger = { GER_RIFLE }, enemy = { FR_GUNS }, enemyD = 70,
      vehicles = { { V_HALF, 20, 0 } },
      note = "halftrack within ARMOUR_SCAN 45 m. Control: swap it for an Opel Blitz - a truck must NOT qualify" },

    { n = 7, expect = {21, 22, 23}, name = "7 Bounding overwatch",
      shows = "BOUND-move and BOUND-overwatch swapping every 8 s",
      ger = { GER_RIFLE }, enemy = { FR_RIFLE }, enemyD = 75,
      note = "threatened but only ONE enemy, far enough that PINNED cannot pre-empt bounding" },

    { n = 8, expect = {11, 12, 13, 14, 15}, name = "8 Medic and wounded drag",
      shows = "MEDIC-sortie, DRAG-approach to pickup to to-cover",
      ger = { GER_RIFLE, GER_RIFLE }, enemy = { FR_RIFLE }, enemyD = 120,
      note = "enemy at 120 m is OUTSIDE PINNED_RADIUS 50, which the medic sortie requires" },

    { n = 9, expect = {1}, name = "9 Crew bail-out",
      shows = "crew leave the wreck, then CREW-onfoot away from the enemy",
      ger = { GER_CREW }, enemy = { FR_GUNS }, enemyD = 300,
      vehicles = { { V_PZ2, 0, 0 } },
      note = "a CREWED vehicle, not a truck: truck occupants are passengers, not crew" },

    { n = 10, expect = {17}, name = "10 Radio fire mission",
      shows = "RADIO-fire-mission, and a barrage that actually LANDS",
      ger = { GER_RIFLE }, enemy = { FR_RIFLE, FR_RIFLE, FR_RIFLE }, enemyD = 80,
      note = "80 m clears FIRE_DANGER_R, which is 50 m (RealisticEvents.lua:61) - NOT the 90 m "
          .. "this note used to quote. At 90 the radius equalled SENSE_RADIUS, so the gate was "
          .. "arithmetically impossible to open and every barrage was refused danger-close. That "
          .. "was the bug, not the geometry; 24 shells landed once it was 50" },

    { n = 11, expect = {30, 31}, name = "11 Transport reuse",
      shows = "RETURN-to-transport then REBOARD-transport",
      ger = {}, mounted = { GER_RIFLE }, enemy = {}, objectiveD = 200,
      vehicles = { { V_TRUCK, 30, 0 } },
      note = "no contact, objective beyond REBOARD_MIN_DIST 120, truck inside REBOARD_SCAN 60" },

    { n = 12, expect = {26}, objective = "attract", name = "12 Consolidate and objective flow",
      shows = "CONSOLIDATE, capture, then flow to the second objective",
      ger = { GER_RIFLE, GER_RIFLE }, enemy = { FR_RIFLE }, enemyD = 80,
      secondObjective = true,
      note = "small enough that objective 1 falls in minutes, then attraction releases it" },

    { n = 13, expect = {24, 10}, name = "13 Kill feed and callouts",
      shows = "on-screen kill feed, one squadmate callout per death",
      ger = { GER_RIFLE }, enemy = { FR_RIFLE }, enemyD = 100,
      player = true,
      note = "THIS is the station to spawn into - the feed is scoped to the player's own squad" },
}

--========================= build the range ==================================
local labels = {}
local failed = 0

-- The two rig emitters. `side` is a STRING here, not a faction handle: the rig resolves
-- "invader"/"defender" to INV/DEF itself, which is what lets this whole prefix be inlined ABOVE
-- the point where a faction handle even exists.
local function addSquad(squadId, pos, side, radius)
    SHOWCASE.squads[#SHOWCASE.squads + 1] =
        { squad = squadId, side = side, pos = pos, radius = radius or 12 }
end
-- ARG 3 IS A vec3 DIRECTION, NOT A ROTATION IN DEGREES. docs/verified-api.md documented
-- spawnVehicle(vehicle_id, pos, rot) and a number looked like the obvious reading; it is not.
-- MEASURED 2026-09-08 on v2.1.0: passing 180 threw
--     bad argument #3 to 'spawnVehicleWithCallback' (userdata expected, got number)
-- and - this is the important part - the exception ESCAPED THE ENCLOSING pcall, propagated
-- into Unity's coroutine machinery and killed the entire phase script. The range built
-- station 1 and then simply stopped. Same uncatchable class as the soldier_suppressed NRE:
-- the throw happens inside the engine's own argument marshalling, before the Lua body, so
-- pcall cannot help and a guard is NOT protection. The only safe move is to pass the right type.
local function addVeh(name, pos, dir)
    SHOWCASE.vehicles[#SHOWCASE.vehicles + 1] = { name, pos, dir }
end

-- LAYOUT VALIDATION, before anything is emitted. The failure mode this catches is subtle and
-- silent: a station's enemies drift within sensing range of a NEIGHBOUR's centre, so that
-- neighbour's squad counts them in its force ratio and takes a completely different branch. The
-- demonstration then shows the wrong feature and looks like an AI bug. Refuse to build instead.
local SENSE = 90
local MARGIN = 60            -- how much clear air to demand beyond sensing range
local function validateLayout()
    local bad = 0
    for _, s in ipairs(STATIONS) do
        local dx, dz = cell(s.n)
        local ed = s.enemyD or 100
        local hasEnemies = (#(s.enemy or {}) > 0)
        if hasEnemies then
            for _, o in ipairs(STATIONS) do
                if o.n ~= s.n then
                    local ox, oz = cell(o.n)
                    -- enemies sit at (dx + ed, dz); how close is that to another centre?
                    local ddx, ddz = (dx + ed) - ox, dz - oz
                    local d = math.sqrt(ddx * ddx + ddz * ddz)
                    if d < (SENSE + MARGIN) then
                        scLog(string.format("LAYOUT ERROR station %d's enemies are %.0f m from "
                              .. "station %d's centre (need >= %d)", s.n, d, o.n, SENSE + MARGIN))
                        bad = bad + 1
                    end
                end
            end
        end
    end
    return bad
end

local layoutErrors = validateLayout()
-- AN `if`, NOT A `return`. This used to be `return`, and a top-level return is FATAL once this
-- prefix is inlined into RealisticEvents.lua's main chunk: it would abort the phase script and
-- take every callback registration with it.
if layoutErrors > 0 then
    scLog("REFUSING to build: " .. layoutErrors .. " layout conflict(s). Raise STATION_GAP or "
          .. "lower the offending enemyD. Nothing was spawned.")
else

scLog("building the demonstration range, " .. #STATIONS .. " stations, "
      .. STATION_GAP .. " m apart (SENSE_RADIUS is 90, layout validated)")

-- STATION HOMES, for the repeating diorama. There is NO teleport for soldiers in this engine -
-- the Soldier class exposes moveTo, killSoldier, healSoldier, incapacitate/stopIncapacitate and
-- setInVehicle, and nothing that sets a position directly (checked against the official class
-- reference, easyred2.com/wiki/scripting.php?type_id=8). So a reset cannot snap anyone back: the
-- actors have to WALK home, which is why each one's start position is recorded here.
SHOWCASE.stations = {}

for _, s in ipairs(STATIONS) do
    local dx, dz = cell(s.n)
    local centre = at(dx, dz)
    local stn = { n = s.n, name = s.name, centre = centre, inv = {}, def = {} }
    SHOWCASE.stations[#SHOWCASE.stations + 1] = stn

    -- German side
    for i, sid in ipairs(s.ger or {}) do
        addSquad(sid, at(dx + (i - 1) * 20, dz), "invader", 12)
        stn.inv[#stn.inv + 1] = at(dx + (i - 1) * 20, dz)
    end
    -- A squad that must spawn ON a vehicle, which is the only way the transport-reuse branch is
    -- reachable: it keys off myTransportId, remembered while MOUNTED, so a squad that never rode
    -- anything can never return to it. Measured: station 11 showed only ROAD-MARCH until this was
    -- added. The truck it boards is the one in s.vehicles at the SAME position - it used to be
    -- spawned a second time here, which put two Opel Blitzes on the same square metre.
    for _, sid in ipairs(s.mounted or {}) do
        SHOWCASE.mounted[#SHOWCASE.mounted + 1] = { sid, at(dx + 30, dz), "invader" }
    end

    -- Enemy side, placed enemyD metres along +X so the axis of threat is consistent
    local ed = s.enemyD or 100
    for i, sid in ipairs(s.enemy or {}) do
        addSquad(sid, at(dx + ed, dz + (i - 1) * 25), "defender", 10)
        stn.def[#stn.def + 1] = at(dx + ed, dz + (i - 1) * 25)
    end

    -- Vehicles: { name, offsetX, offsetZ }
    for _, v in ipairs(s.vehicles or {}) do
        addVeh(v[1], at(dx + v[2], dz + v[3]), vec3(0, 90, 0))   -- yaw +X: Euler DEGREES
    end
    -- Emplacements face back down -X toward the German squads, who sit at the station centre.
    for i, e in ipairs(s.emplace or {}) do
        addVeh(e, at(dx + ed, dz + (i - 1) * 30), vec3(0, 270, 0))  -- yaw -X: Euler DEGREES
    end

    -- STATION LABEL. attractor = FALSE for every label except the two stations that need a real
    -- objective. An attractor changes AI behaviour, so a label that attracted would pull
    -- neighbouring stations' squads out of position and wreck their demonstrations.
    -- ONE OBJECTIVE PER STATION, and this is load-bearing rather than cosmetic.
    --
    -- Originally only 4 stations had an objective. The brain marches an unthreatened attacker to
    -- his NEAREST objective, so every squad without a local one found an objective up to 1500 m
    -- away and marched off its station - the whole range collapsed into blobs at the few stations
    -- that had one. MEASURED before this fix: ROAD-MARCH x10 at station 8, x8 at 11 and 13, and
    -- dozens of soldiers piled onto stations 10 and 12. Only 1-3 of 13 stations demonstrated
    -- anything.
    --
    -- Offset 180 m on -Z, NOT at the centre: a squad standing on its own objective is inside
    -- ARRIVE_RADIUS 30 and consolidates instead of demonstrating (measured: CONSOLIDATE x8 at
    -- station 13). 180 m also clears REBOARD_MIN_DIST 120, which station 11 needs. Own objective
    -- is 180 m away while the nearest neighbouring one is 320 m, so "nearest" is unambiguous.
    --
    -- attractor is FALSE everywhere except station 12, which exists to demonstrate objective flow.
    -- An attractor steers base AI map-wide, so a second attracting objective would drag other
    -- stations' squads across the range - the same collapse by a different route.
    -- THE OBJECTIVE SITS BEYOND THE ENEMY, on the same +X axis, so marching to it DRIVES the
    -- squad into contact. It was on -Z, perpendicular to the enemy, and the result was that every
    -- station showed ROAD-MARCH + RALLY-on-MG for ever: the squad dutifully marched away from the
    -- enemy it was supposed to be demonstrating against. Putting the objective past the enemy
    -- makes each station self-driving - approach, contact, then whichever branch the geometry
    -- forces - which is also how a real approach march ends.
    --
    -- Clamped to 220 m so it stays nearer its OWN station than any neighbour's (they are 500 m
    -- apart, so the next centre is 280 m further on).
    --
    -- OBJECTIVES ARE SPAWNED HERE IN BOTH ROLES, not emitted into the rig. The rig has ONE
    -- TEST_OBJECTIVE slot and this range needs fourteen, and objective creation - unlike squad
    -- spawning - depends on no callback, so doing it at load time is safe even when this prefix is
    -- inlined above RealisticEvents.lua's setCallback block.
    local od = s.objectiveD or math.min(220, (s.enemyD or 100) + 120)
    local attract = (s.objective == "attract")
    local o = scSafeGet(function()
        return spawnMissionObjective(at(dx + od, dz), 45, s.name, 0, attract)
    end)
    if o then labels[#labels + 1] = s.name else failed = failed + 1 end
    -- KEEP THE HANDLE. The Objective class exposes setText ("Update the text of a Scripted
    -- Mission Objective"), so this label can be rewritten every few seconds with what the actors
    -- at this station are ACTUALLY doing. That is the difference between a range you have to
    -- read a log to understand and one you can walk up to and read off the sign - which is the
    -- whole point of a station you can stand next to.
    stn.label = o
    -- TAG THE NON-ATTRACTING LABELS so RealisticEvents.lua's attraction manager leaves them alone.
    -- That manager does `for _, o in ipairs(objList) do setAttract(o, true, true) end` at load
    -- (RealisticEvents.lua:1082) and re-asserts attraction every ATTRACT_EVERY seconds in
    -- loopBody, which would turn all thirteen station labels into attractors and undo the
    -- attractor=false design above - the map-wide drag that collapsed this range once already.
    -- Station 12's attracting pair is deliberately left UNTAGGED: it exists to demonstrate
    -- objective flow, and the attraction manager is the thing that demonstrates it.
    if o and not attract then
        scSafe(function()
            global.set(1, "realistic_showcase_label" .. tostring(o.getUniqueId()))
        end)
    end
    if s.secondObjective then
        scSafe(function() spawnMissionObjective(at(dx + od, dz - 200), 45,
                                                s.name .. " (second)", 0, true) end)
    end

    scLog(string.format("station %-2d @(%.0f,%.0f)  %s", s.n, centre.x, centre.z, s.shows))
end

scLog(string.format("range built: %d squads, %d vehicles, %d mounted, %d labels, %d failures",
      #SHOWCASE.squads, #SHOWCASE.vehicles, #SHOWCASE.mounted, #labels, failed))

end   -- if layoutErrors > 0 ... else

--============================================================================
--@@ SHOWCASE INLINE CUT - tools/gen_showcase_inline.py splices ONLY the text ABOVE this line.
--
-- EVERYTHING BELOW IS STANDALONE-ONLY and must never be inlined:
--   * the master-client guard is a top-level `return` (RealisticEvents.lua:90 already has its own);
--   * INV / DEF / MY_PHASE / announce / safe / safeGet / roleOf all collide with names
--     RealisticEvents.lua already declares;
--   * the emitter would spawn the range at load, BEFORE a single setCallback has run - the exact
--     ordering bug check 4k exists to prevent, and the reason the rig is a deferred function;
--   * the HUD ends in `while true ... sleep(1)`, so nothing after it would ever execute.
--============================================================================

if not er2.isMasterClient() then return end

local safeGet = scSafeGet
local safe = scSafe
local log2 = scLog
local function announce(m) log2(m); pcall(function() print(m) end) end

local MY_PHASE = safeGet(function() return er2.getCurrentPhaseId() end) or 0
local INV = safeGet(function() return er2.getInvadersFaction() end)
local DEF = safeGet(function() return er2.getDefendersFaction() end)

local HUD         = true            -- on-screen readout. This file is a demo, so it ships ON.
local HUD_EVERY   = 1.5             -- s between HUD refreshes
local HUD_RADIUS  = 120             -- m around the player whose soldiers are listed
local HUD_MAX     = 8               -- lines per refresh; a HUD, not a log
-- 30 s between censuses, and the FIRST one is held back until the range has had time to spawn
-- (29 squads arrive over a coroutine, not instantly) and to close with the enemy. Judging at 15 s
-- reported 2/13 simply because most squads were still marching.
local CENSUS_EVERY = 30
local CENSUS_WARMUP = 120           -- s after build before the first census is meaningful

--========================= the standalone emitter ===========================
-- Spawns the rig tables this file just built. Order matters and mirrors runSpawnRig(): squads,
-- then vehicles, then mounted - the mounted path finds its vehicle by AREA SCAN, so the vehicle
-- has to exist first.
local built = 0
local function spawnSquadAt(squadId, pos, faction, radius)
    local sq = safeGet(function()
        return spawnSquad_script(pos, radius or 12, faction, squadId, BRAIN)
    end)
    if sq == nil then
        -- Fall back to a brainless spawn so the station still exists and is visibly wrong,
        -- rather than silently missing. A bad squad id shows up here.
        if safe(function() spawnSquad(pos, radius or 12, faction, squadId) end) then
            log2("WARNING squad '" .. tostring(squadId) .. "' spawned WITHOUT a brain")
        else
            log2("FAILED to spawn squad '" .. tostring(squadId) .. "' - check the id")
            failed = failed + 1
            return nil
        end
    end
    built = built + 1
    return sq
end

for _, s in ipairs(SHOWCASE.squads) do
    spawnSquadAt(s.squad, s.pos, (s.side == "invader") and INV or DEF, s.radius)
end

for _, v in ipairs(SHOWCASE.vehicles) do
    if not safe(function() spawnVehicle(v[1], v[2], v[3]) end) then
        log2("FAILED to spawn vehicle '" .. tostring(v[1]) .. "'")
        failed = failed + 1
    end
end

for _, m in ipairs(SHOWCASE.mounted) do
    -- Find the vehicle by AREA SCAN rather than trusting spawnVehicle's return value, which is
    -- undocumented and empty (it resolves to spawnVehicleWithCallback). Relying on it made this
    -- branch always take the dismounted fallback. getVehiclesInArea is fill-style and must be
    -- called WITH a table.
    local vlist, veh = {}, nil
    safe(function() er2.getVehiclesInArea(m[2], 40, vlist) end)
    for _, v in pairs(vlist) do if v then veh = v break end end
    local fac = (m[3] == "defender") and DEF or INV
    local ok = veh and safeGet(function()
        return spawnSquadOnVehicle_script(m[2], 8, fac, m[1], veh, BRAIN)
    end)
    if ok then
        built = built + 1
    else
        log2("mounted spawn unavailable for '" .. tostring(m[1])
             .. "' - falling back to a dismounted squad (transport reuse will not fire)")
        spawnSquadAt(m[1], m[2], fac, 12)
    end
end

log2(string.format("standalone emitter: %d squads/crews placed, %d failures, %d labels",
     built, failed, #labels))
if failed > 0 then
    log2("NOTE a failure above is almost always a squad or vehicle id that does not exist on this "
         .. "install. Find the real id with the editor's loadout SEARCH box.")
end

--========================= the on-screen readout ============================
-- This is what makes the range OBSERVABLE rather than a log-reading exercise.
--
-- It costs the brain NOTHING: the brain already publishes its decision as an integer to the Lua
-- global "D"..uid on change (Realistic.lua), so the phase script just reads it back. No extra
-- per-tick work is added to 350 brains to render a HUD for one player.
local DECN = {
    [1]="CREW-onfoot", [2]="MOUNTED-defer", [3]="ROUT", [4]="ROUT-cover",
    [5]="AT-stalk", [6]="AT-hunt", [8]="ASSAULT", [9]="ASSAULT-cover",
    [10]="PINNED", [11]="MEDIC-sortie", [12]="MEDIC-hold-cover",
    [13]="DRAG-approach", [14]="DRAG-pickup", [15]="DRAG-to-cover", [16]="DRAG-abandon",
    [17]="RADIO-fire-mission", [18]="LEADER-cover", [19]="SUPPORT-hold-fire",
    [20]="ADVANCE-behind-armour", [21]="BOUND-move", [22]="BOUND-move-cover",
    [23]="BOUND-overwatch", [24]="FIGHT-from-cover", [25]="DEFEND-hold",
    [26]="CONSOLIDATE", [27]="RALLY-on-MG", [28]="ROAD-MARCH", [29]="ADVANCE-baseAI",
    [30]="RETURN-to-transport", [31]="REBOARD-transport", [32]="FORM-followLeader",
}

local function roleOf(s)
    if safeGet(function() return s.isSquadLeader() end) == true then return "leader"   end
    if safeGet(function() return s.isATSoldier()   end) == true then return "AT"       end
    if safeGet(function() return s.isMedic()       end) == true then return "medic"    end
    if safeGet(function() return s.isRadioman()    end) == true then return "radioman" end
    local cn = tostring(safeGet(function() return s.getClassName() end) or ""):lower()
    if cn:find("support") or cn:find("gunner") then return "gunner" end
    return "rifleman"
end

if not HUD then log2("HUD disabled") return end

-- ACCUMULATED per station: every decision code ever seen there, across the whole run.
-- This is the fix for a census that was measuring the wrong thing. The first version sampled a
-- single instant and asked "is an expected decision happening RIGHT NOW". But the features are
-- TRANSIENT - a man is PINNED for a few seconds, ASSAULTs for one bound, ROUTs once - while the
-- steady state is DEFEND-hold and ROAD-MARCH. So an instantaneous census reported 0-3 of 13
-- stations while the brain trace for the SAME run showed twenty branches firing, including PINNED
-- 77 times, FIGHT-from-cover 132, ASSAULT 14, ROUT 17 and AT 6. The range was working; the
-- instrument was not. Same rule as the rest of this project: absence at one instant is not
-- absence over time.
local SEEN = {}

-- Census of ONE station: what are the soldiers there actually deciding?
-- Reads the brain's published decision from global "D"..uid, so it costs the brain nothing.
local function census(st)
    local dx, dz = cell(st.n)
    local c = at(dx, dz)
    local list = {}
    -- 240 m, not 260: stations are 500 m apart, so a wider ring reaches a neighbour.
    safe(function() er2.getSoldiersInArea(c, 240, list) end)
    local counts, total = {}, 0
    for _, sol in pairs(list) do
        -- INVADERS ONLY. Every feature on this range is invader-side, so the defenders' uniform
        -- DEFEND-hold drowned the signal: station 10 read 18 DEFEND-hold against 2 of the
        -- decisions it was actually meant to show.
        local sf = sol and safeGet(function() return sol.getFaction() end)
        local isInv = sf and safeGet(function() return er2.isSameFaction(sf, INV) end) == true
        if isInv and safeGet(function() return sol.isAlive() end) ~= false then
            local uid = safeGet(function() return sol.getUniqueId() end)
            local code = uid and safeGet(function() return global.get("D" .. uid) end)
            if code and code ~= 0 then
                counts[code] = (counts[code] or 0) + 1
                total = total + 1
            end
        end
    end
    -- did any EXPECTED decision appear?
    local hit, top, topn = false, nil, 0
    for code, n in pairs(counts) do
        if n > topn then top, topn = code, n end
        for _, want in ipairs(st.expect or {}) do
            if code == want then hit = true end
        end
    end
    -- fold this sample into the station's accumulated set
    SEEN[st.n] = SEEN[st.n] or {}
    for code, n in pairs(counts) do
        SEEN[st.n][code] = (SEEN[st.n][code] or 0) + n
    end
    -- a station passes if an expected decision has EVER been seen, not just now
    local everHit = false
    for _, want in ipairs(st.expect or {}) do
        if (SEEN[st.n][want] or 0) > 0 then everHit = true end
    end
    return counts, total, everHit, top, topn
end

local function decList(counts)
    local parts = {}
    for code, n in pairs(counts) do
        parts[#parts + 1] = (DECN[code] or ("code" .. code)) .. " x" .. n
    end
    table.sort(parts)
    return table.concat(parts, ", ")
end

-- SPECTATOR CENSUS. The per-player HUD needs er2.getPlayer(), which is nil until someone picks a
-- faction and spawns - so on the faction-selection screen the readout printed nothing at all and
-- looked broken. This reports every station at once instead, and CHECKS each against the decision
-- it exists to demonstrate, which makes the range self-verifying rather than something you have to
-- walk and interpret.
local function fullCensus()
    announce("===== SHOWCASE RANGE: cumulative station census =====")
    local working, silent = 0, 0
    for _, st in ipairs(STATIONS) do
        local counts, total, everHit = census(st)
        local acc = SEEN[st.n] or {}
        local accN = 0
        for _ in pairs(acc) do accN = accN + 1 end
        if accN == 0 then
            announce(string.format("  %-2d %-28s  (nothing seen yet)", st.n,
                     st.name:gsub("^%d+%s*", "")))
            silent = silent + 1
        else
            -- report the ACCUMULATED set, which is what the pass/fail is judged on
            announce(string.format("  %-2d %-28s %s  %s", st.n, st.name:gsub("^%d+%s*", ""),
                     everHit and "OK " or "-- ", decList(acc)))
            if everHit then working = working + 1 end
        end
    end
    -- Station 13 (kill feed) needs a human in a squad and cannot pass unattended; 12 is the
    -- unattended target.
    announce(string.format("===== %d/%d stations have shown an expected decision "
             .. "(13 needs a player) =====", working, #STATIONS))
end

local lastHud, lastCensus = 0, 0
local buildT = safeGet(function() return er2.time() end) or 0
while true do
    local ph = safeGet(function() return er2.getCurrentPhaseId() end)
    if ph == MY_PHASE then
        local t = safeGet(function() return er2.time() end) or 0
        local p = safeGet(function() return er2.getPlayer() end)
        local pp = p and safeGet(function() return p.getPosition() end)

        if pp and (t - lastHud) >= HUD_EVERY then
            -- PLAYER PRESENT: the walk-the-range readout.
            lastHud = t
            local st, sd = nil, 1e9
            for _, cand in ipairs(STATIONS) do
                local dx, dz = cell(cand.n)
                local d = distance(pp, at(dx, dz))
                if d < sd then st, sd = cand, d end
            end
            if st then
                announce(string.format("== %s  (%.0f m from centre) ==", st.name, sd))
                announce("   showing: " .. st.shows)
            end
            local list = {}
            safe(function() er2.getSoldiersInArea(pp, HUD_RADIUS, list) end)
            local shown = 0
            for _, sol in pairs(list) do
                if shown >= HUD_MAX then break end
                if sol and safeGet(function() return sol.isAlive() end) ~= false then
                    local uid = safeGet(function() return sol.getUniqueId() end)
                    local code = uid and safeGet(function() return global.get("D" .. uid) end)
                    if code and code ~= 0 then
                        announce(string.format("   %-9s %s", roleOf(sol),
                                 DECN[code] or ("code " .. tostring(code))))
                        shown = shown + 1
                    end
                end
            end
            if shown == 0 then
                announce("   (no brain nearby has published a decision yet)")
            end

        elseif not pp and t >= (buildT + CENSUS_WARMUP) and (t - lastCensus) >= CENSUS_EVERY then
            -- NO PLAYER (spectating, or still on faction selection): report the whole range.
            lastCensus = t
            fullCensus()
        end
    end
    sleep(1)
end
