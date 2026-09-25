---@mod org.agenda.export Writing agenda views to files and batch output
---
--- A port of `org-agenda-write`, `org-store-agenda-views`,
--- `org-batch-agenda` and `org-batch-agenda-csv`. The file type follows the
--- extension: `.txt` (plain text), `.html`/`.htm` (coloured HTML, like
--- htmlize), `.org` (the entries' subtrees) and `.ics` (iCalendar).
--- PDF and PostScript output need Emacs's ps-print and are not supported.

local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")

local M = {}

local function view_mod()
  return require("org.agenda.view")
end

--- The agenda buffer, its lines and line -> item map.
local function current()
  local S = view_mod().state
  if not S.buf or not vim.api.nvim_buf_is_valid(S.buf) then
    return nil
  end
  return S, vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
end

---------------------------------------------------------------------------
-- HTML (htmlize)
---------------------------------------------------------------------------

local function esc(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function hex(n)
  return n and string.format("#%06x", n) or nil
end

--- CSS for a highlight group (links resolved).
local function css_for(group, cache)
  if cache[group] ~= nil then
    return cache[group]
  end
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  local parts = {}
  if ok and hl then
    if hl.fg then
      parts[#parts + 1] = "color: " .. hex(hl.fg)
    end
    if hl.bg then
      parts[#parts + 1] = "background-color: " .. hex(hl.bg)
    end
    if hl.bold then
      parts[#parts + 1] = "font-weight: bold"
    end
    if hl.italic then
      parts[#parts + 1] = "font-style: italic"
    end
    if hl.underline then
      parts[#parts + 1] = "text-decoration: underline"
    end
  end
  cache[group] = table.concat(parts, "; ")
  return cache[group]
end

--- The agenda buffer as an HTML page, coloured from its highlights.
function M.html(buf, lines)
  local ns = vim.api.nvim_create_namespace("org.agenda")
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local by_row = {}
  for _, m in ipairs(marks) do
    local row, col, d = m[2], m[3], m[4]
    local group = d.hl_group or d.line_hl_group
    if group then
      by_row[row] = by_row[row] or {}
      local e = d.end_col or (d.line_hl_group and #(lines[row + 1] or "")) or col
      table.insert(by_row[row], { s = d.line_hl_group and 0 or col, e = e, group = group })
    end
  end
  local cache, classes, used = {}, {}, {}
  local function class_of(group)
    if not classes[group] then
      classes[group] = "org-" .. group:gsub("%W", "-"):lower()
      used[#used + 1] = group
    end
    return classes[group]
  end
  local body = {}
  for i, line in ipairs(lines) do
    local spans = by_row[i - 1] or {}
    table.sort(spans, function(a, b)
      return a.s < b.s
    end)
    local out, pos = {}, 0
    for _, sp in ipairs(spans) do
      if sp.s >= pos and sp.e > sp.s then
        out[#out + 1] = esc(line:sub(pos + 1, sp.s))
        out[#out + 1] = string.format('<span class="%s">%s</span>', class_of(sp.group), esc(line:sub(sp.s + 1, sp.e)))
        pos = sp.e
      end
    end
    out[#out + 1] = esc(line:sub(pos + 1))
    body[#body + 1] = table.concat(out)
  end
  local normal = css_for("Normal", cache)
  local style = { "    body { " .. (normal ~= "" and normal or "color: #000000; background-color: #ffffff") .. "; }" }
  for _, g in ipairs(used) do
    local css = css_for(g, cache)
    if css ~= "" then
      style[#style + 1] = string.format("    .%s { %s; }", classes[g], css)
    end
  end
  local out = {
    "<!DOCTYPE html>",
    "<html>",
    "  <head>",
    '    <meta charset="utf-8">',
    "    <title>Org Agenda</title>",
    '    <style type="text/css">',
  }
  vim.list_extend(out, style)
  vim.list_extend(out, { "    </style>", "  </head>", "  <body>", "    <pre>" })
  vim.list_extend(out, body)
  vim.list_extend(out, { "</pre>", "  </body>", "</html>" })
  return out
end

---------------------------------------------------------------------------
-- Org (the entries' subtrees)
---------------------------------------------------------------------------

--- Unique subtrees of the agenda entries, each promoted/demoted to level 1
--- (org-copy-subtree + org-paste-subtree 1).
function M.org_lines(S, nlines)
  local out, seen = {}, {}
  for l = 1, nlines do
    local it = S.line_items[l]
    local hl = it and it.headline
    if hl then
      local key = (it.filename or tostring(it.bufnr)) .. ":" .. hl.line
      local text = table.concat(vim.list_slice(hl.file.lines, hl.line, hl.end_line), "\n")
      if not seen[key] and not seen[text] then
        seen[key], seen[text] = true, true
        local shift = 1 - hl.level
        for i = hl.line, hl.end_line do
          local line = hl.file.lines[i]
          local stars, rest = line:match("^(%*+)(%s.*)$")
          if not stars and line:match("^%*+$") then
            stars, rest = line, ""
          end
          if stars then
            line = string.rep("*", math.max(1, #stars + shift)) .. rest
          end
          out[#out + 1] = line
        end
      end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- iCalendar (org-icalendar-export-current-agenda)
---------------------------------------------------------------------------

local function uuid()
  local t = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (
    t:gsub("[xy]", function(c)
      local v = c == "x" and math.random(0, 15) or math.random(8, 11)
      return string.format("%X", v)
    end)
  )
end

local function ics_escape(s)
  return (s:gsub("\\", "\\\\"):gsub(";", "\\;"):gsub(",", "\\,"):gsub("\n", "\\n"))
end

local function ics_date(d, prop)
  if d.hour then
    return string.format("%s:%04d%02d%02dT%02d%02d00", prop, d.year, d.month, d.day, d.hour, d.min or 0)
  end
  return string.format("%s;VALUE=DATE:%04d%02d%02d", prop, d.year, d.month, d.day)
end

local function ics_end(d)
  if d.range_end then
    local e = d.range_end
    if e.hour then
      return ics_date(e, "DTEND")
    end
    return ics_date(date.from_days(e:days() + 1), "DTEND")
  end
  if d.hour then
    local em
    if d.end_hour then
      em = d.end_hour * 60 + (d.end_min or 0)
    else
      -- two hours when there is no end (org-icalendar default duration)
      em = d.hour * 60 + (d.min or 0) + 120
    end
    local day = d:days() + math.floor(em / 1440)
    em = em % 1440
    local e = date.from_days(day, { hour = math.floor(em / 60), min = em % 60 })
    return ics_date(e, "DTEND")
  end
  return ics_date(date.from_days(d:days() + 1), "DTEND")
end

local RRULE_FREQ = { h = "HOURLY", d = "DAILY", w = "WEEKLY", m = "MONTHLY", y = "YEARLY" }

local function rrule(d)
  local r = d and d.repeater
  if r and r.value and r.value > 0 then
    return string.format("RRULE:FREQ=%s;INTERVAL=%d", RRULE_FREQ[r.unit] or "DAILY", r.value)
  end
end

--- iCalendar PRIORITY for an entry (org-icalendar--vtodo).
local function ics_priority(hl)
  local pr = hl.file:priorities()
  local function v(x)
    return tonumber(x) or x:byte()
  end
  local p = v(hl.priority or pr.default)
  local lo, hi = v(pr.lowest), v(pr.highest)
  if lo == hi then
    return 5
  end
  return math.floor(9 - 8 * ((lo - p) / (lo - hi)))
end

local function description(hl)
  local lines = {}
  for i = hl.line + 1, hl.body_end do
    local l = hl.file.lines[i]
    local pr = hl.properties_range
    if i ~= hl.planning_line and not (pr and i >= pr[1] and i <= pr[2]) then
      lines[#lines + 1] = vim.trim(l)
    end
  end
  local s = vim.trim(table.concat(lines, "\n"))
  if #s > 100 then
    s = s:sub(1, 100)
  end
  return s
end

--- VEVENT/VTODO lines for the entries of the agenda (in agenda order).
function M.ics_lines(S, nlines)
  local stamp = os.date("!%Y%m%dT%H%M%SZ")
  local out = {
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "X-WR-CALNAME:OrgMode",
    "PRODID:-//" .. (vim.env.USER or "user") .. "//Neovim with org.nvim//EN",
    "X-WR-TIMEZONE:" .. os.date("%Z"),
    "X-WR-CALDESC:",
    "CALSCALE:GREGORIAN",
  }
  local seen = {}
  for l = 1, nlines do
    local it = S.line_items[l]
    local hl = it and it.headline
    local key = hl and ((it.filename or tostring(it.bufnr)) .. ":" .. hl.line)
    if hl and not seen[key] then
      seen[key] = true
      local uid = hl.properties.ID or uuid()
      local title = ics_escape(hl:plain_title())
      local cat = ics_escape(hl:get_category())
      local desc = description(hl)
      for n, t in ipairs(hl.timestamps) do
        local d = t.date
        out[#out + 1] = "BEGIN:VEVENT"
        out[#out + 1] = "DTSTAMP:" .. stamp
        out[#out + 1] = "UID:TS" .. n .. "-" .. uid
        out[#out + 1] = ics_date(d, "DTSTART")
        out[#out + 1] = ics_end(d)
        out[#out + 1] = rrule(d)
        out[#out + 1] = "SUMMARY:" .. title
        if desc ~= "" then
          out[#out + 1] = "DESCRIPTION:" .. ics_escape(desc)
        end
        out[#out + 1] = "CATEGORIES:" .. cat
        out[#out + 1] = "END:VEVENT"
      end
      local dl = hl.planning.deadline
      if dl and not hl.todo then
        out[#out + 1] = "BEGIN:VEVENT"
        out[#out + 1] = "DTSTAMP:" .. stamp
        out[#out + 1] = "UID:DL-" .. uid
        out[#out + 1] = ics_date(dl, "DTSTART")
        out[#out + 1] = ics_end(dl)
        out[#out + 1] = rrule(dl)
        out[#out + 1] = "SUMMARY:DL: " .. title
        out[#out + 1] = "CATEGORIES:" .. cat
        out[#out + 1] = "END:VEVENT"
      end
      if hl.todo then
        local sc = hl.planning.scheduled
        local done = hl:is_done()
        out[#out + 1] = "BEGIN:VTODO"
        out[#out + 1] = "UID:TODO-" .. uid
        out[#out + 1] = "DTSTAMP:" .. stamp
        if sc and not done then
          out[#out + 1] = ics_date(sc, "DTSTART")
        end
        if dl and not done then
          out[#out + 1] = ics_date(dl, "DUE")
        end
        if not done then
          out[#out + 1] = rrule(sc) or rrule(dl)
        end
        out[#out + 1] = "SUMMARY:" .. title
        if desc ~= "" then
          out[#out + 1] = "DESCRIPTION:" .. ics_escape(desc)
        end
        out[#out + 1] = "CATEGORIES:" .. cat
        out[#out + 1] = "SEQUENCE:1"
        out[#out + 1] = "PRIORITY:" .. ics_priority(hl)
        out[#out + 1] = "STATUS:" .. (done and "COMPLETED" or "NEEDS-ACTION")
        out[#out + 1] = "END:VTODO"
      end
    end
  end
  out[#out + 1] = "END:VCALENDAR"
  return out
end

---------------------------------------------------------------------------
-- org-agenda-write
---------------------------------------------------------------------------

--- Write the current agenda view to `path` (org-agenda-write). The format
--- follows the extension; anything else is plain text.
---@param path? string prompted for when nil
---@param opts? { open?: boolean, lines?: string[] }
---@return boolean ok
function M.write(path, opts)
  opts = opts or {}
  local S, lines = current()
  if not S then
    utils.error("No agenda buffer to write")
    return false
  end
  if not path then
    path = utils.input({
      prompt = "Write agenda to file: ",
      default = vim.fn.expand("~/agenda.txt"),
      completion = "file",
    })
    if not path or path == "" then
      return false
    end
  end
  path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  local ext = (path:match("%.([^./]+)$") or ""):lower()
  local out, msg
  if ext == "pdf" or ext == "ps" then
    utils.error("PDF/PostScript agenda export is not supported (it needs Emacs's ps-print)")
    return false
  elseif ext == "org" then
    out, msg = M.org_lines(S, #lines), "Org file written to "
  elseif ext == "html" or ext == "htm" then
    out, msg = M.html(S.buf, lines), "HTML written to "
  elseif ext == "ics" then
    out = M.ics_lines(S, #lines)
    for i, l in ipairs(out) do
      out[i] = l .. "\r"
    end
    msg = "iCalendar written to "
  else
    out, msg = lines, "Plain text written to "
  end
  local ok = pcall(utils.writefile, path, out)
  if not ok then
    utils.error("Cannot write agenda to file " .. path)
    return false
  end
  utils.notify(msg .. path)
  if opts.open then
    pcall(vim.ui.open, path)
  end
  return true
end

--- Export files of a custom command (Emacs's last element): `export_files`
--- (a string or a list).
local function export_files(cmd)
  local f = cmd.export_files
  if type(f) == "string" then
    return { f }
  end
  return f or {}
end
M.export_files = export_files

--- Temporarily merge `overrides` into `config.opts.agenda` while `fn` runs.
local function with_agenda_options(overrides, fn)
  if not overrides or vim.tbl_isempty(overrides) then
    return fn()
  end
  local saved = vim.deepcopy(config.opts.agenda)
  for k, v in pairs(overrides) do
    config.opts.agenda[k] = v
  end
  local ok, err = pcall(fn)
  config.opts.agenda = saved
  if not ok then
    error(err, 0)
  end
end

--- Run every custom command with `export_files` and write its view to
--- each file (org-store-agenda-views). Relative paths are resolved against
--- the current directory, like Emacs.
---@return integer number of files written
function M.store_views(overrides)
  local agenda = require("org.agenda")
  local cmds = config.opts.agenda.custom_commands or {}
  local keys = vim.tbl_keys(cmds)
  table.sort(keys)
  local n = 0
  for _, key in ipairs(keys) do
    local cmd = cmds[key]
    if type(cmd) == "table" then
      local fl = export_files(cmd)
      if #fl > 0 then
        with_agenda_options(overrides, function()
          agenda.open_custom(key)
          for _, f in ipairs(fl) do
            if M.write(vim.fn.fnamemodify(vim.fn.expand(f), ":p")) then
              n = n + 1
            end
          end
          pcall(view_mod().quit, true)
        end)
      end
    end
  end
  utils.notify(string.format("%d agenda view file(s) written", n))
  return n
end

---------------------------------------------------------------------------
-- Batch (org-batch-agenda, org-batch-agenda-csv)
---------------------------------------------------------------------------

--- Open an agenda from a batch key: a custom command or dispatcher key of
--- one character, or a tags/property match string.
local function open_batch(key)
  local agenda = require("org.agenda")
  if type(key) == "table" then
    agenda.open(key)
    return
  end
  local custom = config.opts.agenda.custom_commands or {}
  if type(custom[key]) == "table" then
    agenda.open_custom(key)
  elseif #key > 1 then
    agenda.open_tags(key)
  else
    agenda.dispatch(key)
  end
end

--- Lines of the agenda produced by `key` with `overrides` (agenda options).
function M.batch_lines(key, overrides)
  local lines = {}
  with_agenda_options(overrides, function()
    open_batch(key)
    local _, l = current()
    lines = l or {}
  end)
  return lines
end

local function write_stdout(lines)
  io.stdout:write(table.concat(lines, "\n") .. "\n")
end

--- Print the agenda for `key` to stdout (org-batch-agenda), e.g.
--- `nvim --headless -c "lua require('org.agenda.export').batch('a', { span = 'day' })" -c q`.
---@param key string|table custom command key, dispatcher key, match string or view spec
---@param overrides? table agenda options (like the Emacs variable bindings)
function M.batch(key, overrides)
  local lines = M.batch_lines(key, overrides)
  write_stdout(lines)
  return lines
end

local function csv_field(v)
  v = v == nil and "" or tostring(v)
  return vim.trim((v:gsub(",", ";")))
end

local function day_string(n)
  if not n then
    return ""
  end
  local d = date.from_days(n)
  return string.format("%d-%02d-%02d", d.year, d.month, d.day)
end

--- The CSV record of an agenda item (org-batch-agenda-csv fields:
--- category,head,type,todo,tags,date,time,extra,priority-l,priority-n,agenda-day).
function M.csv_record(it)
  local render = require("org.agenda.render")
  local d
  local t = it.ts_type or ""
  if it.day then
    if t == "past-scheduled" or t == "deadline" or t == "closed" or t == "clock" or t == "state" then
      d = it.date and it.date.days and it.date:days() or it.day
    else
      d = it.day
    end
  end
  local head = render.display_title and render.display_title(it.display_title or it.title or "") or (it.title or "")
  local time = ""
  local start, stop = it.time, it.end_time
  if not start and (t == "todo" or t:match("^tagsmatch") or t == "search") and it.title then
    -- list items look for a time in the headline too (dotime t)
    local items = require("org.agenda.items")
    if items.find_time and config.opts.agenda.search_headline_for_time ~= false then
      local f = items.find_time(items.strip_timestamps(it.title))
      if f then
        start, stop = f.start, f.stop
      end
    end
  end
  if start then
    time = render.time_string and render.time_string(start, stop) or ""
  end
  local fields = {
    it.category or "",
    head,
    t,
    it.todo or "",
    table.concat(it.tags or {}, ":"),
    day_string(d),
    time,
    it.habit and "" or (it.extra or ""),
    it.priority or "",
    it.prio or "",
    day_string(it.day),
  }
  for i, f in ipairs(fields) do
    fields[i] = csv_field(f)
  end
  return table.concat(fields, ",")
end

--- The CSV records of the current agenda buffer, including time grid lines
--- (Emacs outputs them with an empty category).
function M.csv_lines()
  local S, lines = current()
  if not S then
    return {}
  end
  local sep = ((config.opts.agenda.time_grid or {}).separator) or " ┄┄┄┄┄ "
  local out = {}
  local day
  for l, line in ipairs(lines) do
    if S.day_lines and S.day_lines[l] then
      day = S.day_lines[l]
    end
    local it = S.line_items[l]
    if it then
      out[#out + 1] = M.csv_record(it)
    elseif day and not (S.day_lines and S.day_lines[l]) then
      local t = line:match("^%s+(%d%d?:%d%d)")
      if t then
        local rest = line:match("^%s+%d%d?:%d%d(.*)$") or ""
        local text = rest
        if rest:sub(1, #sep) == sep then
          text = rest:sub(#sep + 1)
        else
          text = rest:gsub("^%S*", "", 1)
        end
        out[#out + 1] = table.concat({
          "",
          csv_field(text),
          "",
          "",
          "",
          "",
          csv_field(t .. sep),
          "",
          "",
          "",
          day_string(day),
        }, ",")
      end
    end
  end
  return out
end

--- Print the agenda for `key` as CSV to stdout (org-batch-agenda-csv).
---@param key string|table
---@param overrides? table agenda options
function M.batch_csv(key, overrides)
  local out = {}
  with_agenda_options(vim.tbl_extend("force", { remove_tags = true }, overrides or {}), function()
    open_batch(key)
    out = M.csv_lines()
  end)
  write_stdout(out)
  return out
end

return M
