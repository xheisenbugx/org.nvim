---@mod org.clock.modeline Statusline and effort of the clocked task
---
--- The statusline component and changing the effort estimate.
---
--- Part of org.clock, which loads it.

local config = require("org.config")
local date = require("org.date")
local edit = require("org.edit")
local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.clock.shared")

local M = require("org.clock")

local check_effort = shared.check_effort
local clock_cfg = shared.clock_cfg
local persist = shared.persist

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
    shared.notified = false
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
