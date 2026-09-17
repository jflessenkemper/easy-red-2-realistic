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
--   Verified against build v2.0.9 (see docs/verified-api.md).
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
-- 50 m, NOT 90. CORRECTED 2026-09-08 after enumerating why no barrage has ever landed.
--
-- It was 90, exactly equal to the brain's SENSE_RADIUS, and that made feature 19 MATHEMATICALLY
-- UNREACHABLE rather than merely unlucky:
--   * the radioman publishes the ENEMY CENTROID as the target (Realistic.lua: global.set(ec.x,"RQ_X"))
--   * `ec` comes from a getSoldiersInArea(pos, SENSE_RADIUS 90) sweep, so the target is ALWAYS
--     within 90 m of the radioman
--   * dangerClose() refuses if ANY friendly of the requesting side is within FIRE_DANGER_R of the
--     target - and the radioman is himself such a friendly, within 90 m of it by construction
-- So every request was refused, always, and all six observed responses were "REFUSED danger
-- close". The README called that "the fail-safe working, not a fault"; it was arithmetic. No test
-- geometry could have fixed it, because the constraint is between the radioman and his OWN sensed
-- enemies, not about where anything is placed.
--
-- 50 m leaves a usable window (enemies sensed at 50-90 m can be shelled) and is still 5x
-- BARRAGE_BLAST, which is 10 m. It must stay comfortably BELOW SENSE_RADIUS or the feature dies
-- again; tests/offline_phase.lua now asserts that relationship.
local FIRE_DANGER_R    = 50   -- m, refuse the mission if ANY friendly of the requesting side is this close
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
-- T10 - RADIO FIRE MISSION. Uncomment to run the scenario that proves feature 19.
--
-- The geometry is the whole point and every number is load-bearing:
--   enemies at 75 m  -> INSIDE SENSE_RADIUS 90, so the radioman senses them and can form an
--                       enemy centroid at all (he publishes that centroid as the target)
--                    -> OUTSIDE FIRE_DANGER_R 50, so danger-close does NOT refuse it
--   ONE enemy squad  -> ne is comfortably >= RADIO_MIN_ENEMIES 3, while nec (within
--                       PINNED_RADIUS 50) is 0, so PINNED cannot pre-empt the radio branch
--                       from proximity - only transient suppression can, which passes
--   no objective     -> the squad is threatened so it will not march anyway, and a stationary
--                       radioman is what STALL_DIST 15 m / STALL_WINDOW 30 s requires
--   balanced numbers -> forceRatio ~0.5, far above germany's moraleFloor 0.22, so ROUT (which
--                       sits ABOVE radio in the cascade) does not pre-empt it either
--
-- This scenario MUST run with THIS phase script, not showcase.lua: the request is published by
-- the brain but the CONSUMER that accepts it and fires the barrage lives here. Measured in the
-- showcase, which replaces this file: 2 requests, 0 accepted, 0 refused, 0 rounds away.
--
-- Placed at (200,200), clear of VirtualScene's own spawns near the origin (~280 m away, well
-- beyond SENSE_RADIUS) so the mission's own squads cannot contaminate the force ratio.
-- PROVEN 2026-09-08 with this rig, on VirtualScene, zero Lua errors:
--   RADIO-fire-mission accepted: side=2 target=18,45 rounds in 12s (radio)
--   RADIO-fire-mission rounds away: 24 shells on 18,45 for side 2
--   RADIO-fire-mission complete
-- The FIRST barrage in this project's history. It was unblocked by the FIRE_DANGER_R fix
-- (90 -> 50); the geometry below is what makes the branch reachable at all.
local T10 = {
    { pos = vec3(200, 0, 200), side = "invader",  squad = "ger_infantry_1940", radius = 10 },
    { pos = vec3(275, 0, 200), side = "defender", squad = "fr_ATsquad",        radius = 10 },
}

-- T9 + T6 COMBINED RIG. Three stations, 500 m apart, so one run exercises all three.
--
-- DECISION RECORDED: T9, T6 and T6's negative control are run together rather than as separate
-- scenarios. Station separation of 500 m is already proven to isolate stations (it must exceed
-- SENSE_RADIUS 90 so one station's enemies cannot enter another's force ratio), so a combined run
-- yields one run of EACH at a quarter of the cost. Nothing is lost: the branches under test are
-- different, and the geometries do not interact.
--
--   T9  crew bail-out  - a CREWED Panzer II C with a tank crew aboard, killed by an AT squad at
--                        80 m. A truck will not do: its occupants are passengers, not crew, and
--                        the branch keys off what the man was RIDING.
--   T6  armour advance - rifle squad + Sdkfz251 halftrack within ARMOUR_SCAN 45 m, enemy at 75 m
--                        (inside SENSE_RADIUS 90 so the squad is threatened - the branch lives in
--                        the threatened arm of the cascade).
--   T6c NEGATIVE CONTROL - identical, but an Opel Blitz instead of the halftrack. A TRUCK MUST
--                        NOT QUALIFY as armour. If ADVANCE-behind-armour fires here, the
--                        name filter is broken. This is the half of T6 that can actually fail.
--
-- RUN 2 RESULT, 2026-09-08 - ROOT CAUSE FOUND, and it is the RIG, not the mod.
-- spawnVehicle() HAS NO FACTION PARAMETER, so a script-spawned vehicle has NO OWNING SIDE. That
-- single fact kills both scenarios:
--   T6 - advanceBehindArmour() requires v.getFaction() non-nil AND isSameFaction(vf, myFaction),
--        so the halftrack can never be "friendly armour". Confirmed: riflemen 20 m from it were
--        genuinely threatened (ne=1-3, ed=70-74) and fell through to BOUND-*/LEADER-cover, which
--        sit BELOW ADVANCE-behind-armour in the cascade - so 12b was evaluated and returned false.
--   T9 - the enemy does not engage a factionless vehicle either. Two AT squads at 35-40 m produced
--        ZERO vehicle_destroyed/disabled/fueltank events, so the Panzer was never even damaged.
-- Both were re-run after the armour-filter fix and after moving the AT squads from 80 m to 35 m;
-- neither change could have helped, because the blocker is upstream of both.
-- CONCLUSION: features 5 and 18 need an EDITOR-PLACED vehicle spawner, which carries a faction.
-- They are NOT provable on a scripted rig. Marked accordingly rather than re-attempted.
--
-- RUN 1 RESULT, 2026-09-08 (VirtualScene, zero Lua errors). The rig itself works: 5 squads,
-- 3 vehicles and the tank crew ABOARD the Panzer all spawned, and MOUNTED/CREW-defer fired 135
-- times, which confirms the new mounted-spawn path. But neither feature under test was observed:
--   * T9  - the Panzer II C SURVIVED. fr_ATsquad at 80 m did not destroy it, so there was nothing
--           to bail out of. Bring the AT squad closer, or give the French an AT gun, before
--           calling this scenario run at all.
--   * T6  - ADVANCE-behind-armour fired ZERO times at BOTH stations. At the control station the
--           squads were genuinely threatened (measured ne=1-2, ed=72-76) and correctly produced no
--           armour advance, but that is NOT a passing control.
--
-- MEASUREMENT PRINCIPLE, recorded because it is easy to mis-read: A NEGATIVE CONTROL PROVES
-- NOTHING WHILE THE POSITIVE CASE IS SILENT. Zero fires at the truck station only discriminates
-- if the halftrack station fires. Absence everywhere is absence of evidence, not evidence of a
-- working name filter. Do not mark T6 either way until the positive half fires.
local T9_T6 = {
    -- T9 at (200,200). AT squads at 35 m and 40 m, not 80 m: at 80 m the Panzer II C SURVIVED the
    -- whole battle, so there was nothing to bail out of and the scenario was not a valid run.
    -- Two squads, to make the kill reliable rather than hoped for.
    { pos = vec3(235, 0, 200), side = "defender", squad = "fr_ATsquad",        radius = 8 },
    { pos = vec3(240, 0, 235), side = "defender", squad = "fr_ATsquad",        radius = 8 },
    -- T6 at (700,200)
    { pos = vec3(700, 0, 200), side = "invader",  squad = "ger_infantry_1940", radius = 10 },
    { pos = vec3(775, 0, 200), side = "defender", squad = "fr_ATsquad",        radius = 10 },
    -- T6 control at (1200,200)
    { pos = vec3(1200, 0, 200), side = "invader",  squad = "ger_infantry_1940", radius = 10 },
    { pos = vec3(1275, 0, 200), side = "defender", squad = "fr_ATsquad",        radius = 10 },
}
-- Vehicles: { name, pos, direction }. ARG 3 IS A vec3 DIRECTION, NOT DEGREES - a number throws
-- inside the engine's own marshalling and the throw ESCAPES pcall, killing the phase script.
local T9_T6_VEHICLES = {
    { "Panzer II C",    vec3(200, 0, 200),  vec3(1, 0, 0) },   -- T9: the crewed tank
    { "Sdkfz251 1939",  vec3(720, 0, 200),  vec3(1, 0, 0) },   -- T6: real armour
    { "Opel Blitz",     vec3(1220, 0, 200), vec3(1, 0, 0) },   -- T6c: a truck, must NOT qualify
}
-- Squads that must spawn ON a vehicle: { squadId, vehiclePos }. The crew branch and the transport
-- branch both key off what the man was RIDING, so a dismounted spawn cannot reach either.
local T9_T6_MOUNTED = {
    { "ger_tankCrew_1940", vec3(200, 0, 200) },
}

