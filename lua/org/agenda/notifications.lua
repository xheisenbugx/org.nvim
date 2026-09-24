---@mod org.agenda.notifications Appointment reminders (org-agenda-to-appt)
---
--- Every `notifications.check_interval` seconds, timed SCHEDULED, DEADLINE
--- and plain timestamps of today/tomorrow are checked; when an entry starts
--- within one of `reminder_time` minutes a notification is shown once.

local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")

local M = {}

local timer = nil
local sent = {}
local sent_day = nil

--- Upcoming timed entries: list of { item, start (minutes since epoch), kind }.
function M.upcoming(now)
  now = now or date.now()
  local today = now:days()
  local items = require("org.agenda.items")
  local by_day = items.agenda(require("org.files").agenda_files(), today, today + 1, { today = today })
  local out = {}
  for d = today, today + 1 do
    for _, it in ipairs(by_day[d] or {}) do
      if it.time and not it.reminder and not it.done and not it.log then
        out[#out + 1] = {
          item = it,
          start = d * 1440 + it.time,
          kind = it.type,
        }
      end
    end
  end
  return out
end

local function system_notify(title, body)
  local n = config.opts.notifications or {}
  if n.system_notification == false then
    return
  end
  if vim.fn.has("mac") == 1 and vim.fn.executable("osascript") == 1 then
    local esc = function(s)
      return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
    end
    vim.system({
      "osascript",
      "-e",
      string.format('display notification "%s" with title "%s"', esc(body), esc(title)),
    })
  elseif vim.fn.executable("notify-send") == 1 then
    vim.system({ "notify-send", "--app-name=org.nvim", title, body })
  end
end

local function notify(entry, minutes_left)
  local it = entry.item
  local kind = ({ scheduled = "Scheduled", deadline = "Deadline" })[entry.kind] or "Appointment"
  local t = string.format("%02d:%02d", math.floor(it.time / 60), it.time % 60)
  local when = minutes_left <= 0 and "now" or string.format("in %d min", minutes_left)
  local title = (it.todo and (it.todo .. " ") or "") .. require("org.agenda.render").display_title(it.title)
  local body = string.format("%s at %s (%s) — %s", kind, t, when, it.category)
  local custom = (config.opts.notifications or {}).notifier
  if type(custom) == "function" then
    pcall(custom, { title = title, body = body, item = it, minutes = minutes_left })
    return
  end
  utils.notify(title .. "\n" .. body, vim.log.levels.WARN, { title = "org reminder" })
  system_notify("org: " .. kind, title .. " — " .. t)
end

--- Run one check (also usable for testing with a fixed `now`).
---@return integer number of notifications sent
function M.check(now)
  now = now or date.now()
  local ncfg = config.opts.notifications or {}
  local reminders = ncfg.reminder_time or { 10, 0 }
  if type(reminders) == "number" then
    reminders = { reminders }
  end
  reminders = vim.deepcopy(reminders)
  table.sort(reminders)
  if sent_day ~= now:days() then
    sent = {}
    sent_day = now:days()
  end
  local now_min = now:minutes()
  local count = 0
  for _, e in ipairs(M.upcoming(now)) do
    local left = e.start - now_min
    if left >= 0 then
      local key = (e.item.filename or "") .. ":" .. e.item.lnum .. ":" .. e.kind .. ":" .. e.start
      -- smallest reminder offset that has been reached and not yet sent
      local fire
      for _, r in ipairs(reminders) do
        if left <= r and not sent[key .. ":" .. r] then
          fire = fire or r
        end
      end
      if fire then
        for _, r in ipairs(reminders) do
          if r >= left then
            sent[key .. ":" .. r] = true
          end
        end
        notify(e, left)
        count = count + 1
      end
    end
  end
  return count
end

function M.reset()
  sent = {}
end

function M.start()
  M.stop()
  local interval = ((config.opts.notifications or {}).check_interval or 60) * 1000
  timer = vim.uv.new_timer()
  timer:start(1000, interval, vim.schedule_wrap(function()
    local ok, err = pcall(M.check)
    if not ok then
      utils.error("org notifications: " .. tostring(err))
    end
  end))
end

function M.stop()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

function M.running()
  return timer ~= nil
end

return M
