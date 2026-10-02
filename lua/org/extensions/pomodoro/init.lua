---@mod org.extensions.pomodoro Pomodoro timer on top of the clock
---
--- Enable with `extensions = { pomodoro = {} }` (see
--- `:h org-extensions-pomodoro`). Like Emacs org-pomodoro: a pomodoro
--- clocks in the entry at point for `work` minutes, then a break starts
--- (clocked out), a long one after every `long_break_every` pomodoros.
--- Each finished pomodoro adds one to the entry's POMODOROS property.
---
--- ```lua
--- local pomodoro = require("org.extensions.pomodoro")
--- pomodoro.start()          -- on the heading at the cursor
--- pomodoro.statusline()     -- "🍅 24:13 (1)"
--- pomodoro.info()           -- { phase = "work", remaining = 1453, ... }
--- ```

local utils = require("org.utils")

local M = {}

M.defaults = {
  --- Minutes of a pomodoro (org-pomodoro-length).
  work = 25,
  --- Minutes of a short break (org-pomodoro-short-break-length).
  short_break = 5,
  --- Minutes of a long break (org-pomodoro-long-break-length).
  long_break = 15,
  --- A long break follows every Nth pomodoro (org-pomodoro-long-break-frequency).
  long_break_every = 4,
  --- Start the break as soon as a pomodoro ends.
  auto_start_breaks = true,
  --- Start the next pomodoro on the same entry when a break ends
  --- (otherwise wait for `pomodoro_start`).
  auto_start_work = false,
  --- When the time is up, go on in overtime (the clock keeps running)
  --- until `pomodoro_start` ends the pomodoro and starts the break
  --- (org-pomodoro-manual-break).
  manual_break = false,
  --- Clock out while on a break (and while paused).
  clock_out_on_break = true,
  --- Property counting the finished pomodoros of an entry; false for none.
  property = "POMODOROS",
  --- Also send a desktop notification (osascript / notify-send / powershell.exe).
  system_notification = true,
  --- Command run when a phase ends, e.g. `{ "afplay", "/System/Library/Sounds/Glass.aiff" }`
  --- or a shell string; false for none (`clock.sound` still applies).
  sound = false,
  --- Add the pomodoro to `require("org").statusline()`.
  statusline = true,
  --- Where the running pomodoro is kept, so a new Neovim goes on with it;
  --- false to forget it on exit.
  state_file = vim.fn.stdpath("state") .. "/org/pomodoro.json",
  --- Statusline icons.
  icons = { work = "🍅", short_break = "☕", long_break = "🌴", paused = "⏸", ready = "🍅", overtime = "🍅" },
}

local ns = vim.api.nvim_create_namespace("org_pomodoro")

