---@mod org.agenda.view.show The entry at the cursor: showing and visiting it
---
--- Part of org.agenda.view, which loads it.

local config = require("org.config")
local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.agenda.view.shared")

local M = require("org.agenda.view")

---------------------------------------------------------------------------
-- Items at cursor & targets
---------------------------------------------------------------------------

function M.item_at_cursor()
  if not M.state.buf or vim.api.nvim_get_current_buf() ~= M.state.buf then
    if M.state.win and vim.api.nvim_win_is_valid(M.state.win) then
      return M.state.line_items[vim.api.nvim_win_get_cursor(M.state.win)[1]]
    end
    return nil
  end
  return M.state.line_items[vim.api.nvim_win_get_cursor(0)[1]]
end

--- Buffer + headline line for an item, loading the file if needed.
---@return org.Target|nil
function M.resolve_target(item)
  local bufnr
  if item.type == "diary" and not item.filename then
    -- a holiday line of the diary (org-agenda-error)
    utils.error("Command not allowed in this line")
    return nil
  end
  if item.filename then
    bufnr = utils.find_buffer(item.filename)
    if not bufnr then
      bufnr = utils.load_buffer(item.filename)
      M.state.new_buffers[bufnr] = true
    end
  elseif item.bufnr and vim.api.nvim_buf_is_valid(item.bufnr) then
    bufnr = item.bufnr
  end
  if not bufnr then
    utils.error("Cannot find the file of this entry")
    return nil
  end
  local lnum = M.locate_line(bufnr, item)
  if not lnum then
    utils.warn("Entry has changed or moved; press r to refresh the agenda")
    return nil
  end
  return { bufnr = bufnr, lnum = lnum }
end

