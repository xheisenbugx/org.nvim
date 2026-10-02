-- Syntax highlighting, concealing and decorations, checked against Emacs
-- Org 9.8.10 font-lock (org-set-font-lock-defaults).

--- Lowercase syntax group names at line l, column c (1-based), joined by " ".
local function groups(l, c)
  return table.concat(
    vim.tbl_map(function(id)
      return vim.fn.synIDattr(id, "name"):lower()
    end, vim.fn.synstack(l, c)),
    " "
  )
end

local function has(l, c, group)
  return groups(l, c):find(group:lower(), 1, true) ~= nil
end

--- The column (1-based) of the first `s` in line l.
local function col(l, s)
  return assert(vim.fn.getline(l):find(s, 1, true), s)
end

--- Line l as drawn with concealing (conceallevel 2).
local function shown(l)
  local out, line, last = "", vim.fn.getline(l), nil
  for c = 1, #line do
    local r = vim.fn.synconcealed(l, c)
    if r[1] == 0 then
      out, last = out .. line:sub(c, c), nil
    elseif r[3] ~= last then
      out, last = out .. r[2], r[3]
    end
  end
  return out
end

--- An org file opened with :edit (setup that reads the file).
local function edit(lines)
  local f = vim.fn.tempname() .. ".org"
  vim.fn.writefile(lines, f)
  vim.cmd("edit! " .. f)
  return vim.api.nvim_get_current_buf()
end