--- Current wall-clock time in seconds, sub-second (the time a suspended
--- machine slept counts, so the phases it covered end on wake-up and a
--- saved session compares with the next Neovim's time); specs replace it
--- with a fake clock.
---@return number
function M.time()
  local sec, usec = vim.uv.gettimeofday()
  return sec + usec / 1e6
end

---@class org.PomodoroState
---@field phase "work"|"short_break"|"long_break"|"overtime"|"ready"
---@field started number seconds
---@field duration number seconds (0 in overtime, which counts up)
---@field paused_at number|nil
---@field count integer pomodoros finished in this session
---@field bufnr integer|nil the entry's buffer (nil until needed after a restore)
---@field mark integer|nil extmark on the entry's headline
---@field path string|nil the entry's file
---@field lnum integer|nil the entry's line when saved
---@field title string

---@type org.PomodoroState|nil
M.state = nil

local timer
-- a setup() that follows a teardown in this Neovim (not a new start)
local torn_down

local function opts()
  return require("org.extensions").opts("pomodoro") or M.defaults
end

local function minutes(key)
  return (tonumber(opts()[key]) or M.defaults[key]) * 60
end

local function redraw()
  pcall(vim.cmd, "redrawstatus")
end

---------------------------------------------------------------------------
-- Saved state
---------------------------------------------------------------------------

local function state_file()
  local f = opts().state_file
  -- lint: allow expand: the state_file option
  return type(f) == "string" and f ~= "" and vim.fn.expand(f) or nil
end

local function entry_line(st)
  st = st or M.state
  if not st then
    return nil
  end
  if not (st.bufnr and vim.api.nvim_buf_is_valid(st.bufnr)) and st.path then
    -- restored: find the entry in its file (loaded now)
    local ok, b = pcall(utils.load_buffer, st.path)
    if not ok or not b then
      return nil
    end
    local file = require("org.files").get_buffer(b)
    local hl = file:headline_at(st.lnum or 1)
    if not (hl and hl:plain_title() == st.title) then
      hl = file:find_headline(function(h)
        return h:plain_title() == st.title
      end)
    end
    if not hl then
      return nil
    end
    st.bufnr = b
    st.mark = vim.api.nvim_buf_set_extmark(b, ns, hl.line - 1, 0, {})
  end
  if not (st.bufnr and st.mark and vim.api.nvim_buf_is_valid(st.bufnr)) then
    return nil
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(st.bufnr, ns, st.mark, {})
  if not pos[1] then
    return nil
  end
  local hl = require("org.files").get_buffer(st.bufnr):headline_at(pos[1] + 1)
  return hl and hl.line or nil
end

--- Write the session to `state_file` (removed when there is none).
local function save()
  local f = state_file()
  if not f then
    return
  end
  local st = M.state
  if not st then
    vim.fn.delete(f)
    return
  end
  local lnum = (st.bufnr and entry_line(st)) or st.lnum
  local path = st.path
  if st.bufnr and vim.api.nvim_buf_is_valid(st.bufnr) then
    local name = vim.api.nvim_buf_get_name(st.bufnr)
    path = name ~= "" and name or nil
  end
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(f, ":h"), "p")
  pcall(utils.write_json, f, {
    phase = st.phase,
    started = st.started,
    duration = st.duration,
    paused_at = st.paused_at or vim.NIL,
    count = st.count,
    path = path or vim.NIL,
    lnum = lnum or vim.NIL,
    title = st.title,
    pid = vim.fn.getpid(),
  })
end

local function null(v)
  if v == vim.NIL then
    return nil
  end
  return v
end

---------------------------------------------------------------------------
-- Notifications
---------------------------------------------------------------------------

--- Tell the user a phase ended: `clock.notification_handler` (or
--- vim.notify) and `clock.sound` through org.clock's notifier, a desktop
--- notification and the `sound` command.
---@param msg string
function M.notify(msg)
  local o = opts()
  require("org.clock").notify(msg)
  if o.system_notification and #vim.api.nvim_list_uis() > 0 then
    require("org.agenda.notifications").desktop_notify("Pomodoro", msg)
  end
  local sound = o.sound
  if type(sound) == "string" and sound ~= "" then
    pcall(vim.system, { vim.o.shell, vim.o.shellcmdflag, sound }, { detach = true })
  elseif type(sound) == "table" and #sound > 0 then
    pcall(vim.system, sound, { detach = true })
  end
end

---------------------------------------------------------------------------
-- The entry
---------------------------------------------------------------------------

local function clock_in()
  local lnum = entry_line()
  if not lnum then
    utils.warn("Pomodoro: the entry is gone")
    return false
  end
  local clock = require("org.clock")
  if clock.state and clock.is_clocked_headline(M.state.bufnr, lnum) then
    return true
  end
  clock.clock_in({ bufnr = M.state.bufnr, lnum = lnum }, { no_count = true })
  return true
end

local function clock_out()
  local st = M.state
  local clock = require("org.clock")
  local lnum = entry_line()
  if clock.state and lnum and clock.is_clocked_headline(st.bufnr, lnum) then
    clock.clock_out({ quiet = true, switch_to_state = false, note = false })
  end
end

