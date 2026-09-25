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
  local default = existing and existing.date or nil
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
  -- only the timestamp at the cursor, also inside a range (like Emacs)
  local _, col = utils.cursor()
  local s, e = item.start_col, item.end_col
  if item.date.range_end then
    local dash = item.raw:find("[%]>]%-%-[<%[]")
    if dash then
      if col > item.start_col + dash then
        s = item.start_col + dash + 2
      else
        e = item.start_col + dash - 1
      end
    end
  end
  local map = { ["["] = "<", ["]"] = ">", ["<"] = "[", [">"] = "]" }
  local text = vim.api.nvim_get_current_line():sub(s, e):gsub("[%[%]<>]", map)
  replace_text(0, item.lnum, s, e, text)
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

--- Duration message like Emacs `org-make-tdiff-string`: "2 days 3 hours
--- 30 minutes" (zero parts omitted).
local function tdiff_string(d, h, m)
  local parts = {}
  local function add(v, word)
    if v > 0 then
      parts[#parts + 1] = string.format("%d %s%s", v, word, v > 1 and "s" or "")
    end
  end
  add(d, "day")
  add(h, "hour")
  add(m, "minute")
  return table.concat(parts, " ")
end

--- The two dates of the range and whether one has a time, or nil when
--- not a range. `<a>--<b>` like Emacs; `<d 10:00-12:30>` is an extension.
local function range_bounds(d)
  if d.range_end then
    return d, d.range_end, d.hour ~= nil or d.range_end.hour ~= nil
  elseif d.end_hour then
    return d, d:clone({ hour = d.end_hour, min = d.end_min, end_hour = vim.NIL, end_min = vim.NIL }), true
  end
end

--- Report the duration of the timestamp range at the cursor, or the first
--- range on the line (org-evaluate-time-range). With `insert` (default:
--- `vim.v.count > 0`), write it after the range in Emacs format (` 2d
--- 03:30`, ` 2d`, ` 00:20`), replacing an earlier result. On a CLOCK line,
--- recompute its duration instead.
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
    if range_bounds(it.date) and col >= it.start_col and col <= it.end_col then
      item = it
    end
  end
  if not item then
    for _, it in ipairs(all) do
      if range_bounds(it.date) then
        item = it
        break
      end
    end
  end
  if not item then
    utils.warn("Not at a timestamp range, and none found in current line")
    return false
  end
  local a, b, havetime = range_bounds(item.date)
  local diff = b:minutes() - a:minutes()
  local negative = diff < 0
  diff = math.abs(diff)
  local d, h, m
  if havetime then
    d, h, m = math.floor(diff / 1440), math.floor((diff % 1440) / 60), diff % 60
  else
    d, h, m = math.floor(diff / 1440 + 0.5), 0, 0
  end
  if insert_result then
    local rest = line:sub(item.end_col + 1)
    -- an earlier result: ( *-? *[0-9]+y)?( *[0-9]+d)? *[0-9][0-9]:[0-9][0-9]
    local r = rest:gsub("^ *%-? *%d+y", "", 1)
    r = r:gsub("^ *%d+d", "", 1)
    local r2 = r:gsub("^ *%d%d:%d%d", "", 1)
    if r2 ~= r then
      rest = r2
    end
    local text
    if d > 0 then
      text = havetime and string.format("%dd %02d:%02d", d, h, m) or string.format("%dd", d)
    else
      text = string.format("%02d:%02d", h, m)
    end
    local new = line:sub(1, item.end_col) .. (negative and " -" or "") .. " " .. text .. rest
    vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { new })
    utils.notify("Time difference inserted")
  else
    utils.notify(tdiff_string(d, h, m))
  end
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

