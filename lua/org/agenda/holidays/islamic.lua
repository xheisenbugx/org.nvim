---@mod org.agenda.holidays.islamic Islamic calendar holidays (port of Emacs's cal-islam.el)
---
--- See org.agenda.holidays.julian for the calendar-window emulation: every
--- function returns the entries Emacs's `calendar-check-holidays` finds on the
--- days of the given Gregorian year, sorted by day.

local julian = require("org.agenda.holidays.julian")

local C = julian.calendar
local floor = math.floor

local M = {}

--- calendar-islamic-epoch: absolute date of July 16, 622 (Julian).
local EPOCH = julian.to_absolute(7, 16, 622)

local LEAP_YEARS = { [2] = true, [5] = true, [7] = true, [10] = true, [13] = true, [16] = true }
for _, y in ipairs({ 18, 21, 24, 26, 29 }) do
  LEAP_YEARS[y] = true
end

--- calendar-islamic-leap-year-p
---@param year integer
---@return boolean
local function leap_year_p(year)
  return LEAP_YEARS[year % 30] == true
end

--- calendar-islamic-last-day-of-month
---@param month integer
---@param year integer
---@return integer
local function last_day_of_month(month, year)
  if month == 12 then
    return leap_year_p(year) and 30 or 29
  end
  return month % 2 == 1 and 30 or 29
end

--- calendar-islamic-to-absolute
---@param month integer
---@param day integer
---@param year integer
---@return integer
function M.to_absolute(month, day, year)
  local y = year % 30
  local leap_years_in_cycle
  if y < 3 then
    leap_years_in_cycle = 0
  elseif y < 6 then
    leap_years_in_cycle = 1
  elseif y < 8 then
    leap_years_in_cycle = 2
  elseif y < 11 then
    leap_years_in_cycle = 3
  elseif y < 14 then
    leap_years_in_cycle = 4
  elseif y < 17 then
    leap_years_in_cycle = 5
  elseif y < 19 then
    leap_years_in_cycle = 6
  elseif y < 22 then
    leap_years_in_cycle = 7
  elseif y < 25 then
    leap_years_in_cycle = 8
  elseif y < 27 then
    leap_years_in_cycle = 9
  else
    leap_years_in_cycle = 10
  end
  -- calendar-islamic-day-number
  local day_number = 30 * floor(month / 2) + 29 * floor((month - 1) / 2) + day
  return day_number + (year - 1) * 354 + 11 * floor(year / 30) + leap_years_in_cycle + EPOCH - 1
end

--- calendar-islamic-from-absolute ((0 0 0) before the epoch)
---@param abs integer
---@return integer month, integer day, integer year
function M.from_absolute(abs)
  if abs < EPOCH then
    return 0, 0, 0
  end
  local year = floor((abs - EPOCH) / 355)
  while abs >= M.to_absolute(1, 1, year + 1) do
    year = year + 1
  end
  local month = 1
  while abs > M.to_absolute(month, last_day_of_month(month, year), year) do
    month = month + 1
  end
  return month, abs - (M.to_absolute(month, 1, year) - 1), year
end

--- holiday-islamic, for a calendar window (calendar-total-months ~= 3).
---@param w org.holidays.Window
---@param month integer
---@param day integer
---@param name string
---@return {[1]: integer, [2]: string}[]
function M.holiday_islamic_window(w, month, day, name)
  return C.named(C.nongregorian_date_visible_p(w, month, day, M.to_absolute, M.from_absolute), name)
end

--- holiday-islamic MONTH DAY STRING: the Gregorian dates in YEAR of Islamic MONTH DAY.
---@param year integer Gregorian year
---@param month integer Islamic month
---@param day integer Islamic day
---@param name string
---@return org.HolidayEntry[]
function M.holiday_islamic(year, month, day, name)
  return C.for_year(year, function(w)
    return M.holiday_islamic_window(w, month, day, name)
  end)
end

--- holiday-islamic-new-year: "Islamic New Year NNNN" (the Islamic year of the
--- last day of the Gregorian month of the holiday, like Emacs).
---@param year integer Gregorian year
---@param opts? table unused (no all-holidays flag)
---@return org.HolidayEntry[]
function M.new_year(year, opts)
  local _ = opts
  return C.for_year(year, function(w)
    local res = {}
    for _, h in ipairs(M.holiday_islamic_window(w, 1, 1, "")) do
      local y, m = C.gregorian_from_absolute(h[1])
      local _, _, iy = M.from_absolute(C.absolute_from_gregorian(y, m, C.last_day_of_month(m, y)))
      res[#res + 1] = { h[1], string.format("Islamic New Year %d", iy) }
    end
    return res
  end)
end

return M
