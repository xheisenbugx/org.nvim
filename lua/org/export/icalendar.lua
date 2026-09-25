---@mod org.export.icalendar iCalendar back-end (port of Emacs ox-icalendar.el)
---
--- Headlines and inline tasks become VEVENT components (from SCHEDULED,
--- DEADLINE and plain timestamps) and optionally VTODO components. Like
--- Emacs, the back-end derives from the ASCII back-end, which transcodes
--- entry bodies for the DESCRIPTION field.

local ox = require("org.export.ox")
local element = require("org.export.element")
local utils = require("org.utils")

local M = {}

M.extension = "ics"

local fmt = string.format
local nw = ox.nw
local trim = ox.trim

local function icfg()
  return (require("org.config").opts.export or {}).icalendar or {}
end

--- Option value from config with the Emacs default.
local function opt(name, default)
  local v = icfg()[name]
  if v == nil then
    return default
  end
  return v
end

--- org-icalendar-timezone: config, else $TZ.
local function timezone()
  local tz = icfg().timezone
  if tz == nil then
    tz = vim.env.TZ
  end
  return tz
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- org-icalendar-cleanup-string: protect \ , ; and turn newlines into \n.
function M.cleanup_string(s)
  if s == nil then
    return nil
  end
  s = s:gsub("([\\,;])", "\\%1")
  s = s:gsub("[ \t]*\n", "\\n")
  return s
end

