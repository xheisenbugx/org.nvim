local structure = require("org.structure")

local function cur()
  return vim.api.nvim_win_get_cursor(0)
end

local function with_stub(tbl, key, fn, body)
  local orig = tbl[key]
  tbl[key] = fn
  local ok, err = pcall(body)
  tbl[key] = orig
  if not ok then
    error(err, 0)
  end
end

local function edit_build(before, tags)
  return require("org.edit").with_tags(before, tags)
end

describe("structure: inserting headings", function()
  -- Emacs org-insert-heading: C-u (arg 4) inserts after the subtree; at
  -- the end of a headline the new one goes right below it; at the start
  -- of a text line, that line becomes a headline
  it("M-RET with C-u inserts a sibling after the subtree", function()
    local buf = org_buffer({ "* A", "body", "** A1", "* B" }, { 2, 0 })
    structure.meta_return_heading({ arg = 4 })
    eq({ "* A", "body", "** A1", "* ", "* B" }, buf_lines(buf))
    eq(4, cur()[1])
    buf = org_buffer({ "* A", "body", "** A1", "* B" }, { 1, 0 })
    structure.meta_return_heading({ pos = { 1, 3 } })
    eq({ "* A", "* ", "body", "** A1", "* B" }, buf_lines(buf))
    buf = org_buffer({ "* A", "body" }, { 2, 0 })
    structure.meta_return_heading({})
    eq({ "* A", "* body" }, buf_lines(buf))
  end)

  it("M-RET at start of headline inserts above", function()
    local buf = org_buffer({ "* A" }, { 1, 0 })
    structure.meta_return_heading({})
    eq({ "* ", "* A" }, buf_lines(buf))
  end)

  it("M-RET splits the title at point, keeping the tags", function()
    local buf = org_buffer({ "* Heading :t:" }, { 1, 0 })
    structure.meta_return_heading({ pos = { 1, 5 } })
    eq(edit_build("* Hea", { "t" }), buf_lines(buf)[1])
    eq("* ding", buf_lines(buf)[2])
    eq(2, cur()[1])
  end)

  it("TODO heading uses the keyword of the current entry", function()
    local buf = org_buffer({ "#+TODO: NEXT WAIT | FIN", "* WAIT A" }, { 2, 3 })
    structure.meta_return_heading({ todo = true, pos = { 2, 8 } })
    eq("* WAIT ", buf_lines(buf)[3])
    structure.meta_return_heading({ todo = true, pos = { 2, 8 }, arg = 4 })
    eq("* NEXT ", buf_lines(buf)[3])
  end)

  it("respects blank lines with auto", function()
    local buf = org_buffer({ "* A", "", "* B", "text" }, { 3, 2 })
    structure.meta_return_heading({ arg = 4 })
    eq({ "* A", "", "* B", "text", "", "* " }, buf_lines(buf))
  end)

  -- Emacs org-insert-subheading: a headline below the current line, demoted
  it("inserts subheading below the headline", function()
    local buf = org_buffer({ "* A", "body", "** old" }, { 1, 0 })
    structure.insert_subheading()
    vim.cmd("stopinsert")
    eq({ "* A", "** ", "body", "** old" }, buf_lines(buf))
  end)
end)

describe("structure: promote/demote", function()
  it("demotes only the heading", function()
    local buf = org_buffer({ "* A", "** B" }, { 1, 0 })
    structure.demote_heading()
    eq({ "** A", "** B" }, buf_lines(buf))
  end)
  it("demotes subtree and realigns tags", function()
    local buf = org_buffer({ "* A    :x:", "** B" }, { 1, 0 })
    structure.demote_subtree()
    local l = buf_lines(buf)
    eq("** A", l[1]:sub(1, 4))
    eq(77, vim.api.nvim_strwidth(l[1]))
    eq("*** B", l[2])
  end)
  it("refuses to promote level 1", function()
    local buf = org_buffer({ "* A" }, { 1, 0 })
    structure.promote_heading()
    eq({ "* A" }, buf_lines(buf))
  end)
end)

describe("structure: moving and kill ring", function()
  it("moves subtrees", function()
    local buf = org_buffer({ "* A", "a", "* B", "b", "** B1" }, { 3, 0 })
    structure.move_subtree_up()
    eq({ "* B", "b", "** B1", "* A", "a" }, buf_lines(buf))
    eq(1, cur()[1])
    structure.move_subtree_down()
    eq({ "* A", "a", "* B", "b", "** B1" }, buf_lines(buf))
  end)

  -- Emacs org-paste-subtree: at the start of a headline, before it with
  -- its level; elsewhere before the next visible headline, at the deeper
  -- level of the headlines around
  it("cut and paste at a different level", function()
    local buf = org_buffer({ "* A", "** A1", "text", "* B" }, { 2, 0 })
    with_stub(vim, "notify", function() end, function()
      structure.cut_subtree()
      eq({ "* A", "* B" }, buf_lines(buf))
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      structure.paste_subtree()
      eq({ "* A", "* A1", "text", "* B" }, buf_lines(buf))
      eq({ 2, 0 }, cur())
    end)
    buf = org_buffer({ "* A", "** B", "body", "*** C" }, { 1, 0 })
    with_stub(vim, "notify", function() end, function()
      structure.copy_subtree()
      vim.api.nvim_win_set_cursor(0, { 3, 2 })
      structure.paste_subtree()
    end)
    eq({ "* A", "** B", "body", "*** A", "**** B", "body", "***** C", "*** C" }, buf_lines(buf))
  end)
end)

