-- Agenda calendar commands (org.agenda.calendars): org-agenda-convert-date,
-- org-agenda-phases-of-moon, org-agenda-sunrise-sunset, org-agenda-holidays.
--
-- Every expected string was printed by Emacs 31 in batch mode
-- (`calendar-*-date-string', `calendar-lunar-phases', `solar-sunrise-sunset-string',
-- `calendar-list-holidays'), with TZ=America/New_York where a zone matters.
local cal = require("org.agenda.calendars")
local astro = require("org.agenda.holidays.astro")
local solar = require("org.agenda.holidays.solar")

local function abs(m, d, y)
  return astro.absolute_from_gregorian(m, d, y)
end

-- 2026-09-25 12:00 UTC (see agenda_holidays_astro_spec).
local NOW = 1790337600

local function with_tz(tz, fn)
  local saved = vim.env.TZ
  vim.env.TZ = tz
  local ok, err = pcall(fn, solar.system_zone(NOW))
  vim.env.TZ = saved
  solar.reset()
  if not ok then
    error(err, 0)
  end
end

describe("agenda calendars: convert date", function()
  it("matches org-agenda-convert-date", function()
    eq({
      "Gregorian:  Sunday, September 27, 2026",
      "ISO:        Day 7 of week 39 of 2026",
      "Day of Yr:  Day 270 of 2026; 95 days remaining in the year",
      "Julian:     September 14, 2026",
      "Astron. JD: 2461311 (Julian date number at noon UTC)",
      "Hebrew:     Tishri 16, 5787 (until sunset)",
      "Islamic:    Rabi II 14, 1448 (until sunset)",
      "French:     Sextidi 6 Vendémiaire an 235 de la Révolution, jour de la Balsamine",
      "Bahá’í:     Mashíyyat 1, 183 (until sunset)",
      "Mayan:      Long count = 13.0.13.17.8; tzolkin = 1 Lamat; haab = 1 Yax",
      "Coptic:     Tut 17, 1743",
      "Ethiopic:   Maskaram 17, 2019",
      "Persian:    Mehr 5, 1405",
      "Chinese:    Cycle 78, year 43 (Bing-Wu), month 8 (Ding-You), day 17 (Jia-Chen)",
    }, cal.convert_lines(abs(9, 27, 2026)))
  end)

  it("handles year ends, leap years and leap months", function()
    local a = abs(1, 1, 2000)
    eq("Day 6 of week 52 of 1999", cal.iso_string(a))
    eq("Day 1 of 2000; 365 days remaining in the year", cal.day_of_year_string(a))
    eq("December 19, 1999", cal.julian_string(a))
    eq("Teveth 23, 5760", cal.hebrew_string(a))
    eq("Ramadan 24, 1420", cal.islamic_string(a))
    eq("Duodi 12 Nivôse an 208 de la Révolution, jour de l'Argile", cal.french_string(a))
    eq("Sharaf 2, 156", cal.bahai_string(a))
    eq("Long count = 12.19.6.15.2; tzolkin = 11 Ik; haab = 10 Kankin", cal.mayan_string(a))
    eq("Kiyahk 22, 1716", cal.coptic_string(a))
    eq("Takhsas 22, 1992", cal.ethiopic_string(a))
    eq("Dey 11, 1378", cal.persian_string(a))
    eq("Cycle 78, year 16 (Ji-Mao), month 11 (Bing-Zi), day 25 (Wu-Wu)", cal.chinese_string(a))

    a = abs(2, 29, 2024)
    eq("Adar I 20, 5784", cal.hebrew_string(a))
    eq("Ayyám-i-Há 4, 180", cal.bahai_string(a))
    eq("Primidi 11 Ventôse an 232 de la Révolution, jour du Narcisse", cal.french_string(a))
    eq("Esfand 10, 1402", cal.persian_string(a))

    a = abs(12, 31, 1999)
    eq("Day 365 of 1999; 0 days remaining in the year", cal.day_of_year_string(a))
    eq("Day 5 of week 52 of 1999", cal.iso_string(a))

    a = abs(3, 20, 2025)
    eq("Bahá 1, 182", cal.bahai_string(a))
    eq("Farvardin 1, 1404", cal.persian_string(a))
    eq("Décadi 30 Ventôse an 233 de la Révolution, jour du Plantoir", cal.french_string(a))
    eq("Long count = 13.0.12.7.12; tzolkin = 4 Eb; haab = 15 Cumku", cal.mayan_string(a))
  end)

  it("gives empty strings before a calendar's epoch", function()
    local a = abs(7, 14, 1789)
    eq("", cal.french_string(a))
    eq("", cal.bahai_string(a))
    eq("Tammuz 20, 5549", cal.hebrew_string(a))
    eq("Shawwal 20, 1203", cal.islamic_string(a))
    eq("Cycle 74, year 46 (Ji-You), second month 5, day 22 (Ding-Wei)", cal.chinese_string(a))
    eq("Abib 9, 1505", cal.coptic_string(a))
    eq("Tir 24, 1168", cal.persian_string(a))
    eq("Primidi 1 Vendémiaire an 1 de la Révolution, jour du Raisin", cal.french_string(abs(9, 22, 1792)))
    eq("Tuesday, October 5, 1582", cal.gregorian_string(abs(10, 5, 1582)))
    eq("September 25, 1582", cal.julian_string(abs(10, 5, 1582)))
    eq("2299151", cal.astro_string(abs(10, 5, 1582)))
  end)
end)

describe("agenda calendars: moon, sun, holidays", function()
  it("lists the phases of the moon like calendar-lunar-phases", function()
    with_tz("America/New_York", function(zone)
      local title, lines = cal.phases_lines(abs(9, 27, 2026), zone)
      eq("Phases of the Moon from August to October, 2026", title)
      eq({
        "Wednesday, August 5, 2026: Last Quarter Moon 10:28pm (EDT)",
        "Wednesday, August 12, 2026: New Moon 1:38pm (EDT) ** Solar Eclipse **",
        "Wednesday, August 19, 2026: First Quarter Moon 10:47pm (EDT)",
        "Friday, August 28, 2026: Full Moon 12:16am (EDT) ** Lunar Eclipse **",
        "Friday, September 4, 2026: Last Quarter Moon 3:57am (EDT)",
        "Thursday, September 10, 2026: New Moon 11:27pm (EDT)",
        "Friday, September 18, 2026: First Quarter Moon 4:44pm (EDT)",
        "Saturday, September 26, 2026: Full Moon 12:46pm (EDT)",
        "Saturday, October 3, 2026: Last Quarter Moon 9:31am (EDT)",
        "Saturday, October 10, 2026: New Moon 11:50am (EDT)",
        "Sunday, October 18, 2026: First Quarter Moon 12:14pm (EDT)",
        "Monday, October 26, 2026: Full Moon 12:09am (EDT)",
      }, lines)
      title, lines = cal.phases_lines(abs(1, 15, 2027), zone)
      eq("Phases of the Moon from December, 2026 to February, 2027", title)
      eq(13, #lines)
      eq("Tuesday, December 1, 2026: Last Quarter Moon 1:14am (EST)", lines[1])
      eq("Friday, January 22, 2027: Full Moon 7:15am (EST) ** Lunar Eclipse possible **", lines[8])
      eq("Sunday, February 28, 2027: Last Quarter Moon 12:22am (EST)", lines[13])
    end)
  end)

  it("formats sunrise and sunset like solar-sunrise-sunset-string", function()
    with_tz("America/New_York", function(zone)
      local o = { zone = zone }
      eq(
        "Sunrise 6:49am (EDT), sunset 6:44pm (EDT) at 40.7N, 74.0W (11:54 hrs daylight)",
        cal.sunrise_sunset_string(abs(9, 27, 2026), 40.7, -74.0, o)
      )
      eq(
        "Sunrise 7:04am (EST), sunset 4:28pm (EST) at 40.7N, 74.0W (9:23 hrs daylight)",
        cal.sunrise_sunset_string(abs(12, 3, 2025), 40.7, -74.0, o)
      )
      eq(
        "No sunrise, no sunset at 78.2N, 15.6E (24:00 hrs daylight)",
        cal.sunrise_sunset_string(abs(6, 21, 2026), 78.2, 15.6, o)
      )
      eq(
        "No sunrise, no sunset at 78.2N, 15.6E (0:00 hrs daylight)",
        cal.sunrise_sunset_string(abs(12, 21, 2026), 78.2, 15.6, o)
      )
      eq(
        "No sunrise, sunset 2:53am (EDT) at Sydney (9:51 hrs daylight)",
        cal.sunrise_sunset_string(abs(6, 21, 2026), -33.9, 151.2, { zone = zone, location = "Sydney" })
      )
    end)
  end)

  it("lists the holidays of the three months like calendar-list-holidays", function()
    with_tz("America/New_York", function()
      require("org.agenda.holidays").reset()
      local defaults = require("org.config").defaults.agenda.holidays
      local title, lines = cal.holidays_lines(abs(9, 27, 2026), defaults)
      eq("Notable Dates from August to October, 2026", title)
      eq({
        "Monday, September 7, 2026: Labor Day",
        "Saturday, September 12, 2026: Rosh HaShanah 5787",
        "Monday, September 21, 2026: Yom Kippur",
        "Tuesday, September 22, 2026: Autumnal Equinox 8:04pm (EDT)",
        "Saturday, September 26, 2026: Sukkot",
        "Saturday, October 3, 2026: Shemini Atzeret",
        "Sunday, October 4, 2026: Simchat Torah",
        "Monday, October 12, 2026: Columbus Day",
        "Saturday, October 31, 2026: Halloween",
      }, lines)
      title, lines = cal.holidays_lines(abs(12, 3, 2025), defaults)
      eq("Notable Dates from November, 2025 to January, 2026", title)
      eq({
        "Sunday, November 2, 2025: Daylight Saving Time Ends 2:00am (EDT)",
        "Tuesday, November 11, 2025: Veteran's Day",
        "Thursday, November 27, 2025: Thanksgiving",
        "Monday, December 15, 2025: Hanukkah",
        "Sunday, December 21, 2025: Winter Solstice 10:02am (EST)",
        "Thursday, December 25, 2025: Christmas",
        "Thursday, January 1, 2026: New Year's Day",
        "Monday, January 19, 2026: Martin Luther King Day",
      }, lines)
      require("org.agenda.holidays").reset()
    end)
  end)
end)

describe("agenda calendars: agenda keys", function()
  local config = require("org.config")
  local utils = require("org.utils")
  local view = require("org.agenda.view")
  local agenda = require("org.agenda")
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/c.org"

  local function open(opts, spec)
    utils.writefile(path, { "* TODO Task", "  <2026-09-27 Sun>" })
    config.setup(vim.tbl_deep_extend("force", { agenda_files = { path }, org_directory = dir }, opts or {}))
    config.opts.clock.persist = false
    if spec then
      agenda.open(spec)
    else
      agenda.open_agenda({ span = "day", anchor = require("org.date").days_from_civil(2026, 9, 27) })
    end
  end

  after_each(function()
    pcall(view.quit, true)
    config.setup({})
  end)

  it("maps gC, M, S and H in the agenda buffer", function()
    open()
    for _, lhs in ipairs({ "gC", "M", "S", "H" }) do
      ok(vim.fn.maparg(lhs, "n") ~= "", lhs)
    end
  end)

  it("shows the date at point in other calendars", function()
    open()
    local l = next(view.state.day_lines)
    vim.api.nvim_win_set_cursor(0, { l, 0 })
    local buf, win = view.convert_date()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    eq("Gregorian:  Sunday, September 27, 2026", lines[1])
    eq("Persian:    Mehr 5, 1405", lines[13])
    vim.api.nvim_win_close(win, true)
  end)

  it("gives sunrise and sunset at the configured location", function()
    open({ agenda = { calendar_latitude = 40.7, calendar_longitude = -74.0, calendar_location_name = "NYC" } })
    local msg = view.sunrise_sunset()
    local pat = "^Sep 27, 2026: Sunrise %d+:%d%dam %(.-%), sunset %d+:%d%dpm %(.-%) at NYC %(11:5%d hrs daylight%)$"
    ok(msg:match(pat), msg)
  end)

  it("lists moon phases and holidays in a float", function()
    open()
    local saved = vim.env.TZ
    vim.env.TZ = "America/New_York"
    solar.reset()
    local okp, buf, win = pcall(view.phases_of_moon)
    vim.env.TZ = saved
    solar.reset()
    assert(okp, buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    eq(12, #lines)
    eq("Wednesday, August 5, 2026: Last Quarter Moon 10:28pm (EDT)", lines[1])
    vim.api.nvim_win_close(win, true)
    buf, win = view.holidays()
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    eq("Monday, September 7, 2026: Labor Day", lines[1])
    vim.api.nvim_win_close(win, true)
  end)

  it("needs a date at point", function()
    open(nil, { blocks = { { type = "todo" } } })
    local errors = {}
    local orig = utils.error
    utils.error = function(m)
      errors[#errors + 1] = m
    end
    local r = view.convert_date()
    utils.error = orig
    eq(nil, r)
    eq({ "Don't know which date to convert" }, errors)
  end)
end)
