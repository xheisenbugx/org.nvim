-- Emacs structure-editing parity: lists, footnotes, tags, properties,
-- sparse trees.
local utils = require("org.utils")
local ui = require("org.ui")
local config = require("org.config")
vim.g.org_test = true

local function keys(k)
  vim.api.nvim_feedkeys(vim.keycode(k), "xt", false)
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

local function cursor_line()
  return vim.api.nvim_win_get_cursor(0)[1]
end

describe("lists: item motion", function()
  it("<S-Down>/<S-Up> move between items of the same level", function()
    org_buffer({ "* H", "- a", "  - a1", "- b", "  more b", "- c" }, { 2, 0 })
    keys("<S-Down>")
    eq(4, cursor_line())
    keys("<S-Down>")
    eq(6, cursor_line())
    keys("<S-Up>")
    eq(4, cursor_line())
  end)

  it("stays on the last item", function()
    local buf = org_buffer({ "- a", "- b" }, { 2, 0 })
    with_stub(vim, "notify", function() end, function()
      require("org.lists").next_item()
    end)
    eq(2, cursor_line())
    eq({ "- a", "- b" }, buf_lines(buf))
  end)
end)

describe("lists: checkboxes", function()
  it("toggles every item of a Visual selection", function()
    local buf = org_buffer({ "* H [0/3]", "- [ ] a", "- [ ] b", "- [X] c" }, { 2, 0 })
    keys("Vj<C-Space>")
    eq({ "* H [3/3]", "- [X] a", "- [X] b", "- [X] c" }, buf_lines(buf))
  end)

  it("adds checkboxes to a selection without any", function()
    local buf = org_buffer({ "- a", "- b" }, { 1, 0 })
    keys("Vj<C-Space>")
    eq({ "- [ ] a", "- [ ] b" }, buf_lines(buf))
  end)

  it("4<C-Space> removes the checkbox, 16<C-Space> sets [-]", function()
    local buf = org_buffer({ "- [X] a", "- b" }, { 1, 0 })
    keys("4<C-Space>")
    eq("- a", buf_lines(buf)[1])
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    keys("16<C-Space>")
    eq("- [-] b", buf_lines(buf)[2])
  end)
end)

describe("structure: drag line and region promotion", function()
  it("<M-K>/<M-J> drag the line outside tables", function()
    local buf = org_buffer({ "* H", "one", "two", "three" }, { 2, 1 })
    keys("<M-J>")
    eq({ "* H", "two", "one", "three" }, buf_lines(buf))
    eq({ 3, 1 }, vim.api.nvim_win_get_cursor(0))
    keys("<M-K>")
    eq({ "* H", "one", "two", "three" }, buf_lines(buf))
  end)

  it("<M-l>/<M-h> in Visual mode demote/promote every headline", function()
    local buf = org_buffer({ "* A", "text", "** B", "* C" }, { 1, 0 })
    vim.cmd("normal! zR")
    keys("Vjj<M-l>")
    eq({ "** A", "text", "*** B", "* C" }, buf_lines(buf))
    keys("ggVjj<M-h>")
    eq({ "* A", "text", "** B", "* C" }, buf_lines(buf))
  end)
end)

describe("structure: TAB after creating a heading or item", function()
  it("cycles the level of an empty headline", function()
    local buf = org_buffer({ "* A", "** B", "** " }, { 3, 2 })
    vim.cmd("normal! zR")
    keys("A<Tab>")
    eq("*** ", buf_lines(buf)[3])
    keys("A<Tab>")
    eq("* ", buf_lines(buf)[3])
    keys("A<Tab>")
    eq("** ", buf_lines(buf)[3])
    keys("A<Tab>x")
    eq("*** x", buf_lines(buf)[3])
  end)

  it("keeps TODO keywords while cycling", function()
    local buf = org_buffer({ "* A", "* TODO " }, { 2, 6 })
    keys("A<Tab>")
    eq("** TODO ", buf_lines(buf)[2])
  end)

  it("indents an empty item, then outdents it back", function()
    local buf = org_buffer({ "- a", "- " }, { 2, 1 })
    keys("A<Tab>")
    eq("  - ", buf_lines(buf)[2])
    keys("A<Tab>")
    eq("- ", buf_lines(buf)[2])
  end)

  it("inserts a real tab in normal text and non-empty headlines", function()
    local buf = org_buffer({ "* A", "text" }, { 2, 3 })
    vim.bo[buf].expandtab = false
    keys("A<Tab>")
    eq("text\t", buf_lines(buf)[2])
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    keys("A<Tab>")
    eq("* A\t", buf_lines(buf)[1])
  end)

  it("still moves between table fields", function()
    local buf = org_buffer({ "| a | b |" }, { 1, 2 })
    keys("i<Tab>x")
    eq("| a | xb |", buf_lines(buf)[1])
  end)
end)

