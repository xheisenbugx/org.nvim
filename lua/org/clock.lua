---@mod org.clock Clocking work time
---
--- One clock runs at a time. Its state is `{ path, start (string), title,
--- effort, total }`; the open `CLOCK: [start]` line in `path` is the source
--- of truth, so the clock survives restarts (`restore()` finds it again).
---
--- User autocmds fire around clocking (the Emacs hooks): `OrgClockInPrepare`
--- (before the CLOCK line is written, `data = { bufnr, lnum }`),
--- `OrgClockIn`, `OrgClockOut`, `OrgClockCancel` and `OrgClockGoto`.
---
--- This file holds the clock state, the helpers the parts share and the
--- lookup of the running clock's CLOCK line; it loads the rest from
--- org/clock/: timers (effort notice, idle time, exit hooks), range
--- (:block ranges), sum (org-clock-sum), clocktable, report (the clock
--- report commands), clocking (clock in, out, cancel, goto), lines (editing
--- CLOCK lines), resolve (open and idle clocks), modeline (statusline,
--- effort), display (sums on headlines) and persist (restore, sync).

local config = require("org.config")
local date = require("org.date")
local edit = require("org.edit")
local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")

local M = {}
-- The parts in org/clock/ add their functions to this table and require it
-- back, so it must be in package.loaded before they load.
package.loaded["org.clock"] = M

---@class org.ClockState
---@field path string "" for a buffer without a file
---@field bufnr? integer the buffer, kept only when it has no file
---@field start string inactive timestamp string of the clock start
---@field title string
---@field effort integer|nil minutes
---@field total integer|nil minutes clocked on the task before this clock (see `clock.mode_line_total`)

---@class org.ClockTask
---@field path string
---@field title string
---@field id? string
---@field out? string clock-out time (inactive timestamp) of the last clock

---@type org.ClockState|nil
M.state = nil
---@type org.ClockTask|nil
M.last = nil
--- Recently clocked tasks, newest first (org-clock-history).
---@type org.ClockTask[]
M.history = {}
--- Task marked with a double count on clock_in, offered as `d` when
--- picking a task (org-clock-default-task).
---@type org.ClockTask|nil
M.default_task = nil
--- The task whose clock was stopped by the last clock_in, offered as `i`
--- when picking a task (org-clock-interrupted-task).
---@type org.ClockTask|nil
M.interrupted = nil
--- Start of time taken off a clock when resolving (s/S): the next clock_in
--- offers to start from there (org-clock-leftover-time). Minutes.
---@type integer|nil
M.leftover = nil

local display_ns = vim.api.nvim_create_namespace("org.clock.display")
local mark_ns = vim.api.nvim_create_namespace("org.clock.target")

local function clock_cfg()
  return config.opts.clock or {}
end

local function fire(pattern, data)
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = pattern, data = data, modeline = false })
end

local function persist()
  local cfg = clock_cfg()
  if not cfg.persist or not cfg.persist_file then
    return
  end
  local clock = cfg.persist == true or cfg.persist == "clock"
  local history = cfg.persist == true or cfg.persist == "history"
  pcall(utils.write_json, cfg.persist_file, {
    state = clock and M.state or vim.NIL,
    last = history and M.last or vim.NIL,
    history = history and M.history or {},
  })
end

--- A date (with time) for a number of civil minutes since the epoch.
local function at_minutes(m)
  m = math.floor(m)
  return date.from_days(math.floor(m / 1440)):add(m % 1440, "min"):clone({ active = false })
end

--- Resolve durations on the Unix timeline; public bounds and leftover time
--- remain civil minutes, like Date:minutes(). Preserve fractional minutes
--- here for the 45-second "barely started" idle-clock check.
local function instant_minutes(m)
  return at_minutes(m):to_time() / 60 + m % 1
end

local function at_instant(m)
  return date.from_time(math.floor(m) * 60, true):clone({ active = false })
end

local function now_minutes()
  return os.time() / 60
end

local function buf_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and vim.fs.normalize(name) or nil
end

