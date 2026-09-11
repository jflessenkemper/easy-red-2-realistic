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
            -- S.actors is for the diorama scenarios: the cycle queries an area per STATION, and a
            -- stub that answers every query with the same cast is enough to exercise heal, reset
            -- and the scripted casualty without modelling 13 station positions.
            for i, s in ipairs(S.actors or S.soldiers or {}) do out[i] = s end
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
    -- A scenario can ask for the DIORAMA build. tools/deploy.py flips this exact line for the test
    -- map, so testing the flipped shape is testing what actually ships there. Without this the
    -- whole diorama - heal, reset, casualty, signage - is dead code in every offline run, which is
    -- precisely how a casualty that never fired got shipped and then measured in-game three times.
    if scn.diorama then
        src = src:gsub("on%s*=%s*false", "on     = true", 1)
    end
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
-- THE RESET WINDOW MUST COVER THE WALK HOME. There is no teleport for soldiers, so a reset is a
-- MARCH: at roughly 3 m/s a 30 s window moved a man only ~90 m, while the station radius is 160 m
-- and each station's objective sits 180 m out. Measured in-game: 20 of 113 soldiers ended beyond
-- 220 m of their nearest station, one at 658 m. The window expired long before anyone got back, so
-- the next round began from wherever they stood and the drift ACCUMULATED every cycle. Both
-- numbers are read out of the source, so tuning one without the other cannot pass.
do
    local src = assert(io.open("RealisticEvents.lua")):read("*a")
    -- SCOPED TO THE CYC TABLE. A bare `radius%s*=%s*(%d+)` matched `radius = 10` from the
    -- inlined station data hundreds of lines earlier, so this compared 90 m against 10 m and
    -- passed while the real window was far too short. That is a test that cannot fail, and it is
    -- the eleventh found on this project - the file now contains two inlined data sets, so any
    -- unanchored pattern is a trap.
    local cyc = src:match("local CYC = %{(.-)\n%}")
    if not cyc then
        out("  \27[31mFAIL\27[0m  could not find the `local CYC = { ... }` table in " .. SRC)
        os.exit(1)
    end
    local reset  = tonumber(cyc:match("reset%s*=%s*(%d+)"))
    local radius = tonumber(cyc:match("radius%s*=%s*(%d+)"))
    local SPEED  = 3.0
    if not reset or not radius then
        out("  \27[31mFAIL\27[0m  could not read CYC.reset / CYC.radius out of " .. SRC)
        os.exit(1)
    end
    if reset * SPEED < radius then
        out(string.format("  \27[31mFAIL\27[0m  diorama reset window is %ds -> covers only %.0f m "
            .. "at %.1f m/s, less than the %dm station radius. Actors cannot reach their marks "
            .. "before the next round, so drift accumulates instead of clearing.",
            reset, reset * SPEED, SPEED, radius))
        os.exit(1)
    end
    out(string.format("  \27[32mPASS\27[0m  diorama reset window %ds covers %.0fm >= station "
        .. "radius %dm", reset, reset * SPEED, radius))
end

-- THE DIORAMA MUST ACTUALLY DO ITS THREE JOBS. Measured in-game over three rounds: the cycle
-- announced every transition correctly and yet produced ZERO scripted casualties, so station 8 had
-- nobody for the medic to treat and MEDIC/DRAG could never appear. The announcements made it look
-- healthy. Nothing in the log said which guard inside CYC.hurt was rejecting every soldier, and
-- three in-game runs at ~15 minutes each could not tell me either - so it is asserted here, where
-- a stub can record exactly which calls were made.
local function mkActor(uid, faction, pos)
    local a = { _uid = uid, _fac = faction, _pos = pos, _inc = 0, _heal = 0,
                _moved = nil, _moves = 0 }
    a.getUniqueId = function() return a._uid end
    a.getFaction = function() return a._fac end
    a.isAlive = function() return true end
    a.getPosition = function() return a._pos end
    a.incapacitate = function() a._inc = a._inc + 1 end
    a.stopIncapacitate = function() end
    a.healSoldier = function() a._heal = a._heal + 1 end
    a.moveTo = function(p) a._moved = p; a._moves = (a._moves or 0) + 1 end
    a.isOnCover = function() return false end
    a.isMoving = false
    a.getSuppressionValue = function() return 0 end
    return a
end

local T, pass, fail = {}, 0, 0

