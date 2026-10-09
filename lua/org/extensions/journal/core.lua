---@mod org.extensions.journal.core Journal files, days and entries
---
--- A journal is a directory of files named after a date with
--- `file_format`: one per day, week, month or year (`file_type`). Each
--- day is a top-level heading, `date_prefix` .. `date_format`; in weekly,
--- monthly and yearly files it has a `:CREATED: YYYYMMDD` property, in
--- daily files the file name gives the date (as in Emacs org-journal).
--- Entries are headings under the day, `time_prefix` .. `time_format`.

local date = require("org.date")
local utils = require("org.utils")

local M = {}

---@class org.journal.Day
---@field date org.Date the day
---@field days integer its day number
---@field path string the journal file
---@field line integer the day's heading (1 when the day is a whole daily file without one)
---@field end_line integer last line of the day
---@field level integer the day heading's level (0 without a heading)

---@return table
function M.opts()
  return require("org.extensions").opts("journal") or require("org.extensions.journal").defaults
end

--- The journal directory, absolute and without a trailing slash.
---@return string
function M.directory()
  return (utils.expand(M.opts().directory):gsub("/+$", ""))
end

local function daily()
  return (M.opts().file_type or "daily") == "daily"
end

--- Level of the day headings (stars in `date_prefix`), 0 when the prefix
--- isn't a heading (a daily file is then the day).
---@return integer
function M.day_level()
  local stars = (M.opts().date_prefix or "* "):match("^(%*+) ")
  return stars and #stars or 0
end

--- Level of the time entries (stars in `time_prefix`), nil when it isn't a
--- heading.
---@return integer|nil
function M.entry_level()
  local stars = (M.opts().time_prefix or "** "):match("^(%*+)")
  return stars and #stars or nil
end

--- The first day of the file `d` belongs in: `d` for daily files, the start
--- of its week (`start_on_weekday`), month or year otherwise.
---@param d org.Date
---@return org.Date
function M.period_start(d)
  local t = M.opts().file_type
  if t == "weekly" then
    local wd = tonumber(M.opts().start_on_weekday) or 1
    if wd == 0 then
      wd = 7
    end
    return date.from_days(d:days() - (d:weekday() - wd) % 7)
  elseif t == "monthly" then
    return date.from_days(date.days_from_civil(d.year, d.month, 1))
  elseif t == "yearly" then
    return date.from_days(date.days_from_civil(d.year, 1, 1))
  end
  return date.from_days(d:days())
end

--- Last day of the file whose first day is `start`.
---@param start org.Date
---@return org.Date
function M.period_end(start)
  local t = M.opts().file_type
  if t == "weekly" then
    return date.from_days(start:days() + 6)
  elseif t == "monthly" then
    return date.from_days(date.days_from_civil(start.year, start.month, date.days_in_month(start.year, start.month)))
  elseif t == "yearly" then
    return date.from_days(date.days_from_civil(start.year, 12, 31))
  end
  return start
end

--- `fmt` (format-time-string) or `fun(d): string` applied to a date.
---@param fmt string|fun(d: org.Date): string
---@param d org.Date
---@return string
function M.format(fmt, d)
  if type(fmt) == "function" then
    return tostring(fmt(d) or "")
  end
  return d:strftime(fmt or "")
end

--- The journal file of the day `d`.
---@param d org.Date
---@return string
function M.path(d)
  return M.directory() .. "/" .. M.format(M.opts().file_format, M.period_start(d))
end

---------------------------------------------------------------------------
-- File names
---------------------------------------------------------------------------

local NUM = {
  Y = { "(%d%d%d%d)", "year" },
  G = { "(%d%d%d%d)", "isoyear" },
  m = { "(%d%d)", "month" },
  d = { "(%d%d)", "day" },
  e = { " ?(%d%d?)", "day" },
  j = { "(%d%d%d)", "yday" },
  V = { "(%d%d)", "isoweek" },
  y = { "(%d%d)", "yy" },
}

