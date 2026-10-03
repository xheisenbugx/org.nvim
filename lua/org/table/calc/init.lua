---@mod org.table.calc A small GNU Calc for table formulas
---
--- Org hands table formulas to Emacs Calc (`calc-eval`) after replacing the
--- references by the field text. This module parses and evaluates that text
--- the way Calc does with Org's default modes (`org-calc-default-modes`):
---
--- - Calc operator precedence: `a/b*c` is `a/(b*c)`, `-2^2` is -4, `2 3`
---   and `2(3+1)` multiply, `a ? b : c`, `!`, `%`, `\` (integer division),
---   `|` (vector concatenation), comparisons and `&&`/`||`.
--- - Exact integers (bignums), floats with 12 digits of working precision
---   (`p` mode), fractions `3:4` (`F` flag), vectors `[1, 2]`, date forms
---   `<2024-01-10 Wed>` (days since 0001-01-01; subtracting two gives days).
--- - The Calc float display (`float 8` by default, `n`, `f`, `s`, `e`
---   modes): `3.`, `0.33333333`, `1e-3`, `1.2345679e12`.
--- - Complex numbers `(2, 3)` and polar `(2; 30)` (`sqrt(-4)` is `(0, 2)`),
---   HMS forms `2@ 30' 0"`, error forms `3 +/- 0.5`, intervals `[1 .. 3)`,
---   and `usimplify` of expressions with units (`3 m + 20 cm`, a table of
---   common units with Calc's conversion factors).
--- - Symbols and unknown functions stay symbolic, like Calc: `x*2` is
---   `2 x`, `sqrt(x)` stays `sqrt(x)`, `pi` stays `pi`. Formulas are
---   normalized the way Calc's math-normalize does it (ports of
---   math-add-symb-fancy, math-mul-symb-fancy, ...): `x*y/x` is `y`,
---   `(x+1)*2` is `2 x + 2`. simplify, expand, collect, deriv, integ and
---   solve live in org.table.calc_alg, matrices in org.table.calc_vec.
--- - Modulo forms `3 mod 7`.
--- - Quoted strings (`"big"`) are an extension: Calc turns them into
---   vectors of character codes, this module keeps them as text.
---
--- The evaluator is split by concern under lua/org/table/calc/: big
--- (bignums), values (value types, modes and date forms), parser, arith
--- (normalization and + - * / ^), functions, forms (complex, HMS, error,
--- interval and modulo forms), special (more functions), units, logic,
--- evaluate and format (the display).

local values = require("org.table.calc.values")
local arith = require("org.table.calc.arith")
local logic = require("org.table.calc.logic")
local evaluate = require("org.table.calc.evaluate")
local format = require("org.table.calc.format")

local tag = values.tag
local is_int = values.is_int
local is_real = values.is_real
local is_symbolic = values.is_symbolic
local modes = values.modes
local float = values.float
local tofloat = values.tofloat
local make_frac = values.make_frac
local days_from_civil = values.days_from_civil
local civil_from_days = values.civil_from_days
local sym = arith.sym
local op = arith.op
local call = arith.call
local num_cmp = arith.num_cmp
local is_zero = arith.is_zero
local negative = arith.negative
local add = arith.add
local sub = arith.sub
local mul = arith.mul
local div = arith.div
local pow = arith.pow
local neg = arith.neg
local F = arith.F
local same = arith.same
local is_object = arith.is_object
local is_objvec = arith.is_objvec
local is_number = arith.is_number
local equal_int = arith.equal_int
local looks_neg = arith.looks_neg
local known_scalar = arith.known_scalar
local combine_sum = arith.combine_sum
local combine_prod = arith.combine_prod
local set_simplifying = arith.set_simplifying
local set_mat = arith.set_mat
local compare = logic.compare
local concat = logic.concat
local eval = evaluate.eval
local format_float = format.format_float
local display = format.display

local M = {}

M.parse = require("org.table.calc.parser").parse

-- The functions of `F`, in the order the files define them (forms.lua
-- replaces sqrt, ln, log10 and log of functions.lua with versions that
-- give complex results).
require("org.table.calc.functions")
require("org.table.calc.forms")
require("org.table.calc.special")
require("org.table.calc.units")

---------------------------------------------------------------------------
-- Entry point
---------------------------------------------------------------------------

--- Evaluate a Calc formula.
---@param s string the formula, references already substituted
---@param opts? { prec?: integer, float_format?: table, deg?: boolean, frac?: boolean, num?: boolean }
---   `float_format` is `{ "float"|"fix"|"sci"|"eng", digits }` (default
---   `{ "float", 8 }`); `num` requires a numeric result (`calc-eval` 'num).
---@return string
function M.eval(s, opts)
  opts = opts or {}
  -- set in place: the files of the evaluator share the table
  local saved = { prec = modes.prec, frac = modes.frac, deg = modes.deg }
  modes.prec, modes.frac, modes.deg = opts.prec or 12, opts.frac or false, opts.deg ~= false
  set_simplifying(false)
  local ok, res = pcall(function()
    local v = eval(M.parse(s))
    if opts.num and not is_real(v) then
      error("result is not a number")
    end
    return display(v, opts.float_format or { "float", 8 }, modes.prec)
  end)
  modes.prec, modes.frac, modes.deg = saved.prec, saved.frac, saved.deg
  if not ok then
    error(res, 0)
  end
  return res
end

-- Vectors and matrices (org.table.calc_vec) and symbolic algebra
-- (org.table.calc_alg) work on the values above through these internals.
local K = {
  F = F,
  tag = tag,
  is_real = is_real,
  is_int = is_int,
  is_object = is_object,
  is_number = is_number,
  is_symbolic = is_symbolic,
  is_zero = is_zero,
  negative = negative,
  looks_neg = looks_neg,
  equal_int = equal_int,
  num_cmp = num_cmp,
  tofloat = tofloat,
  float = float,
  make_frac = make_frac,
  same = same,
  add = add,
  sub = sub,
  mul = mul,
  div = div,
  pow = pow,
  neg = neg,
  op = op,
  sym = sym,
  call = call,
  concat = concat,
  compare = compare,
  is_objvec = is_objvec,
  known_scalar = known_scalar,
  combine_sum = combine_sum,
  combine_prod = combine_prod,
  modes = function()
    return modes
  end,
  --- Turn Calc's math-simplifying on or off; returns the previous state.
  set_simplifying = set_simplifying,
}
local V = require("org.table.calc_vec")(K)
set_mat(V.mat_mul, V.mat_div, V.mat_pow)
K.is_matrix = V.is_matrix
require("org.table.calc_alg")(K)

M._format_float = format_float
M._days_from_civil = days_from_civil
M._civil_from_days = civil_from_days

return M
