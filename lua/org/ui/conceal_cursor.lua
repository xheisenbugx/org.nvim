--- Keep the cursor off concealed text in Normal mode. Emacs never leaves
--- point inside invisible text (the command loop's point adjustment), so
--- `C-f` on a descriptive link goes from the text before it to its
--- description. In Vim, `l` would step through the hidden `[[target][`
--- one character at a time with the cursor standing still on screen.
--- After a motion that lands on fully hidden text (syntax conceal at
--- 'conceallevel' 2 without a replacement character, or level 3), the
--- cursor goes on past it in the direction it moved, or back when nothing
--- visible follows on the line.
local M = {}

--- Whether byte `col` (1-based) of line `lnum` is concealed and not drawn.
---@param lnum integer
---@param col integer
---@param level integer 'conceallevel'
---@return boolean
local function hidden(lnum, col, level)
  local c = vim.fn.synconcealed(lnum, col)
  return c[1] == 1 and (level >= 3 or c[2] == "")
end

--- The first byte of the character after the one at `col`, or nil at the
--- end of `line`.
---@param line string
---@param col integer
---@return integer|nil
local function next_char(line, col)
  local n = col + vim.str_utf_end(line, col) + 1
  return n <= #line and n or nil
end

--- The first byte of the character before the one at `col`, or nil at the
--- start of `line`.
---@param line string
---@param col integer
---@return integer|nil
local function prev_char(line, col)
  if col <= 1 then
    return nil
  end
  return col - 1 + vim.str_utf_start(line, col - 1)
end

--- The first visible character from `col` on, stepping with `step`.
---@param line string
---@param lnum integer
---@param col integer
---@param level integer
---@param step fun(line: string, col: integer): integer|nil
---@return integer|nil
local function visible_from(line, lnum, col, level, step)
  local c = col ---@type integer|nil
  while c and hidden(lnum, c, level) do
    c = step(line, c)
  end
  return c
end

--- Move the cursor of the current window off hidden text (CursorMoved).
function M.adjust()
  local win = vim.api.nvim_get_current_win()
  local pos = vim.api.nvim_win_get_cursor(win)
  local prev = vim.w[win].org_conceal_cursor
  vim.w[win].org_conceal_cursor = pos
  local wo = vim.wo[win]
  if vim.api.nvim_get_mode().mode ~= "n" or wo.conceallevel < 2 or not wo.concealcursor:find("n", 1, true) then
    return
  end
  local lnum, col = pos[1], pos[2] + 1
  local line = vim.api.nvim_get_current_line()
  if col > #line or not hidden(lnum, col, wo.conceallevel) then
    return
  end
  -- the direction of the motion; from another line (j, k, a search) forward
  local back = prev ~= nil and prev[1] == lnum and prev[2] > pos[2]
  local level = wo.conceallevel
  local to
  if back then
    to = visible_from(line, lnum, col, level, prev_char) or visible_from(line, lnum, col, level, next_char)
  else
    to = visible_from(line, lnum, col, level, next_char) or visible_from(line, lnum, col, level, prev_char)
  end
  if to then
    vim.api.nvim_win_set_cursor(win, { lnum, to - 1 })
    vim.w[win].org_conceal_cursor = { lnum, to - 1 }
  end
end

--- Adjust the cursor in buffer `bufnr` after each motion.
---@param bufnr integer
---@param group integer augroup
function M.attach(bufnr, group)
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = bufnr,
    callback = function()
      M.adjust()
    end,
  })
end

return M
