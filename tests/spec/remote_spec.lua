-- The session server (:h org-remote): one Neovim listens on a well-known
-- address and the `org` command line, org-protocol URLs and
-- api.remote.call() run there. Every address here is a scratch socket
-- under this run's temp directory, never the user's real one, and every
-- Neovim started here gets scratch HOME/XDG directories and org files.
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
local remote = require("org.remote")
local is_win = vim.fn.has("win32") == 1

local TODAY = os.date("%Y-%m-%d %a")

--- A scratch address: a short socket path (unix sockets allow ~100
--- bytes), a named pipe on Windows.
local function scratch_address()
  if is_win then
    return "\\\\.\\pipe\\org-nvim-spec-" .. vim.fn.getpid() .. "-" .. math.random(1e6)
  end
  return vim.fn.tempname() .. ".sock"
end

--- A temp directory with work.org, inbox.org, a config and XDG dirs.
local function workspace()
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({
    "#+CATEGORY: work",
    "* TODO Review pull request :code:",
    "  SCHEDULED: <" .. TODAY .. ">",
    "* TODO Write release notes",
  }, dir .. "/work.org")
  vim.fn.writefile({ "* Inbox" }, dir .. "/inbox.org")
  vim.fn.writefile({
    "local dir = " .. vim.inspect(dir),
    "return {",
    "  org_directory = dir,",
    "  default_notes_file = dir .. '/notes.org',",
    "  agenda_files = { dir .. '/work.org', dir .. '/inbox.org' },",
    "  capture = { templates = {",
    "    t = { description = 'Task', target = dir .. '/inbox.org', headline = 'Inbox',",
    "          template = '* TODO %?' },",
    "    p = { description = 'Protocol', target = dir .. '/inbox.org', headline = 'Inbox',",
    "          template = '* %:description\\n  %:link' },",
    "  } },",
    "  clock = { persist = true, persist_file = dir .. '/clock.json' },",
    "}",
  }, dir .. "/cfg.lua")
  for _, d in ipairs({ "home", "xdg-config", "xdg-state", "xdg-cache", "xdg-data" }) do
    vim.fn.mkdir(dir .. "/" .. d, "p")
  end
  return dir
end

local function env(dir, address)
  return {
    HOME = dir .. "/home",
    XDG_CONFIG_HOME = dir .. "/xdg-config",
    XDG_STATE_HOME = dir .. "/xdg-state",
    XDG_CACHE_HOME = dir .. "/xdg-cache",
    XDG_DATA_HOME = dir .. "/xdg-data",
    ORG_NVIM_BIN = vim.v.progpath,
    ORG_NVIM_CONFIG = dir .. "/cfg.lua",
    ORG_NVIM_SERVER = address or "none",
  }
end

local function read(path)
  return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
end

local function contains(lines, pat)
  for _, l in ipairs(lines) do
    if l:find(pat, 1, true) then
      return true
    end
  end
  return false
end

--- Run bin/org (stdin closed) against `address`: code, stdout, stderr.
local function org(dir, address, args)
  local cmd = vim.list_extend({ require("org.extensions.cli").bin() }, args)
  local res = vim.system(cmd, { text = true, stdin = false, env = env(dir, address), cwd = dir }):wait(30000)
  return res.code, res.stdout or "", res.stderr or ""
end

-- Neovims started by server(), stopped in after_each
local servers = {}

