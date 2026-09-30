local date = require("org.date")
local utils = require("org.utils")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local today = date.today_days()
local function day(offset)
  return date.from_days(today + offset):to_string({ brackets = false })
end
local function clock(offset, from, to, mins)
  return string.format("  CLOCK: [%s %s]--[%s %s] => %s", day(offset), from, day(offset), to, mins)
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/log.org"

local LINES = {
  "* TODO Deep work :work:",
  "  :LOGBOOK:",
  clock(0, "09:00", "10:30", "1:30"),
  clock(-1, "09:00", "11:00", "2:00"),
  clock(-2, "09:00", "09:30", "0:30"),
  clock(-10, "09:00", "13:00", "4:00"),
  "  :END:",
  "* TODO Side project :home:",
  "  :LOGBOOK:",
  clock(-1, "20:00", "21:00", "1:00"),
  "  :END:",
  "* DONE Closed task",
  "  CLOSED: [" .. day(-1) .. " 18:00]",
  "  :LOGBOOK:",
  '  - State "DONE"       from "TODO"       [' .. day(-1) .. " 18:00]",
  "  :END:",
  "* TODO Exercise",
  "  SCHEDULED: <" .. day(1) .. " .+1d>",
  "  :PROPERTIES:",
  "  :STYLE: habit",
  "  :END:",
  "  :LOGBOOK:",
  '  - State "DONE"       from "TODO"       [' .. day(0) .. " 07:00]",
  '  - State "DONE"       from "TODO"       [' .. day(-2) .. " 07:00]",
  "  :END:",
}

local function write()
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
  utils.writefile(path, LINES)
  require("org.files").invalidate(path)
end

local function setup(ext)
  require("org").setup({
    org_directory = dir,
    agenda_files = { path },
    extensions = ext ~= nil and { heatmap = ext } or nil,
  })
end

local function restore()
  require("org").setup({
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
  })
end

local heatmap = require("org.extensions.heatmap")

local function hls()
  return require("org.files").get(path).headlines
end

describe("heatmap extension", function()
  after_each(function()
    heatmap.close()
    restore()
  end)

  it("is off by default", function()
    setup(nil)
    eq(nil, require("org.actions").list.heatmap_open)
    eq(nil, require("org.commands").extra.heatmap)
  end)

  it("registers its action, command and key when enabled", function()
    setup({})
    ok(require("org.actions").list.heatmap_open)
    ok(require("org.commands").extra.heatmap)
    eq("<prefix>Vh", require("org.config").opts.mappings.global.heatmap_open)
  end)
end)

