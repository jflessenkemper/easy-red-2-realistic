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
-- DEPLOY: copy this file to a TEST mission as its phase script:
--   ~/.config/unity3d/Corvostudio/Easy Red 2/mission_editor/<mission>/scripts/mission/phase_0.lua
-- and put Realistic.lua in that mission's scripts/AI/. It is SELF-CONTAINED: it spawns everything
-- and attaches the brain itself, so it does NOT need RealisticEvents.lua and must not be deployed
-- alongside it (one phase script per phase).
--
-- FIRST RUN: set ORIGIN. Open the mission in the editor, aim the camera at the middle of a large
-- flat area, press P to copy the cursor position, and paste it below. Everything else is laid out
-- relative to that single coordinate, so it is the only thing you have to capture by hand.
--============================================================================

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
local HUD         = true            -- on-screen readout. This file is a demo, so it ships ON.
local HUD_EVERY   = 1.5             -- s between HUD refreshes
local HUD_RADIUS  = 120             -- m around the player whose soldiers are listed
local HUD_MAX     = 8               -- lines per refresh; a HUD, not a log

local BRAIN = "Realistic.lua"

--========================= confirmed content only ===========================
-- Every id below was read out of the real ME_Stonne mission file, so all of them exist on this
-- install. NOTHING here is guessed.
--
-- GAP, stated rather than papered over: there is NO confirmed French RIFLE squad id. The mission
-- contains only fr_ATsquad, fr_artilleryCrew and fr_tankCrew. So the opposing infantry below uses
-- fr_ATsquad, which is a real squad but an anti-tank one. To use a proper French rifle section,
-- find its id with the editor's loadout SEARCH box and put it in FR_RIFLE. Greyed-out entries in
-- that picker are DLC-locked.
local GER_RIFLE = "ger_infantry_1940"          -- 1940 rifle squad, has a Support gunner
local GER_AT    = "ger_infantry_AT_earlywar"   -- AT squad, for the armour-hunting station
local GER_CREW  = "ger_tankCrew_1940"          -- for the bail-out station
local FR_RIFLE  = "fr_ATsquad"                 -- see the GAP note above
local FR_GUNS   = "fr_artilleryCrew"           -- emplaced-crew stand-in

local V_PZ2     = "Panzer II C"
local V_HALF    = "Sdkfz251 1939"
local V_TRUCK   = "Opel Blitz"
local V_MG_EMP  = "Hotchkiss Stationary Ground"
local V_FRTANK  = "Char B1"

--========================= helpers ==========================================
local function safeGet(fn) local ok, v = pcall(fn); if ok then return v end return nil end
local function safe(fn) return (pcall(fn)) end
local function log2(m) log("[SHOWCASE] " .. tostring(m)) end
local function announce(m) log2(m); pcall(function() print(m) end) end

if not er2.isMasterClient() then return end
local MY_PHASE = safeGet(function() return er2.getCurrentPhaseId() end) or 0
local INV = safeGet(function() return er2.getInvadersFaction() end)
local DEF = safeGet(function() return er2.getDefendersFaction() end)

-- Resolve the origin: an explicit override, else the first mission objective, else the map centre.
-- getAllObjectives is a FILL-style API and must be called WITH a table - a bare call throws on
-- every invocation.
if ORIGIN_OVERRIDE then
    ORIGIN = ORIGIN_OVERRIDE
    log2(string.format("origin: override (%.0f,%.0f)", ORIGIN.x, ORIGIN.z))
else
    local objs = {}
    safe(function() er2.getAllObjectives(objs) end)
    for _, o in pairs(objs) do
        local op = o and safeGet(function() return o.getPosition() end)
        if op then
            -- Offset well clear of the objective itself so the range does not overlap whatever
            -- the mission already has fighting over it.
            ORIGIN = vec3(op.x + 400, op.y, op.z + 400)
            log2(string.format("origin: derived from the first mission objective -> (%.0f,%.0f)",
                 ORIGIN.x, ORIGIN.z))
            break
        end
    end
    if not ORIGIN then
        ORIGIN = vec3(0, 0, 0)
        log2("origin: no objective found, falling back to (0,0). If the range spawns off-map, set "
             .. "ORIGIN_OVERRIDE with a P-captured position.")
    end
