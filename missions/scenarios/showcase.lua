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
-- 30 s between censuses, and the FIRST one is held back until the range has had time to spawn
-- (29 squads arrive over a coroutine, not instantly) and to close with the enemy. Judging at 15 s
-- reported 2/13 simply because most squads were still marching.
local CENSUS_EVERY = 30
local CENSUS_WARMUP = 120           -- s after build before the first census is meaningful

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

-- DOCTRINE IS PINNED, not inherited. The demo squads are spawned on whichever faction this
-- mission happens to call the invaders, and doctrine is derived from the soldier's FACTION string
-- - so on a mission whose invaders are British, German-equipped demo troops would get britain's
-- profile (aggression 0.50, assaultRange 25) instead of germany's (0.75, 35). Station 4 puts its
-- enemies at exactly 25 m, so that difference decides whether the assault station works at all.
-- The brain already exposes an override for exactly this; use it so the range behaves the same on
-- any host mission. Primitives only in a Lua global, and the value comes first.
safe(function() global.set("germany", "realistic_nation_invaders") end)
safe(function() global.set("france",  "realistic_nation_defenders") end)
log2("doctrine pinned: invaders=germany, defenders=france (independent of the host mission)")

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
      note = "130 m is the whole point: it clears FIRE_DANGER_R 90 m from every friendly. "
          .. "Every barrage so far was correctly REFUSED danger close" },

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
    -- A squad spawned ON a vehicle, which is the only way the transport-reuse branch is reachable:
    -- it keys off myTransportId, remembered while MOUNTED, so a squad that never rode anything can
    -- never return to it. Measured: station 11 showed only ROAD-MARCH until this was added.
    for _, sid in ipairs(s.mounted or {}) do
        local vp = at(dx + 30, dz)
        safe(function() spawnVehicle(V_TRUCK, vp, vec3(1, 0, 0)) end)
        -- Find the truck by AREA SCAN rather than trusting spawnVehicle's return value, which is
        -- undocumented and empty (it resolves to spawnVehicleWithCallback). Relying on it made
        -- this branch always take the dismounted fallback. getVehiclesInArea is fill-style and
        -- must be called WITH a table.
        local vlist, veh = {}, nil
        safe(function() er2.getVehiclesInArea(vp, 40, vlist) end)
        for _, v in pairs(vlist) do if v then veh = v break end end
        local ok = veh and safeGet(function()
            return spawnSquadOnVehicle_script(vp, 8, INV, sid, veh, BRAIN)
        end)
        if ok then
            built = built + 1
        else
            log2("mounted spawn unavailable for '" .. tostring(sid)
                 .. "' - falling back to a dismounted squad (transport reuse will not fire)")
            spawnSquadAt(sid, at(dx, dz), INV, 12)
        end
    end

    -- Enemy side, placed enemyD metres along +X so the axis of threat is consistent
    local ed = s.enemyD or 100
    for i, sid in ipairs(s.enemy or {}) do
        spawnSquadAt(sid, at(dx + ed, dz + (i - 1) * 25), DEF, 10)
    end

    -- Vehicles: { name, offsetX, offsetZ }
    --
    -- ARG 3 IS A vec3 DIRECTION, NOT A ROTATION IN DEGREES. docs/verified-api.md documented
    -- spawnVehicle(vehicle_id, pos, rot) and a number looked like the obvious reading; it is not.
    -- MEASURED 2026-09-08 on v2.1.0: passing 180 threw
    --     bad argument #3 to 'spawnVehicleWithCallback' (userdata expected, got number)
    -- and - this is the important part - the exception ESCAPED THE ENCLOSING pcall, propagated
    -- into Unity's coroutine machinery and killed the entire phase script. The range built
    -- station 1 and then simply stopped. Same uncatchable class as the soldier_suppressed NRE:
    -- the throw happens inside the engine's own argument marshalling, before the Lua body, so
    -- pcall cannot help and a guard is NOT protection. The only safe move is to pass the right
    -- type.
    for _, v in ipairs(s.vehicles or {}) do
        if not safe(function() spawnVehicle(v[1], at(dx + v[2], dz + v[3]), vec3(1, 0, 0)) end) then
            log2("FAILED to spawn vehicle '" .. tostring(v[1]) .. "'")
            failed = failed + 1
        end
    end
    -- Emplacements face back down -X toward the German squads, who sit at the station centre.
    for i, e in ipairs(s.emplace or {}) do
        if not safe(function()
               spawnVehicle(e, at(dx + ed, dz + (i - 1) * 30), vec3(-1, 0, 0))
           end) then
            log2("FAILED to spawn emplacement '" .. tostring(e) .. "'")
            failed = failed + 1
        end
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
    local od = s.objectiveD or math.min(220, (s.enemyD or 100) + 120)
    local attract = (s.objective == "attract")
    local o = safeGet(function()
        return spawnMissionObjective(at(dx + od, dz), 45, s.name, 0, attract)
    end)
    if o then labels[#labels + 1] = s.name else failed = failed + 1 end
    if s.secondObjective then
        safe(function() spawnMissionObjective(at(dx + od, dz - 200), 45,
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
    return counts, total, hit, top, topn
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
    announce("===== SHOWCASE RANGE: station census =====")
    local working, silent = 0, 0
    for _, st in ipairs(STATIONS) do
        local counts, total, hit, top, topn = census(st)
        if total == 0 then
            announce(string.format("  %-2d %-28s  (no decisions published yet)", st.n,
                     st.name:gsub("^%d+%s*", "")))
            silent = silent + 1
        else
            announce(string.format("  %-2d %-28s %s  %s", st.n, st.name:gsub("^%d+%s*", ""),
                     hit and "OK " or "-- ", decList(counts)))
            if hit then working = working + 1 end
        end
    end
    announce(string.format("===== %d/%d stations showing an expected decision =====",
             working, #STATIONS))
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
