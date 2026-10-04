---@mod org.table.fields Commands on table fields
---
--- Editing a field (C-c `), summing (C-c +), blanking (C-c SPC) and
--- copying a field down with increment (S-RET).
---
--- Part of org.table, which loads it.

local utils = require("org.utils")
local shared = require("org.table.shared")

local M = require("org.table")

local before_move = shared.before_move
local current_field = shared.current_field
local cursor_pos = shared.cursor_pos
local dline = shared.dline
local maybe_recalc_line = shared.maybe_recalc_line
local new_row_at = shared.new_row_at
local reload = shared.reload
local selected_rect = shared.selected_rect
local set_cursor = shared.set_cursor
local write_table = shared.write_table

local function escape_cell(s)
  return (s:gsub("\n", " "):gsub("|", "\\vert{}"))
end

--- Edit the full content of the current field in a prompt, then realign.
--- Count 4 (C-u) shows the field's column in full when it is shrunk; count
--- 16 (C-u C-u) toggles follow-field mode (see |org-table-follow-field|).
--- Emacs `C-c `` (org-table-edit-field).
---@param count? integer
function M.edit_field(count)
  count = count or vim.v.count
  local info, row, field = current_field()
  if not info then
    return false
  end
  if count >= 16 then
    return require("org.table.follow").toggle()
  elseif count >= 4 then
    local shrink = require("org.table.shrink")
    local cols = shrink.get(0, info.start)
    cols[field] = nil
    return shrink.set(0, info.start, cols)
  end
  local t = info.tbl
  if t.rows[row].hline then
    utils.warn("Not in a table data field")
    return
  end
  local value = utils.input({
    prompt = string.format("Field @%d$%d: ", dline(t, row), field),
    default = t.rows[row].cells[field],
  })
  if value == nil then
    return
  end
  t.rows[row].cells[field] = escape_cell(vim.trim(value))
  local lines = write_table(info, t)
  set_cursor(info, lines, row, field, 0)
end

--- The value a field adds to a sum (Emacs org-table--number-for-summing):
--- its leading number (text and empty fields are skipped, `0` counts), or
--- H:MM[:SS] as hours (then `is_time` is true).
local function number_for_summing(s)
  local formula = require("org.table.formula")
  s = vim.trim(s)
  local n, isfloat = formula.string_to_number(s)
  if s:find("0", 1, true) and s:match("^[-+ \t0.edED]+$") then
    return 0, false, false
  end
  local h, m, sec = s:match("^(%d+):(%d+):(%d+)$")
  if not h then
    h, m = s:match("^(%d+):(%d+)$")
  end
  if h then
    return tonumber(h) + tonumber(m) / 60 + (tonumber(sec) or 0) / 3600, true, true
  end
  if n == 0 then
    return nil
  end
  return n, false, isfloat
end

--- Sum the numbers (and H:MM[:SS] durations) of the current column, or of
--- the fields in the visual selection. As soon as one field is a duration,
--- plain numbers count as hours and the sum is H:MM:SS. The result is
--- shown and stored in the unnamed register. Emacs `C-c +` (org-table-sum).
function M.sum()
  local info, rows, c1, c2 = selected_rect(true)
  if not info then
    return false
  end
  local t = info.tbl
  local total, count, times, isfloat = 0, 0, 0, false
  for _, r in ipairs(rows) do
    for c = c1, c2 do
      local n, is_time, fl = number_for_summing(t.rows[r].cells[c] or "")
      if n then
        total, count = total + n, count + 1
        times = times + (is_time and 1 or 0)
        isfloat = isfloat or fl
      end
    end
  end
  local s
  if times > 0 then
    local diff = 3600 * total
    local h = math.floor(diff / 3600)
    diff = diff % 3600
    local m = math.floor(diff / 60)
    diff = diff % 60
    s = string.format("%.0f:%02.0f:%02.0f", h, m, diff)
  else
    s = require("org.table.formula").number_to_string(total, isfloat)
  end
  vim.fn.setreg('"', s)
  utils.notify(string.format("Sum of %d items: %s", count, s))
  return s
end

--- Blank the current field (or every field in the visual selection) and
--- realign. Emacs `C-c SPC` (org-table-blank-field).
function M.blank_field()
  local info, rows, c1, c2 = selected_rect(false)
  if not info then
    return false
  end
  local t = info.tbl
  for _, r in ipairs(rows) do
    for c = c1, c2 do
      t.rows[r].cells[c] = ""
    end
  end
  local row, field = cursor_pos(info)
  local lines = write_table(info, t)
  set_cursor(info, lines, row, math.min(field, t.ncols), 0)
end

--- Next value in a copy-down series: numbers, numbers prefixed or
--- suffixed to text, and timestamps (by days) are incremented by the
--- difference to `previous` when it has the same shape, else by `step`.
--- Emacs org-table--increment-field.
---@param value string
---@param previous? string
---@param step number
function M.increment_field(value, previous, step)
  -- number-to-string: integers as such, floats like Emacs prints them
  -- (3.0, 0.30000000000000004)
  local function num_str(n, isfloat)
    if not isfloat and n == math.floor(n) and math.abs(n) < 2 ^ 53 then
      return string.format("%d", n)
    end
    local elisp = require("org.table.elisp")
    return elisp.to_string(elisp.float(n))
  end
  local function analyze(s)
    if not s or s == "" then
      return nil
    end
    local n = s:match("^[-+]?%d+%.?$") or s:match("^[-+]?%d*%.%d+$") or s:match("^[-+]?%d+%.?%d*[eE][-+]?%d+$")
    if n then
      -- string-to-number: a float with a fraction or an exponent ("5." is
      -- an integer)
      local float = n:find("[eE]") ~= nil or n:find("%.%d") ~= nil
      return "number", tonumber((n:gsub("^%+", ""):gsub("%.$", ""))), float
    end
    local pre = s:match("^%d+")
    if pre then
      return "prefix", tonumber(pre), s:sub(#pre + 1)
    end
    local suf = s:match("%d+$")
    if suf then
      return "suffix", tonumber(suf), s:sub(1, #s - #suf)
    end
    local item = require("org.date").parse_all(s)[1]
    if item then
      return "timestamp", item, nil
    end
  end
  local kind, v1, p1 = analyze(value)
  local kind2, v2, p2 = analyze(previous)
  if kind == "number" then
    -- p1/p2 tell whether the numbers are floats
    local same = kind2 == "number"
    local float = p1 or (same and p2) or (not same and step ~= math.floor(step))
    return num_str(v1 + (same and (v1 - v2) or step), float)
  end
  local same = kind == kind2 and p1 == p2
  if kind == "prefix" then
    return num_str(v1 + (same and (v1 - v2) or step)) .. p1
  elseif kind == "suffix" then
    return p1 .. num_str(v1 + (same and (v1 - v2) or step))
  elseif kind == "timestamp" then
    local days = same and (v1.date:days() - v2.date:days()) or step
    local shifted = v1.date:add_with_range(days, "d")
    return value:sub(1, v1.start_col - 1) .. shifted:to_string() .. value:sub(v1.end_col + 1)
  end
  return value
end

--- Copy the current field one row down (creating the row when needed) and
--- move with it; in an empty field, copy the nearest non-empty field above
--- (the Nth with a count). Numbers, numbered text and timestamps are
--- incremented (`table_copy_increment`). Emacs S-RET (org-table-copy-down).
---@param n? integer
function M.copy_down(n)
  local info, row, field = current_field()
  if not info then
    return false
  end
  n = n or math.max(vim.v.count, 1)
  local t = info.tbl
  if t.rows[row].hline then
    utils.warn("Not in a table data field")
    return
  end
  local function above(r)
    r = r - 1
    if t.rows[r] and not t.rows[r].hline then
      local v = t.rows[r].cells[field]
      return v ~= "" and v or nil
    end
  end
  local initial = t.rows[row].cells[field]
  local value, src = initial, row
  if value == "" then
    value = nil
    for r = row - 1, 1, -1 do
      local v = not t.rows[r].hline and t.rows[r].cells[field] or ""
      if v ~= "" then
        if n > 1 then
          n = n - 1
        else
          value, src = v, r
          break
        end
      end
    end
    if not value then
      utils.warn("No non-empty field found")
      return
    end
  end
  local inc = require("org.config").opts.table_copy_increment
  if inc ~= false and inc ~= nil and n ~= 0 then
    value = M.increment_field(value, type(inc) ~= "number" and above(src) or nil, type(inc) == "number" and inc or 1)
  end
  local target, added = row, false
  if initial ~= "" then
    -- org-table-next-row: a `#` row is recalculated before leaving it, and
    -- a new row is added like org-table-insert-row
    info = before_move(info, row, field, true)
    t = info.tbl
    target = row + 1
    if not t.rows[target] or t.rows[target].hline then
      table.insert(t.rows, target, new_row_at(t, target))
      added = true
    end
  end
  t.rows[target].cells[field] = value
  write_table(info, t)
  if added then
    M.fix_formulas(0, info.finish, "@", nil, dline(t, target) - 1, 1)
  end
  info = reload(info)
  if maybe_recalc_line(info, target) then
    info = reload(info)
  end
  set_cursor(info, info.lines, target, field, #value)
end
