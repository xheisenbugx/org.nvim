---@mod org.table Org tables
---
--- Parsing, alignment and editing of `| a | b |` tables, plus spreadsheet
--- formulas (`#+TBLFM:`, see `org.table.formula`).
---
--- This file parses, renders and aligns tables and holds the cursor helpers;
--- the commands live in parts it loads (they add their functions to this
--- module): org/table/structure.lua (rows, columns, cells), sort.lua
--- (sorting, transposing), convert.lua (create, import, export), tblfm.lua
--- (formula commands), navigate.lua (field motion), fields.lua (field
--- commands) and region.lua (rectangles, wrapping).

local utils = require("org.utils")

local M = {}

-- The parts (org/table/*.lua, loaded below) require
-- this module back, so it must be in package.loaded before they load.
package.loaded["org.table"] = M

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
  -- Spaces/tabs after the closing delimiter are not an extra empty cell.
  local body = line:gsub("[ \t]+$", ""):gsub("^%s*|", "")
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
  if t.ncols == 0 and lines[1] then
    -- only hlines: as many columns as the first one has (org-table-align)
    t.ncols = select(2, lines[1]:gsub("%+", "")) + 1
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
  if lnum < 1 or not is_table_line(line) or require("org.table.el").at(bufnr, lnum) then
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
local number_rx = {}

--- Whether cell text `s` is a number for alignment: it matches
--- `table_number_regexp` (org-table-number-regexp), ignoring case like
--- Emacs. The default regexp is matched in Lua.
function M.is_number(s)
  local config = require("org.config")
  local re = config.opts.table_number_regexp
  if re == nil or re == config.defaults.table_number_regexp then
    if s:match(NUMBER) or s:match("^[<>]?[-+]?0[xX][%x.]+$") or s:match("^[<>]?[-+]?%d+#[%w.]+$") then
      return true
    end
    local l = s:lower()
    return l == "nan" or l:match("^[-+u]?inf$") ~= nil
  end
  local rx = number_rx[re]
  if rx == nil then
    local ok, r = pcall(vim.regex, "\\c" .. require("org.agenda.search").emacs_regexp(re, true))
    rx = ok and r or false
    number_rx[re] = rx
  end
  return rx and rx:match_str(s) ~= nil or false
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

--- Display width of a cell, as the buffer shows it: a link counts as its
--- description (or path) while links are shown descriptively, hidden
--- emphasis markers count for nothing and pretty entities count as their
--- character, like Emacs aligning with org-string-width (which skips
--- invisible text). `o` is the buffer's |org.ui.conceal_opts|.
---@param s string
---@param o? table
local function cell_width(s, o)
  return require("org.ui").visible_width(s, o)
end
M.cell_width = cell_width

--- Column widths and alignments ("l", "r" or "c") of a parsed table, like
--- Emacs org-table-align: the first `<l>`/`<r>`/`<c>` cookie fixes the
--- alignment, else a column is right-aligned when at least
--- `table_number_fraction` of its non-empty fields are numbers.
function M.layout(t, o)
  local fraction = require("org.config").opts.table_number_fraction or 0.5
  o = o or require("org.ui").conceal_opts()
  local widths, align = {}, {}
  for c = 1, t.ncols do
    local w, fixed, numbers, nonempty = 1, nil, 0, 0
    for _, row in ipairs(t.rows) do
      if not row.hline then
        local cell = row.cells[c] or ""
        w = math.max(w, cell_width(cell, o))
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
  local o = require("org.ui").conceal_opts()
  local widths, align = M.layout(t, o)
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
        local pad = widths[c] - cell_width(cell, o)
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

--- An empty row for inserting at `at`, copying the `#`, `*` or `$` mark of
--- the row above (Emacs org-table-insert-row below that row).
local function new_row_at(t, at)
  local row = empty_row(t.ncols)
  local above = t.rows[at - 1]
  local mark = above and not above.hline and above.cells[1]
  if mark == "#" or mark == "*" or mark == "$" then
    row.cells[1] = mark
  end
  return row
end

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

--- Rectangle of fields to act on: the visual selection (visual mode is
--- left) or, in normal mode, the current field (or the whole current
--- column when `whole_column`).
---@return table|nil info
---@return integer[]|nil rows table row indices (hlines skipped)
---@return integer|nil c1
---@return integer|nil c2
local function selected_rect(whole_column)
  local visual = in_visual()
  local srow, scol, erow, ecol, mode
  if visual then
    srow, scol, erow, ecol, mode = utils.visual_range()
    utils.exit_visual()
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

-- Local functions the parts below use
local shared = require("org.table.shared")
shared.current_field = current_field
shared.cursor_pos = cursor_pos
shared.dline = dline
shared.empty_row = empty_row
shared.in_visual = in_visual
shared.is_table_line = is_table_line
shared.is_tblfm = is_tblfm
shared.new_row_at = new_row_at
shared.pad_rows = pad_rows
shared.pipe_positions = pipe_positions
shared.reload = reload
shared.restore_cursor = restore_cursor
shared.selected_rect = selected_rect
shared.set_cursor = set_cursor
shared.write_table = write_table

require("org.table.structure")
require("org.table.sort")
require("org.table.convert")
require("org.table.tblfm")
require("org.table.navigate")
require("org.table.fields")
require("org.table.region")

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

--- C-c ~ (org-table-create-with-table.el): convert between Org and
--- table.el tables, or insert a new table.el table (see `org.table.el`).
function M.table_el()
  return require("org.table.el").create_or_convert()
end

---------------------------------------------------------------------------
-- Buffer attach
---------------------------------------------------------------------------

--- Align every Org table of `bufnr` (org-table-map-tables with
--- org-table-align).
function M.align_all(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local l = 1
  while l <= vim.api.nvim_buf_line_count(bufnr) do
    local line = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]
    if is_table_line(line) then
      local info = M.find(bufnr, l)
      if info then
        M.align_at(bufnr, l)
        l = M.find(bufnr, l).finish
      else
        while is_table_line(vim.api.nvim_buf_get_lines(bufnr, l, l + 1, false)[1]) do
          l = l + 1
        end
      end
    end
    l = l + 1
  end
end

function M.attach(bufnr)
  local config = require("org.config").opts
  if config.table_header_line_p then
    require("org.table.follow").header_line_mode(bufnr, true)
  end
  local startup = require("org.files").get_buffer(bufnr).settings.startup or {}
  -- #+STARTUP: align / noalign (org-startup-align-all-tables)
  local align = startup.align or (config.startup_align_all_tables and not startup.noalign)
  local shrink = startup.shrink or (config.startup_shrink_all_tables and not startup.noshrink)
  if align or shrink then
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        if align then
          M.align_all(bufnr)
        end
        if shrink then
          require("org.table.shrink").shrink_all(bufnr)
        end
      end
    end)
  end
  require("org.table.typing").attach(bufnr)
  vim.api.nvim_create_autocmd("InsertLeave", {
    buffer = bufnr,
    group = vim.api.nvim_create_augroup("org.table." .. bufnr, { clear = true }),
    callback = function()
      if vim.api.nvim_get_current_buf() ~= bufnr then
        return
      end
      if require("org.config").opts.table_automatic_realign == false then
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
