---@mod org.special Edit a region of an org buffer in a separate buffer
---
--- Used by `edit_special` (src blocks, tables formulas) and narrowing.
--- The source range is tracked with extmarks, so edits elsewhere in the
--- source buffer while the special buffer is open are safe. `:w` in the
--- special buffer writes back; the configured `save_exit` / `abort`
--- mappings leave it.

local config = require("org.config")
local ui = require("org.ui")
local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.special")

---@class org.SpecialOpts
---@field source_buf integer
---@field start_line integer first line of the edited region (1-based)
---@field end_line integer last line (inclusive); may be start_line-1 for an empty region
---@field lines string[] initial content of the edit buffer
---@field filetype? string
---@field name? string buffer name suffix
---@field to_source? fun(lines: string[]): string[] transform before writing back
---@field on_close? fun()
---@field window? string

---@param opts org.SpecialOpts
function M.open(opts)
  local src = opts.source_buf
  -- extmarks around the region: start mark before the first line,
  -- end mark at the end of the last line
  local sm = vim.api.nvim_buf_set_extmark(src, ns, opts.start_line - 1, 0, { right_gravity = false })
  local end_row = math.max(opts.end_line, opts.start_line - 1)
  local em
  if opts.end_line >= opts.start_line then
    local last = vim.api.nvim_buf_get_lines(src, end_row - 1, end_row, false)[1] or ""
    em = vim.api.nvim_buf_set_extmark(src, ns, end_row - 1, #last, { right_gravity = true })
  end
  local empty_region = opts.end_line < opts.start_line

  local buf = vim.api.nvim_create_buf(false, false)
  local base = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(src), ":t")
  pcall(vim.api.nvim_buf_set_name, buf, string.format("org-special://%s/%s#%d", base, opts.name or "edit", buf))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modified = false
  if opts.filetype and opts.filetype ~= "" then
    local ft = vim.filetype.match({ filename = "x." .. opts.filetype }) or opts.filetype
    vim.bo[buf].filetype = ft
  end

  local function region()
    local s = vim.api.nvim_buf_get_extmark_by_id(src, ns, sm, {})
    if empty_region then
      return s[1] + 1, s[1]
    end
    local e = vim.api.nvim_buf_get_extmark_by_id(src, ns, em, {})
    return s[1] + 1, e[1] + 1
  end

  local function write_back()
    if not vim.api.nvim_buf_is_valid(src) then
      utils.error("Source buffer no longer exists")
      return false
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if opts.to_source then
      lines = opts.to_source(lines)
    end
    local s, e = region()
    vim.api.nvim_buf_set_lines(src, s - 1, e, false, lines)
    -- re-anchor marks on the new region
    vim.api.nvim_buf_del_extmark(src, ns, sm)
    sm = vim.api.nvim_buf_set_extmark(src, ns, s - 1, 0, { right_gravity = false })
    if #lines > 0 then
      local last_row = s - 1 + #lines - 1
      local last = vim.api.nvim_buf_get_lines(src, last_row, last_row + 1, false)[1] or ""
      if em then
        vim.api.nvim_buf_del_extmark(src, ns, em)
      end
      em = vim.api.nvim_buf_set_extmark(src, ns, last_row, #last, { right_gravity = true })
      empty_region = false
    else
      empty_region = true
    end
    vim.bo[buf].modified = false
    return true
  end

  local closed = false
  local function cleanup()
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_buf_is_valid(src) then
      pcall(vim.api.nvim_buf_del_extmark, src, ns, sm)
      if em then
        pcall(vim.api.nvim_buf_del_extmark, src, ns, em)
      end
    end
    if opts.on_close then
      opts.on_close()
    end
  end

  local win = ui.open_buffer_window(buf, opts.window or config.opts.win_split_mode, { title = opts.name })
  local prev_win = vim.fn.win_getid(vim.fn.winnr("#"))

  local function close()
    cleanup()
    if vim.api.nvim_win_is_valid(win) then
      if #vim.api.nvim_list_wins() > 1 then
        vim.api.nvim_win_close(win, true)
      else
        vim.api.nvim_set_current_buf(src)
      end
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    if prev_win and vim.api.nvim_win_is_valid(prev_win) then
      pcall(vim.api.nvim_set_current_win, prev_win)
    end
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      write_back()
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = cleanup,
  })

  local maps = config.opts.mappings.edit_src or {}
  for _, lhs in ipairs(config.lhs_list(maps.save_exit)) do
    vim.keymap.set("n", lhs, function()
      if vim.bo[buf].modified then
        write_back()
      end
      close()
    end, { buffer = buf, desc = "org: save and exit edit buffer" })
  end
  for _, lhs in ipairs(config.lhs_list(maps.abort)) do
    vim.keymap.set("n", lhs, function()
      vim.bo[buf].modified = false
      close()
    end, { buffer = buf, desc = "org: abort edit buffer" })
  end
  vim.b[buf].org_special = true
  return buf, win
end

return M
