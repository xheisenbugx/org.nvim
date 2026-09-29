---@mod org.export.csl.regex Emacs regular expressions (for the citeproc port)
---
--- A small backtracking matcher for the Emacs regexp syntax citeproc-el
--- uses: `\(...\)`, `\(?:...\)`, `\(?N:...\)`, `\|`, `* + ?` (and their
--- lazy forms), `\{n,m\}`, `[...]` with ranges and `[:class:]`, `.`,
--- `^ $ \` \'`, `\b \B \< \>`, `\w \W \sC \SC` and the categories `\cl`
--- (Latin), `\cy` (Cyrillic) and `\cg` (Greek). Matching works on
--- characters, not bytes; positions in the API are 0-based character
--- offsets like Emacs string positions. `case_fold` follows the default of
--- `case-fold-search` (t) unless an option says otherwise.

local U = require("org.export.csl.util")

local R = {}

---------------------------------------------------------------------------
-- Character classes
---------------------------------------------------------------------------

local lower, upper = U.lower_cp, U.upper_cp

local function is_digit(c)
  return c >= 48 and c <= 57
end

local function is_space_syntax(c)
  return c == 32 or c == 9 or c == 10 or c == 12 or c == 13
end

local CLASSES = {
  alpha = function(c)
    return U.is_alpha_cp(c)
  end,
  digit = is_digit,
  alnum = function(c)
    return is_digit(c) or U.is_alpha_cp(c)
  end,
  space = function(c)
    return is_space_syntax(c) or c == 11 or c == 0xA0 or (c >= 0x2000 and c <= 0x200A) or c == 0x3000
  end,
  blank = function(c)
    return c == 32 or c == 9 or c == 0xA0 or (c >= 0x2000 and c <= 0x200A)
  end,
  upper = function(c)
    return lower(c) ~= c
  end,
  lower = function(c)
    return upper(c) ~= c
  end,
  punct = function(c)
    if c < 128 then
      return (c >= 33 and c <= 47) or (c >= 58 and c <= 64) or (c >= 91 and c <= 96) or (c >= 123 and c <= 126)
    end
    return not U.is_word_cp(c)
  end,
  word = function(c)
    return U.is_word_cp(c)
  end,
  xdigit = function(c)
    return is_digit(c) or (c >= 65 and c <= 70) or (c >= 97 and c <= 102)
  end,
  cntrl = function(c)
    return c < 32
  end,
  print = function(c)
    return c >= 32 and c ~= 127
  end,
  graph = function(c)
    return c > 32 and c ~= 127
  end,
  ascii = function(c)
    return c < 128
  end,
  nonascii = function(c)
    return c >= 128
  end,
}

local function syntax_test(class)
  if class == " " or class == "-" then
    return is_space_syntax
  elseif class == "w" then
    return U.is_word_cp
  elseif class == "_" then
    return function(c)
      return c == 95 or c == 36 or c == 38 or c == 42 or c == 43 or c == 45 or c == 60 or c == 62
    end
  elseif class == "." then
    return CLASSES.punct
  elseif class == "(" then
    return function(c)
      return c == 40 or c == 91 or c == 123
    end
  elseif class == ")" then
    return function(c)
      return c == 41 or c == 93 or c == 125
    end
  elseif class == '"' then
    return function(c)
      return c == 34
    end
  end
  return function()
    return false
  end
end

local function category_test(cat)
  if cat == "l" then
    return function(c)
      return (c >= 32 and c <= 0x24F)
        or (c >= 0x250 and c <= 0x2AF)
        or (c >= 0x1E00 and c <= 0x1EFF)
        or (c >= 0x2C60 and c <= 0x2C7F)
        or (c >= 0xA720 and c <= 0xA7FF)
    end
  elseif cat == "y" then
    return function(c)
      return (c >= 32 and c < 128) or (c >= 0x400 and c <= 0x52F)
    end
  elseif cat == "g" then
    return function(c)
      return (c >= 32 and c < 128) or (c >= 0x370 and c <= 0x3FF) or (c >= 0x1F00 and c <= 0x1FFF)
    end
  end
  return function()
    return false
  end
end

---------------------------------------------------------------------------
-- Parser
---------------------------------------------------------------------------

local cache = {}

