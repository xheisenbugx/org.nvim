---@mod org.lint.object org-lint: the object parser and `parse`

local util = require("org.lint.util")
local data = require("org.lint.data")
local timestamp = require("org.lint.timestamp")
local element = require("org.lint.element")

local trim = util.trim
local nw = util.nw
local balanced = util.balanced
local word_char = util.word_char
local LINK_TYPES = data.LINK_TYPES
local parse_timestamp = timestamp.parse_timestamp
local Doc = element.Doc
local new_el = element.new_el

---------------------------------------------------------------------------
-- Document model: objects
---------------------------------------------------------------------------

---@class org.lint.Object
---@field type string
---@field b integer start offset in the container string
---@field e integer end offset (exclusive, trailing blanks included)
---@field cb integer|nil contents start offset
---@field ce integer|nil contents end offset (exclusive)
---@field parent org.lint.Object|nil enclosing object
---@field element org.lint.Element container element
---@field lnum integer
---@field col integer
---@field pos fun(offset: integer): integer, integer line and column of an offset

local ENTITIES
local function is_entity(name)
  if not ENTITIES then
    local ok, ast = pcall(require, "org.export.ast")
    ENTITIES = ok and ast.ENTITIES or {}
  end
  return ENTITIES[name] ~= nil or name == "dollar"
end

--- Object parser over a container string.
local Lexer = {}
Lexer.__index = Lexer

