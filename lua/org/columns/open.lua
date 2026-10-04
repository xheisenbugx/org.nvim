---@mod org.columns.open Opening the column view
---
--- Its keys, quitting, and opening the view (org-columns).
--- Part of org.columns, which loads it.

local config = require("org.config")
local utils = require("org.utils")
local shared = require("org.columns.shared")

local M = require("org.columns")

local READ_ONLY = shared.READ_ONLY
local current = shared.current
local delete_column = shared.delete_column
local edit_allowed = shared.edit_allowed
local edit_cell = shared.edit_cell
local move_column = shared.move_column
local move_row = shared.move_row
local new_column = shared.new_column
local next_allowed = shared.next_allowed
local ns = shared.ns
local ns_ov = shared.ns_ov
local overlay_current = shared.overlay_current
local overlay_goto = shared.overlay_goto
local overlay_render = shared.overlay_render
local refresh = shared.refresh
local render = shared.render
local sync_menus = shared.sync_menus
local update_winbar = shared.update_winbar
local views = shared.views
local widen = shared.widen

--- Bind the column view keys with `map(lhs, fn, desc)`; `quit` leaves the
--- view.
local function bind_keys(state, map, quit)
  --- Mapping callback running `fn(state, ...)` in a coroutine (prompts).
  local function run(fn, ...)
    local args = { ... }
    return function()
      utils.run(fn, state, unpack(args))
    end
  end
  map("q", quit, "quit")
  map({ "r", "g" }, function()
    refresh(state)
  end, "refresh")
  map("e", run(edit_cell), "edit value")
  map({ "n", "<S-Right>" }, run(next_allowed, 1), "next allowed value")
  map({ "p", "<S-Left>" }, run(next_allowed, -1), "previous allowed value")
  map("a", run(edit_allowed), "edit allowed values")
  -- 1..9 pick the Nth allowed value (org-columns-next-allowed-value); 0
  -- keeps its Vim meaning
  for i = 1, 9 do
    map(tostring(i), run(next_allowed, 1, i), "allowed value " .. i)
  end
  map("<C-c><C-o>", function()
    local r, ci = current(state)
    if not r then
      return
    end
    local value = r.cells[ci] or ""
    local target = value:match("%[%[(.-)%]%]") or value:match("%[%[(.-)%]%[") or value:match("%a[%w+.-]*:%S+")
    if target then
      target = target:match("^(.-)%]%[") or target
      if state.mode ~= "overlay" then
        vim.cmd("wincmd p")
      end
      require("org.links").open(target, { bufnr = state.src })
    else
      utils.warn("No link in this field")
    end
  end, "open link")
  map("s", run(new_column, true), "edit column attributes")
  map({ "<M-S-Right>", "<M-L>" }, run(new_column, false), "new column")
  map({ "<M-S-Left>", "<M-H>" }, run(delete_column), "delete column")
  map({ "<M-Right>", "<M-l>" }, run(move_column, 1), "move column right")
  map({ "<M-Left>", "<M-h>" }, run(move_column, -1), "move column left")
  map({ "<M-Up>", "<M-k>" }, run(move_row, -1), "move row up")
  map({ "<M-Down>", "<M-j>" }, run(move_row, 1), "move row down")
  map(">", function()
    utils.run(widen, state, math.max(vim.v.count, 1))
  end, "widen column")
  map("<", function()
    utils.run(widen, state, -math.max(vim.v.count, 1))
  end, "narrow column")
  map("<C-c><C-c>", function()
    local r, ci = current(state)
    if r and vim.trim(r.cells[ci] or ""):match("^%[[ xX%-]%]$") then
      utils.run(next_allowed, state, 1)
    else
      quit()
    end
  end, "toggle checkbox or quit")
  map("<C-c><C-t>", function()
    local r = current(state)
    if r then
      utils.run(function()
        require("org.todo").select_or_cycle({ bufnr = state.src, lnum = r.hl.line })
        refresh(state)
      end)
    end
  end, "change TODO state")
  map("v", function()
    local r, ci = current(state)
    if r then
      utils.notify(state.cols[ci].title .. ": " .. (r.cells[ci] or ""))
    end
  end, "show value")
end

