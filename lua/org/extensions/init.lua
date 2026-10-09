---@mod org.extensions Optional extensions
---
--- Extensions are built-in modules, `lua/org/extensions/<name>`, that stay
--- unloaded until enabled in the `extensions` option:
---
--- ```lua
--- require("org").setup({ extensions = { roam = { directory = "~/roam" } } })
--- ```
---
--- An extension module returns an `org.Extension`. `setup()` loads each
--- enabled one, merges its `defaults` under the user's table (the result is
--- `require("org.config").opts.extensions.<name>`), registers its actions
--- and `:Org` subcommands, adds its default keys where the user set none, and
--- calls its `setup`.

local M = {}

---@class org.Extension
---Option defaults; the user's `extensions.<name>` table is merged over them.
---@field defaults? table
---Actions added to `org.actions.list` (usable in `mappings` and `:Org`).
---@field actions? table<string, org.Action>
---`:Org` subcommands that take arguments, in the `org.commands.extra` form.
---@field commands? table<string, table>
---Default keys by `mappings` section (`global`, `org`, `emacs_global`,
---`emacs`), action name -> lhs. Keys the user already set are left alone.
---@field mappings? table<string, table<string, string|string[]|false>>
---which-key group labels under `mappings.prefix`: `{ { "m", "roam" } }`.
---@field groups? { [1]: string, [2]: string }[]
---Called with the resolved options after everything is registered.
---@field setup? fun(opts: table)
---Adds checks to `:checkhealth org`; receives `vim.health`.
---@field health? fun(h: table, opts: table)
---Called when a later `setup()` turns the extension off (or before it is
---set up again): remove autocmds, handlers and windows it made.
---@field teardown? fun()
---"stable" or "experimental" (the default): see `:h org-extensions-stability`.
---@field stability? "stable"|"experimental"

--- Enabled extensions from the last `setup()`: name -> module.
---@type table<string, org.Extension>
M.loaded = {}

-- names and global keys registered by the last setup, removed again on the
-- next one
local registered = { actions = {}, commands = {}, keys = {} }

local function is_enabled(value)
  if value == nil or value == false then
    return false
  end
  return not (type(value) == "table" and value.enabled == false)
end

local function unregister()
  local actions = require("org.actions")
  local commands = require("org.commands")
  for name in pairs(registered.actions) do
    actions.list[name] = nil
  end
  for name in pairs(registered.commands) do
    commands.extra[name] = nil
  end
  -- global keys of actions that may no longer exist; a key the user has
  -- since mapped to something else is left alone
  for _, k in ipairs(registered.keys) do
    local map = vim.fn.maparg(k.lhs, k.mode, false, true)
    if map.desc == k.desc then
      pcall(vim.keymap.del, k.mode, k.lhs)
    end
  end
  registered = { actions = {}, commands = {}, keys = {} }
end

