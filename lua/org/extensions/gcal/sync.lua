---@mod org.extensions.gcal.sync Fetching, posting and deleting events
---
--- Everything here runs inside an `org.utils.run` coroutine: requests are
--- awaited, and entries are found again by an extmark after each request
--- so edits made meanwhile don't send the result to the wrong line.

local date = require("org.date")
local edit = require("org.edit")
local event = require("org.extensions.gcal.event")
local files = require("org.files")
local oauth = require("org.extensions.gcal.oauth")
local utils = require("org.utils")

local M = {}

--- A full (windowed) sync is redone when the sync token is older than this,
--- so the fetch window follows today.
M.SYNC_TOKEN_TTL = 86400

local ns = vim.api.nvim_create_namespace("org.gcal")

local function gcal()
  return require("org.extensions.gcal")
end

local function bufnr_of(b)
  return (b == nil or b == 0) and vim.api.nvim_get_current_buf() or b
end

---------------------------------------------------------------------------
-- Entries
---------------------------------------------------------------------------

local function headline(bufnr, lnum)
  local file = files.get_buffer(bufnr)
  return file:headline_at(lnum), file
end

local function gcal_drawer(hl)
  for _, d in ipairs(hl.drawers) do
    if d.name:lower() == event.DRAWER then
      return d
    end
  end
end

--- entry-id -> headline line, for the entries of a buffer.
---@return table<string, integer>
function M.entries(bufnr)
  local out = {}
  for _, hl in ipairs(files.get_buffer(bufnr).headlines) do
    local id = hl.properties["ENTRY-ID"]
    if id and not out[id] then
      out[id] = hl.line
    end
  end
  return out
end

--- Mark a line so it can be found after edits and awaits.
local function mark(bufnr, lnum)
  return vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {})
end

local function unmark(bufnr, id)
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, id, {})
  pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, id)
  return pos[1] and pos[1] + 1 or nil
end

local function marked_line(bufnr, id)
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, id, {})
  return pos[1] and pos[1] + 1 or nil
end

--- Update the entry at `lnum` from an event: title, managed properties and
--- the `:org-gcal:` drawer (or SCHEDULED, when the entry uses it). Other
--- text of the entry is kept.
---@param mode string|nil org-gcal-managed value; nil keeps the entry's
function M.write_entry(bufnr, lnum, calendar_id, ev, mode)
  local opts = gcal().opts()
  edit.update_headline(bufnr, lnum, { title = event.title(ev) })
  for _, p in ipairs(event.properties(calendar_id, ev)) do
    edit.set_property(bufnr, lnum, p.name, p.value)
  end
  local hl = headline(bufnr, lnum)
  mode = mode or hl.properties["ORG-GCAL-MANAGED"]
  if mode then
    edit.set_property(bufnr, lnum, "org-gcal-managed", mode)
  end
  hl = headline(bufnr, lnum)
  local ts = event.timestamp(opts, ev)
  local body
  if hl.planning.scheduled and ts then
    edit.set_planning(bufnr, lnum, "scheduled", date.parse(ts))
    hl = headline(bufnr, lnum)
    body = event.description_lines(ev.description)
  else
    body = event.drawer_lines(opts, ev)
  end
  local indent = edit.body_indent(hl.level)
  for i, l in ipairs(body) do
    body[i] = l ~= "" and indent .. l or l
  end
  local d = gcal_drawer(hl)
  if d then
    vim.api.nvim_buf_set_lines(bufnr, d.start, d["end"] - 1, false, body)
  elseif #body > 0 then
    local s = edit.ensure_drawer(bufnr, lnum, "org-gcal")
    vim.api.nvim_buf_set_lines(bufnr, s, s, false, body)
  end
end

