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
  --- Follow `org clock in/out/cancel` run from a shell: this Neovim rereads
  --- the files and takes up (or drops) the running clock.
  watch_clock = true,
}

M.actions = {
  cli_install = { MOD, "install", desc = "Link the org command line (bin/org) into install_dir" },
}

M.commands = {
  cli_install = {
    MOD,
    "install_command",
    desc = "Link bin/org into a directory: :Org cli_install [DIR]",
    complete = function(arglead)
      return require("org.utils").complete_path(arglead, "dir")
    end,
  },
}

--- `:Org cli_install [DIR]`.
function M.install_command(args)
  local dir = vim.trim(args or "")
  return M.install(dir ~= "" and dir or nil)
end

--- The file `org clock in/out/cancel` touches so a running Neovim notices.
function M.stamp_path()
  return vim.fn.stdpath("data") .. "/org/cli-clock.stamp"
end

local poll, group

--- Take up a clock change made by the command line (`org.clock.sync`).
function M.sync_clock()
  local ok, what, st = pcall(require("org.clock").sync)
  if not ok or not what then
    return nil
  end
  local utils = require("org.utils")
  if what == "in" then
    utils.notify("Clocked in from the command line: " .. (st.title or ""))
  else
    utils.notify("Clocked out from the command line: " .. (st.title or ""))
  end
  return what
end

local function stop_watch()
  if poll then
    pcall(poll.stop, poll)
    pcall(poll.close, poll)
    poll = nil
  end
  if group then
    pcall(vim.api.nvim_del_augroup_by_id, group)
    group = nil
  end
end

function M.setup(o)
  stop_watch()
  if not o.watch_clock then
    return
  end
  local path = M.stamp_path()
  local last = (vim.uv.fs_stat(path) or {}).mtime
  local function changed()
    local st = vim.uv.fs_stat(path)
    local m = st and st.mtime
    if m and (not last or m.sec ~= last.sec or m.nsec ~= last.nsec) then
      last = m
      return true
    end
    return false
  end
  -- a stat every 2 s; the callback never raises
  poll = vim.uv.new_fs_poll()
  poll:start(path, 2000, function()
    vim.schedule(function()
      if changed() then
        M.sync_clock()
      end
    end)
  end)
  group = vim.api.nvim_create_augroup("org_extensions_cli", { clear = true })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      if changed() then
        M.sync_clock()
      end
    end,
  })
end

function M.teardown()
  stop_watch()
end

local function opts()
  return require("org.extensions").opts("cli") or M.defaults
end

local is_win = vim.fn.has("win32") == 1

--- Path of `bin/org` in this checkout (`bin/org.cmd` on Windows).
---@return string
function M.bin()
  return require("org.version").root() .. (is_win and "/bin/org.cmd" or "/bin/org")
end

--- The launcher `cli_install` writes on Windows, where symlinks need
--- administrator rights or developer mode: it runs `bin`.
---@param bin string
---@return string
local function shim(bin)
  return '@"' .. bin:gsub("/", "\\") .. '" %*\r\n'
end

local function same_path(a, b)
  a, b = vim.fs.normalize(a), vim.fs.normalize(b)
  if is_win then
    a, b = a:lower(), b:lower()
  end
  return a == b
end

--- What `p` runs: the target of a symlink, or of an `org.cmd` launcher.
local function target(p)
  if is_win then
    local f = io.open(p, "rb")
    local text = f and f:read("*a") or ""
    if f then
      f:close()
    end
    return text:match('^@"(.-)" %%%*') or p
  end
  return vim.fn.resolve(p)
end

--- The `org` found on $PATH, resolved, or nil.
local function on_path()
  local p = vim.fn.exepath("org")
  if p == "" then
    return nil
  end
  return target(p)
end

--- Symlink `bin/org` into `install_dir` (asks first; an existing file
--- that is not that symlink is left alone).
---@param dir? string
---@return string|nil the link made
function M.install(dir)
  local utils = require("org.utils")
  dir = vim.fs.normalize(vim.fn.expand(dir or opts().install_dir))
  local link = dir .. (is_win and "/org.cmd" or "/org")
  local bin = M.bin()
  if vim.uv.fs_lstat(link) and same_path(target(link), is_win and bin or vim.fn.resolve(bin)) then
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
  local ok, err
  if is_win then
    local f
    f, err = io.open(link, "wb")
    if f then
      ok = f:write(shim(bin))
      f:close()
    end
  else
    ok, err = vim.uv.fs_symlink(bin, link)
  end
  if not ok then
    utils.error("Could not link " .. link .. ": " .. tostring(err))
    return nil
  end
  local on = false
  for _, p in ipairs(vim.split(vim.env.PATH or "", is_win and ";" or ":", { trimempty = true })) do
    on = on or same_path(p:gsub("[/\\]$", ""), dir)
  end
  if not on then
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
  if found and same_path(found, is_win and bin or vim.fn.resolve(bin)) then
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
