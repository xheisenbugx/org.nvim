---@mod org.extensions.ics.parser iCalendar (RFC 5545) reader
---
--- Pure Lua: line unfolding, components and properties, VEVENT with
--- DTSTART/DTEND/DURATION (dates, UTC, floating and TZID times), RRULE
--- (SECONDLY to YEARLY with INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY,
--- BYMONTH, BYYEARDAY, BYHOUR, BYMINUTE, BYSECOND, BYSETPOS, WKST), RDATE,
--- EXDATE, RECURRENCE-ID overrides and STATUS:CANCELLED.
---
--- Times are handled as "naive seconds": seconds since 1970-01-01 of the
--- wall clock time, ignoring zones. A TZID is turned into UTC with the
--- system time zone database (its TZif files, `org.extensions.ics.tzif`;
--- `TZ` and `os.time` when a file can't be read), else with the calendar's
--- VTIMEZONE rules, else with a table of Windows zone names; a zone that
--- can't be resolved is read as local time.

local dt = require("org.date")

local M = {}

local floor = math.floor

---------------------------------------------------------------------------
-- Lines, components and properties
---------------------------------------------------------------------------

--- Unfold content lines (RFC 5545 3.1): a line starting with a space or a
--- tab continues the previous one.
---@param text string
---@return string[]
function M.unfold(text)
  text = text:gsub("^\239\187\191", "") -- UTF-8 BOM
  local out = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    local c = line:sub(1, 1)
    if (c == " " or c == "\t") and #out > 0 then
      out[#out] = out[#out] .. line:sub(2)
    elseif line ~= "" then
      out[#out + 1] = line
    end
  end
  return out
end

--- Split a content line into name, params and value.
---@param line string
---@return string|nil name, table params, string value
function M.content_line(line)
  local i, n = 1, #line
  local quoted = false
  local parts = {}
  local start = 1
  local value
  while i <= n do
    local c = line:sub(i, i)
    if c == '"' then
      quoted = not quoted
    elseif not quoted and (c == ";" or c == ":") then
      parts[#parts + 1] = line:sub(start, i - 1)
      start = i + 1
      if c == ":" then
        value = line:sub(i + 1)
        break
      end
    end
    i = i + 1
  end
  if not value then
    return nil, {}, ""
  end
  local name = (parts[1] or ""):upper()
  local params = {}
  for k = 2, #parts do
    local pk, pv = parts[k]:match("^([^=]+)=(.*)$")
    if pk then
      pv = pv:gsub('^"(.*)"$', "%1")
      params[pk:upper()] = pv
    end
  end
  return name, params, value
end

--- Unescape a TEXT value.
function M.text(v)
  return (v:gsub("\\(.)", function(c)
    if c == "n" or c == "N" then
      return "\n"
    end
    return c
  end))
end

--- Parse into a component tree: `{ name, props = { {name, params, value} },
--- children = {...} }`; the root is a pseudo component holding the
--- VCALENDARs.
function M.tree(text)
  local root = { name = "ROOT", props = {}, children = {} }
  local stack = { root }
  for _, line in ipairs(M.unfold(text)) do
    local name, params, value = M.content_line(line)
    if name == "BEGIN" then
      local comp = { name = vim.trim(value):upper(), props = {}, children = {} }
      local top = stack[#stack]
      top.children[#top.children + 1] = comp
      stack[#stack + 1] = comp
    elseif name == "END" then
      -- close the component of that name, and any left open inside it
      -- (a missing END:VALARM must not swallow the next event)
      local want = vim.trim(value):upper()
      for k = #stack, 2, -1 do
        if stack[k].name == want then
          for j = #stack, k, -1 do
            stack[j] = nil
          end
          break
        end
      end
    elseif name then
      local top = stack[#stack]
      top.props[#top.props + 1] = { name = name, params = params, value = value }
    end
  end
  return root
end

local function prop(comp, name)
  for _, p in ipairs(comp.props) do
    if p.name == name then
      return p
    end
  end
end

local function props(comp, name)
  local out = {}
  for _, p in ipairs(comp.props) do
    if p.name == name then
      out[#out + 1] = p
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Values
---------------------------------------------------------------------------

--- Naive seconds of a civil date and time.
function M.naive(y, m, d, h, mi, s)
  return dt.days_from_civil(y, m, d) * 86400 + (h or 0) * 3600 + (mi or 0) * 60 + (s or 0)
end

--- Civil fields of naive seconds.
function M.civil(naive)
  local days = floor(naive / 86400)
  local rest = naive - days * 86400
  local y, m, d = dt.civil_from_days(days)
  return {
    year = y,
    month = m,
    day = d,
    hour = floor(rest / 3600),
    min = floor(rest % 3600 / 60),
    sec = rest % 60,
  }
end

--- A DATE or DATE-TIME value: `{ naive, all_day, utc, tzid }`.
---@param value string
---@param params? table
---@return table|nil
function M.time(value, params)
  params = params or {}
  value = vim.trim(value)
  local y, m, d, rest = value:match("^(%d%d%d%d)(%d%d)(%d%d)(.*)$")
  if not y then
    return nil
  end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  local h, mi, s, z = rest:match("^T(%d%d)(%d%d)(%d%d)(Z?)$")
  if not h then
    if rest ~= "" then
      return nil
    end
    return { naive = M.naive(y, m, d), all_day = true }
  end
  return {
    naive = M.naive(y, m, d, tonumber(h), tonumber(mi), tonumber(s)),
    utc = z == "Z",
    tzid = z ~= "Z" and params.TZID or nil,
  }
end

--- A DURATION value in seconds (`P1W`, `PT1H30M`, `-P1DT2H`).
function M.duration(value)
  value = vim.trim(value or "")
  local sign, rest = value:match("^([+-]?)P(.*)$")
  if not rest then
    return nil
  end
  local total = 0
  local datepart, timepart = rest:match("^([^T]*)T?(.*)$")
  for n, u in datepart:gmatch("(%d+)([WD])") do
    total = total + tonumber(n) * (u == "W" and 604800 or 86400)
  end
  for n, u in timepart:gmatch("(%d+)([HMS])") do
    total = total + tonumber(n) * (u == "H" and 3600 or u == "M" and 60 or 1)
  end
  return sign == "-" and -total or total
end

--- A UTC offset (`+0100`, `-0530`) in seconds.
function M.offset(value)
  local sign, h, m, s = vim.trim(value or ""):match("^([+-])(%d%d)(%d%d)(%d*)$")
  if not sign then
    return nil
  end
  local v = tonumber(h) * 3600 + tonumber(m) * 60 + (tonumber(s) or 0)
  return sign == "-" and -v or v
end

local WEEKDAYS = { MO = 1, TU = 2, WE = 3, TH = 4, FR = 5, SA = 6, SU = 7 }
M.WEEKDAYS = WEEKDAYS

local function int_list(v)
  local out = {}
  for x in (v or ""):gmatch("[^,]+") do
    out[#out + 1] = tonumber(x)
  end
  return #out > 0 and out or nil
end

--- Parse an RRULE value.
---@return table|nil
function M.rrule(value)
  local r = {}
  for k, v in value:gmatch("([^;=]+)=([^;]*)") do
    r[k:upper()] = v
  end
  if not r.FREQ then
    return nil
  end
  local rule = {
    freq = r.FREQ:upper(),
    interval = math.max(tonumber(r.INTERVAL) or 1, 1),
    count = tonumber(r.COUNT),
    until_ = r.UNTIL and M.time(r.UNTIL) or nil,
    bymonth = int_list(r.BYMONTH),
    bymonthday = int_list(r.BYMONTHDAY),
    byyearday = int_list(r.BYYEARDAY),
    bysetpos = int_list(r.BYSETPOS),
    byhour = int_list(r.BYHOUR),
    byminute = int_list(r.BYMINUTE),
    bysecond = int_list(r.BYSECOND),
    wkst = WEEKDAYS[(r.WKST or "MO"):upper()] or 1,
    unsupported = {},
  }
  if r.BYDAY then
    rule.byday = {}
    for part in r.BYDAY:gmatch("[^,]+") do
      local n, wd = part:upper():match("^([+-]?%d*)(%u%u)$")
      if wd and WEEKDAYS[wd] then
        rule.byday[#rule.byday + 1] = { wd = WEEKDAYS[wd], n = tonumber(n) }
      end
    end
  end
  if r.BYWEEKNO then
    rule.unsupported[#rule.unsupported + 1] = "BYWEEKNO"
  end
  return rule
end

---------------------------------------------------------------------------
-- Recurrence
---------------------------------------------------------------------------

local function weekday(dn)
  return (dn + 3) % 7 + 1
end

local function contains(list, v)
  for _, x in ipairs(list) do
    if x == v then
      return true
    end
  end
  return false
end

-- Days (day numbers) of month y-m matched by BYMONTHDAY / BYDAY, or the
-- start's day of month.
local function month_days(rule, y, m, start_day, byday_in_month)
  local dim = dt.days_in_month(y, m)
  local first = dt.days_from_civil(y, m, 1)
  local a, b
  if rule.bymonthday then
    a = {}
    for _, v in ipairs(rule.bymonthday) do
      local d = v < 0 and dim + 1 + v or v
      if d >= 1 and d <= dim then
        a[first + d - 1] = true
      end
    end
  end
  if rule.byday and byday_in_month then
    b = {}
    for _, bd in ipairs(rule.byday) do
      local off = (bd.wd - weekday(first)) % 7
      local all = {}
      for d = first + off, first + dim - 1, 7 do
        all[#all + 1] = d
      end
      if not bd.n or bd.n == 0 then
        for _, d in ipairs(all) do
          b[d] = true
        end
      else
        local d = bd.n > 0 and all[bd.n] or all[#all + 1 + bd.n]
        if d then
          b[d] = true
        end
      end
    end
  end
  local out = {}
  if a and b then
    for d in pairs(a) do
      if b[d] then
        out[#out + 1] = d
      end
    end
  elseif a or b then
    for d in pairs(a or b) do
      out[#out + 1] = d
    end
  elseif start_day <= dim then
    out[1] = first + start_day - 1
  end
  return out
end

-- Candidate days of period k of a rule.
local function period_days(rule, k, d0)
  local y0, m0, day0 = dt.civil_from_days(d0)
  local f = rule.freq
  local cands = {}
  if f == "DAILY" then
    cands[1] = d0 + k * rule.interval
  elseif f == "WEEKLY" then
    local ws = d0 - (weekday(d0) - rule.wkst) % 7 + 7 * k * rule.interval
    if rule.byday then
      for _, bd in ipairs(rule.byday) do
        cands[#cands + 1] = ws + (bd.wd - rule.wkst) % 7
      end
    else
      cands[1] = ws + (weekday(d0) - rule.wkst) % 7
    end
  elseif f == "MONTHLY" then
    local mi = y0 * 12 + (m0 - 1) + k * rule.interval
    cands = month_days(rule, floor(mi / 12), mi % 12 + 1, day0, true)
  elseif f == "YEARLY" then
    local y = y0 + k * rule.interval
    if rule.byyearday then
      local len = dt.is_leap(y) and 366 or 365
      local jan1 = dt.days_from_civil(y, 1, 1)
      for _, v in ipairs(rule.byyearday) do
        local n = v < 0 and len + 1 + v or v
        if n >= 1 and n <= len then
          cands[#cands + 1] = jan1 + n - 1
        end
      end
    elseif rule.bymonth or rule.bymonthday or not rule.byday then
      for _, m in ipairs(rule.bymonth or { m0 }) do
        vim.list_extend(cands, month_days(rule, y, m, day0, true))
      end
    else
      -- BYDAY alone: weekdays of the whole year (20MO = the 20th Monday)
      local jan1 = dt.days_from_civil(y, 1, 1)
      local len = dt.is_leap(y) and 366 or 365
      for _, bd in ipairs(rule.byday) do
        local all = {}
        for d = jan1 + (bd.wd - weekday(jan1)) % 7, jan1 + len - 1, 7 do
          all[#all + 1] = d
        end
        if not bd.n or bd.n == 0 then
          vim.list_extend(cands, all)
        else
          cands[#cands + 1] = bd.n > 0 and all[bd.n] or all[#all + 1 + bd.n]
        end
      end
    end
  else
    return nil
  end
  -- limiting BYxxx parts
  local out = {}
  for _, d in ipairs(cands) do
    local _, m, md = dt.civil_from_days(d)
    local keep = true
    if rule.bymonth and f ~= "YEARLY" and not contains(rule.bymonth, m) then
      keep = false
    end
    if keep and rule.byday and f == "DAILY" then
      keep = false
      for _, bd in ipairs(rule.byday) do
        if bd.wd == weekday(d) then
          keep = true
        end
      end
    end
    if keep and rule.bymonthday and (f == "DAILY" or f == "WEEKLY") then
      local dim = dt.days_in_month(dt.civil_from_days(d), m)
      keep = false
      for _, v in ipairs(rule.bymonthday) do
        if (v < 0 and dim + 1 + v or v) == md then
          keep = true
        end
      end
    end
    if keep then
      out[#out + 1] = d
    end
  end
  table.sort(out)
  -- remove duplicates
  local uniq = {}
  for _, d in ipairs(out) do
    if uniq[#uniq] ~= d then
      uniq[#uniq + 1] = d
    end
  end
  if rule.bysetpos then
    local sel = {}
    for _, p in ipairs(rule.bysetpos) do
      local d = p > 0 and uniq[p] or uniq[#uniq + 1 + p]
      if d then
        sel[#sel + 1] = d
      end
    end
    table.sort(sel)
    uniq = sel
  end
  return uniq
end

local PERIOD_DAYS = { DAILY = 1, WEEKLY = 7, MONTHLY = 28, YEARLY = 365 }

-- Whether day `d` passes the BYMONTH, BYMONTHDAY and BYDAY filters.
local function day_ok(rule, d)
  local y, m, md = dt.civil_from_days(d)
  if rule.bymonth and not contains(rule.bymonth, m) then
    return false
  end
  if rule.bymonthday then
    local dim = dt.days_in_month(y, m)
    local hit = false
    for _, v in ipairs(rule.bymonthday) do
      hit = hit or (v < 0 and dim + 1 + v or v) == md
    end
    if not hit then
      return false
    end
  end
  if rule.byday then
    local hit = false
    for _, bd in ipairs(rule.byday) do
      hit = hit or bd.wd == weekday(d)
    end
    if not hit then
      return false
    end
  end
  return true
end

-- HOURLY, MINUTELY and SECONDLY rules: every INTERVAL hours (minutes,
-- seconds) from the start, BYMINUTE / BYSECOND expanding an hour (a
-- minute), the other BYxxx parts filtering.
local function sub_daily(rule, start, from, limit, past_until)
  local unit = rule.freq == "HOURLY" and 3600 or rule.freq == "MINUTELY" and 60 or 1
  local step = unit * rule.interval
  local s0 = start % 60
  local m0 = floor(start % 3600 / 60)
  local offs = { 0 }
  if unit == 3600 and (rule.byminute or rule.bysecond) then
    offs = {}
    for _, mi in ipairs(rule.byminute or { m0 }) do
      for _, s in ipairs(rule.bysecond or { s0 }) do
        offs[#offs + 1] = (mi - m0) * 60 + (s - s0)
      end
    end
  elseif unit == 60 and rule.bysecond then
    offs = {}
    for _, s in ipairs(rule.bysecond) do
      offs[#offs + 1] = s - s0
    end
  end
  table.sort(offs)
  local out, count, k = {}, 0, 0
  if not rule.count and from > start then
    k = math.max(floor((from - start) / step) - 1, 0)
  end
  if k == 0 then
    count = 1
    if start >= from and start <= limit then
      out[1] = start
    end
  end
  local guard = 0
  while guard < 100000 do
    guard = guard + 1
    local base = start + k * step
    if base + (offs[1] or 0) > limit then
      break
    end
    local done = false
    for _, off in ipairs(offs) do
      local t = base + off
      local d = floor(t / 86400)
      local tod = t - d * 86400
      local ok = t > start
        and day_ok(rule, d)
        and not (rule.byhour and not contains(rule.byhour, floor(tod / 3600)))
        and not (unit < 3600 and rule.byminute and not contains(rule.byminute, floor(tod % 3600 / 60)))
      if ok then
        if t > limit or (past_until and past_until(t)) or (rule.count and count >= rule.count) then
          done = true
          break
        end
        count = count + 1
        if t >= from then
          out[#out + 1] = t
        end
      end
    end
    if done then
      break
    end
    k = k + 1
  end
  return out
end

--- Occurrences (naive seconds) of a recurrence starting at `start` (naive)
--- up to `limit` (naive, inclusive), from `from` on. `past_until(naive)`
--- tells whether an occurrence is after the rule's UNTIL. DTSTART is
--- always the first occurrence.
---@param rule table from `M.rrule`
---@param start integer
---@param from integer
---@param limit integer
---@param past_until? fun(naive: integer): boolean
---@return integer[]
function M.expand(rule, start, from, limit, past_until)
  local out = {}
  local d0 = floor(start / 86400)
  local tod = start - d0 * 86400
  if rule.freq == "HOURLY" or rule.freq == "MINUTELY" or rule.freq == "SECONDLY" then
    return sub_daily(rule, start, from, limit, past_until)
  end
  local per = PERIOD_DAYS[rule.freq]
  if not per then
    return { start }
  end
  -- times of day: BYHOUR x BYMINUTE x BYSECOND, else the start's
  local tods = { tod }
  if rule.byhour or rule.byminute or rule.bysecond then
    local h0, m0, s0 = floor(tod / 3600), floor(tod % 3600 / 60), tod % 60
    tods = {}
    for _, h in ipairs(rule.byhour or { h0 }) do
      for _, mi in ipairs(rule.byminute or { m0 }) do
        for _, s in ipairs(rule.bysecond or { s0 }) do
          if h >= 0 and h < 24 and mi >= 0 and mi < 60 and s >= 0 and s < 60 then
            tods[#tods + 1] = h * 3600 + mi * 60 + s
          end
        end
      end
    end
    table.sort(tods)
  end
  local count = 0
  local k = 0
  -- without COUNT, skip the periods before `from`
  if not rule.count and from > start then
    local periods = floor((from - start) / 86400 / (per * rule.interval))
    if rule.freq == "MONTHLY" then
      periods = floor(periods * 28 / 31)
    end
    k = math.max(periods - 2, 0)
  end
  if k == 0 then
    count = 1
    if start >= from and start <= limit then
      out[1] = start
    end
  end
  local guard = 0
  while guard < 100000 do
    guard = guard + 1
    local days = period_days(rule, k, d0)
    if not days then
      break
    end
    local done = false
    for _, d in ipairs(days) do
      for _, td in ipairs(tods) do
        local t = d * 86400 + td
        if t > start then
          if t > limit or (past_until and past_until(t)) then
            done = true
            break
          end
          if rule.count and count >= rule.count then
            done = true
            break
          end
          count = count + 1
          if t >= from then
            out[#out + 1] = t
          end
        end
      end
      if done then
        break
      end
    end
    if done then
      break
    end
    -- stop once a whole period starts after the limit
    local pstart
    local y0, m0 = dt.civil_from_days(d0)
    if rule.freq == "YEARLY" then
      pstart = dt.days_from_civil(y0 + k * rule.interval, 1, 1)
    elseif rule.freq == "MONTHLY" then
      local mi = y0 * 12 + (m0 - 1) + k * rule.interval
      pstart = dt.days_from_civil(floor(mi / 12), mi % 12 + 1, 1)
    else
      pstart = d0 + k * rule.interval * per - 7
    end
    if pstart * 86400 > limit then
      break
    end
    k = k + 1
  end
  return out
end

---------------------------------------------------------------------------
-- Time zones
---------------------------------------------------------------------------

--- Windows time zone names (Outlook / Exchange) -> IANA names.
M.WINDOWS_ZONES = {
  ["Dateline Standard Time"] = "Etc/GMT+12",
  ["Hawaiian Standard Time"] = "Pacific/Honolulu",
  ["Alaskan Standard Time"] = "America/Anchorage",
  ["Pacific Standard Time"] = "America/Los_Angeles",
  ["US Mountain Standard Time"] = "America/Phoenix",
  ["Mountain Standard Time"] = "America/Denver",
  ["Central Standard Time"] = "America/Chicago",
  ["Central Standard Time (Mexico)"] = "America/Mexico_City",
  ["Canada Central Standard Time"] = "America/Regina",
  ["Central America Standard Time"] = "America/Guatemala",
  ["Eastern Standard Time"] = "America/New_York",
  ["SA Pacific Standard Time"] = "America/Bogota",
  ["Atlantic Standard Time"] = "America/Halifax",
  ["Newfoundland Standard Time"] = "America/St_Johns",
  ["E. South America Standard Time"] = "America/Sao_Paulo",
  ["Argentina Standard Time"] = "America/Argentina/Buenos_Aires",
  ["Pacific SA Standard Time"] = "America/Santiago",
  ["UTC"] = "UTC",
  ["GMT Standard Time"] = "Europe/London",
  ["Greenwich Standard Time"] = "Atlantic/Reykjavik",
  ["W. Europe Standard Time"] = "Europe/Berlin",
  ["Central Europe Standard Time"] = "Europe/Budapest",
  ["Central European Standard Time"] = "Europe/Warsaw",
  ["Romance Standard Time"] = "Europe/Paris",
  ["GTB Standard Time"] = "Europe/Bucharest",
  ["E. Europe Standard Time"] = "Europe/Chisinau",
  ["FLE Standard Time"] = "Europe/Kiev",
  ["Israel Standard Time"] = "Asia/Jerusalem",
  ["South Africa Standard Time"] = "Africa/Johannesburg",
  ["Turkey Standard Time"] = "Europe/Istanbul",
  ["Russian Standard Time"] = "Europe/Moscow",
  ["Arabian Standard Time"] = "Asia/Dubai",
  ["India Standard Time"] = "Asia/Kolkata",
  ["SE Asia Standard Time"] = "Asia/Bangkok",
  ["China Standard Time"] = "Asia/Shanghai",
  ["Singapore Standard Time"] = "Asia/Singapore",
  ["Tokyo Standard Time"] = "Asia/Tokyo",
  ["Korea Standard Time"] = "Asia/Seoul",
  ["AUS Eastern Standard Time"] = "Australia/Sydney",
  ["E. Australia Standard Time"] = "Australia/Brisbane",
  ["W. Australia Standard Time"] = "Australia/Perth",
  ["New Zealand Standard Time"] = "Pacific/Auckland",
}

local tzif = require("org.extensions.ics.tzif")

local zone_exists_cache = {}

--- Whether `name` is a zone of the system time zone database.
function M.system_zone(name)
  if not name or name == "" or name:find("%.%.") or name:sub(1, 1) == "/" then
    return false
  end
  if zone_exists_cache[name] ~= nil then
    return zone_exists_cache[name]
  end
  local found = tzif.load(name) ~= nil
  if not found then
    for _, dir in ipairs(tzif.dirs()) do
      if vim.fn.filereadable(dir .. "/" .. name) == 1 then
        found = true
        break
      end
    end
  end
  zone_exists_cache[name] = found
  return found
end

--- Run `fn` with the TZ environment variable set to `tz` (nil: unchanged).
local function with_tz(tz, fn, ...)
  if not tz then
    return fn(...)
  end
  local saved = vim.env.TZ
  dt.set_tz(tz)
  local ok, a = pcall(fn, ...)
  dt.set_tz(saved)
  if not ok then
    error(a, 0)
  end
  return a
end
M.with_tz = with_tz

--- UTC epoch of wall time `naive` in system zone `tz`: read from its
--- zoneinfo file, else with `TZ` set around `os.time`.
function M.system_epoch(tz, naive)
  local z = tzif.load(tz)
  if z then
    return tzif.epoch(z, naive)
  end
  local c = M.civil(naive)
  return with_tz(tz, os.time, { year = c.year, month = c.month, day = c.day, hour = c.hour, min = c.min, sec = c.sec })
end

--- Wall time (naive seconds) of epoch `e` in zone `tz` (nil: the
--- system's local zone).
function M.wall(e, tz)
  local z = tz and tzif.load(tz)
  if z then
    return tzif.wall(z, e)
  end
  local c = with_tz(tz, os.date, "*t", e)
  return M.naive(c.year, c.month, c.day, c.hour, c.min, c.sec)
end

-- VTIMEZONE: observances { onset, from, to, rule, rdates }
local function parse_vtimezone(comp)
  local obs = {}
  for _, child in ipairs(comp.children) do
    if child.name == "STANDARD" or child.name == "DAYLIGHT" then
      local s = prop(child, "DTSTART")
      local o = {
        onset = s and M.time(s.value) and M.time(s.value).naive or 0,
        from = M.offset((prop(child, "TZOFFSETFROM") or {}).value) or 0,
        to = M.offset((prop(child, "TZOFFSETTO") or {}).value) or 0,
        rdates = {},
      }
      local r = prop(child, "RRULE")
      if r then
        o.rule = M.rrule(r.value)
      end
      for _, p in ipairs(props(child, "RDATE")) do
        for v in p.value:gmatch("[^,]+") do
          local t = M.time(v)
          if t then
            o.rdates[#o.rdates + 1] = t.naive
          end
        end
      end
      obs[#obs + 1] = o
    end
  end
  return obs
end

--- UTC offset (seconds) of wall time `naive` under VTIMEZONE observances.
function M.vtimezone_offset(obs, naive, cache)
  local c = M.civil(naive)
  local key = c.year
  local trans = cache and cache[key]
  if not trans then
    trans = {}
    local from = M.naive(c.year - 1, 1, 1)
    local limit = M.naive(c.year + 1, 1, 1)
    for _, o in ipairs(obs) do
      local onsets
      if o.rule then
        local rule = o.rule
        local until_ = rule.until_
        onsets = M.expand(rule, o.onset, from, limit, until_ and function(t)
          return t > until_.naive + (until_.utc and o.from or 0)
        end or nil)
      else
        onsets = o.onset <= limit and { o.onset } or {}
      end
      for _, t in ipairs(o.rdates) do
        onsets[#onsets + 1] = t
      end
      for _, t in ipairs(onsets) do
        trans[#trans + 1] = { t, o.to }
      end
    end
    table.sort(trans, function(a, b)
      return a[1] < b[1]
    end)
    if cache then
      cache[key] = trans
    end
  end
  local best
  for _, t in ipairs(trans) do
    if t[1] <= naive then
      best = t[2]
    end
  end
  if best then
    return best
  end
  -- before every onset in range: the earliest observance still applies
  local earliest
  for _, o in ipairs(obs) do
    if not earliest or o.onset < earliest.onset then
      earliest = o
    end
  end
  if earliest and earliest.onset <= naive then
    return earliest.to
  end
  return earliest and earliest.from or 0
end

---------------------------------------------------------------------------
-- Calendars
---------------------------------------------------------------------------

---@class org.ics.Event
---@field uid string
---@field summary string
---@field description string|nil
---@field location string|nil
---@field url string|nil
---@field status string|nil
---@field categories string[]
---@field start table `{ naive, all_day, utc, tzid }`
---@field stop table|nil end (exclusive)
---@field duration integer|nil seconds
---@field rrule table|nil
---@field rdates table[]
---@field exdates table[]
---@field recurrence_id table|nil
---@field line integer|nil

local function event_of(comp)
  local function text(name)
    local p = prop(comp, name)
    return p and M.text(p.value) or nil
  end
  local s = prop(comp, "DTSTART")
  local start = s and M.time(s.value, s.params)
  if not start then
    return nil
  end
  if s.params.VALUE == "DATE" then
    start.all_day = true
  end
  local ev = {
    uid = text("UID") or "",
    summary = text("SUMMARY") or "",
    description = text("DESCRIPTION"),
    location = text("LOCATION"),
    url = text("URL"),
    status = (text("STATUS") or ""):upper(),
    start = start,
    categories = {},
    rdates = {},
    exdates = {},
  }
  local e = prop(comp, "DTEND")
  if e then
    ev.stop = M.time(e.value, e.params)
  end
  local du = prop(comp, "DURATION")
  if du then
    ev.duration = M.duration(du.value)
  end
  local r = prop(comp, "RRULE")
  if r then
    ev.rrule = M.rrule(r.value)
  end
  for _, name in ipairs({ "RDATE", "EXDATE" }) do
    for _, p in ipairs(props(comp, name)) do
      for v in p.value:gmatch("[^,]+") do
        local t = M.time(v, p.params)
        if t then
          if p.params.VALUE == "DATE" then
            t.all_day = true
          end
          table.insert(name == "RDATE" and ev.rdates or ev.exdates, t)
        end
      end
    end
  end
  local rid = prop(comp, "RECURRENCE-ID")
  if rid then
    ev.recurrence_id = M.time(rid.value, rid.params)
  end
  for _, p in ipairs(props(comp, "CATEGORIES")) do
    for v in p.value:gmatch("[^,]+") do
      ev.categories[#ev.categories + 1] = M.text(v)
    end
  end
  return ev
end

---@class org.ics.Calendar
---@field name string|nil X-WR-CALNAME
---@field timezone string|nil X-WR-TIMEZONE
---@field events org.ics.Event[]
---@field zones table<string, table> VTIMEZONE observances by TZID
---@field unresolved table<string, boolean> TZIDs read as local time

--- Parse iCalendar text.
---@param text string
---@return org.ics.Calendar
function M.parse(text)
  local root = M.tree(text)
  local cal = { events = {}, zones = {}, unresolved = {}, zone_cache = {} }
  local function walk(comp)
    for _, child in ipairs(comp.children) do
      if child.name == "VCALENDAR" then
        local n = prop(child, "X-WR-CALNAME")
        cal.name = cal.name or (n and M.text(n.value))
        local tz = prop(child, "X-WR-TIMEZONE")
        cal.timezone = cal.timezone or (tz and vim.trim(tz.value))
        walk(child)
      elseif child.name == "VTIMEZONE" then
        local id = prop(child, "TZID")
        if id then
          cal.zones[vim.trim(id.value)] = parse_vtimezone(child)
        end
      elseif child.name == "VEVENT" then
        local ev = event_of(child)
        if ev then
          cal.events[#cal.events + 1] = ev
        end
      end
    end
  end
  walk(root)
  return cal
end

--- A resolver of TZID `tzid`: `fun(naive): epoch`, or nil when unknown.
---@param cal org.ics.Calendar
---@param tzid string
---@param aliases? table<string, string> extra TZID -> IANA names
function M.zone(cal, tzid, aliases)
  cal.resolvers = cal.resolvers or {}
  if cal.resolvers[tzid] ~= nil then
    return cal.resolvers[tzid] or nil
  end
  local res
  local alias = aliases and aliases[tzid]
  local name = alias or tzid
  -- "/mozilla.org/20050126_1/Europe/Berlin" and the like
  local trimmed = name
  while trimmed and not M.system_zone(trimmed) and trimmed:find("/") do
    trimmed = trimmed:match("^/?[^/]*/(.*)$")
  end
  if trimmed and M.system_zone(trimmed) then
    res = function(naive)
      return M.system_epoch(trimmed, naive)
    end
  elseif cal.zones[tzid] and #cal.zones[tzid] > 0 then
    local obs = cal.zones[tzid]
    cal.zone_cache[tzid] = {}
    res = function(naive)
      return naive - M.vtimezone_offset(obs, naive, cal.zone_cache[tzid])
    end
  elseif M.WINDOWS_ZONES[tzid] and M.system_zone(M.WINDOWS_ZONES[tzid]) then
    local iana = M.WINDOWS_ZONES[tzid]
    res = function(naive)
      return M.system_epoch(iana, naive)
    end
  elseif tzid == "UTC" or tzid == "GMT" or tzid == "Etc/UTC" or tzid == "Z" then
    res = function(naive)
      return naive
    end
  end
  cal.resolvers[tzid] = res or false
  if not res then
    cal.unresolved[tzid] = true
  end
  return res
end

--- UTC epoch of a time value, or nil for floating times and dates.
function M.epoch(cal, t, aliases)
  if t.all_day then
    return nil
  end
  if t.utc then
    return t.naive
  end
  if t.tzid then
    local z = M.zone(cal, t.tzid, aliases)
    if z then
      return z(t.naive)
    end
  end
  return nil
end

--- Wall time (naive seconds) in the display zone of a time value: UTC and
--- zoned times are converted to `tz` (nil: the system's local zone),
--- floating times and dates are kept.
function M.localize(cal, t, tz, aliases)
  local e = M.epoch(cal, t, aliases)
  if not e then
    return t.naive
  end
  return M.wall(e, tz)
end

-- Key identifying an occurrence for EXDATE / RECURRENCE-ID matching.
local function occ_key(cal, t, aliases)
  if t.all_day then
    return "d" .. floor(t.naive / 86400)
  end
  local e = M.epoch(cal, t, aliases)
  return e and ("e" .. e) or ("n" .. t.naive)
end

--- Occurrences between days `from` and `to` (local day numbers):
--- `{ event, start, stop, all_day }` with `start`/`stop` as local naive
--- seconds (stop exclusive).
---@param cal org.ics.Calendar
---@param from integer
---@param to integer
---@param opts? { timezone?: string, aliases?: table }
function M.occurrences(cal, from, to, opts)
  opts = opts or {}
  local tz, aliases = opts.timezone, opts.aliases
  -- a day of slack either side for zone offsets
  local from_n = (from - 2) * 86400
  local to_n = (to + 2) * 86400 + 86399
  local overridden = {}
  for _, ev in ipairs(cal.events) do
    if ev.recurrence_id then
      overridden[ev.uid .. "|" .. occ_key(cal, ev.recurrence_id, aliases)] = true
    end
  end
  local out = {}
  local function emit(ev, start_t)
    local len
    if ev.stop then
      len = ev.stop.naive - ev.start.naive
      if not ev.start.all_day and (ev.stop.tzid ~= ev.start.tzid or ev.stop.utc ~= ev.start.utc) then
        local a, b = M.epoch(cal, ev.start, aliases), M.epoch(cal, ev.stop, aliases)
        if a and b then
          len = b - a
        end
      end
    elseif ev.duration then
      len = ev.duration
    else
      len = start_t.all_day and 86400 or 0
    end
    local s = M.localize(cal, start_t, tz, aliases)
    local e
    if start_t.all_day then
      e = s + math.max(len, 86400)
    else
      local ep = M.epoch(cal, start_t, aliases)
      if ep then
        e = M.wall(ep + len, tz)
      else
        e = s + len
      end
    end
    local sd = floor(s / 86400)
    if sd <= to and floor(math.max(e - 1, s) / 86400) >= from then
      out[#out + 1] = { event = ev, start = s, stop = e, all_day = start_t.all_day or false }
    end
  end
  for _, ev in ipairs(cal.events) do
    if ev.status ~= "CANCELLED" or ev.recurrence_id then
      local starts = {}
      if ev.recurrence_id or not (ev.rrule or #ev.rdates > 0) then
        -- a single event far outside the range (the slack covers zone
        -- offsets) is skipped before its zone is looked up
        local s = ev.start.naive
        local e = s + 86400
        if ev.stop then
          e = math.max(e, ev.stop.naive)
        elseif ev.duration then
          e = math.max(e, s + ev.duration)
        end
        if s <= to_n and e >= from_n then
          starts[1] = s
        end
      else
        -- span of one occurrence, so one that started before `from` and
        -- still runs is found
        local span = 0
        if ev.stop then
          span = math.max(ev.stop.naive - ev.start.naive, 0)
        elseif ev.duration then
          span = math.max(ev.duration, 0)
        end
        if ev.rrule then
          local until_ = ev.rrule.until_
          local past
          if until_ then
            if until_.utc and not ev.start.all_day then
              past = function(t)
                local e = M.epoch(cal, { naive = t, tzid = ev.start.tzid, utc = ev.start.utc }, aliases)
                return (e or t) > until_.naive
              end
            else
              local lim = until_.all_day and (until_.naive + 86399) or until_.naive
              past = function(t)
                return t > lim
              end
            end
          end
          starts = M.expand(ev.rrule, ev.start.naive, from_n - span, to_n, past)
        elseif ev.start.naive >= from_n - span and ev.start.naive <= to_n then
          starts = { ev.start.naive }
        end
        for _, r in ipairs(ev.rdates) do
          if r.naive >= from_n - span and r.naive <= to_n then
            -- an RDATE keeps its own zone (UTC, another TZID)
            starts[#starts + 1] = r.all_day == ev.start.all_day and r or r.naive
          end
        end
      end
      -- an RDATE that repeats an occurrence of the rule is one instance
      local seen = {}
      for _, n in ipairs(starts) do
        local t
        if type(n) == "table" then
          t, n = n, n.naive
        else
          t = { naive = n, all_day = ev.start.all_day, utc = ev.start.utc, tzid = ev.start.tzid }
        end
        local key = occ_key(cal, t, aliases)
        local skip = ev.status == "CANCELLED" or seen[key]
        seen[key] = true
        if not ev.recurrence_id then
          skip = skip or overridden[ev.uid .. "|" .. key]
          for _, x in ipairs(ev.exdates) do
            if occ_key(cal, x, aliases) == key or (x.all_day and floor(x.naive / 86400) == floor(n / 86400)) then
              skip = true
            end
          end
        end
        if not skip then
          emit(ev, t)
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.start ~= b.start then
      return a.start < b.start
    end
    return a.event.summary < b.event.summary
  end)
  return out
end

return M
