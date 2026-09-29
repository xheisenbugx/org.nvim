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
