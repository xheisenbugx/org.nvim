---@mod org.extensions.ics.tzif Time zones from the system zoneinfo (TZif)
---
--- A small reader of the TZif files in `/usr/share/zoneinfo` (RFC 8536,
--- versions 1 to 4): the transitions, and for times after the last one the
--- POSIX TZ rule of the footer ("CET-1CEST,M3.5.0,M10.5.0/3"). Zones are
--- read once and cached. Pure Lua, so converting thousands of event times
--- needs no `TZ` juggling around `os.time`.

local M = {}

local floor = math.floor

local DIRS = { "/usr/share/zoneinfo", "/usr/lib/zoneinfo", "/usr/share/lib/zoneinfo", "/etc/zoneinfo" }

---------------------------------------------------------------------------
-- Calendar helpers (proleptic Gregorian, day 0 = 1970-01-01)
---------------------------------------------------------------------------

local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function civil_year(days)
  local z = days + 719468
  local era = floor(z / 146097)
  local doe = z - era * 146097
  local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524) - floor(doe / 146096)) / 365)
  local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
  local mp = floor((5 * doy + 2) / 153)
  local m = mp < 10 and mp + 3 or mp - 9
  return yoe + era * 400 + (m <= 2 and 1 or 0)
end

local function is_leap(y)
  return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

local DIM = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function days_in_month(y, m)
  return m == 2 and is_leap(y) and 29 or DIM[m]
end

---------------------------------------------------------------------------
-- POSIX TZ strings
---------------------------------------------------------------------------

-- `[+-]hh[:mm[:ss]]` at `pos`: seconds and the next position
local function hms(s, pos)
  local sign, h, rest = s:match("^([+-]?)(%d+)()", pos)
  if not h then
    return nil, pos
  end
  local v = tonumber(h) * 3600
  pos = rest
  local mm, p2 = s:match("^:(%d+)()", pos)
  if mm then
    v, pos = v + tonumber(mm) * 60, p2
    local ss, p3 = s:match("^:(%d+)()", pos)
    if ss then
      v, pos = v + tonumber(ss), p3
    end
  end
  return sign == "-" and -v or v, pos
end

-- a zone abbreviation (`CET` or `<+0330>`) at `pos`
local function abbr(s, pos)
  local q, p = s:match("^<([^>]*)>()", pos)
  if q then
    return q, p
  end
  local a, p2 = s:match("^(%a%a%a+)()", pos)
  return a, p2 or pos
end

-- a transition rule date (`Mm.w.d`, `Jn` or `n`) and its `/time`
local function rule_date(s, pos)
  local r = {}
  local m, w, d, p = s:match("^M(%d+)%.(%d)%.(%d)()", pos)
  if m then
    r.kind, r.m, r.w, r.d, pos = "M", tonumber(m), tonumber(w), tonumber(d), p
  else
    local j, pj = s:match("^J(%d+)()", pos)
    if j then
      r.kind, r.n, pos = "J", tonumber(j), pj
    else
      local n, pn = s:match("^(%d+)()", pos)
      if not n then
        return nil, pos
      end
      r.kind, r.n, pos = "n", tonumber(n), pn
    end
  end
  r.time = 7200
  if s:sub(pos, pos) == "/" then
    local t, p2 = hms(s, pos + 1)
    if t then
      r.time, pos = t, p2
    end
  end
  return r, pos
end