--- Add one to the entry's pomodoro property.
local function count_pomodoro()
  local prop = opts().property
  local lnum = entry_line()
  if not prop or prop == "" or not lnum then
    return
  end
  local hl = require("org.files").get_buffer(M.state.bufnr):headline_at(lnum)
  local n = tonumber(hl.properties[prop:upper()] or "") or 0
  require("org.edit").set_property(M.state.bufnr, lnum, prop, tostring(n + 1))
end

---------------------------------------------------------------------------
-- Phases
---------------------------------------------------------------------------

--- Seconds left in the current phase (nil when idle, ready or in
--- overtime).
---@param now? number
---@return number|nil
function M.remaining(now)
  local st = M.state
  if not st or st.phase == "ready" or st.phase == "overtime" then
    return nil
  end
  now = st.paused_at or now or M.time()
  return math.max(0, st.duration - (now - st.started))
end

--- Seconds since the current phase started (for overtime: past the end of
--- the pomodoro).
---@param now? number
---@return number|nil
function M.elapsed(now)
  local st = M.state
  if not st or st.phase == "ready" then
    return nil
  end
  now = st.paused_at or now or M.time()
  return math.max(0, now - st.started)
end

---@class org.PomodoroInfo
---@field phase string "work", "overtime", "short_break", "long_break" or "ready"
---@field remaining number|nil seconds left (nil when ready or in overtime)
---@field elapsed number|nil seconds since the phase started
---@field paused boolean
---@field count integer pomodoros finished in the session
---@field title string the entry
---@field overtime boolean

--- The session for other code (a statusline, the sidebar extension): nil
--- when none runs, else a copy of its state.
---@return org.PomodoroInfo|nil
function M.info()
  local st = M.state
  if not st then
    return nil
  end
  return {
    phase = st.phase,
    remaining = M.remaining(),
    elapsed = M.elapsed(),
    paused = st.paused_at ~= nil,
    count = st.count,
    title = st.title,
    overtime = st.phase == "overtime",
  }
end

local function stop_timer()
  if timer then
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
    timer = nil
  end
end

local function start_timer()
  if timer then
    return
  end
  timer = vim.uv.new_timer()
  timer:start(
    1000,
    1000,
    vim.schedule_wrap(function()
      local ok, err = pcall(M.tick)
      if not ok then
        -- once, not every second
        stop_timer()
        utils.error("pomodoro: " .. tostring(err) .. " (timer stopped; pomodoro_start goes on)")
      end
    end)
  )
end

local function begin(phase, now)
  local st = M.state
  st.phase = phase
  st.started = now or M.time()
  st.paused_at = nil
  st.duration = (phase == "ready" or phase == "overtime") and 0 or minutes(phase)
  if phase == "ready" then
    stop_timer()
  else
    start_timer()
  end
  save()
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "OrgPomodoroPhase",
    data = { phase = phase, count = st.count, title = st.title },
    modeline = false,
  })
  redraw()
end

local function fmt(seconds)
  seconds = math.ceil(seconds)
  local h, m, s = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60
  if h > 0 then
    return string.format("%d:%02d:%02d", h, m, s)
  end
  return string.format("%d:%02d", m, s)
end

local function start_work(now)
  if not clock_in() then
    return false
  end
  begin("work", now)
  return true
end

local function break_kind()
  local every = tonumber(opts().long_break_every) or 0
  if every > 0 and M.state.count > 0 and M.state.count % every == 0 then
    return "long_break"
  end
  return "short_break"
end