--- A headless Neovim that sets org up with the workspace's config and
--- `remote = { enabled = true, address = address }`, then runs `lua`
--- (optional). Returns its job and an RPC channel to it.
local function server(dir, address, lua)
  local script = dir .. "/server-" .. #servers .. ".lua"
  vim.fn.writefile({
    -- tests/minimal_init.lua sets ORG_NVIM_SERVER=none: this one serves
    "vim.env.ORG_NVIM_SERVER = nil",
    "vim.o.swapfile = false",
    "local cfg = dofile(" .. vim.inspect(dir .. "/cfg.lua") .. ")",
    "cfg.remote = { enabled = true, address = " .. vim.inspect(address) .. " }",
    "require('org').setup(cfg)",
    -- quits by itself should this spec die first
    "vim.fn.timer_start(120000, function() vim.cmd('qa!') end)",
    lua or "",
  }, script)
  local e = env(dir, nil)
  e.ORG_NVIM_SERVER = nil
  local job = vim.system({
    vim.v.progpath,
    "--headless",
    "-n",
    "-i",
    "NONE",
    "-u",
    root .. "/tests/minimal_init.lua",
    "-c",
    "luafile " .. vim.fn.fnameescape(script),
  }, { env = e, cwd = dir })
  servers[#servers + 1] = job
  local chan
  vim.wait(15000, function()
    chan = remote.connect(address)
    if chan and pcall(vim.rpcrequest, chan, "nvim_exec_lua", "return require('org.remote').is_server()", {}) then
      return true
    end
    if chan then
      pcall(vim.fn.chanclose, chan)
      chan = nil
    end
    return false
  end, 50)
  ok(chan, "the server Neovim did not start")
  return job, chan
end

--- Evaluate Lua in the Neovim on `chan`.
local function eval(chan, code, ...)
  return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... })
end

describe("remote: addresses", function()
  it("defaults to org.nvim.sock in a directory every Neovim of the user shares", function()
    local a = remote.default_address()
    if is_win then
      ok(a:match("^\\\\%.\\pipe\\org%.nvim%."), a)
      return
    end
    ok(a:match("/org%.nvim%.sock$"), a)
    -- not this process's own temp directory
    local mine = vim.fs.dirname(vim.fs.normalize(vim.fn.tempname()))
    ok(vim.fs.dirname(a) ~= mine, "the per-process temp directory: " .. a)
  end)

  it("takes $ORG_NVIM_SERVER, then remote.address", function()
    local saved = vim.env.ORG_NVIM_SERVER
    vim.env.ORG_NVIM_SERVER = nil
    local config = require("org.config")
    config.opts.remote.address = "/x/y.sock"
    eq("/x/y.sock", remote.address())
    vim.env.ORG_NVIM_SERVER = "/a/b.sock"
    eq("/a/b.sock", remote.address())
    vim.env.ORG_NVIM_SERVER = "none"
    ok(remote.disabled_by_env())
    eq("/x/y.sock", remote.address())
    config.opts.remote.address = nil
    vim.env.ORG_NVIM_SERVER = saved
  end)
end)

