---@mod org.extensions.gcal.event Google Calendar events <-> Org entries
---
--- Pure conversions between Calendar API v3 event resources and the
--- entries org-gcal writes: timestamps, the `:org-gcal:` drawer body and
--- the event JSON posted back.

local date = require("org.date")

local M = {}

M.DRAWER = "org-gcal"

---------------------------------------------------------------------------
-- Time zones
---------------------------------------------------------------------------

--- Offset of local wall time from UTC in seconds at UNIX time `t`: the
--- fixed `utc_offset` option (minutes) or the system zone.
---@param opts table
---@param t integer
---@return integer
function M.offset(opts, t)
  if opts.utc_offset then
    return math.floor(opts.utc_offset * 60)
  end
  local l, u = os.date("*t", t), os.date("!*t", t)
  return (date.days_from_civil(l.year, l.month, l.day) - date.days_from_civil(u.year, u.month, u.day)) * 86400
    + (l.hour - u.hour) * 3600
    + (l.min - u.min) * 60
    + (l.sec - u.sec)
end

--- UNIX time -> local civil { year, month, day, hour, min }.
function M.epoch_to_local(opts, t)
  local s = t + M.offset(opts, t)
  local days = math.floor(s / 86400)
  local y, m, d = date.civil_from_days(days)
  local rem = s - days * 86400
  return { year = y, month = m, day = d, hour = math.floor(rem / 3600), min = math.floor(rem % 3600 / 60) }
end

--- Local civil time -> UNIX time.
function M.local_to_epoch(opts, c)
  local wall = date.days_from_civil(c.year, c.month, c.day) * 86400 + (c.hour or 0) * 3600 + (c.min or 0) * 60
  -- the offset depends on the instant; two passes settle DST boundaries
  local t = wall - M.offset(opts, wall)
  return wall - M.offset(opts, t)
end

--- Parse RFC 3339 (`2026-09-28T10:00:00-07:00`, `...Z`) to UNIX time.
---@param s string
---@return integer|nil
function M.parse_rfc3339(s)
  local y, mo, d, h, mi, sec, rest = (s or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):?(%d*)%.?%d*(.*)$")
  if not y then
    return nil
  end
  local off = 0
  if rest ~= "" and rest ~= "Z" and rest ~= "z" then
    local sign, oh, om = rest:match("^([+-])(%d%d):?(%d%d)$")
    if not sign then
      return nil
    end
    off = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "-" and -1 or 1)
  end
  return date.days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + tonumber(h) * 3600
    + tonumber(mi) * 60
    + (tonumber(sec) or 0)
    - off
end

--- UNIX time -> RFC 3339 in local time with its offset.
function M.format_rfc3339(opts, t)
  local off = M.offset(opts, t)
  local c = M.epoch_to_local(opts, t)
  local sign = off < 0 and "-" or "+"
  local a = math.abs(off)
  return string.format(
    "%04d-%02d-%02dT%02d:%02d:00%s%02d:%02d",
    c.year,
    c.month,
    c.day,
    c.hour,
    c.min,
    sign,
    math.floor(a / 3600),
    math.floor(a % 3600 / 60)
  )
end

local function parse_date(s)
  local y, m, d = (s or ""):match("^(%d+)-(%d+)-(%d+)$")
  if y then
    return { year = tonumber(y), month = tonumber(m), day = tonumber(d) }
  end
end

local function add_days(c, n)
  local y, m, d = date.civil_from_days(date.days_from_civil(c.year, c.month, c.day) + n)
  return { year = y, month = m, day = d }
end

---------------------------------------------------------------------------
-- Event -> Org
---------------------------------------------------------------------------

--- The org timestamp of an event: `<2026-09-28 Mon 10:00-11:00>`, an
--- all-day `<2026-09-28 Mon>` or a `<a>--<b>` range across days.
---@param opts table
---@param ev table event resource
---@return string|nil
function M.timestamp(opts, ev)
  local s, e = ev.start or {}, ev["end"] or {}
  if s.date then
    local first = parse_date(s.date)
    if not first then
      return nil
    end
    -- the end date of an all-day event is exclusive
    local last = parse_date(e.date) and add_days(parse_date(e.date), -1) or first
    local a = date.Date.new({ year = first.year, month = first.month, day = first.day, active = true })
    if date.days_from_civil(last.year, last.month, last.day) > a:days() then
      a.range_end = date.Date.new({ year = last.year, month = last.month, day = last.day, active = true })
    end
    return a:to_string()
  end
  local st = M.parse_rfc3339(s.dateTime)
  if not st then
    return nil
  end
  local et = M.parse_rfc3339(e.dateTime) or st
  local a, b = M.epoch_to_local(opts, st), M.epoch_to_local(opts, et)
  a.active, b.active = true, true
  local ts = date.Date.new(a)
  if a.year == b.year and a.month == b.month and a.day == b.day then
    if et ~= st then
      ts.end_hour, ts.end_min = b.hour, b.min
    end
  else
    ts.range_end = date.Date.new(b)
  end
  return ts:to_string()
