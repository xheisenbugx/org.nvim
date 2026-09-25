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
--- - Symbols and unknown functions stay symbolic, like Calc: `x*2` is
---   `2 x`, `sqrt(x)` stays `sqrt(x)`, `pi` stays `pi`. Only a few algebraic
---   simplifications are done (collecting `x + x`, `x x`); Calc's rewrite
---   engine, units, complex numbers and HMS forms are not implemented.
--- - Quoted strings (`"big"`) are an extension: Calc turns them into
---   vectors of character codes, this module keeps them as text.

local M = {}

---------------------------------------------------------------------------
-- Big integers (base 1e7 limbs, little endian)
---------------------------------------------------------------------------

local BASE, BASE_DIGITS = 10000000, 7
local MAX_EXACT = 2 ^ 53

local Big = {}
Big.__index = Big

local function big_from_int(n)
  local b = setmetatable({ tag = "big", sign = n < 0 and -1 or 1, d = {} }, Big)
  n = math.abs(n)
  repeat
    b.d[#b.d + 1] = n % BASE
    n = math.floor(n / BASE)
  until n == 0
  return b
end

local function big_from_string(s)
  local b = setmetatable({ tag = "big", sign = 1, d = {} }, Big)
  if s:sub(1, 1) == "-" then
    b.sign, s = -1, s:sub(2)
  end
  s = s:gsub("^0+", "")
  local i = #s
  while i > 0 do
    local j = math.max(1, i - BASE_DIGITS + 1)
    b.d[#b.d + 1] = tonumber(s:sub(j, i))
    i = j - 1
  end
  if #b.d == 0 then
    b.d[1], b.sign = 0, 1
  end
  return b
end

local function big_trim(b)
  while #b.d > 1 and b.d[#b.d] == 0 do
    b.d[#b.d] = nil
  end
  if #b.d == 1 and b.d[1] == 0 then
    b.sign = 1
  end
  return b
end

local function big_cmp_abs(a, b)
  if #a.d ~= #b.d then
    return #a.d < #b.d and -1 or 1
  end
  for i = #a.d, 1, -1 do
    if a.d[i] ~= b.d[i] then
      return a.d[i] < b.d[i] and -1 or 1
    end
  end
  return 0
end

local function big_add_abs(a, b)
  local r, carry = {}, 0
  for i = 1, math.max(#a.d, #b.d) do
    local s = (a.d[i] or 0) + (b.d[i] or 0) + carry
    r[i], carry = s % BASE, math.floor(s / BASE)
  end
  if carry > 0 then
    r[#r + 1] = carry
  end
  return r
end

local function big_sub_abs(a, b) -- |a| >= |b|
  local r, borrow = {}, 0
  for i = 1, #a.d do
    local s = a.d[i] - (b.d[i] or 0) - borrow
    if s < 0 then
      s, borrow = s + BASE, 1
    else
      borrow = 0
    end
    r[i] = s
  end
  return r
end

local function big_add(a, b)
  if a.sign == b.sign then
    return big_trim(setmetatable({ tag = "big", sign = a.sign, d = big_add_abs(a, b) }, Big))
  end
  local c = big_cmp_abs(a, b)
  if c == 0 then
    return big_from_int(0)
  elseif c > 0 then
    return big_trim(setmetatable({ tag = "big", sign = a.sign, d = big_sub_abs(a, b) }, Big))
  end
  return big_trim(setmetatable({ tag = "big", sign = b.sign, d = big_sub_abs(b, a) }, Big))
end

local function big_mul(a, b)
  local r = {}
  for i = 1, #a.d + #b.d do
    r[i] = 0
  end
  for i = 1, #a.d do
    local carry = 0
    for j = 1, #b.d do
      local cur = r[i + j - 1] + a.d[i] * b.d[j] + carry
      r[i + j - 1], carry = cur % BASE, math.floor(cur / BASE)
    end
    local k = i + #b.d
    while carry > 0 do
      local cur = r[k] + carry
      r[k], carry = cur % BASE, math.floor(cur / BASE)
      k = k + 1
    end
  end
  return big_trim(setmetatable({ tag = "big", sign = a.sign * b.sign, d = r }, Big))
end

local function big_tostring(b)
  local parts = { tostring(b.d[#b.d]) }
  for i = #b.d - 1, 1, -1 do
    parts[#parts + 1] = string.format("%07d", b.d[i])
  end
  return (b.sign < 0 and "-" or "") .. table.concat(parts)
end

local function big_tofloat(b)
  local v = 0
  for i = #b.d, 1, -1 do
    v = v * BASE + b.d[i]
  end
  return v * b.sign
end

--- A big integer back to a Lua number when it is small enough.
local function big_norm(b)
  if #b.d <= 3 then
    local v = big_tofloat(b)
    if math.abs(v) < MAX_EXACT then
      return v
    end
  end
  return b
end

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
    v = v + (tonumber(hh) * 60 + tonumber(mm)) / 1440
  end
  return { tag = "date", v = v }
end

---------------------------------------------------------------------------
-- Tokenizer
---------------------------------------------------------------------------

local function tokenize(s)
  local toks, i, n = {}, 1, #s
  local function push(kind, value, space)
    toks[#toks + 1] = { kind = kind, value = value, space = space }
  end
  while i <= n do
    local space = false
    local ws = s:match("^%s+", i)
    if ws then
      i = i + #ws
      space = true
      if i > n then
        break
      end
    end
    local ch = s:sub(i, i)
    local num = s:match("^%d*%.?%d+[eE][-+]?%d+", i) or s:match("^%d+%.?%d*[eE][-+]?%d+", i)
    if not num then
      num = s:match("^%d+%.%d*", i) or s:match("^%.%d+", i) or s:match("^%d+", i)
    end
    if num then
      i = i + #num
      if not num:find("[.eE]") then
        -- fractions 1:2 and mixed fractions 1:2:3
        local a, b = s:match("^:(%d+):(%d+)", i)
        if not a then
          a = s:match("^:(%d+)", i)
        end
        if b then
          i = i + 2 + #a + #b
          push("frac", { tonumber(num), tonumber(a), tonumber(b) }, space)
        elseif a then
          i = i + 1 + #a
          push("frac", { 0, tonumber(num), tonumber(a) }, space)
        else
          push("int", num, space)
        end
      else
        if s:sub(i, i) == ":" then
          error("syntax error: bad fraction")
        end
        push("float", num, space)
      end
    elseif ch:match("[%a]") then
      local id = s:match("^[%a][%w_']*", i)
      i = i + #id
      push("id", id, space)
    elseif ch == '"' then
      local j, buf = i + 1, {}
      while j <= n and s:sub(j, j) ~= '"' do
        if s:sub(j, j) == "\\" then
          j = j + 1
        end
        buf[#buf + 1] = s:sub(j, j)
        j = j + 1
      end
      if j > n then
        error("syntax error: unterminated string")
      end
      push("str", table.concat(buf), space)
      i = j + 1
    elseif ch == "<" and s:match("^<%d%d%d%d%-%d%d%-%d%d[^>]*>", i) then
      local ts = s:match("^<(%d%d%d%d%-%d%d%-%d%d[^>]*)>", i)
      i = i + #ts + 2
      push("date", ts, space)
    else
      local op = s:match("^%*%*", i)
        or s:match("^<=", i)
        or s:match("^>=", i)
        or s:match("^==", i)
        or s:match("^!=", i)
        or s:match("^&&", i)
        or s:match("^||", i)
        or s:match("^[-+*/\\%%^()%[%],<>=!|?:]", i)
      if not op then
        error("syntax error near: " .. s:sub(i, i + 5))
      end
      i = i + #op
      push("op", op, space)
    end
  end
  push("eof", nil, false)
  return toks
end

---------------------------------------------------------------------------
-- Parser (Calc's math-read-expr-level with the standard operator table)
---------------------------------------------------------------------------

-- binary operators: { left precedence, right precedence }
local BINARY = {
  ["^"] = { 201, 200 },
  ["**"] = { 201, 200 },
  ["*"] = { 196, 195 },
  ["/"] = { 190, 191 },
  ["%"] = { 190, 191 },
  ["\\"] = { 190, 191 },
  ["+"] = { 180, 181 },
  ["-"] = { 180, 181 },
  ["|"] = { 170, 171 },
  ["<"] = { 160, 161 },
  [">"] = { 160, 161 },
  ["<="] = { 160, 161 },
  [">="] = { 160, 161 },
  ["="] = { 160, 161 },
  ["=="] = { 160, 161 },
  ["!="] = { 160, 161 },
  ["&&"] = { 110, 111 },
  ["||"] = { 100, 101 },
  ["?"] = { 91, 90 },
}
local IMPLICIT = { 196, 195 }

local Parser = {}
Parser.__index = Parser

function Parser:peek()
  return self.toks[self.i]
end

function Parser:next()
  local t = self.toks[self.i]
  self.i = self.i + 1
  return t
end

function Parser:expect(op)
  local t = self:next()
  if t.kind ~= "op" or t.value ~= op then
    error("syntax error: expected " .. op)
  end
end

local function starts_factor(t)
  return t.kind == "int"
    or t.kind == "float"
    or t.kind == "frac"
    or t.kind == "id"
    or t.kind == "str"
    or t.kind == "date"
    or (t.kind == "op" and (t.value == "(" or t.value == "["))
end

function Parser:args(close)
  local out = {}
  local t = self:peek()
  if t.kind == "op" and t.value == close then
    self:next()
    return out
  end
  while true do
    out[#out + 1] = self:level(0)
    t = self:next()
    if t.kind == "op" and t.value == close then
      return out
    elseif not (t.kind == "op" and t.value == ",") then
      error("syntax error: expected , or " .. close)
    end
  end
end

function Parser:factor()
  local t = self:next()
  if t.kind == "int" then
    local v = tonumber(t.value)
    if v >= MAX_EXACT then
      return { k = "val", v = big_norm(big_from_string(t.value)) }
    end
    return { k = "val", v = v }
  elseif t.kind == "float" then
    return { k = "val", v = float(tonumber(t.value)) }
  elseif t.kind == "frac" then
    local w, a, b = t.value[1], t.value[2], t.value[3]
    return { k = "val", v = make_frac(w * b + a, b) }
  elseif t.kind == "str" then
    return { k = "val", v = { tag = "str", s = t.value } }
  elseif t.kind == "date" then
    local d = parse_date(t.value)
    if not d then
      error("bad date form")
    end
    return { k = "val", v = d }
  elseif t.kind == "id" then
    local nxt = self:peek()
    if nxt.kind == "op" and nxt.value == "(" and not nxt.space then
      self:next()
      return { k = "call", name = t.value, args = self:args(")") }
    end
    return { k = "sym", name = t.value }
  elseif t.kind == "op" then
    if t.value == "(" then
      local e = self:level(0)
      local c = self:next()
      if c.kind == "op" and c.value == "," then
        -- a complex number (re, im): only real ones are supported
        local im = self:level(0)
        self:expect(")")
        if not (im.k == "val" and im.v == 0) then
          error("complex numbers are not supported")
        end
        return e
      elseif not (c.kind == "op" and c.value == ")") then
        error("syntax error: expected )")
      end
      return e
    elseif t.value == "[" then
      return { k = "vec", items = self:args("]") }
    elseif t.value == "-" then
      return { k = "neg", a = self:level(197) }
    elseif t.value == "+" then
      return self:level(197)
    elseif t.value == "!" then
      return { k = "call", name = "lnot", args = { self:level(1000) } }
    end
  end
  error("syntax error near " .. tostring(t.value or "end of formula"))
end

function Parser:level(prec)
  local x = self:factor()
  while true do
    local t = self:peek()
    local op, lp, rp
    if t.kind == "op" then
      op = t.value
      if op == "!" then
        -- postfix factorial
        lp = 210
      elseif op == "%" and not starts_factor(self.toks[self.i + 1]) then
        -- postfix percent
        lp = 1100
        op = "pct"
      elseif BINARY[op] then
        lp, rp = BINARY[op][1], BINARY[op][2]
      elseif op == "(" or op == "[" then
        op, lp, rp = "*", IMPLICIT[1], IMPLICIT[2]
        if lp >= prec then
          x = { k = "bin", op = "*", a = x, b = self:level(rp) }
          goto continue
        end
      end
    elseif starts_factor(t) then
      op, lp, rp = "*", IMPLICIT[1], IMPLICIT[2]
      if lp >= prec then
        x = { k = "bin", op = "*", a = x, b = self:level(rp) }
        goto continue
      end
      break
    end
    if not lp or lp < prec then
      break
    end
    self:next()
    if op == "!" then
      x = { k = "call", name = "fact", args = { x } }
    elseif op == "pct" then
      x = { k = "call", name = "percent", args = { x } }
    elseif op == "?" then
      local a = self:level(0)
      self:expect(":")
      local b = self:level(rp)
      x = { k = "call", name = "if", args = { x, a, b } }
    else
      x = { k = "bin", op = op, a = x, b = self:level(rp) }
    end
    ::continue::
  end
  return x
end

--- Parse a Calc algebraic formula into a syntax tree.
function M.parse(s)
  local p = setmetatable({ toks = tokenize(s), i = 1 }, Parser)
  local e = p:level(0)
  if p:peek().kind ~= "eof" then
    error("syntax error near " .. tostring(p:peek().value))
  end
  return e
end

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

--- Numeric coefficient and rest of a symbolic product (`2 x` → 2, x).
local function split_coef(v)
  if tag(v) == "op" and v.op == "*" and is_real(v.a) then
    return v.a, v.b
  elseif tag(v) == "neg" then
    local c, r = split_coef(v.a)
    return neg(c), r
  end
  return 1, v
end

local function same(a, b)
  return vim.deep_equal(a, b)
end

local function elementwise(f, a, b)
  local out = { tag = "vec" }
  local ta, tb = tag(a), tag(b)
  if ta == "vec" and tb == "vec" then
    if #a ~= #b then
      error("dimension error")
    end
    for i = 1, #a do
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
  elseif t == "neg" then
    return a.a
  elseif t == "op" and a.op == "*" and is_real(a.a) then
    return mul(neg(a.a), a.b)
  end
  if t == "sym" or t == "call" or t == "op" then
    return { tag = "neg", a = a }
  end
  error("bad argument for negation")
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
    return float(tofloat(a) + tofloat(b))
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

add = function(a, b)
  local ta, tb = tag(a), tag(b)
  if is_nan(a) or is_nan(b) then
    return float(0 / 0)
  end
  if ta == "vec" or tb == "vec" then
    return elementwise(add, a, b)
  elseif is_real(a) and is_real(b) then
    return real_add(a, b)
  elseif ta == "date" and is_real(b) then
    return { tag = "date", v = a.v + tofloat(b) }
  elseif tb == "date" and is_real(a) then
    return { tag = "date", v = b.v + tofloat(a) }
  elseif ta == "str" or tb == "str" or ta == "date" or tb == "date" then
    error("bad argument for +")
  end
  -- symbolic
  if is_zero(a) then
    return b
  elseif is_zero(b) then
    return a
  end
  if negative(b) then
    return op("-", a, neg(b))
  end
  local ca, ra = split_coef(a)
  local cb, rb = split_coef(b)
  if not is_real(ra) and same(ra, rb) then
    return mul(add(ca, cb), ra)
  end
  return op("+", a, b)
end

sub = function(a, b)
  local ta, tb = tag(a), tag(b)
  if is_nan(a) or is_nan(b) then
    return float(0 / 0)
  end
  if ta == "vec" or tb == "vec" then
    return elementwise(sub, a, b)
  elseif is_real(a) and is_real(b) then
    return real_add(a, neg(b))
  elseif ta == "date" and tb == "date" then
    local d = a.v - b.v
    return d == math.floor(d) and d or float(d)
  elseif ta == "date" and is_real(b) then
    return { tag = "date", v = a.v - tofloat(b) }
  elseif ta == "str" or tb == "str" or ta == "date" or tb == "date" then
    error("bad argument for -")
  end
  if is_zero(b) then
    return a
  elseif is_zero(a) then
    return neg(b)
  end
  if negative(b) then
    return add(a, neg(b))
  end
  local ca, ra = split_coef(a)
  local cb, rb = split_coef(b)
  if not is_real(ra) and same(ra, rb) then
    return mul(sub(ca, cb), ra)
  end
  return op("-", a, b)
end

mul = function(a, b)
  local ta, tb = tag(a), tag(b)
  if is_nan(a) or is_nan(b) then
    return float(0 / 0)
  end
  if ta == "vec" and tb == "vec" then
    -- Calc multiplies two vectors as a dot product
    if #a ~= #b then
      error("dimension error")
    end
    local s = 0
    for i = 1, #a do
      s = add(s, mul(a[i], b[i]))
    end
    return s
  elseif ta == "vec" or tb == "vec" then
    return elementwise(mul, a, b)
  elseif is_real(a) and is_real(b) then
    return real_mul(a, b)
  elseif ta == "str" or tb == "str" or ta == "date" or tb == "date" then
    error("bad argument for *")
  end
  if is_real(b) and not is_real(a) then
    a, b = b, a
  end
  if is_real(a) then
    if is_zero(a) and tag(a) == "int" then
      return 0
    elseif is_one(a) or (tag(a) == "float" and a.v == 1) then
      return b
    elseif a == -1 then
      return neg(b)
    end
    local cb, rb = split_coef(b)
    if cb ~= 1 then
      return mul(real_mul(a, cb), rb)
    end
    return op("*", a, b)
  end
  if same(a, b) then
    return pow(a, 2)
  end
  return op("*", a, b)
end

div = function(a, b)
  local ta, tb = tag(a), tag(b)
  if is_nan(a) or is_nan(b) then
    return float(0 / 0)
  end
  if ta == "vec" and not (tb == "vec") then
    return elementwise(div, a, b)
  elseif is_real(a) and is_real(b) then
    local r = real_div(a, b)
    if r == nil then
      return op("/", a, b) -- Calc leaves division by zero alone
    end
    return r
  elseif ta == "str" or tb == "str" or ta == "date" or tb == "date" or ta == "vec" or tb == "vec" then
    error("bad argument for /")
  end
  if is_one(b) then
    return a
  end
  return op("/", a, b)
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

pow = function(a, b)
  local ta, tb = tag(a), tag(b)
  if is_nan(a) or is_nan(b) then
    return float(0 / 0)
  end
  if ta == "vec" and is_real(b) then
    return elementwise(pow, a, b)
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
      return op("^", a, b)
    end
    return float(x ^ y)
  end
  if ta == "str" or tb == "str" or ta == "date" or tb == "date" then
    error("bad argument for ^")
  end
  if is_one(b) then
    return a
  elseif tb == "int" and b == 0 then
    return 1
  end
  return op("^", a, b)
end

---------------------------------------------------------------------------
-- Functions
---------------------------------------------------------------------------

local F = {}

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

--- Apply a numeric function, leaving it symbolic for symbolic arguments.
local function numeric(name, fn)
  return function(args)
    for _, a in ipairs(args) do
      if not is_real(a) then
        if tag(a) == "vec" and #args == 1 then
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
F.exp10 = numeric("exp10", function(x)
  return pow(10, x)
end)
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
F.frac = numeric("frac", function(x)
  if is_int(x) then
    return 0
  end
  return sub(x, F.trunc({ x }))
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
date_part("hour", function(v)
  return math.floor((v - math.floor(v)) * 24 + 1e-9)
end)
date_part("minute", function(v)
  return math.floor((v - math.floor(v)) * 1440 + 1e-9) % 60
end)
date_part("second", function(v)
  return math.floor((v - math.floor(v)) * 86400 + 0.5) % 60
end)
F.now = function()
  local t = os.time()
  local d = os.date("*t", t)
  return { tag = "date", v = days_from_civil(d.year, d.month, d.day) + (d.hour * 60 + d.min) / 1440 + d.sec / 86400 }
end

-- Logic
local function truth(v)
  if is_real(v) then
    return not is_zero(v)
  end
  return nil
end
F["if"] = function(args, lazy)
  local c = truth(args[1])
  if c == nil then
    if tag(args[1]) == "vec" then
      error("bad condition")
    end
    return call("if", args)
  end
  return c and args[2] or args[3]
end
F.lnot = function(args)
  local c = truth(args[1])
  if c == nil then
    return call("lnot", args)
  end
  return c and 0 or 1
end

local function compare(o, a, b)
  if is_real(a) and is_real(b) then
    local c = num_cmp(a, b)
    local r = (o == "<" and c < 0)
      or (o == ">" and c > 0)
      or (o == "<=" and c <= 0)
      or (o == ">=" and c >= 0)
      or ((o == "==" or o == "=") and c == 0)
      or (o == "!=" and c ~= 0)
    return r and 1 or 0
  elseif tag(a) == "date" and tag(b) == "date" then
    return compare(o, a.v, b.v)
  elseif tag(a) == "str" and tag(b) == "str" then
    local r = (o == "==" or o == "=") and a.s == b.s or (o == "!=" and a.s ~= b.s)
    return r and 1 or 0
  end
  if (o == "==" or o == "=") and same(a, b) then
    return 1
  end
  return op(o == "=" and "==" or o, a, b)
end

local function concat(a, b)
  if tag(a) == "str" and tag(b) == "str" then
    return { tag = "str", s = a.s .. b.s }
  end
  local out = { tag = "vec" }
  for _, v in ipairs({ a, b }) do
    if tag(v) == "vec" then
      for _, x in ipairs(v) do
        out[#out + 1] = x
      end
    else
      out[#out + 1] = v
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Evaluation
---------------------------------------------------------------------------

local CONSTANTS = { pi = true, e = true, gamma = true, phi = true, i = true }

local function eval(node)
  local k = node.k
  if k == "val" then
    return node.v
  elseif k == "sym" then
    if node.name == "nan" then
      return float(0 / 0)
    elseif node.name == "inf" then
      return float(math.huge)
    end
    return sym(node.name)
  elseif k == "neg" then
    return neg(eval(node.a))
  elseif k == "vec" then
    local out = { tag = "vec" }
    for i, x in ipairs(node.items) do
      out[i] = eval(x)
    end
    return out
  elseif k == "call" then
    local args = {}
    if node.name == "if" and #node.args == 3 then
      local c = truth(eval(node.args[1]))
      if c ~= nil then
        return eval(node.args[c and 2 or 3])
      end
    end
    for i, x in ipairs(node.args) do
      args[i] = eval(x)
    end
    local f = F[node.name]
    if not f then
      return call(node.name, args)
    end
    return f(args)
  elseif k == "bin" then
    local a, b = eval(node.a), eval(node.b)
    local o = node.op
    if o == "+" then
      return add(a, b)
    elseif o == "-" then
      return sub(a, b)
    elseif o == "*" then
      return mul(a, b)
    elseif o == "/" then
      return div(a, b)
    elseif o == "^" or o == "**" then
      return pow(a, b)
    elseif o == "%" then
      return F.mod({ a, b })
    elseif o == "\\" then
      return F.idiv({ a, b })
    elseif o == "|" then
      return concat(a, b)
    elseif o == "&&" then
      local ta, tb = truth(a), truth(b)
      if ta == nil or tb == nil then
        return op("&&", a, b)
      end
      return (ta and tb) and 1 or 0
    elseif o == "||" then
      local ta, tb = truth(a), truth(b)
      if ta == nil or tb == nil then
        return op("||", a, b)
      end
      return (ta or tb) and 1 or 0
    end
    return compare(o, a, b)
  end
  error("bad expression")
end

---------------------------------------------------------------------------
-- Display
---------------------------------------------------------------------------

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

--- Round a digit string to `n` digits (n may be <= 0), half away from zero.
--- Returns the new digit string and how many digits were dropped.
local function round_digits(digits, n)
  local drop = #digits - n
  if drop <= 0 then
    return digits, 0
  end
  if n <= 0 then
    -- everything is dropped: the result is 0 or 1 (at the next position)
    local first = n == 0 and tonumber(digits:sub(1, 1)) or 0
    return first >= 5 and "1" or "0", drop
  end
  local keep = digits:sub(1, n)
  if tonumber(digits:sub(n + 1, n + 1)) >= 5 then
    local t, i, carry = {}, #keep, 1
    for j = 1, #keep do
      t[j] = keep:byte(j) - 48
    end
    while carry == 1 and i >= 1 do
      t[i] = t[i] + 1
      if t[i] == 10 then
        t[i] = 0
      else
        carry = 0
      end
      i = i - 1
    end
    for j = 1, #t do
      t[j] = string.char(t[j] + 48)
    end
    keep = (carry == 1 and "1" or "") .. table.concat(t)
  end
  return keep, drop
end

--- Calc's math-format-number for a float, with calc-float-format `fmt`
--- (`{ "float"|"fix"|"sci"|"eng", figs }`) and internal precision `prec`.
local function format_float(x, fmt, prec)
  if x ~= x then
    return "nan"
  elseif x == math.huge then
    return "inf"
  elseif x == -math.huge then
    return "-inf"
  end
  if x < 0 then
    return "-" .. format_float(-x, fmt, prec)
  end
  local kind, figs = fmt[1], fmt[2]
  local mant, exp
  if x == 0 then
    mant, exp = "0", 0
  else
    mant, exp = decompose(x, prec)
  end
  if kind == "fix" and (figs < 0 or exp + #mant > -figs) then
    figs = math.abs(figs)
    local str
    local scale = exp + figs
    if scale >= 0 then
      str = mant .. string.rep("0", scale)
    else
      str = round_digits(mant, #mant + scale)
    end
    str = str:gsub("^0+(%d)", "%1")
    if #str <= figs then
      str = string.rep("0", 1 + figs - #str) .. str
    end
    if figs > 0 then
      return str:sub(1, #str - figs) .. "." .. str:sub(#str - figs + 1)
    end
    return str .. "."
  end
  if figs < 0 then
    figs = prec + figs
  end
  if figs > 0 and #mant > figs then
    local drop
    mant, drop = round_digits(mant, figs)
    exp = exp + drop
  end
  local str = mant
  local len = #str
  local dpos = exp + len
  if kind == "float" and dpos <= prec and dpos >= -1 then
    if dpos == 0 then
      return "0." .. str
    elseif exp <= 0 and dpos > 0 then
      return str:sub(1, dpos) .. "." .. str:sub(dpos + 1)
    elseif exp > 0 then
      return str .. string.rep("0", exp) .. "."
    end
    return "0." .. string.rep("0", -dpos) .. str
  end
  local eadj = exp + len
  local scale = kind == "eng" and (1 + (eadj + 300002) % 3) or 1
  if scale > #str then
    str = str .. string.rep("0", scale - #str)
  end
  if scale < #str then
    str = str:sub(1, scale) .. "." .. str:sub(scale + 1)
  end
  return str .. "e" .. (eadj - scale)
end

-- display precedences: { left, right } of each operator
local DISPLAY = {
  ["^"] = { 201, 200, "^" },
  ["*"] = { 196, 195, " " },
  ["/"] = { 190, 191, " / " },
  ["%"] = { 190, 191, " % " },
  ["+"] = { 180, 181, " + " },
  ["-"] = { 180, 181, " - " },
  ["<"] = { 160, 161, " < " },
  [">"] = { 160, 161, " > " },
  ["<="] = { 160, 161, " <= " },
  [">="] = { 160, 161, " >= " },
  ["=="] = { 160, 161, " = " },
  ["!="] = { 160, 161, " != " },
  ["&&"] = { 110, 111, " && " },
  ["||"] = { 100, 101, " || " },
}

local display

local function display_real(v, fmt, prec)
  local t = tag(v)
  if t == "int" then
    return string.format("%d", v)
  elseif t == "big" then
    return big_tostring(v)
  elseif t == "float" then
    return format_float(v.v, fmt, prec)
  elseif t == "frac" then
    return string.format("%d:%d", v.n, v.d)
  end
end

display = function(v, fmt, prec, ctx)
  ctx = ctx or 0
  local t = tag(v)
  if is_real(v) then
    local s = display_real(v, fmt, prec)
    if ctx > 180 and s:sub(1, 1) == "-" then
      return "(" .. s .. ")"
    end
    return s
  elseif t == "vec" then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = display(x, fmt, prec, 0)
    end
    return "[" .. table.concat(parts, ", ") .. "]"
  elseif t == "str" then
    return v.s
  elseif t == "date" then
    return date_string(v.v)
  elseif t == "sym" then
    return v.name
  elseif t == "call" then
    local parts = {}
    for i, x in ipairs(v.args) do
      parts[i] = display(x, fmt, prec, 0)
    end
    return v.name .. "(" .. table.concat(parts, ", ") .. ")"
  elseif t == "neg" then
    local s = "-" .. display(v.a, fmt, prec, 197)
    return ctx > 197 and "(" .. s .. ")" or s
  elseif t == "op" then
    local d = DISPLAY[v.op]
    local sep = d[3]
    if v.op == "/" and is_real(v.a) and is_real(v.b) then
      sep = "/"
    end
    local s = display(v.a, fmt, prec, d[1]) .. sep .. display(v.b, fmt, prec, d[2])
    if d[1] < ctx then
      return "(" .. s .. ")"
    end
    return s
  end
  return tostring(v)
end

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
  local saved = modes
  modes = { prec = opts.prec or 12, frac = opts.frac or false, deg = opts.deg ~= false }
  local ok, res = pcall(function()
    local v = eval(M.parse(s))
    if opts.num and not is_real(v) then
      error("result is not a number")
    end
    return display(v, opts.float_format or { "float", 8 }, modes.prec)
  end)
  modes = saved
  if not ok then
    error(res, 0)
  end
  return res
end

M._format_float = format_float
M._days_from_civil = days_from_civil
M._civil_from_days = civil_from_days
M.CONSTANTS = CONSTANTS

return M
