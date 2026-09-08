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
        -- GROUND TRUTH from the engine itself, not inferred from position deltas. This is the
        -- point of the whole file: the project's standing problem has been that "a decision label
        -- is not proof of behaviour", so every cover/pinned/drag claim was judged by a speed
        -- threshold, and analyse_run.py openly concedes 16 of its labels are ungateable that way
        -- (a man sprinting to a wall and a man refusing to move both look wrong against one of the
        -- two thresholds). These reads answer the question directly.
        --
        -- All verified present on v2.0.9 by the 2026-08-29 probe (docs/verified-api.md:300-369)
        -- and all guarded anyway, so a build without one degrades to "?" instead of dying.
        -- Kept in the OBSERVER, never the brain: Realistic.lua is at the Lua 200-local ceiling and
        -- this file issues no orders, so it is safe to run alongside anything.
        local onCover = safeGet(function() return s.isOnCover() end)
        local moving  = safeGet(function() return s.isMoving() end)
        local crawl   = safeGet(function() return s.isCrawling() end)
        local supv    = safeGet(function() return s.getSuppressionValue() end)
        local carry   = safeGet(function() return s.isCarryingBody() end)
        local vel     = safeGet(function() return s.getVelocity() end)
        local spd
        if vel then
            spd = safeGet(function() return math.sqrt(vel.x * vel.x + vel.z * vel.z) end)
        end
        local function tri(v) if v == true then return "1" elseif v == false then return "0" end return "?" end

        -- Machine-readable, one soldier per line, fixed field order. Parsed by
        -- er2-plugin/tools/watch_audit.py.
        log(string.format("[WATCH]   #%s %-9s%s  enemies<%dm:%d  %s"
            .. "  cover:%s move:%s crawl:%s carry:%s sup:%s spd:%s",
            tostring(uid), cls, ldr and "*LEAD" or "     ", THREAT_R, near,
            pos and string.format("(%.0f,%.0f)", pos.x, pos.z) or "(?)",
            tri(onCover), tri(moving), tri(crawl), tri(carry),
            supv and string.format("%.2f", supv) or "?",
            spd and string.format("%.2f", spd) or "?"))
    end

    sleep(WATCH_TICK)
end
