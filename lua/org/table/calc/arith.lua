---@mod org.table.calc.arith Calc: normalization and arithmetic
---
--- Formula constructors, Calc's type predicates, math-normalize's
--- combining of sums and products, and + - * / ^ on every value type.

local big = require("org.table.calc.big")
local values = require("org.table.calc.values")

local MAX_EXACT = big.MAX_EXACT
local big_from_int = big.big_from_int
local big_cmp_abs = big.big_cmp_abs
local big_add = big.big_add
local big_mul = big.big_mul
local big_norm = big.big_norm
local tag = values.tag
local is_int = values.is_int
local is_real = values.is_real
local modes = values.modes
local float = values.float
local decimal_sum = values.decimal_sum
local tofloat = values.tofloat
local make_frac = values.make_frac
local as_frac = values.as_frac

---------------------------------------------------------------------------
-- Arithmetic
---------------------------------------------------------------------------

local function sym(name)
  return { tag = "sym", name = name }
end

local function op(o, a, b)
  return { tag = "op", op = o, a = a, b = b }
end

local function call(name, args)
  return { tag = "call", name = name, args = args }
end

local function is_nan(v)
  return tag(v) == "float" and v.v ~= v.v
end

local function num_cmp(a, b) -- -1, 0, 1 for two reals
  if is_int(a) and is_int(b) and (tag(a) == "big" or tag(b) == "big") then
    local ba = type(a) == "table" and a or big_from_int(a)
    local bb = type(b) == "table" and b or big_from_int(b)
    if ba.sign ~= bb.sign then
      return ba.sign < bb.sign and -1 or 1
    end
    return big_cmp_abs(ba, bb) * ba.sign
  end
  local x, y = tofloat(a), tofloat(b)
  return x < y and -1 or (x > y and 1 or 0)
end

local function is_zero(v)
  return is_real(v) and tofloat(v) == 0
end

local function is_one(v)
  return v == 1
end

local function negative(v)
  return is_real(v) and tofloat(v) < 0
end

local add, sub, mul, div, pow, neg
local FANCY_TAGS = { cplx = true, polar = true, hms = true, sdev = true, intv = true, mod = true }
-- arithmetic on complex numbers, HMS forms, error forms, intervals and
-- modulo forms (defined with the functions below); nil when neither operand
-- is one
local ext_op
-- matrix products and powers (defined with the vector functions below)
local mat_mul, mat_div, mat_pow

local F = {}

local function to_float_early(v)
  return float(tofloat(v))
end

local function same(a, b)
  return vim.deep_equal(a, b)
end

-- Calc's type predicates (calc-macs.el): Math-objectp, Math-numberp, ...
local function is_object(v)
  return is_real(v) or FANCY_TAGS[tag(v)] or tag(v) == "date"
end

local function is_objvec(v)
  return is_object(v) or tag(v) == "vec"
end

local function is_number(v)
  return is_real(v) or tag(v) == "cplx" or tag(v) == "polar"
end

local function is_angle(v)
  return is_real(v) or tag(v) == "hms"
end

local function equal_int(v, n)
  return v == n or (tag(v) == "float" and v.v == n)
end

--- math-looks-negp: a negative number, `-x`, or a product, quotient or
--- difference that starts with one.
local function looks_neg(v)
  local t = tag(v)
  if is_real(v) then
    return negative(v)
  elseif t == "neg" then
    return true
  elseif t == "op" and (v.op == "*" or v.op == "/") then
    return looks_neg(v.a) or looks_neg(v.b)
  elseif t == "op" and v.op == "-" then
    return looks_neg(v.a)
  end
  return false
end

-- What Calc knows of a formula without declarations: only numbers and the
-- constants have a known sign or type (math-known-nonnegp, ...).
local POSITIVE_CONSTS = { pi = true, e = true, phi = true, gamma = true }
local function known_nonneg(v)
  if is_real(v) then
    return not negative(v)
  end
  return tag(v) == "sym" and POSITIVE_CONSTS[v.name] or false
end

local function known_num_integer(v)
  return is_int(v) or (tag(v) == "float" and v.v == math.floor(v.v))
end

local function known_even(v)
  return type(v) == "number" and v % 2 == 0
end

local function known_odd(v)
  return type(v) == "number" and v % 2 == 1
end

