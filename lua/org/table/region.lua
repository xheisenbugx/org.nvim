---@mod org.table.region Table rectangles and wrapping
---
--- Copying, cutting and pasting rectangles of fields (C-c C-x M-w / C-w /
--- C-y) and M-RET in a table (org-table-wrap-region).
---
--- Part of org.table, which loads it.

local utils = require("org.utils")
local shared = require("org.table.shared")

local M = require("org.table")

local current_field = shared.current_field
local cursor_pos = shared.cursor_pos
local empty_row = shared.empty_row
local in_visual = shared.in_visual
local pad_rows = shared.pad_rows
local selected_rect = shared.selected_rect
local set_cursor = shared.set_cursor
local write_table = shared.write_table

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

--- org--do-wrap: lines of at most about `width` characters.
local function do_wrap(words, width)
  local lines = {}
  local i = 1
  while i <= #words do
    local line = words[i]
    i = i + 1
    while words[i] and vim.fn.strchars(line) + vim.fn.strchars(words[i]) < width do
      line = line .. " " .. words[i]
      i = i + 1
    end
    lines[#lines + 1] = line
  end
  return lines
end

--- org-wrap: `text` in at most `nlines` lines, as narrow as possible.
local function wrap_text(text, nlines)
  local words = vim.split(vim.trim(text), "%s+")
  if #words == 0 or words[1] == "" then
    return {}
  end
  local w = 0
  for _, word in ipairs(words) do
    w = math.max(w, vim.fn.strchars(word))
  end
  local ll = do_wrap(words, w)
  while #ll > nlines do
    w = w + 1
    ll = do_wrap(words, w)
  end
  return ll
end

--- M-RET in a table (org-table-wrap-region). In Visual mode, the fields
--- of the selected column are wrapped like a paragraph into as many lines
--- as selected (or `count` lines). Otherwise the text after the cursor
--- moves to the start of the field below (only in Insert mode with
--- `meta_return_split_line`, else the cursor just goes to the field
--- below); with a count the field is emptied and its text appended to the
--- field above.
---@param opts? { count?: integer, split?: boolean }
function M.wrap_region(opts)
  opts = opts or {}
  local count = opts.count
  if count == nil and vim.v.count > 0 then
    count = vim.v.count
  end
  if in_visual() then
    local info, rows, c1, c2 = selected_rect()
    if not info then
      return false
    end
    if c1 ~= c2 then
      utils.warn("Region must be limited to single column")
      return
    end
    local t = info.tbl
    pad_rows(t)
    local words = {}
    for _, r in ipairs(rows) do
      words[#words + 1] = t.rows[r].cells[c1]
      t.rows[r].cells[c1] = ""
    end
    local nlines = #rows
    if count and count < 1 then
      nlines = #rows + count
    elseif count then
      nlines = count
    end
    local wrapped = wrap_text(table.concat(words, " "), math.max(nlines, 1))
    -- paste from the first selected row down, over the data rows
    local r = rows[1]
    for _, text in ipairs(wrapped) do
      while t.rows[r] and t.rows[r].hline do
        r = r + 1
      end
      if not t.rows[r] then
        t.rows[r] = empty_row(t.ncols)
      end
      t.rows[r].cells[c1] = text
      r = r + 1
    end
    local lines = write_table(info, t)
    set_cursor(info, lines, rows[1], c1, 0)
    return
  end
  local info, row, field = current_field()
  if not info then
    return false
  end
  local t = info.tbl
  if t.rows[row].hline then
    utils.warn("Not in a table data field")
    return
  end
  pad_rows(t)
  if count then
    -- combine with the field above
    local text = vim.trim(t.rows[row].cells[field] or "")
    t.rows[row].cells[field] = ""
    local above = row - 1
    while t.rows[above] and t.rows[above].hline do
      above = above - 1
    end
    if not t.rows[above] then
      utils.warn("No field above")
      return
    end
    t.rows[above].cells[field] = vim.trim((t.rows[above].cells[field] or ""):gsub("%s+$", "") .. " " .. text)
    local lines = write_table(info, t)
    set_cursor(info, lines, above, field, 0)
    return
  end
  local split = opts.split
  if split == nil then
    split = require("org.structure").may_split_line("table")
  end
  local lnum, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local pipe = line:find("|", col + 1, true)
  if not split and pipe then
    col = pipe - 1
  end
  local rest = pipe and line:sub(col + 1, pipe - 1) or ""
  if pipe and rest ~= "" then
    -- split the field: the text after the cursor starts the field below
    vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { line:sub(1, col) .. " " .. line:sub(pipe) })
    vim.api.nvim_win_set_cursor(0, { lnum, col })
    M.next_row()
    local info2 = M.at_cursor()
    local row2, field2 = cursor_pos(info2)
    local t2 = info2.tbl
    pad_rows(t2)
    t2.rows[row2].cells[field2] = vim.trim(vim.trim(rest) .. " " .. (t2.rows[row2].cells[field2] or ""))
    local lines = write_table(info2, t2)
    set_cursor(info2, lines, row2, field2, 0)
    return
  end
  vim.api.nvim_win_set_cursor(0, { lnum, col })
  M.next_row()
end
