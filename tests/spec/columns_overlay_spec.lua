-- Column view drawn over the headlines of the org buffer (Emacs org-columns).
local columns = require("org.columns")
local config = require("org.config")
local utils = require("org.utils")

local ns = vim.api.nvim_create_namespace("org.columns.overlay")

local function keys(k)
  vim.api.nvim_feedkeys(vim.keycode(k), "xt", false)
end

--- Put the cursor on screen column `n` of line `lnum` (digits are column
--- view keys on the rows).
local function cursor(lnum, n)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.cmd("normal! " .. n .. "|")
end

--- Overlay text drawn on buffer line `lnum` (trailing blanks removed).
local function row(lnum)
  local m = vim.api.nvim_buf_get_extmarks(0, ns, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })[1]
  if not m then
    return nil
  end
  local parts = {}
  for _, chunk in ipairs(m[4].virt_text) do
    parts[#parts + 1] = chunk[1]
  end
  return (table.concat(parts):gsub("%s+$", ""))
end

local lines = {
  "#+COLUMNS: %12ITEM %TODO %Effort{:}",
  "* TODO Project",
  "** Sub A",
  ":PROPERTIES:",
  ":Effort: 1:00",
  ":Effort_ALL: 0:30 1:00 2:00",
  ":END:",
  "** DONE Sub B",
  ":PROPERTIES:",
  ":Effort: 0:30",
  ":END:",
  "Body text",
  "* Other",
}

describe("overlay column view", function()
  after_each(function()
    columns.quit()
  end)

  it("draws the columns over the headlines, with summaries and a title winbar", function()
    org_buffer(lines, { 1, 0 })
    local wrap = vim.wo.wrap
    eq(true, columns.open())
    ok(columns.active())
    eq("* Project    | TODO | 1:30   |", row(2))
    eq("** Sub A     |      | 1:00   |", row(3))
    eq("** Sub B     | DONE | 0:30   |", row(8))
    eq("* Other      |      |        |", row(13))
    eq(nil, row(4))
    eq(nil, row(12))
    -- the buffer text is unchanged
    eq(lines, buf_lines())
    ok(vim.wo.winbar:find("ITEM         | TODO | Effort |", 1, true), vim.wo.winbar)
    eq(false, vim.wo.wrap)
    local rows = vim.tbl_keys(columns.overlay_lines(vim.api.nvim_get_current_buf()))
    table.sort(rows)
    eq({ 2, 3, 8, 13 }, rows)
    columns.quit()
    ok(not columns.active())
    eq(nil, row(2))
    eq("", vim.wo.winbar)
    eq(wrap, vim.wo.wrap)
  end)

  it("covers only the subtree at point when there is no COLUMNS above it", function()
    org_buffer({ "* A", "** A1", "* B" }, { 2, 0 })
    columns.open()
    ok(row(2))
    eq(nil, row(1))
    eq(nil, row(3))
  end)

  it("quits with q on a column row and restores the buffer's own mappings", function()
    local buf = org_buffer(lines, { 2, 0 })
    vim.keymap.set("n", "<C-c><C-c>", "<Cmd>let g:org_cc = 1<CR>", { buffer = buf })
    columns.open()
    keys("q")
    ok(not columns.active())
    eq("<Cmd>let g:org_cc = 1<CR>", vim.fn.maparg("<C-c><C-c>", "n"))
    eq("", vim.fn.maparg("q", "n"))
  end)

  it("keeps the usual meaning of the keys outside the column rows", function()
    local buf = org_buffer(lines, { 2, 0 })
    vim.keymap.set("n", "<C-c><C-c>", "<Cmd>let g:org_cc = 1<CR>", { buffer = buf })
    vim.g.org_cc = nil
    columns.open()
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    keys("<C-c><C-c>")
    eq(1, vim.g.org_cc)
    ok(columns.active())
    keys("2j")
    eq(6, vim.api.nvim_win_get_cursor(0)[1])
    keys("q")
    ok(columns.active())
    -- on a row, the column view key
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    keys("<C-c><C-c>")
    ok(not columns.active())
  end)

  it("n / p / digits switch the allowed values of the column under the cursor", function()
    local buf = org_buffer(lines, { 1, 0 })
    columns.open()
    cursor(3, 23)
    keys("n")
    eq(":Effort:   2:00", buf_lines(buf)[5])
    eq("** Sub A     |      | 2:00   |", row(3))
    eq("* Project    | TODO | 2:30   |", row(2))
    keys("p")
    eq(":Effort:   1:00", buf_lines(buf)[5])
    keys("1")
    eq(":Effort:   0:30", buf_lines(buf)[5])
    -- the cursor stays in the column
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
    eq(23, vim.fn.virtcol("."))
    -- S-Right on the TODO column cycles the keyword
    cursor(3, 16)
    keys("<S-Right>")
    eq("** TODO Sub A", buf_lines(buf)[3])
  end)

  it("e edits the value and v shows it", function()
    local buf = org_buffer(lines, { 1, 0 })
    columns.open()
    cursor(8, 23)
    local input, notify = utils.input, utils.notify
    local shown, default
    utils.input = function(o)
      default = o.default
      return "2:00"
    end
    utils.notify = function(msg)
      shown = msg
    end
    keys("v")
    keys("e")
    utils.input, utils.notify = input, notify
    eq("0:30", default)
    eq("Effort: 0:30", shown)
    eq(":Effort:   2:00", buf_lines(buf)[10])
    eq("** Sub B     | DONE | 2:00   |", row(8))
  end)

  it("> widens and M-Right moves the column, storing the format", function()
    local buf = org_buffer(lines, { 1, 0 })
    columns.open()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    keys(">")
    eq("#+COLUMNS: %13ITEM %TODO %Effort{:}", buf_lines(buf)[1])
    eq("* Project     | TODO | 1:30   |", row(2))
    keys("<M-Right>")
    eq("#+COLUMNS: %TODO %13ITEM %Effort{:}", buf_lines(buf)[1])
    eq("TODO | * Project     | 1:30   |", row(2))
    -- the cursor followed the column
    ok(vim.fn.virtcol(".") > 7)
  end)

  it("follows the headlines when the text changes", function()
    local buf = org_buffer(lines, { 1, 0 })
    columns.open()
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "New line" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    vim.wait(100, function()
      return row(3) ~= nil and row(2) == nil
    end)
    eq(nil, row(2))
    eq("* Project    | TODO | 1:30   |", row(3))
  end)

  it("quits when the buffer leaves the window", function()
    org_buffer(lines, { 1, 0 })
    columns.open()
    vim.cmd("enew!")
    eq("", vim.wo.winbar)
    eq(true, vim.wo.wrap)
  end)

  it("columns_view = table shows the table buffer", function()
    org_buffer(lines, { 1, 0 })
    local saved = config.opts.columns_view
    config.opts.columns_view = "table"
    columns.open()
    config.opts.columns_view = saved
    eq("orgcolumns", vim.bo.filetype)
    vim.api.nvim_win_close(0, true)
  end)
end)
