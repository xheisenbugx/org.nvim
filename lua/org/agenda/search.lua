---@mod org.agenda.search Tags / property / TODO matches and text search
---
--- Implements the Emacs `org-make-tags-matcher` syntax (tags views, sparse
--- trees, clock tables, column view) and the `org-search-view` query syntax.
---
---   +work-boss               tag work, not tag boss (`:` also means AND)
---   work&urgent|home         (work AND urgent) OR home
---   {^proj}                  a tag matching an (Emacs) regexp
---   PRIORITY="A" LEVEL>1     property comparisons (= == <> != /= < <= > >=)
---   Effort<2                 numbers: `string-to-number` of the value ("1:30" is 1)
---   Effort<*2                starred operator: only entries that have the property
---   SCHEDULED<="<today>"     dates: <now> <today> <tomorrow> <+2d> <2026-01-01>
---   CATEGORY={^w}            regexp property match (`<>`, `!=`, `/=` negate)
---   .../TODO|NEXT            TODO part: keywords (OR), -KW excludes, {re}
---   .../!                    only not-done TODO entries (`/!-WAIT` etc.)
---
--- Regexps are written in Emacs syntax and translated to Vim regexps
--- (`M.emacs_regexp`); they match case-insensitively, like Emacs, which runs
--- the matcher with `case-fold-search` bound to t.

local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")

local M = {}

---------------------------------------------------------------------------
-- Emacs regexps
---------------------------------------------------------------------------

-- `vim.regex():match_str()` sees a newline as an ordinary character: `^`,
-- `$` and `.` need spelling out to behave like Emacs on multi-line text.
local NL = "\\%d10"
local BOL = "\\%(\\%^\\|\\%d10\\@<=\\)"
local EOL = "\\%(\\%$\\|\\%d10\\@=\\)"
local ANY = "[^\\x0a]"
-- word constituents: letters and digits (`_` is a symbol constituent)
local WORD = "[^[:punct:][:space:][:cntrl:]]"
local NOT_WORD = "[[:punct:][:space:][:cntrl:]]"

-- Emacs syntax classes (`\sC` / `\SC`), best effort.
local SYNTAX = {
  ["-"] = "[:space:]",
  [" "] = "[:space:]",
  w = "[:alnum:]\\u00c0-\\uffff",
  _ = "_",
  ["."] = "[:punct:]",
  ["("] = "([{",
  [")"] = ")\\]}",
  ['"'] = '"',
  ["'"] = "'",
  ["\\"] = "\\\\",
  ["$"] = "$",
}

-- POSIX classes Emacs knows but Vim does not.
local CLASSES = {
  word = "[:alnum:]\\u00c0-\\uffff",
  ascii = "\\x01-\\x7f",
  unibyte = "\\x01-\\x7f",
  nonascii = "\\u0080-\\uffff",
  multibyte = "\\u0080-\\uffff",
}

local VIM_SPECIAL = { ["\\"] = true, ["^"] = true, ["$"] = true, ["."] = true, ["*"] = true, ["["] = true, ["~"] = true }

--- A character as a literal in a magic Vim pattern.
local function lit(c)
  if c == "\n" then
    return NL
  end
  return VIM_SPECIAL[c] and ("\\" .. c) or c
end

--- `s` as a literal Vim pattern (Emacs `regexp-quote`).
function M.quote(s)
  return (s:gsub("[\\%^%$%.%*%[~\n]", lit))
end