end

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
    { n = 1,  name = "1 Approach march + formation",
      shows = "ROAD-MARCH, RALLY-on-MG, lateral stagger",
      ger = { GER_RIFLE }, enemy = {}, objective = true,
      note = "no enemies at all, objective 400 m away; the gunner ends up off a flank" },

    { n = 2,  name = "2 Pinned + fight from cover",
      shows = "PINNED, then FIGHT-from-cover as suppression lifts",
      ger = { GER_RIFLE }, enemy = { FR_GUNS, FR_GUNS, FR_GUNS }, enemyD = 40,
      emplace = { V_MG_EMP, V_MG_EMP },
      note = "three MG teams at 40 m: >=2 enemies inside PINNED_RADIUS 50" },

    { n = 3,  name = "3 Rout",
      shows = "ROUT / ROUT-cover, falling back ~40 m",
      ger = { GER_RIFLE }, enemy = { FR_RIFLE, FR_RIFLE, FR_RIFLE, FR_RIFLE }, enemyD = 60,
      note = "heavily outnumbered so force ratio drops under Germany's moraleFloor 0.22" },

    { n = 4,  name = "4 Close assault",
      shows = "ASSAULT / ASSAULT-cover, closing to contact",
      ger = { GER_RIFLE }, enemy = { FR_RIFLE }, enemyD = 25,
      note = "ONE enemy squad at 25 m: inside assaultRange 35, and not enough to trigger PINNED" },

    { n = 5,  name = "5 AT team hunts armour",
      shows = "AT-stalk beyond 60 m, AT-hunt inside it",
      ger = { GER_AT }, enemy = {}, vehicles = { { V_FRTANK, 100, 0 }, { V_FRTANK, 120, 30 } },
      note = "enemy armour but NO enemy infantry, so nothing else can pre-empt the AT branch" },

    { n = 6,  name = "6 Advance behind armour",
      shows = "ADVANCE-behind-armour, line abreast ~6 m behind the hull",
      ger = { GER_RIFLE }, enemy = { FR_GUNS }, enemyD = 200,
      vehicles = { { V_HALF, 20, 0 } },
      note = "halftrack within ARMOUR_SCAN 45 m. Control: swap it for an Opel Blitz - a truck must NOT qualify" },

    { n = 7,  name = "7 Bounding overwatch",
      shows = "BOUND-move and BOUND-overwatch swapping every 8 s",
      ger = { GER_RIFLE }, enemy = { FR_RIFLE }, enemyD = 150,
      note = "threatened but only ONE enemy, far enough that PINNED cannot pre-empt bounding" },

    { n = 8,  name = "8 Medic and wounded drag",
      shows = "MEDIC-sortie, DRAG-approach to pickup to to-cover",
      ger = { GER_RIFLE, GER_RIFLE }, enemy = { FR_RIFLE }, enemyD = 120,
      note = "enemy at 120 m is OUTSIDE PINNED_RADIUS 50, which the medic sortie requires" },

    { n = 9,  name = "9 Crew bail-out",
      shows = "crew leave the wreck, then CREW-onfoot away from the enemy",
      ger = { GER_CREW }, enemy = { FR_GUNS }, enemyD = 300,
      vehicles = { { V_PZ2, 0, 0 } },
      note = "a CREWED vehicle, not a truck: truck occupants are passengers, not crew" },

    { n = 10, name = "10 Radio fire mission",
      shows = "RADIO-fire-mission, and a barrage that actually LANDS",
      ger = { GER_RIFLE }, enemy = { FR_RIFLE, FR_RIFLE, FR_RIFLE }, enemyD = 130,
      note = "130 m is the whole point: it clears FIRE_DANGER_R 90 m from every friendly. "
          .. "Every barrage so far was correctly REFUSED danger close" },

    { n = 11, name = "11 Transport reuse",
      shows = "RETURN-to-transport then REBOARD-transport",
      ger = { GER_RIFLE }, enemy = {}, objective = true, objectiveD = 200,
      vehicles = { { V_TRUCK, 30, 0 } },
      note = "no contact, objective beyond REBOARD_MIN_DIST 120, truck inside REBOARD_SCAN 60" },

    { n = 12, name = "12 Consolidate and objective flow",
      shows = "CONSOLIDATE, capture, then flow to the second objective",
      ger = { GER_RIFLE, GER_RIFLE }, enemy = { FR_RIFLE }, enemyD = 80,
      objective = true, secondObjective = true,
      note = "small enough that objective 1 falls in minutes, then attraction releases it" },

    { n = 13, name = "13 Kill feed and callouts",
      shows = "on-screen kill feed, one squadmate callout per death",
      ger = { GER_RIFLE }, enemy = { FR_RIFLE }, enemyD = 100,
      player = true,
      note = "THIS is the station to spawn into - the feed is scoped to the player's own squad" },
}

--========================= build the range ==================================
local built, failed = 0, 0
local labels = {}

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

