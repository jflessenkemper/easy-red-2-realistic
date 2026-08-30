-- Offline test harness for Realistic.lua — runs the brain's decision cascade with NO game.
--
-- WHY THIS EXISTS
-- Every logic bug in this project has so far cost a ~15-minute battle to find, and several were
-- invisible even then because ER2 does not surface a brain-coroutine death as a Lua error: the
-- soldier simply stops thinking and the log stays clean. `rosterIndex()` was called 69 lines
-- above its definition, compiled to a global read, and silently suppressed ADVANCE-behind-armour
-- entirely — 367 fires before, 0 after, no error anywhere.
--
-- This stubs the whole ER2 runtime surface the brain touches (8 er2.* calls plus a dozen
-- globals), drives one soldier through a scenario, and asserts which decision came out. A bug
-- that kills the brain shows up here as an ERROR instead of as silence.
--
-- Usage:  luajit tests/offline_brain.lua
-- Exit 0 = all scenarios pass.

local SRC = (arg and arg[0] or ""):gsub("tests/offline_brain%.lua$", "") .. "Realistic.lua"
if SRC == "Realistic.lua" or SRC == "" then SRC = "Realistic.lua" end

--========================= stub runtime =====================================
local captured = {}          -- decision labels emitted this run
local STOP = "OFFLINE_HARNESS_STOP"

local function v3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end

-- scenario is filled in per test before the brain is loaded
local S

local function mkSoldier(t)
    t = t or {}
    local s = {}
    s.getUniqueId          = function() return t.uid or 1000 end
    s.getPosition          = function() return t.pos or v3(0, 0, 0) end
    s.getFaction           = function() return t.faction or "Germany_axis" end
    s.getName              = function() return t.name or "Hans Test" end
    s.getClassName         = function() return t.class or "rifleman" end
    s.getHealth            = function() return t.health or 100 end
    s.isAlive              = function() return t.alive ~= false end
    s.isIncapacitated      = function() return t.down == true end
    s.isSuppressed         = function() return t.suppressed == true end
    s.isSquadLeader        = function() return t.leader == true end
    s.isATSoldier          = function() return t.at == true end
    s.isMedic              = function() return t.medic == true end
    s.isRadioman           = function() return t.radio == true end
    s.isMarksman           = function() return t.marksman == true end
    s.isCarryingBody       = function() return t.carrying == true end
    s.getCurrentVehicle    = function() return t.vehicle end
    s.getSquad             = function() return t.squad end
    -- default TRUE: the brain polls this with sleep() during bootstrap, so a stub that
    -- never reports ready consumes the tick budget before the cascade ever runs.
    s.isSquadReady         = function() return t.squadReady ~= false end
    s.getAiParams          = function() return t.aiparams or {} end
    -- void commands: record, never fail
    s.moveTo   = function() t.moved = true end
    s.findCover= function() t.covered = true end
    s.stop     = function() end
    s.say      = function() end
    s.alertFor = function() end
    s.forceTarget = function() end
    s.carryBody   = function() return true end
    s.leaveVehicle= function() end
    s.boardVehicle= function() end
    s.setBrain    = function() end
    return s
end

local function mkSquad(members)
    return {
        getSquadSize   = function() return #members end,
        getAllMembers  = function(tbl)
            for i, m in ipairs(members) do tbl[i] = m end
            return tbl
        end,
        isPlayerInSquad = function() return false end,
    }
end

