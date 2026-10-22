-- Pure-logic specs for Realistic.lua master features. Example-based AND property-based: each
-- property draws random inputs from a fixed seed (reproducible) and asserts an invariant.
local X = require("spec.helpers.extract")
local vec3 = X.vec3
math.randomseed(tonumber(os.getenv("SPEC_SEED") or "20261023"))
local N = 300

local function roster(idx, n) return function() return idx, n end end

describe("feature 26 nationFromFaction", function()
  local F = X.load({ "NATION_TOKENS", "nationFromFaction" })
  it("maps real faction handles", function()
    assert.equal("germany", F.nationFromFaction("Germany_axis"))
    assert.equal("france", F.nationFromFaction("France_allies"))
    assert.equal("soviet", F.nationFromFaction("SovietUnion_allies"))
    assert.equal("britain", F.nationFromFaction("England_allies"))
    assert.equal("unitedstates", F.nationFromFaction("UnitedStates_allies"))
    assert.equal("hungary", F.nationFromFaction("Hungary_axis"))
  end)
  it("unknown / nil -> nil (DOCTRINE_DEFAULT fallback)", function()
    assert.is_nil(F.nationFromFaction(nil))
    assert.is_nil(F.nationFromFaction("Martians_axis"))
  end)
  it("property: never errors and only returns a known doctrine key or nil", function()
    local D = X.load({ "DOCTRINE" }).DOCTRINE
    for _ = 1, N do
      local s = {}
      for i = 1, math.random(0, 24) do s[i] = string.char(math.random(32, 126)) end
      local r = F.nationFromFaction(table.concat(s))
      assert.is_true(r == nil or D[r] ~= nil, tostring(r))
    end
  end)
end)

describe("feature 8 doctrine table", function()
  local T = X.load({ "DOCTRINE_DEFAULT", "DOCTRINE", "NATION_TOKENS" })
  it("property: every profile has all fields, probabilities in [0,1], ranges > 0", function()
    local all = { default = T.DOCTRINE_DEFAULT }
    for k, v in pairs(T.DOCTRINE) do all[k] = v end
    for k, d in pairs(all) do
      for _, f in ipairs({ "moraleFloor", "aggression", "coverDiscipline" }) do
        assert.is_number(d[f], k .. "." .. f)
        assert.is_true(d[f] >= 0 and d[f] <= 1, k .. "." .. f)
      end
      assert.is_true(d.assaultRange > 0, k)
      assert.is_boolean(d.mgCentric, k)
    end
  end)
  it("every nation token resolves to a profile that exists", function()
    for _, p in ipairs(T.NATION_TOKENS) do assert.is_table(T.DOCTRINE[p[2]], p[2]) end
  end)
end)

describe("feature 28 classMatches", function()
  local F = X.load({ "classMatches" })
  it("token and override semantics", function()
    assert.is_true(F.classMatches("support gunner", { "gunner" }))
    assert.is_false(F.classMatches("rifleman", { "gunner" }))
    assert.is_false(F.classMatches("", { "" }))
    assert.is_true(F.classMatches("maschinengewehr", { "gunner" }, "maschinen"))
    assert.is_false(F.classMatches("support gunner", { "gunner" }, "mortar"))
  end)
  it("empty override string falls back to tokens", function()
    assert.is_true(F.classMatches("support gunner", { "gunner" }, ""))
  end)
end)

describe("feature 1 segFlatness", function()
  it("flat ground = 0, slope = rise, no terrain = 1e9", function()
    local h = function(x) return x * 0.5 end
    local F = X.load({ "terrainY", "segFlatness" },
      { vec3 = vec3, er2 = { getTerrainHeight = function(p) return h(p.x) end } },
      { safeGet = X.safeGet })
    assert.near(10, F.segFlatness(0, 0, 20, 0), 1e-9)
    assert.near(0, F.segFlatness(0, 0, 0, 50), 1e-9)
    local G = X.load({ "terrainY", "segFlatness" },
      { vec3 = vec3, er2 = { getTerrainHeight = function() error("no terrain") end } },
      { safeGet = X.safeGet })
    assert.equal(1e9, G.segFlatness(0, 0, 10, 10))
  end)
  it("property: result is >= 0 and symmetric in direction", function()
    local F = X.load({ "terrainY", "segFlatness" },
      { vec3 = vec3, er2 = { getTerrainHeight = function(p) return math.sin(p.x * 0.1) * 3 + p.z * 0.02 end } },
      { safeGet = X.safeGet })
    for _ = 1, N do
      local a, b, c, d = math.random(-500, 500), math.random(-500, 500), math.random(-500, 500), math.random(-500, 500)
      local f = F.segFlatness(a, b, c, d)
      assert.is_true(f >= 0)
      assert.near(f, F.segFlatness(c, d, a, b), 1e-9)
    end
  end)
end)

