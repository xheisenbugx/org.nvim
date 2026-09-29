-- A local stand-in for Google's OAuth and Calendar v3 endpoints, served on
-- 127.0.0.1 with vim.uv, so the gcal extension can be exercised end to end
-- through real curl without touching the network. It keeps events in
-- memory and follows the API where the extension depends on it: paging,
-- sync tokens (410 when invalidated), showDeleted, ETags with If-Match
-- (412), PATCH merging (a start with both date and dateTime is refused),
-- recurring events (a time zone is required; /instances expands simple
-- RRULEs) and 401 for unknown tokens. Not a complete implementation.
local M = {}
M.__index = M

local function json(v)
  return vim.json.encode(v)
end

local function urldecode(s)
  return (s:gsub("%+", " "):gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function parse_query(s)
  local out = {}
  for pair in (s or ""):gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    out[urldecode(k)] = urldecode(v)
  end
  return out
end

local function b64url(s)
  return (vim.base64.encode(s):gsub("%+", "-"):gsub("/", "_"):gsub("=+$", ""))
end

local function challenge_of(verifier)
  local hex = vim.fn.sha256(verifier)
  return b64url((hex:gsub("%x%x", function(h)
    return string.char(tonumber(h, 16))
  end)))
end

local function rfc3339_to_epoch(s)
  local y, mo, d, h, mi, sec, rest = s:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):?(%d*)%.?%d*(.*)$")
  if not y then
    local yy, mm, dd = s:match("^(%d+)-(%d+)-(%d+)$")
    if not yy then
      return nil
    end
    y, mo, d, h, mi, sec, rest = yy, mm, dd, "0", "0", "0", "Z"
  end
  local off = 0
  if rest ~= "" and rest ~= "Z" then
    local sign, oh, om = rest:match("^([+-])(%d%d):?(%d%d)$")
    off = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "-" and -1 or 1)
  end
  return require("org.date").days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + tonumber(h) * 3600
    + tonumber(mi) * 60
    + (tonumber(sec) or 0)
    - off
end

local function epoch_to_utc(t)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

