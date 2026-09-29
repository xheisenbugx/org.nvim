---@mod org.extensions.gcal.sync Fetching, posting and deleting events
---
--- Everything here runs inside an `org.utils.run` coroutine: requests are
--- awaited, and entries are found again after each request (by their
--- entry-id or an extmark) so edits made meanwhile don't send the result to
--- the wrong line. Entries are found by entry-id in the fetch files, the
--- agenda files and loaded org buffers, so a refiled entry keeps syncing.

local date = require("org.date")
local edit = require("org.edit")
local event = require("org.extensions.gcal.event")
local files = require("org.files")
local oauth = require("org.extensions.gcal.oauth")
local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.gcal")

local function gcal()
  return require("org.extensions.gcal")
end

local function names()
  return event.names(gcal().opts())
end

local function prop(hl, name)
  return hl.properties[name:upper()]
end

---------------------------------------------------------------------------
-- Entries
---------------------------------------------------------------------------

local function headline(bufnr, lnum)
  local file = files.get_buffer(bufnr)
  return file:headline_at(lnum), file
end

local function gcal_drawer(hl)
  local want = names().drawer:lower()
  for _, d in ipairs(hl.drawers) do
    if d.name:lower() == want then
      return d
    end
  end
end

--- entry-id -> headline line, for the entries of a buffer.
---@return table<string, integer>
function M.entries(bufnr)
  local key = names().entry_id:upper()
  local out = {}
  for _, hl in ipairs(files.get_buffer(bufnr).headlines) do
    local id = hl.properties[key]
    if id and not out[id] then
      out[id] = hl.line
    end
  end
  return out
end

--- Mark a line so it can be found after edits and awaits. The mark is
--- invalidated when its line is deleted (it would otherwise move onto the
--- next entry).
local function mark(bufnr, lnum)
  return vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, { invalidate = true })
end

--- The line of a mark, or nil when its line was deleted.
local function marked_line(bufnr, id)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, id, { details = true })
  if not pos[1] or (pos[3] and pos[3].invalid) then
    return nil
  end
  return pos[1] + 1
end

local function unmark(bufnr, id)
  local l = marked_line(bufnr, id)
  pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, id)
  return l
end

--- The headline line of a marked entry after an await: where the mark is
--- when a headline still starts there, else the entry with `entry_id` (its
--- headline line may have been replaced), else nil (the entry was deleted).
local function marked_entry(bufnr, id, entry_id)
  local l = marked_line(bufnr, id)
  if l then
    local hl = headline(bufnr, l)
    if hl and hl.line == l then
      return l
    end
  end
  if entry_id and vim.api.nvim_buf_is_valid(bufnr) then
    return M.entries(bufnr)[entry_id]
  end
end

--- Where entries are looked for: fetch files, agenda files and loaded org
--- buffers (org-gcal uses the ID locations of every Org file).
local function candidate_paths()
  local opts = gcal().opts()
  local seen, out = {}, {}
  local function add(p)
    p = p and vim.fs.normalize(utils.expand(p))
    if p and not seen[p] then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  local cals = vim.tbl_keys(opts.fetch_file_alist or {})
  table.sort(cals)
  for _, cal in ipairs(cals) do
    add(opts.fetch_file_alist[cal])
  end
  for _, p in ipairs(files.agenda_file_paths()) do
    add(p)
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "org" then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        add(name)
      end
    end
  end
  return out
end

--- entry-id -> path of the file holding it.
---@return table<string, string>
function M.index()
  local key = names().entry_id:upper()
  local out = {}
  for _, path in ipairs(candidate_paths()) do
    local ok, file = pcall(files.get, path)
    if ok and file then
      for _, hl in ipairs(file.headlines) do
        local id = hl.properties[key]
        if id and not out[id] then
          out[id] = path
        end
      end
    end
  end
  return out
end

--- A run's shared state: the entry index, the buffers changed and the
--- entries already pushed.
local function new_ctx(push)
  return { index = M.index(), touched = {}, push = push, pushed = {}, stats = {} }
end

--- The buffer and line of an entry-id, or nil.
local function locate(ctx, entry_id)
  local path = ctx.index[entry_id]
  if not path then
    return nil
  end
  local bufnr = utils.load_buffer(path)
  local lnum = M.entries(bufnr)[entry_id]
  if not lnum then
    -- moved since the index was built: look everywhere again
    ctx.index = M.index()
    path = ctx.index[entry_id]
    if not path then
      return nil
    end
    bufnr = utils.load_buffer(path)
    lnum = M.entries(bufnr)[entry_id]
  end
  return lnum and bufnr or nil, lnum
end

local function save(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) ~= "" then
    utils.save_buffer_or_warn(bufnr)
  end
end

local function save_all(ctx)
  for b in pairs(ctx.touched) do
    save(b)
  end
end

local function add_stats(stats, key)
  if key then
    stats[key] = (stats[key] or 0) + 1
  end
end

