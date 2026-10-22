-- Feature flags: every shipped on/off switch is a literal boolean at top level, and every
-- diagnostic flag ships false (mirrors check 6, but per-flag so a failure names the flag).
local function read(f) local h = assert(io.open(f)); local s = h:read("*a"); h:close(); return s end
local SRC = os.getenv("REALISTIC_SRC") or "Realistic.lua"
local B, P = read(SRC), read("RealisticEvents.lua")
local FEATURE = { ROAD_FOLLOW = "1 road march", USE_ARMOUR_COVER = "5 advance behind armour",
                  REUSE_TRANSPORT = "7 transport reuse" }
local DIAG_B = { "DEBUG", "VERBOSE" }
local DIAG_P = { "DEBUG", "TRACE_LOOP", "PROBE_GLOBALS", "PROBE_APIS", "WATCH", "TELEMETRY" }
describe("feature flags", function()
  for name, feat in pairs(FEATURE) do
    it(name .. " (" .. feat .. ") is a top-level boolean AND gates code", function()
      assert.truthy(B:match("\nlocal " .. name .. "%s*=%s*true") or B:match("\nlocal " .. name .. "%s*=%s*false"))
      local uses = select(2, B:gsub("%f[%w_]" .. name .. "%f[^%w_]", ""))
      assert.is_true(uses >= 2, name .. " declared but never read")
    end)
  end
  for _, n in ipairs(DIAG_B) do
    it("brain " .. n .. " ships false", function() assert.truthy(B:match("\nlocal " .. n .. "%s*=%s*false")) end)
  end
  for _, n in ipairs(DIAG_P) do
    it("phase " .. n .. " ships false", function() assert.truthy(P:match("\nlocal " .. n .. "%s*=%s*false")) end)
  end
end)
