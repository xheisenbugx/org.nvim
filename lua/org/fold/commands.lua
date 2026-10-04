---@mod org.fold.commands Subtree visibility commands
---
--- show_branches, show_children, hide_entry, hide_block_all,
--- hide_drawer_all, show_context / reveal (org-fold-show-context,
--- org-reveal) and copy_visible.
---
--- Part of org.fold, which loads it.

local config = require("org.config")
local shared = require("org.fold.shared")

local M = require("org.fold")

local close_at = shared.close_at
local close_blocks = shared.close_blocks
local close_drawers = shared.close_drawers
local file = shared.file
local has_fold = shared.has_fold
local hide_archived = shared.hide_archived
local hide_entry = shared.hide_entry
local lnum_closed = shared.lnum_closed
local open_hidden = shared.open_hidden
local open_outline = shared.open_outline
local refresh_ellipsis = shared.refresh_ellipsis
local show_entry = shared.show_entry
local show_heading_path = shared.show_heading_path

---------------------------------------------------------------------------
-- Subtree visibility commands
---------------------------------------------------------------------------

--- Headline at the cursor (the one whose section contains it).
local function headline_at_cursor()
  return file():headline_at(vim.api.nvim_win_get_cursor(0)[1])
end

--- Hide the subtree of `hl` (org-fold-hide-subtree), then show its
--- headlines down to `depth` levels below it (org-fold-show-children):
--- their text and that of `hl` stay hidden.
local function show_descendants(hl, depth)
  show_heading_path(hl)
  if #hl.children == 0 then
    if has_fold(hl) then
      close_at(hl.line)
    end
    refresh_ellipsis()
    return
  end
  if lnum_closed(hl.line) then
    open_hidden(hl)
  else
    hide_entry(hl)
  end
  local function walk(h, rel)
    for _, ch in ipairs(h.children) do
      M.unconceal(0, ch.line, ch.line)
      if rel + 1 < depth and #ch.children > 0 then
        if lnum_closed(ch.line) then
          open_hidden(ch)
        else
          hide_entry(ch)
        end
        walk(ch, rel + 1)
      elseif has_fold(ch) then
        close_at(ch.line)
      end
    end
  end
  walk(hl, 0)
  refresh_ellipsis()
end

--- Show all headlines of the current subtree, without their text, and
--- fold its archived subtrees (org-kill-note-or-show-branches outside
--- capture).
function M.show_branches()
  local hl = headline_at_cursor()
  if not hl then
    return false
  end
  show_descendants(hl, math.huge)
  hide_archived(hl.line, hl.end_line, true)
  refresh_ellipsis()
end

--- Show the direct children of the current headline, folded, its text
--- hidden (org-ctrl-c-tab outside tables). With a count N, show N levels.
function M.show_children()
  local hl = headline_at_cursor()
  if not hl then
    return false
  end
  show_descendants(hl, math.max(vim.v.count, 1))
end

--- Hide the text of the entry at the cursor; its child headlines stay as
--- they are (org-fold-hide-entry).
function M.hide_entry()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local f = file()
  local hl = f:headline_at(lnum)
  if not hl then
    -- before the first headline: the text above it
    local first = f.headlines[1]
    if first and first.line > 1 and M.conceal_supported then
      M.conceal(0, 1, first.line - 1)
      vim.api.nvim_win_set_cursor(0, { first.line, 0 })
    end
    return
  end
  if lnum_closed(hl.line) or hl.body_end <= hl.line then
    -- folded already, or no text
    return
  end
  if #hl.children == 0 then
    close_at(hl.line)
  else
    hide_entry(hl)
  end
  if lnum > hl.line then
    vim.api.nvim_win_set_cursor(0, { hl.line, 0 })
  end
  refresh_ellipsis()
end

--- Fold every block of the buffer (org-fold-hide-block-all).
function M.hide_block_all()
  close_blocks(1, vim.api.nvim_buf_line_count(0))
end

--- Fold every drawer of the buffer, or of the lines of the visual
--- selection (org-fold-hide-drawer-all).
function M.hide_drawer_all()
  local s, e = 1, vim.api.nvim_buf_line_count(0)
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    s, _, e = require("org.utils").visual_range()
    require("org.utils").exit_visual()
  end
  close_drawers(s, e)
end

--- The visibility span shown around a location reached in `context`
--- (org-fold-show-context-detail): "agenda", "org-goto", "occur-tree",
--- "tags-tree", "link-search", "mark-goto", "bookmark-jump", "isearch"
--- or "default".
---@param context? string
---@return string
function M.context_detail(context)
  local opt = config.opts.fold_show_context_detail
  if opt == true then
    return "canonical"
  elseif not opt then
    return "minimal"
  elseif type(opt) == "string" then
    return opt
  end
  return (context and opt[context]) or opt.default or "minimal"
end

--- Show the context of line `lnum` for `context`, as set by
--- `fold_show_context_detail` (org-fold-show-context).
function M.show_context_for(lnum, context)
  M.show_context(lnum, M.context_detail(context))
