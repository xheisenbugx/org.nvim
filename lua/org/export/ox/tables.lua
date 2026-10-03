---@mod org.export.ox.tables Table helpers for back-ends (org-export-table-*)
---
--- Part of org.export.ox, which loads it: the functions are fields of
--- that module.

local element = require("org.export.element")
local M = require("org.export.ox")

local cfg = M.cfg

---------------------------------------------------------------------------
-- Tables
---------------------------------------------------------------------------

local function cell_text(cell)
  local c = cell and cell.contents or {}
  if #c == 0 then
    return nil
  end
  if #c == 1 and c[1].type == "plain-text" then
    return c[1].value
  end
  return false
end

function M.table_has_special_column_p(tbl)
  local special = "empty"
  for _, row in ipairs(tbl.contents) do
    if row.row_type == "standard" then
      local v = cell_text(row.contents[1])
      if v and ({ ["/"] = 1, ["#"] = 1, ["!"] = 1, ["$"] = 1, ["*"] = 1, ["_"] = 1, ["^"] = 1 })[v] then
        special = "special"
      elseif v == nil then
        -- empty
      else
        return false
      end
    end
  end
  return special == "special"
end

function M.table_row_is_special_p(row, _)
  if row.row_type ~= "standard" then
    return false
  end
  local first = cell_text(row.contents[1])
  if first == "/" then
    return true
  end
  if M.table_has_special_column_p(row.parent) and ({ ["^"] = 1, ["_"] = 1, ["$"] = 1, ["!"] = 1 })[first or ""] then
    return true
  end
  local special = "empty"
  for _, cell in ipairs(row.contents) do
    local v = cell_text(cell)
    if v == nil then
      -- empty
    elseif v and v:match("^<[lrc]?%d*>$") then
      special = "cookie"
    else
      return false
    end
  end
  return special == "cookie"
end

function M.table_has_header_p(tbl, info)
  local cache = info.table_header_cache
  if cache[tbl] ~= nil then
    return cache[tbl]
  end
  local rowgroup, flag = 1, false
  local result = false
  for _, row in ipairs(tbl.contents) do
    if not info.ignore[row] then
      if rowgroup > 1 then
        result = true
        break
      end
      if flag and row.row_type == "rule" then
        rowgroup = rowgroup + 1
        flag = false
      elseif not flag and row.row_type == "standard" then
        flag = true
      end
    end
  end
  cache[tbl] = result
  return result
end

function M.table_row_group(row, info)
  if row.row_type ~= "standard" then
    return nil
  end
  local cache = info.table_row_group_cache
  if cache[row] == nil then
    local group, flag = 0, false
    for _, r in ipairs(row.parent.contents) do
      if not info.ignore[r] then
        if r.row_type == "rule" then
          flag = false
        else
          if not flag then
            group = group + 1
            flag = true
          end
          cache[r] = group
        end
      end
    end
  end
  return cache[row]
end

local function column_of(cell)
  for i, c in ipairs(cell.parent.contents) do
    if c == cell then
      return i
    end
  end
end

function M.table_cell_width(cell, info)
  local row = cell.parent
  local tbl = row.parent
  local col = column_of(cell)
  local cache = info.table_cell_width_cache
  cache[tbl] = cache[tbl] or {}
  if cache[tbl][col] == nil then
    local w = false
    for _, r in ipairs(tbl.contents) do
      if M.table_row_is_special_p(r, info) then
        local v = cell_text(r.contents[col])
        local n = v and v:match("^<[lrc]?(%d+)>$")
        if n then
          w = tonumber(n)
          break
        end
      end
    end
    cache[tbl][col] = w
  end
  return cache[tbl][col] or nil
end

local NUMBER_RE = {
  "^[<>]?[-+^.0-9]*[0-9][-+^.0-9eEdDx()%%:]*$",
  "^[<>]?[-+]?0[xX][%x.]+$",
  "^[<>]?[-+]?[0-9]+#[0-9a-zA-Z.]+$",
  "^nan$",
  "^[-+u]?inf$",
}
function M.table_number_p(s)
  for _, p in ipairs(NUMBER_RE) do
    if s:match(p) then
      return true
    end
  end
  return false
end

function M.table_cell_alignment(cell, info)
  local row = cell.parent
  local tbl = row.parent
  local col = column_of(cell)
  local cache = info.table_cell_alignment_cache
  cache[tbl] = cache[tbl] or {}
  if cache[tbl][col] then
    return cache[tbl][col]
  end
  local number_cells, total = 0, 0
  local cookie
  local prev_num = false
  for _, r in ipairs(tbl.contents) do
    if M.table_row_is_special_p(r, info) then
      local v = cell_text(r.contents[col])
      local a = v and v:match("^<([lrc])%d*>$")
      if a then
        cookie = a
      end
    elseif r.row_type == "rule" then
      -- ignore
    elseif not cookie then
      local v = M.data(r.contents[col] and r.contents[col].contents or {}, info)
      total = total + 1
      if M.table_number_p(v) or (v == "" and prev_num) then
        prev_num = true
        number_cells = number_cells + 1
      else
        prev_num = false
      end
    end
  end
  local fraction = cfg().table_number_fraction or 0.5
  local a
  if cookie == "l" then
    a = "left"
  elseif cookie == "r" then
    a = "right"
  elseif cookie == "c" then
    a = "center"
  elseif total > 0 and number_cells / total >= fraction then
    a = "right"
  else
    a = "left"
  end
  cache[tbl][col] = a
  return a
