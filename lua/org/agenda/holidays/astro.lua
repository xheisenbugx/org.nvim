---@mod org.agenda.holidays.astro Emacs calendar arithmetic and astronomy (solar.el, lunar.el, cal-dst.el)
---
--- Faithful ports of the Emacs 31 calendar functions that the astronomical
--- holidays need: Gregorian/absolute date conversion, the holiday "calendar
--- window" predicates of calendar.el, the daylight-saving adjustments of
--- cal-dst.el, the solar longitude / equinox / sunrise-sunset code of solar.el
--- and the new-moon code of lunar.el.
---
--- Every expression keeps Emacs's evaluation order (Elisp `(+ a b c)` is
--- `(a + b) + c`, `(mod x y)` on floats is fmod with the sign of Y, `round` is
--- round-half-even), so the floating-point results are bit-identical to Emacs's
--- and the printed dates and minutes match exactly.
---
--- Dates here are Emacs "absolute" dates (days since the imaginary 1 BC-12-31;
--- absolute = days since 1970-01-01 + 719163) and astronomical (Julian) day
--- numbers (absolute + 1721424.5).

local M = {}

local floor, sin, cos, tan, atan, sqrt, fmod, abs =
  math.floor, math.sin, math.cos, math.tan, math.atan, math.sqrt, math.fmod, math.abs

local PI = math.pi -- `float-pi`
local DTR = PI / 180.0 -- `degrees-to-radians`
local RTD = 180.0 / PI -- `radians-to-degrees`
local TWO_PI = 2 * PI
local ASTRO = 1721424.5 -- calendar-astro-from-absolute offset

--- Absolute date of 1970-01-01 (`calendar-system-time-basis`).
M.EPOCH_ABS = 719163

---------------------------------------------------------------------------
-- Elisp arithmetic
---------------------------------------------------------------------------

--- Elisp `mod` on floats: fmod with the sign of the divisor.
---@param x number
---@param y number
---@return number
local function emod(x, y)
  local r = fmod(x, y)
  if (y < 0 and r > 0) or (y >= 0 and r < 0) then
    r = r + y
  end
  return r
end
M.emod = emod

--- Elisp `round` on floats (rint: halves go to the even integer).
---@param x number
---@return integer
local function round(x)
  local f = floor(x)
  local diff = x - f
  if diff > 0.5 then
    return f + 1
  elseif diff < 0.5 then
    return f
  end
  return f % 2 == 0 and f or f + 1
end
M.round = round

--- Elisp `truncate`.
---@param x number
---@return integer
local function truncate(x)
  if x < 0 then
    return -floor(-x)
  end
  return floor(x)
end
M.truncate = truncate

--- Elisp integer `/` (truncates towards zero).
---@param a integer
---@param b integer
---@return integer
local function idiv(a, b)
  return truncate(a / b)
end
M.idiv = idiv

---------------------------------------------------------------------------
-- Gregorian calendar (calendar.el)
---------------------------------------------------------------------------

--- calendar-leap-year-p
---@param year integer
---@return boolean
local function leap_year_p(year)
  if year < 0 then
    year = abs(year) - 1
  end
  return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end
M.leap_year_p = leap_year_p

local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

--- calendar-last-day-of-month
---@param month integer
---@param year integer
---@return integer
local function last_day_of_month(month, year)
  if month == 2 and leap_year_p(year) then
    return 29
  end
  return MONTH_DAYS[month]
end
M.last_day_of_month = last_day_of_month

--- calendar-day-number (DAY may be a float, as in Emacs).
---@param month integer
---@param day number
---@param year integer
---@return number
local function day_number(month, day, year)
  local doy = day + 31 * (month - 1)
  if month > 2 then
    doy = doy - idiv(23 + 4 * month, 10)
    if leap_year_p(year) then
      doy = doy + 1
    end
  end
  return doy
end
M.day_number = day_number

