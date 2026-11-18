---@mod org.extensions.src_lsp.proxy Forwarding LSP requests into src blocks
---
--- An in-process language server (`vim.lsp.start({ cmd = proxy.cmd })`)
--- attached to the org buffers with configured blocks. A request at a
--- position inside a block body (definition, declaration, type definition,
--- implementation, references, hover, signature help, completion) is sent
--- to the language servers of that block's hidden buffer, with the URI and
--- position translated; locations in the hidden buffer come back as
--- locations in the org buffer. Anywhere else it answers nothing, so
--- `gd`, `K`, `grr`, `vim.lsp.completion` and completion plugins' LSP
--- sources work inside blocks without any setup.

local M = {}

local mirror = require("org.extensions.src_lsp.mirror")

M.NAME = "org_src"
--- Positions between Neovim and this server.
M.ENCODING = "utf-16"

local ERR = { method_not_found = -32601 }

--- Methods forwarded into the blocks.
M.forwarded = {
  ["textDocument/definition"] = "locations",
  ["textDocument/declaration"] = "locations",
  ["textDocument/typeDefinition"] = "locations",
  ["textDocument/implementation"] = "locations",
  ["textDocument/references"] = "locations",
  ["textDocument/hover"] = "first",
  ["textDocument/signatureHelp"] = "first",
  ["textDocument/completion"] = "completion",
}

local function opts()
  return require("org.extensions").opts("src_lsp") or require("org.extensions.src_lsp").defaults
end

--- Server capabilities.
---@return table
function M.capabilities()
  local caps = {
    positionEncoding = M.ENCODING,
    textDocumentSync = { openClose = false, change = 0 },
    definitionProvider = true,
    declarationProvider = true,
    typeDefinitionProvider = true,
    implementationProvider = true,
    referencesProvider = true,
    hoverProvider = true,
    signatureHelpProvider = { triggerCharacters = { "(", "," } },
  }
  if opts().completion ~= false then
    caps.completionProvider = {
      triggerCharacters = { ".", ":", "(", '"', "'", "/", "@", ">" },
      resolveProvider = true,
    }
  end
  return caps
end

---------------------------------------------------------------------------
-- Mapping results back
---------------------------------------------------------------------------

--- Text of line `lnum` (0-based) of a file outside the org buffers, for
--- encoding conversions of locations the servers return.
---@param cache table<string, string[]|false>
---@param uri string
---@param lnum integer
---@return string|nil
local function external_line(cache, uri, lnum)
  if cache[uri] == nil then
    ---@type string[]|false
    local lines = false
    if uri:match("^file:") then
      local fname = vim.uri_to_fname(uri)
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == fname then
          lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
          break
        end
      end
      if not lines and vim.uv.fs_stat(fname) then
        local ok, res = pcall(vim.fn.readfile, fname)
        lines = ok and res or false
      end
    end
    cache[uri] = lines
  end
  local lines = cache[uri]
  return lines and lines[lnum + 1] or nil
end

---@class org.src_lsp.Ctx
---@field org integer
---@field org_uri string
---@field g org.src_lsp.Group
---@field enc string the server's position encoding
---@field cache table<string, string[]|false>

--- A range (`ctx.enc`) in document `uri` as a range for Neovim
--- (`M.ENCODING`); the hidden buffer's ranges move to the org buffer.
---@param ctx org.src_lsp.Ctx
---@param uri string
---@param range table|nil
---@return table|nil
local function map_range(ctx, uri, range)
  if type(range) ~= "table" or not range.start then
    return range
  end
  if uri == ctx.g.uri then
    return {
      start = mirror.to_org(ctx.org, ctx.g, range.start, ctx.enc, M.ENCODING),
      ["end"] = mirror.to_org(ctx.org, ctx.g, range["end"], ctx.enc, M.ENCODING),
    }
  end
  if ctx.enc == M.ENCODING then
    return range
  end
  local function conv(pos)
    local line = external_line(ctx.cache, uri, pos.line)
    if not line then
      return pos
    end
    local okb, byte = pcall(vim.str_byteindex, line, ctx.enc, pos.character, false)
    if not okb then
      return pos
    end
    local okc, char = pcall(vim.str_utfindex, line, M.ENCODING, byte, false)
    return { line = pos.line, character = okc and char or pos.character }
  end
  return { start = conv(range.start), ["end"] = conv(range["end"]) }
end

---@param ctx org.src_lsp.Ctx
---@param uri string
---@return string
local function map_uri(ctx, uri)
  return uri == ctx.g.uri and ctx.org_uri or uri
end

