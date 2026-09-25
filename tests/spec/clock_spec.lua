local config = require("org.config")
local date = require("org.date")
local clock = require("org.clock")
local files = require("org.files")

local function file_buffer(lines)
  local path = vim.fn.tempname() .. ".org"
  vim.fn.writefile(lines, path)
  vim.cmd("enew!")
  vim.cmd("edit! " .. vim.fn.fnameescape(path))
  vim.bo.bufhidden = "hide"
  return vim.api.nvim_get_current_buf(), path
end

describe("clock", function()
  before_each(function()
    config.opts.clock.persist = false
    clock.state = nil
  end)

  it("clocks in and out", function()
    local buf = file_buffer({ "* TODO Task", ":PROPERTIES:", ":Effort: 1:00", ":END:", "body" })
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    local start = date.now():add(-90, "min")
    clock.clock_in(nil, { at = start })
    local l = buf_lines(buf)
    eq(":LOGBOOK:", l[5])
    ok(l[6]:match("^CLOCK: %[.-%]$"), l[6])
    eq(":END:", l[7])
    ok(clock.active())
    ok(clock.statusline():find("/1:00%] %(Task%)"), clock.statusline())
    ok(clock.is_clocked_headline(buf, 1))
    clock.clock_out()
    l = buf_lines(buf)
    ok(l[6]:match("^CLOCK: %[.-%]%-%-%[.-%] =>  1:30$"), l[6])
    eq(nil, clock.active())
    eq("", clock.statusline())
    eq(90, files.get_buffer(buf).headlines[1].clocks[1].minutes)
  end)

  it("switches tasks and removes zero clocks", function()
    config.opts.clock.out_remove_zero_time = true
    local buf = file_buffer({ "* A", "* B" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    clock.clock_in()
    clock.clock_in({ bufnr = buf, lnum = files.get_buffer(buf).headlines[2].line })
    local l = buf_lines(buf)
    -- A's zero-length clock and drawer were removed
    eq("* A", l[1])
    eq("* B", l[2])
    eq(":LOGBOOK:", l[3])
    eq("B", clock.active().title)
    clock.clock_cancel()
    config.opts.clock.out_remove_zero_time = false
    eq({ "* A", "* B" }, buf_lines(buf))
  end)

  it("clocks out when marked done", function()
    local buf = file_buffer({ "* TODO A" })
    clock.clock_in(nil, { at = date.now():add(-10, "min") })
    require("org.todo").change_state(nil, "DONE")
    eq(nil, clock.state)
    ok(vim.tbl_filter(function(x)
      return x:match("=>%s+0:10")
    end, buf_lines(buf))[1])
  end)

  it("restores an open clock from agenda files scan", function()
    local _, path = file_buffer({ "* Running", ":LOGBOOK:", "CLOCK: [2026-09-23 Wed 09:00]", ":END:" })
    local saved = config.opts.agenda_files
    config.opts.agenda_files = { path }
    clock.restore()
    config.opts.agenda_files = saved
    eq("Running", clock.state.title)
    clock.state = nil
  end)

  it("updates clock lines", function()
    local buf = org_buffer({ "  CLOCK: [2026-09-22 Tue 10:00]--[2026-09-22 Tue 12:15] =>  0:00" })
    clock.update_clock_line(buf, 1)
    eq("  CLOCK: [2026-09-22 Tue 10:00]--[2026-09-22 Tue 12:15] =>  2:15", buf_lines(buf)[1])
  end)

  it("sums minutes with clipping", function()
    local buf = org_buffer({
      "* P",
      "CLOCK: [2026-09-22 Tue 23:00]--[2026-09-23 Wed 01:00] =>  2:00",
      "** C",
      "CLOCK: [2026-09-23 Wed 10:00]--[2026-09-23 Wed 10:30] =>  0:30",
    })
    local hl = files.get_buffer(buf).headlines[1]
    eq(150, clock.sum_minutes(hl))
    eq(120, clock.sum_minutes(hl, nil, nil, true))
    local from = date.parse("<2026-09-23 Wed>"):minutes()
    eq(90, clock.sum_minutes(hl, from, from + 1440))
  end)

  it("computes block ranges", function()
    local s, e = clock.block_range("2026-09")
    eq(date.parse("<2026-09-01>"):minutes(), s)
    eq(date.parse("<2026-10-01>"):minutes(), e)
    s = clock.block_range("2026-W01")
    eq("2025-12-29", date.from_days(s / 1440):to_date_string())
    s, e = clock.block_range("today")
    eq(1440, e - s)
    s, e = clock.block_range("thisweek")
    eq(1, date.from_days(s / 1440):weekday())
  end)

  it("builds a clock table", function()
    local buf = org_buffer({
      "* Project",
      "** Task one",
      "CLOCK: [2026-09-23 Wed 10:00]--[2026-09-23 Wed 11:00] =>  1:00",
      "** Task two",
      "CLOCK: [2026-09-23 Wed 12:00]--[2026-09-23 Wed 12:30] =>  0:30",
      "* Other",
      "CLOCK: [2026-09-20 Sun 12:00]--[2026-09-20 Sun 12:15] =>  0:15",
    })
    local lines = clock.clocktable({ maxlevel = 2 }, buf)
    ok(lines[1]:match("^#%+CAPTION: Clock summary at"))
    -- half the Time cells are numbers: Emacs right-aligns the column
    eq("| Headline     |   Time |      |", lines[2])
    eq("|--------------+--------+------|", lines[3])
    eq("| *Total time* | *1:45* |      |", lines[4])
    eq("| Project      |   1:30 |      |", lines[6])
    eq("| \\_  Task one |        | 1:00 |", lines[7])
    eq("| Other        |   0:15 |      |", lines[9])
    local blk = clock.clocktable({ maxlevel = 1, block = "2026-09-23" }, buf)
    eq("| *Total time* | *1:30* |", blk[4])
  end)

  it("clock table options: formula %, level, properties, emphasize, tags", function()
    local buf = org_buffer({
      "* Project :work:",
      ":PROPERTIES:",
      ":Effort: 2:00",
      ":END:",
      "** Task one",
      "CLOCK: [2026-09-23 Wed 10:00]--[2026-09-23 Wed 11:00] =>  1:00",
      "* Other",
      "CLOCK: [2026-09-20 Sun 12:00]--[2026-09-20 Sun 13:00] =>  1:00",
    })
    local lines = clock.clocktable({
      maxlevel = 2,
      formula = "%",
      level = true,
      properties = '("Effort")',
      tags = true,
      emphasize = true,
    }, buf)
    eq("| L | Tags | Effort | Headline       | Time   |        |     % |", lines[2])
    eq("|   |      |        | *Total time*   | *2:00* |        | 100.0 |", lines[4])
    eq("| 1 | work |   2:00 | *Project*      | *1:00* |        |  50.0 |", lines[6])
    eq("| 2 | work |        | \\_  /Task one/ |        | /1:00/ |  50.0 |", lines[7])
    eq("| 1 |      |        | *Other*        | *1:00* |        |  50.0 |", lines[8])
  end)

  it("clock table: narrow, days, compact, timestamp", function()
    local buf = org_buffer({
      "* A very long headline that goes on and on beyond forty characters",
      "SCHEDULED: <2026-09-21 Mon>",
      "CLOCK: [2026-09-20 Sun 10:00]--[2026-09-21 Mon 12:00] => 26:00",
      "** Child",
      "CLOCK: [2026-09-23 Wed 10:00]--[2026-09-23 Wed 10:30] =>  0:30",
    })
    local lines = clock.clocktable({ maxlevel = 2, compact = true, timestamp = true }, buf)
    eq("| Timestamp        | Headline                                 | Time      |", lines[2])
    eq("|                  | *Total time*                             | *1d 2:30* |", lines[4])
    eq("| <2026-09-21 Mon> | A very long headline that goes on and... | 1d 2:30   |", lines[6])
    eq("|                  | \\_  Child                                | 0:30      |", lines[7])
  end)

  it("clock table :step", function()
    local buf = org_buffer({
      "* A",
      "CLOCK: [2026-09-21 Mon 10:00]--[2026-09-21 Mon 11:00] =>  1:00",
      "CLOCK: [2026-09-23 Wed 10:00]--[2026-09-23 Wed 10:30] =>  0:30",
    })
    local lines = clock.clocktable({ step = "day", block = "2026-W39", stepskip0 = true }, buf)
    eq("", lines[1])
    eq("Daily report: [2026-09-21 Mon]", lines[2])
    eq("| Headline     | Time   |", lines[3])
    eq("| *Total time* | *1:00* |", lines[5])
    eq("Daily report: [2026-09-23 Wed]", lines[9])
    eq("| *Total time* | *0:30* |", lines[12])
    -- the skipped Sunday leaves an empty line, like Emacs
    eq(15, #lines)
    eq("", lines[15])
    lines = clock.clocktable({ step = "week", tstart = "<2026-09-16 Wed>", tend = "<2026-09-30 Wed>" }, buf)
    eq("Weekly report starting on: [2026-09-16 Wed]", lines[2])
    eq("| *Total time* | *0:00* |", lines[5])
    eq("Weekly report starting on: [2026-09-21 Mon]", lines[7])
    eq("| *Total time* | *1:30* |", lines[10])
    eq("Weekly report starting on: [2026-09-28 Mon]", lines[14])
  end)

  it("formats durations like org-duration", function()
    eq("1d 2:30", date.duration_to_string(1590))
    eq("26:30", date.duration_to_string(1590, "h:mm"))
    eq("0:45", date.duration_to_string(45))
    eq(90.5, date.parse_duration("1:30:30"))
  end)

  it("clocks in continuously", function()
    config.opts.clock.continuously = true
    local buf = file_buffer({ "* A", "* B" })
    local stop = date.now():add(-20, "min")
    clock.clock_in(nil, { at = date.now():add(-60, "min") })
    clock.clock_out({ at = stop })
    clock.clock_in({ bufnr = buf, lnum = files.get_buffer(buf).headlines[2].line })
    config.opts.clock.continuously = false
    eq(stop:clone({ active = false }):to_string(), clock.state.start)
    clock.clock_cancel()
  end)

  it("honours CLOCK_INTO_DRAWER and LOG_INTO_DRAWER", function()
    local buf = file_buffer({ "* A", ":PROPERTIES:", ":CLOCK_INTO_DRAWER: CLOCKING", ":END:" })
    clock.clock_in(nil, { at = date.now():add(-5, "min") })
    eq(":CLOCKING:", buf_lines(buf)[5])
    clock.clock_cancel()
    buf = file_buffer({ "* A", ":PROPERTIES:", ":CLOCK_INTO_DRAWER: nil", ":END:" })
    clock.clock_in(nil, { at = date.now():add(-5, "min") })
    ok(buf_lines(buf)[5]:match("^CLOCK: "), buf_lines(buf)[5])
    clock.clock_cancel()
    buf = file_buffer({ "* A", ":PROPERTIES:", ":LOG_INTO_DRAWER: MYLOG", ":END:" })
    clock.clock_in(nil, { at = date.now():add(-5, "min") })
    eq(":MYLOG:", buf_lines(buf)[5])
    clock.clock_cancel()
  end)

  it("switches state and takes a note on clock out", function()
    config.opts.clock.out_switch_to_state = "NEXT"
    local buf = file_buffer({ "#+STARTUP: lognoteclock-out", "* TODO A" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    clock.clock_in(nil, { at = date.now():add(-10, "min") })
    clock.clock_out({ note = "stopped here" })
    config.opts.clock.out_switch_to_state = nil
    local l = buf_lines(buf)
    eq("* NEXT A", l[2])
    ok(l[4]:match("^CLOCK: .*=>  0:10$"), l[4])
    eq("- stopped here", l[5])
  end)

  it("remembers history and clocks in a selected task", function()
    local buf = file_buffer({ "* A", "* B" })
    clock.history = {}
    clock.clock_in(nil, { at = date.now():add(-5, "min") })
    clock.clock_in({ bufnr = buf, lnum = files.get_buffer(buf).headlines[2].line }, { at = date.now():add(-3, "min") })
    eq({ "B", "A" }, vim.tbl_map(function(h)
      return h.title
    end, clock.history))
    local ui = require("org.ui")
    local orig = ui.menu
    local seen
    ui.menu = function(opts)
      seen = {}
      for _, it in ipairs(opts.items) do
        seen[#seen + 1] = it.heading and it.label or (it.key .. " " .. vim.trim(it.label))
      end
      -- recent task 2 is A
      for _, it in ipairs(opts.items) do
        if it.key == "2" then
          return it.value
        end
      end
    end
    clock.clock_in_select()
    ui.menu = orig
    local cat = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t:r")
    eq({
      "The task interrupted by starting the last one",
      "i " .. cat .. "  A",
      "Current Clocking Task",
      "c " .. cat .. "  B",
      "Recent Tasks",
      "1 " .. cat .. "  B",
      "2 " .. cat .. "  A",
    }, vim.tbl_map(function(l)
      return (l:gsub("%s+", " "):gsub(cat .. " ", cat .. "  "))
    end, seen))
    eq("A", clock.active().title)
    eq("A", clock.history[1].title)
    -- B was interrupted
    eq("B", clock.interrupted.title)
    clock.clock_cancel()
  end)

  it("modifies and increments effort", function()
    local buf = file_buffer({ "* A", ":PROPERTIES:", ":Effort: 1:00", ":Effort_ALL: 0:30 1:00 2:00", ":END:" })
    clock.clock_in(nil, { at = date.now():add(-5, "min") })
    eq("1:15", clock.modify_effort("+15"))
    eq(":Effort: 1:15", buf_lines(buf)[3])
    eq(75, clock.state.effort)
    eq("0:45", clock.modify_effort("-0:30"))
    eq("2:00", clock.modify_effort("2h"))
    clock.clock_cancel()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    eq(nil, clock.inc_effort()) -- 2:00 is the last value
    clock.modify_effort("0:30")
    eq("1:00", clock.inc_effort())
    eq(":Effort: 1:00", buf_lines(buf)[3])
  end)

  it("shifts both clock timestamps with C-S-Up/Down", function()
    local buf = org_buffer({ "* A", "CLOCK: [2026-09-23 Wed 10:00]--[2026-09-23 Wed 11:30] =>  1:30" }, { 2, 23 })
    ok(clock.timestamps_shift(1))
    eq("CLOCK: [2026-09-23 Wed 11:00]--[2026-09-23 Wed 12:30] =>  1:30", buf_lines(buf)[2])
    vim.api.nvim_win_set_cursor(0, { 2, 45 })
    ok(clock.timestamps_shift(-1))
    eq("CLOCK: [2026-09-22 Tue 11:00]--[2026-09-22 Tue 12:30] =>  1:30", buf_lines(buf)[2])
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    eq(false, clock.timestamps_shift(1))
  end)

  it("resolves dangling clocks", function()
    local buf, path = file_buffer({
      "* A",
      ":LOGBOOK:",
      "CLOCK: [2026-09-23 Wed 09:00]",
      ":END:",
      "* B",
      ":LOGBOOK:",
      "CLOCK: [2026-09-23 Wed 10:00]",
      ":END:",
    })
    local saved = config.opts.agenda_files
    config.opts.agenda_files = { path }
    eq(2, #vim.tbl_filter(function(d)
      return d.bufnr == buf
    end, clock.dangling_clocks()))
    local ui = require("org.ui")
    local utils = require("org.utils")
    local omenu, oinput = ui.menu, utils.input
    -- K: keep 30 minutes and stay clocked out (k would clock in again)
    local answers = { B = "K", A = "C" }
    ui.menu = function(opts)
      return answers[opts.title:match(": (%w+)$")] or "i"
    end
    utils.input = function()
      return "30"
    end
    clock.resolve_clocks()
    ui.menu, utils.input = omenu, oinput
    config.opts.agenda_files = saved
    -- bottom-up: B kept 30 minutes, A cancelled
    eq({
      "* A",
      "* B",
      ":LOGBOOK:",
      "CLOCK: [2026-09-23 Wed 10:00]--[2026-09-23 Wed 10:30] =>  0:30",
      ":END:",
    }, buf_lines(buf))
  end)

  it("cleans up temp buffers", function()
    vim.cmd("enew!")
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):match("%.org$") and b ~= vim.api.nvim_get_current_buf() then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
  end)
end)