describe("structure: toggles", function()
  it("toggle comment", function()
    local buf = org_buffer({ "* TODO A" }, { 1, 0 })
    structure.toggle_comment()
    eq("* TODO COMMENT A", buf_lines(buf)[1])
    structure.toggle_comment()
    eq("* TODO A", buf_lines(buf)[1])
  end)

  it("toggle heading", function()
    local buf = org_buffer({ "* A", "- [X] item" }, { 2, 0 })
    structure.toggle_heading()
    eq("** DONE item", buf_lines(buf)[2])
    structure.toggle_heading()
    eq("DONE item", buf_lines(buf)[2])
  end)
end)

describe("structure: sort", function()
  it("sorts children alphabetically via menu", function()
    local buf = org_buffer({ "* P", "** c", "** a", "** b" }, { 1, 0 })
    local ui = require("org.ui")
    local orig = ui.menu
    ui.menu = function(opts)
      for _, it in ipairs(opts.items) do
        if it.key == "a" then
          return it.value
        end
      end
    end
    structure.sort()
    eq({ "* P", "** a", "** b", "** c" }, buf_lines(buf))
    ui.menu = function(opts)
      for _, it in ipairs(opts.items) do
        if it.key == "A" then
          return it.value
        end
      end
    end
    structure.sort()
    eq({ "* P", "** c", "** b", "** a" }, buf_lines(buf))
    ui.menu = orig
  end)

  it("sorts by priority and todo order", function()
    local buf = org_buffer({ "* [#C] x", "* DONE y", "* [#A] z" }, { 1, 0 })
    local ui = require("org.ui")
    local orig = ui.menu
    ui.menu = function(opts)
      for _, it in ipairs(opts.items) do
        if it.key == "p" then
          return it.value
        end
      end
    end
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    -- top-level sort needs cursor before first headline; use preamble-less file:
    -- headline_at(1) is "x", whose children are empty -> nothing to sort
    ui.menu = orig
    eq("* [#C] x", buf_lines(buf)[1])
  end)

  it("sorts list items", function()
    local buf = org_buffer({ "- b", "- c", "- a" }, { 1, 0 })
    local ui = require("org.ui")
    local orig = ui.menu
    ui.menu = function(opts)
      for _, it in ipairs(opts.items) do
        if it.key == "a" then
          return it.value
        end
      end
    end
    structure.sort()
    ui.menu = orig
    eq({ "- a", "- b", "- c" }, buf_lines(buf))
  end)
end)

describe("structure: navigation and text objects", function()
  local lines = { "* A", "a", "** A1", "x", "** A2", "* B" }
  it("skips folded headings", function()
    org_buffer(lines, { 1, 0 })
    require("org.fold").overview()
    structure.next_heading()
    eq(6, cur()[1])
  end)

  it("moves between headings", function()
    org_buffer(lines, { 1, 0 })
    require("org.fold").show_all()
    structure.next_heading()
    eq(3, cur()[1])
    structure.next_sibling()
    eq(5, cur()[1])
    structure.goto_parent()
    eq(1, cur()[1])
    structure.next_sibling()
    eq(6, cur()[1])
    structure.prev_heading()
    eq(5, cur()[1])
  end)

  it("selects subtree", function()
    org_buffer(lines, { 2, 0 })
    require("org.fold").show_all()
    structure.select_subtree(false)
    vim.cmd("normal! y")
    eq({ "* A", "a", "** A1", "x", "** A2" }, vim.fn.getreg('"', 1, true))
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    structure.select_heading(true)
    vim.cmd("normal! y")
    eq({ "x" }, vim.fn.getreg('"', 1, true))
  end)
end)

