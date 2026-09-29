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
  --- Mark entries of cancelled events with `cancelled_todo_keyword` when it
  --- is a TODO keyword of the file (org-gcal-update-cancelled-events-with-todo).
  update_cancelled_events_with_todo = true,
  cancelled_todo_keyword = "CANCELLED",
  --- Also offer to remove entries already marked cancelled
  --- (org-gcal-remove-events-with-cancelled-todo).
  remove_events_with_cancelled_todo = false,
  --- `org-gcal-managed` of fetched, updated and posted entries: "gcal"
  --- (Google is the source; sync overwrites the entry) or "org" (the entry
  --- is the source; sync pushes it).
  managed_newly_fetched_mode = "gcal",
  managed_update_existing_mode = "gcal",
  managed_create_from_entry_mode = "org",
  --- Posting an entry managed by Google: "prompt" asks (syncs never push
  --- it), "prompt_sync" asks during syncs too, "never_push", "always_push"
  --- (org-gcal-managed-post-at-point-update-existing).
  managed_post_at_point_update_existing = "prompt",
  --- Instances of recurring events: "top_level" entries in the fetch file, or
  --- "nested" under an entry for the recurring event (org-gcal-recurring-events-mode).
  recurring_events_mode = "top_level",
  --- Archive entries of events that ended before the fetch window, before
  --- each fetch (org-gcal-auto-archive).
  auto_archive = false,
  --- Report what each fetch or post did (org-gcal-notify-p).
  notify = true,
  --- Functions `fun(event): boolean`; an event any of them rejects is not
  --- fetched (org-gcal-fetch-event-filters).
  fetch_event_filters = {},
  --- Strip HTML from descriptions (org-gcal-strip-html-descriptions), and
  --- per-calendar overrides: `{ ["cal@group.calendar.google.com"] = false }`.
  strip_html_descriptions = false,
  strip_html_descriptions_overrides = {},
  --- Called after an entry is written from an event:
  --- `fun(calendar_id, event, mode, { bufnr, lnum })` with mode
  --- "newly_fetched", "update_existing" or "create_from_entry"
  --- (org-gcal-after-update-entry-functions). `User OrgGcalEntryUpdated`
  --- fires too.
  after_update_entry = nil,
  --- Names of the properties and the drawer (org-gcal-*-property,
  --- org-gcal-drawer-name).
  entry_id_property = "entry-id",
  calendar_id_property = "calendar-id",
  etag_property = "ETag",
  managed_property = "org-gcal-managed",
  drawer_name = "org-gcal",
  --- "local": times are shown in local time; "event": in each event's own
  --- zone (kept in a TIMEZONE property and used when posting back).
  time_zone = "local",
  --- IANA zone for local time and for `timeZone` of posted events
  --- (org-gcal-local-timezone); nil uses the system zone.
  local_timezone = nil,
  --- Fixed offset from UTC in minutes instead of a zone.
  utc_offset = nil,
  --- Minutes a posted event lasts when its timestamp has no end time; the
  --- entry's Effort is used when longer (org-gcal-event-default-duration).
  default_duration = 5,
  --- Transparency of new events (org-gcal-default-transparency).
  default_transparency = "opaque",
  --- Seconds after a full fetch before the next one; incremental fetches
  --- in between (the window follows today).
  sync_token_ttl = 86400,
  --- Waits (ms) before retrying a request that hit a rate limit or a
  --- server error.
  retry_delays = { 1000, 2000, 4000 },
  --- Seconds to wait for the consent page.
  auth_timeout = 300,
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
  gcal_post_at_point = action("post_at_point", "Create or update the event of the entry at point (org or agenda)"),
  gcal_delete_at_point = action(
    "delete_at_point",
    "Delete the event of the entry at point (count: clear the entry even if the delete fails)"
  ),
  gcal_sync_tokens_clear = action("sync_tokens_clear", "Forget the sync tokens: the next fetch is a full one"),
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
    -- data-raw: a body starting with @ is not read as a file name
    lines[#lines + 1] = "data-raw = " .. curl_quote(req.body)
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
  local refreshed, retries = false, 0
  local delays = opts.retry_delays or {}
  while true do
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
    local ok, data = pcall(vim.json.decode, resp.body ~= "" and resp.body or "null", { luanil = { object = true } })
    resp.json = ok and type(data) == "table" and data or nil
    if resp.status == 401 and not refreshed then
      refreshed = true
      token, terr = oauth.refresh(opts)
      if not token then
        return nil, terr
      end
    elseif M.retryable(resp) and retries < #delays then
      retries = retries + 1
      local ms = delays[retries]
      require("org.utils").await(function(cb)
        vim.defer_fn(cb, ms)
      end)
    else
      return resp
    end
  end
end

--- Rate limits (429, 403 rateLimitExceeded) and server errors are retried.
function M.retryable(resp)
  local s = resp.status
  if s == 429 or s == 500 or s == 502 or s == 503 or s == 504 then
    return true
  end
  if s == 403 and resp.json and type(resp.json.error) == "table" then
    for _, e in ipairs(resp.json.error.errors or {}) do
      if e.reason == "rateLimitExceeded" or e.reason == "userRateLimitExceeded" then
        return true
      end
    end
  end
  return false
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
  local ok, err = require("org.extensions.gcal.sync").post({ bufnr = 0 })
  return report(ok, err)
end

function M.delete_at_point()
  local force = vim.v.count > 0
  return report(require("org.extensions.gcal.sync").delete({ bufnr = 0 }, force))
end

function M.sync_tokens_clear()
  local opts = M.opts()
  local state = oauth.load(opts)
  state.sync_tokens = {}
  if vim.uv.fs_stat(oauth.token_path(opts)) then
    oauth.save(opts, state)
  end
  notify("sync tokens cleared")
  return true
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
  local tz = require("org.extensions.gcal.tz")
  if opts.utc_offset then
    h.info(string.format("gcal: times use a fixed UTC offset of %d minutes", opts.utc_offset))
  elseif opts.local_timezone then
    if tz.load(opts.local_timezone) then
      h.ok("gcal: local_timezone " .. opts.local_timezone)
    else
      h.warn("gcal: local_timezone " .. opts.local_timezone .. " not found in the zone files; the system zone is used")
    end
  else
    local sys = tz.system_zone()
    if sys and tz.load(sys) then
      h.ok("gcal: system time zone " .. sys)
    else
      h.warn("gcal: can't tell the system's IANA time zone", {
        "Set extensions.gcal.local_timezone (needed to post repeating events)",
      })
    end
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
