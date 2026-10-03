-- OrgTagsChanged (org-after-tags-change-hook) and OrgRefile
-- (org-after-refile-insert-hook): every path that changes tags fires,
-- once per change, and handlers that edit the buffer don't make the
-- command lose track of its headlines.
local api = require("org.api")
local config = require("org.config")
local tags = require("org.tags")
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
    todo_keywords = { "TODO", "WAIT", "|", "DONE" },
    id = { locations_file = dir .. "/ids.json" },
    tags_column = 0,
  }, extra or {}))
  require("org.id")._reset()
end

local function write(dir, name, lines)
  local p = dir .. "/" .. name
  utils.writefile(p, lines)
  return p
end

--- Edit `path` in the current window; returns its buffer.
local function open_file(path)
  vim.cmd("enew!")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

--- Collect the data of every `event` until the test ends; `fn(data)` runs
--- for each, as a handler.
local listeners = {}
local function listen(event, fn)
  local got = {}
  listeners[#listeners + 1] = api.on(event, function(data)
    got[#got + 1] = data
    if fn then
      fn(data, #got)
    end
  end)
  return got
end

--- { lnum, from, to } of each OrgTagsChanged event.
local function changes(events)
  return vim.tbl_map(function(d)
    return { d.lnum, d.from, d.to }
  end, events)
end

--- Run `fn` with module fields replaced: { { module, name, value }, ... }.
local function with_stubs(stubs, fn)
  local saved = {}
  for _, s in ipairs(stubs) do
    saved[#saved + 1] = { s[1], s[2], s[1][s[2]] }
    s[1][s[2]] = s[3]
  end
  local ok_, err = pcall(fn)
  for _, s in ipairs(saved) do
    s[1][s[2]] = s[3]
  end
  if not ok_ then
    error(err, 0)
  end
end

describe("org.api events", function()
  local dir

  before_each(function()
    dir = tmpdir()
    setup(dir)
  end)

  after_each(function()
    for _, id in ipairs(listeners) do
      api.off(id)
    end
    listeners = {}
    pcall(function()
      require("org.agenda.view").quit(true)
    end)
    config.setup({})
  end)

  describe("OrgTagsChanged", function()
    it("follows the region's headlines when a handler moves them", function()
      local buf = org_buffer({ "* A", "* B :b:", "text", "text", "* C :c:" }, { 1, 0 })
      local events = listen("OrgTagsChanged", function(data)
        local h = api.headline_at({ bufnr = data.bufnr, lnum = data.lnum })
        ok(h:set_property("TAGS_CHANGED", "today"))
      end)
      eq(3, tags.change_tag_in_region(buf, 1, 5, "add", "y"))
      local drawer = { ":PROPERTIES:", ":TAGS_CHANGED: today", ":END:" }
      eq(
        vim.iter({ "* A :y:", drawer, "* B :b:y:", drawer, "text", "text", "* C :c:y:", drawer }):flatten():totable(),
        buf_lines(buf)
      )
      eq({ { 1, {}, { "y" } }, { 5, { "b" }, { "b", "y" } }, { 11, { "c" }, { "c", "y" } } }, changes(events))
    end)

    it("reads the tags a handler changed before changing them", function()
      local buf = org_buffer({ "* A", "* B :b:" }, { 1, 0 })
      -- a handler that tags the next headline too
      local events = listen("OrgTagsChanged", function(data)
        if data.lnum == 1 then
          tags.toggle_tag({ bufnr = data.bufnr, lnum = 2 }, "z")
        end
      end)
      eq(2, tags.change_tag_in_region(buf, 1, 2, "add", "y"))
      eq({ "* A :y:", "* B :b:z:y:" }, buf_lines(buf))
      eq({ { 1, {}, { "y" } }, { 2, { "b" }, { "b", "z" } }, { 2, { "b", "z" }, { "b", "z", "y" } } }, changes(events))
    end)

    it("fires once per change from set_tags, toggle_tag and the region command", function()
      local buf = org_buffer({ "* A :a:", "* B" }, { 1, 0 })
      local events = listen("OrgTagsChanged")
      tags.set_tags(nil, { "a", "x" })
      tags.toggle_tag({ bufnr = buf, lnum = 2 }, "x")
      tags.set_tags(nil, { "a", "x" })
      eq(1, tags.change_tag_in_region(buf, 1, 2, "remove", "a"))
      eq({ "* A :x:", "* B :x:" }, buf_lines(buf))
      eq({
        { 1, { "a" }, { "a", "x" } },
        { 2, {}, { "x" } },
        { 1, { "a", "x" }, { "x" } },
      }, changes(events))
    end)

    it("fires for todo_state_tags_triggers, once per tag turned on or off", function()
      config.opts.todo_state_tags_triggers =
        { WAIT = { waiting = true }, done = { hold = false, waiting = false }, [""] = { waiting = false } }
      local buf = org_buffer({ "#+TODO: TODO WAIT | DONE(!)", "* Other", "* TODO Task :work:hold:" }, { 3, 0 })
      local events = listen("OrgTagsChanged", function(_, n)
        if n == 2 then
          -- a handler that moves the entry: what follows the tags lands
          -- on it all the same
          vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "#+TITLE: Moved" })
        end
      end)
      local todo = require("org.todo")
      ok(todo.change_state(nil, "WAIT"))
      eq({ { 3, { "work", "hold" }, { "work", "hold", "waiting" } } }, changes(events))
      local res = todo.change_state({ bufnr = buf, lnum = 3 }, "DONE")
      eq(4, res.lnum)
      local l = buf_lines(buf)
      eq({ "#+TITLE: Moved", "* Other", "* DONE Task :work:" }, vim.list_slice(l, 2, 4))
      ok(l[5]:match('^%- State "DONE"%s+from "WAIT"'), l[5])
      eq({
        { 3, { "work", "hold" }, { "work", "hold", "waiting" } },
        { 3, { "work", "hold", "waiting" }, { "work", "waiting" } },
        { 4, { "work", "waiting" }, { "work" } },
      }, changes(events))
    end)

    it("C-c C-q keeps to its headline when a TODO key's tag trigger moves it", function()
      config.opts.todo_state_tags_triggers = { WAIT = { waiting = true } }
      config.opts.fast_tag_selection_include_todo = true
      local buf = org_buffer(
        { "#+TODO: TODO(t) WAIT(w) | DONE(d)", "#+TAGS: x(x)", "* Other", "* TODO Task" },
        { 4, 0 }
      )
      local events = listen("OrgTagsChanged", function(_, n)
        if n == 1 then
          vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "#+TITLE: Moved" })
        end
      end)
      -- WAIT by its key in the tag menu, then the tag x
      local keys = { "w", "x", "\r" }
      with_stubs({
        {
          utils,
          "getchar",
          function()
            return table.remove(keys, 1)
          end,
        },
      }, function()
        tags.set_tags()
      end)
      eq({ "#+TITLE: Moved", "* Other", "* WAIT Task :x:" }, vim.list_slice(buf_lines(buf), 3, 5))
      eq({ { 4, {}, { "waiting" } }, { 5, { "waiting" }, { "x" } } }, changes(events))
    end)

    it("fires for the ARCHIVE tag, and for the archive sibling it creates", function()
      local archive = require("org.archive")
      local buf = org_buffer({ "* P", "** A :x:", "** B" }, { 2, 0 })
      local events = listen("OrgTagsChanged")
      ok(archive.toggle_archive_tag({ bufnr = buf, lnum = 2 }))
      eq("** A :x:ARCHIVE:", buf_lines(buf)[2])
      eq(false, archive.toggle_archive_tag({ bufnr = buf, lnum = 2 }))
      eq({ { 2, { "x" }, { "x", "ARCHIVE" } }, { 2, { "x", "ARCHIVE" }, { "x" } } }, changes(events))
      -- the sibling gets its tag like org-toggle-tag gives it (Emacs runs
      -- the hook there too)
      archive.archive_to_sibling({ bufnr = buf, lnum = 3 })
      eq("** Archive :ARCHIVE:", buf_lines(buf)[3])
      eq({ 4, {}, { "ARCHIVE" } }, changes(events)[3])
      eq(3, #events)
    end)

    it("fires in the archive file for the inherited tags of an archived entry", function()
      config.opts.archive_subtree_add_inherited_tags = true
      local path = write(dir, "work.org", { "* P :p:", "** Entry :own:" })
      local buf = open_file(path)
      local events = listen("OrgTagsChanged")
      ok(require("org.archive").archive_subtree({ bufnr = buf, lnum = 2 }))
      eq(1, #events)
      ok(events[1].file:match("work%.org_archive$"), events[1].file)
      eq({ "own" }, events[1].from)
      eq({ "p", "own" }, events[1].to)
      local abuf = utils.find_buffer(path .. "_archive")
      eq("* Entry :p:own:", vim.api.nvim_buf_get_lines(abuf, 0, -1, false)[events[1].lnum])
    end)

    it("fires for the ORDERED tag", function()
      config.opts.track_ordered_property_with_tag = true
      local buf = org_buffer({ "* H :x:" }, { 1, 0 })
      local events = listen("OrgTagsChanged")
      require("org.properties").toggle_ordered()
      require("org.properties").toggle_ordered()
      eq({ "* H :x:" }, buf_lines(buf))
      eq({ { 1, { "x" }, { "x", "ORDERED" } }, { 1, { "x", "ORDERED" }, { "x" } } }, changes(events))
    end)

    it("fires for the ATTACH tag", function()
      local buf = open_file(write(dir, "a.org", { "* Task", ":PROPERTIES:", ":ID: abcdef", ":END:" }))
      utils.writefile(dir .. "/c.txt", { "c" })
      local events = listen("OrgTagsChanged")
      ok(require("org.attach").attach_file(dir .. "/c.txt", "cp", { bufnr = buf, lnum = 1 }))
      eq("* Task :ATTACH:", buf_lines(buf)[1])
      eq({ { 1, {}, { "ATTACH" } } }, changes(events))
    end)

    it("fires for agenda bulk tag changes", function()
      local path = write(dir, "a.org", { "* TODO One", "* TODO Two :x:" })
      setup(dir, { agenda_files = { path } })
      local view = require("org.agenda.view")
      require("org.agenda").open_todo()
      view.actions.mark_all()
      local events = listen("OrgTagsChanged")
      with_stubs({
        {
          require("org.ui"),
          "menu",
          function()
            return "+"
          end,
        },
        {
          utils,
          "input_complete",
          function()
            return "y"
          end,
        },
      }, function()
        view.actions.bulk_action()
      end)
      eq({ "* TODO One :y:", "* TODO Two :x:y:" }, vim.api.nvim_buf_get_lines(utils.find_buffer(path), 0, -1, false))
      table.sort(events, function(a, b)
        return a.lnum < b.lnum
      end)
      eq({ { 1, {}, { "y" } }, { 2, { "x" }, { "x", "y" } } }, changes(events))
    end)

    it("fires for a TAGS edit in the agenda column view", function()
      local path = write(dir, "a.org", { "#+COLUMNS: %25ITEM %TAGS", "* TODO One :x:" })
      setup(dir, { agenda_files = { path } })
      local view = require("org.agenda.view")
      local cols = require("org.agenda.columns")
      require("org.agenda").open_todo()
      cols.apply()
      local l
      for ln, it in pairs(view.state.line_items) do
        if it.title == "One" then
          l = ln
        end
      end
      -- the TAGS column, after ITEM and its separator
      local ns = vim.api.nvim_create_namespace("org.agenda.columns")
      local m = vim.api.nvim_buf_get_extmarks(0, ns, { l - 1, 0 }, { l - 1, -1 }, { details = true })[1]
      vim.api.nvim_win_set_cursor(0, { l, vim.fn.strdisplaywidth(m[4].virt_text[1][1]:match("^(.-| )")) })
      local events = listen("OrgTagsChanged")
      with_stubs({
        {
          utils,
          "input",
          function()
            return ":x:y:"
          end,
        },
      }, function()
        cols.edit()
      end)
      eq("* TODO One :x:y:", vim.api.nvim_buf_get_lines(utils.find_buffer(path), 0, -1, false)[2])
      eq({ { 2, { "x" }, { "x", "y" } } }, changes(events))
      cols.quit()
    end)
  end)

  describe("OrgRefile", function()
    local LINES = {
      "* Inbox",
      "** TODO Entry",
      "* Projects",
      ":PROPERTIES:",
      ":COUNT: 0",
      ":END:",
      "** TODO Existing",
    }

    it("returns and remembers the entry a handler moved, and the API follows it", function()
      local path = write(dir, "work.org", LINES)
      local refile = require("org.refile")
      local during
      local events = listen("OrgRefile", function(data)
        -- Emacs sets the last-refile bookmark before it runs the hook
        during = vim.deepcopy(refile.last_stored)
        -- a handler that adds a property line above the entry
        local parent = api.headline_at({ bufnr = data.bufnr, lnum = data.lnum }):parent()
        ok(parent:set_property("LAST", "Entry"))
      end)
      local h = api.headlines({ files = path, title = "Entry" })[1]
      local dest = api.headlines({ files = path, title = "Projects" })[1]
      ok(h:refile(dest))
      eq(1, #events)
      eq(7, events[1].lnum)
      eq({ 7, "** TODO Entry" }, { during.lnum, during.raw })
      local lines = utils.readfile(path)
      eq("** TODO Entry", lines[8])
      eq("** TODO Existing", lines[7])
      -- the handle, the bookmark and the last stored location are on the entry
      eq({ "Entry", 8 }, { h.title, h.line })
      eq({ 8, "** TODO Entry" }, { refile.last_stored.lnum, refile.last_stored.raw })
      ok(h:set_todo("DONE"))
      lines = utils.readfile(path)
      eq("** DONE Entry", lines[8])
      eq("** TODO Existing", lines[7])
    end)

    it("returns the entry's line after the handler ran", function()
      local buf = org_buffer(LINES, { 2, 0 })
      listen("OrgRefile", function(data)
        vim.api.nvim_buf_set_lines(data.bufnr, 0, 0, false, { "#+TITLE: Work" })
      end)
      local refile = require("org.refile")
      local dbuf, dline = refile.refile(
        { bufnr = buf, lnum = 2 },
        { dest = { bufnr = buf, lnum = 3, label = "Projects" } }
      )
      eq(buf, dbuf)
      eq("** TODO Entry", buf_lines(buf)[dline])
      eq(8, dline)
      eq(8, refile.last_stored.lnum)
    end)

    it("saves a hidden destination with the handler's edits", function()
      local src = write(dir, "src.org", { "* TODO Entry" })
      local dest = write(dir, "dest.org", { "* Projects" })
      local sbuf = open_file(src)
      listen("OrgRefile", function(data)
        -- an edit that doesn't save the buffer itself
        ok(require("org.properties").set_property({ bufnr = data.bufnr, lnum = data.lnum }, "REFILED", "yes"))
      end)
      local dbuf = require("org.refile").refile(
        { bufnr = sbuf, lnum = 1 },
        { dest = { filename = dest, lnum = 1, label = "Projects" } }
      )
      eq(-1, vim.fn.bufwinid(dbuf))
      eq({ "* Projects", "** TODO Entry", ":PROPERTIES:", ":REFILED:  yes", ":END:" }, utils.readfile(dest))
      eq(false, vim.bo[dbuf].modified)
    end)
  end)
end)