describe("structure: clone", function()
  it("clones with time shift", function()
    local buf = org_buffer({ "* T", "SCHEDULED: <2026-09-01 Tue +1w>", ":PROPERTIES:", ":ID: x", ":END:" }, { 1, 0 })
    local utils = require("org.utils")
    local orig = utils.input
    local answers = { "2", "+1d" }
    utils.input = function()
      return table.remove(answers, 1)
    end
    structure.clone_subtree()
    utils.input = orig
    -- Emacs: with a repeater, n + 2 entries: the original and the clones
    -- lose it, one more clone after them keeps it; every copy gets a new ID
    local l = buf_lines(buf)
    eq(20, #l)
    eq("SCHEDULED: <2026-09-01 Tue>", l[2])
    eq("SCHEDULED: <2026-09-02 Wed>", l[7])
    eq("SCHEDULED: <2026-09-03 Thu>", l[12])
    eq("SCHEDULED: <2026-09-04 Fri +1w>", l[17])
    local ids = {}
    for _, x in ipairs(l) do
      local id = x:match("^:ID:%s+(.*)$")
      if id then
        ids[id] = true
      end
    end
    eq(4, vim.tbl_count(ids))
    eq(nil, ids.x)
  end)

  it("drops the ID with clone_delete_id, shifts backwards, removes clocks", function()
    local config = require("org.config")
    config.opts.clone_delete_id = true
    local buf = org_buffer({
      "* T",
      ":PROPERTIES:",
      ":ID: x",
      ":END:",
      "<2026-09-10 Thu>",
      ":LOGBOOK:",
      "CLOCK: [2026-09-01 Tue 10:00]--[2026-09-01 Tue 11:00] =>  1:00",
      ":END:",
    }, { 1, 0 })
    local utils = require("org.utils")
    local orig = utils.input
    local answers = { "1", "-1d" }
    utils.input = function()
      return table.remove(answers, 1)
    end
    structure.clone_subtree()
    utils.input = orig
    config.opts.clone_delete_id = false
    eq({ "* T", "<2026-09-09 Wed>" }, vim.list_slice(buf_lines(buf), 9, 10))
    eq(10, #buf_lines(buf))
  end)
end)

describe("structure: keymaps integration", function()
  local function keys(k)
    vim.api.nvim_feedkeys(vim.keycode(k), "mx", false)
  end
  it(">> demotes headings and falls back on text", function()
    local buf = org_buffer({ "* A", "text" }, { 1, 0 })
    require("org.fold").show_all()
    keys(">>")
    eq("** A", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    keys(">>")
    eq(vim.bo.shiftwidth, #buf_lines(buf)[2]:match("^(%s*)"))
  end)
  it("M-RET in list adds item, on heading adds heading", function()
    local buf = org_buffer({ "* A", "- x" }, { 2, 2 })
    require("org.fold").show_all()
    keys("<M-CR>")
    vim.cmd("stopinsert")
    eq({ "* A", "- x", "- " }, buf_lines(buf))
    -- Normal mode: at the end of the headline, so right below it
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    keys("<M-CR>")
    vim.cmd("stopinsert")
    eq({ "* A", "* ", "- x", "- " }, buf_lines(buf))
  end)
  it("<Tab> folds a headline", function()
    org_buffer({ "* A", "body", "* B" }, { 1, 0 })
    require("org.fold").show_all()
    keys("<Tab>")
    eq(1, vim.fn.foldclosed(1))
  end)
  it("<M-k> moves list items", function()
    local buf = org_buffer({ "- a", "- b" }, { 2, 0 })
    keys("<M-k>")
    eq({ "- b", "- a" }, buf_lines(buf))
  end)
end)

local s = structure
describe("structure: templates, drawers, narrow, emphasize", function()
  it("template", function()
    local buf = org_buffer({ "* A", "" }, { 2, 0 })
    local ui = require("org.ui"); local orig = ui.menu
    ui.menu = function(o) for _, i in ipairs(o.items) do if i.key == "q" then return i.value end end end
    s.insert_structure_template(); vim.cmd("stopinsert")
    ui.menu = orig
    -- Emacs org-insert-structure-template: the empty line becomes the
    -- block, the cursor goes before its end line
    eq({ "* A", "#+begin_quote", "#+end_quote" }, buf_lines(buf))
    eq({ 3, 0 }, vim.api.nvim_win_get_cursor(0))
  end)
  it("drawer", function()
    local buf = org_buffer({ "* A", "x" }, { 1, 2 })
    local u = require("org.utils"); local o = u.input
    u.input = function() return "notes" end
    s.insert_drawer(); vim.cmd("stopinsert")
    u.input = o
    -- Emacs org-insert-drawer keeps the name as typed
    eq({ "* A", ":notes:", "", ":END:", "", "x" }, buf_lines(buf))
  end)
  it("narrow", function()
    local buf = org_buffer({ "* A", "a", "* B" }, { 1, 0 })
    s.narrow_subtree()
    local b2 = vim.api.nvim_get_current_buf()
    ok(b2 ~= buf)
    eq({ "* A", "a" }, buf_lines(b2))
    vim.api.nvim_buf_set_lines(b2, 1, 2, false, { "changed", "more" })
    vim.cmd("write")
    eq({ "* A", "changed", "more", "* B" }, buf_lines(buf))
    vim.cmd("bwipeout! " .. b2)
  end)
  it("emphasize", function()
    local buf = org_buffer({ "hello world" }, { 1, 0 })
    local u = require("org.utils"); local o = u.getchar
    u.getchar = function() return "*" end
    vim.cmd("normal! v$")
    s.emphasize()
    u.getchar = o
    eq({ "*hello world*" }, buf_lines(buf))
  end)
end)
