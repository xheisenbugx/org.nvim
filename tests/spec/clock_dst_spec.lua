-- TZ is fixed before process startup: changing vim.env.TZ in an already
-- running process is not portable across C-library timezone caches.
if vim.env.ORG_TEST_DST ~= "1" then
  local spec = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  local root = vim.fn.fnamemodify(spec, ":h:h:h")
  describe("clock daylight saving parity", function()
    it("passes elapsed-time regressions in America/New_York", function()
      local result = vim
        .system({
          vim.v.progpath,
          "--headless",
          "-u",
          root .. "/tests/minimal_init.lua",
          "-l",
          root .. "/tests/run.lua",
          spec,
        }, { env = { TZ = "America/New_York", ORG_TEST_DST = "1" }, text = true })
        :wait()
      eq(0, result.code, (result.stdout or "") .. (result.stderr or ""))
    end)
  end)
  return
end

local clock = require("org.clock")
local config = require("org.config")
local date = require("org.date")
local parser = require("org.parser")
local timestamps = require("org.timestamps")
local render = require("org.agenda.render")
local ui = require("org.ui")
local utils = require("org.utils")

local cases = {
  { start = "[2026-03-08 Sun 01:30]", stop = "[2026-03-08 Sun 03:30]", minutes = 60 },
  { start = "[2026-11-01 Sun 00:30]", stop = "[2026-11-01 Sun 02:30]", minutes = 180 },
}

describe("DST elapsed time (Emacs Org 9.8.7)", function()
  local real_now = date.now
  after_each(function()
    date.now = real_now
    clock.state = nil
  end)
  with_config({ clock = vim.tbl_extend("force", config.opts.clock, { report_include_clocking_task = true }) })

  it("formats clock lines and parses unstated durations using elapsed time", function()
    for _, c in ipairs(cases) do
      local start, stop = date.parse(c.start), date.parse(c.stop)
      local line, minutes = clock.format_clock_line("", start, stop)
      eq(c.minutes, minutes)
      ok(line:find("=>  " .. date.format_duration(c.minutes), 1, true), line)
      eq(c.minutes, parser.parse_clock_line("CLOCK: " .. c.start .. "--" .. c.stop).minutes)
    end
  end)

  it("sums actual time in whole reports and civil date windows", function()
    for _, c in ipairs(cases) do
      local file = parser.parse({ "* DST shift", "CLOCK: " .. c.start .. "--" .. c.stop .. " =>  2:00" })
      local hl = file.headlines[1]
      local midnight = date.parse(c.start):start_of("day"):minutes()
      eq(c.minutes, clock.sum_minutes(hl))
      eq(c.minutes, clock.sum_minutes(hl, midnight, midnight + 1440))
      eq(c.minutes, clock.sum_minutes(hl, nil, nil, true))
    end
  end)

  it("clips a clock using actual elapsed time between the bounds", function()
    local file = parser.parse({
      "* Spring",
      "CLOCK: [2026-03-08 Sun 01:30]--[2026-03-08 Sun 03:30] =>  1:00",
    })
    local from = date.parse("[2026-03-08 Sun 01:45]"):minutes()
    local to = date.parse("[2026-03-08 Sun 03:15]"):minutes()
    eq(30, clock.sum_minutes(file.headlines[1], from, to))
    eq(30, clock.sum_minutes(file.headlines[1], from, to, true))
  end)

  it("uses elapsed time in the active clock and running reports", function()
    for _, c in ipairs(cases) do
      date.now = function()
        return date.parse(c.stop)
      end
      clock.state = { path = "/tmp/dst-clock.org", title = "DST shift", start = c.start, total = 15 }
      eq(c.minutes, clock.active().minutes)
      eq(c.minutes + 15, clock.active().clocked)
      local file = parser.parse({ "* DST shift", "CLOCK: " .. c.start }, clock.state.path)
      local midnight = date.parse(c.start):start_of("day"):minutes()
      eq(c.minutes, clock.sum_minutes(file.headlines[1], midnight, midnight + 1440))
    end
  end)

  it("evaluates timestamp ranges using elapsed time", function()
    for _, c in ipairs(cases) do
      local text = c.start .. "--" .. c.stop
      local buf = org_buffer({ text }, { 1, 0 })
      ok(timestamps.evaluate_time_range(true))
      eq(text .. string.format(" %02d:00", c.minutes / 60), buf_lines(buf)[1])
    end
  end)

  it("preserves civil-day arithmetic across DST changes", function()
    local start = date.parse("<2026-03-07 Sat 12:00>")
    local next_day = start:add(1, "d")
    eq("<2026-03-08 Sun 12:00>", next_day:to_string())
    eq(1440, next_day:minutes() - start:minutes())
    eq(1380, date.elapsed_minutes(start, next_day))
  end)
end)

