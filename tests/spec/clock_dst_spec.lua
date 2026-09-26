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
