---@mod org.extensions.cli.lsp `org lsp`: the language server over stdio
---
--- The `lsp` extension's server (org.extensions.lsp.server) for editors
--- that start a language server as a program: Helix, VS Code, Zed, Emacs,
--- Kakoune. Messages are LSP's JSON-RPC with `Content-Length` headers on
--- stdin and stdout. This file is only the transport: framing, the
--- documents the client opens (each kept in a buffer of this Neovim, so
--- the server reads them as it reads unsaved buffers in Neovim) and
--- position encodings (the server counts bytes; a client that can't take
--- UTF-8 gets UTF-16 offsets). Every request is answered by the
--- extension's handlers.

local shared = require("org.extensions.cli.shared")

local run = require("org.extensions.cli.run")

local M = {}

local fail = run.fail
local state = shared.state

local ERR = {
  parse = -32700,
  invalid_request = -32600,
  method_not_found = -32601,
  internal = -32603,
  not_initialized = -32002,
}

--- Capabilities that run org actions in this Neovim (code lenses and
--- command code actions): their edits would stay in its buffers, so the
--- stdio server leaves them out.
local NO_STDIO = { codeLensProvider = true, executeCommandProvider = true }
local NO_STDIO_METHODS = {
  ["workspace/executeCommand"] = true,
  ["textDocument/codeLens"] = true,
  ["codeLens/resolve"] = true,
}

---------------------------------------------------------------------------
-- Framing
---------------------------------------------------------------------------

