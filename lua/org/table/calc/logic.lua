---@mod org.table.calc.logic Calc: logic, comparisons and concatenation

local values = require("org.table.calc.values")
local arith = require("org.table.calc.arith")
local forms = require("org.table.calc.forms")

local tag = values.tag
local is_real = values.is_real
local op = arith.op
local call = arith.call
local num_cmp = arith.num_cmp
local is_zero = arith.is_zero
local F = arith.F
local same = arith.same
local is_objvec = arith.is_objvec
local hms_value = forms.hms_value

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
  elseif not (is_objvec(a) or tag(a) == "str") or not (is_objvec(b) or tag(b) == "str") then
    return op("|", a, b)
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

return {
  truth = truth,
  compare = compare,
  concat = concat,
}
