-- Table editing and recalculation compared with Emacs Org 9.8.10: every
-- expected buffer is what the Emacs command produced on the same input.
local tbl = require("org.table")
local utils = require("org.utils")

local function quiet(fn)
  local notify, warn = utils.notify, utils.warn
  utils.notify, utils.warn = function() end, function() end
  local ok, err = pcall(fn)
  utils.notify, utils.warn = notify, warn
  if not ok then
    error(err, 0)
  end
end

--- Put the cursor in field `col` of line `line` and run `fn`.
local function at(lines, line, col, fn)
  local buf = org_buffer(lines)
  local s, n, pos = lines[line], 0, 0
  for i = 1, #s do
    if s:sub(i, i) == "|" then
      n = n + 1
      if n == col then
        pos = i + 1
        break
      end
    end
  end
  vim.api.nvim_win_set_cursor(0, { line, pos })
  quiet(fn)
  return buf_lines(buf)
end

describe("table formulas are fixed after structure edits (org-table-fix-formulas)", function()
  it("deleting a column invalidates and shifts references", function()
    local out = at({ "| a | b | c |", "| 1 | 2 | 3 |", "#+TBLFM: $3=$1+$2" }, 2, 1, tbl.delete_column)
    eq({ "| b | c |", "| 2 | 3 |", "#+TBLFM: $2=$INVALID+$1" }, out)
  end)

  it("inserting a column shifts the columns from there on", function()
    local out = at({ "| a | b | c |", "| 1 | 2 | 3 |", "#+TBLFM: $3=$1+$2::@2$2=@1$1" }, 2, 2, tbl.insert_column)
    eq({ "| a |   | b | c |", "| 1 |   | 2 | 3 |", "#+TBLFM: $4=$1+$3::@2$3=@1$1" }, out)
  end)

  it("moving a column swaps references, field formulas included", function()
    local out = at({ "| a | b | c |", "| 1 | 2 | 3 |", "#+TBLFM: $3=$1*2" }, 2, 1, function()
      tbl.move_column(1)
    end)
    eq({ "| b | a | c |", "| 2 | 1 | 3 |", "#+TBLFM: $3=$2*2" }, out)
    out = at({ "| a | b | c |", "| 1 | 2 | 3 |", "#+TBLFM: @1$2=$1*2::$3=$2" }, 2, 2, function()
      tbl.move_column(1)
    end)
    eq("#+TBLFM: @1$3=$1*2::$2=$3", out[3])
  end)

  it("moving, inserting and killing rows fixes row references", function()
    local lines = { "| a | b |", "| 1 | 2 |", "| 3 | 4 |", "#+TBLFM: @3$2=@2$1*10" }
    eq("#+TBLFM: @3$2=@1$1*10", at(lines, 1, 1, function()
      tbl.move_row(1)
    end)[4])
    eq("#+TBLFM: @4$2=@3$1*10", at(lines, 2, 1, function()
      tbl.insert_row(true)
    end)[5])
    eq("#+TBLFM: @2$2=@1$1*10", at(lines, 1, 1, tbl.delete_row)[3])
  end)

  it("killing a row removes the formulas assigning to it", function()
    local out = at({ "| 1 | |", "| 2 | |", "#+TBLFM: @2$2=7::@1$2=@2$1" }, 2, 1, tbl.delete_row)
    eq({ "| 1 |   |", "#+TBLFM: @1$2=@INVALID$1" }, out)
  end)

  it("every #+TBLFM line is fixed, remote references are left alone", function()
    local out = at({
      "| a | b |",
      "| 1 | 2 |",
      "#+TBLFM: $2=$1*2",
      "#+TBLFM: $2=remote(t,@1$1)+$1",
    }, 2, 1, tbl.insert_column)
    eq("#+TBLFM: $3=$2*2", out[3])
    eq("#+TBLFM: $3=remote(t,@1$1)+$2", out[4])
  end)

  describe("with table_fix_formulas_confirm", function()
    with_config({ table_fix_formulas_confirm = true })
    it("asks first", function()
      local confirm = utils.confirm
      utils.confirm = function()
        return false
      end
      local out = at({ "| a | b |", "| 1 | 2 |", "#+TBLFM: $2=$1" }, 2, 1, tbl.insert_column)
      utils.confirm = confirm
      eq("#+TBLFM: $2=$1", out[3])
    end)
  end)

  it("a new row copies the # mark of the current row", function()
    local out = at({ "| # | 1 |", "#+TBLFM: $2=1" }, 1, 2, function()
      tbl.insert_row(false)
    end)
    eq({ "| # | 1 |", "| # |   |", "#+TBLFM: $2=1" }, out)
  end)
end)

