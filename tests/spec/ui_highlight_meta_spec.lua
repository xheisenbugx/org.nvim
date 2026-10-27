-- The parser highlighter's keywords, drawers and comments
-- (org.ui.highlight.meta): the groups the syntax engine draws there, with
-- the faces of Emacs (emacs_faces_meta_spec.lua compares them byte by
-- byte), spelling and the time it takes on long lines.
local hl = require("tests.helpers.highlighter")
local deco = require("org.ui.decorations")

local groups, has = hl.groups, hl.has

--- The column (1-based) of the first `s` in line l.
local function col(l, s)
  return assert(vim.fn.getline(l):find(s, 1, true), s)
end

--- Line l as shown with the hidden bytes left out.
local function shown(l)
  local s, line = "", vim.fn.getline(l)
  for c = 1, #line do
    if not has(l, c, "conceal") then
      s = s .. line:sub(c, c)
    end
  end
  return s
end

--- The marks of this part on 0-based row `row`: group -> spell option
--- (`false`, or "nil").
local function spells(buf, row)
  local out = {}
  for _, m in ipairs(deco.line_marks(buf, row)) do
    local g = m[2].hl_group
    if g then
      out[g] = m[2].spell == nil and "nil" or m[2].spell
    end
  end
  return out
end

describe("parser highlighter: keywords, drawers and comments", function()
  with_config({ ui = { highlighter = "parser" } })

  it("draws keywords as marks, not syntax", function()
    org_buffer({ "#+STARTUP: overview", "  #+FILETAGS: :a:", "#+key without colon" }, { 1, 0 })
    eq({}, vim.fn.synstack(1, 1))
    ok(has(1, 1, "orgkeyword"), groups(1, 1))
    ok(has(1, col(1, ":"), "orgkeyword"), groups(1, col(1, ":")))
    ok(has(1, col(1, " "), "orgkeywordvalue"), groups(1, col(1, " ")))
    ok(has(1, col(1, "overview"), "orgkeywordvalue"), groups(1, col(1, "overview")))
    -- Emacs: the whole line in org-meta-line, the indentation too
    ok(has(2, 1, "orgkeyword"), groups(2, 1))
    ok(has(2, col(2, ":a:"), "orgkeywordvalue"), groups(2, col(2, ":a:")))
    ok(has(3, col(3, "colon"), "orgkeyword"), groups(3, col(3, "colon")))
  end)

  it("draws the title and the document info keywords", function()
    org_buffer({ "#+TITLE: The title", "#+author: Me", "#+Date: today", "#+email: a@b.c", "#+subtitle: s" }, { 1, 0 })
    ok(has(1, 1, "orgtitlekeyword"), groups(1, 1))
    ok(has(1, 8, "orgtitlekeyword"), groups(1, 8))
    -- (the blank after the keyword: no face, as in Emacs)
    eq("", groups(1, 9))
    ok(has(1, 10, "orgtitle"), groups(1, 10))
    ok(not has(1, 10, "orgtitlekeyword"), groups(1, 10))
    for l = 2, 5 do
      ok(has(l, 1, "orginfokeyword"), groups(l, 1))
      ok(has(l, col(l, ":"), "orginfokeyword"), groups(l, col(l, ":")))
      local v = col(l, ":") + 2
      ok(has(l, v, "orginfovalue"), groups(l, v))
    end
  end)

  it("draws a keyword like an info keyword only with its colon", function()
    org_buffer({ "#+title_x: no", "#+titles: no", "#+DATE:" }, { 1, 0 })
    ok(has(1, 1, "orgkeyword"), groups(1, 1))
    ok(has(2, 1, "orgkeyword"), groups(2, 1))
    ok(has(3, 1, "orginfokeyword"), groups(3, 1))
  end)

  it("hides the keywords of ui.hidden_keywords", function()
    require("org.config").opts.ui.hidden_keywords = { "title", "author" }
    org_buffer({ "#+TITLE: Hello", "#+AUTHOR: Me", "#+DATE: today", "  #+title: Indented" }, { 1, 0 })
    -- Emacs: "#+TITLE:" invisible, the space and the title shown
    eq(" Hello", shown(1))
    eq(" Me", shown(2))
    eq("#+DATE: today", shown(3))
    eq(" Indented", shown(4))
    require("org.config").opts.ui.hidden_keywords = {}
  end)

  it("draws captions: the keyword as a keyword, the caption as a block", function()
    org_buffer({ "#+CAPTION[short]: A caption", "#+captions: x" }, { 1, 0 })
    ok(has(1, col(1, "]:"), "orgkeyword"), groups(1, col(1, "]:")))
    ok(has(1, col(1, "A caption"), "orgblock"), groups(1, col(1, "A caption")))
    ok(has(2, col(2, "x"), "orgkeywordvalue"), groups(2, col(2, "x")))
  end)

  it("draws the lines of a dynamic block as keywords", function()
    org_buffer(
      { "#+BEGIN: clocktable :scope file", "#+CAPTION: Clock summary", "Some *bold* note", "#+END:" },
      { 1, 0 }
    )
    ok(has(1, 1, "orgkeyword"), groups(1, 1))
    ok(has(2, 1, "orgkeyword"), groups(2, 1))
    ok(not has(3, 1, "orgkeyword"), groups(3, 1))
    ok(has(4, 1, "orgkeyword"), groups(4, 1))
  end)

  it("draws comments, not other lines starting with a hash", function()
    org_buffer({ "# a comment", "#", "   # indented", "#x not", "Text # not", "#\ttab" }, { 1, 0 })
    for _, l in ipairs({ 1, 2, 3 }) do
      ok(has(l, 1, "orgcomment"), groups(l, 1))
      ok(has(l, #vim.fn.getline(l), "orgcomment"), groups(l, #vim.fn.getline(l)))
    end
    eq("", groups(4, 1))
    eq("", groups(5, 6))
    -- (not a comment; Emacs draws it in org-meta-line)
    ok(has(6, 1, "orgkeyword"), groups(6, 1))
  end)

  it("draws drawers and properties", function()
    org_buffer({
      "* H",
      ":PROPERTIES:",
      ":ID:       abc",
      ":header-args:lua: :var base=100",
      ":a.b:",
      ":KEY: trailing   ",
      ":END:",
      "  :LOGBOOK:  ",
      ":k:v",
      ":NAME: outside a drawer",
    }, { 1, 0 })
    ok(has(2, 1, "orgdrawer"), groups(2, 1))
    ok(has(2, 12, "orgdrawer"), groups(2, 12))
    ok(has(3, 1, "orgpropertykey"), groups(3, 1))
    ok(has(3, 4, "orgpropertykey"), groups(3, 4))
    eq("", groups(3, 5))
    ok(has(3, col(3, "abc"), "orgpropertyvalue"), groups(3, col(3, "abc")))
    -- (a name with a colon)
    ok(has(4, 2, "orgpropertykey"), groups(4, 2))
    ok(has(4, col(4, "lua:"), "orgpropertykey"), groups(4, col(4, "lua:")))
    ok(has(4, col(4, ":var"), "orgpropertyvalue"), groups(4, col(4, ":var")))
    -- (no value: the name drawn all the same, as in Emacs)
    ok(has(5, 1, "orgpropertykey"), groups(5, 1))
    -- (the value without its trailing blanks)
    ok(has(6, col(6, "trailing"), "orgpropertyvalue"), groups(6, col(6, "trailing")))
    eq("", groups(6, #vim.fn.getline(6)))
    ok(has(7, 1, "orgdrawer"), groups(7, 1))
    eq("", groups(8, 1))
    ok(has(8, 3, "orgdrawer"), groups(8, 3))
    eq("", groups(8, 13))
    eq("", groups(9, 1))
    ok(has(10, 1, "orgpropertykey"), groups(10, 1))
  end)

  it("draws fixed-width lines and horizontal rules", function()
    org_buffer({ ": fixed", ":", "  : indented", ":\ttab", "-----", "  ------  ", "----" }, { 1, 0 })
    ok(has(1, 1, "orgfixedwidth"), groups(1, 1))
    ok(has(1, 7, "orgfixedwidth"), groups(1, 7))
    ok(has(2, 1, "orgfixedwidth"), groups(2, 1))
    -- Emacs: org-code from the colon on
    eq("", groups(3, 1))
    ok(has(3, 3, "orgfixedwidth"), groups(3, 3))
    eq("", groups(4, 1))
    ok(has(5, 1, "orghorizontalrule"), groups(5, 1))
    ok(has(6, 4, "orghorizontalrule"), groups(6, 4))
    eq("", groups(7, 1))
  end)

  it("draws no meta lines in blocks, and nothing in src and example blocks", function()
    org_buffer({
      "#+begin_quote",
      "#+TITLE: in a quote",
      "# a comment in a quote",
      ":ID: q",
      "#+end_quote",
      "#+begin_src emacs-lisp",
      "# not a comment",
      ":ID: s",
      ": not fixed",
      "#+end_src",
      "#+begin_example",
      ":PROPERTIES:",
      "#+end_example",
      "#+begin_center",
      "#+date: closed by the headline",
      "* H",
    }, { 1, 0 })
    -- (Emacs goes on after a block's end line: its lines aren't keywords)
    eq("", groups(2, 1))
    eq("", groups(3, 1))
    ok(has(4, 1, "orgpropertykey"), groups(4, 1))
    ok(not has(7, 1, "orgcomment"), groups(7, 1))
    ok(not has(8, 1, "orgpropertykey"), groups(8, 1))
    ok(not has(9, 1, "orgfixedwidth"), groups(9, 1))
    ok(not has(12, 1, "orgdrawer"), groups(12, 1))
    ok(not has(15, 1, "orginfokeyword"), groups(15, 1))
  end)

  it("draws a keyword after a begin line that opens no block", function()
    org_buffer({ "#+begin_note", "#+STARTUP: indent", "# c" }, { 1, 0 })
    ok(has(2, 1, "orgkeyword"), groups(2, 1))
    ok(has(3, 1, "orgcomment"), groups(3, 1))
  end)

  it("draws a keyword line when the window starts below a src block's begin line", function()
    local lines = { "* H", "#+begin_src lua" }
    for _ = 1, 200 do
      lines[#lines + 1] = "# lua"
    end
    lines[#lines + 1] = "#+end_src"
    lines[#lines + 1] = "#+STARTUP: indent"
    local buf = org_buffer(lines, { 1, 0 })
    local rows = {}
    require("org.ui.highlight").add_marks(buf, 150, #lines - 1, require("org.config").opts.ui, rows)
    for row = 150, #lines - 3 do
      for _, m in ipairs(rows[row] or {}) do
        ok(m[2].hl_group ~= "orgComment", "row " .. row)
      end
    end
    local found = false
    for _, m in ipairs(rows[#lines - 1] or {}) do
      found = found or m[2].hl_group == "orgKeyword"
    end
    ok(found, vim.inspect(rows[#lines - 1]))
  end)

  it("spell checks comments only", function()
    local buf = org_buffer({
      "# a comment",
      "#+TITLE: t",
      "#+author: a",
      "#+STARTUP: indent",
      ":PROPERTIES:",
      ":ID: x",
      ": fixed",
      "-----",
    }, { 1, 0 })
    eq({ orgComment = "nil" }, spells(buf, 0))
    eq({ orgTitleKeyword = false, orgTitle = false }, spells(buf, 1))
    eq({ orgInfoKeyword = false, orgInfoValue = false }, spells(buf, 2))
    eq({ orgKeyword = false, orgKeywordValue = false }, spells(buf, 3))
    eq({ orgDrawer = false }, spells(buf, 4))
    eq({ orgPropertyKey = false, orgPropertyValue = false }, spells(buf, 5))
    eq({ orgFixedWidth = false }, spells(buf, 6))
    eq({ orgHorizontalRule = false }, spells(buf, 7))
  end)

  it("draws long lines in linear time", function()
    local function time(n)
      local w = string.rep("ab: c ", n)
      local lines = {
        "#+STARTUP: " .. w,
        "#+TITLE: " .. w,
        "#+caption[" .. string.rep("]a", n) .. ": x",
        "# " .. w,
        ":" .. string.rep("a:", n) .. " " .. w .. string.rep(" ", n),
        ":KEY:" .. string.rep(" ", 6 * n) .. "v",
        ": " .. w,
        "-----" .. string.rep("-", 6 * n) .. string.rep(" ", n),
        ":" .. string.rep("abcdef", n) .. ":",
      }
      local buf = org_buffer(lines, { 1, 0 })
      local t = vim.uv.hrtime()
      for _ = 1, 3 do
        local rows = {}
        require("org.ui.highlight.meta").paint({
          bufnr = buf,
          ui = require("org.config").opts.ui,
          file = require("org.files").get_buffer(buf),
          get_line = function()
            return nil
          end,
          lines = lines,
          row0 = 0,
          first = 0,
          last = #lines - 1,
          kinds = require("org.ui.emphasis").kinds(lines),
          roles = {},
          emit = function(i, c, e, o)
            rows[#rows + 1] = { i, c, e, o }
          end,
        })
      end
      return (vim.uv.hrtime() - t) / 1e6
    end
    time(100)
    local small, big = time(3000), time(30000)
    -- ten times the text, well under a hundred times the time
    ok(big < math.max(small, 1) * 30, string.format("%.1f ms then %.1f ms", small, big))
  end)
end)
