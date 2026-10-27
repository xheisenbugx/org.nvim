---@mod org.ui.highlight.list Lists
---
--- Part of org.ui.highlight (the parser highlighter): bullets, checkboxes, statistics cookies and description list terms.
---
--- A port of the list rules of org-set-font-lock-defaults: checkboxes
--- (org-list-full-item-re, group 3), statistics cookies
--- (org-get-checkbox-statistics-face) and description terms (the
--- org-list-dt rule, its " ::" included), each found on its own line by a
--- scan of that line. Bullets have no face in Emacs: they are drawn as the
--- syntax engine draws them (lists.allow_alphabetical,
--- lists.ordered_item_terminator). Emacs finds all of them on any line,
--- then org-fontify-meta-lines-and-blocks replaces the faces of keywords,
--- comments and the bodies of src, example and export blocks: nothing is
--- drawn on those lines here. Like syntax groups without @Spell, none of
--- them is spell checked.

-- Not compiled by the JIT, like org.ui.highlight (see the comment there).
if jit then
  jit.off(true, true)
end

local M = {}

local byte = string.byte

local PRIO = require("org.ui.highlight").PRIO

local BOX_GROUP = { [32] = "orgCheckbox", [88] = "orgCheckboxChecked", [45] = "orgCheckboxPartial" }

--- Whether byte `b` is a blank of the patterns ([ \t]; nil: the end of the line).
local function blank(b)
  return b == 32 or b == 9
end

local function digit(b)
  return b ~= nil and b >= 48 and b <= 57
end

local function letter(b)
  return b ~= nil and ((b >= 65 and b <= 90) or (b >= 97 and b <= 122))
end

--- The end (exclusive, 1-based) of the bullet at `s` (the first non-blank
--- byte of `line`), as org.syntax draws orgListBullet, or nil.
---@param line string
---@param s integer
---@param terms table<integer, boolean> the ordered item terminators
---@param alpha boolean lists.allow_alphabetical
---@return integer?
local function bullet_end(line, s, terms, alpha)
  local c = byte(line, s)
  local e
  if c == 45 or c == 43 then -- - +
    e = s + 1
  elseif c == 42 then -- * (indented only: a headline otherwise)
    e = s > 1 and s + 1 or nil
  elseif digit(c) then
    e = s + 1
    while digit(byte(line, e)) do
      e = e + 1
    end
    e = terms[byte(line, e) or 0] and e + 1 or nil
  elseif alpha and letter(c) then
    e = terms[byte(line, s + 1) or 0] and s + 2 or nil
  end
  if e and (byte(line, e) == nil or blank(byte(line, e))) then
    return e
  end
end

--- The checkbox of `line` (org-list-full-item-re, group 3: after a bullet,
--- blanks and an optional [@N] counter; font-lock takes every bullet,
--- letters and "*" at the start of a line too, case-sensitive [X]): its
--- first byte and its group, or nil.
---@param line string
---@param s integer the first non-blank byte
---@return integer?, string?
local function checkbox(line, s)
  local c = byte(line, s)
  local j
  if c == 45 or c == 43 or c == 42 then
    j = s + 1
  elseif digit(c) then
    j = s + 1
    while digit(byte(line, j)) do
      j = j + 1
    end
  elseif letter(c) then
    j = s + 1
  else
    return
  end
  if c ~= 45 and c ~= 43 and c ~= 42 then
    local t = byte(line, j)
    if t ~= 46 and t ~= 41 then -- . )
      return
    end
    j = j + 1
  end
  if not blank(byte(line, j)) then
    return
  end
  while blank(byte(line, j)) do
    j = j + 1
  end
  -- the counter: [@N], [@start:N] (a number or a letter), then blanks
  if byte(line, j) == 91 and byte(line, j + 1) == 64 then
    local k = j + 2
    if line:sub(k, k + 5) == "start:" then
      k = k + 6
    end
    local v = k
    if digit(byte(line, k)) then
      while digit(byte(line, k)) do
        k = k + 1
      end
    elseif letter(byte(line, k)) then
      k = k + 1
    end
    if k > v and byte(line, k) == 93 then
      j = k + 1
      while blank(byte(line, j)) do
        j = j + 1
      end
    end
  end
  if byte(line, j) == 91 and byte(line, j + 2) == 93 then
    local group = BOX_GROUP[byte(line, j + 1)]
    local after = byte(line, j + 3)
    if group and (after == nil or blank(after)) then
      return j, group
    end
  end
end

