---@mod org.preview.server A small HTTP/1.1 server on vim.uv for the live preview
---
--- Only what the preview needs: GET and HEAD, one request per connection
--- (`Connection: close`), plain responses with a Content-Length and
--- server-sent event streams that stay open. Requests are handed to the
--- handler on the main loop (vim.schedule), so it can use the whole API.
---
---   local srv = assert(server.start({ host = "127.0.0.1", port = 0 }, function(req, res)
---     res:send(200, { ["Content-Type"] = "text/plain" }, "hi")
---   end))
---   srv.port -- the port it listens on
---   srv:close()

local uv = vim.uv

local M = {}

local MAX_HEAD = 16 * 1024

M.REASONS = {
  [200] = "OK",
  [301] = "Moved Permanently",
  [400] = "Bad Request",
  [403] = "Forbidden",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [413] = "Content Too Large",
  [421] = "Misdirected Request",
  [431] = "Request Header Fields Too Large",
  [500] = "Internal Server Error",
}

M.MIME = {
  html = "text/html; charset=utf-8",
  htm = "text/html; charset=utf-8",
  xhtml = "application/xhtml+xml",
  css = "text/css; charset=utf-8",
  js = "text/javascript; charset=utf-8",
  mjs = "text/javascript; charset=utf-8",
  json = "application/json",
  xml = "application/xml",
  txt = "text/plain; charset=utf-8",
  org = "text/plain; charset=utf-8",
  csv = "text/csv; charset=utf-8",
  svg = "image/svg+xml",
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
  avif = "image/avif",
  bmp = "image/bmp",
  ico = "image/x-icon",
  tif = "image/tiff",
  tiff = "image/tiff",
  pdf = "application/pdf",
  mp4 = "video/mp4",
  webm = "video/webm",
  ogv = "video/ogg",
  ogg = "audio/ogg",
  mp3 = "audio/mpeg",
  wav = "audio/wav",
  woff = "font/woff",
  woff2 = "font/woff2",
  ttf = "font/ttf",
  otf = "font/otf",
}

--- MIME type of a file name.
---@param name string
---@return string
function M.mime(name)
  local ext = name:match("%.([%w]+)$")
  return ext and M.MIME[ext:lower()] or "application/octet-stream"
end

--- Decode %XX escapes. nil when an escape is malformed.
---@param s string
---@return string|nil
function M.url_decode(s)
  if s:find("%%%X") or s:find("%%%x%X") or s:find("%%%x?$") then
    return nil
  end
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

--- Parse the head of a request: { method, target, path (decoded, no
--- query), version, headers (lower-case names) }. nil when malformed.
---@param head string
---@return table|nil
function M.parse_head(head)
  local lines = vim.split(head, "\r\n", { plain = true })
  local method, target, version = (lines[1] or ""):match("^(%u+) (%S+) HTTP/(%d%.%d)$")
  if not method then
    return nil
  end
  local headers = {}
  for i = 2, #lines do
    local l = lines[i]
    if l ~= "" then
      local k, v = l:match("^([^:%s]+):%s*(.-)%s*$")
      if not k then
        return nil
      end
      headers[k:lower()] = v
    end
  end
  local raw = target:match("^[^?#]*")
  local path = M.url_decode(raw)
  if not path then
    return nil
  end
  return { method = method, target = target, path = path, version = version, headers = headers }
end

---@class org.preview.Response
---@field client uv.uv_tcp_t
---@field head_only boolean
---@field done boolean
local Response = {}
Response.__index = Response

local function close(handle)
  if handle and not handle:is_closing() then
    handle:close()
  end
end

