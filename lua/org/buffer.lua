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

--- Is the custom timestamp display on in `bufnr`? The buffer's toggle,
--- else `#+STARTUP: customtime`, else `display_custom_times`
--- (`org.timestamps.custom_display_enabled`; here so that opening a file
--- doesn't load org.timestamps).
---@param bufnr integer
---@return boolean
function M.custom_times(bufnr)
  local v = vim.b[bufnr].org_custom_times
  if v ~= nil then
    return v
  end
  local ok, file = pcall(require("org.files").get_buffer, bufnr)
  if ok and file.settings.startup.customtime then
    return true
  end
  return config.opts.display_custom_times == true
end

--- Whether the buffer starts with org-beamer-mode on
--- (`startup_with_beamer_mode`, `#+STARTUP: beamer`).
---@param bufnr integer
---@return boolean
function M.beamer_startup(bufnr)
  if config.opts.startup_with_beamer_mode == true then
    return true
  end
  local ok, file = pcall(require("org.files").get_buffer, bufnr)
  return ok and file and file.settings and file.settings.startup and file.settings.startup.beamer and true or false
end

-- Deferred vim.paste wrapper for dropped files (yank.dnd_paste): installed on
-- the first org buffer and loads `org.yank` only when pasting inside an org
-- buffer.
local function register_paste_hook()
  if M._paste_wrapped then
    return
  end
  local loaded_yank = package.loaded["org.yank"]
  if loaded_yank and loaded_yank._paste_wrapped then
    M._paste_wrapped = true
    return
  end
  M._paste_wrapped = true
  local orig = vim.paste
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.paste = function(lines, phase)
    if phase == -1 and vim.bo.filetype == "org" and (config.opts.yank or {}).dnd_paste ~= false then
      if require("org.yank").handle_paste(lines) then
        return true
      end
    end
    return orig(lines, phase)
  end
end

-- The crypt write hook (org-crypt-use-before-save-magic) until org.crypt
-- loads and registers its own under the same name: it loads org.crypt only
-- when `crypt.encrypt_on_save` is on at the time of a write.
local crypt_hook_registered = false
local function register_crypt_hook()
  if crypt_hook_registered or package.loaded["org.crypt"] then
    return
  end
  crypt_hook_registered = true
  require("org.write_hooks").register("crypt", {
    order = 50,
    filetype = "org",
    pre = function(bufnr)
      if not (config.opts.crypt or {}).encrypt_on_save then
        return true
      end
      return require("org.crypt").before_save(bufnr)
    end,
  })
end

-- OrgFileWritten (|org-api-events|): after every write of an org buffer,
-- by a write command or by org's own saves (`utils.save_buffer`, which
-- runs no BufWritePost), so a listener sees both alike.
local written_hook_registered = false
local function register_written_hook()
  if written_hook_registered then
    return
  end
  written_hook_registered = true
  require("org.write_hooks").register("org.written", {
    order = 95,
    filetype = "org",
    post = function(bufnr, ctx)
      if ctx.ok then
        require("org.utils").user_event(
          "OrgFileWritten",
          { bufnr = bufnr, file = vim.api.nvim_buf_get_name(bufnr), source = ctx.source }
        )
      end
    end,
  })
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
  if hides or M.custom_times(bufnr) then
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
  try("org.cite.attach", "attach", bufnr)
  -- mini.ai, snacks.nvim scopes and flash.nvim, when they are loaded
  try("org.integrations", "attach", bufnr)
  -- (the attach parts of the larger modules, which load on first use)
  try("org.table.attach", "attach", bufnr)
  try("org.clock.attach", "attach", bufnr)
  register_paste_hook()
  register_crypt_hook()
  register_written_hook()
  -- speed commands (org.speed.attach): the module loads on a character
  -- typed while `use_speed_commands` is on
  vim.api.nvim_create_autocmd("InsertCharPre", {
    buffer = bufnr,
    group = vim.api.nvim_create_augroup("org.speed." .. bufnr, { clear = true }),
    callback = function()
      if config.opts.use_speed_commands then
        require("org.speed").on_insert_char()
      end
    end,
  })
  -- reload_on_change: watch the file for changes made by other programs
  if config.opts.reload_on_change ~= false and vim.api.nvim_buf_get_name(bufnr) ~= "" then
    try("org.reload", "attach", bufnr)
  end
  -- #+STARTUP: linkpreviews / latexpreview, ui.images.startup
  try("org.ui.images.startup", "setup_buffer", bufnr)
  -- startup_with_beamer_mode, #+STARTUP: beamer (org.export.beamer_mode
  -- loads only for a buffer that starts with the mode)
  if M.beamer_startup(bufnr) then
    try("org.export.beamer_mode", "setup_buffer", bufnr)
  end
  -- custom timestamp display (display_custom_times, #+STARTUP: customtime)
  if M.custom_times(bufnr) then
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
  -- the autocommands of the buffer, the attach parts' too: speed
  -- commands, table realigning and typing, the clock display and the
  -- custom timestamp display would go on editing a buffer that is no
  -- longer Org (org-mode's local hooks go with kill-all-local-variables)
  for _, group in ipairs({ "org.buffer.", "org.fold.", "org.speed.", "org.table.", "org.clock.buf." }) do
    pcall(vim.api.nvim_del_augroup_by_name, group .. bufnr)
  end
  -- (orgtbl-mode, a minor mode of its own, keeps its table typing)
  local typing = package.loaded["org.table.typing"]
  if typing and not vim.b[bufnr].orgtbl_mode then
    typing.detach(bufnr)
  end
  if vim.b[bufnr].org_custom_times_attached then
    vim.b[bufnr].org_custom_times_attached = nil
    pcall(vim.api.nvim_del_augroup_by_name, "org.timestamps.custom." .. bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, vim.api.nvim_create_namespace("org.timestamps.custom"), 0, -1)
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