--- Longest link type (`org-link-types`) followed by ":" at `p`.
local type_sets = setmetatable({}, { __mode = "k" })
local colon_s, colon_from, colon_at
local function link_type_at(types, s, p)
  -- A type holds no ":", so the only candidate is the text up to the
  -- first colon.
  local set = type_sets[types]
  if not set then
    set = { [0] = 0 }
    for _, t in ipairs(types) do
      set[t] = true
      set[0] = math.max(set[0], #t)
    end
    type_sets[types] = set
  end
  -- the next colon, remembered: asked at each word of a paragraph without
  -- one, the search went to its end every time (quadratic)
  local colon
  if colon_s == s and p >= colon_from and (not colon_at or p <= colon_at) then
    colon = colon_at
  else
    colon = s:find(":", p, true) or false
    colon_s, colon_from, colon_at = s, p, colon
  end
  local t = colon and colon - p <= set[0] and s:sub(p, colon - 1)
  return t and set[t] and t or nil
end

-- Emphasis markers
local EMPH = {
  ["*"] = "bold",
  ["/"] = "italic",
  ["_"] = "underline",
  ["+"] = "strike-through",
  ["="] = "verbatim",
  ["~"] = "code",
}

local function is_space(c)
  return c == " " or c == "\t" or c == "\n" or c == "\r" or c == "\f" or c == "\v"
end

-- Unicode characters with whitespace syntax in Emacs (U+2000..U+200B, U+3000).
local function uspace_ending_at(s, q)
  local t = s:sub(q - 2, q)
  return t:match("^\226\128[\128-\139]$") ~= nil or t == "\227\128\128"
end

local function uspace_starting_at(s, q)
  local t = s:sub(q, q + 2)
  return t:match("^\226\128[\128-\139]$") ~= nil or t == "\227\128\128"
end

function Lexer:emphasis(p, a, b)
  local s = self.s
  local mark = s:sub(p, p)
  if p > a then
    local prev = s:sub(p - 1, p - 1)
    if not (is_space(prev) or prev:match("[%-%(%'\"{]") or uspace_ending_at(s, p - 1)) then
      return nil
    end
  end
  local nxt = s:sub(p + 1, p + 1)
  if nxt == "" or p + 1 > b or is_space(nxt) or uspace_starting_at(s, p + 1) then
    return nil
  end
  -- Whether a marker closes doesn't depend on where the emphasis opened:
  -- the last scan for this marker and limit answers for any start between
  -- where it began and the closing marker it found (or `b`, when it found
  -- none). Without it, a long paragraph with many unclosed markers was
  -- scanned to its end from each of them (quadratic).
  local start = p + 2
  local by_limit = self.emph_close[b]
  if not by_limit then
    by_limit = {}
    self.emph_close[b] = by_limit
  end
  local last = by_limit[mark]
  local q
  if last and start >= last.from and (not last.at or start <= last.at) then
    q = last.at
  else
    q = start
    while true do
      q = s:find(mark, q, true)
      if not q or q > b then
        q = false
        break
      end
      if not is_space(s:sub(q - 1, q - 1)) and not uspace_ending_at(s, q - 1) then
        local after = s:sub(q + 1, q + 1)
        if
          q == b
          or after == ""
          or is_space(after)
          or after:match("[%-%.,;:!%?'\"%)}\\%[]")
          or uspace_starting_at(s, q + 1)
        then
          break
        end
      end
      q = q + 1
    end
    by_limit[mark] = { from = start, at = q }
  end
  if not q then
    return nil
  end
  local post = s:match("^[ \t]*", q + 1)
  local o = { type = EMPH[mark], b = p, e = q + 1 + #post }
  if mark ~= "=" and mark ~= "~" then
    o.cb, o.ce = p + 1, q
  else
    o.value = s:sub(p + 1, q - 1)
  end
  return o
end

function Lexer:link(p, a, b)
  local s = self.s
  if s:sub(p, p + 1) == "[[" then
    -- org-link-bracket-re
    local i = p + 2
    local path_end
    while i <= b do
      local ch = s:sub(i, i)
      if ch == "\\" then
        local j = i
        while s:sub(j, j) == "\\" do
          j = j + 1
        end
        i = j + 1
        if s:sub(j, j) == "" then
          break
        end
      elseif ch == "[" then
        break
      elseif ch == "]" then
        path_end = i - 1
        break
      else
        i = i + 1
      end
    end
    if not path_end or path_end < p + 2 then
      return nil
    end
    local raw = s:sub(p + 2, path_end)
    local link_end, cb, ce
    if s:sub(path_end + 1, path_end + 2) == "]]" then
      link_end = path_end + 2
    elseif s:sub(path_end + 1, path_end + 2) == "][" then
      local d = s:find("]]", path_end + 4, true)
      if not d or d > b then
        return nil
      end
      cb, ce = path_end + 3, d
      link_end = d + 1
    else
      return nil
    end
    raw = raw:gsub("[ \t]*\n[ \t]*", " ")
    raw = raw
      :gsub("(\\+)([%[%]])", function(bs, br)
        return string.rep("\\", math.floor(#bs / 2)) .. br
      end)
      :gsub("(\\+)$", function(bs)
        return string.rep("\\", math.floor(#bs / 2))
      end)
    raw = self.expand_abbrev(raw)
    local o = { type = "link", b = p, format = "bracket", raw_link = raw, cb = cb, ce = ce, link_end = link_end }
    local lt = link_type_at(self.doc.link_types, raw, 1)
    if raw:match("^[/~]") or raw:match("^%.%.?/") then
      o.link_type, o.path = "file", raw
    elseif lt then
      o.link_type, o.path = lt, raw:sub(#lt + 2)
    elseif raw:sub(1, 1) == "(" and raw:sub(-1) == ")" then
      o.link_type, o.path = "coderef", raw:sub(2, -2)
    elseif raw:sub(1, 1) == "#" then
      o.link_type, o.path = "custom-id", raw:sub(2)
    else
      o.link_type, o.path = "fuzzy", raw
    end
    return self:finish_link(o)
  end
  if s:sub(p, p) == "<" then
    local t = link_type_at(self.doc.link_types, s, p + 1)
    if not t then
      return nil
    end
    local q = p + #t + 2
    local gt = s:find(">", q, true)
    if not gt or gt > b then
      return nil
    end
    local inner = s:sub(q, gt - 1)
    -- continuation lines must start with a non-blank, non-> character
    for cont in inner:gmatch("\n([^\n]*)") do
      if not cont:match("^[ \t]*[^> \t]") then
        return nil
      end
    end
    local o = {
      type = "link",
      b = p,
      format = "angle",
      link_type = t,
      path = inner:gsub("[ \t]*\n[ \t]*", ""),
      link_end = gt,
    }
    o.raw_link = t .. ":" .. inner
    return self:finish_link(o)
  end
  -- plain link: word-start, type ":" path
  if p > a and word_char(s:sub(p - 1, p - 1)) then
    return nil
  end
  local t = link_type_at(self.doc.link_types, s, p)
  if not t then
    return nil
  end
  local q = p + #t + 1
  -- (1+ (or non-space-bracket parenthesis)) then a final char
  local i = q
  local good_end
  while i <= b do
    local ch = s:sub(i, i)
    if ch:match("[%(%[<]") then
      -- one level of parentheses: (any "<([") non-space-brackets (any "])>")
      local j = i + 1
      local ok = false
      while j <= b do
        local cj = s:sub(j, j)
        if cj == ")" or cj == "]" or cj == ">" then
          ok = true
          break
        end
        if cj:match("[ \t\n%(%)<>%[%]]") then
          break
        end
        j = j + 1
      end
      if not ok then
        break
      end
      if i > q then
        good_end = j
      end
      i = j + 1
    elseif ch:match("[%[%] \t\n%(%)<>]") then
      break
    else
      if i > q and (ch:match("[%w]") or ch:byte() >= 128 or ch == "-" or ch == "/") then
        good_end = i
      end
      i = i + 1
    end
  end
  if not good_end then
    return nil
  end
  local o = {
    type = "link",
    b = p,
    format = "plain",
    link_type = t,
    path = s:sub(q, good_end),
    raw_link = s:sub(p, good_end),
    link_end = good_end,
  }
  return self:finish_link(o)
end

function Lexer:finish_link(o)
  local s = self.s
  local post = s:match("^[ \t]*", o.link_end + 1)
  o.e = o.link_end + 1 + #post
  local app = o.link_type:match("^file%+(.+)$")
  if o.link_type == "file" or app then
    o.application = app
    o.link_type = "file"
    local path, opt = o.path:match("^(.-)::(.*)$")
    if path then
      o.search_option = opt
      o.path = path
    end
    o.path = o.path:gsub("^///*(%a:)/", "%1/"):gsub("^///*/", "/")
  end
  return o
end

function Lexer:footnote_ref(p, b)
  local s = self.s
  local label, rest = s:match("^%[fn:([%w_%-]*)()", p)
  if not label then
    return nil
  end
  local nxt = s:sub(rest, rest)
  local inline
  if nxt == ":" then
    inline = true
  elseif nxt == "]" and label ~= "" then
    inline = false
  else
    return nil
  end
  local close = balanced(s, p, "[", "]", b)
  if not close then
    return nil
  end
  local post = s:match("^[ \t]*", close + 1)
  local o = {
    type = "footnote-reference",
    b = p,
    e = close + 1 + #post,
    label = label ~= "" and label or nil,
    ref_type = inline and "inline" or "standard",
  }
  if inline then
    o.cb, o.ce = rest + 1, close
  end
  return o
end

function Lexer:citation(p, b)
  local s = self.s
  local style, start = s:match("^%[cite/([%w/_%-]+):()", p)
  if not style then
    start = s:match("^%[cite:()", p)
  end
  if not start then
    return nil
  end
  local close = balanced(s, p, "[", "]", b)
  if not close then
    return nil
  end
  local inner = s:sub(start, close - 1)
  if not inner:find("@[%w%-%.:%?!`'/%*@%+|%(%){}<>&_%^%$#%%~]") then
    return nil
  end
  local post = s:match("^[ \t]*", close + 1)
  return { type = "citation", b = p, e = close + 1 + #post }
end

function Lexer:macro(p, b)
  local s = self.s
  local name, after = s:match("^{{{([a-zA-Z][%-a-zA-Z0-9_]*)()", p)
  if not name then
    return nil
  end
  local args, stop
  if s:sub(after, after + 2) == "}}}" then
    stop = after + 2
  elseif s:sub(after, after) == "(" then
    local c = s:find(")}}}", after, true)
    if not c or c + 3 > b then
      return nil
    end
    args = s:sub(after + 1, c - 1)
    stop = c + 3
  else
    return nil
  end
  local post = s:match("^[ \t]*", stop + 1)
  local o = { type = "macro", b = p, e = stop + 1 + #post, key = name:lower() }
  if args then
    local a = trim(args):gsub("[ \t\r\n]+", " ")
    a = a:gsub("(\\*),", function(bs)
      return string.rep("\\", math.floor(#bs / 2)) .. (#bs % 2 == 0 and "\0" or ",")
    end)
    o.args = vim.split(a, "\0", { plain = true })
  end
  return o
end

function Lexer:latex(p, a, b)
  local s = self.s
  local c = s:sub(p, p)
  local after
  if c ~= "$" then
    local n = s:sub(p + 1, p + 1)
    if n == "(" then
      local e2 = s:find("\\)", p + 2, true)
      after = e2 and e2 + 2
    elseif n == "[" then
      local e2 = s:find("\\]", p + 2, true)
      after = e2 and e2 + 2
    else
      local m = s:match("^\\[a-zA-Z]+%*?", p)
      if not m then
        return nil
      end
      local q = p + #m
      while true do
        local arg = s:match("^%[[^%]%[\n{}]*%]", q) or s:match("^{[^{}\n]*}", q)
        if not arg then
          break
        end
        q = q + #arg
      end
      after = q
    end
  elseif s:sub(p + 1, p + 1) == "$" then
    local e2 = s:find("$$", p + 2, true)
    after = e2 and e2 + 2
  else
    if p > a and s:sub(p - 1, p - 1) == "$" then
      return nil
    end
    local n = s:sub(p + 1, p + 1)
    if n == "" or n:match("[ \t\n,%.;]") then
      return nil
    end
    local e2 = s:find("$", p + 1, true)
    if not e2 then
      return nil
    end
    local before = s:sub(e2 - 1, e2 - 1)
    if before:match("[ \t\n,%.]") then
      return nil
    end
    local nx = s:sub(e2 + 1, e2 + 1)
    if not (nx == "" or nx == "\n" or nx:match("[%p%s]")) then
      return nil
    end
    after = e2 + 1
  end
  if not after or after - 1 > b then
    return nil
  end
  local post = s:match("^[ \t]*", after)
  return { type = "latex-fragment", b = p, e = after + #post, value = s:sub(p, after - 1) }
end

function Lexer:entity(p)
  local s = self.s
  local name, after = s:match("^\\([a-zA-Z]+)()", p)
  if not name then
    return nil
  end
  local n = s:sub(after, after)
  if not (n == "" or n == "\n" or s:sub(after, after + 1) == "{}" or not n:match("%a")) then
    return nil
  end
  if not is_entity(name) then
    return nil
  end
  local stop = s:sub(after, after + 1) == "{}" and after + 2 or after
  local post = s:match("^[ \t]*", stop)
  return { type = "entity", b = p, e = stop + #post }
end

function Lexer:target(p)
  local s = self.s
  local radio = s:match("^<<<([^<>\n\r \t][^<>\n\r]-[^<>\n\r \t])>>>", p) or s:match("^<<<([^<>\n\r \t])>>>", p)
  if radio then
    local stop = p + #radio + 6
    local post = s:match("^[ \t]*", stop)
    return { type = "radio-target", b = p, e = stop + #post, value = radio, cb = p + 3, ce = p + 3 + #radio }
  end
  local v = s:match("^<<([^<>\n\r \t][^<>\n\r]-[^<>\n\r \t])>>", p) or s:match("^<<([^<>\n\r \t])>>", p)
  if not v then
    return nil
  end
  local stop = p + #v + 4
  local post = s:match("^[ \t]*", stop)
  return { type = "target", b = p, e = stop + #post, value = v }
end

function Lexer:inline_src(p, a, b)
  local s = self.s
  if p > a and word_char(s:sub(p - 1, p - 1)) then
    return nil
  end
  local lang, q = s:match("^[sS][rR][cC]_([^ \t\n%[{]+)()", p)
  if not lang then
    return nil
  end
  local o = { type = "inline-src-block", b = p, language = lang }
  if s:sub(q, q) == "[" then
    local c = balanced(s, q, "[", "]", b)
    if not c then
      return nil
    end
    o.parameters = nw(s:sub(q + 1, c - 1))
    q = c + 1
  end
  if s:sub(q, q) ~= "{" then
    return nil
  end
  local c = balanced(s, q, "{", "}", b)
  if not c then
    return nil
  end
  local post = s:match("^[ \t]*", c + 1)
  o.e = c + 1 + #post
  return o
end

function Lexer:inline_call(p, a, b)
  local s = self.s
  if p > a and word_char(s:sub(p - 1, p - 1)) then
    return nil
  end
  local name, q = s:match("^[cC][aA][lL][lL]_([^ \t\n%[%(]+)()", p)
  if not name then
    return nil
  end
  local o = { type = "inline-babel-call", b = p, call = name }
  if s:sub(q, q) == "[" then
    local c = balanced(s, q, "[", "]", b)
    if not c then
      return nil
    end
    o.inside_header = s:sub(q + 1, c - 1)
    q = c + 1
  end
  if s:sub(q, q) ~= "(" then
    return nil
  end
  local c = balanced(s, q, "(", ")", b)
  if not c then
    return nil
  end
  q = c + 1
  if s:sub(q, q) == "[" then
    local c2 = balanced(s, q, "[", "]", b)
    if c2 then
      o.end_header = nw(s:sub(q + 1, c2 - 1))
      q = c2 + 1
    end
  end
  local post = s:match("^[ \t]*", q)
  o.e = q + #post
  return o
end

function Lexer:snippet(p, b)
  local s = self.s
  local be, q = s:match("^@@([%w%-]+):()", p)
  if not be then
    return nil
  end
  local c = s:find("@@", q, true)
  if not c or c + 1 > b then
    return nil
  end
  local post = s:match("^[ \t]*", c + 2)
  return { type = "export-snippet", b = p, e = c + 2 + #post }
end

--- Next object at or after `p` in [p, b] (`org-element--object-lex`).
--- `restrict` flags disable object types (see `org-element-object-restrictions`).
function Lexer:next_object(p, a, b, restrict)
  local s = self.s
  local R = restrict
  while p <= b do
    local c = s:sub(p, p)
    local n = s:sub(p + 1, p + 1)
    local o
    local low = s:sub(p, p + 4):lower()
    if low == "call_" or low:sub(1, 4) == "src_" then
      if R.minimal then
        o = nil
      elseif low:sub(1, 4) == "src_" then
        o = not R.no_babel and self:inline_src(p, a, b) or nil
      else
        o = not R.no_babel and self:inline_call(p, a, b) or nil
      end
    elseif EMPH[c] and n ~= "" and not is_space(n) then
      o = self:emphasis(p, a, b)
    elseif c == "@" and n == "@" then
      o = not R.minimal and self:snippet(p, b) or nil
    elseif c == "{" and s:sub(p, p + 2) == "{{{" then
      o = not R.minimal and self:macro(p, b) or nil
    elseif c == "$" then
      o = self:latex(p, a, b)
    elseif c == "<" then
      if n == "<" then
        o = not R.no_targets and self:target(p) or nil
      elseif n == "%" or n:match("%d") then
        o = not R.no_timestamps and parse_timestamp(s, p, b) or nil
        if o then
          o.type = "timestamp"
        end
      elseif not R.no_links then
        o = self:link(p, a, b)
      end
    elseif c == "\\" then
      if n:match("[%a%[%(]") then
        o = self:entity(p) or self:latex(p, a, b)
      end
    elseif c == "[" then
      if n == "[" then
        o = not R.no_links and self:link(p, a, b) or nil
      elseif s:sub(p, p + 3) == "[fn:" then
        o = not R.no_footnotes and self:footnote_ref(p, b) or nil
      elseif s:sub(p, p + 5) == "[cite:" or s:sub(p, p + 5) == "[cite/" then
        o = not R.no_citations and self:citation(p, b) or nil
      elseif n:match("%d") then
        o = not R.no_timestamps and parse_timestamp(s, p, b) or nil
        if o then
          o.type = "timestamp"
        end
      end
    elseif c:match("%a") and not R.no_links then
      if p == a or not word_char(s:sub(p - 1, p - 1)) then
        o = self:link(p, a, b)
      end
    end
    if o then
      return o
    end
    p = p + 1
  end
  return nil
end

-- Restrictions of link descriptions and radio targets (minimal set plus
-- snippets, inline Babel and macros for links).
local LINK_RESTRICT = {
  no_links = true,
  no_timestamps = true,
  no_footnotes = true,
  no_targets = true,
  no_citations = true,
}
local MINIMAL_RESTRICT = {
  minimal = true,
  no_links = true,
  no_timestamps = true,
  no_footnotes = true,
  no_targets = true,
  no_citations = true,
}
local CELL_RESTRICT = { no_babel = true }

--- Parse objects in [a, b] of the container string, appending to the
--- document with `parent` as enclosing object.
function Lexer:parse(a, b, parent, restrict)
  local p = a
  local text_start = a
  while p <= b do
    local o = self:next_object(p, a, b, restrict)
    if not o then
      break
    end
    if o.b > text_start then
      self:add_text(text_start, o.b - 1, parent)
    end
    o.parent = parent
    self:add(o)
    if o.cb then
      local r = {}
      if o.type == "link" then
        r = LINK_RESTRICT
      elseif o.type == "radio-target" then
        r = MINIMAL_RESTRICT
      end
      self:parse(o.cb, o.ce - 1, o, r)
    end
    p = math.max(o.e, p + 1)
    text_start = p
  end
  if text_start <= b then
    self:add_text(text_start, b, parent)
  end
end

function Lexer:add(o)
  o.element = self.element
  o.pos = self.pos
  o.lnum, o.col = self.pos(o.b)
  o.s = self.s
  if o.type == "timestamp" then
    o.text = self.s:sub(o.b, o.e - 1)
  end
  local list = self.doc.objects
  list[#list + 1] = o
end

function Lexer:add_text(a, b, parent)
  local o = { type = "plain-text", b = a, e = b + 1, parent = parent, value = self.s:sub(a, b) }
  self:add(o)
end

--- Parse objects of a container made of `segments` ({line, col, text}).
function Doc:parse_objects(segments, element, restrict)
  local parts, starts = {}, {}
  local off = 1
  for i, seg in ipairs(segments) do
    starts[i] = off
    parts[#parts + 1] = seg.text
    off = off + #seg.text + 1
  end
  local s = table.concat(parts, "\n")
  if #s == 0 then
    return
  end
  -- (a binary search: a paragraph can have thousands of lines)
  local function pos(o)
    if o < starts[1] then
      return segments[1].line, segments[1].col
    end
    local lo, hi = 1, #segments
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if starts[mid] <= o then
        lo = mid
      else
        hi = mid - 1
      end
    end
    return segments[lo].line, segments[lo].col + (o - starts[lo])
  end
  local lx = setmetatable({
    s = s,
    doc = self,
    element = element,
    pos = pos,
    expand_abbrev = self.expand_abbrev,
    emph_close = {},
  }, Lexer)
  lx:parse(1, #s, nil, restrict or {})
end

function Doc:collect_objects()
  local L = self.lines
  -- Parsed affiliated keywords (CAPTION) are not traversed: the checkers
  -- call `org-element-map' without WITH-AFFILIATED.
  for _, el in ipairs(self.elements) do
    if el.type == "paragraph" then
      local segs = {}
      for k = el.cbegin, el.cend do
        local c = k == el.cbegin and el.ccol or 1
        segs[#segs + 1] = { line = k, col = c, text = L[k]:sub(c) }
      end
      self:parse_objects(segs, el)
    elseif el.type == "item" and el.item.tag then
      local l = L[el.begin]
      local tstart = l:find(el.item.tag, 1, true)
      if tstart then
        self:parse_objects({ { line = el.begin, col = tstart, text = el.item.tag } }, el)
      end
    elseif el.type == "headline" then
      local r = el.title_range
      if r[2] >= r[1] then
        self:parse_objects({ { line = el.begin, col = r[1], text = L[el.begin]:sub(r[1], r[2]) } }, el)
      end
    elseif el.type == "verse-block" and el.vbegin then
      local segs = {}
      for k = el.vbegin, el.vend do
        segs[#segs + 1] = { line = k, col = 1, text = L[k] }
      end
      self:parse_objects(segs, el)
    elseif el.type == "table-row" then
      local l = L[el.begin]
      if not l:match("^[ \t]*|%-") then
        local p = l:find("|", 1, true) + 1
        while p <= #l do
          local bar = l:find("|", p, true)
          local cell_end = (bar or #l + 1) - 1
          local cs, ce = p, cell_end
          while cs <= ce and l:sub(cs, cs):match("[ \t]") do
            cs = cs + 1
          end
          while ce >= cs and l:sub(ce, ce):match("[ \t]") do
            ce = ce - 1
          end
          if ce >= cs then
            self:parse_objects({ { line = el.begin, col = cs, text = l:sub(cs, ce) } }, el, CELL_RESTRICT)
          end
          if not bar then
            break
          end
          p = bar + 1
        end
      end
    end
  end
end

--- Innermost element containing (lnum, col), like `org-element-at-point`.
function Doc:element_at(lnum, col)
  col = col or 1
  local function covers(el)
    if lnum < el.begin or lnum >= el.stop then
      return false
    end
    if lnum == el.begin and el.col > 1 and col < el.col then
      return false
    end
    return true
  end
  local node = self.root
  local found = nil
  while true do
    -- the last child that covers the position: children come in document
    -- order, so a binary search finds the last one starting at or before
    -- it, and going back stops at the first one that ends before it (a
    -- scan of all children made the checkers that ask for each line
    -- quadratic in a file of many top-level headlines)
    local children = node.children
    local lo, hi = 1, #children
    while lo <= hi do
      local mid = math.floor((lo + hi) / 2)
      if children[mid].begin <= lnum then
        lo = mid + 1
      else
        hi = mid - 1
      end
    end
    local next_node
    for i = hi, 1, -1 do
      local ch = children[i]
      if covers(ch) then
        next_node = ch
        break
      end
      if ch.stop <= lnum then
        break
      end
    end
    if not next_node then
      return found
    end
    found = next_node
    -- descend only inside the contents
    if not next_node.cbegin or #next_node.children == 0 then
      return found
    end
    if lnum < next_node.cbegin or (lnum == next_node.cbegin and next_node.ccol > 1 and col < next_node.ccol) then
      return found
    end
    node = next_node
  end
end

--- Parse buffer lines into a document.
---@param lines string[]
---@param opts? { file?: table, dir?: string, bufnr?: integer, filename?: string }
local function parse(lines, opts)
  opts = opts or {}
  local doc = setmetatable({
    lines = lines,
    elements = {},
    objects = {},
    file = opts.file,
    dir = opts.dir,
    bufnr = opts.bufnr,
    filename = opts.filename,
  }, Doc)
  local abbrevs = opts.file and opts.file.settings.link_abbrevs or {}
  doc.expand_abbrev = function(raw)
    local name = raw:match("^([%w_%-]+):") or raw
    if abbrevs[name] or (require("org.config").opts.links.abbreviations or {})[name] then
      local ok, links = pcall(require, "org.links")
      if ok then
        return links.expand_abbrev(raw, opts.file)
      end
    end
    return raw
  end
  local types = vim.deepcopy(LINK_TYPES)
  for t in pairs(require("org.config").opts.links.types or {}) do
    types[#types + 1] = t
  end
  doc.link_types = types
  doc.todo = opts.file and opts.file.settings.todo
    or require("org.parser").parse(lines, opts.filename or ((opts.dir or vim.fn.getcwd()) .. "/.org-setup-context")).settings.todo
  doc.root = new_el("org-data", { begin = 1, post = 1, last = #lines, stop = #lines + 1 })
  local s = doc:skip_blank(1, #lines)
  doc:parse_region(s, #lines, "first-section", doc.root)
  if opts.objects ~= false then
    doc:collect_objects()
  end
  return doc
end

return {
  parse = parse,
}