local function status_line(status, headers)
  local out = { ("HTTP/1.1 %d %s"):format(status, M.REASONS[status] or "Unknown") }
  local hs = vim.tbl_extend("keep", headers or {}, {
    ["Cache-Control"] = "no-store",
    ["X-Content-Type-Options"] = "nosniff",
    ["Referrer-Policy"] = "no-referrer",
  })
  local keys = vim.tbl_keys(hs)
  table.sort(keys)
  for _, k in ipairs(keys) do
    out[#out + 1] = k .. ": " .. tostring(hs[k])
  end
  return table.concat(out, "\r\n") .. "\r\n\r\n"
end

--- Send a whole response and close the connection.
---@param status integer
---@param headers? table<string, string|integer>
---@param body? string
function Response:send(status, headers, body)
  if self.done then
    return
  end
  self.done = true
  body = body or ""
  headers = vim.tbl_extend("force", { ["Content-Length"] = #body, ["Connection"] = "close" }, headers or {})
  if not headers["Content-Type"] then
    headers["Content-Type"] = "text/plain; charset=utf-8"
  end
  local data = status_line(status, headers) .. (self.head_only and "" or body)
  local client = self.client
  if client:is_closing() then
    return
  end
  client:write(data, function()
    if not client:is_closing() then
      client:shutdown(function()
        close(client)
      end)
    end
  end)
end

--- A short plain-text error response.
---@param status integer
function Response:fail(status)
  self:send(status, nil, (M.REASONS[status] or "Error") .. "\n")
end

---@class org.preview.Stream
---@field client uv.uv_tcp_t
---@field closed boolean
---@field on_close? fun()
local Stream = {}
Stream.__index = Stream

--- Write raw text to the stream; false once the client is gone.
---@param text string
---@return boolean
function Stream:write(text)
  if self.closed or self.client:is_closing() then
    return false
  end
  local ok = pcall(self.client.write, self.client, text, function(err)
    if err then
      self:close()
    end
  end)
  if not ok then
    self:close()
  end
  return ok
end

--- Send a server-sent event.
---@param event string|nil
---@param data string
---@return boolean
function Stream:event(event, data)
  local out = {}
  if event then
    out[#out + 1] = "event: " .. event
  end
  for _, l in ipairs(vim.split(data, "\n", { plain = true })) do
    out[#out + 1] = "data: " .. l
  end
  return self:write(table.concat(out, "\n") .. "\n\n")
end

function Stream:close()
  if self.closed then
    return
  end
  self.closed = true
  close(self.client)
  if self.on_close then
    local cb = self.on_close
    vim.schedule(cb)
  end
end

--- Turn the response into an event stream (text/event-stream) that stays
--- open until the client leaves or `stream:close()`.
---@return org.preview.Stream
function Response:stream()
  self.done = true
  local s = setmetatable({ client = self.client, closed = false }, Stream)
  s:write(status_line(200, {
    ["Content-Type"] = "text/event-stream; charset=utf-8",
    ["Connection"] = "keep-alive",
  }))
  -- reading on: EOF (the page went away) closes the stream
  pcall(self.client.read_start, self.client, function(err, data)
    if err or not data then
      s:close()
    end
  end)
  return s
end

---@class org.preview.Server
---@field tcp uv.uv_tcp_t
---@field host string
---@field port integer
---@field clients table<uv.uv_tcp_t, true>
local Server = {}
Server.__index = Server

function Server:close()
  for c in pairs(self.clients) do
    close(c)
  end
  self.clients = {}
  close(self.tcp)
end

---@return boolean
function Server:is_running()
  return self.tcp ~= nil and not self.tcp:is_closing()
end

--- Start listening on `opts.host`:`opts.port` (0 = a free port).
--- `handler(req, res)` gets each request (see `parse_head`).
---@param opts { host: string, port: integer }
---@param handler fun(req: table, res: org.preview.Response)
---@return org.preview.Server|nil server, string|nil err
function M.start(opts, handler)
  local tcp = uv.new_tcp()
  if not tcp then
    return nil, "cannot create a TCP handle"
  end
  local ok, err = tcp:bind(opts.host, opts.port or 0)
  if not ok then
    close(tcp)
    return nil, ("cannot listen on %s:%s: %s"):format(opts.host, tostring(opts.port), tostring(err))
  end
  local srv = setmetatable({ tcp = tcp, host = opts.host, clients = {} }, Server)
  local lok, lerr = tcp:listen(64, function(e)
    if e then
      return
    end
    local client = uv.new_tcp()
    if not client then
      return
    end
    if not pcall(tcp.accept, tcp, client) then
      close(client)
      return
    end
    srv.clients[client] = true
    local buf = ""
    local function forget()
      srv.clients[client] = nil
    end
    client:read_start(function(rerr, data)
      if rerr or not data then
        client:read_stop()
        forget()
        close(client)
        return
      end
      buf = buf .. data
      local stop = buf:find("\r\n\r\n", 1, true)
      local res = setmetatable({ client = client, head_only = false, done = false }, Response)
      if not stop then
        if #buf > MAX_HEAD then
          client:read_stop()
          res:fail(431)
          forget()
        end
        return
      end
      client:read_stop()
      local req = M.parse_head(buf:sub(1, stop - 1))
      if not req then
        res:fail(400)
        forget()
        return
      end
      res.head_only = req.method == "HEAD"
      vim.schedule(function()
        forget()
        if client:is_closing() then
          return
        end
        local hok, herr = pcall(handler, req, res)
        if not hok then
          if not res.done then
            res:send(500, nil, "Internal Server Error\n")
          end
          vim.notify("org preview: " .. tostring(herr), vim.log.levels.DEBUG)
        elseif not res.done then
          res:fail(404)
        end
      end)
    end)
  end)
  if not lok then
    close(tcp)
    return nil, tostring(lerr)
  end
  local name = tcp:getsockname()
  srv.port = name and name.port or opts.port
  return srv
end

return M