describe("remote: the server", function()
  after_each(function()
    remote.stop()
    for _, job in ipairs(servers) do
      pcall(job.kill, job, 9)
      pcall(job.wait, job, 5000)
    end
    servers = {}
  end)

  it("listens on its address, and setup() leaves it off by default", function()
    local a = scratch_address()
    eq(a, remote.start(a))
    ok(remote.is_server())
    ok(vim.tbl_contains(vim.fn.serverlist(), a))
    -- starting again is a no-op
    eq(a, remote.start(a))
    remote.stop()
    ok(not remote.is_server())
    ok(not vim.tbl_contains(vim.fn.serverlist(), a))
  end)

  it("does not serve with ORG_NVIM_SERVER=none or in the command line", function()
    local a = scratch_address()
    local config = require("org.config")
    config.opts.remote.enabled = true
    config.opts.remote.address = a
    -- the test suite runs with ORG_NVIM_SERVER=none
    remote.setup()
    ok(not remote.is_server())
    local saved = vim.env.ORG_NVIM_SERVER
    vim.env.ORG_NVIM_SERVER = nil
    remote.inhibit = true
    remote.setup()
    ok(not remote.is_server())
    remote.inhibit = false
    remote.setup()
    ok(remote.is_server())
    eq(a, remote.serving)
    -- turned off again
    config.opts.remote.enabled = false
    remote.setup()
    ok(not remote.is_server())
    vim.env.ORG_NVIM_SERVER = saved
    config.opts.remote.address = nil
  end)

  it("has one owner: a second Neovim doesn't take the address, and doesn't fail", function()
    local dir = workspace()
    local a = scratch_address()
    local _, chan = server(dir, a)
    eq(true, eval(chan, "return require('org.remote').is_server()"))
    -- this Neovim is the second instance
    local got, err = remote.start(a)
    eq(nil, got)
    ok(tostring(err):find("another Neovim", 1, true), err)
    ok(not remote.is_server())
    -- and setup() with remote.enabled is quiet about it
    local saved = vim.env.ORG_NVIM_SERVER
    vim.env.ORG_NVIM_SERVER = nil
    local config = require("org.config")
    config.opts.remote.enabled = true
    config.opts.remote.address = a
    remote.setup()
    ok(not remote.is_server())
    config.opts.remote.enabled = false
    config.opts.remote.address = nil
    remote.setup()
    vim.env.ORG_NVIM_SERVER = saved
    -- the first one still answers
    local res = remote.request("ping", nil, { address = a })
    eq(eval(chan, "return vim.fn.getpid()"), res.pid)
  end)

  it("takes over a stale socket left by a Neovim that died", function()
    if is_win then
      return -- named pipes go away with their process
    end
    local dir = workspace()
    local a = scratch_address()
    local job = server(dir, a)
    job:kill(9)
    job:wait(5000)
    ok(vim.uv.fs_stat(a), "the socket file stays")
    eq(a, remote.start(a))
    ok(remote.is_server())
  end)

  it("leaves a file that is not a socket alone", function()
    if is_win then
      return
    end
    local a = scratch_address()
    vim.fn.writefile({ "not a socket" }, a)
    local got, err = remote.start(a)
    eq(nil, got)
    ok(tostring(err):find("not a socket", 1, true), err)
    eq({ "not a socket" }, read(a))
  end)

  it("answers requests in the server itself without a connection", function()
    local a = scratch_address()
    remote.start(a)
    local res = remote.request("ping", nil, { address = a })
    eq(vim.fn.getpid(), res.pid)
    local _, err, reason = remote.request("nope", nil, { address = a })
    eq("failed", reason)
    ok(err:find("unknown request", 1, true))
  end)

  it("reports an address nothing listens on as unreachable", function()
    local res, _, reason = remote.request("ping", nil, { address = scratch_address() })
    eq(nil, res)
    eq("unreachable", reason)
  end)
end)

