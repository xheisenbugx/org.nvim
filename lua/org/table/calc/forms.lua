---@mod org.table.calc.forms Calc: complex numbers, HMS forms, error forms, intervals and modulo forms

local values = require("org.table.calc.values")
local arith = require("org.table.calc.arith")
local functions = require("org.table.calc.functions")

local tag = values.tag
local is_int = values.is_int
local is_real = values.is_real
local modes = values.modes
local float = values.float
local tofloat = values.tofloat
local call = arith.call
local num_cmp = arith.num_cmp
local is_zero = arith.is_zero
local negative = arith.negative
local sub = arith.sub
local add = arith.add
local mul = arith.mul
local pow = arith.pow
local div = arith.div
local neg = arith.neg
local FANCY_TAGS = arith.FANCY_TAGS
local F = arith.F
local same = arith.same
local equal_int = arith.equal_int
local known_nonneg = arith.known_nonneg
local EXT_FN = functions.EXT_FN
local numeric = functions.numeric
local from_angle = functions.from_angle
local modulo = functions.modulo

---------------------------------------------------------------------------
-- Complex numbers, HMS forms, error forms and intervals
---------------------------------------------------------------------------
-- complex: { tag = "cplx", re = real, im = real } (im ~= 0)
-- polar:   { tag = "polar", r = real, t = real } (t in the angle mode)
-- hms:     { tag = "hms", h = int, m = int, s = real } (all <= 0 if negative)
-- sdev:    { tag = "sdev", x = real, s = real } (error form x +/- s)
-- intv:    { tag = "intv", mask = 0..3, lo = real, hi = real } (mask: 2 =
--          low end closed, 1 = high end closed, like Calc)

local function to_float(v)
  return float(tofloat(v))
end

--- A complex number, or a real when the imaginary part is zero (Calc's
--- math-normalize).
local function cplx(re, im)
  if is_zero(im) then
    return re
  end
  return { tag = "cplx", re = re, im = im }
end

--- A pure imaginary number: its real part is 0. when `im` is a float.
local function imaginary(im)
  return cplx(tag(im) == "float" and float(0) or 0, im)
end

local function half_turn()
  return modes.deg and 180 or float(math.pi)
end

local function polar(r, t)
  if is_zero(r) then
    return r
  end
  -- normalize the angle to (-180, 180]
  local full = modes.deg and 360 or 2 * math.pi
  local tv = tofloat(t)
  while tv > full / 2 do
    t, tv = sub(t, modes.deg and 360 or float(full)), tv - full
  end
  while tv <= -full / 2 do
    t, tv = add(t, modes.deg and 360 or float(full)), tv + full
  end
  if is_zero(t) then
    return r
  end
  return { tag = "polar", r = r, t = t }
end

--- Rectangular parts of a real, complex or polar number.
local function rect_parts(v)
  local t = tag(v)
  if t == "cplx" then
    return v.re, v.im
  elseif t == "polar" then
    return to_float(mul(v.r, F.cos({ v.t }))), to_float(mul(v.r, F.sin({ v.t })))
  end
  return v, 0
end

local function c_abs(v)
  local re, im = rect_parts(v)
  return F.sqrt({ add(mul(re, re), mul(im, im)) })
end

local function c_arg(v)
  local t = tag(v)
  if t == "polar" then
    return v.t
  elseif t == "cplx" then
    return float(from_angle(math.atan2(tofloat(v.im), tofloat(v.re))))
  end
  return negative(v) and half_turn() or 0
end

local function to_polar(v)
  if tag(v) == "polar" then
    return v
  end
  return polar(c_abs(v), to_float(c_arg(v)))
end

--- Round away components that are noise next to the other one (like Calc,
--- which gets `(-4)^1.5` as `(0., -8.)`).
local function c_clean(re, im)
  local x, y = tofloat(re), tofloat(im)
  local scale = math.max(math.abs(x), math.abs(y)) * 10 ^ -(modes.prec + 1)
  if math.abs(x) < scale then
    re = float(0)
  end
  if math.abs(y) < scale then
    im = float(0)
  end
  return cplx(re, im)
end

