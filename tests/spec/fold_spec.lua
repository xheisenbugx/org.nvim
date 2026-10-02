local fold = require("org.fold")

describe("fold: levels", function()
  it("computes headline, drawer and block levels", function()
    local levels = fold.compute({
      "#+TITLE: x",
      "* A",
      ":PROPERTIES:",
      ":ID: 1",
      ":END:",
      "#+begin_src lua",
      "print(1)",
      "#+end_src",
      "** B",
      "text",
      "* C",
      ":NOTCLOSED:",
      "x",
    })
    eq({ 0, ">1", ">2", 2, "<2", ">2", 2, "<2", ">2", 2, ">1", 1, 1 }, levels)
  end)
end)

describe("fold: cycling", function()
  local lines = {
    "* A",
    "body",
    "** B",
    "b body",
    "** C",
    "c body",
    "* D",
    "d body",
  }
  it("cycles folded -> children -> subtree -> folded", function()
    local buf = org_buffer(lines, { 1, 0 })
    fold.setup_buffer(buf)
    fold.overview()
    eq(1, vim.fn.foldclosed(1))
    fold.cycle()
    eq(-1, vim.fn.foldclosed(1))
    eq(3, vim.fn.foldclosed(3))
    eq(5, vim.fn.foldclosed(5))
    fold.cycle()
    eq(-1, vim.fn.foldclosed(3))
    eq(-1, vim.fn.foldclosed(5))
    fold.cycle()
    eq(1, vim.fn.foldclosed(1))
  end)

  -- Emacs org-cycle-emulate-tab: TAB in body text indents the line, or
  -- with it off cycles the entry
  it("indents body text, or cycles the entry without cycle_emulate_tab", function()
    local buf = org_buffer({ "* A", "- item", "  more", "   x" }, { 4, 0 })
    fold.setup_buffer(buf)
    fold.show_all()
    fold.cycle()
    eq("  x", buf_lines(buf)[4])
    local config = require("org.config")
    config.opts.cycle_emulate_tab = false
    buf = org_buffer(lines, { 2, 0 })
    fold.setup_buffer(buf)
    fold.show_all()
    fold.cycle()
    config.opts.cycle_emulate_tab = true
    eq(1, vim.fn.foldclosed(1))
  end)

  it("global cycle", function()
    local buf = org_buffer(lines, { 1, 0 })
    fold.setup_buffer(buf)
    vim.b.org_global_cycle = "showall"
    fold.global_cycle()
    eq(1, vim.fn.foldclosed(1))
    fold.global_cycle() -- contents
    eq(-1, vim.fn.foldclosed(1))
    eq(3, vim.fn.foldclosed(3))
    fold.global_cycle() -- show all
    eq(-1, vim.fn.foldclosed(3))
  end)

  -- org-cycle-internal-global: CONTENTS and SHOW ALL only follow the
  -- previous S-TAB; after any other command S-TAB shows the OVERVIEW
  it("global cycle starts again from OVERVIEW after another command", function()
    local buf = org_buffer(lines, { 4, 0 })
    fold.setup_buffer(buf)
    fold.show_all()
    fold.global_cycle() -- overview: the cursor goes to the headline it shows on
    eq(1, vim.fn.foldclosed(1))
    eq(1, vim.api.nvim_win_get_cursor(0)[1])
    fold.global_cycle() -- contents
    eq(-1, vim.fn.foldclosed(1))
    eq(3, vim.fn.foldclosed(3))
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    fold.global_cycle() -- overview again, not show all
    eq(1, vim.fn.foldclosed(1))
    fold.global_cycle() -- contents
    vim.cmd("normal! 3Gzo")
    fold.global_cycle() -- the cursor moved: overview
    eq(1, vim.fn.foldclosed(1))
  end)

  it("<S-Tab> cycles OVERVIEW, CONTENTS, SHOW ALL when pressed in a row", function()
    local buf = org_buffer(lines, { 4, 0 })
    fold.setup_buffer(buf)
    fold.show_all()
    local function stab()
      vim.api.nvim_feedkeys(vim.keycode("<S-Tab>"), "xt", false)
    end
    stab()
    eq(1, vim.fn.foldclosed(1))
    stab()
    eq(-1, vim.fn.foldclosed(1))
    eq(3, vim.fn.foldclosed(3))
    stab()
    eq(-1, vim.fn.foldclosed(3))
    eq(-1, vim.fn.foldclosed(4))
  end)
end)

-- org-cycle-include-plain-lists 'integrate (Emacs 9.8.10: CHILDREN shows
-- the top-level items folded, then SUBTREE, then FOLDED; with `t` a
-- headline with only a list goes FOLDED -> SUBTREE (NO CHILDREN))
describe("fold: cycle_include_plain_lists = integrate", function()
  with_config({ cycle_include_plain_lists = "integrate" })
  it("cycles items as children of the headline", function()
    local buf = org_buffer({ "* A", "- one", "  more", "- two", "  more2", "* B" }, { 1, 0 })
    fold.setup_buffer(buf)
    fold.overview()
    eq(1, vim.fn.foldclosed(1))
    fold.cycle()
    eq(-1, vim.fn.foldclosed(1))
    eq(2, vim.fn.foldclosed(2))
    eq(4, vim.fn.foldclosed(4))
    fold.cycle()
    eq(-1, vim.fn.foldclosed(2))
    eq(-1, vim.fn.foldclosed(4))
    fold.cycle()
    eq(1, vim.fn.foldclosed(1))
  end)
end)

describe("fold: cycle_include_plain_lists = true", function()
  it("shows a headline with only a list as a subtree", function()
    local buf = org_buffer({ "* A", "- one", "  more", "- two", "  more2", "* B" }, { 1, 0 })
    fold.setup_buffer(buf)
    fold.overview()
    fold.cycle()
    eq(-1, vim.fn.foldclosed(1))
    eq(-1, vim.fn.foldclosed(2))
    fold.cycle()
    eq(1, vim.fn.foldclosed(1))
  end)
end)
