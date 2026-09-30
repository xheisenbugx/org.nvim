---@mod org.extensions.transclusion.edit Editing a transclusion's source
---
--- The source lines of a transclusion open in a float (or a split) whose
--- `:write` puts them back into the source: its buffer when it is loaded
--- (written too when it had no other unsaved changes), else the file on
--- disk. Every transclusion of that source is then shown again. With
--- `live`, the text goes into the source buffer as you type (loaded for
--- the purpose when it isn't), like org-transclusion-live-sync.

local source = require("org.extensions.transclusion.source")
local utils = require("org.utils")

local M = {}

--- edit buffer -> { path, bufnr, first, last, orig, spec, ctx, live }
M.edits = {}

--- Called with the source path after a write (set by init.lua).
---@type fun(path: string|nil, bufnr: integer|nil)
M.on_written = function() end

--- Debounced call (set by init.lua): later(key, fn).
---@type fun(key: string, fn: function)
M.later = function(_, fn)
  vim.schedule(fn)
end

local counter = 0

local function float_config(o, lines, title)
  local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local w = o.width or 0.8
  if w <= 1 then
    w = math.floor(cols * w)
  end
  w = math.max(20, math.min(cols - 4, w))
  local maxh = o.height or 0.7
  if maxh <= 1 then
    maxh = math.floor(rows * maxh)
  end
  local h = math.max(3, math.min(maxh, #lines + 1, rows - 4))
  return {
    relative = "editor",
    row = math.floor((rows - h) / 2) - 1,
    col = math.floor((cols - w) / 2),
    width = w,
    height = h,
    style = "minimal",
    border = o.border or "rounded",
    title = title,
    title_pos = "center",
    zindex = 45,
  }
end

--- Open the source of `res` for editing.
---@param res org.transclusion.Result
---@param spec org.transclusion.Spec
---@param ctx org.transclusion.Context
---@param o table the extension's `edit` options
---@return integer buf, integer win
function M.open(res, spec, ctx, o)
  o = o or {}
  counter = counter + 1
  local b = vim.api.nvim_create_buf(false, true)
  local where = res.path and vim.fn.fnamemodify(res.path, ":~:.") or "buffer"
  vim.api.nvim_buf_set_name(b, string.format("org-transclusion://%s:%d-%d#%d", where, res.first, res.last, counter))
  vim.api.nvim_buf_set_lines(b, 0, -1, false, res.raw)
  vim.bo[b].buftype = "acwrite"
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].swapfile = false
  if res.path then
    vim.b[b].org_base_dir = vim.fn.fnamemodify(res.path, ":h")
  end
  M.edits[b] = {
    path = res.path,
    bufnr = not res.path and res.bufnr or nil,
    first = res.first,
    last = res.last,
    orig = vim.deepcopy(res.raw),
    spec = spec,
    ctx = ctx,
    live = o.live and true or false,
  }
  local ft = "org"
  if res.kind ~= "org" then
    ft = res.lang and (vim.filetype.match({ filename = "x." .. res.lang }) or res.lang) or ""
  end
  local title = string.format(" %s  ·  :w writes the source  ·  <Esc> closes ", res.label)
  local win
  if (o.window or "float") == "float" then
    win = vim.api.nvim_open_win(b, true, float_config(o, res.raw, title))
    vim.wo[win].number = true
    vim.wo[win].cursorline = true
  else
    vim.cmd(o.window)
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, b)
  end
  vim.bo[b].filetype = ft
  vim.bo[b].modified = false
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = b,
    callback = function()
      M.write(b)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = b,
    callback = function()
      M.edits[b] = nil
    end,
  })
  if M.edits[b].live then
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      buffer = b,
      callback = function()
        M.later("edit:" .. b, function()
          if M.edits[b] and vim.api.nvim_buf_is_valid(b) then
            M.write(b, true)
          end
        end)
      end,
    })
  end
  -- <Esc> closes (in Normal mode; Insert mode keeps its <Esc>), never
  -- dropping unwritten text
  vim.keymap.set("n", "<Esc>", function()
    if vim.bo[b].modified then
      utils.warn("Unsaved changes: :w writes them to the source, :q! drops them")
      return
    end
    M.close(b)
  end, { buffer = b, nowait = true, desc = "org: close the transclusion source" })
  return b, win
end

function M.close(b)
  for _, w in ipairs(vim.fn.win_findbuf(b)) do
    if #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  if vim.api.nvim_buf_is_valid(b) then
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
end

--- Close the edit windows without unwritten changes (the extension is
--- turned off); the others stay, and `:w` still works in them.
function M.close_all()
  for b in pairs(M.edits) do
    if vim.api.nvim_buf_is_valid(b) and not vim.bo[b].modified then
      M.close(b)
    end
  end
