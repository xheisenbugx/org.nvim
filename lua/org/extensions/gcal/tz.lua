---@mod org.extensions.gcal.tz IANA time zones for the gcal extension
---
--- Reads the system's compiled zone files (TZif, RFC 8536) from
--- `$TZDIR` or `/usr/share/zoneinfo`, so times convert correctly across
--- DST changes for any IANA zone (`Europe/Berlin`) without dependencies.
--- Instants after the file's last transition use its POSIX TZ footer rule.

local M = {}

local cache = {}

local function dirs()
  local out = {}
  if vim.env.TZDIR and vim.env.TZDIR ~= "" then
    out[#out + 1] = vim.env.TZDIR
  end
  vim.list_extend(out, { "/usr/share/zoneinfo", "/usr/lib/zoneinfo", "/usr/share/lib/zoneinfo" })
  return out
end

local function be(s, i, n, signed)
  local v = 0
  for k = 0, n - 1 do
    v = v * 256 + s:byte(i + k)
  end
  if signed and v >= 2 ^ (8 * n - 1) then
    v = v - 2 ^ (8 * n)
  end
  return v
end

---------------------------------------------------------------------------
-- POSIX TZ rules (the TZif footer, e.g. "CET-1CEST,M3.5.0,M10.5.0/3")
---------------------------------------------------------------------------

local function parse_offset(s, i)
  local sign, h, m, sec, j = s:match("^([+-]?)(%d+):?(%d*):?(%d*)()", i)
  if not h then
    return nil, i
  end
  local v = tonumber(h) * 3600 + (tonumber(m) or 0) * 60 + (tonumber(sec) or 0)
  return sign == "-" and -v or v, j
end

local function parse_name(s, i)
  if s:sub(i, i) == "<" then
    local j = s:find(">", i, true)
    return j and s:sub(i + 1, j - 1), j and j + 1 or i
  end
  local name, j = s:match("^(%a+)()", i)
  return name, j or i
end

local function parse_rule_date(s, i)
  local m, w, d, j = s:match("^M(%d+)%.(%d+)%.(%d+)()", i)
  local r
  if m then
    r = { kind = "M", m = tonumber(m), w = tonumber(w), d = tonumber(d) }
  else
    local n
    n, j = s:match("^J(%d+)()", i)
    if n then
      r = { kind = "J", n = tonumber(n) }
    else
      n, j = s:match("^(%d+)()", i)
      if not n then
        return nil, i
      end
      r = { kind = "n", n = tonumber(n) }
    end
  end
  r.time = 7200
  if s:sub(j, j) == "/" then
    r.time, j = parse_offset(s, j + 1)
  end
  return r, j
end

--- Parse a POSIX TZ string. Offsets are returned as seconds east of UTC.
---@param s string
---@return table|nil
function M.parse_posix(s)
  local std, i = parse_name(s, 1)
  if not std then
    return nil
  end
  local off
  off, i = parse_offset(s, i)
  if not off then
    return nil
  end
  local rule = { std = -off }
  local dst
  dst, i = parse_name(s, i)
  if not dst or dst == "" then
    return rule
  end
  local doff, j = parse_offset(s, i)
  rule.dst = doff and -doff or rule.std + 3600
  i = doff and j or i
  if s:sub(i, i) ~= "," then
    -- no rule given: the US rules (POSIX default)
    s, i = s .. ",M3.2.0,M11.1.0", #s + 1
  end
  rule.start, i = parse_rule_date(s, i + 1)
  if not rule.start or s:sub(i, i) ~= "," then
    return { std = rule.std }
  end
  rule["end"] = parse_rule_date(s, i + 1)
  if not rule["end"] then
    return { std = rule.std }
  end
  return rule
end

local function is_leap(y)
  return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

-- local seconds since the epoch at which a rule date takes effect in year y
local function rule_time(r, y)
  local date = require("org.date")
  local days
  if r.kind == "M" then
    local first = date.days_from_civil(y, r.m, 1)
    local wd = (first + 4) % 7 -- 1970-01-01 was a Thursday (4)
    local d = first + (r.d - wd) % 7 + (r.w - 1) * 7
    local mdays = ({ 31, is_leap(y) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 })[r.m]
    while d > first + mdays - 1 do
      d = d - 7
    end
    days = d
  elseif r.kind == "J" then
    -- 1..365, February 29 never counted
    local n = r.n
    if is_leap(y) and n >= 60 then
      n = n + 1
    end
    days = date.days_from_civil(y, 1, 1) + n - 1
  else
    days = date.days_from_civil(y, 1, 1) + r.n
  end
  return days * 86400 + r.time
end

local function posix_offset(rule, t)
  if not rule.start then
    return rule.std
  end
  local y = require("org.date").civil_from_days(math.floor((t + rule.std) / 86400))
  -- start is given in standard local time, end in daylight local time
  local s = rule_time(rule.start, y) - rule.std
  local e = rule_time(rule["end"], y) - rule.dst
  local in_dst
  if s < e then
    in_dst = t >= s and t < e
  else
    in_dst = t >= s or t < e -- southern hemisphere
  end
  return in_dst and rule.dst or rule.std
end

---------------------------------------------------------------------------
-- TZif
---------------------------------------------------------------------------

--- Parse TZif data into { times, types, offsets, footer }.
---@param s string
---@return table|nil
function M.parse_tzif(s)
  if not s or s:sub(1, 4) ~= "TZif" then
    return nil
  end
  local version = s:sub(5, 5)
  local function block(pos, tsize)
    -- isutcnt, isstdcnt, leapcnt, timecnt, typecnt, charcnt
    local isut, isstd, leap = be(s, pos + 20, 4), be(s, pos + 24, 4), be(s, pos + 28, 4)
    local timecnt, typecnt, charcnt = be(s, pos + 32, 4), be(s, pos + 36, 4), be(s, pos + 40, 4)
    local p = pos + 44
    local z = { times = {}, types = {}, offsets = {} }
    for k = 1, timecnt do
      z.times[k] = be(s, p + (k - 1) * tsize, tsize, true)
    end
    p = p + timecnt * tsize
    for k = 1, timecnt do
      z.types[k] = s:byte(p + k - 1) + 1
    end
    p = p + timecnt
    for k = 1, typecnt do
      z.offsets[k] = be(s, p + (k - 1) * 6, 4, true)
    end
    p = p + typecnt * 6 + charcnt + leap * (tsize + 4) + isstd + isut
    return z, p
  end
  local z, p = block(1, 4)
  if version >= "2" and #s > p + 44 and s:sub(p, p + 3) == "TZif" then
    z, p = block(p, 8)
    local footer = s:match("^\n([^\n]*)\n", p)
    if footer and footer ~= "" then
      z.footer = M.parse_posix(footer)
    end
  end
  return z
end

--- Load an IANA zone. Returns nil when it can't be found or read.
---@param name string
---@return table|nil
function M.load(name)
  if type(name) ~= "string" or name == "" or name:find("%.%.") then
    return nil
  end
  if cache[name] ~= nil then
    return cache[name] or nil
  end
  local zone
  if name == "UTC" or name == "Etc/UTC" or name == "GMT" then
    zone = { times = {}, types = {}, offsets = { 0 } }
  else
    for _, d in ipairs(dirs()) do
      local fd = io.open(d .. "/" .. name, "rb")
      if fd then
        zone = M.parse_tzif(fd:read("*a"))
        fd:close()
        if zone then
          break
        end
      end
    end
  end
  cache[name] = zone or false
  return zone
end

--- Offset from UTC (seconds) of zone `z` at UNIX time `t`.
---@param z table
---@param t integer
---@return integer
function M.offset_at(z, t)
  local n = #z.times
  if n == 0 then
    return z.footer and posix_offset(z.footer, t) or z.offsets[1] or 0
  end
  if t < z.times[1] then
    -- before the first transition: the first standard-time type
    return z.offsets[1] or 0
  end
  if t >= z.times[n] and z.footer then
    return posix_offset(z.footer, t)
  end
  local lo, hi = 1, n
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if z.times[mid] <= t then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return z.offsets[z.types[lo]] or 0
end

--- Offset from UTC of the IANA zone `name` at `t`, or nil when unknown.
---@param name string
---@param t integer
---@return integer|nil
function M.offset(name, t)
  local z = M.load(name)
  return z and M.offset_at(z, t) or nil
end

--- The system's IANA zone name: `$TZ`, `/etc/timezone` or the target of
--- the `/etc/localtime` link. nil when it can't be told.
---@return string|nil
function M.system_zone()
  local tz = vim.env.TZ
  if tz and tz ~= "" then
    tz = tz:gsub("^:", "")
    if tz:match("^%a[%w_%-%+]*/[%w_%-%+/]+$") or tz == "UTC" then
      return tz
    end
  end
  local fd = io.open("/etc/timezone", "r")
  if fd then
    local name = vim.trim(fd:read("*l") or "")
    fd:close()
    if name ~= "" then
      return name
    end
  end
  local link = vim.uv.fs_readlink("/etc/localtime")
  return link and link:match("zoneinfo/(.+)$") or nil
end

--- Forget loaded zones (tests).
function M.clear()
  cache = {}
end

return M
