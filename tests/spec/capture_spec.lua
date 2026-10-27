local capture = require("org.capture")
local config = require("org.config")
local utils = require("org.utils")
local date = require("org.date")

vim.g.org_test = true
local root = vim.fn.getcwd()
local D = date.parse("<2026-09-25 Fri 12:00>")

local function base_setup(extra)
  config.setup(vim.tbl_deep_extend("force", {
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
    id = { locations_file = vim.fn.tempname() .. ".json" },
  }, extra or {}))
  require("org.id")._reset()
end

--- Captures edited in a separate capture buffer (capture.in_place = false).
local function buffer_setup(extra)
  base_setup(vim.tbl_deep_extend("force", { capture = { in_place = false } }, extra or {}))
end

local function tmpfile(lines)
  local p = vim.fn.tempname() .. ".org"
  if lines then
    utils.writefile(p, lines)
  end
  return p
end

local function run(fn, ...)
  local res
  local args = { ... }
  local finished = utils.run(function()
    res = { fn(unpack(args)) }
  end)
  ok(finished, "coroutine did not finish")
  return unpack(res or {})
end

local function file_lines(path)
  local b = utils.find_buffer(path)
  if b then
    return vim.api.nvim_buf_get_lines(b, 0, -1, false)
  end
  return utils.readfile(path)
end

