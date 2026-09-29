---@mod org.extensions.gcal.event Google Calendar events <-> Org entries
---
--- Pure conversions between Calendar API v3 event resources and the
--- entries org-gcal writes: timestamps, the `:org-gcal:` drawer body,
--- properties and the event JSON posted back.

local date = require("org.date")
local tz = require("org.extensions.gcal.tz")

local M = {}

---------------------------------------------------------------------------
-- Time zones
---------------------------------------------------------------------------

local function system_offset(t)
  local l, u = os.date("*t", t), os.date("!*t", t)
  return (date.days_from_civil(l.year, l.month, l.day) - date.days_from_civil(u.year, u.month, u.day)) * 86400
    + (l.hour - u.hour) * 3600
    + (l.min - u.min) * 60
    + (l.sec - u.sec)
end

--- Offset of wall time from UTC in seconds at UNIX time `t`, for `zone`
--- (an IANA name) or, without one, the local zone: the fixed `utc_offset`
--- option (minutes), `local_timezone`, or the system zone.
---@param opts table
---@param t integer
---@param zone? string
---@return integer
function M.offset(opts, t, zone)
  if type(zone) == "string" then
    local off = tz.offset(zone, t)
    if off then
      return off
    end
  end
  if opts.utc_offset then
    return math.floor(opts.utc_offset * 60)
  end
  if opts.local_timezone then
    local off = tz.offset(opts.local_timezone, t)
    if off then
      return off
    end
  end
  return system_offset(t)
end

--- The IANA zone sent as `timeZone` with posted timed events: `zone`,
--- `local_timezone`, "UTC" or `Etc/GMT±N` for a whole-hour `utc_offset`,
--- or the system zone. nil when none is known.
---@param opts table
---@param zone? string
---@return string|nil
function M.send_zone(opts, zone)
  if zone then
    return zone
  end
  if opts.local_timezone then
    return opts.local_timezone
  end
  if opts.utc_offset then
    local h = opts.utc_offset / 60
    if h == 0 then
      return "UTC"
    elseif h == math.floor(h) and math.abs(h) <= 14 then
      -- POSIX sign: Etc/GMT-2 is two hours east of UTC
      return string.format("Etc/GMT%s%d", h > 0 and "-" or "+", math.abs(h))
    end
    return nil
  end
  local sys = tz.system_zone()
  return sys and tz.load(sys) and sys or nil
end

--- UNIX time -> civil { year, month, day, hour, min } in `zone` (or local).
function M.epoch_to_local(opts, t, zone)
  local s = t + M.offset(opts, t, zone)
  local days = math.floor(s / 86400)
  local y, m, d = date.civil_from_days(days)
  local rem = s - days * 86400
  return { year = y, month = m, day = d, hour = math.floor(rem / 3600), min = math.floor(rem % 3600 / 60) }
end

--- Civil time in `zone` (or local) -> UNIX time.
function M.local_to_epoch(opts, c, zone)
  local wall = date.days_from_civil(c.year, c.month, c.day) * 86400 + (c.hour or 0) * 3600 + (c.min or 0) * 60
  -- the offset depends on the instant; two passes settle DST boundaries
  local t = wall - M.offset(opts, wall, zone)
  return wall - M.offset(opts, t, zone)
end

--- Parse RFC 3339 (`2026-09-28T10:00:00-07:00`, `...Z`) to UNIX time and
--- the offset it carries (seconds).
---@param s string
---@return integer|nil t, integer|nil offset
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
    - off,
    off
end

--- UNIX time -> RFC 3339 in `zone` (or local) time with its offset.
function M.format_rfc3339(opts, t, zone)
  local off = M.offset(opts, t, zone)
  local c = M.epoch_to_local(opts, t, zone)
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

--- The zone an event's times are shown in with `time_zone = "event"`: its
--- start's `timeZone`, else the calendar's (from the events list).
---@param ev table
---@return string|nil
function M.event_zone(ev)
  return (ev.start or {}).timeZone or ev._calendar_zone
end

