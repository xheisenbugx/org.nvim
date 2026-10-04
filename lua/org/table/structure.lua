---@mod org.table.structure Row, column and cell editing
---
--- Inserting, deleting and moving rows, columns and cells, and fixing the
--- #+TBLFM references they move (org-table-fix-formulas).
---
--- Part of org.table, which loads it.

local utils = require("org.utils")
local shared = require("org.table.shared")

local M = require("org.table")

local cursor_pos = shared.cursor_pos
local dline = shared.dline
local empty_row = shared.empty_row
local is_tblfm = shared.is_tblfm
local pad_rows = shared.pad_rows
local set_cursor = shared.set_cursor
local write_table = shared.write_table

---------------------------------------------------------------------------
-- Fixing formulas after structure edits (Emacs org-table-fix-formulas)
---------------------------------------------------------------------------

--- Rewrite the #+TBLFM lines below the table that ends at `finish` after
--- rows (`key` "@") or columns (`key` "$") changed: numbers in `replace`
--- ({ [old] = new }) are swapped, others above `limit` shift by `delta`,
--- and formulas assigning to row/column `remove` are dropped. References
--- inside remote(...) are left alone. Asks first when
--- `table_fix_formulas_confirm` is set (org-table-fix-formulas-confirm).
function M.fix_formulas(bufnr, finish, key, replace, limit, delta, remove)
  bufnr = bufnr or 0
  replace = replace or {}
  local lnums = {}
  local l = finish + 1
  while is_tblfm(vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]) do
    lnums[#lnums + 1] = l
    l = l + 1
  end
  if #lnums == 0 then
    return false
  end
  if require("org.config").opts.table_fix_formulas_confirm and not utils.confirm("Fix formulas?") then
    return false
  end
  local pat = (key == "$" and "%$" or "@") .. "(%d+)"
  local function shift(text)
    return (
      text:gsub(pat, function(n)
        local new = replace[n]
        if new then
          return key .. new
        elseif limit and tonumber(n) > limit then
          return key .. (tonumber(n) + delta)
        end
      end)
    )
  end
  for _, lnum in ipairs(lnums) do
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    local prefix, body = line:match("^(%s*#%+[Tt][Bb][Ll][Ff][Mm]:%s*)(.*)$")
    if remove then
      local kept = {}
      for part in (body .. "::"):gmatch("(.-)::") do
        local lhs = vim.trim(part:match("^(.-)=") or "")
        local drop
        if key == "$" then
          drop = lhs == "$" .. remove or lhs:match("^@%d+%$" .. remove .. "$") ~= nil
        else
          drop = lhs:match("^@" .. remove .. "%$%d+$") ~= nil
        end
        if not drop then
          kept[#kept + 1] = part
        end
      end
      body = table.concat(kept, "::")
    end
    -- leave remote(...) references alone
    local out, i = {}, 1
    while true do
      local a, b = body:find("remote%b()", i)
      out[#out + 1] = shift(body:sub(i, (a or #body + 1) - 1))
      if not a then
        break
      end
      out[#out + 1] = body:sub(a, b)
      i = b + 1
    end
    local new = prefix .. table.concat(out)
    if new ~= line then
      vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new })
    end
  end
  return true
end

--- Insert an empty row above (`above` = true) or below the current row.
--- A `#`, `*` or `$` mark in the first column is copied, and row
--- references in the formulas are shifted. Emacs org-table-insert-row.
function M.insert_row(above)
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field = cursor_pos(info)
  local t = info.tbl
  pad_rows(t)
  local at = above and row or row + 1
  local new = empty_row(t.ncols)
  local cur = t.rows[row]
  if not cur.hline and (cur.cells[1] == "#" or cur.cells[1] == "*" or cur.cells[1] == "$") then
    new.cells[1] = cur.cells[1]
  end
  table.insert(t.rows, at, new)
  local lines = write_table(info, t)
  M.fix_formulas(0, info.finish, "@", nil, dline(t, at) - 1, 1)
  set_cursor(info, lines, at, field, 0)
end

--- Delete the current row (or hline); formulas referring to it become
--- `@INVALID` and those assigning to it are removed. Emacs
--- org-table-kill-row.
function M.delete_row()
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field = cursor_pos(info)
  local t = info.tbl
  local dl = not t.rows[row].hline and dline(t, row) or nil
  if #t.rows == 1 then
    vim.api.nvim_buf_set_lines(0, info.start - 1, info.finish, false, {})
    return
  end
  table.remove(t.rows, row)
  local lines = write_table(info, t)
  if dl then
    M.fix_formulas(0, info.finish, "@", { [tostring(dl)] = "INVALID" }, dl, -1, dl)
  end
  set_cursor(info, lines, math.min(row, #lines), field, 0)
end

function M.insert_hline(above)
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field = cursor_pos(info)
  local t = info.tbl
  table.insert(t.rows, above and row or row + 1, { hline = true })
  local lines = write_table(info, t)
  set_cursor(info, lines, above and row + 1 or row, field, 0)
end

--- Insert an empty column left of the current one (column references
--- from there on shift). Emacs org-table-insert-column.
function M.insert_column()
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field = cursor_pos(info)
  local t = info.tbl
  pad_rows(t)
  for _, r in ipairs(t.rows) do
    if not r.hline then
      table.insert(r.cells, field, "")
    end
  end
  t.ncols = t.ncols + 1
  local lines = write_table(info, t)
  M.shift_shrunk(info.start, function(c)
    return c < field and c or c + 1
  end)
  M.fix_formulas(0, info.finish, "$", nil, field - 1, 1)
  set_cursor(info, lines, row, field, 0)
end

--- Delete the current column; references to it become `$INVALID`, formulas
--- assigning to it are removed. Emacs org-table-delete-column.
function M.delete_column()
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field = cursor_pos(info)
  local t = info.tbl
  pad_rows(t)
  if t.ncols <= 1 then
    vim.api.nvim_buf_set_lines(0, info.start - 1, info.finish, false, {})
    return
  end
  for _, r in ipairs(t.rows) do
    if not r.hline then
      table.remove(r.cells, field)
    end
  end
  t.ncols = t.ncols - 1
  local lines = write_table(info, t)
  M.shift_shrunk(info.start, function(c)
    return c < field and c or (c > field and c - 1 or nil)
  end)
  M.fix_formulas(0, info.finish, "$", { [tostring(field)] = "INVALID" }, field, -1, field)
  set_cursor(info, lines, row, math.min(field, t.ncols), 0)
end

function M.move_column(dir)
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field = cursor_pos(info)
  local t = info.tbl
  pad_rows(t)
  local other = field + dir
  if other < 1 or other > t.ncols then
    utils.warn("Cannot move column further")
    return
  end
  for _, r in ipairs(t.rows) do
    if not r.hline then
      r.cells[field], r.cells[other] = r.cells[other], r.cells[field]
    end
  end
  local lines = write_table(info, t)
  M.shift_shrunk(info.start, function(c)
    return c == field and other or (c == other and field or c)
  end)
  M.fix_formulas(0, info.finish, "$", { [tostring(field)] = tostring(other), [tostring(other)] = tostring(field) })
  set_cursor(info, lines, row, other, 0)
end

function M.move_row(dir)
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field = cursor_pos(info)
  local t = info.tbl
  local other = row + dir
  if other < 1 or other > #t.rows then
    utils.warn("Cannot move row further")
    return
  end
  local swap = not t.rows[row].hline and not t.rows[other].hline
  local d1, d2 = dline(t, row), dline(t, other)
  t.rows[row], t.rows[other] = t.rows[other], t.rows[row]
  local lines = write_table(info, t)
  if swap then
    M.fix_formulas(0, info.finish, "@", { [tostring(d1)] = tostring(d2), [tostring(d2)] = tostring(d1) })
  end
  set_cursor(info, lines, other, field, 0)
end

--- Swap the current field with its neighbour in `dir` ("up", "down",
--- "left" or "right"), skipping hlines, and follow it. Emacs S-<arrows>
--- in a table (org-table-move-cell-up/down/left/right).
---@param dir "up"|"down"|"left"|"right"
function M.move_cell(dir)
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field = cursor_pos(info)
  local t = info.tbl
  pad_rows(t)
  if t.rows[row].hline then
    utils.warn("Not in a table data field")
    return
  end
  local r2, f2 = row, field
  if dir == "left" or dir == "right" then
    f2 = field + (dir == "left" and -1 or 1)
  else
    local step = dir == "up" and -1 or 1
    r2 = row + step
    while t.rows[r2] and t.rows[r2].hline do
      r2 = r2 + step
    end
  end
  if not t.rows[r2] or f2 < 1 or f2 > t.ncols then
    utils.warn("Cannot move cell further")
    return
  end
  local a, b = t.rows[row].cells, t.rows[r2].cells
  a[field], b[f2] = b[f2], a[field]
  local lines = write_table(info, t)
  set_cursor(info, lines, r2, f2, 0)
end
