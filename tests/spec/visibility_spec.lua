local fold = require("org.fold")
local config = require("org.config")

local function keys(k)
  vim.api.nvim_feedkeys(vim.keycode(k), "xt", false)
end

local function closed(lnum)
  return vim.fn.foldclosed(lnum) ~= -1
end

describe("visibility: startup", function()
  it("#+STARTUP: show2levels shows two levels of headlines", function()
    org_buffer({ "#+STARTUP: show2levels", "* A", "** B", "*** C", "c body", "* D", "d body" }, { 1, 0 })
    fold.apply_startup(0)
    eq(false, closed(2))
    eq(true, closed(3)) -- ** B visible, but folded
    eq(3, vim.fn.foldclosed(3))
    eq(6, vim.fn.foldclosed(6))
  end)

  it("hideblocks folds blocks, nohidedrawers keeps drawers open", function()
    org_buffer({
      "#+STARTUP: showall hideblocks nohidedrawers",
      "* A",
      ":LOGBOOK:",
      "- note",
      ":END:",
      "#+begin_src lua",
      "print(1)",
      "#+end_src",
    }, { 1, 0 })
    fold.apply_startup(0)
    eq(false, closed(3))
    eq(6, vim.fn.foldclosed(6))
  end)

  it("applies VISIBILITY properties", function()
    org_buffer({
      "* A",
      ":PROPERTIES:",
      ":VISIBILITY: children",
      ":END:",
      "a body",
      "** B",
      "b body",
      "* C",
      ":PROPERTIES:",
      ":VISIBILITY: folded",
      ":END:",
      "c body",
    }, { 1, 0 })
    config.opts.startup_folded = "showall"
    fold.apply_startup(0)
    config.opts.startup_folded = "overview"
    eq(false, closed(1))
    eq(false, closed(5)) -- body of A visible
    eq(6, vim.fn.foldclosed(6)) -- child folded
    eq(8, vim.fn.foldclosed(8))
  end)

  it("keeps archived subtrees folded in SHOW ALL", function()
    org_buffer({ "* A", "a body", "* Old :ARCHIVE:", "old body", "* B", "b body" }, { 1, 0 })
    fold.overview()
    vim.b.org_global_cycle = "content"
    fold.global_cycle() -- show all
    eq(false, closed(2))
    eq(3, vim.fn.foldclosed(3))
    eq(false, closed(6))
  end)
end)

describe("visibility: cycling", function()
  it("archived children stay closed, force_cycle_archived opens them", function()
    org_buffer({ "* A", "** Kept", "kept body", "** Old :ARCHIVE:", "old body" }, { 1, 0 })
    fold.overview()
    fold.cycle() -- children
    eq(4, vim.fn.foldclosed(4))
    fold.cycle() -- subtree
    eq(false, closed(3))
    eq(4, vim.fn.foldclosed(4))
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    fold.cycle()
    eq(4, vim.fn.foldclosed(4))
    fold.force_cycle_archived()
    eq(false, closed(4))
  end)

  it("an archived-only subtree does not get stuck", function()
    org_buffer({ "* A", "** Old :ARCHIVE:", "old body" }, { 1, 0 })
    fold.overview()
    fold.cycle() -- children
    eq(false, closed(1))
    fold.cycle() -- folded again
    eq(1, vim.fn.foldclosed(1))
  end)

  it("16<Tab> restores startup visibility, 64<Tab> shows everything", function()
    org_buffer({ "* A", ":PROPERTIES:", ":X: 1", ":END:", "body", "* B", "b" }, { 1, 0 })
    keys("64<Tab>")
    eq(false, closed(1))
    eq(false, closed(2))
    keys("16<Tab>")
    eq(1, vim.fn.foldclosed(1))
    eq(6, vim.fn.foldclosed(6))
  end)

  it("N<Tab> shows the subtree of the level-N ancestor", function()
    org_buffer({ "* A", "** B", "*** C", "c body", "** D", "d body" }, { 3, 0 })
    fold.overview()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    keys("1<Tab>")
    eq(false, closed(1))
    eq(false, closed(4))
    eq(false, closed(6))
  end)
end)
