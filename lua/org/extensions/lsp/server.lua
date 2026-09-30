---@mod org.extensions.lsp.server The in-process language server
---
--- `vim.lsp.start({ cmd = server.cmd })` makes Neovim talk to this module
--- instead of a process: `cmd(dispatchers)` returns the RPC client
--- (`request`, `notify`, `is_closing`, `terminate`). Requests are answered
--- on the next event-loop tick, like a real server, and read the documents
--- straight from their buffers.

local util = require("org.extensions.lsp.util")

local M = {}

local ERR = { method_not_found = -32601, invalid_params = -32602, internal = -32603, request_failed = -32803 }

--- Server capabilities for the enabled features.
function M.capabilities()
  local f = util.opts().features or {}
  local on = function(name)
    return f[name] ~= false
  end
  local caps = {
    positionEncoding = "utf-8",
    textDocumentSync = { openClose = true, change = 2, save = { includeText = false } },
    documentSymbolProvider = on("document_symbols") or nil,
    workspaceSymbolProvider = on("workspace_symbols") or nil,
    hoverProvider = on("hover") or nil,
    definitionProvider = on("definition") or nil,
    referencesProvider = on("references") or nil,
    renameProvider = on("rename") and { prepareProvider = true } or nil,
    foldingRangeProvider = on("folding") or nil,
    documentLinkProvider = on("document_links") and { resolveProvider = false } or nil,
  }
  if on("code_actions") then
    caps.codeActionProvider = { codeActionKinds = { "quickfix", "refactor", "refactor.rewrite" } }
    caps.executeCommandProvider = { commands = { require("org.extensions.lsp.code_actions").COMMAND } }
  end
  return caps
end

local function doc_or_err(params)
  local uri = params and params.textDocument and params.textDocument.uri
  local doc = uri and util.doc(uri)
  if not doc then
    error({ code = ERR.invalid_params, message = "Unknown document: " .. tostring(uri) })
  end
  return doc
end