local function install(scn)
    S = scn
    captured = {}
    _G.myself   = function() return S.me end
    _G.vec3     = v3
    _G.distance = function(a, b)
        if not a or not b then return 1e9 end
        local dx, dz = (a.x or 0) - (b.x or 0), (a.z or 0) - (b.z or 0)
        return math.sqrt(dx * dx + dz * dz)
    end
    _G.log = function(m)
        local lab = tostring(m):match("%-> ([A-Za-z/%-]+)")
        if lab then captured[#captured + 1] = lab end
    end
    _G.sayMissionClip = function() end
    _G.VoiceClip = setmetatable({}, { __index = function() return 0 end })
    local ticks = 0
    _G.sleep = function()
        ticks = ticks + 1
        if ticks >= (S.ticks or 6) then error(STOP, 0) end
    end
    _G.global = {
        set = function(v, k)
            assert(type(v) == "number" or type(v) == "string" or type(v) == "boolean",
                   "UserData in a global! key=" .. tostring(k))
            S.globals[k] = v
        end,
        get = function(k) return S.globals[k] end,
    }
    _G.er2 = {
        time                = function() return S.clock or 100 end,
        getInvadersFaction  = function() return "Germany_axis" end,
        isSameFaction       = function(a, b) return a == b end,
        getNearestObjective = function()
            if not S.objective then return nil end
            return { getPosition = function() return S.objective end }
        end,
        getTerrainHeight    = function() return 0 end,
        getSoldiersInArea   = function(_, _, out)
            for i, s in ipairs(S.nearby or {}) do out[i] = s end
            return out
        end,
        getVehiclesInArea   = function(_, _, out)
            for i, v in ipairs(S.vehicles or {}) do out[i] = v end
            return out
        end,
        findVehicle         = function() return S.transport end,
    }
end

--========================= run one scenario =================================
local function run(scn)
    scn.globals = scn.globals or {}
    install(scn)
    -- Force DEBUG *and* VERBOSE on. DEBUG alone is not enough: per-tick traces are also
    -- SAMPLED (TRACED = floor(|uid|/2) % DBG_SAMPLE == 0) and throttled, so a test soldier whose
    -- uid happens not to be in the sample emits nothing and every scenario looks broken.
    -- VERBOSE bypasses both, which is what a deterministic test wants. Neither flag is written
    -- back to disk; the shipped file keeps both false.
    local src = assert(io.open(SRC)):read("*a")
        :gsub("local DEBUG%s*=%s*false", "local DEBUG = true", 1)
        :gsub("local VERBOSE%s*=%s*false", "local VERBOSE = true", 1)
    local chunk, err = load(src, "@" .. SRC)
    if not chunk then return nil, "compile: " .. tostring(err) end
    local ok, e = pcall(chunk)
    if not ok and tostring(e):find(STOP, 1, true) == nil then
        return nil, tostring(e)          -- a REAL error: exactly what we are hunting
    end
    return captured
end

--========================= scenarios ========================================
local function soldierAt(x, z, t)
    t = t or {}; t.pos = v3(x, 0, z); return mkSoldier(t)
end

-- A realistic body of friendlies. Without these a lone test soldier facing two enemies has a
-- force ratio far below moraleFloor, so ROUT correctly pre-empts every other branch and the
-- scenario tests nothing. The harness surfaced this immediately, which is the point of it.
local function friendlies(n, faction)
    local t = {}
    for i = 1, n do
        t[i] = soldierAt(i * 2, 0, { uid = 5000 + i * 2, faction = faction or "Germany_axis" })
    end
    return t
end

local function concat(...)
    local out = {}
    for _, list in ipairs({ ... }) do for _, v in ipairs(list) do out[#out + 1] = v end end
    return out
end

local TESTS = {
    { name = "attacker, no contact, objective far -> ROAD-MARCH",
      expect = "ROAD%-MARCH",
      build = function()
          local me = soldierAt(0, 0, { uid = 1000 })
          return { me = me, objective = v3(0, 0, 400), nearby = { me }, clock = 100 }
      end },

    { name = "defender, no contact -> DEFEND-hold",
      expect = "DEFEND%-hold",
      build = function()
          local me = soldierAt(0, 0, { uid = 1000, faction = "France_allies" })
          return { me = me, objective = v3(0, 0, 400), nearby = { me } }
      end },

    { name = "suppressed -> PINNED",
      expect = "PINNED",
      build = function()
          local me = soldierAt(0, 0, { uid = 1000, suppressed = true })
          local foe = soldierAt(10, 10, { uid = 2000, faction = "France_allies" })
          return { me = me, objective = v3(0, 0, 400),
                   nearby = concat({ me, foe }, friendlies(10)) }
      end },

    { name = "mounted -> MOUNTED/CREW-defer",
      expect = "MOUNTED/CREW%-defer",
      build = function()
          local veh = { getUniqueId = function() return 7 end,
                        getPosition = function() return v3(0, 0, 0) end }
          local me = soldierAt(0, 0, { uid = 1000, vehicle = veh })
          return { me = me, objective = v3(0, 0, 400), nearby = { me } }
      end },

    { name = "attacker standing on the objective -> CONSOLIDATE",
      expect = "CONSOLIDATE",
      build = function()
          local me = soldierAt(0, 0, { uid = 1000 })
          return { me = me, objective = v3(0, 0, 5), nearby = { me } }
      end },

    -- REGRESSION GUARD. advanceBehindArmour calls rosterIndex(); when that was a forward
    -- reference it compiled to a nil global and the call raised, silently killing the brain.
    -- This scenario drives that exact path, so the bug reappears here as an ERROR, not silence.
    { name = "threatened attacker with friendly armour -> ADVANCE-behind-armour (rosterIndex path)",
      expect = "ADVANCE%-behind%-armour",
      build = function()
          local me = soldierAt(0, 0, { uid = 1000, squad = nil })
          -- Enemies must be far enough out that neither ASSAULT (germany assaultRange 35 m)
          -- nor PINNED (>=2 enemies inside PINNED_RADIUS 50 m) pre-empts the armour branch,
          -- but close enough to count as threatened. 70 m satisfies all three.
          local foe1 = soldierAt(70, 0, { uid = 2000, faction = "France_allies" })
          local foe2 = soldierAt(72, 0, { uid = 2002, faction = "France_allies" })
          local tank = { getUniqueId = function() return 9 end,
                         getPosition = function() return v3(10, 0, 0) end,
                         getFaction  = function() return "Germany_axis" end,
                         getName     = function() return "Panzer II Ausf. B" end,
                         isDestroyed = function() return false end,
                         isArtilleryVehicle = function() return false end }
          return { me = me, objective = v3(0, 0, 400),
                   nearby = concat({ me, foe1, foe2 }, friendlies(12)),
                   vehicles = { tank }, ticks = 8 }
      end },
}

--========================= driver ===========================================
local pass, fail = 0, 0
for _, t in ipairs(TESTS) do
    local got, err = run(t.build())
    if err then
        print(string.format("  \27[31mFAIL\27[0m  %s\n         ERROR: %s", t.name, err))
        fail = fail + 1
    else
        local hit = false
        for _, lab in ipairs(got) do if lab:match(t.expect) then hit = true break end end
        if hit then
            print(string.format("  \27[32mPASS\27[0m  %s", t.name))
            pass = pass + 1
        else
            print(string.format("  \27[31mFAIL\27[0m  %s\n         expected %s, got: %s",
                  t.name, t.expect, #got > 0 and table.concat(got, ", ") or "(no decision)"))
            fail = fail + 1
        end
    end
end
print(string.format("\n  offline brain: PASS %d  FAIL %d", pass, fail))
os.exit(fail == 0 and 0 or 1)
