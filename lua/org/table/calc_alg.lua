---@mod org.table.calc_alg Symbolic algebra for the table Calc
---
--- Ports of Calc's algebra functions (calc-alg.el, calc-poly.el,
--- calcalg2.el) for formulas with variables: simplify (math-simplify and
--- its rules for + - * / ^ sqrt exp trigonometric functions and
--- equations), expand, collect, subst, deriv, integ (common integrals, not
--- Calc's rule-based integrator) and solve (linear and quadratic
--- polynomials, inverse functions; one solution, as Calc without the "all
--- solutions" flag).

---@param K table the internals of org.table.calc
return function(K)
  local F, tag, is_real, is_int = K.F, K.tag, K.is_real, K.is_int
  local add, sub, mul, div, pow, neg = K.add, K.sub, K.mul, K.div, K.pow, K.neg
  local op, sym, call, same = K.op, K.sym, K.call, K.same
  local is_zero, negative, looks_neg = K.is_zero, K.negative, K.looks_neg
  local is_object, is_number = K.is_object, K.is_number

  local function isop(v, a, b)
    return tag(v) == "op" and (v.op == a or (b ~= nil and v.op == b))
  end

  local function is_call(v, name)
    return tag(v) == "call" and v.name == name and #v.args == 1
  end

  --- Math-primp: a number, object or variable (no sub-formulas).
  local function primitive(v)
    local t = tag(v)
    return not (t == "op" or t == "neg" or t == "call" or t == "vec")
  end

  local function is_rat(v)
    return is_int(v) or tag(v) == "frac"
  end

  local COMPARE = { ["=="] = true, ["!="] = true, ["<"] = true, [">"] = true, ["<="] = true, [">="] = true }
  local BINARY = { ["+"] = add, ["-"] = sub, ["*"] = mul, ["/"] = div, ["^"] = pow, ["|"] = K.concat }

  local HELD = { deriv = true, integ = true, solve = true, simplify = true, expand = true, collect = true }

  --- math-normalize: evaluate a formula again, bottom up.
  local function normalize(v)
    local t = tag(v)
    if t == "op" then
      local a, b = normalize(v.a), normalize(v.b)
      if BINARY[v.op] then
        return BINARY[v.op](a, b)
      elseif COMPARE[v.op] then
        return K.compare(v.op, a, b)
      elseif v.op == "%" then
        return F.mod({ a, b })
      end
      return op(v.op, a, b)
    elseif t == "neg" then
      return neg(normalize(v.a))
    elseif t == "call" then
      local args = {}
      for i, x in ipairs(v.args) do
        args[i] = normalize(x)
      end
      -- an algebra function left unevaluated stays so (no retrying it)
      local f = not HELD[v.name] and F[v.name]
      return f and f(args) or call(v.name, args)
    elseif t == "vec" then
      local out = { tag = "vec" }
      for i, x in ipairs(v) do
        out[i] = normalize(x)
      end
      return out
    end
    return v
  end

  --- The same formula with `f` applied to each direct sub-formula.
  local function map_children(v, f)
    local t = tag(v)
    if t == "op" then
      return op(v.op, f(v.a), f(v.b))
    elseif t == "neg" then
      return { tag = "neg", a = f(v.a) }
    elseif t == "call" then
      local args = {}
      for i, x in ipairs(v.args) do
        args[i] = f(x)
      end
      return call(v.name, args)
    elseif t == "vec" then
      local out = { tag = "vec" }
      for i, x in ipairs(v) do
        out[i] = f(x)
      end
      return out
    end
    return v
  end

  --- math-expr-contains
  local function contains(expr, thing)
    if same(expr, thing) then
      return true
    end
    local t = tag(expr)
    if t == "op" then
      return contains(expr.a, thing) or contains(expr.b, thing)
    elseif t == "neg" then
      return contains(expr.a, thing)
    elseif t == "call" then
      for _, x in ipairs(expr.args) do
        if contains(x, thing) then
          return true
        end
      end
    elseif t == "vec" then
      for _, x in ipairs(expr) do
        if contains(x, thing) then
          return true
        end
      end
    end
    return false
  end

  --- math-expr-subst: replace `old` by `new`, without evaluating again
  --- (`subst(x^2, x, 3)` is `3^2`, as in Calc).
  local function subst(expr, old, new)
    if same(expr, old) then
      return new
    elseif primitive(expr) then
      return expr
    end
    return map_children(expr, function(x)
      return subst(x, old, new)
    end)
  end

  --- Run `f` with Calc's math-simplifying on.
  local function simplifying(f, ...)
    local old = K.set_simplifying(true)
    local ok, r = pcall(f, ...)
    K.set_simplifying(old)
    if not ok then
      error(r, 0)
    end
    return r
  end

  ---------------------------------------------------------------------------
  -- simplify (math-simplify)
  ---------------------------------------------------------------------------

  -- A settable reference to a sub-formula (a cons cell in Calc): the field
  -- `k` of the node `t`.
  local function cell(t, k)
    return {
      get = function()
        return t[k]
      end,
      set = function(v)
        t[k] = v
      end,
    }
  end

  -- the Calc symbol of a node, for the canonical order of math-beforep
  local HEAD = { ["=="] = "calcFunc-eq", ["!="] = "calcFunc-neq", ["<"] = "calcFunc-lt", [">"] = "calcFunc-gt" }
  HEAD["<="], HEAD[">="], HEAD["&&"], HEAD["||"] = "calcFunc-leq", "calcFunc-geq", "calcFunc-land", "calcFunc-lor"
  local function head(v)
    local t = tag(v)
    if t == "op" then
      return HEAD[v.op] or v.op
    elseif t == "call" then
      return "calcFunc-" .. v.name
    end
    return t
  end
  local function parts(v)
    local t = tag(v)
    if t == "op" then
      return { v.a, v.b }
    elseif t == "neg" then
      return { v.a }
    elseif t == "call" then
      return v.args
    elseif t == "vec" then
      return v
    end
    return {}
  end

  --- math-beforep: the canonical order of terms and factors.
  local function beforep(a, b)
    if is_real(a) and is_real(b) then
      local c = K.num_cmp(a, b)
      local rank = { int = 3, big = 3, frac = 2, float = 1 }
      return c < 0 or (c == 0 and not same(a, b) and rank[tag(a)] > rank[tag(b)])
    elseif is_real(a) then
      return true
    elseif is_real(b) then
      return false
    elseif (is_object(a) or false) ~= (is_object(b) or false) then
      return is_object(a) and true or false
    elseif tag(a) == "sym" then
      if tag(b) == "sym" then
        return a.name < b.name
      end
      return not is_number(b)
    elseif tag(b) == "sym" then
      return is_number(a)
    elseif head(a) == head(b) then
      local pa, pb = parts(a), parts(b)
      local i = 1
      while pb[i] ~= nil and pa[i] ~= nil and same(pa[i], pb[i]) do
        i = i + 1
      end
      return pb[i] ~= nil and (pa[i] == nil or beforep(pa[i], pb[i]))
    end
    return head(a) < head(b)
  end

  --- math-to-simple-fraction
  local function simple_fraction(v)
    if tag(v) == "float" then
      local x = v.v
      if x == math.floor(x) and math.abs(x) < 2 ^ 53 then
        return x
      end
      for d = 1, 3 do
        local n = x * 10 ^ d
        if math.abs(n - math.floor(n + 0.5)) < 1e-9 and math.abs(n) < 1000 then
          return K.make_frac(math.floor(n + 0.5), 10 ^ d)
        end
      end
    end
    return v
  end

  local function frac_parts(v)
    if tag(v) == "frac" then
      return v.n, v.d
    end
    return v, 1
  end

  local function igcd(a, b)
    a, b = math.abs(a), math.abs(b)
    while b ~= 0 do
      a, b = b, a % b
    end
    return a
  end

  --- math-frac-gcd
  local function frac_gcd(a, b)
    if is_zero(a) then
      return b
    elseif is_zero(b) then
      return a
    elseif type(a) == "number" and type(b) == "number" then
      return igcd(a, b)
    end
    local an, ad = frac_parts(a)
    local bn, bd = frac_parts(b)
    return K.make_frac(igcd(an, bn), igcd(ad, bd))
  end

  --- math-common-constant-factor: a rational factor of every term.
  local function ccf(expr)
    if is_real(expr) then
      if is_rat(expr) then
        if expr == 0 or expr == 1 or expr == -1 then
          return nil
        end
        return negative(expr) and neg(expr) or expr
      end
      local r = simple_fraction(expr)
      return is_rat(r) and ccf(r) or nil
    end
    if isop(expr, "+", "-") then
      local f1, f2 = ccf(expr.a), ccf(expr.b)
      if f1 and f2 then
        local g = frac_gcd(f1, f2)
        return g ~= 1 and g or nil
      end
    elseif isop(expr, "*") then
      return ccf(expr.a)
    elseif isop(expr, "/") then
      return ccf(expr.a) or (is_int(expr.b) and K.make_frac(1, math.abs(expr.b))) or nil
    end
    return nil
  end

  --- math-cancel-common-factor
  local function cancel(expr, val)
    if isop(expr, "+", "-") then
      expr.a = cancel(expr.a, val)
      expr.b = cancel(expr.b, val)
      return expr
    elseif isop(expr, "*") then
      return mul(cancel(expr.a, val), expr.b)
    end
    return div(expr, val)
  end

  --- math-possible-signs, for numbers only: 1 negative, 2 zero, 4 positive
  --- (7: unknown).
  local function signs(v)
    if is_real(v) then
      return negative(v) and 1 or (is_zero(v) and 2 or 4)
    end
    return 7
  end

  -- the relation after multiplying both sides by a negative number
  local TWEAK = { ["=="] = "==", ["!="] = "!=", ["<"] = ">", [">"] = "<", ["<="] = ">=", [">="] = "<=" }

  local simplify_divisor

  local function simplify_one_divisor(expr, np, dp, nover, dover)
    local temp = K.combine_prod(np.get(), dp.get(), nover, dover, true)
    if temp ~= nil then
      if not (expr.op == "/" or expr.op == "==" or expr.op == "!=") and negative(dp.get()) and TWEAK[expr.op] then
        expr.op = TWEAK[expr.op]
      end
      np.set(nover and div(1, temp) or temp)
      dp.set(1)
    elseif dover and not nover and expr.op == "/" and is_call(dp.get(), "sqrt") and is_int(dp.get().args[1]) then
      local arg = dp.get().args[1]
      np.set(mul(np.get(), call("sqrt", { arg })))
      dp.set(arg)
    end
  end

  simplify_divisor = function(expr, np, dp, nover, dover)
    local d = dp.get()
    if isop(d, "/") then
      simplify_divisor(expr, np, cell(d, "a"), nover, dover)
      if K.known_scalar(d.a, true) then
        simplify_divisor(expr, np, cell(d, "b"), nover, not dover)
      end
      return
    end
    local s = signs(np.get())
    if expr.op == "/" or s == 1 or s == 4 or is_number(np.get()) then
      local safe, scalar = true, K.known_scalar(np.get())
      while isop(dp.get(), "*") and safe do
        d = dp.get()
        simplify_one_divisor(expr, np, cell(d, "a"), nover, dover)
        safe = scalar or K.known_scalar(d.a, true)
        dp = cell(d, "b")
      end
      if safe then
        simplify_one_divisor(expr, np, dp, nover, dover)
      end
    end
  end

  --- math-simplify-divide: cancel common factors of a quotient or of the
  --- two sides of an equation.
  local function simplify_divide(expr)
    local nn = (expr.op == "/" or not is_real(expr.b)) and ccf(expr.b)
    if nn then
      local n = (expr.op == "/" or not is_real(expr.a)) and ccf(expr.a)
      if tag(nn) == "frac" and nn.n == 1 and not n then
        if not (expr.op == "==" and tag(expr.a) == "sym" and not contains(expr.b, expr.a)) then
          expr.a = mul(nn.d, expr.a)
          expr.b = cancel(expr.b, nn)
        end
      elseif n then
        n = frac_gcd(n, nn)
        if n ~= 1 then
          expr.a = cancel(expr.a, n)
          expr.b = cancel(expr.b, n)
          if negative(n) and TWEAK[expr.op] then
            expr.op = TWEAK[expr.op]
          end
        end
      end
    end
    local np = cell(expr, "a")
    local nover = false
    if isop(np.get(), "/") and K.known_scalar(expr.b, true) then
      local num = expr.a
      np = cell(num, "a")
      while isop(np.get(), "*") do
        local n = np.get()
        if K.known_scalar(n.b, true) then
          simplify_divisor(expr, cell(n, "a"), cell(expr, "b"), false, true)
        end
        np = cell(n, "b")
      end
      simplify_divisor(expr, np, cell(expr, "b"), false, true)
      nover = true
      np = cell(num, "b")
    end
    while isop(np.get(), "*") do
      local n = np.get()
      if K.known_scalar(n.b, true) then
        simplify_divisor(expr, cell(n, "a"), cell(expr, "b"), nover, true)
      end
      np = cell(n, "b")
    end
    simplify_divisor(expr, np, cell(expr, "b"), nover, true)
    return expr
  end

  --- math-simplify-add-term: move a term of the left side of an equation
  --- to the right one when they combine.
  local function simplify_add_term(np, dp, minus, lplain)
    if tag(np.get()) == "vec" then
      return
    end
    local rplain = true
    local n, d = np.get(), dp.get()
    while isop(d, "+", "-") do
      rplain = false
      local temp = K.combine_sum(n, d.b, minus, d.op == "+", true)
      if temp ~= nil then
        if lplain or looks_neg(temp) == minus then
          np.set(minus and neg(temp) or temp)
          d.b = 0
        else
          np.set(0)
          d.b = d.op == "+" and neg(temp) or temp
        end
      end
      dp = cell(d, "a")
      n, d = np.get(), dp.get()
    end
    local temp = K.combine_sum(n, d, minus, true, true)
    if temp ~= nil then
      if lplain or (not rplain and looks_neg(temp) == minus) then
        np.set(minus and neg(temp) or temp)
        dp.set(0)
      else
        np.set(0)
        dp.set(neg(temp))
      end
    end
  end

  --- math-simplify-ineq: an equation or inequality.
  local function simplify_ineq(expr)
    local np = cell(expr, "a")
    local plain = true
    while isop(np.get(), "+", "-") do
      local n = np.get()
      simplify_add_term(cell(n, "b"), cell(expr, "b"), n.op == "-", false)
      np = cell(n, "a")
      plain = false
    end
    simplify_add_term(np, cell(expr, "b"), false, plain)
    simplify_divide(expr)
    local s
    if is_real(expr.a) and is_real(expr.b) then
      s = signs(sub(expr.a, expr.b))
    elseif same(expr.a, expr.b) then
      s = 2
    else
      return expr
    end
    local o = expr.op
    local r
    if o == "==" then
      r = s == 2 and 1 or 0
    elseif o == "!=" then
      r = s == 2 and 0 or 1
    elseif o == "<" then
      r = s == 1 and 1 or 0
    elseif o == ">" then
      r = s == 4 and 1 or 0
    elseif o == "<=" then
      r = s == 4 and 0 or 1
    elseif o == ">=" then
      r = s == 1 and 0 or 1
    end
    return r or expr
  end

  local function simplify_addsub(expr)
    local a = expr.a
    if isop(a, "+", "-") and is_number(a.b) and not is_number(expr.b) then
      -- (u + 2) + x is (u + x) + 2
      local x, o = expr.b, expr.op
      expr.b, expr.op = a.b, a.op
      a.b, a.op = x, o
    elseif expr.op == "+" and is_number(expr.a) and not is_number(expr.b) then
      expr.a, expr.b = expr.b, expr.a
    end
    local aa, aaa = expr, nil
    while true do
      aaa = aa.a
      if not isop(aaa, "+", "-") then
        break
      end
      local temp = K.combine_sum(aaa.b, expr.b, aaa.op == "-", expr.op == "-", true)
      if temp ~= nil then
        expr.b, expr.op = temp, "+"
        aaa.b = 0
      end
      aa = aa.a
    end
    local temp = K.combine_sum(aaa, expr.b, false, expr.op == "-", true)
    if temp ~= nil then
      expr.b, expr.op = temp, "+"
      aa.a = 0
    end
    return expr
  end

  local function simplify_mul(expr)
    local b = expr.b
    if isop(b, "*") then
      if beforep(b.a, expr.a) and (K.known_scalar(expr.a, true) or K.known_scalar(b.a, true)) then
        expr.a, b.a = b.a, expr.a
      end
    elseif beforep(expr.b, expr.a) and (K.known_scalar(expr.a, true) or K.known_scalar(expr.b, true)) then
      expr.a, expr.b = expr.b, expr.a
    end
    local safe, scalar = true, K.known_scalar(expr.a)
    if is_rat(expr.a) then
      local temp = ccf(expr.b)
      if temp then
        expr.b = cancel(expr.b, temp)
        expr.a = mul(expr.a, temp)
      end
    end
    local aa, aaa = expr, nil
    while true do
      aaa = aa.b
      if not (isop(aaa, "*") and safe) then
        break
      end
      local temp = K.combine_prod(expr.a, aaa.a, false, false, true)
      if temp ~= nil then
        expr.a = temp
        aaa.a = 1
      end
      safe = scalar or K.known_scalar(aaa.a, true)
      aa = aa.b
    end
    local temp = K.combine_prod(aaa, expr.a, false, false, true)
    if temp ~= nil and safe then
      expr.a = temp
      aa.b = 1
    end
    local f = expr.a
    if tag(f) == "frac" and (f.n == 1 or f.n == -1) then
      return div(mul(expr.b, f.n), f.d)
    end
    return expr
  end

  --- math-squared-factor: the product of the squares of small primes that
  --- divide an integer.
  local function squared_factor(x)
    if type(x) ~= "number" then
      return nil
    end
    local fac = 1
    for _, p in ipairs({ 4, 9, 25, 49, 121, 169, 289, 361, 529, 841 }) do
      while x % p == 0 and x ~= 0 do
        x, fac = x / p, fac * p
      end
    end
    return fac
  end

  local function simplify_sqrt(expr)
    local u = expr.args[1]
    if tag(u) == "frac" then
      return div(call("sqrt", { mul(u.n, u.d) }), u.d)
    end
    local fac
    if is_object(u) then
      fac = squared_factor(u)
    else
      fac = ccf(u)
    end
    if fac and fac ~= 1 then
      return mul(F.sqrt({ fac }), F.sqrt({ cancel(u, fac) }))
    end
    return nil
  end

  local function simplify_exp(x)
    if is_call(x, "ln") then
      return x.args[1]
    end
    return nil
  end

  -- trigonometric rules: f(g(u)) for inverse functions, f(-u)
  local function sqrt_1_minus_sqr(u)
    return call("sqrt", { sub(1, mul(u, u)) })
  end
  local function sqrt_1_plus_sqr(u)
    return call("sqrt", { add(1, mul(u, u)) })
  end
  local TRIG = {
    sin = {
      arcsin = function(u)
        return u
      end,
      arccos = sqrt_1_minus_sqr,
      arctan = function(u)
        return div(u, sqrt_1_plus_sqr(u))
      end,
      odd = true,
    },
    cos = {
      arccos = function(u)
        return u
      end,
      arcsin = sqrt_1_minus_sqr,
      arctan = function(u)
        return div(1, sqrt_1_plus_sqr(u))
      end,
      odd = false,
    },
    tan = {
      arctan = function(u)
        return u
      end,
      arcsin = function(u)
        return div(u, sqrt_1_minus_sqr(u))
      end,
      arccos = function(u)
        return div(sqrt_1_minus_sqr(u), u)
      end,
      odd = true,
    },
    sinh = {
      arcsinh = function(u)
        return u
      end,
      odd = true,
    },
    cosh = {
      arccosh = function(u)
        return u
      end,
      odd = false,
    },
    tanh = {
      arctanh = function(u)
        return u
      end,
      odd = true,
    },
  }
  local INVERSE_OF = { arcsin = "sin", arccos = "cos", arctan = "tan", arcsinh = "sinh", arctanh = "tanh" }

  local function simplify_call(expr)
    local name, u = expr.name, expr.args[1]
    if #expr.args ~= 1 then
      return nil
    end
    local rules = TRIG[name]
    if rules then
      if tag(u) == "call" and #u.args == 1 and rules[u.name] then
        return rules[u.name](u.args[1])
      elseif looks_neg(u) then
        local r = call(name, { neg(u) })
        return rules.odd and neg(r) or r
      end
      return nil
    elseif INVERSE_OF[name] and looks_neg(u) then
      -- arcsin(-x) is -arcsin(x)
      return neg(call(name, { neg(u) }))
    elseif name == "sqrt" then
      return simplify_sqrt(expr)
    elseif name == "exp" then
      return simplify_exp(u)
    end
    return nil
  end

  local function simplify_pow(expr)
    local a, b = expr.a, expr.b
    if K.equal_int(a, 10) and is_call(b, "log10") then
      return b.args[1]
    elseif tag(a) == "sym" and a.name == "e" then
      return simplify_exp(b)
    elseif is_call(a, "exp") then
      return call("exp", { mul(a.args[1], b) })
    end
    return nil
  end

  local function handler(aa)
    local t = tag(aa)
    if t == "op" then
      if aa.op == "+" or aa.op == "-" then
        return simplify_addsub(aa)
      elseif aa.op == "*" then
        return simplify_mul(aa)
      elseif aa.op == "/" then
        return simplify_divide(aa)
      elseif aa.op == "^" then
        return simplify_pow(aa)
      elseif COMPARE[aa.op] then
        return simplify_ineq(aa)
      end
    elseif t == "call" then
      return simplify_call(aa)
    end
    return nil
  end

  --- math-simplify-step: simplify the parts, then the formula itself.
  local function simplify_step(a)
    if primitive(a) then
      return a
    end
    local aa = map_children(a, simplify_step)
    local r = handler(aa)
    if r ~= nil then
      return r
    end
    return aa
  end

  --- math-simplify: normalize and simplify until nothing changes.
  local function simplify(top)
    return simplifying(function()
      for _ = 1, 100 do
        local res = simplify_step(normalize(top))
        if same(top, res) then
          break
        end
        top = res
      end
      return top
    end)
  end

  F.simplify = function(args)
    if #args ~= 1 then
      return call("simplify", args)
    end
    return simplify(args[1])
  end
  F.subst = function(args)
    if #args ~= 3 then
      return call("subst", args)
    end
    return subst(args[1], args[2], args[3])
  end

  ---------------------------------------------------------------------------
  -- expand (calc-poly.el)
  ---------------------------------------------------------------------------

  local function add_or_sub(a, b, aneg, bneg)
    if aneg then
      a = neg(a)
    end
    if bneg then
      b = neg(b)
    end
    return add(a, b)
  end

  --- math-expand-power: a sum to a small power, term by term.
  local function expand_power(x, n)
    if not (type(n) == "number" and n >= 0 and isop(x, "+", "-")) then
      return nil
    end
    local terms = {}
    while isop(x, "+", "-") do
      table.insert(terms, 1, x.op == "-" and neg(x.b) or x.b)
      x = x.a
    end
    table.insert(terms, 1, x)
    local accum = 0
    if #terms == 2 then
      for i = 0, n do
        accum = op(
          "+",
          accum,
          op("*", F.choose({ n, i }), op("*", op("^", terms[2], i), op("^", terms[1], n - i)))
        )
      end
    elseif n == 2 then
      for i = 1, #terms do
        accum = op("+", accum, op("^", terms[i], 2))
        for j = i + 1, #terms do
          accum = op("+", accum, op("*", 2, op("*", terms[i], terms[j])))
        end
      end
    elseif n == 3 then
      for i = 1, #terms do
        accum = op("+", accum, op("^", terms[i], 3))
        for j = i + 1, #terms do
          accum = op(
            "+",
            op("+", accum, op("*", 3, op("*", op("^", terms[i], 2), terms[j]))),
            op("*", 3, op("*", terms[i], op("^", terms[j], 2)))
          )
          for k = j + 1, #terms do
            accum = op("+", accum, op("*", 6, op("*", terms[i], op("*", terms[j], terms[k]))))
          end
        end
      end
    else
      return nil
    end
    return accum
  end

  --- math-expand-term: distribute one product, quotient or power of a sum.
  local function expand_term(expr)
    if isop(expr, "*") and isop(expr.a, "+", "-") then
      return add_or_sub(op("*", expr.a.a, expr.b), op("*", expr.a.b, expr.b), false, expr.a.op == "-")
    elseif isop(expr, "*") and isop(expr.b, "+", "-") then
      return add_or_sub(op("*", expr.a, expr.b.a), op("*", expr.a, expr.b.b), false, expr.b.op == "-")
    elseif isop(expr, "/") and isop(expr.a, "+", "-") then
      return add_or_sub(op("/", expr.a.a, expr.b), op("/", expr.a.b, expr.b), false, expr.a.op == "-")
    elseif isop(expr, "^") and isop(expr.a, "+", "-") and type(expr.b) == "number" then
      if expr.b > 0 then
        return expand_power(expr.a, expr.b) or op("*", expr.a, op("^", expr.a, expr.b - 1))
      elseif expr.b < 0 then
        return op("/", 1, op("^", expr.a, -expr.b))
      end
    end
    return expr
  end

  --- math-map-tree: apply `f` to every node until nothing changes.
  local function map_tree(f, expr)
    local budget = 20000
    local function rec(e)
      while budget > 0 do
        while budget > 0 do
          budget = budget - 1
          local nv = f(e)
          if same(e, nv) then
            break
          end
          e = nv
        end
        if primitive(e) then
          break
        end
        local nv = map_children(e, rec)
        if same(nv, e) then
          break
        end
        e = nv
      end
      return e
    end
    return rec(expr)
  end

  local function expand(expr)
    return normalize(map_tree(expand_term, expr))
  end

  F.expand = function(args)
    if #args < 1 or #args > 2 then
      return call("expand", args)
    end
    return expand(args[1])
  end

  ---------------------------------------------------------------------------
  -- Polynomials (math-is-polynomial) and collect
  ---------------------------------------------------------------------------

  local function poly_mix(a, ac, b, bc)
    local out = {}
    for i = 1, math.max(#a, #b) do
      out[i] = add(mul(a[i] or 0, ac), mul(b[i] or 0, bc))
    end
    return out
  end

  local function poly_mul(a, b)
    if #a == 0 or #b == 0 then
      return {}
    end
    local rest = { unpack(a, 2) }
    local shifted = { 0, unpack(b) }
    return poly_mix(b, a[1], #rest > 0 and poly_mul(rest, shifted) or {}, 1)
  end

  local function poly_simplify(p)
    while #p > 1 and is_zero(p[#p]) do
      p[#p] = nil
    end
    return p
  end

  --- The coefficients { c0, c1, ... } of `expr` as a polynomial in `var`,
  --- or nil. `base` is the variable whose presence makes a term
  --- non-constant (nil with `loose`: every other term is a coefficient).
  local function is_polynomial(expr, var, degree, loose, base)
    base = base or var
    local function depends(x)
      return not loose and contains(x, base)
    end
    local rec
    rec = function(e)
      local r
      if same(e, var) then
        r = { 0, 1 }
      elseif isop(e, "^") then
        local b, n = e.a, e.b
        if type(n) == "number" and n >= 0 then
          local p1 = same(b, var) and { 0, 1 } or rec(b)
          if p1 and (not degree or (#p1 - 1) * n <= degree) then
            r = { 1 }
            for _ = 1, n do
              r = poly_mul(r, p1)
            end
          end
        end
      elseif is_object(e) then
        r = { e }
      elseif isop(e, "+", "-") then
        local p1 = rec(e.a)
        local p2 = p1 and rec(e.b)
        if p2 then
          r = poly_mix(p1, 1, p2, e.op == "+" and 1 or -1)
        end
      elseif tag(e) == "neg" then
        local p1 = rec(e.a)
        if p1 then
          r = {}
          for i, c in ipairs(p1) do
            r[i] = neg(c)
          end
        end
      elseif isop(e, "*") then
        local p1 = rec(e.a)
        local p2 = p1 and rec(e.b)
        if p2 and (not degree or #p1 + #p2 - 2 <= degree) then
          r = poly_mul(p1, p2)
        end
      elseif isop(e, "/") then
        if not depends(e.b) and not is_zero(e.b) then
          local p1 = rec(e.a)
          if p1 then
            r = {}
            for i, c in ipairs(p1) do
              r[i] = div(c, e.b)
            end
          end
        end
      end
      if r == nil and not depends(e) and tag(e) ~= "vec" then
        r = { e }
      end
      return r and poly_simplify(r)
    end
    local p = rec(expr)
    if p and degree and #p > degree + 1 then
      return nil
    end
    return p
  end

  --- math-build-polynomial-expr
  local function build_polynomial(p, var)
    local n = #p - 1
    local accum = mul(p[#p], pow(var, n))
    for i = #p - 1, 1, -1 do
      n = n - 1
      local c = p[i]
      if not is_zero(c) then
        local negc = looks_neg(c)
        accum = op(negc and "-" or "+", accum, mul(negc and neg(c) or c, pow(var, n)))
      end
    end
    return accum
  end

  F.collect = function(args)
    if #args ~= 2 then
      return call("collect", args)
    end
    local p = is_polynomial(args[1], args[2], 50, true)
    if not p then
      return call("collect", args)
    elseif #p > 1 then
      for i, c in ipairs(p) do
        p[i] = normalize(c)
      end
      return build_polynomial(p, args[2])
    end
    return p[1]
  end

  ---------------------------------------------------------------------------
  -- deriv (math-derivative)
  ---------------------------------------------------------------------------

  local PI = sym("pi")

  --- An angle in the angle mode to radians, kept symbolic (math-to-radians-2).
  local function to_radians(a)
    if K.modes().deg then
      return div(mul(a, PI), 180)
    end
    return a
  end

  local function from_radians(a)
    if K.modes().deg then
      return div(mul(a, 180), PI)
    end
    return a
  end

  local function sqr(u)
    return mul(u, u)
  end

  local function fn(name, ...)
    local f = F[name]
    local args = { ... }
    return f and f(args) or call(name, args)
  end

  -- derivatives of functions of one argument (the `f'` handlers)
  local DERIV = {
    sqrt = function(u)
      return div(1, mul(2, call("sqrt", { u })))
    end,
    ln = function(u)
      return div(1, u)
    end,
    log10 = function(u)
      return div(div(1, fn("ln", 10)), u)
    end,
    exp = function(u)
      return fn("exp", u)
    end,
    sin = function(u)
      return to_radians(fn("cos", u))
    end,
    cos = function(u)
      return neg(to_radians(fn("sin", u)))
    end,
    tan = function(u)
      return to_radians(sqr(fn("sec", u)))
    end,
    sec = function(u)
      return to_radians(mul(fn("sec", u), fn("tan", u)))
    end,
    csc = function(u)
      return neg(to_radians(mul(fn("csc", u), fn("cot", u))))
    end,
    cot = function(u)
      return neg(to_radians(sqr(fn("csc", u))))
    end,
    arcsin = function(u)
      return from_radians(div(1, fn("sqrt", sub(1, sqr(u)))))
    end,
    arccos = function(u)
      return from_radians(div(-1, fn("sqrt", sub(1, sqr(u)))))
    end,
    arctan = function(u)
      return from_radians(div(1, add(1, sqr(u))))
    end,
    sinh = function(u)
      return fn("cosh", u)
    end,
    cosh = function(u)
      return fn("sinh", u)
    end,
    tanh = function(u)
      return sqr(fn("sech", u))
    end,
    arcsinh = function(u)
      return div(1, fn("sqrt", add(sqr(u), 1)))
    end,
    arccosh = function(u)
      return div(1, fn("sqrt", add(sqr(u), -1)))
    end,
    arctanh = function(u)
      return div(1, sub(1, sqr(u)))
    end,
    deg = function()
      return div(K.float(180), K.float(math.pi))
    end,
    rad = function()
      return K.float(math.pi / 180)
    end,
    inv = function(u)
      return neg(div(1, sqr(u)))
    end,
  }

  local function derivative(expr, var)
    local function d(e)
      if same(e, var) then
        return 1
      end
      local t = tag(e)
      if is_object(e) or t == "sym" or t == "str" then
        return 0
      elseif t == "op" then
        local o = e.op
        if o == "+" then
          return add(d(e.a), d(e.b))
        elseif o == "-" then
          return sub(d(e.a), d(e.b))
        elseif COMPARE[o] then
          return op(o, d(e.a), d(e.b))
        elseif o == "*" then
          return add(mul(e.b, d(e.a)), mul(e.a, d(e.b)))
        elseif o == "/" then
          return sub(div(d(e.a), e.b), div(mul(e.a, d(e.b)), sqr(e.b)))
        elseif o == "^" then
          local du, dv = d(e.a), d(e.b)
          if not is_zero(du) then
            du = mul(e.b, mul(pow(e.a, add(e.b, -1)), du))
          end
          if not is_zero(dv) then
            dv = mul(fn("ln", e.a), mul(e, dv))
          end
          return add(du, dv)
        elseif o == "%" then
          return d(e.a)
        end
      elseif t == "neg" then
        return neg(d(e.a))
      elseif t == "vec" then
        return map_children(e, d)
      elseif t == "call" then
        if e.name == "re" or e.name == "im" or e.name == "conj" then
          return call(e.name, { d(e.args[1]) })
        end
        -- the sum of the partial derivatives, `f'(x)` for unknown ones
        local accum = 0
        for i, arg in ipairs(e.args) do
          local dv = d(arg)
          if not is_zero(dv) then
            local h = #e.args == 1 and DERIV[e.name]
            local fd = h and h(arg) or call(e.name .. "'" .. (i > 1 and tostring(i) or ""), e.args)
            accum = add(accum, mul(dv, fd))
          end
        end
        return accum
      end
      return call("deriv", { e, var })
    end
    return d(expr)
  end

  F.deriv = function(args)
    local expr, var, value = args[1], args[2], args[3]
    if #args < 2 or #args > 3 then
      return call("deriv", args)
    end
    local res = normalize(derivative(expr, var))
    if value ~= nil then
      return subst(res, var, value)
    end
    return res
  end

  ---------------------------------------------------------------------------
  -- integ
  ---------------------------------------------------------------------------

  --- `u` as a * var + b with a, b free of var, or nil.
  local function linear(u, var)
    -- exact coefficients (x / 2 is 1:2 x), as Calc's integrator finds them
    local modes = K.modes()
    local saved = modes.frac
    modes.frac = true
    local ok, p = pcall(is_polynomial, u, var, 1, false, var)
    modes.frac = saved
    if not ok then
      error(p, 0)
    end
    if p and #p == 2 and not contains(p[2], var) and not contains(p[1], var) then
      return p[2], p[1]
    end
    return nil
  end

  local integral

  --- An integral by parts for (polynomial in var) * f with f easy to
  --- integrate repeatedly (exp, sin, cos of a linear argument).
  local function by_parts(p, f, var, depth)
    if depth > 8 then
      return nil
    end
    local fi = integral(f, var, depth + 1)
    if not fi then
      return nil
    end
    local dp = normalize(derivative(p, var))
    if is_zero(dp) then
      return mul(p, fi)
    end
    local rest = integral(mul(dp, fi), var, depth + 1)
    return rest and expand(sub(mul(p, fi), rest))
  end

  --- The antiderivative of `e` in `var`, or nil when it isn't known.
  integral = function(e, var, depth)
    depth = depth or 0
    if depth > 12 then
      return nil
    end
    if not contains(e, var) then
      return mul(e, var)
    elseif same(e, var) then
      return div(pow(var, 2), 2)
    end
    local t = tag(e)
    if t == "op" and (e.op == "+" or e.op == "-") then
      local a, b = integral(e.a, var, depth), integral(e.b, var, depth)
      return a and b and (e.op == "+" and add(a, b) or sub(a, b))
    elseif t == "neg" then
      local a = integral(e.a, var, depth)
      return a and neg(a)
    elseif t == "op" and e.op == "*" then
      if not contains(e.a, var) then
        local r = integral(e.b, var, depth)
        return r and mul(e.a, r)
      elseif not contains(e.b, var) then
        local r = integral(e.a, var, depth)
        return r and mul(r, e.b)
      end
      -- polynomial times exp/sin/cos: by parts
      for _, pair in ipairs({ { e.a, e.b }, { e.b, e.a } }) do
        local p, f = pair[1], pair[2]
        if is_polynomial(p, var, 10, false, var) and tag(f) == "call" and #f.args == 1 then
          local nm = f.name
          if (nm == "exp" or nm == "sin" or nm == "cos") and linear(f.args[1], var) then
            local r = by_parts(p, f, var, depth)
            if r then
              return r
            end
          end
        end
      end
      local ex = expand(e)
      if not same(ex, e) then
        return integral(ex, var, depth + 1)
      end
      return nil
    elseif t == "op" and e.op == "/" then
      if not contains(e.b, var) then
        local r = integral(e.a, var, depth)
        return r and div(r, e.b)
      elseif not contains(e.a, var) then
        local den = e.b
        local a = linear(den, var)
        if a then
          -- c / (a x + b)
          return mul(e.a, div(fn("ln", den), a))
        end
        a = is_call(den, "sqrt") and linear(den.args[1], var)
        if a then
          -- c / sqrt(a x + b)
          return mul(e.a, div(mul(2, den), a))
        end
        local p = is_polynomial(den, var, 2, false, var)
        if p and #p == 3 and K.equal_int(p[3], 1) and K.equal_int(p[1], 1) and is_zero(p[2]) then
          -- c / (x^2 + 1)
          return mul(e.a, to_radians(fn("arctan", var)))
        end
        return integral(pow(den, -1), var, depth + 1)
      end
      return nil
    elseif t == "op" and e.op == "^" then
      local base, n = e.a, e.b
      if not contains(n, var) then
        local a = linear(base, var)
        if a then
          if K.equal_int(n, -1) then
            return div(fn("ln", base), a)
          end
          local n1 = add(n, 1)
          return div(pow(base, n1), mul(a, n1))
        end
        if isop(base, "+", "-") and type(n) == "number" and n > 1 then
          return integral(expand(e), var, depth + 1)
        end
      elseif not contains(base, var) then
        local a = linear(n, var)
        if a then
          -- c^(a x + b)
          return div(e, mul(a, fn("ln", base)))
        end
      end
      return nil
    elseif t == "call" and #e.args == 1 then
      local u = e.args[1]
      local a = linear(u, var)
      if not a then
        return nil
      end
      local nm = e.name
      local r
      if nm == "exp" then
        r = e
      elseif nm == "sin" then
        r = from_radians(neg(fn("cos", u)))
      elseif nm == "cos" then
        r = from_radians(fn("sin", u))
      elseif nm == "tan" then
        r = from_radians(fn("ln", fn("sec", u)))
      elseif nm == "sinh" then
        r = fn("cosh", u)
      elseif nm == "cosh" then
        r = fn("sinh", u)
      elseif nm == "ln" then
        r = sub(mul(u, e), u)
      elseif nm == "sqrt" then
        r = mul(K.make_frac(2, 3), call("sqrt", { pow(u, 3) }))
      else
        return nil
      end
      return K.equal_int(a, 1) and r or div(r, a)
    end
    return nil
  end

  --- calcFunc-integ: split sums and constant factors, then integrate.
  local function integ(expr, var, low, high)
    local function again(x)
      return integ(x, var, low, high)
    end
    if isop(expr, "+") then
      return add(again(expr.a), again(expr.b))
    elseif isop(expr, "-") then
      return sub(again(expr.a), again(expr.b))
    elseif tag(expr) == "neg" then
      return neg(again(expr.a))
    elseif isop(expr, "*") and not contains(expr.a, var) then
      return mul(expr.a, again(expr.b))
    elseif isop(expr, "*") and not contains(expr.b, var) then
      return mul(again(expr.a), expr.b)
    elseif isop(expr, "/") and not contains(expr.a, var) and not K.equal_int(expr.a, 1) then
      return mul(expr.a, again(div(1, expr.b)))
    elseif isop(expr, "/") and not contains(expr.b, var) then
      return div(again(expr.a), expr.b)
    elseif tag(expr) == "vec" then
      return map_children(expr, again)
    end
    local res = integral(expr, var)
    if res == nil then
      local args = { expr, var, low, high }
      return call("integ", args)
    end
    if low ~= nil and high ~= nil then
      return simplify(sub(subst(res, var, high), subst(res, var, low)))
    elseif low ~= nil then
      return simplify(subst(res, var, low))
    end
    return simplify(res)
  end

  F.integ = function(args)
    if #args < 2 or #args > 4 or tag(args[2]) ~= "sym" then
      return call("integ", args)
    end
    return integ(args[1], args[2], args[3], args[4])
  end

  ---------------------------------------------------------------------------
  -- solve (math-try-solve-for)
  ---------------------------------------------------------------------------

  -- the variable being solved for, and the direction of the solution for
  -- inequalities (math-solve-sign: 1 same, -1 reversed, nil unknown)
  local solve_var, solve_sign

  --- math-solve-get-sign without "all solutions": the simplified value.
  local function get_sign(val)
    val = simplify(val)
    if isop(val, "*") and is_number(val.a) then
      return op("*", val.a, get_sign(val.b))
    end
    if is_call(val, "sqrt") and isop(val.args[1], "^") then
      val = pow(val.args[1].a, div(val.args[1].b, 2))
    end
    return val
  end

  --- math-solve-sign: the direction after multiplying by `expr`.
  local function sign_by(sign, expr)
    if sign == nil or not is_real(expr) then
      return nil
    elseif negative(expr) then
      return -sign
    end
    return not is_zero(expr) and sign or nil
  end

  local function looks_even(e)
    if is_int(e) then
      return type(e) == "number" and e % 2 == 0
    elseif isop(e, "*", "/") then
      return looks_even(e.a)
    end
    return false
  end

  local try_solve

  local function integer_log2(n)
    local k = 0
    while n > 1 and n % 2 == 0 do
      n, k = n / 2, k + 1
    end
    return n == 1 and k > 0 and k or nil
  end

  -- Calc picks the arbitrary integers of general solutions as 0
  -- (math-solve-get-int without "all solutions"), but keeps their terms
  local function zero_term(scale)
    return mul(scale, 0)
  end

  local function try_solve_prod(lhs, rhs, sign)
    local var = solve_var
    if isop(lhs, "*") then
      if not contains(lhs.a, var) then
        return try_solve(lhs.b, div(rhs, lhs.a), sign_by(sign, lhs.a))
      elseif not contains(lhs.b, var) then
        return try_solve(lhs.a, div(rhs, lhs.b), sign_by(sign, lhs.b))
      elseif is_zero(rhs) then
        return try_solve(lhs.b, 0) or try_solve(lhs.a, 0)
      end
    elseif isop(lhs, "/") then
      if not contains(lhs.a, var) then
        return try_solve(lhs.b, div(lhs.a, rhs), sign_by(sign, lhs.a))
      elseif not contains(lhs.b, var) then
        return try_solve(lhs.a, mul(rhs, lhs.b), sign_by(sign, lhs.b))
      end
      return try_solve(sub(lhs.a, mul(lhs.b, rhs)), 0)
    elseif isop(lhs, "^") then
      local base, n = lhs.a, lhs.b
      if not contains(base, var) then
        local k = div(mul(2, mul(PI, zero_term(sym("i")))), fn("ln", base))
        return try_solve(n, add(fn("log", rhs, base), k))
      elseif not contains(n, var) then
        local k = type(n) == "number" and n >= 2 and integer_log2(n)
        if k then
          local t2 = rhs
          for _ = 1, k do
            t2 = get_sign(fn("sqrt", t2))
          end
          return try_solve(base, normalize(t2))
        elseif looks_neg(n) then
          return try_solve(op("^", base, neg(n)), div(1, rhs))
        end
        local odd = type(n) == "number" and n % 2 == 1
        local root = fn("exp", div(mul(PI, zero_term(sym("i"))), div(n, 2)))
        return try_solve(base, mul(root, fn("nroot", rhs, n)), odd and sign_by(sign, n) or nil)
      end
    end
    return nil
  end

  local contains_vars

  --- math-decompose-poly: the sub-formula (the variable itself, 1/x, ...)
  --- that `lhs` - `rhs` is a polynomial of, with its coefficients.
  local function decompose_poly(lhs, rhs)
    local var = solve_var
    local found
    local function pred(b)
      if same(b, lhs) then
        return false
      end
      local p = is_polynomial(lhs, b, 50, false, var)
      if not p then
        return false
      end
      p[1] = sub(p[1], rhs)
      -- math-solve-crunch-poly: x^2 (a x^2 + b) = 0 and powers of x^k
      local count = 0
      while #p > 0 and is_zero(p[1]) do
        table.remove(p, 1)
        count = count + 1
      end
      if #p == 0 then
        return false
      end
      local degree = #p - 1
      local power = 1
      for scale = degree, 2, -1 do
        if power == 1 and degree % scale == 0 then
          local ok, new = true, {}
          for i, c in ipairs(p) do
            if (i - 1) % scale == 0 then
              new[#new + 1] = c
            elseif not is_zero(c) then
              ok = false
            end
          end
          if ok then
            power, p = scale, new
          end
        end
      end
      if #p - 1 > 15 or not (contains(b, var)) then
        return false
      end
      found = { base = pow(b, power), coefs = p, factor = pow(b, count) }
      return true
    end
    local function rec(e, const_ok)
      if K.is_objvec(e) then
        return false
      end
      if isop(e, "+", "-") or isop(e, "*") then
        if rec(e.a, const_ok) or rec(e.b, const_ok) then
          return true
        end
      elseif isop(e, "/") or tag(e) == "neg" or isop(e, "^") then
        if rec(e.a, const_ok) then
          return true
        end
      end
      return (const_ok or contains_vars(e)) and pred(e)
    end
    if rec(lhs, false) or rec(lhs, true) then
      return found
    end
    return nil
  end

  --- math-expr-contains-vars
  contains_vars = function(e)
    local t = tag(e)
    if t == "sym" then
      return true
    elseif primitive(e) then
      return false
    end
    for _, x in ipairs(parts(e)) do
      if contains_vars(x) then
        return true
      end
    end
    return false
  end

  local function solve_quadratic(var, c, b, a)
    local val
    if looks_even(b) then
      local halfb = div(b, 2)
      val = div(add(neg(halfb), get_sign(fn("sqrt", add(sqr(halfb), mul(neg(c), a))))), a)
    else
      val = div(add(neg(b), get_sign(fn("sqrt", add(sqr(b), mul(4, mul(neg(c), a)))))), mul(2, a))
    end
    return try_solve(var, val, nil, true)
  end

  local function half_circle()
    return K.modes().deg and 180 or K.float(math.pi)
  end

  --- math-solve-cubic
  local function solve_cubic(var, d, c, b, a)
    local p, q, r = div(b, a), div(c, a), div(d, a)
    local psqr = sqr(p)
    local aa = sub(q, div(psqr, 3))
    local bb = add(r, div(sub(mul(2, mul(psqr, p)), mul(9, mul(p, q))), 27))
    if is_zero(aa) then
      return try_solve(pow(add(var, div(p, 3)), 3), neg(bb), nil, true)
    elseif is_zero(bb) then
      local v = add(var, div(p, 3))
      return try_solve(mul(v, add(sqr(v), aa)), 0, nil, true)
    end
    local m = mul(2, call("sqrt", { div(aa, -3) }))
    local angle = sub(call("arccos", { div(mul(3, bb), mul(aa, m)) }), mul(2, mul(add(1, 0), half_circle())))
    local root = sub(normalize(mul(m, call("cos", { div(angle, 3) }))), div(p, 3))
    if tag(root) == "cplx" and is_real(root.re) and is_real(root.im) then
      -- a real root reached through complex numbers: drop the rounding
      -- noise left in its imaginary part
      local re, im = K.tofloat(root.re), K.tofloat(root.im)
      if math.abs(im) <= math.abs(re) * 10 ^ -(K.modes().prec - 2) then
        root = root.re
      end
    end
    return try_solve(var, root, nil, true)
  end

  --- math-solve-quartic
  local function solve_quartic(var, d, c, b, a, aa)
    a, b, c, d = div(a, aa), div(b, aa), div(c, aa), div(d, aa)
    local asqr = sqr(a)
    local asqr4 = div(asqr, 4)
    local saved = solve_var
    local cd = sub(sub(mul(4, mul(b, d)), mul(asqr, d)), sqr(c))
    local y = solve_cubic(solve_var, cd, sub(mul(a, c), mul(4, d)), neg(b), 1)
    solve_var = saved
    if y == nil then
      return nil
    end
    local rsqr = add(sub(asqr4, b), y)
    local r = call("sqrt", { rsqr })
    local sign1 = get_sign(1)
    local de
    if is_zero(rsqr) then
      de = add(sub(mul(3, asqr4), mul(2, b)), mul(2, mul(sign1, call("sqrt", { sub(sqr(y), mul(4, d)) }))))
    else
      de = add(
        sub(mul(3, asqr4), mul(2, b)),
        sub(mul(sign1, div(sub(sub(mul(4, mul(a, b)), mul(8, c)), mul(asqr, a)), mul(4, r))), rsqr)
      )
    end
    de = call("sqrt", { de })
    local val = normalize(sub(add(mul(sign1, div(r, 2)), get_sign(div(de, 2))), div(a, 4)))
    return try_solve(var, val, nil, true)
  end

  -- the inverse of functions of one argument (math-inverse), and whether
  -- they keep (1) or reverse (-1) the order (math-inverse-sign)
  local INVERSE = {
    sqrt = function(x)
      return sqr(x)
    end,
    ln = function(x)
      return call("exp", { x })
    end,
    log10 = function(x)
      return call("exp10", { x })
    end,
    exp = function(x)
      return add(fn("ln", x), mul(2, mul(PI, zero_term(sym("i")))))
    end,
    sin = function(x)
      local n = 0
      return add(mul(fn("arcsin", x), pow(-1, n)), mul(half_circle(), n))
    end,
    cos = function(x)
      return add(get_sign(fn("arccos", x)), zero_term(mul(2, half_circle())))
    end,
    tan = function(x)
      return add(fn("arctan", x), zero_term(half_circle()))
    end,
    arcsin = function(x)
      return fn("sin", x)
    end,
    arccos = function(x)
      return fn("cos", x)
    end,
    arctan = function(x)
      return fn("tan", x)
    end,
    sinh = function(x)
      return fn("arcsinh", x)
    end,
    cosh = function(x)
      return get_sign(fn("arccosh", x))
    end,
    tanh = function(x)
      return fn("arctanh", x)
    end,
    arcsinh = function(x)
      return fn("sinh", x)
    end,
    arccosh = function(x)
      return fn("cosh", x)
    end,
    arctanh = function(x)
      return fn("tanh", x)
    end,
    abs = function(x)
      return get_sign(x)
    end,
    deg = function(x)
      return call("rad", { x })
    end,
    rad = function(x)
      return call("deg", { x })
    end,
    inv = function(x)
      return div(1, x)
    end,
  }
  local INVERSE_SIGN = {
    ln = 1,
    log10 = 1,
    exp = 1,
    deg = 1,
    rad = 1,
    sinh = 1,
    tanh = 1,
    arcsinh = 1,
    arctanh = 1,
    inv = -1,
  }

  try_solve = function(lhs, rhs, sign, no_poly)
    local var = solve_var
    if same(lhs, var) then
      solve_sign = sign
      return rhs
    elseif primitive(lhs) then
      return nil
    elseif tag(lhs) == "neg" then
      return try_solve(lhs.a, neg(rhs), sign and -sign)
    end
    local r = try_solve_prod(lhs, rhs, sign)
    if r ~= nil then
      return r
    end
    if not no_poly then
      local d = decompose_poly(lhs, rhs)
      if d then
        local p = d.coefs
        if #p == 5 then
          r = solve_quartic(d.base, p[1], p[2], p[3], p[4], p[5])
        elseif #p == 4 then
          r = solve_cubic(d.base, p[1], p[2], p[3], p[4])
        elseif #p == 3 then
          r = solve_quadratic(d.base, p[1], p[2], p[3])
        elseif #p == 2 then
          r = try_solve(d.base, div(neg(p[1]), p[2]), sign_by(sign, p[2]), true)
        elseif #p == 1 and not K.equal_int(d.factor, 1) then
          r = try_solve(d.factor, 0, nil, true)
        end
        -- (a polynomial of degree 5 or more: Calc finds a root numerically)
        return r
      end
    end
    if isop(lhs, "+") then
      if not contains(lhs.a, var) then
        return try_solve(lhs.b, sub(rhs, lhs.a), sign)
      elseif not contains(lhs.b, var) then
        return try_solve(lhs.a, sub(rhs, lhs.b), sign)
      end
    elseif isop(lhs, "==") then
      return try_solve(sub(lhs.a, lhs.b), rhs, sign, no_poly)
    elseif isop(lhs, "-") then
      if not contains(lhs.a, var) then
        return try_solve(lhs.b, sub(lhs.a, rhs), sign and -sign)
      elseif not contains(lhs.b, var) then
        return try_solve(lhs.a, add(rhs, lhs.b), sign)
      end
    elseif tag(lhs) == "call" and lhs.name == "log" and #lhs.args == 2 then
      if not contains(lhs.args[2], var) then
        return try_solve(lhs.args[1], pow(lhs.args[2], rhs))
      elseif not contains(lhs.args[1], var) then
        return try_solve(lhs.args[2], pow(lhs.args[1], div(1, rhs)))
      end
    elseif tag(lhs) == "call" and #lhs.args == 1 and INVERSE[lhs.name] then
      local s = INVERSE_SIGN[lhs.name]
      return try_solve(lhs.args[1], normalize(INVERSE[lhs.name](rhs)), sign and s and sign * s)
    end
    return nil
  end

  --- The floats of a formula rounded to the working precision.
  local function round_floats(v)
    local t = tag(v)
    if t == "float" then
      return K.float(v.v)
    elseif t == "cplx" then
      return { tag = "cplx", re = round_floats(v.re), im = round_floats(v.im) }
    elseif primitive(v) then
      return v
    end
    return map_children(v, round_floats)
  end

  --- math-solve-for: lhs = rhs for var, or nil.
  local function solve_for(lhs, rhs, var, sign)
    if contains(rhs, var) then
      return solve_for(sub(lhs, rhs), 0, var, sign)
    elseif not contains(lhs, var) then
      return nil
    end
    local saved = solve_var
    solve_var, solve_sign = var, nil
    -- extra working precision, as Calc's solver and its functions use
    local modes = K.modes()
    local prec = modes.prec
    modes.prec = prec + 3
    local ok, r = pcall(try_solve, lhs, rhs, sign)
    modes.prec = prec
    solve_var = saved
    if not ok then
      error(r, 0)
    end
    return r and round_floats(r)
  end

  local INEQ = { ["<"] = true, [">"] = true, ["<="] = true, [">="] = true, ["!="] = true }

  --- math-solve-eqn: an equation `var = solution`, or an inequality with
  --- the variable on the side it ends up on.
  local function solve_eqn(expr, var)
    if tag(expr) == "op" and INEQ[expr.op] then
      local res = solve_for(op("-", expr.a, expr.b), 0, var, expr.op ~= "!=" and 1 or nil)
      if res == nil then
        return nil
      elseif solve_sign == 1 then
        return op(expr.op, var, res)
      elseif solve_sign == -1 then
        return op(expr.op, res, var)
      elseif expr.op == "!=" or expr.op == "<" or expr.op == ">" then
        return op("!=", var, res)
      end
      return nil
    end
    local res = solve_for(expr, 0, var)
    return res ~= nil and op("==", var, res) or nil
  end

  F.solve = function(args)
    local expr, var = args[1], args[2]
    if #args ~= 2 or tag(var) ~= "sym" or tag(expr) == "vec" then
      return call("solve", args)
    end
    return solve_eqn(expr, var) or call("solve", args)
  end

  return { simplify = simplify, normalize = normalize }
end
