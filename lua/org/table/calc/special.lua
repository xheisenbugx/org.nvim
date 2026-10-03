---@mod org.table.calc.special Calc: more functions
---
--- Roots and means, rounding, gamma and primes, hyperbolic and other
--- trigonometric functions, 32-bit words, date arithmetic, evalv.

local values = require("org.table.calc.values")
local arith = require("org.table.calc.arith")
local functions = require("org.table.calc.functions")
local forms = require("org.table.calc.forms")

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
local op = arith.op
local call = arith.call
local is_zero = arith.is_zero
local pow = arith.pow
local add = arith.add
local div = arith.div
local sub = arith.sub
local neg = arith.neg
local mul = arith.mul
local F = arith.F
local real_mul = arith.real_mul
local flatten = functions.flatten
local numeric = functions.numeric
local float_fn = functions.float_fn
local to_float = forms.to_float

---------------------------------------------------------------------------
-- More functions
---------------------------------------------------------------------------

F.nroot = numeric("nroot", function(x, n)
  if type(n) ~= "number" or n < 1 or n ~= math.floor(n) then
    return nil
  end
  local v = tofloat(x)
  if v < 0 and n % 2 == 0 then
    return nil
  end
  local r = (v < 0 and -1 or 1) * math.abs(v) ^ (1 / n)
  if type(x) == "number" then
    local ri = math.floor(r + 0.5)
    if ri ^ n == x then
      return ri
    end
  end
  return float(r)
end)
-- nroot of a formula is a fractional power: nroot(x, 3) is x^1:3
local real_nroot = F.nroot
F.nroot = function(args)
  local x, n = args[1], args[2]
  if #args == 2 and type(n) == "number" and n >= 1 and n == math.floor(n) and not is_real(x) then
    if is_symbolic(x) or tag(x) == "vec" then
      return pow(x, make_frac(1, n))
    end
  end
  return real_nroot(args)
