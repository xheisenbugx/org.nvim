local config = require("org.config")
local date = require("org.date")
local ts = require("org.timestamps")
local calendar = require("org.calendar")

describe("timestamps", function()
  it("increments the component under the cursor", function()
    local buf = org_buffer({ "x <2026-09-23 Wed 10:00-11:30 +1w -2d> y" }, { 1, 4 })
    -- cursor on year (col 0-based 4 -> '2' of 2026? '<' is col 2)
    ok(ts.increment(1))
    eq("x <2027-09-23 Thu 10:00-11:30 +1w -2d> y", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 1, 9 }) -- month
    ts.increment(1)
    eq("x <2027-10-23 Sat 10:00-11:30 +1w -2d> y", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 1, 12 }) -- day
    ts.increment(-1)
    eq("x <2027-10-22 Fri 10:00-11:30 +1w -2d> y", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 1, 19 }) -- hour
    ts.increment(1)
    eq("x <2027-10-22 Fri 11:00-12:30 +1w -2d> y", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 1, 22 }) -- minute
    ts.increment(5)
    eq("x <2027-10-22 Fri 11:05-12:35 +1w -2d> y", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 1, 24 }) -- end hour
    ts.increment(1)
    eq("x <2027-10-22 Fri 11:05-13:35 +1w -2d> y", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 1, 32 }) -- repeater
    ts.increment(1)
    eq("x <2027-10-22 Fri 11:05-13:35 +2w -2d> y", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 1, 36 }) -- warning
    ts.increment(1)
    eq("x <2027-10-22 Fri 11:05-13:35 +2w -3d> y", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    ts.increment(1, "d")
    eq("x <2027-10-23 Sat 11:05-13:35 +2w -3d> y", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    eq(false, ts.increment(1))
  end)

  it("increments parts of ranges and inactive stamps", function()
    local buf = org_buffer({ "<2026-01-01 Thu>--<2026-01-03 Sat> [2026-02-01 Sun]" }, { 1, 30 })
    ts.increment(1)
    eq("<2026-01-01 Thu>--<2026-01-04 Sun> [2026-02-01 Sun]", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 1, 10 })
    ts.increment(1)
    eq("<2026-01-02 Fri>--<2026-01-04 Sun> [2026-02-01 Sun]", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 1, 46 })
    ts.increment(1)
    eq("<2026-01-02 Fri>--<2026-01-04 Sun> [2026-02-02 Mon]", buf_lines(buf)[1])
  end)

  it("updates CLOCK durations", function()
    local buf = org_buffer({ "CLOCK: [2026-09-22 Tue 10:00]--[2026-09-22 Tue 11:30] =>  1:30" }, { 1, 47 })
    ts.increment(1)
    eq("CLOCK: [2026-09-22 Tue 10:00]--[2026-09-22 Tue 12:30] =>  2:30", buf_lines(buf)[1])
  end)

  it("schedules, reschedules with logging, removes", function()
    local orig = calendar.pick
    local d = date.parse("<2026-10-01 Thu>")
    calendar.pick = function()
      return d
    end
    local buf = org_buffer({ "* TODO Task" }, { 1, 0 })
    ts.schedule()
    eq("SCHEDULED: <2026-10-01 Thu>", buf_lines(buf)[2])
    config.opts.log_reschedule = "time"
    d = date.parse("<2026-10-05 Mon>")
    ts.schedule()
    config.opts.log_reschedule = false
    local l = buf_lines(buf)
    eq("SCHEDULED: <2026-10-05 Mon>", l[2])
    ok(l[4]:match('^%- Rescheduled from "%[2026%-10%-01 Thu%]" on %['), l[4])
    ts.deadline()
    eq("DEADLINE: <2026-10-05 Mon> SCHEDULED: <2026-10-05 Mon>", buf_lines(buf)[2])
    calendar.pick = function()
      return { remove = true }
    end
    ts.deadline()
    eq("SCHEDULED: <2026-10-05 Mon>", buf_lines(buf)[2])
    calendar.pick = orig
  end)

  it("keeps repeaters when rescheduling", function()
    local orig = calendar.pick
    calendar.pick = function()
      return date.parse("<2026-11-01 Sun>")
    end
    local buf = org_buffer({ "* TODO Task", "SCHEDULED: <2026-10-01 Thu +1m>" }, { 1, 0 })
    ts.schedule()
    eq("SCHEDULED: <2026-11-01 Sun +1m>", buf_lines(buf)[2])
    calendar.pick = orig
  end)

  it("inserts timestamps and ranges", function()
    local orig = calendar.pick
    calendar.pick = function()
      return date.parse("<2026-10-01 Thu>")
    end
    local buf = org_buffer({ "Meet" }, { 1, 3 })
    ts.insert_active()
    eq("Meet <2026-10-01 Thu>", buf_lines(buf)[1])
    ts.insert_active()
    -- cursor on the timestamp: replaced
    eq("Meet <2026-10-01 Thu>", buf_lines(buf)[1])
    ts.insert_inactive()
    eq("Meet [2026-10-01 Thu]", buf_lines(buf)[1])
    calendar.pick = orig
  end)

  it("shifts via target (agenda)", function()
    local buf = org_buffer({ "* TODO Task", "SCHEDULED: <2026-10-01 Thu>", "text <2026-10-10 Sat>" })
    ts.shift({ bufnr = buf, lnum = 1 }, "scheduled", 1)
    ts.shift({ bufnr = buf, lnum = 1 }, "timestamp", -1)
    eq({ "* TODO Task", "SCHEDULED: <2026-10-02 Fri>", "text <2026-10-09 Fri>" }, buf_lines(buf))
  end)
