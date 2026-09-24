---@mod org org.nvim - Org mode for Neovim
---
--- Public API. Most functionality lives in feature modules; this file only
--- wires configuration, commands and global keymaps.

local M = {}

local did_setup = false

---@param opts? org.Config
function M.setup(opts)
  require("org.config").setup(opts)
  did_setup = true
  require("org.commands").setup()
  require("org.mappings").setup_global()
  require("org.highlights").setup()
  local cfg = require("org.config").opts
  if cfg.notifications.enabled then
    vim.schedule(function()
      local ok, n = pcall(require, "org.agenda.notifications")
      if ok then
        n.start()
      end
    end)
  end
  if cfg.clock.persist then
    vim.schedule(function()
      local ok, clock = pcall(require, "org.clock")
      if ok and clock.restore then
        pcall(clock.restore)
      end
    end)
  end
  -- attach to org buffers that were opened before setup ran
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "org" then
      require("org.buffer").attach(b)
    end
  end
  return M
end

--- Ensure setup ran with defaults (e.g. when a user opens an org file
--- without calling setup).
function M.ensure_setup()
  if not did_setup then
    M.setup({})
  end
end

--- Open the agenda dispatcher, or a specific view (see `:h org-agenda`).
function M.agenda(key)
  require("org.utils").run(function()
    if key then
      require("org.agenda").command(key)
    else
      require("org.agenda").prompt()
    end
  end)
end

--- Capture; `key` selects a template directly.
function M.capture(key)
  require("org.utils").run(function()
    if key then
      require("org.capture").command(key)
    else
      require("org.capture").prompt()
    end
  end)
end

--- Statusline component showing the running clock (empty when idle).
function M.statusline()
  local ok, clock = pcall(require, "org.clock")
  if not ok or not clock.statusline then
    return ""
  end
  return clock.statusline()
end

--- Run a named action (see `org.actions`).
function M.action(name)
  return require("org.actions").run(name)
end

return M
