-- Agenda commands keep acting on the right source entry after the source
-- buffer was edited (Emacs uses markers for this).
local config = require("org.config")
local utils = require("org.utils")
local view = require("org.agenda.view")
local agenda = require("org.agenda")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/m.org"

local function setup(lines)
  utils.writefile(path, lines)
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
  config.setup({ agenda_files = { path }, org_directory = dir })
  config.opts.clock.persist = false
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function item_lines(title)
  local out = {}
  for l, it in pairs(view.state.line_items) do
    if it.title == title then
      out[#out + 1] = l
    end
  end
  table.sort(out)
  return out
end

local function titles()
  local out = {}
  for _, it in pairs(view.state.line_items) do
    out[#out + 1] = it.title
  end
  table.sort(out)
  return out
end

describe("agenda entries after source edits", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  it("acts on the entry of the line, not an identical one above", function()
    local src = setup({ "* TODO Call", "* TODO Call" })
    agenda.open_todo()
    local l = item_lines("Call")
    eq(2, #l)
    -- the second entry
    vim.api.nvim_win_set_cursor(view.state.win, { l[2], 0 })
    vim.api.nvim_buf_set_lines(src, 0, 0, false, { "* Inserted" })
    view.actions.todo_next()
    eq({ "* Inserted", "* TODO Call", "* DONE Call" }, vim.api.nvim_buf_get_lines(src, 0, 3, false))
  end)

  it("acts on the moved entry of an item when identical ones exist", function()
    local src = setup({ "* TODO Call", "* Other", "* TODO Call" })
    agenda.open_todo()
    local l = item_lines("Call")
    vim.api.nvim_win_set_cursor(view.state.win, { l[1], 0 })
    vim.api.nvim_buf_set_lines(src, 0, 0, false, { "* A", "* B", "* C" })
    view.actions.todo_next()
    eq({ "* A", "* B", "* C", "* DONE Call", "* Other", "* TODO Call" }, vim.api.nvim_buf_get_lines(src, 0, -1, false))
  end)

  it("a subtree restriction follows edits of the source buffer on redo", function()
    local src =
      setup({ "* Other", "** TODO Outside", "* Project", "** TODO One", "** TODO Two", "* Last", "** TODO Far" })
    agenda.open_todo(nil, { bufnr = src, filename = vim.api.nvim_buf_get_name(src), range = { 3, 5 } })
    eq({ "One", "Two" }, titles())
    -- a line above the subtree and one inside it
    vim.api.nvim_buf_set_lines(src, 0, 0, false, { "#+TITLE: x" })
    vim.api.nvim_buf_set_lines(src, 4, 4, false, { "   body" })
    view.redo()
    eq({ "One", "Two" }, titles())
  end)

  it("drag keeps the line highlight of the moved lines", function()
    setup({ "* TODO One", "* TODO Two" })
    agenda.open_todo()
    local one, two = item_lines("One")[1], item_lines("Two")[1]
    -- a line highlight like the clocked entry's
    view.state.line_hl_groups[one] = "OrgAgendaClocking"
    vim.api.nvim_win_set_cursor(view.state.win, { one, 0 })
    view.drag_line(two - one)
    local function line_hl(l)
      return view.state.line_hl_groups[l]
    end
    eq("One", view.state.line_items[two].title)
    eq("OrgAgendaClocking", line_hl(two))
    eq(nil, line_hl(one))
  end)
end)

describe("agenda bulk mark regexp", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  -- org-agenda-bulk-mark-regexp matches the entry text (txt), not the
  -- category prefix of the line (checked against Emacs 9.8.10)
  it("matches the entry text, not the prefix", function()
    setup({
      "#+CATEGORY: alpha",
      "* TODO Short task :work:",
      "* TODO Long task :home:",
      "* TODO Exactly half hour :work:urgent:",
      "* TODO Beta child :Work:",
      "* TODO Phone call :phone:",
    })
    agenda.open_todo()
    eq(0, view.mark_regexp("alpha"))
    view.actions.unmark_all()
    eq(0, view.mark_regexp("^  alpha"))
    view.actions.unmark_all()
    eq(2, view.mark_regexp("task"))
    view.actions.unmark_all()
    eq(2, view.mark_regexp("work:$"))
  end)
end)

describe("agenda category filter", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  it("< with a count removes a filter for a category (org-agenda-filtered-by-category)", function()
    setup({ "* TODO A", ":PROPERTIES:", ":CATEGORY: Work", ":END:", "* TODO B" })
    agenda.open_todo()
    vim.api.nvim_win_set_cursor(view.state.win, { item_lines("A")[1], 0 })
    view.actions.filter_category()
    eq({ "A" }, titles())
    vim.cmd("normal 1<")
    vim.cmd("normal! \27")
    eq({ "A", "B" }, titles())
    eq({}, view.state.filters.category)
  end)
end)
