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

  -- Emacs keeps point out of invisible text, so TAB acts on the visible
  -- heading; Vim lets the cursor sit inside a closed fold (after G or a search)
  it("cycles the visible heading when the cursor is inside a closed fold", function()
    local buf = org_buffer({ "* A", "** B", "b body", "** C" }, { 1, 0 })
    fold.setup_buffer(buf)
    fold.overview()
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    eq(1, vim.fn.foldclosed(4))
    fold.cycle()
    -- Emacs 9.8.10: point ends up at the end of the visible heading
    eq({ 1, 2 }, vim.api.nvim_win_get_cursor(0))
    eq(-1, vim.fn.foldclosed(1))
    eq(2, vim.fn.foldclosed(2))
  end)

  -- Emacs leaves point after a link that ends the heading, so
  -- org-tab-follows-link doesn't follow it
  it("cycles instead of following a link at the end of the visible heading", function()
    local links = require("org.config").opts.links
    local saved = links.tab_follows_link
    links.tab_follows_link = true
    local buf = org_buffer({ "* See [[B]]", "** sub", "body", "* B" }, { 1, 0 })
    fold.setup_buffer(buf)
    fold.overview()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    eq(1, vim.fn.foldclosed(3))
    local ok_, err = pcall(fold.cycle)
    links.tab_follows_link = saved
    assert(ok_, err)
    eq({ 1, 10 }, vim.api.nvim_win_get_cursor(0))
    eq(-1, vim.fn.foldclosed(1))
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

describe("fold: mapped Tab with short child folds", function()
  with_config({ cycle_separator_lines = 1 })
  local saved_foldminlines
  before_each(function()
    saved_foldminlines = vim.wo.foldminlines
    vim.wo.foldminlines = 1
  end)
  after_each(function()
    vim.wo.foldminlines = saved_foldminlines
  end)

  local function tab()
    vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "xt", false)
  end

  local function shown()
    local out = {}
    for l = 1, vim.fn.line("$") do
      if fold.line_visible(l) then
        out[#out + 1] = vim.fn.getline(l)
      end
    end
    return out
  end

  local cases = {
    {
      name = "a final child followed only by an EOF blank",
      lines = { "* Unsortiert", "** A", "body", "** B", "" },
      children = { "* Unsortiert", "** A", "** B", "" },
      folded = { "* Unsortiert", "" },
      child_closed = 2,
    },
    {
      name = "a final child followed only by whitespace at EOF",
      lines = { "* Unsortiert", "** A", "body", "** B", "", "  " },
      children = { "* Unsortiert", "** A", "** B", "", "  " },
      folded = { "* Unsortiert", "", "  " },
      child_closed = 2,
    },
    {
      name = "the cursor inside a closed parent with an empty final child",
      lines = { "* Unsortiert", "** A", "body", "** B", "" },
      cursor = 4,
      children = { "* Unsortiert", "** A", "** B", "" },
      folded = { "* Unsortiert", "" },
      child_closed = 2,
    },
    {
      name = "a child followed only by a separator blank",
      lines = { "* Unsortiert", "** A", "body", "** B", "", "** C" },
      children = { "* Unsortiert", "** A", "** B", "", "** C" },
      folded = { "* Unsortiert" },
      child_closed = 2,
    },
    {
      name = "child folds no longer than foldminlines",
      lines = { "* Unsortiert", "** A", "body", "** B", "short body", "" },
      foldminlines = 2,
      children = { "* Unsortiert", "** A", "body", "** B", "short body", "" },
      folded = { "* Unsortiert", "" },
      child_closed = -1,
    },
  }

  for _, case in ipairs(cases) do
    it("cycles FOLDED -> CHILDREN -> SUBTREE -> FOLDED with " .. case.name, function()
      local buf = org_buffer(case.lines, { 1, 0 })
      vim.wo.foldminlines = case.foldminlines or 1
      fold.setup_buffer(buf)
      fold.overview()
      eq(1, vim.fn.foldclosed(1))
      eq(case.folded, shown())
      vim.api.nvim_win_set_cursor(0, { case.cursor or 1, 0 })
      eq(1, vim.fn.foldclosed(case.cursor or 1))

      -- Repeat the whole cycle: a bogus CHILDREN state must not leave the
      -- parent closed and trap every subsequent mapped Tab in that state.
      for _ = 1, 2 do
        tab()
        eq(-1, vim.fn.foldclosed(1), "CHILDREN keeps the parent open")
        -- from inside the fold the cursor goes to the end of the heading
        eq({ 1, case.cursor and #case.lines[1] - 1 or 0 }, vim.api.nvim_win_get_cursor(0))
        eq("children", vim.w.org_last_cycle.status)
        eq(case.child_closed, vim.fn.foldclosed(2))
        eq(case.children, shown())

        tab()
        eq("subtree", vim.w.org_last_cycle.status)
        eq(-1, vim.fn.foldclosed(1))
        eq(-1, vim.fn.foldclosed(2))
        eq(case.lines, shown())

        tab()
        eq("folded", vim.w.org_last_cycle.status)
        eq(1, vim.fn.foldclosed(1))
        eq(case.folded, shown())
      end
      eq(case.lines, buf_lines(buf))
    end)
  end
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

describe("fold: closed headlines", function()
  local function screen_row(row)
    local s = {}
    for c = 1, vim.o.columns do
      s[#s + 1] = vim.fn.screenstring(row, c)
    end
    return (table.concat(s):gsub("%s+$", ""))
  end
  -- redraw, then once more after the ellipsis marks are moved
  local function draw()
    vim.cmd("redraw!")
    vim.wait(20)
    vim.cmd("redraw!")
  end

  -- Emacs keeps a folded heading's faces: folding only hides the text after it
  it("keeps the highlighting of a folded heading and ends it with the ellipsis", function()
    local buf = org_buffer({ "* TODO Task [[https://x][link]] :tag:", "body", "* Next", "next body" }, { 1, 0 })
    fold.setup_buffer(buf)
    eq("", vim.wo.foldtext)
    fold.overview()
    draw()
    eq(1, vim.fn.foldclosed(1))
    -- the link is concealed as when the fold is open
    eq("* TODO Task link :tag:...", screen_row(1))
    eq("* Next...", screen_row(2))
    -- the TODO keyword and the title don't share one highlight
    ok(vim.fn.screenattr(1, 3) ~= vim.fn.screenattr(1, 8))
    vim.cmd("normal! ggzo")
    draw()
    eq("* TODO Task link :tag:", screen_row(1))
    eq("body", screen_row(2))
  end)

  it("puts the ellipsis only in the window where the fold is closed", function()
    local buf = org_buffer({ "* A", "body" }, { 1, 0 })
    fold.setup_buffer(buf)
    vim.cmd("normal! zM")
    vim.cmd("vsplit")
    fold.setup_buffer(buf)
    vim.cmd("normal! zR")
    draw()
    local width = vim.fn.winwidth(0)
    -- the left window, with the fold open, has no ellipsis
    eq("* A", (screen_row(1):sub(1, width):gsub("%s+$", "")))
    -- the right one, with it closed, has it
    ok(screen_row(1):find("│%* A%.%.%.$"), screen_row(1))
    vim.cmd("close")
  end)
end)