local function c_exp(v)
  local re, im = rect_parts(v)
  local m = math.exp(tofloat(re))
  return c_clean(float(m * math.cos(tofloat(im))), float(m * math.sin(tofloat(im))))
end

local function c_ln(v)
  local re, im = rect_parts(v)
  local x, y = tofloat(re), tofloat(im)
  return cplx(float(math.log(math.sqrt(x * x + y * y))), float(math.atan2(y, x)))
end

--- Magnitude and angle of a real, complex or polar number.
local function polar_parts(v)
  if tag(v) == "cplx" then
    v = to_polar(v)
  end
  if tag(v) == "polar" then
    return v.r, v.t
  end
  return F.abs({ v }), negative(v) and half_turn() or 0
end

local c_binary

local function c_pow(a, b)
  if type(b) == "number" then
    if b < 0 then
      return c_binary("/", 1, c_pow(a, -b))
    end
    local r, base, n = 1, a, b
    while n > 0 do
      if n % 2 == 1 then
        r = c_binary("*", r, base)
      end
      n = math.floor(n / 2)
      if n > 0 then
        base = c_binary("*", base, base)
      end
    end
    return r
  end
  if is_zero(a) then
    return 0
  end
  -- exp(b ln(a)) in doubles, rounded once at the end
  local ar, ai = rect_parts(a)
  local br, bi = rect_parts(b)
  local x, y = tofloat(ar), tofloat(ai)
  local lr, li = math.log(math.sqrt(x * x + y * y)), math.atan2(y, x)
  local pr, pim = tofloat(br) * lr - tofloat(bi) * li, tofloat(br) * li + tofloat(bi) * lr
  local m = math.exp(pr)
  return c_clean(float(m * math.cos(pim)), float(m * math.sin(pim)))
end

--- Arithmetic when a complex or polar number is involved.
c_binary = function(o, a, b)
  if (tag(a) == "polar" or tag(b) == "polar") and (o == "*" or o == "/" or o == "^") then
    local ra, ta = polar_parts(a)
    if o == "^" then
      if type(b) ~= "number" then
        return to_polar(c_pow(cplx(rect_parts(a)), b))
      end
      return polar(pow(ra, b), mul(ta, b))
    end
    local rb, tb = polar_parts(b)
    if o == "*" then
      return polar(mul(ra, rb), add(ta, tb))
    end
    return polar(div(ra, rb), sub(ta, tb))
  end
  local was_polar = tag(a) == "polar" or tag(b) == "polar"
  local ar, ai = rect_parts(a)
  local br, bi = rect_parts(b)
  local r
  if o == "+" then
    r = cplx(add(ar, br), add(ai, bi))
  elseif o == "-" then
    r = cplx(sub(ar, br), sub(ai, bi))
  elseif o == "*" then
    r = cplx(sub(mul(ar, br), mul(ai, bi)), add(mul(ar, bi), mul(ai, br)))
  elseif o == "/" then
    local den = add(mul(br, br), mul(bi, bi))
    if is_zero(den) then
      return nil
    end
    r = cplx(div(add(mul(ar, br), mul(ai, bi)), den), div(sub(mul(ai, br), mul(ar, bi)), den))
  elseif o == "^" then
    r = c_pow(cplx(ar, ai), b)
  end
  if was_polar and r ~= nil then
    return to_polar(r)
  end
  return r
end

-- HMS forms

--- An HMS form from hours, minutes and seconds (any reals), with the carries
--- done and all parts of the same sign (math-normalize-hms).
local function hms(h, m, s)
  if tofloat(h) + tofloat(m) / 60 + tofloat(s) / 3600 < 0 then
    local r = hms(neg(h), neg(m), neg(s))
    return { tag = "hms", h = neg(r.h), m = neg(r.m), s = neg(r.s) }
  end
  -- fractions of hours and minutes go down, whole minutes and hours up
  if not is_int(h) then
    local hi = F.floor({ h })
    m, h = add(m, mul(sub(h, hi), 60)), hi
  end
  if not is_int(m) then
    local mi = F.floor({ m })
    s, m = add(s, mul(sub(m, mi), 60)), mi
  end
  local q = F.floor({ div(s, 60) })
  s, m = sub(s, mul(q, 60)), add(m, q)
  q = F.floor({ div(m, 60) })
  m, h = sub(m, mul(q, 60)), add(h, q)
  return { tag = "hms", h = h, m = m, s = s }