--- The current line of an item's entry in `bufnr` (Emacs keeps a marker):
--- its line when the buffer is unchanged since the agenda was built, else
--- the line with the same text, the n-th of n identical ones when it was
--- the n-th before, otherwise the one nearest its old line.
---@return integer|nil
function M.locate_line(bufnr, item)
  local lnum, raw = item.lnum, item.raw
  local old = item.headline and item.headline.file
  if old and files.cached_buffer(bufnr) == old then
    return lnum
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local found = {}
  for i, l in ipairs(lines) do
    if l == raw then
      found[#found + 1] = i
    end
  end
  if #found <= 1 then
    return found[1]
  end
  if old and old.lines[lnum] == raw then
    local k, total = 0, 0
    for i, l in ipairs(old.lines) do
      if l == raw then
        total = total + 1
        if i <= lnum then
          k = total
        end
      end
    end
    if total == #found then
      return found[k]
    end
  end
  local best = found[1]
  for _, i in ipairs(found) do
    if math.abs(i - lnum) < math.abs(best - lnum) then
      best = i
    end
  end
  return best
end

local function other_window()
  local cur = M.state.win and vim.api.nvim_win_is_valid(M.state.win) and M.state.win or vim.api.nvim_get_current_win()
  if M.state.prev_win and M.state.prev_win ~= cur and vim.api.nvim_win_is_valid(M.state.prev_win) then
    local cfg = vim.api.nvim_win_get_config(M.state.prev_win)
    if cfg.relative == "" then
      return M.state.prev_win
    end
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= cur and vim.api.nvim_win_get_config(w).relative == "" then
      return w
    end
  end
  -- create one
  local w
  vim.api.nvim_win_call(cur, function()
    vim.cmd("rightbelow vsplit")
    w = vim.api.nvim_get_current_win()
  end)
  vim.api.nvim_set_current_win(cur)
  return w
end

--- Show the target of `item` in `win`; returns the window it shows in
--- (a split of `win` when its buffer can't be abandoned).
local function open_in_window(win, target, item)
  local shown = win
  vim.api.nvim_win_call(win, function()
    if item.filename then
      -- no zv: it would show every sibling of the ancestors
      utils.open_file(item.filename, target.lnum, { reveal = false })
    else
      utils.set_current_buf(target.bufnr)
      vim.api.nvim_win_set_cursor(0, { target.lnum, 0 })
    end
    require("org.fold").reveal_cursor("agenda")
    shown = vim.api.nvim_get_current_win()
  end)
  return shown
end

--- Show the entry in another window (focus = jump there).
function M.show_item(focus)
  local item = M.item_at_cursor()
  if not item then
    return
  end
  local target = M.resolve_target(item)
  if not target then
    return
  end
  local is_float = M.state.win
    and vim.api.nvim_win_is_valid(M.state.win)
    and vim.api.nvim_win_get_config(M.state.win).relative ~= ""
  if is_float and focus then
    M.quit(false)
    local w = vim.api.nvim_get_current_win()
    open_in_window(w, target, item)
    return
  end
  -- a window already showing the file is reused (display-buffer)
  local w
  for _, win in ipairs(vim.fn.win_findbuf(target.bufnr)) do
    if
      win ~= M.state.win
      and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
      and vim.api.nvim_win_get_config(win).relative == ""
    then
      w = win
      break
    end
  end
  w = open_in_window(w or other_window(), target, item)
  if focus then
    vim.api.nvim_set_current_win(w)
  end
  return w
end

--- Show the subtree of the entry at point in an edit buffer in the other
--- window (org-agenda-tree-to-indirect-buffer, C-c C-x b). The previous
--- one is closed unless it has unsaved changes, like Emacs kills its last
--- indirect buffer. `arg` (a count) is Emacs' numeric argument: the
--- subtree of the ancestor at that level (negative: that many levels up);
--- the previous buffer is then kept.
---@param arg? integer
---@return integer? buf
function M.tree_to_indirect_buffer(arg)
  local item = M.item_at_cursor()
  if not item then
    utils.warn("No agenda entry on this line")
    return nil
  end
  if item.type == "diary" or not item.headline then
    utils.error("Command not allowed in this line")
    return nil
  end
  local target = M.resolve_target(item)
  if not target then
    return nil
  end
  local old = M.state.indirect_buf
  local w = other_window()
  local buf
  vim.api.nvim_win_call(w, function()
    utils.set_current_buf(target.bufnr)
    vim.api.nvim_win_set_cursor(0, { target.lnum, 0 })
    buf = require("org.structure").tree_to_indirect_buffer("current", arg)
  end)
  if not arg and old and old ~= buf and vim.api.nvim_buf_is_valid(old) and not vim.bo[old].modified then
    pcall(vim.api.nvim_buf_delete, old, { force = true })
  end
  M.state.indirect_buf = buf
  return buf
end

--- Move the cursor to the agenda line under the mouse (mouse-set-point);
--- false when the click was outside the agenda window.
function M.mouse_set_point()
  local pos = vim.fn.getmousepos()
  if not (M.state.win and pos.winid == M.state.win and pos.line > 0) then
    return false
  end
  vim.api.nvim_set_current_win(M.state.win)
  pcall(vim.api.nvim_win_set_cursor, M.state.win, { pos.line, math.max(pos.column - 1, 0) })
  return true
end

--- The window of the last `show` (org-agenda-show-window).
M.show_window = nil

--- Scroll `win` a page: `dir` > 0 forward (scroll-up), < 0 back.
local function scroll_page(win, dir)
  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd("normal! " .. (dir > 0 and "\6" or "\2"))
  end)
end

--- Show the entry at point in the other window, its drawers open; pressed
--- again right after, scroll that window a page forward
--- (org-agenda-show-and-scroll-up, <Space>). With `fold_drawers` (a
--- count, Emacs C-u) the drawers stay folded.
---@param fold_drawers? boolean
function M.show_and_scroll_up(fold_drawers)
  local sw = M.show_window
  if sw and vim.api.nvim_win_is_valid(sw) and M.last_command == "show" then
    scroll_page(sw, 1)
    return sw
  end
  local w = M.show_item(false)
  if w then
    local item = M.item_at_cursor()
    local hl = item and item.headline
    if hl and not fold_drawers then
      -- org-fold-show-entry, then all drawers of the entry
      pcall(vim.api.nvim_win_call, w, function()
        local last = hl.children[1] and (hl.children[1].line - 1) or hl.end_line
        vim.cmd(string.format("silent! %d,%dfoldopen!", hl.line, math.max(hl.line, last)))
      end)
    end
    M.show_window = w
  end
  return w
end

--- Scroll the window of the last `show` back a page
--- (org-agenda-show-scroll-down, <BS>).
function M.show_scroll_down()
  local sw = M.show_window
  if sw and vim.api.nvim_win_is_valid(sw) then
    scroll_page(sw, -1)
  end
end

--- Show the entry at point in the other window with `level` of detail
--- (org-agenda-show-1): 0 folds the subtree, 1 shows the entry, 2 its
--- children, 3 its subtree, 4 its subtree and drawers. `verbose` echoes
--- the "Remote: ..." message of level 1 too.
---@param level integer
---@param verbose? boolean
function M.show_1(level, verbose)
  local w = M.show_item(false)
  local item = M.item_at_cursor()
  local hl = item and item.headline
  if not (w and hl) then
    return nil
  end
  local target = M.resolve_target(item)
  local msg
  vim.api.nvim_win_call(w, function()
    local file = files.get_buffer(target.bufnr)
    hl = file:headline_at(target.lnum) or hl
    vim.api.nvim_win_set_cursor(w, { hl.line, 0 })
    vim.cmd("normal! zt")
    if level ~= 1 then
      require("org.fold").show_level(hl.line, level)
    end
    if level == 0 then
      msg = "Remote: FOLDED"
    elseif level == 1 then
      msg = verbose and "Remote: show with default settings" or nil
    elseif level == 2 then
      msg = "Remote: CHILDREN"
    elseif level == 3 then
      msg = "Remote: SUBTREE"
    else
      msg = "Remote: SUBTREE AND ALL DRAWERS"
    end
  end)
  if msg then
    utils.notify(msg)
  end
  return msg
end

--- Visibility level of the last cycle_show.
M.cycle_counter = nil

--- Show the entry at point; pressed again right after, cycle its
--- visibility: children, subtree, folded (org-agenda-cycle-show). A count
--- is passed to `show_1` as the level.
---@param n? integer
function M.cycle_show(n)
  if n then
    M.cycle_counter = n
  elseif M.last_command ~= "cycle_show" then
    M.cycle_counter = 1
  elseif M.cycle_counter == 0 then
    M.cycle_counter = 2
  else
    M.cycle_counter = (M.cycle_counter or 0) + 1
    if M.cycle_counter > 3 then
      M.cycle_counter = 0
    end
  end
  return M.show_1(M.cycle_counter)
end

--- What follow mode shows for the entry at point: the entry, or its
--- subtree in an edit buffer with `agenda.follow_indirect`
--- (org-agenda-follow-indirect).
function M.follow_show()
  if config.opts.agenda.follow_indirect then
    local item = M.item_at_cursor()
    if item and item.headline and item.type ~= "diary" then
      return M.tree_to_indirect_buffer()
    end
    return nil
  end
  return M.show_item(false)
end

--- Open the entry in the agenda window itself (RET).
function M.switch_to()
  local item = M.item_at_cursor()
  if not item then
    return
  end
  local target = M.resolve_target(item)
  if not target then
    return
  end
  local is_float = M.state.win
    and vim.api.nvim_win_is_valid(M.state.win)
    and vim.api.nvim_win_get_config(M.state.win).relative ~= ""
  M.state.follow = false
  if is_float then
    M.quit(false)
  end
  open_in_window(vim.api.nvim_get_current_win(), target, item)
end

shared.other_window = other_window
