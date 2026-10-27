-- ui.highlighter = "parser": dates and planning (org.ui.highlight.date):
-- timestamps and ranges, SCHEDULED / DEADLINE / CLOSED and CLOCK, clock
-- durations, diary sexps and the COMMENT keyword of headlines, drawn with
-- the groups of the syntax rules. What Emacs draws is compared in
-- emacs_faces_date_spec.lua; this spec ports the syntax engine's
-- assertions (ui_syntax_highlighting_spec.lua) and checks spelling and
-- the time on long lines.
local hl = require("tests.helpers.highlighter")
local groups, has = hl.groups, hl.has

local deco = require("org.ui.decorations")

--- The column (1-based) of the first `s` in line l.
local function col(l, s)
  return assert(vim.fn.getline(l):find(s, 1, true), s)
end

--- The bytes (1-based, "a-b") of line `l` drawn in `group`, joined by " ".
local function spans(l, group)
  local out, start = {}, nil
  local line = vim.fn.getline(l)
  for c = 1, #line + 1 do
    local on = c <= #line and has(l, c, group)
    if on and not start then
      start = c
    elseif not on and start then
      out[#out + 1] = start .. "-" .. (c - 1)
      start = nil
    end
  end
  return table.concat(out, " ")
end

describe("parser highlighter: dates and planning", function()
  with_config({ ui = { highlighter = "parser" } })

  it("defines no syntax for timestamps, planning or clocks", function()
    org_buffer({ "SCHEDULED: <2026-10-02 Fri> CLOCK: [2026-10-02 Fri]" })
    for c = 1, #vim.fn.getline(1) do
      for _, id in ipairs(vim.fn.synstack(1, c)) do
        local name = vim.fn.synIDattr(id, "name")
        ok(not name:find("^orgTimestamp") and not name:find("^orgPlanning") and name ~= "orgClock", name)
      end
    end
    ok(has(1, 1, "orgplanning"), groups(1, 1))
    ok(has(1, 13, "orgtimestamp"), groups(1, 13))
  end)

  it("highlights active and inactive timestamps and ranges", function()
    org_buffer({
      "a <2026-10-02 Fri> b [2026-10-02 Fri 10:00] c",
      "<2026-10-01 Thu>--<2026-10-03 Sat> and [2026-10-01]-[2026-10-03]",
      "<2026-10-01 Thu>----<2026-10-03 Sat>",
      "x<2026-10-01 Thu 10:00-11:30 +1w -2d>y",
    })
    eq("3-18", spans(1, "orgtimestamp"))
    eq("22-43", spans(1, "orgtimestampinactive"))
    eq("1-34", spans(2, "orgtimestamp"))
    eq("40-64", spans(2, "orgtimestampinactive"))
    -- (four dashes: no range, two timestamps)
    eq("1-16 21-36", spans(3, "orgtimestamp"))
    eq("2-37", spans(4, "orgtimestamp"))
  end)

  it("highlights timestamps inside other objects and elements", function()
    org_buffer({
      "* H <2026-10-02 Fri>",
      ":PROPERTIES:",
      ":CREATED: [2026-10-02 Fri]",
      ":END:",
      "*bold <2026-10-02 Fri> text*",
      "/it [2026-10-02 Fri]/",
      "- term <2026-10-02 Fri> :: desc",
      "See [[https://x.org][desc <2026-10-02 Fri>]] z",
      "| [2026-10-02 Fri] | =<2026-10-02 Fri>= |",
      ": fixed <2026-10-02 Fri>",
      "x [fn:: note <2026-10-02 Fri>] y",
    })
    ok(has(1, 6, "orgtimestamp"), groups(1, 6))
    ok(has(3, 12, "orgtimestampinactive"), groups(3, 12))
    ok(has(5, 8, "orgtimestamp"), groups(5, 8))
    ok(has(6, 6, "orgtimestampinactive"), groups(6, 6))
    ok(has(7, 9, "orgtimestamp"), groups(7, 9))
    ok(has(8, col(8, "2026"), "orgtimestamp"), groups(8, col(8, "2026")))
    ok(has(9, 3, "orgtimestampinactive"), groups(9, 3))
    ok(has(9, col(9, "=<") + 2, "orgtimestamp"), groups(9, col(9, "=<") + 2))
    ok(has(10, col(10, "2026"), "orgtimestamp"), groups(10, col(10, "2026")))
    ok(has(11, col(11, "2026"), "orgtimestamp"), groups(11, col(11, "2026")))
  end)

  it("highlights timestamps in quote blocks and special blocks", function()
    org_buffer({
      "#+begin_quote",
      "- item <2026-10-02 Fri> +strike+",
      "# a comment in a quote [2026-10-02 Fri]",
      "#+end_quote",
      "#+begin_note",
      "Note <2026-10-02 Fri>",
      "#+end_note",
    })
    ok(has(2, col(2, "2026"), "orgtimestamp"), groups(2, col(2, "2026")))
    ok(has(3, col(3, "2026"), "orgtimestampinactive"), groups(3, col(3, "2026")))
    ok(has(6, col(6, "2026"), "orgtimestamp"), groups(6, col(6, "2026")))
  end)

  -- org-tsr-regexp-both
  it("doesn't take non-dates or prose for timestamps", function()
    org_buffer({
      "<2026-10-02x> not a timestamp",
      "<2026-10-02 Fri] then prose -> arrow",
      "The ratio => 3:45",
      "<226-10-02 Fri> <2026-1-02 Fri> [2026-10-02 Fri",
    })
    ok(not has(1, 2, "orgtimestamp"), groups(1, 2))
    ok(has(2, 2, "orgtimestamp"), groups(2, 2))
    ok(not has(2, col(2, "prose"), "orgtimestamp"), groups(2, col(2, "prose")))
    ok(not has(3, col(3, "=>"), "orgclockduration"), groups(3, col(3, "=>")))
    eq("", spans(4, "orgtimestamp") .. spans(4, "orgtimestampinactive"))
  end)

  it("draws no timestamp after [ (a link's target)", function()
    org_buffer({ "[[2026-10-02 Fri]] [<2026-10-02 Fri>] then <2026-10-03 Sat>" })
    eq(col(1, "<2026-10-03") .. "-" .. #vim.fn.getline(1), spans(1, "orgtimestamp"))
    eq("", spans(1, "orgtimestampinactive"))
  end)

  it("draws nothing on comments, keywords and in src and example blocks", function()
    org_buffer({
      "# <2026-10-02 Fri> SCHEDULED: %%(x)",
      "#+CAPTION: [2026-10-02 Fri]",
      "#+NAME: <2026-10-02 Fri>",
      "#+begin_src emacs-lisp",
      '"<2026-10-02 Fri>" ; SCHEDULED: CLOCK:',
      "#+end_src",
      "#+begin_example",
      "<2026-10-02 Fri> %%(diary)",
      "#+end_example",
    })
    for _, l in ipairs({ 1, 2, 3, 5, 8 }) do
      for _, g in ipairs({ "orgtimestamp", "orgtimestampinactive", "orgplanning", "orgclock", "orgsexpdate" }) do
        eq("", spans(l, g))
      end
    end
  end)

  it("highlights diary sexps", function()
    org_buffer({
      "* M",
      "  SCHEDULED: <%%(diary-float t 4 2)>",
      "%%(diary-anniversary 10 2 1990) Birthday",
      "&%%(diary-float t 4 2) x",
      "  %%(indented) and text %%(x)",
      "<%%(memq x '(1 2))> and <%%(y)>",
    })
    ok(has(2, 16, "orgsexpdate"), groups(2, 16))
    eq("14-36", spans(2, "orgsexpdate"))
    eq("1-40", spans(3, "orgsexpdate"))
    eq("1-24", spans(4, "orgsexpdate"))
    eq("", spans(5, "orgsexpdate"))
    eq("1-19 25-31", spans(6, "orgsexpdate"))
  end)

  it("highlights SCHEDULED, DEADLINE, CLOSED and CLOCK anywhere, not after a word character", function()
    org_buffer({
      "  SCHEDULED: <2026-10-02 Fri> DEADLINE: <2026-10-03 Sat> CLOSED: [2026-10-01 Thu]",
      "text SCHEDULED: and CLOCK: x",
      "xSCHEDULED: 1DEADLINE: _CLOSED: $CLOCK: 'CLOSED: (DEADLINE:)",
      "scheduled: SCHEDULED",
    })
    eq("3-12 31-39 58-64", spans(1, "orgplanning"))
    eq("6-15", spans(2, "orgplanning"))
    eq("21-26", spans(2, "orgclock"))
    eq("25-31 51-59", spans(3, "orgplanning"))
    eq("", spans(3, "orgclock"))
    eq("", spans(4, "orgplanning"))
  end)

  it("highlights the CLOCK keyword, its timestamps and duration", function()
    org_buffer({
      "  CLOCK: [2026-01-01 Thu 10:00]--[2026-01-01 Thu 11:00] =>  1:00",
      "CLOCK: [2026-01-01 Thu 10:00]",
      "CLOCK: => -0:30",
      "Text => 1:00 and CLOCK: x => 1:00",
    })
    ok(has(1, col(1, "=>"), "orgclockduration"), groups(1, col(1, "=>")))
    eq("3-8", spans(1, "orgclock"))
    eq("10-55", spans(1, "orgtimestampinactive"))
    eq(col(1, "=>") .. "-" .. #vim.fn.getline(1), spans(1, "orgclockduration"))
    eq("1-6", spans(2, "orgclock"))
    eq("8-29", spans(2, "orgtimestampinactive"))
    eq("8-15", spans(3, "orgclockduration"))
    -- (a duration only on a clock line)
    eq("", spans(4, "orgclockduration"))
    eq("18-23", spans(4, "orgclock"))
  end)

  -- org-set-font-lock-defaults: "^\*+\(?: +TODO\)?\(?: +\[#P\]\)? +COMMENT\(?: \|$\)"
  it("highlights COMMENT only after the stars, a keyword and a priority", function()
    org_buffer({
      "#+TODO: TODO NEXT | DONE",
      "* TODO [#A] COMMENT Task",
      "* DONE COMMENT Old",
      "* Foo COMMENT bar",
      "* COMMENT-x foo",
      "* COMMENT",
      "* NEXT COMMENT x",
      "* WAITING COMMENT x",
      "* [#42] COMMENT x",
      "*  COMMENT x",
      "* COMMENTS x",
    })
    ok(has(2, 13, "orgheadlinecomment"), groups(2, 13))
    ok(has(3, 8, "orgheadlinecomment"), groups(3, 8))
    ok(not has(4, 7, "orgheadlinecomment"), groups(4, 7))
    ok(not has(5, 3, "orgheadlinecomment"), groups(5, 3))
    ok(has(6, 3, "orgheadlinecomment"), groups(6, 3))
    eq("8-14", spans(7, "orgheadlinecomment"))
    eq("", spans(8, "orgheadlinecomment"))
    eq("9-15", spans(9, "orgheadlinecomment"))
    eq("4-10", spans(10, "orgheadlinecomment"))
    eq("", spans(11, "orgheadlinecomment"))
  end)

  it("leaves dates, planning, clocks, sexps and COMMENT out of spell checking", function()
    local buf = org_buffer({
      "* COMMENT Taks",
      "SCHEDULED: <2026-10-02 Fri>",
      "CLOCK: [2026-10-02 Fri]--[2026-10-02 Fri] => 1:00",
      "%%(diary-anniversary 10 2 1990)",
    })
    local seen = {}
    for row = 0, 3 do
      for _, m in ipairs(deco.line_marks(buf, row)) do
        local g = m[2].hl_group
        if
          g
          and (
            g:find("^orgTimestamp")
            or g:find("^orgPlanning")
            or g:find("^orgClock")
            or g == "orgSexpDate"
            or g == "orgHeadlineComment"
          )
        then
          seen[g] = true
          eq(false, m[2].spell, g)
        end
      end
    end
    for _, g in ipairs({
      "orgTimestamp",
      "orgTimestampInactive",
      "orgPlanning",
      "orgClock",
      "orgClockDuration",
      "orgSexpDate",
      "orgHeadlineComment",
    }) do
      ok(seen[g], g)
    end
  end)

  it("draws a row alone as in the whole buffer", function()
    local buf = org_buffer({
      "* H",
      "#+begin_src lua",
      "x = '<2026-10-02 Fri>'",
      "#+end_src",
      "CLOCK: [2026-10-02 Fri]",
    })
    local function only(row)
      local rows = {}
      require("org.ui.highlight").add_marks(buf, row, row, require("org.config").opts.ui, rows)
      local out = {}
      for _, m in ipairs(rows[row] or {}) do
        local g = m[2].hl_group or ""
        if g:find("^orgTimestamp") or g:find("^orgClock") then
          out[#out + 1] = g .. "@" .. m[1]
        end
      end
      table.sort(out)
      return table.concat(out, " ")
    end
    eq("", only(2))
    eq("orgClock@0 orgTimestampInactive@7", only(4))
  end)

  it("takes time linear in the length of the line", function()
    local paint = require("org.ui.highlight.date").paint
    local E = require("org.ui.emphasis")
    local function time(line)
      local lines = { line }
      local kinds, roles = E.kinds(lines)
      local n = 0
      local ctx = {
        lines = lines,
        row0 = 0,
        first = 0,
        last = 0,
        kinds = kinds,
        roles = roles,
        file = require("org.files").get_buffer(vim.api.nvim_get_current_buf()),
        emit = function()
          n = n + 1
        end,
      }
      local t = vim.uv.hrtime()
      paint(ctx)
      return (vim.uv.hrtime() - t) / 1e6
    end
    org_buffer({ "" })
    for _, unit in ipairs({
      "<2026-10-02 Fri ", -- no closing bracket
      "[2026-10-02 Fri]--",
      "<2026-10-02 Fri>-<2026-10-03 ",
      "[[2026-10-02 ",
      "SCHEDULED:DEADLINE:xCLOSED: ",
      "<%%(diary ",
      "%%(",
      "2026-10-02 ",
    }) do
      time(string.rep(unit, 100))
      local small = time(string.rep(unit, math.floor(20000 / #unit)))
      local big = time(string.rep(unit, math.floor(200000 / #unit)))
      -- ten times the text, well under a hundred times the time
      ok(big < math.max(small, 1) * 40, string.format("%q: %.1f ms then %.1f ms", unit, small, big))
    end
    for _, line in ipairs({
      "CLOCK: " .. string.rep("=> 1:00 =>  ", 20000),
      "* TODO " .. string.rep(" ", 200000) .. "COMMENT",
    }) do
      ok(time(line) < 200, line:sub(1, 20))
    end
  end)
end)
