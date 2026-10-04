---@mod org.export.element.markup Export parser: emphasis and timestamps
---
--- Emphasis markers and timestamp objects.
---
--- Part of org.export.element, which loads it.

local shared = require("org.export.element.shared")

local M = require("org.export.element")

local P = shared.P

---------------------------------------------------------------------------
-- Objects
---------------------------------------------------------------------------

local function word_char(c)
  return c ~= nil and c ~= "" and c:match("[%w]") ~= nil
end

local PUNCT_CLOSE = "[ \t\n%-%.,;:!%?'\"%)}\\%[]"
local EMPH = {
  ["*"] = "bold",
  ["/"] = "italic",
  ["_"] = "underline",
  ["+"] = "strike-through",
  ["="] = "verbatim",
  ["~"] = "code",
}

--- Non-ASCII characters with whitespace syntax in Emacs ([[:space:]]):
--- no-break space, U+2000..U+200B, U+202F, U+205F and U+3000.
local USPACES = { "\194\160", "\226\128\175", "\226\129\159", "\227\128\128" }
for c = 0x80, 0x8b do
  USPACES[#USPACES + 1] = "\226\128" .. string.char(c)
end

--- Does a Unicode space start (dir = 1) or end (dir = -1) at byte i?
local function uspace_at(s, i, dir)
  for _, u in ipairs(USPACES) do
    local a = dir > 0 and i or (i - #u + 1)
    if a >= 1 and s:sub(a, a + #u - 1) == u then
      return true
    end
  end
  return false
end

--- Emphasis at position p (org-element--parse-generic-emphasis).
function P:emphasis(s, p)
  local mark = s:sub(p, p)
  local prev = p > 1 and s:sub(p - 1, p - 1) or "\n"
  if not (prev:match("[ \t\n%-%(%{'\"]") or prev == "\n" or uspace_at(s, p - 1, -1)) then
    return nil
  end
  local nxt = s:sub(p + 1, p + 1)
  if nxt == "" or nxt:match("[ \t\n]") or uspace_at(s, p + 1, 1) then
    return nil
  end
  -- closing: (not space)(mark)(punct or eol). Whether a marker closes
  -- doesn't depend on the opening one: the last search for this marker in
  -- `s` answers for any opening between where it started and the closing
  -- marker it found (or the end, when it found none). Searching from each
  -- opening marker made a long paragraph of unclosed ones quadratic.
  local from = p + 2
  -- (per string: a paragraph's objects are parsed between those of its
  -- emphasis contents; a few strings at a time are enough)
  local memos = self.emph_close
  if not memos or memos.n > 64 then
    memos = { n = 0, of = {} }
    self.emph_close = memos
  end
  local memo = memos.of[s]
  if not memo then
    memo = {}
    memos.of[s] = memo
    memos.n = memos.n + 1
  end
  local last = memo[mark]
  local c
  if last and from >= last.from and (not last.at or from <= last.at) then
    c = last.at
  else
    local k = p + 1
    while true do
      c = s:find(mark, k + 1, true)
      if not c then
        c = false
        break
      end
      local before = s:sub(c - 1, c - 1)
      local after_c = s:sub(c + 1, c + 1)
      if
        not before:match("[ \t\n]")
        and not uspace_at(s, c - 1, -1)
        and (after_c == "" or after_c:match(PUNCT_CLOSE) or uspace_at(s, c + 1, 1))
      then
        break
      end
      k = c
    end
    memo[mark] = { from = from, at = c }
  end
  if not c then
    return nil
  end
  local inner = s:sub(p + 1, c - 1)
  local e = c + 1
  local ws = s:match("^[ \t]*", e)
  local t = EMPH[mark]
  local node = M.node(t, { post_blank = #ws })
  if t == "verbatim" or t == "code" then
    node.value = inner
  else
    node.inner = inner
  end
  return node, e + #ws
end

--- Parse a timestamp at s:sub(p). Returns node, end index (after post-blank).
function P:parse_timestamp(s, p)
  local c = s:sub(p, p)
  if c ~= "<" and c ~= "[" then
    return nil
  end
  local close = c == "<" and ">" or "]"
  -- diary sexp <%%(...)>
  if s:sub(p, p + 2) == "<%%" then
    local sexp_end = s:find(">", p, true)
    local body = s:match("^<%%%%(%b())([^\n>]*)>", p)
    if not body then
      return nil
    end
    local full = s:match("^(<%%%%%b()[^\n>]*>)", p)
    local e = p + #full
    local ws = s:match("^[ \t]*", e)
    local node = M.node("timestamp", {
      ts_type = "diary",
      raw_value = full,
      diary_sexp = body:sub(2, -2),
      post_blank = #ws,
    })
    local rest = s:match("^<%%%%%b()([^\n>]*)>", p)
    local h1, m1, h2, m2 = (rest or ""):match("(%d?%d):(%d%d)%-(%d?%d):(%d%d)")
    if not h1 then
      h1, m1 = (rest or ""):match("(%d?%d):(%d%d)")
    end
    node.hour_start, node.minute_start = tonumber(h1), tonumber(m1)
    node.hour_end, node.minute_end = tonumber(h2), tonumber(m2)
    if node.hour_end then
      node.range_type = "timerange"
    end
    _ = sexp_end
    return node, e + #ws
  end
  local inner = s:match("^%" .. c .. "(%d%d%d%d%-%d%d%-%d%d[^%" .. close .. "\n]-)%" .. close, p)
  if not inner then
    return nil
  end
  if not (inner:match("^%d%d%d%d%-%d%d%-%d%d$") or inner:match("^%d%d%d%d%-%d%d%-%d%d ")) then
    return nil
  end
  local raw = c .. inner .. close
  local e = p + #raw
  local inner2
  if s:sub(e, e + 1) == "--" then
    local c2 = s:sub(e + 2, e + 2)
    if c2 == "<" or c2 == "[" then
      local close2 = c2 == "<" and ">" or "]"
      inner2 = s:match("^%" .. c2 .. "(%d%d%d%d%-%d%d%-%d%d[^%" .. close2 .. "\n]-)%" .. close2, e + 2)
      if inner2 and (inner2:match("^%d%d%d%d%-%d%d%-%d%d$") or inner2:match("^%d%d%d%d%-%d%d%-%d%d ")) then
        raw = raw .. "--" .. c2 .. inner2 .. close2
        e = p + #raw
      else
        inner2 = nil
      end
    end
  end
  local ws = s:match("^[ \t]*", e)
  local active = c == "<"
  local function parse_date(str)
    local y, mo, d = str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    local h, mi = str:match(" (%d?%d):(%d%d)")
    return tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi)
  end
  local y1, mo1, d1, h1, mi1 = parse_date(inner)
  local th, tm = inner:match("%d?%d:%d%d%-(%d?%d):(%d%d)")
  local ttype
  if active and (inner2 or th) then
    ttype = "active-range"
  elseif active then
    ttype = "active"
  elseif inner2 or th then
    ttype = "inactive-range"
  else
    ttype = "inactive"
  end
  local node = M.node("timestamp", {
    ts_type = ttype,
    range_type = inner2 and "daterange" or (th and "timerange" or nil),
    raw_value = raw,
    year_start = y1,
    month_start = mo1,
    day_start = d1,
    hour_start = h1,
    minute_start = mi1,
    post_blank = #ws,
  })
  if inner2 then
    local y2, mo2, d2, h2, mi2 = parse_date(inner2)
    node.year_end, node.month_end, node.day_end, node.hour_end, node.minute_end = y2, mo2, d2, h2, mi2
  else
    node.year_end, node.month_end, node.day_end = y1, mo1, d1
    node.hour_end = tonumber(th) or h1
    node.minute_end = tonumber(tm) or mi1
  end
  local rtype, rval, runit = raw:match("([%.%+]?%+)(%d+)([hdwmy])")
  if rtype then
    node.repeater_type = rtype == "++" and "catch-up" or (rtype == ".+" and "restart" or "cumulate")
    node.repeater_value = tonumber(rval)
    node.repeater_unit = runit
  end
  local wfirst, wval, wunit = raw:match("(%-?)%-(%d+)([hdwmy])")
  if wval and raw:match("%s%-%-?%d+[hdwmy]") then
    node.warning_type = wfirst == "-" and "first" or "all"
    node.warning_value = tonumber(wval)
    node.warning_unit = wunit
  end
  return node, e + #ws
end

-- Locals the later parts share
shared.word_char = word_char
shared.EMPH = EMPH
