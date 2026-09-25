---@mod org.clock Clocking work time
---
--- One clock runs at a time. Its state is `{ path, start (string), title,
--- effort, total }`; the open `CLOCK: [start]` line in `path` is the source
--- of truth, so the clock survives restarts (`restore()` finds it again).
---
--- User autocmds fire around clocking (the Emacs hooks): `OrgClockInPrepare`
--- (before the CLOCK line is written, `data = { bufnr, lnum }`),
--- `OrgClockIn`, `OrgClockOut`, `OrgClockCancel` and `OrgClockGoto`.

local config = require("org.config")
local date = require("org.date")
local edit = require("org.edit")
local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")

local M = {}

---@class org.ClockState
---@field path string
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
-- defined with the clock tables below
local clock_sum, iso_week_shift
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

--- A date (with time) for a number of minutes since the epoch.
local function at_minutes(m)
  m = math.floor(m)
  return date.from_days(math.floor(m / 1440)):add(m % 1440, "min"):clone({ active = false })
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
  local minutes = stop:minutes() - start:minutes()
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

--- Locate the open clock line of the running clock.
---@return integer|nil bufnr, integer|nil lnum
function M.find_open_clock()
  local st = M.state
  if not st then
    return nil
  end
  local bufnr = utils.find_buffer(st.path)
  if not bufnr then
    if not utils.exists(st.path) then
      return nil
    end
    bufnr = utils.load_buffer(st.path)
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local pat = "^%s*CLOCK:%s*" .. utils.escape_pattern(st.start) .. "%s*$"
  for i, l in ipairs(lines) do
    if l:match(pat) then
      return bufnr, i
    end
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
  local minutes = date.now():minutes() - start:minutes()
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
  local path = buf_path(bufnr)
  if not path or path ~= vim.fs.normalize(M.state.path) then
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

---------------------------------------------------------------------------
-- Time already clocked, effort and notifications
---------------------------------------------------------------------------

--- Start of the time counted in the statusline (org-clock-get-sum-start):
--- the CLOCK_MODELINE_TOTAL property or `clock.mode_line_total`, where
--- `auto` means since LAST_REPEAT for repeated tasks, else all time.
---@return integer|nil from minutes, nil for all time
---@return boolean current only the running clock counts
local function sum_start(hl)
  local cmt = hl:get_property("CLOCK_MODELINE_TOTAL", true) or clock_cfg().mode_line_total or "auto"
  local lr = hl.properties.LAST_REPEAT
  lr = lr and date.parse(lr)
  if cmt == "current" then
    return nil, true
  elseif cmt == "today" then
    return date.today():minutes(), false
  elseif cmt == "all" or ((cmt == "auto" or cmt == "") and not lr) then
    return nil, false
  elseif cmt == "repeat" or cmt == "auto" or cmt == "" then
    return lr and lr:minutes() or nil, false
  end
  return nil, false
end

local SUM_TEXT = {
  current = "showing time in current clock instance",
  today = "showing today's task time.",
  all = "showing entire task time.",
  ["repeat"] = "showing task time since last repeat.",
}

--- Minutes clocked in the entry's subtree before a clock starts.
local function total_before(hl)
  local from, current = sum_start(hl)
  if current then
    return 0, SUM_TEXT.current
  end
  local cmt = hl:get_property("CLOCK_MODELINE_TOTAL", true) or clock_cfg().mode_line_total or "auto"
  local text = SUM_TEXT[cmt] or (from and SUM_TEXT["repeat"] or SUM_TEXT.all)
  return M.sum_minutes(hl, from, nil), text
end

--- Notify through `clock.notification_handler` (a function or a program),
--- else vim.notify, and play `clock.sound` (org-notify).
function M.notify(msg)
  local cfg = clock_cfg()
  local handler = cfg.notification_handler
  if type(handler) == "function" then
    pcall(handler, msg)
  elseif type(handler) == "string" and handler ~= "" then
    pcall(vim.system, { handler, msg }, { detach = true })
  else
    utils.notify(msg, vim.log.levels.WARN)
  end
  local sound = cfg.sound
  if sound == true then
    -- the terminal bell
    pcall(vim.api.nvim_chan_send, vim.v.stderr, "\7")
  elseif type(sound) == "string" and sound ~= "" then
    local file = vim.fn.expand(sound)
    for _, player in ipairs({ "afplay", "paplay", "aplay" }) do
      if vim.fn.executable(player) == 1 then
        pcall(vim.system, { player, file }, { detach = true })
        break
      end
    end
  end
end

local notified = false

--- Notify once when the clocked time reaches the effort
--- (org-clock-notify-once-if-expired).
local function check_effort()
  local a = M.active()
  if not a or not a.overrun then
    notified = false
    return
  end
  if not notified and clock_cfg().notify_effort ~= false then
    notified = true
    M.notify(string.format("Task '%s' should be finished by now. (%s)", a.title, date.duration_to_string(a.effort)))
  end
end

---------------------------------------------------------------------------
-- Timers: statusline refresh, effort, idle time, auto clock-out
---------------------------------------------------------------------------

local tick_timer, auto_timer
local last_activity = vim.uv.now()
local on_key_ns

local function track_activity()
  if on_key_ns then
    return
  end
  on_key_ns = vim.on_key(function()
    last_activity = vim.uv.now()
  end, vim.api.nvim_create_namespace("org.clock.activity"))
end

local function stop_timer(t)
  if t then
    t:stop()
    t:close()
  end
end

--- Seconds since the user last did something (org-user-idle-seconds): the
--- system idle time on macOS (ioreg) and X11 (xprintidle) once Neovim
--- itself has been idle that long, else Neovim's idle time.
---@param threshold? number seconds; the system is only asked above it
function M.user_idle_seconds(threshold)
  local idle = (vim.uv.now() - last_activity) / 1000
  if threshold and idle < threshold then
    return idle
  end
  local sys
  if vim.fn.has("mac") == 1 then
    local ok, res = pcall(function()
      return vim.system({ "ioreg", "-c", "IOHIDSystem" }, { text = true }):wait(2000)
    end)
    local ns = ok and res and res.stdout and res.stdout:match('"HIDIdleTime"%s*=%s*(%d+)')
    sys = ns and tonumber(ns) / 1e9
  elseif vim.env.DISPLAY and vim.fn.executable("xprintidle") == 1 then
    local ok, res = pcall(function()
      return vim.system({ "xprintidle" }, { text = true }):wait(2000)
    end)
    local ms = ok and res and res.stdout and tonumber(vim.trim(res.stdout))
    sys = ms and ms / 1000
  end
  return sys or idle
end

local resolving = false

--- Every minute while clocking: refresh the statusline, check the effort
--- and whether the user has been idle for `clock.idle_time` minutes
--- (org-resolve-clocks-if-idle).
local function tick()
  if not M.state then
    return
  end
  check_effort()
  vim.cmd("redrawstatus")
  local idle_min = tonumber(clock_cfg().idle_time)
  if idle_min and idle_min > 0 and not resolving then
    local idle = M.user_idle_seconds(idle_min * 60)
    if idle > idle_min * 60 then
      local bufnr, lnum = M.find_open_clock()
      if bufnr then
        local idle_start = date.now():minutes() - idle / 60
        M.resolve({ bufnr = bufnr, lnum = lnum, start = date.parse(M.state.start), active = true }, function()
          return string.format(
            "Clocked in & idle for %.1f mins",
            (date.now():minutes() + os.date("*t").sec / 60 - idle_start)
          )
        end, idle_start, { idle = true })
      end
    end
  end
end

-- for tests: run the minute tick now
M._tick = function()
  tick()
end

local function start_timers()
  stop_timer(tick_timer)
  tick_timer = vim.uv.new_timer()
  tick_timer:start(60000, 60000, vim.schedule_wrap(tick))
  track_activity()
  check_effort()
  stop_timer(auto_timer)
  auto_timer = nil
  local secs = tonumber(clock_cfg().auto_clockout_timer)
  if secs and secs > 0 and M.auto_clockout_enabled ~= false then
    -- org-clock-auto-clockout: clock out once idle for `secs` seconds
    auto_timer = vim.uv.new_timer()
    local period = math.max(1000, math.min(secs * 250, 30000))
    auto_timer:start(period, period, vim.schedule_wrap(function()
      if M.state and M.user_idle_seconds(secs) >= secs then
        M.clock_out({})
      end
    end))
  end
end

local function stop_timers()
  stop_timer(tick_timer)
  stop_timer(auto_timer)
  tick_timer, auto_timer = nil, nil
end

--- Turn auto clock-out after `clock.auto_clockout_timer` seconds of idle
--- time on or off for this session (org-clock-toggle-auto-clockout).
function M.toggle_auto_clockout()
  M.auto_clockout_enabled = M.auto_clockout_enabled == false
  if M.state then
    start_timers()
  end
  utils.notify("Auto clock-out after idle time turned " .. (M.auto_clockout_enabled and "on" or "off"))
  return M.auto_clockout_enabled
end

local exit_hooked = false

--- Ask to clock out before leaving Neovim (org-clock-ask-before-exiting).
local function hook_exit()
  if exit_hooked then
    return
  end
  exit_hooked = true
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = utils.augroup,
    callback = function()
      if M.state and clock_cfg().ask_before_exiting and utils.confirm("Clock out before exiting?") then
        local bufnr = M.find_open_clock()
        M.clock_out({})
        if bufnr then
          utils.save_buffer(bufnr)
        end
      end
    end,
  })
end

---------------------------------------------------------------------------
-- Clock out / cancel
---------------------------------------------------------------------------

