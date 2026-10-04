---@mod org.agenda.view.window Agenda buffer and window: open, redo, quit
---
--- Part of org.agenda.view, which loads it.

local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")
local shared = require("org.agenda.view.shared")

local M = require("org.agenda.view")

local empty_filters = shared.empty_filters
local item_key = shared.item_key
local new_state = shared.new_state
local set_restrict = shared.set_restrict
local states = shared.states
local use = shared.use

---------------------------------------------------------------------------
-- Buffer & window
---------------------------------------------------------------------------

--- Echo the outline path of the entry at point (org-agenda-show-outline-path).
local function show_outline_path()
  if not config.opts.agenda.show_outline_path or #vim.api.nvim_list_uis() == 0 then
    return
  end
  local item = M.item_at_cursor()
  if not (item and item.headline) then
    return
  end
  local path = item.headline:outline_path()
  path[#path + 1] = item.headline:plain_title()
  local text = table.concat(path, "/")
  vim.api.nvim_echo({ { text } }, false, {})
end

local function ensure_buf(name)
  for buf, st in pairs(states) do
    if st.name == name and vim.api.nvim_buf_is_valid(buf) then
      use(st)
      return buf, false
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "orgagenda"
  local st = new_state()
  st.buf = buf
  st.name = name
  -- keep settings that persist across agendas (persistent filter)
  if config.opts.agenda.persistent_filter and M.state then
    st.filters = vim.deepcopy(M.state.filters)
  end
  states[buf] = st
  use(st)
  shared.setup_mappings(buf)
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = buf,
    callback = function()
      if states[buf] then
        use(states[buf])
      end
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      if states[buf] then
        use(states[buf])
      end
      local lr = M._last_run
      if lr and (lr.buf ~= buf or lr.lnum ~= vim.api.nvim_win_get_cursor(0)[1]) then
        -- a motion ends a sequence of repeated commands (last-command)
        M._last_run = nil
      end
      if M.state.follow then
        vim.schedule(function()
          M.follow_show()
        end)
      end
      show_outline_path()
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      local st2 = states[buf]
      states[buf] = nil
      if st2 then
        st2.buf = nil
        st2.win = nil
      end
    end,
  })
  return buf, true
end

local function set_win_opts(win)
  local o = { scope = "local", win = win }
  vim.api.nvim_set_option_value("number", false, o)
  vim.api.nvim_set_option_value("relativenumber", false, o)
  vim.api.nvim_set_option_value("signcolumn", "no", o)
  vim.api.nvim_set_option_value("wrap", false, o)
  vim.api.nvim_set_option_value("cursorline", true, o)
  vim.api.nvim_set_option_value("foldenable", false, o)
  vim.api.nvim_set_option_value("spell", false, o)
  vim.api.nvim_set_option_value("list", false, o)
  vim.api.nvim_set_option_value("colorcolumn", "", o)
end

