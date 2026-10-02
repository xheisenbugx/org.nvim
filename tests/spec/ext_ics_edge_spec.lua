-- The ics extension: time zones from zoneinfo, recurrence details,
-- caching, fetch failures, import dedup and the events() API.
local parser = require("org.extensions.ics.parser")
local tzif = require("org.extensions.ics.tzif")
local date = require("org.date")
local N = parser.naive

local function day(s)
  return date.parse("<" .. s .. ">"):days()
end

local function ics(events)
  local lines = { "BEGIN:VCALENDAR", "VERSION:2.0" }
  for _, ev in ipairs(events) do
    lines[#lines + 1] = "BEGIN:VEVENT"
    vim.list_extend(lines, ev)
    lines[#lines + 1] = "END:VEVENT"
  end
  lines[#lines + 1] = "END:VCALENDAR"
  return table.concat(lines, "\r\n") .. "\r\n"
end

local function utc(n)
  return os.date("!%Y-%m-%d %H:%M", n)
end

local function write(path, text)
  local fh = assert(io.open(path, "wb"))
  fh:write(text)
  fh:close()
end

describe("ics: zoneinfo (TZif) reader", function()
  local berlin = tzif.load("Europe/Berlin")
  if not berlin then
    -- no system zone database (Windows): the os.time fallback is used
    return
  end

  it("agrees with the C library on offsets, past the last transition too", function()
    skip_on_windows("TZ takes no IANA zone names on Windows")
    for _, name in ipairs({ "Europe/Berlin", "America/New_York", "Australia/Sydney", "Asia/Kolkata" }) do
      local z = assert(tzif.load(name))
      local saved = vim.env.TZ
      date.set_tz(name)
      for t = 0, 2 ^ 31 + 86400 * 365 * 20, 86400 * 37 + 3607 do
        local c = os.date("*t", t)
        local w = os.date("!*t", tzif.wall(z, t))
        if w.day ~= c.day or w.hour ~= c.hour or w.min ~= c.min then
          date.set_tz(saved)
          local fmt = "%s at %d: libc %02d %02d:%02d, tzif %02d %02d:%02d"
          error(string.format(fmt, name, t, c.day, c.hour, c.min, w.day, w.hour, w.min))
        end
      end
      date.set_tz(saved)
    end
  end)

  it("reads a skipped time with the offset before it and a repeated one as the first", function()
    eq("2024-03-31 01:30", utc(tzif.epoch(berlin, N(2024, 3, 31, 2, 30))))
    eq("2024-10-27 00:30", utc(tzif.epoch(berlin, N(2024, 10, 27, 2, 30))))
    eq("2060-07-01 10:00", utc(tzif.epoch(berlin, N(2060, 7, 1, 12))))
  end)

  it("parses POSIX TZ rules, southern hemisphere and quoted names included", function()
    local z = tzif.parse_posix("AEST-10AEDT,M10.1.0,M4.1.0/3")
    eq(11 * 3600, tzif.posix_offset(z, N(2040, 1, 15)))
    eq(10 * 3600, tzif.posix_offset(z, N(2040, 7, 15)))
    local q = tzif.parse_posix("<+0330>-3:30")
    eq(12600, tzif.posix_offset(q, 0))
    eq(nil, tzif.parse_posix(""))
    eq(nil, tzif.parse("not a zone"))
  end)

  it("converts calendar times with it (no TZ switching)", function()
    local cal = parser.parse(ics({ { "UID:a", "DTSTART;TZID=Europe/Berlin:20261025T023000", "SUMMARY:x" } }))
    local occ = parser.occurrences(cal, day("2026-10-25 Sun"), day("2026-10-25 Sun"), { timezone = "UTC" })
    -- the repeated 02:30 is the first one (CEST)
    eq("2026-10-25 00:30", utc(occ[1].start))
  end)
end)

describe("ics: recurrence details", function()
  it("expands BYHOUR and BYMINUTE", function()
    local r = parser.rrule("FREQ=DAILY;COUNT=4;BYHOUR=9,17;BYMINUTE=0,30")
    local out = vim.tbl_map(utc, parser.expand(r, N(2026, 1, 5, 9), N(2026, 1, 1), N(2026, 2, 1)))
    eq({ "2026-01-05 09:00", "2026-01-05 09:30", "2026-01-05 17:00", "2026-01-05 17:30" }, out)
  end)

  it("expands HOURLY and MINUTELY rules with filters", function()
    local r = parser.rrule("FREQ=HOURLY;INTERVAL=3;COUNT=3")
    eq(
      { "2026-01-05 22:00", "2026-01-06 01:00", "2026-01-06 04:00" },
      vim.tbl_map(utc, parser.expand(r, N(2026, 1, 5, 22), N(2026, 1, 1), N(2026, 2, 1)))
    )
    r = parser.rrule("FREQ=MINUTELY;INTERVAL=20;BYHOUR=9")
    eq(
      { "2026-01-06 09:00", "2026-01-06 09:20", "2026-01-06 09:40" },
      vim.tbl_map(utc, parser.expand(r, N(2026, 1, 5, 9), N(2026, 1, 6), N(2026, 1, 6, 23)))
    )
  end)

  it("finds single events by their span, zones included, and skips far ones", function()
    local cal = parser.parse(ics({
      { "UID:a", "DTSTART;VALUE=DATE:20260101", "DTEND;VALUE=DATE:20260301", "SUMMARY:Long" },
      { "UID:b", "DTSTART:20260204T230000Z", "DURATION:PT2H", "SUMMARY:Late UTC" },
      { "UID:c", "DTSTART;TZID=Pacific/Kiritimati:20260206T010000", "SUMMARY:Early zone" },
      { "UID:d", "DTSTART:20250105T100000", "SUMMARY:Last year" },
      { "UID:e", "DTSTART:20270105T100000", "SUMMARY:Next year" },
    }))
    local from = day("2026-02-05 Thu")
    local names = vim.tbl_map(function(o)
      return o.event.summary
    end, parser.occurrences(cal, from, from, { timezone = "UTC" }))
    table.sort(names)
    if parser.system_zone("Pacific/Kiritimati") then
      eq({ "Early zone", "Late UTC", "Long" }, names)
    else
      eq(
        { "Late UTC", "Long" },
        vim.tbl_filter(function(n)
          return n ~= "Early zone"
        end, names)
      )
    end
  end)

  it("reads an RDATE in its own zone, and drops one that repeats the rule", function()
    local cal = parser.parse(ics({
      {
        "UID:r",
        "DTSTART:20260105T100000Z",
        "RRULE:FREQ=DAILY;COUNT=2",
        "RDATE;TZID=Asia/Tokyo:20260110T180000",
        "RDATE:20260106T100000Z",
        "SUMMARY:R",
      },
    }))
    local from = day("2026-01-05 Mon")
    local starts = vim.tbl_map(function(o)
      return utc(o.start)
    end, parser.occurrences(cal, from, from + 10, { timezone = "UTC" }))
    if parser.system_zone("Asia/Tokyo") then
      eq({ "2026-01-05 10:00", "2026-01-06 10:00", "2026-01-10 09:00" }, starts)
    else
      eq({ "2026-01-05 10:00", "2026-01-06 10:00" }, vim.list_slice(starts, 1, 2))
    end
  end)

  it("skips Feb 29 in non-leap years", function()
    local r = parser.rrule("FREQ=YEARLY;COUNT=2")
    eq({ "2024-02-29 00:00", "2028-02-29 00:00" }, vim.tbl_map(utc, parser.expand(r, N(2024, 2, 29), 0, N(2030, 1, 1))))
  end)
end)

describe("ics extension: agenda, cache, fetch, import", function()
  local dir
  local ics_mod = require("org.extensions.ics")
  local notify

  local function setup(ext)
    require("org").setup({
      org_directory = dir,
      agenda_files = { dir .. "/tasks.org" },
      agenda = { time_grid = { enabled = false } },
      extensions = ext and { ics = ext } or nil,
    })
  end

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "* Nothing" }, dir .. "/tasks.org")
    notify = vim.notify
    vim.notify = function() end
  end)

  after_each(function()
    vim.notify = notify
    setup(nil)
    ics_mod.fetcher = ics_mod._real_fetcher or ics_mod.fetcher
  end)

  it("shows an event crossing midnight on both days, with the end time on the last", function()
    write(
      dir .. "/c.ics",
      ics({ { "UID:n", "DTSTART:20261009T220000", "DTEND:20261010T020000", "SUMMARY:Night shift" } })
    )
    setup({ calendars = { { name = "C", path = dir .. "/c.ics" } }, auto_refresh = false })
    local items = ics_mod.agenda_items(day("2026-10-09 Fri"), day("2026-10-10 Sat"))
    eq(2, #items)
    eq({ 22 * 60, nil, "(1/2): " }, { items[1].time, items[1].end_time, items[1].extra })
    eq({ 2 * 60, "(2/2): " }, { items[2].time, items[2].extra })
  end)

  it("expands a calendar once per range and zone, and again when the file changes", function()
    write(dir .. "/c.ics", ics({ { "UID:a", "DTSTART:20261009T100000", "RRULE:FREQ=DAILY", "SUMMARY:Daily" } }))
    setup({ calendars = { { name = "C", path = dir .. "/c.ics" } }, auto_refresh = false })
    local real = parser.occurrences
    local calls = 0
    parser.occurrences = function(...)
      calls = calls + 1
      return real(...)
    end
    local ok1, err = pcall(function()
      ics_mod.agenda_items(day("2026-10-12 Mon"), day("2026-10-18 Sun"))
      ics_mod.agenda_items(day("2026-10-12 Mon"), day("2026-10-18 Sun"))
      eq(1, calls)
      ics_mod.agenda_items(day("2026-10-19 Mon"), day("2026-10-25 Sun"))
      eq(2, calls)
      write(dir .. "/c.ics", ics({ { "UID:a", "DTSTART:20261009T110000", "RRULE:FREQ=DAILY", "SUMMARY:Daily" } }))
      vim.uv.fs_utime(dir .. "/c.ics", os.time() + 5, os.time() + 5)
      local items = ics_mod.agenda_items(day("2026-10-12 Mon"), day("2026-10-18 Sun"))
      eq(3, calls)
      eq(11 * 60, items[1].time)
    end)
    parser.occurrences = real
    ok(ok1, err)
  end)

  it("expands 5,000 events over a year quickly, and a redraw from the cache", function()
    local evs = {}
    for i = 1, 5000 do
      local rule = i % 3 == 0 and "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR" or i % 3 == 1 and "RRULE:FREQ=MONTHLY" or nil
      local e = {
        "UID:e" .. i,
        string.format("DTSTART;TZID=Europe/Berlin:2026%02d%02dT%02d0000", i % 12 + 1, i % 28 + 1, i % 12 + 7),
        "DURATION:PT1H",
        "SUMMARY:Event " .. i,
      }
      if rule then
        e[#e + 1] = rule
      end
      evs[#evs + 1] = e
    end
    write(dir .. "/big.ics", ics(evs))
    setup({ calendars = { { name = "Big", path = dir .. "/big.ics" } }, auto_refresh = false, timezone = "UTC" })
    local from = day("2026-01-01 Thu")
    local t0 = vim.uv.hrtime()
    local n = #ics_mod.agenda_items(from, from + 364)
    local first = (vim.uv.hrtime() - t0) / 1e6
    t0 = vim.uv.hrtime()
    ics_mod.agenda_items(from, from + 364)
    local second = (vim.uv.hrtime() - t0) / 1e6
    ok(n > 50000, n)
    ok(first < 10000, string.format("first %.0f ms", first))
    ok(second < first, string.format("cached %.0f ms, first %.0f ms", second, first))
  end)

  it("retries a failed fetch after the refresh interval and warns once", function()
    ics_mod._real_fetcher = ics_mod._real_fetcher or ics_mod.fetcher
    local calls, warned = 0, 0
    ics_mod.fetcher = function(_, _, cb)
      calls = calls + 1
      vim.schedule(function()
        cb("Could not resolve host")
      end)
    end
    local real_warn = require("org.utils").warn
    require("org.utils").warn = function()
      warned = warned + 1
    end
    setup({
      calendars = { { name = "R", url = "https://example.invalid/x.ics", refresh = 1 } },
      auto_refresh = false,
      cache_dir = dir .. "/cache",
    })
    local ok1, err = pcall(function()
      ics_mod.refresh_stale()
      vim.wait(200, function()
        return calls == 1 and ics_mod.fetch_errors["https://example.invalid/x.ics"] ~= nil
      end)
      ics_mod.refresh_stale()
      ics_mod._tick()
      vim.wait(50)
      eq(1, calls)
      eq(1, warned)
    end)
    require("org.utils").warn = real_warn
    ok(ok1, err)
  end)

  it("keeps the old copy when a download is cut off", function()
    ics_mod._real_fetcher = ics_mod._real_fetcher or ics_mod.fetcher
    ics_mod.fetcher = function(_, dest, cb)
      write(dest, "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nDTSTART:2026")
      vim.schedule(function()
        cb(nil)
      end)
    end
    setup({ calendars = { { name = "c", url = "https://example.com/x.ics" } }, auto_refresh = false })
    local errors
    ics_mod.refresh(function(e)
      errors = e
    end, nil)
    vim.wait(1000, function()
      return errors ~= nil
    end)
    ok(errors.c:find("incomplete", 1, true), vim.inspect(errors))
  end)

  it("never raises from the timer", function()
    setup({ calendars = { { name = "c", url = "https://example.com/x.ics" } }, auto_refresh = false })
    local real = ics_mod.refresh_stale
    local errs = 0
    local real_error = require("org.utils").error
    require("org.utils").error = function()
      errs = errs + 1
    end
    ics_mod.refresh_stale = function()
      error("boom")
    end
    local ok1 = pcall(function()
      ics_mod._tick()
      ics_mod._tick()
      ics_mod._tick()
    end)
    ics_mod.refresh_stale = real
    require("org.utils").error = real_error
    ok(ok1)
    eq(1, errs)
  end)

  it("imports an event once, and updates the time of one that moved", function()
    local file = dir .. "/in.org"
    setup({ calendars = {}, auto_refresh = false, import_file = file })
    local ev = { uid = "u1", summary = "Dentist", rdates = {} }
    local occ = { event = ev, start = N(2026, 10, 9, 9), stop = N(2026, 10, 9, 10), all_day = false }
    ics_mod.import_occurrence(occ)
    ics_mod.import_occurrence(occ)
    local lines = vim.fn.readfile(file)
    eq(1, #vim.tbl_filter(function(l)
      return l == "* Dentist"
    end, lines))
    ics_mod.import_occurrence({ event = ev, start = N(2026, 10, 9, 11), stop = N(2026, 10, 9, 12), all_day = false })
    lines = vim.fn.readfile(file)
    ok(vim.tbl_contains(lines, "<2026-10-09 Fri 11:00-12:00>"), vim.inspect(lines))
    ok(not vim.tbl_contains(lines, "<2026-10-09 Fri 09:00-10:00>"), vim.inspect(lines))
    -- occurrences of a recurring event are told apart
    local rec = { uid = "u2", summary = "Standup", rdates = {}, rrule = parser.rrule("FREQ=DAILY") }
    ics_mod.import_occurrence({ event = rec, start = N(2026, 10, 9, 9), stop = N(2026, 10, 9, 9), all_day = false })
    ics_mod.import_occurrence({ event = rec, start = N(2026, 10, 10, 9), stop = N(2026, 10, 10, 9), all_day = false })
    lines = vim.fn.readfile(file)
    eq(2, #vim.tbl_filter(function(l)
      return l == "* Standup"
    end, lines))
    ok(vim.tbl_contains(lines, ":ICS_RECURRENCE_ID: 20261010T090000"), vim.inspect(lines))
    local b = vim.fn.bufnr(file)
    if b > 0 then
      vim.api.nvim_buf_delete(b, { force = true })
    end
  end)

  it("gives other views plain events, and completes calendar names", function()
    write(dir .. "/c.ics", ics({ { "UID:a", "DTSTART:20261009T100000", "DTEND:20261009T110000", "SUMMARY:Talk" } }))
    setup({ calendars = { { name = "Conf", path = dir .. "/c.ics" } }, auto_refresh = false })
    local evs = ics_mod.events(day("2026-10-09 Fri"), day("2026-10-09 Fri"))
    eq(1, #evs)
    eq("Conf", evs[1].calendar)
    eq("Talk", evs[1].summary)
    eq({ 600, 660 }, { evs[1].start_time, evs[1].end_time })
    eq(day("2026-10-09 Fri"), evs[1].start_day)
    eq("<2026-10-09 Fri 10:00-11:00>", evs[1].timestamp)
    eq({ "Conf" }, require("org.commands").complete("C", "Org ics_refresh C"))
  end)
end)
