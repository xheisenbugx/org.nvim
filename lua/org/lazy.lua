---@mod org.lazy Deferred hooks into modules that are not loaded yet
---
--- Extensions plug into heavy modules (the agenda renderer, capture, babel)
--- by setting fields on them. Requiring those modules in `setup()` would load
--- them at startup, so `on_load` runs the hook when the module first loads
--- instead (or at once when it already is).
---
--- ```lua
--- require("org.lazy").on_load("org.agenda.render", "ql", function(render)
---   render.sources.ql = source
--- end)
--- ```
---
--- `parts` loads the parts of a facade module (org/lists.lua and the files
--- in org/lists/) on first use of one of them.

local M = {}

-- module name -> { key -> fn }
local hooks = {}

-- Find the module the way `require` would, after package.preload.
local function find_loader(name)
  local errs = {}
  for i = 2, #package.loaders do
    local loader = package.loaders[i](name)
    if type(loader) == "function" then
      return loader
    elseif type(loader) == "string" then
      errs[#errs + 1] = loader
    end
  end
  error(string.format("module '%s' not found:%s", name, table.concat(errs)), 3)
end

-- module name -> the package.preload function installed for it
local installed = {}

local function install(name)
  if installed[name] and package.preload[name] == installed[name] then
    return
  end
  -- Neovim's own modules (vim.filetype, ...) can already have a preloader
  local previous = package.preload[name]
  local function preload(...)
    local mod = (previous or find_loader(name))(...)
    if mod == nil and type(package.loaded[name]) == "table" then
      mod = package.loaded[name]
    end
    package.preload[name] = previous
    installed[name] = nil
    local fns = hooks[name] or {}
    hooks[name] = nil
    local keys = vim.tbl_keys(fns)
    table.sort(keys)
    for _, key in ipairs(keys) do
      fns[key](mod)
    end
    return mod
  end
  installed[name] = preload
  package.preload[name] = preload
end

--- Run `fn(mod)` with module `name`: now when it is loaded, otherwise right
--- after its first `require`. A later call with the same `key` replaces a
--- pending hook; `fn = nil` cancels it.
---@param name string module name
---@param key string hook identity (e.g. the extension name)
---@param fn fun(mod: any)|nil
function M.on_load(name, key, fn)
  local mod = package.loaded[name]
  if mod ~= nil then
    if fn then
      fn(mod)
    end
    return
  end
  hooks[name] = hooks[name] or {}
  hooks[name][key] = fn
  if fn then
    install(name)
  end
end

--- Run `fn(mod)` only when module `name` is already loaded (undoing a hook
--- in a teardown), and cancel the pending `key` hook otherwise.
---@param name string
---@param key string
---@param fn fun(mod: any)
function M.if_loaded(name, key, fn)
  local mod = package.loaded[name]
  if mod ~= nil then
    fn(mod)
  elseif hooks[name] then
    hooks[name][key] = nil
  end
end

--- Load the parts of the facade module `facade` (modules that add their
--- functions to it and share helpers through `shared`) the first time a
--- field the facade doesn't have is read from it or `shared`, or a new one
--- is set on it: code that only uses the facade's own functions (the list
--- item parser the folds use) doesn't load them. Both are plain tables
--- again once the parts are in.
---
--- `own` lists fields that belong to `facade` itself even while currently
--- `nil` (for example state fields like `clock.state`), so reading or
--- assigning them does not trigger loading the deferred parts.
---@param facade table
---@param shared table
---@param names string[] the parts, loaded in this order
---@param own? table<string, boolean> facade-owned keys that may be nil
function M.parts(facade, shared, names, own)
  local function load()
    setmetatable(facade, nil)
    setmetatable(shared, nil)
    for _, name in ipairs(names) do
      require(name)
    end
  end
  setmetatable(facade, {
    __index = function(t, k)
      if own and own[k] then
        return nil
      end
      load()
      return rawget(t, k)
    end,
    __newindex = function(t, k, v)
      if own and own[k] then
        rawset(t, k, v)
        return
      end
      load()
      rawset(t, k, v)
    end,
  })
  setmetatable(shared, {
    __index = function(t, k)
      load()
      return rawget(t, k)
    end,
  })
end

return M