--- The window layout of the current tab: a tree of splits with buffers.
local function save_layout()
  local function walk(node)
    if node[1] == "leaf" then
      local w = node[2]
      return { "leaf", vim.api.nvim_win_get_buf(w), vim.api.nvim_win_get_cursor(w), w }
    end
    local children = {}
    for _, c in ipairs(node[2]) do
      children[#children + 1] = walk(c)
    end
    return { node[1], children }
  end
  local ok, tree = pcall(function()
    return walk(vim.fn.winlayout())
  end)
  return ok and { tree = tree, current = vim.api.nvim_get_current_win() } or nil
end

--- Rebuild a layout saved by save_layout in the current tab.
local function restore_layout(saved)
  if not saved then
    return false
  end
  pcall(vim.cmd, "silent! only")
  local focus
  local function build(node, win)
    vim.api.nvim_set_current_win(win)
    if node[1] == "leaf" then
      if vim.api.nvim_buf_is_valid(node[2]) then
        vim.api.nvim_win_set_buf(win, node[2])
        pcall(vim.api.nvim_win_set_cursor, win, node[3])
      end
      if node[4] == saved.current then
        focus = win
      end
      return
    end
    local wins = { win }
    for i = 2, #node[2] do
      vim.api.nvim_set_current_win(wins[#wins])
      vim.cmd(node[1] == "row" and "rightbelow vsplit" or "rightbelow split")
      wins[#wins + 1] = vim.api.nvim_get_current_win()
    end
    for i, c in ipairs(node[2]) do
      build(c, wins[i])
    end
  end
  local ok = pcall(build, saved.tree, vim.api.nvim_get_current_win())
  if focus and vim.api.nvim_win_is_valid(focus) then
    vim.api.nvim_set_current_win(focus)
  end
  return ok
end

--- Display the agenda buffer (org-agenda-window-setup).
local function show_buffer()
  local buf = M.state.buf
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == buf then
      vim.api.nvim_set_current_win(w)
      M.state.win = w
      set_win_opts(w)
      return
    end
  end
  local acfg = config.opts.agenda
  local mode = acfg.window or "split"
  if mode == "reorganize-frame" then
    mode = "split"
  elseif mode == "current-window" then
    mode = "current"
  elseif mode == "only-window" then
    mode = "only"
  elseif mode == "other-window" then
    mode = "other"
  elseif mode == "other-tab" or mode == "other-frame" then
    mode = "tab"
  end
  M.state.prev_win = vim.api.nvim_get_current_win()
  M.state.prev_buf = vim.api.nvim_get_current_buf()
  M.state.layout = acfg.restore_windows_after_quit and save_layout() or nil
  M.state.win_mode = mode
  if mode == "float" then
    M.state.win =
      require("org.ui").open_buffer_window(buf, "float", { title = "Org Agenda", width = 0.9, height = 0.85 })
  elseif mode == "split" then
    -- reorganize-frame: two windows, the current one and the agenda
    pcall(vim.cmd, "silent! only")
    M.state.prev_win = vim.api.nvim_get_current_win()
    M.state.win = require("org.ui").open_buffer_window(buf, "split")
  elseif mode == "vsplit" or mode == "tab" then
    M.state.win = require("org.ui").open_buffer_window(buf, mode)
  elseif mode == "only" then
    pcall(vim.cmd, "silent! only")
    vim.api.nvim_set_current_buf(buf)
    M.state.win = vim.api.nvim_get_current_win()
  elseif mode == "other" then
    local cur = vim.api.nvim_get_current_win()
    local other
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if w ~= cur and vim.api.nvim_win_get_config(w).relative == "" then
        other = w
        break
      end
    end
    if not other then
      vim.cmd("rightbelow split")
      other = vim.api.nvim_get_current_win()
    end
    vim.api.nvim_set_current_win(other)
    vim.api.nvim_win_set_buf(other, buf)
    M.state.win = other
  else
    vim.api.nvim_set_current_buf(buf)
    M.state.win = vim.api.nvim_get_current_win()
  end
  set_win_opts(M.state.win)
end

local function first_item_line()
  local lines = vim.tbl_keys(M.state.line_items)
  table.sort(lines)
  return lines[1]
end

--- Filter presets of a view's blocks (org-agenda-*-filter-preset).
local function view_presets(view)
  local p = { tag = {}, category = {}, regexp = {}, effort = {} }
  local function add(kind, v)
    if type(v) == "string" then
      v = { v }
    end
    for _, x in ipairs(v or {}) do
      if not vim.tbl_contains(p[kind], x) then
        p[kind][#p[kind] + 1] = x
      end
    end
  end
  for _, src in ipairs({ view.settings or {}, unpack(view.blocks or {}) }) do
    add("tag", src.tag_filter_preset or src.org_agenda_tag_filter_preset)
    add("category", src.category_filter_preset or src.org_agenda_category_filter_preset)
    add("regexp", src.regexp_filter_preset or src.org_agenda_regexp_filter_preset)
    add("effort", src.effort_filter_preset or src.org_agenda_effort_filter_preset)
  end
  return p
end

--- A buffer name for a view (org-agenda-sticky: "*Org Agenda(KEY)*").
local function buffer_name(view, opts)
  if not config.opts.agenda.sticky then
    return "org://agenda"
  end
  local key = opts.key or view.key
  if not key then
    local b = view.blocks[1] or {}
    key = (b.type == "agenda" and "a")
      or (b.type == "todo" and "t")
      or (b.type == "tags" and "m")
      or (b.type == "tags_todo" and "M")
      or (b.type == "search" and "s")
      or (b.type == "stuck" and "#")
      or "a"
    if b.match and b.match ~= "" then
      key = key .. ":" .. b.match
    elseif b.keywords then
      key = key .. ":" .. table.concat(type(b.keywords) == "table" and b.keywords or { b.keywords }, "|")
    end
  end
  return "org://agenda(" .. key .. ")"
end

--- Open a view.
---@param view { blocks: table[], title?: string, multi?: boolean, key?: string }
---@param opts? { anchor?: integer, span?: string|integer, restrict?: table, keep_state?: boolean, key?: string }
function M.open(view, opts)
  opts = opts or {}
  local name = buffer_name(view, opts)
  local prev = M.state
  local _, created = ensure_buf(name)
  if config.opts.agenda.sticky and not created and M.state.view and not opts.keep_state then
    -- a sticky agenda is shown as it is (org-agenda-use-sticky-p)
    show_buffer()
    utils.notify("Sticky Agenda buffer, use `r' to refresh")
    return
  end
  M.state.view = view
  view.presets = view_presets(view)
  if not opts.keep_state then
    local acfg = config.opts.agenda
    -- the start_with_* modes and dim_blocked_tasks: the command's settings
    -- are let-bound around org-agenda-mode and org-agenda-finalize
    local function opt(name)
      return M.command_option(name, M.state)
    end
    M.state.anchor = opts.anchor
    M.state.span = opts.span
    M.state.align = true
    M.state.log_mode = opt("start_with_log_mode") or false
    M.state.clockreport = opt("start_with_clockreport_mode") or false
    M.state.entry_text = opt("start_with_entry_text_mode") or false
    M.state.follow = opt("start_with_follow_mode") or false
    -- org-agenda-start-with-archives-mode: "trees", or true / "files"
    -- for the archive files too
    local am = opt("start_with_archives_mode")
    M.state.archives = (am == true or am == "files") and "files" or (am == "trees" and "trees") or false
    M.state.inactive = false
    M.state.time_grid_off = false
    M.state.no_deadlines = false
    M.state.include_diary = nil
    M.state.dim_blocked = opt("dim_blocked_tasks")
    if M.state.dim_blocked == nil then
      M.state.dim_blocked = true
    end
    M.state.marks = {}
    M.state.limits = {}
    M.undo_list = {}
    if acfg.persistent_filter and prev and prev ~= M.state then
      M.state.filters = vim.deepcopy(prev.filters)
    elseif not acfg.persistent_filter then
      M.state.filters = empty_filters()
    end
    set_restrict(opts.restrict)
  end
  show_buffer()
  M.refresh()
  -- cursor: today's header in agenda views, else first item
  local target
  local today = date.today_days()
  for lnum, d in pairs(M.state.day_lines) do
    if d == today and (not target or lnum < target) then
      target = lnum
    end
  end
  target = target or first_item_line() or 1
  pcall(vim.api.nvim_win_set_cursor, M.state.win, { target, 0 })
  local ok, cols = pcall(require, "org.agenda.columns")
  if ok then
    pcall(cols.refresh_if_active, true)
  end
end

--- Rebuild the view (re-reading files), keeping the cursor on the same entry.
function M.redo(opts)
  opts = opts or {}
  if not M.state.view then
    return
  end
  local item = M.item_at_cursor()
  local key = item and item_key(item)
  local lnum = M.state.win and vim.api.nvim_win_is_valid(M.state.win) and vim.api.nvim_win_get_cursor(M.state.win)[1]
    or 1
  M.refresh()
  if M.state.win and vim.api.nvim_win_is_valid(M.state.win) then
    local target
    if key then
      for l, it in pairs(M.state.line_items) do
        if item_key(it) == key and (not target or math.abs(l - lnum) < math.abs(target - lnum)) then
          target = l
        end
      end
    end
    target = target or math.min(lnum, vim.api.nvim_buf_line_count(M.state.buf))
    pcall(vim.api.nvim_win_set_cursor, M.state.win, { target, 0 })
  end
  -- a rebuild runs org-agenda-finalize, which turns column view back on
  -- when org-agenda-view-columns-initially is set (even after `q` in it)
  local ok, cols = pcall(require, "org.agenda.columns")
  if ok and not cols.active() then
    pcall(cols.refresh_if_active, true)
  end
end

--- Quit the agenda window (org-agenda-quit). `wipe` also deletes the
--- buffer (org-agenda-Quit).
function M.quit(wipe)
  -- windows switching below may make another agenda buffer current
  local S = M.state
  S.follow = false
  local win = S.win
  local mode = S.win_mode
  local layout = S.layout
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == "" then
    -- the filter display belongs to the agenda, not to the window
    pcall(vim.api.nvim_set_option_value, "winbar", "", { scope = "local", win = win })
  end
  if layout and win and vim.api.nvim_win_is_valid(win) and mode ~= "float" and mode ~= "tab" then
    vim.api.nvim_set_current_win(win)
    restore_layout(layout)
    S.layout = nil
  elseif win and vim.api.nvim_win_is_valid(win) then
    local closable = mode == "float" or mode == "split" or mode == "vsplit" or mode == "other"
    if closable and #vim.api.nvim_list_wins() > 1 then
      vim.api.nvim_win_close(win, true)
    elseif mode == "tab" and #vim.api.nvim_list_tabpages() > 1 then
      vim.api.nvim_set_current_win(win)
      vim.cmd("tabclose")
    else
      if S.prev_buf and vim.api.nvim_buf_is_valid(S.prev_buf) and S.prev_buf ~= S.buf then
        vim.api.nvim_win_set_buf(win, S.prev_buf)
      else
        vim.api.nvim_win_call(win, function()
          vim.cmd("enew")
        end)
      end
    end
    if S.prev_win and vim.api.nvim_win_is_valid(S.prev_win) then
      pcall(vim.api.nvim_set_current_win, S.prev_win)
    end
  end
  S.win = nil
  if wipe and S.buf and vim.api.nvim_buf_is_valid(S.buf) then
    local b = S.buf
    pcall(vim.api.nvim_buf_delete, b, { force = true })
    S.buf = nil
  end
end

--- Delete every agenda buffer (org-agenda-kill-all-agenda-buffers).
---@return integer number of buffers deleted
function M.kill_all_agenda_buffers()
  local bufs = {}
  for b in pairs(states) do
    bufs[#bufs + 1] = b
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == "orgagenda" and not vim.tbl_contains(bufs, b) then
      bufs[#bufs + 1] = b
    end
  end
  local n = 0
  for _, b in ipairs(bufs) do
    if vim.api.nvim_buf_is_valid(b) then
      if pcall(vim.api.nvim_buf_delete, b, { force = true }) then
        n = n + 1
      end
    end
  end
  return n
end

--- org-agenda-exit: quit, kill the agenda buffers and the unmodified
--- buffers the agenda loaded.
function M.exit()
  local loaded = {}
  for _, st in pairs(states) do
    for b in pairs(st.new_buffers or {}) do
      loaded[b] = true
    end
  end
  for b in pairs(M.state.new_buffers or {}) do
    loaded[b] = true
  end
  M.quit(true)
  for b in pairs(loaded) do
    if vim.api.nvim_buf_is_valid(b) and not vim.bo[b].modified and #vim.fn.win_findbuf(b) == 0 then
      pcall(vim.api.nvim_buf_delete, b, {})
    end
  end
end
