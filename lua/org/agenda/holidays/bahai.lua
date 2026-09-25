---@mod org.agenda.holidays.bahai Bahá’í calendar holidays (cal-bahai.el)
---
--- Ports of `holiday-bahai', `holiday-bahai-new-year', `holiday-bahai-ridvan'
--- and `holiday-bahai-twin-holy-birthdays' of Emacs 31, including the
--- 172 BE (2015) reform: Naw-Rúz follows the vernal equinox as observed from
--- Tehran (before or after sunset) and the Twin Holy Birthdays follow the
--- eighth new moon after Naw-Rúz. All computations use Tehran's time zone
--- (UTC+3:30, no DST), so the results do not depend on the local time zone.
---
--- Each function returns what `calendar-check-holidays' finds for every day of
--- a Gregorian year: the holiday form is evaluated in the one-month window
--- Emacs binds for each month and the entries dated in that month are kept.

local astro = require("org.agenda.holidays.astro")

local M = {}

local floor = math.floor
local idiv = astro.idiv
local EPOCH_ABS = astro.EPOCH_ABS
local ASTRO = astro.ASTRO
local abs_from_greg = astro.absolute_from_gregorian
local greg_from_abs = astro.gregorian_from_absolute

local EPOCH = abs_from_greg(3, 21, 1844) -- calendar-bahai-epoch
local TEHRAN_LAT = 35.6892 -- calendar-bahai-tehran-latitude
local TEHRAN_LON = 51.3890 -- calendar-bahai-tehran-longitude
local REFORM_YEAR = 172 -- calendar-bahai-reform-year
local LEAP_BASE = idiv(1844, 4) - idiv(1844, 100) + idiv(1844, 400) -- calendar-bahai-leap-base

--- Tehran's zone (calendar-bahai-tehran-timezone, DST disabled).
---@type org.agenda.holidays.Zone
local TEHRAN = { tz = 210, dst_offset = 0, std_name = "IRST", dst_name = "IRST", starts_time = 0, ends_time = 0 }

local nawruz_cache = {} ---@type table<integer, integer>

--- calendar-bahai-nawruz-for-gregorian-year, as an absolute date: the vernal
--- equinox day in Tehran if the equinox is more than 2 minutes before sunset,
--- else the next day.
---@param greg_year integer
---@return integer
local function nawruz_for_gregorian_year(greg_year)
  local cached = nawruz_cache[greg_year]
  if cached then
    return cached
  end
  local m, day_frac, y = astro.equinoxes_solstices(TEHRAN.tz, 0, greg_year)
  local d = floor(day_frac)
  local eq_time = 24 * (day_frac - d)
  local _, sunset = astro.sunrise_sunset(TEHRAN, TEHRAN_LAT, TEHRAN_LON, m, d, y)
  local tolerance = 2.0 / 60
  local res = abs_from_greg(m, d, y)
  if not (sunset and eq_time < sunset - tolerance) then
    res = res + 1
  end
  nawruz_cache[greg_year] = res
  return res
end

--- calendar-bahai-nawruz: absolute date of Naw-Rúz of Bahá’í YEAR.
---@param year integer
---@return integer
local function nawruz(year)
  if year < REFORM_YEAR then
    return abs_from_greg(3, 21, year + 1843)
  end
  return nawruz_for_gregorian_year(year + 1843)
end

--- calendar-bahai-leap-year-p
---@param year integer
---@return boolean
local function leap_year_p(year)
  if year < REFORM_YEAR then
    return astro.leap_year_p(year + 1844)
  end
  return nawruz(year + 1) - nawruz(year) == 366
end

--- calendar-bahai-to-absolute (month 19 with DAY <= 0 is Ayyám-i-Há).
---@return integer
local function to_absolute(month, day, year)
  if year < REFORM_YEAR then
    local prior_years = (year - 1) + 1844
    local leap_days = (idiv(prior_years, 4) + -idiv(prior_years, 100) + idiv(prior_years, 400)) - LEAP_BASE
    local extra = 0
    if month == 19 then
      local ayyam = leap_year_p(year) and 5 or 4
      extra = day <= 0 and ayyam - 1 or ayyam
    end
    return (EPOCH - 1) + 365 * (year - 1) + leap_days + 19 * (month - 1) + extra + day
  end
  local year_start = nawruz(year)
  local ayyam = leap_year_p(year) and 5 or 4
  local days
  if month < 19 then
    days = 19 * (month - 1) + day
  elseif day <= 0 then
    days = 19 * 18 + (day + (ayyam - 1))
  else
    days = 19 * 18 + ayyam + day
  end
  return year_start + -1 + days
end