--- Run the after-update hooks (org-gcal-after-update-entry-functions).
local function after_update(bufnr, lnum, calendar_id, ev, mode)
  local opts = gcal().opts()
  if type(opts.after_update_entry) == "function" then
    local ok, err = pcall(opts.after_update_entry, calendar_id, ev, mode, { bufnr = bufnr, lnum = lnum })
    if not ok then
      gcal().notify("after_update_entry failed: " .. tostring(err), vim.log.levels.WARN)
    end
  end
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "OrgGcalEntryUpdated",
    modeline = false,
    data = { calendar_id = calendar_id, event_id = ev.id, mode = mode, bufnr = bufnr, lnum = lnum, event = ev },
  })
end

--- The timestamp text an entry shows now (drawer or SCHEDULED).
local function current_stamp(bufnr, hl)
  if hl.planning.scheduled then
    return hl.planning.scheduled:to_string()
  end
  local d = gcal_drawer(hl)
  if d then
    local lines = vim.api.nvim_buf_get_lines(bufnr, d.start, d["end"] - 1, false)
    for _, l in ipairs(lines) do
      local s = vim.trim(l):match("^(<%d%d%d%d%-.->)$")
      if s then
        return s
      end
    end
  end
end

--- Update the entry at `lnum` from an event: title, managed properties and
--- the `:org-gcal:` drawer (or SCHEDULED, when the entry uses it). Other
--- text of the entry is kept (org-gcal--update-entry).
---@param mode? "newly_fetched"|"update_existing"|"create_from_entry" runs the hooks
---@param managed? string org-gcal-managed value set when the entry has none
function M.write_entry(bufnr, lnum, calendar_id, ev, mode, managed)
  local opts = gcal().opts()
  local n = event.names(opts)
  local hl = headline(bufnr, lnum)
  -- a recurring event's parent keeps its own times (org-gcal)
  local keep = ev.recurrence and current_stamp(bufnr, hl) or nil
  edit.update_headline(bufnr, lnum, { title = event.title(ev, hl.title, opts.cancelled_todo_keyword or nil) })
  for _, p in ipairs(event.properties(opts, calendar_id, ev, hl.properties)) do
    edit.set_property(bufnr, lnum, p.name, p.value)
  end
  hl = headline(bufnr, lnum)
  local m = prop(hl, n.managed)
  if not (m == "org" or m == "gcal") and managed then
    edit.set_property(bufnr, lnum, n.managed, managed)
  end
  -- remove the old drawer, then write it after the property drawer
  hl = headline(bufnr, lnum)
  local d = gcal_drawer(hl)
  if d then
    vim.api.nvim_buf_set_lines(bufnr, d.start - 1, d["end"], false, {})
    hl = headline(bufnr, lnum)
  end
  local body
  local ts = keep or event.timestamp(opts, ev)
  if hl.planning.scheduled and ts then
    if not keep then
      edit.set_planning(bufnr, lnum, "scheduled", date.parse(ts))
      hl = headline(bufnr, lnum)
    end
    body = event.description_lines(event.description(opts, calendar_id, ev))
  else
    body = event.drawer_lines(opts, ev, calendar_id, keep)
  end
  local indent = edit.body_indent(hl.level)
  local lines = { indent .. ":" .. n.drawer .. ":" }
  for _, l in ipairs(body) do
    lines[#lines + 1] = l ~= "" and indent .. l or l
  end
  lines[#lines + 1] = indent .. ":END:"
  local at = edit.meta_end(hl)
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, lines)
  if mode then
    after_update(bufnr, lnum, calendar_id, ev, mode)
  end
end

--- Insert a new entry for an event: at the end of `bufnr`, or as the last
--- child of the entry at `parent` (recurring events, `nested` mode).
---@return integer lnum
local function insert_entry(bufnr, calendar_id, ev, parent)
  local opts = gcal().opts()
  local cur = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local at, level = #cur, 1
  if parent then
    local hl = headline(bufnr, parent)
    at, level = hl.end_line, hl.level + 1
  end
  local stars = string.rep("*", level)
  if #cur == 1 and cur[1] == "" then
    at = 0
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { stars .. " busy" })
  else
    vim.api.nvim_buf_set_lines(bufnr, at, at, false, { stars .. " busy" })
  end
  M.write_entry(bufnr, at + 1, calendar_id, ev, "newly_fetched", opts.managed_newly_fetched_mode)
  return at + 1
end

local function todo_names(bufnr)
  local ok, list = pcall(function()
    return files.get_buffer(bufnr).settings.todo:names()
  end)
  return ok and list or {}
end

