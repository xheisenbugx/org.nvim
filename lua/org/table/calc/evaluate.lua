---@mod org.table.calc.evaluate Calc: the evaluator

local values = require("org.table.calc.values")
local arith = require("org.table.calc.arith")
local forms = require("org.table.calc.forms")
local logic = require("org.table.calc.logic")

local tag = values.tag
local is_real = values.is_real
local float = values.float
local sym = arith.sym
local op = arith.op
local call = arith.call
local neg = arith.neg
local add = arith.add
local sub = arith.sub
local mul = arith.mul
local div = arith.div
local pow = arith.pow
local F = arith.F
local cplx = forms.cplx
local polar = forms.polar
local hms = forms.hms
local intv = forms.intv
local truth = logic.truth
local compare = logic.compare
local concat = logic.concat

---------------------------------------------------------------------------
-- Evaluation
---------------------------------------------------------------------------

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
    local arith = ({ ["+"] = add, ["-"] = sub, ["*"] = mul, ["/"] = div, ["^"] = pow, ["**"] = pow })[o]
    if arith and (tag(a) == "vec" or tag(b) == "vec") then
      -- vectors of the wrong sizes: Calc leaves the operation alone
      local ok, r = pcall(arith, a, b)
      if ok then
        return r
      elseif tostring(r):find("dimension error") then
        return op(o == "**" and "^" or o, a, b)
      end
      error(r, 0)
    end
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
    elseif o == "mod" then
      return F.makemod({ a, b })
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

return {
  eval = eval,
}
