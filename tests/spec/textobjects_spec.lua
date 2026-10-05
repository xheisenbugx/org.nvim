-- Text objects (|org-textobj|): each one with an operator (d, y, c), in
-- Visual mode, with a count, grown by typing it again, and repeated with
-- ".".
local function keys(k)
  vim.api.nvim_feedkeys(vim.keycode(k), "xt", false)
end

--- Run `k` in a fresh buffer; returns the lines and the unnamed register.
local function run(lines, cur, k)
  local buf = org_buffer(lines, cur)
  vim.fn.setreg('"', "")
  keys(k)
  return buf_lines(buf), vim.fn.getreg('"'), vim.fn.getregtype('"')
end

--- The Visual selection after `k` ({ mode, srow, scol, erow, ecol }, 1-based).
local function selection(lines, cur, k)
  org_buffer(lines, cur)
  keys(k)
  local mode = vim.fn.mode()
  local a, b = vim.fn.getpos("v"), vim.fn.getpos(".")
  keys("<Esc>")
  return { mode, a[2], a[3], b[2], b[3] }
end

local outline = { "* A", "** B", "b text", "*** C", "c text", "** D", "* E" }

describe("text objects: heading and subtree", function()
  it("dar deletes the subtree, dir its contents", function()
    eq({ "* A", "** D", "* E" }, (run(outline, { 2, 0 }, "dar")))
    eq({ "* A", "** B", "** D", "* E" }, (run(outline, { 2, 0 }, "dir")))
  end)

  it("ah / ih stop at the first child", function()
    local lines, reg = run(outline, { 3, 0 }, "yah")
    eq(outline, lines)
    eq("** B\nb text\n", reg)
    eq({ "* A", "** B", "*** C", "c text", "** D", "* E" }, (run(outline, { 3, 0 }, "dih")))
  end)

  it("a count selects an ancestor, before or after the operator", function()
    eq({ "* A", "** D", "* E" }, (run(outline, { 5, 0 }, "d2ar")))
    eq({ "* A", "** D", "* E" }, (run(outline, { 5, 0 }, "2dar")))
    eq({ "* E" }, (run(outline, { 5, 0 }, "d3ar")))
    -- no ancestor that far up: nothing happens
    eq(outline, (run(outline, { 5, 0 }, "d9ar")))
  end)

  it("typed again in Visual mode, grows to the parent", function()
    eq({ "V", 4, 1, 5, 1 }, selection(outline, { 5, 0 }, "Var"))
    eq({ "V", 2, 1, 5, 1 }, selection(outline, { 5, 0 }, "varar"))
    eq({ "V", 1, 1, 6, 1 }, selection(outline, { 5, 0 }, "vararar"))
  end)

  it("outside any headline does nothing", function()
    eq({ "text", "* A" }, (run({ "text", "* A" }, { 1, 0 }, "dar")))
  end)

  it(". repeats the operator with the object", function()
    local buf = org_buffer({ "* A", "a", "* B", "b", "* C", "c" }, { 1, 0 })
    keys("dar")
    keys(".")
    eq({ "* C", "c" }, buf_lines(buf))
    keys("u")
    eq({ "* B", "b", "* C", "c" }, buf_lines(buf))
  end)
end)

