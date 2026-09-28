-- Calc in table formulas: complex numbers, HMS forms, error forms,
-- intervals, units (usimplify) and more functions. Every expected value is
-- the output of Emacs 31 Calc (calc-eval with org-calc-default-modes) or of
-- Org 9.8.10 org-table-recalculate.
local calc = require("org.table.calc")
local tbl = require("org.table")

local function recalc(input)
  local buf = org_buffer(input, { 1, 0 })
  tbl.recalc(buf, 1)
  return buf_lines(buf)
end

describe("calc extensions", function()
  local cases = {
    { "sqrt(-4)", "(0, 2)" },
    { "pi", "pi" },
    { "2*pi", "2 pi" },
    { "(1,2)*(3,4)", "(-5, 10)" },
    { "abs((3,4))", "5" },
    { "arg((0,1))", "90." },
    { "re((3,4))", "3" },
    { "conj((3,4))", "(3, -4)" },
    { "2@ 30' 0\"", "2@ 30' 0\"" },
    { "2@ 30' + 1@ 45'", "4@ 15' 0\"" },
    { "hms(2.5)", "2@ 30' 0.\"" },
    { "deg(2@ 30')", "2.5" },
    { "vgmean([2,8])", "4" },
    { "vhmean([1,2])", "1.3333333" },
    { "and(12,10)", "8" },
    { "or(12,10)", "14" },
    { "xor(12,10)", "6" },
    { "not(5)", "4294967290" },
    { "lsh(1,4)", "16" },
    { "rsh(16,2)", "4" },
    { "[1..3]", "[1 .. 3]" },
    { "3 +/- 0.5", "3 +/- 0.5" },
    { "(3 +/- 0.5)*2", "6 +/- 1." },
    { "usimplify(3 m / 2 s)", "1.5 m / s" },
    { "ln(-1)", "(0., 3.1415927)" },
    { "sqrt(-2)", "(0., 1.4142136)" },
    { "exp(1)", "2.7182818" },
    { "1/(2,3)", "(0.15384615, -0.23076923)" },
    { "(1,2)^2", "(-3, 4)" },
    { "i", "i" },
    { "2i", "2 i" },
    { "(0,1)^2", "-1" },
    { "polar((3,4))", "(5; 53.130102)" },
    { "sin((1,1))", "(0.017455065, 0.017451520)" },
    { "log10(1000)", "3" },
    { "round(2.567, 2)", "2.57" },
    { "fdiv(7,2)", "7:2" },
    { "rounde(2.5)", "2" },
    { "roundu(2.5)", "3" },
    { "float(1/3)", "0.33333333" },
    { "gamma(5)", "24" },
    { "prime(7)", "1" },
    { "totient(10)", "4" },
    { "nextprime(10)", "11" },
    { "usimplify(1 hr + 60 min)", "2 hr" },
    { "usimplify(2 min + 30 s)", "2.5 min" },
    { "usimplify(1 km + 500 m)", "1.5 km" },
    { "usimplify(1 m + 1 km)", "1001 m" },
    { "usimplify(1 ft + 1 in)", "1.0833333 ft" },
    { "usimplify(1 mi / 1 km)", "1.609344" },
    { "usimplify(1 lb / 1 kg)", "0.45359237" },
    { "usimplify(1 gal / 1 l)", "3.7854118" },
    { "usimplify(1 day / 1 hr)", "24" },
    { "usimplify(3 m * 2 m / 4 s)", "1.5 m^2 / s" },
    { "usimplify(10 m / 2 s / 5 s)", "m / s^2" },
    { "usimplify(2 kg m / s^2)", "2 kg m / s^2" },
    { "usimplify(3 N * 2 m)", "6 N m" },
    { "usimplify(1 J / 1 cal)", "0.23884590" },
    { "usimplify(1 in^2 / 1 cm^2)", "6.4516" },
    { "usimplify(5 m)", "5 m" },
    { "usimplify(5)", "5" },
    { "usimplify(3 m - 50 cm)", "2.5 m" },
    { "usimplify(2 m + 3 s)", "2 m + 3 s" },
    { "usimplify(x)", "x" },
    { "usimplify(1 acre / 1 ha)", "0.40468564" },
    { "usimplify(100 km / 1 hr)", "100 km / hr" },
    { "usimplify(1 mph / 1 kph)", "1.609344" },
    { "usimplify(1 hr / 1 min)", "60" },
    { "usimplify(1 yd / 1 ft)", "3." },
    { "usimplify(1 oz/1 g)", "28.349523" },
    { "usimplify(1 wk / 1 day)", "7" },
    { "usimplify(1 yr / 1 day)", "365.25" },
    { "usimplify(1 atm / 1 Pa)", "101325" },
    { "usimplify(1 hp / 1 W)", "745.69987" },
    { "usimplify(1 kWh / 1 J)", "3600000" },
    { "usimplify(1 t / 1 kg)", "1000" },
    { "usimplify(1 nmi / 1 m)", "1852" },
    { "usimplify(1 knot / 1 kph)", "1.852" },
    { "usimplify(1 bar / 1 Pa)", "100000" },
    { "usimplify(1 psi / 1 Pa)", "6894.7573" },
    { "usimplify(1 Hz * 1 s)", "Hz s" },
    { "usimplify(1 ms / 1 s)", "1e-3" },
    { "usimplify(1 um / 1 m)", "1e-6" },
    { "usimplify(2 m * 3)", "6 m" },
    { "usimplify(6 m / 2)", "3 m" },
    { "usimplify(1 qt / 1 pt)", "2." },
    { "usimplify(1 cup / 1 ml)", "236.58824" },
    { "usimplify(1 lbf/1 N)", "4.4482216" },
    { "usimplify(1 mm + 1 m)", "1001. mm" },
    { "usimplify(20 cm + 3 m)", "320. cm" },
    { "usimplify(3 m + 20 cm)", "3.2 m" },
    { "usimplify(2 ft + 3 in)", "2.25 ft" },
    { "usimplify(1 hr + 30 min)", "1.5 hr" },
    { "sqrt(-4) + 1", "(1, 2)" },
    { "sqrt(-4)*2", "(0, 4)" },
    { "(2,3) + 1", "(3, 3)" },
    { "(2,3) - (2,3)", "0" },
    { "(2,3)/(2,3)", "1" },
    { "abs((1,1))", "1.4142136" },
    { "arg((1,1))", "45." },
    { "im((3,4))", "4" },
    { "(3,4) == (3,4)", "1" },
    { "sqrt((3,4))", "(2., 1.)" },
    { "exp((0,1))", "(0.54030231, 0.84147098)" },
    { "ln((0,1))", "(0., 1.5707963)" },
    { "(1.5, 2)", "(1.5, 2)" },
    { "(3;45)", "(3; 45)" },
    { "(3;45) + 1", "(3.7739423; 34.200920)" },
    { "2@ 30' 15.5\"", "2@ 30' 15.5\"" },
    { "2@ 30' * 2", "5@ 0' 0.\"" },
    { "(2@ 30') / 2", "1@ 15' 0.\"" },
    { "hms(2, 30, 0)", "2@ 30' 0\"" },
    { "2@ 30' - 3@", "-0@ 30' 0\"" },
    { "sin(30@ 0' 0\")", "0.5" },
    { "30@", "30@ 0' 0\"" },
    { "hms(1.2345678)", "1@ 14' 4.44408\"" },
    { "2@ 30' 0\" + 1", "3@ 30' 0\"" },
    { "rad(90)", "1.5707963" },
    { "deg(pi)", "deg(pi)" },
    { "sin(pi)", "sin(pi)" },
    { "2.5 * 1@ 0' 0\"", "2@ 30' 0.\"" },
    { "0.0174515204", "0.017451520" },
    { "(0.0174515204, 1)", "(0.017451520, 1)" },
    { "(1,2)/(3,4)", "(0.44, 0.08)" },
    { "(1,2)/2", "(0.5, 1)" },
    { "(1,2) - (1,2)", "0" },
    { "abs((1,2))", "2.2360680" },
    { "-(1,2)", "(-1, -2)" },
    { "(1,-2)", "(1, -2)" },
    { "(-1.5,2)*2", "(-3., 4.)" },
    { "2*(0,1)", "(0, 2)" },
    { "(1,2)^3", "(-11, -2)" },
    { "(1,2)^-1", "(0.2, -0.4)" },
    { "(1,2)^0.5", "(1.2720196, 0.78615138)" },
    { "(1,2)^(1,1)", "(-0.24720004, 0.69645049)" },
    { "ln(-2)", "(0.69314718, 3.1415927)" },
    { "log10(-10)", "(1., 1.3643764)" },
    { "exp((1,2))", "(-1.1312044, 2.4717267)" },
    { "sqrt(-4.)", "(0., 2.)" },
    { "sqrt(-1:4)", "(0, 1:2)" },
    { "arg(-1)", "180" },
    { "arg(1)", "0" },
    { "re(5)", "5" },
    { "im(5)", "0" },
    { "conj(5)", "5" },
    { "polar((1,1))", "(1.4142136; 45.)" },
    { "rect((2;90))", "(0., 2.)" },
    { "(2;90)", "(2; 90)" },
    { "(2;90)*(3;45)", "(6; 135)" },
    { "(1,2) < (3,4)", "(1, 2) < (3, 4)" },
    { "vsum([(1,2),(3,4)])", "(4, 6)" },
    { "(1,2) + x", "(1, 2) + x" },
    { "cos((0,1))", "1.0001523" },
    { "(1,2)*1.5", "(1.5, 3.)" },
    { "1:2*(1,1)", "(1:2, 1:2)" },
    { "(2,3)+(1,-3)", "3" },
    { "evalv(pi)", "3.1415927" },
    { "log(8,2)", "3" },
    { "log(10,3)", "2.0959033" },
    { "nroot(27,3)", "3" },
    { "nroot(10,3)", "2.1544347" },
    { "vgmean([2,3])", "2.4494897" },
    { "vgmean([1,2,4])", "2" },
    { "gamma(4.5)", "11.631728" },
    { "gamma(0.5)", "1.7724539" },
    { "dfact(7)", "105" },
    { "prime(97)", "1" },
    { "prevprime(10)", "7" },
    { "totient(12)", "4" },
    { "sec(60)", "2." },
    { "csc(30)", "2." },
    { "cot(45)", "1." },
    { "arcsinh(1)", "0.88137359" },
    { "arccosh(2)", "1.3169579" },
    { "arctanh(0.5)", "0.54930614" },
    { "incmonth(<2024-01-31>, 1)", "<2024-02-29 Thu>" },
    { "incyear(<2024-02-29>, 1)", "<2025-02-28 Fri>" },
    { "newmonth(<2024-03-15>)", "<2024-03-01 Fri>" },
    { "newyear(<2024-03-15>)", "<2024-01-01 Mon>" },
    { "newweek(<2024-03-15>)", "<2024-03-10 Sun>" },
    { "julian(<2024-01-01>)", "2460311" },
    { "(-4)^0.5", "(0., 2.)" },
    { "(-8)^(1:3)", "(1., 1.7320508)" },
    { "(-4)^1.5", "(0., -8.)" },
    { "[1..3] + 1", "[2 .. 4]" },
    { "[1..3] + [2..4]", "[3 .. 7]" },
    { "[1..3) * 2", "[2 .. 6)" },
    { "[1..3] * -1", "[-3 .. -1]" },
    { "(1..3] * [2..4]", "(2 .. 12]" },
    { "[1..3] / 2", "[0.5 .. 1.5]" },
    { "-[1..3)", "(-3 .. -1]" },
    { "abs(3 +/- 0.5)", "3 +/- 0.5" },
    { "sqrt(4 +/- 1)", "2 +/- 0.25" },
    { "(3 +/- 0.5) + (2 +/- 1.2)", "5 +/- 1.3" },
    { "(3 +/- 0.5) * (2 +/- 1)", "6 +/- 3.1622777" },
    { "(6 +/- 1) / (2 +/- 0.5)", "3 +/- 0.90138782" },
    { "(2 +/- 0.1)^2", "4 +/- 0.4" },
    { "-(3 +/- 1)", "-3 +/- 1" },
    { "2 / (4 +/- 1)", "0.5 +/- 0.125" },
    { "idiv(7,2)", "3" },
    { "and(-1, 255)", "255" },
    { "lsh(-1)", "4294967294" },
    { "rsh(-1)", "2147483647" },
    { "ash(-8, -1)", "4294967292" },
    { "not(0)", "4294967295" },
    { "xor(5)", "xor(5)" },
    { "and(5.5, 3)", "and(5.5, 3)" },
    { "rounde(3.5)", "4" },
    { "rounde(-2.5)", "-2" },
    { "roundu(-2.5)", "-2" },
    { "round(-2.5)", "-3" },
    { "fdiv(6,3)", "2" },
    { "float(7:2)", "3.5" },
    { "usimplify(1 L / 1 mL)", "1000" },
    { "usimplify(1 km * 1 m)", "1000 m^2" },
    { "usimplify(1 mA * 2 s)", "2 mA s" },
    { "usimplify([1 m + 1 cm, 2 ft])", "[1.01 m, 2 ft]" },
    { "2@ 30' 0\" > 2@ 0' 0\"", "1" },
    { "2@ 30' 0\" == 2.5", "1" },
    { "max(2@, 3@)", "3@ 0' 0\"" },
    { "-2@ 30' 0\"", "-2@ 30' 0\"" },
    { "(1..2) - [0..1]", "(0 .. 2)" },
    { "[1..2] * [-1..3]", "[-2 .. 6]" },
    { "[0.5..1.5] + 1", "[1.5 .. 2.5]" },
    { "(1, 2) * [1, 2]", "[(1, 2), (2, 4)]" },
    { "[(1,1), 2] + 1", "[(2, 1), 3]" },
    { "exp((0, 180))", "(-0.59846007, -0.80115264)" },
    { "sin((0, 0))", "0" },
    { "(0, 1) == (0, 1)", "1" },
    { "5 +/- 1 - 5 +/- 1", "0 +/- 1.4142136" },
    { "(5 +/- 1)^2", "25 +/- 10" },
    { "exp(0 +/- 1)", "1 +/- 1" },
    { "ln(1 +/- 0.1)", "0 +/- 0.1" },
    { "hms(-1.5)", "-1@ 30' 0.\"" },
    { "2@ 30' - 30'", "2@ 0' 0\"" },
    { "30' 15\"", "0@ 30' 15\"" },
    { "vsum([1@ 30', 2@ 45'])", "4@ 15' 0\"" },
  }

  it("evaluates like Emacs Calc", function()
    local bad = {}
    for _, c in ipairs(cases) do
      local okc, got = pcall(calc.eval, c[1])
      if not okc or got ~= c[2] then
        bad[#bad + 1] = string.format("%s: expected %s, got %s", c[1], c[2], tostring(got))
      end
    end
    eq({}, bad)
  end)

  it("converts dates to and from unix time in the local time zone", function()
    local secs = os.time({ year = 2024, month = 1, day = 1, hour = 0, min = 0, sec = 0 })
    eq(tostring(secs), calc.eval("unixtime(<2024-01-01>)"))
    eq("<2024-01-01 Mon>", calc.eval("unixtime(" .. secs .. ")"))
  end)

  it("keeps symbolic forms Calc keeps", function()
    eq("(1, 2) + x", calc.eval("(1, 2) + x"))
    eq("3 m + 20 cm", calc.eval("3 m + 20 cm"))
    eq("2 m + 3 s", calc.eval("usimplify(2 m + 3 s)"))
    eq("foo((0, 1))", calc.eval("foo((0, 1))"))
  end)

  it("recalculates tables with the new value forms", function()
    local cases_t = {
      {
        { "| 2@ 30' 0\" | 1@ 45' 0\" |  |", "#+TBLFM: $3=$1+$2" },
        { "| 2@ 30' 0\" | 1@ 45' 0\" | 4@ 15' 0\" |", "#+TBLFM: $3=$1+$2" },
      },
      { { "| -4 |  |", "#+TBLFM: $2=sqrt($1)" }, { "| -4 | (0, 2) |", "#+TBLFM: $2=sqrt($1)" } },
      {
        { "| (1, 2) | (3, 4) |  |  |", "#+TBLFM: $3=$1*$2::$4=abs($2)" },
        { "| (1, 2) | (3, 4) | (-5, 10) | 5 |", "#+TBLFM: $3=$1*$2::$4=abs($2)" },
      },
      {
        { "| 3 m | 20 cm |  |", "#+TBLFM: $3=usimplify($1+$2)" },
        { "| 3 m | 20 cm | 3.2 m |", "#+TBLFM: $3=usimplify($1+$2)" },
      },
      {
        { "| 30 |  |  |", "#+TBLFM: $2=sin($1);R::$3=sqrt(-$1);%.2f" },
        { "| 30 | -0.98803162 | 0.00 |", "#+TBLFM: $2=sin($1);R::$3=sqrt(-$1);%.2f" },
      },
      {
        { "| 3 +/- 0.5 | 2 |  |", "#+TBLFM: $3=$1*$2" },
        { "| 3 +/- 0.5 | 2 | 6 +/- 1. |", "#+TBLFM: $3=$1*$2" },
      },
      {
        { "| 1 | 2 | 4 |  |", "#+TBLFM: $4=vgmean($1..$3)" },
        { "| 1 | 2 | 4 | 2 |", "#+TBLFM: $4=vgmean($1..$3)" },
      },
      { { "| (1, 2) |  |", "#+TBLFM: $2=$1*2;N" }, { "| (1, 2) | 0 |", "#+TBLFM: $2=$1*2;N" } },
    }
    for _, c in ipairs(cases_t) do
      eq(c[2], recalc(c[1]))
    end
  end)
end)

-- Calc adds floats exactly in decimal and keeps a date's time of day to the
-- working precision; expected values are Emacs 31 Calc / Org 9.8.10 output.
describe("calc decimal sums and dates with times", function()
  it("leaves no binary noise when a float sum cancels", function()
    eq("0.699306", calc.eval("739890 - 739889.300694"))
    eq("0.354166", calc.eval("739891.270833 - 739890.916667"))
    eq("0.3", calc.eval("100.3 - 100"))
  end)

  it("rounds a time of day to the working precision", function()
    eq("0.354166", calc.eval("<2026-10-02 Fri 06:30> - <2026-10-01 Thu 22:00>"))
    eq("8.499984", calc.eval("(<2026-10-02 Fri 06:30> - <2026-10-01 Thu 22:00>)*24"))
    eq("0.699306", calc.eval("<2026-10-01 Thu 00:00> - <2026-09-30 Wed 07:13>"))
    eq("7", calc.eval("minute(<2026-10-01 Thu 00:07>)"))
    eq("28", calc.eval("minute(<2026-10-01 Thu 00:28>)"))
    eq("22", calc.eval("hour(<2026-10-01 Thu 22:00>)"))
  end)

  it("keeps the zeros Calc keeps", function()
    -- a float that rounds to fewer digits for display keeps its zeros in Calc
    eq("8.5000000", calc.eval("exp(ln(8.5))"))
    eq("8.500", calc.eval("8.5", { float_format = { "fix", 3 } }))
  end)

  it("computes time differences in a table like Org", function()
    local tbl = require("org.table")
    local input = {
      "| <2026-10-01 Thu 22:00> | <2026-10-02 Fri 06:30> |  |  |  |  |  |",
      "#+TBLFM: $3=$2-$1::$4=($2-$1)*24::$5=($2-$1)*1440::$6=($2-$1)*24;%.2f::$7=($2-$1)*1440;%d",
    }
    local buf = org_buffer(input, { 1, 0 })
    tbl.recalc(buf, 1)
    eq({
      "| <2026-10-01 Thu 22:00> | <2026-10-02 Fri 06:30> | 0.354166 | 8.499984 | 509.99904 | 8.50 | 509 |",
      input[2],
    }, buf_lines(buf))
  end)
end)
