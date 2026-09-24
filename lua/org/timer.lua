---@mod org.timer Relative timer and countdown (org-timer)

local utils = require("org.utils")

local M = {}

---@type { start: number, paused_at?: number }|nil
M.state = nil
local countdown_timer

local function now()
  return vim.uv.hrtime() / 1e9
end

--- Elapsed seconds of the relative timer.
function M.elapsed()
  local st = M.state
  if not st then
    return 0
  end
  local t = st.paused_at or now()
  return math.max(0, math.floor(t - st.start))
end

function M.format(seconds)
  seconds = math.floor(seconds)
  return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60)
end

--- Start (or restart) the relative timer. Argument: optional offset "H:MM:SS".
function M.start(args)
  local offset = 0
  if type(args) == "string" and args ~= "" then
    local h, m, s = args:match("^(%d+):(%d%d):(%d%d)$")
    if h then
      offset = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
    else
      offset = (tonumber(args) or 0) * 60
    end
  end
  M.state = { start = now() - offset }
  utils.notify("Timer started")
  return true
end

function M.stop()
  if not M.state then
    utils.notify("No running timer")
    return nil
  end
  local e = M.elapsed()
  M.state = nil
  utils.notify("Timer stopped at " .. M.format(e))
  return e
end

function M.pause_or_continue()
  local st = M.state
  if not st then
    utils.notify("No running timer")
    return nil
  end
  if st.paused_at then
    st.start = st.start + (now() - st.paused_at)
    st.paused_at = nil
    utils.notify("Timer continued")
  else
    st.paused_at = now()
    utils.notify("Timer paused at " .. M.format(M.elapsed()))
  end
  return true
end

--- Insert the timer value at the cursor. In a list item, start a new
--- description item "- 0:12:34 :: ".
function M.insert()
  if not M.state then
    M.start()
  end
  local value = M.format(M.elapsed())
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

--- Start a countdown of `args` minutes (prompted when empty).
function M.countdown(args)
  local minutes = tonumber(args)
  if not minutes then
    local v = utils.input({ prompt = "Countdown minutes: ", default = "25" })
    minutes = tonumber(v)
  end
  if not minutes then
    return nil
  end
  if countdown_timer then
    countdown_timer:stop()
    countdown_timer:close()
  end
  countdown_timer = vim.uv.new_timer()
  countdown_timer:start(math.floor(minutes * 60 * 1000), 0, function()
    vim.schedule(function()
      utils.notify(string.format("Countdown of %s minutes finished", minutes), vim.log.levels.WARN)
      if countdown_timer then
        countdown_timer:close()
        countdown_timer = nil
      end
    end)
  end)
  utils.notify(string.format("Countdown started: %s minutes", minutes))
  return true
end

return M