--- Clock out of the running clock. Interactively (no `opts`) with a
--- count, ask for the TODO state to switch the task to (org-clock-out with
--- C-u); otherwise `clock.out_switch_to_state` applies.
---@param opts? { at?: table, switch_to_state?: string|false, note?: string|false }
function M.clock_out(opts)
  local interactive = type(opts) ~= "table"
  opts = type(opts) == "table" and opts or {}
  if not M.state then
    if not opts.quiet then
      utils.notify("No active clock")
    end
    return nil
  end
  local bufnr, lnum = M.find_open_clock()
  local st = M.state
  M.state = nil
  stop_timers()
  persist()
  if not bufnr then
    utils.warn("Clock start time is gone: " .. st.title)
    vim.cmd("redrawstatus")
    return nil
  end
  local switch = opts.switch_to_state
  if switch == nil then
    if interactive and vim.v.count > 0 then
      local todo_cfg = files.get_buffer(bufnr).settings.todo
      switch = utils.input_complete("Switch to state: ", todo_cfg:names(), "DONE")
    else
      switch = clock_cfg().out_switch_to_state
    end
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  local indent = line:match("^(%s*)")
  local clocked = files.get_buffer(bufnr):headline_at(lnum)
  local start = date.parse(st.start)
  local stop = (opts.at or current_time()):clone({ active = false })
  local new, minutes = M.format_clock_line(indent, start, stop)
  local removed = minutes == 0 and clock_cfg().out_remove_zero_time == true
  local hl_mark = clocked and vim.api.nvim_buf_set_extmark(bufnr, mark_ns, clocked.line - 1, 0, {})
  local clock_mark
  if removed then
    delete_clock_line(bufnr, lnum)
  else
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new })
    clock_mark = vim.api.nvim_buf_set_extmark(bufnr, mark_ns, lnum - 1, 0, {})
  end
  if M.last and M.last.path == st.path then
    M.last = vim.tbl_extend("force", M.last, { out = stop:to_string() })
  else
    M.last = { path = st.path, title = st.title, out = stop:to_string() }
  end
  persist()
  -- org-clock-out-switch-to-state (without clocking out again on DONE)
  local hl_line = hl_mark and vim.api.nvim_buf_get_extmark_by_id(bufnr, mark_ns, hl_mark, {})[1] + 1
  local hl = hl_line and files.get_buffer(bufnr):headline_on(hl_line)
  if hl then
    if type(switch) == "function" then
      switch = switch(hl.todo)
    end
    if type(switch) == "string" and switch ~= "" and hl.todo ~= switch then
      require("org.todo").change_state({ bufnr = bufnr, lnum = hl.line }, switch)
    end
  end
  utils.notify(
    string.format(
      removed and "Clock stopped at %s after %s => LINE REMOVED" or "Clock stopped at %s after %s",
      stop:to_string(),
      date.duration_to_string(minutes)
    )
  )
  fire("OrgClockOut", { path = st.path, title = st.title, minutes = minutes, removed = removed })
  -- org-log-note-clock-out: the note goes right below the CLOCK line
  if clock_mark and opts.note ~= false then
    local cl = vim.api.nvim_buf_get_extmark_by_id(bufnr, mark_ns, clock_mark, {})[1] + 1
    hl = files.get_buffer(bufnr):headline_at(cl)
    if require("org.todo").log_setting(files.get_buffer(bufnr), "clock_out", hl) == "note" then
      local note = opts.note or utils.input({ prompt = "Clock-out note (" .. st.title .. "): " })
      if note and vim.trim(note) ~= "" then
        local note_lines = vim.split(note, "\n")
        local out = { indent .. "- " .. note_lines[1] }
        for i = 2, #note_lines do
          out[#out + 1] = indent .. "  " .. note_lines[i]
        end
        vim.api.nvim_buf_set_lines(bufnr, cl, cl, false, out)
      end
    end
  end
  for _, m in ipairs({ hl_mark, clock_mark }) do
    pcall(vim.api.nvim_buf_del_extmark, bufnr, mark_ns, m)
  end
  vim.cmd("redrawstatus")
  return minutes
end

--- Cancel the running clock (remove the open CLOCK line).
function M.clock_cancel()
  if not M.state then
    utils.notify("No active clock")
    return nil
  end
  local bufnr, lnum = M.find_open_clock()
  local st = M.state
  M.state = nil
  stop_timers()
  persist()
  if bufnr then
    delete_clock_line(bufnr, lnum)
    utils.notify("Clock canceled")
  else
    utils.notify("Clock gone, cancel the timer anyway")
  end
  fire("OrgClockCancel", { path = st.path, title = st.title })
  vim.cmd("redrawstatus")
  return true
end

---------------------------------------------------------------------------
-- Picking tasks
---------------------------------------------------------------------------

--- Find the headline of a clocked-task entry (by ID, then title).
---@return integer|nil bufnr, integer|nil lnum
local function find_entry(task)
  if not task or not utils.exists(task.path) then
    return nil
  end
  local bufnr = utils.load_buffer(task.path)
  local file = files.get_buffer(bufnr)
  local hl = task.id and file:find_by_id(task.id) or nil
  hl = hl or file:find_by_title(task.title)
  if not hl then
    return nil
  end
  return bufnr, hl.line
end

--- The running clock as a task entry.
local function current_task()
  local bufnr, lnum = M.find_open_clock()
  if not bufnr then
    return nil
  end
  local hl = files.get_buffer(bufnr):headline_at(lnum)
  return hl and task_of(bufnr, hl)
end

--- The running clock's task `{ path, title, id }`, or nil.
function M.current_task()
  return M.state and current_task() or nil
end

--- Clock into a task entry `{ path, title, id }` (e.g. one returned by
--- `current_task`), found by ID or title.
function M.clock_in_task(task, opts)
  local bufnr, lnum = find_entry(task)
  if not bufnr then
    utils.warn("Cannot find task: " .. tostring(task and task.title))
    return nil
  end
  return M.clock_in({ bufnr = bufnr, lnum = lnum }, vim.tbl_extend("force", { no_count = true }, opts or {}))
end

--- Record a closed clock [start, stop] in the entry at (bufnr, lnum),
--- placed like clock_in places CLOCK lines. Returns the minutes, or nil
--- when a zero-length clock was dropped (`clock.out_remove_zero_time`).
function M.add_clock(bufnr, lnum, start, stop)
  local text, minutes = M.format_clock_line("", start, stop)
  if minutes == 0 and clock_cfg().out_remove_zero_time == true then
    return nil
  end
  insert_clock_line(bufnr, lnum, vim.trim(text))
  return minutes
end

--- Pick a task among the default, interrupted, current and recent tasks
--- (org-clock-select-task). Returns bufnr, lnum of its headline.
---@param prompt? string
---@return integer|nil bufnr, integer|nil lnum
function M.select_task(prompt)
  local items = {}
  local function add(key, task)
    local bufnr, lnum = find_entry(task)
    if not bufnr then
      return false
    end
    local hl = files.get_buffer(bufnr):headline_at(lnum)
    items[#items + 1] = {
      key = key,
      label = string.format("%-12s  %s", hl:get_category(), hl:plain_title()),
      value = { bufnr = bufnr, lnum = lnum },
    }
    return true
  end
  local function heading(text)
    items[#items + 1] = { heading = true, label = text }
  end
  local function section(text, key, task)
    if task then
      heading(text)
      if not add(key, task) then
        items[#items] = nil
      end
    end
  end
  section("Default Task", "d", M.default_task)
  section("The task interrupted by starting the last one", "i", M.interrupted)
  section("Current Clocking Task", "c", M.state and current_task() or nil)
  local recent, prev = {}, nil
  for _, h in ipairs(M.history) do
    if not (prev and prev.path == h.path and prev.title == h.title) then
      recent[#recent + 1] = h
    end
    prev = h
  end
  if #recent == 0 then
    utils.notify("No recent clock")
    return nil
  end
  heading("Recent Tasks")
  local n = 0
  for _, h in ipairs(recent) do
    local key = n < 9 and tostring(n + 1) or string.char(("A"):byte() + n - 9)
    if n < 35 and add(key, h) then
      n = n + 1
    end
  end
  local choice = require("org.ui").menu({ title = prompt or "Select task for clocking", items = items })
  if type(choice) ~= "table" or not choice.bufnr then
    return nil
  end
  return choice.bufnr, choice.lnum
end

--- Clock in a task picked from the clock history (org-clock-in with C-u).
function M.clock_in_select()
  local bufnr, lnum = M.select_task("Clock-in on task")
  if not bufnr then
    return nil
  end
  return M.clock_in({ bufnr = bufnr, lnum = lnum }, { no_count = true })
end

--- Mark the entry at the cursor as the default task (org-clock-mark-default-task).
function M.mark_default_task(target)
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  M.default_task = task_of(bufnr, hl)
  utils.notify("Default clocking task: " .. M.default_task.title)
  return M.default_task
end

---------------------------------------------------------------------------
-- Clock in
---------------------------------------------------------------------------

--- Start clocking the headline at target (org-clock-in). Interactively
--- (no target) a count picks a task from the history (C-u), 16 also marks
--- the entry at the cursor as the default task (C-u C-u), and 64 starts
--- the clock where the last one stopped (C-u C-u C-u).
---@param target? org.Target
---@param opts? { at?: table, resume?: boolean, switch_to_state?: string, no_count?: boolean }
function M.clock_in(target, opts)
  opts = opts or {}
  local count = (target == nil and not opts.at and not opts.no_count) and vim.v.count or 0
  if count >= 64 then
    local out = M.last and M.last.out and date.parse(M.last.out)
    return M.clock_in(nil, { at = out or nil, no_count = true, continuous = true })
  elseif count > 0 and count < 16 then
    return M.clock_in_select()
  end
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  if count >= 16 then
    M.mark_default_task({ bufnr = bufnr, lnum = hl.line })
  end
  local mark = vim.api.nvim_buf_set_extmark(bufnr, mark_ns, hl.line - 1, 0, {})
  local function target_line()
    return vim.api.nvim_buf_get_extmark_by_id(bufnr, mark_ns, mark, {})[1] + 1
  end
  local interrupting = M.state ~= nil and not opts.resolving_idle
  local leftover = not resolving and M.leftover
  -- org-clock-auto-clock-resolution: resolve dangling clocks first
  local auto = clock_cfg().auto_clock_resolution
  if auto == nil then
    auto = "when-no-clock-is-running"
  end
  if auto and (not interrupting or auto == true) and not resolving and not opts.clocking_in then
    M.leftover = nil
    M.resolve_clocks(false, { clocking_in = true, quiet = true })
  end
  if M.state and M.is_clocked_headline(bufnr, target_line()) then
    vim.api.nvim_buf_del_extmark(bufnr, mark_ns, mark)
    utils.notify("Clock continues in " .. M.state.title)
    return nil
  end
  if M.state then
    M.interrupted = current_task()
    M.clock_out({ switch_to_state = opts.out_switch_to_state, note = opts.note, quiet = true })
  else
    M.interrupted = nil
  end
  local lnum = target_line()
  fire("OrgClockInPrepare", { bufnr = bufnr, lnum = lnum })
  lnum = target_line()
  local file = files.get_buffer(bufnr)
  hl = file:headline_at(lnum)
  push_history(task_of(bufnr, hl))
  -- org-clock-in-switch-to-state
  local switch = opts.switch_to_state or clock_cfg().in_switch_to_state
  if type(switch) == "function" then
    switch = switch(hl.todo)
  end
  if type(switch) == "string" and switch ~= "" and hl.todo ~= switch and file.settings.todo:is_keyword(switch) then
    require("org.todo").change_state({ bufnr = bufnr, lnum = lnum }, switch)
    lnum = target_line()
  end
  vim.api.nvim_buf_del_extmark(bufnr, mark_ns, mark)
  hl = files.get_buffer(bufnr):headline_at(lnum)
  local start_str
  local resume = opts.resume or clock_cfg().in_resume
  if resume then
    for _, c in ipairs(hl.clocks) do
      if not c["end"] then
        -- org-clock-in-resume: continue the entry's open clock
        start_str = c.start:clone({ active = false }):to_string({ range = false })
        break
      end
    end
  end
  local total, sum_text = total_before(hl)
  if not start_str then
    local start
    local continuous = clock_cfg().continuously or opts.continuous
    local out = continuous and M.last and M.last.out and date.parse(M.last.out)
    if out and out:minutes() <= date.now():minutes() then
      start = out
    elseif leftover then
      local ago = date.now():minutes() - leftover
      if
        utils.confirm(string.format("You stopped another clock %d mins ago; start this one from then?", ago))
      then
        start = at_minutes(leftover)
      end
      M.leftover = nil
    end
    start = (start or opts.at or current_time(true)):clone({ active = false })
    start_str = start:to_string({ range = false })
    insert_clock_line(bufnr, lnum, "CLOCK: " .. start_str)
    hl = files.get_buffer(bufnr):headline_at(lnum)
  end
  M.state = {
    path = buf_path(bufnr) or "",
    start = start_str,
    title = mode_line_heading(hl),
    effort = require("org.properties").effort_minutes(hl),
    total = total,
  }
  M.last = { path = M.state.path, title = hl:plain_title(), id = hl.properties.ID }
  notified = false
  persist()
  start_timers()
  hook_exit()
  utils.notify("Clock starts at " .. start_str .. " - " .. sum_text)
  fire("OrgClockIn", { bufnr = bufnr, lnum = lnum, title = M.state.title })
  vim.cmd("redrawstatus")
  return M.state
end

--- Clock in the most recently clocked task (org-clock-in-last). With a
--- count: pick from the history (C-u), start where the last clock stopped
--- (16, C-u C-u), or ask for the TODO state to switch to (64).
function M.clock_in_last()
  local count = vim.v.count
  if count > 0 and count < 16 then
    return M.clock_in_select()
  end
  local task = M.history[1] or M.last
  if not task then
    utils.notify("No last clock")
    return nil
  end
  local bufnr, lnum = find_entry(task)
  if not bufnr then
    utils.notify("No last clock")
    return nil
  end
  local opts = { no_count = true }
  if count == 16 then
    local out = M.last and M.last.out and date.parse(M.last.out)
    opts.at, opts.continuous = out or nil, true
  elseif count >= 64 and not M.state then
    local todo_cfg = files.get_buffer(bufnr).settings.todo
    local s = utils.input_complete("Switch to state: ", todo_cfg:names())
    if s and s ~= "" then
      opts.switch_to_state = s
    end
  end
  local already = M.state ~= nil
  local res = M.clock_in({ bufnr = bufnr, lnum = lnum }, opts)
  if res and not already then
    utils.notify(string.format("Clocking back: %s (in %s)", res.title, vim.fn.fnamemodify(res.path, ":t")))
  end
  return res
end

--- Jump to the running (or last) clocked task (org-clock-goto). With a
--- count, pick the task from the history.
function M.goto_clock()
  local bufnr, lnum
  local recent = false
  if vim.v.count > 0 then
    bufnr, lnum = M.select_task("Select task to go to")
    if not bufnr then
      utils.notify("No task selected")
      return nil
    end
  elseif M.state then
    local b, l = M.find_open_clock()
    if b then
      local hl = files.get_buffer(b):headline_at(l)
      bufnr, lnum = b, hl and hl.line or l
    end
  end
  if not bufnr and clock_cfg().goto_may_find_recent_task ~= false then
    bufnr, lnum = find_entry(M.history[1] or M.last)
    recent = bufnr ~= nil
  end
  if not bufnr then
    utils.notify("No active or recent clock task")
    return nil
  end
  utils.open_file(vim.api.nvim_buf_get_name(bufnr), lnum)
  -- org-clock-goto-before-context: lines shown above the entry
  local context = tonumber(clock_cfg().goto_before_context) or 2
  pcall(vim.fn.winrestview, { topline = math.max(1, lnum - context) })
  if recent then
    utils.notify("No running clock, this is the most recently clocked task")
  end
  fire("OrgClockGoto", { bufnr = bufnr, lnum = lnum })
  return true
end

---------------------------------------------------------------------------
-- Clock lines
---------------------------------------------------------------------------

--- Recompute the duration of a CLOCK line (org-clock-update-time-maybe).
--- When `old_line` (the line before an edit) was the running clock's open
--- line, the running clock follows its new start.
---@param old_line? string
function M.update_clock_line(bufnr, lnum, old_line)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  local c = line and parser.parse_clock_line(line)
  if not c then
    return false
  end
  if not c["end"] then
    local st = M.state
    if
      st
      and old_line
      and buf_path(bufnr) == vim.fs.normalize(st.path)
      and old_line:match("^%s*CLOCK:%s*" .. utils.escape_pattern(st.start) .. "%s*$")
    then
      st.start = c.start:clone({ active = false }):to_string({ range = false })
      persist()
      vim.cmd("redrawstatus")
    end
    return true
  end
  local new = M.format_clock_line(line:match("^(%s*)"), c.start, c["end"])
  if new ~= line then
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new })
  end
  return true
end

--- Shift both timestamps of the CLOCK line at the cursor by `n` units of
--- the part under the cursor, keeping the duration (org-clock-timestamps-up
--- / -down, C-S-Up / C-S-Down). On an open clock only its timestamp moves.
--- Returns false when not on a CLOCK line.
---@param n integer
function M.timestamps_shift(n)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  local c = parser.parse_clock_line(line)
  if not c then
    return false
  end
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local s1 = line:find("[", 1, true)
  if col < s1 then
    vim.api.nvim_win_set_cursor(0, { lnum, s1 })
  end
  if not c["end"] then
    -- an open clock: only its timestamp (the running clock follows it)
    return require("org.timestamps").increment(n) ~= false
  end
  local s2 = line:find("--[", 1, true)
  local on_end = col > s2 + 1
  if not require("org.timestamps").increment(n) then
    return false
  end
  local new = parser.parse_clock_line(vim.api.nvim_get_current_line())
  if not new or not new["end"] then
    return true
  end
  local start, stop = new.start, new["end"]
  if on_end then
    start = start:add(stop:minutes() - c["end"]:minutes(), "min")
  else
    stop = stop:add(start:minutes() - c.start:minutes(), "min")
  end
  local text = M.format_clock_line(line:match("^(%s*)"), start, stop)
  local cursor = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { text })
  vim.api.nvim_win_set_cursor(0, { lnum, math.min(cursor[2], #text - 1) })
  return true
end

--- On a CLOCK line, change the timestamp at the cursor by `n` (like
--- S-Up/S-Down) and move the touching timestamp of the neighbouring task in
--- the clock history by the same amount: the previous task's clock-out when
--- changing a clock-in, the next task's clock-in when changing a clock-out
--- (org-shiftmetaup / org-shiftmetadown on clock lines). Returns false when
--- not on a CLOCK timestamp.
---@param n integer
function M.timestamps_adjust_closest(n)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local c = parser.parse_clock_line(line)
  local s1 = line:find("[", 1, true)
  if not c or not s1 or col + 1 < s1 then
    return false
  end
  local s2 = line:find("--[", 1, true)
  local on_start = not s2 or col + 1 < s2
  local before = on_start and c.start:minutes() or c["end"]:minutes()
  if not require("org.timestamps").increment(n) then
    return false
  end
  local new = parser.parse_clock_line(vim.api.nvim_get_current_line())
  local delta = (on_start and new.start:minutes() or (new["end"] and new["end"]:minutes() or before)) - before
  local hl = files.get_buffer(bufnr):headline_at(lnum)
  if #M.history < 2 or not hl or delta == 0 then
    utils.notify("No clock to adjust")
    return true
  end
  local path = buf_path(bufnr)
  local idx
  for i, h in ipairs(M.history) do
    if h.path == path and ((h.id and h.id == hl.properties.ID) or h.title == hl:plain_title()) then
      idx = i
      break
    end
  end
  -- the history is newest first: the previous task is the next entry
  local other = idx and M.history[idx + (on_start and 1 or -1)]
  local obuf, olnum = find_entry(other)
  if not obuf then
    utils.notify("No clock to adjust")
    return true
  end
  local ohl = files.get_buffer(obuf):headline_at(olnum)
  local clocks = vim.deepcopy(ohl.clocks)
  table.sort(clocks, function(a, b)
    return a.line < b.line
  end)
  for _, oc in ipairs(clocks) do
    if not on_start or oc["end"] then
      local l = vim.api.nvim_buf_get_lines(obuf, oc.line - 1, oc.line, false)[1]
      local indent = l:match("^(%s*)")
      local text
      if on_start then
        text = M.format_clock_line(indent, oc.start, oc["end"]:add(delta, "min"))
      elseif oc["end"] then
        text = M.format_clock_line(indent, oc.start:add(delta, "min"), oc["end"])
      else
        text = indent .. "CLOCK: " .. oc.start:add(delta, "min"):clone({ active = false }):to_string({ range = false })
      end
      vim.api.nvim_buf_set_lines(obuf, oc.line - 1, oc.line, false, { text })
      M.update_clock_line(obuf, oc.line, l)
      utils.notify(
        string.format(
          "Clock adjusted in %s for heading: %s",
          vim.fn.fnamemodify(vim.api.nvim_buf_get_name(obuf), ":t"),
          ohl:plain_title()
        )
      )
      return true
    end
  end
  utils.notify("No clock to adjust")
  return true
end

--- Shift the `:block` of the clocktable whose `#+BEGIN:` line is at the
--- cursor by `n` periods and update it (org-clocktable-shift, S-arrows):
--- today → today-1, 2026-W39 → 2026-W40, 2026-Q3 → 2026-Q4, ...
--- Returns false when not on a clocktable line.
---@param n integer negative = towards the past
function M.clocktable_shift(n)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  if not line:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]:%s+clocktable%f[%W]") then
    return false
  end
  local s = line:match(":block%s+()%S")
  if not s then
    utils.warn("Line needs a :block definition before this command works")
    return true
  end
  local e = line:find("%s", s) or #line + 1
  local block = line:sub(s, e - 1)
  local alias = {
    yesterday = "today-1",
    lastweek = "thisweek-1",
    lastmonth = "thismonth-1",
    lastyear = "thisyear-1",
    lastq = "thisq-1",
  }
  block = alias[block] or block
  local ins
  local base, shift = block:match("^(%a+)([-+]%d+)$")
  base = base or block
  if base == "today" or base == "thisweek" or base == "thismonth" or base == "thisyear" or base == "thisq" then
    local k = (tonumber(shift) or 0) + n
    ins = k == 0 and base or string.format("%s%+d", base, k)
  else
    local y, rest = block:match("^(%d+)(.*)$")
    y = tonumber(y)
    if not y then
      utils.warn("Cannot shift clocktable block")
      return true
    end
    local dm, dd = rest:match("^%-(%d%d?)%-(%d%d?)$")
    local w = rest:match("^%-[wW](%d%d?)$")
    local q = rest:match("^%-[qQ](%d)$")
    local mo = rest:match("^%-(%d%d?)$")
    if dm then
      local d = date.from_days(date.days_from_civil(y, tonumber(dm), tonumber(dd)) + n)
      ins = string.format("%04d-%02d-%02d", d.year, d.month, d.day)
    elseif w then
      local iy, iw = iso_week_shift(y, tonumber(w), n)
      ins = string.format("%d-W%02d", iy, iw)
    elseif q then
      local idx = tonumber(q) - 1 + n
      ins = string.format("%d-Q%d", y + math.floor(idx / 4), idx % 4 + 1)
    elseif mo then
      local total = y * 12 + tonumber(mo) - 1 + n
      ins = string.format("%04d-%02d", math.floor(total / 12), total % 12 + 1)
    elseif rest == "" then
      ins = tostring(y + n)
    else
      utils.warn("Cannot shift clocktable block")
      return true
    end
  end
  vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { line:sub(1, s - 1) .. ins .. line:sub(e) })
  require("org.dblock").update_at_cursor()
  return true
end

--- Insert a clock table, or update the one at the cursor (org-clock-report).
--- The new table covers the entry at the cursor (:scope subtree), or the
--- file before the first headline, with `clock.clocktable_default` settings.
--- With a count, update the first clock table of the buffer instead.
function M.clock_report()
  local dblock = require("org.dblock")
  local bufnr = vim.api.nvim_get_current_buf()
  M.remove_overlays(bufnr)
  if vim.v.count > 0 then
    for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if l:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]:%s+clocktable%f[%W]") then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        vim.cmd("normal! zv")
        break
      end
    end
  end
  local existing = dblock.at_cursor()
  if existing and existing.name:lower() == "clocktable" then
    return dblock.update_block(bufnr, existing)
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  local before_first = files.get_buffer(bufnr):headline_at(lnum) == nil
  local defaults = clock_cfg().clocktable_default or {}
  local header = "#+BEGIN: clocktable :scope " .. (before_first and "file" or "subtree")
  header = header .. " :maxlevel " .. tostring(defaults.maxlevel or 2)
  -- org-create-dblock: on a non-blank line, the block goes below it
  local at = line:match("%S") and lnum or lnum - 1
  local indent = line:match("%S") and "" or line:match("^(%s*)")
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, { indent .. header, indent .. "#+END:" })
  vim.api.nvim_win_set_cursor(0, { at + 1, 0 })
  return dblock.update_block(bufnr, dblock.find_at(bufnr, at + 1))
