-- Astronomical holidays (org.agenda.holidays.{astro,solar,chinese,bahai}).
--
-- Every expected value below was produced by Emacs 31 in batch mode:
--  * the raw floats with `(solar-equinoxes/solstices ...)`, `(solar-longitude ...)`,
--    `(lunar-new-moon-time ...)`, ... printed with `%S` (shortest round-trip form,
--    compared here with exact float equality);
--  * the holiday entries by evaluating the holiday form in the window that
--    `calendar-check-holidays' binds for each month of the year
--    (displayed-month = next month, calendar-total-months = 1) and keeping the
--    entries of that month, with the process TZ set as noted.
-- The full 1950-2100 comparison (every function, both flag values, 21 time
-- zones) was run the same way and matched line for line.
local astro = require("org.agenda.holidays.astro")
local solar = require("org.agenda.holidays.solar")
local chinese = require("org.agenda.holidays.chinese")
local bahai = require("org.agenda.holidays.bahai")
local date = require("org.date")

-- "YYYY-MM-DD|name" lines of a list of entries.
local function render(entries)
  local out = {}
  for _, e in ipairs(entries) do
    local y, m, d = date.civil_from_days(e.day)
    out[#out + 1] = string.format("%04d-%02d-%02d|%s", y, m, d, e.name)
  end
  return out
end

-- A zone with no DST, TZ minutes from UTC.
local function fixed_zone(tz, name)
  return { tz = tz, dst_offset = 0, std_name = name, dst_name = name, starts_time = 0, ends_time = 0 }
end

-- 2026-09-25 12:00 UTC: the "now" the Emacs runs probed the zone at.
local NOW = 1790337600

-- Run FN with the process time zone set to TZ (os.date follows it).
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

describe("holidays astro", function()
  it("reproduces Emacs's floats bit for bit", function()
    local china = fixed_zone(480, "CST")
    local m, d, y = astro.equinoxes_solstices(0, 0, 2026)
    eq({ 3, 20.614215063862503, 2026 }, { m, d, y })
    m, d, y = astro.equinoxes_solstices(480, 3, 2033)
    eq({ 12, 21.905841486373294, 2033 }, { m, d, y })
    eq(238.3344638393919, astro.solar_longitude(china, 2461000.25))
    eq(2461001.898827394, astro.date_next_longitude(china, 2461000.25, 30))
    eq(2461294.642906505, astro.new_moon_time(fixed_zone(0, "UTC"), 330))
    eq(2461029.904166667, astro.new_moon_on_or_after(china, 2461000.25))
    local rise, set = astro.sunrise_sunset(fixed_zone(210, "IRST"), 35.6892, 51.3890, 3, 20, 2026)
    eq({ 6.1499999994412065, 18.249999999068677 }, { rise, set })
    eq(0.00039062844004659515, astro.ephemeris_correction(1960))
    eq(0.000775462962962963, astro.ephemeris_correction(2000))
    eq(0.0019930308795194844, astro.ephemeris_correction(2050))
    eq(8.461254094840995e-05, astro.ephemeris_correction(1850))
  end)

  it("formats times like solar-time-string", function()
    eq("8:44am (CST)", astro.time_string(8 + 44 / 60, "CST"))
    eq("12:00am (UTC)", astro.time_string(0, "UTC"))
    eq("12:30pm", astro.time_string(12.5))
    eq("12:00pm", astro.time_string(23.999))
  end)
end)

describe("holidays solar", function()
  it("gives equinoxes and solstices in a fixed zone", function()
    eq({
      "2026-03-20|Vernal Equinox 2:44pm (UTC)",
      "2026-06-21|Summer Solstice 8:24am (UTC)",
      "2026-09-23|Autumnal Equinox 12:04am (UTC)",
      "2026-12-21|Winter Solstice 8:49pm (UTC)",
    }, render(solar.equinoxes_solstices(2026, { zone = fixed_zone(0, "UTC") })))
    eq({
      "2026-03-20|Vernal Equinox 8:14pm (IST)",
      "2026-06-21|Summer Solstice 1:54pm (IST)",
      "2026-09-23|Autumnal Equinox 5:34am (IST)",
      "2026-12-22|Winter Solstice 2:19am (IST)",
    }, render(solar.equinoxes_solstices(2026, { zone = fixed_zone(330, "IST") })))
    eq({}, solar.dst(2026, { zone = fixed_zone(0, "UTC") }))
  end)

  it("uses southern hemisphere names for a negative latitude", function()
    local names = vim.tbl_map(function(e)
      return e.name
    end, solar.equinoxes_solstices(2026, { zone = fixed_zone(0, "UTC"), latitude = -33.9 }))
    eq("Autumnal Equinox 2:44pm (UTC)", names[1])
    eq("Summer Solstice 8:49pm (UTC)", names[4])
  end)

  it("follows the system zone and its DST rules (TZ=America/New_York)", function()
    with_tz("America/New_York", function(zone)
      eq(-300, zone.tz)
      eq(60, zone.dst_offset)
      eq({
        "2024-03-19|Vernal Equinox 11:06pm (EDT)",
        "2024-06-20|Summer Solstice 4:50pm (EDT)",
        "2024-09-22|Autumnal Equinox 8:43am (EDT)",
        "2024-12-21|Winter Solstice 4:19am (EST)",
      }, render(solar.equinoxes_solstices(2024, { zone = zone })))
      eq({
        "2024-03-10|Daylight Saving Time Begins 2:00am (EST)",
        "2024-11-03|Daylight Saving Time Ends 2:00am (EDT)",
      }, render(solar.dst(2024, { zone = zone })))
      -- The DST dates of each year come from that year's transitions.
      eq({
        "1970-04-26|Daylight Saving Time Begins 2:00am (EST)",
        "1970-10-25|Daylight Saving Time Ends 2:00am (EDT)",
      }, render(solar.dst(1970, { zone = zone })))
      eq("1970-06-21|Summer Solstice 3:43pm (EDT)", render(solar.equinoxes_solstices(1970, { zone = zone }))[2])
    end)
  end)

  it("keeps past DST entries of a zone without DST today (TZ=America/Mexico_City)", function()
    with_tz("America/Mexico_City", function(zone)
      eq(0, zone.dst_offset)
      eq({
        "2022-04-03|Daylight Saving Time Begins 12:00am (CST)",
        "2022-10-30|Daylight Saving Time Ends 12:00am (CST)",
      }, render(solar.dst(2022, { zone = zone })))
      eq({}, solar.dst(2023, { zone = zone }))
      eq("2023-09-23|Autumnal Equinox 12:49am (CST)", render(solar.equinoxes_solstices(2023, { zone = zone }))[3])
    end)
  end)

  it("handles southern hemisphere DST (TZ=Australia/Sydney)", function()
    with_tz("Australia/Sydney", function(zone)
      eq({
        "2026-03-21|Vernal Equinox 1:44am (AEDT)",
        "2026-06-21|Summer Solstice 6:24pm (AEST)",
        "2026-09-23|Autumnal Equinox 10:04am (AEST)",
        "2026-12-22|Winter Solstice 7:49am (AEDT)",
      }, render(solar.equinoxes_solstices(2026, { zone = zone })))
      eq({
        "2026-10-04|Daylight Saving Time Begins 2:00am (AEST)",
        "2026-04-05|Daylight Saving Time Ends 3:00am (AEDT)",
      }, render(solar.dst(2026, { zone = zone })))
    end)
  end)
end)

describe("holidays chinese", function()
  it("computes the new year and fixed-date festivals", function()
    eq({ "2026-02-17|Chinese New Year (Bing-Wu)" }, render(chinese.new_year(2026)))
    eq({ "1985-02-20|Chinese New Year (Yi-Chou)" }, render(chinese.new_year(1985)))
    eq({ "2100-02-09|Chinese New Year (Geng-Shen)" }, render(chinese.new_year(2100)))
    eq({ "2026-09-25|Mid-Autumn Festival" }, render(chinese.holiday_chinese(2026, 8, 15, "Mid-Autumn Festival")))
    eq({ "1985-03-06|Lantern Festival" }, render(chinese.holiday_chinese(1985, 1, 15, "Lantern Festival")))
    eq({ "2026-04-04|Qingming Festival" }, render(chinese.qingming(2026)))
    eq({ "2033-12-21|Winter Solstice Festival" }, render(chinese.winter_solstice(2033)))
  end)

  it("computes years outside Emacs's precomputed cache the same way", function()
    local months = chinese.chinese_year(2050)
    eq(13, #months)
    eq({ 12, 748376 }, months[1])
    eq({ 3.5, 748493 }, months[5])
    eq({ 11, 748730 }, months[13])
  end)

  it("reproduces Emacs's window quirks", function()
    -- Day 30 of a 29-day month rolls into the next month (here: new year's day).
    eq({ "2026-02-17|C 12 30" }, render(chinese.holiday_chinese(2026, 12, 30, "C 12 30")))
    -- Twice in one Gregorian year.
    eq({ "2100-01-10|C 12 1", "2100-12-31|C 12 1" }, render(chinese.holiday_chinese(2100, 12, 1, "C 12 1")))
    eq({ "2007-01-08|C 11 20", "2007-12-29|C 11 20" }, render(chinese.holiday_chinese(2007, 11, 20, "C 11 20")))
    -- 2033: the leap month after month 11 (Emacs's precomputed 2034 starts with 11.5).
    eq({ "2033-12-11|C 11 20" }, render(chinese.holiday_chinese(2033, 11, 20, "C 11 20")))
    eq({ "2034-01-20|C 12 1" }, render(chinese.holiday_chinese(2034, 12, 1, "C 12 1")))
  end)
end)

describe("holidays bahai", function()
  it("computes Naw-Ruz before and after the 172 BE reform", function()
    eq({ "2014-03-21|Bahá’í New Year (Naw-Ruz) 171" }, render(bahai.new_year(2014)))
    eq({ "2026-03-21|Bahá’í New Year (Naw-Ruz) 183" }, render(bahai.new_year(2026)))
    eq({ "2060-03-20|Bahá’í New Year (Naw-Ruz) 217" }, render(bahai.new_year(2060)))
  end)

  it("computes the Twin Holy Birthdays", function()
    local function twin(bab, baha)
      return { bab .. "|Birth of the Báb", baha .. "|Birth of Bahá’u’lláh" }
    end
    -- Fixed dates before 172 BE, the eighth new moon after Naw-Ruz since.
    eq(twin("2014-10-20", "2014-11-12"), render(bahai.twin_holy_birthdays(2014)))
    eq(twin("2015-11-13", "2015-11-14"), render(bahai.twin_holy_birthdays(2015)))
    eq(twin("2033-10-24", "2033-10-25"), render(bahai.twin_holy_birthdays(2033)))
  end)

  it("respects the all flag of Ridvan", function()
    eq({
      "2026-04-21|First Day of Ridvan",
      "2026-04-29|Ninth Day of Ridvan",
      "2026-05-02|Twelfth Day of Ridvan",
    }, render(bahai.ridvan(2026)))
    local all = render(bahai.ridvan(2026, { all = true }))
    eq(12, #all)
    eq("2026-04-22|Second Day of Ridvan", all[2])
    eq("2026-05-02|Twelfth Day of Ridvan", all[12])
  end)

  it("maps Bahá’í dates like holiday-bahai", function()
    eq({ "2026-05-24|Declaration of the Báb" }, render(bahai.holiday_bahai(2026, 4, 8, "Declaration of the Báb")))
    eq({ "2026-11-26|Day of the Covenant" }, render(bahai.holiday_bahai(2026, 14, 4, "Day of the Covenant")))
    eq({ "2026-02-25|Ayyam-i-Ha" }, render(bahai.holiday_bahai(2026, 19, -3, "Ayyam-i-Ha")))
    eq(740037, bahai.to_absolute(19, -3, 183))
    eq({ 1, 5, 183 }, { bahai.from_absolute(739700) })
  end)
end)
