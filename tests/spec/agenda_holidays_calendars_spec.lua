-- Hebrew, Islamic and Julian holiday calendars (org.agenda.holidays.hebrew,
-- .islamic, .julian). The expected entries below were produced by Emacs 31 in
-- batch, evaluating each holiday function the way `calendar-check-holidays`
-- (used by `org-calendar-holiday`) does: for every month, displayed-month =
-- month + 1 and calendar-total-months = 1, then `calendar-holiday-list`,
-- keeping the entries of that month. The whole 1900-2100 range of every
-- function (both values of calendar-hebrew-all-holidays-flag) was compared
-- with Emacs during development; these are samples of that output.
local hebrew = require("org.agenda.holidays.hebrew")
local islamic = require("org.agenda.holidays.islamic")
local julian = require("org.agenda.holidays.julian")
local date = require("org.date")

local ALL = { all = true }

local CASES = {
  passover0 = function(y)
    return hebrew.passover(y)
  end,
  passover1 = function(y)
    return hebrew.passover(y, ALL)
  end,
  rosh0 = function(y)
    return hebrew.rosh_hashanah(y, {})
  end,
  rosh1 = function(y)
    return hebrew.rosh_hashanah(y, ALL)
  end,
  hanukkah0 = function(y)
    return hebrew.hanukkah(y)
  end,
  hanukkah1 = function(y)
    return hebrew.hanukkah(y, ALL)
  end,
  tisha = function(y)
    return hebrew.tisha_b_av(y)
  end,
  misc = function(y)
    return hebrew.misc(y)
  end,
  isl_ny = function(y)
    return islamic.new_year(y)
  end,
  isl_9_1 = function(y)
    return islamic.holiday_islamic(y, 9, 1, "I9-1")
  end,
  jul_12_25 = function(y)
    return julian.holiday_julian(y, 12, 25, "J12-25")
  end,
  jul_1_1 = function(y)
    return julian.holiday_julian(y, 1, 1, "J1-1")
  end,
  greek = function(y)
    return julian.greek_orthodox_easter(y)
  end,
  greek_m2 = function(y)
    return julian.greek_orthodox_easter(y, -2, "Good Friday")
  end,
  heb_13_14 = function(y)
    return hebrew.holiday_hebrew(y, 13, 14, "H13-14")
  end,
  heb_8_30 = function(y)
    return hebrew.holiday_hebrew(y, 8, 30, "H8-30")
  end,
}

