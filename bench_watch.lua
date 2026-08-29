--============================================================================
-- bench_watch.lua  —  read-only OBSERVER phase script (master client).
--   Every WATCH_TICK seconds it scans the battlefield and logs a compact
--   per-soldier state table [WATCH], so you can watch the brain's decisions
--   line up against ground truth while play-testing. Pairs with the [REALISTIC]
--   trace: [WATCH] tells you WHAT is true, [REALISTIC] tells you what the brain
--   DID about it.
--
--   Uses ONLY verified API (er2.getSoldiersInArea, isSameFaction,
--   getInvadersFaction, getClassName, getFaction, getPosition, isAlive). It
--   never issues orders — pure observation, safe to run alongside anything.
--
--   Deploy: use as a phase script (rename to phase_N.lua in a TEST mission), or
--   run from scripts/general via er2.run("bench_watch.lua"). Does NOT overwrite
--   RealisticEvents (phase_0.lua).
--============================================================================

local WATCH_TICK   = 4     -- s between snapshots
local WATCH_CENTRE = nil   -- vec3 to scan around; nil => use the player's position
local WATCH_RADIUS = 500   -- m
local THREAT_R     = 90    -- m, "enemies near me" radius (matches the brain's SENSE_RADIUS)

local function safeGet(fn) local ok, v = pcall(fn); if ok then return v end return nil end

if not er2.isMasterClient() then return end
local MY_PHASE = safeGet(function() return er2.getCurrentPhaseId() end) or 0
local INV = safeGet(function() return er2.getInvadersFaction() end)

local function centre()
    if WATCH_CENTRE then return WATCH_CENTRE end
    local p = safeGet(function() return er2.getPlayer() end)
    local pp = p and safeGet(function() return p.getPosition() end) or nil
    return pp or vec3(0, 0, 0)
end

local function sideTag(f)
    if INV ~= nil and safeGet(function() return er2.isSameFaction(f, INV) end) == true then return "INV" end
    return "def"
end

log("[WATCH] observer online (phase "..MY_PHASE..", every "..WATCH_TICK.."s)")

while true do
    if (safeGet(function() return er2.getCurrentPhaseId() end)) ~= MY_PHASE then return end

    local c = centre()
    local all = {}
    safeGet(function() er2.getSoldiersInArea(c, WATCH_RADIUS, all) end)

    -- first pass: split by side + collect positions for threat counting
    local inv, def = {}, {}
    for _, s in pairs(all) do
        if s and safeGet(function() return s.isAlive() end) ~= false then
            local f = safeGet(function() return s.getFaction() end)
            if sideTag(f) == "INV" then table.insert(inv, s) else table.insert(def, s) end
        end
    end

    log(string.format("[WATCH] --- snapshot: %d invaders, %d defenders alive ---", #inv, #def))

    -- per-soldier line for the invader side (the squad under test)
    for _, s in ipairs(inv) do
        local pos  = safeGet(function() return s.getPosition() end)
        local cls  = tostring(safeGet(function() return s.getClassName() end) or "?")
        local ldr  = safeGet(function() return s.isSquadLeader() end) == true
        local uid  = safeGet(function() return s.getUniqueId() end) or "?"
        local near = 0
        if pos then
            for _, e in ipairs(def) do
                local ep = safeGet(function() return e.getPosition() end)
                if ep and distance(pos, ep) <= THREAT_R then near = near + 1 end
            end
        end
        log(string.format("[WATCH]   #%s %-9s%s  enemies<%dm:%d  %s",
            tostring(uid), cls, ldr and "*LEAD" or "     ", THREAT_R, near,
            pos and string.format("(%.0f,%.0f)", pos.x, pos.z) or "(?)"))
    end

    sleep(WATCH_TICK)
end