describe("remote: forwarding to a running Neovim", function()
  after_each(function()
    for _, job in ipairs(servers) do
      pcall(job.kill, job, 9)
      pcall(job.wait, job, 5000)
    end
    servers = {}
  end)

  it("captures from the command line into the Neovim's open buffer", function()
    local dir = workspace()
    local a = scratch_address()
    local _, chan = server(dir, a, "vim.cmd.edit(" .. vim.inspect(dir .. "/inbox.org") .. ")")
    local code, out, errs = org(dir, a, { "capture", "-t", "t", "Buy", "milk" })
    eq(0, code, errs)
    ok(out:find("Captured to", 1, true), out)
    local lines = eval(chan, "return vim.api.nvim_buf_get_lines(0, 0, -1, false)")
    eq({ "* Inbox", "** TODO Buy milk" }, lines)
    -- one undo step in that Neovim takes it back
    eq(false, eval(chan, "return vim.bo.modified"))
    eval(chan, "vim.cmd('silent undo')")
    eq({ "* Inbox" }, eval(chan, "return vim.api.nvim_buf_get_lines(0, 0, -1, false)"))
    -- it was saved, as a capture in that Neovim saves it
    eq({ "* Inbox", "** TODO Buy milk" }, read(dir .. "/inbox.org"))
  end)

  it("keeps the Neovim's unsaved changes unsaved", function()
    local dir = workspace()
    local a = scratch_address()
    local _, chan = server(
      dir,
      a,
      "vim.cmd.edit("
        .. vim.inspect(dir .. "/inbox.org")
        .. "); vim.api.nvim_buf_set_lines(0, 1, 1, false, { 'typed' })"
    )
    local code, _, errs = org(dir, a, { "capture", "-t", "t", "Call", "Bob" })
    eq(0, code, errs)
    ok(errs:find("unsaved changes", 1, true), errs)
    local lines = eval(chan, "return vim.api.nvim_buf_get_lines(0, 0, -1, false)")
    ok(contains(lines, "typed"))
    ok(contains(lines, "TODO Call Bob"))
    eq(true, eval(chan, "return vim.bo.modified"))
    -- the file on disk is as it was
    eq({ "* Inbox" }, read(dir .. "/inbox.org"))
  end)

  it("clocks in and out in the Neovim's own clock", function()
    local dir = workspace()
    local a = scratch_address()
    local _, chan = server(dir, a)
    local code, _, errs = org(dir, a, { "clock", "in", "Write release notes" })
    eq(0, code, errs)
    eq("Write release notes", eval(chan, "return (require('org.api').clock.status() or {}).title"))
    local code2, out = org(dir, a, { "clock", "status", "--short", "--format", "%t" })
    eq(0, code2)
    eq("Write release notes", vim.trim(out))
    local code3, _, errs3 = org(dir, a, { "clock", "out" })
    eq(0, code3, errs3)
    eq(false, eval(chan, "return require('org.api').clock.is_running()"))
    ok(contains(read(dir .. "/work.org"), "CLOCK: ["))
  end)

  it("changes TODO states and builds agendas without touching the Neovim's windows", function()
    local dir = workspace()
    local a = scratch_address()
    local _, chan = server(dir, a, "vim.cmd.edit(" .. vim.inspect(dir .. "/work.org") .. ")")
    local wins = eval(chan, "return #vim.api.nvim_list_wins()")
    local code, out, errs = org(dir, a, { "agenda", "day" })
    eq(0, code, errs)
    ok(out:find("Review pull request", 1, true), out)
    eq(wins, eval(chan, "return #vim.api.nvim_list_wins()"))
    eq("org", eval(chan, "return vim.bo.filetype"))
    eq(
      0,
      eval(
        chan,
        [[
        local n = 0
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.bo[b].filetype == "orgagenda" then n = n + 1 end
        end
        return n
      ]]
      )
    )
    code, out, errs = org(dir, a, { "--json", "set", "todo", "Write release notes", "DONE" })
    eq(0, code, errs)
    local res = vim.json.decode(out)
    eq("DONE", res.data.new)
    ok(contains(eval(chan, "return vim.api.nvim_buf_get_lines(0, 0, -1, false)"), "DONE Write release notes"))
  end)

  it("leaves an agenda open in the Neovim as it is", function()
    local dir = workspace()
    local a = scratch_address()
    local _, chan = server(dir, a, "require('org.agenda').open_todo()")
    local function view()
      return eval(
        chan,
        [[
        local S = require("org.agenda.view").state
        return { buf = S.buf, win = vim.api.nvim_get_current_win(),
          lines = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false), wins = #vim.api.nvim_list_wins() }
      ]]
      )
    end
    local before = view()
    ok(contains(before.lines, "Write release notes"))
    local code, out, errs = org(dir, a, { "agenda", "tags", "+code" })
    eq(0, code, errs)
    ok(out:find("Review pull request", 1, true), out)
    ok(not out:find("Write release notes", 1, true), out)
    eq(before, view())
  end)

  it("reads stdin and relative paths on the client's side", function()
    local dir = workspace()
    local a = scratch_address()
    server(dir, a)
    vim.fn.writefile({ vim.json.encode({ template = "t", text = "From a file" }) }, dir .. "/in.json")
    local code, _, errs = org(dir, a, { "capture", "--input", "in.json" })
    eq(0, code, errs)
    ok(contains(read(dir .. "/inbox.org"), "TODO From a file"))
  end)

  it("sends org-protocol URLs to the Neovim", function()
    local dir = workspace()
    local a = scratch_address()
    local _, chan = server(dir, a)
    local code, out, errs =
      org(dir, a, { "protocol", "org-protocol://store-link?url=https%3A%2F%2Fexample.com&title=Example" })
    eq(0, code, errs)
    ok(out:find("Sent to Neovim", 1, true), out)
    local stored
    vim.wait(5000, function()
      stored = eval(chan, "return require('org.api').links.stored()")
      return #stored > 0
    end, 20)
    eq("https://example.com", stored[#stored].link)
  end)

  it("calls org.api functions in the server with api.remote.call", function()
    local dir = workspace()
    local a = scratch_address()
    local _, chan = server(dir, a, "vim.cmd.edit(" .. vim.inspect(dir .. "/inbox.org") .. ")")
    local saved = vim.env.ORG_NVIM_SERVER
    vim.env.ORG_NVIM_SERVER = a
    local api = require("org.api")
    ok(api.remote.reachable())
    ok(not api.remote.is_server())
    eq(a, api.remote.address())
    local res, err = api.remote.call("capture", { template = "* TODO Remote task", target = dir .. "/inbox.org" })
    vim.env.ORG_NVIM_SERVER = saved
    eq(nil, err)
    eq(vim.fn.resolve(dir .. "/inbox.org"), vim.fn.resolve(res.file))
    eq("Remote task", res.headline.title)
    ok(contains(eval(chan, "return vim.api.nvim_buf_get_lines(0, 0, -1, false)"), "TODO Remote task"))
    -- an unknown function
    local none, err2 = api.remote.call("no_such_function")
    eq(nil, none)
    ok(err2:find("no org.api function", 1, true))
  end)

  it("a command runs here when the Neovim waits for input or is turned off", function()
    local run = require("org.extensions.cli.run")
    local saved_request, saved_notify, saved_env = remote.request, vim.notify, vim.env.ORG_NVIM_SERVER
    local sent, warned = 0, {}
    remote.request = function()
      sent = sent + 1
      return nil, "the Neovim on x is waiting for input", "busy"
    end
    vim.notify = function(msg)
      warned[#warned + 1] = msg
    end
    vim.env.ORG_NVIM_SERVER = scratch_address()
    local flags = run.parse_args({ "capture", "x" })
    local okf, res = pcall(run.forward, { "capture", "x" }, "capture", flags)
    local res_none
    vim.env.ORG_NVIM_SERVER = "none"
    local ok_none = pcall(function()
      res_none = run.forward({ "capture", "x" }, "capture", flags)
    end)
    local no_server = run.forward({ "--no-server", "capture", "x" }, "capture", run.parse_args({ "--no-server" }))
    local export = run.forward({ "export", "a.org", "html" }, "export", flags)
    remote.request, vim.notify, vim.env.ORG_NVIM_SERVER = saved_request, saved_notify, saved_env
    ok(okf, res)
    eq(nil, res)
    ok(warned[1] and warned[1]:find("running the command here", 1, true), vim.inspect(warned))
    ok(ok_none)
    eq(nil, res_none)
    eq(nil, no_server)
    eq(nil, export)
    -- only the first one asked the server
    eq(1, sent)
  end)
end)

describe("remote: without a server", function()
  it("the command line works on the files, as before", function()
    local dir = workspace()
    local code, out, errs = org(dir, scratch_address(), { "capture", "-t", "t", "Offline" })
    eq(0, code, errs)
    ok(out:find("Captured to", 1, true))
    ok(contains(read(dir .. "/inbox.org"), "TODO Offline"))
    -- ORG_NVIM_SERVER=none too
    code, _, errs = org(dir, "none", { "set", "todo", "Offline", "DONE" })
    eq(0, code, errs)
    ok(contains(read(dir .. "/inbox.org"), "DONE Offline"))
  end)

  it("stores an org-protocol capture at once, and needs a Neovim for the rest", function()
    local dir = workspace()
    local a = scratch_address()
    local url = "org-protocol://capture?template=p&url=https%3A%2F%2Fexample.org&title=Example%20page"
    local code, out, errs = org(dir, a, { "protocol", url })
    eq(0, code, errs)
    ok(out:find("Captured to", 1, true), out)
    local lines = read(dir .. "/inbox.org")
    ok(contains(lines, "** Example page"), table.concat(lines, "\n"))
    ok(contains(lines, "https://example.org"), table.concat(lines, "\n"))
    code, _, errs = org(dir, a, { "protocol", "org-protocol://store-link?url=https%3A%2F%2Fexample.org" })
    eq(1, code)
    ok(errs:find("needs a running Neovim", 1, true), errs)
  end)

  it("api.remote.call runs the function here", function()
    local saved = vim.env.ORG_NVIM_SERVER
    vim.env.ORG_NVIM_SERVER = scratch_address()
    local api = require("org.api")
    ok(not api.remote.reachable())
    local files = api.remote.call("agenda_files")
    vim.env.ORG_NVIM_SERVER = saved
    eq(api.agenda_files(), files)
  end)
end)
