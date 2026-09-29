---@mod org.extensions.roam.dailies Daily notes (org-roam-dailies)
---
--- One file per day in `dailies.directory` (relative to the roam
--- directory), made from `dailies.capture_templates` whose targets are
--- relative to that directory.

local date = require("org.date")
local utils = require("org.utils")

local M = {}

local function ropts()
  return require("org.extensions").opts("roam") or require("org.extensions.roam").defaults
end

--- The dailies directory, absolute and without a trailing slash.
---@return string
function M.directory()
  local d = ropts().dailies.directory or "daily/"
  return (utils.expand(d, require("org.extensions.roam.db").directory()):gsub("/$", ""))
end

--- Whether `path` is a daily note (org-roam-dailies--daily-note-p).
---@param path string
---@return boolean
function M.is_daily(path)
  local dir = M.directory() .. "/"
  path = vim.fs.normalize(path or "")
  return path:sub(1, #dir) == dir and path:match("%.org$") ~= nil
end

--- The day `n` days from today (nil for today itself, so captures use the
--- current time).
local function day(n)
  if not n or n == 0 then
    return nil
  end
  return date.today():add(n, "d")
end

local function run(d, go, keys)
  local dir = M.directory()
  vim.fn.mkdir(dir, "p")
  return require("org.extensions.roam.capture").capture({
    templates = ropts().dailies.capture_templates,
    keys = keys,
    directory = dir,
    date = d,
    visit = go,
    node = { title = "" },
  })
end

local function count(n)
  n = tonumber(n)
  if n and n > 0 then
    return n
  end
  return vim.v.count > 0 and vim.v.count or 1
end

local function read_date(arg, prompt)
  if arg and vim.trim(arg) ~= "" then
    local d = date.read_date(vim.trim(arg), date.today())
    if not d then
      utils.warn("org-roam: cannot read date " .. arg)
    end
    return d
  end
  return require("org.calendar").pick({ prompt = prompt })
end

--- Open today's note, creating it (org-roam-dailies-goto-today).
function M.goto_today()
  return run(nil, true)
end

--- Open the note of `n` (a count, default 1) days ago.
---@param n? integer|string
function M.goto_yesterday(n)
  return run(day(-count(n)), true)
end

--- Open the note of `n` days ahead.
---@param n? integer|string
function M.goto_tomorrow(n)
  return run(day(count(n)), true)
end

--- Open the note of a date read from `arg` or picked in the calendar.
---@param arg? string
function M.goto_date(arg)
  local d = read_date(arg, "Goto daily note")
  if d then
    return run(d, true)
  end
end

--- Capture into today's note (org-roam-dailies-capture-today).
---@param keys? string template key
function M.capture_today(keys)
  return run(nil, false, keys)
end

--- Capture into the note of `n` days ago.
---@param n? integer|string
function M.capture_yesterday(n)
  return run(day(-count(n)), false)
end

--- Capture into the note of `n` days ahead.
---@param n? integer|string
function M.capture_tomorrow(n)
  return run(day(count(n)), false)
end

--- Capture into the note of a date read from `arg` or the calendar.
---@param arg? string
function M.capture_date(arg)
  local d = read_date(arg, "Capture to daily note")
  if d then
    return run(d, false)
  end
end

--- The daily note files, oldest first.
---@return string[]
function M.list()
  local dir = M.directory()
  if not utils.is_dir(dir) then
    return {}
  end
  local out = {}
  for _, p in ipairs(vim.fn.globpath(dir, "**/*.org", false, true)) do
    out[#out + 1] = vim.fs.normalize(p)
  end
  table.sort(out)
  return out
end

local function step(n)
  local path = vim.fs.normalize(vim.api.nvim_buf_get_name(0))
  if not M.is_daily(path) then
    utils.warn("org-roam: not in a daily note")
    return
  end
  local list = M.list()
  local i
  for k, p in ipairs(list) do
    if p == path then
      i = k
    end
  end
  if not i then
    -- an unsaved note: between the notes around it
    i = 0.5
    for k, p in ipairs(list) do
      if p < path then
        i = k + 0.5
      end
    end
  end
  local target = n > 0 and math.floor(i + n) or math.ceil(i + n)
  if target < 1 then
    utils.warn("org-roam: already at the oldest note")
    return
  elseif target > #list then
    utils.warn("org-roam: already at the newest note")
    return
  end
  require("org.extensions.roam.node").open(list[target], 1)
end

--- Go to the next daily note (org-roam-dailies-goto-next-note).
---@param n? integer|string
function M.goto_next_note(n)
  step(count(n))
end

--- Go to the previous daily note.
---@param n? integer|string
function M.goto_previous_note(n)
  step(-count(n))
end

--- Open the dailies directory (org-roam-dailies-find-directory).
function M.find_directory()
  local dir = M.directory()
  vim.fn.mkdir(dir, "p")
  vim.cmd("edit " .. vim.fn.fnameescape(dir))
end

return M
