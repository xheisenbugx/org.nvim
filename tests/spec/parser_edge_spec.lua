local parser = require("org.parser")

describe("parser edge cases", function()
  it("treats a drawer without :END: as text, keeping its timestamps", function()
    local f = parser.parse({ "* Task", ":note:", "some text", "<2024-01-02 Tue>", "* Next" }, "/x.org")
    local hl = f.headlines[1]
    eq(0, #hl.drawers)
    eq(1, #hl.timestamps)
    eq(4, hl.timestamps[1].line)
  end)

  it("does not close a drawer with an :END: from a later section", function()
    local f = parser.parse({ "* A", ":note:", "<2024-01-02 Tue>", "* B", ":END:" }, "/x.org")
    eq(1, #f.headlines[1].timestamps)
    eq(0, #f.headlines[1].drawers)
  end)

  it("closes a drawer with a lower-case :end: line", function()
    local f = parser.parse({ "* Task", ":LOGBOOK:", "- note", ":end:", "<2024-01-02 Tue>" }, "/x.org")
    local hl = f.headlines[1]
    eq(1, #hl.drawers)
    eq(4, hl.drawers[1]["end"])
    eq({ start = 2, ["end"] = 4 }, hl.logbook)
    eq(1, #hl.timestamps)
  end)

  it("keeps timestamps inside closed drawers, like Emacs", function()
    -- Emacs Org 9.8.10: a drawer's paragraphs hold timestamp objects, and
    -- the agenda lists both of these
    local f = parser.parse({ "* Task", ":note:", "<2024-01-02 Tue>", ":END:", ":x:", "<2024-01-03 Wed>" }, "/x.org")
    local hl = f.headlines[1]
    eq(1, #hl.drawers)
    eq(2, #hl.timestamps)
    eq(3, hl.timestamps[1].line)
    eq(6, hl.timestamps[2].line)
  end)

  it("keeps drawer timestamps but not a CLOCK line's", function()
    local f = parser.parse({
      "* Task",
      "  :PROPERTIES:",
      "  :WHEN: <2024-01-02 Tue>",
      "  :END:",
      "  :LOGBOOK:",
      "  CLOCK: [2024-01-01 Mon 10:00]--[2024-01-01 Mon 11:00] =>  1:00",
      '  - State "DONE"       from "TODO"       [2024-01-01 Mon 12:00]',
      "  - Note taken on [2024-01-01 Mon 13:00] \\\\",
      "    follow up <2024-01-03 Wed>",
      "  :END:",
    }, "/x.org")
    local hl = f.headlines[1]
    eq(
      { 3, 9 },
      vim.tbl_map(function(t)
        return t.line
      end, hl.timestamps)
    )
    eq(true, hl.timestamps[1].in_property)
    -- TIMESTAMP skips the property value (a node property, no timestamp
    -- object); TIMESTAMP_IA is the State note's, not the clock's
    eq("<2024-01-03 Wed>", hl:get_property("TIMESTAMP"))
    eq("[2024-01-01 Mon 12:00]", hl:get_property("TIMESTAMP_IA"))
  end)
end)

describe("element motion on an inline task END line", function()
  with_config({ inlinetask_min_level = 4 })
  local lines = { "* A", "text", "**** Inline", "body", "**** END", "more", "* B" }

  it("moves forward past the inline task", function()
    org_buffer(lines, { 5, 0 })
    require("org.element").forward()
    eq(6, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("moves backward to the inline task", function()
    org_buffer(lines, { 5, 0 })
    require("org.element").backward()
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("moves up to the enclosing headline", function()
    org_buffer(lines, { 5, 0 })
    require("org.element").up()
    eq(1, vim.api.nvim_win_get_cursor(0)[1])
  end)
end)

-- Expected values below are Emacs Org 9.8.10's (emacs -Q --batch).
describe("parser: inline tasks are not their parent's text", function()
  with_config({ inlinetask_min_level = 4 })

  it("keeps an inline task's lines out of the enclosing entry's section", function()
    local f = parser.parse({
      "* TODO A",
      "  [2026-10-01 Thu]",
      "**** TODO Inline",
      "     SCHEDULED: <2026-10-07 Wed>",
      "     <2026-10-07 Wed>",
      "**** END",
      "text <2026-10-09 Fri>",
      "* B",
      "**** Inline2",
      "     <2026-10-08 Thu>",
      "     [2026-10-02 Fri]",
    }, "/tmp/inl.org")
    local a, inline, b, inline2 = f.headlines[1], f.headlines[2], f.headlines[3], f.headlines[4]
    eq(0, #a.timestamps)
    eq("[2026-10-01 Thu]", a:get_property("TIMESTAMP_IA"))
    eq(5, inline.timestamps[1].line)
    eq(0, #b.timestamps)
    eq(nil, b.first_inactive)
    -- without END, the text up to the next heading is the inline task's
    eq(10, inline2.timestamps[1].line)
    eq("[2026-10-02 Fri]", inline2:get_property("TIMESTAMP_IA"))
  end)

  it("lists only the inline tasks in the agenda", function()
    local items = require("org.agenda.items")
    local date = require("org.date")
    local f = parser.parse({
      "* TODO A",
      "**** TODO Inline",
      "     SCHEDULED: <2026-10-07 Wed>",
      "**** END",
      "* B",
      "**** Inline2",
      "     <2026-10-08 Thu>",
    }, "/tmp/inl.org")
    local T = date.parse("<2026-10-07 Wed>"):days()
    local by_day = items.agenda({ f }, T, T + 1, { today = T })
    eq("Inline", by_day[T][1].title)
    eq(1, #by_day[T])
    eq("Inline2", by_day[T + 1][1].title)
    eq(1, #by_day[T + 1])
  end)
end)
