local tbl = require("org.table")
local formula = require("org.table.formula")

local function calc(lines)
  local buf = org_buffer(lines, { 1, 1 })
  tbl.recalc(buf, 1)
  return buf_lines(buf)
end

describe("formulas", function()
  it("parses tblfm", function()
    local f = formula.parse_tblfm("$3=$1*$2::@>$2=vsum(@I..@II);%.2f")
    eq(2, #f)
    eq("$3", f[1].lhs)
    eq("vsum(@I..@II)", f[2].rhs)
    eq("%.2f", f[2].flags)
  end)

  it("column and field formulas", function()
    local out = calc({
      "| item | qty | price | total |",
      "|------+-----+-------+-------|",
      "| a    |   2 |   1.5 |       |",
      "| b    |   3 |     2 |       |",
      "|------+-----+-------+-------|",
      "| sum  |     |       |       |",
      "#+TBLFM: $4=$2*$3::@>$2=vsum(@I..@II)::@>$4=vsum(@I..@II);%.2f",
    })
    eq("| a    |   2 |   1.5 |     3 |", out[3])
    eq("| b    |   3 |     2 |     6 |", out[4])
    eq("| sum  |   5 |       |  9.00 |", out[6])
  end)

  it("relative refs, counters, functions", function()
    local out = calc({
      "| 1 |  |  |",
      "| 2 |  |  |",
      "| 3 |  |  |",
      "#+TBLFM: $2=@#::$3=if($1 > 1, $1 * 2, 0)::@2$3..@3$3=$1 + @-1$1",
    })
    eq("| 1 | 1 | 0 |", out[1])
    eq("| 2 | 2 | 3 |", out[2])
    eq("| 3 | 3 | 5 |", out[3])
  end)

  it("vmean, vmax, ranges in a row, lua formulas", function()
    local out = calc({
      "| 2 | 4 | 6 |   |   |   |",
      "#+TBLFM: $4=vmean($1..$3)::$5=vmax($1..$3)::$6='(string.upper(\"x\" .. $1))",
    })
    eq("| 2 | 4 | 6 | 4 | 6 | X2 |", out[1])
  end)

  it("durations", function()
    local out = calc({
      "| 1:30 |",
      "| 0:45 |",
      "|      |",
      "#+TBLFM: @3$1=vsum(@1..@2);U",
    })
    eq("| 02:15 |", out[3]:gsub("%s+", " "):gsub("^| ", "| "))
  end)

  it("errors", function()
    local out = calc({ "| a |  |", "#+TBLFM: $2=$1*2" })
    eq("| a | #ERROR |", out[1])
  end)

  it("remote", function()
    local buf = org_buffer({
      "#+NAME: other",
      "| 10 | 20 |",
      "",
      "| x |",
      "#+TBLFM: $1=remote(other,@1$2)",
    })
    tbl.recalc(buf, 4)
    eq("| 20 |", buf_lines(buf)[4])
  end)
end)
