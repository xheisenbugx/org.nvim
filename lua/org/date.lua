---@mod org.date Timestamps
---
--- Pure-Lua org timestamps. Day arithmetic uses a proleptic Gregorian day
--- number (days since 1970-01-01), so DST never shifts a date.
---
--- A timestamp object:
---   year, month, day            integers
---   hour, min                   integers or nil (no time)
---   end_hour, end_min           time range within the day (<... 10:00-11:00>)
---   active                      boolean (<...> vs [...])
---   repeater                    { type = "+"|"++"|".+", value = n, unit = "h|d|w|m|y", max = {value, unit}? }
---   warning                     { type = "-"|"--", value = n, unit = "h|d|w|m|y" }
---   range_end                   another timestamp for <a>--<b> ranges (set by parse_all)

local M = {}

local Date = {}
Date.__index = Date
M.Date = Date

M.DAY_NAMES = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
M.DAY_NAMES_LONG = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" }
M.MONTH_NAMES = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
M.MONTH_NAMES_LONG = {
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
}

local floor = math.floor

--- Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
function M.days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = floor(y / 400)
  local yoe = y - era * 400
  local mp = m > 2 and m - 3 or m + 9
  local doy = floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

--- Civil date for a day number.
function M.civil_from_days(z)
  z = z + 719468
  local era = floor(z / 146097)
  local doe = z - era * 146097
  local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524) - floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
  local mp = floor((5 * doy + 2) / 153)
  local d = doy - floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  return (m <= 2 and y + 1 or y), m, d
end

function M.is_leap(y)
  return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

function M.days_in_month(y, m)
  local dim = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if m == 2 and M.is_leap(y) then
    return 29
  end
  return dim[m]
end

---@return table
function Date.new(t)
  t = t or {}
  local self = setmetatable({
    year = t.year,
    month = t.month,
    day = t.day,
    hour = t.hour,
    min = t.min,
    end_hour = t.end_hour,
    end_min = t.end_min,
    active = t.active ~= false,
    repeater = t.repeater and vim.deepcopy(t.repeater) or nil,
    warning = t.warning and vim.deepcopy(t.warning) or nil,
    range_end = t.range_end,
  }, Date)
  if self.hour and not self.min then
    self.min = 0
  end
  return self
end

--- A new date from a day number (no time).
function M.from_days(n, t)
  local y, m, d = M.civil_from_days(n)
  local o = vim.tbl_extend("force", t or {}, { year = y, month = m, day = d })
  return Date.new(o)
end

--- Hours after midnight that still count as the previous day
--- (org-extend-today-until).
local function extend_today_until()
  local ok, config = pcall(require, "org.config")
  local v = ok and config.opts and config.opts.extend_today_until or 0
  return tonumber(v) or 0
end

--- Today (no time component). Before `extend_today_until` o'clock this is
--- still the previous day, like Emacs `org-today`.
function M.today()
  local t = os.date("*t", os.time() - extend_today_until() * 3600)
  return Date.new({ year = t.year, month = t.month, day = t.day })
end

--- Now (with hour & minute).
function M.now()
  local t = os.date("*t")
  return Date.new({ year = t.year, month = t.month, day = t.day, hour = t.hour, min = t.min })
end

--- The time recorded by CLOSED and log notes (org-current-effective-time):
--- with `use_effective_time`, before `extend_today_until` o'clock it is
--- 23:59 of the previous day.
function M.effective_now()
  local now = M.now()
  local ok, config = pcall(require, "org.config")
  if ok and config.opts.use_effective_time and now.hour < extend_today_until() then
    local y = now:add(-1, "d")
    return y:clone({ hour = 23, min = 59 })
  end
  return now
end

function M.today_days()
  local t = M.today()
  return M.days_from_civil(t.year, t.month, t.day)
end

--- From a unix time.
function M.from_time(epoch, with_time)
  local t = os.date("*t", epoch)
  return Date.new({
    year = t.year,
    month = t.month,
    day = t.day,
    hour = with_time and t.hour or nil,
    min = with_time and t.min or nil,
  })
end

function Date:clone(overrides)
  local c = Date.new(self)
  if overrides then
    for k, v in pairs(overrides) do
      if v == vim.NIL then
        c[k] = nil
      else
        c[k] = v
      end
    end
  end
  return c
end

--- Day number (days since epoch).
function Date:days()
  return M.days_from_civil(self.year, self.month, self.day)
end

--- ISO weekday: 1 = Monday ... 7 = Sunday.
function Date:weekday()
  return (self:days() + 3) % 7 + 1
end

function Date:dayname()
  return M.DAY_NAMES[self:weekday()]
end

function Date:has_time()
  return self.hour ~= nil
end