end

function M.table_cell_borders(cell, info)
  local row = cell.parent
  local tbl = element.lineage(cell, "table")
  local borders = {}
  local rows = tbl.contents
  local idx
  for i, r in ipairs(rows) do
    if r == row then
      idx = i
    end
  end
  -- above
  local rule = false
  local found = false
  for i = idx - 1, 1, -1 do
    local r = rows[i]
    if r.row_type == "rule" then
      rule = true
    elseif not M.table_row_is_special_p(r, info) then
      if rule then
        borders.above = true
      end
      found = true
      break
    end
  end
  if not found then
    if rule then
      borders.above = true
    end
    borders.top = true
  end
  rule, found = false, false
  for i = idx + 1, #rows do
    local r = rows[i]
    if r.row_type == "rule" then
      rule = true
    elseif not M.table_row_is_special_p(r, info) then
      if rule then
        borders.below = true
      end
      found = true
      break
    end
  end
  if not found then
    if rule then
      borders.below = true
    end
    borders.bottom = true
  end
  -- column groups
  local col = column_of(cell)
  for i = #rows, 1, -1 do
    local r = rows[i]
    if r.row_type ~= "rule" and cell_text(r.contents[1]) == "/" then
      local groups = {}
      for k, c in ipairs(r.contents) do
        local v = cell_text(c)
        if v == "<" or v == "<>" or v == ">" then
          groups[k] = v
        end
      end
      if
        (col > 1 and (groups[col - 1] == ">" or groups[col - 1] == "<>"))
        or groups[col] == "<"
        or groups[col] == "<>"
      then
        borders.left = true
      end
      if
        (col < #r.contents and (groups[col + 1] == "<" or groups[col + 1] == "<>"))
        or groups[col] == ">"
        or groups[col] == "<>"
      then
        borders.right = true
      end
      break
    end
  end
  return borders
end

function M.table_cell_starts_colgroup_p(cell, info)
  local first
  for _, c in ipairs(cell.parent.contents) do
    if not info.ignore[c] then
      first = c
      break
    end
  end
  return first == cell or M.table_cell_borders(cell, info).left == true
end

function M.table_cell_ends_colgroup_p(cell, info)
  local cells = cell.parent.contents
  return cells[#cells] == cell or M.table_cell_borders(cell, info).right == true
end

local function first_cell(row, info)
  for _, c in ipairs(row.contents) do
    if not info.ignore[c] then
      return c
    end
  end
  return row.contents[1]
end

function M.table_row_starts_rowgroup_p(row, info)
  if row.row_type == "rule" or M.table_row_is_special_p(row, info) then
    return false
  end
  local b = M.table_cell_borders(first_cell(row, info), info)
  return b.top or b.above or false
end

function M.table_row_ends_rowgroup_p(row, info)
  if row.row_type == "rule" or M.table_row_is_special_p(row, info) then
    return false
  end
  local b = M.table_cell_borders(first_cell(row, info), info)
  return b.bottom or b.below or false
end

function M.table_row_in_header_p(row, info)
  return M.table_has_header_p(element.lineage(row, "table"), info) and M.table_row_group(row, info) == 1
end

function M.table_row_starts_header_p(row, info)
  return M.table_row_in_header_p(row, info) and M.table_row_starts_rowgroup_p(row, info)
end

function M.table_row_ends_header_p(row, info)
  return M.table_row_in_header_p(row, info) and M.table_row_ends_rowgroup_p(row, info)
end

function M.table_row_number(row, info)
  if row.row_type ~= "standard" then
    return nil
  end
  local n = -1
  for _, r in ipairs(row.parent.contents) do
    if r.row_type == "standard" and not info.ignore[r] then
      n = n + 1
      if r == row then
        return n
      end
    end
  end
end

function M.table_dimensions(tbl, info)
  local rows, cols = 0, 0
  local first
  for _, r in ipairs(tbl.contents) do
    if r.row_type == "standard" and not info.ignore[r] then
      rows = rows + 1
      first = first or r
    end
  end
  if first then
    for _, c in ipairs(first.contents) do
      if not info.ignore[c] then
        cols = cols + 1
      end
    end
  end
  return rows, cols
end

function M.table_cell_address(cell, info)
  local row = cell.parent
  local rn = M.table_row_number(row, info)
  if not rn then
    return nil
  end
  local c = 0
  for _, x in ipairs(row.contents) do
    if not info.ignore[x] then
      if x == cell then
        return rn, c
      end
      c = c + 1
    end
  end
end

function M.get_table_cell_at(r, c, tbl, info)
  local n = 0
  for _, row in ipairs(tbl.contents) do
    if row.row_type ~= "rule" and not info.ignore[row] then
      if n == r then
        local k = 0
        for _, x in ipairs(row.contents) do
          if not info.ignore[x] then
            if k == c then
              return x
            end
            k = k + 1
          end
        end
        return nil
      end
      n = n + 1
    end
  end
end