--- Which part of the single timestamp string `s` the cursor is on, like
--- Emacs `org-at-timestamp-p`: the cursor on character `off` (1-based) is
--- point before it, and a field extends to the position right after it.
--- Returns "bracket", "year", "month", "day", "hour", "minute", or
--- { extra = string, offset = integer } for the part after the time (end
--- time, repeater, warning).
local function component_at(s, off)
  local p = off - 1
  if p <= 0 or p == #s - 1 then
    return "bracket"
  end
  local function in_range(b, e)
    return b and p >= b and p <= e
  end
  -- 0-based [begin, end) positions of the groups of org-ts-regexp3
  local ys = 1
  local after_date = 11
  local _, name_e = s:find("^ *[^%]%+0-9>\r\n %-]+", after_date + 1)
  local name_b = name_e and s:find("[^ ]", after_date + 1)
  local pos = name_e or after_date
  local hs, he, ms, me
  local hh, mm = s:match("^ (%d%d?):(%d%d)", pos + 1)
  if hh then
    hs = pos + 1
    he = hs + #hh
    ms = he + 1
    me = ms + 2
  end
  if in_range(ys, ys + 4) then
    return "year"
  elseif in_range(6, 8) then
    return "month"
  elseif in_range(hs, he) then
    return "hour"
  elseif in_range(ms, me) then
    return "minute"
  elseif in_range(9, 11) or (name_e and in_range(name_b - 1, name_e)) then
    return "day"
  end
  local e = me or name_e
  if e and p > e and p < #s then
    return { extra = s:sub(e + 1, -2), offset = p - e }
  end
  return "day"
end

-- d -> w -> m -> y (org-modify-ts-extra)
local UNIT_ORDER = { "d", "w", "m", "y" }