end

--- An HMS form of a real number of hours (or degrees).
local function to_hms(x)
  if tag(x) == "hms" then
    return x
  end
  local h = F.trunc({ x })
  local rem = mul(sub(x, h), 60)
  local m = F.trunc({ rem })
  return hms(h, m, mul(sub(rem, m), 60))
end

--- The number of hours (degrees) of an HMS form, as a float.
local function hms_value(v)
  return float(tofloat(v.h) + tofloat(v.m) / 60 + tofloat(v.s) / 3600)
end

local function hms_binary(o, a, b)
  local ta, tb = tag(a), tag(b)
  if o == "+" or o == "-" then
    if not ((ta == "hms" or is_real(a)) and (tb == "hms" or is_real(b))) then
      return nil
    end
    a, b = to_hms(a), to_hms(b)
    if o == "-" then
      b = { tag = "hms", h = neg(b.h), m = neg(b.m), s = neg(b.s) }
    end
    return hms(add(a.h, b.h), add(a.m, b.m), add(a.s, b.s))
  elseif o == "*" then
    if ta == "hms" and is_real(b) then
      return to_hms(mul(hms_value(a), b))
    elseif tb == "hms" and is_real(a) then
      return to_hms(mul(a, hms_value(b)))
    end
  elseif o == "/" then
    if ta == "hms" and tb == "hms" then
      return div(hms_value(a), hms_value(b))
    elseif ta == "hms" and is_real(b) and not is_zero(b) then
      return to_hms(div(hms_value(a), b))
    end
  end
  return nil
end

-- Error forms

local function sdev(x, s)
  return { tag = "sdev", x = x, s = F.abs({ s }) }
end

local function sdev_parts(v)
  if tag(v) == "sdev" then
    return v.x, v.s
  end
  return v, 0
end

local function hypot2(a, b)
  if is_zero(a) then
    return F.abs({ b })
  elseif is_zero(b) then
    return F.abs({ a })
  end
  return F.sqrt({ add(mul(a, a), mul(b, b)) })
end

local function sdev_binary(o, a, b)
  local ax, as = sdev_parts(a)
  local bx, bs = sdev_parts(b)
  if not (is_real(ax) and is_real(as) and is_real(bx) and is_real(bs)) then
    return nil
  end
  if o == "+" then
    return sdev(add(ax, bx), hypot2(as, bs))
  elseif o == "-" then
    return sdev(sub(ax, bx), hypot2(as, bs))
  elseif o == "*" then
    return sdev(mul(ax, bx), hypot2(mul(bx, as), mul(ax, bs)))
  elseif o == "/" then
    if is_zero(bx) then
      return nil
    end
    return sdev(div(ax, bx), hypot2(div(as, bx), div(mul(ax, bs), mul(bx, bx))))
  elseif o == "^" and type(b) == "number" then
    return sdev(pow(ax, b), mul(F.abs({ mul(b, pow(ax, b - 1)) }), as))
  end
  return nil
end

-- Intervals

local function intv(mask, lo, hi)
  return { tag = "intv", mask = mask, lo = lo, hi = hi }
end

local function intv_parts(v)
  if tag(v) == "intv" then
    return v.lo, v.hi, math.floor(v.mask / 2) == 1, v.mask % 2 == 1
  end
  return v, v, true, true
end

local function intv_mask(lo_closed, hi_closed)
  return (lo_closed and 2 or 0) + (hi_closed and 1 or 0)
end

