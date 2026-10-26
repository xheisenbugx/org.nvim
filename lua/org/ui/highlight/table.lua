---@mod org.ui.highlight.table Tables
---
--- Part of org.ui.highlight (the parser highlighter): table rows, separators and rules, formulas and cookies in cells, #+TBLFM lines and table.el tables.
---
--- A port of the "Table lines" and "Table internals" rules of
--- org-set-font-lock-defaults, each a regexp over one line:
---
---   "^[ \t]*\\(\\(|\\|\\+-[-+]\\).*\\S-\\)\n?"           (1 'org-table t)
---   "^[ \t]*|\\(?:.*?|\\)? *\\(:?=[^|\n]*\\)"             (1 'org-formula t)
---   "^[ \t]*| *\\([#*]\\) *|"                             (1 'org-formula t)
---   "^[ \t]*|\\( *\\([$!_^/]\\) *|.*\\)|"                 (1 'org-formula t)
---   "| *\\(<[lrc]?[0-9]*>\\)"                             (1 'org-formula t)
---
--- The formulas override the table face (`t`), so their bytes get
--- orgTableFormula and not orgTable or orgTableSeparator. A #+TBLFM line is
--- a keyword in Emacs (org-meta-line, drawn by org.ui.highlight.meta), not
--- a formula. Each line is scanned once, from its "|" positions: the time
--- is linear in its length.

local M = {}

local PRIO = require("org.ui.highlight").PRIO

local byte = string.byte

-- (blanks: what "\\S-" isn't in Org's syntax table)
local BLANK = { [32] = true, [9] = true, [12] = true, [13] = true }

local function is_digit(b)
  return b ~= nil and b >= 48 and b <= 57
end

--- The first byte at or after `p` of `line` that isn't a space (" *": only
--- spaces, not tabs).
local function skip_spaces(line, p)
  while byte(line, p) == 32 do
    p = p + 1
  end
  return p
end

--- The cookie (<l10>, <r>, <>, ...) that starts at `q`: its last byte.
local function cookie_end(line, q)
  if byte(line, q) ~= 60 then -- <
    return
  end
  local r = q + 1
  local b = byte(line, r)
  if b == 108 or b == 114 or b == 99 then -- l r c
    r = r + 1
  end
  while is_digit(byte(line, r)) do
    r = r + 1
  end
  if byte(line, r) == 62 then -- >
    return r
  end
end

--- Whether `line` is a property line (org-property-re: ":KEY: value"),
--- whose value org-property-value overrides (no cookie face in it).
local function property_line(line)
  return line:find("^[ \t]*:[-_%w\128-\255]+%+?:[ \t]") ~= nil or line:find("^[ \t]*:[-_%w\128-\255]+%+?:$") ~= nil
end

-- (org-deadline-string, org-scheduled-string, org-closed-string,
-- org-clock-string)
local SPECIAL = { "DEADLINE:", "SCHEDULED:", "CLOSED:", "CLOCK:" }

--- The byte ranges (1-based, inclusive) of the special keywords of `line`
--- ("\\<SCHEDULED:", ...: org-special-keyword overrides the table and
--- formula faces there), in order.
---@param line string
---@return integer[][]
local function specials(line)
  local out = {} ---@type integer[][]
  for _, word in ipairs(SPECIAL) do
    local p = line:find(word, 1, true)
    while p do
      local b = byte(line, p - 1)
      -- (at the start of a word: no letter, digit or other word byte before)
      if not (b and (b >= 128 or (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122))) then
        out[#out + 1] = { p, p + #word - 1 }
      end
      p = line:find(word, p + #word, true)
    end
  end
  table.sort(out, function(x, y)
    return x[1] < y[1]
  end)
  return out
end

--- The parts of [a, e] that no range of `cut` (sorted by start) covers.
---@param a integer
---@param e integer
---@param cut integer[][]
---@return integer[][]
local function minus(a, e, cut)
  local out = {} ---@type integer[][]
  for _, sp in ipairs(cut) do
    if sp[1] > e then
      break
    end
    if sp[1] > a then
      out[#out + 1] = { a, sp[1] - 1 }
    end
    a = math.max(a, sp[2] + 1)
  end
  if a <= e then
    out[#out + 1] = { a, e }
  end
  return out
end

--- The byte ranges (1-based, inclusive) of `line` in org-formula, and the
--- positions of its "|". `row`: whether it is a table row ("^[ \t]*|", the
--- "|" at `s`), else only cookies are looked for.
---@param line string
---@param row boolean
---@param s? integer
---@return integer[][] spans, integer[] bars
local function formulas(line, row, s)
  local bars = {} ---@type integer[]
  local p = row and s or line:find("|", 1, true)
  while p do
    bars[#bars + 1] = p
    p = line:find("|", p + 1, true)
  end
  local spans = {} ---@type integer[][]
  -- cookies, anywhere: "| *\\(<[lrc]?[0-9]*>\\)" (a match never holds a
  -- "|", so each "|" is tried)
  for _, bar in ipairs(bars) do
    local q = skip_spaces(line, bar + 1)
    local r = cookie_end(line, q)
    if r then
      spans[#spans + 1] = { q, r }
    end
  end
  if not row then
    return spans, bars
  end
  local n = #bars
  -- a field formula in the first cell that holds one: "|\\(?:.*?|\\)?" tries
  -- the cells after the first one (the optional group first, lazily), then
  -- the first one
  local function field(k)
    local q = skip_spaces(line, bars[k] + 1)
    local b = byte(line, q)
    if b == 58 and byte(line, q + 1) == 61 or b == 61 then -- ":=" or "="
      local e = bars[k + 1] and bars[k + 1] - 1 or #line
      spans[#spans + 1] = { q, e }
      return true
    end
    return false
  end
  local found = false
  for k = 2, n do
    if field(k) then
      found = true
      break
    end
  end
  if not found then
    field(1)
  end
  -- the marking column: "^[ \t]*| *\\([#*]\\) *|"
  local q = skip_spaces(line, s + 1)
  local b = byte(line, q)
  if (b == 35 or b == 42) and byte(line, skip_spaces(line, q + 1)) == 124 then
    spans[#spans + 1] = { q, q }
  end
  -- a special row: "^[ \t]*|\\( *\\([$!_^/]\\) *|.*\\)|", up to the last "|"
  if (b == 36 or b == 33 or b == 95 or b == 94 or b == 47) and n >= 3 then
    local second = skip_spaces(line, q + 1)
    if byte(line, second) == 124 and bars[n] > second then
      spans[#spans + 1] = { s + 1, bars[n] - 1 }
    end
  end
  table.sort(spans, function(x, y)
    return x[1] < y[1]
  end)
  return spans, bars
end

--- Paint the rows of `ctx` (see org.ui.highlight `Ctx`).
---@param ctx org.ui.highlight.Ctx
function M.paint(ctx)
  local lines, kinds, emit = ctx.lines, ctx.kinds, ctx.emit
  local from = math.max(1, ctx.first - ctx.row0 + 1)
  local to = math.min(#lines, ctx.last - ctx.row0 + 1)
  local element, part = PRIO.element, PRIO.part
  for i = from, to do
    local line = lines[i]
    local kind = kinds[i]
    -- (nothing in src, example and export blocks; the comment and keyword
    -- faces override the cookie face, like the property value face)
    if kind ~= "none" and kind ~= "comment" and kind ~= "info" then
      local s = line:match("^[ \t]*()") ---@type integer
      local c = byte(line, s)
      local row = c == 124
      local border = c == 43 and byte(line, s + 1) == 45 and (byte(line, s + 2) == 45 or byte(line, s + 2) == 43)
      if row or border then
        -- (no @Spell in orgTable: the rows aren't spell checked)
        emit(i, 0, #line, { spell = false, priority = element })
      end
      local spans, bars = {}, {} ---@type integer[][], integer[]
      if row or (line:find("|", 1, true) and not property_line(line)) then
        spans, bars = formulas(line, row, s)
      end
      local keys = {} ---@type integer[][]
      if row and line:find(":", 1, true) then
        keys = specials(line)
      end
      for _, sp in ipairs(spans) do
        for _, r in ipairs(#keys > 0 and minus(sp[1], sp[2], keys) or { sp }) do
          emit(i, r[1] - 1, r[2], { hl_group = "orgTableFormula", priority = part, spell = false })
        end
      end
      if row or border then
        -- the table face: from the "|" or "+-" to the last non-blank, with
        -- a non-blank after the "|" or "+-[-+]"
        local e = #line
        while e > s and BLANK[byte(line, e)] do
          e = e - 1
        end
        if e > (row and s or s + 2) then
          local hline = row and line:find("^[ \t]*|[-+]+|?[ \t]*$") ~= nil
          local hl = hline and "orgTableHline" or "orgTable"
          -- the bytes no formula or special keyword covers
          local cut = spans
          if #keys > 0 then
            cut = vim.list_extend(vim.list_extend({}, spans), keys)
            table.sort(cut, function(x, y)
              return x[1] < y[1]
            end)
          end
          for _, r in ipairs(minus(s, e, cut)) do
            emit(i, r[1] - 1, r[2], { hl_group = hl, priority = element })
          end
          if row and not hline then
            local k = 1
            for _, bar in ipairs(bars) do
              if bar > e then
                break
              end
              while cut[k] and cut[k][2] < bar do
                k = k + 1
              end
              if not (cut[k] and cut[k][1] <= bar) then
                emit(i, bar - 1, bar, { hl_group = "orgTableSeparator", priority = part })
              end
            end
          end
        end
      end
    end
  end
end

return M