local function locations_of(refs)
  local out = {}
  for _, r in ipairs(refs) do
    out[#out + 1] = { uri = r.doc.uri, range = util.range(r.lnum, r.s, r.e) }
  end
  return out
end

---@type table<string, fun(srv: table, params: table): any>
M.requests = {}
local R = M.requests

R["initialize"] = function(srv, params)
  srv.initialized = true
  srv.client_capabilities = params and params.capabilities
  return {
    capabilities = M.capabilities(),
    serverInfo = { name = "org.nvim", version = require("org.version").release },
  }
end

R["shutdown"] = function(srv)
  srv.shutdown = true
  return vim.NIL
end

R["textDocument/documentSymbol"] = function(_, params)
  return require("org.extensions.lsp.symbols").document(doc_or_err(params))
end

R["workspace/symbol"] = function(_, params)
  return require("org.extensions.lsp.symbols").workspace(params.query or "")
end

R["textDocument/foldingRange"] = function(_, params)
  return require("org.extensions.lsp.symbols").folding(doc_or_err(params))
end

R["textDocument/documentLink"] = function(_, params)
  return require("org.extensions.lsp.symbols").links(doc_or_err(params))
end

R["textDocument/hover"] = function(_, params)
  local doc = doc_or_err(params)
  local lnum, col = util.from_pos(params.position)
  local text, range = require("org.extensions.lsp.hover").at(doc, lnum, col)
  if not text then
    return vim.NIL
  end
  return { contents = { kind = "markdown", value = text }, range = range }
end

R["textDocument/definition"] = function(_, params)
  local doc = doc_or_err(params)
  local targets = require("org.extensions.lsp.targets")
  local lnum, col = util.from_pos(params.position)
  local line = doc.lines[lnum] or ""
  local link = targets.link_at(doc, lnum, col)
  if link then
    local loc = targets.resolve(doc, link)
    return loc and util.location(loc.path, loc.lnum, loc.s, loc.e) or vim.NIL
  end
  local fn = targets.footnote_at(line, col)
  if fn then
    local def = targets.footnote_definition(doc.lines, fn.label)
    if fn.definition then
      -- from a definition to its first reference
      for _, u in ipairs(targets.footnote_uses(doc.lines, fn.label)) do
        if not u.definition then
          return util.location(doc.path, u.lnum, u.ls, u.le)
        end
      end
      return vim.NIL
    end
    return def and util.location(doc.path, def.start, 1, 0) or vim.NIL
  end
  local radio = targets.radio_at(doc, lnum, col)
  if radio then
    return util.location(doc.path, radio.target.lnum, radio.target.s, radio.target.e)
  end
  return vim.NIL
end

R["textDocument/references"] = function(_, params)
  local doc = doc_or_err(params)
  local targets = require("org.extensions.lsp.targets")
  local lnum, col = util.from_pos(params.position)
  local subject = targets.subject_at(doc, lnum, col)
  if not subject then
    return {}
  end
  local out = locations_of(targets.references(subject))
  if params.context and params.context.includeDeclaration then
    table.insert(out, 1, targets.declaration(subject))
  end
  return out
end

R["textDocument/prepareRename"] = function(_, params)
  local doc = doc_or_err(params)
  local lnum, col = util.from_pos(params.position)
  return require("org.extensions.lsp.rename").prepare(doc, lnum, col) or vim.NIL
end

R["textDocument/rename"] = function(_, params)
  local doc = doc_or_err(params)
  local lnum, col = util.from_pos(params.position)
  local edit, err = require("org.extensions.lsp.rename").rename(doc, lnum, col, params.newName)
  if not edit then
    error({ code = ERR.request_failed, message = err })
  end
  return edit
end

R["textDocument/codeAction"] = function(_, params)
  return require("org.extensions.lsp.code_actions").actions(doc_or_err(params), params)
end

R["workspace/executeCommand"] = function(_, params)
  local ca = require("org.extensions.lsp.code_actions")
  if params.command ~= ca.COMMAND then
    error({ code = ERR.invalid_params, message = "Unknown command: " .. tostring(params.command) })
  end
  local args = params.arguments and params.arguments[1]
  -- after the reply: the action may prompt
  vim.schedule(function()
    local ok, err = pcall(ca.execute, args)
    if not ok then
      require("org.utils").error("org lsp: " .. tostring(err))
    end
  end)
  return vim.NIL
end

---@type table<string, fun(srv: table, params: table)>
M.notifications = {}
local N = M.notifications

local function buf_of(params)
  local uri = params and params.textDocument and params.textDocument.uri
  if not uri then
    return nil
  end
  local b = require("org.utils").find_buffer(vim.uri_to_fname(uri))
  return b
end

N["textDocument/didOpen"] = function(srv, params)
  local b = buf_of(params)
  srv.versions[params.textDocument.uri] = params.textDocument.version
  if b and srv.diagnostics then
    srv.diagnostics.schedule(b, 0)
  end
end

N["textDocument/didChange"] = function(srv, params)
  local b = buf_of(params)
  srv.versions[params.textDocument.uri] = params.textDocument.version
  if b and srv.diagnostics then
    srv.diagnostics.schedule(b)
  end
end

N["textDocument/didSave"] = function(srv, params)
  local b = buf_of(params)
  if b and srv.diagnostics then
    srv.diagnostics.schedule(b, 0)
  end
end

N["textDocument/didClose"] = function(srv, params)
  local b = buf_of(params)
  srv.versions[params.textDocument.uri] = nil
  if b and srv.diagnostics then
    srv.diagnostics.clear(b)
  end
end

--- Create a server for `vim.lsp.start`'s `cmd`.
---@param dispatchers table vim.lsp.rpc.Dispatchers
---@return table vim.lsp.rpc.PublicClient
function M.cmd(dispatchers)
  local srv = { closing = false, versions = {}, next_id = 0 }
  local features = util.opts().features or {}
  if features.diagnostics ~= false then
    srv.diagnostics = require("org.extensions.lsp.diagnostics").scheduler(function(uri, diags)
      if srv.closing then
        return
      end
      dispatchers.notification("textDocument/publishDiagnostics", {
        uri = uri,
        version = srv.versions[uri],
        diagnostics = diags,
      })
    end)
  end

  local function exit(code)
    if srv.closing then
      return
    end
    srv.closing = true
    if srv.diagnostics then
      srv.diagnostics.stop()
    end
    vim.schedule(function()
      pcall(dispatchers.on_exit, code or 0, 0)
    end)
  end

  local rpc = {}

  function rpc.request(method, params, callback, notify_reply_callback)
    if srv.closing then
      return false
    end
    srv.next_id = srv.next_id + 1
    local id = srv.next_id
    vim.schedule(function()
      local handler = M.requests[method]
      local err, result
      if not handler then
        err = { code = ERR.method_not_found, message = "Method not found: " .. tostring(method) }
      else
        local ok, res = pcall(handler, srv, params or {})
        if ok then
          result = res
        elseif type(res) == "table" and res.code then
          err = res
        else
          err = { code = ERR.internal, message = tostring(res) }
        end
      end
      if result == nil and not err then
        result = vim.NIL
      end
      pcall(callback, err, err == nil and result or nil)
      if notify_reply_callback then
        pcall(notify_reply_callback, id)
      end
    end)
    return true, id
  end

  function rpc.notify(method, params)
    if method == "exit" then
      exit(srv.shutdown and 0 or 1)
      return true
    end
    if srv.closing then
      return false
    end
    local handler = M.notifications[method]
    if handler then
      vim.schedule(function()
        if not srv.closing then
          local ok, err = pcall(handler, srv, params or {})
          if not ok then
            require("org.utils").error("org lsp: " .. method .. ": " .. tostring(err))
          end
        end
      end)
    end
    return true
  end

  function rpc.is_closing()
    return srv.closing
  end

  function rpc.terminate()
    exit(0)
  end

  M.last = srv
  return rpc
end

return M
