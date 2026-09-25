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
    eq({ "1 Possibly misplaced heading line", "3 Possibly misplaced heading line" }, run({
      "Paragraph** Oops heading",
      "* Heading 1",
      "* Heading 2** Heading 3",
      "text",
    }, "misplaced-heading"))
  end)

  it("duplicates", function()
    eq({ '3 Duplicate CUSTOM_ID property "dup"', '7 Duplicate CUSTOM_ID property "dup"' }, run({
      "* A",
      ":PROPERTIES:",
      ":CUSTOM_ID: dup",
      ":END:",
      "* B",
      ":PROPERTIES:",
      ":CUSTOM_ID: dup",
      ":END:",
    }, "duplicate-custom-id"))
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
      { "2 Deprecated syntax for export block.  Use \"BEGIN_EXPORT html\" instead" },
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
    eq({
      "1 Potentially malformed timestamp <2024-01-01> .  Parsed as: <2024-01-01 Mon> ",
      "1 Potentially malformed timestamp <2024-01-01 Mon 9:00>.  Parsed as: <2024-01-01 Mon 09:00>",
      "2 Potentially malformed timestamp <2024-02-30> .  Parsed as: <2024-03-01 Fri> ",
    }, run({
      "At <2024-01-01> and <2024-01-01 Mon 9:00>",
      "Also <2024-02-30> and <2024-01-01 Mon>--<2024-01-03 Wed>",
    }, "timestamp-syntax"))
    eq({
      "2 Potentially malformed CLOCK: line\n           CLOCK: [2024-01-01 Mon 10:00]--[2024-01-01 Mon 11:05] => 1:05"
        .. "\nParsed as: CLOCK: [2024-01-01 Mon 10:00]--[2024-01-01 Mon 11:05] =>  1:05",
    }, run({
      "* H",
      "CLOCK: [2024-01-01 Mon 10:00]--[2024-01-01 Mon 11:05] => 1:05",
      "CLOCK: [2024-01-01 Mon 10:00]--[2024-01-01 Mon 11:05] =>  1:05",
    }, "clock-syntax"))
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
    eq({
      '2 Unused placeholders in macro "bad"',
      '3 Missing template in macro "%s"',
      '4 Missing argument in macro "greet"',
      '4 Spurious argument in macro "greet": b',
      '4 Missing argument in macro "title"',
      '4 Undefined macro "nope"',
      '4 Spurious arguments in macro "bad": 3, 4',
    }, run({
      "#+MACRO: greet Hello $1",
      "#+MACRO: bad Hi $2",
      "#+MACRO: empty",
      "{{{greet}}} {{{greet(a,b)}}} {{{title}}} {{{nope}}} {{{bad(1,2,3,4)}}} {{{n}}}",
    }, "invalid-macro-argument-and-template"))
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
    eq({ 1, 2, 3 }, vim.tbl_map(function(r)
      return r.lnum
    end, reports))
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

  it("is available as an action and :Org lint", function()
    ok(require("org.actions").list.lint)
    org_buffer({ "[[nowhere]]" })
    vim.cmd("Org lint invalid-fuzzy-link")
    eq(1, #vim.fn.getloclist(0))
    vim.cmd("lclose")
  end)
end)
