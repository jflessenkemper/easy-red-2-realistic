-- Runs every tests/offline_*.lua harness present on the CURRENT branch under busted, so each
-- feature branch's own harness (offline_peek.lua, offline_morale.lua, ...) is reported per-file.
local function ls()
  local t, p = {}, io.popen("ls tests/offline_*.lua 2>/dev/null")
  for f in p:lines() do t[#t + 1] = f end
  p:close(); return t
end
describe("offline harnesses", function()
  for _, f in ipairs(ls()) do
    it(f, function()
      local p = io.popen("luajit " .. f .. " 2>&1; echo __rc=$?")
      local out = p:read("*a"); p:close()
      local rc = tonumber(out:match("__rc=(%d+)"))
      assert.equal(0, rc, out:sub(-1500))
    end)
  end
end)