describe("multiple #+TBLFM lines", function()
  local lines = { "| 1 | | |", "#+TBLFM: $2=$1*2", "#+TBLFM: $3=$1*3" }

  it("only the first line applies", function()
    local buf = org_buffer(lines)
    tbl.recalc(buf, 1)
    eq("| 1 | 2 |   |", buf_lines(buf)[1])
  end)

  it("C-c C-c on another line applies that one (org-table-calc-current-TBLFM)", function()
    local buf = org_buffer(lines, { 3, 0 })
    tbl.calc_current_tblfm(buf, 3)
    eq("| 1 |   | 3 |", buf_lines(buf)[1])
    eq(lines[2], buf_lines(buf)[2])
    eq(lines[3], buf_lines(buf)[3])
  end)

  it("storing a formula rewrites only the first line", function()
    local buf = org_buffer(lines, { 1, 6 })
    local input = utils.input
    utils.input = function()
      return "$1+10"
    end
    quiet(function()
      tbl.eval_formula(false)
    end)
    utils.input = input
    eq({ "| 1 | 11 |   |", "#+TBLFM: $2=$1+10", "#+TBLFM: $3=$1*3" }, buf_lines(buf))
  end)

  it("stored formulas are sorted like Emacs", function()
    eq({ "$2=1", "$10=1", "$>=1", "@2$1=1", "@10$1=1" }, tbl.sort_formulas({ "$>=1", "@10$1=1", "$10=1", "@2$1=1", "$2=1" }))
  end)
end)

describe("C-c * (org-table-recalculate)", function()
  local lines = { "| 1 |   |", "| 2 |   |", "#+TBLFM: $2=$1*10::@1$1=5" }

  it("recalculates the current row; field formulas always run", function()
    local buf = org_buffer(lines, { 2, 2 })
    quiet(function()
      tbl.recalculate(0)
    end)
    eq({ "| 5 |    |", "| 2 | 20 |" }, { buf_lines(buf)[1], buf_lines(buf)[2] })
  end)

  it("count 4 recalculates the table, 16 iterates", function()
    local buf = org_buffer(lines, { 2, 2 })
    quiet(function()
      tbl.recalculate(4)
    end)
    -- one pass: row 1 used the old @1$1
    eq({ "| 5 | 10 |", "| 2 | 20 |" }, { buf_lines(buf)[1], buf_lines(buf)[2] })
    buf = org_buffer(lines, { 2, 2 })
    quiet(function()
      tbl.recalculate(16)
    end)
    eq({ "| 5 | 50 |", "| 2 | 20 |" }, { buf_lines(buf)[1], buf_lines(buf)[2] })
  end)

  it("a column formula beyond the table adds the column", function()
    local buf = org_buffer({ "| 1 |", "#+TBLFM: $3=$1" })
    tbl.recalc(buf, 1)
    eq("| 1 |   | 1 |", buf_lines(buf)[1])
  end)

  it("a field formula beyond the table is an error unless table_formula_create_columns", function()
    local buf = org_buffer({ "| 1 |", "#+TBLFM: @1$3=$1" })
    local err = utils.error
    local seen
    utils.error = function(m)
      seen = m
    end
    tbl.recalc(buf, 1)
    utils.error = err
    eq("| 1 |", buf_lines(buf)[1])
    ok(seen and seen:find("Missing columns"))
  end)

  describe("with table_formula_create_columns = true", function()
    with_config({ table_formula_create_columns = true })
    it("adds the columns", function()
      local buf = org_buffer({ "| 1 |", "#+TBLFM: @1$3=$1" })
      tbl.recalc(buf, 1)
      eq("| 1 |   | 1 |", buf_lines(buf)[1])
    end)
  end)

  it("with marks (! $ ^ _ # *) only # and * rows get column formulas", function()
    local buf = org_buffer({ "| ! | a | b |", "|---+---+---|", "|   | 1 |   |", "| # | 2 |   |", "#+TBLFM: $3=$2*2" })
    tbl.recalc(buf, 1)
    eq({ "|   | 1 |   |", "| # | 2 | 4 |" }, { buf_lines(buf)[3], buf_lines(buf)[4] })
  end)

  it("named fields keep their value from before the recalculation", function()
    local buf = org_buffer({ "| 1 | 5 | |", "| ^ | x | |", "#+TBLFM: @1$2=10::@1$3=$x" })
    tbl.recalc(buf, 1)
    eq("| 1 | 10 | 5 |", buf_lines(buf)[1])
  end)
end)

