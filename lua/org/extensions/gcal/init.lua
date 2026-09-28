---@mod org.extensions.gcal Google Calendar sync (org-gcal)
---
--- Two-way sync between Google Calendar and Org files in the format of the
--- Emacs org-gcal package. Enable with
--- `extensions = { gcal = { client_id = ..., client_secret = ..., fetch_file_alist = { ... } } }`,
--- authorize once with `:Org gcal_auth`, then `:Org gcal_fetch` or
--- `:Org gcal_sync`. See `:h org-extensions-gcal`.
---
--- Network requests go through `M._request(req, cb)`, which runs `curl`
--- with its options on stdin (so tokens never appear in the process list).
--- Tests replace it.

local M = {}

M.defaults = {
  --- OAuth client ID of a "Desktop app" client (Google Cloud console).
  client_id = nil,
  --- Its client secret: a string, or a function returning it.
  client_secret = nil,
  --- Calendar ID -> org file receiving its events (org-gcal-fetch-file-alist).
  fetch_file_alist = {},
  --- Days before / after today to fetch (org-gcal-up-days / down-days).
  up_days = 30,
  down_days = 60,
  --- OAuth tokens and calendar sync tokens (written with mode 0600).
  token_file = vim.fn.stdpath("data") .. "/org/gcal-token.json",
  --- Events cancelled on the server: false keeps the entry, "ask" asks,
  --- true removes it (org-gcal-remove-api-cancelled-events).
  remove_api_cancelled_events = "ask",
  --- Kept entries of cancelled events get this TODO keyword (false: none;
  --- org-gcal-update-cancelled-events-with-todo / cancelled-todo-keyword).
  cancelled_todo_keyword = "CANCELLED",
  --- `org-gcal-managed` of fetched, updated and posted entries: "gcal"
  --- (Google is the source; sync overwrites the entry) or "org" (the entry
  --- is the source; sync pushes it).
  managed_newly_fetched_mode = "gcal",
  managed_update_existing_mode = "gcal",
  managed_create_from_entry_mode = "org",
  --- Archive entries of events that ended before the fetch window
  --- (org-gcal-auto-archive).
  auto_archive = false,
  --- Report what each fetch or post did.
  notify = true,
  --- IANA zone sent as `timeZone` with posted timed events (org-gcal-local-timezone).
  local_timezone = nil,
  --- Fixed offset from UTC in minutes for converting times; nil uses the system zone.
  utc_offset = nil,
  --- Minutes a posted event lasts when its timestamp has no end time.
  default_duration = 0,
  --- curl executable.
  curl = "curl",
  --- Seconds before a request is abandoned.
  timeout = 60,
}

local function action(fn, desc)
  return { "org.extensions.gcal", fn, desc = desc, global = true }
end

M.actions = {
  gcal_auth = action("auth", "Authorize Google Calendar access"),
  gcal_logout = action("logout", "Forget the Google Calendar tokens"),
  gcal_fetch = action("fetch", "Fetch Google Calendar events into the fetch files"),
  gcal_sync = action("sync", "Fetch events and push entries managed by org"),
  gcal_fetch_buffer = action("fetch_buffer", "Update the buffer's events from Google Calendar"),
  gcal_sync_buffer = action("sync_buffer", "Sync the buffer's events with Google Calendar"),
  gcal_post_at_point = action("post_at_point", "Create or update the event of the entry at point"),
  gcal_delete_at_point = action("delete_at_point", "Delete the event of the entry at point"),
}

---@return table
function M.opts()
  return require("org.extensions").opts("gcal") or vim.deepcopy(M.defaults)
end

--- Seconds since the epoch (replaceable in tests).
function M.now()
  return os.time()
end

---------------------------------------------------------------------------
-- Transport
---------------------------------------------------------------------------

local function curl_quote(s)
  s = tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
  return '"' .. s .. '"'
end

