---@mod org.extensions.cli.session Commands run in a Neovim that keeps running
---
--- `forward` sends a command to the session server (|org-remote|) when
--- one listens; `serve` runs one there for a client, around the headless
--- prompts and the CLI's overrides. `resident_begin` is what `org mcp`
--- sets up around each tool call it runs in its own Neovim. Part of
--- org.extensions.cli.run, which loads it after its command table.

local shared = require("org.extensions.cli.shared")

local M = require("org.extensions.cli.run")

local fail = M.fail
local state = shared.state
local err = shared.err

--- Commands a running Neovim (the session server, |org-remote|) runs for
--- the command line: all but export, schema, version and mcp (whose tool
--- calls go there one by one), and those `org mcp` runs in its own.
M.SESSION_COMMANDS = {}
for name in pairs(M.COMMANDS) do
  if name ~= "export" and name ~= "schema" and name ~= "version" and name ~= "mcp" and name ~= "lsp" then
    M.SESSION_COMMANDS[name] = true
  end
end

--- Does `argv` read stdin (TEXT "-", --input -)?
local function reads_stdin(argv)
  for i, a in ipairs(argv) do
    if a == "--" then
      return argv[i + 1] == "-"
    end
    if a == "-" or a == "--input=-" then
      return true
    end
  end
  return false
end

--- Send the command to the session server when one listens: its exit
--- code, after printing its output, or nil to run it here (nothing
--- listens, it waits for input, `--no-server`, `--config`, `--files` or
--- `--dir`, `ORG_NVIM_SERVER=none`).
---@param argv string[]
---@param command string
---@param flags table
---@return integer|nil
function M.forward(argv, command, flags)
  local remote = require("org.remote")
  if
    not M.SESSION_COMMANDS[command]
    or flags.no_server
    or flags.config
    or flags.dir
    or #flags.files > 0
    or remote.disabled_by_env()
  then
    return nil
  end
  local stdin
  if reads_stdin(argv) then
    stdin = M.read_stdin()
    -- read once: a command run here gets the same text
    M.read_stdin = function()
      return stdin
    end
  end
  local address = remote.address()
  local res, e, reason = remote.request("cli", { argv = argv, cwd = vim.fn.getcwd(), stdin = stdin })
  if reason == "unreachable" then
    return nil
  end
  if reason == "busy" then
    vim.notify(tostring(e) .. "; running the command here", vim.log.levels.WARN)
    return nil
  end
  if type(res) ~= "table" then
    fail("the Neovim on " .. address .. " failed: " .. tostring(e), "failed", { server = address })
  end
  if state.verbose then
    err("ran in the Neovim on " .. address)
  end
  M.stdout(res.out or "")
  M.stderr(res.err or "")
  return tonumber(res.code) or 1
end

--- Keep the agenda options, which commands may set (a custom command's
--- span). Returns the function that puts them back.
---@return fun()
local function keep_agenda_options()
  local config = require("org.config")
  local agenda_opts = config.opts.agenda
  local agenda_saved = {}
  for k, v in pairs(agenda_opts) do
    agenda_saved[k] = v
  end
  return function()
    for k in pairs(agenda_opts) do
      if agenda_saved[k] == nil then
        agenda_opts[k] = nil
      end
    end
    for k, v in pairs(agenda_saved) do
      agenda_opts[k] = v
    end
    config.opts.agenda = agenda_opts
  end
end