end

---------------------------------------------------------------------------
-- Resolving open clocks
---------------------------------------------------------------------------

--- Open CLOCK lines in the agenda files and loaded org buffers:
--- list of { bufnr, lnum, start, title, active }. The running clock is
--- included only with `with_active`.
function M.dangling_clocks(with_active)
  local out, seen = {}, {}
  local running_buf, running_lnum = M.find_open_clock()
  local function scan(bufnr)
    if seen[bufnr] then
      return
    end
    seen[bufnr] = true
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, l in ipairs(lines) do
      local c = l:find("CLOCK:", 1, true) and parser.parse_clock_line(l)
      local active = bufnr == running_buf and i == running_lnum
      if c and not c["end"] and (with_active or not active) then
        local hl = files.get_buffer(bufnr):headline_at(i)
        out[#out + 1] = {
          bufnr = bufnr,
          lnum = i,
          start = c.start,
          title = hl and hl:plain_title() or "?",
          active = active,
        }
      end
    end
  end
  for _, f in ipairs(files.agenda_files()) do
    if f.filename and utils.exists(f.filename) then
      scan(utils.load_buffer(f.filename))
    end
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "org" then
      scan(b)
    end
  end
  return out
end

--- Close the open CLOCK line of `clock` at `stop` (minutes).
local function close_clock(clock, stop)
  if clock.active then
    return M.clock_out({ at = at_minutes(stop), quiet = true })
  end
  -- like org-with-clock: clock out of the dangling clock as if it were the
  -- running one (state switch, note, 0:00 removal), then restore the
  -- running clock
  local lnum = vim.api.nvim_buf_get_extmark_by_id(clock.bufnr, mark_ns, clock.mark, {})[1] + 1
  local hl = files.get_buffer(clock.bufnr):headline_at(lnum)
  local saved = M.state
  M.state = {
    path = buf_path(clock.bufnr) or "",
    start = clock.start:clone({ active = false }):to_string({ range = false }),
    title = hl and mode_line_heading(hl) or "?",
  }
  local ok, err = pcall(M.clock_out, { at = at_minutes(stop), quiet = true })
  M.state = saved
  if saved then
    persist()
    start_timers()
  end
  if not ok then
    error(err, 0)
  end
