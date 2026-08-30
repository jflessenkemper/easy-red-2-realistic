-- Offline test harness for RealisticEvents.lua — runs the PHASE script's 1 s loop with no game.
--
-- WHY THIS EXISTS
-- The phase loop stops mid-session and two fixes aimed at it were both wrong. There is no `break`
-- left in it (every remaining one is inside an inner for), so a loop with no exit that stops is
-- DYING, not breaking. ER2 does not surface a coroutine death as a Lua error — proven by the
-- rosterIndex bug, which silently suppressed a whole feature — so the live log can never tell us
-- what threw. This harness drives the loop directly, so anything it throws is visible.
--
-- It also exercises the battle-boundary path that live testing is slow at: phase changes away,
-- battle_ended fires, phase comes back. That is where the loop was dying.
--
-- Usage:  luajit tests/offline_phase.lua        (exit 0 = pass)

local SRC = "RealisticEvents.lua"

-- Keep a handle on the REAL print: install() stubs _G.print to mute the phase script's
-- announce() (the on-screen kill feed), and that would otherwise silence this harness's own
-- output too - the first run produced exit 1 and not a single line.
local out = print

local function v3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end

local S            -- scenario
local lines = {}   -- everything the script logged
local STOP = "OFFLINE_PHASE_STOP"

local function mkSoldier(uid, faction, pos)
    return {
        getUniqueId = function() return uid end,
        getPosition = function() return pos or v3(0, 0, 0) end,
        getFaction  = function() return faction or "Germany_axis" end,
        getName     = function() return "S" .. uid end,
        getClassName= function() return "rifleman" end,
        isAlive     = function() return true end,
        isIncapacitated = function() return false end,
        isSquadLeader= function() return false end,
        isATSoldier = function() return false end,
        isMedic     = function() return false end,
        isRadioman  = function() return false end,
        isMarksman  = function() return false end,
        isFlameThrowerCarrier = function() return false end,
        isCarryingBody = function() return false end,
        getSquad    = function() return nil end,
        getCurrentVehicle = function() return nil end,
        setBrain    = function() end,
        say         = function() end,
        alertFor    = function() end,
        leaveVehicle= function() end,
    }
end

local function mkObjective(x, z)
    local attract = false
    return {
        getPosition  = function() return v3(x, 0, z) end,
        isAttractor  = function() return attract end,
        setAttractor = function(_, v) attract = v end,
        getName      = function() return "obj" end,
    }
end

local function install(scn)
    S = scn
    lines = {}
    _G.vec3 = v3
    _G.distance = function(a, b)
        if not a or not b then return 1e9 end
        local dx, dz = (a.x or 0) - (b.x or 0), (a.z or 0) - (b.z or 0)
        return math.sqrt(dx * dx + dz * dz)
    end
    _G.log   = function(m) lines[#lines + 1] = tostring(m) end
    _G.print = function() end
    _G.VoiceClip = setmetatable({}, { __index = function() return 0 end })
    _G.spawnSquad, _G.spawnSquad_script, _G.spawnMissionObjective = function() end, function() end, function() end
    local ticks = 0
    _G.sleep = function()
        ticks = ticks + 1
        S.onTick(ticks)                       -- the scenario drives the world forward
        if ticks >= S.ticks then error(STOP, 0) end
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
        isMasterClient      = function() return true end,
        time                = function() return 100 + (S.clock or 0) end,
        getCurrentPhaseId   = function() return S.phase end,
        getInvadersFaction  = function() return "Germany_axis" end,
        getDefendersFaction = function() return "France_allies" end,
        isSameFaction       = function(a, b) return a == b end,
        getPlayer           = function() return S.player end,
        getAllObjectives    = function(out)
            for i, o in ipairs(S.objectives or {}) do out[i] = o end
            return out
        end,
        getAllSoldiers      = function(out)
            for i, s in ipairs(S.soldiers or {}) do out[i] = s end
            return out
        end,
        getSoldiersInArea   = function(_, _, out)
            for i, s in ipairs(S.soldiers or {}) do out[i] = s end
            return out
        end,
        getVehiclesInArea   = function(_, _, out) return out end,
        countAliveInvaders  = function() return S.inv or 50 end,
        countAliveDefenders = function() return S.def or 50 end,
        getTerrainHeight    = function() return 0 end,
        explosion           = function() S.shells = (S.shells or 0) + 1 end,
        setCallback         = function(name, fn) S.callbacks[name] = fn end,
    }
end

