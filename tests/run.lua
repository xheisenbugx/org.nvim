-- Tiny busted-style test runner.
-- Usage: nvim --headless -u tests/minimal_init.lua -l tests/run.lua [spec files...]
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local results = { passed = 0, failed = 0, errors = {} }
local stack = {}
local befores = {}
local afters = {}

_G.describe = function(name, fn)
  table.insert(stack, name)
  table.insert(befores, {})
  table.insert(afters, {})
  fn()
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

local files = _G.arg and #_G.arg > 0 and _G.arg or vim.fn.glob(root .. "/tests/spec/**/*_spec.lua", false, true)
for _, f in ipairs(files) do
  local ok, err = pcall(dofile, f)
  if not ok then
    results.failed = results.failed + 1
    table.insert(results.errors, { name = "load " .. f, err = err })
  end
end

for _, e in ipairs(results.errors) do
  io.stdout:write("FAIL: " .. e.name .. "\n    " .. tostring(e.err):gsub("\n", "\n    ") .. "\n")
end
io.stdout:write(string.format("\n%d passed, %d failed\n", results.passed, results.failed))
vim.cmd(results.failed > 0 and "cquit 1" or "qall!")
