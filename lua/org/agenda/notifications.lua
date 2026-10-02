---@mod org.agenda.notifications Appointment reminders (org-agenda-to-appt)
---
--- Every `notifications.check_interval` seconds, timed SCHEDULED, DEADLINE
--- and plain timestamps of today/tomorrow are checked; when an entry starts
--- within one of `reminder_time` minutes a notification is shown once.
---
--- An entry is known by its file, headline and start time, so editing the
--- file around it doesn't send its reminders again, and a headline whose
--- SCHEDULED time is also a plain timestamp is reminded once (Emacs's
--- appt-add skips an appointment with the same time and message).
---
--- With `single_instance`, only one Neovim sends reminders: the sender
--- holds `stdpath("data")/org/notifications.lock` (its pid and the
--- reminders sent), rewritten on every check. Another instance takes over
--- when the sender exits, or stops checking for three intervals, and
--- starts from the reminders already sent.

local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")

local M = {}

local timer = nil
local augroup = nil
--- Reminders sent: key -> start of the entry (minutes since epoch).
local sent = {}
--- Whether this instance holds the lock (single_instance).
local owner = false

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

-- Windows PowerShell 5.1 (powershell.exe, part of Windows) shows toasts
-- through WinRT, which PowerShell 7 can't load. The toasts are sent as
-- PowerShell itself: an app id Windows knows, so nothing needs registering.
local TOAST_APP = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe"

--- The PowerShell script showing a toast with `title` and `body`.
---@param title string
---@param body string
---@return string
function M.toast_script(title, body)
  return table.concat({
    "$ErrorActionPreference = 'Stop'",
    "$m = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]",
    "$x = $m::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)",
    "$t = $x.GetElementsByTagName('text')",
    "[void]$t.Item(0).AppendChild($x.CreateTextNode(" .. utils.ps_quote(title) .. "))",
    "[void]$t.Item(1).AppendChild($x.CreateTextNode(" .. utils.ps_quote(body) .. "))",
    "$m::CreateToastNotifier("
      .. utils.ps_quote(TOAST_APP)
      .. ").Show([Windows.UI.Notifications.ToastNotification]::new($x))",
  }, "\n")
end

--- Which desktop notifier `desktop_notify` uses: "osascript" (macOS),
--- "notify-send" (Linux, BSD), "powershell" (Windows, and WSL without
--- notify-send) or nil when none is available.
---@return "osascript"|"notify-send"|"powershell"|nil
function M.desktop_backend()
  local fn = vim.fn
  if fn.has("mac") == 1 and fn.executable("osascript") == 1 then
    return "osascript"
  elseif fn.has("win32") == 0 and fn.executable("notify-send") == 1 then
    return "notify-send"
  elseif (fn.has("win32") == 1 or fn.has("wsl") == 1) and fn.executable("powershell.exe") == 1 then
    return "powershell"
  end
  return nil
end

--- Send a desktop notification: osascript on macOS, notify-send on Linux,
--- a toast through powershell.exe on Windows (nothing when none is there).
--- Also used by extensions (pomodoro).
---@param title string
---@param body string
function M.desktop_notify(title, body)
  local backend = M.desktop_backend()
  if backend == "osascript" then
    local esc = function(s)
      return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
    end
    pcall(vim.system, {
      "osascript",
      "-e",
      string.format('display notification "%s" with title "%s"', esc(body), esc(title)),
    })
  elseif backend == "notify-send" then
    pcall(vim.system, { "notify-send", "--app-name=org.nvim", title, body })
  elseif backend == "powershell" then
    pcall(vim.system, utils.powershell(M.toast_script(title, body)))
  end
end

local function system_notify(title, body)
  local n = config.opts.notifications or {}
  if n.system_notification == false then
    return
  end
  M.desktop_notify(title, body)
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

-- SCHEDULED and DEADLINE before plain timestamps, so an entry that is both
-- is reminded as the former
local KIND_RANK = { deadline = 1, scheduled = 2 }

--- The identity of an entry's reminders: its file, headline (the line
--- itself outside a headline) and start, but not its line number or kind.
local function entry_key(e)
  local it = e.item
  local text = (it.title and it.title ~= "") and it.title or (it.raw or "")
  return table.concat({ it.filename or "", text, tostring(e.start) }, "\t")
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
  local now_min = now:minutes()
  -- forget entries that have started (rather than resetting at midnight,
  -- which would repeat a reminder sent late yesterday for an entry just
  -- after midnight)
  for k, start in pairs(sent) do
    if start < now_min then
      sent[k] = nil
    end
  end
  local entries = M.upcoming(now)
  for i, e in ipairs(entries) do
    e.order = i
  end
  table.sort(entries, function(a, b)
    local ra, rb = KIND_RANK[a.kind] or 3, KIND_RANK[b.kind] or 3
    if ra ~= rb then
      return ra < rb
    end
    return a.order < b.order
  end)
  local count = 0
  for _, e in ipairs(entries) do
    local left = e.start - now_min
    if left >= 0 then
      local key = entry_key(e)
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
            sent[key .. ":" .. r] = e.start
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

