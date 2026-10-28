-- `org mcp`: the command line as an MCP server (JSON-RPC 2.0 on stdin and
-- stdout), its tools, their arguments and the read-only mode.
local mcp = require("org.extensions.cli.mcp")
local schema = require("org.extensions.cli.schema")

--- A temp directory with home.org, a config file and XDG dirs.
local function workspace()
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({
    "* TODO Buy milk :errand:",
    "* Projects",
    "** NEXT Garden",
    "** NEXT Garden",
  }, dir .. "/home.org")
  vim.fn.writefile({
    "local dir = " .. vim.inspect(dir),
    "return {",
    "  org_directory = dir,",
    "  agenda_files = { dir .. '/home.org' },",
    "  default_notes_file = dir .. '/notes.org',",
    "  todo_keywords = { 'TODO NEXT | DONE' },",
    "  capture = { templates = {",
    "    t = { description = 'Task', target = dir .. '/inbox.org', template = '* TODO %?' },",
    "  } },",
    "}",
  }, dir .. "/cfg.lua")
  for _, d in ipairs({ "config", "state", "cache" }) do
    vim.fn.mkdir(dir .. "/xdg-" .. d, "p")
  end
  return dir
end

local function env(dir)
  return {
    ORG_NVIM_CONFIG = "",
    ORG_NVIM_SERVER = "none",
    XDG_CONFIG_HOME = dir .. "/xdg-config",
    XDG_STATE_HOME = dir .. "/xdg-state",
    XDG_CACHE_HOME = dir .. "/xdg-cache",
    XDG_DATA_HOME = vim.env.XDG_DATA_HOME or (dir .. "/xdg-data"),
    ORG_NVIM_BIN = vim.v.progpath,
  }
end