--- Replace utils prompts by answers taken in order; returns a restore function.
local function answer(list, seen)
  local orig = { utils.input, utils.input_complete, utils.select, utils.confirm }
  local function pop(kind, prompt, cands)
    if seen then
      seen[#seen + 1] = { kind = kind, prompt = prompt, candidates = cands }
    end
    return table.remove(list, 1)
  end
  utils.input = function(opts)
    return pop("input", type(opts) == "table" and opts.prompt or opts)
  end
  utils.input_complete = function(prompt, cands)
    return pop("complete", prompt, cands)
  end
  utils.select = function(items, opts)
    local v = pop("select", opts and opts.prompt, items)
    if type(v) == "number" then
      return items[v], v
    end
    return v
  end
  utils.confirm = function()
    return pop("confirm") ~= false
  end
  return function()
    utils.input, utils.input_complete, utils.select, utils.confirm = unpack(orig)
  end
end

describe("capture.expand (org-capture-fill-template)", function()
  before_each(function()
    base_setup()
  end)

  it("expands dates and keeps %% and backslash-escaped placeholders like Emacs", function()
    local text = run(capture.expand, "100%% %%t \\%t \\\\%t %t %u %T %<%Y/%m>", { date = D })
    eq(
      "100%% %<2026-09-25 Fri> %t \\<2026-09-25 Fri> <2026-09-25 Fri> [2026-09-25 Fri] <2026-09-25 Fri 12:00> 2026/09",
      text
    )
    eq("* TODO \30", run(capture.expand, "* TODO %?", {}))
    eq("%?", (run(capture.expand, "%? %?", {}):gsub("^\30 ", "")))
  end)

  it("counts only %^{...} answers for %\\N; %\\*N counts every prompt", function()
    local restore = answer({ "Alice" })
    local orig = require("org.calendar").pick
    require("org.calendar").pick = function()
      return date.parse("<2026-10-01 Thu>")
    end
    local text = run(capture.expand, "%^{When}t %^{Name} %\\1 %\\*1 %\\*2", {})
    require("org.calendar").pick = orig
    restore()
    eq("<2026-10-01 Thu> Alice Alice <2026-10-01 Thu> Alice", text)
    restore = answer({ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l" })
    text = run(capture.expand, "%^{A}%^{B}%^{C}%^{D}%^{E}%^{F}%^{G}%^{H}%^{I}%^{J}%^{K}%^{L} %\\12 %\\1", {})
    restore()
    eq("abcdefghijkl l a", text)
  end)

  it("uses the default for an empty answer and completes the other choices", function()
    local seen = {}
    local restore = answer({ "", "q", "Bob" }, seen)
    local text, ctx = run(capture.expand, "%^{P|dflt|x|y}|%^{Q} %^{Owner}p", {})
    restore()
    eq("dflt|q ", text)
    eq({ "x", "y" }, seen[1].candidates)
    eq("P [dflt]: ", seen[1].prompt)
    eq({ { "Owner", "Bob" } }, ctx.properties)
  end)

  it("offers the allowed values of %^{PROP}p from the target", function()
    local p = tmpfile({ "* Target", ":PROPERTIES:", ":Status_ALL: open closed", ":END:" })
    local seen = {}
    local restore = answer({ "closed" }, seen)
    run(capture.capture, { target = p, headline = "Target", template = "* X %^{Status}p", immediate_finish = true })
    restore()
    eq({ "open", "closed" }, seen[1].candidates)
    eq({
      "* Target",
      ":PROPERTIES:",
      ":Status_ALL: open closed",
      ":END:",
      "** X ",
      ":PROPERTIES:",
      ":Status:   closed",
      ":END:",
    }, file_lines(p))
  end)

  it("repeats the text before %i on every line of the initial content", function()
    eq("- one\n- two", run(capture.expand, "- %i", { initial = "one\ntwo" }))
    eq("  > one\n  > two", run(capture.expand, "  > %i", { initial = "one\ntwo" }))
    eq("x = (one\ntwo)", run(capture.expand, 'x = %("(" .. [[%i]] .. ")")', { initial = "one\ntwo" }))
  end)

  it("expands %a %l %L and asks for the description of %A", function()
    local restore = answer({ "D" })
    local text = run(capture.expand, "%a|%l|%L|%A|%:link", { annotation = "[[file:/x.org::*H][H]]" })
    restore()
    eq("[[file:/x.org::*H][H]]|[[file:/x.org::*H]]|file:/x.org::*H|[[file:/x.org::*H][D]]|file:/x.org::*H", text)
  end)

  it("drops blank lines before, whitespace after, and untabifies", function()
    eq("  first\n        second  ", run(capture.expand, "\n\n  first\n\tsecond  \n\n  ", {}))
    eq("", run(capture.expand, " \n\t\n", {}))
  end)

  it("inserts files with %[...] and evaluates %(lua)", function()
    local f = vim.fn.tempname()
    utils.writefile(f, { "from file" })
    eq("from file", run(capture.expand, "%[" .. f .. "]", {}))
    -- (C:/no/such/file on Windows, as expand-file-name gives)
    ok(run(capture.expand, "%[/no/such/file]", {}):match("^%%!%[could not insert %a?:?/no/such/file: "))
    eq("3 X %(", run(capture.expand, "%(1 + 2) %(string.upper('x')) %(", {}))
  end)

  it("aligns tags from %^g on a heading and offers the target file's tags", function()
    base_setup({ tags_column = -30 })
    local p = tmpfile({ "* A :work:", "* B :home:" })
    local seen = {}
    local restore = answer({ "work:new" }, seen)
    run(capture.capture, { target = p, template = "* H %^g", immediate_finish = true })
    restore()
    eq({ "home", "work" }, seen[1].candidates)
    eq("* H                 :work:new:", file_lines(p)[3])
  end)

  it("still prompts for a %^{...} after %^g on the same heading", function()
    local seen = {}
    local restore = answer({ "work", "Hello", "Next" }, seen)
    local text = run(capture.expand, "* H %^g %^{Something}\n%^{Other}", {})
    restore()
    local prompts = vim.tbl_map(function(s)
      return s.prompt
    end, seen)
    eq({ "Tags: ", "Something: ", "Other: " }, prompts)
    eq("* H :work: Hello\nNext", text)
  end)
end)

describe("capture templates", function()
  before_each(function()
    base_setup()
  end)

  it("falls back to Emacs's Task template when none is configured", function()
    vim.cmd("enew!")
    base_setup({ capture = { templates = {} } })
    local items = capture.menu_items()
    eq(1, #items)
    eq("t", items[1].key)
    local tpl = capture.get_template("t")
    eq("Tasks", tpl.headline)
    eq("* TODO %?\n  %u\n  %a", tpl.template)
    eq("split", config.opts.capture.window)
    local notes = tmpfile({ "* Other" })
    base_setup({ capture = { templates = {} }, default_notes_file = notes })
    run(capture.capture, vim.tbl_extend("force", capture.get_template("t"), { immediate_finish = true }), { date = D })
    eq({ "* Other", "* Tasks", "** TODO", "[2026-09-25 Fri]" }, vim.tbl_map(vim.trim, file_lines(notes)))
  end)

  it("uses Emacs's default text for an empty entry template", function()
    vim.cmd("enew!")
    local p = tmpfile({ "* A" })
    run(capture.capture, { target = p, headline = "A", immediate_finish = true })
    eq({ "* A", "** " }, file_lines(p))
    local p2 = tmpfile({ "* A" })
    run(capture.capture, { target = p2, headline = "A", type = "checkitem", immediate_finish = true })
    eq({ "* A", "- [ ] " }, file_lines(p2))
  end)

  it("reads the template from a file", function()
    base_setup({ org_directory = vim.fn.fnamemodify(vim.fn.tempname(), ":h") })
    local tf = vim.fn.tempname() .. ".txt"
    utils.writefile(tf, { "* From %<%Y>" })
    local p = tmpfile({})
    run(capture.capture, { target = p, template = { file = tf }, immediate_finish = true }, { date = D })
    eq({ "* From 2026" }, file_lines(p))
    local p2 = tmpfile({})
    run(capture.capture, { target = p2, template = { file = "/no/such.txt" }, immediate_finish = true })
    eq({ '* Template file "/no/such.txt" not found' }, file_lines(p2))
  end)

  it("filters and remaps templates with templates_contexts", function()
    local t = { a = { template = "a" }, b = { template = "b" }, c = { template = "c" } }
    base_setup({
      capture = {
        templates = t,
        templates_contexts = {
          { "a", { { in_mode = "^markdown$" } } },
          { "b", "c", { { not_in_mode = "^org$" } } },
        },
      },
    })
    local env = { mode = "text", buffer = "x.txt" }
    local list = capture.templates(env)
    eq(nil, list.a)
    eq("c", list.b.template)
    eq(nil, list.c)
    list = capture.templates({ mode = "markdown", buffer = "x.md" })
    eq("a", list.a.template)
    list = capture.templates({ mode = "org", buffer = "x.org" })
    eq(nil, list.a)
    eq(nil, list.b)
    eq("c", list.c.template)
    base_setup({
      capture = {
        templates = t,
        templates_contexts = { {
          "a",
          function()
            return true
          end,
        } },
      },
    })
    eq("a", capture.templates({ mode = "org" }).a.template)
  end)

  it("builds menu items from keys", function()
    base_setup({
      capture = {
        templates = {
          t = { description = "Task", template = "x" },
          w = "Work",
          wm = { description = "Meeting", template = "y" },
        },
      },
    })
    local items = capture.menu_items()
    eq(2, #items)
    local work
    for _, i in ipairs(items) do
      if i.key == "w" then
        work = i
      end
    end
    eq("Work", work.label)
    eq("wm", work.items[1].value)
  end)
end)

describe("capture placement (Emacs parity)", function()
  before_each(function()
    base_setup()
  end)

  -- content, template, the file after capturing (checked against Emacs)
  local cases = {
    { "* A\n\n* B\n", { headline = "A", template = "* new" }, "* A\n** new\n* B\n" },
    { "* A\nbody\n\n* B\n", { headline = "A", template = "* new" }, "* A\nbody\n** new\n* B\n" },
    { "* A\nbody\n\n\n* B\n\n* C\n", { headline = "A", template = "* new" }, "* A\nbody\n** new\n* B\n\n* C\n" },
    { "* A\n** x\n\n** y\n\n* B\n", { headline = "A", template = "* new" }, "* A\n** x\n\n** y\n** new\n* B\n" },
    {
      "* A\n** x\n\n** y\n\n* B\n",
      { headline = "A", template = "* new", prepend = true },
      "* A\n** new\n** x\n\n** y\n\n* B\n",
    },
    { "* A\n\n* B\n\n", { template = "* new" }, "* A\n\n* B\n* new\n" },
    { "* A\n* B\n\n\n", { template = "* new" }, "* A\n* B\n* new\n" },
    { "#+TITLE: t\n\n* A\n* B\n", { template = "* new", prepend = true }, "#+TITLE: t\n* new\n* A\n* B\n" },
    { "#+TITLE: t\n", { template = "* new", prepend = true }, "#+TITLE: t\n* new\n" },
    { "* A\n* B\n", { headline = "A", template = "* new", empty_lines_after = 2 }, "* A\n** new\n\n\n* B\n" },
    { "* A\n* B\n", { headline = "Zed", template = "* new" }, "* A\n* B\n* Zed\n** new\n" },
    {
      "* A\n* TODO [#A] Zed :tag:\n",
      { headline = "Zed", template = "* new" },
      "* A\n* TODO [#A] Zed :tag:\n** new\n",
    },
    {
      "* A\ntext\n* B\n",
      { type = "plain", headline = "A", template = "p1\np2", empty_lines = 1 },
      "* A\ntext\n\np1\np2\n\n* B\n",
    },
    {
      "* A\n:PROPERTIES:\n:X: 1\n:END:\ntext\n* B\n",
      { type = "plain", headline = "A", template = "p1", prepend = true },
      "* A\n:PROPERTIES:\n:X: 1\n:END:\np1\ntext\n* B\n",
    },
    {
      "* A\n:PROPERTIES:\n:X: 1\n:END:\ntext\n* B\n",
      { type = "item", headline = "A", template = "p1", prepend = true },
      "* A\n:PROPERTIES:\n:X: 1\n:END:\n- p1\ntext\n* B\n",
    },
    {
      "* A\n- a\n- b\n\n* B\n",
      { type = "item", headline = "A", template = "c", empty_lines = 2 },
      "* A\n- a\n- b\n\n- c\n\n* B\n",
    },
    {
      "* A\n- a\n- b\n\n* B\n",
      { type = "item", headline = "A", template = "c", empty_lines = 2, prepend = true },
      "* A\n- c\n\n- a\n- b\n\n* B\n",
    },
    {
      "* A\ntext\n* B\n",
      { type = "item", headline = "A", template = "c", empty_lines = 1 },
      "* A\ntext\n\n- c\n\n* B\n",
    },
    {
      "* A\n  1) a\n  2) b\n",
      { type = "item", headline = "A", template = "- c\nmore" },
      "* A\n  1) a\n  2) b\n  3) c\n  more\n",
    },
    { "* A\n- [ ] a\n", { type = "checkitem", headline = "A", template = "c" }, "* A\n- [ ] a\n- c\n" },
    { "* A\n- [ ] a\n", { type = "checkitem", headline = "A" }, "* A\n- [ ] a\n- [ ] \n" },
    {
      "* A\ntext\n* B\n",
      { type = "table-line", headline = "A", template = "| x | y |" },
      "* A\ntext\n|   |   |\n|---+---|\n| x | y |\n* B\n",
    },
    {
      "* A\n| a |\n|---|\n| 1 |\n| 2 |\n|---|\n| 3 |\n",
      { type = "table-line", headline = "A", template = "| x |", table_line_pos = "II-1" },
      "* A\n| a |\n|---|\n| 1 |\n| 2 |\n| x |\n|---|\n| 3 |\n",
    },
    {
      "* A\n| a |\n|---|\n| 1 |\n| 2 |\n|---|\n| 3 |\n",
      { type = "table-line", headline = "A", template = "| x |", table_line_pos = "I+2" },
      "* A\n| a |\n|---|\n| 1 |\n| x |\n| 2 |\n|---|\n| 3 |\n",
    },
    {
      "* A\n| a |\n|---|\n| 1 |\n| 2 |\n|---|\n| 3 |\n",
      { type = "table-line", headline = "A", template = "| x |", table_line_pos = "II+1" },
      "* A\n| a |\n|---|\n| 1 |\n| 2 |\n|---|\n| x |\n| 3 |\n",
    },
    { "text\n* A\n", { type = "table-line", template = "| x |" }, "text\n* A\n|   |\n|---|\n| x |\n" },
    -- a table-looking line in a block is not a table: a new one goes after
    -- the block, or the line goes to the next real table
    {
      "* A\n#+begin_example\n| x |\n#+end_example\n* B\n",
      { type = "table-line", headline = "A", template = "| c |" },
      "* A\n#+begin_example\n| x |\n#+end_example\n|   |\n|---|\n| c |\n* B\n",
    },
    {
      "* A\n#+begin_src text\n| x |\n#+end_src\n: | f |\n| y |\n",
      { type = "table-line", template = "| c |" },
      "* A\n#+begin_src text\n| x |\n#+end_src\n: | f |\n| y |\n| c |\n",
    },
    { "* A\nbody\n* B\n", { regexp = "^\\* B", template = "* new" }, "* A\nbody\n* B\n** new\n" },
    {
      "* A\nfoo MARK bar\n* B\n",
      { type = "plain", regexp = "MARK", template = "new", prepend = true },
      "* A\nfoo \nnew\nMARK bar\n* B\n",
    },
    { "* A\n+ a\n+ b\n", { type = "item", headline = "A", template = "c", prepend = true }, "* A\n- c\n- a\n- b\n" },
    {
      "* A\n1. a\n2. b\n",
      { type = "item", headline = "A", template = "c", prepend = true },
      "* A\n1. c\n2. a\n3. b\n",
    },
    { "* A\n- a\n- b\n", { type = "item", headline = "A", template = "3) c", prepend = true }, "* A\n- c\n- a\n- b\n" },
    { "* A\n1) a\n2) b\n", { type = "item", headline = "A", template = "- c" }, "* A\n1) a\n2) b\n3) c\n" },
    { "* A\n- a\n  - a1\n- b\n", { type = "item", headline = "A", template = "c" }, "* A\n- a\n  - a1\n- b\n- c\n" },
    { "* A\n- a\n- b\n\n- c\n", { type = "item", headline = "A", template = "d" }, "* A\n- a\n- b\n\n- c\n- d\n" },
    {
      "* A\n- a\n- b\ntext\n- c\n",
      { type = "item", headline = "A", template = "d" },
      "* A\n- a\n- b\n- d\ntext\n- c\n",
    },
    { "* A\n  - [ ] a\n", { type = "checkitem", headline = "A", template = "- [X] c" }, "* A\n  - [ ] a\n  - [X] c\n" },
    { "* A\n- a\n* B\n- x\n", { type = "item", template = "new" }, "* A\n- a\n- new\n* B\n- x\n" },
    { "- a\n* B\n", { type = "item", template = "new" }, "- a\n- new\n* B\n" },
    { "- a\n* B\n", { type = "item", template = "new", prepend = true }, "- new\n- a\n* B\n" },
    { "#+TITLE: x\n* B\n", { type = "item", template = "new", prepend = true }, "- new\n#+TITLE: x\n* B\n" },
    { "#+TITLE: x\n* B\n", { type = "plain", template = "new", empty_lines = 1 }, "#+TITLE: x\n* B\n\nnew\n\n" },
    { "#+TITLE: x\n* B\n\n\n", { type = "plain", template = "new" }, "#+TITLE: x\n* B\nnew\n" },
    { "* A\n\n\n* B\n", { type = "plain", headline = "A", template = "new" }, "* A\nnew\n* B\n" },
    {
      "* A\nx\n\n\n* B\n",
      { type = "plain", headline = "A", template = "new", prepend = true },
      "* A\nnew\nx\n\n\n* B\n",
    },
    {
      "* A\nSCHEDULED: <2026-09-25 Fri>\n:LOGBOOK:\n- x\n:END:\ntext\n",
      { type = "plain", headline = "A", template = "new", prepend = true },
      "* A\nSCHEDULED: <2026-09-25 Fri>\n:LOGBOOK:\n- x\n:END:\nnew\ntext\n",
    },
    { "* A\n", { headline = "A", template = "*** deep\ntext\n**** deeper\n" }, "* A\n** deep\ntext\n*** deeper\n" },
    { "* A\n", { headline = "A", template = "\n\n  * TODO x\n  text  \n\n" }, "* A\n**   * TODO x\n  text  \n" },
    {
      "* 2027\n",
      { datetree = true, template = "* new" },
      "\n* 2026\n** 2026-09 September\n*** 2026-09-25 Friday\n**** new\n* 2027\n",
    },
    {
      "#+TITLE: x\n\n\n* 2027\n",
      { datetree = true, template = "* new" },
      "#+TITLE: x\n* 2026\n** 2026-09 September\n*** 2026-09-25 Friday\n**** new\n* 2027\n",
    },
    {
      "* 2025\n\n* 2027\n",
      { datetree = true, template = "* new" },
      "* 2025\n* 2026\n** 2026-09 September\n*** 2026-09-25 Friday\n**** new\n* 2027\n",
    },
    {
      "* 2026\n\n** 2026-08 August\nx\n\n",
      { datetree = true, template = "* new" },
      "* 2026\n\n** 2026-08 August\nx\n\n** 2026-09 September\n*** 2026-09-25 Friday\n**** new\n",
    },
    {
      "* 2026\n** 2026-09 September\n*** 2026-09-24 Thursday\nx\n\n\n** 2026-10 October\n",
      { datetree = true, template = "* new" },
      "* 2026\n** 2026-09 September\n*** 2026-09-24 Thursday\nx\n*** 2026-09-25 Friday\n**** new\n** 2026-10 October\n",
    },
    {
      "* Notes\n:PROPERTIES:\n:DATE_TREE: t\n:END:\n* Other\n",
      { datetree = true, template = "* new" },
      "* Notes\n:PROPERTIES:\n:DATE_TREE: t\n:END:\n** 2026\n*** 2026-09 September\n**** 2026-09-25 Friday\n***** new\n* Other\n",
    },
    {
      "* 2026\n** 2026-09 September\n*** 2026-09-25 Friday\n",
      { datetree = true, tree_type = { "year", "month" }, template = "* new" },
      "* 2026\n** 2026-09 September\n*** 2026-09-25 Friday\n*** new\n",
    },
    {
      "",
      { datetree = true, tree_type = { "year", "quarter", "week", "day" }, template = "* new" },
      "\n* 2026\n** 2026-Q3\n*** 2026-W39\n**** 2026-09-25 Friday\n***** new\n",
    },
    { "* A\n", { olp = { "A", "B" }, template = "* new" }, "* A\n" },
    { "* X\n** A\n* A\n** B\n", { olp = { "A", "B" }, template = "* new" }, "* X\n** A\n* A\n** B\n*** new\n" },
    {
      "",
      { datetree = true, template = "* new" },
      "\n* 2026\n** 2026-09 September\n*** 2026-09-25 Friday\n**** new\n",
    },
    {
      "#+TITLE: J\n* 2025\n** 2025-01 January\n* 2027\n* Notes\n",
      { datetree = true, template = "* new" },
      "#+TITLE: J\n* 2025\n** 2025-01 January\n* 2026\n** 2026-09 September\n*** 2026-09-25 Friday\n**** new\n* 2027\n* Notes\n",
    },
    {
      "* 2026 :journal:\n** 2026-09 Sept\n*** 2026-09-25 Freitag\n**** old\n*** 2026-09-27 Sunday\n",
      { datetree = true, template = "* new" },
      "* 2026 :journal:\n** 2026-09 Sept\n*** 2026-09-25 Freitag\n**** old\n**** new\n*** 2026-09-27 Sunday\n",
    },
    {
      "* 2026\n** 2026-10 October\n** 2026-08 August\n",
      { datetree = true, template = "* new" },
      "* 2026\n** 2026-09 September\n*** 2026-09-25 Friday\n**** new\n** 2026-10 October\n** 2026-08 August\n",
    },
    {
      "",
      { datetree = true, tree_type = "week", template = "* new" },
      "\n* 2026\n** 2026-W39\n*** 2026-09-25 Friday\n**** new\n",
    },
    { "", { datetree = true, tree_type = "month", template = "* new" }, "\n* 2026\n** 2026-09 September\n*** new\n" },
    {
      "",
      { datetree = true, tree_type = { "year", "quarter", "month" }, template = "* new" },
      "\n* 2026\n** 2026-Q3\n*** 2026-09 September\n**** new\n",
    },
    {
      "* P\n** Q\n* Z\n",
      { olp = { "P", "Q" }, datetree = true, template = "* new" },
      "* P\n** Q\n*** 2026\n**** 2026-09 September\n***** 2026-09-25 Friday\n****** new\n* Z\n",
    },
    {
      "* 2026\n** 2026-09 September\n*** 2026-09-25 Friday\n**** a\n",
      { datetree = true, type = "item", template = "x" },
      "* 2026\n** 2026-09 September\n*** 2026-09-25 Friday\n- x\n**** a\n",
    },
    {
      "* 2026\n** 2026-09 September\n*** 2026-09-25 Friday\n**** a\n",
      { datetree = true, prepend = true, template = "* new" },
      "* 2026\n** 2026-09 September\n*** 2026-09-25 Friday\n**** new\n**** a\n",
    },
    {
      "* 2026\n** 2026-09 September\n*** 2026-09-25 Friday\n**** a\n",
      { datetree = true, template = "* %t %T %u %U %<%Y/%m>" },
      "* 2026\n** 2026-09 September\n*** 2026-09-25 Friday\n**** a\n**** <2026-09-25 Fri> <2026-09-25 Fri 12:00> [2026-09-25 Fri] [2026-09-25 Fri 12:00] 2026/09\n",
    },
  }
  for i, c in ipairs(cases) do
    it("case " .. i .. ": " .. (c[2].type or "entry") .. " " .. vim.inspect(c[2]):gsub("%s+", " "), function()
      local p = tmpfile()
      local fd = io.open(p, "w")
      fd:write(c[1])
      fd:close()
      local tpl = vim.tbl_extend("force", { target = p, immediate_finish = true }, c[2])
      run(capture.capture, tpl, { date = D })
      local b = utils.find_buffer(p)
      if b then
        utils.save_buffer(b)
      end
      local fd2 = io.open(p, "r")
      local text = fd2:read("*a")
      fd2:close()
      eq(c[3], text)
    end)
  end
end)

describe("capture targets", function()
  before_each(function()
    base_setup()
  end)

  it("creates file+headline entries, relevels and prepends", function()
    local p = tmpfile({ "#+TITLE: Inbox", "* Other" })
    local tpl = { target = p, headline = "Tasks", template = "* TODO %?", immediate_finish = true }
    run(capture.capture, tpl)
    eq({ "#+TITLE: Inbox", "* Other", "* Tasks", "** TODO " }, file_lines(p))
    run(capture.capture, vim.tbl_extend("force", tpl, { template = "* Second" }))
    eq("** Second", file_lines(p)[5])
    run(capture.capture, vim.tbl_extend("force", tpl, { template = "* First", prepend = true }))
    eq("** First", file_lines(p)[4])
  end)

  it("follows an outline path (every node must exist) and adds properties", function()
    local p = tmpfile({ "* Work", "** Meetings", "*** Old" })
    run(capture.capture, {
      target = p,
      olp = { "Work", "Meetings" },
      template = "* Standup",
      properties = { Where = "Room 1" },
      immediate_finish = true,
    })
    eq(
      { "* Work", "** Meetings", "*** Old", "*** Standup", ":PROPERTIES:", ":Where:    Room 1", ":END:" },
      file_lines(p)
    )
    local r = run(capture.capture, { target = p, olp = "Work/Missing", template = "* X", immediate_finish = true })
    eq(nil, r)
    eq(7, #file_lines(p))
  end)

  it("builds date trees with a list or function :tree-type", function()
    local p = tmpfile({ "* 2027" })
    run(capture.capture, { target = p, datetree = true, template = "* Entry", immediate_finish = true }, { date = D })
    eq({ "", "* 2026", "** 2026-09 September", "*** 2026-09-25 Friday", "**** Entry", "* 2027" }, file_lines(p))
    local p2 = tmpfile({ "* 2026", "** 2026-09 Sept", "*** 2026-09-25 Freitag" })
    run(capture.capture, { target = p2, datetree = true, template = "* Again", immediate_finish = true }, { date = D })
    eq({ "* 2026", "** 2026-09 Sept", "*** 2026-09-25 Freitag", "**** Again" }, file_lines(p2))
    local p3 = tmpfile({})
    run(capture.capture, {
      target = p3,
      datetree = { tree_type = { "year", "quarter" } },
      template = "* Q",
      immediate_finish = true,
    }, { date = D })
    eq({ "", "* 2026", "** 2026-Q3", "*** Q" }, file_lines(p3))
    local p4 = tmpfile({})
    run(capture.capture, {
      target = p4,
      datetree = true,
      tree_type = function(d)
        return { "Journal " .. d.year, "Week" }
      end,
      template = "* F",
      immediate_finish = true,
    }, { date = D })
    eq({ "", "* Journal 2026", "** Week", "*** F" }, file_lines(p4))
  end)

  it("captures under an entry with an ID", function()
    local p = tmpfile({ "* A", "* B", ":PROPERTIES:", ":ID: cap-id-1", ":END:", "** Old", "* C" })
    base_setup({ agenda_files = { p } })
    run(capture.capture, { id = "cap-id-1", template = "* New", immediate_finish = true })
    eq({ "* A", "* B", ":PROPERTIES:", ":ID: cap-id-1", ":END:", "** Old", "** New", "* C" }, file_lines(p))
  end)

  it("captures under the clocked task, resolved when the capture starts", function()
    local clock = require("org.clock")
    local p = tmpfile({ "* Task", "* Other" })
    vim.cmd("edit! " .. p)
    clock.clock_in({ bufnr = vim.api.nvim_get_current_buf(), lnum = 1 })
    run(capture.capture, { target = "clock", template = "* Note", immediate_finish = true })
    local lines = file_lines(p)
    eq("** Note", lines[#lines - 1])
    eq("* Other", lines[#lines])
    -- clocking out during the capture keeps the target
    local buf = run(capture.capture, { target = "clock", template = "* Later" })
    clock.clock_cancel()
    run(capture.finalize, buf, { jump = false })
    lines = file_lines(p)
    eq("** Later", lines[#lines - 1])
    -- no clock: nothing happens
    local r = run(capture.capture, { target = "clock", template = "* X", immediate_finish = true })
    eq(nil, r)
  end)

  it("uses a function target: file+function and the (function f) location", function()
    local p = tmpfile({ "* A", "* B", "text" })
    run(capture.capture, {
      target = p,
      func = function()
        return 2
      end,
      template = "* Child",
      immediate_finish = true,
    })
    eq({ "* A", "* B", "text", "** Child" }, file_lines(p))
    local p2 = tmpfile({ "* A", "some text", "more" })
    local b2 = utils.load_buffer(p2)
    run(capture.capture, {
      type = "plain",
      location = function()
        return b2, 2, 4
      end,
      template = "INSERTED",
      immediate_finish = true,
    })
    eq({ "* A", "some", "INSERTED", " text", "more" }, file_lines(p2))
  end)

  it("inserts at the cursor with `here` (C-0)", function()
    local p = tmpfile({ "* A", "body", "* B" })
    vim.cmd("edit! " .. p)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    run(
      capture.capture,
      { template = "* Here", immediate_finish = true, target = "/should/not/be/used.org" },
      { here = true }
    )
    eq({ "* A", "* Here", "body", "* B" }, file_lines(p))
    vim.api.nvim_win_set_cursor(0, { 2, 3 })
    run(capture.capture, { type = "plain", template = "after", immediate_finish = true }, { here = true })
    eq({ "* A", "* Here", "after", "body", "* B" }, file_lines(p))
  end)

  it("asks for the date tree date with a count of 1 (C-1)", function()
    local p = tmpfile({})
    base_setup({
      capture = { templates = { j = { target = p, datetree = true, template = "* J", immediate_finish = true } } },
    })
    local orig_pick, orig_menu = require("org.calendar").pick, require("org.ui").menu
    require("org.calendar").pick = function()
      return date.parse("<2025-01-02 Thu>")
    end
    require("org.ui").menu = function()
      return "j"
    end
    run(capture.prompt, { count = 1 })
    require("org.calendar").pick, require("org.ui").menu = orig_pick, orig_menu
    eq({ "", "* 2025", "** 2025-01 January", "*** 2025-01-02 Thursday", "**** J" }, file_lines(p))
  end)

  it("places table lines with :table-line-pos and creates missing tables", function()
    local p = tmpfile({ "* A", "| a |", "|---|", "| 1 |", "| 2 |", "|---|", "| 3 |" })
    run(capture.capture, {
      target = p,
      headline = "A",
      type = "table-line",
      template = "| x |",
      table_line_pos = "II-1",
      immediate_finish = true,
    })
    eq({ "* A", "| a |", "|---|", "| 1 |", "| 2 |", "| x |", "|---|", "| 3 |" }, file_lines(p))
    local p2 = tmpfile({ "* A", "text" })
    run(
      capture.capture,
      { target = p2, headline = "A", type = "table-line", template = "| x | y |", immediate_finish = true }
    )
    eq({ "* A", "text", "|   |   |", "|---+---|", "| x | y |" }, file_lines(p2))
  end)
end)

describe("capture buffer (capture.in_place = false)", function()
  before_each(function()
    buffer_setup()
  end)

  it("opens a split buffer and finalizes into the target", function()
    local p = tmpfile({ "* Inbox" })
    buffer_setup({
      capture = { templates = { t = { description = "Task", template = "* TODO %?", target = p, headline = "Inbox" } } },
    })
    local wins = #vim.api.nvim_list_wins()
    local buf = run(capture.capture, "t")
    ok(capture.sessions[buf])
    eq(wins + 1, #vim.api.nvim_list_wins())
    eq("", vim.api.nvim_win_get_config(vim.fn.bufwinid(buf)).relative)
    eq("org", vim.bo[buf].filetype)
    eq("acwrite", vim.bo[buf].buftype)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "* TODO Write tests", "" })
    run(capture.finalize, buf, { jump = false })
    eq(nil, capture.sessions[buf])
    eq(false, vim.api.nvim_buf_is_valid(buf))
    eq({ "* Inbox", "** TODO Write tests" }, file_lines(p))
  end)

  it("keeps the text when the target is gone", function()
    local p = tmpfile({ "* A", ":PROPERTIES:", ":ID: gone-1", ":END:", "* B" })
    buffer_setup({ agenda_files = { p } })
    local buf = run(capture.capture, { id = "gone-1", template = "* Note" })
    local tb = utils.find_buffer(p)
    vim.api.nvim_buf_set_lines(tb, 0, 4, false, {})
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "* Precious" })
    eq(nil, (run(capture.finalize, buf, { jump = false })))
    ok(capture.sessions[buf])
    eq({ "* Precious" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    capture.kill(buf)
  end)

  it("kill discards the capture and the headline created for it", function()
    local p = tmpfile({ "* Inbox" })
    buffer_setup({ capture = { templates = { t = { template = "* X", target = p, headline = "New" } } } })
    local buf = run(capture.capture, "t")
    eq({ "* Inbox", "* New" }, file_lines(p))
    capture.kill(buf)
    eq({ "* Inbox" }, file_lines(p))
  end)

  it("a cancelled prompt leaves no headline or date tree in the target", function()
    local p = tmpfile({ "* Inbox", "text" })
    buffer_setup()
    local tb = utils.load_buffer(p)
    local restore = answer({ nil })
    run(capture.capture, { template = "* %^{Title}", target = p, headline = "New" })
    restore()
    eq({ "* Inbox", "text" }, buf_lines(tb))
    eq(false, vim.bo[tb].modified)
    -- a target file the capture loaded is unloaded again
    local q = tmpfile({ "* Old" })
    restore = answer({ nil })
    run(capture.capture, { template = "* %^{Title}", target = q, datetree = true }, { date = D })
    restore()
    eq(nil, utils.find_buffer(q))
    eq({ "* Old" }, utils.readfile(q))
  end)

  -- Emacs: C-c C-k / C-c C-c work while typing. The capture starts in
  -- Insert mode at %?; there <C-c> used to leave Insert mode and <C-k>
  -- run as a Normal-mode key (LazyVim: the window above).
  it("the Ctrl keys abort and finish from Insert mode, the <prefix> keys only in Normal mode", function()
    local p = tmpfile({ "* Inbox" })
    buffer_setup({ capture = { templates = { t = { template = "* TODO %?", target = p, headline = "Inbox" } } } })
    local up = 0
    vim.keymap.set("n", "<C-k>", function()
      up = up + 1
    end)
    local function keys(k)
      vim.api.nvim_feedkeys(vim.keycode(k), "xt", false)
    end
    local ok_, err = pcall(function()
      local buf = run(capture.capture, "t")
      local prefix_k = config.lhs_list("<prefix>k")[1]
      vim.api.nvim_buf_call(buf, function()
        eq("org: abort capture", vim.fn.maparg("<C-c><C-k>", "i", false, true).desc)
        eq("org: finalize capture (count: and jump to it)", vim.fn.maparg("<C-c><C-c>", "i", false, true).desc)
        eq("org: refile capture", vim.fn.maparg("<C-c><C-w>", "i", false, true).desc)
        eq({}, vim.fn.maparg(prefix_k, "i", false, true))
        eq("org: abort capture", vim.fn.maparg(prefix_k, "n", false, true).desc)
      end)
      keys("Ainbox<C-c><C-k>")
      eq(nil, capture.sessions[buf])
      eq(0, up)
      eq("n", vim.api.nvim_get_mode().mode)
      eq({ "* Inbox" }, file_lines(p))
      buf = run(capture.capture, "t")
      keys("AWrite tests<C-c><C-c>")
      eq(nil, capture.sessions[buf])
      eq("n", vim.api.nvim_get_mode().mode)
      eq({ "* Inbox", "** TODO Write tests" }, file_lines(p))
    end)
    vim.keymap.del("n", "<C-k>")
    assert(ok_, err)
  end)

  -- With a short 'timeoutlen' (LazyVim: 300ms) Insert mode stops waiting
  -- for <C-k> and runs <C-c> alone: the prefix map reads the rest itself.
  it("the Ctrl prefix waits for the rest of the key in Insert mode, and gives other keys back", function()
    local p = tmpfile({ "* Inbox" })
    buffer_setup({ capture = { templates = { t = { template = "* TODO %?", target = p, headline = "Inbox" } } } })
    local buf = run(capture.capture, "t")
    vim.cmd("startinsert")
    local prefix = vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg("<C-c>", "i", false, true)
    end)
    eq("org: capture keys", prefix.desc)
    -- not a capture key: <C-c> as Vim's own key (leaves Insert mode), then x
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "* TODO ab" })
    vim.api.nvim_win_set_cursor(0, { 1, 7 })
    vim.api.nvim_feedkeys("x", "t", false)
    prefix.callback()
    vim.api.nvim_feedkeys("", "x", false)
    eq("n", vim.api.nvim_get_mode().mode)
    ok(capture.sessions[buf])
    eq({ "* TODO b" }, buf_lines(buf))
    -- <C-k> typed after the timeout: abort
    vim.api.nvim_feedkeys(vim.keycode("<C-k>"), "t", false)
    prefix.callback()
    eq(nil, capture.sessions[buf])
    eq({ "* Inbox" }, file_lines(p))
  end)

  it("kill unloads an empty or missing target file it loaded, unmodified", function()
    buffer_setup()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local empty, missing = dir .. "/empty.org", dir .. "/missing.org"
    utils.writefile(empty, {})
    for _, p in ipairs({ empty, missing }) do
      local buf = run(capture.capture, { template = "* X", target = p, headline = "New" })
      local tb = capture.sessions[buf].ctx.loc.bufnr
      eq({ "* New" }, buf_lines(tb))
      capture.kill(buf)
      eq(false, vim.api.nvim_buf_is_valid(tb))
    end
    eq(false, utils.exists(missing))
  end)

  it("an immediate capture that can't be saved leaves no headline behind", function()
    buffer_setup()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local p = dir .. "/no/such/dir/t.org"
    local dbuf = run(capture.capture, { template = "* X", target = p, headline = "New", immediate_finish = true })
    eq(nil, dbuf)
    local tb = utils.find_buffer(p)
    eq(true, tb == nil or vim.deep_equal({ "" }, buf_lines(tb)))
  end)

  it("runs on_abort with the target buffer when the capture is killed", function()
    local p = tmpfile({ "* Inbox" })
    buffer_setup()
    local got
    local buf = run(capture.capture, {
      template = "* X",
      target = p,
      on_abort = function(b)
        got = b
      end,
    })
    local target = utils.find_buffer(p)
    ok(target)
    capture.kill(buf)
    eq(target, got)
  end)

  it("refuses an empty capture unless allow_empty, which still saves the target", function()
    local p = tmpfile({ "#+title: Head" })
    buffer_setup()
    local buf = run(capture.capture, { type = "plain", template = "", target = p })
    eq(nil, (run(capture.finalize, buf, { jump = false })))
    capture.kill(buf)
    local tb = utils.load_buffer(p)
    vim.api.nvim_buf_set_lines(tb, 0, -1, false, { "#+title: Changed" })
    buf = run(capture.capture, { type = "plain", template = "", target = p, allow_empty = true })
    ok(run(capture.finalize, buf, { jump = false }))
    eq({ "#+title: Changed" }, utils.readfile(p))
  end)

  it("jumps to the stored entry with a count (C-u C-c C-c) and goes to targets", function()
    local p = tmpfile({ "* Inbox", "* Other" })
    local tpl = { template = "* X", target = p, headline = "Other" }
    buffer_setup({ capture = { templates = { t = tpl } } })
    local buf = run(capture.capture, "t")
    run(capture.finalize, buf, { jump = true })
    eq(require("org.utils").realpath(p), require("org.utils").realpath(vim.api.nvim_buf_get_name(0)))
    eq("** X", vim.api.nvim_get_current_line())
    vim.cmd("enew!")
    run(capture.goto_last_stored)
    eq("** X", vim.api.nvim_get_current_line())
    vim.cmd("enew!")
    run(capture.goto_target, "t")
    eq("* Other", vim.api.nvim_get_current_line())
  end)

  it("unloads a target it loaded with kill_buffer", function()
    local p = tmpfile({ "* Inbox" })
    run(capture.capture, { template = "* K", target = p, immediate_finish = true, kill_buffer = true })
    eq(nil, utils.find_buffer(p))
    eq({ "* Inbox", "* K" }, utils.readfile(p))
  end)

  it("refiles entries with the template's refile_targets, and only entries", function()
    local p = tmpfile({ "* Inbox" })
    local dest = tmpfile({ "* Projects", "* Other" })
    local tpl = { template = "* Refiled", target = p, refile_targets = { { files = dest, level = 1 } } }
    local buf = run(capture.capture, tpl)
    local seen = {}
    local restore = answer({ 1 }, seen)
    run(capture.refile, buf)
    restore()
    eq(
      { "Projects (" .. vim.fn.fnamemodify(dest, ":t") .. ")", "Other (" .. vim.fn.fnamemodify(dest, ":t") .. ")" },
      vim.tbl_map(function(t)
        return t.label
      end, seen[1].candidates)
    )
    eq({ "* Inbox" }, file_lines(p))
    eq({ "* Projects", "** Refiled", "* Other" }, file_lines(dest))
    local buf2 = run(capture.capture, { template = "text", type = "plain", target = p })
    run(capture.refile, buf2)
    ok(capture.sessions[buf2])
    capture.kill(buf2)
  end)

  it("takes the whole last character of a charwise selection as %i", function()
    org_buffer({ "un café noir" }, { 1, 3 })
    local opts = { count = 0 }
    local ui = require("org.ui")
    local orig = ui.menu
    ui.menu = function() end
    vim.keymap.set("x", "<F5>", function()
      capture.prompt(opts)
    end, { buffer = true })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("v3l<F5>", true, false, true), "x", false)
    ui.menu = orig
    eq("café", opts.initial)
  end)

  it("keeps the last capture and the last refile apart, like Emacs", function()
    -- org-capture-last-stored-marker and the :last-refile bookmark
    local refile = require("org.refile")
    local real = function(b)
      return utils.realpath(vim.api.nvim_buf_get_name(b))
    end
    local inbox, other = tmpfile({ "* Inbox" }), tmpfile({ "* Projects", "* Task" })
    run(capture.capture, { target = inbox, headline = "Inbox", template = "* Captured", immediate_finish = true })
    vim.cmd("edit! " .. other)
    local b = vim.api.nvim_get_current_buf()
    run(refile.refile, { bufnr = b, lnum = 2 }, { dest = { filename = other, bufnr = b, lnum = 1 } })
    vim.cmd("enew!")
    run(capture.goto_last_stored)
    eq({ utils.realpath(inbox), "** Captured" }, { real(0), vim.api.nvim_get_current_line() })
    vim.cmd("enew!")
    run(refile.goto_last_stored)
    eq({ utils.realpath(other), "** Task" }, { real(0), vim.api.nvim_get_current_line() })
    -- refiling from the capture buffer moves both (org-capture-is-refiling)
    local dest = tmpfile({ "* Elsewhere" })
    local buf = run(capture.capture, { template = "* Moved", target = inbox, refile_targets = { { files = dest } } })
    local restore = answer({ 1 })
    run(capture.refile, buf)
    restore()
    for _, go in ipairs({ capture.goto_last_stored, refile.goto_last_stored }) do
      vim.cmd("enew!")
      run(go)
      eq({ utils.realpath(dest), "** Moved" }, { real(0), vim.api.nvim_get_current_line() })
    end
  end)

  it("runs hooks", function()
    local p = tmpfile({ "* Inbox" })
    local calls = {}
    run(capture.capture, {
      target = p,
      template = "* Hooked",
      immediate_finish = true,
      before_finalize = function(b, l)
        calls[#calls + 1] = "before:" .. vim.api.nvim_buf_get_lines(b, l - 1, l, false)[1]
      end,
      after_finalize = function()
        calls[#calls + 1] = "after"
      end,
    })
    eq({ "before:* Hooked", "after" }, calls)
  end)
end)

describe("in-place capture (capture.in_place = true)", function()
  before_each(function()
    base_setup({ capture = { in_place = true } })
    vim.cmd("silent! only!")
  end)
  after_each(function()
    for buf in pairs(capture.sessions) do
      capture.kill(buf)
    end
    capture.store_filters.test = nil
  end)

  --- Screen lines `win` shows for the whole buffer: the hidden ones count 0.
  local function shown(win)
    return vim.api.nvim_win_text_height(win, {}).all
  end

  --- The capture window shows `n` lines: the entry's when this Neovim can
  --- hide lines in one window (Neovim 0.11.0 can't), else the whole file.
  local function narrowed(win, n)
    local all = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
    eq(capture.can_narrow() and n or all, shown(win))
  end

  it("inserts the entry into the target at once and shows only it in the capture window", function()
    local p = tmpfile({ "* Inbox", "** Old", "body", "* Other" })
    local tb = utils.load_buffer(p)
    -- another window already shows the target
    vim.api.nvim_set_current_buf(tb)
    local other = vim.api.nvim_get_current_win()
    local buf, win = run(capture.capture, { template = "* TODO %?\nnote", target = p, headline = "Inbox" })
    eq(tb, buf)
    ok(capture.sessions[tb].in_place)
    eq(tb, vim.api.nvim_win_get_buf(win))
    ok(win ~= other)
    eq({ "* Inbox", "** Old", "body", "** TODO ", "note", "* Other" }, buf_lines(tb))
    eq({ 4, 7 }, vim.api.nvim_win_get_cursor(win))
    -- the capture window shows the two captured lines, the other one all six
    narrowed(win, 2)
    eq(6, shown(other))
    -- the hint has no ":w finishes": :w writes the file
    ok(not vim.wo[win].winbar:find(":w", 1, true))
    -- typing more lines keeps them in view
    vim.api.nvim_buf_set_text(tb, 3, 8, 3, 8, { "Write tests" })
    vim.api.nvim_buf_set_text(tb, 4, 4, 4, 4, { "", "more" }) -- `o` on the last line
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = tb })
    narrowed(win, 3)
    eq(7, shown(other))
    if capture.can_narrow() then
      -- the cursor stays inside the entry, like a narrowed buffer
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = tb })
      eq(4, vim.api.nvim_win_get_cursor(win)[1])
      vim.api.nvim_win_set_cursor(win, { 7, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = tb })
      eq(6, vim.api.nvim_win_get_cursor(win)[1])
    end
    run(capture.finalize, tb, { jump = false })
    eq(nil, capture.sessions[tb])
    eq(false, vim.api.nvim_win_is_valid(win))
    eq({ "* Inbox", "** Old", "body", "** TODO Write tests", "note", "more", "* Other" }, utils.readfile(p))
    eq(false, vim.bo[tb].modified)
    eq(7, shown(other))
  end)

  it("shows the whole file where Neovim can't hide lines in one window only", function()
    local can = capture.can_narrow
    capture.can_narrow = function()
      return false
    end
    local p = tmpfile({ "* Inbox", "** Old", "* Other" })
    local tb = utils.load_buffer(p)
    local ok_run, err = pcall(function()
      local _, win = run(capture.capture, { template = "* New", target = p, headline = "Inbox" })
      eq(4, shown(win))
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = tb })
      eq(1, vim.api.nvim_win_get_cursor(win)[1])
      run(capture.finalize, tb, { jump = false })
    end)
    capture.can_narrow = can
    assert(ok_run, err)
    eq({ "* Inbox", "** Old", "** New", "* Other" }, utils.readfile(p))
  end)

  it("aborts by removing exactly the inserted text, keeping unsaved edits and the modified state", function()
    local p = tmpfile({ "* Inbox", "text" })
    local tb = utils.load_buffer(p)
    -- an unmodified buffer is unmodified again after the abort
    run(capture.capture, { template = "* Note %?", target = p, headline = "New" })
    eq({ "* Inbox", "text", "* New", "** Note " }, buf_lines(tb))
    ok(vim.bo[tb].modified)
    vim.api.nvim_buf_set_text(tb, 3, 8, 3, 8, { "typed", "more" })
    capture.kill(tb)
    eq(nil, capture.sessions[tb])
    eq({ "* Inbox", "text" }, buf_lines(tb))
    eq(false, vim.bo[tb].modified)
    -- unsaved edits made before and during the capture stay
    vim.api.nvim_buf_set_lines(tb, 1, 2, false, { "unsaved" })
    run(capture.capture, { template = "* Note", target = p, headline = "Inbox" })
    vim.api.nvim_buf_set_lines(tb, -1, -1, false, { "* Later" })
    capture.kill(tb)
    eq({ "* Inbox", "unsaved", "* Later" }, buf_lines(tb))
    ok(vim.bo[tb].modified)
    eq({ "* Inbox", "text" }, utils.readfile(p))
  end)

  it("aborts after undo, and undo after an abort brings nothing back unasked", function()
    local p = tmpfile({ "* Inbox" })
    local tb = utils.load_buffer(p)
    run(capture.capture, { template = "* Note", target = p, headline = "Inbox" })
    eq({ "* Inbox", "** Note" }, buf_lines(tb))
    vim.api.nvim_buf_call(tb, function()
      vim.cmd("let &l:undolevels = &l:undolevels")
    end)
    vim.api.nvim_buf_set_text(tb, 1, 7, 1, 7, { " typed" })
    vim.api.nvim_buf_call(tb, function()
      vim.cmd("silent undo")
    end)
    eq({ "* Inbox", "** Note" }, buf_lines(tb))
    capture.kill(tb)
    eq({ "* Inbox" }, buf_lines(tb))
    eq(false, vim.bo[tb].modified)
  end)

  it("loads a target file that is not open and unloads it after an abort or with kill_buffer", function()
    local p = tmpfile({ "* Inbox" })
    eq(nil, utils.find_buffer(p))
    local tb = run(capture.capture, { template = "* Note", target = p, headline = "Inbox" })
    eq({ "* Inbox", "** Note" }, buf_lines(tb))
    capture.kill(tb)
    eq(false, vim.api.nvim_buf_is_valid(tb))
    eq({ "* Inbox" }, utils.readfile(p))
    tb = run(capture.capture, { template = "* Kept", target = p, headline = "Inbox", kill_buffer = true })
    run(capture.finalize, tb, { jump = false })
    eq(false, vim.api.nvim_buf_is_valid(tb))
    eq({ "* Inbox", "** Kept" }, utils.readfile(p))
  end)

  it("places date tree entries, prepended entries, items, checkitems, table lines and plain text", function()
    local p = tmpfile({ "* A", "- one", "- [ ] c", "| a |", "text", "** Old" })
    local tb = utils.load_buffer(p)
    local function captured(tpl, typed)
      tpl.target, tpl.headline = p, "A"
      local _, win = run(capture.capture, tpl)
      -- typed at %? (Normal mode puts the cursor on the last character)
      local row, col = unpack(vim.api.nvim_win_get_cursor(win))
      local line = buf_lines(tb)[row]
      if col == #line - 1 and line:sub(-1) == " " then
        col = #line
      end
      vim.api.nvim_buf_set_text(tb, row - 1, col, row - 1, col, { typed })
      run(capture.finalize, tb, { jump = false })
    end
    captured({ template = "* %?", prepend = true }, "First")
    captured({ type = "item", template = "- %?" }, "two")
    captured({ type = "checkitem", template = "- [ ] %?" }, "d")
    captured({ type = "table-line", template = "| %? |" }, "bbb")
    captured({ type = "plain", template = "%?" }, "plain")
    eq(
      { "* A", "- one", "- [ ] c", "- two", "- [ ] d", "| a   |", "| bbb |", "text", "plain", "** First", "** Old" },
      utils.readfile(p)
    )
    local p2 = tmpfile({ "* Journal" })
    local tb2 = utils.load_buffer(p2)
    local _, win = run(capture.capture, { template = "* %?", target = p2, datetree = true }, {
      date = date.parse("<2026-09-27 Sun>"),
    })
    eq({ "* Journal", "* 2026", "** 2026-09 September", "*** 2026-09-27 Sunday", "**** " }, buf_lines(tb2))
    narrowed(win, 1)
    capture.kill(tb2)
    eq({ "* Journal" }, buf_lines(tb2))
  end)

  it("refiles the captured entry", function()
    local p = tmpfile({ "* Inbox" })
    local dest = tmpfile({ "* Projects" })
    local tb = utils.load_buffer(p)
    run(capture.capture, { template = "* Moved", target = p, refile_targets = { { files = dest, level = 1 } } })
    eq({ "* Inbox", "* Moved" }, buf_lines(tb))
    local restore = answer({ 1 })
    run(capture.refile, tb)
    restore()
    eq(nil, capture.sessions[tb])
    eq({ "* Inbox" }, file_lines(p))
    eq({ "* Projects", "** Moved" }, file_lines(dest))
  end)

  it("gives a second capture into the same file a capture buffer", function()
    local p = tmpfile({ "* Inbox" })
    local tb = utils.load_buffer(p)
    run(capture.capture, { template = "* First", target = p })
    local second = run(capture.capture, { template = "* Second", target = p })
    ok(second ~= tb)
    eq("acwrite", vim.bo[second].buftype)
    run(capture.finalize, second, { jump = false })
    run(capture.finalize, tb, { jump = false })
    eq({ "* Inbox", "* First", "* Second" }, utils.readfile(p))
  end)

  it("follows the captured text when the target is edited elsewhere meanwhile", function()
    local p = tmpfile({ "* A", "* Inbox", "** Old" })
    local tb = utils.load_buffer(p)
    local _, win = run(capture.capture, { template = "* Captured", target = p, headline = "Inbox" })
    vim.api.nvim_buf_set_lines(tb, 1, 1, false, { "** under A", "** and more" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = tb })
    narrowed(win, 1)
    local _, dline = run(capture.finalize, tb, { jump = false })
    eq({ "* A", "** under A", "** and more", "* Inbox", "** Old", "** Captured" }, utils.readfile(p))
    eq(6, dline)
  end)

  it("stores immediate_finish captures without a window", function()
    local p = tmpfile({ "* Inbox" })
    local wins = #vim.api.nvim_list_wins()
    run(capture.capture, { template = "* Quick", target = p, headline = "Inbox", immediate_finish = true })
    eq(wins, #vim.api.nvim_list_wins())
    eq({}, vim.tbl_keys(capture.sessions))
    eq({ "* Inbox", "** Quick" }, utils.readfile(p))
  end)

  it("runs the store filters: rewritten text in place, or the entry moved to another target", function()
    local p = tmpfile({ "* Inbox" })
    local other = tmpfile({ "* Elsewhere" })
    local tb = utils.load_buffer(p)
    capture.store_filters.test = function(_, lines)
      if lines[1]:find("move", 1, true) then
        return { "* Moved" }, { target = other, headline = "Elsewhere" }
      end
      return { (lines[1]:gsub("x", "y")) }
    end
    run(capture.capture, { template = "* xx", target = p, headline = "Inbox" })
    run(capture.finalize, tb, { jump = false })
    eq({ "* Inbox", "** yy" }, utils.readfile(p))
    run(capture.capture, { template = "* move me", target = p, headline = "New" })
    local dbuf, dline = run(capture.finalize, tb, { jump = false })
    eq({ "* Inbox", "** yy" }, buf_lines(tb))
    eq({ "* Elsewhere", "** Moved" }, utils.readfile(other))
    eq(vim.fn.resolve(other), vim.fn.resolve(vim.api.nvim_buf_get_name(dbuf)))
    eq(2, dline)
  end)
end)

describe("unnarrowed capture (:unnarrowed)", function()
  before_each(function()
    base_setup()
    vim.cmd("silent! only!")
  end)
  after_each(function()
    for buf in pairs(capture.sessions) do
      capture.kill(buf)
    end
  end)

  it("edits the text in the target buffer and finalizes in place", function()
    local p = tmpfile({ "* Inbox", "* Other" })
    local tb = utils.load_buffer(p)
    local calls = {}
    local tpl = {
      template = "* TODO %?\n  body",
      target = p,
      headline = "Inbox",
      unnarrowed = true,
      hook = function(b)
        calls[#calls + 1] = b
      end,
    }
    local buf, win = run(capture.capture, tpl)
    eq(tb, buf)
    ok(capture.sessions[tb].unnarrowed)
    eq({ tb }, calls)
    eq(tb, vim.api.nvim_win_get_buf(win))
    -- the whole target is visible and already holds the text
    eq({ "* Inbox", "** TODO ", "  body", "* Other" }, buf_lines(tb))
    eq(2, vim.api.nvim_win_get_cursor(win)[1])
    vim.api.nvim_buf_set_text(tb, 1, 8, 1, 8, { "Write tests" })
    run(capture.finalize, tb, { jump = false })
    eq(nil, capture.sessions[tb])
    ok(vim.api.nvim_buf_is_valid(tb))
    eq(false, vim.api.nvim_win_is_valid(win))
    eq({ "* Inbox", "** TODO Write tests", "  body", "* Other" }, utils.readfile(p))
    eq(false, vim.bo[tb].modified)
    -- the target's own keys are back
    eq(
      "org: Show all branches of subtree",
      vim.api.nvim_buf_call(tb, function()
        return vim.fn.maparg("<C-c><C-k>", "n", false, true).desc
      end)
    )
  end)

  it("aborts by removing exactly the captured lines and keeps unrelated edits", function()
    local p = tmpfile({ "* Inbox", "text", "* Other" })
    local tb = utils.load_buffer(p)
    run(capture.capture, { template = "* Note", target = p, headline = "New", unnarrowed = true, empty_lines = 1 })
    eq({ "* Inbox", "text", "* Other", "* New", "", "** Note", "" }, buf_lines(tb))
    -- the user edits the capture and, elsewhere, the rest of the file
    vim.api.nvim_buf_set_lines(tb, 5, 6, false, { "** Note edited", "more captured text" })
    vim.api.nvim_buf_set_lines(tb, 1, 2, false, { "changed text" })
    vim.api.nvim_buf_set_lines(tb, -1, -1, false, { "* Later unsaved work" })
    capture.kill(tb)
    eq(nil, capture.sessions[tb])
    eq({ "* Inbox", "changed text", "* Other", "* Later unsaved work" }, buf_lines(tb))
    eq({ "* Inbox", "text", "* Other" }, utils.readfile(p))
  end)

  it("restores the target's own mappings and calls them outside the capture window", function()
    local p = tmpfile({ "* Inbox" })
    local tb = utils.load_buffer(p)
    local hits = 0
    vim.keymap.set("n", "<C-c><C-k>", function()
      hits = hits + 1
    end, { buffer = tb, desc = "mine" })
    local _, win = run(capture.capture, { template = "* X", target = p, unnarrowed = true })
    local map = vim.api.nvim_buf_call(tb, function()
      return vim.fn.maparg("<C-c><C-k>", "n", false, true)
    end)
    eq("org: abort capture", map.desc)
    -- another window showing the target: the buffer's own mapping
    vim.cmd("split")
    vim.api.nvim_win_set_buf(0, tb)
    ok(vim.api.nvim_get_current_win() ~= win)
    map.callback()
    eq(1, hits)
    ok(capture.sessions[tb])
    -- the capture window: abort
    vim.api.nvim_set_current_win(win)
    map.callback()
    eq(nil, capture.sessions[tb])
    eq({ "* Inbox" }, buf_lines(tb))
    eq(
      "mine",
      vim.api.nvim_buf_call(tb, function()
        return vim.fn.maparg("<C-c><C-k>", "n", false, true).desc
      end)
    )
    vim.keymap.del("n", "<C-c><C-k>", { buffer = tb })
  end)

  it("maps the Ctrl keys in Insert mode too, and restores the target's own", function()
    local p = tmpfile({ "* Inbox" })
    local tb = utils.load_buffer(p)
    vim.keymap.set("i", "<C-c><C-k>", "mine", { buffer = tb, desc = "mine" })
    local function imap()
      return vim.api.nvim_buf_call(tb, function()
        return vim.fn.maparg("<C-c><C-k>", "i", false, true).desc
      end)
    end
    run(capture.capture, { template = "* X", target = p, unnarrowed = true })
    eq("org: abort capture", imap())
    vim.api.nvim_feedkeys(vim.keycode("A<C-c><C-k>"), "xt", false)
    eq(nil, capture.sessions[tb])
    eq({ "* Inbox" }, buf_lines(tb))
    eq("mine", imap())
    vim.keymap.del("i", "<C-c><C-k>", { buffer = tb })
    -- the prefix waits for the rest after a timeout, and is unmapped after
    run(capture.capture, { template = "* X", target = p, unnarrowed = true })
    local prefix = vim.api.nvim_buf_call(tb, function()
      return vim.fn.maparg("<C-c>", "i", false, true)
    end)
    eq("org: capture keys", prefix.desc)
    vim.api.nvim_feedkeys(vim.keycode("<C-k>"), "t", false)
    prefix.callback()
    eq(nil, capture.sessions[tb])
    eq({ "* Inbox" }, buf_lines(tb))
    eq(
      {},
      vim.api.nvim_buf_call(tb, function()
        return vim.fn.maparg("<C-c>", "i", false, true)
      end)
    )
  end)

  it("refiles the captured entry", function()
    local p = tmpfile({ "* Inbox" })
    local dest = tmpfile({ "* Projects" })
    local tb = utils.load_buffer(p)
    run(capture.capture, {
      template = "* Moved",
      target = p,
      unnarrowed = true,
      refile_targets = { { files = dest, level = 1 } },
    })
    eq({ "* Inbox", "* Moved" }, buf_lines(tb))
    local restore = answer({ 1 })
    run(capture.refile, tb)
    restore()
    eq({ "* Inbox" }, file_lines(p))
    eq({ "* Projects", "** Moved" }, file_lines(dest))
  end)

  it("ends the capture keeping the text when its window is closed", function()
    local p = tmpfile({ "* Inbox" })
    local tb = utils.load_buffer(p)
    local _, win = run(capture.capture, { template = "* Kept", target = p, unnarrowed = true })
    vim.api.nvim_win_close(win, true)
    eq(nil, capture.sessions[tb])
    eq({ "* Inbox", "* Kept" }, buf_lines(tb))
    eq(
      "org: Context action (C-c C-c)",
      vim.api.nvim_buf_call(tb, function()
        return vim.fn.maparg("<C-c><C-c>", "n", false, true).desc
      end)
    )
  end)

  it("keeps the capture open while its text is empty and places items and table lines", function()
    local p = tmpfile({ "* A", "- one" })
    local tb = utils.load_buffer(p)
    run(capture.capture, { type = "item", template = "- %?", target = p, headline = "A", unnarrowed = true })
    eq({ "* A", "- one", "- " }, buf_lines(tb))
    vim.api.nvim_buf_set_text(tb, 2, 0, 2, 2, { "" })
    eq(nil, (run(capture.finalize, tb, { jump = false })))
    ok(capture.sessions[tb])
    vim.api.nvim_buf_set_text(tb, 2, 0, 2, 0, { "- two" })
    run(capture.finalize, tb, { jump = false })
    eq({ "* A", "- one", "- two" }, utils.readfile(p))
    local p2 = tmpfile({ "* T", "| a | b |", "|---+---|" })
    local tb2 = utils.load_buffer(p2)
    local row = { type = "table-line", template = "| %? | y |", target = p2, headline = "T", unnarrowed = true }
    run(capture.capture, row)
    vim.api.nvim_buf_set_text(tb2, 3, 2, 3, 2, { "long" })
    run(capture.finalize, tb2, { jump = false })
    eq({ "* T", "| a    | b |", "|------+---|", "| long | y |" }, utils.readfile(p2))
  end)
end)

describe("capture and extend_today_until", function()
  before_each(function()
    base_setup()
  end)

  it("dates captures before extend_today_until o'clock on the previous day at 23:59", function()
    -- 24: every hour of the day still belongs to yesterday
    base_setup({ extend_today_until = 24 })
    local y = date.now():add(-1, "d"):clone({ hour = 23, min = 59 })
    local ymd = string.format("%04d-%02d-%02d", y.year, y.month, y.day)
    local text = run(capture.expand, "%T %U %t %<%Y-%m-%d %H:%M>", {})
    local expected = {
      y:clone({ active = true }):to_string(),
      y:clone({ active = false }):to_string(),
      y:clone({ active = true, hour = vim.NIL, min = vim.NIL }):to_string(),
      ymd .. " 23:59",
    }
    eq(table.concat(expected, " "), text)
    -- the date tree uses the same day (org-today)
    local p = tmpfile({})
    run(capture.capture, { target = p, datetree = true, template = "* J", immediate_finish = true })
    ok(vim.tbl_contains(file_lines(p), "*** " .. ymd .. " " .. date.DAY_NAMES_LONG[y:weekday()]))
  end)

  it("takes a capture date without a time at extend_today_until o'clock", function()
    base_setup({ extend_today_until = 4 })
    eq("<2026-09-20 Sun 04:00>", run(capture.expand, "%T", { date = date.parse("<2026-09-20 Sun>") }))
    eq("<2026-09-19 Sat 23:59>", run(capture.expand, "%T", { date = date.parse("<2026-09-20 Sun 03:00>") }))
    eq("<2026-09-20 Sun 12:00>", run(capture.expand, "%T", { date = date.parse("<2026-09-20 Sun 12:00>") }))
  end)

  it("uses the time prompt's date at 00:00, or now for today", function()
    local p = tmpfile({})
    local orig = require("org.calendar").pick
    require("org.calendar").pick = function()
      return date.parse("<2025-01-02 Thu>")
    end
    run(capture.capture, { target = p, time_prompt = true, template = "* %T", immediate_finish = true })
    require("org.calendar").pick = function()
      return date.today()
    end
    local now = date.now()
    run(capture.capture, { target = p, time_prompt = true, template = "* %U", immediate_finish = true })
    require("org.calendar").pick = orig
    eq({ "* <2025-01-02 Thu 00:00>", "* " .. now:clone({ active = false }):to_string() }, file_lines(p))
  end)
end)
