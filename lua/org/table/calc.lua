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
---   `2 x`, `sqrt(x)` stays `sqrt(x)`, `pi` stays `pi`. Only a few algebraic
---   simplifications are done (collecting `x + x`, `x x`); Calc's rewrite
---   engine is not implemented.
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
      if num and num:sub(-1) == "." and s:sub(i + #num, i + #num) == "." then
        num = num:sub(1, -2) -- `1..3`: an interval, not the float `1.`
      end
    end
    -- HMS forms: 2@ 30' 15.5", also 30' 15" and 15"
    local mark = num and s:match("^%s*([@'\"])", i + #num)
    if mark then
      local parts = { "0", "0", "0" }
      local first = mark == "@" and 1 or (mark == "'" and 2 or 3)
      for k = first, 3 do
        local unit_mark = ({ "@", "'", '"' })[k]
        local field = s:match("^%s*%d+%.?%d*%s*" .. unit_mark, i)
        if field then
          parts[k] = field:match("%d+%.?%d*")
          i = i + #field
        end
      end
      push("hms", parts, space)
    elseif num then
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
        or s:match("^%+/%-", i)
        or s:match("^%.%.", i)
        or s:match("^<=", i)
        or s:match("^>=", i)
        or s:match("^==", i)
        or s:match("^!=", i)
        or s:match("^&&", i)
        or s:match("^||", i)
        or s:match("^[-+*/\\%%^()%[%],;<>=!|?:]", i)
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
  ["+/-"] = { 300, 300 },
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
    or t.kind == "hms"
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
  elseif t.kind == "hms" then
    local p = {}
    for i, x in ipairs(t.value) do
      p[i] = x:find("%.") and float(tonumber(x)) or tonumber(x)
    end
    return { k = "hms", h = p[1], m = p[2], s = p[3] }
  elseif t.kind == "op" then
    if t.value == "(" then
      local e = self:level(0)
      local c = self:next()
      if c.kind == "op" and c.value == "," then
        -- a complex number (re, im)
        local im = self:level(0)
        self:expect(")")
        return { k = "cplx", re = e, im = im }
      elseif c.kind == "op" and c.value == ";" then
        -- a polar complex number (r; theta)
        local theta = self:level(0)
        self:expect(")")
        return { k = "polar", r = e, t = theta }
      elseif c.kind == "op" and c.value == ".." then
        return self:interval(e, false)
      elseif not (c.kind == "op" and c.value == ")") then
        error("syntax error: expected )")
      end
      return e
    elseif t.value == "[" then
      local nxt = self:peek()
      if nxt.kind == "op" and nxt.value == "]" then
        self:next()
        return { k = "vec", items = {} }
      end
      local first = self:level(0)
      nxt = self:peek()
      if nxt.kind == "op" and nxt.value == ".." then
        self:next()
        return self:interval(first, true)
      end
      local items = { first }
      while true do
        local c = self:next()
        if c.kind == "op" and c.value == "]" then
          return { k = "vec", items = items }
        elseif not (c.kind == "op" and c.value == ",") then
          error("syntax error: expected , or ]")
        end
        items[#items + 1] = self:level(0)
      end
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

--- The rest of an interval `[lo .. hi]` after `..`; `closed_lo` tells the
--- opening bracket.
function Parser:interval(lo, closed_lo)
  local hi = self:level(0)
  local c = self:next()
  if not (c.kind == "op" and (c.value == "]" or c.value == ")")) then
    error("syntax error: expected ] or )")
  end
  return { k = "intv", mask = (closed_lo and 2 or 0) + (c.value == "]" and 1 or 0), lo = lo, hi = hi }
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
local FANCY_TAGS = { cplx = true, polar = true, hms = true, sdev = true, intv = true }
-- arithmetic on complex numbers, HMS forms, error forms and intervals
-- (defined with the functions below); nil when neither operand is one
local ext_op

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
  elseif FANCY_TAGS[t] then
    return ext_op("neg", a)
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
  end
  local x = ext_op("+", a, b)
  if x ~= nil then
    return x
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
  end
  local x = ext_op("-", a, b)
  if x ~= nil then
    return x
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
  end
  local x = ext_op("*", a, b)
  if x ~= nil then
    return x
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
  end
  local x = ext_op("/", a, b)
  if x ~= nil then
    return x
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

-- Functions of complex numbers, HMS forms, ... (`EXT_FN[name](args...)`,
-- nil to leave the call symbolic); filled below.
local EXT_FN = {}

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

---------------------------------------------------------------------------
-- Complex numbers, HMS forms, error forms and intervals
---------------------------------------------------------------------------
-- complex: { tag = "cplx", re = real, im = real } (im ~= 0)
-- polar:   { tag = "polar", r = real, t = real } (t in the angle mode)
-- hms:     { tag = "hms", h = int, m = int, s = real } (all <= 0 if negative)
-- sdev:    { tag = "sdev", x = real, s = real } (error form x +/- s)
-- intv:    { tag = "intv", mask = 0..3, lo = real, hi = real } (mask: 2 =
--          low end closed, 1 = high end closed, like Calc)

local eval -- the evaluator (below)

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

ext_op = function(o, a, b)
  local ta = tag(a)
  if o == "neg" then
    if ta == "cplx" then
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
  if ta == "hms" or tb == "hms" then
    return hms_binary(o, a, b)
  elseif ta == "sdev" or tb == "sdev" then
    return sdev_binary(o, a, b)
  elseif ta == "intv" or tb == "intv" then
    return intv_binary(o, a, b)
  end
  return c_binary(o, a, b)
end

-- Complex functions: the real ones that give complex results too
local real_sqrt, real_ln, real_log10 = F.sqrt, F.ln, F.log10
F.sqrt = function(args)
  local x = args[1]
  if #args == 1 and is_real(x) and negative(x) then
    return imaginary(real_sqrt({ neg(x) }))
  end
  return real_sqrt(args)
end
F.ln = function(args)
  local x = args[1]
  if #args == 1 and is_real(x) and negative(x) then
    return cplx(float(math.log(-tofloat(x))), float(math.pi))
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

---------------------------------------------------------------------------
-- Units (usimplify)
---------------------------------------------------------------------------
-- A table of common units: the value in base units (m, g, s, A) as Calc's
-- math-to-standard-units writes it (so exact and float conversions match
-- Calc), and the dimensions. Outside usimplify units are plain symbols, as
-- in Calc (`3 m + 20 cm` stays).

local INCH = "254*10^-2*10^-2"
local POUND = "16*28349523125*10^-9"
local GALLON_PT = "2*8*2*3*492892159375*10^-11*10^-3*10^-3"
local GFORCE = "980665*10^-5"
local function dims(l, m, t, i)
  return { L = l, M = m, T = t, I = i }
end
local LEN, MASS, TIME = dims(1), dims(nil, 1), dims(nil, nil, 1)
local VOL, AREA, SPEED = dims(3), dims(2), dims(1, nil, -1)
local FORCE, ENERGY, POWER = dims(1, 1, -2), dims(2, 1, -2), dims(2, 1, -3)
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
}
local PREFIXES = {
  Q = 30, R = 27, Y = 24, Z = 21, E = 18, P = 15, T = 12, G = 9, M = 6, k = 3, K = 3, h = 2, H = 2, D = 1,
  d = -1, c = -2, m = -3, u = -6, n = -9, p = -12, f = -15, a = -18, z = -21, y = -24, r = -27, q = -30,
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
    local factor = eval(M.parse(def[1]))
    if prefix ~= 0 then
      factor = mul(pow(10, prefix), factor)
    end
    info = { factor = factor, dims = def[2], base = base, prefix = prefix }
  end
  unit_cache[name] = info
  return info or nil
end

local function same_dims(a, b)
  for _, k in ipairs({ "L", "M", "T", "I" }) do
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
  local num, den
  if not (mono.coef == 1 and #mono.units > 0) then
    num = mono.coef
  end
  for _, u in ipairs(mono.units) do
    local p = math.abs(u[2])
    local f = p == 1 and sym(u[1]) or op("^", sym(u[1]), p)
    if u[2] > 0 then
      num = num and op("*", num, f) or f
    else
      den = den and op("*", den, f) or f
    end
  end
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

-- Logic
local function truth(v)
  if is_real(v) then
    return not is_zero(v)
  end
  return nil
end
F["if"] = function(args)
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
  elseif
    (tag(a) == "hms" or tag(b) == "hms")
    and (tag(a) == "hms" or is_real(a))
    and (tag(b) == "hms" or is_real(b))
  then
    return compare(o, tag(a) == "hms" and hms_value(a) or a, tag(b) == "hms" and hms_value(b) or b)
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

eval = function(node)
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
  elseif k == "cplx" or k == "polar" then
    local a, b = eval(node.re or node.r), eval(node.im or node.t)
    if not (is_real(a) and is_real(b)) then
      error("bad complex number")
    end
    return k == "cplx" and cplx(a, b) or polar(a, b)
  elseif k == "hms" then
    return hms(node.h, node.m, node.s)
  elseif k == "intv" then
    local lo, hi = eval(node.lo), eval(node.hi)
    if not (is_real(lo) and is_real(hi)) then
      error("bad interval")
    end
    return intv(node.mask, lo, hi)
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
    elseif o == "+/-" then
      return F.sdev({ a, b })
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
  ["+/-"] = { 300, 300, " +/- " },
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
  elseif t == "cplx" then
    return "(" .. display(v.re, fmt, prec, 0) .. ", " .. display(v.im, fmt, prec, 0) .. ")"
  elseif t == "polar" then
    return "(" .. display(v.r, fmt, prec, 0) .. "; " .. display(v.t, fmt, prec, 0) .. ")"
  elseif t == "hms" then
    if negative(v.h) or negative(v.m) or negative(v.s) then
      return "-" .. display(ext_op("neg", v), fmt, prec, 0)
    end
    local s = string.format("%s@ %s' %s\"", display(v.h, fmt, prec), display(v.m, fmt, prec), display(v.s, fmt, prec))
    return ctx > 197 and "(" .. s .. ")" or s
  elseif t == "sdev" then
    local s = display(v.x, fmt, prec, 0) .. " +/- " .. display(v.s, fmt, prec, 0)
    return ctx > 300 and "(" .. s .. ")" or s
  elseif t == "intv" then
    return (math.floor(v.mask / 2) == 1 and "[" or "(")
      .. display(v.lo, fmt, prec, 0)
      .. " .. "
      .. display(v.hi, fmt, prec, 0)
      .. (v.mask % 2 == 1 and "]" or ")")
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

return M
