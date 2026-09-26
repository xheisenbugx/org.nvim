---@mod org.buffer Per-buffer setup for org files

local config = require("org.config")
local utils = require("org.utils")

local M = {}

--- Safely call `module.fn(...)` if the module exists and defines it.
local function try(mod, fn, ...)
  local ok, m = pcall(require, mod)
  if ok and type(m[fn]) == "function" then
    local ok2, err = pcall(m[fn], ...)
    if not ok2 then
      utils.error(string.format("%s.%s: %s", mod, fn, err))
    end
  end
end

--- Called from ftplugin/org.lua for every org buffer.
function M.attach(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  if vim.b[bufnr].org_attached then
    return
  end
  vim.b[bufnr].org_attached = true
  require("org").ensure_setup()

  local bo = vim.bo[bufnr]
  bo.commentstring = "# %s"
  bo.comments = "fb:*,fb:-,fb:+,b:#,b:\\:"
  bo.formatoptions = bo.formatoptions:gsub("[tc]", "") .. "nql"
  bo.formatlistpat = [[^\s*\(\(\d\+\|\a\)[.)]\|[-+]\|\s\+\*\)\s\+\(\[[ xX-]\]\s\+\)\?]]
  bo.omnifunc = "v:lua.require'org.completion'.omnifunc"
  bo.expandtab = true
  bo.textwidth = bo.textwidth ~= 0 and bo.textwidth or 0

  vim.api.nvim_buf_call(bufnr, function()
    vim.wo.conceallevel = config.opts.ui.conceal_links and 2 or vim.wo.conceallevel
    vim.wo.concealcursor = vim.wo.concealcursor == "" and "nc" or vim.wo.concealcursor
  end)

  try("org.fold", "setup_buffer", bufnr)
  require("org.mappings").attach(bufnr)
  try("org.ui.decorations", "attach", bufnr)
  try("org.table", "attach", bufnr)
  try("org.clock", "attach", bufnr)
  try("org.crypt", "attach", bufnr)
  try("org.speed", "attach", bufnr)
  -- #+STARTUP: linkpreviews / latexpreview, ui.images.startup
  try("org.ui.images", "setup_buffer", bufnr)
  -- custom timestamp display (display_custom_times, #+STARTUP: customtime)
  local ok_ts, ts = pcall(require, "org.timestamps")
  if ok_ts and ts.custom_display_enabled(bufnr) then
    vim.api.nvim_buf_call(bufnr, function()
      vim.wo.conceallevel = math.max(vim.wo.conceallevel, 2)
    end)
    try("org.timestamps", "attach_custom_display", bufnr)
  end

  vim.b[bufnr].undo_ftplugin = (vim.b[bufnr].undo_ftplugin or "") .. "|lua require('org.buffer').detach(" .. bufnr .. ")"
end

function M.detach(bufnr)
  vim.b[bufnr].org_attached = nil
end

--- Re-read in-buffer settings (#+TODO etc.) and refresh syntax/folds.
function M.refresh(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("syntax clear")
    vim.b.current_syntax = nil
    vim.cmd("runtime! syntax/org.lua")
    vim.cmd("normal! zx")
  end)
  try("org.ui.decorations", "refresh", bufnr)
end

return M
