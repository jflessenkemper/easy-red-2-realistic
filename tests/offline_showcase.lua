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
_G.spawnSquad = function() spawned.squads=spawned.squads+1 return {} end
_G.spawnVehicle = function() spawned.vehicles=spawned.vehicles+1 end
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
print(string.format("squads/vehicles %d/%d  objectives %d (attracting %d)",
      spawned.squads, spawned.vehicles, spawned.objectives, spawned.attracting))
print("layout errors: "..layouterr.."   refused to build: "..tostring(refused))
if layouterr > 0 or refused then os.exit(1) end
-- Only the stations that declare a real objective may attract. Stations 1, 11 and 12 do, and 12
-- adds a second - so four. Any more means a LABEL is attracting and will drag a neighbour's squad.
if spawned.attracting ~= 4 then
    print("FAIL expected exactly 4 attracting objectives, got " .. spawned.attracting)
    print("     a station LABEL is attracting; labels must pass attractor = false")
    os.exit(1)
end
if spawned.squads < 20 then
    print("FAIL only " .. spawned.squads .. " squads were spawned; the range is incomplete")
    os.exit(1)
end
print("LAYOUT OK  (" .. spawned.squads .. " squads, " .. spawned.attracting
      .. " attracting objectives, no station within sensing range of another)")
