---@mod org.extensions.ics iCalendar subscriptions in the agenda
---
--- Enable with `extensions = { ics = { calendars = { ... } } }` (see
--- `:h org-extensions-ics`). Each calendar is a local `.ics` file (`path`)
--- or an `http(s)://` / `webcal://` link (`url`, e.g. a Google or Outlook
--- secret address) fetched with curl into a cache. Their events show in
--- agenda day and week views, read-only, next to the org entries.

local MOD = "org.extensions.ics"
local parser = require("org.extensions.ics.parser")

local M = {}

M.defaults = {
  --- The calendars: `{ name = "Work", url = "https://..." }` or
  --- `{ name = "Home", path = "~/cal/home.ics" }`, with optional `category`
  --- (default: the name), `tags` (a list), `refresh` (minutes), `face` and
  --- `agenda = false` (import only).
  calendars = {},
  --- Minutes before a subscribed calendar is fetched again.
  refresh = 60,
  --- Fetch stale calendars on setup and every minute after (off: only
  --- `ics_refresh` fetches).
  auto_refresh = true,
  --- Where fetched calendars are kept.
  cache_dir = vim.fn.stdpath("cache") .. "/org/ics",
  --- The fetch program and its arguments; the URL is appended after `-o FILE`.
  curl = { "curl", "-fsSL", "--max-time", "30" },
  --- Zone the agenda shows times in (an IANA name); nil = the system's.
  timezone = nil,
  --- Extra TZID -> IANA zone names, for zones the calendar doesn't define.
  tz_aliases = {},
  --- Append " (location)" to event titles.
  show_location = true,
  --- Title of an event in the agenda: `fun(event, calendar): string`
  --- (nil: the summary and, with `show_location`, the location).
  format = nil,
  --- Highlight group of the event titles.
  face = "OrgAgendaDiary",
  --- File `ics_import` adds headings to (nil: `default_notes_file`).
  import_file = nil,
  --- Days ahead `ics_import` offers events from, outside the agenda.
  import_days = 30,
}

M.actions = {
  ics_refresh = { MOD, "refresh", desc = "Fetch the subscribed iCalendar calendars again" },
  ics_import = { MOD, "import", desc = "Copy a calendar event into an org file as a heading" },
}

local function opts()
  return require("org.extensions").opts("ics") or M.defaults
end

local utils = function()
  return require("org.utils")
end

---------------------------------------------------------------------------
-- Sources and cache
---------------------------------------------------------------------------

--- An `http(s)` URL of a calendar entry (webcal:// is https://), or nil.
local function url_of(c)
  if type(c.url) ~= "string" or c.url == "" then
    return nil
  end
  return (c.url:gsub("^webcals?://", "https://"))
end

--- The local file of a calendar: its `path`, or the cache file of its URL.
function M.file_of(c)
  if c.path then
    return vim.fs.normalize(vim.fn.expand(c.path))
  end
  local url = url_of(c)
  if not url then
    return nil
  end
  local name = (c.name or "calendar"):gsub("[^%w_-]+", "_")
  local dir = vim.fs.normalize(vim.fn.expand(opts().cache_dir))
  return string.format("%s/%s-%s.ics", dir, name, utils().sha256(url):sub(1, 12))
end

local function calendars()
  local out = {}
  for i, c in ipairs(opts().calendars or {}) do
    if type(c) == "table" then
      c.name = c.name or ("calendar" .. i)
      out[#out + 1] = c
    end
  end
  return out
end

-- path -> { mtime, size, cal } of parsed files; path -> error text
local parsed = {}
local parse_errors = {}
-- url -> true while a fetch runs; url -> error text of the last fetch
local fetching = {}
M.fetch_errors = {}
-- url -> os.time() of the last failed fetch; url -> the error last warned
-- about (a failure is retried after the refresh interval, and warned about
-- once until it changes)
local failed_at = {}
local warned = {}

--- Forget the parsed calendars (they are read again when next needed).
function M.clear_cache()
  parsed = {}
  parse_errors = {}
end

--- The parsed calendar of entry `c`, or nil (not fetched yet, unreadable).
---@return org.ics.Calendar|nil
function M.load(c)
  local file = M.file_of(c)
  if not file then
    return nil
  end
  local st = vim.uv.fs_stat(file)
  if not st then
    return nil
  end
  local p = parsed[file]
  if p and p.mtime == st.mtime.sec and p.nsec == st.mtime.nsec and p.size == st.size then
    return p.cal
  end
  local fh = io.open(file, "rb")
  if not fh then
    return nil
  end
  local text = fh:read("*a")
  fh:close()
  local ok, cal = pcall(parser.parse, text)
  if not ok then
    if parse_errors[file] ~= cal then
      utils().warn(string.format("ics: can't read %s: %s", file, tostring(cal)))
    end
    parse_errors[file] = cal
    return nil
  end
  parse_errors[file] = nil
  parsed[file] = { mtime = st.mtime.sec, nsec = st.mtime.nsec, size = st.size, cal = cal }
  return cal
end

--- Fetch `url` into `dest`; calls `cb(err)` (nil on success) on the main
--- loop. Replaceable (tests stub it).
---@param url string
---@param dest string
---@param cb fun(err: string|nil)
function M.fetcher(url, dest, cb)
  local cmd = vim.deepcopy(opts().curl)
  if vim.fn.executable(cmd[1]) == 0 then
    vim.schedule(function()
      cb(cmd[1] .. " not found")
    end)
    return
  end
  vim.list_extend(cmd, { "-o", dest, url })
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      if res.code == 0 then
        cb(nil)
      else
        cb(vim.trim(res.stderr or "") ~= "" and vim.trim(res.stderr) or ("exit code " .. res.code))
      end
    end)
  end)
