---@mod org.ui Floating windows and Emacs-style key menus

local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.ui")

--- Open a floating window with `lines`.
---@param lines string[]
---@param opts? { title?: string, width?: integer, height?: integer, enter?: boolean, filetype?: string, modifiable?: boolean, relative?: string, row?: integer, col?: integer, border?: string }
---@return integer buf, integer win
function M.float(lines, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end
  local width = opts.width
  if not width then
    width = 20
    for _, l in ipairs(lines) do
      width = math.max(width, utils.width(l) + 2)
    end
    if opts.title then
      width = math.max(width, utils.width(opts.title) + 4)
    end
  end
  width = math.min(width, vim.o.columns - 4)
  local height = math.min(opts.height or #lines, vim.o.lines - 4)
  height = math.max(height, 1)
  local win = vim.api.nvim_open_win(buf, opts.enter ~= false, {
    relative = opts.relative or "editor",
    width = width,
    height = height,
    row = opts.row or math.floor((vim.o.lines - height) / 2) - 1,
    col = opts.col or math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = opts.border or require("org.config").opts.win_border or "rounded",
    title = opts.title and (" " .. opts.title .. " ") or nil,
    title_pos = opts.title and "center" or nil,
    zindex = 60,
  })
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = opts.cursorline or false
  vim.bo[buf].modifiable = opts.modifiable or false
  return buf, win
end

---@class org.MenuItem
---@field key string single char (or multi-char in `from_keys`)
---@field label string
---@field value any
---@field items? org.MenuItem[] submenu
---@field heading? boolean non-selectable label row

--- Build a nested menu tree from items with multi-character keys.
--- An item whose key is a strict prefix of other keys becomes a submenu.
---@param entries org.MenuItem[]
---@return org.MenuItem[]
function M.tree_from_keys(entries)
  local root = {}
  local by_prefix = { [""] = root }
  table.sort(entries, function(a, b)
    if #a.key ~= #b.key then
      return #a.key < #b.key
    end
    return a.key < b.key
  end)
  for _, e in ipairs(entries) do
    local parent_key = e.key:sub(1, -2)
    local list = by_prefix[parent_key]
    if not list then
      -- create an implicit group
      local grp = { key = parent_key:sub(-1), label = parent_key .. "…", items = {} }
      local gp = by_prefix[parent_key:sub(1, -2)] or root
      table.insert(gp, grp)
      by_prefix[parent_key] = grp.items
      list = grp.items
    end
    local item = vim.tbl_extend("force", {}, e, { key = e.key:sub(-1) })
    if item.value == nil and not item.heading then
      item.items = item.items or {}
      by_prefix[e.key] = item.items
    end
    table.insert(list, item)
  end
  return root
end

--- Show a key-driven menu and return the selected item's value (or the
--- item when it has no value). Blocks until a key is pressed.
---@param opts { title: string, items: org.MenuItem[], footer?: string[] }
---@return any|nil
function M.menu(opts)
  local items = opts.items
  local title = opts.title
  while true do
    local lines, hls = {}, {}
    for _, it in ipairs(items) do
      if it.heading then
        lines[#lines + 1] = it.label
        hls[#hls + 1] = { #lines - 1, 0, -1, "Title" }
      else
        local suffix = it.items and " …" or ""
        lines[#lines + 1] = string.format(" [%s]  %s%s", it.key, it.label, suffix)
        hls[#hls + 1] = { #lines - 1, 1, 4, "Special" }
      end
    end
    for _, f in ipairs(opts.footer or {}) do
      lines[#lines + 1] = f
      hls[#hls + 1] = { #lines - 1, 0, -1, "Comment" }
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = " [Esc]  Quit"
    hls[#hls + 1] = { #lines - 1, 1, 6, "Comment" }
    local width = 40
    for _, l in ipairs(lines) do
      width = math.max(width, utils.width(l) + 2)
    end
    local buf, win = M.float(lines, { title = title, width = width })
    for _, h in ipairs(hls) do
      vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], {
        end_col = h[3] == -1 and #lines[h[1] + 1] or h[3],
        hl_group = h[4],
      })
    end
    vim.cmd("redraw")
    local ch = utils.getchar()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if not ch then
      return nil
    end
    local chosen
    for _, it in ipairs(items) do
      if not it.heading and it.key == ch then
        chosen = it
        break
      end
    end
    if not chosen then
      utils.warn("No menu entry for key: " .. ch)
      return nil
    end
    if chosen.items and chosen.value == nil then
      items = chosen.items
      title = title .. " › " .. chosen.label
    else
      if chosen.value ~= nil then
        return chosen.value
      end
      return chosen
    end
  end
end

--- Show a read-only help float listing key → description rows.
---@param title string
---@param rows { [1]: string, [2]: string }[]
function M.help(title, rows)
  local width = 0
  for _, r in ipairs(rows) do
    width = math.max(width, utils.width(r[1]))
  end
  local lines = {}
  for _, r in ipairs(rows) do
    lines[#lines + 1] = " " .. utils.pad_right(r[1], width) .. "   " .. r[2]
  end
  local buf, win = M.float(lines, { title = title, height = math.min(#lines, vim.o.lines - 6), cursorline = true })
  for i = 0, #lines - 1 do
    vim.api.nvim_buf_set_extmark(buf, ns, i, 1, { end_col = 1 + #rows[i + 1][1], hl_group = "Special" })
  end
  for _, k in ipairs({ "q", "<Esc>", "g?" }) do
    vim.keymap.set("n", k, function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end, { buffer = buf, nowait = true })
  end
  return buf, win
end

--- Open a buffer in a window according to `mode`.
---@param buf integer
---@param mode "float"|"split"|"vsplit"|"tab"|"current"|nil
---@param opts? { title?: string, width?: number, height?: number }
---@return integer win
function M.open_buffer_window(buf, mode, opts)
  opts = opts or {}
  mode = mode or require("org.config").opts.win_split_mode or "float"
  if mode == "float" then
    local width = math.floor(vim.o.columns * (opts.width or 0.8))
    local height = math.floor(vim.o.lines * (opts.height or 0.7))
    return vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2) - 1,
      col = math.floor((vim.o.columns - width) / 2),
      border = require("org.config").opts.win_border or "rounded",
      title = opts.title and (" " .. opts.title .. " ") or nil,
      title_pos = opts.title and "center" or nil,
      zindex = 50,
    })
  elseif mode == "split" then
    vim.cmd("botright split")
  elseif mode == "vsplit" then
    vim.cmd("botright vsplit")
  elseif mode == "tab" then
    vim.cmd("tabnew")
  end
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  return win
end

return M
