---@mod org.structure.level Promoting and demoting
---
--- Promote/demote a heading, a subtree or a region, cycle the level and
--- drag lines.
---
--- Part of org.structure, which loads it.

local config = require("org.config")
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
local relevel = shared.relevel
local set_lines = shared.set_lines

---------------------------------------------------------------------------
-- Promote / demote
---------------------------------------------------------------------------

local function change_level(hl, file, delta, subtree)
  local bufnr = buf()
  if hl.inlinetask then
    return require("org.inlinetask").change_level(bufnr, hl, delta)
  end
  delta = delta * M.level_increment(bufnr)
  if hl.level + delta < 1 and hl.level == 1 and config.opts.allow_promoting_top_level_subtree then
    -- org-promote turns "* " into "# "; the other headlines of the subtree
    -- are promoted as usual
    local line = get_lines(bufnr, hl.line, hl.line)[1]
    set_lines(bufnr, hl.line, hl.line, { "# " .. line:sub(3) })
    if subtree and hl.end_line > hl.body_end then
      local rest = get_lines(bufnr, hl.body_end + 1, hl.end_line)
      set_lines(bufnr, hl.body_end + 1, hl.end_line, relevel(rest, delta, file.settings.todo))
    end
    return
  end
  if hl.level + delta < 1 then
    utils.warn("Cannot promote to level 0.  UNDO to recover if necessary")
    return
  end
  local s = hl.line
  local e = subtree and hl.end_line or hl.body_end
  local lines = get_lines(bufnr, s, e)
  local new = relevel(lines, delta, file.settings.todo)
  if not subtree then
    -- only the headline (and its own body when adapting indentation)
    for i = 2, #new do
      if parser.headline_level(lines[i]) then
        new[i] = lines[i]
      end
    end
  end
  local pos = cursor()
  set_lines(bufnr, s, e, new)
  local l = vim.api.nvim_buf_get_lines(bufnr, pos[1] - 1, pos[1], false)[1] or ""
  -- keep the cursor on its character: a headline changes by its stars, a
  -- body line by its re-indentation (if any)
  local shift = 0
  if pos[1] >= s and pos[1] <= e then
    local old = lines[pos[1] - s + 1]
    shift = parser.headline_level(old) and delta or #l - #old
  end
  vim.api.nvim_win_set_cursor(0, { pos[1], math.max(0, math.min(pos[2] + shift, #l)) })
end

local function headline_for_level_change()
  local hl, file = current_headline()
  if not hl then
    utils.warn("Not on a headline")
    return nil
  end
  return hl, file
end

function M.promote_heading()
  local hl, file = headline_for_level_change()
  if hl then
    change_level(hl, file, -1, false)
  end
end

function M.demote_heading()
  local hl, file = headline_for_level_change()
  if hl then
    change_level(hl, file, 1, false)
  end
end

function M.promote_subtree()
  local hl, file = headline_for_level_change()
  if hl then
    for _ = 1, math.max(vim.v.count, 1) do
      local was_top = hl.level == 1
      change_level(hl, file, -1, true)
      hl, file = current_headline()
      if was_top or not hl or hl.level == 1 then
        break
      end
    end
  end
end

function M.demote_subtree()
  local hl, file = headline_for_level_change()
  if hl then
    for _ = 1, math.max(vim.v.count, 1) do
      change_level(hl, file, 1, true)
      hl, file = current_headline()
    end
  end
end

--- Promote (delta < 0) or demote (delta > 0) every headline in the
--- Visual selection (org-metaleft / org-metaright with an active region).
--- Returns false when the selection contains no headline.
function M.change_level_region(delta)
  local bufnr = buf()
  delta = delta * M.level_increment(bufnr)
  local s, _, e = utils.visual_range()
  exit_visual()
  local file = files.get_buffer(bufnr)
  local heads = {}
  for _, hl in ipairs(file.headlines) do
    if hl.line >= s and hl.line <= e then
      heads[#heads + 1] = hl
    end
  end
  if #heads == 0 then
    return false
  end
  local allow = config.opts.allow_promoting_top_level_subtree
  for _, hl in ipairs(heads) do
    if hl.level + delta < 1 and not (allow and hl.level == 1) then
      utils.warn("Cannot promote to level 0.  UNDO to recover if necessary")
      return
    end
  end
  -- bottom-up so body re-indentation keeps line numbers valid
  for i = #heads, 1, -1 do
    local hl = heads[i]
    local lines = get_lines(bufnr, hl.line, hl.body_end)
    local new = relevel(lines, delta, file.settings.todo)
    if hl.level + delta < 1 then
      -- allow_promoting_top_level_subtree: "* " becomes "# "
      new = vim.deepcopy(lines)
      new[1] = "# " .. lines[1]:sub(3)
    end
    for j = 2, #new do
      if parser.headline_level(lines[j]) then
        new[j] = lines[j]
      end
    end
    set_lines(bufnr, hl.line, hl.body_end, new)
  end
end

--- On an empty headline (only stars and maybe a TODO keyword), cycle its
--- level: child of the previous entry, then up the hierarchy, then back
--- (org-cycle-level, used by TAB right after M-RET). Returns false when
--- the headline is not empty.
function M.cycle_level()
  local bufnr = buf()
  local lnum = cursor()[1]
  local line = vim.api.nvim_get_current_line()
  local file = files.get_buffer(bufnr)
  local p = parser.parse_headline_line(line, file.settings.todo)
  if not p or vim.trim(p.title) ~= "" or p.priority or #p.tags > 0 then
    return false
  end
  local cur = p.level
  local prev_hl = lnum > 1 and file:headline_at(lnum - 1) or nil
  local prev = prev_hl and prev_hl.level or 0
  -- the steps of org-do-promote / org-do-demote (org-level-increment)
  local inc = M.level_increment(bufnr)
  local new
  if prev == 0 then
    new = cur - inc * math.floor((cur - 1) / inc) -- first headline of the file
  elseif prev == cur then
    new = cur + inc -- sibling -> child
  elseif prev == 1 then
    new = cur - inc * math.floor((cur - 1) / inc) -- the parent is top-level
  elseif cur == 1 then
    new = 1 + inc * math.floor((prev - 1) / inc) -- back to the sibling level
  elseif cur < prev then
    new = cur - inc
  else
    -- promote until higher than the previous level
    new = cur - inc * (1 + math.floor((cur - prev) / inc))
  end
  local rest = line:sub(#line:match("^%*+") + 1)
  local text = string.rep("*", math.max(new, 1)) .. rest
  vim.api.nvim_set_current_line(text)
  vim.api.nvim_win_set_cursor(0, { lnum, #text })
end

--- Drag the line at the cursor up (dir = -1) or down (dir = 1), count
--- times (org-drag-line-backward / org-drag-line-forward, M-S-Up/Down).
function M.drag_line(dir)
  local bufnr = buf()
  local pos = cursor()
  local n = math.max(vim.v.count, 1)
  local target = pos[1] + dir * n
  if target < 1 or target > vim.api.nvim_buf_line_count(bufnr) then
    utils.warn("Cannot move line " .. (dir < 0 and "up" or "down"))
    return
  end
  local line = get_lines(bufnr, pos[1], pos[1])[1]
  set_lines(bufnr, pos[1], pos[1], {})
  set_lines(bufnr, target, target - 1, { line })
  vim.api.nvim_win_set_cursor(0, { target, pos[2] })
end
