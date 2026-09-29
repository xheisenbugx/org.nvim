-- Structure editing commands added for Emacs Org 9.8.10 parity:
-- org-edit-headline, org-insert-todo-subheading, org-convert-to-odd-levels
-- and org-convert-to-oddeven-levels. Expectations come from Emacs 9.8.10.
local utils = require("org.utils")
vim.g.org_test = true

local function with_stub(tbl, key, fn, body)
  local orig = tbl[key]
  tbl[key] = fn
  local ok, err = pcall(body)
  tbl[key] = orig
  if not ok then
    error(err, 0)
  end
end

local function yes(body)
  with_stub(utils, "confirm", function()
    return true
  end, body)
end

describe("edit_headline", function()
  it("replaces the title, keeping keyword, priority and tags", function()
    local buf = org_buffer({ "* TODO [#A] Old title  :tag:", "body" }, { 2, 0 })
    require("org.structure").edit_headline("A much longer new title")
    eq({ "* TODO [#A] A much longer new title                                     :tag:", "body" }, buf_lines(buf))
  end)

  it("adds a title to an empty headline", function()
    local buf = org_buffer({ "* TODO :tag:" }, { 1, 0 })
    require("org.structure").edit_headline("New")
    eq({ "* TODO New                                                              :tag:" }, buf_lines(buf))
  end)

  it("edits COMMENT as part of the title and trims", function()
    local buf = org_buffer({ "* COMMENT Old" }, { 1, 0 })
    require("org.structure").edit_headline("  New  ")
    eq({ "* New" }, buf_lines(buf))
  end)

  it("prompts with the old title", function()
    local buf = org_buffer({ "** DONE Title :a:" }, { 1, 0 })
    local seen
    with_stub(utils, "input", function(opts)
      seen = opts
      return "Changed"
    end, function()
      require("org.actions").run("edit_headline")
    end)
    eq("Edit: ", seen.prompt)
    eq("Title", seen.default)
    ok(buf_lines(buf)[1]:match("^%*%* DONE Changed%s+:a:$"))
  end)
end)

describe("insert_todo_subheading", function()
  it("inserts a demoted TODO heading after the headline line", function()
    local buf = org_buffer({ "* TODO A", "body", "* B" }, { 1, 0 })
    require("org.structure").insert_todo_subheading()
    vim.cmd("stopinsert")
    eq({ "* TODO A", "** TODO ", "body", "* B" }, buf_lines(buf))
  end)

  it("uses the first keyword after a done sibling", function()
    local buf = org_buffer({ "* DONE A" }, { 1, 0 })
    require("org.structure").insert_todo_subheading()
    vim.cmd("stopinsert")
    eq({ "* DONE A", "** TODO " }, buf_lines(buf))
  end)

  it("inserts an indented checkbox item on an item", function()
    local buf = org_buffer({ "* TODO A", "- item" }, { 2, 0 })
    require("org.structure").insert_todo_subheading()
    vim.cmd("stopinsert")
    eq({ "* TODO A", "- item", "  - [ ] " }, buf_lines(buf))
  end)
end)