--- Handle a cancelled event's entry (org-gcal--handle-cancelled-entry):
--- mark it with the cancelled keyword, then maybe remove it. Returns a
--- stats key.
local function cancel_entry(bufnr, lnum)
  local opts = gcal().opts()
  local hl = headline(bufnr, lnum)
  local kw = opts.cancelled_todo_keyword
  local already = kw and hl.todo == kw
  local key = "cancelled"
  if not already and kw and opts.update_cancelled_events_with_todo ~= false then
    if vim.tbl_contains(todo_names(bufnr), kw) then
      edit.update_headline(bufnr, lnum, { todo = kw })
    end
  end
  if opts.remove_events_with_cancelled_todo or not already then
    local remove = opts.remove_api_cancelled_events
    if remove == "ask" then
      remove = utils.confirm(string.format("Delete the entry of cancelled event %q?", hl.title))
    end
    if remove then
      hl = headline(bufnr, lnum)
      vim.api.nvim_buf_set_lines(bufnr, hl.line - 1, hl.end_line, false, {})
      key = "removed"
    end
  end
  return key
end

--- Effort of the entry in minutes (for a default event length).
local function effort_minutes(hl)
  local e = hl.properties[(require("org.config").opts.effort_property or "Effort"):upper()]
  if not e then
    return nil
  end
  local ok, m = pcall(require("org.duration").to_minutes, e)
  return ok and tonumber(m) or nil
end

--- The event data of the entry at `lnum`.
---@return table|nil entry, string? err
function M.entry(bufnr, lnum)
  local opts = gcal().opts()
  local n = event.names(opts)
  local hl, file = headline(bufnr, lnum)
  if not hl then
    return nil, "not on an entry"
  end
  local d = gcal_drawer(hl)
  local ts = hl.planning.scheduled
  local desc = {}
  if d then
    local seen_ts = false
    for i = d.start + 1, d["end"] - 1 do
      local l = file.lines[i]:gsub("^%s+", "")
      -- the timestamp line, possibly a <a>--<b> range
      local stamp = not seen_ts and l:match("^(<%d%d%d%d%-.->)%s*$")
      if stamp then
        seen_ts = true
        ts = ts or date.parse(stamp)
      else
        desc[#desc + 1] = l
      end
    end
  end
  local event_id, cal = event.split_entry_id(prop(hl, n.entry_id))
  local recurrence = hl.properties.RECURRENCE
  if not ts and not (recurrence and event_id) then
    return nil, "the entry has no SCHEDULED or :" .. n.drawer .. ": timestamp"
  end
  local refs = vim.split(vim.trim(hl.properties.ROAM_REFS or ""), "%s+", { trimempty = true })
  local effort = effort_minutes(hl)
  return {
    title = hl.title,
    timestamp = ts,
    description = event.description_text(desc),
    location = hl.properties.LOCATION,
    transparency = hl.properties.TRANSPARENCY,
    link = hl.properties.LINK or refs[1],
    recurrence = recurrence,
    zone = opts.time_zone == "event" and hl.properties.TIMEZONE or nil,
    duration = math.max(opts.default_duration or 0, effort and math.ceil(effort / 5) * 5 or 0),
    event_id = event_id,
    calendar_id = prop(hl, n.calendar_id) or cal,
    etag = prop(hl, n.etag),
    managed = prop(hl, n.managed),
    has_drawer = d ~= nil,
  }
end

--- Calendar for a new event: the fetch file's calendar, or ask.
local function pick_calendar(bufnr)
  local opts = gcal().opts()
  local name = vim.api.nvim_buf_get_name(bufnr)
  local ids = {}
  for cal, file in pairs(opts.fetch_file_alist or {}) do
    ids[#ids + 1] = cal
    if name ~= "" and vim.fs.normalize(utils.expand(file)) == vim.fs.normalize(name) then
      return cal
    end
  end
  table.sort(ids)
  if #ids <= 1 then
    return ids[1]
  end
  return utils.select(ids, { prompt = "Google calendar" })
end

--- Resolve a target: `{ bufnr, lnum }`, or the entry at the cursor of an
--- org buffer or of the agenda.
---@return integer|nil bufnr, integer|nil lnum, boolean from_agenda
local function resolve(target)
  target = target or {}
  local bufnr = target.bufnr
  if (bufnr == nil or bufnr == 0) and not target.lnum and vim.bo.filetype == "orgagenda" then
    local view = require("org.agenda.view")
    local item = view.item_at_cursor()
    if not item then
      return nil, nil, true
    end
    local t = view.resolve_target(item)
    if not t then
      return nil, nil, true
    end
    return t.bufnr, t.lnum, true
  end
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local lnum = target.lnum or vim.api.nvim_win_get_cursor(0)[1]
  local hl = headline(bufnr, lnum)
  return bufnr, hl and hl.line, false
end

--- Rebuild a visible agenda so it shows the changes.
local function refresh_agenda()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "orgagenda" then
      local ok, view = pcall(require, "org.agenda.view")
      if ok then
        pcall(view.redo)
      end
      return
    end
  end
end

---------------------------------------------------------------------------
-- Post and delete
---------------------------------------------------------------------------

--- Replace the entry with the server's version (after a 412, or when an
--- entry managed by Google is not pushed).
local function take_server_version(bufnr, lnum, cal, event_id)
  local id = mark(bufnr, lnum)
  local resp, err = gcal().api({ url = gcal().events_url(cal, event_id) })
  -- the buffer may have changed while waiting
  lnum = marked_entry(bufnr, id, event.entry_id(cal, event_id))
  pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, id)
  if not resp then
    return false, err
  end
  if not lnum then
    return false, "the entry was deleted while it was being updated"
  end
  if (resp.status == 404 or resp.status == 410) or (resp.json and resp.json.status == "cancelled") then
    return true, nil, cancel_entry(bufnr, lnum)
  end
  if resp.status ~= 200 or not resp.json then
    return false, gcal().api_error(resp)
  end
  M.write_entry(bufnr, lnum, cal, resp.json, "update_existing", gcal().opts().managed_update_existing_mode)
  return true, nil, "updated"
