---@mod org.table.elisp Emacs Lisp table formulas ('(...) in #+TBLFM)
---
--- A small Emacs Lisp interpreter for Org's Lisp formulas, e.g.
--- `$3='(+ $1 $2);N`. The caller substitutes references first (strings by
--- default, bare numbers with N, raw text with L) and strips the leading `'`.
---
--- Values: integers are Lua numbers, Emacs floats are tagged tables (see
--- `M.float`, `M.is_float`, `M.tonumber`) so `3.0` stays a float, strings are
--- Lua strings, `t` is `true`, `nil` is `nil`, lists are arrays with an `n`
--- field (empty list = nil), symbols are interned `{ name = "..." }` tables.
---
--- Special forms: quote function if when unless cond and or let let* progn
---   lambda setq
--- Functions: + - * / % mod 1+ 1- abs max min expt sqrt exp log floor ceiling
---   round truncate float = /= < > <= >= eq eql equal string= string-equal
---   string< string> concat substring length upcase downcase capitalize
---   string-to-number number-to-string format string-trim split-string
---   string-join mapconcat list car cdr nth nthcdr cons append reverse last
---   apply funcall mapcar identity number-sequence not null numberp
---   integerp floatp stringp listp consp symbolp zerop string-prefix-p
---   string-suffix-p symbol-name

local M = {}

local unpack = table.unpack or unpack

-- Values -----------------------------------------------------------------

local Float = {
  __tostring = function(f)
    return M.to_string(f)
  end,
}
local Sym = {}
local Closure = {}
local symbols = {}

function M.float(x)
  return setmetatable({ v = x }, Float)
end

function M.is_float(v)
  return getmetatable(v) == Float
end

--- Unwrap an Emacs number (integer or float) to a plain Lua number.
function M.tonumber(v)
  if type(v) == "number" then
    return v
  elseif getmetatable(v) == Float then
    return v.v
  end
end

local function sym(name)
  local s = symbols[name]
  if not s then
    s = setmetatable({ name = name }, Sym)
    symbols[name] = s
  end
  return s
end

local function is_sym(v)
  return getmetatable(v) == Sym
end

local function list(...)
  local n = select("#", ...)
  if n == 0 then
    return nil
  end
  return { n = n, ... }
end

local function is_list(v)
  return type(v) == "table" and v.n ~= nil and getmetatable(v) == nil
end

local function items(v) -- list -> array, n
  if v == nil then
    return {}, 0
  elseif is_list(v) then
    return v, v.n
  end
  error("wrong-type-argument listp " .. M.to_string(v))
end

local function slice(v, from)
  local t, n = items(v)
  if from > n then
    return (n > 0 and t.dot ~= nil) and t.dot or nil
  end
  local out = { n = n - from + 1, dot = t.dot }
  for i = from, n do
    out[i - from + 1] = t[i]
  end
  return out
end

local function truthy(v)
  return v ~= nil and v ~= false
end

local function bool(b)
  return b and true or nil
end

-- Reader -----------------------------------------------------------------

local escapes = { n = "\n", t = "\t", r = "\r", e = "\27", a = "\7", f = "\f", ["0"] = "\0" }

local function read_all(src)
  local pos, len = 1, #src
  local read

  local function skip()
    while pos <= len do
      local c = src:sub(pos, pos)
      if c:match("%s") then
        pos = pos + 1
      elseif c == ";" then
        pos = (src:find("\n", pos, true) or len) + 1
      else
        break
      end
    end
  end

  local function atom(tok)
    local n = tonumber(tok)
    if n and tok:match("^[+-]?%.?%d") and not tok:match("^[+-]?0[xX]") then
      if tok:match("^[+-]?%d+%.?$") then
        return n
      end
      return M.float(n)
    elseif tok == "nil" then
      return nil
    elseif tok == "t" then
      return true
    end
    return sym((tok:gsub("\\(.)", "%1")))
  end

  function read()
    skip()
    if pos > len then
      error("end-of-file during parsing")
    end
    local c = src:sub(pos, pos)
    if c == "(" then
      pos = pos + 1
      local out, n = {}, 0
      while true do
        skip()
        local d = src:sub(pos, pos)
        if d == "" then
          error("end-of-file during parsing")
        elseif d == ")" then
          pos = pos + 1
          break
        elseif d == "." and src:sub(pos + 1, pos + 1):match("[%s()]") then
          pos = pos + 1
          out.dot = read()
          skip()
          if src:sub(pos, pos) ~= ")" then
            error("invalid read syntax: .")
          end
          pos = pos + 1
          break
        end
        n = n + 1
        out[n] = read()
      end
      if n == 0 then
        return nil
      end
      out.n = n
      return out
    elseif c == ")" then
      error("invalid read syntax: )")
    elseif c == "'" then
      pos = pos + 1
      return list(sym("quote"), read())
    elseif c == "#" and src:sub(pos + 1, pos + 1) == "'" then
      pos = pos + 2
      return list(sym("function"), read())
    elseif c == '"' then
      local buf = {}
      pos = pos + 1
      while true do
        local d = src:sub(pos, pos)
        if d == "" then
          error("end-of-file during parsing")
        elseif d == '"' then
          pos = pos + 1
          break
        elseif d == "\\" then
          local e = src:sub(pos + 1, pos + 1)
          if e ~= "\n" then
            buf[#buf + 1] = escapes[e] or e
          end
          pos = pos + 2
        else
          buf[#buf + 1] = d
          pos = pos + 1
        end
      end
      return table.concat(buf)
    elseif c == "?" then
      local e = src:sub(pos + 1, pos + 1)
      if e == "\\" then
        local x = src:sub(pos + 2, pos + 2)
        pos = pos + 3
        return (escapes[x] or x):byte()
      end
      local ch = src:match("^[%z\1-\127\194-\244][\128-\191]*", pos + 1)
      pos = pos + 1 + #ch
      return vim.fn.char2nr(ch)
    end
    local s, e = src:find("^[^%s()\"';]+", pos)
    local tok = src:sub(s, e)
    -- allow backslash-escaped characters inside symbols
    while src:sub(e, e) == "\\" and e < len do
      local s2, e2 = src:find("^[^%s()\"';]*", e + 2)
      tok = tok .. src:sub(e + 1, e2)
      e = e2
    end
    pos = e + 1
    return atom(tok)
  end

  local forms = {}
  skip()
  while pos <= len do
    forms[#forms + 1] = { read() }
    skip()
  end
  return forms
end

-- Printer ----------------------------------------------------------------

local function float_str(x)
  if x ~= x then
    return x < 0 and "-0.0e+NaN" or "0.0e+NaN"
  elseif x == math.huge then
    return "1.0e+INF"
  elseif x == -math.huge then
    return "-1.0e+INF"
  end
  local s
  for p = 15, 17 do -- dtoastr starts at DBL_DIG
    s = string.format("%." .. p .. "g", x)
    if tonumber(s) == x then
      break
    end
  end
  if not s:find("[.e]") then
    s = s .. ".0"
  end
  return s
end

local function int_str(x)
  if x == math.floor(x) and math.abs(x) < 2 ^ 63 then
    return string.format("%d", x)
  end
  return float_str(x)
end

local function print_value(v, escape, top)
  if v == nil or v == false then
    return top and "" or "nil"
  elseif v == true then
    return "t"
  elseif type(v) == "number" then
    return int_str(v)
  elseif type(v) == "string" then
    if escape then
      return '"' .. v:gsub('[\\"]', "\\%0") .. '"'
    end
    return v
  elseif type(v) == "function" then
    return "#<subr>"
  end
  local mt = getmetatable(v)
  if mt == Float then
    return float_str(v.v)
  elseif mt == Sym then
    return v.name
  elseif mt == Closure then
    return "#<lambda>"
  end
  if v[1] == sym("quote") and v.n == 2 and v.dot == nil then
    return "'" .. print_value(v[2], escape)
  end
  local parts = {}
  for i = 1, v.n do
    parts[i] = print_value(v[i], escape)
  end
  if v.dot ~= nil then
    parts[#parts + 1] = ". " .. print_value(v.dot, escape)
  end
  return "(" .. table.concat(parts, " ") .. ")"
end

--- Render a value the way Org inserts it into a cell (`format "%s"`):
--- strings without quotes, integers without decimals, floats like Emacs
--- (`3.0`, `2.5`), nil as "", t as "t", lists as `(1 2 3)`.
function M.to_string(v)
  return print_value(v, false, true)
end

-- Numbers ----------------------------------------------------------------

local function num(v)
  if type(v) == "number" then
    return v, false
  elseif getmetatable(v) == Float then
    return v.v, true
  end
  error("wrong-type-argument number-or-marker-p " .. print_value(v, true))
end

local function mknum(x, fl)
  if fl then
    return M.float(x)
  end
  return x
end

local function int_arg(v)
  local x, fl = num(v)
  if fl then
    error("wrong-type-argument integerp " .. float_str(x))
  end
  return x
end

local function trunc(x)
  return x >= 0 and math.floor(x) or math.ceil(x)
end

local function arith(init, op, unary)
  return function(...)
    local args = { ... }
    local n = select("#", ...)
    if n == 0 then
      return init
    end
    local acc, fl = num(args[1])
    if n == 1 and unary then
      return mknum(unary(acc, fl), fl)
    end
    for i = 2, n do
      local x, f = num(args[i])
      fl = fl or f
      acc = op(acc, x, fl)
    end
    return mknum(acc, fl)
  end
end

local function compare(op)
  return function(...)
    local args = { ... }
    for i = 1, select("#", ...) - 1 do
      if not op(num(args[i]), (num(args[i + 1]))) then
        return nil
      end
    end
    return true
  end
end

local function round_even(x)
  local f = math.floor(x)
  local d = x - f
  if d > 0.5 or (d == 0.5 and f % 2 == 1) then
    return f + 1
  end
  return f
end

local function rounder(fn)
  return function(v, d)
    local x = num(v)
    if d ~= nil then
      local y, fl = num(d)
      if y == 0 and not fl and not M.is_float(v) then
        error("arith-error")
      end
      x = x / y
    end
    return fn(x)
  end
end

-- Strings ----------------------------------------------------------------

local function str(v)
  if type(v) == "string" then
    return v
  elseif is_sym(v) then
    return v.name
  elseif v == nil then
    return "nil"
  end
  error("wrong-type-argument stringp " .. print_value(v, true))
end

local function chars(s)
  local out = {}
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    out[#out + 1] = ch
  end
  return out
end

local function seq_items(v) -- list or string -> array, n
  if type(v) == "string" then
    local out = {}
    for i, ch in ipairs(chars(v)) do
      out[i] = vim.fn.char2nr(ch)
    end
    return out, #out
  end
  return items(v)
end

local classes = {
  space = "%s",
  digit = "%d",
  alpha = "%a",
  alnum = "%w",
  upper = "%u",
  lower = "%l",
  punct = "%p",
  blank = " \t",
}

--- Translate a simple Emacs regexp into a Lua pattern.
local function regex_to_pattern(re)
  local out, i, inset = {}, 1, false
  while i <= #re do
    local c = re:sub(i, i)
    if inset then
      local cls = re:match("^%[:(%a+):%]", i)
      if cls then
        out[#out + 1] = classes[cls] or error("unsupported regexp class " .. cls)
        i = i + #cls + 4
      else
        if c == "]" and re:sub(i - 1, i - 1) ~= "[" and re:sub(i - 2, i - 1) ~= "[^" then
          inset = false
          out[#out + 1] = c
        elseif c == "%" then
          out[#out + 1] = "%%"
        else
          out[#out + 1] = c
        end
        i = i + 1
      end
    elseif c == "[" then
      inset = true
      out[#out + 1] = c
      i = i + 1
    elseif c == "\\" then
      local e = re:sub(i + 1, i + 1)
      if e:match("[|(){}0-9]") then
        error("unsupported regexp: " .. re)
      end
      out[#out + 1] = (e:match("%w") and e or "%" .. e)
      i = i + 2
    elseif c:match("[.*+?^$]") then
      out[#out + 1] = c
      i = i + 1
    else
      out[#out + 1] = c:match("%w") and c or "%" .. c
      i = i + 1
    end
  end
  return table.concat(out)
end

local function format_directive(spec, flags, width, prec, conv, v)
  if conv == "s" or conv == "S" then
    local s = print_value(v, conv == "S")
    if prec ~= "" then
      s = s:sub(1, tonumber(prec:sub(2)))
    end
    return string.format("%" .. flags .. width .. "s", s)
  elseif conv == "c" then
    return vim.fn.nr2char(int_arg(v))
  end
  local x = num(v)
  if conv == "d" or conv == "x" or conv == "X" or conv == "o" then
    return string.format(spec:gsub("%.%d*", ""), trunc(x))
  end
  return string.format(spec, x)
end

local function format(fmt, ...)
  local args, n, i = { ... }, select("#", ...), 0
  return (
    str(fmt):gsub("%%([-+ #0]*)(%d*)(%.?%d*)([%%sSdfegcxXo])", function(flags, width, prec, conv)
      if conv == "%" then
        return "%"
      end
      i = i + 1
      if i > n then
        error("Not enough arguments for format string")
      end
      return format_directive("%" .. flags .. width .. prec .. conv, flags, width, prec, conv, args[i])
    end)
  )
end

local function string_to_number(s, base)
  s = str(s):gsub("^%s+", "")
  if base ~= nil and base ~= 10 then
    local digits = s:match("^[+-]?%w+") or ""
    return tonumber(digits, int_arg(base)) or 0
  end
  local f = s:match("^[+-]?%d*%.%d+[eE][+-]?%d+")
    or s:match("^[+-]?%d+[eE][+-]?%d+")
    or s:match("^[+-]?%d*%.%d+")
  if f then
    return M.float(tonumber(f))
  end
  local n = s:match("^[+-]?%d+")
  return n and tonumber(n) or 0
end

-- Evaluator --------------------------------------------------------------

local NIL = {} -- marks a variable bound to nil
local F = {} -- builtin functions
local S = {} -- special forms
local eval, call

local function lookup(env, name)
  while env do
    local v = env.vars[name]
    if v ~= nil then
      if v == NIL then
        return nil
      end
      return v
    end
    env = env.parent
  end
  error("void-variable " .. name)
end

local function new_env(parent)
  return { vars = {}, parent = parent }
end

local function bind(env, name, v)
  env.vars[name] = v == nil and NIL or v
end

local function progn(body, from, env)
  local t, n = items(body)
  local res
  for i = from, n do
    res = eval(t[i], env)
  end
  return res
end

local function make_closure(params, body_list, from, env)
  return setmetatable({ params = params, body = body_list, from = from, env = env }, Closure)
end

function eval(x, env)
  if is_sym(x) then
    if x.name:sub(1, 1) == ":" then
      return x
    end
    return lookup(env, x.name)
  elseif not is_list(x) then
    return x
  end
  local head = x[1]
  if is_sym(head) then
    local special = S[head.name]
    if special then
      return special(x, env)
    end
  end
  local f
  if is_sym(head) then
    f = F[head.name] or error("void-function " .. head.name)
  elseif is_list(head) and head[1] == sym("lambda") then
    f = eval(head, env)
  else
    error("invalid-function " .. print_value(head, true))
  end
  local args = {}
  for i = 2, x.n do
    args[i - 1] = eval(x[i], env)
  end
  return call(f, args, x.n - 1)
end

--- Call a function designator (symbol, closure, lambda list, builtin).
function call(f, args, n)
  n = n or #args
  if type(f) == "function" then
    return f(unpack(args, 1, n))
  elseif is_sym(f) then
    local fn = F[f.name] or error("void-function " .. f.name)
    return fn(unpack(args, 1, n))
  elseif is_list(f) and f[1] == sym("lambda") then
    return call(eval(f, new_env(nil)), args, n)
  elseif getmetatable(f) == Closure then
    local env = new_env(f.env)
    local params, pn = items(f.params)
    local i, mode = 1, nil
    for k = 1, pn do
      local p = params[k].name
      if p == "&optional" or p == "&rest" then
        mode = p
      elseif mode == "&rest" then
        bind(env, p, n >= i and { n = n - i + 1, unpack(args, i, n) } or nil)
        i = n + 1
      else
        if i > n and mode ~= "&optional" then
          error("wrong-number-of-arguments")
        end
        bind(env, p, args[i])
        i = i + 1
      end
    end
    if i <= n then
      error("wrong-number-of-arguments")
    end
    return progn(f.body, f.from, env)
  end
  error("invalid-function " .. print_value(f, true))
end

S.quote = function(x)
  return x[2]
end
S["function"] = function(x, env)
  local v = x[2]
  if is_list(v) and v[1] == sym("lambda") then
    return eval(v, env)
  end
  return v
end
S.lambda = function(x, env)
  return make_closure(x[2], x, 3, env)
end
S.progn = function(x, env)
  return progn(x, 2, env)
end
S["if"] = function(x, env)
  if truthy(eval(x[2], env)) then
    return eval(x[3], env)
  end
  return progn(x, 4, env)
end
S.when = function(x, env)
  if truthy(eval(x[2], env)) then
    return progn(x, 3, env)
  end
end
S.unless = function(x, env)
  if not truthy(eval(x[2], env)) then
    return progn(x, 3, env)
  end
end
S.cond = function(x, env)
  for i = 2, x.n do
    local clause = x[i]
    local test = eval(clause[1], env)
    if truthy(test) then
      if clause.n == 1 then
        return test
      end
      return progn(clause, 2, env)
    end
  end
end
S["and"] = function(x, env)
  local res = true
  for i = 2, x.n do
    res = eval(x[i], env)
    if not truthy(res) then
      return nil
    end
  end
  return res
end
S["or"] = function(x, env)
  for i = 2, x.n do
    local res = eval(x[i], env)
    if truthy(res) then
      return res
    end
  end
end
local function let(sequential)
  return function(x, env)
    local inner = new_env(env)
    local bindings, n = items(x[2])
    for i = 1, n do
      local b = bindings[i]
      if is_sym(b) then
        bind(inner, b.name, nil)
      else
        bind(inner, b[1].name, eval(b[2], sequential and inner or env))
      end
    end
    return progn(x, 3, inner)
  end
end
S.let = let(false)
S["let*"] = let(true)
S.setq = function(x, env)
  local v
  for i = 2, x.n, 2 do
    v = eval(x[i + 1], env)
    local name, e = x[i].name, env
    while e.parent and e.vars[name] == nil do
      e = e.parent
    end
    bind(e, name, v)
  end
  return v
end
-- (org-sbe "block" [header] (var value)...): a src block's result (ob-table)
S["org-sbe"] = function(x)
  return require("org.babel").sbe_form(x)
end

-- Builtins ---------------------------------------------------------------

F["+"] = arith(0, function(a, b)
  return a + b
end)
F["*"] = arith(1, function(a, b)
  return a * b
end)
F["-"] = arith(0, function(a, b)
  return a - b
end, function(a)
  return -a
end)
F["/"] = arith(nil, function(a, b, fl)
  if fl then
    return a / b
  elseif b == 0 then
    error("arith-error")
  end
  return trunc(a / b)
end, function(a, fl)
  if fl then
    return 1 / a
  elseif a == 0 then
    error("arith-error")
  end
  return trunc(1 / a)
end)
F["%"] = function(a, b)
  a, b = int_arg(a), int_arg(b)
  if b == 0 then
    error("arith-error")
  end
  return math.fmod(a, b)
end
F.mod = function(a, b)
  local x, f1 = num(a)
  local y, f2 = num(b)
  if y == 0 and not (f1 or f2) then
    error("arith-error")
  end
  return mknum(x - math.floor(x / y) * y, f1 or f2)
end
F["1+"] = function(a)
  local x, fl = num(a)
  return mknum(x + 1, fl)
end
F["1-"] = function(a)
  local x, fl = num(a)
  return mknum(x - 1, fl)
end
F.abs = function(a)
  local x, fl = num(a)
  return mknum(math.abs(x), fl)
end
local function extremum(better)
  return function(...)
    local args = { ... }
    local best, fl = num(args[1])
    for i = 2, select("#", ...) do
      local x, f = num(args[i])
      fl = fl or f
      if better(x, best) then
        best = x
      end
    end
    return mknum(best, fl)
  end
end
F.max = extremum(function(a, b)
  return a > b
end)
F.min = extremum(function(a, b)
  return a < b
end)
F.expt = function(a, b)
  local x, f1 = num(a)
  local y, f2 = num(b)
  return mknum(x ^ y, f1 or f2 or y < 0)
end
F.sqrt = function(a)
  return M.float(math.sqrt((num(a))))
end
F.exp = function(a)
  return M.float(math.exp((num(a))))
end
F.log = function(a, base)
  local r = math.log((num(a)))
  if base ~= nil then
    r = r / math.log((num(base)))
  end
  return M.float(r)
end
F.float = function(a)
  return M.float((num(a)))
end
F.floor = rounder(math.floor)
F.ceiling = rounder(math.ceil)
F.truncate = rounder(trunc)
F.round = rounder(round_even)
F["="] = compare(function(a, b)
  return a == b
end)
F["<"] = compare(function(a, b)
  return a < b
end)
F[">"] = compare(function(a, b)
  return a > b
end)
F["<="] = compare(function(a, b)
  return a <= b
end)
F[">="] = compare(function(a, b)
  return a >= b
end)
F["/="] = function(a, b)
  return bool(num(a) ~= num(b))
end

local function eql(a, b)
  if M.is_float(a) and M.is_float(b) then
    return a.v == b.v
  end
  return rawequal(a, b)
end
local function equal(a, b)
  if eql(a, b) then
    return true
  elseif type(a) == "string" and type(b) == "string" then
    return a == b
  elseif is_list(a) and is_list(b) and a.n == b.n then
    for i = 1, a.n do
      if not equal(a[i], b[i]) then
        return false
      end
    end
    return equal(a.dot, b.dot)
  end
  return false
end
F.eq = function(a, b)
  return bool(eql(a, b))
end
F.eql = F.eq
F.equal = function(a, b)
  return bool(equal(a, b))
end
F["string="] = function(a, b)
  return bool(str(a) == str(b))
end
F["string-equal"] = F["string="]
F["string<"] = function(a, b)
  return bool(str(a) < str(b))
end
F["string-lessp"] = F["string<"]
F["string>"] = function(a, b)
  return bool(str(a) > str(b))
end
F["string-prefix-p"] = function(p, s)
  return bool(vim.startswith(str(s), str(p)))
end
F["string-suffix-p"] = function(p, s)
  return bool(vim.endswith(str(s), str(p)))
end

F.concat = function(...)
  local args, out = { ... }, {}
  for i = 1, select("#", ...) do
    local v = args[i]
    if type(v) == "string" then
      out[#out + 1] = v
    else
      local t, n = items(v)
      for k = 1, n do
        out[#out + 1] = vim.fn.nr2char(int_arg(t[k]))
      end
    end
  end
  return table.concat(out)
end
F.substring = function(s, from, to)
  local cs = chars(str(s))
  local n = #cs
  local a = from == nil and 0 or int_arg(from)
  local b = to == nil and n or int_arg(to)
  a, b = a < 0 and n + a or a, b < 0 and n + b or b
  if a < 0 or b > n or a > b then
    error("args-out-of-range")
  end
  return table.concat(cs, "", a + 1, b)
end
F.length = function(v)
  if type(v) == "string" then
    return #chars(v)
  end
  local _, n = items(v)
  return n
end
F.upcase = function(v)
  if type(v) == "number" then
    return vim.fn.char2nr(vim.fn.toupper(vim.fn.nr2char(v)))
  end
  return vim.fn.toupper(str(v))
end
F.downcase = function(v)
  if type(v) == "number" then
    return vim.fn.char2nr(vim.fn.tolower(vim.fn.nr2char(v)))
  end
  return vim.fn.tolower(str(v))
end
F.capitalize = function(v)
  return (
    vim.fn.tolower(str(v)):gsub("(%w)(%w*)", function(a, b)
      return a:upper() .. b
    end)
  )
end
F["string-to-number"] = string_to_number
F["number-to-string"] = function(v)
  num(v)
  return print_value(v)
end
F.format = format
F["format-message"] = format
F["string-trim"] = function(s)
  return vim.trim(str(s))
end
F["split-string"] = function(s, sep, omit)
  s = str(s)
  local pat = sep == nil and "%s+" or regex_to_pattern(str(sep))
  if sep == nil then
    omit = true
  end
  local out, pos = {}, 1
  while true do
    local a, b = s:find(pat, pos)
    if a and b < a then -- empty match: advance one character
      a, b = s:find(pat, pos + 1)
    end
    if not a then
      out[#out + 1] = s:sub(pos)
      break
    end
    out[#out + 1] = s:sub(pos, a - 1)
    pos = b + 1
  end
  local res = {}
  for _, p in ipairs(out) do
    if not (truthy(omit) and p == "") then
      res[#res + 1] = p
    end
  end
  return list(unpack(res))
end
F["string-join"] = function(l, sep)
  local t, n = items(l)
  local parts = {}
  for i = 1, n do
    parts[i] = str(t[i])
  end
  return table.concat(parts, sep == nil and "" or str(sep))
end
F.mapconcat = function(f, seq, sep)
  local t, n = seq_items(seq)
  local parts = {}
  for i = 1, n do
    parts[i] = F.concat(call(f, { t[i] }, 1))
  end
  return table.concat(parts, sep == nil and "" or str(sep))
end
F["symbol-name"] = function(s)
  return str(s)
end

F.list = list
F.car = function(l)
  local t = items(l)
  return t[1]
end
F.cdr = function(l)
  return slice(l, 2)
end
F.nth = function(k, l)
  local t, n = items(l)
  k = int_arg(k)
  return k < n and t[k + 1] or nil
end
F.nthcdr = function(k, l)
  return slice(l, int_arg(k) + 1)
end
F.last = function(l)
  local _, n = items(l)
  return slice(l, math.max(n, 1))
end
F.cons = function(a, l)
  if l == nil or is_list(l) then
    local t, n = items(l)
    return { n = n + 1, dot = t.dot, a, unpack(t, 1, n) }
  end
  return { n = 1, dot = l, a }
end
F.append = function(...)
  local args, out, n = { ... }, {}, select("#", ...)
  for i = 1, n - 1 do
    local t, m = seq_items(args[i])
    for k = 1, m do
      out[#out + 1] = t[k]
    end
  end
  local tail = args[n]
  if #out == 0 then
    return tail
  end
  local t, m = items(tail == nil and nil or (is_list(tail) and tail or list()))
  for k = 1, m do
    out[#out + 1] = t[k]
  end
  out.n = #out
  if tail ~= nil and not is_list(tail) then
    out.dot = tail
  end
  return out
end
F.reverse = function(v)
  if type(v) == "string" then
    return table.concat(vim.fn.reverse(chars(v)))
  end
  local t, n = items(v)
  local out = { n = n }
  for i = 1, n do
    out[i] = t[n - i + 1]
  end
  return n > 0 and out or nil
end
F.nreverse = F.reverse
F["number-sequence"] = function(from, to, step)
  local a, fl = num(from)
  if to == nil then
    return list(from)
  end
  local b, f2 = num(to)
  local s, f3 = 1, false
  if step ~= nil then
    s, f3 = num(step)
  end
  fl = fl or f2 or f3
  local out = {}
  for x = a, b, s do
    out[#out + 1] = mknum(x, fl)
  end
  return list(unpack(out))
end
F.identity = function(v)
  return v
end
F.funcall = function(f, ...)
  return call(f, { ... }, select("#", ...))
end
F.apply = function(f, ...)
  local args, n = { ... }, select("#", ...)
  local all = {}
  for i = 1, n - 1 do
    all[i] = args[i]
  end
  local t, m = items(args[n])
  for k = 1, m do
    all[n - 1 + k] = t[k]
  end
  return call(f, all, n - 1 + m)
end
F.mapcar = function(f, seq)
  local t, n = seq_items(seq)
  local out = { n = n }
  for i = 1, n do
    out[i] = call(f, { t[i] }, 1)
  end
  return n > 0 and out or nil
end
F.mapc = function(f, seq)
  F.mapcar(f, seq)
  return seq
end

F["not"] = function(v)
  return bool(not truthy(v))
end
F.null = F["not"]
F.numberp = function(v)
  return bool(M.tonumber(v) ~= nil)
end
F["number?"] = F.numberp
F.integerp = function(v)
  return bool(type(v) == "number")
end
F.floatp = function(v)
  return bool(M.is_float(v))
end
F.stringp = function(v)
  return bool(type(v) == "string")
end
F.listp = function(v)
  return bool(v == nil or is_list(v))
end
F.consp = function(v)
  return bool(is_list(v))
end
F.symbolp = function(v)
  return bool(is_sym(v) or v == nil or v == true)
end
F.zerop = function(v)
  return bool(num(v) == 0)
end

-- Public API -------------------------------------------------------------

--- True if `src` looks like an Emacs Lisp call this module implements, as
--- opposed to a parenthesised Lua expression such as `(string.upper(x))`.
function M.looks_like(src)
  if type(src) ~= "string" then
    return false
  end
  local head, after = src:match("^%s*%(%s*([^%s()\"';]+)(.?)")
  if not head or not (after == "" or after == ")" or after:match("%s")) then
    return false
  end
  return F[head] ~= nil or S[head] ~= nil
end

--- Read and evaluate `src` (one or more forms; the last value is returned).
--- Raises a Lua error on read or evaluation failure.
function M.eval(src)
  local forms = read_all(src)
  if #forms == 0 then
    error("end-of-file during parsing")
  end
  local env, res = new_env(nil), nil
  for _, f in ipairs(forms) do
    res = eval(f[1], env)
  end
  return res
end

--- Evaluate `src` and render the result as Org would insert it.
function M.eval_to_string(src)
  return M.to_string(M.eval(src))
end

M.functions = F
M.special_forms = S

return M