--- Screen text of rows 1..n.
local function screen(n)
  local out = {}
  for r = 1, n do
    local s = {}
    for c = 1, vim.o.columns do
      s[#s + 1] = vim.fn.screenstring(r, c)
    end
    out[r] = (table.concat(s):gsub("%s+$", ""))
  end
  return out
end

local function ui(over)
  return vim.tbl_extend("force", vim.deepcopy(require("org.config").opts.ui), over)
end

describe("ui syntax: blocks", function()
  -- Emacs: a headline always ends a block (org-fontify-meta-lines-and-blocks-1)
  it("ends blocks, closed or not, at a headline", function()
    org_buffer({
      "* Top",
      "#+begin_quote",
      "quoted, never closed",
      "* TODO Next :tag:",
      "** DONE Child",
      "* Example",
      "#+begin_example",
      "** in example",
      "#+end_example",
      "#+begin_src python",
      "x = 1",
      "* After src",
    })
    ok(has(4, 1, "orgheadlinelevel1"), groups(4, 1))
    ok(has(4, 3, "orgtodo"), groups(4, 3))
    ok(not has(4, 3, "orgquoteblock"), groups(4, 3))
    ok(has(4, 13, "orgtags"), groups(4, 13))
    ok(has(5, 4, "orgdone"), groups(5, 4))
    ok(has(8, 1, "orgheadlinelevel2"), groups(8, 1))
    ok(has(12, 1, "orgheadlinelevel1"), groups(12, 1))
  end)

  it("highlights quote and verse contents as Org text, and center and special blocks", function()
    org_buffer({
      "#+begin_quote",
      "- item <2026-01-01 Thu> +strike+ [fn:1]",
      "| a | b |",
      "#+end_quote",
      "#+begin_center",
      "| c | d |",
      "#+end_center",
      "#+begin_note",
      "*bold* in a special block",
      "#+end_note",
    })
    ok(has(2, 1, "orgquoteblock") and has(2, 1, "orglistbullet"), groups(2, 1))
    ok(has(2, col(2, "2026"), "orgtimestamp"), groups(2, col(2, "2026")))
    ok(has(2, col(2, "trike"), "orgstrikethrough"), groups(2, col(2, "trike")))
    ok(has(2, col(2, "fn:1"), "orgfootnote"), groups(2, col(2, "fn:1")))
    ok(has(3, 3, "orgtable"), groups(3, 3))
    ok(has(5, 1, "orgblockdelimiter"), groups(5, 1))
    eq("orgtable", groups(6, 3))
    ok(has(9, 2, "orgbold"), groups(9, 2))
    ok(not has(9, 2, "orgblock "), groups(9, 2))
  end)

  it("spell checks quote blocks", function()
    org_buffer({ "#+begin_quote", "teh wrod", "#+end_quote" })
    vim.wo.spell = true
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eq("teh", vim.fn.spellbadword()[1])
    vim.wo.spell = false
  end)

  -- a dynamic block's contents are Org text; only #+BEGIN:/#+END: lines are meta
  it("highlights only the delimiter lines of a dynamic block", function()
    org_buffer({ "#+BEGIN: clocktable :scope file", "#+CAPTION: Clock summary", "Some *bold* note", "#+END:" })
    ok(has(1, 1, "orgblockdelimiter"), groups(1, 1))
    ok(has(2, 1, "orgkeyword"), groups(2, 1))
    ok(has(3, 7, "orgbold"), groups(3, 7))
    ok(has(4, 1, "orgblockdelimiter"), groups(4, 1))
  end)

  it("keeps a long block's middle lines block text when the window starts there", function()
    local lines = { "* Log", "#+begin_example" }
    for i = 1, 600 do
      lines[#lines + 1] = (i % 2 == 0) and ("# line " .. i) or ("| col | " .. i .. " |")
    end
    lines[#lines + 1] = "#+end_example"
    lines[#lines + 1] = "* After"
    edit(lines)
    vim.cmd("normal! 500Gzt")
    vim.cmd("redraw!")
    eq("orgblock", groups(500, 1))
    eq("orgblock", groups(501, 1))
    ok(has(#lines, 1, "orgheadlinelevel1"), groups(#lines, 1))
  end)

  -- c.vim's `syn sync ccomment` used to replace org's syncing for the buffer
  it("keeps org's syncing with an included src language", function()
    edit({ "* H", "#+begin_src c", "int x;", "#+end_src" })
    local out = vim.api.nvim_exec2("syntax sync", { output = true }).output
    ok(not out:find("C%-style"), out)
    ok(out:find("orgSyncHeadline", 1, true), out)
  end)

  -- sql.vim, lisp.vim, html.vim... run `syn case ignore`
  it("keeps TODO keywords case-sensitive with a sql src block", function()
    org_buffer({ "* todo buy milk", "* done reading", "#+begin_src sql", "select 1", "#+end_src" })
    ok(not has(1, 3, "orgtodo"), groups(1, 3))
    ok(not has(2, 3, "orgdone"), groups(2, 3))
    ok(not has(2, 3, "orgheadlinedone"), groups(2, 3))
  end)

  -- syntax/org.vim of Neovim defined its own orgBold for the whole buffer
  it("doesn't include Neovim's bundled org syntax for org src blocks", function()
    org_buffer({ "* Top", "** Second level", "*** Third", "#+begin_src org", ",* nested", "#+end_src" })
    for l = 2, 3 do
      for c = 1, l do
        ok(not has(l, c, "orgbold"), l .. ":" .. c .. " " .. groups(l, c))
      end
    end
  end)

  -- lisp.vim and sh.vim set `syn iskeyword` for the whole buffer
  it("finds plain links after - and < with an emacs-lisp or sh block", function()
    for _, lang in ipairs({ "emacs-lisp", "sh" }) do
      org_buffer({ "* H", "#+begin_src " .. lang, "x", "#+end_src", "see <https://x.org> and text-https://a.org" })
      ok(has(5, col(5, "https://x"), "orglinkplain"), lang .. ": " .. groups(5, col(5, "https://x")))
      ok(has(5, col(5, "https://a"), "orglinkplain"), lang .. ": " .. groups(5, col(5, "https://a")))
    end
  end)

  it("highlights c++ blocks as cpp and export blocks in their language", function()
    org_buffer({
      "#+begin_src c++",
      "class Foo { public: int x; };",
      "#+end_src",
      "#+begin_src C",
      "int y;",
      "#+end_src",
      "#+begin_export html",
      "<b>hi</b>",
      "#+end_export",
    })
    ok(has(2, 1, "orgsrcblock_cpp"), groups(2, 1))
    ok(has(5, 1, "orgsrcblock_c"), groups(5, 1))
    ok(has(8, 2, "orgsrcblock_html"), groups(8, 2))
  end)

  it("highlights a src block of a language added after the buffer was opened", function()
    local buf = edit({ "* H", "text" })
    vim.api.nvim_buf_set_lines(buf, 2, 2, false, { "#+begin_src python", "def f(): return 1", "#+end_src" })
    vim.cmd("doautocmd TextChanged")
    ok(has(4, 1, "orgsrcblock_python"), groups(4, 1))
  end)
end)

describe("ui syntax: emphasis", function()
  with_config({ ui = ui({ hide_emphasis_markers = true }) })

  -- org-emphasis-regexp-components: only blanks are forbidden borders
  it("allows quotes and commas at the borders", function()
    org_buffer({ [[~'symbol~ and ="quoted"= and =,= and *'q'*]] })
    ok(has(1, 2, "orgcode"), groups(1, 2))
    ok(has(1, col(1, '"quoted') + 1, "orgverbatim"), groups(1, 16))
    ok(has(1, col(1, "=,=") + 1, "orgverbatim"), groups(1, col(1, "=,=") + 1))
    ok(has(1, col(1, "*'q") + 1, "orgbold"), groups(1, col(1, "*'q") + 1))
    eq(1, vim.fn.synconcealed(1, 1)[1])
  end)

  -- org-element-paragraph-separate
  it("doesn't continue onto a list item, table row or keyword line", function()
    org_buffer({ "some *text", "- item* more", "", "other /text", "| x/ y |", "", "x _a", "#+KEY: b_ c" })
    ok(not has(1, 7, "orgbold"), groups(1, 7))
    ok(not has(2, 3, "orgbold"), groups(2, 3))
    ok(not has(4, 8, "orgitalic"), groups(4, 8))
    ok(not has(7, 4, "orgunderline"), groups(7, 4))
    eq(0, vim.fn.synconcealed(1, 6)[1])
  end)

  it("continues onto the next line of the paragraph", function()
    org_buffer({ "para *bold", "continues here* ok" })
    ok(has(1, 7, "orgbold"), groups(1, 7))
    ok(has(2, 1, "orgbold"), groups(2, 1))
  end)

  -- Emacs: "Do not span over cells in table rows"
  it("never spans table cells, but highlights markup inside one", function()
    org_buffer({ "| a ~c|d~ | e |", "| *x | y* |", "| _u_ | +s+ | *b* | =v= |" })
    for l = 1, 2 do
      for c = 1, #vim.fn.getline(l) do
        ok(not groups(l, c):find("org[bc]o[ld]"), l .. ":" .. c .. " " .. groups(l, c))
      end
    end
    ok(has(2, 1, "orgtableseparator"), groups(2, 1))
    ok(has(3, 4, "orgunderline"), groups(3, 4))
    ok(has(3, 10, "orgstrikethrough"), groups(3, 10))
    ok(has(3, 16, "orgbold"), groups(3, 16))
    ok(has(3, 22, "orgverbatim"), groups(3, 22))
  end)

  -- org-emph-re needs a non-empty text: "==" is no empty markup
  it("doesn't make an empty emphasis of doubled markers", function()
    org_buffer({ "Compare a == b and later x =y= z.", "A // comment and later a/b/ c" })
    eq(1, vim.fn.synconcealed(1, 11)[1])
    eq(0, vim.fn.synconcealed(1, 12)[1])
    ok(has(1, 14, "orgverbatim"), groups(1, 14))
    ok(has(2, 5, "orgitalic"), groups(2, 5))
  end)

  it("highlights markup in DONE headlines and hides its markers", function()
    org_buffer({ "* DONE *bold* and /it/ done", "** DONE [#A] =v= x" })
    ok(has(1, 9, "orgbold"), groups(1, 9))
    eq(1, vim.fn.synconcealed(1, 8)[1])
    ok(has(1, 20, "orgitalic"), groups(1, 20))
    ok(has(2, 15, "orgverbatim"), groups(2, 15))
  end)

  it("highlights all markup in list terms and table cells", function()
    org_buffer({ "- term +s+ _u_ :: def", "- [[https://example.com][Example]] :: def", "- =v= :: d" })
    ok(has(1, 9, "orgstrikethrough"), groups(1, 9))
    ok(has(1, 13, "orgunderline"), groups(1, 13))
    ok(has(2, 30, "orglistterm"), groups(2, 30))
    ok(has(3, 4, "orglistterm") and has(3, 4, "orgverbatim"), groups(3, 4))
  end)

  -- E363 / 'redrawtime' on paragraph lines with many unclosed markers
  it("draws long lines full of markers quickly", function()
    local msgs = {}
    for _, line in ipairs({ string.rep("/x ", 320), string.rep("*a *b ", 100), string.rep("call *args and **kw, ", 50) }) do
      edit({ "* Head", line, "after *bold* text", "* TODO second *bold*" })
      local t = vim.uv.hrtime()
      local okr, err = pcall(vim.cmd, "redraw!")
      ok(okr, tostring(err))
      ok((vim.uv.hrtime() - t) / 1e6 < 500, "slow redraw")
      ok(has(4, 3, "orgtodo"), groups(4, 3))
      msgs[#msgs + 1] = vim.api.nvim_exec2("messages", { output = true }).output
    end
    ok(not table.concat(msgs):find("redrawtime"))
  end)

  -- Emacs refontifies multi-line emphasis (font-lock-multiline)
  it("redraws the line above when a two-line emphasis is closed", function()
    local buf = org_buffer({ "para *bold", "continues here", "third" })
    vim.wo.conceallevel = 2
    vim.cmd("redraw")
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.api.nvim_buf_set_text(buf, 1, 14, 1, 14, { "*" })
    vim.cmd("redraw")
    local a, s = vim.fn.screenattr(2, 1), vim.fn.screenstring(1, 6)
    vim.cmd("redraw!")
    eq(vim.fn.screenattr(2, 1), a)
    eq(vim.fn.screenstring(1, 6), s)
  end)
end)

describe("ui syntax: headlines", function()
  it("highlights COMMENT only after the stars, a keyword and a priority", function()
    org_buffer({ "* TODO [#A] COMMENT Task", "* DONE COMMENT Old", "* Foo COMMENT bar", "* COMMENT-x foo", "* COMMENT" })
    ok(has(1, 13, "orgheadlinecomment"), groups(1, 13))
    ok(has(2, 8, "orgheadlinecomment"), groups(2, 8))
    ok(not has(3, 7, "orgheadlinecomment"), groups(3, 7))
    ok(not has(4, 3, "orgheadlinecomment"), groups(4, 3))
    ok(has(5, 3, "orgheadlinecomment"), groups(5, 3))
  end)

  -- org-tag-re: [[:alnum:]_@#%]
  it("highlights only valid tags", function()
    org_buffer({ "* Headline :foo-bar:", "* Call at :10.30:", "* Real :a_b:@x:#y:", "* Ünï :tâg:" })
    ok(not has(1, 13, "orgtags"), groups(1, 13))
    ok(not has(2, 12, "orgtags"), groups(2, 12))
    ok(has(3, 9, "orgtags"), groups(3, 9))
    ok(has(4, col(4, ":t") + 1, "orgtags"), groups(4, col(4, ":t") + 1))
  end)

  it("dims headlines tagged ARCHIVE", function()
    org_buffer({ "* Old project notes :work:ARCHIVE:", "* Live project :work:" })
    ok(has(1, 3, "orgheadlinearchived"), groups(1, 3))
    ok(has(1, col(1, ":work"), "orgtags"), groups(1, col(1, ":work")))
    ok(not has(2, 3, "orgheadlinearchived"), groups(2, 3))
  end)

  -- org-get-level-face cycles the 8 faces
  it("highlights headlines of any depth", function()
    local stars = string.rep("*", 21)
    org_buffer({ stars .. " TODO Deep :tag:", string.rep("*", 16) .. " x" })
    ok(has(1, 1, "orgheadlinelevel5"), groups(1, 1))
    ok(has(1, 23, "orgtodo"), groups(1, 23))
    ok(has(1, col(1, ":tag"), "orgtags"), groups(1, col(1, ":tag")))
    ok(has(2, 1, "orgheadlinelevel8"), groups(2, 1))
  end)

  -- org-checkbox-statistics-done / -todo
  it("highlights complete statistics cookies as done", function()
    org_buffer({ "* Done [2/2] [1/2] [100%] [50%] [0/0]" })
    ok(has(1, 9, "orgstatisticdone"), groups(1, 9))
    ok(has(1, 15, "orgstatistic") and not has(1, 15, "orgstatisticdone"), groups(1, 15))
    ok(has(1, 21, "orgstatisticdone"), groups(1, 21))
    ok(not has(1, 28, "orgstatisticdone"), groups(1, 28))
  end)
end)

describe("ui syntax: links", function()
  it("conceals a bracket link whose description wraps to the next line", function()
    org_buffer({ "see [[https://example.com][a long", "description]] here" })
    vim.wo.conceallevel = 2
    eq("see a long", shown(1))
    eq("description here", shown(2))
    ok(has(2, 1, "orglink"), groups(2, 1))
  end)

  it("activates links in property values, comments, #+TITLE and #+AUTHOR", function()
    org_buffer({
      "* H",
      ":PROPERTIES:",
      ":URL:      [[https://example.com][Example]]",
      ":SRC: https://example.com/x",
      ":END:",
      "# see [[https://example.com][Example]]",
      "#+TITLE: Notes on [[https://example.com][Example]]",
      "#+AUTHOR: Me [[mailto:me@x.org][mail]]",
    })
    vim.wo.conceallevel = 2
    eq(":URL:      Example", shown(3))
    ok(has(4, 8, "orglinkplain"), groups(4, 8))
    eq("# see Example", shown(6))
    eq("#+TITLE: Notes on Example", shown(7))
    eq("#+AUTHOR: Me mail", shown(8))
  end)

  it("highlights angle links whole and plain links after _", function()
    org_buffer({
      "open <file:my notes.org> or <https://example.com/a b> now",
      "x _https://example.com and xhttps://b.com",
    })
    for _, w in ipairs({ "<file", "notes.org>", "<https", " b>" }) do
      ok(has(1, col(1, w) + 1, "orglinkplain"), w .. ": " .. groups(1, col(1, w) + 1))
    end
    ok(has(2, 4, "orglinkplain"), groups(2, 4))
    ok(not has(2, col(2, "xhttps") + 1, "orglinkplain"), groups(2, col(2, "xhttps") + 1))
  end)

  it("keeps whole inline footnotes with brackets and links inside", function()
    org_buffer({ "a [fn:: see [[https://x.org][x]] here] b", "c [fn:: a [b] c] d", "x [fn:: note <2026-10-02 Fri>] y" })
    vim.wo.conceallevel = 2
    eq("a [fn:: see x here] b", shown(1))
    ok(has(1, col(1, "here"), "orgfootnote"), groups(1, col(1, "here")))
    ok(has(2, col(2, " c]"), "orgfootnote"), groups(2, col(2, " c]")))
    ok(has(3, col(3, "2026"), "orgtimestamp"), groups(3, col(3, "2026")))
  end)
end)

describe("ui syntax: timestamps and objects", function()
  it("highlights timestamps inside other objects and elements", function()
    org_buffer({
      "* H",
      ":PROPERTIES:",
      ":CREATED: [2026-10-02 Fri]",
      ":END:",
      "*bold <2026-10-02 Fri> text*",
      "/it [2026-10-02 Fri]/",
      "- term <2026-10-02 Fri> :: desc",
      "See [[https://x.org][desc <2026-10-02 Fri>]] z",
    })
    ok(has(3, 12, "orgtimestampinactive"), groups(3, 12))
    ok(has(5, 8, "orgtimestamp"), groups(5, 8))
    ok(has(6, 6, "orgtimestampinactive"), groups(6, 6))
    ok(has(7, 9, "orgtimestamp"), groups(7, 9))
    ok(has(8, col(8, "2026"), "orgtimestamp"), groups(8, col(8, "2026")))
  end)

  it("highlights diary sexps", function()
    org_buffer({ "* M", "  SCHEDULED: <%%(diary-float t 4 2)>", "%%(diary-anniversary 10 2 1990) Birthday" })
    ok(has(2, 16, "orgsexpdate"), groups(2, 16))
    ok(has(3, 1, "orgsexpdate"), groups(3, 1))
  end)

  -- org-tsr-regexp-both
  it("doesn't take non-dates or prose for timestamps", function()
    org_buffer({ "<2026-10-02x> not a timestamp", "<2026-10-02 Fri] then prose -> arrow", "The ratio => 3:45" })
    ok(not has(1, 2, "orgtimestamp"), groups(1, 2))
    ok(has(2, 2, "orgtimestamp"), groups(2, 2))
    ok(not has(2, col(2, "prose"), "orgtimestamp"), groups(2, col(2, "prose")))
    ok(not has(3, col(3, "=>"), "orgclockduration"), groups(3, col(3, "=>")))
  end)

  it("highlights the duration of a CLOCK line", function()
    org_buffer({ "  CLOCK: [2026-01-01 Thu 10:00]--[2026-01-01 Thu 11:00] =>  1:00" })
    ok(has(1, col(1, "=>"), "orgclockduration"), groups(1, col(1, "=>")))
  end)

  it("highlights inline src blocks and export snippets", function()
    org_buffer({ "Run src_python{print(1)} and src_sh[:results raw]{ls} now.", "a @@html:<b>@@ bold" })
    ok(has(1, 5, "orginlinesrcmarker"), groups(1, 5))
    ok(has(1, 9, "orginlinesrclang"), groups(1, 9))
    ok(has(1, 17, "orginlinesrcbody"), groups(1, 17))
    ok(has(1, col(1, "[:res") + 1, "orginlinesrcheader"), groups(1, col(1, "[:res") + 1))
    ok(has(2, 3, "orgexportsnippetmarker"), groups(2, 3))
    ok(has(2, 5, "orgexportsnippetbackend"), groups(2, 5))
  end)

  it("highlights markup, footnotes, macros, cookies and formulas in table rows", function()
    org_buffer({ "| _u_ | +s+ | [fn:1] | {{{m}}} | [1/2] | <<tgt>> |", "| <5> | <r> | := $1 | x |", "| # | a |" })
    ok(has(1, col(1, "fn:1"), "orgfootnote"), groups(1, col(1, "fn:1")))
    ok(has(1, col(1, "{{{"), "orgmacro"), groups(1, col(1, "{{{")))
    ok(has(1, col(1, "1/2"), "orgstatistic"), groups(1, col(1, "1/2")))
    ok(has(1, col(1, "tgt"), "orgtarget"), groups(1, col(1, "tgt")))
    ok(has(2, 3, "orgtableformula"), groups(2, 3))
    ok(has(2, 9, "orgtableformula"), groups(2, 9))
    ok(has(2, col(2, ":="), "orgtableformula"), groups(2, col(2, ":=")))
    ok(has(3, 3, "orgtableformula"), groups(3, 3))
    ok(not has(1, 1, "orgtableformula"), groups(1, 1))
  end)

  it("highlights a property whose name has a colon", function()
    org_buffer({ "* H", ":PROPERTIES:", ":header-args:lua: :var base=100", ":END:" })
    ok(has(3, 2, "orgpropertykey"), groups(3, 2))
    ok(has(3, col(3, ":var"), "orgpropertyvalue"), groups(3, col(3, ":var")))
  end)
end)

describe("ui syntax: latex", function()
  with_config({ ui = ui({ highlight_latex_and_related = { "latex", "entities" } }) })

  it("highlights only closed fragments, never past a headline", function()
    org_buffer({ "* H1", "text \\(x + y", "* H2", "para $$ a", "* H3", "\\begin{equation}", "x", "* H4", "\\(a\\) b" })
    for _, l in ipairs({ 1, 3, 5, 8 }) do
      ok(has(l, 1, "orgheadlinelevel1") and not has(l, 1, "orglatex"), l .. " " .. groups(l, 1))
    end
    ok(not has(2, 7, "orglatex"), groups(2, 7))
    ok(has(9, 2, "orglatex"), groups(9, 2))
  end)

  it("highlights environments when entities are on", function()
    org_buffer({ "Text.", "\\begin{equation}", "x = 1", "\\end{equation}" })
    ok(has(2, 10, "orglatex"), groups(2, 10))
    ok(has(3, 1, "orglatex"), groups(3, 1))
    ok(has(4, 6, "orglatex"), groups(4, 6))
  end)
end)

describe("ui syntax: lists", function()
  it("highlights a checkbox after a counter, not [x] or a box without a blank", function()
    org_buffer({ "- [@3] [X] counter box", "1. [@start:2] [ ] start", "- [ ]no space", "- [x] lower", "a. [ ] alpha" })
    ok(has(1, 8, "orgcheckboxchecked"), groups(1, 8))
    ok(has(2, 15, "orgcheckbox"), groups(2, 15))
    ok(not has(3, 3, "orgcheckbox"), groups(3, 3))
    ok(not has(4, 3, "orgcheckbox"), groups(4, 3))
    ok(has(5, 4, "orgcheckbox"), groups(5, 4))
  end)

  it("draws checkbox icons as org.lists reads the item", function()
    local saved = require("org.config").opts.ui.checkboxes
    require("org.config").opts.ui.checkboxes = { "U", "P", "C" }
    vim.o.columns = 60
    edit({ "- [@3] [X] counter box", "- [ ]no space", "- [x] lower", "- [ ] plain" })
    vim.cmd("redraw!")
    local s = screen(4)
    require("org.config").opts.ui.checkboxes = saved
    eq("- [@3] [C] counter box", s[1])
    eq("- [ ]no space", s[2])
    eq("- [x] lower", s[3])
    eq("- [U] plain", s[4])
  end)

  it("follows allow_alphabetical for bullets", function()
    org_buffer({ "Text", "I. Smith wrote" })
    ok(not has(2, 1, "orglistbullet"), groups(2, 1))
  end)
end)

describe("ui decorations: pretty entities", function()
  local saved
  before_each(function()
    saved = require("org.config").opts.ui.pretty_entities
    require("org.config").opts.ui.pretty_entities = true
    vim.o.columns = 80
  end)
  after_each(function()
    require("org.config").opts.ui.pretty_entities = saved
  end)

  local function render(lines)
    edit(lines)
    vim.wo.foldenable = false
    vim.api.nvim_win_set_cursor(0, { #lines, 0 })
    vim.cmd("redraw!")
    return screen(#lines)
  end

  it("follows #+OPTIONS: ^:{} for sub- and superscripts", function()
    local s = render({ "#+OPTIONS: ^:{}", "snake_case x^2 a_{i}", "" })
    eq("snake_case x^2 aᵢ", s[2])
    s = render({ "#+OPTIONS: toc:nil ^:nil", "snake_case x^2", "" })
    eq("snake_case x^2", s[2])
  end)

  it("doesn't raise scripts in property names, links, footnotes, tags, emphasis and comments", function()
    local s = render({
      "* Head :tag_x:",
      ":PROPERTIES:",
      ":CUSTOM_ID: abc",
      ":END:",
      "file:my_notes.org",
      "see[fn:my_note]",
      "*e_f* /g_h/",
      "# a_b",
      "a=b x^2 c=d",
      "",
    })
    eq("* Head :tag_x:", s[1])
    eq(":CUSTOM_ID: abc", s[3])
    eq("file:my_notes.org", s[5])
    eq("see[fn:my_note]", s[6])
    eq("*e_f* /g_h/", s[7])
    eq("# a_b", s[8])
    eq("a=b x² c=d", s[9])
  end)

  it("shows entities in quote and verse blocks, not in src blocks", function()
    local s = render({
      "#+begin_quote",
      "\\alpha x^2",
      "#+end_quote",
      "#+begin_src text",
      "\\beta",
      "#+end_src",
      "",
    })
    eq("α x²", s[2])
    eq("\\beta", s[5])
  end)
end)

describe("ui decorations: indent mode", function()
  local function inline_marks(buf, row)
    local ns = vim.api.nvim_get_namespaces()["org.decorations.inline"]
    return vim.api.nvim_buf_get_extmarks(buf, ns, { row or 0, 0 }, { row or -1, -1 }, { details = true })
  end

  it("prefixes empty lines too", function()
    vim.o.columns = 60
    local buf = edit({ "#+STARTUP: indent", "* A", "** B", "body", "", "more" })
    vim.cmd("redraw!")
    local width = 0
    for _, m in ipairs(inline_marks(buf, 4)) do
      for _, c in ipairs(m[4].virt_text or {}) do
        width = width + vim.fn.strdisplaywidth(c[1])
      end
    end
    eq(4, width)
  end)

  it("removes the prefixes after a reload with #+STARTUP: noindent", function()
    local f = vim.fn.tempname() .. ".org"
    vim.fn.writefile({ "#+STARTUP: indent", "* A", "text1", "** B", "body" }, f)
    vim.cmd("edit! " .. f)
    vim.cmd("redraw!")
    ok(#inline_marks(0) > 0)
    vim.fn.writefile({ "#+STARTUP: noindent", "* A", "text1", "** B", "body" }, f)
    vim.cmd("edit!")
    vim.cmd("redraw!")
    require("org.files").get_buffer(0)
    vim.cmd("redraw!")
    eq(0, #inline_marks(0))
  end)

  it("doesn't decorate rows hidden in a closed fold", function()
    local lines = { "#+STARTUP: indent", "* A" }
    for i = 1, 2000 do
      lines[#lines + 1] = "text line " .. i
    end
    lines[#lines + 1] = "* B"
    local buf = edit(lines)
    vim.wo.foldenable = true
    vim.cmd("2")
    vim.cmd("normal! zM")
    vim.cmd("redraw!")
    vim.api.nvim_buf_set_text(buf, 1, 3, 1, 3, { "x" })
    vim.cmd("redraw")
    ok(#inline_marks(buf) < 100, #inline_marks(buf))
  end)
end)

describe("ui buffer setup", function()
  it("sets concealing for org windows only", function()
    vim.cmd("enew!")
    vim.o.conceallevel, vim.o.concealcursor = 0, ""
    edit({ "* Head [[https://x.com][desc]]", "body" })
    eq(2, vim.wo.conceallevel)
    eq(0, vim.go.conceallevel)
    eq("", vim.go.concealcursor)
    vim.cmd("enew!")
    eq(0, vim.wo.conceallevel)
    eq("", vim.wo.concealcursor)
  end)

  it("undoes the org setup when the filetype changes", function()
    edit({ "* TODO Head", "body", "** sub", "text" })
    local undo = vim.b.undo_ftplugin or ""
    ok(not undo:match("^%s*|"), undo)
    local out = vim.api.nvim_exec2("set ft=org", { output = true }).output
    ok(not out:find("TODO Head", 1, true), out)
    vim.cmd("set ft=text")
    ok(not vim.wo.foldexpr:find("org"), vim.wo.foldexpr)
    ok(not vim.bo.indentexpr:find("org"), vim.bo.indentexpr)
    local m = vim.fn.maparg("<Tab>", "n", false, true)
    ok(not (m.desc and m.desc:find("org")), m.desc)
    vim.cmd("set ft=org")
    eq("v:lua.require'org.fold'.foldexpr(v:lnum)", vim.wo.foldexpr)
  end)
end)