--- The current time, rounded to `clock.rounding_minutes` (org-current-time).
--- With `past`, a rounded time in the future is moved back one step.
local function current_time(past)
  local r = clock_cfg().rounding_minutes
  if r == "same-as-time-stamp" then
    r = (config.opts.time_stamp_rounding_minutes or {})[1]
  end
  r = tonumber(r) or 0
  local now = date.now()
  if r <= 1 then
    return now
  end
  local t = os.date("*t")
  local exact = now:minutes() + t.sec / 60
  local rounded = now:add(r * math.floor(now.min / r + 0.5) - now.min, "min")
  if past and rounded:minutes() > exact then
    rounded = rounded:add(-r, "min")
  end
  return rounded
end

--- Format a closed clock line (`=>` holds the duration as H:MM, like Emacs).
function M.format_clock_line(indent, start, stop)
  local minutes = date.elapsed_minutes(start, stop)
  local m = math.abs(minutes)
  return string.format(
    "%sCLOCK: %s--%s => %s",
    indent or "",
    start:clone({ active = false }):to_string({ range = false }),
    stop:clone({ active = false }):to_string({ range = false }),
    string.format(minutes < 0 and "-%d:%02d" or "%2d:%02d", math.floor(m / 60), m % 60)
  ),
    minutes
end

--- Whether `line` is an open CLOCK line starting at `start` (a timestamp
--- string), however its timestamp is written.
---@param line string
---@param start string
function M._is_open_clock_of(line, start)
  if line:match("^%s*CLOCK:%s*" .. utils.escape_pattern(start) .. "%s*$") then
    return true
  end
  local c = parser.parse_clock_line(line)
  local s = c and not c["end"] and date.parse(start)
  return s and c.start:minutes() == s:minutes() or false
end

--- Whether the running clock is in buffer `bufnr`.
local function state_in_buffer(bufnr)
  local st = M.state
  if not st then
    return false
  end
  if st.path == "" then
    return st.bufnr == bufnr
  end
  local path = buf_path(bufnr)
  return path ~= nil and path == vim.fs.normalize(st.path)
end

--- The `bufnr` to keep in the clock state: only for a buffer without a
--- file, which cannot be found again by its path.
local function unnamed(bufnr)
  return buf_path(bufnr) == nil and bufnr or nil
end

-- The last find_open_clock answer, valid while the clock state, the
-- buffer and its changedtick stay the same.
local open_cache

--- Locate the open clock line of the running clock.
---@return integer|nil bufnr, integer|nil lnum
function M.find_open_clock()
  local st = M.state
  if not st then
    return nil
  end
  local bufnr
  if st.path == "" then
    -- a buffer without a file: only that buffer, while it is loaded
    bufnr = st.bufnr
    if not (bufnr and vim.api.nvim_buf_is_loaded(bufnr) and buf_path(bufnr) == nil) then
      return nil
    end
  else
    bufnr = utils.find_buffer(st.path)
  end
  if not bufnr then
    if not utils.exists(st.path) then
      return nil
    end
    bufnr = utils.load_buffer(st.path)
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local c = open_cache
  if c and c.state == st and c.start == st.start and c.bufnr == bufnr and c.tick == tick then
    return c.lnum and bufnr or nil, c.lnum
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local pat = "^%s*CLOCK:%s*" .. utils.escape_pattern(st.start) .. "%s*$"
  local found
  for i, l in ipairs(lines) do
    if l:match(pat) then
      found = i
      break
    end
  end
  -- the line may be written differently from the state's normalized
  -- start (no day name, another day name, extra spaces)
  if not found then
    for i, l in ipairs(lines) do
      if l:find("CLOCK:", 1, true) and M._is_open_clock_of(l, st.start) then
        found = i
        break
      end
    end
  end
  open_cache = { state = st, start = st.start, bufnr = bufnr, tick = tick, lnum = found }
  if found then
    return bufnr, found
  end
  return nil
end

