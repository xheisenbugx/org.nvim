---@mod org.table Org tables
---
--- Parsing, alignment and editing of `| a | b |` tables, plus spreadsheet
--- formulas (`#+TBLFM:`, see `org.table.formula`).

local utils = require("org.utils")

local M = {}

---------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------

local function is_table_line(line)
  return line ~= nil and line:match("^%s*|") ~= nil
end
M.is_table_line = is_table_line

local function is_hline(line)
  return line:match("^%s*|%-") ~= nil
end

local function is_tblfm(line)
  return line ~= nil and line:match("^%s*#%+[Tt][Bb][Ll][Ff][Mm]:") ~= nil
end
M.is_tblfm = is_tblfm

--- Split a table row line into trimmed cells.
function M.split_cells(line)
  local body = line:gsub("^%s*|", "")
  if body:sub(-1) == "|" then
    body = body:sub(1, -2)
  end
  local cells = {}
  for cell in (body .. "|"):gmatch("([^|]*)|") do
    cells[#cells + 1] = vim.trim(cell)
  end
  return cells
end

--- Byte positions (1-based) of every `|` in a line.
local function pipe_positions(line)
  local out = {}
  local i = 0
  while true do
    i = line:find("|", i + 1, true)
    if not i then
      break
    end
    out[#out + 1] = i
  end
  return out
end

--- Parse lines into a table structure.
---@param lines string[]
---@return table { indent, rows = { {hline=true} | {cells={...}} }, ncols }
function M.parse(lines)
  local t = { indent = (lines[1] or ""):match("^(%s*)"), rows = {}, ncols = 0 }
  for _, line in ipairs(lines) do
    if is_hline(line) then
      t.rows[#t.rows + 1] = { hline = true }
    else
      local cells = M.split_cells(line)
      t.rows[#t.rows + 1] = { cells = cells }
      t.ncols = math.max(t.ncols, #cells)
    end
  end
  t.ncols = math.max(t.ncols, 1)
  return t
end

--- Locate the table containing `lnum` (or whose #+TBLFM line is `lnum`).
---@return table|nil { start, finish, tblfm = {lnums}, lines }
function M.find(bufnr, lnum)
  bufnr = bufnr or 0
  local n = vim.api.nvim_buf_line_count(bufnr)
  local function get(l)
    return vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]
  end
  local line = get(lnum)
  if is_tblfm(line) then
    local l = lnum
    while l > 1 and is_tblfm(get(l - 1)) do
      l = l - 1
    end
    lnum = l - 1
    line = get(lnum)
  end
  if lnum < 1 or not is_table_line(line) then
    return nil
  end
  local s, e = lnum, lnum
  while s > 1 and is_table_line(get(s - 1)) do
    s = s - 1
  end
  while e < n and is_table_line(get(e + 1)) do
    e = e + 1
  end
  local tblfm = {}
  local l = e + 1
  while l <= n and is_tblfm(get(l)) do
    tblfm[#tblfm + 1] = l
    l = l + 1
  end
  return { start = s, finish = e, tblfm = tblfm, lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false) }
end

--- Table info at cursor, or nil.
function M.at_cursor()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  if not is_table_line(line) then
    return nil
  end
  local info = M.find(0, lnum)
  if info then
    info.tbl = M.parse(info.lines)
  end
  return info
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local NUMBER = "^[<>]?[-+^.0-9]*[0-9][-+^.0-9eEdDx()%%:]*$"

function M.is_number(s)
  return s:match(NUMBER) ~= nil or s:match("^[-+]?inf$") ~= nil or s == "nan"
end

--- Whether every non-empty cell of `row` is a width/alignment cookie.
local function is_cookie_row(row)
  if row.hline then
    return false
  end
  local any = false
  for _, c in ipairs(row.cells) do
    if c ~= "" then
      if not c:match("^<[lrc]?%d*>$") then
        return false
      end
      any = true
    end
  end
  return any
end
M.is_cookie_row = is_cookie_row

--- Display width of a cell. Links count as their description (or path)
--- while `ui.conceal_links` hides the brackets, like Emacs aligning with
--- `org-link-descriptive`.
local function cell_width(s)
  if not s:find("[[", 1, true) or (require("org.config").opts.ui or {}).conceal_links == false then
    return utils.width(s)
  end
  local out, i = {}, 1
  while true do
    local a = s:find("[[", i, true)
    if not a then
      break
    end
    -- the link path may hold backslash-escaped brackets
    local k = a + 2
    while k <= #s and not s:sub(k, k):match("[%[%]]") do
      k = k + (s:sub(k, k) == "\\" and 2 or 1)
    end
    local after, visible = nil, nil
    if s:sub(k, k + 1) == "]]" then
      after, visible = k + 2, s:sub(a + 2, k - 1)
    elseif s:sub(k, k + 1) == "][" then
      local close = s:find("]]", k + 2, true)
      if close then
        after, visible = close + 2, s:sub(k + 2, close - 1)
      end
    end
    out[#out + 1] = s:sub(i, a - 1) .. (visible or "[[")
    i = after or a + 2
  end
  out[#out + 1] = s:sub(i)
  return utils.width(table.concat(out))
end
M.cell_width = cell_width

--- Column widths and alignments ("l", "r" or "c") of a parsed table, like
--- Emacs org-table-align: the first `<l>`/`<r>`/`<c>` cookie fixes the
--- alignment, else a column is right-aligned when at least
--- `table_number_fraction` of its non-empty fields are numbers.
function M.layout(t)
  local fraction = require("org.config").opts.table_number_fraction or 0.5
  local widths, align = {}, {}
  for c = 1, t.ncols do
    local w, fixed, numbers, nonempty = 1, nil, 0, 0
    for _, row in ipairs(t.rows) do
      if not row.hline then
        local cell = row.cells[c] or ""
        w = math.max(w, cell_width(cell))
        if fixed or cell == "" then
          -- nothing
        elseif cell:match("^<[lrc]%d*>$") then
          fixed = cell:sub(2, 2)
        else
          nonempty = nonempty + 1
          if M.is_number(cell) then
            numbers = numbers + 1
          end
        end
      end
    end
    widths[c] = w
    align[c] = fixed or (numbers >= fraction * nonempty and "r" or "l")
  end
  return widths, align
end

--- Render a parsed table into aligned lines.
function M.render(t)
  local ncols = t.ncols
  local widths, align = M.layout(t)
  local out = {}
  for _, row in ipairs(t.rows) do
    if row.hline then
      local parts = {}
      for c = 1, ncols do
        parts[c] = string.rep("-", widths[c] + 2)
      end
      out[#out + 1] = t.indent .. "|" .. table.concat(parts, "+") .. "|"
    else
      local parts = {}
      for c = 1, ncols do
        local cell = row.cells[c] or ""
        local pad = widths[c] - cell_width(cell)
        local a = align[c]
        if a == "r" then
          cell = string.rep(" ", pad) .. cell
        elseif a == "c" then
          local left = math.floor(pad / 2)
          cell = string.rep(" ", left) .. cell .. string.rep(" ", pad - left)
        else
          cell = cell .. string.rep(" ", pad)
        end
        parts[c] = " " .. cell .. " "
      end
      out[#out + 1] = t.indent .. "|" .. table.concat(parts, "|") .. "|"
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Cursor helpers
---------------------------------------------------------------------------

--- Field index (1-based) and offset within the trimmed cell at byte col.
local function field_at(line, col)
  local pipes = pipe_positions(line)
  local field = 0
  for _, p in ipairs(pipes) do
    if p < col then
      field = field + 1
    end
  end
  field = math.max(field, 1)
  local start = pipes[field] or 0
  local stop = pipes[field + 1] or (#line + 1)
  local content = line:sub(start + 1, stop - 1)
  local lead = #(content:match("^(%s*)"))
  local offset = col - (start + 1 + lead)
  local trimmed_len = #vim.trim(content)
  offset = math.max(0, math.min(offset, trimmed_len))
  return field, offset
end

--- Byte column (0-based) of field `f` content start in an aligned line.
local function field_col(line, f, offset)
  local pipes = pipe_positions(line)
  local p = pipes[f]
  if not p then
    return math.max(#line - 1, 0)
  end
  local stop = pipes[f + 1] or (#line + 1)
  local content = line:sub(p + 1, stop - 1)
  local lead = #(content:match("^(%s*)"))
  if content:match("^%s*$") then
    lead = math.min(1, #content)
  end
  return p + lead + (offset or 0)
end

--- Current cursor position in table terms.
local function cursor_pos(info)
  local lnum, col = utils.cursor()
  local line = vim.api.nvim_get_current_line()
  local row = lnum - info.start + 1
  local field, offset = field_at(line, col)
  return row, field, offset
end

local function write_table(info, t)
  local lines = M.render(t)
  local cur = vim.api.nvim_buf_get_lines(0, info.start - 1, info.finish, false)
  if not vim.deep_equal(cur, lines) then
    vim.api.nvim_buf_set_lines(0, info.start - 1, info.finish, false, lines)
  end
  info.finish = info.start + #lines - 1
  require("org.table.shrink").refresh(0, info.start)
  return lines
end

local function set_cursor(info, lines, row, field, offset)
  row = math.max(1, math.min(row, #lines))
  local line = lines[row]
  local col = field_col(line, field, offset)
  vim.api.nvim_win_set_cursor(0, { info.start + row - 1, col })
end

--- Normalize `t` to ncols columns per row.
local function pad_rows(t)
  for _, row in ipairs(t.rows) do
    if not row.hline then
      for c = #row.cells + 1, t.ncols do
        row.cells[c] = ""
      end
    end
  end
end

local function empty_row(ncols)
  local cells = {}
  for c = 1, ncols do
    cells[c] = ""
  end
  return { cells = cells }
end

-- Defined with the formula commands below.
local before_move

local function in_visual()
  local m = vim.fn.mode()
  return m == "v" or m == "V" or m == "\22"
end

--- Renumber shrunk columns after a column edit.
function M.shift_shrunk(start, map)
  require("org.table.shrink").shift(0, start, map)
end

--- Data-line number (Emacs `@N`, hlines not counted) of table row `row`.
local function dline(t, row)
  local n = 0
  for i = 1, row do
    if not t.rows[i].hline then
      n = n + 1
    end
  end
  return n
end

--- Put the cursor back on `row`/`field` of the table starting at `start`.
local function restore_cursor(start, row, field)
  local info = M.find(0, start)
  if info then
    set_cursor(info, info.lines, row, field, 0)
  end
end


--- Re-read the table starting at `info.start` (after a buffer change).
local function reload(info)
  local fresh = M.find(0, info.start)
  fresh.tbl = M.parse(fresh.lines)
  pad_rows(fresh.tbl)
  return fresh
end

---------------------------------------------------------------------------
-- Public actions
---------------------------------------------------------------------------

--- Realign the table at the cursor (keeps the cursor in the same field).
function M.align()
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field, offset = cursor_pos(info)
  local lines = write_table(info, info.tbl)
  set_cursor(info, lines, row, math.min(field, info.tbl.ncols), offset)
end

--- Realign the table containing `lnum` in `bufnr` without moving the cursor.
function M.align_at(bufnr, lnum)
  local info = M.find(bufnr, lnum)
  if not info then
    return
  end
  local lines = M.render(M.parse(info.lines))
  if not vim.deep_equal(lines, info.lines) then
    vim.api.nvim_buf_set_lines(bufnr, info.start - 1, info.finish, false, lines)
  end
end

--- Move to the next field (insert-mode <Tab>); creates a row at the end.
function M.next_field()
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field = cursor_pos(info)
  info = before_move(info, row, field)
  local t = info.tbl
  pad_rows(t)
  -- move out of an hline row
  local target_row, target_field = row, field + 1
  if t.rows[row].hline or target_field > t.ncols then
    target_field = 1
    target_row = row + 1
    while t.rows[target_row] and t.rows[target_row].hline do
      target_row = target_row + 1
    end
    if not t.rows[target_row] then
      table.insert(t.rows, empty_row(t.ncols))
      target_row = #t.rows
    end
  end
  local lines = write_table(info, t)
  set_cursor(info, lines, target_row, target_field, 0)
end

--- Move to the previous field (insert-mode <S-Tab>).
function M.prev_field()
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field = cursor_pos(info)
  info = before_move(info, row, field, true)
  local t = info.tbl
  pad_rows(t)
  local target_row, target_field = row, field - 1
  if t.rows[row].hline or target_field < 1 then
    target_row = row - 1
    while t.rows[target_row] and t.rows[target_row].hline do
      target_row = target_row - 1
    end
    if not t.rows[target_row] then
      target_row, target_field = row, 1
    else
      target_field = t.ncols
    end
  end
  local lines = write_table(info, t)
  set_cursor(info, lines, target_row, target_field, 0)
end

--- Move to the same column in the next row (insert-mode <CR>).
function M.next_row()
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field = cursor_pos(info)
  info = before_move(info, row, field)
  local t = info.tbl
  pad_rows(t)
  local nxt = t.rows[row + 1]
  if not nxt or nxt.hline then
    table.insert(t.rows, row + 1, empty_row(t.ncols))
  end
  local lines = write_table(info, t)
  set_cursor(info, lines, row + 1, field, 0)
end

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
    return (text:gsub(pat, function(n)
      local new = replace[n]
      if new then
        return key .. new
      elseif limit and tonumber(n) > limit then
        return key .. (tonumber(n) + delta)
      end
    end))
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

--- Text of a field without emphasis markers and link brackets (a link
--- sorts as its description). Emacs org-sort-remove-invisible.
function M.remove_invisible(s)
  s = s:gsub("%[%[([^%]]-)%]%[(.-)%]%]", "%2"):gsub("%[%[([^%]]-)%]%]", "%1")
  local out, i, n = {}, 1, #s
  while i <= n do
    local ch = s:sub(i, i)
    local prev = i == 1 and " " or s:sub(i - 1, i - 1)
    local close
    if ch:match("[*/_+=~]") and prev:match("[%s%-({'\"]") and s:sub(i + 1, i + 1):match("%S") then
      local j = i + 1
      while true do
        j = s:find(ch, j + 1, true)
        if not j then
          break
        end
        local after = j == n and " " or s:sub(j + 1, j + 1)
        if s:sub(j - 1, j - 1):match("%S") and after:match("[%s%-%.,:!?;'\")}%]]") then
          close = j
          break
        end
      end
    end
    if close then
      out[#out + 1] = M.remove_invisible(s:sub(i + 1, close - 1))
      i = close + 1
    else
      out[#out + 1] = ch
      i = i + 1
    end
  end
  return table.concat(out)
end

--- Sort key of a field for sorting type `kind` (a, n, t).
local function sort_key(kind, v)
  if kind == "n" then
    return (require("org.table.formula").string_to_number(v))
  elseif kind == "t" then
    local date = require("org.date")
    local item = date.parse_all(v)[1]
    if item then
      return item.date:to_time()
    end
    local mins = date.parse_duration(v)
    if mins and (v:match("^%s*%d+:%d%d") or v:match("%a")) then
      return mins
    end
    local hm = v:match("%f[%d](%d+:%d%d)%f[^%d]")
    return hm and date.parse_duration(hm) or 0
  end
  return M.remove_invisible(v)
end

--- Read a Lua function for `f`/`F` sorting (an expression such as
--- `function(s) return #s end` or the name of a global function).
local function read_function(prompt, allow_empty)
  local text = utils.input({ prompt = prompt })
  if text == nil or (vim.trim(text) == "" and allow_empty) then
    return nil
  end
  local chunk = load("return " .. text, "sort", "t", setmetatable({}, { __index = _G }))
  local ok, fn = false, nil
  if chunk then
    ok, fn = pcall(chunk)
  end
  if not ok or type(fn) ~= "function" then
    utils.warn("Not a function: " .. text)
    utils.abort()
  end
  return fn
end

--- Sort the rows of the current hline-delimited section (or the rows of
--- the visual selection) by the current column. Types: a (text without
--- markup; case-insensitive unless `opts.with_case`, set by a count like
--- Emacs' C-u), n (numbers), t (timestamps, durations, H:MM), f (a key
--- function, prompted as Lua, with an optional comparison function);
--- uppercase sorts in reverse. Emacs org-table-sort-lines (C-c ^).
---@param opts? { type?: string, with_case?: boolean, getkey?: fun(field: string): any, compare?: fun(a: any, b: any): boolean }
function M.sort_column(opts)
  opts = type(opts) == "table" and opts or {}
  local visual = in_visual()
  local srow, scol, erow
  if visual then
    srow, scol, erow = utils.visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    vim.api.nvim_win_set_cursor(0, { srow, math.max(scol - 1, 0) })
  end
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field = cursor_pos(info)
  local t = info.tbl
  pad_rows(t)
  if t.rows[row].hline then
    utils.warn("Place the cursor on a data row")
    return
  end
  local with_case = opts.with_case
  if with_case == nil then
    with_case = vim.v.count > 0
  end
  local choice = opts.type
    or require("org.ui").menu({
      title = "Sort table by column " .. field,
      items = {
        { key = "a", label = "alphabetically", value = "a" },
        { key = "A", label = "alphabetically (reverse)", value = "A" },
        { key = "n", label = "numerically", value = "n" },
        { key = "N", label = "numerically (reverse)", value = "N" },
        { key = "t", label = "by time/date", value = "t" },
        { key = "T", label = "by time/date (reverse)", value = "T" },
        { key = "f", label = "by a key function", value = "f" },
        { key = "F", label = "by a key function (reverse)", value = "F" },
      },
    })
  if not choice then
    return
  end
  local s, e = row, row
  if visual then
    s = math.max(srow, info.start) - info.start + 1
    e = math.min(erow, info.finish) - info.start + 1
  else
    while s > 1 and not t.rows[s - 1].hline do
      s = s - 1
    end
    while e < #t.rows and not t.rows[e + 1].hline do
      e = e + 1
    end
  end
  local kind = choice:lower()
  local getkey, compare = opts.getkey, opts.compare
  if kind == "f" and not getkey then
    getkey = read_function("Function for extracting keys: ")
    compare = compare or read_function("Function for comparing keys (empty for default): ", true)
  end
  local reverse = choice ~= kind
  -- only data rows move; hlines inside a selected region stay in place
  local slots, slice = {}, {}
  for i = s, e do
    if not t.rows[i].hline then
      slots[#slots + 1] = i
      local r = t.rows[i]
      local v = vim.trim(r.cells[field] or "")
      local k
      if kind == "f" then
        k = getkey(v)
      else
        k = sort_key(kind, v)
        if kind == "a" and not with_case then
          k = k:lower()
        end
      end
      slice[#slice + 1] = { row = r, key = k, i = #slice + 1 }
    end
  end
  local less = compare or function(a, b)
    return a < b
  end
  table.sort(slice, function(a, b)
    local x, y = a.key, b.key
    if reverse then
      x, y = y, x
    end
    if less(x, y) then
      return true
    elseif less(y, x) then
      return false
    end
    return a.i < b.i
  end)
  for i, item in ipairs(slice) do
    t.rows[slots[i]] = item.row
  end
  local lines = write_table(info, t)
  set_cursor(info, lines, row, field, 0)
end

---------------------------------------------------------------------------
-- Creation / conversion
---------------------------------------------------------------------------

local function split_csv(line)
  local out, i, n = {}, 1, #line
  while i <= n + 1 do
    local c = line:sub(i, i)
    if c == '"' then
      local buf = {}
      i = i + 1
      while i <= n do
        local ch = line:sub(i, i)
        if ch == '"' then
          if line:sub(i + 1, i + 1) == '"' then
            buf[#buf + 1] = '"'
            i = i + 2
          else
            i = i + 1
            break
          end
        else
          buf[#buf + 1] = ch
          i = i + 1
        end
      end
      out[#out + 1] = table.concat(buf)
      -- skip to comma
      local nxt = line:find(",", i, true)
      i = (nxt or n + 1) + 1
    else
      local nxt = line:find(",", i, true)
      out[#out + 1] = vim.trim(line:sub(i, (nxt or n + 1) - 1))
      i = (nxt or n + 1) + 1
    end
  end
  return out
end

--- Convert lines of CSV/TSV/whitespace data into table lines.
---@param sep? "tab"|"csv"|"space"|integer an integer N splits on N+ spaces or tabs
function M.convert_lines(lines, sep)
  local indent = (lines[1] or ""):match("^(%s*)")
  if not sep then
    local joined = table.concat(lines, "\n")
    if joined:find("\t") then
      sep = "tab"
    elseif joined:find(",") then
      sep = "csv"
    else
      sep = "space"
    end
  end
  local t = { indent = indent, rows = {}, ncols = 1 }
  for _, l in ipairs(lines) do
    if not l:match("^%s*$") then
      local cells
      if sep == "tab" then
        cells = vim.split(vim.trim(l), "\t", { plain = true })
      elseif sep == "csv" then
        cells = split_csv(vim.trim(l))
      elseif type(sep) == "number" then
        -- N or more spaces, or a tab (Emacs C-N C-c |)
        cells = vim.split((vim.trim(l):gsub(string.rep(" ", sep) .. "+", "\t")), "%s*\t%s*")
      else
        cells = vim.split(vim.trim(l), "%s+")
      end
      for i, c in ipairs(cells) do
        cells[i] = vim.trim(c):gsub("|", "\\vert{}")
      end
      t.rows[#t.rows + 1] = { cells = cells }
      t.ncols = math.max(t.ncols, #cells)
    end
  end
  pad_rows(t)
  return M.render(t)
end

--- Separator for a count given to a conversion command, like Emacs'
--- prefix argument: 4 (C-u) comma, 16 (C-u C-u) tab, another N that many
--- spaces (or a tab); no count guesses from the data.
function M.separator_for_count(count)
  if not count or count == 0 then
    return nil
  elseif count == 4 then
    return "csv"
  elseif count == 16 then
    return "tab"
  end
  return count
end

--- Create an empty table (normal mode) or convert the visual selection.
function M.create_or_convert()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local sep = M.separator_for_count(vim.v.count)
    local srow, _, erow = utils.visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    local lines = vim.api.nvim_buf_get_lines(0, srow - 1, erow, false)
    vim.api.nvim_buf_set_lines(0, srow - 1, erow, false, M.convert_lines(lines, sep))
    return
  end
  local line = vim.api.nvim_get_current_line()
  if is_table_line(line) then
    return M.align()
  end
  local size = utils.input({ prompt = "Table size Columns x Rows [e.g. 5x2]: ", default = "5x2" })
  if not size then
    return
  end
  local cols, rows = size:match("^%s*(%d+)%s*[xX]%s*(%d+)%s*$")
  cols, rows = tonumber(cols), tonumber(rows)
  if not cols or cols < 1 or rows < 1 then
    utils.warn("Invalid table size: " .. size)
    return
  end
  local t = { indent = line:match("^(%s*)"), rows = {}, ncols = cols }
  for r = 1, rows do
    t.rows[#t.rows + 1] = empty_row(cols)
    if r == 1 and rows > 1 then
      t.rows[#t.rows + 1] = { hline = true }
    end
  end
  local lines = M.render(t)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local at = line:match("^%s*$") and lnum - 1 or lnum
  if line:match("^%s*$") then
    vim.api.nvim_buf_set_lines(0, at, at + 1, false, lines)
  else
    vim.api.nvim_buf_set_lines(0, at, at, false, lines)
  end
  vim.api.nvim_win_set_cursor(0, { at + 1, #t.indent + 2 })
end

--- Insert a CSV/TSV/whitespace separated file as a table below the cursor
--- line (replacing it when blank). The separator is guessed unless given
--- (or set with a count, see `separator_for_count`). Emacs org-table-import.
---@param path? string
---@param sep? "tab"|"csv"|"space"|integer
function M.import(path, sep)
  sep = sep or M.separator_for_count(vim.v.count)
  path = path or utils.input({ prompt = "Import table from file: ", completion = "file" })
  if not path or vim.trim(path) == "" then
    return
  end
  path = vim.fn.fnamemodify(vim.fn.expand(vim.trim(path)), ":p")
  local data = utils.readfile(path)
  if not data then
    utils.warn("Cannot read file: " .. path)
    return
  end
  local lines = M.convert_lines(data, sep)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local blank = vim.api.nvim_get_current_line():match("^%s*$") ~= nil
  local at = blank and lnum - 1 or lnum
  vim.api.nvim_buf_set_lines(0, at, blank and lnum or lnum, false, lines)
  vim.api.nvim_win_set_cursor(0, { at + 1, 2 })
end

--- Lines of `rows` (lists of cells) as "tsv" or "csv" text.
function M.to_separated(rows, format)
  local out = {}
  for _, cells in ipairs(rows) do
    local parts = {}
    for i, c in ipairs(cells) do
      if format == "csv" and c:find('[",\n]') then
        c = '"' .. c:gsub('"', '""') .. '"'
      end
      parts[i] = c
    end
    out[#out + 1] = table.concat(parts, format == "csv" and "," or "\t")
  end
  return out
end

--- Translators offered for `table_export` (org-table-export).
local EXPORT_FORMATS = {
  "orgtbl-to-tsv",
  "orgtbl-to-csv",
  "orgtbl-to-latex",
  "orgtbl-to-html",
  "orgtbl-to-generic",
  "orgtbl-to-texinfo",
  "orgtbl-to-orgtbl",
}

--- Write the table at the cursor to a file with a translator (see
--- |org-table-translators|). The file and format come from the
--- TABLE_EXPORT_FILE / TABLE_EXPORT_FORMAT properties (inherited) when
--- set, else they are asked for; the suggested format matches the file
--- extension, else `table_export_default_format`. A format is a
--- translator name with parameters, `orgtbl-to-latex :splice t`. Emacs
--- org-table-export.
---@param path? string
---@param format? string
function M.export(path, format)
  local info = M.at_cursor()
  if not info then
    return false
  end
  local interactive = path == nil
  local hl = require("org.files").get_buffer(0):headline_at(info.start)
  path = path or (hl and hl:get_property("TABLE_EXPORT_FILE", true))
  if not path then
    path = utils.input({ prompt = "Export table to: ", completion = "file" })
    if not path or vim.trim(path) == "" then
      return
    end
    path = vim.fn.fnamemodify(vim.fn.expand(vim.trim(path)), ":p")
    if utils.exists(path) and not utils.confirm("Overwrite file " .. path .. "?") then
      utils.notify("File not written")
      return
    end
  end
  path = vim.fn.fnamemodify(vim.fn.expand(vim.trim(path)), ":p")
  if utils.is_dir(path) then
    utils.warn("This is a directory path, not a file")
    return
  end
  if path == vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p") then
    utils.warn("Please specify a file name that is different from current")
    return
  end
  format = format or (hl and hl:get_property("TABLE_EXPORT_FORMAT", true))
  if not format then
    local ext = (path:match("%.(%w+)$") or ""):lower()
    local default = require("org.config").opts.table_export_default_format or "orgtbl-to-tsv"
    for _, f in ipairs(EXPORT_FORMATS) do
      if ext ~= "" and f:sub(-#ext) == ext then
        default = f
        break
      end
    end
    if interactive then
      format = utils.input_complete("Format: ", EXPORT_FORMATS, default)
      if not format or vim.trim(format) == "" then
        return
      end
    else
      format = default
    end
  end
  local name, params = vim.trim(format):match("^(%S+)%s*(.*)$")
  local orgtbl = require("org.table.orgtbl")
  if not name or not orgtbl.translator(name) then
    utils.warn("No such transformation function " .. tostring(name))
    return
  end
  local text = orgtbl.translate(name, orgtbl.to_lisp(info.lines), params)
  utils.writefile(path, vim.split(text, "\n", { plain = true }))
  utils.notify("Export done: " .. path)
  return path
end

---------------------------------------------------------------------------
-- Formulas
---------------------------------------------------------------------------

--- Formulas of the first #+TBLFM line (the active one, like Emacs; the
--- other lines are alternatives applied with <C-c><C-c> on them).
---@param line? integer read this #+TBLFM line instead
local function read_formulas(bufnr, info, line)
  local l = line or info.tblfm[1]
  if not l then
    return ""
  end
  local text = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]
  return text:match("^%s*#%+[Tt][Bb][Ll][Ff][Mm]:%s*(.-)%s*$") or ""
end

--- Constants for `$name` in formulas: the global option, overridden by the
--- buffer's `#+CONSTANTS: name=value ...` lines.
local function formula_constants(bufnr)
  local out = vim.deepcopy(require("org.config").opts.table_formula_constants or {})
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local body = line:match("^%s*#%+[Cc][Oo][Nn][Ss][Tt][Aa][Nn][Tt][Ss]:%s*(.*)$")
    for k, v in (body or ""):gmatch("([%a_][%w_]*)=(%S+)") do
      out[k] = v
    end
  end
  for k, v in pairs(out) do
    out[k] = tostring(v)
  end
  return out
end

--- Formula debugging (Emacs org-table-formula-debug, toggled by C-c {).
M.formula_debug = false

--- Show one step of the formula debugger (Emacs *Substitution History*)
--- and ask whether to go on. Returns false to abort.
local function debug_step(trace)
  local lines = {
    "Substitution history of formula",
    "Orig:   " .. tostring(trace.orig),
    "$xyz->  " .. tostring(trace.orig),
    "@r$c->  " .. tostring(trace.form or ""),
    "$1->    " .. tostring(trace.form or ""),
  }
  if trace.error then
    lines[#lines + 1] = "Error:  " .. tostring(trace.error)
  else
    lines[#lines + 1] = "Result: " .. tostring(trace.result or "")
    lines[#lines + 1] = "Format: " .. tostring(trace.format or "NONE")
    lines[#lines + 1] = "Final:  " .. tostring(trace.final or "")
  end
  M.debug_history = lines
  local buf = vim.fn.bufnr("*Substitution History*")
  if buf < 0 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "*Substitution History*")
    vim.bo[buf].bufhidden = "wipe"
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local win = vim.fn.bufwinid(buf)
  if win < 0 then
    local cur = vim.api.nvim_get_current_win()
    vim.cmd("botright " .. #lines .. "split")
    vim.api.nvim_win_set_buf(0, buf)
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(cur)
  end
  vim.cmd("redraw")
  local go_on = utils.confirm("Debugging Formula.  Continue to next?")
  if vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  return go_on
end

--- Recalculate the table at the cursor (or at `lnum`) with its first
--- #+TBLFM line. Options: `line` recalculates only the column formulas of
--- that buffer line (Emacs C-c * without prefix; field formulas always
--- run), `tblfm_line` uses the formulas of that #+TBLFM line instead
--- (org-table-calc-current-TBLFM).
---@param opts? { line?: integer, tblfm_line?: integer }
function M.recalc(bufnr, lnum, opts)
  bufnr = (type(bufnr) == "number" and bufnr) or 0
  opts = type(opts) == "table" and opts or {}
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local info = M.find(bufnr, lnum)
  if not info then
    return false
  end
  local row
  if opts.line and opts.line >= info.start and opts.line <= info.finish then
    local t = M.parse(info.lines)
    if not t.rows[opts.line - info.start + 1].hline then
      row = dline(t, opts.line - info.start + 1)
    end
  end
  local lines = M.recalc_lines(bufnr, info.lines, read_formulas(bufnr, info, opts.tblfm_line), info.start, {
    row = row,
    only_row = opts.line ~= nil,
  })
  if not vim.deep_equal(lines, info.lines) then
    vim.api.nvim_buf_set_lines(bufnr, info.start - 1, info.finish, false, lines)
  end
  return true
end

--- Recalculate the current row (C-c *), the whole table (count 4, C-u
--- C-c *) or iterate the table until it is stable (count 16, C-u C-u C-c
--- *). Emacs org-table-recalculate.
function M.recalculate(count)
  count = count or vim.v.count
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local info = M.find(0, lnum)
  if not info then
    utils.warn("Not at a table")
    return false
  end
  local row, field = cursor_pos(info)
  if count >= 16 then
    M.iterate(0, lnum)
  elseif count >= 4 then
    M.recalc(0, lnum)
  else
    M.recalc(0, lnum, { line = lnum })
  end
  restore_cursor(info.start, row, field)
end

--- Recalculate the table until it does not change any more, at most `n`
--- (10) times. Emacs org-table-iterate.
function M.iterate(bufnr, lnum, n)
  bufnr = (type(bufnr) == "number" and bufnr) or 0
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  n = n or 10
  local info = M.find(bufnr, lnum)
  if not info then
    return false
  end
  local last = info.lines
  for i = 1, n do
    M.recalc(bufnr, info.start)
    local now = M.find(bufnr, info.start).lines
    if vim.deep_equal(now, last) then
      utils.notify(i > 1 and ("Convergence after " .. i .. " iterations") or "Table was already stable")
      return true
    end
    last = now
  end
  utils.warn("No convergence after " .. n .. " iterations")
  return false
end

--- Apply the formulas of the #+TBLFM line at `lnum` (not only the first
--- one) to its table. Emacs org-table-calc-current-TBLFM (C-c C-c on a
--- #+TBLFM line).
function M.calc_current_tblfm(bufnr, lnum)
  bufnr = (type(bufnr) == "number" and bufnr) or 0
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  if not is_tblfm(line) then
    utils.warn("Not at a #+TBLFM line")
    return false
  end
  local ok = M.recalc(bufnr, lnum, { tblfm_line = lnum })
  if ok then
    require("org.table.orgtbl").maybe_send(bufnr, lnum)
  end
  return ok
end

--- Apply formulas to table `lines` and return the aligned result. `tblfm`
--- is the formula string or a list of `#+TBLFM:` lines (only the first one
--- is used, like Emacs); `lnum` locates the table in `bufnr` (for $PROP_
--- lookups). `opts.row` limits column formulas to that data row.
---@param tblfm string|string[]
---@param opts? { row?: integer, only_row?: boolean }
function M.recalc_lines(bufnr, lines, tblfm, lnum, opts)
  opts = opts or {}
  if type(tblfm) == "table" then
    tblfm = tblfm[1] and tblfm[1]:match("^%s*#%+[Tt][Bb][Ll][Ff][Mm]:%s*(.-)%s*$") or ""
  end
  local t = M.parse(lines)
  pad_rows(t)
  if tblfm ~= "" then
    local formula = require("org.table.formula")
    local ok, err = pcall(formula.apply, t, formula.parse_tblfm(tblfm), {
      bufnr = bufnr,
      row = opts.row or (opts.only_row and 0) or nil,
      get_table = function(name)
        return M.find_named_table(bufnr, name)
      end,
      constants = formula_constants(bufnr),
      property = function(name)
        local hl = require("org.files").get_buffer(bufnr):headline_at(lnum)
        return hl and hl:get_property(name, true)
      end,
      debug = M.formula_debug and debug_step or nil,
    })
    if not ok then
      if err ~= "Abort" then
        utils.error("Table formula error: " .. tostring(err))
      end
    end
    pad_rows(t)
  end
  return M.render(t)
end

--- Toggle the formula debugger: while on, every formula evaluation shows
--- its substitution steps and asks whether to go on. Emacs C-c {
--- (org-table-toggle-formula-debugger).
function M.toggle_formula_debugger()
  M.formula_debug = not M.formula_debug
  utils.notify("Formula debugging has been turned " .. (M.formula_debug and "on" or "off"))
  return M.formula_debug
end

--- Edit the formulas of the table at the cursor (or of the #+TBLFM line
--- at the cursor) in the formula editor, see |org-table-formula-editor|.
--- Emacs C-c ' (org-table-edit-formulas).
function M.edit_formulas()
  return require("org.table.fedit").open()
end

--- Rows (list of list of strings) of the table named `name` (#+NAME:).
--- Hlines are skipped. When `keep_header` is false and the first row is
--- followed by an hline, that header row is dropped (org-babel behaviour).
function M.get_named_table(bufnr, name, keep_header)
  local t = M.find_named_table(bufnr, name)
  if not t then
    return nil
  end
  local rows = {}
  local drop_header = not keep_header and #t.rows > 2 and not t.rows[1].hline and t.rows[2].hline
  for idx, r in ipairs(t.rows) do
    if not r.hline and not (drop_header and idx == 1) then
      rows[#rows + 1] = vim.deepcopy(r.cells)
    end
  end
  return rows
end

--- The parsed table (hlines included) after `#+NAME: name`, or nil.
function M.find_named_table(bufnr, name)
  bufnr = bufnr or 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    local n = line:match("^%s*#%+[Nn][Aa][Mm][Ee]:%s*(.-)%s*$")
    if n and n == name then
      local j = i + 1
      while lines[j] and lines[j]:match("^%s*#%+") do
        j = j + 1
      end
      if lines[j] and is_table_line(lines[j]) then
        local tl = {}
        while lines[j] and is_table_line(lines[j]) do
          tl[#tl + 1] = lines[j]
          j = j + 1
        end
        local t = M.parse(tl)
        pad_rows(t)
        return t
      end
      return nil
    end
  end
  return nil
end

--- Render rows (list of lists) as aligned table lines.
---@param rows (string[]|string)[] use the string "hline" for separators
function M.rows_to_lines(rows, indent)
  local t = { indent = indent or "", rows = {}, ncols = 1 }
  for _, r in ipairs(rows) do
    if r == "hline" then
      t.rows[#t.rows + 1] = { hline = true }
    else
      local cells = {}
      for i, v in ipairs(r) do
        cells[i] = tostring(v):gsub("\n", " "):gsub("|", "\\vert{}")
      end
      t.rows[#t.rows + 1] = { cells = cells }
      t.ncols = math.max(t.ncols, #cells)
    end
  end
  pad_rows(t)
  return M.render(t)
end

---------------------------------------------------------------------------
-- Field commands (Emacs C-c =, C-c `, C-c +, C-c SPC, C-c ?, regions ...)
---------------------------------------------------------------------------

--- Emacs-style column letter (A, B, ..., Z, AA, ...) for column `c`.
local function col_letter(c)
  local s = ""
  while c > 0 do
    local r = (c - 1) % 26
    s = string.char(65 + r) .. s
    c = math.floor((c - 1) / 26)
  end
  return s
end

local function escape_cell(s)
  return (s:gsub("\n", " "):gsub("|", "\\vert{}"))
end

--- Table at cursor with rows padded, plus cursor row/field/offset.
local function current_field()
  local info = M.at_cursor()
  if not info then
    return nil
  end
  local row, field, offset = cursor_pos(info)
  pad_rows(info.tbl)
  return info, row, math.min(field, info.tbl.ncols), offset
end

--- Individual `lhs=rhs` formulas of the first #+TBLFM line (or of line
--- `line`), verbatim.
local function formula_parts(bufnr, info, line)
  local parts = {}
  for part in (read_formulas(bufnr, info, line) .. "::"):gmatch("(.-)::") do
    part = vim.trim(part)
    if part ~= "" then
      parts[#parts + 1] = part
    end
  end
  return parts
end
M.formula_parts = formula_parts

--- Index of the formula whose target is exactly `lhs`, or nil.
local function find_formula(parts, lhs)
  for i, p in ipairs(parts) do
    if vim.trim(p:match("^(.-)=") or "") == lhs then
      return i
    end
  end
end

--- Sort key of a formula's left side (Emacs
--- org-table-formula-make-cmp-string): `$<`/`$>` last, numbers padded.
local function formula_cmp_string(lhs)
  local arrows = lhs:match("^%$([<>]+)$")
  if arrows then
    return string.format("$%05d", 10000 + (arrows:sub(1, 1) == "<" and -1000 or 0) + #arrows)
  end
  local row = lhs:match("^@(%d+)")
  local rest = row and lhs:sub(#row + 2) or lhs
  local col = rest:match("^%$?(%d+)")
  rest = col and rest:sub(#rest:match("^%$?%d+") + 1) or rest
  local name = rest:match("^(%$?[%w]+)")
  if not row and not col and not name then
    return nil
  end
  return (row and string.format("@%05d", tonumber(row)) or "")
    .. (col and string.format("$%05d", tonumber(col)) or "")
    .. (name and ("@@" .. name) or "")
end

--- Sort formulas like Emacs stores them (org-table-formula-less-p; stable).
function M.sort_formulas(parts)
  local keyed = {}
  for i, p in ipairs(parts) do
    keyed[i] = { p = p, k = formula_cmp_string(vim.trim(p:match("^(.-)=") or "")), i = i }
  end
  table.sort(keyed, function(a, b)
    if a.k and b.k and a.k ~= b.k then
      return a.k < b.k
    end
    return a.i < b.i
  end)
  local out = {}
  for i, e in ipairs(keyed) do
    out[i] = e.p
  end
  return out
end

--- Store `parts` in the first #+TBLFM line of table `info` (or in line
--- `line`), sorted and as `lhs=rhs`, like Emacs org-table-store-formulas.
--- Other #+TBLFM lines are left alone.
local function write_formulas(bufnr, info, parts, line)
  local indent = info.lines[1]:match("^(%s*)")
  local norm = {}
  for i, p in ipairs(M.sort_formulas(parts)) do
    local lhs, rhs = p:match("^(.-)%s*=%s*(.-)%s*$")
    norm[i] = lhs and (vim.trim(lhs) .. "=" .. rhs) or p
  end
  local l = line or info.tblfm[1]
  if l then
    local old = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]
    local prefix = old:match("^(%s*#%+[Tt][Bb][Ll][Ff][Mm]:)") or (indent .. "#+TBLFM:")
    vim.api.nvim_buf_set_lines(bufnr, l - 1, l, false, { prefix .. " " .. table.concat(norm, "::") })
  elseif #norm > 0 then
    vim.api.nvim_buf_set_lines(bufnr, info.finish, info.finish, false, { indent .. "#+TBLFM: " .. table.concat(norm, "::") })
  end
end
M._write_formulas = write_formulas

--- Convert A1-style references (`B3`, `C&`) to `@3$2` / `$3` (Emacs
--- org-table-convert-refs-to-rc).
function M.refs_to_rc(s)
  local function col(letters)
    local n = 0
    for i = 1, #letters do
      n = n * 26 + (letters:upper():byte(i) - 64)
    end
    return n
  end
  local out, i = {}, 1
  while i <= #s do
    local pre = i == 1 and "" or s:sub(i - 1, i - 1)
    local letters, digits = s:match("^(%a%a?)(%d+)", i)
    local after = letters and s:sub(i + #letters + #digits, i + #letters + #digits) or ""
    if letters and not pre:match("[%w_@$]") and not after:match("[%w_]") then
      out[#out + 1] = "@" .. digits .. "$" .. col(letters)
      i = i + #letters + #digits
    else
      local amp = s:match("^(%a%a?)&", i)
      if amp and not pre:match("[%w_@$]") then
        out[#out + 1] = "$" .. col(amp)
        i = i + #amp + 1
      else
        out[#out + 1] = s:sub(i, i)
        i = i + 1
      end
    end
  end
  return table.concat(out)
end

--- Convert `@3$2` references to `B3` (Emacs org-table-convert-refs-to-an).
function M.refs_to_an(s)
  return (s:gsub("@(%d+)%$(%d+)", function(r, c)
    return col_letter(tonumber(c)) .. r
  end):gsub("%$(%d+)", function(c)
    return col_letter(tonumber(c)) .. "&"
  end))
end

--- A formula typed by the user, with A1-style references converted when
--- `table_use_standard_references` allows it (org-table-formula-from-user).
local function formula_from_user(s)
  if require("org.config").opts.table_use_standard_references then
    return M.refs_to_rc(s)
  end
  return s
end

--- Name of the field at data row `dl`, column `c` (a `^`/`_` name), or nil.
local function field_name(t, dl, c)
  local formula = require("org.table.formula")
  local m = formula._model(t)
  formula._collect_names(m)
  for name, pos in pairs(m.names.fields) do
    if pos[1] == dl and pos[2] == c then
      return name
    end
  end
end

--- The formula applying to data row `dl`, column `c`: its left side,
--- right side and whether it is a field formula.
local function field_formula_of(t, parts, dl, c, row)
  local name = field_name(t, dl, c)
  for _, lhs in ipairs({ name or false, "@" .. dl .. "$" .. c }) do
    local idx = lhs and find_formula(parts, lhs)
    if idx then
      return lhs, parts[idx]:match("^.-=%s*(.*)$"), true
    end
  end
  -- column formulas apply below the first hline (or to all rows)
  local first_hline = 0
  for i, r in ipairs(t.rows) do
    if r.hline and i > 1 then
      first_hline = i
      break
    end
  end
  if row > first_hline then
    local idx = find_formula(parts, "$" .. c)
    if idx then
      return "$" .. c, parts[idx]:match("^.-=%s*(.*)$"), false
    end
  end
end

--- Evaluate formula `eq` (`rhs;flags`) for one field of the table at the
--- cursor and write the result there (Emacs evaluates only the current
--- field; C-c * recalculates the rest).
local function eval_one(info, row, field, eq)
  local formula = require("org.table.formula")
  local t = info.tbl
  local f = formula.parse_tblfm("@" .. dline(t, row) .. "$" .. field .. "=" .. eq)
  if #f == 0 then
    return
  end
  local ok, err = pcall(formula.apply, t, f, {
    bufnr = 0,
    get_table = function(name)
      return M.find_named_table(0, name)
    end,
    constants = formula_constants(0),
    property = function(name)
      local hl = require("org.files").get_buffer(0):headline_at(info.start)
      return hl and hl:get_property(name, true)
    end,
    debug = M.formula_debug and debug_step or nil,
  })
  if not ok and err ~= "Abort" then
    utils.error("Table formula error: " .. tostring(err))
  end
  pad_rows(t)
  write_table(info, t)
end

--- Read and store the formula of the current column (a field formula with
--- `field_formula`, or count 4: C-u C-c =) and compute the current field
--- with it. An empty formula removes it. Count 16 (C-u C-u C-c =) puts
--- the formula of the field into the field as `=...` / `:=...` for
--- editing. Setting a column formula removes the field's own formula.
--- Emacs `C-c =` (org-table-eval-formula).
---@param field_formula? boolean
function M.eval_formula(field_formula)
  local info, row, field = current_field()
  if not info then
    return false
  end
  local t = info.tbl
  if t.rows[row].hline then
    utils.warn("Not in a table data field")
    return
  end
  local count = vim.v.count
  local dl = dline(t, row)
  local parts = formula_parts(0, info)
  if count >= 16 and field_formula == nil then
    local _, rhs, is_field = field_formula_of(t, parts, dl, field, row)
    if not rhs then
      utils.warn("No formula active for the current field")
      return
    end
    t.rows[row].cells[field] = (is_field and ":=" or "=") .. rhs
    local lines = write_table(info, t)
    set_cursor(info, lines, row, field, 0)
    return
  end
  if field_formula == nil then
    field_formula = count > 0
  end
  local name = field_name(t, dl, field)
  local ref = "@" .. dl .. "$" .. field
  local lhs = field_formula and (name or ref) or ("$" .. field)
  local idx = find_formula(parts, lhs)
  local default = idx and parts[idx]:match("^.-=%s*(.*)$") or ""
  local to_user = require("org.config").opts.table_use_standard_references == true and M.refs_to_an
    or function(s)
      return s
    end
  local rhs = utils.input({
    prompt = to_user((field_formula and "Field" or "Column") .. " formula " .. lhs .. "="),
    default = to_user(default),
  })
  if rhs == nil then
    return
  end
  rhs = vim.trim(formula_from_user(rhs)):gsub("^=%s*", "")
  if rhs == "" then
    if idx then
      table.remove(parts, idx)
      write_formulas(0, info, parts)
    end
    utils.notify("Formula removed")
    return
  end
  if idx then
    parts[idx] = lhs .. "=" .. rhs
  else
    parts[#parts + 1] = lhs .. "=" .. rhs
  end
  if not field_formula then
    -- the column formula replaces the field's own formula
    local own = find_formula(parts, name or ref)
    if own then
      table.remove(parts, own)
    end
  end
  write_formulas(0, info, parts)
  info = reload(info)
  eval_one(info, row, field, rhs)
  restore_cursor(info.start, row, field)
end

--- When field `field` of row `row` holds `=formula` (or `:=formula`),
--- install it as the column (or field) formula in #+TBLFM and compute the
--- field. Emacs org-table-maybe-eval-formula (typing a formula into a
--- field and pressing <Tab>, <CR> or C-c C-c).
---@return boolean installed
local function maybe_eval_formula(info, row, field)
  local t = info.tbl
  local r = t.rows[row]
  if not r or r.hline or require("org.config").opts.table_formula_evaluate_inline == false then
    return false
  end
  local named, rhs = vim.trim(r.cells[field] or ""):match("^(:?)=(.*[^=])$")
  if not rhs then
    return false
  end
  local dl = dline(t, row)
  local lhs = named == ":" and (field_name(t, dl, field) or ("@" .. dl .. "$" .. field)) or ("$" .. field)
  rhs = vim.trim(formula_from_user(rhs))
  r.cells[field] = ""
  write_table(info, t)
  local parts = formula_parts(0, info)
  local idx = find_formula(parts, lhs)
  parts[idx or (#parts + 1)] = lhs .. "=" .. rhs
  write_formulas(0, info, parts)
  info = reload(info)
  eval_one(info, row, field, rhs)
  return true
end

--- Recalculate row `row` when it is marked with `#` in its first column.
--- Emacs org-table-maybe-recalculate-line.
local function maybe_recalc_line(info, row)
  local r = info.tbl.rows[row]
  if r and not r.hline and vim.trim(r.cells[1] or "") == "#" and #info.tblfm > 0 then
    M.recalc(0, info.start, { line = info.start + row - 1 })
    return true
  end
  return false
end

--- Run before <Tab>/<S-Tab>/<CR>/C-c RET/C-c C-c: evaluate an inline
--- formula and auto-recalculate `#` rows. Returns fresh table info.
function before_move(info, row, field, no_formula)
  if (not no_formula and maybe_eval_formula(info, row, field)) or maybe_recalc_line(info, row) then
    return reload(info)
  end
  return info
end

--- C-c C-c in a table: install an inline `=`/`:=` formula, then with a
--- count recalculate (4: the table, 16: iterate), else recalculate a
--- `#`-marked row, else realign (org-ctrl-c-ctrl-c).
function M.ctrl_c_ctrl_c()
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field, offset = cursor_pos(info)
  local count = vim.v.count
  if count > 0 then
    maybe_eval_formula(info, row, field)
    M.recalculate(count)
    return
  end
  info = before_move(info, row, field)
  local lines = write_table(info, info.tbl)
  set_cursor(info, lines, row, math.min(field, info.tbl.ncols), offset)
end

--- The active formula of the current field as `$2=...` / `@3$2=...`, or
--- nil. Emacs org-table-current-field-formula.
function M.current_field_formula()
  local info, row, field = current_field()
  if not info or info.tbl.rows[row].hline then
    return nil
  end
  local lhs, rhs = field_formula_of(info.tbl, formula_parts(0, info), dline(info.tbl, row), field, row)
  return lhs and (lhs .. "=" .. rhs) or nil
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

--- Rectangle of fields to act on: the visual selection (visual mode is
--- left) or, in normal mode, the current field (or the whole current
--- column when `whole_column`).
---@return table|nil info, integer[] rows (table row indices, hlines skipped), integer c1, integer c2
local function selected_rect(whole_column)
  local visual = in_visual()
  local srow, scol, erow, ecol, mode
  if visual then
    srow, scol, erow, ecol, mode = utils.visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end
  local info, row, field = current_field()
  if not info then
    return nil
  end
  local t = info.tbl
  local r1, r2, c1, c2
  if visual then
    local function fld(lnum, col, fallback)
      if lnum < info.start or lnum > info.finish or mode == "V" then
        return fallback
      end
      local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
      return math.max(1, math.min((field_at(line, col)), t.ncols))
    end
    c1, c2 = fld(srow, scol, 1), fld(erow, ecol, t.ncols)
    if c1 > c2 then
      c1, c2 = c2, c1
    end
    r1 = math.max(srow, info.start) - info.start + 1
    r2 = math.min(erow, info.finish) - info.start + 1
  elseif whole_column then
    r1, r2, c1, c2 = 1, #t.rows, field, field
  else
    r1, r2, c1, c2 = row, row, field, field
  end
  local rows = {}
  for r = r1, r2 do
    if not t.rows[r].hline then
      rows[#rows + 1] = r
    end
  end
  return info, rows, c1, c2
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

--- Insert an hline below the current row and move to the first field of
--- the row after it, creating that row when the table ends there or
--- another hline follows. With a count (or `same_column`) keep the column.
--- Emacs `C-c RET` (org-table-hline-and-move).
---@param same_column? boolean
function M.hline_and_move(same_column)
  local info, row, field = current_field()
  if not info then
    return false
  end
  if same_column == nil then
    same_column = vim.v.count > 0
  end
  info = before_move(info, row, field)
  local t = info.tbl
  table.insert(t.rows, row + 1, { hline = true })
  local target = row + 2
  if not t.rows[target] or t.rows[target].hline then
    table.insert(t.rows, target, empty_row(t.ncols))
  end
  local lines = write_table(info, t)
  set_cursor(info, lines, target, same_column and field or 1, 0)
end

--- Show the reference of the current field and the formula applying to
--- it. Emacs `C-c ?` (org-table-field-info).
function M.field_info()
  local info, row, field = current_field()
  if not info then
    return false
  end
  local t = info.tbl
  if t.rows[row].hline then
    utils.notify("Not in a table data field")
    return
  end
  local dl = dline(t, row)
  local ref = "@" .. dl .. "$" .. field
  local msg = string.format("line @%d, col $%d, ref %s or %s%d", dl, field, ref, col_letter(field), dl)
  local parts = formula_parts(0, info)
  local idx = find_formula(parts, ref)
  if not idx then
    -- column formulas apply below the first hline (or to all rows without one)
    local first_hline = 0
    for i, r in ipairs(t.rows) do
      if r.hline and i > 1 then
        first_hline = i
        break
      end
    end
    if row > first_hline then
      idx = find_formula(parts, "$" .. field)
    end
  end
  if idx then
    msg = msg .. ", formula: " .. parts[idx]
  end
  utils.notify(msg)
  return msg
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

--- Next value in a copy-down series: numbers, numbers prefixed or
--- suffixed to text, and timestamps (by days) are incremented by the
--- difference to `previous` when it has the same shape, else by `step`.
--- Emacs org-table--increment-field.
---@param value string
---@param previous? string
---@param step number
function M.increment_field(value, previous, step)
  local function num_str(n)
    if n == math.floor(n) and math.abs(n) < 1e15 then
      return string.format("%d", n)
    end
    return string.format("%.15g", n)
  end
  local function analyze(s)
    if not s or s == "" then
      return nil
    end
    local n = s:match("^[-+]?%d+%.?$") or s:match("^[-+]?%d*%.%d+$") or s:match("^[-+]?%d+%.?%d*[eE][-+]?%d+$")
    if n then
      return "number", tonumber((n:gsub("^%+", ""):gsub("%.$", ""))), nil
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
  local same = kind == kind2 and p1 == p2
  if kind == "number" then
    return num_str(v1 + (same and (v1 - v2) or step))
  elseif kind == "prefix" then
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
  local target = row
  if initial ~= "" then
    target = row + 1
    if not t.rows[target] or t.rows[target].hline then
      table.insert(t.rows, target, empty_row(t.ncols))
    end
  end
  t.rows[target].cells[field] = value
  local lines = write_table(info, t)
  set_cursor(info, lines, target, field, #value)
end

--- Transpose the table at the cursor: rows become columns. Hlines are
--- dropped. Emacs org-table-transpose-table-at-point.
function M.transpose()
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field = cursor_pos(info)
  local t = info.tbl
  pad_rows(t)
  local data = {}
  for _, r in ipairs(t.rows) do
    if not r.hline then
      data[#data + 1] = r.cells
    end
  end
  local out = { indent = t.indent, rows = {}, ncols = math.max(#data, 1) }
  for c = 1, t.ncols do
    local cells = {}
    for i, cells_in in ipairs(data) do
      cells[i] = cells_in[c] or ""
    end
    out.rows[c] = { cells = cells }
  end
  local lines = write_table(info, out)
  set_cursor(info, lines, field, t.rows[row].hline and 1 or dline(t, row), 0)
end

--- Recalculation marks, in rotation order (Emacs org-recalc-marks).
local RECALC_MARKS = { " ", "#", "*", "!", "$", "_", "^" }
local MARK_HELP = {
  [" "] = "Unmarked: no special line, no automatic recalculation",
  ["#"] = "Automatically recalculate this line upon TAB, RET, and C-c C-c in the line",
  ["*"] = "Recalculate only when entire table is recalculated with C-u C-c *",
  ["!"] = "Column name definition line. Reference in formula as $name.",
  ["$"] = "Parameter definition line name=value. Reference in formula as $name.",
  ["_"] = "Names for values in row below this one.",
  ["^"] = "Names for values in row above this one.",
}

--- Rotate the recalculation mark (` # * ! $ _ ^`) in the first column of
--- the current row (or set `mark` on every row of the visual selection,
--- after prompting). A marker column is inserted when the table has none.
--- Emacs C-# (org-table-rotate-recalc-marks).
---@param mark? string
function M.rotate_recalc_marks(mark)
  local visual = in_visual()
  local srow, erow
  if visual then
    local s, _, e = utils.visual_range()
    srow, erow = s, e
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end
  local info, row, field = current_field()
  if not info then
    return false
  end
  local t = info.tbl
  if t.rows[row].hline then
    utils.warn("Not at a table data line")
    return
  end
  if visual and not mark then
    mark = utils.getchar("Change region to what mark?  Type # * ! $ or SPC: ")
    if not mark then
      return
    end
  end
  if mark and not MARK_HELP[mark] then
    utils.warn("Invalid recalculation mark: " .. mark)
    return
  end
  local has_marks = true
  for _, r in ipairs(t.rows) do
    if not r.hline and not MARK_HELP[r.cells[1] == "" and " " or r.cells[1]] then
      has_marks = false
      break
    end
  end
  if not has_marks then
    for _, r in ipairs(t.rows) do
      if not r.hline then
        table.insert(r.cells, 1, "")
      end
    end
    t.ncols = t.ncols + 1
    field = field + 1
  end
  local new = mark
  if not new then
    local current = t.rows[row].cells[1]
    current = current == "" and " " or current
    if not has_marks or not MARK_HELP[current] then
      new = "#"
    else
      for i, m in ipairs(RECALC_MARKS) do
        if m == current then
          new = RECALC_MARKS[i % #RECALC_MARKS + 1]
        end
      end
    end
  end
  local r1, r2 = row, row
  if visual then
    r1 = math.max(srow, info.start) - info.start + 1
    r2 = math.min(erow, info.finish) - info.start + 1
  end
  for r = r1, r2 do
    if not t.rows[r].hline then
      t.rows[r].cells[1] = new == " " and "" or new
    end
  end
  local lines = write_table(info, t)
  set_cursor(info, lines, row, field, 0)
  utils.notify(MARK_HELP[new])
  return new
end

---------------------------------------------------------------------------
-- Coordinate overlays (Emacs C-c })
---------------------------------------------------------------------------

local coord_ns = vim.api.nvim_create_namespace("org.table.coordinates")

--- Toggle virtual text showing row (`@N`) and column (`$N`) references on
--- the table at the cursor. Emacs `C-c }`
--- (org-table-toggle-coordinate-overlays).
function M.toggle_coordinate_overlays()
  local bufnr = vim.api.nvim_get_current_buf()
  if #vim.api.nvim_buf_get_extmarks(bufnr, coord_ns, 0, -1, { limit = 1 }) > 0 then
    vim.api.nvim_buf_clear_namespace(bufnr, coord_ns, 0, -1)
    return
  end
  local info = M.at_cursor()
  if not info then
    return false
  end
  local t = info.tbl
  local n = 0
  for i, r in ipairs(t.rows) do
    local lnum = info.start + i - 1
    if not r.hline then
      n = n + 1
      vim.api.nvim_buf_set_extmark(bufnr, coord_ns, lnum - 1, 0, {
        virt_text = { { "@" .. n, "OrgTableFormula" } },
        virt_text_pos = "eol",
      })
    end
  end
  -- column labels above the first row, each over its field
  local line = info.lines[1]
  local pipes = pipe_positions(line)
  local label = ""
  for c = 1, t.ncols do
    local p = pipes[c]
    if not p then
      break
    end
    local col = vim.fn.strdisplaywidth(line:sub(1, p)) + 1
    local text = "$" .. c
    label = label .. string.rep(" ", math.max(col - vim.fn.strdisplaywidth(label), c > 1 and 1 or 0)) .. text
  end
  vim.api.nvim_buf_set_extmark(bufnr, coord_ns, info.start - 1, 0, {
    virt_lines = { { { label, "OrgTableFormula" } } },
    virt_lines_above = true,
  })
end

---------------------------------------------------------------------------
-- Rectangles (Emacs C-c C-x M-w / C-w / C-y)
---------------------------------------------------------------------------

--- Last copied/cut rectangle: list of rows of cells.
---@type string[][]|nil
M.clipboard = nil

local function copy_rect(t, rows, c1, c2)
  local out = {}
  for _, r in ipairs(rows) do
    local cells = {}
    for c = c1, c2 do
      cells[#cells + 1] = t.rows[r].cells[c] or ""
    end
    out[#out + 1] = cells
  end
  return out
end

--- Copy the fields of the visual selection (or the current field) into the
--- table clipboard. Emacs `C-c C-x M-w` (org-table-copy-region).
function M.copy_region()
  local info, rows, c1, c2 = selected_rect(false)
  if not info then
    return false
  end
  M.clipboard = copy_rect(info.tbl, rows, c1, c2)
end

--- Copy the selected fields (or the current field) into the table
--- clipboard and blank them. Emacs `C-c C-x C-w` (org-table-cut-region).
function M.cut_region()
  local info, rows, c1, c2 = selected_rect(false)
  if not info then
    return false
  end
  local t = info.tbl
  M.clipboard = copy_rect(t, rows, c1, c2)
  for _, r in ipairs(rows) do
    for c = c1, c2 do
      t.rows[r].cells[c] = ""
    end
  end
  local lines = write_table(info, t)
  set_cursor(info, lines, rows[1] or 1, c1, 0)
end

--- Paste the table clipboard with its top-left corner at the current field,
--- overwriting fields and adding rows/columns as needed (hlines are
--- skipped). Emacs `C-c C-x C-y` (org-table-paste-rectangle).
function M.paste_rectangle()
  local info, row, field = current_field()
  if not info then
    return false
  end
  if not M.clipboard or #M.clipboard == 0 then
    utils.warn("First cut/copy a region to paste")
    return
  end
  local t = info.tbl
  local r = row
  while t.rows[r] and t.rows[r].hline do
    r = r + 1
  end
  local first = r
  for i, cells in ipairs(M.clipboard) do
    if i > 1 then
      r = r + 1
      while t.rows[r] and t.rows[r].hline do
        r = r + 1
      end
    end
    if not t.rows[r] then
      t.rows[r] = empty_row(t.ncols)
    end
    if field + #cells - 1 > t.ncols then
      t.ncols = field + #cells - 1
      pad_rows(t)
    end
    for j, v in ipairs(cells) do
      t.rows[r].cells[field + j - 1] = v
    end
  end
  local lines = write_table(info, t)
  set_cursor(info, lines, first, field, 0)
end

--- Recalculate every table with #+TBLFM formulas in the buffer, iterating
--- until the results are stable (at most 10 passes). Emacs `C-u C-u C-c *`
--- (org-table-iterate-buffer-tables).
function M.recalc_buffer(bufnr)
  bufnr = (type(bufnr) == "number" and bufnr) or 0
  for _ = 1, 10 do
    local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local l = 1
    while l <= vim.api.nvim_buf_line_count(bufnr) do
      local line = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]
      local info = is_table_line(line) and M.find(bufnr, l)
      if info then
        if #info.tblfm > 0 then
          M.recalc(bufnr, l)
          info = M.find(bufnr, l)
        end
        l = (info.tblfm[#info.tblfm] or info.finish) + 1
      else
        l = l + 1
      end
    end
    if vim.deep_equal(before, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) then
      return
    end
  end
  utils.warn("Table formulas did not converge after 10 iterations")
end

---------------------------------------------------------------------------
-- Buffer attach
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Shrinking columns (Emacs org-table-shrink / C-c TAB)
---------------------------------------------------------------------------

--- Shrink the columns with a width cookie of the table at `lnum` and expand
--- the others. Emacs org-table-shrink.
function M.shrink(bufnr, lnum)
  return require("org.table.shrink").shrink(bufnr, lnum or vim.api.nvim_win_get_cursor(0)[1])
end

--- Show every column of the table at `lnum` in full. Emacs org-table-expand.
function M.expand(bufnr, lnum)
  return require("org.table.shrink").expand(bufnr, lnum or vim.api.nvim_win_get_cursor(0)[1])
end

--- Shrink or expand the current column; before the first or after the
--- last column, ask for column ranges (`2-4 6-`). Count 4 (C-u) shrinks
--- the columns with width cookies (org-table-shrink), 16 expands all.
--- Emacs C-c TAB in a table (org-table-toggle-column-width).
---@param count? integer
---@param ranges? string column ranges instead of the current column
function M.toggle_column_width(count, ranges)
  count = count or vim.v.count
  local lnum, col = utils.cursor()
  local info = M.find(0, lnum)
  if not info then
    utils.warn("Not in a table")
    return false
  end
  local shrink = require("org.table.shrink")
  if count >= 16 then
    return shrink.expand(0, lnum)
  elseif count >= 4 then
    return shrink.shrink(0, lnum)
  end
  local line = vim.api.nvim_get_current_line()
  local pipes = pipe_positions(line)
  local t = M.parse(info.lines)
  local cols
  if ranges or col <= (pipes[1] or 1) or col > (pipes[#pipes] or #line) then
    ranges = ranges or utils.input({ prompt = "Column ranges (e.g. 2-4 6-): " })
    if not ranges then
      return
    end
    cols = shrink.parse_ranges(ranges, t.ncols)
  else
    cols = { [field_at(line, col)] = true }
  end
  local current = shrink.get(0, lnum)
  for c in pairs(cols) do
    if c >= 1 and c <= t.ncols then
      current[c] = not current[c] or nil
    end
  end
  return shrink.set(0, lnum, current)
end

--- Toggle follow-field mode (Emacs org-table-follow-field-mode).
function M.toggle_follow_field_mode()
  return require("org.table.follow").toggle()
end

--- Toggle header-line mode for the current buffer (Emacs
--- org-table-header-line-mode).
function M.header_line_mode()
  local on = require("org.table.follow").header_line_mode(0)
  utils.notify("Table header-line mode " .. (on and "enabled" or "disabled"))
  return on
end

--- Tables in the table.el format (`+---+`) are not supported: explain
--- (Emacs C-c ~, org-table-create-with-table.el).
function M.table_el()
  utils.warn("table.el tables are not supported (see :h org-differences)")
end

function M.attach(bufnr)
  if require("org.config").opts.table_header_line_p then
    require("org.table.follow").header_line_mode(bufnr, true)
  end
  local startup = require("org.files").get_buffer(bufnr).settings.startup or {}
  if startup.shrink or (require("org.config").opts.startup_shrink_all_tables and not startup.noshrink) then
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        require("org.table.shrink").shrink_all(bufnr)
      end
    end)
  end
  vim.api.nvim_create_autocmd("InsertLeave", {
    buffer = bufnr,
    group = vim.api.nvim_create_augroup("org.table." .. bufnr, { clear = true }),
    callback = function()
      if vim.api.nvim_get_current_buf() ~= bufnr then
        return
      end
      local line = vim.api.nvim_get_current_line()
      if is_table_line(line) then
        local info = M.at_cursor()
        if info and not vim.deep_equal(M.render(info.tbl), info.lines) then
          M.align()
        end
      end
    end,
  })
end

return M