--- The current phase ended (or was skipped).
---@param now number
---@param skipped? boolean
local function finish(now, skipped)
  local st = M.state
  local o = opts()
  if st.phase == "work" and not skipped and o.manual_break then
    -- org-pomodoro-overtime: the clock runs on until pomodoro_start
    M.notify(string.format("Pomodoro done (%s): now on overtime; pomodoro_start starts the break", st.title))
    begin("overtime", now)
    return
  end
  if st.phase == "work" or st.phase == "overtime" then
    if not skipped or st.phase == "overtime" then
      st.count = st.count + 1
      count_pomodoro()
    end
    if o.clock_out_on_break ~= false then
      clock_out()
    end
    local kind = break_kind()
    local mins = minutes(kind) / 60
    if not skipped then
      M.notify(
        string.format(
          "Pomodoro %d done (%s): time for a %s break (%s min)",
          st.count,
          st.title,
          kind == "long_break" and "long" or "short",
          (string.format("%g", mins))
        )
      )
    end
    if o.auto_start_breaks ~= false then
      begin(kind, now)
    else
      begin("ready", now)
    end
  else
    if not skipped then
      M.notify("Break over: back to " .. st.title)
    end
    if o.auto_start_work then
      start_work(now)
    else
      begin("ready", now)
    end
  end
end

--- Check the running phase; called every second by the timer (and by
--- specs with a fake `now`).
---@param now? number
function M.tick(now)
  local st = M.state
  if not st then
    stop_timer()
    return
  end
  if st.phase == "ready" or st.paused_at then
    return
  end
  now = now or M.time()
  -- several phases may have passed (a suspended machine): catch up one by one
  local guard = 0
  while M.state and M.state.phase ~= "ready" and M.state.phase ~= "overtime" and not M.state.paused_at do
    local left = M.state.duration - (now - M.state.started)
    if left > 0 or guard >= 100 then
      break
    end
    finish(M.state.started + M.state.duration)
    guard = guard + 1
  end
  redraw()
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

--- Start a pomodoro (org-pomodoro) on the heading at the cursor; outside
--- an org heading, the entry of the current session (after a break).
--- While a pomodoro runs on another entry, it moves to this one. In
--- overtime it ends the pomodoro and starts the break.
---@param target? org.Target
function M.start(target)
  local now = M.time()
  if M.state and M.state.phase == "overtime" then
    M.state.paused_at = nil
    finish(now, false)
    return M.state
  end
  local bufnr, lnum
  local here = vim.bo.filetype == "org" or (target and target.bufnr)
  if here then
    local b, _, hl = require("org.edit").resolve(target)
    if hl then
      bufnr, lnum = b, hl.line
    end
  end
  if not bufnr then
    if M.state and entry_line() then
      if M.state.phase == "work" then
        utils.notify("Pomodoro already running: " .. M.state.title)
        return
      end
      return start_work(now)
    end
    utils.warn("Pomodoro: not on a heading")
    return
  end
  local hl = require("org.files").get_buffer(bufnr):headline_at(lnum)
  local st = M.state
  if st and st.bufnr == bufnr and entry_line() == lnum and st.phase == "work" then
    if st.paused_at then
      return M.resume()
    end
    utils.notify("Pomodoro already running: " .. st.title)
    return
  end
  if st and st.bufnr and st.mark and vim.api.nvim_buf_is_valid(st.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, st.bufnr, ns, st.mark)
  end
  M.state = {
    phase = "ready",
    started = now,
    duration = 0,
    count = st and st.count or 0,
    bufnr = bufnr,
    mark = vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {}),
    path = vim.api.nvim_buf_get_name(bufnr) ~= "" and vim.api.nvim_buf_get_name(bufnr) or nil,
    title = hl:plain_title(),
  }
  if start_work(now) then
    local mins = string.format("%g", minutes("work") / 60)
    utils.notify(string.format("Pomodoro started: %s (%s min)", M.state.title, mins))
  end
  return M.state
end

--- Pause the running phase (the clock stops with `clock_out_on_break`),
--- or resume a paused one.
function M.pause()
  local st = M.state
  if not st or st.phase == "ready" then
    utils.notify("No pomodoro running")
    return
  end
  if st.paused_at then
    return M.resume()
  end
  st.paused_at = M.time()
  if (st.phase == "work" or st.phase == "overtime") and opts().clock_out_on_break ~= false then
    clock_out()
  end
  save()
  utils.notify("Pomodoro paused")
  redraw()
end

