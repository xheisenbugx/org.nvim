---@mod org.timestamps Inserting and editing timestamps, scheduling

local config = require("org.config")
local date = require("org.date")
local edit = require("org.edit")
local utils = require("org.utils")

local M = {}

local function now_inactive()
  return date.now():clone({ active = false })
end

--- Timestamp under the cursor.
---@return { date: table, start_col: integer, end_col: integer, lnum: integer, raw: string }|nil
function M.at_cursor()
  local lnum, col = utils.cursor()
  local line = vim.api.nvim_get_current_line()
  local item = date.at_col(line, col)
  if not item then
    return nil
  end
  item.lnum = lnum
  return item
end

local function replace_text(bufnr, lnum, s, e, text)
  vim.api.nvim_buf_set_text(bufnr, lnum - 1, s - 1, lnum - 1, e, { text })
end

---------------------------------------------------------------------------
-- Insert
---------------------------------------------------------------------------

--- Write `picked` at the cursor: replace the timestamp `existing` under
--- the cursor, or insert after the cursor character (creating a range when
--- right after another timestamp).
local function put(picked, existing)
  if existing and existing.date.repeater and not picked.repeater then
    picked.repeater = vim.deepcopy(existing.date.repeater)
  end
  local text = picked:to_string()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum, col = utils.cursor()
  if existing then
    replace_text(bufnr, lnum, existing.start_col, existing.end_col, text)
    vim.api.nvim_win_set_cursor(0, { lnum, existing.start_col - 1 })
    return picked
  end
  local line = vim.api.nvim_get_current_line()
  -- insert after the cursor character (like `a`), or at col 0 on empty lines
  local at = #line == 0 and 0 or col
  local before = line:sub(1, at)
  -- right after an existing timestamp: create a range
  local prev = date.parse_all(before)
  local last = prev[#prev]
  if last and last.end_col == #before and not last.date.range_end then
    text = "--" .. text
  elseif at > 0 and not before:match("%s$") then
    text = " " .. text
  end
  vim.api.nvim_buf_set_text(bufnr, lnum - 1, at, lnum - 1, at, { text })
  vim.api.nvim_win_set_cursor(0, { lnum, at + #text - 1 })
  return picked
end

local function insert(active)
  local with_time = vim.v.count > 0
  local existing = M.at_cursor()
  if vim.v.count >= 16 then
    -- C-u C-u: the current time, without prompting
    return put(date.now():clone({ active = active }), existing)
  end
  local default = existing and existing.date or date.today()
  local picked = require("org.calendar").pick({
    default = default,
    prompt = active and "Timestamp" or "Inactive timestamp",
    with_time = with_time,
  })
  if not picked or picked.remove then
    return nil
  end
  return put(picked:clone({ active = active }), existing)
end

function M.insert_active()
  return insert(true)
end

function M.insert_inactive()
  return insert(false)
end

--- Toggle the timestamp at the cursor between active and inactive
--- (org-toggle-timestamp-type). Returns false when not on a timestamp.
function M.toggle_type()
  local item = M.at_cursor()
  if not item then
    return false
  end
  local d = item.date
  local active = not d.active
  local new = d:clone({ active = active })
  if d.range_end then
    new.range_end = d.range_end:clone({ active = active })
  end
  replace_text(0, item.lnum, item.start_col, item.end_col, new:to_string())
  return true
end

--- Insert today's active date at the cursor (org-date-from-calendar: Emacs
--- inserts the date selected in the calendar, which defaults to today).
function M.insert_today()
  return put(date.today(), M.at_cursor())
end

--- Show the calendar at the date under the cursor, or today
--- (org-goto-calendar). The picked date is only reported.
function M.goto_calendar()
  local existing = M.at_cursor()
  local picked = require("org.calendar").pick({
    default = existing and existing.date or date.today(),
    prompt = "Calendar",
  })
  if picked and not picked.remove then
    utils.notify(picked:to_string())
  end
  return true
end

--- Duration text in Emacs style: "N days H:MM" (days omitted when zero).
local function tdiff_string(minutes)
  local neg = minutes < 0
  minutes = math.abs(minutes)
  local days = math.floor(minutes / 1440)
  local rest = minutes % 1440
  local s = string.format("%d:%02d", math.floor(rest / 60), rest % 60)
  if days > 0 then
    s = string.format("%d day%s %s", days, days == 1 and "" or "s", s)
  end
  return neg and ("-" .. s) or s
end

--- Duration of a timestamp range in minutes (nil when not a range).
local function range_minutes(d)
  if d.range_end then
    return d.range_end:minutes() - d:minutes()
  elseif d.end_hour then
    return d:end_minutes() - d:minutes()
  end
end

--- Report the duration of the timestamp range at the cursor, or the first
--- range on the line (org-evaluate-time-range). Handles `<a>--<b>` and
--- `<d 10:00-12:30>`. With `insert` (default: `vim.v.count > 0`), write
--- ` => H:MM` after the range, replacing an existing `=> ...`. On a CLOCK
--- line, recompute its duration instead.
---@param insert_result? boolean
function M.evaluate_time_range(insert_result)
  if insert_result == nil then
    insert_result = vim.v.count > 0
  end
  local lnum, col = utils.cursor()
  local line = vim.api.nvim_get_current_line()
  if line:match("^%s*CLOCK:") then
    local clock = require("org.clock")
    if clock.update_clock_line(0, lnum) then
      local new = vim.api.nvim_get_current_line()
      utils.notify("Clock: " .. (new:match("=>%s*(%S+)") or "?"))
      return true
    end
  end
  local item
  local all = date.parse_all(line)
  for _, it in ipairs(all) do
    if range_minutes(it.date) and col >= it.start_col and col <= it.end_col then
      item = it
    end
  end
  if not item then
    for _, it in ipairs(all) do
      if range_minutes(it.date) then
        item = it
        break
      end
    end
  end
  if not item then
    utils.warn("No timestamp range on this line")
    return false
  end
  local minutes = range_minutes(item.date)
  if insert_result then
    local rest = line:sub(item.end_col + 1)
    if rest:match("^%s*=>") then
      rest = ""
    end
    local new = line:sub(1, item.end_col) .. " => " .. date.format_duration(minutes) .. rest
    vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { new })
  end
  utils.notify(tdiff_string(minutes))
  return true
end

--- Rewrite the timestamp under the cursor in canonical form (day names).
function M.normalize_at_cursor()
  local item = M.at_cursor()
  if not item then
    return false
  end
  replace_text(0, item.lnum, item.start_col, item.end_col, item.date:to_string())
  return true
end

---------------------------------------------------------------------------
-- Increment component under cursor
---------------------------------------------------------------------------

--- Find which component of a single timestamp string `s` is at `off`
--- (1-based offset into s).
local function component_at(s, off)
  -- brackets / date part
  local body_start = 2
  local pos = body_start
  local tokens = {}
  while true do
    local ts, te = s:find("[^%s<>%[%]]+", pos)
    if not ts then
      break
    end
    tokens[#tokens + 1] = { s = ts, e = te, text = s:sub(ts, te) }
    pos = te + 1
  end
  for _, t in ipairs(tokens) do
    if off >= t.s and off <= t.e then
      local rel = off - t.s + 1
      local text = t.text
      if text:match("^%d%d%d%d%-%d%d?%-%d%d?$") then
        if rel <= 4 then
          return "year"
        elseif rel <= 7 then
          return "month"
        end
        return "day"
      elseif text:match("^%d%d?:%d%d%-%d%d?:%d%d$") then
        local dash = text:find("-", 1, true)
        local colon1 = text:find(":", 1, true)
        if rel < dash then
          return rel < colon1 and "hour" or "min"
        end
        local colon2 = text:find(":", dash, true)
        return rel < colon2 and "end_hour" or "end_min"
      elseif text:match("^%d%d?:%d%d$") then
        return rel < text:find(":", 1, true) and "hour" or "min"
      elseif text:match("^[%.%+]?%+%d+[hdwmy]") then
        return "repeater"
      elseif text:match("^%-%-?%d+[hdwmy]") then
        return "warning"
      end
      return "day"
    end
  end
  return "day"
end

--- Minute step for <S-Up>/<S-Down> without a count
--- (org-time-stamp-rounding-minutes), and the minute value rounded so that
--- one step lands on a multiple of it.
local function rounded_minutes(min, n)
  local dm = math.max((config.opts.time_stamp_rounding_minutes or {})[2] or 1, 1)
  if dm <= 1 or vim.v.count > 0 then
    return min, n
  end
  local rem = min % dm
  if rem ~= 0 then
    min = min + (n > 0 and -rem or (dm - rem))
  end
  return min, dm * (n > 0 and 1 or n < 0 and -1 or 0)
end

local function shift_component(d, comp, n)
  if comp == "min" and d.min then
    local min, step = rounded_minutes(d.min, n)
    return d:add(min - d.min + step, "min")
  elseif comp == "end_min" and d.end_min then
    local min, step = rounded_minutes(d.end_min, n)
    n = min - d.end_min + step
  end
  if comp == "year" then
    return d:add(n, "y")
  elseif comp == "month" then
    return d:add(n, "m")
  elseif comp == "day" then
    return d:add(n, "d")
  elseif comp == "hour" then
    return d:add(n, "h")
  elseif comp == "min" then
    return d:add(n, "min")
  elseif comp == "end_hour" or comp == "end_min" then
    local c = d:clone()
    local total = c.end_hour * 60 + c.end_min + (comp == "end_hour" and n * 60 or n)
    total = total % 1440
    c.end_hour, c.end_min = math.floor(total / 60), total % 60
    return c
  elseif comp == "repeater" and d.repeater then
    local c = d:clone()
    c.repeater.value = math.max(0, c.repeater.value + n)
    return c
  elseif comp == "warning" and d.warning then
    local c = d:clone()
    c.warning.value = math.max(0, c.warning.value + n)
    return c
  end
  return d:add(n, "d")
end

--- Shift the component under the cursor by `n`. `unit` forces a unit
--- ("d" for S-left/right). Returns false when not on a timestamp.
---@param n integer
---@param unit? string
function M.increment(n, unit)
  local item = M.at_cursor()
  if not item then
    return false
  end
  local _, col = utils.cursor()
  local line = vim.api.nvim_get_current_line()
  local raw = item.raw
  local d = item.date
  -- which part of a range?
  local part2_start
  if d.range_end then
    local dash = raw:find("--", 2, true)
    while dash and raw:sub(dash + 2, dash + 2):match("[%d]") do
      dash = raw:find("--", dash + 1, true)
    end
    part2_start = dash and (item.start_col + dash + 1) or nil
  end
  local first = d:clone({ range_end = vim.NIL })
  local second = d.range_end
  local on_second = part2_start and col >= part2_start
  local part_text = on_second and line:sub(part2_start, item.end_col)
    or line:sub(item.start_col, part2_start and (part2_start - 3) or item.end_col)
  local part_start = on_second and part2_start or item.start_col
  local comp = unit == "d" and "day" or component_at(part_text, col - part_start + 1)
  if unit and unit ~= "d" then
    comp = ({ y = "year", m = "month", h = "hour", min = "min", w = "day" })[unit] or "day"
    if unit == "w" then
      n = n * 7
    end
  end
  if on_second then
    second = shift_component(second, comp, n)
  else
    first = shift_component(first, comp, n)
  end
  local text = first:to_string({ range = false })
  if second then
    text = text .. "--" .. second:to_string({ range = false })
  end
  replace_text(0, item.lnum, item.start_col, item.end_col, text)
  local new_col = math.min(col, item.start_col + #text - 1)
  vim.api.nvim_win_set_cursor(0, { item.lnum, new_col - 1 })
  if line:match("^%s*CLOCK:") then
    local ok, clock = pcall(require, "org.clock")
    if ok and clock.update_clock_line then
      clock.update_clock_line(0, item.lnum)
    end
  end
  return true
end

---------------------------------------------------------------------------
-- Schedule / deadline
---------------------------------------------------------------------------

local function log_planning_change(bufnr, file, lnum, kind, old, new)
  if not old then
    return
  end
  local todo = require("org.todo")
  local setting = todo.log_setting(file, kind == "scheduled" and "reschedule" or "redeadline")
  if not setting then
    return
  end
  local old_str = '"' .. old:clone({ active = false }):to_string({ range = false }) .. '"'
  local header
  if new then
    header = (kind == "scheduled" and "- Rescheduled from " or "- New deadline from ")
      .. old_str
      .. " on "
      .. now_inactive():to_string()
  else
    header = (kind == "scheduled" and "- Not scheduled, was " or "- Removed deadline, was ")
      .. old_str
      .. " on "
      .. now_inactive():to_string()
  end
  local note
  if setting == "note" then
    note = utils.input({ prompt = "Note: " })
  end
  edit.add_log_entry(bufnr, lnum, edit.log_lines(header, note))
end

--- Set (or remove with nil) a date of an entry.
---@param target? org.Target
---@param kind "scheduled"|"deadline"|"closed"|"timestamp"
---@param value table|nil
function M.set_date(target, kind, value)
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  if kind == "timestamp" then
    local t = hl.timestamps[1]
    if not t then
      if value then
        -- add one after the meta lines
        local at = edit.meta_end(hl)
        vim.api.nvim_buf_set_lines(bufnr, at, at, false, { edit.body_indent(hl.level) .. value:to_string() })
      end
      return value
    end
    local text = value and value:to_string() or ""
    vim.api.nvim_buf_set_text(bufnr, t.line - 1, t.start_col - 1, t.line - 1, t.end_col, { text })
    return value
  end
  edit.set_planning(bufnr, hl.line, kind, value)
  return value
end

--- C-u C-u C-c C-s / C-c C-d: set the delay (SCHEDULED) or warning period
--- (DEADLINE) from a date picked relative to the existing one.
local function plan_warning(bufnr, hl, kind)
  local existing = hl.planning[kind]
  if not existing then
    utils.warn(kind == "deadline" and "No deadline information to update" or "No scheduled information to update")
    return nil
  end
  local picked = require("org.calendar").pick({
    default = existing,
    prompt = kind == "deadline" and "Warn starting from" or "Delay until",
  })
  if not picked or picked.remove then
    return nil
  end
  local days = math.abs(existing:days() - picked:days())
  local new = existing:clone({ warning = { type = "-", value = days, unit = "d" } })
  edit.set_planning(bufnr, hl.line, kind, new)
  return new
end

local function plan(target, kind)
  local remove = vim.v.count > 0
  local bufnr, file, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  if vim.v.count >= 16 then
    return plan_warning(bufnr, hl, kind)
  end
  local existing = hl.planning[kind]
  local new
  if remove then
    new = nil
  else
    local picked = require("org.calendar").pick({
      default = existing or date.today(),
      prompt = kind == "scheduled" and "Schedule" or "Deadline",
      allow_remove = existing ~= nil,
    })
    if not picked then
      return nil
    end
    if not picked.remove then
      new = picked:clone({ active = true, range_end = vim.NIL })
      if existing then
        new.repeater = new.repeater or (existing.repeater and vim.deepcopy(existing.repeater))
        new.warning = new.warning or (existing.warning and vim.deepcopy(existing.warning))
      end
    end
  end
  if not existing and not new then
    return nil
  end
  local lnum = hl.line
  edit.set_planning(bufnr, lnum, kind, new)
  log_planning_change(bufnr, file, lnum, kind, existing, new)
  return new or false
end

function M.schedule(target)
  return plan(target, "scheduled")
end

function M.deadline(target)
  return plan(target, "deadline")
end

--- Shift a date of an entry by n units (agenda S-left/right).
---@param kind "scheduled"|"deadline"|"timestamp"
function M.shift(target, kind, n, unit)
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local d
  if kind == "timestamp" then
    d = hl.timestamps[1] and hl.timestamps[1].date
  else
    d = hl.planning[kind]
  end
  if not d then
    return nil
  end
  local new = d:add_with_range(n, unit or "d")
  M.set_date({ bufnr = bufnr, lnum = hl.line }, kind, new)
  return new
end

return M
