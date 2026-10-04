---@mod org.fold.helpers Opening and closing folds in the current window
---
--- Window options, opening and closing folds of headlines, drawers,
--- blocks and items, archived subtrees, showing an entry or the path to
--- a headline, and the startup visibility of a buffer.
---
--- Part of org.fold, which loads it.

local config = require("org.config")
local shared = require("org.fold.shared")

local M = require("org.fold")

local file = shared.file
local regions = shared.regions

---------------------------------------------------------------------------
-- Window helpers
---------------------------------------------------------------------------

local function set_win_opts(win)
  local wo = vim.wo[win][0]
  wo.foldmethod = "expr"
  wo.foldexpr = "v:lua.require'org.fold'.foldexpr(v:lnum)"
  -- empty: the line as drawn open, with an ellipsis mark (see "Ellipsis")
  wo.foldtext = ""
  wo.foldenable = true
  local fc = vim.wo[win].fillchars
  if not fc:find("fold:") then
    wo.fillchars = (fc ~= "" and fc .. "," or "") .. "fold: "
  end
  if M.conceal_supported and vim.wo[win].conceallevel < 2 then
    -- hidden lines need conceallevel >= 2
    wo.conceallevel = 2
  end
end

local function lnum_closed(lnum)
  return vim.fn.foldclosed(lnum) ~= -1
end

--- Close the fold starting at lnum if it is open.
local function close_at(lnum)
  if vim.fn.foldclosed(lnum) == -1 and vim.fn.foldlevel(lnum) > 0 then
    pcall(vim.cmd, lnum .. "foldclose")
  end
end

local function open_at(lnum)
  if vim.fn.foldclosed(lnum) ~= -1 then
    pcall(vim.cmd, lnum .. "foldopen")
  end
end

--- Close drawer folds in [s, e].
local function close_drawers(s, e)
  -- innermost first doesn't matter: drawers don't nest
  for _, r in ipairs(regions(vim.api.nvim_get_current_buf(), s, e)) do
    if r.kind == "drawer" and r.start >= s and r["end"] <= e then
      if vim.fn.foldclosed(r.start) == -1 then
        close_at(r.start)
      end
    end
  end
end

local function has_fold(hl)
  return hl.end_line > hl.line
end

--- Close the block folds (`#+begin_...`) in [s, e] (org-fold-hide-block-all).
local function close_blocks(s, e)
  for _, r in ipairs(regions(vim.api.nvim_get_current_buf(), s, e)) do
    if r.kind == "block" and r.start >= s and r["end"] <= e then
      close_at(r.start)
    end
  end
end

--- Open the folds of lines [s, e] except those of drawers, blocks and
--- `#+RESULTS`, which keep their state: Emacs shows a subtree
--- (org-fold-show-subtree, SUBTREE) by revealing its outline only, so
--- `hideblocks` blocks and folded drawers stay folded.
local function open_outline(s, e)
  local keep = {}
  for _, r in ipairs(regions(vim.api.nvim_get_current_buf(), s, e)) do
    if r.kind == "block" or r.kind == "results" or r.kind == "drawer" then
      keep[r.start] = true
    end
  end
  if next(keep) == nil then
    pcall(vim.cmd, s .. "," .. e .. "foldopen!")
    return
  end
  local l = s
  while l <= e do
    local fc = vim.fn.foldclosed(l)
    if fc == -1 then
      l = l + 1
    elseif keep[fc] then
      l = vim.fn.foldclosedend(l) + 1
    else
      -- one level at a time, so that a closed block inside stays closed
      local tries = 0
      while vim.fn.foldclosed(l) == fc and tries < 100 do
        pcall(vim.cmd, l .. "foldopen")
        tries = tries + 1
      end
      if vim.fn.foldclosed(l) == fc then
        l = vim.fn.foldclosedend(l) + 1
      end
    end
  end
end

--- Open the item folds in [s, e] (the text of an entry shows its lists).
local function open_items(s, e)
  for _, r in ipairs(regions(vim.api.nvim_get_current_buf(), s, e)) do
    if r.kind == "item" and r.start >= s and r.start <= e then
      open_at(r.start)
    end
  end
end

--- The message for a subtree that stays closed because it is archived,
--- naming the key bound to force_cycle_archived as Emacs substitutes
--- \\[org-cycle-force-archived], or the command when no key is bound.
---@return string
local function archived_message()
  local key = require("org.menu").key_for("force_cycle_archived")
  return ("Subtree is archived and stays closed.  Use %s to cycle it anyway."):format(
    key or ":Org force_cycle_archived"
  )
end

