-- Plain list options and commands. Every expected buffer came from Emacs
-- Org 9.8.10 (emacs -Q --batch, the same text and command).

local lists = require("org.lists")

local function lines_of(text)
  return vim.split(text, "\n", { plain = true })
end

local function cycle_n(n, dir)
  local out = {}
  for _ = 1, n do
    lists.cycle_bullet(dir or 1)
    out[#out + 1] = vim.api.nvim_get_current_line()
  end
  return out
end

describe("lists: alphabetical bullets (lists.allow_alphabetical)", function()
  with_config({ lists = { allow_alphabetical = true } })

  it("parses a. and B) as ordered items, not ab.", function()
    ok(lists.parse_item_line("a. one").is_ordered)
    eq("B)", lists.parse_item_line("B) one").bullet)
    eq(nil, lists.parse_item_line("ab. one"))
    eq("c", lists.parse_item_line("a. [@c] one").counter)
    eq("one", lists.parse_item_line("a. [@start:c] one").text)
  end)

  it("renumbers alphabetical lists", function()
    local buf = org_buffer({ "a. one", "q. two", "x. three" }, { 2, 0 })
    lists.repair()
    eq({ "a. one", "b. two", "c. three" }, buf_lines(buf))
    buf = org_buffer({ "B) one", "q) two", "x) three" }, { 2, 0 })
    lists.repair()
    eq({ "A) one", "B) two", "C) three" }, buf_lines(buf))
  end)

  it("uses alphabetical counters", function()
    local buf = org_buffer({ "a. one", "b. [@e] two", "c. three" }, { 2, 0 })
    lists.repair()
    eq({ "a. one", "e. [@e] two", "f. three" }, buf_lines(buf))
    buf = org_buffer({ "a. [@c] one", "b. two" }, { 1, 0 })
    lists.repair()
    eq({ "c. [@c] one", "d. two" }, buf_lines(buf))
    -- a numeric counter in a letter list and a letter one in a numbered list
    buf = org_buffer({ "a. one", "b. [@3] two" }, { 2, 0 })
    lists.repair()
    eq({ "a. one", "b. [@3] two" }, buf_lines(buf))
    buf = org_buffer({ "1. one", "2. [@c] two" }, { 2, 0 })
    lists.repair()
    eq({ "1. one", "2. [@c] two" }, buf_lines(buf))
  end)

  it("falls back to numbers past 26 items", function()
    local l26, l27 = {}, {}
    for i = 1, 27 do
      l27[i] = "a. item" .. i
      if i <= 26 then
        l26[i] = "a. item" .. i
      end
    end
    local buf = org_buffer(l26, { 26, 0 })
    lists.repair()
    eq("z. item26", buf_lines(buf)[26])
    eq("b. item2", buf_lines(buf)[2])
    buf = org_buffer(l27, { 27, 0 })
    lists.repair()
    eq("1. item1", buf_lines(buf)[1])
    eq("27. item27", buf_lines(buf)[27])
    -- a [@z] counter leaves no room for the second item
    buf = org_buffer({ "a. [@z] x", "b. y" }, { 1, 0 })
    lists.repair()
    eq({ "1. [@z] x", "2. y" }, buf_lines(buf))
  end)

  it("inserts the next letter", function()
    local buf = org_buffer({ "a. one", "b. two" }, { 2, 0 })
    lists.new_item({ pos = { 2, 6 } })
    eq({ "a. one", "b. two", "c. " }, buf_lines(buf))
  end)

  it("cycles through letter bullets", function()
    org_buffer({ "- one", "- two" }, { 1, 0 })
    eq({ "+ one", "1. one", "1) one", "a. one", "A. one", "a) one", "A) one", "- one" }, cycle_n(8))
    local buf = org_buffer({ "- one", "  - two" }, { 2, 0 })
    cycle_n(8)
    eq({ "- one", "  A) two" }, buf_lines(buf))
    buf = org_buffer({ "1. one", "2. two" }, { 1, 0 })
    cycle_n(3)
    eq({ "A. one", "B. two" }, buf_lines(buf))
    buf = org_buffer({ "a. one" }, { 1, 0 })
    lists.cycle_bullet("A)")
    eq({ "A) one" }, buf_lines(buf))
  end)

  it("skips letters for lists of more than 26 items", function()
    local l = {}
    for i = 1, 27 do
      l[i] = "- item" .. i
    end
    org_buffer(l, { 1, 0 })
    eq({ "+ item1", "1. item1", "1) item1", "- item1", "+ item1", "1. item1", "1) item1" }, cycle_n(7))
  end)
end)

describe("lists: alphabetical bullets off (default)", function()
  it("does not parse letters", function()
    eq(nil, lists.parse_item_line("a. one"))
  end)
end)

describe("lists: ordered_item_terminator", function()
  with_config({ lists = { ordered_item_terminator = "." } })
  it('"." makes 1) text and drops 1) from the cycle', function()
    eq(nil, lists.parse_item_line("1) one"))
    org_buffer({ "- one" }, { 1, 0 })
    eq({ "+ one", "1. one", "- one", "+ one" }, cycle_n(4))
  end)
end)

describe("lists: ordered_item_terminator )", function()
  with_config({ lists = { ordered_item_terminator = ")" } })
  it('")" makes 1. text and drops 1. from the cycle', function()
    eq(nil, lists.parse_item_line("1. one"))
    org_buffer({ "- one" }, { 1, 0 })
    eq({ "+ one", "1) one", "- one", "+ one" }, cycle_n(4))
  end)
end)

describe("lists: two_spaces_after_bullet_regexp", function()
  with_config({ lists = { two_spaces_after_bullet_regexp = "[0-9]" } })
  it("puts two spaces after matching bullets", function()
    local buf = org_buffer({ "1. one", "2. two", "- x" }, { 1, 0 })
    lists.repair()
    eq({ "1.  one", "2.  two", "3.  x" }, buf_lines(buf))
    buf = org_buffer({ "- one", "- two" }, { 1, 0 })
    cycle_n(2)
    eq({ "1.  one", "2.  two" }, buf_lines(buf))
  end)
end)

describe("lists: indent_offset", function()
  with_config({ lists = { indent_offset = 2 } })
  it("indents sub-lists further", function()
    local buf = org_buffer({ "- one", "- two" }, { 2, 0 })
    lists.indent_item(1, false)
    eq({ "- one", "    - two" }, buf_lines(buf))
    buf = org_buffer({ "- one", "  - sub" }, { 2, 0 })
    lists.repair()
    eq({ "- one", "    - sub" }, buf_lines(buf))
  end)
end)

describe("lists: demote_modify_bullet", function()
  with_config({ lists = { demote_modify_bullet = { ["+"] = "-", ["-"] = "+", ["1."] = "a)" } } })
  it("changes the bullet of demoted items", function()
    local buf = org_buffer({ "- one", "- two", "  - kid", "- three" }, { 2, 0 })
    lists.indent_item(1, true)
    eq({ "- one", "  + two", "    + kid", "- three" }, buf_lines(buf))
    buf = org_buffer({ "+ one", "+ two" }, { 2, 0 })
    lists.indent_item(1, false)
    eq({ "+ one", "  - two" }, buf_lines(buf))
    -- a) is no bullet without allow_alphabetical: numbered instead
    buf = org_buffer({ "1. one", "2. two" }, { 2, 0 })
    lists.indent_item(1, false)
    eq({ "1. one", "   1) two" }, buf_lines(buf))
  end)
end)

