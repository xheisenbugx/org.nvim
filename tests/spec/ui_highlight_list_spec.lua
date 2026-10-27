-- ui.highlighter = "parser": bullets, checkboxes, statistics cookies and
-- description list terms (org.ui.highlight.list). The assertions of the
-- syntax engine's specs (ui_spec.lua, ui_syntax_highlighting_spec.lua,
-- syntax_long_lines_spec.lua), engine-agnostic; what Emacs draws is
-- checked in emacs_faces_list_spec.lua.
local hl = require("tests.helpers.highlighter")
local groups, has = hl.groups, hl.has

local deco = require("org.ui.decorations")

--- The column (1-based) of the first `s` in line l.
local function col(l, s)
  return assert(vim.fn.getline(l):find(s, 1, true), s)
end

--- The marks of group `group` on 0-based row `row`, as "start-end".
local function spans(buf, row, group)
  local out = {}
  for _, m in ipairs(deco.line_marks(buf, row)) do
    if m[2].hl_group == group then
      out[#out + 1] = string.format("%d-%d", m[1], m[2].end_col)
    end
  end
  table.sort(out)
  return out
end

describe("parser highlighter: lists", function()
  with_config({ ui = { highlighter = "parser" } })

  it("draws no list syntax groups", function()
    org_buffer({ "- [ ] term :: x [1/2]" }, { 1, 0 })
    for c = 1, 21 do
      for _, id in ipairs(vim.fn.synstack(1, c)) do
        local name = vim.fn.synIDattr(id, "name")
        ok(not name:find("^orgList") and not name:find("^orgCheckbox") and not name:find("^orgStatistic"), name)
      end
    end
  end)

  it("highlights core list elements", function()
    org_buffer({ "* WAIT [#A] Hello *bold* :tag:", "- [ ] item" }, { 1, 0 })
    ok(has(2, 1, "orgListBullet"), groups(2, 1))
    ok(has(2, 3, "orgCheckbox"), groups(2, 3))
  end)

  it("highlights description list terms after the bullet and checkbox", function()
    org_buffer({
      "- term :: description",
      "- [ ] box term :: desc",
      "   * star bullet :: x",
      "1. numbered :: no term",
      "- no space::here",
      "- tricky :: one :: two",
    }, { 1, 0 })
    ok(has(1, 1, "orgListBullet"), groups(1, 1))
    ok(not has(1, 2, "orgListBullet") and not has(1, 2, "orgListTerm"), groups(1, 2))
    ok(has(1, 3, "orgListTerm"), groups(1, 3))
    ok(has(1, 6, "orgListTerm"), groups(1, 6))
    -- (Emacs: org-list-dt goes on over " ::")
    ok(has(1, 9, "orgListTerm"), groups(1, 9))
    eq("", groups(1, 11))
    ok(has(2, 3, "orgCheckbox"), groups(2, 3))
    ok(has(2, 7, "orgListTerm"), groups(2, 7))
    ok(has(3, 6, "orgListTerm"), groups(3, 6))
    ok(has(3, 4, "orgListBullet"), groups(3, 4))
    ok(not has(4, 4, "orgListTerm"), groups(4, 4))
    ok(not has(5, 3, "orgListTerm"), groups(5, 3))
    ok(has(6, 3, "orgListTerm"), groups(6, 3))
    ok(not has(6, 14, "orgListTerm"), groups(6, 14))
  end)

  it("ends a term at the first ' ::' before a blank, and gives a blank back", function()
    local buf = org_buffer({ "- a::b :: c", "- end ::x", "-  :: two blanks", "- :: one blank", "-\ttab\t::\tx" })
    eq({ "2-9" }, spans(buf, 0, "orgListTerm"))
    eq({}, spans(buf, 1, "orgListTerm"))
    eq({ "2-5" }, spans(buf, 2, "orgListTerm"))
    eq({}, spans(buf, 3, "orgListTerm"))
    eq({ "2-8" }, spans(buf, 4, "orgListTerm"))
  end)

  it("highlights all markup in list terms", function()
    org_buffer({ "- term +s+ _u_ :: def", "- [[https://example.com][Example]] :: def", "- =v= :: d" }, { 1, 0 })
    ok(has(1, 9, "orgStrikethrough") and has(1, 9, "orgListTerm"), groups(1, 9))
    ok(has(1, 13, "orgUnderline"), groups(1, 13))
    ok(has(2, 30, "orgListTerm"), groups(2, 30))
    ok(has(3, 4, "orgListTerm") and has(3, 4, "orgVerbatim"), groups(3, 4))
  end)

  it("highlights a checkbox after a counter, not [x] or a box without a blank", function()
    org_buffer({
      "- [@3] [X] counter box",
      "1. [@start:2] [ ] start",
      "- [ ]no space",
      "- [x] lower",
      "a. [ ] alpha",
      "+ [-] partial",
      "- [@ab] [ ] bad counter",
      "- [ ]",
      "* [ ] on a headline",
      "** [ ] two stars",
    }, { 1, 0 })
    ok(has(1, 8, "orgCheckboxChecked"), groups(1, 8))
    ok(has(2, 15, "orgCheckbox"), groups(2, 15))
    ok(not has(3, 3, "orgCheckbox"), groups(3, 3))
    ok(not has(4, 3, "orgCheckbox") and not has(4, 3, "orgCheckboxChecked"), groups(4, 3))
    ok(has(5, 4, "orgCheckbox"), groups(5, 4))
    ok(has(6, 4, "orgCheckboxPartial"), groups(6, 4))
    ok(not has(7, 10, "orgCheckbox"), groups(7, 10))
    ok(has(8, 4, "orgCheckbox"), groups(8, 4))
    -- (Emacs: org-list-full-item-re takes "* " at the start of a line)
    ok(has(9, 4, "orgCheckbox"), groups(9, 4))
    ok(not has(10, 5, "orgCheckbox"), groups(10, 5))
  end)

  -- org-checkbox-statistics-done / -todo
  it("highlights complete statistics cookies as done", function()
    org_buffer({ "* Done [2/2] [1/2] [100%] [50%] [0/0] [/] [%] [01/1]" }, { 1, 0 })
    ok(has(1, 9, "orgStatisticDone"), groups(1, 9))
    ok(has(1, 15, "orgStatistic") and not has(1, 15, "orgStatisticDone"), groups(1, 15))
    ok(has(1, 21, "orgStatisticDone"), groups(1, 21))
    ok(has(1, 28, "orgStatistic") and not has(1, 28, "orgStatisticDone"), groups(1, 28))
    ok(has(1, col(1, "0/0"), "orgStatisticDone"), groups(1, col(1, "0/0")))
    ok(has(1, col(1, "[/]"), "orgStatistic"), groups(1, col(1, "[/]")))
    ok(has(1, col(1, "[%]"), "orgStatistic"), groups(1, col(1, "[%]")))
    ok(has(1, col(1, "01/1"), "orgStatistic"), groups(1, col(1, "01/1")))
  end)

  it("highlights cookies in tables, terms, verbatim and fixed width, not in comments or keywords", function()
    org_buffer({
      "| _u_ | [1/2] | x |",
      "- a [1/3] term :: x",
      "Text =[1/2]= x",
      ": fixed [1/2]",
      "# comment [1/2]",
      "#+caption: c [1/2]",
      "#+begin_src lua",
      "x = '[1/2]'",
      "#+end_src",
    }, { 1, 0 })
    ok(has(1, col(1, "1/2"), "orgStatistic"), groups(1, col(1, "1/2")))
    ok(has(2, col(2, "1/3"), "orgStatistic") and has(2, col(2, "1/3"), "orgListTerm"), groups(2, col(2, "1/3")))
    ok(has(3, col(3, "1/2"), "orgStatistic"), groups(3, col(3, "1/2")))
    ok(has(4, col(4, "1/2"), "orgStatistic"), groups(4, col(4, "1/2")))
    for _, l in ipairs({ 5, 6, 8 }) do
      ok(not has(l, col(l, "1/2"), "orgStatistic"), l .. ": " .. groups(l, col(l, "1/2")))
    end
  end)

  it("draws items in quote and comment blocks, not in src or example blocks", function()
    org_buffer({
      "#+begin_quote",
      "- [ ] quoted :: x",
      "#+end_quote",
      "#+begin_example",
      "- [X] example :: x",
      "#+end_example",
      "#+begin_comment",
      "+ [-] comment :: x",
      "#+end_comment",
    }, { 1, 0 })
    ok(has(2, 1, "orgListBullet"), groups(2, 1))
    ok(has(2, 3, "orgCheckbox") and has(2, 7, "orgListTerm"), groups(2, 3))
    ok(not has(5, 1, "orgListBullet") and not has(5, 3, "orgCheckboxChecked"), groups(5, 3))
    ok(not has(5, 7, "orgListTerm"), groups(5, 7))
    ok(has(8, 3, "orgCheckboxPartial") and has(8, 7, "orgListTerm"), groups(8, 3))
  end)

  it("follows allow_alphabetical for bullets", function()
    org_buffer({ "Text", "I. Smith wrote", "b) x" }, { 1, 0 })
    ok(not has(2, 1, "orgListBullet"), groups(2, 1))
    require("org.config").opts.lists.allow_alphabetical = true
    local ok_run, err = pcall(function()
      org_buffer({ "Text", "I. Smith wrote", "b) x" }, { 1, 0 })
      ok(has(2, 1, "orgListBullet") and has(2, 2, "orgListBullet"), groups(2, 1))
      ok(has(3, 1, "orgListBullet"), groups(3, 1))
    end)
    require("org.config").opts.lists.allow_alphabetical = nil
    assert(ok_run, err)
  end)

  it("follows ordered_item_terminator for bullets", function()
    require("org.config").opts.lists.ordered_item_terminator = ")"
    local ok_run, err = pcall(function()
      org_buffer({ "1. dot", "2) paren", "- dash", "  * star", "3.no blank", "7." }, { 1, 0 })
      ok(not has(1, 1, "orgListBullet"), groups(1, 1))
      ok(has(2, 1, "orgListBullet") and has(2, 2, "orgListBullet"), groups(2, 2))
      ok(not has(2, 3, "orgListBullet"), groups(2, 3))
      ok(has(3, 1, "orgListBullet"), groups(3, 1))
      ok(has(4, 3, "orgListBullet"), groups(4, 3))
    end)
    require("org.config").opts.lists.ordered_item_terminator = nil
    assert(ok_run, err)
    org_buffer({ "1. dot", "2) paren", "3.no blank", "7." }, { 1, 0 })
    ok(has(1, 2, "orgListBullet") and has(2, 2, "orgListBullet"), groups(1, 2))
    ok(not has(3, 1, "orgListBullet"), groups(3, 1))
    ok(has(4, 2, "orgListBullet"), groups(4, 2))
  end)

  it("leaves bullets, checkboxes, cookies and terms out of spell checking", function()
    local buf = org_buffer({ "- [ ] term :: x [1/2]" }, { 1, 0 })
    local seen = {}
    for _, m in ipairs(deco.line_marks(buf, 0)) do
      local g = m[2].hl_group or ""
      if g:find("^orgList") or g:find("^orgCheckbox") or g:find("^orgStatistic") then
        seen[g] = true
        eq(false, m[2].spell)
      end
    end
    eq({ orgCheckbox = true, orgListBullet = true, orgListTerm = true, orgStatistic = true }, seen)
  end)

  it("highlights the terms of long lines", function()
    local prose = string.rep("I would like the board to be set to a certain color for clients. ", 80)
    org_buffer({ "- term :: desc", "  - [X] boxed *bold* term :: d", "- " .. prose .. ":: long term", "- " .. prose })
    ok(has(1, 3, "orgListTerm"), groups(1, 3))
    ok(has(2, 5, "orgCheckboxChecked"), groups(2, 5))
    ok(has(2, 16, "orgBold") and has(2, 16, "orgListTerm"), groups(2, 16))
    ok(has(3, 3, "orgListTerm") and has(3, 2990, "orgListTerm"), groups(3, 2990))
    ok(not has(4, 3, "orgListTerm"), groups(4, 3))
  end)

  for name, unit in pairs({
    term = "word :",
    colons = "a::b ",
    cookies = "[1/2] [3%] ",
    brackets = "[12[/[%",
    boxes = "- [ ] ",
  }) do
    it("draws a long line of " .. name .. " in linear time", function()
      local function time(n)
        local buf = org_buffer({ "- " .. string.rep(unit, math.floor(n / #unit)) .. " :: x" }, { 1, 0 })
        local t = vim.uv.hrtime()
        deco.line_marks(buf, 0)
        return (vim.uv.hrtime() - t) / 1e6
      end
      time(1000)
      local small, big = time(20000), time(200000)
      -- ten times the text, well under a hundred times the time
      ok(big < math.max(small, 2) * 40, string.format("%.1f ms then %.1f ms", small, big))
    end)
  end
end)