describe("heatmap data", function()
  before_each(function()
    write()
    setup({})
  end)
  after_each(restore)

  it("sums clocked minutes per day", function()
    local values, details = heatmap.data("clock", hls())
    eq(90, values[today])
    eq(180, values[today - 1])
    eq(30, values[today - 2])
    eq(240, values[today - 10])
    eq(2, #details[today - 1])
    eq("Deep work", details[today - 1][1].title)
    eq(120, details[today - 1][1].value)
  end)

  it("splits a clock across midnight", function()
    local b = org_buffer({
      "* Night",
      string.format("  CLOCK: [%s 23:00]--[%s 01:30] =>  2:30", day(-1), day(0)),
    })
    local values = heatmap.data("clock", require("org.files").get_buffer(b).headlines)
    eq(60, values[today - 1])
    eq(90, values[today])
  end)

  it("counts closed tasks once a day", function()
    local values = heatmap.data("closed", hls())
    eq(1, values[today - 1])
    -- the habit's log entries count as closed too
    eq(1, values[today])
    eq(1, values[today - 2])
  end)

  it("counts habit completions", function()
    local values = heatmap.data("habit", hls())
    eq(1, values[today])
    eq(1, values[today - 2])
    eq(nil, values[today - 1])
  end)

  it("shades by quartiles or thresholds", function()
    local level = heatmap.leveler({ 0, 10, 20, 30, 40 })
    eq({ 0, 1, 2, 3, 4 }, { level(0), level(10), level(20), level(30), level(40) })
    level = heatmap.leveler({ 0, 0 })
    eq(0, level(5))
    level = heatmap.leveler({}, { 30, 60, 120, 240 })
    eq({ 0, 1, 1, 2, 3, 4 }, { level(0), level(5), level(30), level(60), level(200), level(500) })
  end)

  it("computes totals and streaks", function()
    local values = { [10] = 5, [11] = 3, [12] = 0, [13] = 2, [14] = 4, [15] = 1 }
    local s = heatmap.stats(values, 10, 15)
    eq(15, s.total)
    eq(5, s.active)
    eq(3, s.streak)
    eq(3, s.longest)
    eq(5, s.best)
    eq(10, s.best_day)
    -- nothing today yet: the streak up to yesterday counts
    s = heatmap.stats({ [10] = 1, [11] = 1 }, 5, 12)
    eq(2, s.streak)
    s = heatmap.stats({ [10] = 1 }, 5, 12)
    eq(0, s.streak)
  end)

  it("ends the range with the current week", function()
    local first, last = heatmap.range(4, today)
    eq(today, last)
    eq(1, date.from_days(first):weekday())
    ok(today - first >= 21 and today - first <= 27)
  end)
end)

describe("heatmap view", function()
  before_each(function()
    write()
    setup({ weeks = 8 })
  end)
  after_each(function()
    heatmap.close()
    restore()
  end)

  it("draws a week per column and a day per row", function()
    local st = heatmap.open()
    eq(8, st.weeks)
    local lines = buf_lines(st.buf)
    eq(" Mon ", lines[st.grid_top]:sub(1, 5))
    eq(" Sun ", lines[st.grid_top + 6]:sub(1, 5))
    local _, n = lines[st.grid_top]:gsub("■", "")
    eq(8, n)
    ok(table.concat(lines, "\n"):find("Less", 1, true))
    local text = table.concat(lines, "\n")
    -- 1:30 + 2:00 + 0:30 + 4:00 + 1:00
    ok(text:find("Total 9h  ·  4 active days", 1, true), text)
    ok(text:find("Streak 3 days", 1, true), text)
    ok(text:find("best 4h", 1, true), text)
  end)

  it("shades today's cell and puts the cursor on it", function()
    local st = heatmap.open()
    local lnum = vim.api.nvim_win_get_cursor(st.win)[1]
    local wd = date.from_days(today):weekday()
    eq(st.grid_top + wd - 1, lnum)
    eq(today, heatmap.day_at(st, lnum, vim.fn.virtcol(".")))
    local levels = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.buf, -1, 0, -1, { details = true })) do
      local g = m[4].hl_group
      if g and g:match("^OrgHeatmap%d$") then
        levels[g] = true
      end
    end
    ok(levels.OrgHeatmap0 and levels.OrgHeatmap4)
  end)

  it("shows the selected day's total and entries", function()
    local st = heatmap.open()
    heatmap.move(-1)
    eq(today - 1, st.day)
    local mark = vim.api.nvim_buf_get_extmarks(
      st.buf,
      vim.api.nvim_create_namespace("org_heatmap_detail"),
      0,
      -1,
      { details = true }
    )[1]
    local text = table.concat(vim.tbl_map(function(c)
      return c[1]
    end, mark[4].virt_text))
    ok(text:find("3h", 1, true), text)
    ok(text:find("Deep work 2h", 1, true), text)
    ok(text:find("Side project 1h", 1, true), text)
    heatmap.move(-7)
    eq(today - 8, st.day)
    heatmap.move(1000)
    eq(today, st.day)
  end)

  it("filters by tag", function()
    local st = heatmap.open({ tag = "home" })
    eq(60, st.values[today - 1])
    eq(nil, st.values[today])
  end)

  it("cycles through the kinds", function()
    local st = heatmap.open()
    eq("clock", st.kind)
    heatmap.next_kind()
    eq("closed", st.kind)
    ok(buf_lines(st.buf)[1]:find("tasks closed", 1, true))
    heatmap.next_kind()
    eq("habit", st.kind)
    heatmap.next_kind()
    eq("clock", st.kind)
  end)

  it("opens the agenda for the selected day", function()
    local agenda = require("org.agenda")
    local open_day = agenda.open_day
    local got
    agenda.open_day = function(d)
      got = d
    end
    local st = heatmap.open()
    heatmap.move(-2)
    heatmap.agenda()
    agenda.open_day = open_day
    eq(today - 2, got)
    ok(not vim.api.nvim_buf_is_valid(st.buf))
  end)

  it("follows the cursor", function()
    local st = heatmap.open()
    local lnum, vcol = st.grid_top, 5 + 1
    vim.api.nvim_win_set_cursor(st.win, { lnum, vim.fn.virtcol2col(st.win, lnum, vcol) - 1 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = st.buf })
    eq(st.first, st.day)
  end)

  it("maps its keys", function()
    local st = heatmap.open()
    for _, lhs in ipairs({ "<Tab>", "h", "l", "j", "k", "<CR>", "r", "q" }) do
      ok(vim.fn.maparg(lhs, "n", false, true).buffer == 1, lhs)
    end
    vim.api.nvim_feedkeys("k", "x", false)
    eq(today - 1, st.day)
    vim.api.nvim_feedkeys("q", "x", false)
    eq(nil, heatmap.state)
  end)

  it("derives five shades from the colorscheme, or takes colors", function()
    local tgc = vim.o.termguicolors
    vim.o.termguicolors = true
    vim.api.nvim_set_hl(0, "Normal", { fg = "#ffffff", bg = "#000000" })
    vim.api.nvim_set_hl(0, "DiagnosticOk", { fg = "#00ff00" })
    local t = heatmap.shade_highlights()
    eq("#00ff00", t.OrgHeatmap4.fg)
    local seen = {}
    for i = 0, 4 do
      seen[t["OrgHeatmap" .. i].fg] = true
    end
    eq(5, vim.tbl_count(seen))
    setup({ colors = { "#111111", "#222222", "#333333", "#444444", "#555555" } })
    t = heatmap.shade_highlights()
    eq("#333333", t.OrgHeatmap2.fg)
    vim.o.termguicolors = tgc
    vim.cmd("hi clear Normal")
  end)

  it("parses :Org heatmap arguments", function()
    eq({}, heatmap.parse_args(""))
    eq({ kind = "closed", tag = "work" }, heatmap.parse_args("closed +work"))
    eq({ kind = "habit" }, heatmap.parse_args("habit"))
    eq({ tag = "home" }, heatmap.parse_args(":home:"))
    eq({ source = vim.fn.expand("~/log.org") }, heatmap.parse_args("~/log.org"))
  end)

  it("refuses an unknown kind", function()
    local notify = vim.notify
    vim.notify = function() end
    heatmap.open({ kind = "nope" })
    vim.notify = notify
    eq(nil, heatmap.state)
  end)
