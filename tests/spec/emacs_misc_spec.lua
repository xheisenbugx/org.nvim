local config = require("org.config")
local date = require("org.date")
local dblock = require("org.dblock")
local files = require("org.files")
local fold = require("org.fold")
local properties = require("org.properties")
local structure = require("org.structure")
local timer = require("org.timer")
local timestamps = require("org.timestamps")
local todo = require("org.todo")
local utils = require("org.utils")

local function with_stub(tbl, key, fn, body)
  local orig = tbl[key]
  tbl[key] = fn
  local ok_, err = pcall(body)
  tbl[key] = orig
  if not ok_ then
    error(err, 0)
  end
end

local function silence(body)
  with_stub(vim, "notify", function() end, body)
end

local tree = {
  "* A", -- 1
  "a body", -- 2
  "** B", -- 3
  "b body", -- 4
  "*** B1", -- 5
  "b1 body", -- 6
  "** C", -- 7
  "c body", -- 8
  "* D", -- 9
  "d body", -- 10
}

describe("emacs: outline visibility", function()
  it("show_branches shows every headline, folds leaves", function()
    local buf = org_buffer(tree, { 1, 0 })
    fold.setup_buffer(buf)
    fold.overview()
    fold.show_branches()
    eq(-1, vim.fn.foldclosed(1))
    eq(-1, vim.fn.foldclosed(3))
    eq(5, vim.fn.foldclosed(5))
    eq(7, vim.fn.foldclosed(7))
    eq(9, vim.fn.foldclosed(9))
  end)

  it("show_children shows only direct children, folded", function()
    local buf = org_buffer(tree, { 2, 0 })
    fold.setup_buffer(buf)
    fold.show_all()
    fold.show_children()
    eq(-1, vim.fn.foldclosed(1))
    eq(3, vim.fn.foldclosed(3))
    eq(3, vim.fn.foldclosed(5))
    eq(7, vim.fn.foldclosed(7))
  end)

  it("returns false outside a subtree", function()
    org_buffer({ "text", "* A" }, { 1, 0 })
    eq(false, fold.show_children())
    eq(false, fold.show_branches())
    org_buffer({ "* Lonely" }, { 1, 0 })
    fold.show_children()
    fold.reveal(true)
  end)

  it("reveal opens the folds hiding the cursor", function()
    local buf = org_buffer(tree, { 6, 0 })
    fold.setup_buffer(buf)
    fold.overview()
    fold.reveal(false)
    eq(-1, vim.fn.foldclosed(6))
    eq(7, vim.fn.foldclosed(7))
    fold.overview()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    fold.reveal(true)
    eq(-1, vim.fn.foldclosed(6))
    eq(-1, vim.fn.foldclosed(8))
  end)

  it("copy_visible skips closed fold contents", function()
    local buf = org_buffer(tree, { 1, 0 })
    fold.setup_buffer(buf)
    fold.overview()
    vim.cmd("1foldopen")
    silence(function()
      fold.copy_visible()
    end)
    eq({ "* A", "a body", "** B", "** C", "* D" }, vim.fn.getreg('"', 1, true))
  end)
end)

describe("emacs: subtree", function()
  it("mark_subtree selects the subtree linewise", function()
    local report = vim.o.report
    vim.o.report = 10000
    org_buffer(tree, { 4, 0 })
    structure.mark_subtree()
    eq("V", vim.fn.mode())
    vim.cmd("normal! y")
    eq({ "** B", "b body", "*** B1", "b1 body" }, vim.fn.getreg('"', 1, true))
    -- repeated in visual mode: extend to the next sibling
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.keymap.set("x", "<F12>", function()
      structure.mark_subtree()
    end, { buffer = 0 })
    vim.api.nvim_feedkeys(vim.keycode("Vjjj<F12>y"), "x", false)
    vim.o.report = report
    eq({ "** B", "b body", "*** B1", "b1 body", "** C", "c body" }, vim.fn.getreg('"', 1, true))
  end)

  it("tree_to_indirect_buffer edits the subtree in a split", function()
    local src = org_buffer(tree, { 3, 0 })
    local wins = #vim.api.nvim_list_wins()
    local buf, win = structure.tree_to_indirect_buffer()
    eq(wins + 1, #vim.api.nvim_list_wins())
    eq(false, vim.api.nvim_win_get_config(win).relative ~= "")
    eq({ "** B", "b body", "*** B1", "b1 body" }, buf_lines(buf))
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "changed" })
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("write")
    end)
    eq("changed", buf_lines(src)[4])
    vim.api.nvim_win_close(win, true)
  end)

  it("toggles the ORDERED property", function()
    local buf = org_buffer({ "* A", "** B" }, { 1, 0 })
    silence(function()
      properties.toggle_ordered()
      eq({ "* A", ":PROPERTIES:", ":ORDERED: t", ":END:", "** B" }, buf_lines(buf))
      eq(true, properties.toggle_ordered())
    end)
    eq({ "* A", "** B" }, buf_lines(buf))
  end)
end)