end

--- Create or update the event of an entry (org-gcal-post-at-point).
---@param target? { bufnr?: integer, lnum?: integer }
---@param o? { quiet?: boolean, sync?: boolean } `sync`: called by a sync (prompt means never push)
---@return boolean ok, string? err, string? stat
function M.post(target, o)
  o = o or {}
  local opts = gcal().opts()
  local n = event.names(opts)
  local bufnr, lnum, from_agenda = resolve(target)
  if not bufnr or not lnum then
    return false, "not on an entry"
  end
  local entry, err = M.entry(bufnr, lnum)
  if not entry then
    return false, err
  end
  local managed = entry.managed
  if managed ~= "org" and managed ~= "gcal" then
    managed = (entry.calendar_id and entry.event_id) and opts.managed_update_existing_mode
      or opts.managed_create_from_entry_mode
    edit.set_property(bufnr, lnum, n.managed, managed)
    lnum = headline(bufnr, lnum).line
  end
  local cal = entry.calendar_id or pick_calendar(bufnr)
  if not cal then
    return false, "no calendar for this entry: set a calendar-id property or fetch_file_alist"
  end
  if not entry.calendar_id then
    edit.set_property(bufnr, lnum, n.calendar_id, cal)
  end
  -- entries managed by Google are pushed only when asked
  -- (org-gcal-managed-post-at-point-update-existing)
  local push = true
  if managed == "gcal" and entry.event_id then
    local mode = opts.managed_post_at_point_update_existing or "prompt"
    if o.sync and mode == "prompt" then
      mode = "never_push"
    end
    if mode == "never_push" then
      push = false
    elseif mode == "prompt" or mode == "prompt_sync" then
      push = utils.confirm(string.format("Push event to Google Calendar?\n\n%s", entry.title))
    end
  end
  local id = mark(bufnr, lnum)
  local function done(ok, e, stat)
    local l = unmark(bufnr, id)
    save(bufnr)
    if from_agenda then
      refresh_agenda()
    end
    return ok, e, stat, l
  end
  if not push then
    local ok, e, stat = take_server_version(bufnr, lnum, cal, entry.event_id)
    return done(ok, e, stat)
  end
  local body, berr = event.to_event(opts, entry)
  if not body then
    return done(false, berr)
  end
  local req
  if entry.event_id then
    req = {
      method = "PATCH",
      url = gcal().events_url(cal, entry.event_id),
      json = body,
      headers = entry.etag and { ["If-Match"] = entry.etag } or nil,
    }
  else
    req = { method = "POST", url = gcal().events_url(cal), json = body }
  end
  local resp, rerr = gcal().api(req)
  lnum = marked_entry(bufnr, id, entry.event_id and event.entry_id(cal, entry.event_id))
  if not resp then
    return done(false, rerr)
  end
  if not lnum then
    return done(false, "the entry was deleted while posting")
  end
  if resp.status == 412 and entry.event_id then
    local ok, e = take_server_version(bufnr, lnum, cal, entry.event_id)
    if ok then
      -- even in a sync: the entry's local changes are lost (org-gcal)
      gcal().notify(
        string.format(
          "%s: the event changed on Google Calendar: the entry was updated from it, local changes were not sent",
          entry.title
        ),
        vim.log.levels.WARN
      )
    end
    return done(ok, e, "updated")
  end
  if resp.status ~= 200 or not resp.json then
    return done(false, gcal().api_error(resp))
  end
  M.write_entry(
    bufnr,
    lnum,
    cal,
    resp.json,
    entry.event_id and "update_existing" or "create_from_entry",
    entry.event_id and opts.managed_update_existing_mode or opts.managed_create_from_entry_mode
  )
  if opts.notify and not o.quiet then
    gcal().notify((entry.event_id and "updated " or "created ") .. event.title(resp.json))
  end
  return done(true, nil, "pushed")
end

