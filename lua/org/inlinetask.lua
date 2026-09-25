---@mod org.inlinetask Inline tasks (org-inlinetask)
---
--- With `inlinetask_min_level` set (Emacs loads the org-inlinetask module
--- and uses 15), headlines of that level or deeper are inline tasks: TODO
--- items inside the text of an entry, optionally closed by a line of
--- stars followed by END. They do not start a new entry or subtree, fold
--- up to their END line with TAB, and are shown with only their last two
--- stars (the others hidden).
---
--- ```org
--- * Entry
--- Some text.
--- *************** TODO Call Bob
--- Details of the task.
--- *************** END
--- More text of the entry.
--- ```

local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")

local M = {}

--- The minimum inline task level, or nil when inline tasks are off.
function M.min_level()
  return parser.inlinetask_min_level()
end

--- The number of stars of a new inline task.
local function stars_count()
  local min = M.min_level()
  if require("org.structure").odd_levels_only() then
    return 2 * min - 1
  end
  return min
end

--- The inline task containing `lnum`, or nil.
function M.task_at(bufnr, lnum)
  if not M.min_level() then
    return nil
  end
  local hl = files.get_buffer(bufnr or 0):headline_at(lnum)
  if hl and hl.inlinetask and lnum >= hl.line and lnum <= hl.end_line then
    return hl
  end
end

--- Insert an inline task (org-inlinetask-insert-task, C-c C-x t) below the
--- cursor, or around the Visual selection, with `inlinetask_default_state`
--- unless a count is given.
function M.insert()
  if not M.min_level() then
    utils.warn("Inline tasks are off: set inlinetask_min_level (Emacs: 15)")
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local no_state = vim.v.count > 0
  local mode = vim.fn.mode()
  local s, e
  if mode == "v" or mode == "V" or mode == "\22" then
    s, _, e = utils.visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  end
  local lnum = s or vim.api.nvim_win_get_cursor(0)[1]
  local task = M.task_at(bufnr, lnum)
  if task and not (lnum == task.line and not s) then
    utils.warn("Cannot nest inline tasks")
    return
  end
  local stars = string.rep("*", stars_count()) .. " "
  local state = (not no_state) and require("org.config").opts.inlinetask_default_state or nil
  local head = stars .. (state and (state .. " ") or "")
  if s then
    vim.api.nvim_buf_set_lines(bufnr, e, e, false, { stars .. "END" })
    vim.api.nvim_buf_set_lines(bufnr, s - 1, s - 1, false, { head })
    vim.api.nvim_win_set_cursor(0, { s, #head })
  else
    local line = vim.api.nvim_get_current_line()
    local at = line == "" and lnum - 1 or lnum
    local new = { head, stars .. "END" }
    if line == "" then
      vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, new)
    else
      vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, new)
    end
    vim.api.nvim_win_set_cursor(0, { at + 1, #head })
  end
  if vim.fn.mode():sub(1, 1) ~= "i" then
    vim.cmd("startinsert!")
  end
end

--- Promote (-1) or demote (1) the inline task `hl` and its END line
--- (org-inlinetask-promote / org-inlinetask-demote).
function M.change_level(bufnr, hl, delta)
  local min = M.min_level()
  local step = require("org.structure").level_increment(bufnr)
  local new = hl.level + delta * step
  if new < min then
    utils.warn("Cannot promote an inline task at minimum level")
    return
  end
  local function restar(lnum)
    local l = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    local stars = l:match("^%*+")
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { string.rep("*", new) .. l:sub(#stars + 1) })
  end
  restar(hl.line)
  if hl.end_line > hl.line then
    restar(hl.end_line)
  end
end

return M