--- calendar-bahai-from-absolute: Bahá’í (month, day, year) of absolute DATE.
---@return integer month
---@return integer day
---@return integer year
local function from_absolute(date)
  if date < EPOCH then
    return 0, 0, 0
  end
  local gm, gd, gy = greg_from_abs(date)
  local year = (gy - 1844) + ((gm > 3 or (gm == 3 and gd >= 15)) and 1 or 0)
  while date < nawruz(year) do
    year = year - 1
  end
  while date >= nawruz(year + 1) do
    year = year + 1
  end
  local days_in_year = date - nawruz(year)
  local ayyam = leap_year_p(year) and 5 or 4
  if days_in_year < 19 * 18 then
    return 1 + idiv(days_in_year, 19), 1 + days_in_year % 19, year
  elseif days_in_year < 19 * 18 + ayyam then
    return 19, (days_in_year - 19 * 18) - (ayyam - 1), year
  end
  return 19, 1 + (days_in_year - 19 * 18 - ayyam), year
end

--- calendar-bahai-twin-holy-birthdays-for-year: absolute dates of the Birth
--- of the Báb and of Bahá’u’lláh in Bahá’í YEAR (>= 172).
local twin_cache = {} ---@type table<integer, integer>
local function twin_holy_birthdays_for_year(bahai_year)
  local cached = twin_cache[bahai_year]
  if cached then
    return cached, cached + 1
  end
  local nawruz_abs = nawruz(bahai_year)
  local nm, nd, ny = greg_from_abs(nawruz_abs)
  local _, sunset0 = astro.sunrise_sunset(TEHRAN, TEHRAN_LAT, TEHRAN_LON, nm, nd, ny)
  local current = (nawruz_abs + ASTRO) + (sunset0 or 18.0) / 24.0
  local eighth
  for _ = 1, 8 do
    current = astro.new_moon_on_or_after(TEHRAN, current)
    eighth = current
    current = current + 1
  end
  local frac_abs = eighth - ASTRO
  local new_moon_abs = floor(frac_abs)
  local hours = 24 * (frac_abs - new_moon_abs)
  local gm, gd, gy = greg_from_abs(new_moon_abs)
  local _, sunset = astro.sunrise_sunset(TEHRAN, TEHRAN_LAT, TEHRAN_LON, gm, gd, gy)
  local bab = (sunset and hours < sunset) and new_moon_abs + 1 or new_moon_abs + 2
  twin_cache[bahai_year] = bab
  return bab, bab + 1
end

---------------------------------------------------------------------------
-- Holiday forms, evaluated in a calendar window
---------------------------------------------------------------------------

