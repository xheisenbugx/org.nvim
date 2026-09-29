---@mod org.table.typing Typing into table fields
---
--- Emacs org-self-insert-command / orgtbl-self-insert-command in tables:
--- - right after a field motion (<Tab>, <S-Tab>, <CR>) the first
---   character typed replaces the field's text (org-table-auto-blank-field);
--- - a character typed into a field that ends with two or more spaces
---   takes the place of one of them, so the table stays aligned (in
---   orgtbl-mode only with orgtbl-optimized).
---
--- - "|" is inserted as it is (org-force-self-insert);
--- - <BS> and <Del> in Insert mode delete a character of a field and put
---   a space before the next separator, so the column keeps its width
---   (org-delete-backward-char, org-delete-char).
---
--- InsertCharPre cannot change the buffer, so it records the position and
--- TextChangedI fixes the field once the character is in (or out).

local M = {}

local pending = {} -- bufnr -> { lnum, col, tick } after a field motion
local typed = {} -- bufnr -> { lnum, col, char, blank } for TextChangedI
local deleting = {} -- bufnr -> { lnum, line, col } expected after <BS>/<Del>
local attached = {} -- bufnr -> true

--- A field motion just put the cursor at the start of a field.
function M.motion_done(bufnr)
  local c = vim.api.nvim_win_get_cursor(0)
  pending[bufnr] = { lnum = c[1], col = c[2], tick = vim.api.nvim_buf_get_changedtick(bufnr) }
end

local function on_char(bufnr, char)
  local p = pending[bufnr]
  pending[bufnr] = nil
  typed[bufnr] = nil
  char = char or vim.v.char
  if char == "|" then
    -- org-force-self-insert: no blanking, no padding
    return
  end
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
  typed[bufnr] = { lnum = c[1], col = c[2], char = char, blank = blank }
end

local function table_row(line)
  return line:match("^%s*|") and not line:match("^%s*|%-")
end

--- Before <BS> (`backward` true) or <Del> in Insert mode: when Emacs
--- would keep the field's width, remember the line the key will leave.
local function on_delete(bufnr, backward)
  deleting[bufnr] = nil
  local line = vim.api.nvim_get_current_line()
  if not table_row(line) then
    return
  end
  local c = vim.api.nvim_win_get_cursor(0)
  local col = c[2] -- bytes before the cursor
  local s, e -- the character deleted, 1-based
  if backward then
    if col == 0 then
      return
    end
    s = vim.str_utf_start(line, col) + col
    e = col
  else
    if col >= #line then
      return
    end
    s = col + 1
    e = col + vim.str_utf_end(line, col + 1) + 1
  end
  -- not a separator, not in the indentation, with a separator after it
  if line:sub(s, e) == "|" or not line:sub(1, s - 1):match("%S") or not line:find("|", e + 1, true) then
    return
  end
  deleting[bufnr] = { lnum = c[1], line = line:sub(1, s - 1) .. line:sub(e + 1), col = s - 1 }
end

--- After a deletion recorded by `on_delete`: a space before the next
--- separator.
local function after_delete(bufnr)
  local st = deleting[bufnr]
  deleting[bufnr] = nil
  if not st then
    return
  end
  local c = vim.api.nvim_win_get_cursor(0)
  if c[1] ~= st.lnum or c[2] ~= st.col or vim.api.nvim_get_current_line() ~= st.line then
    return
  end
  local pipe = st.line:find("|", st.col + 1, true)
  vim.api.nvim_buf_set_text(bufnr, c[1] - 1, pipe - 1, c[1] - 1, pipe - 1, { " " })
  vim.api.nvim_win_set_cursor(0, c)
end

local key_ns
local delete_keys
local function watch_delete_keys()
  if key_ns then
    return
  end
  delete_keys = {
    [vim.keycode("<BS>")] = true,
    [vim.keycode("<C-h>")] = true,
    [vim.keycode("<Del>")] = false,
  }
  key_ns = vim.on_key(function(key)
    local backward = delete_keys[key]
    if backward == nil then
      return
    end
    local bufnr = vim.api.nvim_get_current_buf()
    if not attached[bufnr] then
      return
    end
    local mode = vim.api.nvim_get_mode().mode
    if mode ~= "i" then
      deleting[bufnr] = nil
      return
    end
    pcall(on_delete, bufnr, backward)
  end, vim.api.nvim_create_namespace("org.table.typing.keys"))
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
  attached[bufnr] = true
  watch_delete_keys()
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
      after_delete(bufnr)
      on_changed(bufnr)
    end,
  })
end

--- Stop handling typing in `bufnr`.
function M.detach(bufnr)
  pcall(vim.api.nvim_del_augroup_by_name, "org.table.typing." .. bufnr)
  pending[bufnr], typed[bufnr], deleting[bufnr], attached[bufnr] = nil, nil, nil, nil
end

M._on_char = on_char
M._on_changed = on_changed
M._on_delete = on_delete
M._after_delete = after_delete

return M
