-- Clock options: clocktable default properties, formatter and cell formats,
-- resolve_expert, persist_query_save and x11idle_program_name. Clock table
-- texts come from Emacs 9.8.10 (org-clock-report with the same options).
local clock = require("org.clock")
local config = require("org.config")
local utils = require("org.utils")
vim.g.org_test = true

local LINES = {
  "* A",
  ":LOGBOOK:",
  "CLOCK: [2026-09-25 Fri 10:00]--[2026-09-25 Fri 11:30] =>  1:30",
  ":END:",
  "** B",
  ":LOGBOOK:",
  "CLOCK: [2026-09-25 Fri 12:00]--[2026-09-25 Fri 12:15] =>  0:15",
  ":END:",
}

local function set_clock(opts)
  config.setup({ clock = vim.tbl_extend("force", { persist = false }, opts) })
end

describe("clock table options", function()
  after_each(function()
    config.setup({})
  end)

  it("writes clocktable_default_properties into a new block header", function()
    set_clock({ clocktable_default_properties = { maxlevel = 3, link = true, block = "today", tags = true } })
    org_buffer(vim.list_extend(vim.deepcopy(LINES), { "" }), { 9, 0 })
    clock.clock_report()
    local l = buf_lines()
    -- Emacs: #+BEGIN: clocktable :scope subtree :maxlevel 3 :link t :block today :tags t
    -- (plist order; here the keys after :maxlevel are sorted)
    eq("#+BEGIN: clocktable :scope subtree :maxlevel 3 :block today :link t :tags t", l[9])
    set_clock({})
    org_buffer({ "", "* A" }, { 1, 0 })
    clock.clock_report()
    eq("#+BEGIN: clocktable :scope file :maxlevel 2", buf_lines()[1])
  end)

  it("formats the total time cells", function()
    set_clock({ total_time_cell_format = "<%s>", file_time_cell_format = "_%s_" })
    local buf = org_buffer(LINES)
    local l = clock.clocktable({ maxlevel = 2 }, buf)
    eq("| Headline     | Time   |      |", l[2])
    eq("|--------------+--------+------|", l[3])
    eq("| <Total time> | <1:45> |      |", l[4])
    eq("|--------------+--------+------|", l[5])
    eq("| A            | 1:45   |      |", l[6])
    eq("| \\_  B        |        | 0:15 |", l[7])
  end)

  it("formats the file time label of multi-file tables", function()
    set_clock({ total_time_cell_format = "<%s>", file_time_cell_format = "_%s_" })
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    utils.writefile(dir .. "/A.org", { "* A", "CLOCK: [2026-09-25 Fri 10:00]--[2026-09-25 Fri 11:30] =>  1:30" })
    utils.writefile(dir .. "/B.org", { "* B", "CLOCK: [2026-09-25 Fri 12:00]--[2026-09-25 Fri 12:15] =>  0:15" })
    local buf = org_buffer({ "" })
    vim.api.nvim_buf_set_name(buf, dir .. "/main.org")
    local l = clock.clocktable({ maxlevel = 2, scope = '("A.org" "B.org")' }, buf)
    eq({
      "| File  | Headline         | Time   |",
      "|-------+------------------+--------|",
      "|       | ALL <Total time> | <1:45> |",
      "|-------+------------------+--------|",
      "| A.org | _File time_      | *1:30* |",
      "|       | A                | 1:30   |",
      "|-------+------------------+--------|",
      "| B.org | _File time_      | *0:15* |",
      "|       | B                | 0:15   |",
    }, vim.list_slice(l, 2, 10))
  end)

  it("hands the data to clocktable_formatter", function()
    local got
    set_clock({
      clocktable_formatter = function(tables, params)
        got = { tables = tables, maxlevel = params.maxlevel }
        return { "custom " .. tables[1].time }
      end,
    })
    local buf = org_buffer(LINES)
    eq({ "custom 105" }, clock.clocktable({ maxlevel = 2 }, buf))
    eq(2, got.maxlevel)
    eq(105, got.tables[1].time)
    eq({ level = 1, headline = "A", tags = {}, time = 105, properties = {} }, got.tables[1].entries[1])
    eq(15, got.tables[1].entries[2].time)
  end)
end)