describe("lists: demote_modify_bullet with letters", function()
  with_config({ lists = { demote_modify_bullet = { ["1."] = "a)" }, allow_alphabetical = true } })
  it("can demote to letters", function()
    local buf = org_buffer({ "1. one", "2. two", "3. three" }, { 2, 0 })
    lists.indent_item(1, false)
    eq({ "1. one", "   a) two", "2. three" }, buf_lines(buf))
  end)
end)

describe("lists: checkbox statistics", function()
  local text = { "* H", "- [ ] top [/]", "  - [X] a", "  - [ ] b", "    - [X] c", "    - [X] d" }
  it("count direct children by default", function()
    local buf = org_buffer(text, { 2, 0 })
    lists.update_statistics()
    eq("- [ ] top [1/2]", buf_lines(buf)[2])
  end)

  it("count every box with COOKIE_DATA recursive", function()
    local buf = org_buffer({ "* H", ":PROPERTIES:", ":COOKIE_DATA: recursive", ":END:", unpack(text, 2) }, { 5, 0 })
    lists.update_statistics()
    eq("- [ ] top [3/4]", buf_lines(buf)[5])
  end)

  it("leave item cookies alone with COOKIE_DATA todo", function()
    local buf = org_buffer(
      { "* H", ":PROPERTIES:", ":COOKIE_DATA: todo", ":END:", "- [ ] top [/]", "  - [X] a" },
      { 5, 0 }
    )
    lists.update_statistics()
    eq("- [ ] top [/]", buf_lines(buf)[5])
  end)
end)

describe("lists: checkbox_hierarchical_statistics = false", function()
  with_config({ lists = { checkbox_hierarchical_statistics = false } })
  it("counts every box below the cookie", function()
    local buf = org_buffer({ "* H", "- [ ] top [/]", "  - [X] a", "  - [ ] b", "    - [X] c", "    - [X] d" }, { 2, 0 })
    lists.update_statistics()
    eq("- [ ] top [3/4]", buf_lines(buf)[2])
    buf = org_buffer({ "* H [/]", "- [X] top", "  - [X] a", "- [ ] b" }, { 2, 0 })
    lists.update_statistics()
    eq("* H [2/3]", buf_lines(buf)[1])
  end)
end)

describe("lists: reset_checkbox_state_subtree", function()
  it("unchecks the boxes of the subtree", function()
    local buf = org_buffer(
      lines_of("* H [/]\n- [X] a\n- [-] b\n  - [X] c\n  - [ ] d\n** Sub [1/1]\n- [X] e\n- [X]\n* Other\n- [X] keep"),
      { 2, 0 }
    )
    lists.reset_checkbox_state_subtree()
    eq(
      lines_of("* H [0/2]\n- [ ] a\n- [ ] b\n  - [ ] c\n  - [ ] d\n** Sub [1/2]\n- [ ] e\n- [X]\n* Other\n- [X] keep"),
      buf_lines(buf)
    )
  end)

  it("is an error before the first headline", function()
    local buf = org_buffer({ "- [X] a", "* H" }, { 1, 0 })
    lists.reset_checkbox_state_subtree()
    eq({ "- [X] a", "* H" }, buf_lines(buf))
  end)
end)

