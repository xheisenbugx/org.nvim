---@mod org.extensions.cli.args Arguments and configuration
---
--- Splitting the command line into flags and words (`parse_args`), paths
--- from it (`arg_path`) and loading the user's configuration with the
--- CLI's overrides (`load_config`). Part of org.extensions.cli.run, which
--- loads it.

local schema = require("org.extensions.cli.schema")

local shared = require("org.extensions.cli.shared")

local M = require("org.extensions.cli.run")

local fail = M.fail
local state = shared.state

-- repeatable flags whose values may also be comma-separated
local COMMA = { files = true, todo = true, tag = true, add = true, remove = true }

--- Split `argv` into flags and positional words. Repeatable flags give
--- lists; `--flag=value` works too; `--` ends the flags.
---@param argv string[]
---@return table flags, string[] words
function M.parse_args(argv)
  local flags, words = {}, {}
  for _, f in ipairs(schema.FLAGS) do
    if f.repeatable then
      flags[f.key] = {}
    end
  end
  local given = {}
  local i = 1
  local rest = false
  while i <= #argv do
    local a = argv[i]
    if rest then
      words[#words + 1] = a
    elseif a == "--" then
      rest = true
    else
      local name, value = a:match("^(%-%-[%w-]+)=(.*)$")
      name = name or a
      local f = schema.BY_NAME[name]
      if f and f.value then
        if not value then
          i = i + 1
          value = argv[i]
          -- the next word is an option of its own (`--todo --json`): the
          -- value is missing, not "--json" (`--match=-v` gives a value
          -- that looks like an option)
          local next_name = value and (value:match("^(%-%-[%w-]+)=") or value)
          if value == nil or value == "--" or schema.BY_NAME[next_name] then
            fail(name .. " needs a value", "usage", { flag = name })
          end
        end
        if f.repeatable then
          if COMMA[f.key] then
            vim.list_extend(flags[f.key], vim.split(value, ",", { trimempty = true }))
          else
            table.insert(flags[f.key], value)
          end
        else
          flags[f.key] = value
        end
        given[f.key] = name
      elseif f and not value then
        flags[f.key] = true
        given[f.key] = name
      elseif a:match("^%-%-?%a") and a ~= "-" then
        fail("unknown option " .. a .. " (see org help)", "unknown_option", { option = a })
      else
        words[#words + 1] = a
      end
    end
    i = i + 1
  end
  flags._given = given
  return flags, words
end

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------

--- The config file to load: `--config`, `$ORG_NVIM_CONFIG`, else
--- `stdpath("config")/org-cli.lua` when it exists.
---@return string|nil
function M.config_file(flags)
  local f = flags.config or vim.env.ORG_NVIM_CONFIG
  if f and f ~= "" then
    f = require("org.utils").expand_vars(f)
    if vim.fn.filereadable(f) == 0 then
      fail("config file not found: " .. f, "config", { file = f })
    end
    return f
  end
  local default = vim.fn.stdpath("config") .. "/org-cli.lua"
  if vim.fn.filereadable(default) == 1 then
    return default
  end
  return nil
end

--- A path from the command line, absolute (relative to the client's
--- directory when the session server runs the command).
local function arg_path(p)
  p = require("org.utils").expand_vars(p)
  if state.cwd and not (p:match("^[/\\]") or p:match("^%a:[/\\]")) then
    p = state.cwd .. "/" .. p
  end
  return vim.fs.normalize(vim.fn.fnamemodify(p, ":p"))
end
M.arg_path = arg_path

--- Load the user's configuration with the CLI's overrides forced in, then
--- apply `--files` and `--dir`.
function M.load_config(flags)
  local config = require("org.config")
  local setup = config.setup
  local function forced_setup(opts)
    return setup(vim.tbl_deep_extend("force", opts or {}, M.OVERRIDES))
  end
  config.setup = forced_setup
  local file = M.config_file(flags)
  local ok, res = true, nil
  if file then
    ok, res = pcall(dofile, file)
    if not ok then
      config.setup = setup
      fail("error in " .. file .. ": " .. tostring(res), "config", { file = file })
    end
  end
  if res ~= nil and type(res) ~= "table" then
    config.setup = setup
    fail(
      string.format(
        '%s returns a %s: it must return the options table of setup(), or call require("org").setup() itself',
        file,
        type(res)
      ),
      "config",
      { file = file }
    )
  end
  local org = require("org")
  local sok, serr = pcall(function()
    if type(res) == "table" then
      org.setup(res)
    else
      org.ensure_setup()
    end
  end)
  config.setup = setup
  if not sok then
    fail("error in " .. tostring(file or "the configuration") .. ": " .. tostring(serr), "config", { file = file })
  end
  -- options every command reads: a wrong type would fail as an internal
  -- error later
  local function check_type(name, value)
    local okay = type(value) == "string"
    if type(value) == "table" then
      okay = true
      for _, v in ipairs(value) do
        okay = okay and type(v) == "string"
      end
    end
    if value ~= nil and not okay then
      fail(
        string.format("%s must be a path or a list of paths, not %s", name, vim.inspect(value)),
        "config",
        { file = file or vim.NIL, option = name }
      )
    end
  end
  check_type("agenda_files", config.opts.agenda_files)
  if config.opts.org_directory ~= nil and type(config.opts.org_directory) ~= "string" then
    fail(
      "org_directory must be a path, not " .. vim.inspect(config.opts.org_directory),
      "config",
      { file = file or vim.NIL, option = "org_directory" }
    )
  end
  -- a config that set things up before the override was in place
  for k, v in pairs(M.OVERRIDES) do
    if type(v) == "table" then
      config.opts[k] = config.opts[k] or {}
      for k2, v2 in pairs(v) do
        config.opts[k][k2] = v2
      end
    else
      config.opts[k] = v
    end
  end
  if flags.dir then
    config.opts.org_directory = arg_path(flags.dir) .. "/"
  end
  if #flags.files > 0 then
    config.opts.agenda_files = vim.tbl_map(arg_path, flags.files)
  end
  -- org.crypt registers its write hook (encrypt_on_save) when it loads,
  -- which Neovim does as it sets up an org buffer: `nvim -l` sets up none
  if (config.opts.crypt or {}).encrypt_on_save then
    require("org.crypt")
  end
end

--- The resolved `extensions.cli` options (its defaults when the extension
--- is not enabled in the loaded configuration).
local function cli_opts()
  return require("org.extensions").opts("cli") or require("org.extensions.cli").defaults
end

shared.cli_opts = cli_opts
