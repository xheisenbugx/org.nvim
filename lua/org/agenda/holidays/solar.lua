---@mod org.agenda.holidays.solar Equinoxes, solstices and DST holidays (solar.el, cal-dst.el)
---
--- Ports of Emacs's `solar-equinoxes-solstices' and of the two "Daylight Saving
--- Time Begins/Ends" entries of the default `holiday-solar-holidays', as seen
--- by `calendar-check-holidays' (which is what Org's `org-calendar-holiday'
--- calls).
---
--- Like Emacs, the local time zone is probed from the operating system
--- (cal-dst.el's `calendar-current-time-zone'): the standard offset, the DST
--- offset, the zone names and the DST start/end times of day come from the
--- first two transitions after "now", while the DST dates of each year come
--- from the transitions after January 1 of that year
--- (`calendar-dst-check-each-year-flag' = t). A zone without DST today (e.g.
--- America/Mexico_City) therefore still gets DST entries for the past years in
--- which it had DST, exactly like Emacs.

local astro = require("org.agenda.holidays.astro")

local M = {}

local floor = math.floor
local idiv = astro.idiv
local EPOCH_ABS = astro.EPOCH_ABS

---------------------------------------------------------------------------
-- System time zone probing (current-time-zone)
---------------------------------------------------------------------------

local days_from_civil = require("org.date").days_from_civil

--- UTC offset in seconds of the local zone at UNIX time T.
---@param t integer
---@return integer
local function utc_offset(t)
  local l = os.date("*t", t) --[[@as osdate]]
  local u = os.date("!*t", t) --[[@as osdate]]
  return (days_from_civil(l.year, l.month, l.day) - days_from_civil(u.year, u.month, u.day)) * 86400
    + (l.hour - u.hour) * 3600
    + (l.min - u.min) * 60
    + (l.sec - u.sec)
end

--- current-time-zone: (OFFSET NAME) at UNIX time T.
---@param t integer
---@return integer offset
---@return string name
local function current_time_zone(t)
  return utc_offset(t), os.date("%Z", t) --[[@as string]]
end

--- calendar-absolute-from-time: absolute local date and seconds after midnight.
local function absolute_from_time(x, utc_diff)
  local l = x + utc_diff
  return EPOCH_ABS + floor(l / 86400), l % 86400
end

--- calendar-time-from-absolute
local function time_from_absolute(abs_date, s)
  return s + 86400 * (abs_date - EPOCH_ABS)
end

--- calendar-next-time-zone-transition: first second of the next offset change
--- after T (probing 2, 1 and 3 quarters ahead), or nil.
---@param time integer
---@return integer?
local function next_time_zone_transition(time)
  local off = utc_offset(time)
  local hi, hi_off = nil, off
  local quarter = 7889238
  for _, q in ipairs({ 2, 1, 3 }) do
    if hi_off ~= off then
      break
    end
    hi = time + q * quarter
    hi_off = utc_offset(hi)
  end
  if hi_off == off then
    return nil
  end
  local lo = time
  while true do
    local probe = floor((lo + hi) / 2)
    if probe == lo then
      break
    end
    if utc_offset(probe) == hi_off then
      hi = probe
    else
      lo = probe
    end
  end
  return hi
end

-- cal-persia.el, for the Persian-calendar DST candidate rules.
local PERSIAN_EPOCH = 226896 -- calendar-persian-epoch

--- calendar-persian-to-absolute for day 1 of MONTH 1 or 7 of Persian YEAR > 0.
local function persian_to_absolute(month, year)
  local c = (year + 2345) % 2820
  return (PERSIAN_EPOCH - 1)
    + 365 * (year - 1)
    + 683 * floor((year + 2345) / 2820)
    + 186 * floor(c / 768)
    + floor(683 * (c % 768) / 2820)
    + -568
    + (month == 7 and 186 or 0)
    + 1
end

--- A DST rule of `calendar-time-zone-daylight-rules', evaluated for YEAR.
---@class org.agenda.holidays.DstRule
---@field kind "fixed"|"nth"|"persian" (list M D year), calendar-nth-named-day, Persian 1/1 or 7/1
---@field m integer month (Persian month for "persian")
---@field d? integer day of a "fixed" rule
---@field n? integer
---@field wd? integer weekday (0 = Sunday)
---@field day? integer

--- The Gregorian date (month, day, year) a rule gives for YEAR.
---@param rule org.agenda.holidays.DstRule
---@param year integer
---@return integer, integer, integer
local function rule_date(rule, year)
  if rule.kind == "fixed" then
    return rule.m, rule.d, year
  elseif rule.kind == "nth" then
    return astro.gregorian_from_absolute(astro.nth_named_absday(rule.n, rule.wd, rule.m, year, rule.day))
  end
  return astro.gregorian_from_absolute(persian_to_absolute(rule.m, year - 621))
end

--- The absolute date a rule gives for YEAR.
local function rule_absolute(rule, year)
  if rule.kind == "fixed" then
    return astro.absolute_from_gregorian(rule.m, rule.d, year)
  elseif rule.kind == "nth" then
    return astro.nth_named_absday(rule.n, rule.wd, rule.m, year, rule.day)
  end
  return persian_to_absolute(rule.m, year - 621)
end

--- calendar-time-zone-daylight-rules: the rule for the transition on
--- ABS_DATE (UTC_DIFF seconds from UTC before it), found by testing candidate
--- rules against the following years.
---@return org.agenda.holidays.DstRule
local function time_zone_daylight_rules(abs_date, utc_diff)
  local m, d, y = astro.gregorian_from_absolute(abs_date)
  local weekday = abs_date % 7
  local last = astro.last_day_of_month(m, y)
  local candidates = { { kind = "fixed", m = m, d = d } }
  if d < 8 then
    table.insert(candidates, { kind = "nth", n = 1, wd = weekday, m = m })
  end
  if d > last - 7 then
    table.insert(candidates, { kind = "nth", n = -1, wd = weekday, m = m })
  end
  local rlist = {}
  local j = math.max(2, d - 6) - 1
  while true do
    j = j + 1
    if j > math.min(d, last - 8) then
      break
    end
    table.insert(rlist, 1, { kind = "nth", n = 1, wd = weekday, m = m, day = j })
  end
  vim.list_extend(candidates, rlist)
  if m == 3 and (d == 20 or d == 21) then
    table.insert(candidates, { kind = "persian", m = 1 })
  end
  if m == 9 and (d == 22 or d == 23) then
    table.insert(candidates, { kind = "persian", m = 7 })
  end
  local prevday_sec = -1 - utc_diff
  local year = y + 1
  -- Emacs loops until one rule is left; the bound only guards against zones
  -- whose candidate rules never diverge.
  local guard = 0
  while #candidates > 1 and guard < 1000 do
    local new = {}
    for _, rule in ipairs(candidates) do
      local date = rule_absolute(rule, year)
      local o1, n1 = current_time_zone(time_from_absolute(date, prevday_sec))
      local o2, n2 = current_time_zone(time_from_absolute(date + 1, prevday_sec))
      if not (o1 == o2 and n1 == n2) then
        new[#new + 1] = rule
      end
    end
    candidates = #new > 0 and new or { candidates[1] }
    year = year + 1
    guard = guard + 1
  end
  return candidates[1]
end

---@class org.agenda.holidays.DstData
---@field utc_diff integer? minutes of standard time from UTC
---@field dst_offset integer?
---@field std_name string?
---@field dst_name string?
---@field starts org.agenda.holidays.DstRule?
---@field ends org.agenda.holidays.DstRule?
---@field starts_time integer?
---@field ends_time integer?

--- calendar-dst-find-data: DST data from the first two transitions after T0.
---@param t0 integer
---@return org.agenda.holidays.DstData
local function dst_find_data(t0)
  local t0_off, t0_name = current_time_zone(t0)
  local t1 = next_time_zone_transition(t0)
  local t2 = t1 and next_time_zone_transition(t1)
  if not t2 then
    return {
      utc_diff = idiv(t0_off, 60),
      dst_offset = 0,
      std_name = t0_name,
      dst_name = t0_name,
      starts_time = 0,
      ends_time = 0,
    }
  end
  local t1_off, t1_name = current_time_zone(t1)
  local t1_abs, t1_sec = absolute_from_time(t1, t0_off)
  local t2_abs, t2_sec = absolute_from_time(t2, t1_off)
  local t1_rules = time_zone_daylight_rules(t1_abs, t0_off)
  local t2_rules = time_zone_daylight_rules(t2_abs, t1_off)
  local t1_time, t2_time = idiv(t1_sec, 60), idiv(t2_sec, 60)
  local t1_decoded = os.date("*t", t1) --[[@as osdate]]
  if t1_decoded.isdst then
    return {
      utc_diff = idiv(t0_off, 60),
      dst_offset = idiv(t1_off - t0_off, 60),
      std_name = t0_name,
      dst_name = t1_name,
      starts = t1_rules,
      ends = t2_rules,
      starts_time = t1_time,
      ends_time = t2_time,
    }
  end
  return {
    utc_diff = idiv(t1_off, 60),
    dst_offset = idiv(t0_off - t1_off, 60),
    std_name = t1_name,
    dst_name = t0_name,
    starts = t2_rules,
    ends = t1_rules,
    starts_time = t2_time,
    ends_time = t1_time,
  }
end

---------------------------------------------------------------------------
-- The system zone (calendar-time-zone & co.)
---------------------------------------------------------------------------

---@type org.agenda.holidays.Zone?
local system_zone

--- The Emacs calendar zone of the operating system's local time zone, probed
--- once like cal-dst.el does when it is loaded (`calendar-current-time-zone'
--- at the current time; per-year DST dates via `calendar-dst-find-startend').
---@param now? integer UNIX time to probe at (default: now)
---@return org.agenda.holidays.Zone
function M.system_zone(now)
  if system_zone and not now then
    return system_zone
  end
  local cache = dst_find_data(now or os.time())
  local startend = {} ---@type table<integer, org.agenda.holidays.DstData>
  --- calendar-dst-find-startend
  local function find_startend(year)
    local e = startend[year]
    if not e then
      -- (encode-time 1 0 0 1 1 year), the current year when out of range
      local t = os.time({ year = year, month = 1, day = 1, hour = 0, min = 0, sec = 1 })
      if not t then
        local this_year = tonumber(os.date("%Y")) --[[@as integer]]
        t = os.time({ year = this_year, month = 1, day = 1, hour = 0, min = 0, sec = 1 })
      end
      e = dst_find_data(t)
      startend[year] = e
    end
    return e
  end
  local z = {
    tz = cache.utc_diff or -300,
    dst_offset = cache.dst_offset or 60,
    std_name = cache.std_name or "UTC",
    dst_name = cache.dst_name or "UTC",
    starts_time = cache.starts_time or 120,
  }
  z.ends_time = cache.ends_time or z.starts_time
  --- calendar-dst-starts
  z.starts = function(year)
    local rule = find_startend(year).starts
    if rule then
      return rule_date(rule, year)
    end
    if z.dst_offset ~= 0 then
      return astro.gregorian_from_absolute(astro.nth_named_absday(2, 0, 3, year))
    end
  end
  --- calendar-dst-ends
  z.ends = function(year)
    local rule = find_startend(year).ends
    if rule then
      return rule_date(rule, year)
    end
    if z.dst_offset ~= 0 then
      return astro.gregorian_from_absolute(astro.nth_named_absday(1, 0, 11, year))
    end
  end
  if not now then
    system_zone = z
  end
  return z
end

--- Forget the probed system zone (e.g. after the TZ environment changed).
function M.reset()
  system_zone = nil
end

---------------------------------------------------------------------------
-- Holidays
---------------------------------------------------------------------------

local N_HEMI = { "Vernal Equinox", "Summer Solstice", "Autumnal Equinox", "Winter Solstice" }
local S_HEMI = { "Autumnal Equinox", "Winter Solstice", "Vernal Equinox", "Summer Solstice" }

---@class org.agenda.holidays.SolarOpts
---@field zone? org.agenda.holidays.Zone the calendar zone (default: `system_zone()`)
---@field latitude? number `calendar-latitude` (southern hemisphere names when < 0)

---@alias org.agenda.holidays.Entry { day: integer, name: string }

local function to_day(month, day, year)
  return astro.absolute_from_gregorian(month, day, year) - EPOCH_ABS
end

--- solar-equinoxes-solstices-1: the entry for equinox/solstice K of YEAR.
---@param z org.agenda.holidays.Zone
---@return integer abs_date
---@return string name
local function equinox_solstice(z, k, year, latitude)
  local m0, d0, y0 = astro.equinoxes_solstices(z.tz, k, year)
  local fd = floor(d0)
  local h0 = 24 * (d0 - fd)
  local am, ad, ay, atime = astro.dst_adjust_time(z, m0, fd, y0, h0)
  local abs_day = astro.absolute_from_gregorian(am, ad + atime / 24.0, ay)
  local names = (latitude and latitude < 0) and S_HEMI or N_HEMI
  local fl = floor(abs_day)
  local zone = astro.dst_in_effect(z, abs_day) and z.dst_name or z.std_name
  return fl, names[k + 1] .. " " .. astro.time_string(24 * (abs_day - fl), zone)
end

local eq_cache = {} ---@type table<org.agenda.holidays.Zone, table<string, org.agenda.holidays.Entry[]>>

--- solar-equinoxes-solstices, as `calendar-check-holidays' sees it for every
--- day of Gregorian YEAR: the equinoxes and solstices with their local time.
---@param year integer
---@param opts? org.agenda.holidays.SolarOpts
---@return org.agenda.holidays.Entry[]
function M.equinoxes_solstices(year, opts)
  opts = opts or {}
  local z = opts.zone or M.system_zone()
  local key = year .. ":" .. tostring(opts.latitude)
  eq_cache[z] = eq_cache[z] or {}
  local cached = eq_cache[z][key]
  if cached then
    return cached
  end
  local res = {}
  for k = 0, 3 do
    -- The window of month 3(k+1) only keeps an entry dated in that month.
    local abs_date, name = equinox_solstice(z, k, year, opts.latitude)
    local m, _, y = astro.gregorian_from_absolute(abs_date)
    if m == 3 * (k + 1) and y == year then
      res[#res + 1] = { day = abs_date - EPOCH_ABS, name = name }
    end
  end
  eq_cache[z][key] = res
  return res
end

--- The `holiday-sexp' entry of a DST date function for YEAR (nil when there
--- is none or the date is not a valid Gregorian date).
local function dst_entry(fn, year, text)
  local m, d, y = fn(year)
  if not m or not astro.date_is_valid_p(m, d, y) or y ~= year then
    return nil
  end
  return { day = to_day(m, d, y), name = text }
end

--- The "Daylight Saving Time Begins" entry of `holiday-solar-holidays' in YEAR.
---@param year integer
---@param opts? org.agenda.holidays.SolarOpts
---@return org.agenda.holidays.Entry[]
function M.dst_begins(year, opts)
  local z = (opts and opts.zone) or M.system_zone()
  local text = "Daylight Saving Time Begins " .. astro.time_string(z.starts_time / 60.0, z.std_name)
  local e = z.starts and dst_entry(z.starts, year, text)
  return { e }
end

--- The "Daylight Saving Time Ends" entry of `holiday-solar-holidays' in YEAR.
---@param year integer
---@param opts? org.agenda.holidays.SolarOpts
---@return org.agenda.holidays.Entry[]
function M.dst_ends(year, opts)
  local z = (opts and opts.zone) or M.system_zone()
  local text = "Daylight Saving Time Ends " .. astro.time_string(z.ends_time / 60.0, z.dst_name)
  local e = z.ends and dst_entry(z.ends, year, text)
  return { e }
end

--- Both DST entries of YEAR: the "Begins" form's entries, then the "Ends"
--- form's (the order of `holiday-solar-holidays').
---@param year integer
---@param opts? org.agenda.holidays.SolarOpts
---@return org.agenda.holidays.Entry[]
function M.dst(year, opts)
  local res = M.dst_begins(year, opts)
  vim.list_extend(res, M.dst_ends(year, opts))
  return res
end

return M