end

--- Make the cursor line visible after a jump in `context` (see
--- `context_detail`), or open the folds around it (`zv`) in a window that
--- doesn't fold like Org.
function M.reveal_cursor(context)
  local ok = vim.wo.foldexpr == "v:lua.require'org.fold'.foldexpr(v:lnum)"
    and pcall(M.show_context_for, vim.api.nvim_win_get_cursor(0)[1], context)
  if not ok then
    pcall(vim.cmd, "normal! zv")
  end
end

--- Show the context of line `lnum` (org-fold-show-set-visibility):
--- `detail` is "minimal", "local", "ancestors", "ancestors-full",
--- "lineage", "tree" or "canonical" (see org-fold-show-context-detail).
function M.show_context(lnum, detail)
  detail = detail or "ancestors"
  local f = file()
  local hl = f:headline_at(lnum)
  if not hl then
    M.unconceal(0, lnum, lnum)
    return
  end
  local on_heading = hl.line == lnum
  show_heading_path(hl)
  if detail == "ancestors-full" then
    -- the whole subtree
    pcall(vim.cmd, hl.line .. "," .. hl.end_line .. "foldopen!")
    M.unconceal(0, hl.line, hl.end_line)
    close_drawers(hl.line, hl.end_line)
  elseif not on_heading or detail == "local" then
    show_entry(hl)
  end
  if detail == "local" then
    -- and the next headline
    local nxt = f:headline_at(hl.body_end + 1)
    if nxt and nxt.line == hl.body_end + 1 then
      show_heading_path(nxt)
    end
  end
  if detail == "lineage" or detail == "tree" or detail == "canonical" then
    -- the children of every ancestor
    local a = hl.parent
    while a do
      for _, ch in ipairs(a.children) do
        M.unconceal(0, ch.line, ch.line)
      end
      if detail == "canonical" then
        show_entry(a)
        for _, ch in ipairs(a.children) do
          M.unconceal(0, ch.line, ch.line)
        end
      end
      a = a.parent
    end
  end
  if not on_heading and #hl.children > 0 then
    if detail == "lineage" then
      M.unconceal(0, hl.children[1].line, hl.children[1].line)
    elseif detail == "tree" or detail == "canonical" then
      for _, ch in ipairs(hl.children) do
        M.unconceal(0, ch.line, ch.line)
      end
    end
  end
  if vim.fn.foldclosed(lnum) ~= -1 and vim.fn.foldclosed(lnum) ~= lnum then
    local pos = vim.api.nvim_win_get_cursor(0)
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    vim.cmd("normal! zv")
    vim.api.nvim_win_set_cursor(0, pos)
  end
  M.unconceal(0, lnum, lnum)
  refresh_ellipsis()
end

--- Make the context around the cursor visible (org-reveal): the headline
--- path, the siblings at every level and the current entry (lineage).
--- `arg` 4 (C-u) also shows the text of the ancestors (canonical); true
--- or 16 (C-u C-u) shows the parent's whole subtree.
---@param arg? boolean|integer defaults to the count
function M.reveal(arg)
  if arg == nil then
    arg = vim.v.count > 0 and vim.v.count or false
  end
  -- org-crypt puts org-decrypt-entry on org-fold-reveal-start-hook
  require("org.crypt").reveal_hook()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local hl = headline_at_cursor()
  if not hl then
    vim.cmd("normal! zv")
    return
  end
  if arg == true or (type(arg) == "number" and arg >= 16) then
    local top = hl.parent or hl
    show_heading_path(top)
    open_outline(top.line, top.end_line)
    M.unconceal(0, top.line, top.end_line)
    close_drawers(top.line, top.end_line)
    refresh_ellipsis()
    return
  end
  M.show_context(lnum, arg == 4 and "canonical" or "lineage")
end

--- Copy the visible text (closed folds contribute only their first line,
--- hidden lines nothing) of the buffer, or of the lines of the visual
--- selection, into the unnamed and `+` registers (org-copy-visible).
function M.copy_visible()
  local s, e = 1, vim.api.nvim_buf_line_count(0)
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local srow, _, erow = require("org.utils").visual_range()
    s, e = srow, erow
    require("org.utils").exit_visual()
  end
  local out = {}
  local lnum = s
  while lnum <= e do
    local fc = vim.fn.foldclosed(lnum)
    if fc == -1 then
      if not M.is_concealed(0, lnum) then
        out[#out + 1] = vim.fn.getline(lnum)
      end
      lnum = lnum + 1
    else
      if fc == lnum and not M.is_concealed(0, lnum) then
        out[#out + 1] = vim.fn.getline(lnum)
      end
      lnum = vim.fn.foldclosedend(lnum) + 1
    end
  end
  vim.fn.setreg('"', out, "l")
  pcall(vim.fn.setreg, "+", out, "l")
  require("org.utils").notify(string.format("Copied %d visible line(s)", #out))
  return out
end
