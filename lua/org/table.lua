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

--- Render a parsed table into aligned lines.
function M.render(t)
  local ncols = t.ncols
  local widths, numeric, total, forced = {}, {}, {}, {}
  for c = 1, ncols do
    widths[c], numeric[c], total[c] = 1, 0, 0
  end
  for _, row in ipairs(t.rows) do
    if not row.hline then
      local cookie = is_cookie_row(row)
      for c = 1, ncols do
        local cell = row.cells[c] or ""
        widths[c] = math.max(widths[c], utils.width(cell))
        if cookie then
          local a = cell:match("^<([lrc])")
          if a then
            forced[c] = a
          end
        elseif cell ~= "" then
          total[c] = total[c] + 1
          if M.is_number(cell) then
            numeric[c] = numeric[c] + 1
          end
        end
      end
    end
  end
  local align = {}
  for c = 1, ncols do
    align[c] = forced[c] or ((total[c] > 0 and numeric[c] / total[c] >= 0.5) and "r" or "l")
  end
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
        local w = utils.width(cell)
        local pad = widths[c] - w
        local a = align[c]
        if is_cookie_row(row) then
          a = "l"
        end
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
  local t = info.tbl
  pad_rows(t)
  local nxt = t.rows[row + 1]
  if not nxt or nxt.hline then
    table.insert(t.rows, row + 1, empty_row(t.ncols))
  end
  local lines = write_table(info, t)
  set_cursor(info, lines, row + 1, field, 0)
end

--- Insert an empty row above (`above` = true) or below the current row.
function M.insert_row(above)
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field = cursor_pos(info)
  local t = info.tbl
  pad_rows(t)
  local at = above and row or row + 1
  table.insert(t.rows, at, empty_row(t.ncols))
  local lines = write_table(info, t)
  set_cursor(info, lines, at, field, 0)
end

function M.delete_row()
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field = cursor_pos(info)
  local t = info.tbl
  if #t.rows == 1 then
    vim.api.nvim_buf_set_lines(0, info.start - 1, info.finish, false, {})
    return
  end
  table.remove(t.rows, row)
  local lines = write_table(info, t)
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

--- Insert an empty column left of the current one.
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
  set_cursor(info, lines, row, field, 0)
end

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
  t.rows[row], t.rows[other] = t.rows[other], t.rows[row]
  local lines = write_table(info, t)
  set_cursor(info, lines, other, field, 0)
end

