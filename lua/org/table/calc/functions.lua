---@mod org.table.calc.functions Calc: functions of numbers, vectors and dates

local big = require("org.table.calc.big")
local values = require("org.table.calc.values")
local arith = require("org.table.calc.arith")

local MAX_EXACT = big.MAX_EXACT
local big_from_string = big.big_from_string
local big_norm = big.big_norm
local tag = values.tag
local is_int = values.is_int
local is_real = values.is_real
local modes = values.modes
local round_sig = values.round_sig
local float = values.float
local tofloat = values.tofloat
local gcd = values.gcd
local make_frac = values.make_frac
local days_from_civil = values.days_from_civil
local civil_from_days = values.civil_from_days
local call = arith.call
local is_nan = arith.is_nan
local num_cmp = arith.num_cmp
local is_zero = arith.is_zero
local negative = arith.negative
local neg = arith.neg
local pow = arith.pow
local div = arith.div
local sub = arith.sub
local mul = arith.mul
local add = arith.add
local FANCY_TAGS = arith.FANCY_TAGS
local F = arith.F
local real_mul = arith.real_mul

---------------------------------------------------------------------------
-- Functions
---------------------------------------------------------------------------

local function flatten(args)
  local out = {}
  local function add_one(v)
    if tag(v) == "vec" then
      for _, x in ipairs(v) do
        add_one(x)
      end
    else
      out[#out + 1] = v
    end
  end
  for _, a in ipairs(args) do
    add_one(a)
  end
  return out
end

local function real_arg(v, name)
  if not is_real(v) then
    error("bad argument for " .. name)
  end
  return v
end

-- Functions of complex numbers, HMS forms, ... (`EXT_FN[name](args...)`,
-- nil to leave the call symbolic); filled below.
local EXT_FN = {}

-- the functions Calc applies to each element of a vector (the others stay
-- symbolic: `sqrt([4, 9])`)
local VEC_MAP = {
  floor = true,
  ceil = true,
  trunc = true,
  round = true,
  frac = true,
  rounde = true,
  roundu = true,
  float = true,
  re = true,
  im = true,
  conj = true,
  arg = true,
}

--- Apply a numeric function, leaving it symbolic for symbolic arguments.
local function numeric(name, fn)
  return function(args)
    for _, a in ipairs(args) do
      if FANCY_TAGS[tag(a)] then
        local r = EXT_FN[name] and EXT_FN[name](unpack(args))
        if r ~= nil then
          return r
        end
        return call(name, args)
      end
    end
    for _, a in ipairs(args) do
      if not is_real(a) then
        if tag(a) == "vec" and #args == 1 and VEC_MAP[name] then
          local out = { tag = "vec" }
          for i, x in ipairs(a) do
            out[i] = F[name]({ x })
          end
          return out
        end
        if tag(a) == "str" or tag(a) == "date" then
          error("bad argument for " .. name)
        end
        return call(name, args)
      end
    end
    local r = fn(unpack(args))
    if r == nil then
      return call(name, args)
    end
    return r
  end
end

local function to_angle(x)
  return modes.deg and x * math.pi / 180 or x
end

local function from_angle(x)
  return modes.deg and x * 180 / math.pi or x
end

local function float_fn(f)
  return function(x)
    local r = f(tofloat(x))
    if r ~= r then
      return nil
    end
    return float(r)
  end
end

F.abs = numeric("abs", function(x)
  return negative(x) and neg(x) or x
end)
F.sqrt = numeric("sqrt", function(x)
  local v = tofloat(x)
  if v < 0 then
    return nil
  end
  local function exact(n)
    local r = math.floor(math.sqrt(n) + 0.5)
    return r * r == n and r or nil
  end
  if type(x) == "number" and exact(x) then
    return exact(x)
  elseif tag(x) == "frac" and exact(x.n) and exact(x.d) then
    return make_frac(exact(x.n), exact(x.d))
  end
  return float(math.sqrt(v))
end)
F.exp = numeric("exp", function(x)
  if x == 0 then
    return 1
  end
  return float(math.exp(tofloat(x)))
end)
F.ln = numeric("ln", function(x)
  if tofloat(x) <= 0 then
    return nil
  end
  if x == 1 then
    return 0
  end
  return float(math.log(tofloat(x)))
end)
F.log = F.ln
F.log10 = numeric("log10", function(x)
  local v = tofloat(x)
  if v <= 0 then
    return nil
  end
  if type(x) == "number" then
    local p = 0
    local n = x
    while n >= 10 and n % 10 == 0 do
      n, p = n / 10, p + 1
    end
    if n == 1 then
      return p
    end
  end
  return float(math.log10(v))
end)
-- exp10(x) is 10.^x (a float, like Calc's calcFunc-exp10)
F.exp10 = function(args)
  local x = args[1]
  if #args ~= 1 or FANCY_TAGS[tag(x)] or tag(x) == "str" or tag(x) == "date" then
    return call("exp10", args)
  end
  return pow(float(10), x)
end
local function rounding(name, f)
  F[name] = numeric(name, function(x, n)
    if n ~= nil then
      local m = 10 ^ tofloat(n)
      return float(f(tofloat(x) * m) / m)
    end
    if is_int(x) then
      return x
    end
    local r = f(tofloat(x))
    if math.abs(r) >= MAX_EXACT then
      return big_norm(big_from_string(string.format("%.0f", r)))
    end
    return r
  end)
end
rounding("floor", math.floor)
rounding("ceil", math.ceil)
rounding("round", function(x)
  local v = math.floor(math.abs(x) + 0.5)
  return x < 0 and -v or v
end)
rounding("trunc", function(x)
  return x < 0 and math.ceil(x) or math.floor(x)
end)
F.idiv = numeric("idiv", function(a, b)
  if is_zero(b) then
    return nil
  end
  if type(a) == "number" and type(b) == "number" then
    return math.floor(a / b)
  end
  return F.floor({ div(a, b) })
end)
local function modulo(a, b)
  if is_zero(b) then
    return nil
  end
  if type(a) == "number" and type(b) == "number" then
    return a % b
  end
  return sub(a, mul(b, F.floor({ div(a, b) })))
end
F.mod = numeric("mod", modulo)
F.percent = numeric("percent", function(x)
  return div(x, 100)
end)
F.fact = numeric("fact", function(n)
  if not is_int(n) or negative(n) then
    return nil
  end
  local r = 1
  for i = 2, n do
    r = real_mul(r, i)
  end
  return r
end)
F.choose = numeric("choose", function(n, k)
  if not (is_int(n) and is_int(k)) then
    return nil
  end
  if k < 0 or k > n then
    return 0
  end
  local r = 1
  for i = 1, k do
    r = div(real_mul(r, n - k + i), i)
  end
  return r
end)
F.perm = numeric("perm", function(n, k)
  if not (is_int(n) and is_int(k)) then
    return nil
  end
  local r = 1
  for i = n - k + 1, n do
    r = real_mul(r, i)
  end
  return r
end)
F.gcd = numeric("gcd", function(a, b)
  if type(a) ~= "number" or type(b) ~= "number" or a ~= math.floor(a) or b ~= math.floor(b) then
    return nil
  end
  return gcd(a, b)
end)
F.lcm = numeric("lcm", function(a, b)
  if type(a) ~= "number" or type(b) ~= "number" then
    return nil
  end
  if a == 0 or b == 0 then
    return 0
  end
  return math.abs(a * b) / gcd(a, b)
end)
F.sign = numeric("sign", function(x)
  local v = tofloat(x)
  return v > 0 and 1 or (v < 0 and -1 or 0)
end)
-- frac(x): a float as the simplest fraction equal to it at the working
-- precision (calcFunc-frac, by continued fractions)
F.frac = numeric("frac", function(x)
  if tag(x) ~= "float" then
    return x
  end
  local v = x.v
  local target = round_sig(v, modes.prec)
  local h0, h1, k0, k1 = 0, 1, 1, 0
  local r = math.abs(v)
  for _ = 1, 64 do
    local a = math.floor(r)
    h0, h1 = h1, a * h1 + h0
    k0, k1 = k1, a * k1 + k0
    if round_sig((v < 0 and -h1 or h1) / k1, modes.prec) == target or r == a then
      break
    end
    r = 1 / (r - a)
  end
  if math.abs(h1) >= MAX_EXACT or k1 >= MAX_EXACT then
    return x
  end
  return make_frac(v < 0 and -h1 or h1, k1)
end)
-- exact results for exact arguments, like Calc: sin/cos of multiples of
-- 90 degrees, the inverse functions of -1, 0 and 1
local EXACT_TRIG = {
  sin = { [0] = 0, [90] = 1, [180] = 0, [270] = -1 },
  cos = { [0] = 1, [90] = 0, [180] = -1, [270] = 0 },
  tan = { [0] = 0, [180] = 0 },
  asin = { [-1] = -90, [0] = 0, [1] = 90 },
  acos = { [-1] = 180, [0] = 90, [1] = 0 },
  atan = { [-1] = -45, [0] = 0, [1] = 45 },
}
for _, f in ipairs({ "sin", "cos", "tan" }) do
  F[f] = numeric(f, function(x)
    if type(x) == "number" and (modes.deg or x == 0) then
      local r = EXACT_TRIG[f][x % 360]
      if r then
        return r
      end
    end
    return float(math[f](to_angle(tofloat(x))))
  end)
end
for _, f in ipairs({ "asin", "acos", "atan" }) do
  local name = "arc" .. f:sub(2)
  F[name] = numeric(name, function(x)
    if type(x) == "number" and modes.deg and EXACT_TRIG[f][x] then
      return EXACT_TRIG[f][x]
    end
    local r = math[f](tofloat(x))
    if r ~= r then
      return nil
    end
    return float(from_angle(r))
  end)
  F[f] = F[name]
end
F.arctan2 = numeric("arctan2", function(y, x)
  return float(from_angle(math.atan2(tofloat(y), tofloat(x))))
end)
for _, f in ipairs({ "sinh", "cosh", "tanh" }) do
  F[f] = numeric(f, float_fn(math[f]))
end
F.deg = numeric("deg", function(x)
  return float(tofloat(x) * 180 / math.pi)
end)
F.rad = numeric("rad", function(x)
  return float(tofloat(x) * math.pi / 180)
end)
F.pow = function(args)
  return pow(args[1], args[2])
end
F.hypot = numeric("hypot", function(a, b)
  return F.sqrt({ add(mul(a, a), mul(b, b)) })
end)

local function min_max(name, better)
  return function(args)
    local vals = flatten(args)
    if #vals == 0 then
      return float(better(1, -1) and -math.huge or math.huge)
    end
    local r = vals[1]
    for i = 2, #vals do
      local v = vals[i]
      if is_nan(r) or is_nan(v) then
        r = float(0 / 0)
      elseif is_real(r) and is_real(v) then
        if better(num_cmp(v, r), 0) then
          r = v
        end
      elseif tag(r) == "date" and tag(v) == "date" then
        if better(v.v, r.v) then
          r = v
        end
      elseif
        (tag(r) == "hms" or tag(v) == "hms")
        and (tag(r) == "hms" or is_real(r))
        and (tag(v) == "hms" or is_real(v))
      then
        -- HMS forms compare as hours
        local function hours(x)
          return tag(x) == "hms" and EXT_FN.deg(x) or x
        end
        if better(num_cmp(hours(v), hours(r)), 0) then
          r = v
        end
      else
        r = call(name, { r, v })
      end
    end
    return r
  end
end
F.max = min_max("max", function(a, b)
  return a > b
end)
F.min = min_max("min", function(a, b)
  return a < b
end)
F.vmax, F.vmin = F.max, F.min
-- max and min of a vector stay symbolic in Calc (vmax, vmin take vectors)
for _, name in ipairs({ "max", "min" }) do
  local f = F[name]
  F[name] = function(args)
    for _, a in ipairs(args) do
      if tag(a) == "vec" then
        return call(name, args)
      end
    end
    return f(args)
  end
end

F.vsum = function(args)
  local r = 0
  for _, v in ipairs(flatten(args)) do
    r = add(r, v)
  end
  return r
end
F.vprod = function(args)
  local r = 1
  for _, v in ipairs(flatten(args)) do
    r = mul(r, v)
  end
  return r
end
F.vcount = function(args)
  return #flatten(args)
end
F.vlen = function(args)
  local v = args[1]
  return tag(v) == "vec" and #v or 0
end
F.vmean = function(args)
  local vals = flatten(args)
  if #vals == 0 then
    return call("vmean", { { tag = "vec" } })
  end
  return div(F.vsum(vals), #vals)
end
F.vmedian = function(args)
  local vals = flatten(args)
  for _, v in ipairs(vals) do
    if not is_real(v) then
      return call("vmedian", args)
    end
  end
  if #vals == 0 then
    return call("vmedian", args)
  end
  table.sort(vals, function(a, b)
    return num_cmp(a, b) < 0
  end)
  local n = #vals
  if n % 2 == 1 then
    return vals[(n + 1) / 2]
  end
  return div(add(vals[n / 2], vals[n / 2 + 1]), 2)
end
local function variance(args, pop)
  local vals = flatten(args)
  local n = #vals
  for _, v in ipairs(vals) do
    if not is_real(v) then
      return nil
    end
  end
  if n < (pop and 1 or 2) then
    return 0
  end
  local mean = div(F.vsum(vals), n)
  local s = 0
  for _, v in ipairs(vals) do
    local d = sub(v, mean)
    s = add(s, mul(d, d))
  end
  return div(s, pop and n or n - 1)
end
F.vvar = function(args)
  return variance(args, false) or call("vvar", args)
end
F.vpvar = function(args)
  return variance(args, true) or call("vpvar", args)
end
F.vsdev = function(args)
  local v = variance(args, false)
  return v and F.sqrt({ v }) or call("vsdev", args)
end
F.vpsdev = function(args)
  local v = variance(args, true)
  return v and F.sqrt({ v }) or call("vpsdev", args)
end
-- covariance and correlation of two vectors of numbers
local function covariance(name, a, b, pop)
  if tag(a) ~= "vec" or tag(b) ~= "vec" or #a ~= #b or #a < 2 then
    return nil
  end
  for i = 1, #a do
    if not (is_real(a[i]) and is_real(b[i])) then
      return nil
    end
  end
  local ma, mb = div(F.vsum({ a }), #a), div(F.vsum({ b }), #b)
  local s = 0
  for i = 1, #a do
    s = add(s, mul(sub(a[i], ma), sub(b[i], mb)))
  end
  return div(s, pop and #a or #a - 1)
end
for name, pop in pairs({ vcov = false, vpcov = true }) do
  F[name] = function(args)
    return covariance(name, args[1], args[2], pop) or call(name, args)
  end
end
F.vcorr = function(args)
  local c = covariance("vcorr", args[1], args[2], false)
  if not c then
    return call("vcorr", args)
  end
  return float(tofloat(div(c, F.sqrt({ mul(variance({ args[1] }, false), variance({ args[2] }, false)) }))))
end
F.rev = function(args)
  local v = args[1]
  if tag(v) ~= "vec" then
    return call("rev", args)
  end
  local out = { tag = "vec" }
  for i = #v, 1, -1 do
    out[#out + 1] = v[i]
  end
  return out
end
F.sort = function(args)
  local v = args[1]
  if tag(v) ~= "vec" then
    return call("sort", args)
  end
  local out = { tag = "vec", unpack(v) }
  table.sort(out, function(a, b)
    return num_cmp(real_arg(a, "sort"), real_arg(b, "sort")) < 0
  end)
  return out
end
F.vsort = F.sort

-- Dates
F.date = function(args)
  local a = args[1]
  if #args >= 3 then
    return { tag = "date", v = days_from_civil(tofloat(args[1]), tofloat(args[2]), tofloat(args[3])) }
  elseif tag(a) == "date" then
    return a.v == math.floor(a.v) and a.v or float(a.v)
  elseif is_real(a) then
    return { tag = "date", v = tofloat(a) }
  end
  return call("date", args)
end
local function date_part(name, fn)
  F[name] = function(args)
    local a = args[1]
    if tag(a) ~= "date" then
      if is_real(a) then
        a = { tag = "date", v = tofloat(a) }
      else
        return call(name, args)
      end
    end
    return fn(a.v)
  end
end
date_part("year", function(v)
  return (civil_from_days(math.floor(v)))
end)
date_part("month", function(v)
  return select(2, civil_from_days(math.floor(v)))
end)
date_part("day", function(v)
  return select(3, civil_from_days(math.floor(v)))
end)
date_part("weekday", function(v)
  return math.floor(v) % 7
end)
-- math-date-parts: the time of day in whole seconds, rounded (a date with a
-- time is only accurate to the working precision, 22:00 is .916667)
local function day_seconds(v)
  return math.floor((v - math.floor(v)) * 86400 + 0.5)
end
date_part("hour", function(v)
  return math.floor(day_seconds(v) / 3600)
end)
date_part("minute", function(v)
  return math.floor(day_seconds(v) / 60) % 60
end)
date_part("second", function(v)
  return day_seconds(v) % 60
end)
F.now = function()
  local t = os.time()
  local d = os.date("*t", t)
  return { tag = "date", v = days_from_civil(d.year, d.month, d.day) + (d.hour * 60 + d.min) / 1440 + d.sec / 86400 }
end

return {
  flatten = flatten,
  EXT_FN = EXT_FN,
  numeric = numeric,
  from_angle = from_angle,
  float_fn = float_fn,
  modulo = modulo,
}