describe("text objects: element", function()
  local doc = { "* H", "#+name: x", "#+begin_src lua", "print(1)", "print(2)", "#+end_src", "", "para", "graph" }

  it("ie is the contents of a block, ae the block with its keywords and blanks", function()
    eq({ "* H", "#+name: x", "#+begin_src lua", "#+end_src", "", "para", "graph" }, (run(doc, { 4, 0 }, "die")))
    eq({ "* H", "para", "graph" }, (run(doc, { 4, 0 }, "dae")))
    eq({ "* H", "para", "graph" }, (run(doc, { 3, 0 }, "dae")))
  end)

  it("on a paragraph", function()
    local _, reg = run(doc, { 9, 0 }, "yie")
    eq("para\ngraph\n", reg)
  end)

  it("drawer contents", function()
    local lines = { "* H", ":LOGBOOK:", "- note", ":END:", "after" }
    eq({ "* H", ":LOGBOOK:", ":END:", "after" }, (run(lines, { 3, 0 }, "die")))
  end)

  it("a count or a second ae selects the enclosing element", function()
    local lines = { "* H", "#+begin_quote", "inside", "#+end_quote", "after" }
    eq({ "* H", "after" }, (run(lines, { 3, 0 }, "d2ae")))
    eq({ "V", 2, 1, 4, 1 }, selection(lines, { 3, 0 }, "vaeae"))
  end)

  it("an empty block has no inner element; a headline no element", function()
    local lines = { "* H", "#+begin_src", "#+end_src" }
    eq(lines, (run(lines, { 2, 0 }, "die")))
    eq(lines, (run(lines, { 1, 0 }, "dae")))
  end)
end)

describe("text objects: list item", function()
  local list = { "- [ ] one", "  more", "  - sub", "", "- two" }

  it("i- is the item's text after bullet and checkbox, without children", function()
    local lines, reg = run(list, { 1, 0 }, "di-")
    eq({ "- [ ] ", "  - sub", "", "- two" }, lines)
    eq("one\n  more", reg)
    eq({ "- [ ] ONE", "  - sub", "", "- two" }, (run(list, { 2, 0 }, "ci-ONE<Esc>")))
  end)

  it("a- is the item with its children and the blanks before the next item", function()
    eq({ "- two" }, (run(list, { 1, 3 }, "da-")))
    eq({ "- [ ] one", "  more", "", "- two" }, (run(list, { 3, 4 }, "da-")))
  end)

  it("a count selects a parent item", function()
    eq({ "- two" }, (run(list, { 3, 4 }, "d2a-")))
    eq({ "V", 1, 1, 4, 1 }, selection(list, { 3, 4 }, "va-a-"))
  end)

  it("outside a list does nothing", function()
    eq({ "text" }, (run({ "text" }, { 1, 0 }, "da-")))
  end)
end)

describe("text objects: table", function()
  local t = { "| a  | bb |", "|----+----|", "| 1  | 22 |" }

  it("ic is the field's text, ac the field with a separator", function()
    local lines, reg = run(t, { 1, 7 }, "dic")
    eq({ "| a  |  |", "|----+----|", "| 1  | 22 |" }, lines)
    eq("bb", reg)
    eq({ "| bb |", "|----+----|", "| 1  | 22 |" }, (run(t, { 1, 2 }, "dac")))
    eq({ "| a  |", "|----+----|", "| 1  | 22 |" }, (run(t, { 1, 7 }, "dac")))
    -- (the table is realigned on leaving Insert mode)
    eq({ "| a | xy |", "|---+----|", "| 1 | 22 |" }, (run(t, { 1, 7 }, "cicxy<Esc>")))
  end)

  it("vic selects the cell, an empty one its blanks", function()
    eq({ "v", 1, 8, 1, 9 }, selection(t, { 1, 7 }, "vic"))
    eq({ "v", 1, 2, 1, 5 }, selection({ "|    | x |" }, { 1, 2 }, "vic"))
  end)

  it("no cell on a rule or outside a table", function()
    eq(t, (run(t, { 2, 2 }, "dic")))
    eq({ "text" }, (run({ "text" }, { 1, 0 }, "dic")))
  end)

  it("iR is the row between its outer bars, aR the line ([count] lines)", function()
    local _, reg = run(t, { 1, 2 }, "yiR")
    eq(" a  | bb ", reg)
    eq({ "|----+----|", "| 1  | 22 |" }, (run(t, { 1, 2 }, "daR")))
    eq({ "| 1  | 22 |" }, (run(t, { 1, 2 }, "d2aR")))
    eq({ "| 1  | 22 |" }, (run(t, { 1, 2 }, "2daR")))
  end)

  it("iC / aC: the column as a block", function()
    local lines, reg, regtype = run(t, { 3, 7 }, "yiC")
    eq(t, lines)
    eq(" bb \n----\n 22 ", reg)
    eq("\0224", regtype)
    eq({ "| bb |", "|----|", "| 22 |" }, (run(t, { 1, 2 }, "daC")))
    eq({ "| a  |", "|----|", "| 1  |" }, (run(t, { 3, 7 }, "daC")))
  end)

  it("iC wants an aligned table", function()
    local bad = { "| a | bb |", "| 1 | 2 |" }
    eq(bad, (run(bad, { 1, 6 }, "diC")))
  end)

  it(". repeats a cell deletion in the next row", function()
    local buf = org_buffer({ "| a | b |", "| c | d |" }, { 1, 6 })
    keys("dic")
    keys("j.")
    eq({ "| a |  |", "| c |  |" }, buf_lines(buf))
  end)
end)