--- Lines of a new entry for an event.
function M.entry_lines(calendar_id, ev, mode)
  local opts = gcal().opts()
  local lines = { "* " .. event.title(ev), ":PROPERTIES:" }
  for _, p in ipairs(event.properties(calendar_id, ev)) do
    if p.value then
      lines[#lines + 1] = edit.property_line("", p.name, p.value)
    end
  end
  lines[#lines + 1] = edit.property_line("", "org-gcal-managed", mode)
  lines[#lines + 1] = ":END:"
  lines[#lines + 1] = ":org-gcal:"
  vim.list_extend(lines, event.drawer_lines(opts, ev))
  lines[#lines + 1] = ":END:"
  return lines
end

local function append_entry(bufnr, lines)
  local cur = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #cur == 1 and cur[1] == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  else
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
  end
end

local function delete_entry(bufnr, lnum)
  local hl = headline(bufnr, lnum)
  vim.api.nvim_buf_set_lines(bufnr, hl.line - 1, hl.end_line, false, {})
end

--- Handle a cancelled event's entry. Returns the stats key.
local function cancel_entry(bufnr, lnum)
  local opts = gcal().opts()
  local hl = headline(bufnr, lnum)
  local remove = opts.remove_api_cancelled_events
  if remove == "ask" then
    remove = utils.confirm(string.format("Event %q was cancelled. Remove its entry?", hl.title))
  end
  if remove then
    delete_entry(bufnr, lnum)
    return "removed"
  end
  local kw = opts.cancelled_todo_keyword
  if kw and hl.todo ~= kw then
    edit.update_headline(bufnr, lnum, { todo = kw })
  end
  return "cancelled"
end

--- The event data of the entry at `lnum`.
---@return table|nil entry, string? err
function M.entry(bufnr, lnum)
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
  if not ts then
    return nil, "the entry has no SCHEDULED or :org-gcal: timestamp"
  end
  local event_id, cal = event.split_entry_id(hl.properties["ENTRY-ID"])
  return {
    title = hl.title,
    timestamp = ts,
    description = event.description_text(desc),
    location = hl.properties["LOCATION"],
    transparency = hl.properties["TRANSPARENCY"],
    event_id = event_id,
    calendar_id = hl.properties["CALENDAR-ID"] or cal,
    etag = hl.properties["ETAG"],
    managed = hl.properties["ORG-GCAL-MANAGED"],
  }
end

--- Calendar for a new event: the fetch file's calendar, or ask.
local function pick_calendar(bufnr)
  local opts = gcal().opts()
  local name = vim.api.nvim_buf_get_name(bufnr)
  local ids = {}
  for cal, file in pairs(opts.fetch_file_alist or {}) do
    ids[#ids + 1] = cal
    if name ~= "" and utils.expand(file) == vim.fs.normalize(name) then
      return cal
    end
  end
  table.sort(ids)
  if #ids == 1 then
    return ids[1]
  end
  if #ids == 0 then
    return nil
  end
  return utils.select(ids, { prompt = "Google calendar" })
end

local function save(bufnr)
  if vim.api.nvim_buf_get_name(bufnr) ~= "" then
    utils.save_buffer_or_warn(bufnr)
  end
end

---------------------------------------------------------------------------
-- Post and delete
---------------------------------------------------------------------------

--- Replace the entry with the server's version after a 412.
local function take_server_version(bufnr, lnum, cal, event_id)
  local resp, err = gcal().api({ url = gcal().events_url(cal, event_id) })
  if not resp then
    return false, err
  end
  if resp.status ~= 200 or not resp.json then
    return false, gcal().api_error(resp)
  end
  M.write_entry(bufnr, lnum, cal, resp.json, gcal().opts().managed_update_existing_mode)
  return true
end

--- Create or update the event of the entry at `target` (org-gcal-post-at-point).
---@param target { bufnr?: integer, lnum?: integer }
---@param quiet? boolean don't notify on success
---@return boolean ok, string? err
function M.post(target, quiet)
  local bufnr = bufnr_of(target.bufnr)
  local lnum = target.lnum or vim.api.nvim_win_get_cursor(0)[1]
  local hl = headline(bufnr, lnum)
  if not hl then
    return false, "not on an entry"
  end
  lnum = hl.line
  local entry, err = M.entry(bufnr, lnum)
  if not entry then
    return false, err
  end
  local opts = gcal().opts()
  local cal = entry.calendar_id or pick_calendar(bufnr)
  if not cal then
    return false, "no calendar for this entry: set a calendar-id property or fetch_file_alist"
  end
  local body = event.to_event(opts, entry)
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
  local id = mark(bufnr, lnum)
  local resp, rerr = gcal().api(req)
  lnum = unmark(bufnr, id)
  if not resp then
    return false, rerr
  end
  if not lnum then
    return false, "the entry was deleted while posting"
  end
  if resp.status == 412 then
    local ok, e = take_server_version(bufnr, lnum, cal, entry.event_id)
    save(bufnr)
    if not ok then
      return false, e
    end
    gcal().notify("the event changed on Google Calendar: the entry was updated from it, local changes were not sent")
    return true
  end
  if resp.status ~= 200 or not resp.json then
    return false, gcal().api_error(resp)
  end
  local mode = entry.managed or opts.managed_create_from_entry_mode
  M.write_entry(bufnr, lnum, cal, resp.json, mode)
  save(bufnr)
  if opts.notify and not quiet then
    gcal().notify((entry.event_id and "updated " or "created ") .. event.title(resp.json))
  end
  return true
end

--- Delete the event of the entry at `target` and the entry (org-gcal-delete-at-point).
---@return boolean ok, string? err
function M.delete(target)
  local bufnr = bufnr_of(target.bufnr)
  local lnum = target.lnum or vim.api.nvim_win_get_cursor(0)[1]
  local hl = headline(bufnr, lnum)
  if not hl then
    return false, "not on an entry"
  end
  lnum = hl.line
  local event_id, cal = event.split_entry_id(hl.properties["ENTRY-ID"])
  cal = hl.properties["CALENDAR-ID"] or cal
  if not event_id or not cal then
    return false, "the entry has no Google Calendar event"
  end
  if not utils.confirm(string.format("Delete %q from Google Calendar?", hl.title)) then
    return true
  end
  local etag = hl.properties["ETAG"]
  local id = mark(bufnr, lnum)
  local resp, err = gcal().api({
    method = "DELETE",
    url = gcal().events_url(cal, event_id),
    headers = etag and { ["If-Match"] = etag } or nil,
  })
  lnum = unmark(bufnr, id)
  if not resp then
    return false, err
  end
  if resp.status == 412 and lnum then
    local ok, e = take_server_version(bufnr, lnum, cal, event_id)
    save(bufnr)
    if not ok then
      return false, e
    end
    gcal().notify("the event changed on Google Calendar and was not deleted: the entry was updated from it")
    return true
  end
  if resp.status ~= 204 and resp.status ~= 200 and resp.status ~= 404 and resp.status ~= 410 then
    return false, gcal().api_error(resp)
  end
  if lnum then
    delete_entry(bufnr, lnum)
    save(bufnr)
  end
  if gcal().opts().notify then
    gcal().notify("deleted " .. hl.title)
  end
  return true
end

---------------------------------------------------------------------------
-- Fetch
---------------------------------------------------------------------------

--- Apply one fetched event to a buffer: to the entry at `lnum`, or to the
--- entry with its entry-id (a new entry when there is none). Returns a
--- stats key.
function M.apply(bufnr, calendar_id, ev, push, lnum)
  local opts = gcal().opts()
  lnum = lnum or M.entries(bufnr)[event.entry_id(calendar_id, ev)]
  if ev.status == "cancelled" then
    return lnum and cancel_entry(bufnr, lnum) or "skipped"
  end
  if not lnum then
    append_entry(bufnr, M.entry_lines(calendar_id, ev, opts.managed_newly_fetched_mode))
    return "new"
  end
  local hl = headline(bufnr, lnum)
  if push and hl.properties["ORG-GCAL-MANAGED"] == "org" then
    local ok, err = M.post({ bufnr = bufnr, lnum = lnum }, true)
    if not ok then
      gcal().notify(err or "post failed", vim.log.levels.WARN)
      return "failed"
    end
    return "pushed"
  end
  M.write_entry(bufnr, lnum, calendar_id, ev, opts.managed_update_existing_mode)
  return "updated"
end

local function iso_day(t, opts)
  local c = event.epoch_to_local(opts, t)
  return event.format_rfc3339(opts, event.local_to_epoch(opts, { year = c.year, month = c.month, day = c.day }))
end

--- All changed events of a calendar: incremental with the stored sync
--- token, or a full fetch of the window when there is none, it is older
--- than SYNC_TOKEN_TTL or the server answers 410 Gone.
---@return table[]|nil events, string|table? next_sync_token_or_err
function M.list_events(calendar_id)
  local opts = gcal().opts()
  local now = gcal().now()
  local st = oauth.load(opts).sync_tokens[calendar_id]
  local full = not (type(st) == "table" and st.token and (tonumber(st.expires) or 0) > now)
  for _ = 1, 2 do
    local query = { singleEvents = "true", maxResults = "2500" }
    if full then
      query.timeMin = iso_day(now - opts.up_days * 86400, opts)
      query.timeMax = iso_day(now + (opts.down_days + 1) * 86400, opts)
    else
      query.syncToken = st.token
    end
    local items, gone = {}, false
    while true do
      local resp, err = gcal().api({ url = gcal().events_url(calendar_id), query = query })
      if not resp then
        return nil, err
      end
      if resp.status == 410 and not full then
        gone = true
        break
      end
      if resp.status ~= 200 or not resp.json then
        return nil, gcal().api_error(resp)
      end
      vim.list_extend(items, resp.json.items or {})
      if resp.json.nextPageToken then
        query.pageToken = resp.json.nextPageToken
      else
        return items, resp.json.nextSyncToken
      end
    end
    if gone then
      full = true
    end
  end
  return nil, "sync failed"
end

--- Archive entries whose event ended before the fetch window.
local function archive_old(bufnr)
  local opts = gcal().opts()
  local limit = date.today_days() - opts.up_days
  local old = {}
  for _, hl in ipairs(files.get_buffer(bufnr).headlines) do
    if hl.properties["ENTRY-ID"] then
      local ts = hl.planning.scheduled or (hl.timestamps[1] and hl.timestamps[1].date)
      local last = ts and (ts.range_end or ts)
      if last and last:days() < limit then
        old[#old + 1] = mark(bufnr, hl.line)
      end
    end
  end
  local n = 0
  for i = #old, 1, -1 do
    local lnum = unmark(bufnr, old[i])
    if lnum and pcall(require("org.archive").archive_subtree, { bufnr = bufnr, lnum = lnum }) then
      n = n + 1
    end
  end
  return n
end

local function add_stats(total, key)
  total[key] = (total[key] or 0) + 1
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

--- Fetch one calendar into its file.
function M.fetch_calendar(calendar_id, path, push, stats)
  local opts = gcal().opts()
  local items, next_token = M.list_events(calendar_id)
  if not items then
    return false, next_token
  end
  path = utils.expand(path)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local bufnr = utils.load_buffer(path)
  for _, ev in ipairs(items) do
    add_stats(stats, M.apply(bufnr, calendar_id, ev, push))
  end
  if opts.auto_archive then
    stats.archived = (stats.archived or 0) + archive_old(bufnr)
  end
  save(bufnr)
  if next_token then
    local state = oauth.load(opts)
    state.sync_tokens[calendar_id] = { token = next_token, expires = gcal().now() + M.SYNC_TOKEN_TTL }
    oauth.save(opts, state)
  end
  return true
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
    local stats = {}
    for _, cal in ipairs(cals) do
      local ok, err = M.fetch_calendar(cal, opts.fetch_file_alist[cal], o.push, stats)
      if not ok then
        return false, string.format("%s: %s", cal, err)
      end
    end
    if opts.notify then
      gcal().notify((o.push and "synced: " or "fetched: ") .. summary(stats))
    end
    return true
  end)
end

--- Refresh (and with `push`, sync) every entry of a buffer from its event.
---@return boolean ok, string? err
function M.buffer(bufnr, o)
  bufnr = bufnr_of(bufnr)
  return exclusive(function()
    local opts = gcal().opts()
    local marks = {}
    for entry_id, lnum in pairs(M.entries(bufnr)) do
      marks[#marks + 1] = { id = entry_id, mark = mark(bufnr, lnum) }
    end
    local stats = {}
    for _, m in ipairs(marks) do
      local event_id, cal = event.split_entry_id(m.id)
      local lnum = marked_line(bufnr, m.mark)
      local hl = lnum and headline(bufnr, lnum)
      cal = hl and hl.properties["CALENDAR-ID"] or cal
      if hl and event_id and cal then
        local resp, err = gcal().api({ url = gcal().events_url(cal, event_id) })
        lnum = marked_line(bufnr, m.mark)
        if not resp then
          for _, mm in ipairs(marks) do
            unmark(bufnr, mm.mark)
          end
          return false, err
        end
        local ev = resp.json
        if resp.status == 404 or resp.status == 410 then
          ev = { id = event_id, status = "cancelled" }
        elseif resp.status ~= 200 or not ev then
          add_stats(stats, "failed")
          ev = nil
        end
        if ev and lnum then
          add_stats(stats, M.apply(bufnr, cal, ev, o.push, lnum))
        end
      end
      unmark(bufnr, m.mark)
    end
    save(bufnr)
    if opts.notify then
      gcal().notify((o.push and "synced buffer: " or "fetched buffer: ") .. summary(stats))
    end
    return true
  end)
end

return M
