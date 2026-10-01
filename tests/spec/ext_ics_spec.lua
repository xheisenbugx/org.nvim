-- The ics extension: iCalendar subscriptions shown in the agenda.
local parser = require("org.extensions.ics.parser")
local date = require("org.date")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local fixture = root .. "/tests/fixtures/ics/work.ics"
local N = parser.naive

local function fmt(list)
  local out = {}
  for _, n in ipairs(list) do
    out[#out + 1] = os.date("!%Y-%m-%d %a %H:%M", n)
  end
  return out
end

local function read(path)
  local fh = assert(io.open(path, "rb"))
  local s = fh:read("*a")
  fh:close()
  return s
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

-- occurrences as "YYYY-MM-DD HH:MM summary" (local naive times)
local function occ_list(cal, from, to, tz)
  local out = {}
  for _, o in ipairs(parser.occurrences(cal, from, to, { timezone = tz })) do
    out[#out + 1] = os.date("!%Y-%m-%d %H:%M ", o.start) .. o.event.summary
  end
  return out
end

local function day(s)
  return date.parse("<" .. s .. ">"):days()
end

describe("ics parser: content lines", function()
  it("unfolds lines and drops CR and the BOM", function()
    eq({ "DESCRIPTION:one two", "SUMMARY:x" }, parser.unfold("\239\187\191DESCRIPTION:one\r\n  two\r\nSUMMARY:x\r\n"))
    eq({ "A:bc" }, parser.unfold("A:b\n\tc\n"))
  end)

  it("splits name, params and value with quoted params", function()
    local name, params, value = parser.content_line('DTSTART;TZID="Zone: with; odd chars":20261005T100000')
    eq("DTSTART", name)
    eq("Zone: with; odd chars", params.TZID)
    eq("20261005T100000", value)
    name, params, value = parser.content_line("summary;LANGUAGE=en:Lunch: tacos")
    eq("SUMMARY", name)
    eq("en", params.LANGUAGE)
    eq("Lunch: tacos", value)
    eq(nil, (parser.content_line("garbage")))
  end)

  it("unescapes text", function()
    eq("a\nb, c; d\\e", parser.text("a\\nb\\, c\\; d\\\\e"))
  end)

  it("reads dates, times, durations and offsets", function()
    eq({ naive = N(2026, 10, 5), all_day = true }, parser.time("20261005"))
    eq({ naive = N(2026, 10, 5, 14, 30), utc = true }, parser.time("20261005T143000Z"))
    eq(
      { naive = N(2026, 10, 5, 14, 30), utc = false, tzid = "Europe/Paris" },
      parser.time("20261005T143000", {
        TZID = "Europe/Paris",
      })
    )
    eq(nil, parser.time("nonsense"))
    eq(5400, parser.duration("PT1H30M"))
    eq(86400 * 8 + 7200, parser.duration("P1W1DT2H"))
    eq(-900, parser.duration("-PT15M"))
    eq(3600, parser.offset("+0100"))
    eq(-19800, parser.offset("-0530"))
  end)

  it("parses components, events and time zones", function()
    local cal = parser.parse(read(fixture))
    eq("Work", cal.name)
    eq("America/New_York", cal.timezone)
    eq(11, #cal.events)
    eq(2, #cal.zones["Custom Zone"])
    local review = cal.events[3]
    eq("Design review", review.summary)
    eq("Room 4, 2nd floor", review.location)
    eq(
      "Agenda:\n- mockups\n- API, and a very long line that is folded onto the next line by the producer",
      review.description
    )
    eq("https://example.com/review", review.url)
    eq("America/New_York", review.start.tzid)
    eq(true, cal.events[5].start.all_day)
    eq("CANCELLED", cal.events[7].status)
  end)
end)

describe("ics parser: recurrence", function()
  local function expand(rule, start, from, limit)
    return fmt(parser.expand(parser.rrule(rule), start, from or 0, limit))
  end

  it("expands weekly rules with BYDAY and COUNT", function()
    eq(
      { "2026-09-28 Mon 10:00", "2026-09-30 Wed 10:00", "2026-10-05 Mon 10:00", "2026-10-07 Wed 10:00" },
      expand("FREQ=WEEKLY;BYDAY=MO,WE;COUNT=4", N(2026, 9, 28, 10), 0, N(2027, 1, 1))
    )
  end)

  it("expands every other week from a later window", function()
    eq(
      { "2026-09-01 Tue 08:00", "2026-09-15 Tue 08:00", "2026-09-29 Tue 08:00" },
      expand("FREQ=WEEKLY;INTERVAL=2;BYDAY=TU", N(2026, 1, 6, 8), N(2026, 9, 1), N(2026, 10, 6))
    )
  end)

  it("expands daily rules with INTERVAL from years back", function()
    eq(
      { "2026-09-29 Tue 08:00", "2026-10-02 Fri 08:00", "2026-10-05 Mon 08:00" },
      expand("FREQ=DAILY;INTERVAL=3", N(2020, 1, 1, 8), N(2026, 9, 28), N(2026, 10, 6))
    )
  end)

  it("expands monthly rules: last Friday, the 31st, the last weekday", function()
    eq(
      { "2026-01-30 Fri 09:00", "2026-02-27 Fri 09:00", "2026-03-27 Fri 09:00" },
      expand("FREQ=MONTHLY;BYDAY=-1FR;COUNT=3", N(2026, 1, 30, 9), 0, N(2027, 1, 1))
    )
    eq(
      { "2026-01-31 Sat 09:00", "2026-03-31 Tue 09:00", "2026-05-31 Sun 09:00" },
      expand("FREQ=MONTHLY", N(2026, 1, 31, 9), 0, N(2026, 6, 1))
    )
    eq(
      { "2026-09-30 Wed 08:00", "2026-10-30 Fri 08:00", "2026-11-30 Mon 08:00", "2026-12-31 Thu 08:00" },
      expand("FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", N(2026, 9, 30, 8), 0, N(2027, 1, 1))
    )
    eq(
      { "2026-10-01 Thu 08:00", "2026-10-15 Thu 08:00", "2026-11-01 Sun 08:00", "2026-11-15 Sun 08:00" },
      expand("FREQ=MONTHLY;BYMONTHDAY=1,15;COUNT=4", N(2026, 10, 1, 8), 0, N(2027, 1, 1))
    )
  end)

  it("expands yearly rules with BYMONTH and BYDAY, and UNTIL", function()
    eq(
      { "2025-03-09 Sun 02:00", "2026-03-08 Sun 02:00" },
      expand("FREQ=YEARLY;BYMONTH=3;BYDAY=2SU", N(2007, 3, 11, 2), N(2025, 1, 1), N(2027, 1, 1))
    )
    eq({ "2024-02-29 Thu 00:00", "2028-02-29 Tue 00:00" }, expand("FREQ=YEARLY", N(2024, 2, 29), 0, N(2029, 1, 1)))
    local until_ = N(2026, 10, 3)
    eq(
      { "2026-10-01 Thu 09:00", "2026-10-02 Fri 09:00" },
      fmt(parser.expand(parser.rrule("FREQ=DAILY"), N(2026, 10, 1, 9), 0, N(2027, 1, 1), function(t)
        return t > until_
      end))
    )
  end)

  it("notes unsupported parts", function()
    eq({ "BYWEEKNO" }, parser.rrule("FREQ=YEARLY;BYWEEKNO=20").unsupported)
    eq({}, parser.rrule("FREQ=DAILY;BYHOUR=9,17").unsupported)
    eq(nil, parser.rrule("INTERVAL=2"))
  end)
end)

describe("ics parser: occurrences and time zones", function()
  local cal
  before_each(function()
    cal = parser.parse(read(fixture))
  end)

  it("converts to the display zone and applies EXDATE, RECURRENCE-ID and CANCELLED", function()
    eq({
      "2026-10-05 10:00 Standup",
      "2026-10-05 17:00 Gym",
      "2026-10-06 09:00 Design review",
      "2026-10-06 10:00 Standup",
      "2026-10-07 09:00 Call with Berlin",
      "2026-10-08 12:00 Lunch",
      "2026-10-08 12:00 Standup (moved)",
      "2026-10-08 17:00 Gym",
      "2026-10-09 00:00 Company holiday",
      "2026-10-09 10:00 Standup",
      "2026-10-09 11:00 West coast sync",
      "2026-10-09 20:00 Rover check",
    }, occ_list(cal, day("2026-10-05 Mon"), day("2026-10-09 Fri"), "America/New_York"))
  end)

  it("shows the same events in another zone", function()
    local list = occ_list(cal, day("2026-10-06 Tue"), day("2026-10-06 Tue"), "UTC")
    ok(vim.tbl_contains(list, "2026-10-06 13:00 Design review"), vim.inspect(list))
    ok(vim.tbl_contains(list, "2026-10-06 14:00 Standup"), vim.inspect(list))
  end)

  it("follows VTIMEZONE daylight saving rules", function()
    local text = read(fixture):gsub("BEGIN:VEVENT.*END:VEVENT\r\n", "")
    text = text:gsub(
      "END:VCALENDAR",
      table.concat({
        "BEGIN:VEVENT",
        "UID:w",
        "DTSTART;TZID=Custom Zone:20261022T150000",
        "RRULE:FREQ=WEEKLY;COUNT=2",
        "SUMMARY:Weekly",
        "END:VEVENT",
        "END:VCALENDAR",
      }, "\r\n")
    )
    local c = parser.parse(text)
    eq(
      { "2026-10-22 13:00 Weekly", "2026-10-29 14:00 Weekly" },
      occ_list(c, day("2026-10-20 Tue"), day("2026-10-31 Sat"), "UTC")
    )
  end)

  it("resolves IANA names, Windows names and Mozilla-style paths, else reads local time", function()
    local c = parser.parse(ics({
      { "UID:a", "DTSTART;TZID=/mozilla.org/20050126_1/Europe/Berlin:20260105T100000", "SUMMARY:Moz" },
      { "UID:b", "DTSTART;TZID=W. Europe Standard Time:20260105T110000", "SUMMARY:Win" },
      { "UID:c", "DTSTART;TZID=Nowhere/Land:20260105T120000", "SUMMARY:Unknown" },
    }))
    eq(
      { "2026-01-05 09:00 Moz", "2026-01-05 10:00 Win", "2026-01-05 12:00 Unknown" },
      occ_list(c, day("2026-01-05 Mon"), day("2026-01-05 Mon"), "UTC")
    )
    eq({ ["Nowhere/Land"] = true }, c.unresolved)
    -- a user alias
    c = parser.parse(ics({ { "UID:c", "DTSTART;TZID=Office:20260105T120000", "SUMMARY:Aliased" } }))
    local occ = parser.occurrences(c, day("2026-01-05 Mon"), day("2026-01-05 Mon"), {
      timezone = "UTC",
      aliases = { Office = "Asia/Tokyo" },
    })
    eq("2026-01-05 03:00", os.date("!%Y-%m-%d %H:%M", occ[1].start))
  end)

  it("adds RDATEs, drops cancelled instances and keeps orphan overrides", function()
    local c = parser.parse(ics({
      {
        "UID:r",
        "DTSTART:20260105T100000",
        "RRULE:FREQ=DAILY;COUNT=3",
        "RDATE:20260110T100000",
        "SUMMARY:Daily",
      },
      { "UID:r", "RECURRENCE-ID:20260106T100000", "DTSTART:20260106T100000", "STATUS:CANCELLED", "SUMMARY:Daily" },
      { "UID:orphan", "RECURRENCE-ID:20260108T100000", "DTSTART:20260108T150000", "SUMMARY:Orphan" },
    }))
    eq({
      "2026-01-05 10:00 Daily",
      "2026-01-07 10:00 Daily",
      "2026-01-08 15:00 Orphan",
      "2026-01-10 10:00 Daily",
    }, occ_list(c, day("2026-01-01 Thu"), day("2026-01-31 Sat")))
  end)

  it("finds a multi-day event that started before the range", function()
    local c = parser.parse(ics({
      { "UID:x", "DTSTART;VALUE=DATE:20260101", "DTEND;VALUE=DATE:20260111", "SUMMARY:Long" },
    }))
    eq({ "2026-01-01 00:00 Long" }, occ_list(c, day("2026-01-09 Fri"), day("2026-01-09 Fri")))
    eq({}, occ_list(c, day("2026-01-11 Sun"), day("2026-01-12 Mon")))
  end)
end)

describe("ics extension", function()
  local dir, org_file
  local ics_mod = require("org.extensions.ics")

  local function setup(ext)
    require("org").setup({
      org_directory = dir,
      agenda_files = { org_file },
      default_notes_file = dir .. "/notes.org",
      agenda = { time_grid = { enabled = false } },
      extensions = ext and { ics = ext } or nil,
    })
  end

  local function week(anchor)
    local T = day(anchor or "2026-10-05 Mon")
    local b = require("org.agenda.render").view({ blocks = { { type = "agenda", span = "week" } } }, {
      today = T,
      now = 8 * 60,
      width = 100,
      anchor = T,
      files_for = function()
        return require("org.files").agenda_files()
      end,
      todo_names = { "TODO", "DONE" },
    })
    return b
  end

  local real_notify
  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    org_file = dir .. "/tasks.org"
    vim.fn.writefile({ "* TODO Write report", "  SCHEDULED: <2026-10-06 Tue>" }, org_file)
    -- keep "calendars updated" / "added ..." out of the test output
    real_notify = vim.notify
    vim.notify = function() end
  end)

  after_each(function()
    vim.notify = real_notify
    setup(nil)
    ics_mod.fetcher = ics_mod._real_fetcher or ics_mod.fetcher
  end)

  it("is inert when off: no agenda source, the agenda unchanged", function()
    setup(nil)
    eq({}, require("org.agenda.items").day_sources)
    eq(nil, require("org.actions").list.ics_import)
    local text = table.concat(week().lines, "\n")
    ok(text:find("Write report", 1, true), text)
    ok(not text:find("Work:", 1, true), text)
    -- turning it on then off again removes the source
    setup({ calendars = { { name = "Work", path = fixture } }, auto_refresh = false })
    ok(require("org.agenda.items").day_sources.ics)
    setup(nil)
    eq(nil, require("org.agenda.items").day_sources.ics)
  end)

  it("shows events in the week view next to org entries", function()
    setup({
      calendars = { { name = "Work", path = fixture, tags = { "cal" } } },
      auto_refresh = false,
      timezone = "America/New_York",
    })
    local b = week()
    local lines = {}
    for _, l in ipairs(b.lines) do
      lines[#lines + 1] = vim.trim((l:gsub("%s+:cal:$", "")))
    end
    local text = table.concat(lines, "\n")
    ok(text:find("Work:        9:00-10:00 Design review (Room 4, 2nd floor)", 1, true), text)
    ok(text:find("Work:       10:00-10:30 Standup (Zoom)", 1, true), text)
    ok(text:find("tasks:      Scheduled:  TODO Write report", 1, true), text)
    ok(text:find("Work:       Company holiday", 1, true), text)
    ok(text:find("Work:       (1/3):  Conference", 1, true), text)
    ok(not text:find("Cancelled thing", 1, true), text)
    -- items carry the calendar's tags and no file
    local found
    for _, it in pairs(b.items) do
      if it.ics and it.title:find("Design review") then
        found = it
      end
    end
    eq({ "cal" }, found.tags)
    eq(nil, found.filename)
    eq("Work", found.category)
  end)

  it("uses category, format and show_location", function()
    setup({
      calendars = { { name = "Work", path = fixture, category = "meet" } },
      auto_refresh = false,
      timezone = "America/New_York",
      show_location = false,
    })
    local text = table.concat(week().lines, "\n")
    ok(text:find("meet:        9:00-10:00 Design review\n", 1, true), text)
    setup({
      calendars = { { name = "Work", path = fixture } },
      auto_refresh = false,
      timezone = "America/New_York",
      format = function(ev)
        return "[" .. ev.summary .. "]"
      end,
    })
    text = table.concat(week().lines, "\n")
    ok(text:find("[Design review]", 1, true), text)
  end)

  it("leaves out calendars with agenda = false and restricted agendas", function()
    setup({ calendars = { { name = "Work", path = fixture, agenda = false } }, auto_refresh = false })
    eq({}, ics_mod.agenda_items(day("2026-10-05 Mon"), day("2026-10-11 Sun")))
    setup({ calendars = { { name = "Work", path = fixture } }, auto_refresh = false })
    ok(#ics_mod.agenda_items(day("2026-10-05 Mon"), day("2026-10-11 Sun")) > 5)
    eq({}, ics_mod.agenda_items(day("2026-10-05 Mon"), day("2026-10-11 Sun"), { restrict = { filename = org_file } }))
  end)

  it("fetches URL calendars into the cache and re-reads them", function()
    ics_mod._real_fetcher = ics_mod._real_fetcher or ics_mod.fetcher
    local fetched = {}
    ics_mod.fetcher = function(url, dest, cb)
      fetched[#fetched + 1] = url
      vim.fn.writefile(vim.split(read(fixture), "\n"), dest, "b")
      vim.schedule(function()
        cb(nil)
      end)
    end
    setup({
      calendars = { { name = "Team cal", url = "webcal://example.com/secret/basic.ics" } },
      auto_refresh = false,
      cache_dir = dir .. "/cache",
    })
    local c = require("org.config").opts.extensions.ics.calendars[1]
    local file = ics_mod.file_of(c)
    ok(file:find(dir .. "/cache/Team_cal-", 1, true), file)
    eq(true, ics_mod.stale(c))
    eq(0, #ics_mod.agenda_items(day("2026-10-05 Mon"), day("2026-10-11 Sun")))
    local errors
    ics_mod.refresh(function(e)
      errors = e
    end)
    vim.wait(1000, function()
      return errors ~= nil
    end)
    eq({}, errors)
    eq({ "https://example.com/secret/basic.ics" }, fetched)
    eq(1, vim.fn.filereadable(file))
    eq(false, ics_mod.stale(c))
    ok(#ics_mod.agenda_items(day("2026-10-05 Mon"), day("2026-10-11 Sun")) > 5)
  end)

  it("keeps the old copy when a fetch fails or isn't iCalendar", function()
    ics_mod._real_fetcher = ics_mod._real_fetcher or ics_mod.fetcher
    local warned = {}
    local real_warn = require("org.utils").warn
    require("org.utils").warn = function(msg)
      warned[#warned + 1] = msg
    end
    ics_mod.fetcher = function(_, dest, cb)
      vim.fn.writefile({ "<html>login</html>" }, dest)
      vim.schedule(function()
        cb(nil)
      end)
    end
    setup({ calendars = { { name = "c", url = "https://example.com/x.ics" } }, auto_refresh = false })
    local errors
    ics_mod.refresh(function(e)
      errors = e
    end)
    vim.wait(1000, function()
      return errors ~= nil
    end)
    require("org.utils").warn = real_warn
    eq({ c = "not an iCalendar file" }, errors)
    ok(warned[1]:find("not an iCalendar file", 1, true))
    local c = require("org.config").opts.extensions.ics.calendars[1]
    eq(0, vim.fn.filereadable(ics_mod.file_of(c)))
    eq(0, vim.fn.filereadable(ics_mod.file_of(c) .. ".part"))
  end)

  it("reports curl failures through the real fetcher", function()
    setup({
      calendars = { { name = "c", url = "https://example.invalid/x.ics" } },
      auto_refresh = false,
      curl = { "org-nvim-no-such-curl" },
    })
    local err
    ics_mod.fetcher("https://example.invalid/x.ics", dir .. "/x", function(e)
      err = e
    end)
    vim.wait(1000, function()
      return err ~= nil
    end)
    eq("org-nvim-no-such-curl not found", err)
  end)

  it("builds org headings and timestamps for imported events", function()
    local cal = parser.parse(read(fixture))
    local occ = parser.occurrences(cal, day("2026-10-06 Tue"), day("2026-10-06 Tue"), {
      timezone = "America/New_York",
    })
    local review
    for _, o in ipairs(occ) do
      if o.event.summary == "Design review" then
        review = o
      end
    end
    review.calendar = { name = "Work" }
    eq({
      "* Design review",
      ":PROPERTIES:",
      ":LOCATION: Room 4, 2nd floor",
      ":URL: https://example.com/review",
      ":CALENDAR: Work",
      ":ICS_UID: review@example.com",
      ":END:",
      "<2026-10-06 Tue 09:00-10:00>",
      "Agenda:",
      "- mockups",
      "- API, and a very long line that is folded onto the next line by the producer",
    }, require("org.extensions.ics").entry_lines(review))
    eq(
      "<2026-10-10 Sat>--<2026-10-12 Mon>",
      ics_mod.timestamp({ start = N(2026, 10, 10), stop = N(2026, 10, 13), all_day = true })
    )
    eq("<2026-10-09 Fri>", ics_mod.timestamp({ start = N(2026, 10, 9), stop = N(2026, 10, 10), all_day = true }))
    eq(
      "<2026-10-09 Fri 22:00>--<2026-10-10 Sat 02:00>",
      ics_mod.timestamp({ start = N(2026, 10, 9, 22), stop = N(2026, 10, 10, 2) })
    )
    eq("<2026-10-09 Fri 22:00>", ics_mod.timestamp({ start = N(2026, 10, 9, 22), stop = N(2026, 10, 9, 22) }))
  end)

  it("imports the event under the cursor in the agenda, else one picked", function()
    local today = date.today()
    local stamp = string.format("%04d%02d%02d", today.year, today.month, today.day)
    local cal_file = dir .. "/today.ics"
    local fh = assert(io.open(cal_file, "wb"))
    fh:write(ics({
      { "UID:t1", "DTSTART:" .. stamp .. "T090000", "DTEND:" .. stamp .. "T093000", "SUMMARY:Dentist" },
      { "UID:t2", "DTSTART;VALUE=DATE:" .. stamp, "SUMMARY:Bin day", "DESCRIPTION:** not a heading" },
    }))
    fh:close()
    setup({ calendars = { { name = "Home", path = cal_file } }, auto_refresh = false, import_file = dir .. "/in.org" })
    require("org.agenda").open_agenda({ span = "day" })
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local lnum
    for i, l in ipairs(lines) do
      if l:find("Dentist", 1, true) then
        lnum = i
      end
    end
    ok(lnum, table.concat(lines, "\n"))
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    require("org.actions").run("ics_import")
    local got = vim.fn.readfile(dir .. "/in.org")
    eq("* Dentist", got[1])
    ok(vim.tbl_contains(got, ":CALENDAR: Home"))
    ok(vim.tbl_contains(got, "<" .. today:to_string({ brackets = false }) .. " 09:00-09:30>"), vim.inspect(got))
    require("org.agenda.view").quit(true)
    -- outside the agenda: pick from the next days' events
    local real_select = vim.ui.select
    local offered
    vim.ui.select = function(list, o, cb)
      offered = vim.tbl_map(o.format_item, list)
      for _, occ in ipairs(list) do
        if occ.event.summary == "Bin day" then
          cb(occ)
        end
      end
    end
    require("org.actions").run("ics_import")
    vim.ui.select = real_select
    eq(2, #offered)
    ok(offered[1]:find("Bin day", 1, true) or offered[2]:find("Bin day", 1, true), vim.inspect(offered))
    got = vim.fn.readfile(dir .. "/in.org")
    ok(vim.tbl_contains(got, ",** not a heading"), vim.inspect(got))
  end)

  it("checks health", function()
    setup({
      calendars = {
        { name = "Work", path = fixture },
        { name = "Missing", path = dir .. "/nope.ics" },
        { name = "Remote", url = "https://example.com/x.ics" },
      },
      auto_refresh = false,
      cache_dir = dir .. "/cache",
    })
    local msgs = {}
    local h = {}
    for _, k in ipairs({ "ok", "warn", "error", "info" }) do
      h[k] = function(m)
        msgs[#msgs + 1] = k .. ": " .. m
      end
    end
    ics_mod.health(h, require("org.config").opts.extensions.ics)
    local text = table.concat(msgs, "\n")
    ok(text:find("ok: ics: Work: 11 event(s)", 1, true), text)
    ok(text:find("unknown time zones read as local time: Mars/Olympus", 1, true), text)
    ok(text:find("error: ics: Missing: " .. dir .. "/nope.ics not found", 1, true), text)
    ok(text:find("warn: ics: Remote not fetched yet", 1, true), text)
  end)
end)

describe("ics time zones without zoneinfo (Windows)", function()
  local tzif = require("org.extensions.ics.tzif")
  local dirs

  before_each(function()
    dirs = tzif.dirs
    tzif.clear()
  end)

  after_each(function()
    tzif.dirs = dirs
    tzif.clear()
  end)

  it("uses the bundled rule of a zone and agrees with its zoneinfo", function()
    -- offsets from the zone files, where this system has them
    local cases = {
      { "America/New_York", os.time({ year = 2026, month = 1, day = 15, hour = 12 }), -5 * 3600 },
      { "America/New_York", os.time({ year = 2026, month = 7, day = 15, hour = 12 }), -4 * 3600 },
      { "Europe/Berlin", os.time({ year = 2026, month = 7, day = 15, hour = 12 }), 2 * 3600 },
      { "Australia/Sydney", os.time({ year = 2026, month = 1, day = 15, hour = 12 }), 11 * 3600 },
      { "Asia/Kolkata", os.time({ year = 2026, month = 1, day = 15, hour = 12 }), 5 * 3600 + 1800 },
    }
    local empty = vim.fn.tempname()
    vim.fn.mkdir(empty, "p")
    tzif.dirs = function()
      return { empty }
    end
    for _, c in ipairs(cases) do
      local z = tzif.load(c[1])
      ok(z and z.bundled, c[1])
      eq(c[3], tzif.offset(z, c[2]), c[1])
    end
    eq(nil, tzif.load("Nowhere/Nothing"))
  end)
end)