end

-- Write `lines` over the file at `path`, keeping its line endings, byte
-- order mark and final newline (or its lack).
local function write_file(path, lines)
  local fd = io.open(path, "rb")
  local old = fd and fd:read("*a") or ""
  if fd then
    fd:close()
  end
  local eol = old:find("\r\n", 1, true) and "\r\n" or "\n"
  local final = old == "" or old:sub(-1) == "\n"
  local bom = old:sub(1, 3) == "\239\187\191" and lines[1] and lines[1]:sub(1, 3) ~= "\239\187\191"
  local out, err = io.open(path, "wb")
  if not out then
    error("cannot write " .. path .. ": " .. tostring(err), 0)
  end
  if bom then
    out:write("\239\187\191")
  end
  out:write(table.concat(lines, eol))
  if #lines > 0 and final then
    out:write(eol)
  end
  out:close()
end

-- Replace lines `old` of `buf` from 0-based row `row` by `new`, changing
-- only the lines that differ: marks on the others (a keyword's) stay.
local function replace_lines(buf, row, old, new)
  local diff = (vim.text and vim.text.diff) or vim.diff
  local ok, hunks = pcall(diff, table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n", {
    result_type = "indices",
  })
  if not ok or type(hunks) ~= "table" then
    hunks = { { 1, #old, 1, #new } }
  end
  for i = #hunks, 1, -1 do
    local h = hunks[i]
    local start = h[2] == 0 and h[1] or h[1] - 1
    vim.api.nvim_buf_set_lines(buf, row + start, row + start + h[2], false, vim.list_slice(new, h[3], h[3] + h[4] - 1))
  end
end

--- Write the edit buffer `b` back into its source. With `sync` (live
--- editing), the text only goes into the source buffer, loaded when it
--- isn't; nothing is written to disk.
---@param b integer
---@param sync? boolean
---@return boolean ok
function M.write(b, sync)
  local e = M.edits[b]
  if not e then
    return false
  end
  local new = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  if sync and vim.deep_equal(new, e.orig) then
    return true
  end
  local lines, sb = source.read(e.path, e.bufnr)
  if sync and not sb and e.path and lines then
    local nb = vim.fn.bufadd(e.path)
    vim.fn.bufload(nb)
    lines, sb = source.read(e.path, e.bufnr)
  end
  if not lines then
    utils.error("transclusion: cannot read the source")
    return false
  end
  local first, last = e.first, e.last
  if not vim.deep_equal(vim.list_slice(lines, first, last), e.orig) then
    -- the source moved: find the same text again
    local r = source.resolve(e.spec, e.ctx)
    if r and vim.deep_equal(r.raw, e.orig) then
      first, last = r.first, r.last
    else
      if not sync or not e.warned then
        utils.error("transclusion: the source changed since it was opened; reopen it to edit")
      end
      e.warned = true
      return false
    end
  end
  if sb then
    if e.src_modified == nil then
      -- whether the source had changes of its own before this edit
      e.src_modified = vim.bo[sb].modified
    end
    -- The source's own inserted transclusions are taken out meanwhile:
    -- its lines are then the ones `first` and `last` count, and the
    -- write (in BufWriteCmd, where autocommands don't nest) leaves them
    -- out of the file.
    local t = package.loaded["org.extensions.transclusion"]
    local without = t and t.without_inserted or function(_, fn)
      return fn()
    end
    local wrote = false
    local ok, err = pcall(without, sb, function()
      replace_lines(sb, first - 1, vim.list_slice(lines, first, last), new)
      if not sync and not e.src_modified and vim.api.nvim_buf_get_name(sb) ~= "" then
        vim.api.nvim_buf_call(sb, function()
          vim.cmd("silent keepalt write")
        end)
        wrote = true
      end
    end)
    if not ok then
      utils.error("transclusion: cannot write the source: " .. tostring(err))
      return false
    end
    if wrote then
      e.src_modified = nil
    elseif not sync then
      utils.notify("transclusion: source buffer updated (it had unsaved changes, so it was not written)")
    end
  else
    local out = vim.list_slice(lines, 1, first - 1)
    vim.list_extend(out, new)
    vim.list_extend(out, vim.list_slice(lines, last + 1, #lines))
    local ok, err = pcall(write_file, e.path, out)
    if not ok then
      utils.error("transclusion: " .. tostring(err))
      return false
    end
    source.clear_cache(e.path)
    require("org.files").invalidate(e.path)
  end
  e.first, e.last = first, first + #new - 1
  e.orig = vim.deepcopy(new)
  e.warned = nil
  if not sync then
    vim.bo[b].modified = false
  end
  M.on_written(e.path, sb)
  return true
end

return M
