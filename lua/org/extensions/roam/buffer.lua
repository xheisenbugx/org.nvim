---@mod org.extensions.roam.buffer The backlinks buffer (org-roam-buffer)
---
--- A side window listing the backlinks and reflinks of the node at point,
--- each with a preview of the text around the link. It follows the cursor
--- through org buffers while it is open. `<CR>` opens a link's location in
--- the window it was toggled from, `r` refreshes, `q` closes.

local db = require("org.extensions.roam.db")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

local state = { buf = nil, win = nil, id = nil, targets = {} }
local ns = vim.api.nvim_create_namespace("org.roam.buffer")
local group = vim.api.nvim_create_augroup("org.roam.buffer", { clear = true })

local function bopts()
  local o = require("org.extensions").opts("roam") or require("org.extensions.roam").defaults
  return o.buffer or {}
end

local function valid_win()
  return state.win
    and vim.api.nvim_win_is_valid(state.win)
    and state.buf
    and vim.api.nvim_win_get_buf(state.win) == state.buf
end

--- Whether the roam buffer is shown.
---@return boolean
function M.is_open()
  return valid_win() and true or false
end

local function file_lines(path)
  local b = utils.find_buffer(path)
  if b then
    return files.get_buffer(b)
  end
  return files.get(path)
end