--- Location / Location[] / LocationLink[] as a list for the org buffer.
---@param ctx org.src_lsp.Ctx
---@param res any
---@return table[]
local function map_locations(ctx, res)
  if type(res) ~= "table" then
    return {}
  end
  local list = (res.uri or res.targetUri) and { res } or res
  local out = {}
  for _, loc in ipairs(list) do
    if type(loc) == "table" then
      if loc.targetUri then
        out[#out + 1] = {
          targetUri = map_uri(ctx, loc.targetUri),
          targetRange = map_range(ctx, loc.targetUri, loc.targetRange),
          targetSelectionRange = map_range(ctx, loc.targetUri, loc.targetSelectionRange),
          originSelectionRange = map_range(ctx, ctx.g.uri, loc.originSelectionRange),
        }
      elseif loc.uri then
        out[#out + 1] = { uri = map_uri(ctx, loc.uri), range = map_range(ctx, loc.uri, loc.range) }
      end
    end
  end
  return out
end

--- A TextEdit or InsertReplaceEdit in the hidden buffer, for the org buffer.
---@param ctx org.src_lsp.Ctx
---@param edit table|nil
---@return table|nil
local function map_edit(ctx, edit)
  if type(edit) ~= "table" then
    return edit
  end
  local e = vim.deepcopy(edit)
  if e.range then
    e.range = map_range(ctx, ctx.g.uri, e.range)
  end
  if e.insert then
    e.insert = map_range(ctx, ctx.g.uri, e.insert)
  end
  if e.replace then
    e.replace = map_range(ctx, ctx.g.uri, e.replace)
  end
  return e
end

--- A completion item of client `client_id` for the org buffer; its `data`
--- remembers the client, for completionItem/resolve.
---@param ctx org.src_lsp.Ctx
---@param item table
---@param client_id integer
---@param defaults? table CompletionList.itemDefaults
---@return table
local function map_item(ctx, item, client_id, defaults)
  item = vim.deepcopy(item)
  if defaults then
    if not item.textEdit and defaults.editRange then
      local text = item.textEditText or item.insertText or item.label
      local r = defaults.editRange
      item.textEdit = r.insert and { newText = text, insert = r.insert, replace = r.replace }
        or { newText = text, range = r }
    end
    for _, k in ipairs({ "commitCharacters", "insertTextFormat", "insertTextMode" }) do
      if item[k] == nil then
        item[k] = defaults[k]
      end
    end
    if item.data == nil then
      item.data = defaults.data
    end
  end
  item.textEdit = map_edit(ctx, item.textEdit)
  if item.additionalTextEdits then
    local edits = {}
    for i, e in ipairs(item.additionalTextEdits) do
      edits[i] = map_edit(ctx, e)
    end
    item.additionalTextEdits = edits
  end
  item.data = { org_src = { client = client_id, org = ctx.org, ft = ctx.g.ft, data = item.data } }
  return item
end

---@param ctx org.src_lsp.Ctx
---@param res any
---@param client_id integer
---@return table[] items, boolean incomplete
local function map_completion(ctx, res, client_id)
  if type(res) ~= "table" then
    return {}, false
  end
  local items = res.items or res
  local out = {}
  for _, it in ipairs(items) do
    out[#out + 1] = map_item(ctx, it, client_id, res.itemDefaults)
  end
  return out, res.isIncomplete == true
end

---------------------------------------------------------------------------
-- Forwarding
---------------------------------------------------------------------------

---@param method string
---@param params table
---@param callback fun(err: table|nil, result: any)
function M.forward(method, params, callback)
  local uri = params.textDocument and params.textDocument.uri
  local pos = params.position
  if type(uri) ~= "string" or type(pos) ~= "table" then
    return callback(nil, nil)
  end
  local org = vim.uri_to_bufnr(uri)
  mirror.flush(org)
  local g = mirror.group_at(org, pos.line + 1)
  if not g then
    return callback(nil, nil)
  end
  local clients = vim.tbl_filter(function(c)
    return c.name ~= M.NAME
  end, mirror.clients(g.hidden, method))
  if #clients == 0 then
    return callback(nil, nil)
  end
  local kind = M.forwarded[method]
  local results = {}
  local pending = #clients
  local function done()
    pending = pending - 1
    if pending > 0 then
      return
    end
    local first_err
    if kind == "locations" then
      local out = {}
      for _, r in ipairs(results) do
        first_err = first_err or r.err
        vim.list_extend(out, map_locations(r.ctx, r.res))
      end
      return callback(#out == 0 and first_err or nil, out)
    elseif kind == "completion" then
      local items, incomplete = {}, false
      for _, r in ipairs(results) do
        first_err = first_err or r.err
        local its, inc = map_completion(r.ctx, r.res, r.client)
        vim.list_extend(items, its)
        incomplete = incomplete or inc
      end
      return callback(#items == 0 and first_err or nil, { isIncomplete = incomplete, items = items })
    end
    for _, r in ipairs(results) do
      first_err = first_err or r.err
      if type(r.res) == "table" then
        local res = vim.deepcopy(r.res)
        if res.range then
          res.range = map_range(r.ctx, g.uri, res.range)
        end
        return callback(nil, res)
      end
    end
    return callback(first_err, nil)
  end
  for _, c in ipairs(clients) do
    local enc = c.offset_encoding or "utf-16"
    ---@type org.src_lsp.Ctx
    local ctx = { org = org, org_uri = uri, g = g, enc = enc, cache = {} }
    local p = vim.deepcopy(params)
    p.textDocument = { uri = g.uri }
    p.position = mirror.to_hidden(org, g, pos, M.ENCODING, enc)
    local ok = c:request(method, p, function(err, res)
      results[#results + 1] = { err = err, res = res, ctx = ctx, client = c.id }
      done()
    end, g.hidden)
    if not ok then
      done()
    end
  end
end

--- completionItem/resolve: ask the client that gave the item.
---@param item table
---@param callback fun(err: table|nil, result: any)
function M.resolve(item, callback)
  local tag = type(item) == "table" and type(item.data) == "table" and item.data.org_src
  if not tag then
    return callback(nil, item)
  end
  local c = vim.lsp.get_client_by_id(tag.client)
  local st = mirror.states[tag.org]
  local g = st and st.groups[tag.ft]
  if not c or not g or not c:supports_method("completionItem/resolve") then
    return callback(nil, item)
  end
  local orig = vim.deepcopy(item)
  orig.data = tag.data
  -- the server knows its own ranges, not ours: drop the mapped edits
  orig.textEdit = nil
  orig.additionalTextEdits = nil
  ---@type org.src_lsp.Ctx
  local ctx = { org = tag.org, org_uri = vim.uri_from_bufnr(tag.org), g = g, enc = c.offset_encoding, cache = {} }
  local ok = c:request("completionItem/resolve", orig, function(err, res)
    if err or type(res) ~= "table" then
      return callback(nil, item)
    end
    local out = map_item(ctx, res, c.id)
    -- keep the edit the item was shown with when the server sends none
    out.textEdit = out.textEdit or item.textEdit
    callback(nil, out)
  end, g.hidden)
  if not ok then
    callback(nil, item)
  end
end

---------------------------------------------------------------------------
-- The server
---------------------------------------------------------------------------

--- Create a server for `vim.lsp.start`'s `cmd`.
---@param dispatchers table vim.lsp.rpc.Dispatchers
---@return table vim.lsp.rpc.PublicClient
function M.cmd(dispatchers)
  local srv = { closing = false, next_id = 0, shutdown = false }
  local function exit(code)
    if srv.closing then
      return
    end
    srv.closing = true
    vim.schedule(function()
      -- lint: allow pcall: Neovim's LSP client, which may be gone at exit
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
    local replied = false
    local function reply(err, result)
      if replied then
        return
      end
      replied = true
      if result == nil and not err then
        result = vim.NIL
      end
      local utils = require("org.utils")
      utils.try("src_lsp: reply handler", callback, err, err == nil and result or nil)
      if notify_reply_callback then
        utils.try("src_lsp: reply handler", notify_reply_callback, id)
      end
    end
    if method == "initialize" then
      -- answered at once: the client is initialized before vim.lsp.start
      -- returns, so the org buffer gets its didOpen right away. On 0.11.0,
      -- wiping a buffer whose client has not sent didOpen yet fails in
      -- vim.lsp's change tracking.
      reply(nil, { capabilities = M.capabilities(), serverInfo = { name = "org.nvim src blocks" } })
      return true, id
    end
    vim.schedule(function()
      local ok, err = pcall(function()
        if method == "initialize" then
          reply(nil, { capabilities = M.capabilities(), serverInfo = { name = "org.nvim src blocks" } })
        elseif method == "shutdown" then
          srv.shutdown = true
          reply(nil, vim.NIL)
        elseif method == "completionItem/resolve" then
          M.resolve(params, reply)
        elseif M.forwarded[method] then
          M.forward(method, params or {}, reply)
        else
          reply({ code = ERR.method_not_found, message = "Method not found: " .. tostring(method) })
        end
      end)
      if not ok then
        reply({ code = -32603, message = tostring(err) })
      end
    end)
    return true, id
  end

  function rpc.notify(method)
    if method == "exit" then
      exit(srv.shutdown and 0 or 1)
    end
    return not srv.closing
  end

  function rpc.is_closing()
    return srv.closing
  end

  function rpc.terminate()
    exit(0)
  end

  return rpc
end

--- The running proxy clients.
---@return vim.lsp.Client[]
function M.clients()
  return vim.lsp.get_clients({ name = M.NAME })
end

--- Attach the proxy to an org buffer (starting it if needed).
---@param bufnr integer
---@return integer|nil client id
function M.attach(bufnr)
  return vim.lsp.start({
    name = M.NAME,
    cmd = M.cmd,
    root_dir = vim.fs.dirname(vim.api.nvim_buf_get_name(bufnr)),
    offset_encoding = M.ENCODING,
  }, {
    bufnr = bufnr,
    reuse_client = function(client, config)
      return client.name == config.name and not client:is_stopped()
    end,
  })
end

--- Stop the proxy clients.
function M.stop()
  for _, c in ipairs(M.clients()) do
    c:stop(true)
  end
end

return M