local function intv_binary(o, a, b)
  local alo, ahi, alc, ahc = intv_parts(a)
  local blo, bhi, blc, bhc = intv_parts(b)
  if not (is_real(alo) and is_real(ahi) and is_real(blo) and is_real(bhi)) then
    return nil
  end
  if o == "+" then
    return intv(intv_mask(alc and blc, ahc and bhc), add(alo, blo), add(ahi, bhi))
  elseif o == "-" then
    return intv(intv_mask(alc and bhc, ahc and blc), sub(alo, bhi), sub(ahi, blo))
  elseif o == "*" or (o == "/" and tag(b) ~= "intv" and not is_zero(b)) then
    local f = o == "*" and mul or div
    -- the extremes of the products of the ends
    local best_lo, best_hi
    for _, x in ipairs({ { alo, alc }, { ahi, ahc } }) do
      for _, y in ipairs({ { blo, blc }, { bhi, bhc } }) do
        local v, closed = f(x[1], y[1]), x[2] and y[2]
        if not best_lo or num_cmp(v, best_lo[1]) < 0 or (num_cmp(v, best_lo[1]) == 0 and closed) then
          best_lo = { v, closed }
        end
        if not best_hi or num_cmp(v, best_hi[1]) > 0 or (num_cmp(v, best_hi[1]) == 0 and closed) then
          best_hi = { v, closed }
        end
      end
    end
    return intv(intv_mask(best_lo[2], best_hi[2]), best_lo[1], best_hi[1])
  end
  return nil
end

-- Modulo forms

--- math-make-mod: `n mod m` for real numbers, the modulus positive.
local function make_mod(n, m)
  if not is_real(m) or not (tofloat(m) > 0) then
    error("bad modulus")
  end
  if negative(n) or num_cmp(n, m) >= 0 then
    n = modulo(n, m)
  end
  return { tag = "mod", n = n, m = m }
end

--- a / b modulo m for integers (math-div-mod), or nil without a solution.
local function div_mod(a, b, m)
  if not (type(a) == "number" and type(b) == "number" and type(m) == "number") then
    return nil
  end
  local u1, u3, v1, v3 = 1, b, 0, m
  while v3 ~= 0 do
    local q = math.floor(u3 / v3)
    u1, u3, v1, v3 = v1, v3, u1 - v1 * q, u3 - v3 * q
  end
  if a % u3 ~= 0 then
    return nil
  end
  return (a / u3 * u1) % m
end

--- a^b modulo m (math-pow-mod).
local function pow_mod(a, b, m)
  if type(a) == "number" and type(b) == "number" and type(m) == "number" and m < 2 ^ 26 then
    if b < 0 then
      local p = pow_mod(a, -b, m)
      return p and div_mod(1, p, m)
    end
    local r, base, n = 1, a % m, b
    while n > 0 do
      if n % 2 == 1 then
        r = r * base % m
      end
      base, n = base * base % m, math.floor(n / 2)
    end
    return r
  end
  return modulo(pow(a, b), m)
end

local function mod_binary(o, a, b)
  local ta, tb = tag(a), tag(b)
  local m, x, y
  if ta == "mod" and tb == "mod" then
    if not same(a.m, b.m) then
      return nil
    end
    m, x, y = a.m, a.n, b.n
  elseif ta == "mod" and is_real(b) then
    m, x, y = a.m, a.n, b
  elseif tb == "mod" and is_real(a) then
    m, x, y = b.m, a, b.n
  else
    return nil
  end
  local r
  if o == "+" then
    r = add(x, y)
  elseif o == "-" then
    r = sub(x, y)
  elseif o == "*" then
    r = mul(x, y)
  elseif o == "/" then
    r = div_mod(x, y, m)
  elseif o == "^" then
    r = pow_mod(x, y, m)
  end
  return r ~= nil and make_mod(r, m) or nil
end

local function ext_op(o, a, b)
  local ta = tag(a)
  if o == "neg" then
    if ta == "mod" then
      return is_zero(a.n) and a or make_mod(sub(a.m, a.n), a.m)
    elseif ta == "cplx" then
      return cplx(neg(a.re), neg(a.im))
    elseif ta == "polar" then
      return polar(a.r, add(a.t, half_turn()))
    elseif ta == "hms" then
      return { tag = "hms", h = neg(a.h), m = neg(a.m), s = neg(a.s) }
    elseif ta == "sdev" then
      return sdev(neg(a.x), a.s)
    elseif ta == "intv" then
      return intv(intv_mask(a.mask % 2 == 1, math.floor(a.mask / 2) == 1), neg(a.hi), neg(a.lo))
    end
    return nil
  end
  local tb = tag(b)
  if not (FANCY_TAGS[ta] or FANCY_TAGS[tb]) then
    return nil
  end
  if not ((FANCY_TAGS[ta] or is_real(a)) and (FANCY_TAGS[tb] or is_real(b))) then
    return nil -- symbolic
  end
  if ta == "mod" or tb == "mod" then
    return mod_binary(o, a, b)
  elseif ta == "hms" or tb == "hms" then
    return hms_binary(o, a, b)
  elseif ta == "sdev" or tb == "sdev" then
    return sdev_binary(o, a, b)
  elseif ta == "intv" or tb == "intv" then
    return intv_binary(o, a, b)
  end
  return c_binary(o, a, b)
