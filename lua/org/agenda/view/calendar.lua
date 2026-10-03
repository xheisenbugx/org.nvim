---@mod org.agenda.view.calendar Calendar commands on the date at point, goto date, export
---
--- Part of org.agenda.view, which loads it.

local config = require("org.config")
local render = require("org.agenda.render")
local utils = require("org.utils")
local shared = require("org.agenda.view.shared")

local M = require("org.agenda.view")

local current_span = shared.current_span
local has_agenda_block = shared.has_agenda_block

---------------------------------------------------------------------------
-- Calendar commands on the date at point (org-agenda-convert-date, ...)
---------------------------------------------------------------------------

--- The Emacs absolute date of the day at point, or nil after an error
--- `msg` (org-agenda-execute-calendar-command needs a `day` property).
local function calendar_abs(msg)
  local day = M.day_at_cursor()
  if not day then
    utils.error(msg or "Don't know which date to use for the calendar command")
    return nil
  end
  return day + require("org.agenda.calendars").EPOCH_ABS
end

--- Show `lines` in a float closed by q / <Esc> (Emacs's temporary buffer).
local function show_calendar_text(title, lines)
  local buf, win = require("org.ui").float(lines, { title = title })
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end, { buffer = buf, nowait = true })
  end
  return buf, win
end

--- The date at point in other calendars (org-agenda-convert-date).
function M.convert_date()
  local abs = calendar_abs("Don't know which date to convert")
  if abs then
    return show_calendar_text("Dates", require("org.agenda.calendars").convert_lines(abs))
  end
end

--- The quarters of the moon in the three months around the date at point
--- (org-agenda-phases-of-moon).
function M.phases_of_moon()
  local abs = calendar_abs()
  if abs then
    local title, lines = require("org.agenda.calendars").phases_lines(abs)
    return show_calendar_text(title, lines)
  end
end

--- The holidays of the three months around the date at point
--- (org-agenda-holidays).
function M.holidays()
  local abs = calendar_abs()
  if not abs then
    return
  end
  local title, lines = require("org.agenda.calendars").holidays_lines(abs)
  if #lines == 0 then
    utils.notify("Looking up holidays...none found")
    return
  end
  return show_calendar_text(title, lines)
end

--- Read a number of degrees (solar-get-number), nil when cancelled.
local function read_degrees(prompt)
  local s = utils.input({ prompt = prompt })
  return s and tonumber(s)
end

--- Sunrise and sunset on the date at point (org-agenda-sunrise-sunset).
--- The location is `agenda.calendar_latitude/longitude`; it is asked for
--- when unset or with `ask` (a count, Emacs's prefix argument).
---@param ask? boolean
---@return string? message
function M.sunrise_sunset(ask)
  local abs = calendar_abs()
  if not abs then
    return
  end
  local ac = config.opts.agenda
  local lat, lon, name = ac.calendar_latitude, ac.calendar_longitude, ac.calendar_location_name
  if ask then
    lat, lon, name = nil, nil, "the given coordinates"
  end
  -- solar-setup: answers without a count are kept for the session
  lon = lon or read_degrees("Enter longitude (decimal fraction; + east, - west): ")
  if not lon then
    return
  end
  lat = lat or read_degrees("Enter latitude (decimal fraction; + north, - south): ")
  if not lat then
    return
  end
  if not ask then
    ac.calendar_latitude, ac.calendar_longitude = lat, lon
  end
  local cal = require("org.agenda.calendars")
  local msg = cal.gregorian_string(abs, true, true)
    .. ": "
    .. cal.sunrise_sunset_string(abs, lat, lon, { location = name })
  utils.notify(msg)
  return msg
end

--- Show day `day` (a day number) in the agenda (org-agenda-goto-date).
function M.goto_date(day)
  if not has_agenda_block() then
    require("org.agenda").open_agenda({ anchor = day })
    return
  end
  local span = current_span()
  local first
  for _, inf in pairs(M.state.info) do
    first = inf
    break
  end
  if not (first and day >= first.from and day <= first.to) then
    M.state.anchor = render.span_days(span, day) == 1 and day or render.starting_day(span, day)
  end
  M.refresh()
  for l, d in pairs(M.state.day_lines) do
    if d == day then
      pcall(vim.api.nvim_win_set_cursor, 0, { l, 0 })
    end
  end
end

--- Write the agenda to a file (org-agenda-write).
function M.export(path)
  if not M.state.buf or not vim.api.nvim_buf_is_valid(M.state.buf) then
    return
  end
  path = path
    or utils.input({ prompt = "Write agenda to file: ", default = vim.fn.expand("~/agenda.txt"), completion = "file" })
  if not path or path == "" then
    return
  end
  local ok, exp = pcall(require, "org.agenda.export")
  if ok and type(exp.write) == "function" then
    return exp.write(path)
  end
  -- lint: allow expand: a file the user typed
  path = vim.fn.expand(path)
  utils.writefile(path, vim.api.nvim_buf_get_lines(M.state.buf, 0, -1, false))
  utils.notify("Agenda written to " .. path)
end