-- "== CASE YEAR" headers followed by "YYYY-MM-DD|NAME" lines, in the order
-- Emacs lists them (by date; same-day entries in the function's order).
local EMACS = [==[
== passover0 2026
2026-04-02|Passover
2026-05-22|Shavuot
== passover1 2026
2026-02-14|Shabbat Shekalim
2026-02-28|Shabbat Zachor
2026-03-02|Fast of Esther
2026-03-02|Erev Purim
2026-03-03|Purim
2026-03-04|Shushan Purim
2026-03-07|Shabbat Parah
2026-03-14|Shabbat HaHodesh
2026-03-28|Shabbat HaGadol
2026-04-01|Erev Passover
2026-04-02|Passover
2026-04-03|Passover (second day)
2026-04-04|Hol Hamoed Passover (first day)
2026-04-05|Hol Hamoed Passover (second day)
2026-04-06|Hol Hamoed Passover (third day)
2026-04-07|Hol Hamoed Passover (fourth day)
2026-04-08|Passover (seventh day)
2026-04-09|Passover (eighth day)
2026-04-14|Yom HaShoah
2026-04-22|Yom HaAtzma'ut
2026-05-05|Lag BaOmer
2026-05-15|Yom Yerushalaim
2026-05-21|Erev Shavuot
2026-05-22|Shavuot
2026-05-23|Shavuot (second day)
== rosh0 2026
2026-09-12|Rosh HaShanah 5787
2026-09-21|Yom Kippur
2026-09-26|Sukkot
2026-10-03|Shemini Atzeret
2026-10-04|Simchat Torah
== rosh1 2026
2026-09-05|Selichot (night)
2026-09-11|Erev Rosh HaShanah
2026-09-12|Rosh HaShanah 5787
2026-09-13|Rosh HaShanah (second day)
2026-09-14|Tzom Gedaliah
2026-09-19|Shabbat Shuvah
2026-09-20|Erev Yom Kippur
2026-09-21|Yom Kippur
2026-09-25|Erev Sukkot
2026-09-26|Sukkot
2026-09-27|Sukkot (second day)
2026-09-28|Hol Hamoed Sukkot (first day)
2026-09-29|Hol Hamoed Sukkot (second day)
2026-09-30|Hol Hamoed Sukkot (third day)
2026-10-01|Hol Hamoed Sukkot (fourth day)
2026-10-02|Hoshanah Rabbah
2026-10-03|Shemini Atzeret
2026-10-04|Simchat Torah
== hanukkah0 2026
2026-12-05|Hanukkah
== hanukkah1 2024
2024-12-25|Erev Hanukkah
2024-12-26|Hanukkah (first day)
2024-12-27|Hanukkah (second day)
2024-12-28|Hanukkah (third day)
2024-12-29|Hanukkah (fourth day)
2024-12-30|Hanukkah (fifth day)
2024-12-31|Hanukkah (sixth day)
== hanukkah1 2025
2025-01-01|Hanukkah (seventh day)
2025-01-02|Hanukkah (eighth day)
2025-12-14|Erev Hanukkah
2025-12-15|Hanukkah (first day)
2025-12-16|Hanukkah (second day)
2025-12-17|Hanukkah (third day)
2025-12-18|Hanukkah (fourth day)
2025-12-19|Hanukkah (fifth day)
2025-12-20|Hanukkah (sixth day)
2025-12-21|Hanukkah (seventh day)
2025-12-22|Hanukkah (eighth day)
== tisha 2026
2026-07-02|Tzom Tammuz
2026-07-18|Shabbat Hazon
2026-07-23|Tisha B'Av
2026-07-25|Shabbat Nahamu
== misc 2026
2026-01-31|Shabbat Shirah
2026-02-02|Tu B'Shevat
2026-12-04|"Tal Umatar" (evening)
2026-12-20|Tzom Teveth
== misc 2027
2027-01-23|Tu B'Shevat
2027-01-23|Shabbat Shirah
2027-12-05|"Tal Umatar" (evening)
== misc 2009
2009-01-06|Tzom Teveth
2009-02-07|Shabbat Shirah
2009-02-09|Tu B'Shevat
2009-04-08|Kiddush HaHamah
2009-12-04|"Tal Umatar" (evening)
2009-12-27|Tzom Teveth
== isl_ny 2008
2008-01-10|Islamic New Year 1429
2008-12-29|Islamic New Year 1430
== isl_9_1 2026
2026-02-18|I9-1
== jul_12_25 2026
2026-01-07|J12-25
== jul_1_1 2026
2026-01-14|J1-1
== greek 2026
2026-04-12|Pascha (Greek Orthodox Easter)
== greek_m2 2026
2026-04-10|Good Friday
== heb_13_14 2026
== heb_13_14 2027
2027-03-23|H13-14
== heb_8_30 2016
]==]

local function parse()
  local blocks, cur = {}, nil
  for line in EMACS:gmatch("[^\n]+") do
    local key, year = line:match("^== (%S+) (%d+)$")
    if key then
      cur = { key = key, year = tonumber(year), lines = {} }
      blocks[#blocks + 1] = cur
    else
      table.insert(cur.lines, line)
    end
  end
  return blocks
end

local function render(entries)
  local res = {}
  for _, e in ipairs(entries) do
    local y, m, d = date.civil_from_days(e.day)
    res[#res + 1] = string.format("%04d-%02d-%02d|%s", y, m, d, e.name)
  end
  return res
end

describe("agenda holiday calendars (Emacs-verified)", function()
  for _, b in ipairs(parse()) do
    it(b.key .. " " .. b.year, function()
      eq(b.lines, render(CASES[b.key](b.year)))
    end)
  end

  it("uses the plugin's day numbers", function()
    local e = julian.holiday_julian(2026, 12, 25, "Christmas")
    eq({ { day = date.days_from_civil(2026, 1, 7), name = "Christmas" } }, e)
  end)

  it("Hebrew and Islamic conversions round-trip (Emacs absolute dates)", function()
    -- (calendar-hebrew-from-absolute (calendar-absolute-from-gregorian '(9 12 2026))) => (7 1 5787)
    local abs = date.days_from_civil(2026, 9, 12) + 719163
    eq({ 7, 1, 5787 }, { hebrew.from_absolute(abs) })
    eq(abs, hebrew.to_absolute(7, 1, 5787))
    -- (calendar-islamic-from-absolute ...) of 2026-06-17 => (1 1 1448)
    abs = date.days_from_civil(2026, 6, 17) + 719163
    eq({ 1, 1, 1448 }, { islamic.from_absolute(abs) })
    -- (calendar-julian-from-absolute ...) of 2026-01-07 => (12 25 2025)
    abs = date.days_from_civil(2026, 1, 7) + 719163
    eq({ 12, 25, 2025 }, { julian.from_absolute(abs) })
  end)
end)