--- The curl config (read from stdin) for a request.
---@param req table
---@return string
function M.curl_config(req)
  local opts = M.opts()
  local lines = {
    "silent",
    "show-error",
    "url = " .. curl_quote(req.url),
    "request = " .. curl_quote(req.method or "GET"),
    "max-time = " .. tostring(opts.timeout or 60),
    'write-out = "\\n%{http_code}"',
  }
  local names = vim.tbl_keys(req.headers or {})
  table.sort(names)
  for _, name in ipairs(names) do
    lines[#lines + 1] = "header = " .. curl_quote(name .. ": " .. req.headers[name])
  end
  if req.body then
    lines[#lines + 1] = "data-binary = " .. curl_quote(req.body)
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Send `req` = { method, url, headers?, body? } and call `cb(resp)` with
--- { status, body } or `cb(nil, err)`. Replaced in tests.
---@param req table
---@param cb fun(resp: table|nil, err?: string)
function M._request(req, cb)
  local opts = M.opts()
  local ok, err = pcall(vim.system, { opts.curl or "curl", "--config", "-" }, {
    stdin = M.curl_config(req),
    text = true,
  }, function(res)
    if res.code ~= 0 then
      cb(nil, "curl failed: " .. vim.trim(res.stderr or ("exit " .. res.code)))
      return
    end
    local out = res.stdout or ""
    local body, status = out:match("^(.*)\n(%d%d%d)$")
    if not status then
      cb(nil, "unexpected curl output")
      return
    end
    cb({ status = tonumber(status), body = body })
  end)
  if not ok then
    cb(nil, tostring(err))
  end
end

--- `M._request` awaited from a coroutine.
---@return table|nil resp, string? err
function M.await_request(req)
  return require("org.utils").await(function(cb)
    M._request(req, cb)
  end)
end

---------------------------------------------------------------------------
-- Calendar API
---------------------------------------------------------------------------

M.API = "https://www.googleapis.com/calendar/v3"

local oauth = require("org.extensions.gcal.oauth")

--- Path of a calendar's events collection or one event.
function M.events_url(calendar_id, event_id)
  local url = M.API .. "/calendars/" .. oauth.urlencode(calendar_id) .. "/events"
  if event_id then
    url = url .. "/" .. oauth.urlencode(event_id)
  end
  return url
end

--- An authorized Calendar API request (inside a coroutine). Refreshes the
--- access token when it expired and once more on a 401.
---@param req { method?: string, url: string, query?: table, json?: table, headers?: table }
---@return table|nil resp { status, body, json }, string? err
function M.api(req)
  local opts = M.opts()
  local url = req.url
  if req.query and next(req.query) then
    url = url .. "?" .. oauth.form(req.query)
  end
  local token, terr = oauth.access_token(opts)
  if not token then
    return nil, terr
  end
  local resp, err
  for attempt = 1, 2 do
    local headers = vim.tbl_extend("force", { Authorization = "Bearer " .. token }, req.headers or {})
    local body
    if req.json then
      headers["Content-Type"] = "application/json"
      body = vim.json.encode(req.json)
    end
    resp, err = M.await_request({ method = req.method or "GET", url = url, headers = headers, body = body })
    if not resp then
      return nil, oauth.redact(err)
    end
    if resp.status ~= 401 or attempt == 2 then
      break
    end
    token, terr = oauth.refresh(opts)
    if not token then
      return nil, terr
    end
  end
  local ok, data = pcall(vim.json.decode, resp.body ~= "" and resp.body or "null", { luanil = { object = true } })
  resp.json = ok and type(data) == "table" and data or nil
  return resp
end

--- A readable error for a failed API response.
function M.api_error(resp)
  local msg = resp.json and resp.json.error and (resp.json.error.message or resp.json.error) or resp.body
  return oauth.redact(string.format("HTTP %s: %s", resp.status, type(msg) == "string" and msg or vim.inspect(msg)))
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local function notify(msg, level)
  require("org.utils").notify("org gcal: " .. oauth.redact(msg), level)
end
M.notify = notify

local function report(ok, err)
  if not ok and err then
    notify(err, vim.log.levels.ERROR)
  end
  return true
end

function M.auth()
  local ok, err = oauth.authorize(M.opts())
  if ok then
    notify("authorized")
  end
  return report(ok, err)
end

function M.logout()
  local path = oauth.token_path(M.opts())
  if vim.uv.fs_stat(path) then
    os.remove(path)
  end
  notify("tokens removed")
  return true
end

function M.fetch()
  return report(require("org.extensions.gcal.sync").run({ push = false }))
end

function M.sync()
  return report(require("org.extensions.gcal.sync").run({ push = true }))
end

function M.fetch_buffer()
  return report(require("org.extensions.gcal.sync").buffer(0, { push = false }))
end

function M.sync_buffer()
  return report(require("org.extensions.gcal.sync").buffer(0, { push = true }))
end

function M.post_at_point()
  return report(require("org.extensions.gcal.sync").post({ bufnr = 0 }))
end

function M.delete_at_point()
  return report(require("org.extensions.gcal.sync").delete({ bufnr = 0 }))
end

---------------------------------------------------------------------------
-- Health
---------------------------------------------------------------------------

function M.health(h, opts)
  local curl = opts.curl or "curl"
  if vim.fn.executable(curl) == 1 then
    h.ok("gcal: curl found")
  else
    h.error("gcal: curl not found: " .. curl)
  end
  if opts.client_id and opts.client_id ~= "" then
    h.ok("gcal: client_id configured")
  else
    h.error("gcal: client_id is not set", { "See :h org-extensions-gcal to create an OAuth client" })
  end
  if not oauth.client_secret(opts) then
    h.warn("gcal: client_secret is not set (Google requires it for Desktop clients)")
  end
  local state = oauth.load(opts)
  if state.refresh_token then
    local left = (tonumber(state.expires_at) or 0) - M.now()
    local note = left > 0 and string.format(" (access token valid for %d min)", math.floor(left / 60))
      or " (access token will be refreshed)"
    h.ok("gcal: authorized" .. note)
  else
    h.warn("gcal: not authorized", { "Run :Org gcal_auth" })
  end
  local path = oauth.token_path(opts)
  local st = vim.uv.fs_stat(path)
  if st and bit.band(st.mode, tonumber("077", 8)) ~= 0 then
    h.warn("gcal: token file is readable by others: " .. path, { "chmod 600 " .. path })
  end
  local utils = require("org.utils")
  if vim.tbl_isempty(opts.fetch_file_alist or {}) then
    h.warn("gcal: fetch_file_alist is empty; nothing will be fetched")
  end
  for cal, file in pairs(opts.fetch_file_alist or {}) do
    local path = utils.expand(file)
    if utils.exists(path) then
      h.ok(string.format("gcal: %s -> %s", cal, path))
    else
      h.info(string.format("gcal: %s -> %s (created on first fetch)", cal, path))
    end
  end
end

return M
