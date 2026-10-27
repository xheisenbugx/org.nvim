-- The parser highlighter: headlines (org.ui.highlight.headline). What it
-- draws is compared with Emacs in emacs_faces_headline_spec.lua; this spec
-- checks the options, the group names, spelling and the time it takes.
local hl = require("tests.helpers.highlighter")
local has, groups = hl.has, hl.groups

local deco = require("org.ui.decorations")

--- The column (1-based) of the first `s` in line l.
local function col(l, s)
  return assert(vim.fn.getline(l):find(s, 1, true), s)
end

local function ui()
  return require("org.config").opts.ui
end

--- The mark of group `group` over byte `c` (1-based) of line `l`.
local function mark(buf, l, c, group)
  for _, m in ipairs(deco.line_marks(buf, l - 1)) do
    local o = m[2]
    if o.hl_group == group and c - 1 >= m[1] and c - 1 < o.end_col then
      return o
    end
  end
end

describe("parser highlighter: headlines", function()
  with_config({ ui = { hide_emphasis_markers = true } })

  -- org-get-level-face cycles the 8 faces
  it("draws headlines of any depth in their level face", function()
    local stars = string.rep("*", 21)
    org_buffer({ "* One", "** Two", "*** Three", stars .. " TODO Deep :tag:", string.rep("*", 16) .. " x" })
    ok(has(1, 1, "orgheadlinelevel1") and has(1, 5, "orgheadlinelevel1"), groups(1, 5))
    ok(has(2, 4, "orgheadlinelevel2"), groups(2, 4))
    ok(has(3, 9, "orgheadlinelevel3"), groups(3, 9))
    ok(has(4, 1, "orgheadlinelevel5"), groups(4, 1))
    ok(has(4, 23, "orgtodo"), groups(4, 23))
    ok(has(4, col(4, ":tag"), "orgtags"), groups(4, col(4, ":tag")))
    ok(has(5, 1, "orgheadlinelevel8"), groups(5, 1))
  end)

  it("draws no headline without a blank after the stars", function()
    org_buffer({ "*bold* text", "*\tx", "**" })
    for l = 1, 3 do
      ok(not groups(l, 1):find("orgheadlinelevel"), groups(l, 1))
    end
  end)

  it("takes the TODO keywords of the buffer, case-sensitive", function()
    org_buffer({
      "#+TODO: TODO NEXT(n) | DONE KILL(k@)",
      "* NEXT a",
      "* KILL b",
      "* TODOX c",
      "* todo d",
      "* TODO",
      "* TODO\tafter a tab",
      "* x TODO",
    })
    ok(has(2, 3, "orgtodo"), groups(2, 3))
    ok(has(3, 3, "orgdone"), groups(3, 3))
    ok(not has(4, 3, "orgtodo"), groups(4, 3))
    ok(not has(5, 3, "orgtodo"), groups(5, 3))
    ok(has(6, 3, "orgtodo"), groups(6, 3))
    -- Emacs: a keyword followed by a tab and text isn't one
    ok(not has(7, 3, "orgtodo"), groups(7, 3))
    ok(not has(8, 5, "orgtodo"), groups(8, 5))
  end)

  -- sql.vim, lisp.vim, html.vim... run `syn case ignore`
  it("keeps TODO keywords case-sensitive with a sql src block", function()
    org_buffer({ "* todo buy milk", "* done reading", "#+begin_src sql", "select 1", "#+end_src" })
    ok(not has(1, 3, "orgtodo"), groups(1, 3))
    ok(not has(2, 3, "orgdone"), groups(2, 3))
    ok(not has(2, 3, "orgheadlinedone"), groups(2, 3))
  end)

  -- org-fontify-done-headline: the text after the keyword, the level face
  -- under it
  it("draws the text of DONE headlines in orgHeadlineDone", function()
    org_buffer({ "** DONE [#A] Done  :x:", "* TODO open" })
    ok(not has(1, 1, "orgheadlinedone") and has(1, 1, "orgheadlinelevel2"), groups(1, 1))
    ok(not has(1, 4, "orgheadlinedone") and has(1, 4, "orgdone"), groups(1, 4))
    ok(not has(1, 8, "orgheadlinedone"), groups(1, 8))
    ok(has(1, 9, "orgheadlinedone") and has(1, 9, "orgpriorityA"), groups(1, 9))
    ok(has(1, 21, "orgheadlinedone") and has(1, 21, "orgtags"), groups(1, 21))
    ok(has(1, 21, "orgheadlinelevel2"), groups(1, 21))
    ok(not has(2, 8, "orgheadlinedone"), groups(2, 8))
  end)

  it("highlights markup in DONE headlines and hides its markers", function()
    org_buffer({ "* DONE *bold* and /it/ done", "** DONE [#A] =v= x" })
    vim.wo.conceallevel = 2
    ok(has(1, 9, "orgbold") and has(1, 9, "orgheadlinedone"), groups(1, 9))
    ok(has(1, 8, "conceal"), groups(1, 8))
    ok(has(1, 20, "orgitalic"), groups(1, 20))
    ok(has(2, 15, "orgverbatim"), groups(2, 15))
  end)

  it("highlights COMMENT only after the stars, a keyword and a priority", function()
    org_buffer({
      "* TODO [#A] COMMENT Task",
      "* DONE COMMENT Old",
      "* Foo COMMENT bar",
      "* COMMENT-x foo",
      "* COMMENT",
      "* [#B] COMMENT x",
      "* COMMENTED",
    })
    ok(has(1, 13, "orgheadlinecomment"), groups(1, 13))
    ok(has(2, 8, "orgheadlinecomment"), groups(2, 8))
    ok(not has(3, 7, "orgheadlinecomment"), groups(3, 7))
    ok(not has(4, 3, "orgheadlinecomment"), groups(4, 3))
    ok(has(5, 3, "orgheadlinecomment"), groups(5, 3))
    ok(has(6, 8, "orgheadlinecomment"), groups(6, 8))
    ok(not has(7, 3, "orgheadlinecomment"), groups(7, 3))
  end)

  -- org-tag-re: [[:alnum:]_@#%]
  it("highlights only valid tags", function()
    org_buffer({
      "* Headline :foo-bar:",
      "* Call at :10.30:",
      "* Real :a_b:@x:#y:",
      "* Ünï :tâg:",
      "* Glued:a:",
      "* :only:",
      "* Trailing :t:   ",
      "* Doubled ::a::b::",
      "* Not ::",
    })
    ok(not has(1, 13, "orgtags"), groups(1, 13))
    ok(not has(2, 12, "orgtags"), groups(2, 12))
    ok(has(3, 9, "orgtags"), groups(3, 9))
    ok(has(4, col(4, ":t") + 1, "orgtags"), groups(4, col(4, ":t") + 1))
    ok(not has(5, 9, "orgtags"), groups(5, 9))
    ok(has(6, 3, "orgtags") and has(6, 8, "orgtags"), groups(6, 3))
    ok(has(7, 14, "orgtags") and not has(7, 15, "orgtags"), groups(7, 15))
    ok(has(8, 11, "orgtags"), groups(8, 11))
    ok(not has(9, 7, "orgtags"), groups(9, 7))
  end)

  it("dims headlines tagged ARCHIVE", function()
    org_buffer({ "* Old project notes :work:ARCHIVE:", "* Live project :work:" })
    ok(has(1, 3, "orgheadlinearchived"), groups(1, 3))
    ok(not has(1, 1, "orgheadlinearchived"), groups(1, 1))
    ok(has(1, col(1, ":work"), "orgtags"), groups(1, col(1, ":work")))
    ok(not has(2, 3, "orgheadlinearchived"), groups(2, 3))
  end)

  -- org-priority-value-regexp; org-font-lock-add-priority-faces draws the
  -- first cookie after "^\*+", on any line starting with a star
  it("draws the first priority cookie in orgPriorityA/B/C or orgPriority", function()
    org_buffer({
      "* [#A] a",
      "* [#B] b",
      "* [#C] c",
      "* [#D] d",
      "* [#64] n",
      "* [#65] n",
      "* x [#A] and [#B]",
      "*Note:* [#A] here",
      "no star [#A]",
      "#+begin_src org",
      "*x [#A]",
      "#+end_src",
    })
    ok(has(1, 3, "orgpriorityA"), groups(1, 3))
    ok(has(2, 4, "orgpriorityB"), groups(2, 4))
    ok(has(3, 6, "orgpriorityC"), groups(3, 6))
    ok(has(4, 3, "orgpriority"), groups(4, 3))
    ok(has(5, 7, "orgpriority"), groups(5, 7))
    ok(not has(6, 3, "orgpriority"), groups(6, 3))
    ok(has(7, 5, "orgpriorityA") and not has(7, 14, "orgpriorityB"), groups(7, 14))
    ok(has(8, 9, "orgpriorityA"), groups(8, 9))
    ok(not has(9, 9, "orgpriority"), groups(9, 9))
    ok(not has(11, 4, "orgpriority"), groups(11, 4))
  end)

  describe("inline tasks", function()
    with_config({ inlinetask_min_level = 15 })
    it("draws them without a level face", function()
      local stars = string.rep("*", 15)
      local buf = org_buffer({ stars .. " TODO Call :t:", stars .. " END", "* Normal" })
      ok(has(1, 1, "orghiddenstars") and has(1, 13, "orghiddenstars"), groups(1, 1))
      ok(not has(1, 14, "orghiddenstars") and has(1, 14, "orginlinetask"), groups(1, 14))
      ok(not groups(1, 1):find("orgheadlinelevel"), groups(1, 1))
      ok(not groups(1, 20):find("orgheadlinelevel"), groups(1, 20))
      ok(has(1, 17, "orgtodo"), groups(1, 17))
      ok(has(1, col(1, ":t"), "orgtags"), groups(1, col(1, ":t")))
      ok(has(2, 17, "orginlinetask"), groups(2, 17))
      ok(has(3, 1, "orgheadlinelevel1"), groups(3, 1))
      -- the keyword goes over org-inlinetask (drawn at priority 150)
      local m = assert(mark(buf, 1, 17, "orgTodo"))
      ok(m.priority > 150, m.priority)
    end)
  end)

  -- org-odd-levels-only: level 1 + stars / 2
  it("takes odd levels from #+STARTUP: odd", function()
    org_buffer({ "#+STARTUP: odd", "* One", "*** Two", "***** Three" })
    ok(has(2, 1, "orgheadlinelevel1"), groups(2, 1))
    ok(has(3, 1, "orgheadlinelevel2"), groups(3, 1))
    ok(has(4, 1, "orgheadlinelevel3"), groups(4, 1))
  end)

  -- syntax spell toplevel: the keyword, priority, tags and COMMENT groups
  -- had no @Spell, the headline text had
  it("leaves keywords, priorities, tags and COMMENT out of spell checking", function()
    local buf = org_buffer({ "* TODO [#A] COMMENT Titel :tagg:" }, { 1, 0 })
    eq(false, assert(mark(buf, 1, 3, "orgTodo")).spell)
    eq(false, assert(mark(buf, 1, 8, "orgPriorityA")).spell)
    eq(false, assert(mark(buf, 1, 13, "orgHeadlineComment")).spell)
    eq(false, assert(mark(buf, 1, 28, "orgTags")).spell)
    eq(nil, assert(mark(buf, 1, 22, "orgHeadlineLevel1")).spell)
  end)

  it("draws long headlines in linear time", function()
    local function time(n)
      local line = "* TODO " .. string.rep("w [# [#x :a: COMMENT x:ARCHIV ", n) .. " :tag:"
      local buf = org_buffer({ line, "** DONE " .. string.rep("x\t", n) }, { 1, 0 })
      local t = vim.uv.hrtime()
      deco.line_marks(buf, 0)
      deco.line_marks(buf, 1)
      return (vim.uv.hrtime() - t) / 1e6
    end
    time(100)
    local small, big = time(700), time(7000)
    -- (about 20k and 200k characters) ten times the text, well under a
    -- hundred times the time
    ok(big < math.max(small, 1) * 40, string.format("%.1f ms vs %.1f ms", small, big))
  end)
end)

describe("parser highlighter: headline options", function()
  with_config({ ui = {} })

  it("level_color_stars_only colors only the stars", function()
    ui().level_color_stars_only = true
    org_buffer({ "** TODO Head :t:" })
    ok(has(1, 1, "orgheadlinelevel2") and has(1, 3, "orgheadlinelevel2"), groups(1, 3))
    ok(not has(1, 9, "orgheadlinelevel2") and has(1, 9, "orgheadlinetext"), groups(1, 9))
    ok(has(1, 4, "orgtodo"), groups(1, 4))
    ok(has(1, 14, "orgtags"), groups(1, 14))
  end)

  it("hide_leading_stars draws the leading stars in OrgHiddenStars", function()
    ui().hide_leading_stars = true
    org_buffer({ "*** Three", "* One" })
    ok(has(1, 1, "orghiddenstars") and has(1, 2, "orghiddenstars"), groups(1, 2))
    ok(not has(1, 3, "orghiddenstars") and has(1, 3, "orgheadlinelevel3"), groups(1, 3))
    ok(not has(2, 1, "orghiddenstars"), groups(2, 1))
  end)

  it("fontify_todo_headline highlights the text after a TODO keyword", function()
    ui().fontify_todo_headline = true
    org_buffer({ "* TODO [#A] Head [1/2] x :tag:", "* DONE y", "* TODO [[l]] y" })
    for _, c in ipairs({ 8, 11, 13, 18, 22, 24, 26, 30 }) do
      ok(has(1, c, "orgheadlinetodo"), "column " .. c .. ": " .. groups(1, c))
    end
    ok(not has(1, 3, "orgheadlinetodo"), groups(1, 3))
    ok(has(1, 8, "orgpriorityA") and has(1, 27, "orgtags"), groups(1, 27))
    ok(not has(2, 8, "orgheadlinetodo"), groups(2, 8))
    ok(has(3, 8, "orgheadlinetodo") and has(3, 13, "orgheadlinetodo"), groups(3, 13))
  end)

  it("fontify_done_headline = false leaves DONE text in the level face", function()
    ui().fontify_done_headline = false
    org_buffer({ "* DONE y" })
    ok(has(1, 3, "orgdone"), groups(1, 3))
    ok(not has(1, 8, "orgheadlinedone") and has(1, 8, "orgheadlinelevel1"), groups(1, 8))
  end)

  it("todo_keyword_faces draws a keyword in its own group", function()
    ui().todo_keyword_faces = { WAIT = ":foreground orange" }
    org_buffer({ "#+TODO: TODO WAIT | DONE", "* WAIT x", "* TODO y" })
    ok(has(2, 3, "orgtodokw_wait"), groups(2, 3))
    ok(not has(3, 3, "orgtodokw_wait") and has(3, 3, "orgtodo"), groups(3, 3))
    ok(vim.api.nvim_get_hl(0, { name = "orgTodoKw_WAIT" }).fg ~= nil)
  end)

  it("ui.priority_faces / ui.tag_faces highlight cookies and tags", function()
    ui().priority_faces = { A = "ErrorMsg", ["10"] = { fg = "#123456" } }
    ui().tag_faces = { urgent = ":foreground red :weight bold" }
    org_buffer({ "* TODO [#A] Task :urgent:x:", "* [#10] N" })
    require("org.highlights").apply_todo_faces()
    local line = vim.fn.getline(1)
    ok(has(1, line:find("#A", 1, true), "orgpriorityface_a"), groups(1, 9))
    ok(has(1, line:find("urgent", 1, true), "orgtagface_urgent"), groups(1, line:find("urgent", 1, true)))
    ok(not groups(1, line:find("x:", 1, true)):find("orgtagface"), groups(1, line:find("x:", 1, true)))
    ok(not has(1, line:find(":urgent", 1, true), "orgtagface_urgent"))
    ok(has(2, 4, "orgpriorityface_10"), groups(2, 4))
    eq("#ff0000", string.format("#%06x", vim.api.nvim_get_hl(0, { name = "orgTagFace_urgent" }).fg))
  end)
end)
