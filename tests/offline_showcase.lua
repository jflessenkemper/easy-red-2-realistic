-- Offline check of the SHOWCASE RANGE's layout. Stubs just enough of the runtime to run the
-- top-level build, then asserts the range is coherent without launching the game.
--
-- The bug this exists to catch is silent and ruins the demo rather than crashing it: a station's
-- enemies drifting within SENSE_RADIUS of a NEIGHBOUR's centre, so that neighbour's squad counts
-- them in its force ratio and takes a completely different cascade branch. The station then
-- demonstrates the wrong feature and it reads as an AI bug. It happened for real at the original
-- 300 m spacing - station 9's enemies landed exactly ON station 10's centre.
--
-- Also asserts that only the REAL objectives attract. An attracting label would pull neighbouring
-- squads out of position, which is the same class of failure by a different route.
--
-- Usage:  luajit tests/offline_showcase.lua      (exit 0 = the range is coherent)
local spawned = { squads = 0, vehicles = 0, objectives = 0, attracting = 0 }
local logs = {}
_G.vec3 = function(x,y,z) return {x=x or 0,y=y or 0,z=z or 0} end
_G.distance = function(a,b) local dx,dz=a.x-b.x,a.z-b.z return math.sqrt(dx*dx+dz*dz) end
_G.log = function(m) logs[#logs+1]=tostring(m) end
_G.sleep = function() error("STOPHUD",0) end
_G.global = { get=function() return nil end, set=function() end }
_G.spawnSquad_script = function() spawned.squads=spawned.squads+1 return {} end
-- The mounted variant. Without this stub the script silently took its dismounted FALLBACK and the
-- test would pass while station 11's transport branch stayed unreachable in-game.
_G.spawnSquadOnVehicle_script = function() spawned.mounted=(spawned.mounted or 0)+1 return {} end
_G.spawnSquad = function() spawned.squads=spawned.squads+1 return {} end
-- TYPE-CHECKS arg 3. The engine wants userdata (a vec3); passing a number throws inside its own
-- argument marshalling, ESCAPES pcall, and kills the phase script - the range built one station
-- and stopped. A stub that accepted anything is what let that reach the game.
_G.spawnVehicle = function(id, pos, rot)
    if type(rot) ~= "table" or rot.x == nil then
        error("spawnVehicle arg 3 must be a vec3 direction (userdata in-engine), got "
              .. type(rot) .. " -- this KILLS the phase script and pcall cannot catch it", 0)
    end
    spawned.vehicles = spawned.vehicles + 1
end
_G.spawnMissionObjective = function(pos,r,txt,icon,attract)
    spawned.objectives=spawned.objectives+1
    if attract then spawned.attracting=spawned.attracting+1 end
    return {}
end
_G.er2 = {
    isMasterClient=function() return true end,
    getCurrentPhaseId=function() return 0 end,
    getInvadersFaction=function() return "Germany_axis" end,
    getDefendersFaction=function() return "France_allies" end,
    time=function() return 100 end,
    getPlayer=function() return nil end,
    getSoldiersInArea=function(_,_,o) return o end,
    -- Return a vehicle so the MOUNTED path is exercised, not the dismounted fallback.
    getVehiclesInArea=function(_,_,o) o[1] = { getName=function() return "Opel Blitz" end } return o end,
    -- FILL-style: must be called WITH a table. Returning one objective exercises the derived-origin
    -- path, which is the default; an empty table would only ever test the fallback.
    getAllObjectives=function(t)
        t[1] = { getPosition = function() return {x=1000,y=0,z=-500} end }
        return t
    end,
}
local fn = assert(loadfile("missions/scenarios/showcase.lua"))
local ok, err = pcall(fn)
if not ok and not tostring(err):find("STOPHUD") then print("ERROR: "..tostring(err)) os.exit(1) end
local refused, layouterr = false, 0
for _,l in ipairs(logs) do
  if l:find("REFUSING") then refused = true end
  if l:find("LAYOUT ERROR") then layouterr = layouterr + 1 print("  "..l) end
end
print(string.format("squads/vehicles %d/%d  mounted %d  objectives %d (attracting %d)",
      spawned.squads, spawned.vehicles, spawned.mounted or 0, spawned.objectives,
      spawned.attracting))
-- Station 11 MUST spawn its squad mounted; the fallback logs a warning and leaves the branch dead.
if (spawned.mounted or 0) < 1 then
    print("FAIL no squad was spawned mounted - transport reuse (station 11) cannot fire")
    os.exit(1)
end
print("layout errors: "..layouterr.."   refused to build: "..tostring(refused))
if layouterr > 0 or refused then os.exit(1) end
-- EXACTLY TWO attracting objectives: station 12's pair, which is the only station that exists to
-- demonstrate objective flow. Every station now gets its own objective as a march target, but an
-- ATTRACTOR steers base AI map-wide, so any extra one drags other stations' squads across the
-- range. That collapse was measured for real - only 1-3 of 13 stations demonstrated anything - so
-- this number going up is a regression, not a tweak.
if spawned.attracting ~= 2 then
    print("FAIL expected exactly 2 attracting objectives (station 12's pair), got "
          .. spawned.attracting)
    print("     an extra attractor steers base AI map-wide and empties other stations")
    os.exit(1)
end
-- One objective per station is what keeps each squad local (13 stations + station 12's second).
-- Fewer means some squad has no local march target and will walk off the range.
if spawned.objectives < 13 then
    print("FAIL only " .. spawned.objectives .. " objectives; every station needs its own or its "
          .. "squad marches to a distant one and leaves the station")
    os.exit(1)
end
-- Assert ZERO spawn failures. The script guards every spawn with pcall, so a bad argument is
-- swallowed offline and only shows up as a logged FAILED line - which is exactly how a numeric
-- spawnVehicle rotation reached the game and killed the phase script. Counting the log lines is
-- the signal; the pcall means an exception never reaches this test.
local spawnfails = 0
for _, l in ipairs(logs) do
    if l:find("FAILED to spawn") or l:find("WARNING squad") then
        spawnfails = spawnfails + 1
        print("  " .. l)
    end
end
if spawnfails > 0 then
    print("FAIL " .. spawnfails .. " spawn failure(s); every id and argument type must be valid")
    os.exit(1)
end
if spawned.squads < 20 then
    print("FAIL only " .. spawned.squads .. " squads were spawned; the range is incomplete")
    os.exit(1)
end
print("LAYOUT OK  (" .. spawned.squads .. " squads, " .. spawned.attracting
      .. " attracting objectives, no station within sensing range of another)")
