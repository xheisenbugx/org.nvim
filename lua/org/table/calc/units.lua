---@mod org.table.calc.units Calc: units (usimplify)

local values = require("org.table.calc.values")
local parser = require("org.table.calc.parser")
local arith = require("org.table.calc.arith")
local evaluate = require("org.table.calc.evaluate")

local tag = values.tag
local is_real = values.is_real
local is_symbolic = values.is_symbolic
local parse = parser.parse
local sym = arith.sym
local op = arith.op
local mul = arith.mul
local pow = arith.pow
local neg = arith.neg
local div = arith.div
local add = arith.add
local F = arith.F
local eval = evaluate.eval

---------------------------------------------------------------------------
-- Units (usimplify)
---------------------------------------------------------------------------
-- A table of common units: the value in base units (m, g, s, A) as Calc's
-- math-to-standard-units writes it (so exact and float conversions match
-- Calc), and the dimensions. Outside usimplify units are plain symbols, as
-- in Calc (`3 m + 20 cm` stays).

do
  local INCH = "254*10^-2*10^-2"
  local POUND = "16*28349523125*10^-9"
  local GALLON_PT = "2*8*2*3*492892159375*10^-11*10^-3*10^-3"
  local GFORCE = "980665*10^-5"
  local function dims(l, m, t, i, k, n)
    return { L = l, M = m, T = t, I = i, K = k, N = n }
  end
  local LEN, MASS, TIME = dims(1), dims(nil, 1), dims(nil, nil, 1)
  local VOL, AREA, SPEED = dims(3), dims(2), dims(1, nil, -1)
  local FORCE, ENERGY, POWER = dims(1, 1, -2), dims(2, 1, -2), dims(2, 1, -3)
  local TEMP = dims(nil, nil, nil, nil, 1)
  local UNITS = {
    m = { "1", LEN },
    ["in"] = { INCH, LEN },
    ft = { "12*" .. INCH, LEN },
    yd = { "3*12*" .. INCH, LEN },
    mi = { "5280*12*" .. INCH, LEN },
    fath = { "6*12*" .. INCH, LEN },
    nmi = { "1852", LEN },
    au = { "149597870700", LEN },
    Ang = { "10^-10", LEN },
    g = { "1", MASS },
    lb = { POUND, MASS },
    oz = { "28349523125*10^-9", MASS },
    t = { "1000*10^3", MASS },
    ton = { "2000*" .. POUND, MASS },
    s = { "1", TIME },
    sec = { "1", TIME },
    min = { "60", TIME },
    hr = { "60*60", TIME },
    day = { "24*60*60", TIME },
    wk = { "7*24*60*60", TIME },
    yr = { "36525*10^-2*24*60*60", TIME },
    Hz = { "1", dims(nil, nil, -1) },
    l = { "10^-3", VOL },
    L = { "10^-3", VOL },
    gal = { "4*2*" .. GALLON_PT, VOL },
    qt = { "2*" .. GALLON_PT, VOL },
    pt = { GALLON_PT, VOL },
    cup = { "8*2*3*492892159375*10^-11*10^-3*10^-3", VOL },
    ozfl = { "2*3*492892159375*10^-11*10^-3*10^-3", VOL },
    tbsp = { "3*492892159375*10^-11*10^-3*10^-3", VOL },
    tsp = { "492892159375*10^-11*10^-3*10^-3", VOL },
    a = { "100", AREA },
    ha = { "10^2*100", AREA },
    acre = { "(1/640)*(5280*12*" .. INCH .. ")^2", AREA },
    mph = { "5280*12*" .. INCH .. "/(60*60)", SPEED },
    kph = { "10^3/(60*60)", SPEED },
    knot = { "1852/(60*60)", SPEED },
    c = { "299792458", SPEED },
    N = { "10^3", FORCE },
    dyn = { "10^-5*10^3", FORCE },
    lbf = { GFORCE .. "*" .. POUND, FORCE },
    J = { "10^3", ENERGY },
    erg = { "10^-7*10^3", ENERGY },
    cal = { "41868*10^-4*10^3", ENERGY },
    Wh = { "10^3*60*60", ENERGY },
    eV = { "1.60217663e-19*10^3", ENERGY },
    W = { "10^3", POWER },
    hp = { "550*(12*" .. INCH .. ")*" .. GFORCE .. "*" .. POUND, POWER },
    Pa = { "10^3", dims(-1, 1, -2) },
    bar = { "10^5*10^3", dims(-1, 1, -2) },
    atm = { "101325*10^3", dims(-1, 1, -2) },
    psi = { GFORCE .. "*" .. POUND .. "/(" .. INCH .. ")^2", dims(-1, 1, -2) },
    mmHg = { "10^-3*1000*(1/760)*101325*10^3", dims(-1, 1, -2) },
    A = { "1", dims(nil, nil, nil, 1) },
    C = { "1", dims(nil, nil, 1, 1) },
    V = { "10^3", dims(2, 1, -3, -1) },
    ohm = { "10^3", dims(2, 1, -3, -2) },
    -- temperature differences (usimplify converts intervals, as Calc)
    K = { "1", TEMP },
    degC = { "1", TEMP },
    dC = { "1", TEMP },
    degF = { "5/9", TEMP },
    dF = { "5/9", TEMP },
    fur = { "660*12*" .. INCH, LEN },
    mil = { "(1/1000)*" .. INCH, LEN },
    point = { "(1/72)*" .. INCH, LEN },
    lyr = { "299792458*36525*10^-2*24*60*60", LEN },
    b = { "10^-28", AREA },
    galUK = { "454609*10^-5*10^-3", VOL },
    ga = { GFORCE, dims(1, nil, -2) },
    ct = { "(2/10)", MASS },
    tonUK = { "10160469088*10^-7*10^3", MASS },
    gf = { GFORCE, FORCE },
    kip = { "1000*" .. GFORCE .. "*" .. POUND, FORCE },
    calth = { "4184*10^-3*10^3", ENERGY },
    Cal = { "1000*41868*10^-4*10^3", ENERGY },
    Btu = { "105505585262*10^-8*10^3", ENERGY },
    therm = { "105506000*10^3", ENERGY },
    Ws = { "10^3", ENERGY },
    Torr = { "(1/760)*101325*10^3", dims(-1, 1, -2) },
    inHg = { "254*10^-1*10^-3*1000*(1/760)*101325*10^3", dims(-1, 1, -2) },
    P = { "(1/10)*10^3", dims(-1, 1, -1) },
    St = { "10^-4", dims(2, nil, -1) },
    S = { "10^-3", dims(-2, -1, 3, 2) },
    mho = { "10^-3", dims(-2, -1, 3, 2) },
    F = { "10^-3", dims(-2, -1, 4, 2) },
    Wb = { "10^3", dims(2, 1, -2, -1) },
    T = { "10^3", dims(nil, 1, -2, -1) },
    Gs = { "10^-4*10^3", dims(nil, 1, -2, -1) },
    H = { "10^3", dims(2, 1, -2, -2) },
    Bq = { "1", dims(nil, nil, -1) },
    Ci = { "37*10^9", dims(nil, nil, -1) },
    Gy = { "1", dims(2, nil, -2) },
    Sv = { "1", dims(2, nil, -2) },
    rd = { "(1/100)", dims(2, nil, -2) },
    rem = { "(1/100)", dims(2, nil, -2) },
    mol = { "1", dims(nil, nil, nil, nil, nil, 1) },
  }
  local PREFIXES = {
    Q = 30,
    R = 27,
    Y = 24,
    Z = 21,
    E = 18,
    P = 15,
    T = 12,
    G = 9,
    M = 6,
    k = 3,
    K = 3,
    h = 2,
    H = 2,
    D = 1,
    d = -1,
    c = -2,
    m = -3,
    u = -6,
    n = -9,
    p = -12,
    f = -15,
    a = -18,
    z = -21,
    y = -24,
    r = -27,
    q = -30,
  }

  local unit_cache = {}

  --- The { factor, dims, base, prefix } of a unit name (with an SI prefix:
  --- `base` is the name without it, `prefix` its power of ten), or nil.
  local function unit_info(name)
    if unit_cache[name] ~= nil then
      return unit_cache[name] or nil
    end
    local base, prefix = name, 0
    local def = UNITS[name]
    if not def then
      local p, rest = PREFIXES[name:sub(1, 1)], name:sub(2)
      if name:sub(1, 2) == "μ" then
        p, rest = -6, name:sub(3)
      end
      def = p and UNITS[rest]
      if def then
        base, prefix = rest, p
      end
    end
    local info = false
    if def then
      local factor = eval(parse(def[1]))
      if prefix ~= 0 then
        factor = mul(pow(10, prefix), factor)
      end
      info = { factor = factor, dims = def[2], base = base, prefix = prefix }
    end
    unit_cache[name] = info
    return info or nil
  end

  local function same_dims(a, b)
    for _, k in ipairs({ "L", "M", "T", "I", "K", "N" }) do
      if (a[k] or 0) ~= (b[k] or 0) then
        return false
      end
    end
    return true
  end

  --- `v` as a coefficient times a product of units ({ coef, units = { { name,
  --- power }, ... } }), or nil.
  local function monomial(v)
    local t = tag(v)
    if t == "sym" and unit_info(v.name) then
      return { coef = 1, units = { { v.name, 1 } } }
    elseif is_real(v) or t == "sym" or t == "call" then
      return { coef = v, units = {} }
    elseif t == "neg" then
      local r = monomial(v.a)
      if r then
        r.coef = neg(r.coef)
      end
      return r
    elseif t == "op" and v.op == "^" and tag(v.a) == "sym" and type(v.b) == "number" then
      if unit_info(v.a.name) then
        return { coef = 1, units = { { v.a.name, v.b } } }
      end
      return { coef = v, units = {} }
    elseif t == "op" and (v.op == "*" or v.op == "/") then
      local a, b = monomial(v.a), monomial(v.b)
      if not a or not b then
        return nil
      end
      local sign = v.op == "*" and 1 or -1
      local r = { coef = sign == 1 and mul(a.coef, b.coef) or div(a.coef, b.coef), units = {} }
      for _, u in ipairs(a.units) do
        r.units[#r.units + 1] = { u[1], u[2] }
      end
      for _, u in ipairs(b.units) do
        r.units[#r.units + 1] = { u[1], u[2] * sign }
      end
      return r
    end
    return nil
  end

  --- Merge equal units and cancel a unit against another of the same
  --- dimension with the opposite power (`in / cm` is 2.54).
  local function simplify_monomial(mono)
    local units = {}
    for _, u in ipairs(mono.units) do
      local found = false
      for _, x in ipairs(units) do
        if x[1] == u[1] then
          x[2], found = x[2] + u[2], true
          break
        end
      end
      if not found then
        units[#units + 1] = { u[1], u[2] }
      end
    end
    local coef = mono.coef
    -- the same unit with different prefixes: into the last one (km m is
    -- 1000 m^2), by exact powers of ten when they are positive, like Calc
    for i, x in ipairs(units) do
      local ux = unit_info(x[1])
      for j = i + 1, #units do
        local y = units[j]
        local uy = unit_info(y[1])
        if x[2] ~= 0 and y[2] ~= 0 and ux.base == uy.base then
          coef = mul(coef, pow(10, (ux.prefix - uy.prefix) * x[2]))
          y[2], x[2] = y[2] + x[2], 0
          break
        end
      end
    end
    -- other units of the same dimension with opposite powers (in / cm)
    for i, x in ipairs(units) do
      for j = i + 1, #units do
        local y = units[j]
        if x[2] ~= 0 and x[2] == -y[2] then
          local ux, uy = unit_info(x[1]), unit_info(y[1])
          if same_dims(ux.dims, uy.dims) then
            local ratio = x[2] > 0 and div(ux.factor, uy.factor) or div(uy.factor, ux.factor)
            coef = mul(coef, pow(ratio, math.abs(x[2])))
            x[2], y[2] = 0, 0
          end
        end
      end
    end
    local out = {}
    for _, x in ipairs(units) do
      if x[2] ~= 0 then
        out[#out + 1] = x
      end
    end
    return { coef = coef, units = out }
  end

  local function units_factor(units)
    local f = 1
    for _, u in ipairs(units) do
      f = mul(f, pow(unit_info(u[1]).factor, u[2]))
    end
    return f
  end

  local function units_dims(units)
    local d = {}
    for _, u in ipairs(units) do
      for k, n in pairs(unit_info(u[1]).dims) do
        d[k] = (d[k] or 0) + n * u[2]
      end
    end
    return d
  end

  --- A monomial as a Calc expression: `1.5 m^2 / s`.
  local function build(mono)
    local nums, dens = {}, {}
    if not (mono.coef == 1 and #mono.units > 0) then
      nums[1] = mono.coef
    end
    -- the units in Calc's canonical order (by name)
    local units = { unpack(mono.units) }
    table.sort(units, function(x, y)
      return x[1] < y[1]
    end)
    for _, u in ipairs(units) do
      local p = math.abs(u[2])
      local f = p == 1 and sym(u[1]) or op("^", sym(u[1]), p)
      table.insert(u[2] > 0 and nums or dens, f)
    end
    if #nums > 1 and is_symbolic(nums[1]) and tag(nums[1]) ~= "sym" then
      -- a formula coefficient goes after the units: m*(x + 2)
      table.insert(nums, table.remove(nums, 1))
    end
    -- products nest to the right, as Calc builds them
    local function product(list)
      local r = list[#list]
      for i = #list - 1, 1, -1 do
        r = op("*", list[i], r)
      end
      return r
    end
    local num, den = product(nums), product(dens)
    if den then
      return op("/", num or 1, den)
    end
    return num
  end

  local function usimplify(v)
    if tag(v) == "vec" then
      local out = { tag = "vec" }
      for i, x in ipairs(v) do
        out[i] = usimplify(x)
      end
      return out
    end
    -- the terms of a sum
    local terms = {}
    local function collect(x, sign)
      if tag(x) == "op" and (x.op == "+" or x.op == "-") then
        collect(x.a, sign)
        collect(x.b, x.op == "-" and -sign or sign)
      else
        terms[#terms + 1] = { x, sign }
      end
    end
    collect(v, 1)
    local monos = {}
    for i, t in ipairs(terms) do
      local m = monomial(t[1])
      if not m then
        return v
      end
      m = simplify_monomial(m)
      if t[2] < 0 then
        m.coef = neg(m.coef)
      end
      monos[i] = m
    end
    local first = monos[1]
    if #monos == 1 then
      return build(first)
    end
    -- a sum: every term in the units of the first one, like Calc
    local fdims, ffactor = units_dims(first.units), units_factor(first.units)
    local coef = first.coef
    for i = 2, #monos do
      local m = monos[i]
      if not same_dims(fdims, units_dims(m.units)) then
        local r = build(first)
        for j = 2, #monos do
          r = add(r, build(monos[j]))
        end
        return r
      end
      coef = add(coef, div(mul(m.coef, units_factor(m.units)), ffactor))
    end
    return build({ coef = coef, units = first.units })
  end
  F.usimplify = function(args)
    return usimplify(args[1])
  end
end