describe("feature 4b staggerAcross", function()
  local function load(idx)
    return X.load({ "COLUMN_STAGGER", "staggerAcross" }, { vec3 = vec3 }, { rosterIndex = roster(idx, 8) })
  end
  it("even roster index goes to one verge, odd to the other, by exactly COLUMN_STAGGER", function()
    local a = load(2).staggerAcross(vec3(0, 0, 100), vec3(0, 0, 0))
    local b = load(3).staggerAcross(vec3(0, 0, 100), vec3(0, 0, 0))
    assert.near(-2.5, a.x, 1e-9); assert.near(2.5, b.x, 1e-9)
    assert.near(100, a.z, 1e-9)
  end)
  it("on top of the destination -> unchanged", function()
    local d = vec3(1, 2, 3)
    assert.equal(d, load(1).staggerAcross(d, vec3(1.2, 0, 3.1)))
  end)
  it("property: offset is perpendicular to the march axis with length COLUMN_STAGGER", function()
    for _ = 1, N do
      local F = load(math.random(1, 12))
      local p = vec3(math.random(-300, 300), 0, math.random(-300, 300))
      local d = vec3(p.x + math.random(-200, 200), 5, p.z + math.random(-200, 200))
      local ax, az = d.x - p.x, d.z - p.z
      if ax * ax + az * az >= 1 then
        local r = F.staggerAcross(d, p)
        local ox, oz = r.x - d.x, r.z - d.z
        assert.near(2.5, math.sqrt(ox * ox + oz * oz), 1e-6)
        assert.near(0, ox * ax + oz * az, 1e-6)
        assert.equal(5, r.y)
      end
    end
  end)
end)

describe("feature 9 ketteSlot", function()
  local function load(idx, n)
    return X.load({ "KETTE_INTERVAL", "KETTE_FRONT", "ketteSlot" }, { vec3 = vec3 }, { rosterIndex = roster(idx, n) })
  end
  it("front half to the right, rear half to the left, 4 m interval", function()
    local mg = vec3(0, 0, 0)
    assert.near(-4, load(1, 8).ketteSlot(mg, 0, 1, mg).x, 1e-9)   -- facing +z, right = -x
    assert.near(-16, load(4, 8).ketteSlot(mg, 0, 1, mg).x, 1e-9)
    assert.near(4, load(5, 8).ketteSlot(mg, 0, 1, mg).x, 1e-9)
  end)
  it("degenerate facing returns the gunner position", function()
    local mg = vec3(3, 0, 3)
    assert.equal(mg, load(1, 8).ketteSlot(mg, 0, 0, mg))
  end)
  it("property: slot lies on the line through the gunner, across the threat, within KETTE_FRONT/2", function()
    for _ = 1, N do
      local n = math.random(1, 30)
      local F = load(math.random(1, n), n)
      local mg = vec3(math.random(-100, 100), 1, math.random(-100, 100))
      local fx, fz = math.random(-10, 10), math.random(-10, 10)
      if fx ~= 0 or fz ~= 0 then
        local s = F.ketteSlot(mg, fx, fz, mg)
        local ox, oz = s.x - mg.x, s.z - mg.z
        assert.is_true(math.sqrt(ox * ox + oz * oz) <= 18 + 1e-9)
        assert.near(0, ox * fx + oz * fz, 1e-6)
      end
    end
  end)
end)