--- The lock file of `single_instance`.
function M.lock_path()
  return vim.fn.stdpath("data") .. "/org/notifications.lock"
end

local function interval_seconds()
  return (config.opts.notifications or {}).check_interval or 60
end

local function read_lock()
  local data = utils.read_json(M.lock_path())
  return type(data) == "table" and data or nil
end

-- Write the lock through a temporary file and a rename, so another
-- instance never reads it half written. `pid` false marks it free while
-- keeping the reminders sent for the next holder.
local function write_lock(pid)
  local path = M.lock_path()
  -- instances starting together may race to create the directory
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
  local tmp = path .. "." .. vim.fn.getpid()
  local fd = io.open(tmp, "wb")
  if not fd then
    return
  end
  fd:write(vim.json.encode({
    pid = pid ~= false and vim.fn.getpid() or vim.NIL,
    sent = next(sent) and sent or vim.empty_dict(),
  }))
  fd:close()
  vim.uv.fs_rename(tmp, path)
end

local function pid_alive(pid)
  if type(pid) ~= "number" then
    return false
  end
  -- signal 0 only checks that the process exists
  local ok, res = pcall(vim.uv.kill, pid, 0)
  return ok and res == 0
end

-- Whether another instance holds the lock: its process runs and it
-- checked within three intervals.
local function held_by_other(lock, pid, now_s)
  if not lock or lock.pid == pid or not pid_alive(lock.pid) then
    return false
  end
  local stat = vim.uv.fs_stat(M.lock_path())
  local age = stat and (now_s - stat.mtime.sec) or math.huge
  return age <= 3 * interval_seconds() + 5
end

--- Whether this instance may send reminders now, taking the lock when it
--- is free, its holder is gone, or its holder stopped checking. Returns
--- true for the holder, whose lock `tick()` then rewrites.
function M.acquire(now_s)
  now_s = now_s or os.time()
  local pid = vim.fn.getpid()
  local lock = read_lock()
  if owner and lock and lock.pid == pid then
    return true
  end
  owner = false
  if held_by_other(lock, pid, now_s) then
    return false
  end
  -- Of several instances taking over at once only the one that creates
  -- the claim file (O_EXCL) may; it looks at the lock again under it.
  local claim = M.lock_path() .. ".claim"
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(claim, ":h"), "p")
  local fd = vim.uv.fs_open(claim, "wx", tonumber("644", 8))
  if not fd then
    -- a claim left by an instance that died while taking over
    local stat = vim.uv.fs_stat(claim)
    if stat and now_s - stat.mtime.sec > 10 then
      os.remove(claim)
    end
    return false
  end
  vim.uv.fs_close(fd)
  lock = read_lock()
  if not held_by_other(lock, pid, now_s) then
    -- start from what the previous holder sent
    local prev = type(lock) == "table" and type(lock.sent) == "table" and lock.sent or {}
    for k, start in pairs(prev) do
      if type(start) == "number" then
        sent[k] = sent[k] or start
      end
    end
    write_lock()
    owner = true
  end
  os.remove(claim)
  return owner
end

--- Give the lock up (on stop and exit) when this instance holds it,
--- leaving the reminders sent for the instance that takes over.
function M.release()
  if not owner then
    return
  end
  owner = false
  local lock = read_lock()
  if lock and lock.pid == vim.fn.getpid() then
    write_lock(false)
  end
end

--- One tick of the timer: a check, in the lock holder only with
--- `single_instance`.
function M.tick(now)
  local single = (config.opts.notifications or {}).single_instance ~= false
  if single and not M.acquire() then
    return 0
  end
  local count = M.check(now)
  if single then
    -- also the holder's heartbeat
    write_lock()
  end
  return count
end

function M.start()
  M.stop()
  local interval = interval_seconds() * 1000
  timer = vim.uv.new_timer()
  timer:start(
    1000,
    interval,
    vim.schedule_wrap(function()
      local ok, err = pcall(M.tick)
      if not ok then
        utils.error("org notifications: " .. tostring(err))
      end
    end)
  )
  augroup = vim.api.nvim_create_augroup("org.notifications", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = augroup, callback = M.release })
end

function M.stop()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  M.release()
end

function M.running()
  return timer ~= nil
end

return M
