---@mod org.babel.lang.screen GNU screen sessions (ob-screen)
---
--- A block is pasted into a screen session (`:session`, default
--- "default"), which is started in a terminal (`:terminal`, default xterm)
--- running `:cmd` (default sh) when it doesn't exist yet.

local ob = require("org.babel.ob")

local M = {}

local function screen()
  return (ob.opts("screen") or {}).location or "screen"
end

--- `org-babel-screen-session-socketname`: the socket of `session` from
--- `screen -ls`, or nil.
function M.socketname(session)
  local res = vim.system({ "sh", "-c", screen() .. " -ls" }, { text = true }):wait()
  for _, l in ipairs(vim.split(res.stdout or "", "\n", { plain = true })) do
    if (l:find("(Attached)", 1, true) or l:find("(Detached)", 1, true)) and l:find(session, 1, true) then
      return vim.split(vim.trim(l), "%s+")[1]
    end
  end
  return nil
end

--- `org-babel-prep-session:screen`: start the terminal with screen and
--- wait for the session.
function M.prep_session(args)
  local session = ob.unq(args.session) or "default"
  local cmd = ob.unq(args.cmd) or "sh"
  local terminal = ob.unq(args.terminal) or "xterm"
  local screenrc = ob.unq(args.screenrc) or "/dev/null"
  local argv = vim.split(terminal, "%s+", { trimempty = true })
  vim.list_extend(argv, { "-T", "org-babel: " .. session, "-e", screen(), "-c", screenrc, "-mS", session, cmd })
  local ok, err = pcall(vim.system, argv, { detach = true })
  if not ok then
    error("Cannot start the terminal " .. terminal .. ": " .. tostring(err), 0)
  end
  local timeout = require("org.config").opts.babel.timeout or 30000
  local found = vim.wait(timeout, function()
    return M.socketname(session) ~= nil
  end, 100)
  if not found then
    error("No screen session " .. session .. " appeared", 0)
  end
end

--- `org-babel-screen-session-write-temp-file`
local function write_temp(body)
  local lines = {}
  for _, l in ipairs(vim.split(body .. "\n", "\n", { plain = true })) do
    if not l:match("^ +$") then
      lines[#lines + 1] = l
    end
  end
  return ob.write(ob.temp(), table.concat(lines, "\n"))
end

--- `org-babel-screen-session-execute-string`
function M.execute_string(session, body)
  local socket = M.socketname(session)
  if socket then
    local tmp = write_temp(body)
    vim.system({ screen(), "-S", socket, "-X", "eval", "msgwait 0", "readreg z " .. tmp, "paste z" })
  end
end

function M.expand(body, args)
  return ob.expand_generic(type(body) == "table" and body or { body }, args, {})
end

function M.prepare(body, args)
  local session = ob.unq(args.session) or "default"
  if not M.socketname(session) then
    M.prep_session(args)
  end
  M.execute_string(session, M.expand(body, args))
  return { value = nil }
end

--- `org-babel-screen-test`: run a block that writes a random string to a
--- file in the default setup and report whether it arrived.
function M.test()
  local random = tostring(math.random(0, 99998))
  local tmp = ob.temp()
  local body = "echo '" .. random .. "' > " .. tmp .. "\nexit\n"
  local args = vim.tbl_extend("force", {
    results = "silent",
    session = "default",
    cmd = "sh",
    terminal = "xterm",
    screenrc = "/dev/null",
  }, (ob.opts("screen") or {}).default_header_args or {})
  local ok, err = pcall(M.prepare, { body }, vim.tbl_extend("force", args, { results_spec = {} }))
  local utils = require("org.utils")
  if not ok then
    utils.notify("org-babel-screen: Setup DOESN'T work. (" .. tostring(err) .. ")")
    return nil
  end
  local timeout = require("org.config").opts.babel.timeout or 30000
  vim.wait(timeout, function()
    return vim.fn.filereadable(tmp) == 1 and (ob.read(tmp) or ""):find("\n") ~= nil
  end, 50)
  local text = ob.read(tmp) or ""
  os.remove(tmp)
  local works = text:find(random, 1, true) ~= nil
  utils.notify("org-babel-screen: Setup " .. (works and "WORKS." or "DOESN'T work."))
  return works or nil
end

return M
