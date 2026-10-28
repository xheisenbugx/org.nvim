-- `org lsp`: the lsp extension's language server over stdio (LSP's
-- Content-Length framed JSON-RPC), run as a real process.
local lsp = require("org.extensions.cli.lsp")

--- A temp directory with notes.org, other.org, a config file and XDG dirs.
local function workspace()
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({
    "* Other",
    "See [[id:garden-id][the garden]].",
  }, dir .. "/other.org")
  vim.fn.writefile({
    "local dir = " .. vim.inspect(dir),
    "return {",
    "  org_directory = dir,",
    "  agenda_files = { dir .. '/*.org' },",
    "  default_notes_file = dir .. '/inbox.org',",
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

--- A running `org lsp --stdio`: `send(msg)` (a table, or a string sent
--- as it is), `wait_for(pred)` for a message, `close()` (stdin) and
--- `finish()` for the result of the process.
local function start(dir, args)
  local cmd = { require("org.extensions.cli").bin(), "--config", dir .. "/cfg.lua", "lsp" }
  vim.list_extend(cmd, args or { "--stdio" })
  local read = lsp.reader()
  local msgs, stderr = {}, {}
  local job = vim.system(cmd, {
    stdin = true,
    env = env(dir),
    cwd = dir,
    stdout = function(_, data)
      if data then
        for _, body in ipairs(read(data)) do
          msgs[#msgs + 1] = body and vim.json.decode(body) or { bad_frame = true }
        end
      end
    end,
    stderr = function(_, data)
      stderr[#stderr + 1] = data
    end,
  })
  local c = { msgs = msgs }
  function c.send(m)
    job:write(type(m) == "string" and m or lsp.frame(m))
  end
  function c.wait_for(pred, what)
    local found
    vim.wait(30000, function()
      for _, m in ipairs(msgs) do
        if pred(m) then
          found = m
          return true
        end
      end
      return false
    end, 20)
    ok(found, "no " .. (what or "message") .. "; got " .. vim.inspect(msgs) .. "\nstderr: " .. table.concat(stderr))
    return found
  end
  function c.reply(id)
    return c.wait_for(function(m)
      return m.id == id and (m.result ~= nil or m.error ~= nil)
    end, "reply " .. tostring(id))
  end
  function c.request(id, method, params)
    c.send({ jsonrpc = "2.0", id = id, method = method, params = params or vim.empty_dict() })
    return c.reply(id)
  end
  function c.notify(method, params)
    c.send({ jsonrpc = "2.0", method = method, params = params or vim.empty_dict() })
  end
  function c.close()
    job:write(nil)
  end
  function c.finish()
    local res = job:wait(30000)
    res.stderr = table.concat(stderr)
    return res
  end
  return c
end

local function initialize(c, dir, encodings)
  local caps = { workspace = { workspaceFolders = true } }
  if encodings then
    caps.general = { positionEncodings = encodings }
  end
  return c.request(1, "initialize", {
    processId = vim.NIL,
    rootUri = vim.uri_from_fname(dir),
    capabilities = caps,
  })
end

local NOTES = {
  "* TODO Buy milk :errand:",
  "SCHEDULED: <2026-10-30 Fri>",
  "* Garden",
  ":PROPERTIES:",
  ":ID: garden-id",
  ":END:",
  "** Tomatoes",
  "#+begin_src",
}

local function open(c, uri, lines)
  c.notify("textDocument/didOpen", {
    textDocument = { uri = uri, languageId = "org", version = 1, text = table.concat(lines, "\n") .. "\n" },
  })
end

describe("org lsp --stdio", function()
  it("frames messages and finds their bodies across reads", function()
    local read = lsp.reader()
    local f = lsp.frame({ a = 1 })
    eq({}, read(f:sub(1, 10)))
    eq({ '{"a":1}' }, read(f:sub(11) .. f:sub(1, 5)))
    eq({ '{"a":1}' }, read(f:sub(6)))
    -- a header with no length is reported, the next message still read
    eq({ false, '{"a":1}' }, read("X-Foo: 1\r\n\r\n" .. f))
  end)

  it("picks UTF-8 when the client takes it, else UTF-16", function()
    eq("utf-8", lsp.encoding({ general = { positionEncodings = { "utf-16", "utf-8" } } }))
    eq("utf-16", lsp.encoding({ general = { positionEncodings = { "utf-16" } } }))
    eq("utf-16", lsp.encoding({}))
    eq("utf-16", lsp.encoding(nil))
  end)

  it("converts positions between bytes and UTF-16, per document", function()
    local lines = { ["file:///a"] = { "héllo wörld" } }
    local function line_of(uri, n)
      return (lines[uri] or {})[n + 1] or ""
    end
    local v =
      { uri = "file:///a", range = { start = { line = 0, character = 7 }, ["end"] = { line = 0, character = 13 } } }
    lsp.convert(v, nil, "utf-16", false, line_of)
    eq({ line = 0, character = 6 }, v.range.start)
    eq({ line = 0, character = 11 }, v.range["end"])
    lsp.convert(v, nil, "utf-16", true, line_of)
    eq(7, v.range.start.character)
    eq(13, v.range["end"].character)
    -- WorkspaceEdit changes are keyed by URI
    local edit = { changes = { ["file:///a"] = { { range = { start = { line = 0, character = 13 } } } } } }
    lsp.convert(edit, nil, "utf-16", false, line_of)
    eq(11, edit.changes["file:///a"][1].range.start.character)
  end)

  it("answers initialize, symbols, hover, rename and diagnostics, then exits 0", function()
    local dir = workspace()
    local c = start(dir)
    local init = initialize(c, dir, { "utf-8" })
    ok(init.result, vim.inspect(init))
    local caps = init.result.capabilities
    eq("utf-8", caps.positionEncoding)
    eq(1, caps.textDocumentSync.change)
    eq(true, caps.documentSymbolProvider)
    eq(nil, caps.codeLensProvider)
    eq(nil, caps.executeCommandProvider)
    eq("org.nvim", init.result.serverInfo.name)
    c.notify("initialized")

    local uri = vim.uri_from_fname(dir .. "/notes.org")
    open(c, uri, NOTES)

    local r2 = c.request(2, "textDocument/documentSymbol", { textDocument = { uri = uri } })
    local syms = r2.result
    ok(syms, vim.inspect(r2))
    eq("Buy milk", syms[1].name)
    eq("Garden", syms[2].name)
    eq("Tomatoes", syms[2].children[1].name)

    local hover = c.request(3, "textDocument/hover", {
      textDocument = { uri = uri },
      position = { line = 1, character = 14 },
    }).result
    ok(hover and hover.contents.value:match("2026"), vim.inspect(hover))

    -- the unclosed block is an org-lint report
    local diags = c.wait_for(function(m)
      return m.method == "textDocument/publishDiagnostics" and m.params.uri == uri and #m.params.diagnostics > 0
    end, "diagnostics").params.diagnostics
    ok(vim.iter(diags):any(function(d)
      return d.source == "org-lint"
    end))

    -- the ID, with the link in the other (unopened) file
    local edit = c.request(4, "textDocument/rename", {
      textDocument = { uri = uri },
      position = { line = 4, character = 7 },
      newName = "veggies",
    }).result
    ok(edit and edit.changes, vim.inspect(edit))
    local other
    for u, edits in pairs(edit.changes) do
      if u:match("other%.org$") then
        other = edits
      end
    end
    ok(other and other[1].newText:match("veggies"), vim.inspect(edit))
    -- nothing written: the client applies the edit
    eq("See [[id:garden-id][the garden]].", vim.fn.readfile(dir .. "/other.org")[2])

    -- a change replaces the whole text
    c.notify("textDocument/didChange", {
      textDocument = { uri = uri, version = 2 },
      contentChanges = { { text = "* Only one\n" } },
    })
    syms = c.request(5, "textDocument/documentSymbol", { textDocument = { uri = uri } }).result
    eq(1, #syms)
    eq("Only one", syms[1].name)

    eq(vim.NIL, c.request(6, "shutdown").result)
    c.notify("exit")
    local res = c.finish()
    eq(0, res.code, res.stderr)
  end)

  it("speaks UTF-16 to a client that doesn't take UTF-8", function()
    local dir = workspace()
    local c = start(dir)
    eq("utf-16", initialize(c, dir).result.capabilities.positionEncoding)
    local uri = vim.uri_from_fname(dir .. "/notes.org")
    open(c, uri, { "* Café crème", "* Next" })
    local syms = c.request(2, "textDocument/documentSymbol", { textDocument = { uri = uri } }).result
    -- "* Café crème" is 14 bytes, 12 UTF-16 units
    eq(12, syms[1].selectionRange["end"].character)
    c.request(3, "shutdown")
    c.notify("exit")
    eq(0, c.finish().code)
  end)

  it("gives JSON-RPC errors for bad messages and goes on", function()
    local dir = workspace()
    local c = start(dir)
    -- before initialize
    eq(-32002, c.request(7, "textDocument/hover", { textDocument = { uri = "file:///x" } }).error.code)
    initialize(c, dir, { "utf-8" })
    eq(-32601, c.request(2, "org/noSuchMethod").error.code)
    -- code lenses run org actions in the server's buffer: not over stdio
    eq(-32601, c.request(3, "workspace/executeCommand", { command = "org.lsp.action" }).error.code)
    -- invalid JSON, then a header with no length
    c.send("Content-Length: 5\r\n\r\n{nope")
    c.send("X-Nothing: 1\r\n\r\n")
    local errs = {}
    vim.wait(10000, function()
      errs = vim.tbl_filter(function(m)
        return m.error and m.id == vim.NIL
      end, c.msgs)
      return #errs >= 2
    end, 20)
    eq(-32700, errs[1].error.code)
    eq(-32700, errs[2].error.code)
    -- still serving
    eq(vim.NIL, c.request(4, "shutdown").result)
    -- a request after shutdown
    eq(-32600, c.request(5, "textDocument/hover", { textDocument = { uri = "file:///x" } }).error.code)
    c.notify("exit")
    eq(0, c.finish().code)
  end)

  it("exits when stdin closes: 1 without shutdown, after answering", function()
    local dir = workspace()
    local c = start(dir)
    initialize(c, dir, { "utf-8" })
    local uri = vim.uri_from_fname(dir .. "/notes.org")
    open(c, uri, NOTES)
    c.send({
      jsonrpc = "2.0",
      id = 2,
      method = "textDocument/documentSymbol",
      params = { textDocument = { uri = uri } },
    })
    c.close()
    local res = c.finish()
    eq(1, res.code, res.stderr)
    ok(c.reply(2).result)
  end)

  it("exits 0 when stdin closes after shutdown", function()
    local dir = workspace()
    local c = start(dir)
    initialize(c, dir, { "utf-8" })
    c.request(2, "shutdown")
    c.close()
    eq(0, c.finish().code)
  end)

  it("refuses --json and is no MCP tool", function()
    local dir = workspace()
    local cmd = { require("org.extensions.cli").bin(), "--config", dir .. "/cfg.lua", "--json", "lsp" }
    local res = vim.system(cmd, { text = true, stdin = false, env = env(dir), cwd = dir }):wait(30000)
    eq(2, res.code)
    ok(res.stdout:match("takes no %-%-json"), res.stdout)
    local mcp = require("org.extensions.cli.mcp")
    for _, t in ipairs(mcp.tools(false)) do
      ok(t.name ~= "lsp")
    end
  end)
end)