--- start and end of an event as UNIX times (nil for all-day events).
---@return integer|nil start, integer|nil end
function M.bounds(ev)
  local s, e = ev.start or {}, ev["end"] or {}
  if s.date then
    local a, b = parse_date(s.date), parse_date(e.date or s.date)
    if not a then
      return nil
    end
    b = b or a
    return date.days_from_civil(a.year, a.month, a.day) * 86400, date.days_from_civil(b.year, b.month, b.day) * 86400
  end
  local st = M.parse_rfc3339(s.dateTime)
  return st, M.parse_rfc3339(e.dateTime) or st
end

---------------------------------------------------------------------------
-- Event -> Org
---------------------------------------------------------------------------

--- Wall time of `dt` (an RFC 3339 string): in `zone` when it can be read,
--- else in the offset the string carries, or in local time when
--- `as_local` is set.
local function wall(opts, dt, as_local, zone)
  local t, off = M.parse_rfc3339(dt)
  if not t then
    return nil
  end
  if as_local then
    return M.epoch_to_local(opts, t), t
  end
  if zone and tz.load(zone) then
    return M.epoch_to_local(opts, t, zone), t
  end
  return M.epoch_to_local({ utc_offset = off / 60 }, t), t
end

--- The org timestamp of an event: `<2026-09-28 Mon 10:00-11:00>`, an
--- all-day `<2026-09-28 Mon>` or a `<a>--<b>` range across days. Times are
--- local, or in the event's zone with `opts.time_zone == "event"`.
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
  local as_local = opts.time_zone ~= "event"
  local zone = not as_local and M.event_zone(ev) or nil
  local a, st = wall(opts, s.dateTime, as_local, zone)
  if not a then
    return nil
  end
  local b, et = wall(opts, e.dateTime or s.dateTime, as_local, zone)
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

--- HTML of a description as plain text (org-gcal--strip-html).
---@param s string
---@return string
function M.strip_html(s)
  s = s:gsub("<[Bb][Rr][^>]*>", "\n")
    :gsub("<[Ll][Ii][^>]*>", "\n- ")
    :gsub("</?[Pp]>", "\n")
    :gsub("<[^>]+>", "")
    :gsub("&lt;", "<")
    :gsub("&gt;", ">")
    :gsub("&nbsp;", " ")
    :gsub("&quot;", '"')
    :gsub("&#39;", "'")
    :gsub("&amp;", "&")
    :gsub("\n\n\n+", "\n\n")
  return vim.trim(s)
end

--- Whether descriptions of `calendar_id` are stripped of HTML.
function M.strip_html_p(opts, calendar_id)
  local o = (opts.strip_html_descriptions_overrides or {})[calendar_id]
  if o ~= nil then
    return o
  end
  return opts.strip_html_descriptions and true or false
end

--- The description of an event as written to the entry.
function M.description(opts, calendar_id, ev)
  local d = ev.description
  if type(d) ~= "string" or d == "" then
    return nil
  end
  if M.strip_html_p(opts, calendar_id) then
    d = M.strip_html(d)
  end
  return d
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
function M.entry_id(calendar_id, event_id)
  if type(event_id) == "table" then
    event_id = event_id.id
  end
  return event_id .. "/" .. calendar_id
end

--- Split an entry-id into event id and calendar id.
---@return string|nil event_id, string|nil calendar_id
function M.split_entry_id(s)
  if not s then
    return nil
  end
  local ev, cal = s:match("^([^/\n]+)/([^/\n]+)$")
  return ev, cal
end

--- `recurrence` property value: org-gcal prints the API's list as
--- `[RRULE:FREQ=WEEKLY EXDATE:...]`.
---@param list string[]|nil
---@return string|nil
function M.format_recurrence(list)
  if type(list) ~= "table" or #list == 0 then
    return nil
  end
  return "[" .. table.concat(list, " ") .. "]"
end