end

--- Apply a resolution to an open clock (org-clock-resolve-clock).
--- `to` is nil (cancel), "now", or a time in minutes.
local function resolve_clock(clock, to, out_time, close, restart, ctx)
  local head = clock.head
  local function heading_target()
    local l = vim.api.nvim_buf_get_extmark_by_id(clock.bufnr, mark_ns, head, {})[1] + 1
    return { bufnr = clock.bufnr, lnum = l }
  end
  if to == nil then
    if clock.active then
      M.clock_cancel()
    else
      local lnum = vim.api.nvim_buf_get_extmark_by_id(clock.bufnr, mark_ns, clock.mark, {})[1] + 1
      delete_clock_line(clock.bufnr, lnum)
    end
    if restart and not ctx.clocking_in then
      M.clock_in(heading_target(), { no_count = true, clocking_in = true })
    end
  elseif to == "now" then
    if close or ctx.clocking_in then
      close_clock(clock, date.now():minutes())
    elseif not clock.active then
      M.clock_in(heading_target(), { resume = true, no_count = true, clocking_in = true })
    end
  else
    close_clock(clock, out_time or to)
    if ctx.clocking_in then
      return
    elseif close then
      M.leftover = not out_time and math.floor(to) or nil
    else
      M.clock_in(heading_target(), {
        at = out_time and at_minutes(to) or nil,
        no_count = true,
        clocking_in = true,
        resolving_idle = ctx.idle,
      })
    end
  end
end

--- Ask how to resolve an open clock (org-clock-resolve). `clock` is
--- `{ bufnr, lnum, start, active }`, `prompt` a function returning the
--- question, `last_valid` (minutes) the last time the clock was known to be
--- valid (its start for a dangling clock, the start of the idle time).
---
--- Keys: k/K keep N minutes, t/T keep until a time, g/G got back N minutes
--- ago, s/S subtract the idle time, C cancel, j/J jump, i/q ignore.
--- Uppercase leaves the clock stopped.
---@param opts? { clocking_in?: boolean, idle?: boolean }
function M.resolve(clock, prompt, last_valid, opts)
  opts = opts or {}
  local ui = require("org.ui")
  clock.mark = vim.api.nvim_buf_set_extmark(clock.bufnr, mark_ns, clock.lnum - 1, 0, {})
  local hl = files.get_buffer(clock.bufnr):headline_at(clock.lnum)
  clock.head = vim.api.nvim_buf_set_extmark(clock.bufnr, mark_ns, (hl and hl.line or clock.lnum) - 1, 0, {})
  resolving = true
  local ok, err = pcall(function()
    local title = prompt(clock) .. (hl and (": " .. hl:plain_title()) or "")
    local ch = ui.menu({
      title = title,
      items = {
        { key = "k", label = "Keep X minutes of the idle time (default all), stay clocked in", value = "k" },
        { key = "K", label = "Keep X minutes, then clock out", value = "K" },
        { key = "t", label = "Keep the time until a given time, stay clocked in", value = "t" },
        { key = "T", label = "Keep the time until a given time, then clock out", value = "T" },
        { key = "g", label = "Got back X minutes ago (clock in again from then)", value = "g" },
        { key = "G", label = "Got back X minutes ago, stay clocked out", value = "G" },
        { key = "s", label = "Subtract the idle time, clock in again now", value = "s" },
        { key = "S", label = "Subtract the idle time, then clock out", value = "S" },
        { key = "C", label = "Cancel the clock altogether", value = "C" },
        { key = "j", label = "Jump to the clock", value = "j" },
        { key = "J", label = "Clock out now and jump to the clock", value = "J" },
        { key = "i", label = "Ignore (keep all the idle time)", value = "i" },
        { key = "q", label = "Quit", value = "q" },
      },
    })
    if ch == nil or ch == "i" or ch == "q" then
      return
    end
    local now = date.now():minutes()
    local default = math.floor(now - last_valid)
    local keep, gotback
    if ch == "k" or ch == "K" then
      local v = utils.input({ prompt = string.format("Keep how many minutes (default %d): ", default) })
      if v == nil then
        return
      end
      keep = tonumber(vim.trim(v)) or default
    elseif ch == "t" or ch == "T" then
      local v = utils.input({ prompt = "Keep until (date/time): " })
      local d = v and v ~= "" and date.read_date(v, date.from_days(math.floor(last_valid / 1440)))
      if not d then
        return
      end
      keep = math.floor(d:minutes() - last_valid)
    elseif ch == "g" or ch == "G" then
      local v = utils.input({ prompt = string.format("Got back how many minutes ago (default %d): ", default) })
      if v == nil then
        return
      end
      gotback = tonumber(vim.trim(v)) or default
    end
    if ch == "j" or ch == "J" then
      if ch == "J" then
        resolve_clock(clock, "now", nil, true, false, opts)
      end
      local lnum = vim.api.nvim_buf_get_extmark_by_id(clock.bufnr, mark_ns, clock.mark, {})[1] + 1
      utils.open_file(vim.api.nvim_buf_get_name(clock.bufnr), lnum)
      return
    end
    local subtract = ch == "s" or ch == "S"
    -- less than 45 seconds on the clock before going away
    local barely_started = (last_valid - clock.start:minutes()) < 0.75
    local start_over = subtract and barely_started
    local to
    if ch == "C" or start_over then
      to = nil
    elseif subtract or gotback == 0 then
      to = last_valid
    elseif keep == default or gotback == default then
      to = "now"
    elseif keep then
      to = last_valid + keep
    elseif gotback then
      to = now - gotback
    end
    local close = ch == "K" or ch == "G" or ch == "S" or ch == "T"
    local restart = start_over and not (ch == "K" or ch == "G" or ch == "S" or ch == "C")
    resolve_clock(clock, to, gotback and last_valid or nil, close, restart, opts)
  end)
  resolving = false
  vim.api.nvim_buf_del_extmark(clock.bufnr, mark_ns, clock.mark)
  vim.api.nvim_buf_del_extmark(clock.bufnr, mark_ns, clock.head)
  if not ok then
    error(err, 0)
  end
  -- idle resolution stopped the timers only when clocking out
  if M.state and not tick_timer then
    start_timers()
  end
  return true
end

