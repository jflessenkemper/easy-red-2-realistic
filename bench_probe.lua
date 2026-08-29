--============================================================================
-- bench_probe.lua  —  attach as a SQUAD BRAIN in a throwaway test mission.
--   One-run diagnostic: logs [BENCH] lines telling you which soldier/aiParams
--   methods actually exist on THIS build, and dumps the full VoiceClip enum
--   (so you get the exact fire/burn clip name to use as the scared cry).
--   Read the results in the F3 console or Player.log. Delete after use.
--
--   Existence is tested by INDEXING only (never calling) so it has no side
--   effects and cannot crash the unit. `exists` = the member is a function.
--============================================================================

local me = myself()
if not me then return end

local function member(obj, name)
    local ok, v = pcall(function() return obj[name] end)
    if not ok then return "err" end
    if v == nil then return "MISSING" end
    return type(v)   -- expect "function"
end

local function report(label, obj, names)
    log("[BENCH] ---- "..label.." ----")
    for _, n in ipairs(names) do
        log("[BENCH]   "..n.." = "..member(obj, n))
    end
end

-- 1) Soldier surface (verified + handoff-guessed, so we learn which guesses are real)
report("Soldier", me, {
    -- verified in shipped corpus:
    "getUniqueId","getPosition","getFaction","isAlive","forceTarget","alertFor",
    "moveTo","getSquad","isSquadLeader","isSquadReady","getCurrentVehicle","setBrain",
    -- handoff-only (unconfirmed) — the ones we most want to settle:
    "getHealth","isIncapacitated","isCarried","isCarryingBody","getName","getClassName",
    "getId","stop","findCover","boardVehicle","leaveVehicle","damageSoldier","killSoldier",
    "say","sayClip","carryBody","dropBody","rescue","healSoldier","reviveSoldier",
})

-- 2) aiParams surface
local p = nil
do local ok, v = pcall(function() return me.aiParams end); if ok and v ~= nil then p = v end end
-- v2.0.9 reported .aiParams MISSING; try the getter form and report which works
if not p then
    local ok, v = pcall(function() return me.getAiParams() end)
    log("[BENCH]   me.getAiParams() = "..(ok and (v ~= nil and "ok (USE THIS)" or "nil") or "MISSING/err"))
    if ok and v ~= nil then p = v end
end
if p then
    report("aiParams", p, {
        "enableAiBehaviour","allowMovements","allowFollowOrders","allowFindCoverWhenSuppressed",
        "allowCheckForEnemies","allowBeingTargeted","allowDoMedic","allowChangePose",
        "allowGiveOrders","allowLeaveVehicle","allowOpenWindows","allowRadioOrders",
        "followCustomDirectCommands","followCustomSquadOrders","setTargetPlanesOften",
    })
else
    log("[BENCH] aiParams = MISSING (no .aiParams property on this build)")
end

-- 3) Squad surface (if we have one)
local sq = nil
do local ok, v = pcall(function() return me.getSquad() end); if ok then sq = v end end
if sq then
    report("Squad", sq, {
        "moveTo","charge","coverArea","attackFromPoint","holdFire","fireAtWill",
        "followLeader","getLeader","getMedic","hasAliveMembers","getMembers",
        "getSoldiers","getSize","getInitialSize","getMaxSize","setClosestObjective",
        "setRandomObjective","alertEnemies","cancelRadioRequest",
    })
else
    log("[BENCH] Squad = nil (unit has no squad, or getSquad MISSING)")
end

-- 4) VoiceClip enum — the big one. Dump every member so we get real names,
--    especially the FIRE/BURN line to reuse as the scared cry.
local vc = nil
do local ok, v = pcall(function() return VoiceClip end); if ok then vc = v end end
if vc then
    log("[BENCH] ---- VoiceClip enum (all members) ----")
    local n = 0
    local ok = pcall(function()
        for k, val in pairs(vc) do
            log("[BENCH]   VoiceClip."..tostring(k).." = "..tostring(val))
            n = n + 1
        end
    end)
    if not ok or n == 0 then
        log("[BENCH] VoiceClip exists but is not pairs-iterable ("..tostring(n)
            .."); try Script Settings -> Id tables in-game for the list")
    else
        log("[BENCH] VoiceClip member count = "..n)
    end
else
    log("[BENCH] VoiceClip = MISSING as a global (check Script Settings -> Id tables)")
end

-- 4b) Vehicle scan + Vehicle methods (for "advance behind armour").
--     getVehiclesInArea is CONFIRMED to exist (engine error string); confirm its
--     namespace (er2.* vs global) and the Vehicle method names here.
do
    log("[BENCH] ---- vehicle scan ----")
    local vlist = {}
    local ok1 = pcall(function() er2.getVehiclesInArea(me.getPosition(), 300, vlist) end)
    log("[BENCH]   er2.getVehiclesInArea = "..(ok1 and ("ok, found "..#vlist) or "MISSING/err"))
    if not ok1 then
        local vlist2 = {}
        local ok2 = pcall(function() getVehiclesInArea(me.getPosition(), 300, vlist2) end)
        log("[BENCH]   getVehiclesInArea (global) = "..(ok2 and ("ok, found "..#vlist2) or "MISSING/err"))
        vlist = vlist2
    end
    log("[BENCH]   er2.getNearestVehicle = "..member(er2, "getNearestVehicle"))
    local v = vlist and vlist[1] or nil
    if v then
        report("Vehicle[1]", v, {
            "getPosition","getFaction","getName","getClassName","isEmpty",
            "getHealth","isAlive","getUniqueId","playerIsInside",
        })
    else
        log("[BENCH]   no vehicle in 300m to probe methods on (place a tank near the test squad)")
    end
end

-- 5) health scale probe (only reads, if getHealth exists)
do
    local ok, h = pcall(function() return me.getHealth() end)
    if ok and h ~= nil then
        log("[BENCH] getHealth() sample = "..tostring(h).."  (>1 => 0..100 scale, <=1 => 0..1)")
    else
        log("[BENCH] getHealth() not callable on this build")
    end
end

-- 6) doctrine inputs: class name value + which side am I (for faction styles)
do
    log("[BENCH] ---- doctrine inputs ----")
    local cn = pcall(function() return me.getClassName() end) and me.getClassName() or nil
    log("[BENCH]   getClassName() = "..tostring(cn).."  (expect Rifleman/Support/Assault/Medic/...)")
    local inv = pcall(function() return er2.isSameFaction(me.getFaction(), er2.getInvadersFaction()) end)
                and er2.isSameFaction(me.getFaction(), er2.getInvadersFaction()) or nil
    log("[BENCH]   amInvader = "..tostring(inv).."  (invader=attacker side)")
end

log("[BENCH] probe complete — copy [BENCH] lines back to the dev.")