--- Change the end time, repeater or warning at `offset` of `extra` like
--- Emacs `org-modify-ts-extra`: the end hour and minute move by `n`, a
--- unit letter cycles d/w/m/y, a repeater value never drops below 1 and a
--- warning value below 0. Only `+N` repeaters and `-N` warnings in days,
--- weeks, months or years are changed, like Emacs.
local function modify_extra(extra, offset, n)
  local groups = {}
  local i = 0
  local eh, em = extra:match("^%-([012]%d):([0-5]%d)")
  if eh then
    groups.end_hour = { 1, 3 }
    groups.end_min = { 4, 6 }
    i = 6
  end
  local sp, num, unit = extra:match("^( +%+)(%d+)([dmwy])", i + 1)
  if sp then
    local b = i + #sp
    groups.rep_num = { b, b + #num }
    groups.rep_unit = { b + #num, b + #num + 1 }
    i = b + #num + 1
  end
  local wsp, wnum, wunit = extra:match("^( +%-)(%d+)([dmwy])", i + 1)
  if wsp then
    local b = i + #wsp
    groups.warn_num = { b, b + #wnum }
    groups.warn_unit = { b + #wnum, b + #wnum + 1 }
  end
  local function at(g)
    return g and offset >= g[1] and offset <= g[2]
  end
  local function replace(g, text)
    return extra:sub(1, g[1]) .. text .. extra:sub(g[2] + 1)
  end
  local function cycle(u)
    local idx = 1
    for k, v in ipairs(UNIT_ORDER) do
      if v == u then
        idx = k
      end
    end
    return UNIT_ORDER[math.max(1, math.min(#UNIT_ORDER, idx + n))]
  end
  if at(groups.end_hour) or at(groups.end_min) then
    local hour, minute = tonumber(eh), tonumber(em)
    if at(groups.end_hour) then
      hour = hour + n
    else
      minute = minute + n
    end
    hour = hour + math.floor(minute / 60)
    minute = minute % 60
    return replace({ 0, 6 }, string.format("-%02d:%02d", hour % 24, minute))
  elseif at(groups.rep_unit) then
    return replace(groups.rep_unit, cycle(unit))
  elseif at(groups.rep_num) then
    return replace(groups.rep_num, tostring(math.max(1, tonumber(num) + n)))
  elseif at(groups.warn_unit) then
    return replace(groups.warn_unit, cycle(wunit))
  elseif at(groups.warn_num) then
    return replace(groups.warn_num, tostring(math.max(0, tonumber(wnum) + n)))
  end
  return nil
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
  if comp == "minute" and d.min then
    local min, step = rounded_minutes(d.min, n)
    return d:add(min - d.min + step, "min")
  elseif comp == "year" then
    return d:add(n, "y")
  elseif comp == "month" then
    return d:add(n, "m")
  elseif comp == "hour" and d.hour then
    return d:add(n, "h")
  end
  return d:add(n, "d")
end

--- Shift the component under the cursor by `n` (org-timestamp-change). On
--- a bracket, toggle the timestamp between active and inactive. `unit`
--- forces a unit ("d" for S-left/right). Returns false when not on a
--- timestamp.
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
  local on_second = part2_start and col >= part2_start
  local part_start = on_second and part2_start or item.start_col
  local part_end = on_second and item.end_col or (part2_start and (part2_start - 3) or item.end_col)
  if part2_start and not on_second and col > part_end then
    -- on the "--" between the two timestamps: right after the first one
    -- only a forced unit changes it, the second dash is not on a
    -- timestamp (Emacs)
    if col ~= part_end + 1 then
      return false
    elseif not unit then
      return true
    end
  end
  local part_text = line:sub(part_start, part_end)
  local comp = component_at(part_text, col - part_start + 1)
  if unit then
    comp = ({ y = "year", m = "month", h = "hour", min = "minute", w = "day", d = "day" })[unit] or "day"
    if unit == "w" then
      n = n * 7
    end
  end
  if comp == "bracket" then
    return M.toggle_type()
  end
  local text
  if type(comp) == "table" then
    local extra = modify_extra(comp.extra, comp.offset, n)
    if not extra then
      return true
    end
    text = line:sub(part_start, part_start + #part_text - #comp.extra - 2) .. extra .. part_text:sub(-1)
    local new = date.parse(text)
    if not new then
      return true
    end
    replace_text(0, item.lnum, part_start, part_end, text)
  else
    local first = d:clone({ range_end = vim.NIL })
    local second = d.range_end
    if on_second then
      second = shift_component(second, comp, n)
    else
      first = shift_component(first, comp, n)
    end
    text = first:to_string({ range = false })
    if second then
      text = text .. "--" .. second:to_string({ range = false })
    end
    replace_text(0, item.lnum, item.start_col, item.end_col, text)
    text = nil
  end
  local new_line = vim.api.nvim_get_current_line()
  local new_item = date.at_col(new_line, math.min(col, #new_line))
  local max_col = new_item and new_item.end_col or col
  vim.api.nvim_win_set_cursor(0, { item.lnum, math.min(col, max_col) - 1 })
  if line:match("^%s*CLOCK:") then
    local ok, clock = pcall(require, "org.clock")
    if ok and clock.update_clock_line then
      clock.update_clock_line(0, item.lnum, line)
    end
  end
  return true
end

---------------------------------------------------------------------------
-- Custom timestamp display (org-display-custom-times)
---------------------------------------------------------------------------

local custom_ns = vim.api.nvim_create_namespace("org.timestamps.custom")

--- Is the custom display on in `bufnr`? The buffer's toggle, else
--- `#+STARTUP: customtime`, else `display_custom_times`.
function M.custom_display_enabled(bufnr)
  local v = vim.b[bufnr].org_custom_times
  if v ~= nil then
    return v
  end
  local ok, file = pcall(require("org.files").get_buffer, bufnr)
  if ok and file.settings.startup.customtime then
    return true
  end
  return config.opts.display_custom_times == true
end

--- The text a timestamp is displayed as: `time_stamp_custom_formats`
--- (org-timestamp-custom-formats) without surrounding brackets.
function M.custom_text(d)
  local fmts = config.opts.time_stamp_custom_formats or { "%m/%d/%y %a", "%m/%d/%y %a %H:%M" }
  local fmt = (d.hour and fmts[2] or fmts[1]) or "%Y-%m-%d"
  if fmt:match("^<.*>$") or fmt:match("^%[.*%]$") then
    fmt = fmt:sub(2, -2)
  end
  return d:strftime(fmt)
end

--- Redraw the custom display of every timestamp of the buffer: each one
--- (both ends of a range) is concealed and its custom text shown inline,
--- like Emacs displays it over the timestamp. Editing shows the real text
--- (the concealment follows 'concealcursor').
function M.refresh_custom_display(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, custom_ns, 0, -1)
  if not M.custom_display_enabled(bufnr) then
    return
  end
  for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:find("[<%[]%d%d%d%d%-") then
      for _, item in ipairs(date.parse_all(line)) do
        local parts = { { item.date, item.start_col, item.end_col } }
        if item.date.range_end then
          local dash = item.raw:find("[%]>]%-%-[<%[]")
          if dash then
            parts = {
              { item.date, item.start_col, item.start_col + dash - 1 },
              { item.date.range_end, item.start_col + dash + 2, item.end_col },
            }
          end
        end
        for _, part in ipairs(parts) do
          local d, s, e = part[1], part[2], part[3]
          pcall(vim.api.nvim_buf_set_extmark, bufnr, custom_ns, i - 1, s - 1, {
            end_col = e,
            conceal = "",
            virt_text = { { M.custom_text(d), d.active and "OrgTimestamp" or "OrgTimestampInactive" } },
            virt_text_pos = "inline",
          })
        end
      end
    end
  end
end

--- Keep the custom display of `bufnr` up to date while it is on.
function M.attach_custom_display(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if vim.b[bufnr].org_custom_times_attached then
    M.refresh_custom_display(bufnr)
    return
  end
  vim.b[bufnr].org_custom_times_attached = true
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWinEnter" }, {
    buffer = bufnr,
    group = vim.api.nvim_create_augroup("org.timestamps.custom." .. bufnr, { clear = true }),
    callback = function()
      M.refresh_custom_display(bufnr)
    end,
  })
  M.refresh_custom_display(bufnr)
end

--- Toggle the custom timestamp display of the buffer
--- (org-toggle-timestamp-overlays, C-c C-x C-t).
function M.toggle_custom_display()
  local bufnr = vim.api.nvim_get_current_buf()
  local on = not M.custom_display_enabled(bufnr)
  vim.b[bufnr].org_custom_times = on
  if on and vim.wo.conceallevel < 2 then
    vim.wo.conceallevel = 2
  end
  M.attach_custom_display(bufnr)
  utils.notify(on and "Time stamps are overlaid with custom format" or "Time stamp overlays removed")
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
  if new and new:to_string({ range = false }) == old:to_string({ range = false }) then
    return
  end
  local purpose
  if new then
    purpose = kind == "scheduled" and "reschedule" or "redeadline"
  else
    purpose = kind == "scheduled" and "delschedule" or "deldeadline"
  end
  local note
  if setting == "note" then
    note = utils.input_note({ prompt = "Note: ", purpose = new and "rescheduling" or "removing the date" })
  end
  edit.add_log_entry(bufnr, lnum, edit.log_entry(purpose, note, new, old))
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

--- C-c C-s / C-c C-d with the Emacs prefix argument `arg`: 4 (C-u)
--- removes the date, 16 (C-u C-u) sets the delay / warning period.
local function plan(target, kind, arg)
  local bufnr, file, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  if arg == 16 then
    return plan_warning(bufnr, hl, kind)
  end
  local existing = hl.planning[kind]
  local new
  if arg == 4 then
    if not existing then
      utils.notify(kind == "deadline" and "Entry had no deadline to remove" or "Entry was not scheduled")
      return nil
    end
    new = nil
  else
    local picked = require("org.calendar").pick({
      default = existing,
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
  if new and hl.planning.closed then
    -- a new date removes CLOSED (org-add-planning-info ... 'closed)
    edit.set_planning(bufnr, lnum, "closed", nil)
  end
  log_planning_change(bufnr, file, lnum, kind, existing, new)
  if not new then
    utils.notify(kind == "deadline" and "Entry no longer has a deadline." or "Entry is no longer scheduled.")
  end
  return new or false
end

--- Schedule or set a deadline on the headline at the cursor, or on every
--- headline of the Visual selection. The count is the Emacs prefix
--- argument (4 removes, 16 sets the delay / warning).
local function plan_command(target, kind)
  local arg = target == nil and vim.v.count or nil
  if target == nil then
    local targets = edit.region_headlines()
    if targets then
      local last
      for _, t in ipairs(targets) do
        local l = t.lnum()
        if l then
          last = plan({ bufnr = t.bufnr, lnum = l }, kind, arg)
        end
      end
      return last
    end
  end
  return plan(target, kind, arg)
end

function M.schedule(target)
  return plan_command(target, "scheduled")
end

function M.deadline(target)
  return plan_command(target, "deadline")
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