--- The text around a link: its paragraph (or list item), up to
--- `buffer.preview_lines` lines.
---@param file org.File
---@param lnum integer
---@return string[]
function M.preview(file, lnum)
  local lines = file.lines
  local max = bopts().preview_lines or 5
  -- the paragraph ends at a blank line, a headline, a drawer line and a
  -- keyword, block delimiter or comment line (#+title: ... before it)
  local function stop(l)
    return l == nil
      or l:match("^%s*$")
      or l:match("^%*+%s")
      or l:match("^%s*:%u+:%s*$")
      or l:match("^%s*#%+")
      or l:match("^%s*#%s")
      or l:match("^%s*#$")
  end
  local s, e = lnum, lnum
  while s > 1 and not stop(lines[s - 1]) and not (lines[s] or ""):match("^%s*[-+]%s") do
    s = s - 1
  end
  while e < #lines and not stop(lines[e + 1]) and not lines[e + 1]:match("^%s*[-+*]%s") do
    e = e + 1
  end
  if e - s + 1 > max then
    -- keep the link's line in view
    s = math.max(s, lnum - math.floor(max / 2))
    e = math.min(e, s + max - 1)
  end
  local out = {}
  for i = s, e do
    out[#out + 1] = vim.trim(lines[i])
  end
  return out
end

local function outline(file, lnum)
  local hl = file:headline_at(lnum)
  if not hl then
    return "Top"
  end
  local olp = hl:outline_path()
  olp[#olp + 1] = hl:plain_title()
  return table.concat(olp, " > ")
end

-- preview text as Org shows it: links as their descriptions
local function display(text)
  return require("org.links").display_format(text)
end

local function render(node)
  local lines, hls, targets = {}, {}, {}
  local function add(text, hl, target)
    lines[#lines + 1] = text
    if hl then
      hls[#hls + 1] = { #lines - 1, hl }
    end
    targets[#lines] = target
  end
  if not node then
    add("No node at point", "Comment")
  else
    add(node.title, "Title", { file = node.file, lnum = node.lnum })
    add("")
    local builders = {
      backlinks = function()
        return "Backlinks", db.backlinks(node.id)
      end,
      reflinks = function()
        return "Reflinks", db.reflinks(node)
      end,
    }
    for _, key in ipairs(bopts().sections or { "backlinks", "reflinks" }) do
      if key == "unlinked" or key == "unlinked_references" then
        local refs = db.unlinked_references(node)
        add(string.format("Unlinked references (%d)", #refs), "Statement")
        for _, r in ipairs(refs) do
          local where = string.format("%s:%d:%d", vim.fn.fnamemodify(r.file, ":t:r"), r.lnum, r.col)
          local target = { file = r.file, lnum = r.lnum, col = r.col }
          add("  " .. where .. "  " .. display(vim.trim(r.text)), nil, target)
          hls[#hls + 1] = { #lines - 1, "Comment", 2, 2 + #where }
        end
        add("")
      end
      local builder = builders[key]
      if builder then
        local name, list = builder()
        add(string.format("%s (%d)", name, #list), "Statement")
        table.sort(list, function(a, b)
          if a.source.title ~= b.source.title then
            return a.source.title < b.source.title
          end
          return a.link.lnum < b.link.lnum
        end)
        local last
        for _, item in ipairs(list) do
          local target = { file = item.link.file, lnum = item.link.lnum, col = item.link.col }
          if last ~= item.source.id then
            add("  " .. item.source.title, "Directory", { file = item.source.file, lnum = item.source.lnum })
            last = item.source.id
          end
          local f = file_lines(item.link.file)
          if f then
            add("    " .. outline(f, item.link.lnum), "Comment", target)
            for _, p in ipairs(M.preview(f, item.link.lnum)) do
              add("      " .. display(p), nil, target)
            end
          end
        end
        add("")
      end
    end
  end
  local buf = state.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    if h[3] then
      vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[3], { end_col = h[4], hl_group = h[2] })
    else
      vim.api.nvim_buf_set_extmark(buf, ns, h[1], 0, { end_row = h[1] + 1, hl_group = h[2], hl_eol = false })
    end
  end
  state.targets = targets
end

--- Show the links of the node in `bufnr` at `lnum` (default: the current
--- window's cursor).
---@param force? boolean redraw even when the node did not change
function M.redisplay(force)
  if not valid_win() then
    return
  end
  local cur = vim.api.nvim_get_current_buf()
  if cur == state.buf or vim.bo[cur].filetype ~= "org" then
    return
  end
  local here = require("org.extensions.roam.node").at_point(cur)
  local id = here and here.id or nil
  if not force and id == state.id then
    return
  end
  state.id = id
  state.source_win = vim.api.nvim_get_current_win()
  local node = id and db.node(id)
  if here and not node then
    -- not indexed yet (unsaved, or outside the roam directory)
    local path = vim.api.nvim_buf_get_name(cur)
    local title = here.hl and here.hl:plain_title() or here.file:title()
    node = { id = id, title = title, file = path, lnum = here.lnum or 1, refs = {}, aliases = {}, tags = {}, olp = {} }
    node.refs = db.split_quoted((here.hl and here.hl.properties or here.file.properties).ROAM_REFS)
  end
  render(node)
end

local function jump()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local t = state.targets[row]
  if not t then
    return
  end
  local win = state.source_win
  if not (win and vim.api.nvim_win_is_valid(win)) or win == state.win then
    vim.cmd("wincmd p")
  else
    vim.api.nvim_set_current_win(win)
  end
  if vim.api.nvim_get_current_win() == state.win then
    -- no other window: open one beside this one rather than replacing the
    -- links with the note
    local o = bopts()
    local width = vim.api.nvim_win_get_width(state.win)
    local height = vim.api.nvim_win_get_height(state.win)
    local split = o.position == "bottom" and "aboveleft split"
      or o.position == "left" and "rightbelow vsplit"
      or "aboveleft vsplit"
    vim.cmd(split)
    if o.position == "bottom" then
      vim.api.nvim_win_set_height(state.win, math.min(o.height or 15, math.floor(height / 2)))
    else
      vim.api.nvim_win_set_width(state.win, math.min(o.width or 50, math.floor(width / 2)))
    end
  end
  require("org.extensions.roam.node").open(t.file, t.lnum, { col = t.col and math.max(0, t.col - 1) or 0 })
end

local function create_buffer()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "org-roam")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "org-roam"
  vim.bo[buf].modifiable = false
  local map = function(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("<CR>", jump)
  map("<Esc>", M.close)
  map("r", function()
    db.sync()
    local win = state.source_win
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        M.redisplay(true)
      end)
    end
  end)
  state.buf = buf
  return buf
end

--- Close the roam window.
function M.close()
  if valid_win() then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
  state.id = nil
  vim.api.nvim_clear_autocmds({ group = group })
end

--- Close the roam window and delete its buffer (the extension is turned
--- off).
function M.wipe()
  M.close()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.buf = nil
  state.targets = {}
end

--- Open the roam window for the node at point, keeping the cursor where
--- it is.
function M.open()
  db.sync()
  local cur_win = vim.api.nvim_get_current_win()
  local buf = create_buffer()
  if not valid_win() then
    local o = bopts()
    local pos = o.position == "left" and "topleft vertical"
      or o.position == "bottom" and "botright"
      or "botright vertical"
    local size = (o.position == "bottom" and o.height) or o.width or 50
    vim.cmd(pos .. " " .. size .. "split")
    state.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.win, buf)
    -- local to the window's buffer (:setlocal): a file opened in this
    -- window later gets the usual options back (but for winfix*, which
    -- belong to the window)
    local wopts = {
      number = false,
      relativenumber = false,
      signcolumn = "no",
      foldcolumn = "0",
      foldenable = false,
      spell = false,
      list = false,
      wrap = true,
      linebreak = true,
      -- wrapped preview lines stay under their heading
      breakindent = true,
      winfixwidth = o.position ~= "bottom",
      winfixheight = o.position == "bottom",
    }
    for name, value in pairs(wopts) do
      vim.api.nvim_set_option_value(name, value, { win = state.win, scope = "local" })
    end
    vim.api.nvim_set_current_win(cur_win)
  end
  vim.api.nvim_clear_autocmds({ group = group })
  vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
    group = group,
    callback = function()
      M.redisplay(false)
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function()
      vim.schedule(function()
        M.redisplay(true)
      end)
    end,
  })
  state.id = false
  M.redisplay(true)
end

--- Toggle the roam window (org-roam-buffer-toggle).
function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

--- For tests: the rendered lines.
---@return string[]
function M.lines()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return {}
  end
  return vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
end

return M
