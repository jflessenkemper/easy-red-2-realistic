--============================================================================
-- Realistic.lua  —  per-soldier "realistic survival" brain for Easy Red 2
--   Attach via the Squad Spawner "Brain" field. Runs LOCALLY on every unit;
--   myself() is the soldier. Verified against build v2.0.9 (see .llm/api/verified-api.md
--   and the play-test forensics). This brain LAYERS caution + doctrine on top of
--   the engine's base AI; it never stores UserData in a global (that is fatal on
--   this build) and every uncertain call is guarded.
--
--   Behaviour:
--     - approach march along ROADS (flattest corridor toward the objective),
--       deploying off-road into cover the moment contact is made        (roads)
--     - take cover under fire via the engine findCover()                (survive)
--     - roles come from the NATIVE flags (isATSoldier/isMedic/isRadioman/
--       isMarksman/isSquadLeader) and pinning from the engine's own
--       isSuppressed(), both probe-confirmed 2026-08-29                 (native)
--     - MG-centric squads cohere on the Support (LMG) gunner            (doctrine)
--     - aggressive doctrines close to assault; methodical ones hold     (doctrine)
--     - medics hold cover, sortie to a casualty only when it is safe    (medic)
--     - rout when locally outnumbered past the nation's threshold       (morale)
--     - vocal reactions from the built-in VoiceClip enum                (voice)
--============================================================================

local DEBUG = false
-- VERBOSE = comprehensive per-tick, per-soldier decision logging (a firehose: every soldier
-- logs its full state + chosen action EVERY tick). Use it to VERIFY behaviour, then set it
-- false — logging is expensive on this build (~1.1 KB + a stack walk per line). When false,
-- per-tick lines are throttled + sampled (~1 soldier in DBG_SAMPLE); lifecycle lines always show.
-- Verification is complete, so the firehose is OFF: per-tick lines are now sampled
-- (~1 soldier in DBG_SAMPLE) and throttled. Set true again to re-verify behaviour — it costs
-- ~1.1 KB + a managed stack walk per line, and produced multi-million-line logs.
local VERBOSE = false

--========================== TUNABLES ========================================
local TICK           = 1.5    -- brain loop period (s)
local SENSE_RADIUS   = 90     -- m, area scan for friends/enemies
local THREAT_ENEMIES = 1      -- >=N enemies sensed => under threat
-- Pinned: the PRIMARY trigger is now the engine's OWN suppression state (isSuppressed(),
-- probe-confirmed 2026-08-29). The enemy-proximity test below is DEMOTED to a secondary
-- or-condition, for the man who is closely engaged but not yet formally suppressed.
-- (We POLL isSuppressed; we must never SUBSCRIBE to soldier_suppressed — the engine NREs
-- inside its own dispatch on that event and pcall cannot catch it.)
local PINNED_ENEMIES = 2      -- >=N enemies within PINNED_RADIUS => pinned (secondary trigger)
local PINNED_RADIUS  = 50     -- m
local COVER_RADIUS   = 22     -- m, radius passed to engine findCover()
local ROUT_FALLBACK  = 40     -- m, how far to fall back when routing
-- Rout: force ratio ALONE made this unreachable (PINNED consumed it), and force ratio alone
-- also fires too readily, so a man breaks when he is (a) collapsing — far below his nation's
-- floor — or (b) merely outnumbered AND bloodied (hurt himself, or friends down beside him).
local ROUT_COLLAPSE   = 0.60  -- x moraleFloor; below this he breaks even unbloodied
local ROUT_HURT_HP    = 65    -- own health (0..100) at/below which he counts as bloodied
local ROUT_CASUALTIES = 1     -- >=N friendly casualties sensed also counts as bloodied
local ROUT_COVER_DELAY = 3    -- s after the fallback order before taking cover (NEVER same tick)
-- Assault. It is evaluated ABOVE pinned (else PINNED always consumes it — measured 9 fires in
-- 10,731 decisions), but only for doctrines that are actually aggressive.
local ASSAULT_MIN_AGGR = 0.50 -- doctrines below this aggression never pre-empt PINNED
local ASSAULT_MARGIN   = 0.15 -- forceRatio must exceed moraleFloor by this much to press in
local ASSAULT_BOUND    = 15   -- m, length of one covered assault bound (see coverDiscipline)
-- Medic: reach for a casualty. The old gate (threatened AND no close enemy AND enemy >55 m AND
-- a casualty, all at once) was never satisfiable — a medic sorties whenever no enemy is inside
-- PINNED_RADIUS and the casualty is within reach, threatened or not.
local MEDIC_REACH    = 60     -- m, how far a medic will sortie for a casualty
-- Squad: getSquad() resolves late for ~15% of soldiers (56 of 371 measured), so re-attempt.
local SQUAD_RETRY    = 20     -- ticks between lazy getSquad() re-attempts until it resolves
-- Defenders HOLD THEIR LINE; they do not march to the objective.
-- MEASURED over two live battles: attackers move normally (122 m median displacement) but
-- defenders barely move (7 m) no matter what we order — base AI keeps them on their defensive
-- positions and wins, because allowFollowOrders is true. That is also the historically correct
-- behaviour for a defence, so we stop fighting it: a defender ALWAYS holds and takes cover.
-- There was a DEFEND_RADIUS escape hatch here letting a badly-out-of-position defender close on
-- the objective. It was measured again on 2026-08-29 and it never worked at any radius: 0.09 m/s
-- with 100% of the men stationary over 2755 pooled seconds. Both the constant and the branch are
-- deleted rather than tuned — no value of the radius makes an ignored order work.
-- Movement hysteresis: re-issuing moveTo to a slightly-different point every tick
-- fights the engine pathfinder and never lets a soldier settle. Only re-order when
-- the destination has moved > MOVE_DEADBAND, or MOVE_REISSUE seconds have passed.
local MOVE_DEADBAND  = 6      -- m
local MOVE_REISSUE   = 4      -- s
-- Roads: no road API is exposed to Lua, but the engine flattens terrain under roads,
-- so we bias the approach march toward the flattest corridor leading to the objective.
-- Approach-march ONLY: dropped the instant contact is made (a road under fire is a
-- killing zone). Approximate — may prefer fields/riverbanks; that is accepted.
local ROAD_FOLLOW    = true
local ROAD_STEP      = 25     -- m, look-ahead waypoint distance
-- Advance behind armour.
local USE_ARMOUR_COVER = true
local ARMOUR_SCAN    = 45     -- m
local ARMOUR_HUG     = 6      -- m behind the hull, enemy-opposite side. Tight on purpose: at 10 m
                              -- the hull stops being cover for the men behind it. See ARMOUR_SPREAD.
local ARMOUR_SPREAD  = 2.5    -- m between men in the line abreast behind the hull
-- Anti-tank. An AT man is the battalion's ONLY answer to armour, so he must not be spent as a
-- rifleman: without this branch `isATSoldier` only tagged the role and the man fell through into
-- the hoisted ASSAULT and charged infantry. This branch issues NO moveTo, so it behaves the same
-- for defenders (who ignore move orders) as for attackers — see §7 of realistic.md.
local AT_RANGE       = 120    -- m — acquire an enemy vehicle out to here
local AT_EFFECTIVE   = 60     -- m — inside this he stops closing and shoots
-- Radioman fire mission. A radioman calls for fire when the advance has STALLED against something
-- worth shelling — not on first contact. The phase script owns the danger-close refusal and the
-- gun itself; the brain only publishes a request. See RQ_* in the cascade for the wire protocol.
-- Wounded drag. There is NO dropBody on this build (verified-api.md: ABSENT), so `stop()` is the
-- only release once a man picks a body up. Every guard below exists to bound that: a no-op
-- carryBody must cost one man a few seconds, never freeze him for the rest of the battle.
local DRAG_RADIUS    = 30     -- m — how far a man will go to fetch a casualty
local DRAG_MAX_TIME  = 12     -- s — hard ceiling on one drag attempt, then abandon
local CARRY_MAX_TRIES = 3     -- attempts before this soldier gives up dragging entirely
local CARRY_ADJACENT = 3      -- m — close enough to attempt the pick-up
-- Bounding overwatch: one half of the squad moves while the other half watches and fires.
-- Consolidation. An attacker standing on the objective has nothing left to march to; ordering
-- him to a point he occupies makes him log ROAD-MARCH forever while stationary. Digging in to
-- face the counter-attack is also what he should be doing.
local ARRIVE_RADIUS  = 30     -- m from the objective at which an attacker consolidates
local BOUND_PERIOD   = 8      -- s per bound before the halves swap
local BOUND_STEP     = 20     -- m covered by one bound
local STALL_DIST     = 15     -- m — moved less than this in STALL_WINDOW counts as stalled
local STALL_WINDOW   = 30     -- s
local RADIO_MIN_ENEMIES = 3   -- sensed enemies needed before a mission is worth asking for
local RADIO_COOLDOWN = 120    -- s between requests from ONE radioman (the phase caps them again)