describe("emacs: dates", function()
  it("inserts today", function()
    local buf = org_buffer({ "Due " }, { 1, 3 })
    timestamps.insert_today()
    eq("Due " .. date.today():to_string(), buf_lines(buf)[1])
  end)

  it("evaluates a date range", function()
    local msg
    local buf = org_buffer({ "<2026-01-01 Thu 10:00>--<2026-01-03 Sat 13:15> => old" }, { 1, 0 })
    with_stub(vim, "notify", function(m)
      msg = m
    end, function()
      timestamps.evaluate_time_range(false)
      eq("2 days 3:15", msg)
      eq("<2026-01-01 Thu 10:00>--<2026-01-03 Sat 13:15> => old", buf_lines(buf)[1])
      timestamps.evaluate_time_range(true)
    end)
    eq("<2026-01-01 Thu 10:00>--<2026-01-03 Sat 13:15> => 51:15", buf_lines(buf)[1])
  end)

  it("evaluates a time range", function()
    local msg
    local buf = org_buffer({ "Meet <2026-01-01 Thu 10:00-12:30> ok" }, { 1, 0 })
    with_stub(vim, "notify", function(m)
      msg = m
    end, function()
      timestamps.evaluate_time_range(true)
    end)
    eq("2:30", msg)
    eq("Meet <2026-01-01 Thu 10:00-12:30> => 2:30 ok", buf_lines(buf)[1])
  end)

  it("updates CLOCK lines and rejects lines without ranges", function()
    local buf = org_buffer({
      "* T",
      "CLOCK: [2026-01-01 Thu 10:00]--[2026-01-01 Thu 11:30] =>  0:00",
      "plain <2026-01-01 Thu>",
    }, { 2, 0 })
    silence(function()
      eq(true, timestamps.evaluate_time_range(false))
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      eq(false, timestamps.evaluate_time_range(false))
    end)
    ok(buf_lines(buf)[2]:match("=>%s+1:30$"), buf_lines(buf)[2])
  end)
end)

describe("emacs: agenda file list", function()
  it("adds, moves and removes the current file", function()
    local saved = config.opts.agenda_files
    local path = vim.fs.normalize(vim.fn.resolve(vim.fn.tempname()) .. ".org")
    vim.fn.writefile({ "* x" }, path)
    vim.cmd("silent edit! " .. vim.fn.fnameescape(path))
    vim.bo.filetype = "org"
    config.opts.agenda_files = { "~/nonexistent-org-dir/*.org" }
    silence(function()
      files.agenda_file_to_front()
      eq(path, config.opts.agenda_files[1])
      ok(vim.tbl_contains(files.agenda_file_paths(), path))
      files.remove_file()
      ok(not vim.tbl_contains(files.agenda_file_paths(), path))
      -- matched through a glob: still excluded
      config.opts.agenda_files = { vim.fn.fnamemodify(path, ":h") .. "/*.org" }
      ok(not vim.tbl_contains(files.agenda_file_paths(), path))
      files.agenda_file_to_front()
      ok(vim.tbl_contains(files.agenda_file_paths(), path))
    end)
    config.opts.agenda_files = saved
    files.removed = {}
    vim.cmd("enew!")
  end)
end)

describe("emacs: dynamic blocks", function()
  it("inserts a columnview block", function()
    local buf = org_buffer({ "* A", ":PROPERTIES:", ":Effort: 1:00", ":END:" }, { 1, 0 })
    with_stub(utils, "input_complete", function(prompt, cands)
      ok(prompt:find("Capture columns"))
      ok(vim.tbl_contains(cands, "global"))
      return ""
    end, function()
      dblock.insert_columnview()
    end)
    local l = buf_lines(buf)
    eq("#+BEGIN: columnview :hlines 1 :id local", l[2])
    ok(vim.tbl_contains(l, "#+END:"))
    ok(#l > 7)
  end)

  it("inserts a block of a chosen type", function()
    local buf = org_buffer({ "* A" }, { 1, 0 })
    dblock.register("hello", function()
      return { "hi" }
    end)
    with_stub(utils, "input_complete", function(_, cands)
      ok(vim.tbl_contains(cands, "clocktable"))
      ok(vim.tbl_contains(cands, "columnview"))
      return "hello"
    end, function()
      dblock.insert_dblock()
    end)
    dblock.writers.hello = nil
    eq({ "* A", "#+BEGIN: hello", "hi", "#+END:" }, buf_lines(buf))
  end)
end)

describe("emacs: todo / notes / timer", function()
  it("select_or_cycle cycles without fast keys", function()
    local buf = org_buffer({ "#+TODO: TODO | DONE", "* Task" }, { 2, 0 })
    todo.select_or_cycle()
    eq("* TODO Task", buf_lines(buf)[2])
  end)

  it("select_or_cycle uses fast selection with keys", function()
    org_buffer({ "* Task" }, { 1, 0 })
    local called = false
    with_stub(todo, "select", function()
      called = true
    end, function()
      todo.select_or_cycle()
    end)
    ok(called)
  end)

  it("add_note works at the cursor", function()
    local buf = org_buffer({ "* Task", "body" }, { 2, 0 })
    with_stub(utils, "input", function()
      return "hello"
    end, function()
      eq(true, todo.add_note())
    end)
    local text = table.concat(buf_lines(buf), "\n")
    ok(text:find("Note taken on"), text)
    ok(text:find("hello"), text)
  end)

  it("insert_item adds a timer list item", function()
    local buf = org_buffer({ "  - first", "" }, { 1, 0 })
    silence(function()
      timer.insert_item()
      vim.cmd("stopinsert")
      eq("  - 0:00:00 :: ", buf_lines(buf)[2])
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      timer.insert_item()
      vim.cmd("stopinsert")
      timer.stop()
    end)
    eq("- 0:00:00 :: ", buf_lines(buf)[3])
  end)
end)
