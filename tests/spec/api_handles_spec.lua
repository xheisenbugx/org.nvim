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
