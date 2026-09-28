---@mod org.agenda.sexp Diary sexp entries (a Lua emulation of the common ones)
---
--- Org can put Emacs diary s-expressions in timestamps (`<%%(diary-float t 4 2)>`)
--- and on lines of their own (`%%(org-anniversary 1990 5 17) Birthday %d`).
--- Emacs evaluates them as Elisp. This module reads them with a small, safe
--- s-expression reader and evaluates the common calendar functions in Lua:
---
---   org-anniversary Y M D     diary-anniversary M D [Y]
---   org-cyclic N Y M D        diary-cyclic N M D Y
---   org-block Y1 M1 D1 Y2 M2 D2    diary-block M1 D1 Y1 M2 D2 Y2
---   org-date Y M D            diary-date M D Y     (t = any, lists allowed)
---   diary-float MONTH DAYNAME N [DAY]
---   org-class Y1 M1 D1 Y2 M2 D2 DAYNAME [SKIP-WEEKS...]
---   org-calendar-holiday      (the holidays of `agenda.holidays`)
---   diary-remind SEXP DAYS [MARKING]   diary-offset SEXP DAYS
---   diary-hebrew-date, diary-iso-date, ... (the date in other calendars)
---   diary-day-of-year
---   and, or, not, list, quote
---
--- around a side-effect-free subset of Elisp: if/when/unless/cond/let/
--- let*/progn, comparisons, arithmetic, list and string functions and the
--- calendar.el date helpers, with `date` bound to (MONTH DAY YEAR) and
--- `entry` to the entry text. There are no loops, lambdas or assignments,
--- so every sexp terminates and has no side effects.
---
--- The `diary-*` functions use Emacs's default `calendar-date-style`
--- (american: month day year); the `org-*` wrappers use ISO order (year month
--- day), exactly like Emacs. Anything else (other Elisp, the anniversaries
--- of other calendars, ...) is reported as an error so the caller can skip
--- the entry.

local date = require("org.date")

local M = {}

local NIL = false

---------------------------------------------------------------------------
-- Reader
---------------------------------------------------------------------------