describe("sorting (org-table-sort-lines)", function()
  it("sorts text without emphasis and link markup, case-insensitively", function()
    local out = at({ "| C |", "| *b* |", "| [[x][a]] |", "| B |" }, 1, 1, function()
      tbl.sort_column({ type = "a" })
    end)
    local order = {}
    for i, l in ipairs(out) do
      order[i] = vim.trim(l:sub(2, -2))
    end
    eq({ "[[x][a]]", "*b*", "B", "C" }, order)
  end)

  it("sorts case-sensitively with with_case (C-u)", function()
    local out = at({ "| b |", "| B |", "| a |" }, 1, 1, function()
      tbl.sort_column({ type = "a", with_case = true })
    end)
    eq({ "| B |", "| a |", "| b |" }, out)
  end)

  it("sorts numerically within the hline section", function()
    local out = at({ "| h |", "|---|", "| 10 |", "| 9 |", "| abc |", "| -2 |", "|---|", "| 1 |" }, 3, 1, function()
      tbl.sort_column({ type = "n" })
    end)
    eq({ "|   h |", "|-----|", "|  -2 |", "| abc |", "|   9 |", "|  10 |", "|-----|", "|   1 |" }, out)
  end)

  it("sorts with a key function (f / F)", function()
    local out = at({ "| ccc |", "| a |", "| bb |" }, 1, 1, function()
      tbl.sort_column({
        type = "F",
        getkey = function(s)
          return #s
        end,
      })
    end)
    eq({ "| ccc |", "| bb  |", "| a   |" }, out)
  end)

  it("sorts only the rows of a visual selection", function()
    local buf = org_buffer({ "| 3 |", "| 2 |", "| 1 |", "| 0 |" }, { 2, 2 })
    vim.cmd("normal! Vj")
    quiet(function()
      tbl.sort_column({ type = "n" })
    end)
    eq({ "| 3 |", "| 1 |", "| 2 |", "| 0 |" }, buf_lines(buf))
  end)
end)

describe("alignment (org-table-align)", function()
  it("aligns cookie cells like the column and counts <N> as text", function()
    eq({ "|  <r> | <l>  |  <c>   |", "|    a | 1    |   x    |", "| bbbb | 2222 | yyyyyy |" }, tbl.render(tbl.parse({
      "| <r> | <l> | <c> |",
      "| a | 1 | x |",
      "| bbbb | 2222 | yyyyyy |",
    })))
    eq({ "|       <r5> |", "| abcdefghij |", "|          a |" }, tbl.render(tbl.parse({ "| <r5> |", "| abcdefghij |", "| a |" })))
    eq({ "| <5>   |", "| Short |", "| 1     |" }, tbl.render(tbl.parse({ "| <5> |", "| Short |", "| 1 |" })))
  end)
end)