--- Info about the running clock, or nil when no clock runs.
---
--- ```lua
--- local a = require("org.clock").active()
--- if a then print(a.title, a.minutes) end
--- ```
---@return { path: string, title: string, start: table, effort: integer|nil, minutes: integer, clocked: integer, overrun: boolean }|nil
---   `start` is an `org.date` timestamp; `minutes` is the time of this clock,
---   `clocked` adds the earlier time shown in the statusline
---   (`clock.mode_line_total`), `overrun` is true once `clocked` reaches the
---   effort
function M.active()
  local st = M.state
  if not st then
    return nil
  end
  local start = date.parse(st.start)
  if not start then
    return nil
  end
  local minutes = date.elapsed_minutes(start, date.now())
  local clocked = minutes + (st.total or 0)
  return {
    path = st.path,
    title = st.title,
    start = start,
    effort = st.effort,
    minutes = minutes,
    clocked = clocked,
    overrun = st.effort ~= nil and st.effort > 0 and clocked >= st.effort,
  }
end

--- Is the running clock inside the headline at (bufnr, lnum)?
function M.is_clocked_headline(bufnr, lnum)
  if not M.state then
    return false
  end
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  if not state_in_buffer(bufnr) then
    return false
  end
  local b, clnum = M.find_open_clock()
  if not b or b ~= bufnr then
    return false
  end
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(clnum)
  local target = file:headline_at(lnum)
  return hl ~= nil and target ~= nil and hl.line == target.line
end

--- Clock drawer (org-clock-into-drawer, org-clock-drawer-name): the
--- (inherited) CLOCK_INTO_DRAWER property, then `clock.into_drawer`. A
--- number N means "only once the entry has N clock lines".
---@param hl? org.Headline
---@return string|nil name, integer|nil threshold
local function clock_drawer(hl)
  local into = clock_cfg().into_drawer
  local prop = hl and hl:get_property("CLOCK_INTO_DRAWER", true)
  if prop and prop ~= "" then
    if prop == "nil" then
      into = false
    elseif prop == "t" then
      into = true
    elseif prop:match("^%d+$") then
      into = tonumber(prop)
    else
      into = prop
    end
  end
  if into == nil or into == false then
    return nil
  end
  if type(into) == "string" then
    return into
  end
  local log = edit.log_drawer_name(hl)
  if type(into) == "number" then
    return log or "LOGBOOK", into
  end
  return log or "LOGBOOK"
end

local function log_reversed(file)
  local reversed = config.opts.log_states_order_reversed ~= false
  local startup = file.settings.startup or {}
  if startup.logstatesreversed then
    reversed = true
  elseif startup.nologstatesreversed then
    reversed = false
  end
  return reversed
end

