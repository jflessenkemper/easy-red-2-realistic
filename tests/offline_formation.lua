--============================================================================
-- offline_formation.lua — does the Schuetzenkette produce a MEASURABLE formation?
--
-- WHY THIS EXISTS. Three formation attempts have been made. Two were reverted on evidence. The
-- third (the Kette) has never been measured, because measuring it live costs ~13 min a battle and
-- needs 3+ runs per configuration to clear the metric's own 0.20-0.23 run-to-run spread. Worse,
-- .llm/kette-measurement.md argues the prediction may be UNACHIEVABLE: KETTE_FRONT = 36 caps the
-- line at +/-18 m, so a PERFECT Kette has sigma_across ~= 36/sqrt(12) ~= 10.4 m, which is NARROWER
-- than the 17.4 m actually measured for RALLY-on-MG - and narrowing the across term RAISES
-- along/across rather than dropping it below 1. So a live run could fail with working code, or
-- pass with broken code. That question is arithmetic, and arithmetic should not cost a battle.
--
-- WHAT IT DOES. Drives the REAL brain (not a reimplementation) once per man, so the actual
-- ketteSlot + rosterIndex code path runs, captures the moveTo DESTINATION each man is given, then
-- adds Gaussian pathing scatter and computes the same sigma_across / sigma_along / ratio that
-- er2-plugin/tools/movement_audit.py computes from live telemetry. Repeating that T times gives
-- the DISTRIBUTION, which is what a single battle can never provide.
--
-- The scatter model is the load-bearing assumption and it is stated, not hidden: the engine's own
-- pathing scatter was measured at ~13 m sigma, and every doctrinal interval is below it
-- (Schuetzenkette 4-5 m is 0.31-0.38 sigma). SCATTER is injectable so the sensitivity can be seen.
--
-- Usage:  luajit tests/offline_formation.lua [trials] [scatter_m]
--============================================================================

local TRIALS  = tonumber(arg and arg[1]) or 400
local SCATTER = tonumber(arg and arg[2]) or 13.0
local SQUAD_N = 10          -- KStN 131c: the squad was TEN men by May 1940
local GUN_D   = 60          -- men start this far from the gunner (> MG_COHESION 25 so it fires)
local START_SPREAD = 15     -- how scattered the men are before they form up

--=================== deterministic RNG =====================================
-- Our own generator, NOT math.random: the brain calls math.randomseed(uid) at bootstrap, so it
-- reseeds the global RNG on every single load and would make the scatter correlate with uid.
local seed = 20260908
local function rnd()
    seed = (1103515245 * seed + 12345) % 2147483648
    return seed / 2147483648
end
local function gauss(sigma)                      -- Box-Muller
    local u1, u2 = rnd(), rnd()
    if u1 < 1e-12 then u1 = 1e-12 end
    return sigma * math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

--=================== stats =================================================
local function pstdev(t)
    local n = #t
    if n < 2 then return 0 end
    local m = 0; for i = 1, n do m = m + t[i] end; m = m / n
    local s = 0; for i = 1, n do local d = t[i] - m; s = s + d * d end
    return math.sqrt(s / n)
end
local function median(t)
    local c = {}; for i = 1, #t do c[i] = t[i] end
    table.sort(c)
    local n = #c
    if n == 0 then return 0 / 0 end
    if n % 2 == 1 then return c[(n + 1) / 2] end
    return (c[n / 2] + c[n / 2 + 1]) / 2