--- Delete the event of the entry at `target` (org-gcal-delete-at-point):
--- the `:org-gcal:` drawer and the calendar and entry ids are removed, then
--- the entry is handled like a cancelled event (marked, maybe removed).
---@param target? { bufnr?: integer, lnum?: integer }
---@param force? boolean clear the entry's calendar data even when the delete fails
---@return boolean ok, string? err
function M.delete(target, force)
  local opts = gcal().opts()
  local n = event.names(opts)
  local bufnr, lnum, from_agenda = resolve(target)
  if not bufnr or not lnum then
    return false, "not on an entry"
  end
  local hl = headline(bufnr, lnum)
  local event_id, cal = event.split_entry_id(prop(hl, n.entry_id))
  cal = prop(hl, n.calendar_id) or cal
  if not event_id or not cal then
    return false, "the entry has no Google Calendar event"
  end
  if not utils.confirm(string.format("Delete %q from Google Calendar?", hl.title)) then
    return true
  end
  local etag = prop(hl, n.etag)
  local id = mark(bufnr, lnum)
  local resp, err = gcal().api({
    method = "DELETE",
    url = gcal().events_url(cal, event_id),
    headers = etag and { ["If-Match"] = etag } or nil,
  })
  lnum = marked_entry(bufnr, id, prop(hl, n.entry_id))
  pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, id)
  local failed
  if not resp then
    failed = err
  elseif resp.status == 412 and lnum and not force then
    local ok, e = take_server_version(bufnr, lnum, cal, event_id)
    save(bufnr)
    if not ok then
      return false, e
    end
    gcal().notify("the event changed on Google Calendar and was not deleted: the entry was updated from it")
    return true
  elseif resp.status ~= 204 and resp.status ~= 200 and resp.status ~= 404 and resp.status ~= 410 then
    failed = gcal().api_error(resp)
  end
  if failed and not force then
    return false, failed
  end
  if lnum then
    hl = headline(bufnr, lnum)
    local d = gcal_drawer(hl)
    if d then
      vim.api.nvim_buf_set_lines(bufnr, d.start - 1, d["end"], false, {})
    end
    edit.set_property(bufnr, lnum, n.calendar_id, nil)
    edit.set_property(bufnr, lnum, n.entry_id, nil)
    cancel_entry(bufnr, headline(bufnr, lnum).line)
    save(bufnr)
  end
  if from_agenda then
    refresh_agenda()
  end
  if failed then
    return false, failed
  end
  if opts.notify then
    gcal().notify("deleted " .. hl.title)
  end
  return true
end

---------------------------------------------------------------------------
-- Fetch
---------------------------------------------------------------------------

--- Today as a day number, by `gcal.now()` in local time.
local function today()
  local opts = gcal().opts()
  local c = event.epoch_to_local(opts, gcal().now())
  return date.days_from_civil(c.year, c.month, c.day)
end

--- The fetch window as UNIX times { from, to }.
function M.window()
  local opts = gcal().opts()
  local now = gcal().now()
  local c = event.epoch_to_local(opts, now)
  local midnight = event.local_to_epoch(opts, { year = c.year, month = c.month, day = c.day })
  return midnight - opts.up_days * 86400, midnight + (opts.down_days + 1) * 86400
end

local function in_window(ev, from, to)
  local s, e = event.bounds(ev)
  if not s then
    return true
  end
  if ev.start and ev.start.date then
    -- all-day events: compare days
    local d1, d2 = math.floor(s / 86400), math.floor((e or s) / 86400)
    local opts = gcal().opts()
    local f = event.epoch_to_local(opts, from)
    local t = event.epoch_to_local(opts, to)
    return d2 > date.days_from_civil(f.year, f.month, f.day) and d1 < date.days_from_civil(t.year, t.month, t.day)
  end
  return (e or s) > from and s < to
end

--- Whether an entry's timestamp falls in the fetch window.
local function entry_in_window(bufnr, lnum)
  local ok, entry = pcall(M.entry, bufnr, lnum)
  if not ok or not entry or not entry.timestamp then
    return false
  end
  local opts = gcal().opts()
  local ts = entry.timestamp
  local last = ts.range_end or ts
  local t = today()
  return last:days() >= t - opts.up_days and ts:days() <= t + opts.down_days
end

local function iso(t)
  return event.format_rfc3339(gcal().opts(), t)
end

local function list_pages(url, query)
  local items, zone = {}, nil
  while true do
    local resp, err = gcal().api({ url = url, query = query })
    if not resp then
      return nil, err
    end
    if resp.status == 410 then
      return nil, "gone", 410
    end
    if resp.status ~= 200 or not resp.json then
      return nil, gcal().api_error(resp)
    end
    zone = zone or resp.json.timeZone
    vim.list_extend(items, resp.json.items or {})
    if resp.json.nextPageToken then
      query = vim.tbl_extend("force", query, { pageToken = resp.json.nextPageToken })
    else
      return items, resp.json.nextSyncToken, nil, zone
    end
  end
end