end
arith.set_ext_op(ext_op)

--- makemod(n, m), `n mod m`: a formula spreads the modulus over its terms
--- (math-make-mod), `x mod 7` is `(1 mod 7) x`.
local function make_mod_expr(n, m)
  local t = tag(n)
  if is_real(n) then
    return make_mod(n, m)
  elseif t == "vec" then
    local out = { tag = "vec" }
    for i, x in ipairs(n) do
      out[i] = make_mod_expr(x, m)
    end
    return out
  elseif t == "neg" then
    return neg(make_mod_expr(n.a, m))
  elseif t == "op" and (n.op == "+" or n.op == "-" or n.op == "/") then
    local f = ({ ["+"] = add, ["-"] = sub, ["/"] = div })[n.op]
    return f(make_mod_expr(n.a, m), make_mod_expr(n.b, m))
  elseif t == "op" and n.op == "*" and is_real(n.a) then
    return mul(make_mod(n.a, m), n.b)
  elseif t == "sym" or (t == "op" and (n.op == "*" or n.op == "^")) then
    return mul(make_mod(1, m), n)
  end
  error("bad argument for mod")
end
F.makemod = function(args)
  local n, m = args[1], args[2]
  if #args == 2 and is_real(m) and tofloat(m) > 0 then
    return make_mod_expr(tag(n) == "mod" and n.n or n, m)
  end
  return call("makemod", args)
end

-- Complex functions: the real ones that give complex results too
local real_sqrt, real_ln, real_log10 = F.sqrt, F.ln, F.log10
F.sqrt = function(args)
  local x = args[1]
  if #args == 1 and is_real(x) and negative(x) then
    return imaginary(real_sqrt({ neg(x) }))
  elseif #args == 1 and tag(x) == "op" then
    -- the square root of a product or quotient with a known non-negative
    -- part splits (math-sqrt): sqrt(4 x) is 2 sqrt(x)
    local a, b = x.a, x.b
    if x.op == "*" and (known_nonneg(a) or known_nonneg(b)) then
      return mul(F.sqrt({ a }), F.sqrt({ b }))
    elseif x.op == "/" and known_nonneg(b) then
      return div(F.sqrt({ a }), F.sqrt({ b }))
    elseif x.op == "/" and known_nonneg(a) and not equal_int(a, 1) then
      return mul(F.sqrt({ a }), F.sqrt({ div(1, b) }))
    end
  end
  return real_sqrt(args)
end
F.ln = function(args)
  local x = args[1]
  if #args == 1 and is_real(x) and negative(x) then
    return cplx(float(math.log(-tofloat(x))), float(math.pi))
  elseif #args == 1 and tag(x) == "sym" and x.name == "e" then
    return 1
  end
  return real_ln(args)
end
F.log10 = function(args)
  local x = args[1]
  if #args == 1 and is_real(x) and negative(x) then
    return EXT_FN.log10({ tag = "cplx", re = x, im = 0 })
  end
  return real_log10(args)
end
F.log = function(args)
  if #args == 2 then
    local x, b = args[1], args[2]
    if is_int(x) and is_int(b) and type(x) == "number" and type(b) == "number" and x > 0 and b > 1 then
      -- exact integer logarithms: log(8, 2) is 3
      local n, p = x, 0
      while n % b == 0 do
        n, p = n / b, p + 1
      end
      if n == 1 then
        return p
      end
    end
    if is_real(x) and is_real(b) and tofloat(x) > 0 and tofloat(b) > 0 then
      return float(math.log(tofloat(x)) / math.log(tofloat(b)))
    elseif x == 1 then
      return 0
    elseif tag(b) == "sym" and b.name == "e" then
      return F.ln({ x })
    elseif same(x, b) then
      return 1
    end
    return call("log", args)
  end
  return F.ln(args)