--- A reader of `Content-Length` framed messages: `feed(data)` returns
--- the complete bodies so far, and for a header without a length the
--- string false (the parse error to report).
---@return fun(data: string): table
function M.reader()
  local buf = ""
  ---@param data string
  ---@return table
  local function feed(data)
    buf = buf .. data
    local out = {}
    while true do
      local hs, he = buf:find("\r?\n\r?\n")
      if not hs then
        break
      end
      local header = buf:sub(1, hs - 1)
      local len = tonumber(header:match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
      if not len then
        -- no length: the body can't be found, skip the header
        out[#out + 1] = false
        buf = buf:sub(he + 1)
      elseif #buf - he < len then
        break
      else
        out[#out + 1] = buf:sub(he + 1, he + len)
        buf = buf:sub(he + len + 1)
      end
    end
    return out
  end
  return feed
end

--- A message with its header.
---@param msg table
---@return string
function M.frame(msg)
  local body = vim.json.encode(msg)
  return "Content-Length: " .. #body .. "\r\n\r\n" .. body
end

---------------------------------------------------------------------------
-- Position encodings
---------------------------------------------------------------------------

--- The encoding to use for the client's `general.positionEncodings`
--- (UTF-16 when it lists none: the protocol's default).
---@param caps table|nil client capabilities
---@return string
function M.encoding(caps)
  local list = caps and caps.general and caps.general.positionEncodings
  if type(list) == "table" then
    for _, e in ipairs({ "utf-8", "utf-16", "utf-32" }) do
      if vim.tbl_contains(list, e) then
        return e
      end
    end
  end
  return "utf-16"
end

local function is_pos(v)
  return type(v.line) == "number" and type(v.character) == "number"
end

--- Convert every position in `value` (in place) between bytes and
--- `enc`: `to_bytes` for what the client sends, else for what goes to
--- it. `line_of(uri, lnum0)` gives the text of a line; `uri` is the
--- document of positions with no `uri` of their own around them.
---@param value any
---@param uri string|nil
---@param enc string
---@param to_bytes boolean
---@param line_of fun(uri: string|nil, lnum0: integer): string
function M.convert(value, uri, enc, to_bytes, line_of)
  if enc == "utf-8" or type(value) ~= "table" then
    return
  end
  local function walk(v, u)
    if type(v) ~= "table" then
      return
    end
    if is_pos(v) then
      local line = line_of(u, v.line)
      if to_bytes then
        local ok, b = pcall(vim.str_byteindex, line, enc, v.character, false)
        v.character = ok and b or #line
      else
        local c = math.min(v.character, #line)
        local ok, i = pcall(vim.str_utfindex, line, enc, c, false)
        v.character = ok and i or c
      end
      return
    end
    if type(v.uri) == "string" then
      u = v.uri
    elseif type(v.textDocument) == "table" and type(v.textDocument.uri) == "string" then
      u = v.textDocument.uri
    end
    for k, child in pairs(v) do
      -- a WorkspaceEdit's `changes` are keyed by URI
      walk(child, type(k) == "string" and k:match("^file:") and k or u)
    end
  end
  walk(value, uri)
end

---------------------------------------------------------------------------
-- The server
---------------------------------------------------------------------------

--- A session of the stdio server: `receive(data)` takes bytes from
--- stdin, `eof()` says stdin closed, `send(str)` writes to stdout and
--- `done(code)` is called once when the server exits.
---@param send fun(s: string)
---@param done fun(code: integer)
---@return { receive: fun(data: string), eof: fun(), stop: fun() }
function M.session(send, done)
  local server = require("org.extensions.lsp.server")
  local lsp_util = require("org.extensions.lsp.util")
  local read = M.reader()
  local s = {
    initialized = false,
    shutdown = false,
    finished = false,
    pending = 0,
    eof = false,
    enc = "utf-16",
    -- canonical path -> { buf, uri (as the client wrote it) }
    docs = {},
    next_id = 0,
  }

  local function path_of(uri)
    if type(uri) ~= "string" or not uri:match("^file:") then
      return nil
    end
    return lsp_util.canon(vim.uri_to_fname(uri))
  end

  -- lines of files that aren't open, for one message
  local disk = {}
  local function line_of(uri, lnum0)
    local p = path_of(uri)
    if not p then
      return ""
    end
    local d = s.docs[p]
    if d and vim.api.nvim_buf_is_loaded(d.buf) then
      return vim.api.nvim_buf_get_lines(d.buf, lnum0, lnum0 + 1, false)[1] or ""
    end
    if disk[p] == nil then
      local ok, lines = pcall(vim.fn.readfile, p)
      disk[p] = ok and lines or {}
    end
    return disk[p][lnum0 + 1] or ""
  end

  -- the client's own spelling of the URIs of its documents (a Windows
  -- client may write file:///c%3A/...)
  local function client_uris(v)
    if type(v) ~= "table" then
      return v
    end
    for k, child in pairs(v) do
      if k == "uri" and type(child) == "string" then
        local d = s.docs[path_of(child) or ""]
        if d then
          v[k] = d.uri
        end
      else
        client_uris(child)
      end
    end
    if type(v.changes) == "table" then
      local changes = {}
      for u, edits in pairs(v.changes) do
        local d = s.docs[path_of(u) or ""]
        changes[d and d.uri or u] = edits
      end
      v.changes = changes
    end
    return v
  end

  local function write(msg)
    if s.finished then
      return
    end
    send(M.frame(msg))
  end

  local function outgoing(value, uri)
    disk = {}
    client_uris(value)
    M.convert(value, uri, s.enc, false, line_of)
    return value
  end

  local function finish(code)
    if s.finished then
      return
    end
    for _, d in pairs(s.docs) do
      pcall(vim.api.nvim_buf_delete, d.buf, { force = true })
    end
    s.docs = {}
    s.finished = true
    done(code)
  end

  local rpc = server.cmd({
    notification = function(method, params)
      local uri = type(params) == "table" and params.uri or nil
      write({ jsonrpc = "2.0", method = method, params = outgoing(params, uri) })
    end,
    -- refresh requests: their answers are not waited for
    server_request = function(method, params)
      s.next_id = s.next_id + 1
      write({ jsonrpc = "2.0", id = "org-" .. s.next_id, method = method, params = params })
      return nil, vim.NIL
    end,
    on_error = function(_, err)
      run.stderr("org lsp: " .. tostring(err) .. "\n")
    end,
    on_exit = function(code)
      finish(code)
    end,
  })

  ---------------------------------------------------------------------------
  -- Documents
  ---------------------------------------------------------------------------

  local function set_text(buf, text)
    -- a final newline ends the last line, as in a file
    local lines = vim.split((text:gsub("\r?\n$", "")), "\r?\n")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end

  local function open(td)
    local p = path_of(td.uri)
    if not p then
      return
    end
    local d = s.docs[p]
    if not d then
      local buf = lsp_util.buffer_of(p)
      if not buf then
        buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buf, p)
      end
      vim.bo[buf].swapfile = false
      vim.bo[buf].undolevels = -1
      -- the filetype without its autocmds: no ftplugin, highlighter or
      -- in-process client in a buffer no window shows
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("noautocmd setlocal filetype=org")
      end)
      d = { buf = buf }
      s.docs[p] = d
      lsp_util.reset_scope()
      lsp_util.invalidate()
    end
    d.uri = td.uri
    set_text(d.buf, td.text or "")
  end

  local function change(params)
    local d = s.docs[path_of(params.textDocument and params.textDocument.uri) or ""]
    if not d then
      return
    end
    for _, c in ipairs(params.contentChanges or {}) do
      if c.range then
        disk = {}
        M.convert(c.range, d.uri, s.enc, true, line_of)
        local r = c.range
        local lines = vim.split(c.text or "", "\r?\n")
        local last = vim.api.nvim_buf_line_count(d.buf) - 1
        local sl, el = math.min(r.start.line, last), math.min(r["end"].line, last)
        local sc = math.min(r.start.character, #line_of(d.uri, sl))
        local ec = math.min(r["end"].character, #line_of(d.uri, el))
        if r["end"].line > last then
          ec = #line_of(d.uri, last)
        end
        vim.api.nvim_buf_set_text(d.buf, sl, sc, el, ec, lines)
      else
        set_text(d.buf, c.text or "")
      end
    end
  end

  local function close(params)
    local p = path_of(params.textDocument and params.textDocument.uri)
    local d = p and s.docs[p]
    if not p or not d then
      return
    end
    s.docs[p] = nil
    -- after the server's own didClose handler (scheduled before)
    vim.schedule(function()
      if not s.docs[p] then
        pcall(vim.api.nvim_buf_delete, d.buf, { force = true })
        lsp_util.reset_scope()
        lsp_util.invalidate()
      end
    end)
  end

  -- the client's folders join the workspace (references, rename and
  -- workspace symbols look at their .org files)
  local function add_roots(params)
    local dirs = {}
    for _, f in ipairs(type(params.workspaceFolders) == "table" and params.workspaceFolders or {}) do
      dirs[#dirs + 1] = f.uri
    end
    if #dirs == 0 and type(params.rootUri) == "string" then
      dirs[1] = params.rootUri
    end
    local roots = {}
    for _, u in ipairs(dirs) do
      local p = path_of(u)
      if p and vim.fn.isdirectory(p) == 1 then
        roots[#roots + 1] = p
      end
    end
    lsp_util.roots = roots
    lsp_util.invalidate()
  end

  ---------------------------------------------------------------------------
  -- Messages
  ---------------------------------------------------------------------------

  local function reply(id, result, err)
    if err then
      write({ jsonrpc = "2.0", id = id, error = err })
    else
      write({ jsonrpc = "2.0", id = id, result = result == nil and vim.NIL or result })
    end
  end

  -- `exit`, or stdin closed (what `exit` would do), once every request
  -- is answered: the server reads its `shutdown` from the reply's handler
  local function maybe_exit()
    if (s.eof or s.exiting) and s.pending == 0 and not s.finished then
      rpc.notify("exit", nil)
    end
  end

  local function request(msg)
    local id, method, params = msg.id, msg.method, msg.params or {}
    if not s.initialized and method ~= "initialize" then
      return reply(id, nil, { code = ERR.not_initialized, message = "Server not initialized" })
    end
    if s.shutdown then
      return reply(id, nil, { code = ERR.invalid_request, message = "Server is shutting down" })
    end
    if NO_STDIO_METHODS[method] then
      return reply(id, nil, { code = ERR.method_not_found, message = "Method not found: " .. method })
    end
    local uri = params.textDocument and params.textDocument.uri
    disk = {}
    M.convert(params, uri, s.enc, true, line_of)
    if method == "initialize" then
      s.enc = M.encoding(params.capabilities)
      add_roots(params)
      -- `initialized` and the first didOpen may come before the reply
      s.initialized = true
    end
    s.pending = s.pending + 1
    local sent = rpc.request(method, params, function(err, result)
      s.pending = s.pending - 1
      if err then
        reply(id, nil, { code = err.code or ERR.internal, message = err.message or tostring(err) })
      else
        if method == "initialize" then
          for k in pairs(NO_STDIO) do
            result.capabilities[k] = nil
          end
          -- whole documents on change: no offsets to convert there
          result.capabilities.textDocumentSync.change = 1
          result.capabilities.positionEncoding = s.enc
        elseif method == "shutdown" then
          s.shutdown = true
        elseif method == "textDocument/codeAction" and type(result) == "table" then
          -- the actions that are edits; commands would change this
          -- Neovim's buffer only
          result = vim.tbl_filter(function(a)
            return a.edit ~= nil
          end, result)
        end
        reply(id, outgoing(result, uri))
      end
      maybe_exit()
    end)
    if not sent then
      s.pending = s.pending - 1
      reply(id, nil, { code = ERR.invalid_request, message = "Server is shutting down" })
    end
  end

  local function notification(msg)
    local method, params = msg.method, msg.params or {}
    if method == "exit" then
      s.exiting = true
      maybe_exit()
      return
    end
    if not s.initialized then
      return
    end
    if method == "textDocument/didOpen" then
      open(params.textDocument or {})
    elseif method == "textDocument/didChange" then
      change(params)
    end
    rpc.notify(method, params)
    if method == "textDocument/didClose" then
      close(params)
    end
  end

  local function handle(body)
    if body == false then
      return reply(vim.NIL, nil, { code = ERR.parse, message = "Missing Content-Length header" })
    end
    local ok, msg = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
    if not ok or type(msg) ~= "table" then
      return reply(vim.NIL, nil, { code = ERR.parse, message = "Parse error: invalid JSON" })
    end
    if msg.method == nil then
      -- a response to one of our requests (refresh): nothing to do
      if msg.id ~= nil then
        return
      end
      return reply(vim.NIL, nil, { code = ERR.invalid_request, message = "Invalid request" })
    end
    if type(msg.method) ~= "string" then
      return reply(msg.id or vim.NIL, nil, { code = ERR.invalid_request, message = "Invalid request" })
    end
    if msg.id ~= nil then
      request(msg)
    else
      notification(msg)
    end
  end

  return {
    receive = function(data)
      for _, body in ipairs(read(data)) do
        if s.finished then
          return
        end
        local ok, e = pcall(handle, body)
        if not ok then
          run.stderr("org lsp: " .. tostring(e) .. "\n")
        end
      end
    end,
    eof = function()
      s.eof = true
      maybe_exit()
    end,
    stop = function()
      rpc.terminate()
    end,
  }
end

---------------------------------------------------------------------------
-- stdin and stdout
---------------------------------------------------------------------------

-- A libuv stream on a standard fd (a pipe or a terminal), or nil for a
-- file.
local function stream(fd)
  local uv = vim.uv
  local kind = uv.guess_handle(fd)
  local h
  if kind == "pipe" then
    h = uv.new_pipe(false)
    if h and not h:open(fd) then
      h = nil
    end
  elseif kind == "tty" then
    h = uv.new_tty(fd, fd == 0)
  end
  return h
end

--- `org lsp [--stdio]`: serve until the client sends `exit` or closes
--- stdin.
function M.cmd_lsp(_, _)
  if state.session then
    fail("org lsp runs from an editor or a shell, not in a running Neovim", "usage")
  end
  if state.machine then
    fail("org lsp speaks JSON-RPC on stdout: it takes no --json or --jsonl", "usage")
  end
  -- nothing but the protocol on stdout
  local restore = run.protocol_stdout()

  local out = stream(1)
  local writing = 0
  local function send(str)
    if out then
      writing = writing + 1
      out:write(str, function()
        writing = writing - 1
      end)
    else
      -- stdout is a file: raw bytes, which Windows' text mode would
      -- give a \r before every \n
      vim.uv.fs_write(1, str)
    end
  end

  local code
  local sess = M.session(send, function(c)
    code = c
  end)
  local input = stream(0)
  if input then
    input:read_start(function(err, data)
      vim.schedule(function()
        if err or not data then
          sess.eof()
        else
          sess.receive(data)
        end
      end)
    end)
  else
    -- stdin is a file: all of it (raw bytes, as for stdout), then its end
    vim.schedule(function()
      local parts = {}
      while true do
        local data = vim.uv.fs_read(0, 65536)
        if not data or data == "" then
          break
        end
        parts[#parts + 1] = data
      end
      sess.receive(table.concat(parts))
      sess.eof()
    end)
  end

  local ok, e = pcall(function()
    while code == nil do
      vim.wait(1000, function()
        return code ~= nil
      end, 20)
    end
    vim.wait(5000, function()
      return writing == 0
    end, 5)
  end)
  if input then
    pcall(input.read_stop, input)
    pcall(input.close, input)
  end
  if out then
    pcall(out.close, out)
  end
  restore()
  if not ok then
    error(e, 0)
  end
  return { text = {}, code = code }
end

return M
