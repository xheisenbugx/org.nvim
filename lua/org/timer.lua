---@mod org.timer Relative timer and countdown (org-timer)
---
--- One timer runs at a time, like Emacs: either a relative timer counting
--- up from its start, or a countdown (`org-timer-set-timer`) counting down.
--- Pause, stop and insert work on both; during a countdown the inserted
--- value is the remaining time.

local utils = require("org.utils")

local M = {}

---@class org.TimerState
---@field start number time (seconds) the relative timer counts from
---@field paused_at? number
---@field countdown? number countdown length in seconds
---@field title? string countdown title

---@type org.TimerState|nil
M.state = nil
local countdown_timer

local function now()
  return vim.uv.hrtime() / 1e9
end

local function stop_countdown_timer()
  if countdown_timer then
    countdown_timer:stop()
    countdown_timer:close()
    countdown_timer = nil
  end
end

--- Elapsed seconds since the timer started (paused time excluded).
function M.elapsed()
  local st = M.state
  if not st then
    return 0
  end
  local t = st.paused_at or now()
  return math.max(0, math.floor(t - st.start))
end

--- Seconds shown by the timer: elapsed, or remaining for a countdown.
function M.value()
  local st = M.state
  if st and st.countdown then
    return math.max(0, st.countdown - M.elapsed())
  end
  return M.elapsed()
end

function M.format(seconds)
  seconds = math.floor(seconds)
  return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60)
end

--- Parse a timer value into seconds like Emacs: "25" is minutes, "1:30"
--- is M:SS and "1:30:00" is H:MM:SS (org-timer-fix-incomplete).
local function parse_hms(str)
  str = vim.trim(str or "")
  local h, m, s = str:match("^(%d+):(%d+):(%d+)$")
  if h then
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
  end
  m, s = str:match("^(%d+):(%d+)$")
  if m then
    return tonumber(m) * 60 + tonumber(s)
  end
  local n = tonumber(str)
  return n and math.floor(n * 60) or nil
end

--- Start (or restart) the relative timer. `args` is an optional offset,
--- "H:MM:SS" or minutes; interactively a count prompts for it
--- (org-timer-start with C-u).
function M.start(args)
  if M.state and M.state.countdown then
    utils.warn("A countdown timer is running. Stop it first")
    return nil
  end
  if args == nil and vim.v.count > 0 then
    args = utils.input({ prompt = "Restart timer with offset: ", default = "0:00:00" })
    if args == nil then
      return nil
    end
  end
  local offset = 0
  if type(args) == "string" and args ~= "" then
    offset = parse_hms(args) or 0
  end
  M.state = { start = now() - offset }
  utils.notify("Timer started")
  return true
end

--- Stop the relative or countdown timer (org-timer-stop).
function M.stop()
  if not M.state then
    utils.notify("No running timer")
    return nil
  end
  local v = M.value()
  M.state = nil
  stop_countdown_timer()
  utils.notify("Timer stopped at " .. M.format(v))
  vim.cmd("redrawstatus")
  return v
end

local function arm_countdown()
  stop_countdown_timer()
  local st = M.state
  local remaining = M.value()
  countdown_timer = vim.uv.new_timer()
  countdown_timer:start(math.floor(remaining * 1000), 0, function()
    vim.schedule(function()
      if M.state ~= st then
        return
      end
      stop_countdown_timer()
      M.state = nil
      utils.notify(string.format("%s: time out", st.title or "Timer"), vim.log.levels.WARN)
      pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "OrgTimerDone", data = { title = st.title } })
      vim.cmd("redrawstatus")
    end)
  end)
end

--- Pause or continue the running timer or countdown.
function M.pause_or_continue()
  local st = M.state
  if not st then
    utils.notify("No running timer")
    return nil
  end
  if st.paused_at then
    st.start = st.start + (now() - st.paused_at)
    st.paused_at = nil
    if st.countdown then
      arm_countdown()
    end
    utils.notify("Timer continued")
  else
    st.paused_at = now()
    stop_countdown_timer()
    utils.notify("Timer paused at " .. M.format(M.value()))
  end
  vim.cmd("redrawstatus")
  return true
end

