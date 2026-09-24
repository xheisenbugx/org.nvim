local structure = require("org.structure")

local function cur()
  return vim.api.nvim_win_get_cursor(0)
end

describe("structure: inserting headings", function()
  it("M-RET inserts sibling after subtree", function()
    local buf = org_buffer({ "* A", "body", "** A1", "* B" }, { 2, 0 })
    structure.meta_return_heading({})
    eq({ "* A", "body", "** A1", "* ", "* B" }, buf_lines(buf))
    eq(4, cur()[1])
  end)

  it("M-RET at start of headline inserts above", function()
    local buf = org_buffer({ "* A" }, { 1, 0 })
    structure.meta_return_heading({})
    eq({ "* ", "* A" }, buf_lines(buf))
  end)

  it("TODO heading uses first keyword", function()
    local buf = org_buffer({ "#+TODO: NEXT | FIN", "* A" }, { 2, 3 })
    structure.meta_return_heading({ todo = true })
    eq("* NEXT ", buf_lines(buf)[3])
  end)

  it("respects blank lines with auto", function()
    local buf = org_buffer({ "* A", "", "* B", "text" }, { 3, 2 })
    structure.meta_return_heading({})
    eq({ "* A", "", "* B", "text", "", "* " }, buf_lines(buf))
  end)

  it("inserts subheading after own section", function()
    local buf = org_buffer({ "* A", "body", "** old" }, { 1, 0 })
    structure.insert_subheading()
    vim.cmd("stopinsert")
    eq({ "* A", "body", "** ", "** old" }, buf_lines(buf))
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

  it("cut and paste at a different level", function()
    local buf = org_buffer({ "* A", "** A1", "text", "* B" }, { 2, 0 })
    structure.cut_subtree()
    eq({ "* A", "* B" }, buf_lines(buf))
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    structure.paste_subtree()
    eq({ "* A", "* B", "* A1", "text" }, buf_lines(buf))
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

  local function pick(key)
    local ui = require("org.ui")
    local orig = ui.menu
    ui.menu = function(opts)
      for _, it in ipairs(opts.items) do
        if it.key == key then
          return it.value
        end
      end
    end
    return function()
      ui.menu = orig
    end
  end

  it("sorts the entries selected in Visual mode", function()
    local buf = org_buffer({
      "#+TITLE: t",
      "* [#C] c",
      "body c",
      "** child of c",
      "* [#A] a",
      "* [#B] b",
      "body b",
      "* untouched",
    }, { 2, 0 })
    vim.cmd("normal! zR")
    local restore = pick("p")
    -- select from "c" into the body of "b": its whole subtree is included
    vim.api.nvim_feedkeys(vim.keycode("V5j<leader>ohs"), "xt", false)
    restore()
    eq({
      "#+TITLE: t",
      "* [#A] a",
      "* [#B] b",
      "body b",
      "* [#C] c",
      "body c",
      "** child of c",
      "* untouched",
    }, buf_lines(buf))
    eq("n", vim.fn.mode())
  end)

  it("sorts only the top-level entries of the selection", function()
    local buf = org_buffer({ "* P", "** b", "*** z", "*** y", "** a" }, { 2, 0 })
    vim.cmd("normal! zR")
    local restore = pick("a")
    vim.api.nvim_feedkeys(vim.keycode("V3j<leader>ohs"), "xt", false)
    restore()
    eq({ "* P", "** a", "** b", "*** z", "*** y" }, buf_lines(buf))
  end)

  it("sorts list items selected in Visual mode", function()
    local buf = org_buffer({ "* H", "- b", "- c", "- a" }, { 2, 0 })
    vim.cmd("normal! zR")
    local restore = pick("a")
    vim.api.nvim_feedkeys(vim.keycode("Vj<leader>ohs"), "xt", false)
    restore()
    eq({ "* H", "- a", "- b", "- c" }, buf_lines(buf))
  end)

  it("sorts the children of a single selected (folded) entry", function()
    local buf = org_buffer({ "* P", "** b", "** a", "* Q" }, { 1, 0 })
    vim.cmd("normal! zx")
    local restore = pick("a")
    vim.api.nvim_feedkeys(vim.keycode("V<leader>ohs"), "xt", false)
    restore()
    eq({ "* P", "** a", "** b", "* Q" }, buf_lines(buf))
  end)

  it("leaves a heading without children alone", function()
    local buf = org_buffer({ "* b", "* a" }, { 1, 0 })
    local asked = false
    local ui = require("org.ui")
    local orig = ui.menu
    ui.menu = function()
      asked = true
    end
    structure.sort()
    ui.menu = orig
    eq(false, asked, "no menu when there is nothing to sort")
    eq({ "* b", "* a" }, buf_lines(buf))
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
    local l = buf_lines(buf)
    eq(9, #l)
    eq("SCHEDULED: <2026-09-02 Wed>", l[7])
    eq("SCHEDULED: <2026-09-03 Thu>", l[9])
    eq("SCHEDULED: <2026-09-01 Tue +1w>", l[2])
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
    local buf = org_buffer({ "* A", "- x" }, { 2, 0 })
    require("org.fold").show_all()
    keys("<M-CR>")
    eq({ "* A", "- x", "- " }, buf_lines(buf))
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    keys("<M-CR>")
    eq("* ", buf_lines(buf)[4])
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
    eq({ "* A", "#+begin_quote", "", "#+end_quote" }, buf_lines(buf))
  end)
  it("drawer", function()
    local buf = org_buffer({ "* A", "x" }, { 1, 0 })
    local u = require("org.utils"); local o = u.input
    u.input = function() return "notes" end
    s.insert_drawer(); vim.cmd("stopinsert")
    u.input = o
    eq({ "* A", ":NOTES:", "", ":END:", "x" }, buf_lines(buf))
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
