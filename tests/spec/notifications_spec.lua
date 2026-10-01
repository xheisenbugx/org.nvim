local date = require("org.date")
local config = require("org.config")
local files = require("org.files")
local n = require("org.agenda.notifications")

local day = date.parse("<2026-09-25 Fri>")
local file = vim.fn.tempname() .. ".org"

local function ts(offset, time)
  return "<" .. day:add(offset, "d"):to_string({ brackets = false }) .. " " .. time .. ">"
end

local function at(offset, hour, min)
  return day:add(offset, "d"):clone({ hour = hour, min = min })
end

local function write(lines)
  vim.fn.writefile(lines, file)
  files.invalidate(file)
end

local sent
local function collect(ev)
  sent[#sent + 1] = ev
end

describe("notifications", function()
  with_config({
    agenda_files = { file },
    notifications = { reminder_time = { 10 }, system_notification = false, notifier = collect },
  })

  before_each(function()
    sent = {}
    n.reset()
  end)

  after_each(function()
    n.stop()
    os.remove(n.lock_path())
  end)

  it("doesn't repeat a reminder when lines are added above the entry", function()
    local lines = { "* Meeting", "  " .. ts(0, "10:00") }
    write(lines)
    eq(1, n.check(at(0, 9, 52)))
    table.insert(lines, 1, "* Captured just now")
    table.insert(lines, 2, "  :LOGBOOK:")
    table.insert(lines, 3, "  :END:")
    write(lines)
    eq(0, n.check(at(0, 9, 53)))
    eq(1, #sent)
  end)

  it("reminds once for a headline that is scheduled at its own timestamp", function()
    write({ "* TODO Call " .. ts(0, "10:00"), "  SCHEDULED: " .. ts(0, "10:00") })
    eq(1, n.check(at(0, 9, 55)))
    eq(1, #sent)
    ok(sent[1].body:find("^Scheduled at 10:00"))
  end)

  it("still reminds of two entries at the same time", function()
    write({ "* Standup", "  " .. ts(0, "10:00"), "* Review", "  " .. ts(0, "10:00") })
    eq(2, n.check(at(0, 9, 55)))
  end)

  it("doesn't repeat a reminder sent before midnight after midnight", function()
    write({ "* Night launch", "  " .. ts(1, "00:05") })
    eq(1, n.check(at(0, 23, 57)))
    eq(0, n.check(at(1, 0, 1)))
  end)

  describe("single_instance", function()
    local function lock(pid, keys)
      vim.fn.mkdir(vim.fn.fnamemodify(n.lock_path(), ":h"), "p")
      vim.fn.writefile({ vim.json.encode({ pid = pid, sent = keys or vim.empty_dict() }) }, n.lock_path())
    end
    -- a process that is alive: our parent
    local other = vim.uv.os_getppid()

    local function holder()
      return vim.json.decode(vim.fn.readfile(n.lock_path())[1]).pid
    end

    it("takes a free lock and releases it on stop", function()
      write({ "* Meeting", "  " .. ts(0, "10:00") })
      eq(1, n.tick(at(0, 9, 52)))
      eq(vim.fn.getpid(), holder())
      n.stop()
      eq(vim.NIL, holder())
    end)

    it("doesn't repeat a reminder when the holder quits and another takes over", function()
      write({ "* Meeting", "  " .. ts(0, "10:00") })
      eq(1, n.tick(at(0, 9, 52)))
      n.stop()
      -- another instance: nothing sent yet in its memory
      n.reset()
      eq(0, n.tick(at(0, 9, 53)))
      eq(1, #sent)
      eq(vim.fn.getpid(), holder())
    end)

    it("leaves reminders to the instance holding the lock", function()
      write({ "* Meeting", "  " .. ts(0, "10:00") })
      lock(other)
      eq(0, n.tick(at(0, 9, 52)))
      eq(0, #sent)
      -- stopping doesn't remove another instance's lock
      n.stop()
      eq(other, holder())
    end)

    it("takes over from a holder that exited, without repeating its reminders", function()
      write({ "* Meeting", "  " .. ts(0, "10:00") })
      -- a first instance sends the reminder and exits, its lock left behind
      -- with a pid that isn't running
      eq(1, n.tick(at(0, 9, 52)))
      local held = vim.json.decode(vim.fn.readfile(n.lock_path())[1])
      n.stop()
      lock(4194311, held.sent)
      -- a second instance
      n.reset()
      eq(0, n.tick(at(0, 9, 53)))
      eq(1, #sent)
      eq(vim.fn.getpid(), holder())
    end)

    it("takes over from a holder that stopped checking", function()
      write({ "* Meeting", "  " .. ts(0, "10:00") })
      lock(other)
      local old = os.time() - 3600
      vim.uv.fs_utime(n.lock_path(), old, old)
      eq(1, n.tick(at(0, 9, 52)))
    end)

    it("is off with single_instance = false", function()
      write({ "* Meeting", "  " .. ts(0, "10:00") })
      config.opts.notifications.single_instance = false
      lock(other)
      eq(1, n.tick(at(0, 9, 52)))
      config.opts.notifications.single_instance = nil
    end)
  end)
end)

describe("desktop notifications", function()
  local notifications = require("org.agenda.notifications")
  local real_has, real_executable, real_system
  local platform, available, calls

  before_each(function()
    real_has, real_executable, real_system = vim.fn.has, vim.fn.executable, vim.system
    platform, available, calls = {}, {}, {}
    vim.fn.has = function(feature)
      if feature == "mac" or feature == "win32" or feature == "wsl" then
        return platform[feature] and 1 or 0
      end
      return real_has(feature)
    end
    vim.fn.executable = function(exe)
      return available[exe] and 1 or 0
    end
    vim.system = function(cmd)
      calls[#calls + 1] = cmd
    end
  end)

  after_each(function()
    vim.fn.has, vim.fn.executable, vim.system = real_has, real_executable, real_system
  end)

  -- the script powershell -EncodedCommand runs (UTF-16LE base64)
  local function decode(b64)
    local bytes, chars, i = vim.base64.decode(b64), {}, 1
    local function unit()
      local u = bytes:byte(i) + bytes:byte(i + 1) * 256
      i = i + 2
      return u
    end
    while i <= #bytes do
      local u = unit()
      if u >= 0xD800 and u < 0xDC00 then
        u = 0x10000 + (u - 0xD800) * 0x400 + (unit() - 0xDC00)
      end
      chars[#chars + 1] = u
    end
    return vim.fn.list2str(chars, 1)
  end

  it("picks the notifier of the platform", function()
    platform.mac, available.osascript, available["notify-send"] = true, true, true
    eq("osascript", notifications.desktop_backend())
    platform.mac = false
    eq("notify-send", notifications.desktop_backend())
    available["notify-send"] = nil
    eq(nil, notifications.desktop_backend())
    platform.win32, available["powershell.exe"] = true, true
    eq("powershell", notifications.desktop_backend())
    -- notify-send on Windows (e.g. from MSYS2) isn't a desktop notifier
    available["notify-send"] = true
    eq("powershell", notifications.desktop_backend())
  end)

  it("uses powershell.exe in WSL only without notify-send", function()
    platform.wsl, available["powershell.exe"] = true, true
    eq("powershell", notifications.desktop_backend())
    available["notify-send"] = true
    eq("notify-send", notifications.desktop_backend())
  end)

  it("shows a Windows toast through powershell.exe", function()
    platform.win32, available["powershell.exe"] = true, true
    notifications.desktop_notify("org: Deadline", "TODO Mike's review — 10:00 🍅")
    eq(1, #calls)
    local cmd = calls[1]
    eq("powershell.exe", cmd[1])
    eq("-EncodedCommand", cmd[#cmd - 1])
    local script = decode(cmd[#cmd])
    eq(notifications.toast_script("org: Deadline", "TODO Mike's review — 10:00 🍅"), script)
    ok(script:find("CreateTextNode('org: Deadline')", 1, true), script)
    -- quotes are doubled in PowerShell's single-quoted strings, and the
    -- emoji (a surrogate pair in UTF-16) comes back whole
    ok(script:find("CreateTextNode('TODO Mike''s review — 10:00 🍅')", 1, true), script)
    ok(script:find("ToastNotificationManager", 1, true), script)
  end)

  it("doubles curly quotes, which PowerShell also ends strings with", function()
    local script = notifications.toast_script("t", "it\u{2019}s")
    ok(script:find("'it\u{2019}\u{2019}s'", 1, true), script)
  end)

  it("sends nothing without a notifier", function()
    notifications.desktop_notify("title", "body")
    eq(0, #calls)
  end)
end)
