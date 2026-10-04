---@mod org.table.navigate Moving between table fields
---
--- <Tab>, <S-Tab> and <CR> in a table (org-table-next-field,
--- org-table-previous-field, org-table-next-row), C-c RET
--- (org-table-hline-and-move) and org-table-goto-column.
---
--- Part of org.table, which loads it.

local shared = require("org.table.shared")

local M = require("org.table")

local before_move = shared.before_move
local current_field = shared.current_field
local cursor_pos = shared.cursor_pos
local dline = shared.dline
local empty_row = shared.empty_row
local is_table_line = shared.is_table_line
local new_row_at = shared.new_row_at
local pad_rows = shared.pad_rows
local pipe_positions = shared.pipe_positions
local set_cursor = shared.set_cursor
local write_table = shared.write_table

--- Write the table after a field motion (org-table-automatic-realign):
--- realigned when `table_automatic_realign` is on or `force` (a row was
--- added), else left as it is. Returns the table's lines.
local function motion_write(info, t, force)
  if force or require("org.config").opts.table_automatic_realign ~= false then
    return write_table(info, t)
  end
  return vim.api.nvim_buf_get_lines(0, info.start - 1, info.finish, false)
end

--- Remember that the cursor just moved to a field, so that typing replaces
--- it (org-table-auto-blank-field).
local function after_motion()
  require("org.table.typing").motion_done(vim.api.nvim_get_current_buf())
end
M.after_motion = after_motion

--- Move to the next field (insert-mode <Tab>); creates a row at the end.
--- Hlines are jumped over (`table_tab_jumps_over_hlines`), else a row is
--- added before them, like Emacs org-table-next-field.
function M.next_field()
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field = cursor_pos(info)
  info = before_move(info, row, field)
  local t = info.tbl
  pad_rows(t)
  local jumps = require("org.config").opts.table_tab_jumps_over_hlines ~= false
  local target_row, target_field = row, field + 1
  local insert_at
  if t.rows[row].hline or target_field > t.ncols then
    target_field = 1
    target_row = row + 1
    if t.rows[row].hline or (t.rows[target_row] and t.rows[target_row].hline and jumps) then
      while t.rows[target_row] and t.rows[target_row].hline do
        target_row = target_row + 1
      end
      if not t.rows[target_row] then
        -- no data row after the hline: a new row before it
        insert_at = t.rows[row].hline and #t.rows + 1 or row + 1
      end
    elseif t.rows[target_row] and t.rows[target_row].hline then
      insert_at = row + 1
    elseif not t.rows[target_row] then
      insert_at = #t.rows + 1
    end
  end
  if insert_at then
    table.insert(t.rows, insert_at, new_row_at(t, insert_at))
    target_row = insert_at
  end
  local lines = motion_write(info, t, insert_at ~= nil)
  if insert_at then
    -- org-table-insert-row: rows from the new one on move down
    M.fix_formulas(0, info.finish, "@", nil, dline(t, insert_at) - 1, 1)
  end
  set_cursor(info, lines, target_row, target_field, 0)
  after_motion()
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
  local lines = motion_write(info, t)
  set_cursor(info, lines, target_row, target_field, 0)
  after_motion()
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
  local added = false
  if not nxt or nxt.hline then
    table.insert(t.rows, row + 1, new_row_at(t, row + 1))
    added = true
  end
  local lines = motion_write(info, t, added)
  if added then
    -- org-table-insert-row: rows from the new one on move down
    M.fix_formulas(0, info.finish, "@", nil, dline(t, row + 1) - 1, 1)
  end
  set_cursor(info, lines, row + 1, field, 0)
  after_motion()
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

--- Move to column `n` (a count, default 1) of the current table row: after
--- the `| ` that starts the field, or after the last `|` when the row has
--- fewer fields (org-table-goto-column).
function M.goto_column(n)
  n = n or math.max(vim.v.count, 1)
  local line = vim.api.nvim_get_current_line()
  if not is_table_line(line) then
    return false
  end
  local pipes = pipe_positions(line)
  local p = pipes[math.min(n, #pipes)]
  local col = p
  if line:sub(p + 1, p + 1) == " " then
    col = p + 1
  end
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_win_get_cursor(0)[1], math.min(col, math.max(#line - 1, 0)) })
end