--- Start a server. Returns it; `server.base` is "http://127.0.0.1:PORT".
function M.start()
  local self = setmetatable({
    calendars = {},
    tokens = {}, -- access token -> true
    refresh = {}, -- refresh token -> true
    codes = {}, -- code -> { challenge, redirect_uri }
    log = {},
    seq = 0,
    min_sync = 0, -- sync tokens older than this answer 410
    page_size = 2,
    etag_n = 0,
    fail_next = {}, -- list of statuses to answer next (rate limit tests)
  }, M)
  local server = vim.uv.new_tcp()
  assert(server:bind("127.0.0.1", 0))
  self.port = server:getsockname().port
  self.base = "http://127.0.0.1:" .. self.port
  self.server = server
  server:listen(16, function(err)
    if err then
      return
    end
    local client = vim.uv.new_tcp()
    server:accept(client)
    local buf = ""
    client:read_start(function(rerr, chunk)
      if rerr or not chunk then
        if not client:is_closing() then
          client:close()
        end
        return
      end
      buf = buf .. chunk
      local head_end = buf:find("\r\n\r\n", 1, true)
      if not head_end then
        return
      end
      local head = buf:sub(1, head_end - 1)
      local len = tonumber(head:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
      if #buf < head_end + 3 + len then
        return
      end
      local body = buf:sub(head_end + 4, head_end + 3 + len)
      local method, target = head:match("^(%u+) (%S+) HTTP/")
      local headers = {}
      for k, v in head:gmatch("\r\n([^:\r\n]+):%s*([^\r\n]*)") do
        headers[k:lower()] = v
      end
      buf = ""
      vim.schedule(function()
        local ok, status, out, extra = pcall(self.handle, self, method, target, headers, body)
        if not ok then
          status, out = 500, json({ error = { message = tostring(status) } })
        end
        local lines = { "HTTP/1.1 " .. status .. " X", "Content-Type: application/json", "Connection: close" }
        for k, v in pairs(extra or {}) do
          lines[#lines + 1] = k .. ": " .. v
        end
        lines[#lines + 1] = "Content-Length: " .. #(out or "")
        client:write(table.concat(lines, "\r\n") .. "\r\n\r\n" .. (out or ""), function()
          if not client:is_closing() then
            client:close()
          end
        end)
      end)
    end)
  end)
  return self
end

function M:stop()
  if self.server and not self.server:is_closing() then
    self.server:close()
  end
end

--- Point the extension at this server.
function M:install()
  local gcal = require("org.extensions.gcal")
  local oauth = require("org.extensions.gcal.oauth")
  self.saved = { api = gcal.API, auth = oauth.AUTH_URL, token = oauth.TOKEN_URL }
  gcal.API = self.base .. "/calendar/v3"
  oauth.AUTH_URL = self.base .. "/o/oauth2/v2/auth"
  oauth.TOKEN_URL = self.base .. "/token"
end

function M:uninstall()
  if self.saved then
    local gcal = require("org.extensions.gcal")
    local oauth = require("org.extensions.gcal.oauth")
    gcal.API, oauth.AUTH_URL, oauth.TOKEN_URL = self.saved.api, self.saved.auth, self.saved.token
  end
end

function M:calendar(id, zone)
  self.calendars[id] = self.calendars[id] or { events = {}, order = {}, zone = zone or "UTC" }
  return self.calendars[id]
end

local function bump(self, ev)
  self.seq = self.seq + 1
  self.etag_n = self.etag_n + 1
  ev.etag = '"' .. self.etag_n .. '"'
  ev._seq = self.seq
  ev.updated = epoch_to_utc(os.time())
end

--- Add or replace an event (as if changed on Google).
function M:put(cal_id, ev)
  local cal = self:calendar(cal_id)
  ev = vim.deepcopy(ev)
  ev.status = ev.status or "confirmed"
  ev.htmlLink = ev.htmlLink or ("https://calendar.example/event?eid=" .. ev.id)
  if not cal.events[ev.id] then
    cal.order[#cal.order + 1] = ev.id
  end
  cal.events[ev.id] = ev
  bump(self, ev)
  return ev
end

--- Delete an event on the server side.
function M:remove(cal_id, id, forget)
  local cal = self:calendar(cal_id)
  local ev = cal.events[id]
  if ev then
    if forget then
      cal.events[id] = nil
    else
      ev.status = "cancelled"
      bump(self, ev)
    end
  end
end

--- Grant a token pair without the consent flow.
function M:grant(access, refresh)
  self.tokens[access] = true
  if refresh then
    self.refresh[refresh] = true
  end
end

local function public(ev)
  local out = {}
  for k, v in pairs(ev) do
    if k:sub(1, 1) ~= "_" then
      out[k] = v
    end
  end
  return out
end

local function bounds(ev)
  local s = ev.start and (ev.start.dateTime or ev.start.date)
  local e = ev["end"] and (ev["end"].dateTime or ev["end"].date)
  return s and rfc3339_to_epoch(s), e and rfc3339_to_epoch(e)
end

local STEP = { DAILY = 86400, WEEKLY = 7 * 86400 }

-- instances of a recurring event (DAILY/WEEKLY, INTERVAL, COUNT only)
local function instances(ev, from, to)
  local rule = (ev.recurrence or {})[1] or ""
  local freq = rule:match("FREQ=(%u+)")
  local interval = tonumber(rule:match("INTERVAL=(%d+)")) or 1
  local count = tonumber(rule:match("COUNT=(%d+)")) or 400
  local step = STEP[freq]
  local out = {}
  if not step then
    return out
  end
  local s, e = bounds(ev)
  for k = 0, count - 1 do
    local st = s + k * step * interval
    local et = e + k * step * interval
    if st >= to then
      break
    end
    if et > from then
      local inst = public(ev)
      inst.recurrence = nil
      inst.recurringEventId = ev.id
      inst.id = ev.id .. "_" .. os.date("!%Y%m%dT%H%M%SZ", st)
      inst.start = { dateTime = epoch_to_utc(st), timeZone = ev.start.timeZone }
      inst["end"] = { dateTime = epoch_to_utc(et), timeZone = ev["end"].timeZone }
      inst.originalStartTime = inst.start
      out[#out + 1] = inst
    end
  end
  return out
end

local function err(status, msg, reason)
  return status, json({ error = { code = status, message = msg, errors = reason and { { reason = reason } } or nil } })
end

local function valid_times(ev)
  for _, k in ipairs({ "start", "end" }) do
    local t = ev[k]
    if type(t) ~= "table" or (t.date == nil) == (t.dateTime == nil) then
      return false, "Invalid " .. k .. " time."
    end
  end
  if ev.recurrence and ev.start.dateTime and not ev.start.timeZone then
    return false, "Missing time zone definition for start time."
  end
  return true
end

-- JSON merge (RFC 7396): null removes a field
local function merge(dst, src)
  for k, v in pairs(src) do
    if v == vim.NIL then
      dst[k] = nil
    elseif type(v) == "table" and not vim.islist(v) and next(v) ~= nil then
      dst[k] = type(dst[k]) == "table" and dst[k] or {}
      merge(dst[k], v)
    else
      dst[k] = v
    end
  end
end

local function decode(body)
  return vim.json.decode(body ~= "" and body or "{}", { luanil = { object = false } })
end

function M:handle(method, target, headers, body)
  local path, qs = target:match("^([^?]*)%??(.*)$")
  local q = parse_query(qs)
  self.log[#self.log + 1] = { method = method, path = path, query = q, headers = headers, body = body }
  if #self.fail_next > 0 then
    local status = table.remove(self.fail_next, 1)
    if status == 403 then
      return err(403, "Rate Limit Exceeded", "rateLimitExceeded")
    end
    return err(status, "try again")
  end

  -- consent page: redirects straight back with a code (the user agreed)
  if method == "GET" and path == "/o/oauth2/v2/auth" then
    local code = "code-" .. (#self.log)
    self.codes[code] = { challenge = q.code_challenge, redirect_uri = q.redirect_uri, method = q.code_challenge_method }
    return 302, "", { Location = q.redirect_uri .. "/?code=" .. code .. "&state=" .. q.state }
  end
  if method == "POST" and path == "/token" then
    local f = parse_query(body)
    if f.grant_type == "authorization_code" then
      local c = self.codes[f.code]
      if not c or c.method ~= "S256" or challenge_of(f.code_verifier or "") ~= c.challenge then
        return 400, json({ error = "invalid_grant" })
      end
      if f.redirect_uri ~= c.redirect_uri then
        return 400, json({ error = "redirect_uri_mismatch" })
      end
      self.codes[f.code] = nil
      local a, r = "access-" .. #self.log, "refresh-" .. #self.log
      self:grant(a, r)
      return 200, json({ access_token = a, refresh_token = r, expires_in = 3599, token_type = "Bearer" })
    elseif f.grant_type == "refresh_token" then
      if not self.refresh[f.refresh_token] then
        return 400, json({ error = "invalid_grant" })
      end
      local a = "access-" .. #self.log
      self:grant(a)
      return 200, json({ access_token = a, expires_in = 3599, token_type = "Bearer" })
    end
    return 400, json({ error = "unsupported_grant_type" })
  end

  local token = (headers.authorization or ""):match("^Bearer (.+)$")
  if not token or not self.tokens[token] then
    return err(401, "Invalid Credentials")
  end
  local cal_id, rest = path:match("^/calendar/v3/calendars/([^/]+)/events(.*)$")
  if not cal_id then
    return err(404, "Not Found")
  end
  cal_id = urldecode(cal_id)
  local cal = self:calendar(cal_id)
  local ev_id, sub = rest:match("^/([^/]+)(.*)$")
  ev_id = ev_id and urldecode(ev_id)

  if method == "GET" and not ev_id then
    local items = {}
    local base_seq = 0
    if q.syncToken then
      base_seq = tonumber(q.syncToken:match("^sync%-(%d+)$") or "-1")
      if base_seq < self.min_sync then
        return err(410, "Sync token is no longer valid, a full sync is required.")
      end
      if q.timeMin or q.timeMax then
        return err(400, "timeMin and syncToken can't be combined")
      end
    end
    local from = q.timeMin and rfc3339_to_epoch(q.timeMin) or -math.huge
    local to = q.timeMax and rfc3339_to_epoch(q.timeMax) or math.huge
    for _, id in ipairs(cal.order) do
      local ev = cal.events[id]
      if ev then
        local changed = ev._seq > base_seq
        if q.syncToken then
          if changed then
            if ev.recurrence and q.singleEvents == "true" then
              vim.list_extend(items, instances(ev, os.time() - 400 * 86400, os.time() + 400 * 86400))
            else
              items[#items + 1] = public(ev)
            end
          end
        elseif ev.status ~= "cancelled" or q.showDeleted == "true" then
          if ev.recurrence and q.singleEvents == "true" then
            vim.list_extend(items, instances(ev, from, to))
          else
            local s, e = bounds(ev)
            if s and e and e > from and s < to then
              items[#items + 1] = public(ev)
            end
          end
        end
      end
    end
    local start = tonumber(q.pageToken and q.pageToken:match("^page%-(%d+)$") or "0")
    local page = vim.list_slice(items, start + 1, start + self.page_size)
    local resp = { kind = "calendar#events", timeZone = cal.zone, items = page }
    if start + self.page_size < #items then
      resp.nextPageToken = "page-" .. (start + self.page_size)
    else
      resp.nextSyncToken = "sync-" .. self.seq
    end
    return 200, json(resp)
  end

  if method == "POST" and not ev_id then
    local ev = {}
    merge(ev, decode(body)) -- drops the nulls
    local okv, msg = valid_times(ev)
    if not okv then
      return err(400, msg)
    end
    ev.id = "srv" .. (self.etag_n + 1)
    return 200, json(public(self:put(cal_id, ev)))
  end

  local ev = ev_id and cal.events[ev_id]
  if ev_id and sub == "/instances" and method == "GET" then
    if not ev then
      return err(404, "Not Found")
    end
    local from = q.timeMin and rfc3339_to_epoch(q.timeMin) or -math.huge
    local to = q.timeMax and rfc3339_to_epoch(q.timeMax) or math.huge
    return 200, json({ kind = "calendar#events", timeZone = cal.zone, items = instances(ev, from, to) })
  end
  if not ev then
    return err(404, "Not Found")
  end
  if method == "GET" then
    return 200, json(public(ev))
  end
  if headers["if-match"] and headers["if-match"] ~= ev.etag then
    return err(412, "Precondition Failed")
  end
  if method == "PATCH" then
    local new = vim.deepcopy(ev)
    merge(new, decode(body))
    local okv, msg = valid_times(new)
    if not okv then
      return err(400, msg)
    end
    return 200, json(public(self:put(cal_id, new)))
  end
  if method == "DELETE" then
    if ev.status == "cancelled" then
      return err(410, "Resource has been deleted")
    end
    self:remove(cal_id, ev_id)
    return 204, ""
  end
  return err(405, "Method Not Allowed")
end

--- Requests matching method and a Lua pattern on the path.
function M:requests(method, pattern)
  local out = {}
  for _, r in ipairs(self.log) do
    if (not method or r.method == method) and (not pattern or r.path:find(pattern)) then
      out[#out + 1] = r
    end
  end
  return out
end

return M
