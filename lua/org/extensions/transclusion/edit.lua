---@mod org.extensions.transclusion.edit Editing a transclusion's source
---
--- The source lines of a transclusion open in a float (or a split) whose
--- `:write` puts them back into the source: its buffer when it is loaded
--- (written too when it had no other unsaved changes), else the file on
--- disk. Every transclusion of that source is then shown again.

local source = require("org.extensions.transclusion.source")
local utils = require("org.utils")

local M = {}

--- edit buffer -> { path, bufnr, first, last, orig, spec, ctx }
M.edits = {}

--- Called with the source path after a write (set by init.lua).
---@type fun(path: string|nil, bufnr: integer|nil)
M.on_written = function() end

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
  }
  local ft = "org"
  if res.kind ~= "org" then
    ft = res.lang and (vim.filetype.match({ filename = "x." .. res.lang }) or res.lang) or ""
  end
  local title = string.format(" %s  ·  :w writes the source  ·  q closes ", res.label)
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
  vim.keymap.set("n", "q", function()
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

--- Write the edit buffer `b` back into its source.
---@param b integer
---@return boolean ok
function M.write(b)
  local e = M.edits[b]
  if not e then
    return false
  end
  local new = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local lines, sb, map = source.read(e.path, e.bufnr)
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
      utils.error("transclusion: the source changed since it was opened; reopen it to edit")
      return false
    end
  end
  if sb then
    local bf, bl = first, last
    if map then
      bf, bl = map[first] or first, map[last] or last
      if last >= first and bl - bf ~= last - first then
        utils.error("transclusion: the source region holds a materialized transclusion; remove it first")
        return false
      end
      if last < first then
        bf = map[first] or (#map > 0 and map[#map] + 1) or 1
        bl = bf - 1
      end
    end
    local was_modified = vim.bo[sb].modified
    vim.api.nvim_buf_set_lines(sb, bf - 1, bl, false, new)
    if not was_modified and vim.api.nvim_buf_get_name(sb) ~= "" then
      vim.api.nvim_buf_call(sb, function()
        vim.cmd("silent keepalt write")
      end)
    elseif was_modified then
      utils.notify("transclusion: source buffer updated (it had unsaved changes, so it was not written)")
    end
  else
    local out = vim.list_slice(lines, 1, first - 1)
    vim.list_extend(out, new)
    vim.list_extend(out, vim.list_slice(lines, last + 1, #lines))
    utils.writefile(e.path, out)
    source.clear_cache(e.path)
    require("org.files").invalidate(e.path)
  end
  e.first, e.last = first, first + #new - 1
  e.orig = vim.deepcopy(new)
  vim.bo[b].modified = false
  M.on_written(e.path, sb)
  return true
end

return M