end)

describe("heatmap edges", function()
  before_each(function()
    write()
    setup({ weeks = 8 })
  end)
  after_each(function()
    heatmap.close()
    restore()
  end)

  it("only computes the days of the range", function()
    local values, details = heatmap.data("clock", hls(), today - 5, today)
    eq(90, values[today])
    eq(180, values[today - 1])
    eq(nil, values[today - 10])
    eq(nil, details[today - 10])
  end)

  it("counts habits by their closing notes and LAST_REPEAT", function()
    local b = org_buffer({
      "* TODO Meditate",
      "  SCHEDULED: <" .. day(1) .. " .+1d>",
      "  :PROPERTIES:",
      "  :STYLE: habit",
      "  :LAST_REPEAT: [" .. day(-3) .. " 07:00]",
      "  :END:",
      "  :LOGBOOK:",
      "  - CLOSING NOTE [" .. day(-4) .. " 08:00] \\\\",
      "    felt good",
      "  :END:",
    })
    local values = heatmap.data("habit", require("org.files").get_buffer(b).headlines)
    eq(1, values[today - 3])
    eq(1, values[today - 4])
  end)

  it("fits a tiny editor", function()
    local columns, lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 20, 6
    local ok_open, st = pcall(heatmap.open)
    vim.o.columns, vim.o.lines = columns, lines
    ok(ok_open, st)
    ok(st and vim.api.nvim_win_is_valid(st.win))
  end)

  it("fits the weeks to a resized editor", function()
    setup({ weeks = 0 })
    local columns = vim.o.columns
    vim.o.columns = 120
    local st = heatmap.open()
    local weeks = st.weeks
    vim.o.columns = 80
    vim.api.nvim_exec_autocmds("VimResized", {})
    vim.o.columns = columns
    ok(st.weeks < weeks, st.weeks .. " < " .. weeks)
    ok(vim.api.nvim_win_get_width(st.win) <= 78)
  end)

  it("stays open when it opens the agenda from a split", function()
    setup({ layout = "vsplit" })
    local agenda = require("org.agenda")
    local open_day = agenda.open_day
    agenda.open_day = function() end
    local st = heatmap.open()
    heatmap.agenda()
    agenda.open_day = open_day
    ok(vim.api.nvim_buf_is_valid(st.buf))
    vim.cmd("silent! only")
  end)

  it("completes kinds, sources and tags", function()
    local c = require("org.commands").complete("", "Org heatmap ")
    ok(vim.tbl_contains(c, "closed"), vim.inspect(c))
    ok(vim.tbl_contains(c, "work"), vim.inspect(c))
    ok(vim.tbl_contains(c, "buffer"), vim.inspect(c))
  end)
end)