end

local function redo_agenda()
  local ok, view = pcall(require, "org.agenda.view")
  if ok then
    pcall(view.redo)
  end
end

--- Fetch calendar entry `c` (a URL one) now. `cb(err)` when done.
function M.fetch(c, cb)
  local url = url_of(c)
  if not url then
    if cb then
      cb("no url")
    end
    return
  end
  if fetching[url] then
    if cb then
      cb("already fetching")
    end
    return
  end
  local file = M.file_of(c)
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  local tmp = file .. ".part"
  fetching[url] = true
  M.fetcher(url, tmp, function(err)
    fetching[url] = nil
    if not err then
      local fh = io.open(tmp, "rb")
      local data = fh and fh:read("*a") or ""
      if fh then
        fh:close()
      end
      if not data:sub(1, 4096):find("BEGIN:VCALENDAR", 1, true) then
        err = "not an iCalendar file"
      elseif not data:sub(-4096):find("END:VCALENDAR", 1, true) then
        -- cut off (a dropped connection, a proxy): keep the old copy
        err = "incomplete download (no END:VCALENDAR)"
      end
    end
    if err then
      os.remove(tmp)
      M.fetch_errors[url] = err
      failed_at[url] = os.time()
    else
      failed_at[url] = nil
      os.rename(tmp, file)
      M.fetch_errors[url] = nil
      parsed[file] = nil
    end
    if cb then
      cb(err)
    end
  end)
end

--- Whether entry `c`'s cached copy is missing or older than its refresh.
function M.stale(c)
  if not url_of(c) then
    return false
  end
  local st = vim.uv.fs_stat(M.file_of(c))
  if not st then
    return true
  end
  local minutes = tonumber(c.refresh) or tonumber(opts().refresh) or 60
  return os.time() - st.mtime.sec >= minutes * 60
end

--- Fetch the stale calendars in the background; the agenda is redone
--- when one arrives.
function M.refresh_stale()
  for _, c in ipairs(calendars()) do
    local url = url_of(c)
    local minutes = tonumber(c.refresh) or tonumber(opts().refresh) or 60
    -- a failed fetch is tried again after the refresh interval, not at
    -- every agenda redraw (nor never again)
    local waiting = failed_at[url] and os.time() - failed_at[url] < minutes * 60
    if url and M.stale(c) and not fetching[url] and not waiting then
      M.fetch(c, function(err)
        if err then
          if warned[url] ~= err then
            warned[url] = err
            utils().warn(string.format("ics: fetching %s failed: %s", c.name, err))
          end
        else
          warned[url] = nil
          redo_agenda()
        end
      end)
    end
  end
end

-- the minute timer: never raises (an error would repeat every minute)
local function tick()
  local ok, err = pcall(M.refresh_stale)
  if not ok and warned.__tick ~= tostring(err) then
    warned.__tick = tostring(err)
    pcall(utils().error, "ics: " .. tostring(err))
  end
end
M._tick = tick

