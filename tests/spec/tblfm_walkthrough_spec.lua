-- Spreadsheet walkthrough: each case blanks the computed fields, recalculates
-- and compares every field with the expected table.
local tbl = require("org.table")
local F = {}
local function add(name, blank, text)
  F[#F + 1] = { name = name, blank = blank, lines = vim.split(text, "\n", { trimempty = true }) }
end
-- blank: list of {r1, r2, c} over DATA rows (hlines excluded, 1-based)
add("1 simple", { { 2, 2, 3 } }, [[
| A | B | Result |
|---+---+--------|
| 2 | 3 |      5 |
#+TBLFM: @2$3=$1+$2]])
add("2 range", { { 2, 4, 3 } }, [[
| A  | B | Result |
|----+---+--------|
| 10 | 2 |     20 |
| 20 | 3 |     60 |
| 30 | 4 |    120 |
#+TBLFM: @2$3..@4$3=$1*$2]])
add("3 ops", { { 2, 3, 3 }, { 2, 3, 4 }, { 2, 3, 5 }, { 2, 3, 6 } }, [[
| A   | B  | Add | Sub | Mul | Div |
|-----+----+-----+-----+-----+-----|
| 100 | 20 | 120 |  80 | 2000 |   5 |
|  50 | 10 |  60 |  40 |  500 |   5 |
#+TBLFM: @2$3..@3$3=$1+$2::@2$4..@3$4=$1-$2::@2$5..@3$5=$1*$2::@2$6..@3$6=$1/$2]])
add("4 shopping", { { 2, 5, 4 } }, [[
| Item     | Qty | Price | Total |
|----------+-----+-------+-------|
| Coffee   |   3 |   4.5 |  13.5 |
| Keyboard |   1 |   120 |   120 |
| Stickers |  10 |   0.8 |     8 |
|----------+-----+-------+-------|
| Sum      |     |       | 141.5 |
#+TBLFM: @2$4..@4$4=$2*$3::@5$4=vsum(@2..@4)]])
add("5 vsum", { { 6, 6, 2 } }, [[
| Item | Value |
|------+-------|
| A    |    10 |
| B    |    20 |
| C    |    30 |
| D    |    40 |
|------+-------|
| Sum  |   100 |
#+TBLFM: @6$2=vsum(@2..@5)]])
add("6 vmean", { { 5, 5, 2 } }, [[
| Test    | Score |
|---------+-------|
| Test 1  |    80 |
| Test 2  |    90 |
| Test 3  |   100 |
|---------+-------|
| Average |    90 |
#+TBLFM: @5$2=vmean(@2..@4)]])
add("7a percent", { { 2, 4, 4 } }, [[
| Item | Completed | Total | Percent |
|------+-----------+-------+---------|
| A    |        80 |   100 |      80 |
| B    |        45 |    50 |      90 |
| C    |        30 |    40 |      75 |
#+TBLFM: @2$4..@4$4=100*$2/$3]])
add("7b percent fmt", { { 2, 4, 4 } }, [[
| Item | Completed | Total | Percent |
|------+-----------+-------+---------|
| A    |        80 |   100 |   80.0% |
| B    |        45 |    50 |   90.0% |
| C    |        30 |    40 |   75.0% |
#+TBLFM: @2$4..@4$4=100*$2/$3;%.1f%%]])
add("8 decimals", { { 2, 4, 4 } }, [[
| Item | Qty | Price   | Total   |
|------+-----+---------+---------|
| A    |   3 | 1.23456 |    3.70 |
| B    |   7 | 2.34567 |   16.42 |
| C    |   2 | 9.99999 |   20.00 |
#+TBLFM: @2$4..@4$4=$2*$3;%.2f]])
add("9 constants", { { 2, 4, 3 }, { 2, 4, 4 } }, [[
#+CONSTANTS: tax=0.16

| Product  | Price | Tax  | Total  |
|----------+-------+------+--------|
| Keyboard |  1200 |  192 |   1392 |
| Mouse    |   500 |   80 |    580 |
| Monitor  |  6000 |  960 |   6960 |
#+TBLFM: @2$3..@4$3=$2*$tax::@2$4..@4$4=$2+$3]])
add("10 named columns", { { 2, 4, 4 } }, [[
| Item     | Qty | Price | Total |
|----------+-----+-------+-------|
| Coffee   |   3 |   4.5 |  13.5 |
| Keyboard |   1 |   120 |   120 |
| Stickers |  10 |   0.8 |     8 |
#+TBLFM: $Total=$Qty*$Price]])
add("11 ! row names", { { 3, 5, 5 } }, [[
|   | Item     | Qty | Price | Total |
|---+----------+-----+-------+-------|
| ! | item     | qty | price | total |
|---+----------+-----+-------+-------|
| # | Coffee   |   3 |   4.5 |  13.5 |
| # | Keyboard |   1 |   120 |   120 |
| # | Stickers |  10 |   0.8 |     8 |
#+TBLFM: $total=$qty*$price]])
add("12 relative cols", { { 2, 4, 3 } }, [[
| A | B | Result |
|---+---+--------|
| 2 | 3 |      6 |
| 4 | 5 |     20 |
| 6 | 7 |     42 |
#+TBLFM: @2$3..@4$3=$-2*$-1]])
add("13 currency", { { 2, 4, 3 } }, [[
#+CONSTANTS: usd_mxn=18.50

| Product  | USD | MXN      |
|----------+-----+----------|
| Keyboard | 120 |  2220.00 |
| Monitor  | 500 |  9250.00 |
| Laptop   | 999 | 18481.50 |
#+TBLFM: @2$3..@4$3=$2*$usd_mxn;%.2f]])
add("14 invoice", { { 2, 7, 4 } }, [[
#+CONSTANTS: tax=0.16

| Item       | Qty | Price | Total   |
|------------+-----+-------+---------|
| Keyboard   |   2 |   120 |  240.00 |
| Mouse      |   3 |    50 |  150.00 |
| Monitor    |   1 |   500 |  500.00 |
|------------+-----+-------+---------|
| Subtotal   |     |       |  890.00 |
| Tax        |     |       |  142.40 |
| Grand Total |    |       | 1032.40 |
#+TBLFM: @2$4..@4$4=$2*$3;%.2f::@5$4=vsum(@2..@4);%.2f::@6$4=@5$4*$tax;%.2f::@7$4=@5$4+@6$4;%.2f]])
add("15a cells", { { 5, 5, 2 } }, [[
| Value | Result |
|-------+--------|
|    10 |        |
|    20 |        |
|    30 |        |
|-------+--------|
| Total |     60 |
#+TBLFM: @5$2=@2$1+@3$1+@4$1]])
add("15b vsum cells", { { 5, 5, 2 } }, [[
| Value | Result |
|-------+--------|
|    10 |        |
|    20 |        |
|    30 |        |
|-------+--------|
| Total |     60 |
#+TBLFM: @5$2=vsum(@2$1..@4$1)]])
add("16 horizontal", { { 2, 4, 5 } }, [[
| Name  | Jan | Feb | Mar | Total |
|-------+-----+-----+-----+-------|
| Alice |  10 |  20 |  30 |    60 |
| Bob   |  15 |  25 |  35 |    75 |
| Carol |   5 |  10 |  15 |    30 |
#+TBLFM: @2$5..@4$5=vsum($2..$4)]])
add("17 grand total", { { 2, 5, 5 } }, [[
| Name  | Jan | Feb | Mar | Total |
|-------+-----+-----+-----+-------|
| Alice |  10 |  20 |  30 |    60 |
| Bob   |  15 |  25 |  35 |    75 |
| Carol |   5 |  10 |  15 |    30 |
|-------+-----+-----+-----+-------|
| Total |     |     |     |   165 |
#+TBLFM: @2$5..@4$5=vsum($2..$4)::@5$5=vsum(@2..@4)]])
add("18 running", { { 2, 5, 3 } }, [[
| Transaction | Amount | Balance |
|-------------+--------+---------|
| Initial     |   1000 |    1000 |
| Coffee      |    -10 |     990 |
| Keyboard    |   -120 |     870 |
| Salary      |   2000 |    2870 |
#+TBLFM: @2$3=$2::@3$3..@5$3=$2+@-1$3]])
add("19 expenses", { { 2, 5, 4 }, { 2, 5, 5 }, { 6, 6, 2 }, { 6, 6, 5 } }, [[
| Category      | Budget | Actual | Difference | Used % |
|---------------+--------+--------+------------+--------|
| Food          |    500 |    420 |         80 |  84.0% |
| Entertainment |    200 |    250 |        -50 | 125.0% |
| Transport     |    300 |    280 |         20 |  93.3% |
| Shopping      |    400 |    350 |         50 |  87.5% |
|---------------+--------+--------+------------+--------|
| Total         |   1400 |   1300 |        100 |  92.9% |
#+TBLFM: @2$4..@5$4=$2-$3::@2$5..@5$5=100*$3/$2;%.1f%%::@6$2=vsum(@2..@5)::@6$3=vsum(@2..@5)::@6$4=$2-$3::@6$5=100*$3/$2;%.1f%%]])

local function cells(line)
  return vim.tbl_map(vim.trim, vim.split(line:sub(2, -2), "|", { plain = true }))
end

local function grid(lines)
  local g = {}
  for _, l in ipairs(lines) do
    if l:match("^%s*|") and not l:match("^%s*|%-") then
      g[#g + 1] = cells(vim.trim(l))
    end
  end
  return g
end

describe("tblfm walkthrough", function()
  for _, f in ipairs(F) do
    it(f.name, function()
      local input, d, first = {}, 0, nil
      for i, l in ipairs(f.lines) do
        if l:match("^|") and not l:match("^|%-") then
          d = d + 1
          local cs = cells(l)
          for _, b in ipairs(f.blank) do
            if d >= b[1] and d <= b[2] then
              cs[b[3]] = ""
            end
          end
          l = "| " .. table.concat(cs, " | ") .. " |"
        end
        if l:match("^|") and not first then
          first = i
        end
        input[#input + 1] = l
      end
      local buf = org_buffer(input, { first, 1 })
      tbl.recalc(buf, first)
      eq(grid(f.lines), grid(buf_lines(buf)))
    end)
  end
end)
