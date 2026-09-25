local tbl = require("org.table")
local utils = require("org.utils")

--- Run `fn` with utils.input stubbed to return `value` (records the opts).
local function with_input(value, fn)
  local orig = utils.input
  local seen
  utils.input = function(opts)
    seen = opts
    return value
  end
  local ok_, err = pcall(fn)
  utils.input = orig
  if not ok_ then
    error(err, 0)
  end
  return seen
end

--- Silence notifications, returning the collected messages.
local function capture_notify(fn)
  local orig = utils.notify
  local msgs = {}
  utils.notify = function(msg)
    msgs[#msgs + 1] = msg
  end
  local ok_, err = pcall(fn)
  utils.notify = orig
  if not ok_ then
    error(err, 0)
  end
  return msgs
end

--- Run `fn` from a visual-mode mapping after typing `keys` in normal mode.
local function in_visual(keys, fn)
  vim.keymap.set("x", "<F12>", fn, { buffer = 0 })
  vim.api.nvim_feedkeys(vim.keycode(keys .. "<F12>"), "x", false)
  vim.keymap.del("x", "<F12>", { buffer = 0 })
end

describe("table emacs commands", function()
  it("returns false outside tables", function()
    org_buffer({ "text" }, { 1, 0 })
    eq(false, tbl.eval_formula())
    eq(false, tbl.edit_field())
    eq(false, tbl.sum())
    eq(false, tbl.blank_field())
    eq(false, tbl.hline_and_move())
    eq(false, tbl.field_info())
    eq(false, tbl.toggle_coordinate_overlays())
    eq(false, tbl.copy_region())
    eq(false, tbl.cut_region())
    eq(false, tbl.paste_rectangle())
  end)

  it("eval_formula stores a column formula and computes the field", function()
    local buf = org_buffer({ "| a | b | c |", "|---+---+---|", "| 1 | 2 |   |", "| 3 | 4 |   |" }, { 3, 10 })
    local seen = with_input("$1+$2", function()
      tbl.eval_formula()
    end)
    eq("Column formula $3=", seen.prompt)
    eq("", seen.default)
    eq({
      "| a | b | c |",
      "|---+---+---|",
      "| 1 | 2 | 3 |",
      "| 3 | 4 |   |",
      "#+TBLFM: $3=$1+$2",
    }, buf_lines(buf))
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
    -- default is the existing formula; replacing keeps a single entry
    seen = with_input("$1*$2", function()
      tbl.eval_formula()
    end)
    eq("$1+$2", seen.default)
    eq("| 1 | 2 | 2 |", buf_lines(buf)[3])
    eq("#+TBLFM: $3=$1*$2", buf_lines(buf)[5])
  end)

  it("eval_formula with a count stores a field formula", function()
    local buf = org_buffer({ "| 1 |   |", "| 2 |   |", "#+TBLFM: $2=$1" }, { 2, 6 })
    local seen = with_input("99", function()
      tbl.eval_formula(true)
    end)
    eq("Field formula @2$2=", seen.prompt)
    eq({ "| 1 |    |", "| 2 | 99 |", "#+TBLFM: $2=$1::@2$2=99" }, buf_lines(buf))
    -- empty input removes it
    with_input("", function()
      tbl.eval_formula(true)
    end)
    eq("#+TBLFM: $2=$1", buf_lines(buf)[3])
  end)

  it("edit_field replaces the field content", function()
    local buf = org_buffer({ "| a | b |", "| c | d |" }, { 2, 6 })
    local seen = with_input("long | text", function()
      tbl.edit_field()
    end)
    eq("d", seen.default)
    eq({ "| a | b                 |", "| c | long \\vert{} text |" }, buf_lines(buf))
    eq({ 2, 6 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("sum adds the current column", function()
    org_buffer({ "| n  | t    |", "|----+------|", "| 1  | 1:30 |", "| 2.5 | 0:45 |", "| x  |      |" }, { 3, 2 })
    local msgs = capture_notify(function()
      eq("3.5", tbl.sum())
    end)
    eq("Sum of 2 items: 3.5", msgs[1])
    eq("3.5", vim.fn.getreg('"'))
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    capture_notify(function()
      eq("2:15:00", tbl.sum())
    end)
  end)

  it("sum includes the header rows and counts numbers as hours next to times", function()
    -- Emacs org-table-sum: the whole column, 13 / 3:30:00 / 2:00:10
    org_buffer({ "| 10 |", "|----|", "| 1  |", "| 2  |" }, { 3, 2 })
    capture_notify(function()
      eq("13", tbl.sum())
    end)
    org_buffer({ "| 1:30 |", "| 2    |" }, { 1, 2 })
    capture_notify(function()
      eq("3:30:00", tbl.sum())
    end)
    org_buffer({ "| 1:30:10 |", "| 0:30    |" }, { 1, 2 })
    capture_notify(function()
      eq("2:00:10", tbl.sum())
    end)
    org_buffer({ "| 1.1 |", "| 3   |" }, { 1, 2 })
    capture_notify(function()
      eq("4.1", tbl.sum())
    end)
  end)

  it("sum works on a visual block", function()
    org_buffer({ "| 1 | 2 | 3 |", "| 4 | 5 | 6 |" }, { 1, 2 })
    capture_notify(function()
      in_visual("<C-v>j4l", function()
        tbl.sum()
      end)
    end)
    eq("12", vim.fn.getreg('"'))
  end)

  it("blank_field blanks the field or a selection", function()
    local buf = org_buffer({ "| a | b |", "| c | d |" }, { 1, 2 })
    tbl.blank_field()
    eq({ "|   | b |", "| c | d |" }, buf_lines(buf))
    in_visual("Vj", function()
      tbl.blank_field()
    end)
    eq({ "|   |   |", "|   |   |" }, buf_lines(buf))
  end)

  it("hline_and_move inserts an hline and a new row", function()
    local buf = org_buffer({ "| a | b |" }, { 1, 6 })
    tbl.hline_and_move()
    eq({ "| a | b |", "|---+---|", "|   |   |" }, buf_lines(buf))
    eq({ 3, 2 }, vim.api.nvim_win_get_cursor(0))
    -- moves into an existing row below
    buf = org_buffer({ "| a | b |", "| c | d |" }, { 1, 6 })
    tbl.hline_and_move(true)
    eq({ "| a | b |", "|---+---|", "| c | d |" }, buf_lines(buf))
    eq({ 3, 6 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("field_info reports references and formulas", function()
    org_buffer({ "| h | x |", "|---+---|", "| 1 |   |", "#+TBLFM: $2=$1*2" }, { 3, 6 })
    local msgs = capture_notify(function()
      tbl.field_info()
    end)
    eq("line @2, col $2, ref @2$2 or B2, formula: $2=$1*2", msgs[1])
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    msgs = capture_notify(function()
      tbl.field_info()
    end)
    eq("line @1, col $2, ref @1$2 or B1", msgs[1])
  end)

  it("toggles coordinate overlays", function()
    local buf = org_buffer({ "| a | bb |", "|---+----|", "| c | d  |" }, { 1, 2 })
    local ns = vim.api.nvim_create_namespace("org.table.coordinates")
    tbl.toggle_coordinate_overlays()
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    eq(3, #marks)
    local texts = {}
    for _, m in ipairs(marks) do
      local d = m[4]
      if d.virt_text then
        texts[#texts + 1] = d.virt_text[1][1]
      else
        eq("  $1  $2", d.virt_lines[1][1][1])
      end
    end
    eq({ "@1", "@2" }, texts)
    tbl.toggle_coordinate_overlays()
    eq({}, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
  end)

  it("copies, cuts and pastes rectangles", function()
    local buf = org_buffer({ "| 1 | 2 | 3 |", "|---+---+---|", "| 4 | 5 | 6 |" }, { 1, 6 })
    in_visual("<C-v>2j4l", function()
      tbl.copy_region()
    end)
    eq({ { "2", "3" }, { "5", "6" } }, tbl.clipboard)
    -- paste at the last column: adds a column, skips the hline, adds a row
    vim.api.nvim_win_set_cursor(0, { 3, 10 })
    tbl.paste_rectangle()
    eq({ "| 1 | 2 | 3 |   |", "|---+---+---+---|", "| 4 | 5 | 2 | 3 |", "|   |   | 5 | 6 |" }, buf_lines(buf))
    eq({ 3, 10 }, vim.api.nvim_win_get_cursor(0))
    -- cut in normal mode acts on the current field
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    tbl.cut_region()
    eq({ { "1" } }, tbl.clipboard)
    eq("|   | 2 | 3 |   |", buf_lines(buf)[1])
  end)

  it("recalc_buffer recalculates every table", function()
    local buf = org_buffer({
      "| 1 |   |",
      "#+TBLFM: $2=$1*10",
      "",
      "text",
      "| 2 |   |",
      "#+TBLFM: $2=$1+1",
      "| no | formulas |",
    }, { 4, 0 })
    tbl.recalc_buffer()
    eq({
      "| 1 | 10 |",
      "#+TBLFM: $2=$1*10",
      "",
      "text",
      "| 2 | 3 |",
      "#+TBLFM: $2=$1+1",
      "| no | formulas |",
    }, buf_lines(buf))
  end)
end)
