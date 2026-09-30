---@mod org.extensions.cli The `org` command line
---
--- `bin/org` runs org.nvim headless from a shell: the agenda as text or
--- JSON, capture, the clock, search and export (see `:h org-extensions-cli`
--- and `org help`). The command line works whether or not this extension
--- is enabled; enabling it adds `:Org cli_install` (a symlink to `bin/org`
--- on your $PATH), health checks and the options below, which the CLI reads
--- from the configuration it loads.
---
--- ```lua
--- require("org").setup({ extensions = { cli = { install_dir = "~/bin" } } })
--- ```

local M = {}

local MOD = "org.extensions.cli"

M.defaults = {
  --- Directory `cli_install` puts the `org` symlink in.
  install_dir = "~/.local/bin",
  --- Template key `org capture` uses without `-t` (nil: "t" when it
  --- exists, else the first template).
  capture_template = nil,
  --- `org clock status --short` format: %t title, %e elapsed, %T total
  --- with earlier clocks, %E effort, %f file, %s start.
  status_format = "%e %t",
}

M.actions = {
  cli_install = { MOD, "install", desc = "Link the org command line (bin/org) into install_dir" },
}

local function opts()
  return require("org.extensions").opts("cli") or M.defaults
end

--- Path of `bin/org` in this checkout.
---@return string
function M.bin()
  return require("org.version").root() .. "/bin/org"
end

--- The `org` found on $PATH, resolved, or nil.
local function on_path()
  local p = vim.fn.exepath("org")
  if p == "" then
    return nil
  end
  return vim.fn.resolve(p)
end

--- Symlink `bin/org` into `install_dir` (asks first; an existing file
--- that is not that symlink is left alone).
---@param dir? string
---@return string|nil the link made
function M.install(dir)
  local utils = require("org.utils")
  dir = vim.fn.expand(dir or opts().install_dir)
  local link = dir .. "/org"
  local bin = M.bin()
  if vim.fn.resolve(link) == vim.fn.resolve(bin) then
    utils.notify("org CLI already installed: " .. link)
    return link
  end
  if vim.uv.fs_lstat(link) then
    utils.warn(link .. " exists and is not org.nvim's bin/org; remove it first")
    return nil
  end
  local choice = utils.select({ "Yes", "No" }, { prompt = "Link " .. link .. " -> " .. bin .. "?" })
  if choice ~= "Yes" then
    return nil
  end
  vim.fn.mkdir(dir, "p")
  local ok, err = vim.uv.fs_symlink(bin, link)
  if not ok then
    utils.error("Could not link " .. link .. ": " .. tostring(err))
    return nil
  end
  local path = ":" .. (vim.env.PATH or "") .. ":"
  if not path:find(":" .. dir .. ":", 1, true) and not path:find(":" .. dir .. "/:", 1, true) then
    utils.warn(dir .. " is not on your $PATH")
  end
  utils.notify("org CLI installed: " .. link)
  return link
end

function M.health(h)
  local bin = M.bin()
  if vim.fn.executable(bin) == 1 then
    h.ok("cli: " .. bin)
  else
    h.error("cli: " .. bin .. " is missing or not executable")
  end
  local found = on_path()
  if found and found == vim.fn.resolve(bin) then
    h.ok("cli: `org` on $PATH is this checkout's bin/org")
  elseif found then
    h.warn("cli: `org` on $PATH is " .. found .. ", not " .. bin)
  else
    h.info("cli: `org` is not on $PATH (`:Org cli_install` links it into " .. opts().install_dir .. ")")
  end
  local cfg = vim.env.ORG_NVIM_CONFIG
  if cfg and cfg ~= "" then
    if vim.fn.filereadable(vim.fn.expand(cfg)) == 1 then
      h.ok("cli: config $ORG_NVIM_CONFIG = " .. cfg)
    else
      h.warn("cli: $ORG_NVIM_CONFIG = " .. cfg .. " is not readable")
    end
  elseif vim.fn.filereadable(vim.fn.stdpath("config") .. "/org-cli.lua") == 1 then
    h.ok("cli: config " .. vim.fn.stdpath("config") .. "/org-cli.lua")
  else
    h.info("cli: no CLI config; `org` runs with the defaults (use --config, $ORG_NVIM_CONFIG or org-cli.lua)")
  end
  if vim.fn.executable("jq") == 0 then
    h.info("cli: jq not found (optional, for --json output)")
  end
end

return M
