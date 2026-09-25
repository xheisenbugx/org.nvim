-- Follow-field mode, header-line mode, the formula debugger and the C-c
-- keys dispatching to table commands.
local tbl = require("org.table")
local follow = require("org.table.follow")
local utils = require("org.utils")

local function quiet(fn)
  local notify, warn = utils.notify, utils.warn
  utils.notify, utils.warn = function() end, function() end
  local ok_, err = pcall(fn)
  utils.notify, utils.warn = notify, warn
  if not ok_ then
    error(err, 0)
  end
end

describe("follow-field mode (C-u C-u C-c `)", function()
  it("shows the current field, follows the cursor and writes edits back", function()
    local buf = org_buffer({ "| a | long text |", "| c | d |", "", "after" }, { 1, 6 })
    quiet(function()
      tbl.edit_field(16)
    end)
    local st = follow.state(buf)
    ok(st)
    eq({ "long text" }, vim.api.nvim_buf_get_lines(st.buf, 0, -1, false))
    vim.api.nvim_win_set_cursor(0, { 2, 2 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    eq({ "c" }, vim.api.nvim_buf_get_lines(st.buf, 0, -1, false))
    vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, { "new | value" })
    vim.bo[st.buf].modified = true
    -- leaving the table writes the field back and ends the mode
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    quiet(function()
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    end)
    eq(nil, follow.state(buf))
    eq("| new \\vert{} value | d         |", buf_lines(buf)[2])
  end)

  it("count 4 shows a shrunk column in full", function()
    local buf = org_buffer({ "| <2> |", "| abcdef |" }, { 2, 2 })
    tbl.shrink(buf, 1)
    eq({ [1] = true }, require("org.table.shrink").get(buf, 1))
    tbl.edit_field(4)
    eq({}, require("org.table.shrink").get(buf, 1))
  end)
end)

describe("header-line mode", function()
  it("shows the first row in the winbar while it is scrolled away", function()
    local lines = { "| head | x |", "|------+---|" }
    for i = 1, 60 do
      lines[#lines + 1] = "| " .. i .. " | y |"
    end
    local buf = org_buffer(lines, { 1, 0 })
    quiet(function()
      tbl.header_line_mode()
    end)
    vim.cmd("normal! 40Gzt")
    follow.refresh_header(buf)
    ok(vim.wo.winbar:find("| head | x |", 1, true))
    vim.cmd("normal! ggzt")
    follow.refresh_header(buf)
    eq("", vim.wo.winbar)
    quiet(function()
      tbl.header_line_mode()
    end)
  end)
end)

describe("formula debugger (C-c {)", function()
  it("shows each substitution and can abort", function()
    local buf = org_buffer({ "| 2 | |", "| 3 | |", "#+TBLFM: $2=$1*10;%.1f" })
    quiet(function()
      eq(true, tbl.toggle_formula_debugger())
    end)
    local confirm = utils.confirm
    local steps = 0
    utils.confirm = function()
      steps = steps + 1
      return false
    end
    tbl.recalc(buf, 1)
    utils.confirm = confirm
    quiet(function()
      eq(false, tbl.toggle_formula_debugger())
    end)
    eq(1, steps)
    eq({
      "Substitution history of formula",
      "Orig:   $1*10",
      "$xyz->  $1*10",
      "@r$c->  (2)*10",
      "$1->    (2)*10",
      "Result: 20",
      "Format: %.1f",
      "Final:  20.0",
    }, tbl.debug_history)
    -- aborted after the first field (like Emacs, it stays computed)
    eq({ "| 2 | 20.0 |", "| 3 |      |" }, { buf_lines(buf)[1], buf_lines(buf)[2] })
  end)
end)

describe("C-c TAB", function()
  it("shrinks the table column in a table and shows children elsewhere", function()
    local buf = org_buffer({ "| abc |" }, { 1, 2 })
    require("org.context").ctrl_c_tab()
    eq({ [1] = true }, require("org.table.shrink").get(buf, 1))
  end)
end)