-- Remember the global keys the extension's actions will get (defaults and
-- the user's own), so the next setup can remove them.
local function track_keys()
  local config = require("org.config")
  local actions = require("org.actions")
  local maps = config.opts.mappings
  for _, section in ipairs({ "global", "emacs_global" }) do
    for aname, value in pairs(maps[section] or {}) do
      local a = registered.actions[aname] and actions.list[aname]
      if a then
        for _, lhs in ipairs(config.lhs_list(value)) do
          for _, mode in ipairs(a.modes or { "n" }) do
            if mode ~= "i" then
              registered.keys[#registered.keys + 1] = { mode = mode, lhs = lhs, desc = "org: " .. a.desc }
            end
          end
        end
      end
    end
  end
end

---@param name string
---@param ext org.Extension
local function register(name, ext)
  local actions = require("org.actions")
  local commands = require("org.commands")
  local utils = require("org.utils")
  for aname, a in pairs(ext.actions or {}) do
    if actions.list[aname] and not registered.actions[aname] then
      utils.error(string.format("extension %s: action %s already exists", name, aname))
    else
      actions.list[aname] = a
      registered.actions[aname] = true
    end
  end
  for cname, c in pairs(ext.commands or {}) do
    if commands.extra[cname] and not registered.commands[cname] then
      utils.error(string.format("extension %s: :Org %s already exists", name, cname))
    else
      commands.extra[cname] = c
      registered.commands[cname] = true
    end
  end
  local maps = require("org.config").opts.mappings
  for section, keys in pairs(ext.mappings or {}) do
    -- a section the user turned off (`mappings.emacs = false`) stays off
    if maps[section] ~= false then
      maps[section] = maps[section] or {}
      for aname, lhs in pairs(keys) do
        if maps[section][aname] == nil then
          maps[section][aname] = lhs
        end
      end
    end
  end
end

--- Load and register the enabled extensions. Called by `require("org").setup`
--- after the options are merged and before keymaps are set.
function M.setup()
  local config = require("org.config")
  local utils = require("org.utils")
  unregister()
  for name, ext in pairs(M.loaded) do
    if ext.teardown then
      local ok, err = pcall(ext.teardown)
      if not ok then
        utils.error(string.format("extension %s: teardown failed: %s", name, tostring(err)))
      end
    end
  end
  M.loaded = {}
  local exts = config.opts.extensions or {}
  local names = vim.tbl_keys(exts)
  table.sort(names)
  for _, name in ipairs(names) do
    local value = exts[name]
    if is_enabled(value) then
      local ok, ext = pcall(require, "org.extensions." .. name)
      if not ok then
        utils.error(string.format("Unknown or broken extension %s: %s", name, tostring(ext)))
      else
        local opts = vim.deepcopy(ext.defaults or {})
        config.merge(opts, type(value) == "table" and value or {})
        opts.enabled = true
        exts[name] = opts
        M.loaded[name] = ext
        register(name, ext)
        if ext.setup then
          local sok, err = pcall(ext.setup, opts)
          if not sok then
            utils.error(string.format("extension %s: setup failed: %s", name, tostring(err)))
          end
        end
      end
    end
  end
  track_keys()
end

--- Whether an extension is enabled and loaded.
---@param name string
---@return boolean
function M.enabled(name)
  return M.loaded[name] ~= nil
end

--- Resolved options of an enabled extension (nil when it is off).
---@param name string
---@return table|nil
function M.opts(name)
  if not M.loaded[name] then
    return nil
  end
  return require("org.config").opts.extensions[name]
end

--- `:checkhealth org` section listing the enabled extensions.
---@param h table vim.health
function M.check(h)
  h.start("org.nvim extensions")
  local names = vim.tbl_keys(M.loaded)
  table.sort(names)
  if #names == 0 then
    h.info("No extensions enabled (see :h org-extensions)")
    return
  end
  for _, name in ipairs(names) do
    h.ok("enabled: " .. name)
    local label = M.stability_label(name)
    if label then
      h.info(label)
    end
    local ext = M.loaded[name]
    if ext.health then
      local ok, err = pcall(ext.health, h, M.opts(name))
      if not ok then
        h.error(string.format("%s health check failed: %s", name, tostring(err)))
      end
    end
  end
end

--- The extensions that ship with org.nvim: `lua/org/extensions/<name>/init.lua`
--- or `<name>.lua` (helper modules ending in `_util` are not extensions), sorted.
---@return string[]
function M.builtin()
  local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
  local names = {}
  for name, kind in vim.fs.dir(dir) do
    if kind == "directory" and vim.uv.fs_stat(dir .. "/" .. name .. "/init.lua") then
      names[#names + 1] = name
    elseif kind == "file" and name:match("%.lua$") and name ~= "init.lua" and not name:match("_util%.lua$") then
      names[#names + 1] = name:sub(1, -5)
    end
  end
  table.sort(names)
  return names
end

--- Stability of a built-in extension, from its module's `stability` field
--- ("experimental" when it sets none): the source of truth for the README
--- table, `:h org-extensions-stability` and `:checkhealth org`
--- (tests/spec/ext_stability_spec.lua checks they agree).
---@param name string
---@return "stable"|"experimental"
function M.stability(name)
  local ok, ext = pcall(require, "org.extensions." .. name)
  return ok and type(ext) == "table" and ext.stability == "stable" and "stable" or "experimental"
end

--- The stability line of a built-in extension in `:checkhealth org`; nil for
--- a third-party one.
---@param name string
---@return string|nil
function M.stability_label(name)
  if not vim.tbl_contains(M.builtin(), name) then
    return nil
  end
  if M.stability(name) == "stable" then
    return "stability: stable"
  end
  return "stability: experimental, its options may change (:h org-extensions-stability)"
end

return M