describe("structure: sort by checkbox status and clocking time", function()
  it("sorts list items by checkbox (x)", function()
    local buf = org_buffer({ "- [X] a", "- [ ] b", "- [-] c" }, { 1, 0 })
    with_stub(ui, "menu", function(opts)
      for _, it in ipairs(opts.items) do
        if it.key == "x" then
          return it.value
        end
      end
    end, function()
      utils.run(require("org.structure").sort)
    end)
    eq({ "- [ ] b", "- [-] c", "- [X] a" }, buf_lines(buf))
  end)

  it("sorts entries by clocked time (k)", function()
    local buf = org_buffer({
      "* Top",
      "** Long",
      "CLOCK: [2026-01-01 Thu 10:00]--[2026-01-01 Thu 12:00] =>  2:00",
      "** Short",
      "CLOCK: [2026-01-01 Thu 10:00]--[2026-01-01 Thu 10:30] =>  0:30",
    }, { 1, 0 })
    local seen_x
    with_stub(ui, "menu", function(opts)
      for _, it in ipairs(opts.items) do
        seen_x = seen_x or it.key == "x"
        if it.key == "k" then
          return it.value
        end
      end
    end, function()
      utils.run(require("org.structure").sort)
    end)
    eq(false, seen_x)
    eq("** Short", buf_lines(buf)[2])
    eq("** Long", buf_lines(buf)[4])
  end)
end)