--- What the session server sets up around a command: the prompts of
--- `M.headless`, the CLI's option overrides and the buffers that already
--- have unsaved changes. Returns the function that undoes it.
---@return fun()
local function session_begin(flags)
  if flags.config or flags.dir or #flags.files > 0 then
    fail("--config, --files and --dir are not for a running Neovim (use --no-server)", "usage")
  end
  require("org").ensure_setup()
  local config = require("org.config")
  local restore_headless = M.headless()
  local saved = {}
  local function set(tbl, k, v)
    saved[#saved + 1] = { tbl, k, tbl[k] }
    tbl[k] = v
  end
  for k, v in pairs(M.OVERRIDES) do
    if type(v) == "table" then
      for k2, v2 in pairs(v) do
        set(config.opts[k], k2, v2)
      end
    else
      set(config.opts, k, v)
    end
  end
  local restore_agenda = keep_agenda_options()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified then
      state.dirty_before[b] = true
    end
  end
  return function()
    for i = #saved, 1, -1 do
      local e = saved[i]
      e[1][e[2]] = e[3]
    end
    restore_agenda()
    restore_headless()
  end
end

--- Forget what this Neovim holds in memory of the clock and the ID
--- database: a command reads them from their files, which another `org`
--- or Neovim may have written since the last one.
local function forget_state()
  if package.loaded["org.clock"] then
    require("org.clock").forget()
  end
  if package.loaded["org.id"] then
    require("org.id").unload()
  end
end

--- The buffers, windows (with their buffers) and current window there
--- are now.
local function layout()
  local bufs, wins = {}, {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    bufs[b] = true
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    wins[w] = vim.api.nvim_win_get_buf(w)
  end
  return { bufs = bufs, wins = wins, win = vim.api.nvim_get_current_win() }
end

--- Close the windows (and so the tab pages) opened since `before` and
--- wipe the buffers loaded since, unsaved changes and all, as a Neovim
--- that exits does.
local function put_back(before)
  if vim.api.nvim_win_is_valid(before.win) then
    pcall(vim.api.nvim_set_current_win, before.win)
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if not before.wins[w] then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  for w, b in pairs(before.wins) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_buf_is_valid(b) and vim.api.nvim_win_get_buf(w) ~= b then
      pcall(vim.api.nvim_win_set_buf, w, b)
    end
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if not before.bufs[b] then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

--- What a server that runs commands one after another in its own Neovim
--- (`org mcp`) sets up around each, so that each runs as it would in a
--- new Neovim with the configuration the server loaded: the prompts of
--- `M.headless`, and the clock and the ID database read again from their
--- files. Returns the function that undoes it, which also puts the
--- agenda options back, closes the windows the command opened and wipes
--- the buffers it loaded, so that the next command reads the files from
--- disk.
---@return fun()
local function resident_begin()
  local restore_headless = M.headless()
  local restore_agenda = keep_agenda_options()
  local before = layout()
  forget_state()
  return function()
    put_back(before)
    forget_state()
    restore_agenda()
    restore_headless()
  end
end

--- Run a command of the command line in this Neovim, for a client (the
--- `cli` request of the session server): `argv` as `org` got it, relative
--- paths taken from `cwd`, `stdin` the text a "-" reads. Returns
--- { code, out, err }: the exit code and what it would print.
---@param argv string[]
---@param cwd? string
---@param stdin? string
---@return { code: integer, out: string, err: string }
function M.serve(argv, cwd, stdin)
  local out_buf, err_buf = {}, {}
  local saved = { stdout = M.stdout, stderr = M.stderr, read_stdin = M.read_stdin }
  local function to_out(s)
    out_buf[#out_buf + 1] = s
  end
  local function to_err(s)
    err_buf[#err_buf + 1] = s
  end
  local function read_stdin()
    return stdin or ""
  end
  M.stdout, M.stderr, M.read_stdin = to_out, to_err, read_stdin
  local ok, code = pcall(M.main, argv, { session = true, cwd = cwd })
  M.stdout, M.stderr, M.read_stdin = saved.stdout, saved.stderr, saved.read_stdin
  if not ok then
    err_buf[#err_buf + 1] = "org: " .. tostring(code) .. "\n"
    code = 1
  end
  return { code = code, out = table.concat(out_buf), err = table.concat(err_buf) }
end

shared.session_begin = session_begin
shared.resident_begin = resident_begin
