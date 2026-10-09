-- `make difftest`: org.nvim against Emacs Org 9.8.10 on generated documents
-- (tests/difftest/init.lua). Run with tests/minimal_init.lua:
--
--   nvim --headless -u tests/minimal_init.lua -l scripts/difftest.lua
--
-- Settings come from the environment:
--   SEED      first seed (default: random)
--   COUNT     documents (default 100)
--   ORACLES   space-separated oracles (default: all of them)
--   DIFFTEST_OUT       output directory (default difftest-out)
--   DIFFTEST_JOBS      Emacs workers (default: CPUs, at most 8)
--   DIFFTEST_MINIMISE  failures to shrink (default 20)
--   ORG_EMACS, ORG_LISP_DIR  Emacs and the Org 9.8.10 lisp directory
-- Exits with 1 when a difference isn't a known one.

local oracles = require("tests.difftest.oracles")
local emacs = require("tests.difftest.emacs")

local function env(name)
  local v = vim.env[name]
  if v == nil or v == "" then
    return nil
  end
  return v
end

local list = oracles.ALL
if env("ORACLES") then
  list = vim.split(vim.trim(env("ORACLES")), "[%s,]+")
  for _, o in ipairs(list) do
    if not vim.tbl_contains(oracles.ALL, o) then
      io.stderr:write(("difftest: unknown oracle %s (known: %s)\n"):format(o, table.concat(oracles.ALL, " ")))
      os.exit(2)
    end
  end
end

local problem = emacs.check()
if problem then
  io.stderr:write("difftest: Emacs with Org 9.8.10 is needed (ORG_EMACS, ORG_LISP_DIR)\n" .. problem .. "\n")
  os.exit(2)
end

math.randomseed(vim.uv.hrtime())
local seed = tonumber(env("SEED") or "") or math.random(1, 9999999)
local okr, res = xpcall(require("tests.difftest").run, debug.traceback, {
  seed = seed,
  count = tonumber(env("COUNT") or "") or 100,
  oracles = list,
  out = env("DIFFTEST_OUT") or "difftest-out",
  jobs = tonumber(env("DIFFTEST_JOBS") or "") or math.min(8, #vim.uv.cpu_info()),
  minimise = tonumber(env("DIFFTEST_MINIMISE") or ""),
})
if not okr then
  io.stderr:write("difftest: " .. tostring(res) .. "\n")
  os.exit(2)
end
os.exit(#res.failures > 0 and 1 or 0)
