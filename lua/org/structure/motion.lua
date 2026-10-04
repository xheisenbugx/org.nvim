---@mod org.structure.motion Heading motions and text objects
---
--- Next/previous heading and sibling, parent, goto, and the heading and
--- subtree text objects.
---
--- Part of org.structure, which loads it.

local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.structure.shared")

local M = require("org.structure")

local cursor = shared.cursor
local current_headline = shared.current_headline
local exit_visual = shared.exit_visual
local in_visual = shared.in_visual
local sibling_index = shared.sibling_index
local siblings = shared.siblings

---------------------------------------------------------------------------
-- Navigation
---------------------------------------------------------------------------

local function jump(lnum)
  if not lnum then
    return
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
end

local function visible(lnum)
  return require("org.fold").line_visible(lnum)
end

function M.next_heading()
  local file = files.get_buffer(0)
  local lnum = cursor()[1]
  local target
  for _ = 1, math.max(vim.v.count, 1) do
    local found
    for _, h in ipairs(file.headlines) do
      if h.line > lnum and visible(h.line) then
        found = h.line
        break
      end
    end
    if not found then
      break
    end
    target, lnum = found, found
  end
  jump(target)
end

function M.prev_heading()
  local file = files.get_buffer(0)
  local lnum = cursor()[1]
  local target
  for _ = 1, math.max(vim.v.count, 1) do
    local found
    for i = #file.headlines, 1, -1 do
      local h = file.headlines[i]
      if h.line < lnum and visible(h.line) then
        found = h.line
        break
      end
    end
    if not found then
      break
    end
    target, lnum = found, found
  end
  jump(target)
end

local function sibling_jump(dir)
  local target
  -- walk the tree without moving the cursor, so the jump records the
  -- starting position in the jumplist
  local hl = current_headline()
  for _ = 1, math.max(vim.v.count, 1) do
    if not hl then
      break
    end
    local sib = siblings(hl)[sibling_index(hl) + dir]
    if not sib then
      if not target then
        utils.warn("No " .. (dir > 0 and "next" or "previous") .. " sibling")
      end
      break
    end
    target, hl = sib.line, sib
  end
  if target then
    jump(target)
  end
end

function M.next_sibling()
  sibling_jump(1)
end

function M.prev_sibling()
  sibling_jump(-1)
end

function M.goto_parent()
  local hl = current_headline()
  if not hl then
    return
  end
  local target = hl
  for _ = 1, math.max(vim.v.count, 1) do
    target = target.parent or target
  end
  if target == hl then
    utils.warn("Already at top level")
    return
  end
  jump(target.line)
end

--- Pick a headline of the current buffer and jump to it.
function M.goto_heading()
  local file = files.get_buffer(0)
  if #file.headlines == 0 then
    utils.warn("No headlines in buffer")
    return
  end
  local choice = utils.select(file.headlines, {
    prompt = "Go to heading",
    format_item = function(h)
      local path = h:outline_path()
      path[#path + 1] = h:plain_title()
      local prefix = h.todo and (h.todo .. " ") or ""
      return string.rep("*", h.level) .. " " .. prefix .. table.concat(path, " / ")
    end,
  })
  if choice then
    jump(choice.line)
    require("org.fold").reveal_cursor("org-goto")
  end
end

---------------------------------------------------------------------------
-- Text objects
---------------------------------------------------------------------------

local function select_lines(s, e)
  exit_visual()
  vim.api.nvim_win_set_cursor(0, { s, 0 })
  vim.cmd("normal! V")
  vim.api.nvim_win_set_cursor(0, { e, 0 })
end

--- Select the current headline's section. `inner` excludes the headline.
function M.select_heading(inner)
  local hl = current_headline()
  if not hl then
    return
  end
  if inner then
    if hl.body_end <= hl.line then
      return
    end
    select_lines(hl.line + 1, hl.body_end)
  else
    select_lines(hl.line, hl.body_end)
  end
end

--- Visually select the current subtree, linewise (org-mark-subtree). A
--- count selects that many sibling subtrees; in visual mode the selection
--- is extended to the next sibling subtree.
function M.mark_subtree()
  local file = files.get_buffer(0)
  local start, stop
  if in_visual() then
    local srow, _, erow = utils.visual_range()
    local hl = file:headline_at(srow)
    if not hl then
      return false
    end
    local sibs = siblings(hl)
    local last
    for i = sibling_index(hl), #sibs do
      last = sibs[i]
      if sibs[i].end_line > erow then
        break
      end
    end
    start, stop = hl.line, last.end_line
  else
    local hl = file:headline_at(cursor()[1])
    if not hl then
      return false
    end
    local sibs = siblings(hl)
    local idx = sibling_index(hl)
    local last = sibs[math.min(idx + math.max(vim.v.count, 1) - 1, #sibs)] or hl
    start, stop = hl.line, last.end_line
  end
  local fc = vim.fn.foldclosed(start)
  if fc ~= -1 and fc ~= start then
    -- inside a closed ancestor: linewise Visual would grab the whole fold
    vim.api.nvim_win_set_cursor(0, { start, 0 })
    vim.cmd("normal! zv")
  end
  select_lines(start, stop)
end

--- Select the current subtree. `inner` excludes the headline.
function M.select_subtree(inner)
  local hl = current_headline()
  if not hl then
    return
  end
  if inner then
    if hl.end_line <= hl.line then
      return
    end
    select_lines(hl.line + 1, hl.end_line)
  else
    select_lines(hl.line, hl.end_line)
  end
end
