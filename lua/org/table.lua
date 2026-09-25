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

-- Defined with the formula commands below.
local before_move

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

--- Write the table at the cursor to a TSV or CSV file (hlines dropped). The
--- file and format come from the TABLE_EXPORT_FILE / TABLE_EXPORT_FORMAT
--- properties (inherited) when set, else the file is asked for and the
--- format follows its extension. Emacs org-table-export.
---@param path? string
---@param format? string "tsv" or "csv" (also "orgtbl-to-tsv" / "orgtbl-to-csv")
function M.export(path, format)
  local info = M.at_cursor()
  if not info then
    return false
  end
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
    format = (path:match("%.(%w+)$") or ""):lower() == "csv" and "csv" or "tsv"
  end
  format = vim.trim(format):gsub("^orgtbl%-to%-", ""):match("^(%S+)")
  if format ~= "tsv" and format ~= "csv" then
    utils.warn("Unsupported table export format: " .. tostring(format) .. " (use tsv or csv)")
    return
  end
  local rows = {}
  for _, r in ipairs(info.tbl.rows) do
    if not r.hline then
      rows[#rows + 1] = r.cells
    end
  end
  utils.writefile(path, M.to_separated(rows, format))
  utils.notify("Export done: " .. path)
  return path
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

--- Recalculate the table at cursor (or at `lnum`) using its #+TBLFM line.
function M.recalc(bufnr, lnum)
  bufnr = bufnr or 0
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local info = M.find(bufnr, lnum)
  if not info then
    return false
  end
  local lines = M.recalc_lines(bufnr, info.lines, read_formulas(bufnr, info), info.start)
  if not vim.deep_equal(lines, info.lines) then
    vim.api.nvim_buf_set_lines(bufnr, info.start - 1, info.finish, false, lines)
  end
end

--- Apply formulas to table `lines` and return the aligned result. `tblfm`
--- is the formula string or a list of `#+TBLFM:` lines; `lnum` locates the
--- table in `bufnr` (for $PROP_ lookups).
---@param tblfm string|string[]
function M.recalc_lines(bufnr, lines, tblfm, lnum)
  if type(tblfm) == "table" then
    local parts = {}
    for _, l in ipairs(tblfm) do
      local body = l:match("^%s*#%+[Tt][Bb][Ll][Ff][Mm]:%s*(.-)%s*$")
      if body and body ~= "" then
        parts[#parts + 1] = body
      end
    end
    tblfm = table.concat(parts, "::")
  end
  local t = M.parse(lines)
  pad_rows(t)
  if tblfm ~= "" then
    local formula = require("org.table.formula")
    local ok, err = pcall(formula.apply, t, formula.parse_tblfm(tblfm), {
      bufnr = bufnr,
      get_table = function(name)
        return M.find_named_table(bufnr, name)
      end,
      constants = formula_constants(bufnr),
      property = function(name)
        local hl = require("org.files").get_buffer(bufnr):headline_at(lnum)
        return hl and hl:get_property(name, true)
      end,
    })
    if not ok then
      utils.error("Table formula error: " .. tostring(err))
    end
  end
  return M.render(t)
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

--- Individual `lhs=rhs` formulas of the #+TBLFM lines, verbatim.
local function formula_parts(bufnr, info)
  local parts = {}
  for part in (read_formulas(bufnr, info) .. "::"):gmatch("(.-)::") do
    part = vim.trim(part)
    if part ~= "" then
      parts[#parts + 1] = part
    end
  end
  return parts
end

--- Index of the formula whose target is exactly `lhs`, or nil.
local function find_formula(parts, lhs)
  for i, p in ipairs(parts) do
    if vim.trim(p:match("^(.-)=") or "") == lhs then
      return i
    end
  end
end

--- Replace the #+TBLFM lines of table `info` (creating/removing them).
local function write_formulas(bufnr, info, parts)
  local indent = info.lines[1]:match("^(%s*)")
  local new = #parts > 0 and { indent .. "#+TBLFM: " .. table.concat(parts, "::") } or {}
  if #info.tblfm == 0 then
    vim.api.nvim_buf_set_lines(bufnr, info.finish, info.finish, false, new)
  else
    vim.api.nvim_buf_set_lines(bufnr, info.tblfm[1] - 1, info.tblfm[#info.tblfm], false, new)
  end
end

--- Put the cursor back on `row`/`field` of the table starting at `start`.
local function restore_cursor(start, row, field)
  local info = M.find(0, start)
  if info then
    set_cursor(info, info.lines, row, field, 0)
  end
end

--- Set (or remove, on empty input) the formula of the current column in
--- #+TBLFM and recalculate. With a count (or `field_formula` = true) the
--- formula is a field formula `@R$C=` instead. Emacs `C-c =` / `C-u C-c =`
--- (org-table-eval-formula).
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
  if field_formula == nil then
    field_formula = vim.v.count > 0
  end
  local lhs = field_formula and ("@" .. dline(t, row) .. "$" .. field) or ("$" .. field)
  local parts = formula_parts(0, info)
  local idx = find_formula(parts, lhs)
  local default = idx and parts[idx]:match("^.-=%s*(.*)$") or ""
  local rhs = utils.input({
    prompt = (field_formula and "Field" or "Column") .. " formula " .. lhs .. "=",
    default = default,
  })
  if rhs == nil then
    return
  end
  rhs = vim.trim(rhs)
  if rhs == "" then
    if not idx then
      return
    end
    table.remove(parts, idx)
  elseif idx then
    parts[idx] = lhs .. "=" .. rhs
  else
    parts[#parts + 1] = lhs .. "=" .. rhs
  end
  write_formulas(0, info, parts)
  M.recalc(0, info.start)
  restore_cursor(info.start, row, field)
end

--- When field `field` of row `row` holds `=formula` (or `:=formula`),
--- install it as the column (or field) formula in #+TBLFM, clear the field
--- and recalculate. Emacs org-table-maybe-eval-formula (typing a formula
--- into a field and pressing <Tab>, <CR> or C-c C-c).
---@return boolean installed
local function maybe_eval_formula(info, row, field)
  local t = info.tbl
  local r = t.rows[row]
  if not r or r.hline then
    return false
  end
  local named, rhs = vim.trim(r.cells[field] or ""):match("^(:?)=(.*[^=])$")
  if not rhs then
    return false
  end
  local lhs = named == ":" and ("@" .. dline(t, row) .. "$" .. field) or ("$" .. field)
  r.cells[field] = ""
  write_table(info, t)
  local parts = formula_parts(0, info)
  local idx = find_formula(parts, lhs)
  parts[idx or (#parts + 1)] = lhs .. "=" .. vim.trim(rhs)
  write_formulas(0, info, parts)
  M.recalc(0, info.start)
  return true
end

--- Recalculate the table when row `row` is marked with `#` in its first
--- column. Emacs org-table-maybe-recalculate-line.
local function maybe_recalc_line(info, row)
  local r = info.tbl.rows[row]
  if r and not r.hline and vim.trim(r.cells[1] or "") == "#" and #info.tblfm > 0 then
    M.recalc(0, info.start)
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

--- C-c C-c in a table: install an inline `=`/`:=` formula, recalculate a
--- `#`-marked row, then realign (org-ctrl-c-ctrl-c).
function M.ctrl_c_ctrl_c()
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field, offset = cursor_pos(info)
  info = before_move(info, row, field)
  local lines = write_table(info, info.tbl)
  set_cursor(info, lines, row, math.min(field, info.tbl.ncols), offset)
end

--- Edit the full content of the current field in a prompt, then realign.
--- Emacs `C-c `` (org-table-edit-field).
function M.edit_field()
  local info, row, field = current_field()
  if not info then
    return false
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

local function in_visual()
  local m = vim.fn.mode()
  return m == "v" or m == "V" or m == "\22"
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

--- Sum the numbers (and H:MM[:SS] durations) of the current column, or of
--- the fields in the visual selection. Rows above the first hline (the
--- header) are skipped in the whole-column case. The result is shown and
--- stored in the unnamed register. Emacs `C-c +` (org-table-sum).
function M.sum()
  local visual = in_visual()
  local info, rows, c1, c2 = selected_rect(true)
  if not info then
    return false
  end
  local t = info.tbl
  local first = 1
  if not visual then
    for i, r in ipairs(t.rows) do
      if r.hline then
        if i > 1 and i < #t.rows then
          first = i + 1
        end
        break
      end
    end
  end
  local formula = require("org.table.formula")
  local total, count, time, seconds = 0, 0, false, false
  for _, r in ipairs(rows) do
    if r >= first then
      for c = c1, c2 do
        local v = vim.trim(t.rows[r].cells[c] or "")
        local secs = formula._parse_duration(v)
        if secs then
          time = true
          seconds = seconds or select(2, v:gsub(":", "")) > 1
          total, count = total + secs, count + 1
        else
          local n = tonumber(v) or tonumber((v:gsub("^%+", "")))
          if n and v ~= "" then
            total, count = total + n, count + 1
          end
        end
      end
    end
  end
  local s
  if time then
    s = formula._format_duration(total, seconds)
  elseif total == math.floor(total) and math.abs(total) < 1e15 then
    s = string.format("%d", total)
  else
    s = string.format("%.12g", total)
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
