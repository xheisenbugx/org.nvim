---@mod org.ui.chars Org's syntax table for non-ASCII characters
---
--- What Emacs's regexps make of a non-ASCII character in an Org buffer,
--- for the parser highlighter's ports of them: whether it is a word or
--- symbol constituent ("\\<", "\\_<", [[:punct:]]), whether "\\<" matches
--- between it and a Latin letter (word_boundary_p: a word constituent of
--- another script, such as 東京https://x.org, starts a new word), and
--- whether it is [[:alnum:]] and not line-breakable (the boundaries of
--- radio target links). The tables are generated from Emacs
--- (scripts/emacs-parity/chars.el, lua/org/ui/chars_data.lua) and read
--- on first use. ASCII characters are the callers' (their syntax in Org:
--- word constituents are letters, digits and $ % ', symbol constituents
--- & * + - / = \ _ | ~).

local M = {}

local byte = string.byte

---@type table<string, integer[]>?
local tables

--- The ranges of table `name`, flat: { from1, to1, from2, to2, ... }.
---@param name string
---@return integer[]
local function ranges(name)
  if not tables then
    tables = {}
    for k, text in pairs(require("org.ui.chars_data")) do
      local t = {} ---@type integer[]
      for a, b in text:gmatch("(%x+)%-(%x+)") do
        t[#t + 1] = tonumber(a, 16)
        t[#t + 1] = tonumber(b, 16)
      end
      tables[k] = t
    end
  end
  return tables[name]
end

--- Whether codepoint `cp` is in table `name`.
---@param name string
---@param cp integer
local function member(name, cp)
  local t = ranges(name)
  local lo, hi = 1, #t / 2
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if cp < t[2 * mid - 1] then
      hi = mid - 1
    elseif cp > t[2 * mid] then
      lo = mid + 1
    else
      return true
    end
  end
  return false
end

--- The codepoint of the UTF-8 character starting at byte `i` of `s` and
--- its last byte, or nil (not the start of a multibyte character).
---@param s string
---@param i integer
---@return integer?, integer?
function M.at(s, i)
  local b = byte(s, i)
  if not b or b < 0xC0 then
    return nil
  end
  local n, cp
  if b < 0xE0 then
    n, cp = 1, b - 0xC0
  elseif b < 0xF0 then
    n, cp = 2, b - 0xE0
  else
    n, cp = 3, b - 0xF0
  end
  for k = 1, n do
    local c = byte(s, i + k)
    if not c or c < 0x80 or c >= 0xC0 then
      return nil
    end
    cp = cp * 64 + c - 0x80
  end
  return cp, i + n
end

--- The codepoint of the UTF-8 character ending at byte `i` of `s` (a
--- byte >= 0x80 there), or nil.
---@param s string
---@param i integer
---@return integer?
function M.before(s, i)
  for j = i, math.max(1, i - 3), -1 do
    local b = byte(s, j)
    if not b or b < 0x80 then
      return nil
    end
    if b >= 0xC0 then
      local cp, e = M.at(s, j)
      return e == i and cp or nil
    end
  end
end

--- The syntax class of non-ASCII codepoint `cp`: "w" (word), "_"
--- (symbol) or "." (anything else: punctuation, blanks, parentheses).
---@param cp integer
---@return "w"|"_"|"."
function M.syntax(cp)
  if member("SYMBOL", cp) then
    return "_"
  elseif member("OTHER", cp) then
    return "."
  end
  return "w"
end

--- Whether "\\<" matches between non-ASCII codepoint `cp` and a Latin
--- letter after it.
---@param cp integer
function M.word_start_after(cp)
  return not member("JOIN", cp)
end

--- Whether non-ASCII codepoint `cp` is [[:alnum:]] and not
--- line-breakable (\\c|).
---@param cp integer
function M.alnum_unbreakable(cp)
  return member("ALNUM", cp)
end

return M
