--============================================================================
-- RealisticEvents.lua  —  mission PHASE script (master client). Deploy as
--   <MISSION>/scripts/mission/phase_0.lua.
--   On-screen feed = ONE thing only: a death message for a member of the PLAYER'S OWN
--   squad, formatted "<name> (<role>) killed by <weapon>". Weapon only — never the killer's
--   name. Squad identity is real on this build (getSquad()/isPlayerInSquad() confirmed by the
--   2026-08-29 in-game probe: 315/371 soldiers resolved a real squad), so the squad tier is
--   PRIMARY; own-side-within-FEED_RADIUS survives only as a fallback for the deaths where the
--   squad cannot be resolved, so the feed is never silent. Everything else — battalion tally,
--   attraction, bail-out, fire missions — is LOG ONLY and never reaches the screen.
--   Also hosts the phase half of crew bail-out (feature 18) and the consumer half of the
--   radioman fire mission (feature 19; Realistic.lua is the producer).
--   Verified against build v2.0.9 (see .llm/api/verified-api.md).
--============================================================================

local DEBUG = false
-- TRACE_LOOP: per-tick top/pre-sleep markers, to locate WHERE the loop stops. The loop reliably
-- dies at objective capture with no error and no idle line, and the last thing it ever logs is the
-- final statement of the attraction block — which leaves the unprotected `tick = tick + 1` and
-- `sleep(1)` as the only untested ground. A "top" with no matching "pre-sleep" means the body
-- died; a "pre-sleep" with no following "top" means sleep() never resumed the coroutine.
-- Diagnostic only. check.sh check 6 refuses to ship this true.
local TRACE_LOOP = false

--========================== CONFIG ==========================================
local FIRE_SUPPORT_TARGETS = {}   -- fill with P-key vec3s to enable a radioman barrage
local BARRAGE_SHELLS  = 24
local BARRAGE_SCATTER = 70    -- m, radius of the beaten zone shells fall within
-- er2.explosion(pos, damage, penetration_mm, blast_radius_m) — arg3 is PENETRATION, arg4 is RADIUS
local BARRAGE_DAMAGE      = 55   -- per-shell damage (0-100 scale)
local BARRAGE_PENETRATION = 80   -- mm; enough to hurt infantry and thin-skinned vehicles
local BARRAGE_BLAST       = 10   -- m, per-shell blast radius
local SHELL_INTERVAL  = 0.8
local SUPPORT_WARNING = 12
local THREAT_TTL      = 12    -- s, a recorded threat older than this is not trusted as the killer
local NEAR_ENEMY_R    = 60    -- m, radius for the nearest-enemy weapon fallback
-- Kill-feed scope. PRIMARY = the player's own squad (getSquad + isPlayerInSquad, both confirmed).
-- FALLBACK ONLY = own side within this radius of the player, used when the squad cannot be
-- resolved (a soldier probed at the instant of spawn has no squad yet) so the feed never goes
-- silent on a map where squads fail to bind.
local FEED_RADIUS     = 120   -- m

-- Radioman fire mission (feature 19) — CONSUMER half; Realistic.lua is the producer.
local FIRE_DANGER_R    = 90   -- m, refuse the mission if ANY friendly of the requesting side is this close
local FIRE_MIN_GAP     = 150  -- s, minimum gap between two accepted fire missions (phase-wide anti-spam)
local FIRE_MAX         = 3    -- accepted fire missions per phase
local PROBE_GLOBALS    = false -- ANSWERED 2026-08-29: yes, shared (brain wrote PROBE_B2P=4242,
                               -- phase read it back). Flip true only to re-check.
local PROBE_EVERY      = 30   -- cycles between gprobe lines (never per tick)
local fireTick         = 0
local ROLE_REFRESH     = 5    -- loop cycles between role-cache refresh passes
local ROLE_REFRESH_MAX = 60   -- soldiers re-checked per pass, so one pass is never a spike
local FIRE_SHELLS_TICK = 3    -- hard cap on shells fired in one 1 s cycle (the loop paces the barrage)

-- Crew bail-out (feature 18) — phase half.
local BAIL_RADIUS     = 10    -- m, wreck-side scan radius when the native crew query comes up empty
local BAIL_ALERT      = 20    -- s, alertFor() applied to a crewman who just bailed out
local BAIL_PER_TICK   = 4     -- wrecks processed per 1 s cycle (the QUEUE is drained, never the callback)
local BAIL_QUEUE_MAX  = 24    -- queued wrecks; further events are dropped rather than grow unbounded

--========================== HELPERS =========================================
local function dbg(m) if DEBUG then log("[EVENTS] "..m) end end
local function safeGet(fn) local ok, v = pcall(fn); if ok then return v end return nil end
-- safe(): run a VOID call, return whether it succeeded. Distinct from safeGet, which returns the
-- VALUE. This was used four times before it existed — a nil global, so every call raised and the
-- enclosing pcall swallowed it. That silently disabled the role refresher, both speaker-election
-- paths of the death callout, AND the say() itself. Nothing errored; the feature just never fired.
local function safe(fn) local ok = pcall(fn); return ok end
local function announce(m) log("[EVENTS] "..m); pcall(function() print(m) end) end  -- on-screen + log
local function logonly(m) if DEBUG then log("[EVENTS] "..m) end end                 -- log only
local function now() return safeGet(function() return er2.time() end) or 0 end

if not er2.isMasterClient() then return end

local INV = safeGet(function() return er2.getInvadersFaction() end)
local DEF = safeGet(function() return er2.getDefendersFaction() end)
local MY_PHASE = safeGet(function() return er2.getCurrentPhaseId() end) or 0

-- GEOMETRY PROBE (one shot, DEBUG only). distance() is an ENGINE global, so all ~19 call sites in
-- the brain are interop hops and replacing them with inline Lua maths is the single biggest
-- remaining optimisation. That is only safe if we know whether it measures in 2D or 3D: guessing
-- wrong silently changes who counts as "within PINNED_RADIUS" on sloped ground, which is exactly
-- the kind of quiet behaviour change this project has been bitten by before.
-- The two points below are 3 apart in x/z and 4 apart in y, so 3D gives 5 and 2D gives 3. There
-- is no ambiguity in the answer.
if DEBUG then
    local d = safeGet(function() return distance(vec3(0, 0, 0), vec3(0, 4, 3)) end)
    log("[EVENTS] geometry: distance((0,0,0),(0,4,3)) = " .. tostring(d)
        .. "   -> 5 means 3D (x,y,z); 3 means 2D (x,z only)")
end

local function nameOf(s)
    return safeGet(function() return s.getName() end)
        or ("#"..tostring(safeGet(function() return s.getUniqueId() end) or "?"))
end
-- role = the soldier's job in the squad. Uses the NATIVE role flags (confirmed 2026-08-29:
-- isSquadLeader/isATSoldier/isMedic/isRadioman/isMarksman), never a getClassName substring —
-- the flags are language- and mod-proof, and string matching had a real ordering hazard
-- ("Tank Hunter" was swallowed by the crew test). getClassName survives only as the fallback
-- for the two jobs with no native flag: the Support gunner and the mortar crew.
local function flag(s, name)
    return safeGet(function() return s[name](s) end) == true
        or safeGet(function() return s[name]() end) == true
end
local function roleOf(s)
    if flag(s, "isSquadLeader") then return "leader"   end
    if flag(s, "isATSoldier")   then return "AT"       end
    if flag(s, "isMedic")       then return "medic"    end
    if flag(s, "isRadioman")    then return "radioman" end
    if flag(s, "isMarksman")    then return "marksman" end
    local cn = tostring(safeGet(function() return s.getClassName() end) or ""):lower()
    if cn:find("support") then return "gunner" end
    if cn:find("mortar")  then return "mortar" end
    return "rifleman"
end
local function sideOf(f)
    if INV ~= nil and safeGet(function() return er2.isSameFaction(f, INV) end) == true then return "invader" end
    if DEF ~= nil and safeGet(function() return er2.isSameFaction(f, DEF) end) == true then return "defender" end
    return "?"
end

-- Weapon inferred from the killer's role (there is no death-weapon API on this build). Native
-- role flags first, getClassName only for the jobs that have no flag. The killer's NAME is
-- never surfaced — the feed says what killed you, not who.
local function weaponOf(s)
    if flag(s, "isATSoldier")          then return "an anti-tank weapon" end
    if flag(s, "isMarksman")           then return "a sniper" end
    if flag(s, "isFlameThrowerCarrier")then return "a flamethrower" end
    local cn = tostring(safeGet(function() return s.getClassName() end) or ""):lower()
    if     cn:find("support")                        then return "machine-gun fire"
    elseif cn:find("assault")                        then return "a submachine gun"
    elseif cn:find("sniper") or cn:find("marksman")  then return "a sniper"
    elseif cn:find("bazooka") or cn:find("panzer") or cn:find("anti") or cn:find("at unit") then return "an anti-tank weapon"
    elseif cn:find("flame")                          then return "a flamethrower"
    elseif cn:find("mortar")                         then return "a mortar"
    elseif cn:find("engineer")                       then return "an explosive charge"
    elseif cn:find("rifle")                          then return "rifle fire"
    elseif cn ~= ""                                  then return "small-arms fire"
    else return "enemy fire" end