T[#T + 1] = { name = "diorama: heals, resets and puts a man down at the casualty station",
  run = function()
      -- Actors are returned for EVERY area query, so whichever station the cycle inspects sees
      -- them. Both sides are present because the casualty must come from the INVADERS: the medic
      -- and the stretcher party are on the casualty's own side.
      local ger1 = mkActor(101, "Germany_axis", v3(0, 0, 0))
      local ger2 = mkActor(102, "Germany_axis", v3(10, 0, 0))
      -- NIL ALIVENESS IS THE REAL CASE, not an edge case. safeGet returns nil whenever the interop
      -- call fails, and the whole codebase treats `~= false` as alive for that reason. A bare
      -- truthiness test in CYC.hurt/CYC.sign rejected every such soldier, which is why the
      -- scripted casualty never fired in THREE in-game runs and the station signs counted zero
      -- men. This actor reproduces it: he must still be healed, counted and eligible.
      ger1.isAlive = function() return nil end
      ger2.isAlive = function() return nil end
      local fr1  = mkActor(201, "France_allies", v3(60, 0, 0))
      -- `diorama = true` makes run() deploy the flipped build, exactly as tools/deploy.py does for
      -- the test map. ticks must exceed act(90) + reset(75) so a full cycle completes and the
      -- reset -> act transition that creates the casualty actually happens.
      -- THE HARNESS CLOCK ONLY MOVES IF THE SCENARIO MOVES IT: time() is `100 + (S.clock or 0)`
      -- and S.clock is never touched unless onTick sets it. So every time-based feature was
      -- untestable here by construction - the diorama's act/reset transitions could never fire,
      -- which is why this scenario failed for a reason that had nothing to do with the code under
      -- test. One tick = one second, matching the loop's own sleep(1).
      local scn = {
          phase = 0, ticks = 200, diorama = true,
          objectives = { mkObjective(0, 100) },
          actors = { ger1, ger2, fr1 },
      }
      scn.onTick = function(n) scn.clock = n end
      local ls, err = run(scn)
      if err then return false, "ERROR: " .. err end

      local healed = ger1._heal + ger2._heal + fr1._heal
      -- NOTE: doHeal does not consult isAlive at all, so a heal-based assertion proved nothing
      -- here - my first attempt at this test passed with the bug reintroduced. The aliveness guard
      -- lives in CYC.hurt, so BOTH invaders must be the nil-aliveness case for `down` below to
      -- discriminate.
      local down   = ger1._inc + ger2._inc
      if healed == 0 then
          return false, "the heal tick never ran - the cast would die off and the exhibit empties"
      end
      if down == 0 then
          return false, "CYC.hurt never incapacitated an invader, so the casualty station has "
                .. "nobody for the medic to treat. This is the in-game failure reproduced: three "
                .. "rounds ran, every transition was announced, and zero casualties were created."
      end
      if fr1._inc > 0 then
          return false, "a DEFENDER was incapacitated; the medic and the dragger are on the "
                .. "attacker's side, so the casualty has to be an invader"
      end
      -- AND THE RESET MUST ACTUALLY ORDER PEOPLE HOME. In-game the drift was unchanged after
      -- raising the window (median 61 m, max 663 m, 16 of 108 beyond 220 m), which points at the
      -- reset issuing no orders at all rather than at the window being too short. If nobody is
      -- ordered home then at the start of each act phase the station centre is empty - which also
      -- explains why the casualty never fired in-game while working here.
      local moved = 0
      for _, a in ipairs({ ger1, ger2, fr1 }) do
          if a._moved then moved = moved + 1 end
      end
      if moved == 0 then
          return false, "CYC.doReset issued NO moveTo at all, so nobody is ever ordered back to "
                .. "their mark and the drift can only accumulate"
      end
      -- ONCE IS NOT ENOUGH, and this is the assertion that matters. The brain re-issues its own
      -- moveTo every MOVE_REISSUE seconds, so a single order per 75-second reset is overridden
      -- within two seconds and everyone marches off again - which is exactly what the in-game
      -- drift showed while this test was happily reporting "3/3 ordered home". The reset has to
      -- compete on FREQUENCY, so count the orders, not just their existence.
      -- THRESHOLD MEASURED, NOT GUESSED. With the reset re-issued every tick this scenario logs
      -- 912 move orders to ger1; with the one-shot reset it logs 12. A threshold of 5 - my first
      -- guess - passed BOTH and was therefore another test that could not fail. 40 sits clearly
      -- between the two, so it separates "competing with the brain every tick" from "ordering
      -- once and being overridden".
      if ger1._moves < 40 then
          return false, string.format("the reset issued only %d moveTo for a %ds window - the "
                .. "brain re-issues its own order every couple of seconds and will override a "
                .. "one-shot reset, leaving the cast wherever it was (expect ~900 when the reset "
                .. "re-issues per tick, ~12 when it does not)", ger1._moves, 75)
      end
      return true, string.format("healed %d times, %d invader(s) put down, no defender touched, "
                                 .. "%d/3 ordered home, %d move orders to ger1",
                                 healed, down, moved, ger1._moves)
  end }

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