--- Minutes since epoch (local wall time; time defaults to 00:00).
function Date:minutes()
  return self:days() * 1440 + (self.hour or 0) * 60 + (self.min or 0)
end

--- Minutes for the end of a time range, or nil.
function Date:end_minutes()
  if self.end_hour then
    return self:days() * 1440 + self.end_hour * 60 + (self.end_min or 0)
  end
end

--- Unix time (via os.time, local timezone).
function Date:to_time()
  return os.time({
    year = self.year,
    month = self.month,
    day = self.day,
    hour = self.hour or 0,
    min = self.min or 0,
    sec = 0,
    isdst = nil,
  })
end

--- os.date-style formatting.
function Date:strftime(fmt)
  return os.date(fmt, self:to_time())
end

--- Compare two dates. With `day_only`, the time is ignored.
---@return integer -1, 0, 1
function Date:compare(other, day_only)
  local a, b
  if day_only then
    a, b = self:days(), other:days()
  else
    a, b = self:minutes(), other:minutes()
  end
  if a < b then
    return -1
  elseif a > b then
    return 1
  end
  return 0
end

function Date:is_same_day(other)
  return self:days() == other:days()
end

function Date.__eq(a, b)
  return a:minutes() == b:minutes()
end

function Date.__lt(a, b)
  return a:minutes() < b:minutes()
end

function Date.__le(a, b)
  return a:minutes() <= b:minutes()
end

--- Return a new date shifted by `n` units. Units: min, h, d, w, m, y.
--- Months and years keep the day and roll over like Emacs (`Jan 31` + 1m
--- = `Mar 3`); with `clamp`, the day is clamped to the month's last day
--- instead (calendar movement).
function Date:add(n, unit, clamp)
  unit = unit or "d"
  local c = self:clone()
  if n == 0 then
    return c
  end
  if unit == "d" or unit == "w" then
    local days = unit == "w" and n * 7 or n
    local y, m, d = M.civil_from_days(self:days() + days)
    c.year, c.month, c.day = y, m, d
  elseif unit == "m" or unit == "y" then
    local months = unit == "y" and n * 12 or n
    local total = self.year * 12 + (self.month - 1) + months
    local y, m = floor(total / 12), total % 12 + 1
    if clamp then
      c.year, c.month, c.day = y, m, math.min(self.day, M.days_in_month(y, m))
    else
      c.year, c.month, c.day = M.civil_from_days(M.days_from_civil(y, m, 1) + self.day - 1)
    end
  elseif unit == "h" or unit == "min" then
    local minutes = unit == "h" and n * 60 or n
    local dur = c.end_hour and ((c.end_hour * 60 + c.end_min) - (c.hour * 60 + c.min)) or nil
    local total = self:minutes() + minutes
    local days = floor(total / 1440)
    local rem = total - days * 1440
    local y, m, d = M.civil_from_days(days)
    c.year, c.month, c.day = y, m, d
    c.hour = floor(rem / 60)
    c.min = rem % 60
    if dur then
      local e = c.hour * 60 + c.min + dur
      c.end_hour, c.end_min = floor(e / 60) % 24, e % 60
    end
  else
    error("unknown date unit: " .. tostring(unit))
  end
  return c
end

--- Shift the start and range end together.
function Date:add_with_range(n, unit)
  local c = self:add(n, unit)
  if self.range_end then
    c.range_end = self.range_end:add(n, unit)
  end
  return c
end

function Date:start_of(what)
  if what == "week" then
    return M.from_days(self:days() - (self:weekday() - 1))
  elseif what == "month" then
    return Date.new({ year = self.year, month = self.month, day = 1 })
  elseif what == "year" then
    return Date.new({ year = self.year, month = 1, day = 1 })
  end
  return self:clone({ hour = vim.NIL, min = vim.NIL, end_hour = vim.NIL, end_min = vim.NIL })
end

--- Days from today to this date (positive = future).
function Date:days_from_today()
  return self:days() - M.today_days()
end

local function fmt_time(h, m)
  return string.format("%02d:%02d", h, m)
end

