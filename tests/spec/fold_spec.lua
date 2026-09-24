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

  it("returns false on body text", function()
    local buf = org_buffer(lines, { 2, 0 })
    fold.setup_buffer(buf)
    fold.show_all()
    eq(false, fold.cycle())
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

end)