local function parse(pat)
  local cps = U.codepoints(pat)
  local n = #cps
  local i = 1
  local ngroups = 0

  local parse_alt

  local function peek(k)
    return cps[i + (k or 0)]
  end

  local function parse_set()
    -- at the char after "["
    local set = { t = "set", neg = false, ranges = {}, classes = {} }
    if peek() == 94 then -- ^
      set.neg = true
      i = i + 1
    end
    local first = true
    while i <= n do
      local c = cps[i]
      if c == 93 and not first then -- ]
        i = i + 1
        return set
      end
      first = false
      if c == 91 and cps[i + 1] == 58 then -- [:
        local j = i + 2
        local name = {}
        while j <= n and not (cps[j] == 58 and cps[j + 1] == 93) do
          name[#name + 1] = U.char(cps[j])
          j = j + 1
        end
        set.classes[#set.classes + 1] = CLASSES[table.concat(name)] or function()
          return false
        end
        i = j + 2
      else
        local lo = c
        i = i + 1
        if cps[i] == 45 and cps[i + 1] and cps[i + 1] ~= 93 then -- a-b
          local hi = cps[i + 1]
          i = i + 2
          set.ranges[#set.ranges + 1] = { lo, hi }
        else
          set.ranges[#set.ranges + 1] = { lo, lo }
        end
      end
    end
    error("unterminated [ in regexp: " .. pat)
  end

  local function parse_atom(seq)
    local c = cps[i]
    if c == 92 then -- backslash
      local d = cps[i + 1]
      i = i + 2
      if d == 40 then -- \(
        local num
        if cps[i] == 63 then -- ?
          if cps[i + 1] == 58 then
            i = i + 2
          else
            local j = i + 1
            local digits = {}
            while cps[j] and is_digit(cps[j]) do
              digits[#digits + 1] = U.char(cps[j])
              j = j + 1
            end
            num = tonumber(table.concat(digits))
            if num and num > ngroups then
              ngroups = num
            end
            i = j + 1 -- skip ":"
          end
        else
          ngroups = ngroups + 1
          num = ngroups
        end
        local alts = parse_alt()
        -- expect \)
        if cps[i] == 92 and cps[i + 1] == 41 then
          i = i + 2
        else
          error("unmatched \\( in regexp: " .. pat)
        end
        return { t = "group", n = num, alts = alts }
      elseif d == 96 then -- \`
        return { t = "bos" }
      elseif d == 39 then -- \'
        return { t = "eos" }
      elseif d == 98 then -- \b
        return { t = "wordb" }
      elseif d == 66 then -- \B
        return { t = "notwordb" }
      elseif d == 60 then -- \<
        return { t = "wstart" }
      elseif d == 62 then -- \>
        return { t = "wend" }
      elseif d == 95 then -- \_< \_>
        local e = cps[i]
        i = i + 1
        return { t = e == 60 and "symstart" or "symend" }
      elseif d == 119 then -- \w
        return { t = "test", f = U.is_word_cp }
      elseif d == 87 then -- \W
        return {
          t = "test",
          f = function(x)
            return not U.is_word_cp(x)
          end,
        }
      elseif d == 115 or d == 83 then -- \sC \SC
        local class = U.char(cps[i])
        i = i + 1
        local f = syntax_test(class)
        if d == 83 then
          return {
            t = "test",
            f = function(x)
              return not f(x)
            end,
          }
        end
        return { t = "test", f = f }
      elseif d == 99 or d == 67 then -- \cC \CC
        local f = category_test(U.char(cps[i]))
        i = i + 1
        if d == 67 then
          return {
            t = "test",
            f = function(x)
              return not f(x)
            end,
          }
        end
        return { t = "test", f = f }
      elseif d and d >= 49 and d <= 57 then -- \1 backreference
        return { t = "backref", n = d - 48 }
      else
        return { t = "char", cp = d }
      end
    elseif c == 91 then
      i = i + 1
      return parse_set()
    elseif c == 46 then
      i = i + 1
      return { t = "any" }
    elseif c == 94 and (#seq == 0) then
      i = i + 1
      return { t = "bol" }
    elseif c == 36 then
      -- $ is special at the end of the pattern or before \) or \|
      local nx, nx2 = cps[i + 1], cps[i + 2]
      if nx == nil or (nx == 92 and (nx2 == 41 or nx2 == 124)) then
        i = i + 1
        return { t = "eol" }
      end
      i = i + 1
      return { t = "char", cp = c }
    else
      i = i + 1
      return { t = "char", cp = c }
    end
  end

  local function parse_seq()
    local seq = {}
    while i <= n do
      local c = cps[i]
      if c == 92 and (cps[i + 1] == 124 or cps[i + 1] == 41) then
        break
      end
      if (c == 42 or c == 43 or c == 63) and #seq > 0 and seq[#seq].t ~= "bol" then
        i = i + 1
        local lazy = false
        if cps[i] == 63 then
          lazy = true
          i = i + 1
        end
        local node = table.remove(seq)
        local min, max = 0, math.huge
        if c == 43 then
          min = 1
        elseif c == 63 then
          max = 1
        end
        seq[#seq + 1] = { t = "rep", node = node, min = min, max = max, lazy = lazy }
      elseif c == 92 and cps[i + 1] == 123 and #seq > 0 then -- \{n,m\}
        local j = i + 2
        local a, b = {}, nil
        while cps[j] and is_digit(cps[j]) do
          a[#a + 1] = U.char(cps[j])
          j = j + 1
        end
        local min = tonumber(table.concat(a)) or 0
        local max = min
        if cps[j] == 44 then
          j = j + 1
          b = {}
          while cps[j] and is_digit(cps[j]) do
            b[#b + 1] = U.char(cps[j])
            j = j + 1
          end
          max = tonumber(table.concat(b)) or math.huge
        end
        i = j + 2 -- skip \}
        local node = table.remove(seq)
        seq[#seq + 1] = { t = "rep", node = node, min = min, max = max, lazy = false }
      else
        seq[#seq + 1] = parse_atom(seq)
      end
    end
    return seq
  end

  parse_alt = function()
    local alts = { parse_seq() }
    while cps[i] == 92 and cps[i + 1] == 124 do
      i = i + 2
      alts[#alts + 1] = parse_seq()
    end
    return alts
  end

  local alts = parse_alt()
  return { t = "group", n = 0, alts = alts }, ngroups
end

local function compile(pat)
  local c = cache[pat]
  if not c then
    local ast, ng = parse(pat)
    c = { ast = ast, ngroups = ng }
    cache[pat] = c
  end
  return c
end

---------------------------------------------------------------------------
-- Matcher
---------------------------------------------------------------------------

local function fold(c)
  return lower(c)
end

local function set_match(node, c, cf)
  local hit = false
  for _, r in ipairs(node.ranges) do
    if c >= r[1] and c <= r[2] then
      hit = true
      break
    end
    if cf then
      local lc, uc = lower(c), upper(c)
      if (lc >= r[1] and lc <= r[2]) or (uc >= r[1] and uc <= r[2]) then
        hit = true
        break
      end
    end
  end
  if not hit then
    for _, f in ipairs(node.classes) do
      if f(c) then
        hit = true
        break
      end
      if cf and (f == CLASSES.upper or f == CLASSES.lower) and (lower(c) ~= c or upper(c) ~= c) then
        hit = true
        break
      end
    end
  end
  if node.neg then
    return not hit
  end
  return hit
end

local function word_at(cps, p)
  local c = cps[p]
  return c ~= nil and U.is_word_cp(c)
end

--- Try to match at `pos`. Returns end position and captures, or nil.
local function run(prog, cps, pos, cf)
  local n = #cps
  local caps = {}
  local m_node, m_seq

  m_seq = function(seq, k, p, cont)
    if k > #seq then
      return cont(p)
    end
    return m_node(seq[k], p, function(q)
      return m_seq(seq, k + 1, q, cont)
    end)
  end

  m_node = function(node, p, cont)
    local t = node.t
    if t == "char" then
      local c = cps[p]
      if c ~= nil and (c == node.cp or (cf and fold(c) == fold(node.cp))) then
        return cont(p + 1)
      end
      return false
    elseif t == "any" then
      local c = cps[p]
      if c ~= nil and c ~= 10 then
        return cont(p + 1)
      end
      return false
    elseif t == "set" then
      local c = cps[p]
      if c ~= nil and set_match(node, c, cf) then
        return cont(p + 1)
      end
      return false
    elseif t == "test" then
      local c = cps[p]
      if c ~= nil and node.f(c) then
        return cont(p + 1)
      end
      return false
    elseif t == "group" then
      for _, alt in ipairs(node.alts) do
        local saved = node.n and caps[node.n]
        local ok = m_seq(alt, 1, p, function(q)
          local old = node.n and caps[node.n]
          if node.n then
            caps[node.n] = { p, q }
          end
          if cont(q) then
            return true
          end
          if node.n then
            caps[node.n] = old
          end
          return false
        end)
        if ok then
          return true
        end
        if node.n then
          caps[node.n] = saved
        end
      end
      return false
    elseif t == "rep" then
      local min, max, sub = node.min, node.max, node.node
      local function try(count, q)
        if node.lazy then
          if count >= min and cont(q) then
            return true
          end
          if count < max then
            return m_node(sub, q, function(r)
              if r == q and count >= min then
                return false
              end
              return try(count + 1, r)
            end)
          end
          return false
        end
        if count < max then
          local ok = m_node(sub, q, function(r)
            if r == q and count >= min then
              return false
            end
            return try(count + 1, r)
          end)
          if ok then
            return true
          end
        end
        if count >= min then
          return cont(q)
        end
        return false
      end
      return try(0, p)
    elseif t == "bol" then
      if p == 1 or cps[p - 1] == 10 then
        return cont(p)
      end
      return false
    elseif t == "eol" then
      if p == n + 1 or cps[p] == 10 then
        return cont(p)
      end
      return false
    elseif t == "bos" then
      if p == 1 then
        return cont(p)
      end
      return false
    elseif t == "eos" then
      if p == n + 1 then
        return cont(p)
      end
      return false
    elseif t == "wordb" then
      if word_at(cps, p - 1) ~= word_at(cps, p) then
        return cont(p)
      end
      return false
    elseif t == "notwordb" then
      if word_at(cps, p - 1) == word_at(cps, p) then
        return cont(p)
      end
      return false
    elseif t == "wstart" then
      if not word_at(cps, p - 1) and word_at(cps, p) then
        return cont(p)
      end
      return false
    elseif t == "wend" then
      if word_at(cps, p - 1) and not word_at(cps, p) then
        return cont(p)
      end
      return false
    elseif t == "symstart" or t == "symend" then
      local function sym(q)
        local c = cps[q]
        return c ~= nil and (U.is_word_cp(c) or c == 95 or c == 45)
      end
      if t == "symstart" and not sym(p - 1) and sym(p) then
        return cont(p)
      elseif t == "symend" and sym(p - 1) and not sym(p) then
        return cont(p)
      end
      return false
    elseif t == "backref" then
      local cap = caps[node.n]
      if not cap then
        return false
      end
      local len = cap[2] - cap[1]
      for k = 0, len - 1 do
        local a, b = cps[cap[1] + k], cps[p + k]
        if b == nil or (a ~= b and not (cf and fold(a) == fold(b))) then
          return false
        end
      end
      return cont(p + len)
    end
    error("bad regexp node " .. tostring(t))
  end

  local final
  local ok = m_node(prog.ast, pos, function(q)
    final = q
    return true
  end)
  if ok then
    caps[0] = { pos, final }
    return caps
  end
end

---------------------------------------------------------------------------
-- API
---------------------------------------------------------------------------

---@class org.csl.MatchData
---@field cps integer[]
---@field groups table<integer, integer[]> 0-based [begin, end)

local MD = {}
MD.__index = MD

--- Substring of group `k`, or nil.
function MD:str(k)
  local g = self.groups[k or 0]
  if not g then
    return nil
  end
  return U.from_codepoints(self.cps, g[1] + 1, g[2])
end

function MD:b(k)
  local g = self.groups[k or 0]
  return g and g[1]
end

function MD:e(k)
  local g = self.groups[k or 0]
  return g and g[2]
end

local function decode(s)
  if type(s) == "table" then
    return s
  end
  return U.codepoints(s)
end

--- string-match: search `re` in `s` from 0-based `start`. Returns the
--- 0-based begin and the match data, or nil.
---@param opts? { case_fold?: boolean }
function R.search(re, s, start, opts)
  local prog = compile(re)
  local cps = decode(s)
  local cf = not (opts and opts.case_fold == false)
  for p = (start or 0) + 1, #cps + 1 do
    local caps = run(prog, cps, p, cf)
    if caps then
      local groups = {}
      for k, v in pairs(caps) do
        groups[k] = { v[1] - 1, v[2] - 1 }
      end
      return p - 1, setmetatable({ cps = cps, groups = groups }, MD)
    end
  end
  return nil
end

--- Match anchored at 0-based `pos` (looking-at).
function R.looking_at(re, s, pos, opts)
  local prog = compile(re)
  local cps = decode(s)
  local cf = not (opts and opts.case_fold == false)
  local caps = run(prog, cps, (pos or 0) + 1, cf)
  if caps then
    local groups = {}
    for k, v in pairs(caps) do
      groups[k] = { v[1] - 1, v[2] - 1 }
    end
    return setmetatable({ cps = cps, groups = groups }, MD)
  end
end

--- s-matches-p / string-match-p
function R.test(re, s, opts)
  return R.search(re, s, 0, opts) ~= nil
end

--- s-match: list of group strings (index 0 is the whole match) or nil.
function R.match(re, s, opts)
  local b, md = R.search(re, s, 0, opts)
  if not b then
    return nil
  end
  local out = {}
  local ng = compile(re).ngroups
  for k = 0, ng do
    out[k] = md:str(k)
  end
  out.n = ng
  return out
end

--- Expand a replacement string with \N and \& (replace-match, not literal).
local function expand(rep, md)
  return (rep:gsub("\\([%d&\\])", function(c)
    if c == "&" then
      return md:str(0) or ""
    elseif c == "\\" then
      return "\\"
    end
    return md:str(tonumber(c)) or ""
  end))
end

--- replace-regexp-in-string: `rep` is a string (with \N unless `literal`)
--- or a function of the matched string (called with the match data too).
---@param opts? { case_fold?: boolean, literal?: boolean }
function R.replace(re, rep, s, opts)
  opts = opts or {}
  local cps = U.codepoints(s)
  local out = {}
  local start = 0
  local n = #cps
  while start < n do
    local b, md = R.search(re, cps, start, opts)
    if not b then
      break
    end
    local e = md:e(0)
    out[#out + 1] = U.from_codepoints(cps, start + 1, b)
    local r
    if type(rep) == "function" then
      r = rep(md:str(0), md)
    elseif opts.literal then
      r = rep
    else
      r = expand(rep, md)
    end
    out[#out + 1] = r
    if e == b then
      -- empty match: keep the next character
      e = math.min(n, b + 1)
      out[#out + 1] = U.from_codepoints(cps, b + 1, e)
    end
    start = e
  end
  out[#out + 1] = U.from_codepoints(cps, start + 1, n)
  return table.concat(out)
end

--- split-string (without TRIM): `omit_nulls` drops empty parts.
function R.split(s, re, omit_nulls, opts)
  local cps = U.codepoints(s)
  local n = #cps
  local out = {}
  local keep_nulls = not omit_nulls
  local start = 0
  local notfirst = false
  local last_mb
  local function push(a, b)
    if keep_nulls or a < b then
      out[#out + 1] = U.from_codepoints(cps, a + 1, b)
    end
  end
  while true do
    local from = start
    if notfirst and last_mb == start and start < n then
      from = start + 1
    end
    local b, md = R.search(re, cps, from, opts)
    if not b or not (start < n) then
      break
    end
    notfirst = true
    local this_start = start
    last_mb = b
    start = md:e(0)
    push(this_start, b)
  end
  push(start, n)
  return out
end

--- citeproc-s-slice-by-matches
function R.slice_by_matches(s, re, start, annot)
  start = start or 0
  local cps = U.codepoints(s)
  local b, md = R.search(re, cps, start)
  if not b then
    return { annot and { s, true } or s }
  end
  local e = md:e(0)
  if b == start and e == start then
    return R.slice_by_matches(s, re, start + 1, annot)
  end
  local result = R.slice_by_matches(U.from_codepoints(cps, e + 1, #cps), re, 0, annot)
  if b ~= e then
    local slice = U.from_codepoints(cps, b + 1, e)
    table.insert(result, 1, annot and { slice, false } or slice)
  end
  if b ~= 0 then
    local slice = U.from_codepoints(cps, 1, b)
    table.insert(result, 1, annot and { slice, true } or slice)
  end
  return result
end

return R