--- Resume a paused phase.
function M.resume()
  local st = M.state
  if not st or not st.paused_at then
    utils.notify("No paused pomodoro")
    return
  end
  local now = M.time()
  st.started = st.started + (now - st.paused_at)
  st.paused_at = nil
  if st.phase == "work" or st.phase == "overtime" then
    clock_in()
  end
  start_timer()
  save()
  utils.notify("Pomodoro resumed")
  redraw()
end

--- Stop the session (org-pomodoro-kill): the running pomodoro is not
--- counted and the clock stops.
function M.stop()
  local st = M.state
  if not st then
    utils.notify("No pomodoro running")
    return
  end
  if st.phase == "work" or st.phase == "overtime" then
    clock_out()
  end
  stop_timer()
  if st.bufnr and st.mark and vim.api.nvim_buf_is_valid(st.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, st.bufnr, ns, st.mark)
  end
  M.state = nil
  save()
  utils.notify("Pomodoro stopped")
  redraw()
end

--- End the current phase now: a skipped pomodoro is not counted and goes
--- to its break; a skipped break starts the next pomodoro. Overtime ends
--- the pomodoro, counted.
function M.skip()
  local st = M.state
  if not st then
    utils.notify("No pomodoro running")
    return
  end
  local now = M.time()
  if st.phase == "ready" then
    return start_work(now)
  end
  local was_break = st.phase ~= "work" and st.phase ~= "overtime"
  st.paused_at = nil
  finish(now, st.phase ~= "overtime")
  if was_break and M.state and M.state.phase == "ready" then
    start_work(now)
  end
end

--- Show the current phase and time left.
function M.status()
  local s = M.statusline()
  utils.notify(s ~= "" and ("Pomodoro: " .. s .. " - " .. (M.state and M.state.title or "")) or "No pomodoro running")
end

local SUBCOMMANDS = { "start", "pause", "resume", "stop", "skip", "status" }

--- `:Org pomodoro [start|pause|resume|stop|skip|status]`.
---@param args? string
function M.command(args)
  local sub = vim.trim(args or "")
  local fns = {
    [""] = M.start,
    start = M.start,
    pause = M.pause,
    resume = M.resume,
    stop = M.stop,
    skip = M.skip,
    status = M.status,
  }
  local fn = fns[sub]
  if not fn then
    utils.error("Unknown :Org pomodoro argument: " .. sub)
    return
  end
  return fn()
end

--- Statusline component: `"🍅 24:13 (1)"` while working, `"☕ 4:59"` on a
--- break, `"⏸ 🍅 12:00"` paused, `"🍅 +2:10 (1)"` in overtime, `"🍅 ready
--- (2)"` between pomodoros; empty when no session runs. The number is the
--- pomodoros finished in this session.
---@return string
function M.statusline()
  local st = M.state
  if not st then
    return ""
  end
  local icons = vim.tbl_extend("force", M.defaults.icons, opts().icons or {})
  local count = st.count > 0 and string.format(" (%d)", st.count) or ""
  if st.phase == "ready" then
    return string.format("%s ready%s", icons.ready, count)
  end
  local s
  if st.phase == "overtime" then
    s = string.format("%s +%s%s", icons.overtime or icons.work, fmt(M.elapsed() or 0), count)
  else
    s = string.format("%s %s%s", icons[st.phase] or "", fmt(M.remaining() or 0), count)
  end
  if st.paused_at then
    s = icons.paused .. " " .. s
  end
  return s
end

