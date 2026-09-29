---@mod org.extensions.ql.query org-ql queries
---
--- Parses org-ql queries and compiles them to headline predicates. A query
--- is one of:
---
---   (and (todo "NEXT") (tags "work"))      a sexp query, as in Emacs
---   todo:NEXT,WAITING tags:work !done       the plain ("non-sexp") syntax
---   { "and", { "todo", "NEXT" }, { "tags", "work" } }   a Lua table
---
--- In the Lua form a predicate is a list whose first element is its name;
--- keyword arguments are strings starting with ":" followed by their value
--- (`{ "deadline", ":to", "today" }`), and `{ "pred", fn }` calls
--- `fn(headline)`. Sexp and plain queries are read into that form.

local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")

local M = {}

---------------------------------------------------------------------------
-- Reading sexp queries
---------------------------------------------------------------------------

--- Read one sexp query into the Lua form. Symbols and strings both become
--- Lua strings, `t` becomes true, `nil` false and `'x` is x.
---@param s string
---@return table|string|number|boolean
function M.read_sexp(s)
  local i, n = 1, #s
  local function skip()
    while i <= n do
      local c = s:sub(i, i)
      if c:match("%s") then
        i = i + 1
      elseif c == ";" then
        i = (s:find("\n", i, true) or n) + 1
      else
        return
      end
    end
  end
  local read
  read = function()
    skip()
    if i > n then
      error("unexpected end of query", 0)
    end
    local c = s:sub(i, i)
    if c == "'" or c == "`" then
      i = i + 1
      return read()
    elseif c == "(" then
      i = i + 1
      local list = {}
      while true do
        skip()
        if i > n then
          error("missing ) in query", 0)
        end
        if s:sub(i, i) == ")" then
          i = i + 1
          return list
        end
        list[#list + 1] = read()
      end
    elseif c == ")" then
      error("unexpected ) in query", 0)
    elseif c == '"' then
      local buf = {}
      i = i + 1
      while i <= n do
        local ch = s:sub(i, i)
        if ch == "\\" and i < n then
          local nx = s:sub(i + 1, i + 1)
          buf[#buf + 1] = nx == "n" and "\n" or nx == "t" and "\t" or nx
          i = i + 2
        elseif ch == '"' then
          i = i + 1
          return table.concat(buf)
        else
          buf[#buf + 1] = ch
          i = i + 1
        end
      end
      error("unterminated string in query", 0)
    end
    local atom = s:match("^[^%s()\"';]+", i)
    i = i + #atom
    if atom == "t" then
      return true
    elseif atom == "nil" then
      return false
    end
    return tonumber(atom) or atom
  end
  local v = read()
  skip()
  if i <= n then
    error("trailing text in query: " .. s:sub(i), 0)
  end
  return v
end

---------------------------------------------------------------------------
-- Reading plain queries
---------------------------------------------------------------------------

-- Split `s` at unquoted occurrences of `sep` (a single character class).
local function split_unquoted(s, sep)
  local out, cur, quoted = {}, {}, false
  for ch in s:gmatch(".") do
    if ch == '"' then
      quoted = not quoted
      cur[#cur + 1] = ch
    elseif not quoted and ch:match(sep) then
      if #cur > 0 then
        out[#out + 1] = table.concat(cur)
      end
      cur = {}
    else
      cur[#cur + 1] = ch
    end
  end
  if #cur > 0 then
    out[#out + 1] = table.concat(cur)
  end
  return out
end

local function unquote(s)
  return s:match('^"(.*)"$') or s
end

--- Read a plain query (`todo:NEXT tags:work !done "a phrase"`) into the
--- Lua form: space-separated terms are ANDed, `!` negates a term, commas
--- separate a predicate's arguments, `key=value` is a keyword argument and
--- a bare word is `(rifle word)` (the `default_predicate` option).
---@param s string
---@param default_predicate? string
---@return table
function M.read_plain(s, default_predicate)
  default_predicate = default_predicate or "rifle"
  local terms = { "and" }
  for _, tok in ipairs(split_unquoted(s, "%s")) do
    local neg = false
    if tok:sub(1, 1) == "!" then
      neg = true
      tok = tok:sub(2)
    end
    local name, args = tok:match("^([%w%-_&*]+):(.*)$")
    if name and not M.is_predicate(name) then
      -- not a predicate (a URL, a time, ...): the whole token is a word
      name = nil
    end
    local term
    if name then
      term = { name }
      for _, a in ipairs(split_unquoted(args, ",")) do
        local k, v = a:match("^([%w%-_]+)=(.*)$")
        if k and not a:match('^"') then
          term[#term + 1] = ":" .. k
          term[#term + 1] = tonumber(v) or unquote(v)
        else
          term[#term + 1] = unquote(a)
        end
      end
    else
      term = { default_predicate, unquote(tok) }
    end
    terms[#terms + 1] = neg and { "not", term } or term
  end
  if #terms == 2 then
    return terms[2]
  end
  return terms
end

--- Read a query given as a string (sexp when it starts with "("), or return
--- a Lua-form query as it is.
---@param q string|table
---@return table
function M.read(q)
  if type(q) == "table" then
    return q
  end
  q = vim.trim(q or "")
  if q == "" then
    error("empty query", 0)
  end
  if q:sub(1, 1) == "(" then
    local v = M.read_sexp(q)
    if type(v) ~= "table" then
      error("query must be a list: " .. q, 0)
    end
    return v
  end
  local opts = require("org.extensions").opts("ql") or {}
  return M.read_plain(q, opts.default_predicate)
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- Split predicate arguments into positional args and keyword args.
local function split_args(expr)
  local pos, kw = {}, {}
  local i = 2
  while i <= #expr do
    local a = expr[i]
    if type(a) == "string" and a:match("^:[%w%-_]+$") then
      kw[a:sub(2):gsub("%-", "_")] = expr[i + 1]
      i = i + 2
    else
      pos[#pos + 1] = a
      i = i + 1
    end
  end
  return pos, kw
end

local function lower(s)
  return tostring(s):lower()
end

local function regex(re)
  return require("org.agenda.search").compile_emacs_regexp(tostring(re))
end

local function matches(re, s)
  return re:match_str(s) ~= nil
end

-- The entry's own lines: headline to the end of its section.
local function entry_lines(hl)
  return vim.list_slice(hl.file.lines, hl.line, hl.body_end or hl.line)
end

local function entry_text(hl)
  return table.concat(entry_lines(hl), "\n")
end

-- Every timestamp in the entry (planning, title, body, clocks), active or not.
local ts_cache = setmetatable({}, { __mode = "k" })
local function entry_timestamps(hl)
  local key = hl
  local c = ts_cache[key]
  if c and c.raw == hl.raw then
    return c.list
  end
  local list = {}
  for _, l in ipairs(entry_lines(hl)) do
    for _, it in ipairs(date.parse_all(l)) do
      list[#list + 1] = it.date
    end
  end
  ts_cache[key] = { raw = hl.raw, list = list }
  return list
end

-- Minutes since day 0 of a date (its time, or `default_min`).
local function abs_min(d, default_min)
  return d:days() * 1440 + (d.hour and (d.hour * 60 + (d.min or 0)) or default_min)
end

--- A date argument: a number of days from today, "today", "now", an ISO
--- date or date-time, a timestamp, or an org.Date.
---@return table|nil date
---@return boolean has_time
local function date_arg(v)
  if v == nil or v == false then
    return nil, false
  end
  if type(v) == "table" and v.days then
    return v, v.hour ~= nil
  end
  if type(v) == "number" then
    return date.today():add(v, "d"), false
  end
  local s = tostring(v)
  local l = s:lower()
  if l == "today" then
    return date.today(), false
  elseif l == "now" then
    return date.now(), true
  elseif l == "tomorrow" then
    return date.today():add(1, "d"), false
  elseif l == "yesterday" then
    return date.today():add(-1, "d"), false
  end
  local n = tonumber(s)
  if n then
    return date.today():add(n, "d"), false
  end
  local y, mo, d, rest = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
  if y then
    local h, mi = rest:match("(%d%d?):(%d%d)")
    local dt = date.from_days(date.days_from_civil(tonumber(y), tonumber(mo), tonumber(d)))
    if h then
      dt = dt:clone({ hour = tonumber(h), min = tonumber(mi) })
    end
    return dt, h ~= nil
  end
  local parsed = date.parse(s:match("^[<%[]") and s or ("<" .. s .. ">"))
  if parsed then
    return parsed, parsed.hour ~= nil
  end
  error("invalid date in query: " .. s, 0)
end

-- `:with-time`: true, false or nil (either), also given as "t" / "nil".
local function with_time_arg(v)
  if v == "t" then
    return true
  elseif v == "nil" then
    return false
  end
  return v
end

--- A range test from :from / :to / :on keyword args and a single
--- positional argument: `single` is "to" (look forward: up to that day),
--- "on" (that day) or "past" (a number N means the last N days, as for
--- org-ql's clocked and closed; other values are a :from date).
local function range_test(pos, kw, single, repeats)
  local from, to = kw.from, kw.to
  if kw.on ~= nil then
    from, to = kw.on, kw.on
  end
  if pos[1] ~= nil and from == nil and to == nil then
    local n = tonumber(pos[1])
    if single == "to" then
      to = pos[1]
    elseif single == "on" then
      from, to = pos[1], pos[1]
    elseif n then
      from = -n
    else
      from = pos[1]
    end
  end
  local lo, hi
  if from ~= nil then
    local d = date_arg(from)
    lo = d and abs_min(d, 0)
  end
  if to ~= nil then
    -- a date without a time runs to the end of that day
    local d = date_arg(to)
    hi = d and abs_min(d, 1439)
  end
  local with_time = with_time_arg(kw.with_time)
  local function overlaps(ts)
    local s = abs_min(ts, 0)
    local e = s
    if ts.range_end and ts.range_end.days then
      e = abs_min(ts.range_end, 1439)
    elseif ts.end_hour then
      e = ts:days() * 1440 + ts.end_hour * 60 + (ts.end_min or 0)
    elseif not ts.hour then
      e = s + 1439
    end
    return (lo == nil or e >= lo) and (hi == nil or s <= hi)
  end
  return function(ts)
    if with_time == true and not ts.hour then
      return false
    elseif with_time == false and ts.hour then
      return false
    end
    local r = repeats and ts.repeater
    if r and (r.value or 0) > 0 and lo and ts:days() * 1440 < lo then
      -- a repeating timestamp matches when one of its occurrences does
      if not hi then
        return true
      end
      for _, occ in ipairs(date.occurrences(ts, math.floor(lo / 1440), math.floor(hi / 1440))) do
        if overlaps(occ) then
          return true
        end
      end
      return false
    end
    return overlaps(ts)
  end
end

-- Expand repeaters in date predicates (the `expand_repeaters` option).
local function repeats()
  local o = require("org.extensions").opts("ql")
  return not o or o.expand_repeaters ~= false
end

local function any_ts(list, test)
  for _, ts in ipairs(list) do
    if ts and test(ts) then
      return true
    end
  end
  return false
end

-- Priority as a number where higher is more important (A > B).
local function prio_num(p)
  return p and -(tostring(p):byte()) or nil
end

local COMPARATORS = {
  ["<"] = function(a, b)
    return a < b
  end,
  ["<="] = function(a, b)
    return a <= b
  end,
  [">"] = function(a, b)
    return a > b
  end,
  [">="] = function(a, b)
    return a >= b
  end,
  ["="] = function(a, b)
    return a == b
  end,
}

-- `(level 2)`, `(level 2 4)` or `(level '> 1)` on values from `get`.
local function numeric(pos, get, parse)
  parse = parse or tonumber
  local cmp = COMPARATORS[tostring(pos[1])]
  if cmp and pos[2] ~= nil then
    local n = parse(pos[2])
    if n == nil then
      error("invalid number in query: " .. tostring(pos[2]), 0)
    end
    return function(hl)
      local v = get(hl)
      return v ~= nil and n ~= nil and cmp(v, n)
    end
  elseif pos[2] ~= nil then
    local lo, hi = parse(pos[1]), parse(pos[2])
    if lo == nil or hi == nil then
      error("invalid numbers in query: " .. tostring(pos[1]) .. " " .. tostring(pos[2]), 0)
    end
    return function(hl)
      local v = get(hl)
      return v ~= nil and v >= lo and v <= hi
    end
  elseif pos[1] ~= nil then
    local n = parse(pos[1])
    if n == nil then
      error("invalid number in query: " .. tostring(pos[1]), 0)
    end
    return function(hl)
      return get(hl) == n
    end
  end
  return function(hl)
    return get(hl) ~= nil
  end
end

local function effort_of(hl)
  local v = hl:get_property(config.opts.effort_property or "Effort")
  return v and date.parse_duration(v) or nil
end

local function duration(v)
  if type(v) == "number" then
    return v
  end
  local m = date.parse_duration(tostring(v))
  if not m then
    error("invalid effort in query: " .. tostring(v), 0)
  end
  return m
end

local function plain_title(hl)
  return hl:plain_title()
end

local function contains_ci(hay, needle)
  return lower(hay):find(lower(needle), 1, true) ~= nil
end

local function all_strings(pos, fn)
  return function(hl)
    for _, s in ipairs(pos) do
      if not fn(hl, s) then
        return false
      end
    end
    return true
  end
end

local function any_value(values, list)
  for _, v in ipairs(values) do
    if vim.tbl_contains(list, v) then
      return true
    end
  end
  return false
end

local function tags_matching(list, pos)
  if #pos == 0 then
    return #list > 0
  end
  return any_value(pos, list)
end

-- Source blocks of the entry: { lang, lines }.
local function src_blocks(hl)
  local out, cur = {}, nil
  for _, l in ipairs(entry_lines(hl)) do
    local lang = l:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]%s*(%S*)")
    if lang then
      cur = { lang = lang, lines = {} }
    elseif cur and l:match("^%s*#%+[Ee][Nn][Dd]_[Ss][Rr][Cc]") then
      out[#out + 1] = cur
      cur = nil
    elseif cur then
      cur.lines[#cur.lines + 1] = l
    end
  end
  return out
end

local function each_descendant(hl, fn)
  for _, c in ipairs(hl.children or {}) do
    if fn(c) or each_descendant(c, fn) then
      return true
    end
  end
  return false
end

---------------------------------------------------------------------------
-- Predicates
---------------------------------------------------------------------------

local ALIASES = {
  h = "heading",
  ["h*"] = "heading-regexp",
  r = "regexp",
  smart = "rifle",
  olp = "outline-path",
  olps = "outline-path-segment",
  ["tags&"] = "tags-all",
  ["tags*"] = "tags-regexp",
  ["local-tags"] = "tags-local",
  ["tags-l"] = "tags-local",
  ltags = "tags-local",
  ["inherited-tags"] = "tags-inherited",
  ["tags-i"] = "tags-inherited",
  itags = "tags-inherited",
  ["ts-a"] = "ts-active",
  ["ts-i"] = "ts-inactive",
  ["&"] = "and",
  ["|"] = "or",
  ["!"] = "not",
}

local compile

local P = {}

P["and"] = function(pos)
  local subs = vim.tbl_map(compile, pos)
  return function(hl)
    for _, f in ipairs(subs) do
      if not f(hl) then
        return false
      end
    end
    return true
  end
end

P["or"] = function(pos)
  local subs = vim.tbl_map(compile, pos)
  return function(hl)
    for _, f in ipairs(subs) do
      if f(hl) then
        return true
      end
    end
    return false
  end
end

P["not"] = function(pos)
  local sub = compile(#pos == 1 and pos[1] or vim.list_extend({ "and" }, pos))
  return function(hl)
    return not sub(hl)
  end
end

P.todo = function(pos)
  if #pos == 0 then
    return function(hl)
      return hl.todo ~= nil and not hl:is_done()
    end
  end
  return function(hl)
    return hl.todo ~= nil and vim.tbl_contains(pos, hl.todo)
  end
end

P.done = function()
  return function(hl)
    return hl:is_done()
  end
end

P.tags = function(pos)
  return function(hl)
    return tags_matching(hl:get_tags(), pos)
  end
end

P["tags-all"] = function(pos)
  return function(hl)
    local list = hl:get_tags()
    for _, t in ipairs(pos) do
      if not vim.tbl_contains(list, t) then
        return false
      end
    end
    return true
  end
end

P["tags-local"] = function(pos)
  return function(hl)
    return tags_matching(hl.tags, pos)
  end
end

P["tags-inherited"] = function(pos)
  return function(hl)
    local own = {}
    for _, t in ipairs(hl.tags) do
      own[t] = true
    end
    local inherited = vim.tbl_filter(function(t)
      return not own[t]
    end, hl:get_tags())
    return tags_matching(inherited, pos)
  end
end

P["tags-regexp"] = function(pos)
  local res = vim.tbl_map(regex, pos)
  return function(hl)
    for _, t in ipairs(hl:get_tags()) do
      for _, re in ipairs(res) do
        if matches(re, t) then
          return true
        end
      end
    end
    return false
  end
end

P.priority = function(pos)
  local cmp = COMPARATORS[tostring(pos[1])]
  if cmp then
    if pos[2] == nil or tostring(pos[2]) == "" then
      error("priority: needs a priority after " .. tostring(pos[1]), 0)
    end
    local n = prio_num(pos[2])
    return function(hl)
      local v = prio_num(hl.priority)
      return v ~= nil and cmp(v, n)
    end
  end
  return function(hl)
    if hl.priority == nil then
      return false
    end
    return #pos == 0 or vim.tbl_contains(vim.tbl_map(tostring, pos), hl.priority)
  end
end

local function planning_pred(kinds, single)
  return function(pos, kw)
    local auto = pos[1] == "auto"
    local test
    if auto then
      pos = {}
    end
    if #pos > 0 or kw.from ~= nil or kw.to ~= nil or kw.on ~= nil or kw.with_time ~= nil then
      test = range_test(pos, kw, single, single ~= "past" and repeats())
    end
    return function(hl)
      for _, k in ipairs(kinds) do
        local ts = hl.planning and hl.planning[k]
        if ts then
          if auto then
            local warn = date.warning_days(ts, config.opts.deadline_warning_days or 14)
            if ts:days() <= date.today_days() + warn then
              return true
            end
          elseif not test or test(ts) then
            return true
          end
        end
      end
      return false
    end
  end
end

-- a single number looks forward for deadline / scheduled / planning and
-- back for closed (org-ql's "forward-" and "backward-looking" predicates)
P.deadline = planning_pred({ "deadline" }, "to")
P.scheduled = planning_pred({ "scheduled" }, "to")
P.closed = planning_pred({ "closed" }, "past")
P.planning = planning_pred({ "deadline", "scheduled", "closed" }, "to")

local function ts_pred(active)
  return function(pos, kw)
    -- (ts N) is (ts :to N), as in org-ql
    local test = range_test(pos, kw, "to", repeats())
    return function(hl)
      return any_ts(entry_timestamps(hl), function(ts)
        if active ~= nil and ts.active ~= active then
          return false
        end
        return test(ts)
      end)
    end
  end
end

P.ts = ts_pred(nil)
P["ts-active"] = ts_pred(true)
P["ts-inactive"] = ts_pred(false)

-- Only finished clocks count: a running clock is ignored, as in org-ql.
P.clocked = function(pos, kw)
  local any = #pos == 0 and kw.from == nil and kw.to == nil and kw.on == nil
  local test = not any and range_test(pos, kw, "past") or nil
  return function(hl)
    for _, c in ipairs(hl.clocks or {}) do
      if c["end"] then
        if any or test(c.start:clone({ range_end = c["end"] })) then
          return true
        end
      end
    end
    return false
  end
end

P.property = function(pos, kw)
  local name, value = pos[1], pos[2]
  if not name then
    error("property: needs a property name", 0)
  end
  local inherit = kw.inherit
  return function(hl)
    local v = hl:get_property(tostring(name), inherit)
    if v == nil then
      return false
    end
    return value == nil or v == tostring(value)
  end
end

P.heading = function(pos)
  return all_strings(pos, function(hl, s)
    return contains_ci(plain_title(hl), s)
  end)
end

P["heading-regexp"] = function(pos)
  local res = vim.tbl_map(regex, pos)
  return function(hl)
    local t = plain_title(hl)
    for _, re in ipairs(res) do
      if not matches(re, t) then
        return false
      end
    end
    return true
  end
end

P.regexp = function(pos)
  local res = vim.tbl_map(regex, pos)
  return function(hl)
    local text = entry_text(hl)
    for _, re in ipairs(res) do
      if not matches(re, text) then
        return false
      end
    end
    return true
  end
end

P.rifle = function(pos)
  return all_strings(pos, function(hl, s)
    return contains_ci(entry_text(hl), s) or contains_ci(table.concat(hl:outline_path(), "/"), s)
  end)
end

P.level = function(pos)
  return numeric(pos, function(hl)
    return hl.level
  end)
end

P.effort = function(pos)
  return numeric(pos, effort_of, duration)
end

P.path = function(pos)
  local res = vim.tbl_map(regex, pos)
  return function(hl)
    local f = hl.file.filename or ""
    if #res == 0 then
      return f ~= ""
    end
    for _, re in ipairs(res) do
      if matches(re, f) then
        return true
      end
    end
    return false
  end
end

P.category = function(pos)
  return function(hl)
    local c = hl:get_category()
    return #pos == 0 and c ~= nil or vim.tbl_contains(vim.tbl_map(tostring, pos), c)
  end
end

P.habit = function()
  return function(hl)
    return require("org.agenda.habits").is_habit(hl)
  end
end

P.blocked = function()
  return function(hl)
    local ok, todo = pcall(require, "org.todo")
    if not ok or not hl.todo or hl:is_done() then
      return false
    end
    local ok2, reason = pcall(todo.blocked_reason, hl)
    return ok2 and reason ~= nil
  end
end

-- Each string is in some outline path segment, in any order, as in org-ql
-- (`(olp "Fruit" "Food")` matches Food/Fruits/Grapes).
P["outline-path"] = function(pos)
  return function(hl)
    local olp = hl:outline_path()
    olp[#olp + 1] = plain_title(hl)
    for _, s in ipairs(pos) do
      local found = false
      for _, seg in ipairs(olp) do
        if contains_ci(seg, s) then
          found = true
          break
        end
      end
      if not found then
        return false
      end
    end
    return true
  end
end

-- The strings match consecutive outline path segments.
P["outline-path-segment"] = function(pos)
  return function(hl)
    local olp = hl:outline_path()
    olp[#olp + 1] = plain_title(hl)
    for start = 1, #olp - #pos + 1 do
      local ok = true
      for k, s in ipairs(pos) do
        if not contains_ci(olp[start + k - 1], s) then
          ok = false
          break
        end
      end
      if ok then
        return true
      end
    end
    return #pos == 0
  end
end

P.parent = function(pos)
  local sub = pos[1] and compile(pos[1])
  return function(hl)
    return hl.parent ~= nil and (not sub or sub(hl.parent))
  end
end

P.ancestors = function(pos)
  local sub = pos[1] and compile(pos[1])
  return function(hl)
    local h = hl.parent
    while h do
      if not sub or sub(h) then
        return true
      end
      h = h.parent
    end
    return false
  end
end

P.children = function(pos)
  local sub = pos[1] and compile(pos[1])
  return function(hl)
    for _, c in ipairs(hl.children or {}) do
      if not sub or sub(c) then
        return true
      end
    end
    return false
  end
end

P.descendants = function(pos)
  local sub = pos[1] and compile(pos[1])
  return function(hl)
    return each_descendant(hl, function(c)
      return not sub or sub(c)
    end)
  end
end

P.src = function(pos, kw)
  local lang = kw.lang and lower(kw.lang)
  local regexps = kw.regexps or pos
  if type(regexps) ~= "table" then
    regexps = { regexps }
  end
  local res = vim.tbl_map(regex, regexps)
  return function(hl)
    for _, b in ipairs(src_blocks(hl)) do
      if not lang or lower(b.lang) == lang then
        local body = table.concat(b.lines, "\n")
        local ok = true
        for _, re in ipairs(res) do
          if not matches(re, body) then
            ok = false
            break
          end
        end
        if ok then
          return true
        end
      end
    end
    return false
  end
end

P.link = function(pos, kw)
  local any = pos[1]
  local desc, target = kw.description, kw.target
  local regexp_p = kw.regexp_p
  local function test(s, pat)
    if pat == nil then
      return true
    end
    if regexp_p then
      return matches(regex(pat), s)
    end
    return contains_ci(s, pat)
  end
  return function(hl)
    for _, l in ipairs(entry_lines(hl)) do
      for t, d in l:gmatch("%[%[(.-)%]%[?(.-)%]?%]") do
        local both = t .. " " .. d
        if test(both, any) and test(d, desc) and test(t, target) then
          return true
        end
      end
    end
    return false
  end
end

P.pred = function(pos)
  local fn = pos[1]
  if type(fn) ~= "function" then
    error("pred: needs a Lua function", 0)
  end
  return function(hl)
    return fn(hl) and true or false
  end
end

M.predicates = P
M.aliases = ALIASES

--- Whether `name` is a predicate or an alias of one.
---@param name string
---@return boolean
function M.is_predicate(name)
  local n = name:lower()
  return P[ALIASES[n] or n] ~= nil
end

--- Compile a Lua-form query to `fun(headline): boolean`.
---@param expr table|string|function
---@return fun(hl: org.Headline): boolean
compile = function(expr)
  if type(expr) == "function" then
    return expr
  elseif type(expr) == "string" then
    -- a bare string in a query is a regexp, as in org-ql
    return P.regexp({ expr })
  elseif expr == true then
    return function()
      return true
    end
  elseif type(expr) ~= "table" or type(expr[1]) ~= "string" then
    error("invalid query term: " .. vim.inspect(expr), 0)
  end
  local name = expr[1]:lower()
  name = ALIASES[name] or name
  local fn = P[name]
  if not fn then
    error("unknown query predicate: " .. expr[1], 0)
  end
  local pos, kw = split_args(expr)
  return fn(pos, kw)
end

--- Compile a query (any form) to a headline predicate.
---@param q string|table
---@return fun(hl: org.Headline): boolean
function M.compile(q)
  return compile(M.read(q))
end

-- file -> cache key -> headline line -> result; the parse of a file is
-- replaced when it changes (buffer changedtick, file mtime), which drops
-- its results
local results = setmetatable({}, { __mode = "k" })

--- Forget cached results (run by setup, as options change what matches).
function M.clear_cache()
  results = setmetatable({}, { __mode = "k" })
end

-- The cache key of a query, or nil when it can't be cached (Lua functions,
-- "now").
local function cache_key(expr)
  local has_fn = false
  local function walk(v)
    if type(v) == "function" then
      has_fn = true
    elseif type(v) == "table" then
      for _, x in pairs(v) do
        walk(x)
      end
    end
  end
  walk(expr)
  if has_fn then
    return nil
  end
  local key = vim.inspect(expr, { newline = " ", indent = "" })
  if key:lower():find('"now"', 1, true) then
    return nil
  end
  return key .. "\0" .. date.today_days()
end

--- Compile a query to a predicate that remembers its result for each
--- headline until the headline's file changes.
---@param q string|table
---@return fun(hl: org.Headline): boolean
function M.compile_cached(q)
  local expr = M.read(q)
  local pred = compile(expr)
  local key = cache_key(expr)
  if not key then
    return pred
  end
  return function(hl)
    local f = hl.file
    if not f then
      return pred(hl)
    end
    local byfile = results[f]
    if not byfile then
      byfile = {}
      results[f] = byfile
    end
    local r = byfile[key]
    if not r then
      r = {}
      byfile[key] = r
    end
    local v = r[hl.line]
    if v == nil then
      v = pred(hl) and true or false
      r[hl.line] = v
    end
    return v
  end
end

--- Like `compile`, but returns nil and the error message on failure.
---@return (fun(hl: org.Headline): boolean)|nil
---@return string|nil err
function M.try_compile(q, cached)
  local ok, res = pcall(cached and M.compile_cached or M.compile, q)
  if ok then
    return res
  end
  return nil, tostring(res)
end

---------------------------------------------------------------------------
-- Sorting
---------------------------------------------------------------------------

local function planning_day(hl, kinds)
  local best
  for _, k in ipairs(kinds) do
    local ts = hl.planning and hl.planning[k]
    if ts then
      local v = abs_min(ts, 0)
      if not best or v < best then
        best = v
      end
    end
  end
  return best
end

-- Ascending by key; entries without a key go last.
local function by_key(key)
  return function(a, b)
    local ka, kb = key(a), key(b)
    if ka == nil then
      return false
    elseif kb == nil then
      return true
    end
    return ka < kb
  end
end

local SORTERS = {
  -- the deadline, else the scheduled date (org-ql--date<)
  date = by_key(function(hl)
    return planning_day(hl, { "deadline" }) or planning_day(hl, { "scheduled" })
  end),
  deadline = by_key(function(hl)
    return planning_day(hl, { "deadline" })
  end),
  scheduled = by_key(function(hl)
    return planning_day(hl, { "scheduled" })
  end),
  closed = by_key(function(hl)
    return planning_day(hl, { "closed" })
  end),
  priority = by_key(function(hl)
    return hl.priority and hl.priority:byte() or nil
  end),
  todo = by_key(function(hl)
    if not hl.todo then
      return nil
    end
    local names = hl.file.settings.todo:names()
    for i, n in ipairs(names) do
      if n == hl.todo then
        return i
      end
    end
    return #names + 1
  end),
}
M.sorters = SORTERS

local function stable_sort(list, less)
  local indexed = {}
  for i, v in ipairs(list) do
    indexed[i] = { v, i }
  end
  table.sort(indexed, function(a, b)
    if less(a[1], b[1]) then
      return true
    elseif less(b[1], a[1]) then
      return false
    end
    return a[2] < b[2]
  end)
  for i, p in ipairs(indexed) do
    list[i] = p[1]
  end
end

--- Sort `list` in place with org-ql sorters: a name (date, deadline,
--- scheduled, closed, priority, todo, random, reverse), a comparator
--- `fun(a, b): boolean`, or a list of those. As in org-ql, a list is
--- applied in order with stable sorts, so the last sorter is the primary
--- key: `{ "priority", "date" }` sorts by date, then priority, and
--- `{ "date", "reverse" }` is newest first.
--- `get` maps a list element to its headline (default: the element).
---@param list any[]
---@param sort string|function|(string|function)[]|nil
---@param get? fun(x: any): org.Headline
function M.sort(list, sort, get)
  if sort == nil or sort == false then
    return list
  end
  local sorters = (type(sort) == "table") and sort or { sort }
  get = get or function(x)
    return x
  end
  for _, s in ipairs(sorters) do
    if s == "reverse" then
      local n = #list
      for k = 1, math.floor(n / 2) do
        list[k], list[n - k + 1] = list[n - k + 1], list[k]
      end
    elseif s == "random" then
      for k = #list, 2, -1 do
        local j = math.random(k)
        list[k], list[j] = list[j], list[k]
      end
    else
      local less = type(s) == "function" and s or SORTERS[s]
      if not less then
        utils.error("org-ql: unknown sorter " .. tostring(s))
      else
        stable_sort(list, function(a, b)
          return less(get(a), get(b))
        end)
      end
    end
  end
  return list
end

return M