--- Tokenize and read one s-expression. Nodes:
---   number, string, { sym = "name" }, { list = { ... } }
local function read(str)
  local pos = 1
  local n = #str

  local function skip_ws()
    while pos <= n do
      local c = str:sub(pos, pos)
      if c:match("%s") then
        pos = pos + 1
      elseif c == ";" then
        -- comment to end of line
        local e = str:find("\n", pos, true)
        pos = e and e + 1 or n + 1
      else
        break
      end
    end
  end

  local read_form

  function read_form()
    skip_ws()
    if pos > n then
      error("end of input", 0)
    end
    local c = str:sub(pos, pos)
    if c == "(" then
      pos = pos + 1
      local items = {}
      while true do
        skip_ws()
        if pos > n then
          error("unbalanced parentheses", 0)
        end
        if str:sub(pos, pos) == ")" then
          pos = pos + 1
          break
        end
        items[#items + 1] = read_form()
      end
      return { list = items }
    elseif c == ")" then
      error("unexpected )", 0)
    elseif c == "'" then
      pos = pos + 1
      return { list = { { sym = "quote" }, read_form() } }
    elseif c == '"' then
      local buf = {}
      pos = pos + 1
      while true do
        if pos > n then
          error("unterminated string", 0)
        end
        local ch = str:sub(pos, pos)
        if ch == "\\" then
          local nx = str:sub(pos + 1, pos + 1)
          buf[#buf + 1] = nx == "n" and "\n" or nx == "t" and "\t" or nx
          pos = pos + 2
        elseif ch == '"' then
          pos = pos + 1
          break
        else
          buf[#buf + 1] = ch
          pos = pos + 1
        end
      end
      return table.concat(buf)
    else
      local tok = str:match("^[^%s%(%)'\";]+", pos)
      pos = pos + #tok
      local num = tok:match("^[%+%-]?%d+%.?$") and tonumber((tok:gsub("%.$", "")))
        or tok:match("^[%+%-]?%d*%.%d+$") and tonumber(tok)
      if num then
        return num
      end
      if tok:sub(1, 1) == "?" then
        error("character literals are not supported", 0)
      end
      return { sym = tok }
    end
  end

  local form = read_form()
  skip_ws()
  if pos <= n then
    error("trailing text after sexp", 0)
  end
  return form
end

--- Parse a sexp string such as "(diary-float t 4 2)".
---@param str string
---@return table|nil node, string|nil err
function M.parse(str)
  local ok, res = pcall(read, str or "")
  if not ok then
    return nil, tostring(res)
  end
  return res
end

---------------------------------------------------------------------------
-- Calendar helpers (Emacs calendar.el semantics on org.date day numbers)
---------------------------------------------------------------------------

local function abs_date(m, d, y)
  if type(m) ~= "number" or type(d) ~= "number" or type(y) ~= "number" then
    error("wrong-type-argument: date parts must be integers", 0)
  end
  -- like calendar-absolute-from-gregorian: the day of month is linear
  return date.days_from_civil(y, m, 1) + d - 1
end

local function mdy(day)
  local y, m, d = date.civil_from_days(day)
  return m, d, y
end

--- 0 = Sunday ... 6 = Saturday (calendar-day-of-week)
local function dow(day)
  return (day + 4) % 7
end

--- calendar-dayname-on-or-before
local function dayname_on_or_before(dayname, day)
  return day - ((dow(day) - dayname) % 7)
end

--- calendar-nth-named-absday
local function nth_named_absday(n, dayname, month, year, day)
  if n > 0 then
    return 7 * (n - 1) + dayname_on_or_before(dayname, 6 + abs_date(month, day or 1, year))
  end
  return 7 * (n + 1)
    + dayname_on_or_before(dayname, abs_date(month, day or date.days_in_month(year, month), year))
end

local function iso_week(day)
  local thu = day - ((dow(day) + 6) % 7) + 3
  local y = date.civil_from_days(thu)
  return math.floor((thu - date.days_from_civil(y, 1, 1)) / 7) + 1
end

--- diary-ordinal-suffix
function M.ordinal_suffix(n)
  local r100 = math.fmod(n, 100)
  local r10 = math.fmod(n, 10)
  if r100 == 11 or r100 == 12 or r100 == 13 or r10 > 3 then
    return "th"
  end
  return ({ [0] = "th", "st", "nd", "rd" })[r10] or error("args-out-of-range", 0)
end

--- Emacs `format` with the %d / %s / %% specs used by diary entries.
local function format_entry(fmt, ...)
  local args = { ... }
  local i = 0
  local out = fmt:gsub("%%([%-0 ]?%d*)([%a%%])", function(flags, spec)
    if spec == "%" then
      return "%"
    end
    i = i + 1
    local a = args[i]
    if a == nil then
      error("Not enough arguments for format string", 0)
    end
    if spec == "d" then
      if type(a) ~= "number" then
        error("Format specifier doesn't match argument type", 0)
      end
      return string.format("%" .. flags .. "d", a)
    elseif spec == "s" then
      return string.format("%" .. flags .. "s", tostring(a))
    end
    error("Invalid format operation %" .. spec, 0)
  end)
  return out
end

---------------------------------------------------------------------------
-- Functions
---------------------------------------------------------------------------

local function cons(entry)
  return { cons = true, cdr = entry }
end

local function is_list(v)
  return type(v) == "table" and v.items ~= nil
end

--- `(or (and (listp x) (memq v x)) (equal v x) (eq x t))`
local function matches(v, x)
  if x == true then
    return true
  elseif x == NIL or x == nil then
    return false -- nil is the empty list
  elseif is_list(x) then
    return vim.tbl_contains(x.items, v)
  end
  return v == x
end

--- diary-make-date: order depends on calendar-date-style.
local function make_date(style, a, b, c)
  if style == "iso" then
    return b, c, a
  end
  return a, b, c
end

local function fn_date(ctx, style, a, b, c)
  local mm, dd, yy = make_date(style, a, b, c)
  local m, d, y = mdy(ctx.day)
  if matches(d, dd) and matches(m, mm) and matches(y, yy) then
    return cons(ctx.entry)
  end
  return NIL
end

local function fn_block(ctx, style, a1, b1, c1, a2, b2, c2)
  local d1 = abs_date(make_date(style, a1, b1, c1))
  local d2 = abs_date(make_date(style, a2, b2, c2))
  if d1 <= ctx.day and ctx.day <= d2 then
    return cons(ctx.entry)
  end
  return NIL
end

local function fn_anniversary(ctx, style, a, b, c)
  local mm, dd, yy = make_date(style, a, b, c)
  local _, _, y = mdy(ctx.day)
  if yy == NIL then
    yy = nil
  end
  local diff = yy and (y - yy) or 100
  if mm == 2 and dd == 29 and not date.is_leap(y) then
    mm, dd = 3, 1
  end
  if diff > 0 and abs_date(mm, dd, y) == ctx.day then
    local cm, cd = mdy(ctx.day)
    if cm == mm and cd == dd then
      return cons(format_entry(ctx.entry, diff, M.ordinal_suffix(diff)))
    end
  end
  return NIL
end

local function fn_cyclic(ctx, style, n, a, b, c)
  if type(n) ~= "number" then
    error("wrong-type-argument: cycle must be a number", 0)
  end
  if n <= 0 then
    error("Day count must be positive", 0)
  end
  local diff = ctx.day - abs_date(make_date(style, a, b, c))
  if diff >= 0 and diff % n == 0 then
    local cycle = math.floor(diff / n)
    return cons(format_entry(ctx.entry, cycle, M.ordinal_suffix(cycle)))
  end
  return NIL
end

local function month_ok(month, m)
  if month == true then
    return true
  elseif is_list(month) then
    return vim.tbl_contains(month.items, m)
  elseif month == NIL then
    return false
  end
  return m == month
end

local function fn_float(ctx, month, dayname, n, day)
  if type(dayname) ~= "number" or type(n) ~= "number" then
    error("wrong-type-argument: diary-float needs numeric DAYNAME and N", 0)
  end
  if day == NIL then
    day = nil
  end
  if dayname ~= dow(ctx.day) then
    return NIL
  end
  local m, d, y = mdy(ctx.day)
  local limit = nth_named_absday(-n, dayname, m, y, d)
  local last_abs = n > 0 and limit or limit + 6
  local first_abs = n > 0 and limit - 6 or limit
  local m2, d2, y2 = mdy(last_abs)
  local m1, d1, y1 = mdy(first_abs)
  local function base(mo, yr)
    return day or (n > 0 and 1 or date.days_in_month(yr, mo))
  end
  local ok = (m1 == m2 and month_ok(month, m1) and (function()
    local bd = base(m1, y1)
    return d1 <= bd and bd <= d2
  end)()) or ((y1 < y2 or (y1 == y2 and m1 < m2)) and (
    (month_ok(month, m1) and d1 <= base(m1, y1)) or (month_ok(month, m2) and base(m2, y2) <= d2)
  ))
  if ok then
    return cons(ctx.entry)
  end
  return NIL
end

local function fn_class(ctx, y1, m1, d1, y2, m2, d2, dayname, ...)
  local a = abs_date(m1, d1, y1)
  local b = abs_date(m2, d2, y2)
  local skip = { ... }
  if not (a <= ctx.day and ctx.day <= b and dow(ctx.day) == dayname) then
    return NIL
  end
  if #skip > 0 then
    -- holiday skipping (the `holidays' symbol or holiday names) needs the
    -- Emacs holiday tables: ignored here
    local wk = iso_week(ctx.day)
    for _, w in ipairs(skip) do
      if w == wk then
        return NIL
      end
    end
  end
  return ctx.entry
end

--- Truthiness: only nil (and the empty list) is false in Elisp.
local function truthy(v)
  return v ~= NIL and v ~= nil
end

local function bool(v)
  return v and true or NIL
end

--- A missing value (absent argument, index past the end) is nil.
local function nilify(v)
  if v == nil then
    return NIL
  end
  return v
end

--- The items of a list value (nil is the empty list).
local function items_of(v, fn)
  if v == NIL or v == nil then
    return {}
  elseif is_list(v) then
    return v.items
  end
  error("wrong-type-argument listp " .. vim.inspect(v) .. (fn and (" in " .. fn) or ""), 0)
end

local function list_of(items)
  if #items == 0 then
    return NIL
  end
  return { items = items }
end

local function num(v, fn)
  if type(v) ~= "number" then
    error("wrong-type-argument number-or-marker-p " .. vim.inspect(v) .. " in " .. fn, 0)
  end
  return v
end

--- `eq`/`eql`: numbers, symbols, t and nil by value, other objects by identity.
local function eq(a, b)
  if type(a) == "table" and type(b) == "table" and a.symbol and b.symbol then
    return a.symbol == b.symbol
  elseif type(a) == "string" then
    return false
  elseif (a == NIL or is_list(a) and #a.items == 0) and (b == NIL or is_list(b) and #b.items == 0) then
    return true
  end
  return a == b
end

local function equal(a, b)
  if type(a) == "table" and type(b) == "table" then
    if a.symbol or b.symbol then
      return a.symbol == b.symbol
    end
    local ia, ib = is_list(a) and a.items, is_list(b) and b.items
    if ia and ib then
      if #ia ~= #ib then
        return false
      end
      for i = 1, #ia do
        if not equal(ia[i], ib[i]) then
          return false
        end
      end
      return true
    end
  end
  return eq(a, b) or (type(a) == "string" and a == b)
end

--- The date list (month day year) of an absolute day.
local function date_list(day)
  local m, d, y = mdy(day)
  return { items = { m, d, y } }
end

--- (month day year) -> absolute day.
local function from_date_list(v, fn)
  local it = items_of(v, fn)
  return abs_date(it[1], it[2], it[3])
end

local function compare(fn, op)
  return function(_, ...)
    local args = { ... }
    for i = 1, #args do
      num(args[i], fn)
    end
    for i = 1, #args - 1 do
      if not op(args[i], args[i + 1]) then
        return NIL
      end
    end
    return true
  end
end

local function arith(fn, op, unit, unary)
  return function(_, ...)
    local args = { ... }
    if #args == 0 then
      return unit
    end
    local acc = num(args[1], fn)
    if #args == 1 and unary then
      return unary(acc)
    end
    for i = 2, #args do
      acc = op(acc, num(args[i], fn))
    end
    return acc
  end
end

local function int(v, fn)
  num(v, fn)
  if v ~= math.floor(v) then
    error("wrong-type-argument integerp " .. v .. " in " .. fn, 0)
  end
  return v
end

local function memq(_, x, l)
  local it = items_of(l, "memq")
  for i, v in ipairs(it) do
    if eq(x, v) then
      return list_of(vim.list_slice(it, i))
    end
  end
  return NIL
end

local FUNCS = {
  ["diary-date"] = function(ctx, ...)
    return fn_date(ctx, "american", ...)
  end,
  ["org-date"] = function(ctx, ...)
    return fn_date(ctx, "iso", ...)
  end,
  ["diary-block"] = function(ctx, ...)
    return fn_block(ctx, "american", ...)
  end,
  ["org-block"] = function(ctx, ...)
    return fn_block(ctx, "iso", ...)
  end,
  ["diary-anniversary"] = function(ctx, ...)
    return fn_anniversary(ctx, "american", ...)
  end,
  ["org-anniversary"] = function(ctx, ...)
    return fn_anniversary(ctx, "iso", ...)
  end,
  ["diary-cyclic"] = function(ctx, n, ...)
    return fn_cyclic(ctx, "american", n, ...)
  end,
  ["org-cyclic"] = function(ctx, n, ...)
    return fn_cyclic(ctx, "iso", n, ...)
  end,
  ["diary-float"] = fn_float,
  ["org-class"] = fn_class,
  -- org-calendar-holiday: the calendar-holidays of the day, joined with "; "
  ["org-calendar-holiday"] = function(ctx)
    return require("org.agenda.holidays").org_calendar_holiday(ctx.day) or NIL
  end,

  -- calendar.el helpers on (month day year) lists
  ["calendar-day-of-week"] = function(_, d)
    return dow(from_date_list(d, "calendar-day-of-week"))
  end,
  ["calendar-extract-month"] = function(_, d)
    return items_of(d, "calendar-extract-month")[1]
  end,
  ["calendar-extract-day"] = function(_, d)
    return items_of(d, "calendar-extract-day")[2]
  end,
  ["calendar-extract-year"] = function(_, d)
    return items_of(d, "calendar-extract-year")[3]
  end,
  ["calendar-absolute-from-gregorian"] = function(_, d)
    -- calendar.el counts days from 1 Jan of year 1 (Gregorian) = day 1
    return from_date_list(d, "calendar-absolute-from-gregorian") - date.days_from_civil(1, 1, 1) + 1
  end,
  ["calendar-gregorian-from-absolute"] = function(_, n)
    return date_list(int(n, "calendar-gregorian-from-absolute") + date.days_from_civil(1, 1, 1) - 1)
  end,
  ["calendar-iso-from-absolute"] = function(_, n)
    -- (week day year), day 0 = Sunday
    local day = int(n, "calendar-iso-from-absolute") + date.days_from_civil(1, 1, 1) - 1
    local thu = day - ((dow(day) + 6) % 7) + 3
    return { items = { iso_week(day), dow(day), (date.civil_from_days(thu)) } }
  end,
  ["calendar-leap-year-p"] = function(_, y)
    return bool(date.is_leap(int(y, "calendar-leap-year-p")))
  end,
  ["calendar-last-day-of-month"] = function(_, m, y)
    return date.days_in_month(int(y, "calendar-last-day-of-month"), int(m, "calendar-last-day-of-month"))
  end,
  ["calendar-day-number"] = function(_, d)
    local it = items_of(d, "calendar-day-number")
    return from_date_list(d, "calendar-day-number") - date.days_from_civil(it[3], 1, 1) + 1
  end,
  ["calendar-nth-named-day"] = function(_, n, dayname, month, year, day)
    return date_list(
      nth_named_absday(
        int(n, "calendar-nth-named-day"),
        int(dayname, "calendar-nth-named-day"),
        int(month, "calendar-nth-named-day"),
        int(year, "calendar-nth-named-day"),
        day ~= NIL and day or nil
      )
    )
  end,
  ["calendar-date-equal"] = function(_, a, b)
    return bool(equal(a, b))
  end,
  ["calendar-date-compare"] = function(_, a, b)
    -- (calendar-date-compare DATE1 DATE2): the dates are the cars
    local fn = "calendar-date-compare"
    return bool(from_date_list(items_of(a, fn)[1], fn) < from_date_list(items_of(b, fn)[1], fn))
  end,

  -- predicates and comparisons
  ["not"] = function(_, v)
    return bool(not truthy(v))
  end,
  null = function(_, v)
    return bool(not truthy(v))
  end,
  eq = function(_, a, b)
    return bool(eq(a, b))
  end,
  eql = function(_, a, b)
    return bool(eq(a, b))
  end,
  equal = function(_, a, b)
    return bool(equal(a, b))
  end,
  ["string="] = function(_, a, b)
    return bool(type(a) == "string" and a == b)
  end,
  ["string-equal"] = function(_, a, b)
    return bool(type(a) == "string" and a == b)
  end,
  ["="] = compare("=", function(a, b)
    return a == b
  end),
  ["/="] = compare("/=", function(a, b)
    return a ~= b
  end),
  ["<"] = compare("<", function(a, b)
    return a < b
  end),
  [">"] = compare(">", function(a, b)
    return a > b
  end),
  ["<="] = compare("<=", function(a, b)
    return a <= b
  end),
  [">="] = compare(">=", function(a, b)
    return a >= b
  end),
  zerop = function(_, v)
    return bool(num(v, "zerop") == 0)
  end,
  integerp = function(_, v)
    return bool(type(v) == "number" and v == math.floor(v))
  end,
  numberp = function(_, v)
    return bool(type(v) == "number")
  end,
  stringp = function(_, v)
    return bool(type(v) == "string")
  end,
  listp = function(_, v)
    return bool(v == NIL or is_list(v))
  end,
  consp = function(_, v)
    return bool(is_list(v) and #v.items > 0)
  end,

  -- arithmetic (integer division truncates, like Elisp on integers)
  ["+"] = arith("+", function(a, b)
    return a + b
  end, 0),
  ["-"] = arith(
    "-",
    function(a, b)
      return a - b
    end,
    0,
    function(a)
      return -a
    end
  ),
  ["*"] = arith("*", function(a, b)
    return a * b
  end, 1),
  ["/"] = arith("/", function(a, b)
    if b == 0 then
      error("arith-error", 0)
    end
    local q = a / b
    if a == math.floor(a) and b == math.floor(b) then
      q = q < 0 and math.ceil(q) or math.floor(q)
    end
    return q
  end),
  ["%"] = function(_, a, b)
    if int(b, "%") == 0 then
      error("arith-error", 0)
    end
    return math.fmod(int(a, "%"), b)
  end,
  mod = function(_, a, b)
    if num(b, "mod") == 0 then
      error("arith-error", 0)
    end
    return num(a, "mod") - math.floor(a / b) * b
  end,
  ["1+"] = function(_, v)
    return num(v, "1+") + 1
  end,
  ["1-"] = function(_, v)
    return num(v, "1-") - 1
  end,
  abs = function(_, v)
    return math.abs(num(v, "abs"))
  end,
  max = arith("max", math.max),
  min = arith("min", math.min),

  -- lists
  list = function(_, ...)
    return list_of({ ... })
  end,
  car = function(_, l)
    return nilify(items_of(l, "car")[1])
  end,
  cdr = function(_, l)
    return list_of(vim.list_slice(items_of(l, "cdr"), 2))
  end,
  cadr = function(_, l)
    return nilify(items_of(l, "cadr")[2])
  end,
  nth = function(_, n, l)
    return nilify(items_of(l, "nth")[int(n, "nth") + 1])
  end,
  length = function(_, l)
    if type(l) == "string" then
      return vim.fn.strchars(l)
    end
    return #items_of(l, "length")
  end,
  memq = memq,
  memql = memq,
  member = function(_, x, l)
    local it = items_of(l, "member")
    for i, v in ipairs(it) do
      if equal(x, v) then
        return list_of(vim.list_slice(it, i))
      end
    end
    return NIL
  end,

  -- strings
  concat = function(_, ...)
    local parts = {}
    for i, v in ipairs({ ... }) do
      parts[i] = type(v) == "string" and v or error("wrong-type-argument sequencep in concat", 0)
    end
    return table.concat(parts)
  end,
  format = function(_, fmt, ...)
    if type(fmt) ~= "string" then
      error("wrong-type-argument stringp in format", 0)
    end
    return format_entry(fmt, ...)
  end,
  ["number-to-string"] = function(_, v)
    return tostring(num(v, "number-to-string"))
  end,
}

--- Convert a quoted form to a value.
local function quoted(node)
  if type(node) ~= "table" then
    return node
  elseif node.sym then
    if node.sym == "t" then
      return true
    elseif node.sym == "nil" then
      return NIL
    end
    return { symbol = node.sym }
  end
  local items = {}
  for i, x in ipairs(node.list) do
    items[i] = quoted(x)
  end
  return list_of(items)
end

local eval_node

local function progn(body, first, ctx)
  local v = NIL
  for i = first, #body do
    v = nilify(eval_node(body[i], ctx))
  end
  return v
end

--- Bindings of `let`/`let*`: `((var value) var ...)`.
local function let_form(items, ctx, sequential)
  local spec = items[2]
  local specs = type(spec) == "table" and spec.list
  if spec ~= nil and not specs and not (type(spec) == "table" and spec.sym == "nil") then
    error("wrong-type-argument listp in let", 0)
  end
  local scope = setmetatable({}, { __index = ctx.vars })
  local inner = setmetatable({ vars = scope }, { __index = ctx })
  for _, b in ipairs(specs or {}) do
    local name, value
    if type(b) == "table" and b.sym then
      name, value = b.sym, NIL
    elseif type(b) == "table" and b.list and b.list[1] and b.list[1].sym then
      name = b.list[1].sym
      value = NIL
      if b.list[2] ~= nil then
        value = nilify(eval_node(b.list[2], sequential and inner or ctx))
      end
    else
      error("invalid let binding", 0)
    end
    scope[name] = value
  end
  return progn(items, 3, inner)
end

--- Special forms: their arguments are not evaluated first.
local SPECIAL = {
  quote = function(items)
    return quoted(items[2])
  end,
  ["and"] = function(items, ctx)
    local v = true
    for i = 2, #items do
      v = eval_node(items[i], ctx)
      if not truthy(v) then
        return NIL
      end
    end
    return v
  end,
  ["or"] = function(items, ctx)
    for i = 2, #items do
      local v = eval_node(items[i], ctx)
      if truthy(v) then
        return v
      end
    end
    return NIL
  end,
  ["if"] = function(items, ctx)
    if truthy(eval_node(items[2], ctx)) then
      return nilify(items[3] ~= nil and eval_node(items[3], ctx) or nil)
    end
    return progn(items, 4, ctx)
  end,
  when = function(items, ctx)
    if truthy(eval_node(items[2], ctx)) then
      return progn(items, 3, ctx)
    end
    return NIL
  end,
  unless = function(items, ctx)
    if not truthy(eval_node(items[2], ctx)) then
      return progn(items, 3, ctx)
    end
    return NIL
  end,
  cond = function(items, ctx)
    for i = 2, #items do
      local clause = items[i]
      if type(clause) ~= "table" or not clause.list then
        error("invalid cond clause", 0)
      end
      local v = clause.list[1] ~= nil and eval_node(clause.list[1], ctx) or NIL
      if truthy(v) then
        if #clause.list > 1 then
          return progn(clause.list, 2, ctx)
        end
        return v
      end
    end
    return NIL
  end,
  progn = function(items, ctx)
    return progn(items, 2, ctx)
  end,
  let = function(items, ctx)
    return let_form(items, ctx, false)
  end,
  ["let*"] = function(items, ctx)
    return let_form(items, ctx, true)
  end,
}

function eval_node(node, ctx)
  if type(node) ~= "table" then
    return node
  elseif node.sym then
    local name = node.sym
    if name == "t" then
      return true
    elseif name == "nil" then
      return NIL
    elseif name:sub(1, 1) == ":" then
      return { symbol = name } -- keywords evaluate to themselves
    end
    local v = ctx.vars[name]
    if v == nil then
      error("void-variable " .. name, 0)
    end
    return v
  end
  local items = node.list
  if #items == 0 then
    return NIL
  end
  local head = items[1]
  if type(head) ~= "table" or not head.sym then
    error("invalid function", 0)
  end
  local name = head.sym
  if SPECIAL[name] then
    return SPECIAL[name](items, ctx)
  end
  local f = FUNCS[name]
  if not f then
    error("unsupported function " .. name, 0)
  end
  local args = {}
  local nargs = #items - 1
  for i = 2, #items do
    args[i - 1] = eval_node(items[i], ctx)
  end
  return f(ctx, unpack(args, 1, nargs))
end

---------------------------------------------------------------------------
-- Diary functions that evaluate a quoted sexp (diary-lib.el)
---------------------------------------------------------------------------

--- A quoted value back as a form (the inverse of `quoted`).
local function to_node(v)
  if v == true then
    return { sym = "t" }
  elseif v == NIL or v == nil then
    return { sym = "nil" }
  elseif type(v) == "table" and v.symbol then
    return { sym = v.symbol }
  elseif is_list(v) then
    local list = {}
    for i, x in ipairs(v.items) do
      list[i] = to_node(x)
    end
    return { list = list }
  elseif type(v) == "table" then
    error("invalid-function", 0)
  end
  return v
end

--- Evaluate the form `v` with `date` bound to DAY (Emacs rebinds the
--- dynamic variable `date`; `entry` is unchanged).
local function eval_on(ctx, v, day)
  local vars = setmetatable({ date = date_list(day) }, { __index = ctx.vars })
  return eval_node(to_node(v), setmetatable({ day = day, vars = vars }, { __index = ctx }))
end

--- diary-offset SEXP DAYS: SEXP applies DAYS days earlier.
FUNCS["diary-offset"] = function(ctx, sexp, days)
  if type(days) ~= "number" or days ~= math.floor(days) then
    error("Days must be an integer", 0)
  end
  return eval_on(ctx, sexp, ctx.day - days)
end

--- diary-remind SEXP DAYS [MARKING]: the entry on its date, and "Reminder:
--- Only N days until ENTRY" DAYS days before (a list of days, or -N for 1..N).
local function remind(ctx, sexp, days)
  if type(days) == "number" and days < 0 and days == math.floor(days) then
    local l = {}
    for i = 1, -days do
      l[i] = i
    end
    days = list_of(l)
  end
  local entry = eval_on(ctx, sexp, ctx.day)
  if truthy(entry) then
    return entry
  elseif type(days) == "number" and days == math.floor(days) then
    entry = eval_on(ctx, sexp, ctx.day + days)
    if not truthy(entry) then
      return NIL
    end
    if type(entry) == "table" and entry.cons then
      entry = entry.cdr
    end
    if type(entry) ~= "string" then
      error("wrong-type-argument sequencep in diary-remind", 0)
    end
    return string.format("Reminder: Only %d day%s until %s", days, days > 1 and "s" or "", entry)
  elseif is_list(days) then
    local r = remind(ctx, sexp, days.items[1])
    if truthy(r) then
      return r
    end
    return remind(ctx, sexp, list_of(vim.list_slice(days.items, 2)))
  end
  return NIL
end
FUNCS["diary-remind"] = function(ctx, sexp, days)
  return remind(ctx, sexp, days)
end

---------------------------------------------------------------------------
-- The date in other calendars (diary-hebrew-date, diary-iso-date, ...)
---------------------------------------------------------------------------

--- Emacs absolute day number (calendar-absolute-from-gregorian) of `day`.
local function absolute(day)
  return day - date.days_from_civil(1, 1, 1) + 1
end

--- { function, calendars.lua converter, format, text when it is "" }
local OTHER_DATES = {
  { "diary-hebrew-date", "hebrew_string", "Hebrew date (until sunset): %s" },
  { "diary-islamic-date", "islamic_string", "Islamic date (until sunset): %s", "Date is pre-Islamic" },
  { "diary-bahai-date", "bahai_string", "Bahá’í date: %s" },
  { "diary-chinese-date", "chinese_string", "Chinese date: %s" },
  { "diary-julian-date", "julian_string", "Julian date: %s" },
  { "diary-iso-date", "iso_string", "ISO date: %s" },
  { "diary-astro-day-number", "astro_string", "Astronomical (Julian) day number at noon UTC: %s.0" },
  { "diary-french-date", "french_string", "French Revolutionary date: %s", "Date is pre-French Revolution" },
  { "diary-mayan-date", "mayan_string", "Mayan date: %s" },
  { "diary-coptic-date", "coptic_string", "Coptic date: %s", "Date is pre-Coptic calendar" },
  { "diary-ethiopic-date", "ethiopic_string", "Ethiopic date: %s", "Date is pre-Ethiopic calendar" },
  { "diary-persian-date", "persian_string", "Persian date: %s" },
}
for _, spec in ipairs(OTHER_DATES) do
  local name, conv, fmt, empty = spec[1], spec[2], spec[3], spec[4]
  FUNCS[name] = function(ctx)
    local s = require("org.agenda.calendars")[conv](absolute(ctx.day))
    if s == nil then
      error("There was no year zero", 0)
    elseif s == "" and empty then
      return empty
    end
    return (fmt:gsub("%%s", function()
      return s
    end))
  end
end

--- diary-day-of-year (calendar-day-of-year-string).
FUNCS["diary-day-of-year"] = function(ctx)
  local y = date.civil_from_days(ctx.day)
  local n = ctx.day - date.days_from_civil(y, 1, 1) + 1
  local left = date.days_from_civil(y, 12, 31) - ctx.day
  return string.format("Day %d of %d; %d day%s remaining in the year", n, y, left, left == 1 and "" or "s")
end
--- diary-lunar-phases [MARK]: the phase of the moon on the day (lunar.el).
FUNCS["diary-lunar-phases"] = function(ctx)
  local cal, astro = require("org.agenda.calendars"), require("org.agenda.holidays.astro")
  local z = require("org.agenda.holidays.solar").system_zone()
  local abs = absolute(ctx.day)
  local m, d, y = mdy(ctx.day)
  -- lunar-index
  local index = 4 * astro.truncate(12.3685 * (y + astro.day_number(m, d, y) / 366.0 + -1900))
  local p = cal.lunar_phase(z, index)
  while p.abs < abs do
    index = index + 1
    p = cal.lunar_phase(z, index)
  end
  if p.abs ~= abs then
    return NIL
  end
  return cons(cal.phase_names[p.phase + 1] .. " " .. p.time .. (p.eclipse ~= "" and (" " .. p.eclipse) or ""))
end

--- diary-sunrise-sunset: at `agenda.calendar_latitude`/`calendar_longitude`.
FUNCS["diary-sunrise-sunset"] = function(ctx)
  local acfg = require("org.config").opts.agenda
  local lat, lon = acfg.calendar_latitude, acfg.calendar_longitude
  if type(lat) ~= "number" or type(lon) ~= "number" then
    error("agenda.calendar_latitude and agenda.calendar_longitude are not set", 0)
  end
  local location = acfg.calendar_location_name
  return require("org.agenda.calendars").sunrise_sunset_string(absolute(ctx.day), lat, lon, { location = location })
end
M.functions = vim.tbl_keys(FUNCS)

--- Evaluate a sexp for a day (org.date day number).
--- Returns false when it does not match, true when it matches without text,
--- or the (formatted) entry text when it matches. On error returns nil and
--- the error message.
---@param node table|string parsed node or sexp text
---@param day integer
---@param entry_text? string text after the sexp (`entry` in Emacs), used by %d/%s
---@return boolean|string|nil, string|nil
function M.eval(node, day, entry_text)
  if type(node) == "string" then
    local err
    node, err = M.parse(node)
    if not node then
      return nil, err
    end
  end
  local entry = entry_text or ""
  -- the dynamic variables of a diary sexp: `date' (month day year), `entry'
  local ctx = { day = day, entry = entry, vars = { date = date_list(day), entry = entry } }
  local ok, res = pcall(eval_node, node, ctx)
  if not ok then
    return nil, tostring(res)
  end
  -- org-diary-sexp-entry: strings, (mark . "text"), other non-nil => entry
  local text
  if type(res) == "string" then
    -- even "" is an entry: the agenda shows "SEXP entry returned empty string"
    return res
  elseif type(res) == "table" and res.cons then
    text = type(res.cdr) == "string" and res.cdr or ctx.entry
  elseif is_list(res) and type(res.items[1]) == "string" then
    -- a list of strings: one entry each (joined for the "; " split)
    local texts = {}
    for i, v in ipairs(res.items) do
      texts[i] = type(v) == "string" and v or ""
    end
    text = table.concat(texts, "; ")
  elseif res == NIL or res == nil then
    return false
  else
    text = ctx.entry
  end
  if text == "" then
    return true
  end
  return text
end

---------------------------------------------------------------------------
-- Finding sexps in text
---------------------------------------------------------------------------

--- `<%%(SEXP)>` timestamps in a line, like Emacs's
--- "<%%\\(([^>\n]+)\\)\\([^\n>]*\\)>" (the sexp ends at the last `)`
--- before the first `>`).
---@param line string
---@return { sexp: string, start_col: integer, end_col: integer, text_after: string }[]
function M.find_all(line)
  local out = {}
  local init = 1
  while true do
    local s = line:find("<%%(", init, true)
    if not s then
      break
    end
    local close = line:find(">", s + 3, true)
    if not close then
      break
    end
    local body = line:sub(s + 3, close - 1)
    local last = body:match("^.*()%)")
    if last and last > 2 then
      out[#out + 1] = {
        sexp = body:sub(1, last),
        start_col = s,
        end_col = close,
        text_after = body:sub(last + 1),
      }
    end
    init = close + 1
  end
  return out
end

--- End position of the balanced sexp starting at `i` (a `(`), or nil.
local function sexp_end(str, i)
  local depth = 0
  local instr = false
  local j = i
  while j <= #str do
    local c = str:sub(j, j)
    if instr then
      if c == "\\" then
        j = j + 1
      elseif c == '"' then
        instr = false
      end
    elseif c == '"' then
      instr = true
    elseif c == "(" then
      depth = depth + 1
    elseif c == ")" then
      depth = depth - 1
      if depth == 0 then
        return j
      end
    end
    j = j + 1
  end
  return nil
end

--- A diary sexp line, `%%(SEXP) text` or `&%%(SEXP) text` at the beginning
--- of the line (org-agenda-get-sexps).
---@param line string
---@return { sexp: string, text: string }|nil
function M.line_entry(line)
  local prefix = line:match("^&?%%%%%(")
  if not prefix then
    return nil
  end
  local start = #prefix
  local e = sexp_end(line, start)
  if not e then
    return nil
  end
  return { sexp = line:sub(start, e), text = vim.trim(line:sub(e + 1)) }
end

return M