--- org-icalendar-fold-string: lines of at most 75 characters.
function M.fold_string(s)
  local out = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then
      local len = vim.fn.strchars(line)
      if len <= 75 then
        out[#out + 1] = line
      else
        local folded = vim.fn.strcharpart(line, 0, 75)
        local start = 75
        while start + 74 < len do
          folded = folded .. "\n " .. vim.fn.strcharpart(line, start, 74)
          start = start + 74
        end
        out[#out + 1] = folded .. "\n " .. vim.fn.strcharpart(line, start)
      end
    end
  end
  return ox.normalize_string(table.concat(out, "\n"))
end

local function utc_format_p()
  local f = opt("date_time_format", ":%Y%m%dT%H%M%S")
  return f:sub(-1) == "Z"
end

--- org-icalendar-convert-timestamp
function M.convert_timestamp(ts, keyword, is_end, tz)
  local with_time = ts.minute_start ~= nil
  local equal_bounds = ts.year_start == ts.year_end
    and ts.month_start == ts.month_end
    and ts.day_start == ts.day_end
    and ts.hour_start == ts.hour_end
    and ts.minute_start == ts.minute_end
  local duration = icfg().default_appointment_duration
  local mi, h, d, m, y
  if not with_time then
    mi, h = 0, 0
  elseif not is_end then
    mi, h = ts.minute_start, ts.hour_start
  else
    if duration and equal_bounds then
      mi = ts.minute_end + duration
    else
      mi = ts.minute_end
    end
    if not equal_bounds or duration then
      h = ts.hour_end
    else
      h = ts.hour_end + 2
    end
  end
  if not is_end then
    d = ts.day_start
  elseif not with_time then
    d = ts.day_end + 1
  else
    d = ts.day_end
  end
  m = is_end and ts.month_end or ts.month_start
  y = is_end and ts.year_end or ts.year_start
  local t = os.time({ year = y, month = m, day = d, hour = h, min = mi, sec = 0 })
  local f
  if tz == "UTC" then
    f = ":%Y%m%dT%H%M%SZ"
  elseif not with_time then
    f = ";VALUE=DATE:%Y%m%d"
  elseif type(tz) == "string" then
    f = ";TZID=" .. tz .. ":%Y%m%dT%H%M%S"
  else
    f = opt("date_time_format", ":%Y%m%dT%H%M%S"):gsub("%%Z", function()
      return timezone() or ""
    end)
  end
  local universal = tz == "UTC" or (tz == nil and with_time and utc_format_p())
  -- os.date only understands the C directives used here
  return keyword .. os.date((universal and "!" or "") .. f, t)
end

function M.dtstamp()
  return os.date("!DTSTAMP:%Y%m%dT%H%M%SZ")
end

--- A stable identifier for entries without an ID property. Emacs uses a
--- random UUID (org-id-new); here it is derived from the file and the
--- entry so that repeated exports keep the same UID.
local function generated_uid(entry, info)
  local key = (info.input_file or "") .. "\0" .. (entry.raw_value or "") .. "\0" .. tostring(entry.level or 0)
  info.icalendar_uid_count = info.icalendar_uid_count or {}
  local n = (info.icalendar_uid_count[key] or 0) + 1
  info.icalendar_uid_count[key] = n
  local h = vim.fn.sha256(key .. "\0" .. n)
  return fmt("%s-%s-%s-%s-%s", h:sub(1, 8), h:sub(9, 12), h:sub(13, 16), h:sub(17, 20), h:sub(21, 32)):upper()
end

--- org-icalendar-get-categories
local function categories(entry, info)
  local acc = {}
  for _, t in ipairs(info.icalendar_categories or {}) do
    if t == "category" then
      table.insert(acc, 1, ox.get_category(entry, info))
    elseif t == "todo-state" then
      if entry.todo_keyword then
        table.insert(acc, 1, entry.todo_keyword)
      end
    elseif t == "local-tags" or t == "all-tags" then
      local tags = ox.get_tags(entry, info, nil, t == "all-tags")
      -- (append (nreverse tags) categories)
      local rev = {}
      for i = #tags, 1, -1 do
        rev[#rev + 1] = tags[i]
      end
      acc = vim.list_extend(rev, acc)
    end
  end
  local out, seen = {}, {}
  for i = #acc, 1, -1 do
    if not seen[acc[i]] then
      seen[acc[i]] = true
      out[#out + 1] = acc[i]
    end
  end
  return table.concat(out, ",")
end

local function skip_timestamp_p(with, ttype)
  if with == false then
    return true
  elseif with == "active" then
    return not (ttype == "active" or ttype == "active-range" or ttype == "diary")
  elseif with == "active-exclude-diary" then
    return not (ttype == "active" or ttype == "active-range")
  elseif with == "inactive" then
    return not (ttype == "inactive" or ttype == "inactive-range")
  end
  return false
end

local UNITS = { h = "HOURLY", d = "DAILY", w = "WEEKLY", m = "MONTHLY", y = "YEARLY" }

local function rrule(unit, value)
  return fmt("RRULE:FREQ=%s;INTERVAL=%d", UNITS[unit] or "", value)
end

local function repeater_type(ts)
  if not ts or not ts.repeater_type or not ts.repeater_value or ts.repeater_value <= 0 then
    return nil
  end
  if ts.repeater_type ~= "cumulate" then
    utils.warn(fmt("Repeater-type %s not currently supported by iCalendar export", ts.repeater_type))
    return nil
  end
  return ts.repeater_type
end

--- org-icalendar--valarm
local function valarm(entry, ts, summary)
  local warn = entry.props and entry.props.APPT_WARNTIME
  local alarm_time = warn and tonumber(warn) or nil
  local global = opt("alarm_time", 0)
  local force = opt("force_alarm", false)
  if not ((alarm_time and alarm_time > 0) or global > 0 or force) or not ts.hour_start then
    return ""
  end
  local minutes
  if alarm_time and force then
    minutes = alarm_time
  elseif alarm_time and alarm_time ~= 0 then
    minutes = alarm_time
  else
    minutes = global
  end
  return fmt("BEGIN:VALARM\nACTION:DISPLAY\nDESCRIPTION:%s\nTRIGGER:-P0DT0H%dM0S\nEND:VALARM\n", summary, minutes)
end

--- org-icalendar--vevent
local function vevent(entry, ts, uid, summary, location, description, cats, tz, class)
  if ts.ts_type == "diary" then
    -- diary sexps need Emacs' calendar library (org-diary-to-ical-string)
    return ""
  end
  return "BEGIN:VEVENT\n"
    .. M.dtstamp()
    .. "\n"
    .. "UID:"
    .. uid
    .. "\n"
    .. M.convert_timestamp(ts, "DTSTART", nil, tz)
    .. "\n"
    .. M.convert_timestamp(ts, "DTEND", true, tz)
    .. "\n"
    .. (ts.repeater_type and (rrule(ts.repeater_unit, ts.repeater_value) .. "\n") or "")
    .. "SUMMARY:"
    .. summary
    .. "\n"
    .. (nw(location) and fmt("LOCATION:%s\n", location) or "")
    .. (nw(class) and fmt("CLASS:%s\n", class) or "")
    .. (nw(description) and fmt("DESCRIPTION:%s\n", description) or "")
    .. "CATEGORIES:"
    .. cats
    .. "\n"
    .. valarm(entry, ts, summary)
    .. "END:VEVENT\n"
end

--- Warning period of a deadline in days (org-get-wdays).
local function warning_days(ts)
  local v, u = ts.warning_value, ts.warning_unit
  if v then
    local mult = ({ h = 1 / 24, d = 1, w = 7, m = 30.4, y = 365.25 })[u] or 1
    return math.floor(v * mult + 0.5)
  end
  return require("org.config").opts.deadline_warning_days or 14
end

--- A timestamp `days` before `ts` (org-timestamp-down-day).
local function shift_days(ts, days)
  local t = os.time({ year = ts.year_start, month = ts.month_start, day = ts.day_start - days, hour = 12 })
  local d = os.date("*t", t)
  return {
    type = "timestamp",
    ts_type = "active",
    year_start = d.year,
    month_start = d.month,
    day_start = d.day,
    hour_start = ts.hour_start,
    minute_start = ts.minute_start,
    year_end = d.year,
    month_end = d.month,
    day_end = d.day,
    hour_end = ts.hour_start,
    minute_end = ts.minute_start,
  }
end

local function priority_value(p)
  if p == nil then
    return nil
  end
  return tonumber(p) or p:byte()
end

--- org-icalendar--vtodo
local function vtodo(entry, uid, summary, location, description, cats, tz, class, info)
  local use_scheduled = info.icalendar_use_scheduled or {}
  local use_deadline = info.icalendar_use_deadline or {}
  local sc = vim.tbl_contains(use_scheduled, "todo-start") and entry.scheduled or nil
  local dl = vim.tbl_contains(use_deadline, "todo-due") and entry.deadline or nil
  local sc_repeat = repeater_type(sc)
  local dl_repeat = repeater_type(dl)
  local repeat_value = (sc and sc.repeater_value) or (dl and dl.repeater_value)
  local repeat_unit = (sc and sc.repeater_unit) or (dl and dl.repeater_unit)
  local repeat_until = (sc_repeat and not dl_repeat) and dl or nil
  local unscheduled = opt("todo_unscheduled_start", "recurring-deadline-warning")
  local start
  if sc then
    start = sc
  elseif unscheduled == "current-datetime" then
    local now = os.date("*t")
    start = {
      ts_type = "active",
      minute_start = now.min,
      hour_start = now.hour,
      day_start = now.day,
      month_start = now.month,
      year_start = now.year,
    }
    start.minute_end, start.hour_end, start.day_end = start.minute_start, start.hour_start, start.day_start
    start.month_end, start.year_end = start.month_start, start.year_start
  elseif (unscheduled == "deadline-warning" and dl) or (unscheduled == "recurring-deadline-warning" and dl_repeat) then
    start = shift_days(dl, warning_days(dl))
  end
  local s = "BEGIN:VTODO\n" .. "UID:TODO-" .. uid .. "\n" .. M.dtstamp() .. "\n"
  if start then
    s = s .. M.convert_timestamp(start, "DTSTART", nil, tz) .. "\n"
  end
  if dl and not repeat_until then
    s = s .. M.convert_timestamp(dl, "DUE", nil, tz) .. "\n"
  end
  if dl_repeat and not (repeat_value == dl.repeater_value and repeat_unit == dl.repeater_unit) then
    utils.warn("Not yet implemented: different repeaters on SCHEDULED and DEADLINE.  Skipping.")
  elseif dl_repeat and sc and not sc_repeat then
    utils.warn("Not yet implemented: repeater on DEADLINE but not SCHEDULED.  Skipping.")
  elseif sc_repeat or dl_repeat then
    s = s .. rrule(repeat_unit, repeat_value)
    if repeat_until then
      local local_time = not tz and opt("date_time_format", ":%Y%m%dT%H%M%S") == ":%Y%m%dT%H%M%S"
      local t = os.time({
        year = repeat_until.year_start,
        month = repeat_until.month_start,
        day = repeat_until.day_start,
        hour = repeat_until.hour_start or 0,
        min = repeat_until.minute_start or 0,
        sec = 0,
      })
      local u
      if not start.minute_start then
        u = os.date("%Y%m%d", t)
      elseif local_time then
        u = os.date("%Y%m%dT%H%M%S", t)
      else
        u = os.date("!%Y%m%dT%H%M%SZ", t)
      end
      s = s .. ";UNTIL=" .. u
    end
    s = s .. "\n"
  end
  local cfg = require("org.config").opts
  local lowest = priority_value(cfg.priority_lowest or "C")
  local highest = priority_value(cfg.priority_highest or "A")
  local pri = priority_value(entry.priority) or priority_value(cfg.priority_default or "B")
  local priority = math.floor(9 - (8 * ((lowest - pri) / (lowest - highest))))
  return s
    .. "SUMMARY:"
    .. summary
    .. "\n"
    .. (nw(location) and fmt("LOCATION:%s\n", location) or "")
    .. (nw(class) and fmt("CLASS:%s\n", class) or "")
    .. (nw(description) and fmt("DESCRIPTION:%s\n", description) or "")
    .. "CATEGORIES:"
    .. cats
    .. "\n"
    .. "SEQUENCE:1\n"
    .. fmt("PRIORITY:%d\n", priority)
    .. fmt("STATUS:%s\n", entry.todo_type == "todo" and "NEEDS-ACTION" or "COMPLETED")
    .. "END:VTODO\n"
end

--- org-icalendar-blocked-headline-p
local function blocked_p(h, info)
  local child_todo = element.map(h.contents, "headline", function(x)
    if x.todo_type == "todo" then
      return true
    end
  end, { first_match = true, ignore = info.ignore })
  if child_todo then
    return true
  end
  local current = h
  local p = h.parent
  while p and p.type ~= "org-data" do
    if not p.todo_keyword then
      return false
    end
    local ordered = p.props and p.props.ORDERED
    if ordered and ordered ~= "nil" then
      local sib = ox.get_previous_element(current, info)
      while sib do
        if sib.todo_type == "todo" then
          return true
        end
        sib = ox.get_previous_element(sib, info)
      end
    else
      current = p
    end
    p = p.parent
  end
  return false
end

local function include_todo_p(entry, info)
  local inc = info.icalendar_include_todo
  if not entry.todo_type or not inc then
    return false
  end
  if inc == "all" then
    return true
  elseif inc == "unblocked" then
    return entry.type == "headline" and not blocked_p(entry, info)
  elseif inc == true then
    return entry.todo_type == "todo"
  elseif type(inc) == "table" then
    return vim.tbl_contains(inc, entry.todo_keyword)
  end
  return false
end

local function prop(entry, name)
  return entry.props and entry.props[name]
end

--- org-icalendar-entry
local function entry_fn(entry, contents, info)
  if entry.footnote_section_p then
    return nil
  end
  local etype = entry.type
  local inside
  if etype == "inlinetask" then
    inside = entry.contents
  else
    local first = entry.contents[1]
    inside = (first and first.type == "section") and first.contents or {}
  end
  local out = {}
  local todo_type = entry.todo_type
  local uid = prop(entry, "ID") or generated_uid(entry, info)
  local summary = M.cleanup_string(prop(entry, "SUMMARY") or ox.data(entry.title, info))
  local loc = M.cleanup_string(prop(entry, "LOCATION"))
  local class = M.cleanup_string(ox.get_node_property("CLASS", entry, false))
  local desc = prop(entry, "DESCRIPTION")
  if not desc then
    local body = ox.data(inside, info)
    local include = info.icalendar_include_body
    if not nw(body) then
      desc = nil
    elseif type(include) == "number" and include >= 0 then
      body = trim(body)
      desc = vim.fn.strcharpart(body, 0, math.min(vim.fn.strchars(body), include))
    elseif include then
      desc = trim(body)
    end
  end
  desc = M.cleanup_string(desc)
  local cats = categories(entry, info)
  local tz = ox.get_node_property("TIMEZONE", entry, false)
  local function event_p(list)
    if todo_type == "todo" then
      return vim.tbl_contains(list, "event-if-todo-not-done") or vim.tbl_contains(list, "event-if-todo")
    elseif todo_type == "done" then
      return vim.tbl_contains(list, "event-if-todo")
    end
    return vim.tbl_contains(list, "event-if-not-todo")
  end
  if entry.deadline and event_p(info.icalendar_use_deadline or {}) then
    out[#out + 1] = vevent(
      entry,
      entry.deadline,
      "DL-" .. uid,
      (M.cleanup_string(info.icalendar_deadline_summary_prefix) or "") .. summary,
      loc,
      desc,
      cats,
      tz,
      class
    )
  end
  if entry.scheduled and event_p(info.icalendar_use_scheduled or {}) then
    out[#out + 1] = vevent(
      entry,
      entry.scheduled,
      "SC-" .. uid,
      (M.cleanup_string(info.icalendar_scheduled_summary_prefix) or "") .. summary,
      loc,
      desc,
      cats,
      tz,
      class
    )
  end
  local counter = 0
  local scope = { entry.title }
  vim.list_extend(scope, inside)
  local no_rec = etype == "headline" and { inlinetask = true } or nil
  for _, ts in ipairs(element.map(scope, "timestamp", function(x)
    return x
  end, { ignore = info.ignore, no_recursion = no_rec })) do
    if not skip_timestamp_p(info.with_timestamps, ts.ts_type) then
      counter = counter + 1
      out[#out + 1] = vevent(entry, ts, fmt("TS%d-%s", counter, uid), summary, loc, desc, cats, tz, class)
    end
  end
  if include_todo_p(entry, info) then
    out[#out + 1] = vtodo(entry, uid, summary, loc, desc, cats, tz, class, info)
  end
  -- diary sexps (org-icalendar-include-sexps) need Emacs' calendar
  -- library: they are not exported.
  if etype == "headline" then
    for _, task in ipairs(element.map(inside, "inlinetask", function(x)
      return x
    end, { ignore = info.ignore })) do
      out[#out + 1] = entry_fn(task, nil, info) or ""
    end
  end
  out[#out + 1] = contents or ""
  return table.concat(out)
end

--- org-icalendar--vcalendar
function M.vcalendar(name, owner, tz, description, ttl, contents)
  return M.fold_string(
    fmt(
      "BEGIN:VCALENDAR\nVERSION:2.0\nX-WR-CALNAME:%s\nPRODID:-//%s//Emacs with Org mode//EN\nX-WR-TIMEZONE:%s\nX-WR-CALDESC:%s\n",
      M.cleanup_string(name),
      M.cleanup_string(owner),
      M.cleanup_string(tz),
      M.cleanup_string(description)
    )
      .. (ttl and fmt("X-PUBLISHED-TTL:%s\n", M.cleanup_string(ttl)) or "")
      .. "CALSCALE:GREGORIAN\n"
      .. contents
      .. "END:VCALENDAR\n"
  )
end

local function calendar_timezone()
  local tz = timezone()
  if nw(tz) then
    return tz
  end
  return os.date("%Z")
end

local function template(contents, info)
  local name
  if info.input_file then
    name = vim.fn.fnamemodify(info.input_file, ":t:r")
  else
    name = info.icalendar_buffer_name or "*scratch*"
  end
  local owner = info.with_author and ox.data(info.author, info) or ""
  return M.vcalendar(name, owner, calendar_timezone(), ox.data(info.title, info), info.icalendar_ttl, contents)
end

---------------------------------------------------------------------------
-- Back-end
---------------------------------------------------------------------------

local function none()
  return nil
end

local T = {
  clock = none,
  ["footnote-definition"] = none,
  ["footnote-reference"] = none,
  headline = entry_fn,
  inlinetask = none,
  planning = none,
  section = none,
  inner_template = function(contents)
    return contents
  end,
  template = template,
}

local has_ascii = pcall(require, "org.export.ascii")
if not has_ascii then
  -- Fallback while no ASCII back-end is available: plain paragraphs.
  T.paragraph = function(_, contents)
    return ((contents or ""):gsub("\n$", ""):gsub("[ \t]*\n[ \t]*", " "))
  end
  T.timestamp = function(el)
    return ox.timestamp_translate(el)
  end
  T["plain-text"] = function(text)
    return text
  end
end

M.transcoders = T

local function options()
  return {
    { "exclude_tags", "ICALENDAR_EXCLUDE_TAGS", nil, opt("exclude_tags", {}), "split" },
    { "with_timestamps", nil, "<", opt("with_timestamps", "active") },
    { "icalendar_alarm_time", nil, nil, opt("alarm_time", 0) },
    { "icalendar_categories", nil, nil, opt("categories", { "local-tags", "category" }) },
    { "icalendar_date_time_format", nil, nil, opt("date_time_format", ":%Y%m%dT%H%M%S") },
    { "icalendar_include_body", nil, nil, opt("include_body", true) },
    { "icalendar_include_sexps", nil, nil, opt("include_sexps", true) },
    { "icalendar_include_todo", nil, nil, opt("include_todo", false) },
    { "icalendar_store_uid", nil, nil, opt("store_uid", false) },
    { "icalendar_timezone", nil, nil, timezone() },
    { "icalendar_use_deadline", nil, nil, opt("use_deadline", { "event-if-not-todo", "todo-due" }) },
    { "icalendar_use_scheduled", nil, nil, opt("use_scheduled", { "todo-start" }) },
    { "icalendar_scheduled_summary_prefix", nil, nil, opt("scheduled_summary_prefix", "S: ") },
    { "icalendar_deadline_summary_prefix", nil, nil, opt("deadline_summary_prefix", "DL: ") },
    { "icalendar_ttl", "ICAL-TTL", nil, opt("ttl", nil) },
  }
end

M.backend = ox.define_backend("icalendar", {
  parent = has_ascii and "ascii" or nil,
  transcoders = T,
  options = options,
  filters = {
    headline = {
      function(s)
        -- org-icalendar-clear-blank-lines
        local out = {}
        for line in (s:match("\n$") and s or (s .. "\n")):gmatch("(.-)\n") do
          if line:match("%S") then
            out[#out + 1] = line
          end
        end
        return table.concat(out, "\n") .. (#out > 0 and "\n" or "")
      end,
    },
  },
})

-- ASCII options used for descriptions, like org-icalendar-export-to-ics
local EXT = { ascii_charset = "utf-8", ascii_links_to_notes = false }

---------------------------------------------------------------------------
-- Entry points
---------------------------------------------------------------------------

--- Export Org lines to an iCalendar string (LF line endings).
---@param lines string[]
---@param opts? { filename?: string, bufnr?: integer, body_only?: boolean, ext?: table }
---@return string
function M.to_string(lines, opts)
  opts = opts or {}
  local ext = vim.tbl_extend("force", EXT, opts.ext or {})
  return (
    ox.export_as("icalendar", lines, {
      filename = opts.filename,
      bufnr = opts.bufnr,
      body_only = opts.body_only,
      subtree_line = opts.subtree_line,
      visible_only = opts.visible_only,
      ext = ext,
    })
  )
end

--- Write `text` with CRLF line endings (org-icalendar--post-process-file)
--- and run the after-save hook (org-icalendar-after-save-hook).
local function write_ics(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd = assert(io.open(path, "wb"))
  fd:write((text:gsub("\r?\n", "\r\n")))
  fd:close()
  local hook = icfg().after_save_hook
  if type(hook) == "function" then
    pcall(hook, path)
  end
  return path
end
M.write_ics = write_ics

--- Set ID properties on headlines missing one (org-icalendar-create-uid).
local function create_uids(bufnr)
  local ok, id = pcall(require, "org.id")
  if not ok then
    return
  end
  local file = require("org.parser").parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  local lnums = {}
  for _, hl in ipairs(file.headlines) do
    if not hl.properties.ID and not hl.commented then
      lnums[#lnums + 1] = hl.line
    end
  end
  for i = #lnums, 1, -1 do
    pcall(id.get_create, { bufnr = bufnr, lnum = lnums[i] })
  end
end

--- Lines and file name of a buffer or path.
local function source(target)
  if type(target) == "number" or target == nil then
    local bufnr = (target == nil or target == 0) and vim.api.nvim_get_current_buf() or target
    local name = vim.api.nvim_buf_get_name(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), name ~= "" and name or nil, bufnr
  end
  local path = vim.fn.fnamemodify(utils.expand(target), ":p")
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), path, bufnr
  end
  return utils.readfile(path) or {}, path, nil
end

--- Export a buffer (or file) to FILE.ics next to it (org-icalendar-export-to-ics).
---@param target? integer|string buffer number or path (default: current buffer)
---@param opts? { output?: string, subtree_line?: integer, visible_only?: boolean, body_only?: boolean }
---@return string path of the .ics file
function M.export_file(target, opts)
  opts = opts or {}
  local lines, filename, bufnr = source(target)
  if bufnr and filename and opt("store_uid", false) then
    create_uids(bufnr)
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  local text = M.to_string(lines, {
    filename = filename,
    bufnr = bufnr,
    subtree_line = opts.subtree_line,
    visible_only = opts.visible_only,
    body_only = opts.body_only,
  })
  local out = opts.output
  if not out then
    local base = filename and vim.fn.fnamemodify(filename, ":p:r") or (vim.fn.getcwd() .. "/export")
    out = base .. ".ics"
  end
  return write_ics(out, text)
end

local function agenda_paths()
  return require("org.files").agenda_file_paths()
end

--- Export every agenda file to its own .ics file (org-icalendar-export-agenda-files).
---@return string[] written files
function M.export_agenda_files(opts)
  opts = opts or {}
  local out = {}
  for _, path in ipairs(opts.files or agenda_paths()) do
    out[#out + 1] = M.export_file(path)
  end
  return out
end

--- Combine all agenda files into one calendar
--- (org-icalendar-combine-agenda-files), written to
--- `export.icalendar.combined_agenda_file` (default "~/org.ics").
---@return string path
function M.combine_agenda_files(opts)
  opts = opts or {}
  local parts = {}
  for _, path in ipairs(opts.files or agenda_paths()) do
    local lines, filename, bufnr = source(path)
    if bufnr and opt("store_uid", false) then
      create_uids(bufnr)
      lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end
    parts[#parts + 1] = M.to_string(lines, { filename = filename, bufnr = bufnr, body_only = true })
  end
  local text = M.vcalendar(
    opt("combined_name", "OrgMode"),
    ox.user_full_name() or "",
    calendar_timezone(),
    opt("combined_description", ""),
    opt("ttl", nil),
    table.concat(parts)
  )
  local out = opts.output or utils.expand(opt("combined_agenda_file", "~/org.ics"))
  return write_ics(out, text)
end

return M