--- Translate a bracket expression starting at `i` (the `[`).
---@return string, integer vim bracket, index after the closing `]`
local function bracket(re, i, fold)
  local n = #re
  local j = i + 1
  local out = { "[" }
  if re:sub(j, j) == "^" then
    out[#out + 1] = "^"
    j = j + 1
  end
  if re:sub(j, j) == "]" then
    out[#out + 1] = "]"
    j = j + 1
  end
  while j <= n do
    local c = re:sub(j, j)
    if c == "]" then
      out[#out + 1] = "]"
      return table.concat(out), j + 1
    elseif c == "[" and re:sub(j + 1, j + 1) == ":" then
      local name, e = re:match("^%[:(%a+):%]()", j)
      if not name then
        error("invalid character class in regexp: " .. re)
      end
      if fold and (name == "upper" or name == "lower") then
        -- `case-fold-search' makes these match either case
        name = "alpha"
      end
      out[#out + 1] = CLASSES[name] or ("[:" .. name .. ":]")
      j = e
    elseif c == "\\" then
      -- a backslash is an ordinary character inside Emacs brackets
      out[#out + 1] = "\\\\"
      j = j + 1
    elseif c == "\n" then
      out[#out + 1] = "\\x0a"
      j = j + 1
    else
      out[#out + 1] = c
      j = j + 1
    end
  end
  error("unmatched [ in regexp: " .. re)
end

--- Translate an Emacs regexp to a (magic) Vim regexp that behaves the same
--- with `vim.regex():match_str()` on text that may contain newlines:
--- `\(...\)`, `\(?:...\)`, `\|`, `\{m,n\}`, postfix `* + ?` and their
--- non-greedy forms, `[...]` with character classes, `\< \> \b \_< \_>`,
--- `` \` `` / `\'`, `\w \W \sC \SC`, `^`/`$` at line boundaries, `.`
--- (not a newline) and backreferences. Other escaped characters are
--- literal, like in Emacs. With `fold` (case-insensitive matching, the
--- caller adds `\c`), `[:upper:]` and `[:lower:]` match either case.
---@param re string Emacs regexp
---@param fold? boolean
---@return string
function M.emacs_regexp(re, fold)
  local out = {}
  local n = #re
  local i = 1
  local at_start = true -- `^` is an anchor and `*` a literal here
  local function emit(s, start)
    out[#out + 1] = s
    at_start = start or false
  end
  while i <= n do
    local c = re:sub(i, i)
    if c == "\\" then
      local d = re:sub(i + 1, i + 1)
      i = i + 2
      if d == "(" then
        if re:sub(i, i) == "?" then
          local num, e = re:match("^%?(%d*):()", i)
          if not num then
            error("invalid group in regexp: " .. re)
          end
          i = e
          emit(num == "" and "\\%(" or "\\(", true)
        else
          emit("\\(", true)
        end
      elseif d == ")" then
        emit("\\)")
      elseif d == "|" then
        emit("\\|", true)
      elseif d == "{" then
        local body, e = re:match("^([%d,]*)\\}()", i)
        if not body or not body:match("^%d*,?%d*$") then
          error("invalid \\{ in regexp: " .. re)
        end
        i = e
        emit("\\{" .. body .. "}")
      elseif d:match("^%d$") and d ~= "0" then
        emit("\\" .. d)
      elseif d == "w" then
        emit(WORD)
      elseif d == "W" then
        emit(NOT_WORD)
      elseif d == "s" or d == "S" then
        local cls = re:sub(i, i)
        i = i + 1
        local set = SYNTAX[cls]
        if set then
          emit((d == "s" and "[" or "[^") .. set .. "]")
        else
          emit(d == "s" and ANY or "[\\x0a]")
        end
      elseif d == "c" or d == "C" then
        -- character categories: unsupported, match any character
        i = i + 1
        emit(ANY)
      elseif d == "<" or d == ">" then
        emit("\\" .. d)
      elseif d == "_" and (re:sub(i, i) == "<" or re:sub(i, i) == ">") then
        emit("\\" .. re:sub(i, i))
        i = i + 1
      elseif d == "b" then
        emit("\\%(\\<\\|\\>\\)")
      elseif d == "B" then
        emit("\\%(\\<\\|\\>\\)\\@!")
      elseif d == "`" then
        emit("\\%^", true)
      elseif d == "'" then
        emit("\\%$")
      elseif d == "=" then
        -- point: never matches in a string
        emit("\\%(\\)\\@!")
      elseif d == "" then
        error("trailing backslash in regexp: " .. re)
      else
        emit(lit(d))
      end
    elseif c == "[" then
      local s, e = bracket(re, i, fold)
      emit(s)
      i = e
    elseif c == "*" or c == "+" or c == "?" then
      if at_start then
        emit(c == "*" and "\\*" or c)
        i = i + 1
      else
        local lazy = re:sub(i + 1, i + 1) == "?"
        if lazy then
          emit(c == "*" and "\\{-}" or (c == "+" and "\\{-1,}" or "\\{-,1}"))
          i = i + 2
        else
          emit(c == "*" and "*" or (c == "+" and "\\+" or "\\="))
          i = i + 1
        end
      end
    elseif c == "^" then
      if at_start then
        emit(BOL, true)
      else
        emit("\\^")
      end
      i = i + 1
    elseif c == "$" then
      local nxt = re:sub(i + 1, i + 2)
      if i == n or nxt == "\\)" or nxt == "\\|" then
        emit(EOL)
      else
        emit("\\$")
      end
      i = i + 1
    elseif c == "." then
      emit(ANY)
      i = i + 1
    else
      emit(lit(c))
      i = i + 1
    end
  end
  return table.concat(out)
end

--- Compile an Emacs regexp into a case-insensitive `vim.regex` object
--- (errors on an invalid regexp).
---@param re string
---@param case_sensitive? boolean
function M.compile_emacs_regexp(re, case_sensitive)
  local ok, r = pcall(function()
    return vim.regex((case_sensitive and "\\C" or "\\c") .. M.emacs_regexp(re, not case_sensitive))
  end)
  if not ok then
    error("invalid regexp {" .. re .. "}: " .. tostring(r):gsub("^.-:%d+: ", ""), 0)
  end
  return r
end

---------------------------------------------------------------------------
-- Values
---------------------------------------------------------------------------

--- Emacs `string-to-number`: the leading number of `s`, else 0.
function M.string_to_number(s)
  if type(s) == "number" then
    return s
  end
  s = tostring(s or "")
  local m, rest = s:match("^[ \t]*([%+%-]?%d*%.?%d*)()")
  if not m or not m:match("%d") then
    return 0
  end
  local e = s:match("^[eE][%+%-]?%d+", rest) or ""
  return tonumber(m .. e) or tonumber(m) or 0
end

--- Minutes since the epoch of the first `YYYY-MM-DD [dow] [HH:MM]` in `s`
--- (Emacs `org-2ft`, in minutes), or 0.
local function time_value(s)
  if type(s) ~= "string" then
    return 0
  end
  local y, mo, d, rest = s:match("(%d%d%d%d)%-(%d%d)%-(%d%d)()")
  if not y then
    return 0
  end
  local h, mi = s:sub(rest):match("^ +[^%]%+0-9>\r\n %-]+ +(%d%d?):(%d%d)")
  if not h then
    h, mi = s:sub(rest):match("^ +(%d%d?):(%d%d)")
  end
  return date.days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 1440 + (tonumber(h) or 0) * 60
    + (tonumber(mi) or 0)
end

--- Minutes value of a date match operand (Emacs `org-matcher-time`), or 0.
local function matcher_time(s)
  local now = date.now():minutes()
  local today = date.today():minutes()
  if s == "<now>" then
    return now
  elseif s == "<today>" then
    return today
  elseif s == "<tomorrow>" then
    return today + 1440
  elseif s == "<yesterday>" then
    return today - 1440
  end
  local n, unit = s:match("^<([%+%-]%d+)([hdwmy])>$")
  if n then
    local mult = { h = 60, d = 1440, w = 10080, m = 44640, y = 525960 }
    return (unit == "h" and now or today) + tonumber(n) * mult[unit]
  end
  return time_value(s)
end

--- Resolve a date match value: "<today>", "<+2d>", "<2026-01-01>", "<now>".
---@return table|nil date
function M.resolve_date(v)
  local inner = v:sub(2, -2)
  local lower = inner:lower()
  if lower == "now" then
    return date.now()
  elseif lower == "today" then
    return date.today()
  elseif lower == "tomorrow" then
    return date.today():add(1, "d")
  elseif lower == "yesterday" then
    return date.today():add(-1, "d")
  end
  local rel_sign, n, unit = lower:match("^([%+%-])(%d+)([hdwmy]?)$")
  if rel_sign then
    n = tonumber(n) * (rel_sign == "-" and -1 or 1)
    return date.today():add(n, unit ~= "" and unit or "d")
  end
  return date.parse("<" .. inner .. ">") or date.read_date(inner)
end

---------------------------------------------------------------------------
-- Tags / property / TODO matcher (org-make-tags-matcher)
---------------------------------------------------------------------------

local NAME_CHARS = "^[%w_\128-\255]+"
local TAG_CHARS = "^[%w_@#%%\128-\255]+"

--- Operand of a property comparison at `i`: {re}, "string" or a number.
local function parse_operand(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local j = s:find("}", i + 1, true)
    if j and j > i + 1 then
      return { kind = "regex", text = s:sub(i + 1, j - 1) }, j + 1
    end
  elseif c == '"' then
    local j = s:find('"', i + 1, true)
    if j then
      return { kind = "string", text = s:sub(i + 1, j - 1) }, j + 1
    end
  else
    local num = s:match("^%-?[%.%d]+", i)
    if num then
      local e = s:match("^[eE][%+%-]?%d+", i + #num) or ""
      return { kind = "number", text = num .. e }, i + #num + #e
    end
  end
end

--- Operator candidates at `i`, in the order Emacs's regexp tries them.
local function op_candidates(s, i)
  local c1, c2 = s:sub(i, i), s:sub(i + 1, i + 1)
  local out = {}
  if c1 ~= "" and ("<=>"):find(c1, 1, true) then
    if c2 == "=" then
      out[#out + 1] = c1 .. c2
    end
    out[#out + 1] = c1
  end
  if (c1 == "!" or c1 == "/") and c2 == "=" then
    out[#out + 1] = c1 .. c2
  end
  if c1 == "<" and c2 == ">" then
    out[#out + 1] = "<>"
  end
  return out
end

--- One query term at `i` of `s` (`&?[-+:]?TERM`), or nil when the rest
--- of the string does not start with a term (Emacs ignores that rest).
---@return table|nil term, integer|nil next index
local function parse_term(s, i)
  local j = i
  if s:sub(j, j) == "&" then
    j = j + 1
  end
  local sign = s:sub(j, j)
  local neg = false
  if sign == "-" or sign == "+" or sign == ":" then
    neg = sign == "-"
    j = j + 1
  end
  local c = s:sub(j, j)
  if c == "{" then
    local k = s:find("}", j + 1, true)
    if k and k > j + 1 then
      return { kind = "tagre", neg = neg, text = s:sub(j, k), re = s:sub(j + 1, k - 1) }, k + 1
    end
    return nil
  end
  -- property name: word characters or backslash-escaped characters
  local k = j
  while true do
    local run = s:match(NAME_CHARS, k)
    if run then
      k = k + #run
    elseif s:sub(k, k) == "\\" and s:sub(k + 1, k + 1):match("^%S$") then
      k = k + 2
    else
      break
    end
  end
  if k > j then
    for _, op in ipairs(op_candidates(s, k)) do
      local p = k + #op
      for _, star in ipairs({ true, false }) do
        local q = p
        if not star or s:sub(q, q) == "*" then
          if star then
            q = q + 1
          end
          local value, e = parse_operand(s, q)
          if value then
            local name = s:sub(j, k - 1):gsub("\\(.)", "%1"):upper()
            return { kind = "prop", neg = neg, name = name, op = op, star = star, value = value, text = s:sub(j, e - 1) },
              e
          end
        end
      end
    end
  end
  local tag = s:match(TAG_CHARS, j)
  if tag then
    return { kind = "tag", neg = neg, name = tag, text = tag }, j + #tag
  end
  return nil
end

--- All terms of an AND group, stopping (silently, like Emacs) at the
--- first position that does not start a term.
local function parse_and(s)
  local terms = {}
  local i = 1
  while i <= #s do
    local t, e = parse_term(s, i)
    if not t then
      break
    end
    terms[#terms + 1] = t
    i = e
  end
  return terms
end

--- Emacs `org-split-string` on "|": pieces at the ends are dropped when
--- empty, empty pieces in between are kept.
local function split_bar(s)
  local parts = vim.split(s, "|", { plain = true })
  if parts[1] == "" then
    table.remove(parts, 1)
  end
  if parts[#parts] == "" then
    table.remove(parts)
  end
  return parts
end

local CMP = {
  ["<"] = function(a, b)
    return a < b
  end,
  [">"] = function(a, b)
    return a > b
  end,
  ["<="] = function(a, b)
    return a <= b
  end,
  [">="] = function(a, b)
    return a >= b
  end,
  ["="] = function(a, b)
    return a == b
  end,
  ["<>"] = function(a, b)
    return a ~= b
  end,
}
local OP_KIND = { ["<"] = "<", [">"] = ">", ["<="] = "<=", [">="] = ">=", ["="] = "=", ["=="] = "=" }
for _, o in ipairs({ "<>", "!=", "/=" }) do
  OP_KIND[o] = "<>"
end

local function is_time_operand(v)
  if v.kind ~= "string" then
    return false
  end
  local l = ('"' .. v.text .. '"'):lower()
  local ok = l:match('^"[%[<]%d') or l:match('^"[%[<]now') or l:match('^"[%[<]today')
    or l:match('^"[%[<]tomorrow') or l:match('^"[%[<][%+%-]%d+[dmwy]')
  return ok ~= nil and l:match('[%]>]"$') ~= nil
end

--- The first inactive timestamp of the entry (TIMESTAMP_IA).
local function first_inactive(hl)
  for i = hl.line, hl.body_end do
    if i ~= hl.planning_line then
      local line = hl.file.lines[i] or ""
      if not line:match("^%s*CLOCK:") then
        for _, m in ipairs(date.parse_all(line)) do
          if not m.date.active then
            return m.raw
          end
        end
      end
    end
  end
end

--- Property value getter of the matcher (org-make-tags-matcher's `gv`).
local function getter(name)
  if name == "LEVEL" then
    return function(hl)
      return tostring(hl.level)
    end
  elseif name == "CATEGORY" then
    return function(hl)
      return hl:get_category()
    end
  elseif name == "TODO" then
    return function(hl)
      return hl.todo
    end
  elseif name == "TIMESTAMP_IA" then
    return first_inactive
  end
  return function(hl)
    return hl:get_property(name)
  end
end

--- Compile a property term into predicate(hl).
local function compile_prop(t)
  local gv = getter(t.name)
  local kind = OP_KIND[t.op]
  local v = t.value
  local test
  if v.kind == "regex" then
    local re = M.compile_emacs_regexp(v.text)
    local neg = kind == "<>"
    test = function(value)
      return (re:match_str(value or "") ~= nil) ~= neg
    end
  elseif is_time_operand(v) then
    local b = matcher_time(v.text)
    test = function(value)
      local a = time_value(value or "")
      if not (a > 0 and b > 0) then
        return false
      end
      -- Emacs's `org-time<>' tests equality (it calls `\=', i.e. `=')
      return CMP[kind == "<>" and "=" or kind](a, b)
    end
  elseif v.kind == "string" then
    local b = v.text
    test = function(value)
      return CMP[kind](value or "", b)
    end
  else
    local b = M.string_to_number(v.text)
    test = function(value)
      return CMP[kind](M.string_to_number(value or ""), b)
    end
  end
  return function(hl)
    local value = gv(hl)
    if t.star and value == nil then
      return false
    end
    return test(value)
  end
end

--- Compile one term into predicate(hl, tags).
local function compile_term(t)
  local f
  if t.kind == "tag" then
    local name = t.name
    f = function(_, tags)
      return tags()[name] == true
    end
  elseif t.kind == "tagre" then
    local re = M.compile_emacs_regexp(t.re)
    f = function(_, tags)
      for tag in pairs(tags()) do
        if re:match_str(tag) then
          return true
        end
      end
      return false
    end
  else
    local p = compile_prop(t)
    f = function(hl)
      return p(hl)
    end
  end
  if t.neg then
    return function(hl, tags)
      return not f(hl, tags)
    end
  end
  return f
end

--- Compile the TODO part ("TODO|NEXT", "-DONE", "{^W}").
local function compile_todo(s)
  local groups = {}
  for _, term in ipairs(split_bar(s)) do
    local preds = {}
    for _, t in ipairs(parse_and(term)) do
      local p
      if t.kind == "tagre" then
        local re = M.compile_emacs_regexp(t.re)
        p = function(hl)
          -- Emacs signals an error for entries without a keyword
          return hl.todo ~= nil and re:match_str(hl.todo) ~= nil
        end
      else
        local kw = t.text
        p = function(hl)
          return hl.todo == kw
        end
      end
      if t.neg then
        local q = p
        p = function(hl)
          return not q(hl)
        end
      end
      preds[#preds + 1] = p
    end
    groups[#groups + 1] = preds
  end
  return function(hl)
    for _, preds in ipairs(groups) do
      if #preds > 0 then
        local all = true
        for _, p in ipairs(preds) do
          if not p(hl) then
            all = false
            break
          end
        end
        if all then
          return true
        end
      end
    end
    return false
  end
end

--- Compile a match string into predicate(headline) -> boolean.
--- Invalid regexps raise an error; use `M.try_compile` for (nil, err).
--- Like Emacs, text after the last term that parses is ignored.
---@param match string
---@return fun(hl: org.Headline): boolean
function M.compile(match)
  match = match or ""
  -- the TODO part follows the last run of slashes, unless a double quote
  -- comes after it (then the slash belongs to a property value)
  local tag_part, todo_part = match, nil
  local last
  for s in match:gmatch("()/+") do
    last = s
  end
  if last and not match:find('"', last, true) then
    local e = match:match("^/+()", last)
    tag_part, todo_part = match:sub(1, last - 1), match:sub(e)
  end
  local todo_only = false
  if todo_part then
    if todo_part:sub(1, 1) == "!" then
      todo_only = true
      todo_part = todo_part:sub(2)
    end
    if todo_part:match("^%s*$") then
      todo_part = nil
    end
  end

  local tag_pred
  if tag_part:match("%S") then
    local orterms = split_bar(tag_part)
    local groups = {}
    local k = 1
    while k <= #orterms do
      local term = orterms[k]
      k = k + 1
      -- repair a split on an escaped bar
      while term:sub(-1) == "\\" and k <= #orterms do
        term = term .. "|" .. orterms[k]
        k = k + 1
      end
      local preds = {}
      for _, t in ipairs(parse_and(term)) do
        preds[#preds + 1] = compile_term(t)
      end
      groups[#groups + 1] = preds
    end
    tag_pred = function(hl)
      local set
      local function tags()
        if not set then
          set = {}
          for _, t in ipairs(hl:get_tags()) do
            set[t] = true
          end
        end
        return set
      end
      for _, preds in ipairs(groups) do
        local all = true
        for _, p in ipairs(preds) do
          if not p(hl, tags) then
            all = false
            break
          end
        end
        if all then
          return true
        end
      end
      return false
    end
  end
  local todo_pred = todo_part and compile_todo(todo_part) or nil

  return function(hl)
    if todo_only and not hl:is_todo() then
      return false
    end
    if todo_pred and not todo_pred(hl) then
      return false
    end
    if tag_pred and not tag_pred(hl) then
      return false
    end
    return true
  end
end

---@return (fun(hl: org.Headline): boolean)|nil, string|nil
function M.try_compile(match)
  local ok, res = pcall(M.compile, match)
  if not ok then
    return nil, (tostring(res):gsub("^.-:%d+: ", ""))
  end
  return res
end

---------------------------------------------------------------------------
-- Text search (agenda search view, org-search-view)
---------------------------------------------------------------------------

local function search_opt(opts, key)
  if opts and opts[key] ~= nil then
    return opts[key]
  end
  return (config.opts.agenda or {})[key]
end

--- Parse a search view query like `org-search-view`.
---@param query string
---@param opts? table overrides of the `search_view_*` agenda options
---@return { headline_only: boolean, todo_only: boolean, boolean: boolean, plus: string[], minus: string[] }
function M.parse_query(query, opts)
  local words = query or ""
  local hdl_only, todo_only = false, false
  local full_words = search_opt(opts, "search_view_force_full_words") and true or false
  if words:sub(1, 1) == "*" then
    hdl_only = true
    words = words:sub(2)
  end
  if words:sub(1, 1) == "!" then
    todo_only = true
    words = words:sub(2)
  end
  if words:sub(1, 1) == ":" then
    full_words = true
    words = words:sub(2)
  end
  local boolean = search_opt(opts, "search_view_always_boolean") and true or false
  if words:match("^[%-%+{]") then
    boolean = true
  end
  local list = vim.split(vim.trim(words), "%s+", { trimempty = true })
  -- a word ending in a backslash continues with the next one
  local www = {}
  local k = 1
  while k <= #list do
    local w = list[k]
    k = k + 1
    while w:sub(-1) == "\\" and k <= #list do
      w = w:sub(1, -2) .. " " .. list[k]
      k = k + 1
    end
    www[#www + 1] = w
  end
  -- a {regexp} may contain spaces
  list, www, k = www, {}, 1
  while k <= #list do
    local w = list[k]
    k = k + 1
    if w:match("^[%-%+]?{") and not w:match("}$") then
      while k <= #list and not list[k]:match("}$") do
        w = w .. " " .. list[k]
        k = k + 1
      end
      w = w .. " " .. (list[k] or "")
      k = k + 1
    end
    www[#www + 1] = w
  end
  list = www
  local plus, minus = {}, {}
  if boolean then
    -- double-quoted snippets are taken as a whole
    local wds = {}
    k = 1
    while k <= #list do
      local w = list[k]
      k = k + 1
      if w:sub(1, 1) == '"' or (#w > 1 and w:match("^[%+%-]") and w:sub(2, 2) == '"') then
        while k <= #list and w:sub(-1) ~= '"' do
          w = w .. " " .. list[k]
          k = k + 1
        end
      end
      w = w:gsub('^([%-%+]?)"', "%1")
      if w:sub(-1) == '"' then
        w = w:sub(1, -2)
      end
      wds[#wds + 1] = w
    end
    for _, w in ipairs(wds) do
      local neg = false
      local c = w:sub(1, 1)
      if c == "-" then
        neg, w = true, w:sub(2)
      elseif c == "+" then
        w = w:sub(2)
      end
      local re, len
      if w:match("^{.*}$") then
        re, len = M.emacs_regexp(w:sub(2, -2), true), #w - 2
      else
        len = #w + select(2, w:gsub("[%[%*%.\\%?%+%^%$]", ""))
        re = M.quote(w:lower())
        if full_words then
          re, len = "\\<" .. re .. "\\>", len + 4
        end
      end
      table.insert(neg and minus or plus, { pattern = re, len = len })
    end
  else
    local quoted, len = {}, 0
    for _, w in ipairs(list) do
      quoted[#quoted + 1] = M.quote(w)
      len = len + #w + 4
    end
    plus[1] = { pattern = table.concat(quoted, "[[:space:]]\\+"), len = len }
  end
  -- Emacs pushes the snippets (reversing them) and sorts them by length,
  -- longest first; the first one locates entries, the others filter them
  local rev = {}
  for i = #plus, 1, -1 do
    rev[#rev + 1] = plus[i]
  end
  for i, p in ipairs(rev) do
    p.idx = i
  end
  table.sort(rev, function(a, b)
    if a.len ~= b.len then
      return a.len > b.len
    end
    return a.idx < b.idx
  end)
  plus = {}
  for i, p in ipairs(rev) do
    plus[i] = p.pattern
  end
  for i, p in ipairs(minus) do
    minus[i] = p.pattern
  end
  return { headline_only = hdl_only, todo_only = todo_only, boolean = boolean, plus = plus, minus = minus }
end

--- Last line of the region the search view treats as the entry of `hl`:
--- up to the next heading (with `max_level` > 0, the next heading at that
--- level or above), or nil when `hl` is deeper than `max_level` (its text
--- belongs to its ancestor).
local function region_end(hl, max_level)
  if max_level > 0 then
    if hl.level > max_level then
      return nil
    end
    local hls = hl.file.headlines
    for i = (hl.index or 0) + 1, #hls do
      if hls[i].level <= max_level then
        return hls[i].line - 1
      end
    end
    return #hl.file.lines
  end
  return hl.body_end
end

--- Compile a search-view query into predicate(headline), following
--- `org-search-view`: a plain query is a phrase whose spaces match any
--- whitespace (newlines included); a query starting with `+`, `-` or `{`
--- (or any query with `search_view_always_boolean`) is a list of words
--- (`+word`, `-word`, `"a phrase"`, `{emacs regexp}`) that must / must not
--- occur. A leading `*` searches headlines only, `!` TODO entries only and
--- `:` makes words match full words (like `search_view_force_full_words`).
--- Matching ignores case.
---@param query string
---@param opts? table overrides of `search_view_always_boolean`,
---  `search_view_force_full_words`, `search_view_max_outline_level`
---@return fun(hl: org.Headline): boolean
function M.compile_text(query, opts)
  local q = M.parse_query(query, opts)
  local function compile(p)
    local ok, r = pcall(vim.regex, "\\c" .. p)
    if not ok then
      error("invalid search regexp: " .. tostring(r):gsub("^.-:%d+: ", ""), 0)
    end
    return r
  end
  local plus, minus = {}, {}
  for _, p in ipairs(q.plus) do
    plus[#plus + 1] = compile(p)
  end
  for _, p in ipairs(q.minus) do
    minus[#minus + 1] = compile(p)
  end
  local max_level = tonumber(search_opt(opts, "search_view_max_outline_level")) or 0
  local primary = table.remove(plus, 1)
  return function(hl)
    if q.todo_only and not hl:is_todo() then
      return false
    end
    local last = region_end(hl, max_level)
    if not last then
      return false
    end
    local lines = hl.file.lines
    last = math.min(last, #lines)
    local region = table.concat(lines, "\n", hl.line, last) .. "\n"
    local text = q.headline_only and (lines[hl.line] or "") or region
    -- the longest snippet locates the entry: anywhere in its region (on a
    -- heading line with `*`), deeper entries merged into it
    if primary then
      local found = false
      if q.headline_only then
        for i = hl.line, last do
          local l = lines[i]
          if l:match("^%*+ ") and primary:match_str((l:gsub("^%*+ ", ""))) then
            found = true
            break
          end
        end
      else
        found = primary:match_str(region) ~= nil
      end
      if not found then
        return false
      end
    end
    for _, r in ipairs(minus) do
      if r:match_str(text) then
        return false
      end
    end
    for _, r in ipairs(plus) do
      if not r:match_str(text) then
        return false
      end
    end
    return true
  end
end

---------------------------------------------------------------------------
-- Global heading jump
---------------------------------------------------------------------------

--- Pick any headline in the agenda files (plus current buffer) and jump to it.
function M.goto_heading()
  local entries = {}
  for _, file in ipairs(require("org.files").agenda_files_with_current()) do
    local fname = file.filename and vim.fn.fnamemodify(file.filename, ":t") or "[buffer]"
    for _, hl in ipairs(file.headlines) do
      local parts = { fname }
      vim.list_extend(parts, hl:outline_path())
      local title = hl:plain_title()
      if hl.todo then
        title = hl.todo .. " " .. title
      end
      parts[#parts + 1] = title
      entries[#entries + 1] = {
        text = table.concat(parts, " › "),
        filename = file.filename,
        bufnr = file.bufnr,
        lnum = hl.line,
      }
    end
  end
  if #entries == 0 then
    utils.warn("No headlines found in agenda files")
    return
  end
  local choice = utils.select(entries, {
    prompt = "Go to heading",
    kind = "org_heading",
    format_item = function(e)
      return e.text
    end,
  })
  if not choice then
    return
  end
  if choice.filename then
    utils.open_file(choice.filename, choice.lnum)
  elseif choice.bufnr then
    vim.api.nvim_set_current_buf(choice.bufnr)
    vim.api.nvim_win_set_cursor(0, { choice.lnum, 0 })
    vim.cmd("normal! zv")
  end
end

return M