local function run(scn)
    scn.globals   = scn.globals or {}
    scn.callbacks = {}
    scn.onTick    = scn.onTick or function() end
    install(scn)
    local src = assert(io.open(SRC)):read("*a"):gsub("local DEBUG%s*=%s*false", "local DEBUG = true", 1)
    local chunk, err = load(src, "@" .. SRC)
    if not chunk then return nil, "compile: " .. tostring(err) end
    local ok, e = pcall(chunk)
    if not ok and tostring(e):find(STOP, 1, true) == nil then
        return nil, tostring(e)
    end
    return lines
end

local function count(ls, pat)
    local n = 0
    for _, l in ipairs(ls) do if l:find(pat) then n = n + 1 end end
    return n
end

--========================= scenarios ========================================
local T, pass, fail = {}, 0, 0

-- 1. The loop runs at all and emits attraction lines.
T[#T + 1] = { name = "loop runs and manages objectives",
  run = function()
      local ls, err = run({
          phase = 0, ticks = 12,
          objectives = { mkObjective(0, 100) },
          soldiers = { mkSoldier(1, "Germany_axis", v3(0, 0, 100)) },
      })
      if err then return false, "ERROR: " .. err end
      local n = count(ls, "invAttract")
      return n > 0, n > 0 and "" or "no invAttract lines in " .. #ls .. " log lines"
  end }

-- 2. THE REGRESSION THAT MATTERS. Phase changes away (battle ends), battle_ended fires, then the
--    phase returns. The loop must idle and RESUME, not die. Two fixes for this were both wrong.
T[#T + 1] = { name = "survives a battle boundary and RESUMES",
  run = function()
      local scn
      scn = {
          phase = 0, ticks = 30,
          objectives = { mkObjective(0, 100) },
          soldiers = { mkSoldier(1, "Germany_axis", v3(0, 0, 100)) },
          onTick = function(t)
              if t == 8 then
                  scn.phase = 1                                  -- battle ends: phase moves on
                  local cb = scn.callbacks["battle_ended"]
                  if cb then pcall(cb) end                        -- and battle_ended fires
              elseif t == 18 then
                  scn.phase = 0                                  -- a new battle: our phase returns
              end
          end,
      }
      local ls, err = run(scn)
      if err then return false, "ERROR: " .. err end
      local idled   = count(ls, "idling")
      local resumed = count(ls, "RESUMED")
      -- attraction lines AFTER the resume are the real proof the loop is alive again
      local after, seenResume = 0, false
      for _, l in ipairs(ls) do
          if l:find("RESUMED") then seenResume = true
          elseif seenResume and l:find("invAttract") then after = after + 1 end
      end
      if idled == 0 then return false, "never idled when the phase changed away" end
      if resumed == 0 then return false, "idled but never RESUMED when the phase came back" end
      if after == 0 then return false, "resumed but produced no further attraction lines (loop is dead)" end
      return true, string.format("idled %d, resumed %d, %d attraction lines after resume",
                                 idled, resumed, after)
  end }

-- 3. The fire-mission consumer reacts to a request written the way the brain writes it.
--    Accept OR refuse both prove it is running; silence means it is not.
T[#T + 1] = { name = "fire-mission consumer reacts to an injected RQ_* request",
  run = function()
      local scn
      scn = {
          phase = 0, ticks = 20,
          objectives = { mkObjective(0, 100) },
          soldiers = { mkSoldier(1, "Germany_axis", v3(0, 0, 100)) },
          onTick = function(t)
              if t == 5 then      -- exactly what Realistic.lua's producer writes
                  scn.globals.RQ_X = 120
                  scn.globals.RQ_Z = 600
                  scn.globals.RQ_S = 1
                  scn.globals.RQ_T = 9999
              end
          end,
      }
      local ls, err = run(scn)
      if err then return false, "ERROR: " .. err end
      local reacted = count(ls, "RADIO%-fire%-mission")
      return reacted > 0, reacted > 0 and "consumer logged a decision"
             or "consumer NEVER responded to RQ_T>=0 (feature 19 cannot work)"
  end }

--========================= driver ===========================================
for _, t in ipairs(T) do
    local ok, why = t.run()
    if ok then
        out(string.format("  \27[32mPASS\27[0m  %s%s", t.name, why ~= "" and ("  (" .. why .. ")") or ""))
        pass = pass + 1
    else
        out(string.format("  \27[31mFAIL\27[0m  %s\n         %s", t.name, why))
        fail = fail + 1
    end
end
out(string.format("\n  offline phase: PASS %d  FAIL %d", pass, fail))
os.exit(fail == 0 and 0 or 1)
