-- Folding and visibility: fold levels, what S-TAB / TAB / C-c TAB show,
-- and the ellipsis after hidden text. Expectations from Emacs Org 9.8.10
-- (batch runs of org-cycle, org-ctrl-c-tab, ... on the same text).
local fold = require("org.fold")

local function visible(lines)
  local out = {}
  for _, l in ipairs(lines) do
    out[#out + 1] = fold.line_visible(l)
  end
  return out
end

--- The texts of the lines shown in the current window.
local function shown()
  local out = {}
  for l = 1, vim.fn.line("$") do
    if fold.line_visible(l) then
      out[#out + 1] = vim.fn.getline(l)
    end
  end
  return out
end

local function screen_row(row)
  local s = {}
  for c = 1, vim.o.columns do
    s[#s + 1] = vim.fn.screenstring(row, c)
  end
  return (table.concat(s):gsub("%s+$", ""))
end

-- redraw, then again once the ellipsis marks are moved
local function draw()
  for _ = 1, 3 do
    vim.cmd("redraw!")
    vim.wait(20)
  end
end

local function quiet(fn)
  local echo = vim.api.nvim_echo
  vim.api.nvim_echo = function() end
  local ok, err = pcall(fn)
  vim.api.nvim_echo = echo
  assert(ok, err)
end

--- TAB on line `lnum`, `n` times in a row.
local function tab(lnum, n)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.w.org_last_cycle = nil
  for _ = 1, n or 1 do
    quiet(fold.cycle)
  end
end

--- S-TAB `n` times in a row.
local function stab(n)
  vim.w.org_last_global = nil
  for _ = 1, n do
    quiet(fold.global_cycle)
  end
end

local function setup(lines, cursor)
  local buf = org_buffer(lines, cursor or { 1, 0 })
  fold.setup_buffer(buf)
  return buf
end

local function levels(buf)
  local out = {}
  vim.api.nvim_buf_call(buf, function()
    for l = 1, vim.api.nvim_buf_line_count(buf) do
      out[l] = vim.fn.foldlevel(l)
    end
  end)
  return out
end

describe("folds after typing in Insert mode", function()
  -- Neovim doesn't update 'foldexpr' folds while in Insert or Replace mode
  it("gives a headline typed in Insert mode its own fold", function()
    local buf = setup({ "* A", "text", "text2", "text3", "* B" })
    fold.show_all()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys("o** N\27", "xt", false)
    eq({ 1, 1, 2, 2, 2, 1 }, levels(buf))
    vim.cmd("3foldclose")
    eq(3, vim.fn.foldclosed(3))
  end)

  it("updates the folds after `r` makes a headline", function()
    local buf = setup({ "* A", "xN", "text", "* B" })
    fold.show_all()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys("r*", "xt", false)
    vim.wait(50, function()
      return vim.fn.foldlevel(2) == 1 and vim.fn.foldclosed(1) == -1 and levels(buf)[3] == 1
    end)
    eq("*N", buf_lines(buf)[2])
    -- "*N" is no headline: the levels stay
    eq({ 1, 1, 1, 1 }, levels(buf))
    vim.api.nvim_feedkeys("a \27", "xt", false)
    eq("* N", buf_lines(buf)[2])
    eq({ 1, 1, 1, 1 }, levels(buf))
    vim.cmd("2foldclose")
    eq(2, vim.fn.foldclosed(2))
  end)
end)

describe("fold levels", function()
  it("follow the outline depth when a level is skipped", function()
    eq(
      { ">1", 1, ">2", 2, ">2", ">3", 3, ">1" },
      (fold.compute({ "* A", "b", "*** C", "c", "*** C2", "**** D", "d", "* E" }))
    )
    -- after a deeper headline, a shallower one is the child of the first
    eq({ ">1", ">2", ">2" }, (fold.compute({ "* A", "*** C", "** B" })))
  end)

  it("stay the same as a full recompute after headline edits", function()
    local buf = setup({ "** X", "x", "**** Y", "y", "*** Z", "z", "** W", "w", "*** V", "* U", "u", "**** T" })
    local rand = 7
    local function rnd(n)
      rand = (rand * 1103515245 + 12345) % 2147483648
      return rand % n + 1
    end
    local snippets = { "*", "**", "***", "****", "text", "", "- item" }
    for step = 1, 300 do
      local n = vim.api.nvim_buf_line_count(buf)
      local at = rnd(n) - 1
      local op = rnd(4)
      local line = vim.api.nvim_buf_get_lines(buf, at, at + 1, false)[1]
      if op == 1 then
        -- add or remove a star
        if line:match("^%*") and rnd(2) == 1 then
          vim.api.nvim_buf_set_text(buf, at, 0, at, 1, {})
        else
          vim.api.nvim_buf_set_text(buf, at, 0, at, 0, { "*" })
        end
      elseif op == 2 then
        local s = snippets[rnd(#snippets)]
        vim.api.nvim_buf_set_lines(buf, at, at, false, { s:match("^%*") and (s .. " H" .. step) or s })
      elseif op == 3 and n > 3 then
        vim.api.nvim_buf_set_lines(buf, at, at + 1, false, {})
      else
        local s = snippets[rnd(#snippets)]
        vim.api.nvim_buf_set_lines(buf, at, at + 1, false, { s:match("^%*") and (s .. " R" .. step) or s })
      end
      local expected = fold.compute(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      local actual = {}
      vim.api.nvim_buf_call(buf, function()
        for l = 1, vim.api.nvim_buf_line_count(buf) do
          actual[l] = fold.foldexpr(l)
        end
      end)
      eq(expected, actual, "step " .. step)
    end
  end)

  it("never fold the blank lines at the end of the file", function()
    eq({ ">1", 1, ">1", 1, 0, 0 }, (fold.compute({ "* A", "a", "* B", "b", "", "  " })))
  end)

  it("don't let a block or LaTeX environment run past a headline into a #+RESULTS fold", function()
    local lines = { "* A", "#+RESULTS:", "#+begin_example", "x", "* B", "body", "#+end_example", "* C" }
    eq(2, require("org.babel.blocks").results_end(lines, 2))
    eq({ ">1", 1, 1, 1, ">1", 1, 1, ">1" }, (fold.compute(lines)))
    local env = { "* A", "#+RESULTS:", "\\begin{eq}", "x", "* B", "\\end{eq}" }
    eq(2, require("org.babel.blocks").results_end(env, 2))
  end)

  it("fold a block inside a drawer and a drawer inside a quote block", function()
    local lines = {
      "* H",
      ":NOTES:",
      "#+begin_src sh",
      "echo hi",
      "#+end_src",
      ":END:",
      "#+begin_quote",
      ":QD:",
      "x",
      ":END:",
      "#+end_quote",
    }
    eq({ ">1", ">2", ">3", 3, "<3", "<2", ">2", ">3", 3, "<3", "<2" }, (fold.compute(lines)))
    -- nothing folds inside a src block
    eq({ ">1", ">2", 2, 2, "<2" }, (fold.compute({ "* H", "#+begin_src org", ":D:", ":END:", "#+end_src" })))
    setup(lines)
    fold.show_all()
    tab(3)
    eq(3, vim.fn.foldclosed(4))
    eq(-1, vim.fn.foldclosed(2))
    tab(8)
    eq(8, vim.fn.foldclosed(9))
    eq(-1, vim.fn.foldclosed(7))
  end)
end)

describe("global cycling", function()
  local skip = { "* A", "body", "*** C", "cbody", "*** C2", "**** D", "d", "* E" }

  it("shows every child under a skipped level (CHILDREN) and every headline (CONTENTS)", function()
    setup(skip)
    stab(1)
    tab(1)
    eq({ "* A", "body", "*** C", "*** C2", "* E" }, shown())
    stab(2)
    eq({ "* A", "*** C", "*** C2", "**** D", "* E" }, shown())
  end)

  it("shows a child under a skipped level after blank lines", function()
    setup({ "* A", "text", "", "", "*** C", "body", "* B" })
    stab(1)
    tab(1)
    eq({ true, true, true, true, true, false, true }, visible({ 1, 2, 3, 4, 5, 6, 7 }))
  end)

  it("leaves blocks and results unfolded after OVERVIEW", function()
    local lines = {
      "#+STARTUP: overview",
      "* A",
      "#+begin_src sh",
      "echo",
      "#+end_src",
      "#+RESULTS:",
      ": out",
      "** B",
      "b",
      "* C",
    }
    setup(lines)
    eq(2, vim.fn.foldclosed(3))
    tab(2, 2)
    eq({ true, true, true, true, true, true }, visible({ 3, 4, 5, 6, 7, 8 }))
    -- the same after S-TAB
    stab(1)
    tab(2, 2)
    eq({ true, true, true, true }, visible({ 4, 5, 6, 7 }))
    -- a block folded by hand stays folded
    tab(3)
    eq(3, vim.fn.foldclosed(4))
    stab(1)
    tab(2, 2)
    eq(3, vim.fn.foldclosed(4))
    eq(true, fold.line_visible(7))
  end)

  it("keeps hideblocks blocks folded", function()
    setup({ "#+STARTUP: overview hideblocks", "* A", "#+begin_src sh", "echo", "#+end_src" })
    -- (no children: SUBTREE)
    tab(2)
    eq(3, vim.fn.foldclosed(4))
  end)

  it("keeps the blank lines at the end of the file visible", function()
    setup({ "#+STARTUP: overview", "* A", "a", "* B", "b", "", "" })
    eq({ false, true, true }, visible({ 5, 6, 7 }))
    tab(4)
    eq({ true, true, true }, visible({ 5, 6, 7 }))
  end)

  it("keeps the separator line before a child headline in CONTENTS", function()
    setup({ "#+STARTUP: content", "* A", "a", "", "", "** B", "b", "", "", "* C" })
    eq({ false, false, true, true, false, false, true, true }, visible({ 3, 4, 5, 6, 7, 8, 9, 10 }))
  end)

  it("shows the headlines with up to N stars for showNlevels", function()
    setup({ "#+STARTUP: show2levels", "* A", "*** C", "c", "* E", "** F", "*** G" })
    eq({ "#+STARTUP: show2levels", "* A", "* E", "** F" }, shown())
  end)
end)

describe("inline tasks in CONTENTS", function()
  with_config({ inlinetask_min_level = 15 })

  it("shows the inline tasks of an entry, folded", function()
    setup({ "* A", "body", "*************** TODO Task", "inl body", "*************** END", "more", "* B", "b" })
    stab(2)
    eq({ "* A", "*************** TODO Task", "* B" }, shown())
  end)
end)

describe("a negative cycle_separator_lines", function()
  with_config({ cycle_separator_lines = -1 })

  it("keeps all the blank lines before a headline visible", function()
    setup({ "* A", "x", "", "", "* B", "y", "", "* C", "z" })
    stab(1)
    eq({ false, true, true, true, false, true, true, false }, visible({ 2, 3, 4, 5, 6, 7, 8, 9 }))
  end)
end)

describe("local cycling and drawers", function()
  it("leaves an open drawer open in CHILDREN and SUBTREE", function()
    setup({ "* A", ":LOGBOOK:", '- State "DONE" from "TODO"', ":END:", "text", "** B", "b", "* C" })
    tab(1)
    eq(1, vim.fn.foldclosed(1))
    tab(1, 2)
    eq({ true, true }, visible({ 3, 4 }))
    tab(1, 3)
    eq({ true, true }, visible({ 3, 4 }))
  end)

  it("keeps a folded drawer folded in SHOW ALL", function()
    setup({ "* A", ":PROPERTIES:", ":X: 1", ":END:", "text" })
    tab(2)
    eq(2, vim.fn.foldclosed(3))
    stab(3)
    eq(2, vim.fn.foldclosed(3))
    eq(true, fold.line_visible(5))
  end)
end)

describe("C-c TAB and C-c C-k", function()
  local tree = { "#+STARTUP: showall", "* A", "a body", "** B", "b body", "*** C", "c", "* D" }

  it("hide the text of the entry first", function()
    setup(tree, { 2, 0 })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    fold.show_children()
    eq({ true, false, true, false, false, false, true }, visible({ 2, 3, 4, 5, 6, 7, 8 }))
    fold.show_all()
    fold.show_branches()
    eq({ true, false, true, false, true, false, true }, visible({ 2, 3, 4, 5, 6, 7, 8 }))
  end)

  it("C-c C-k leaves archived subtrees folded", function()
    setup({ "#+STARTUP: overview", "* P", "p", "** Old :ARCHIVE:", "old", "*** deep", "x", "** New", "n" }, { 2, 0 })
    fold.show_branches()
    eq({ true, false, true, false, false, false, true }, visible({ 2, 3, 4, 5, 6, 7, 8 }))
  end)
end)

describe("VISIBILITY property", function()
  it("content folds a headline without children", function()
    setup({ "#+STARTUP: showall", "* A", ":PROPERTIES:", ":VISIBILITY: content", ":END:", "body text", "* B", "b" })
    eq({ true, false, false, true }, visible({ 2, 3, 6, 7 }))
  end)
end)

describe("hidden lines and the cursor", function()
  it("shows a hidden line a search lands on, even the next one", function()
    local buf = setup({ "* A", "a body", "** A1", "a1 body", "* B", "b body" })
    fold.content()
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    ok(fold.is_concealed(buf, 2))
    vim.fn.search("a body")
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    eq(2, vim.fn.line("."))
    eq(false, fold.is_concealed(buf, 2))
  end)

  it("still skips a hidden line on j", function()
    local buf = setup({ "* A", "a body", "** A1", "a1 body", "* B", "b body" })
    fold.content()
    vim.api.nvim_feedkeys("j", "xt", false)
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    eq(3, vim.fn.line("."))
    ok(fold.is_concealed(buf, 2))
  end)
end)

describe("the fold ellipsis", function()
  before_each(function()
    vim.o.columns, vim.o.lines = 80, 20
  end)

  it("follows a heading with hidden text directly, like a folded one", function()
    setup({ "* A", "body", "** B", "b", "* C" })
    fold.content()
    draw()
    eq("* A...", screen_row(1))
    eq("** B...", screen_row(2))
  end)

  it("goes away when the hidden line is replaced", function()
    setup({ "* A", "a body", "** A1", "a1 body", "* B", "b body" })
    fold.content()
    draw()
    eq("* A...", screen_row(1))
    vim.cmd("2s/.*/replaced/")
    draw()
    eq("* A", screen_row(1))
    eq("replaced", screen_row(2))
  end)

  it("goes away once 'foldtext' is changed", function()
    setup({ "* A", "body", "* B", "body" })
    vim.cmd("normal! zM")
    draw()
    eq("* A...", screen_row(1))
    vim.wo.foldtext = "foldtext()"
    vim.cmd("normal! zR")
    draw()
    eq("* A", screen_row(1))
  end)

  it("isn't drawn for a folded heading scrolled out of view", function()
    vim.o.columns = 40
    setup({ "* A long headline that is wider than the leftcol offset", "body", "* Short", "body" })
    vim.cmd("normal! zM")
    vim.wo.wrap = false
    vim.fn.winrestview({ leftcol = 25 })
    draw()
    eq(25, vim.fn.winsaveview().leftcol)
    eq("", screen_row(2))
    ok(screen_row(1):find("%.%.%.$"), screen_row(1))
  end)

  it("comes after the column view row", function()
    setup({
      "#+COLUMNS: %25ITEM %TODO %Effort{:} %TAGS",
      "* TODO Project with a long title :work:",
      ":PROPERTIES:",
      ":Effort: 1:00",
      ":END:",
      "** Sub",
    }, { 2, 0 })
    require("org.columns").open()
    fold.content()
    draw()
    local row = screen_row(3)
    local want = "* Project with a long t.. | TODO | 1:00   | :work: |"
    eq(want, row:sub(1, #want))
    eq("...", row:sub(#want + 1))
    require("org.columns").quit()
  end)
end)

describe("jumping from the agenda", function()
  local config = require("org.config")
  local utils = require("org.utils")
  local view = require("org.agenda.view")

  after_each(function()
    pcall(view.quit, true)
  end)

  it("shows the target without its siblings in a folded file", function()
    local dir = utils.realpath((function()
      local d = vim.fn.tempname()
      vim.fn.mkdir(d, "p")
      return d
    end)())
    local path = dir .. "/goto.org"
    local today = require("org.date").today():to_string({ brackets = false })
    utils.writefile(path, {
      "#+STARTUP: overview",
      "* A",
      "** A1",
      "   body a1",
      "** TODO A2 target",
      "   SCHEDULED: <" .. today .. ">",
      "   body a2",
      "*** A2a child",
      "    child body",
      "** A3",
      "* B",
    })
    config.setup({ agenda_files = { path }, org_directory = dir })
    config.opts.clock.persist = false
    require("org.agenda").open_agenda({ span = "day" })
    local target
    for l, item in pairs(view.state.line_items) do
      if item.title and item.title:find("A2 target", 1, true) then
        target = l
      end
    end
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "mx", false)
    local win = vim.fn.bufwinid(vim.fn.bufnr(path))
    ok(win ~= -1)
    local lines
    vim.api.nvim_win_call(win, function()
      lines = shown()
    end)
    ok(vim.tbl_contains(lines, "** TODO A2 target"), vim.inspect(lines))
    ok(not vim.tbl_contains(lines, "** A1"), vim.inspect(lines))
    ok(not vim.tbl_contains(lines, "** A3"), vim.inspect(lines))
  end)
end)
