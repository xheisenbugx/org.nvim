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
  --- Clock out while on a break (and while paused).
  clock_out_on_break = true,
  --- Property counting the finished pomodoros of an entry; false for none.
  property = "POMODOROS",
  --- Also send a desktop notification (osascript / notify-send).
  system_notification = true,
  --- Command run when a phase ends, e.g. `{ "afplay", "/System/Library/Sounds/Glass.aiff" }`
  --- or a shell string; false for none (`clock.sound` still applies).
  sound = false,
  --- Add the pomodoro to `require("org").statusline()`.
  statusline = true,
  --- Statusline icons.
  icons = { work = "🍅", short_break = "☕", long_break = "🌴", paused = "⏸", ready = "🍅" },
}

local ns = vim.api.nvim_create_namespace("org_pomodoro")

--- Current time in seconds (os.time with sub-second steps); specs
--- replace it with a fake clock.
---@return number
do
  local base_os, base_uv = os.time(), vim.uv.now() / 1000
  M.time = function()
    return base_os + (vim.uv.now() / 1000 - base_uv)
  end
end

---@class org.PomodoroState
---@field phase "work"|"short_break"|"long_break"|"ready"
---@field started number seconds
---@field duration number seconds
---@field paused_at number|nil
---@field count integer pomodoros finished in this session
---@field bufnr integer|nil the entry's buffer
---@field mark integer|nil extmark on the entry's headline
---@field title string

---@type org.PomodoroState|nil
M.state = nil

local timer

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
-- Notifications
---------------------------------------------------------------------------

local function system_notify(title, body)
  if vim.fn.has("mac") == 1 and vim.fn.executable("osascript") == 1 then
    local esc = function(s)
      return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
    end
    pcall(vim.system, {
      "osascript",
      "-e",
      string.format('display notification "%s" with title "%s"', esc(body), esc(title)),
    })
  elseif vim.fn.executable("notify-send") == 1 then
    pcall(vim.system, { "notify-send", "--app-name=org.nvim", title, body })
  end
end

--- Tell the user a phase ended: `clock.notification_handler` (or
--- vim.notify) and `clock.sound` through org.clock's notifier, a desktop
--- notification and the `sound` command.
---@param msg string
function M.notify(msg)
  local o = opts()
  require("org.clock").notify(msg)
  if o.system_notification and #vim.api.nvim_list_uis() > 0 then
    system_notify("Pomodoro", msg)
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

--- Line of the pomodoro's entry, or nil when it is gone.
local function entry_line(st)
  st = st or M.state
  if not (st and st.bufnr and st.mark and vim.api.nvim_buf_is_valid(st.bufnr)) then
    return nil
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(st.bufnr, ns, st.mark, {})
  if not pos[1] then
    return nil
  end
  local hl = require("org.files").get_buffer(st.bufnr):headline_at(pos[1] + 1)
  return hl and hl.line or nil
end

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

--- Seconds left in the current phase (nil when idle or ready).
---@param now? number
---@return number|nil
function M.remaining(now)
  local st = M.state
  if not st or st.phase == "ready" then
    return nil
  end
  now = st.paused_at or now or M.time()
  return math.max(0, st.duration - (now - st.started))
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
        utils.error("pomodoro: " .. tostring(err))
      end
    end)
  )
end

local function begin(phase, now)
  local st = M.state
  st.phase = phase
  st.started = now or M.time()
  st.paused_at = nil
  st.duration = phase == "ready" and 0 or minutes(phase)
  if phase == "ready" then
    stop_timer()
  else
    start_timer()
  end
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
  if st.phase == "work" then
    if not skipped then
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
  while M.state and M.state.phase ~= "ready" and not M.state.paused_at and guard < 100 do
    local left = M.state.duration - (now - M.state.started)
    if left > 0 then
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
--- While a pomodoro runs on another entry, it moves to this one.
---@param target? org.Target
function M.start(target)
  local now = M.time()
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
  if st.phase == "work" and opts().clock_out_on_break ~= false then
    clock_out()
  end
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
  if st.phase == "work" then
    clock_in()
  end
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
  if st.phase == "work" then
    clock_out()
  end
  stop_timer()
  if st.bufnr and st.mark and vim.api.nvim_buf_is_valid(st.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, st.bufnr, ns, st.mark)
  end
  M.state = nil
  utils.notify("Pomodoro stopped")
  redraw()
end

--- End the current phase now: a skipped pomodoro is not counted and goes
--- to its break; a skipped break starts the next pomodoro.
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
  local was_break = st.phase ~= "work"
  st.paused_at = nil
  finish(now, true)
  if was_break and M.state and M.state.phase == "ready" then
    start_work(now)
  end
end

--- Show the current phase and time left.
function M.status()
  local s = M.statusline()
  utils.notify(s ~= "" and ("Pomodoro: " .. s .. " - " .. (M.state and M.state.title or "")) or "No pomodoro running")
end

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
--- break, `"⏸ 🍅 12:00"` paused, `"🍅 ready (2)"` between pomodoros;
--- empty when no session runs. The number is the pomodoros finished in
--- this session.
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
  local s = string.format("%s %s%s", icons[st.phase] or "", fmt(M.remaining() or 0), count)
  if st.paused_at then
    s = icons.paused .. " " .. s
  end
  return s
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

function M.setup(o)
  local org = require("org")
  if org.statusline_components then
    org.statusline_components.pomodoro = o.statusline ~= false and M.statusline or nil
  end
end

function M.teardown()
  if M.state then
    stop_timer()
    if M.state.phase == "work" and not M.state.paused_at then
      pcall(clock_out)
    end
    M.state = nil
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
  if o.system_notification and vim.fn.executable("osascript") == 0 and vim.fn.executable("notify-send") == 0 then
    h.warn("pomodoro: no osascript or notify-send for desktop notifications")
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
end

return M