--- Resolve open clocks in the agenda files and org buffers
--- (org-resolve-clocks). Interactively a count limits this to dangling
--- clocks (not the running one).
---@param only_dangling? boolean
---@param opts? { clocking_in?: boolean, quiet?: boolean }
function M.resolve_clocks(only_dangling, opts)
  if only_dangling == nil and type(opts) ~= "table" then
    only_dangling = vim.v.count > 0
  end
  opts = type(opts) == "table" and opts or {}
  if resolving then
    return true
  end
  local list = M.dangling_clocks(not only_dangling)
  if #list == 0 then
    if not opts.quiet then
      utils.notify("No open clocks to resolve")
    end
    return true
  end
  for _, d in ipairs(list) do
    d.mark = vim.api.nvim_buf_set_extmark(d.bufnr, mark_ns, d.lnum - 1, 0, {})
  end
  for _, d in ipairs(list) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(d.bufnr, mark_ns, d.mark, {})
    vim.api.nvim_buf_del_extmark(d.bufnr, mark_ns, d.mark)
    local line = pos[1] and vim.api.nvim_buf_get_lines(d.bufnr, pos[1], pos[1] + 1, false)[1]
    local c = line and parser.parse_clock_line(line)
    if c and not c["end"] then
      d.lnum = pos[1] + 1
      d.active = d.active and M.state ~= nil
      M.resolve(d, function(clock)
        return string.format("Dangling clock started %d mins ago", date.now():minutes() - clock.start:minutes())
      end, d.start:minutes(), opts)
    end
  end
  return true
end

---------------------------------------------------------------------------
-- Statusline and effort
---------------------------------------------------------------------------

--- Statusline component (org-clock-get-clock-string): `"⏱ [0:25] (Task)"`,
--- or `"⏱ [0:25/1:00] (Task)"` when the task has an Effort. The time
--- includes earlier clocks per `clock.mode_line_total`; `clock.string_limit`
--- shortens it, `clock.task_overrun_text` is prepended once the effort is
--- reached. Empty when no clock runs. `require("org").statusline()`
--- combines this with the timer.
---@return string
function M.statusline()
  local a = M.active()
  if not a then
    return ""
  end
  local cfg = clock_cfg()
  local clocked = date.duration_to_string(a.clocked)
  local time = a.effort and string.format("[%s/%s]", clocked, date.duration_to_string(a.effort))
    or string.format("[%s]", clocked)
  local limit = tonumber(cfg.string_limit) or 0
  local heading = a.title
  local s
  -- org-clock-get-clock-string: "TIME (HEADING) " is 5 characters longer
  local full = vim.fn.strchars(time) + vim.fn.strchars(heading) + 5
  if limit <= 0 or limit >= full then
    s = string.format("%s (%s)", time, heading)
  elseif limit <= vim.fn.strchars(time) + 5 then
    s = vim.fn.strcharpart(time, 0, limit)
  else
    local keep = limit - (vim.fn.strchars(time) + 5)
    s = string.format("%s (%s…)", time, vim.fn.strcharpart(heading, 0, keep))
  end
  if a.overrun and cfg.task_overrun_text then
    s = cfg.task_overrun_text .. s
  end
  local icon = cfg.statusline_icon or "⏱"
  return icon ~= "" and (icon .. " " .. s) or s
end

--- Headline of the running clock: bufnr, headline (or nil).
local function clocked_headline()
  local bufnr, lnum = M.find_open_clock()
  if not bufnr then
    return nil
  end
  local hl = files.get_buffer(bufnr):headline_at(lnum)
  return hl and bufnr, hl
end

--- Refresh the running clock's effort after the entry's Effort changed.
function M.effort_changed(bufnr, lnum)
  if M.state and M.is_clocked_headline(bufnr, lnum) then
    local hl = files.get_buffer(bufnr):headline_at(lnum)
    M.state.effort = require("org.properties").effort_minutes(hl)
    notified = false
    persist()
    check_effort()
    vim.cmd("redrawstatus")
  end
end

--- Set or change the effort of the clocked task
--- (org-clock-modify-effort-estimate). `value` may be relative: `+0:15`,
--- `-10`. Without a running clock, acts on the entry at the cursor.
---@param value? string
function M.modify_effort(value)
  local bufnr, hl = clocked_headline()
  if not bufnr then
    local _
    bufnr, _, hl = edit.resolve_headline(nil)
    if not bufnr then
      return nil
    end
  end
  local prop = config.opts.effort_property or "Effort"
  local current = hl.properties[prop:upper()]
  if value == nil then
    value = utils.input({
      prompt = "Set effort (hh:mm or mm" .. (current and (", prefix + to add to " .. current) or "") .. "): ",
    })
    if not value or vim.trim(value) == "" then
      return nil
    end
  end
  value = vim.trim(tostring(value))
  local sign = value:sub(1, 1)
  local base = 0
  if sign == "+" or sign == "-" then
    base = current and date.parse_duration(current) or 0
    value = value:sub(2)
  end
  local minutes = date.parse_duration(value)
  if not minutes then
    utils.warn("Invalid effort: " .. value)
    return nil
  end
  if sign == "-" then
    minutes = base - minutes
  elseif sign == "+" then
    minutes = base + minutes
  end
  local str = date.duration_to_string(math.max(0, minutes))
  edit.set_property(bufnr, hl.line, prop, str)
  M.effort_changed(bufnr, hl.line)
  utils.notify("Effort is now " .. str)
  return str
end

--- Set the effort to the next value of `Effort_ALL` (org-inc-effort).
function M.inc_effort(target)
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local prop = config.opts.effort_property or "Effort"
  local allowed = hl:get_allowed_values(prop)
  if not allowed or #allowed == 0 then
    utils.warn("Allowed effort values are not set (" .. prop .. "_ALL)")
    return nil
  end
  local current = hl.properties[prop:upper()]
  local nxt
  if not current then
    nxt = allowed[1]
  else
    for i, v in ipairs(allowed) do
      if v == current then
        nxt = allowed[i + 1]
      end
    end
    if not nxt then
      utils.warn(string.format("Unknown value %q among allowed values", current))
      return nil
    end
  end
  edit.set_property(bufnr, hl.line, prop, nxt)
  M.effort_changed(bufnr, hl.line)
  utils.notify(prop .. " is now " .. nxt)
  return nxt
end

---------------------------------------------------------------------------
-- Clock sums on headlines
---------------------------------------------------------------------------

--- Remove the clock sums shown by `toggle_display` (org-clock-remove-overlays).
function M.remove_overlays(bufnr)
  bufnr = (type(bufnr) ~= "number" or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local had = #vim.api.nvim_buf_get_extmarks(bufnr, display_ns, 0, -1, { limit = 1 }) > 0
  vim.api.nvim_buf_clear_namespace(bufnr, display_ns, 0, -1)
  return had
end

--- Show the time clocked in each subtree next to its headline
--- (org-clock-display), for `clock.display_default_range` (this year by
--- default). With a count: 4 = today, 16 = ask for a range, 64 = only
--- report the total. Called again while the sums are shown, it hides them.
---@param bufnr? integer
---@param range? string a :block value (today, thisweek, untilnow, ...)
function M.toggle_display(bufnr, range)
  bufnr = (type(bufnr) ~= "number" or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local count = range == nil and vim.v.count or 0
  if M.remove_overlays(bufnr) and count == 0 and range == nil then
    return true
  end
  local label = ""
  if count >= 64 then
    range = "untilnow"
  elseif count >= 16 then
    range = utils.input_complete(
      "Range: ",
      { "today", "yesterday", "thisweek", "lastweek", "thismonth", "lastmonth", "thisyear", "lastyear", "untilnow" }
    )
    if not range or range == "" then
      return nil
    end
    label = " (custom)"
  elseif count > 0 then
    range = "today"
    label = " for today"
  end
  range = range or clock_cfg().display_default_range or "thisyear"
  local from, to = M.special_range(range)
  local file = files.get_buffer(bufnr)
  local times, total = clock_sum(file.children, from, to)
  if count < 64 then
    for _, hl in ipairs(file.headlines) do
      local m = times[hl]
      if m and m > 0 then
        -- like Emacs: dots up to column 60, then the time
        local dots = math.max(60 - utils.width(file.lines[hl.line]) - 1, 0)
        vim.api.nvim_buf_set_extmark(bufnr, display_ns, hl.line - 1, 0, {
          virt_text = {
            { " " .. string.rep("·", dots), "OrgClockOverlayDots" },
            { string.format(" %9s ", date.duration_to_string(m)), "OrgClockOverlay" },
          },
          virt_text_pos = "eol",
          hl_mode = "combine",
        })
      end
    end
  end
  utils.notify(
    string.format(
      "Total file time%s: %s (%d hours and %d minutes)",
      label,
      date.duration_to_string(total),
      math.floor(total / 60),
      total % 60
    )
  )
  return true
end

--- Buffer-local setup: clear clock display on edits.
function M.attach(bufnr)
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertEnter" }, {
    buffer = bufnr,
    group = vim.api.nvim_create_augroup("org.clock.buf." .. bufnr, { clear = true }),
    callback = function()
      vim.api.nvim_buf_clear_namespace(bufnr, display_ns, 0, -1)
    end,
  })
  vim.api.nvim_set_hl(0, "OrgClockSum", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "OrgClockOverlay", { link = "OrgClockSum", default = true })
  vim.api.nvim_set_hl(0, "OrgClockOverlayDots", { link = "NonText", default = true })
end

---------------------------------------------------------------------------
-- Persistence
---------------------------------------------------------------------------

--- Ask whether to resume a clock found after a restart
--- (org-clock-persist-query-resume).
local function query_resume(title)
  return not clock_cfg().persist_query_resume or utils.confirm("Resume clock (" .. title .. ")?")
end

--- Restore the running clock after a restart (from `clock.persist_file`).
--- Called by `setup()` when `clock.persist` is set: `true` restores the
--- clock and the history, `"clock"` / `"history"` only one of them.
---@return org.ClockState|nil state the running clock, if any
function M.restore()
  hook_exit()
  if M.state then
    return M.state
  end
  local cfg = clock_cfg()
  local want_clock = cfg.persist ~= "history"
  if cfg.persist and cfg.persist_file then
    local data = utils.read_json(cfg.persist_file)
    if type(data) == "table" then
      if cfg.persist == true or cfg.persist == "history" then
        if type(data.last) == "table" then
          M.last = data.last
        end
        if type(data.history) == "table" and vim.islist(data.history) then
          M.history = data.history
        end
      end
      if want_clock and type(data.state) == "table" and data.state.path and data.state.start then
        M.state = data.state
        if M.find_open_clock() then
          if not query_resume(M.state.title) then
            -- the open CLOCK line stays, as a dangling clock to resolve
            M.state = nil
            return nil
          end
          start_timers()
          return M.state
        end
        M.state = nil
      end
    end
  end
  if not want_clock then
    return nil
  end
  for _, f in ipairs(files.agenda_files()) do
    for _, hl in ipairs(f.headlines) do
      for _, c in ipairs(hl.clocks) do
        if not c["end"] then
          if not query_resume(mode_line_heading(hl)) then
            return nil
          end
          M.state = {
            path = f.filename,
            start = c.start:clone({ active = false }):to_string({ range = false }),
            title = mode_line_heading(hl),
            effort = require("org.properties").effort_minutes(hl),
            total = (total_before(hl)),
          }
          start_timers()
          return M.state
        end
      end
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Clock table
---------------------------------------------------------------------------

