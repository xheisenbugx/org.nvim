local api = require("org.api")
local config = require("org.config")
local date = require("org.date")
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
  return utils.readfile(path)
end

--- Collect the data of every `event` until the test ends.
local listeners = {}
local function listen(event)
  local got = {}
  listeners[#listeners + 1] = api.on(event, function(data)
    got[#got + 1] = data
  end)
  return got
end

local function open_file(path)
  vim.cmd("enew!")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

--- A headline line with its tags aligned or not.
local function squash(line)
  return (line:gsub("%s+(:[%w_@#%%:]+:)$", " %1"))
end

local function same_file(a, b)
  return a and b and vim.fn.resolve(a) == vim.fn.resolve(b)
end

--- The open `CLOCK: [...]` line of `lines`, or nil.
local function open_clock(lines)
  for _, l in ipairs(lines) do
    if l:match("^%s*CLOCK: %[[^%]]*%]%s*$") then
      return l
    end
  end
end

local WORK = {
  "#+TITLE: Work notes",
  "#+FILETAGS: :work:",
  "#+CATEGORY: job",
  "* TODO [#B] Write report :urgent:",
  "  SCHEDULED: <2026-10-05 Mon +1w> DEADLINE: <2026-10-09 Fri>",
  "  :PROPERTIES:",
  "  :ID:       report-id",
  "  :EFFORT:   1:00",
  "  :END:",
  "** NEXT Draft outline",
  "** DONE Collect data",
  "   CLOSED: [2026-10-01 Thu 10:00]",
  "* Projects",
  "  :PROPERTIES:",
  "  :CUSTOM_ID: projects",
  "  :END:",
  "** TODO Plan offsite :travel:",
  "* Archived :ARCHIVE:",
  "** TODO Hidden task",
}

describe("org.api", function()
  local dir, work
  -- The specs run on Friday 2026-10-02 at 12:00, whatever the date: in the
  -- week of WORK's dates the agenda adds today's entries (overdue and
  -- upcoming ones) on today, and a clock running across a minute boundary
  -- counts a minute.
  local TODAY = date.days_from_civil(2026, 10, 2)
  local saved_date

  before_each(function()
    saved_date = { today = date.today, today_days = date.today_days, now = date.now }
    date.today_days = function()
      return TODAY
    end
    date.today = function()
      return date.from_days(TODAY)
    end
    date.now = function()
      return date.from_days(TODAY, { hour = 12, min = 0 })
    end
    dir = tmpdir()
    setup(dir)
    work = write(dir, "work.org", WORK)
  end)

  after_each(function()
    for _, id in ipairs(listeners) do
      api.off(id)
    end
    listeners = {}
    local clock = require("org.clock")
    clock.state = nil
    date.today, date.today_days, date.now = saved_date.today, saved_date.today_days, saved_date.now
  end)

  describe("version", function()
    it("is semver and checks compatibility with has()", function()
      ok(api.version:match("^%d+%.%d+%.%d+$"))
      local major = api.version:match("^(%d+)")
      ok(api.has(major))
      ok(api.has(api.version))
      ok(not api.has(tostring(tonumber(major) + 1)))
      ok(not api.has(major .. ".999"))
      ok(not api.has("nonsense"))
    end)

    it("date() converts the accepted date forms", function()
      eq("2026-10-02", api.date("2026-10-02").date)
      eq("<2026-10-02 Fri 09:15>", api.date({ year = 2026, month = 10, day = 2, hour = 9, min = 15 }).text)
      eq("[2026-10-02 Fri]", api.date("[2026-10-02 Fri]").raw)
      eq(false, api.date("[2026-10-02 Fri]").active)
      local t = os.time({ year = 2026, month = 10, day = 2, hour = 12, min = 0 })
      eq("12:00", api.date(t).time)
      local _, err = api.date({ year = 2026 })
      ok(err:match("year, month and day"))
    end)

    it("exposes release, lhs_list, priority_value and format_time (API 1.6)", function()
      ok(api.has("1.6"))
      eq(require("org.version").release, api.release)
      eq({}, api.lhs_list(false))
      eq({}, api.lhs_list(nil))
      local prefix = api.option("mappings.prefix") or "<leader>o"
      eq({ prefix .. "a" }, api.lhs_list("<prefix>a"))
      eq({ "q", "<Esc>" }, api.lhs_list({ "q", "<Esc>" }))
      eq(65, api.priority_value("A"))
      eq(66, api.priority_value("B"))
      eq(nil, api.priority_value(nil))
      local t = os.time({ year = 2026, month = 10, day = 2, hour = 12, min = 30, sec = 0 })
      eq("2026-10-02 12:30", api.format_time("%Y-%m-%d %H:%M", t))
    end)
  end)

  describe("files", function()
    it("lists the agenda files", function()
      local other = write(dir, "other.org", { "* x" })
      local paths = api.agenda_files()
      eq(2, #paths)
      ok(vim.tbl_contains(vim.tbl_map(vim.fn.resolve, paths), vim.fn.resolve(other)))
    end)

    it("loads a file as plain data", function()
      local f = api.load(work)
      ok(same_file(work, f.file))
      eq("Work notes", f.title)
      eq("job", f.category)
      eq({ "work" }, f.filetags)
      eq({ "TODO", "NEXT" }, vim.list_slice(f.todo_keywords.todo, 1, 2))
      ok(vim.tbl_contains(f.todo_keywords.done, "DONE"))
      eq(7, #f.headlines)
      eq("Write report", f.headlines[1].title)
    end)

    it("returns nil and an error for a missing file", function()
      local f, err = api.load(dir .. "/missing.org")
      eq(nil, f)
      ok(err:match("cannot read"))
    end)

    it("loads every agenda file, or a list of paths", function()
      write(dir, "other.org", { "* x" })
      eq(2, #api.load())
      local list = api.load({ work })
      eq(1, #list)
      eq("Work notes", list[1].title)
    end)

    it("reads a loaded buffer, unsaved changes included", function()
      open_file(work)
      vim.api.nvim_buf_set_lines(0, 3, 4, false, { "* TODO Changed title" })
      eq("Changed title", api.load(work).headlines[1].title)
      local cur = api.current()
      eq("Changed title", cur.headlines[1].title)
      eq(vim.api.nvim_get_current_buf(), cur.bufnr)
      vim.cmd("bwipeout!")
    end)

    it("current() is nil outside org buffers", function()
      vim.cmd("enew!")
      vim.bo.filetype = "text"
      eq(nil, api.current())
    end)
  end)

  describe("headline fields", function()
    it("describes a headline with plain data", function()
      local h = api.load(work).headlines[1]
      eq("Write report", h.title)
      eq("* TODO [#B] Write report :urgent:", h.raw)
      eq(1, h.level)
      eq("TODO", h.todo)
      eq("todo", h.todo_type)
      eq(false, h.done)
      eq("B", h.priority)
      eq({ "urgent" }, h.tags)
      eq({ "work", "urgent" }, h.all_tags)
      eq("report-id", h.id)
      eq("1:00", h.properties.EFFORT)
      eq("job", h.category)
      eq(4, h.line)
      eq(12, h.end_line)
      eq({}, h.outline_path)
      eq(false, h.archived)
      eq(false, h.commented)
    end)

    it("gives dates as structures with the raw text", function()
      local f = api.load(work)
      local s = f.headlines[1].scheduled
      eq({ 2026, 10, 5 }, { s.year, s.month, s.day })
      eq("2026-10-05", s.date)
      eq(true, s.active)
      eq({ type = "+", value = 1, unit = "w" }, s.repeater)
      eq("<2026-10-05 Mon +1w>", s.raw)
      eq("<2026-10-05 Mon +1w>", s.text)
      eq(os.time({ year = 2026, month = 10, day = 5, hour = 0 }), s.timestamp)
      eq("2026-10-09", f.headlines[1].deadline.date)
      local c = f.headlines[3].closed
      eq("10:00", c.time)
      eq(false, c.active)
      eq("[2026-10-01 Thu 10:00]", c.raw)
      eq(nil, f.headlines[2].scheduled)
    end)

    it("reports done state, ancestors and archived subtrees", function()
      local f = api.load(work)
      eq("done", f.headlines[3].todo_type)
      eq(true, f.headlines[3].done)
      eq({ "Write report" }, f.headlines[2].outline_path)
      eq(true, f.headlines[6].archived)
      eq(nil, f.headlines[4].todo)
      eq(nil, f.headlines[4].todo_type)
    end)

    it("parent(), children(), get_property() and reload()", function()
      local h = api.load(work).headlines[2]
      eq("Write report", h:parent().title)
      eq(nil, h:parent():parent())
      eq(
        { "Draft outline", "Collect data" },
        vim.tbl_map(function(c)
          return c.title
        end, h:parent():children())
      )
      eq("NEXT", h:get_property("TODO"))
      eq(":work:urgent:", h:get_property("ALLTAGS"))
      -- the file changes behind the handle's back
      local lines = disk(work)
      lines[10] = "** WAITING Draft outline"
      table.insert(lines, 1, "#+TODO: TODO NEXT WAITING | DONE")
      utils.writefile(work, lines)
      require("org.files").invalidate()
      local ok_ = h:reload()
      eq(nil, ok_)
      -- an ID finds the headline wherever it moved
      local top = api.load(work).headlines[1]
      table.insert(lines, 1, "")
      utils.writefile(work, lines)
      ok(top:reload())
      eq(6, top.line)
    end)
  end)

  describe("finding headlines", function()
    local function titles(list)
      return vim.tbl_map(function(h)
        return h.title
      end, list)
    end

    it("headline_at in a buffer or a file", function()
      open_file(work)
      vim.api.nvim_win_set_cursor(0, { 11, 0 })
      eq("Collect data", api.headline_at().title)
      eq("Write report", api.headline_at({ lnum = 5 }).title)
      eq(nil, api.headline_at({ lnum = 1 }))
      eq("Plan offsite", api.headline_at({ file = work, lnum = 17 }).title)
      vim.cmd("bwipeout!")
    end)

    it("headline_at and links.insert take the cursor of the current window", function()
      local p = write(dir, "two.org", { "* First", "* Second" })
      open_file(p)
      local b = vim.api.nvim_get_current_buf()
      vim.cmd("split")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      -- the lower window, current, on the second headline
      vim.cmd("wincmd j")
      vim.api.nvim_win_set_cursor(0, { 2, 2 })
      eq("Second", api.headline_at().title)
      eq("Second", api.headline_at({ bufnr = b }).title)
      eq("[[https://x.org][X]]", api.links.insert("https://x.org", "X"))
      eq({ "* First", "* [[https://x.org][X]]Second" }, buf_lines(b))
      vim.cmd("only")
      vim.cmd("bwipeout!")
    end)

    it("a buffer takes the cursor of a window showing it; a hidden one has none", function()
      local p = write(dir, "two.org", { "* First", "* Second" })
      open_file(p)
      local b = vim.api.nvim_get_current_buf()
      vim.api.nvim_win_set_cursor(0, { 2, 2 })
      vim.cmd("split")
      vim.cmd("enew")
      eq("Second", api.headline_at({ bufnr = b }).title)
      local l = api.links.store_location({ bufnr = b })
      ok(l.link:match("Second"), l.link)
      api.links.insert("id:abc", nil, { bufnr = b })
      eq({ "* First", "* [[id:abc]]Second" }, buf_lines(b))
      -- no window shows it: no cursor to take
      vim.cmd("only")
      eq(-1, vim.fn.bufwinid(b))
      local h, err = api.headline_at({ bufnr = b })
      eq(nil, h)
      ok(err:match("not shown in a window"), err)
      local text, err2 = api.links.insert("id:x", nil, { bufnr = b })
      eq(nil, text)
      ok(err2:match("not shown in a window"), err2)
      local sl, err3 = api.links.store_location({ bufnr = b })
      eq(nil, sl)
      ok(err3:match("not shown in a window"), err3)
      eq({ "* First", "* [[id:abc]]Second" }, buf_lines(b))
      -- a line and a column need no cursor
      eq("First", api.headline_at({ bufnr = b, lnum = 1 }).title)
      api.links.insert("id:y", nil, { bufnr = b, row = 1, col = 7 })
      eq("* First[[id:y]]", buf_lines(b)[1])
    end)

    it("find_by_id", function()
      eq("Write report", api.find_by_id("report-id").title)
      eq(nil, api.find_by_id("nope"))
    end)

    it("filters by TODO state", function()
      eq({ "Write report", "Draft outline", "Plan offsite", "Hidden task" }, titles(api.headlines({ todo = true })))
      eq({ "Draft outline" }, titles(api.headlines({ todo = "NEXT" })))
      eq({ "Draft outline", "Collect data" }, titles(api.headlines({ todo = { "NEXT", "DONE" } })))
      eq({ "Projects", "Archived" }, titles(api.headlines({ todo = false })))
      eq({ "Collect data" }, titles(api.headlines({ done = true })))
    end)

    it("filters by tags with inheritance", function()
      eq({ "Write report", "Draft outline", "Collect data" }, titles(api.headlines({ tags = "urgent" })))
      eq({ "Plan offsite" }, titles(api.headlines({ tags = { "work", "travel" } })))
    end)

    it("filters by properties, level, title, id and archived", function()
      eq({ "Write report" }, titles(api.headlines({ property = { EFFORT = "1:00" } })))
      eq({ "Projects" }, titles(api.headlines({ property = { CUSTOM_ID = true } })))
      eq(6, #api.headlines({ property = {
        CUSTOM_ID = false,
      } }))
      eq(
        { "Write report" },
        titles(api.headlines({
          property = {
            EFFORT = function(v)
              return v ~= nil
            end,
          },
        }))
      )
      eq({ "Write report", "Projects", "Archived" }, titles(api.headlines({ level = 1 })))
      eq(4, #api.headlines({ level = { min = 2 } }))
      eq({ "Plan offsite" }, titles(api.headlines({ title = "OFFSITE" })))
      eq({ "Write report" }, titles(api.headlines({ id = "report-id" })))
      eq(
        { "Write report", "Draft outline", "Collect data", "Projects", "Plan offsite" },
        titles(api.headlines({ archived = false }))
      )
    end)

    it("matches titles ignoring case beyond ASCII", function()
      local p = write(dir, "accents.org", { "* ÉTÉ à Paris", "* Hiver", "* Ωmega" })
      eq({ "ÉTÉ à Paris" }, titles(api.headlines({ files = p, title = "été" })))
      eq({ "ÉTÉ à Paris" }, titles(api.headlines({ files = p, title = "À PARIS" })))
      eq({ "Ωmega" }, titles(api.headlines({ files = p, title = "ωMEGA" })))
      eq({ "Hiver" }, titles(api.headlines({ files = p, title = "hIVER" })))
    end)

    it("accepts a tags/property match string and a filter function", function()
      eq({ "Plan offsite" }, titles(api.headlines({ match = "+travel" })))
      eq({ "Projects" }, titles(api.headlines({ match = 'CUSTOM_ID="projects"' })))
      eq({ "Draft outline" }, titles(api.headlines({ match = "+urgent/NEXT" })))
      eq(
        { "Collect data" },
        titles(api.headlines({
          filter = function(h)
            return h.closed ~= nil
          end,
        }))
      )
      local res, err = api.headlines({ match = "{a\\(}" })
      eq(nil, res)
      ok(err)
    end)

    it("searches given files", function()
      local other = write(dir, "elsewhere.org", { "* TODO Elsewhere" })
      setup(dir, { agenda_files = { work } })
      eq({}, titles(api.headlines({ title = "Elsewhere" })))
      eq({ "Elsewhere" }, titles(api.headlines({ files = other })))
    end)
  end)

  describe("changing headlines", function()
    local function head(title)
      return api.headlines({ files = work, title = title })[1]
    end

    it("set_todo changes a file that is not loaded and saves it", function()
      local events = listen("OrgTodoStateChange")
      local h = head("Draft outline")
      eq(nil, utils.find_buffer(work))
      eq(h, h:set_todo("DONE"))
      eq("DONE", h.todo)
      eq(true, h.done)
      eq("** DONE Draft outline", disk(work)[10])
      local b = utils.find_buffer(work)
      eq(false, vim.bo[b].modified)
      eq(1, #events)
      eq({ "NEXT", "DONE" }, { events[1].from, events[1].to })
    end)

    it("set_todo logs without prompting and takes a note", function()
      config.opts.todo_keywords = { "TODO(t@)", "NEXT", "|", "DONE(d@)" }
      local h = head("Plan offsite")
      ok(h:set_todo("DONE"))
      ok(table.concat(disk(work), "\n"):find('%- State "DONE"%s+from "TODO"%s+%[[^%]]+%]\n'))
      local h2 = head("Hidden task")
      ok(h2:set_todo("DONE", { note = "Done at last" }))
      local text = table.concat(disk(work), "\n")
      ok(text:find("Done at last", 1, true))
    end)

    it("a repeating task moves on", function()
      local changes, repeats = listen("OrgTodoStateChange"), listen("OrgTodoRepeat")
      local h = head("Write report")
      ok(h:set_todo("DONE"))
      eq("TODO", h.todo)
      eq("2026-10-12", h.scheduled.date)
      eq(1, #changes)
      eq(1, #repeats)
      eq(true, repeats[1].repeated)
    end)

    it("set_todo removes the keyword with nil and rejects unknown ones", function()
      local h = head("Plan offsite")
      ok(h:set_todo(nil))
      eq(nil, h.todo)
      eq("** Plan offsite :travel:", squash(disk(work)[17]))
      local res, err = h:set_todo("BOGUS")
      eq(nil, res)
      ok(err:match("Unknown TODO keyword"))
    end)

    it("leaves a buffer with unsaved changes unsaved unless asked", function()
      open_file(work)
      local b = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(b, -1, -1, false, { "* Unsaved" })
      local h = head("Plan offsite")
      ok(h:set_todo("DONE"))
      eq(true, vim.bo[b].modified)
      eq("** TODO Plan offsite :travel:", disk(work)[17])
      ok(h:set_todo("TODO", { save = true }))
      eq(false, vim.bo[b].modified)
      eq("* Unsaved", disk(work)[#disk(work)])
      vim.cmd("bwipeout!")
    end)

    it("save = false never writes", function()
      local h = head("Plan offsite")
      ok(h:set_priority("A", { save = false }))
      eq("** TODO Plan offsite :travel:", disk(work)[17])
      eq(true, vim.bo[utils.find_buffer(work)].modified)
    end)

    it("set_tags, add_tag and remove_tag fire OrgTagsChanged", function()
      local events = listen("OrgTagsChanged")
      local h = head("Plan offsite")
      ok(h:set_tags({ "b", "a" }))
      eq({ "b", "a" }, h.tags)
      ok(disk(work)[17]:match(":b:a:$"))
      ok(h:add_tag("c"))
      eq({ "b", "a", "c" }, h.tags)
      ok(h:remove_tag("b"))
      eq({ "a", "c" }, h.tags)
      ok(h:set_tags(":x:y:"))
      eq({ "x", "y" }, h.tags)
      eq(4, #events)
      eq({ "travel" }, events[1].from)
      eq({ "b", "a" }, events[1].to)
      ok(same_file(work, events[1].file))
      eq(17, events[1].lnum)
      -- no change, no event
      ok(h:set_tags({ "x", "y" }))
      eq(4, #events)
    end)

    it("set_priority fires OrgPriorityChanged", function()
      local events = listen("OrgPriorityChanged")
      local h = head("Write report")
      ok(h:set_priority("A"))
      eq("A", h.priority)
      ok(h:set_priority(nil))
      eq(nil, h.priority)
      eq("* TODO Write report :urgent:", squash(disk(work)[4]))
      eq(2, #events)
      eq({ "B", "A" }, { events[1].from, events[1].to })
      eq({ "A", nil }, { events[2].from, events[2].to })
      local res, err = h:set_priority("Z")
      eq(nil, res)
      ok(err:match("Priority must be"))
    end)

    it("set_property sets and removes properties", function()
      local events = listen("OrgPropertyChanged")
      local h = head("Plan offsite")
      ok(h:set_property("Where", "Lisbon"))
      eq("Lisbon", h.properties.WHERE)
      eq({ "Where", "Lisbon" }, { events[1].name, events[1].value })
      ok(h:set_property("Where", nil))
      eq(nil, h.properties.WHERE)
      ok(not table.concat(disk(work), "\n"):find("Lisbon", 1, true))
    end)

    it("schedule and deadline take dates in many forms", function()
      local h = head("Plan offsite")
      ok(h:schedule("2026-10-20"))
      eq("2026-10-20", h.scheduled.date)
      ok(h:schedule({ year = 2026, month = 10, day = 21, hour = 9, min = 30 }))
      eq("<2026-10-21 Wed 09:30>", h.scheduled.raw)
      ok(h:set_deadline("<2026-10-30 Fri>"))
      eq("2026-10-30", h.deadline.date)
      ok(h:schedule(os.time({ year = 2026, month = 11, day = 2, hour = 8, min = 0 })))
      eq("2026-11-02", h.scheduled.date)
      ok(h:schedule(nil))
      eq(nil, h.scheduled)
      ok(h:set_deadline(false))
      eq(nil, h.deadline)
      local res, err = h:schedule("not a date at all !!")
      eq(nil, res)
      ok(err:match("invalid date"))
    end)

    it("schedule keeps the old repeater and removes CLOSED", function()
      local h = head("Write report")
      ok(h:set_scheduled("2026-10-19"))
      eq("<2026-10-19 Mon +1w>", h.scheduled.raw)
      local c = head("Collect data")
      ok(c:schedule("2026-10-19"))
      eq(nil, c.closed)
    end)

    it("clock_in and clock_out fire events and report status", function()
      local cin, cout = listen("OrgClockIn"), listen("OrgClockOut")
      eq(nil, api.clock.status())
      eq(false, api.clock.is_running())
      local h = head("Plan offsite")
      ok(h:clock_in())
      ok(h:is_clocked_in())
      eq(true, api.clock.is_running())
      local st = api.clock.status()
      eq("Plan offsite", st.headline.title)
      ok(same_file(work, st.file))
      eq("number", type(st.minutes))
      ok(st.start.date:match("^%d%d%d%d%-%d%d%-%d%d$"))
      ok(table.concat(disk(work), "\n"):find("CLOCK: %["))
      -- clocking in again is a no-op
      ok(h:clock_in())
      eq(1, #cin)
      local other = head("Draft outline")
      local m, err = other:clock_out()
      eq(nil, m)
      ok(err:match("not running"))
      eq(0, h:clock_out())
      eq(nil, api.clock.status())
      eq(1, #cout)
      ok(table.concat(disk(work), "\n"):find("CLOCK: %[.-%]%-%-%[.-%] =>"))
    end)

    it("api.clock.clock_out and cancel stop the running clock", function()
      local h = head("Plan offsite")
      ok(h:clock_in())
      eq(0, api.clock.clock_out())
      local _, err = api.clock.clock_out()
      ok(err:match("no clock"))
      ok(h:clock_in())
      local cancel = listen("OrgClockCancel")
      eq(true, api.clock.cancel())
      eq(1, #cancel)
      eq(nil, open_clock(disk(work)))
      local _, err2 = api.clock.cancel()
      ok(err2:match("no clock"))
    end)

    it("cancel saves the file of the cancelled clock", function()
      setup(dir, { clock = { persist = true, persist_file = dir .. "/clock.json" } })
      local h = head("Plan offsite")
      eq(nil, utils.find_buffer(work))
      ok(h:clock_in())
      ok(open_clock(disk(work)))
      eq(true, api.clock.cancel())
      eq(nil, open_clock(disk(work)))
      local b = utils.find_buffer(work)
      eq(false, vim.bo[b].modified)
      -- the next session doesn't take up the cancelled clock again
      vim.cmd("bwipeout! " .. b)
      local clock = require("org.clock")
      clock.state = nil
      eq(nil, clock.restore())
    end)

    it("clock_out saves a clock that is not under a headline", function()
      local p = write(dir, "loose.org", { "CLOCK: [2026-10-02 Fri 11:00]", "* Task" })
      require("org.clock").state = { path = p, start = "[2026-10-02 Fri 11:00]", title = "loose" }
      eq(nil, api.clock.status().headline)
      eq(60, api.clock.clock_out())
      eq("CLOCK: [2026-10-02 Fri 11:00]--[2026-10-02 Fri 12:00] =>  1:00", disk(p)[1])
      eq(false, vim.bo[utils.find_buffer(p)].modified)
    end)

    it("cancel leaves a buffer with unsaved changes unsaved unless asked", function()
      open_file(work)
      local b = vim.api.nvim_get_current_buf()
      local h = head("Plan offsite")
      ok(h:clock_in())
      vim.api.nvim_buf_set_lines(b, -1, -1, false, { "* Unsaved" })
      eq(true, api.clock.cancel())
      eq(true, vim.bo[b].modified)
      ok(open_clock(disk(work)))
      ok(h:clock_in())
      eq(true, api.clock.cancel({ save = true }))
      eq(false, vim.bo[b].modified)
      eq(nil, open_clock(disk(work)))
      eq("* Unsaved", disk(work)[#disk(work)])
      vim.cmd("bwipeout!")
    end)

    it("refile moves under a headline and follows the entry", function()
      local events = listen("OrgRefile")
      local h = head("Plan offsite")
      local dest = head("Write report")
      ok(h:refile(dest))
      eq(2, h.level)
      eq({ "Write report" }, h.outline_path)
      local lines = disk(work)
      eq("** TODO Plan offsite :travel:", squash(lines[h.line]))
      eq(1, #events)
      eq("Plan offsite", events[1].title)
      eq(false, events[1].copy)
      ok(same_file(work, events[1].source_file))
    end)

    it("refile to another file, by headline title, and as a copy", function()
      local inbox = write(dir, "inbox.org", { "* Inbox", "* Later" })
      local h = head("Plan offsite")
      ok(h:refile({ file = inbox, headline = "Later" }))
      ok(same_file(inbox, h.file))
      eq({ "* Inbox", "* Later", "** TODO Plan offsite :travel:" }, vim.tbl_map(squash, disk(inbox)))
      ok(not table.concat(disk(work), "\n"):find("Plan offsite", 1, true))
      local d = head("Draft outline")
      ok(d:refile(inbox, { copy = true }))
      ok(same_file(work, d.file))
      eq("* NEXT Draft outline", disk(inbox)[4])
      ok(table.concat(disk(work), "\n"):find("Draft outline", 1, true))
      local _, err = d:refile({ file = inbox, headline = "Nope" })
      ok(err:match("no headline"))
    end)

    it("refile leaves a destination buffer with unsaved changes unsaved", function()
      local inbox = write(dir, "inbox.org", { "* Inbox" })
      open_file(inbox)
      local b = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(b, -1, -1, false, { "* Unsaved" })
      local h = head("Plan offsite")
      ok(h:refile({ file = inbox, headline = "Inbox" }))
      -- the entry is in the buffer; the file keeps what was saved
      eq({ "* Inbox" }, disk(inbox))
      eq(true, vim.bo[b].modified)
      ok(table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"):find("Plan offsite", 1, true))
      vim.cmd("bwipeout!")
    end)

    it("archive moves the subtree to the archive file", function()
      local events, final = listen("OrgArchive"), listen("OrgArchiveFinalize")
      local h = head("Plan offsite")
      local archive = h:archive()
      ok(archive:match("work%.org_archive$"))
      ok(table.concat(disk(archive), "\n"):find("Plan offsite", 1, true))
      ok(not table.concat(disk(work), "\n"):find("Plan offsite", 1, true))
      eq(1, #events)
      eq("Plan offsite", events[1].title)
      eq(1, #final)
      ok(same_file(archive, final[1].archive_file))
      local _, err = h:archive()
      ok(err:match("not found"))
    end)

    it("add_id creates an ID once, get_id reads it", function()
      local h = head("Plan offsite")
      eq(nil, h:get_id())
      local id = h:add_id()
      ok(id and #id > 10)
      eq(id, h.id)
      eq(id, h:get_id())
      eq(id, h:id_get_or_create())
      eq(id, api.find_by_id(id).id)
      eq("report-id", head("Write report"):add_id())
    end)

    it("open puts the cursor on the headline", function()
      local h = head("Plan offsite")
      ok(h:open())
      ok(same_file(work, vim.api.nvim_buf_get_name(0)))
      eq(17, vim.api.nvim_win_get_cursor(0)[1])
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      ok(h["goto"](h))
      eq(17, vim.api.nvim_win_get_cursor(0)[1])
      vim.cmd("bwipeout!")
    end)

    it("works on a buffer without a file", function()
      local buf = org_buffer({ "* TODO Scratch" }, { 1, 0 })
      local h = api.current().headlines[1]
      eq(nil, h.file)
      ok(h:set_todo("DONE"))
      eq({ "* DONE Scratch" }, buf_lines(buf))
      ok(h:open())
    end)

    it("finds a headline again after lines were added above it", function()
      local h = head("Plan offsite")
      local lines = disk(work)
      table.insert(lines, 1, "# a comment")
      utils.writefile(work, lines)
      ok(h:set_todo("DONE"))
      eq(18, h.line)
      eq("** DONE Plan offsite :travel:", squash(disk(work)[18]))
    end)

    it("never prompts", function()
      local calls = 0
      local input = vim.fn.input
      vim.fn.input = function()
        calls = calls + 1
        return ""
      end
      setup(dir, { log_reschedule = "note", log_redeadline = "note", refile = { log = "note" } })
      local h = head("Write report")
      local okk = pcall(function()
        ok(h:schedule("2026-10-26"))
        ok(h:refile(head("Projects")))
      end)
      vim.fn.input = input
      ok(okk)
      eq(0, calls)
      eq(false, utils.is_noninteractive())
      local text = table.concat(disk(work), "\n")
      ok(text:find('Rescheduled from "[2026-10-05 Mon +1w]"', 1, true))
      ok(text:find("Refiled on", 1, true))
    end)
  end)

  describe("agenda", function()
    it("lists days with their items", function()
      local days = api.agenda.agenda({ from = "2026-10-07", span = "week" })
      eq(7, #days)
      eq("2026-10-05", days[1].date)
      eq(5, days[1].day.day)
      local d1 = days[1].items
      eq(1, #d1)
      eq("Write report", d1[1].title)
      eq("scheduled", d1[1].type)
      eq("2026-10-05", d1[1].day)
      eq("Write report", d1[1].headline.title)
      ok(same_file(work, d1[1].file))
      eq(4, d1[1].line)
      eq({ "work", "urgent" }, d1[1].tags)
      local fri = days[5].items
      eq("deadline", fri[1].type)
      eq("2026-10-09", fri[1].date.date)
    end)

    it("starts on the given day without alignment and skips empty days", function()
      local days = api.agenda.agenda({ from = "2026-10-07", span = 3, align = false })
      eq(
        { "2026-10-07", "2026-10-08", "2026-10-09" },
        vim.tbl_map(function(d)
          return d.date
        end, days)
      )
      local some = api.agenda.agenda({ from = "2026-10-05", span = "week", include_empty = false })
      eq(
        { "2026-10-05", "2026-10-09" },
        vim.tbl_map(function(d)
          return d.date
        end, some)
      )
      local _, err = api.agenda.agenda({ span = "eon" })
      ok(err:match("invalid span"))
      local _, err2 = api.agenda.agenda({ from = "???" })
      ok(err2)
    end)

    it("shows times of timed entries", function()
      write(dir, "meet.org", { "* Meeting", "  <2026-10-06 Tue 14:00-15:30>" })
      local days = api.agenda.agenda({ from = "2026-10-06", span = "day" })
      local it_ = days[1].items[1]
      eq("Meeting", it_.title)
      eq("14:00", it_.time)
      eq("15:30", it_.end_time)
      eq("timestamp", it_.type)
    end)

    it("search keeps a headline-only query with todo_only", function()
      local p = write(dir, "notes.org", {
        "* TODO Outline the talk",
        "* TODO Slides",
        "  an outline in the body",
        "* Outline without keyword",
      })
      local function titles(list)
        return vim.tbl_map(function(i)
          return i.title
        end, list)
      end
      eq({ "Outline the talk", "Outline without keyword" }, titles(api.agenda.search("*outline", { files = p })))
      eq({ "Outline the talk", "Slides" }, titles(api.agenda.search("outline", { todo_only = true, files = p })))
      eq({ "Outline the talk" }, titles(api.agenda.search("*outline", { todo_only = true, files = p })))
      eq({ "Outline the talk" }, titles(api.agenda.search("*!outline", { todo_only = true, files = p })))
      eq({ "Outline the talk", "Slides" }, titles(api.agenda.search("!outline", { todo_only = true, files = p })))
    end)

    it("todo, tags and search lists", function()
      local titles = function(list)
        return vim.tbl_map(function(i)
          return i.title
        end, list)
      end
      eq({ "Write report", "Draft outline", "Plan offsite" }, titles(api.agenda.todo()))
      eq({ "Draft outline" }, titles(api.agenda.todo({ keywords = "NEXT" })))
      eq({ "Plan offsite" }, titles(api.agenda.tags("+travel")))
      eq({ "Write report", "Draft outline" }, titles(api.agenda.tags("+urgent", { todo_only = true })))
      eq({ "Draft outline" }, titles(api.agenda.search("outline")))
      eq("search", api.agenda.search("outline")[1].type)
      local res, err = api.agenda.tags("{a\\(}")
      eq(nil, res)
      ok(err)
      eq({ "Draft outline" }, titles(api.agenda.todo({ keywords = { "NEXT" }, files = work })))
    end)
  end)

  describe("capture", function()
    it("captures with a template key and prompt answers", function()
      setup(dir, {
        capture = {
          templates = {
            t = { description = "Task", template = "* TODO %^{Title} %^g\n  %^{Where|home}", target = "inbox.org" },
          },
        },
      })
      local events = listen("OrgCaptureAfterFinalize")
      local res = api.capture({ key = "t", values = { Title = "Buy milk", Tags = { "shop", "food" } } })
      ok(res, "captured")
      ok(same_file(dir .. "/inbox.org", res.file))
      eq("Buy milk", res.headline.title)
      eq({ "shop", "food" }, res.headline.tags)
      local lines = disk(dir .. "/inbox.org")
      ok(lines[1]:match("^%* TODO Buy milk%s+:shop:food:$"))
      -- an unanswered prompt takes its default
      eq("  home", lines[2])
      eq(1, #events)
      eq(res.bufnr, events[1].bufnr)
    end)

    it("captures with an ad hoc template, positional answers and %i", function()
      local res = api.capture({
        template = "* %^{First} and %^{Second}\n%i",
        target = dir .. "/notes.org",
        values = { "one", "two" },
        initial = "body text",
      })
      ok(res)
      eq({ "* one and two", "body text" }, disk(dir .. "/notes.org"))
      eq("one and two", res.headline.title)
    end)

    it("files under a headline and other template types", function()
      write(dir, "lists.org", { "* Shopping", "- [ ] bread" })
      local res = api.capture({
        template = "[ ] %^{Item}",
        type = "checkitem",
        target = dir .. "/lists.org",
        headline = "Shopping",
        values = { "eggs" },
      })
      ok(res)
      eq(nil, res.headline)
      eq({ "* Shopping", "- [ ] bread", "- [ ] eggs" }, disk(dir .. "/lists.org"))
    end)

    it("takes a date for %t and time prompts", function()
      local res = api.capture({
        template = "* Event %t\n  %^{When}t",
        target = dir .. "/d.org",
        date = "2026-12-24",
        values = { When = "2026-12-25" },
      })
      ok(res)
      local lines = disk(dir .. "/d.org")
      eq("* Event <2026-12-24 Thu>", lines[1])
      eq("  <2026-12-25 Fri>", lines[2])
    end)

    it("answers date prompts with any date the API takes", function()
      local t = os.time({ year = 2026, month = 12, day = 25, hour = 9, min = 30 })
      local res, err = api.capture({
        template = "* Event\n  %^{When}t\n  %^{Also}t\n  %^{Then}T",
        target = dir .. "/d2.org",
        values = { When = t, Also = { year = 2026, month = 12, day = 26 }, Then = api.date("2026-12-27 10:00-11:30") },
      })
      ok(res, err)
      eq(
        { "* Event", "  <2026-12-25 Fri 09:30>", "  <2026-12-26 Sat>", "  <2026-12-27 Sun 10:00-11:30>" },
        disk(dir .. "/d2.org")
      )
      local none, err2 =
        api.capture({ template = "* %^{When}t", target = dir .. "/d3.org", values = { { year = 2026 } } })
      eq(nil, none)
      ok(err2:match("year, month and day"), err2)
      local none2, err3 =
        api.capture({ template = "* %^{When}t", target = dir .. "/d3.org", values = { "no such day !!" } })
      eq(nil, none2)
      ok(err3:match("invalid date"), err3)
      eq(nil, utils.readfile(dir .. "/d3.org"))
    end)

    it("returns the entry when kill_buffer closed the target's buffer", function()
      local target = write(dir, "killed.org", { "* Old" })
      local events = listen("OrgCaptureAfterFinalize")
      local res, err = api.capture({
        template = { template = "* %^{Title}", target = target, kill_buffer = true },
        values = { "Fresh" },
      })
      ok(res, err)
      eq(nil, utils.find_buffer(target))
      eq(nil, res.bufnr)
      ok(same_file(target, res.file))
      eq(2, res.line)
      eq("Fresh", res.headline.title)
      ok(same_file(target, res.headline.file))
      eq({ "* Old", "* Fresh" }, disk(target))
      eq(1, #events)
    end)

    it("fails without a template", function()
      local res, err = api.capture({ key = "nope" })
      eq(nil, res)
      ok(err:match("no capture template"))
      local _, err2 = api.capture({})
      ok(err2)
    end)
  end)

  describe("links", function()
    it("stores, lists and formats links", function()
      local s = api.links.store("https://example.com", "Example")
      eq({ link = "https://example.com", desc = "Example" }, s)
      eq(s, api.links.stored()[1])
      eq("[[https://example.com][Example]]", api.links.format("https://example.com", "Example"))
      eq("[[a\\[b]]", api.links.format("a[b"))
    end)

    it("stores a link to a headline", function()
      local h = api.headlines({ files = work, title = "Write report" })[1]
      local l = api.links.store_location(h)
      ok(l.link:match("report%-id") or l.link:match("Write report"), l.link)
      eq(l, api.links.stored()[1])
    end)

    it("store_location saves the ID it creates", function()
      setup(dir, { links = { use_id = true } })
      local h = api.headlines({ files = work, title = "Plan offsite" })[1]
      eq(nil, utils.find_buffer(work))
      local l, err = api.links.store_location(h)
      ok(l, err)
      local id = l.link:match("^id:(.+)$")
      ok(id, l.link)
      ok(table.concat(disk(work), "\n"):find(":ID: +" .. vim.pesc(id)))
      eq(false, vim.bo[utils.find_buffer(work)].modified)
    end)

    it("store_location leaves a buffer with unsaved changes unsaved unless asked", function()
      setup(dir, { links = { use_id = true } })
      open_file(work)
      local b = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(b, -1, -1, false, { "* Unsaved" })
      local l = api.links.store_location({ bufnr = b, lnum = 17 })
      local id = l.link:match("^id:(.+)$")
      ok(id, l.link)
      ok(not table.concat(disk(work), "\n"):find(id, 1, true))
      eq(true, vim.bo[b].modified)
      local hidden = api.headlines({ files = work, title = "Hidden task" })[1]
      l = api.links.store_location(hidden, { save = true })
      ok(l.link:match("^id:"), l.link)
      eq(false, vim.bo[b].modified)
      ok(table.concat(disk(work), "\n"):find(id, 1, true))
      eq("* Unsaved", disk(work)[#disk(work)])
      vim.cmd("bwipeout!")
    end)

    it("store_location reports the error of a failing link type", function()
      setup(dir, {
        links = {
          types = {
            boom = {
              store = function()
                error("boom!", 0)
              end,
            },
          },
        },
      })
      open_file(work)
      local l, err = api.links.store_location()
      eq(nil, l)
      eq("boom!", err)
      vim.cmd("bwipeout!")
    end)

    it("inserts a link at the cursor or a position", function()
      local buf = org_buffer({ "See  here" }, { 1, 4 })
      eq("[[https://x.org][X]]", api.links.insert("https://x.org", "X"))
      eq({ "See [[https://x.org][X]] here" }, buf_lines(buf))
      api.links.insert("id:abc", nil, { bufnr = buf, row = 1, col = 0 })
      eq({ "[[id:abc]]See [[https://x.org][X]] here" }, buf_lines(buf))
    end)

    it("inserts a link whose description has several lines", function()
      local buf = org_buffer({ "See  here" }, { 1, 4 })
      eq("[[https://x.org][two\nlines]]", api.links.insert("https://x.org", " two\nlines\n"))
      eq({ "See [[https://x.org][two", "lines]] here" }, buf_lines(buf))
      local l = require("org.links").parse_links(table.concat(buf_lines(buf), "\n"))[1]
      eq({ "https://x.org", "two\nlines" }, { l.target, l.desc })
    end)

    it("resolves links without following them", function()
      local r = api.links.resolve("[[id:report-id]]")
      eq("id", r.type)
      eq(4, r.line)
      eq("Write report", r.headline.title)
      ok(same_file(work, r.file))
      r = api.links.resolve("file:" .. work .. "::*Plan offsite")
      eq("file", r.type)
      eq("*Plan offsite", r.search)
      eq(17, r.line)
      r = api.links.resolve("[[file:" .. work .. "::#projects][P]]")
      eq(13, r.line)
      r = api.links.resolve("file:" .. work .. "::12")
      eq(12, r.line)
      r = api.links.resolve("https://example.com")
      eq("https://example.com", r.url)
      eq("https", r.type)
      local _, err = api.links.resolve("id:missing-id")
      ok(err:match("cannot find"))
      -- internal links search the given buffer
      open_file(work)
      r = api.links.resolve("*Projects")
      eq("heading", r.type)
      eq(13, r.line)
      r = api.links.resolve("#projects")
      eq(13, r.line)
      r = api.links.resolve("Draft outline")
      eq("fuzzy", r.type)
      eq(10, r.line)
      vim.cmd("bwipeout!")
    end)
  end)

  describe("resolving links like following them", function()
    local TARGETS = {
      "#+TITLE: Targets",
      "* Projects",
      "  :PROPERTIES:",
      "  :CUSTOM_ID: projects",
      "  :ID:       proj-id",
      "  :END:",
      "** TODO Plan   offsite [1/2]",
      "#+NAME: my table",
      "| a | b |",
      "Text with a <<dedicated target>> and a <<<Radio Word>>>.",
      "#+begin_src sh",
      "echo hi (ref:greet)",
      "#+end_src",
      "* Draft outline",
    }
    -- link, the line following it goes to (nil: not found)
    local CASES = {
      { "*projects", 2 },
      { "*Plan offsite", 7 },
      { "#PROJECTS", 2 },
      { "my table", 8 },
      { "MY   TABLE", 8 },
      { "Dedicated  Target", 10 },
      { "Radio Word", nil },
      { "draft outline", 14 },
      { "(greet)", 12 },
      { "file:targets.org::*projects", 2 },
      { "[[file:targets.org::my table][the table]]", 8 },
      { "id:proj-id::plan offsite", 7 },
      { "id:proj-id", 2 },
      { "nothing like this", nil },
    }

    it("finds what following finds", function()
      local p = write(dir, "targets.org", TARGETS)
      config.opts.links.frame_setup = { file = "current" }
      open_file(p)
      local b = vim.api.nvim_get_current_buf()
      local links = require("org.links")
      local confirm = utils.confirm
      -- a missing heading is not created
      utils.confirm = function()
        return false
      end
      local function follow(link)
        vim.api.nvim_set_current_buf(b)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        local l = links.parse_links(link, { bracket_only = true })[1]
        local done, _, found = utils.noninteractive(links.open, l and l.target or link, { bufnr = b })
        assert(done, found)
        return found and vim.api.nvim_win_get_cursor(0)[1] or nil
      end
      local ok_, err = pcall(function()
        for _, case in ipairs(CASES) do
          local link, line = case[1], case[2]
          eq(line, follow(link), "following " .. link)
          local r = api.links.resolve(link, { bufnr = b })
          eq(line, r.line, "resolving " .. link)
          ok(same_file(p, r.file), link)
        end
      end)
      utils.confirm = confirm
      ok(ok_, err)
      local r = api.links.resolve("*projects", { bufnr = b })
      eq("Projects", r.headline.title)
      eq("*projects", r.search)
      eq("(greet)", api.links.resolve("(greet)", { bufnr = b }).search)
      -- searches that do more than find a line
      eq(nil, api.links.resolve("file:targets.org::/Projects/", { bufnr = b }).line)
      write(dir, "refs.bib", { "@book{smith,", "  title = {Projects}", "}" })
      r = api.links.resolve("file:refs.bib::Projects", { bufnr = b })
      ok(same_file(dir .. "/refs.bib", r.file))
      eq(nil, r.line)
      vim.cmd("bwipeout!")
    end)
  end)

  describe("events", function()
    it("lists the events and adds and removes listeners", function()
      for _, name in ipairs({
        "OrgTodoStateChange",
        "OrgPriorityChanged",
        "OrgTagsChanged",
        "OrgClockIn",
        "OrgClockOut",
        "OrgCaptureAfterFinalize",
        "OrgRefile",
        "OrgArchive",
        "OrgFileLoaded",
        "OrgFileWritten",
      }) do
        ok(api.events[name], name)
      end
      local n = 0
      local id = api.on("OrgTagsChanged", function()
        n = n + 1
      end)
      local h = api.headlines({ files = work, title = "Plan offsite" })[1]
      h:set_tags({ "one" })
      api.off(id)
      h:set_tags({ "two" })
      eq(1, n)
      local once = 0
      api.on("OrgTagsChanged", function()
        once = once + 1
      end, { once = true })
      h:set_tags({ "three" })
      h:set_tags({ "four" })
      eq(1, once)
    end)

    it("fires OrgTagsChanged and OrgPriorityChanged for the keys too", function()
      local tags, prio = listen("OrgTagsChanged"), listen("OrgPriorityChanged")
      local buf = org_buffer({ "* TODO Task" }, { 1, 0 })
      require("org.tags").toggle_tag(nil, "x")
      require("org.priority").up()
      require("org.priority").set(nil, "C")
      eq(1, #tags)
      eq({ {}, { "x" } }, { tags[1].from, tags[1].to })
      eq(2, #prio)
      eq(buf, prio[1].bufnr)
    end)

    it("fires OrgFileWritten after :w and after org's own saves", function()
      local got = {}
      local id = api.on("OrgFileWritten", function(data)
        got[#got + 1] = data
      end)
      local path = write(dir, "written.org", { "* One" })
      vim.cmd("enew!")
      vim.cmd.edit(vim.fn.fnameescape(path))
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "* Two" })
      vim.cmd("silent write")
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "* Three" })
      ok(require("org.utils").save_buffer(buf))
      -- a buffer that isn't org: nothing
      local txt = write(dir, "notes.txt", { "x" })
      vim.cmd.edit(vim.fn.fnameescape(txt))
      vim.cmd("silent write")
      api.off(id)
      vim.cmd("silent! bwipeout! " .. buf)
      local real = vim.fs.normalize(vim.uv.fs_realpath(path))
      eq(
        {
          { bufnr = buf, file = real, source = "write" },
          { bufnr = buf, file = real, source = "save_buffer" },
        },
        vim.tbl_map(function(d)
          return { bufnr = d.bufnr, file = vim.fs.normalize(vim.uv.fs_realpath(d.file)), source = d.source }
        end, got)
      )
    end)

    it("fires OrgFileLoaded for listeners with patterns that match it", function()
      local got = {}
      local function on(pattern)
        return vim.api.nvim_create_autocmd("User", {
          pattern = pattern,
          callback = function(ev)
            got[#got + 1] = pattern .. " " .. ev.match
          end,
        })
      end
      local fic = vim.o.fileignorecase
      local ids = {}
      local ok_, err = pcall(function()
        vim.o.fileignorecase = false
        ids = { on("Org*"), on("*Loaded"), on("Org[EF]ile?oaded"), on("orgfileloaded"), on("OrgTodo*") }
        api.load(write(dir, "glob.org", { "* Glob" }))
        vim.wait(200, function()
          return #got >= 3
        end)
        table.sort(got)
        eq({ "*Loaded OrgFileLoaded", "Org* OrgFileLoaded", "Org[EF]ile?oaded OrgFileLoaded" }, got)
        -- autocmd patterns ignore case with 'fileignorecase'
        got = {}
        vim.o.fileignorecase = true
        api.load(write(dir, "case.org", { "* Case" }))
        vim.wait(200, function()
          return #got >= 4
        end)
        table.sort(got)
        eq({
          "*Loaded OrgFileLoaded",
          "Org* OrgFileLoaded",
          "Org[EF]ile?oaded OrgFileLoaded",
          "orgfileloaded OrgFileLoaded",
        }, got)
      end)
      vim.o.fileignorecase = fic
      for _, id in ipairs(ids) do
        vim.api.nvim_del_autocmd(id)
      end
      ok(ok_, err)
    end)

    it("fires OrgFileLoaded once per read", function()
      local events = listen("OrgFileLoaded")
      local p = write(dir, "fresh.org", { "* Fresh" })
      api.load(p)
      api.load(p)
      vim.wait(200, function()
        return #events > 0
      end)
      eq(1, #events)
      ok(same_file(p, events[1].file))
      eq("disk", events[1].source)
      -- a buffer is parsed for the first time
      open_file(p)
      api.current()
      api.current()
      vim.wait(200, function()
        return #events > 1
      end)
      eq(2, #events)
      eq("buffer", events[2].source)
      eq(vim.api.nvim_get_current_buf(), events[2].bufnr)
      vim.cmd("bwipeout!")
    end)
  end)

  describe("API 1.3", function()
    local function titles(list)
      return vim.tbl_map(function(h)
        return h.title
      end, list)
    end
    local function dates(list)
      return vim.tbl_map(function(d)
        return d.date
      end, list)
    end

    it("is version 1.5", function()
      ok(api.has("1.4"))
      ok(api.has("1.5"))
    end)

    it("option() reads top-level and nested resolved options", function()
      eq(config.opts.org_directory, api.option("org_directory"))
      eq(config.opts.agenda.save_after_edit, api.option("agenda.save_after_edit"))
      eq(config.opts.ui.todo_keyword_faces, api.option("ui.todo_keyword_faces"))
      eq(nil, api.option("no_such_option"))
      eq(nil, api.option("org_directory.nested"))
      eq(nil, api.option(""))
    end)

    it("today() is org's today; a date has its day number and is made from one", function()
      eq("2026-10-02", api.today().date)
      eq(TODAY, api.today().days)
      eq(0, api.date("1970-01-01").days)
      eq(date.days_from_civil(2026, 10, 5), api.date("2026-10-05").days)
      local d = api.date({ days = date.days_from_civil(2026, 10, 5), hour = 10, min = 30 })
      eq({ "2026-10-05", "10:30" }, { d.date, d.time })
      local _, err = api.date({ days = "soon" })
      ok(err:match("days"))
      eq(date.days_from_civil(2026, 10, 1), api.load(work).headlines[3].closed.days)
    end)

    it("occurrences() lists the days a timestamp falls on", function()
      eq(
        { "2026-10-05", "2026-10-12", "2026-10-19", "2026-10-26" },
        dates(assert(api.occurrences("<2026-10-05 Mon +1w>", "2026-10-01", "2026-10-31")))
      )
      eq({ "2026-10-05" }, dates(assert(api.occurrences("<2026-10-05 Mon>", "2026-10-01", "2026-10-31"))))
      eq({}, dates(assert(api.occurrences("<2026-10-05 Mon>", "2026-11-01", "2026-11-30"))))
      -- a handle's date as it is, and day numbers
      local s = api.load(work).headlines[1].scheduled
      local n = date.days_from_civil(2026, 10, 19)
      eq({ "2026-10-19" }, dates(assert(api.occurrences(s, { days = n }, { days = n }))))
      local res, err = api.occurrences("nonsense", "2026-10-01", "2026-10-31")
      eq(nil, res)
      ok(err)
      -- past 5,000 dates: an error, not a list cut short
      eq(4748, #assert(api.occurrences("<2026-01-01 Thu +1d>", "2026-01-01", "2038-12-31")))
      res, err = api.occurrences("<2026-01-01 Thu +1d>", "2026-01-01", "2039-12-31")
      eq(nil, res)
      ok(err:match("more than 5000 occurrences"), err)
    end)

    it("todo_keywords() of the option, a file and a buffer, in their order", function()
      local g = assert(api.todo_keywords())
      eq({ { "TODO", "NEXT", "DONE" }, { "TODO", "NEXT" }, { "DONE" } }, { g.all, g.todo, g.done })
      local p = write(dir, "seq.org", { "#+TODO: TODO | DONE", "#+TODO: BUG FIX | FIXED", "* BUG A" })
      local f = assert(api.todo_keywords(p))
      eq({ "TODO", "DONE", "BUG", "FIX", "FIXED" }, f.all)
      eq({ "TODO", "BUG", "FIX" }, f.todo)
      eq(f.all, api.load(p).todo_keywords.all)
      local buf = org_buffer({ "#+TODO: OPEN | SHUT", "* OPEN x" })
      eq({ "OPEN", "SHUT" }, assert(api.todo_keywords(buf)).all)
      eq({ "OPEN", "SHUT" }, assert(api.todo_keywords(0)).all)
      local _, err = api.todo_keywords(dir .. "/missing.org")
      ok(err:match("cannot read"))
      vim.cmd("enew!")
      local _, err2 = api.todo_keywords(0)
      ok(err2:match("not an org buffer"))
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)

    it("handles have effort, priority_value and bufnr", function()
      local p = write(dir, "prio.org", {
        "* TODO [#A] First",
        "  :PROPERTIES:",
        "  :Effort: 1:30",
        "  :END:",
        "* TODO Second",
        "* TODO [#C] Third",
      })
      local hs = assert(api.headlines({ files = p }))
      eq({ 90, nil, nil }, { hs[1].effort, hs[2].effort, hs[3].effort })
      -- org-get-priority: 1000 * (lowest - priority), the default (B)
      -- without a cookie
      eq({ 2000, 1000, 0 }, { hs[1].priority_value, hs[2].priority_value, hs[3].priority_value })
      eq(60, api.load(work).headlines[1].effort)
      -- the entry's own, as the agenda reads it: never inherited
      local inherit = config.opts.use_property_inheritance
      config.opts.use_property_inheritance = true
      local q = write(dir, "inherit.org", { "* P", "  :PROPERTIES:", "  :Effort: 1:00", "  :END:", "** child" })
      local kids = assert(api.headlines({ files = q }))
      config.opts.use_property_inheritance = inherit
      eq({ 60, nil }, { kids[1].effort, kids[2].effort })
      eq(nil, hs[1].bufnr)
      open_file(p)
      eq(vim.api.nvim_get_current_buf(), assert(api.current()).headlines[1].bufnr)
      vim.cmd("bwipeout!")
    end)

    it("queries a buffer, a subtree, what the agenda looks at and dated entries", function()
      local buf = org_buffer({
        "* TODO A",
        "* B",
        "** TODO C",
        "** COMMENT D",
        "*** TODO E",
        "* TODO F :ARCHIVE:",
        "* TODO G",
        "  SCHEDULED: <2026-10-05 Mon>",
      })
      eq({ "A", "B", "C", "D", "E", "F", "G" }, titles(assert(api.headlines({ bufnr = buf }))))
      eq({ "A", "B", "C", "G" }, titles(assert(api.headlines({ bufnr = buf, agenda = true }))))
      local b = assert(api.headlines({ bufnr = buf, title = "B" }))[1]
      eq({ "B", "C", "D", "E" }, titles(assert(api.headlines({ within = b }))))
      eq({ "B", "C" }, titles(assert(api.headlines({ within = b, agenda = true }))))
      eq({ "G" }, titles(assert(api.headlines({ bufnr = buf, planned = true }))))
      eq(6, #assert(api.headlines({ bufnr = buf, planned = false })))
      -- a subtree skip is asked about the matches only (org-agenda-skip
      -- runs after the matcher): a DONE parent the query doesn't match
      -- doesn't hide its TODO child
      local skip_buf = org_buffer({ "* DONE parent", "** TODO child" })
      local agenda_opts = require("org.config").opts.agenda
      local global = agenda_opts.skip_function_global
      agenda_opts.skip_function_global = require("org.agenda").skip_subtree_if("todo", { "DONE" })
      local res = titles(assert(api.headlines({ bufnr = skip_buf, agenda = true, todo = "TODO" })))
      agenda_opts.skip_function_global = global
      eq({ "child" }, res)
      vim.cmd("enew!")
      local _, err = api.headlines({ bufnr = 0 })
      ok(err:match("not an org buffer"))
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end)

    it("fills only the fields a query asks for, and every field again on reload", function()
      local hs = assert(api.headlines({ files = work, fields = { "scheduled" } }))
      local h = hs[1]
      eq("2026-10-05", h.scheduled.date)
      eq({ nil, nil, nil, nil }, { h.deadline, h.all_tags, h.properties, h.category })
      eq({ "Write report", "TODO", "B", 4, "report-id" }, { h.plain_title, h.todo, h.priority, h.line, h.id })
      ok(h:reload())
      eq({ "work", "urgent" }, h.all_tags)
      eq("2026-10-09", h.deadline.date)
      local res, err = api.headlines({ fields = "scheduled" })
      eq(nil, res)
      ok(err:match("fields"))
      -- a misspelt name isn't a field nobody has
      res, err = api.headlines({ files = work, fields = { "efort" } })
      eq(nil, res)
      ok(err:match('invalid field: "efort"'), err)
    end)

    it("clocks() lists the CLOCK lines of the entries, in a range of days", function()
      local p = write(dir, "time.org", {
        "* Task one",
        "  :LOGBOOK:",
        "  CLOCK: [2026-10-01 Thu 09:00]--[2026-10-01 Thu 10:30] =>  1:30",
        "  CLOCK: [2026-09-20 Sun 09:00]--[2026-09-20 Sun 09:30] =>  0:30",
        "  :END:",
        "* Task two",
        "  CLOCK: [2026-10-02 Fri 11:00]",
      })
      local all = assert(api.clocks({ files = p }))
      eq(3, #all)
      local c = all[1]
      eq(
        { "Task one", "09:00", "10:30", 90, false, 3 },
        { c.headline.title, c.start.time, c["end"].time, c.minutes, c.running, c.line }
      )
      -- one handle per entry
      ok(rawequal(all[1].headline, all[2].headline))
      -- a running clock: until now (12:00)
      eq({ "Task two", true, nil, 60 }, { all[3].headline.title, all[3].running, all[3]["end"], all[3].minutes })
      eq(2, #assert(api.clocks({ files = p, from = "2026-10-01", to = "2026-10-31" })))
      local oct1 = assert(api.clocks({ files = p, from = "2026-10-01", to = "2026-10-01" }))
      eq({ "Task one" }, {
        oct1[1].headline.title,
        oct1[2] and oct1[2].headline.title or nil,
      })
      eq(1, #assert(api.clocks({ files = p, title = "two" })))
      local _, err = api.clocks({ files = p, from = "???" })
      ok(err)
      -- minutes from the timestamps, not a stale `=>` text (org-clock-sum);
      -- 0 for one that ends before it starts
      local q = write(dir, "stale.org", {
        "* Task",
        "  CLOCK: [2026-10-01 Thu 09:00]--[2026-10-01 Thu 10:00] =>  2:00",
        "  CLOCK: [2026-10-01 Thu 11:00]--[2026-10-01 Thu 10:00] => -1:00",
      })
      eq(
        { 60, 0 },
        vim.tbl_map(function(x)
          return x.minutes
        end, assert(api.clocks({ files = q })))
      )
    end)

    it("clocks() gives plain dates, as api.date makes them", function()
      local p = write(dir, "dates.org", {
        "* Task",
        "  :LOGBOOK:",
        "  CLOCK: [2026-10-01 Thu 23:00]--[2026-10-02 Fri 01:30] =>  2:30",
        "  CLOCK: [2026-09-30 Wed 09:00 +1w]--[2026-09-30 Wed 10:15] =>  1:15",
        "  CLOCK: [2026-09-29 Tue 09:00-09:30]--[2026-09-29 Tue 10:00] =>  1:00",
        "  CLOCK: [2026-09-28 Mon 09:00]--[2026-09-29 Tue] =>  0:00",
        "  CLOCK: [2026-09-27 Sun]--[2026-09-27 Sun 10:00] =>  0:00",
        "  :END:",
      })
      local cs = assert(api.clocks({ files = p }))
      eq(
        { 150, 75, 60, 1440, 0 },
        vim.tbl_map(function(c)
          return c.minutes
        end, cs)
      )
      for _, c in ipairs(cs) do
        for _, d in ipairs({ c.start, c["end"] }) do
          -- field by field what api.date() makes of its text, in a plain
          -- table: pairs(), vim.json.encode() and vim.deep_equal() see it whole
          local want = assert(api.date(d.text))
          eq(nil, getmetatable(d))
          eq(want, d)
          ok(vim.deep_equal(want, d))
          eq(vim.json.decode(vim.json.encode(want)), vim.json.decode(vim.json.encode(d)))
          eq(vim.tbl_count(want), vim.tbl_count(d))
        end
      end
      eq("[2026-10-01 Thu 23:00]", cs[1].start.text)
      eq({ type = "+", value = 1, unit = "w" }, cs[2].start.repeater)
      eq("[2026-09-30 Wed 09:00 +1w]", cs[2].start.text)
      eq({ 9, 30, "09:00", "[2026-09-29 Tue 09:00-09:30]" }, {
        cs[3].start.end_hour,
        cs[3].start.end_min,
        cs[3].start.time,
        cs[3].start.text,
      })
      eq({ nil, nil, "2026-09-27", "[2026-09-27 Sun]" }, {
        cs[5].start.hour,
        cs[5].start.time,
        cs[5].start.date,
        cs[5].start.text,
      })
    end)

    it("clocks() counts the minutes of a daylight-saving day as they elapsed", function()
      local saved = vim.env.TZ
      date.set_tz(tz("America/New_York"))
      local p = write(dir, "dst.org", {
        "* Task",
        "  :LOGBOOK:",
        "  CLOCK: [2026-03-08 Sun 01:30]--[2026-03-08 Sun 03:30] =>  2:00",
        "  CLOCK: [2026-03-07 Sat 22:00]--[2026-03-08 Sun 04:00] =>  6:00",
        "  CLOCK: [2026-11-01 Sun 00:30]--[2026-11-01 Sun 02:30] =>  2:00",
        "  CLOCK: [2026-11-02 Mon 00:30]--[2026-11-02 Mon 02:30] =>  2:00",
        "  :END:",
      })
      local ok_, got = pcall(function()
        return vim.tbl_map(function(c)
          return { c.minutes, (c["end"].timestamp - c.start.timestamp) / 60 }
        end, assert(api.clocks({ files = p })))
      end)
      date.set_tz(saved)
      ok(ok_, got)
      -- 2:00 to 3:00 is skipped in spring and 1:00 to 2:00 repeated in
      -- the fall; the day after counts its wall-clock time
      eq({ { 60, 60 }, { 300, 300 }, { 180, 180 }, { 120, 120 } }, got)
    end)

    it("completed() lists when entries were marked done", function()
      local p = write(dir, "done.org", {
        "* DONE Report",
        "  CLOSED: [2026-10-01 Thu 18:00]",
        "  :LOGBOOK:",
        '  - State "DONE"       from "TODO"       [2026-10-01 Thu 18:00]',
        "  :END:",
        "* TODO Water plants",
        "  SCHEDULED: <2026-10-03 Sat .+1d>",
        "  :PROPERTIES:",
        "  :LAST_REPEAT: [2026-10-02 Fri 08:00]",
        "  :END:",
        "  :LOGBOOK:",
        '  - State "DONE"       from "TODO"       [2026-10-02 Fri 08:00]',
        '  - State "NEXT"       from "TODO"       [2026-09-30 Wed 08:00]',
        "  - CLOSING NOTE [2026-09-28 Mon 08:00] \\\\",
        "    all good",
        "  :END:",
      })
      local function rows(list)
        return vim.tbl_map(function(x)
          return { x.headline.title, x.type, x.date.date }
        end, list)
      end
      -- an entry's CLOSED first, then its log lines, then LAST_REPEAT
      eq({
        { "Report", "closed", "2026-10-01" },
        { "Report", "state", "2026-10-01" },
        { "Water plants", "state", "2026-10-02" },
        { "Water plants", "note", "2026-09-28" },
        { "Water plants", "last_repeat", "2026-10-02" },
      }, rows(assert(api.completed({ files = p }))))
      eq(
        { { "Report", "closed", "2026-10-01" }, { "Report", "state", "2026-10-01" } },
        rows(assert(api.completed({ files = p, from = "2026-09-29", to = "2026-10-01" })))
      )
      -- a closing note per `log_note_headings.done`, as org-habit reads it
      local headings = config.opts.log_note_headings
      config.opts.log_note_headings = vim.tbl_extend("force", headings, { done = "Finished %t" })
      local q = write(dir, "finished.org", {
        "* DONE Read",
        "  - Finished [2026-10-01 Thu 10:00]",
        "  - CLOSING NOTE [2026-09-30 Wed 10:00]",
      })
      local got = rows(assert(api.completed({ files = q })))
      config.opts.log_note_headings = headings
      eq({ { "Read", "note", "2026-10-01" } }, got)
    end)

    it("set_todo with interactive asks for the note the logging wants", function()
      config.opts.todo_keywords = { "TODO(t@)", "NEXT", "|", "DONE(d@)" }
      local input_note = utils.input_note
      local asked
      utils.input_note = function(o)
        asked = o.prompt
        return "Typed note"
      end
      local h = assert(api.headlines({ files = work, title = "Plan offsite" }))[1]
      local res, err = h:set_todo("DONE", { interactive = true })
      utils.input_note = input_note
      eq(h, res)
      eq(nil, err)
      ok(asked)
      ok(table.concat(disk(work), "\n"):find("Typed note", 1, true))
    end)

    it("an interactive change org refuses returns nil without an error", function()
      config.opts.enforce_todo_dependencies = true
      local notify = vim.notify
      local said = {}
      vim.notify = function(m)
        said[#said + 1] = m
      end
      local h = assert(api.headlines({ files = work, title = "Write report" }))[1]
      local res, err = h:set_todo("DONE", { interactive = true })
      local res2, err2 = h:set_todo("DONE")
      vim.notify = notify
      config.opts.enforce_todo_dependencies = false
      eq({ nil, nil }, { res, err })
      ok(#said > 0)
      eq(nil, res2)
      ok(err2)
    end)

    it("schedule and set_deadline with interactive ask with the date prompt", function()
      local cal = require("org.calendar")
      local pick = cal.pick
      local asked = {}
      cal.pick = function(o)
        asked[#asked + 1] = o.prompt
        return date.from_days(date.days_from_civil(2026, 10, 20))
      end
      local h = assert(api.headlines({ files = work, title = "Plan offsite" }))[1]
      ok(h:schedule(nil, { interactive = true }))
      eq("2026-10-20", h.scheduled.date)
      ok(h:set_deadline(nil, { interactive = true }))
      eq("2026-10-20", h.deadline.date)
      cal.pick = function(o)
        asked[#asked + 1] = o.prompt
        return nil
      end
      local res, err = h:schedule(nil, { interactive = true })
      eq({ nil, nil }, { res, err })
      -- cancelling the deadline prompt asks nothing more (no Schedule)
      res, err = h:set_deadline(nil, { interactive = true })
      cal.pick = pick
      eq({ nil, nil }, { res, err })
      eq({ "Schedule", "Deadline", "Schedule", "Deadline" }, asked)
      ok(table.concat(disk(work), "\n"):find("SCHEDULED: <2026-10-20 Tue>", 1, true))
      -- without interactive, nil removes the date
      ok(h:schedule(nil))
      eq(nil, h.scheduled)
    end)

    it("move_after and move_before move a subtree past its siblings", function()
      local p = write(dir, "order.org", { "* A", "** A1", "* B", "* C", "* D" })
      local hs = assert(api.headlines({ files = p, level = 1 }))
      local a, b, c, d = hs[1], hs[2], hs[3], hs[4]
      eq(a, a:move_after(c))
      eq({ "* B", "* C", "* A", "** A1", "* D" }, disk(p))
      eq(3, a.line)
      ok(a:move_before(b))
      eq({ "* A", "** A1", "* B", "* C", "* D" }, disk(p))
      ok(d:move_before(b))
      eq({ "* A", "** A1", "* D", "* B", "* C" }, disk(p))
      ok(d:move_after(c))
      eq({ "* A", "** A1", "* B", "* C", "* D" }, disk(p))
      -- already there: nothing moves
      ok(b:move_after(a))
      eq({ "* A", "** A1", "* B", "* C", "* D" }, disk(p))
      local a1 = assert(api.headlines({ files = p, title = "A1" }))[1]
      local res, err = a1:move_after(c)
      eq(nil, res)
      ok(err:match("not a sibling"))
      local _, err2 = a:move_after("C")
      ok(err2:match("invalid sibling"))
    end)

    it("agenda.open opens the agenda view on a day", function()
      local agenda = require("org.agenda")
      local open_day, open_agenda = agenda.open_day, agenda.open_agenda
      local calls = {}
      agenda.open_day = function(n)
        calls[#calls + 1] = { "day", n }
      end
      agenda.open_agenda = function(o)
        calls[#calls + 1] = { "agenda", o.span, o.anchor }
      end
      ok(api.agenda.open({ from = "2026-10-05", span = "day" }))
      ok(api.agenda.open({ from = "2026-10-05", span = "week" }))
      ok(api.agenda.open())
      local res, err = api.agenda.open({ span = "eon" })
      agenda.open_day, agenda.open_agenda = open_day, open_agenda
      local mon = date.days_from_civil(2026, 10, 5)
      eq({ { "day", mon }, { "agenda", "week", mon }, { "agenda", nil, TODAY } }, calls)
      eq(nil, res)
      ok(err:match("invalid span"))
    end)
  end)
end)
