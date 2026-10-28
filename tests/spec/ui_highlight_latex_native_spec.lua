-- ui.highlight_latex_and_related = { "native" } with the parser
-- highlighter (org.ui.highlight.native): what org-do-latex-and-related
-- draws then, org-src-font-lock-fontify-block "latex" on the text found.
-- Emacs Org 9.8.12 (emacs -Q, org-highlight-latex-and-related '(native)):
--
--   Text $x^2$ and \(a+b\) and $$y$$ end.
--   -> " " org-block, "$x^" tex-math org-block, "2" tex-math superscript
--      org-block, "$" tex-math org-block, "\(" font-lock-keyword-face
--      org-block, "a+b" org-block, ... no org-latex-and-related
--   *bold $z$ here*   -> " $z$" without bold (its faces are taken off)
--   \begin{equation} / E = mc^2 % comment / \end{equation}
--   -> "\begin" keyword, "equation" function-name, "% comment" comment,
--      all on org-block
--   '(native entities script): "\alpha" keyword, "_1" org-block (and
--   subscript on "1"): entities and scripts are fontified natively too
--
-- Here the groups are Vim's tex syntax's (texMathZoneX, texStatement,
-- ...) over orgSrcBlock (org-block, like the body of a src block a syntax
-- draws).
local deco = require("org.ui.decorations")