--- Format the timestamp in org syntax: `<2026-09-23 Wed 10:00-11:00 +1w -2d>`
---@param opts? { brackets?: boolean }
function Date:to_string(opts)
  opts = opts or {}
  local parts = { string.format("%04d-%02d-%02d %s", self.year, self.month, self.day, self:dayname()) }
  if self.hour then
    local t = fmt_time(self.hour, self.min or 0)
    if self.end_hour then
      t = t .. "-" .. fmt_time(self.end_hour, self.end_min or 0)
    end
    parts[#parts + 1] = t
  end
  if self.repeater then
    local r = self.repeater
    local s = r.type .. r.value .. r.unit
    if r.max then
      s = s .. "/" .. r.max.value .. r.max.unit
    end
    parts[#parts + 1] = s
  end
  if self.warning then
    parts[#parts + 1] = self.warning.type .. self.warning.value .. self.warning.unit
  end
  local body = table.concat(parts, " ")
  if opts.brackets == false then
    return body
  end
  local open, close = "<", ">"
  if not self.active then
    open, close = "[", "]"
  end
  local s = open .. body .. close
  if self.range_end and opts.range ~= false then
    s = s .. "--" .. self.range_end:to_string({ range = false })
  end
  return s
end

Date.__tostring = Date.to_string

--- Plain `YYYY-MM-DD`.
function Date:to_date_string()
  return string.format("%04d-%02d-%02d", self.year, self.month, self.day)
end

function Date:time_string()
  if not self.hour then
    return nil
  end
  local t = fmt_time(self.hour, self.min or 0)
  if self.end_hour then
    t = t .. "-" .. fmt_time(self.end_hour, self.end_min or 0)
  end
  return t
end

---------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------

local UNIT = "[hdwmy]"

--- Parse the inside of a timestamp (without brackets).
local function parse_body(body, active)
  local y, mo, d, rest = body:match("^%s*(%d%d%d%d)%-(%d%d?)%-(%d%d?)(.*)$")
  if not y then
    return nil
  end
  local ts = Date.new({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), active = active })
  if ts.month < 1 or ts.month > 12 or ts.day < 1 or ts.day > 31 then
    return nil
  end
  for token in rest:gmatch("%S+") do
    local h1, m1, h2, m2 = token:match("^(%d%d?):(%d%d)%-(%d%d?):(%d%d)$")
    if h1 then
      ts.hour, ts.min, ts.end_hour, ts.end_min = tonumber(h1), tonumber(m1), tonumber(h2), tonumber(m2)
    else
      local h, m = token:match("^(%d%d?):(%d%d)$")
      if h then
        ts.hour, ts.min = tonumber(h), tonumber(m)
      else
        local rtype, rval, runit, rest2 = token:match("^([%.%+]?%+)(%d+)(" .. UNIT .. ")(.*)$")
        if rtype and (rtype == "+" or rtype == "++" or rtype == ".+") then
          ts.repeater = { type = rtype, value = tonumber(rval), unit = runit }
          local mv, mu = rest2:match("^/(%d+)(" .. UNIT .. ")$")
          if mv then
            ts.repeater.max = { value = tonumber(mv), unit = mu }
          end
        else
          local wtype, wval, wunit = token:match("^(%-%-?)(%d+)(" .. UNIT .. ")$")
          if wtype then
            ts.warning = { type = wtype, value = tonumber(wval), unit = wunit }
          end
          -- anything else (day names, in any language) is ignored
        end
      end
    end
  end
  return ts
end

--- Parse a single timestamp string like `<2026-09-23 Wed>` or `[2026-09-23]`.
---@return table|nil
function M.parse(str)
  if not str then
    return nil
  end
  local list = M.parse_all(str)
  return list[1] and list[1].date or nil
end

--- Find every timestamp in a line.
--- Returns list of { date, start_col, end_col (1-based, inclusive), raw }.
--- `<a>--<b>` ranges yield one entry whose date has `range_end`.
function M.parse_all(line)
  local out = {}
  local init = 1
  while true do
    local s, e, open, body, close = line:find("([<%[])(%d%d%d%d%-%d%d?%-%d%d?[^<>%[%]\n]-)([>%]])", init)
    if not s then
      break
    end
    local active = open == "<"
    if (active and close == ">") or (not active and close == "]") then
      local ts = parse_body(body, active)
      if ts then
        local item = { date = ts, start_col = s, end_col = e, raw = line:sub(s, e) }
        -- range?
        local rs, re, ropen, rbody, rclose =
          line:find("^%-%-([<%[])(%d%d%d%d%-%d%d?%-%d%d?[^<>%[%]\n]-)([>%]])", e + 1)
        if rs and ((ropen == "<" and rclose == ">") or (ropen == "[" and rclose == "]")) then
          local ts2 = parse_body(rbody, ropen == "<")
          if ts2 then
            ts.range_end = ts2
            item.end_col = re
            item.raw = line:sub(s, re)
            e = re
          end
        end
        out[#out + 1] = item
      end
    end
    init = e + 1
  end
  return out
end

--- Timestamp at a 1-based byte column of a line (or nil).
function M.at_col(line, col)
  for _, item in ipairs(M.parse_all(line)) do
    if col >= item.start_col and col <= item.end_col then
      return item
    end
  end
end

--- Duration string `H:MM` for minutes.
function M.format_duration(minutes)
  local neg = minutes < 0
  minutes = math.abs(floor(minutes + 0.5))
  local s = string.format("%d:%02d", floor(minutes / 60), minutes % 60)
  return neg and "-" .. s or s
end

--- Duration in org-duration style: `H:MM`, or `Nd H:MM` from one day on
--- when `duration_format` is "d h:mm" (the default, like Emacs
--- `org-duration-format`). `fmt` overrides the option.
---@param minutes number
---@param fmt? "h:mm"|"d h:mm"
function M.duration_to_string(minutes, fmt)
  fmt = fmt or require("org.config").opts.duration_format or "d h:mm"
  local m = floor(math.abs(minutes) + 0.5)
  if fmt ~= "d h:mm" or m < 1440 then
    return M.format_duration(minutes)
  end
  local days = floor(m / 1440)
  return (minutes < 0 and "-" or "") .. days .. "d " .. M.format_duration(m - days * 1440)
end

--- Parse `H:MM`, `H:MM:SS`, `1h30min`, `90`, `1d 2h`, `1.5h` into minutes.
function M.parse_duration(str)
  if not str then
    return nil
  end
  str = vim.trim(str)
  if str == "" then
    return nil
  end
  local d, h, m = str:match("^(%d+)d%s+(%d+):(%d%d)$")
  if d then
    return tonumber(d) * 1440 + tonumber(h) * 60 + tonumber(m)
  end
  h, m = str:match("^(%d+):(%d%d)$")
  if h then
    return tonumber(h) * 60 + tonumber(m)
  end
  local sec
  h, m, sec = str:match("^(%d+):(%d%d):(%d%d)$")
  if h then
    return tonumber(h) * 60 + tonumber(m) + tonumber(sec) / 60
  end
  if str:match("^%d+%.?%d*$") then
    return tonumber(str)
  end
  local total, found = 0, false
  local mult = { min = 1, m = 1, h = 60, d = 1440, w = 10080, mon = 43200, y = 525960 }
  for num, unit in str:gmatch("(%d+%.?%d*)%s*(%a+)") do
    local f = mult[unit]
    if not f then
      return nil
    end
    total = total + tonumber(num) * f
    found = true
  end
  return found and floor(total + 0.5) or nil
end

---------------------------------------------------------------------------
-- Repeaters
---------------------------------------------------------------------------

--- Next occurrence for a repeated timestamp when marked DONE (org-auto-repeat-maybe).
---@param ts table
---@param now? table defaults to M.now()
function M.apply_repeater(ts, now)
  local r = ts.repeater
  if not r then
    return ts
  end
  now = now or M.now()
  local unit = r.unit
  local n = r.value
  if n == 0 then
    return ts
  end
  if r.type == "+" then
    return ts:add_with_range(n, unit)
  elseif r.type == "++" then
    local nxt = ts:add_with_range(n, unit)
    local guard = 0
    local cmp_day = not ts:has_time() or unit ~= "h"
    while guard < 100000 do
      if cmp_day then
        if nxt:days() > now:days() then
          break
        end
      elseif nxt:minutes() > now:minutes() then
        break
      end
      nxt = nxt:add_with_range(n, unit)
      guard = guard + 1
    end
    return nxt
  elseif r.type == ".+" then
    local base
    if unit == "h" then
      base = ts:clone({ year = now.year, month = now.month, day = now.day, hour = now.hour, min = now.min })
    else
      base = ts:clone({ year = now.year, month = now.month, day = now.day })
    end
    local shifted = base:add(n, unit)
    if ts.range_end then
      local delta = ts.range_end:days() - ts:days()
      shifted.range_end = ts.range_end:add(shifted:days() + delta - ts.range_end:days(), "d")
    end
    return shifted
  end
  return ts
end

--- All occurrences of a (possibly repeating) timestamp between two day numbers.
--- Returns list of dates (clones), each representing an occurrence.
function M.occurrences(ts, from_days, to_days)
  local out = {}
  if not ts.repeater or ts.repeater.value == 0 then
    local d = ts:days()
    if d >= from_days and d <= to_days then
      out[1] = ts
    end
    return out
  end
  local r = ts.repeater
  local cur = ts
  local start = cur:days()
  if start > to_days then
    return out
  end
  -- jump close to `from_days` for day/week units
  if start < from_days and (r.unit == "d" or r.unit == "w") then
    local step = r.unit == "w" and r.value * 7 or r.value
    local skip = floor((from_days - start) / step)
    if skip > 0 then
      cur = cur:add(skip * step, "d")
    end
  end
  -- occurrence k is computed from the start (no drift at month ends,
  -- like org-closest-date)
  local base, k = cur, 0
  local guard = 0
  while cur:days() <= to_days and guard < 5000 do
    if cur:days() >= from_days then
      out[#out + 1] = cur
    end
    k = k + 1
    cur = base:add(k * r.value, r.unit)
    guard = guard + 1
  end
  return out
end

--- Warning days for a deadline: explicit `-Nd` or config default.
function M.warning_days(ts, default)
  if ts.warning then
    local w = ts.warning
    -- org-get-wdays: a month is 30.4 days, a year 365.25
    local mult = { h = 1 / 24, d = 1, w = 7, m = 30.4, y = 365.25 }
    return floor(w.value * (mult[w.unit] or 1))
  end
  return default or 14
end

---------------------------------------------------------------------------
-- org-read-date: parse free-form date input relative to a default date
---------------------------------------------------------------------------
-- A port of `org-read-date-analyze` and of the parts of Emacs
-- `parse-time-string` it relies on.

-- parse-time-weekdays (0 = Sunday) and parse-time-months
local WEEKDAYS = {
  sun = 0, mon = 1, tue = 2, wed = 3, thu = 4, fri = 5, sat = 6,
  sunday = 0, monday = 1, tuesday = 2, wednesday = 3, thursday = 4, friday = 5, saturday = 6,
}
local MONTHS = {
  jan = 1, feb = 2, mar = 3, apr = 4, may = 5, jun = 6, jul = 7, aug = 8, sep = 9, oct = 10, nov = 11, dec = 12,
  january = 1, february = 2, march = 3, april = 4, june = 6, july = 7, august = 8, september = 9,
  october = 10, november = 11, december = 12,
}
-- zone names parse-time-string swallows
local ZONES = { z = true, ut = true, gmt = true, pst = true, pdt = true, mst = true, mdt = true }
for _, z in ipairs({ "cst", "cdt", "est", "edt" }) do
  ZONES[z] = true
end

--- Two-digit years become one of the next 30 years or a past one
--- (org-small-year-to-year).
function M.small_year_to_year(year)
  if year >= 100 then
    return year
  end
  local current = tonumber(os.date("%Y"))
  local century = floor(current / 100)
  local offset = year - current % 100
  if offset > 30 then
    return (century - 1) * 100 + year
  elseif offset > -70 then
    return century * 100 + year
  end
  return (century + 1) * 100 + year
end

--- Emacs `parse-time-string` for the forms org-read-date-analyze needs.
--- Returns { sec, min, hour, day, month, year, wday } (nil when unknown).
local function parse_time_string(s)
  local t = {}
  for tok in s:gmatch("[a-z0-9+%-:]+") do
    local num = tok:match("^%d+$") and tonumber(tok) or nil
    local function free(slot)
      return t[slot] == nil
    end
    if free("wday") and WEEKDAYS[tok] then
      t.wday = WEEKDAYS[tok]
    elseif free("day") and num and num >= 1 and num <= 31 then
      t.day = num
    elseif free("month") and MONTHS[tok] then
      t.month = MONTHS[tok]
    elseif free("year") and num and num >= 100 then
      t.year = num
    elseif free("hour") and #tok == 8 and tok:match("^%d%d:%d%d:%d%d$") then
      t.hour, t.min, t.sec = tonumber(tok:sub(1, 2)), tonumber(tok:sub(4, 5)), tonumber(tok:sub(7, 8))
    elseif free("zone") and ZONES[tok] then
      t.zone = tok
    elseif free("zone") and #tok == 5 and tok:match("^[%+%-]%d%d%d%d$") then
      t.zone = tok
    elseif free("year") and #tok == 10 and tok:match("^%d%d%d%d%-%d%d%-%d%d$") then
      t.year, t.month, t.day = tonumber(tok:sub(1, 4)), tonumber(tok:sub(6, 7)), tonumber(tok:sub(9, 10))
    elseif free("hour") and #tok == 5 and tok:match("^%d%d:%d%d$") then
      t.hour, t.min, t.sec = tonumber(tok:sub(1, 2)), tonumber(tok:sub(4, 5)), 0
    elseif free("hour") and #tok == 4 and tok:match("^%d:%d%d$") then
      t.hour, t.min, t.sec = tonumber(tok:sub(1, 1)), tonumber(tok:sub(3, 4)), 0
    elseif free("hour") and #tok == 7 and tok:match("^%d:%d%d:%d%d$") then
      t.hour, t.min, t.sec = tonumber(tok:sub(1, 1)), tonumber(tok:sub(3, 4)), tonumber(tok:sub(6, 7))
    elseif free("year") and num and num >= 50 and num <= 110 then
      t.year = 1900 + num
    elseif free("year") and num and num <= 49 then
      t.year = 2000 + num
    end
  end
  return t
end

--- The relative part at the start of the answer (org-read-date-get-relative):
--- `+3d`, `-2w`, `++1m`, `+4`, `fri`, `+2fri`, `-mon`. Returns
--- n, unit, from_default and the rest of the input.
local function get_relative(s, today, default)
  local sign, num, what, rest = s:match("^[ \t]*([%+%-]?[%+%-]?)(%d*)(%a*)(.*)$")
  if not sign or not (rest == "" or rest:match("^[ \t]")) then
    return nil
  end
  local unit, wday1
  if what == "" then
    unit = "d"
  elseif what:match("^[hdwmy]$") then
    unit = what
  elseif WEEKDAYS[what] then
    wday1 = WEEKDAYS[what]
  else
    return nil
  end
  if sign == "" and not wday1 then
    return nil
  end
  local dir = sign ~= "" and sign:sub(-1) or "+"
  local rel = #sign == 2
  local n = num ~= "" and tonumber(num) or 1
  if wday1 then
    local base = rel and default or today
    local wday = base:weekday() % 7
    local delta = (7 + wday1 - wday) % 7
    if delta == 0 then
      delta = 7
    end
    if dir == "-" then
      delta = delta - 7
      if delta == 0 then
        delta = -7
      end
    end
    if n > 1 then
      delta = delta + (n - 1) * (dir == "-" and -7 or 7)
    end
    return delta, "d", rel, rest
  end
  return n * (dir == "-" and -1 or 1), unit, rel, rest
end

--- Convert am/pm times (twice, for an end time) when there is no plain
--- HH:MM time yet.
local function convert_ampm(ans)
  for _ = 1, 2 do
    local has_plain = ans:match("^[012]?%d:%d%d%f[%s%z]") or ans:match("[^+][012]?%d:%d%d%f[%s%z]")
    if has_plain then
      break
    end
    local s, e, h, m, ap = ans:find("([012]?%d):?(%d?%d?)([ap]m)%f[^%w]")
    if not s or (m ~= "" and #m ~= 2) then
      break
    end
    local hour, minute = tonumber(h), tonumber(m) or 0
    local pm = ap == "pm"
    if hour == 12 and not pm then
      hour = 0
    elseif pm and hour < 12 then
      hour = hour + 12
    end
    ans = ans:sub(1, s - 1) .. string.format("%02d:%02d", hour, minute) .. ans:sub(e + 1)
  end
  return ans
end

--- Convert HHhMM times (15h30, 9h, h30) like am/pm times.
local function convert_hhmm(ans)
  for _ = 1, 2 do
    local has_plain = ans:match("^[012]?%d:%d%d%f[%s%z]") or ans:match("[^+][012]?%d:%d%d%f[%s%z]")
    if has_plain then
      break
    end
    local s, e, h, m = ans:find("%f[%w]([012]?%d?)h([0-5]%d)")
    if not s then
      s, e, h, m = ans:find("%f[%w]([012]?%d)h([0-5]?%d?)%f[^%w]")
      if s and m ~= "" and #m ~= 2 then
        s = nil
      end
    end
    if not s or (h == "" and m == "") then
      break
    end
    ans = ans:sub(1, s - 1)
      .. string.format("%02d:%02d", tonumber(h) or 0, tonumber(m) or 0)
      .. ans:sub(e + 1)
  end
  return ans
end

--- Normalize (year, month, day, hour, min) like `encode-time`: days,
--- months and hours out of range roll over.
local function normalize(year, month, day, hour, min)
  local months = year * 12 + (month - 1)
  year, month = floor(months / 12), months % 12 + 1
  local total = (hour or 0) * 60 + (min or 0)
  local dshift = floor(total / 1440)
  total = total - dshift * 1440
  local days = M.days_from_civil(year, month, 1) + day - 1 + dshift
  local y, m, d = M.civil_from_days(days)
  return y, m, d, floor(total / 60), total % 60
end

--- Parse org-read-date style input, like Emacs `org-read-date-analyze`.
---
--- Examples (relative to `default`, usually now):
---   ""/"."           today / the default   "+3d" "-2w" "+1m" "+4" "+2h"   relative to now
---   "++3d" "--1w"    relative to the default date
---   "fri" "+2fri"    next Friday / Friday in 2 weeks (a weekday name is never today)
---   "2026-10-01" "26-10-01" "10-01" "10/1" "10/1/2026" "15.3." "15" "oct"
---   "sep 15" "15 sep 2027" "2027"                     month names, years
---   "w40" "2026-w40-3" "w40 fri"                      ISO weeks
---   "14:00" "2pm" "15h30" "10:00-11:30" "10:00+1:30" "10am-11am" "24:00"
---   "2026-10-01T10:00"  "2026-10-01 Thu +1w"          ISO times; extra words are ignored
---   "today" "tomorrow" "yesterday" "now"              (extensions)
--- Missing parts come from the default; with `read_date_prefer_future`, a
--- day or month without a year is taken in the future. Dates out of range
--- roll over (`feb 30` = `mar 2`). Returns a date with a time only when
--- one was typed (`end_hour`/`end_min` for a range), or nil when nothing
--- in the input could be read.
---@param input string
---@param default? table default date (defaults to now)
---@return table|nil
function M.read_date(input, default)
  local now = M.now()
  local prefer = require("org.config").opts.read_date_prefer_future
  if prefer == nil then
    prefer = true
  end
  local def
  if default then
    def = default:clone({ range_end = vim.NIL })
    def.hour, def.min = default.hour or 0, default.min or 0
  else
    def = now:clone()
    local ext = tonumber(require("org.config").opts.extend_today_until) or 0
    if now.hour < ext then
      def = now:add(-1, "d"):clone({ hour = 23, min = 59 })
    end
  end
  local ans = (input or ""):lower()
  if ans:match("^[ \t]*%.[ \t]*$") then
    ans = "+0"
  end
  local recognized = vim.trim(ans) == ""
  -- extensions: today / tomorrow / yesterday / now
  local ext_delta, ext_now
  ans = ans:gsub("%f[%a](%a+)%f[^%a]", function(w)
    if w == "today" then
      ext_delta = 0
    elseif w == "tomorrow" then
      ext_delta = 1
    elseif w == "yesterday" then
      ext_delta = -1
    elseif w == "now" then
      ext_delta, ext_now = 0, true
    else
      return nil
    end
    return ""
  end)
  ans = ans:gsub("(%d)t(%d%d?:%d%d)", "%1 %2")

  local deltan, deltaw, deltadef
  local n, w, rel, rest = get_relative(ans, now, def)
  if n then
    deltan, deltaw, deltadef, ans = n, w, rel, rest
    recognized = true
  elseif ext_delta then
    deltan, deltaw, deltadef = ext_delta, "d", false
    recognized = true
  end

  -- ISO week: w40, 2026-w40-3, w40 fri
  local iso_year, iso_week, iso_weekday
  do
    local s, e, y, wk, wd = ans:find("%f[%w](%d*)%-?w(%d%d?)%-?([0-6]?)%f[%s%z]")
    if s and not (y ~= "" and ans:sub(s + #y, s + #y) ~= "-") and not (wd ~= "" and ans:sub(e - 1, e - 1) ~= "-") then
      iso_year = y ~= "" and M.small_year_to_year(tonumber(y)) or nil
      iso_week, iso_weekday = tonumber(wk), wd ~= "" and tonumber(wd) or nil
      ans = ans:sub(1, s - 1) .. ans:sub(e + 2)
      recognized = true
    end
  end

  local kill_year = false
  local cur_year = now.year
  -- ISO dates with single digits, 10-01 (year of today)
  do
    local lead, y, mo, d = ans:match("^( *)(%d+)%-([01]?%d)%-([0-3]?%d)")
    local len
    if lead then
      len = #lead + #y + 1 + #mo + 1 + #d
    else
      lead, mo, d = ans:match("^( *)([01]?%d)%-([0-3]?%d)")
      len = lead and (#lead + #mo + 1 + #d)
    end
    if lead and not ans:sub(len + 1, len + 1):match("[%-%d]") then
      local year
      if y then
        year = tonumber(y)
      else
        kill_year = true
        year = cur_year
      end
      year = M.small_year_to_year(year)
      ans = string.format("%04d-%02d-%02d", year, tonumber(mo), tonumber(d)) .. ans:sub(len + 1)
    end
  end
  -- dotted european dates: 15.3. / 15.3.2027
  do
    local lead, d, mo, rest2 = ans:match("^( *)(%d%d?)%. ?(%d%d?)%.(.*)$")
    local dn, mn = tonumber(d or ""), tonumber(mo or "")
    if lead and dn >= 1 and dn <= 31 and mn >= 1 and mn <= 12 then
      local y = rest2:match("^ ?([1-9]%d%d%d)")
      local year
      if y then
        year = tonumber(y)
        rest2 = rest2:gsub("^ ?[1-9]%d%d%d", "", 1)
      else
        kill_year = true
        year = cur_year
      end
      ans = string.format("%04d-%02d-%02d", year, mn, dn) .. rest2
    end
  end
  -- american dates: 5/30, 5/30/7
  do
    local lead, mo, d, rest2 = ans:match("^( *)(%d%d?)/(%d%d?)(.*)$")
    local mn, dn = tonumber(mo or ""), tonumber(d or "")
    if lead and mn >= 1 and mn <= 12 and dn >= 1 and dn <= 31 then
      local y, rest3 = rest2:match("^/(%d+)(.*)$")
      if y then
        rest2 = rest3
      end
      if rest2 == "" or not rest2:match("^[/%d]") then
        local year
        if y then
          year = tonumber(y)
        else
          kill_year = true
          year = cur_year
        end
        year = M.small_year_to_year(year)
        ans = string.format("%04d-%02d-%02d", year, mn, dn) .. rest2
      end
    end
  end
  ans = convert_ampm(ans)
  ans = convert_hhmm(ans)
  -- a time range given as a duration: 10:00+1:30
  do
    local s, e, h, m, dh, dm = ans:find("([012]?%d):([0-6]%d)%+([012]?%d):?([0-5]?%d?)")
    if s then
      local hour, minute = tonumber(h), tonumber(m)
      local h2, m2 = hour + tonumber(dh), minute + (tonumber(dm) or 0)
      if m2 >= 60 then
        h2, m2 = h2 + 1, m2 - 60
      end
      ans = ans:sub(1, s - 1) .. string.format("%02d:%02d-%02d:%02d", hour, minute, h2, m2) .. ans:sub(e + 1)
    end
  end
  -- a time range: keep the end time, analyze the start
  local end_hour, end_min
  do
    local s = 1
    while true do
      local ts, te, h, m = ans:find("([012]?%d):([0-5]%d)%f[^%w]", s)
      if not ts then
        break
      end
      if ts == 1 or not ans:sub(ts - 1, ts - 1):match("[%w]") then
        local rs, re, eh, em = ans:find("^%-%-?([012]?%d):([0-5]%d)%f[^%w]", te + 1)
        if rs then
          end_hour, end_min = tonumber(eh), tonumber(em)
          ans = ans:sub(1, te) .. ans:sub(re + 1)
        end
        break
      end
      s = te + 1
    end
  end

  local tl = parse_time_string(ans)
  if next(tl) ~= nil then
    recognized = true
  end
  if not recognized then
    return nil
  end
  local futurep = false
  local day = tl.day or def.day
  local month
  if tl.month then
    month = tl.month
  elseif not prefer then
    month = def.month
  elseif tl.day then
    futurep = true
    month = day < now.day and now.month + 1 or now.month
  else
    month = def.month
  end
  local year
  if not kill_year and tl.year then
    year = tl.year
  elseif not prefer then
    year = def.year
  elseif futurep then
    year = (month > now.month or day >= now.day) and now.year or now.year + 1
  elseif tl.month then
    futurep = true
    if month > now.month then
      year = now.year
    elseif month < now.month then
      year = now.year + 1
    elseif day < now.day then
      year = now.year + 1
    else
      year = now.year
    end
  else
    year = def.year
  end
  local hour = tl.hour or def.hour
  local minute = tl.min or def.min
  local wday = tl.wday
  local time_given = tl.hour ~= nil

  if
    prefer == "time"
    and not tl.day
    and not tl.month
    and not tl.year
    and day == now.day
    and month == now.month
    and year == now.year
    and tl.hour
    and (tl.hour < now.hour or (tl.hour == now.hour and tl.min and tl.min < now.min))
  then
    day = day + 1
  end

  if iso_week then
    year = iso_year or year
    local d = iso_weekday or wday or 1
    local jan4 = M.days_from_civil(year, 1, 4)
    local monday1 = jan4 - ((jan4 + 3) % 7)
    local abs = monday1 + (iso_week - 1) * 7 + (d == 0 and 6 or d - 1)
    year, month, day = M.civil_from_days(abs)
  elseif deltan then
    if not deltadef then
      day, month, year = now.day, now.month, now.year
    end
    if deltaw == "h" then
      time_given = true
      hour = hour + deltan
    elseif deltaw == "d" then
      day = day + deltan
    elseif deltaw == "w" then
      day = day + 7 * deltan
    elseif deltaw == "m" then
      month = month + deltan
    elseif deltaw == "y" then
      year = year + deltan
    end
  elseif wday and not tl.day then
    -- a weekday without a day: that day of the week on or after the date
    local y2, m2, d2 = normalize(year, month, day, 0, 0)
    local wday1 = M.days_from_civil(y2, m2, d2)
    wday1 = (wday1 + 4) % 7
    day = day + (wday - wday1 + 7) % 7
  end
  if ext_now then
    hour, minute, time_given = now.hour, now.min, true
  end
  if year < 100 then
    year = year + 2000
  end
  local y, m, d, h, mi = normalize(year, month, day, hour, minute)
  local result = Date.new({ year = y, month = m, day = d, active = def.active })
  if time_given then
    result.hour, result.min = h, mi
    if end_hour then
      result.end_hour, result.end_min = end_hour, end_min
    end
  end
  return result
end

return M
