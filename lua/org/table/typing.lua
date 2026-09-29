---@mod org.table.typing Typing into table fields
---
--- Emacs org-self-insert-command / orgtbl-self-insert-command in tables:
--- - right after a field motion (<Tab>, <S-Tab>, <CR>) the first
---   character typed replaces the field's text (org-table-auto-blank-field);
--- - a character typed into a field that ends with two or more spaces
---   takes the place of one of them, so the table stays aligned (in
---   orgtbl-mode only with orgtbl-optimized).
---
--- InsertCharPre cannot change the buffer, so it records the position and
--- TextChangedI fixes the field once the character is in.

local M = {}

local pending = {} -- bufnr -> { lnum, col, tick } after a field motion
local typed = {} -- bufnr -> { lnum, col, char, blank } for TextChangedI

--- A field motion just put the cursor at the start of a field.
function M.motion_done(bufnr)
  local c = vim.api.nvim_win_get_cursor(0)
  pending[bufnr] = { lnum = c[1], col = c[2], tick = vim.api.nvim_buf_get_changedtick(bufnr) }
end

local function on_char(bufnr, char)
  local p = pending[bufnr]
  pending[bufnr] = nil
  typed[bufnr] = nil
  local line = vim.api.nvim_get_current_line()
  if not line:match("^%s*|") or line:match("^%s*|%-") then
    return
  end
  local c = vim.api.nvim_win_get_cursor(0)
  local blank = p ~= nil
    and require("org.config").opts.table_auto_blank_field ~= false
    and p.lnum == c[1]
    and p.col == c[2]
    and p.tick == vim.api.nvim_buf_get_changedtick(bufnr)
  typed[bufnr] = { lnum = c[1], col = c[2], char = char or vim.v.char, blank = blank }
end

local function on_changed(bufnr)
  local st = typed[bufnr]
  typed[bufnr] = nil
  if not st then
    return
  end
  local c = vim.api.nvim_win_get_cursor(0)
  if c[1] ~= st.lnum or c[2] ~= st.col + #st.char then
    return
  end
  local line = vim.api.nvim_get_current_line()
  local from = c[2] + 1
  local pipe = line:find("|", from, true)
  if not pipe then
    return
  end
  local seg = line:sub(from, pipe - 1)
  local new = seg
  if st.blank then
    -- org-table-blank-field: the rest of the field becomes spaces
    new = string.rep(" ", vim.fn.strchars(seg))
  end
  if new:match("  $") then
    -- room for the character: drop a space before the separator
    new = new:sub(1, -2)
  end
  if new ~= seg then
    vim.api.nvim_buf_set_text(bufnr, c[1] - 1, c[2], c[1] - 1, pipe - 1, { new })
    vim.api.nvim_win_set_cursor(0, c)
  end
end

--- Handle typing in the tables of `bufnr`.
function M.attach(bufnr)
  local group = vim.api.nvim_create_augroup("org.table.typing." .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("InsertCharPre", {
    buffer = bufnr,
    group = group,
    callback = function()
      on_char(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd("TextChangedI", {
    buffer = bufnr,
    group = group,
    callback = function()
      on_changed(bufnr)
    end,
  })
end

--- Stop handling typing in `bufnr`.
function M.detach(bufnr)
  pcall(vim.api.nvim_del_augroup_by_name, "org.table.typing." .. bufnr)
  pending[bufnr], typed[bufnr] = nil, nil
end

M._on_char = on_char
M._on_changed = on_changed

return M
