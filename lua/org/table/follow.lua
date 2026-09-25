---@mod org.table.follow Follow-field and header-line modes
---
--- - Follow-field mode (Emacs org-table-follow-field-mode, C-u C-u C-c `):
---   a small window below shows the full text of the current table field
---   and follows the cursor. Edit it there and write it back with
---   <C-c><C-c> or :w (moving to another field writes a modified field
---   too). The mode ends when the cursor leaves the table
---   (`table_exit_follow_field_mode_when_leaving_table`).
--- - Header-line mode (Emacs org-table-header-line-mode,
---   `table_header_line_p`): while the first row of the table at the top
---   of the window is scrolled out of view, it is shown in the window's
---   'winbar' (Emacs draws it over the first visible line).

local utils = require("org.utils")

local M = {}

local function tbl()
  return require("org.table")
end

---------------------------------------------------------------------------
-- Follow-field mode
---------------------------------------------------------------------------

--- Per source buffer: { buf = edit buffer, win = window, field = { lnum, col } }
local follow = {}

--- Field (line, column index) and its text at the cursor, or nil.
local function field_at_cursor()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  if not tbl().is_table_line(line) or line:match("^%s*|%-") then
    return nil
  end
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local n = 0
  for i = 1, col do
    if line:sub(i, i) == "|" and i < col then
      n = n + 1
    end
  end
  n = math.max(n, 1)
  local cells = tbl().split_cells(line)
  return { lnum = lnum, col = n }, cells[n] or ""
end

--- Write the follow buffer's text back into its field.
local function write_back(src)
  local st = follow[src]
  if not (st and st.field and vim.api.nvim_buf_is_valid(st.buf)) or not vim.bo[st.buf].modified then
    return
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false), " ")
  text = vim.trim(text):gsub("|", "\\vert{}")
  local line = vim.api.nvim_buf_get_lines(src, st.field.lnum - 1, st.field.lnum, false)[1]
  if line and tbl().is_table_line(line) then
    local pipes = {}
    for p in line:gmatch("()|") do
      pipes[#pipes + 1] = p
    end
    local a, b = pipes[st.field.col], pipes[st.field.col + 1]
    if a and b then
      local new = line:sub(1, a) .. " " .. text .. " " .. line:sub(b)
      vim.api.nvim_buf_set_lines(src, st.field.lnum - 1, st.field.lnum, false, { new })
      tbl().align_at(src, st.field.lnum)
    end
  end
  vim.bo[st.buf].modified = false
end

--- Show the current field in the follow window.
local function update(src)
  local st = follow[src]
  if not st or vim.api.nvim_get_current_buf() ~= src then
    return
  end
  local field, text = field_at_cursor()
  if not field then
    if require("org.config").opts.table_exit_follow_field_mode_when_leaving_table ~= false then
      M.stop(src)
    end
    return
  end
  if st.field and st.field.lnum == field.lnum and st.field.col == field.col then
    return
  end
  write_back(src)
  st.field = field
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, { text })
  vim.bo[st.buf].modified = false
  local t = tbl().find(src, field.lnum)
  local dl = 0
  if t then
    for i = t.start, field.lnum do
      if not vim.api.nvim_buf_get_lines(src, i - 1, i, false)[1]:match("^%s*|%-") then
        dl = dl + 1
      end
    end
  end
  if vim.api.nvim_win_is_valid(st.win) then
    vim.wo[st.win].winbar = string.format("Field @%d$%d  (<C-c><C-c> or :w writes it back)", dl, field.col)
  end
end

--- Start follow-field mode in the current buffer.
function M.start()
  local src = vim.api.nvim_get_current_buf()
  if follow[src] then
    return
  end
  if not field_at_cursor() then
    utils.warn("Not at a table")
    return false
  end
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, "*Org Table Edit Field*#" .. buf)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  local cur = vim.api.nvim_get_current_win()
  vim.cmd("botright 3split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].wrap = true
  vim.api.nvim_set_current_win(cur)
  local st = { buf = buf, win = win }
  follow[src] = st
  st.group = vim.api.nvim_create_augroup("org.table.follow." .. src, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = src,
    group = st.group,
    callback = function()
      update(src)
    end,
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    group = st.group,
    callback = function()
      write_back(src)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    group = st.group,
    callback = function()
      follow[src] = nil
      pcall(vim.api.nvim_del_augroup_by_id, st.group)
    end,
  })
  vim.keymap.set("n", "<C-c><C-c>", function()
    write_back(src)
  end, { buffer = buf, desc = "org: write the field back" })
  update(src)
  utils.notify("Table follow-field mode enabled")
  return true
end

--- End follow-field mode (writing a modified field back).
function M.stop(src)
  src = (src == nil or src == 0) and vim.api.nvim_get_current_buf() or src
  local st = follow[src]
  if not st then
    return
  end
  write_back(src)
  follow[src] = nil
  pcall(vim.api.nvim_del_augroup_by_id, st.group)
  if vim.api.nvim_win_is_valid(st.win) then
    pcall(vim.api.nvim_win_close, st.win, true)
  end
  if vim.api.nvim_buf_is_valid(st.buf) then
    pcall(vim.api.nvim_buf_delete, st.buf, { force = true })
  end
end

--- Toggle follow-field mode.
function M.toggle()
  local src = vim.api.nvim_get_current_buf()
  if follow[src] then
    M.stop(src)
    utils.notify("Table follow-field mode disabled")
    return false
  end
  return M.start()
end

--- Follow state of a buffer (for tests).
function M.state(src)
  return follow[(src == nil or src == 0) and vim.api.nvim_get_current_buf() or src]
end

---------------------------------------------------------------------------
-- Header-line mode
---------------------------------------------------------------------------

local header = {} -- bufnr -> { group, saved = { [win] = winbar } }

--- The header row (first row that is not an hline or a cookie row) of the
--- table at the top of window `win`, or nil when it is visible.
local function header_text(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local top = vim.fn.line("w0", win)
  local line = vim.api.nvim_buf_get_lines(buf, top - 1, top, false)[1]
  if not tbl().is_table_line(line) then
    return nil
  end
  local info = tbl().find(buf, top)
  if not info then
    return nil
  end
  for i, l in ipairs(info.lines) do
    if not l:match("^%s*|%-") and not l:match("|%s+<[rcl]?%d*>") then
      local lnum = info.start + i - 1
      if lnum >= top then
        return nil
      end
      return l
    end
  end
end

--- Refresh the winbar of the windows showing `bufnr`.
function M.refresh_header(bufnr)
  local st = header[bufnr]
  if not st then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    local text = header_text(win)
    if text then
      if st.saved[win] == nil then
        st.saved[win] = vim.wo[win].winbar
      end
      local info = vim.fn.getwininfo(win)[1]
      local leftcol = vim.api.nvim_win_call(win, function()
        return vim.fn.winsaveview().leftcol
      end)
      local shown = vim.fn.strcharpart(text, leftcol)
      vim.wo[win].winbar = "%#OrgTable#" .. string.rep(" ", info.textoff) .. shown:gsub("%%", "%%%%")
    elseif st.saved[win] ~= nil then
      vim.wo[win].winbar = st.saved[win]
      st.saved[win] = nil
    end
  end
end

--- Turn header-line mode on or off for `bufnr` (default: toggle).
---@param on? boolean
function M.header_line_mode(bufnr, on)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if on == nil then
    on = header[bufnr] == nil
  end
  if not on then
    local st = header[bufnr]
    if st then
      pcall(vim.api.nvim_del_augroup_by_id, st.group)
      for win, bar in pairs(st.saved) do
        if vim.api.nvim_win_is_valid(win) then
          vim.wo[win].winbar = bar
        end
      end
      header[bufnr] = nil
    end
    return false
  end
  if header[bufnr] then
    return true
  end
  local st = { saved = {} }
  st.group = vim.api.nvim_create_augroup("org.table.header." .. bufnr, { clear = true })
  header[bufnr] = st
  vim.api.nvim_create_autocmd({ "WinScrolled", "CursorMoved", "CursorMovedI", "BufWinEnter" }, {
    buffer = bufnr,
    group = st.group,
    callback = function()
      M.refresh_header(bufnr)
    end,
  })
  M.refresh_header(bufnr)
  return true
end

return M