end

--========================== ATTRIBUTION =====================================
-- record the last ENEMY that suppressed/targeted each soldier -> {weap, t}; side-filtered
-- (never a friendly) and TTL'd (a stale contact is not the killer).
local lastThreat = {}
local function isEnemyOf(a, b)
    local fa = safeGet(function() return a.getFaction() end)
    local fb = safeGet(function() return b.getFaction() end)
    if fa == nil or fb == nil then return false end
    return safeGet(function() return er2.isSameFaction(fa, fb) end) ~= true
end
local function note(victim, shooter)
    if victim == nil or shooter == nil then return end
    if not isEnemyOf(victim, shooter) then return end
    local vu = safeGet(function() return victim.getUniqueId() end)
    if not vu then return end
    lastThreat[vu] = { weap = weaponOf(shooter), t = now() }
end
-- DO NOT SUBSCRIBE TO soldier_suppressed ON THIS BUILD.
-- Verified in-game: the engine throws inside its OWN dispatch when that event fires with a
-- null shooter (a bullet impact with no attributable source):
--     Lua error at 'Global Callbacks' ... Object reference not set
--     LuaCallbackHandler:Call(String, Delegate, DynValue[])
--     Soldier:Suppress(Int32, Soldier)  <- BulletInstance:OnHit
-- The NRE happens marshalling the arguments, BEFORE any Lua body executes, so wrapping the
-- handler in pcall does NOT help (tested: errors continued). It fires on the bullet hot path,
-- so the only mitigation is not to subscribe. Attribution is unaffected in practice:
-- soldier_target_inf_acquired still supplies the shooter, and weaponForDeath() falls back to
-- the nearest enemy at time of death.
pcall(function() er2.setCallback("soldier_target_inf_acquired",
    function(a, b) pcall(function() note(a, b); note(b, a) end) end) end)

-- fallback: weapon of the nearest enemy to the victim at time of death
local function nearestEnemyWeapon(victim)
    local pos = safeGet(function() return victim.getPosition() end)
    local vf  = safeGet(function() return victim.getFaction() end)
    if pos == nil or vf == nil then return nil end
    local list = {}
    if not pcall(function() er2.getSoldiersInArea(pos, NEAR_ENEMY_R, list) end) then return nil end
    local best, bestD = nil, 1e18
    for _, s in pairs(list) do
        if s then
            local sf = safeGet(function() return s.getFaction() end)
            if sf ~= nil and safeGet(function() return er2.isSameFaction(sf, vf) end) ~= true then
                local sp = safeGet(function() return s.getPosition() end)
                if sp then
                    local dx, dz = sp.x - pos.x, sp.z - pos.z
                    local d = dx * dx + dz * dz
                    if d < bestD then best, bestD = s, d end
                end
            end
        end
    end
    return best and weaponOf(best) or nil
end
local function weaponForDeath(victim)
    local vu = safeGet(function() return victim.getUniqueId() end)
    local t  = vu and lastThreat[vu] or nil
    if t and (now() - t.t) <= THREAT_TTL then return t.weap end
    return nearestEnemyWeapon(victim) or "enemy fire"
end

--========================== PLAYER'S-SQUAD SCOPE (defect 2.10) ==============
-- PRIMARY tier = the player's own squad, which is real on this build. The old note claiming
-- "getSquad() returns nil, so the squad tier is dead" was retracted by the 2026-08-29 in-game
-- probe: 315 of 371 soldiers resolved a real Squad, and Squad.isPlayerInSquad/getAllMembers/
-- getSquadSize are all confirmed. The 56 nils were a SPAWN-INSTANT TIMING artefact, not a
-- context limit — so a nil squad is only ever treated as "unresolved for this one death", never
-- as "this build has no squads".
--   1. victim.getSquad():isPlayerInSquad()  — definitive yes/no.
--   2. the PLAYER's squad roster contains the victim's uid — recovers the timing nils, since
--      the player's squad resolves long before any of its members die.
--   3. FALLBACK ONLY: own side within FEED_RADIUS of the player, so the feed is never silent
--      on a map where squads fail to bind entirely.
-- The whole team is NEVER in scope at any tier.
local scopeLogged = nil
local function scopeNote(kind, msg)
    if scopeLogged ~= kind then scopeLogged = kind; dbg("feed scope = " .. msg) end
end

local function playerSquad()
    local p = safeGet(function() return er2.getPlayer() end)
    if not p then return nil, nil end         -- nil during phase load; resolved lazily, not cached
    return p, safeGet(function() return p.getSquad() end)
end

-- tier 2: is the victim on the player's squad roster? nil = could not tell (never false-negatives
-- into a silent feed — an unresolvable roster falls through to the radius tier).
local function onPlayerRoster(victim, psq)
    if psq == nil then return nil end
    local vu = safeGet(function() return victim.getUniqueId() end)
    if vu == nil then return nil end
    local mem = {}
    local ok, ret = pcall(function() return psq.getAllMembers(mem) end)
    if not ok then return nil end
    if #mem == 0 and type(ret) == "table" then mem = ret end   -- fill-style or return-style
    if #mem == 0 then return nil end
    for _, m in pairs(mem) do
        if m and tostring(safeGet(function() return m.getUniqueId() end)) == tostring(vu) then
            return true
        end
    end
    return false
end

local function onChosenSquad(victim)
    local p, psq = playerSquad()

    -- 1) the victim's own squad knows whether the player is in it
    local vsq = safeGet(function() return victim.getSquad() end)
    if vsq ~= nil then
        local inSquad = safeGet(function() return vsq.isPlayerInSquad() end)
        if inSquad == nil then inSquad = safeGet(function() return vsq.isPlayerInSquad(vsq) end) end
        if inSquad == true  then scopeNote("squad", "the player's own squad (isPlayerInSquad)"); return true  end
        if inSquad == false then scopeNote("squad", "the player's own squad (isPlayerInSquad)"); return false end
    end

    -- 2) squad unresolved for this soldier — check the player's roster instead
    local onRoster = onPlayerRoster(victim, psq)
    if onRoster ~= nil then
        scopeNote("roster", "the player's own squad (roster match; victim's getSquad was nil)")
        return onRoster
    end

    -- 3) FALLBACK ONLY: squads could not be resolved at all — own side, near the player
    if not p then return false end            -- nil during phase load; nothing to scope to yet
    local pf = safeGet(function() return p.getFaction() end)
    local vf = safeGet(function() return victim.getFaction() end)
    if pf == nil or vf == nil then return false end
    if safeGet(function() return er2.isSameFaction(pf, vf) end) ~= true then return false end
    local pp = safeGet(function() return p.getPosition() end)
    local vp = safeGet(function() return victim.getPosition() end)
    if pp == nil or vp == nil then return false end
    scopeNote("prox", "FALLBACK own side within " .. FEED_RADIUS .. "m of the player "
        .. "(squad could not be resolved)")
    return distance(pp, vp) <= FEED_RADIUS
end

--========================== SCRIPTED TEST SPAWNS (optional) =================
-- Build a test scenario from the API instead of placing units by hand in the editor.
-- Leave TEST_SPAWNS empty for a normal mission; fill it to bench the brain.
--   pos    : vec3 (press P in the editor to copy a world position)
--   side   : "invader" | "defender"
--   squad  : squad template id (see Script Settings -> Id tables in-game)
--   radius : spawn scatter, metres
-- Uses spawnSquad_script so each squad gets Realistic.lua attached at spawn time.
local TEST_SPAWNS = {
    -- { pos = vec3(0, 0, 0),   side = "invader",  squad = "ger_rifle_squad", radius = 12 },
    -- { pos = vec3(0, 0, 120), side = "defender", squad = "fra_rifle_squad", radius = 12 },
}
local TEST_OBJECTIVE = nil     -- e.g. vec3(0,0,60); nil = don't create one
local TEST_OBJ_RADIUS = 40

if #TEST_SPAWNS > 0 then
    for i, s in ipairs(TEST_SPAWNS) do
        local fac = (s.side == "invader") and INV or DEF
        local ok, sq = pcall(function()
            return spawnSquad_script(s.pos, s.radius or 12, fac, s.squad, "Realistic.lua")
        end)
        if not ok or sq == nil then
            -- fall back to a brainless spawn; auto-attach below will still catch the soldiers
            ok = pcall(function() spawnSquad(s.pos, s.radius or 12, fac, s.squad) end)
        end
        dbg(string.format("test spawn %d: %s %s -> %s", i, s.side, tostring(s.squad),
            ok and "ok" or "FAILED (check the squad id in Id tables)"))
    end
end
if TEST_OBJECTIVE then
    local ok = pcall(function()
        local o = spawnMissionObjective(TEST_OBJECTIVE, TEST_OBJ_RADIUS, "Take the objective", 0, true)
        if o then global.set(o.getUniqueId(), "realistic_test_obj") end
    end)
    dbg("test objective " .. (ok and "created" or "FAILED"))
