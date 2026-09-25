local config = require("org.config")
local date = require("org.date")
local ts = require("org.timestamps")
local calendar = require("org.calendar")

describe("timestamps", function()
  -- written for this setup rather than the Emacs defaults
  with_config({ todo_keywords = { "TODO(t) NEXT(n) | DONE(d)" }, log_done = "time", log_into_drawer = "LOGBOOK" })
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
    vim.api.nvim_win_set_cursor(0, { 1, 31 }) -- repeater value
    ts.increment(1)
    eq("x <2027-10-22 Fri 11:05-13:35 +2w -2d> y", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 1, 35 }) -- warning value
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
    -- only the timestamp at the cursor, like org-toggle-timestamp-type
    local buf = org_buffer({ "a <2026-09-23 Wed>--<2026-09-24 Thu> b" }, { 1, 5 })
    ok(ts.toggle_type())
    eq("a [2026-09-23 Wed]--<2026-09-24 Thu> b", buf_lines(buf)[1])
    ts.toggle_type()
    eq("a <2026-09-23 Wed>--<2026-09-24 Thu> b", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 1, 25 })
    ts.toggle_type()
    eq("a <2026-09-23 Wed>--[2026-09-24 Thu] b", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
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

-- Emacs Org 9.8 parity (expectations checked against Emacs in batch mode,
-- with "now" = Fri 2026-09-25 14:38)
describe("timestamps: Emacs org-read-date parity", function()
  local real_now = date.now
  before_each(function()
    date.now = function()
      return date.parse("<2026-09-25 Fri 14:38>")
    end
  end)
  after_each(function()
    date.now = real_now
    config.opts.read_date_prefer_future = true
  end)
  local function rd(input, default)
    local r = date.read_date(input, default and date.parse(default))
    if not r then
      return "nil"
    end
    local s = r:to_date_string()
    if r.hour then
      s = s .. string.format(" %02d:%02d", r.hour, r.min)
    end
    if r.end_hour then
      s = s .. string.format("-%02d:%02d", r.end_hour, r.end_min)
    end
    return s
  end

  it("reads answers like org-read-date-analyze", function()
    local cases = {
      { "fri", "2026-10-02" },
      { "friday", "2026-10-02" },
      { "fri 3pm", "2026-10-02 15:00" },
      { "+1h", "2026-09-25 15:38" },
      { "+2d 14:00", "2026-09-27 14:00" },
      { "24:00", "2026-09-26 00:00" },
      { "25:00", "2026-09-26 01:00" },
      { "2026-10-01 Thu", "2026-10-01" },
      { "2026-10-01 +1w", "2026-10-01" },
      { "2026-10-01 Thu 10:00 +1w -2d", "2026-10-01 10:00" },
      { "2026-10-01T10:00", "2026-10-01 10:00" },
      { "10am-11am", "2026-09-25 10:00-11:00" },
      { "10:00+1:30", "2026-09-25 10:00-11:30" },
      { "2:45-2:45pm", "2026-09-25 02:45-14:45" },
      { "12:30am", "2026-09-25 00:30" },
      { "oct", "2026-10-25" },
      { "sep", "2026-09-25" },
      { "2027", "2027-09-25" },
      { "31", "2026-10-01" },
      { "15", "2026-10-15" },
      { "2026-02-30", "2026-03-02" },
      { "feb 29", "2027-03-01" },
      { "22 sept 2026", "2026-10-22" },
      { "+2d fri", "2026-09-27" },
      { "3 weeks", "2026-10-03" },
      { "next fri", "2026-09-25" },
      { "+1 week", "2026-09-26" },
      { "w40-0", "2026-10-04" },
      { "-2fri", "2026-09-11" },
      { "+1mon", "2026-09-28" },
      { "2012 feb 3", "2012-02-03" },
      { ".", "2026-09-25" },
      { "9:5", "nil" },
    }
    for _, c in ipairs(cases) do
      eq(c[2], rd(c[1]), c[1])
    end
  end)

  it("uses the default date for ++/-- and missing parts", function()
    local def = "<2026-12-10 Thu 10:00>"
    eq("2026-12-10", rd("", def))
    eq("2026-12-12", rd("++2d", def))
    eq("2026-12-03", rd("--1w", def))
    eq("2026-12-10 14:00", rd("14:00", def))
    eq("2026-12-01", rd("dec 1", def))
    eq("2027-05-06", rd("5-6", def))
    eq("2026-09-27", rd("+2d", def))
  end)

  it("read_date_prefer_future: false and time", function()
    config.opts.read_date_prefer_future = false
    eq("2026-09-20", rd("20"))
    eq("2026-02-25", rd("feb"))
    eq("2026-09-24", rd("09-24"))
    config.opts.read_date_prefer_future = "time"
    eq("2026-09-26 10:00", rd("10:00"))
    eq("2026-09-25 15:00", rd("3pm"))
  end)

  it("the extensions today / tomorrow / yesterday / now", function()
    eq("2026-09-26 15:00", rd("3pm tomorrow"))
    eq("2026-09-24", rd("yesterday"))
    eq("2026-09-25 14:38", rd("now"))
  end)
end)

describe("timestamps: Emacs org-timestamp-change parity", function()
  local function at(line, col, n, unit)
    local buf = org_buffer({ line }, { 1, col })
    local r = ts.increment(n, unit)
    return r == false and "not on ts" or buf_lines(buf)[1]
  end

  it("toggles the type on brackets, cycles units, keeps repeaters >= 1", function()
    local s = "<2026-09-24 Thu 10:07-11:07 +1w -2d>"
    eq("[2026-09-24 Thu 10:07-11:07 +1w -2d]", at(s, 0, 1))
    eq("[2026-09-24 Thu 10:07-11:07 +1w -2d]", at(s, #s - 1, 1))
    eq("<2026-09-24 Thu 10:07-11:07 +1m -2d>", at(s, 30, 1)) -- w
    eq("<2026-09-24 Thu 10:07-11:07 +1d -2d>", at(s, 30, -1))
    eq("<2026-09-24 Thu 10:07-11:07 +1w -2d>", at(s, 29, -1)) -- 1: stays 1
    eq("<2026-09-24 Thu 10:07-11:07 +1w -2w>", at(s, 34, 1)) -- d of -2d
    eq("<2026-09-24 Thu 10:07-11:08 +1w -2d>", at(s, 26, 1)) -- end minute: by 1
    eq("<2026-09-24 Thu 10:07-12:07 +1w -2d>", at(s, 23, 1)) -- end hour
    -- the separator after a field changes that field
    eq("<2027-09-24 Fri 10:07-11:07 +1w -2d>", at(s, 5, 1))
    -- .+ repeaters are left alone, like Emacs
    eq("<2026-09-24 Thu 10:00 .+1d/3d>", at("<2026-09-24 Thu 10:00 .+1d/3d>", 24, 1))
  end)

  it("on a date range: the dashes", function()
    local s = "<2026-09-24 Thu>--<2026-09-26 Sat>"
    eq(s, at(s, 16, 1))
    eq("not on ts", at(s, 17, 1))
    eq("<2026-09-24 Thu>--[2026-09-26 Sat]", at(s, 18, 1))
  end)

  it("months roll over like Emacs", function()
    eq("[2026-03-03 Tue]", at("[2026-01-31 Sat]", 6, 1))
  end)
end)

describe("timestamps: scheduling like Emacs", function()
  local orig_pick = calendar.pick
  after_each(function()
    calendar.pick = orig_pick
  end)

  it("a new date removes CLOSED; only a count of 4 removes the date", function()
    calendar.pick = function()
      return date.parse("<2026-10-01 Thu>")
    end
    local buf = org_buffer({ "* DONE X", "CLOSED: [2026-09-01 Tue 10:00]" }, { 1, 0 })
    ts.schedule()
    eq({ "* DONE X", "SCHEDULED: <2026-10-01 Thu>" }, buf_lines(buf))
    vim.api.nvim_feedkeys(vim.keycode("3<C-c><C-s>"), "xt", false)
    eq({ "* DONE X", "SCHEDULED: <2026-10-01 Thu>" }, buf_lines(buf))
    vim.api.nvim_feedkeys(vim.keycode("4<C-c><C-s>"), "xt", false)
    eq({ "* DONE X" }, buf_lines(buf))
  end)

  it("Visual C-c C-d sets a deadline on every headline", function()
    calendar.pick = function()
      return date.parse("<2026-10-01 Thu>")
    end
    local buf = org_buffer({ "* A", "* B", "body", "* C" }, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("Vjj<C-c><C-d>"), "xt", false)
    eq({ "* A", "DEADLINE: <2026-10-01 Thu>", "* B", "DEADLINE: <2026-10-01 Thu>", "body", "* C" }, buf_lines(buf))
  end)

  it("custom timestamp display", function()
    local buf = org_buffer({ "* X <2026-09-25 Fri 10:00>--<2026-09-26 Sat> [2026-01-02 Fri +1w]" }, { 1, 0 })
    ts.toggle_custom_display()
    local ns = vim.api.nvim_get_namespaces()["org.timestamps.custom"]
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local texts = {}
    for _, m in ipairs(marks) do
      texts[#texts + 1] = m[3] .. ":" .. m[4].virt_text[1][1] .. ":" .. m[4].conceal
    end
    eq({ "4:09/25/26 Fri 10:00:", "28:09/26/26 Sat:", "45:01/02/26 Fri:" }, texts)
    ts.toggle_custom_display()
    eq({}, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
  end)
end)