--- Re-fold archived subtrees (`:ARCHIVE:` tag) whose headline is in
--- [s, e], so visibility cycling never opens them
--- (org-cycle-hide-archived-subtrees). Returns true when the headline at
--- `s` itself is archived.
local function hide_archived(s, e, always)
  if not always and (config.opts.cycle_open_archived_trees or M._force_archived) then
    return false
  end
  local self_archived = false
  for _, hl in ipairs(file().headlines) do
    -- (the raw line first: reading `tags` parses the headline)
    if
      hl.line >= s
      and hl.line <= e
      and hl.raw:find(":ARCHIVE:", 1, true)
      and vim.tbl_contains(hl.tags, "ARCHIVE")
      and has_fold(hl)
    then
      close_at(hl.line)
      if hl.line == s then
        self_archived = true
      end
    end
  end
  return self_archived
end

local function hide_archived_all()
  hide_archived(1, vim.api.nvim_buf_line_count(0))
end

--- Fold every subtree tagged :ARCHIVE: (org-fold-hide-archived-subtrees),
--- whatever `cycle_open_archived_trees` says.
function M.hide_archived_subtrees()
  hide_archived(1, vim.api.nvim_buf_line_count(0), true)
end

--- Hide the text of an entry (the lines between its headline and its
--- first child) while its fold is open.
local function hide_entry(hl)
  if hl.body_end > hl.line then
    M.conceal(0, hl.line + 1, hl.body_end)
  end
end

--- Show the text of an entry: open its fold if needed (its children
--- stay hidden) and unhide its lines (org-fold-show-entry). Its drawers
--- get folded unless `keep_drawers` (org-fold-show-entry without
--- HIDE-DRAWERS).
---@param keep_drawers? boolean
local function show_entry(hl, keep_drawers)
  if has_fold(hl) and lnum_closed(hl.line) then
    open_at(hl.line)
    for _, ch in ipairs(hl.children) do
      if has_fold(ch) then
        close_at(ch.line)
      end
      M.conceal(0, ch.line, ch.line)
    end
  end
  M.unconceal(0, hl.line + 1, hl.body_end)
  open_items(hl.line + 1, hl.body_end)
  if not keep_drawers then
    close_drawers(hl.line, hl.body_end)
  end
end

--- Open the fold of `hl` whose contents were hidden, keeping them hidden:
--- its text and child headlines get concealed.
local function open_hidden(hl)
  if not has_fold(hl) or not lnum_closed(hl.line) then
    return false
  end
  open_at(hl.line)
  hide_entry(hl)
  for _, ch in ipairs(hl.children) do
    if has_fold(ch) then
      close_at(ch.line)
    end
    M.conceal(0, ch.line, ch.line)
  end
  return true
end

--- Make the headline `hl` visible, opening its ancestors without showing
--- anything else (org-fold-heading on the path).
local function show_heading_path(hl)
  local path = {}
  local h = hl
  while h do
    table.insert(path, 1, h)
    h = h.parent
  end
  for idx, a in ipairs(path) do
    M.unconceal(0, a.line, a.line)
    if idx < #path then
      open_hidden(a)
    end
  end
end

local STARTUP_MODES = {
  "overview",
  "content",
  "showall",
  "showeverything",
  "nofold",
  "fold",
  "show2levels",
  "show3levels",
  "show4levels",
  "show5levels",
}

--- Resolve an on/off `#+STARTUP` word pair against a default.
local function startup_flag(startup, on, off, default)
  if startup[on] then
    return true
  elseif startup[off] then
    return false
  end
  return default
end

--- The startup visibility of a buffer (#+STARTUP or startup_folded) and
--- its #+STARTUP words.
local function startup_mode(bufnr)
  local f = require("org.files").get_buffer(bufnr)
  local startup = f.settings.startup or {}
  local mode = config.opts.startup_folded or "overview"
  for _, k in ipairs(STARTUP_MODES) do
    if startup[k] then
      mode = k
    end
  end
  if mode == "fold" then
    mode = "overview"
  end
  return mode, startup
end

shared.archived_message = archived_message
shared.close_at = close_at
shared.close_blocks = close_blocks
shared.close_drawers = close_drawers
shared.has_fold = has_fold
shared.hide_archived = hide_archived
shared.hide_archived_all = hide_archived_all
shared.hide_entry = hide_entry
shared.lnum_closed = lnum_closed
shared.open_at = open_at
shared.open_hidden = open_hidden
shared.open_items = open_items
shared.open_outline = open_outline
shared.set_win_opts = set_win_opts
shared.show_entry = show_entry
shared.show_heading_path = show_heading_path
shared.startup_flag = startup_flag
shared.startup_mode = startup_mode
