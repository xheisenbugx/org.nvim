-- The parser highlighter: links, footnotes, targets, macros, export
-- snippets, inline src blocks and line breaks (org.ui.highlight.object),
-- and their groups. What Emacs draws is compared in
-- emacs_faces_object_spec.lua; this spec checks the groups, spelling, the
-- options and the time.
local hl = require("tests.helpers.highlighter")
local groups, has = hl.groups, hl.has

local deco = require("org.ui.decorations")

--- The column (1-based) of the first `s` in line l.
local function col(l, s)
  return assert(vim.fn.getline(l):find(s, 1, true), s)
end

--- Line l as shown, without what the marks hide.
local function shown(l)
  local out, line = {}, vim.fn.getline(l)
  for c = 1, #line do
    if not has(l, c, "conceal") then
      out[#out + 1] = line:sub(c, c)
    end
  end
  return table.concat(out)
end

--- The marks of group `group` on 0-based row `row`.
local function marks_of(buf, row, group)
  local out = {}
  for _, m in ipairs(deco.line_marks(buf, row)) do
    if (m[2].hl_group or ""):lower() == group:lower() then
      out[#out + 1] = m
    end
  end
  return out
end

--- Whether byte c (1-based) of line l is left out of spell checking.
local function nospell(buf, l, c)
  for _, m in ipairs(deco.line_marks(buf, l - 1)) do
    if c - 1 >= m[1] and c - 1 < (m[2].end_col or m[1] + 1) and m[2].spell == false then
      return true
    end
  end
  return false
end

describe("parser highlighter: objects", function()
  with_config({ ui = { hide_emphasis_markers = true } })

  it("draws objects with marks, not with syntax regions", function()
    org_buffer({ "a [[x][y]] https://x.org [fn:1] <<t>> {{{m}}} @@b:v@@ src_sh{ls} \\\\" }, { 1, 0 })
    for c = 1, #vim.fn.getline(1) do
      eq({}, vim.fn.synstack(1, c))
    end
    ok(has(1, col(1, "[[x"), "orglink"), groups(1, col(1, "[[x")))
    ok(has(1, col(1, "https"), "orglinkplain"))
    ok(has(1, col(1, "fn:1"), "orgfootnote"))
    ok(has(1, col(1, "<<t"), "orgtarget"))
    ok(has(1, col(1, "{{{"), "orgmacro"))
    ok(has(1, col(1, "src_"), "orginlinesrcmarker"))
    ok(has(1, col(1, "\\\\"), "orglinebreak"))
  end)

  describe("links", function()
    it("draws a bracket link whole, and the part on the next line of one over a line break", function()
      org_buffer({ "see [[https://example.com][a long", "description]] here" })
      eq("see a long", shown(1))
      eq("description here", shown(2))
      for _, c in ipairs({ col(1, "[["), col(1, "a long"), #"see [[https://example.com][a long" }) do
        ok(has(1, c, "orglink"), groups(1, c))
      end
      ok(has(2, 1, "orglink"), groups(2, 1))
      ok(has(2, col(2, "]]") + 1, "orglink"), groups(2, col(2, "]]") + 1))
      ok(not has(2, col(2, "here"), "orglink"), groups(2, col(2, "here")))
    end)

    it("highlights angle links whole and plain links after _", function()
      org_buffer({
        "open <file:my notes.org> or <https://example.com/a b> now",
        "x _https://example.com and xhttps://b.com",
      })
      for _, w in ipairs({ "<file", "notes.org>", "<https", " b>" }) do
        ok(has(1, col(1, w) + 1, "orglinkplain"), w .. ": " .. groups(1, col(1, w) + 1))
      end
      ok(not has(1, col(1, " now") + 1, "orglinkplain"), groups(1, col(1, " now") + 1))
      ok(has(2, 4, "orglinkplain"), groups(2, 4))
      ok(not has(2, col(2, "xhttps") + 1, "orglinkplain"), groups(2, col(2, "xhttps") + 1))
    end)

    -- lisp.vim and sh.vim set `syn iskeyword` for the whole buffer
    it("finds plain links after - and < with an emacs-lisp or sh block", function()
      for _, lang in ipairs({ "emacs-lisp", "sh" }) do
        org_buffer({ "* H", "#+begin_src " .. lang, "x", "#+end_src", "see <https://x.org> and text-https://a.org" })
        ok(has(5, col(5, "https://x"), "orglinkplain"), lang .. ": " .. groups(5, col(5, "https://x")))
        ok(has(5, col(5, "https://a"), "orglinkplain"), lang .. ": " .. groups(5, col(5, "https://a")))
      end
    end)

    it("leaves trailing punctuation out of plain links and keeps parentheses", function()
      org_buffer({ "a https://x.org/a_(b). and file:a.org, end" })
      local line = vim.fn.getline(1)
      ok(has(1, col(1, "(b)") + 2, "orglinkplain"), groups(1, col(1, "(b)") + 2))
      ok(not has(1, col(1, "). and") + 1, "orglinkplain"), groups(1, col(1, "). and") + 1))
      ok(has(1, col(1, "a.org"), "orglinkplain"))
      ok(not has(1, col(1, ", end"), "orglinkplain"), line)
    end)

    it("activates links in property values, comments, #+TITLE and #+AUTHOR", function()
      local buf = org_buffer({
        "* H",
        ":PROPERTIES:",
        ":URL:      [[https://example.com][Example]]",
        ":SRC: https://example.com/x",
        ":END:",
        "# see [[https://example.com][Example]]",
        "#+TITLE: Notes on [[https://example.com][Example]]",
        "#+AUTHOR: Me [[mailto:me@x.org][mail]]",
      })
      eq(":URL:      Example", shown(3))
      ok(has(3, col(3, "Example"), "orglink"), groups(3, col(3, "Example")))
      ok(has(4, 8, "orglinkplain"), groups(4, 8))
      eq("# see Example", shown(6))
      eq("#+TITLE: Notes on Example", shown(7))
      eq("#+AUTHOR: Me mail", shown(8))
      -- Emacs draws comments and info keywords in their own face, over the
      -- links' (org-fontify-meta-lines-and-blocks), but leaves the links
      -- out of spell checking
      for _, l in ipairs({ 6, 7, 8 }) do
        local c = col(l, "[[") + 2
        ok(not has(l, c, "orglink"), groups(l, c))
        ok(nospell(buf, l, c), l)
      end
    end)

    it("draws links in verbatim, fixed width lines, tables and quote blocks, not in src blocks", function()
      org_buffer({
        "=see [[https://x.org]]= and ~https://y.org~",
        ": fixed https://x.org",
        "| [[https://x.org][x]] |",
        "#+begin_quote",
        "quoted https://x.org",
        "#+end_quote",
        "#+begin_src sh",
        "echo https://x.org",
        "#+end_src",
      })
      ok(has(1, col(1, "[[") + 2, "orglink"), groups(1, col(1, "[[") + 2))
      ok(has(1, col(1, "y.org"), "orglinkplain"), groups(1, col(1, "y.org")))
      ok(has(2, col(2, "https"), "orglinkplain"), groups(2, col(2, "https")))
      ok(has(3, col(3, "[[") + 2, "orglink"), groups(3, col(3, "[[") + 2))
      ok(has(5, col(5, "https"), "orglinkplain"), groups(5, col(5, "https")))
      ok(not has(8, col(8, "https"), "orglinkplain"), groups(8, col(8, "https")))
    end)

    it("draws custom link types in their face (links.types.<name>.face)", function()
      require("org.config").opts.links.types = { jira = { follow = function() end, face = "ErrorMsg" } }
      org_buffer({ "[[jira:X-1]] jira:Y-2 <jira:Z-3> and [[https://x.org]]" })
      for _, w in ipairs({ "[[jira", "X-1", "jira:Y", "Z-3" }) do
        ok(has(1, col(1, w), "orglinktype_jira"), w .. ": " .. groups(1, col(1, w)))
      end
      ok(has(1, col(1, "https"), "orglink") and not has(1, col(1, "https"), "orglinktype_jira"))
      eq("ErrorMsg", vim.api.nvim_get_hl(0, { name = "orgLinkType_jira" }).link)
      require("org.config").opts.links.types = {}
    end)

    it("highlights radio links: any case, over a line break, whole words only", function()
      org_buffer({ "<<<my radio>>>", "a My Radio b and xmy radio", "and MY", "  radio end", "=<<<not one>>>= not one" })
      ok(has(1, col(1, "my"), "orgradiolink"), groups(1, col(1, "my")))
      ok(has(1, 1, "orgtarget"), groups(1, 1))
      ok(has(2, col(2, "My"), "orgradiolink"), groups(2, col(2, "My")))
      ok(has(2, col(2, "Radio") + 4, "orgradiolink"))
      eq("", groups(2, 1))
      ok(not has(2, col(2, "xmy") + 1, "orgradiolink"), groups(2, col(2, "xmy") + 1))
      ok(has(3, col(3, "MY"), "orgradiolink"), groups(3, col(3, "MY")))
      ok(has(4, col(4, "radio"), "orgradiolink"), groups(4, col(4, "radio")))
      -- (a radio target in verbatim is text)
      ok(not has(5, col(5, " not one") + 1, "orgradiolink"), groups(5, col(5, " not one") + 1))
    end)
  end)

  describe("footnotes", function()
    it("keeps whole inline footnotes with brackets and links inside", function()
      org_buffer({
        "a [fn:: see [[https://x.org][x]] here] b",
        "c [fn:: a [b] c] d",
        "x [fn:: note <2026-10-02 Fri>] y",
      })
      eq("a [fn:: see x here] b", shown(1))
      ok(has(1, col(1, "here"), "orgfootnote"), groups(1, col(1, "here")))
      ok(has(1, col(1, "] b"), "orgfootnote"), groups(1, col(1, "] b")))
      ok(not has(1, col(1, " b"), "orgfootnote"), groups(1, col(1, " b")))
      ok(has(2, col(2, " c]"), "orgfootnote"), groups(2, col(2, " c]")))
      ok(has(3, col(3, "2026"), "orgfootnote"), groups(3, col(3, "2026")))
    end)

    it("highlights footnotes in quote blocks and table rows", function()
      org_buffer({ "#+begin_quote", "- a +strike+ [fn:1]", "#+end_quote", "| _u_ | [fn:1] |" })
      ok(has(2, col(2, "fn:1"), "orgfootnote"), groups(2, col(2, "fn:1")))
      ok(has(4, col(4, "fn:1"), "orgfootnote"), groups(4, col(4, "fn:1")))
    end)

    it("draws definitions at the start of a line, not in comments or fixed width lines", function()
      org_buffer({
        "[fn:1] A note.",
        "  [fn:2] indented",
        "# [fn:3] comment",
        ": [fn:4] fixed",
        "#+begin_comment",
        "[fn:5] x",
        "#+end_comment",
      })
      ok(has(1, 2, "orgfootnote"), groups(1, 2))
      ok(not has(1, col(1, "A note"), "orgfootnote"), groups(1, col(1, "A note")))
      ok(has(2, col(2, "fn:2"), "orgfootnote"), groups(2, col(2, "fn:2")))
      ok(not has(3, col(3, "fn:3"), "orgfootnote"), groups(3, col(3, "fn:3")))
      -- (a reference anywhere but at the start of a line, Emacs's
      -- org-activate-footnote-links)
      ok(has(4, col(4, "fn:4"), "orgfootnote"), groups(4, col(4, "fn:4")))
      ok(not has(6, 2, "orgfootnote"), groups(6, 2))
    end)

    it("isn't a footnote in a bracket link, after a LaTeX macro, unclosed or with a bad label", function()
      org_buffer({ "a [[fn:1]] b \\ref[fn:2] c [fn:bad label] d [fn:] e [fn:: open", "f" })
      for _, w in ipairs({ "fn:1", "fn:2", "fn:bad", "fn:]", "fn:: open" }) do
        ok(not has(1, col(1, w), "orgfootnote"), w .. ": " .. groups(1, col(1, w)))
      end
    end)

    it("ends inline footnotes as scan-sexps does: strings and angles", function()
      org_buffer({ 'a [fn:: "x ] y" z] b [fn:: c > d] e' })
      ok(has(1, col(1, "z]"), "orgfootnote"), groups(1, col(1, "z]")))
      ok(has(1, col(1, "> d"), "orgfootnote"), groups(1, col(1, "> d")))
      ok(not has(1, col(1, " d]"), "orgfootnote"), groups(1, col(1, " d]")))
    end)
  end)

  describe("targets, macros, snippets, inline src blocks", function()
    it("highlights markup, footnotes, macros and targets in table rows", function()
      org_buffer({ "| _u_ | +s+ | [fn:1] | {{{m}}} | [1/2] | <<tgt>> |" })
      ok(has(1, col(1, "fn:1"), "orgfootnote"), groups(1, col(1, "fn:1")))
      ok(has(1, col(1, "{{{"), "orgmacro"), groups(1, col(1, "{{{")))
      ok(has(1, col(1, "tgt"), "orgtarget"), groups(1, col(1, "tgt")))
    end)

    it("draws targets as org-target-regexp matches them", function()
      org_buffer({ "a <<t>> <<<r>>> << s>> <<s >> <<a<b>> <<x>>>" })
      ok(has(1, col(1, "<<t"), "orgtarget") and has(1, col(1, "t>>") + 2, "orgtarget"))
      ok(has(1, col(1, "<<<r"), "orgtarget") and has(1, col(1, "r>>>") + 3, "orgtarget"))
      -- (no blank after "<<" or before ">>", no angle in it)
      for _, w in ipairs({ "<< s", "<<s >>", "<<a<", "b>>" }) do
        ok(not has(1, col(1, w), "orgtarget"), w .. ": " .. groups(1, col(1, w)))
      end
      ok(has(1, col(1, "<<x"), "orgtarget") and not has(1, col(1, "x>>>") + 3, "orgtarget"))
    end)

    it("draws macros up to the first }}} before an empty line", function()
      org_buffer({ "a {{{m(1, 2)}}} {{{1x}}} {{{over", "a line}}} b {{{open", "", "c}}}" })
      ok(has(1, col(1, "m(1"), "orgmacro"), groups(1, col(1, "m(1")))
      ok(has(1, col(1, "{{{"), "orgmacromarker"), groups(1, col(1, "{{{")))
      ok(not has(1, col(1, "1x"), "orgmacro"), groups(1, col(1, "1x")))
      ok(has(2, 1, "orgmacro"), groups(2, 1))
      ok(not has(2, col(2, "open"), "orgmacro"), groups(2, col(2, "open")))
      ok(not has(4, 1, "orgmacro"), groups(4, 1))
    end)

    it("hide_macro_markers hides the braces of macros", function()
      require("org.config").opts.ui.hide_macro_markers = true
      org_buffer({ "a {{{m(1)}}} b" })
      eq("a m(1) b", shown(1))
      ok(has(1, 6, "orgmacro"), groups(1, 6))
      require("org.config").opts.ui.hide_macro_markers = false
      org_buffer({ "a {{{m(1)}}} b" })
      eq("a {{{m(1)}}} b", shown(1))
    end)

    it("highlights inline src blocks and export snippets", function()
      org_buffer({ "Run src_python{print(1)} and src_sh[:results raw]{ls} now.", "a @@html:<b>@@ bold @@HTML:x@@" })
      ok(has(1, 5, "orginlinesrcmarker"), groups(1, 5))
      ok(has(1, 9, "orginlinesrclang"), groups(1, 9))
      ok(has(1, 17, "orginlinesrcbody"), groups(1, 17))
      ok(has(1, col(1, "{print"), "orginlinesrcmarker"), groups(1, col(1, "{print")))
      ok(has(1, col(1, "[:res") + 1, "orginlinesrcheader"), groups(1, col(1, "[:res") + 1))
      ok(has(2, 3, "orgexportsnippetmarker"), groups(2, 3))
      ok(has(2, 5, "orgexportsnippetbackend"), groups(2, 5))
      ok(not has(2, col(2, "<b>"), "orgexportsnippetbackend"), groups(2, col(2, "<b>")))
      ok(not has(2, col(2, "@@HTML"), "orgexportsnippetmarker"), groups(2, col(2, "@@HTML")))
    end)

    it("draws inline src blocks as Emacs does: bare, nested braces, over a line break", function()
      org_buffer({ "a src_sh b xsrc_sh{x} c src_sh{a {b} c} d src_sh{x", "y} e src_sh{https://x.org} f" })
      ok(has(1, col(1, "src_sh b"), "orginlinesrcmarker"), groups(1, col(1, "src_sh b")))
      ok(has(1, col(1, "sh b"), "orginlinesrclang"), groups(1, col(1, "sh b")))
      ok(not has(1, col(1, "xsrc") + 1, "orginlinesrcmarker"), groups(1, col(1, "xsrc") + 1))
      ok(has(1, col(1, "c}"), "orginlinesrcbody"), groups(1, col(1, "c}")))
      ok(has(1, col(1, "c} d") + 1, "orginlinesrcmarker"), groups(1, col(1, "c} d") + 1))
      ok(has(2, 1, "orginlinesrcbody"), groups(2, 1))
      ok(has(2, 2, "orginlinesrcmarker"), groups(2, 2))
      -- (the body is the language's: no link in it)
      ok(not has(2, col(2, "https"), "orglinkplain"), groups(2, col(2, "https")))
    end)

    it("takes the faces of the line off an inline src block's braces and body", function()
      -- (org-fontify-inline-src-blocks: src_LANG and [HEADERS] keep them)
      local buf = org_buffer({
        "* TODO A src_sh[:x y]{echo x} b :tag:",
        "| a | src_sh{t} |",
        "- term src_sh{x} :: d",
        "# a comment src_sh{c} *b*",
        "#+begin_src sh",
        "echo src_sh{z}",
        "#+end_src",
        "A [[https://x.org][d src_sh{l} e]] f.",
      })
      ---@type { [1]: integer, [2]: string, [3]: string }[] line, text, group
      local cases = {
        { 1, "A src", "orgheadlinelevel1" },
        { 2, "| a", "orgtable" },
        { 3, "term", "orglistterm" },
        { 4, "# a", "orgcomment" },
        { 6, "echo", "orgsrcblock" },
        { 8, "d src", "orglink" },
      }
      for _, c in ipairs(cases) do
        local l, text, group = c[1], c[2], c[3]
        ok(has(l, col(l, text), group), groups(l, col(l, text)))
        -- src_ and the language keep the line's face
        ok(has(l, col(l, "src_"), group), groups(l, col(l, "src_")))
        ok(has(l, col(l, "src_") + 4, group), groups(l, col(l, "src_") + 4))
        local open = col(l, "{")
        local close = vim.fn.getline(l):find("}", open, true)
        for x = open, close do
          ok(not has(l, x, group), l .. ":" .. x .. " " .. groups(l, x))
        end
        ok(has(l, open, "orginlinesrcmarker"), groups(l, open))
        ok(has(l, close, "orginlinesrcmarker"), groups(l, close))
        if close < #vim.fn.getline(l) - 1 then
          ok(has(l, close + 1, group), l .. ":" .. (close + 1) .. " " .. groups(l, close + 1))
        end
      end
      -- the header keeps the headline's face, the tags theirs
      ok(has(1, col(1, ":x y"), "orgheadlinelevel1"), groups(1, col(1, ":x y")))
      ok(has(1, col(1, ":tag"), "orgtags"), groups(1, col(1, ":tag")))
      -- what the link hides stays hidden, and the body stays out of spell
      -- checking
      ok(has(8, col(8, "[[https"), "conceal"), groups(8, col(8, "[[https")))
      ok(nospell(buf, 8, col(8, "{l}") + 1))
    end)

    it("highlights line breaks", function()
      org_buffer({ "a line \\\\", "b \\\\ c" })
      ok(has(1, col(1, "\\\\"), "orglinebreak"), groups(1, col(1, "\\\\")))
      ok(not has(2, col(2, "\\\\"), "orglinebreak"), groups(2, col(2, "\\\\")))
    end)
  end)

  it("draws man: as a link in brackets only, and opens it plain too", function()
    -- (Emacs knows man: only with ol-man, not in the default org-modules)
    local buf = org_buffer({ "see man:printf(3) and <man:ls(1)> and [[man:ls]]" }, { 1, 0 })
    eq({}, marks_of(buf, 0, "orgLinkPlain"))
    eq(1, #marks_of(buf, 0, "orgLink"))
    eq(col(1, "[[man") - 1, marks_of(buf, 0, "orgLink")[1][1])
    local found = require("org.links").parse_links("see man:printf(3) and")
    eq("man:printf(3)", found[1] and found[1].raw)
    -- (a type of `links.types` named man is a link type again)
    local opts = require("org.config").opts.links
    local types = opts.types
    opts.types = { man = { follow = function() end } }
    deco.render(buf)
    local plain = false
    for _, m in ipairs(deco.line_marks(buf, 0)) do
      plain = plain or (m[1] == col(1, "man:") - 1 and (m[2].hl_group or ""):find("^orgLink") ~= nil)
    end
    opts.types = types
    deco.render(buf)
    ok(plain)
  end)

  it("draws a macro or a footnote over a #+TITLE: line in the blanks after the keyword", function()
    local buf = org_buffer({ "a {{{m(b", "#+TITLE:  title", "c)}}} [fn:: d", "#+AUTHOR: me", "e]" }, { 1, 0 })
    local m = marks_of(buf, 1, "orgMacro")
    eq(1, #m)
    eq({ 8, 10 }, { m[1][1], m[1][2].end_col })
    local f = marks_of(buf, 3, "orgFootnote")
    eq(1, #f)
    eq({ 9, 10 }, { f[1][1], f[1][2].end_col })
  end)

  it("leaves objects out of spell checking, but not the text of inline footnotes", function()
    local buf = org_buffer({
      "[[https://teh.org][teh]] https://teh.org <<teh>> {{{teh}}} @@teh:x@@ src_teh{teh} [fn:teh] [fn:: teh note] \\\\",
    })
    for _, w in ipairs({ "[[https", "teh]]", "https://teh", "<<teh", "{{{teh", "@@teh", "src_teh", "[fn:teh]", "[fn::" }) do
      ok(nospell(buf, 1, col(1, w)), w)
    end
    ok(not nospell(buf, 1, col(1, "teh note")))
    ok(nospell(buf, 1, col(1, "\\\\")))
  end)

  it("draws long lines of objects in linear time", function()
    local E = require("org.ui.emphasis")
    local object = require("org.ui.highlight.object")
    -- (the part alone, on a line of `unit` n times)
    local function time(unit, n)
      local lines = { string.rep(unit, n), "<<<radio x>>>" }
      local kinds, roles = E.kinds(lines)
      local count = 0
      local ctx = {
        bufnr = 0,
        ui = {},
        file = { lines = lines },
        lines = lines,
        row0 = 0,
        first = 0,
        last = 1,
        kinds = kinds,
        roles = roles,
        emit = function()
          count = count + 1
        end,
        cancel = function()
          count = count + 1
        end,
        get_line = function() end,
      }
      local t = vim.uv.hrtime()
      object.paint(ctx)
      return (vim.uv.hrtime() - t) / 1e6, count
    end
    for _, unit in ipairs({
      "[[a][b]] c:d https://x.org/(a) [fn:: x [fn:1] (y] <<t>> {{{m}}} @@b:v@@ src_s{x} radio x ",
      -- unclosed: each opening is tried
      "[fn:: a (b [fn:: c ",
      "{{{m <<a <<<b @@c:d ",
      "src_a{ src_b[x src_c{ ",
    }) do
      time(unit, 10)
      -- (about 20k then 200k characters)
      local small, made = time(unit, math.floor(20000 / #unit))
      local big = time(unit, math.floor(200000 / #unit))
      ok(made > 0, unit)
      ok(big < math.max(small, 1) * 40, string.format("%s: %.1f ms then %.1f ms", unit, small, big))
    end
  end)
end)