--- Run `org mcp` with `messages` (tables, or strings sent as they are) on
--- stdin; returns the decoded responses by id (and in order), stdout,
--- stderr and the exit code.
local function serve(dir, messages, args)
  local lines = {}
  for _, m in ipairs(messages) do
    lines[#lines + 1] = type(m) == "string" and m or vim.json.encode(m)
  end
  local cmd = { require("org.extensions.cli").bin(), "--config", dir .. "/cfg.lua", "mcp" }
  vim.list_extend(cmd, args or {})
  local res =
    vim.system(cmd, { text = true, stdin = table.concat(lines, "\n") .. "\n", env = env(dir), cwd = dir }):wait(60000)
  local by_id, list = {}, {}
  for _, l in ipairs(vim.split(vim.trim(res.stdout or ""), "\n", { plain = true })) do
    if l ~= "" then
      local okd, msg = pcall(vim.json.decode, l)
      ok(okd, "not JSON on stdout: " .. l)
      list[#list + 1] = msg
      if type(msg) == "table" and msg.id ~= nil and msg.id ~= vim.NIL then
        by_id[msg.id] = msg
      end
    end
  end
  return by_id, list, res
end

local function call(id, name, arguments)
  return {
    jsonrpc = "2.0",
    id = id,
    method = "tools/call",
    params = { name = name, arguments = arguments or vim.empty_dict() },
  }
end

local INIT = {
  jsonrpc = "2.0",
  id = 1,
  method = "initialize",
  params = { protocolVersion = "2025-06-18", capabilities = vim.empty_dict(), clientInfo = { name = "spec" } },
}
local INITIALIZED = { jsonrpc = "2.0", method = "notifications/initialized" }

--- The JSON a tool result holds as its (first) text.
local function result(res)
  ok(res and res.result, vim.inspect(res))
  return vim.json.decode(res.result.content[1].text)
end

local function names(tools)
  return vim.tbl_map(function(t)
    return t.name
  end, tools)
end

describe("cli mcp: tools and arguments", function()
  it("makes a tool of every command but schema, help, version, protocol, mcp and lsp", function()
    local tools = mcp.tools(false)
    local got = names(tools)
    for _, c in ipairs(schema.COMMANDS) do
      local name = c.name:gsub(" ", "_")
      local skip = ({ schema = true, help = true, version = true, protocol = true, mcp = true, lsp = true })[c.name]
      eq(not skip, vim.tbl_contains(got, name), name)
    end
    local set_todo = tools[vim.fn.index(got, "set_todo") + 1]
    eq({ "target", "state" }, set_todo.inputSchema.required)
    eq(nil, set_todo.inputSchema.properties.force)
    ok(set_todo.inputSchema.properties.note)
    eq(false, set_todo.annotations.readOnlyHint)
    eq(true, set_todo.annotations.destructiveHint)
    local agenda = tools[vim.fn.index(got, "agenda") + 1]
    eq(true, agenda.annotations.readOnlyHint)
    eq(nil, agenda.inputSchema.properties.csv)
    eq(nil, agenda.inputSchema.required)
    local capture = tools[vim.fn.index(got, "capture") + 1]
    eq(nil, capture.inputSchema.properties.input)
    eq(false, capture.annotations.destructiveHint)
  end)

  it("lists only the tools that don't write when read-only", function()
    local got = names(mcp.tools(true))
    eq({ "agenda", "search", "headlines", "show", "clock_status", "templates", "files", "tags", "keywords" }, got)
  end)

  it("turns arguments into the command line", function()
    local c = schema.BY_COMMAND
    eq(
      { "set", "todo", "--note", "Done at last", "--", "Write report", "DONE" },
      mcp.argv(c["set todo"], {
        target = "Write report",
        state = "DONE",
        note = "Done at last",
      })
    )
    eq(
      { "headlines", "--todo", "NEXT", "--todo", "TODO", "--limit", "3", "--archived", "--" },
      mcp.argv(c.headlines, { todo = { "NEXT", "TODO" }, limit = 3, archived = true })
    )
    eq(
      { "capture", "--template", "t", "--", "Call the dentist" },
      mcp.argv(c.capture, { template = "t", text = "Call the dentist" })
    )
    -- no limit: one more than LIST_LIMIT, to tell a cut list
    local argv, cap = mcp.argv(c.search, { query = { "a", "b" } })
    eq({ "search", "--limit", tostring(mcp.LIST_LIMIT + 1), "--", "a", "b" }, argv)
    eq(mcp.LIST_LIMIT, cap)
    eq(nil, select(2, mcp.argv(c.search, { query = "a", limit = 500 })))
    eq({ "clock", "status", "--" }, mcp.argv(c["clock status"], vim.empty_dict()))
    eq({ "clock", "status", "--" }, mcp.argv(c["clock status"], nil))
    -- an option that starts with "-" stays an argument
    eq({ "set", "tags", "--", "Task", "-x" }, mcp.argv(c["set tags"], { target = "Task", tags = "-x" }))
  end)

  it("refuses bad arguments with a message the agent can act on", function()
    local c = schema.BY_COMMAND
    local function msg(cmd, args)
      local okc, e = pcall(mcp.argv, cmd, args)
      eq(false, okc)
      return e.msg
    end
    eq("missing argument state", msg(c["set todo"], { target = "x" }))
    ok(msg(c["set todo"], { target = "x", state = "DONE", force = true }):match("takes no argument force"))
    eq("archived must be true or false", msg(c.headlines, { archived = "yes" }))
    eq("arg needs view too", msg(c.agenda, { arg = "NEXT" }))
    ok(msg(c.capture, { text = "-" }):match("standard input"))
    eq("target takes one string", msg(c.show, { target = { "a", "b" } }))
    eq("arguments must be an object", msg(c.show, { "a" }))
  end)
end)

describe("cli mcp: JSON-RPC", function()
  local server = { global_argv = { "--json" }, read_only = false }

  local function reply(line)
    local r = mcp.handle_line(server, line)
    return r and vim.json.decode(r)
  end

  it("answers initialize with the client's protocol version, or the newest", function()
    local r = reply(vim.json.encode(INIT))
    eq("2025-06-18", r.result.protocolVersion)
    eq("org.nvim", r.result.serverInfo.name)
    eq(false, r.result.capabilities.tools.listChanged)
    ok(r.result.instructions:match("Targets"))
    ok(r.result.instructions:match("Today is %d%d%d%d%-%d%d%-%d%d"))
    eq(false, r.result.capabilities.prompts.listChanged)
    local old = vim.deepcopy(INIT)
    old.params.protocolVersion = "2024-11-05"
    eq("2024-11-05", reply(vim.json.encode(old)).result.protocolVersion)
    old.params.protocolVersion = "1999-01-01"
    eq(mcp.PROTOCOLS[1], reply(vim.json.encode(old)).result.protocolVersion)
  end)

  it("gives notifications and responses no answer", function()
    eq(nil, mcp.handle_line(server, vim.json.encode(INITIALIZED)))
    eq(nil, mcp.handle_line(server, '{"jsonrpc":"2.0","method":"notifications/whatever"}'))
    eq(nil, mcp.handle_line(server, '{"jsonrpc":"2.0","id":5,"result":{}}'))
  end)

  it("answers ping with an empty object", function()
    local r = mcp.handle_line(server, '{"jsonrpc":"2.0","id":"p","method":"ping"}')
    ok(r:match('"result":{}'), r)
    eq({ jsonrpc = "2.0", id = "p", result = vim.empty_dict() }, vim.json.decode(r))
  end)

  it("reports protocol errors with JSON-RPC error codes", function()
    eq(-32700, reply("not json").error.code)
    eq(vim.NIL, reply("not json").id)
    eq(-32601, reply('{"jsonrpc":"2.0","id":2,"method":"nope"}').error.code)
    eq(-32600, reply('{"jsonrpc":"2.0","id":3}').error.code)
    eq(-32600, reply("[]").error.code)
    local unknown = reply(vim.json.encode(call(4, "rm_rf")))
    eq(-32602, unknown.error.code)
    eq(4, unknown.id)
  end)

  it("answers a batch with a list", function()
    local r = mcp.handle_line(
      server,
      '[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]'
    )
    eq({ { jsonrpc = "2.0", id = 1, result = vim.empty_dict() } }, vim.json.decode(r))
  end)

  it("gives a bad argument as a tool error, without running anything", function()
    local r = reply(vim.json.encode(call(5, "set_todo", { target = "x" })))
    eq(true, r.result.isError)
    eq("missing argument state", r.result.content[1].text)
  end)

  it("refuses a tool that writes when read-only", function()
    local r = mcp.handle_line({ global_argv = { "--json" }, read_only = true }, vim.json.encode(call(6, "capture")))
    r = vim.json.decode(r)
    eq(true, r.result.isError)
    ok(r.result.content[1].text:match("read%-only"))
  end)

  it("is not something the session server runs", function()
    eq(nil, require("org.extensions.cli.run").SESSION_COMMANDS.mcp)
  end)
end)

describe("cli mcp: results", function()
  it("leaves out nulls, empty lists and false flags, and names each heading's target", function()
    local home = vim.fs.normalize(vim.uv.os_homedir())
    local hl = {
      file = home .. "/org/a.org",
      line = 3,
      end_line = 5,
      level = 1,
      id = vim.NIL,
      todo = "TODO",
      title = "Task",
      raw_title = "Task",
      tags = { "x" },
      local_tags = { "x" },
      outline_path = {},
      archived = false,
      scheduled = {
        raw = "<2026-10-02 Fri 10:00 +1w>",
        date = "2026-10-02",
        time = "10:00",
        end_time = vim.NIL,
        start = "2026-10-02T10:00",
        ["end"] = vim.NIL,
        active = true,
        repeater = "+1w",
        warning = vim.NIL,
      },
    }
    eq({
      file = "~/org/a.org",
      line = 3,
      end_line = 5,
      level = 1,
      todo = "TODO",
      title = "Task",
      tags = { "x" },
      scheduled = { raw = "<2026-10-02 Fri 10:00 +1w>", start = "2026-10-02T10:00" },
      target = "~/org/a.org:3",
    }, mcp.compact(hl))
    hl.id = "abc"
    hl.local_tags = {}
    local c = mcp.compact(hl)
    eq("id:abc", c.target)
    eq(nil, c.local_tags)
    -- the result's own list stays, even empty
    eq({}, mcp.compact({}))
    eq({ items = {}, view = "todo" }, mcp.compact({ items = {}, view = "todo", start = vim.NIL }))
  end)

  it("gives the data on success, the error on failure, and says when a list was cut", function()
    local r = mcp.result({ ok = true, data = { 1, 2, 3 }, warnings = {}, errors = {} }, 2)
    eq(false, r.isError)
    eq({ 1, 2 }, vim.json.decode(r.content[1].text))
    ok(r.content[2].text:match("first 2 results"))
    r = mcp.result({ ok = true, data = { 1, 2 }, warnings = { "careful" }, errors = {} }, 2)
    eq(2, #r.content)
    eq("Warnings: careful", r.content[2].text)
    r = mcp.result({
      ok = false,
      data = vim.NIL,
      warnings = {},
      errors = { { code = "no_clock", message = "no running clock", details = vim.NIL } },
    })
    eq(true, r.isError)
    eq({ error = "no_clock", message = "no running clock" }, vim.json.decode(r.content[1].text))
  end)

  it("describes the tools for an agent, without the command line's flags", function()
    for _, t in ipairs(mcp.tools(false)) do
      ok(not t.description:match("%(org "), t.name)
      for k, p in pairs(t.inputSchema.properties) do
        ok(not p.description:match("^%-%-"), t.name .. "." .. k)
        ok(not p.description:match("stdin"), t.name .. "." .. k)
      end
    end
  end)
end)

describe("cli mcp: prompts", function()
  local server = { global_argv = { "--json" }, read_only = false }
  local function reply(msg)
    return vim.json.decode(mcp.handle_line(server, vim.json.encode(msg)))
  end

  it("lists the prompts and fills one in", function()
    local list = reply({ jsonrpc = "2.0", id = 1, method = "prompts/list" }).result.prompts
    eq(
      { "plan_day", "weekly_review", "triage_inbox" },
      vim.tbl_map(function(p)
        return p.name
      end, list)
    )
    local got = reply({
      jsonrpc = "2.0",
      id = 2,
      method = "prompts/get",
      params = { name = "triage_inbox", arguments = { file = "~/org/inbox.org" } },
    }).result
    eq("user", got.messages[1].role)
    ok(got.messages[1].content.text:match("inbox %(~/org/inbox%.org%)"), got.messages[1].content.text)
    local plain = reply({ jsonrpc = "2.0", id = 3, method = "prompts/get", params = { name = "triage_inbox" } })
    ok(plain.result.messages[1].content.text:match("^Help me empty my Org inbox%."))
    eq(-32602, reply({ jsonrpc = "2.0", id = 4, method = "prompts/get", params = { name = "nope" } }).error.code)
  end)
end)

describe("cli mcp: org mcp", function()
  it("runs the handshake and read and write tools on the files", function()
    local dir = workspace()
    local by_id, list, res = serve(dir, {
      INIT,
      INITIALIZED,
      { jsonrpc = "2.0", id = 2, method = "tools/list" },
      call(3, "headlines", { todo = { "open" } }),
      call(4, "capture", { template = "t", text = "Call the dentist" }),
      call(5, "set_todo", { target = "Buy milk", state = "DONE" }),
      call(6, "show", { target = "Nothing like this" }),
      call(7, "show", { target = "Garden" }),
      "",
      { jsonrpc = "2.0", id = 8, method = "ping" },
    })
    eq(0, res.code)
    -- one answer per request, nothing else on stdout
    eq(8, #list)
    eq("2025-06-18", by_id[1].result.protocolVersion)
    ok(vim.tbl_contains(names(by_id[2].result.tools), "set_todo"))

    local hl = result(by_id[3])
    eq(
      { "Buy milk", "Garden", "Garden" },
      vim.tbl_map(function(h)
        return h.title
      end, hl)
    )
    eq(false, by_id[3].result.isError)
    -- each heading names its target; nulls and empty lists are left out
    eq(dir .. "/home.org:1", vim.fs.normalize(vim.fn.expand(hl[1].target)))
    eq(nil, hl[1].id)
    eq(nil, hl[2].tags)

    eq(false, by_id[4].result.isError)
    eq({ "* TODO Call the dentist" }, vim.fn.readfile(dir .. "/inbox.org"))

    eq(false, by_id[5].result.isError)
    eq("DONE", result(by_id[5]).new)
    ok(vim.fn.readfile(dir .. "/home.org")[1]:match("^%* DONE Buy milk"))

    local missing = result(by_id[6])
    eq(true, by_id[6].result.isError)
    eq("not_found", missing.error)
    ok(missing.message:match("no heading matches"))

    local amb = result(by_id[7])
    eq("ambiguous", amb.error)
    eq(2, #amb.details.candidates)
    ok(amb.details.candidates[1].target:match(":3$"))

    eq(vim.empty_dict(), by_id[8].result)
  end)

  it("leaves the files alone with --read-only", function()
    local dir = workspace()
    local before = vim.fn.readfile(dir .. "/home.org")
    local by_id, _, res = serve(dir, {
      INIT,
      { jsonrpc = "2.0", id = 2, method = "tools/list" },
      call(3, "set_todo", { target = "Buy milk", state = "DONE" }),
      call(4, "agenda", { view = "todo" }),
    }, { "--read-only" })
    eq(0, res.code)
    eq(nil, vim.tbl_contains(names(by_id[2].result.tools), "set_todo") or nil)
    eq(true, by_id[3].result.isError)
    eq(before, vim.fn.readfile(dir .. "/home.org"))
    local ag = result(by_id[4])
    eq(false, by_id[4].result.isError)
    eq(3, #ag.items)
  end)

  it("takes read_only from the configuration", function()
    local dir = workspace()
    local cfg = vim.fn.readfile(dir .. "/cfg.lua")
    table.insert(cfg, #cfg, "  extensions = { cli = { mcp = { read_only = true } } },")
    vim.fn.writefile(cfg, dir .. "/cfg.lua")
    local by_id = serve(dir, { INIT, { jsonrpc = "2.0", id = 2, method = "tools/list" } })
    eq(false, vim.tbl_contains(names(by_id[2].result.tools), "capture"))
  end)

  it("refuses --json", function()
    local dir = workspace()
    local res = vim
      .system(
        { require("org.extensions.cli").bin(), "--config", dir .. "/cfg.lua", "--json", "mcp" },
        { text = true, stdin = "", env = env(dir), cwd = dir }
      )
      :wait(20000)
    eq(2, res.code)
    eq("usage", vim.json.decode(res.stdout).errors[1].code)
  end)
end)
