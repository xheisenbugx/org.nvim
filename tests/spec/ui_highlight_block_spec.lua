-- Blocks and LaTeX drawn by the parser highlighter (org.ui.highlight.block):
-- the rules of org.syntax for them, ported (ui_syntax_highlighting_spec.lua,
-- display_emacs_spec.lua, syntax_long_lines_spec.lua), and spelling, a
-- part of a buffer drawn alone and the time on long lines. What Emacs
-- draws is compared in emacs_faces_block_spec.lua.
local hl = require("tests.helpers.highlighter")
local deco = require("org.ui.decorations")

local groups, has = hl.groups, hl.has

--- The marks of group `group` on line `l` (1-based), as "start-end".
local function spans(l, group)
  local out = {}
  for _, m in ipairs(deco.line_marks(vim.api.nvim_get_current_buf(), l - 1)) do
    if m[2].hl_group == group then
      out[#out + 1] = m[1] .. "-" .. m[2].end_col
    end
  end
  table.sort(out)
  return out
end

--- Whether every mark that covers byte `c` (1-based) of line `l` and sets
--- `spell` sets it false, and one does.
local function nospell(l, c)
  local seen = false
  for _, m in ipairs(deco.line_marks(vim.api.nvim_get_current_buf(), l - 1)) do
    local o = m[2]
    if c - 1 >= m[1] and c - 1 < (o.end_col or m[1] + 1) and o.spell ~= nil then
      if o.spell ~= false then
        return false
      end
      seen = true
    end
  end
  return seen
end

--- The column (1-based) of the first `s` in line l.
local function col(l, s)
  return assert(vim.fn.getline(l):find(s, 1, true), s)
end

local function ui(over)
  return vim.tbl_extend("force", vim.deepcopy(require("org.config").opts.ui), { highlighter = "parser" }, over or {})
end

describe("parser highlighter: blocks", function()
  with_config({ ui = { highlighter = "parser", hide_emphasis_markers = true } })

  it("draws begin and end lines whole, never spell checked", function()
    org_buffer({
      "#+begin_src emacs-lisp :results silent",
      "(+ 1 2)",
      "#+end_src",
      "  #+BEGIN_QUOTE with words",
      "  quoted",
      "  #+END_QUOTE",
      "#+begin_note",
      "special",
      "#+end_note",
    })
    for _, l in ipairs({ 1, 3, 4, 6, 7, 9 }) do
      eq({ "0-" .. #vim.fn.getline(l) }, spans(l, "orgBlockDelimiter"))
      ok(nospell(l, 2), "line " .. l)
    end
    ok(not has(2, 1, "orgblockdelimiter"), groups(2, 1))
  end)

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
    ok(has(2, 1, "orgblockdelimiter"), groups(2, 1))
    ok(has(3, 1, "orgquoteblock"), groups(3, 1))
    ok(not has(4, 3, "orgquoteblock"), groups(4, 3))
    ok(not has(4, 1, "orgblockdelimiter"), groups(4, 1))
    ok(has(7, 1, "orgblockdelimiter"), groups(7, 1))
    -- the headline ends the example: its end line closes nothing
    ok(not has(8, 1, "orgblock"), groups(8, 1))
    ok(not has(9, 1, "orgblockdelimiter"), groups(9, 1))
    ok(has(10, 1, "orgblockdelimiter"), groups(10, 1))
    ok(not has(12, 1, "orgblock") and not has(12, 1, "orgblockdelimiter"), groups(12, 1))
  end)

  it("leaves a block without an end line or headline after it unhighlighted", function()
    org_buffer({ "#+begin_example", "open to the end" })
    ok(not has(1, 1, "orgblockdelimiter"), groups(1, 1))
    ok(not has(2, 1, "orgblock"), groups(2, 1))
  end)

  it("closes a block only with an end line of its name", function()
    org_buffer({ "#+begin_verse", "a", "#+end_verse1", "#+end_verse_", "after" })
    ok(has(3, 1, "orgquoteblock") and not has(3, 1, "orgblockdelimiter"), groups(3, 1))
    ok(has(4, 1, "orgblockdelimiter"), groups(4, 1))
    ok(not has(5, 1, "orgquoteblock"), groups(5, 1))
  end)

  it("draws example and export bodies in orgBlock, out of spell checking", function()
    org_buffer({
      "#+begin_example -n",
      "teh *not bold* | not a table |",
      "# not a comment",
      "#+end_example",
      "#+begin_src",
      "no language",
      "#+end_src",
      "#+begin_src unknown-language-xyz",
      "x",
      "#+end_src",
      "",
      "#+begin_example",
      "#+end_example",
    })
    for _, l in ipairs({ 2, 3, 6, 9 }) do
      eq({ "0-" .. #vim.fn.getline(l) }, spans(l, "orgBlock"))
      ok(nospell(l, 1), "line " .. l)
    end
    ok(not has(2, col(2, "not bold"), "orgbold"), groups(2, col(2, "not bold")))
    eq({}, spans(11, "orgBlock"))
  end)

  it("leaves the body of a src block to its language's highlighter", function()
    org_buffer({ "#+begin_src lua", "local x = 1 -- teh", "#+end_src" })
    local how = require("org.ui.highlight.block")._drawn_by("lua")
    ok(how, "lua is drawn by tree-sitter or its syntax")
    -- org-block under the language's faces: a group without attributes
    eq({}, spans(2, "orgBlock"))
    eq({ "0-18" }, spans(2, "orgSrcBlock"))
    eq({}, vim.api.nvim_get_hl(0, { name = "orgSrcBlock" }))
    if how == "treesitter" then
      ok(nospell(2, 1))
    end
  end)

  it("draws src bodies in orgBlock when src highlighting is off", function()
    require("org.config").opts.ui.src_highlight = false
    org_buffer({ "#+begin_src lua", "local x = 1", "#+end_src" })
    eq({ "0-11" }, spans(2, "orgBlock"))
    ok(nospell(2, 1))
    require("org.config").opts.ui.src_highlight = nil
  end)

  it("highlights quote and verse contents as Org text on orgQuoteBlock", function()
    org_buffer({
      "#+begin_quote",
      "- item <2026-01-01 Thu> +strike+ [fn:1]",
      "| a | b |",
      "#+begin_src emacs-lisp",
      "(in the quote)",
      "#+end_src",
      "#+end_quote",
      "#+begin_verse",
      "  Roses are *red*,",
      "#+end_verse",
    })
    for _, l in ipairs({ 2, 3, 4, 5, 6, 9 }) do
      eq({ "0-" .. #vim.fn.getline(l) }, spans(l, "orgQuoteBlock"))
    end
    ok(has(2, col(2, "trike"), "orgstrikethrough"), groups(2, col(2, "trike")))
    -- (Emacs: a block in a quote block is quote text)
    ok(not has(4, 1, "orgblockdelimiter"), groups(4, 1))
    ok(not has(5, 1, "orgblock"), groups(5, 1))
    ok(has(7, 1, "orgblockdelimiter"), groups(7, 1))
    ok(has(9, col(9, "red"), "orgbold"), groups(9, col(9, "red")))
  end)

  it("spell checks quote, verse and comment blocks", function()
    org_buffer({ "#+begin_quote", "teh wrod", "#+end_quote", "#+begin_comment", "teh", "#+end_comment" })
    ok(not nospell(2, 1))
    ok(not nospell(5, 1))
    for _, m in ipairs(deco.line_marks(0, 1)) do
      ok(m[2].spell ~= false, vim.inspect(m))
    end
  end)

  -- Emacs: comment, center and special blocks aren't protecting blocks:
  -- their body is Org text, without a face of the block
  it("highlights only the delimiter lines of comment, center and special blocks", function()
    org_buffer({
      "#+begin_comment",
      "A *comment* block.",
      "#+end_comment",
      "#+begin_center",
      "| c | d |",
      "#+end_center",
      "#+begin_note",
      "*bold* in a special block",
      "#+end_note",
    })
    for _, l in ipairs({ 2, 5, 8 }) do
      eq({}, spans(l, "orgBlock"))
      eq({}, spans(l, "orgQuoteBlock"))
      eq({}, spans(l, "orgBlockDelimiter"))
    end
    ok(has(2, col(2, "comment*"), "orgbold"), groups(2, col(2, "comment*")))
    ok(has(8, 2, "orgbold"), groups(8, 2))
    ok(has(4, 1, "orgblockdelimiter") and has(9, 1, "orgblockdelimiter"))
  end)

  -- Emacs: #+BEGIN: and #+END: are keyword lines (org-meta-line), drawn by
  -- the keyword rule; the contents are Org text
  it("leaves a dynamic block's lines to the keyword rule", function()
    org_buffer({ "#+BEGIN: clocktable :scope file", "#+CAPTION: Clock summary", "Some *bold* note", "#+END:" })
    for l = 1, 4 do
      eq({}, spans(l, "orgBlockDelimiter"))
    end
    eq({ "11-24" }, spans(2, "orgBlock"))
    ok(has(3, 7, "orgbold"), groups(3, 7))
  end)

  -- org-fontify-meta-lines-and-blocks-1: the value of #+CAPTION is org-block
  it("draws the value of a caption in orgBlock", function()
    org_buffer({
      "#+CAPTION: A table",
      "#+caption[short]: The long one",
      "#+caption[a]: b]: c",
      "#+CAPTION:",
      "#+captions: no",
      "#+CAPTION:    blanks",
      "#+begin_quote",
      "#+caption: in a quote",
      "#+end_quote",
    })
    eq({ "11-18" }, spans(1, "orgBlock"))
    eq({ "18-30" }, spans(2, "orgBlock"))
    eq({ "18-19" }, spans(3, "orgBlock"))
    eq({}, spans(4, "orgBlock"))
    eq({}, spans(5, "orgBlock"))
    eq({ "14-20" }, spans(6, "orgBlock"))
    eq({}, spans(8, "orgBlock"))
    -- (spell checked, like Emacs's flyspell)
    ok(not nospell(1, 12))
  end)

  it("keeps a long block's middle lines block text when drawn alone", function()
    local lines = { "* Log", "#+begin_example" }
    for i = 1, 600 do
      lines[#lines + 1] = (i % 2 == 0) and ("# line " .. i) or ("| col | " .. i .. " |")
    end
    lines[#lines + 1] = "#+end_example"
    lines[#lines + 1] = "#+begin_src lua"
    for i = 1, 600 do
      lines[#lines + 1] = "local x" .. i .. " = " .. i
    end
    lines[#lines + 1] = "#+end_src"
    lines[#lines + 1] = "* After"
    org_buffer(lines)
    eq({ "0-" .. #lines[500] }, spans(500, "orgBlock"))
    eq({ "0-" .. #lines[501] }, spans(501, "orgBlock"))
    -- the language of a src block whose begin line is far above
    eq({}, spans(1000, "orgBlock"))
    eq({ "0-" .. #lines[1000] }, spans(1000, "orgSrcBlock"))
    eq({}, spans(#lines, "orgBlock"))
  end)

  it("draws long block lines in linear time", function()
    local function time(n)
      local body = string.rep("x $a \\( _b ", n)
      org_buffer({ "#+begin_example " .. body, body, "#+end_example", "#+begin_quote", body, "#+end_quote" })
      local t = vim.uv.hrtime()
      for row = 0, 5 do
        deco.compute(vim.api.nvim_get_current_buf(), row, row)
      end
      return (vim.uv.hrtime() - t) / 1e6
    end
    time(100)
    local small, big = time(2000), time(20000)
    ok(big < math.max(small, 1) * 40, string.format("%.1f ms then %.1f ms", small, big))
  end)
end)

describe("parser highlighter: latex", function()
  with_config({ ui = ui({ highlight_latex_and_related = { "latex", "entities" } }) })

  it("highlights only closed fragments, never past a headline", function()
    org_buffer({ "* H1", "text \\(x + y", "* H2", "para $$ a", "* H3", "\\begin{equation}", "x", "* H4", "\\(a\\) b" })
    for _, l in ipairs({ 1, 3, 5, 8 }) do
      ok(not has(l, 1, "orglatex"), l .. " " .. groups(l, 1))
    end
    ok(not has(2, 7, "orglatex"), groups(2, 7))
    ok(not has(6, 1, "orglatex"), groups(6, 1))
    eq({ "0-5" }, spans(9, "orgLatex"))
    ok(nospell(9, 2))
  end)

  it("highlights environments, from the start of the line", function()
    org_buffer({ "Text.", "  \\begin{equation}", "x = 1", "", "y = 2", "\\end{equation} after", "\\begin{x} \\end{x}" })
    eq({ "0-18" }, spans(2, "orgLatex"))
    eq({ "0-5" }, spans(3, "orgLatex"))
    eq({ "0-5" }, spans(5, "orgLatex"))
    eq({ "0-15" }, spans(6, "orgLatex"))
    eq({ "0-17" }, spans(7, "orgLatex"))
  end)

  it("highlights an environment open above the rows drawn", function()
    local lines = { "* H", "\\begin{align}" }
    for i = 1, 300 do
      lines[#lines + 1] = i % 3 == 0 and "" or ("a_" .. i .. " &= b \\\\")
    end
    lines[#lines + 1] = "\\end{align}"
    lines[#lines + 1] = "after"
    lines[#lines + 1] = "\\begin{open}"
    for i = 1, 300 do
      lines[#lines + 1] = i % 3 == 0 and "" or "no end"
    end
    org_buffer(lines)
    eq({ "0-" .. #lines[201] }, spans(201, "orgLatex"))
    eq({ "0-11" }, spans(303, "orgLatex"))
    eq({}, spans(304, "orgLatex"))
    eq({}, spans(500, "orgLatex"))
  end)

  it("highlights $ fragments the way org-latex-regexps finds them", function()
    org_buffer({
      "a $x$ b $x+y$, $ no$ $no $ $$d$$ c$5 $a$b",
      "$x",
      "y$ over two lines",
    })
    -- (not "$ no$", "$no $", "$5 $" nor "$a$b")
    eq({ "2-5", "27-32", "8-13" }, spans(1, "orgLatex"))
    eq({ "0-2" }, spans(2, "orgLatex"))
    eq({ "0-2" }, spans(3, "orgLatex"))
  end)

  it("draws no LaTeX in blocks, comments and keywords, but in quotes and tables", function()
    org_buffer({
      "#+begin_src latex",
      "\\(a\\)",
      "#+end_src",
      "# \\(a\\)",
      "#+keyword: \\(a\\)",
      "#+begin_quote",
      "\\(a\\) \\alpha",
      "#+end_quote",
      "| \\(a\\) |",
    })
    eq({}, spans(2, "orgLatex"))
    eq({}, spans(4, "orgLatex"))
    eq({}, spans(5, "orgLatex"))
    eq({ "0-5" }, spans(7, "orgLatex"))
    eq({ "6-12" }, spans(7, "orgLatexEntity"))
    eq({ "2-7" }, spans(9, "orgLatex"))
  end)

  it("draws long lines of unclosed fragments in linear time", function()
    local function time(n)
      org_buffer({ string.rep("x $a \\( \\[ $$ \\alpha_b ", n), "\\begin{e}" .. string.rep(" \\( y", n) })
      local t = vim.uv.hrtime()
      deco.compute(vim.api.nvim_get_current_buf(), 0, 0)
      deco.compute(vim.api.nvim_get_current_buf(), 1, 1)
      return (vim.uv.hrtime() - t) / 1e6
    end
    time(100)
    local small, big = time(1000), time(10000)
    ok(big < math.max(small, 1) * 40, string.format("%.1f ms then %.1f ms", small, big))
  end)
end)

describe("parser highlighter: highlight_latex_and_related", function()
  with_config({ ui = ui() })
  local text = { "x $a+b$ \\alpha, y_1" }
  local function names()
    local out = {}
    for c = 1, #text[1] do
      local g = groups(1, c):match("orglatex%a*") or ""
      out[c] = g
    end
    return out
  end

  it("highlights nothing by default", function()
    org_buffer(text)
    for _, n in ipairs(names()) do
      eq("", n)
    end
  end)

  it("picks what is highlighted", function()
    local opts = require("org.config").opts.ui
    opts.highlight_latex_and_related = { "latex" }
    org_buffer(text)
    local n = names()
    eq({ "orglatex", "orglatex", "", "" }, { n[3], n[7], n[9], n[18] })
    -- entities: \alpha and the comma after it
    opts.highlight_latex_and_related = { "entities" }
    org_buffer(text)
    n = names()
    eq({ "", "orglatexentity", "orglatexentity", "" }, { n[3], n[9], n[15], n[16] })
    -- script: _1, from the underscore
    opts.highlight_latex_and_related = { "script" }
    org_buffer(text)
    n = names()
    eq({ "", "orglatexscript", "orglatexscript" }, { n[17], n[18], n[19] })
    -- native: like latex
    opts.highlight_latex_and_related = { "native" }
    org_buffer(text)
    n = names()
    eq({ "orglatex", "orglatex" }, { n[3], n[7] })
  end)

  it("follows ui.use_sub_superscripts and #+OPTIONS: ^:", function()
    local opts = require("org.config").opts.ui
    opts.highlight_latex_and_related = { "script" }
    org_buffer({ "a_b c^{d} e_(f)" })
    eq({ "1-3", "11-15", "5-9" }, spans(1, "orgLatexScript"))
    org_buffer({ "#+OPTIONS: ^:{}", "a_b c^{d}" })
    eq({ "5-9" }, spans(2, "orgLatexScript"))
    opts.use_sub_superscripts = false
    org_buffer({ "a_b c^{d}" })
    eq({}, spans(1, "orgLatexScript"))
  end)

  it("takes scripts the way org-match-substring-regexp does", function()
    local opts = require("org.config").opts.ui
    opts.highlight_latex_and_related = { "script" }
    org_buffer({ "x_1.5a y^* z_{a{b}c} _x a_ b^+-c q^-2 w_a,b" })
    -- (not "_x" after a blank, "a_" without a body, "^+-c")
    eq({ "1-6", "12-20", "34-37", "39-43", "8-10" }, spans(1, "orgLatexScript"))
  end)
end)
