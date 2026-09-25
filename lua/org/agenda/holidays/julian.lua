---@mod org.agenda.holidays.julian Julian calendar holidays (port of Emacs's cal-julian.el)
---
--- Also holds the emulation of the Emacs calendar "window" (displayed-month,
--- displayed-year, calendar-total-months) shared by the Hebrew and Islamic
--- ports: Emacs's holiday functions only return the holidays visible in that
--- window, and some of them compute their dates from it.
---
--- `org-calendar-holiday` calls `calendar-check-holidays`, which evaluates the
--- holiday functions with a one-month window (the month of the date). The
--- public functions of these modules therefore evaluate their Emacs
--- counterpart once per month of the requested Gregorian year, with that exact
--- window, and return the entries of the whole year sorted by date (entries on
--- the same day keep the order in which Emacs's function returns them).
---
--- Dates are Emacs "absolute" dates internally (day 1 = 0001-01-01 Gregorian);
--- entries use the plugin's day numbers (`org.date.days_from_civil`).

local date = require("org.date")

local floor = math.floor

local M = {}

--- Emacs absolute date of 1970-01-01 minus one: absolute = day + ABS_OFFSET.
local ABS_OFFSET = 719163

---@class org.HolidayEntry
---@field day integer Day number (days since 1970-01-01)
---@field name string

---------------------------------------------------------------------------
-- Gregorian helpers (calendar.el)

---@class org.holidays.Calendar
local C = {}
M.calendar = C

C.ABS_OFFSET = ABS_OFFSET

--- calendar-absolute-from-gregorian (linear in DAY, like Emacs).
---@param y integer
---@param m integer
---@param d integer
---@return integer
function C.absolute_from_gregorian(y, m, d)
  return date.days_from_civil(y, m, 1) + d - 1 + ABS_OFFSET
end

--- calendar-gregorian-from-absolute.
---@param abs integer
---@return integer year, integer month, integer day
function C.gregorian_from_absolute(abs)
  return date.civil_from_days(abs - ABS_OFFSET)
end

--- calendar-last-day-of-month.
---@param m integer
---@param y integer
---@return integer
function C.last_day_of_month(m, y)
  return date.days_in_month(y, m)
end

--- calendar-dayname-on-or-before: absolute date of DAYNAME (0 = Sunday) on or before ABS.
---@param dayname integer
---@param abs integer
---@return integer
function C.dayname_on_or_before(dayname, abs)
  return abs - (abs - dayname) % 7
end

--- calendar-increment-month: returns MON, YR moved by N months.
---@param mon integer
---@param yr integer
---@param n integer
---@return integer mon, integer yr
function C.increment_month(mon, yr, n)
  local macro_y = yr * 12 + mon - 1 + n
  return macro_y % 12 + 1, floor(macro_y / 12)
end

---------------------------------------------------------------------------
-- Calendar window (displayed-month, displayed-year, calendar-total-months)

---@class org.holidays.Window
---@field month integer displayed-month
---@field year integer displayed-year
---@field total integer calendar-total-months

--- calendar-get-month-range (including its quirk: for a one-month window on
--- December, Y2 is the following year).
---@param w org.holidays.Window
---@return integer m1, integer y1, integer m2, integer y2
function C.month_range(w)
  local y1, y2 = w.year, w.year
  local m1 = w.month - 1
  local m2 = (m1 - 1 + w.total) % 12
  if m2 == 0 then
    m2 = 12
  end
  if m1 > 1 then
    if m2 < m1 then
      y2 = y1 + 1
    end
  elseif m1 == 0 then
    m1, y1 = 12, y1 - 1
  end
  return m1, y1, m2, y2
end

--- calendar--month-overlap-p
local function month_overlap_p(m1, m2, mon, n)
  if n == 0 then
    return m1 <= mon and mon <= m2
  end
  n = mon + n
  if n <= 12 then
    return math.max(m1, mon) <= math.min(m2, n)
  end
  return math.max(m1, 1) <= math.min(m2, n - 12) or math.max(m1, mon) <= math.min(m2, 12)
end

--- calendar-month-visible-p: with N = nil/0 the year of MONTH (or nil),
--- otherwise the list of visible years between MONTH and MONTH+N.
---@param w org.holidays.Window
---@param month integer
---@param n? integer
---@return integer|integer[]|nil
function C.month_visible_p(w, month, n)
  n = n or 0
  local m1, y1, m2, y2 = C.month_range(w)
  local r = {}
  if y1 == y2 then
    if month_overlap_p(m1, m2, month, n) then
      table.insert(r, 1, y1)
    end
  else
    if month_overlap_p(1, m2, month, n) then
      table.insert(r, 1, y2)
    end
    if month_overlap_p(m1, 12, month, n) then
      table.insert(r, 1, y1)
    end
  end
  if n == 0 then
    return r[1]
  end
  return r
end

--- calendar-date-is-visible-p (for an absolute date).
---@param w org.holidays.Window
---@param abs integer
---@return boolean
function C.date_is_visible_p(w, abs)
  local y, m = C.gregorian_from_absolute(abs)
  if y < 1 then
    return false
  end
  local interval = 12 * (y - w.year) + (m - w.month)
  return -2 < interval and interval < w.total - 1
end

--- calendar-nongregorian-date-visible-p: the visible absolute dates of the
--- local date MONTH DAY. TOABS(month, day, year) and FROMABS(abs) -> month,
--- day, year convert the local calendar; N is the first month of its year.
---@param w org.holidays.Window
---@param month integer
---@param day integer
---@param toabs fun(month: integer, day: integer, year: integer): integer
---@param fromabs fun(abs: integer): integer, integer, integer
---@param n? integer
---@return integer[]
function C.nongregorian_date_visible_p(w, month, day, toabs, fromabs, n)
  local rm1, ry1, rm2, ry2 = C.month_range(w)
  local start_date = C.absolute_from_gregorian(ry1, rm1, 1)
  local end_date = C.absolute_from_gregorian(ry2, rm2, C.last_day_of_month(rm2, ry2))
  local m1, _, y1 = fromabs(start_date)
  local m2, _, y2 = fromabs(end_date)
  n = n or 1
  local years = {} -- pushed years; Emacs pushes, so the result is reversed
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
    if m1 >= n then
      if month >= m1 or month < n then
        push(y1)
      end
      if month <= m2 then
        push(y2)
      end
    else
      if m1 <= month and month < n then
        push(y1)
      end
      if month >= n or month <= m2 then
        push(y2)
      end
    end
  end
  local res = {}
  for _, y in ipairs(years) do
    local abs = toabs(month, day, y)
    if C.date_is_visible_p(w, abs) then
      res[#res + 1] = abs
    end
  end
  return res
end

--- holiday-filter-visible-calendar over {abs, name} pairs.
---@param w org.holidays.Window
---@param list {[1]: integer, [2]: string}[]
---@return {[1]: integer, [2]: string}[]
function C.filter_visible(w, list)
  local res = {}
  for _, h in ipairs(list) do
    if C.date_is_visible_p(w, h[1]) then
      res[#res + 1] = h
    end
  end
  return res
end

--- Pairs {abs, NAME} for each absolute date of DATES.
---@param dates integer[]
---@param name string
---@return {[1]: integer, [2]: string}[]
function C.named(dates, name)
  local res = {}
  for _, abs in ipairs(dates) do
    res[#res + 1] = { abs, name }
  end
  return res
end

--- Evaluates FN(window) the way `calendar-check-holidays` does, for each
--- month of the Gregorian YEAR (displayed-month = month + 1, one-month
--- window), and returns the entries of the year sorted by day, keeping FN's
--- order for entries on the same day.
---@param year integer
---@param fn fun(w: org.holidays.Window): {[1]: integer, [2]: string}[]
---@return org.HolidayEntry[]
function C.for_year(year, fn)
  local list = {}
  for month = 1, 12 do
    local dm, dy = C.increment_month(month, year, 1)
    local w = { month = dm, year = dy, total = 1 }
    for _, h in ipairs(fn(w)) do
      local y, m = C.gregorian_from_absolute(h[1])
      if y == year and m == month then
        list[#list + 1] = { abs = h[1], name = h[2], idx = #list }
      end
    end
  end
  table.sort(list, function(a, b)
    if a.abs ~= b.abs then
      return a.abs < b.abs
    end
    return a.idx < b.idx
  end)
  local res = {}
  for _, h in ipairs(list) do
    res[#res + 1] = { day = h.abs - ABS_OFFSET, name = h.name }
  end
  return res
end

---------------------------------------------------------------------------
-- Julian calendar (cal-julian.el)

--- calendar-julian-to-absolute
---@param month integer
---@param day integer
---@param year integer
---@return integer
function M.to_absolute(month, day, year)
  local day_number = C.absolute_from_gregorian(year, month, day) - C.absolute_from_gregorian(year, 1, 1) + 1
  local correction = (year % 100 == 0 and year % 400 ~= 0 and month > 2) and 1 or 0
  return day_number + correction + 365 * (year - 1) + floor((year - 1) / 4) - 2
end

local JULIAN_MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

--- calendar-julian-from-absolute
---@param abs integer
---@return integer month, integer day, integer year
function M.from_absolute(abs)
  local year = floor((abs + 2) / 366)
  while abs >= M.to_absolute(1, 1, year + 1) do
    year = year + 1
  end
  local month = 1
  while true do
    local last = (month == 2 and year % 4 == 0) and 29 or JULIAN_MONTH_DAYS[month]
    if abs > M.to_absolute(month, last, year) then
      month = month + 1
    else
      break
    end
  end
  return month, abs - (M.to_absolute(month, 1, year) - 1), year
end

--- holiday-julian, for a calendar window.
---@param w org.holidays.Window
---@param month integer
---@param day integer
---@param name string
---@return {[1]: integer, [2]: string}[]
function M.holiday_julian_window(w, month, day, name)
  return C.named(C.nongregorian_date_visible_p(w, month, day, M.to_absolute, M.from_absolute), name)
end

--- holiday-julian MONTH DAY STRING: the Gregorian dates in YEAR of Julian MONTH DAY.
---@param year integer Gregorian year
---@param month integer Julian month
---@param day integer Julian day
---@param name string
---@return org.HolidayEntry[]
function M.holiday_julian(year, month, day, name)
  return C.for_year(year, function(w)
    return M.holiday_julian_window(w, month, day, name)
  end)
end

--- holiday-greek-orthodox-easter-abs
---@param y integer
---@return integer
local function greek_orthodox_easter_abs(y)
  local _, _, julian_year = M.from_absolute(C.absolute_from_gregorian(y, 3, 31))
  local shifted_epact = (14 + 11 * (julian_year % 19)) % 30
  local paschal_moon = M.to_absolute(4, 19, julian_year) - shifted_epact
  return C.dayname_on_or_before(0, paschal_moon + 7)
end

--- holiday-greek-orthodox-easter &optional N STRING (through holiday-after).
---@param year integer Gregorian year
---@param n? integer days after (negative: before) Pascha, default 0
---@param name? string default "Pascha (Greek Orthodox Easter)"
---@return org.HolidayEntry[]
function M.greek_orthodox_easter(year, n, name)
  n = n or 0
  name = name or "Pascha (Greek Orthodox Easter)"
  return C.for_year(year, function(w)
    local _, y1, _, y2 = C.month_range(w)
    local list = { { n + greek_orthodox_easter_abs(y1), name } }
    if y1 ~= y2 then
      list[#list + 1] = { n + greek_orthodox_easter_abs(y2), name }
    end
    return C.filter_visible(w, list)
  end)
end

return M
