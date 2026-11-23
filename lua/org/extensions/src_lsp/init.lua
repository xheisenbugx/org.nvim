---@mod org.extensions.src_lsp Language servers inside src blocks
---
--- The language servers of a block's language (the configurations of
--- `vim.lsp.config` / `vim.lsp.enable`) work inside `#+begin_src` blocks:
--- diagnostics show in the block, and go to definition, hover, references,
--- signature help and completion are answered by the language's server.
---
--- ```lua
--- vim.lsp.enable("lua_ls")
--- require("org").setup({ extensions = { src_lsp = { languages = { "lua", "python" } } } })
--- ```
---
--- Each org buffer with blocks of a listed language gets a hidden buffer
--- per language holding those blocks at their own line numbers
--- (`org.extensions.src_lsp.mirror`); the servers attach to it, and a small
--- in-process server attached to the org buffer forwards requests into it
--- (`org.extensions.src_lsp.proxy`). Nothing is loaded or started until an
--- org buffer with a block of a listed language opens.
---
--- See `:h org-extensions-src-lsp`.

local M = {}

--- See :h org-extensions-stability (scripts/extension_report.lua measures it).
M.stability = "stable"

M.defaults = {
  --- Languages whose blocks get their language servers: a list of
  --- language names (`{ "lua", "python" }`), or a table of name ->
  --- `{ servers = { ... } }` naming the `vim.lsp.config` configurations
  --- (or config tables) to start. Without `servers`, every enabled
  --- configuration (`vim.lsp.enable`) whose `filetypes` has the language's
  --- filetype is started.
  ---@type (string|table)[]|table<string, { servers?: (string|table)[] }|boolean>
  languages = {},
  --- Milliseconds without changes before the hidden buffers are updated
  --- (a request inside a block updates them first).
  debounce = 200,
  --- Show the servers' diagnostics in the block bodies.
  diagnostics = true,
  --- Offer the servers' completion: an LSP completion source in the org
  --- buffer (`vim.lsp.completion`, blink.cmp, nvim-cmp), and `<C-x><C-o>`
  --- inside a block.
  completion = true,
}

local augroup = vim.api.nvim_create_augroup("org.src_lsp", { clear = true })

local function mirror()
  return require("org.extensions.src_lsp.mirror")
end

local function proxy()
  return require("org.extensions.src_lsp.proxy")
end

--- Whether a buffer is an org file buffer the extension watches.
---@param buf integer
---@return boolean
local function eligible(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "org" then
    return false
  end
  local bt = vim.bo[buf].buftype
  return (bt == "" or bt == "acwrite") and vim.api.nvim_buf_get_name(buf) ~= ""
end

---@param buf integer
local function attach(buf)
  if eligible(buf) then
    local ok, err = pcall(mirror().attach, buf)
    if not ok then
      require("org.utils").error("src_lsp: " .. tostring(err))
    end
  end
end

--- `omnifunc` inside a block of a listed language: the servers' completion
--- (`vim.lsp.omnifunc`). Returns nil elsewhere, where org's own completion
--- answers. Called by `org.completion.omnifunc`.
---@param findstart integer
---@param base string
---@return any
function M.omnifunc(findstart, base)
  local o = require("org.extensions").opts("src_lsp")
  if not o or o.completion == false then
    return nil
  end
  local buf = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local m = package.loaded["org.extensions.src_lsp.mirror"]
  if not m or not m.states[buf] then
    return nil
  end
  m.flush(buf)
  if not m.group_at(buf, lnum) then
    return nil
  end
  -- vim.lsp.omnifunc annotates `base` as an integer; it is the typed text
  ---@diagnostic disable-next-line: param-type-mismatch
  return vim.lsp.omnifunc(findstart, base)
end

function M.setup(_)
  vim.api.nvim_clear_autocmds({ group = augroup })
  mirror().on_first_group = function(buf)
    local ok, err = pcall(proxy().attach, buf)
    if not ok then
      require("org.utils").error("src_lsp: could not start the proxy: " .. tostring(err))
    end
  end
  vim.api.nvim_create_autocmd("FileType", {
    group = augroup,
    pattern = "org",
    callback = function(ev)
      attach(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = augroup,
    callback = function(ev)
      local m = package.loaded["org.extensions.src_lsp.mirror"]
      if m and m.states[ev.buf] then
        m.dispose(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = augroup,
    callback = function(ev)
      local m = package.loaded["org.extensions.src_lsp.mirror"]
      local owner = m and m.owners[ev.buf]
      if owner then
        vim.schedule(function()
          m.update_diagnostics(owner.org)
        end)
      end
    end,
  })
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      attach(b)
    end
  end
end

--- Turned off (or set up again): delete the hidden buffers, stop the proxy.
function M.teardown()
  vim.api.nvim_clear_autocmds({ group = augroup })
  local m = package.loaded["org.extensions.src_lsp.mirror"]
  if m then
    m.dispose_all()
    m.on_first_group = nil
  end
  if package.loaded["org.extensions.src_lsp.proxy"] then
    proxy().stop()
  end
end

---@param h table vim.health
---@param o table resolved options
function M.health(h, o)
  local by_lang = mirror().languages()
  local names = vim.tbl_keys(by_lang)
  table.sort(names)
  if #names == 0 then
    h.warn("src_lsp: no languages listed", { "set extensions.src_lsp.languages, see :h org-extensions-src-lsp" })
    return
  end
  for _, lang in ipairs(names) do
    local conf = by_lang[lang]
    local configs, missing = mirror().server_configs(conf)
    for _, s in ipairs(missing) do
      h.warn(
        string.format("src_lsp: %s: no vim.lsp.config for %s", lang, s),
        { "define it with vim.lsp.config(), see :h lsp-config" }
      )
    end
    if #configs == 0 then
      h.warn(
        string.format("src_lsp: %s (filetype %s): no enabled language server", lang, conf.ft),
        { "enable one with vim.lsp.enable() or list it in `servers`, see :h org-extensions-src-lsp" }
      )
    end
    for _, cfg in ipairs(configs) do
      local cmd = cfg.cmd
      if type(cmd) == "table" and type(cmd[1]) == "string" and vim.fn.executable(cmd[1]) == 0 then
        h.warn(
          string.format("src_lsp: %s: %s needs %s, which is not executable", lang, cfg.name, cmd[1]),
          { "install it or fix its `cmd`, see :h lsp-config" }
        )
      else
        h.ok(string.format("src_lsp: %s (filetype %s): %s", lang, conf.ft, tostring(cfg.name)))
      end
    end
  end
  if o.diagnostics == false then
    h.info("src_lsp: diagnostics turned off")
  end
  if #vim.api.nvim_get_runtime_file("lua/otter/init.lua", false) > 0 then
    h.info("src_lsp: otter.nvim is installed too; activate only one of them for org buffers, or diagnostics show twice")
  end
end

return M
