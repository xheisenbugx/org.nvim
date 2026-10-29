-- Minimized inputs found by the fuzz specs (fuzz_*_spec.lua).
describe("fuzz regressions", function()
  it("M-down from the blank lines after the last-but-one element keeps the cursor in the buffer", function()
    local buf = org_buffer({ "a", "", "", "#+title: x" }, { 2, 0 })
    require("org.element").drag_forward()
    eq({ "#+title: x", "", "", "a" }, buf_lines(buf))
    eq(4, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("S-M-up on the bracket of a CLOCK timestamp toggles it without an error", function()
    local line = "CLOCK: [2003-10-04 Fri 05:00]--[2003-10-04 Fri 23:30] => 18:30"
    local buf = org_buffer({ "* T", line }, { 2, 52 })
    eq(true, require("org.clock").timestamps_adjust_closest(-1))
    eq("CLOCK: [2003-10-04 Fri 05:00]--<2003-10-04 Fri 23:30> => 18:30", buf_lines(buf)[2])
  end)

  it("merge keeps a one-sided deletion of a property drawer's :END:", function()
    local merge = require("org.extensions.merge.merge")
    local base = { "** H", ":PROPERTIES:", ":END:", ":LOGBOOK:", ":END:" }
    local ours = { "** H", ":PROPERTIES:", ":LOGBOOK:", ":END:" }
    local res = merge.merge(base, ours, base)
    eq(0, res.conflicts)
    eq(ours, res.lines)
    res = merge.merge(base, base, ours)
    eq(ours, res.lines)
  end)

  it("the export parser reads no properties from a drawer that isn't a property drawer", function()
    local E = require("org.export.element")
    local function props(lines)
      return E.parse(lines).contents[1].props
    end
    -- org-property-drawer-re: property lines only, up to an :END: line
    eq({}, props({ "* H", ":PROPERTIES:", ":Effort: 1:00" }))
    eq({}, props({ "* H", ":PROPERTIES:", ":A: 1", "text", ":END:" }))
    eq({}, props({ "* H", ":PROPERTIES:", ":A: 1", ":B:2", ":END:" }))
    eq({ A = "1", B = "" }, props({ "* H", ":PROPERTIES:", ":A: 1", ":B:", ":END:" }))
    -- the same for the file's drawer and a property-drawer element
    eq({}, E.parse({ ":PROPERTIES:", ":A: 1" }).props)
    local data = E.parse({ "* H", ":PROPERTIES:", ":A: 1", "x", ":END:" })
    eq(0, #E.map(data, "property-drawer", function(n)
      return n
    end))
  end)

  it("the export parser reads a planning keyword after a broken timestamp", function()
    local E = require("org.export.element")
    local hl = E.parse({
      "*** x",
      "CLOSED: [2023-06-05 Wed  SCHEDULED: <2028-12-08 Fri> DEADLINE: <2020-03-14 Sat 15:00>",
    }).contents[1]
    -- org-element-planning-parser: each keyword takes the timestamp after
    -- it, or none
    eq("<2028-12-08 Fri>", hl.scheduled.raw_value)
    eq("<2020-03-14 Sat 15:00>", hl.deadline.raw_value)
    -- a keyword found again replaces the first one
    hl = E.parse({ "* x", "SCHEDULED: <2024-01-01 Mon> SCHEDULED: none" }).contents[1]
    eq(nil, hl.scheduled)
  end)

  it("reads a property drawer written in lower case", function()
    -- org-property-drawer-re is matched with case-fold-search (Emacs Org
    -- 9.8.10: org-entry-get reads A here)
    local file =
      require("org.parser").parse({ "* H", ":properties:", ":A: 1", ":end:", "* I", ":Properties:", ":B: 2", ":End:" })
    eq({ A = "1" }, file.headlines[1].properties)
    eq({ 2, 4 }, file.headlines[1].properties_range)
    eq({ B = "2" }, file.headlines[2].properties)
    eq({ A = "1" }, require("org.parser").parse({ ":properties:", ":A: 1", ":end:", "* H" }).properties)
    -- setting a property writes into that drawer
    local buf = org_buffer({ "* H", ":properties:", ":A: 1", ":end:" }, { 1, 0 })
    require("org.properties").set_property(nil, "B", "2")
    eq({ "* H", ":properties:", ":A: 1", ":B:        2", ":end:" }, buf_lines(buf))
  end)

  describe("with inline tasks", function()
    with_config({ inlinetask_min_level = 15 })

    it("counts the clocks after an inline task's END line for the entry", function()
      -- Emacs Org 9.8.10: org-element puts these lines in H's section and
      -- org-clock-sum counts the clock for H; the agenda doesn't list the
      -- timestamp for H, nor does org-entry-get read it as H's TIMESTAMP
      local file = require("org.parser").parse({
        "* H",
        "*************** task",
        "CLOCK: [2024-01-01 Mon 08:00]--[2024-01-01 Mon 08:30] =>  0:30",
        "*************** END",
        "CLOCK: [2024-01-01 Mon 10:00]--[2024-01-01 Mon 11:00] =>  1:00",
        "<2024-01-02 Tue>",
        "*************** no END",
        "CLOCK: [2024-01-01 Mon 12:00]--[2024-01-01 Mon 12:15] =>  0:15",
      })
      local h, task, endless = file.headlines[1], file.headlines[2], file.headlines[3]
      local function lines_of(clocks)
        return vim.tbl_map(function(c)
          return c.line
        end, clocks)
      end
      eq({ 5 }, lines_of(h.clocks))
      eq({}, h.timestamps)
      eq(30, task.clocks[1].minutes)
      eq(1, #task.clocks)
      -- an inline task without END keeps the lines up to the next heading
      eq({ 8 }, lines_of(endless.clocks))
    end)
  end)

  it("reads no clock from a CLOCK line inside a block", function()
    -- Emacs Org 9.8.10: org-clock-sum gives H 15 minutes
    local clock = "CLOCK: [2024-01-01 Mon 10:00]--[2024-01-01 Mon 11:00] =>  1:00"
    local file = require("org.parser").parse({
      "* H",
      "#+begin_comment",
      clock,
      "#+end_comment",
      "#+begin_src sh",
      clock,
      "#+end_src",
      "#+begin_example",
      clock,
      "#+end_example",
      "CLOCK: [2024-01-01 Mon 12:00]--[2024-01-01 Mon 12:15] =>  0:15",
    })
    eq(1, #file.headlines[1].clocks)
    eq(15, file.headlines[1]:clocked_minutes())
  end)

  it("reads no clock from a CLOCK line inside a verse block", function()
    -- a verse block holds objects only (org-element-verse-block-parser), so
    -- org-element-at-point there is no clock and org-clock-sum skips it; a
    -- quote block holds elements, its CLOCK line is a clock
    local file = require("org.parser").parse({
      "* H",
      "#+begin_verse",
      "CLOCK: [2029-03-06 Wed 07:00]--[2029-03-06 Wed 20:30] => 13:30",
      "<2029-03-07 Thu>",
      "#+END_VERSE",
      "#+begin_quote",
      "CLOCK: [2024-01-01 Mon 12:00]--[2024-01-01 Mon 12:15] =>  0:15",
      "#+end_quote",
    })
    local h = file.headlines[1]
    eq(1, #h.clocks)
    eq(7, h.clocks[1].line)
    eq(15, h:clocked_minutes())
    -- the verse block's timestamps are objects all the same
    eq(1, #h.timestamps)
    eq(4, h.timestamps[1].line)
  end)

  it("reads a lower-case [x] as an unchecked box", function()
    -- Emacs Org 9.8.10: org-list reads "[x]" as a box, counts it as
    -- unchecked ([0/2]) and C-c C-c checks it ("[X]")
    local lists = require("org.lists")
    eq(" ", lists.parse_item_line("- [x] a").checkbox)
    local buf = org_buffer({ "* H [/]", "- [x] a", "- [ ] b" }, { 1, 0 })
    lists.update_all_statistics(buf)
    eq("* H [0/2]", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    lists.toggle_checkbox()
    eq({ "* H [1/2]", "- [X] a", "- [ ] b" }, buf_lines(buf))
  end)
end)