end
F.vgmean = function(args)
  local vals = flatten(args)
  for _, v in ipairs(vals) do
    if not is_real(v) then
      return call("vgmean", args)
    end
  end
  if #vals == 0 then
    return call("vgmean", args)
  end
  return F.nroot({ F.vprod(vals), #vals })
end
F.vhmean = function(args)
  local vals = flatten(args)
  if #vals == 0 then
    return call("vhmean", args)
  end
  local s = 0
  for _, v in ipairs(vals) do
    s = add(s, div(1, v))
  end
  return div(#vals, s)
end

-- rounding: rounde (half to even), roundu (half up)
F.rounde = numeric("rounde", function(x)
  if is_int(x) then
    return x
  end
  local v = tofloat(x)
  local f = math.floor(v)
  local d = v - f
  if d > 0.5 or (d == 0.5 and f % 2 == 1) then
    f = f + 1
  end
  return f
end)
F.roundu = numeric("roundu", function(x)
  if is_int(x) then
    return x
  end
  return math.floor(tofloat(x) + 0.5)
end)
F.fdiv = numeric("fdiv", function(a, b)
  if is_zero(b) then
    return nil
  end
  local saved = modes.frac
  modes.frac = true
  local r = div(a, b)
  modes.frac = saved
  return r
end)
F.float = numeric("float", function(x)
  return to_float(x)
end)

-- Gamma (Lanczos approximation, g = 7), factorials and primes
local LANCZOS = {
  0.99999999999980993,
  676.5203681218851,
  -1259.1392167224028,
  771.32342877765313,
  -176.61502916214059,
  12.507343278686905,
  -0.13857109526572012,
  9.9843695780195716e-6,
  1.5056327351493116e-7,
}
local function gamma(x)
  if x < 0.5 then
    return math.pi / (math.sin(math.pi * x) * gamma(1 - x))
  end
  x = x - 1
  local a = LANCZOS[1]
  local t = x + 7.5
  for i = 2, 9 do
    a = a + LANCZOS[i] / (x + i - 1)
  end
  return math.sqrt(2 * math.pi) * t ^ (x + 0.5) * math.exp(-t) * a
end
F.gamma = numeric("gamma", function(x)
  if is_int(x) then
    if tofloat(x) <= 0 then
      return nil
    end
    return F.fact({ sub(x, 1) })
  end
  return float(gamma(tofloat(x)))
end)
F.dfact = numeric("dfact", function(n)
  if type(n) ~= "number" or n < 0 then
    return nil
  end
  local r = 1
  for i = n, 2, -2 do
    r = real_mul(r, i)
  end
  return r
end)
local function is_prime(n)
  if n < 2 then
    return false
  end
  if n % 2 == 0 then
    return n == 2
  end
  for d = 3, math.floor(math.sqrt(n)), 2 do
    if n % d == 0 then
      return false
    end
  end
  return true
end
local function int_arg(fn)
  return function(n, ...)
    if type(n) ~= "number" or math.abs(n) > 1e12 then
      return nil
    end
    return fn(n, ...)
  end
end
F.prime = numeric(
  "prime",
  int_arg(function(n)
    return is_prime(n) and 1 or 0
  end)
)
F.nextprime = numeric(
  "nextprime",
  int_arg(function(n)
    n = math.max(n + 1, 2)
    while not is_prime(n) do
      n = n + 1
    end
    return n
  end)
)
F.prevprime = numeric(
  "prevprime",
  int_arg(function(n)
    n = n - 1
    while n >= 2 and not is_prime(n) do
      n = n - 1
    end
    return n >= 2 and n or nil
  end)
)
F.totient = numeric(
  "totient",
  int_arg(function(n)
    n = math.abs(n)
    local r, p = n, 2
    while p * p <= n do
      if n % p == 0 then
        while n % p == 0 do
          n = n / p
        end
        r = r - r / p
      end
      p = p + 1
    end
    if n > 1 then
      r = r - r / n
    end
    return r
  end)
)

-- sec, csc, cot and the inverse hyperbolic functions
for name, base in pairs({ sec = "cos", csc = "sin", cot = "tan" }) do
  F[name] = numeric(name, function(x)
    local r = F[base]({ x })
    if is_zero(r) then
      return nil
    end
    return to_float(div(1, r))
  end)
end
F.arcsinh = numeric(
  "arcsinh",
  float_fn(function(x)
    return math.log(x + math.sqrt(x * x + 1))
  end)
)
F.arccosh = numeric(
  "arccosh",
  float_fn(function(x)
    return x >= 1 and math.log(x + math.sqrt(x * x - 1)) or 0 / 0
  end)
)
F.arctanh = numeric(
  "arctanh",
  float_fn(function(x)
    return math.abs(x) < 1 and 0.5 * math.log((1 + x) / (1 - x)) or 0 / 0
  end)
)

-- Binary operations on 32-bit words (calc-word-size 32)
local WORD = 2 ^ 32
local function bitop(a, b, f)
  a, b = a % WORD, b % WORD
  local r, bitv = 0, 1
  for _ = 1, 32 do
    if f(a % 2, b % 2) then
      r = r + bitv
    end
    a, b, bitv = math.floor(a / 2), math.floor(b / 2), bitv * 2
  end
  return r
end
--- A function of integers (the arguments `min`..`max`), symbolic otherwise.
local function word(name, min, max, fn)
  F[name] = function(args)
    if #args < min or #args > max then
      return call(name, args)
    end
    for _, a in ipairs(args) do
      if type(a) ~= "number" then
        return call(name, args)
      end
    end
    return fn(unpack(args))
  end
end
word("and", 2, 2, function(a, b)
  return bitop(a, b, function(x, y)
    return x == 1 and y == 1
  end)
end)
word("or", 2, 2, function(a, b)
  return bitop(a, b, function(x, y)
    return x == 1 or y == 1
  end)
end)
word("xor", 2, 2, function(a, b)
  return bitop(a, b, function(x, y)
    return x ~= y
  end)
end)
word("diff", 2, 2, function(a, b)
  return bitop(a, b, function(x, y)
    return x == 1 and y == 0
  end)
end)
word("not", 1, 1, function(a)
  return WORD - 1 - a % WORD
end)
word("lsh", 1, 2, function(a, n)
  n = n or 1
  if n < 0 then
    return math.floor((a % WORD) / 2 ^ -n)
  end
  return (a % WORD) * 2 ^ n % WORD
end)
word("rsh", 1, 2, function(a, n)
  return F.lsh({ a, -(n or 1) })
end)
word("ash", 1, 2, function(a, n)
  n = n or 1
  if n >= 0 then
    return F.lsh({ a, n })
  end
  -- arithmetic shift right: the sign bit is copied
  local u = a % WORD
  local signed = u >= WORD / 2 and u - WORD or u
  return math.floor(signed / 2 ^ -n) % WORD
end)

-- Dates
local function date_arg(v)
  if tag(v) == "date" then
    return v.v
  elseif is_real(v) then
    return tofloat(v)
  end
end
local function add_months(v, n)
  local day = math.floor(v)
  local y, m, d = civil_from_days(day)
  local total = y * 12 + (m - 1) + n
  y, m = math.floor(total / 12), total % 12 + 1
  local last = days_from_civil(m == 12 and y + 1 or y, m == 12 and 1 or m + 1, 1) - days_from_civil(y, m, 1)
  return { tag = "date", v = days_from_civil(y, m, math.min(d, last)) + (v - day) }
end
F.incmonth = function(args)
  local v = date_arg(args[1])
  if not v or not (args[2] == nil or type(args[2]) == "number") then
    return call("incmonth", args)
  end
  return add_months(v, args[2] or 1)
end
F.incyear = function(args)
  local v = date_arg(args[1])
  if not v or not (args[2] == nil or type(args[2]) == "number") then
    return call("incyear", args)
  end
  return add_months(v, 12 * (args[2] or 1))
end
F.newmonth = function(args)
  local v = date_arg(args[1])
  if not v then
    return call("newmonth", args)
  end
  local y, m = civil_from_days(math.floor(v))
  return { tag = "date", v = days_from_civil(y, m, 1) }
end
F.newyear = function(args)
  local v = date_arg(args[1])
  if not v then
    return call("newyear", args)
  end
  return { tag = "date", v = days_from_civil((civil_from_days(math.floor(v))), 1, 1) }
end
F.newweek = function(args)
  local v = date_arg(args[1])
  if not v then
    return call("newweek", args)
  end
  local day = math.floor(v)
  return { tag = "date", v = day - day % 7 }
end
F.julian = function(args)
  local v = date_arg(args[1])
  if not v then
    return call("julian", args)
  end
  return math.floor(v) + 1721425
end
-- unixtime(date) is seconds since the epoch (in the local time zone, like
-- Calc's default calc-time-zone); unixtime(n) is the date back
local EPOCH = days_from_civil(1970, 1, 1)
local function tz_offset(secs)
  local t = os.date("*t", secs)
  local u = os.date("!*t", secs)
  u.isdst = t.isdst
  return os.difftime(os.time(t), os.time(u))
end
F.unixtime = function(args)
  local a = args[1]
  if tag(a) == "date" then
    local secs = math.floor((a.v - EPOCH) * 86400 + 0.5)
    return secs - tz_offset(secs)
  elseif is_real(a) then
    local secs = tofloat(a)
    return { tag = "date", v = EPOCH + (secs + tz_offset(secs)) / 86400 }
  end
  return call("unixtime", args)
end

-- evalv: the value of the constants pi, e, gamma and phi in a formula
local CONSTANTS = { pi = math.pi, e = math.exp(1), gamma = 0.57721566490153286, phi = (1 + math.sqrt(5)) / 2 }
local function evalv(v)
  local t = tag(v)
  if t == "sym" then
    return CONSTANTS[v.name] and float(CONSTANTS[v.name]) or v
  elseif t == "neg" then
    return neg(evalv(v.a))
  elseif t == "op" then
    local a, b = evalv(v.a), evalv(v.b)
    local f = ({ ["+"] = add, ["-"] = sub, ["*"] = mul, ["/"] = div, ["^"] = pow })[v.op]
    return f and f(a, b) or op(v.op, a, b)
  elseif t == "call" then
    local args = {}
    for i, x in ipairs(v.args) do
      args[i] = evalv(x)
    end
    return F[v.name] and F[v.name](args) or call(v.name, args)
  elseif t == "vec" then
    local out = { tag = "vec" }
    for i, x in ipairs(v) do
      out[i] = evalv(x)
    end
    return out
  end
  return v
end
F.evalv = function(args)
  return evalv(args[1])
end

return {}