--- Sort the rows of the current hline-delimited section by current column.
function M.sort_column()
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
  local choice = require("org.ui").menu({
    title = "Sort table by column " .. field,
    items = {
      { key = "a", label = "alphabetically", value = "a" },
      { key = "A", label = "alphabetically (reverse)", value = "A" },
      { key = "n", label = "numerically", value = "n" },
      { key = "N", label = "numerically (reverse)", value = "N" },
      { key = "t", label = "by time/date", value = "t" },
      { key = "T", label = "by time/date (reverse)", value = "T" },
    },
  })
  if not choice then
    return
  end
  local s, e = row, row
  while s > 1 and not t.rows[s - 1].hline do
    s = s - 1
  end
  while e < #t.rows and not t.rows[e + 1].hline do
    e = e + 1
  end
  local slice = {}
  for i = s, e do
    slice[#slice + 1] = t.rows[i]
  end
  local kind = choice:lower()
  local function key(r)
    local v = r.cells[field] or ""
    if kind == "n" then
      return tonumber(v:match("[-+]?%d*%.?%d+[eE]?[-+]?%d*")) or 0
    elseif kind == "t" then
      local d = require("org.date").parse(v)
      if d then
        return d:minutes()
      end
      local mins = require("org.date").parse_duration(v)
      return mins or 0
    end
    return v:lower()
  end
  local reverse = choice ~= kind
  -- stable sort
  for i, r in ipairs(slice) do
    r._i = i
  end
  table.sort(slice, function(a, b)
    local ka, kb = key(a), key(b)
    if ka == kb then
      return a._i < b._i
    end
    if reverse then
      return ka > kb
    end
    return ka < kb
  end)
  for i, r in ipairs(slice) do
    r._i = nil
    t.rows[s + i - 1] = r
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

--- Create an empty table (normal mode) or convert the visual selection.
function M.create_or_convert()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local srow, _, erow = utils.visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    local lines = vim.api.nvim_buf_get_lines(0, srow - 1, erow, false)
    vim.api.nvim_buf_set_lines(0, srow - 1, erow, false, M.convert_lines(lines))
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

---------------------------------------------------------------------------
-- Formulas
---------------------------------------------------------------------------

--- Collect formulas from #+TBLFM lines.
local function read_formulas(bufnr, info)
  local out = {}
  for _, l in ipairs(info.tblfm) do
    local line = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]
    local body = line:match("^%s*#%+[Tt][Bb][Ll][Ff][Mm]:%s*(.-)%s*$")
    if body and body ~= "" then
      out[#out + 1] = body
    end
  end
  return table.concat(out, "::")
end

--- Recalculate the table at cursor (or at `lnum`) using its #+TBLFM line.
function M.recalc(bufnr, lnum)
  bufnr = bufnr or 0
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local info = M.find(bufnr, lnum)
  if not info then
    return false
  end
  local tblfm = read_formulas(bufnr, info)
  local t = M.parse(info.lines)
  pad_rows(t)
  if tblfm ~= "" then
    local formula = require("org.table.formula")
    local ok, err = pcall(formula.apply, t, formula.parse_tblfm(tblfm), {
      bufnr = bufnr,
      get_named_table = function(name)
        return M.get_named_table(bufnr, name, true)
      end,
    })
    if not ok then
      utils.error("Table formula error: " .. tostring(err))
    end
  end
  local lines = M.render(t)
  if not vim.deep_equal(lines, info.lines) then
    vim.api.nvim_buf_set_lines(bufnr, info.start - 1, info.finish, false, lines)
  end
end

--- Edit the #+TBLFM formulas of the table at cursor, one per line.
function M.edit_formulas()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local info = M.find(0, lnum)
  if not info then
    utils.warn("Not in a table")
    return
  end
  local formulas = read_formulas(0, info)
  local indent = info.lines[1]:match("^(%s*)")
  local start_line, end_line
  if #info.tblfm == 0 then
    vim.api.nvim_buf_set_lines(0, info.finish, info.finish, false, { indent .. "#+TBLFM:" })
    start_line, end_line = info.finish + 1, info.finish + 1
  else
    start_line, end_line = info.tblfm[1], info.tblfm[#info.tblfm]
  end
  local lines = formulas == "" and { "" } or vim.split(formulas, "::", { plain = true })
  require("org.special").open({
    source_buf = vim.api.nvim_get_current_buf(),
    start_line = start_line,
    end_line = end_line,
    lines = lines,
    name = "formulas",
    to_source = function(new)
      local parts = {}
      for _, l in ipairs(new) do
        l = vim.trim(l)
        if l ~= "" then
          parts[#parts + 1] = l
        end
      end
      if #parts == 0 then
        return {}
      end
      return { indent .. "#+TBLFM: " .. table.concat(parts, "::") }
    end,
  })
end

--- Rows (list of list of strings) of the table named `name` (#+NAME:).
--- Hlines are skipped. When `keep_header` is false and the first row is
--- followed by an hline, that header row is dropped (org-babel behaviour).
function M.get_named_table(bufnr, name, keep_header)
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
        local rows = {}
        local drop_header = not keep_header and #t.rows > 2 and not t.rows[1].hline and t.rows[2].hline
        for idx, r in ipairs(t.rows) do
          if not r.hline and not (drop_header and idx == 1) then
            rows[#rows + 1] = vim.deepcopy(r.cells)
          end
        end
        return rows
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
-- Buffer attach
---------------------------------------------------------------------------

function M.attach(bufnr)
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
