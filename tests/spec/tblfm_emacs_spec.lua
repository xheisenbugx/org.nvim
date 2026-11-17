-- Emacs Org-mode spreadsheet compatibility (Org manual, "The Spreadsheet",
-- Org 9.7). Expected values are what Emacs produces with the default
-- `org-calc-default-modes`:
--   calc-internal-prec 12, calc-float-format (float 8), calc-angle-mode deg,
--   calc-prefer-frac nil, calc-symbolic-mode nil
-- i.e. floats are *displayed* with 8 significant digits and trig functions
-- work in degrees unless the `R` flag is given.
--
-- Recalculation corresponds to C-c C-c on the #+TBLFM line, which is
-- `(org-table-recalculate 'all)`: one pass, column formulas first (row by
-- row), then field formulas.
--
-- Not covered here (tested elsewhere): #+CONSTANTS, `!` name rows,
-- header-name columns, `%%` in printf formats.
local tbl = require("org.table")

--- Record a case whose Emacs output is not certain enough to assert.
local function pending(_name, _note) end

--- Trimmed field values of one table line.
local function cells(line)
  local out = {}
  local body = vim.trim(line):match("^|(.*)|$") or ""
  for c in (body .. "|"):gmatch("(.-)|") do
    out[#out + 1] = vim.trim(c)
  end
  return out
end

--- Data rows (hlines skipped) of the table starting at buffer line `from`.
--- Row i of the result is Emacs' @i.
local function grid(lines, from)
  local rows = {}
  local i = from or 1
  while lines[i] and lines[i]:match("^%s*|") do
    if not lines[i]:match("^%s*|%-") then
      rows[#rows + 1] = cells(lines[i])
    end
    i = i + 1
  end
  return rows
end

--- Recalculate the table at `lnum` (default: line 1), return its grid.
local function calc(lines, lnum)
  local buf = org_buffer(lines, { 1, 0 })
  tbl.recalc(buf, lnum or 1)
  return grid(buf_lines(buf), lnum or 1), buf_lines(buf)
end

--- Column `c` of a grid as a list.
local function col(g, c)
  local out = {}
  for i, row in ipairs(g) do
    out[i] = row[c]
  end
  return out
end

--- Evaluate a single field formula `@1$1=<rhs>` in a one-cell table.
local function eval1(rhs)
  return calc({ "|  |", "#+TBLFM: @1$1=" .. rhs })[1][1]
end

describe("tblfm emacs compat", function()
  describe("references", function()
    it("@N$M absolute and $M (current row)", function()
      local g = calc({
        "| 1 | 10 | 100 |   |",
        "| 2 | 20 | 200 |   |",
        "| 3 | 30 | 300 |   |",
        "#+TBLFM: @1$4=@3$2::@2$4=$1::@3$4=@1$3",
      })
      eq({ "30", "2", "100" }, col(g, 4))
    end)

    it("@N alone refers to row N of the current column", function()
      local g = calc({
        "| a | 4 |",
        "| b |   |",
        "#+TBLFM: @2$2=@1*3",
      })
      eq("12", g[2][2])
    end)

    it("@< @> $< $> and @<< / $>> (second first / second last)", function()
      local g = calc({
        "|  1 |   |  2 |  3 |",
        "|  4 |   |  5 |  6 |",
        "|  7 |   |  8 |  9 |",
        "| 10 |   | 11 | 12 |",
        "#+TBLFM: @1$2=@<$<::@2$2=@>$>::@3$2=@<<$>>::@4$2=@>>$<",
      })
      eq({ "1", "12", "5", "7" }, col(g, 2))
    end)

    it("relative @-1 @+1 $-1 $+1", function()
      local g = calc({
        "| 1 |   | 10 |",
        "| 2 |   | 20 |",
        "| 3 |   | 30 |",
        "#+TBLFM: @2$2=@-1$1+@+1$1::@3$2=$-1+$+1::@1$2=@+2$+1",
      })
      eq({ "30", "4", "33" }, col(g, 2))
    end)

    it("@0 $0 (current row / column) and @# $# counters", function()
      local g = calc({
        "| 3 |   |   |",
        "| 4 |   |   |",
        "#+TBLFM: $2=@0$1*2::$3=@# * 10 + $#",
      })
      eq({ "6", "8" }, col(g, 2))
      eq({ "13", "23" }, col(g, 3))
    end)

    it("@I @II @III with +N / -N offsets", function()
      local g = calc({
        "| h   |   |",
        "|-----+---|",
        "| 1   |   |",
        "| 2   |   |",
        "| 3   |   |",
        "|-----+---|",
        "| 10  |   |",
        "| 20  |   |",
        "|-----+---|",
        "| 100 |   |",
        "#+TBLFM: @2$2=vsum(@I$1..@II$1)::@3$2=@II+1$1::@4$2=@II-1$1"
          .. "::@5$2=vsum(@II$1..@III$1)::@6$2=@III$1::@7$2=@I+2$1",
      })
      eq({ "", "6", "10", "3", "30", "100", "2" }, col(g, 2))
    end)

    it("@-I is the row just below the nearest hline above", function()
      local g = calc({
        "| a |   |",
        "|---+---|",
        "| 1 |   |",
        "| 2 |   |",
        "|---+---|",
        "| 3 |   |",
        "| 4 |   |",
        "#+TBLFM: $2=@-I$1",
      })
      eq({ "", "1", "1", "3", "3" }, col(g, 2))
    end)

    it("a leading hline is @I", function()
      local g = calc({
        "|---+-----|",
        "| h | out |",
        "|---+-----|",
        "| 1 |     |",
        "| 2 |     |",
        "|---+-----|",
        "|   |     |",
        "#+TBLFM: $2=$1*10::@>$2=vsum(@II..@III)",
      })
      eq({ "out", "10", "20", "30" }, col(g, 2))
      -- @I..@II is the header row alone
      g = calc({
        "|---+-----|",
        "| h | out |",
        "|---+-----|",
        "| 1 |     |",
        "| 2 |     |",
        "|---+-----|",
        "|   |     |",
        "#+TBLFM: $2=$1*10::@>$2=vsum(@I..@II)",
      })
      eq({ "out", "10", "20", "out" }, col(g, 2))
    end)

    it("the hline after the last one is the last row (Emacs' imaginary hline)", function()
      local lines = {
        "| a | 1 |",
        "|---+---|",
        "| b | 2 |",
        "| c | 3 |",
        "| d |   |",
      }
      local function with(f)
        local l = vim.deepcopy(lines)
        l[#l + 1] = "#+TBLFM: " .. f
        return calc(l)
      end
      eq({ "1", "2", "3", "5" }, col(with("@>$2=vsum(@I..@II)"), 2))
      eq({ "5", "2", "3", "" }, col(with("@1$2=vsum(@II..@I)"), 2))
      eq({ "3", "2", "3", "" }, col(with("@1$2=@II-1"), 2))
      -- difftest seed 5792531: a row of "|" alone, @II the target itself
      local g = calc({
        "| Price1",
        "|---+---|",
        "| 13 | 49",
        "|",
        "| |",
        "#+TBLFM: @>$1=vsum(@I..@II)",
      })
      eq({ "Price1", "13", "", "13" }, col(g, 1))
    end)
  end)

  describe("ranges", function()
    it("2D range, row range $1..$3, and @<..@>", function()
      local g = calc({
        "| 1 | 2 | 3 |   |   |",
        "| 4 | 5 | 6 |   |   |",
        "| 7 | 8 | 9 |   |   |",
        "#+TBLFM: $4=vsum($1..$3)::@1$5=vsum(@1$1..@3$3)::@2$5=vsum(@<$1..@>$1)",
      })
      eq({ "6", "15", "24" }, col(g, 4))
      eq({ "45", "12", "" }, col(g, 5))
    end)

    it("relative 2D range around the current field", function()
      local g = calc({
        "| 1 | 2 | 3 |",
        "| 4 |   | 6 |",
        "| 7 | 8 | 9 |",
        "#+TBLFM: @2$2=vsum(@-1$-1..@+1$+1)",
      })
      eq("40", g[2][2])
    end)

    it("empty fields are dropped from ranges", function()
      local g = calc({
        "| 2 |   |",
        "|   |   |",
        "| 4 |   |",
        "| 6 |   |",
        "#+TBLFM: @1$2=vmean(@1$1..@4$1)::@2$2=vcount(@1$1..@4$1)",
      })
      eq("4", g[1][2])
      eq("3", g[2][2])
    end)

    it("E keeps empty fields in ranges (EN: as 0)", function()
      local g = calc({
        "| 2 |   |",
        "|   |   |",
        "| 4 |   |",
        "| 6 |   |",
        "#+TBLFM: @1$2=vmean(@1$1..@4$1);EN::@2$2=vcount(@1$1..@4$1);EN",
      })
      eq("3", g[1][2])
      eq("4", g[2][2])
    end)

    it("an empty single-field reference is 0", function()
      local g = calc({
        "|   | 5 |   |",
        "#+TBLFM: $3=$1+$2",
      })
      eq("5", g[1][3])
    end)
  end)

  describe("formula kinds and precedence", function()
    it("column formulas skip the header; field formula on the total row", function()
      local g = calc({
        "| item | qty | price | total |",
        "|------+-----+-------+-------|",
        "| a    |   2 |     3 |       |",
        "| b    |   4 |     5 |       |",
        "|------+-----+-------+-------|",
        "| sum  |     |       |       |",
        "#+TBLFM: $4=$2*$3::@>$4=vsum(@I..@II)::@>$2=vsum(@I..@II)",
      })
      eq({ "total", "6", "20", "26" }, col(g, 4))
      eq("6", g[4][2])
    end)

    it("without hlines column formulas apply to every row", function()
      local g = calc({
        "| 1 |   |",
        "| 2 |   |",
        "#+TBLFM: $2=$1+1",
      })
      eq({ "2", "3" }, col(g, 2))
    end)

    it("column formulas are evaluated row by row", function()
      -- Emacs loops over rows, applying every column formula in each row,
      -- so @-1$3 already holds the value computed on the previous row.
      local g = calc({
        "| h | a | 0 |",
        "|---+---+---|",
        "| 1 |   |   |",
        "| 2 |   |   |",
        "#+TBLFM: $2=$1+@-1$3::$3=$2*10",
      })
      eq({ "a", "1", "12" }, col(g, 2))
      eq({ "0", "10", "120" }, col(g, 3))
    end)

    it("field formulas override column formulas", function()
      local g = calc({
        "| 1 |   |",
        "| 2 |   |",
        "| 3 |   |",
        "#+TBLFM: $2=$1*2::@2$2=99",
      })
      eq({ "2", "99", "6" }, col(g, 2))
    end)

    it("field formula wins even when listed before the column formula", function()
      local g = calc({
        "| 1 |   |",
        "| 2 |   |",
        "#+TBLFM: @2$2=99::$2=$1*2",
      })
      eq({ "2", "99" }, col(g, 2))
    end)

    it("range formulas (column slice and 2D)", function()
      local g = calc({
        "| 1 |   |   |   |",
        "| 2 |   |   |   |",
        "| 3 |   |   |   |",
        "#+TBLFM: @2$2..@3$2=$1*10::@1$3..@2$4=@# * 10 + $#",
      })
      eq({ "", "20", "30" }, col(g, 2))
      eq({ "13", "23", "" }, col(g, 3))
      eq({ "14", "24", "" }, col(g, 4))
    end)

    it("@>$> field formula", function()
      local g = calc({
        "| 1 | 2 |",
        "| 3 |   |",
        "#+TBLFM: @>$>=vsum(@<$<..@>$<)",
      })
      eq("4", g[2][2])
    end)

    it("a row formula @2= sets every field of the row", function()
      local g = calc({
        "| 1 | 2 | 3 |",
        "|   |   |   |",
        "#+TBLFM: @2=@1*2",
      })
      eq({ "2", "4", "6" }, g[2])
    end)

    it("a row formula @>= sums every column", function()
      local g = calc({
        "| a | b |",
        "|---+---|",
        "| 1 | 2 |",
        "| 3 | 4 |",
        "|---+---|",
        "|   |   |",
        "#+TBLFM: @>=vsum(@I..@II)",
      })
      eq({ "4", "6" }, g[4])
    end)
  end)

  describe("special first-column marks", function()
    it("with marked rows, only # and * rows get column formulas", function()
      local g = calc({
        "| # | 1 |   |",
        "|   | 2 |   |",
        "| * | 3 |   |",
        "#+TBLFM: $3=$2*10",
      })
      eq({ "10", "", "30" }, col(g, 3))
    end)

    it("$ row defines parameters", function()
      local g = calc({
        "| # |   2 |   |",
        "| # |   5 |   |",
        "| $ | k=3 |   |",
        "#+TBLFM: $3=$2*$k",
      })
      eq({ "6", "15", "" }, col(g, 3))
      eq("k=3", g[3][2])
    end)

    it("^ names the field above", function()
      local g = calc({
        "| # | 1 |     |",
        "| # | 2 |     |",
        "|   |   |     |",
        "| ^ |   | tot |",
        "#+TBLFM: $tot=vsum(@1$2..@2$2)",
      })
      eq("3", g[3][3])
      eq("tot", g[4][3])
    end)

    it("_ names the field below", function()
      local g = calc({
        "| _ |   | lo |",
        "| # | 7 |    |",
        "#+TBLFM: $lo=$2*2",
      })
      eq("14", g[2][3])
      eq("lo", g[1][3])
    end)

    pending(
      "/ marked rows",
      "unsure whether org-table-recalculate skips `/` rows for column formulas (field-1 check `[_^!$/]`)"
    )
  end)

  describe("properties", function()
    it("$PROP_Foo reads a property of the current entry", function()
      local g = calc({
        "* Entry",
        ":PROPERTIES:",
        ":Rate: 3",
        ":END:",
        "| 2 |   |",
        "| 5 |   |",
        "#+TBLFM: $2=$1*$PROP_Rate",
      }, 5)
      eq({ "6", "15" }, col(g, 2))
    end)
  end)

  describe("calc functions", function()
    local cases = {
      { "abs(-3)", "3" },
      { "sqrt(16)", "4" },
      { "sqrt(2)", "1.4142136" },
      { "exp(0)", "1" },
      { "ln(1)", "0" },
      { "log10(1000)", "3" },
      { "floor(2.7)", "2" },
      { "ceil(2.1)", "3" },
      { "round(2.5)", "3" },
      { "round(-2.5)", "-3" },
      { "max(3, 7, 5)", "7" },
      { "min(3, 7, 5)", "3" },
      { "2^10", "1024" },
      { "7 % 3", "1" },
      { "mod(7, 3)", "1" },
      { "idiv(7, 2)", "3" },
      { "if(3 > 2, 10, 20)", "10" },
      { "if(3 < 2, 10, 20)", "20" },
      { "3 == 3", "1" },
      { "3 != 3", "0" },
      { "sin(30)", "0.5" }, -- degrees by default
      { "vmax([4, 9, 2])", "9" },
      { "vmedian([1, 2, 3, 4])", "2.5" },
    }
    for _, c in ipairs(cases) do
      it(c[1] .. " = " .. c[2], function()
        eq(c[2], eval1(c[1]))
      end)
    end

    -- math-round / math-ceiling / math-floor / math-trunc with a precision:
    -- calcFunc-scf shifts the decimal point exactly (Calc floats are
    -- decimal), then divides back (an integer when it divides); with a
    -- precision <= 0 an integer stays as it is (Emacs 31.1 Calc)
    local more = {
      { "floor(0.29, 2)", "0.29" },
      { "floor(-0.29, 2)", "-0.29" },
      { "ceil(1.1, 2)", "1.1" },
      { "ceil(-1.1, 2)", "-1.1" },
      { "trunc(0.57, 2)", "0.57" },
      { "trunc(-0.57, 2)", "-0.57" },
      { "round(1.005, 2)", "1.01" },
      { "round(-1.005, 2)", "-1.01" },
      { "round(2.675, 2)", "2.68" },
      { "round(0.285, 2)", "0.29" },
      { "round(9.995, 2)", "10" },
      { "round(5, 2)", "5" },
      { "round(12345, -2)", "12345" },
      { "round(12345.6789, -2)", "12300" },
      { "floor(-12.5, -1)", "-20" },
      { "round(1.005, 2.0)", "1.01" },
      { "round(2:3, 2)", "0.67" },
      { "rounde(0.125, 2)", "0.12" },
      { "rounde(2.675, 2)", "2.68" },
      { "roundu(-0.125, 2)", "-0.12" },
    }
    -- numbers with an explicit radix (math-read-number-fancy), and `%`
    -- before a prefix operator is the modulo, not the postfix percent
    -- (math-factor-after) (Emacs 31.1 Calc)
    vim.list_extend(more, {
      { "2#101", "5" },
      { "16#FF + 1", "256" },
      { "16#ff", "255" },
      { "36#Z", "35" },
      { "-16#FF", "-255" },
      { "16#1E3", "483" },
      { "16#F.8", "15.5" },
      { "2#101.1", "5.5" },
      { "2#1.1e1", "3." },
      { "2#1.1e-1", "0.75" },
      { "2#101e-2", "1.25" },
      { "8#7e+1", "56." },
      { "14#De-1", "0.92857143" },
      { "16#1E-3", "27" },
      { "16#F:3", "5" },
      { "16^^FF", "255" },
      { "2##101", "5" },
      { "16#FFFFFFFFFFFFFFFFFF", "4722366482869645213695" },
      { "3#12a", "#ERROR" },
      { "7 % -3", "-2" },
      { "50% - 3", "-1" },
      { "5% + 2", "1" },
      { "5 % !0", "0" },
      { "10% * 2", "0.2" },
      { "(10%) - 3", "-2.9" },
    })
    for _, c in ipairs(more) do
      it(c[1] .. " = " .. c[2], function()
        eq(c[2], eval1(c[1]))
      end)
    end

    it("vector functions over a column range", function()
      local fns = { "vsum", "vmean", "vmax", "vmin", "vcount", "vprod", "vmedian", "vsdev", "vvar" }
      local lines = {}
      local fm = {}
      local data = { "2", "4", "6" }
      for i, fn in ipairs(fns) do
        lines[i] = "| " .. (data[i] or "") .. " |  |"
        fm[#fm + 1] = "@" .. i .. "$2=" .. fn .. "(@1$1..@3$1)"
      end
      lines[#lines + 1] = "#+TBLFM: " .. table.concat(fm, "::")
      local g = calc(lines)
      local got = {}
      for i, fn in ipairs(fns) do
        got[fn] = g[i][2]
      end
      eq({
        vsum = "12",
        vmean = "4",
        vmax = "6",
        vmin = "2",
        vcount = "3",
        vprod = "48",
        vmedian = "4",
        vsdev = "2",
        vvar = "4",
      }, got)
    end)

    it("vmean with a non-integer result", function()
      local g = calc({ "| 1 | 2 | 4 |   |", "#+TBLFM: $4=vmean($1..$3)" })
      eq("2.3333333", g[1][4])
    end)

    -- Calc keeps text as symbols (`$1*2` with "a" gives "2 a"); this
    -- plugin has no symbolic algebra and shows #ERROR instead.
    pending("non-numeric fields stay symbolic in Calc", "no symbolic algebra")
  end)

  describe("number formatting", function()
    local cases = {
      { "10/4", "2.5" },
      { "6/3", "2" },
      { "1/3", "0.33333333" }, -- calc-float-format (float 8)
      { "2/3", "0.66666667" },
      { "0.1 + 0.2", "0.3" },
      { "2^50", "1125899906842624" },
    }
    for _, c in ipairs(cases) do
      it(c[1] .. " = " .. c[2], function()
        eq(c[2], eval1(c[1]))
      end)
    end

    pending("integer-valued float (e.g. 2*1.5)", "Calc may display `3.` for a float result")
  end)

  describe("mode strings", function()
    local cases = {
      { "1/3;%.2f", "0.33" },
      { "7/2;%d", "3" }, -- (format "%d" 3.5) truncates
      { "10/4;f3", "2.500" },
      { "1/3;f2", "0.33" },
      { "sin(30);D", "0.5" },
      { "atan(1);R", "0.78539816" },
    }
    for _, c in ipairs(cases) do
      it(c[1] .. " -> " .. c[2], function()
        eq(c[2], eval1(c[1]))
      end)
    end

    it("N treats non-numbers as 0", function()
      local g = calc({ "| abc | 2 |   |", "#+TBLFM: $3=$1+$2;N" })
      eq("2", g[1][3])
    end)

    pending("p20", "only raises calc-internal-prec; display stays (float 8), so 1/3 is still 0.33333333")
    pending("s3 / e3", "exact Calc scientific/engineering rendering (e.g. `1.23e3`) not verified")
  end)

  describe("durations", function()
    it("T / t / U on a sum", function()
      local g = calc({
        "| 1:30 |   |   |   |",
        "| 0:45 |   |   |   |",
        "#+TBLFM: @1$2=vsum(@1$1..@2$1);T::@1$3=vsum(@1$1..@2$1);t::@1$4=vsum(@1$1..@2$1);U",
      })
      eq({ "1:30", "02:15:00", "2.25", "02:15" }, g[1])
    end)

    it("manual example: 2:12 + 1:47", function()
      local g = calc({
        "| 2:12 | 1:47 |   |   |",
        "#+TBLFM: $3=$1+$2;T::$4=$1+$2;t",
      })
      eq({ "2:12", "1:47", "03:59:00", "3.98" }, g[1])
    end)

    it("H:MM:SS input and duration arithmetic", function()
      local g = calc({
        "| 1:00:30 | 0:30:30 |   |   |   |",
        "#+TBLFM: $3=$1+$2;T::$4=$1-$2;U::$5=$1*2;T",
      })
      eq({ "01:31:00", "00:30", "02:01:00" }, { g[1][3], g[1][4], g[1][5] })
    end)
  end)

  describe("lisp formulas", function()
    it("'(+ $1 $2) with N", function()
      local g = calc({ "| 1 | 2 |   |", "#+TBLFM: $3='(+ $1 $2);N" })
      eq("3", g[1][3])
    end)

    it("'(+ $1 $2) with L (fields inserted literally)", function()
      local g = calc({ "| 1 | 2 |   |", "#+TBLFM: $3='(+ $1 $2);L" })
      eq("3", g[1][3])
    end)

    it("'(concat $1 $2) and '(length $1) on strings", function()
      local g = calc({ "| ab | cd |   |   |", "#+TBLFM: $3='(concat $1 \"-\" $2)::$4='(length $1)" })
      eq("ab-cd", g[1][3])
      eq("2", g[1][4])
    end)

    it("'(apply '+ '(range)) with N", function()
      local g = calc({
        "| 1 |   |",
        "| 2 |   |",
        "| 3 |   |",
        "#+TBLFM: @1$2='(apply '+ '(@1$1..@3$1));N",
      })
      eq("6", g[1][2])
    end)

    it("string results from if", function()
      local g = calc({
        "| 3 |   |",
        "| 8 |   |",
        '#+TBLFM: $2=\'(if (> $1 5) "big" "small");N',
      })
      eq({ "small", "big" }, col(g, 2))
    end)
  end)

  describe("remote references", function()
    local lines = {
      "#+NAME: data",
      "| name | val |",
      "|------+-----|",
      "| a    |   1 |",
      "| b    |   2 |",
      "| c    |   3 |",
      "",
      "| sum | one | first |",
      "|-----+-----+-------|",
      "|     |     |       |",
      "#+TBLFM: @2$1=vsum(remote(data,@2$2..@4$2))::@2$2=remote(data,@3$2)::@2$3=remote(data,@I$1)",
    }

    it("single field", function()
      eq("2", calc(lines, 8)[2][2])
    end)

    it("range inside vsum", function()
      eq("6", calc(lines, 8)[2][1])
    end)

    it("hline reference in the remote table", function()
      eq("a", calc(lines, 8)[2][3])
    end)

    it("a rule above the remote table's first row is @I", function()
      local _, out = calc({
        "| x |   |",
        "#+TBLFM: $2=remote(src,@I$1)",
        "",
        "#+NAME: src",
        "|---+----|",
        "| a | b  |",
        "|---+----|",
        "| 1 | 10 |",
      })
      eq("| x | a |", out[1])
    end)

    it("@# and $# inside the remote reference", function()
      local g = calc({
        "| 2 |   |",
        "| 3 |   |",
        "#+TBLFM: $2=remote(src, @@#$1)*$1",
        "",
        "#+NAME: src",
        "| 10 |",
        "| 20 |",
      })
      eq({ "20", "60" }, col(g, 2))
      g = calc({
        "| 1 | 2 |   |",
        "#+TBLFM: $3=remote(src, @1$$#)",
        "",
        "#+NAME: src",
        "| 10 | 20 | 30 |",
      })
      eq("30", g[1][3])
    end)

    it("the table name read from a field", function()
      local g = calc({
        "| src |    |",
        "#+TBLFM: $2=remote($1,@1$1)",
        "",
        "#+NAME: src",
        "| 10 | 20 |",
      })
      eq("10", g[1][2])
    end)
  end)

  it("date(<$1>) on fields holding bare dates", function()
    local g = calc({
      "| 2026-01-01 | 2026-03-01 |   |",
      "#+TBLFM: $3=date(<$2>)-date(<$1>)",
    })
    eq("59", g[1][3])
  end)
end)

describe("tblfm: Calc names with a number subscript", function()
  -- Calc reads H_2O as the subscript H_2 times O (difftest seeds 2520871,
  -- 2521047)
  it("H_2O is H_2 O", function()
    eq("H_2 O + paren", calc({ "| H_2O | (paren) |", "#+TBLFM: $3=$1+$2" })[1][3])
    eq("H_2 O > 0 ? 1 : 0", calc({ "| H_2O |", "#+TBLFM: $3=if($1>$2, 1, 0)" })[1][3])
    eq("x_a + 1", calc({ "| x_a |", "#+TBLFM: $2=$1+1" })[1][2])
  end)
end)

describe("tblfm: field formulas on rows written short", function()
  -- org-table-recalculate works on the table as written: a field formula
  -- aimed past the last field of its row (org-table-goto-column without
  -- FORCE, then org-table-get-field) writes nothing; column formulas add
  -- the fields they need (difftest seed 152)
  it("writes nothing past the row's last field", function()
    local g = calc({ "|", "| 94.9 |", "| | | |", "#+TBLFM: @2$3=@2$1*10" })
    eq({ "", "", "" }, { g[1][3], g[2][3], g[3][3] })
    eq("", calc({ "|", "| 94.9 | | |", "| | | |", "#+TBLFM: @1$3=@2$1*10" })[1][3])
    eq("", calc({ "| a |", "| | | |", "#+TBLFM: @1$2=7" })[1][2])
  end)

  it("writes into a field the row has", function()
    eq("949.", calc({ "|", "| 94.9 | | |", "| | | |", "#+TBLFM: @2$3=@2$1*10" })[2][3])
    eq({ "a", "7", "8" }, calc({ "| a | | |", "| | |", "#+TBLFM: @1$2=7::@1$3=8" })[1])
  end)

  it("a column formula adds the fields to its rows", function()
    local g = calc({ "| a |", "|---|", "| 1 |", "| 2 | | |", "#+TBLFM: $3=5::@3$2=9" })
    eq({ "1", "", "5" }, g[2])
    eq({ "2", "9", "5" }, g[3])
  end)
end)

describe("tblfm: Calc over text fields (Emacs Org 9.8.10 + Calc)", function()
  -- difftest seeds 20, 58, 248, 267, 269, 271, 400, 1033, 50659: what
  -- Calc makes of fields that are not numbers
  it("braces are vectors: {{{title}}} is [[[title]]]", function()
    eq("[[[(46 title)]]]", calc({ "| {{{title}}} | 46 |", "#+TBLFM: $3=$1*$2" })[1][3])
    eq("[[[42 + title + 32]]]", calc({ "| 42 | {{{title}}} | 32 |", "#+TBLFM: $4=$1+$2+$3" })[1][4])
    eq("[[[nan]]]", calc({ "| {{{title}}} | |", "#+TBLFM: $3=$1*$2;E" })[1][3])
    eq("max(title, x)", calc({ "| {{{title}}} | x |", "#+TBLFM: $3=vmax($1..$2)" })[1][3])
  end)

  it("x^{10} is x^[10], a_{i} the subscript a_[i]", function()
    eq("x^[10] > 71.8 ? 1 : 0", calc({ "| x^{10} | 71.8 |", "#+TBLFM: $3=if($1>$2, 1, 0)" })[1][3])
    eq("[-4, a_[i]]", calc({ "| -4 a_{i} |", "#+TBLFM: $3=$1..$2" })[1][3])
    eq("H_2 O a_b", calc({ "| H_2O | a_b |", "#+TBLFM: $3=$1*$2" })[1][3])
    local g = calc({
      "|",
      "|---+---|",
      "| | 80",
      "| 94.5 | 41",
      "| | x^{10}",
      "|---+---|",
      "| | |",
      "#+TBLFM: @>$2=vsum(@2..@-1)",
    })
    eq("121 + x^[10]", g[5][2])
  end)

  it("a vector element starts at a brace: [src_python{1+1}, 3]", function()
    eq("src_python + 5", calc({ "| src_python{1+1} | 3 |", "#+TBLFM: $3=vsum($1..$2)" })[1][3])
  end)

  it("a quoted string is the vector of its character codes", function()
    eq("[a, [113, 117, 111, 116, 101, 100]]", calc({ '| a | "quoted" |', "#+TBLFM: $3=$1..$2" })[1][3])
    eq("[114]", calc({ '| "q" |', "#+TBLFM: $2=$1+1" })[1][2])
  end)

  it("an @ range of one field is that field: vsum(task) stays", function()
    local g = calc({
      "| Price1",
      "|---+---+---+---|",
      "| | task | plan",
      "| | | | 66",
      "#+TBLFM: @>$2=vsum(@2..@-1)",
    })
    eq("vsum(task)", g[3][2])
    -- a range ending on an hline stays a vector: vsum([Sum]) is Sum
    eq("Sum", calc({ "| | gamma", "|---+---|", "| Sum |", "#+TBLFM: @>$1=vsum(@I..@II)" })[2][1])
  end)

  it("equal formulas compare: alpha > alpha is 0", function()
    eq("0", calc({ "| alpha | alpha |", "#+TBLFM: $3=if($1>$2, 1, 0)" })[1][3])
  end)

  it("a table whose #+TBLFM line is empty is left alone, not aligned", function()
    local _, lines = calc({ "| 1   | 2 |", "#+TBLFM:" })
    eq({ "| 1   | 2 |", "#+TBLFM:" }, lines)
    _, lines = calc({ "| 1   | 2 |", "#+TBLFM: :: " })
    eq("| 1   | 2 |", lines[1])
  end)
end)

describe("tblfm: references inside quoted strings (Emacs Org 9.8.10 + Calc)", function()
  -- org-table-eval-formula replaces references by regexp over the whole
  -- formula, quoted strings included
  --- Calc's vector of the character codes of `s`.
  local function codes(s)
    local out = {}
    for ch in s:gmatch(".") do
      out[#out + 1] = tostring(ch:byte())
    end
    return "[" .. table.concat(out, ", ") .. "]"
  end

  it("Calc: $1, @1$2, $1..$2, $# and @# are replaced inside a string", function()
    eq(codes("(abc)"), calc({ "| abc | 2 |   |", '#+TBLFM: $3="$1"' })[1][3])
    eq(codes("x(2)y"), calc({ "| 5 | 2 |   |", '#+TBLFM: $3="x$2y"' })[1][3])
    eq(codes("(2)"), calc({ "| 5 | 2 |   |", '#+TBLFM: $3="@1$2"' })[1][3])
    eq(codes("[5,2]"), calc({ "| 5 | 2 |   |", '#+TBLFM: $3="$1..$2"' })[1][3])
    eq(codes("3-1"), calc({ "| abc | def |   |", '#+TBLFM: $3="$#-@#"' })[1][3])
    eq("9", calc({ "| a | b |   |", "| c | d |   |", "| x | y |   |", '#+TBLFM: @3$3=vlen("@1$1..@2$2")' })[3][3])
  end)

  it("Calc: an empty field is (0), nan with E; N keeps the string", function()
    eq(codes("(0)"), calc({ "| x |   |   |", '#+TBLFM: $3="$2"' })[1][3])
    eq(codes("nan"), calc({ "| x |   |   |", '#+TBLFM: $3="$2";E' })[1][3])
    eq(codes("(5)"), calc({ "| 5 | 2 |   |", '#+TBLFM: $3="$1";N' })[1][3])
    eq(codes("(0)"), calc({ "| x |   |   |", '#+TBLFM: $3="$1";N' })[1][3])
  end)

  it("Calc: an inactive timestamp field becomes <...> in the string", function()
    eq(codes("(<2024-01-02 Tue>)"), calc({ "| [2024-01-02 Tue] | 2 |   |", '#+TBLFM: $3="$1"' })[1][3])
  end)

  it("Calc: names, constants and column names are replaced too", function()
    eq(codes("(42)"), calc({ "#+CONSTANTS: c=42", "| 5 | 2 |   |", '#+TBLFM: $3="$c"' }, 2)[1][3])
    eq(codes("a(#UNDEFINED_NAME)"), calc({ "| 5 | 2 |   |", '#+TBLFM: $3="a$b"' })[1][3])
    eq(codes("(0)"), calc({ "| ! | x | y |", "|   | 5 | 2 |", "|   |   |   |", '#+TBLFM: @3$2="$x"' })[3][2])
  end)

  it("Calc: an @ or $ that starts no reference stays", function()
    eq(codes("a@b"), calc({ "| 5 | 2 |   |", '#+TBLFM: $3="a@b"' })[1][3])
    eq("[102, 41]", calc({ "| 5 | 2 |   |", '#+TBLFM: $3="a$" + $1' })[1][3])
    eq("[41]", calc({ "| 5 | 2 |   |", '#+TBLFM: $3=$1 + "$"' })[1][3])
  end)

  it("Calc: durations: the field in seconds, a string result is 00:00:00", function()
    eq("00:00:00", calc({ "| 1:30 | 2 |   |", '#+TBLFM: $3="$1";T' })[1][3])
    eq("00:00", calc({ "| 1:30 |   |", '#+TBLFM: $2="$1";U' })[1][2])
  end)

  it("Lisp: a field is a quoted string, so only L or N give its text", function()
    eq("#ERROR", calc({ "| abc | def |   |", '#+TBLFM: $3=\'(concat "$1" "-" "$2")' })[1][3])
    eq("abc-def", calc({ "| abc | def |   |", '#+TBLFM: $3=\'(concat "$1" "-" "$2");L' })[1][3])
    eq("5-6", calc({ "| 5 | 6 |   |", '#+TBLFM: $3=\'(concat "$1" "-" "$2");N' })[1][3])
    eq("12", calc({ "| 1 | 2 |   |", '#+TBLFM: $3=\'(concat "$1$2");L' })[1][3])
    eq("[a b]", calc({ "| a b | 2 |   |", '#+TBLFM: $3=\'(concat "[$1]");L' })[1][3])
    eq("#ERROR", calc({ "| a b | 2 |   |", '#+TBLFM: $3=\'(concat "[$1]")' })[1][3])
    eq("#ERROR", calc({ '| a"b | 2 |   |', '#+TBLFM: $3=\'(concat "[$1]");L' })[1][3])
    eq('"5"', calc({ "| 5 | 2 |   |", '#+TBLFM: $3=\'(format "%s" "\\"$1\\"");L' })[1][3])
    -- `""5" costs 5$"` reads as "" 5 " costs 5$": (format "%s" "") is ""
    eq("", calc({ "| 5 | 2 |   |", '#+TBLFM: $3=\'(format "%s" "$1 costs 5$")' })[1][3])
    eq("5 costs 5$", calc({ "| 5 | 2 |   |", '#+TBLFM: $3=\'(format "%s" "$1 costs 5$");L' })[1][3])
  end)

  it("Lisp: ranges, $<, $>, $# and @# inside a string", function()
    eq("5 5 2", calc({ "| 5 | 2 |   |", '#+TBLFM: $3=\'(format "%s %s" "@1$1" "$1..$2");L' })[1][3])
    eq("5", calc({ "| 5 | 2 |   |", '#+TBLFM: $3=\'(format "%s" "$<$>");L' })[1][3])
    eq("31", calc({ "| abc | def |   |", '#+TBLFM: $3=\'(concat "$#" "@#")' })[1][3])
    eq("2", calc({ "| 5 | 2 |   |", '#+TBLFM: $3=\'(format "%s" "$-1");L' })[1][3])
    local g = calc({
      "| a | b |   |",
      "| c | d |   |",
      "| x | y |   |",
      '#+TBLFM: @3$3=\'(format "%s" "@1$1..@2$2");L',
    })
    eq("a b c d", g[3][3])
  end)

  it("Lisp: names and durations inside a string", function()
    eq("42", calc({ "#+CONSTANTS: c=42", "| 5 | 2 |   |", '#+TBLFM: $3=\'(format "%s" "$c")' }, 2)[1][3])
    eq("#UNDEFINED_NAME", calc({ "| 5 | 2 |   |", '#+TBLFM: $3=\'(format "%s" "$b")' })[1][3])
    eq("01:30:00", calc({ "| 1:30 | 2 |   |", '#+TBLFM: $3=\'(format "%s" "$1");T' })[1][3])
    eq("1:30", calc({ "| 1:30 | 2 |   |", '#+TBLFM: $3=\'(format "%s" "$1");L' })[1][3])
    eq("a@b", calc({ "| 5 | 2 |   |", '#+TBLFM: $3=\'(format "%s" "a@b")' })[1][3])
  end)

  it("N accepts any constant result: vectors, complex, HMS, intervals", function()
    eq("[1, 2]", calc({ "| 1 |   |", "#+TBLFM: $2=[1,2];N" })[1][2])
    eq("(2, 3)", calc({ "| 1 |   |", "#+TBLFM: $2=(2,3);N" })[1][2])
    eq("[1 .. 3]", calc({ "| 1 |   |", "#+TBLFM: $2=[1..3];N" })[1][2])
    eq("3 mod 7", calc({ "| 1 |   |", "#+TBLFM: $2=3 mod 7;N" })[1][2])
    eq("#ERROR", calc({ "| 1 |   |", "#+TBLFM: $2=[x,1];N" })[1][2])
    eq("#ERROR", calc({ "| 1 |   |", "#+TBLFM: $2=<2024-01-02>;N" })[1][2])
  end)
end)