end

--- Description lines for the drawer: leading `*` becomes `✱` (so they
--- aren't headlines) and `:END:` lines are escaped with a comma.
---@param desc string|nil
---@return string[]
function M.description_lines(desc)
  if not desc or desc == "" then
    return {}
  end
  desc = desc:gsub("\r\n", "\n")
  local out = {}
  for _, l in ipairs(vim.split(desc, "\n", { plain = true })) do
    l = l:gsub("^%*", "✱")
    if l:match("^%s*:[%w_-]+:%s*$") then
      l = "," .. l
    end
    out[#out + 1] = l
  end
  while out[#out] == "" do
    out[#out] = nil
  end
  return out
end

--- Undo description_lines.
---@param lines string[]
---@return string
function M.description_text(lines)
  local out = {}
  for _, l in ipairs(lines) do
    l = l:gsub("^✱", "*"):gsub("^,(%s*:[%w_-]+:%s*)$", "%1")
    out[#out + 1] = l
  end
  while out[1] == "" do
    table.remove(out, 1)
  end
  while out[#out] == "" do
    out[#out] = nil
  end
  return table.concat(out, "\n")
end

--- `entry-id` for an event: `EVENTID/CALENDARID` (org-gcal's format).
function M.entry_id(calendar_id, ev)
  return ev.id .. "/" .. calendar_id
end

--- Split an entry-id into event id and calendar id.
---@return string|nil event_id, string|nil calendar_id
function M.split_entry_id(s)
  if not s then
    return nil
  end
  local ev, cal = s:match("^([^/]+)/(.+)$")
  return ev, cal
end

--- Managed property values of an event (nil removes the property).
---@param calendar_id string
---@param ev table
---@return { name: string, value: string|nil }[]
function M.properties(calendar_id, ev)
  return {
    { name = "ETag", value = ev.etag },
    { name = "LOCATION", value = ev.location ~= "" and ev.location or nil },
    { name = "LINK", value = ev.htmlLink and ("[[" .. ev.htmlLink .. "][Go to gcal web page]]") or nil },
    { name = "TRANSPARENCY", value = ev.transparency },
    { name = "calendar-id", value = calendar_id },
    { name = "entry-id", value = M.entry_id(calendar_id, ev) },
  }
end

--- The event's headline title (`busy` when it has none, like org-gcal).
function M.title(ev)
  local t = ev.summary
  if not t or vim.trim(t) == "" then
    return "busy"
  end
  return (t:gsub("[\r\n]+", " "))
end

--- Drawer body lines: the timestamp, then the description.
---@return string[]
function M.drawer_lines(opts, ev)
  local lines = {}
  local ts = M.timestamp(opts, ev)
  if ts then
    lines[#lines + 1] = ts
  end
  local desc = M.description_lines(ev.description)
  if #desc > 0 then
    lines[#lines + 1] = ""
    vim.list_extend(lines, desc)
  end
  return lines
end

---------------------------------------------------------------------------
-- Org -> Event
---------------------------------------------------------------------------

local function to_civil(ts)
  return { year = ts.year, month = ts.month, day = ts.day, hour = ts.hour, min = ts.min }
end

--- start/end of an event from an org timestamp object.
---@param opts table
---@param ts table org.date timestamp
---@return table start, table end
function M.times(opts, ts)
  local last = ts.range_end or ts
  local function tzfield(t)
    if opts.local_timezone then
      t.timeZone = opts.local_timezone
    end
    return t
  end
  if not ts.hour then
    local e = add_days(to_civil(last), 1)
    return { date = string.format("%04d-%02d-%02d", ts.year, ts.month, ts.day) },
      { date = string.format("%04d-%02d-%02d", e.year, e.month, e.day) }
  end
  local st = M.local_to_epoch(opts, to_civil(ts))
  local et
  if ts.range_end and ts.range_end.hour then
    et = M.local_to_epoch(opts, to_civil(ts.range_end))
  elseif ts.range_end then
    et = M.local_to_epoch(opts, { year = last.year, month = last.month, day = last.day, hour = 23, min = 59 })
  elseif ts.end_hour then
    local c = to_civil(ts)
    c.hour, c.min = ts.end_hour, ts.end_min
    et = M.local_to_epoch(opts, c)
  else
    et = st + (opts.default_duration or 0) * 60
  end
  return tzfield({ dateTime = M.format_rfc3339(opts, st) }), tzfield({ dateTime = M.format_rfc3339(opts, et) })
end

--- The event body posted for an entry.
---@param opts table
---@param entry { title: string, timestamp: table, description?: string, location?: string, transparency?: string }
---@return table
function M.to_event(opts, entry)
  local s, e = M.times(opts, entry.timestamp)
  return {
    summary = entry.title,
    start = s,
    ["end"] = e,
    description = entry.description or "",
    location = entry.location or "",
    transparency = entry.transparency,
  }
end

return M
