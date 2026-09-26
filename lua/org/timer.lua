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

local function cfg()
  return require("org.config").opts.timer or {}
end

local function fire(pattern, data)
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = pattern, data = data or {}, modeline = false })
end

--- Complete "SS" or "M:SS" to "H:MM:SS" (org-timer-fix-incomplete).
local function fix_incomplete(hms)
  local a, b, c = hms:match("(%d+):(%d+):(%d+)")
  if not a then
    b, c = hms:match("(%d+):(%d+)")
    if not b then
      c = hms:match("(%d+)")
    end
  end
  if not c then
    return nil
  end
  return string.format("%d:%02d:%02d", tonumber(a) or 0, tonumber(b) or 0, tonumber(c))
end

--- "[-]H:MM:SS" to seconds (org-timer-hms-to-secs); 0 when not a timer value.
local function hms_to_secs(hms)
  local sign, h, m, sec = (hms or ""):match("([-+]?)(%d+):(%d%d):(%d%d)")
  if not h then
    return 0
  end
  local v = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(sec)
  return sign == "-" and -v or v
end

--- Seconds of a countdown length: plain digits are minutes, else
--- [[H:]M:]S like Emacs (org-timer-set-timer).
local function countdown_secs(str)
  str = vim.trim(tostring(str or ""))
  if str:match("^%d+$") then
    str = str .. ":00"
  end
  local fixed = fix_incomplete(str)
  return fixed and hms_to_secs(fixed) or nil
end

--- The timer value as inserted in the buffer (org-timer-value-string).
local function value_string()
  local fmt = cfg().format or "%s "
  return (fmt:gsub("%%s", M.format(M.value()), 1))
end

--- Start (or restart) the relative timer (org-timer-start). `args` is an
--- offset "H:MM:SS" (a bare number is seconds, "M:SS" minutes and seconds);
--- interactively a count asks for it, defaulting to the timer value at the
--- cursor. A count of 16 shifts the timer values of the selection instead.
function M.start(args)
  if args == nil and vim.v.count >= 16 then
    return M.change_times_in_region()
  end
  if M.state and M.state.countdown then
    utils.warn("Countdown timer is running.  Cancel first")
    return nil
  end
  if args == nil and vim.v.count > 0 then
    local line = vim.api.nvim_get_current_line()
    local def = line:match("[-+]?%d+:%d%d:%d%d") or "0:00:00"
    args = utils.input({ prompt = "Restart timer with offset [" .. def .. "]: " })
    if args == nil then
      return nil
    end
    if not args:match("%S") then
      args = def
    end
  end
  local offset = 0
  if type(args) == "number" then
    offset = args
  elseif type(args) == "string" and args ~= "" then
    offset = hms_to_secs(fix_incomplete(args) or "")
  end
  M.state = { start = now() - offset }
  utils.notify(
    string.format(
      "Timer start time set to %s, current value is %s",
      os.date("%H:%M:%S", os.time() - offset),
      M.format(offset)
    )
  )
  fire("OrgTimerStart")
  vim.cmd("redrawstatus")
  return true
end

--- Shift every timer value (H:MM:SS) in the selection, or the current
--- line, by `delta` (org-timer-change-times-in-region). Without `delta`,
--- ask for it, defaulting to the value that makes the first one 0:00:00.
---@param delta? string like "-1:08:26"
function M.change_times_in_region(delta, s, e)
  if not s then
    local mode = vim.fn.mode()
    if mode == "v" or mode == "V" or mode == "\22" then
      s, e = vim.fn.line("v"), vim.fn.line(".")
      if s > e then
        s, e = e, s
      end
      vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    else
      s = vim.api.nvim_win_get_cursor(0)[1]
      e = s
    end
  end
  local lines = vim.api.nvim_buf_get_lines(0, s - 1, e, false)
  local pat = "[-+]?%d+:%d%d:%d%d"
  if delta == nil then
    delta = utils.input({ prompt = 'Enter time difference like "-1:08:26".  Default is first time to zero: ' })
    if delta == nil then
      return nil
    end
  end
  if not delta:match("%S") then
    local first = table.concat(lines, "\n"):match(pat)
    if not first then
      utils.warn("No change")
      return nil
    end
    delta = first:sub(1, 1) == "-" and first:sub(2) or ("-" .. first)
  end
  local sign = delta:match("^%s*%-") and -1 or 1
  local d = hms_to_secs(fix_incomplete(delta:gsub("^%s*[-+]", "")) or "") * sign
  if d == 0 then
    utils.warn("No change")
    return nil
  end
  for i, l in ipairs(lines) do
    lines[i] = l:gsub(pat, function(v)
      local secs = hms_to_secs(v) + d
      return (secs < 0 and "-" or "") .. M.format(math.abs(secs))
    end)
  end
  vim.api.nvim_buf_set_lines(0, s - 1, e, false, lines)
  return true
end

--- Stop the relative or countdown timer (org-timer-stop).
function M.stop()
  if not M.state then
    utils.notify("No running timer")
    return nil
  end
  local v = M.value()
  fire("OrgTimerStop")
  M.state = nil
  stop_countdown_timer()
  utils.notify("Timer stopped")
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
      -- org-notify, with the clock's notification handler and sound
      require("org.clock").notify(string.format("%s: time out", st.title or "Timer"))
      fire("OrgTimerDone", { title = st.title })
      stop_countdown_timer()
      M.state = nil
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
    fire("OrgTimerContinue")
    utils.notify("Timer continues at " .. M.format(M.value()))
  else
    fire("OrgTimerPause")
    st.paused_at = now()
    stop_countdown_timer()
    utils.notify("Timer paused at " .. M.format(M.value()))
  end
  vim.cmd("redrawstatus")
  return true
