---@mod org.integrations Plugins that expect a tree-sitter parser
---
--- org buffers have no tree-sitter parser, so plugins built on one find
--- nothing in them. When an org buffer is set up, this hooks org.nvim's
--- own structure into the ones that are installed and loaded (and into
--- those lazy.nvim loads later): mini.ai's custom text objects, snacks.nvim's
--- scopes and flash.nvim's tree-sitter jump. Nothing here loads a plugin
--- that isn't loaded already, and a plugin that isn't installed is never
--- touched. `integrations` in `setup()` turns each off (|org-integrations|).

local M = {}

---@return table
local function opts()
  return require("org.config").opts.integrations or {}
end

--- Run `fn(mod)` with module `name` now when it is loaded, else when it
--- is first required (from `package.preload`, which then finds the module
--- with the other loaders, as `require` would).
---@param name string
---@param fn fun(mod: any)
function M.on_require(name, fn)
  local mod = package.loaded[name]
  if mod ~= nil then
    fn(mod)
    return
  end
  if package.preload[name] then
    return
  end
  package.preload[name] = function()
    package.preload[name] = nil
    local errs = {}
    local loaders = package.loaders or package.searchers ---@diagnostic disable-line: deprecated
    for i = 2, #loaders do
      local loader = loaders[i](name)
      if type(loader) == "function" then
        local value = loader(name)
        if value == nil then
          value = package.loaded[name] == nil and true or package.loaded[name]
        end
        require("org.utils").try("integrations: on loading " .. name, fn, value)
        return value
      elseif type(loader) == "string" then
        errs[#errs + 1] = loader
      end
    end
    error(("module '%s' not found:%s"):format(name, table.concat(errs)), 2)
  end
end

--- Hook the loaded plugins into org buffer `bufnr`.
---@param bufnr integer
function M.attach(bufnr)
  local o = opts()
  if o.mini_ai ~= false and (package.loaded["mini.ai"] or rawget(_G, "MiniAi")) then
    require("org.integrations.mini_ai").attach(bufnr, type(o.mini_ai) == "table" and o.mini_ai or nil)
  end
  if o.snacks_scope ~= false and package.loaded["snacks"] then
    M.on_require("snacks.scope", function(mod)
      require("org.integrations.snacks_scope").patch(mod)
    end)
  end
  if o.flash ~= false and package.loaded["flash"] then
    M.on_require("flash.plugins.treesitter", function(mod)
      require("org.integrations.flash").patch(mod)
    end)
  end
  M.watch()
end

local watching = false

--- Attach again every org buffer when lazy.nvim loads one of the plugins
--- after the buffers were set up.
function M.watch()
  if watching then
    return
  end
  watching = true
  local names = { ["mini.ai"] = true, ["mini.nvim"] = true, ["snacks.nvim"] = true, ["flash.nvim"] = true }
  vim.api.nvim_create_autocmd("User", {
    pattern = "LazyLoad",
    group = vim.api.nvim_create_augroup("org.integrations", { clear = true }),
    desc = "org: hook lazy-loaded plugins into org buffers",
    callback = function(ev)
      if not names[ev.data] then
        return
      end
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "org" then
          M.attach(b)
        end
      end
    end,
  })
end

return M
