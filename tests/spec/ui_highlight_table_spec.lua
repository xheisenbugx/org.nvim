-- The parser highlighter: tables (org.ui.highlight.table), drawn with the
-- groups orgTable, orgTableSeparator, orgTableHline and orgTableFormula;
-- what Emacs draws on every byte is compared by emacs_faces_table_spec.lua.
local hl = require("tests.helpers.highlighter")
local groups, has = hl.groups, hl.has

--- The column (1-based) of the first `s` in line l.
local function col(l, s)
  return assert(vim.fn.getline(l):find(s, 1, true), s)
end

--- Whether a table group (orgtable...) is drawn on byte c of line l.
local function any_table(l, c)
  return groups(l, c):find("orgtable", 1, true) ~= nil
end

describe("parser highlighter: tables", function()
  with_config({ ui = {} })

  it("draws rows, separators and rules", function()
    org_buffer({ "| a | b |", "|---+---|", "  | c | d |  ", "|-" })
    ok(has(1, 1, "orgtableseparator"), groups(1, 1))
    ok(has(1, 1, "orgtable"), groups(1, 1))
    eq("orgtable", groups(1, 3))
    ok(has(1, 5, "orgtableseparator"), groups(1, 5))
    ok(has(2, 1, "orgtablehline") and has(2, 5, "orgtablehline"), groups(2, 5))
    ok(not has(2, 5, "orgtableseparator"), groups(2, 5))
    -- (Emacs: from the "|" to the last non-blank, not the indentation or
    -- the blanks after it)
    eq("", groups(3, 1))
    ok(has(3, 3, "orgtableseparator"), groups(3, 3))
    eq("", groups(3, 13))
    ok(has(4, 2, "orgtablehline"), groups(4, 2))
  end)

  it("draws no table face on a lone bar (Emacs: a non-blank must follow it)", function()
    org_buffer({ "|", "|   ", "|x" })
    eq("", groups(1, 1))
    eq("", groups(2, 1))
    ok(has(3, 1, "orgtableseparator") and has(3, 2, "orgtable"), groups(3, 2))
  end)

  it("draws tables in quote, center and comment blocks, not in src or example blocks", function()
    org_buffer({
      "#+begin_quote",
      "| a | b |",
      "#+end_quote",
      "#+begin_center",
      "| c | d |",
      "#+end_center",
      "#+begin_comment",
      "| e | f |",
      "#+end_comment",
      "#+begin_example",
      "| g | h |",
      "+---+---+",
      "#+end_example",
      "#+begin_src lua",
      "| i | <l> |",
      "#+end_src",
    })
    ok(has(2, 3, "orgtable"), groups(2, 3))
    eq("orgtable", groups(5, 3))
    ok(has(8, 3, "orgtable"), groups(8, 3))
    for _, l in ipairs({ 11, 12, 15 }) do
      for c = 1, #vim.fn.getline(l) do
        ok(not any_table(l, c), l .. ":" .. c .. " " .. groups(l, c))
      end
    end
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

  it("highlights the row under the objects, cookies and formulas in table rows", function()
    org_buffer({ "| _u_ | +s+ | [fn:1] | {{{m}}} | [1/2] | <<tgt>> |", "| <5> | <r> | := $1 | x |", "| # | a |" })
    -- (the footnote, macro, statistics cookie and target in it are the
    -- objects of org.ui.highlight.object and list, checked by their specs;
    -- here the row under them)
    for _, s in ipairs({ "fn:1", "{{{", "1/2", "tgt" }) do
      ok(has(1, col(1, s), "orgtable"), groups(1, col(1, s)))
    end
    ok(has(2, 3, "orgtableformula"), groups(2, 3))
    ok(has(2, 9, "orgtableformula"), groups(2, 9))
    ok(has(2, col(2, ":="), "orgtableformula"), groups(2, col(2, ":=")))
    ok(has(3, 3, "orgtableformula"), groups(3, 3))
    ok(not has(1, 1, "orgtableformula"), groups(1, 1))
    -- (a formula overrides the table face, as in Emacs)
    ok(not has(2, 3, "orgtable"), groups(2, 3))
  end)

  it("draws the field formula of the first cell after the first one that has one", function()
    -- org-set-font-lock-defaults: "^[ \t]*|\\(?:.*?|\\)? *\\(:?=[^|\n]*\\)"
    org_buffer({ "| a | =x | := y |", "|=x|:=y|", "| =open", "| a | :x | = |" })
    ok(has(1, col(1, "=x"), "orgtableformula") and has(1, col(1, "=x") + 2, "orgtableformula"), groups(1, 9))
    ok(not has(1, col(1, ":="), "orgtableformula"), groups(1, col(1, ":=")))
    ok(not has(2, 2, "orgtableformula") and has(2, 5, "orgtableformula"), groups(2, 5))
    ok(has(3, 3, "orgtableformula") and has(3, 7, "orgtableformula"), groups(3, 7))
    ok(not has(4, col(4, ":x"), "orgtableformula") and has(4, col(4, "= "), "orgtableformula"), groups(4, 11))
  end)

  it("highlights the marking column and the special rows", function()
    org_buffer({ "| ! | a | b |", "| # | 1 |", "| * x | 2 |", "| / | x |", "| $ | y" })
    -- (a special row is a formula up to its last "|", its separators too)
    ok(has(1, 3, "orgtableformula") and has(1, 5, "orgtableformula") and has(1, 11, "orgtableformula"))
    ok(not has(1, 5, "orgtableseparator"), groups(1, 5))
    ok(has(1, 13, "orgtableseparator") and not has(1, 13, "orgtableformula"), groups(1, 13))
    ok(has(2, 3, "orgtableformula") and not has(2, 7, "orgtableformula"), groups(2, 7))
    ok(not has(3, 3, "orgtableformula"), groups(3, 3))
    ok(has(4, 3, "orgtableformula"), groups(4, 3))
    ok(not has(5, 3, "orgtableformula"), groups(5, 3))
  end)

  it("highlights the marking column and formulas of a padded table", function()
    local pad = string.rep(" ", 4000)
    org_buffer({
      "| ! | a" .. pad .. " | b |",
      "| # | 1" .. pad .. " | <l5> |",
      "|   | x" .. pad .. " | :=$1 |",
      "| / | y" .. pad .. " | =vsum(@2) |",
    })
    ok(has(1, 2, "orgtableformula") and has(1, 3, "orgtableformula"), groups(1, 3))
    ok(has(2, 3, "orgtableformula"), groups(2, 3))
    eq("orgtable", groups(2, 7))
    ok(has(4, 3, "orgtableformula"), groups(4, 3))
    -- (no 'synmaxcol': the cookie and formulas past it are drawn)
    ok(has(2, col(2, "<l5>"), "orgtableformula"), groups(2, col(2, "<l5>")))
    ok(has(3, col(3, ":=$1"), "orgtableformula"), groups(3, col(3, ":=$1")))
    ok(has(4, col(4, "=vsum"), "orgtableformula"), groups(4, col(4, "=vsum")))
  end)

  it("draws cookies after a bar anywhere but in comments and property values", function()
    org_buffer({ "Text | <c3> and |<r>.", "* H | <l2>", "# x | <l>", ":KEY: | <l>" })
    ok(has(1, col(1, "<c3>"), "orgtableformula") and has(1, col(1, "<r>"), "orgtableformula"))
    ok(not has(1, col(1, "|"), "orgtableformula"), groups(1, col(1, "|")))
    ok(has(2, col(2, "<l2>"), "orgtableformula"), groups(2, col(2, "<l2>")))
    ok(not has(3, col(3, "<l>"), "orgtableformula"), groups(3, col(3, "<l>")))
    ok(not has(4, col(4, "<l>"), "orgtableformula"), groups(4, col(4, "<l>")))
  end)

  it("leaves the special keywords out of the table face (org-special-keyword overrides it)", function()
    org_buffer({ "| =CLOSED:= | the SCHEDULED: day | xDEADLINE: |" })
    ok(not any_table(1, col(1, "CLOSED")), groups(1, col(1, "CLOSED")))
    ok(not any_table(1, col(1, "SCHEDULED")), groups(1, col(1, "SCHEDULED")))
    ok(has(1, col(1, "xDEADLINE") + 1, "orgtable"), groups(1, col(1, "xDEADLINE") + 1))
    ok(has(1, col(1, " day"), "orgtable"), groups(1, col(1, " day")))
  end)

  it("draws #+TBLFM lines as keywords, not formulas (org-meta-line in Emacs)", function()
    org_buffer({ "| 1 | 2 |", "#+TBLFM: $2=$1*2" })
    for c = 1, #vim.fn.getline(2) do
      ok(not any_table(2, c), c .. " " .. groups(2, c))
    end
  end)

  it("highlights table.el borders like table lines", function()
    org_buffer({ "* H", "+-----+-----+", "| a   | b   |", "+-----+-----+", "  +---+  ", "+--", "+- x" })
    eq("orgtable", groups(2, 3))
    ok(has(3, 3, "orgtable"), groups(3, 3))
    eq("orgtable", groups(4, 1))
    eq("orgtable", groups(5, 3))
    eq("", groups(5, 8))
    -- (Emacs: "+-[-+]" and a non-blank after it)
    eq("", groups(6, 1))
    eq("", groups(7, 1))
  end)

  it("draws a table row on the first column (ui_spec)", function()
    org_buffer({ "* H", "| a | b |" })
    ok(has(2, 1, "orgtableseparator"), groups(2, 1))
  end)

  it("leaves table rows out of spell checking", function()
    local buf = org_buffer({ "| speling | erors |", "+---+", "Some speling" })
    local deco = require("org.ui.decorations")
    for row = 0, 1 do
      local off = false
      for _, m in ipairs(deco.line_marks(buf, row)) do
        if m[2].spell == false and m[1] == 0 and m[2].end_col == #vim.fn.getline(row + 1) then
          off = true
        end
      end
      ok(off, "row " .. row)
    end
    for _, m in ipairs(deco.line_marks(buf, 2)) do
      ok(m[2].spell ~= false, vim.inspect(m))
    end
  end)

  it("draws long rows in linear time", function()
    local T = require("org.ui.highlight.table")
    local E = require("org.ui.emphasis")
    local function time(n)
      local lines = {
        string.rep("| a =x <l> ", n) .. "|",
        "|" .. string.rep(" ", 10 * n) .. "| :=" .. string.rep("x", n) .. " |",
        "| ! " .. string.rep("| <r5> ", n) .. "|",
        "|" .. string.rep("-+", 5 * n) .. "|",
        "+" .. string.rep("--+", 3 * n),
        string.rep("x | <c> SCHEDULED: ", n),
        "| " .. string.rep("CLOSED: | ", n),
      }
      local count = 0
      local kinds, roles = E.kinds(lines)
      local ctx = {
        lines = lines,
        row0 = 0,
        first = 0,
        last = #lines - 1,
        kinds = kinds,
        roles = roles,
        emit = function()
          count = count + 1
        end,
      }
      local t = vim.uv.hrtime()
      T.paint(ctx --[[@as org.ui.highlight.Ctx]])
      return (vim.uv.hrtime() - t) / 1e6, count
    end
    time(200)
    local small = time(2000)
    local big, count = time(20000)
    ok(count > 20000)
    -- ten times the text (20k then 200k characters a line), well under a
    -- hundred times the time
    ok(big < math.max(small, 1) * 40, string.format("%.1f ms then %.1f ms", small, big))
  end)
end)
