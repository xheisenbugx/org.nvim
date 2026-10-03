-- Picker integrations (org.pickers): the sources, backend selection, the
-- vim.ui.select fallback, and each adapter against a fake of the plugin's
-- API (none of snacks.nvim, fzf-lua, telescope.nvim or mini.pick is
-- installed in the test run).
local utils = require("org.utils")

local dir
local saved_fns, saved_mods, saved_globals = {}, {}, {}

local function stub(tbl, key, value)
  saved_fns[#saved_fns + 1] = { tbl, key, tbl[key] }
  tbl[key] = value
end

--- Put a fake module on package.loaded (restored after the test).
local function fake_module(name, mod)
  if saved_mods[name] == nil then
    saved_mods[name] = { package.loaded[name] }
  end
  package.loaded[name] = mod
end

local function fake_global(name, value)
  if saved_globals[name] == nil then
    saved_globals[name] = { rawget(_G, name) }
  end
  rawset(_G, name, value)
end

local function write(rel, lines)
  local path = dir .. "/" .. rel
  utils.writefile(path, lines)
  return path
end

local function today_stamp()
  return os.date("<%Y-%m-%d %a>")
end

--- Wait for the scheduled answer of a picker.
local function settle()
  vim.wait(200, function()
    return false
  end)
end

local function texts(items)
  return vim.tbl_map(require("org.pickers").line, items)
end

describe("pickers", function()
  local a_path, b_path
  before_each(function()
    dir = utils.realpath(vim.fn.tempname()) or vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = utils.realpath(dir)
    a_path = write("a.org", {
      "#+TAGS: work home",
      "* Projects :work:",
      "** TODO [#A] Write report :urgent:",
      "   SCHEDULED: " .. today_stamp(),
      "** DONE Old thing",
      "* Notes",
    })
    b_path = write("b.org", {
      "* TODO Call mom :home:",
      "* Ideas",
    })
    local opts = require("org.config").opts
    stub(opts, "agenda_files", { dir .. "/*.org" })
    stub(opts, "picker", "auto")
    stub(vim.g, "lazyvim_picker", nil)
  end)
  after_each(function()
    for i = #saved_fns, 1, -1 do
      local s = saved_fns[i]
      s[1][s[2]] = s[3]
    end
    for name, v in pairs(saved_mods) do
      package.loaded[name] = v[1]
    end
    for name, v in pairs(saved_globals) do
      rawset(_G, name, v[1])
    end
    saved_fns, saved_mods, saved_globals = {}, {}, {}
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
  end)

  describe("sources", function()
    it("lists the headlines of a file with path, TODO, priority and tags", function()
      local sources = require("org.pickers.sources")
      local items = sources.headline_items({ require("org.files").get(a_path) })
      eq({
        "Projects  :work:",
        "Projects › TODO [#A] Write report  :urgent:",
        "Projects › DONE Old thing",
        "Notes",
      }, texts(items))
      local it = items[2]
      eq(a_path, it.filename)
      eq(3, it.lnum)
      eq("Write report", it.value:plain_title())
      eq({
        { "Projects › ", "Comment" },
        { "TODO", "OrgTodo" },
        { " " },
        { "[#A]", "OrgPriority" },
        { " " },
        { "Write report", nil },
        { "  :urgent:", "OrgTags" },
      }, it.display)
      eq({ "DONE", "OrgDone" }, items[3].display[2])
      eq("OrgHeadlineDone", items[3].display[4][2])
    end)

    it("puts the file name first for the agenda files", function()
      local sources = require("org.pickers.sources")
      local items = sources.headline_items(require("org.files").agenda_files(), { file = true })
      ok(vim.tbl_contains(texts(items), "b.org TODO Call mom  :home:"), vim.inspect(texts(items)))
      eq({ "a.org", "Directory" }, items[1].display[1])
    end)

    it("uses the todo_keyword_faces group of a keyword", function()
      local ui = require("org.config").opts.ui
      stub(ui, "todo_keyword_faces", { TODO = ":foreground red" })
      eq("orgTodoKw_TODO", require("org.pickers.sources").todo_group("TODO", false))
    end)

    it("counts the headlines of each tag, with definitions and FILETAGS", function()
      local f = write("c.org", { "#+FILETAGS: :proj:", "* X :work:" })
      local files = require("org.files")
      local list = require("org.pickers.sources").tag_list({ files.get(a_path), files.get(b_path), files.get(f) })
      eq({
        { name = "home", count = 1 },
        { name = "proj", count = 0 },
        { name = "urgent", count = 1 },
        { name = "work", count = 2 },
      }, list)
      local items = require("org.pickers.sources").tag_items(list, { work = true })
      eq({ "  home  (1)", "  proj  (0)", "  urgent  (1)", "✓ work  (2)" }, texts(items))
      eq("work", items[4].value)
    end)

    it("toggles chosen tags and adds typed ones", function()
      local toggle = require("org.pickers.sources").toggle_tags
      eq({ "b", "c" }, toggle({ "a", "b" }, { "a", "c" }))
      eq({ "a", "x", "y" }, toggle({ "a" }, {}, "x:y"))
      eq({ "a" }, toggle({ "a" }, {}, "a"))
    end)

    it("lists today's agenda and the TODO list", function()
      local sources = require("org.pickers.sources")
      local today = require("org.date").today_days()
      local items = sources.agenda_items(today, today)
      eq(1, #items)
      ok(texts(items)[1]:find("Scheduled: a: TODO [#A] Write report  :urgent:", 1, true), texts(items)[1])
      eq(a_path, items[1].filename)
      eq(3, items[1].lnum)
      -- a span of several days shows the day first
      local week = sources.agenda_items(today, today + 6)
      eq(require("org.date").from_days(today):strftime("%a %d %b") .. " ", week[1].display[1][1])
      local todo = texts(sources.todo_items())
      table.sort(todo)
      eq({ "a: TODO [#A] Write report  :urgent:", "b: TODO Call mom  :home:" }, todo)
    end)

    it("lists the capture templates by key", function()
      local capture = require("org.config").opts.capture
      stub(capture, "templates", {
        t = { description = "Task", template = "* TODO %?" },
        n = { description = "Note", template = "* %?" },
      })
      local items = require("org.pickers.sources").capture_template_items()
      eq({ "n  Note", "t  Task" }, texts(items))
      eq("n", items[1].value.key)
    end)
  end)

  describe("backend", function()
    it("falls back to vim.ui.select with no picker installed", function()
      eq("select", require("org.pickers").backend())
      eq(false, require("org.pickers").available("snacks"))
    end)

    it("detects installed pickers at call time, in order", function()
      local pickers = require("org.pickers")
      fake_global("MiniPick", { start = function() end })
      eq("mini", pickers.backend())
      fake_module("telescope.pickers", {})
      eq("telescope", pickers.backend())
      fake_module("fzf-lua", { fzf_exec = function() end })
      eq("fzf-lua", pickers.backend())
      fake_module("snacks", { picker = { pick = function() end } })
      eq("snacks", pickers.backend())
      -- LazyVim's choice first
      stub(vim.g, "lazyvim_picker", "fzf")
      eq("fzf-lua", pickers.backend())
    end)

    it("honours the picker option, and warns when it isn't installed", function()
      local pickers = require("org.pickers")
      fake_module("fzf-lua", { fzf_exec = function() end })
      fake_global("MiniPick", { start = function() end })
      stub(require("org.config").opts, "picker", "mini")
      eq("mini", pickers.backend())
      local warned
      stub(utils, "warn", function(msg)
        warned = msg
      end)
      eq("select", pickers.backend("telescope"))
      ok(warned and warned:find("telescope", 1, true), warned)
    end)
  end)

  describe("vim.ui.select fallback", function()
    it("jumps to the chosen headline of the file", function()
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      local shown
      stub(vim.ui, "select", function(items, o, cb)
        shown = vim.tbl_map(o.format_item, items)
        eq("org_picker", o.kind)
        cb(items[4])
      end)
      require("org.actions").run("pick_headline")
      settle()
      eq(
        { "Projects  :work:", "Projects › TODO [#A] Write report  :urgent:", "Projects › DONE Old thing", "Notes" },
        shown
      )
      eq(6, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("opens the file of a headline of the agenda files", function()
      stub(vim.ui, "select", function(items, o, cb)
        for _, it in ipairs(items) do
          if o.format_item(it):find("Call mom", 1, true) then
            return cb(it)
          end
        end
      end)
      require("org.actions").run("pick_headline_all")
      settle()
      eq(b_path, vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
      eq(1, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("picks a tag, then a headline with it (inherited too)", function()
      local calls = 0
      local second
      stub(vim.ui, "select", function(items, o, cb)
        calls = calls + 1
        if calls == 1 then
          for _, it in ipairs(items) do
            if o.format_item(it):match("^work") then
              return cb(it)
            end
          end
        else
          second = vim.tbl_map(o.format_item, items)
          return cb(items[2])
        end
      end)
      require("org.actions").run("pick_tag")
      settle()
      settle()
      eq({
        "a.org Projects  :work:",
        "a.org Projects › TODO [#A] Write report  :urgent:",
        "a.org Projects › DONE Old thing",
      }, second)
      eq(a_path, vim.fs.normalize(vim.api.nvim_buf_get_name(0)))
      eq(3, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("toggles a tag of the headline, or adds a typed one", function()
      local buf = org_buffer({ "#+TAGS: work home", "* Task :work:" }, { 2, 0 })
      local labels
      stub(vim.ui, "select", function(items, o, cb)
        labels = vim.tbl_map(o.format_item, items)
        cb(items[2]) -- home
      end)
      require("org.actions").run("pick_set_tags")
      settle()
      eq({ "+ New tags…", "  home", "✓ work" }, labels)
      ok(buf_lines(buf)[2]:match("^%* Task%s+:work:home:$"), buf_lines(buf)[2])
      -- "+ New tags…" asks for them
      stub(vim.ui, "select", function(items, _, cb)
        cb(items[1])
      end)
      stub(utils, "input", function(o)
        eq("New tags: ", o.prompt)
        return "x:y"
      end)
      require("org.actions").run("pick_set_tags")
      settle()
      ok(buf_lines(buf)[2]:match(":work:home:x:y:$"), buf_lines(buf)[2])
      -- choosing a tag the headline has removes it
      stub(vim.ui, "select", function(items, o, cb)
        for _, it in ipairs(items) do
          if o.format_item(it) == "✓ work" then
            return cb(it)
          end
        end
      end)
      require("org.actions").run("pick_set_tags")
      settle()
      ok(buf_lines(buf)[2]:match("^%* Task%s+:home:x:y:$"), buf_lines(buf)[2])
    end)

    it("calls on_cancel when nothing is chosen", function()
      stub(vim.ui, "select", function(_, _, cb)
        cb(nil)
      end)
      local cancelled, chosen = false, false
      require("org.pickers").pick({
        title = "X",
        items = { { display = { { "a" } } } },
        on_choice = function()
          chosen = true
        end,
        on_cancel = function()
          cancelled = true
        end,
      })
      settle()
      eq(true, cancelled)
      eq(false, chosen)
    end)

    it("warns instead of opening an empty picker", function()
      local warned
      stub(utils, "warn", function(msg)
        warned = msg
      end)
      stub(vim.ui, "select", function()
        error("should not open")
      end)
      eq(nil, require("org.pickers").pick({ title = "Nothing", items = {}, on_choice = function() end }))
      ok(warned:find("Nothing", 1, true))
    end)

    it("waits for the choice inside a coroutine (choose)", function()
      stub(vim.ui, "select", function(items, _, cb)
        vim.schedule(function()
          cb(items[2])
        end)
      end)
      local got
      utils.run(function()
        got = require("org.pickers").choose({
          title = "X",
          items = { { display = { { "a" } } }, { display = { { "b" } }, value = 2 } },
        })
      end)
      vim.wait(500, function()
        return got ~= nil
      end)
      eq(2, got[1].value)
    end)
  end)

  describe("snacks.nvim adapter", function()
    local captured
    before_each(function()
      captured = nil
      fake_global("Snacks", nil)
      fake_module("snacks", {
        picker = {
          pick = function(o)
            captured = o
            return {}
          end,
        },
      })
      stub(require("org.config").opts, "picker", "snacks")
    end)

    --- A fake snacks picker: `selected` items, the typed `pattern`.
    local function fake_picker(selected, pattern)
      local p = { input = { filter = { pattern = pattern or "" } }, closed = false }
      function p:selected(o)
        eq({ fallback = true }, o)
        return selected
      end
      function p:close()
        self.closed = true
        captured.on_close(self)
      end
      return p
    end

    it("passes items with file, pos and highlighted chunks", function()
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      require("org.actions").run("pick_headline")
      eq("Headlines", captured.title)
      eq("file", captured.preview)
      eq(4, #captured.items)
      local it = captured.items[2]
      eq("Projects › TODO [#A] Write report  :urgent:", it.text)
      eq(a_path, it.file)
      eq({ 3, 0 }, it.pos)
      eq({ "TODO", "OrgTodo" }, captured.format(it, {})[2])
      eq("function", type(captured.actions.confirm))
      -- confirm jumps (once the picker has closed)
      local p = fake_picker({})
      captured.actions.confirm(p, captured.items[4])
      eq(true, p.closed)
      settle()
      eq(6, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("returns the multi-selection and the query, and cancels on close", function()
      local got, query, cancelled
      local spec = {
        title = "T",
        multi = true,
        allow_query = true,
        items = { { display = { { "a" } }, value = 1 }, { display = { { "b" } }, value = 2 } },
        on_choice = function(items, q)
          got, query = items, q
        end,
        on_cancel = function()
          cancelled = true
        end,
      }
      require("org.pickers").pick(spec)
      eq("none", captured.preview)
      eq({ preset = "select" }, captured.layout)
      captured.actions.confirm(fake_picker({ captured.items[1], captured.items[2] }, "zz"), captured.items[1])
      settle()
      eq(
        { 1, 2 },
        vim.tbl_map(function(i)
          return i.value
        end, got)
      )
      eq("zz", query)
      -- nothing matched: the query alone
      require("org.pickers").pick(spec)
      captured.actions.confirm(fake_picker({}, "new tag"), nil)
      settle()
      eq({}, got)
      eq("new tag", query)
      -- closed without a choice
      require("org.pickers").pick(spec)
      fake_picker({}):close()
      settle()
      eq(true, cancelled)
    end)
  end)

  describe("fzf-lua adapter", function()
    local entries, opts
    before_each(function()
      entries, opts = nil, nil
      fake_module("fzf-lua", {
        fzf_exec = function(e, o)
          entries, opts = e, o
        end,
      })
      fake_module("fzf-lua.utils", {
        ansi_from_hl = function(hl, s)
          return "<" .. hl .. ">" .. s .. "</>", "x"
        end,
      })
      -- the builtin previewer class, as fzf-lua's Object:extend()
      local base = {}
      base.__index = base
      function base:extend()
        local cls = {}
        for k, v in pairs(self) do
          if k:find("__") == 1 then
            cls[k] = v
          end
        end
        cls.__index = cls
        cls.super = self
        return setmetatable(cls, self)
      end
      function base:new(o, op)
        self.o, self.opts = o, op
        return self
      end
      fake_module("fzf-lua.previewer.builtin", { buffer_or_file = setmetatable({}, base) })
      stub(require("org.config").opts, "picker", "fzf-lua")
    end)

    it("sends indexed ANSI entries and maps the choice back", function()
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      require("org.actions").run("pick_headline")
      eq(4, #entries)
      eq(
        "2\t<Comment>Projects › </><OrgTodo>TODO</> <OrgPriority>[#A]</> Write report<OrgTags>  :urgent:</>",
        entries[2]
      )
      eq("Headlines> ", opts.prompt)
      eq({
        ["--ansi"] = true,
        ["--delimiter"] = "\t",
        ["--with-nth"] = "2..",
        ["--multi"] = false,
        ["--no-multi"] = true,
      }, opts.fzf_opts)
      -- the previewer reads the file and line from the entry
      local P = opts.previewer
      ok(P and P.new and P.parse_entry, "a previewer class")
      local prev = P:new({}, opts)
      local e = prev:parse_entry(entries[3])
      eq(a_path, e.path)
      eq(5, e.line)
      opts.actions.enter({ entries[4] }, { last_query = "no" })
      settle()
      eq(6, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("previews the buffer of the item's own file, not one whose name it matches", function()
      local work = write("work.org", { "* Work" })
      local archive = write("work.org_archive", { "* Archived" })
      local ab = vim.fn.bufadd(archive)
      vim.fn.bufload(ab)
      require("org.pickers").pick({
        title = "T",
        items = { { display = { { "Work" } }, filename = work, lnum = 1 } },
        on_choice = function() end,
      })
      local prev = opts.previewer:new({}, opts)
      local e = prev:parse_entry(entries[1])
      eq(work, e.path)
      -- work.org isn't loaded: the file, not work.org_archive's buffer
      eq(nil, e.bufnr)
      vim.cmd("edit " .. vim.fn.fnameescape(work))
      eq(vim.api.nvim_get_current_buf(), prev:parse_entry(entries[1]).bufnr)
    end)

    it("supports multi-select, a bare query and cancelling", function()
      local got, query, cancelled
      local spec = {
        title = "T",
        multi = true,
        allow_query = true,
        items = { { display = { { "a" } }, value = 1 }, { display = { { "b", "Comment" } }, value = 2 } },
        on_choice = function(items, q)
          got, query = items, q
        end,
        on_cancel = function()
          cancelled = true
        end,
      }
      require("org.pickers").pick(spec)
      eq(true, opts.fzf_opts["--multi"])
      eq(nil, opts.previewer)
      opts.actions.enter({ entries[1], entries[2] }, { last_query = "" })
      settle()
      eq(
        { 1, 2 },
        vim.tbl_map(function(i)
          return i.value
        end, got)
      )
      require("org.pickers").pick(spec)
      opts.actions.enter({}, { last_query = "brand new" })
      settle()
      eq({}, got)
      eq("brand new", query)
      require("org.pickers").pick(spec)
      opts.actions.esc({}, {})
      settle()
      eq(true, cancelled)
    end)
  end)

  describe("telescope adapter", function()
    local conf, select_fn, closed, multi, selected, line
    before_each(function()
      conf, select_fn, closed = nil, nil, nil
      multi, selected, line = {}, nil, ""
      fake_module("telescope.pickers", {
        new = function(o, c)
          conf = c
          c.topts = o
          return {
            find = function()
              c.prompt_bufnr = vim.api.nvim_create_buf(false, true)
              eq(true, c.attach_mappings(c.prompt_bufnr, function() end))
            end,
          }
        end,
      })
      fake_module("telescope.finders", {
        new_table = function(t)
          return t
        end,
      })
      fake_module("telescope.config", {
        values = {
          generic_sorter = function()
            return "sorter"
          end,
          grep_previewer = function()
            return "grep_previewer"
          end,
        },
      })
      fake_module("telescope.actions", {
        select_default = {
          replace = function(_, fn)
            select_fn = fn
          end,
        },
        close = function(bufnr)
          closed = bufnr
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end,
      })
      fake_module("telescope.actions.state", {
        get_current_picker = function()
          return {
            get_multi_selection = function()
              return multi
            end,
          }
        end,
        get_selected_entry = function()
          return selected
        end,
        get_current_line = function()
          return line
        end,
      })
      stub(require("org.config").opts, "picker", "telescope")
    end)

    it("builds entries with display highlights and jumps on select", function()
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      require("org.actions").run("pick_headline")
      eq("Headlines", conf.prompt_title)
      eq("sorter", conf.sorter)
      eq("grep_previewer", conf.previewer)
      local entry = conf.finder.entry_maker(conf.finder.results[2])
      eq("Projects › TODO [#A] Write report  :urgent:", entry.ordinal)
      eq(a_path, entry.filename)
      eq(3, entry.lnum)
      local text, hls = entry.display(entry)
      eq(entry.ordinal, text)
      local p = #"Projects › "
      eq({
        { { 0, p }, "Comment" },
        { { p, p + 4 }, "OrgTodo" },
        { { p + 5, p + 9 }, "OrgPriority" },
        { { p + 22, #text }, "OrgTags" },
      }, hls)
      selected = conf.finder.entry_maker(conf.finder.results[4])
      select_fn()
      eq(conf.prompt_bufnr, closed)
      settle()
      eq(6, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("returns the multi-selection, a bare query, or cancels when wiped", function()
      local got, query, cancelled
      local spec = {
        title = "T",
        multi = true,
        allow_query = true,
        query = "start",
        items = { { display = { { "a" } }, value = 1 }, { display = { { "b" } }, value = 2 } },
        on_choice = function(items, q)
          got, query = items, q
        end,
        on_cancel = function()
          cancelled = true
        end,
      }
      require("org.pickers").pick(spec)
      eq("start", conf.default_text)
      eq(nil, conf.previewer)
      multi = { conf.finder.entry_maker(spec.items[1]), conf.finder.entry_maker(spec.items[2]) }
      select_fn()
      settle()
      eq(
        { 1, 2 },
        vim.tbl_map(function(i)
          return i.value
        end, got)
      )
      multi, selected, line = {}, nil, " typed "
      require("org.pickers").pick(spec)
      select_fn()
      settle()
      eq({}, got)
      eq("typed", query)
      require("org.pickers").pick(spec)
      vim.api.nvim_buf_delete(conf.prompt_bufnr, { force = true })
      settle()
      eq(true, cancelled)
    end)

    it("registers a telescope extension using the telescope picker", function()
      stub(require("org.config").opts, "picker", "select")
      fake_module("telescope", {
        register_extension = function(ext)
          return ext
        end,
      })
      package.loaded["telescope._extensions.org"] = nil
      local ext = require("telescope._extensions.org")
      package.loaded["telescope._extensions.org"] = nil
      for _, name in ipairs({ "org", "headlines", "headlines_all", "tags", "agenda", "todo", "capture_templates" }) do
        eq("function", type(ext.exports[name]), name)
      end
      ext.exports.headlines_all()
      eq("Agenda headlines", conf.prompt_title)
    end)
  end)

  describe("mini.pick adapter", function()
    local started, behaviour
    before_each(function()
      started, behaviour = nil, nil
      fake_global("MiniPick", {
        start = function(o)
          started = o
          return behaviour and behaviour(o.source)
        end,
        default_show = function(buf, items)
          vim.api.nvim_buf_set_lines(
            buf,
            0,
            -1,
            false,
            vim.tbl_map(function(x)
              return x.text
            end, items)
          )
        end,
        default_preview = function(buf, item)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "preview of " .. item.path .. ":" .. item.lnum })
        end,
        get_picker_query = function()
          return { "n", "e", "w" }
        end,
      })
      stub(require("org.config").opts, "picker", "mini")
    end)

    it("passes path/lnum items, highlights them and jumps on choose", function()
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      behaviour = function(source)
        source.choose(source.items[4])
        return source.items[4]
      end
      require("org.actions").run("pick_headline")
      eq("Headlines", started.source.name)
      local it = started.source.items[2]
      eq("Projects › TODO [#A] Write report  :urgent:", it.text)
      eq(a_path, it.path)
      eq(3, it.lnum)
      -- show adds the chunks' highlights
      local buf = vim.api.nvim_create_buf(false, true)
      started.source.show(buf, { it }, {})
      local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
      local groups = vim.tbl_map(function(m)
        return m[4].hl_group
      end, marks)
      eq({ "Comment", "OrgTodo", "OrgPriority", "OrgTags" }, groups)
      started.source.preview(buf, it)
      eq({ "preview of " .. a_path .. ":3" }, buf_lines(buf))
      settle()
      eq(6, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("chooses marked items, takes the query from + New, and cancels", function()
      local got, query, cancelled
      local spec = {
        title = "T",
        multi = true,
        allow_query = true,
        create_label = "+ New thing",
        items = { { display = { { "a" } }, value = 1 }, { display = { { "b" } }, value = 2 } },
        on_choice = function(items, q)
          got, query = items, q
        end,
        on_cancel = function()
          cancelled = true
        end,
      }
      behaviour = function(source)
        eq("+ New thing", source.items[1].text)
        source.choose_marked({ source.items[2], source.items[3] })
      end
      require("org.pickers").pick(spec)
      settle()
      eq(
        { 1, 2 },
        vim.tbl_map(function(i)
          return i.value
        end, got)
      )
      behaviour = function(source)
        source.choose(source.items[1])
      end
      require("org.pickers").pick(spec)
      settle()
      eq({}, got)
      eq("new", query)
      behaviour = nil
      require("org.pickers").pick(spec)
      settle()
      eq(true, cancelled)
    end)
  end)

  describe("roam nodes", function()
    local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
    local roam_dir
    before_each(function()
      roam_dir = dir .. "/roam"
      vim.fn.mkdir(roam_dir, "p")
      utils.writefile(roam_dir .. "/apple.org", { ":PROPERTIES:", ":ID: apple-id", ":END:", "#+title: Apple" })
    end)
    after_each(function()
      require("org").setup({
        org_directory = root .. "/tests/fixtures",
        agenda_files = { root .. "/tests/fixtures/*.org" },
      })
    end)

    local function setup(picker)
      require("org").setup({
        org_directory = root .. "/tests/fixtures",
        agenda_files = { dir .. "/*.org" },
        extensions = { roam = { directory = roam_dir, index_file = dir .. "/roam-index.json", picker = picker } },
      })
      require("org.extensions.roam.db").reset()
    end

    it("reads a node with the configured picker, with a preview", function()
      local entries, opts
      fake_module("fzf-lua", {
        fzf_exec = function(e, o)
          entries, opts = e, o
          vim.schedule(function()
            o.actions.enter({ e[1] }, { last_query = "" })
          end)
        end,
      })
      setup("fzf-lua")
      local node = require("org.extensions.roam.node")
      eq("fzf-lua", node.picker())
      local c
      utils.run(function()
        c = node.read({ prompt = "Find node", default_title = "App" })
      end)
      vim.wait(500, function()
        return c ~= nil
      end)
      eq("apple-id", c.node.id)
      eq("1\tApple", entries[1])
      eq("Find node> ", opts.prompt)
      eq("App", opts.query)
    end)

    it("creates a node from a query that matches nothing", function()
      fake_module("fzf-lua", {
        fzf_exec = function(_, o)
          vim.schedule(function()
            o.actions.enter({}, { last_query = "Durian" })
          end)
        end,
      })
      setup("auto")
      eq("fzf-lua", require("org.extensions.roam.node").picker())
      local c
      utils.run(function()
        c = require("org.extensions.roam.node").read({})
      end)
      vim.wait(500, function()
        return c ~= nil
      end)
      eq({ title = "Durian" }, c)
    end)

    it("keeps snacks for auto when snacks is loaded", function()
      fake_module("fzf-lua", { fzf_exec = function() end })
      fake_global("Snacks", { picker = { pick = function() end } })
      setup("auto")
      eq("snacks", require("org.extensions.roam.node").picker())
      stub(require("org.config").opts, "picker", "fzf-lua")
      eq("fzf-lua", require("org.extensions.roam.node").picker())
    end)
  end)
end)
