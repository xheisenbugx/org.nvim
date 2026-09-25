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
---   and, or, not, list, quote
---
--- The `diary-*` functions use Emacs's default `calendar-date-style`
--- (american: month day year); the `org-*` wrappers use ISO order (year month
--- day), exactly like Emacs. Anything else (arbitrary Elisp, holidays, other
--- calendars, diary-remind, ...) is reported as an error so the caller can skip
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
  list = function(_, ...)
    return { items = { ... } }
  end,
  ["not"] = function(_, v)
    return v == NIL or v == nil
  end,
  null = function(_, v)
    return v == NIL or v == nil
  end,
}
M.functions = vim.tbl_keys(FUNCS)

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
  return { items = items }
end

local function eval_node(node, ctx)
  if type(node) ~= "table" then
    return node
  elseif node.sym then
    if node.sym == "t" then
      return true
    elseif node.sym == "nil" then
      return NIL
    elseif node.sym == "entry" then
      return ctx.entry
    end
    error("void-variable " .. node.sym, 0)
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
  if name == "quote" then
    return quoted(items[2])
  elseif name == "and" then
    local v = true
    for i = 2, #items do
      v = eval_node(items[i], ctx)
      if v == NIL or v == nil then
        return NIL
      end
    end
    return v
  elseif name == "or" then
    for i = 2, #items do
      local v = eval_node(items[i], ctx)
      if v ~= NIL and v ~= nil then
        return v
      end
    end
    return NIL
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
  local ctx = { day = day, entry = entry_text or "" }
  local ok, res = pcall(eval_node, node, ctx)
  if not ok then
    return nil, tostring(res)
  end
  -- org-diary-sexp-entry: strings, (mark . "text"), other non-nil => entry
  local text
  if type(res) == "string" then
    text = res
  elseif type(res) == "table" and res.cons then
    text = type(res.cdr) == "string" and res.cdr or ctx.entry
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
