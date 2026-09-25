local lists = require("org.lists")

describe("lists: parsing", function()
  it("parses item lines", function()
    local it = lists.parse_item_line("  - [X] done thing")
    eq(2, it.indent)
    eq("-", it.bullet)
    eq("X", it.checkbox)
    eq("done thing", it.text)
    eq(8, it.content_col)
    local o = lists.parse_item_line("3) [@3] third")
    ok(o.is_ordered)
    eq(3, o.counter)
    local d = lists.parse_item_line("- term :: description")
    eq("term", d.tag)
    eq(nil, lists.parse_item_line("* headline"))
    ok(lists.parse_item_line("  * star item"))
    eq(nil, lists.parse_item_line("plain text"))
  end)

  it("finds items, children and continuation lines", function()
    local buf = org_buffer({
      "* H",
      "- one",
      "  continued",
      "  - child a",
      "  - child b",
      "- two",
      "",
      "text after",
    })
    local it = lists.item_at(buf, 3)
    eq(2, it.lnum)
    eq(5, it.end_lnum)
    eq(2, #it.children)
    local c = lists.item_at(buf, 5)
    eq(5, c.lnum)
    eq(it.lnum, c.parent.lnum)
    eq(6, lists.item_at(buf, 6).lnum)
    eq(nil, lists.item_at(buf, 8))
    eq(nil, lists.item_at(buf, 1))
    eq(2, #lists.siblings(it))
  end)

  it("two blank lines end a list", function()
    local buf = org_buffer({ "- a", "", "", "  indented" })
    eq(nil, lists.item_at(buf, 4))
  end)
end)

describe("lists: checkboxes & cookies", function()
  it("toggles and updates parents and cookies", function()
    local buf = org_buffer({
      "* Task [0/2] [0%]",
      "- [ ] parent [/]",
      "  - [ ] a",
      "  - [ ] b",
      "- [ ] other",
    }, { 3, 0 })
    lists.toggle_checkbox()
    local l = buf_lines(buf)
    eq("  - [X] a", l[3])
    eq("- [-] parent [1/2]", l[2])
    eq("* Task [0/2] [0%]", l[1])
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    lists.toggle_checkbox()
    l = buf_lines(buf)
    eq("- [X] parent [2/2]", l[2])
    eq("* Task [1/2] [50%]", l[1])
  end)

  -- Emacs: a parent box follows its children (org-list-automatic-rules)
  it("a parent checkbox follows its children", function()
    local buf = org_buffer({ "- [ ] p", "  - [ ] a", "  - [ ] b" }, { 1, 0 })
    lists.toggle_checkbox()
    eq({ "- [ ] p", "  - [ ] a", "  - [ ] b" }, buf_lines(buf))
  end)

  -- Emacs org-toggle-checkbox leaves items without a box alone
  it("leaves plain items alone and returns false elsewhere", function()
    local buf = org_buffer({ "- item", "text" }, { 1, 0 })
    lists.toggle_checkbox()
    eq("- item", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    eq(false, lists.toggle_checkbox())
  end)

  it("counts TODO children in headline cookies", function()
    local buf = org_buffer({ "* P [/]", "** TODO a", "** DONE b", "** c" })
    lists.update_statistics_for(buf, 3)
    eq("* P [1/2]", buf_lines(buf)[1])
  end)

  it("respects COOKIE_DATA recursive", function()
    local buf = org_buffer({
      "* P [%]",
      ":PROPERTIES:",
      ":COOKIE_DATA: todo recursive",
      ":END:",
      "** TODO a",
      "*** DONE b",
    })
    lists.update_statistics()
    eq("* P [50%]", buf_lines(buf)[1])
  end)
end)

describe("lists: editing", function()
  it("new item renumbers ordered lists", function()
    local buf = org_buffer({ "1. a", "2. b" }, { 1, 0 })
    lists.new_item({ pos = { 1, 4 } })
    eq({ "1. a", "2. ", "3. b" }, buf_lines(buf))
    eq(2, vim.api.nvim_win_get_cursor(0)[1])
  end)

  -- Emacs org-insert-item: no checkbox copied, after the children when
  -- the line isn't split, before the item at or before its text
  it("new item goes after children without copying the checkbox", function()
    local buf = org_buffer({ "- [X] a", "  - sub", "- b" }, { 1, 0 })
    lists.new_item({ pos = { 1, 7 }, split = false })
    eq({ "- [X] a", "  - sub", "- ", "- b" }, buf_lines(buf))
    buf = org_buffer({ "- [X] a", "  - sub", "- b" }, { 1, 0 })
    lists.new_item({ pos = { 1, 0 } })
    eq({ "- ", "- [X] a", "  - sub", "- b" }, buf_lines(buf))
  end)

  it("splitting an item moves the rest and its children to the new item", function()
    local buf = org_buffer({ "- ab", "  - sub", "- c" }, { 1, 0 })
    lists.new_item({ pos = { 1, 3 } })
    eq({ "- a", "- b", "  - sub", "- c" }, buf_lines(buf))
    eq({ 2, 2 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("new item honours blank_before_new_entry.plain_list_item", function()
    local config = require("org.config")
    config.opts.blank_before_new_entry.plain_list_item = true
    local buf = org_buffer({ "- a", "- b" }, { 1, 0 })
    lists.new_item({ pos = { 1, 3 } })
    eq({ "- a", "", "- ", "- b" }, buf_lines(buf))
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
    config.opts.blank_before_new_entry.plain_list_item = "auto"
    buf = org_buffer({ "- a", "- b", "", "- c" }, { 1, 0 })
    lists.new_item({ pos = { 1, 3 } })
    eq({ "- a", "- ", "- b", "", "- c" }, buf_lines(buf))
    lists.new_item({ pos = { 5, 3 } })
    eq({ "- a", "- ", "- b", "", "- c", "", "- " }, buf_lines(buf))
    -- a single item: blank lines inside the list count
    buf = org_buffer({ "- a", "", "  p" }, { 1, 0 })
    lists.new_item({ pos = { 3, 3 } })
    eq({ "- a", "", "  p", "", "- " }, buf_lines(buf))
  end)

  it("indents and outdents items", function()
    local buf = org_buffer({ "- a", "- b", "  - c" }, { 2, 0 })
    lists.indent_item(1, true)
    eq({ "- a", "  - b", "    - c" }, buf_lines(buf))
    lists.indent_item(-1, true)
    eq({ "- a", "- b", "  - c" }, buf_lines(buf))
  end)

  it("moves items with children", function()
    local buf = org_buffer({ "- a", "  - a1", "- b" }, { 3, 0 })
    lists.move_item(-1)
    eq({ "- b", "- a", "  - a1" }, buf_lines(buf))
    eq(1, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("moves ordered items and renumbers", function()
    local buf = org_buffer({ "1. a", "2. b" }, { 1, 0 })
    lists.move_item(1)
    eq({ "1. b", "2. a" }, buf_lines(buf))
  end)

  it("cycles bullets", function()
    local buf = org_buffer({ "- a", "  cont", "- b" }, { 1, 0 })
    lists.cycle_bullet(1)
    eq({ "+ a", "  cont", "+ b" }, buf_lines(buf))
    lists.cycle_bullet(1)
    eq({ "1. a", "   cont", "2. b" }, buf_lines(buf))
  end)

  it("repair honours counters and widths", function()
    local buf = org_buffer({ "1. [@9] a", "1. b", "   cont" })
    lists.repair(buf, 1)
    eq({ "9. [@9] a", "10. b", "    cont" }, buf_lines(buf))
  end)

  it("toggle_item converts lines", function()
    local buf = org_buffer({ "text" }, { 1, 0 })
    lists.toggle_item()
    eq({ "- text" }, buf_lines(buf))
    lists.toggle_item()
    eq({ "text" }, buf_lines(buf))
  end)
end)