-- LAYOUT VALIDATION, before anything is spawned. The failure mode this catches is subtle and
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
                        log2(string.format("LAYOUT ERROR station %d's enemies are %.0f m from "
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
if layoutErrors > 0 then
    log2("REFUSING to build: " .. layoutErrors .. " layout conflict(s). Raise STATION_GAP or "
         .. "lower the offending enemyD. Nothing was spawned.")
    return
end

log2("building the demonstration range, " .. #STATIONS .. " stations, "
     .. STATION_GAP .. " m apart (SENSE_RADIUS is 90, layout validated)")

for _, s in ipairs(STATIONS) do
    local dx, dz = cell(s.n)
    local centre = at(dx, dz)

    -- German side
    for i, sid in ipairs(s.ger or {}) do
        spawnSquadAt(sid, at(dx + (i - 1) * 20, dz), INV, 12)
    end

    -- Enemy side, placed enemyD metres along +X so the axis of threat is consistent
    local ed = s.enemyD or 100
    for i, sid in ipairs(s.enemy or {}) do
        spawnSquadAt(sid, at(dx + ed, dz + (i - 1) * 25), DEF, 10)
    end

    -- Vehicles: { name, offsetX, offsetZ }
    for _, v in ipairs(s.vehicles or {}) do
        if not safe(function() spawnVehicle(v[1], at(dx + v[2], dz + v[3]), 0) end) then
            log2("FAILED to spawn vehicle '" .. tostring(v[1]) .. "'")
            failed = failed + 1
        end
    end
    for i, e in ipairs(s.emplace or {}) do
        safe(function() spawnVehicle(e, at(dx + ed, dz + (i - 1) * 30), 180) end)
    end

    -- STATION LABEL. attractor = FALSE for every label except the two stations that need a real
    -- objective. An attractor changes AI behaviour, so a label that attracted would pull
    -- neighbouring stations' squads out of position and wreck their demonstrations.
    -- Real objectives go on the -Z axis, NOT the +X axis the enemies use, so an ATTRACTING
    -- objective can never end up near a neighbouring station and pull its squad out of position.
    local isRealObjective = (s.objective == true)
    local od = s.objectiveD or 250
    local labelPos = isRealObjective and at(dx, dz - od) or centre
    local o = safeGet(function()
        return spawnMissionObjective(labelPos, 40, s.name, 0, isRealObjective)
    end)
    if o then labels[#labels + 1] = s.name end
    if s.secondObjective then
        safe(function() spawnMissionObjective(at(dx + 200, dz - od), 40,
                                             s.name .. " (second)", 0, true) end)
    end

    log2(string.format("station %-2d @(%.0f,%.0f)  %s", s.n, centre.x, centre.z, s.shows))
end

log2(string.format("range built: %d squads/vehicles placed, %d failures, %d labels",
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

local function nearestStation(p)
    local best, bd = nil, 1e9
    for _, s in ipairs(STATIONS) do
        local dx, dz = cell(s.n)
        local c = at(dx, dz)
        local d = distance(p, c)
        if d < bd then best, bd = s, d end
    end
    return best, bd
end

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

local lastHud = 0
while true do
    local ph = safeGet(function() return er2.getCurrentPhaseId() end)
    if ph == MY_PHASE then
        local t = safeGet(function() return er2.time() end) or 0
        if (t - lastHud) >= HUD_EVERY then
            lastHud = t
            local p = safeGet(function() return er2.getPlayer() end)
            local pp = p and safeGet(function() return p.getPosition() end)
            if pp then
                local st, sd = nearestStation(pp)
                if st then
                    announce(string.format("== %s  (%.0f m from centre) ==", st.name, sd))
                    announce("   showing: " .. st.shows)
                end
                local list = {}
                safe(function() er2.getSoldiersInArea(pp, HUD_RADIUS, list) end)
                local shown = 0
                for _, s in pairs(list) do
                    if shown >= HUD_MAX then break end
                    if s and safeGet(function() return s.isAlive() end) ~= false then
                        local uid = safeGet(function() return s.getUniqueId() end)
                        local code = uid and safeGet(function() return global.get("D" .. uid) end)
                        if code and code ~= 0 then
                            announce(string.format("   %-9s %s", roleOf(s),
                                     DECN[code] or ("code " .. tostring(code))))
                            shown = shown + 1
                        end
                    end
                end
                if shown == 0 then
                    announce("   (no brain has published a decision within " .. HUD_RADIUS .. " m yet)")
                end
            end
        end
    end
    sleep(1)
end
