---@mod org.remote The session server: one running Neovim takes org requests
---
--- With `remote.enabled`, the first Neovim that sets org up listens on a
--- well-known address (`remote.address`, see |org-remote|). The `org`
--- command line, org-protocol URLs and `api.remote.call()` send their
--- requests there, so they edit that Neovim's buffers (undo, unsaved
--- changes and the running clock stay its own) instead of the files
--- behind its back. When nothing listens, they work as before.
---
--- Requests arrive as `nvim_exec_lua` calls of `M.dispatch(method,
--- params)`; a client sends them with `M.request()`.

local M = {}

--- Set by processes that must never become the server (the `org`
--- command line loads the same configuration).
M.inhibit = false

--- The address this Neovim serves (nil when it doesn't).
---@type string|nil
M.serving = nil

local is_win = vim.fn.has("win32") == 1

local function cfg()
  return require("org.config").opts.remote or {}
end

--- The default address: `org.nvim.sock` in the per-user runtime
--- directory ($XDG_RUNTIME_DIR, else Neovim's `nvim.<user>` directory
--- under the temp directory), a named pipe on Windows.
---@return string
function M.default_address()
  if is_win then
    local user = (vim.env.USERNAME or vim.env.USER or "user"):gsub("[^%w_.-]", "_")
    return "\\\\.\\pipe\\org.nvim." .. user
  end
  local run = vim.fs.normalize(vim.fn.stdpath("run"))
  -- without $XDG_RUNTIME_DIR, stdpath("run") is this process's own temp
  -- directory (nvim.<user>/XXXXXX): its parent is the same for every
  -- Neovim of the user
  local tmp = vim.fs.normalize(vim.fn.tempname())
  if tmp:sub(1, #run + 1) == run .. "/" then
    run = vim.fs.dirname(run)
  end
  return run .. "/org.nvim.sock"
end

--- `$ORG_NVIM_SERVER` set to "none": no session server, here or as a
--- client (the test suite sets it).
---@return boolean
function M.disabled_by_env()
  return vim.env.ORG_NVIM_SERVER == "none"
end

--- The address of the session server: `$ORG_NVIM_SERVER`, else
--- `remote.address`, else |M.default_address|.
---@return string
function M.address()
  local env = vim.env.ORG_NVIM_SERVER
  if env and env ~= "" and env ~= "none" then
    return env
  end
  local a = cfg().address
  if type(a) == "function" then
    a = a()
  end
  if type(a) == "string" and a ~= "" then
    return require("org.utils").expand_vars(a)
  end
  return M.default_address()
end

--- Is a unix socket `address` a file system path?
local function is_path(address)
  return not is_win and not address:match("^[%w.-]+:%d+$")
end

--- Connect to `address`: an RPC channel, or nil and the error.
---@param address string
---@return integer|nil chan, string|nil err
function M.connect(address)
  local ok, chan = pcall(vim.fn.sockconnect, "pipe", address, { rpc = true })
  if ok and type(chan) == "number" and chan > 0 then
    return chan
  end
  return nil, ok and "connection failed" or tostring(chan)
end

local function close(chan)
  pcall(vim.fn.chanclose, chan)
end

--- Is another process listening on `address`?
local function listening(address)
  local chan = M.connect(address)
  if chan then
    close(chan)
    return true
  end
  return false
end

--- Does this Neovim listen on `address`?
local function own(address)
  for _, a in ipairs(vim.fn.serverlist()) do
    if a == address then
      return true
    end
  end
  return false
end

--- Listen on `address` (default `M.address()`), unless another Neovim
--- already does: only one owns it. A socket file nothing listens on (left
--- by a Neovim that crashed) is removed first. Returns the address, or
--- nil and why not.
---@param address? string
---@return string|nil address, string|nil err
function M.start(address)
  address = address or M.address()
  if M.serving == address and own(address) then
    return address
  end
  if own(address) then
    M.serving = address
    return address
  end
  if listening(address) then
    return nil, "another Neovim listens on " .. address
  end
  if is_path(address) then
    local st = vim.uv.fs_stat(address)
    if st and st.type ~= "socket" then
      return nil, address .. " exists and is not a socket"
    end
    if st then
      -- stale: nothing answered; look once more right before removing it
      if listening(address) then
        return nil, "another Neovim listens on " .. address
      end
      os.remove(address)
    end
    vim.fn.mkdir(vim.fs.dirname(address), "p", tonumber("700", 8))
  end
  local ok, res = pcall(vim.fn.serverstart, address)
  if not ok then
    return nil, tostring(res)
  end
  M.serving = address
  return address
end

--- Stop serving.
function M.stop()
  if M.serving then
    pcall(vim.fn.serverstop, M.serving)
    M.serving = nil
  end
end

--- Is this Neovim the session server?
---@return boolean
function M.is_server()
  return M.serving ~= nil and own(M.serving)
end

local group

--- Called by `setup()`: serve when `remote.enabled`, and try again when
--- Neovim gets the focus while another instance owns the address (it may
--- have quit since).
function M.setup()
  if group then
    pcall(vim.api.nvim_del_augroup_by_id, group)
    group = nil
  end
  if not cfg().enabled or M.inhibit or M.disabled_by_env() then
    M.stop()
    return
  end
  local want = M.address()
  if M.serving and M.serving ~= want then
    M.stop()
  end
  M.start(want)
  group = vim.api.nvim_create_augroup("org_remote", { clear = true })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      if cfg().enabled and not M.is_server() then
        M.start()
      end
    end,
  })
end