end

EXT_FN.sqrt = function(x)
  local t = tag(x)
  if t == "sdev" then
    local r = F.sqrt({ x.x })
    return sdev(r, div(x.s, mul(2, r)))
  elseif t == "cplx" or t == "polar" then
    local re, im = rect_parts(x)
    local d = tofloat(c_abs(x))
    local a, b = tofloat(re), tofloat(im)
    local r = cplx(float(math.sqrt((d + a) / 2)), float((b < 0 and -1 or 1) * math.sqrt((d - a) / 2)))
    return t == "polar" and to_polar(r) or r
  end
end
EXT_FN.abs = function(x)
  local t = tag(x)
  if t == "cplx" then
    return c_abs(x)
  elseif t == "polar" then
    return F.abs({ x.r })
  elseif t == "sdev" then
    return sdev(F.abs({ x.x }), x.s)
  elseif t == "hms" then
    if negative(x.h) or negative(x.m) or negative(x.s) then
      return ext_op("neg", x)
    end
    return x
  end
end
EXT_FN.exp = function(x)
  if tag(x) == "sdev" then
    local r = F.exp({ x.x })
    return sdev(r, mul(r, x.s))
  elseif tag(x) == "cplx" or tag(x) == "polar" then
    return c_exp(x)
  end
end
EXT_FN.ln = function(x)
  if tag(x) == "sdev" then
    return sdev(F.ln({ x.x }), div(x.s, F.abs({ x.x })))
  elseif tag(x) == "cplx" or tag(x) == "polar" then
    return c_ln(x)
  end
end
EXT_FN.log = EXT_FN.ln
EXT_FN.log10 = function(x)
  if tag(x) == "cplx" or tag(x) == "polar" then
    local re, im = rect_parts(x)
    local a, b = tofloat(re), tofloat(im)
    local l10 = math.log(10)
    return cplx(float(math.log(math.sqrt(a * a + b * b)) / l10), float(math.atan2(b, a) / l10))
  end
end
-- sin, cos, tan of complex numbers (the argument in the angle mode) and of
-- HMS forms (an angle in degrees)
local function angle_arg(x)
  if tag(x) == "hms" then
    local d = hms_value(x)
    return modes.deg and d or float(tofloat(d) * math.pi / 180), true
  end
  local re, im = rect_parts(x)
  local k = modes.deg and math.pi / 180 or 1
  return tofloat(re) * k, tofloat(im) * k
end
local function c_sin(a, b)
  return c_clean(float(math.sin(a) * math.cosh(b)), float(math.cos(a) * math.sinh(b)))
end
local function c_cos(a, b)
  return c_clean(float(math.cos(a) * math.cosh(b)), float(-math.sin(a) * math.sinh(b)))
end
for name, f in pairs({ sin = c_sin, cos = c_cos, tan = false, sec = false, csc = false, cot = false }) do
  EXT_FN[name] = function(x)
    local a, b = angle_arg(x)
    if b == true then
      return F[name]({ a })
    elseif tag(x) ~= "cplx" and tag(x) ~= "polar" then
      return nil
    end
    local s, c = c_sin(a, b), c_cos(a, b)
    if f then
      return f(a, b)
    elseif name == "tan" then
      return c_binary("/", s, c)
    elseif name == "sec" then
      return c_binary("/", 1, c)
    elseif name == "csc" then
      return c_binary("/", 1, s)
    end
    return c_binary("/", c, s)
  end
end
-- arcsin, arccos and arctan of complex numbers, and of reals beyond
-- [-1, 1] (math-arcsin-raw: -i ln(i z + sqrt(1 - z^2)))
local function c_arcsin_raw(x, y)
  local ra, ia = 1 - (x * x - y * y), -2 * x * y
  local d = math.sqrt(ra * ra + ia * ia)
  local sr, si = math.sqrt((d + ra) / 2), math.sqrt((d - ra) / 2)
  if ia < 0 then
    si = -si
  end
  local wr, wi = -y + sr, x + si
  return math.atan2(wi, wr), -math.log(math.sqrt(wr * wr + wi * wi))