describe("text objects: link and timestamp", function()
  local line = { "see [[https://x.org][the site]] now and <2026-10-04 Sun 10:00>--<2026-10-05 Mon> ok" }

  it("iL is the description, aL the link and the blanks after it", function()
    local lines, reg = run(line, { 1, 0 }, "diL")
    eq("the site", reg)
    eq("see [[https://x.org][]] now and <2026-10-04 Sun 10:00>--<2026-10-05 Mon> ok", lines[1])
    lines, reg = run(line, { 1, 10 }, "daL")
    eq("[[https://x.org][the site]] ", reg)
    eq("see now and <2026-10-04 Sun 10:00>--<2026-10-05 Mon> ok", lines[1])
  end)

  it("iL without a description is the target", function()
    local _, reg = run({ "a [[file:x.org]] b" }, { 1, 5 }, "yiL")
    eq("file:x.org", reg)
    _, reg = run({ "a <https://x.org> b" }, { 1, 5 }, "yiL")
    eq("https://x.org", reg)
    _, reg = run({ "a https://x.org b" }, { 1, 5 }, "yaL")
    eq("https://x.org ", reg)
  end)

  it("id is the timestamp's text, ad the timestamp or range", function()
    local _, reg = run(line, { 1, 45 }, "yid")
    eq("2026-10-04 Sun 10:00>--<2026-10-05 Mon", reg)
    local lines
    lines, reg = run(line, { 1, 45 }, "dad")
    eq("<2026-10-04 Sun 10:00>--<2026-10-05 Mon> ", reg)
    eq("see [[https://x.org][the site]] now and ok", lines[1])
    _, reg = run({ "x <2026-10-04 Sun>" }, { 1, 0 }, "yid")
    eq("2026-10-04 Sun", reg)
  end)

  it("ad at the end of a line takes the blanks before it", function()
    eq({ "x" }, (run({ "x <2026-10-04 Sun>" }, { 1, 4 }, "dad")))
  end)

  it("nothing after the cursor: nothing happens", function()
    eq({ "<2026-10-04 Sun> x" }, (run({ "<2026-10-04 Sun> x" }, { 1, 17 }, "did")))
  end)
end)

describe("text objects: configuration", function()
  it("false removes one; another key works", function()
    local maps = require("org.config").opts.mappings
    local saved = maps.text_objects
    maps.text_objects = vim.tbl_extend("force", saved, { inner_cell = false, around_link = "ak" })
    local okay, err = pcall(function()
      org_buffer({ "| a |" }, { 1, 2 })
      eq("", vim.fn.maparg("ic", "o"))
      eq("", vim.fn.maparg("aL", "o"))
      eq("org: around link", vim.fn.maparg("ak", "o", false, true).desc)
      eq("org: inner timestamp", vim.fn.maparg("id", "x", false, true).desc)
    end)
    maps.text_objects = saved
    assert(okay, err)
  end)

  it("text_objects = false maps none", function()
    local maps = require("org.config").opts.mappings
    local saved = maps.text_objects
    maps.text_objects = false
    local okay, err = pcall(function()
      org_buffer({ "* A" }, { 1, 0 })
      eq("", vim.fn.maparg("ar", "o"))
      eq("", vim.fn.maparg("ic", "x"))
    end)
    maps.text_objects = saved
    assert(okay, err)
  end)
end)