local MONTH_NAMES = {
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
}
local DAY_NAMES = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" }
local ORDINALS = { "1st", "2nd", "3rd", "4th" }

--- Clocktable terms per `:lang` (org-clock-clocktable-language-setup):
--- File, L, Timestamp, Headline, Time, ALL, Total time, File time, Clock
--- summary at. Add a language by adding an entry.
M.languages = {
  en = { "File", "L", "Timestamp", "Headline", "Time", "ALL", "Total time", "File time", "Clock summary at" },
  de = { "Datei", "E", "Zeitstempel", "Kopfzeile", "Dauer", "GESAMT", "Gesamtdauer", "Dateizeit", "Erstellt am" },
  es = {
    "Archivo",
    "N",
    "Fecha y hora",
    "Tarea",
    "Duración",
    "TODO",
    "Duración total",
    "Tiempo archivo",
    "Generado el",
  },
  fr = {
    "Fichier",
    "N",
    "Horodatage",
    "En-tête",
    "Durée",
    "TOUT",
    "Durée totale",
    "Durée fichier",
    "Horodatage sommaire à",
  },
  nl = { "Bestand", "N", "Tijdstip", "Rubriek", "Duur", "ALLES", "Totale duur", "Bestandstijd", "Klok overzicht op" },
  nn = { "Fil", "N", "Tidspunkt", "Overskrift", "Tid", "ALLE", "Total tid", "Filtid", "Tidsoversyn" },
  pl = {
    "Plik",
    "P",
    "Data i godzina",
    "Nagłówek",
    "Czas",
    "WSZYSTKO",
    "Czas całkowity",
    "Czas pliku",
    "Poddumowanie zegara na",
  },
  ["pt-BR"] = {
    "Arquivo",
    "N",
    "Data e hora",
    "Título",
    "Hora",
    "TODOS",
    "Hora total",
    "Hora do arquivo",
    "Resumo das horas em",
  },
  sk = {
    "Súbor",
    "L",
    "Časová značka",
    "Záhlavie",
    "Čas",
    "VŠETKO",
    "Celkový čas",
    "Čas súboru",
    "Časový súhrn pre",
  },
}
local TERMS = {
  File = 1,
  L = 2,
  Timestamp = 3,
  Headline = 4,
  Time = 5,
  ALL = 6,
  ["Total time"] = 7,
  ["File time"] = 8,
  ["Clock summary at"] = 9,
}

local function translate(term, lang)
  local l = M.languages[tostring(lang or "en")] or M.languages.en
  return l[TERMS[term]] or term
end

--- A date from a year, month and day that may overflow (like encode-time).
local function mkdate(y, m, d)
  local total = y * 12 + (m - 1)
  local yy = math.floor(total / 12)
  return date.from_days(date.days_from_civil(yy, total - yy * 12 + 1, 1) + d - 1)
end

--- Monday of ISO week `w` of year `y`.
local function iso_week_start(y, w)
  local jan4 = date.from_days(date.days_from_civil(y, 1, 4))
  return jan4:add(-(jan4:weekday() - 1) + (w - 1) * 7, "d")
end

--- ISO year and week of a date ("%G", "%V").
local function iso_week(d)
  local thursday = d:days() + (4 - d:weekday())
  local iy = date.civil_from_days(thursday)
  return iy, math.floor((thursday - date.days_from_civil(iy, 1, 1)) / 7) + 1
end

function iso_week_shift(y, w, n)
  return iso_week(iso_week_start(y, w):add(7 * n, "d"))
end

--- Resolve a `:block` (org-clock-special-range): `today`, `yesterday`,
--- `thisweek`, `lastweek`, `thismonth`, `lastmonth`, `thisq`, `lastq`,
--- `thisyear`, `lastyear` (the `this*` and `today` forms take a `-N`/`+N`
--- shift), `untilnow`, `2026`, `2026-09`, `2026-W39`, `2026-Q3`,
--- `2026-09-23`. Returns the range in minutes (from is nil for
--- `untilnow`) and the text used in the table caption.
---@param key string|integer
---@param wstart? integer first day of the week (1 = Monday, 0 = Sunday)
---@param mstart? integer first day of the month
---@return integer|nil from_min, integer to_min, string text
function M.special_range(key, wstart, mstart)
  local now = date.now()
  local y, month, d = now.year, now.month, now.day
  local dow = now:weekday() % 7 -- 0 = Sunday, like decode-time
  local q = math.floor((month - 1) / 3) + 1
  local skey = tostring(key)
  local shift = 0
  local kind
  if skey:match("^%d+$") then
    y, month, d, kind = tonumber(skey), 1, 1, "year"
  elseif skey:match("^%d+%-%d%d?$") then
    local a, b = skey:match("^(%d+)%-(%d+)$")
    y, month, d, kind = tonumber(a), tonumber(b), 1, "month"
  elseif skey:match("^%d+%-[wW]%d%d?$") then
    local a, b = skey:match("^(%d+)%-[wW](%d+)$")
    local s = iso_week_start(tonumber(a), tonumber(b))
    y, month, d, dow, kind = s.year, s.month, s.day, 1, "week"
  elseif skey:match("^%d+%-[qQ][1-4]$") then
    local a, b = skey:match("^(%d+)%-[qQ](%d)$")
    y, q, kind = tonumber(a), tonumber(b), "quarter"
  elseif skey:match("^%d+%-%d%d?%-%d%d?$") then
    local a, b, c = skey:match("^(%d+)%-(%d+)%-(%d+)$")
    y, month, d, kind = tonumber(a), tonumber(b), tonumber(c), "day"
  else
    local base, n = skey:match("^(.-)([-+]%d+)$")
    if base then
      kind, shift = base, tonumber(n)
    else
      kind = skey
    end
  end
  if shift == 0 then
    local last = { yesterday = "today", lastweek = "week", lastmonth = "month", lastyear = "year", lastq = "quarter" }
    if last[kind] then
      kind, shift = last[kind], -1
    end
  end
  local s, e, text
  if kind == "day" or kind == "today" then
    s = mkdate(y, month, d + shift)
    e = s:add(1, "d")
    text = string.format("%s, %s %02d, %d", DAY_NAMES[s:weekday()], MONTH_NAMES[s.month], s.day, s.year)
  elseif kind == "week" or kind == "thisweek" then
    local diff = -7 * shift + (dow + 7 - (tonumber(wstart) or 1)) % 7
    s = mkdate(y, month, d - diff)
    e = s:add(7, "d")
    text = string.format("week %d-W%02d", iso_week(s))
  elseif kind == "month" or kind == "thismonth" then
    s = mkdate(y, month + shift, tonumber(mstart) or 1)
    e = mkdate(y, month + shift + 1, tonumber(mstart) or 1)
    text = MONTH_NAMES[s.month] .. " " .. s.year
  elseif kind == "quarter" or kind == "thisq" then
    local idx = q - 1 + shift
    local qy, qq = y + math.floor(idx / 4), idx % 4
    s = mkdate(qy, 3 * qq + 1, 1)
    e = mkdate(qy, 3 * qq + 4, 1)
    text = ORDINALS[qq + 1] .. " quarter of " .. qy
  elseif kind == "year" or kind == "thisyear" then
    s = mkdate(y + shift, 1, 1)
    e = mkdate(y + shift + 1, 1, 1)
    text = "the year " .. s.year
  elseif kind == "untilnow" then
    return nil, now:minutes(), "now"
  else
    error("No such time block " .. skey, 0)
  end
  return s:minutes(), e:minutes(), text
end

--- Kept for callers of the old API: the range of a `:block`, or nil.
function M.block_range(block)
  if not block or block == "" then
    return nil
  end
  local ok, from, to = pcall(M.special_range, block)
  if not ok then
    return nil
  end
  return from, to
end

--- Interpret a `:tstart` / `:tend` value (org-matcher-time): a timestamp,
--- `<now>`, `<today>`, `<tomorrow>`, `<yesterday>`, or `<-2d>`-style
--- offsets (h counts from now, d w m y from today). Unknown values mean the
--- epoch, like Emacs.
---@return integer minutes
function M.matcher_time(s)
  s = tostring(s)
  local now = date.now():minutes()
  local today = date.today():minutes()
  if s == "<now>" then
    return now
  elseif s == "<today>" then
    return today
  elseif s == "<tomorrow>" then
    return today + 1440
  elseif s == "<yesterday>" then
    return today - 1440
  end
  local n, unit = s:match("^<([-+]%d+)([hdwmy])>$")
  if n then
    local mult = { h = 60, d = 1440, w = 10080, m = 44640, y = 525960 }
    return (unit == "h" and now or today) + tonumber(n) * mult[unit]
  end
  local y, m, d = s:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if y then
    local hh, mm = s:match("%d%d%d%d%-%d%d%-%d%d[^%d%]>]*%s(%d%d?):(%d%d)")
    return date.days_from_civil(tonumber(y), tonumber(m), tonumber(d)) * 1440
      + (tonumber(hh) or 0) * 60
      + (tonumber(mm) or 0)
  end
  return 0
end

--- Align a list of rows ("hline" or list of cells) into org table lines,
--- the way `org-table-align` does (numeric columns right-aligned).
function M.format_table(rows)
  return require("org.table").rows_to_lines(rows)
end

local function matcher(match)
  if not match or match == "" then
    return nil
  end
  local pred = require("org.agenda.search").compile(tostring(match))
  return pred
end

local function param_on(v)
  return v ~= nil and v ~= false and v ~= "nil"
end

--- Emacs `org-shorten-string`: cut at a word boundary and add "...".
local function shorten(s, max)
  if vim.fn.strchars(s) <= max then
    return s
  end
  local n = math.max(max - 4, 1)
  for i = n + 1, 2, -1 do
    local head = vim.fn.strcharpart(s, 0, i)
    local nxt = vim.fn.strcharpart(s, i, 1)
    if head:sub(-1) ~= " " and (nxt == " " or nxt == "") then
      return head .. "..."
    end
  end
  return vim.fn.strcharpart(s, 0, math.max(max - 3, 0)) .. "..."
end

