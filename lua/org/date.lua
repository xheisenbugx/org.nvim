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

--- Today (no time component).
function M.today()
  local t = os.date("*t")
  return Date.new({ year = t.year, month = t.month, day = t.day })
end

--- Now (with hour & minute).
function M.now()
  local t = os.date("*t")
  return Date.new({ year = t.year, month = t.month, day = t.day, hour = t.hour, min = t.min })
end

function M.today_days()
  local t = os.date("*t")
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
function Date:add(n, unit)
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
    c.year = floor(total / 12)
    c.month = total % 12 + 1
    c.day = math.min(self.day, M.days_in_month(c.year, c.month))
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

--- Parse `H:MM`, `1h30min`, `90`, `1d 2h`, `1.5h` into minutes.
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
  if str:match("^%d+%.?%d*$") then
    return tonumber(str)
  end
  local total, found = 0, false
  local mult = { min = 1, m = 1, h = 60, d = 1440, w = 10080, mon = 43200, y = 525600 }
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
  local guard = 0
  while cur:days() <= to_days and guard < 5000 do
    if cur:days() >= from_days then
      out[#out + 1] = cur
    end
    cur = cur:add(r.value, r.unit == "h" and "h" or r.unit)
    guard = guard + 1
  end
  return out
end

--- Warning days for a deadline: explicit `-Nd` or config default.
function M.warning_days(ts, default)
  if ts.warning then
    local w = ts.warning
    local mult = { h = 1 / 24, d = 1, w = 7, m = 30, y = 365 }
    return floor(w.value * (mult[w.unit] or 1))
  end
  return default or 14
end

---------------------------------------------------------------------------
-- org-read-date: parse free-form date input relative to a default date
---------------------------------------------------------------------------

local DAY_LOOKUP = {}
for i, n in ipairs(M.DAY_NAMES_LONG) do
  DAY_LOOKUP[n:lower()] = i
  DAY_LOOKUP[n:lower():sub(1, 3)] = i
  DAY_LOOKUP[n:lower():sub(1, 2)] = DAY_LOOKUP[n:lower():sub(1, 2)] or i
end
local MONTH_LOOKUP = {}
for i, n in ipairs(M.MONTH_NAMES_LONG) do
  MONTH_LOOKUP[n:lower()] = i
  MONTH_LOOKUP[n:lower():sub(1, 3)] = i
end

local function parse_time_token(tok)
  local h1, m1, h2, m2 = tok:match("^(%d%d?):(%d%d)%-(%d%d?):(%d%d)$")
  if h1 then
    return tonumber(h1), tonumber(m1), tonumber(h2), tonumber(m2)
  end
  -- 10:00+1:30 (duration)
  local h, m, dh, dm = tok:match("^(%d%d?):(%d%d)%+(%d%d?):(%d%d)$")
  if h then
    local e = tonumber(h) * 60 + tonumber(m) + tonumber(dh) * 60 + tonumber(dm)
    return tonumber(h), tonumber(m), floor(e / 60) % 24, e % 60
  end
  h, m = tok:match("^(%d%d?):(%d%d)$")
  if h then
    return tonumber(h), tonumber(m)
  end
  local hh, mm, ap = tok:match("^(%d%d?):?(%d?%d?)([ap]m)$")
  if hh then
    local hour = tonumber(hh) % 12
    if ap == "pm" then
      hour = hour + 12
    end
    return hour, tonumber(mm) or 0
  end
  return nil
end

--- Parse org-read-date style input.
---
--- Examples (relative to `default`, usually today):
---   ""/"."/"today"   today              "+3d" "-2w" "+1m" "+4"   relative
---   "++3d"           relative to default (not today)
---   "fri" "+2fri"    next Friday / Friday in 2 weeks
---   "2026-10-01" "26-10-01" "10/1" "10/1/2026" "15"   absolute
---   "sep 15" "15 sep 2027"                            month names
---   "14:00" "2pm" "10:00-11:30" "10:00+1:30"          times (combinable)
---   "tomorrow" "yesterday" "now"
---@param input string
---@param default? table default date (defaults to today)
---@return table|nil
function M.read_date(input, default)
  local today = M.today()
  default = default or today
  input = vim.trim((input or ""):lower())
  local result = default:clone({ range_end = vim.NIL })
  local explicit_time = false
  if input == "" or input == "." then
    return input == "." and today:clone() or result
  end

  -- extract time tokens
  local rest = {}
  local hour, min, ehour, emin
  for tok in input:gmatch("%S+") do
    local h, m, eh, em = parse_time_token(tok)
    if h then
      hour, min, ehour, emin = h, m, eh, em
      explicit_time = true
    else
      rest[#rest + 1] = tok
    end
  end
  local text = table.concat(rest, " ")
  local base = default:clone()
  local ok = text == ""

  local function set_days(n)
    local y, m, d = M.civil_from_days(n)
    base.year, base.month, base.day = y, m, d
    ok = true
  end

  if text == "today" or text == "." then
    set_days(today:days())
  elseif text == "now" then
    local now = M.now()
    set_days(now:days())
    hour, min = now.hour, now.min
    explicit_time = true
  elseif text == "tomorrow" then
    set_days(today:days() + 1)
  elseif text == "yesterday" then
    set_days(today:days() - 1)
  end

  if not ok then
    -- relative: ++3d / +3d / -2w / +3 / +2fri
    local sign, num, unit = text:match("^([%+%-]+)(%d*)(%a*)$")
    if sign then
      local from_default = sign == "++" or sign == "--"
      local neg = sign:sub(1, 1) == "-"
      local n = tonumber(num) or 1
      local anchor = from_default and default or today
      if unit == "" or unit == "d" then
        set_days(anchor:days() + (neg and -n or n))
      elseif unit == "w" or unit == "m" or unit == "y" or unit == "h" then
        local shifted = anchor:add(neg and -n or n, unit)
        set_days(shifted:days())
        if unit == "h" then
          hour, min = shifted.hour, shifted.min
          explicit_time = true
        end
      elseif DAY_LOOKUP[unit] then
        local wd = DAY_LOOKUP[unit]
        local diff = (wd - anchor:weekday()) % 7
        if neg then
          diff = -((anchor:weekday() - wd) % 7)
          if diff == 0 then
            diff = -7
          end
          set_days(anchor:days() + diff - (n - 1) * 7)
        else
          if diff == 0 then
            diff = 7
          end
          set_days(anchor:days() + diff + (n - 1) * 7)
        end
      end
    end
  end

  if not ok then
    -- weekday name: nearest on or after today
    local wd = DAY_LOOKUP[text]
    if wd then
      local diff = (wd - today:weekday()) % 7
      set_days(today:days() + diff)
    end
  end

  if not ok then
    -- ISO: 2026-10-01, 26-10-01, 10-01
    local y, m, d = text:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$")
    if not y then
      y, m, d = text:match("^(%d%d)%-(%d%d?)%-(%d%d?)$")
      if y then
        y = 2000 + tonumber(y)
      end
    end
    if y then
      base.year, base.month, base.day = tonumber(y), tonumber(m), tonumber(d)
      ok = true
    else
      m, d = text:match("^(%d%d?)%-(%d%d?)$")
      if m then
        base.year, base.month, base.day = today.year, tonumber(m), tonumber(d)
        if base:days() < today:days() then
          base.year = base.year + 1
        end
        ok = true
      end
    end
  end

  if not ok then
    -- US style: 10/1, 10/1/2026, 10/1/26
    local m, d, y = text:match("^(%d%d?)/(%d%d?)/?(%d*)$")
    if m then
      base.month, base.day = tonumber(m), tonumber(d)
      if y ~= "" then
        y = tonumber(y)
        base.year = y < 100 and 2000 + y or y
      else
        base.year = today.year
        if base:days() < today:days() then
          base.year = base.year + 1
        end
      end
      ok = true
    end
  end

  if not ok then
    -- month names: "sep 15", "15 sep", "sep 15 2027", "15 september 2027"
    local a, b, c = text:match("^(%w+)%s+(%w+)%s*(%d*)$")
    if a then
      local mon, day
      if MONTH_LOOKUP[a] and tonumber(b) then
        mon, day = MONTH_LOOKUP[a], tonumber(b)
      elseif MONTH_LOOKUP[b] and tonumber(a) then
        mon, day = MONTH_LOOKUP[b], tonumber(a)
      end
      if mon then
        base.month, base.day = mon, day
        if c ~= "" then
          base.year = tonumber(c)
        else
          base.year = today.year
          if base:days() < today:days() then
            base.year = base.year + 1
          end
        end
        ok = true
      end
    end
  end

  if not ok then
    -- bare day of month: next occurrence
    local d = tonumber(text:match("^(%d%d?)$") or "")
    if d and d >= 1 and d <= 31 then
      base.year, base.month, base.day = today.year, today.month, d
      if d < today.day then
        local nxt = Date.new({ year = today.year, month = today.month, day = 1 }):add(1, "m")
        base.year, base.month = nxt.year, nxt.month
      end
      ok = true
    end
  end

  if not ok then
    return nil
  end
  if base.day > M.days_in_month(base.year, base.month) or base.month < 1 or base.month > 12 then
    return nil
  end
  if explicit_time then
    base.hour, base.min, base.end_hour, base.end_min = hour, min, ehour, emin
  end
  return base
end

return M
