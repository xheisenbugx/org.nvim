local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local function setup(t)
  require("org").setup({
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
    extensions = t ~= nil and { transclusion = t } or nil,
  })
end

local keyword = require("org.extensions.transclusion.keyword")
local source = require("org.extensions.transclusion.source")
local highlight = require("org.extensions.transclusion.highlight")

local SRC = {
  "#+title: Source",
  "Intro before the first headline.",
  "* Alpha",
  "SCHEDULED: <2026-01-05 Mon>",
  ":PROPERTIES:",
  ":CUSTOM_ID: alpha",
  ":END:",
  "Alpha text with *bold* and [[https://example.org][a link]].",
  ":NOTES:",
  "A drawer.",
  ":END:",
  "#+caption: kept unless excluded",
  "** Alpha child",
  "Child text, see [[file:other.org][other]].",
  "* Beta",
  ":PROPERTIES:",
  ":ID: beta-id-1",
  ":END:",
  "Beta text.",
  "",
  "#+NAME: tbl",
  "| a | b |",
  "",
  "A paragraph with <<here>> a target",
  "on two lines.",
  "",
  "* Gamma",
}

local CODE = { "import os", "", "def f(x):", "    return x + 1", "", "def g():", "    pass", "# end" }

local dir

local function write(name, lines)
  vim.fn.writefile(lines, dir .. "/" .. name)
  return dir .. "/" .. name
end

local function spec(value)
  return assert(keyword.parse(value))
end

local function resolve(value, ctx)
  return source.resolve(spec(value), vim.tbl_extend("force", { dir = dir, filename = dir .. "/notes.org" }, ctx or {}))
end

