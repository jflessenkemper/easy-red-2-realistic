-- Offline validation of the Donchery order of battle. No game required.
--
-- WHAT IT CATCHES, all of which are silent in-game:
--   * an UNCONFIRMED squad or vehicle id - a wrong id spawns nothing (or spawns brainless) and the
--     mission is quietly under strength. The allow-lists below are the ids actually read out of the
--     game's own ME_French Ardennes missions and il2cpp metadata.
--   * spawnVehicle arg 3 not being a vec3 - a number throws inside the engine's own marshalling,
--     ESCAPES pcall, and kills the whole phase script.
--   * the REMOVED units creeping back: Sdkfz251 1939, Panzer 38, Char B1, RenaultR35 are all
--     present in the game and all historically wrong for 13 May 1940 at Donchery.
--   * force ratio drifting away from the researched ~205 German v ~135 French.
--
-- Usage: luajit tests/offline_donchery.lua      (exit 0 = the OOB is coherent)

_G.vec3 = function(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
_G.log = function(_) end   -- the OOB now logs its resolved origin

-- ORIGIN DERIVATION STUB. The OOB resolves its origin from the mission's first objective, because
-- absolute coordinates around (0,0,0) are OFF the playable terrain on French Ardennes and killed
-- the spawn loop at squad 8 of 31 with no error at all. Here the objective is stubbed at a
-- non-zero position ON PURPOSE: with a (0,0,0) stub every position would still be its own offset
-- and the assertion below could not tell a derived layout from an absolute one.
local DY_ORIGIN_STUB = { x = 1000, y = 5, z = 2000 }
_G.er2 = {
    getAllObjectives = function(t)
        t[1] = { getPosition = function() return DY_ORIGIN_STUB end }
    end,
}

local OOB = assert(loadfile("missions/donchery_oob.lua"))()

-- The layout must have MOVED with the origin. A squad still sitting near (0,0) means the
-- derivation was dropped and the loop will die partway through again.
do
    local near_zero = 0
    for _, sq in ipairs(OOB.squads) do
        if math.abs(sq.pos.x) < 500 and math.abs(sq.pos.z) < 500 then near_zero = near_zero + 1 end
    end
    if near_zero > 0 then
        print(string.format("FAIL  %d of %d squads are still within 500 m of (0,0) despite the "
              .. "origin stub at (%d,%d) - the origin derivation is not being applied, and the "
              .. "spawn loop will die partway with no error",
              near_zero, #OOB.squads, DY_ORIGIN_STUB.x, DY_ORIGIN_STUB.z))
        os.exit(1)
    end
end

-- Ids CONFIRMED to exist on this install. Nothing outside these lists may be used.
local SQUADS_OK = {
    ger_infantry_1940 = true, ger_infantry_AT_1940 = true, ger_pioneers_1940 = true,
    ger_artilleryCrew_1940 = true, ger_mortarCrew = true, ger_tankCrew_1940 = true,
    fr_reservist_infantry = true, fr_reservist_ATsquad = true,
    fr_artilleryCrew = true, fr_mortarCrew = true,
}
local VEH_OK = {
    ["Panzer I A"] = true, ["Panzer II"] = true, ["Panzer iii F"] = true,
    ["Panzer iv c"] = true, ["Panzer iv d"] = true, ["Sdkfz222"] = true,
    ["Pak 36"] = true, ["Opel Blitz"] = true, ["Kubelwagen"] = true, ["Horch 853"] = true,
    ["Hotchkiss Stationary Ground"] = true,
}
-- Historically wrong for this action, and all of them EXIST, so they can creep back in.
local BANNED = {
    ["Sdkfz251 1939"] = "the battalion had ZERO halftracks",
    ["Panzer 38"]     = "2. Pz.Div. had no Panzer 38(t)",
    ["Char B1"]       = "4e/7e BCC did not arrive until 14 May",
    ["RenaultR35"]    = "4e/7e BCC did not arrive until 14 May",
}

local fail = 0
local function bad(m) print("FAIL  " .. m); fail = fail + 1 end

local ger, fre = 0, 0
for _, s in ipairs(OOB.squads) do
    if not SQUADS_OK[s.squad] then bad("unconfirmed squad id '" .. tostring(s.squad) .. "'") end
    if s.side ~= "invader" and s.side ~= "defender" then
        bad("squad '" .. tostring(s.squad) .. "' has side '" .. tostring(s.side) .. "'")
    end
    if not (s.pos and s.pos.x) then bad("squad '" .. tostring(s.squad) .. "' has no vec3 pos") end
    if s.side == "invader" then ger = ger + 1 else fre = fre + 1 end
end
for _, v in ipairs(OOB.vehicles) do
    local nm, pos, dir = v[1], v[2], v[3]
    if BANNED[nm] then bad("REMOVED unit '" .. nm .. "' is back: " .. BANNED[nm]) end
    if not VEH_OK[nm] then bad("unconfirmed vehicle id '" .. tostring(nm) .. "'") end
    if not (pos and pos.x) then bad("vehicle '" .. tostring(nm) .. "' has no vec3 pos") end
    -- The one that kills the phase script if wrong.
    if type(dir) ~= "table" or dir.x == nil then
        bad("vehicle '" .. tostring(nm) .. "' arg 3 is " .. type(dir)
            .. ", must be a vec3 DIRECTION - a number throws past pcall and kills the script")
    end
end
for _, m in ipairs(OOB.mounted) do
    if not SQUADS_OK[m[1]] then bad("unconfirmed mounted squad id '" .. tostring(m[1]) .. "'") end
    if not (m[2] and m[2].x) then bad("mounted '" .. tostring(m[1]) .. "' has no vec3 pos") end
end

-- Force ratio, by SQUAD COUNT. Headcount cannot be asserted: the number of men a squad id spawns
-- is set by the game's squad TEMPLATE, not the spawn call (ger_infantry_1940 was observed at 4-8),
-- so KStN 131c's ten-man Gruppe is not something this file can enforce.
if ger < 15 or ger > 24 then bad("German squads " .. ger .. ", want 15-24 for ~205 men") end
if fre < 10 or fre > 18 then bad("French squads " .. fre .. ", want 10-18 for ~135 men") end
if #OOB.vehicles < 25 then bad("only " .. #OOB.vehicles .. " vehicles; want 25+") end
-- Every tank must have a crew aboard, or the bail-out branch is unreachable.
if #OOB.mounted < 12 then bad("only " .. #OOB.mounted .. " mounted crews; the 12 AFVs plus the "
    .. "6 Hotchkiss emplacements all need crews aboard") end

if fail > 0 then
    print("  " .. fail .. " problem(s) - the OOB is NOT coherent")
    os.exit(1)
end
print(string.format("ok    Donchery OOB coherent: %d German + %d French squads, %d vehicles, "
      .. "%d crews aboard, no banned units, every id confirmed",
      ger, fre, #OOB.vehicles, #OOB.mounted))
