---@mod org.lists.motion Item motions
---
--- Beginning / end of item and list, cycling the indentation of an
--- empty item, next / previous item.
--- Part of org.lists, which loads it.

local parser = require("org.parser")
local utils = require("org.utils")
local shared = require("org.lists.shared")

local M = require("org.lists")

local cursor_lnum = shared.cursor_lnum
local get_lines = shared.get_lines
local is_blank = shared.is_blank
local protected = shared.protected
local set_lines = shared.set_lines
local user_error = shared.user_error

--- Line where `item` ends (org-list-get-item-end): the next item of its
--- list structure after the blank lines following it, or the line after
--- its last line.
local function item_end_line(bufnr, item)
  local struct = M.struct_at(bufnr, item.lnum)
  local n = vim.api.nvim_buf_line_count(bufnr)
  local l = item.end_lnum + 1
  while l <= n and l <= struct.last and is_blank(get_lines(bufnr, l, l)[1]) do
    l = l + 1
  end
  if l <= struct.last then
    return l
  end
  return item.end_lnum + 1
end

--- Put the cursor at the start of line `lnum`, or at the end of the
--- buffer past its last line.
local function goto_line_start(bufnr, lnum)
  local n = vim.api.nvim_buf_line_count(bufnr)
  if lnum > n then
    local last = get_lines(bufnr, n, n)[1]
    vim.api.nvim_win_set_cursor(0, { n, math.max(0, #last) })
  else
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  end
end

--- The item containing the cursor, or an error "Not in an item".
local function current_item(bufnr)
  local item = M.item_at(bufnr, cursor_lnum())
  if not item then
    utils.error("Not in an item")
  end
  return item
end

--- org-beginning-of-item: the start of the item containing the cursor.
function M.beginning_of_item()
  local bufnr = vim.api.nvim_get_current_buf()
  local item = current_item(bufnr)
  if item then
    goto_line_start(bufnr, item.lnum)
  end
end

--- org-end-of-item: the end of the item containing the cursor.
function M.end_of_item()
  local bufnr = vim.api.nvim_get_current_buf()
  local item = current_item(bufnr)
  if item then
    goto_line_start(bufnr, item_end_line(bufnr, item))
  end
end

--- org-beginning-of-item-list: the first item of the current (sub-)list.
function M.beginning_of_item_list()
  local bufnr = vim.api.nvim_get_current_buf()
  local item = current_item(bufnr)
  if item then
    goto_line_start(bufnr, M.siblings(item)[1].lnum)
  end
end

--- org-end-of-item-list: the end of the current (sub-)list.
function M.end_of_item_list()
  local bufnr = vim.api.nvim_get_current_buf()
  local item = current_item(bufnr)
  if item then
    local sibs = M.siblings(item)
    goto_line_start(bufnr, item_end_line(bufnr, sibs[#sibs]))
  end
end

--- On an empty item (only a bullet, maybe a checkbox), cycle its
--- indentation (org-cycle-item-indentation, TAB right after M-RET): the
--- first TAB makes it a child of the previous item, the next ones outdent
--- it level by level, then it returns to where it started. Returns false
--- when the item is not empty.
function M.cycle_item_indentation()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cursor_lnum()
  local line = vim.api.nvim_get_current_line()
  local parsed = M.parse_item_line(line)
  local state = vim.b[bufnr].org_tab_ind_state
  local continuing = state and state.lnum == lnum and state.tick == vim.api.nvim_buf_get_changedtick(bufnr)
  if not continuing then
    if not parsed or vim.trim(parsed.text) ~= "" or parser.headline_level(line) then
      return false
    end
  end
  local item = M.item_at(bufnr, lnum)
  if not item or item.lnum ~= lnum or (not continuing and #item.children > 0) then
    return false
  end
  local function sib_info(it)
    local sibs = M.siblings(it)
    local prev, nxt
    for i, s in ipairs(sibs) do
      if s == it then
        prev, nxt = sibs[i - 1], sibs[i + 1]
      end
    end
    return prev, nxt
  end
  local function allow_outdent(it)
    local _, nxt = sib_info(it)
    return not nxt and #it.children == 0 and it.parent ~= nil
  end
  local function finish()
    local new = vim.api.nvim_get_current_line()
    vim.api.nvim_win_set_cursor(0, { lnum, #new })
  end
  local ok = protected(function()
    if continuing then
      local ind = item.indent
      local prev = sib_info(item)
      if ind > state.ind and prev then
        M.indent_item(1, false)
      elseif ind < state.ind and allow_outdent(item) then
        M.indent_item(-1, false)
      else
        set_lines(bufnr, lnum, lnum, { string.rep(" ", state.ind) .. state.bul .. " " })
        local restored = M.item_at(bufnr, lnum)
        if ind > state.ind and restored and allow_outdent(restored) then
          M.indent_item(-1, false)
        else
          M.repair(bufnr, lnum)
          vim.b[bufnr].org_tab_ind_state = nil
          finish()
          return true
        end
      end
    else
      local prev, nxt = sib_info(item)
      vim.b[bufnr].org_tab_ind_state = { ind = item.indent, bul = vim.trim(line) }
      state = vim.b[bufnr].org_tab_ind_state
      if prev then
        M.indent_item(1, false)
      elseif not nxt and item.parent then
        M.indent_item(-1, false)
      else
        vim.b[bufnr].org_tab_ind_state = nil
        user_error("Cannot move item")
      end
    end
    finish()
    local st = vim.b[bufnr].org_tab_ind_state
    if st then
      st.lnum = lnum
      st.tick = vim.api.nvim_buf_get_changedtick(bufnr)
      vim.b[bufnr].org_tab_ind_state = st
    end
    return true
  end)
  return ok ~= nil and true or nil
end

function M.next_item()
  return M.goto_sibling_item(1)
end

function M.prev_item()
  return M.goto_sibling_item(-1)
end
