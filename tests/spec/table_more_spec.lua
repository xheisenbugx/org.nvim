local tbl = require("org.table")
local utils = require("org.utils")

local function keys(k)
  vim.api.nvim_feedkeys(vim.keycode(k), "xt", false)
end

--- Run `fn` with a utils function replaced by `stub`.
local function with_stub(name, stub, fn)
  local orig = utils[name]
  utils[name] = stub
  local ok_, err = pcall(fn)
  utils[name] = orig
  if not ok_ then
    error(err, 0)
  end
end

local function quiet(fn)
  with_stub("notify", function() end, fn)
end

describe("table inline formulas", function()
  it("<Tab> installs a column formula typed as =...", function()
    local buf = org_buffer({ "| a | b | c |", "|---+---+---|", "| 1 | 2 |   |", "| 3 | 4 |   |" }, { 3, 10 })
    keys("a=$1+$2<Tab><Esc>")
    eq({
      "| a | b | c |",
      "|---+---+---|",
      "| 1 | 2 | 3 |",
      "| 3 | 4 | 7 |",
      "#+TBLFM: $3=$1+$2",
    }, buf_lines(buf))
    -- the cursor moved on to the next row
    eq(4, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("C-c C-c installs a field formula typed as :=...", function()
    local buf = org_buffer({ "| 1 |      |", "| 2 | :=vsum(@1$1..@2$1) |", "#+TBLFM: $2=$1*10" }, { 2, 8 })
    keys("<C-c><C-c>")
    eq({ "| 1 | 10 |", "| 2 |  3 |", "#+TBLFM: $2=$1*10::@2$2=vsum(@1$1..@2$1)" }, buf_lines(buf))
  end)

  it("<CR> replaces an existing formula for the same column", function()
    local buf = org_buffer({ "| 2 | =$1*3 |", "| 5 |       |", "#+TBLFM: $2=$1" }, { 1, 8 })
    keys("a<CR><Esc>")
    eq({ "| 2 |  6 |", "| 5 | 15 |", "#+TBLFM: $2=$1*3" }, buf_lines(buf))
  end)

  it("<Tab> in a # row recalculates the table", function()
    local buf = org_buffer({ "| # | 2 | 0 |", "|   | 5 | 0 |", "#+TBLFM: $3=$2*2" }, { 1, 6 })
    keys("a<Tab><Esc>")
    eq({ "| # | 2 | 4 |", "|   | 5 | 0 |", "#+TBLFM: $3=$2*2" }, buf_lines(buf))
  end)

  it("a lone = or text is left alone", function()
    local buf = org_buffer({ "| a=b | = |" }, { 1, 2 })
    keys("<C-c><C-c>")
    eq({ "| a=b | = |" }, buf_lines(buf))
  end)
end)

describe("table copy down", function()
  it("increments_field handles numbers, affixes and dates", function()
    eq("4", tbl.increment_field("3", nil, 1))
    eq("5", tbl.increment_field("3", "1", 1))
    eq("2.5", tbl.increment_field("1.5", nil, 1))
    eq("item-3", tbl.increment_field("item-2", "item-1", 1))
    eq("4 apples", tbl.increment_field("3 apples", nil, 1))
    eq("<2026-09-25 Fri>", tbl.increment_field("<2026-09-24 Thu>", nil, 1))
    eq("[2026-10-01 Thu]", tbl.increment_field("[2026-09-24 Thu]", "[2026-09-17 Thu]", 1))
    eq("text", tbl.increment_field("text", nil, 1))
  end)

  it("S-RET copies the field down with increment and follows it", function()
    local buf = org_buffer({ "| n |", "|---|", "| 1 |", "| 2 |" }, { 4, 2 })
    keys("<S-CR>")
    eq({ "| n |", "|---|", "| 1 |", "| 2 |", "| 3 |" }, buf_lines(buf))
    eq(5, vim.api.nvim_win_get_cursor(0)[1])
    keys("<S-CR>")
    eq("| 4 |", buf_lines(buf)[6])
  end)

  it("fills an empty field from the nearest non-empty field above", function()
    local buf = org_buffer({ "| a | x |", "|   | y |", "|   | z |" }, { 3, 2 })
    tbl.copy_down()
    eq("| a | z |", buf_lines(buf)[3])
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("uses a fixed step, or none, with table_copy_increment", function()
    local opts = require("org.config").opts
    local saved = opts.table_copy_increment
    opts.table_copy_increment = 10
    local buf = org_buffer({ "| 1 |", "| 2 |" }, { 2, 2 })
    tbl.copy_down()
    eq("| 12 |", buf_lines(buf)[3])
    opts.table_copy_increment = false
    tbl.copy_down()
    eq("| 12 |", buf_lines(buf)[4])
    opts.table_copy_increment = saved
  end)

  it("S-RET falls back outside tables", function()
    local buf = org_buffer({ "text", "more" }, { 1, 0 })
    keys("<S-CR>")
    eq({ "text", "more" }, buf_lines(buf))
    eq(2, vim.api.nvim_win_get_cursor(0)[1])
  end)
end)

describe("table cell moves and transposition", function()
  it("S-arrows swap the field with its neighbour", function()
    local buf = org_buffer({ "| a | b |", "|---+---|", "| c | d |" }, { 1, 2 })
    keys("<S-Down>")
    eq({ "| c | b |", "|---+---|", "| a | d |" }, buf_lines(buf))
    eq(3, vim.api.nvim_win_get_cursor(0)[1])
    keys("<S-Right>")
    eq({ "| c | b |", "|---+---|", "| d | a |" }, buf_lines(buf))
    eq(6, vim.api.nvim_win_get_cursor(0)[2])
    keys("<S-Up>")
    eq({ "| c | a |", "|---+---|", "| d | b |" }, buf_lines(buf))
    keys("<S-Left>")
    eq({ "| a | c |", "|---+---|", "| d | b |" }, buf_lines(buf))
  end)

  it("move_cell refuses to leave the table", function()
    local buf = org_buffer({ "| a | b |" }, { 1, 2 })
    local warned
    with_stub("warn", function(m)
      warned = m
    end, function()
      tbl.move_cell("left")
      tbl.move_cell("up")
    end)
    eq("Cannot move cell further", warned)
    eq({ "| a | b |" }, buf_lines(buf))
  end)

  it("transposes a table and drops hlines", function()
    local buf = org_buffer({ "| 1 | 2 | 3 |", "|---+---+---|", "| a | b | c |" }, { 3, 6 })
    tbl.transpose()
    eq({ "| 1 | a |", "| 2 | b |", "| 3 | c |" }, buf_lines(buf))
    eq({ 2, 6 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("C-c - with a count inserts the hline above", function()
    local buf = org_buffer({ "| a |", "| b |" }, { 2, 2 })
    keys("4<C-c>-")
    eq({ "| a |", "|---|", "| b |" }, buf_lines(buf))
  end)
end)

describe("table recalculation marks", function()
  it("adds a marker column and rotates the mark", function()
    local buf = org_buffer({ "| x | 1 |", "| y | 2 |" }, { 1, 2 })
    quiet(function()
      eq("#", tbl.rotate_recalc_marks())
    end)
    eq({ "| # | x | 1 |", "|   | y | 2 |" }, buf_lines(buf))
    local seq = {}
    quiet(function()
      for _ = 1, 7 do
        seq[#seq + 1] = tbl.rotate_recalc_marks()
      end
    end)
    eq({ "*", "!", "$", "_", "^", " ", "#" }, seq)
    eq({ "| # | x | 1 |", "|   | y | 2 |" }, buf_lines(buf))
  end)

  it("sets a given mark", function()
    local buf = org_buffer({ "| # | 1 |", "|   | 2 |" }, { 2, 2 })
    quiet(function()
      tbl.rotate_recalc_marks("*")
    end)
    eq({ "| # | 1 |", "| * | 2 |" }, buf_lines(buf))
  end)
end)

describe("table import / export", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

  it("converts with an N-spaces separator", function()
    eq({ "| a b | c |", "| d   | e |" }, tbl.convert_lines({ "a b   c", "d  e" }, 2))
    eq("csv", tbl.separator_for_count(4))
    eq("tab", tbl.separator_for_count(16))
    eq(nil, tbl.separator_for_count(0))
  end)

  it("imports a file as a table", function()
    local path = dir .. "/in.csv"
    utils.writefile(path, { "name,qty", "apple,3" })
    local buf = org_buffer({ "before", "" }, { 2, 0 })
    tbl.import(path)
    eq({ "before", "| name  | qty |", "| apple |   3 |" }, buf_lines(buf))
  end)

  it("exports a table to TSV and CSV", function()
    org_buffer({ "| a | b, c |", "|---+------|", '| 1 | "q"  |' }, { 1, 2 })
    local tsv = dir .. "/out.tsv"
    quiet(function()
      eq(tsv, tbl.export(tsv))
    end)
    eq({ "a\tb, c", '1\t"q"' }, utils.readfile(tsv))
    local csv = dir .. "/out.csv"
    quiet(function()
      tbl.export(csv)
    end)
    eq({ 'a,"b, c"', '1,"""q"""' }, utils.readfile(csv))
  end)

  it("exports to TABLE_EXPORT_FILE with TABLE_EXPORT_FORMAT", function()
    local path = dir .. "/prop.txt"
    org_buffer({
      "* Data",
      ":PROPERTIES:",
      ":TABLE_EXPORT_FILE: " .. path,
      ":TABLE_EXPORT_FORMAT: orgtbl-to-csv",
      ":END:",
      "| x | y |",
    }, { 6, 2 })
    quiet(function()
      tbl.export()
    end)
    eq({ "x,y" }, utils.readfile(path))
  end)

  it("returns false outside tables", function()
    org_buffer({ "text" }, { 1, 0 })
    eq(false, tbl.export())
    eq(false, tbl.copy_down())
    eq(false, tbl.move_cell("up"))
    eq(false, tbl.transpose())
    eq(false, tbl.rotate_recalc_marks())
    eq(false, tbl.ctrl_c_ctrl_c())
  end)
end)
