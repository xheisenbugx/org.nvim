---@mod org.fold.setup Buffer setup
---
--- VISIBILITY properties, the startup visibility (#+STARTUP), keeping
--- the cursor off hidden lines, catch_invisible_edits, and setup_buffer,
--- which ftplugin/org.lua calls for each Org buffer.
---
--- Part of org.fold, which loads it.

local config = require("org.config")
local shared = require("org.fold.shared")

local M = require("org.fold")

local accept_unchanged_tick = shared.accept_unchanged_tick
local cache = shared.cache
local close_at = shared.close_at
local close_blocks = shared.close_blocks
local close_drawers = shared.close_drawers
local closed_ns = shared.closed_ns
local curbuf = shared.curbuf
local default_closed = shared.default_closed
local file = shared.file
local get = shared.get
local has_fold = shared.has_fold
local hide_archived_all = shared.hide_archived_all
local hide_entry_contents = shared.hide_entry_contents
local hide_outline = shared.hide_outline
local ns_state = shared.ns_state
local open_at = shared.open_at
local open_outline = shared.open_outline
local record_states = shared.record_states
local refresh_ellipsis = shared.refresh_ellipsis
local region_states = shared.region_states
local regions = shared.regions
local set_win_opts = shared.set_win_opts
local show_entry = shared.show_entry
local show_heading_path = shared.show_heading_path
local show_levels = shared.show_levels
local startup_flag = shared.startup_flag
local startup_mode = shared.startup_mode

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

--- Whether any line of the buffer mentions a VISIBILITY property (reading
--- every entry's properties would parse all of them).
local function has_visibility_property(bufnr)
  local f = require("org.files").get_buffer(bufnr)
  return table.concat(f.lines, "\n"):upper():find(":VISIBILITY:", 1, true) ~= nil
end

--- Apply the VISIBILITY property of every headline that has one
--- (org-cycle-set-visibility-according-to-property): `folded`,
--- `children`, `content` or `all`. The headline itself is revealed.
--- Drawers are left as they are: Emacs folds them afterwards, and only
--- under `hidedrawers` (org-cycle-set-startup-visibility).
function M.apply_visibility_properties()
  if not has_visibility_property(0) then
    refresh_ellipsis()
    return
  end
  local hide_drawers = default_closed(curbuf()).drawer
  local pos = vim.api.nvim_win_get_cursor(0)
  for _, hl in ipairs(file().headlines) do
    local state = hl.properties.VISIBILITY
    state = state and state:lower()
    if state and has_fold(hl) then
      if state == "folded" then
        close_at(hl.line)
      else
        show_heading_path(hl)
      end
      if state == "children" then
        -- org-fold-show-hidden-entry + org-fold-show-children
        show_entry(hl, not hide_drawers)
        for _, ch in ipairs(hl.children) do
          M.unconceal(0, ch.line, ch.line)
          if has_fold(ch) then
            close_at(ch.line)
          end
        end
      elseif state == "content" then
        -- every headline of the subtree, no text (org-fold-subtree, then
        -- org-cycle-content): a headline without children stays folded
        if #hl.children == 0 then
          close_at(hl.line)
        end
        local function walk(h)
          if #h.children > 0 then
            open_at(h.line)
            hide_entry_contents(h)
          end
          for _, ch in ipairs(h.children) do
            M.unconceal(0, ch.line, ch.line)
            if #ch.children > 0 then
              walk(ch)
            elseif has_fold(ch) then
              close_at(ch.line)
            end
          end
        end
        walk(hl)
      elseif state == "all" or state == "showall" then
        open_outline(hl.line, hl.end_line)
        M.unconceal(0, hl.line, hl.end_line)
        if hide_drawers then
          close_drawers(hl.line, hl.end_line)
        end
      end
    end
  end
  vim.api.nvim_win_set_cursor(0, pos)
  refresh_ellipsis()
end

--- Apply #+STARTUP / startup_folded visibility in the current window,
--- then hide blocks (`hideblocks`), apply VISIBILITY properties, fold
--- archived subtrees and hide drawers (org-cycle-set-startup-visibility).
---@param first? boolean the buffer was just set up, with 'foldlevel' set
--- for its startup visibility already (see `setup_buffer`)
function M.apply_startup(bufnr, first)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local mode, startup = startup_mode(bufnr)
  local levels = tonumber(mode:match("^show(%d)levels$") or "")
  local closed = false
  if first and vim.b[bufnr].org_startup_foldlevel == mode then
    -- 'foldlevel' was set for this mode before 'foldmethod' (zM or zR here
    -- would compute the folds of the whole buffer, and :edit computes
    -- them again once the file is loaded)
    M.clear_hidden()
    vim.b.org_global_cycle = mode == "overview" and "overview" or "showall"
    if mode == "showeverything" then
      return
    end
    closed = true
  elseif mode == "overview" then
    M.overview(true)
  elseif mode == "content" then
    M.content(true)
  elseif levels then
    show_levels(levels, true)
    vim.b.org_global_cycle = "content"
  else
    M.clear_hidden()
    vim.cmd("normal! zR")
    vim.b.org_global_cycle = "showall"
  end
  if mode == "showeverything" then
    return
  end
  if closed then
    -- blocks and drawers were closed with everything else: open those
    -- that `hideblocks` and `hidedrawers` leave open
    local states = region_states(bufnr, regions(bufnr), true)
    local open = false
    for _, c in pairs(states) do
      open = open or not c
    end
    if open then
      hide_outline(true)
    else
      record_states(bufnr, states)
    end
    hide_archived_all()
    return
  end
  local last = vim.api.nvim_buf_line_count(0)
  if startup_flag(startup, "hideblocks", "nohideblocks", config.opts.hide_block_startup) then
    close_blocks(1, last)
  end
  M.apply_visibility_properties()
  hide_archived_all()
  if startup_flag(startup, "hidedrawers", "nohidedrawers", config.opts.hide_drawer_startup ~= false) then
    close_drawers(1, last)
  end
end

--- Return to the startup visibility, VISIBILITY properties included
--- (C-u C-u TAB, org-cycle-set-startup-visibility).
function M.set_startup_visibility()
  M.apply_startup(0)
  vim.api.nvim_echo({ { "Startup visibility, plus VISIBILITY properties" } }, false, {})
end

--- Show the entire buffer, drawers included (C-u C-u C-u TAB).
function M.show_everything()
  M.clear_hidden()
  vim.cmd("normal! zR")
  vim.b.org_global_cycle = "showall"
  vim.api.nvim_echo({ { "Entire buffer visible, including drawers" } }, false, {})
end

-- The keys typed since the cursor last moved: a move to the next line
-- is a line motion (j, k, ...) unless they hold a jump (a search, a mark,
-- G, an Ex command, ...), which must show the line it lands on.
local recent_keys = ""
local motion_ns

local function watch_motion_keys()
  if motion_ns then
    return
  end
  -- (only typed keys: those of :normal in a function are no motion)
  motion_ns = vim.on_key(function(_, typed)
    if typed and typed ~= "" then
      recent_keys = (recent_keys .. typed):sub(-64)
    end
  end, vim.api.nvim_create_namespace("org.fold.motion"))
end

--- Whether the cursor got where it is by a jump: keys holding one, or no
--- key at all (a function moved it: search(), a plugin...).
local function jumped()
  local keys = recent_keys
  recent_keys = ""
  if keys == "" then
    return true
  end
  -- (special keys are three bytes from K_SPECIAL, 0x80: <Down>, <Up>...)
  local s = keys:gsub("\128..", "")
  return s:find("[/?nN*#%%GHML'`:{}()\15]") ~= nil or s:find("gg", 1, true) ~= nil or s:find("[%[%]][%[%]]") ~= nil
end

--- Forget the last TAB and S-TAB once the cursor leaves where they left
--- it: in Emacs any other command breaks the cycle (`last-command`), so
--- TAB, j, k, TAB folds a subtree that the first TAB opened to CHILDREN.
local function forget_cycles_moved()
  local pos = vim.api.nvim_win_get_cursor(0)
  for _, var in ipairs({ "org_last_cycle", "org_last_global" }) do
    local s = vim.w[var]
    if s and (s.lnum ~= pos[1] or s.col ~= pos[2]) then
      vim.w[var] = nil
    end
  end
end

--- Keep the cursor off hidden lines: line motions skip them, other jumps
--- reveal the line (Emacs never leaves point in invisible text).
local function on_cursor_moved(bufnr)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local prev = vim.w.org_prev_lnum or lnum
  vim.w.org_prev_lnum = lnum
  local jump = jumped()
  if not M.is_concealed(bufnr, lnum) then
    return
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  local dir = lnum >= prev and 1 or -1
  if math.abs(lnum - prev) <= 1 and not jump then
    local l = lnum
    while l >= 1 and l <= n and not M.line_visible(l) do
      l = l + dir
    end
    if l < 1 or l > n then
      l = lnum
      while l >= 1 and l <= n and not M.line_visible(l) do
        l = l - dir
      end
    end
    if l >= 1 and l <= n then
      vim.w.org_prev_lnum = l
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      return
    end
  end
  M.show_context(lnum, "lineage")
end

--- Is line `lnum` hidden: concealed, or inside a closed fold below its
--- first line?
local function line_hidden(lnum)
  return lnum >= 1 and lnum <= vim.api.nvim_buf_line_count(0) and not M.line_visible(lnum)
end

--- org-fold-check-before-invisible-edit: `kind` ("insert", "delete" or
--- "delete-backward") is about to edit at the cursor. When that touches
--- hidden text (the cursor line is hidden, or the edit is at the end of a
--- line followed by hidden lines, or at the start of a line after hidden
--- ones), react as `catch_invisible_edits` says. Returns false when the
--- edit must not happen.
---@param kind "insert"|"delete"|"delete-backward"
---@return boolean
function M.check_invisible_edit(kind)
  local mode = config.opts.catch_invisible_edits
  if not mode then
    return true
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  local lnum, col = pos[1], pos[2]
  local line = vim.api.nvim_get_current_line()
  local here = not M.line_visible(lnum)
  local at = here or (col >= #line and line_hidden(lnum + 1))
  local before = here or (col == 0 and line_hidden(lnum - 1))
  if not (at or before) then
    return true
  end
  local msg = "Edit in invisible region aborted, repeat to confirm with text visible"
  if mode == "error" then
    require("org.utils").warn("Editing in invisible areas is prohibited, make them visible first")
    return false
  end
  local props = package.loaded["org.properties"]
  if props and props.custom_properties_hidden and props.custom_properties_hidden(0) then
    -- the hidden text may be custom properties (org-custom-properties)
    if require("org.utils").confirm("Display invisible properties in this buffer?") then
      props.toggle_custom_properties_visibility()
      if mode == "smart" or mode == "show-and-error" then
        require("org.utils").warn(msg)
        return false
      end
      return true
    end
  end
  M.show_context(lnum, "local")
  if at and col >= #line and lnum < vim.api.nvim_buf_line_count(0) then
    M.show_context(lnum + 1, "local")
  end
  if before and lnum > 1 then
    M.show_context(lnum - 1, "local")
  end
  if mode == "show" then
    require("org.utils").notify("Unfolding invisible region around point before editing")
    return true
  elseif mode == "smart" and at and not before and (kind == "insert" or kind == "delete-backward") then
    require("org.utils").notify("Unfolding invisible region around point before editing")
    return true
  end
  require("org.utils").warn(msg)
  return false
end

--- The kind of edit `command` makes, when `catch_invisible_edits_commands`
--- lists it (org-fold-catch-invisible-edits-commands).
local function edit_kind(command)
  local cmds = config.opts.catch_invisible_edits_commands
  return type(cmds) == "table" and cmds[command] or nil
end

--- Check an action before it runs (see `check_invisible_edit`): false
--- when it must not.
function M.check_invisible_edit_command(command)
  if vim.bo.filetype ~= "org" or not config.opts.catch_invisible_edits then
    return true
  end
  local kind = edit_kind(command)
  if not kind then
    return true
  end
  return M.check_invisible_edit(kind)
end

--- Text typed in Insert mode (the self_insert command).
local function on_insert_char()
  local kind = edit_kind("self_insert")
  if kind and not M.check_invisible_edit(kind) then
    vim.v.char = ""
  end
end

-- <BS>, <Del> and <CR> in Insert mode, checked before Vim runs them
-- (delete_backward_char, delete_char and return).
local key_ns
local insert_keys
local function watch_insert_keys()
  if key_ns then
    return
  end
  insert_keys = {
    [vim.keycode("<BS>")] = "delete_backward_char",
    [vim.keycode("<C-h>")] = "delete_backward_char",
    [vim.keycode("<Del>")] = "delete_char",
    [vim.keycode("<CR>")] = "return",
    [vim.keycode("<C-m>")] = "return",
  }
  key_ns = vim.on_key(function(key)
    local command = insert_keys[key]
    if not command or vim.bo.filetype ~= "org" or not config.opts.catch_invisible_edits then
      return
    end
    local mode = vim.api.nvim_get_mode().mode
    if mode ~= "i" and mode ~= "R" then
      return
    end
    local kind = edit_kind(command)
    if kind then
      local ok, allowed = pcall(M.check_invisible_edit, kind)
      if ok and not allowed then
        return ""
      end
    end
  end, vim.api.nvim_create_namespace("org.fold.keys"))
end

function M.setup_buffer(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local function setup_win(win)
    -- a hidden load (bufload, nvim_buf_call) runs in Vim's autocommand
    -- window: the startup visibility waits for a real window
    if vim.fn.win_gettype(win) == "autocmd" then
      return
    end
    local first = not vim.b[bufnr].org_startup_done
    if first then
      -- Set 'foldlevel' before 'foldmethod' when it alone gives the
      -- startup visibility: the folds are then computed once, as the
      -- file is displayed.
      local mode = startup_mode(bufnr)
      if mode == "overview" and not has_visibility_property(bufnr) then
        vim.wo[win][0].foldlevel = 0
        vim.b[bufnr].org_startup_foldlevel = mode
      elseif mode == "showeverything" then
        -- what zR sets: the deepest fold
        local deepest = 0
        for _, l in pairs(get(bufnr).levels) do
          deepest = math.max(deepest, tonumber(type(l) == "string" and l:sub(2) or l) or 0)
        end
        vim.wo[win][0].foldlevel = deepest
        vim.b[bufnr].org_startup_foldlevel = mode
      end
    end
    set_win_opts(win)
    if first then
      vim.b[bufnr].org_startup_done = true
      vim.api.nvim_win_call(win, function()
        M.apply_startup(bufnr, true)
      end)
    end
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) == bufnr then
    setup_win(win)
  end
  local group = vim.api.nvim_create_augroup("org.fold." .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = bufnr,
    group = group,
    callback = function()
      local w = vim.api.nvim_get_current_win()
      if vim.wo[w].foldexpr ~= "v:lua.require'org.fold'.foldexpr(v:lnum)" then
        setup_win(w)
      end
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = bufnr,
    group = group,
    callback = forget_cycles_moved,
  })
  if M.conceal_supported then
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = bufnr,
      group = group,
      callback = function()
        on_cursor_moved(bufnr)
      end,
    })
    vim.api.nvim_create_autocmd("InsertCharPre", {
      buffer = bufnr,
      group = group,
      callback = function()
        on_insert_char()
      end,
    })
    watch_insert_keys()
    watch_motion_keys()
  end
  vim.api.nvim_create_autocmd({ "BufWritePost", "BufEnter" }, {
    buffer = bufnr,
    group = group,
    callback = function()
      accept_unchanged_tick(bufnr)
    end,
  })
  -- :edit re-reads the file (Emacs revert-buffer re-runs org-mode): its
  -- startup visibility applies again, from the #+STARTUP: line on disk
  vim.api.nvim_create_autocmd("BufReadPre", {
    buffer = bufnr,
    group = group,
    callback = function()
      vim.b[bufnr].org_startup_done = nil
      vim.b[bufnr].org_startup_foldlevel = nil
      -- the reload would move the marks of the old visibility (hidden
      -- lines, ellipses, fold states) onto other rows
      M.clear_hidden(bufnr)
      vim.api.nvim_buf_clear_namespace(bufnr, ns_state, 0, -1)
      for _, ns in pairs(closed_ns) do
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    group = group,
    callback = function()
      cache[bufnr] = nil
    end,
  })
end
