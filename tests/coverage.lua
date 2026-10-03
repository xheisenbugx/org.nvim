-- Line coverage of lua/org for `make coverage`, without luacov: a line
-- hook counts the lines of lua/org/**/*.lua that run, and each Neovim of
-- the test run writes its counts to $ORG_COVERAGE_DIR/<pid>.json when it
-- finishes. scripts/coverage_report.lua merges them into a report.
--
-- Only loaded when ORG_COVERAGE_DIR is set (tests/minimal_init.lua), so
-- `make test` and plugin users never pay for it. JIT-compiled code calls no
-- hooks, so the JIT is off while it runs.
local M = {}

local hits = {} -- source ("@/abs/path/lua/org/x.lua") -> { [line] = count }
local wanted = {} -- source -> its hits table, or false (not ours)
local dir

local getinfo = debug.getinfo

local function hook(_, line)
  local src = getinfo(2, "S").source
  local t = wanted[src]
  if t == nil then
    -- org's own modules only: not the specs, Neovim's runtime or a
    -- fixture's Lua block
    t = src:match("[/\\]lua[/\\]org[/\\].+%.lua$") and {} or false
    wanted[src] = t
    if t then
      hits[src] = t
    end
  end
  if t then
    t[line] = (t[line] or 0) + 1
  end
end

--- Start counting (once per Neovim).
function M.start(out_dir)
  if dir then
    return
  end
  dir = out_dir
  vim.fn.mkdir(dir, "p")
  if jit then
    jit.off()
    jit.flush()
  end
  debug.sethook(hook, "l")
end

--- Write the counts so far to the coverage directory. Sources are paths
--- relative to the repository (lua/org/...).
function M.write()
  if not dir then
    return
  end
  debug.sethook()
  local out = {}
  for src, t in pairs(hits) do
    local rel = src:sub(2):gsub("\\", "/"):match("(lua/org/.+%.lua)$")
    if rel then
      local lines = out[rel] or {}
      for l, n in pairs(t) do
        lines[tostring(l)] = (lines[tostring(l)] or 0) + n
      end
      out[rel] = lines
    end
  end
  local f = io.open(("%s/%d-%d.json"):format(dir, vim.uv.os_getpid(), vim.uv.hrtime()), "wb")
  if f then
    f:write(vim.json.encode(out))
    f:close()
  end
end

return M
