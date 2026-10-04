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

local function move_subtree(dir, n)
  local bufnr = buf()
  n = n or math.max(vim.v.count, 1)
  local hl = current_headline()
  if not hl then
    utils.warn("Not on a headline")
    return
  end
  local sibs = siblings(hl)
  local idx = sibling_index(hl)
  if not sibs[idx + dir * n] then
    utils.warn("Cannot move past superior level or buffer limit")
    return
  end
  local folded = vim.fn.foldclosed(hl.line) == hl.line
  local pos = cursor()
  local offset = pos[1] - hl.line
  local text = get_lines(bufnr, hl.line, hl.end_line)
  local new_start
  if dir > 0 then
    local other = sibs[idx + n]
    -- insert after the other subtree, then delete the original
    insert_lines(bufnr, other.end_line + 1, text)
    set_lines(bufnr, hl.line, hl.end_line, {})
    new_start = other.end_line + 1 - #text
  else
    local other = sibs[idx - n]
    set_lines(bufnr, hl.line, hl.end_line, {})
    insert_lines(bufnr, other.line, text)
    new_start = other.line
  end
  vim.api.nvim_win_set_cursor(0, { new_start + offset, pos[2] })
  -- keep the moved subtree folded or open, like Emacs, without resetting
  -- the folds of the rest of the buffer (zx would)
  if folded then
    pcall(vim.cmd, new_start .. "foldclose")
  else
    pcall(vim.cmd, new_start .. "foldopen")
    vim.cmd("silent! normal! zv")
  end
end

function M.move_subtree_up()
  move_subtree(-1)
end

function M.move_subtree_down()
  move_subtree(1)
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