--- Remove the overlay view of `state`: its overlays, winbar and window
--- options and its keys (the buffer's own mappings come back).
local function quit_overlay(state)
  if views[state.src] ~= state then
    return
  end
  views[state.src] = nil
  vim.schedule(sync_menus)
  pcall(vim.api.nvim_del_augroup_by_id, state.group)
  local src = state.src
  if vim.api.nvim_buf_is_valid(src) then
    vim.api.nvim_buf_clear_namespace(src, ns_ov, 0, -1)
    pcall(vim.api.nvim_buf_del_extmark, src, ns, state.mark)
    for _, lhs in ipairs(state.lhs or {}) do
      pcall(vim.keymap.del, "n", lhs, { buffer = src })
    end
    vim.api.nvim_buf_call(src, function()
      for _, m in pairs(state.saved_maps or {}) do
        if m.buffer == 1 then
          pcall(vim.fn.mapset, "n", false, m)
        end
      end
    end)
    require("org.ui.decorations").render(src)
  end
  if state.saved_opts and vim.api.nvim_win_is_valid(state.win) then
    for name, value in pairs(state.saved_opts) do
      pcall(vim.api.nvim_set_option_value, name, value, { scope = "local", win = state.win })
    end
  end
end

--- Leave the overlay column view of `bufnr` (default: the current buffer).
function M.quit(bufnr)
  local state = views[bufnr or vim.api.nvim_get_current_buf()]
  if state then
    quit_overlay(state)
  end
end

--- Run action `idx` of the overlay view of `bufnr` (from its mappings).
function M._key(bufnr, idx)
  local state = views[bufnr]
  local fn = state and state.actions[idx]
  if fn then
    fn()
  end
end

--- Run the mapping that key `idx` of the overlay view of `bufnr` shadows
--- (the key was typed outside a column row).
function M._fallback(bufnr, idx)
  local state = views[bufnr]
  local m = state and state.saved_maps[idx]
  if not m then
    return
  end
  local keys
  if m.callback then
    keys = m.callback()
    keys = m.expr == 1 and type(keys) == "string" and keys or nil
  elseif m.rhs then
    keys = m.expr == 1 and vim.api.nvim_eval(m.rhs) or m.rhs
  end
  if type(keys) == "string" and keys ~= "" then
    vim.api.nvim_feedkeys(vim.keycode(keys), m.noremap == 1 and "n" or "m", false)
  end
end

--- A `map` for `bind_keys` in the org buffer: on a column row the key runs
--- its column view action (Emacs binds them on the overlays), elsewhere it
--- keeps its usual meaning.
local function overlay_mapper(state)
  local src = state.src
  state.actions, state.saved_maps, state.lhs = {}, {}, {}
  return function(lhs, fn, desc)
    for _, l in ipairs(type(lhs) == "table" and lhs or { lhs }) do
      local idx = #state.actions + 1
      state.actions[idx] = fn
      local prev = vim.fn.maparg(l, "n", false, true)
      if prev and prev.lhs then
        state.saved_maps[idx] = prev
      end
      state.lhs[#state.lhs + 1] = l
      vim.keymap.set("n", l, function()
        local st = views[src]
        if st and st.row_at and st.row_at[vim.api.nvim_win_get_cursor(0)[1]] then
          return string.format("<Cmd>lua require('org.columns')._key(%d, %d)<CR>", src, idx)
        elseif st and st.saved_maps[idx] then
          return string.format("<Cmd>lua require('org.columns')._fallback(%d, %d)<CR>", src, idx)
        end
        return l
      end, { buffer = src, expr = true, nowait = true, desc = "org columns: " .. desc })
    end
  end
end

--- Turn on the overlay view in the current window (Emacs org-columns).
local function open_overlay(src, lnum, global)
  if views[src] then
    quit_overlay(views[src])
  end
  local win = vim.api.nvim_get_current_win()
  local mark = vim.api.nvim_buf_set_extmark(src, ns, lnum - 1, 0, {})
  local state = { mode = "overlay", src = src, mark = mark, global = global, win = win }
  overlay_render(state, true)
  if #state.rows == 0 then
    vim.api.nvim_buf_clear_namespace(src, ns_ov, 0, -1)
    pcall(vim.api.nvim_buf_del_extmark, src, ns, mark)
    return nil
  end
  views[src] = state
  state.saved_opts = {}
  -- a headline with a closed fold (drawers, body) is drawn with Folded
  -- across the window, a band under its column row: Emacs shows none
  local whl = vim.api.nvim_get_option_value("winhighlight", { scope = "local", win = win })
  whl = (whl == "" and "" or whl .. ",") .. "Folded:Normal"
  for name, value in pairs({ wrap = false, virtualedit = "all", winbar = "", winhighlight = whl }) do
    state.saved_opts[name] = vim.api.nvim_get_option_value(name, { scope = "local", win = win })
    vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
  end
  update_winbar(state)
  require("org.ui.decorations").render(src)
  local map = overlay_mapper(state)
  bind_keys(state, map, function()
    quit_overlay(state)
  end)
  -- Emacs org-columns-content / org-overview
  map("c", function()
    require("org.fold").content()
  end, "contents view")
  map("o", function()
    require("org.fold").overview()
  end, "overview")
  -- Emacs puts one column on each character, so a motion moves by column
  local function step(dir)
    return function()
      local r, ci = overlay_current(state)
      if r then
        overlay_goto(state, r.hl.line, math.max(1, math.min(#state.cols, ci + dir * vim.v.count1)))
      end
    end
  end
  map({ "l", "<Right>", "w", "<Space>", "<M-f>" }, step(1), "next column")
  map({ "h", "<Left>", "b", "<BS>", "<M-b>" }, step(-1), "previous column")
  map("$", step(math.huge), "last column")
  -- the headline lines are read-only (Emacs gives them a read-only text
  -- property): the keys that change text only say so there
  local changes = { "i", "I", "A", "O", "C", "S", "x", "X", "d", "D", "R", "P", "J", "~", ".", "=", "!", "&" }
  vim.list_extend(changes, { "<Del>", "<Insert>", "<C-a>", "<C-x>" })
  map(changes, function()
    utils.warn(READ_ONLY)
  end, "read-only")
  local group = vim.api.nvim_create_augroup("org.columns.overlay." .. src, { clear = true })
  state.group = group
  -- any other way into Insert mode on a column row is turned back
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = src,
    callback = function()
      if views[src] == state and state.row_at[vim.api.nvim_win_get_cursor(0)[1]] then
        vim.cmd("stopinsert")
        utils.warn(READ_ONLY)
      end
    end,
  })
  -- keep the rows on their headlines when the text changes
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = group,
    buffer = src,
    callback = function()
      vim.schedule(function()
        if views[src] == state and vim.api.nvim_buf_is_valid(src) then
          overlay_render(state, false)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
    group = group,
    callback = function()
      if views[src] == state then
        update_winbar(state)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWinLeave", "BufWipeout", "BufUnload" }, {
    group = group,
    buffer = src,
    callback = function()
      quit_overlay(state)
    end,
  })
  sync_menus()
  return true
end

--- Open column view for the current buffer: over its headlines (Emacs
--- org-columns), or as a table in a split with `columns_view = "table"`.
---@param opts? { global?: boolean, view?: "overlay"|"table" } global (or
--- a count, like C-u in Emacs org-columns): the whole file, with the
--- file-level format; view: overrides `columns_view`
function M.open(opts)
  opts = opts or {}
  local global = opts.global or vim.v.count > 0
  local src = vim.api.nvim_get_current_buf()
  if vim.bo[src].filetype ~= "org" then
    utils.warn("Column view needs an org buffer")
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  if (opts.view or config.opts.columns_view) ~= "table" then
    return open_overlay(src, lnum, global)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "orgcolumns"
  local mark = vim.api.nvim_buf_set_extmark(src, ns, lnum - 1, 0, {})
  local state = { mode = "table", src = src, mark = mark, buf = buf, global = global }
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.wrap = false
  vim.wo.cursorline = true
  vim.wo.number = false
  vim.wo.relativenumber = false
  render(state)
  vim.api.nvim_win_set_height(0, math.min(#state.rows + 3, math.floor(vim.o.lines / 2)))
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if vim.api.nvim_buf_is_valid(src) then
        pcall(vim.api.nvim_buf_del_extmark, src, ns, mark)
      end
    end,
  })
  local function map(lhs, fn, desc)
    for _, l in ipairs(type(lhs) == "table" and lhs or { lhs }) do
      vim.keymap.set("n", l, fn, { buffer = buf, nowait = true, desc = "org columns: " .. desc })
    end
  end
  bind_keys(state, map, function()
    vim.api.nvim_win_close(0, true)
  end)
  map("<CR>", function()
    local r = current(state)
    if not r then
      return
    end
    local path = vim.api.nvim_buf_get_name(state.src)
    vim.cmd("wincmd p")
    if vim.api.nvim_get_current_buf() ~= state.src then
      utils.open_file(path, r.hl.line)
    else
      vim.api.nvim_win_set_cursor(0, { r.hl.line, 0 })
      vim.cmd("normal! zv")
    end
  end, "jump to headline")
  vim.api.nvim_win_set_cursor(0, { math.min(3, vim.api.nvim_buf_line_count(buf)), 0 })
  return true
end

return M
