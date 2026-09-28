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
    local buf = org_buffer(
      { "* H", ":PROPERTIES:", ":COOKIE_DATA: recursive", ":END:", unpack(text, 2) },
      { 5, 0 }
    )
    lists.update_statistics()
    eq("- [ ] top [3/4]", buf_lines(buf)[5])
  end)

  it("leave item cookies alone with COOKIE_DATA todo", function()
    local buf = org_buffer({ "* H", ":PROPERTIES:", ":COOKIE_DATA: todo", ":END:", "- [ ] top [/]", "  - [X] a" }, { 5, 0 })
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
