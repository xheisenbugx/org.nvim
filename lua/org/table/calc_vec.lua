---@mod org.table.calc_vec Vectors and matrices for the table Calc
---
--- Matrix products, powers and division, and Calc's vector functions (calc-vec.el,
--- calc-mtx.el): trn det inv cross head tail cons index cvec idn diag arrange rnorm cnorm
--- ... A function whose arguments don't fit stays symbolic, as Calc's
--- math-reject-arg leaves it.

---@param K table the internals of org.table.calc
return function(K)
  local F, tag, is_real, is_int = K.F, K.tag, K.is_real, K.is_int
  local add, sub, mul, div, neg = K.add, K.sub, K.mul, K.div, K.neg
  local call, is_zero, num_cmp = K.call, K.is_zero, K.num_cmp

  local function is_vec(v)
    return tag(v) == "vec"
  end

  local function vec(list)
    list.tag = "vec"
    return list
  end

  --- math-matrixp: a vector of vectors of the same length.
  local function is_matrix(v)
    if not is_vec(v) or #v == 0 or not is_vec(v[1]) or #v[1] == 0 then
      return false
    end
    for i = 2, #v do
      if not is_vec(v[i]) or #v[i] ~= #v[1] then
        return false
      end
    end
    return true
  end

  local function is_square(v)
    return is_matrix(v) and #v == #v[1]
  end

  --- A formula with no variables (math-constp).
  local function is_const(v)
    local t = tag(v)
    if t == "vec" then
      for _, x in ipairs(v) do
        if not is_const(x) then
          return false
        end
      end
      return true
    end
    return K.is_object(v)
  end

  local function dot(a, b)
    if #a == 0 then
      return 0
    end
    local accum = mul(a[1], b[1])
    for i = 2, #a do
      accum = add(accum, mul(a[i], b[i]))
    end
    return accum
  end

  local function mul_mats(a, b)
    local out = vec({})
    for i, row in ipairs(a) do
      local r = vec({})
      for j = 1, #b[1] do
        local accum = mul(row[1], b[1][j])
        for k = 2, #row do
          accum = add(accum, mul(row[k], b[k][j]))
        end
        r[j] = accum
      end
      out[i] = r
    end
    return out
  end

  local function transpose(m)
    local out = vec({})
    for j = 1, #m[1] do
      local col = vec({})
      for i = 1, #m do
        col[i] = m[i][j]
      end
      out[j] = col
    end
    return out
  end

  local function dimension_error()
    error("dimension error")
  end

  --- The product of two vectors (math-mul-objects-fancy): matrix product,
  --- matrix times vector, or the dot product of two plain vectors.
  local function mat_mul(a, b)
    if is_matrix(a) then
      if is_matrix(b) then
        if #a[1] ~= #b then
          dimension_error()
        end
        return mul_mats(a, b)
      elseif #a[1] == 1 then
        if #a ~= #b then
          dimension_error()
        end
        return mul_mats(a, vec({ b }))
      elseif #a[1] == #b then
        local out = vec({})
        for i, row in ipairs(a) do
          out[i] = dot(row, b)
        end
        return out
      end
      dimension_error()
    elseif is_matrix(b) then
      if #a ~= #b then
        dimension_error()
      end
      return mul_mats(vec({ a }), b)[1]
    end
    if #a ~= #b then
      dimension_error()
    end
    return dot(a, b)
  end

  local function identity(n, x)
    local out = vec({})
    for i = 1, n do
      local row = vec({})
      for j = 1, n do
        row[j] = i == j and x or 0
      end
      out[i] = row
    end
    return out
  end

  --- The floats of a value rounded to the working precision.
  local function round_floats(v)
    local t = tag(v)
    if t == "float" then
      return K.float(v.v)
    elseif t == "vec" then
      local out = vec({})
      for i, x in ipairs(v) do
        out[i] = round_floats(x)
      end
      return out
    end
    return v
  end

  --- Run `f` with 2 more digits of precision (math-with-extra-prec).
  local function extra_prec(f, ...)
    local modes = K.modes()
    local prec = modes.prec
    modes.prec = prec + 2
    local ok, r = pcall(f, ...)
    modes.prec = prec
    if not ok then
      error(r, 0)
    end
    return r ~= nil and round_floats(r) or nil
  end

  --- LU decomposition with partial pivoting (math-do-matrix-lud): the
  --- combined LU rows, the pivot rows and the sign of the permutation, or
  --- nil for a singular matrix.
  local function lud(m)
    local n = #m
    local lu = {}
    for i = 1, n do
      lu[i] = { unpack(m[i]) }
    end
    local d, index = 1, {}
    for j = 1, n do
      for i = 1, j - 1 do
        local s = lu[i][j]
        for k = 1, i - 1 do
          s = sub(s, mul(lu[i][k], lu[k][j]))
        end
        lu[i][j] = s
      end
      local big, imax = 0, j
      for i = j, n do
        local s = lu[i][j]
        for k = 1, j - 1 do
          s = sub(s, mul(lu[i][k], lu[k][j]))
        end
        lu[i][j] = s
        local dum = F.abs({ s })
        if not is_real(dum) then
          return nil
        end
        if is_zero(big) or num_cmp(big, dum) < 0 then
          big, imax = dum, i
        end
      end
      if imax > j then
        lu[j], lu[imax] = lu[imax], lu[j]
        d = -d
      end
      index[j] = imax
      local pivot = lu[j][j]
      if is_zero(pivot) then
        return nil
      end
      for i = j + 1, n do
        lu[i][j] = div(lu[i][j], pivot)
      end
    end
    return { lu = lu, index = index, d = d }
  end

  --- Solve LU x = b for a matrix b (math-lud-solve).
  local function lud_solve(dec, b)
    local lu, n = dec.lu, #b
    local x = {}
    for i = 1, n do
      x[i] = { unpack(b[i]) }
    end
    for col = 1, #b[1] do
      local ii
      for i = 1, n do
        local ip = dec.index[i]
        local sum = x[ip][col]
        x[ip][col] = x[i][col]
        if ii == nil then
          if not is_zero(sum) then
            ii = i
          end
        else
          for j = ii, i - 1 do
            sum = sub(sum, mul(lu[i][j], x[j][col]))
          end
        end
        x[i][col] = sum
      end
      for i = n, 1, -1 do
        local sum = x[i][col]
        for j = i + 1, n do
          sum = sub(sum, mul(lu[i][j], x[j][col]))
        end
        x[i][col] = div(sum, lu[i][i])
      end
    end
    local out = vec({})
    for i = 1, n do
      out[i] = vec(x[i])
    end
    return out
  end

  local function det_raw(m)
    local n = #m
    if n == 1 then
      return m[1][1]
    elseif n == 2 then
      return sub(mul(m[1][1], m[2][2]), mul(m[1][2], m[2][1]))
    elseif n == 3 then
      return sub(
        sub(
          sub(
            add(
              add(mul(m[1][1], mul(m[2][2], m[3][3])), mul(m[1][2], mul(m[2][3], m[3][1]))),
              mul(m[1][3], mul(m[2][1], m[3][2]))
            ),
            mul(m[1][3], mul(m[2][2], m[3][1]))
          ),
          mul(m[1][1], mul(m[2][3], m[3][2]))
        ),
        mul(m[1][2], mul(m[2][1], m[3][3]))
      )
    end
    local dec = lud(m)
    if not dec then
      return 0
    end
    local prod = dec.d
    for i = n, 1, -1 do
      prod = mul(prod, dec.lu[i][i])
    end
    return prod
  end

  --- The inverse of a square matrix (math-matrix-inv-raw), nil if singular.
  local function inv_raw(m)
    local n = #m
    local adj
    if n == 1 then
      adj = 1
    elseif n == 2 then
      adj = vec({ vec({ m[2][2], neg(m[1][2]) }), vec({ neg(m[2][1]), m[1][1] }) })
    elseif n == 3 then
      local function c(r1, c1, r2, c2, r3, c3, r4, c4)
        return sub(mul(m[r1][c1], m[r2][c2]), mul(m[r3][c3], m[r4][c4]))
      end
      adj = vec({
        vec({ c(3, 3, 2, 2, 2, 3, 3, 2), c(1, 3, 3, 2, 3, 3, 1, 2), c(2, 3, 1, 2, 1, 3, 2, 2) }),
        vec({ c(2, 3, 3, 1, 3, 3, 2, 1), c(3, 3, 1, 1, 1, 3, 3, 1), c(1, 3, 2, 1, 2, 3, 1, 1) }),
        vec({ c(3, 2, 2, 1, 2, 2, 3, 1), c(1, 2, 3, 1, 3, 2, 1, 1), c(2, 2, 1, 1, 1, 2, 2, 1) }),
      })
    end
    if adj then
      local det = det_raw(m)
      if is_zero(det) then
        return nil
      end
      return div(adj, det)
    end
    local dec = lud(m)
    return dec and lud_solve(dec, identity(n, 1))
  end

  --- Division by a vector (math-div-objects-fancy): only a square matrix
  --- divides, by solving with its LU decomposition.
  local function mat_div(a, b)
    if not is_square(b) then
      dimension_error()
    end
    local n = #b
    local r
    if is_vec(a) then
      r = extra_prec(function()
        if is_matrix(a) and #a == n then
          local dec = lud(b)
          return dec and lud_solve(dec, a)
        elseif is_matrix(a) and #a[1] == n then
          local dec = lud(transpose(b))
          return dec and transpose(lud_solve(dec, transpose(a)))
        elseif not is_matrix(a) and #a == n then
          local col = vec({})
          for i, x in ipairs(a) do
            col[i] = vec({ x })
          end
          local dec = lud(b)
          if not dec then
            return nil
          end
          local out = vec({})
          for i, row in ipairs(lud_solve(dec, col)) do
            out[i] = row[1]
          end
          return out
        end
        dimension_error()
      end)
    else
      r = extra_prec(inv_raw, b)
      if r and not K.equal_int(a, 1) then
        r = mul(a, r)
      end
    end
    if r == nil then
      error("singular matrix")
    end
    return r
  end

  --- An integer power of a vector: repeated products (math-ipow), the
  --- inverse for negative powers, the identity for 0.
  local function mat_pow(a, n)
    if type(n) ~= "number" then
      return K.op("^", a, n)
    end
    if n == 0 then
      if is_square(a) then
        return identity(#a, 1)
      end
      return 1
    elseif n < 0 then
      if not is_square(a) then
        dimension_error()
      end
      local ia = extra_prec(inv_raw, a)
      if not ia then
        error("singular matrix")
      end
      return mat_pow(ia, -n)
    end
    local function iipow(x, k)
      if k == 1 then
        return x
      elseif k % 2 == 0 then
        return iipow(mul(x, x), k / 2)
      end
      return mul(x, iipow(mul(x, x), (k - 1) / 2))
    end
    return iipow(a, n)
  end

  -- Functions ------------------------------------------------------------

  --- Register `name`, applied to the arguments when `test` accepts them,
  --- symbolic otherwise.
  local function def(name, test, fn)
    F[name] = function(args)
      if test(unpack(args)) then
        local r = fn(unpack(args))
        if r ~= nil then
          return r
        end
      end
      return call(name, args)
    end
  end

  local function fixnum(n)
    return type(n) == "number" and n == math.floor(n)
  end

  def("trn", function(m)
    return is_vec(m) or K.is_number(m)
  end, function(m)
    if not is_vec(m) then
      return m
    elseif is_matrix(m) then
      return transpose(m)
    end
    local out = vec({})
    for i, x in ipairs(m) do
      out[i] = vec({ x })
    end
    return out
  end)
  def("det", is_square, function(m)
    return extra_prec(det_raw, m)
  end)
  def("inv", function(m)
    return is_square(m) or K.is_number(m)
  end, function(m)
    if not is_vec(m) then
      return div(1, m)
    end
    return extra_prec(inv_raw, m)
  end)
  def("tr", is_square, function(m)
    local s = m[1][1]
    for i = 2, #m do
      s = add(s, m[i][i])
    end
    return s
  end)
  def("cross", function(a, b)
    return is_vec(a) and #a == 3 and is_vec(b) and #b == 3
  end, function(a, b)
    return vec({
      sub(mul(a[2], b[3]), mul(a[3], b[2])),
      sub(mul(a[3], b[1]), mul(a[1], b[3])),
      sub(mul(a[1], b[2]), mul(a[2], b[1])),
    })
  end)
  local function nonempty(v)
    return is_vec(v) and #v > 0
  end
  def("head", nonempty, function(v)
    return v[1]
  end)
  def("tail", nonempty, function(v)
    return vec({ unpack(v, 2) })
  end)
  def("rhead", nonempty, function(v)
    return vec({ unpack(v, 1, #v - 1) })
  end)
  def("rtail", nonempty, function(v)
    return v[#v]
  end)
  def("cons", function(_, t)
    return is_vec(t)
  end, function(h, t)
    return vec({ h, unpack(t) })
  end)
  def("rcons", function(h)
    return is_vec(h)
  end, function(h, t)
    local out = vec({ unpack(h) })
    out[#out + 1] = t
    return out
  end)
  def("append", function(a, b)
    return is_vec(a) and is_vec(b)
  end, function(a, b)
    local out = vec({ unpack(a) })
    for _, x in ipairs(b) do
      out[#out + 1] = x
    end
    return out
  end)
  F.vconcat = function(args)
    if #args == 2 then
      return K.concat(args[1], args[2])
    end
    return call("vconcat", args)
  end
  F.vec = function(args)
    return vec({ unpack(args) })
  end
  def("vlen", function(v)
    return is_vec(v) or K.is_object(v)
  end, function(v)
    return is_vec(v) and #v or 0
  end)
  def("index", function(n)
    return fixnum(n)
  end, function(n, start, incr)
    local out = vec({})
    if start ~= nil then
      if n >= 0 then
        for i = 1, n do
          out[i] = start
          start = add(start, incr or 1)
        end
      else
        for i = 1, -n do
          out[i] = start
          start = mul(start, incr or 2)
        end
      end
    elseif n >= 0 then
      for i = 1, n do
        out[i] = i
      end
    else
      for i = 1, -n do
        out[i] = -i
      end
    end
    return out
  end)
  F.cvec = function(args)
    local obj = args[1]
    local function make(k)
      local d = args[k]
      if d == nil then
        return obj
      end
      local out = vec({})
      for i = 1, d do
        out[i] = make(k + 1)
      end
      return out
    end
    for k = 2, #args do
      if not fixnum(args[k]) or args[k] < 0 then
        return call("cvec", args)
      end
    end
    return make(2)
  end
  local function diag(a, n)
    if is_vec(a) then
      if n and #a ~= n then
        return nil
      elseif is_matrix(a) then
        return (n and #a[1] ~= n) and nil or a
      end
      local out = vec({})
      for i = 1, #a do
        local row = vec({})
        for j = 1, #a do
          row[j] = i == j and a[i] or 0
        end
        out[i] = row
      end
      return out
    elseif n then
      return identity(n, a)
    end
  end
  def("diag", function(_, n)
    return n == nil or fixnum(n)
  end, diag)
  def("idn", function(a, n)
    return n ~= nil and fixnum(n) and not is_vec(a)
  end, diag)
  local function flat(v, out)
    out = out or vec({})
    if is_vec(v) then
      for _, x in ipairs(v) do
        flat(x, out)
      end
    else
      out[#out + 1] = v
    end
    return out
  end
  def("arrange", function(v, cols)
    return is_vec(v) and fixnum(cols)
  end, function(v, cols)
    local items = flat(v)
    if cols <= 0 then
      return items
    end
    local out = vec({})
    for i = 1, #items, cols do
      out[#out + 1] = vec({ unpack(items, i, math.min(i + cols - 1, #items)) })
    end
    return out
  end)
  F.vflat = function(args)
    local out = vec({})
    for _, a in ipairs(args) do
      flat(a, out)
    end
    return out
  end
  local function abs(x)
    return F.abs({ x })
  end
  local function max(a, b)
    return F.max({ a, b })
  end
  local function vnorm(v, rows)
    -- rnorm of a vector: the largest |x|; cnorm: the sum of the |x|
    local r = abs(v[1])
    for i = 2, #v do
      r = rows and max(r, abs(v[i])) or add(r, abs(v[i]))
    end
    return r
  end
  def("rnorm", function(a)
    return nonempty(a) and is_const(a)
  end, function(a)
    if is_matrix(a) then
      local r
      for _, row in ipairs(a) do
        local s = vnorm(row, false)
        r = r and max(r, s) or s
      end
      return r
    end
    return vnorm(a, true)
  end)
  def("cnorm", function(a)
    return nonempty(a) and is_const(a)
  end, function(a)
    if is_matrix(a) then
      return F.rnorm({ transpose(a) })
    end
    return vnorm(a, false)
  end)
  def("find", function(v, _, start)
    return is_vec(v) and (start == nil or fixnum(start))
  end, function(v, x, start)
    for i = start or 1, #v do
      if K.same(v[i], x) or (is_real(v[i]) and is_real(x) and num_cmp(v[i], x) == 0) then
        return i
      end
    end
    return 0
  end)
  def("subvec", function(v, s, e)
    return is_vec(v) and fixnum(s) and (e == nil or fixnum(e))
  end, function(v, s, e)
    local len = #v
    e = e or 0
    if s <= 0 then
      s = len + s + 1
    end
    if e <= 0 then
      e = len + e + 1
    end
    if s > len or e <= s then
      return vec({})
    end
    return vec({ unpack(v, s, math.min(e - 1, len)) })
  end)
  def("mrow", function(m, n)
    return is_vec(m) and fixnum(n) and n >= 1 and n <= #m
  end, function(m, n)
    return m[n]
  end)
  def("mcol", function(m, n)
    return is_matrix(m) and fixnum(n) and n >= 1 and n <= #m[1]
  end, function(m, n)
    local out = vec({})
    for i, row in ipairs(m) do
      out[i] = row[n]
    end
    return out
  end)
  def("getdiag", is_matrix, function(m)
    local out = vec({})
    for i = 1, math.min(#m, #m[1]) do
      out[i] = m[i][i]
    end
    return out
  end)
  def("rsort", is_vec, function(v)
    local s = F.sort({ v })
    return is_vec(s) and F.rev({ s }) or nil
  end)
  def("rdup", is_vec, function(v)
    local s = F.sort({ v })
    if not is_vec(s) then
      return nil
    end
    local out = vec({})
    for _, x in ipairs(s) do
      if #out == 0 or not K.same(out[#out], x) then
        out[#out + 1] = x
      end
    end
    return out
  end)

  -- `abs` of a vector is its length; of a two-vector hypot(a, b)
  local scalar_abs = F.abs
  F.abs = function(args)
    local v = args[1]
    if #args == 1 and is_vec(v) then
      if #v == 0 then
        return v
      elseif #v == 1 then
        return F.abs({ v[1] })
      elseif #v == 2 then
        return F.hypot({ v[1], v[2] })
      end
      local s = 0
      for _, x in ipairs(v) do
        if is_vec(x) then
          return call("abs", args)
        end
        s = add(s, mul(x, x))
      end
      return F.sqrt({ s })
    elseif #args == 1 and K.is_symbolic(v) and K.looks_neg(v) then
      -- abs(-x) is abs(x)
      return call("abs", { neg(v) })
    end
    return scalar_abs(args)
  end

  -- the arithmetic operators as functions, and map/reduce over them
  local OPS = { add = add, sub = sub, mul = mul, div = div, pow = K.pow }
  for name, f in pairs(OPS) do
    F[name] = function(args)
      if #args == 0 then
        return call(name, args)
      end
      local r = args[1]
      for i = 2, #args do
        r = f(r, args[i])
      end
      return r
    end
  end
  F.neg = function(args)
    return #args == 1 and neg(args[1]) or call("neg", args)
  end
  local function fn_of(f)
    if tag(f) == "sym" and F[f.name] then
      return function(...)
        return F[f.name]({ ... })
      end
    end
  end
  F.map = function(args)
    local f = fn_of(args[1])
    local v = args[2]
    if not f or not is_vec(v) then
      return call("map", args)
    end
    local out = vec({})
    for i, x in ipairs(v) do
      if args[3] then
        if not is_vec(args[3]) or #args[3] ~= #v then
          return call("map", args)
        end
        out[i] = f(x, args[3][i])
      else
        out[i] = f(x)
      end
    end
    return out
  end
  F.reduce = function(args)
    local f = fn_of(args[1])
    local v = args[2]
    if not f or not nonempty(v) or #args ~= 2 then
      return call("reduce", args)
    end
    local r = v[1]
    for i = 2, #v do
      r = f(r, v[i])
    end
    return r
  end

  return { mat_mul = mat_mul, mat_div = mat_div, mat_pow = mat_pow, is_matrix = is_matrix }
end