--- holiday-filter-visible-calendar over {absolute, name} pairs.
local function filter_visible(w, hlist)
  local res = {}
  for _, h in ipairs(hlist) do
    local m, d, y = greg_from_abs(h[1])
    if astro.date_is_visible_p(w, m, d, y) then
      res[#res + 1] = h
    end
  end
  return res
end

--- calendar-nongregorian-date-visible-p with the Bahá’í conversions (N = 1):
--- absolute dates of Bahá’í MONTH/DAY visible in window W.
local function nongregorian_date_visible(w, month, day)
  local start_date, end_date = astro.date_range_abs(w)
  local m1, _, y1 = from_absolute(start_date)
  local m2, _, y2 = from_absolute(end_date)
  local N = 1
  local years = {}
  local function push(y)
    table.insert(years, 1, y)
  end
  if y1 == y2 then
    if (m1 <= month and month <= m2) or (m1 > m2 and (month >= m1 or month <= m2)) then
      push(y1)
    end
  elseif y1 < y2 then
    for i = 0, y2 - y1 - 2 do
      push(y1 + i + 1)
    end
    if m1 >= N then
      if month >= m1 or month < N then
        push(y1)
      end
      if month <= m2 then
        push(y2)
      end
    else
      if m1 <= month and month < N then
        push(y1)
      end
      if month >= N or month <= m2 then
        push(y2)
      end
    end
  end
  local res = {}
  for _, y in ipairs(years) do
    local a = to_absolute(month, day, y)
    local gm, gd, gy = greg_from_abs(a)
    if astro.date_is_visible_p(w, gm, gd, gy) then
      res[#res + 1] = a
    end
  end
  return res
end

--- holiday-bahai in window W (calendar-total-months is 1, not 3).
local function holiday_bahai_in(w, month, day, name)
  local res = {}
  for i, a in ipairs(nongregorian_date_visible(w, month, day)) do
    res[i] = { a, name }
  end
  return res
end

--- holiday-bahai-new-year-1: the Naw-Rúz entry of Gregorian year Y.
local function new_year_1(y)
  local bahai_year = y - (1844 - 1)
  local date = bahai_year < REFORM_YEAR and abs_from_greg(3, 21, y) or nawruz_for_gregorian_year(y)
  return { date, string.format("Bahá’í New Year (Naw-Ruz) %d", bahai_year) }
end

--- holiday-bahai-new-year in window W.
local function new_year_in(w)
  local hs = { new_year_1(w.y1) }
  if w.y1 ~= w.y2 then
    hs[2] = new_year_1(w.y2)
  end
  return filter_visible(w, hs)
end

--- holiday-bahai-twin-holy-birthdays-1: the entries of Gregorian year Y.
local function twin_1(y, hs)
  local bahai_year = y - (1844 - 1)
  local bab, baha
  if bahai_year >= REFORM_YEAR then
    bab, baha = twin_holy_birthdays_for_year(bahai_year)
  else
    bab, baha = abs_from_greg(10, 20, y), abs_from_greg(11, 12, y)
  end
  hs[#hs + 1] = { bab, "Birth of the Báb" }
  hs[#hs + 1] = { baha, "Birth of Bahá’u’lláh" }
end

--- holiday-bahai-twin-holy-birthdays in window W.
local function twin_in(w)
  local hs = {}
  twin_1(w.y1, hs)
  if w.y1 ~= w.y2 then
    twin_1(w.y2, hs)
  end
  return filter_visible(w, hs)
end

local ORD = {
  "First",
  "Second",
  "Third",
  "Fourth",
  "Fifth",
  "Sixth",
  "Seventh",
  "Eighth",
  "Ninth",
  "Tenth",
  "Eleventh",
  "Twelfth",
}

--- holiday-bahai-ridvan in window W: the first visible date of each shown
--- day of Ridvan (days 1, 9 and 12 unless ALL).
local function ridvan_in(w, all)
  local show = all and { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 } or { 0, 8, 11 }
  local rid = {}
  for _, i in ipairs(show) do
    local month = i < 7 and 2 or 3
    local day = i < 7 and i + 13 or i - 6
    local h = holiday_bahai_in(w, month, day, ORD[i + 1] .. " Day of Ridvan")
    if h[1] then
      rid[#rid + 1] = h[1]
    end
  end
  return rid
end

local results = {} ---@type table<string, org.agenda.holidays.Entry[]>

--- What `calendar-check-holidays' finds with holiday form FN over Gregorian
--- YEAR: FN is run in each month's window and the entries of that month kept.
---@param key string cache key
---@param year integer
---@param fn fun(w: org.agenda.holidays.Window): table[]
---@return org.agenda.holidays.Entry[]
local function over_year(key, year, fn)
  key = key .. "|" .. year
  local cached = results[key]
  if cached then
    return cached
  end
  local res = {}
  for m = 1, 12 do
    local w = astro.check_window(m, year)
    for _, h in ipairs(fn(w)) do
      local hm, _, hy = greg_from_abs(h[1])
      if hm == m and hy == year then
        res[#res + 1] = { day = h[1] - EPOCH_ABS, name = h[2] }
      end
    end
  end
  results[key] = res
  return res
end

---@class org.agenda.holidays.BahaiOpts
---@field all? boolean `calendar-bahai-all-holidays-flag`

--- holiday-bahai: the Bahá’í MONTH/DAY holiday NAME in Gregorian YEAR (month
--- 19 with DAY <= 0 addresses Ayyám-i-Há, as in Emacs).
---@param year integer
---@param month integer
---@param day integer
---@param name string
---@param opts? org.agenda.holidays.BahaiOpts unused
---@return org.agenda.holidays.Entry[]
function M.holiday_bahai(year, month, day, name, opts) ---@diagnostic disable-line: unused-local
  return over_year("b" .. month .. "|" .. day .. "|" .. name, year, function(w)
    return holiday_bahai_in(w, month, day, name)
  end)
end

--- holiday-bahai-new-year: "Bahá’í New Year (Naw-Ruz) N" in Gregorian YEAR.
---@param year integer
---@param opts? org.agenda.holidays.BahaiOpts unused
---@return org.agenda.holidays.Entry[]
function M.new_year(year, opts) ---@diagnostic disable-line: unused-local
  return over_year("ny", year, new_year_in)
end

--- holiday-bahai-ridvan: the days of Ridvan in Gregorian YEAR (all twelve
--- with `opts.all`, else the first, ninth and twelfth).
---@param year integer
---@param opts? org.agenda.holidays.BahaiOpts
---@return org.agenda.holidays.Entry[]
function M.ridvan(year, opts)
  local all = opts and opts.all or false
  return over_year(all and "ridvan-all" or "ridvan", year, function(w)
    return ridvan_in(w, all)
  end)
end

--- holiday-bahai-twin-holy-birthdays: "Birth of the Báb" and "Birth of
--- Bahá’u’lláh" in Gregorian YEAR.
---@param year integer
---@param opts? org.agenda.holidays.BahaiOpts unused
---@return org.agenda.holidays.Entry[]
function M.twin_holy_birthdays(year, opts) ---@diagnostic disable-line: unused-local
  return over_year("twin", year, twin_in)
end

M.to_absolute = to_absolute
M.from_absolute = from_absolute

return M