describe("tags: region and realign", function()
  it("adds and removes a tag on every headline of a selection", function()
    local tags = require("org.tags")
    local buf = org_buffer({ "* A", "* B :x:", "* C" }, { 1, 0 })
    eq(2, tags.change_tag_in_region(buf, 1, 2, "add", "work"))
    ok(buf_lines(buf)[1]:match(":work:$"))
    ok(buf_lines(buf)[2]:match(":x:work:$"))
    eq("* C", buf_lines(buf)[3])
    eq(1, tags.change_tag_in_region(buf, 1, 3, "remove", "x"))
    ok(buf_lines(buf)[2]:match("^%* B%s+:work:$"))
  end)

  it("Visual <C-c><C-q> prompts add/remove and a tag", function()
    local buf = org_buffer({ "* A", "* B" }, { 1, 0 })
    with_stub(ui, "menu", function()
      return "add"
    end, function()
      with_stub(utils, "input_complete", function()
        return "home"
      end, function()
        with_stub(vim, "notify", function() end, function()
          keys("Vj<C-c><C-q>")
        end)
      end)
    end)
    ok(buf_lines(buf)[1]:match(":home:$"))
    ok(buf_lines(buf)[2]:match(":home:$"))
  end)

  it("a count realigns every headline's tags", function()
    local buf = org_buffer({ "* A :x:", "* B     :y:" }, { 1, 0 })
    with_stub(vim, "notify", function() end, function()
      keys("4<C-c><C-q>")
    end)
    eq(77, vim.fn.strdisplaywidth(buf_lines(buf)[1]))
    eq(77, vim.fn.strdisplaywidth(buf_lines(buf)[2]))
  end)

  it("group markers in #+TAGS are not tags", function()
    org_buffer({ "#+TAGS: [ GTD : Control Persp ] { @home(h) @work(w) }", "* A" }, { 2, 0 })
    local names = {}
    for _, d in ipairs(require("org.files").get_buffer(0):tag_definitions()) do
      if d.name then
        names[#names + 1] = d.name
      end
    end
    eq({ "GTD", "Control", "Persp", "@home", "@work" }, names)
  end)
end)

describe("properties: property lines", function()
  local lines = {
    "* A",
    ":PROPERTIES:",
    ":Status_ALL: new open done",
    ":Status: open",
    ":END:",
  }

  it("<S-Right>/<S-Left> cycle allowed values", function()
    local buf = org_buffer(lines, { 4, 0 })
    keys("<S-Right>")
    eq(":Status:   done", buf_lines(buf)[4])
    keys("<S-Right>")
    eq(":Status:   new", buf_lines(buf)[4])
    keys("<S-Left>")
    eq(":Status:   done", buf_lines(buf)[4])
  end)

  it("<C-c><C-c> on a property line offers set / delete", function()
    local buf = org_buffer(lines, { 4, 0 })
    with_stub(ui, "menu", function()
      return "d"
    end, function()
      keys("<C-c><C-c>")
    end)
    eq({ "* A", ":PROPERTIES:", ":Status_ALL: new open done", ":END:" }, buf_lines(buf))
  end)

  it("deletes a property from every entry", function()
    local buf = org_buffer({
      "* A",
      ":PROPERTIES:",
      ":X: 1",
      ":END:",
      "* B",
      ":PROPERTIES:",
      ":X: 2",
      ":Y: 3",
      ":END:",
    }, { 1, 0 })
    with_stub(vim, "notify", function() end, function()
      eq(2, require("org.properties").delete_property_globally(buf, "X"))
    end)
    eq({ "* A", "* B", ":PROPERTIES:", ":Y: 3", ":END:" }, buf_lines(buf))
  end)
end)

describe("sparse tree", function()
  it("<C-c><C-c> first removes sparse-tree highlights", function()
    local sparse = require("org.agenda.sparse")
    local buf = org_buffer({ "* TODO A :x:", "* B" }, { 2, 0 })
    with_stub(vim, "notify", function() end, function()
      sparse.match("+x")
    end)
    ok(sparse.has_highlights(buf))
    keys("<C-c><C-c>")
    eq(false, sparse.has_highlights(buf))
    eq("* B", buf_lines(buf)[2]) -- no tag prompt happened
  end)

  it("match() respects todo_only", function()
    local sparse = require("org.agenda.sparse")
    org_buffer({ "* TODO A :x:", "* B :x:" }, { 1, 0 })
    with_stub(vim, "notify", function() end, function()
      eq(2, #sparse.match("+x"))
      eq(1, #sparse.match("+x", true))
    end)
  end)
end)

describe("footnotes: maintenance", function()
  local fn = require("org.footnotes")

  it("renumbers fn:N in order of reference", function()
    local buf = org_buffer({ "a[fn:3] b[fn:1] c[fn:3]", "", "* Footnotes", "[fn:1] one", "", "[fn:3] three" })
    fn.renumber(buf)
    eq({ "a[fn:1] b[fn:2] c[fn:1]", "", "* Footnotes", "[fn:2] one", "", "[fn:1] three" }, buf_lines(buf))
  end)

  it("sorts definitions in reference order", function()
    local buf = org_buffer({ "a[fn:b] c[fn:a]", "", "* Footnotes", "[fn:a] A", "", "[fn:b] B", "", "[fn:z] orphan" })
    fn.sort(buf)
    eq({ "a[fn:b] c[fn:a]", "", "* Footnotes", "[fn:b] B", "", "[fn:a] A", "", "[fn:z] orphan" }, buf_lines(buf))
  end)

  it("normalizes inline and named footnotes", function()
    local buf = org_buffer({ "* T", "x[fn:note] y[fn::inline text] z[fn:note]", "", "[fn:note] Named." })
    fn.normalize(buf)
    eq({
      "* T",
      "x[fn:1] y[fn:2] z[fn:1]",
      "",
      "* Footnotes",
      "[fn:1] Named.",
      "",
      "[fn:2] inline text",
    }, buf_lines(buf))
  end)

  it("deletes references and definition", function()
    local buf = org_buffer({ "a[fn:1] b[fn:2]", "", "* Footnotes", "[fn:1] one", "", "[fn:2] two" }, { 1, 3 })
    with_stub(vim, "notify", function() end, function()
      fn.delete(buf)
    end)
    eq({ "a b[fn:2]", "", "* Footnotes", "[fn:2] two" }, buf_lines(buf))
  end)

  it("footnote_action jumps when on a footnote, creates one otherwise", function()
    local buf = org_buffer({ "Text[fn:a] more", "", "[fn:a] Def" }, { 1, 6 })
    fn.footnote_action()
    eq(3, cursor_line())
    vim.api.nvim_win_set_cursor(0, { 1, 14 })
    fn.footnote_action()
    eq("Text[fn:a] more[fn:1]", buf_lines(buf)[1])
  end)

  it("footnote_section = false puts definitions at the end of the section", function()
    config.opts.footnote_section = false
    local buf = org_buffer({ "* A", "Hello", "* B", "x" }, { 2, 4 })
    fn.new_footnote({ no_insert = true })
    config.opts.footnote_section = "Footnotes"
    eq({ "* A", "Hello[fn:1]", "", "[fn:1] ", "", "* B", "x" }, buf_lines(buf))
  end)

  it("offers to create a missing definition", function()
    local buf = org_buffer({ "Text[fn:x] more" }, { 1, 6 })
    with_stub(utils, "confirm", function()
      return true
    end, function()
      fn.action_at_point()
    end)
    eq({ "Text[fn:x] more", "", "* Footnotes", "[fn:x] " }, buf_lines(buf))
    eq(4, cursor_line())
  end)
end)
