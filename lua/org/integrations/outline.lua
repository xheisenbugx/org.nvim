---@mod org.integrations.outline An outline.nvim provider for Org buffers
---
--- outline.nvim loads the providers in its `providers.priority` list with
--- `require("outline.providers.<name>")`; `lua/outline/providers/org.lua`
--- returns this module (outline.nvim's "external provider" interface), so
--- `"org"` in that list gives the outline from org.nvim's own parser. Only
--- outline.nvim loads it. See |org-integrations|.
---
--- ```lua
--- require("outline").setup({
---   providers = { priority = { "lsp", "coc", "markdown", "norg", "man", "org" } },
--- })
--- ```

local M = {}

M.name = "org"

---@param bufnr integer
---@return boolean
function M.supports_buffer(bufnr, _)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  return vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "org"
end

---@return string[]
function M.get_status()
  return { "org.nvim document symbols (its own parser)" }
end

--- The symbols of the current buffer (outline.nvim asks from the source
--- window), LSP `DocumentSymbol`-shaped as outline.nvim expects.
---@param callback fun(symbols?: table[], opts?: table)
---@param opts? table
function M.request_symbols(callback, opts)
  local syms = require("org.api").symbols(0)
  callback(syms, opts)
end

return M
