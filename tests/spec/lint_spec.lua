-- org-lint: messages and lines checked against Emacs Org 9.8 (org-lint).
local lint = require("org.lint")

--- Reports of `checker` for a buffer made of `lines`, as "LNUM message".
local function run(lines, checker)
  local buf = org_buffer(lines)
  local out = {}
  for _, r in ipairs(lint.lint(buf, checker and { checker } or nil)) do
    out[#out + 1] = r.lnum .. " " .. r.message
  end
  return out
end

describe("lint structure", function()
  it("misplaced heading", function()
    eq(
      { "1 Possibly misplaced heading line", "3 Possibly misplaced heading line" },
      run({
        "Paragraph** Oops heading",
        "* Heading 1",
        "* Heading 2** Heading 3",
        "text",
      }, "misplaced-heading")
    )
  end)

  it("duplicates", function()
    eq(
      { '3 Duplicate CUSTOM_ID property "dup"', '7 Duplicate CUSTOM_ID property "dup"' },
      run({
        "* A",
        ":PROPERTIES:",
        ":CUSTOM_ID: dup",
        ":END:",
        "* B",
        ":PROPERTIES:",
        ":CUSTOM_ID: dup",
        ":END:",
      }, "duplicate-custom-id")
    )
    eq(
      { '1 Duplicate NAME "dup"', '6 Duplicate NAME "dup"' },
      run({ "#+name: dup", "#+begin_example", "x", "#+end_example", "", "#+name: dup", "| a |" }, "duplicate-name")
    )
    eq(
      { "1 Duplicate target <<t>>", "1 Duplicate target <<t>>" },
      run({ "Some <<t>> and <<t>> and <<u>>." }, "duplicate-target")
    )
    eq(
      { '2 Duplicate footnote definition "1"', '3 Duplicate footnote definition "1"' },
      run({ "Ref[fn:1].", "[fn:1] One.", "[fn:1] Two." }, "duplicate-footnote-definition")
    )
  end)

  it("affiliated keywords", function()
    eq(
      { '1 Orphaned affiliated keyword: "NAME"' },
      run({ "#+name: orphan", "", "text" }, "orphaned-affiliated-keywords")
    )
    eq({}, run({ "#+RESULTS:", "", "text" }, "orphaned-affiliated-keywords"))
    eq(
      { "1 Independent keyword TITLE may be confused with affiliated keywords below" },
      run({ "#+title: y", "#+caption: c", "| t |" }, "combining-keywords-with-affiliated")
    )
    eq(
      { '1 Obsolete affiliated keyword: "TBLNAME".  Use "NAME" instead' },
      run({ "#+TBLNAME: tbl", "| a | b |" }, "obsolete-affiliated-keywords")
    )
  end)

  it("keywords, blocks and drawers", function()
    eq({ '1 Possible missing colon in keyword "TITLE"' }, run({ "#+TITLE foo" }, "invalid-keyword-syntax"))
    eq({}, run({ "#+CAPTION[short]: long", "| a |" }, "invalid-keyword-syntax"))
    eq({
      '1 Possible incomplete block "#+begin_quote"',
      '3 Invalid block closing line "#+end_src x"',
      '4 Possible incomplete block "#+begin_foo"',
      '6 Possible incomplete block "#+end"',
    }, run({ "#+begin_quote", "text", "#+end_src x", "#+begin_foo", "unfinished", "#+end" }, "invalid-block"))
    eq({
      '2 Possible misleading drawer entry ":INNER:"',
      '5 Possible incomplete drawer ":LONELY:"',
    }, run({ ":DRAWER:", ":INNER:", "x", ":END:", ":LONELY:" }, "incomplete-drawer"))
    eq({ "2 Possible indented diary-sexp" }, run({ "text", "  %%(diary-float t 4 2)" }, "indented-diary-sexp"))
    eq(
      { '2 Deprecated syntax for export block.  Use "BEGIN_EXPORT html" instead' },
      run({ "", "#+begin_html", "<p>x</p>", "#+end_html" }, "deprecated-export-blocks")
    )
    eq(
      { "1 Missing backend in export block" },
      run({ "#+BEGIN_EXPORT", "x", "#+END_EXPORT" }, "missing-backend-in-export-block")
    )
    eq(
      { "2 Spurious CATEGORY keyword.  Set :CATEGORY: property instead" },
      run({ "#+CATEGORY: a", "#+CATEGORY: b" }, "deprecated-category-setup")
    )
  end)

  it("headlines", function()
    eq({ "1 Deprecated QUOTE section" }, run({ "* QUOTE old" }, "quote-section"))
    eq({ "1 Tags contain a spurious colon" }, run({ "* Tags :a::b:" }, "spurious-colons"))
    eq({
      "1 Out-of-bounds priority 'D'",
      "2 Invalid priority 'AA'",
      "3 Malformed priority '[#A missing'",
    }, run({ "* [#D] Out", "* [#AA] bad", "* [#A missing", "* [#B] ok" }, "priority"))
    eq(
      { "2 Out-of-bounds priority '7'" },
      run({ "#+PRIORITIES: 1 5 3", "* TODO [#7] Numeric", "* [#2] ok" }, "priority")
    )
  end)
end)

describe("lint properties and planning", function()
  it("property drawers", function()
    local lines = {
      "* H",
      ":PROPERTIES:",
      ":EFFORT: 1 hour",
      ":ID: a::b",
      ":TODO: x",
      ":TITLE: y",
      ":HTML_HEAD: z",
      ":cache: yes",
      ":END:",
      ":PROPERTIES:",
      ":X: y",
      ":END:",
    }
    eq({ '3 Invalid effort duration format: "1 hour"' }, run(lines, "invalid-effort-property"))
    eq({ '4 IDs should not include "::": "a::b"' }, run(lines, "invalid-id-property"))
    eq(
      { '5 Special property "TODO" found in a properties drawer' },
      run(lines, "special-property-in-properties-drawer")
    )
    eq({
      '6 Potentially misspelled global export option "TITLE".  Consider "EXPORT_TITLE".',
      '7 Potentially misspelled nilexport option "HTML_HEAD" in html export backend.  Consider "EXPORT_HTML_HEAD".',
    }, run(lines, "misspelled-export-option"))
    eq({ '8 Deprecated syntax for "cache".  Use :header-args: instead' }, run(lines, "deprecated-header-syntax"))
    eq({ "10 Incorrect contents for PROPERTIES drawer" }, run(lines, "obsolete-properties-drawer"))
    eq({}, run({ "* H", ":PROPERTIES:", ":EFFORT: 1d 2:30", ":END:" }, "invalid-effort-property"))
  end)

  it("planning", function()
    local lines = {
      "* H",
      "SCHEDULED: <2024-01-01 Mon +1w> DEADLINE: <2024-01-05 Fri +2w>",
      "* H2",
      "SCHEDULED: [2024-01-01 Mon]",
      "* H3",
      "DEADLINE: [2024-01-05 Fri]",
      "text",
      "SCHEDULED: <2024-01-01 Mon>",
    }
    eq({ "2 Different repeaters in SCHEDULED and DEADLINE timestamps." }, run(lines, "mismatched-planning-repeaters"))
    eq({
      "4 Inactive timestamp in SCHEDULED will not appear in agenda.",
      "6 Inactive timestamp in DEADLINE will not appear in agenda.",
    }, run(lines, "planning-inactive"))
    eq({ "8 Misplaced planning info line" }, run(lines, "misplaced-planning-info"))
  end)

  it("timestamps and clocks", function()
    eq(
      {
        "1 Potentially malformed timestamp <2024-01-01> .  Parsed as: <2024-01-01 Mon> ",
        "1 Potentially malformed timestamp <2024-01-01 Mon 9:00>.  Parsed as: <2024-01-01 Mon 09:00>",
        "2 Potentially malformed timestamp <2024-02-30> .  Parsed as: <2024-03-01 Fri> ",
      },
      run({
        "At <2024-01-01> and <2024-01-01 Mon 9:00>",
        "Also <2024-02-30> and <2024-01-01 Mon>--<2024-01-03 Wed>",
      }, "timestamp-syntax")
    )
    eq(
      {
        "2 Potentially malformed CLOCK: line\n           CLOCK: [2024-01-01 Mon 10:00]--[2024-01-01 Mon 11:05] => 1:05"
          .. "\nParsed as: CLOCK: [2024-01-01 Mon 10:00]--[2024-01-01 Mon 11:05] =>  1:05",
      },
      run({
        "* H",
        "CLOCK: [2024-01-01 Mon 10:00]--[2024-01-01 Mon 11:05] => 1:05",
        "CLOCK: [2024-01-01 Mon 10:00]--[2024-01-01 Mon 11:05] =>  1:05",
      }, "clock-syntax")
    )
  end)
end)

describe("lint links and footnotes", function()
  it("internal links", function()
    local lines = {
      "* Heading One",
      ":PROPERTIES:",
      ":CUSTOM_ID: h1",
      ":END:",
      "<<target>> [[#h1]] [[#nothere]] [[target]] [[TARGET]] [[nowhere]] [[*heading one]] [[*Nope]]",
      "[[(here)]] [[(nocode)]] [[id:123-nope]]",
      "#+begin_example",
      "x (ref:here)",
      "#+end_example",
    }
    eq({ '5 Unknown custom ID "nothere"' }, run(lines, "invalid-custom-id-link"))
    eq({ '5 Unknown fuzzy location "nowhere"', '5 Unknown fuzzy location "Nope"' }, run(lines, "invalid-fuzzy-link"))
    eq({ '6 Unknown coderef "nocode"' }, run(lines, "invalid-coderef-link"))
    eq({ '6 Unknown ID "123-nope"' }, run(lines, "invalid-id-link"))
  end)

  it("looks IDs up in one scan of the ID files, not once per link", function()
    local id = require("org.id")
    local find = id.find
    local calls = 0
    id.find = function(x)
      calls = calls + 1
      return find(x)
    end
    local lines = { "* Here", ":PROPERTIES:", ":ID: here-1", ":END:" }
    for i = 1, 50 do
      lines[#lines + 1] = string.format("[[id:here-1]] [[id:gone-%d]] [[id:gone-%d]]", i, i)
    end
    local ok_, res = pcall(run, lines, "invalid-id-link")
    id.find = find
    ok(ok_, res)
    eq(100, #res)
    eq('5 Unknown ID "gone-1"', res[1])
    -- one scan of the ID files instead of org.id.find's rescan per ID
    eq(0, calls)
  end)

  it("link syntax", function()
    local lines = {
      "A [[https://example.com][desc [bracket]]] trailing ]",
      "And [[https://example.com/a%20b]] and [[a%5Bb]] and [[file+sys:/nonexistent/x.org]].",
      "A [[file:/nonexistent/missing.org][missing]] and file:/nonexistent/nope.txt",
    }
    eq({ "1 Trailing ']' after link end" }, run(lines, "trailing-bracket-after-link"))
    eq(
      { "1 No closing ']' matches '[' in link description: desc [bracket" },
      run(lines, "unclosed-brackets-in-link-description")
    )
    eq({
      "2 Link escaped with obsolete percent-encoding syntax",
      "2 Link escaped with obsolete percent-encoding syntax",
    }, run(lines, "percent-encoding-link-escape"))
    eq({ '2 Deprecated "file+sys" link type' }, run(lines, "file-application"))
    eq({
      '2 Link to non-existent local file "/nonexistent/x.org"',
      '3 Link to non-existent local file "/nonexistent/missing.org"',
      '3 Link to non-existent local file "/nonexistent/nope.txt"',
    }, run(lines, "link-to-local-file"))
  end)

  it("footnotes", function()
    local lines = {
      "Footnote[fn:1] and [fn:nodef] and [fn:inl:inline def] and [fn::anon].",
      "",
      "[fn:1] One.",
      "[fn:unused] Unused.",
      "* Footnotes",
      "Some text",
      "[fn:inl] x",
    }
    eq({ "1 Missing definition for footnote [nodef]" }, run(lines, "undefined-footnote-reference"))
    eq({ "4 No reference for footnote definition [unused]" }, run(lines, "unreferenced-footnote-definition"))
    eq(
      { "5 Extraneous elements in footnote section are not exported" },
      run(lines, "extraneous-element-in-footnote-section")
    )
    eq(
      {},
      run({ "* Footnotes", "# comment", "[fn:1] x", "** COMMENT hidden" }, "extraneous-element-in-footnote-section")
    )
  end)
end)

describe("lint babel", function()
  local lines = {
    "#+PROPERTY: cache yes",
    "#+PROPERTY: header-args :foo bar",
    "#+begin_src emacs-lisp results output :exports nope :noweb :tangle foo yes",
    "1",
    "#+end_src",
    "",
    "#+begin_src",
    "x",
    "#+end_src",
    "",
    "#+begin_src foobarlang",
    "x",
    "#+end_src",
    "",
    "#+CALL: [x]",
    "#+CALL: foo() [:results raw]",
    "",
    "#+name: blk",
    "#+begin_src emacs-lisp :exports code",
    "1",
    "#+end_src",
    "",
    "#+NAME: res",
    "#+RESULTS: blk",
    ": 1",
  }

  it("header arguments", function()
    eq({
      '2 Unknown header argument ":foo"',
      '3 Missing colon in header argument "results"',
      '15 Missing colon in header argument "x"',
      '16 Missing colon in header argument "[:results"',
    }, run(lines, "wrong-header-argument"))
    eq({
      '3 Forbidden combination in header ":tangle": foo, yes',
      '3 Unknown value "nil" for header ":noweb"',
      '3 Unknown value "nope" for header ":exports"',
    }, run(lines, "wrong-header-value"))
    eq({
      '3 Empty value in header argument ":noweb"',
      '15 Empty value in header argument "x"',
    }, run(lines, "empty-header-argument"))
    eq({ '1 Deprecated syntax for "cache".  Use header-args instead' }, run(lines, "deprecated-header-syntax"))
  end)

  it("blocks and calls", function()
    eq({ "7 Missing language in source block" }, run(lines, "missing-language-in-src-block"))
    eq({ "11 Unknown source block language: 'foobarlang'" }, run(lines, "suspicious-language-in-src-block"))
    eq({
      "15 Invalid syntax in babel call block",
      "16 Babel call's end header must not be wrapped within brackets",
    }, run(lines, "invalid-babel-call-block"))
    eq({
      '23 Links to "res" will not be valid during export unless the parent source block has :exports results or both',
    }, run(lines, "named-result"))
  end)
end)

describe("lint export", function()
  it("keywords", function()
    local lines = {
      "#+SETUPFILE: /nonexistent/x.setup",
      '#+INCLUDE: "/nonexistent/f.org"',
      "#+INCLUDE:",
      '#+INCLUDE: "/nonexistent/f.org" html',
      "#+OPTIONS: toc: foo:bar H:2",
      "#+BIBLIOGRAPHY: /nonexistent/refs.bib",
      "#+CITE_EXPORT:",
      "#+CITE_EXPORT: fancy",
      '#+CITE_EXPORT: "basic"',
      "#+CITE_EXPORT: basic author-year",
    }
    eq({ '1 Non-existent setup file "/nonexistent/x.setup"' }, run(lines, "non-existent-setupfile-parameter"))
    eq({
      "2 Non-existent file argument in INCLUDE keyword",
      "3 Missing location argument in INCLUDE keyword",
      "4 Non-existent file argument in INCLUDE keyword",
    }, run(lines, "wrong-include-link-parameter"))
    eq(
      { '4 Obsolete markup "html" in INCLUDE keyword.  Use "export html" instead' },
      run(lines, "obsolete-include-markup")
    )
    eq({
      '5 Unknown OPTIONS item "foo"',
      '5 Missing value for option item "toc"',
    }, run(lines, "unknown-options-item"))
    eq({ '6 Non-existent bibliography "/nonexistent/refs.bib"' }, run(lines, "non-existent-bibliography"))
    eq({
      "7 Missing export processor name",
      "8 Unknown cite export processor fancy",
      "9 Invalid cite export processor declaration",
    }, run(lines, "invalid-cite-export-declaration"))
  end)

  it("macros", function()
    eq(
      {
        '2 Unused placeholders in macro "bad"',
        '3 Missing template in macro "%s"',
        '4 Missing argument in macro "greet"',
        '4 Spurious argument in macro "greet": b',
        '4 Missing argument in macro "title"',
        '4 Undefined macro "nope"',
        '4 Spurious arguments in macro "bad": 3, 4',
      },
      run({
        "#+MACRO: greet Hello $1",
        "#+MACRO: bad Hi $2",
        "#+MACRO: empty",
        "{{{greet}}} {{{greet(a,b)}}} {{{title}}} {{{nope}}} {{{bad(1,2,3,4)}}} {{{n}}}",
      }, "invalid-macro-argument-and-template")
    )
  end)

  it("citations, LaTeX and beamer", function()
    local lines = {
      "Cite [cite:@key] and broken [cite:nokey] text.",
      "Math $x$ and costs $.50 and =$.5= verbatim.",
      "\\begin{orgframe}",
      "x",
      "\\end{orgframe}",
    }
    eq({ "1 Possibly incomplete citation markup" }, run(lines, "incomplete-citation"))
    eq({ '6 Possibly missing "PRINT_BIBLIOGRAPHY" keyword' }, run(lines, "missing-print-bibliography"))
    eq(
      { "2 $ symbol potentially matching LaTeX fragment boundary.  Consider using \\dollar entity." },
      run(lines, "LaTeX-$")
    )
    eq({
      "3 Beamer frame name may cause error when exporting.  Consider customizing `org-beamer-frame-environment'.",
      "5 Beamer frame name may cause error when exporting.  Consider customizing `org-beamer-frame-environment'.",
    }, run(lines, "beamer-frame"))
    eq(
      { "2 Potentially confusing LaTeX fragment format.  Prefer using more reliable \\(...\\)" },
      run(lines, "LaTeX-$-fragment")
    )
  end)

  it("lists and images", function()
    eq({
      '2 Bullet counter "1. " is not the same with item position 2.  Consider adding manual [@1] counter.',
      '6 Bullet counter "2. " is not the same with item position 3.  Consider adding manual [@2] counter.',
    }, run({ "- 1. a", "1. x", "3. y", "", "1. [@b] first", "2. second" }, "item-number"))
    eq({
      '1 "yes" not a supported value for #+ATTR_ORG keyword attribute ":center".',
      '1 "middle" not a supported value for #+ATTR_ORG keyword attribute ":align".',
    }, run({ "#+ATTR_ORG: :align middle :center yes", "[[file:x.png]]" }, "invalid-image-alignment"))
  end)
end)

describe("lint entry points", function()
  it("sorts reports by line and runs every default checker", function()
    local buf = org_buffer({ "#+TITLE foo", "* QUOTE x", "[[nowhere]]" })
    local reports = lint.lint(buf)
    eq(
      { 1, 2, 3 },
      vim.tbl_map(function(r)
        return r.lnum
      end, reports)
    )
    eq("invalid-keyword-syntax", reports[1].checker)
    eq("low", reports[1].trust)
    eq("high", reports[3].trust)
    ok(not vim.tbl_contains(lint.checker_names(), "LaTeX-$-fragment"))
  end)

  it("show fills the location list", function()
    org_buffer({ "#+TITLE foo", "[[nowhere]]" })
    lint.show()
    local info = vim.fn.getloclist(0, { title = 1, items = 1 })
    eq("org-lint", info.title)
    eq(2, #info.items)
    eq(1, info.items[1].lnum)
    eq('invalid-keyword-syntax: Possible missing colon in keyword "TITLE"', info.items[1].text)
    vim.cmd("lclose")
    lint.show({ "invalid-fuzzy-link" })
    info = vim.fn.getloclist(0, { items = 1 })
    eq(1, #info.items)
    eq('invalid-fuzzy-link: Unknown fuzzy location "nowhere"', info.items[1].text)
    vim.cmd("lclose")
  end)

  it("hides (h) and ignores (i) a checker in the report list; r refreshes", function()
    local src = org_buffer({ "#+TITLE foo", "[[nowhere]]", "#+AUTHOR bar", "[[elsewhere]]" })
    local srcwin = vim.api.nvim_get_current_win()
    lint.show()
    local function checkers()
      return vim.tbl_map(function(it)
        return it.user_data.checker
      end, vim.fn.getloclist(srcwin, { items = 0 }).items)
    end
    eq({ "invalid-keyword-syntax", "invalid-fuzzy-link", "invalid-keyword-syntax", "invalid-fuzzy-link" }, checkers())
    eq("qf", vim.bo.filetype)
    -- h: hide the fuzzy-link reports; r (Emacs g) brings them back
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys("h", "x", false)
    eq({ "invalid-keyword-syntax", "invalid-keyword-syntax" }, checkers())
    vim.api.nvim_feedkeys("r", "x", false)
    eq(4, #checkers())
    -- i: the keyword checker stays out after a refresh
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys("i", "x", false)
    eq({ "invalid-fuzzy-link", "invalid-fuzzy-link" }, checkers())
    vim.api.nvim_feedkeys("r", "x", false)
    eq({ "invalid-fuzzy-link", "invalid-fuzzy-link" }, checkers())
    -- g is not mapped: gg still goes to the first report
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys("gg", "x", false)
    eq(1, vim.api.nvim_win_get_cursor(0)[1])
    vim.cmd("lclose")
    eq(src, vim.api.nvim_get_current_buf())
  end)

  it("is available as an action and :Org lint", function()
    ok(require("org.actions").list.lint)
    org_buffer({ "[[nowhere]]" })
    vim.cmd("Org lint invalid-fuzzy-link")
    eq(1, #vim.fn.getloclist(0))
    vim.cmd("lclose")
  end)
end)

describe("lint SETUPFILE settings", function()
  it("checks INCLUDE searches with the target's own setup-file TODO keywords", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/sub", "p")
    vim.fn.writefile({ "#+TODO: WAIT | FIN" }, dir .. "/sub/todo.setup")
    vim.fn.writefile({ "#+SETUPFILE: todo.setup", "* WAIT Task" }, dir .. "/sub/other.org")
    local buf = org_buffer({ '#+INCLUDE: "sub/other.org::*Task"' })
    vim.api.nvim_buf_set_name(buf, dir .. "/main.org")
    local out = lint.lint(buf, { "wrong-include-link-parameter" })
    vim.fn.delete(dir, "rf")
    eq({}, out)
  end)

  it("ignores macros inside literal blocks of a setup file", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "#+begin_example", "#+MACRO: fake x", "#+end_example" }, dir .. "/m.setup")
    local buf = org_buffer({ "#+SETUPFILE: m.setup", "{{{fake}}}" })
    vim.api.nvim_buf_set_name(buf, dir .. "/main.org")
    local out = {}
    for _, r in ipairs(lint.lint(buf, { "invalid-macro-argument-and-template" })) do
      out[#out + 1] = r.message
    end
    vim.fn.delete(dir, "rf")
    eq({ 'Undefined macro "fake"' }, out)
  end)
end)

describe("lint checkers", function()
  it("has a function for every registered checker", function()
    local names = {}
    for _, c in ipairs(lint.checkers) do
      names[#names + 1] = c[1]
    end
    local buf = org_buffer({ "* TODO Heading", "Text with [[link]] and $x$." })
    for _, r in ipairs(lint.lint(buf, names)) do
      ok(not r.message:match("^Checker error"), r.checker .. ": " .. r.message)
    end
  end)
end)

describe("lint objects", function()
  --- Objects other than plain text that lint finds in `text`, as "type text".
  local function objects(text)
    local lines = vim.split(text, "\n", { plain = true })
    local buf = org_buffer(lines)
    local out = {}
    for _, o in ipairs(lint.document(buf, lines).objects) do
      if o.type ~= "plain-text" then
        out[#out + 1] = o.type .. " " .. o.s:sub(o.b, o.e - 1)
      end
    end
    return out
  end

  -- the closing marker found for one opening marker is reused for the next
  -- ones (a long paragraph of unclosed markers was quadratic): the results
  -- are those of a search from each opening marker
  it("finds the emphasis of a search from each opening marker", function()
    eq({ "bold *b *c d* " }, objects("a *b *c d* e"))
    eq({ "bold *a *b *c *d e*" }, objects("*a *b *c *d e*"))
    eq({ "bold *a b* ", "bold *d e* " }, objects("*a b* c *d e* f *g"))
    eq({ "italic /x *y /z w* q/ ", "bold *y /z w* " }, objects("/x *y /z w* q/ r"))
    eq({ "verbatim =a =b= " }, objects("=a =b= c= *d *e"))
    eq({ "bold *a\nb* ", "bold *d\ne *f* " }, objects("*a\nb* c *d\ne *f* g*"))
    eq({ "bold *a [[https://e.com][*l* ", "link https://e.com" }, objects("x *a [[https://e.com][*l* k]] b* y"))
  end)

  it("lints a long paragraph of unclosed markers without a colon quickly", function()
    local buf = org_buffer({ "* H", string.rep("*a /b =c ~d +e _f word ", 4000) })
    local t = vim.uv.hrtime()
    lint.lint(buf)
    local ms = (vim.uv.hrtime() - t) / 1e6
    -- (9 s before, 60 ms after on a laptop; `make coverage` runs with the
    -- JIT off and a line hook)
    ok(ms < 1000 * (tonumber(vim.env.ORG_PERF_SCALE or "") or 1) or under_coverage(), ms .. " ms")
  end)
end)
