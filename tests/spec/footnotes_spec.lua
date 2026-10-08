local fn = require("org.footnotes")
vim.g.org_test = true

describe("footnotes", function()
  it("detects kinds", function()
    org_buffer({ "Text[fn:1] and [fn::inline] and [fn:x:named]", "[fn:1] Def" }, { 1, 6 })
    eq("reference", fn.at_point().kind)
    vim.api.nvim_win_set_cursor(0, { 1, 20 })
    eq("inline", fn.at_point().kind)
    vim.api.nvim_win_set_cursor(0, { 1, 36 })
    local f = fn.at_point()
    eq("inline", f.kind)
    eq("x", f.label)
    vim.api.nvim_win_set_cursor(0, { 2, 2 })
    eq("definition", fn.at_point().kind)
    vim.api.nvim_win_set_cursor(0, { 2, 8 })
    eq(nil, fn.at_point())
  end)
  it("jumps between reference and definition", function()
    org_buffer({ "Text[fn:a] more", "", "[fn:a] Def" }, { 1, 6 })
    fn.action_at_point()
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
    fn.action_at_point()
    eq({ 1, 4 }, vim.api.nvim_win_get_cursor(0))
  end)
  -- Emacs: the first unused number, a blank line before the new section
  -- and one between its headline and the definition
  it("creates a Footnotes section at the end of the file", function()
    org_buffer({ "Hello", "[fn:3] old" }, { 1, 4 })
    fn.new_footnote({ no_insert = true })
    eq({ "Hello[fn:1]", "[fn:3] old", "", "* Footnotes", "", "[fn:1] " }, buf_lines())
    eq(6, vim.api.nvim_win_get_cursor(0)[1])
  end)
  -- Emacs puts the new definition first in the section
  it("uses a Footnotes section", function()
    org_buffer({ "* A", "Hello", "* Footnotes", "[fn:1] x", "", "* After" }, { 2, 4 })
    fn.new_footnote({ no_insert = true })
    eq({ "* A", "Hello[fn:2]", "* Footnotes", "", "[fn:2] ", "[fn:1] x", "", "* After" }, buf_lines())
  end)
  -- Emacs collects footnotes from the parse tree: [fn:N] in a src block is
  -- code. (Emacs's renumber still rewrites a `[fn:N]` line start inside a
  -- block with a plain regexp; code is left alone here.)
  it("leaves footnote-like text in src and example blocks alone", function()
    local src = { "#+begin_src python", "x = a[fn:3]", "[fn:7] = 1", "#+end_src" }
    local lines = { "Text[fn:7] here.", "" }
    vim.list_extend(lines, src)
    vim.list_extend(lines, { "", "[fn:7] Def seven." })
    org_buffer(lines, { 1, 0 })
    fn.renumber()
    fn.sort()
    local want = { "Text[fn:1] here.", "" }
    vim.list_extend(want, src)
    vim.list_extend(want, { "", "* Footnotes", "", "[fn:1] Def seven." })
    eq(want, buf_lines())
    eq({ "1" }, fn.all_labels())
    org_buffer({ "#+BEGIN_EXAMPLE", "[fn:1] not a definition", "#+END_EXAMPLE", "Ref[fn:1]" }, { 4, 4 })
    eq(1, #fn.collect_references(buf_lines()))
    eq({}, fn.collect_definitions(buf_lines()))
  end)
end)

-- org-footnote--collect-references reads depth first: a definition
-- referenced from another one follows it (Emacs 9.8.10)
describe("footnotes referenced from definitions", function()
  it("sort puts a nested definition right after its parent", function()
    local buf = org_buffer({
      "* A",
      "Text[fn:a] then[fn:b].",
      "",
      "* Footnotes",
      "",
      "[fn:b] Def b.",
      "",
      "[fn:d] Def d.",
      "",
      "[fn:a] Def a with ref[fn:d].",
    }, { 1, 0 })
    fn.sort()
    eq({
      "* A",
      "Text[fn:a] then[fn:b].",
      "",
      "* Footnotes",
      "",
      "[fn:a] Def a with ref[fn:d].",
      "",
      "[fn:d] Def d.",
      "",
      "[fn:b] Def b.",
    }, buf_lines(buf))
  end)

  it("sort without a footnote section puts it after its parent's definition", function()
    local config = require("org.config")
    local saved = config.opts.footnote_section
    config.opts.footnote_section = false
    local buf = org_buffer({
      "* A",
      "T[fn:a] u.",
      "* B",
      "V[fn:b].",
      "* C",
      "[fn:b] B.",
      "",
      "[fn:d] D.",
      "",
      "[fn:a] A[fn:d].",
    }, { 1, 0 })
    fn.sort()
    config.opts.footnote_section = saved
    eq({
      "* A",
      "T[fn:a] u.",
      "",
      "[fn:a] A[fn:d].",
      "",
      "[fn:d] D.",
      "* B",
      "V[fn:b].",
      "",
      "[fn:b] B.",
      "* C",
    }, buf_lines(buf))
  end)

  it("normalize numbers a nested reference after its parent", function()
    local buf = org_buffer({
      "* A",
      "Text[fn:b] and[fn:a] and [fn::anon] and [fn:c:inline c].",
      "",
      "* Footnotes",
      "",
      "[fn:a] Def a with ref[fn:d].",
      "",
      "[fn:b] Def b.",
      "",
      "[fn:d] Def d.",
    }, { 1, 0 })
    fn.normalize()
    eq({
      "* A",
      "Text[fn:1] and[fn:2] and [fn:4] and [fn:5].",
      "",
      "* Footnotes",
      "",
      "[fn:1] Def b.",
      "",
      "[fn:2] Def a with ref[fn:3].",
      "",
      "[fn:3] Def d.",
      "",
      "[fn:4] anon",
      "",
      "[fn:5] inline c",
    }, buf_lines(buf))
  end)

  it("renumber numbers a nested reference after its parent", function()
    local buf = org_buffer({
      "* A",
      "Text[fn:2] x[fn:3].",
      "",
      "[fn:3] three",
      "",
      "[fn:2] two with[fn:1].",
      "",
      "[fn:1] one",
    }, { 1, 0 })
    fn.renumber()
    eq({
      "* A",
      "Text[fn:1] x[fn:3].",
      "",
      "[fn:3] three",
      "",
      "[fn:1] two with[fn:2].",
      "",
      "[fn:2] one",
    }, buf_lines(buf))
  end)
end)