-- FORMATION RIG. One MG-centric German squad, NO enemies, an objective 250 m away so the squad
-- approach-marches. Spawn radius 35, deliberately wide: RALLY-on-MG only fires for a man more
-- than MG_COHESION 25 m from the gunner, and a tight spawn puts everyone inside that so the
-- branch never fires and they all just ROAD-MARCH.
local FORMRIG = {
    { pos = vec3(300, 0, 300), side = "invader", squad = "ger_infantry_1940", radius = 35 },
}

-- DONCHERY ORDER OF BATTLE, spliced in from missions/donchery_oob.lua by
-- tools/gen_donchery_inline.py. It is NOT loaded at runtime: loadfile() resolves from
-- '<mission>/globals/', a root that could not be located from outside the game, and its failure
-- is a HARD engine error that ABORTS the phase script even inside pcall. So the loader is removed
-- and the data is inlined. The data file remains the reviewable source of truth and is gated by
-- check 4h; check 4i asserts this copy is in sync with it.
-- >>> BEGIN GENERATED DONCHERY OOB - edit missions/donchery_oob.lua, then run tools/gen_donchery_inline.py
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
    local vIdx = #DONCHERY.vehicles   -- this crew's own vehicle, by index, for the rig
    -- Crews spawn ABOARD, which is the only way the crew bail-out branch is reachable: it keys
    -- off what the man was RIDING. Editor-placed vehicles carry a faction; script-spawned ones do
    -- not, so features 5 and 18 are only re-provable here if these are converted to editor
    -- spawners. See docs/donchery-build-sheet.md.
    DONCHERY.mounted[#DONCHERY.mounted + 1] = { "ger_tankCrew_1940", vec3(DY_ORIGIN.x + a[2], DY_ORIGIN.y, DY_ORIGIN.z + EMBANKMENT), "invader", vIdx }
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
        -- RE-SPACE ACROSS THE FRONTAGE. Selecting the first N matching entries pulls the whole
        -- assault onto one flank: the researched line puts 12 Gruppen across 420 m, so the first
        -- three sat at x = -210, -172, -134 - the entire attack crammed into 76 m of the left
        -- bank. Reported from play as "the Germans clump along the river". Selection is by TYPE,
        -- so positions must be redistributed afterwards or trimming silently changes the frontage
        -- as well as the force size.
        local inv = 0
        for _, sq in ipairs(kept) do if sq.side == "invader" then inv = inv + 1 end end
        if inv > 1 then
            local k = 0
            for _, sq in ipairs(kept) do
                if sq.side == "invader" then
                    sq.pos = vec3(DY_ORIGIN.x - FRONTAGE / 2 + (FRONTAGE / (inv - 1)) * k,
                                  sq.pos.y, sq.pos.z)
                    k = k + 1
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
-- <<< END GENERATED DONCHERY OOB

-- SHOWCASE DEMONSTRATION RANGE, spliced in from missions/scenarios/showcase.lua by
-- tools/gen_showcase_inline.py. Only that file's RIG-DATA PREFIX is inlined - the text above its
-- `--@@ SHOWCASE INLINE CUT` marker - because its tail is a standalone phase script whose
-- `while true ... sleep(1)` HUD loop would mean not one setCallback below ever registers.
-- Not loaded at runtime for the same reason the Donchery OOB is not: loadfile() resolves from an
-- unlocatable '<mission>/globals/' and its failure ABORTS the phase script even inside pcall.
-- The data file remains the reviewable source of truth, gated by check 4f (offline_showcase);
-- check 4m asserts this copy is in sync with it.
--
-- IT BUILDS `local SHOWCASE = { squads, vehicles, mounted }` and SPAWNS the fourteen station
-- objectives at load. Objective creation needs no callback, so doing it here is safe; squad
-- spawning is NOT, which is why the squads go through the deferred rig instead.
-- >>> BEGIN GENERATED SHOWCASE RANGE - edit missions/scenarios/showcase.lua, then run tools/gen_showcase_inline.py
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
-- 200 m, NOT 500. At 500 the grid was 1500 m across and I finally LOOKED at it: a man alone in
-- an empty desert with no other station in sight, no landmark, nothing to walk toward. A
-- walk-the-line range needs a line you can see. At 200 m several stations are visible at once and
-- the whole exhibit fits in 600 m.
--
-- THE CONSTRAINT IS ARITHMETIC, not taste: a station's enemies sit enemyD along +X, so the nearest
-- foreign unit to the next centre is GAP - enemyD, and that must clear SENSE (90) plus MARGIN.
-- 200 - 75 = 125 against a required 115. The old 500/300 pairing had the same margin with ten
-- times the walking.
local STATION_GAP = 200             -- m between station centres (SENSE_RADIUS is 90)
-- GRID IS 4 COLUMNS. Deliberately a literal in cell() and in the origin maths below rather than a
-- named local: this file is INLINED into RealisticEvents.lua, whose main chunk is at the Lua
-- 200-local ceiling, and adding one more local broke the build with "main function has more than
-- 200 local variables". Constants go inline here; only state goes in a table. If you change the
-- column count, change it in BOTH cell() and the `half` expression - they must agree or the grid
-- will not be centred.
-- 4 columns x 200 m = a 600 m span: fits a 1000 m map centred on the objective, and does NOT fit
-- the 500 m map the range was previously (and invisibly) built off the edge of.

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
    -- ipairs, NOT pairs. With pairs + break, "the first objective" is whatever hash order yields,
    -- so the entire 600 m range could silently relocate between two runs of the same mission.
    -- ipairs gives the same answer every time; the pairs fallback below only runs if the engine
    -- filled a non-sequential table.
    local op
    for _, o in ipairs(objs) do
        op = o and scSafeGet(function() return o.getPosition() end)
        if op then break end
    end
    if not op then
        for _, o in pairs(objs) do
            op = o and scSafeGet(function() return o.getPosition() end)
            if op then break end
        end
    end
    if op then
        -- CENTRE the grid on the objective. This used to be `op + (400, 0, +400)`, to keep the
        -- range clear of whatever the mission was already fighting over - but the test map is
        -- 500 x 500 (coords ~ -250..+250) and that offset threw all thirteen stations OFF THE MAP:
        -- measured at x 372->1072, z 466->1166, with the player spawning ~595 m from station 1 and
        -- ~1040 m from station 13. That is the "mostly empty, nothing to see" the user reported.
        -- Centring costs the original separation, which is fine: the host mission contributes two
        -- editor squads (~13 men) and four trench props, not a battle worth avoiding.
        local half = (4 - 1) * STATION_GAP / 2      -- (COLS-1)/2; COLS is 4, see the note by STATION_GAP
        ORIGIN = vec3(op.x - half, op.y, op.z - half)
        scLog(string.format("origin: grid CENTRED on the first mission objective (%.0f,%.0f) "
                            .. "-> range origin (%.0f,%.0f), span %.0f m",
                            op.x, op.z, ORIGIN.x, ORIGIN.z, (4 - 1) * STATION_GAP))
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

-- Every spawn goes through here, so this is the one place that decides whether the range sits ON
-- the ground. It used to return ORIGIN.y unconditionally - and ORIGIN.y is the first OBJECTIVE's
-- height, not the terrain's. The getTerrainHeight fix was applied to the diorama's query centre
-- (below) and never to the spawns themselves.
--
-- The vec3 form is deliberate. easyred2.com/wiki/scripting lists `getTerrainHeight(x, z)`, but
-- docs/verified-api.md:410 records `er2.getTerrainHeight(vec3(x,0,z))` observed FOUR TIMES in
-- shipped official scripts (including the Kwajalein artillery script). Shipped code beats a wiki
-- summary; do not "fix" this to two numbers.
--
-- Build a FRESH vec3 at the point of use and never persist it - showcase.lua's own history records
-- a persisted-vec3 UserData bug that made a 640 m query report zero soldiers while the brain was
-- logging seven men at that station.
local function at(dx, dz)
    local x, z = ORIGIN.x + dx, ORIGIN.z + dz
    local gy = scSafeGet(function() return er2.getTerrainHeight(vec3(x, 0, z)) end)
    return vec3(x, (type(gy) == "number" and gy) or ORIGIN.y, z)
end

-- Grid: 4 columns, filled row by row, so thirteen stations fit with room to spare.
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
      ger = { GER_RIFLE, GER_RIFLE }, enemy = { FR_RIFLE }, enemyD = 75,
      note = "enemy at 120 m is OUTSIDE PINNED_RADIUS 50, which the medic sortie requires" },

    { n = 9, expect = {1}, name = "9 Crew bail-out",
      shows = "crew leave the wreck, then CREW-onfoot away from the enemy",
      ger = { GER_CREW }, enemy = { FR_GUNS }, enemyD = 75,
      vehicles = { { V_PZ2, 0, 0 } },
      note = "a CREWED vehicle, not a truck: truck occupants are passengers, not crew" },

    { n = 10, expect = {17}, name = "10 Radio fire mission",
      shows = "RADIO-fire-mission, and a barrage that actually LANDS",
      ger = { GER_RIFLE }, enemy = { FR_RIFLE, FR_RIFLE, FR_RIFLE }, enemyD = 75,
      note = "80 m clears FIRE_DANGER_R, which is 50 m (RealisticEvents.lua:61) - NOT the 90 m "
          .. "this note used to quote. At 90 the radius equalled SENSE_RADIUS, so the gate was "
          .. "arithmetically impossible to open and every barrage was refused danger-close. That "
          .. "was the bug, not the geometry; 24 shells landed once it was 50" },

    { n = 11, expect = {30, 31}, name = "11 Transport reuse",
      shows = "RETURN-to-transport then REBOARD-transport",
      ger = {}, mounted = { GER_RIFLE }, enemy = {}, objectiveD = 200, objectiveAxis = "z",
      vehicles = { { V_TRUCK, 30, 0 } },
      note = "no contact, objective beyond REBOARD_MIN_DIST 120, truck inside REBOARD_SCAN 60. "
          .. "objectiveAxis='z' is REQUIRED: 200 m on the default +X axis lands exactly on station "
          .. "12's centre, inside ARRIVE_RADIUS of its squads at spawn. Row 3 is empty at this "
          .. "column, so +Z keeps the distance the feature needs and hits nothing" },

    { n = 12, expect = {26}, objective = "attract", name = "12 Consolidate and objective flow",
      shows = "CONSOLIDATE, capture, then flow to the second objective",
      ger = { GER_RIFLE, GER_RIFLE }, enemy = { FR_RIFLE }, enemyD = 75,
      secondObjective = true,
      note = "small enough that objective 1 falls in minutes, then attraction releases it" },

    { n = 13, expect = {24, 10}, name = "13 Kill feed and callouts",
      shows = "on-screen kill feed, one squadmate callout per death",
      ger = { GER_RIFLE }, enemy = { FR_RIFLE }, enemyD = 75,
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
-- 25 m of clear air beyond sensing range. 60 was generous when stations were 500 m apart and cost
-- nothing; at 200 m it is the difference between a watchable range and an empty one. validateLayout
-- still refuses any layout that breaches SENSE + MARGIN, so this is a tightened budget, not a
-- removed check.
local MARGIN = 25            -- how much clear air to demand beyond sensing range
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
    -- THE STATION CENTRE MUST SIT ON THE GROUND, not at the objective's height. at() carries
    -- ORIGIN.y, and ORIGIN is derived from the mission's first OBJECTIVE - which is not at ground
    -- level. Every diorama query is a 3D sphere around this point, so an objective even 200 m up
    -- empties a 160 m query: measured in-game as "13 stations, 1 flagged, 0 SEEN", which silently
    -- disabled the heal tick, the reset, the casualty and the station signs all at once, across
    -- four runs. Terrain height puts the centre where the men actually are.
    local centre = at(dx, dz)
    do
        local gy = scSafeGet(function() return er2.getTerrainHeight(centre) end)
        centre = vec3(centre.x, gy or 0, centre.z)
    end
    -- STATIONS THAT NEED A CASUALTY. The medic and the stretcher-drag branches only exist when
    -- somebody is DOWN, and the diorama's heal tick makes everyone effectively immortal so a
    -- casualty never occurs naturally. Rather than weaken the immortality - which is what keeps
    -- the exhibit from emptying out - these stations get a SCRIPTED casualty each round:
    -- incapacitate() puts one man down, and he is exempt from healing until the reset revives him.
    -- Station 8 is MEDIC-sortie / DRAG-approach. Station 9 (crew bail-out) is NOT listed: it needs
    -- a DESTROYED vehicle, and destroying one triggers an engine bug - Vehicle:OnDestroy ->
    -- ForceExitAllVehicle -> a missing 'er2animations' bundle -> a storm of 126 NullReferenceExceptions
    -- (measured 2026-09-09). Triggering that on purpose would drown the range's own log in noise.
    -- POSITIONS ARE STORED AS PLAIN NUMBERS, never as a persisted vec3. A vec3 is engine
    -- UserData, and this project already bans putting one in a global because that is fatal
    -- (docs/verified-api.md:255). Keeping one in a TABLE for minutes and then handing it to
    -- getSoldiersInArea turns out to be just as useless: the diagnostic said "0 seen" from a
    -- 640 m sphere while the brain logged seven men at that very station - and the brain's
    -- identical query works precisely because it builds its vec3 FRESH every tick from
    -- getPosition(). Same reason moveTo did nothing on reset, which is why the drift never
    -- improved. Numbers survive; handles do not.
    local stn = { n = s.n, name = s.name,
                  cx = centre.x, cy = centre.y, cz = centre.z,
                  inv = {}, def = {}, needsCasualty = (s.n == 8) }
    SHOWCASE.stations[#SHOWCASE.stations + 1] = stn

    -- A LANDMARK, so the station can be FOUND. Screenshots from inside the game showed the real
    -- problem with this range: featureless sand in every direction, with nothing to walk toward.
    -- Shrinking the grid to 200 m helps only if there is something to see at 200 m, and a truck is
    -- visible across open ground where a prone rifleman is not.
    --
    -- An Opel Blitz specifically, and that choice is load-bearing: it is a SOFT-SKIN, so
    -- isArmour() rejects it (gated by tests/armour_filter_check.py). A tank here would be treated
    -- as cover by ADVANCE-behind-armour and hunted by the AT branch, quietly corrupting the very
    -- demonstrations the landmark exists to help you find. Placed 30 m BEHIND the German line, out
    -- of the axis of advance, so it marks the station without standing in it.
    addVeh("Opel Blitz", at(dx - 30, dz), vec3(0, 90, 0))

    -- German side
    for i, sid in ipairs(s.ger or {}) do
        addSquad(sid, at(dx + (i - 1) * 20, dz), "invader", 12)
        do local m = at(dx + (i - 1) * 20, dz)
           stn.inv[#stn.inv + 1] = { x = m.x, y = m.y, z = m.z } end
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
        do local m = at(dx + ed, dz + (i - 1) * 25)
           stn.def[#stn.def + 1] = { x = m.x, y = m.y, z = m.z } end
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
    -- The objective must sit INSIDE this station's own cell or squads march into the neighbour's.
    -- Half the gap is 100 m, so 95 is the ceiling; it must also stay clear of ARRIVE_RADIUS (30)
    -- or a squad consolidates on its own objective instead of demonstrating anything.
    local od = s.objectiveD or math.min(95, (s.enemyD or 60) + 25)
    local attract = (s.objective == "attract")
    -- MOST objectives go beyond the enemy on +X (see above). Station 11 cannot: its feature needs
    -- the objective beyond REBOARD_MIN_DIST 120, while the layout ceiling is 95 (half the gap), and
    -- those are arithmetically incompatible at a 200 m gap. It was set to 200 on +X, which put it
    -- EXACTLY on station 12's centre (972,866 on the old origin) - inside ARRIVE_RADIUS of station
    -- 12's squads at spawn, which is why station 12 was measured consolidating the moment it built.
    --
    -- The way out is the empty cell: station 11 is grid (col 2, row 2) and row 3 holds only station
    -- 13 at col 0, so (col 2, row 3) is vacant ground. Sending station 11's objective along +Z
    -- keeps the 200 m the feature needs AND lands it on nothing. `objectiveAxis` exists for that.
    local odx, odz = od, 0
    if s.objectiveAxis == "z" then odx, odz = 0, od end
    local o = scSafeGet(function()
        return spawnMissionObjective(at(dx + odx, dz + odz), 45, s.name, 0, attract)
    end)
    -- KEEP the handle, per station. It was previously used only as a truthiness test and thrown
    -- away, which is why CYC.sign had nothing to write to and every label stayed frozen at its
    -- construction-time text for the life of the battle.
    if o then
        labels[#labels + 1] = s.name
        SHOWCASE.objectives = SHOWCASE.objectives or {}
        SHOWCASE.objectives[s.n] = o
    else
        failed = failed + 1
    end
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
        scSafe(function() spawnMissionObjective(at(dx + od, dz - 90), 45,
                                                s.name .. " (second)", 0, true) end)
    end

    scLog(string.format("station %-2d @(%.0f,%.0f)  %s", s.n, centre.x, centre.z, s.shows))
end

scLog(string.format("range built: %d squads, %d vehicles, %d mounted, %d labels, %d failures",
      #SHOWCASE.squads, #SHOWCASE.vehicles, #SHOWCASE.mounted, #labels, failed))

end   -- if layoutErrors > 0 ... else

--============================================================================
-- <<< END GENERATED SHOWCASE RANGE

-- Ships INERT. To arm a scenario, assign the matching trio:
--   FORMRIG -> TEST_SPAWNS = FORMRIG   (one wide-spawned MG-centric squad, no enemies)
--   T10   -> TEST_SPAWNS = T10
--   T9+T6 -> TEST_SPAWNS = T9_T6, TEST_VEHICLES = T9_T6_VEHICLES, TEST_MOUNTED = T9_T6_MOUNTED
-- Ships INERT. To run Donchery, swap these three to the DONCHERY tables:
--   TEST_SPAWNS = DONCHERY.squads, TEST_VEHICLES = DONCHERY.vehicles,
--   TEST_MOUNTED = DONCHERY.mounted
-- and disable the mission's own editor unit spawners so nothing doubles up.
-- To run the SHOWCASE demonstration range, swap them to the SHOWCASE tables instead:
--   TEST_SPAWNS = SHOWCASE.squads, TEST_VEHICLES = SHOWCASE.vehicles,
--   TEST_MOUNTED = SHOWCASE.mounted
-- NEITHER is done in the repo copy. tools/deploy.py injects the Donchery trio for
-- ME_Stonne_38n85202 and the SHOWCASE trio for "ME_Realistic Test map_o6526q70" at deploy time,
-- asserting the declaration ordering as it goes, so this file stays the clean inert shipping build
-- that check 6 gates.
local TEST_SPAWNS   = {}
local TEST_VEHICLES = {}
local TEST_MOUNTED  = {}
local TEST_OBJECTIVE = nil     -- e.g. vec3(0,0,60); nil = don't create one
local TEST_OBJ_RADIUS = 40

-- SPAWN PACING. A batch this size CANNOT be issued in one frame. The Donchery order of battle
-- (31 squads, 28 vehicles, 18 crews = 77 engine spawn calls) stopped dead at squad 6 of 31 with
-- ZERO failures and ZERO Lua errors — the script simply ceased, which is the documented
-- phase-loop-death signature and is indistinguishable from success in the log. Two causes are
-- consistent with that evidence and this handles both:
--   * the engine needs FRAMES to instantiate what it has been asked for, and a synchronous burst
--     either exhausts a per-frame budget or outruns the instantiation queue;
--   * an engine-side throw on one item ESCAPES pcall (proven twice already — spawnVehicle's
--     bad-argument throw and loadfile's failure both kill the script from inside a pcall).
-- So: yield every SPAWN_BATCH items, and LOG BEFORE EACH ATTEMPT rather than only after it.
-- The pre-log is the diagnosis that was missing: "6 ok lines" cannot distinguish "item 7 failed"
-- from "item 7 killed the script before it could report", because the only dbg() call came AFTER
-- the pcall. An "attempting" line with no matching result names the fatal item exactly.
local SPAWN_BATCH = 4          -- items per frame-yield; 77 calls / 4 ~= 20 sleeps ~= 2 s of setup
local SPAWN_PAUSE = 0.1

local function spawnYield(n)
    if n % SPAWN_BATCH == 0 then pcall(function() sleep(SPAWN_PAUSE) end) end
end

-- DEFERRED, DELIBERATELY. This rig used to EXECUTE HERE, before a single callback was
-- registered - and that is why the Donchery run reported "zero errors" while doing nothing.
-- The spawn burst died partway, and because soldier_spawned (brain auto-attach), soldier_died
-- (kill feed, squadmate callouts, the loop-death pump) and vehicle_destroyed (crew bail-out)
-- are all registered LATER in this file, none of them ever registered. The mod was not
-- partly alive with 6 squads; it was entirely dead, and silent about it.
-- So the rig is now a function, invoked immediately before the main loop once every callback is
-- armed. A spawn death then costs the spawns and the periodic loop, but the event-driven
-- features survive - and pumpIfLoopDead already exists to drive the periodic work from
-- soldier_died when the loop is gone.
local function runSpawnRig()
    if #TEST_SPAWNS > 0 then
        for i, s in ipairs(TEST_SPAWNS) do
            local fac = (s.side == "invader") and INV or DEF
            dbg(string.format("test spawn %d/%d: attempting %s %s", i, #TEST_SPAWNS,
                tostring(s.side), tostring(s.squad)))
            local ok, sq = pcall(function()
                return spawnSquad_script(s.pos, s.radius or 12, fac, s.squad, "Realistic.lua")
            end)
            if not ok or sq == nil then
                -- fall back to a brainless spawn; auto-attach below will still catch the soldiers
                ok = pcall(function() spawnSquad(s.pos, s.radius or 12, fac, s.squad) end)
            end
            dbg(string.format("test spawn %d: %s %s -> %s", i, s.side, tostring(s.squad),
                ok and "ok" or "FAILED (check the squad id in Id tables)"))
            spawnYield(i)
        end
    end

    -- Vehicles for a scenario rig. Direction is a vec3; see the note on the tables above.
    -- HANDLES ARE KEPT, not re-discovered later. The OFFICIAL reference says spawnVehicle
    -- RETURNS a Vehicle (easyred2.com/wiki/scripting.php?id=spawnvehicle), which
    -- contradicts this project's own note that it "returns nothing usable". That note is
    -- why mounted crews were located by an AREA SCAN, and why the first fully-successful
    -- rig run still reported `test mounted 1: ger_tankCrew_1940 -> FAILED (no vehicle
    -- found in range)` with all 25 vehicles placed. Keeping the handle removes the guess.
    local vehHandles = {}
    for i, v in ipairs(TEST_VEHICLES) do
        dbg(string.format("test vehicle %d/%d: attempting %s", i, #TEST_VEHICLES, tostring(v[1])))
        local ok, h = pcall(function() return spawnVehicle(v[1], v[2], v[3]) end)
        if ok and h then vehHandles[i] = h end
        dbg(string.format("test vehicle %d: %s -> %s", i, tostring(v[1]),
            ok and ((h and "ok (handle kept)") or "ok (NO handle returned)")
                or "FAILED (check the vehicle name, and that arg 3 is a vec3)"))
        spawnYield(i)
    end

    -- Squads that must start MOUNTED. The vehicle handle is found by AREA SCAN, because spawnVehicle
    -- returns nothing usable (it resolves to spawnVehicleWithCallback). getVehiclesInArea is
    -- fill-style and must be called WITH a table.
    for i, m in ipairs(TEST_MOUNTED) do
        -- SIDE IS m[3], AND IT MATTERS. This loop used to hardcode INV for every mounted crew. On
        -- Donchery that put the SIX FRENCH Hotchkiss crews on the GERMAN side — enemy gunners manning
        -- the French emplacements, firing the wrong way across the river. Nothing errored and nothing
        -- in the log said so, because a crew spawning on the wrong faction is a perfectly successful
        -- spawn. Defaults to invader when unspecified, which is what every rig-era entry relied on.
        local fac = (m[3] == "defender") and DEF or INV
        dbg(string.format("test mounted %d/%d: attempting %s (%s)", i, #TEST_MOUNTED,
            tostring(m[1]), tostring(m[3] or "invader")))
        -- m[4], when present, is the INDEX into TEST_VEHICLES of this crew's vehicle.
        -- Exact, and immune to the vehicle not being discoverable by a scan yet.
        local veh = m[4] and vehHandles[m[4]] or nil
        local how = veh and "handle" or "area-scan"
        if not veh then
            local vlist = {}
            pcall(function() er2.getVehiclesInArea(m[2], 40, vlist) end)
            for _, cand in pairs(vlist) do if cand then veh = cand break end end
        end
        local ok = false
        if veh then
            ok = pcall(function()
                return spawnSquadOnVehicle_script(m[2], 8, fac, m[1], veh, "Realistic.lua")
            end)
        end
        dbg(string.format("test mounted %d: %s via %s -> %s", i, tostring(m[1]), how,
            ok and "ok (aboard)" or "FAILED (no vehicle found, or the API rejected it)"))
        spawnYield(i)
    end
    if TEST_OBJECTIVE then
        local ok = pcall(function()
            local o = spawnMissionObjective(TEST_OBJECTIVE, TEST_OBJ_RADIUS, "Take the objective", 0, true)
            if o then global.set(o.getUniqueId(), "realistic_test_obj") end
        end)
        dbg("test objective " .. (ok and "created" or "FAILED"))
    end
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
    for _, o in pairs(objs) do
        -- SKIP SHOWCASE STATION LABELS. The demonstration range spawns fourteen objectives: one
        -- non-attracting LABEL per station, which is a march target that keeps each squad on its
        -- own station, plus station 12's attracting pair which exists to demonstrate objective
        -- flow. This manager attracts everything in objList to both sides - unconditionally at
        -- load (line ~1082) and again every ATTRACT_EVERY seconds in loopBody - so without this
        -- filter it would turn all thirteen labels into attractors and steer base AI map-wide.
        -- That is the exact collapse the showcase's attractor=false design exists to prevent, and
        -- it has been measured for real: only 1-3 of 13 stations demonstrated anything. The labels
        -- tag themselves at spawn (global key "realistic_showcase_label"..uid); station 12's pair
        -- is deliberately UNTAGGED, so it stays managed and still demonstrates the flow.
        local skip = false
        if o then
            local uid = safeGet(function() return o.getUniqueId() end)
            if uid ~= nil
               and safeGet(function() return global.get("realistic_showcase_label" .. uid) end) then
                skip = true
            end
        end
        if o and not skip then fresh[#fresh + 1] = o end
    end
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

--========================= THE REPEATING DIORAMA =============================
-- Turns the showcase range from a one-shot into a LOOPING exhibit you can walk between: each
-- station acts out its branch, everyone marches home, and it runs again, indefinitely. This is the
-- standard shape of a developer AI test level - deterministic, repeatable scenarios treated as
-- versioned assets rather than a one-off scene.
--
-- THE ENGINE DOES NOT ALLOW TELEPORTING A SOLDIER. The Soldier class exposes moveTo, killSoldier,
-- healSoldier, incapacitate/stopIncapacitate and setInVehicle, and NOTHING that sets a position
-- (checked against the official class reference, easyred2.com/wiki/scripting.php?type_id=8). So a
-- reset cannot snap the cast back to their marks - they are ordered to WALK home, which is why the
-- reset window is generous.
--
-- IMMORTAL ACTORS. A diorama whose cast shoots each other empties out: after a few cycles the
-- stations are corpses and there is nothing to watch. Every actor is healed on a short tick and
-- un-incapacitated, so they still fight but cannot be permanently removed. Deliberately NOT
-- respawning - repeated spawning grows without bound and Donchery already proved there is an
-- undiagnosed ceiling on spawn count.
--
-- EVERYTHING LIVES IN ONE TABLE, functions included. This file is at the Lua 200-local ceiling now
-- that two data files are inlined into its main chunk: five plain locals for this feature broke
-- every script with "main function has more than 200 local variables", exactly as two constants
-- did in the brain earlier today. Table fields cost nothing. CYC.on is flipped by
-- tools/deploy.py for the test map only.
local CYC = {
    on     = false,
    act    = 60,    -- s performing. Shorter now the range is walkable: a round you can actually
                    -- stand through beats one you give up on.
    -- RESET MUST COVER THE WALK HOME, and 30 s did not. There is no teleport for soldiers, so a
    -- reset is a MARCH: at roughly 3 m/s, 30 s moves a man about 90 m. The station objective sits
    -- 180 m out and men were measured up to 658 m from their nearest station centre, with 20 of
    -- 113 beyond 220 m. So the old window expired long before anyone got back, the next act phase
    -- began from wherever they happened to be, and the drift ACCUMULATED every round instead of
    -- being cleared. 75 s covers ~225 m, which matches the 220 m station radius.
    -- 45 s to walk home. The gate in tests/offline_phase.lua demands reset x 3 m/s >= radius:
    -- 45 x 3 = 135 against a 90 m radius. It was 90 s for a 240 m radius; both shrank together,
    -- which is exactly the pairing that gate exists to enforce.
    reset  = 45,
    -- 2 s between heal ticks, halved. Watching the range showed the reinforcement pool draining
    -- 184 -> 78 in about ninety seconds, so men ARE dying between ticks - the "immortal actors"
    -- claim was reading a squad-scoped kill feed that reported zero. A tighter grid also puts more
    -- of the cast inside the streamed window, so more of them actually get healed.
    heal   = 2,
    -- 90 m, tracking the 200 m station spacing. This MUST stay under half the gap or a station
    -- claims men standing at its neighbour, and the whole point of the grid is that each station
    -- is a distinct exhibit. It was 240 when stations were 500 m apart; shrinking the range
    -- without shrinking this would have quietly merged the stations into one blur.
    radius = 90,
    t0     = nil,
    phase  = "act",
    lastHeal = 0,
    round  = 0,
    casualty = {},   -- station n -> uid of the man deliberately put down this round
}

-- Heal and revive every actor at every station: the only thing between a looping exhibit and a
-- field of bodies.
-- ONE QUERY HELPER FOR THE WHOLE DIORAMA. getSoldiersInArea is a 3D sphere, but a station is a
-- 2D patch of ground: a centre whose Y is off by more than the radius returns NOTHING, which is
-- exactly what happened in-game ("0 seen") and silently disabled heal, reset, casualty and signage
-- together. The station centre is now terrain-height, which fixes the cause; this helper is the
-- belt and braces - it queries a deliberately generous sphere and then filters on HORIZONTAL
-- distance, so no future Y discrepancy can empty a station again.
-- THE ENGINE DECIDES WHO WE CAN SEE, SO WORK FROM THAT SET. getSoldiersInArea only returns
-- soldiers STREAMED IN near the viewer, and the camera sits at the mission's own spawn area - not
-- at any station. Measured: "raw=5 kept=0" at station 1, i.e. five streamed men all more than
-- 240 m from that station centre, while 106 soldiers were alive across the grid. A per-station
-- query therefore finds nobody while nobody is standing there, which is what made heal, reset,
-- casualty and signage all appear broken for a dozen runs.
--
-- So the diorama stops asking "who is at station N" and instead asks "who can I see", then groups
-- them BY NEAREST STATION. The practical effect is the one the range wants: whatever station you
-- walk up to becomes the live one, because your presence is what streams it in.
CYC.streamed = function()
    local stns = SHOWCASE.stations or {}
    if #stns == 0 then return {}, {}, {} end
    local minx, minz, maxx, maxz = 1e9, 1e9, -1e9, -1e9
    for _, stn in ipairs(stns) do
        if stn.cx < minx then minx = stn.cx end
        if stn.cx > maxx then maxx = stn.cx end
        if stn.cz < minz then minz = stn.cz end
        if stn.cz > maxz then maxz = stn.cz end
    end
    local raw = {}
    local c = vec3((minx + maxx) / 2, stns[1].cy or 0, (minz + maxz) / 2)
    local span = math.max(maxx - minx, maxz - minz)
    local ok = pcall(function() er2.getSoldiersInArea(c, span + 3000, raw) end)

    local men, byStn, near, n = {}, {}, {}, 0
    for _, m in pairs(raw) do
        if m and safeGet(function() return m.isAlive() end) ~= false then
            local p = safeGet(function() return m.getPosition() end)
            local best, bestD2 = nil, nil
            if p then
                local bd = 1e18
                for _, stn in ipairs(stns) do
                    local dx, dz = (p.x or 0) - stn.cx, (p.z or 0) - stn.cz
                    local d = dx * dx + dz * dz
                    if d < bd then best, bd = stn, d end
                end
                bestD2 = bd
            end
            -- NEVER include the player. He is on the invaders' side, so no faction test excludes
            -- him: healing him made him immortal, and a reset moveTo would yank him off his feet
            -- mid-stride. er2.getPlayer() is nil while the phase script loads (verified-api.md:268)
            -- so it is resolved lazily here, not captured at load.
            local isPlayer = false
            if CYC.playerUid == nil then
                local pl = safeGet(function() return er2.getPlayer() end)
                CYC.playerUid = pl and safeGet(function() return pl.getUniqueId() end) or false
            end
            if CYC.playerUid then
                local uid = safeGet(function() return m.getUniqueId() end)
                isPlayer = (uid ~= nil and uid == CYC.playerUid)
            end

            if not isPlayer then
                n = n + 1
                men[n] = m
                if best then
                    byStn[best.n] = byStn[best.n] or {}
                    table.insert(byStn[best.n], m)
                    -- AT a station, for the heal tick. bd is a squared distance.
                    if bestD2 and bestD2 <= (CYC.radius * CYC.radius) then
                        near[#near + 1] = m
                    end
                end
            end
        end
    end
    dbg(string.format("DIORAMA streamed: ok=%s seen=%d grouped over %d stations, %d within "
        .. "radius %d", tostring(ok), n, #stns, #near, CYC.radius))
    return men, byStn, near
end

-- Heal BOTH sides - a one-sided heal empties the defenders and the station stops demonstrating
-- anything - but only men who are actually AT a station, and never the player.
--
-- This used to walk the whole streamed set with no radius and no player check, which made three
-- things immortal that should not be: the mission's own editor-placed squads (a 1945 SS AT squad
-- and English paratroopers, nowhere near the range), anything else the engine happened to stream
-- in, and THE PLAYER. Nothing near you could die, including you.
--
-- CYC.radius has been declared since the diorama was written and read by nothing. This is what it
-- was for. Note the bound applies to HEAL only: CYC.doReset deliberately sweeps far wider, because
-- its job is to recover a man who has drifted hundreds of metres, and the offline test asserts
-- exactly that recovery.
CYC.doHeal = function()
    local _, _, near = CYC.streamed()
    for _, m in pairs(near) do
        local uid = safeGet(function() return m.getUniqueId() end)
        local spared = false
        for _, cu in pairs(CYC.casualty) do if uid and cu == uid then spared = true end end
        if not spared then
            safe(function() m.stopIncapacitate() end)
            safe(function() m.healSoldier(100) end)
        end
    end
end

-- Wound ONE visible attacker, at whatever station he belongs to. Pinning this to station 8 was
-- pointless once the streamed set turned out to follow the player: the medic demo should happen
-- wherever you are standing, which is also where you can watch it.
CYC.hurt = function()
    local _, byStn = CYC.streamed()
    for n, group in pairs(byStn) do
        if not CYC.casualty[n] then
            for _, m in pairs(group) do
                local inv = (INV ~= nil) and
                    (safeGet(function() return er2.isSameFaction(m.getFaction(), INV) end) == true)
                if inv then
                    local uid = safeGet(function() return m.getUniqueId() end)
                    if uid then
                        CYC.casualty[n] = uid
                        safe(function() m.incapacitate() end)
                        announce(string.format("DIORAMA: station %d - a man is down, watch the "
                                 .. "medic and the stretcher party", n))
                        return
                    end
                end
            end
        end
    end
end

CYC.doReset = function()
    local stns = SHOWCASE.stations or {}
    if #stns == 0 then return end

    -- Range centre and a radius that comfortably contains the whole 4x4 grid of 500 m cells.
    local minx, minz, maxx, maxz = 1e9, 1e9, -1e9, -1e9
    for _, stn in ipairs(stns) do
        if stn.cx < minx then minx = stn.cx end
        if stn.cx > maxx then maxx = stn.cx end
        if stn.cz < minz then minz = stn.cz end
        if stn.cz > maxz then maxz = stn.cz end
    end
    local cx, cz = (minx + maxx) / 2, (minz + maxz) / 2
    local span = math.max(maxx - minx, maxz - minz)
    local all = {}
    local c = vec3(cx, stns[1].cy or 0, cz)          -- FRESH vec3, never a stored handle
    safe(function() er2.getSoldiersInArea(c, span + 1200, all) end)

    local ni, nd = {}, {}
    for _, m in pairs(all) do
        if m and safeGet(function() return m.isAlive() end) ~= false then
            local p = safeGet(function() return m.getPosition() end)
            if p then
                -- nearest station by HORIZONTAL distance; y is irrelevant and has burned us once
                local best, bd = nil, 1e18
                for _, stn in ipairs(stns) do
                    local dx, dz = (p.x or 0) - stn.cx, (p.z or 0) - stn.cz
                    local d = dx * dx + dz * dz
                    if d < bd then best, bd = stn, d end
                end
                if best then
                    local inv = (INV ~= nil) and
                        (safeGet(function() return er2.isSameFaction(m.getFaction(), INV) end) == true)
                    local marks = inv and best.inv or best.def
                    if marks and #marks > 0 then
                        local k
                        if inv then
                            ni[best.n] = (ni[best.n] or 0) + 1; k = ((ni[best.n] - 1) % #marks) + 1
                        else
                            nd[best.n] = (nd[best.n] or 0) + 1; k = ((nd[best.n] - 1) % #marks) + 1
                        end
                        local mk = marks[k]
                        safe(function() m.moveTo(vec3(mk.x, mk.y or 0, mk.z)) end)
                    end
                end
            end
        end
    end
end

-- ONE-SHOT DIAGNOSTIC SWEEP. getSoldiersInArea answers for the three stations nearest the world
-- origin and returns n=0 for the other ten, with ok=true and no error, while the soldiers' own
-- logged positions prove they are standing there. Five hypotheses died guessing at that; this
-- measures it instead. In a single run it queries FOUR centres at FIVE radii and logs every count,
-- which separates the candidate explanations:
--   * if n grows with radius at a far centre -> the radius is effectively clamped
--   * if only centres near (0,0) ever answer -> the query is world-origin relative
--   * if a huge radius from st1 finds the far men -> the CENTRE is the problem, not the men
--   * if nothing ever exceeds ~10 -> there is a cap on the returned count
CYC.probe = function()
    if CYC.probed then return end
    CYC.probed = true
    local stns = SHOWCASE.stations or {}
    if #stns < 13 then return end
    local pts = {
        { "origin", 0, 0 },
        { "st1", stns[1].cx, stns[1].cz },
        { "st8", stns[8].cx, stns[8].cz },
        { "st13", stns[13].cx, stns[13].cz },
    }
    local radii = { 50, 160, 640, 2000, 6000 }
    for _, pt in ipairs(pts) do
        for _, r in ipairs(radii) do
            local t = {}
            local c = vec3(pt[2], stns[1].cy or 0, pt[3])
            local ok, err = pcall(function() er2.getSoldiersInArea(c, r, t) end)
            local n = 0
            for _ in pairs(t) do n = n + 1 end
            dbg(string.format("PROBE %-7s r=%-5d n=%-4d ok=%s err=%s at (%.0f,%.0f)",
                pt[1], r, n, tostring(ok), tostring(err), pt[2], pt[3]))
        end
    end
    -- Does a PLAYER-relative rule explain it? Log where the engine thinks the player is.
    local pp = safeGet(function() return er2.getPlayerSoldier().getPosition() end)
    dbg(string.format("PROBE player at %s",
        pp and string.format("(%.0f,%.0f,%.0f)", pp.x, pp.y, pp.z) or "unknown"))
end

CYC.step = function(now)
    if not CYC.on then return end
    if not CYC.t0 then
        CYC.t0 = now
        announce("DIORAMA: stations performing. Round 1 - walk the line; each resets every "
                 .. CYC.act .. "s")
        pcall(CYC.probe)
    end
    if (now - CYC.lastHeal) >= CYC.heal then
        CYC.lastHeal = now
        pcall(CYC.doHeal)
        pcall(CYC.sign)
    end
    -- RE-ISSUE THE RESET EVERY TICK WHILE RESETTING. This is the whole reason the reset appeared
    -- to do nothing in-game: the diorama ordered everyone home ONCE per 75-second window, while
    -- each soldier's BRAIN re-issues its own moveTo every MOVE_REISSUE seconds toward its
    -- objective. One order against thirty-odd - the brain simply overrode it within two seconds
    -- and marched everyone off again.
    --
    -- It is invisible offline, because the stub has no brain competing for the same soldier: the
    -- offline test passed "3/3 ordered home" while the real range drifted exactly as before
    -- (median 61 m, max 663 m, unchanged by raising the window). Symptoms that all looked
    -- separate - drift, an empty station 8 when the casualty fires, and every station reporting
    -- ROAD-MARCH - were this one cause.
    --
    -- So during a reset the diorama competes on frequency and wins.
    if CYC.phase == "reset" then pcall(CYC.doReset) end

    local elapsed = now - CYC.t0
    if CYC.phase == "act" and elapsed >= CYC.act then
        CYC.phase, CYC.t0 = "reset", now
        CYC.round = CYC.round + 1
        CYC.casualty = {}      -- revive last round's casualties; a new one is chosen next round
        announce(string.format("DIORAMA: round %d over - all stations resetting, actors walking "
                 .. "back to their marks (%ds)", CYC.round, CYC.reset))
        pcall(CYC.doReset)
    elseif CYC.phase == "reset" and elapsed >= CYC.reset then
        CYC.phase, CYC.t0 = "act", now
        announce(string.format("DIORAMA: round %d - stations performing again", CYC.round + 1))
        pcall(CYC.hurt)
    end
end

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
local WATCH = false -- diagnostic; check.sh refuses to ship this true
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
-- Format — NINE fields per soldier entry. This comment documented four until 2026-09-08 while the
-- emitter below wrote nine; both Python parsers branch on `len(parts) >= 8`, so a drift here is
-- silent. tests/check.sh now cross-checks this block against the format string in telemetryFrame().
--
--   [TELEM] <t> S <uid>,<x>,<y>,<z>,<flag>,<squad>,<inVeh>,<dec>,<ri>;<...>;...
--   [TELEM] <t> V <uid>,<x>,<y>,<z>,<name>;...
--
--   t      mission clock, %.1f
--   uid    soldier unique id (even stride of 262; may be negative)
--   x,y,z  rounded to whole metres - sub-metre precision is noise at map scale and costs bytes
--   flag   I invader · D defender · i invader suppressed · d defender suppressed · x down/dead
--          · ? neither side
--   squad  squad key = the squad LEADER's uid; 0 = unresolved
--   inVeh  1 if getCurrentVehicle() is non-nil. DIRECT, not inferred - men in a vehicle all report
--          the vehicle's position, which once faked a 1.0 m median spacing that was really 32 m, so
--          every spacing/formation statistic MUST filter on this
--   dec    the brain's decision code from global "D"..uid; 0 = unknown. Published CHANGE-ONLY, so
--          it is a latched last-known value, not a per-frame sample
--   ri     roster index from global "R"..uid. Only published when the BRAIN's DEBUG is true, so it
--          is 0 for the whole battle otherwise. Proves roster-slot stability, which every formation
--          feature depends on
local TELEMETRY  = false -- diagnostic; check.sh refuses to ship this true
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
    pcall(function() CYC.step(safeGet(function() return er2.time() end) or 0) end)
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
-- Every callback is armed by this point, so a spawn failure can no longer disarm the mod.
runSpawnRig()

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