describe("level conversion", function()
  it("convert_to_odd_levels", function()
    local buf = org_buffer({ "* A", "** B :x:", "text", "*** C", "**** D", "* E" }, { 1, 0 })
    yes(function()
      require("org.structure").convert_to_odd_levels()
    end)
    eq({
      "* A",
      "*** B                                                                     :x:",
      "text",
      "***** C",
      "******* D",
      "* E",
    }, buf_lines(buf))
  end)

  it("convert_to_oddeven_levels", function()
    local buf = org_buffer({ "* A", "*** B :x:", "text", "***** C" }, { 3, 0 })
    yes(function()
      require("org.structure").convert_to_oddeven_levels()
    end)
    eq({
      "* A",
      "** B                                                                      :x:",
      "text",
      "*** C",
    }, buf_lines(buf))
    eq({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("convert_to_oddeven_levels refuses even levels", function()
    local buf = org_buffer({ "* A", "** B" }, { 1, 0 })
    local msg
    with_stub(utils, "error", function(m)
      msg = m
    end, function()
      yes(function()
        require("org.structure").convert_to_oddeven_levels()
      end)
    end)
    eq("Not all levels are odd in this file.  Conversion not possible", msg)
    eq({ "* A", "** B" }, buf_lines(buf))
  end)

  it("asks before converting", function()
    local buf = org_buffer({ "* A", "** B" }, { 1, 0 })
    with_stub(utils, "confirm", function()
      return false
    end, function()
      require("org.structure").convert_to_odd_levels()
    end)
    eq({ "* A", "** B" }, buf_lines(buf))
  end)
end)

describe("adapt_indentation = headline-data", function()
  local config = require("org.config")
  local saved
  before_each(function()
    saved = config.opts.adapt_indentation
    config.opts.adapt_indentation = "headline-data"
  end)
  after_each(function()
    config.opts.adapt_indentation = saved
  end)

  it("demoting moves only the headline data", function()
    local buf = org_buffer({
      "* H",
      "  SCHEDULED: <2024-01-01 Mon>",
      "  :PROPERTIES:",
      "  :A: 1",
      "  :END:",
      "  :LOGBOOK:",
      "  - note",
      "  :END:",
      "body",
      "  more",
    }, { 1, 0 })
    require("org.structure").demote_heading()
    -- Emacs 9.8.10: org-demote
    eq({
      "** H",
      "   SCHEDULED: <2024-01-01 Mon>",
      "   :PROPERTIES:",
      "   :A:        1",
      "   :END:",
      "   :LOGBOOK:",
      "   - note",
      "   :END:",
      "body",
      "  more",
    }, buf_lines(buf))
  end)

  it("promoting too", function()
    local buf = org_buffer({ "** H", "   :PROPERTIES:", "   :A: 1", "   :END:", "body" }, { 1, 0 })
    require("org.structure").promote_heading()
    -- Emacs 9.8.10: org-promote
    eq({ "* H", "  :PROPERTIES:", "  :A:        1", "  :END:", "body" }, buf_lines(buf))
  end)

  it("indents a new body line to column 0 after the headline data", function()
    local buf = org_buffer({ "** H", "   :PROPERTIES:", "   :A: 1", "   :END:", "text" }, { 5, 0 })
    vim.cmd("silent normal! ==")
    -- Emacs 9.8.10: org-indent-line leaves it
    eq("text", buf_lines(buf)[5])
    vim.api.nvim_buf_set_lines(buf, 1, 4, false, {})
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("silent normal! ==")
    eq("text", buf_lines(buf)[2])
  end)
end)

describe("version", function()
  it("shows the release, git version and install directory (org-version)", function()
    local v = require("org.version")
    local msg
    with_stub(vim, "notify", function(m)
      msg = m
    end, function()
      require("org.actions").run("version")
    end)
    -- like Emacs: "Org mode version 9.8.10 (release_9.8.10 @ /dir/)"
    ok(msg:find("^org%.nvim version " .. vim.pesc(v.release) .. " %(.+ @ .+/%)$"), msg)
    ok(msg:find(v.root(), 1, true), msg)
  end)

  it("inserts it at the cursor with a count", function()
    local buf = org_buffer({ "x" }, { 1, 0 })
    vim.keymap.set("n", "<F9>", function()
      require("org.actions").run("version")
    end, { buffer = buf })
    vim.api.nvim_feedkeys(vim.keycode("4<F9>"), "xt", false)
    ok(buf_lines(buf)[1]:find("org.nvim version", 1, true), buf_lines(buf)[1])
  end)
end)

describe("yank (p / P) of subtrees", function()
  local config = require("org.config")
  local saved
  before_each(function()
    saved = { config.opts.yank_folded_subtrees, config.opts.yank_adjusted_subtrees }
  end)
  after_each(function()
    config.opts.yank_folded_subtrees, config.opts.yank_adjusted_subtrees = saved[1], saved[2]
  end)

  local function org_buffer(lines, pos)
    local buf = _G.org_buffer(lines, pos)
    -- new folds open, so that only what yank folds is closed
    vim.wo.foldlevel = 99
    return buf
  end

  local function closed(lnum)
    return vim.fn.foldclosed(lnum) == lnum
  end

  local function put(keys)
    vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
  end

  -- expectations: Emacs 9.8.10 org-yank at the start of the line after
  -- the cursor line (p) or of the cursor line (P)
  it("folds a put subtree", function()
    local buf = org_buffer({ "* A", "* B" }, { 1, 0 })
    vim.fn.setreg('"', { "** K", "body", "*** K2" }, "l")
    put("p")
    eq({ "* A", "** K", "body", "*** K2", "* B" }, buf_lines(buf))
    ok(closed(2))
  end)

  it("P puts before the line", function()
    local buf = org_buffer({ "* A", "* B" }, { 2, 0 })
    vim.fn.setreg("a", { "** K", "body" }, "l")
    put('"aP')
    eq({ "* A", "** K", "body", "* B" }, buf_lines(buf))
    ok(closed(2))
  end)

  it("does not fold when that would swallow text", function()
    local buf = org_buffer({ "* A", "text after" }, { 1, 0 })
    vim.fn.setreg('"', { "** K", "body" }, "l")
    local msg
    local orig = vim.notify
    vim.notify = function(m)
      msg = m
    end
    put("p")
    vim.notify = orig
    eq({ "* A", "** K", "body", "text after" }, buf_lines(buf))
    ok(not closed(2))
    eq("Inserted text not folded because that would swallow text", msg)
  end)

  it("puts other text as is", function()
    local buf = org_buffer({ "* A" }, { 1, 0 })
    vim.fn.setreg('"', { "text", "** K" }, "l")
    put("p")
    eq({ "* A", "text", "** K" }, buf_lines(buf))
    vim.fn.setreg('"', "x", "c")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    put("p")
    eq("*x A", buf_lines(buf)[1])
  end)

  it("with a count, a plain put", function()
    local buf = org_buffer({ "* A", "* B" }, { 1, 0 })
    vim.fn.setreg('"', { "** K", "body" }, "l")
    put("2p")
    eq({ "* A", "** K", "body", "** K", "body", "* B" }, buf_lines(buf))
    ok(not closed(2))
  end)

  it("yank_adjusted_subtrees adjusts the level", function()
    config.opts.yank_adjusted_subtrees = true
    local buf = org_buffer({ "* A", "** A1", "body", "** A2" }, { 2, 0 })
    vim.fn.setreg('"', { "* K", "body", "** K2" }, "l")
    local orig = vim.notify
    vim.notify = function() end
    put("p")
    vim.notify = orig
    -- pasted before the next visible headline, not folded (like Emacs)
    eq({ "* A", "** A1", "body", "** K", "body", "*** K2", "** A2" }, buf_lines(buf))
    ok(not closed(4))
  end)

  it("yank_adjusted_subtrees before a headline folds", function()
    config.opts.yank_adjusted_subtrees = true
    local buf = org_buffer({ "* A", "** A1", "** A2" }, { 2, 0 })
    vim.fn.setreg('"', { "* K", "body" }, "l")
    local orig = vim.notify
    vim.notify = function() end
    put("p")
    vim.notify = orig
    eq({ "* A", "** A1", "** K", "body", "** A2" }, buf_lines(buf))
    ok(closed(3))
  end)

  it("yank_folded_subtrees = false", function()
    config.opts.yank_folded_subtrees = false
    local buf = org_buffer({ "* A", "* B" }, { 1, 0 })
    vim.fn.setreg('"', { "** K", "body" }, "l")
    put("p")
    eq({ "* A", "** K", "body", "* B" }, buf_lines(buf))
    ok(not closed(2))
  end)
end)

describe("allow_promoting_top_level_subtree", function()
  local config = require("org.config")
  before_each(function()
    config.opts.allow_promoting_top_level_subtree = true
  end)
  after_each(function()
    config.opts.allow_promoting_top_level_subtree = false
  end)

  -- expectations: Emacs 9.8.10
  it("promote subtree", function()
    local buf = org_buffer({ "* A :tag:", "body", "** B", "*** C", "* D" }, { 1, 0 })
    require("org.structure").promote_subtree()
    eq({ "# A :tag:", "body", "* B", "** C", "* D" }, buf_lines(buf))
  end)

  it("promote heading", function()
    local buf = org_buffer({ "* A", "** B" }, { 1, 0 })
    require("org.structure").promote_heading()
    eq({ "# A", "** B" }, buf_lines(buf))
  end)

  it("promote the headlines of a selection", function()
    local buf = org_buffer({ "* A", "** B", "* C" }, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("VG<M-h>"), "xt", false)
    eq({ "# A", "* B", "# C" }, buf_lines(buf))
  end)

  it("off: refused", function()
    config.opts.allow_promoting_top_level_subtree = false
    local buf = org_buffer({ "* A" }, { 1, 0 })
    local orig = vim.notify
    vim.notify = function() end
    require("org.structure").promote_heading()
    vim.notify = orig
    eq({ "* A" }, buf_lines(buf))
  end)
end)

describe("edit_keep_region", function()
  local config = require("org.config")
  local saved
  before_each(function()
    saved = config.opts.edit_keep_region
  end)
  after_each(function()
    config.opts.edit_keep_region = saved
  end)

  it("keeps the selection after <M-l> (Emacs 9.8.10: region stays active)", function()
    local buf = org_buffer({ "* A", "** B", "** C" }, { 2, 0 })
    vim.api.nvim_feedkeys(vim.keycode("Vj<M-l>"), "xt", false)
    eq({ "* A", "*** B", "*** C" }, buf_lines(buf))
    local mode
    vim.api.nvim_feedkeys(vim.keycode("<M-l>"), "xt", false)
    eq({ "* A", "**** B", "**** C" }, buf_lines(buf))
    mode = vim.fn.mode()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
    eq("V", mode)
  end)

  it("false: leaves Visual mode", function()
    config.opts.edit_keep_region = false
    local buf = org_buffer({ "* A", "** B", "** C" }, { 2, 0 })
    vim.api.nvim_feedkeys(vim.keycode("Vj<M-l>"), "xt", false)
    eq("n", vim.fn.mode())
    eq({ "* A", "*** B", "*** C" }, buf_lines(buf))
  end)

  it("per command: meta_down off", function()
    config.opts.edit_keep_region = { meta_down = false, meta_up = true }
    local buf = org_buffer({ "* A", "* B", "* C" }, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("V<M-j>"), "xt", false)
    eq({ "* B", "* A", "* C" }, buf_lines(buf))
    eq("n", vim.fn.mode())
  end)
end)

describe("inserting headings", function()
  local config = require("org.config")

  it("insert_heading_respect_content makes <M-CR> insert after the subtree", function()
    config.opts.insert_heading_respect_content = true
    local buf = org_buffer({ "* A", "body", "** A1", "* B" }, { 1, 0 })
    local ok_, err = pcall(function()
      require("org.context").meta_return()
      vim.cmd("stopinsert")
    end)
    config.opts.insert_heading_respect_content = false
    assert(ok_, err)
    -- Emacs 9.8.10: org-insert-heading with the option
    eq({ "* A", "body", "** A1", "* ", "* B" }, buf_lines(buf))
  end)

  it("fires OrgInsertHeading before the TODO keyword is added", function()
    -- Normal mode: at the end of the line (column 0 would insert above)
    local buf = org_buffer({ "* TODO A" }, { 1, 3 })
    local seen
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "OrgInsertHeading",
      callback = function(ev)
        seen = { ev.data.lnum, vim.api.nvim_buf_get_lines(ev.data.bufnr, ev.data.lnum - 1, ev.data.lnum, false)[1] }
      end,
    })
    require("org.context").meta_shift_return()
    vim.cmd("stopinsert")
    vim.api.nvim_del_autocmd(id)
    -- Emacs 9.8.10: the hook sees line 2 as "* "
    eq({ 2, "* " }, seen)
    eq({ "* TODO A", "* TODO " }, buf_lines(buf))
  end)
end)

describe("insert_mode_line_in_empty_file", function()
  local config = require("org.config")

  it("adds the Emacs mode line to an empty file set to org, which then opens as org", function()
    local path = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({}, path)
    config.opts.insert_mode_line_in_empty_file = true
    local ok_, err = pcall(function()
      vim.cmd("silent edit! " .. vim.fn.fnameescape(path))
      eq("text", vim.bo.filetype)
      vim.cmd("setfiletype org")
      vim.bo.filetype = "org"
    end)
    config.opts.insert_mode_line_in_empty_file = false
    assert(ok_, err)
    -- Emacs 9.8.10 inserts "#    -*- mode: org -*-\n\n"
    eq({ "#    -*- mode: org -*-", "" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    vim.cmd("silent write")
    vim.cmd("silent bwipeout!")
    vim.cmd("silent edit " .. vim.fn.fnameescape(path))
    eq("org", vim.bo.filetype)
    vim.cmd("silent bwipeout!")
    vim.fn.delete(path)
  end)

  it("off by default", function()
    local path = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({}, path)
    vim.cmd("silent edit! " .. vim.fn.fnameescape(path))
    vim.bo.filetype = "org"
    eq({ "" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    vim.cmd("silent bwipeout!")
    vim.fn.delete(path)
  end)
end)

describe("indirect_buffer_display", function()
  local config = require("org.config")
  local structure = require("org.structure")
  local tree = { "* A", "** B", "b body", "* C" }
  after_each(function()
    config.opts.indirect_buffer_display = "other-window"
    vim.cmd("silent! tabonly!")
    vim.cmd("silent! only!")
  end)

  it("current-window shows the subtree in this window", function()
    config.opts.indirect_buffer_display = "current-window"
    local src = org_buffer(tree, { 2, 0 })
    vim.bo[src].bufhidden = "hide" -- org_buffer's "wipe" can't leave a modified buffer
    local wins = #vim.api.nvim_list_wins()
    local win0 = vim.api.nvim_get_current_win()
    local buf, win = structure.tree_to_indirect_buffer()
    eq(wins, #vim.api.nvim_list_wins())
    eq(win0, win)
    eq({ "** B", "b body" }, buf_lines(buf))
  end)

  it("new-frame opens a tab each time", function()
    config.opts.indirect_buffer_display = "new-frame"
    org_buffer(tree, { 2, 0 })
    local tabs = #vim.api.nvim_list_tabpages()
    structure.tree_to_indirect_buffer()
    eq(tabs + 1, #vim.api.nvim_list_tabpages())
  end)

  it("dedicated-frame reuses one tab", function()
    config.opts.indirect_buffer_display = "dedicated-frame"
    local src = org_buffer(tree, { 2, 0 })
    local tabs = #vim.api.nvim_list_tabpages()
    local first_tab = vim.api.nvim_get_current_tabpage()
    structure.tree_to_indirect_buffer()
    local dedicated = vim.api.nvim_get_current_tabpage()
    eq(tabs + 1, #vim.api.nvim_list_tabpages())
    vim.api.nvim_set_current_tabpage(first_tab)
    vim.api.nvim_set_current_buf(src)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    local buf = structure.tree_to_indirect_buffer()
    eq(tabs + 1, #vim.api.nvim_list_tabpages())
    eq(dedicated, vim.api.nvim_get_current_tabpage())
    eq({ "* C" }, buf_lines(buf))
  end)
end)

describe("sort_function", function()
  local config = require("org.config")
  local lessp = require("org.utils").string_lessp
  after_each(function()
    config.opts.sort_function = "collate"
  end)

  it("fallback compares character codes (org-sort-function-fallback)", function()
    config.opts.sort_function = "fallback"
    -- Emacs 9.8.10 with org-sort-function-fallback
    local list = { "b", "B", "a", "A", "_x", "é", "e", "Z" }
    table.sort(list, lessp)
    eq({ "A", "B", "Z", "_x", "a", "b", "e", "é" }, list)
    ok(not lessp("a", "A", true) and not lessp("A", "a", true))
  end)

  it("collate follows the collation locale (character codes on macOS, like Emacs)", function()
    config.opts.sort_function = "collate"
    local list = { "b", "a", "c" }
    table.sort(list, lessp)
    eq({ "a", "b", "c" }, list)
    local l = { "b", "B", "a", "_x" }
    table.sort(l, lessp)
    if vim.fn.has("mac") == 1 then
      -- Emacs 9.8.10 on macOS: ("B" "_x" "a" "b")
      eq({ "B", "_x", "a", "b" }, l)
    else
      eq(vim.fn.sort({ "b", "B", "a", "_x" }, "l"), l)
    end
  end)

  it("a function, used by entry sorting", function()
    local calls = 0
    config.opts.sort_function = function(a, b)
      calls = calls + 1
      return a > b -- reverse
    end
    local buf = org_buffer({ "* P", "** a", "** c", "** b" }, { 1, 0 })
    local ui = require("org.ui")
    local orig = ui.menu
    ui.menu = function()
      return { kind = "alpha", reverse = false }
    end
    local ok_, err = pcall(require("org.structure").sort)
    ui.menu = orig
    assert(ok_, err)
    ok(calls > 0)
    eq({ "* P", "** c", "** b", "** a" }, buf_lines(buf))
  end)
end)