local function virt_text(buf)
  local T = require("org.extensions.transclusion")
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, T.ns, 0, -1, { details = true })) do
    local lines = {}
    for _, vl in ipairs(m[4].virt_lines or {}) do
      local t = {}
      for _, c in ipairs(vl) do
        t[#t + 1] = c[1]
      end
      lines[#lines + 1] = table.concat(t)
    end
    if #lines > 0 then
      out[m[2] + 1] = lines
    end
  end
  return out
end

local function open_notes(lines)
  local path = write("notes.org", lines)
  vim.cmd("edit! " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf(), path
end

describe("transclusion keyword", function()
  it("parses the link and org-transclusion's properties", function()
    local s = spec('[[file:a.org::*Head][desc]] :level 2 :only-contents :exclude-elements "drawer keyword"')
    eq("file", s.type)
    eq("a.org", s.path)
    eq("*Head", s.search)
    eq(2, s.level)
    eq(true, s.only_contents)
    eq({ "drawer", "keyword" }, s.exclude)
    s = spec('[[file:code.py]] :lines 3-10 :src python :rest ":var x=1" :end "# end" :expand-links')
    eq("3-10", s.lines)
    eq("python", s.src)
    eq(":var x=1", s.rest)
    eq("# end", s.end_search)
    eq(true, s.expand_links)
    s = spec("[[id:abc]] :level :disable-auto :no-first-heading")
    eq("id", s.type)
    eq("abc", s.path)
    eq("auto", s.level)
    eq(true, s.disable_auto)
    eq(true, s.no_first_heading)
    eq(nil, s.only_contents)
    s = spec("[[*Local heading]]")
    eq("heading", s.type)
    eq("*Local heading", s.search)
    local nothing, err = keyword.parse("file:a.org")
    eq(nil, nothing)
    ok(err:find("link"))
  end)

  it("reads properties only after the link", function()
    local s = spec("[[file:a :level 3.org]]")
    eq(nil, s.level)
  end)

  it("finds keywords outside blocks", function()
    local kws = keyword.scan({
      "#+transclude: [[file:a.org]]",
      "#+begin_example",
      "#+transclude: [[file:b.org]]",
      "#+end_example",
      "  #+TRANSCLUDE: [[file:c.org]] :level 2",
    })
    eq(2, #kws)
    eq({ 1, "" }, { kws[1].row, kws[1].indent })
    eq({ 5, "  ", "[[file:c.org]] :level 2" }, { kws[2].row, kws[2].indent, kws[2].value })
  end)

  it("sets :level", function()
    eq("#+transclude: [[x]] :level 3", keyword.set_level("#+transclude: [[x]] :level 2", 3))
    eq("#+transclude: [[x]] :level 1", keyword.set_level("#+transclude: [[x]]", 1))
    eq("#+transclude: [[x]] :level 1", keyword.set_level("#+transclude: [[x]] :level", 0))
  end)
end)

describe("transclusion source", function()
  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    write("src.org", SRC)
    write("code.py", CODE)
    setup({ watch = false })
  end)

  after_each(function()
    setup()
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
  end)

  it("transcludes a subtree without its property drawer, at :level", function()
    local res = assert(resolve("[[file:src.org::*Alpha]] :level 2"))
    eq({
      "** Alpha",
      "SCHEDULED: <2026-01-05 Mon>",
      "Alpha text with *bold* and [[https://example.org][a link]].",
      ":NOTES:",
      "A drawer.",
      ":END:",
      "#+caption: kept unless excluded",
      "*** Alpha child",
      "Child text, see [[file:other.org][other]].",
    }, res.lines)
    eq("org", res.kind)
    eq({ 3, 14 }, { res.first, res.last })
    eq(SRC[4], res.raw[2])
    eq("src.org::*Alpha", res.label)
    ok(res.sources[dir .. "/src.org"])
  end)

  it("excludes elements, keeps only contents and drops the first heading", function()
    local res = assert(resolve('[[file:src.org::#alpha]] :exclude-elements "drawer keyword planning"'))
    eq({
      "* Alpha",
      "Alpha text with *bold* and [[https://example.org][a link]].",
      "** Alpha child",
      "Child text, see [[file:other.org][other]].",
    }, res.lines)
    res = assert(resolve('[[file:src.org::*Alpha]] :only-contents :exclude-elements "drawer keyword planning"'))
    eq(
      { "Alpha text with *bold* and [[https://example.org][a link]].", "Child text, see [[file:other.org][other]]." },
      res.lines
    )
    res = assert(resolve('[[file:src.org::*Alpha]] :no-first-heading :exclude-elements "drawer keyword planning"'))
    eq(
      { "Alpha text with *bold* and [[https://example.org][a link]].", "** Alpha child" },
      vim.list_slice(res.lines, 1, 2)
    )
  end)

  it("leaves out property drawers the way the element parser sees them", function()
    local lines = {
      "# comment",
      ":PROPERTIES:",
      ":ID: file-id",
      ":END:",
      "#+title: T",
      "* H",
      "SCHEDULED: <2026-01-05 Mon>",
      ":PROPERTIES:",
      ":A: 1",
      ":END:",
      "body",
      ":LOGBOOK:",
      "x",
      ":END:",
    }
    write("props.org", lines)
    local fast = assert(resolve("[[file:props.org]]"))
    eq({ "# comment", "#+title: T", "* H", "SCHEDULED: <2026-01-05 Mon>", "body" }, vim.list_slice(fast.lines, 1, 5))
    -- with another type, every element is parsed: the same drawers go
    local slow = assert(resolve('[[file:props.org]] :exclude-elements "no-such-type"'))
    eq(fast.lines, slow.lines)
  end)

  it("keeps the property drawer when exclude_elements is empty", function()
    setup({ watch = false, exclude_elements = {} })
    local res = assert(resolve("[[file:src.org::*Beta]]"))
    eq(":ID: beta-id-1", res.lines[3])
  end)

  it("puts :level auto one below the keyword's headline", function()
    local res = assert(resolve("[[file:src.org::*Alpha]] :level", { level = 2 }))
    eq("*** Alpha", res.lines[1])
    eq("**** Alpha child", res.lines[8])
    res = assert(resolve("[[file:src.org::*Alpha]] :level", { level = 0 }))
    eq("* Alpha", res.lines[1])
  end)

  it("finds ID, custom ID, #+NAME and <<target>> links", function()
    require("org.id").register("beta-id-1", dir .. "/src.org")
    local res = assert(resolve("[[id:beta-id-1]]"))
    eq({ "* Beta", "Beta text." }, vim.list_slice(res.lines, 1, 2))
    eq("id:beta-id-1", res.label)
    res = assert(resolve("[[file:src.org::tbl]]"))
    eq({ "#+NAME: tbl", "| a | b |" }, res.lines)
    res = assert(resolve("[[file:src.org::here]]"))
    eq({ "A paragraph with <<here>> a target", "on two lines." }, res.lines)
    local none, err = resolve("[[file:src.org::*Nope]]")
    eq(nil, none)
    ok(err:find("Nope"))
    none, err = resolve("[[id:no-such-id-xyz]]")
    eq(nil, none)
    ok(err:find("no%-such"))
  end)

  it("transcludes a whole file, with or without its first section", function()
    local res = assert(resolve("[[file:src.org]]"))
    eq("#+title: Source", res.lines[1])
    eq("* Gamma", res.lines[#res.lines])
    setup({ watch = false, include_first_section = false })
    res = assert(resolve("[[file:src.org]]"))
    eq("* Alpha", res.lines[1])
  end)

  it("expands relative file links with :expand-links", function()
    local res = assert(resolve("[[file:src.org::*Alpha]] :expand-links"))
    eq("Child text, see [[file:" .. vim.fs.normalize(dir) .. "/other.org][other]].", res.lines[#res.lines])
  end)

  it("transcludes lines of a code file, inclusive, in a src block", function()
    local res = assert(resolve("[[file:code.py]] :lines 3-4 :src python"))
    eq({ "#+begin_src python", "def f(x):", "    return x + 1", "#+end_src" }, res.lines)
    eq({ 3, 4 }, { res.first, res.last })
    eq({ "def f(x):", "    return x + 1" }, res.raw)
    eq("code.py:3-4", res.label)
    res = assert(resolve('[[file:code.py]] :src python :rest ":results output"'))
    eq("#+begin_src python :results output", res.lines[1])
    eq(#CODE + 2, #res.lines)
    res = assert(resolve("[[file:code.py]] :lines 6-"))
    eq({ "def g():", "    pass", "# end" }, res.lines)
    eq("text", res.kind)
    eq("python", res.lang)
    res = assert(resolve("[[file:code.py]] :lines -2"))
    eq({ "import os" }, res.lines)
  end)

  it("starts at a search and ends before :end", function()
    local res = assert(resolve('[[file:code.py::def f]] :end "def g"'))
    eq({ "def f(x):", "    return x + 1" }, res.lines)
    res = assert(resolve("[[file:code.py::def g]] :lines 1-2"))
    eq({ "def g():", "    pass" }, res.lines)
    -- a search without a range takes the text from its target to the end
    -- of the file, like org-transclusion-content-range-of-lines
    res = assert(resolve("[[file:code.py::def g]]"))
    eq({ 6, #CODE }, { res.first, res.last })
    eq({ "def g():", "    pass", "# end" }, res.lines)
    -- :end wins over the end of :lines, which applies when :end finds nothing
    res = assert(resolve('[[file:code.py]] :lines 3-4 :end "nothing like this"'))
    eq({ "def f(x):", "    return x + 1" }, res.lines)
    res = assert(resolve('[[file:code.py]] :lines 3-8 :end "def g"'))
    eq({ "def f(x):", "    return x + 1", "" }, res.raw)
  end)

  it("takes an Org file's :lines as they are, like org-transclusion", function()
    -- the lines of the file, drawers and levels untouched
    local res = assert(resolve("[[file:src.org::*Beta]] :lines 1-4 :level 3"))
    eq({ "* Beta", ":PROPERTIES:", ":ID: beta-id-1", ":END:" }, res.lines)
    eq("org", res.kind)
    res = assert(resolve("[[file:src.org]] :lines 3-4", { indent = "  " }))
    eq({ "  * Alpha", "  SCHEDULED: <2026-01-05 Mon>" }, res.lines)
    -- an ID link keeps its headlines at :level ("org-lines")
    require("org.id").register("beta-id-1", dir .. "/src.org")
    res = assert(resolve("[[id:beta-id-1]] :lines 1-2 :level 2"))
    eq({ "** Beta", ":PROPERTIES:" }, res.lines)
  end)

  it("transcludes a thing at point (:thing-at-point)", function()
    write("f.el", {
      "(defun f (x)",
      '  "Doc (with a paren."',
      "  (+ x 1))",
      "",
      "(defun g () nil)",
      "(defun h () t)",
    })
    local res = assert(resolve("[[file:f.el::defun f]] :thing-at-point sexp"))
    eq({ "(defun f (x)", '  "Doc (with a paren."', "  (+ x 1))" }, res.lines)
    eq({ 1, 3 }, { res.first, res.last })
    res = assert(resolve('[[file:f.el::defun g]] :thingatpt sexp :end "2"'))
    eq({ "(defun g () nil)", "(defun h () t)" }, res.lines)
    res = assert(resolve("[[file:code.py::def f]] :thing-at-point word :src python"))
    eq({ "#+begin_src python", "def", "#+end_src" }, res.lines)
    res = assert(resolve("[[file:code.py::def f]] :thing-at-point defun"))
    eq({ "def f(x):", "    return x + 1" }, res.lines)
    res = assert(resolve("[[file:code.py::import]] :thing-at-point paragraph"))
    eq({ "import os" }, res.lines)
    local none, err = resolve("[[file:code.py]] :thing-at-point frobnicate")
    eq(nil, none)
    ok(err:find("frobnicate"))
    local s = spec("[[file:f.el]] :thing-at-point defun")
    eq("defun", s.thing)
  end)

  it("transcludes a noweb chunk (:noweb-chunk)", function()
    write("prog.nw", {
      "Some text.",
      "<<setup>>=",
      "import os",
      "x = 1",
      "",
      "@ More text.",
      "<<main>>=",
      "print(x)",
      "",
      "",
    })
    local res = assert(resolve("[[file:prog.nw::setup]] :noweb-chunk :src python"))
    eq({ "#+begin_src python", "import os", "x = 1", "#+end_src" }, res.lines)
    res = assert(resolve("[[file:prog.nw::main]] :noweb-chunk"))
    eq({ "print(x)" }, res.lines)
    res = assert(resolve("[[file:prog.nw::setup]] :noweb-chunk :lines 2-5"))
    eq({ "x = 1" }, res.lines)
    local none, err = resolve("[[file:prog.nw::nope]] :noweb-chunk")
    eq(nil, none)
    ok(err:find("nope"))
    eq(true, spec("[[file:prog.nw::main]] :noweb-chunk").noweb_chunk)
  end)

  it("refuses binary files", function()
    local fd = assert(io.open(dir .. "/blob.bin", "wb"))
    fd:write("abc\0def\n")
    fd:close()
    local none, err = resolve("[[file:blob.bin]]")
    eq(nil, none)
    ok(err:find("binary"))
  end)

  it("reuses a result until one of its sources changes", function()
    local ctx = { dir = dir, filename = dir .. "/notes.org", level = 0, indent = "", depth = 0 }
    local s = spec("[[file:src.org::*Beta]]")
    local a = source.resolve_cached(s, ctx)
    local b = source.resolve_cached(s, ctx)
    ok(a == b)
    -- the file changes: a new result
    vim.wait(20)
    local lines = vim.deepcopy(SRC)
    lines[19] = "Beta changed."
    write("src.org", lines)
    local c = source.resolve_cached(s, ctx)
    ok(c ~= a)
    eq("Beta changed.", c.lines[2])
  end)

  it("indents text files like the keyword", function()
    local res = assert(resolve("[[file:code.py]] :lines 3-4", { indent = "  " }))
    eq({ "  def f(x):", "      return x + 1" }, res.lines)
  end)

  it("expands nested transclusions and stops at cycles", function()
    write("a.org", { "* A", "a text", "#+transclude: [[file:b.org]] :level", "* A2" })
    write("b.org", { "* B", "b text", "#+transclude: [[file:a.org]]" })
    local res = assert(resolve("[[file:a.org]]"))
    eq({ "* A", "a text", "** B", "b text", "#+transclude: [[file:a.org]]", "* A2" }, res.lines)
    eq(1, #res.errors)
    ok(res.errors[1]:find("recursive"))
    ok(res.sources[dir .. "/b.org"])
    setup({ watch = false, nested = false })
    res = assert(resolve("[[file:a.org]]"))
    eq("#+transclude: [[file:b.org]] :level", res.lines[3])
  end)

  it("stops at max_depth", function()
    write("d1.org", { "one", "#+transclude: [[file:d2.org]]" })
    write("d2.org", { "two", "#+transclude: [[file:d3.org]]" })
    write("d3.org", { "three" })
    setup({ watch = false, max_depth = 2 })
    local res = assert(resolve("[[file:d1.org]]"))
    eq({ "one", "two", "#+transclude: [[file:d3.org]]" }, res.lines)
    ok(res.errors[1]:find("max_depth"))
  end)

  it("reads a loaded source buffer, unsaved changes included", function()
    vim.cmd("edit " .. dir .. "/src.org")
    vim.api.nvim_buf_set_lines(0, 7, 8, false, { "Changed in the buffer." })
    local res = assert(resolve("[[file:src.org::*Alpha]]"))
    eq("Changed in the buffer.", res.lines[3])
  end)
end)

describe("transclusion highlight", function()
  it("colours org lines", function()
    local c = highlight.org({ "** TODO Title with [[x][desc]] :tag:", "#+title: T", "- item =code=" })
    eq({ "** ", "OrgHeadlineLevel2" }, c[1][1])
    eq({ "TODO", "OrgTodo" }, c[1][2])
    local texts = {}
    for _, ch in ipairs(c[1]) do
      texts[#texts + 1] = ch[1]
    end
    eq("** TODO Title with desc :tag:", table.concat(texts))
    eq({ " :tag:", "OrgTags" }, c[1][#c[1]])
    eq("OrgKeyword", c[2][1][2])
    eq("OrgTitle", c[2][2][2])
    eq({ "-", "OrgListBullet" }, { vim.trim(c[3][2][1]), c[3][2][2] })
    eq({ "=code=", "OrgVerbatim" }, c[3][#c[3]])
  end)

  it("keeps blocks and code plain without a parser", function()
    local c = highlight.org({ "#+begin_src nolang", "x = 1", "#+end_src" })
    eq("OrgBlockDelimiter", c[1][1][2])
    eq({ { "x = 1", "OrgBlock" } }, c[2])
    eq({ { { "a       b" } } }, highlight.code({ "a\tb" }, nil))
  end)

  it("marks up emphasis only at word boundaries", function()
    local c = highlight.inline("a*b* and *bold* 2*3", nil)
    local found = {}
    for _, ch in ipairs(c) do
      if ch[2] then
        found[#found + 1] = ch[1]
      end
    end
    eq({ "*bold*" }, found)
  end)
end)

describe("transclusion", function()
  local T = require("org.extensions.transclusion")

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    write("src.org", SRC)
    write("code.py", CODE)
    setup({ watch = false, debounce = 1 })
  end)

  after_each(function()
    setup()
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
  end)

  local NOTES = {
    "* Notes",
    "#+transclude: [[file:src.org::*Beta]] :level 2",
    "Between",
    "#+transclude: [[file:code.py]] :lines 3-4 :src python",
    "Tail",
  }

  it("is off unless enabled, and its export hook is inert then", function()
    setup()
    eq(nil, require("org.actions").list.transclusion_add)
    eq(nil, next(require("org.export.hooks").preprocessors))
    local buf = open_notes(NOTES)
    eq({}, vim.api.nvim_buf_get_extmarks(buf, T.ns, 0, -1, {}))
    -- the keyword is dropped by the exporter like any unknown keyword
    local out = require("org.export.ox").export_as("ascii", NOTES, { filename = dir .. "/notes.org" })
    ok(not out:find("Beta text", 1, true))
    setup({ watch = false })
    ok(require("org.actions").list.transclusion_add)
    ok(require("org.commands").extra.transclusion_insert)
    eq("<prefix>ua", require("org.config").opts.mappings.org.transclusion_add)
  end)

  it("draws virtual lines under the keywords without touching the buffer", function()
    local buf = open_notes(NOTES)
    local tick = vim.b[buf].changedtick
    eq(NOTES, buf_lines(buf))
    eq(tick, vim.b[buf].changedtick)
    local v = virt_text(buf)
    eq({ "│ ** Beta", "│ Beta text.", "│ ", "│ #+NAME: tbl" }, vim.list_slice(v[2], 1, 4))
    eq({ "│ #+begin_src python", "│ def f(x):", "│     return x + 1", "│ #+end_src" }, v[4])
    eq(false, vim.bo[buf].modified)
    local marks = vim.api.nvim_buf_get_extmarks(buf, T.ns, { 1, 0 }, { 1, -1 }, { details = true })
    ok(marks[1][4].virt_text[1][1]:find("src.org::*Beta", 1, true))
  end)

  it("shows errors as a virtual line", function()
    local buf = open_notes({ "#+transclude: [[file:src.org::*Missing]]" })
    ok(virt_text(buf)[1][1]:find("No match for heading: Missing", 1, true))
  end)

  it("leaves :disable-auto transclusions to transclusion_add", function()
    local buf = open_notes({ "#+transclude: [[file:src.org::*Beta]] :disable-auto" })
    eq({}, virt_text(buf))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    T.add()
    eq("* Beta", buf_lines(buf)[2])
  end)

  it("toggles, removes and refreshes virtual transclusions", function()
    local buf = open_notes(NOTES)
    T.toggle()
    eq({}, virt_text(buf))
    T.toggle()
    ok(virt_text(buf)[2])
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    T.remove()
    eq(nil, virt_text(buf)[2])
    ok(virt_text(buf)[4])
    T.refresh()
    ok(virt_text(buf)[2])
  end)

  it("hides the virtual lines of a folded keyword", function()
    local buf = open_notes(NOTES)
    vim.wo.foldenable = true
    vim.cmd("normal! zM")
    eq(1, vim.fn.foldclosed(2))
    -- virtual lines of a line in a closed fold take no screen rows
    eq(1, vim.api.nvim_win_text_height(0, { start_row = 0, end_row = 4 }).all)
    vim.cmd("normal! zR")
    ok(vim.api.nvim_win_text_height(0, { start_row = 0, end_row = 4 }).all > 10)
    eq(buf, vim.api.nvim_get_current_buf())
  end)

  it("inserts the text with transclusion_add and takes it out", function()
    local buf = open_notes(NOTES)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    T.add()
    local lines = buf_lines(buf)
    eq({ "** Beta", "Beta text." }, vim.list_slice(lines, 3, 4))
    eq(false, vim.bo[buf].modified)
    eq(nil, virt_text(buf)[2])
    local regs = T.regions(buf)
    eq(1, #regs)
    eq(2, regs[1].s)
    -- the cursor in the text belongs to the transclusion
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    eq(2, T.at_cursor(0).row)
    T.remove()
    eq(NOTES, buf_lines(buf))
    eq(0, #T.regions(buf))
    ok(virt_text(buf)[2])
  end)

  it("adds and removes them all", function()
    local buf = open_notes(NOTES)
    T.add_all(buf)
    local lines = buf_lines(buf)
    eq(2, #T.regions(buf))
    eq("#+begin_src python", lines[#lines - 4])
    local clean = T.clean_lines(buf)
    eq(NOTES, clean)
    T.remove_all(buf)
    eq(NOTES, buf_lines(buf))
  end)

  it("never writes inserted text to the file", function()
    local buf, path = open_notes(NOTES)
    T.add_all(buf)
    local shown = buf_lines(buf)
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "* Notes!" })
    vim.cmd("write")
    local disk = vim.fn.readfile(path)
    eq("* Notes!", disk[1])
    eq(vim.list_slice(NOTES, 2), vim.list_slice(disk, 2))
    shown[1] = "* Notes!"
    eq(shown, buf_lines(buf))
    eq(false, vim.bo[buf].modified)
    eq(2, #T.regions(buf))
  end)

  it("puts back text edited in place", function()
    local buf = open_notes(NOTES)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    T.add()
    local before = buf_lines(buf)
    vim.api.nvim_buf_set_text(buf, 3, 0, 3, 4, { "Edited" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    eq(before, buf_lines(buf))
    -- deleting the region's last lines doesn't eat the next line
    local n = #T.regions(buf)[1].data.lines
    vim.api.nvim_buf_set_lines(buf, 2 + n - 2, 2 + n, false, {})
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    eq(before, buf_lines(buf))
  end)

  it("removes the text with its keyword", function()
    local buf = open_notes(NOTES)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    T.add()
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    eq({ "* Notes", "Between" }, vim.list_slice(buf_lines(buf), 1, 2))
    eq(0, #T.regions(buf))
  end)

  it("forgets text deleted as a whole", function()
    local buf = open_notes(NOTES)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    T.add()
    local n = #T.regions(buf)[1].data.lines
    vim.api.nvim_buf_set_lines(buf, 2, 2 + n, false, {})
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    eq(0, #T.regions(buf))
    eq(NOTES, buf_lines(buf))
  end)

  it("takes back its text when a removal is undone", function()
    local buf = open_notes(NOTES)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    T.add()
    local shown = buf_lines(buf)
    local n = #T.regions(buf)[1].data.lines
    -- the text reappears without its marks
    vim.api.nvim_buf_set_lines(buf, 2, 2 + n, false, {})
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    vim.api.nvim_buf_set_lines(buf, 2, 2, false, vim.list_slice(shown, 3, 2 + n))
    T.render(buf)
    eq(1, #T.regions(buf))
    eq(NOTES, T.clean_lines(buf))
  end)

  it("inserts everything on open with mode = materialized", function()
    setup({ watch = false, mode = "materialized" })
    local buf = open_notes(NOTES)
    eq(2, #T.regions(buf))
    eq(false, vim.bo[buf].modified)
  end)

  it("shows nothing until asked with mode = false", function()
    setup({ watch = false, mode = false })
    local buf = open_notes(NOTES)
    eq({}, virt_text(buf))
    T.toggle()
    ok(virt_text(buf)[2])
  end)

  it("edits the source in a float and writes it back to the file", function()
    local buf = open_notes(NOTES)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    T.add()
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    local eb, win = T.edit()
    eq(eb, vim.api.nvim_get_current_buf())
    eq("editor", vim.api.nvim_win_get_config(win).relative)
    eq({ "* Beta", ":PROPERTIES:", ":ID: beta-id-1", ":END:", "Beta text." }, vim.list_slice(buf_lines(eb), 1, 5))
    eq("org", vim.bo[eb].filetype)
    vim.api.nvim_buf_set_lines(eb, 4, 5, false, { "Beta text, edited in the float." })
    vim.cmd("write")
    eq(false, vim.bo[eb].modified)
    eq("Beta text, edited in the float.", vim.fn.readfile(dir .. "/src.org")[19])
    -- the inserted copy follows
    eq("Beta text, edited in the float.", buf_lines(buf)[4])
    eq(false, vim.bo[buf].modified)
    vim.cmd.normal(vim.keycode("<Esc>"))
    eq(buf, vim.api.nvim_get_current_buf())
  end)

  it("edits code lines and a loaded source buffer", function()
    vim.cmd("edit " .. dir .. "/code.py")
    local code = vim.api.nvim_get_current_buf()
    local buf = open_notes(NOTES)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    local eb = T.edit()
    eq({ "def f(x):", "    return x + 1" }, buf_lines(eb))
    eq("python", vim.bo[eb].filetype)
    vim.api.nvim_buf_set_lines(eb, 1, 2, false, { "    return x + 2", "    # two" })
    vim.cmd("write")
    eq({ "def f(x):", "    return x + 2", "    # two" }, vim.api.nvim_buf_get_lines(code, 2, 5, false))
    eq(false, vim.bo[code].modified)
    eq("    return x + 2", vim.fn.readfile(dir .. "/code.py")[4])
    vim.cmd("close")
    eq("│     return x + 2", virt_text(buf)[4][3])
  end)

  it("refuses to write over a source that changed meanwhile", function()
    open_notes(NOTES)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    local eb = T.edit()
    write("code.py", { "totally", "different" })
    vim.api.nvim_buf_set_lines(eb, 0, 1, false, { "def f(y):" })
    local notified = {}
    local notify = vim.notify
    vim.notify = function(msg)
      notified[#notified + 1] = msg
    end
    vim.cmd("write")
    vim.notify = notify
    eq({ "totally", "different" }, vim.fn.readfile(dir .. "/code.py"))
    ok(notified[1]:find("changed"))
    eq(true, vim.bo[eb].modified)
    vim.cmd("close!")
  end)

  it("edits with <CR> on a keyword, and keeps <CR> elsewhere", function()
    local buf = open_notes(NOTES)
    local key = vim.fn.maparg("<CR>", "n", false, true)
    ok(key.desc and key.desc:find("transclusion"))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, true, true), "x", false)
    ok(vim.api.nvim_get_current_buf() ~= buf)
    ok(vim.api.nvim_buf_get_name(0):find("org%-transclusion://"))
    vim.cmd("close")
  end)

  it("redraws when a source buffer changes or is written", function()
    vim.cmd("edit " .. dir .. "/src.org")
    local src = vim.api.nvim_get_current_buf()
    local buf = open_notes(NOTES)
    vim.api.nvim_buf_set_lines(src, 18, 19, false, { "Beta, live." })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = src })
    vim.wait(500, function()
      return (virt_text(buf)[2] or {})[2] == "│ Beta, live."
    end)
    eq("│ Beta, live.", virt_text(buf)[2][2])
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    T.add()
    vim.api.nvim_buf_set_lines(src, 18, 19, false, { "Beta, written." })
    vim.api.nvim_buf_call(src, function()
      vim.cmd("silent write")
    end)
    eq("Beta, written.", buf_lines(buf)[4])
  end)

  it("watches files that are not loaded", function()
    setup({ watch = true, debounce = 1 })
    local buf = open_notes(NOTES)
    write("code.py", { "", "", "def f(z):", "    return z" })
    vim.wait(3000, function()
      return (virt_text(buf)[4] or {})[2] == "│ def f(z):"
    end)
    eq("│ def f(z):", virt_text(buf)[4][2])
  end)

  it("promotes and demotes with :level", function()
    local buf = open_notes(NOTES)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    T.demote()
    eq("#+transclude: [[file:src.org::*Beta]] :level 3", buf_lines(buf)[2])
    eq("│ *** Beta", virt_text(buf)[2][1])
    T.promote()
    T.promote()
    eq("#+transclude: [[file:src.org::*Beta]] :level 1", buf_lines(buf)[2])
    -- inserted text follows
    T.add()
    T.demote()
    eq("** Beta", buf_lines(buf)[3])
    eq(1, #T.regions(buf))
  end)

  it("detaches a copy", function()
    local buf = open_notes(NOTES)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    T.detach()
    eq(
      { "#+begin_src python", "def f(x):", "    return x + 1", "#+end_src", "Tail" },
      vim.list_slice(buf_lines(buf), 4)
    )
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    T.add()
    T.detach()
    eq("** Beta", buf_lines(buf)[2])
    eq(0, #T.regions(buf))
    eq(true, vim.bo[buf].modified)
  end)

  it("makes a keyword from a link and from :Org transclusion_insert", function()
    local buf = open_notes({ "See [[file:src.org::*Beta][beta]]." })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    T.make_from_link()
    eq("#+transclude: [[file:src.org::*Beta][beta]]", buf_lines(buf)[2])
    ok(virt_text(buf)[2])
    T.insert_command("file:code.py :lines 1-1")
    eq("#+transclude: [[file:code.py]] :lines 1-1", buf_lines(buf)[3])
    eq({ "│ import os" }, virt_text(buf)[3])
  end)

  it("opens the source", function()
    open_notes(NOTES)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    T.open_source()
    eq(vim.uv.fs_realpath(dir .. "/src.org"), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)))
    eq(15, vim.api.nvim_win_get_cursor(0)[1])
    vim.cmd("close")
  end)

  it("transcludes a heading of the same buffer", function()
    local buf = open_notes({ "* Target", "target text", "* Other", "#+transclude: [[*Target]] :level 2" })
    eq({ "│ ** Target", "│ target text" }, virt_text(buf)[4])
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    T.add()
    -- the materialized copy doesn't feed itself
    T.refresh()
    eq({ "** Target", "target text" }, vim.list_slice(buf_lines(buf), 5))
  end)

  it("expands keywords on export, once, and skips :disable-auto", function()
    local buf =
      open_notes(vim.list_extend(vim.deepcopy(NOTES), { "#+transclude: [[file:src.org::*Gamma]] :disable-auto" }))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    T.add()
    local out =
      require("org.export.ox").export_as("ascii", buf_lines(buf), { filename = dir .. "/notes.org", bufnr = buf })
    local _, count = out:gsub("Beta text%.", "")
    eq(1, count)
    ok(out:find("return x + 1", 1, true))
    ok(not out:find("Gamma", 1, true))
    setup({ watch = false, export = false })
    out = require("org.export.ox").export_as("ascii", NOTES, { filename = dir .. "/notes.org" })
    ok(not out:find("Beta text", 1, true))
  end)

  it("tells other extensions which lines are inserted (ranges)", function()
    local buf = open_notes(NOTES)
    eq({}, T.ranges(buf))
    T.add_all(buf)
    local n = #source.resolve(spec("[[file:src.org::*Beta]] :level 2"), { dir = dir, level = 1 }).lines
    eq({
      { first = 3, last = 2 + n, keyword = 2 },
      { first = 5 + n, last = 8 + n, keyword = 4 + n },
    }, T.ranges(0))
    T.remove_all(buf)
    eq({}, T.ranges(buf))
    setup()
    eq({}, T.ranges(buf))
  end)

  it("completes :Org transclusion_insert", function()
    open_notes(NOTES)
    local c = require("org.commands").complete
    local got = c("file:sr", "Org transclusion_insert file:sr")
    eq({ "file:src.org" }, got)
    got = c("[[file:co", "Org transclusion_insert [[file:co")
    eq({ "[[file:code.py" }, got)
    got = c(":l", "Org transclusion_insert [[file:code.py]] :l")
    eq({ ":level", ":lines" }, got)
    got = c(":", "Org transclusion_insert [[file:code.py]] :lines 1-2 :")
    ok(not vim.tbl_contains(got, ":lines"))
    ok(vim.tbl_contains(got, ":src"))
  end)

  it("closes the edit float with <Esc>, not over unwritten edits", function()
    local buf = open_notes(NOTES)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    local eb = T.edit()
    eq("", vim.fn.maparg("q", "n"))
    vim.api.nvim_buf_set_lines(eb, 0, 1, false, { "def f(y):" })
    local msgs = {}
    local notify = vim.notify
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    vim.cmd.normal(vim.keycode("<Esc>"))
    vim.notify = notify
    eq(eb, vim.api.nvim_get_current_buf())
    ok(msgs[1]:find("Unsaved"))
    ok(vim.api.nvim_win_get_config(0).title[1][1]:find("<Esc> closes", 1, true))
    vim.cmd("silent write")
    vim.cmd.normal(vim.keycode("<Esc>"))
    eq(buf, vim.api.nvim_get_current_buf())
    eq("def f(y):", vim.fn.readfile(dir .. "/code.py")[3])
  end)

  it("syncs the source while typing with edit.live", function()
    setup({ watch = false, debounce = 1, edit = { live = true } })
    local buf = open_notes(NOTES)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    local eb = T.edit()
    vim.api.nvim_buf_set_lines(eb, 1, 2, false, { "    return x * 2" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = eb })
    vim.wait(1000, function()
      return (virt_text(buf)[4] or {})[3] == "│     return x * 2"
    end)
    eq("│     return x * 2", virt_text(buf)[4][3])
    -- the source buffer follows, the file only on :w
    local sb = vim.fn.bufnr(dir .. "/code.py")
    ok(sb > 0)
    eq("    return x * 2", vim.api.nvim_buf_get_lines(sb, 3, 4, false)[1])
    eq(CODE[4], vim.fn.readfile(dir .. "/code.py")[4])
    vim.cmd("silent write")
    eq("    return x * 2", vim.fn.readfile(dir .. "/code.py")[4])
    eq(false, vim.bo[sb].modified)
    vim.cmd.normal(vim.keycode("<Esc>"))
  end)

  it("ignores keywords inside blocks, for keys and actions too", function()
    local buf = open_notes({ "#+begin_example", "#+transclude: [[file:src.org::*Beta]]", "#+end_example" })
    eq({}, virt_text(buf))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eq(nil, T.at_cursor(0))
    local msgs = {}
    local notify = vim.notify
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    T.add()
    vim.notify = notify
    eq(3, #buf_lines(buf))
    ok(msgs[1]:find("Not on"))
  end)

  it("inserted text follows an edited keyword", function()
    local buf = open_notes(NOTES)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    T.add()
    eq("#+begin_src python", buf_lines(buf)[5])
    -- edited in place (:s, cw, typing): the keyword line stays
    vim.cmd("4s/ :lines 3-4 :src python/ :lines 1-1/")
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    T.render(buf)
    eq({ "import os", "Tail" }, vim.list_slice(buf_lines(buf), 5))
    eq(1, #T.regions(buf))
    eq(NOTES[1], T.clean_lines(buf)[1])
  end)

  it("survives its source being deleted", function()
    local buf = open_notes(NOTES)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    T.add()
    local shown = buf_lines(buf)
    vim.fn.delete(dir .. "/code.py")
    vim.fn.delete(dir .. "/src.org")
    T.refresh()
    -- the inserted copy stays; the virtual one reports the missing file
    eq(shown, buf_lines(buf))
    ok(virt_text(buf)[2][1]:find("Cannot read", 1, true))
  end)

  it("reports a transclusion cycle in one buffer", function()
    local buf = open_notes({
      "* A",
      "#+transclude: [[*B]]",
      "* B",
      "#+transclude: [[*A]]",
    })
    local v = virt_text(buf)
    ok(table.concat(v[2], "\n"):find("recursive", 1, true))
  end)

  it("transcludes its own file without feeding itself", function()
    local buf, path = open_notes({ "* Self", "text", "#+transclude: [[file:notes.org]]" })
    local v = virt_text(buf)[3]
    eq({ "│ * Self", "│ text", "│ #+transclude: file:notes.org" }, vim.list_slice(v, 1, 3))
    ok(table.concat(v, "\n"):find("recursive", 1, true))
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    T.add()
    eq({ "* Self", "text", "#+transclude: [[file:notes.org]]" }, vim.list_slice(buf_lines(buf), 4, 6))
    -- the inserted keyword is text, not a transclusion of its own
    eq(1, #T.regions(buf))
    vim.cmd("silent write")
    eq({ "* Self", "text", "#+transclude: [[file:notes.org]]" }, vim.fn.readfile(path))
  end)

  it("watches one directory for many sources and closes it when done", function()
    setup({ watch = true, debounce = 1 })
    for i = 1, 5 do
      write("s" .. i .. ".org", { "* H", "text " .. i })
    end
    local lines = {}
    for i = 1, 5 do
      lines[#lines + 1] = "#+transclude: [[file:s" .. i .. ".org]]"
    end
    local buf = open_notes(lines)
    eq(1, T.watch_count())
    vim.cmd("bwipeout! " .. buf)
    vim.wait(100, function()
      return T.watch_count() == 0
    end)
    eq(0, T.watch_count())
    open_notes(lines)
    eq(1, T.watch_count())
    setup()
    eq(0, T.watch_count())
  end)

  it("redraws only the transclusions whose source changed", function()
    local buf = open_notes(NOTES)
    local function ids()
      local out = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, T.ns, 0, -1, {})) do
        out[m[2] + 1] = m[1]
      end
      return out
    end
    local before = ids()
    vim.wait(20)
    write("code.py", { "", "", "def f(z):", "    return z" })
    T.refresh_dependents(dir .. "/code.py")
    local after = ids()
    eq(before[2], after[2])
    ok(before[4] ~= after[4])
    eq("│ def f(z):", virt_text(buf)[4][2])
    -- nothing changed: nothing is drawn again
    T.render(buf)
    eq(after, ids())
  end)

  it("redraws when a source reached through a symbolic link is written", function()
    local link = dir .. "-link"
    assert(vim.uv.fs_symlink(dir, link))
    -- the keyword names the file through the link, the buffer by its real path
    local buf = open_notes({ "", "", "", "#+transclude: [[file:" .. link .. "/code.py]] :lines 3-4" })
    vim.cmd("split " .. dir .. "/code.py")
    vim.api.nvim_buf_set_lines(0, 3, 4, false, { "    return 42" })
    vim.cmd("silent write")
    vim.cmd("close")
    eq("│     return 42", virt_text(buf)[4][2])
    vim.uv.fs_unlink(link)
  end)

  it("reports an error in a timer or watcher once", function()
    local msgs = {}
    local notify = vim.notify
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    for _ = 1, 3 do
      T.later("boom", function()
        error("kaboom")
      end)
      vim.wait(50)
    end
    vim.notify = notify
    local n = 0
    for _, m in ipairs(msgs) do
      if m:find("kaboom") then
        n = n + 1
      end
    end
    eq(1, n)
  end)

  it("exports a buffer with inserted text once, from its clean lines", function()
    local buf = open_notes(NOTES)
    T.add_all(buf)
    local out =
      require("org.export.ox").export_as("ascii", buf_lines(buf), { filename = dir .. "/notes.org", bufnr = buf })
    local _, count = out:gsub("Beta text%.", "")
    eq(1, count)
    local _, py = out:gsub("return x %+ 1", "")
    eq(1, py)
  end)

  it("removes inserted text, marks and keys when turned off", function()
    local buf = open_notes(NOTES)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    T.add()
    setup()
    eq(NOTES, buf_lines(buf))
    eq({}, vim.api.nvim_buf_get_extmarks(buf, T.ns, 0, -1, {}))
    local key = vim.fn.maparg("<CR>", "n", false, true)
    ok(not (key.desc or ""):find("transclusion"))
    eq(0, #vim.api.nvim_get_autocmds({ group = "OrgTransclusion" }))
    eq(nil, next(require("org.export.hooks").preprocessors))
  end)
end)
