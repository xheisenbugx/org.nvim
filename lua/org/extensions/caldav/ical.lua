---@mod org.extensions.caldav.ical Calendar components as the fields org syncs
---
--- A VEVENT or VTODO is read into a table of plain strings, its fields
--- (`summary`, `description`, `location` and its times), which the sync
--- compares with the fields of an org entry. Times are keys: an org
--- timestamp without its brackets and day name, in the display zone
--- (`2026-11-10 10:00-11:00 +1w`, `2026-11-10--2026-11-12`), several
--- joined by newlines.
---
--- Writing goes the other way a field at a time: `patch` replaces the
--- properties of the changed fields in the component as the server holds
--- it and leaves the rest (attendees, alarms, unknown properties) alone.

local parser = require("org.extensions.ics.parser")
local date = require("org.date")

local M = {}

local floor = math.floor
local fmt = string.format

--- The fields of each component, in the order they are reported.
---@type table<string, string[]>
M.FIELDS = {
  VEVENT = { "summary", "time", "location", "description" },
  VTODO = { "summary", "status", "priority", "scheduled", "deadline", "location", "description" },
}

---@class org.caldav.Context
---@field timezone? string the zone org timestamps are in (nil: the system's)
---@field tz_aliases? table<string, string>
---@field zone_name? string the IANA name of that zone, when known
---@field from integer first day (a day number) occurrences are listed from
---@field to integer last day
---@field now integer epoch of this sync

---@class org.caldav.Remote
---@field uid string
---@field type "VEVENT"|"VTODO"
---@field fields table<string, string>
---@field ro table<string, boolean> fields only the calendar can change

---------------------------------------------------------------------------
-- Keys
---------------------------------------------------------------------------

---@param naive number
---@return string
local function ymd(naive)
  local c = parser.civil(naive)
  return fmt("%04d-%02d-%02d", c.year, c.month, c.day)
end

---@param naive number
---@return string
local function hm(naive)
  local c = parser.civil(naive)
  return fmt("%02d:%02d", c.hour, c.min)
end

---@param r? { value: integer, unit: string }
---@return string
local function rep_text(r)
  return r and (" +" .. r.value .. r.unit) or ""
end

--- The key of a span of wall time (naive seconds, `e` exclusive).
---@param s number
---@param e number
---@param all_day boolean
---@param repeater? { value: integer, unit: string }
---@return string
function M.span_key(s, e, all_day, repeater)
  local rep = rep_text(repeater)
  if all_day then
    local first = floor(s / 86400)
    local last = floor((math.max(e, s + 86400) - 1) / 86400)
    if last > first then
      return ymd(s) .. rep .. "--" .. ymd(last * 86400)
    end
    return ymd(s) .. rep
  end
  if e <= s then
    return ymd(s) .. " " .. hm(s) .. rep
  end
  if floor(s / 86400) == floor(e / 86400) then
    return ymd(s) .. " " .. hm(s) .. "-" .. hm(e) .. rep
  end
  return ymd(s) .. " " .. hm(s) .. rep .. "--" .. ymd(e) .. " " .. hm(e)
end

--- The key of an org timestamp.
---@param d org.Date
---@return string
function M.date_key(d)
  local s = fmt("%04d-%02d-%02d", d.year, d.month, d.day)
  local rep = rep_text(d.repeater)
  if d.hour then
    s = s .. fmt(" %02d:%02d", d.hour, d.min or 0)
    if d.end_hour then
      return s .. fmt("-%02d:%02d", d.end_hour, d.end_min or 0) .. rep
    end
  end
  local r = d.range_end
  if r then
    local same = r.year == d.year and r.month == d.month and r.day == d.day
    if same and d.hour and r.hour then
      if r.hour * 60 + (r.min or 0) > d.hour * 60 + (d.min or 0) then
        return s .. fmt("-%02d:%02d", r.hour, r.min or 0) .. rep
      end
      return s .. rep
    elseif same and not d.hour then
      return s .. rep
    end
    local stop = fmt("%04d-%02d-%02d", r.year, r.month, r.day)
    if d.hour then
      stop = stop .. fmt(" %02d:%02d", r.hour or d.hour, r.hour and (r.min or 0) or (d.min or 0))
    end
    return s .. rep .. "--" .. stop
  end
  return s .. rep
end

--- The key of an org timestamp as a point in time: its date, its start
--- time and its repeater (what SCHEDULED and DEADLINE of a task sync).
---@param d org.Date
---@return string
function M.point_key(d)
  local s = fmt("%04d-%02d-%02d", d.year, d.month, d.day)
  if d.hour then
    s = s .. fmt(" %02d:%02d", d.hour, d.min or 0)
  end
  return s .. rep_text(d.repeater)
end

--- The org timestamp of a key (active), or nil for one that isn't a date.
---@param key string
---@return org.Date|nil
function M.key_date(key)
  local a, b = key:match("^(.-)%-%-(.+)$")
  return date.parse("<" .. (a or key) .. ">" .. (b and ("--<" .. b .. ">") or ""))
end

---------------------------------------------------------------------------
-- Text
---------------------------------------------------------------------------

--- Escape a TEXT value.
---@param s string
---@return string
local function esc(s)
  return (s:gsub("[\\;,]", "\\%0"):gsub("\r?\n", "\\n"))
end

--- A summary on one line.
---@param s string|nil
---@return string
function M.one_line(s)
  return vim.trim(((s or ""):gsub("%s*[\r\n]+%s*", " ")))
end

--- A description without trailing blanks and without blank lines around it.
---@param s string|nil
---@return string
function M.block(s)
  local lines = vim.split(((s or ""):gsub("\r", "")), "\n", { plain = true })
  for i, l in ipairs(lines) do
    lines[i] = l:gsub("%s+$", "")
  end
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  while #lines > 0 and lines[1] == "" do
    table.remove(lines, 1)
  end
  return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

---@param comp table
---@param name string
---@return { name: string, params: table<string, string>, value: string }|nil
local function prop(comp, name)
  for _, p in ipairs(comp.props) do
    if p.name == name then
      return p
    end
  end
  return nil
end

---@param comp table
---@param name string
---@return string
local function text_of(comp, name)
  local p = prop(comp, name)
  return p and parser.text(p.value) or ""
end

local UNIT = { HOURLY = "h", DAILY = "d", WEEKLY = "w", MONTHLY = "m", YEARLY = "y" }
local FREQ = { h = "HOURLY", d = "DAILY", w = "WEEKLY", m = "MONTHLY", y = "YEARLY" }

--- Weekday of naive seconds: 1 = Monday ... 7 = Sunday.
---@param naive number
---@return integer
local function weekday(naive)
  return (floor(naive / 86400) + 3) % 7 + 1
end

---@param rule table
---@return boolean
local function open_ended(rule)
  return not (
    rule.count
    or rule.until_
    or rule.bysetpos
    or rule.byyearday
    or rule.byhour
    or rule.byminute
    or rule.bysecond
    or #rule.unsupported > 0
  )
end

--- The org repeater a recurrence rule is the same as (`+1w`), or nil for
--- one a repeater can't say (a count, an end, several weekdays, ...).
--- `start` is the first occurrence in the component's own zone.
---@param rule table an `ics.parser.rrule`
---@param start number
---@return { value: integer, unit: string }|nil
function M.repeater(rule, start)
  local unit = UNIT[rule.freq]
  if not unit or not open_ended(rule) then
    return nil
  end
  local c = parser.civil(start)
  local byday = rule.byday
  if byday then
    if not (unit == "w" and #byday == 1 and byday[1].wd == weekday(start) and not byday[1].n) then
      return nil
    end
  end
  local md = rule.bymonthday
  if md and not ((unit == "m" or unit == "y") and #md == 1 and md[1] == c.day) then
    return nil
  end
  local bm = rule.bymonth
  if bm and not (unit == "y" and #bm == 1 and bm[1] == c.month) then
    return nil
  end
  return { value = rule.interval, unit = unit }
end

--- The weekdays of a plain weekly rule on several days (`BYDAY=MO,WE,FR`,
--- every week, no end), as days after `start`, or nil.
---@param rule table
---@param start number
---@return integer[]|nil
local function weekly_offsets(rule, start)
  local byday = rule.byday
  if rule.freq ~= "WEEKLY" or rule.interval ~= 1 or not byday or #byday < 2 or not open_ended(rule) then
    return nil
  end
  if rule.bymonth or rule.bymonthday then
    return nil
  end
  local offsets, has_start = {}, false
  for _, d in ipairs(byday) do
    if d.n then
      return nil
    end
    local off = (d.wd - weekday(start)) % 7
    has_start = has_start or off == 0
    offsets[#offsets + 1] = off
  end
  if not has_start then
    return nil
  end
  table.sort(offsets)
  return offsets
end

--- The wall-time span of an event in the display zone.
---@param cal org.ics.Calendar
---@param ev org.ics.Event
---@param o org.caldav.Context
---@return number s, number e
local function span(cal, ev, o)
  local s = parser.localize(cal, ev.start, o.timezone, o.tz_aliases)
  if ev.start.all_day then
    local len = ev.stop and (ev.stop.naive - ev.start.naive) or ev.duration or 86400
    return s, s + math.max(len, 86400)
  end
  local len = 0
  local stop = ev.stop
  if stop then
    len = stop.naive - ev.start.naive
    if stop.tzid ~= ev.start.tzid or stop.utc ~= ev.start.utc then
      local a, b = parser.epoch(cal, ev.start, o.tz_aliases), parser.epoch(cal, stop, o.tz_aliases)
      if a and b then
        len = b - a
      end
    end
  elseif ev.duration then
    len = ev.duration
  end
  local ep = parser.epoch(cal, ev.start, o.tz_aliases)
  if ep then
    return s, parser.wall(ep + len, o.timezone)
  end
  return s, s + len
end

---@param cal org.ics.Calendar
---@param ev org.ics.Event
---@param overrides integer changed instances stored with the event
---@param o org.caldav.Context
---@return string key, boolean ro
local function event_time(cal, ev, overrides, o)
  local all_day = ev.start.all_day or false
  local s, e = span(cal, ev, o)
  if not (ev.rrule or #ev.rdates > 0) then
    return M.span_key(s, e, all_day), false
  end
  local one_day = floor(s / 86400) == floor(math.max(e - 1, s) / 86400)
  if ev.rrule and #ev.rdates == 0 and #ev.exdates == 0 and overrides == 0 and one_day then
    local rep = M.repeater(ev.rrule, ev.start.naive)
    if rep then
      return M.span_key(s, e, all_day, rep), false
    end
    local offsets = weekly_offsets(ev.rrule, ev.start.naive)
    if offsets then
      local keys = {}
      for _, off in ipairs(offsets) do
        local t = { naive = ev.start.naive + off * 86400, all_day = all_day, utc = ev.start.utc, tzid = ev.start.tzid }
        local ls = parser.localize(cal, t, o.timezone, o.tz_aliases)
        keys[#keys + 1] = M.span_key(ls, ls + (e - s), all_day, { value = 1, unit = "w" })
      end
      return table.concat(keys, "\n"), true
    end
  end
  -- a rule org can't write: the occurrences of the days around today
  local keys, seen = {}, {}
  local occs = parser.occurrences(cal, o.from, o.to, { timezone = o.timezone, aliases = o.tz_aliases })
  for _, occ in ipairs(occs) do
    local key = M.span_key(occ.start, occ.stop, occ.all_day)
    if not seen[key] then
      seen[key] = true
      keys[#keys + 1] = key
    end
  end
  if #keys == 0 then
    keys[1] = M.span_key(s, e, all_day)
  end
  return table.concat(keys, "\n"), true
end

--- The key of a DATE or DATE-TIME property (a point in time), or "".
---@param cal org.ics.Calendar
---@param comp table
---@param name string
---@param o org.caldav.Context
---@return string key, table|nil time the value as `ics.parser.time` reads it
local function point(cal, comp, name, o)
  local p = prop(comp, name)
  local t = p and parser.time(p.value, p.params)
  if not p or not t then
    return "", nil
  end
  if p.params.VALUE == "DATE" then
    t.all_day = true
  end
  local s = parser.localize(cal, t, o.timezone, o.tz_aliases)
  return M.span_key(s, s, t.all_day or false), t
end

---@param n integer|nil a PRIORITY value
---@return string "", "1", "5" or "9"
local function priority_class(n)
  if not n or n <= 0 then
    return ""
  elseif n <= 4 then
    return "1"
  elseif n <= 8 then
    return "5"
  end
  return "9"
end

---@param cal org.ics.Calendar
---@param comp table
---@param o org.caldav.Context
---@return table<string, string> fields, table<string, boolean> ro
local function todo_fields(cal, comp, o)
  local fields, ro = {}, {}
  local scheduled, st = point(cal, comp, "DTSTART", o)
  local deadline, due = point(cal, comp, "DUE", o)
  local r = prop(comp, "RRULE")
  local rule = r and parser.rrule(r.value)
  local base = st or due
  if rule and base then
    local rep = not prop(comp, "RDATE") and not prop(comp, "EXDATE") and M.repeater(rule, base.naive)
    if rep then
      scheduled = scheduled ~= "" and (scheduled .. rep_text(rep)) or ""
      deadline = deadline ~= "" and (deadline .. rep_text(rep)) or ""
    else
      ro.scheduled, ro.deadline = true, true
    end
  end
  fields.scheduled, fields.deadline = scheduled, deadline
  local status = text_of(comp, "STATUS"):upper()
  local percent = tonumber(text_of(comp, "PERCENT-COMPLETE"))
  if status == "CANCELLED" then
    fields.status = "cancelled"
  elseif status == "COMPLETED" or (status == "" and (percent == 100 or prop(comp, "COMPLETED"))) then
    fields.status = "done"
  else
    fields.status = "todo"
  end
  fields.priority = priority_class(tonumber(text_of(comp, "PRIORITY")))
  local completed = point(cal, comp, "COMPLETED", o)
  if completed ~= "" then
    fields._completed = completed
  end
  return fields, ro
end

--- Read the event or task of a calendar resource.
---@param text string its iCalendar text
---@param o org.caldav.Context
---@return org.caldav.Remote|nil remote, string|nil err
function M.read(text, o)
  local comps = {}
  for _, vcal in ipairs(parser.tree(text).children) do
    for _, c in ipairs(vcal.name == "VCALENDAR" and vcal.children or {}) do
      if c.name == "VEVENT" or c.name == "VTODO" then
        comps[#comps + 1] = c
      end
    end
  end
  local main
  for _, c in ipairs(comps) do
    if not prop(c, "RECURRENCE-ID") then
      main = c
      break
    end
  end
  main = main or comps[1]
  if not main then
    return nil, "no event or task in it"
  end
  local uid = text_of(main, "UID")
  if uid == "" then
    return nil, "no UID"
  end
  local cal = parser.parse(text)
  local fields, ro
  if main.name == "VEVENT" then
    local ev, overrides = nil, 0
    for _, x in ipairs(cal.events) do
      if x.recurrence_id then
        overrides = overrides + 1
        ev = ev or x
      elseif not ev or ev.recurrence_id then
        ev = x
      end
    end
    if not ev then
      return nil, "no start time"
    end
    local time, time_ro = event_time(cal, ev, ev.recurrence_id and 0 or overrides, o)
    fields, ro = { time = time }, { time = time_ro or nil }
  else
    fields, ro = todo_fields(cal, main, o)
  end
  fields.summary = M.one_line(text_of(main, "SUMMARY"))
  fields.description = M.block(text_of(main, "DESCRIPTION"))
  fields.location = M.one_line((text_of(main, "LOCATION"):gsub("%s*\n%s*", ", ")))
  return { uid = uid, type = main.name, fields = fields, ro = ro }, nil
end

---------------------------------------------------------------------------
-- Writing
---------------------------------------------------------------------------

---@param naive number
---@return string `YYYYMMDD`
local function d8(naive)
  local c = parser.civil(naive)
  return fmt("%04d%02d%02d", c.year, c.month, c.day)
end

---@param naive number
---@return string `YYYYMMDDTHHMMSS`
local function dt(naive)
  local c = parser.civil(naive)
  return fmt("%04d%02d%02dT%02d%02d%02d", c.year, c.month, c.day, c.hour, c.min, c.sec)
end

--- A UTC date-time of an epoch.
---@param epoch integer
---@return string
function M.utc(epoch)
  return dt(epoch) .. "Z"
end

--- The epoch of wall time `naive` in the display zone.
---@param naive number
---@param o org.caldav.Context
---@return integer
function M.epoch(naive, o)
  if o.timezone then
    return parser.system_epoch(o.timezone, naive)
  end
  local c = parser.civil(naive)
  return os.time({ year = c.year, month = c.month, day = c.day, hour = c.hour, min = c.min, sec = c.sec })
end

--- The zone of the system database a TZID names (an alias, a
--- Mozilla-style path, a Windows name), or nil.
---@param tzid string
---@param aliases? table<string, string>
---@return string|nil
local function iana(tzid, aliases)
  local name = aliases and aliases[tzid] or tzid
  while name and not parser.system_zone(name) and name:find("/") do
    name = name:match("^/?[^/]*/(.*)$")
  end
  if name and parser.system_zone(name) then
    return name
  end
  local win = parser.WINDOWS_ZONES[tzid]
  return win and parser.system_zone(win) and win or nil
end

local DAYS = { [0] = "SU", "MO", "TU", "WE", "TH", "FR", "SA" }

---@param sec integer
---@return string `+0100`
local function offset(sec)
  local sign = sec < 0 and "-" or "+"
  sec = math.abs(sec)
  return fmt("%s%02d%02d", sign, floor(sec / 3600), floor(sec % 3600 / 60))
end

--- The VTIMEZONE of a zone of the system database, from its current rule,
--- or nil when it has none this can write.
---@param name string
---@return string[]|nil
function M.vtimezone(name)
  local z = require("org.extensions.ics.tzif").load(name)
  local f = z and z.footer
  if not f then
    return nil
  end
  local out = { "BEGIN:VTIMEZONE", "TZID:" .. name }
  if not f.dst then
    vim.list_extend(out, {
      "BEGIN:STANDARD",
      "DTSTART:19700101T000000",
      "TZOFFSETFROM:" .. offset(f.std),
      "TZOFFSETTO:" .. offset(f.std),
      "END:STANDARD",
    })
  else
    local function observance(kind, rule, from, to)
      if not rule or rule.kind ~= "M" or rule.time < 0 or rule.time >= 86400 then
        return false
      end
      local first = date.days_from_civil(1970, rule.m, 1)
      local day = 1 + (rule.d - (first + 4) % 7) % 7 + 7 * (rule.w - 1)
      while day > date.days_in_month(1970, rule.m) do
        day = day - 7
      end
      local t = rule.time
      vim.list_extend(out, {
        "BEGIN:" .. kind,
        fmt("DTSTART:1970%02d%02dT%02d%02d%02d", rule.m, day, floor(t / 3600), floor(t % 3600 / 60), t % 60),
        "TZOFFSETFROM:" .. offset(from),
        "TZOFFSETTO:" .. offset(to),
        fmt("RRULE:FREQ=YEARLY;BYMONTH=%d;BYDAY=%s%s", rule.m, rule.w == 5 and "-1" or tostring(rule.w), DAYS[rule.d]),
        "END:" .. kind,
      })
      return true
    end
    if not (observance("DAYLIGHT", f.start, f.std, f.dst) and observance("STANDARD", f.stop, f.dst, f.std)) then
      return nil
    end
  end
  out[#out + 1] = "END:VTIMEZONE"
  return out
end

---@class org.caldav.ZoneForm
---@field floating? boolean
---@field tzid? string the TZID to write
---@field zone? string the zone of the system database it is
---@field add? boolean the resource needs its VTIMEZONE

--- How a date-time is written: in the zone the property had (so the event
--- stays in the zone it was made in), as a floating time when it was one,
--- else in UTC. A new repeating time is written in the display zone when
--- its name is known, since a UTC time would drift at a clock change.
---@param orig string|nil the property line as the server has it
---@param repeating boolean
---@param o org.caldav.Context
---@return org.caldav.ZoneForm
local function zone_form(orig, repeating, o)
  if orig then
    local _, params, value = parser.content_line(orig)
    local t = parser.time(value, params)
    if t and not t.all_day and params.VALUE ~= "DATE" then
      if t.tzid then
        local zone = iana(t.tzid, o.tz_aliases)
        if zone then
          return { tzid = t.tzid, zone = zone }
        end
      elseif not t.utc then
        return { floating = true }
      end
    end
  end
  if repeating and o.zone_name then
    -- (a zone without clock changes never drifts from UTC)
    local z = require("org.extensions.ics.tzif").load(o.zone_name)
    if z and z.footer and z.footer.dst and M.vtimezone(o.zone_name) then
      return { tzid = o.zone_name, zone = o.zone_name, add = true }
    end
  end
  return {}
end

--- `;TZID=...:value` or `:value` of wall time `naive` (display zone).
---@param naive number
---@param form org.caldav.ZoneForm
---@param o org.caldav.Context
---@return string
local function stamp(naive, form, o)
  if form.floating then
    return ":" .. dt(naive)
  end
  local epoch = M.epoch(naive, o)
  if form.zone and form.tzid then
    local id = form.tzid:find("[:;,]") and ('"' .. form.tzid .. '"') or form.tzid
    return ";TZID=" .. id .. ":" .. dt(parser.wall(epoch, form.zone))
  end
  return ":" .. M.utc(epoch)
end

---@param d org.Date
---@return number naive of its start
local function start_naive(d)
  return d:days() * 86400 + (d.hour or 0) * 3600 + (d.min or 0) * 60
end

---@param r org.DateRepeater|nil
---@return string|nil
local function rrule_line(r)
  local freq = r and FREQ[r.unit]
  if not r or not freq then
    return nil
  end
  return "RRULE:FREQ=" .. freq .. (r.value > 1 and (";INTERVAL=" .. r.value) or "")
end

--- One property line of a point in time (DTSTART or DUE of a task).
---@param name string
---@param d org.Date
---@param orig string|nil
---@param o org.caldav.Context
---@return string line, string|nil zone a TZID whose VTIMEZONE is needed
local function point_line(name, d, orig, o)
  if not d.hour then
    return name .. ";VALUE=DATE:" .. d8(start_naive(d)), nil
  end
  local form = zone_form(orig, d.repeater ~= nil, o)
  return name .. stamp(start_naive(d), form, o), form.add and form.tzid or nil
end

--- The main component of unfolded lines: the first VEVENT or VTODO that
--- isn't a changed instance. Its BEGIN and END line numbers.
---@param lines string[]
---@return integer|nil b, integer|nil e
local function locate(lines)
  local depth = 0
  local found, cur = {}, nil
  for i, line in ipairs(lines) do
    local up = line:upper()
    if up:match("^BEGIN:") then
      depth = depth + 1
      if depth == 2 and (up:match("^BEGIN:VEVENT%s*$") or up:match("^BEGIN:VTODO%s*$")) then
        cur = { b = i }
      end
    elseif up:match("^END:") then
      if depth == 2 and cur then
        cur.e = i
        found[#found + 1] = cur
        cur = nil
      end
      depth = depth - 1
    elseif cur and depth == 2 and up:match("^RECURRENCE%-ID[;:]") then
      cur.rid = true
    end
  end
  for _, c in ipairs(found) do
    if not c.rid then
      return c.b, c.e
    end
  end
  if found[1] then
    return found[1].b, found[1].e
  end
  return nil, nil
end

---@class org.caldav.Line
---@field name? string the property's name
---@field line? string
---@field block? string[] the lines of a component inside (an alarm)

--- Set property `name` of a component to one line, or remove it (nil).
---@param items org.caldav.Line[]
---@param name string
---@param line string|nil
local function set(items, name, line)
  local at
  for i = #items, 1, -1 do
    if items[i].name == name then
      table.remove(items, i)
      at = i
    end
  end
  if not line then
    return
  end
  if not at then
    at = #items + 1
    for i, it in ipairs(items) do
      if it.block then
        at = i
        break
      end
    end
  end
  table.insert(items, at, { name = name, line = line })
end

---@param items org.caldav.Line[]
---@param name string
---@return string|nil
local function get(items, name)
  for _, it in ipairs(items) do
    if it.name == name then
      return it.line
    end
  end
  return nil
end

--- Fold a content line at 75 octets, between characters.
---@param line string
---@return string
local function fold(line)
  if #line <= 75 then
    return line
  end
  local out, pos, limit = {}, 1, 75
  while pos <= #line do
    local stop = math.min(pos + limit - 1, #line)
    while stop < #line and stop > pos do
      local b = line:byte(stop + 1)
      if b >= 0x80 and b < 0xC0 then
        stop = stop - 1
      else
        break
      end
    end
    out[#out + 1] = line:sub(pos, stop)
    pos = stop + 1
    limit = 74
  end
  return table.concat(out, "\r\n ")
end

--- The iCalendar text of a resource with the fields named in `changed`
--- set from `fields` (an entry's fields); everything else stays as it is.
---@param text string the resource as the server has it
---@param kind "VEVENT"|"VTODO"
---@param fields table<string, string>
---@param changed table<string, boolean>
---@param o org.caldav.Context
---@return string|nil ics, string|nil err
function M.patch(text, kind, fields, changed, o)
  local lines = parser.unfold(text)
  local b, e = locate(lines)
  if not b or not e then
    return nil, "no event or task in it"
  end
  ---@type org.caldav.Line[]
  local items = {}
  local depth, block = 0, nil
  for i = b + 1, e - 1 do
    local line = lines[i]
    local up = line:upper()
    if up:match("^BEGIN:") then
      depth = depth + 1
      if depth == 1 then
        block = {}
        items[#items + 1] = { block = block }
      end
    end
    if depth > 0 and block then
      block[#block + 1] = line
      if up:match("^END:") then
        depth = depth - 1
      end
    else
      items[#items + 1] = { name = (line:match("^([^;:]+)") or ""):upper(), line = line }
    end
  end

  local zones = {}
  if changed.summary then
    set(items, "SUMMARY", "SUMMARY:" .. esc(fields.summary or ""))
  end
  if changed.description then
    local d = fields.description or ""
    set(items, "DESCRIPTION", d ~= "" and ("DESCRIPTION:" .. esc(d)) or nil)
    -- an HTML copy of the old description would be shown instead
    set(items, "X-ALT-DESC", nil)
  end
  if changed.location then
    local l = fields.location or ""
    set(items, "LOCATION", l ~= "" and ("LOCATION:" .. esc(l)) or nil)
  end

  if kind == "VEVENT" and changed.time then
    -- (of several timestamp lines the user wrote, the first is the event's)
    local d = M.key_date((fields.time or ""):match("^[^\n]*"))
    if not d then
      return nil, "no timestamp"
    end
    local start, stop
    if not d.hour then
      local last = d.range_end or d
      start = "DTSTART;VALUE=DATE:" .. d8(start_naive(d))
      stop = "DTEND;VALUE=DATE:" .. d8((last:days() + 1) * 86400)
    else
      local sn = start_naive(d)
      local en
      local r = d.range_end
      if d.end_hour then
        en = d:days() * 86400 + d.end_hour * 3600 + (d.end_min or 0) * 60
      elseif r then
        en = r:days() * 86400 + (r.hour or d.hour) * 3600 + (r.hour and (r.min or 0) or (d.min or 0)) * 60
      end
      local form = zone_form(get(items, "DTSTART"), d.repeater ~= nil, o)
      start = "DTSTART" .. stamp(sn, form, o)
      stop = en and en > sn and ("DTEND" .. stamp(en, form, o)) or nil
      if form.add then
        zones[#zones + 1] = form.tzid
      end
    end
    set(items, "DTSTART", start)
    set(items, "DURATION", nil)
    set(items, "DTEND", stop)
    set(items, "RRULE", rrule_line(d.repeater))
    if get(items, "SEQUENCE") then
      local n = tonumber((get(items, "SEQUENCE") or ""):match(":%s*(%d+)")) or 0
      set(items, "SEQUENCE", "SEQUENCE:" .. (n + 1))
    end
  end

  if kind == "VTODO" then
    local repeater
    for _, pair in ipairs({ { "scheduled", "DTSTART" }, { "deadline", "DUE" } }) do
      local key = fields[pair[1]] or ""
      local d = key ~= "" and M.key_date(key) or nil
      repeater = repeater or (d and d.repeater)
      if changed[pair[1]] then
        if d then
          local line, zone = point_line(pair[2], d, get(items, pair[2]), o)
          set(items, pair[2], line)
          zones[#zones + 1] = zone
        else
          set(items, pair[2], nil)
        end
      end
    end
    if changed.scheduled or changed.deadline then
      set(items, "RRULE", rrule_line(repeater))
      if get(items, "DUE") then
        set(items, "DURATION", nil)
      end
    end
    if changed.status then
      local status = fields.status
      if status == "done" then
        local closed = fields._closed and M.key_date(fields._closed)
        set(items, "STATUS", "STATUS:COMPLETED")
        set(items, "PERCENT-COMPLETE", "PERCENT-COMPLETE:100")
        set(items, "COMPLETED", "COMPLETED:" .. M.utc(closed and M.epoch(start_naive(closed), o) or o.now))
      else
        set(items, "STATUS", status == "cancelled" and "STATUS:CANCELLED" or "STATUS:NEEDS-ACTION")
        set(items, "PERCENT-COMPLETE", nil)
        set(items, "COMPLETED", nil)
      end
    end
    if changed.priority then
      local p = fields.priority or ""
      set(items, "PRIORITY", p ~= "" and ("PRIORITY:" .. p) or nil)
    end
  end

  set(items, "DTSTAMP", "DTSTAMP:" .. M.utc(o.now))
  set(items, "LAST-MODIFIED", "LAST-MODIFIED:" .. M.utc(o.now))

  local out = {}
  for i = 1, b - 1 do
    out[#out + 1] = lines[i]
  end
  local defined = {}
  for _, line in ipairs(lines) do
    local id = line:match("^TZID:(.*)$")
    if id then
      defined[id] = true
    end
  end
  for _, zone in ipairs(zones) do
    local vtz = not defined[zone] and M.vtimezone(zone)
    if vtz then
      defined[zone] = true
      vim.list_extend(out, vtz)
    end
  end
  out[#out + 1] = lines[b]
  for _, it in ipairs(items) do
    if it.block then
      vim.list_extend(out, it.block)
    else
      out[#out + 1] = it.line
    end
  end
  for i = e, #lines do
    out[#out + 1] = lines[i]
  end
  for i, line in ipairs(out) do
    out[i] = fold(line)
  end
  return table.concat(out, "\r\n") .. "\r\n", nil
end

--- The iCalendar text of a new resource for an entry's fields.
---@param kind "VEVENT"|"VTODO"
---@param uid string
---@param fields table<string, string>
---@param o org.caldav.Context
---@return string|nil ics, string|nil err
function M.build(kind, uid, fields, o)
  local text = table.concat({
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//org.nvim//caldav//EN",
    "BEGIN:" .. kind,
    "UID:" .. esc(uid),
    "CREATED:" .. M.utc(o.now),
    "END:" .. kind,
    "END:VCALENDAR",
  }, "\r\n")
  local changed = {}
  for _, f in ipairs(M.FIELDS[kind]) do
    changed[f] = (fields[f] or "") ~= ""
  end
  changed.summary = true
  return M.patch(text, kind, fields, changed, o)
end

return M
