---@mod org.fold.cycle Local visibility cycling (TAB)
---
--- TAB on a headline, plain list item, drawer or block (org-cycle),
--- show_level (org-agenda-show-1) and force_cycle_archived.
---
--- Part of org.fold, which loads it.

local config = require("org.config")
local parser = require("org.parser")
local shared = require("org.fold.shared")

local M = require("org.fold")

local archived_message = shared.archived_message
local close_at = shared.close_at
local close_drawers = shared.close_drawers
local curbuf = shared.curbuf
local file = shared.file
local has_fold = shared.has_fold
local hide_archived = shared.hide_archived
local is_blank = shared.is_blank
local lnum_closed = shared.lnum_closed
local open_at = shared.open_at
local open_items = shared.open_items
local open_outline = shared.open_outline
local record_state = shared.record_state
local refresh_ellipsis = shared.refresh_ellipsis
local regions = shared.regions
local run_cycle_hook = shared.run_cycle_hook
local show_entry = shared.show_entry
local show_heading_path = shared.show_heading_path

---------------------------------------------------------------------------
-- Local cycling
---------------------------------------------------------------------------

--- Show the whole subtree of the ancestor at `level` of the headline at
--- the cursor (org-cycle with a numeric argument).
local function show_ancestor_subtree(level)
  local hl = file():headline_at(vim.api.nvim_win_get_cursor(0)[1])
  if not hl then
    return false
  end
  while hl.parent and hl.level > level do
    hl = hl.parent
  end
  show_heading_path(hl)
  open_outline(hl.line, hl.end_line)
  M.unconceal(0, hl.line, hl.end_line)
  close_drawers(hl.line, hl.end_line)
  hide_archived(hl.line + 1, hl.end_line)
  refresh_ellipsis()
end

