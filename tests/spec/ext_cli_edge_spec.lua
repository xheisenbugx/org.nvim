-- The org command line: picking among clock-in candidates, ID and
-- FILE::HEADING queries, and a running Neovim following the shell's clock.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function workspace()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({
    "* TODO Write report",
    "* TODO Write tests",
    "  :PROPERTIES:",
    "  :ID: tests-id",
    "  :END:",
  }, dir .. "/work.org")
  vim.fn.writefile({ "* TODO Write report" }, dir .. "/home.org")
  vim.fn.writefile({
    "return { org_directory = " .. vim.inspect(dir) .. ",",
    "  agenda_files = { " .. vim.inspect(dir .. "/work.org") .. ", " .. vim.inspect(dir .. "/home.org") .. " } }",
  }, dir .. "/cfg.lua")
  return dir
end

local function run(dir, args)
  local cmd = { root .. "/bin/org", "--config", dir .. "/cfg.lua" }
  vim.list_extend(cmd, args)
  local env = {
    ORG_NVIM_CONFIG = "",
    XDG_CONFIG_HOME = dir .. "/xdg-config",
    XDG_STATE_HOME = dir .. "/xdg-state",
    XDG_CACHE_HOME = dir .. "/xdg-cache",
    XDG_DATA_HOME = vim.env.XDG_DATA_HOME or (dir .. "/xdg-data"),
    ORG_NVIM_BIN = vim.v.progpath,
  }
  local res = vim.system(cmd, { text = true, stdin = false, env = env }):wait(20000)
  return res.code, res.stdout or "", res.stderr or ""
end

describe("cli: choosing the heading to clock in", function()
  it("numbers the candidates and takes the one given with --pick", function()
    local dir = workspace()
    local code, _, stderr = run(dir, { "clock", "in", "Write" })
    eq(1, code)
    ok(stderr:find("  1  ", 1, true), stderr)
    ok(stderr:find("  3  ", 1, true), stderr)
    ok(stderr:find("--pick", 1, true), stderr)
    local out
    code, out = run(dir, { "clock", "in", "--pick", "2", "Write" })
    eq(0, code)
    eq("Clocked in: Write tests\n", out)
    run(dir, { "clock", "out" })
    code = run(dir, { "clock", "in", "--pick", "9", "Write" })
    eq(2, code)
    vim.fn.delete(dir, "rf")
  end)

  it("finds a heading by its ID and by FILE::HEADING", function()
    local dir = workspace()
    local code, out = run(dir, { "clock", "in", "tests-id" })
    eq(0, code)
    eq("Clocked in: Write tests\n", out)
    run(dir, { "clock", "out" })
    code, out = run(dir, { "clock", "in", "home.org::*Write report" })
    eq(0, code, out)
    eq("Clocked in: Write report\n", out)
    -- the open clock is in home.org, not in work.org's "Write report"
    local home = table.concat(vim.fn.readfile(dir .. "/home.org"), "\n") .. "\n"
    ok(home:match("CLOCK: %[[^%]]+%]\n"), home)
    ok(not table.concat(vim.fn.readfile(dir .. "/work.org"), "\n"):match("CLOCK: %[[^%]]+%]\n"))
    run(dir, { "clock", "out" })
    vim.fn.delete(dir, "rf")
  end)
end)

describe("cli: a running Neovim follows the shell's clock", function()
  local dir
  local real_notify
  local notes = {}

  before_each(function()
    dir = workspace()
    real_notify = vim.notify
    notes = {}
    vim.notify = function(m)
      notes[#notes + 1] = m
    end
  end)

  after_each(function()
    vim.notify = real_notify
    local clock = require("org.clock")
    clock.state = nil
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      agenda_files = { root .. "/tests/fixtures/*.org" },
    })
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find(dir, 1, true) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    vim.fn.delete(dir, "rf")
  end)

  it("takes up a clock-in and drops it on a clock-out", function()
    require("org").setup({
      org_directory = dir,
      agenda_files = { dir .. "/work.org" },
      extensions = { cli = { watch_clock = true } },
    })
    local clock = require("org.clock")
    eq(nil, clock.state)
    eq(0, (run(dir, { "clock", "in", "tests-id" })))
    -- the watcher polls the stamp file every 2 s
    vim.wait(5000, function()
      return clock.state ~= nil
    end, 100)
    ok(clock.state, "clock not taken up")
    eq("Write tests", clock.state.title)
    ok(notes[#notes]:find("Clocked in from the command line", 1, true), vim.inspect(notes))
    eq(0, (run(dir, { "clock", "out" })))
    eq("out", require("org.extensions.cli").sync_clock())
    eq(nil, clock.state)
  end)

  it("does nothing while the extension is off", function()
    require("org").setup({ org_directory = dir, agenda_files = { dir .. "/work.org" } })
    run(dir, { "clock", "in", "tests-id" })
    vim.wait(2500)
    eq(nil, require("org.clock").state)
    run(dir, { "clock", "out" })
  end)

  it("completes directories for :Org cli_install", function()
    require("org").setup({ extensions = { cli = {} } })
    local got = require("org.commands").complete(dir .. "/", "Org cli_install " .. dir .. "/")
    eq({}, got)
    vim.fn.mkdir(dir .. "/bin", "p")
    got = require("org.commands").complete(dir .. "/", "Org cli_install " .. dir .. "/")
    eq({ dir .. "/bin/" }, got)
  end)
end)