--- Write a new CLOCK line for the entry at `lnum` (org-clock-find-position):
--- into the clock drawer (created, or collecting the loose CLOCK lines once
--- a numeric threshold is reached), or next to the existing CLOCK lines.
---@return integer lnum of the new line
local function insert_clock_line(bufnr, lnum, text)
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  local name, threshold = clock_drawer(hl)
  local reversed = log_reversed(file)
  if name then
    for _, d in ipairs(hl.drawers) do
      if d.name:upper() == name:upper() then
        local indent = file.lines[d.start]:match("^(%s*)")
        local at = reversed and d.start or d["end"] - 1
        vim.api.nvim_buf_set_lines(bufnr, at, at, false, { indent .. text })
        return at + 1
      end
    end
  end
  local clock_lines = {}
  for _, c in ipairs(hl.clocks) do
    clock_lines[#clock_lines + 1] = c.line
  end
  table.sort(clock_lines)
  local indent = edit.body_indent(hl.level)
  local at = edit.meta_end(hl)
  if #clock_lines == 0 then
    if name and (not threshold or threshold < 2) then
      local lines = { indent .. ":" .. name .. ":", indent .. text, indent .. ":END:" }
      vim.api.nvim_buf_set_lines(bufnr, at, at, false, lines)
      return at + 2
    end
    vim.api.nvim_buf_set_lines(bufnr, at, at, false, { indent .. text })
    return at + 1
  end
  if name and (not threshold or #clock_lines + 1 >= threshold) then
    -- move the loose CLOCK lines into a new drawer
    local moved = {}
    for i = #clock_lines, 1, -1 do
      local l = clock_lines[i]
      table.insert(moved, 1, indent .. vim.trim(file.lines[l]))
      vim.api.nvim_buf_set_lines(bufnr, l - 1, l, false, {})
    end
    if reversed then
      table.insert(moved, 1, indent .. text)
    else
      moved[#moved + 1] = indent .. text
    end
    table.insert(moved, 1, indent .. ":" .. name .. ":")
    moved[#moved + 1] = indent .. ":END:"
    vim.api.nvim_buf_set_lines(bufnr, at, at, false, moved)
    return reversed and at + 2 or at + #moved - 1
  end
  -- above the first CLOCK line (above the last one without reversed order)
  local l = reversed and clock_lines[1] or clock_lines[#clock_lines]
  local ind = file.lines[l]:match("^(%s*)")
  vim.api.nvim_buf_set_lines(bufnr, l - 1, l - 1, false, { ind .. text })
  return l
end

--- Remove the drawer around line `lnum` when it is empty
--- (org-remove-empty-drawer-at).
local function remove_empty_drawer_around(bufnr, lnum)
  local prev = vim.api.nvim_buf_get_lines(bufnr, lnum - 2, lnum, false)
  if prev[1] and prev[2] and prev[1]:match("^%s*:[%w_%-]+:%s*$") and prev[2]:match("^%s*:END:%s*$") then
    vim.api.nvim_buf_set_lines(bufnr, lnum - 2, lnum, false, {})
  end
end

--- Delete the CLOCK line `lnum` and an empty drawer left around it.
local function delete_clock_line(bufnr, lnum)
  vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, {})
  remove_empty_drawer_around(bufnr, lnum)
end

--- Remember a clocked task in the history (newest first, no duplicates).
local function push_history(entry)
  local max = clock_cfg().history_length or 35
  local out = { entry }
  for _, h in ipairs(M.history) do
    if #out >= max then
      break
    end
    if not (h.path == entry.path and ((entry.id and h.id == entry.id) or h.title == entry.title)) then
      out[#out + 1] = h
    end
  end
  M.history = out
end

--- History entry for a headline.
local function task_of(bufnr, hl)
  return { path = buf_path(bufnr) or "", title = hl:plain_title(), id = hl.properties.ID }
end

--- The heading shown in the statusline (org-clock--mode-line-heading).
local function mode_line_heading(hl)
  local fn = clock_cfg().heading_function
  if type(fn) == "function" then
    local ok, s = pcall(fn, hl)
    if ok and type(s) == "string" then
      return s
    end
  end
  local t = vim.trim(hl.title):gsub("%[%[([^%]]-)%]%[([^%]]-)%]%]", "%2"):gsub("%[%[([^%]]-)%]%]", "%1")
  return t
end

-- Local functions and tables the parts below use
local shared = require("org.clock.shared")
shared.at_instant = at_instant
shared.at_minutes = at_minutes
shared.buf_path = buf_path
shared.clock_cfg = clock_cfg
shared.current_time = current_time
shared.delete_clock_line = delete_clock_line
shared.display_ns = display_ns
shared.fire = fire
shared.insert_clock_line = insert_clock_line
shared.instant_minutes = instant_minutes
shared.mark_ns = mark_ns
shared.mode_line_heading = mode_line_heading
shared.now_minutes = now_minutes
shared.persist = persist
shared.push_history = push_history
shared.state_in_buffer = state_in_buffer
shared.task_of = task_of
shared.unnamed = unnamed

-- In this order: a part takes the shared functions of the parts before it.
require("org.clock.timers")
require("org.clock.range")
require("org.clock.sum")
require("org.clock.clocktable")
require("org.clock.report")
require("org.clock.clocking")
require("org.clock.lines")
require("org.clock.resolve")
require("org.clock.modeline")
require("org.clock.display")
require("org.clock.persist")

return M