describe("lists: automatic_rules", function()
  with_config({ lists = { automatic_rules = { checkbox = false, indent = true } } })
  it("checkbox = false leaves cookies alone", function()
    local buf = org_buffer({ "* H [/]", "- [ ] a", "- [ ] b" }, { 2, 0 })
    lists.toggle_checkbox()
    eq({ "* H [/]", "- [X] a", "- [ ] b" }, buf_lines(buf))
  end)
end)

describe("lists: automatic_rules indent = false", function()
  with_config({ lists = { automatic_rules = { checkbox = true, indent = false } } })
  it("stops the first item from moving the whole list", function()
    local buf = org_buffer({ "- a", "- b" }, { 1, 0 })
    lists.indent_item(1, true)
    eq({ "- a", "- b" }, buf_lines(buf))
    buf = org_buffer({ "  * a", "  * b" }, { 1, 0 })
    lists.indent_item(-1, true)
    eq({ "  * a", "  * b" }, buf_lines(buf))
  end)
end)

describe("lists: automatic_rules indent (default)", function()
  it("outdenting * to column 0 makes it -", function()
    local buf = org_buffer({ " * a", " * b" }, { 1, 0 })
    lists.indent_item(-1, true)
    eq({ "- a", "- b" }, buf_lines(buf))
  end)
end)

describe("lists: item motions", function()
  local text = lines_of("* H\n- one\n  text\n  - sub1\n  - sub2\n    more\n\n- two\n\n- three\n  tail\n\nafter")
  local function at(fn, pos)
    org_buffer(text, pos)
    lists[fn]()
    return vim.api.nvim_win_get_cursor(0)
  end

  it("go to the item and list boundaries", function()
    eq({ 5, 0 }, at("beginning_of_item", { 5, 5 }))
    eq({ 8, 0 }, at("end_of_item", { 5, 5 }))
    eq({ 4, 0 }, at("beginning_of_item_list", { 5, 5 }))
    eq({ 8, 0 }, at("end_of_item_list", { 5, 5 }))
    eq({ 1, 0 }, at("beginning_of_item", { 1, 0 })) -- not in an item: stays
  end)

  it("end at the blank line after the last item", function()
    local t = lines_of("* H\n- one\n  text\n  - sub1\n\n- two\n\n- three\n  tail\n\nafter")
    org_buffer(t, { 2, 3 })
    lists.end_of_item()
    eq({ 6, 0 }, vim.api.nvim_win_get_cursor(0))
    org_buffer(t, { 2, 3 })
    lists.end_of_item_list()
    eq({ 10, 0 }, vim.api.nvim_win_get_cursor(0))
    org_buffer({ "- one", "- two" }, { 1, 3 })
    lists.end_of_item_list()
    eq({ 2, 4 }, vim.api.nvim_win_get_cursor(0)) -- end of buffer (Normal mode: last character)
  end)
end)

