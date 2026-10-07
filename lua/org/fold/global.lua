---@mod org.fold.global Global visibility (S-TAB)
---
--- OVERVIEW, CONTENTS and SHOW ALL (org-cycle-internal-global), and the
--- folded state of drawers and blocks kept across them.
---
--- Part of org.fold, which loads it.

local config = require("org.config")
local parser = require("org.parser")
local shared = require("org.fold.shared")

local M = require("org.fold")

local close_at = shared.close_at
local curbuf = shared.curbuf
local file = shared.file
local has_fold = shared.has_fold
local hide_archived_all = shared.hide_archived_all
local is_blank = shared.is_blank
local open_at = shared.open_at
local refresh_ellipsis = shared.refresh_ellipsis
local regions = shared.regions
local startup_flag = shared.startup_flag
local startup_mode = shared.startup_mode

---------------------------------------------------------------------------
-- Global visibility
---------------------------------------------------------------------------

-- Emacs folds the outline, drawers and blocks separately: hiding the
-- outline (OVERVIEW, CONTENTS) leaves a drawer or block as it was, so it
-- shows the same once its entry is shown again. Vim folds nest instead,
-- and the state of a fold inside a closed one can't be read. The states
-- are read while visible and kept here, with an extmark at each start.
local ns_state = vim.api.nvim_create_namespace("org.fold.state")
local region_closed = {} -- bufnr -> { [extmark id] = closed }

local KEEPS_STATE = { drawer = true, block = true, results = true }

--- Whether drawers and blocks are folded when nothing says otherwise:
--- `hidedrawers` and `hideblocks` (#+STARTUP or their options).
local function default_closed(bufnr)
  local _, startup = startup_mode(bufnr)
  return {
    drawer = startup_flag(startup, "hidedrawers", "nohidedrawers", config.opts.hide_drawer_startup ~= false),
    block = startup_flag(startup, "hideblocks", "nohideblocks", config.opts.hide_block_startup) and true or false,
    results = false,
  }
end

--- Whether each drawer, block and result of `regs` is folded (by start
--- line): as shown when it is visible, else as last recorded.
---@param fresh? boolean ignore the current folds (startup)
local function region_states(bufnr, regs, fresh)
  local defaults = default_closed(bufnr)
  local known = {}
  local mem = region_closed[bufnr] or {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns_state, 0, -1, {})) do
    if mem[m[1]] ~= nil then
      known[m[2] + 1] = mem[m[1]]
    end
  end
  local states = {}
  for _, r in ipairs(regs) do
    if KEEPS_STATE[r.kind] then
      local fc = not fresh and vim.fn.foldclosed(r.start)
      if fc == -1 then
        states[r.start] = false
      elseif fc == r.start then
        states[r.start] = true
      elseif not fresh and known[r.start] ~= nil then
        states[r.start] = known[r.start]
      else
        states[r.start] = defaults[r.kind]
      end
    end
  end
  return states
end

local function record_states(bufnr, states)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_state, 0, -1)
  local mem = {}
  for lnum, closed in pairs(states) do
    local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_state, lnum - 1, 0, {})
    if ok then
      mem[id] = closed
    end
  end
  region_closed[bufnr] = mem
end

--- Record that the drawer or block at `lnum` was folded or unfolded.
local function record_state(bufnr, lnum, closed)
  local mem = region_closed[bufnr]
  if not mem then
    mem = {}
    region_closed[bufnr] = mem
  end
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_state, { lnum - 1, 0 }, { lnum - 1, -1 }, {})
  if marks[1] then
    mem[marks[1][1]] = closed
    return
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_state, lnum - 1, 0, {})
  if ok then
    mem[id] = closed
  end
end