--- Names of the configured calendars (`:Org ics_refresh` completion).
function M.calendar_names()
  local out = {}
  for _, c in ipairs(calendars()) do
    out[#out + 1] = c.name
  end
  return out
end

--- `:Org ics_refresh [NAME]`: fetch one calendar, or all of them.
---@param args? string
function M.refresh_command(args)
  local name = vim.trim(args or "")
  if name == "" then
    return M.refresh()
  end
  if not vim.tbl_contains(M.calendar_names(), name) then
    utils().warn("ics: no calendar named " .. name)
    return
  end
  M.refresh(nil, name)
end

--- Action `ics_refresh`: fetch every subscribed calendar now.
---@param done? fun(errors: table<string, string>) called when all finished
---@param only? string only the calendar of that name
function M.refresh(done, only)
  M.clear_cache()
  local pending, errors = 0, {}
  local function finish()
    if pending > 0 then
      return
    end
    redo_agenda()
    local n = vim.tbl_count(errors)
    if n == 0 then
      utils().notify("ics: calendars updated")
    end
    if type(done) == "function" then
      done(errors)
    end
  end
  for _, c in ipairs(calendars()) do
    local url = url_of(c)
    if url and (only == nil or c.name == only) then
      M.fetch_errors[url] = nil
      failed_at[url], warned[url] = nil, nil
      pending = pending + 1
      M.fetch(c, function(err)
        pending = pending - 1
        if err then
          errors[c.name] = err
          utils().warn(string.format("ics: fetching %s failed: %s", c.name, err))
        end
        finish()
      end)
    end
  end
  finish()
end

---------------------------------------------------------------------------
-- Agenda
---------------------------------------------------------------------------

local floor = math.floor

local function title_of(ev, c)
  local o = opts()
  if type(o.format) == "function" then
    local ok, s = pcall(o.format, ev, c)
    if ok and type(s) == "string" then
      return s
    end
  end
  local t = ev.summary ~= "" and ev.summary or "(no title)"
  t = t:gsub("%s*\n%s*", " ")
  if o.show_location and ev.location and vim.trim(ev.location) ~= "" then
    t = t .. " (" .. vim.trim(ev.location:gsub("%s*\n%s*", ", ")) .. ")"
  end
  return t
end

--- Occurrences of every calendar between days `from` and `to`:
--- `{ calendar, event, start, stop, all_day }` (local naive seconds).
function M.occurrences(from, to, agenda_only)
  local o = opts()
  local out = {}
  for _, c in ipairs(calendars()) do
    if not (agenda_only and c.agenda == false) then
      local cal = M.load(c)
      if cal then
        -- expanded once per calendar version, range and zone: redrawing
        -- the agenda (or another view asking for the same days) reuses it
        local key = table.concat({ from, to, o.timezone or "" }, ":")
        cal.occ_cache = cal.occ_cache or { keys = {} }
        local list = cal.occ_cache[key]
        if not list then
          list = parser.occurrences(cal, from, to, { timezone = o.timezone, aliases = o.tz_aliases })
          local keys = cal.occ_cache.keys
          keys[#keys + 1] = key
          cal.occ_cache[key] = list
          if #keys > 8 then
            cal.occ_cache[table.remove(keys, 1)] = nil
          end
        end
        for _, occ in ipairs(list) do
          out[#out + 1] = {
            event = occ.event,
            start = occ.start,
            stop = occ.stop,
            all_day = occ.all_day,
            calendar = c,
          }
        end
      end
    end
  end
  return out
end

--- Agenda items of days [from, to] (the `org.agenda.items.day_sources`
--- entry).
function M.agenda_items(from, to, aopts)
  if aopts and aopts.restrict then
    return {}
  end
  local o = opts()
  if o.auto_refresh then
    M.refresh_stale()
  end
  local items = {}
  local titles = {}
  for _, occ in ipairs(M.occurrences(from, to, true)) do
    local c, ev = occ.calendar, occ.event
    local sd = floor(occ.start / 86400)
    local ed = occ.stop > occ.start and floor((occ.stop - 1) / 86400) or sd
    local n = ed - sd + 1
    titles[ev] = titles[ev] or title_of(ev, c)
    local title = titles[ev]
    local ics = { calendar = c.name, event = ev, start = occ.start, stop = occ.stop, all_day = occ.all_day }
    for d = math.max(sd, from), math.min(ed, to) do
      local i = d - sd + 1
      local item = {
        type = "diary",
        ts_type = "ics",
        title = title,
        raw = title,
        category = c.category or c.name,
        tags = { unpack(c.tags or {}) },
        done = false,
        face = c.face or o.face,
        extra = n > 1 and string.format("(%d/%d): ", i, n) or "",
        day = d,
        ics = ics,
      }
      -- like an org date range: the start time on the first day, the end
      -- time on the last (org-agenda-get-blocks)
      if not occ.all_day then
        if i == 1 then
          item.time = floor((occ.start % 86400) / 60)
          if n == 1 and occ.stop > occ.start then
            item.end_time = floor((occ.stop % 86400) / 60)
          end
        elseif i == n then
          item.time = floor((occ.stop % 86400) / 60)
        end
      end
      items[#items + 1] = item
    end
  end
  return items
end

--- The calendar events of days [from, to] (day numbers, as
--- `org.date:days()`), for other views (sidebar, timeline...): one plain
--- table per occurrence, sorted by start, of the calendars shown in the
--- agenda. Times are wall times in the display zone.
---
--- `{ calendar, category, uid, title, summary, location, description,
--- url, all_day, start, stop, start_day, end_day, start_time, end_time,
--- timestamp }`: `start`/`stop` are seconds since 1970-01-01 of the wall
--- clock (stop exclusive), `start_day`/`end_day` day numbers,
--- `start_time`/`end_time` minutes after midnight (nil for all-day
--- events), `timestamp` the org timestamp `ics_import` would write.
---@param from integer
---@param to integer
---@return table[]
function M.events(from, to)
  local out = {}
  for _, occ in ipairs(M.occurrences(from, to, true)) do
    local c, ev = occ.calendar, occ.event
    local ed = occ.stop > occ.start and floor((occ.stop - 1) / 86400) or floor(occ.start / 86400)
    out[#out + 1] = {
      calendar = c.name,
      category = c.category or c.name,
      uid = ev.uid,
      title = title_of(ev, c),
      summary = ev.summary,
      location = ev.location,
      description = ev.description,
      url = ev.url,
      all_day = occ.all_day,
      start = occ.start,
      stop = occ.stop,
      start_day = floor(occ.start / 86400),
      end_day = ed,
      start_time = not occ.all_day and floor((occ.start % 86400) / 60) or nil,
      end_time = not occ.all_day and floor((occ.stop % 86400) / 60) or nil,
      timestamp = M.timestamp(occ),
    }
  end
  table.sort(out, function(a, b)
    if a.start ~= b.start then
      return a.start < b.start
    end
    return a.title < b.title
  end)
  return out
end

---------------------------------------------------------------------------
-- Import
---------------------------------------------------------------------------

local function stamp(naive, with_time)
  local c = parser.civil(naive)
  local dayname = require("org.date").from_days(floor(naive / 86400)):dayname()
  local s = string.format("%04d-%02d-%02d %s", c.year, c.month, c.day, dayname)
  if with_time then
    s = s .. string.format(" %02d:%02d", c.hour, c.min)
  end
  return s
end

--- The org timestamp of an occurrence (`<2026-10-01 Thu 10:00-11:00>`,
--- or a range for one spanning days).
function M.timestamp(occ)
  if occ.all_day then
    local last = floor((math.max(occ.stop, occ.start + 86400) - 1) / 86400) * 86400
    if last > occ.start then
      return "<" .. stamp(occ.start) .. ">--<" .. stamp(last) .. ">"
    end
    return "<" .. stamp(occ.start) .. ">"
  end
  local sd, ed = floor(occ.start / 86400), floor(occ.stop / 86400)
  if occ.stop <= occ.start then
    return "<" .. stamp(occ.start, true) .. ">"
  end
  if sd == ed then
    local c = parser.civil(occ.stop)
    return "<" .. stamp(occ.start, true) .. string.format("-%02d:%02d", c.hour, c.min) .. ">"
  end
  return "<" .. stamp(occ.start, true) .. ">--<" .. stamp(occ.stop, true) .. ">"
end

--- Lines of the heading an occurrence is imported as.
---@param occ table `{ event, start, stop, all_day, calendar? }`
---@param level? integer
function M.entry_lines(occ, level)
  local ev = occ.event
  local title = (ev.summary ~= "" and ev.summary or "(no title)"):gsub("\n", " ")
  local lines = { string.rep("*", level or 1) .. " " .. title }
  local props = {}
  if ev.location and ev.location ~= "" then
    props[#props + 1] = { "LOCATION", (ev.location:gsub("\n", ", ")) }
  end
  if ev.url and ev.url ~= "" then
    props[#props + 1] = { "URL", ev.url }
  end
  if occ.calendar and occ.calendar.name then
    props[#props + 1] = { "CALENDAR", occ.calendar.name }
  end
  if ev.uid ~= "" then
    props[#props + 1] = { "ICS_UID", ev.uid }
    local rid = M.recurrence_key(occ)
    if rid then
      props[#props + 1] = { "ICS_RECURRENCE_ID", rid }
    end
  end
  if #props > 0 then
    lines[#lines + 1] = ":PROPERTIES:"
    for _, p in ipairs(props) do
      lines[#lines + 1] = ":" .. p[1] .. ": " .. p[2]
    end
    lines[#lines + 1] = ":END:"
  end
  lines[#lines + 1] = M.timestamp(occ)
  if ev.description and vim.trim(ev.description) ~= "" then
    for _, l in ipairs(vim.split(vim.trim(ev.description), "\n", { plain = true })) do
      -- a line starting with stars would become a heading
      lines[#lines + 1] = (l:gsub("^(%*+%s)", ",%1"))
    end
  end
  return lines
end

--- For an occurrence of a recurring event, the `ICS_RECURRENCE_ID` that
--- tells it from the event's other occurrences (its local start,
--- `20261005T100000`); nil for a single event.
function M.recurrence_key(occ)
  local ev = occ.event
  if not (ev.rrule or #(ev.rdates or {}) > 0 or ev.recurrence_id) then
    return nil
  end
  local c = parser.civil(occ.start)
  return string.format("%04d%02d%02dT%02d%02d%02d", c.year, c.month, c.day, c.hour, c.min, c.sec)
end

-- The heading of `lines` imported from occurrence `occ` (same ICS_UID and
-- ICS_RECURRENCE_ID), or nil.
local function imported(lines, occ)
  if (occ.event.uid or "") == "" then
    return nil
  end
  local rid = M.recurrence_key(occ)
  for _, hl in ipairs(require("org.parser").parse(lines).headlines) do
    local p = hl.properties or {}
    if p.ICS_UID == occ.event.uid and p.ICS_RECURRENCE_ID == rid then
      return hl
    end
  end
  return nil
end

--- Append the heading of `occ` to the import file. An event imported
--- before (same `ICS_UID`, and `ICS_RECURRENCE_ID` for one occurrence of a
--- recurring event) is not added again: its timestamp line is updated when
--- the event moved.
---@return string|nil file
function M.import_occurrence(occ)
  local o = opts()
  local file = o.import_file or require("org.config").opts.default_notes_file
  if not file or file == "" then
    utils().error("ics: set extensions.ics.import_file")
    return nil
  end
  file = vim.fn.expand(file)
  local u = utils()
  local buf = u.find_buffer(file) or u.load_buffer(file)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local old = imported(lines, occ)
  if old then
    local stamp = M.timestamp(occ)
    local where = require("org.utils").abbreviate(file) .. ":" .. old.line
    for i = old.line + 1, old.body_end or old.line do
      if lines[i]:match("^%s*<%d%d%d%d%-%d%d%-%d%d[^>]*>[-<>%d%s%a:]*$") then
        if vim.trim(lines[i]) == stamp then
          u.notify(string.format('ics: "%s" is already imported (%s)', occ.event.summary, where))
        else
          local indent = lines[i]:match("^(%s*)")
          vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { indent .. stamp })
          vim.api.nvim_buf_call(buf, function()
            vim.cmd("silent write")
          end)
          u.notify(string.format('ics: updated the time of "%s" (%s)', occ.event.summary, where))
        end
        return file
      end
    end
    u.notify(string.format('ics: "%s" is already imported (%s)', occ.event.summary, where))
    return file
  end
  local add = M.entry_lines(occ)
  if #lines == 1 and lines[1] == "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, add)
  else
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, add)
  end
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent write")
  end)
  u.notify(string.format('ics: added "%s" to %s', occ.event.summary, require("org.utils").abbreviate(file)))
  return file
end

--- Action `ics_import`: on an agenda line of a calendar event, copy that
--- event into `import_file`; elsewhere, pick one of the next
--- `import_days` days' events.
function M.import()
  local ok, view = pcall(require, "org.agenda.view")
  if ok and vim.bo.filetype == "orgagenda" then
    local item = view.item_at_cursor()
    if item and item.ics then
      M.import_occurrence({
        event = item.ics.event,
        start = item.ics.start,
        stop = item.ics.stop,
        all_day = item.ics.all_day,
        calendar = { name = item.ics.calendar },
      })
      return
    end
  end
  local today = require("org.date").today_days()
  local occs = M.occurrences(today, today + (opts().import_days or 30))
  if #occs == 0 then
    utils().warn("ics: no calendar events in the next " .. (opts().import_days or 30) .. " days")
    return
  end
  vim.ui.select(occs, {
    prompt = "Import event",
    format_item = function(occ)
      return string.format("%s  %s  [%s]", M.timestamp(occ), occ.event.summary, occ.calendar.name)
    end,
  }, function(choice)
    if choice then
      M.import_occurrence(choice)
    end
  end)
end

---------------------------------------------------------------------------
-- Extension
---------------------------------------------------------------------------

local timer

local function stop_timer()
  if timer then
    pcall(timer.stop, timer)
    pcall(timer.close, timer)
    timer = nil
  end
end

function M.setup(o)
  require("org.agenda.items").day_sources.ics = M.agenda_items
  M.clear_cache()
  M.fetch_errors = {}
  failed_at, warned = {}, {}
  stop_timer()
  if o.auto_refresh then
    local has_url = false
    for _, c in ipairs(calendars()) do
      has_url = has_url or url_of(c) ~= nil
    end
    if has_url then
      vim.schedule(tick)
      timer = vim.uv.new_timer()
      timer:start(60000, 60000, vim.schedule_wrap(tick))
    end
  end
end

M.commands = {
  ics_refresh = {
    MOD,
    "refresh_command",
    desc = "Fetch the subscribed calendars again: :Org ics_refresh [calendar]",
    complete = function()
      return M.calendar_names()
    end,
  },
}

function M.teardown()
  local items = require("org.agenda.items")
  if items.day_sources.ics == M.agenda_items then
    items.day_sources.ics = nil
  end
  stop_timer()
  M.clear_cache()
end

function M.health(h, o)
  local cals = calendars()
  if #cals == 0 then
    h.warn("ics: no calendars (set extensions.ics.calendars)")
    return
  end
  local needs_curl = false
  for _, c in ipairs(cals) do
    local url = url_of(c)
    needs_curl = needs_curl or url ~= nil
    local file = M.file_of(c)
    if not file then
      h.error(string.format("ics: calendar %s has neither url nor path", c.name))
    else
      local st = vim.uv.fs_stat(file)
      if not st then
        if url then
          h.warn(string.format("ics: %s not fetched yet (%s)", c.name, M.fetch_errors[url] or "run :Org ics_refresh"))
        else
          h.error(string.format("ics: %s: %s not found", c.name, file))
        end
      else
        local cal = M.load(c)
        if cal then
          local age = url and string.format(", fetched %d min ago", floor((os.time() - st.mtime.sec) / 60)) or ""
          h.ok(string.format("ics: %s: %d event(s)%s", c.name, #cal.events, age))
          for _, ev in ipairs(cal.events) do
            if ev.start.tzid then
              parser.zone(cal, ev.start.tzid, o.tz_aliases)
            end
          end
          local bad = vim.tbl_keys(cal.unresolved)
          if #bad > 0 then
            table.sort(bad)
            h.warn(string.format("ics: %s: unknown time zones read as local time: %s", c.name, table.concat(bad, ", ")))
          end
        else
          h.error(string.format("ics: %s: can't parse %s", c.name, file))
        end
        if url and M.fetch_errors[url] then
          h.warn(string.format("ics: %s: last fetch failed: %s", c.name, M.fetch_errors[url]))
        end
      end
    end
  end
  if needs_curl then
    local exe = (o.curl or {})[1] or "curl"
    if vim.fn.executable(exe) == 1 then
      h.ok("ics: " .. exe .. " found")
    else
      h.error("ics: " .. exe .. " not found: subscribed (url) calendars can't be fetched")
    end
  end
  if o.timezone and not parser.system_zone(o.timezone) then
    h.warn("ics: timezone " .. o.timezone .. " is not in the system time zone database")
  end
end

return M