--- Change the visibility of the headline at `lnum` in the current window
--- the way org-agenda-show-1 does: 0 folds its subtree (org-fold-subtree),
--- 2 shows its text and child headlines without hiding anything already
--- visible (org-fold-show-entry, org-fold-show-children), 3 its subtree
--- with the drawers folded, 4 everything. Other folds are left alone.
---@param lnum integer
---@param level integer
---@return boolean false when there is no headline at `lnum`
function M.show_level(lnum, level)
  local hl = file():headline_at(lnum)
  if not hl then
    return false
  end
  show_heading_path(hl)
  if level == 0 then
    if has_fold(hl) then
      -- open everything first so that each :foldclose below closes the
      -- fold it names, then close the descendants deepest first: opening
      -- the subtree again later shows its child headlines folded
      pcall(vim.cmd, hl.line .. "," .. hl.end_line .. "foldopen!")
      local desc = {}
      local function walk(h)
        for _, ch in ipairs(h.children) do
          desc[#desc + 1] = ch
          walk(ch)
        end
      end
      walk(hl)
      for i = #desc, 1, -1 do
        if has_fold(desc[i]) then
          close_at(desc[i].line)
        end
      end
      close_at(hl.line)
    end
  elseif level == 2 then
    show_entry(hl)
    for _, ch in ipairs(hl.children) do
      M.unconceal(0, ch.line, ch.line)
    end
    hide_archived(hl.line + 1, hl.end_line)
  elseif level >= 3 then
    pcall(vim.cmd, hl.line .. "," .. hl.end_line .. "foldopen!")
    M.unconceal(0, hl.line, hl.end_line)
    if level == 3 then
      close_drawers(hl.line, hl.end_line)
      hide_archived(hl.line + 1, hl.end_line)
    end
  end
  refresh_ellipsis()
  return true
end

--- Remember the state of the last TAB, like Emacs `last-command`: the
--- next TAB continues the cycle only if nothing happened in between (an
--- edit changes the tick, a cursor motion drops it: see org.fold.setup).
local function set_last_cycle(lnum, status)
  vim.w.org_last_cycle = {
    buf = curbuf(),
    lnum = lnum,
    col = vim.api.nvim_win_get_cursor(0)[2],
    tick = vim.api.nvim_buf_get_changedtick(0),
    status = status,
  }
end

local function last_cycle_status(lnum)
  local s = vim.w.org_last_cycle
  if s and s.buf == curbuf() and s.lnum == lnum and s.tick == vim.api.nvim_buf_get_changedtick(0) then
    return s.status
  end
end

--- Whether everything after line `lnum` up to `last` is hidden (or blank).
local function all_hidden_after(lnum, last)
  if lnum_closed(lnum) then
    return true
  end
  local lines = vim.api.nvim_buf_get_lines(0, lnum, last, false)
  for i, l in ipairs(lines) do
    local n = lnum + i
    if M.line_visible(n) and not is_blank(l) then
      return false
    end
  end
  return true
end

--- TAB on a plain list item (org-cycle-include-plain-lists).
local function cycle_item(lnum, item)
  if item.end_lnum <= item.lnum then
    vim.api.nvim_echo({ { "EMPTY ENTRY" } }, false, {})
    return
  end
  local has_children = #item.children > 0
  local skip = config.opts.cycle_skip_children_state_if_no_children ~= false
  local last = last_cycle_status(lnum)
  local hooks = file():headline_at(lnum) ~= nil
  local function hook(pattern, state)
    if hooks then
      run_cycle_hook(pattern, state, lnum)
    end
  end
  if all_hidden_after(lnum, item.end_lnum) and (has_children or not skip) then
    -- CHILDREN: the item text, its sub-items folded
    hook("OrgCyclePre", "children")
    open_at(lnum)
    M.unconceal(0, lnum + 1, item.end_lnum)
    for _, ch in ipairs(item.children) do
      if ch.end_lnum > ch.lnum then
        close_at(ch.lnum)
      end
    end
    vim.api.nvim_echo({ { "CHILDREN" } }, false, {})
    set_last_cycle(lnum, "children")
    hook("OrgCycle", "children")
  elseif (all_hidden_after(lnum, item.end_lnum) and not has_children) or last == "children" then
    local skipped = all_hidden_after(lnum, item.end_lnum) and not has_children
    hook("OrgCyclePre", "subtree")
    open_outline(lnum, item.end_lnum)
    M.unconceal(0, lnum + 1, item.end_lnum)
    close_drawers(lnum, item.end_lnum)
    vim.api.nvim_echo({ { skipped and "SUBTREE (NO CHILDREN)" or "SUBTREE" } }, false, {})
    set_last_cycle(lnum, "subtree")
    hook("OrgCycle", "subtree")
  else
    hook("OrgCyclePre", "folded")
    close_at(lnum)
    vim.api.nvim_echo({ { "FOLDED" } }, false, {})
    set_last_cycle(lnum, "folded")
    hook("OrgCycle", "folded")
  end
end

--- TAB outside headlines, items, drawers and blocks: indent the line
--- when `cycle_emulate_tab` says so (org-cycle-emulate-tab), else cycle
--- the entry containing the cursor. Returns nil when handled.
local function emulate_tab(lnum, line)
  local mode = config.opts.cycle_emulate_tab
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local emulate
  if mode == true then
    emulate = true
  elseif mode == "white" then
    emulate = is_blank(line)
  elseif mode == "whitestart" then
    emulate = line:sub(1, col):match("^%s*$") ~= nil
  elseif mode == "exc-hl-bol" then
    emulate = true
  else
    emulate = false
  end
  if emulate then
    return require("org.element").indent_line(lnum)
  end
  local hl = file():headline_at(lnum)
  local limit = M.cycle_limit_level()
  while hl and limit and hl.level > limit do
    hl = hl.parent
  end
  if not hl then
    return false
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_win_set_cursor(0, { hl.line, 0 })
  M.cycle()
  if M.line_visible(pos[1]) then
    vim.api.nvim_win_set_cursor(0, pos)
  end
end

--- org-cycle-hook: image previews on TAB (ui.images.cycle_display), then
--- the OrgCycle User autocmd.
local function cycle_hook(state, hl)
  if (config.opts.ui.images or {}).cycle_display then
    local first_child = hl.children[1] and hl.children[1].line or nil
    pcall(require("org.ui.images").cycle_display, state, hl.line, hl.end_line, first_child)
  end
  run_cycle_hook("OrgCycle", state, hl.line)
end

--- The deepest level cycled as a headline (org-cycle-max-level, else one
--- less than the inline task level), in stars; nil = every level.
function M.cycle_limit_level()
  -- odd_levels_only or the buffer's #+STARTUP: odd / oddeven
  local odd = require("org.structure").odd_levels_only()
  local max = config.opts.cycle_max_level
  if max ~= nil and max ~= false then
    if type(max) ~= "number" or max < 1 or max % 1 ~= 0 then
      error("`cycle_max_level' must be a positive integer", 0)
    end
    return odd and 2 * max - 1 or max
  end
  local min_inline = parser.inlinetask_min_level()
  if min_inline then
    max = min_inline - 1
    return odd and 2 * max - 1 or max
  end
end

--- TAB. With a count: 16 restores the startup visibility, 64 shows
--- everything (drawers too), any other N shows the whole subtree of the
--- ancestor at level N (like C-u C-u TAB, C-u C-u C-u TAB and M-N TAB).
function M.cycle()
  if (config.opts.links or {}).tab_follows_link and require("org.links").link_at_cursor() then
    -- org-tab-follows-link: TAB on a link follows it
    return require("org.context").open_at_point()
  end
  local count = vim.v.count
  if count == 16 then
    return M.set_startup_visibility()
  elseif count == 64 then
    return M.show_everything()
  elseif count > 0 then
    return show_ancestor_subtree(count)
  end
  local limit = M.cycle_limit_level()
  local pos = vim.api.nvim_win_get_cursor(0)
  local lnum = pos[1]
  local line = vim.api.nvim_get_current_line()
  local bufnr = vim.api.nvim_get_current_buf()
  local level = parser.headline_level(line)
  if limit and level and level > limit then
    -- deeper headlines are text for cycling (org-cycle-max-level)
    level = nil
  end
  if config.opts.cycle_global_at_bob and lnum == 1 and pos[2] == 0 and not level then
    -- org-cycle-global-at-bob
    return M.global_cycle()
  end
  for _, r in ipairs(regions(bufnr, lnum, lnum)) do
    if r.start == lnum and r.kind ~= "item" then
      if lnum_closed(lnum) then
        open_at(lnum)
      else
        close_at(lnum)
      end
      record_state(bufnr, lnum, lnum_closed(lnum))
      return
    end
  end
  if not level then
    if line:match("^[ \t]*[|+]") and require("org.table.el").at(bufnr, lnum) then
      return require("org.table.el").hint()
    end
    if config.opts.cycle_include_plain_lists ~= false then
      local item = require("org.lists").item_on(bufnr, lnum)
      if item then
        return cycle_item(lnum, item)
      end
    end
    return emulate_tab(lnum, line)
  end
  local f = file()
  local hl = f:headline_on(lnum)
  if not hl then
    return false
  end
  if not has_fold(hl) then
    run_cycle_hook("OrgCyclePre", "empty", lnum)
    vim.api.nvim_echo({ { "EMPTY ENTRY" } }, false, {})
    set_last_cycle(lnum, nil)
    return
  end
  local last = last_cycle_status(lnum)
  local hidden = all_hidden_after(lnum, hl.end_line)
  local children = hl.children
  -- cycle_include_plain_lists = "integrate": list items count as children
  local integrate = config.opts.cycle_include_plain_lists == "integrate"
  local body_lists = integrate and require("org.lists").parse_region(f.lines, hl.line + 1, hl.body_end) or {}
  local has_children = #children > 0 or #body_lists > 0
  if integrate and not has_children then
    for l = hl.line + 1, hl.end_line do
      if require("org.lists").parse_item_line(f.lines[l]) then
        has_children = true
        break
      end
    end
  end
  -- no children: skip the CHILDREN state (org-cycle-skip-children-state-if-no-children)
  local skipped = hidden and not has_children and config.opts.cycle_skip_children_state_if_no_children ~= false
  if hidden and not skipped then
    -- CHILDREN: the entry text and the child headlines, folded
    run_cycle_hook("OrgCyclePre", "children", lnum)
    if limit and hl.level >= limit then
      -- children deeper than cycle_max_level are text: all of it shows
      -- (like Emacs, where they are no headlines for org-fold-show-children)
      open_outline(hl.line, hl.end_line)
      M.unconceal(0, hl.line + 1, hl.end_line)
    else
      open_at(lnum)
      for _, ch in ipairs(children) do
        if has_fold(ch) then
          close_at(ch.line)
        end
      end
      M.unconceal(0, hl.line + 1, hl.end_line)
      open_items(hl.line + 1, hl.body_end)
      -- "integrate": every list shows its top-level items, folded
      for _, list in ipairs(body_lists) do
        for _, it in ipairs(list.items) do
          if it.end_lnum > it.lnum then
            close_at(it.lnum)
          end
        end
      end
      -- drawers stay as they are: Emacs cycling reveals the outline only
    end
    refresh_ellipsis()
    set_last_cycle(lnum, "children")
    cycle_hook("children", hl)
    if hide_archived(hl.line, hl.end_line) then
      vim.api.nvim_echo({ { archived_message() } }, false, {})
      return
    end
    vim.api.nvim_echo({ { "CHILDREN" } }, false, {})
    return
  end
  if skipped or last == "children" then
    -- SUBTREE
    run_cycle_hook("OrgCyclePre", "subtree", lnum)
    open_outline(hl.line, hl.end_line)
    M.unconceal(0, hl.line + 1, hl.end_line)
    refresh_ellipsis()
    set_last_cycle(lnum, "subtree")
    cycle_hook("subtree", hl)
    if hide_archived(hl.line, hl.end_line) then
      vim.api.nvim_echo({ { archived_message() } }, false, {})
      return
    end
    vim.api.nvim_echo({ { skipped and "SUBTREE (NO CHILDREN)" or "SUBTREE" } }, false, {})
    return
  end
  -- FOLDED
  run_cycle_hook("OrgCyclePre", "folded", lnum)
  close_at(lnum)
  refresh_ellipsis()
  set_last_cycle(lnum, "folded")
  cycle_hook("folded", hl)
  vim.api.nvim_echo({ { "FOLDED" } }, false, {})
end

--- Cycle the subtree at the cursor even when it is archived
--- (org-cycle-force-archived).
function M.force_cycle_archived()
  M._force_archived = true
  local ok, res = pcall(M.cycle)
  M._force_archived = nil
  if not ok then
    error(res)
  end
  return res
end