end

--- Insert the timer value after the cursor, formatted with `timer.format`
--- (org-timer). Starts the relative timer when none runs; a count restarts
--- it (C-u), 16 shifts the timer values of the selection instead (C-u C-u).
function M.insert()
  local count = vim.v.count
  if count >= 16 then
    return M.change_times_in_region()
  end
  if count > 0 or not M.state then
    M.start("")
  end
  local text = value_string()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local at = #line == 0 and 0 or col + 1
  vim.api.nvim_buf_set_text(0, lnum - 1, at, lnum - 1, at, { text })
  vim.api.nvim_win_set_cursor(0, { lnum, math.max(at + #text - 1, 0) })
  return true
end

local ITEM = "^(%s*)([-+*])%s+"
local OITEM = "^(%s*)(%d+)([.)])%s+"

--- Insert a description item with the timer value, "- 0:12:34 :: "
--- (org-timer-item). In a list of timer items the new item goes below the
--- current one; in another kind of list this is an error; elsewhere the
--- current line starts a new list. A count restarts the timer.
function M.insert_item()
  if vim.v.count > 0 or not M.state then
    M.start("")
  end
  local value = M.format(M.value()) .. " :: "
  local buf = 0
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- the item around the cursor
  local item
  for i = lnum, 1, -1 do
    local l = lines[i]
    if l:match(ITEM) and not l:match("^%*") or l:match(OITEM) then
      item = i
      break
    end
    if l:match("^%*+%s") or (i < lnum and l:match("^%S") and not l:match(ITEM)) then
      break
    end
  end
  if item then
    local l = lines[item]
    local indent, bullet = l:match(ITEM)
    local num, delim
    if not indent then
      indent, num, delim = l:match(OITEM)
    end
    local _, prefix_end = l:find(bullet and ITEM or OITEM)
    local rest = l:sub(prefix_end + 1):gsub("^%[[ Xx-]%]%s+", "")
    if not rest:match("^[-+]?%d+:%d%d:%d%d%s+::") then
      utils.error("This is not a timer list")
      return nil
    end
    -- below the item and its continuation lines
    local last = item
    for i = item + 1, #lines do
      local li = lines[i]
      if li:match("^%s*$") or #(li:match("^(%s*)")) > #indent then
        last = i
      else
        break
      end
    end
    while last > item and lines[last]:match("^%s*$") do
      last = last - 1
    end
    local new = indent .. (bullet or (tostring(tonumber(num) + 1) .. delim)) .. " " .. value
    vim.api.nvim_buf_set_lines(buf, last, last, false, { new })
    vim.api.nvim_win_set_cursor(0, { last + 1, #new })
    vim.cmd("startinsert!")
    return true
  end
  local line = lines[lnum]
  local indent = line:match("^(%s*)")
  local new = indent .. "- " .. value .. line:sub(#indent + 1)
  vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, { new })
  vim.api.nvim_win_set_cursor(0, { lnum, #indent + 2 + #value })
  utils.start_insert()
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
  -- org-get-heading: the headline without its stars
  return ok and hl and vim.trim((hl.raw:gsub("^%*+%s*", ""))) or nil
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

--- Start a countdown (org-timer-set-timer). `args` is minutes or
--- [H:]M:SS. Interactively a count gives the minutes; otherwise the entry's
--- Effort, else a prompt (suggesting `timer.default_timer` unless "0").
function M.countdown(args)
  if M.state and not M.state.countdown then
    utils.warn("Relative timer is running.  Stop first")
    return nil
  end
  local minutes = args ~= nil and args ~= "" and tostring(args) or nil
  if not minutes and vim.v.count > 0 then
    minutes = tostring(vim.v.count)
  end
  if not minutes then
    local effort = entry_effort()
    minutes = effort and effort > 0 and tostring(math.floor(effort)) or nil
  end
  if not minutes then
    local def = tostring(cfg().default_timer or "0")
    minutes = utils.input({
      prompt = "How much time left? (minutes or h:mm:ss) ",
      default = def ~= "0" and def or nil,
    })
    if minutes == nil then
      return nil
    end
  end
  if not minutes:match("%d") then
    return M.show_remaining()
  end
  local secs = countdown_secs(minutes)
  if not secs or secs <= 0 then
    return nil
  end
  if M.state and M.state.countdown and not utils.confirm("Replace current timer?") then
    utils.notify("No timer set")
    return nil
  end
  M.state = { start = now(), countdown = secs, title = entry_title() or vim.fn.bufname() }
  arm_countdown()
  fire("OrgTimerSet", { seconds = secs })
  vim.cmd("redrawstatus")
  return true
end

--- Show the remaining countdown time (org-timer-show-remaining-time).
function M.show_remaining()
  if not (M.state and M.state.countdown) then
    utils.notify("No timer set")
    return nil
  end
  local v = M.value()
  utils.notify(string.format("%d minute(s) %d seconds left before next time out", math.floor(v / 60), v % 60))
  return true
end

--- Statusline component: `"⏲ 0:12:34"`, with `" (paused)"` appended while
--- paused (empty without a timer). `require("org").statusline()` combines
--- this with the clock.
---@return string
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
