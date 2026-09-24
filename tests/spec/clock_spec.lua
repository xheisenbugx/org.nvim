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
    eq("| Headline     | Time   |      |", lines[2])
    eq("|--------------+--------+------|", lines[3])
    eq("| *Total time* | *1:45* |      |", lines[4])
    eq("| Project      |   1:30 |      |", lines[6])
    eq("| \\_  Task one |        | 1:00 |", lines[7])
    eq("| Other        |   0:15 |      |", lines[9])
    local blk = clock.clocktable({ maxlevel = 1, block = "2026-09-23" }, buf)
    eq("| *Total time* | *1:30* |", blk[4])
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