end

--========================== AUTO-ATTACH THE AI BRAIN ========================
-- The Squad Spawner's "Brain" field is trivially easy to leave empty, and when it is EVERY
-- soldier silently runs base AI (this cost a whole play-test: [REALISTIC] = 0 lines).
-- Attaching from here removes that failure mode entirely and also covers reinforcements,
-- which a spawner field set once would miss. Set to nil to disable.
local AUTO_ATTACH_BRAIN = "Realistic.lua"
local attached = 0
-- Role cache, keyed by uid. NOT trustworthy at spawn: getSquad()/isSquadLeader() are nil for
-- the first seconds of a soldier's life (the same bootstrap race the brain works around with
-- SQUAD_RETRY). Capturing at attachBrain therefore records "rifleman" for EVERYONE — measured:
-- 80 deaths, 80 skips, every one role=rifleman, zero leaders across a whole battle.
-- So the cache is REFRESHED from the 1 s loop until each man resolves to a real role; only the
-- still-ambiguous "rifleman" entries are re-checked, so the work converges and then stops.
-- Role captured at SPAWN, keyed by uid. Native role flags are read here, while the soldier is
-- alive and fully constructed; reading them off a corpse inside soldier_died is not dependable,
-- and a wrong "rifleman" answer suppresses the callout silently with no error to show for it.
-- Strings and numbers only — never a Soldier handle (that would pin every corpse in the battle).
local roleAtSpawn = {}

local function attachBrain(s)
    if not (AUTO_ATTACH_BRAIN and s) then return end
    local ok = pcall(function() s.setBrain(AUTO_ATTACH_BRAIN) end)
    if not ok then ok = pcall(function() s:setBrain(AUTO_ATTACH_BRAIN) end) end
    if ok then
        attached = attached + 1
        local suid = safeGet(function() return s.getUniqueId() end)
        if suid then roleAtSpawn[suid] = roleOf(s) end
        if attached <= 3 or attached % 25 == 0 then
            dbg("brain attached to " .. attached .. " soldier(s)")
        end
    elseif attached == 0 then
        dbg("WARNING setBrain failed — is " .. AUTO_ATTACH_BRAIN .. " in this mission's scripts/AI/ ?")
    end
end
-- every future spawn (incl. reinforcements/waves)
pcall(function() er2.setCallback("soldier_spawned", function(s) pcall(function() attachBrain(s) end) end) end)
-- plus everyone already alive when this phase begins
do
    local sol = {}
    local ok = pcall(function() er2.getAllSoldiers(sol) end)
    if ok then
        for _, s in pairs(sol) do attachBrain(s) end
    end
    dbg("initial brain sweep: " .. attached .. " soldier(s) (getAllSoldiers ok=" .. tostring(ok) .. ")")
end

--========================== API PROBE (one-shot) ============================
-- Metadata proves a BINDING exists; it does not prove behaviour. Things found in the IL2CPP
-- string table have surprised us before (getSquad() exists but returns nil for spawner-attached
-- brains; findCover looked like a query but is a void command). So probe here, in the phase
-- script, against a real live soldier — a brain-based probe cannot work now that the phase
-- script auto-attaches Realistic.lua over it.
--
-- SAFETY: members are tested by INDEXING (never calling), except pure read-only getters which
-- are called to learn their return TYPE and a sample value. Mutators (surrender, setPose,
-- kickEveryoneOut, incapacitate, damageSoldier...) are NEVER called — probing must not alter
-- the battle. Set false once verified-api.md is updated.
-- The 2026-08-29 run is folded into verified-api.md, so the probe is OFF. The function and its
-- call site are deliberately KEPT: the next unknown binding gets probed by flipping this back on.
local PROBE_APIS = false
local probeDone = false

local function memberKind(obj, name)
    local ok, v = pcall(function() return obj[name] end)
    if not ok then return "err" end
    if v == nil then return "MISSING" end
    return type(v)
end

local function callRead(obj, name)
    -- only for read-only getters; returns "<type>=<value>" or an error marker
    local ok, v = pcall(function() return obj[name](obj) end)
    if not ok then
        local ok2, v2 = pcall(function() return obj[name]() end)   -- dot-style, no self
        if not ok2 then return "call-err" end
        v = v2
    end
    if v == nil then return "nil" end
    if type(v) == "userdata" then return "userdata" end
    return string.format("%s=%s", type(v), tostring(v):sub(1, 28))
end