--- Fold the outline of the buffer (every headline, item and inline task),
--- leaving each drawer, block and result as it was (see `region_states`).
---@param fresh? boolean the buffer was just loaded: drawers and blocks are
--- as `hidedrawers` and `hideblocks` say
local function hide_outline(fresh)
  local bufnr = curbuf()
  local regs = regions(bufnr)
  local states = region_states(bufnr, regs, fresh)
  record_states(bufnr, states)
  local open = false
  for _, closed in pairs(states) do
    if not closed then
      open = true
      break
    end
  end
  if not open then
    vim.cmd("normal! zM")
    return
  end
  -- everything open, then close the folds to close from the last one up:
  -- each :foldclose then closes the fold starting on its line
  vim.cmd("normal! zR")
  local starts = {}
  for _, hl in ipairs(file().headlines) do
    if has_fold(hl) then
      starts[#starts + 1] = hl.line
    end
  end
  for _, r in ipairs(regs) do
    -- (items stay open: whatever shows an entry opens its items)
    if r.kind == "inlinetask" or states[r.start] then
      starts[#starts + 1] = r.start
    end
  end
  table.sort(starts)
  local prev
  for i = #starts, 1, -1 do
    local l = starts[i]
    if l ~= prev and vim.fn.foldclosed(l) == -1 and vim.fn.foldlevel(l) > 0 then
      pcall(vim.cmd, l .. "foldclose")
    end
    prev = l
  end
end

---@param fresh? boolean (see `hide_outline`)
function M.overview(fresh)
  M.clear_hidden()
  hide_outline(fresh)
  vim.b.org_global_cycle = "overview"
end

--- The inline tasks in the text of `hl` (the lines of their headlines).
local function inline_tasks(hl)
  local min_inline = parser.inlinetask_min_level()
  if not min_inline or hl.body_end <= hl.line then
    return {}
  end
  local out = {}
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, hl.line, hl.body_end, false)) do
    local lv = l:byte(1) == 42 and parser.headline_level(l)
    if lv and lv >= min_inline and not l:match("^%*+%s+END%s*$") then
      out[#out + 1] = hl.line + i
    end
  end
  return out
end

--- How many blank lines before the headline after line `last` stay
--- visible when the text above it is hidden (org-cycle-separator-lines,
--- see org-cycle-show-empty-lines): the last one, or all of them when the
--- option is negative, if there are enough.
local function separator_lines(last)
  local sep = config.opts.cycle_separator_lines or 2
  if sep == 0 or last >= vim.api.nvim_buf_line_count(0) then
    return 0
  end
  local nxt = vim.api.nvim_buf_get_lines(0, last, last + 1, false)[1] or ""
  if not (nxt:byte(1) == 42 and parser.headline_level(nxt)) then
    return 0
  end
  local k = 0
  while last - k >= 1 and is_blank(vim.api.nvim_buf_get_lines(0, last - k - 1, last - k, false)[1]) do
    k = k + 1
  end
  if k < math.abs(sep) then
    return 0
  end
  return sep > 0 and 1 or k
end

--- Hide the text of `hl` like org-cycle-content: the separator lines
--- before its first child stay visible, and so do its inline tasks,
--- folded (org-inlinetask-hide-tasks).
local function hide_entry_contents(hl)
  if hl.body_end <= hl.line then
    return
  end
  local last = hl.body_end - separator_lines(hl.body_end)
  if last > hl.line then
    M.conceal(0, hl.line + 1, last)
  end
  for _, l in ipairs(inline_tasks(hl)) do
    M.unconceal(0, l, l)
    for _, r in ipairs(regions(curbuf(), l, l)) do
      if r.kind == "inlinetask" and r.start == l then
        close_at(l)
      end
    end
  end
end

--- Show the headlines with up to `level` stars without their text
--- (org-cycle-content): CONTENTS, and #+STARTUP: showNlevels.
---@param fresh? boolean (see `hide_outline`)
local function show_levels(level, fresh)
  M.clear_hidden()
  hide_outline(fresh)
  -- parents come first, so each fold opened here is visible
  for _, hl in ipairs(file().headlines) do
    if hl.level < level and has_fold(hl) then
      local shown = false
      for _, ch in ipairs(hl.children) do
        if ch.level <= level then
          shown = true
        end
      end
      if shown or #inline_tasks(hl) > 0 then
        open_at(hl.line)
        hide_entry_contents(hl)
        for _, ch in ipairs(hl.children) do
          if ch.level > level then
            -- under a skipped level: deeper than shown
            M.conceal(0, ch.line, ch.line)
          end
        end
      end
    end
  end
  hide_archived_all()
  refresh_ellipsis()
end

---@param fresh? boolean (see `hide_outline`)
function M.content(fresh)
  show_levels(math.huge, fresh)
  vim.b.org_global_cycle = "content"
end

function M.show_all()
  M.clear_hidden()
  vim.cmd("normal! zR")
  vim.b.org_global_cycle = "showall"
end

--- Every headline and block shown, drawers as they were (Emacs "showall",
--- org-fold-show-all '(headings blocks)).
local function show_all_but_drawers()
  local bufnr = curbuf()
  local regs = regions(bufnr)
  local states = region_states(bufnr, regs)
  M.clear_hidden()
  vim.cmd("normal! zR")
  for i = #regs, 1, -1 do
    local r = regs[i]
    if r.kind == "drawer" and states[r.start] then
      close_at(r.start)
    end
  end
  hide_archived_all()
  vim.b.org_global_cycle = "showall"
end

--- Run the User autocmd `pattern` (OrgCyclePre, org-cycle-pre-hook, or
--- OrgCycle, org-cycle-hook) with the new visibility `state`: "overview",
--- "contents" or "all" after a global change, "folded", "children",
--- "subtree" (or "empty", before only) after a local one.
---@param lnum? integer the headline or item cycled (local cycling)
local function run_cycle_hook(pattern, state, lnum)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = pattern,
    data = { state = state, bufnr = curbuf(), lnum = lnum },
    modeline = false,
  })
