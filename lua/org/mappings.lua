---@mod org.mappings Keymaps

local actions = require("org.actions")
local config = require("org.config")
local utils = require("org.utils")

local M = {}

--- Feed the key's default behaviour (or a global mapping for it) when an
--- action returned `false`.
local function fallback(lhs, mode)
  -- global (non-buffer) mapping for the same key?
  for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
    if map.lhs == lhs or vim.keycode(map.lhs) == vim.keycode(lhs) then
      if map.callback then
        local ok, res = pcall(map.callback)
        if ok and map.expr == 1 and type(res) == "string" then
          vim.api.nvim_feedkeys(vim.keycode(res), map.noremap == 1 and "n" or "m", false)
        end
        return
      elseif map.rhs and map.rhs ~= "" then
        local rhs = map.rhs
        if map.expr == 1 then
          rhs = vim.api.nvim_eval(rhs)
        end
        vim.api.nvim_feedkeys(vim.keycode(rhs), map.noremap == 1 and "n" or "m", false)
        return
      end
    end
  end
  local keys = vim.keycode(lhs)
  if vim.v.count > 0 and mode == "n" then
    keys = vim.v.count .. keys
  end
  vim.api.nvim_feedkeys(keys, "n", false)
end

local function wrap(name, lhs, mode)
  return function()
    if not actions.run(name) then
      fallback(lhs, mode)
    end
  end
end

local function set(mode, lhs, rhs, opts)
  vim.keymap.set(mode, lhs, rhs, opts)
end

--- Global keymaps (agenda, capture, ...).
function M.setup_global()
  local maps = config.opts.mappings
  if maps.disable_all then
    return
  end
  for name, value in pairs(maps.global or {}) do
    local a = actions.list[name]
    if a then
      for _, lhs in ipairs(config.lhs_list(value)) do
        set("n", lhs, wrap(name, lhs, "n"), { desc = "org: " .. a.desc })
      end
    end
  end
  M.register_which_key()
end

--- Buffer-local keymaps for an org buffer.
function M.attach(bufnr)
  local maps = config.opts.mappings
  if maps.disable_all then
    return
  end
  for name, value in pairs(maps.org or {}) do
    local a = actions.list[name]
    if a then
      for _, lhs in ipairs(config.lhs_list(value)) do
        for _, mode in ipairs(a.modes or { "n" }) do
          if mode ~= "i" or name == "meta_return" or name == "meta_shift_return" then
            set(mode, lhs, wrap(name, lhs, mode), { buffer = bufnr, desc = "org: " .. a.desc })
          end
        end
      end
    end
  end
  for name, value in pairs(maps.org_insert or {}) do
    local a = actions.list[name]
    if a then
      for _, lhs in ipairs(config.lhs_list(value)) do
        set("i", lhs, wrap(name, lhs, "i"), { buffer = bufnr, desc = "org: " .. a.desc })
      end
    end
  end
  -- text objects (synchronous)
  local to = maps.text_objects or {}
  local objs = {
    inner_heading = { "select_heading", true },
    around_heading = { "select_heading", false },
    inner_subtree = { "select_subtree", true },
    around_subtree = { "select_subtree", false },
  }
  for name, spec in pairs(objs) do
    for _, lhs in ipairs(config.lhs_list(to[name])) do
      set({ "o", "x" }, lhs, function()
        require("org.structure")[spec[1]](spec[2])
      end, { buffer = bufnr, desc = "org: " .. name:gsub("_", " ") })
    end
  end
end

local groups = {
  { "", "org" },
  { "i", "insert" },
  { "h", "heading/subtree" },
  { "x", "clock" },
  { "l", "links" },
  { "b", "babel" },
  { "T", "table" },
}

function M.register_which_key()
  local ok, wk = pcall(require, "which-key")
  if not ok or not wk.add then
    return
  end
  local prefix = config.opts.mappings.prefix or "<leader>o"
  local spec = {}
  for _, g in ipairs(groups) do
    spec[#spec + 1] = { prefix .. g[1], group = g[2], mode = { "n", "x" } }
  end
  pcall(wk.add, spec)
end

--- `g?` help float for the current buffer kind.
function M.show_help()
  local maps = config.opts.mappings
  local rows = {}
  local ft = vim.bo.filetype
  local section
  if ft == "orgagenda" then
    section = maps.agenda
    for name, value in pairs(section or {}) do
      local lhs = table.concat(config.lhs_list(value), ", ")
      if lhs ~= "" then
        rows[#rows + 1] = { lhs, name:gsub("_", " ") }
      end
    end
  else
    for _, tbl in ipairs({ maps.global or {}, maps.org or {}, maps.org_insert or {} }) do
      for name, value in pairs(tbl) do
        local a = actions.list[name]
        local lhs = table.concat(config.lhs_list(value), ", ")
        if a and lhs ~= "" then
          rows[#rows + 1] = { lhs, a.desc }
        end
      end
    end
    for name, value in pairs(maps.text_objects or {}) do
      local lhs = table.concat(config.lhs_list(value), ", ")
      if lhs ~= "" then
        rows[#rows + 1] = { lhs, "text object: " .. name:gsub("_", " ") }
      end
    end
  end
  table.sort(rows, function(a, b)
    return a[2] < b[2]
  end)
  require("org.ui").help("org keymaps", rows)
end

return M