describe("feature 5 isArmour", function()
  local function load()
    return X.load({ "ARMOUR_ALLOW", "ARMOUR_DENY", "armourSeen", "isArmour" },
      { global = { get = function() return true end, set = function() end } },
      { safeGet = X.safeGet, safe = X.safe, dbg = function() end })
  end
  local function veh(n) return { getName = function() return n end } end
  it("classifies the real mission names (mirrors check 4g)", function()
    local F = load()
    assert.is_true(F.isArmour(veh("Panzer II Ausf. B")))
    assert.is_true(F.isArmour(veh("Sdkfz251 1939")))
    assert.is_true(F.isArmour(veh("Sdkfz222")))
    assert.is_false(F.isArmour(veh("Hotchkiss Stationary Ground")))
    assert.is_false(F.isArmour(veh("Opel Blitz")))
    assert.is_false(F.isArmour(veh("")))
    -- exclusion tokens at position 1 (kills find(...,2,...) mutants)
    assert.is_false(F.isArmour(veh("Stationary Panzer")))
    assert.is_false(F.isArmour(veh("Emplaced Panzer")))
    assert.is_false(F.isArmour(veh("Static Panzer")))
  end)
  it("property: any name containing 'stationary'/'emplac'/'static' is never armour", function()
    local F = load()
    for _ = 1, N do
      local w = ({ "Stationary", "emplacement", "STATIC" })[math.random(1, 3)]
      assert.is_false(F.isArmour(veh("Panzer IV " .. w .. " " .. math.random(1, 99))))
    end
  end)
  it("a throwing getName is not armour (pcall-safe)", function()
    assert.is_false(load().isArmour({ getName = function() error("NRE") end }))
  end)
end)

-- Added after the first mutation run (tools/mutate.py) exposed these unasserted behaviours.
describe("mutation-driven gaps", function()
  it("segFlatness samples along Z as well as X", function()
    local F = X.load({ "terrainY", "segFlatness" },
      { vec3 = vec3, er2 = { getTerrainHeight = function(p) return p.z end } }, { safeGet = X.safeGet })
    assert.near(40, F.segFlatness(0, 10, 0, 50), 1e-9)
    assert.near(40, F.segFlatness(7, 10, 7, 50), 1e-9)
  end)
  it("staggerAcross / ketteSlot pass through when either input is nil", function()
    local S = X.load({ "COLUMN_STAGGER", "staggerAcross" }, { vec3 = vec3 }, { rosterIndex = roster(1, 4) })
    local d = vec3(0, 0, 50)
    assert.equal(d, S.staggerAcross(d, nil))
    assert.is_nil(S.staggerAcross(nil, vec3()))
    local K = X.load({ "KETTE_INTERVAL", "KETTE_FRONT", "ketteSlot" }, { vec3 = vec3 }, { rosterIndex = roster(1, 4) })
    assert.equal(d, K.ketteSlot(d, 0, 1, nil))
  end)
  it("staggerAcross leaves a 1-2 m approach unchanged only below 1 m", function()
    local S = X.load({ "COLUMN_STAGGER", "staggerAcross" }, { vec3 = vec3 }, { rosterIndex = roster(1, 4) })
    local d = vec3(0, 0, 1.5)
    assert.are_not.equal(d, S.staggerAcross(d, vec3(0, 0, 0)))
  end)
  it("isArmour: an unclassified name is NOT armour and is logged once per battle", function()
    local sets, logs = 0, 0
    local store = {}
    local F = X.load({ "ARMOUR_ALLOW", "ARMOUR_DENY", "armourSeen", "isArmour" },
      { global = { get = function(k) return store[k] end, set = function(v, k) store[k] = v; sets = sets + 1 end } },
      { safeGet = X.safeGet, safe = X.safe, dbg = function() logs = logs + 1 end })
    local v = { getName = function() return "Zeppelin Mk IX" end }
    assert.is_false(F.isArmour(v)); assert.is_false(F.isArmour(v))
    assert.equal(1, sets); assert.equal(1, logs)
    -- a SECOND brain (fresh armourSeen) must see the battle-wide global guard and stay silent
    local G = X.load({ "ARMOUR_ALLOW", "ARMOUR_DENY", "armourSeen", "isArmour" },
      { global = { get = function(k) return store[k] end, set = function(v, k) store[k] = v; sets = sets + 1 end } },
      { safeGet = X.safeGet, safe = X.safe, dbg = function() logs = logs + 1 end })
    assert.is_false(G.isArmour(v)); assert.equal(1, logs)
  end)
end)