--- Insert the timer value at the cursor (org-timer). Starts the relative
--- timer when none runs. In a list item, start a new description item
--- "- 0:12:34 :: ".
function M.insert()
  if not M.state then
    M.start("")
  end
  local value = M.format(M.value())
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  local indent, bullet = line:match("^(%s*)([-+*])%s")
  if not indent then
    indent, bullet = line:match("^(%s*)(%d+[.)])%s")
  end
  if bullet and not (indent == "" and bullet == "*") then
    local new = indent .. (bullet:match("%d") and "-" or bullet) .. " " .. value .. " :: "
    vim.api.nvim_buf_set_lines(0, lnum, lnum, false, { new })
    vim.api.nvim_win_set_cursor(0, { lnum + 1, #new })
    vim.cmd("startinsert!")
    return true
  end
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local at = #line == 0 and 0 or col + 1
  local text = value .. " "
  vim.api.nvim_buf_set_text(0, lnum - 1, at, lnum - 1, at, { text })
  vim.api.nvim_win_set_cursor(0, { lnum, at + #text - 1 })
  return true
end

--- Insert a description list item with the timer value, "- 0:12:34 :: "
--- (org-timer-item). On a list item, the new item goes below it with the
--- same indentation and bullet; otherwise it replaces an empty line or goes
--- below the current line. Starts the timer when not running.
function M.insert_item()
  if not M.state then
    M.start("")
  end
  local value = M.format(M.value())
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  local indent, bullet = line:match("^(%s*)([-+*])%s")
  if not indent then
    indent, bullet = line:match("^(%s*)(%d+[.)])%s")
  end
  if not bullet or (indent == "" and bullet == "*") then
    indent, bullet = line:match("^(%s*)") or "", "-"
  elseif bullet:match("%d") then
    bullet = "-"
  end
  local new = indent .. bullet .. " " .. value .. " :: "
  if line:match("^%s*$") then
    vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { new })
  else
    vim.api.nvim_buf_set_lines(0, lnum, lnum, false, { new })
    lnum = lnum + 1
  end
  vim.api.nvim_win_set_cursor(0, { lnum, #new })
  vim.cmd("startinsert!")
  return true
end

--- Title of the entry at the cursor, for countdown messages.
local function entry_title()
  if vim.bo.filetype ~= "org" then
    return nil
  end
  local ok, hl = pcall(function()
    return require("org.files").get_buffer(0):headline_at(vim.api.nvim_win_get_cursor(0)[1])
  end)
  return ok and hl and hl:plain_title() or nil
end

--- Effort of the entry at the cursor, in minutes.
local function entry_effort()
  if vim.bo.filetype ~= "org" then
    return nil
  end
  local ok, minutes = pcall(function()
    local hl = require("org.files").get_buffer(0):headline_at(vim.api.nvim_win_get_cursor(0)[1])
    return hl and require("org.properties").effort_minutes(hl)
  end)
  return ok and minutes or nil
end

--- Start a countdown (org-timer-set-timer). `args` is minutes or H:MM:SS;
--- otherwise a count gives the minutes, then the entry's Effort, then a
--- prompt (default 25 minutes).
function M.countdown(args)
  if M.state and not M.state.countdown then
    utils.warn("Relative timer is running. Stop first")
    return nil
  end
  local secs = type(args) == "string" and args ~= "" and parse_hms(args) or tonumber(args) and tonumber(args) * 60
  if not secs and vim.v.count > 0 then
    secs = vim.v.count * 60
  end
  if not secs then
    local effort = entry_effort()
    secs = effort and effort > 0 and effort * 60 or nil
  end
  if not secs then
    local v = utils.input({ prompt = "How much time left? (minutes or h:mm:ss) ", default = "25" })
    if v == nil then
      return nil
    end
    secs = parse_hms(v)
  end
  if not secs or secs <= 0 then
    return nil
  end
  if M.state and M.state.countdown and not utils.confirm("Replace current timer?") then
    utils.notify("No timer set")
    return nil
  end
  M.state = { start = now(), countdown = secs, title = entry_title() }
  arm_countdown()
  utils.notify(string.format("Timer set: %s", M.format(secs)))
  vim.cmd("redrawstatus")
  return true
end

--- Show the remaining countdown time (org-timer-show-remaining-time).
function M.show_remaining()
  if not (M.state and M.state.countdown) then
    utils.notify("No timer set")
    return nil
  end
  utils.notify(string.format("%s remaining for timer%s", M.format(M.value()), M.state.title and (" " .. M.state.title) or ""))
  return true
end

--- Statusline component: "⏲ 0:12:34" (empty without a timer).
function M.statusline()
  if not M.state then
    return ""
  end
  local s = "⏲ " .. M.format(M.value())
  if M.state.paused_at then
    s = s .. " (paused)"
  end
  return s
end

return M