---@param s string|nil
---@return string[]|nil
function M.parse_recurrence(s)
  if not s or s == "" then
    return nil
  end
  s = s:gsub("^%s*[%[(]", ""):gsub("[%])]%s*$", "")
  local out = {}
  for part in s:gmatch("%S+") do
    out[#out + 1] = (part:gsub('^"', ""):gsub('"$', ""))
  end
  return #out > 0 and out or nil
end

local FREQ = { d = "DAILY", w = "WEEKLY", m = "MONTHLY", y = "YEARLY" }

--- An RRULE for an org repeater (`+1w` -> `RRULE:FREQ=WEEKLY;INTERVAL=1`).
---@param rep table|nil org.date repeater
---@return string|nil rule, string? err
function M.rrule(rep)
  if not rep or (rep.value or 0) <= 0 then
    return nil
  end
  local freq = FREQ[rep.unit]
  if not freq then
    return nil, "Google Calendar can't repeat every " .. rep.value .. rep.unit .. " (use days or longer)"
  end
  return string.format("RRULE:FREQ=%s;INTERVAL=%d", freq, rep.value)
end

--- The org link for an event's `source` (org-gcal writes it to `link`, or to
--- ROAM_REFS when it has no title).
function M.source_link(source)
  if type(source) ~= "table" or not source.url or source.url == "" then
    return nil
  end
  if source.title and source.title ~= "" then
    return "[[" .. source.url .. "][" .. source.title .. "]]"
  end
  return "[[" .. source.url .. "]]"
end

--- Parse an org link (or a bare URL) into an event `source`.
function M.source_from_link(s)
  if not s or s == "" then
    return nil
  end
  local url, title = s:match("%[%[([^%]]+)%]%[([^%]]*)%]%]")
  if not url then
    url = s:match("%[%[([^%]]+)%]%]") or s:match("^%s*(%S+)%s*$")
  end
  if not url then
    return nil
  end
  return { url = url, title = title ~= "" and title or nil }
end

--- Property names, from the options (org-gcal-*-property).
function M.names(opts)
  return {
    entry_id = opts.entry_id_property or "entry-id",
    calendar_id = opts.calendar_id_property or "calendar-id",
    etag = opts.etag_property or "ETag",
    managed = opts.managed_property or "org-gcal-managed",
    drawer = opts.drawer_name or "org-gcal",
  }
end

