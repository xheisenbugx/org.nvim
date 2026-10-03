-- Headline handles of org.api: finding the right entry again, saving every
-- file a change touches, and the values the change methods accept.
local api = require("org.api")
local config = require("org.config")
local utils = require("org.utils")
vim.g.org_test = true

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return vim.fs.normalize(vim.fn.resolve(dir))
end

local function setup(dir, extra)
  config.setup(vim.tbl_deep_extend("force", {
    org_directory = dir,
    agenda_files = { dir },
    todo_keywords = { "TODO", "NEXT", "|", "DONE" },
    default_notes_file = dir .. "/inbox.org",
    id = { locations_file = dir .. "/ids.json" },
  }, extra or {}))
  require("org.id")._reset()
end

local function write(dir, name, lines)
  local p = dir .. "/" .. name
  utils.writefile(p, lines)
  return p
end

local function disk(path)
  return utils.readfile(path) or {}
end

local WORK = {
  "* Projects",
  "** TODO Plan offsite :travel:",
  "   SCHEDULED: <2026-10-05 Mon>",
  "** TODO Write report",
}

describe("org.api handles", function()
  local dir, work

  before_each(function()
    dir = tmpdir()
    setup(dir)
    work = write(dir, "work.org", WORK)
  end)

  after_each(function()
    require("org.clock").state = nil
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" and vim.startswith(vim.fs.normalize(name), dir) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
  end)

  local function head(title, path)
    return api.headlines({ files = path or work, title = title })[1]
  end

  describe("dates", function()
    it("normalises out-of-range fields like os.time", function()
      local h = head("Write report")
      ok(h:schedule({ year = 2026, month = 10, day = 32, hour = 12, min = 0 }))
      eq("<2026-11-01 Sun 12:00>", h.scheduled.raw)
      eq("SCHEDULED: <2026-11-01 Sun 12:00>", vim.trim(disk(work)[5]))
      -- the usual way to compute a date in Lua
      local t = os.date("*t", os.time({ year = 2026, month = 10, day = 2, hour = 12 }))
      t.day = t.day + 30
      ok(h:schedule(t))
      eq("<2026-11-01 Sun 12:00>", h.scheduled.raw)
      eq("<2027-01-01 Fri>", api.date({ year = 2026, month = 13, day = 1 }).text)
      eq("<2026-09-30 Wed>", api.date({ year = 2026, month = 10, day = 0 }).text)
      eq("<2024-02-29 Thu>", api.date({ year = 2024, month = 3, day = 0 }).text)
      eq("<2026-10-03 Sat 01:30>", api.date({ year = 2026, month = 10, day = 2, hour = 24, min = 90 }).text)
      eq("<2026-10-01 Thu 23:00>", api.date({ year = 2026, month = 10, day = 2, hour = 0, min = -60 }).text)
      eq(
        "<2026-10-02 Fri 09:00-10:30>",
        api.date({ year = 2026, month = 10, day = 2, hour = 9, end_hour = 10, end_min = 30 }).text
      )
      eq("<2026-10-02 Fri>", api.date({ year = "2026", month = "10", day = "2" }).text)
      eq("<2026-03-02 Mon 10:00>", api.date("<2026-02-30 Mon 10:00>").text)
      eq("<2026-05-01 Fri>", api.date("2026-04-31").text)
      eq(
        "<2026-10-02 Fri +1w -2d>",
        api.date({
          year = 2026,
          month = 10,
          day = 2,
          repeater = { type = "+", value = 1, unit = "w" },
          warning = { type = "-", value = 2, unit = "d" },
        }).text
      )
      eq(
        "<2026-10-02 Fri .+1d/3d>",
        api.date({
          year = 2026,
          month = 10,
          day = 2,
          repeater = { type = ".+", value = 1, unit = "d", max = { value = 3, unit = "d" } },
        }).text
      )
      -- a date the API gave back is taken as it is
      eq("<2026-11-01 Sun 12:00>", api.date(h.scheduled).text)
    end)

    it("rejects impossible dates", function()
      local h = head("Write report")
      for _, bad in ipairs({
        { year = 2026, month = 10, day = 1.5 },
        { year = 2026, month = "x", day = 1 },
        { year = 2026, month = 10, day = 2, hour = 0 / 0 },
        { year = 2026, month = 10, day = 2, hour = math.huge },
        { year = 2026, month = 10, day = 2, hour = 9, end_hour = 30 },
        { year = 2026, month = 10, day = 2, hour = 9, end_hour = 10, end_min = 75 },
        { year = 12026, month = 1, day = 1 },
        { year = 2026, month = 10, day = 2, repeater = { type = "+", value = 1, unit = "x" } },
        { year = 2026, month = 10, day = 2, repeater = { type = "*", value = 1, unit = "d" } },
        { year = 2026, month = 10, day = 2, repeater = { type = "+", value = 1, unit = "d", max = { value = "x" } } },
        { year = 2026, month = 10, day = 2, warning = "-3d" },
      }) do
        local res, err = h:schedule(bad)
        eq(nil, res, vim.inspect(bad))
        ok(err and err:match("invalid date"), vim.inspect(bad) .. ": " .. tostring(err))
      end
      eq(WORK, disk(work))
      for _, bad in ipairs({ 0 / 0, math.huge, 1e15 }) do
        local res, err = h:schedule(bad)
        eq(nil, res)
        ok(err and err:match("invalid date"), tostring(err))
      end
      local _, err = api.date({ year = 2026, month = 10 })
      ok(err:match("year, month and day"), err)
    end)

    it("gives a planning range's raw text whole", function()
      local p = write(dir, "range.org", {
        "* Trip",
        "  SCHEDULED: <2026-10-02 Fri>--<2026-10-04 Sun> DEADLINE: <2026-10-05 Mon 10:00>--<2026-10-05 Mon 12:00>",
        "* Meeting",
        "  CLOSED: [2026-10-01 Thu 09:00]--[2026-10-01 Thu 10:00] SCHEDULED: <2026-10-06 Tue 10:00-11:00>",
      })
      local f = api.load(p)
      local s = f.headlines[1].scheduled
      eq("<2026-10-02 Fri>--<2026-10-04 Sun>", s.raw)
      eq(s.raw, s.text)
      eq("2026-10-02", s.date)
      eq("<2026-10-05 Mon 10:00>--<2026-10-05 Mon 12:00>", f.headlines[1].deadline.raw)
      eq("<2026-10-06 Tue 10:00-11:00>", f.headlines[2].scheduled.raw)
      eq("[2026-10-01 Thu 09:00]--[2026-10-01 Thu 10:00]", f.headlines[2].closed.raw)
    end)
  end)

  describe("priorities", function()
    it("set_priority(nil) fails like set_priority('A') when priorities are off", function()
      setup(dir, { priority_enable_commands = false })
      local p = write(dir, "prio.org", { "* [#B] Task" })
      local h = head("Task", p)
      local res, err = h:set_priority("A")
      eq(nil, res)
      ok(err:match("disabled"), err)
      res, err = h:set_priority(nil)
      eq(nil, res)
      ok(err and err:match("disabled"), tostring(err))
      eq({ "* [#B] Task" }, disk(p))
    end)
  end)
end)