--- Parse a POSIX TZ string: `{ std, dst?, start?, stop? }` with UTC
--- offsets in seconds east of Greenwich, or nil.
---@param s string
function M.parse_posix(s)
  if not s or s == "" then
    return nil
  end
  local pos = 1
  local std
  std, pos = abbr(s, pos)
  if not std then
    return nil
  end
  local off
  off, pos = hms(s, pos)
  if not off then
    return nil
  end
  local z = { std = -off }
  if pos > #s then
    return z
  end
  local dst
  dst, pos = abbr(s, pos)
  if not dst then
    return z
  end
  local doff
  doff, pos = hms(s, pos)
  z.dst = doff and -doff or z.std + 3600
  if s:sub(pos, pos) == "," then
    z.start, pos = rule_date(s, pos + 1)
    if s:sub(pos, pos) == "," then
      z.stop = rule_date(s, pos + 1)
    end
  end
  if not (z.start and z.stop) then
    -- no rule: the US rules of POSIX's default
    z.start = { kind = "M", m = 3, w = 2, d = 0, time = 7200 }
    z.stop = { kind = "M", m = 11, w = 1, d = 0, time = 7200 }
  end
  return z
end

-- Day number of a rule date in year y.
local function rule_day(r, y)
  if r.kind == "M" then
    local first = days_from_civil(y, r.m, 1)
    local wd1 = (first + 4) % 7 -- 0 = Sunday
    local day = 1 + (r.d - wd1) % 7 + 7 * (r.w - 1)
    local dim = days_in_month(y, r.m)
    while day > dim do
      day = day - 7
    end
    return first + day - 1
  elseif r.kind == "J" then
    local n = r.n
    if is_leap(y) and n >= 60 then
      n = n + 1
    end
    return days_from_civil(y, 1, 1) + n - 1
  end
  return days_from_civil(y, 1, 1) + r.n
end

--- UTC offset of epoch `t` under a parsed POSIX rule.
function M.posix_offset(z, t)
  if not z.dst then
    return z.std
  end
  local y = civil_year(floor((t + z.std) / 86400))
  -- the start is given in standard time, the end in daylight time
  local s = rule_day(z.start, y) * 86400 + z.start.time - z.std
  local e = rule_day(z.stop, y) * 86400 + z.stop.time - z.dst
  local in_dst
  if s < e then
    in_dst = t >= s and t < e
  else
    in_dst = t < e or t >= s
  end
  return in_dst and z.dst or z.std
end

---------------------------------------------------------------------------
-- TZif files
---------------------------------------------------------------------------

local function u32(data, i)
  local a, b, c, d = data:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function s32(data, i)
  local v = u32(data, i)
  return v >= 2147483648 and v - 4294967296 or v
end

local function s64(data, i)
  local hi, lo = u32(data, i), u32(data, i + 4)
  if hi >= 2147483648 then
    hi = hi - 4294967296
  end
  return hi * 4294967296 + lo
end

--- Parse the bytes of a TZif file: `{ times, types, utoff, footer }`, or
--- nil and an error.
---@param data string
function M.parse(data)
  if type(data) ~= "string" or data:sub(1, 4) ~= "TZif" or #data < 44 then
    return nil, "not a TZif file"
  end
  local function header(at)
    if data:sub(at, at + 3) ~= "TZif" then
      return nil
    end
    return {
      version = data:sub(at + 4, at + 4),
      isutcnt = u32(data, at + 20),
      isstdcnt = u32(data, at + 24),
      leapcnt = u32(data, at + 28),
      timecnt = u32(data, at + 32),
      typecnt = u32(data, at + 36),
      charcnt = u32(data, at + 40),
    }
  end
  local h = header(1)
  if not h or h.typecnt == 0 then
    return nil, "bad TZif header"
  end
  local tsize, at = 4, 45
  local v1len = h.timecnt * 5 + h.typecnt * 6 + h.charcnt + h.leapcnt * 8 + h.isstdcnt + h.isutcnt
  if h.version ~= "\0" then
    -- version 2+: skip the 32-bit block, read the 64-bit one
    local h2 = header(at + v1len)
    if h2 then
      h, tsize, at = h2, 8, at + v1len + 44
    end
  end
  local need = h.timecnt * (tsize + 1) + h.typecnt * 6 + h.charcnt + h.leapcnt * (tsize + 4) + h.isstdcnt + h.isutcnt
  if #data < at - 1 + need then
    return nil, "truncated TZif file"
  end
  local z = { times = {}, types = {}, utoff = {} }
  for i = 0, h.timecnt - 1 do
    z.times[i + 1] = tsize == 8 and s64(data, at + i * 8) or s32(data, at + i * 4)
  end
  at = at + h.timecnt * tsize
  for i = 0, h.timecnt - 1 do
    z.types[i + 1] = data:byte(at + i) + 1
  end
  at = at + h.timecnt
  for i = 0, h.typecnt - 1 do
    z.utoff[i + 1] = s32(data, at + i * 6)
  end
  at = at + h.typecnt * 6 + h.charcnt + h.leapcnt * (tsize + 4) + h.isstdcnt + h.isutcnt
  if tsize == 8 then
    local footer = data:match("^\n([^\n]*)\n", at)
    z.footer = footer and M.parse_posix(footer) or nil
  end
  return z