describe("DST agenda clock checks", function()
  local real_now = date.now
  with_config({ agenda = vim.deepcopy(config.opts.agenda) })
  after_each(function()
    date.now = real_now
  end)

  local function issues(lines, checks)
    config.opts.agenda.clock_consistency_checks = checks or {}
    local file = parser.parse(lines, "/tmp/dst-clockcheck.org")
    local day = file.headlines[1].clocks[1].start:days()
    local b = render.builder()
    render.agenda_block(b, { span = "day" }, {
      files = { file },
      span = "day",
      anchor = day,
      today = day,
      log_mode = "clockcheck",
      time_grid_off = true,
    })
    local out = {}
    for _, line in ipairs(b.lines) do
      if line:match("^ Clocking") or line:match("^ No end") then
        out[#out + 1] = vim.trim(line)
      end
    end
    return out
  end

  it("compares interval limits and open-clock ages using elapsed minutes", function()
    eq({}, issues({ "* Spring", "CLOCK: " .. cases[1].start .. "--" .. cases[1].stop }, { max_duration = 90 }))
    eq({}, issues({ "* Fall", "CLOCK: " .. cases[2].start .. "--" .. cases[2].stop }, { min_duration = 150 }))
    for _, c in ipairs(cases) do
      date.now = function()
        return date.parse(c.stop)
      end
      eq({ "No end time: (" .. date.duration_to_string(c.minutes) .. ")" }, issues({ "* Open", "CLOCK: " .. c.start }))
    end
  end)

  it("measures gaps and overlaps across a DST transition", function()
    eq(
      {},
      issues({
        "* A",
        "CLOCK: [2026-03-08 Sun 00:30]--[2026-03-08 Sun 01:30]",
        "* B",
        "CLOCK: [2026-03-08 Sun 03:30]--[2026-03-08 Sun 04:30]",
      }, { max_gap = 90 })
    )
    eq(
      { "Clocking gap: 180 minutes" },
      issues({
        "* A",
        "CLOCK: [2026-11-01 Sun 00:00]--[2026-11-01 Sun 00:30]",
        "* B",
        "CLOCK: [2026-11-01 Sun 02:30]--[2026-11-01 Sun 03:00]",
      }, { max_gap = 150 })
    )
    eq(
      { "Clocking overlap: 60 minutes" },
      issues({
        "* A",
        "CLOCK: [2026-03-08 Sun 00:30]--[2026-03-08 Sun 03:30]",
        "* B",
        "CLOCK: [2026-03-08 Sun 01:30]--[2026-03-08 Sun 04:30]",
      })
    )
  end)

  it("still matches acceptable gaps against local times of day", function()
    eq(
      {},
      issues({
        "* A",
        "CLOCK: [2026-03-08 Sun 00:30]--[2026-03-08 Sun 01:30]",
        "* B",
        "CLOCK: [2026-03-08 Sun 04:00]--[2026-03-08 Sun 04:30]",
      }, { max_gap = 30, gap_ok_around = { "03:45" } })
    )
  end)
end)

describe("DST clock resolution", function()
  local saved
  with_config({
    clock = vim.tbl_extend("force", config.opts.clock, {
      persist = false,
      auto_clock_resolution = false,
      rounding_minutes = 0,
      idle_time = 10,
    }),
  })
  before_each(function()
    saved = { now = date.now, menu = ui.menu, input = utils.input, idle = clock.user_idle_seconds, os_time = os.time }
    os.time = function(t)
      return t and saved.os_time(t) or date.now():to_time()
    end
    clock.state, clock.leftover = nil, nil
  end)
  after_each(function()
    if clock.state then
      clock.clock_cancel()
    end
    date.now, ui.menu, utils.input = saved.now, saved.menu, saved.input
    clock.user_idle_seconds, os.time = saved.idle, saved.os_time
    clock.leftover = nil
  end)

  local function running(start, now)
    date.now = function()
      return date.parse(now)
    end
    local buf = org_buffer({ "* DST shift", "CLOCK: " .. start }, { 1, 0 })
    local path = vim.fn.tempname() .. ".org"
    vim.api.nvim_buf_set_name(buf, path)
    clock.state = { path = vim.api.nvim_buf_get_name(buf), title = "DST shift", start = start }
    return buf, { bufnr = buf, lnum = 2, start = date.parse(start), active = true }
  end

  local function resolve(c, key, input, last_valid)
    ui.menu = function()
      return key
    end
    local question
    utils.input = function(opts)
      question = opts.prompt
      return input
    end
    clock.resolve(c, function()
      return "Idle"
    end, date.parse(last_valid):minutes(), { idle = true })
    return question
  end

  it("keeps a number of elapsed minutes across the spring transition", function()
    local buf, c = running("[2026-03-08 Sun 00:30]", "[2026-03-08 Sun 04:30]")
    local question = resolve(c, "K", "90", "[2026-03-08 Sun 01:30]")
    ok(question:find("default 120", 1, true), question)
    eq("CLOCK: [2026-03-08 Sun 00:30]--[2026-03-08 Sun 04:00] =>  2:30", buf_lines(buf)[2])
  end)

  it("keeps a number of elapsed minutes across the autumn transition", function()
    local buf, c = running("[2026-11-01 Sun 00:00]", "[2026-11-01 Sun 04:00]")
    local question = resolve(c, "K", "180", "[2026-11-01 Sun 00:30]")
    ok(question:find("default 270", 1, true), question)
    eq("CLOCK: [2026-11-01 Sun 00:00]--[2026-11-01 Sun 02:30] =>  3:30", buf_lines(buf)[2])
  end)

  it("restarts from the instant the user got back", function()
    local _, c = running("[2026-03-08 Sun 00:00]", "[2026-03-08 Sun 03:30]")
    resolve(c, "g", "90", "[2026-03-08 Sun 00:30]")
    eq("[2026-03-08 Sun 01:00]", clock.state.start)
  end)

  it("subtracts idle seconds from the current instant before closing", function()
    local buf = running("[2026-03-08 Sun 00:30]", "[2026-03-08 Sun 03:30]")
    clock.user_idle_seconds = function()
      return 60 * 60
    end
    ui.menu = function(opts)
      ok(opts.title:find("idle for 60.0 mins", 1, true), opts.title)
      return "S"
    end
    clock._tick()
    eq("CLOCK: [2026-03-08 Sun 00:30]--[2026-03-08 Sun 01:30] =>  1:00", buf_lines(buf)[2])
    eq(date.parse("[2026-03-08 Sun 01:30]"):minutes(), clock.leftover)
  end)
end)