--- The groups of the marks over byte `c` (1-based) of line `l`.
local function marks_at(l, c)
  local out = {}
  for _, m in ipairs(deco.line_marks(vim.api.nvim_get_current_buf(), l - 1)) do
    if c - 1 >= m[1] and c - 1 < (m[2].end_col or m[1] + 1) and m[2].hl_group then
      out[#out + 1] = m[2].hl_group
    end
  end
  table.sort(out)
  return out
end

local function has_tex(l, c)
  for _, g in ipairs(marks_at(l, c)) do
    if g:match("^tex") then
      return true
    end
  end
  return false
end

local function has(l, c, group)
  return vim.tbl_contains(marks_at(l, c), group)
end

--- The spans of `group` on line `l`, "start-end" (0-based, end exclusive).
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

describe("parser highlighter: highlight_latex_and_related native", function()
  with_config({ ui = { highlight_latex_and_related = { "native" } } })

  it("draws fragments with the tex syntax over orgSrcBlock, not orgLatex", function()
    org_buffer({ "Text $x^2$ and \\(a+b\\) and \\[ \\frac{1}{2} \\] and $$y$$ end." })
    -- (" $x^2$" with the blank before it, as org-latex-regexps matches it)
    eq({ "15-22", "27-44", "4-10", "49-54" }, spans(1, "orgSrcBlock"))
    eq({}, spans(1, "orgLatex"))
    for _, c in ipairs({ 6, 8, 10, 16, 17, 30, 50 }) do
      ok(has_tex(1, c), c .. ": " .. vim.inspect(marks_at(1, c)))
    end
    eq(
      "texMathZoneX",
      vim.tbl_filter(function(g)
        return g:match("^tex") ~= nil
      end, marks_at(1, 7))[1]
    )
    eq(
      "texStatement",
      vim.tbl_filter(function(g)
        return g:match("^tex") ~= nil
      end, marks_at(1, 31))[1]
    )
    -- nothing outside the fragments
    eq({}, marks_at(1, 1))
    eq({}, marks_at(1, 12))
  end)

  it("draws environments natively, comments and all", function()
    org_buffer({ "Para.", "\\begin{equation}", "E = mc^2 % comment", "\\end{equation}" })
    ok(has(2, 1, "orgSrcBlock") and has_tex(2, 1), vim.inspect(marks_at(2, 1)))
    ok(vim.tbl_contains(marks_at(3, 12), "texComment"), vim.inspect(marks_at(3, 12)))
    ok(has_tex(4, 2), vim.inspect(marks_at(4, 2)))
    eq({}, marks_at(1, 1))
  end)

  it("draws an environment open above the rows drawn from its begin line", function()
    local lines = { "* H", "\\begin{equation}" }
    for i = 1, 200 do
      lines[#lines + 1] = "a_" .. i .. " + b % c" .. i
    end
    lines[#lines + 1] = "\\end{equation}"
    local buf = org_buffer(lines)
    -- (row 150 alone: the scan starts below the begin line)
    local rows = deco.compute(buf, 150, 150)
    local found = {}
    for _, m in ipairs(rows[150] or {}) do
      found[m[2].hl_group] = true
    end
    ok(found.orgSrcBlock and found.texComment, vim.inspect(vim.tbl_keys(found)))
  end)

  it("draws entities and scripts natively when listed, never as errors", function()
    require("org.config").opts.ui.highlight_latex_and_related = { "native", "entities", "script" }
    org_buffer({ "Entity \\alpha, and y_1 here" })
    ok(has(1, 8, "orgSrcBlock") and has_tex(1, 8), vim.inspect(marks_at(1, 8)))
    eq({}, spans(1, "orgLatexEntity"))
    ok(has(1, 21, "orgSrcBlock"), vim.inspect(marks_at(1, 21)))
    for _, g in ipairs(marks_at(1, 21)) do
      ok(not g:find("Error") and g ~= "texOnlyMath", g)
    end
  end)

  it("draws no LaTeX in example blocks, comments and keywords", function()
    org_buffer({ "#+begin_example", "$x$ \\(a\\)", "#+end_example", "# \\(a\\)", "#+title: \\(a\\)" })
    eq({}, spans(2, "orgSrcBlock"))
    ok(not has_tex(2, 6), vim.inspect(marks_at(2, 6)))
    ok(not has_tex(4, 4), vim.inspect(marks_at(4, 4)))
    ok(not has_tex(5, 12), vim.inspect(marks_at(5, 12)))
  end)

  it("keeps the fragments' groups across redraws and edits", function()
    local buf = org_buffer({ "a \\(x\\) b" })
    ok(has_tex(1, 3))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a \\(xy\\) b" })
    ok(has_tex(1, 3), vim.inspect(marks_at(1, 3)))
    ok(has(1, 6, "orgSrcBlock"))
  end)
end)

describe("parser highlighter: native without the tex syntax", function()
  with_config({ ui = { highlight_latex_and_related = { "native" } } })

  it("draws org-block alone, as Emacs does without latex-mode", function()
    local N = require("org.ui.highlight.native")
    local available = N.available
    N.available = function()
      return false
    end
    local ok_, err = pcall(function()
      org_buffer({ "x \\(a\\) y" })
      eq({ "2-7" }, spans(1, "orgBlock"))
      ok(not has_tex(1, 4))
    end)
    N.available = available
    assert(ok_, err)
  end)
end)

describe("parser highlighter: latex without native", function()
  with_config({ ui = { highlight_latex_and_related = { "latex" } } })

  it("draws no tex groups", function()
    org_buffer({ "x \\(\\frac{a}{b}\\) $y$, z" })
    for c = 1, 22 do
      ok(not has_tex(1, c), c .. ": " .. vim.inspect(marks_at(1, c)))
    end
    -- (" $y$," as org-latex-regexps matches it: the blank before, the
    -- comma after)
    eq({ "17-22", "2-17" }, spans(1, "orgLatex"))
    -- (and the syntax has no tex in it either)
    eq({}, vim.fn.synstack(1, 6))
  end)
end)

describe("parser highlighter: an environment open above lines without LaTeX", function()
  with_config({ ui = { highlight_latex_and_related = { "latex" } } })

  it("draws them when it ends below them", function()
    -- (rows 100 to 150 have no backslash or dollar of their own: they were
    -- left plain when drawn alone)
    local lines = { "* H", "\\begin{equation}" }
    for i = 1, 200 do
      lines[#lines + 1] = "a_" .. i .. " + b % c" .. i
    end
    lines[#lines + 1] = "\\end{equation}"
    local buf = org_buffer(lines)
    for _, row in ipairs({ 50, 100, 120, 150, 160 }) do
      eq({ "0-" .. #lines[row + 1] }, spans(row + 1, "orgLatex"), "row " .. row)
    end
    eq(1, #deco.line_marks(buf, 202))
  end)
end)
