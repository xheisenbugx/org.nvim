---@mod org.extensions.caldav.http WebDAV requests of the caldav extension
---
--- Requests go through curl, with its options (the URL, the headers and the
--- credentials) given in a config on stdin, so a password never shows in
--- the process list. The functions that talk to the server run inside a
--- coroutine (`org.utils.run`) and return `value, err`.

local M = {}

local function utils()
  return require("org.utils")
end

---------------------------------------------------------------------------
-- XML (the multistatus replies)
---------------------------------------------------------------------------

---@class org.caldav.Xml
---@field name string the element's name without its namespace prefix
---@field attrs table<string, string>
---@field children org.caldav.Xml[]
---@field text string the character data directly inside it

local ENTITIES = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

---@param s string
---@return string
local function unescape(s)
  if not s:find("&", 1, true) then
    return s
  end
  return (
    s:gsub("&(#?%w+);", function(e)
      if ENTITIES[e] then
        return ENTITIES[e]
      end
      local n = e:match("^#x(%x+)$")
      local code = n and tonumber(n, 16) or tonumber(e:match("^#(%d+)$"))
      if code then
        return vim.fn.nr2char(code, true)
      end
      return nil
    end)
  )
end

--- Escape text for an XML body.
---@param s string
---@return string
function M.xml_escape(s)
  return (s:gsub("[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

--- Parse XML into a tree of elements. Namespace prefixes are dropped
--- (`D:href` and `d:href` are both `href`); comments, processing
--- instructions and doctypes are skipped. Tolerant: a wrong closing tag
--- closes the nearest element of that name.
---@param text string
---@return org.caldav.Xml root a pseudo element holding the document
function M.xml(text)
  ---@type org.caldav.Xml
  local root = { name = "", attrs = {}, children = {}, text = "" }
  local stack = { root }
  local pos, n = 1, #text
  while pos <= n do
    local lt = text:find("<", pos, true)
    local top = stack[#stack]
    if not lt then
      break
    end
    if lt > pos then
      top.text = top.text .. unescape(text:sub(pos, lt - 1))
    end
    if text:sub(lt, lt + 3) == "<!--" then
      local e = text:find("-->", lt + 4, true)
      pos = e and e + 3 or n + 1
    elseif text:sub(lt, lt + 8) == "<![CDATA[" then
      local e = text:find("]]>", lt + 9, true)
      top.text = top.text .. text:sub(lt + 9, (e or n + 1) - 1)
      pos = e and e + 3 or n + 1
    elseif text:sub(lt, lt + 1) == "<?" or text:sub(lt, lt + 1) == "<!" then
      local e = text:find(">", lt + 2, true)
      pos = e and e + 1 or n + 1
    else
      -- the end of the tag, past quoted attribute values
      local i, quote = lt + 1, nil
      while i <= n do
        local c = text:sub(i, i)
        if quote then
          if c == quote then
            quote = nil
          end
        elseif c == '"' or c == "'" then
          quote = c
        elseif c == ">" then
          break
        end
        i = i + 1
      end
      local tag = text:sub(lt + 1, i - 1)
      pos = i + 1
      if tag:sub(1, 1) == "/" then
        local name = vim.trim(tag:sub(2)):gsub("^.*:", "")
        for k = #stack, 2, -1 do
          if stack[k].name == name then
            for j = #stack, k, -1 do
              stack[j] = nil
            end
            break
          end
        end
      else
        local closed = tag:sub(-1) == "/"
        if closed then
          tag = tag:sub(1, -2)
        end
        local name, rest = tag:match("^([^%s]+)(.*)$")
        if name then
          ---@type org.caldav.Xml
          local node = { name = (name:gsub("^.*:", "")), attrs = {}, children = {}, text = "" }
          for k, _, v in rest:gmatch("([^%s=]+)%s*=%s*([\"'])(.-)%2") do
            node.attrs[(k:gsub("^.*:", ""))] = unescape(v)
          end
          top.children[#top.children + 1] = node
          if not closed then
            stack[#stack + 1] = node
          end
        end
      end
    end
  end
  return root
end

--- The first child of `node` named `name`.
---@param node org.caldav.Xml|nil
---@param name string
---@return org.caldav.Xml|nil
function M.child(node, name)
  for _, c in ipairs(node and node.children or {}) do
    if c.name == name then
      return c
    end
  end
  return nil
end

--- The first element named `name` anywhere under `node`.
---@param node org.caldav.Xml|nil
---@param name string
---@return org.caldav.Xml|nil
function M.find(node, name)
  for _, c in ipairs(node and node.children or {}) do
    if c.name == name then
      return c
    end
    local found = M.find(c, name)
    if found then
      return found
    end
  end
  return nil
end

---@class org.caldav.DavResponse
---@field href string the resource's path, normalized (`M.path`)
---@field status integer|nil the status of the response itself (a 404 in a multiget)
---@field props table<string, org.caldav.Xml> the properties found (propstat 200)

--- The responses of a `207 Multi-Status` body.
---@param body string
---@return org.caldav.DavResponse[]
function M.multistatus(body)
  local out = {}
  local ms = M.find(M.xml(body), "multistatus")
  for _, r in ipairs(ms and ms.children or {}) do
    local href = r.name == "response" and M.child(r, "href")
    if href then
      ---@type org.caldav.DavResponse
      local resp = { href = M.path(vim.trim(href.text)), props = {} }
      local status = M.child(r, "status")
      if status then
        resp.status = tonumber(status.text:match("HTTP/%S+%s+(%d+)"))
      end
      for _, ps in ipairs(r.children) do
        if ps.name == "propstat" then
          local st = M.child(ps, "status")
          local code = st and tonumber(st.text:match("HTTP/%S+%s+(%d+)")) or 200
          if code >= 200 and code < 300 then
            for _, p in ipairs((M.child(ps, "prop") or {}).children or {}) do
              resp.props[p.name] = p
            end
          end
        end
      end
      out[#out + 1] = resp
    end
  end
  return out
end

---------------------------------------------------------------------------
-- URLs
---------------------------------------------------------------------------

---@param s string
---@return string
local function decode(s)
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

---@param s string
---@return string
local function encode(s)
  return (s:gsub("[^%w%-%._~/]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

--- The path of a URL or an href, percent-encoded one way, so the same
--- resource compares equal however the server spelt it (`@` or `%40`).
---@param url string
---@return string
function M.path(url)
  local path = url:gsub("^%a[%w+.-]*://[^/]*", "")
  path = path:gsub("[?#].*$", "")
  if path == "" then
    path = "/"
  end
  return encode(decode(path))
end

--- `scheme://host[:port]` of a URL.
---@param url string
---@return string
function M.origin(url)
  return url:match("^(%a[%w+.-]*://[^/]*)") or ""
end

--- The URL of `href` (a path or a full URL) on the server of `base`.
---@param base string
---@param href string
---@return string
function M.resolve(base, href)
  if href:match("^%a[%w+.-]*://") then
    return href
  end
  return M.origin(base) .. href
end

--- A collection URL with its trailing slash.
---@param url string
---@return string
function M.collection(url)
  url = vim.trim(url)
  return url:sub(-1) == "/" and url or (url .. "/")
end

--- The href a new resource of `uid` is stored at in the collection `url`.
---@param url string
---@param uid string
---@return string
function M.href_for(url, uid)
  local name = uid
  if not name:match("^[%w%._-]+$") or #name > 100 then
    name = utils().sha256(uid):sub(1, 40)
  end
  return M.path(M.collection(url)) .. name .. ".ics"
end

---------------------------------------------------------------------------
-- The transport
---------------------------------------------------------------------------

---@class org.caldav.Request
---@field method string
---@field url string
---@field headers? string[] `Name: value` lines
---@field body? string
---@field user? string
---@field password? string
---@field auth? "basic"|"digest"|"any"
---@field curl? string[] the program and extra arguments
---@field timeout? integer seconds
---@field follow? boolean follow redirects

---@class org.caldav.Reply
---@field status integer
---@field headers table<string, string> names lower-cased
---@field body string

--- A value of a curl config file.
---@param s string
---@return string
local function quote(s)
  return '"' .. s:gsub('[\\"]', "\\%0"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
end

--- The curl config of a request: what goes on its stdin.
---@param req org.caldav.Request
---@param files { body?: string, out: string, headers: string }
---@return string
function M.curl_config(req, files)
  local lines = {
    "url = " .. quote(req.url),
    "request = " .. quote(req.method),
    "globoff",
    "silent",
    "show-error",
    "max-time = " .. tostring(req.timeout or 60),
    "output = " .. quote(files.out),
    "dump-header = " .. quote(files.headers),
    "write-out = " .. quote("%{http_code}"),
  }
  if req.follow then
    lines[#lines + 1] = "location"
  end
  for _, h in ipairs(req.headers or {}) do
    lines[#lines + 1] = "header = " .. quote(h)
  end
  if files.body then
    lines[#lines + 1] = "data-binary = " .. quote("@" .. files.body)
    -- no "Expect: 100-continue" round trip for a large body
    lines[#lines + 1] = "header = " .. quote("Expect:")
  end
  if req.user and req.user ~= "" then
    lines[#lines + 1] = "user = " .. quote(req.user .. ":" .. (req.password or ""))
    if req.auth == "digest" then
      lines[#lines + 1] = "digest"
    elseif req.auth == "any" then
      lines[#lines + 1] = "anyauth"
    else
      lines[#lines + 1] = "basic"
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

--- The headers of the last reply in a `--dump-header` file (a redirect or
--- a `100 Continue` comes before it).
---@param text string
---@return table<string, string>
function M.parse_headers(text)
  local headers = {}
  for line in (text:gsub("\r", "") .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^HTTP/") then
      headers = {}
    else
      local k, v = line:match("^([^:%s]+):%s*(.-)%s*$")
      if k then
        headers[k:lower()] = v
      end
    end
  end
  return headers
end

---@param path string
---@return string
local function slurp(path)
  local fh = io.open(path, "rb")
  if not fh then
    return ""
  end
  local s = fh:read("*a")
  fh:close()
  return s or ""
end

--- The path a program is started by: on Windows a launcher on the path
--- that isn't an .exe (`bw.cmd`) is only found by its full name.
---@param name string
---@return string
function M.program(name)
  local path = vim.fn.exepath(name)
  return path ~= "" and path or name
end

--- Send `req` with curl; `cb(reply, err)` on the main loop. Replaceable
--- (the specs stub it).
---@param req org.caldav.Request
---@param cb fun(reply: org.caldav.Reply|nil, err: string|nil)
function M.transport(req, cb)
  local cmd = vim.deepcopy(req.curl or { "curl" })
  if vim.fn.executable(cmd[1]) == 0 then
    vim.schedule(function()
      cb(nil, cmd[1] .. " not found")
    end)
    return
  end
  cmd[1] = M.program(cmd[1])
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  local files = { out = dir .. "/out", headers = dir .. "/headers" }
  if req.body then
    files.body = dir .. "/body"
    local fh = assert(io.open(files.body, "wb"))
    fh:write(req.body)
    fh:close()
  end
  vim.list_extend(cmd, { "--config", "-" })
  local ok, err = pcall(vim.system, cmd, { stdin = M.curl_config(req, files), text = true }, function(res)
    vim.schedule(function()
      local status = tonumber(vim.trim(res.stdout or ""):match("(%d%d%d)$"))
      local reply
      if res.code == 0 and status then
        reply = { status = status, headers = M.parse_headers(slurp(files.headers)), body = slurp(files.out) }
      end
      vim.fn.delete(dir, "rf")
      if reply then
        cb(reply, nil)
      else
        local msg = vim.trim(res.stderr or ""):gsub("^curl: %(%d+%) ", "")
        cb(nil, msg ~= "" and msg or ("curl exit code " .. res.code))
      end
    end)
  end)
  if not ok then
    vim.fn.delete(dir, "rf")
    vim.schedule(function()
      cb(nil, tostring(err))
    end)
  end
end

---------------------------------------------------------------------------
-- Credentials
---------------------------------------------------------------------------

-- "name\0field" -> the resolved secret of a calendar
local secrets = {}

--- Forget the passwords and tokens read so far.
function M.forget_secrets()
  secrets = {}
end

--- A password or token option: a string, a function returning one, or a
--- command (a list) whose first line of output it is. Read once and kept
--- for the session.
---@param c org.caldav.Calendar
---@param field "password"|"token"
---@return string|nil value, string|nil err
local function secret(c, field)
  local key = c.name .. "\0" .. field
  if secrets[key] then
    return secrets[key]
  end
  local v = c[field]
  local value, err
  if type(v) == "string" then
    value = v
  elseif type(v) == "function" then
    local ok, res = pcall(v, c)
    if ok and type(res) == "string" then
      value = res
    else
      err = string.format("the %s function failed: %s", field, tostring(res))
    end
  elseif type(v) == "table" then
    local argv = vim.deepcopy(v)
    argv[1] = M.program(tostring(argv[1]))
    local res = utils().await(function(cb)
      local ok, serr = pcall(vim.system, argv, { text = true }, cb)
      if not ok then
        cb({ code = 1, stdout = "", stderr = tostring(serr) })
      end
    end)
    local out = vim.trim((res.stdout or ""):match("^[^\r\n]*") or "")
    if res.code == 0 and out ~= "" then
      value = out
    else
      local why = vim.trim(res.stderr or "")
      err = string.format("the %s command failed: %s", field, why ~= "" and why or ("exit code " .. tostring(res.code)))
    end
  end
  if value then
    secrets[key] = value
  end
  return value, err
end

---@param c org.caldav.Calendar
local function forget(c)
  secrets[c.name .. "\0password"] = nil
  secrets[c.name .. "\0token"] = nil
end

---------------------------------------------------------------------------
-- Requests
---------------------------------------------------------------------------

---@class org.caldav.Calendar
---@field name string
---@field url string
---@field user? string
---@field password? string|string[]|fun(c: table): string
---@field token? string|string[]|fun(c: table): string
---@field auth? "basic"|"digest"|"any"
---@field headers? table<string, string>
---@field inbox? string|{ file: string, headline?: string }
---@field files? string[]
---@field direction? "twoway"|"pull"|"push"
---@field conflict? "local"|"remote"
---@field delete_local? "ask"|"always"|"never"
---@field delete_remote? "ask"|"always"|"never"
---@field todos? boolean
---@field past_days? integer|false

---@param reply org.caldav.Reply
---@return string
local function describe(reply)
  local s = reply.status
  if s == 401 then
    return "401: the server refused the user, password or token"
  elseif s == 403 then
    return "403: the server does not allow it"
  elseif s == 404 then
    return "404: not found (check the calendar's url)"
  elseif s == 412 then
    return "412: it changed on the server"
  end
  return "HTTP " .. s
end
M.describe = describe

--- Send a request of calendar `c` (inside a coroutine).
---@param c org.caldav.Calendar
---@param req { method: string, url: string, headers?: string[], body?: string, follow?: boolean }
---@return org.caldav.Reply|nil reply, string|nil err
function M.request(c, req)
  local o = require("org.extensions.caldav").opts()
  for attempt = 1, 2 do
    ---@type org.caldav.Request
    local r = {
      method = req.method,
      url = req.url,
      headers = vim.deepcopy(req.headers or {}),
      body = req.body,
      follow = req.follow,
      curl = o.curl,
      timeout = o.timeout,
      auth = c.auth,
    }
    for name, value in pairs(c.headers or {}) do
      r.headers[#r.headers + 1] = name .. ": " .. value
    end
    if c.token then
      local token, err = secret(c, "token")
      if not token then
        return nil, err or "no token"
      end
      r.headers[#r.headers + 1] = "Authorization: Bearer " .. token
    elseif c.user then
      r.user = c.user
      if c.password then
        local password, err = secret(c, "password")
        if not password then
          return nil, err or "no password"
        end
        r.password = password
      end
    end
    ---@type org.caldav.Reply|nil, string|nil
    local reply, err = utils().await(function(cb)
      M.transport(r, cb)
    end)
    if not reply then
      return nil, err or "the request failed"
    end
    -- a token (or a password from a command) that stopped working is read
    -- again once
    local renewable = type(c.token) ~= "string" and c.token ~= nil or type(c.password) == "table"
    if reply.status == 401 and attempt == 1 and renewable then
      forget(c)
    else
      return reply, nil
    end
  end
  return nil, "the request failed"
end

local XML = 'Content-Type: application/xml; charset="utf-8"'
local NS = 'xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"'

---@param c org.caldav.Calendar
---@param method string
---@param url string
---@param depth string
---@param body string
---@return org.caldav.DavResponse[]|nil responses, string|nil err
local function dav(c, method, url, depth, body)
  local reply, err = M.request(c, {
    method = method,
    url = url,
    headers = { "Depth: " .. depth, XML },
    body = '<?xml version="1.0" encoding="utf-8"?>\n' .. body,
    follow = true,
  })
  if not reply then
    return nil, err
  end
  if reply.status ~= 207 then
    return nil, describe(reply)
  end
  return M.multistatus(reply.body), nil
end

---@param p org.caldav.Xml|nil
---@return string|nil
local function etag_of(p)
  local s = p and vim.trim(p.text) or ""
  return s ~= "" and s or nil
end

--- The resources of the calendar holding a component `comp` ("VEVENT",
--- "VTODO"): href -> etag. With `start` (`YYYYMMDDTHHMMSSZ`), only those
--- with an occurrence at or after it.
---@param c org.caldav.Calendar
---@param comp string
---@param start? string
---@return table<string, string>|nil etags, string|nil err
function M.query(c, comp, start)
  local range = start and ('<C:time-range start="' .. start .. '"/>') or ""
  local body = table.concat({
    "<C:calendar-query " .. NS .. ">",
    "<D:prop><D:getetag/></D:prop>",
    '<C:filter><C:comp-filter name="VCALENDAR">',
    '<C:comp-filter name="' .. comp .. '">' .. range .. "</C:comp-filter>",
    "</C:comp-filter></C:filter>",
    "</C:calendar-query>",
  }, "\n")
  local responses, err = dav(c, "REPORT", M.collection(c.url), "1", body)
  if not responses then
    return nil, err
  end
  local out = {}
  for _, r in ipairs(responses) do
    local etag = etag_of(r.props.getetag)
    if etag then
      out[r.href] = etag
    end
  end
  return out, nil
end

--- Every resource of the calendar: href -> etag.
---@param c org.caldav.Calendar
---@return table<string, string>|nil etags, string|nil err
function M.etags(c)
  local url = M.collection(c.url)
  local body = "<D:propfind " .. NS .. "><D:prop><D:getetag/></D:prop></D:propfind>"
  local responses, err = dav(c, "PROPFIND", url, "1", body)
  if not responses then
    return nil, err
  end
  local own = M.path(url)
  local out = {}
  for _, r in ipairs(responses) do
    local etag = etag_of(r.props.getetag)
    if etag and r.href ~= own and r.href .. "/" ~= own then
      out[r.href] = etag
    end
  end
  return out, nil
end

--- The contents of resources: href -> `{ etag, ics }`. A resource the
--- server no longer has is left out.
---@param c org.caldav.Calendar
---@param hrefs string[]
---@return table<string, { etag: string, ics: string }>|nil data, string|nil err
function M.multiget(c, hrefs)
  local out = {}
  local batch = 50
  for first = 1, #hrefs, batch do
    local parts = {
      "<C:calendar-multiget " .. NS .. ">",
      "<D:prop><D:getetag/><C:calendar-data/></D:prop>",
    }
    for i = first, math.min(first + batch - 1, #hrefs) do
      parts[#parts + 1] = "<D:href>" .. M.xml_escape(hrefs[i]) .. "</D:href>"
    end
    parts[#parts + 1] = "</C:calendar-multiget>"
    local responses, err = dav(c, "REPORT", M.collection(c.url), "1", table.concat(parts, "\n"))
    if not responses then
      return nil, err
    end
    for _, r in ipairs(responses) do
      local data = r.props["calendar-data"]
      if data and data.text:find("BEGIN:VCALENDAR", 1, true) then
        out[r.href] = { etag = etag_of(r.props.getetag) or "", ics = data.text }
      end
    end
  end
  return out, nil
end

--- An etag as If-Match takes it: a weak one (`W/"x"`) never matches there,
--- so its opaque part is sent.
---@param etag string
---@return string
local function strong(etag)
  return (etag:gsub("^W/", ""))
end

--- Store `ics` at `href`: only when the resource is still at `etag`, or
--- (without one) only when there is none yet. Returns the new etag, or ""
--- when the server gave none.
---@param c org.caldav.Calendar
---@param href string
---@param ics string
---@param etag? string
---@return string|nil etag, string|nil err, integer|nil status
function M.put(c, href, ics, etag)
  local reply, err = M.request(c, {
    method = "PUT",
    url = M.resolve(c.url, href),
    headers = {
      "Content-Type: text/calendar; charset=utf-8",
      etag and etag ~= "" and ("If-Match: " .. strong(etag)) or "If-None-Match: *",
    },
    body = ics,
  })
  if not reply then
    return nil, err, nil
  end
  if reply.status < 200 or reply.status >= 300 then
    return nil, describe(reply), reply.status
  end
  return reply.headers.etag or "", nil, reply.status
end

--- Delete the resource at `href` when it is still at `etag`. One that is
--- gone already counts as deleted.
---@param c org.caldav.Calendar
---@param href string
---@param etag? string
---@return boolean ok, string|nil err
function M.delete(c, href, etag)
  local reply, err = M.request(c, {
    method = "DELETE",
    url = M.resolve(c.url, href),
    headers = etag and etag ~= "" and { "If-Match: " .. strong(etag) } or {},
  })
  if not reply then
    return false, err
  end
  if (reply.status >= 200 and reply.status < 300) or reply.status == 404 or reply.status == 410 then
    return true, nil
  end
  return false, describe(reply)
end

---@class org.caldav.Collection
---@field name string
---@field url string
---@field components string[] "VEVENT", "VTODO", ...

--- The calendars of the account at `c.url` (the server's address, a
--- principal or a calendar home): follows `current-user-principal` and
--- `calendar-home-set`, then lists the calendar collections.
---@param c org.caldav.Calendar
---@return org.caldav.Collection[]|nil calendars, string|nil err
function M.discover(c)
  local function props(url, names, depth)
    local body = "<D:propfind " .. NS .. "><D:prop>" .. names .. "</D:prop></D:propfind>"
    return dav(c, "PROPFIND", url, depth, body)
  end
  local function href_in(p)
    local h = M.find(p, "href")
    return h and vim.trim(h.text) ~= "" and M.resolve(c.url, vim.trim(h.text)) or nil
  end
  local start = "<D:current-user-principal/><C:calendar-home-set/><D:resourcetype/>"
  local responses, err = props(c.url, start, "0")
  if not responses then
    return nil, err
  end
  local first = responses[1] or { props = {} }
  local home = href_in(first.props["calendar-home-set"])
  if not home then
    local principal = href_in(first.props["current-user-principal"])
    if principal then
      responses, err = props(principal, "<C:calendar-home-set/>", "0")
      if not responses then
        return nil, err
      end
      home = href_in((responses[1] or { props = {} }).props["calendar-home-set"])
    end
  end
  home = M.collection(home or c.url)
  local wanted = "<D:displayname/><D:resourcetype/><C:supported-calendar-component-set/>"
  responses, err = props(home, wanted, "1")
  if not responses then
    return nil, err
  end
  local out = {}
  for _, r in ipairs(responses) do
    if M.child(r.props.resourcetype, "calendar") then
      local comps = {}
      for _, comp in ipairs((r.props["supported-calendar-component-set"] or { children = {} }).children) do
        if comp.attrs.name then
          comps[#comps + 1] = comp.attrs.name:upper()
        end
      end
      local name = r.props.displayname and vim.trim(r.props.displayname.text) or ""
      out[#out + 1] = {
        name = name ~= "" and name or (decode(r.href):gsub("/$", ""):match("[^/]*$") or r.href),
        url = M.resolve(home, r.href),
        components = comps,
      }
    end
  end
  table.sort(out, function(a, b)
    return a.name < b.name
  end)
  return out, nil
end

return M
