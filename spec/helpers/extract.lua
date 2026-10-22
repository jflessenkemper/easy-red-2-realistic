-- Pull named top-level definitions OUT of a mod script and compile them in a sandbox with a mocked
-- game API. The brain cannot simply be `require`d: it is a coroutine body that runs a whole soldier
-- on load. Extracting just the pure-logic functions (and the constants they close over) lets busted
-- exercise them directly, with no runtime, in milliseconds.
--
-- A definition is `local NAME = ...` or `local function NAME(...)` at column 0, running until the
-- next column-0 `end` / `}` (multi-line) or the same line (single-line). The source path can be
-- overridden with REALISTIC_SRC, which is how tools/mutate.py points the specs at a mutant.
local M = {}

local function readLines(path)
  local t = {}
  for l in io.lines(path) do t[#t + 1] = l end
  return t
end

local function block(lines, name)
  for i, l in ipairs(lines) do
    if l:match("^local function " .. name .. "%(") or l:match("^local " .. name .. "%s*=") then
      local opens = l:match("^local function") or l:match("=%s*{%s*$") or l:match("=%s*{[^}]*$")
      if not opens then return l end
      local out = { l }
      for j = i + 1, #lines do
        out[#out + 1] = lines[j]
        if lines[j]:match("^end") or lines[j]:match("^}") then return table.concat(out, "\n") end
      end
    end
  end
  error("extract: no top-level definition of '" .. name .. "'", 2)
end

-- names: ordered list (dependencies first). env: mock globals. upvalues: extra locals to predefine
-- (name -> value), e.g. rosterIndex. Returns a table name -> value.
function M.load(names, env, upvalues, src)
  src = src or os.getenv("REALISTIC_SRC") or "Realistic.lua"
  local lines = readLines(src)
  local chunks, pre = {}, {}
  upvalues = upvalues or {}
  for k in pairs(upvalues) do pre[#pre + 1] = "local " .. k .. " = __up." .. k end
  for _, n in ipairs(names) do chunks[#chunks + 1] = block(lines, n) end
  local ret = {}
  for _, n in ipairs(names) do ret[#ret + 1] = n .. "=" .. n end
  local code = table.concat(pre, "\n") .. "\n" .. table.concat(chunks, "\n") ..
               "\nreturn {" .. table.concat(ret, ",") .. "}"
  env = env or {}
  env.__up = upvalues
  setmetatable(env, { __index = _G })
  local fn = assert(loadstring(code, "=" .. src .. "[extract]"))
  setfenv(fn, env)
  return fn()
end

function M.vec3(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
function M.safeGet(f) local ok, v = pcall(f); if ok then return v end end
function M.safe(f) return (pcall(f)) end

return M