---------------------------------------------------------------------------
-- Requests
---------------------------------------------------------------------------

--- A copy of `v` that can cross RPC: functions and userdata dropped,
--- metatables ignored, cycles cut, a table that isn't a list keeps only
--- its string keys.
---@param v any
---@param seen? table
---@return any
function M.plain(v, seen)
  local t = type(v)
  if t == "function" or t == "thread" or (t == "userdata" and v ~= vim.NIL) then
    return nil
  end
  if t ~= "table" then
    return v
  end
  seen = seen or {}
  if seen[v] then
    return nil
  end
  seen[v] = true
  local out = {}
  if vim.islist(v) then
    for i, x in ipairs(v) do
      local px = M.plain(x, seen)
      out[i] = px == nil and vim.NIL or px
    end
  else
    for k, x in pairs(v) do
      if type(k) == "string" then
        out[k] = M.plain(x, seen)
      end
    end
  end
  seen[v] = nil
  return out
end

--- `...` as a list that can cross RPC: nil as vim.NIL, and its length.
---@return { n: integer, values: any[] }
function M.pack(...)
  local n = select("#", ...)
  local values = {}
  for i = 1, n do
    local x = M.plain((select(i, ...)))
    values[i] = x == nil and vim.NIL or x
  end
  return { n = n, values = values }
end

--- The values of `M.pack()`, vim.NIL back to nil.
---@param p { n: integer, values: any[] }
---@return any ...
function M.unpack(p)
  local values = {}
  for i = 1, p.n or #p.values do
    local x = p.values[i]
    if x ~= vim.NIL then
      values[i] = x
    end
  end
  return unpack(values, 1, p.n or #p.values)
end

--- The org.api function `name` ("capture", "clock.status", ...), or nil.
---@param name string
---@return function|nil
function M.api_function(name)
  local fn = require("org.api")
  for part in tostring(name):gmatch("[^.]+") do
    if type(fn) ~= "table" then
      return nil
    end
    fn = fn[part]
  end
  return type(fn) == "function" and fn or nil
end

--- Request handlers of the server: method -> function(params) returning
--- plain data.
M.handlers = {
  --- Is the server there? Its pid and address.
  ping = function()
    return { pid = vim.fn.getpid(), address = M.serving, version = require("org.version").release }
  end,
  --- `params.name`: an org.api function ("capture", "clock.status"),
  --- `params.args`: its arguments as `M.pack()` gives them. Returns its
  --- results the same way.
  api = function(params)
    local fn = M.api_function(params.name)
    if not fn then
      error("no org.api function " .. tostring(params.name), 0)
    end
    return M.pack(fn(M.unpack(params.args or { n = 0, values = {} })))
  end,
  --- `params.url`: an org-protocol URL, handled once the request has
  --- returned (a capture opens its window as usual).
  protocol = function(params)
    local url = params.url
    if type(url) ~= "string" or not url:match("org%-protocol:") then
      error("not an org-protocol URL: " .. tostring(url), 0)
    end
    vim.schedule(function()
      require("org.protocol").handle(url)
    end)
    return true
  end,
  --- A command of the `org` command line: `params.argv`, run in the
  --- client's directory `params.cwd`. Returns { code, out, err }.
  cli = function(params)
    return require("org.extensions.cli.run").serve(params.argv or {}, params.cwd)
  end,
}

--- Run request `method` (called by clients through `nvim_exec_lua`).
--- Returns { ok = true, result } or { ok = false, error }.
---@param method string
---@param params? table
---@return table
function M.dispatch(method, params)
  require("org").ensure_setup()
  local h = M.handlers[method]
  if not h then
    return { ok = false, error = "unknown request " .. tostring(method) }
  end
  local ok, res = pcall(h, type(params) == "table" and params or {})
  if not ok then
    return { ok = false, error = tostring(res) }
  end
  return { ok = true, result = res == nil and vim.NIL or res }
end

--- Send request `method` to the session server. Returns the result, or
--- nil, an error and a reason: "unreachable" (nothing listens), "busy"
--- (it waits for input: a prompt, a pending operator) or "failed".
--- In the server itself the request runs directly.
---@param method string
---@param params? table
---@param opts? { address?: string }
---@return any result, string|nil err, string|nil reason
function M.request(method, params, opts)
  opts = opts or {}
  local address = opts.address or M.address()
  if M.serving == address and own(address) then
    local res = M.dispatch(method, params)
    if not res.ok then
      return nil, res.error, "failed"
    end
    return res.result
  end
  local chan, err = M.connect(address)
  if not chan then
    return nil, "no Neovim listens on " .. address .. " (" .. tostring(err) .. ")", "unreachable"
  end
  local ok, mode = pcall(vim.rpcrequest, chan, "nvim_get_mode")
  if not ok then
    close(chan)
    return nil, "no answer from " .. address .. ": " .. tostring(mode), "unreachable"
  end
  if type(mode) == "table" and mode.blocking then
    close(chan)
    return nil, "the Neovim on " .. address .. " is waiting for input", "busy"
  end
  local ok2, res = pcall(
    vim.rpcrequest,
    chan,
    "nvim_exec_lua",
    "return require('org.remote').dispatch(...)",
    { method, params or vim.empty_dict() }
  )
  close(chan)
  if not ok2 then
    return nil, tostring(res), "failed"
  end
  if type(res) ~= "table" then
    return nil, "unexpected answer from " .. address, "failed"
  end
  if not res.ok then
    return nil, tostring(res.error), "failed"
  end
  if res.result == vim.NIL then
    return nil
  end
  return res.result
end

return M
