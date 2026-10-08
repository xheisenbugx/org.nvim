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

--- A spec of items a (1) and b (2) logging its answers in `events`:
--- "choice <value>", "cancel".
local function recorder(events)
  return {
    title = "T",
    items = { { display = { { "a" } }, value = 1 }, { display = { { "b" } }, value = 2 } },
    on_choice = function(items)
      events[#events + 1] = "choice " .. items[1].value
    end,
    on_cancel = function()
      events[#events + 1] = "cancel"
    end,
  }
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

    it("sorts the TODO list like the TODO view, timestamp strategies too", function()
      local date = require("org.date")
      local function stamp(n)
        return "<" .. date.today():add(n, "d"):to_string({ brackets = false }) .. ">"
      end
      write("c.org", {
        "* TODO Later",
        "  SCHEDULED: " .. stamp(5),
        "* TODO Sooner",
        "  SCHEDULED: " .. stamp(1),
      })
      stub(require("org.config").opts.agenda, "sorting", { todo = { "scheduled-up" } })
      local titles = vim.tbl_map(function(it)
        return it.value.title
      end, require("org.pickers.sources").todo_items())
      eq({ "Write report", "Sooner", "Later", "Call mom" }, titles)
      -- the order of the TODO view
      local view = require("org.agenda.view")
      require("org.agenda").open_todo()
      local shown = {}
      for l = 1, vim.api.nvim_buf_line_count(0) do
        local it = view.state.line_items[l]
        if it then
          shown[#shown + 1] = it.title
        end
      end
      view.quit(true)
      eq(shown, titles)
    end)

    it("warns about an invalid sorting strategy and keeps the file order", function()
      local warned
      stub(utils, "warn", function(msg)
        warned = msg
      end)
      local agenda = require("org.config").opts.agenda
      local function titles()
        return vim.tbl_map(function(it)
          return it.value.title
        end, require("org.pickers.sources").todo_items())
      end
      stub(agenda, "sorting", { todo = { "bogus-up" } })
      eq({ "Write report", "Call mom" }, titles())
      ok(warned and warned:find("bogus-up", 1, true), warned)
      -- fails only when sorting
      warned = nil
      stub(agenda, "sorting", { todo = { "user-defined-up" } })
      stub(agenda, "cmp_user_defined", nil)
      eq({ "Write report", "Call mom" }, titles())
      ok(warned and warned:find("cmp_user_defined", 1, true), warned)
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

    it("takes the picker of LazyVim's picker extra when lazyvim_picker is auto", function()
      local pickers = require("org.pickers")
      fake_module("snacks", { picker = { pick = function() end } })
      fake_module("fzf-lua", { fzf_exec = function() end })
      fake_module("telescope.pickers", {})
      -- LazyVim sets vim.g.lazyvim_picker = "auto"; the extra enabled with
      -- :LazyExtras registers its picker in LazyVim.pick
      stub(vim.g, "lazyvim_picker", "auto")
      fake_global("LazyVim", { pick = { picker = { name = "fzf" } } })
      eq("fzf-lua", pickers.backend())
      fake_global("LazyVim", { pick = { picker = { name = "telescope" } } })
      eq("telescope", pickers.backend())
      -- none registered: the first installed
      fake_global("LazyVim", { pick = {} })
      eq("snacks", pickers.backend())
      -- set in the config, it wins
      fake_global("LazyVim", { pick = { picker = { name = "telescope" } } })
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

    it("captures with the agenda's date from the agenda (use_agenda_date)", function()
      local date = require("org.date")
      local tomorrow = date.today():add(1, "d")
      write("c.org", { "* TODO Meeting", "  SCHEDULED: <" .. tomorrow:to_string({ brackets = false }) .. ">" })
      local config = require("org.config")
      stub(config.opts.capture, "templates", { t = { description = "Task", template = "* TODO %?" } })
      stub(config.opts.capture, "use_agenda_date", true)
      local captured
      stub(require("org.capture"), "capture", function(tpl, o)
        captured = { key = tpl.key, opts = o }
      end)
      stub(vim.ui, "select", function(items, _, cb)
        cb(items[1])
      end)
      local view = require("org.agenda.view")
      require("org.agenda").open_agenda({ span = 3, anchor = date.today_days() })
      for l, it in pairs(view.state.line_items) do
        if it.title:match("Meeting") then
          vim.api.nvim_win_set_cursor(0, { l, 0 })
        end
      end
      require("org.actions").run("pick_capture_template")
      settle()
      view.quit(true)
      eq("t", captured.key)
      eq(tomorrow:days(), captured.opts.date:days())
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

  --- The quickfix list: its title and `file:lnum:col text` entries.
  local function qf()
    local info = vim.fn.getqflist({ title = 1, items = 1 })
    return {
      title = info.title,
      items = vim.tbl_map(function(e)
        local name = e.bufnr > 0 and vim.fn.fnamemodify(vim.api.nvim_buf_get_name(e.bufnr), ":t") or ""
        return string.format("%s:%d:%d %s", name, e.lnum, e.col, e.text)
      end, info.items),
    }
  end

  --- Whether a quickfix window is open in this tab page.
  local function qf_open()
    return vim.fn.getqflist({ winid = 1 }).winid ~= 0
  end

  describe("quickfix list", function()
    after_each(function()
      vim.fn.setqflist({}, "f")
      vim.cmd("silent! cclose | silent! tabonly | silent! only")
    end)

    it("puts several chosen places in the quickfix list, titled after the picker", function()
      local events = {}
      stub(vim.ui, "select", function(items, _, cb)
        events[#events + 1] = #items
        cb(items[1])
      end)
      local items = require("org.pickers.sources").headline_items(require("org.files").agenda_files(), { file = true })
      eq(6, #items)
      require("org.pickers").go({ items[2], items[5] }, nil, "Agenda headlines")
      eq({
        title = "Agenda headlines",
        items = {
          "a.org:3:1 a.org Projects › TODO [#A] Write report  :urgent:",
          "b.org:1:1 b.org TODO Call mom  :home:",
        },
      }, qf())
      ok(qf_open(), "the quickfix window is open")
    end)

    it("takes a buffer without a file, and the item's column", function()
      local buf = org_buffer({ "* First", "* Second" }, { 1, 0 })
      require("org.pickers").qflist({
        { display = { { "Second" } }, bufnr = buf, lnum = 2, col = 3 },
        { display = { { "nowhere" } } },
      }, "T")
      local info = vim.fn.getqflist({ items = 1 })
      eq(1, #info.items)
      eq({ buf, 2, 3, "Second" }, { info.items[1].bufnr, info.items[1].lnum, info.items[1].col, info.items[1].text })
    end)

    it("jumps to one place, and opens several in windows of their own with split, vsplit, tab", function()
      local items = require("org.pickers.sources").headline_items(require("org.files").agenda_files(), { file = true })
      require("org.pickers").go({ items[2] })
      eq({ a_path, 3 }, { vim.api.nvim_buf_get_name(0), vim.api.nvim_win_get_cursor(0)[1] })
      eq(false, qf_open())
      require("org.pickers").go({ items[2], items[5] }, "vsplit")
      eq(3, #vim.api.nvim_tabpage_list_wins(0))
      eq({ b_path, 1 }, { vim.api.nvim_buf_get_name(0), vim.api.nvim_win_get_cursor(0)[1] })
      eq(false, qf_open())
      require("org.pickers").go({ items[2] }, "qflist", "T")
      eq(1, #qf().items)
    end)

    it("lets the place pickers choose several, the others one", function()
      local specs = {}
      stub(require("org.pickers"), "pick", function(spec)
        specs[#specs + 1] = spec
      end)
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      local sources = require("org.pickers.sources")
      sources.headlines()
      sources.todo()
      sources.agenda_file()
      sources.capture_template()
      eq({ true, true, true }, { specs[1].multi, specs[2].multi, specs[3].multi })
      eq(nil, specs[4].multi)
      -- several chosen go to the quickfix list, titled after the picker
      specs[2].on_choice({ specs[2].items[1], specs[2].items[2] })
      eq("TODO", qf().title)
      eq(2, #qf().items)
    end)
  end)

  describe("snacks.nvim adapter", function()
    local captured, previewed
    before_each(function()
      captured, previewed = nil, nil
      fake_global("Snacks", nil)
      fake_module("snacks", {
        picker = {
          pick = function(o)
            captured = o
            return {}
          end,
          preview = {
            -- the file previewer: the item's `buf` when set, else its `file`
            file = function(ctx)
              previewed = { buf = ctx.item.buf, file = ctx.item.file, pos = ctx.item.pos }
            end,
          },
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
      eq(4, #captured.items)
      local it = captured.items[2]
      eq("Projects › TODO [#A] Write report  :urgent:", it.text)
      eq(a_path, it.file)
      eq({ 3, 0 }, it.pos)
      captured.preview({ item = it })
      eq({ buf = vim.api.nvim_get_current_buf(), file = a_path, pos = { 3, 0 } }, previewed)
      eq({ "TODO", "OrgTodo" }, captured.format(it, {})[2])
      eq("function", type(captured.actions.confirm))
      -- confirm jumps (once the picker has closed); several can be selected
      local p = fake_picker({ captured.items[4] })
      captured.actions.confirm(p, captured.items[4])
      eq(true, p.closed)
      settle()
      eq(6, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("binds the picker_keys to split, vsplit and tab actions", function()
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      require("org.actions").run("pick_headline")
      eq({ "org_split", mode = { "n", "i" } }, captured.win.input.keys["<C-s>"])
      eq("org_vsplit", captured.win.list.keys["<C-v>"])
      eq("org_tab", captured.win.list.keys["<C-t>"])
      eq("org_qflist", captured.win.list.keys["<C-q>"])
      local p = fake_picker({ captured.items[4] })
      captured.actions.org_split(p, captured.items[4])
      eq(true, p.closed)
      settle()
      eq(2, #vim.api.nvim_tabpage_list_wins(0))
      eq(6, vim.api.nvim_win_get_cursor(0)[1])
      vim.cmd("silent! only")
      require("org.actions").run("pick_tag")
      eq({}, captured.win.input.keys)
      eq(nil, captured.actions.org_split)
    end)

    it("merges picker_opts over its own options, keeping its handlers", function()
      local user_closed = 0
      stub(require("org.config").opts, "picker_opts", {
        snacks = {
          layout = { preset = "ivy" },
          title = "Mine",
          on_close = function()
            user_closed = user_closed + 1
          end,
          items = {},
        },
      })
      local events = {}
      require("org.pickers").pick(recorder(events))
      eq({ preset = "ivy" }, captured.layout)
      eq("Mine", captured.title)
      eq(2, #captured.items)
      fake_picker({}):close()
      settle()
      eq(1, user_closed)
      eq({ "cancel" }, events)
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

    it("previews the buffer of a loaded file, with its unsaved edits", function()
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "* Inserted", "" })
      require("org.actions").run("pick_headline_all")
      local checked = 0
      for _, it in ipairs(captured.items) do
        if it.text:find("Write report", 1, true) then
          captured.preview({ item = it })
          eq(buf, previewed.buf)
          eq("** TODO [#A] Write report :urgent:", vim.api.nvim_buf_get_lines(buf, it.pos[1] - 1, it.pos[1], false)[1])
          checked = checked + 1
        elseif it.text:find("Call mom", 1, true) then
          -- b.org isn't loaded: its file
          captured.preview({ item = it })
          eq({ file = b_path, pos = { 1, 0 } }, previewed)
          checked = checked + 1
        end
      end
      eq(2, checked)
    end)

    it("sends the selection with <CR>, or every match with the qflist key, to the quickfix list", function()
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      require("org.actions").run("pick_headline_all")
      local p = fake_picker({ captured.items[2], captured.items[5] })
      -- snacks passes its action third
      captured.actions.confirm(p, captured.items[2], { name = "confirm" })
      eq(true, p.closed)
      settle()
      eq("Agenda headlines", qf().title)
      eq(2, #qf().items)
      ok(qf_open(), "the quickfix window is open")
      vim.cmd("cclose")
      -- the qflist key: every item matching the query, not the selection
      require("org.actions").run("pick_headline_all")
      p = fake_picker({ captured.items[1] })
      function p:items()
        return { captured.items[3], captured.items[4], captured.items[6] }
      end
      captured.actions.org_qflist(p, captured.items[1])
      settle()
      eq(
        { "a.org:5:1 a.org Projects › DONE Old thing", "a.org:6:1 a.org Notes", "b.org:2:1 b.org Ideas" },
        qf().items
      )
      vim.cmd("cclose")
      vim.fn.setqflist({}, "f")
    end)

    it("answers again when resumed", function()
      local events = {}
      require("org.pickers").pick(recorder(events))
      local opts = captured
      fake_picker({}):close()
      settle()
      eq({ "cancel" }, events)
      -- Snacks.picker.resume() opens a new picker with the same options
      local p = fake_picker({})
      opts.actions.confirm(p, opts.items[2])
      settle()
      eq({ "cancel", "choice 2" }, events)
      eq(true, p.closed)
      -- a resumed picker closed without a choice doesn't cancel again
      fake_picker({}):close()
      settle()
      eq({ "cancel", "choice 2" }, events)
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
        ["--multi"] = true,
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

    it("opens the place in a split, vsplit or tab with the picker_keys", function()
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      require("org.actions").run("pick_headline")
      local keys = vim.tbl_keys(opts.actions)
      table.sort(keys)
      eq({ "ctrl-q", "ctrl-s", "ctrl-t", "ctrl-v", "enter" }, keys)
      opts.actions["ctrl-v"]({ entries[4] }, {})
      settle()
      eq(2, #vim.api.nvim_tabpage_list_wins(0))
      eq(6, vim.api.nvim_win_get_cursor(0)[1])
      eq(a_path, vim.api.nvim_buf_get_name(0))
      require("org.actions").run("pick_headline")
      opts.actions["ctrl-t"]({ entries[2] }, {})
      settle()
      eq(2, #vim.api.nvim_list_tabpages())
      eq(3, vim.api.nvim_win_get_cursor(0)[1])
      vim.cmd("silent! tabonly | silent! only")
      -- other pickers choose with enter only
      require("org.actions").run("pick_tag")
      eq({ "enter" }, vim.tbl_keys(opts.actions))
    end)

    it("takes the picker_keys in Vim's notation, false turning one off", function()
      local fzf = require("org.pickers.backends.fzf_lua")
      eq("ctrl-s", fzf.fzf_key("<C-s>"))
      eq("alt-x", fzf.fzf_key("<M-x>"))
      eq("alt-x", fzf.fzf_key("<A-x>"))
      eq("enter", fzf.fzf_key("<CR>"))
      eq("f2", fzf.fzf_key("<F2>"))
      eq("ctrl-o", fzf.fzf_key("ctrl-o"))
      stub(require("org.config").opts, "picker_keys", { split = "<M-s>", vsplit = false, tab = "<C-t>" })
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      require("org.actions").run("pick_headline")
      local keys = vim.tbl_keys(opts.actions)
      table.sort(keys)
      eq({ "alt-s", "ctrl-t", "enter" }, keys)
      opts.actions["alt-s"]({ entries[4] }, {})
      settle()
      eq(2, #vim.api.nvim_tabpage_list_wins(0))
      vim.cmd("silent! only")
    end)

    it("merges picker_opts over its own options, keeping its handlers", function()
      local user_closed = 0
      stub(require("org.config").opts, "picker_opts", {
        ["fzf-lua"] = {
          prompt = "Org> ",
          winopts = {
            height = 0.4,
            on_close = function()
              user_closed = user_closed + 1
            end,
          },
          fzf_opts = { ["--layout"] = "reverse", ["--delimiter"] = "x" },
          actions = { ["ctrl-x"] = function() end },
        },
      })
      local events = {}
      require("org.pickers").pick(recorder(events))
      eq("Org> ", opts.prompt)
      eq(0.4, opts.winopts.height)
      eq(" T ", opts.winopts.title)
      eq("reverse", opts.fzf_opts["--layout"])
      -- the entries need org's delimiter and actions
      eq("\t", opts.fzf_opts["--delimiter"])
      eq({ "enter" }, vim.tbl_keys(opts.actions))
      opts.winopts.on_close()
      settle()
      eq(1, user_closed)
      eq({ "cancel" }, events)
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
      opts.winopts.on_close()
      settle()
      eq(true, cancelled)
    end)

    it("cancels once whichever key closes it", function()
      local events = {}
      -- esc, ctrl-c, ctrl-q, ctrl-z, ctrl-g, ...: fzf-lua closes its window
      -- and runs none of our actions
      require("org.pickers").pick(recorder(events))
      opts.winopts.on_close()
      settle()
      eq({ "cancel" }, events)
      -- enter: the window closes, then the action runs
      events = {}
      require("org.pickers").pick(recorder(events))
      opts.winopts.on_close()
      opts.actions.enter({ entries[2] }, { last_query = "" })
      settle()
      eq({ "choice 2" }, events)
      -- choose() returns (roam's node finder waits for it)
      local returned = false
      utils.run(function()
        returned = require("org.pickers").choose(recorder({})) == nil
      end)
      opts.winopts.on_close()
      vim.wait(500, function()
        return returned
      end)
      eq(true, returned)
    end)

    it("sends the selection with enter, or every match with ctrl-q, to the quickfix list", function()
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      require("org.actions").run("pick_headline")
      opts.actions.enter({ entries[2], entries[4] }, { last_query = "" })
      settle()
      eq("Headlines", vim.fn.getqflist({ title = 1 }).title)
      eq(2, #qf().items)
      vim.cmd("cclose")
      -- ctrl-q selects every match first, then runs the action
      require("org.actions").run("pick_headline")
      local q = opts.actions["ctrl-q"]
      eq("select-all", q.prefix)
      q.fn({ entries[1], entries[3] }, { last_query = "o" })
      settle()
      eq({ "a.org:2:1 Projects  :work:", "a.org:5:1 Projects › DONE Old thing" }, qf().items)
      vim.cmd("cclose")
      vim.fn.setqflist({}, "f")
    end)

    it("answers again when resumed", function()
      local events = {}
      require("org.pickers").pick(recorder(events))
      opts.winopts.on_close()
      settle()
      -- FzfLua.resume() runs fzf again with the same options
      opts.winopts.on_close()
      opts.actions.enter({ entries[2] }, { last_query = "" })
      settle()
      eq({ "cancel", "choice 2" }, events)
    end)
  end)

  describe("telescope adapter", function()
    local conf, select_fn, closed, multi, selected, line, mapped, replaced
    before_each(function()
      conf, select_fn, closed = nil, nil, nil
      multi, selected, line, mapped, replaced = {}, nil, "", {}, {}
      fake_module("telescope.pickers", {
        new = function(o, c)
          conf = c
          c.topts = o
          return {
            find = function()
              c.prompt_bufnr = vim.api.nvim_create_buf(false, true)
              eq(
                true,
                c.attach_mappings(c.prompt_bufnr, function(mode, lhs, fn)
                  mapped[lhs] = { mode = mode, fn = fn }
                end)
              )
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
          -- reads the file into the preview buffer
          buffer_previewer_maker = function(path, bufnr, o)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.fn.readfile(path))
            o.callback(bufnr)
          end,
        },
      })
      fake_module("telescope.previewers", {
        new_buffer_previewer = function(o)
          return o
        end,
      })
      fake_module("telescope.previewers.utils", { highlighter = function() end })
      fake_module("telescope.actions", {
        select_default = {
          replace = function(_, fn)
            select_fn = fn
          end,
        },
        select_horizontal = {
          replace = function(_, fn)
            replaced.select_horizontal = fn
          end,
        },
        select_vertical = {
          replace = function(_, fn)
            replaced.select_vertical = fn
          end,
        },
        select_tab = {
          replace = function(_, fn)
            replaced.select_tab = fn
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

    --- What the previewer shows for an item: the preview buffer's lines and
    --- the line of its window's cursor.
    local function preview(item)
      local pbuf = vim.api.nvim_create_buf(false, true)
      local pwin = vim.api.nvim_open_win(pbuf, false, { relative = "editor", row = 0, col = 0, width = 30, height = 3 })
      local self = { state = { bufnr = pbuf, winid = pwin } }
      conf.previewer.define_preview(self, conf.finder.entry_maker(item), {})
      settle()
      local lines, lnum = buf_lines(pbuf), vim.api.nvim_win_get_cursor(pwin)[1]
      vim.api.nvim_win_close(pwin, true)
      return lines, lnum
    end

    it("builds entries with display highlights and jumps on select", function()
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      require("org.actions").run("pick_headline")
      eq("Headlines", conf.prompt_title)
      eq("sorter", conf.sorter)
      local lines, lnum = preview(conf.finder.results[2])
      eq(utils.readfile(a_path), lines)
      eq(3, lnum)
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

    it("maps the picker_keys, and telescope's own split keys, to split, vsplit and tab", function()
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      require("org.actions").run("pick_headline")
      eq({ "i", "n" }, mapped["<C-s>"].mode)
      eq(
        { "<C-q>", "<C-s>", "<C-t>", "<C-v>" },
        (function()
          local keys = vim.tbl_keys(mapped)
          table.sort(keys)
          return keys
        end)()
      )
      selected = conf.finder.entry_maker(conf.finder.results[4])
      mapped["<C-s>"].fn()
      settle()
      eq(2, #vim.api.nvim_tabpage_list_wins(0))
      eq(6, vim.api.nvim_win_get_cursor(0)[1])
      vim.cmd("silent! only")
      require("org.actions").run("pick_headline")
      selected = conf.finder.entry_maker(conf.finder.results[2])
      replaced.select_tab()
      settle()
      eq(2, #vim.api.nvim_list_tabpages())
      eq(3, vim.api.nvim_win_get_cursor(0)[1])
      vim.cmd("silent! tabonly")
    end)

    it("passes picker_opts, and :Telescope org's options over them", function()
      stub(require("org.config").opts, "picker_opts", {
        telescope = { layout_strategy = "vertical", layout_config = { width = 0.5 } },
      })
      require("org.pickers").pick(recorder({}))
      eq({ layout_strategy = "vertical", layout_config = { width = 0.5 } }, conf.topts)
      eq({}, mapped)
      package.loaded["telescope"] = {
        register_extension = function(ext)
          return ext
        end,
      }
      package.loaded["telescope._extensions.org"] = nil
      local ext = require("telescope._extensions.org")
      package.loaded["telescope._extensions.org"] = nil
      package.loaded["telescope"] = nil
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      ext.exports.headlines({ layout_config = { height = 0.3 } })
      settle()
      eq({ layout_strategy = "vertical", layout_config = { width = 0.5, height = 0.3 } }, conf.topts)
    end)

    it("previews an entry of a buffer without a file", function()
      org_buffer({ "* First", "* Second" }, { 1, 0 })
      require("org.actions").run("pick_headline")
      local lines, lnum = preview(conf.finder.results[2])
      eq({ "* First", "* Second" }, lines)
      eq(2, lnum)
    end)

    it("previews the buffer of a loaded file, with its unsaved edits", function()
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      vim.api.nvim_buf_set_lines(0, 0, 0, false, { "* Inserted", "" })
      local want = buf_lines(0)
      require("org.actions").run("pick_headline")
      local lines, lnum = preview(conf.finder.results[3])
      eq(want, lines)
      eq("** TODO [#A] Write report :urgent:", lines[lnum])
    end)

    it("shows the line of the last entry when an earlier read ends later", function()
      -- a.org isn't loaded: its entries preview the file
      require("org.actions").run("pick_headline_all")
      eq(a_path, conf.finder.results[3].filename)
      -- the first read is slow; the second entry reuses its buffer, still empty
      local reads = {}
      stub(require("telescope.config").values, "buffer_previewer_maker", function(path, bufnr, o)
        reads[#reads + 1] = function()
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.fn.readfile(path))
          o.callback(bufnr)
        end
      end)
      local pbuf = vim.api.nvim_create_buf(false, true)
      local pwin = vim.api.nvim_open_win(pbuf, false, { relative = "editor", row = 0, col = 0, width = 30, height = 3 })
      local self = { state = { bufnr = pbuf, winid = pwin } }
      conf.previewer.define_preview(self, conf.finder.entry_maker(conf.finder.results[1]), {})
      conf.previewer.define_preview(self, conf.finder.entry_maker(conf.finder.results[3]), {})
      reads[2]()
      reads[1]()
      eq(5, vim.api.nvim_win_get_cursor(pwin)[1])
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

    it("sends the selection with <CR>, every match with <C-q>, the selection with <M-q>", function()
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      replaced.send_to_qflist, replaced.send_selected_to_qflist = nil, nil
      local manager = {}
      fake_module(
        "telescope.actions.state",
        vim.tbl_extend("force", require("telescope.actions.state"), {
          get_current_picker = function()
            return {
              get_multi_selection = function()
                return multi
              end,
              manager = {
                iter = function()
                  local i = 0
                  return function()
                    i = i + 1
                    return manager[i]
                  end
                end,
              },
            }
          end,
        })
      )
      local acts = require("telescope.actions")
      for _, name in ipairs({ "send_to_qflist", "send_selected_to_qflist" }) do
        acts[name] = {
          replace = function(_, fn)
            replaced[name] = fn
          end,
        }
      end
      require("org.actions").run("pick_headline")
      local e = function(i)
        return conf.finder.entry_maker(conf.finder.results[i])
      end
      multi = { e(1), e(4) }
      select_fn()
      settle()
      eq({ "a.org:2:1 Projects  :work:", "a.org:6:1 Notes" }, qf().items)
      vim.cmd("cclose")
      -- <C-q>: every match
      require("org.actions").run("pick_headline")
      manager = { e(2), e(3) }
      mapped["<C-q>"].fn()
      settle()
      eq(
        { "a.org:3:1 Projects › TODO [#A] Write report  :urgent:", "a.org:5:1 Projects › DONE Old thing" },
        qf().items
      )
      vim.cmd("cclose")
      -- telescope's own send_to_qflist and send_selected_to_qflist
      require("org.actions").run("pick_headline")
      manager = { e(4) }
      replaced.send_to_qflist()
      settle()
      eq({ "a.org:6:1 Notes" }, qf().items)
      vim.cmd("cclose")
      require("org.actions").run("pick_headline")
      multi, selected = {}, e(1)
      replaced.send_selected_to_qflist()
      settle()
      -- one entry still goes to the quickfix list
      eq({ "a.org:2:1 Projects  :work:" }, qf().items)
      vim.cmd("cclose")
      vim.fn.setqflist({}, "f")
    end)

    it("answers again when resumed", function()
      local events = {}
      require("org.pickers").pick(recorder(events))
      vim.api.nvim_buf_delete(conf.prompt_bufnr, { force = true })
      settle()
      eq({ "cancel" }, events)
      -- builtin.resume() makes a picker of the cached one: a new prompt
      -- buffer, attach_mappings again
      local prompt = vim.api.nvim_create_buf(false, true)
      eq(true, conf.attach_mappings(prompt, function() end))
      selected = conf.finder.entry_maker(conf.finder.results[2])
      select_fn()
      settle()
      eq({ "cancel", "choice 2" }, events)
      eq(prompt, closed)
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
    local started, behaviour, typed
    before_each(function()
      started, behaviour, typed = nil, nil, { "n", "e", "w" }
      fake_global("MiniPick", {
        start = function(o)
          started = o
          -- items may be a function, called once the picker is active
          if type(o.source.items) == "function" then
            o.source.items = o.source.items()
          end
          return behaviour and behaviour(o.source)
        end,
        -- the indexes of `inds` whose text contains the query; nil when
        -- interrupted by a newer query ("!" here)
        default_match = function(stritems, inds, query, opts)
          eq(true, opts.sync)
          local q = table.concat(query)
          if q == "!" then
            return nil
          end
          return vim.tbl_filter(function(i)
            return stritems[i]:find(q, 1, true) ~= nil
          end, inds)
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
        -- a buffer when the item has one, else its path
        default_preview = function(buf, item)
          local what = item.bufnr and ("buffer " .. item.bufnr) or item.path
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "preview of " .. what .. ":" .. item.lnum })
        end,
        get_picker_query = function()
          return typed
        end,
        set_picker_query = function(q)
          typed = q
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
      settle()
      eq(6, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("maps the picker_keys over its own split keys", function()
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      local current
      stub(rawget(_G, "MiniPick"), "get_picker_matches", function()
        return { current = current }
      end)
      behaviour = function(source)
        current = source.items[4]
        return started.mappings.org_vsplit.func()
      end
      require("org.actions").run("pick_headline")
      eq("", started.mappings.choose_in_split)
      eq("", started.mappings.choose_in_vsplit)
      eq("", started.mappings.choose_in_tabpage)
      eq("<C-s>", started.mappings.org_split.char)
      eq("<C-t>", started.mappings.org_tab.char)
      settle()
      eq(2, #vim.api.nvim_tabpage_list_wins(0))
      eq(6, vim.api.nvim_win_get_cursor(0)[1])
      vim.cmd("silent! only")
      -- other pickers keep mini.pick's keys
      behaviour = nil
      require("org.actions").run("pick_tag")
      eq({}, started.mappings)
    end)

    it("merges picker_opts under its own source", function()
      stub(require("org.config").opts, "picker_opts", {
        mini = { window = { config = { width = 50 } }, source = { name = "Mine", cwd = "/" } },
      })
      require("org.pickers").pick(recorder({}))
      eq({ config = { width = 50 } }, started.window)
      eq("T", started.source.name)
      eq("/", started.source.cwd)
    end)

    it("previews the buffer of a loaded file, with its unsaved edits", function()
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      local abuf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(abuf, 0, 0, false, { "* Inserted", "" })
      require("org.actions").run("pick_headline_all")
      local buf = vim.api.nvim_create_buf(false, true)
      local checked = 0
      for _, it in ipairs(started.source.items) do
        if it.text:find("Write report", 1, true) then
          started.source.preview(buf, it)
          eq({ "preview of buffer " .. abuf .. ":5" }, buf_lines(buf))
          eq("** TODO [#A] Write report :urgent:", vim.api.nvim_buf_get_lines(abuf, 4, 5, false)[1])
          checked = checked + 1
        elseif it.text:find("Call mom", 1, true) then
          -- b.org isn't loaded: its file
          started.source.preview(buf, it)
          eq({ "preview of " .. b_path .. ":1" }, buf_lines(buf))
          checked = checked + 1
        end
      end
      eq(2, checked)
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

    it("sends marked items, or every match with the qflist key, to the quickfix list", function()
      vim.cmd("edit " .. vim.fn.fnameescape(a_path))
      behaviour = function(source)
        source.choose_marked({ source.items[1], source.items[4] })
      end
      require("org.actions").run("pick_headline")
      settle()
      eq({ "a.org:2:1 Projects  :work:", "a.org:6:1 Notes" }, qf().items)
      vim.cmd("cclose")
      local all
      stub(rawget(_G, "MiniPick"), "get_picker_matches", function()
        return { current = all[1], all = all }
      end)
      behaviour = function(source)
        all = { source.items[2], source.items[3] }
        return started.mappings.org_qflist.func()
      end
      require("org.actions").run("pick_headline")
      eq("<C-q>", started.mappings.org_qflist.char)
      settle()
      eq(
        { "a.org:3:1 Projects › TODO [#A] Write report  :urgent:", "a.org:5:1 Projects › DONE Old thing" },
        qf().items
      )
      vim.cmd("cclose")
      vim.fn.setqflist({}, "f")
    end)

    it("answers again when resumed", function()
      local events = {}
      require("org.pickers").pick(recorder(events))
      settle()
      eq({ "cancel" }, events)
      -- MiniPick.builtin.resume() runs the same source again
      started.source.choose(started.source.items[2])
      settle()
      eq({ "cancel", "choice 2" }, events)
    end)

    it("keeps + New listed below the matches, with the typed text", function()
      local got, query
      behaviour = function(source)
        local stritems = vim.tbl_map(function(x)
          return x.text
        end, source.items)
        eq({ "+ New tags…", "news", "work" }, stritems)
        local all = { 1, 2, 3 }
        -- nothing typed: + New first, then every entry
        eq(all, source.match(stritems, all, {}))
        -- the matches, then + New
        eq({ 3, 1 }, source.match(stritems, all, { "w", "o" }))
        -- not matched by its own label, and listed when nothing matches
        eq({ 1 }, source.match(stritems, all, { "N", "e", "w" }))
        eq({ 1 }, source.match(stritems, { 1 }, { "D", "u", "r" }))
        -- an interrupted match updates nothing
        eq(nil, source.match(stritems, all, { "!" }))
        -- it shows the text it takes
        local buf = vim.api.nvim_create_buf(false, true)
        source.show(buf, { source.items[1], source.items[2] }, { "D", "u", "r" })
        eq({ "+ New tags: Dur", "news" }, buf_lines(buf))
        typed = { "D", "u", "r" }
        source.choose(source.items[1])
      end
      require("org.pickers").pick({
        title = "Tags",
        allow_query = true,
        create_label = "+ New tags…",
        items = { { display = { { "news" } }, value = "news" }, { display = { { "work" } }, value = "work" } },
        on_choice = function(items, q)
          got, query = items, q
        end,
      })
      settle()
      eq({}, got)
      eq("Dur", query)
    end)

    it("starts with the query typed", function()
      local got, query
      typed = {}
      behaviour = function(source)
        eq({ "D", "u", "r", "i", "a", "n" }, typed)
        source.choose(source.items[1])
      end
      require("org.pickers").pick({
        title = "Node",
        allow_query = true,
        create_label = "+ New node",
        query = "Durian",
        items = { { display = { { "Apple" } }, value = "apple" } },
        on_choice = function(items, q)
          got, query = items, q
        end,
      })
      settle()
      eq({}, got)
      eq("Durian", query)
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

    it("creates a node from the selected text with mini.pick", function()
      local typed = {}
      fake_global("MiniPick", {
        start = function(o)
          if type(o.source.items) == "function" then
            o.source.items = o.source.items()
          end
          -- <CR> on "+ New node: Durian", which no node matches
          o.source.choose(o.source.items[1])
        end,
        get_picker_query = function()
          return typed
        end,
        set_picker_query = function(q)
          typed = q
        end,
      })
      stub(utils, "input", function()
        return nil
      end)
      setup("mini")
      local c, done
      utils.run(function()
        c = require("org.extensions.roam.node").read({ default_title = "Durian" })
        done = true
      end)
      vim.wait(500, function()
        return done
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

    it("follows LazyVim's picker extra for auto", function()
      fake_module("fzf-lua", { fzf_exec = function() end })
      fake_global("Snacks", { picker = { pick = function() end } })
      stub(vim.g, "lazyvim_picker", "auto")
      fake_global("LazyVim", { pick = { picker = { name = "fzf" } } })
      setup("auto")
      eq("fzf-lua", require("org.extensions.roam.node").picker())
    end)
  end)
end)