--- The description term of `line` (the org-list-dt rule:
--- "\(?:^[ \t]*[-+]\|^[ \t]+[*]\)[ \t]+\(.*?[ \t]+::\)\([ \t]+\|$\)"):
--- the first and last byte of group 1, or nil.
---@param line string
---@param s integer the first non-blank byte
---@return integer?, integer?
local function term(line, s)
  local c = byte(line, s)
  if not (c == 45 or c == 43 or (c == 42 and s > 1)) then
    return
  end
  local g = s + 1
  if not blank(byte(line, g)) then
    return
  end
  while blank(byte(line, g)) do
    g = g + 1
  end
  -- (the blanks after the bullet are greedy: the term starts after them,
  -- and the first " ::" there followed by a blank or the end ends it)
  local q = g + 1 ---@type integer?
  while q do
    q = line:find("::", q, true)
    if not q then
      break
    end
    local after = byte(line, q + 2)
    if blank(byte(line, q - 1)) and (after == nil or blank(after)) then
      return g, q + 1
    end
    q = q + 1
  end
  -- with none, they give one blank back: "-  :: x" has the term " ::"
  if g - s > 2 and line:sub(g, g + 1) == "::" then
    local after = byte(line, g + 2)
    if after == nil or blank(after) then
      return g - 1, g + 1
    end
  end
end

--- The statistics cookies of `line` ("[N%]" or "[N/M]", digits optional),
--- each painted with `paint(col0, end_col0, done)`: done is "[100%]" or a
--- fraction with the same non-empty numbers (org-get-checkbox-statistics-face).
---@param line string
---@param paint fun(col: integer, end_col: integer, done: boolean)
local function cookies(line, paint)
  local p = line:find("[", 1, true)
  while p do
    local j = p + 1
    while digit(byte(line, j)) do
      j = j + 1
    end
    local b = byte(line, j)
    local nxt = p + 1
    if b == 37 and byte(line, j + 1) == 93 then -- %]
      paint(p - 1, j + 1, line:sub(p + 1, j) == "100%")
      nxt = j + 2
    elseif b == 47 then -- /
      local k = j + 1
      while digit(byte(line, k)) do
        k = k + 1
      end
      if byte(line, k) == 93 then
        local num, den = line:sub(p + 1, j - 1), line:sub(j + 1, k - 1)
        paint(p - 1, k, num ~= "" and num == den)
        nxt = k + 1
      end
    end
    p = line:find("[", nxt, true)
  end
end

--- What each kind of line draws: list items (bullets, checkboxes, terms)
--- and statistics cookies.
local ITEMS = { text = true, qcomment = true }
local COOKIES = { text = true, qcomment = true, table = true, fixed = true }

--- Paint the rows of `ctx` (see org.ui.highlight `Ctx`).
---@param ctx org.ui.highlight.Ctx
function M.paint(ctx)
  local lists = require("org.lists")
  local t = lists.opt("ordered_item_terminator")
  local terms = t == "." and { [46] = true } or t == ")" and { [41] = true } or { [46] = true, [41] = true }
  local alpha = lists.opt("allow_alphabetical") and true or false
  local emit, lines, kinds = ctx.emit, ctx.lines, ctx.kinds
  local from = math.max(1, ctx.first - ctx.row0 + 1)
  local to = math.min(#lines, ctx.last - ctx.row0 + 1)
  for i = from, to do
    local line = lines[i]
    local kind = kinds[i]
    if ITEMS[kind] then
      local s = line:match("^[ \t]*()") ---@type integer
      if byte(line, s) then
        local be = bullet_end(line, s, terms, alpha)
        if be then
          emit(i, s - 1, be - 1, { hl_group = "orgListBullet", priority = PRIO.part, spell = false })
        end
        local ta, tb = term(line, s)
        if ta and tb then
          emit(i, ta - 1, tb, { hl_group = "orgListTerm", priority = PRIO.part, spell = false })
        end
        local bx, group = checkbox(line, s)
        if bx then
          -- (over the term it may be in: Emacs prepends the term's face
          -- after, but the box keeps its color)
          emit(i, bx - 1, bx + 2, { hl_group = group, priority = PRIO.part + 1, spell = false })
        end
      end
    end
    if COOKIES[kind] and line:find("[", 1, true) then
      cookies(line, function(col, end_col, done)
        emit(i, col, end_col, {
          hl_group = done and "orgStatisticDone" or "orgStatistic",
          priority = PRIO.object,
          spell = false,
        })
      end)
    end
  end
end

M._term = term
M._checkbox = checkbox

return M
