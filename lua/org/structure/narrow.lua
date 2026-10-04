---@mod org.structure.narrow Narrowing and indirect buffers
---
--- Narrow to a subtree and org-tree-to-indirect-buffer.
---
--- Part of org.structure, which loads it.

local config = require("org.config")
local utils = require("org.utils")
local shared = require("org.structure.shared")

local M = require("org.structure")

local buf = shared.buf
local current_headline = shared.current_headline
local get_lines = shared.get_lines

---------------------------------------------------------------------------
-- Narrowing
---------------------------------------------------------------------------

--- Edit the subtree of `hl` (in `bufnr`) in a narrowed edit buffer shown
--- in `window` (see ui.open_buffer_window).
local function narrow_headline(bufnr, hl, window)
  return require("org.special").open({
    source_buf = bufnr,
    start_line = hl.line,
    end_line = hl.end_line,
    lines = get_lines(bufnr, hl.line, hl.end_line),
    filetype = "org",
    name = "narrow " .. hl:plain_title(),
    window = window,
    narrow = true,
  })
end

local function narrow(window)
  local hl = current_headline()
  if not hl then
    utils.warn("Not in a subtree")
    return
  end
  return narrow_headline(buf(), hl, window)
end

function M.narrow_subtree()
  narrow()
end

--- The headline whose subtree org-tree-to-indirect-buffer takes with the
--- numeric argument `arg`: the ancestor at level `arg`, or `-arg` levels
--- up when it is negative (nil: `hl` itself).
local function indirect_headline(hl, arg)
  if type(arg) ~= "number" then
    return hl
  end
  if arg < 0 then
    arg = hl.level + arg
  end
  while hl.parent and hl.level > arg do
    hl = hl.parent
  end
  return hl
end

--- The edit buffer of the last tree_to_indirect_buffer (org-last-indirect-buffer).
M._last_indirect = nil

--- Edit the current subtree in a split window (org-tree-to-indirect-buffer).
--- Uses `win_split_mode` when it is a split / tab, otherwise a horizontal
--- split. The buffer is an edit buffer like `narrow_subtree`: `:w` or the
--- save mapping writes it back.
---
--- Where it shows follows `indirect_buffer_display`
--- (org-indirect-buffer-display): "other-window" (a split, reused by the
--- next call, the cursor staying in the Org buffer), "current-window",
--- "new-frame" (a new tab each time) or "dedicated-frame" (one tab reused).
--- The previous edit buffer is closed (unless it has changes), except
--- with "new-frame" or `arg`. `arg` (a count) is Emacs' numeric argument:
--- the subtree of the ancestor at that level (negative: that many levels
--- up); with "dedicated-frame" it also opens a new tab.
--- `window` ("current", "split", ...) overrides the display (the agenda
--- shows it in its other window).
---@param window? string
---@param arg? integer
function M.tree_to_indirect_buffer(window, arg)
  if arg == nil and window == nil and vim.v.count > 0 then
    arg = vim.v.count
  end
  local bufnr = buf()
  local hl = current_headline()
  if not hl then
    utils.warn("Not in a subtree")
    return
  end
  hl = indirect_headline(hl, arg)
  local display = type(window) == "string" and "window" or config.opts.indirect_buffer_display or "other-window"
  local last = M._last_indirect
  if not (last and vim.api.nvim_buf_is_valid(last)) then
    last = nil
  end
  local last_win = last and vim.fn.bufwinid(last) or -1
  -- org-tree-to-indirect-buffer kills its last indirect buffer
  local replace = last and not arg and display ~= "new-frame" and not vim.bo[last].modified
  local function forget_last()
    if replace and vim.api.nvim_buf_is_valid(last) then
      local ed = require("org.special").edits[last]
      if ed and ed.discard then
        ed.discard()
      else
        pcall(vim.api.nvim_buf_delete, last, { force = true })
      end
    end
  end
  local src_win = vim.api.nvim_get_current_win()
  local res, win
  if display == "window" then
    -- the caller (the agenda) manages the window and the last buffer
    return narrow_headline(bufnr, hl, window)
  elseif display == "current-window" then
    forget_last()
    vim.api.nvim_set_current_win(src_win)
    res, win = narrow_headline(bufnr, hl, "current")
  elseif display == "new-frame" or (display == "dedicated-frame" and arg) then
    forget_last()
    res, win = narrow_headline(bufnr, hl, "tab")
  elseif display == "dedicated-frame" then
    local tab = M._indirect_tab
    if tab and vim.api.nvim_tabpage_is_valid(tab) and tab ~= vim.api.nvim_get_current_tabpage() then
      -- shown in the dedicated tab, in place of the last one there
      vim.api.nvim_set_current_tabpage(tab)
      local here = vim.api.nvim_get_current_buf()
      local keep = vim.bo[here].modified and vim.bo[here].bufhidden == "wipe"
      res, win = narrow_headline(bufnr, hl, keep and "split" or "current")
      -- (replaced in its window, the last one is wiped already)
      forget_last()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
      end
    else
      forget_last()
      vim.api.nvim_set_current_win(src_win)
      res, win = narrow_headline(bufnr, hl, "tab")
      M._indirect_tab = vim.api.nvim_get_current_tabpage()
    end
  else
    -- other-window: in the window of the last one, the cursor staying in
    -- the Org buffer
    local mode = config.opts.win_split_mode
    if mode ~= "split" and mode ~= "vsplit" and mode ~= "tab" then
      mode = "split"
    end
    if replace and last_win ~= -1 and last_win ~= src_win then
      vim.api.nvim_set_current_win(last_win)
      res, win = narrow_headline(bufnr, hl, "current")
    else
      forget_last()
      vim.api.nvim_set_current_win(src_win)
      res, win = narrow_headline(bufnr, hl, mode)
    end
    if mode ~= "tab" and vim.api.nvim_win_is_valid(src_win) then
      vim.api.nvim_set_current_win(src_win)
    end
  end
  M._last_indirect = res
  return res, win
end