describe("lists: use_circular_motion", function()
  with_config({ lists = { use_circular_motion = true } })

  it("wraps next/previous item", function()
    org_buffer({ "- one", "- two", "- three" }, { 3, 3 })
    lists.next_item()
    eq({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
    lists.prev_item()
    eq({ 3, 0 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("sends the last item to the top and the first to the bottom", function()
    local buf = org_buffer({ "- a", "- b", "- c" }, { 3, 2 })
    lists.move_item(1)
    eq({ "- c", "- a", "- b" }, buf_lines(buf))
    eq({ 1, 2 }, vim.api.nvim_win_get_cursor(0))
    buf = org_buffer({ "- a", "- b", "- c" }, { 1, 2 })
    lists.move_item(-1)
    eq({ "- b", "- c", "- a" }, buf_lines(buf))
    eq({ 3, 2 }, vim.api.nvim_win_get_cursor(0))
    buf = org_buffer({ "1. a", "2. b", "3. c", "   more" }, { 3, 4 })
    lists.move_item(1)
    eq({ "1. c", "   more", "2. a", "3. b" }, buf_lines(buf))
    buf = org_buffer({ "- x", "  - a", "  - b", "  - c", "- y" }, { 2, 4 })
    lists.move_item(-1)
    eq({ "- x", "  - b", "  - c", "  - a", "- y" }, buf_lines(buf))
    eq({ 4, 4 }, vim.api.nvim_win_get_cursor(0))
    buf = org_buffer({ "- a", "", "- b", "", "- c" }, { 5, 3 })
    lists.move_item(1)
    eq({ "- c", "", "- a", "", "- b" }, buf_lines(buf))
  end)
end)

describe("lists: checkbox radio mode", function()
  it("fires OrgListCheckboxRadioMode", function()
    org_buffer({ "- [ ] a" }, { 1, 0 })
    local got
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "OrgListCheckboxRadioMode",
      callback = function(ev)
        got = ev.data.enabled
      end,
    })
    lists.checkbox_radio_mode()
    eq(true, got)
    lists.checkbox_radio_mode()
    eq(false, got)
    vim.api.nvim_del_autocmd(id)
  end)
end)

describe("lists: org-toggle-checkbox (make difftest, commands oracle)", function()
  it("toggles the box without renumbering the list", function()
    -- org-toggle-checkbox fixes the boxes only (C-c C-c on an item goes
    -- through org-list-write-struct, which renumbers)
    local buf = org_buffer({ "* H", "1. [@8] [ ] a", "2. b", "3. [ ] c" }, { 4, 0 })
    lists.toggle_checkbox()
    eq({ "* H", "1. [@8] [ ] a", "2. b", "3. [X] c" }, buf_lines(buf))
  end)
end)

describe("lists: statistics cookies (make difftest, commands oracle)", function()
  it("a checkbox counts in the cookies of its entry only", function()
    -- org-update-checkbox-count: the ancestors' cookies stay
    local buf = org_buffer({ "* G [/]", "** H [/]", "- [ ] a" }, { 3, 0 })
    lists.toggle_checkbox()
    eq({ "* G [/]", "** H [1/1]", "- [X] a" }, buf_lines(buf))
  end)

  it("a TODO change updates the parent's cookie with TODO counts, not further up", function()
    -- org-update-parent-todo-statistics: the TODO children, even when the
    -- parent has checkboxes; the grandparent is left alone
    local buf = org_buffer({ "* G [/]", "** P [%]", "- [ ] box", "*** TODO a" }, { 4, 0 })
    require("org.todo").select_or_cycle()
    eq({ "* G [/]", "** P [100%]", "- [ ] box", "*** DONE a" }, buf_lines(buf))
  end)

  it("updating every cookie (C-u C-c #) gives TODO counts to entries with child headlines", function()
    -- org-update-checkbox-count over the buffer, then
    -- org-update-parent-todo-statistics on every headline
    local cases = {
      { { "* P [/]", "- [ ] x", "- [X] y", "- [X] z", "** TODO a", "** TODO b" }, "* P [0/2]" },
      { { "* P [/]", "- [X] x", "** plain" }, "* P [0/0]" },
      { { "* P [/]", "- [X] x", "- [ ] y", "* Q [%]", "text" }, "* P [1/2]" },
      { { "* P [/]", ":PROPERTIES:", ":COOKIE_DATA: checkbox", ":END:", "- [X] x", "** TODO a" }, "* P [1/1]" },
    }
    for _, c in ipairs(cases) do
      local buf = org_buffer(c[1], { 1, 0 })
      lists.update_all_statistics(buf)
      eq(c[2], buf_lines(buf)[1])
    end
    local buf = org_buffer({ "* G [/]", "** P [/]", "- [X] x", "*** TODO a", "*** DONE b", "** TODO c" }, { 1, 0 })
    lists.update_all_statistics(buf)
    eq({ "* G [0/1]", "** P [1/2]" }, vim.list_slice(buf_lines(buf), 1, 2))
  end)

  it("realigns the tags after a cookie changed", function()
    local buf = org_buffer({ "* P [/] :x:", "** TODO a" }, { 2, 0 })
    require("org.todo").select_or_cycle()
    eq({ "* P [1/1]" .. string.rep(" ", 65) .. ":x:", "** DONE a" }, buf_lines(buf))
  end)
end)

describe("lists: parents of ill-formed lists (org-list-parents-alist, make difftest #294)", function()
  -- an item less indented than the sub-list before it, at a column no
  -- earlier item of the list used, goes back to the first less indented
  -- level (the top one if none), not under the item it sits below
  local cases = {
    { { "- a", "    - b", "  - c" }, { "- a", "  - b", "- c" } },
    { { "- a", "  - b", "   - c", " - d", " - e" }, { "- a", "  - b", "    - c", "- d", "  - e" } },
    { { "- a", "    - b", "  text", "   - c" }, { "- a", "  - b", "  text", "- c" } },
    { { "- a", "   - b", "     - c", "  - d", "    - e" }, { "- a", "  - b", "    - c", "- d", "  - e" } },
    { { "1. a", "    1. b", "  3. c", "  4. d" }, { "1. a", "   1. b", "2. c", "   1. d" } },
  }
  for i, c in ipairs(cases) do
    it("repairs case " .. i .. " as Emacs does", function()
      local buf = org_buffer(c[1], { 1, 0 })
      lists.repair()
      eq(c[2], buf_lines(buf))
    end)
  end

  it("exports such a list to Org as Emacs does", function()
    local src = { "+ [ ] @@html:<b>@@", "  1.", "   -", " 2. 42 [[#custom][custom id]] task" }
    local out = require("org.export.ox").export_as("org", src, { body_only = true })
    eq("- [ ] 1. \n  - \n- 42 [[#custom][custom id]] task\n", out)
  end)
end)

describe("lists: tab indentation (current-indentation, tab-width 8)", function()
  -- Org fixes tab-width at 8: "\t- b" is indented 8 columns, so it is a
  -- sub-item of "- a" and of "    - b" alike, and lines whose indentation
  -- doesn't change are left alone (tabs kept)
  it("toggles a tab-indented child and updates its parents", function()
    local t = { "* H [/]", "- [ ] a", "    - [ ] b", "\t- [ ] c", "- [ ] d" }
    local buf = org_buffer(t, { 4, 3 })
    lists.toggle_checkbox()
    eq({ "* H [1/2]", "- [X] a", "    - [X] b", "\t- [X] c", "- [ ] d" }, buf_lines(buf))
  end)

  it("keeps tabs on lines whose indentation doesn't change", function()
    local buf = org_buffer({ "- [ ] a", "\t- [ ] b" }, { 2, 2 })
    lists.toggle_checkbox()
    eq({ "- [X] a", "\t- [X] b" }, buf_lines(buf))
    buf = org_buffer({ "\t- [ ] b", "\t- [ ] c" }, { 1, 2 })
    lists.toggle_checkbox()
    eq({ "\t- [X] b", "\t- [ ] c" }, buf_lines(buf))
  end)

  it("inserts an item at the tab-indented item's indentation", function()
    local buf = org_buffer({ "\t- b" }, { 1, 4 })
    lists.new_item({ pos = { 1, 4 }, split = false })
    eq({ "\t- b", "\t- " }, buf_lines(buf))
  end)

  it("outdents a tab-indented item with its body", function()
    local buf = org_buffer({ "- a", "\t- b", "\t  text" }, { 2, 1 })
    require("org.actions").run("shift_meta_left")
    eq({ "- a", "- b", "  text" }, buf_lines(buf))
  end)

  it("moves a tab-indented sub-item among its siblings", function()
    local buf = org_buffer({ "1. a", "\t1. x", "\t3. y" }, { 2, 2 })
    require("org.actions").run("meta_down")
    eq({ "1. a", "   1. y", "   2. x" }, buf_lines(buf))
  end)

  it("measures indentation in columns", function()
    eq(8, lists.parse_item_line("\t- b").indent)
    eq(9, lists.parse_item_line("  \t - b").indent)
    eq(1, lists.parse_item_line("\t- b").ind_len)
  end)
end)

describe("lists: list to headings with odd levels (org-list-to-subtree)", function()
  -- one level below the entry, counted without odd levels: under a level
  -- 3 headline (reduced level 2) items get 5 stars, sub-items 7
  local O = { "#+STARTUP: odd", "* A", "*** B", "- item", "  - sub", "text" }
  it("C-c * turns the item into a level 5 headline", function()
    local buf = org_buffer(O, { 4, 0 })
    require("org.actions").run("ctrl_c_star")
    eq({ "#+STARTUP: odd", "* A", "*** B", "***** item", "  - sub", "text" }, buf_lines(buf))
  end)

  it("list_make_subtree uses odd levels for sub-lists", function()
    local buf = org_buffer(O, { 4, 0 })
    require("org.actions").run("list_make_subtree")
    eq({ "#+STARTUP: odd", "* A", "*** B", "***** item", "******* sub", "text" }, buf_lines(buf))
  end)
end)

describe("lists: C-c - on a description list (org-cycle-list-bullet)", function()
  -- org-cycle-list-bullet leaves 1. 1) and the letters out of the cycle
  -- when org-at-item-description-p matches the item at point: after the
  -- bullet (and a [@N] counter), the regexp \(\S-.+\)[ \t]+::\([ \t]+\|$\),
  -- so a one-character term ("a :: b") doesn't count, while one after a
  -- checkbox does. Every line below is what Emacs Org 9.8.12 gave.
  local function cycle(lines, cursor, n, dir)
    org_buffer(lines, cursor)
    return cycle_n(n, dir)
  end

  it("cycles - and + at column 0, and *, too, when indented", function()
    eq(
      { "+ Apple :: a fruit", "- Apple :: a fruit", "+ Apple :: a fruit", "- Apple :: a fruit" },
      cycle({ "- Apple :: a fruit", "- Carrot :: a veg" }, { 1, 0 }, 4)
    )
    eq(
      { "  + Apple :: a fruit", "  * Apple :: a fruit", "  - Apple :: a fruit", "  + Apple :: a fruit" },
      cycle({ "* H", "  - Apple :: a fruit", "  - Carrot :: a veg" }, { 2, 0 }, 4)
    )
    eq(
      { "+ Apple :: a fruit", "- Apple :: a fruit", "+ Apple :: a fruit" },
      cycle({ "- Apple :: a fruit", "- Carrot :: a veg" }, { 1, 0 }, 3, -1)
    )
  end)

  it("leaves a numbered description list for +", function()
    eq(
      { "+ Apple :: a fruit", "- Apple :: a fruit" },
      cycle({ "1. Apple :: a fruit", "2. Carrot :: a veg" }, { 1, 0 }, 2)
    )
  end)

  it("looks at the item at point, not at the first one", function()
    eq({ "+ Carrot", "2. Carrot", "2) Carrot", "- Carrot" }, cycle({ "- Apple :: a fruit", "- Carrot" }, { 2, 0 }, 4))
    eq(
      { "+ Carrot :: a veg", "- Carrot :: a veg", "+ Carrot :: a veg" },
      cycle({ "- Apple", "- Carrot :: a veg" }, { 2, 0 }, 3)
    )
  end)

  it("needs a term of two characters, a checkbox or a counter before it", function()
    eq({ "+ a :: b", "1. a :: b", "1) a :: b" }, cycle({ "- a :: b" }, { 1, 0 }, 3))
    eq({ "+ ab :: b", "- ab :: b" }, cycle({ "- ab :: b" }, { 1, 0 }, 2))
    eq({ "+ [ ] a :: b", "- [ ] a :: b" }, cycle({ "- [ ] a :: b" }, { 1, 0 }, 2))
    eq({ "+ [@3] Apple :: b", "- [@3] Apple :: b" }, cycle({ "- [@3] Apple :: b" }, { 1, 0 }, 2))
    eq({ "+ Apple\t:: b", "- Apple\t:: b" }, cycle({ "- Apple\t:: b" }, { 1, 0 }, 2))
    eq({ "+ Apple ::", "- Apple ::" }, cycle({ "- Apple ::", "- Carrot :: x" }, { 1, 0 }, 2))
    eq({ "+ Apple ::x", "1. Apple ::x" }, cycle({ "- Apple ::x", "- Carrot" }, { 1, 0 }, 2))
  end)

  it("counts the term in characters, not bytes", function()
    eq({ "+ é :: b", "1. é :: b" }, cycle({ "- é :: b", "- c" }, { 1, 0 }, 2))
    eq({ "+ 甲 :: b", "1. 甲 :: b" }, cycle({ "- 甲 :: b", "- c" }, { 1, 0 }, 2))
    eq({ "+ 甲乙 :: b", "- 甲乙 :: b" }, cycle({ "- 甲乙 :: b", "- c" }, { 1, 0 }, 2))
  end)

  describe("with alphabetical bullets", function()
    with_config({ lists = { allow_alphabetical = true } })
    it("leaves the letters out too", function()
      eq(
        { "  + Apple :: a fruit", "  * Apple :: a fruit", "  - Apple :: a fruit" },
        cycle({ "* H", "  - Apple :: a fruit", "  - Carrot :: a veg" }, { 2, 0 }, 3)
      )
    end)
  end)
end)

describe("lists: C-c C-c at the start of a list (org-ctrl-c-ctrl-c on a plain-list)", function()
  -- At the very start of a list's first line (column 0, even when the
  -- list is indented, and for a sub-list too), and on an affiliated
  -- keyword above it, org-element-context is the plain list, not the
  -- item. org-ctrl-c-ctrl-c's plain-list branch then sets the boxes of
  -- every item of that list after the first one's: C-u removes them when
  -- the first item has one, else adds `[ ]`; C-u C-u sets `[-]`. Without
  -- a prefix it toggles the first item's box. Then org-list-write-struct
  -- (no ORDERED check) and the cookies. Every buffer below is what Emacs
  -- Org 9.8.12 gave.
  local G = { "* Groceries [/]", "- [ ] milk", "- [X] bread", "- [ ] eggs", "- butter" }
  local G2 = { "* Groceries [/]", "- milk", "- [X] bread", "- [ ] eggs", "- butter" }
  local N = { "* T [%]", "- [ ] parent", "  - [ ] c1", "  - [X] c2", "- [ ] p2" }

  --- C-c C-c typed with count `n` (4 for C-u, 16 for C-u C-u) at `cursor`.
  local function cc(lines, cursor, n)
    local buf = org_buffer(lines, cursor)
    _G.__org_lists_cc = function()
      require("org.actions").run("context_action")
    end
    vim.keymap.set("n", "<F13>", "<Cmd>lua __org_lists_cc()<CR>")
    vim.api.nvim_feedkeys((n and tostring(n) or "") .. vim.keycode("<F13>"), "x", false)
    vim.keymap.del("n", "<F13>")
    _G.__org_lists_cc = nil
    return buf_lines(buf)
  end

  it("C-u removes every box when the first item has one", function()
    eq({ "* Groceries [0/0]", "- milk", "- bread", "- eggs", "- butter" }, cc(G, { 2, 0 }, 4))
    eq({ "- a", "  body", "- b" }, cc({ "- [ ] a", "  body", "- [X] b" }, { 1, 0 }, 4))
  end)

  it("C-u adds an empty box to every item when the first item has none", function()
    eq({ "* Groceries [0/4]", "- [ ] milk", "- [ ] bread", "- [ ] eggs", "- [ ] butter" }, cc(G2, { 2, 0 }, 4))
  end)

  it("C-u C-u sets [-] on every item", function()
    eq({ "* Groceries [0/4]", "- [-] milk", "- [-] bread", "- [-] eggs", "- [-] butter" }, cc(G, { 2, 0 }, 16))
    eq({ "* Groceries [0/4]", "- [-] milk", "- [-] bread", "- [-] eggs", "- [-] butter" }, cc(G2, { 2, 0 }, 16))
  end)

  it("without a prefix toggles the first item's box, or only repairs", function()
    eq({ "* Groceries [2/3]", "- [X] milk", "- [X] bread", "- [ ] eggs", "- butter" }, cc(G, { 2, 0 }))
    eq({ "* Groceries [1/2]", "- milk", "- [X] bread", "- [ ] eggs", "- butter" }, cc(G2, { 2, 0 }))
    eq({ "* H", "  1. [X] a", "  2. [X] b", "  3. c" }, cc({ "* H", "  1. [ ] a", "  3. [X] b", "  7. c" }, { 2, 0 }))
  end)

  it("says so when a parent's box can't change", function()
    local notify, warn = {}, {}
    local utils = require("org.utils")
    local orig_notify, orig_warn = utils.notify, utils.warn
    utils.notify = function(msg)
      notify[#notify + 1] = msg
    end
    utils.warn = function(msg)
      warn[#warn + 1] = msg
    end
    local okc, out = pcall(cc, { "- [ ] p", "  - [ ] c" }, { 1, 0 })
    utils.notify, utils.warn = orig_notify, orig_warn
    ok(okc, out)
    eq({ "- [ ] p", "  - [ ] c" }, out)
    eq({ "Cannot update this checkbox" }, notify)
    eq({}, warn)
  end)

  it("leaves the cursor after a bullet at column 0 that the repair rewrote", function()
    -- org-list-struct-apply-struct puts the new bullet back with
    -- insert-before-markers, which pushes point past it; a checkbox
    -- removed after it then takes the blank before the box, and point
    local function cursor_after(lines, cursor, n)
      cc(lines, cursor, n)
      return vim.api.nvim_win_get_cursor(0)
    end
    eq({ 1, 3 }, cursor_after({ "1. [@3] [ ] a", "2. [X] b" }, { 1, 0 }, 4))
    eq({ 1, 3 }, cursor_after({ "2. [ ] a", "5. [X] b" }, { 1, 0 }))
    eq({ 1, 3 }, cursor_after({ "2. a", "5. b" }, { 1, 0 }, 4))
    eq({ 1, 2 }, cursor_after({ "-   [ ] a", "- [X] b" }, { 1, 0 }))
    eq({ 1, 2 }, cursor_after({ "-", "- [X] b" }, { 1, 0 }, 4))
    eq({ 1, 2 }, cursor_after({ "2. [ ] a", "5. [X] b" }, { 1, 0 }, 4))
    eq({ 1, 1 }, cursor_after({ "-   [X] a", "- [ ] b" }, { 1, 0 }, 4))
    -- a bullet that stays, or one after indentation: column 0
    eq({ 1, 0 }, cursor_after({ "- [ ] a", "- [X] b" }, { 1, 0 }, 4))
    eq({ 2, 0 }, cursor_after({ "* H", "  2. [ ] a", "  5. [X] b" }, { 2, 0 }, 4))
  end)

  it("on a radio list's #+attr_org line: the plain list, not the radio buttons", function()
    -- org-at-radio-list-p needs point on an item line
    local R = { "#+attr_org: :radio t", "- [ ] a", "- [X] b" }
    eq({ "#+attr_org: :radio t", "- a", "- b" }, cc(R, { 1, 0 }, 4))
    eq({ "#+attr_org: :radio t", "- [-] a", "- [-] b" }, cc(R, { 1, 5 }, 16))
    -- at column 0 of its first item, the radio buttons
    eq({ "#+attr_org: :radio t", "- [X] a", "- [ ] b" }, cc(R, { 2, 0 }))
  end)

  it("acts on the item one column further", function()
    eq({ "* Groceries [1/2]", "- milk", "- [X] bread", "- [ ] eggs", "- butter" }, cc(G, { 2, 1 }, 4))
    eq({ "* T [50%]", "- [X] parent", "  - c1", "  - [X] c2", "- [ ] p2" }, cc(N, { 3, 2 }, 4))
    eq({ "* H", "  1. a", "  2. [X] b", "  3. c" }, cc({ "* H", "  1. [ ] a", "  3. [X] b", "  7. c" }, { 2, 2 }, 4))
  end)

  it("at column 0 of an indented list, the whole list", function()
    eq({ "* H", "  1. a", "  2. b", "  3. c" }, cc({ "* H", "  1. [ ] a", "  3. [X] b", "  7. c" }, { 2, 0 }, 4))
    eq({ "* H", " - a", " - b" }, cc({ "* H", " - [ ] a", " - [X] b" }, { 2, 0 }, 4))
  end)

  it("on a sub-list's first line, that sub-list; on the top one, its top items", function()
    eq({ "* T [0%]", "- [ ] parent", "  - c1", "  - c2", "- [ ] p2" }, cc(N, { 3, 0 }, 4))
    eq({ "* T [0%]", "- [-] parent", "  - [-] c1", "  - [-] c2", "- [ ] p2" }, cc(N, { 3, 0 }, 16))
    eq({ "* T [0%]", "- parent", "  - [ ] c1", "  - [X] c2", "- p2" }, cc(N, { 2, 0 }, 4))
    eq({ "* T [0%]", "- [-] parent", "  - [ ] c1", "  - [X] c2", "- [-] p2" }, cc(N, { 2, 0 }, 16))
  end)

  it("only at the first item of its list", function()
    eq({ "* Groceries [0/2]", "- [ ] milk", "- bread", "- [ ] eggs", "- butter" }, cc(G, { 3, 0 }, 4))
    -- two blank lines end a list: "- [ ] b" starts another one
    eq({ "- [ ] a", "", "", "- b", "- c" }, cc({ "- [ ] a", "", "", "- [ ] b", "- c" }, { 4, 0 }, 4))
  end)

  it("ignores ORDERED, which the item's C-c C-c follows", function()
    local O = { "* T", ":PROPERTIES:", ":ORDERED: t", ":END:", "- [X] a", "- [X] b", "- [ ] c" }
    eq({ "* T", ":PROPERTIES:", ":ORDERED: t", ":END:", "- [ ] a", "- [X] b", "- [ ] c" }, cc(O, { 5, 0 }))
    eq({ "* T", ":PROPERTIES:", ":ORDERED: t", ":END:", "- [ ] a", "- [ ] b", "- [ ] c" }, cc(O, { 5, 1 }))
  end)

  it("on an affiliated keyword: the list, at any column, without toggling", function()
    local K = { "* H", "#+NAME: foo", "- [ ] a", "- [X] b" }
    eq({ "* H", "#+NAME: foo", "- a", "- b" }, cc(K, { 2, 4 }, 4))
    eq(K, cc(K, { 2, 0 }))
  end)
end)

describe("lists: the cursor after C-c ^ (org-sort-list)", function()
  -- org-sort-list narrows to the list, goes to point-min and sorts with
  -- sort-subr (whose save-excursion keeps point there), then runs
  -- org-list-repair: point ends at the start of the list's first line,
  -- column 0, whatever item it was on. When that repair renumbers a
  -- bullet at column 0, its insert-before-markers pushes point past the
  -- new bullet. Every buffer and position below is what Emacs Org
  -- 9.8.12 gave.
  local function sort(lines, cursor, key)
    local buf = org_buffer(lines, cursor)
    local ui = require("org.ui")
    local orig = ui.menu
    ui.menu = function(opts)
      for _, it in ipairs(opts.items) do
        if it.key == key then
          return it.value
        end
      end
    end
    local okc, err = pcall(require("org.actions").run, "ctrl_c_caret")
    ui.menu = orig
    ok(okc, err)
    return { buf_lines(buf), vim.api.nvim_win_get_cursor(0) }
  end

  local F = { "* Fruits", "- pear", "- Apple", "- banana" }

  it("leaves the cursor at the start of the list, from any item", function()
    eq({ { "* Fruits", "- pear", "- banana", "- Apple" }, { 2, 0 } }, sort(F, { 3, 0 }, "A"))
    eq({ { "* Fruits", "- Apple", "- banana", "- pear" }, { 2, 0 } }, sort(F, { 3, 4 }, "a"))
    eq({ { "* Fruits", "- Apple", "- banana", "- pear" }, { 2, 0 } }, sort(F, { 4, 3 }, "a"))
    eq({ { "* F", "- a", "- b", "- c" }, { 2, 0 } }, sort({ "* F", "- a", "- b", "- c" }, { 3, 2 }, "a"))
    eq(
      { { "* F", "Some text", "- apple", "- pear" }, { 3, 0 } },
      sort({ "* F", "Some text", "- pear", "- apple" }, { 4, 1 }, "a")
    )
  end)

  it("at column 0 of an indented list or a sub-list", function()
    eq(
      { { "* F", "  - Apple", "  - banana", "  - pear" }, { 2, 0 } },
      sort({ "* F", "  - pear", "  - Apple", "  - banana" }, { 3, 5 }, "a")
    )
    eq(
      { { "- top", "  - apple", "  - pear", "- b" }, { 2, 0 } },
      sort({ "- top", "  - pear", "  - apple", "- b" }, { 3, 4 }, "a")
    )
    eq({ { "* F", "  1. apple", "  2. pear" }, { 2, 0 } }, sort({ "* F", "  3. pear", "  7. apple" }, { 3, 4 }, "a"))
    eq({ { "* F", "\t- apple", "\t- pear" }, { 2, 0 } }, sort({ "* F", "\t- pear", "\t- apple" }, { 3, 1 }, "a"))
  end)

  it("after a bullet at column 0 that the repair renumbers", function()
    eq({ { "* F", "1. apple", "2. pear" }, { 2, 3 } }, sort({ "* F", "1. pear", "2. apple" }, { 3, 3 }, "a"))
  end)

  it("repairs the sorted list only, as narrowed to it, without ORDERED", function()
    -- org-list-repair runs inside the narrowing: the items around it,
    -- and the sub-list's indentation under them, stay as they are
    eq(
      { { "1. top", "   - apple", "   - pear", "3. b" }, { 2, 0 } },
      sort({ "1. top", "   - pear", "   - apple", "3. b" }, { 3, 5 }, "a")
    )
    eq(
      { { "1. top", "  - apple", "  - pear", "2. b" }, { 2, 0 } },
      sort({ "1. top", "  - pear", "  - apple", "2. b" }, { 3, 5 }, "a")
    )
    eq(
      { { "- [ ] p", "  - [X] a", "  - [X] b", "- [ ] q" }, { 2, 0 } },
      sort({ "- [ ] p", "  - [X] b", "  - [X] a", "- [ ] q" }, { 3, 4 }, "a")
    )
    eq(
      { { "1. top", "   - apple", "   - pear", "     1. x", "     2. y", "2. b" }, { 2, 0 } },
      sort({ "1. top", "   - pear", "     1. x", "     3. y", "   - apple", "2. b" }, { 5, 4 }, "a")
    )
    local O = { "* T", ":PROPERTIES:", ":ORDERED: t", ":END:", "- [X] b", "- [ ] a", "- [X] c" }
    eq(
      { { "* T", ":PROPERTIES:", ":ORDERED: t", ":END:", "- [ ] a", "- [X] b", "- [X] c" }, { 5, 0 } },
      sort(O, { 6, 3 }, "a")
    )
  end)
end)
