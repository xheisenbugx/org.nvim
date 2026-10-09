---@mod org.extensions.journal.commands Journal actions
---
--- New entries, dated and scheduled entries, moving between days, the
--- calendar of days with entries and searching the journal.

local core = require("org.extensions.journal.core")
local date = require("org.date")
local utils = require("org.utils")

local M = {}

--- The date read from `arg` (org-read-date syntax), or picked in the
--- calendar when `arg` is empty. nil when cancelled or unreadable.
---@param arg? string
---@param prompt string
---@return org.Date|nil
local function read_date(arg, prompt)
  if type(arg) == "string" and vim.trim(arg) ~= "" then
    local d = date.read_date(vim.trim(arg), date.today())
    if not d then
      utils.warn("journal: cannot read date " .. arg)
    end
    return d
  end
  return require("org.calendar").pick({ prompt = prompt, marks = M.marks() })
end

--- Today's journal: a new timed entry at the end of today's day, made
--- (with the carry-over) when missing (org-journal-new-entry). With a date
--- (`:Org journal_new_entry fri`), an entry on that day, untimed unless it
--- is today.
---@param arg? string
function M.new_entry(arg)
  local d = date.today()
  if type(arg) == "string" and vim.trim(arg) ~= "" then
    d = read_date(arg, "Journal entry")
    if not d then
      return
    end
  end
  core.open(d, { entry = true })
end

--- Open today's day, made when missing, without adding an entry
--- (org-journal-new-entry with C-u).
function M.open_today()
  core.open(date.today())
end

--- An entry on a date from the calendar (or `arg`): in the past or today a
--- new entry, in the future a scheduled one (org-journal-new-date-entry).
---@param arg? string
function M.new_date_entry(arg)
  local d = read_date(arg, "Journal entry for")
  if not d then
    return
  end
  if d:days() > date.today_days() then
    return M.new_scheduled_entry(d)
  end
  core.open(d, { entry = true })
end

