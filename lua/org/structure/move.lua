---@mod org.structure.move Moving subtrees and regions
---
--- org-move-subtree-up/down and moving a region of headings.
---
--- Part of org.structure, which loads it.

local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")
local shared = require("org.structure.shared")

local M = require("org.structure")

local buf = shared.buf
local cursor = shared.cursor
local current_headline = shared.current_headline
local exit_visual = shared.exit_visual
local get_lines = shared.get_lines
local insert_lines = shared.insert_lines
local is_blank = shared.is_blank
local set_lines = shared.set_lines
local sibling_index = shared.sibling_index
local siblings = shared.siblings

---------------------------------------------------------------------------
-- Moving subtrees
---------------------------------------------------------------------------

--- Move the subtree of `hl` in `bufnr` past `n` siblings, down (`dir` 1)
--- or up (-1). Returns the line it starts on now, or nil (with a warning)
--- when it can't move.
---@param bufnr integer
---@param hl org.Headline
---@param dir integer
---@param n integer
---@return integer|nil
local function move_headline(bufnr, hl, dir, n)
  local sibs = siblings(hl)
  local idx = sibling_index(hl)
  -- the sibling to move past, n times, as org-get-next-sibling /
  -- org-get-previous-sibling find it: deeper headlines (entries before the
  -- first headline of a lower level, as "** a" then "* b") are skipped, a
  -- lower level stops; going up, deeper headlines from the top of the
  -- buffer count as one entry starting there
  local i, up_to = idx, nil
  for _ = 1, n do
    local j = i + dir
    while sibs[j] and sibs[j].level > hl.level do
      j = j + dir
    end
    if sibs[j] and sibs[j].level == hl.level then
      i = j
    elseif
      dir < 0
      and not sibs[j]
      and not hl.parent
      and hl.line > 1
      and parser.headline_level(get_lines(bufnr, 1, 1)[1] or "")
    then
      up_to = 1
      break
    else
      utils.warn("Cannot move past superior level or buffer limit")
      return nil
    end
  end
  local text = get_lines(bufnr, hl.line, hl.end_line)
  if dir > 0 then
    local other = sibs[i]
    -- insert after the other subtree, then delete the original
    insert_lines(bufnr, other.end_line + 1, text)
    set_lines(bufnr, hl.line, hl.end_line, {})
    return other.end_line + 1 - #text
  end
  local to = up_to or sibs[i].line
  set_lines(bufnr, hl.line, hl.end_line, {})
  insert_lines(bufnr, to, text)
  return to
end

local function move_subtree(dir, n)
  local bufnr = buf()
  n = n or math.max(vim.v.count, 1)
  local hl = current_headline()
  if not hl then
    utils.warn("Not on a headline")
    return
  end
  local folded = vim.fn.foldclosed(hl.line) == hl.line
  local pos = cursor()
  local offset = pos[1] - hl.line
  local new_start = move_headline(bufnr, hl, dir, n)
  if not new_start then
    return
  end
  vim.api.nvim_win_set_cursor(0, { new_start + offset, pos[2] })
  -- keep the moved subtree folded or open, like Emacs, without resetting
  -- the folds of the rest of the buffer (zx would)
  if folded then
    pcall(vim.api.nvim_command, new_start .. "foldclose")
  else
    pcall(vim.api.nvim_command, new_start .. "foldopen")
    vim.cmd("silent! normal! zv")
  end
end

function M.move_subtree_up()
  move_subtree(-1)
end

function M.move_subtree_down()
  move_subtree(1)
end

--- Move the subtree of the headline at `target` past `n` (default 1)
--- siblings, down (`dir` 1) or up (-1), like M-down / M-up with a count,
--- without moving a cursor. Returns the line it starts on now, or nil
--- (with a warning) when it can't move.
---@param target { bufnr: integer, lnum: integer }
---@param dir integer
---@param n? integer
---@return integer|nil
function M.move_subtree_at(target, dir, n)
  local hl = files.get_buffer(target.bufnr):headline_at(target.lnum)
  if not hl then
    utils.warn("Not on a headline")
    return nil
  end
  return move_headline(target.bufnr, hl, dir, math.max(1, n or 1))
end

--- M-up / M-down with a Visual selection (org-metaup / org-metadown with
--- a region): when it starts at a headline, move the selected subtrees
--- past the previous / next sibling; otherwise move the selected lines up
--- or down one line. The selection follows.
function M.move_region(dir)
  local bufnr = buf()
  local s, _, e = utils.visual_range()
  exit_visual()
  local file = files.get_buffer(bufnr)
  local first = s
  while first < e and is_blank(get_lines(bufnr, first, first)[1]) do
    first = first + 1
  end
  local hl = file:headline_on(first)
  local n = vim.api.nvim_buf_line_count(bufnr)
  if hl then
    local level = hl.level
    for l = first + 1, e do
      local lv = parser.headline_level(get_lines(bufnr, l, l)[1])
      if lv and lv < level then
        utils.warn("Cannot move past superior level or buffer limit")
        return
      end
    end
    local sibs = siblings(hl)
    local idx = sibling_index(hl)
    if dir < 0 then
      local prev = sibs[idx - 1]
      if not prev then
        utils.warn("Cannot move past superior level or buffer limit")
        return
      end
      -- the previous sibling goes below the selected subtrees
      local last_sel = hl
      for i = idx, #sibs do
        if sibs[i].line <= e then
          last_sel = sibs[i]
        end
      end
      local text = get_lines(bufnr, prev.line, prev.end_line)
      set_lines(bufnr, last_sel.end_line + 1, last_sel.end_line, text)
      set_lines(bufnr, prev.line, prev.end_line, {})
      local size = last_sel.end_line - hl.line + 1
      s, e = prev.line, prev.line + size - 1
    else
      local last_sel = hl
      for i = idx, #sibs do
        if sibs[i].line <= e then
          last_sel = sibs[i]
        end
      end
      local nxt = sibs[sibling_index(last_sel) + 1]
      if not nxt then
        utils.warn("Cannot move past superior level or buffer limit")
        return
      end
      local text = get_lines(bufnr, nxt.line, nxt.end_line)
      set_lines(bufnr, nxt.line, nxt.end_line, {})
      set_lines(bufnr, hl.line, hl.line - 1, text)
      local size = last_sel.end_line - hl.line + 1
      s, e = hl.line + #text, hl.line + #text + size - 1
    end
  else
    if (dir < 0 and s <= 1) or (dir > 0 and e >= n) then
      utils.warn("Cannot move " .. (dir < 0 and "up" or "down"))
      return
    end
    local lines = get_lines(bufnr, s, e)
    if dir < 0 then
      local above = get_lines(bufnr, s - 1, s - 1)
      set_lines(bufnr, s - 1, e, vim.list_extend(lines, above))
      s, e = s - 1, e - 1
    else
      local below = get_lines(bufnr, e + 1, e + 1)
      set_lines(bufnr, s, e + 1, vim.list_extend(below, lines))
      s, e = s + 1, e + 1
    end
  end
  vim.api.nvim_win_set_cursor(0, { s, 0 })
  -- the selection follows unless `edit_keep_region` says otherwise
  if require("org.context").keep_region(dir < 0 and "meta_up" or "meta_down") then
    vim.cmd("normal! V")
    vim.api.nvim_win_set_cursor(0, { e, 0 })
  end
end
