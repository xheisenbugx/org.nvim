---@mod org.table.calc.parser Calc: the tokenizer and the formula parser

local big = require("org.table.calc.big")
local values = require("org.table.calc.values")

local MAX_EXACT = big.MAX_EXACT
local big_from_string = big.big_from_string
local big_norm = big.big_norm
local tag = values.tag
local float = values.float
local make_frac = values.make_frac
local parse_date = values.parse_date

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

--- Run `f` inside parentheses (`vector` false) or brackets (true): in the
--- brackets of a vector, a space separates elements (`[1 2]`, `[1 -2]`).
function Parser:nested(vector, f, ...)
  self.ctx[#self.ctx + 1] = vector
  local r = f(self, ...)
  self.ctx[#self.ctx] = nil
  return r
end

function Parser:in_vector()
  return self.ctx[#self.ctx] == true
end

--- Whether the brackets being read contain a comma at their own level.
function Parser:has_comma()
  local depth = 0
  for i = self.i, #self.toks do
    local t = self.toks[i]
    if t.kind == "op" then
      if t.value == "(" or t.value == "[" then
        depth = depth + 1
      elseif t.value == ")" or t.value == "]" then
        if depth == 0 then
          return false
        end
        depth = depth - 1
      elseif t.value == "," and depth == 0 then
        return true
      end
    end
  end
  return false
end

local function is_sign(t)
  return t.kind == "op" and (t.value == "-" or t.value == "+")
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
    if nxt.kind == "op" and nxt.value == "(" and not (nxt.space and self:in_vector()) then
      -- a function call, also with a space: `f (x)`
      self:next()
      return { k = "call", name = t.value, args = self:nested(false, self.args, ")") }
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
      return self:nested(false, self.paren)
    elseif t.value == "[" then
      -- without commas, spaces separate the elements (math-read-brackets)
      return self:nested(not self:has_comma(), self.bracket)
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

--- The rest of a parenthesized formula, complex number or interval.
function Parser:paren()
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
end

--- The rest of a vector or interval after `[`.
function Parser:bracket()
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
    local c = self:peek()
    if c.kind == "op" and c.value == "]" then
      self:next()
      return { k = "vec", items = items }
    elseif c.kind == "op" and c.value == "," then
      self:next()
    elseif not (self:in_vector() and c.space and (starts_factor(c) or is_sign(c))) then
      error("syntax error: expected , or ]")
    end
    items[#items + 1] = self:level(0)
  end
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
    if
      t.space
      and self:in_vector()
      and not (t.kind == "id" and t.value == "mod")
      and (starts_factor(t) or (is_sign(t) and not self.toks[self.i + 1].space))
    then
      break -- the next element of a vector
    elseif t.kind == "id" and t.value == "mod" then
      -- the modulo form operator: `3 mod 7`
      op, lp, rp = "mod", 400, 400
    elseif t.kind == "op" then
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
local function parse(s)
  local p = setmetatable({ toks = tokenize(s), i = 1, ctx = {} }, Parser)
  local e = p:level(0)
  if p:peek().kind ~= "eof" then
    error("syntax error near " .. tostring(p:peek().value))
  end
  return e
end

return {
  parse = parse,
}
