-- Structure, visibility and display features ported from Emacs Org 9.8.
local fold = require("org.fold")
local config = require("org.config")

local function keys(k)
  vim.api.nvim_feedkeys(vim.keycode(k), "xt", false)
end

local function silence(body)
  local notify = vim.notify
  vim.notify = function() end
  local ok_, err = pcall(body)
  vim.notify = notify
  if not ok_ then
    error(err, 0)
  end
end

--- The lines a reader sees: closed folds show their first line, hidden
--- lines nothing.
local function visible_lines()
  local out = {}
  local n = vim.api.nvim_buf_line_count(0)
  local l = 1
  while l <= n do
    local fc = vim.fn.foldclosed(l)
    if fc ~= -1 then
      if not fold.is_concealed(0, l) then
        out[#out + 1] = vim.fn.getline(l) .. " ..."
      end
      l = vim.fn.foldclosedend(l) + 1
    else
      if not fold.is_concealed(0, l) then
        out[#out + 1] = vim.fn.getline(l)
      end
      l = l + 1
    end
  end
  return out
end

local tree = {
  "* A",
  "a body",
  "** B",
  "b body",
  "*** B1",
  "b1 body match",
  "** C",
  "c body",
  "* D",
  "d body",
}

describe("visibility: Emacs views with hidden lines", function()
  if not fold.conceal_supported then
    return
  end

  it("CONTENTS shows headlines without their text", function()
    org_buffer(tree, { 1, 0 })
    fold.content()
    eq({ "* A", "** B", "*** B1 ...", "** C ...", "* D ..." }, visible_lines())
  end)

  it("show2levels shows two levels of headlines", function()
    org_buffer(vim.list_extend({ "#+STARTUP: show2levels" }, vim.deepcopy(tree)), { 1, 0 })
    fold.apply_startup(0)
    eq({ "#+STARTUP: show2levels", "* A", "** B ...", "** C ...", "* D ..." }, visible_lines())
  end)

  it("show_children from a folded entry keeps its text hidden", function()
    org_buffer(tree, { 1, 0 })
    fold.overview()
    fold.show_children()
    eq({ "* A", "** B ...", "** C ...", "* D ..." }, visible_lines())
    fold.overview()
    fold.show_branches()
    eq({ "* A", "** B", "*** B1 ...", "** C ...", "* D ..." }, visible_lines())
  end)

  it("sparse trees show matches, their ancestors and the matched entries only", function()
    org_buffer(tree, { 1, 0 })
    silence(function()
      require("org.agenda.sparse").regexp("match")
    end)
    eq({ "* A", "** B", "*** B1", "b1 body match", "* D ..." }, visible_lines())
  end)

  it("reveal shows the lineage", function()
    org_buffer(tree, { 6, 0 })
    fold.overview()
    fold.reveal(false)
    eq({ "* A", "** B", "*** B1", "b1 body match", "** C ...", "* D ..." }, visible_lines())
  end)

  it("TAB on a CONTENTS headline folds it, then shows its text and children", function()
    org_buffer(tree, { 1, 0 })
    fold.content()
    fold.cycle()
    eq({ "* A ...", "* D ..." }, visible_lines())
    fold.cycle()
    eq({ "* A", "a body", "** B ...", "** C ...", "* D ..." }, visible_lines())
  end)

  it("line motions skip hidden lines", function()
    org_buffer(tree, { 1, 0 })
    fold.content()
    keys("j")
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
  end)
end)

describe("visibility: plain lists and TAB", function()
  it("folds list items with children or more lines", function()
    local levels = fold.compute({ "* H", "- a", "  - b", "  more", "- c" })
    eq({ ">1", ">2", 2, 2, 1 }, levels)
  end)

  it("TAB cycles an item: folded, children, subtree", function()
    org_buffer({ "* H", "- a", "  - b", "    b text", "  more", "- c" }, { 2, 0 })
    fold.show_all()
    fold.cycle()
    eq(2, vim.fn.foldclosed(2))
    fold.cycle()
    eq(-1, vim.fn.foldclosed(2))
    eq(3, vim.fn.foldclosed(3))
    fold.cycle()
    eq(-1, vim.fn.foldclosed(3))
  end)

  it("keeps a blank line visible before a headline (cycle_separator_lines)", function()
    local levels = fold.compute({ "* A", "x", "", "", "* B" })
    eq({ ">1", 1, 1, 0, ">1" }, levels)
    levels = fold.compute({ "* A", "x", "", "* B" })
    eq({ ">1", 1, 1, ">1" }, levels)
  end)

  it("TAB on text indents it like org-indent-line", function()
    local buf = org_buffer({ "* H", "  para", "text" }, { 3, 0 })
    fold.show_all()
    fold.cycle()
    eq("  text", vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
  end)
end)

describe("structure: headline syntax", function()
  local parser = require("org.parser")
  it("stars need a space (org-outline-regexp)", function()
    eq(nil, parser.headline_level("**"))
    eq(nil, parser.headline_level("*\tx"))
    eq(2, parser.headline_level("** x"))
    eq(1, parser.headline_level("* "))
    local file = parser.parse({ "* A", "**", "text" })
    eq(1, #file.headlines)
    eq(3, file.headlines[1].end_line)
  end)
end)

describe("structure: emphasis highlighting", function()
  local function group(l, c)
    return vim.fn.synIDattr(vim.fn.synID(l, c, 1), "name"):lower()
  end
  it("spans one newline, not two, and not after [", function()
    org_buffer({ "x *multi", "line* y", "[*x*] z", "x *a", "b", "c* d", "*b /it/ c*" })
    vim.cmd("syntax sync fromstart")
    eq("orgbold", group(1, 5))
    eq("orgbold", group(2, 2))
    eq("", group(3, 3))
    eq("", group(4, 4))
    eq("orgitalic", group(7, 5))
  end)
end)

describe("display: pretty entities, scripts, numbering", function()
  local deco = require("org.ui.decorations")
  local function conceals(rows, row)
    local out = {}
    for _, m in ipairs(rows[row] or {}) do
      if m[2].conceal and m[2].conceal ~= "" then
        out[#out + 1] = m[2].conceal
      end
    end
    table.sort(out)
    return table.concat(out, "|")
  end
  local function virt(rows, row)
    for _, m in ipairs(rows[row] or {}) do
      if m[2].virt_text and m[2].virt_text_pos == "inline" then
        return m[2].virt_text[1][1]
      end
    end
  end

  it("shows entities and sub/superscripts with #+STARTUP: entitiespretty", function()
    local buf = org_buffer({ "#+STARTUP: entitiespretty", "\\alpha{} x^2 a_{ij} \\frac12 =\\beta=" })
    local rows = deco.compute(buf)
    eq("²|½|α|ᵢ|ⱼ", conceals(rows, 1))
  end)

  it("toggle_pretty_entities switches the buffer", function()
    local buf = org_buffer({ "\\alpha" })
    silence(function()
      deco.toggle_pretty_entities()
    end)
    eq("α", conceals(deco.compute(buf), 0))
    silence(function()
      deco.toggle_pretty_entities()
    end)
    eq("", conceals(deco.compute(buf), 0))
  end)

  it("numbers headlines like org-num-mode", function()
    local buf = org_buffer({ "#+STARTUP: num", "* A", "** B", "*** C", "* D", "*** E" })
    local rows = deco.compute(buf)
    eq("1 ", virt(rows, 1))
    eq("1.1 ", virt(rows, 2))
    eq("1.1.1 ", virt(rows, 3))
    eq("2 ", virt(rows, 4))
    eq("2.0.1 ", virt(rows, 5))
  end)

  it("skips numbering by tag and commented subtrees when asked", function()
    local ui = config.opts.ui
    ui.num_skip_tags = { "x" }
    ui.num_skip_commented = true
    local buf = org_buffer({ "#+STARTUP: num", "* A :x:", "** A1", "* COMMENT B", "* C" })
    local rows = deco.compute(buf)
    ui.num_skip_tags = {}
    ui.num_skip_commented = false
    eq(nil, virt(rows, 1))
    eq(nil, virt(rows, 2))
    eq(nil, virt(rows, 3))
    eq("1 ", virt(rows, 4))
  end)

  it("indents text of a level-n entry to column 2n (org-indent)", function()
    local buf = org_buffer({ "#+STARTUP: indent", "** A", "text" })
    local rows = deco.compute(buf)
    eq(" ", virt(rows, 1))
    eq("    ", virt(rows, 2))
  end)
end)

describe("inline tasks", function()
  with_config({ inlinetask_min_level = 15 })
  local stars = string.rep("*", 15)
  local lines = { "* A", "text", stars .. " TODO task", "task body", stars .. " END", "more text", "* B" }

  it("are not entries of their own", function()
    local parser = require("org.parser")
    local file = parser.parse(lines)
    eq(3, #file.headlines)
    eq(true, file.headlines[2].inlinetask)
    eq(0, #file.headlines[1].children)
    eq(6, file.headlines[1].body_end)
    eq("A", file:headline_at(6).title)
    eq("task", file:headline_at(4).title)
  end)

  it("fold to their END line", function()
    local levels = fold.compute(lines)
    eq({ ">1", 1, ">2", 2, "<2", 1, ">1" }, levels)
  end)

  it("promote and demote with their END line, not below the minimum", function()
    local buf = org_buffer(vim.deepcopy(lines), { 3, 0 })
    require("org.structure").demote_heading()
    eq(string.rep("*", 16) .. " TODO task", buf_lines(buf)[3])
    eq(string.rep("*", 16) .. " END", buf_lines(buf)[5])
    silence(function()
      require("org.structure").promote_heading()
      require("org.structure").promote_heading()
    end)
    eq(stars .. " TODO task", buf_lines(buf)[3])
  end)

  it("C-c C-x t inserts one", function()
    local buf = org_buffer({ "* A", "text" }, { 2, 0 })
    require("org.inlinetask").insert()
    vim.cmd("stopinsert")
    eq({ "* A", "text", stars .. " ", stars .. " END" }, buf_lines(buf))
  end)
end)

describe("speed commands and org-tempo", function()
  it("run a command for a letter typed at the start of a headline", function()
    config.opts.use_speed_commands = true
    local buf = org_buffer({ "* A", "** B", "* C" }, { 1, 0 })
    require("org.speed").attach(buf)
    keys("in")
    vim.wait(50, function()
      return vim.api.nvim_win_get_cursor(0)[1] == 2
    end)
    keys("<Esc>")
    config.opts.use_speed_commands = false
    eq({ "* A", "** B", "* C" }, buf_lines(buf))
    eq(2, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("expands <s and <q with TAB in Insert mode", function()
    config.opts.tempo = true
    local buf = org_buffer({ "" }, { 1, 0 })
    keys("i<s<Tab>sh<Esc>")
    eq({ "#+begin_src sh", "", "#+end_src" }, buf_lines(buf))
    buf = org_buffer({ "" }, { 1, 0 })
    keys("i<q<Tab>x<Esc>")
    eq({ "#+begin_quote", "x", "#+end_quote" }, buf_lines(buf))
    buf = org_buffer({ "" }, { 1, 0 })
    keys("i<L<Tab>x<Esc>")
    eq({ "#+latex: x" }, buf_lines(buf))
    config.opts.tempo = false
  end)
end)

describe("structure: odd levels and sorting", function()
  it("promotes by two stars with #+STARTUP: odd", function()
    local buf = org_buffer({ "#+STARTUP: odd", "* A", "*** B" }, { 3, 0 })
    require("org.structure").promote_heading()
    eq("* B", buf_lines(buf)[3])
  end)

  it("sorts by a key function from sort_functions", function()
    config.opts.sort_functions = {
      by_len = function(h)
        return #h.title
      end,
    }
    local buf = org_buffer({ "* P", "** ccc", "** a", "** bb" }, { 1, 0 })
    local utils, ui = require("org.utils"), require("org.ui")
    local input, menu = utils.input, ui.menu
    local answers = { "by_len", "" }
    utils.input = function()
      return table.remove(answers, 1)
    end
    ui.menu = function(o)
      for _, i in ipairs(o.items) do
        if i.key == "f" then
          return i.value
        end
      end
    end
    silence(function()
      require("org.structure").sort()
    end)
    utils.input, ui.menu = input, menu
    config.opts.sort_functions = {}
    eq({ "* P", "** a", "** bb", "** ccc" }, buf_lines(buf))
  end)
end)

describe("lists: radio buttons and fixed width", function()
  it("a radio list keeps one box checked", function()
    local buf = org_buffer({ "#+attr_org: :radio t", "- [X] a", "- [ ] b" }, { 3, 2 })
    keys("<C-c><C-c>")
    eq({ "#+attr_org: :radio t", "- [ ] a", "- [X] b" }, buf_lines(buf))
  end)

  it("C-c : toggles the fixed-width marker", function()
    local buf = org_buffer({ "* H", "some text" }, { 2, 0 })
    keys("<C-c>:")
    eq(": some text", buf_lines(buf)[2])
    keys("<C-c>:")
    eq("some text", buf_lines(buf)[2])
  end)
end)