--- All changed events of a calendar: incremental with the stored sync
--- token, or a full fetch of the window when there is none, it expired
--- (`sync_token_ttl` after the last full fetch) or the server answers 410.
---@return table[]|nil events, string? err, { full: boolean, token?: string, zone?: string }? info
function M.list_events(calendar_id)
  local opts = gcal().opts()
  local now = gcal().now()
  local state = oauth.load(opts)
  local st = state.sync_tokens[calendar_id]
  local full = not (type(st) == "table" and st.token and (tonumber(st.expires) or 0) > now)
  local from, to = M.window()
  local url = gcal().events_url(calendar_id)
  for _ = 1, 2 do
    local query = { singleEvents = "true", maxResults = "2500" }
    if full then
      query.timeMin, query.timeMax, query.showDeleted = iso(from), iso(to), "true"
    else
      query.syncToken = st.token
    end
    local items, token_or_err, code, zone = list_pages(url, query)
    if items then
      for _, ev in ipairs(items) do
        ev._calendar_zone = zone
      end
      return items, nil, { full = full, token = token_or_err, zone = zone }
    end
    if code ~= 410 or full then
      return nil, token_or_err
    end
    -- the sync token is no longer valid: forget it and fetch everything
    state.sync_tokens[calendar_id] = nil
    oauth.save(opts, state)
    full = true
  end
  return nil, "sync failed"
end

--- Archive entries of events that ended before the fetch window
--- (org-gcal--archive-old-event).
local function archive_old(bufnr)
  local opts = gcal().opts()
  local limit = today() - opts.up_days
  local key = event.names(opts).managed:upper()
  local old = {}
  for _, hl in ipairs(files.get_buffer(bufnr).headlines) do
    if hl.properties[key] and not hl.properties.ARCHIVE_TIME then
      local ts = hl.planning.scheduled or (hl.timestamps[1] and hl.timestamps[1].date)
      local last = ts and (ts.range_end or ts)
      if last and last:days() < limit then
        old[#old + 1] = mark(bufnr, hl.line)
      end
    end
  end
  local count = 0
  for i = #old, 1, -1 do
    local lnum = unmark(bufnr, old[i])
    if lnum and pcall(require("org.archive").archive_subtree, { bufnr = bufnr, lnum = lnum }) then
      count = count + 1
    end
  end
  return count
end

local function passes_filters(ev)
  for _, f in ipairs(gcal().opts().fetch_event_filters or {}) do
    local ok, keep = pcall(f, ev)
    if ok and not keep then
      return false
    end
  end
  return true
end

--- Whether the parent entry of a recurring instance has an org repeater,
--- which then stands for the instances (an event created from `+1w`).
local function parent_repeats(ctx, calendar_id, ev)
  if not ev.recurringEventId then
    return false
  end
  local bufnr, lnum = locate(ctx, event.entry_id(calendar_id, ev.recurringEventId))
  if not bufnr then
    return false
  end
  local ok, entry = pcall(M.entry, bufnr, lnum)
  return ok and entry and entry.timestamp and entry.timestamp.repeater and entry.timestamp.repeater.value > 0
end

--- Apply one fetched event: update its entry (or push it, when syncing an
--- entry managed by org), or insert a new one. Returns a stats key.
---@param parent? { bufnr: integer, lnum: integer } insert under this entry
function M.apply(ctx, calendar_id, path, ev, parent)
  local opts = gcal().opts()
  local entry_id = event.entry_id(calendar_id, ev)
  local bufnr, lnum = locate(ctx, entry_id)
  if bufnr then
    ctx.touched[bufnr] = true
    if ev.status == "cancelled" then
      if ev.start then
        M.write_entry(bufnr, lnum, calendar_id, ev, "update_existing", opts.managed_update_existing_mode)
        lnum = M.entries(bufnr)[entry_id] or lnum
      end
      return cancel_entry(bufnr, lnum)
    end
    local hl = headline(bufnr, lnum)
    if ctx.push and prop(hl, names().managed) == "org" and not ctx.pushed[entry_id] then
      ctx.pushed[entry_id] = true
      local ok, err, stat = M.post({ bufnr = bufnr, lnum = lnum }, { quiet = true, sync = true })
      if not ok then
        gcal().notify(err or "post failed", vim.log.levels.WARN)
        return "failed"
      end
      return stat or "pushed"
    end
    M.write_entry(bufnr, lnum, calendar_id, ev, "update_existing", opts.managed_update_existing_mode)
    return "updated"
  end
  if ev.status == "cancelled" or not passes_filters(ev) then
    return nil
  end
  -- incremental syncs report changes anywhere in time
  local from, to = M.window()
  if not in_window(ev, from, to) then
    return nil
  end
  if not parent and parent_repeats(ctx, calendar_id, ev) then
    return nil
  end
  local target = parent and parent.bufnr or utils.load_buffer(path)
  ctx.touched[target] = true
  local l = insert_entry(target, calendar_id, ev, parent and parent.lnum)
  ctx.index[entry_id] = vim.fs.normalize(vim.api.nvim_buf_get_name(target))
  return l and "new"
end

--- `nested` mode: the parent event and its instances in the window, the new
--- ones inserted under the parent's entry.
local function sync_recurring(ctx, calendar_id, path, parent_id, seen)
  local opts = gcal().opts()
  local resp, err = gcal().api({ url = gcal().events_url(calendar_id, parent_id) })
  if not resp then
    return false, err
  end
  if resp.status ~= 200 or not resp.json then
    return true
  end
  local parent_ev = resp.json
  local pid = event.entry_id(calendar_id, parent_ev)
  seen[pid] = true
  local bufnr, lnum = locate(ctx, pid)
  if bufnr then
    ctx.touched[bufnr] = true
    if parent_ev.status == "cancelled" then
      add_stats(ctx.stats, cancel_entry(bufnr, lnum))
      return true
    end
    M.write_entry(bufnr, lnum, calendar_id, parent_ev, "update_existing", opts.managed_update_existing_mode)
    add_stats(ctx.stats, "updated")
  elseif parent_ev.status ~= "cancelled" then
    bufnr = utils.load_buffer(path)
    ctx.touched[bufnr] = true
    insert_entry(bufnr, calendar_id, parent_ev)
    ctx.index[pid] = vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))
    add_stats(ctx.stats, "new")
  else
    return true
  end
  local from, to = M.window()
  local items, ierr = list_pages(
    gcal().events_url(calendar_id, parent_id) .. "/instances",
    { timeMin = iso(from), timeMax = iso(to), maxResults = "2500" }
  )
  if not items then
    return false, ierr
  end
  for _, inst in ipairs(items) do
    seen[event.entry_id(calendar_id, inst)] = true
    local pb, pl = locate(ctx, pid)
    add_stats(ctx.stats, M.apply(ctx, calendar_id, path, inst, pb and { bufnr = pb, lnum = pl } or nil))
  end
  return true