--- A Lua pattern matching the file names of `file_format` (relative to the
--- directory), and the field each capture holds.
---@param fmt string
---@return string pattern, string[] fields
function M.name_pattern(fmt)
  fmt = fmt:gsub("%%F", "%%Y-%%m-%%d")
  local out, fields = { "^" }, {}
  local i = 1
  while i <= #fmt do
    local c = fmt:sub(i, i)
    if c == "%" and i < #fmt then
      local k = fmt:sub(i + 1, i + 1)
      -- flags and widths (%-d, %_m, %3N) are skipped
      while k:match("[%-_0%^#%d]") and i + 2 <= #fmt do
        i = i + 1
        k = fmt:sub(i + 1, i + 1)
      end
      local n = NUM[k]
      if n then
        out[#out + 1] = n[1]
        fields[#fields + 1] = n[2]
      elseif k == "%" then
        out[#out + 1] = "%%"
      elseif k:match("[aAbBh]") then
        out[#out + 1] = "%a+"
      else
        out[#out + 1] = "[^/]-"
      end
      i = i + 2
    else
      out[#out + 1] = c:match("%w") and c or ("%" .. c)
      i = i + 1
    end
  end
  out[#out + 1] = "$"
  return table.concat(out), fields
end

--- The date a journal file name stands for (the first day of its file),
--- nil when `rel` (relative to the directory) isn't a journal file name or
--- doesn't hold a date.
---@param rel string
---@return org.Date|nil, boolean matched
function M.date_of_name(rel)
  local pat, fields = M.name_pattern(M.opts().file_format)
  local caps = { rel:match(pat) }
  if #caps == 0 then
    return nil, false
  end
  local v = {}
  for i, f in ipairs(fields) do
    v[f] = tonumber(caps[i])
  end
  local year = v.year or (v.yy and 2000 + v.yy)
  if v.isoyear and v.isoweek then
    local jan4 = date.days_from_civil(v.isoyear, 1, 4)
    local monday = jan4 - (date.from_days(jan4):weekday() - 1) + 7 * (v.isoweek - 1)
    local wd = tonumber(M.opts().start_on_weekday) or 1
    return date.from_days(monday + ((wd == 0 and 7 or wd) - 1)), true
  end
  if not year then
    return nil, true
  end
  if v.yday then
    return date.from_days(date.days_from_civil(year, 1, 1) + v.yday - 1), true
  end
  local month, day = v.month or 1, v.day or 1
  if month < 1 or month > 12 or day < 1 or day > date.days_in_month(year, month) then
    return nil, true
  end
  return date.from_days(date.days_from_civil(year, month, day)), true
end

--- The path relative to the journal directory, nil outside of it.
---@param path string
---@return string|nil
local function relative(path)
  local dir = M.directory() .. "/"
  path = vim.fs.normalize(path)
  if path:sub(1, #dir) == dir then
    return path:sub(#dir + 1)
  end
end

--- Whether `path` is a journal file (its name matches `file_format`).
---@param path string
---@return boolean
function M.is_journal(path)
  local rel = path and path ~= "" and relative(path)
  if not rel then
    return false
  end
  local _, matched = M.date_of_name(rel)
  return matched
end

--- The journal files on disk, sorted by name.
---@return string[]
function M.files()
  local dir = M.directory()
  if not utils.is_dir(dir) then
    return {}
  end
  local depth = select(2, (M.opts().file_format or ""):gsub("/", "")) + 1
  local out = {}
  for name, type in vim.fs.dir(dir, { depth = depth }) do
    if type == "file" and M.is_journal(dir .. "/" .. name) then
      out[#out + 1] = vim.fs.normalize(dir .. "/" .. name)
    end
  end
  table.sort(out)
  return out
end

---------------------------------------------------------------------------
-- Days
---------------------------------------------------------------------------

--- The date of a `:CREATED:` value: `20261008`, `2026-10-08` or a
--- timestamp.
---@param v string|nil
---@return org.Date|nil
function M.parse_created(v)
  local y, m, d = (v or ""):match("(%d%d%d%d)%-?(%d%d)%-?(%d%d)")
  if not y then
    return nil
  end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if m < 1 or m > 12 or d < 1 or d > date.days_in_month(y, m) then
    return nil
  end
  return date.from_days(date.days_from_civil(y, m, d))
end

--- The days of a parsed journal file, in file order.
---@param file org.File
---@param path string
---@return org.journal.Day[]
function M.file_days(file, path)
  path = vim.fs.normalize(path)
  local level = M.day_level()
  local out = {}
  local function add(d, line, end_line, lvl)
    out[#out + 1] = { date = d, days = d:days(), path = path, line = line, end_line = end_line, level = lvl }
  end
  if daily() then
    local rel = relative(path)
    local d = rel and M.date_of_name(rel)
    if level == 0 then
      local last = #file.lines
      if d and (last > 1 or (file.lines[1] or "") ~= "") then
        add(d, 1, last, 0)
      end
      return out
    end
    for _, hl in ipairs(file.headlines) do
      if hl.level == level then
        local created = M.parse_created(hl.properties.CREATED)
        if created or d then
          add(created or d --[[@as org.Date]], hl.line, hl.end_line, level)
        end
        break
      end
    end
    return out
  end
  for _, hl in ipairs(file.headlines) do
    if hl.level == level then
      local created = M.parse_created(hl.properties.CREATED)
      if created then
        add(created, hl.line, hl.end_line, level)
      end
    end
  end
  return out
end

--- Every journal day, oldest first.
---@return org.journal.Day[]
function M.days()
  local out = {}
  for _, path in ipairs(M.files()) do
    local file = require("org.files").get(path)
    if file then
      vim.list_extend(out, M.file_days(file, path))
    end
  end
  -- a new journal buffer that isn't written yet
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) or ""
    if name ~= "" and vim.fn.filereadable(name) == 0 and M.is_journal(name) then
      vim.list_extend(out, M.file_days(require("org.files").get_buffer(b), name))
    end
  end
  table.sort(out, function(a, b)
    if a.days ~= b.days then
      return a.days < b.days
    end
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.line < b.line
  end)
  return out
end

--- The day `d` in the buffer `buf`, if it has one.
---@param buf integer
---@param d org.Date
---@return org.journal.Day|nil, org.journal.Day[] all days of the buffer
function M.find_day(buf, d)
  local days = M.file_days(require("org.files").get_buffer(buf), vim.api.nvim_buf_get_name(buf))
  for _, day in ipairs(days) do
    if day.days == d:days() then
      return day, days
    end
  end
  return nil, days
end

--- Last line of `day` that isn't blank (where entries are added after).
---@param buf integer
---@param day org.journal.Day
---@return integer
function M.content_end(buf, day)
  local lines = vim.api.nvim_buf_get_lines(buf, day.line - 1, day.end_line, false)
  for i = #lines, 1, -1 do
    if lines[i]:match("%S") then
      return day.line + i - 1
    end
  end
  return day.line
end

local function split(text)
  if text == "" then
    return {}
  end
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

--- Whether the buffer holds nothing but one empty line.
local function empty(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return #lines == 0 or (#lines == 1 and lines[1] == "")
end

--- Add the heading of day `d` to the journal buffer `buf`, in date order
--- among its days (org-journal--insert-entry-header).
---@param buf integer
---@param d org.Date
---@return org.journal.Day
local function insert_day(buf, d)
  local o = M.opts()
  local head = type(o.date_format) == "function" and M.format(o.date_format, d)
    or ((o.date_prefix or "* ") .. M.format(o.date_format, d))
  local lines = split(head)
  if not daily() and M.day_level() > 0 then
    lines[#lines + 1] = ":PROPERTIES:"
    lines[#lines + 1] = ":CREATED:  " .. d:strftime("%Y%m%d")
    lines[#lines + 1] = ":END:"
  end
  local _, days = M.find_day(buf, d)
  local at
  for _, day in ipairs(days) do
    if day.days > d:days() then
      at = day.line
      break
    end
  end
  if at then
    vim.api.nvim_buf_set_lines(buf, at - 1, at - 1, false, lines)
  elseif empty(buf) then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  else
    -- after the last line that isn't blank
    local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local last = #all
    while last > 0 and not all[last]:match("%S") do
      last = last - 1
    end
    vim.api.nvim_buf_set_lines(buf, last, last, false, lines)
  end
  return assert(M.find_day(buf, d))
end

---------------------------------------------------------------------------
-- Carry-over (org-journal--carryover)
---------------------------------------------------------------------------

local function today_days()
  return date.today_days()
end

--- `<2026-10-07 Wed>` timestamps (date only, not on a SCHEDULED or
--- DEADLINE line) moved to the day `d`, as org-journal does.
local function redate(lines, d)
  local stamp = d:strftime("%Y-%m-%d %a")
  for i, l in ipairs(lines) do
    if not l:match("SCHEDULED:") and not l:match("DEADLINE:") then
      lines[i] = l:gsub("<%d%d%d%d%-%d%d%-%d%d ?%a*>", function()
        return "<" .. stamp .. ">"
      end)
    end
  end
  return lines
end

local function strip_trailing_blank(lines)
  while #lines > 0 and not lines[#lines]:match("%S") do
    lines[#lines] = nil
  end
  return lines
end

--- Whether the day's text has nothing but its heading, planning lines,
--- drawers and blank lines (org-journal--empty-journal-p).
---@param lines string[] the day's lines, heading first
---@param has_heading boolean
local function day_empty(lines, has_heading)
  local in_drawer = false
  for i, l in ipairs(lines) do
    if not (has_heading and i == 1) then
      local s = vim.trim(l)
      if in_drawer then
        if s:upper() == ":END:" then
          in_drawer = false
        end
      elseif s:match("^:[%w_-]+:$") then
        in_drawer = true
      elseif s ~= "" then
        local rest = s:gsub("%u+:%s*[<%[][^>%]]*[>%]]", "")
        if vim.trim(rest) ~= "" then
          return false
        end
      end
    end
  end
  return true
end

--- Move the items matching `carryover` from the last journal day before
--- `today` into it: each with the headings above it, which stay behind
--- while something else is left under them (org-journal--carryover).
---@param buf integer today's journal buffer
---@param today org.Date
---@return integer moved the number of items carried over
function M.carryover(buf, today)
  local o = M.opts()
  local match = o.carryover
  if not match or match == "" then
    return 0
  end
  local pred, err = require("org.agenda.search").try_compile(match, { groups = false })
  if not pred then
    utils.warn("journal: bad carryover match: " .. tostring(err))
    return 0
  end
  local prev
  for _, day in ipairs(M.days()) do
    if day.days < today:days() then
      prev = day
    end
  end
  if not prev then
    return 0
  end
  local pbuf = utils.load_buffer(prev.path)
  local file = require("org.files").get_buffer(pbuf)
  local pday
  for _, day in ipairs(M.file_days(file, prev.path)) do
    if day.days == prev.days then
      pday = day
    end
  end
  if not pday then
    return 0
  end
  local lines = file.lines
  -- the items, and the headings above them up to the day
  local items, ancestors, seen, chains = {}, {}, {}, {}
  local skip_to = 0
  for _, hl in ipairs(file.headlines) do
    if hl.line > pday.line and hl.line <= pday.end_line and hl.level > pday.level and hl.line > skip_to then
      if pred(hl) then
        items[#items + 1] = hl
        skip_to = hl.end_line
        local chain = {}
        local p = hl.parent
        while p and p.level > pday.level do
          table.insert(chain, 1, p)
          p = p.parent
        end
        for _, a in ipairs(chain) do
          if not seen[a.line] then
            seen[a.line] = true
            ancestors[#ancestors + 1] = a
          end
        end
        chains[hl] = chain
      end
    end
  end
  if #items == 0 then
    return 0
  end
  -- the text: each heading above an item once, with its own section
  local text, emitted = {}, {}
  for _, hl in ipairs(items) do
    for _, a in ipairs(chains[hl]) do
      if not emitted[a.line] then
        emitted[a.line] = true
        local stop = a.children[1] and a.children[1].line - 1 or a.end_line
        vim.list_extend(text, strip_trailing_blank(vim.list_slice(lines, a.line, stop)))
      end
    end
    vim.list_extend(text, strip_trailing_blank(vim.list_slice(lines, hl.line, hl.end_line)))
  end
  redate(text, today)

  -- remove them from the previous day; a heading above goes too when
  -- nothing is left under it
  local gone = {}
  local taken = {}
  for _, hl in ipairs(items) do
    taken[hl] = true
    for l = hl.line, hl.end_line do
      gone[l] = true
    end
  end
  table.sort(ancestors, function(a, b)
    return a.level > b.level
  end)
  for _, a in ipairs(ancestors) do
    local all = true
    for _, c in ipairs(a.children) do
      if not taken[c] then
        all = false
        break
      end
    end
    if all then
      taken[a] = true
      for l = a.line, a.end_line do
        gone[l] = true
      end
    end
  end
  local kept = {}
  for l = pday.line, pday.end_line do
    if not gone[l] then
      kept[#kept + 1] = lines[l]
    end
  end
  vim.api.nvim_buf_set_lines(pbuf, pday.line - 1, pday.end_line, false, kept)

  -- the previous day may now be empty (carryover_delete_empty)
  local delete = o.carryover_delete_empty
  local removed_file = false
  local prev_lines = vim.list_slice(kept, 1, #kept)
  if
    delete
    and delete ~= "never"
    and day_empty(prev_lines, pday.level > 0)
    and (delete ~= "ask" or utils.confirm("Delete empty journal entry/file?"))
  then
    local others = M.file_days(require("org.files").get_buffer(pbuf), prev.path)
    if #others <= 1 and pbuf ~= buf then
      vim.fn.delete(prev.path)
      pcall(vim.api.nvim_buf_delete, pbuf, { force = true })
      require("org.files").invalidate(prev.path)
      removed_file = true
    else
      vim.api.nvim_buf_set_lines(pbuf, pday.line - 1, pday.line - 1 + #kept, false, {})
    end
  end
  if pbuf ~= buf and not removed_file then
    utils.save_buffer_or_warn(pbuf)
  end

  -- and add them at the end of today
  local day = assert(M.find_day(buf, today))
  local at = M.content_end(buf, day)
  vim.api.nvim_buf_set_lines(buf, at, at, false, text)
  return #items
end

---------------------------------------------------------------------------
-- Opening a day, adding entries
---------------------------------------------------------------------------

--- Unfold the whole day `d` (org-journal--finalize-view shows its subtree).
---@param buf integer
---@param d org.Date
function M.show_day(buf, d)
  local day = M.find_day(buf, d)
  if day and vim.wo.foldmethod == "expr" then
    require("org.fold").refresh(buf)
    pcall(vim.cmd, string.format("silent! %d,%dfoldopen!", day.line, day.end_line))
  end
end

--- Open the journal file of `d` in the current window and make sure it has
--- the day (org-journal-new-entry): the file header in a new file, the day
--- heading and, for today, the carry-over. With `opts.entry`, add an entry
--- at the end of the day (timed when `d` is today and `opts.no_time` isn't
--- set) and leave the cursor on it; otherwise the cursor goes to the day.
---@param d org.Date
---@param opts? { entry?: boolean, no_time?: boolean, carryover?: boolean, insert?: boolean, text?: string }
---@return integer buf, integer row the buffer and the row of the day or entry
function M.open(d, opts)
  opts = opts or {}
  local o = M.opts()
  d = date.from_days(d:days())
  local path = M.path(d)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  utils.open_file(path)
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype ~= "org" then
    vim.bo[buf].filetype = "org"
  end
  if empty(buf) then
    local header = o.file_header
    if header and header ~= "" then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, split(M.format(header, d)))
    end
  end
  local day = M.find_day(buf, d)
  if not day then
    day = insert_day(buf, d)
  end
  local today = d:days() == today_days()
  if today and opts.carryover ~= false then
    local moved = M.carryover(buf, d)
    if moved > 0 then
      -- the items left the previous day's file, which is saved: keep them
      utils.save_buffer_or_warn(buf)
      utils.notify(string.format("journal: carried over %d item%s", moved, moved == 1 and "" or "s"))
    end
    day = assert(M.find_day(buf, d))
  end
  local row = day.line
  if opts.entry then
    local stamp = ""
    if today and not opts.no_time then
      stamp = date.now():strftime(o.time_format or "")
    end
    local head = (o.time_prefix or "** ") .. stamp .. (opts.text or "")
    local at = M.content_end(buf, day)
    local new = { head }
    local col
    local tmpl = o.entry_template
    if type(tmpl) == "function" then
      tmpl = tmpl(d)
    end
    if tmpl and tmpl ~= "" then
      for _, l in ipairs(vim.split(tmpl, "\n", { plain = true })) do
        new[#new + 1] = l
      end
      if new[#new] == "" then
        new[#new] = nil
      end
    end
    -- the cursor goes to `%?` in the template, else after the heading
    row, col = at + 1, #head
    for i, l in ipairs(new) do
      local s = l:find("%?", 1, true)
      if s then
        new[i] = l:sub(1, s - 1) .. l:sub(s + 2)
        row, col = at + i, s - 1
        break
      end
    end
    vim.api.nvim_buf_set_lines(buf, at, at, false, new)
    M.show_day(buf, d)
    vim.api.nvim_win_set_cursor(0, { row, col })
    if opts.insert ~= false and not utils.is_noninteractive() and #vim.api.nvim_list_uis() > 0 then
      utils.start_insert()
    end
  else
    M.show_day(buf, d)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
  end
  return buf, row
end

return M