--- Managed property values of an event, in order (nil removes one).
--- `current` holds the entry's properties (upper-case keys) so a source is
--- written where the entry already keeps it.
---@param opts table
---@param calendar_id string
---@param ev table
---@param current? table<string, string>
---@return { name: string, value: string|nil }[]
function M.properties(opts, calendar_id, ev, current)
  local n = M.names(opts)
  current = current or {}
  local out = { { name = n.etag, value = ev.etag } }
  if ev.recurrence then
    out[#out + 1] = { name = "recurrence", value = M.format_recurrence(ev.recurrence) }
  end
  if type(ev.location) == "string" and ev.location ~= "" then
    out[#out + 1] = { name = "LOCATION", value = (ev.location:gsub("\r?\n", ", ")) }
  end
  if type(ev.source) == "table" and ev.source.url then
    local refs = vim.split(vim.trim(current.ROAM_REFS or ""), "%s+", { trimempty = true })
    if not current.LINK and #refs <= 1 and not (ev.source.title and ev.source.title ~= "") then
      out[#out + 1] = { name = "ROAM_REFS", value = ev.source.url }
    else
      out[#out + 1] = { name = "link", value = M.source_link(ev.source) }
    end
  end
  if type(ev.transparency) == "string" then
    out[#out + 1] = { name = "TRANSPARENCY", value = ev.transparency }
  end
  if type(ev.hangoutLink) == "string" and ev.hangoutLink ~= "" then
    out[#out + 1] = { name = "HANGOUTS", value = "[[" .. ev.hangoutLink .. "][Join Hangouts Meet]]" }
  end
  if opts.time_zone == "event" and ev.start and ev.start.dateTime then
    out[#out + 1] = { name = "TIMEZONE", value = M.event_zone(ev) }
  end
  out[#out + 1] = { name = n.calendar_id, value = calendar_id }
  out[#out + 1] = { name = n.entry_id, value = M.entry_id(calendar_id, ev) }
  return out
end

--- The event's headline title (`busy` when it has none, like org-gcal).
---@param ev table
---@param current? string the entry's title
function M.title(ev, current, cancelled_kw)
  local t = ev.summary
  if type(t) ~= "string" or vim.trim(t) == "" or (cancelled_kw and t == cancelled_kw) then
    if current and current ~= "" then
      return current
    end
    return "busy"
  end
  return (t:gsub("[\r\n]+", " "))
end

--- Drawer body lines: the timestamp, then the description.
---@param opts table
---@param ev table
---@param calendar_id? string
---@param keep_ts? string a timestamp kept instead (recurring parents)
---@return string[]
function M.drawer_lines(opts, ev, calendar_id, keep_ts)
  local lines = {}
  local ts = keep_ts or M.timestamp(opts, ev)
  if ts then
    lines[#lines + 1] = ts
  end
  local desc = M.description_lines(M.description(opts, calendar_id, ev))
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

--- start/end of an event from an org timestamp object. Each carries a
--- JSON null for the other of date/dateTime, so a PATCH can turn a timed
--- event into an all-day one and back.
---@param opts table
---@param ts table org.date timestamp
---@param zone? string the entry's TIMEZONE (time_zone = "event")
---@param duration? integer minutes when the timestamp has no end
---@return table start, table end
function M.times(opts, ts, zone, duration)
  local last = ts.range_end or ts
  if not ts.hour then
    local e = add_days(to_civil(last), 1)
    return { date = string.format("%04d-%02d-%02d", ts.year, ts.month, ts.day), dateTime = vim.NIL },
      { date = string.format("%04d-%02d-%02d", e.year, e.month, e.day), dateTime = vim.NIL }
  end
  local st = M.local_to_epoch(opts, to_civil(ts), zone)
  local et
  if ts.range_end and ts.range_end.hour then
    et = M.local_to_epoch(opts, to_civil(ts.range_end), zone)
  elseif ts.range_end then
    et = M.local_to_epoch(opts, { year = last.year, month = last.month, day = last.day, hour = 23, min = 59 }, zone)
  elseif ts.end_hour then
    local c = to_civil(ts)
    c.hour, c.min = ts.end_hour, ts.end_min
    et = M.local_to_epoch(opts, c, zone)
  else
    et = st + (duration or opts.default_duration or 0) * 60
  end
  local send = M.send_zone(opts, zone)
  return { dateTime = M.format_rfc3339(opts, st, zone), date = vim.NIL, timeZone = send },
    { dateTime = M.format_rfc3339(opts, et, zone), date = vim.NIL, timeZone = send }
end

--- The event body posted for an entry.
---@param opts table
---@param entry table see `org.extensions.gcal.sync.entry`
---@return table|nil body, string? err
function M.to_event(opts, entry)
  local body = {
    summary = entry.title,
    description = entry.description or "",
    location = entry.location or "",
    transparency = entry.transparency or opts.default_transparency,
    source = M.source_from_link(entry.link) or vim.NIL,
  }
  local rep = entry.timestamp and entry.timestamp.repeater
  local rule, err = M.rrule(rep)
  if err then
    return nil, err
  end
  if rule then
    -- the repeater gives the rule; other lines (EXDATE, RDATE) are kept
    local list = { rule }
    for _, l in ipairs(M.parse_recurrence(entry.recurrence) or {}) do
      if not l:match("^RRULE:") then
        list[#list + 1] = l
      end
    end
    body.recurrence = list
  elseif entry.recurrence then
    -- a fetched recurring event: the series' times stay as they are
    body.recurrence = M.parse_recurrence(entry.recurrence)
    return body
  end
  body.start, body["end"] = M.times(opts, entry.timestamp, entry.zone, entry.duration)
  if body.recurrence and not body.start.timeZone and body.start.dateTime ~= vim.NIL then
    return nil, "a repeating event needs a time zone: set extensions.gcal.local_timezone"
  end
  return body
end

return M