end

--- UTC offset (seconds east) of epoch `t` in parsed zone `z`.
function M.offset(z, t)
  local times = z.times
  local n = #times
  if n == 0 or t < times[1] then
    if n == 0 and z.footer then
      return M.posix_offset(z.footer, t)
    end
    return z.utoff[1]
  end
  if t >= times[n] then
    if z.footer then
      return M.posix_offset(z.footer, t)
    end
    return z.utoff[z.types[n]]
  end
  -- last transition at or before t
  local lo, hi = 1, n
  while lo < hi do
    local mid = floor((lo + hi + 1) / 2)
    if times[mid] <= t then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return z.utoff[z.types[lo]]
end

--- UTC epoch of wall time `naive` (seconds since 1970-01-01 of the local
--- clock) in zone `z`. A time skipped by a transition is read with the
--- offset before it, a repeated one as its first occurrence (RFC 5545).
function M.epoch(z, naive)
  local seen, valid = {}, {}
  for _, probe in ipairs({ naive - 86400, naive, naive + 86400 }) do
    local o = M.offset(z, probe)
    if not seen[o] then
      seen[o] = true
      local e = naive - o
      if M.offset(z, e) == o then
        valid[#valid + 1] = e
      end
    end
  end
  if #valid > 0 then
    table.sort(valid)
    return valid[1]
  end
  -- in a gap: the offset in effect before it
  return naive - M.offset(z, naive - 86400)
end

--- Wall time (naive seconds) of epoch `t` in zone `z`.
function M.wall(z, t)
  return t + M.offset(z, t)
end

---------------------------------------------------------------------------
-- Zones by name
---------------------------------------------------------------------------

local cache = {}

--- Directories searched for zone files (`$TZDIR` first).
function M.dirs()
  local out = {}
  if vim.env.TZDIR and vim.env.TZDIR ~= "" then
    out[1] = vim.env.TZDIR
  end
  vim.list_extend(out, DIRS)
  return out
end

--- The parsed zone `name` ("Europe/Berlin"), cached: its zoneinfo file,
--- else (no zoneinfo, as on Windows) its current rule from the bundled
--- tz_rules; nil for an unknown zone.
---@param name string
function M.load(name)
  if type(name) ~= "string" or name == "" or name:find("%.%.") or name:sub(1, 1) == "/" then
    return nil
  end
  local c = cache[name]
  if c ~= nil then
    return c or nil
  end
  local z = false
  for _, dir in ipairs(M.dirs()) do
    local fh = io.open(dir .. "/" .. name, "rb")
    if fh then
      local data = fh:read("*a")
      fh:close()
      local parsed = M.parse(data)
      if parsed then
        z = parsed
        break
      end
    end
  end
  if not z then
    -- no zoneinfo (Windows): the zone's current rule, bundled
    local rule = require("org.extensions.ics.tz_rules")[name]
    local footer = rule and M.parse_posix(rule)
    if footer then
      z = { times = {}, types = {}, utoff = {}, footer = footer, bundled = true }
    end
  end
  cache[name] = z
  return z or nil
end

--- Forget the loaded zones.
function M.clear()
  cache = {}
end

return M