--- The files a clocktable reads for :scope, and whether they form one list
--- (Emacs `consp files`). `roots` restricts to one subtree.
local function scope_files(scope, cur, lnum)
  local function with_archives(list)
    local archive = require("org.archive")
    local out, seen = {}, {}
    local function add(f)
      local key = f and (f.filename or f)
      if f and not seen[key] then
        seen[key] = true
        out[#out + 1] = f
      end
    end
    for _, f in ipairs(list) do
      add(f)
      if f.filename then
        local locs = { archive.location_for({ properties = {}, file = f }) }
        for _, hl in ipairs(f.headlines) do
          if hl.properties.ARCHIVE and hl.properties.ARCHIVE ~= "" then
            locs[#locs + 1] = hl.properties.ARCHIVE
          end
        end
        for _, loc in ipairs(locs) do
          local target = archive.parse_location(loc, f.filename).filename
          if target and target ~= f.filename and utils.exists(target) then
            add(files.get(target))
          end
        end
      end
    end
    return out
  end
  scope = scope == nil and "file" or scope
  if type(scope) == "table" then
    -- a list of org.File (the agenda's files)
    return scope, nil, true
  elseif scope == false or scope == "file" or scope == "nil" then
    return { cur }, nil, false
  elseif scope == "agenda" then
    return files.agenda_files(), nil, true
  elseif scope == "agenda-with-archives" then
    return with_archives(files.agenda_files()), nil, true
  elseif scope == "file-with-archives" then
    return with_archives({ cur }), nil, false
  elseif scope == "subtree" or scope == "tree" or tostring(scope):match("^tree%d+$") then
    local hl = cur:headline_at(lnum or 1)
    if not hl then
      error("Before first headline", 0)
    end
    local level = scope == "tree" and 0 or tonumber(tostring(scope):match("^tree(%d+)$"))
    if level then
      while hl.parent do
        hl = hl.parent
        if hl.level <= level then
          break
        end
      end
    end
    return { cur }, { hl }, false
  elseif type(scope) == "string" and scope:match("^%(") then
    local list = {}
    local dir = cur.filename and vim.fn.fnamemodify(cur.filename, ":h") or nil
    for p in scope:gmatch('"([^"]+)"') do
      local path = utils.expand(p, dir)
      local f = files.get(path)
      if f then
        f.display_name = p
        list[#list + 1] = f
      end
    end
    return list, nil, true
  end
  error("Unknown scope: " .. tostring(scope), 0)
end

--- First active (or inactive) timestamp of an entry outside its planning
--- line and CLOCK lines (the TIMESTAMP / TIMESTAMP_IA special properties).
local function entry_timestamp(hl, active)
  local lines = hl.file.lines
  for i = hl.line, hl.body_end or hl.line do
    local l = lines[i]
    if l and i ~= hl.planning_line and not l:match("^%s*CLOCK:") then
      local text = i == hl.line and hl.title or l
      for _, item in ipairs(date.parse_all(text)) do
        if item.date.active == active then
          return item.date:to_string()
        end
      end
    end
  end
end

--- Emacs `org-link-escape`: backslash-escape brackets in a link path.
local function link_escape(s)
  s = s:gsub("(\\*)([%[%]])", function(bs, br)
    return bs .. bs .. "\\" .. br
  end)
  return (s:gsub("(\\+)$", "%1%1"))
end

local COOKIE = "%[%d*%%%]"
local COOKIE2 = "%[%d*/%d*%]"

local function link_display(s)
  s = s:gsub("%[%[([^%]]-)%]%[([^%]]-)%]%]", "%2")
  return (s:gsub("%[%[([^%]]-)%]%]", "%1"))
end

--- The running clock's headline, if it is in `file`: its line and start.
local function running_in(file)
  if not M.state or not file.filename or vim.fs.normalize(file.filename) ~= vim.fs.normalize(M.state.path) then
    return nil
  end
  local start = date.parse(M.state.start)
  for _, hl in ipairs(file.headlines) do
    for _, c in ipairs(hl.clocks) do
      if not c["end"] and start and c.start:minutes() == start:minutes() then
        return hl, start:minutes()
      end
    end
  end
end

--- Clock sums of a file (org-clock-sum): for each headline in the scanned
--- region, the minutes clocked in its subtree within [ts, te). With a
--- matcher, only matching entries contribute their own clocks, and their
--- ancestors are listed to show them.
---@return table<org.Headline, integer> times listed headlines and their time
---@return integer total
function clock_sum(roots, ts, te, pred)
  local times, total = {}, 0
  local include_running = clock_cfg().report_include_clocking_task
  local run_hl, run_start
  if include_running and ts and te and roots[1] then
    run_hl, run_start = running_in(roots[1].file)
  end
  local function own(hl)
    local t = 0
    for _, c in ipairs(hl.clocks) do
      if c["end"] then
        local s, e = c.start:minutes(), c["end"]:minutes()
        local dt = (te and math.min(e, te) or e) - (ts and math.max(s, ts) or s)
        if dt > 0 then
          t = t + dt
        end
      end
    end
    if hl == run_hl and run_start >= ts and run_start <= te then
      t = t + math.max(0, date.now():minutes() - run_start)
    end
    return t
  end
  -- returns the subtree's time and whether a listed descendant forces
  -- the headline into the table
  local function visit(hl)
    local sub, forced = 0, false
    for _, child in ipairs(hl.children) do
      local ct, cl = visit(child)
      sub = sub + ct
      forced = forced or cl
    end
    local included = not pred or pred(hl)
    local t1 = own(hl)
    local time = sub + (included and t1 or 0)
    local listed = (t1 > 0 or sub > 0) and (included or (pred ~= nil and forced))
    if listed then
      times[hl] = time
    end
    if included then
      total = total + t1
    end
    return time, listed
  end
  for _, hl in ipairs(roots) do
    visit(hl)
  end
  return times, total
end

--- Minutes clocked in a headline subtree, clipped to [from_min, to_min).
---@param hl org.Headline
---@param from_min? integer
---@param to_min? integer
---@param own_only? boolean exclude children
function M.sum_minutes(hl, from_min, to_min, own_only)
  if own_only then
    local total = 0
    for _, c in ipairs(hl.clocks) do
      if c["end"] then
        local s, e = c.start:minutes(), c["end"]:minutes()
        local dt = (to_min and math.min(e, to_min) or e) - (from_min and math.max(s, from_min) or s)
        if dt > 0 then
          total = total + dt
        end
      end
    end
    return total
  end
  local times = clock_sum({ hl }, from_min, to_min)
  return times[hl] or 0
end

--- Clock data of one file (org-clock-get-table-data).
---@return { file: org.File, total: integer, entries: table[] }
local function table_data(file, roots, params, ts, te)
  local maxlevel = tonumber(params.maxlevel) or 2
  local link = param_on(params.link)
  local props = params._props
  local times, total = clock_sum(roots or file.children, ts, te, matcher(params.match))
  local entries = {}
  local function walk(hl)
    local time = times[hl]
    if time and time > 0 and hl.level <= maxlevel then
      local title = vim.trim(hl.title)
      local headline = title
      if link then
        local search = "*" .. vim.trim((title:gsub(COOKIE, " "):gsub(COOKIE2, " "):gsub("[ \t]+", " ")))
        local desc = vim.trim(link_display((title:gsub(COOKIE, ""):gsub(COOKIE2, ""))))
        local target = file.filename and ("file:" .. file.filename .. "::" .. search) or search
        headline = "[[" .. link_escape(target) .. "][" .. desc .. "]]"
      end
      local tsp
      if param_on(params.timestamp) then
        tsp = hl:get_property("SCHEDULED")
          or hl:get_property("DEADLINE")
          or entry_timestamp(hl, true)
          or entry_timestamp(hl, false)
      end
      local values = {}
      for i, p in ipairs(props) do
        values[i] = hl:get_property(p, param_on(params["inherit-props"])) or ""
      end
      entries[#entries + 1] = {
        level = hl.level,
        headline = headline,
        tags = param_on(params.tags) and hl:get_tags() or {},
        ts = tsp,
        time = time,
        props = values,
      }
    end
    for _, child in ipairs(hl.children) do
      walk(child)
    end
  end
  for _, hl in ipairs(roots or file.children) do
    walk(hl)
  end
  return { file = file, total = total, entries = entries }
end

--- Sort the data rows of the first section after the total row
--- (`:sort (COLUMN . ?TYPE)`, like org-table-sort-lines).
local function sort_rows(rows, spec)
  local col, kind = tostring(spec):match("^%(%s*(%d+)%s*%.%s*%?(%a)%s*%)$")
  col = tonumber(col)
  if not col then
    error("Invalid :sort parameter " .. tostring(spec), 0)
  end
  local data = 0
  local first
  for i, r in ipairs(rows) do
    if r ~= "hline" then
      data = data + 1
      if data == 3 then
        first = i
        break
      end
    end
  end
  if not first then
    return rows
  end
  local s, e = first, first
  while s > 1 and rows[s - 1] ~= "hline" do
    s = s - 1
  end
  while e < #rows and rows[e + 1] ~= "hline" do
    e = e + 1
  end
  local lower = kind:lower()
  local function key(r)
    local f = vim.trim(r[col] or "")
    if lower == "n" then
      return tonumber(f:match("^[-+]?%d*%.?%d+")) or 0
    elseif lower == "t" then
      local d = date.parse(f:match("[<%[]%d%d%d%d%-%d%d%-%d%d[^>%]]*[>%]]") or "")
      if d then
        return d:minutes()
      end
      return date.parse_duration(f:gsub("^[*/]", ""):gsub("[*/]$", "")) or 0
    elseif lower == "a" then
      -- org-string< ignoring case compares upcased strings ("P" < "\\")
      return (link_display(f):gsub("[*/_=~+]", ""):upper())
    end
    error("Invalid sorting type " .. kind, 0)
  end
  local slice = {}
  for i = s, e do
    slice[#slice + 1] = { row = rows[i], key = key(rows[i]), i = i }
  end
  local reverse = kind ~= lower
  if reverse then
    -- sort-subr: reverse, stable sort, reverse again
    for i, x in ipairs(slice) do
      x.i = -i
    end
  end
  table.sort(slice, function(a, b)
    if a.key ~= b.key then
      if reverse then
        return a.key > b.key
      end
      return a.key < b.key
    end
    return a.i < b.i
  end)
  for i, x in ipairs(slice) do
    rows[s + i - 1] = x.row
  end
  return rows
end

--- Split an org table row into cells ("hline" for rules).
local function row_cells(line)
  if line:match("^%s*|%-") then
    return "hline"
  end
  return require("org.table").split_cells(line)
end

--- One clock table (org-clocktable-write-default) for [ts, te).
---@param ctx { bufnr: integer, lnum?: integer, content?: string[] }
---@return string[] lines, integer total minutes
local function clocktable_single(params, ctx, ts, te)
  local lang = params.lang or "en"
  local cur = type(params.scope) ~= "table" and files.get_buffer(ctx.bufnr) or nil
  local file_list, roots, listp = scope_files(params.scope, cur, ctx.lnum)
  local multifile = listp and not param_on(params.hidefiles) and params.scope ~= "file-with-archives"
  local maxlevel = tonumber(params.maxlevel) or 2
  local compact = param_on(params.compact)
  local level_col = param_on(params.level) and not compact
  local show_ts = param_on(params.timestamp)
  local show_tags = param_on(params.tags)
  local props = {}
  if type(params.properties) == "string" then
    for p in params.properties:gmatch('"([^"]+)"') do
      props[#props + 1] = p
    end
  end
  params._props = props
  local emph = param_on(params.emphasize)
  local indent = compact or param_on(params.indent)
  local percent = params.formula == "%"
  local link = param_on(params.link)
  local narrow = params.narrow
  if narrow == nil or narrow == false then
    narrow = compact and "40!" or nil
  end
  if type(narrow) == "number" and link then
    narrow = narrow .. "!"
  end
  local narrow_cut
  if type(narrow) == "string" then
    narrow_cut = tonumber(narrow:match("^(%d+)!$"))
    if not narrow_cut then
      error("Invalid value " .. narrow .. " of :narrow property in clock table", 0)
    end
  end

  local tables = {}
  for _, f in ipairs(file_list) do
    tables[#tables + 1] = table_data(f, roots, params, ts, te)
  end
  local total = 0
  local deepest
  for _, t in ipairs(tables) do
    total = total + t.total
    if t.total ~= 0 then
      for _, e in ipairs(t.entries) do
        deepest = math.max(deepest or 0, e.level)
      end
    end
  end
  local tcols = (compact or maxlevel < 2) and 1 or math.min(maxlevel, tonumber(params.tcolumns) or 100, deepest or 1)
  local fmt = date.duration_to_string
  local function tr(term)
    return translate(term, lang)
  end
  local nprops = string.rep("|", #props)

  -- The table text, built like Emacs does and aligned afterwards.
  local text = {}
  if type(narrow) == "number" then
    text[#text + 1] = "|"
      .. (multifile and "|" or "")
      .. (level_col and "|" or "")
      .. (show_ts and "|" or "")
      .. (show_tags and "|" or "")
      .. nprops
      .. string.format("<%d>| |", narrow)
  end
  text[#text + 1] = "|"
    .. (multifile and (tr("File") .. "|") or "")
    .. (level_col and (tr("L") .. "|") or "")
    .. (show_ts and (tr("Timestamp") .. "|") or "")
    .. (show_tags and "Tags |" or "")
    .. (#props > 0 and (table.concat(props, "|") .. "|") or "")
    .. tr("Headline")
    .. "|"
    .. tr("Time")
    .. "|"
    .. string.rep("|", math.max(0, tcols - 1))
    .. (percent and "%|" or "")
  text[#text + 1] = "|-"
  text[#text + 1] = "|"
    .. (multifile and string.format("| %s ", tr("ALL")) or "")
    .. (level_col and "|" or "")
    .. (show_ts and "|" or "")
    .. (show_tags and "|" or "")
    .. nprops
    .. "*"
    .. tr("Total time")
    .. "*| *"
    .. fmt(total)
    .. "*|"
    .. string.rep("|", math.max(0, tcols - 1))
    .. (percent and (total == 0 and "0.0|" or "100.0|") or "")
  if total > 0 then
    for _, t in ipairs(tables) do
      if t.total > 0 or not param_on(params.fileskip0) then
        text[#text + 1] = "|-"
        if multifile then
          local name = t.file.display_name or vim.fn.fnamemodify(t.file.filename or "", ":t")
          if param_on(params.filetitle) and t.file.settings.title then
            name = t.file.settings.title
          end
          text[#text + 1] = string.format(
            "| %s %s | %s%s%s*%s* | *%s*|%s%s",
            name,
            level_col and "| " or "",
            show_ts and "| " or "",
            show_tags and "| " or "",
            nprops,
            tr("File time"),
            fmt(t.total),
            string.rep("|", math.max(0, tcols - 1)),
            percent and string.format(" %.1f |", 100 * t.total / total) or ""
          )
        end
        if maxlevel > 0 then
          for _, e in ipairs(t.entries) do
            local headline = e.headline
            if narrow_cut then
              local l, d = headline:match("^%[%[(.-)%]%[(.*)%]%]$")
              headline = l and ("[[" .. l .. "][" .. shorten(d, narrow_cut) .. "]]") or shorten(headline, narrow_cut)
            end
            local function field(s)
              if emph and e.level == 1 then
                return "*" .. s .. "* |"
              elseif emph and e.level == 2 then
                return "/" .. s .. "/ |"
              end
              return s .. " |"
            end
            local values = {}
            for i, v in ipairs(e.props) do
              values[i] = v
            end
            text[#text + 1] = "|"
              .. (multifile and "|" or "")
              .. (level_col and (e.level .. "|") or "")
              .. (show_ts and ((e.ts or "") .. "|") or "")
              .. (show_tags and (table.concat(e.tags, ", ") .. "|") or "")
              .. (#props > 0 and (table.concat(values, "|") .. "|") or "")
              .. (indent and e.level > 1 and ("\\_" .. string.rep(" ", 2 * (e.level - 1))) or "")
              .. field((headline:gsub("|", "\\vert{}")))
              .. string.rep("|", math.max(0, math.min(tcols, e.level) - 1))
              .. field(fmt(e.time))
              .. string.rep("|", math.max(0, tcols - e.level))
              .. (percent and string.format("%.1f |", 100 * e.time / total) or "")
          end
        end
      end
    end
  end

  local rows = vim.tbl_map(row_cells, text)
  local tblfm
  if params.formula == nil or params.formula == false or percent then
    for _, l in ipairs(ctx.content or {}) do
      local f = l:match("^%s*(#%+[Tt][Bb][Ll][Ff][Mm]:.*)$")
      if f then
        tblfm = f
        break
      end
    end
  elseif type(params.formula) == "string" then
    tblfm = "#+TBLFM: " .. params.formula
  else
    error("Invalid :formula parameter in clocktable", 0)
  end
  if params.sort then
    sort_rows(rows, params.sort)
  end
  local out = M.format_table(rows)
  if tblfm then
    out = require("org.table").recalc_lines(ctx.bufnr, out, { tblfm }, ctx.lnum)
    out[#out + 1] = tblfm
  end

  local header = params.header
  local caption
  if header == nil or header == false then
    caption = "#+CAPTION: " .. tr("Clock summary at") .. " " .. date.now():clone({ active = false }):to_string()
    if params.block then
      local _, _, range_text = M.special_range(params.block, params.wstart, params.mstart)
      caption = caption .. ", for " .. range_text .. "."
    end
    caption = caption .. "\n"
  else
    caption = tostring(header):gsub("\\n", "\n")
  end
  -- the header is inserted as is: text after its last newline starts the
  -- first table line
  local head = vim.split(caption, "\n", { plain = true })
  out[1] = head[#head] .. out[1]
  head[#head] = nil
  return vim.list_extend(head, out), total
end

local STEP_HEADERS = {
  day = "Daily report: ",
  week = "Weekly report starting on: ",
  semimonth = "Semimonthly report starting on: ",
  month = "Monthly report starting on: ",
  quarter = "Quarterly report starting on: ",
  year = "Annual report starting on: ",
}

--- Start of the step period after the one starting at `m` minutes.
local function next_step(m, step, wstart, mstart)
  local d = date.from_days(math.floor(m / 1440))
  local dow = d:weekday() % 7 -- 0 = Sunday
  local nd
  if step == "day" then
    nd = d:add(1, "d")
  elseif step == "week" then
    nd = d:add(dow == wstart and 7 or (wstart - dow) % 7, "d")
  elseif step == "semimonth" then
    nd = d.day < 16 and mkdate(d.year, d.month, 16) or mkdate(d.year, d.month + 1, 1)
  elseif step == "month" then
    nd = mkdate(d.year, d.month + 1, mstart)
  elseif step == "quarter" then
    nd = mkdate(d.year, d.month + 3, mstart)
  else
    nd = mkdate(d.year + 1, 1, 1)
  end
  return nd:minutes()
end

local function ts_string(m, with_time)
  local d = date.from_days(math.floor(m / 1440))
  if with_time then
    d = d:clone({ hour = math.floor((m % 1440) / 60), min = m % 60 })
  end
  return d:clone({ active = false }):to_string()
end

--- One table per :step period (org-clocktable-steps).
local function clocktable_steps(params, ctx)
  local step = tostring(params.step)
  if not STEP_HEADERS[step] then
    error("Unknown `:step' specification: " .. step, 0)
  end
  local wstart = tonumber(params.wstart) or 1
  local mstart = tonumber(params.mstart) or 1
  local start, stop
  if params.block then
    start, stop = M.special_range(params.block, wstart, mstart)
    start = start or M.matcher_time("<2003-01-01 Thu 00:00>")
  else
    start = M.matcher_time(params.tstart or "<2003-01-01 Thu 00:00>")
    stop = M.matcher_time(params.tend)
  end
  local out = {}
  local guard = 0
  local skipped = false
  while start < stop and guard < 5000 do
    guard = guard + 1
    local nxt = next_step(start, step, wstart % 7, mstart)
    local sub = vim.tbl_extend("force", params, { header = "", step = false, block = false })
    local lines, total = clocktable_single(sub, ctx, start, math.min(stop, nxt))
    skipped = param_on(params.stepskip0) and total == 0
    if not skipped then
      out[#out + 1] = ""
      out[#out + 1] = STEP_HEADERS[step] .. ts_string(start)
      vim.list_extend(out, lines)
    end
    start = nxt
  end
  if skipped then
    -- Emacs deletes a skipped table but keeps the empty line before it
    out[#out + 1] = ""
  end
  return out
end

--- Build clock table lines for a dynamic block. Parameters follow Emacs
--- (`org-dblock-write:clocktable`): :scope :maxlevel :block :tstart :tend
--- :wstart :mstart :step :stepskip0 :fileskip0 :match :emphasize :lang
--- :link :narrow :indent :filetitle :hidefiles :tcolumns :level :sort
--- :compact :timestamp :tags :properties :inherit-props :formula :header.
--- Defaults come from `clock.clocktable_default`.
---@param params table parsed block parameters
---@param bufnr integer buffer containing the block
---@param lnum? integer line of the block (for :scope subtree)
---@param content? string[] the block's previous content (to keep a #+TBLFM)
---@return string[]
function M.clocktable(params, bufnr, lnum, content)
  local defaults = {
    maxlevel = 2,
    lang = "en",
    scope = "file",
    wstart = 1,
    mstart = 1,
    narrow = "40!",
    indent = true,
  }
  params = vim.tbl_extend("force", defaults, clock_cfg().clocktable_default or {}, params or {})
  local ctx = {
    bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr,
    lnum = lnum,
    content = content,
  }
  local ok, res = pcall(function()
    if param_on(params.step) then
      if not (param_on(params.block) or (param_on(params.tstart) and param_on(params.tend))) then
        error("Clocktable `:step' can only be used with `:block' or `:tstart', `:tend'", 0)
      end
      return clocktable_steps(params, ctx)
    end
    local ts, te
    if param_on(params.block) then
      ts, te = M.special_range(params.block, params.wstart, params.mstart)
    else
      params.block = nil
      ts = param_on(params.tstart) and M.matcher_time(params.tstart) or nil
      te = param_on(params.tend) and M.matcher_time(params.tend) or nil
    end
    return (clocktable_single(params, ctx, ts, te))
  end)
  if not ok then
    error(res, 0)
  end
  return res
end

return M