describe("clock.resolve_expert (org-clock-resolve-expert)", function()
  local ui = require("org.ui")
  it("reads a key at a prompt instead of the menu", function()
    set_clock({ resolve_expert = true, auto_clock_resolution = false })
    local start = require("org.date").from_time(os.time() - 3600, true):clone({ active = false })
    local buf = org_buffer({ "* Work", "CLOCK: [" .. start:to_string({ brackets = false }) .. "]" }, { 1, 0 })
    local orig_menu, orig_getchar = ui.menu, utils.getchar
    local menu_called, prompts = false, {}
    ui.menu = function()
      menu_called = true
    end
    local keys = { "x", "C" }
    utils.getchar = function(prompt)
      prompts[#prompts + 1] = prompt
      return table.remove(keys, 1)
    end
    clock.resolve({ bufnr = buf, lnum = 2, start = start }, function()
      return "Dangling clock"
    end, start:to_time() / 60)
    ui.menu, utils.getchar = orig_menu, orig_getchar
    eq(false, menu_called)
    eq(2, #prompts) -- an invalid key asks again
    eq("Dangling clock: Work [jkKtTgGSscCiq]? ", prompts[1])
    eq({ "* Work" }, buf_lines(buf)) -- C cancelled the clock
    config.setup({})
  end)
end)

describe("clock.persist_query_save (org-clock-persist-query-save)", function()
  it("drops the running clock from the persist file when declined", function()
    local file = vim.fn.tempname() .. ".json"
    set_clock({ persist = true, persist_file = file, persist_query_save = true })
    local state = { path = "/x.org", title = "Work", start = "[2026-09-25 Fri 10:00]" }
    clock.state = state
    local orig = utils.confirm
    local asked
    utils.confirm = function(q)
      asked = q
      return false
    end
    clock.query_save()
    eq("Save current clock (Work)?", asked)
    local saved = (utils.read_json(file) or {}).state
    ok(saved == nil or saved == vim.NIL)
    eq(state, clock.state)
    utils.confirm = function()
      return true
    end
    utils.write_json(file, { state = state })
    clock.query_save()
    eq(state, utils.read_json(file).state)
    set_clock({ persist = true, persist_file = file })
    asked = nil
    utils.confirm = function(q)
      asked = q
    end
    clock.query_save()
    eq(nil, asked) -- off by default
    utils.confirm = orig
    clock.state = nil
    config.setup({})
  end)
end)

describe("clock.x11idle_program_name (org-clock-x11idle-program-name)", function()
  it("uses the configured program, else xprintidle or x11idle", function()
    set_clock({ x11idle_program_name = "my-idle" })
    eq("my-idle", clock.x11idle_program())
    set_clock({})
    eq(vim.fn.executable("xprintidle") == 1 and "xprintidle" or "x11idle", clock.x11idle_program())
  end)

  it("reads the idle time from the program on X11", function()
    -- The program (any executable) is stubbed: spawning a freshly written script is slow on
    -- macOS (the first exec of a new executable is assessed by the system,
    -- one at a time), so under parallel test runs it hit the 2s timeout.
    set_clock({ x11idle_program_name = vim.v.progpath })
    local display, has, sys = vim.env.DISPLAY, vim.fn.has, vim.system
    local ran
    vim.env.DISPLAY = ":0"
    vim.fn.has = function(f) -- as on Linux: macOS asks ioreg instead
      return f == "mac" and 0 or has(f)
    end
    vim.system = function(cmd)
      ran = cmd
      return {
        wait = function()
          return { code = 0, stdout = "120000\n" }
        end,
      }
    end
    local ok_, idle = pcall(clock.user_idle_seconds, 0)
    vim.fn.has, vim.env.DISPLAY, vim.system = has, display, sys
    ok(ok_, idle)
    eq({ vim.v.progpath }, ran)
    eq(120, idle)
    config.setup({})
  end)
end)
