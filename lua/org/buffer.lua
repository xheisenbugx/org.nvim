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

--- With `insert_mode_line_in_empty_file`, an empty file whose name does not
--- make it an org file gets the Emacs mode line `-*- mode: org -*-` when
--- the org filetype is set on it (org-insert-mode-line-in-empty-file), so
--- that it opens as org from then on.
function M.insert_mode_line(bufnr)
  if not config.opts.insert_mode_line_in_empty_file or vim.bo[bufnr].buftype ~= "" then
    return
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or name:match("%.org$") or name:match("%.org_archive$") then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 1 and lines[1] == "" and vim.bo[bufnr].modifiable then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "#    -*- mode: org -*-", "" })
  end
end

--- Concealing for the buffer in window `win`: set with `:setlocal`, so
--- other buffers later shown in the window keep their own values.
local function set_win_opts(bufnr, win)
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    return
  end
  local wo = vim.wo[win][0]
  local ui = config.opts.ui
  local hides = ui.conceal_links or ui.hide_macro_markers or #(ui.hidden_keywords or {}) > 0
  local ok_ts, ts = pcall(require, "org.timestamps")
  if hides or (ok_ts and ts.custom_display_enabled(bufnr)) then
    wo.conceallevel = math.max(vim.wo[win].conceallevel, 2)
  end
  if vim.wo[win].concealcursor == "" then
    wo.concealcursor = "nc"
  end
end

-- What `attach` sets in a buffer, undone by `detach`.
local BUF_OPTS = {
  "commentstring",
  "comments",
  "formatoptions",
  "formatlistpat",
  "omnifunc",
  "indentexpr",
  "indentkeys",
  "formatexpr",
  "expandtab",
  "textwidth",
}
local WIN_OPTS = { "foldmethod", "foldexpr", "foldtext", "conceallevel", "concealcursor" }

--- Called from ftplugin/org.lua for every org buffer.
function M.attach(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  if vim.b[bufnr].org_attached then
    return
  end
  vim.b[bufnr].org_attached = true
  require("org").ensure_setup()
  require("org.highlights").ensure()

  local bo = vim.bo[bufnr]
  M.insert_mode_line(bufnr)
  bo.commentstring = "# %s"
  bo.comments = "fb:*,fb:-,fb:+,b:#,b:\\:"
  bo.formatoptions = bo.formatoptions:gsub("[tc]", "") .. "nql"
  bo.formatlistpat = [[^\s*\(\(\d\+\|\a\)[.)]\|[-+]\|\s\+\*\)\s\+\(\[[ xX-]\]\s\+\)\?]]
  bo.omnifunc = "v:lua.require'org.completion'.omnifunc"
  -- org-indent-line / org-fill-paragraph
  bo.indentexpr = "v:lua.require'org.indent'.indentexpr()"
  bo.indentkeys = "o,O,!^F"
  bo.formatexpr = "v:lua.require'org.fill'.formatexpr()"
  bo.expandtab = true
  bo.textwidth = bo.textwidth ~= 0 and bo.textwidth or 0

  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    set_win_opts(bufnr, win)
  end
  local group = vim.api.nvim_create_augroup("org.buffer." .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = bufnr,
    callback = function()
      set_win_opts(bufnr, vim.api.nvim_get_current_win())
    end,
  })
  -- motions skip concealed link markup, like Emacs' invisible text
  try("org.ui.conceal_cursor", "attach", bufnr, group)

  try("org.fold", "setup_buffer", bufnr)
  require("org.mappings").attach(bufnr)
  try("org.ui.decorations", "attach", bufnr)
  try("org.ui.src_highlight", "attach", bufnr)
  try("org.cite", "attach", bufnr)
  try("org.table", "attach", bufnr)
  try("org.clock", "attach", bufnr)
  try("org.crypt", "attach", bufnr)
  try("org.speed", "attach", bufnr)
  -- #+STARTUP: linkpreviews / latexpreview, ui.images.startup
  try("org.ui.images", "setup_buffer", bufnr)
  -- startup_with_beamer_mode, #+STARTUP: beamer
  try("org.export.beamer_mode", "setup_buffer", bufnr)
  -- custom timestamp display (display_custom_times, #+STARTUP: customtime)
  local ok_ts, ts = pcall(require, "org.timestamps")
  if ok_ts and ts.custom_display_enabled(bufnr) then
    try("org.timestamps", "attach_custom_display", bufnr)
  end

  local undo = "lua require('org.buffer').detach(" .. bufnr .. ")"
  local prev = vim.b[bufnr].undo_ftplugin
  -- (a leading "|" would be an empty command, which prints the line)
  vim.b[bufnr].undo_ftplugin = (prev and prev ~= "") and (prev .. " | " .. undo) or undo
end

--- Undo `attach` (b:undo_ftplugin, when the filetype changes): the
--- buffer's options, mappings, folds and decorations go back to what any
--- other buffer has (Emacs: kill-all-local-variables).
function M.detach(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.b[bufnr].org_attached = nil
  for _, name in ipairs(BUF_OPTS) do
    vim.bo[bufnr][name] = vim.api.nvim_get_option_value(name, { scope = "global" })
  end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    for _, name in ipairs(WIN_OPTS) do
      vim.wo[win][0][name] = vim.api.nvim_get_option_value(name, { scope = "global" })
    end
  end
  for _, r in ipairs(vim.b[bufnr].org_keymaps or {}) do
    pcall(vim.keymap.del, r[1], r[2], { buffer = bufnr })
  end
  vim.b[bufnr].org_keymaps = nil
  for _, group in ipairs({ "org.buffer.", "org.fold." }) do
    pcall(vim.api.nvim_del_augroup_by_name, group .. bufnr)
  end
  try("org.ui.decorations", "detach", bufnr)
  try("org.ui.src_highlight", "detach", bufnr)
end

--- Re-read in-buffer settings (#+TODO etc.) and refresh syntax/folds.
function M.refresh(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  -- (first: a parser installed since is found by the syntax below)
  try("org.ui.src_highlight", "refresh", bufnr)
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("syntax clear")
    vim.b.current_syntax = nil
    vim.cmd("runtime! syntax/org.lua")
  end)
  require("org.fold").refresh(bufnr)
  try("org.ui.decorations", "refresh", bufnr)
end

return M
