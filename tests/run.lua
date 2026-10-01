-- Tiny busted-style test runner.
-- Usage: nvim --headless -u tests/minimal_init.lua -l tests/run.lua [spec files...]
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local results = { passed = 0, failed = 0, errors = {}, skipped = {} }
local stack = {}
local befores = {}
local afters = {}

_G.describe = function(name, fn)
  table.insert(stack, name)
  table.insert(befores, {})
  table.insert(afters, {})
  -- an error in the body fails the describe, not the specs of later files:
  -- they would run with its name and its before_each/after_each hooks
  local ok, err = pcall(fn)
  if not ok then
    results.failed = results.failed + 1
    table.insert(results.errors, { name = table.concat(stack, " > "), err = err })
  end
  table.remove(afters)
  table.remove(befores)
  table.remove(stack)
end

_G.before_each = function(fn)
  table.insert(befores[#befores], fn)
end

_G.after_each = function(fn)
  table.insert(afters[#afters], fn)
end

--- Inside a describe: set top-level config options for each of its tests
--- and restore them afterwards (specs written for a non-default setup,
--- e.g. a NEXT keyword or logging into LOGBOOK).
_G.with_config = function(overrides)
  local saved
  before_each(function()
    local opts = require("org.config").opts
    saved = {}
    for k, v in pairs(overrides) do
      saved[k] = { opts[k] }
      opts[k] = vim.deepcopy(v)
    end
  end)
  after_each(function()
    local opts = require("org.config").opts
    for k, v in pairs(saved or {}) do
      opts[k] = v[1]
    end
  end)
end

_G.it = function(name, fn)
  local full = table.concat(stack, " > ") .. " > " .. name
  -- specs call commands directly, which read v:count: don't let one test's
  -- count (e.g. a fed "3<C-c><C-s>") leak into the next
  vim.cmd("normal! \27")
  local ok, err = pcall(function()
    for _, level in ipairs(befores) do
      for _, b in ipairs(level) do
        b()
      end
    end
    fn()
  end)
  for i = #afters, 1, -1 do
    for _, a in ipairs(afters[i]) do
      local aok, aerr = pcall(a)
      if ok and not aok then
        ok, err = false, aerr
      end
    end
  end
  if ok then
    results.passed = results.passed + 1
  elseif type(err) == "table" and err.skip then
    results.skipped[#results.skipped + 1] = full .. " (" .. err.skip .. ")"
  else
    results.failed = results.failed + 1
    table.insert(results.errors, { name = full, err = err })
  end
end

local function fmt(v)
  return vim.inspect(v)
end

_G.eq = function(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error((msg and (msg .. ": ") or "") .. "expected " .. fmt(expected) .. ", got " .. fmt(actual), 2)
  end
end

_G.ok = function(v, msg)
  if not v then
    error(msg or ("expected truthy, got " .. fmt(v)), 2)
  end
end

--- Create a scratch org buffer with `lines`, make it current, cursor at {lnum, col0}.
_G.org_buffer = function(lines, cursor)
  vim.cmd("enew!")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "org"
  if cursor then
    vim.api.nvim_win_set_cursor(0, cursor)
  end
  return buf
end

_G.buf_lines = function(buf)
  return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false)
end

local is_win = vim.fn.has("win32") == 1

--- A fake program `name` in `dir` running the POSIX shell script `body`
--- (with or without its #! line). On Windows, where a script isn't
--- executable, `name.cmd` runs it with sh (Git for Windows' on CI). Returns
--- the path to run it by.
_G.fake_exe = function(dir, name, body)
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. name
  if not body:match("^#!") then
    body = "#!/bin/sh\n" .. body
  end
  local f = assert(io.open(path, "wb"))
  f:write(body, body:sub(-1) == "\n" and "" or "\n")
  f:close()
  vim.uv.fs_chmod(path, tonumber("755", 8))
  if not is_win then
    return path
  end
  local cmd = assert(io.open(path .. ".cmd", "wb"))
  cmd:write('@sh "%~dpn0" %*\r\n')
  cmd:close()
  return path .. ".cmd"
end

--- Put `dir` first on $PATH (with the platform's separator).
_G.path_prepend = function(dir)
  vim.env.PATH = dir .. (is_win and ";" or ":") .. (vim.env.PATH or "")
end

--- Skip the rest of the current spec on Windows, which can't do `reason`
--- (Unix file modes, POSIX time zone names in TZ, ...).
_G.skip_on_windows = function(reason)
  if is_win then
    error({ skip = reason }, 0)
  end
end

-- Temp names in the form the plugin works with: forward slashes, and the
-- long form of 8.3 short names (C:\Users\RUNNER~1\...), as on other systems
-- expectations are built from them.
if is_win then
  local tempname = vim.fn.tempname
  vim.fn.tempname = function()
    local p = tempname()
    local dir, base = p:match("^(.*)[/\\]([^/\\]+)$")
    return vim.fs.normalize(require("org.utils").realpath(dir) or dir) .. "/" .. base
  end
end

-- What specs stub: a spec that fails before putting a function or an
-- environment variable back would break the specs of later files (e.g. a
-- no-op utils.notify hides every later warning). Each file starts from the
-- state the previous one found.
local VIM_FNS = {
  { vim, "notify" },
  { vim, "system" },
  { vim.ui, "select" },
  { vim.ui, "input" },
  { vim.fn, "input" },
  { vim.fn, "confirm" },
  { vim.fn, "getchar" },
  { vim.fn, "inputlist" },
  { vim.fn, "has" },
  { vim.fn, "executable" },
  { os, "time" },
  { os, "date" },
  { os, "getenv" },
}

local function snapshot()
  local s = { vim = {}, modules = {}, env = vim.fn.environ() }
  for i, f in ipairs(VIM_FNS) do
    s.vim[i] = f[1][f[2]]
  end
  for name, mod in pairs(package.loaded) do
    if type(name) == "string" and name:match("^org[%.]") or name == "org" then
      if type(mod) == "table" then
        local fns = {}
        for k, v in pairs(mod) do
          if type(v) == "function" then
            fns[k] = v
          end
        end
        s.modules[name] = fns
      end
    end
  end
  return s
end

local function restore(s)
  -- and no buffers: a modified one left by a failing spec makes a later
  -- :edit fail with E37
  vim.cmd("silent! %bwipeout!")
  for i, f in ipairs(VIM_FNS) do
    f[1][f[2]] = s.vim[i]
  end
  for name, fns in pairs(s.modules) do
    local mod = package.loaded[name]
    if type(mod) == "table" then
      for k, v in pairs(fns) do
        if mod[k] ~= v then
          mod[k] = v
        end
      end
    end
  end
  for k in pairs(vim.fn.environ()) do
    if s.env[k] == nil then
      vim.env[k] = nil
    end
  end
  for k, v in pairs(s.env) do
    if vim.env[k] ~= v then
      vim.env[k] = v
    end
  end
end

local files = _G.arg and #_G.arg > 0 and _G.arg or vim.fn.glob(root .. "/tests/spec/**/*_spec.lua", false, true)
for _, f in ipairs(files) do
  local state = snapshot()
  local ok, err = pcall(dofile, f)
  if not ok then
    results.failed = results.failed + 1
    table.insert(results.errors, { name = "load " .. f, err = err })
  end
  restore(state)
end

for _, e in ipairs(results.errors) do
  io.stdout:write("FAIL: " .. e.name .. "\n    " .. tostring(e.err):gsub("\n", "\n    ") .. "\n")
end
for _, s in ipairs(results.skipped) do
  io.stdout:write("SKIP: " .. s .. "\n")
end
io.stdout:write(
  string.format(
    "\n%d passed, %d failed%s\n",
    results.passed,
    results.failed,
    #results.skipped > 0 and string.format(", %d skipped", #results.skipped) or ""
  )
)
vim.cmd(results.failed > 0 and "cquit 1" or "qall!")
