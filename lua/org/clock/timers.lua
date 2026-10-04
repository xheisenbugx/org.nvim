---@mod org.clock.timers Time clocked so far, effort notice, timers and exit hooks
---
--- The time already clocked on a task (mode line total), the effort
--- notification, the minute tick, idle time and auto clock-out, and the
--- autocmds that follow a renamed buffer and ask before exiting.
---
--- Part of org.clock, which loads it.

local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")
local shared = require("org.clock.shared")

local M = require("org.clock")

local at_instant = shared.at_instant
local buf_path = shared.buf_path
local clock_cfg = shared.clock_cfg
local now_minutes = shared.now_minutes
local persist = shared.persist
local state_in_buffer = shared.state_in_buffer
local unnamed = shared.unnamed

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
    -- today starts at `extend_today_until` o'clock
    return date.today():minutes() + (tonumber(config.opts.extend_today_until) or 0) * 60, false
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
    -- lint: allow expand: the sound option
    local file = vim.fn.expand(sound)
    for _, player in ipairs({ "afplay", "paplay", "aplay" }) do
      if vim.fn.executable(player) == 1 then
        pcall(vim.system, { player, file }, { detach = true })
        break
      end
    end
  end
end

-- The effort notice was given for the running clock (shared: clock in and
-- an effort change reset it).
shared.notified = false

--- Notify once when the clocked time reaches the effort
--- (org-clock-notify-once-if-expired).
local function check_effort()
  local a = M.active()
  if not a or not a.overrun then
    shared.notified = false
    return
  end
  if not shared.notified and clock_cfg().notify_effort ~= false then
    shared.notified = true
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

--- The program printing the X11 idle time in milliseconds
--- (org-clock-x11idle-program-name): `clock.x11idle_program_name`, else
--- xprintidle when installed, else x11idle.
---@return string
function M.x11idle_program()
  local name = clock_cfg().x11idle_program_name
  if name and name ~= "" then
    return name
  end
  return vim.fn.executable("xprintidle") == 1 and "xprintidle" or "x11idle"
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
  elseif vim.env.DISPLAY and vim.fn.executable(M.x11idle_program()) == 1 then
    local ok, res = pcall(function()
      return vim.system({ M.x11idle_program() }, { text = true }):wait(2000)
    end)
    local ms = ok and res and res.stdout and tonumber(vim.trim(res.stdout))
    sys = ms and ms / 1000
  end
  return sys or idle
end

-- An open clock is being resolved (shared: set by org.clock.resolve).
shared.resolving = false

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
  if idle_min and idle_min > 0 and not shared.resolving then
    local idle = M.user_idle_seconds(idle_min * 60)
    if idle > idle_min * 60 then
      local bufnr, lnum = M.find_open_clock()
      if bufnr then
        local idle_start = now_minutes() - idle / 60
        local ok, err = pcall(
          M.resolve,
          { bufnr = bufnr, lnum = lnum, start = date.parse(M.state.start), active = true },
          function()
            return string.format("Clocked in & idle for %.1f mins", now_minutes() - idle_start)
          end,
          at_instant(idle_start):minutes(),
          { idle = true, last_valid_time = idle_start * 60 }
        )
        if not ok then
          utils.error(tostring(err))
        end
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
    auto_timer:start(
      period,
      period,
      vim.schedule_wrap(function()
        if M.state and M.user_idle_seconds(secs) >= secs then
          M.clock_out({})
        end
      end)
    )
  end
end

local function stop_timers()
  stop_timer(tick_timer)
  stop_timer(auto_timer)
  tick_timer, auto_timer = nil, nil
end

--- Whether the minute tick runs (the clock is being timed).
local function timers_running()
  return tick_timer ~= nil
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
local rename_hooked = false

--- Follow the clocked buffer when it gets another name (:saveas, :file),
--- as Emacs follows its clock marker.
local function hook_rename()
  if rename_hooked then
    return
  end
  rename_hooked = true
  -- :saveas also names a new alternate buffer: the events nest
  local renaming = {}
  vim.api.nvim_create_autocmd("BufFilePre", {
    group = utils.augroup,
    callback = function(ev)
      renaming[ev.buf] = M.state ~= nil and state_in_buffer(ev.buf) or nil
    end,
  })
  vim.api.nvim_create_autocmd("BufFilePost", {
    group = utils.augroup,
    callback = function(ev)
      if renaming[ev.buf] and M.state then
        M.state.path = buf_path(ev.buf) or ""
        M.state.bufnr = unnamed(ev.buf)
        persist()
      end
      renaming[ev.buf] = nil
    end,
  })
end

--- On exit with `clock.persist_query_save` and a running clock, ask
--- whether to keep it for the next session (org-clock-persist-query-save);
--- when not, it is dropped from `clock.persist_file` (the history stays).
function M.query_save()
  local cfg = clock_cfg()
  if not (M.state and cfg.persist_query_save and cfg.persist and cfg.persist ~= "history") then
    return
  end
  if utils.confirm("Save current clock (" .. (M.state.title or "") .. ")?") then
    return
  end
  local state = M.state
  M.state = nil
  persist()
  M.state = state
end

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
          utils.save_buffer_or_warn(bufnr)
        end
      end
      M.query_save()
    end,
  })
end

-- for the parts loaded after this one
shared.check_effort = check_effort
shared.hook_exit = hook_exit
shared.hook_rename = hook_rename
shared.start_timers = start_timers
shared.stop_timers = stop_timers
shared.timers_running = timers_running
shared.total_before = total_before