local function probeApis()
    local sol = {}
    if not pcall(function() er2.getAllSoldiers(sol) end) then dbg("PROBE: getAllSoldiers failed"); return end
    local subject, vehicle = nil, nil
    for _, s in pairs(sol) do
        if s and safeGet(function() return s.isAlive() end) ~= false then subject = s; break end
    end
    if not subject then dbg("PROBE: no live soldier yet"); return end
    probeDone = true

    log("[BENCH] ===== API PROBE (metadata-discovered members) =====")
    -- 1. Soldier: existence of every newly-discovered member
    local SOLDIER_MEMBERS = {
        "isSuppressed", "getSuppressionValue", "isATSoldier", "isMedic", "isRadioman",
        "isMarksman", "isMechanic", "hasRadio", "isAmmoBoxCarrier", "isFlameThrowerCarrier",
        "setPose", "resetPose", "isCrawling", "isOnCover", "getVelocity", "getMoveDirection",
        "getNearestInjured", "getNearestVehicleToRepair", "surrender", "isSurrendering",
        "stopSurrendering", "incapacitate", "stopIncapacitate", "isBleeding", "applyBleeding",
        "setOnFire", "getCarriedBody", "carryBody", "isCarryingBody", "isMoving", "isRunning",
        "isCharging", "isAiming", "isReloading", "isOnFire", "isOutOfStamina", "isAlerted",
        "getDistanceFromGround", "isInsideVehicle", "jump", "containsItem", "addNewItem",
        "wearUniform", "getUniformId", "getHeldWeaponId", "isPlayer", "isAI",
    }
    log("[BENCH] --- Soldier members ---")
    for _, n in ipairs(SOLDIER_MEMBERS) do
        log("[BENCH]   Soldier." .. n .. " = " .. memberKind(subject, n))
    end
    -- 2. Soldier: read-only getters actually CALLED (type + sample value)
    log("[BENCH] --- Soldier read-only calls ---")
    for _, n in ipairs({ "isSuppressed", "getSuppressionValue", "isATSoldier", "isMedic",
                         "isRadioman", "isMarksman", "isMechanic", "hasRadio", "isOnCover",
                         "getVelocity", "isMoving", "isCrawling", "isSurrendering",
                         "getClassName", "getHealth", "isAlerted", "getNearestInjured" }) do
        log("[BENCH]   " .. n .. "() -> " .. callRead(subject, n))
    end
    -- 3. Squad
    local sq = safeGet(function() return subject.getSquad() end)
    log("[BENCH] --- Squad (getSquad -> " .. tostring(sq) .. ") ---")
    if sq then
        for _, n in ipairs({ "getAllMembers", "getSquadSize", "isPlayerInSquad", "getLeader",
                             "getMedic", "getRadioman", "getMechanic", "charge", "coverArea",
                             "attackFromPoint", "followLeader", "holdFire", "fireAtWill",
                             "waypoint", "alertEnemies", "setClosestObjective", "hasObjective",
                             "getObjectivePosition", "getObjectiveRadius", "hasAliveMembers",
                             "hasFullySpawned", "addSoldier", "removeSoldier" }) do
            log("[BENCH]   Squad." .. n .. " = " .. memberKind(sq, n))
        end
        for _, n in ipairs({ "getSquadSize", "isPlayerInSquad", "hasAliveMembers",
                             "hasFullySpawned", "hasObjective" }) do
            log("[BENCH]   " .. n .. "() -> " .. callRead(sq, n))
        end
        local mem = {}
        local okm = pcall(function() sq.getAllMembers(mem) end)
        -- The no-argument form used to be probed here too. It is gone: the question is ANSWERED
        -- (these are fill-style, and calling them bare throws "Expected a table as Nth parameter"
        -- on every invocation - 279 errors in one battle), and that answer is now enforced by
        -- check 4b. Keeping a deliberate bare call around meant the file could never satisfy its
        -- own release check, and it was a live hazard if PROBE_APIS were ever switched on.
        log("[BENCH]   getAllMembers fill=" .. tostring(okm) .. " filled " .. #mem .. " member(s)")
    else
        log("[BENCH]   Squad is nil for this soldier — roster APIs unusable here")
    end
    -- 4. Vehicle
    local vl = {}
    pcall(function() er2.getVehiclesInArea(safeGet(function() return subject.getPosition() end), 400, vl) end)
    for _, v in pairs(vl) do if v then vehicle = v; break end end
    log("[BENCH] --- Vehicle (found " .. #vl .. " within 400m) ---")
    if vehicle then
        for _, n in ipairs({ "kickEveryoneOut", "kickUnits", "getPassengers", "getDriver",
                             "getGunner", "isDestroyed", "isArtilleryVehicle", "getDamage",
                             "getEngineDamage", "getFueltankDamage", "getTracksDamage",
                             "countPeopleInside", "countEmptySeats", "isEmpty", "isFull",
                             "hasDriver", "isDriverAlive", "getName", "repair", "brake" }) do
            log("[BENCH]   Vehicle." .. n .. " = " .. memberKind(vehicle, n))
        end
        for _, n in ipairs({ "getName", "isDestroyed", "isArtilleryVehicle", "isEmpty",
                             "countPeopleInside", "getDamage", "hasDriver" }) do
            log("[BENCH]   " .. n .. "() -> " .. callRead(vehicle, n))
        end
    else
        log("[BENCH]   no vehicle in range to probe")
    end
    -- SMOKE / ARTILLERY REQUEST BINDING. The engine has RequestArtilleryHE, RequestArtilleryAPHE,
    -- RequestArtillerySMOKE and RequestArtillerySMOKE_AsRadioman (recovered from
    -- global-metadata.dat), plus OnSmokeAccepted and marker_request_artillerySmoke. Whether any
    -- of them is Lua-BOUND has never been established, and guessing a binding name is banned.
    -- This tests candidate spellings by indexing; a non-nil result means the member exists.
    do
        local cand = {
            "RequestArtillerySMOKE", "requestArtillerySmoke", "requestArtillerySMOKE",
            "RequestArtillerySMOKE_AsRadioman", "requestArtillerySmokeAsRadioman",
            "RequestArtilleryHE", "requestArtilleryHe", "requestArtilleryHE",
            "TryAssignRadioOrder", "tryAssignRadioOrder", "assignRadioOrder",
            "requestSmoke", "smokeRequest", "requestArtillery", "RequestAmmoDrop",
        }
        local sol = {}
        pcall(function() er2.getAllSoldiers(sol) end)
        local one = nil
        for _, x in pairs(sol) do one = x break end
        local sq = one and safeGet(function() return one.getSquad() end) or nil
        for _, n in ipairs(cand) do
            local onEr2 = safeGet(function() return er2[n] end) ~= nil
            local onSol = one and safeGet(function() return one[n] end) ~= nil or false
            local onSq  = sq  and safeGet(function() return sq[n]  end) ~= nil or false
            if onEr2 or onSol or onSq then
                log(string.format("[BENCH] SMOKE-CAND %s -> er2=%s soldier=%s squad=%s",
                    n, tostring(onEr2), tostring(onSol), tostring(onSq)))
            end
        end
        log("[BENCH] smoke/artillery request candidates probed: " .. #cand)
        -- also: can we EQUIP a smoke grenade? item identifier spellings from the metadata.
        if one then
            for _, item in ipairs({"smokeGrenade", "SmokeGrenade", "smokeGranade"}) do
                local has = safeGet(function() return one.containsItem(item) end)
                log("[BENCH] containsItem(" .. item .. ") -> " .. tostring(has))
            end
        end
    end
    log("[BENCH] ===== PROBE COMPLETE =====")
end

--===================== SQUADMATE DEATH CALLOUT ==============================
-- ONE surviving squadmate calls out when a keyed man goes down. Deliberately one, not all: this
-- runs on the master client from the soldier_died event, so the speaker is elected deterministically
-- and a squad cannot produce a chorus of overlapping lines.
--
-- The engine's 52-clip VoiceClip enum contains exactly FOUR death callouts and every one of them
-- is role-specific: radiomanIsDead, gunnerIsDead, commanderIsDead, driverIsDead. There is NO
-- generic "man down" and no grief clip — `enemyDown` is for killing an ENEMY, and `AAAAAH` is the
-- agony scream of the man being hit, not a reaction to someone else's death.
--
-- So a rifleman, medic, marksman, AT man or mortar crewman dying produces SILENCE rather than a
-- wrong line. Substituting an ill-fitting clip would be worse than saying nothing: it would be
-- audibly incorrect on every rifleman casualty, which is most of them.
-- `driverIsDead` is not mapped either — roleOf() cannot identify a driver, and guessing from a
-- corpse's last vehicle is unreliable.
local DEATH_CLIP = {
    radioman = "radiomanIsDead",
    gunner   = "gunnerIsDead",     -- the Support/LMG gunner: losing the gun matters to the squad
    leader   = "commanderIsDead",
}
local CALLOUT_GAP = 8             -- s between callouts, so a squad being wiped is not a chorus
local CALLOUT_RADIUS = 60         -- m, fallback scan when the victim's squad will not resolve
local lastCallout = -1000

-- pick the nearest LIVING candidate to the victim from a caller-supplied list
local function nearestLiving(list, vp, vuid)
    local best, bestD = nil, 1e9
    for _, m in pairs(list) do
        if m then
            local muid = safeGet(function() return m.getUniqueId() end)
            if muid and muid ~= vuid
               and safeGet(function() return m.isAlive() end) ~= false
               and safeGet(function() return m.isIncapacitated() end) ~= true then
                local mp = safeGet(function() return m.getPosition() end)
                local d  = (mp and vp) and distance(mp, vp) or 1e8
                if d < bestD then best, bestD = m, d end
            end
        end
    end
    return best, bestD
end

local function callOutDeath(victim)
    local vuid0 = safeGet(function() return victim.getUniqueId() end)
    local role  = (vuid0 and roleAtSpawn[vuid0]) or roleOf(victim)
    local clip = DEATH_CLIP[role]
    if not clip then logonly("callout skip: role="..tostring(role).." (no clip for this role)") return end
    local t = now()
    if (t - lastCallout) < CALLOUT_GAP then logonly("callout skip: cooldown") return end
    local vp, vuid = safeGet(function() return victim.getPosition() end), vuid0
    -- PREFERRED speaker: a surviving member of the victim's own squad.
    local best, bestD, how = nil, 1e9, "squad"
    local sq = safeGet(function() return victim.getSquad() end)
    if sq then
        local members = {}
        if safe(function() sq.getAllMembers(members) end) then      -- FILLS the table
            best, bestD = nearestLiving(members, vp, vuid)
        end
    end
    -- FALLBACK: nearest living friendly nearby. getSquad() is not guaranteed to resolve on a
    -- corpse, and silence is worse than the line coming from the man standing next to him — who
    -- in practice is almost always a squadmate anyway.
    if not best and vp then
        local near = {}
        if safe(function() er2.getSoldiersInArea(vp, CALLOUT_RADIUS, near) end) then
            local vf, mates = safeGet(function() return victim.getFaction() end), {}
            for _, m in pairs(near) do
                local mf = m and safeGet(function() return m.getFaction() end) or nil
                if mf ~= nil and vf ~= nil
                   and safeGet(function() return er2.isSameFaction(mf, vf) end) == true then
                    mates[#mates + 1] = m
                end
            end
            best, bestD = nearestLiving(mates, vp, vuid)
            how = "nearby"
        end
    end
    if not best then logonly("callout skip: no living speaker ("..tostring(role)..")") return end
    if safe(function() best.say(VoiceClip[clip]) end) then
        lastCallout = t
        logonly(string.format("callout: %s (%s down) by 1 %s mate at %.0fm", clip, role, how, bestD))
    end
end

--========================== KILL FEED (deaths only) =========================
local invDead, defDead = 0, 0
local battleOver = false      -- set by battle_ended; stops the attraction loop
-- FORWARD DECLARATION. The soldier_died closure below calls pumpIfLoopDead, and Lua resolves that
-- name at COMPILE time: without this line it compiles to a global read, which is nil at runtime,
-- so every death would raise inside the callback. That is exactly how the rosterIndex bug killed
-- ADVANCE-behind-armour (367 fires -> 0) with no error line anywhere. Assigned after loopBody.
local pumpIfLoopDead

pcall(function() er2.setCallback("soldier_died", function(victim)
  pcall(function()
    if not victim then return end
    local side = sideOf(safeGet(function() return victim.getFaction() end))
    if side == "invader" then invDead = invDead + 1
    elseif side == "defender" then defDead = defDead + 1 end
    logonly("tally invaders:"..invDead.."  defenders:"..defDead)
    -- one surviving squadmate reacts; silent for roles the engine has no death clip for
    callOutDeath(victim)
    if onChosenSquad(victim) then
        announce(nameOf(victim).." ("..roleOf(victim)..") killed by "..weaponForDeath(victim))
    end
  end)
  -- WATCHDOG. Deliberately OUTSIDE the pcall above so a failure in the feed cannot stop it, and
  -- last so it never delays the on-screen message. Runs the periodic work only when the loop has
  -- gone stale; while the loop is alive loopAliveT stays fresh and this costs one comparison.
  pcall(pumpIfLoopDead)
end) end)

pcall(function() er2.setCallback("battle_ended", function(winner, forced)
    battleOver = true
    logonly("BATTLE ENDED  invaders dead:"..invDead.."  defenders dead:"..defDead..(forced and "  (forced)" or ""))
end) end)

dbg("feed armed (deaths only, chosen-squad-scoped). INV="..tostring(INV).." DEF="..tostring(DEF).." phase="..MY_PHASE)

--========================== OBJECTIVE ATTRACTION MANAGER ====================
-- This is what makes base-AI units (INCLUDING TANKS) actually advance on an objective,
-- hold it, and then push to the NEXT one — instead of driving around aimlessly. Modelled
-- on the shipped SHARED/gamemode_defend.lua: attract everyone to every objective; once the
-- invaders (attackers) hold one, RELEASE its invader-attraction so their squads flow to the
-- next; defenders stay attracted so they try to retake. Vehicles count double toward holding.
local ATTRACT_EVERY = 4        -- s between attraction recalcs

-- Objectives are RE-QUERIED periodically, not captured once: a mission can create objectives
-- later (phases, scripted spawns), and a list captured at load would never manage them.
local OBJ_REFRESH = 40        -- s between re-queries
local objList, captured, lastObjScan = {}, {}, nil
local function refreshObjectives()
    local objs = {}
    local got = safeGet(function() return er2.getAllObjectives(objs) end)
    if (#objs == 0) and type(got) == "table" then objs = got end   -- handles either return style
    local fresh = {}
    for _, o in pairs(objs) do if o then fresh[#fresh + 1] = o end end
    if #fresh ~= #objList then
        dbg("attraction manager: " .. #fresh .. " objective(s) found"
            .. (lastObjScan and " (was " .. #objList .. ")" or ""))
        -- keep ownership state for indices that still exist; new ones start uncaptured
        for i = #fresh + 1, #captured do captured[i] = nil end
        for i = 1, #fresh do if captured[i] == nil then captured[i] = false end end
    end
    objList = fresh
end
refreshObjectives()

local function countInside(o)
    local ctr = safeGet(function() return o.getPosition() end)
    local r   = safeGet(function() return o.getRadius() end) or 30
    if not ctr then return 0, 0 end
    local inv, def = 0, 0
    local sol = {}
    pcall(function() er2.getSoldiersInArea(ctr, r, sol) end)
    for _, s in pairs(sol) do
        if s and safeGet(function() return s.isAlive() end) ~= false then
            local sd = sideOf(safeGet(function() return s.getFaction() end))
            if sd == "invader" then inv = inv + 1 elseif sd == "defender" then def = def + 1 end
        end
    end
    local veh = {}
    pcall(function() er2.getVehiclesInArea(ctr, r, veh) end)
    for _, v in pairs(veh) do
        if v then
            local sd = sideOf(safeGet(function() return v.getFaction() end))
            if sd == "invader" then inv = inv + 2 elseif sd == "defender" then def = def + 2 end  -- a tank weighs more
        end
    end
    return inv, def
end

-- Read and write are guarded SEPARATELY on purpose. Sharing one pcall meant a throwing
-- isAttractor() also skipped the setAttractor() — the read is only an optimisation to avoid a
-- redundant network-expensive write, so it must never be able to suppress the write.
local function setAttract(o, invAttract, defAttract)
    local function apply(faction, want)
        if faction == nil then return end
        local cur = safeGet(function() return o.isAttractor(faction) end)
        if cur == want then return end            -- already correct; skip the expensive write
        pcall(function() o.setAttractor(want, faction) end)
    end
    apply(INV, invAttract)
    apply(DEF, defAttract)
end

-- start: everyone is attracted to every objective, so units immediately move onto them.
-- NOTE: `captured` is declared alongside refreshObjectives() above — do NOT re-declare it
-- here, or this loop writes to a shadowing local that the refresh never sees.
for _, o in ipairs(objList) do setAttract(o, true, true) end

--========================== CREW BAIL-OUT (feature 18) ======================
-- Phase half. The vehicle_* callbacks record NUMBERS ONLY — wreck id, position, reason — onto a
-- queue and return immediately. A callback must never sleep(), and a Vehicle handle must never be
-- retained (it is UserData, and the wreck can despawn before the queue is drained). The 1 s main
-- loop does all the real work. Every registration gets its OWN pcall, so a name this build does
-- not publish cannot take the other two down with it.
local BAIL_DESTROYED, BAIL_DISABLED, BAIL_FUEL = 1, 2, 3
local BAIL_REASON = { [BAIL_DESTROYED] = "destroyed",
                      [BAIL_DISABLED]  = "disabled",
                      [BAIL_FUEL]      = "fuel tank hit" }
-- both are getOutTank* members of the built-in 52-clip VoiceClip enum
local BAIL_CLIP   = { [BAIL_DESTROYED] = "getOutTankDestroyed",
                      [BAIL_DISABLED]  = "getOutTankDestroyed",
                      [BAIL_FUEL]      = "getOutTankOnFire" }

local bailQ, bailSeen, bailDropped = {}, {}, 0

local function queueBail(v, kind)
    if v == nil then return end
    local uid = safeGet(function() return v.getUniqueId() end)
    local p   = safeGet(function() return v.getPosition() end)
    if uid == nil or p == nil then return end
    local key = tostring(uid)
    if bailSeen[key] then return end          -- disabled-then-destroyed: empty a wreck once only
    local x = safeGet(function() return p.x end)
    local y = safeGet(function() return p.y end)
    local z = safeGet(function() return p.z end)
    if x == nil or z == nil then return end
    if #bailQ >= BAIL_QUEUE_MAX then bailDropped = bailDropped + 1; return end
    bailSeen[key] = true
    bailQ[#bailQ + 1] = { uid = key, x = x, y = y or 0, z = z, kind = kind }
end

pcall(function() er2.setCallback("vehicle_destroyed",
    function(v) pcall(function() queueBail(v, BAIL_DESTROYED) end) end) end)
pcall(function() er2.setCallback("vehicle_disabled",
    function(v) pcall(function() queueBail(v, BAIL_DISABLED) end) end) end)
pcall(function() er2.setCallback("vehicle_damaged_fueltank",
    function(v) pcall(function() queueBail(v, BAIL_FUEL) end) end) end)

-- re-acquire the wreck from its recorded id + position (the handle itself was never kept)
local function wreckAt(job)
    local list = {}
    if not pcall(function() er2.getVehiclesInArea(vec3(job.x, job.y, job.z), BAIL_RADIUS, list) end) then
        return nil
    end
    for _, v in pairs(list) do
        if v and tostring(safeGet(function() return v.getUniqueId() end)) == job.uid then return v end
    end
    return nil
end

-- Crew roster. Native Vehicle.getPassengers/getDriver are preferred (both confirmed 2026-08-29);
-- the ~10 m area scan is only the fallback for when the wreck has already left the world query.
local function crewOf(veh, job)
    local crew, seen = {}, {}
    local function add(s)
        if not s then return end
        local su = tostring(safeGet(function() return s.getUniqueId() end) or "")
        if su == "" or seen[su] then return end
        seen[su] = true
        crew[#crew + 1] = s
    end
    if veh then
        local pax = {}
        local ok, ret = pcall(function() return veh.getPassengers(pax) end)
        if not ok then ok, ret = pcall(function() return veh.getPassengers() end) end
        if ok then
            if #pax == 0 and type(ret) == "table" then pax = ret end   -- fill-style or return-style
            for _, s in pairs(pax) do add(s) end
        end
        add(safeGet(function() return veh.getDriver() end))
    end
    if #crew == 0 then
        local sol = {}
        pcall(function() er2.getSoldiersInArea(vec3(job.x, job.y, job.z), BAIL_RADIUS, sol) end)
        for _, s in pairs(sol) do
            if s then
                local cv = safeGet(function() return s.getCurrentVehicle() end)
                if cv and tostring(safeGet(function() return cv.getUniqueId() end)) == job.uid then add(s) end
            end
        end
    end
    return crew
end

local function bailOut(job)
    local veh  = wreckAt(job)
    local crew = crewOf(veh, job)
    if #crew == 0 then return end
    local vname = veh and (safeGet(function() return veh.getName() end) or "vehicle") or "vehicle"
    local clip  = BAIL_CLIP[job.kind]

    -- kickEveryoneOut is confirmed PRESENT but its behaviour was never exercised (mutators are
    -- never called by the probe), so it is tried first and then VERIFIED per man; anyone still
    -- aboard gets the per-soldier leaveVehicle fallback.
    local kicked = veh ~= nil and pcall(function() veh.kickEveryoneOut() end)
    local out = 0
    for _, s in ipairs(crew) do
        if (not kicked) or safeGet(function() return s.getCurrentVehicle() end) ~= nil then
            pcall(function() s.leaveVehicle() end)
        end
        if safeGet(function() return s.getCurrentVehicle() end) == nil then out = out + 1 end
        pcall(function() s.alertFor(BAIL_ALERT) end)
        if clip then pcall(function() s.say(VoiceClip[clip]) end) end
    end
    logonly("bail-out: " .. out .. " crew left vehicle " .. tostring(vname)
        .. " (" .. (BAIL_REASON[job.kind] or "?") .. ", via "
        .. (kicked and "kickEveryoneOut" or "leaveVehicle") .. ")")
end

local function drainBail()
    local n = 0
    while #bailQ > 0 and n < BAIL_PER_TICK do
        local job = table.remove(bailQ, 1)
        n = n + 1
        pcall(function() bailOut(job) end)
    end
    if bailDropped > 0 then
        logonly("bail-out: dropped " .. bailDropped .. " queued wreck(s) over BAIL_QUEUE_MAX")
        bailDropped = 0
    end
end

--========================== RADIOMAN FIRE MISSION (feature 19) ==============
-- CONSUMER half. Realistic.lua's radioman is the producer; the two halves share ONLY these four
-- globals, and globals hold INTEGERS ONLY (a vec3 or any other UserData in a global throws
-- "Type 'UserData' is not allowed as global variable!" and killed every brain at boot).
--   RQ_X / RQ_Z  integer world X/Z of the requested target
--   RQ_S         integer side of the requester: 1 = attackers/invaders, 2 = defenders
--   RQ_T         integer timestamp of the pending request, or -1 when none is pending
-- The brain writes X, Z and S FIRST and T LAST, so a request is never read half-written. This
-- side reads T and, the instant it is >= 0, writes T = -1 to CONSUME the request before doing
-- anything else — an accepted or refused mission must never be able to re-trigger itself.
-- The read and the clear are guarded SEPARATELY on purpose: one shared pcall around both meant a
-- throwing read also skipped the write, and the request would then repeat forever.
local RQ_T, RQ_X, RQ_Z, RQ_S = "RQ_T", "RQ_X", "RQ_Z", "RQ_S"
pcall(function() global.set(-1, RQ_T) end)     -- start from a defined, consumed slot

local FIRE_IDLE, FIRE_WARN, FIRE_FIRING = 0, 1, 2
local fireState   = FIRE_IDLE
local fireX, fireZ, fireSide = 0, 0, 0
local fireT0      = 0         -- when the current mission was accepted
local shellsLeft  = 0
local nextShellAt = 0
local lastFireEnd = nil       -- nil = nothing fired yet, so the first mission has no cooldown
local fireMissions = 0

local function readInt(key)
    local n = tonumber(safeGet(function() return global.get(key) end))
    if n == nil then return nil end
    return math.floor(n)
end

-- true = REFUSE. FAIL-SAFE: any failure inside the check refuses the mission. Guessing "clear"
-- when the check itself broke would drop 24 shells on our own infantry.
local function dangerClose(tx, tz, side)
    local faction = (side == 1) and INV or ((side == 2) and DEF or nil)
    if faction == nil then return true end
    local ok, hit = pcall(function()
        local y   = safeGet(function() return er2.getTerrainHeight(vec3(tx, 0, tz)) end) or 0
        local ctr = vec3(tx, y, tz)
        local sol = {}
        er2.getSoldiersInArea(ctr, FIRE_DANGER_R, sol)
        for _, s in pairs(sol) do
            if s and safeGet(function() return s.isAlive() end) ~= false then
                local sf = safeGet(function() return s.getFaction() end)
                if sf ~= nil and safeGet(function() return er2.isSameFaction(sf, faction) end) == true then
                    return true
                end
            end
        end
        return false
    end)
    if not ok then return true end
    return hit ~= false
end

local function acceptMission(rx, rz, rs, src)
    local t = now()
    if rx == nil or rz == nil or rs == nil then
        logonly("RADIO-fire-mission REFUSED malformed request (" .. src .. ")"); return false
    end
    if fireState ~= FIRE_IDLE then
        logonly("RADIO-fire-mission REFUSED a mission is already in progress (" .. src .. ")"); return false
    end
    if fireMissions >= FIRE_MAX then
        logonly("RADIO-fire-mission REFUSED mission cap " .. FIRE_MAX .. " reached (" .. src .. ")"); return false
    end
    if lastFireEnd ~= nil and (t - lastFireEnd) < FIRE_MIN_GAP then
        logonly(string.format("RADIO-fire-mission REFUSED cooldown, %.0fs remaining (%s)",
            FIRE_MIN_GAP - (t - lastFireEnd), src)); return false
    end
    if dangerClose(rx, rz, rs) then
        logonly(string.format("RADIO-fire-mission REFUSED danger close: friendly of side %d within %dm of %d,%d (%s)",
            rs, FIRE_DANGER_R, rx, rz, src)); return false
    end
    fireX, fireZ, fireSide = rx, rz, rs
    fireState, fireT0 = FIRE_WARN, t
    fireMissions = fireMissions + 1
    logonly(string.format("RADIO-fire-mission accepted: side=%d target=%d,%d rounds in %ds (%s)",
        rs, rx, rz, SUPPORT_WARNING, src))
    return true
end

local function fireShell(tx, tz)
    local ang = math.random() * math.pi * 2
    local rad = math.random() * BARRAGE_SCATTER
    local x = tx + math.cos(ang) * rad
    local z = tz + math.sin(ang) * rad
    local y = safeGet(function() return er2.getTerrainHeight(vec3(x, 0, z)) end) or 0
    pcall(function() er2.explosion(vec3(x, y, z), BARRAGE_DAMAGE, BARRAGE_PENETRATION, BARRAGE_BLAST) end)
end

-- Optional pre-scripted targets (press P in the editor to copy a world position). They feed the
-- SAME state machine as a radioman request, so there is exactly one firing path to reason about.
local manualQ = {}
pcall(function()
    for _, t in ipairs(FIRE_SUPPORT_TARGETS) do
        manualQ[#manualQ + 1] = { x = math.floor(t.x), z = math.floor(t.z) }
    end
end)

-- ONE 1 s step of the fire-mission state machine. No coroutine and no sleep(): the main loop
-- already sleeps 1 s, so the barrage is paced off er2.time() instead of off its own stack.
-- Re-read the role of everyone still cached as the ambiguous default. A soldier's squad (and
-- therefore isSquadLeader) resolves a few seconds after spawn, so the value captured at
-- attachBrain is wrong for leaders, gunners and radiomen. Bounded per pass and self-limiting:
-- once a man resolves to a real role he is never re-checked.
local roleScan = 0
local function refreshRoles()
    local sol = {}
    if not safe(function() er2.getAllSoldiers(sol) end) then return end
    local n, seen = 0, 0
    for _, s in pairs(sol) do
        if n >= ROLE_REFRESH_MAX then break end
        seen = seen + 1
        if seen > roleScan then
            local suid = safeGet(function() return s.getUniqueId() end)
            if suid and (roleAtSpawn[suid] == nil or roleAtSpawn[suid] == "rifleman") then
                local r = roleOf(s)
                if r ~= "rifleman" then roleAtSpawn[suid] = r end
                n = n + 1
            end
        end
    end
    roleScan = (seen > roleScan + ROLE_REFRESH_MAX) and (roleScan + ROLE_REFRESH_MAX) or 0
end

local function fireMissionStep()
    local t = now()

    -- 1. consume any pending request FIRST, in every state, so the brain is never left holding
    --    a request that nobody clears.
    -- CROSS-CONTEXT PROBE. The brain (client-local, per soldier) writes RQ_* and PROBE_B2P;
    -- this phase script runs on the MASTER CLIENT. Whether `global` is shared between those two
    -- contexts has never been proven. RADIO-fire-mission fired 7 times brain-side while this
    -- consumer logged nothing at all, and "the consumer is wired" has been verified (it is called
    -- as pcall(fireMissionStep) in the 1 s loop) — so a shared-global assumption is the remaining
    -- suspect. Throttled hard: one line per PROBE_EVERY cycles, never per tick.
    if PROBE_GLOBALS and (fireTick % PROBE_EVERY) == 0 then
        logonly(string.format("gprobe: RQ_T=%s PROBE_B2P=%s (nil => the brain's globals are NOT visible here)",
            tostring(safeGet(function() return global.get(RQ_T) end)),
            tostring(safeGet(function() return global.get("PROBE_B2P") end))))
    end
    fireTick = fireTick + 1

    local rq = readInt(RQ_T)
    if rq ~= nil and rq >= 0 then
        local rx, rz, rs = readInt(RQ_X), readInt(RQ_Z), readInt(RQ_S)
        pcall(function() global.set(-1, RQ_T) end)      -- separate pcall from the reads above
        acceptMission(rx, rz, rs, "radio")
    elseif fireState == FIRE_IDLE and #manualQ > 0 then
        local m = table.remove(manualQ, 1)
        acceptMission(m.x, m.z, 1, "scripted")          -- the player's side calls scripted targets
    end

    -- 2. advance the machine
    if fireState == FIRE_WARN then
        if (t - fireT0) >= SUPPORT_WARNING then
            fireState   = FIRE_FIRING
            shellsLeft  = BARRAGE_SHELLS
            nextShellAt = t
            logonly(string.format("RADIO-fire-mission rounds away: %d shells on %d,%d for side %d",
                BARRAGE_SHELLS, fireX, fireZ, fireSide))
        end
    elseif fireState == FIRE_FIRING then
        local fired = 0
        while shellsLeft > 0 and fired < FIRE_SHELLS_TICK and nextShellAt <= t do
            fireShell(fireX, fireZ)
            shellsLeft  = shellsLeft - 1
            fired       = fired + 1
            nextShellAt = nextShellAt + SHELL_INTERVAL
        end
        if nextShellAt < t then nextShellAt = t end      -- never let the schedule bank up a burst
        if shellsLeft <= 0 then
            fireState   = FIRE_IDLE
            lastFireEnd = t
            logonly("RADIO-fire-mission complete")
        end
    end
end

--========================== MAIN LOOP (attraction + bail-out + radioman) ====

local tick = 0
local phasePaused = false

-- WATCHDOG STATE. The loop's `sleep(1)` is the one statement nothing can guard, and it is where
-- the loop actually dies: traced live on Donchery, the last line ever logged is
-- "trace tick=47 pre-sleep" with no matching post-sleep, and the tick never advances again.
-- ER2 implements sleep() as a Unity coroutine (PauseForSeconds -> pauseWithCallback ->
-- Coroutine_Resume); if whatever hosts it stops resuming, the Lua coroutine is simply never
-- continued. No error, no idle line, and nothing inside the script can notice - it is not running.
--
-- So the periodic work must not depend on the loop being alive. soldier_died is registered on the
-- engine, not on the loop's coroutine, and demonstrably keeps firing for the whole battle (tally
-- and callout lines continue tens of thousands of log lines past the loop's last output). It also
-- already does an area scan for the kill feed, so bounded work there is proven safe on this build.
-- The callback therefore pumps the same body when the loop has gone stale.
local loopAliveT = -1        -- er2.time() of the last completed loop iteration
local lastPumpT  = -1        -- er2.time() of the last watchdog-driven pump
local pumps      = 0
local LOOP_STALE = 6         -- s without a loop iteration before the watchdog takes over
local PUMP_GAP   = 4         -- s between pumps, matching the loop's own attraction cadence
local loopBody               -- forward declaration; assigned just below

-- ============================ HEALTH WATCH =================================
-- Answers one question a decision log cannot: are the soldiers actually MOVING, or is the mod
-- issuing orders into the void? A label in the log is not proof of behaviour - that rule has
-- already cost this project two wrong conclusions - so this measures DISPLACEMENT instead.
--
-- One sweep every WATCH_EVERY seconds over every soldier: compare each man's position with where
-- he was last sweep, and classify. Numbers only, keyed by uid - never a Soldier handle, which
-- would pin every corpse in the battle. Cost is one getAllSoldiers plus a getPosition per man per
-- sweep, which at 8 s is negligible next to the per-soldier brains.
--
-- Reads as: watch: alive=248 moving=181 still=67 stuck=12 (>40s) inv=..  def=..
--   moving = displaced > WATCH_MOVED since the last sweep
--   still  = did not; entirely normal for defenders holding, men in cover, and the suppressed
--   stuck  = has not moved in WATCH_STUCK seconds AND is an ATTACKER, who should be advancing.
--            A non-zero stuck count that keeps climbing is the signal that something is wrong.
local WATCH = false-- diagnostic; check.sh refuses to ship this true
local WATCH_EVERY = 8          -- s between sweeps
local WATCH_MOVED = 2.0        -- m of displacement that counts as "moving"
local WATCH_STUCK = 40         -- s stationary before an attacker is called stuck
local wLastX, wLastZ, wStillSince = {}, {}, {}
local wNext = 0

local function healthWatch()
    local t = now()
    if t < wNext then return end
    wNext = t + WATCH_EVERY
    local sol = {}
    if not pcall(function() er2.getAllSoldiers(sol) end) then return end
    local alive, moving, still, stuck = 0, 0, 0, 0
    local iAlive, dAlive = 0, 0
    for _, s in pairs(sol) do
        if s and safeGet(function() return s.isAlive() end) ~= false then
            local u = safeGet(function() return s.getUniqueId() end)
            local p = safeGet(function() return s.getPosition() end)
            if u and p then
                alive = alive + 1
                local side = sideOf(safeGet(function() return s.getFaction() end))
                if side == "invader" then iAlive = iAlive + 1
                elseif side == "defender" then dAlive = dAlive + 1 end
                local px, pz = wLastX[u], wLastZ[u]
                if px then
                    local dx, dz = p.x - px, p.z - pz
                    if math.sqrt(dx * dx + dz * dz) >= WATCH_MOVED then
                        moving = moving + 1
                        wStillSince[u] = nil
                    else
                        still = still + 1
                        wStillSince[u] = wStillSince[u] or t
                        -- Only ATTACKERS count as stuck. Defenders holding a line are supposed to
                        -- be motionless; calling that a fault would bury the real signal.
                        -- Exclude the SUPPRESSED. A man with rounds cracking over his head is
                        -- supposed to be flat, and counting him as stuck buries the real signal.
                        -- Measured: at the end of a won battle stuck sat at 7 of 70 attackers,
                        -- and the decision mix showed SUPPORT-hold-fire - LMG gunners holding a
                        -- base of fire BY DESIGN. One extra call per still soldier per 8 s sweep
                        -- is a fair price for a number that means something.
                        if side == "invader" and (t - wStillSince[u]) >= WATCH_STUCK
                           and safeGet(function() return s.isSuppressed() end) ~= true then
                            stuck = stuck + 1
                        end
                    end
                end
                wLastX[u], wLastZ[u] = p.x, p.z
            end
        end
    end
    log(string.format("[EVENTS] watch: alive=%d moving=%d still=%d stuck=%d(>%ds) inv=%d def=%d",
        alive, moving, still, stuck, WATCH_STUCK, iAlive, dAlive))
end

-- ============================ TELEMETRY ====================================
-- Dumps the position and state of EVERY soldier and EVERY vehicle on a fixed cadence, so the whole
-- battle can be replayed and watched afterwards rather than inferred from decision counts.
-- Rendered by er2-plugin/tools/battle_map.py into an interactive map.
--
-- PACKED, deliberately. log() costs roughly 1.1 KB plus a stack walk, so one call per soldier would
-- be ~350 calls a frame and would itself change the thing being measured. Entities are batched
-- TELEM_BATCH to a line, which turns a frame into about a dozen calls instead.
--
-- Format:  [TELEM] <t> S <uid>,<x>,<z>,<flag>;<uid>,<x>,<z>,<flag>;...
--          [TELEM] <t> V <uid>,<x>,<y>,<z>,<name>;...
--   flag   I invader · D defender · i invader suppressed · d defender suppressed · x down/dead
--   x,z    rounded to whole metres - sub-metre precision is noise at map scale and costs bytes
local TELEMETRY  = false-- diagnostic; check.sh refuses to ship this true
local TELEM_EVERY = 2          -- s between frames
local TELEM_BATCH = 40         -- entities per log line
local telemNext = 0
-- Squad identity for the telemetry, so formation can be measured PER SQUAD rather than across the
-- whole force. Without it a broad advance and a tight file are indistinguishable: the frontage of
-- 30 men spread over the map swamps the 2-3 m that separates two files of one section.
-- Keyed by the squad LEADER's uid, which is stable and needs no new API. Squad membership does not
-- change, so this resolves once per soldier ever - never per frame.
local sqidBy = {}
local function squadKey(s, uid)
    if uid == nil then return 0 end
    local k = sqidBy[uid]
    if k ~= nil then return k end
    local sq = safeGet(function() return s.getSquad() end)
    if sq then
        local ld = safeGet(function() return sq.getLeader() end)
        local lu = ld and safeGet(function() return ld.getUniqueId() end) or nil
        -- CACHE ONLY SUCCESS. Caching the failure was a real bug: a soldier probed during the ~3 s
        -- spawn window has no squad yet, and storing that 0 made it permanent - 158 of 349 men
        -- (45%) came back unresolved when the known resolve rate is ~85%. Leaving the slot nil
        -- costs one retry per frame for the stragglers and recovers almost all of them.
        if lu then sqidBy[uid] = lu; return lu end
    end
    return 0
end

local function telemFlag(s, side)
    if safeGet(function() return s.isIncapacitated() end) == true then return "x" end
    local sup = safeGet(function() return s.isSuppressed() end) == true
    if side == "invader"  then return sup and "i" or "I" end
    if side == "defender" then return sup and "d" or "D" end
    return "?"
end

local function telemetryFrame()
    local t = now()
    if t < telemNext then return end
    telemNext = t + TELEM_EVERY
    local ts = string.format("%.1f", t)

    local sol = {}
    if pcall(function() er2.getAllSoldiers(sol) end) then
        local buf, n = {}, 0
        for _, s in pairs(sol) do
            if s and safeGet(function() return s.isAlive() end) ~= false then
                local u = safeGet(function() return s.getUniqueId() end)
                local p = safeGet(function() return s.getPosition() end)
                if u and p then
                    local side = sideOf(safeGet(function() return s.getFaction() end))
                    n = n + 1
                    -- v: 1 if aboard a vehicle. Direct, not inferred - the old proximity
                    -- heuristic (within 4 m of a vehicle) already produced one false result,
                    -- a phantom 1.0 m median spacing that was really a truckload of men
                    -- sharing one position.
                    local v = safeGet(function() return s.getCurrentVehicle() end) and 1 or 0
                    -- d: the brain's own current decision, as a code. Joins intent to outcome;
                    -- without it "did the men ordered to move actually move?" is unanswerable.
                    local d = tonumber(safeGet(function() return global.get("D" .. u) end)) or 0
                    local ri = tonumber(safeGet(function() return global.get("R" .. u) end)) or 0
                    buf[n] = string.format("%d,%d,%d,%d,%s,%d,%d,%d,%d", u, p.x, p.y, p.z,
                        telemFlag(s, side), squadKey(s, u), v, d, ri)
                    if n >= TELEM_BATCH then
                        log("[TELEM] " .. ts .. " S " .. table.concat(buf, ";")); buf, n = {}, 0
                    end
                end
            end
        end
        if n > 0 then log("[TELEM] " .. ts .. " S " .. table.concat(buf, ";")) end
    end

    -- getAllVehicles is fill-style like getAllSoldiers (confirmed present in the game metadata).
    -- Falls back to a wide getVehiclesInArea sweep if the fill form is rejected, so a signature
    -- difference degrades to fewer vehicles rather than to no telemetry at all.
    local veh = {}
    local vok = pcall(function() er2.getAllVehicles(veh) end)
    if not vok then
        veh = {}
        pcall(function() er2.getVehiclesInArea(vec3(0, 0, 0), 4000, veh) end)
    end
    local vbuf, vn = {}, 0
    for _, v in pairs(veh) do
        if v then
            local u = safeGet(function() return v.getUniqueId() end)
            local p = safeGet(function() return v.getPosition() end)
            if u and p then
                local nm = tostring(safeGet(function() return v.getName() end) or "?"):gsub("[;,]", " ")
                vn = vn + 1
                vbuf[vn] = string.format("%d,%d,%d,%d,%s", u, p.x, p.y, p.z, nm)
                if vn >= TELEM_BATCH then
                    log("[TELEM] " .. ts .. " V " .. table.concat(vbuf, ";")); vbuf, vn = {}, 0
                end
            end
        end
    end
    if vn > 0 then log("[TELEM] " .. ts .. " V " .. table.concat(vbuf, ";")) end
end

loopBody = function()
    if WATCH then pcall(healthWatch) end
    if TELEMETRY then pcall(telemetryFrame) end

    -- (a) objective attraction — throttled, with comprehensive per-objective logging.
    -- TWO PASSES, deliberately. `allHeld` must be known for EVERY objective before any
    -- attraction is applied. Computing it inside the apply loop meant objective 1 always saw
    -- allHeld=true (nothing had cleared it yet), so its invader-attraction was NEVER released
    -- and the "hold it, then flow to the next objective" behaviour could not happen.
    -- one-shot API probe, once soldiers actually exist (they do not at phase load)
    if PROBE_APIS and not probeDone and tick >= 8 then pcall(probeApis) end
    if (tick % OBJ_REFRESH) == 0 then refreshObjectives() end
    if (tick % ATTRACT_EVERY) == 0 and #objList > 0 then
        -- pass 1: ownership only
        local allHeld, changed = true, {}
        local invCount, defCount = {}, {}
        for i, o in ipairs(objList) do
            local inv, def = countInside(o)
            invCount[i], defCount[i] = inv, def
            local was = captured[i]
            if captured[i] then
                if def > inv then captured[i] = false end          -- pushed off: contested again
            elseif inv > def and inv > 0 then
                captured[i] = true                                  -- attackers hold it
            end
            changed[i] = (was ~= captured[i])
            if not captured[i] then allHeld = false end
        end
        -- pass 2: apply attraction now that allHeld is final
        for i, o in ipairs(objList) do
            -- invaders stop being drawn to what they already hold, so they push on; if they hold
            -- EVERYTHING they are re-attracted so they consolidate instead of wandering off.
            local invAttract = (not captured[i]) or allHeld
            setAttract(o, invAttract, true)
            logonly(string.format("obj%d inv=%d def=%d held=%s invAttract=%s%s",
                i, invCount[i], defCount[i], tostring(captured[i]), tostring(invAttract),
                changed[i] and (captured[i] and "  <- CAPTURED by attackers" or "  <- RETAKEN by defenders") or ""))
        end
        -- battalion strength (confirmed API) so we can watch attrition
        local ai = safeGet(function() return er2.countAliveInvaders() end)
        local ad = safeGet(function() return er2.countAliveDefenders() end)
        logonly("alive invaders="..tostring(ai).."  defenders="..tostring(ad))
    end

    -- (b) crew bail-out — drain the queue the vehicle_* callbacks filled. All of the work is
    -- here, never in the callback: callbacks record numbers and return.
    pcall(drainBail)

    -- (c) radioman fire mission — one step of the state machine. No coroutine: the loop already
    -- sleeps 1 s, which is the only clock the barrage needs.
    if (tick % ROLE_REFRESH) == 0 then pcall(refreshRoles) end
    pcall(fireMissionStep)

    -- NO break on battleOver: the idle branch above handles it, so the loop survives to serve
    -- the next battle in this process.
    tick = tick + 1
    loopAliveT = now()
end

-- Assigned here, after loopBody exists. Forward-declared far above, next to the soldier_died
-- callback that calls it.
pumpIfLoopDead = function()
    local t = now()
    if loopAliveT < 0 then return end                 -- loop has not run a single iteration yet
    if (t - loopAliveT) < LOOP_STALE then return end  -- loop is alive; do nothing
    if (t - lastPumpT) < PUMP_GAP then return end     -- already pumped recently
    lastPumpT = t
    pumps = pumps + 1
    if pumps == 1 then
        log("[EVENTS] WATCHDOG: the phase loop stopped (sleep never resumed) - "
            .. "driving attraction/bail-out/fire-missions from soldier_died instead")
    end
    pcall(loopBody)
end
while true do
    -- WAIT-AND-RESUME, not break. This used to `break` the moment the phase changed, which is
    -- what a battle ending looks like. The game does NOT re-load the phase script for a second
    -- battle in the same process, so the loop stayed dead for every later battle while the event
    -- callbacks kept firing - the kill feed and tally still worked, so it LOOKED healthy while
    -- objective attraction, bail-out drain and fire-mission consumption were all silently gone.
    -- Measured: only 6 script loads across a 495k-line log, loop output stopping at line 462,427
    -- while battles continued past 495,000.
    local ph = safeGet(function() return er2.getCurrentPhaseId() end)
    if ph ~= MY_PHASE or battleOver then
        -- IDLE, do not exit. There are TWO ways out of this loop and the first fix only closed
        -- one of them: `battleOver`, set by the battle_ended callback, used to `break` here.
        -- Capturing an objective ends the phase, so the loop was dying MID-SESSION - measured
        -- once at log line 17,805 while the battle ran on to line 103,882, with no idle message
        -- because the phase check never got a look in. Since the game does not re-load the phase
        -- script for the next battle, that break was permanent and silent.
        if not phasePaused then
            phasePaused = true
            logonly("idling: phase=" .. tostring(ph) .. " ours=" .. tostring(MY_PHASE)
                .. " battleOver=" .. tostring(battleOver))
        end
        -- CLEAR battleOver HERE, not in the active branch. Third distinct cause of the loop
        -- death, found offline: once battle_ended set battleOver, the guard
        -- `ph ~= MY_PHASE or battleOver` stayed true even after our phase came back, so the
        -- active branch was never reached - and the active branch was the only place that reset
        -- the flag. A deadlock: the flag that traps the loop could only be cleared by the code it
        -- prevents from running. The phase returning IS the signal that a new battle has begun.
        if ph == MY_PHASE and battleOver then
            battleOver = false
        end
        sleep(1)
    else
        if phasePaused then
            phasePaused = false
            battleOver = false    -- a new battle: the previous one's end no longer applies
            -- Re-query the objectives IMMEDIATELY. Clearing objList alone left it empty until the
            -- next `tick % OBJ_REFRESH == 0`, which is up to 40 s away - so attraction stayed
            -- dead for most of a minute after every resume and the loop still looked broken.
            -- Found offline: the harness resumed correctly and then produced no attraction lines.
            objList = {}
            refreshObjectives()
            logonly("RESUMED: our phase is active again (objectives re-queried)")
        end

        -- DIAGNOSTIC WRAP. The loop has NO exit - every remaining `break` is inside an inner
        -- for-loop - yet it stops mid-session (measured: last loop line 21769 of 25437, with no
        -- idle message). A loop with no exit that stops is DYING, not breaking, and only 4 of
        -- these ~85 lines were protected. An unhandled error here kills the coroutine silently:
        -- ER2 does not surface it as a Lua error, which is why every log has shown zero.
        -- Logged with log() NOT logonly(), because DEBUG ships false and this must be visible.
        local bodyOk, bodyErr = pcall(loopBody)
        if not bodyOk then
            log("[EVENTS] LOOP BODY ERROR (this is what kills the loop): " .. tostring(bodyErr))
        end
    end   -- phase-active branch
    if TRACE_LOOP then log("[EVENTS] trace tick=" .. tick .. " pre-sleep") end
    sleep(1)
    if TRACE_LOOP then log("[EVENTS] trace tick=" .. tick .. " post-sleep") end
end
