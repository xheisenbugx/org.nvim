---@mod org.export.csl.util Helpers for the citeproc port
---
--- Characters and strings with Emacs semantics (positions and lengths
--- count characters, words follow the standard syntax table), and
--- association lists: arrays of `{ key, value }` pairs, first match wins.

local U = {}

---------------------------------------------------------------------------
-- UTF-8
---------------------------------------------------------------------------

local char_cache = {}

--- The UTF-8 string of code point `cp`.
function U.char(cp)
  local c = char_cache[cp]
  if not c then
    if cp < 0x80 then
      c = string.char(cp)
    elseif cp < 0x800 then
      c = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
      c = string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    else
      c = string.char(
        0xF0 + math.floor(cp / 0x40000),
        0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40,
        0x80 + cp % 0x40
      )
    end
    char_cache[cp] = c
  end
  return c
end

--- Code points of UTF-8 string `s` (invalid bytes are taken as Latin-1).
function U.codepoints(s)
  local out = {}
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    local cp, len
    if b < 0x80 then
      cp, len = b, 1
    elseif b >= 0xF0 and i + 3 <= n then
      cp = (b - 0xF0) * 0x40000 + (s:byte(i + 1) - 0x80) * 0x1000 + (s:byte(i + 2) - 0x80) * 0x40 + (s:byte(i + 3) - 0x80)
      len = 4
    elseif b >= 0xE0 and i + 2 <= n then
      cp = (b - 0xE0) * 0x1000 + (s:byte(i + 1) - 0x80) * 0x40 + (s:byte(i + 2) - 0x80)
      len = 3
    elseif b >= 0xC0 and i + 1 <= n then
      cp = (b - 0xC0) * 0x40 + (s:byte(i + 1) - 0x80)
      len = 2
    else
      cp, len = b, 1
    end
    out[#out + 1] = cp
    i = i + len
  end
  return out
end

--- UTF-8 string of `cps[a..b]` (1-based, inclusive).
function U.from_codepoints(cps, a, b)
  a = a or 1
  b = b or #cps
  local out = {}
  for k = a, b do
    out[#out + 1] = U.char(cps[k])
  end
  return table.concat(out)
end

--- Characters of `s` as strings.
function U.chars(s)
  local out = {}
  for c in s:gmatch("[%z\1-\127\192-\255][\128-\191]*") do
    out[#out + 1] = c
  end
  return out
end

--- Length in characters.
function U.len(s)
  local n = 0
  for _ in s:gmatch("[%z\1-\127\192-\255][\128-\191]*") do
    n = n + 1
  end
  return n
end

--- Emacs `substring`: 0-based `from`, exclusive `to`, negatives count
--- from the end, nil `to` is the end.
function U.substring(s, from, to)
  local cps = U.codepoints(s)
  local n = #cps
  from = from or 0
  if from < 0 then
    from = n + from
  end
  if to == nil then
    to = n
  elseif to < 0 then
    to = n + to
  end
  if from < 0 or to > n or from > to then
    error(string.format("Args out of range: %q, %s, %s", s, tostring(from), tostring(to)), 0)
  end
  return U.from_codepoints(cps, from + 1, to)
end

--- Code point of the character at 0-based `i` (aref).
function U.aref(s, i)
  local cps = U.codepoints(s)
  if i < 0 then
    i = #cps + i
  end
  return cps[i + 1]
end

---------------------------------------------------------------------------
-- Case and character classes
---------------------------------------------------------------------------

local lower_cache, upper_cache, word_cache = {}, {}, {}

function U.lower_cp(c)
  if c < 128 then
    if c >= 65 and c <= 90 then
      return c + 32
    end
    return c
  end
  local r = lower_cache[c]
  if not r then
    r = vim.fn.char2nr(vim.fn.tolower(U.char(c)))
    lower_cache[c] = r
  end
  return r
end

function U.upper_cp(c)
  if c < 128 then
    if c >= 97 and c <= 122 then
      return c - 32
    end
    return c
  end
  local r = upper_cache[c]
  if not r then
    r = vim.fn.char2nr(vim.fn.toupper(U.char(c)))
    upper_cache[c] = r
  end
  return r
end

--- Word constituent in Emacs' standard syntax table (letters and digits;
--- most non-ASCII characters except punctuation and symbols).
function U.is_word_cp(c)
  if c < 128 then
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
  end
  local r = word_cache[c]
  if r == nil then
    if (c >= 0x2B0 and c <= 0x2FF) or (c >= 0x300 and c <= 0x36F) then
      r = true
    elseif c == 0xAA or c == 0xB5 or c == 0xBA then
      r = true
    elseif c <= 0xBF or c == 0xD7 or c == 0xF7 then
      r = false
    elseif c >= 0x2000 and c <= 0x2BFF then
      r = false
    elseif c >= 0x3000 and c <= 0x303F then
      r = false
    elseif c == 0xFEFF or (c >= 0xFE30 and c <= 0xFE6F) or (c >= 0xFF00 and c <= 0xFF0F) then
      r = false
    else
      local ok, cls = pcall(vim.fn.charclass, U.char(c))
      r = not ok or cls >= 2
    end
    word_cache[c] = r
  end
  return r
end

--- [[:alpha:]]
function U.is_alpha_cp(c)
  if c < 128 then
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
  end
  if (c >= 0x300 and c <= 0x36F) then
    return false
  end
  return U.is_word_cp(c) and not (c >= 0x660 and c <= 0x669) and not (c >= 0xFF10 and c <= 0xFF19)
end

-- Emacs string case conversion follows Unicode special casing.
local SPECIAL_UP = {
  [0x131] = "ı",
  [0xDF] = "SS",
  [0xFB00] = "FF",
  [0xFB01] = "FI",
  [0xFB02] = "FL",
  [0xFB03] = "FFI",
  [0xFB04] = "FFL",
  [0xFB05] = "ST",
  [0xFB06] = "ST",
}
local SPECIAL_DOWN = { [0x130] = "i" .. U.char(0x307) }

function U.upcase(s)
  if not s:find("[\128-\255]") then
    return s:upper()
  end
  local out = {}
  for _, c in ipairs(U.codepoints(s)) do
    out[#out + 1] = SPECIAL_UP[c] or U.char(U.upper_cp(c))
  end
  return table.concat(out)
end

function U.downcase(s)
  if not s:find("[\128-\255]") then
    return s:lower()
  end
  local out = {}
  for _, c in ipairs(U.codepoints(s)) do
    out[#out + 1] = SPECIAL_DOWN[c] or U.char(U.lower_cp(c))
  end
  return table.concat(out)
end

--- Emacs `capitalize` on a single word: first character up, rest down.
function U.capitalize_word(w)
  local cps = U.codepoints(w)
  for i, c in ipairs(cps) do
    if i == 1 then
      cps[i] = U.upper_cp(c)
    else
      cps[i] = U.lower_cp(c)
    end
  end
  return U.from_codepoints(cps)
end

--- s-lowercase-p: no uppercase letter.
function U.lowercase_p(s)
  for _, c in ipairs(U.codepoints(s)) do
    if U.lower_cp(c) ~= c then
      return false
    end
  end
  return true
end

--- s-uppercase-p: no lowercase letter.
function U.uppercase_p(s)
  for _, c in ipairs(U.codepoints(s)) do
    if U.upper_cp(c) ~= c then
      return false
    end
  end
  return true
end

--- Words of `cps` (Emacs forward-word): list of { begin, end } 1-based,
--- end exclusive.
function U.word_spans(cps)
  local out = {}
  local i, n = 1, #cps
  while i <= n do
    while i <= n and not U.is_word_cp(cps[i]) do
      i = i + 1
    end
    if i > n then
      break
    end
    local b = i
    while i <= n and U.is_word_cp(cps[i]) do
      i = i + 1
    end
    out[#out + 1] = { b, i }
  end
  return out
end

--- Apply `fn(word, span, cps, index)` to each word; its return value (a
--- same-length string, or nil to keep) replaces the word.
function U.map_words(s, fn)
  local cps = U.codepoints(s)
  for idx, span in ipairs(U.word_spans(cps)) do
    local w = U.from_codepoints(cps, span[1], span[2] - 1)
    local r = fn(w, span, cps, idx)
    if r and r ~= w then
      local rc = U.codepoints(r)
      for k = 1, #rc do
        cps[span[1] + k - 1] = rc[k]
      end
    end
  end
  return U.from_codepoints(cps)
end

---------------------------------------------------------------------------
-- Strings
---------------------------------------------------------------------------

--- s-blank? / s-present?
function U.blank(s)
  return s == nil or s == false or s == ""
end

function U.present(s)
  return not U.blank(s)
end

--- s-blank-str-p: nil or only whitespace
function U.blank_str(s)
  return s == nil or s:match("^[ \t\n\r]*$") ~= nil
end

--- s-trim
function U.trim(s)
  return (s:gsub("^[ \t\n\r]+", ""):gsub("[ \t\n\r]+$", ""))
end

--- string-replace (all non-overlapping occurrences)
function U.replace(from, to, s)
  if from == "" then
    return s
  end
  local out, i = {}, 1
  while true do
    local a, b = s:find(from, i, true)
    if not a then
      break
    end
    out[#out + 1] = s:sub(i, a - 1)
    out[#out + 1] = to
    i = b + 1
  end
  out[#out + 1] = s:sub(i)
  return table.concat(out)
end

--- citeproc-s-replace-all-seq
function U.replace_all_seq(s, pairs_)
  for _, p in ipairs(pairs_) do
    s = U.replace(p[1], p[2], s)
  end
  return s
end

function U.starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

function U.ends_with(s, suffix)
  return suffix == "" or s:sub(-#suffix) == suffix
end

--- Emacs `number-to-string` for integers and strings passed through.
function U.num_str(x)
  if type(x) == "number" then
    if x == math.floor(x) then
      return string.format("%d", x)
    end
    return tostring(x)
  end
  return x
end

--- string-to-number: leading number of `s`, 0 if none.
function U.to_number(s)
  if type(s) == "number" then
    return s
  end
  if type(s) ~= "string" then
    return 0
  end
  local num = s:match("^[ \t\n]*([-+]?%d+%.?%d*)")
  return tonumber(num) or 0
end

---------------------------------------------------------------------------
-- Association lists
---------------------------------------------------------------------------

--- alist-get
function U.aget(al, k)
  if not al then
    return nil
  end
  for _, p in ipairs(al) do
    if type(p) == "table" and p[1] == k then
      return p[2]
    end
  end
end

--- assoc / assq: the pair
function U.assoc(al, k)
  if not al then
    return nil
  end
  for _, p in ipairs(al) do
    if type(p) == "table" and p[1] == k then
      return p
    end
  end
end

--- (cons (cons k v) al) as a new array.
function U.acons(k, v, al)
  local out = { { k, v } }
  for _, p in ipairs(al or {}) do
    out[#out + 1] = p
  end
  return out
end

--- Append arrays into a new one (-concat / append).
function U.concat(...)
  local out = {}
  for i = 1, select("#", ...) do
    local l = select(i, ...)
    if l then
      for _, x in ipairs(l) do
        out[#out + 1] = x
      end
    end
  end
  return out
end

--- --filter / --remove on alists by key predicate.
function U.afilter(al, keep)
  local out = {}
  for _, p in ipairs(al or {}) do
    if keep(p) then
      out[#out + 1] = p
    end
  end
  return out
end

--- Remove pairs with key `k`.
function U.aremove(al, k)
  return U.afilter(al, function(p)
    return not (type(p) == "table" and p[1] == k)
  end)
end

--- setf (alist-get k al): modify in place, or return a new alist with the
--- pair added in front. Returns the (possibly new) alist.
function U.aset(al, k, v)
  local p = U.assoc(al, k)
  if p then
    p[2] = v
    return al
  end
  return U.acons(k, v, al)
end

--- A set from a list.
function U.set(list)
  local s = {}
  for _, x in ipairs(list) do
    s[x] = true
  end
  return s
end

--- Stable sort (Emacs `sort` is stable).
function U.stable_sort(list, less)
  local indexed = {}
  for i, x in ipairs(list) do
    indexed[i] = { x, i }
  end
  table.sort(indexed, function(a, b)
    if less(a[1], b[1]) then
      return true
    end
    if less(b[1], a[1]) then
      return false
    end
    return a[2] < b[2]
  end)
  local out = {}
  for i, p in ipairs(indexed) do
    out[i] = p[1]
  end
  return out
end

---------------------------------------------------------------------------
-- Ordered hash tables (Emacs hash tables iterate in insertion order)
---------------------------------------------------------------------------

local OH = {}
OH.__index = OH

function U.ordered()
  return setmetatable({ keys = {}, map = {} }, OH)
end

local NIL_KEY = {}

function OH:get(k)
  if k == nil then
    k = NIL_KEY
  end
  return self.map[k]
end

function OH:put(k, v)
  if k == nil then
    k = NIL_KEY
  end
  if self.map[k] == nil then
    self.keys[#self.keys + 1] = k
  end
  self.map[k] = v
end

function OH:remove(k)
  if k == nil then
    k = NIL_KEY
  end
  if self.map[k] ~= nil then
    self.map[k] = nil
    for i, x in ipairs(self.keys) do
      if x == k then
        table.remove(self.keys, i)
        break
      end
    end
  end
end

function OH:count()
  return #self.keys
end

function OH:values()
  local out = {}
  for _, k in ipairs(self.keys) do
    out[#out + 1] = self.map[k]
  end
  return out
end

function OH:each(fn)
  for _, k in ipairs(vim.list_slice(self.keys)) do
    if self.map[k] ~= nil then
      fn(k, self.map[k])
    end
  end
end

return U