end
local function c_from_radians(re, im)
  local k = modes.deg and 180 / math.pi or 1
  return c_clean(float(re * k), float(im * k))
end
local C_INVERSE_TRIG = {
  arcsin = c_arcsin_raw,
  arccos = function(x, y)
    local re, im = c_arcsin_raw(x, y)
    return math.pi / 2 - re, -im
  end,
  arctan = function(x, y)
    -- (ln(1 + i z) - ln(1 - i z)) / 2i
    local ar, ai = 1 - y, x
    local br, bi = 1 + y, -x
    local lr = math.log(math.sqrt(ar * ar + ai * ai)) - math.log(math.sqrt(br * br + bi * bi))
    local li = math.atan2(ai, ar) - math.atan2(bi, br)
    return li / 2, -lr / 2
  end,
}
for name, f in pairs(C_INVERSE_TRIG) do
  EXT_FN[name] = function(z)
    if tag(z) == "cplx" or tag(z) == "polar" then
      local re, im = rect_parts(z)
      return c_from_radians(f(tofloat(re), tofloat(im)))
    end
  end
  if name ~= "arctan" then
    local real_fn = F[name]
    F[name] = function(args)
      local x = args[1]
      if #args == 1 and is_real(x) and math.abs(tofloat(x)) > 1 then
        return c_from_radians(f(tofloat(x), 0))
      end
      return real_fn(args)
    end
  end
end
F.asin, F.acos = F.arcsin, F.arccos
EXT_FN.arg = function(x)
  return c_arg(x)
end
F.arg = numeric("arg", c_arg)
F.re = numeric("re", function(x)
  return x
end)
F.im = numeric("im", function()
  return 0
end)
F.conj = numeric("conj", function(x)
  return x
end)
EXT_FN.re = function(x)
  return (rect_parts(x))
end
EXT_FN.im = function(x)
  return select(2, rect_parts(x))
end
EXT_FN.conj = function(x)
  if tag(x) == "polar" then
    return polar(x.r, neg(x.t))
  elseif tag(x) == "cplx" then
    return cplx(x.re, neg(x.im))
  end
end
F.polar = numeric("polar", function(x)
  return to_polar(x)
end)
EXT_FN.polar = function(x)
  if tag(x) == "cplx" or tag(x) == "polar" then
    return to_polar(x)
  end
end
F.rect = numeric("rect", function(x)
  return x
end)
EXT_FN.rect = function(x)
  if tag(x) == "cplx" or tag(x) == "polar" then
    return cplx(rect_parts(x))
  end
end

-- HMS functions
F.hms = function(args)
  if #args == 3 and is_real(args[1]) and is_real(args[2]) and is_real(args[3]) then
    return hms(args[1], args[2], args[3])
  end
  local x = args[1]
  if #args == 1 and tag(x) == "hms" then
    return x
  elseif #args == 1 and is_real(x) then
    return to_hms(modes.deg and x or float(tofloat(x) * 180 / math.pi))
  end
  return call("hms", args)
end
EXT_FN.deg = function(x)
  if tag(x) == "hms" then
    return hms_value(x)
  end
end
EXT_FN.rad = function(x)
  if tag(x) == "hms" then
    return float(tofloat(hms_value(x)) * math.pi / 180)
  end
end
-- error forms and intervals as functions
F.sdev = function(args)
  if is_real(args[1]) and is_real(args[2]) then
    return sdev(args[1], args[2])
  end
  return call("sdev", args)
end
F.intv = function(args)
  if type(args[1]) == "number" and is_real(args[2]) and is_real(args[3]) then
    return intv(args[1], args[2], args[3])
  end
  return call("intv", args)
end

return {
  to_float = to_float,
  cplx = cplx,
  polar = polar,
  hms = hms,
  hms_value = hms_value,
  intv = intv,
  ext_op = ext_op,
}
