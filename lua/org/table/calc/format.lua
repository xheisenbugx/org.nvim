---@mod org.table.calc.format Calc: the display of values

local big = require("org.table.calc.big")
local values = require("org.table.calc.values")
local arith = require("org.table.calc.arith")
local forms = require("org.table.calc.forms")

local big_tostring = big.big_tostring
local tag = values.tag
local is_int = values.is_int
local is_real = values.is_real
local decompose = values.decompose
local date_string = values.date_string
local negative = arith.negative
local known_num_integer = arith.known_num_integer
local ext_op = forms.ext_op

---------------------------------------------------------------------------
-- Display
---------------------------------------------------------------------------

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

-- display precedences: { left, right, text } of each operator (Calc's
-- math-standard-opers); a fourth field is the precedence that decides the
-- parentheses when it is not the smaller of the two
local DISPLAY = {
  ["mod"] = { 400, 400, " mod ", 185 },
  ["+/-"] = { 300, 300, " +/- ", 185 },
  ["^"] = { 201, 200, "^" },
  ["*"] = { 196, 195, " " },
  ["/"] = { 190, 191, " / " },
  ["%"] = { 190, 191, " % " },
  ["\\"] = { 190, 191, " \\ " },
  ["+"] = { 180, 181, " + " },
  ["-"] = { 180, 181, " - " },
  ["|"] = { 170, 171, " | " },
  ["<"] = { 160, 161, " < " },
  [">"] = { 160, 161, " > " },
  ["<="] = { 160, 161, " <= " },
  [">="] = { 160, 161, " >= " },
  ["=="] = { 160, 161, " = " },
  ["!="] = { 160, 161, " != " },
  ["&&"] = { 110, 111, " && " },
  ["||"] = { 100, 101, " || " },
}
-- functions Calc writes as operators
local CALL_OPS = {
  idiv = "\\",
  mod = "%",
  vconcat = "|",
  eq = "==",
  neq = "!=",
  lt = "<",
  gt = ">",
  leq = "<=",
  geq = ">=",
  land = "&&",
  lor = "||",
}
local POSTFIX = { fact = { "!", 210 }, dfact = { "!!", 210 }, percent = { "%", 1100 } }

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

--- The last factor of a product (math-prod-last-term).
local function last_factor(v)
  while tag(v) == "op" and v.op == "*" do
    v = v.b
  end
  return v
end

--- A binary operator (math-compose-expr): `div` is set for the right side
--- of `/`, where a product needs parentheses.
local function display_binary(o, a, b, fmt, prec, ctx, div_rhs)
  local d = DISPLAY[o]
  if ctx > (d[4] or math.min(d[1], d[2])) or (div_rhs and o == "*") then
    return "(" .. display_binary(o, a, b, fmt, prec, 0) .. ")"
  end
  local lhs = display(a, fmt, prec, d[1])
  local rhs = display(b, fmt, prec, d[2], o == "/")
  if o == "^" then
    if lhs:sub(1, 1) == "-" then
      lhs = "(" .. lhs .. ")"
    end
    return lhs .. "^" .. rhs
  elseif o == "*" then
    -- juxtaposition, unless it would read as a function call: `x*(y + 1)`
    local nextc = rhs:sub(1, 1)
    if nextc:match("[%w._#%(%[{]") and not (tag(last_factor(a)) == "sym" and nextc == "(") then
      return lhs .. " " .. rhs
    end
    return lhs .. "*" .. rhs
  elseif o == "/" and known_num_integer(a) and is_int(b) then
    return lhs .. "/" .. rhs
  end
  return lhs .. d[3] .. rhs
end

display = function(v, fmt, prec, ctx, div_rhs)
  ctx = ctx or 0
  local t = tag(v)
  if is_real(v) then
    return display_real(v, fmt, prec)
  elseif t == "vec" then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = display(x, fmt, prec, 0)
    end
    if #v == 1 and tag(v[1]) == "op" and v[1].op == "*" then
      -- `[(x y)]`: without parentheses it would read as `[x, y]`
      return "[(" .. parts[1] .. ")]"
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
    return display_binary("+/-", v.x, v.s, fmt, prec, ctx)
  elseif t == "mod" then
    return display_binary("mod", v.n, v.m, fmt, prec, ctx)
  elseif t == "intv" then
    return (math.floor(v.mask / 2) == 1 and "[" or "(")
      .. display(v.lo, fmt, prec, 0)
      .. " .. "
      .. display(v.hi, fmt, prec, 0)
      .. (v.mask % 2 == 1 and "]" or ")")
  elseif t == "sym" then
    return v.name
  elseif t == "call" then
    local n = #v.args
    if CALL_OPS[v.name] and n == 2 then
      return display_binary(CALL_OPS[v.name], v.args[1], v.args[2], fmt, prec, ctx, div_rhs)
    elseif POSTFIX[v.name] and n == 1 then
      local o, p = POSTFIX[v.name][1], POSTFIX[v.name][2]
      local s = display(v.args[1], fmt, prec, p) .. (#o > 1 and " " or "") .. o
      return ctx > p and "(" .. s .. ")" or s
    elseif v.name == "lnot" and n == 1 then
      local s = "!" .. display(v.args[1], fmt, prec, 1000)
      return ctx > 1000 and "(" .. s .. ")" or s
    elseif v.name == "if" and n == 3 then
      local s = display(v.args[1], fmt, prec, 91)
        .. " ? "
        .. display(v.args[2], fmt, prec, 0)
        .. " : "
        .. display(v.args[3], fmt, prec, 90)
      return ctx > 90 and "(" .. s .. ")" or s
    end
    local parts = {}
    for i, x in ipairs(v.args) do
      parts[i] = display(x, fmt, prec, 0)
    end
    return v.name .. "(" .. table.concat(parts, ", ") .. ")"
  elseif t == "neg" then
    local s = "-" .. display(v.a, fmt, prec, 197)
    return ctx > 197 and "(" .. s .. ")" or s
  elseif t == "op" then
    return display_binary(v.op, v.a, v.b, fmt, prec, ctx, div_rhs)
  end
  return tostring(v)
end

return {
  format_float = format_float,
  display = display,
}
