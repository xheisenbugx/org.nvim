---@mod org.integrations.aerial An aerial.nvim backend for Org buffers
---
--- aerial.nvim loads its backends with `require("aerial.backends.<name>")`;
--- `lua/aerial/backends/org.lua` returns this module, so `"org"` in
--- aerial's `backends` gives the outline from org.nvim's own parser (no
--- tree-sitter parser or language server needed). Only aerial loads it,
--- so it never runs without aerial installed. See |org-integrations|.
---
--- ```lua
--- require("aerial").setup({ backends = { org = { "org" } } })
--- ```

local M = {}

local NAME = "org"
local group = vim.api.nvim_create_augroup("AerialOrg", { clear = true })
local timers = {}

---@param bufnr integer|nil
---@return integer
local function buf(bufnr)
  if bufnr == nil or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

---@param r table LSP range
local function from_range(r)
  return {
    lnum = r.start.line + 1,
    col = r.start.character,
    end_lnum = r["end"].line + 1,
    end_col = r["end"].character,
  }
end

--- aerial symbols (1-based lines, 0-based columns, kind names) of org
--- symbols, children linked to their parent.
---@param syms table[] org.api.Symbol[]
---@param bufnr integer
---@return table[] aerial.Symbol[]
function M.convert(syms, bufnr)
  local config = require("aerial.config")
  local kinds = vim.lsp.protocol.SymbolKind
  local function walk(list, parent, level)
    local out = {}
    for _, s in ipairs(list) do
      local item = from_range(s.range)
      item.name = s.name
      item.kind = kinds[s.kind] or "Namespace"
      item.level = level
      item.parent = parent
      item.selection_range = from_range(s.selectionRange)
      if s.children and #s.children > 0 then
        item.children = walk(s.children, item, level + 1)
      end
      local keep = true
      if config.post_parse_symbol then
        keep = config.post_parse_symbol(bufnr, item, { backend_name = NAME, lang = "org", symbol = s }) ~= false
      end
      if keep then
        out[#out + 1] = item
      end
    end
    return out
  end
  return walk(syms, nil, 0)
end

---@param bufnr integer
---@return boolean, string|nil
function M.is_supported(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return false, "Filetype is not org"
  end
  return true, nil
end

---@param bufnr? integer
function M.fetch_symbols_sync(bufnr)
  bufnr = buf(bufnr)
  local syms = require("org.api").symbols(bufnr)
  if not syms then
    return
  end
  require("aerial.backends").set_symbols(bufnr, M.convert(syms, bufnr), { backend_name = NAME, lang = "org" })
end

M.fetch_symbols = M.fetch_symbols_sync

local function stop_timer(bufnr)
  local t = timers[bufnr]
  if t then
    timers[bufnr] = nil
    t:stop()
    t:close()
  end
end

--- Fetch the symbols again `update_delay` ms (aerial's `org.update_delay`,
--- default 300) after the last of aerial's `update_events`.
---@param bufnr integer
function M.attach(bufnr)
  bufnr = buf(bufnr)
  local config = require("aerial.config")
  local events = config.update_events or { "TextChanged", "InsertLeave" }
  if type(events) == "string" then
    events = vim.split(events, ",", { trimempty = true })
  end
  vim.api.nvim_clear_autocmds({ group = group, buffer = bufnr })
  vim.api.nvim_create_autocmd(events, {
    group = group,
    buffer = bufnr,
    desc = "org: update aerial symbols",
    callback = function()
      stop_timer(bufnr)
      local delay = (config[NAME] or {}).update_delay or 300
      local t = assert(vim.uv.new_timer())
      timers[bufnr] = t
      t:start(
        delay,
        0,
        vim.schedule_wrap(function()
          stop_timer(bufnr)
          if vim.api.nvim_buf_is_valid(bufnr) and require("aerial.backends").is_backend_attached(bufnr, NAME) then
            M.fetch_symbols(bufnr)
          end
        end)
      )
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      stop_timer(bufnr)
    end,
  })
end

---@param bufnr integer
function M.detach(bufnr)
  bufnr = buf(bufnr)
  stop_timer(bufnr)
  vim.api.nvim_clear_autocmds({ group = group, buffer = bufnr })
end

return M