end
local function pct(t, p)
    local c = {}; for i = 1, #t do c[i] = t[i] end
    table.sort(c)
    if #c == 0 then return 0 / 0 end
    local i = math.floor(p * (#c - 1)) + 1
    return c[i]
end

--=================== the brain, loaded per man ==============================
local SRC = io.open("Realistic.lua"):read("a")

local function brainSource(variant)
    local s = SRC:gsub("local DEBUG%s*=%s*false", "local DEBUG = true", 1)
                 :gsub("local VERBOSE%s*=%s*false", "local VERBOSE = true", 1)
    if variant == "blob" then
        -- PRE-KETTE control: every man is handed the gunner's position, which is exactly what
        -- RALLY-on-MG did before commit 7d61445 added ketteSlot.
        local n
        s, n = s:gsub("local slot = %(fx and ketteSlot%(mgPos, fx, fz, pos%)%) or mgPos",
                      "local slot = mgPos")
        assert(n == 1, "blob substitution missed - the RALLY-on-MG call site changed")
    end
    return s
end
local SRC_KETTE = brainSource("kette")
local SRC_BLOB  = brainSource("blob")

local function v3(x, y, z) return { x = x, y = y or 0, z = z } end

-- One man's brain run. Returns the destination moveTo was given, or nil.
local function runMan(src, roster, meIdx, objective)
    local dest, decided = nil, nil
    local me = roster[meIdx]

    local squad = {
        getSquadSize   = function() return #roster end,
        getAllMembers  = function(t) for i = 1, #roster do t[i] = roster[i].obj end return t end,
        isPlayerInSquad = function() return false end,
    }

    local function mk(m)
        local s = {}
        s.getUniqueId       = function() return m.uid end
        s.getPosition       = function() return m.pos end
        s.getFaction        = function() return "Germany_axis" end
        s.getName           = function() return "Test" end
        s.getClassName      = function() return m.class or "rifleman" end
        s.getHealth         = function() return 100 end
        s.isAlive           = function() return true end
        s.isIncapacitated   = function() return false end
        s.isSuppressed      = function() return false end
        s.isSquadLeader     = function() return false end
        s.isATSoldier       = function() return false end
        s.isMedic           = function() return false end
        s.isRadioman        = function() return false end
        s.isMarksman        = function() return false end
        s.isAmmoBoxCarrier  = function() return false end
        s.isCarryingBody    = function() return false end
        s.getCurrentVehicle = function() return nil end
        s.getSquad          = function() return squad end
        s.isSquadReady      = function() return true end
        s.getAiParams       = function() return {} end
        s.moveTo   = function(p) dest = p end
        s.findCover= function() end
        s.stop=function() end s.say=function() end s.alertFor=function() end
        s.forceTarget=function() end s.carryBody=function() return true end
        s.leaveVehicle=function() end s.boardVehicle=function() end s.setBrain=function() end
        return s
    end
    for i = 1, #roster do roster[i].obj = mk(roster[i]) end

    local clock, ticks = 100, 0
    local STOP = "__stop__"
    _G.myself   = function() return roster[meIdx].obj end
    _G.vec3     = v3
    -- 3D, matching the engine: probe distance((0,0,0),(0,4,3)) = 5. The main offline harness
    -- stubs this as 2D, which is harmless on flat ground and wrong on terrain.
    _G.distance = function(a, b)
        local dx, dy, dz = a.x - b.x, (a.y or 0) - (b.y or 0), a.z - b.z
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    _G.log      = function(m) local l = tostring(m):match("%->%s+([A-Za-z/%-]+)")
                              if l then decided = l end end
    _G.sayMissionClip = function() end
    _G.VoiceClip = setmetatable({}, { __index = function() return 0 end })
    _G.sleep = function()
        ticks = ticks + 1; clock = clock + 2.0
        if ticks >= 4 then error(STOP, 0) end
    end
    _G.global = { set = function() end, get = function() return nil end }
    _G.er2 = {
        time = function() return clock end,
        getInvadersFaction = function() return "Germany_axis" end,
        isSameFaction = function(a, b) return a == b end,
        getNearestObjective = function()
            return { getPosition = function() return objective end }
        end,
        getTerrainHeight = function() return 0 end,
        getSoldiersInArea = function(_, _, out)
            for i = 1, #roster do out[i] = roster[i].obj end
            return out
        end,
        getVehiclesInArea = function(_, _, out) return out end,
        findVehicle = function() return nil end,
    }

    local fn = assert(load(src, "=brain"))
    local ok, err = pcall(fn)
    if not ok and tostring(err):find(STOP, 1, true) == nil and not tostring(err):find("__stop__") then
        return nil, nil, tostring(err)
    end
    return dest, decided, nil
end

--=================== one trial ==============================================
-- Builds a squad, runs every man, returns sigma_across / sigma_along / ratio of where the men
-- END UP (destination + pathing scatter), measured about the mean direction of travel exactly as
-- movement_audit.formation() does on live telemetry.
local function trial(src)
    -- random march axis so no result is an artefact of one bearing
    local th = rnd() * 2 * math.pi
    local ax, az = math.cos(th), math.sin(th)
    local gun = v3(0, 0, 0)
    local objective = v3(gun.x + ax * 400, 0, gun.z + az * 400)

    local roster = {}
    -- man 1 is the Support gunner, at the origin
    roster[1] = { uid = 1000, pos = gun, class = "Support Gunner" }
    for i = 2, SQUAD_N do
        -- the squad sits GUN_D behind the gunner, loosely scattered
        local bx = gun.x - ax * GUN_D + gauss(START_SPREAD)
        local bz = gun.z - az * GUN_D + gauss(START_SPREAD)
        roster[i] = { uid = 1000 + (i - 1) * 262, pos = v3(bx, 0, bz), class = "rifleman" }
    end

    local pts, decisions = {}, {}
    for i = 2, SQUAD_N do
        local dest, decided, err = runMan(src, roster, i, objective)
        if err then return nil, err end
        decisions[decided or "(none)"] = (decisions[decided or "(none)"] or 0) + 1
        if dest then
            -- where he ACTUALLY ends up: his ordered slot plus engine pathing scatter
            local ex = dest.x + gauss(SCATTER)
            local ez = dest.z + gauss(SCATTER)
            pts[#pts + 1] = { x = ex, z = ez,
                              hx = ex - roster[i].pos.x, hz = ez - roster[i].pos.z }
        end
    end
    if #pts < 3 then return nil, nil, decisions end

    -- mean unit heading, then project onto across/along - movement_audit's exact maths
    local hx, hz = 0, 0
    for _, p in ipairs(pts) do
        local m = math.sqrt(p.hx * p.hx + p.hz * p.hz)
        if m > 0 then hx = hx + p.hx / m; hz = hz + p.hz / m end
    end
    hx, hz = hx / #pts, hz / #pts
    local n = math.sqrt(hx * hx + hz * hz)
    if n < 0.3 then return nil, nil, decisions end   -- no coherent direction, same guard as the tool
    hx, hz = hx / n, hz / n
    local px, pz = -hz, hx
    local across, along = {}, {}
    for _, p in ipairs(pts) do
        across[#across + 1] = p.x * px + p.z * pz
        along[#along + 1]   = p.x * hx + p.z * hz
    end
    local a, b = pstdev(across), pstdev(along)
    return { across = a, along = b, ratio = (a > 0.01) and (b / a) or (0 / 0) }, nil, decisions
end

--=================== run ====================================================
print(string.format("offline formation: %d trials, %d-man squad, pathing scatter sigma %.1f m",
      TRIALS, SQUAD_N, SCATTER))
print("(drives the REAL ketteSlot/rosterIndex path in Realistic.lua, one brain load per man)\n")

local results = {}
for _, variant in ipairs({ { "blob (pre-Kette control)", SRC_BLOB }, { "KETTE (as shipped)", SRC_KETTE } }) do
    local name, src = variant[1], variant[2]
    local rs, as, bs = {}, {}, {}
    local decAll, fail = {}, nil
    for _ = 1, TRIALS do
        local r, err, decs = trial(src)
        if err then fail = err break end
        if decs then for k, v in pairs(decs) do decAll[k] = (decAll[k] or 0) + v end end
        if r and r.ratio == r.ratio then
            rs[#rs + 1] = r.ratio; as[#as + 1] = r.across; bs[#bs + 1] = r.along
        end
    end
    if fail then
        print("  " .. name .. ": BRAIN ERROR: " .. fail)
        os.exit(1)
    end
    local top, tn = "(none)", -1
    for k, v in pairs(decAll) do if v > tn then top, tn = k, v end end
    print(string.format("%-26s n=%d  decision seen most: %s (%d)", name, #rs, top, tn))
    if #rs > 0 then
        print(string.format("   across  median %5.1f m", median(as)))
        print(string.format("   along   median %5.1f m", median(bs)))
        print(string.format("   ratio   median %5.2f   p10 %5.2f   p90 %5.2f   (p90-p10 = %.2f)",
              median(rs), pct(rs, 0.10), pct(rs, 0.90), pct(rs, 0.90) - pct(rs, 0.10)))
    end
    results[name] = { ratio = median(rs), across = median(as), along = median(bs),
                      p10 = pct(rs, 0.10), p90 = pct(rs, 0.90), n = #rs }
end

--=================== verdict ================================================
local blob = results["blob (pre-Kette control)"]
local kette = results["KETTE (as shipped)"]
print("")
if blob.n == 0 or kette.n == 0 then
    print("VERDICT: inconclusive - one variant produced no measurable trial.")
    os.exit(1)
end
local delta = kette.ratio - blob.ratio
local LIVE_SPREAD = 0.23     -- the widest recorded run-to-run spread of this metric
print(string.format("Kette moves the ratio by %+.2f (%.2f -> %.2f).", delta, blob.ratio, kette.ratio))
print(string.format("The metric's recorded LIVE run-to-run spread is %.2f.", LIVE_SPREAD))
if math.abs(delta) <= LIVE_SPREAD then
    print("=> The effect is INSIDE the live noise band. No number of battles could attribute it")
    print("   to the Kette rather than to variance. The prediction 'ratio drops below 1' is not")
    print("   testable at this frontage, which is what the arithmetic already implied.")
else
    print("=> The effect EXCEEDS the live noise band, so it is worth measuring in a battle.")
end
if kette.ratio > blob.ratio then
    print("   Note the direction: the Kette RAISES the ratio. The prediction was that it would")
    print("   drop BELOW 1, so the prediction is wrong in sign as well as in magnitude.")
end