end

--- Where the cursor shows: the start of the closed fold holding it, else
--- the nearest visible line above it (the text Vim and `on_cursor_moved`
--- would move it to).
local function shown_lnum(lnum)
  local fc = vim.fn.foldclosed(lnum)
  if fc ~= -1 then
    return fc
  end
  local l = lnum
  while l > 1 and not M.line_visible(l) do
    l = l - 1
    fc = vim.fn.foldclosed(l)
    if fc ~= -1 then
      return fc
    end
  end
  return l
end

--- Remember the global cycle just done (Emacs checks `last-command`): the
--- cursor goes where it shows, so that nothing moves it before the next
--- command.
local function set_last_global()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local shown = shown_lnum(lnum)
  if shown ~= lnum then
    vim.api.nvim_win_set_cursor(0, { shown, 0 })
  end
  vim.w.org_last_global = {
    buf = curbuf(),
    tick = vim.api.nvim_buf_get_changedtick(0),
    lnum = shown,
    col = vim.api.nvim_win_get_cursor(0)[2],
  }
end

--- Whether the last command in this window was a global cycle.
local function last_was_global()
  local s = vim.w.org_last_global
  return s ~= nil
    and s.buf == curbuf()
    and s.tick == vim.api.nvim_buf_get_changedtick(0)
    and s.lnum == vim.api.nvim_win_get_cursor(0)[1]
end

function M.global_cycle()
  if vim.v.count > 0 then
    show_levels(vim.v.count)
    vim.b.org_global_cycle = "content"
    return
  end
  -- CONTENTS and SHOW ALL only right after the previous state; any other
  -- command in between starts again from OVERVIEW (org-cycle-internal-global)
  local state = last_was_global() and vim.b.org_global_cycle or "showall"
  if state == "showall" then
    run_cycle_hook("OrgCyclePre", "overview")
    M.overview()
    vim.api.nvim_echo({ { "OVERVIEW" } }, false, {})
    run_cycle_hook("OrgCycle", "overview")
  elseif state == "overview" then
    run_cycle_hook("OrgCyclePre", "contents")
    M.content()
    vim.api.nvim_echo({ { "CONTENTS" } }, false, {})
    run_cycle_hook("OrgCycle", "contents")
  else
    run_cycle_hook("OrgCyclePre", "all")
    show_all_but_drawers()
    vim.api.nvim_echo({ { "SHOW ALL" } }, false, {})
    run_cycle_hook("OrgCycle", "all")
  end
  set_last_global()
end

shared.default_closed = default_closed
shared.hide_entry_contents = hide_entry_contents
shared.hide_outline = hide_outline
shared.ns_state = ns_state
shared.record_state = record_state
shared.record_states = record_states
shared.region_states = region_states
shared.run_cycle_hook = run_cycle_hook
shared.show_levels = show_levels
