---@mod org.agenda.holidays.hebrew Hebrew calendar holidays (port of Emacs's cal-hebrew.el)
---
--- See org.agenda.holidays.julian for the calendar-window emulation: every
--- function returns the entries Emacs's `calendar-check-holidays` finds on the
--- days of the given Gregorian year, sorted by day. `opts.all` is
--- `calendar-hebrew-all-holidays-flag`.

local julian = require("org.agenda.holidays.julian")

local C = julian.calendar
local floor = math.floor

local M = {}

---------------------------------------------------------------------------
-- Hebrew calendar

--- calendar-hebrew-leap-year-p
---@param year integer
---@return boolean
local function leap_year_p(year)
  return (1 + 7 * year) % 19 < 7
end

--- calendar-hebrew-last-month-of-year
---@param year integer
---@return integer
local function last_month_of_year(year)
  return leap_year_p(year) and 13 or 12
end

local elapsed_cache = {}

--- calendar-hebrew-elapsed-days: days to the mean conjunction of Tishri of YEAR.
---@param year integer
---@return integer
local function elapsed_days(year)
  local cached = elapsed_cache[year]
  if cached then
    return cached
  end
  local months_elapsed = 235 * floor((year - 1) / 19) + 12 * ((year - 1) % 19) + floor((1 + 7 * ((year - 1) % 19)) / 19)
  local parts_elapsed = 204 + 793 * (months_elapsed % 1080)
  local hours_elapsed = 5 + 12 * months_elapsed + 793 * floor(months_elapsed / 1080) + floor(parts_elapsed / 1080)
  local parts = 1080 * (hours_elapsed % 24) + parts_elapsed % 1080
  local day = 1 + 29 * months_elapsed + floor(hours_elapsed / 24)
  local alternative_day = day
  if
    parts >= 19440
    or (day % 7 == 2 and parts >= 9924 and not leap_year_p(year))
    or (day % 7 == 1 and parts >= 16789 and leap_year_p(year - 1))
  then
    alternative_day = day + 1
  end
  local wday = alternative_day % 7
  local res = (wday == 0 or wday == 3 or wday == 5) and alternative_day + 1 or alternative_day
  elapsed_cache[year] = res
  return res
end

--- calendar-hebrew-days-in-year
local function days_in_year(year)
  return elapsed_days(year + 1) - elapsed_days(year)
end

--- calendar-hebrew-last-day-of-month
---@param month integer
---@param year integer
---@return integer
local function last_day_of_month(month, year)
  if
    month == 2
    or month == 4
    or month == 6
    or month == 10
    or month == 13
    or (month == 12 and not leap_year_p(year))
    or (month == 8 and days_in_year(year) % 10 ~= 5) -- not calendar-hebrew-long-heshvan-p
    or (month == 9 and days_in_year(year) % 10 == 3) -- calendar-hebrew-short-kislev-p
  then
    return 29
  end
  return 30
end

--- calendar-hebrew-to-absolute
---@param month integer
---@param day integer
---@param year integer
---@return integer
function M.to_absolute(month, day, year)
  local sum = 0
  if month < 7 then
    for m = 7, last_month_of_year(year) do
      sum = sum + last_day_of_month(m, year)
    end
    for m = 1, month - 1 do
      sum = sum + last_day_of_month(m, year)
    end
  else
    for m = 7, month - 1 do
      sum = sum + last_day_of_month(m, year)
    end
  end
  return day + sum + elapsed_days(year) - 1373429
end

local FIRST_MONTH = { 9, 10, 11, 12, 1, 2, 3, 4, 7, 7, 7, 8 }

--- calendar-hebrew-from-absolute
---@param abs integer
---@return integer month, integer day, integer year
function M.from_absolute(abs)
  local gy, gm = C.gregorian_from_absolute(abs)
  local year = 3760 + gy
  local month = FIRST_MONTH[gm]
  while abs >= M.to_absolute(7, 1, year + 1) do
    year = year + 1
  end
  local length = last_month_of_year(year)
  while abs > M.to_absolute(month, last_day_of_month(month, year), year) do
    month = 1 + month % length
  end
  return month, 1 + abs - M.to_absolute(month, 1, year), year
end

---------------------------------------------------------------------------
-- Holidays (the *-window functions evaluate Emacs's function in a window)

--- holiday-hebrew, for a calendar window (calendar-hebrew-date-is-visible-p).
---@param w org.holidays.Window
---@param month integer
---@param day integer
---@param name string
---@return {[1]: integer, [2]: string}[]
function M.holiday_hebrew_window(w, month, day, name)
  local visible = C.month_visible_p(w, month, 6)
  if not visible or #visible == 0 then
    return {}
  end
  return C.named(C.nongregorian_date_visible_p(w, month, day, M.to_absolute, M.from_absolute, 7), name)
end

--- Concatenation of lists (mapcan / append).
local function append(res, list)
  for _, h in ipairs(list) do
    res[#res + 1] = h
  end
  return res
end

--- holiday-hebrew-rosh-hashanah-1
local function rosh_hashanah_1(y, all)
  local r = M.to_absolute(7, 1, y + 3761)
  local list = {
    { r, string.format("Rosh HaShanah %d", 3761 + y) },
    { r + 9, "Yom Kippur" },
    { r + 14, "Sukkot" },
    { r + 21, "Shemini Atzeret" },
    { r + 22, "Simchat Torah" },
  }
  if all then
    append(list, {
      { C.dayname_on_or_before(6, r - 4), "Selichot (night)" },
      { r - 1, "Erev Rosh HaShanah" },
      { r + 1, "Rosh HaShanah (second day)" },
      { r + (r % 7 == 4 and 3 or 2), "Tzom Gedaliah" },
      { C.dayname_on_or_before(6, 7 + r), "Shabbat Shuvah" },
      { r + 8, "Erev Yom Kippur" },
      { r + 13, "Erev Sukkot" },
      { r + 15, "Sukkot (second day)" },
      { r + 16, "Hol Hamoed Sukkot (first day)" },
      { r + 17, "Hol Hamoed Sukkot (second day)" },
      { r + 18, "Hol Hamoed Sukkot (third day)" },
      { r + 19, "Hol Hamoed Sukkot (fourth day)" },
      { r + 20, "Hoshanah Rabbah" },
    })
  end
  return list
end

--- holiday-hebrew-hanukkah-1
local function hanukkah_1(y, all)
  local _, _, h_y = M.from_absolute(C.absolute_from_gregorian(y, 11, 30))
  local h = M.to_absolute(9, 25, h_y)
  if not all then
    return { { h, "Hanukkah" } }
  end
  local ord = { "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth" }
  local list = { { h - 1, "Erev Hanukkah" } }
  for i = 0, 7 do
    list[#list + 1] = { h + i, string.format("Hanukkah (%s day)", ord[i + 1]) }
  end
  return list
end

--- holiday-hebrew-passover-1
local function passover_1(y, all)
  local p = M.to_absolute(1, 15, y + 3760)
  local list = {
    { p, "Passover" },
    { p + 50, "Shavuot" },
  }
  if all then
    local wday = p % 7
    local yom_haatzmaut
    if wday == 0 then
      yom_haatzmaut = 18 -- Sat
    elseif wday == 6 then
      yom_haatzmaut = 19 -- Fri
    elseif wday == 2 then
      yom_haatzmaut = 21 -- Mon
    else
      yom_haatzmaut = 20
    end
    append(list, {
      { C.dayname_on_or_before(6, p - 43), "Shabbat Shekalim" },
      { C.dayname_on_or_before(6, p - 30), "Shabbat Zachor" },
      { p - (wday == 2 and 33 or 31), "Fast of Esther" },
      { p - 31, "Erev Purim" },
      { p - 30, "Purim" },
      { p - (wday == 0 and 28 or 29), "Shushan Purim" },
      { C.dayname_on_or_before(6, p - 14) - 7, "Shabbat Parah" },
      { C.dayname_on_or_before(6, p - 14), "Shabbat HaHodesh" },
      { C.dayname_on_or_before(6, p - 1), "Shabbat HaGadol" },
      { p - 1, "Erev Passover" },
      { p + 1, "Passover (second day)" },
      { p + 2, "Hol Hamoed Passover (first day)" },
      { p + 3, "Hol Hamoed Passover (second day)" },
      { p + 4, "Hol Hamoed Passover (third day)" },
      { p + 5, "Hol Hamoed Passover (fourth day)" },
      { p + 6, "Passover (seventh day)" },
      { p + 7, "Passover (eighth day)" },
      { p + ((p + 12) % 7 == 0 and 13 or 12), "Yom HaShoah" },
      { p + yom_haatzmaut, "Yom HaAtzma'ut" },
      { p + 33, "Lag BaOmer" },
      { p + 43, "Yom Yerushalaim" },
      { p + 49, "Erev Shavuot" },
      { p + 51, "Shavuot (second day)" },
    })
  end
  return list
end

--- Runs FN_1 for each of YEARS and keeps the visible entries (the common
--- shape of holiday-hebrew-rosh-hashanah, -passover, -hanukkah, -tisha-b-av).
local function mapcan_filter(w, years, fn_1, all)
  local list = {}
  for _, y in ipairs(years) do
    append(list, fn_1(y, all))
  end
  return C.filter_visible(w, list)
end

--- holiday-hebrew-rosh-hashanah, for a calendar window.
function M.rosh_hashanah_window(w, all)
  return mapcan_filter(w, C.month_visible_p(w, 8, 2), rosh_hashanah_1, all)
end

--- holiday-hebrew-hanukkah, for a calendar window.
function M.hanukkah_window(w, all)
  local years = C.month_visible_p(w, 11, 1) --[[@as integer[] ]]
  local y = C.month_visible_p(w, 1) --[[@as integer?]]
  if y and not vim.tbl_contains(years, y - 1) then
    table.insert(years, 1, y - 1)
  end
  return mapcan_filter(w, years, hanukkah_1, all)
end

--- holiday-hebrew-passover, for a calendar window.
function M.passover_window(w, all)
  return mapcan_filter(w, C.month_visible_p(w, 2, 4), passover_1, all)
end

--- holiday-hebrew-tisha-b-av (lambda of the mapcan)
local function tisha_b_av_1(y)
  local t = M.to_absolute(5, 9, y + 3760)
  local wday = t % 7
  return {
    { t - (wday == 6 and 20 or 21), "Tzom Tammuz" },
    { C.dayname_on_or_before(6, t), "Shabbat Hazon" },
    { wday == 6 and t + 1 or t, "Tisha B'Av" },
    { C.dayname_on_or_before(6, t + 7), "Shabbat Nahamu" },
  }
end

--- holiday-hebrew-tisha-b-av, for a calendar window.
function M.tisha_b_av_window(w)
  return mapcan_filter(w, C.month_visible_p(w, 6, 2), tisha_b_av_1)
end

--- holiday-hebrew-misc, for a calendar window. The days of Tal Umatar, Tzom
--- Teveth and Shabbat Shirah are computed from displayed-month, like Emacs.
function M.misc_window(w)
  local list = {}
  -- "Tal Umatar" (evening): Julian 11/21, or 11/22 before a Julian leap year
  local m, y = C.increment_month(w.month, w.year, -1)
  local _, _, year = julian.from_absolute(C.absolute_from_gregorian(y, m, 1))
  local tal_day = (year + 1) % 4 == 0 and 22 or 21
  append(list, julian.holiday_julian_window(w, 11, tal_day, '"Tal Umatar" (evening)'))
  -- Tzom Teveth: Tevet 10, or 11 when the 10th is a Saturday
  local _, _, h_year = M.from_absolute(C.absolute_from_gregorian(w.year, w.month, 28))
  local teveth_day = M.to_absolute(10, 10, h_year) % 7 == 6 and 11 or 10
  append(list, M.holiday_hebrew_window(w, 10, teveth_day, "Tzom Teveth"))
  append(list, M.holiday_hebrew_window(w, 11, 15, "Tu B'Shevat"))
  -- Shabbat Shirah: the Saturday on or before Shevat 16 (17 when Rosh HaShanah is a Saturday)
  m, y = C.increment_month(w.month, w.year, 1)
  _, _, h_year = M.from_absolute(C.absolute_from_gregorian(y, m, C.last_day_of_month(m, y)))
  local shevat = M.to_absolute(7, 1, h_year) % 7 == 6 and 17 or 16
  local _, shirah_day = M.from_absolute(C.dayname_on_or_before(6, M.to_absolute(11, shevat, h_year)))
  append(list, M.holiday_hebrew_window(w, 11, shirah_day, "Shabbat Shirah"))
  -- Kiddush HaHamah: Julian 3/26 of the years 21 (mod 28) of the solar cycle
  m, y = C.increment_month(w.month, w.year, -1)
  _, _, year = julian.from_absolute(C.absolute_from_gregorian(y, m, 1))
  if year % 28 == 21 then
    append(list, julian.holiday_julian_window(w, 3, 26, "Kiddush HaHamah"))
  end
  return list
end

---------------------------------------------------------------------------
-- Public API: entries in a Gregorian year

---@class org.holidays.Opts
---@field all? boolean calendar-hebrew-all-holidays-flag

--- holiday-hebrew MONTH DAY STRING: the Gregorian dates in YEAR of Hebrew MONTH DAY.
---@param year integer Gregorian year
---@param month integer Hebrew month (1 = Nisan, 7 = Tishri, 13 = Adar II)
---@param day integer
---@param name string
---@return org.HolidayEntry[]
function M.holiday_hebrew(year, month, day, name)
  return C.for_year(year, function(w)
    return M.holiday_hebrew_window(w, month, day, name)
  end)
end

--- holiday-hebrew-passover
---@param year integer
---@param opts? org.holidays.Opts
---@return org.HolidayEntry[]
function M.passover(year, opts)
  local all = (opts or {}).all and true or false
  return C.for_year(year, function(w)
    return M.passover_window(w, all)
  end)
end

--- holiday-hebrew-rosh-hashanah
---@param year integer
---@param opts? org.holidays.Opts
---@return org.HolidayEntry[]
function M.rosh_hashanah(year, opts)
  local all = (opts or {}).all and true or false
  return C.for_year(year, function(w)
    return M.rosh_hashanah_window(w, all)
  end)
end

--- holiday-hebrew-hanukkah
---@param year integer
---@param opts? org.holidays.Opts
---@return org.HolidayEntry[]
function M.hanukkah(year, opts)
  local all = (opts or {}).all and true or false
  return C.for_year(year, function(w)
    return M.hanukkah_window(w, all)
  end)
end

--- holiday-hebrew-tisha-b-av (does not depend on the all-holidays flag)
---@param year integer
---@param opts? org.holidays.Opts
---@return org.HolidayEntry[]
function M.tisha_b_av(year, opts)
  local _ = opts
  return C.for_year(year, M.tisha_b_av_window)
end

--- holiday-hebrew-misc (does not depend on the all-holidays flag)
---@param year integer
---@param opts? org.holidays.Opts
---@return org.HolidayEntry[]
function M.misc(year, opts)
  local _ = opts
  return C.for_year(year, M.misc_window)
end

return M