--- math-known-scalarp: numbers and, with `assume`, anything but a vector.
local function known_scalar(v, assume)
  if assume then
    return tag(v) ~= "vec"
  end
  return is_object(v) or (tag(v) == "sym" and POSITIVE_CONSTS[v.name]) or false
end

local function map_vec2(f, a, b)
  local out = { tag = "vec" }
  local ta, tb = tag(a), tag(b)
  if ta == "vec" and tb == "vec" then
    -- the shorter length, like math-map-vec-2
    for i = 1, math.min(#a, #b) do
      out[i] = f(a[i], b[i])
    end
  elseif ta == "vec" then
    for i = 1, #a do
      out[i] = f(a[i], b)
    end
  else
    for i = 1, #b do
      out[i] = f(a, b[i])
    end
  end
  return out
end

-- the `e` of exp(x) in math-combine-prod (compared by identity)
local COMBINE_E = { tag = "sym", name = "e" }

-- true while `simplify` runs (Calc's math-simplifying): products then
-- combine any powers of the same base and trigonometric pairs
local simplifying = false

--- Two sums with the same terms in any order (math-commutative-equal).
local function commutative_equal(a, b)
  local function is_sum(x)
    return tag(x) == "op" and (x.op == "+" or x.op == "-")
  end
  if not is_sum(a) then
    return same(a, b)
  elseif not is_sum(b) then
    return false
  end
  local function terms(x, negate, out)
    if tag(x) == "op" and x.op == "+" then
      terms(x.a, negate, out)
      terms(x.b, negate, out)
    elseif tag(x) == "op" and x.op == "-" then
      terms(x.a, negate, out)
      terms(x.b, not negate, out)
    else
      out[#out + 1] = negate and neg(x) or x
    end
    return out
  end
  local at, bt = terms(a, false, {}), terms(b, false, {})
  if #at ~= #bt then
    return false
  end
  for _, x in ipairs(at) do
    local found
    for i, y in ipairs(bt) do
      if same(x, y) then
        found = i
        break
      end
    end
    if not found then
      return false
    end
    table.remove(bt, found)
  end
  return true
end

-- products of trigonometric functions of the same argument
-- (math-combine-prod-trig): { a, b, result } (nil result: 1)
local TRIG_PRODUCTS = {
  { "sin", "csc" },
  { "sin", "sec", "tan" },
  { "sin", "cot", "cos" },
  { "cos", "sec" },
  { "cos", "csc", "cot" },
  { "cos", "tan", "sin" },
  { "tan", "cot" },
  { "tan", "csc", "sec" },
  { "sec", "cot", "csc" },
  { "sinh", "csch" },
  { "sinh", "sech", "tanh" },
  { "sinh", "coth", "cosh" },
  { "cosh", "sech" },
  { "cosh", "csch", "coth" },
  { "cosh", "tanh", "sinh" },
  { "tanh", "coth" },
  { "tanh", "csch", "sech" },
  { "sech", "coth", "csch" },
}
local function combine_prod_trig(a, b)
  if tag(a) ~= "call" or tag(b) ~= "call" or not same(a.args, b.args) then
    return nil
  end
  for _, t in ipairs(TRIG_PRODUCTS) do
    if a.name == t[1] and b.name == t[2] then
      return t[3] and call(t[3], a.args) or 1
    end
  end
  return nil
end

--- math-combine-sum: `a` and `b` as one term when they differ only by a
--- numeric factor (`2 x + 3 x` is `5 x`), else nil.
local function combine_sum(a, b, nega, negb, scalar_ok)
  if scalar_ok and is_objvec(a) and is_objvec(b) then
    if nega then
      a = neg(a)
    end
    if negb then
      b = neg(b)
    end
    -- objects that don't combine here (an HMS form and an interval) stay
    -- two terms
    local r = add(a, b)
    return is_objvec(r) and r or nil
  end
  local function split(x)
    local t = tag(x)
    if t == "op" and x.op == "*" and is_object(x.a) then
      return x.a, x.b
    elseif t == "op" and x.op == "/" and is_object(x.b) then
      return is_int(x.b) and make_frac(1, x.b) or div(1, x.b), x.a
    elseif t == "neg" then
      return -1, x.a
    end
    return 1, x
  end
  local am, ar = split(a)
  local bm, br = split(b)
  if not same(ar, br) then
    return nil
  end
  if nega then
    am = neg(am)
  end
  if negb then
    bm = neg(bm)
  end
  return mul(add(am, bm), ar)
end

local function frac_half(v, sign)
  return tag(v) == "frac" and v.n == sign and v.d == 2
end

--- math-combine-prod: `a` and `b` (each maybe inverted) as one factor when
--- they are powers of the same base (`x^2 x` is `x^3`), else nil.
local function combine_prod(a, b, inva, invb, scalar_ok)
  if (inva and is_zero(a)) or (invb and is_zero(b)) then
    return nil
  end
  if scalar_ok and is_objvec(a) and is_objvec(b) then
    local r
    if inva then
      r = invb and div(div(1, a), b) or div(b, a)
    else
      r = invb and div(a, b) or mul(a, b)
    end
    return is_objvec(r) and r or nil
  end
  if tag(a) == "op" and a.op == "^" and inva and looks_neg(a.b) then
    return mul(pow(a.a, neg(a.b)), b)
  end
  if tag(b) == "op" and b.op == "^" and invb and looks_neg(b.b) then
    return mul(a, pow(b.a, neg(b.b)))
  end
  if simplifying then
    local r = combine_prod_trig(a, b)
    if r ~= nil then
      return r
    end
  end
  local function split(x)
    local t = tag(x)
    local base, p = x, 1
    if t == "op" and x.op == "^" and (simplifying or is_number(x.b)) then
      base, p = x.a, x.b
    elseif t == "call" and x.name == "sqrt" and #x.args == 1 then
      base, p = x.args[1], make_frac(1, 2)
    elseif t == "call" and x.name == "exp" and #x.args == 1 and (simplifying or is_number(x.args[1])) then
      base, p = COMBINE_E, x.args[1]
    end
    if tag(base) == "frac" and base.n < base.d then
      base, p = div(1, base), neg(p)
    end
    return base, p
  end
  local apow, bpow
  a, apow = split(a)
  b, bpow = split(b)
  if inva then
    apow = neg(apow)
  end
  if invb then
    bpow = neg(bpow)
  end
  if (simplifying and commutative_equal(a, b)) or same(a, b) then
    local sumpow = add(apow, bpow)
    if not is_int(a) or is_zero(sumpow) or ((tag(apow) == "frac") == (tag(bpow) == "frac")) then
      if looks_neg(sumpow) and (is_int(a) or tag(a) == "frac") and not negative(a) then
        a, sumpow = div(1, a), neg(sumpow)
      end
      if frac_half(sumpow, 1) then
        return call("sqrt", { a })
      elseif frac_half(sumpow, -1) then
        return div(1, call("sqrt", { a }))
      elseif rawequal(a, COMBINE_E) and rawequal(b, COMBINE_E) then
        return call("exp", { sumpow })
      end
      return pow(a, sumpow)
    end
  end
  if same(apow, bpow) and is_int(a) and is_int(b) and not negative(a) and not negative(b) then
    if frac_half(apow, 1) then
      return call("sqrt", { mul(a, b) })
    elseif frac_half(apow, -1) then
      return div(1, call("sqrt", { mul(a, b) }))
    end
    return pow(mul(a, b), apow)
  end
  return nil
end

neg = function(a)
  local t = tag(a)
  if t == "int" then
    return -a
  elseif t == "big" then
    local b = vim.deepcopy(a)
    b.sign = -b.sign
    return big_norm(b)
  elseif t == "float" then
    return { tag = "float", v = -a.v }
  elseif t == "frac" then
    return { tag = "frac", n = -a.n, d = a.d }
  elseif t == "vec" then
    local out = { tag = "vec" }
    for i = 1, #a do
      out[i] = neg(a[i])
    end
    return out
  elseif FANCY_TAGS[t] then
    return ext_op("neg", a)
  elseif t == "str" or t == "date" then
    error("bad argument for negation")
  end
  -- math-neg-fancy
  if t == "op" then
    local o = a.op
    local function okay_neg(x)
      return looks_neg(x) or (tag(x) == "op" and x.op == "-")
    end
    if o == "+" then
      return sub(neg(a.a), a.b)
    elseif o == "-" then
      return sub(a.b, a.a)
    elseif o == "*" or o == "/" then
      if okay_neg(a.a) then
        return op(o, neg(a.a), a.b)
      elseif okay_neg(a.b) then
        return op(o, a.a, neg(a.b))
      elseif is_object(a.a) or (tag(a.a) == "op" and a.a.op == "*" and is_object(a.a.a)) then
        return op(o, neg(a.a), a.b)
      elseif o == "/" and (is_object(a.b) or (tag(a.b) == "op" and a.b.op == "*" and is_object(a.b.a))) then
        return op(o, a.a, neg(a.b))
      end
    end
  elseif t == "neg" then
    return a.a
  end
  return { tag = "neg", a = a }
end

local function int_op(f, bigf, a, b)
  if type(a) == "number" and type(b) == "number" then
    local r = f(a, b)
    if math.abs(r) < MAX_EXACT then
      return r
    end
  end
  local ba = type(a) == "table" and a or big_from_int(a)
  local bb = type(b) == "table" and b or big_from_int(b)
  return big_norm(bigf(ba, bb))
end

local function real_add(a, b)
  local ta, tb = tag(a), tag(b)
  if is_int(a) and is_int(b) then
    return int_op(function(x, y)
      return x + y
    end, big_add, a, b)
  elseif ta == "float" or tb == "float" then
    return float(decimal_sum(tofloat(a), tofloat(b)))
  end
  local an, ad = as_frac(a)
  local bn, bd = as_frac(b)
  return make_frac(an * bd + bn * ad, ad * bd)
end

local function real_mul(a, b)
  local ta, tb = tag(a), tag(b)
  if is_int(a) and is_int(b) then
    return int_op(function(x, y)
      return x * y
    end, big_mul, a, b)
  elseif ta == "float" or tb == "float" then
    return float(tofloat(a) * tofloat(b))
  end
  local an, ad = as_frac(a)
  local bn, bd = as_frac(b)
  return make_frac(an * bn, ad * bd)
end

local function real_div(a, b)
  if is_zero(b) then
    return nil
  end
  local ta, tb = tag(a), tag(b)
  if ta == "float" or tb == "float" then
    return float(tofloat(a) / tofloat(b))
  end
  if ta == "big" or tb == "big" then
    local x, y = tofloat(a), tofloat(b)
    local q = x / y
    if q == math.floor(q) and math.abs(q) < MAX_EXACT then
      local back = real_mul(q, b)
      if num_cmp(back, a) == 0 then
        return q
      end
    end
    return float(q)
  end
  local an, ad = as_frac(a)
  local bn, bd = as_frac(b)
  local n, d = an * bd, ad * bn
  if d < 0 then
    n, d = -n, -d
  end
  if n % d == 0 then
    return n / d
  end
  if modes.frac or ta == "frac" or tb == "frac" then
    return make_frac(n, d)
  end
  return float(n / d)
end

--- A zero of the type of `a` combined with `b`: `0 * 2.` is `0.`.
local function zero_like(z, other)
  if tag(other) == "float" and is_real(z) and tag(z) ~= "float" then
    return float(0)
  end
  return z
end

local function is_float_obj(v)
  local t = tag(v)
  if t == "float" then
    return true
  elseif t == "cplx" then
    return tag(v.re) == "float" or tag(v.im) == "float"
  end
  return false
end

--- math-add-symb-fancy: the sum of two formulas, not both numbers.
local function add_symb(a, b)
  local tb, ta = tag(b), tag(a)
  if tb == "op" and b.op == "+" then
    return add(add(a, b.a), b.b)
  elseif tb == "op" and b.op == "-" then
    return sub(add(a, b.a), b.b)
  elseif tb == "neg" and tag(b.a) == "op" and b.a.op == "+" then
    return sub(sub(a, b.a.a), b.a.b)
  end
  if (ta == "vec" and known_scalar(b)) or (tb == "vec" and known_scalar(a)) then
    return map_vec2(add, a, b)
  end
  local temp
  if ta == "op" and (a.op == "+" or a.op == "-") then
    temp = combine_sum(a.b, b, a.op == "-", false, true)
    if temp ~= nil then
      return add(a.a, temp)
    end
  elseif not (is_object(a) and is_object(b)) then
    temp = combine_sum(a, b, false, false, false)
    if temp ~= nil then
      return temp
    end
  end
  if looks_neg(b) then
    return op("-", a, neg(b))
  elseif looks_neg(a) then
    return op("-", b, neg(a))
  end
  return op("+", a, b)
end

--- math-mul-symb-fancy: the product of two formulas, not both numbers.
local function mul_symb(a, b)
  if equal_int(a, 1) then
    return b
  elseif equal_int(a, -1) then
    return neg(b)
  end
  local ta, tb = tag(a), tag(b)
  if (ta == "vec" and known_scalar(b)) or (tb == "vec" and known_scalar(a)) then
    return map_vec2(mul, a, b)
  end
  if is_object(b) and not is_object(a) then
    return mul(b, a)
  end
  if ta == "neg" then
    return neg(mul(a.a, b))
  elseif tb == "neg" then
    return neg(mul(a, b.a))
  end
  local aop = ta == "op" and a.op
  local bop = tb == "op" and b.op
  if aop == "*" then
    return mul(a.a, mul(a.b, b))
  end
  if aop == "^" and looks_neg(a.b) and not (bop == "^" and looks_neg(b.b)) and known_scalar(b, true) then
    return div(b, pow(a.a, neg(a.b)))
  end
  if bop == "^" and looks_neg(b.b) and not (aop == "^" and looks_neg(a.b)) and tag(b.a) ~= "vec" then
    return div(a, pow(b.a, neg(b.b)))
  end
  if aop == "/" and (known_scalar(a, true) or known_scalar(b, true)) then
    local temp = combine_prod(a.b, b, true, false, true)
    if temp ~= nil then
      return mul(a.a, temp)
    end
    return div(mul(a.a, b), a.b)
  end
  if bop == "/" then
    return div(mul(a, b.a), b.b)
  end
  if (bop == "+" or bop == "-") and is_number(a) and (is_number(b.a) or is_number(b.b)) then
    local f = bop == "+" and add or sub
    return f(mul(a, b.a), mul(a, b.b))
  end
  if bop == "*" and is_number(b.a) and not is_number(a) then
    return mul(b.a, mul(a, b.b))
  end
  if looks_neg(b) then
    return mul(neg(a), neg(b))
  end
  if bop == "-" and looks_neg(a) then
    return mul(neg(a), neg(b))
  end
  local temp
  if bop == "*" then
    temp = combine_prod(a, b.a, false, false, true)
    if temp ~= nil then
      return mul(temp, b.b)
    end
  else
    temp = combine_prod(a, b, false, false, false)
    if temp ~= nil then
      return temp
    end
  end
  return op("*", a, b)
end

--- math-div-symb-fancy: the quotient of two formulas, not both numbers.
local function div_symb(a, b)
  if equal_int(b, 1) then
    return a
  elseif equal_int(b, -1) then
    return neg(a)
  end
  local ta, tb = tag(a), tag(b)
  if ta == "vec" and known_scalar(b) then
    return map_vec2(div, a, b)
  end
  local aop = ta == "op" and a.op
  local bop = tb == "op" and b.op
  if bop == "^" and (looks_neg(b.b) or equal_int(a, 1)) then
    return mul(a, pow(b.a, neg(b.b)))
  end
  if ta == "neg" then
    return neg(div(a.a, b))
  elseif tb == "neg" then
    return neg(div(a, b.a))
  end
  if aop == "/" then
    return div(a.a, mul(a.b, b))
  end
  if bop == "/" then
    return div(mul(a, b.b), b.a)
  end
  if tb == "frac" then
    return mul(make_frac(b.d, b.n), a)
  end
  if (aop == "+" or aop == "-") and (is_number(a.a) or is_number(a.b)) and is_number(b) then
    local f = aop == "+" and add or sub
    return f(div(a.a, b), div(a.b, b))
  end
  if (aop == "-" or looks_neg(a)) and looks_neg(b) then
    return div(neg(a), neg(b))
  end
  if bop == "-" and looks_neg(a) then
    return div(neg(a), neg(b))
  end
  local c
  if aop == "*" then
    if bop == "*" then
      c = combine_prod(a.a, b.a, false, true, true)
      if c ~= nil then
        return div(mul(c, a.b), b.b)
      end
    else
      c = combine_prod(a.a, b, false, true, true)
      if c ~= nil then
        return mul(c, a.b)
      end
    end
  elseif bop == "*" then
    c = combine_prod(a, b.a, false, true, true)
    if c ~= nil then
      return div(c, b.b)
    end
  else
    c = combine_prod(a, b, false, true, false)
    if c ~= nil then
      return c
    end
  end
  return op("/", a, b)
end

--- The symbolic part of math-pow-fancy.
local function pow_symb(a, b)
  local ta = tag(a)
  local aop = ta == "op" and a.op
  if aop == "*" and (known_num_integer(b) or known_nonneg(a.a) or known_nonneg(a.b)) then
    return mul(pow(a.a, b), pow(a.b, b))
  elseif aop == "/" and (known_num_integer(b) or known_nonneg(a.b)) then
    return div(pow(a.a, b), pow(a.b, b))
  elseif aop == "/" and known_nonneg(a.a) and not equal_int(a.a, 1) then
    return mul(pow(a.a, b), pow(div(1, a.b), b))
  elseif aop == "^" and (known_num_integer(b) or known_nonneg(a.a)) then
    return pow(a.a, mul(a.b, b))
  elseif ta == "call" and a.name == "sqrt" and #a.args == 1 and (known_num_integer(b) or known_nonneg(a.args[1])) then
    return pow(a.args[1], div(b, 2))
  elseif looks_neg(a) and is_int(b) then
    if known_even(b) then
      return pow(neg(a), b)
    elseif known_odd(b) then
      return neg(pow(neg(a), b))
    end
  end
  return op("^", a, b)
end

add = function(a, b)
  local ta, tb = tag(a), tag(b)
  if is_nan(a) or is_nan(b) then
    return float(0 / 0)
  end
  if is_real(a) and is_real(b) then
    return real_add(a, b)
  end
  if is_zero(a) then
    return (tag(a) == "float" and is_real(b)) and to_float_early(b) or b
  elseif is_zero(b) then
    return (tag(b) == "float" and is_real(a)) and to_float_early(a) or a
  end
  if ta == "vec" and tb == "vec" then
    return map_vec2(add, a, b)
  end
  local x = ext_op("+", a, b)
  if x ~= nil then
    return x
  elseif ta == "date" and is_real(b) then
    return { tag = "date", v = decimal_sum(a.v, tofloat(b)) }
  elseif tb == "date" and is_real(a) then
    return { tag = "date", v = decimal_sum(b.v, tofloat(a)) }
  elseif ta == "str" or tb == "str" or ta == "date" or tb == "date" then
    error("bad argument for +")
  elseif (ta == "vec" or tb == "vec") and is_objvec(a) and is_objvec(b) then
    return map_vec2(add, a, b)
  end
  return add_symb(a, b)
end

sub = function(a, b)
  local ta, tb = tag(a), tag(b)
  if is_nan(a) or is_nan(b) then
    return float(0 / 0)
  end
  if is_real(a) and is_real(b) then
    return real_add(a, neg(b))
  end
  local x = ext_op("-", a, b)
  if x ~= nil then
    return x
  elseif ta == "date" and tb == "date" then
    local d = decimal_sum(a.v, -b.v)
    return d == math.floor(d) and d or float(d)
  elseif ta == "date" and is_real(b) then
    return { tag = "date", v = decimal_sum(a.v, -tofloat(b)) }
  elseif ta == "str" or tb == "str" or ta == "date" or tb == "date" then
    error("bad argument for -")
  end
  return add(a, neg(b))
end

mul = function(a, b)
  local ta, tb = tag(a), tag(b)
  if is_nan(a) or is_nan(b) then
    return float(0 / 0)
  end
  if is_real(a) and is_real(b) then
    return real_mul(a, b)
  end
  if ta == "str" or tb == "str" or ta == "date" or tb == "date" then
    error("bad argument for *")
  end
  if is_zero(a) and tb ~= "mod" and tb ~= "vec" and not FANCY_TAGS[tb] then
    return (is_float_obj(a) or is_float_obj(b)) and float(0) or 0
  elseif is_zero(b) and ta ~= "mod" and ta ~= "vec" and not FANCY_TAGS[ta] then
    return (is_float_obj(a) or is_float_obj(b)) and float(0) or 0
  end
  if ta == "vec" or tb == "vec" then
    if ta == "vec" and tb == "vec" then
      return mat_mul(a, b)
    elseif is_object(a) or is_object(b) then
      return map_vec2(mul, a, b)
    end
  end
  local x = ext_op("*", a, b)
  if x ~= nil then
    return x
  end
  return mul_symb(a, b)
end

div = function(a, b)
  local ta, tb = tag(a), tag(b)
  if is_nan(a) or is_nan(b) then
    return float(0 / 0)
  end
  if is_real(a) and is_real(b) then
    local r = real_div(a, b)
    if r == nil then
      return op("/", a, b) -- Calc leaves division by zero alone
    end
    return r
  end
  if ta == "str" or tb == "str" or ta == "date" or tb == "date" then
    error("bad argument for /")
  end
  if is_zero(b) then
    return op("/", a, b)
  end
  if is_zero(a) and tb ~= "mod" and tb ~= "vec" then
    return (tag(a) ~= "float" and is_float_obj(b)) and float(0) or a
  end
  if tb == "vec" and is_objvec(a) then
    return mat_div(a, b)
  elseif ta == "vec" and is_object(b) then
    return map_vec2(div, a, b)
  end
  local x = ext_op("/", a, b)
  if x ~= nil then
    return x
  end
  return div_symb(a, b)
end

local function int_pow(a, n)
  local r, base = 1, a
  while n > 0 do
    if n % 2 == 1 then
      r = real_mul(r, base)
    end
    n = math.floor(n / 2)
    if n > 0 then
      base = real_mul(base, base)
    end
  end
  return r
end

--- The exact n-th root of a non-negative integer or fraction, or nil.
local function exact_root(a, n)
  local function iroot(x)
    if type(x) ~= "number" or x < 0 then
      return nil
    end
    local r = math.floor(x ^ (1 / n) + 0.5)
    return int_pow(r, n) == x and r or nil
  end
  if tag(a) == "frac" then
    local rn, rd = iroot(a.n), iroot(a.d)
    return rn and rd and make_frac(rn, rd) or nil
  end
  return iroot(a)
end

pow = function(a, b)
  local ta, tb = tag(a), tag(b)
  if is_nan(a) or is_nan(b) then
    return float(0 / 0)
  end
  if ta == "str" or tb == "str" or ta == "date" or tb == "date" then
    error("bad argument for ^")
  end
  if ta == "vec" and is_int(b) then
    return mat_pow(a, b)
  end
  local ext = ext_op("^", a, b)
  if ext ~= nil then
    return ext
  end
  if is_real(a) and is_real(b) then
    if tb == "int" then
      if b >= 0 then
        if ta == "frac" then
          return make_frac(int_pow(a.n, b), int_pow(a.d, b))
        end
        return int_pow(a, b)
      end
      local p = int_pow(a, -b)
      if is_zero(p) then
        return op("^", a, b)
      end
      return div(1, p)
    end
    local x, y = tofloat(a), tofloat(b)
    if x < 0 then
      -- a complex root, like Calc: (-8)^(1:3) is (1., 1.7320508)
      return ext_op("^", { tag = "cplx", re = a, im = 0 }, b)
    end
    if tb == "frac" and b.d <= 10 and ta ~= "float" then
      -- exact roots: 4^(1:2) is 2, 8^(2:3) is 4
      local root = exact_root(a, b.d)
      if root then
        return pow(root, b.n)
      end
    end
    return float(x ^ y)
  end
  -- math-pow
  if is_zero(a) then
    if is_real(b) and not negative(b) and not is_zero(b) then
      return tag(b) == "float" and to_float_early(a) or a
    end
    return op("^", a, b)
  elseif equal_int(a, 1) or equal_int(b, 1) then
    return a
  elseif is_zero(b) then
    return (is_float_obj(a) or tag(b) == "float") and float(1) or 1
  end
  return pow_symb(a, b)
end

--- Set the operations defined in later files: the arithmetic of the forms
--- (org.table.calc.forms) and the matrix products (org.table.calc_vec).
local function set_ext_op(f)
  ext_op = f
end
local function set_mat(m, d, p)
  mat_mul, mat_div, mat_pow = m, d, p
end

--- Turn Calc's math-simplifying on or off; returns the previous state.
local function set_simplifying(on)
  local old = simplifying
  simplifying = on
  return old
end

return {
  sym = sym,
  op = op,
  call = call,
  is_nan = is_nan,
  num_cmp = num_cmp,
  is_zero = is_zero,
  negative = negative,
  add = add,
  sub = sub,
  mul = mul,
  div = div,
  pow = pow,
  neg = neg,
  FANCY_TAGS = FANCY_TAGS,
  F = F,
  same = same,
  is_object = is_object,
  is_objvec = is_objvec,
  is_number = is_number,
  equal_int = equal_int,
  looks_neg = looks_neg,
  known_nonneg = known_nonneg,
  known_num_integer = known_num_integer,
  known_scalar = known_scalar,
  combine_sum = combine_sum,
  combine_prod = combine_prod,
  real_mul = real_mul,
  set_ext_op = set_ext_op,
  set_mat = set_mat,
  set_simplifying = set_simplifying,
}
