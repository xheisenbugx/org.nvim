---@mod org.table.calc.values Calc: value types, modes and date forms

local big = require("org.table.calc.big")

local MAX_EXACT = big.MAX_EXACT
local big_tofloat = big.big_tofloat
local big_norm = big.big_norm

---------------------------------------------------------------------------
-- Values
---------------------------------------------------------------------------
-- integer: a Lua number with an integral value (|v| < 2^53), or a Big
-- float:   { tag = "float", v = number }
-- frac:    { tag = "frac", n = integer, d = integer } (d > 1)
-- vector:  { tag = "vec", ... }
-- date:    { tag = "date", v = days since 0000-12-31 (fraction = time) }
-- string:  { tag = "str", s = text }
-- symbolic: { tag = "sym", name } { tag = "call", name, args } { tag = "op", op, a, b } { tag = "neg", a }

local function tag(v)
  if type(v) == "number" then
    return "int"
  end
  return v.tag
end

local function is_int(v)
  return type(v) == "number" or (type(v) == "table" and v.tag == "big")
end

local function is_real(v)
  local t = tag(v)
  return t == "int" or t == "big" or t == "float" or t == "frac"
end

local function is_symbolic(v)
  local t = tag(v)
  return t == "sym" or t == "call" or t == "op" or t == "neg"
end

local modes = { prec = 12, frac = false, deg = true }

local function round_sig(x, p)
  if x ~= x or x == math.huge or x == -math.huge or x == 0 then
    return x
  end
  return tonumber(string.format("%." .. (p - 1) .. "e", x))
end

local function float(x)
  return { tag = "float", v = round_sig(x, modes.prec) }
end

--- Decimal digits and exponent of x (x = digits * 10^exp) with `p`
--- significant digits, trailing zeros removed.
local function decompose(x, p)
  local s = string.format("%." .. (p - 1) .. "e", x)
  local d1, rest, e = s:match("^(%d)%.?(%d*)e([-+]%d+)$")
  local digits = (d1 .. rest):gsub("0+$", "")
  if digits == "" then
    digits = "0"
  end
  return digits, tonumber(e) - (#digits - 1)
end

--- x + y as Calc adds floats (math-add-float): exactly in decimal, so the
--- sum is snapped to the last decimal place of the operands. Without this,
--- cancellation leaves binary noise in the low digits:
--- 739890 - 739889.300694 would be 0.699305999908, not 0.699306.
local function decimal_sum(x, y)
  local s = x + y
  if s ~= s or s == math.huge or s == -math.huge or x == 0 or y == 0 then
    return s
  end
  local _, ex = decompose(math.abs(x), modes.prec)
  local _, ey = decompose(math.abs(y), modes.prec)
  local scale = 10 ^ -math.min(ex, ey)
  local n = s * scale
  if scale > 0 and math.abs(n) < 2 ^ 52 then
    s = (n < 0 and -math.floor(-n + 0.5) or math.floor(n + 0.5)) / scale
  end
  return s
end

local function tofloat(v)
  local t = tag(v)
  if t == "int" then
    return v
  elseif t == "big" then
    return big_tofloat(v)
  elseif t == "float" then
    return v.v
  elseif t == "frac" then
    return v.n / v.d
  end
  error("not a number")
end

local function int_norm(n)
  if type(n) == "table" then
    return big_norm(n)
  end
  if math.abs(n) >= MAX_EXACT then
    error("integer overflow") -- the caller redoes the operation with bignums
  end
  return n
end

local function gcd(a, b)
  a, b = math.abs(a), math.abs(b)
  while b ~= 0 do
    a, b = b, a % b
  end
  return a
end

local function make_frac(n, d)
  if d == 0 then
    error("division by zero")
  end
  if d < 0 then
    n, d = -n, -d
  end
  local g = gcd(n, d)
  n, d = n / g, d / g
  if d == 1 then
    return n
  end
  return { tag = "frac", n = n, d = d }
end

local function as_frac(v)
  if type(v) == "number" then
    return v, 1
  end
  return v.n, v.d
end

---------------------------------------------------------------------------
-- Dates (Calc date forms: day 1 is 0001-01-01)
---------------------------------------------------------------------------

local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468 + 719163 -- 1970-01-01 is Calc day 719163
end

local function civil_from_days(n)
  local z = n - 719163 + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  return m <= 2 and y + 1 or y, m, d
end

local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local function date_string(v)
  local day = math.floor(v)
  local y, m, d = civil_from_days(day)
  local s = string.format("%04d-%02d-%02d %s", y, m, d, WEEKDAYS[day % 7 + 1])
  if v ~= day then
    local mins = math.floor((v - day) * 1440 + 0.5)
    s = s .. string.format(" %02d:%02d", math.floor(mins / 60), mins % 60)
  end
  return "<" .. s .. ">"
end

local function parse_date(s)
  local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then
    return nil
  end
  local v = days_from_civil(tonumber(y), tonumber(m), tonumber(d))
  local hh, mm = s:match("(%d%d?):(%d%d)", 11)
  if hh then
    -- math-dt-to-date: the time is added as a float fraction of a day,
    -- rounded to the working precision (22:00 of day 739890 is 739890.916667)
    local frac = round_sig((tonumber(hh) * 3600 + tonumber(mm) * 60) / 86400, modes.prec)
    v = round_sig(v + frac, modes.prec)
  end
  return { tag = "date", v = v }
end

return {
  tag = tag,
  is_int = is_int,
  is_real = is_real,
  is_symbolic = is_symbolic,
  modes = modes,
  round_sig = round_sig,
  float = float,
  decompose = decompose,
  decimal_sum = decimal_sum,
  tofloat = tofloat,
  gcd = gcd,
  make_frac = make_frac,
  as_frac = as_frac,
  days_from_civil = days_from_civil,
  civil_from_days = civil_from_days,
  date_string = date_string,
  parse_date = parse_date,
}
