---@mod org.extensions.caldav.entry Org entries as the fields the calendar syncs
---
--- An entry is read into the same fields a calendar component is
--- (`org.extensions.caldav.ical`), and a changed field is written back
--- into it without touching the rest of the entry.
---
--- An event keeps its time in a line of its own right below the heading's
--- planning line and drawers (one line per timestamp), else in the first
--- active timestamp of the heading or its text, else in SCHEDULED or
--- DEADLINE. Its description is the text below. A task (VTODO) keeps its
--- start in SCHEDULED and its due date in DEADLINE.

local ical = require("org.extensions.caldav.ical")
local date = require("org.date")
local edit = require("org.edit")
local files = require("org.files")

local M = {}

---@class org.caldav.Layout
---@field src "block"|"inline"|"scheduled"|"deadline"|"none" where the event's time is
---@field first? integer first line of the timestamp lines
---@field last? integer
---@field line? integer line of an inline timestamp
---@field start_col? integer
---@field end_col? integer
---@field in_title? boolean
---@field old? org.Date the (first) timestamp there
---@field text integer first line the description can start at

--- The first line of an entry's text: after its planning line, its
--- property drawer and the drawers right below them.
---@param hl org.Headline
---@return integer
local function body_start(hl)
  local l = edit.meta_end(hl) + 1
  local moved = true
  while moved do
    moved = false
    for _, d in ipairs(hl.drawers) do
      if d.start == l then
        l = d["end"] + 1
        moved = true
      end
    end
  end
  return l
end