--- Go on with the pomodoro of a previous Neovim (or of the previous
--- setup()) from `state_file`: a phase that is still running, paused or
--- in overtime. One that ended meanwhile is dropped. The clock is not
--- touched after a restart (clock.persist restores it); after a new
--- setup() in the same Neovim a running pomodoro clocks in again.
---@return org.PomodoroState|nil
function M.restore()
  if M.state then
    return M.state
  end
  local f = state_file()
  local data = f and utils.read_json(f)
  if type(data) ~= "table" or type(data.phase) ~= "string" or data.phase == "ready" then
    return nil
  end
  local now = M.time()
  local started, duration = tonumber(data.started), tonumber(data.duration) or 0
  local paused_at = tonumber(null(data.paused_at))
  if not started then
    return nil
  end
  -- another Neovim still runs it
  local pid = tonumber(data.pid)
  if pid and pid ~= vim.fn.getpid() and vim.uv.kill(pid, 0) == 0 then
    return nil
  end
  local running = data.phase == "overtime" or paused_at or now < started + duration
  if not running or not null(data.path) then
    vim.fn.delete(f)
    return nil
  end
  M.state = {
    phase = data.phase,
    started = started,
    duration = duration,
    paused_at = paused_at,
    count = tonumber(data.count) or 0,
    path = null(data.path),
    lnum = tonumber(null(data.lnum)),
    title = tostring(data.title or ""),
  }
  if not paused_at then
    start_timer()
  end
  if torn_down and not paused_at and (data.phase == "work" or data.phase == "overtime") then
    pcall(clock_in)
  end
  redraw()
  return M.state
end

---------------------------------------------------------------------------
-- Extension
---------------------------------------------------------------------------

M.actions = {
  pomodoro_start = {
    "org.extensions.pomodoro",
    "start",
    desc = "Pomodoro: start on the heading (or the session's entry)",
    global = true,
  },
  pomodoro_pause = { "org.extensions.pomodoro", "pause", desc = "Pomodoro: pause / resume", global = true },
  pomodoro_stop = { "org.extensions.pomodoro", "stop", desc = "Pomodoro: stop the session", global = true },
  pomodoro_skip = { "org.extensions.pomodoro", "skip", desc = "Pomodoro: end the current phase now", global = true },
  pomodoro_status = { "org.extensions.pomodoro", "status", desc = "Pomodoro: show the time left", global = true },
}

M.commands = {
  pomodoro = {
    "org.extensions.pomodoro",
    "command",
    desc = "Pomodoro: :Org pomodoro [start|pause|resume|stop|skip|status]",
    complete = function()
      return SUBCOMMANDS
    end,
  },
}

M.mappings = {
  global = {
    pomodoro_start = "<prefix>zs",
    pomodoro_pause = "<prefix>zp",
    pomodoro_stop = "<prefix>zx",
    pomodoro_skip = "<prefix>zn",
    pomodoro_status = "<prefix>zi",
  },
}

M.groups = { { "z", "pomodoro" } }

local augroup

function M.setup(o)
  local org = require("org")
  if org.statusline_components then
    org.statusline_components.pomodoro = o.statusline ~= false and M.statusline or nil
  end
  augroup = vim.api.nvim_create_augroup("org.pomodoro", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      pcall(save)
    end,
  })
  local ok, err = pcall(M.restore)
  if not ok then
    utils.warn("pomodoro: could not restore the last session: " .. tostring(err))
  end
  torn_down = nil
end

function M.teardown()
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  if M.state then
    -- kept in state_file: a following setup() goes on with it
    pcall(save)
    stop_timer()
    if (M.state.phase == "work" or M.state.phase == "overtime") and not M.state.paused_at then
      pcall(clock_out)
    end
    M.state = nil
    torn_down = true
  end
  local org = require("org")
  if org.statusline_components then
    org.statusline_components.pomodoro = nil
  end
end

function M.health(h, o)
  for _, k in ipairs({ "work", "short_break", "long_break" }) do
    if not (tonumber(o[k]) and tonumber(o[k]) > 0) then
      h.error(string.format("pomodoro: %s must be a positive number of minutes", k))
    end
  end
  if o.system_notification and not require("org.agenda.notifications").desktop_backend() then
    h.warn("pomodoro: no osascript, notify-send or powershell.exe for desktop notifications")
  else
    h.ok(
      string.format(
        "pomodoro: %g/%g/%g min, long break every %d",
        o.work,
        o.short_break,
        o.long_break,
        o.long_break_every
      )
    )
  end
  if M.state then
    h.info("pomodoro: " .. M.statusline() .. " " .. M.state.title)
  end
end

return M