-- Reuse transport: passengers remember the vehicle they rode in and, when it's SAFE and the
-- next objective is far, walk back and re-board instead of abandoning it. EXPERIMENTAL —
-- boardVehicle's behaviour (and whether base AI then drives the truck) is not play-test-verified;
-- set false to disable if soldiers thrash board/leave or pile into a stationary truck.
local REUSE_TRANSPORT  = true
local REBOARD_MIN_DIST = 120  -- m; only mount up if the objective is at least this far
local REBOARD_SCAN     = 60   -- m; the remembered transport must be within this to bother
local BOARD_ADJACENT   = 6    -- m; close enough to actually board (else walk to it first)
local BOARD_REISSUE    = 5    -- s; throttle board attempts

-- Voice: built-in VoiceClip enum (verified names from global-metadata.dat). say() and
-- VoiceClip are BENCH-confirmed present on this build. Custom-wav path kept as an option.
local VOICE = { enabled = false }   -- set true + fill VOICE_WAV to use mission sounds/*.wav
local VOICE_WAV = {}
local VOICE_COOLDOWN = 6      -- s, per-kind voice cooldown (one "kind" may speak every 6 s)
-- scared reuses the fire/burn agony scream per the user's request.
local VOICE_ENUM = {
    enemySpot = "enemyInfantrySpotted",   -- fired on FIRST contact (see sawContact)
    underFire = "imUnderFire",
    hit       = "iVeBeenHit",             -- fired on the hit path (any health drop)
    scared    = "AAAAAH",
    fallback  = "timeToRetreat",
    charge    = "imCharging",
    covering  = "coveringFire",
    leader    = "keepYourHeadDown",
    enemyTank = "enemyTankSpotted",       -- AT man has acquired an enemy vehicle
}

--========================== FACTION DOCTRINE ================================
-- moraleFloor  : LOCAL FORCE-RATIO floor. Rout when friendlies/(friendlies+enemies)
--                sensed nearby drops below this. LOWER = braver / holds when outnumbered.
-- mgCentric    : riflemen cohere on the Support (LMG) gunner (squad supports the gun).
-- aggression   : 0..1 per-tick probability of pressing to assault when in range + steady.
-- assaultRange : m within which an aggressive, steady man closes to assault.
-- coverDiscipline : 0..1 preference for moving via cover/low ground while assaulting.
local DOCTRINE_DEFAULT = { moraleFloor=0.30, mgCentric=false, aggression=0.45, assaultRange=20, coverDiscipline=0.6 }
local DOCTRINE = {
    -- Germany, May 1940 (Sedan/Stonne): high tempo, MG-centric, presses hard, holds when outnumbered.
    germany      = { moraleFloor=0.22, mgCentric=true,  aggression=0.75, assaultRange=35, coverDiscipline=0.80 },
    -- France 1940: methodical battle doctrine, LMG-built section (FM 24/29), strong on the defensive,
    -- rigid command (slow to counter-attack) — steady, NOT brittle.
    france       = { moraleFloor=0.30, mgCentric=true,  aggression=0.40, assaultRange=20, coverDiscipline=0.80 },
    britain      = { moraleFloor=0.28, mgCentric=true,  aggression=0.50, assaultRange=25, coverDiscipline=0.85 },
    unitedstates = { moraleFloor=0.32, mgCentric=false, aggression=0.60, assaultRange=30, coverDiscipline=0.65 },
    soviet       = { moraleFloor=0.20, mgCentric=false, aggression=0.85, assaultRange=45, coverDiscipline=0.35 },
    japan        = { moraleFloor=0.18, mgCentric=true,  aggression=0.85, assaultRange=40, coverDiscipline=0.50 },
    italy        = { moraleFloor=0.38, mgCentric=true,  aggression=0.42, assaultRange=18, coverDiscipline=0.65 },
    finland      = { moraleFloor=0.20, mgCentric=true,  aggression=0.55, assaultRange=25, coverDiscipline=0.90 },
    romania      = { moraleFloor=0.36, mgCentric=true,  aggression=0.42, assaultRange=18, coverDiscipline=0.65 },
    hungary      = { moraleFloor=0.36, mgCentric=true,  aggression=0.42, assaultRange=18, coverDiscipline=0.65 },
}
-- Nation is derived DYNAMICALLY from the soldier's own faction handle, so this brain works on
-- ANY map / ANY belligerents — not just Germany vs France. ER2 faction handles stringify with
-- the nation in them (e.g. "Germany_axis", "France_allies", "SovietUnion_allies"). We parse that.
-- Most-specific tokens first (so "sovietunion" beats "soviet", "unitedstates" beats "usa").
local NATION_TOKENS = {
    {"sovietunion","soviet"}, {"unitedkingdom","britain"}, {"greatbritain","britain"},
    {"unitedstates","unitedstates"}, {"kingdomofitaly","italy"}, {"commonwealth","britain"},
    {"wehrmacht","germany"}, {"germany","germany"}, {"german","germany"},
    {"france","france"}, {"french","france"},
    {"soviet","soviet"}, {"russian","soviet"}, {"russia","soviet"}, {"ussr","soviet"},
    {"american","unitedstates"}, {"america","unitedstates"}, {"usa","unitedstates"},
    {"british","britain"}, {"britain","britain"}, {"england","britain"},
    {"japanese","japan"}, {"japan","japan"},
    {"italian","italy"}, {"italy","italy"},
    {"finnish","finland"}, {"finland","finland"},
    {"romanian","romania"}, {"romania","romania"},
    {"hungarian","hungary"}, {"hungary","hungary"},
}
local function nationFromFaction(f)
    local s = tostring(f or ""):lower()
    for _, pair in ipairs(NATION_TOKENS) do
        if s:find(pair[1], 1, true) then return pair[2] end
    end
    return nil   -- unknown/modded nation -> DOCTRINE_DEFAULT
end
local MG_COHESION = 25   -- m, how close an MG-centric rifleman stays to its Support gunner

--========================== HELPERS =========================================
-- Rate-limited debug log. Each log() on this build is a reflection call + a ~13-frame
-- managed stack walk + ~1.1 KB of I/O, so per-tick chatter MUST be throttled: dbg(msg,key,now)
-- emits at most one line per key per DBG_GAP seconds. dbg(msg) with no key is unthrottled
-- (reserved for one-shot lifecycle events).
local DBG_GAP    = 8
local DBG_SAMPLE = 6        -- ~1 soldier in DBG_SAMPLE emits per-tick state lines
local dbgLast    = {}
local uid        = 0        -- set in bootstrap
local TRACED     = true     -- set in bootstrap: does THIS soldier emit per-tick state?
local function dbg(msg, key, now)
    if not DEBUG then return end
    if not key then
        log("[REALISTIC] "..msg)   -- lifecycle line (msg already carries its own uid): always
        return
    end
    -- per-soldier state line, uid-tagged.
    --   VERBOSE  -> log EVERY soldier EVERY tick (the firehose).
    --   otherwise-> only a sample of soldiers, throttled to one per key per DBG_GAP s.
    if not VERBOSE then
        if not TRACED then return end
        if now then
            if dbgLast[key] and (now - dbgLast[key]) < DBG_GAP then return end
            dbgLast[key] = now
        end
    end
    log("[REALISTIC] #"..tostring(uid).." "..msg)
end

-- guarded call. Logs each DISTINCT failure ONCE (a persistently-failing call in the tick
-- loop would otherwise emit ~1.1 KB of stack trace every tick, on every soldier).
local guardSeen = {}
local function safe(fn)
    local ok, err = pcall(fn)
    if not ok and DEBUG then
        local key = tostring(err)
        if not guardSeen[key] then
            guardSeen[key] = true
            log("[REALISTIC] guard(once): "..key)
        end
    end
    return ok
end
local function safeGet(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

--========================== BOOTSTRAP =======================================
local me = myself()
if not me then return end

uid = safeGet(function() return me.getUniqueId() end) or 0
-- Sample on bit 1, NOT on uid % N: ER2 hands out unique IDs with an even stride (observed 262
-- apart), so uid % 6 only ever yields {0,2,4} and traced ~1 soldier in 3 instead of 1 in 6.
-- (uid // 2) distributes evenly — measured 148/165 over 313 real uids.
TRACED = (math.floor(math.abs(uid) / 2) % DBG_SAMPLE == 0)
-- Seed RNG PER SOLDIER. Each brain is its own Lua chunk; without a per-soldier seed every
-- brain draws the SAME math.random() sequence, so the assault dice fire in lockstep across the
-- whole force (shipped briefing.lua guards this same gotcha). uid is unique -> good seed.
pcall(function() math.randomseed(uid ~= 0 and uid or 1) end)
local myFaction = safeGet(function() return me.getFaction() end)
local homePos   = safeGet(function() return me.getPosition() end)   -- LOCAL upvalue (never a global)

-- getSquad()/isSquadLeader() are nil right after spawn (documented). Wait briefly for the
-- squad to form, else isLeader is always false (which is why leader doctrine never fired).
-- This poll is only a FAST PATH: ~15% of soldiers still miss it, and resolveSquad() below
-- recovers them lazily inside the tick loop.
do
    local waited = 0
    while not (safeGet(function() return me.isSquadReady() end) == true) and waited < 3 do
        sleep(0.25); waited = waited + 0.25
    end
end

-- ROLES: the NATIVE role flags are language-proof and mod-proof, and the 2026-08-29 probe
-- measured them clean over a whole battle (264 rifleman / 42 leader / 31 medic / 14 radioman /
-- 12 AT / 8 marksman), so the getClassName substring matching for those roles is GONE.
local isLeader   = safeGet(function() return me.isSquadLeader() end) == true
local isAT       = safeGet(function() return me.isATSoldier() end) == true
local isMedic    = safeGet(function() return me.isMedic() end) == true
local isRadio    = safeGet(function() return me.isRadioman() end) == true
local isMarksman = safeGet(function() return me.isMarksman() end) == true
-- Substring matching survives ONLY for the roles that have NO native flag:
--   * Support (the LMG gunner) and mortar — no flag exists for either;
--   * crew / pilot / mounted — no flag exists, and the robust runtime signal is
--     getCurrentVehicle() (checked every tick); this class hint is a belt-and-suspenders so we
--     also defer during the brief seat/spawn race.
-- Note isCrew deliberately does NOT match "gunner" (that is the "Support Gunner" LMG class),
-- and its "tank" token is now cleared by the native AT flag so a "Tank Hunter" is not swallowed.
local myClass  = tostring(safeGet(function() return me.getClassName() end) or ""):lower()
local isMG     = myClass:find("support") ~= nil   -- ER2 "Support" = the LMG gunner
local isMortar = myClass:find("mortar")  ~= nil
local isCrew   = (not isAT) and (myClass:find("pilot") or myClass:find("aircraft")
    or myClass:find("aircrew") or myClass:find("crew") or myClass:find("driver")
    or myClass:find("tank")) ~= nil

-- roleTag: most-specific first. Native-flag roles win over the class-string ones. Recomputed
-- when a squad resolves late, so a leader found on tick 20 does not trace as "trooper" forever.
local function makeRoleTag()
    return isCrew and "crew/aircraft"
        or (isLeader and "LEADER" or (isMedic and "medic" or (isAT and "AT"
        or (isMG and "MG-gunner" or (isMortar and "mortar" or (isMarksman and "marksman"
        or (isRadio and "radioman" or "trooper")))))))
end
local roleTag = makeRoleTag()

-- SQUAD, resolved LAZILY. The old "getSquad() returns nil for spawner-attached brains" limit is
-- RETRACTED: the 2026-08-29 in-brain probe resolved a real squad for 315 of 371 soldiers, and
-- the 56 nils were a TIMING artefact of the 3 s bootstrap poll above, not a context limit. So we
-- re-attempt every SQUAD_RETRY ticks until it resolves and then cache it — in a LOCAL UPVALUE,
-- because a Squad is UserData and UserData in a global is fatal on this build.
local mySquad    = safeGet(function() return me.getSquad() end)
local squadPeak  = 0          -- highest roster size ever seen (a casualty signal for ROUT)
local squadTicks = 0
local function resolveSquad()
    squadTicks = squadTicks + 1
    if not mySquad and (squadTicks % SQUAD_RETRY) == 0 then
        mySquad = safeGet(function() return me.getSquad() end)
        if mySquad then
            isLeader = safeGet(function() return me.isSquadLeader() end) == true
            roleTag  = makeRoleTag()
            dbg("#"..tostring(uid).." squad resolved late at tick "..tostring(squadTicks)
                .." leader="..tostring(isLeader))
        end
    end
    if not mySquad then return nil end
    local n = safeGet(function() return mySquad.getSquadSize() end)
    if type(n) == "number" then
        if n > squadPeak then squadPeak = n end
        return n
    end
    return nil
end

-- nation: derived from MY OWN faction handle (map-agnostic). Priority:
--   1) explicit per-side override global (optional manual control for modded/ambiguous maps)
--   2) parsed from my faction handle string
--   3) DOCTRINE_DEFAULT
local amInvader = safeGet(function()
    return er2.isSameFaction(myFaction, er2.getInvadersFaction())
end) == true
local override
if amInvader then override = global.get("realistic_nation_invaders")
else               override = global.get("realistic_nation_defenders") end
local myNation = override or nationFromFaction(myFaction) or "default"
local DOC = DOCTRINE[myNation] or DOCTRINE_DEFAULT

-- AiParams resolved ONCE via the GETTER ONLY (BENCH: "me.getAiParams() = ok").
-- There used to be an `or safeGet(function() return me.aiParams end)` fallback here. The
-- PROPERTY form throws on v2.0.9 and is what produced 20,689 errors in one battle; the fallback
-- was dormant only because the getter always wins, so it was a landmine waiting for a build
-- where the getter is missing — on which it would fire once per soldier. Removed rather than
-- kept guarded: there is no build where the property is the right answer.
-- Route every toggle through aiSet(): silent no-op if the member is unavailable, idempotent so
-- re-setting a held value is free.
local AIP = safeGet(function() return me.getAiParams() end)
local AIP_DEAD, AIP_STATE = {}, {}
local function aiSet(name, value)
    if not AIP or AIP_DEAD[name] then return false end
    if AIP_STATE[name] == value then return true end
    local ok = pcall(function() AIP[name](value) end)   -- dot-style: member(value), no self
    if ok then
        AIP_STATE[name] = value
    else
        AIP_DEAD[name] = true
        if DEBUG then log("[REALISTIC] aiParams."..name.." unavailable on this build - skipped") end
    end
    return ok
end

-- cautious-survival baseline (applied ONCE; the getter object is live so these take effect)
if AIP then
    aiSet("enableAiBehaviour", true)
    aiSet("allowCheckForEnemies", true)
    aiSet("allowFindCoverWhenSuppressed", true)
    aiSet("allowMovements", true)
    aiSet("allowFollowOrders", true)
    aiSet("allowBeingTargeted", true)
    aiSet("allowDoMedic", true)
    aiSet("allowChangePose", true)
else
    dbg("aiParams unavailable — running sense/override only")
end
local sqSize = mySquad and safeGet(function() return mySquad.getSquadSize() end) or nil
-- CROSS-CONTEXT PROBE: write a known integer the phase script can look for. If the phase
-- never sees it, `global` is not shared between a brain and the master-client phase script,
-- which would make the whole RQ_* fire-mission protocol a no-op. Integer only.
safe(function() global.set(4242, "PROBE_B2P") end)
dbg(string.format("ONLINE #%s %s/%s class='%s' faction=%s %s aiParams=%s squad=%s size=%s",
    tostring(uid), myNation, roleTag, myClass, tostring(myFaction),
    DOC.mgCentric and "[MG-centric]" or "[rifle-centric]", AIP and "ok" or "MISSING",
    mySquad and "yes" or "nil(retrying)", tostring(sqSize)))

--========================== SENSING =========================================
-- returns: nEnemies, nEnemiesClose, nFriends, enemyCentroid, nearestMGpos, nearestCasualtyPos,
--          nCasualties
local function sense(pos)
    local list = {}
    safe(function() er2.getSoldiersInArea(pos, SENSE_RADIUS, list) end)
    local ne, nec, nf, ncas = 0, 0, 0, 0
    local ex, ez, en = 0, 0, 0
    local mgPos, mgD = nil, 1e9
    local casPos, casD = nil, 1e9
    local casS = nil          -- the casualty's own handle: carryBody needs the Soldier, not a point
    for _, s in pairs(list) do
        -- SKIP SELF. getSoldiersInArea returns the caller too, so every soldier counted itself
        -- as a friend: nf was inflated by one, which biased the force ratio toward "not shaken"
        -- and helped make ROUT unreachable. Compare on the stable getUniqueId().
        local suid = s and safeGet(function() return s.getUniqueId() end) or nil
        if s and suid ~= uid then
            local alive = safeGet(function() return s.isAlive() end)
            local f = safeGet(function() return s.getFaction() end)
            local same = f ~= nil and safeGet(function() return er2.isSameFaction(f, myFaction) end) == true
            local sp = safeGet(function() return s.getPosition() end)
            if same then
                -- an incapacitated friendly is a casualty (not counted as a fighting friend)
                local down = safeGet(function() return s.isIncapacitated() end) == true
                if down then
                    ncas = ncas + 1
                    if sp then local d = distance(pos, sp)
                        if d < casD then casPos, casD, casS = sp, d, s end
                    end
                elseif alive ~= false then
                    nf = nf + 1
                    -- Support/MG is one of the two roles with NO native flag, so the gunner is
                    -- still found by class string (see the bootstrap note).
                    local cn = tostring(safeGet(function() return s.getClassName() end) or ""):lower()
                    if sp and cn:find("support") then
                        local d = distance(pos, sp); if d < mgD then mgPos, mgD = sp, d end
                    end
                end
            elseif f ~= nil and alive ~= false then
                ne = ne + 1
                if sp then
                    ex = ex + sp.x; ez = ez + sp.z; en = en + 1
                    if distance(pos, sp) <= PINNED_RADIUS then nec = nec + 1 end
                end
            end
        end
    end
    local centroid = (en > 0) and vec3(ex/en, pos.y, ez/en) or nil
    return ne, nec, nf, centroid, mgPos, casPos, ncas, casS
end

--========================== TERRAIN / ROADS =================================
local function terrainY(x, z)
    return safeGet(function() return er2.getTerrainHeight(vec3(x, 0, z)) end)
end

-- flatness of a segment = max-min terrain height sampled along it (smaller = flatter = road-like)
local function segFlatness(x0, z0, x1, z1)
    local mn, mx, got = nil, nil, false
    for i = 0, 4 do
        local t = i / 4
        local y = terrainY(x0 + (x1 - x0) * t, z0 + (z1 - z0) * t)
        if y then
            got = true
            if mn == nil or y < mn then mn = y end
            if mx == nil or y > mx then mx = y end
        end
    end
    if not got then return 1e9 end
    return mx - mn
end

-- pick a look-ahead waypoint toward `target` biased to the flattest corridor (a road proxy).
local function roadStepToward(pos, target)
    local dx, dz = target.x - pos.x, target.z - pos.z
    local m = math.sqrt(dx * dx + dz * dz)
    if m < ROAD_STEP then return target end          -- close enough: go straight to it
    local ux, uz = dx / m, dz / m
    local best, bestScore = nil, 1e18
    for _, off in ipairs({ 0, -20, 20, -40, 40, -60, 60 }) do
        local r = math.rad(off)
        local cs, sn = math.cos(r), math.sin(r)
        local rx, rz = ux * cs - uz * sn, ux * sn + uz * cs
        local nx, nz = pos.x + rx * ROAD_STEP, pos.z + rz * ROAD_STEP
        local score = segFlatness(pos.x, pos.z, nx, nz) + math.abs(off) * 0.02  -- small straightness bias
        if score < bestScore then
            best, bestScore = vec3(nx, terrainY(nx, nz) or pos.y, nz), score
        end
    end
    return best or target
end

-- take cover NEAR `center`. findCover is a COMMAND (returns void) — it orders the soldier to
-- find and move into the best cover within COVER_RADIUS of `center`; we must NOT then issue a
-- moveTo (that would countermand it). Throttled so we don't re-search every tick (thrash).
local lastCoverT = -1000
local function takeCover(center, now)
    if (now - lastCoverT) < MOVE_REISSUE then return end
    lastCoverT = now
    safe(function() me.findCover(center, COVER_RADIUS) end)
end

-- nearest objective position to `from` (drives the approach march); nil if none
local function objectivePos(from)
    local o = safeGet(function() return er2.getNearestObjective(from) end)
             or safeGet(function() return er2.getNearestObjective() end)
    if not o then return nil end
    return safeGet(function() return o.getPosition() end)
end

--========================== VOICE ===========================================
local voiceCooldown = {}
local function react(kind, now)
    if voiceCooldown[kind] and (now - voiceCooldown[kind]) < VOICE_COOLDOWN then return end
    voiceCooldown[kind] = now
    if VOICE.enabled and VOICE_WAV[kind] then
        safe(function() sayMissionClip(me, VOICE_WAV[kind]) end)
    elseif VOICE_ENUM[kind] then
        safe(function() me.say(VoiceClip[VOICE_ENUM[kind]]) end)   -- guarded
    end
    dbg("react:"..kind, "react"..kind, now)
end

--========================== MOVEMENT ========================================
-- SETTLED A/B EXPERIMENT — does suppressing base-AI order-following give our moveTo control?
-- RESULT (measured, balanced A/B in one battle, n=133 vs 128): suppression made NO
-- meaningful difference — overall -9%, attackers +11%, defenders -17% displacement, all
-- within noise. Defenders stayed put either way (66% vs 56% stuck), confirming their holding
-- is base-AI behaviour we cannot override and should not fight. Verdict: DO NOT suppress —
-- the switch and its permanently-false branch inside orderMove are DELETED.
-- KEEP THIS (load-bearing for every future uid-based split or sample):
--   uid % N does NOT work — ER2 hands out unique IDs with an EVEN STRIDE (observed 262 apart),
--   so uid % 2 puts the whole force in one group (measured: control n=0) and uid % 6 only ever
--   yields {0,2,4}. 262/2 = 131 is ODD, so (uid // 2) alternates per soldier and distributes
--   evenly — always split/sample on math.floor(uid/2) % N (as DBG_SAMPLE does).

-- reuse-transport state: the vehicle this soldier last rode in as a passenger, and a
-- throttle for board attempts. Persist across ticks (per-soldier upvalues).
local myTransportId, lastBoardT = nil, -1000
-- hysteretic move order: avoids thrashing the pathfinder every tick
local lastDest, lastMoveT = nil, -1000
-- rout state: when the fallback moveTo was issued, the mission time at which the routing man
-- should go to ground in cover. Deferred to a LATER tick on purpose (findCover + moveTo in the
-- same tick cancel each other).
local routCoverAt = nil
-- Radioman stall tracking. stallPos holds a vec3, which is fine ONLY because it is a local
-- upvalue — a vec3 in a global is the fatal error that killed every brain at boot.
local stallPos, stallT, lastRadioT = nil, -1000, -1000
-- Wounded-drag state. dragBlack is keyed by casualty uid so one unreachable body cannot trap this
-- soldier in a retry loop for the whole battle.
local dragTarget, dragStartT, dragTries, dragBlack = nil, -1000, 0, {}
local function orderMove(dest, now)
    if not dest then return end
    if lastDest and distance(lastDest, dest) < MOVE_DEADBAND and (now - lastMoveT) < MOVE_REISSUE then
        return
    end
    lastDest, lastMoveT = dest, now
    safe(function() me.moveTo(dest) end)
end

-- hand movement back to base AI (used by the defer/hold branches)
local function releaseToBaseAI()
    aiSet("allowMovements", true)
    aiSet("allowFollowOrders", true)
end

-- ARMOUR IDENTIFICATION. This branch used to treat ANY friendly vehicle as armour, so a man
-- would "advance behind" a Kübelwagen or a towed AA gun. Vehicle.getName() is confirmed on this
-- build (probe 2026-08-29: getName() -> "Bofors 40mm L/60") and Vehicle has NO getClassName, so
-- the filter is a name match. ALLOW is tested FIRST so "Armoured car" / "Universal Carrier" are
-- not swallowed by the "car" deny token. A name in NEITHER list is NOT armour and is logged
-- ONCE so the lists can be tuned from real battle data.
-- (Deliberately NOT using getDamage(): it returns raw HP on vehicles — a healthy hull read 250 —
--  not the 0..100 soldier scale, so it cannot be thresholded like soldier health. isDestroyed()
--  is the honest wreck test.)
local ARMOUR_ALLOW = {
    "panzer","pzkpfw","pz.","tank","tiger","panther","stug","sturmgesch","jagd","hetzer","marder",
    "somua","hotchkiss","renault","char","fcm","amc ","amr ","matilda","valentine","churchill",
    "cromwell","crusader","cruiser","sherman","stuart","grant","m3 lee","chaffee","t-34","t34",
    "kv-","kv1","kv2","is-2","isu","su-","bt-","t-26","t26","chi-ha","ha-go",
    "sdkfz 251","sd.kfz. 251","sd.kfz 251","hanomag","universal carrier","bren carrier",
    "armoured car","armored car","puma","greyhound","daimler","humber","staghound",
}
local ARMOUR_DENY = {
    "truck","lorry","kubel","kübel","wagen","jeep","car","motorcycle","motorrad","bike","bicycle",
    "opel","blitz","horse","boat","raft","ferry","bofors","flak","pak","howitzer","artillery",
    "gun","cannon","mortar","ambulance","fuel","supply","tractor","trailer","plane","aircraft",
    "bomber","fighter","glider",
}
local armourSeen = {}   -- per-brain dedup so an unknown name never logs twice from one soldier
local function isArmour(v)
    local nm = tostring(safeGet(function() return v.getName() end) or ""):lower()
    if nm == "" then return false end
    for _, t in ipairs(ARMOUR_ALLOW) do if nm:find(t, 1, true) then return true end end
    for _, t in ipairs(ARMOUR_DENY)  do if nm:find(t, 1, true) then return false end end
    if not armourSeen[nm] then
        armourSeen[nm] = true
        -- one line per BATTLE, not per soldier: the guard is a BOOLEAN global under a STRING
        -- key (primitives only — a Vehicle/vec3 in a global is fatal on this build).
        local gk = "realistic_armour_unk_"..nm
        if not safeGet(function() return global.get(gk) end) then
            safe(function() global.set(true, gk) end)
            dbg("armour filter: unclassified '"..nm.."'")
        end
    end
    return false
end

-- advance on the covered side of the nearest FRIENDLY ARMOURED vehicle
-- FORWARD DECLARATION. rosterIndex() is defined further down but CALLED from
-- advanceBehindArmour below. Without this line Lua resolves the call as a GLOBAL read
-- (confirmed in the bytecode: GGET "rosterIndex"), which is nil at runtime, so the call
-- raises and silently kills that soldier's brain. Measured: ADVANCE-behind-armour fired
-- 367 times before the line-abreast change introduced the forward reference and 0 after.
local rosterIndex

local function advanceBehindArmour(pos, ec, now)
    if not USE_ARMOUR_COVER then return false end
    -- ATTACKERS ONLY. This ends in a moveTo, and defenders do not obey move orders — the base AI
    -- correctly wants them holding ground and it wins. MEASURED 2026-08-29, split by side:
    -- germany 0.65 m/s with 0% stationary, france 0.00 m/s and britain 0.05 m/s with 100%
    -- stationary. Issuing it to a defender produces a decision the engine ignores, which is
    -- worse than useless: it reads as a working feature in the log. Defenders fall through to
    -- FIGHT-from-cover, which is both obeyed and the historically correct behaviour.
    if not amInvader then return false end
    local vlist = {}
    if not safe(function() er2.getVehiclesInArea(pos, ARMOUR_SCAN, vlist) end) then return false end
    local bestPos, bestD = nil, 1e9
    for _, v in pairs(vlist) do
        if v then
            local vf = safeGet(function() return v.getFaction() end)
            if vf ~= nil and safeGet(function() return er2.isSameFaction(vf, myFaction) end) == true
               and safeGet(function() return v.isDestroyed() end) ~= true
               and safeGet(function() return v.isArtilleryVehicle() end) ~= true
               and isArmour(v) then
                local vp = safeGet(function() return v.getPosition() end)
                if vp then local d = distance(pos, vp); if d < bestD then bestPos, bestD = vp, d end end
            end
        end
    end
    if not bestPos then return false end
    local dest = bestPos
    if ec then
        -- Unit vector from the ENEMY to the tank: "behind the hull" is further along it.
        local dx, dz = bestPos.x - ec.x, bestPos.z - ec.z
        local mag = math.sqrt(dx * dx + dz * dz); if mag < 0.001 then dx, dz, mag = 1, 0, 1 end
        local ux, uz = dx / mag, dz / mag
        -- LINE ABREAST behind the hull, not a queue. Every man used to be sent to the SAME point
        -- ARMOUR_HUG behind the tank, so a squad stacked into a single file and only the leading
        -- man actually had the hull between himself and the enemy. Spacing them along the axis
        -- PERPENDICULAR to the enemy gives the Fury-style line: the whole section walks in the
        -- tank's shadow, each man with steel between him and the incoming fire.
        local px, pz = -uz, ux                     -- perpendicular to the enemy axis
        local idx, n = rosterIndex()
        local lateral = (idx - (n + 1) / 2) * ARMOUR_SPREAD
        dest = vec3(bestPos.x + ux * ARMOUR_HUG + px * lateral, bestPos.y,
                    bestPos.z + uz * ARMOUR_HUG + pz * lateral)
    end
    orderMove(dest, now)
    return true, bestD
end

-- fall back away from the enemy (or toward home). Returns true if an order was issued, so the
-- ROUT branch can arm the follow-up findCover for a LATER tick — a findCover here would be
-- countermanded by this very moveTo, which is why the "ends in cover" comment used to be a lie.
-- ANTI-TANK: acquire the nearest live enemy vehicle and engage it. Returns a decision label plus
-- the range, or nil when there is nothing to hunt (caller then falls through to the ordinary
-- cascade and the AT man fights as infantry, which is correct once the armour is dead).
--
-- Deliberately issues NO moveTo. `findCover` is the only relocation used, so this behaves
-- identically on the defending side, which provably ignores move orders — the same constraint
-- that forced ADVANCE-behind-armour and the ROUT fallback to become attacker-only.
local atTargetId, atForceFailed = nil, false
local function huntArmour(pos, now)
    local vlist = {}
    if not safe(function() er2.getVehiclesInArea(pos, AT_RANGE, vlist) end) then return nil end
    local best, bestD = nil, 1e9
    for _, v in pairs(vlist) do
        if v then
            local vf = safeGet(function() return v.getFaction() end)
            if vf ~= nil and safeGet(function() return er2.isSameFaction(vf, myFaction) end) == false
               and safeGet(function() return v.isDestroyed() end) ~= true then
                local vp = safeGet(function() return v.getPosition() end)
                if vp then local d = distance(pos, vp); if d < bestD then best, bestD = v, d end end
            end
        end
    end
    if not best then
        atTargetId = nil          -- nothing left to hunt; stop holding a stale forced target
        return nil
    end
    -- forceTarget is VERIFIED only against a SOLDIER (verified-api.md:189 `.forceTarget(enemySoldier)`
    -- [SDKFZ:37]); passing a Vehicle is unproven on this build. Guard it and degrade honestly to
    -- alert-only rather than reporting a capability we do not have. Logged once per brain.
    local id = safeGet(function() return best.getUniqueId() end)
    if id and id ~= atTargetId then
        atTargetId = id
        if not safe(function() me.forceTarget(best) end) and not atForceFailed then
            atForceFailed = true
            dbg("AT: forceTarget(vehicle) rejected — engaging via alert only")
        end
    end
    safe(function() me.alertFor(15) end)
    react("enemyTank", now)
    -- Outside effective range he closes by covered bounds; inside it he stops and shoots.
    takeCover(pos, now)
    return (bestD > AT_EFFECTIVE) and "AT-stalk" or "AT-hunt", bestD
end

-- BOUNDING OVERWATCH team assignment. Returns 0 or 1 — which half of the squad this man is in.
-- No messaging is required: every man derives the same answer from the same roster and the same
-- wall clock, so the halves alternate in step without any coordination.
--
-- This used to be a raw uid-parity proxy, adopted ONLY because squad rosters were believed
-- impossible on this build. The 2026-08-29 probe retracted that, so the real roster is used and
-- the proxy is now just the fallback for a soldier whose squad never resolves. The fallback must
-- stay floor(uid/2) % 2: ER2 unique-ids have an EVEN STRIDE of 262, so `uid % 2` is degenerate
-- and puts every man on the same team.
-- My index within my own squad roster, and the roster size. Used to space men out laterally so
-- they form a LINE rather than all converging on the same point behind a tank. Falls back to a
-- uid-derived index when the squad will not resolve (floor(uid/2), never uid % N - ER2 uids have
-- an even stride of 262).
function rosterIndex()   -- assigns the forward-declared local above
    if mySquad then
        local members = {}
        if safe(function() mySquad.getAllMembers(members) end) then
            local i, n, mine = 0, 0, nil
            for _, m in pairs(members) do
                i = i + 1; n = i
                if m and safeGet(function() return m.getUniqueId() end) == uid then mine = i end
            end
            if mine then return mine, n end
        end
    end
    return (math.floor(uid / 2) % 8) + 1, 8
end

local function boundTeam()
    local idx
    if mySquad then
        -- getAllMembers FILLS a caller-supplied table (verified-api.md: "getAllMembers(t)
        -- FILLED 2 members"), exactly like getSoldiersInArea. Calling it with no argument
        -- throws "Expected a table as 1st parameter" - 279 errors in one battle.
        local members = {}
        if safe(function() mySquad.getAllMembers(members) end) then
            local i = 0
            for _, m in pairs(members) do
                i = i + 1
                if m and safeGet(function() return m.getUniqueId() end) == uid then idx = i break end
            end
        end
    end
    return (idx or math.floor(uid / 2)) % 2
end

-- Elect exactly ONE man to fetch a casualty: the closest healthy member of his squad who is not
-- already carrying someone. Every member evaluates the same roster against the same casualty, so
-- exactly one of them gets the answer "me" — no globals, no messaging, no election protocol.
--
-- A soldier whose squad never resolved simply does not drag. The measured squad-bind rate is
-- 100%, so this costs almost nothing, and the alternative (a second area scan every tick to run
-- a proximity election) is a real per-tick cost for a rare event.
local function iAmNearestTo(pos, casP)
    if not mySquad then return false end
    -- FILLS the table; see the note in boundTeam(). Never call this with no argument.
    local members = {}
    if not safe(function() mySquad.getAllMembers(members) end) then return false end
    local myD = distance(pos, casP)
    for _, m in pairs(members) do
        if m then
            local muid = safeGet(function() return m.getUniqueId() end)
            if muid and muid ~= uid
               and safeGet(function() return m.isIncapacitated() end) ~= true
               and safeGet(function() return m.isAlive() end) ~= false
               and safeGet(function() return m.isCarryingBody() end) ~= true then
                local mp = safeGet(function() return m.getPosition() end)
                if mp and distance(mp, casP) < myD then return false end
            end
        end
    end
    return true
end

local function fallbackFrom(pos, ec, now)
    -- ATTACKERS ONLY, for the same reason as advanceBehindArmour: this ends in a moveTo and
    -- defenders will not obey it. MEASURED 2026-08-29: ROUT ran at 0.06-0.08 m/s with 100% of
    -- men stationary on the defending side. A defender who breaks therefore goes to ground where
    -- he stands (the caller's `else` yields ROUT-cover) rather than being handed a rearward
    -- rally point he will never walk to.
    if not amInvader then return false end
    local dest
    if ec then
        local dx, dz = pos.x - ec.x, pos.z - ec.z
        local mag = math.sqrt(dx * dx + dz * dz); if mag < 0.001 then dx, dz, mag = 1, 0, 1 end
        dest = vec3(pos.x + (dx / mag) * ROUT_FALLBACK, pos.y, pos.z + (dz / mag) * ROUT_FALLBACK)
    elseif homePos then
        dest = homePos
    else
        return false
    end
    orderMove(dest, now)   -- rearward rally point; cover follows on a later tick (never this one)
    return true
end

-- return to and re-board our remembered transport instead of abandoning it. Only called on a
-- safe, far-objective advance. Returns a decision label if it acted, else nil (walk on foot).
local function reuseTransport(pos, now)
    if not (REUSE_TRANSPORT and myTransportId and not isCrew) then return nil end
    -- A man carrying a wounded comrade does not go looking for a truck. This gate was documented
    -- as a suitability rule long before it could exist (feature 17 was unimplemented, so there
    -- was no such thing as "carrying"); now that the drag branch is real, the rule is real too.
    if safeGet(function() return me.isCarryingBody() end) == true then return nil end
    local veh = safeGet(function() return er2.findVehicle(myTransportId) end)
    if not veh then myTransportId = nil; return nil end          -- transport destroyed/gone -> forget it
    local vp = safeGet(function() return veh.getPosition() end)
    if not vp then return nil end
    local d = distance(pos, vp)
    if d > REBOARD_SCAN then return nil end                       -- too far to bother; march on foot
    if d > BOARD_ADJACENT then
        orderMove(vp, now)                                        -- walk back to the transport first
        return "RETURN-to-transport"
    end
    if (now - lastBoardT) >= BOARD_REISSUE then                   -- adjacent: board (throttled)
        lastBoardT = now
        safe(function() me.boardVehicle(veh) end)
    end
    return "REBOARD-transport"
end

--========================== MAIN LOOP =======================================
local errStreak  = 0
local lastHealth = 100      -- previous tick's health, to detect the "I've been hit" moment
local sawContact = false    -- first-contact latch for VOICE_ENUM.enemySpot
while true do
    -- exit guard: dead => stop; persistent isAlive() error => orphaned brain, stop.
    local aliveOk, alive = pcall(function() return me.isAlive() end)
    if aliveOk then
        if alive == false then break end
        errStreak = 0
    else
        errStreak = errStreak + 1
        if errStreak >= 5 then break end
    end

    local now = safeGet(function() return er2.time() end) or 0
    local pos = safeGet(function() return me.getPosition() end)

    if pos then
        local ne, nec, nf, ec, mgPos, casPos, ncas, casS = sense(pos)
        -- lazy squad: recovers the ~15% of soldiers whose squad was not ready at boot, and
        -- returns the current roster size (nil while unresolved).
        local sqNow = resolveSquad()
        local threatened = ne >= THREAT_ENEMIES
        -- PINNED: the engine's own suppression state is the primary trigger (polled, never
        -- subscribed); close-enemy proximity is only the secondary or-condition.
        local suppressed = safeGet(function() return me.isSuppressed() end) == true
        local pinned     = suppressed or (nec >= PINNED_ENEMIES)
        local edist      = ec and distance(pos, ec) or 1e9
        local inVehicle  = safeGet(function() return me.getCurrentVehicle() end) ~= nil
        -- hit path: any drop in health cries out (VOICE_ENUM.hit = iVeBeenHit) and marks the man
        -- as bloodied for morale. getHealth() is 0..100 on this build.
        local hp   = safeGet(function() return me.getHealth() end)
        local hurt = false
        if type(hp) == "number" then
            hurt = hp < (lastHealth - 0.5)
            lastHealth = hp
        end
        if hurt then react("hit", now) end
        -- first contact: the one place enemySpot belongs. Re-arms once contact is fully broken.
        if threatened and not sawContact then
            react("enemySpot", now); sawContact = true
        elseif ne == 0 then
            sawContact = false
        end
        -- morale = local force ratio (fixes false routs when a squad disperses to advance:
        -- with no enemies near, ratio = 1). Rout only when actually, locally outnumbered.
        local forceRatio = (nf + ne) > 0 and (nf / (nf + ne)) or 1.0
        -- ROUT: force ratio PLUS a casualty signal, never proximity. "Bloodied" = wounded
        -- himself, friends down around him, or a squad that has visibly lost men.
        local bloodied = (type(hp) == "number" and hp <= ROUT_HURT_HP)
                      or (ncas >= ROUT_CASUALTIES)
                      or (type(sqNow) == "number" and squadPeak > 0 and sqNow < squadPeak)
        local shaken   = (ne > 0) and (
                            (forceRatio < DOC.moraleFloor * ROUT_COLLAPSE)
                         or (forceRatio < DOC.moraleFloor and bloodied))
        -- ASSAULT is hoisted ABOVE pinned, but only for genuinely aggressive doctrines with
        -- healthy morale. No `not shaken` guard is needed — the ROUT branch above consumes
        -- every shaken man, so testing it here was tautological. Support weapons, medics and
        -- leaders are excluded: the gun IS the base of fire, and a leader never walks point.
        -- BOUNDING OVERWATCH eligibility. Attacker only (it ends in a moveTo), under threat, with
        -- morale intact. Excludes the men whose job is to BE the base of fire or to stay out of
        -- the firing line: MG, mortar, medic, leader and AT.
        local boundNow = threatened and amInvader and ec
                         and (not isMG) and (not isMortar) and (not isMedic)
                         and (not isLeader) and (not isAT)
                         and forceRatio >= DOC.moraleFloor

        -- RADIOMAN stall detection. Resetting the clock whenever he makes ground means the
        -- trigger is "the advance has stopped", not "he has been alive a while".
        local radioNow = false
        if isRadio then
            if (not stallPos) or distance(pos, stallPos) > STALL_DIST then
                stallPos, stallT = pos, now
            elseif (now - stallT) >= STALL_WINDOW and ne >= RADIO_MIN_ENEMIES
                   and (now - lastRadioT) >= RADIO_COOLDOWN and ec then
                radioNow = true
            end
        end

        -- ANTI-TANK acquisition, resolved before the cascade so its branch stays terminal.
        -- Scanned ONLY for AT men: an AT_RANGE getVehiclesInArea sweep every tick for every
        -- soldier would be a real per-tick cost for the ~3% of the battalion who are AT.
        local atLabel, atDist = nil, nil
        if isAT then atLabel, atDist = huntArmour(pos, now) end

        -- isAT is excluded too: an AT man is the battalion's only answer to armour, and the AT
        -- branch above already handled him whenever there was a vehicle to hunt. Letting him
        -- charge infantry spends the anti-tank capability on a job any rifleman can do.
        local assaultNow = threatened and (not isMG) and (not isMortar)
                           and (not isMedic) and (not isLeader) and (not isAT)
                           and edist <= DOC.assaultRange
                           and (DOC.aggression or 0) >= ASSAULT_MIN_AGGR
                           and forceRatio >= (DOC.moraleFloor + ASSAULT_MARGIN)
                           and math.random() < DOC.aggression
        -- MEDIC sortie: no enemy inside the close ring and the casualty within reach. Threat is
        -- NOT required (a medic works the field between contacts too).
        local casD       = casPos and distance(pos, casPos) or 1e9
        local medicSortie = isMedic and casPos and (nec == 0) and (casD <= MEDIC_REACH)

        -- WOUNDED DRAG. Medics HEAL; everyone else CARRIES. Excludes the base-of-fire roles and
        -- the leader. `nec == 0` keeps it out of a live firefight — dragging a man across beaten
        -- ground kills two soldiers instead of one. The approach leg needs a moveTo, so for a
        -- defender it is limited to a casualty already within arm's reach.
        local casUid  = casS and safeGet(function() return casS.getUniqueId() end) or nil
        local dragNow = false
        if casPos and casS and casUid and (nec == 0) and (casD <= DRAG_RADIUS)
           and (not isMedic) and (not isLeader) and (not isMG) and (not isMortar)
           and dragTries < CARRY_MAX_TRIES and not dragBlack[casUid]
           and (amInvader or casD <= CARRY_ADJACENT) then
            if safeGet(function() return me.isCarryingBody() end) == true then
                dragNow = true                       -- already carrying: finish the job
            elseif iAmNearestTo(pos, casPos) then
                dragTarget, dragNow = casUid, true
            end
        end

        --------- PRIORITY CASCADE (survival-first) ---------
        -- each branch sets `decision`(+`detail`); ONE comprehensive trace line is emitted below.
        -- Every branch is terminal, and no branch may be gated by a condition a higher branch
        -- has already consumed (that is what made ASSAULT, ROUT and MEDIC-sortie unreachable).
        local decision, detail = nil, ""
        if isCrew and not inVehicle then
            -- DISMOUNTED CREWMAN: his vehicle is gone (destroyed, disabled, or he was kicked out
            -- by the bail-out handler in the phase script). He used to stay in the branch below
            -- and defer to base AI forever, which is wrong twice over: he is no longer crewing
            -- anything, and a tank crew is NOT a rifle section — pistols and coveralls, no
            -- section weapons, and worth far more alive as replacement crew. So he breaks
            -- contact and goes to ground rather than joining the firing line.
            aiSet("enableAiBehaviour", true)
            aiSet("allowFindCoverWhenSuppressed", true)
            react("scared", now)
            takeCover(pos, now)
            decision, detail = "CREW-onfoot", (threatened and "under threat" or "vehicle lost")

        elseif inVehicle or isCrew then
            -- ANY non-infantry unit still with its vehicle (tank crew, plane pilot, gun crew,
            -- mounted infantry): this is an INFANTRY brain — never issue ground-move orders to a
            -- vehicle or aircraft. Defer fully to base AI; dismounted infantry (NOT crew, see the
            -- branch above) resume the full brain automatically once they get out.
            aiSet("enableAiBehaviour", true)
            releaseToBaseAI()
            aiSet("allowLeaveVehicle", true)   -- mounted infantry must be free to dismount and fight
            -- remember our transport (passengers only, not permanent vehicle crew) so we can
            -- return to it later instead of abandoning it.
            if inVehicle and not isCrew then
                myTransportId = safeGet(function() return me.getCurrentVehicle().getUniqueId() end) or myTransportId
            end
            decision = "MOUNTED/CREW-defer"
            detail = inVehicle and "in vehicle" or "crew class"

        elseif shaken then
            -- ROUT SITS ABOVE PINNED on purpose: a surrounded man breaks, he does not hug the
            -- deck. With pinned above it this branch never fired once in 10,731 decisions.
            react("fallback", now)
            if routCoverAt and now >= routCoverAt then
                routCoverAt = nil
                takeCover(pos, now)      -- LATER tick than the moveTo: the two cancel if paired
                decision, detail = "ROUT-cover", "gone to ground"
            elseif fallbackFrom(pos, ec, now) then
                routCoverAt = now + ROUT_COVER_DELAY
                decision, detail = "ROUT", "fr="..string.format("%.2f", forceRatio)
                    ..(bloodied and " bloodied" or " collapsing")
            else
                takeCover(pos, now)      -- nowhere to run to: go to ground where he stands
                decision, detail = "ROUT-cover", "no rally point"
            end

        elseif isAT and atLabel then
            -- ANTI-TANK, above ASSAULT so the AT man is never spent charging infantry while a
            -- vehicle is on the field. Falls through when there is nothing to hunt.
            decision, detail = atLabel, "veh d="..string.format("%.0f", atDist or 0)

        elseif assaultNow then
            react("charge", now)
            -- coverDiscipline: the per-doctrine probability that the bound is routed THROUGH
            -- cover instead of straight at the enemy centroid. This is the only lever that
            -- separates German fire-and-movement from a Soviet rush, so it must be read.
            -- findCover is a VOID COMMAND — issue it alone, never with a moveTo in the same tick.
            if ec and math.random() < (DOC.coverDiscipline or 0) then
                local dx, dz = ec.x - pos.x, ec.z - pos.z
                local mag = math.sqrt(dx * dx + dz * dz); if mag < 0.001 then dx, dz, mag = 1, 0, 1 end
                local step = math.min(ASSAULT_BOUND, edist)
                takeCover(vec3(pos.x + (dx / mag) * step, pos.y, pos.z + (dz / mag) * step), now)
                decision, detail = "ASSAULT-cover", "edist="..string.format("%.0f", edist)
            else
                orderMove(ec, now)       -- charge the enemy centroid directly
                decision, detail = "ASSAULT", "edist="..string.format("%.0f", edist)
            end

        elseif pinned then
            react("scared", now)         -- iVeBeenHit already fired above if he was just hit
            aiSet("allowFindCoverWhenSuppressed", true)
            takeCover(pos, now)          -- findCover is a command; it moves us into cover
            decision, detail = "PINNED", (suppressed and "suppressed" or ("nec="..tostring(nec)))

        elseif medicSortie then
            aiSet("allowDoMedic", true)  -- base AI performs the heal once adjacent
            orderMove(casPos, now)
            decision, detail = "MEDIC-sortie", "cas d="..string.format("%.0f", casD)

        elseif isMedic and threatened then
            takeCover(pos, now)
            decision, detail = "MEDIC-hold-cover", (casPos and "casualty out of reach/unsafe" or "no casualty")

        elseif dragNow then
            if safeGet(function() return me.isCarryingBody() end) == true then
                if (now - dragStartT) > DRAG_MAX_TIME then
                    -- HARD CEILING. There is no dropBody on this build, so stop() is the only
                    -- way to put a body down. Without this a single failed carry would pin a
                    -- soldier in place for the rest of the battle.
                    safe(function() me.stop() end)
                    dragTarget, dragTries = nil, dragTries + 1
                    decision, detail = "DRAG-abandon", "time ceiling"
                else
                    takeCover(pos, now)          -- carry him INTO cover, not just away
                    decision, detail = "DRAG-to-cover", "carrying"
                end
            elseif casD <= CARRY_ADJACENT then
                if safe(function() me.carryBody(casS) end) then
                    dragStartT = now
                    decision, detail = "DRAG-pickup", string.format("d=%.0f", casD)
                else
                    -- carryBody refused. Blacklist THIS casualty rather than retrying him every
                    -- tick, and count the attempt against the per-soldier cap.
                    dragBlack[casUid], dragTarget = true, nil
                    dragTries = dragTries + 1
                    decision, detail = "DRAG-abandon", "carryBody rejected"
                end
            else
                orderMove(casPos, now)
                decision, detail = "DRAG-approach", string.format("d=%.0f", casD)
            end

        elseif radioNow then
            -- Publish the request as FOUR INTEGERS. Never a vec3 — UserData in a global is the
            -- fatal error that killed every brain at boot. Write order matters: X, Z and side
            -- FIRST and the timestamp LAST, because the phase-side consumer treats RQ_T >= 0 as
            -- "a complete request is ready to read". Reversing that races a half-written request.
            safe(function()
                global.set(math.floor(ec.x), "RQ_X")
                global.set(math.floor(ec.z), "RQ_Z")
                global.set(amInvader and 1 or 2, "RQ_S")
                global.set(math.floor(now), "RQ_T")
            end)
            lastRadioT, stallT = now, now      -- one mission per stall, not one per tick
            react("covering", now)
            takeCover(pos, now)                -- he calls it in from cover, not standing up
            decision, detail = "RADIO-fire-mission",
                string.format("ne=%d target=(%.0f,%.0f)", ne, ec.x, ec.z)

        elseif isLeader and threatened then
            react("leader", now)
            takeCover(pos, now)
            decision = "LEADER-cover"

        elseif threatened then
            react("underFire", now)
            if isMG or isMortar then
                react("covering", now)
                takeCover(pos, now)
                decision = "SUPPORT-hold-fire"

            else
                -- (the assault test used to live here, where PINNED above it consumed every
                --  case it could fire on; it is now hoisted above PINNED as `assaultNow`.)
                local armoured, aD = advanceBehindArmour(pos, ec, now)
                if armoured then
                    decision, detail = "ADVANCE-behind-armour", "tank d="..string.format("%.0f", aD or 0)

                elseif boundNow then
                    -- BOUNDING OVERWATCH: the signature 1940 infantry tactic. One half of the
                    -- squad moves while the other half watches its ground and fires. Attacker
                    -- only — this ends in a moveTo and defenders ignore those.
                    local team  = boundTeam()
                    local phase = math.floor(now / BOUND_PERIOD) % 2
                    if team == phase then
                        if math.random() < (DOC.coverDiscipline or 0) then
                            -- coverDiscipline again: the same doctrine lever the assault uses.
                            -- A German squad bounds cover-to-cover; a low-discipline army just
                            -- gets up and goes.
                            takeCover(pos, now)
                            decision, detail = "BOUND-move-cover", "phase="..tostring(phase)
                        else
                            local dx, dz = ec.x - pos.x, ec.z - pos.z
                            local mag = math.sqrt(dx * dx + dz * dz)
                            if mag < 0.001 then dx, dz, mag = 1, 0, 1 end
                            orderMove(vec3(pos.x + (dx / mag) * BOUND_STEP, pos.y,
                                           pos.z + (dz / mag) * BOUND_STEP), now)
                            decision, detail = "BOUND-move", "phase="..tostring(phase)
                        end
                    else
                        takeCover(pos, now)
                        safe(function() me.alertFor(BOUND_PERIOD) end)
                        decision, detail = "BOUND-overwatch", "phase="..tostring(phase)
                    end

                else
                    -- MG cohesion deliberately does NOT live here any more; it moved to the
                    -- no-contact path. A man under fire will not walk to the gun, and issuing the
                    -- order anyway only produces a decision the engine ignores.
                    takeCover(pos, now)
                    decision = "FIGHT-from-cover"
                end
            end

        else
            --------- NO CONTACT ---------
            -- Only the ATTACKER approach-marches. Ordering DEFENDERS to march to the objective
            -- fights base AI (which correctly wants them holding ground): base AI wins because
            -- allowFollowOrders is true, and they stall on the spot. MEASURED in a live battle:
            -- 34 of 36 stationary "ROAD-MARCH" soldiers were the defending side, while attackers
            -- and mounted troops moved normally (median 389 m). Defenders now hold/garrison,
            -- which is both the correct order and free of the conflict.
            local obj = objectivePos(pos)
            if not amInvader then
                -- DEFENDERS NEVER MARCH. There used to be a DEFEND-move-up branch here that
                -- ordered a defender further than DEFEND_RADIUS from the objective to close on
                -- it. It never worked: MEASURED 2026-08-29 at 0.09 m/s with 100% of the men
                -- stationary over 2755 pooled seconds, French defenders only. Base AI holds
                -- ground and beats our move order every time, so the label was pure fiction in
                -- the log. Holding is also the historically correct behaviour for a defending
                -- battalion, so there is nothing to reclaim here — the branch is gone, not
                -- disabled. See realistic.md for the retired-feature note.
                local d = obj and distance(pos, obj) or 0
                releaseToBaseAI()                  -- let base AI pick defensive positions
                takeCover(pos, now)
                decision, detail = "DEFEND-hold", (obj and ("obj d="..string.format("%.0f", d)) or "")
            elseif obj and distance(pos, obj) <= ARRIVE_RADIUS then
                -- ARRIVED. He is standing on the objective, so there is nothing left to march to.
                -- Without this he keeps being ordered to a point he already occupies and keeps
                -- logging ROAD-MARCH while stationary. MEASURED 2026-08-29: six attackers marched
                -- 128-283 m and closed to 0-2 m of the objective, then sat there still labelled
                -- ROAD-MARCH, which dragged the pooled march speed down to 0.32 m/s and read as
                -- "not moving" — a real behaviour bug that the metric had made look like a
                -- measurement bug.
                -- Consolidating on a captured position (dig in, face the counter-attack) is also
                -- what the men should actually be doing, so this fixes the behaviour and the
                -- number together.
                releaseToBaseAI()
                takeCover(pos, now)
                decision, detail = "CONSOLIDATE",
                    "obj d="..string.format("%.0f", distance(pos, obj))

            else
                local far = obj and distance(pos, obj) > REBOARD_MIN_DIST
                local reused = far and reuseTransport(pos, now) or nil
                if reused then
                    decision = reused
                elseif DOC.mgCentric and mgPos and distance(pos, mgPos) > MG_COHESION then
                    -- Squad cohesion belongs to the APPROACH MARCH, not to the firefight. This
                    -- test used to sit in the `threatened` branch, where it was an order the
                    -- engine would not honour: MEASURED at 0.34 m/s across 21 soldiers with 57%
                    -- of them stationary, and dead in EVERY nation (germany 0.26 / britain 0.16 /
                    -- france 0.01), so it was not the defender/base-AI conflict — men under fire
                    -- simply go to ground instead of walking to the gun. A rifle squad closes up
                    -- on its Support gunner while still moving, which is what this now models.
                    orderMove(mgPos, now)
                    decision, detail = "RALLY-on-MG", "d="..string.format("%.0f", distance(pos, mgPos))
                elseif ROAD_FOLLOW and obj then
                    orderMove(roadStepToward(pos, obj), now)
                    decision, detail = "ROAD-MARCH", "obj d="..string.format("%.0f", distance(pos, obj))
                else
                    releaseToBaseAI()
                    decision, detail = "ADVANCE-baseAI", (obj and "" or "no objective visible")
                end
            end
        end

        -- COMPREHENSIVE per-tick trace: full sensed state + the action chosen from it.
        -- ed=-1 means "no enemy sensed". Under VERBOSE this logs every soldier every tick.
        -- t= is the mission clock. It is REQUIRED for honest verification: because these lines
        -- are throttled/sampled, consecutive lines for one soldier are NOT consecutive ticks,
        -- so speed can only be computed from real elapsed time (analyse_run.py relies on it).
        -- `decision` is only nil if the cascade somehow fell through (it cannot: the final
        -- branch is an unconditional else) — guarded anyway, because a nil throttle KEY would
        -- turn this into an unthrottled per-tick log line. There is no "IDLE" decision.
        if decision then
            dbg(string.format("t=%.1f %s/%s @(%.0f,%.0f) ne=%d nec=%d nf=%d ed=%.0f fr=%.2f -> %s%s",
                now, myNation, roleTag, pos.x, pos.z, ne, nec, nf,
                (edist >= 1e8 and -1 or edist), forceRatio, decision,
                (detail ~= "" and ("  | "..detail) or "")), decision, now)
        end
    end

    sleep(TICK)
end

dbg("OFFLINE #"..tostring(uid).." "..myNation.."/"..roleTag.." brain ending (dead or removed)")
