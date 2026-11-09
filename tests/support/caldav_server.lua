-- A stand-in for a CalDAV server, for the caldav extension's specs. It
-- keeps one account in memory (a principal, a calendar home and calendar
-- collections of `.ics` resources) and answers what the extension sends:
-- PROPFIND (etags, discovery), REPORT calendar-query (component and
-- time-range start filters) and calendar-multiget, GET, PUT and DELETE
-- with If-Match / If-None-Match, basic and bearer authentication.
--
-- `srv:transport()` answers requests in process (the fast specs);
-- `srv:listen()` serves the same on 127.0.0.1 with vim.uv, so the
-- extension can be run end to end through real curl. Not a complete
-- implementation.
local parser = require("org.extensions.ics.parser")

local M = {}
M.__index = M

local function esc(s)
  return (s:gsub("[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

--- A new server. `opts.user` / `opts.password` (basic) or `opts.token`
--- (bearer) make it ask for credentials.
function M.new(opts)
  local self = setmetatable({}, M)
  self.opts = opts or {}
  self.root = "/dav/"
  self.principal = "/dav/principals/me/"
  self.home = "/dav/calendars/me/"
  self.calendars = {} -- name -> { display, components, items = { file -> { ics, etag } } }
  self.log = {}
  self.n = 0
  -- behaviours a spec can switch on
  self.no_etag = false -- PUT replies without an ETag header
  self.fail = nil -- fun(method, path) -> status|nil: answer with that status
  return self
end

--- Add a calendar collection; returns its path.
function M:calendar(name, opts)
  opts = opts or {}
  self.calendars[name] = {
    display = opts.display or name,
    components = opts.components or { "VEVENT", "VTODO" },
    items = {},
  }
  return self.home .. name .. "/"
end

function M:etag()
  self.n = self.n + 1
  return '"e' .. self.n .. '"'
end

--- Store a resource as if another client had (a new etag).
function M:put(name, file, ics)
  self.calendars[name].items[file] = { ics = ics, etag = self:etag() }
  return self.calendars[name].items[file]
end

--- Remove a resource as if another client had.
function M:remove(name, file)
  self.calendars[name].items[file] = nil
end

--- The text of a resource, or nil.
function M:get(name, file)
  local it = self.calendars[name].items[file]
  return it and it.ics or nil
end

--- The file names of a calendar, sorted.
function M:files(name)
  local out = vim.tbl_keys(self.calendars[name].items)
  table.sort(out)
  return out
end

--- Requests of `method` whose path matches a Lua pattern.
function M:requests(method, pattern)
  local out = {}
  for _, r in ipairs(self.log) do
    if (not method or r.method == method) and (not pattern or r.path:find(pattern)) then
      out[#out + 1] = r
    end
  end
  return out
end

local function decode(s)
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

--- name, file of a path under the calendar home.
function M:locate(path)
  local rest = path:sub(1, #self.home) == self.home and path:sub(#self.home + 1) or nil
  if not rest then
    return nil
  end
  local name, file = rest:match("^([^/]+)/?(.*)$")
  if not name or not self.calendars[name] then
    return nil
  end
  return name, file
end

local function multistatus(responses)
  return 207,
    { ["Content-Type"] = 'application/xml; charset="utf-8"' },
    '<?xml version="1.0" encoding="utf-8"?>\n<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">\n'
      .. table.concat(responses, "\n")
      .. "\n</d:multistatus>\n"
end

local function response(href, props)
  return "<d:response><d:href>"
    .. esc(href)
    .. "</d:href><d:propstat><d:prop>"
    .. props
    .. "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
end

-- Whether a resource has a component `comp` with an occurrence at or
-- after `start` (naive seconds, UTC).
local function matches(ics, comp, start)
  if not ics:find("BEGIN:" .. comp, 1, true) then
    return false
  end
  if not start or comp ~= "VEVENT" then
    return true
  end
  for _, ev in ipairs(parser.parse(ics).events) do
    local stop = ev.stop and ev.stop.naive or (ev.start.naive + (ev.duration or (ev.start.all_day and 86400 or 0)))
    if ev.rrule or #ev.rdates > 0 or stop >= start then
      return true
    end
  end
  return false
end

--- Answer a request: status, headers, body.
function M:handle(method, path, headers, body)
  path = decode(path:gsub("[?#].*$", ""))
  self.log[#self.log + 1] = { method = method, path = path, headers = headers, body = body }
  local o = self.opts
  if o.token then
    if headers.authorization ~= "Bearer " .. o.token then
      return 401, { ["WWW-Authenticate"] = "Bearer" }, "unauthorized"
    end
  elseif o.user then
    local want = "Basic " .. vim.base64.encode(o.user .. ":" .. (o.password or ""))
    if headers.authorization ~= want then
      return 401, { ["WWW-Authenticate"] = 'Basic realm="dav"' }, "unauthorized"
    end
  end
  local forced = self.fail and self.fail(method, path)
  if forced then
    return forced, {}, "failed"
  end

  if method == "PROPFIND" then
    local depth = headers.depth or "0"
    if path == self.root then
      return multistatus({
        response(
          self.root,
          "<d:current-user-principal><d:href>"
            .. self.principal
            .. "</d:href></d:current-user-principal><d:resourcetype><d:collection/></d:resourcetype>"
        ),
      })
    elseif path == self.principal then
      return multistatus({
        response(self.principal, "<cal:calendar-home-set><d:href>" .. self.home .. "</d:href></cal:calendar-home-set>"),
      })
    elseif path == self.home then
      local out = { response(self.home, "<d:resourcetype><d:collection/></d:resourcetype>") }
      local names = vim.tbl_keys(self.calendars)
      table.sort(names)
      for _, name in ipairs(depth == "0" and {} or names) do
        local cal = self.calendars[name]
        local comps = {}
        for _, c in ipairs(cal.components) do
          comps[#comps + 1] = '<cal:comp name="' .. c .. '"/>'
        end
        out[#out + 1] = response(
          self.home .. name .. "/",
          "<d:displayname>"
            .. esc(cal.display)
            .. "</d:displayname><d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>"
            .. "<cal:supported-calendar-component-set>"
            .. table.concat(comps)
            .. "</cal:supported-calendar-component-set>"
        )
      end
      return multistatus(out)
    end
    local name, file = self:locate(path)
    if not name or file ~= "" then
      return 404, {}, "not found"
    end
    local out =
      { response(self.home .. name .. "/", "<d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>") }
    if depth ~= "0" then
      for _, f in ipairs(self:files(name)) do
        out[#out + 1] = response(
          self.home .. name .. "/" .. f,
          "<d:getetag>" .. esc(self.calendars[name].items[f].etag) .. "</d:getetag>"
        )
      end
    end
    return multistatus(out)
  end

  local name, file = self:locate(path)
  if not name then
    return 404, {}, "not found"
  end
  local cal = self.calendars[name]

  if method == "REPORT" then
    local out = {}
    if body:find("calendar%-multiget") then
      for href in body:gmatch("<[%w]*:?href>([^<]*)</[%w]*:?href>") do
        local _, f = self:locate(decode((href:gsub("&amp;", "&"))))
        local it = f and cal.items[f]
        if it then
          out[#out + 1] = response(
            self.home .. name .. "/" .. f,
            "<d:getetag>" .. esc(it.etag) .. "</d:getetag><cal:calendar-data>" .. esc(it.ics) .. "</cal:calendar-data>"
          )
        else
          out[#out + 1] = "<d:response><d:href>"
            .. esc(href)
            .. "</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>"
        end
      end
      return multistatus(out)
    end
    local comp = body:match('comp%-filter name="(VEVENT)"') or body:match('comp%-filter name="(VTODO)"')
    local start = body:match('time%-range start="([^"]+)"')
    local t = start and parser.time(start)
    for _, f in ipairs(self:files(name)) do
      local it = cal.items[f]
      if comp and matches(it.ics, comp, t and t.naive) then
        out[#out + 1] = response(self.home .. name .. "/" .. f, "<d:getetag>" .. esc(it.etag) .. "</d:getetag>")
      end
    end
    return multistatus(out)
  end

  local it = cal.items[file]
  if method == "GET" then
    if not it then
      return 404, {}, "not found"
    end
    return 200, { ETag = it.etag, ["Content-Type"] = "text/calendar" }, it.ics
  elseif method == "PUT" then
    if headers["if-none-match"] == "*" and it then
      return 412, {}, "exists"
    end
    if headers["if-match"] and (not it or it.etag ~= headers["if-match"]) then
      return 412, {}, "changed"
    end
    local comp = body:match("BEGIN:(VEVENT)") or body:match("BEGIN:(VTODO)")
    if not comp or not vim.tbl_contains(cal.components, comp) then
      return 403, {}, "unsupported component"
    end
    local new = self:put(name, file, body)
    return it and 204 or 201, self.no_etag and {} or { ETag = new.etag }, ""
  elseif method == "DELETE" then
    if not it then
      return 404, {}, "not found"
    end
    if headers["if-match"] and it.etag ~= headers["if-match"] then
      return 412, {}, "changed"
    end
    cal.items[file] = nil
    return 204, {}, ""
  end
  return 405, {}, "method not allowed"
end

--- A replacement for `org.extensions.caldav.http`'s transport that
--- answers in process (credentials as curl would send them).
function M:transport()
  return function(req, cb)
    local headers = {}
    for _, h in ipairs(req.headers or {}) do
      local k, v = h:match("^([^:]+):%s*(.*)$")
      if k then
        headers[k:lower()] = v
      end
    end
    if req.user and req.user ~= "" then
      headers.authorization = "Basic " .. vim.base64.encode(req.user .. ":" .. (req.password or ""))
    end
    local path = req.url:gsub("^%a+://[^/]*", "")
    local status, rh, body = self:handle(req.method, path, headers, req.body or "")
    local out = {}
    for k, v in pairs(rh) do
      out[k:lower()] = v
    end
    vim.schedule(function()
      cb({ status = status, headers = out, body = body }, nil)
    end)
  end
end

local REASON = { [200] = "OK", [201] = "Created", [204] = "No Content", [207] = "Multi-Status" }

--- Serve on 127.0.0.1; returns the base URL (`http://127.0.0.1:PORT`).
function M:listen()
  local server = assert(vim.uv.new_tcp())
  server:bind("127.0.0.1", 0)
  server:listen(32, function()
    local client = assert(vim.uv.new_tcp())
    server:accept(client)
    local buf, done = "", false
    client:read_start(function(_, chunk)
      if not chunk then
        if not client:is_closing() then
          client:close()
        end
        return
      end
      buf = buf .. chunk
      local head_end = buf:find("\r\n\r\n", 1, true)
      if done or not head_end then
        return
      end
      local head = buf:sub(1, head_end - 1)
      local len = tonumber(head:lower():match("\r\ncontent%-length:%s*(%d+)")) or 0
      if #buf < head_end + 3 + len then
        return
      end
      done = true
      local body = buf:sub(head_end + 4, head_end + 3 + len)
      local method, path = head:match("^(%S+)%s+(%S+)")
      local headers = {}
      for k, v in head:gmatch("\r\n([^:\r\n]+):%s*([^\r\n]*)") do
        headers[k:lower()] = v
      end
      vim.schedule(function()
        local status, rh, rb = self:handle(method, path, headers, body)
        local lines = { string.format("HTTP/1.1 %d %s", status, REASON[status] or "Status") }
        for k, v in pairs(rh) do
          lines[#lines + 1] = k .. ": " .. v
        end
        lines[#lines + 1] = "Content-Length: " .. #rb
        lines[#lines + 1] = "Connection: close"
        client:write(table.concat(lines, "\r\n") .. "\r\n\r\n" .. rb, function()
          if not client:is_closing() then
            client:close()
          end
        end)
      end)
    end)
  end)
  self.server = server
  self.url = "http://127.0.0.1:" .. server:getsockname().port
  return self.url
end

--- Stop serving.
function M:close()
  if self.server and not self.server:is_closing() then
    self.server:close()
  end
  self.server = nil
end

return M
