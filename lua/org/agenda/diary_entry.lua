---@mod org.agenda.diary_entry Adding diary entries from the agenda (`i`)
---
--- A port of `org-agenda-diary-entry`: with `agenda.diary_entry_file =
--- "diary-file"` (org-agenda-diary-file's default) the entry goes to the
--- Emacs diary file (`agenda.diary_file`) like the calendar's `i` commands
--- (diary-insert-entry, -weekly-, -monthly-, -yearly-, -anniversary-,
--- -block-, -cyclic-entry); with an Org file it becomes an entry of that
--- file (org-agenda-diary-entry-in-org-file), placed by
--- `agenda.insert_diary_strategy`.

local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")

local M = {}

local function view()
  return require("org.agenda.view")
end

--- { year, month, day } of a day number.
local function ymd(day)
  local d = date.from_days(day)
  return d.year, d.month, d.day
end

local function style()
  return config.opts.agenda.calendar_date_style or "american"
end

--- The date text of a diary entry (calendar-date-string with the
--- diary-date-insertion-form of `calendar_date_style`); `*` in place of a
--- field for monthly and yearly entries.
---@param kind "day"|"monthly"|"yearly"
function M.diary_date_string(day, kind)
  local y, m, d = ymd(day)
  local st = style()
  if st == "iso" then
    if kind == "monthly" then
      return string.format("*-*-%02d", d)
    elseif kind == "yearly" then
      return string.format("*-%02d-%02d", m, d)
    end
    return string.format("%d-%02d-%02d", y, m, d)
  elseif st == "european" then
    if kind == "monthly" then
      return string.format("%d * ", d)
    elseif kind == "yearly" then
      return string.format("%d %s", d, date.MONTH_NAMES[m])
    end
    return string.format("%d/%d/%d", d, m, y)
  end
  if kind == "monthly" then
    return string.format("* %d", d)
  elseif kind == "yearly" then
    return string.format("%s %d", date.MONTH_NAMES[m], d)
  end
  return string.format("%d/%d/%d", m, d, y)
end

--- Arguments of a diary sexp for a date, in `calendar_date_style` order
--- (the ISO style pads month and day to two digits, like Emacs).
local function sexp_date(day)
  local y, m, d = ymd(day)
  local st = style()
  if st == "iso" then
    return string.format("%d %02d %02d", y, m, d)
  elseif st == "european" then
    return string.format("%d %d %d", d, m, y)
  end
  return string.format("%d %d %d", m, d, y)
end

--- Open `path` in the window beside the agenda with the cursor at `lnum`.
local function show_file(path, lnum, insert)
  local v = view()
  local S = v.state
  local agenda_win = S.win and vim.api.nvim_win_is_valid(S.win) and S.win or vim.api.nvim_get_current_win()
  local win
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= agenda_win and vim.api.nvim_win_get_config(w).relative == "" then
      win = w
      break
    end
  end
  if not win then
    vim.api.nvim_set_current_win(agenda_win)
    vim.cmd("rightbelow split")
    win = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(win)
  local bufnr = utils.find_buffer(path) or utils.load_buffer(path)
  vim.api.nvim_win_set_buf(win, bufnr)
  lnum = math.min(lnum or vim.api.nvim_buf_line_count(bufnr), vim.api.nvim_buf_line_count(bufnr))
  vim.api.nvim_win_set_cursor(win, { lnum, #(vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or "") })
  pcall(vim.cmd, "normal! zv")
  if insert and #vim.api.nvim_list_uis() > 0 then
    vim.cmd("startinsert!")
  end
  return bufnr, win
end

---------------------------------------------------------------------------
-- The Emacs diary file
---------------------------------------------------------------------------

local DIARY_KEYS = {
  d = "day",
  w = "weekly",
  m = "monthly",
  y = "yearly",
  a = "anniversary",
  b = "block",
  c = "cyclic",
}

--- The text of a new diary line (diary-make-entry): the date part and a
--- space; "&" before it for a non-marking entry.
---@param kind string day|weekly|monthly|yearly|anniversary|block|cyclic
---@param d1 integer day number (point)
---@param d2? integer the other day of a block (mark)
---@param n? integer days of a cyclic entry
function M.diary_line(kind, d1, d2, n, nonmarking)
  local s
  if kind == "day" or kind == "monthly" or kind == "yearly" then
    s = M.diary_date_string(d1, kind)
  elseif kind == "weekly" then
    s = date.DAY_NAMES_LONG[date.from_days(d1):weekday()]
  elseif kind == "anniversary" then
    s = "%%(diary-anniversary " .. sexp_date(d1) .. ")"
  elseif kind == "block" then
    local a, b = math.min(d1, d2), math.max(d1, d2)
    s = "%%(diary-block " .. sexp_date(a) .. " " .. sexp_date(b) .. ")"
  elseif kind == "cyclic" then
    s = "%%(diary-cyclic " .. n .. " " .. sexp_date(d1) .. ")"
  end
  return (nonmarking and "&" or "") .. s .. " "
end

--- Add an entry to the Emacs diary file and show it for the text.
local function diary_file_entry(d1, d2, nonmarking)
  local ch = utils.getchar("Diary entry: [d]ay [w]eekly [m]onthly [y]early [a]nniversary [b]lock [c]yclic")
  if not ch then
    return nil
  end
  local kind = DIARY_KEYS[ch]
  if not kind then
    utils.error("No command associated with <" .. ch .. ">")
    return nil
  end
  if not d1 or (kind == "block" and not d2) then
    utils.error("Don't know which date to use for diary entry")
    return nil
  end
  local n
  if kind == "cyclic" then
    local s = utils.input({ prompt = "Repeat every how many days: " })
    n = s and tonumber(s)
    if not n then
      return nil
    end
  end
  local path = require("org.agenda.diary").file()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local bufnr = utils.find_buffer(path) or utils.load_buffer(path)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = M.diary_line(kind, d1, d2 or d1, n, nonmarking)
  local lnum
  if #lines == 1 and lines[1] == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { text })
    lnum = 1
  else
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { text })
    lnum = #lines + 1
  end
  show_file(path, lnum, true)
  return text
end

---------------------------------------------------------------------------
-- An Org diary file (org-agenda-diary-entry-in-org-file)
---------------------------------------------------------------------------

local function ts(day, time)
  return "<" .. date.from_days(day):to_string({ brackets = false }) .. (time or "") .. ">"
end

--- The line after the section of the headline at `lnum` (before its
--- first child with `first_child`), past trailing blank lines backwards.
local function insert_point(bufnr, lnum, first_child)
  local file = require("org.files").get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  local stop = hl.end_line
  if first_child and hl.children[1] then
    stop = hl.children[1].line - 1
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  while stop > hl.line and vim.trim(lines[stop] or "") == "" do
    stop = stop - 1
  end
  return stop, hl.level
end

--- Insert heading `text` and the line `stamp` for a day / block entry per
--- `agenda.insert_diary_strategy`; returns the stamp's line.
local function insert_entry(bufnr, day, text, stamp)
  local strategy = config.opts.agenda.insert_diary_strategy or "date-tree"
  local indent = config.opts.adapt_indentation == true
  if strategy == "top-level" then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local last = #lines
    if last == 1 and lines[1] == "" then
      last = 0
    end
    local new = { "* " .. text, (indent and "  " or "") .. stamp }
    vim.api.nvim_buf_set_lines(bufnr, last, last == 0 and 1 or last, false, new)
    return last + 2
  end
  local node = require("org.capture").ensure_datetree(bufnr, nil, date.from_days(day), "day")
  local at, level = insert_point(bufnr, node, strategy ~= "date-tree-last")
  local pad = indent and string.rep(" ", level + 2) or ""
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, { string.rep("*", level + 1) .. " " .. text, pad .. stamp })
  return at + 2
end

--- The time at the start of a day entry's text, as " HH:MM[-HH:MM]", and
--- the text without it (org-agenda-insert-diary-extract-time).
local function extract_time(text)
  local found = require("org.agenda.items").find_time(text)
  if not found then
    return nil, text
  end
  local function hm(m)
    return string.format("%02d:%02d", math.floor(m / 60), m % 60)
  end
  local t = " " .. hm(found.start) .. (found.stop and ("-" .. hm(found.stop)) or "")
  local s, e = text:find(vim.pesc(found.text) .. " *")
  return t, text:sub(1, s - 1) .. text:sub(e + 1)
end

local function org_file_entry(path, d1, d2)
  if not d1 then
    utils.error("No date defined in current line")
    return nil
  end
  local ch = utils.getchar("Diary entry: [d]ay [a]nniversary [b]lock [j]ump to date tree")
  if not ch then
    return nil
  end
  local kinds = { d = "day", a = "anniversary", b = "block", j = "jump" }
  local kind = kinds[ch]
  if not kind then
    utils.error("Invalid selection character `" .. ch .. "'")
    return nil
  end
  local text, year
  if kind == "day" then
    text = utils.input({ prompt = "Day entry: " })
  elseif kind == "anniversary" then
    local y = date.from_days(d1).year
    local s = utils.input({ prompt = string.format("Reference year [%d]: ", y) })
    if s == nil then
      return nil
    end
    year = tonumber(s) or y
    text = utils.input({ prompt = "Anniversary (use %d to show years): " })
  elseif kind == "block" then
    text = utils.input({ prompt = "Block entry: " })
    if text and not (d2 and d2 ~= d1) then
      utils.error("No block of days selected")
      return nil
    end
  end
  if kind ~= "jump" and text == nil then
    return nil
  end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local bufnr = utils.find_buffer(path) or utils.load_buffer(path)
  if kind == "jump" then
    local node = require("org.capture").ensure_datetree(bufnr, nil, date.from_days(d1), "day")
    show_file(path, node)
    return true
  end
  local lnum
  if kind == "anniversary" then
    local _, m, d = ymd(d1)
    local line = string.format("%%%%(org-anniversary %d %2d %2d) %s", year, m, d, text)
    local file = require("org.files").get_buffer(bufnr)
    local anniv = file:find_headline(function(h)
      return h.level == 1 and h.raw:match("^%*[ \t]+Anniversaries") ~= nil
    end)
    if not anniv then
      -- a new "* Anniversaries" before the first headline
      local first = file.headlines[1]
      local at = first and first.line - 1 or vim.api.nvim_buf_line_count(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, at, at, false, { "* Anniversaries", line, "" })
      lnum = at + 2
    else
      local at = insert_point(bufnr, anniv.line, false)
      vim.api.nvim_buf_set_lines(bufnr, at, at, false, { line })
      lnum = at + 1
    end
  elseif kind == "day" then
    local time
    if config.opts.agenda.insert_diary_extract_time then
      time, text = extract_time(text)
    end
    lnum = insert_entry(bufnr, d1, text, ts(d1, time))
  else
    local a, b = math.min(d1, d2), math.max(d1, d2)
    lnum = insert_entry(bufnr, a, text, ts(a) .. "--" .. ts(b))
  end
  if text:match("%S") then
    local what = kind:sub(1, 1):upper() .. kind:sub(2)
    utils.notify(what .. " entry added to " .. utils.abbreviate(path))
    -- from the agenda (not from the calendar)
    if vim.bo.filetype == "orgagenda" then
      view().redo()
    end
  else
    show_file(path, lnum, true)
    utils.notify("Please finish entry here")
  end
  return true
end

---------------------------------------------------------------------------
-- The command
---------------------------------------------------------------------------

--- Make a diary entry for the date at point (org-agenda-diary-entry, `i`).
--- A block uses the days at both ends of the Visual selection (Emacs:
--- point and mark). With `nonmarking` (a count, C-u) a diary-file entry
--- is non-marking ("&").
---@param opts? { region?: integer[], nonmarking?: boolean }
function M.entry(opts)
  opts = opts or {}
  local v = view()
  local S = v.state
  local lnum = S.win and vim.api.nvim_win_is_valid(S.win) and vim.api.nvim_win_get_cursor(S.win)[1] or 1
  local d1 = v.day_at_line(lnum)
  local d2
  if opts.region then
    local other = opts.region[1] == lnum and opts.region[2] or opts.region[1]
    d2 = v.day_at_line(other)
  end
  local target = config.opts.agenda.diary_entry_file
  if target == nil or target == "diary-file" then
    return diary_file_entry(d1, d2, opts.nonmarking)
  end
  -- lint: allow expand: the diary_entry_file option, not document text
  return org_file_entry(vim.fs.normalize(vim.fn.expand(target)), d1, d2)
end

--- A diary entry for day `d1` from the calendar
--- (org-calendar-insert-diary-entry-key): org-agenda-diary-entry-in-org-file
--- with the calendar's date. Only with an Org `agenda.diary_entry_file`.
---@param d1 integer day number
---@param d2? integer the other end of a block
function M.calendar_entry(d1, d2)
  local target = config.opts.agenda.diary_entry_file
  if target == nil or target == "diary-file" then
    return nil
  end
  -- lint: allow expand: the diary_entry_file option, not document text
  return org_file_entry(vim.fs.normalize(vim.fn.expand(target)), d1, d2)
end

return M