end

--- After a full fetch: entries in the window whose events were not listed
--- were deleted (or moved) while no sync token was kept. Ask for each one.
local function check_missing(ctx, calendar_id, seen)
  local key = names().entry_id:upper()
  local checks = {}
  for entry_id, path in pairs(ctx.index) do
    local ev_id, cal = event.split_entry_id(entry_id)
    if cal == calendar_id and not seen[entry_id] then
      local bufnr = utils.load_buffer(path)
      local lnum = M.entries(bufnr)[entry_id]
      local hl = lnum and headline(bufnr, lnum)
      if hl and hl.properties[key] and not hl.properties.RECURRENCE and entry_in_window(bufnr, lnum) then
        checks[#checks + 1] = { id = entry_id, ev_id = ev_id }
      end
    end
  end
  table.sort(checks, function(a, b)
    return a.id < b.id
  end)
  for _, c in ipairs(checks) do
    local resp, err = gcal().api({ url = gcal().events_url(calendar_id, c.ev_id) })
    if not resp then
      return false, err
    end
    local bufnr, lnum = locate(ctx, c.id)
    if bufnr then
      ctx.touched[bufnr] = true
      if resp.status == 404 or resp.status == 410 or (resp.json and resp.json.status == "cancelled") then
        add_stats(ctx.stats, cancel_entry(bufnr, lnum))
      elseif resp.status == 200 and resp.json then
        local mode = gcal().opts().managed_update_existing_mode
        M.write_entry(bufnr, lnum, calendar_id, resp.json, "update_existing", mode)
        add_stats(ctx.stats, "updated")
      end
    end
  end
  return true
end

--- Fetch one calendar into its file.
function M.fetch_calendar(ctx, calendar_id, path)
  local opts = gcal().opts()
  path = utils.expand(path)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  if opts.auto_archive and utils.exists(path) then
    local b = utils.load_buffer(path)
    local n = archive_old(b)
    if n > 0 then
      ctx.touched[b] = true
      ctx.stats.archived = (ctx.stats.archived or 0) + n
      ctx.index = M.index()
    end
  end
  local items, err, info = M.list_events(calendar_id)
  if not items then
    return false, err
  end
  local seen, parents, order = {}, {}, {}
  local nested = opts.recurring_events_mode == "nested"
  for _, ev in ipairs(items) do
    local entry_id = event.entry_id(calendar_id, ev)
    seen[entry_id] = true
    if nested and ev.recurringEventId and not locate(ctx, entry_id) then
      -- inserted under its parent below
      if not parents[ev.recurringEventId] then
        parents[ev.recurringEventId] = true
        order[#order + 1] = ev.recurringEventId
      end
    else
      add_stats(ctx.stats, M.apply(ctx, calendar_id, path, ev))
    end
  end
  for _, pid in ipairs(order) do
    local ok, e = sync_recurring(ctx, calendar_id, path, pid, seen)
    if not ok then
      return false, e
    end
  end
  if info.full then
    local ok, e = check_missing(ctx, calendar_id, seen)
    if not ok then
      return false, e
    end
  end
  if info.token then
    local state = oauth.load(opts)
    local old = state.sync_tokens[calendar_id]
    -- keep the expiry of the last full fetch, so the window follows today
    local expires = (not info.full and type(old) == "table" and old.expires)
      or (gcal().now() + (opts.sync_token_ttl or 86400))
    state.sync_tokens[calendar_id] = { token = info.token, expires = expires }
    oauth.save(opts, state)
  end
  return true
end

--- Push every entry managed by org in the window that the fetch didn't
--- already push (org-gcal-sync's second pass).
local function push_managed(ctx)
  local key = names().managed:upper()
  local todo = {}
  for entry_id, path in pairs(ctx.index) do
    if not ctx.pushed[entry_id] then
      local bufnr = utils.load_buffer(path)
      local lnum = M.entries(bufnr)[entry_id]
      local hl = lnum and headline(bufnr, lnum)
      if hl and hl.properties[key] == "org" and entry_in_window(bufnr, lnum) then
        todo[#todo + 1] = entry_id
      end
    end
  end
  table.sort(todo)
  for _, entry_id in ipairs(todo) do
    local bufnr, lnum = locate(ctx, entry_id)
    if bufnr then
      ctx.pushed[entry_id] = true
      ctx.touched[bufnr] = true
      local ok, err, stat = M.post({ bufnr = bufnr, lnum = lnum }, { quiet = true, sync = true })
      if ok then
        add_stats(ctx.stats, stat or "pushed")
      else
        gcal().notify(err or "post failed", vim.log.levels.WARN)
        add_stats(ctx.stats, "failed")
      end
    end
  end
end

local function summary(stats)
  local parts = {}
  for _, k in ipairs({ "new", "updated", "pushed", "cancelled", "removed", "archived", "failed" }) do
    if (stats[k] or 0) > 0 then
      parts[#parts + 1] = string.format("%d %s", stats[k], k)
    end
  end
  return #parts > 0 and table.concat(parts, ", ") or "no changes"
end

local busy = false

local function exclusive(fn)
  if busy then
    return false, "a sync is already running"
  end
  busy = true
  local res = { pcall(fn) }
  busy = false
  if not res[1] then
    return false, oauth.redact(res[2])
  end
  return unpack(res, 2)
end

local function finished(kind, stats)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "OrgGcalSyncDone",
    modeline = false,
    data = { kind = kind, stats = stats },
  })
  refresh_agenda()
end

--- Fetch (and with `push`, sync) every calendar of `fetch_file_alist`.
---@param o { push: boolean }
---@return boolean ok, string? err
function M.run(o)
  return exclusive(function()
    local opts = gcal().opts()
    local cals = vim.tbl_keys(opts.fetch_file_alist or {})
    if #cals == 0 then
      return false, "fetch_file_alist is empty (see :h org-extensions-gcal)"
    end
    table.sort(cals)
    local ctx = new_ctx(o.push)
    for _, cal in ipairs(cals) do
      local ok, err = M.fetch_calendar(ctx, cal, opts.fetch_file_alist[cal])
      if not ok then
        save_all(ctx)
        return false, string.format("%s: %s", cal, err)
      end
    end
    if o.push then
      push_managed(ctx)
    end
    save_all(ctx)
    if opts.notify then
      gcal().notify((o.push and "synced: " or "fetched: ") .. summary(ctx.stats))
    end
    finished(o.push and "sync" or "fetch", ctx.stats)
    return true
  end)
end

--- Refresh (and with `push`, sync) every entry of a buffer from its event
--- (org-gcal-fetch-buffer / org-gcal-sync-buffer). When syncing, entries
--- with an `:org-gcal:` drawer but no event yet are created.
---@return boolean ok, string? err
function M.buffer(bufnr, o)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  return exclusive(function()
    local opts = gcal().opts()
    local n = event.names(opts)
    local marks = {}
    for _, hl in ipairs(files.get_buffer(bufnr).headlines) do
      local has_id = prop(hl, n.entry_id) ~= nil
      if has_id or (o.push and gcal_drawer(hl) and prop(hl, n.managed) ~= "gcal") then
        marks[#marks + 1] = mark(bufnr, hl.line)
      end
    end
    local stats = {}
    for _, m in ipairs(marks) do
      local lnum = marked_line(bufnr, m)
      local hl = lnum and headline(bufnr, lnum)
      if hl then
        local event_id, cal = event.split_entry_id(prop(hl, n.entry_id))
        cal = prop(hl, n.calendar_id) or cal
        if o.push and (prop(hl, n.managed) == "org" or not event_id) then
          local ok, err, stat = M.post({ bufnr = bufnr, lnum = lnum }, { quiet = true, sync = true })
          if ok then
            add_stats(stats, stat or "pushed")
          else
            gcal().notify(err or "post failed", vim.log.levels.WARN)
            add_stats(stats, "failed")
          end
        elseif event_id and cal then
          local ok, err, stat = take_server_version(bufnr, lnum, cal, event_id)
          if not ok then
            for _, mm in ipairs(marks) do
              unmark(bufnr, mm)
            end
            save(bufnr)
            return false, err
          end
          add_stats(stats, stat)
        end
      end
      unmark(bufnr, m)
    end
    save(bufnr)
    if opts.notify then
      gcal().notify((o.push and "synced buffer: " or "fetched buffer: ") .. summary(stats))
    end
    finished(o.push and "sync_buffer" or "fetch_buffer", stats)
    return true
  end)
end

return M