--- calendar-absolute-from-gregorian (years > 0; DAY may be a float and is
--- summed in Emacs's order).
---@param month integer
---@param day number
---@param year integer
---@return number
local function absolute_from_gregorian(month, day, year)
  local oy = year - 1
  return day_number(month, day, year) + 365 * oy + idiv(oy, 4) + -idiv(oy, 100) + idiv(oy, 400)
end
M.absolute_from_gregorian = absolute_from_gregorian

--- calendar-gregorian-from-absolute (integer DATE, years > 0).
---@param date integer
---@return integer month
---@return integer day
---@return integer year
local function gregorian_from_absolute(date)
  local d0 = date - 1
  local n400 = idiv(d0, 146097)
  local d1 = d0 % 146097
  local n100 = idiv(d1, 36524)
  local d2 = d1 % 36524
  local n4 = idiv(d2, 1461)
  local d3 = d2 % 1461
  local n1 = idiv(d3, 365)
  local day = 1 + d3 % 365
  local year = 400 * n400 + 100 * n100 + n4 * 4 + n1
  if n100 == 4 or n1 == 4 then
    return 12, 31, year
  end
  year = year + 1
  local month = 1
  local mdays = last_day_of_month(month, year)
  while mdays < day do
    day = day - mdays
    month = month + 1
    mdays = last_day_of_month(month, year)
  end
  return month, day, year
end
M.gregorian_from_absolute = gregorian_from_absolute

--- calendar-dayname-on-or-before
---@param dayname integer
---@param date integer
---@return integer
local function dayname_on_or_before(dayname, date)
  local x = date - dayname
  return date - (x - idiv(x, 7) * 7)
end

--- calendar-nth-named-absday
---@param n integer
---@param dayname integer
---@param month integer
---@param year integer
---@param day? integer
---@return integer
function M.nth_named_absday(n, dayname, month, year, day)
  if n > 0 then
    return 7 * (n - 1) + dayname_on_or_before(dayname, 6 + absolute_from_gregorian(month, day or 1, year))
  end
  return 7 * (n + 1)
    + dayname_on_or_before(dayname, absolute_from_gregorian(month, day or last_day_of_month(month, year), year))
end

--- calendar-date-is-valid-p
---@return boolean
function M.date_is_valid_p(month, day, year)
  return month == floor(month)
    and day == floor(day)
    and month >= 1
    and month <= 12
    and day >= 1
    and day <= last_day_of_month(month, year)
end

---------------------------------------------------------------------------
-- The calendar window (calendar.el), as bound by `calendar-check-holidays'
---------------------------------------------------------------------------

---@class org.agenda.holidays.Window
---@field dm integer displayed-month
---@field dy integer displayed-year
---@field total integer calendar-total-months
---@field m1 integer
---@field y1 integer
---@field m2 integer
---@field y2 integer

--- calendar-increment-month for years > 0.
---@return integer month
---@return integer year
local function increment_month(mon, yr, n, nmonths)
  nmonths = nmonths or 12
  local macro_y = yr * nmonths + mon - 1 + n
  mon = 1 + macro_y % nmonths
  yr = floor(macro_y / nmonths)
  return mon, yr
end
M.increment_month = increment_month

--- The window `calendar-check-holidays' uses for a date in MONTH/YEAR
--- (displayed-month is the following month, calendar-total-months = 1), with
--- the month range of `calendar-get-month-range' (including its quirk that the
--- December window reports Y2 = YEAR + 1).
---@param month integer
---@param year integer
---@return org.agenda.holidays.Window
function M.check_window(month, year)
  local dm, dy = increment_month(month, year, 1)
  local total = 1
  -- calendar-get-month-range
  local y1, y2 = dy, dy
  local m1 = dm - 1
  local m2 = (m1 - 1 + total) % 12
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
  return { dm = dm, dy = dy, total = total, m1 = m1, y1 = y1, m2 = m2, y2 = y2 }
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

--- calendar-month-visible-p: with N = 0 (or nil) the year of MONTH (or nil),
--- otherwise the list of visible years (Emacs's order).
---@param w org.agenda.holidays.Window
---@param month integer
---@param n? integer
---@return integer|integer[]|nil
function M.month_visible_p(w, month, n)
  n = n or 0
  local r = {}
  if w.y1 == w.y2 then
    if month_overlap_p(w.m1, w.m2, month, n) then
      table.insert(r, 1, w.y1)
    end
  else
    if month_overlap_p(1, w.m2, month, n) then
      table.insert(r, 1, w.y2)
    end
    if month_overlap_p(w.m1, 12, month, n) then
      table.insert(r, 1, w.y1)
    end
  end
  if n == 0 then
    return r[1]
  end
  return r
end

--- calendar-date-is-visible-p
---@param w org.agenda.holidays.Window
---@return boolean
function M.date_is_visible_p(w, month, day, year)
  if not M.date_is_valid_p(month, day, year) then
    return false
  end
  local interval = 12 * (year - w.dy) + (month - w.dm)
  return -2 < interval and interval < w.total - 1
end

--- calendar-get-date-range with FULL: absolute dates of the first and last day.
---@param w org.agenda.holidays.Window
---@return integer start
---@return integer end
function M.date_range_abs(w)
  return absolute_from_gregorian(w.m1, 1, w.y1), absolute_from_gregorian(w.m2, last_day_of_month(w.m2, w.y2), w.y2)
end

---------------------------------------------------------------------------
-- Time zones and daylight saving (cal-dst.el)
---------------------------------------------------------------------------

---@class org.agenda.holidays.Zone
---@field tz number calendar-time-zone (minutes of standard time from UTC)
---@field dst_offset number calendar-daylight-time-offset
---@field std_name string calendar-standard-time-zone-name
---@field dst_name string calendar-daylight-time-zone-name
---@field starts_time number calendar-daylight-savings-starts-time
---@field ends_time number calendar-daylight-savings-ends-time
---@field starts? fun(year: integer): integer?, integer?, integer? calendar-daylight-savings-starts (M, D, Y)
---@field ends? fun(year: integer): integer?, integer?, integer? calendar-daylight-savings-ends (M, D, Y)

--- dst-in-effect: is DST in effect at absolute DATE (fraction = local
--- standard time of day)?
---@param z org.agenda.holidays.Zone
---@param date number
---@return boolean
local function dst_in_effect(z, date)
  if not (z.starts and z.ends) then
    return false
  end
  local _, _, year = gregorian_from_absolute(floor(date))
  local sm, sd, sy = z.starts(year)
  local em, ed, ey = z.ends(year)
  if not (sm and em) then
    return false
  end
  local dst_starts = absolute_from_gregorian(sm, sd, sy) + z.starts_time / 60.0 / 24.0
  local dst_ends = absolute_from_gregorian(em, ed, ey) + (z.ends_time - z.dst_offset) / 60.0 / 24.0
  if dst_starts < dst_ends then
    return dst_starts <= date and date < dst_ends
  end
  return dst_starts <= date or date < dst_ends
end
M.dst_in_effect = dst_in_effect

--- dst-adjust-time: adjust standard TIME (hours) on MONTH/DAY/YEAR for DST.
---@param z org.agenda.holidays.Zone
---@return integer month
---@return integer day
---@return integer year
---@return number time
---@return string zone
local function dst_adjust_time(z, month, day, year, time)
  local rounded = absolute_from_gregorian(month, day, year) + round(60 * time) / 60.0 / 24.0
  local dst = dst_in_effect(z, rounded)
  local zone = dst and z.dst_name or z.std_name
  local t = rounded + (dst and z.dst_offset / 24.0 / 60.0 or 0)
  local tt = truncate(t)
  local m, d, y = gregorian_from_absolute(tt)
  return m, d, y, 24.0 * (t - tt), zone
end
M.dst_adjust_time = dst_adjust_time

--- solar-time-string with the default `calendar-time-display-form'
--- ("8:44am (CST)").
---@param time number hours
---@param zone? string
---@return string
function M.time_string(time, zone)
  local t = round(60 * time)
  local h24 = idiv(t, 60)
  local minutes = string.format("%02d", t - idiv(t, 60) * 60)
  local h12 = 1 + (h24 + 11) % 12
  local am_pm = h24 >= 12 and "pm" or "am"
  local s = h12 .. ":" .. minutes .. am_pm
  if zone then
    s = s .. " (" .. zone .. ")"
  end
  return s
end

---------------------------------------------------------------------------
-- solar.el
---------------------------------------------------------------------------

local function sin_deg(x) -- solar-sin-degrees
  return sin(DTR * emod(x, 360.0))
end
local function cos_deg(x) -- solar-cosine-degrees
  return cos(DTR * emod(x, 360.0))
end
local function tan_deg(x) -- solar-tangent-degrees
  return tan(DTR * emod(x, 360.0))
end
M.sin_deg, M.cos_deg = sin_deg, cos_deg

local function xy_to_quadrant(x, y) -- solar-xy-to-quadrant
  if x > 0 then
    return y > 0 and 1 or 4
  end
  return y > 0 and 2 or 3
end

local function degrees_to_quadrant(angle) -- solar-degrees-to-quadrant
  return 1 + floor(emod(angle, 360.0) / 90)
end

local function arctan(x, quad) -- solar-arctan
  local deg = RTD * atan(x)
  if quad == 2 or quad == 3 then
    return deg + 180
  elseif quad == 4 then
    return deg + 360
  end
  return deg
end

local function atn2(x, y) -- solar-atn2
  if x == 0 then
    return y > 0 and 90 or 270
  end
  return arctan(y / x, xy_to_quadrant(x, y))
end

local function arcsin(y) -- solar-arcsin
  return atn2(sqrt(1 - y * y), y)
end

--- solar-ecliptic-coordinates: apparent longitude, inclination, equation of
--- time (hours) and nutation for TIME in Julian centuries of ET.
---@return number app
---@return number i
---@return number? time_eq
---@return number? nut
local function ecliptic_coordinates(time, sunrise_flag)
  local l = 280.46645 + 36000.76983 * time + 0.0003032 * time * time
  local ml = 218.3165 + 481267.8813 * time
  local m = 357.52910 + 35999.05030 * time + -0.0001559 * time * time + -0.00000048 * time * time * time
  local i = 23.43929111 + -0.013004167 * time + -0.00000016389 * time * time + 0.0000005036 * time * time * time
  local c = (1.914600 + -0.004817 * time + -0.000014 * time * time) * sin_deg(m)
    + (0.019993 + -0.000101 * time) * sin_deg(2 * m)
    + 0.000290 * sin_deg(3 * m)
  local L = l + c
  local omega = 125.04 + -1934.136 * time
  local app = L + -0.00569 + -0.00478 * sin_deg(omega)
  if sunrise_flag then
    return app, i
  end
  local nut = -17.20 * sin_deg(omega) + -1.32 * sin_deg(2 * l) + -0.23 * sin_deg(2 * ml) + 0.21 * sin_deg(2 * omega)
  local ecc = 0.016708617 + -0.000042037 * time + -0.0000001236 * time * time
  local y = tan_deg(i / 2) * tan_deg(i / 2)
  local time_eq = 12
    * (y * sin_deg(2 * l) + -2 * ecc * sin_deg(m) + 4 * ecc * y * sin_deg(m) * cos_deg(2 * l) + -0.5 * y * y * sin_deg(
      4 * l
    ) + -1.25 * ecc * ecc * sin_deg(2 * m))
    / PI
  return app, i, time_eq, nut
end

--- solar-ephemeris-correction: ET - UT in days during Gregorian YEAR.
---@param year integer
---@return number
local function ephemeris_correction(year)
  if 1988 <= year and year < 2020 then
    return (year + -2000 + 67.0) / 60.0 / 60.0 / 24.0
  elseif 1900 <= year and year < 1988 then
    local theta = ((absolute_from_gregorian(7, 1, year) + ASTRO) - (absolute_from_gregorian(1, 1, 1900) + ASTRO))
      / 36525.0
    local theta2 = theta * theta
    local theta3 = theta2 * theta
    local theta4 = theta2 * theta2
    local theta5 = theta3 * theta2
    return -0.00002
      + 0.000297 * theta
      + 0.025184 * theta2
      + -0.181133 * theta3
      + 0.553040 * theta4
      + -0.861938 * theta5
      + 0.677066 * theta3 * theta3
      + -0.212591 * theta4 * theta3
  elseif 1800 <= year and year < 1900 then
    local theta = ((absolute_from_gregorian(7, 1, year) + ASTRO) - (absolute_from_gregorian(1, 1, 1900) + ASTRO))
      / 36525.0
    local theta2 = theta * theta
    local theta3 = theta2 * theta
    local theta4 = theta2 * theta2
    local theta5 = theta3 * theta2
    return -0.000009
      + 0.003844 * theta
      + 0.083563 * theta2
      + 0.865736 * theta3
      + 4.867575 * theta4
      + 15.845535 * theta5
      + 31.332267 * theta3 * theta3
      + 38.291999 * theta4 * theta3
      + 28.316289 * theta4 * theta4
      + 11.636204 * theta4 * theta5
      + 2.043794 * theta5 * theta5
  elseif 1620 <= year and year < 1800 then
    local x = (year - 1600) / 10.0
    return (2.19167 * x * x + -40.675 * x + 196.58333) / 60.0 / 60.0 / 24.0
  end
  local tmp = (absolute_from_gregorian(1, 1, year) + ASTRO) - 2382148
  local second = tmp * tmp / 41048480.0 - 15
  return second / 60.0 / 60.0 / 24.0
end
M.ephemeris_correction = ephemeris_correction

--- Year of the (floored) absolute date of astronomical day number D.
local function astro_year(d)
  local _, _, y = gregorian_from_absolute(floor(d - ASTRO))
  return y
end

--- solar-ephemeris-time: TIME = (T0 centuries at 0 UT, UT hours) -> ET centuries.
local function ephemeris_time(t0, ut)
  local t1 = t0 + ut / 24.0 / 36525
  local y = 2000 + 100 * t1
  local dt = 86400 * ephemeris_correction(floor(y))
  return t1 + dt / 86400 / 36525
end

--- solar-equatorial-coordinates: right ascension (hours), declination (degrees).
local function equatorial_coordinates(t0, ut, sunrise_flag)
  local lon, obl = ecliptic_coordinates(ephemeris_time(t0, ut), sunrise_flag)
  local ra = arctan(cos_deg(obl) * tan_deg(lon), degrees_to_quadrant(lon)) / 15.0
  local de = arcsin(sin_deg(obl) * sin_deg(lon))
  return ra, de
end

--- solar-horizontal-coordinates (height only; the azimuth is unused here).
local function horizontal_height(t0, ut, latitude, longitude, sidereal)
  local ra, de = equatorial_coordinates(t0, ut, true)
  local st = sidereal + ut * 1.00273790935
  local ah = st * 15 - 15 * ra - -1 * longitude
  local height = arcsin(sin_deg(latitude) * sin_deg(de) + cos_deg(latitude) * cos_deg(de) * cos_deg(ah))
  if height > 180 then
    height = height - 360
  end
  return height
end

--- solar-moment: UT of sunrise (DIRECTION -1) or sunset (1) by bisection.
local function solar_moment(direction, latitude, longitude, t0, ut, height, sidereal)
  local utmin = ut + direction * 12.0
  local utmax = ut
  local utmoment_old = utmin
  local utmoment = utmax
  local hmin = horizontal_height(t0, utmin, latitude, longitude, sidereal)
  local hmax = horizontal_height(t0, utmax, latitude, longitude, sidereal)
  if not (hmin < height and hmax > height) then
    return nil
  end
  local err = 0.5 / 60 -- (/ solar-error 60)
  while abs(utmoment - utmoment_old) >= err do
    utmoment_old = utmoment
    utmoment = (utmin + utmax) / 2
    local hut = horizontal_height(t0, utmoment, latitude, longitude, sidereal)
    if hut < height then
      utmin = utmoment
    end
    if hut > height then
      utmax = utmoment
    end
  end
  return utmoment
end

--- solar-sunrise-and-sunset: local standard rise/set times and day length.
local function sunrise_and_sunset(t0, ut, latitude, longitude, height, sidereal, northern_summer, tz)
  local rise = solar_moment(-1, latitude, longitude, t0, ut, height, sidereal)
  local set = solar_moment(1, latitude, longitude, t0, ut, height, sidereal)
  local day_length
  if not (rise and set) then
    if (latitude > 0 and northern_summer) or (latitude < 0 and not northern_summer) then
      day_length = 24
    else
      day_length = 0
    end
  else
    day_length = set - rise
  end
  return rise and rise + tz / 60.0, set and set + tz / 60.0, day_length
end

local ABS_2000_NOON = absolute_from_gregorian(1, 1.5, 2000)

--- solar-julian-ut-centuries
local function julian_ut_centuries(month, day, year)
  return (absolute_from_gregorian(month, day, year) - ABS_2000_NOON) / 36525.0
end

--- solar-exact-local-noon: local date and UT of local noon.
local function exact_local_noon(month, day, year, longitude)
  local ut = 12.0 - longitude / 15
  local _, _, te = ecliptic_coordinates(ephemeris_time(julian_ut_centuries(month, day, year), ut), false)
  ut = ut - te
  local nd = day
  if ut >= 24 then
    nd, ut = day + 1, ut - 24
  end
  if ut < 0 then
    nd, ut = day - 1, ut + 24
  end
  local m, d, y = gregorian_from_absolute(absolute_from_gregorian(month, nd, year))
  return m, d, y, ut
end

--- solar-sidereal-time: Greenwich sidereal time (hours) at T0 (0 UT).
local function sidereal_time(t0)
  local mean = 6.6973746 + 2400.051337 * t0 + 0.0000258622 * t0 * t0 + -0.0000000017222 * t0 * t0 * t0
  local _, i, _, nut = ecliptic_coordinates(ephemeris_time(t0, 0.0), false)
  return emod(emod(mean + nut * cos_deg(i) / 15 / 3600, 24.0) + 24.0, 24.0)
end

--- solar-sunrise-sunset: local (DST-adjusted) times of sunrise and sunset on
--- MONTH/DAY/YEAR at LATITUDE/LONGITUDE, nil when there is none that day.
---@param z org.agenda.holidays.Zone
---@return number? rise
---@return number? set
function M.sunrise_sunset(z, latitude, longitude, month, day, year)
  local nm, nd, ny, nut = exact_local_noon(month, day, year, longitude)
  local t0 = julian_ut_centuries(nm, nd, ny)
  local sid = sidereal_time(t0)
  -- The equator pass only decides the spring/summer flag (a day length at
  -- latitude 1 always has both a rise and a set).
  local _, _, eq_length = sunrise_and_sunset(t0, nut, 1.0, longitude, 0, sid, false, z.tz)
  local northern = eq_length > 12
  local rise, set = sunrise_and_sunset(t0, nut, latitude, longitude, -0.61, sid, northern, z.tz)
  local adj_rise, adj_set
  if rise then
    local m, d, y, t = dst_adjust_time(z, month, day, year, rise)
    if m == month and d == day and y == year then
      adj_rise = t
    end
  end
  if set then
    local m, d, y, t = dst_adjust_time(z, month, day, year, set)
    if m == month and d == day and y == year then
      adj_set = t
    end
  end
  return adj_rise, adj_set
end

-- solar-data-list
local SOLAR_DATA = {
  { 403406, 4.721964, 1.621043 },
  { 195207, 5.937458, 62830.348067 },
  { 119433, 1.115589, 62830.821524 },
  { 112392, 5.781616, 62829.634302 },
  { 3891, 5.5474, 125660.5691 },
  { 2819, 1.5120, 125660.984 },
  { 1721, 4.1897, 62832.4766 },
  { 0, 1.163, 0.813 },
  { 660, 5.415, 125659.31 },
  { 350, 4.315, 57533.85 },
  { 334, 4.553, -33.931 },
  { 314, 5.198, 777137.715 },
  { 268, 5.989, 78604.191 },
  { 242, 2.911, 5.412 },
  { 234, 1.423, 39302.098 },
  { 158, 0.061, -34.861 },
  { 132, 2.317, 115067.698 },
  { 129, 3.193, 15774.337 },
  { 114, 2.828, 5296.670 },
  { 99, 0.52, 58849.27 },
  { 93, 4.65, 5296.11 },
  { 86, 4.35, -3980.70 },
  { 78, 2.75, 52237.69 },
  { 72, 4.50, 55076.47 },
  { 68, 3.23, 261.08 },
  { 64, 1.22, 15773.85 },
  { 46, 0.14, 188491.03 },
  { 38, 3.44, -7756.55 },
  { 37, 4.37, 264.89 },
  { 32, 1.14, 117906.27 },
  { 29, 2.84, 55075.75 },
  { 28, 5.96, -7961.39 },
  { 27, 5.09, 188489.81 },
  { 27, 1.72, 2132.19 },
  { 25, 2.56, 109771.03 },
  { 24, 1.92, 54868.56 },
  { 21, 0.09, 25443.93 },
  { 21, 5.98, -55731.43 },
  { 20, 4.03, 60697.74 },
  { 18, 4.47, 2132.79 },
  { 17, 0.79, 109771.63 },
  { 14, 4.24, -7752.82 },
  { 13, 2.01, 188491.91 },
  { 13, 2.65, 207.81 },
  { 13, 4.98, 29424.63 },
  { 12, 0.93, -7.99 },
  { 10, 2.21, 46941.14 },
  { 10, 3.59, -68.29 },
  { 10, 1.50, 21463.25 },
  { 10, 2.55, 157208.40 },
}
local N_SOLAR_DATA = #SOLAR_DATA

--- solar-longitude: longitude of the sun at astronomical day number D (local
--- time of zone Z).
---@param z org.agenda.holidays.Zone
---@param d number
---@return number
local function solar_longitude(z, d)
  local a_d = d - ASTRO
  local date = a_d - (dst_in_effect(z, a_d) and z.dst_offset / 24.0 / 60.0 or 0) - z.tz / 60.0 / 24.0 + ASTRO
  date = date + ephemeris_correction(astro_year(date))
  local U = (date - 2451545) / 3652500
  local x = SOLAR_DATA[1]
  local sum = x[1] * sin(emod(x[2] + x[3] * U, TWO_PI))
  for j = 2, N_SOLAR_DATA do
    x = SOLAR_DATA[j]
    sum = sum + x[1] * sin(emod(x[2] + x[3] * U, TWO_PI))
  end
  local longitude = 4.9353929 + 62833.1961680 * U + 0.0000001 * sum
  local aberration = 0.0000001 * (17 * cos(3.10 + 62830.14 * U) - 973)
  local A1 = emod(2.18 + U * (-3375.70 + 0.36 * U), TWO_PI)
  local A2 = emod(3.51 + U * (125666.39 + 0.10 * U), TWO_PI)
  local nutation = -0.0000001 * (834 * sin(A1) + 64 * sin(A2))
  return emod(RTD * (longitude + aberration + nutation), 360.0)
end
M.solar_longitude = solar_longitude

--- solar-date-next-longitude: first astronomical day number after D when the
--- solar longitude is a multiple of L degrees (local time of zone Z).
---@param z org.agenda.holidays.Zone
---@param d number
---@param l integer
---@return number
function M.date_next_longitude(z, d, l)
  local start = d
  local next = (l * (1 + floor(solar_longitude(z, d) / l))) % 360
  local finish = d + l / 360.0 * 400
  while 0.00001 < finish - start do
    d = (start + finish) / 2.0
    local long = solar_longitude(z, d)
    if (next ~= 0 and long < next) or (next == 0 and l < long) then
      start = d
    else
      finish = d
    end
  end
  return (start + finish) / 2.0
end

-- solar-seasons-data
local SEASONS_DATA = {
  { 485, 324.96, 1934.136 },
  { 203, 337.23, 32964.467 },
  { 199, 342.08, 20.186 },
  { 182, 27.85, 445267.112 },
  { 156, 73.14, 45036.886 },
  { 136, 171.52, 22518.443 },
  { 77, 222.54, 65928.934 },
  { 74, 296.72, 3034.906 },
  { 70, 243.58, 9037.513 },
  { 58, 119.81, 33718.147 },
  { 52, 297.17, 150.678 },
  { 50, 21.02, 2281.226 },
  { 45, 247.54, 29929.562 },
  { 44, 325.15, 31555.956 },
  { 29, 60.93, 4443.417 },
  { 18, 155.12, 67555.328 },
  { 17, 288.79, 4562.452 },
  { 16, 198.04, 62894.029 },
  { 14, 199.76, 31436.921 },
  { 12, 95.39, 14577.848 },
  { 12, 287.11, 31931.756 },
  { 12, 320.81, 34777.259 },
  { 9, 227.73, 1222.114 },
  { 8, 15.45, 16859.074 },
}

--- solar-mean-equinoxes/solstices: Julian day of mean equinox/solstice K.
local function mean_equinoxes_solstices(k, year)
  local y = year / 1000.0
  local z = (year - 2000) / 1000.0
  if year < 1000 then
    if k == 0 then
      return 1721139.29189 + 365242.13740 * y + 0.06134 * y * y + 0.00111 * y * y * y + -0.00071 * y * y * y * y
    elseif k == 1 then
      return 1721233.25401 + 365241.72562 * y + -0.05323 * y * y + 0.00907 * y * y * y + 0.00025 * y * y * y * y
    elseif k == 2 then
      return 1721325.70455 + 365242.49558 * y + -0.11677 * y * y + -0.00297 * y * y * y + 0.00074 * y * y * y * y
    end
    return 1721414.39987 + 365242.88257 * y + -0.00769 * y * y + -0.00933 * y * y * y + -0.00006 * y * y * y * y
  end
  if k == 0 then
    return 2451623.80984 + 365242.37404 * z + 0.05169 * z * z + -0.00411 * z * z * z + -0.00057 * z * z * z * z
  elseif k == 1 then
    return 2451716.56767 + 365241.62603 * z + 0.00325 * z * z + 0.00888 * z * z * z + -0.00030 * z * z * z * z
  elseif k == 2 then
    return 2451810.21715 + 365242.01767 * z + -0.11575 * z * z + 0.00337 * z * z * z + 0.00078 * z * z * z * z
  end
  return 2451900.05952 + 365242.74049 * z + -0.06223 * z * z + -0.00823 * z * z * z + 0.00032 * z * z * z * z
end

--- solar-equinoxes/solstices: equinox/solstice K (0 = March ... 3 = December)
--- of YEAR as a local standard date (MONTH, fractional DAY, YEAR) for a zone TZ
--- minutes from UTC.
---@param tz number
---@param k integer
---@param year integer
---@return integer month
---@return number day
---@return integer year
function M.equinoxes_solstices(tz, k, year)
  local JDE0 = mean_equinoxes_solstices(k, year)
  local T = (JDE0 - 2451545.0) / 36525
  local W = 35999.373 * T - 2.47
  local delta_lambda = 1 + 0.0334 * cos_deg(W) + 0.0007 * cos_deg(2 * W)
  local x = SEASONS_DATA[1]
  local S = x[1] * cos_deg(x[3] * T + x[2])
  for j = 2, #SEASONS_DATA do
    x = SEASONS_DATA[j]
    S = S + x[1] * cos_deg(x[3] * T + x[2])
  end
  local JDE = JDE0 + 0.00001 * S / delta_lambda
  local correction = 102.3 + 123.5 * T + 32.5 * T * T
  local JD = JDE - correction / 86400
  local m, d, y = gregorian_from_absolute(floor(JD - 1721424.5))
  local time = (JD - 0.5) - floor(JD - 0.5)
  return m, d + time + tz / 60.0 / 24.0, y
end

---------------------------------------------------------------------------
-- lunar.el
---------------------------------------------------------------------------

--- lunar-new-moon-time: astronomical day number (local standard time of
--- zone Z) of the K-th new moon since 2000-01-06.
---@param z org.agenda.holidays.Zone
---@param k integer
---@return number
local function new_moon_time(z, k)
  local T = k / 1236.85
  local T2 = T * T
  local T3 = T * T * T
  local T4 = T2 * T2
  local JDE = 2451550.09765 + 29.530588853 * k + 0.0001337 * T2 + -0.000000150 * T3 + 0.00000000073 * T4
  local E = 1 - 0.002516 * T - 0.0000074 * T2
  local sa = 2.5534 + 29.10535669 * k + -0.0000218 * T2 + -0.00000011 * T3
  local ma = 201.5643 + 385.81693528 * k + 0.0107438 * T2 + 0.00001239 * T3 + -0.000000058 * T4
  local arg = 160.7108 + 390.67050274 * k + -0.0016341 * T2 + -0.00000227 * T3 + 0.000000011 * T4
  local omega = 124.7746 + -1.56375580 * k + 0.0020691 * T2 + 0.00000215 * T3
  local A1 = 299.77 + 0.107408 * k + -0.009173 * T2
  local A2 = 251.88 + 0.016321 * k
  local A3 = 251.83 + 26.641886 * k
  local A4 = 349.42 + 36.412478 * k
  local A5 = 84.66 + 18.206239 * k
  local A6 = 141.74 + 53.303771 * k
  local A7 = 207.14 + 2.453732 * k
  local A8 = 154.84 + 7.306860 * k
  local A9 = 34.52 + 27.261239 * k
  local A10 = 207.19 + 0.121824 * k
  local A11 = 291.34 + 1.844379 * k
  local A12 = 161.72 + 24.198154 * k
  local A13 = 239.56 + 25.513099 * k
  local A14 = 331.55 + 3.592518 * k
  local correction = -0.40720 * sin_deg(ma)
    + 0.17241 * E * sin_deg(sa)
    + 0.01608 * sin_deg(2 * ma)
    + 0.01039 * sin_deg(2 * arg)
    + 0.00739 * E * sin_deg(ma - sa)
    + -0.00514 * E * sin_deg(ma + sa)
    + 0.00208 * E * E * sin_deg(2 * sa)
    + -0.00111 * sin_deg(ma - 2 * arg)
    + -0.00057 * sin_deg(ma + 2 * arg)
    + 0.00056 * E * sin_deg(2 * ma + sa)
    + -0.00042 * sin_deg(3 * ma)
    + 0.00042 * E * sin_deg(sa + 2 * arg)
    + 0.00038 * E * sin_deg(sa - 2 * arg)
    + -0.00024 * E * sin_deg(2 * ma - sa)
    + -0.00017 * sin_deg(omega)
    + -0.00007 * sin_deg(ma + 2 * sa)
    + 0.00004 * sin_deg(2 * ma - 2 * arg)
    + 0.00004 * sin_deg(3 * sa)
    + 0.00003 * sin_deg(ma + sa + -2 * arg)
    + 0.00003 * sin_deg(2 * ma + 2 * arg)
    + -0.00003 * sin_deg(ma + sa + 2 * arg)
    + 0.00003 * sin_deg(ma - sa - -2 * arg)
    + -0.00002 * sin_deg(ma - sa - 2 * arg)
    + -0.00002 * sin_deg(3 * ma + sa)
    + 0.00002 * sin_deg(4 * ma)
  local additional = 0.000325 * sin_deg(A1)
    + 0.000165 * sin_deg(A2)
    + 0.000164 * sin_deg(A3)
    + 0.000126 * sin_deg(A4)
    + 0.000110 * sin_deg(A5)
    + 0.000062 * sin_deg(A6)
    + 0.000060 * sin_deg(A7)
    + 0.000056 * sin_deg(A8)
    + 0.000047 * sin_deg(A9)
    + 0.000042 * sin_deg(A10)
    + 0.000040 * sin_deg(A11)
    + 0.000037 * sin_deg(A12)
    + 0.000035 * sin_deg(A13)
    + 0.000023 * sin_deg(A14)
  local newJDE = JDE + correction + additional
  return newJDE + -ephemeris_correction(astro_year(newJDE)) + z.tz / 60.0 / 24.0
end
M.new_moon_time = new_moon_time

--- lunar-new-moon-on-or-after: astronomical day number (local time of zone Z,
--- DST included) of the first new moon on or after astronomical day D.
---@param z org.agenda.holidays.Zone
---@param d number
---@return number
function M.new_moon_on_or_after(z, d)
  local m, dd, y = gregorian_from_absolute(floor(d - ASTRO))
  local year = y + day_number(m, dd, y) / 365.25
  local k = floor((year - 2000.0) * 12.3685)
  local date = new_moon_time(z, k)
  while date < d do
    k = k + 1
    date = new_moon_time(z, k)
  end
  local a_date = date - ASTRO
  local ta = truncate(a_date)
  local time = 24 * (a_date - ta)
  local gm, gd, gy = gregorian_from_absolute(ta)
  local am, ad, ay, atime = dst_adjust_time(z, gm, gd, gy, time)
  return absolute_from_gregorian(am, ad, ay) + atime / 24.0 + ASTRO
end

M.ASTRO = ASTRO

return M