--- A TODO entry on a future day with that day's active timestamp below it,
--- so it shows in the agenda (org-journal-new-scheduled-entry).
---@param arg? string|org.Date a date, or text read as one
function M.new_scheduled_entry(arg)
  local d = type(arg) == "table" and arg or read_date(arg --[[@as string?]], "Schedule journal entry")
  if not d then
    return
  end
  if d:days() <= date.today_days() then
    utils.warn("journal: a scheduled entry needs a date in the future")
    return
  end
  local o = core.opts()
  local text = "TODO "
  if d.hour then
    text = text .. d:strftime(o.time_format or "")
  end
  local buf, row = core.open(d, { entry = true, no_time = true, insert = false, text = text, carryover = false })
  local stamp = date.from_days(d:days(), { hour = d.hour, min = d.min, active = true }):to_string()
  local prefix = o.scheduled_string or ""
  vim.api.nvim_buf_set_lines(buf, row, row, false, { prefix .. (prefix ~= "" and " " or "") .. stamp })
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  vim.api.nvim_win_set_cursor(0, { row, #line })
  if not utils.is_noninteractive() and #vim.api.nvim_list_uis() > 0 then
    utils.start_insert()
  end
end

---------------------------------------------------------------------------
-- Moving between days
---------------------------------------------------------------------------

--- The day at the cursor: the day around it in a journal file, else today.
---@return integer days the day number, number|nil row the day's heading
local function current_days()
  local path = vim.api.nvim_buf_get_name(0)
  if core.is_journal(path) then
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local days = core.file_days(require("org.files").get_buffer(0), path)
    local found
    for _, day in ipairs(days) do
      if day.line <= row then
        found = day
      end
    end
    if found then
      return found.days
    end
    if days[1] then
      -- above the first day of the file: just before it
      return days[1].days - 0.5
    end
    local d = core.date_of_name(path:sub(#core.directory() + 2))
    if d then
      return d:days()
    end
  end
  return date.today_days()
end

local function count(n)
  n = tonumber(n)
  if n and n > 0 then
    return math.floor(n)
  end
  return vim.v.count > 0 and vim.v.count or 1
end

--- Go `n` days with entries forward (negative: back) from the day at the
--- cursor, or from today outside the journal.
---@param n integer
function M.step(n)
  local from = current_days()
  local forward = n > 0
  local seen, dates = {}, {}
  local by_days = {}
  for _, day in ipairs(core.days()) do
    if not seen[day.days] then
      seen[day.days] = true
      dates[#dates + 1] = day.days
      by_days[day.days] = day
    end
  end
  local target
  if n > 0 then
    for _, d in ipairs(dates) do
      if d > from then
        n = n - 1
        if n == 0 then
          target = d
          break
        end
      end
    end
  else
    for i = #dates, 1, -1 do
      local d = dates[i]
      if d < from then
        n = n + 1
        if n == 0 then
          target = d
          break
        end
      end
    end
  end
  if not target then
    utils.warn("journal: no entry " .. (forward and "after" or "before") .. " this one")
    return false
  end
  local day = by_days[target]
  utils.open_file(day.path, day.line)
  core.show_day(vim.api.nvim_get_current_buf(), day.date)
  vim.api.nvim_win_set_cursor(0, { day.line, 0 })
  return true
end

--- The next day with entries (org-journal-next-entry); a count skips.
---@param n? integer|string
function M.next(n)
  M.step(count(n))
end

--- The previous day with entries (org-journal-previous-entry).
---@param n? integer|string
function M.previous(n)
  M.step(-count(n))
end

---------------------------------------------------------------------------
-- Calendar
---------------------------------------------------------------------------

--- The days with entries, as calendar marks: past days and today in
--- `OrgCalendarMarked`, future ones in `OrgCalendarMarkedFuture`
--- (org-journal-mark-entries).
---@return table<integer, string>
function M.marks()
  local out = {}
  local today = date.today_days()
  for _, day in ipairs(core.days()) do
    out[day.days] = day.days > today and "OrgCalendarMarkedFuture" or "OrgCalendarMarked"
  end
  return out
end

--- The calendar with the days that have entries marked (`n` / `p` move
--- between them); the chosen day opens, or after a question is made.
function M.calendar()
  local marks = M.marks()
  local cur = current_days()
  local d = require("org.calendar").pick({
    prompt = "Journal",
    marks = marks,
    default = date.from_days(math.floor(cur)),
  })
  if not d or d.remove then
    return
  end
  if not marks[d:days()] then
    if not utils.confirm(string.format("No journal entry for %s. Make one?", d:to_date_string())) then
      return
    end
  end
  core.open(d)
end

---------------------------------------------------------------------------
-- Search
---------------------------------------------------------------------------

--- The day numbers a search range spans, nil for no bound: "all" (or
--- "forever"), "future", "past", "week", "month", "year", or two dates
--- "FROM..TO" (either may be empty).
---@param range? string
---@return integer|nil from, integer|nil to, string|nil err
function M.range(range)
  range = vim.trim(range or "")
  local today = date.today()
  if range == "" or range == "all" or range == "forever" then
    return nil, nil
  elseif range == "future" then
    return today:days(), nil
  elseif range == "past" then
    return nil, today:days()
  elseif range == "week" then
    local wd = tonumber(core.opts().start_on_weekday) or 1
    local start = today:days() - (today:weekday() - (wd == 0 and 7 or wd)) % 7
    return start, start + 6
  elseif range == "month" then
    local s = date.days_from_civil(today.year, today.month, 1)
    return s, s + date.days_in_month(today.year, today.month) - 1
  elseif range == "year" then
    return date.days_from_civil(today.year, 1, 1), date.days_from_civil(today.year, 12, 31)
  end
  local a, b = range:match("^(.-)%.%.(.*)$")
  if not a then
    return nil, nil, "unknown range " .. range
  end
  local from, to
  if vim.trim(a) ~= "" then
    local d = date.read_date(vim.trim(a), today)
    if not d then
      return nil, nil, "cannot read date " .. a
    end
    from = d:days()
  end
  if vim.trim(b) ~= "" then
    local d = date.read_date(vim.trim(b), today)
    if not d then
      return nil, nil, "cannot read date " .. b
    end
    to = d:days()
  end
  return from, to
end

M.RANGES = { "all", "future", "past", "week", "month", "year" }

--- Lines of the journal days between `from` and `to` (day numbers, nil for
--- no bound) holding `query`, ignoring case unless it has a capital
--- letter, as picker items (org-journal-search). An empty query lists the
--- entries (lines starting with `time_prefix`).
---@param query string
---@param from? integer
---@param to? integer
---@return org.PickerItem[]
function M.search_items(query, from, to)
  local o = core.opts()
  local plain = query == ""
  local needle = plain and (o.time_prefix or "** ") or query
  local fold = not plain and not needle:match("%u")
  if fold then
    needle = needle:lower()
  end
  local items = {}
  for _, day in ipairs(core.days()) do
    if (not from or day.days >= from) and (not to or day.days <= to) then
      local file = require("org.files").get(day.path)
      local lines = file and file.lines or {}
      local label = M.format_result_date(day.date)
      for l = day.line, math.min(day.end_line, #lines) do
        local text = lines[l]
        local hay = fold and text:lower() or text
        local col = plain and (hay:sub(1, #needle) == needle and 1 or nil) or hay:find(needle, 1, true)
        if col then
          items[#items + 1] = {
            display = { { label, "Function" }, { "  " .. vim.trim(text), nil } },
            text = label .. " " .. text,
            filename = day.path,
            lnum = l,
            col = col,
            value = day,
          }
        end
      end
    end
  end
  if o.search_order == "desc" then
    local rev = {}
    for i = #items, 1, -1 do
      rev[#rev + 1] = items[i]
    end
    items = rev
  end
  return items
end

---@param d org.Date
---@return string
function M.format_result_date(d)
  return core.format(core.opts().search_date_format or "%a %Y-%m-%d", d)
end

--- Search the journal (org-journal-search). `arg` is the text, optionally
--- after a range (`week`, `month`, `year`, `future`, `past`, `all` or
--- `FROM..TO`); without it the text is asked for and all days searched.
--- The matching lines open in a picker; its quickfix key sends them all
--- to the quickfix list.
---@param arg? string
function M.search(arg)
  arg = type(arg) == "string" and vim.trim(arg) or ""
  local range = ""
  local first, rest = arg:match("^(%S+)%s*(.*)$")
  if first and (vim.tbl_contains(M.RANGES, first) or first == "forever" or first:find("..", 1, true)) then
    range, arg = first, rest
  end
  local query = arg
  if query == "" and range == "" then
    local answer = utils.input({ prompt = "Journal search: " })
    if not answer then
      return
    end
    query = vim.trim(answer)
  end
  local from, to, err = M.range(range)
  if err then
    utils.warn("journal: " .. err)
    return
  end
  local items = M.search_items(query, from, to)
  local title = "Journal" .. (query ~= "" and (": " .. query) or "")
  if #items == 0 then
    utils.notify("journal: no matches" .. (query ~= "" and (" for " .. query) or ""))
    return
  end
  local pickers = require("org.pickers")
  pickers.pick({
    title = title,
    items = items,
    split = true,
    on_choice = function(chosen, _, how)
      pickers.go(chosen, how, title)
    end,
  })
end

--- `:Org journal_search` completion: the ranges.
function M.complete_search(arglead)
  return vim.tbl_filter(function(r)
    return r:sub(1, #arglead) == arglead
  end, M.RANGES)
end

---------------------------------------------------------------------------
-- Agenda
---------------------------------------------------------------------------

--- The journal files of today and later, for the agenda
--- (org-journal-enable-agenda-integration): their last day isn't past.
---@return string[]
function M.agenda_files()
  local out = {}
  local today = date.today_days()
  local dir = core.directory()
  local all = core.opts().agenda == "all"
  for _, path in ipairs(core.files()) do
    local start = core.date_of_name(path:sub(#dir + 2))
    if all or not start or core.period_end(start):days() >= today then
      out[#out + 1] = path
    end
  end
  return out
end

return M