end)

describe("timestamps (Emacs details)", function()
  local function keys(k)
    vim.api.nvim_feedkeys(vim.keycode(k), "xt", false)
  end

  it("S-Up/Down on minutes rounds to time_stamp_rounding_minutes", function()
    local buf = org_buffer({ "<2026-09-23 Wed 10:03>" }, { 1, 20 })
    ts.increment(1)
    eq("<2026-09-23 Wed 10:05>", buf_lines(buf)[1])
    ts.increment(1)
    eq("<2026-09-23 Wed 10:10>", buf_lines(buf)[1])
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "<2026-09-23 Wed 10:03-11:03>" })
    ts.increment(-1)
    eq("<2026-09-23 Wed 10:00-11:00>", buf_lines(buf)[1])
    -- a count steps by exactly that many minutes
    keys("2<S-Up>")
    eq("<2026-09-23 Wed 10:02-11:02>", buf_lines(buf)[1])
  end)

  it("toggles the timestamp type", function()
    local buf = org_buffer({ "a <2026-09-23 Wed>--<2026-09-24 Thu> b" }, { 1, 5 })
    ok(ts.toggle_type())
    eq("a [2026-09-23 Wed]--[2026-09-24 Thu] b", buf_lines(buf)[1])
    ts.toggle_type()
    eq("a <2026-09-23 Wed>--<2026-09-24 Thu> b", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    eq(false, ts.toggle_type())
  end)

  it("count 16 before C-c C-d sets the warning period", function()
    local orig = calendar.pick
    calendar.pick = function()
      return date.parse("<2026-10-05 Mon>")
    end
    local buf = org_buffer({ "* TODO Task", "DEADLINE: <2026-10-10 Sat>" }, { 1, 0 })
    keys("16<C-c><C-d>")
    calendar.pick = orig
    eq("DEADLINE: <2026-10-10 Sat -5d>", buf_lines(buf)[2])
  end)

  it("count 16 before C-c . inserts the current time", function()
    local buf = org_buffer({ "x" }, { 1, 0 })
    keys("16<C-c>.")
    local now = date.now()
    ok(buf_lines(buf)[1]:find(now:to_date_string(), 1, true), buf_lines(buf)[1])
    ok(buf_lines(buf)[1]:match("%d%d:%d%d>$"), buf_lines(buf)[1])
  end)

  it("reads ISO weeks, dotted dates and HHhMM times", function()
    eq("2026-09-21", date.read_date("2026-w39"):to_date_string())
    eq("2026-09-25", date.read_date("2026-w39-5"):to_date_string())
    eq("2026-09-24", date.read_date("w39 thu"):to_date_string())
    eq("2027-03-15", date.read_date("15.3.2027"):to_date_string())
    local t = date.read_date("2027-01-01 15h30")
    eq({ 15, 30 }, { t.hour, t.min })
    t = date.read_date("2027-01-01 9h")
    eq({ 9, 0 }, { t.hour, t.min })
  end)
end)
