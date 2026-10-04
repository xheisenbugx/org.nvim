---@mod org.clock.range Time ranges of clock tables (:block, :tstart, :tend)
---
--- org-clock-special-range and org-matcher-time, with the ISO week and
--- month arithmetic they share with clocktable steps and shifts.
---
--- Part of org.clock, which loads it.

local config = require("org.config")
local date = require("org.date")
local shared = require("org.clock.shared")

local M = require("org.clock")

local MONTH_NAMES = {
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
}
local DAY_NAMES = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" }
local ORDINALS = { "1st", "2nd", "3rd", "4th" }

--- A date from a year, month and day that may overflow (like encode-time).
local function mkdate(y, m, d)
  local total = y * 12 + (m - 1)
  local yy = math.floor(total / 12)
  return date.from_days(date.days_from_civil(yy, total - yy * 12 + 1, 1) + d - 1)
end

--- Monday of ISO week `w` of year `y`.
local function iso_week_start(y, w)
  local jan4 = date.from_days(date.days_from_civil(y, 1, 4))
  return jan4:add(-(jan4:weekday() - 1) + (w - 1) * 7, "d")
end

--- ISO year and week of a date ("%G", "%V").
local function iso_week(d)
  local thursday = d:days() + (4 - d:weekday())
  local iy = date.civil_from_days(thursday)
  return iy, math.floor((thursday - date.days_from_civil(iy, 1, 1)) / 7) + 1
end

local function iso_week_shift(y, w, n)
  return iso_week(iso_week_start(y, w):add(7 * n, "d"))
end

--- Resolve a `:block` (org-clock-special-range): `today`, `yesterday`,
--- `thisweek`, `lastweek`, `thismonth`, `lastmonth`, `thisq`, `lastq`,
--- `thisyear`, `lastyear` (the `this*` and `today` forms take a `-N`/`+N`
--- shift), `untilnow`, `2026`, `2026-09`, `2026-W39`, `2026-Q3`,
--- `2026-09-23`. Returns the range in minutes (from is nil for
--- `untilnow`) and the text used in the table caption.
---@param key string|integer
---@param wstart? integer first day of the week (1 = Monday, 0 = Sunday)
---@param mstart? integer first day of the month
---@return integer|nil from_min, integer to_min, string text
function M.special_range(key, wstart, mstart)
  local now = date.now()
  local y, month, d = now.year, now.month, now.day
  local dow = now:weekday() % 7 -- 0 = Sunday, like decode-time
  local q = math.floor((month - 1) / 3) + 1
  local skey = tostring(key)
  local shift = 0
  local kind
  if skey:match("^%d+$") then
    y, month, d, kind = tonumber(skey), 1, 1, "year"
  elseif skey:match("^%d+%-%d%d?$") then
    local a, b = skey:match("^(%d+)%-(%d+)$")
    y, month, d, kind = tonumber(a), tonumber(b), 1, "month"
  elseif skey:match("^%d+%-[wW]%d%d?$") then
    local a, b = skey:match("^(%d+)%-[wW](%d+)$")
    local s = iso_week_start(tonumber(a), tonumber(b))
    y, month, d, dow, kind = s.year, s.month, s.day, 1, "week"
  elseif skey:match("^%d+%-[qQ][1-4]$") then
    local a, b = skey:match("^(%d+)%-[qQ](%d)$")
    y, q, kind = tonumber(a), tonumber(b), "quarter"
  elseif skey:match("^%d+%-%d%d?%-%d%d?$") then
    local a, b, c = skey:match("^(%d+)%-(%d+)%-(%d+)$")
    y, month, d, kind = tonumber(a), tonumber(b), tonumber(c), "day"
  else
    local base, n = skey:match("^(.-)([-+]%d+)$")
    if base then
      kind, shift = base, tonumber(n)
    else
      kind = skey
    end
  end
  if shift == 0 then
    local last = { yesterday = "today", lastweek = "week", lastmonth = "month", lastyear = "year", lastq = "quarter" }
    if last[kind] then
      kind, shift = last[kind], -1
    end
  end
  local s, e, text
  if kind == "day" or kind == "today" then
    s = mkdate(y, month, d + shift)
    e = s:add(1, "d")
    text = string.format("%s, %s %02d, %d", DAY_NAMES[s:weekday()], MONTH_NAMES[s.month], s.day, s.year)
  elseif kind == "week" or kind == "thisweek" then
    local diff = -7 * shift + (dow + 7 - (tonumber(wstart) or 1)) % 7
    s = mkdate(y, month, d - diff)
    e = s:add(7, "d")
    text = string.format("week %d-W%02d", iso_week(s))
  elseif kind == "month" or kind == "thismonth" then
    s = mkdate(y, month + shift, tonumber(mstart) or 1)
    e = mkdate(y, month + shift + 1, tonumber(mstart) or 1)
    text = MONTH_NAMES[s.month] .. " " .. s.year
  elseif kind == "quarter" or kind == "thisq" then
    local idx = q - 1 + shift
    local qy, qq = y + math.floor(idx / 4), idx % 4
    s = mkdate(qy, 3 * qq + 1, 1)
    e = mkdate(qy, 3 * qq + 4, 1)
    text = ORDINALS[qq + 1] .. " quarter of " .. qy
  elseif kind == "year" or kind == "thisyear" then
    s = mkdate(y + shift, 1, 1)
    e = mkdate(y + shift + 1, 1, 1)
    text = "the year " .. s.year
  elseif kind == "untilnow" then
    return nil, now:minutes(), "now"
  else
    error("No such time block " .. skey, 0)
  end
  -- the days of a block start at `extend_today_until` o'clock, like Emacs
  local ext = (tonumber(config.opts.extend_today_until) or 0) * 60
  return s:minutes() + ext, e:minutes() + ext, text
end

--- Kept for callers of the old API: the range of a `:block`, or nil.
function M.block_range(block)
  if not block or block == "" then
    return nil
  end
  local ok, from, to = pcall(M.special_range, block)
  if not ok then
    return nil
  end
  return from, to
end

--- Interpret a `:tstart` / `:tend` value (org-matcher-time): a timestamp,
--- `<now>`, `<today>`, `<tomorrow>`, `<yesterday>`, or `<-2d>`-style
--- offsets (h counts from now, d w m y from today). Unknown values mean the
--- epoch, like Emacs.
---@return integer minutes
function M.matcher_time(s)
  s = tostring(s)
  local now = date.now():minutes()
  -- the calendar day, not org-today (Emacs ignores extend_today_until here)
  local today = date.now():days() * 1440
  if s == "<now>" then
    return now
  elseif s == "<today>" then
    return today
  elseif s == "<tomorrow>" then
    return today + 1440
  elseif s == "<yesterday>" then
    return today - 1440
  end
  local n, unit = s:match("^<([-+]%d+)([hdwmy])>$")
  if n then
    local mult = { h = 60, d = 1440, w = 10080, m = 44640, y = 525960 }
    return (unit == "h" and now or today) + tonumber(n) * mult[unit]
  end
  local y, m, d = s:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if y then
    local hh, mm = s:match("%d%d%d%d%-%d%d%-%d%d[^%d%]>]*%s(%d%d?):(%d%d)")
    return date.days_from_civil(tonumber(y), tonumber(m), tonumber(d)) * 1440
      + (tonumber(hh) or 0) * 60
      + (tonumber(mm) or 0)
  end
  return 0
end

-- for the parts loaded after this one
shared.iso_week_shift = iso_week_shift
shared.mkdate = mkdate