--- The timestamp lines at the top of an entry's text: lines holding one
--- active timestamp and nothing else.
---@param file org.File
---@param hl org.Headline
---@return org.Date[] dates, integer first, integer last
local function time_block(file, hl)
  local first = body_start(hl)
  local l = first
  local dates = {}
  while l <= hl.body_end do
    local line = file.lines[l]
    local stamps = date.parse_all(line)
    local s = stamps[1]
    if #stamps == 1 and s.date.active and vim.trim(line) == s.raw then
      dates[#dates + 1] = s.date
      l = l + 1
    else
      break
    end
  end
  return dates, first, l - 1
end

--- Whether an entry is never synced: a comment, an inline task, or one
--- in an archived subtree.
---@param hl org.Headline
---@return boolean
function M.excluded(hl)
  if hl.commented or hl.inlinetask then
    return true
  end
  local h = hl
  while h do
    if vim.tbl_contains(h.tags, "ARCHIVE") then
      return true
    end
    h = h.parent
  end
  return false
end

--- What a new entry is synced as: a task (with a TODO keyword, when the
--- calendar takes tasks), an event (with an active timestamp; SCHEDULED
--- or DEADLINE count for an entry without keyword only, as in
--- ox-icalendar), or nil.
---@param file org.File
---@param hl org.Headline
---@param todos boolean
---@return "VEVENT"|"VTODO"|nil
function M.kind(file, hl, todos)
  if hl.todo and todos then
    return "VTODO"
  end
  if #time_block(file, hl) > 0 then
    return "VEVENT"
  end
  for _, ts in ipairs(hl.timestamps) do
    if not ts.in_property then
      return "VEVENT"
    end
  end
  if not hl.todo and (hl.planning.scheduled or hl.planning.deadline) then
    return "VEVENT"
  end
  return nil
end

---@param file org.File
---@param hl org.Headline
---@param from integer
---@return integer first, integer last (first > last: no text)
local function text_range(file, hl, from)
  local first, last = from, hl.body_end
  while first <= last and not file.lines[first]:match("%S") do
    first = first + 1
  end
  while last >= first and not file.lines[last]:match("%S") do
    last = last - 1
  end
  return first, last
end

--- The indentation the lines `first..last` share.
---@param file org.File
---@param first integer
---@param last integer
---@return string
local function common_indent(file, first, last)
  local indent
  for i = first, last do
    local l = file.lines[i]
    if l:match("%S") then
      local ind = l:match("^ *")
      if not indent or #ind < #indent then
        indent = ind
      end
    end
  end
  return indent or ""
end

---@param file org.File
---@param p string|nil a priority cookie
---@return string "", "1", "5" or "9"
local function priority_class(file, p)
  if not p or p == "" then
    return ""
  end
  local pr = file:priorities()
  if p == pr.highest then
    return "1"
  elseif p == pr.lowest then
    return "9"
  end
  return "5"
end

--- Read an entry's fields.
---@param file org.File
---@param hl org.Headline
---@param kind "VEVENT"|"VTODO"
---@return table<string, string> fields, org.caldav.Layout layout
function M.read(file, hl, kind)
  local fields = {}
  ---@type org.caldav.Layout
  local layout = { src = "none", text = body_start(hl) }
  local title = hl.title
  if kind == "VEVENT" then
    local dates, first, last = time_block(file, hl)
    local ts
    for _, t in ipairs(hl.timestamps) do
      if not t.in_property then
        ts = t
        break
      end
    end
    if #dates > 0 then
      local keys = {}
      for _, d in ipairs(dates) do
        keys[#keys + 1] = ical.date_key(d)
      end
      fields.time = table.concat(keys, "\n")
      layout = { src = "block", first = first, last = last, old = dates[1], text = last + 1 }
    elseif ts then
      fields.time = ical.date_key(ts.date)
      layout.src, layout.line, layout.start_col, layout.end_col = "inline", ts.line, ts.start_col, ts.end_col
      layout.in_title, layout.old = ts.in_title, ts.date
      if ts.in_title then
        local raw = file.lines[ts.line]:sub(ts.start_col, ts.end_col)
        local s, e = title:find(raw, 1, true)
        if s then
          title = title:sub(1, s - 1) .. title:sub(e + 1)
        end
      end
    elseif hl.planning.scheduled or hl.planning.deadline then
      layout.src = hl.planning.scheduled and "scheduled" or "deadline"
      layout.old = hl.planning[layout.src]
      fields.time = ical.date_key(layout.old)
    else
      fields.time = ""
    end
  else
    local p = hl.planning
    fields.scheduled = p.scheduled and ical.point_key(p.scheduled) or ""
    fields.deadline = p.deadline and ical.point_key(p.deadline) or ""
    if hl.todo and file.settings.todo:is_done(hl.todo) then
      fields.status = hl.todo:upper():match("^CANCEL") and "cancelled" or "done"
    else
      fields.status = "todo"
    end
    fields.priority = priority_class(file, hl.priority)
    if p.closed then
      fields._closed = ical.point_key(p.closed)
    end
  end
  fields.summary = ical.one_line(title)
  fields.location = ical.one_line(hl.properties.LOCATION)
  local first, last = text_range(file, hl, layout.text)
  if first > last then
    fields.description = ""
  else
    local cut = #common_indent(file, first, last)
    local lines = {}
    for i = first, last do
      lines[#lines + 1] = file.lines[i]:sub(cut + 1)
    end
    fields.description = ical.block(table.concat(lines, "\n"))
  end
  return fields, layout
end

---------------------------------------------------------------------------
-- Writing
---------------------------------------------------------------------------

--- The entry of `uid` in a buffer, as it is now.
---@param bufnr integer
---@param uid string
---@return org.File file, org.Headline|nil hl
function M.find(bufnr, uid)
  local file = files.get_buffer(bufnr)
  return file, file:find_by_id(uid)
end

--- A new timestamp keeps the warning cookie of the one it replaces, and
--- its kind of repeater (`.+1w`) when the interval is the same.
---@param d org.Date
---@param old org.Date|nil
---@return org.Date
local function keep(d, old)
  if old then
    d.warning = old.warning
    local a, b = d.repeater, old.repeater
    if a and b and a.value == b.value and a.unit == b.unit then
      a.type, a.max = b.type, b.max
    end
  end
  return d
end

--- The lines of a description as they are written under a heading.
---@param text string
---@param indent string
---@return string[]
local function text_lines(text, indent)
  local out = {}
  if text == "" then
    return out
  end
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    if l ~= "" then
      -- a line starting with stars would be a heading
      if indent == "" and l:match("^%*+ ") then
        l = " " .. l
      end
      l = indent .. l
    end
    out[#out + 1] = l
  end
  return out
end

---@param bufnr integer
---@param uid string
---@param kind "VEVENT"|"VTODO"
---@param text string
local function set_description(bufnr, uid, kind, text)
  local file, hl = M.find(bufnr, uid)
  if not hl then
    return
  end
  local _, layout = M.read(file, hl, kind)
  local first, last = text_range(file, hl, layout.text)
  if first <= last then
    local new = text_lines(text, common_indent(file, first, last))
    vim.api.nvim_buf_set_lines(bufnr, first - 1, last, false, new)
  else
    local new = text_lines(text, edit.body_indent(hl.level))
    vim.api.nvim_buf_set_lines(bufnr, layout.text - 1, layout.text - 1, false, new)
  end
end

---@param bufnr integer
---@param uid string
---@param keys string
local function set_time(bufnr, uid, keys)
  local file, hl = M.find(bufnr, uid)
  if not hl then
    return
  end
  local _, layout = M.read(file, hl, "VEVENT")
  ---@type org.Date[]
  local dates = {}
  for _, k in ipairs(vim.split(keys, "\n", { plain = true, trimempty = true })) do
    local d = ical.key_date(k)
    if d then
      dates[#dates + 1] = keep(d, layout.old)
    end
  end
  if #dates == 0 then
    return
  end
  local function stamps(indent)
    local out = {}
    for _, d in ipairs(dates) do
      out[#out + 1] = indent .. d:to_string()
    end
    return out
  end
  local src = layout.src
  ---@type "scheduled"|"deadline"|nil
  local planned = (src == "scheduled" and "scheduled") or (src == "deadline" and "deadline") or nil
  if src == "block" then
    local indent = file.lines[layout.first]:match("^(%s*)")
    vim.api.nvim_buf_set_lines(bufnr, layout.first - 1, layout.last, false, stamps(indent))
    return
  end
  if #dates == 1 and src == "inline" then
    local line = file.lines[layout.line]
    local new = line:sub(1, layout.start_col - 1) .. dates[1]:to_string() .. line:sub(layout.end_col + 1)
    vim.api.nvim_buf_set_lines(bufnr, layout.line - 1, layout.line, false, { new })
    return
  end
  if #dates == 1 and planned then
    edit.set_planning(bufnr, hl.line, planned, dates[1])
    return
  end
  -- several timestamps where one was (or none): they get lines of their own
  if src == "inline" then
    local line = file.lines[layout.line]
    local new = line:sub(1, layout.start_col - 1):gsub("%s+$", "") .. line:sub(layout.end_col + 1)
    if layout.in_title or new:match("%S") then
      vim.api.nvim_buf_set_lines(bufnr, layout.line - 1, layout.line, false, { new })
    else
      vim.api.nvim_buf_set_lines(bufnr, layout.line - 1, layout.line, false, {})
    end
  elseif planned then
    edit.set_planning(bufnr, hl.line, planned, nil)
  end
  local _, now = M.find(bufnr, uid)
  if now then
    local at = body_start(now)
    vim.api.nvim_buf_set_lines(bufnr, at - 1, at - 1, false, stamps(edit.body_indent(now.level)))
  end
end

---@param bufnr integer
---@param uid string
---@param kind "scheduled"|"deadline"
---@param key string
local function set_point(bufnr, uid, kind, key)
  local _, hl = M.find(bufnr, uid)
  if not hl then
    return
  end
  local d = key ~= "" and ical.key_date(key) or nil
  edit.set_planning(bufnr, hl.line, kind, d and keep(d, hl.planning[kind]) or nil)
end

--- The keyword a task gets for a status of the calendar.
---@param file org.File
---@param status string "todo", "done" or "cancelled"
---@return string|nil
local function keyword_for(file, status)
  local cfg = file.settings.todo
  if status == "todo" then
    return cfg:todo_names()[1]
  end
  local done, cancelled
  for _, k in ipairs(cfg.keywords) do
    if k.done then
      if k.name:upper():match("^CANCEL") then
        cancelled = cancelled or k.name
      else
        done = done or k.name
      end
    end
  end
  if status == "cancelled" then
    return cancelled or done
  end
  return done or cancelled
end

---@param bufnr integer
---@param uid string
---@param status string
---@param completed string|nil the key of when it was completed
local function set_status(bufnr, uid, status, completed)
  local file, hl = M.find(bufnr, uid)
  if not hl then
    return
  end
  edit.update_headline(bufnr, hl.line, { todo = keyword_for(file, status) or false })
  if status == "todo" then
    if hl.planning.closed then
      edit.set_planning(bufnr, hl.line, "closed", nil)
    end
  elseif completed and not hl.planning.closed then
    local d = ical.key_date(completed)
    if d then
      d.active = false
      edit.set_planning(bufnr, hl.line, "closed", d)
    end
  end
end

---@param file org.File
---@param class string|nil
---@return string|nil
local function priority_for(file, class)
  local pr = file:priorities()
  return class == "1" and pr.highest or class == "5" and pr.default or class == "9" and pr.lowest or nil
end

---@param bufnr integer
---@param uid string
---@param summary string
local function set_summary(bufnr, uid, summary)
  local file, hl = M.find(bufnr, uid)
  if not hl then
    return
  end
  local title = summary ~= "" and summary or "(no title)"
  for _, ts in ipairs(hl.timestamps) do
    -- a timestamp in the heading stays there
    if ts.in_title then
      title = title .. " " .. file.lines[ts.line]:sub(ts.start_col, ts.end_col)
      break
    end
  end
  edit.update_headline(bufnr, hl.line, { title = title })
end

--- Write the fields named in `changed` into the entry of `uid`.
---@param bufnr integer
---@param uid string
---@param kind "VEVENT"|"VTODO"
---@param fields table<string, string>
---@param changed table<string, boolean>
function M.apply(bufnr, uid, kind, fields, changed)
  if changed.description then
    set_description(bufnr, uid, kind, fields.description or "")
  end
  if kind == "VEVENT" and changed.time then
    set_time(bufnr, uid, fields.time or "")
  end
  if changed.location then
    local _, hl = M.find(bufnr, uid)
    if hl then
      edit.set_property(bufnr, hl.line, "LOCATION", fields.location ~= "" and fields.location or nil)
    end
  end
  if kind == "VTODO" then
    if changed.scheduled then
      set_point(bufnr, uid, "scheduled", fields.scheduled or "")
    end
    if changed.deadline then
      set_point(bufnr, uid, "deadline", fields.deadline or "")
    end
    if changed.status then
      set_status(bufnr, uid, fields.status or "todo", fields._completed)
    end
    if changed.priority then
      local file, hl = M.find(bufnr, uid)
      if hl then
        edit.update_headline(bufnr, hl.line, { priority = priority_for(file, fields.priority) or false })
      end
    end
  end
  if changed.summary then
    set_summary(bufnr, uid, fields.summary or "")
  end
end

--- The lines of a new entry for a calendar component.
---@param file org.File the file it goes into
---@param level integer
---@param kind "VEVENT"|"VTODO"
---@param uid string
---@param fields table<string, string>
---@return string[]
function M.lines(file, level, kind, uid, fields)
  local indent = edit.body_indent(level)
  local head = { level = level, title = fields.summary ~= "" and fields.summary or "(no title)" }
  local out = {}
  local planning
  if kind == "VTODO" then
    head.todo = keyword_for(file, fields.status or "todo")
    head.priority = priority_for(file, fields.priority)
    local p = {}
    if (fields.scheduled or "") ~= "" then
      p.scheduled = ical.key_date(fields.scheduled)
    end
    if (fields.deadline or "") ~= "" then
      p.deadline = ical.key_date(fields.deadline)
    end
    local closed = fields.status ~= "todo" and fields._completed and ical.key_date(fields._completed)
    if closed then
      closed.active = false
      p.closed = closed
    end
    planning = edit.build_planning(p, indent)
  end
  out[1] = edit.build_headline(head)
  out[#out + 1] = planning
  out[#out + 1] = indent .. ":PROPERTIES:"
  out[#out + 1] = edit.property_line(indent, "ID", uid)
  if (fields.location or "") ~= "" then
    out[#out + 1] = edit.property_line(indent, "LOCATION", fields.location)
  end
  out[#out + 1] = indent .. ":END:"
  if kind == "VEVENT" then
    for _, k in ipairs(vim.split(fields.time or "", "\n", { plain = true, trimempty = true })) do
      local d = ical.key_date(k)
      if d then
        out[#out + 1] = indent .. d:to_string()
      end
    end
  end
  vim.list_extend(out, text_lines(fields.description or "", indent))
  return out
end

--- Where new entries go in a buffer: their level and the line they are
--- inserted after. With `headline`, under the heading of that title
--- (added at the end of the file when there is none).
---@param bufnr integer
---@param headline? string
---@return integer level, integer after
function M.target(bufnr, headline)
  local count = vim.api.nvim_buf_line_count(bufnr)
  local empty = count == 1 and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ""
  if not headline or headline == "" then
    return 1, empty and 0 or count
  end
  local hl = files.get_buffer(bufnr):find_by_title(headline)
  if not hl then
    if empty then
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "* " .. headline })
    else
      vim.api.nvim_buf_set_lines(bufnr, count, count, false, { "* " .. headline })
    end
    hl = files.get_buffer(bufnr):find_by_title(headline)
  end
  if not hl then
    return 1, vim.api.nvim_buf_line_count(bufnr)
  end
  return hl.level + 1, hl.end_line
end

--- Insert the lines of new entries after line `after`.
---@param bufnr integer
---@param after integer
---@param lines string[]
function M.insert(bufnr, after, lines)
  local count = vim.api.nvim_buf_line_count(bufnr)
  if after == 0 and count == 1 and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  else
    vim.api.nvim_buf_set_lines(bufnr, after, after, false, lines)
  end
end

--- Delete the entry of `uid`. One with subheadings is kept.
---@param bufnr integer
---@param uid string
---@return boolean deleted, string|nil why
function M.delete(bufnr, uid)
  local _, hl = M.find(bufnr, uid)
  if not hl then
    return true, nil
  end
  if #hl.children > 0 then
    return false, "it has subheadings"
  end
  vim.api.nvim_buf_set_lines(bufnr, hl.line - 1, hl.end_line, false, {})
  return true, nil
end

return M
