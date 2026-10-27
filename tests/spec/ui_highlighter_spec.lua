-- ui.highlighter = "parser": emphasis and the hidden parts of links drawn
-- by the decorations (org.ui.emphasis) instead of syntax regions. What it
-- draws is checked against Emacs in emacs_fontify_parity_spec.lua; this
-- spec checks the rest: no syntax regions, no 'synmaxcol' limit, spelling,
-- the toggles, the cursor and drawing any part of a buffer alone.
local fuzz = require("tests.helpers.fuzz")
local hl = require("tests.helpers.highlighter")

local deco = require("org.ui.decorations")

--- The marks the decorations draw on 0-based row `row`, as
--- "group@start-end" (or "conceal@..."), sorted.
local function marks(buf, row)
  local out = {}
  for _, m in ipairs(deco.line_marks(buf, row)) do
    local o = m[2]
    -- (orgSrcBlock: the block part's mark under a src block's body, with
    -- no attributes; this spec is about emphasis and links)
    for _, name in ipairs({
      o.hl_group ~= "orgSrcBlock" and o.hl_group or false,
      o.conceal == "" and "conceal" or false,
    }) do
      if name then
        out[#out + 1] = string.format("%s@%d-%d", name, m[1], o.end_col or m[1] + 1)
      end
    end
  end
  table.sort(out)
  return out
end

local function has(list, item)
  return vim.tbl_contains(list, item)
end

describe("ui.highlighter = parser", function()
  with_config({ ui = { highlighter = "parser", hide_emphasis_markers = true } })

  it("defines no emphasis regions and draws the emphasis as marks", function()
    local buf = org_buffer({ "a *bold* and =code= x" }, { 1, 0 })
    for c = 1, 21 do
      for _, id in ipairs(vim.fn.synstack(1, c)) do
        ok(not vim.fn.synIDattr(id, "name"):find("^org[BVC][oe]"), vim.fn.synIDattr(id, "name"))
      end
    end
    local m = marks(buf, 0)
    ok(has(m, "orgBold@3-7"), vim.inspect(m))
    ok(has(m, "orgBoldDelimiter@2-3") and has(m, "orgBoldDelimiter@7-8"), vim.inspect(m))
    ok(has(m, "conceal@2-3") and has(m, "conceal@7-8"), vim.inspect(m))
    ok(has(m, "orgVerbatim@14-18"), vim.inspect(m))
  end)

  it("hides link brackets with marks, not with the syntax", function()
    local buf = org_buffer({ "see [[https://x.org][site]] end" }, { 1, 0 })
    vim.wo.conceallevel = 2
    for c = 1, 31 do
      eq(0, vim.fn.synconcealed(1, c)[1])
    end
    -- (the link's face is a mark too: org.ui.highlight.object)
    local function hidden()
      return vim.tbl_filter(function(m)
        return m:find("^conceal@") ~= nil
      end, marks(buf, 0))
    end
    eq({ "conceal@25-27", "conceal@4-21" }, hidden())
    ok(has(marks(buf, 0), "orgLink@4-27"))
    -- org-toggle-link-display: shown literally
    require("org.links").toggle_link_display()
    eq({}, hidden())
    require("org.links").toggle_link_display()
    eq({ "conceal@25-27", "conceal@4-21" }, hidden())
  end)

  it("draws markup past 'synmaxcol' and on very long lines", function()
    local long = string.rep("word ", 20000) .. "*bold* end"
    local buf = org_buffer({ long, "next *b*" }, { 1, 0 })
    ok(vim.bo.synmaxcol > 0 and vim.bo.synmaxcol < #long)
    local m = marks(buf, 0)
    ok(has(m, string.format("orgBold@%d-%d", 100001, 100005)), vim.inspect(m))
    ok(has(marks(buf, 1), "orgBold@6-7"))
  end)

  it("draws a long line full of unclosed markers in linear time", function()
    local function time(n)
      local buf = org_buffer({ string.rep("*a /b _c =d ", n) }, { 1, 0 })
      local t = vim.uv.hrtime()
      marks(buf, 0)
      return (vim.uv.hrtime() - t) / 1e6
    end
    time(100)
    local small, big = time(2000), time(20000)
    -- ten times the text, well under a hundred times the time
    ok(big < math.max(small, 1) * 40, string.format("%.1f ms then %.1f ms", small, big))
  end)

  it("leaves verbatim and code out of spell checking", function()
    local buf = org_buffer({ "*bold* =verbatim= ~code~" }, { 1, 0 })
    for _, m in ipairs(deco.line_marks(buf, 0)) do
      local g = m[2].hl_group or ""
      if g:find("^orgVerbatim") or g:find("^orgCode") then
        eq(false, m[2].spell)
      elseif g:find("^orgBold") then
        eq(nil, m[2].spell)
      end
    end
  end)

  it("follows b:org_hide_emphasis_markers (presentation slides)", function()
    local buf = org_buffer({ "a *b* c" }, { 1, 0 })
    ok(has(marks(buf, 0), "conceal@2-3"))
    vim.b[buf].org_hide_emphasis_markers = false
    deco.render(buf)
    ok(not has(marks(buf, 0), "conceal@2-3"))
    ok(has(marks(buf, 0), "orgBoldDelimiter@2-3"))
  end)

  it("draws nothing in a src block that starts far above the window", function()
    local lines = { "* H", "#+begin_src lua" }
    for i = 1, 400 do
      lines[#lines + 1] = "x = *a* -- [[l]] " .. i
    end
    lines[#lines + 1] = "#+end_src"
    lines[#lines + 1] = "*after*"
    local buf = org_buffer(lines, { 1, 0 })
    eq({}, marks(buf, 300))
    eq({}, marks(buf, 401))
    ok(has(marks(buf, #lines - 1), "orgBold@1-6"))
  end)

  it("draws a row alone as it draws it with the whole buffer", function()
    -- the scan starts two lines above the rows asked for, in the block
    -- state there: any row drawn alone gets the marks it gets in a scan of
    -- the whole buffer
    local E = require("org.ui.emphasis")
    for _, seed in ipairs(fuzz.seeds(12)) do
      local rng = fuzz.rng(seed)
      local lines = fuzz.doc(rng)
      local opts = { hide_markers = true, conceal_links = true }
      local whole = {}
      E.marks(lines, 0, 0, #lines - 1, opts, whole)
      local buf = org_buffer(lines, { 1, 0 })
      for row = 0, #lines - 1 do
        local alone = {}
        E.add_marks(buf, row, row, require("org.config").opts.ui, alone)
        local function key(t)
          local out = {}
          for _, m in ipairs(t or {}) do
            out[#out + 1] = m[1] .. ":" .. vim.inspect(m[2], { newline = "", indent = "" })
          end
          table.sort(out)
          return table.concat(out, " ")
        end
        if key(whole[row]) ~= key(alone[row]) then
          error(fuzz.report(seed, "row " .. row .. " drawn alone differs", lines, lines))
        end
      end
    end
  end)

  it("draws a row alone like the whole buffer: links over lines, blocks far up", function()
    local E = require("org.ui.emphasis")
    local cases = {
      { "a", "see [[a][first", "second", "third", "fourth]] end", "b" },
      { "x [[a][b", "* H2", "c]] y" },
    }
    -- a src block with no headline within the look back
    local far = {}
    for i = 1, 3100 do
      far[i] = "text " .. i
    end
    vim.list_extend(far, { "#+begin_src python", "x = '*y*'", "x = '*y*'", "x = '*y*'", "#+end_src", "*z*" })
    cases[#cases + 1] = far
    for _, lines in ipairs(cases) do
      local whole = {}
      E.marks(lines, 0, 0, #lines - 1, { hide_markers = true, conceal_links = true }, whole)
      local buf = org_buffer(lines, { 1, 0 })
      for row = math.max(0, #lines - 8), #lines - 1 do
        local alone = {}
        E.add_marks(buf, row, row, require("org.config").opts.ui, alone)
        eq(vim.inspect(whole[row]), vim.inspect(alone[row]), "row " .. row .. ": " .. lines[row + 1])
      end
    end
  end)

  it("moves the cursor over hidden markers and link brackets", function()
    vim.cmd("syntax on")
    local function press(keys)
      vim.cmd("normal! " .. keys)
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
    end
    local function col()
      return vim.api.nvim_win_get_cursor(0)[2]
    end
    org_buffer({ "See [[https://example.org][the site]] end" }, { 1, 2 })
    eq(2, vim.wo.conceallevel)
    -- "See " 0-3, "[[https://example.org][" 4-26, "the site" 27-34
    press("l")
    eq(3, col())
    press("l")
    eq(27, col())
    org_buffer({ "a *bold* b" }, { 1, 0 })
    vim.wo.conceallevel = 2
    press("l")
    press("l")
    eq(3, col())
  end)

  it("is turned on and off by b:org_ui", function()
    require("org.config").opts.ui.highlighter = "syntax"
    local buf = org_buffer({ "a *b* c" }, { 1, 0 })
    hl.use(buf, "syntax")
    eq({}, marks(buf, 0))
    local found = false
    for _, id in ipairs(vim.fn.synstack(1, 4)) do
      found = found or vim.fn.synIDattr(id, "name"):lower() == "orgbold"
    end
    ok(found)
    vim.cmd("enew!")
    local b2 = vim.api.nvim_get_current_buf()
    vim.bo[b2].bufhidden = "wipe"
    vim.b[b2].org_ui = { highlighter = "parser" }
    vim.api.nvim_buf_set_lines(b2, 0, -1, false, { "a *b* c" })
    vim.bo[b2].filetype = "org"
    ok(has(marks(b2, 0), "orgBold@3-4"), vim.inspect(marks(b2, 0)))
    require("org.config").opts.ui.highlighter = "parser"
  end)

  it("leaves the syntax regions to a buffer with only the org syntax (drill)", function()
    vim.cmd("enew!")
    local b = vim.api.nvim_get_current_buf()
    vim.bo[b].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "A *bold* word" })
    vim.bo[b].filetype = "org_drill"
    vim.bo[b].syntax = "org"
    local names = vim.tbl_map(function(id)
      return vim.fn.synIDattr(id, "name"):lower()
    end, vim.fn.synstack(1, 4))
    ok(vim.tbl_contains(names, "orgbold"), vim.inspect(names))
  end)

  it("gives a LaTeX preview with foreground auto the emphasis color", function()
    require("org.config").opts.ui.latex_preview = { foreground = "auto" }
    vim.api.nvim_set_hl(0, "OrgBold", { fg = "#ff0000", bold = true })
    local buf = org_buffer({ "text *bold $x^2$ here* end" }, { 1, 0 })
    eq("1.000,0.000,0.000", require("org.ui.images")._foreground(buf, 0, 11))
    require("org.config").opts.ui.latex_preview = nil
  end)

  -- (structure_features_spec.lua checks the syntax engine's regions)
  it("spans emphasis over one newline, not two, and not after [", function()
    org_buffer({ "x *multi", "line* y", "[*x*] z", "x *a", "b", "c* d", "*b /it/ c*" }, { 1, 0 })
    ok(hl.has(1, 5, "orgbold"), hl.groups(1, 5))
    ok(hl.has(2, 2, "orgbold"), hl.groups(2, 2))
    eq("", hl.groups(3, 3))
    eq("", hl.groups(4, 4))
    ok(hl.has(7, 5, "orgitalic") and hl.has(7, 5, "orgbold"), hl.groups(7, 5))
  end)

  -- (ui_spec.lua checks the syntax engine's)
  it("shows only the description of a link, or its target without one", function()
    local function shown(text)
      org_buffer({ text }, { 1, 0 })
      vim.wo.conceallevel = 2
      local out = {}
      for c = 1, #text do
        if not hl.has(1, c, "conceal") then
          out[#out + 1] = text:sub(c, c)
        end
      end
      return table.concat(out)
    end
    eq("3. this is something else", shown("3. this is [[https://www.google.com][something else]]"))
    eq("* TODO see Link :tag:", shown("* TODO see [[file:a.org::*x][Link]] :tag:"))
    eq("| cell H | b |", shown("| cell [[*Heading][H]] | b |"))
    eq("no desc https://example.com end", shown("no desc [[https://example.com]] end"))
  end)

  it("the test helper sees the same on both sides of a plain case", function()
    local buf = org_buffer({ "*a* /b/ =c=" }, { 1, 0 })
    vim.wo.conceallevel = 2
    eq(hl.emacs_codes(buf, "syntax"), hl.emacs_codes(buf, "parser"))
    hl.use(buf, "parser")
  end)
end)

-- The emphasis cases of ui_syntax_highlighting_spec.lua ("ui syntax:
-- emphasis", the syntax engine), with the parser highlighter.
describe("ui.highlighter = parser: emphasis", function()
  with_highlighter("parser")
  before_each(function()
    require("org.config").opts.ui.hide_emphasis_markers = true
  end)
  after_each(function()
    require("org.config").opts.ui.hide_emphasis_markers = false
  end)

  local function col(l, s)
    return assert(vim.fn.getline(l):find(s, 1, true), s)
  end

  -- org-emphasis-regexp-components: only blanks are forbidden borders
  it("allows quotes and commas at the borders", function()
    org_buffer({ [[~'symbol~ and ="quoted"= and =,= and *'q'*]] }, { 1, 0 })
    vim.wo.conceallevel = 2
    ok(hl.has(1, 2, "orgcode"), hl.groups(1, 2))
    ok(hl.has(1, col(1, '"quoted') + 1, "orgverbatim"), hl.groups(1, 16))
    ok(hl.has(1, col(1, "=,=") + 1, "orgverbatim"), hl.groups(1, col(1, "=,=") + 1))
    ok(hl.has(1, col(1, "*'q") + 1, "orgbold"), hl.groups(1, col(1, "*'q") + 1))
    ok(hl.has(1, 1, "conceal"), hl.groups(1, 1))
  end)

  -- org-element-paragraph-separate
  it("doesn't continue onto a list item, table row or keyword line", function()
    org_buffer({ "some *text", "- item* more", "", "other /text", "| x/ y |", "", "x _a", "#+KEY: b_ c" }, { 1, 0 })
    ok(not hl.has(1, 7, "orgbold"), hl.groups(1, 7))
    ok(not hl.has(2, 3, "orgbold"), hl.groups(2, 3))
    ok(not hl.has(4, 8, "orgitalic"), hl.groups(4, 8))
    ok(not hl.has(7, 4, "orgunderline"), hl.groups(7, 4))
    ok(not hl.has(1, 6, "conceal"), hl.groups(1, 6))
  end)

  it("continues onto the next line of the paragraph", function()
    org_buffer({ "para *bold", "continues here* ok" }, { 1, 0 })
    ok(hl.has(1, 7, "orgbold"), hl.groups(1, 7))
    ok(hl.has(2, 1, "orgbold"), hl.groups(2, 1))
  end)

  -- org-emph-re needs a non-empty text: "==" is no empty markup
  it("doesn't make an empty emphasis of doubled markers", function()
    org_buffer({ "Compare a == b and later x =y= z.", "A // comment and later a/b/ c" }, { 1, 0 })
    ok(not hl.has(1, 11, "orgverbatim") and not hl.has(1, 12, "conceal"), hl.groups(1, 12))
    ok(hl.has(1, 14, "orgverbatim"), hl.groups(1, 14))
    ok(hl.has(2, 5, "orgitalic"), hl.groups(2, 5))
  end)

  it("highlights all markup in list terms", function()
    org_buffer({ "- term +s+ _u_ :: def", "- [[https://example.com][Example]] :: def", "- =v= :: d" }, { 1, 0 })
    ok(hl.has(1, 9, "orgstrikethrough"), hl.groups(1, 9))
    ok(hl.has(1, 13, "orgunderline"), hl.groups(1, 13))
    ok(hl.has(2, 30, "orglistterm"), hl.groups(2, 30))
    ok(hl.has(3, 4, "orglistterm") and hl.has(3, 4, "orgverbatim"), hl.groups(3, 4))
  end)

  -- Emacs refontifies multi-line emphasis (font-lock-multiline)
  it("redraws the line above when a two-line emphasis is closed", function()
    local buf = org_buffer({ "para *bold", "continues here", "third" }, { 1, 0 })
    vim.wo.conceallevel = 2
    vim.cmd("redraw")
    local before = vim.fn.screenattr(1, 7)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.api.nvim_buf_set_text(buf, 1, 14, 1, 14, { "*" })
    vim.cmd("redraw")
    local a, s = vim.fn.screenattr(1, 6), vim.fn.screenstring(1, 6)
    ok(a ~= before, "the first line is drawn bold")
    vim.cmd("redraw!")
    eq(vim.fn.screenattr(1, 6), a)
    eq(vim.fn.screenstring(1, 6), s)
  end)

  -- E363 / 'redrawtime' on paragraph lines with many unclosed markers
  it("draws long lines full of markers quickly", function()
    local msgs = {}
    for _, line in ipairs({ string.rep("/x ", 320), string.rep("*a *b ", 100), string.rep("call *args and **kw, ", 50) }) do
      org_buffer({ "* Head", line, "after *bold* text", "* TODO second *bold*" }, { 1, 0 })
      vim.cmd("messages clear")
      local t = vim.uv.hrtime()
      local okr, err = pcall(vim.cmd, "redraw!")
      ok(okr, tostring(err))
      ok((vim.uv.hrtime() - t) / 1e6 < 500, "slow redraw")
      ok(hl.has(4, 3, "orgtodo"), hl.groups(4, 3))
      ok(hl.has(3, 8, "orgbold"), hl.groups(3, 8))
      msgs[#msgs + 1] = vim.api.nvim_exec2("messages", { output = true }).output
    end
    ok(not table.concat(msgs):find("redrawtime"))
  end)
end)

-- What syntax_long_lines_spec.lua checks of the syntax engine on long
-- lines, with the parser highlighter: the same faces, and none of the
-- limits ('synmaxcol', 'maxmempattern', 'redrawtime').
describe("ui.highlighter = parser: long lines", function()
  with_highlighter("parser")
  local gen = require("tests.helpers.gen")
  local mmp, rdt, smc
  before_each(function()
    mmp, rdt, smc = vim.o.maxmempattern, vim.o.redrawtime, vim.go.synmaxcol
    vim.o.maxmempattern = 1000
    vim.o.redrawtime = 500
  end)
  after_each(function()
    vim.o.maxmempattern, vim.o.redrawtime, vim.go.synmaxcol = mmp, rdt, smc
  end)

  --- Group `group` (or nothing, "") is drawn at line l, column c.
  local function is(group, l, c)
    local at = ("line %d, col %d: %s"):format(l, c, hl.groups(l, c))
    if group == "" then
      eq("", hl.groups(l, c), at)
    else
      ok(hl.has(l, c, group), at)
    end
  end

  local function draw()
    vim.cmd("messages clear")
    local okr, err = pcall(vim.cmd, "redraw!")
    ok(okr, tostring(err))
    local m = vim.api.nvim_exec2("messages", { output = true }).output
    ok(not m:find("E363") and not m:find("redrawtime"), m)
  end

  it("highlights description terms, not the blanks around the bullet", function()
    local prose = gen.prose(5000)
    org_buffer({
      "- term :: desc",
      "  - [X] boxed *bold* term :: d",
      "1. ordered :: not a term",
      "- " .. prose .. " :: long term",
      "#+begin_quote",
      "+ quoted :: x",
      "#+end_quote",
      "- " .. prose,
    }, { 1, 0 })
    draw()
    is("orgListBullet", 1, 1)
    is("", 1, 2)
    is("orgListTerm", 1, 3)
    -- (Emacs draws the blank and the "::" after a term in org-list-dt)
    is("orgListTerm", 1, 7)
    is("", 1, 10)
    is("orgCheckboxChecked", 2, 5)
    -- (and the term starts after the bullet's blanks, the checkbox in it)
    is("orgListTerm", 2, 8)
    is("orgListTerm", 2, 9)
    is("orgBold", 2, 16)
    is("orgListTerm", 4, 3)
    is("orgListTerm", 4, 4990)
    is("orgQuoteBlock", 6, 2)
    is("orgListTerm", 6, 3)
    is("", 8, 3)
  end)

  -- (a padded table: ui_highlight_table_spec.lua)

  it("dims a long headline tagged ARCHIVE", function()
    org_buffer({ "** TODO plain " .. gen.marked(1500) .. " :work:ARCHIVE:", "* Next" }, { 1, 0 })
    draw()
    is("orgHeadlineArchived", 1, 10)
    is("orgHeadlineLevel1", 2, 1)
  end)

  it("highlights markup past 'synmaxcol', and it never runs on below", function()
    vim.go.synmaxcol = 110
    org_buffer({
      gen.prose(96) .. " *starts here and* ends after",
      "plain text",
      "* Next",
      "text *b*",
      gen.prose(5000) .. " ~starts far~ out",
    }, { 1, 0 })
    draw()
    is("orgBold", 1, 100)
    is("", 2, 1)
    is("orgHeadlineLevel1", 3, 1)
    is("orgBold", 4, 7)
    is("orgCode", 5, #vim.fn.getline(5) - 8)
  end)

  it("highlights markup over two lines, after a long first line too", function()
    org_buffer({ "some *bold", "text* and /it/", "", gen.prose(5000) .. " *bold", "text* x" }, { 1, 0 })
    draw()
    is("orgBold", 1, 7)
    is("orgBold", 2, 2)
    is("orgItalic", 2, 12)
    is("orgBold", 4, #vim.fn.getline(4) - 1)
    is("orgBold", 5, 2)
  end)

  for _, kind in ipairs({ "prose", "marked", "markers", "blob" }) do
    it("draws a 20,000-character line of " .. kind .. " and the lines after it", function()
      org_buffer({ "* H", gen[kind](20000), "* After *bold*", "- term :: x" }, { 1, 0 })
      draw()
      is("orgHeadlineLevel1", 3, 1)
      is("orgBold", 3, 11)
      is("orgListTerm", 4, 3)
    end)
  end
end)

-- Typing keeps the marks of the rows an edit can't change
-- (org.ui.decorations `carried`): after every edit, each row must be drawn
-- as a fresh scan of the buffer draws it.
describe("ui.highlighter = parser, after an edit inside a line", function()
  with_config({
    ui = {
      highlighter = "parser",
      hide_emphasis_markers = true,
      indent_mode = true,
      pretty_entities = true,
      bullets = { "◉", "○" },
      checkboxes = { " ", "◐", "✓" },
    },
  })

  --- Every row's marks, as one string per row: as drawn (`fresh`: as a
  --- scan of that row alone draws them, with the same parse).
  local function all_marks(buf, fresh)
    local ui = fresh and deco.ui_options(buf, require("org.ui.highlight").file_in_use(buf))
    local out = {}
    for row = 0, vim.api.nvim_buf_line_count(buf) - 1 do
      local t = {}
      local marks = fresh and deco.compute(buf, row, row, ui)[row] or not fresh and deco.line_marks(buf, row) or {}
      for _, m in ipairs(marks) do
        local o = vim.tbl_extend("force", {}, m[2])
        o.ephemeral = nil
        t[#t + 1] = m[1] .. ":" .. vim.inspect(o, { newline = "", indent = "" })
      end
      table.sort(t)
      out[row + 1] = table.concat(t, " ")
    end
    return out
  end

  --- The inline marks drawn on screen (org.ui.decorations `sync_inline`),
  --- after a redraw.
  local function inline_marks(buf)
    vim.cmd("redraw")
    local ns = vim.api.nvim_create_namespace("org.decorations.inline")
    local t = {}
    local top, bot = vim.fn.line("w0") - 1, vim.fn.line("w$") - 1
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { top, 0 }, { bot, -1 }, { details = true })) do
      local d = m[4]
      d.ns_id = nil
      t[#t + 1] = m[2] .. ":" .. m[3] .. vim.inspect(d, { newline = "", indent = "" })
    end
    table.sort(t)
    return table.concat(t, "\n")
  end

  -- what an edit inserts: plain text, markup markers, link and footnote
  -- brackets, and what keeps rows from being kept (a star, "#", "\")
  local CHARS = { "a", "x", " ", " ", "*", "/", "=", "~", "+", "_", "[", "]", "<", ">", "{", "}", "(", ")", '"' }
  vim.list_extend(CHARS, { "\\", "#", ":", "|", "-", "$", "^", "1", ".", "@", "\t" })

  local root = vim.fn.getcwd() .. "/tests/fixtures/emacs/faces/"
  local fixtures = {}
  for _, f in ipairs({ "headline", "list", "date", "meta", "table", "block", "object" }) do
    vim.list_extend(fixtures, vim.fn.readfile(root .. f .. ".org"))
  end

  it("draws every row as a fresh scan does, and keeps rows", function()
    local carried = deco._carried
    for _, seed in ipairs(fuzz.seeds(4)) do
      local rng = fuzz.rng(seed)
      local lines = fuzz.doc(rng, { crlf = false })
      -- (and a part of the Emacs faces cases)
      local from = rng:int(1, #fixtures - 40)
      vim.list_extend(lines, vim.list_slice(fixtures, from, from + 40))
      local buf = org_buffer(lines, { 1, 0 })
      all_marks(buf)
      for _ = 1, 25 do
        local n = vim.api.nvim_buf_line_count(buf)
        local row = rng:int(0, n - 1)
        local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
        local col = rng:int(0, #line)
        if #line > 0 and rng:chance(0.3) then
          col = math.min(col, #line - 1)
          vim.api.nvim_buf_set_text(buf, row, col, row, col + 1, {})
        else
          vim.api.nvim_buf_set_text(buf, row, col, row, col, { rng:pick(CHARS) })
        end
        local kept = all_marks(buf)
        local fresh = all_marks(buf, true)
        local now = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        for i = 1, #fresh do
          if kept[i] ~= fresh[i] then
            error(fuzz.report(seed, ("row %d drawn after an edit of row %d differs"):format(i - 1, row), now, now))
          end
        end
        -- and the inline marks (indent mode) of the rows on screen
        vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
        local inline = inline_marks(buf)
        deco.render(buf)
        if inline ~= inline_marks(buf) then
          error(fuzz.report(seed, ("inline marks after an edit of row %d differ"):format(row), now, now))
        end
        -- (the redraw computed the rows on screen together, whose marks
        -- can differ from those of each row alone: a macro over a list
        -- item; each row alone again, without a redraw)
        deco.render(buf, true)
        all_marks(buf)
      end
    end
    -- (rows were kept, not only drawn again)
    ok(deco._carried > carried)
  end)
end)
