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

local function text(path)
  return table.concat(disk(path), "\n")
end

local function open_file(path)
  vim.cmd("enew!")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

--- A headline line with its tags aligned or not.
local function squash(line)
  return (line:gsub("%s+(:[^%s]+:)$", " %1"))
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

  describe("saving", function()
    for _, save_file in ipairs({ false, "from_agenda" }) do
      it(
        "archive saves the archive file with the source (archive_subtree_save_file " .. tostring(save_file) .. ")",
        function()
          setup(dir, { archive_subtree_save_file = save_file })
          local archive = head("Plan offsite"):archive()
          ok(archive, "archived")
          ok(not text(work):find("Plan offsite", 1, true))
          ok(text(archive):find("Plan offsite", 1, true), "the archived entry is on disk")
          eq(false, vim.bo[utils.find_buffer(archive)].modified)
        end
      )
    end

    it("archive with save = true saves the archive file too", function()
      setup(dir, { archive_subtree_save_file = false })
      local archive = head("Plan offsite"):archive({ save = true })
      ok(text(archive):find("Plan offsite", 1, true))
      ok(not text(work):find("Plan offsite", 1, true))
    end)

    it("archive leaves the source unsaved when the archive file keeps unsaved changes", function()
      setup(dir, { archive_subtree_save_file = false })
      local archive = write(dir, "work.org_archive", { "* Old" })
      local ab = open_file(archive)
      vim.api.nvim_buf_set_lines(ab, -1, -1, false, { "* Unsaved" })
      ok(head("Plan offsite"):archive())
      -- on disk the entry is still in the source, never in neither file
      ok(text(work):find("Plan offsite", 1, true))
      eq({ "* Old" }, disk(archive))
      eq(true, vim.bo[ab].modified)
      eq(true, vim.bo[utils.find_buffer(work)].modified)
      ok(table.concat(buf_lines(ab), "\n"):find("Plan offsite", 1, true))
    end)

    it("refile leaves the source unsaved when the destination keeps unsaved changes", function()
      local inbox = write(dir, "inbox.org", { "* Inbox" })
      local ib = open_file(inbox)
      vim.api.nvim_buf_set_lines(ib, -1, -1, false, { "* Unsaved" })
      ok(head("Plan offsite"):refile({ file = inbox, headline = "Inbox" }))
      eq({ "* Inbox" }, disk(inbox))
      ok(text(work):find("Plan offsite", 1, true), "the entry stays in the source on disk")
      eq(true, vim.bo[utils.find_buffer(work)].modified)
    end)

    it("refile saves both files when neither had unsaved changes", function()
      local inbox = write(dir, "inbox.org", { "* Inbox" })
      local ib = open_file(inbox)
      ok(head("Plan offsite"):refile({ file = inbox, headline = "Inbox" }))
      ok(text(inbox):find("Plan offsite", 1, true))
      ok(not text(work):find("Plan offsite", 1, true))
      eq(false, vim.bo[ib].modified)
    end)

    --- Open and closed CLOCK lines of a file on disk.
    local function clocks(path)
      local open, closed = 0, 0
      for _, l in ipairs(disk(path)) do
        if l:match("^%s*CLOCK: %[[^%]]+%]%s*$") then
          open = open + 1
        elseif l:match("^%s*CLOCK: %[[^%]]+%]%-%-%[[^%]]+%]%s+=>") then
          closed = closed + 1
        end
      end
      return { open = open, closed = closed }
    end

    it("clock_in saves the file whose clock it stopped", function()
      local a = write(dir, "a.org", { "* Task A" })
      local b = write(dir, "b.org", { "* Task B" })
      ok(head("Task A", a):clock_in())
      eq({ open = 1, closed = 0 }, clocks(a))
      ok(head("Task B", b):clock_in())
      -- one open clock on disk: A's is closed and saved, B's runs
      eq({ open = 0, closed = 1 }, clocks(a))
      eq({ open = 1, closed = 0 }, clocks(b))
      eq(false, vim.bo[utils.find_buffer(a)].modified)
    end)

    it("save = false writes none of the files", function()
      local a = write(dir, "a.org", { "* Task A" })
      local b = write(dir, "b.org", { "* Task B" })
      ok(head("Task A", a):clock_in())
      ok(head("Task B", b):clock_in({ save = false }))
      eq({ open = 1, closed = 0 }, clocks(a))
      eq({ open = 0, closed = 0 }, clocks(b))
      eq(true, vim.bo[utils.find_buffer(a)].modified)
    end)
    it("clock_in saves neither file when the other one had unsaved changes", function()
      local a = write(dir, "a.org", { "* Task A" })
      local b = write(dir, "b.org", { "* Task B" })
      ok(head("Task A", a):clock_in())
      local ab = utils.find_buffer(a)
      vim.api.nvim_buf_set_lines(ab, -1, -1, false, { "* Unsaved" })
      ok(head("Task B", b):clock_in())
      eq({ open = 1, closed = 0 }, clocks(a))
      eq({ open = 0, closed = 0 }, clocks(b))
      eq(true, vim.bo[ab].modified)
      eq(true, vim.bo[utils.find_buffer(b)].modified)
    end)

    it("a failed save of the archive file leaves the source unsaved", function()
      skip_on_windows("file modes")
      setup(dir, { archive_subtree_save_file = false })
      local archive = write(dir, "work.org_archive", { "* Old" })
      vim.uv.fs_chmod(archive, tonumber("444", 8))
      local res, err = head("Plan offsite"):archive()
      vim.uv.fs_chmod(archive, tonumber("644", 8))
      eq(nil, res)
      ok(err:match("could not save"), err)
      eq({ "* Old" }, disk(archive))
      ok(text(work):find("Plan offsite", 1, true))
    end)
  end)

  describe("finding the headline again", function()
    local CALLS = {
      "* TODO Call",
      "  :PROPERTIES:",
      "  :ID:       call-a",
      "  :END:",
      "* TODO Call",
      "  :PROPERTIES:",
      "  :ID:       call-b",
      "  :END:",
    }

    it("an ID decides, not the line", function()
      local p = write(dir, "calls.org", CALLS)
      local hb = api.find_by_id("call-b")
      eq(5, hb.line)
      local lines = disk(p)
      for _ = 1, 4 do
        table.insert(lines, 1, "# note")
      end
      utils.writefile(p, lines)
      ok(hb:set_todo("DONE"))
      lines = disk(p)
      eq("* TODO Call", lines[5])
      eq("* DONE Call", lines[9])
      eq(9, hb.line)
    end)

    it("an ID that no entry has any more is an error, never another entry", function()
      local p = write(dir, "calls.org", CALLS)
      local hb = api.find_by_id("call-b")
      local lines = disk(p)
      lines[7] = "  :ID:       call-c"
      lines[3] = "  :ID:       call-x"
      utils.writefile(p, lines)
      local res, err = hb:set_todo("DONE")
      eq(nil, res)
      ok(err:match("call%-b"), err)
      eq(CALLS[1], disk(p)[1])
      eq(CALLS[5], disk(p)[5])
    end)

    local REVIEWS = {
      "* Reviews",
      "** DONE Weekly review",
      "   CLOSED: [2026-08-01 Sat 10:00]",
      "** DONE Weekly review",
      "   CLOSED: [2026-08-08 Sat 10:00]",
      "** DONE Weekly review",
      "   CLOSED: [2026-09-28 Mon 10:00]",
      "** DONE Weekly review",
      "   CLOSED: [2026-10-01 Thu 10:00]",
    }

    local function old(h)
      return h.closed ~= nil and h.closed.date < "2026-09-01"
    end

    it("archiving each handle of a query archives the selected entries", function()
      local p = write(dir, "reviews.org", REVIEWS)
      local list = api.headlines({ files = p, done = true, filter = old })
      eq(2, #list)
      for _, h in ipairs(list) do
        ok(h:archive())
      end
      local left = text(p)
      ok(left:find("2026-09-28", 1, true), "Sep 28 stays")
      ok(left:find("2026-10-01", 1, true), "Oct 1 stays")
      ok(not left:find("2026-08", 1, true), "Aug entries archived")
      local archived = text(p .. "_archive")
      ok(archived:find("2026-08-01", 1, true))
      ok(archived:find("2026-08-08", 1, true))
      ok(not archived:find("2026-09-28", 1, true))
    end)

    it("handles follow the user's edits of a loaded buffer", function()
      local p = write(dir, "reviews.org", REVIEWS)
      local b = open_file(p)
      local list = api.headlines({ files = p, done = true, filter = old })
      eq(2, #list)
      -- the first entry goes: the Sep 28 one is now where Aug 8's was
      vim.api.nvim_buf_set_lines(b, 1, 3, false, {})
      ok(list[2]:set_todo("TODO"))
      eq("** TODO Weekly review", buf_lines(b)[2])
      eq("   CLOSED: [2026-08-08 Sat 10:00]", buf_lines(b)[3])
      eq(2, list[2].line)
      -- lines added at the top
      vim.api.nvim_buf_set_lines(b, 0, 0, false, { "#+TITLE: Reviews", "" })
      ok(list[2]:set_todo("DONE"))
      eq("** DONE Weekly review", buf_lines(b)[4])
      eq(4, list[2].line)
      ok(list[2]:set_todo("TODO"))
      -- the deleted entry's handle doesn't find another one
      local res, err = list[1]:set_todo("TODO")
      eq(nil, res)
      ok(err:match("get a new handle"), err)
      local todos = 0
      for _, l in ipairs(buf_lines(b)) do
        todos = todos + (l:match("^%*%* TODO") and 1 or 0)
      end
      eq(1, todos)
    end)

    it("sibling handles follow lines added by another handle's change", function()
      local p = write(dir, "reviews.org", REVIEWS)
      local list = api.headlines({ files = p, title = "Weekly review" })
      eq(4, #list)
      ok(list[1]:set_property("Where", "Office"))
      ok(list[1]:schedule("2026-10-10"))
      ok(list[3]:set_todo("TODO"))
      local lines = disk(p)
      local n = 0
      for i, l in ipairs(lines) do
        if l:match("^%*%* ") then
          n = n + 1
          if n == 3 then
            eq("** TODO Weekly review", l)
            eq("   CLOSED: [2026-09-28 Mon 10:00]", lines[i + 1])
          else
            eq("** DONE Weekly review", l)
          end
        end
      end
      eq(4, n)
    end)

    it("an ambiguous headline is an error instead of a guess", function()
      local p = write(dir, "reviews.org", REVIEWS)
      local h = api.headlines({ files = p, title = "Weekly review" })[2]
      -- changed on disk behind the handle's back: two lines removed above it
      local lines = disk(p)
      table.remove(lines, 2)
      table.remove(lines, 2)
      utils.writefile(p, lines)
      local res, err = h:set_todo("TODO")
      eq(nil, res)
      ok(err:match("get a new handle"), err)
      ok(not text(p):find("TODO", 1, true))
    end)

    it("a unique headline is still found after an outside change", function()
      local h = head("Write report")
      local lines = disk(work)
      table.insert(lines, 1, "#+TITLE: Work")
      utils.writefile(work, lines)
      ok(h:set_todo("DONE"))
      eq("** DONE Write report", disk(work)[5])
    end)

    it("handles read from disk follow the buffer once the file is opened", function()
      local p = write(dir, "reviews.org", REVIEWS)
      local list = api.headlines({ files = p, done = true, filter = old })
      local b = open_file(p)
      vim.api.nvim_buf_set_lines(b, 1, 3, false, {})
      ok(list[2]:reload())
      eq(2, list[2].line)
      ok(list[2]:set_todo("TODO"))
      eq("** TODO Weekly review", buf_lines(b)[2])
      eq("   CLOSED: [2026-08-08 Sat 10:00]", buf_lines(b)[3])
    end)

    it("a file read again after an outside change doesn't make a handle take another entry", function()
      local p = write(dir, "reviews.org", REVIEWS)
      local b = open_file(p)
      local list = api.headlines({ files = p, title = "Weekly review" })
      local lines = disk(p)
      table.remove(lines, 2)
      table.remove(lines, 2)
      utils.writefile(p, lines)
      vim.cmd("silent edit!")
      local res, err = list[2]:set_todo("TODO")
      eq(nil, res)
      ok(err:match("get a new handle"), err)
      ok(not table.concat(buf_lines(b), "\n"):find("TODO", 1, true))
    end)

    it("a parent whose statistics cookie changed is still found", function()
      local p = write(dir, "project.org", { "* TODO Project [0/2]", "** TODO a", "** TODO b" })
      local list = api.headlines({ files = p })
      ok(list[2]:set_todo("DONE"))
      ok(list[3]:set_todo("DONE"))
      eq("* TODO Project [2/2]", disk(p)[1])
      ok(list[1]:set_todo("DONE"))
      eq("* DONE Project [2/2]", disk(p)[1])
    end)

    it("several entries with the handle's ID are an error", function()
      local p = write(dir, "calls.org", CALLS)
      local ha = api.find_by_id("call-a")
      local lines = disk(p)
      vim.list_extend(lines, { "* TODO Call (copy)", "  :PROPERTIES:", "  :ID:       call-a", "  :END:" })
      table.insert(lines, 1, "")
      utils.writefile(p, lines)
      local res, err = ha:set_todo("DONE")
      eq(nil, res)
      ok(err:match("several entries have the ID call%-a"), err)
      -- a handle that follows its line still knows which one it is
      local h = api.headlines({ files = p, title = "Call (copy)" })[1]
      ok(h:set_todo("DONE"))
      eq("* DONE Call (copy)", disk(p)[10])
    end)

    it("deletes the marks of handles that were collected", function()
      local p = write(dir, "many.org", { "* a", "* b", "* c" })
      local b = open_file(p)
      local ns = vim.api.nvim_get_namespaces()["org.api.headlines"]
      for _ = 1, 10 do
        api.headlines({ files = p })
      end
      ok(#vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, {}) > 3)
      collectgarbage("collect")
      collectgarbage("collect")
      local kept = api.headlines({ files = p })
      eq(3, #vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, {}))
      ok(kept[3]:set_todo("TODO"))
      eq("* TODO c", buf_lines(b)[3])
    end)

    it("an archived handle stays gone", function()
      local p = write(dir, "reviews.org", REVIEWS)
      local h = api.headlines({ files = p, title = "Weekly review" })[1]
      ok(h:archive())
      local res, err = h:set_todo("TODO")
      eq(nil, res)
      ok(err:match("not found"), err)
      ok(not text(p):find("TODO", 1, true))
    end)
  end)

  describe("tags", function()
    it("add_tag and remove_tag keep tags added since the handle was made", function()
      local p = write(dir, "ids.org", {
        "* TODO Plan offsite :travel:",
        "  :PROPERTIES:",
        "  :ID:       offsite",
        "  :END:",
      })
      local h = api.find_by_id("offsite")
      -- tags added in the file after the handle was made
      local lines = disk(p)
      lines[1] = "* TODO Plan offsite :travel:urgent:"
      utils.writefile(p, lines)
      ok(h:add_tag("b"))
      eq({ "travel", "urgent", "b" }, h.tags)
      eq("* TODO Plan offsite :travel:urgent:b:", squash(disk(p)[1]))
      -- two handles of one entry
      local h1, h2 = api.find_by_id("offsite"), api.find_by_id("offsite")
      ok(h1:add_tag("c"))
      ok(h2:add_tag("d"))
      eq("* TODO Plan offsite :travel:urgent:b:c:d:", squash(disk(p)[1]))
      ok(h1:remove_tag("b"))
      ok(h2:remove_tag("travel"))
      eq("* TODO Plan offsite :urgent:c:d:", squash(disk(p)[1]))
      -- adding a tag it has, removing one it hasn't: no change
      ok(h1:add_tag("c"))
      ok(h1:remove_tag("nope"))
      eq("* TODO Plan offsite :urgent:c:d:", squash(disk(p)[1]))
    end)

    it("add_tag keeps tags set with C-c C-q in a loaded buffer", function()
      local b = open_file(work)
      local h = head("Plan offsite")
      require("org.tags").set_tags({ bufnr = b, lnum = 2 }, { "travel", "urgent" })
      vim.cmd("silent write")
      ok(h:add_tag("b"))
      eq("** TODO Plan offsite :travel:urgent:b:", squash(disk(work)[2]))
    end)

    it("rejects tag names org can't read back", function()
      local h = head("Plan offsite")
      for _, bad in ipairs({ "follow-up", "two words", "", "a:b", "x.y", "a—b", "😀", "x\255" }) do
        local res, err = h:add_tag(bad)
        eq(nil, res, bad)
        ok(err and err:match("invalid tag"), bad .. ": " .. tostring(err))
      end
      local res, err = h:set_tags({ "ok", "not-ok" })
      eq(nil, res)
      ok(err:match("not%-ok"), err)
      res, err = h:set_tags(":fine:bad-one:")
      eq(nil, res)
      ok(err:match("bad%-one"), err)
      res, err = h:remove_tag("follow-up")
      eq(nil, res)
      ok(err:match("invalid tag"), err)
      res, err = h:set_tags({ "ok", 42 })
      eq(nil, res)
      ok(err:match("invalid tag"), err)
      eq(WORK, disk(work))
      -- letters and digits of any script, _ @ # %
      ok(h:set_tags({ "café", "日本", "x_1", "@home", "#n", "50%" }))
      eq({ "café", "日本", "x_1", "@home", "#n", "50%" }, api.load(work).headlines[2].tags)
    end)
  end)

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
