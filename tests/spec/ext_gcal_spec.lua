-- The gcal extension against a stubbed transport: no request leaves the
-- process and no real token is used.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local CAL = "cal@example.com"
-- 2026-09-28 12:00 UTC: the clock the extension sees in these specs
local NOW = require("org.date").days_from_civil(2026, 9, 28) * 86400 + 12 * 3600

local tmp, gcal, oauth, event, sync, requests, routes

local function setup(extra, top)
  require("org").setup(vim.tbl_extend("force", {
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
    extensions = {
      gcal = vim.tbl_extend("force", {
        client_id = "cid.apps.googleusercontent.com",
        client_secret = "csecret-value",
        token_file = tmp .. "/gcal-token.json",
        fetch_file_alist = { [CAL] = tmp .. "/cal.org" },
        utc_offset = 0,
        remove_api_cancelled_events = true,
        notify = false,
        retry_delays = { 0, 0, 0 },
      }, extra or {}),
    },
  }, top or {}))
end

--- Answer requests matching `method` and a Lua pattern on the URL.
local function route(method, pattern, handler)
  table.insert(routes, 1, { method = method, pattern = pattern, handler = handler })
end

local function stub_transport()
  gcal._request = function(req, cb)
    requests[#requests + 1] = req
    for _, r in ipairs(routes) do
      if r.method == req.method and req.url:find(r.pattern) then
        local status, body = r.handler(req)
        cb({ status = status, body = type(body) == "table" and vim.json.encode(body) or body or "" })
        return
      end
    end
    cb({ status = 599, body = "no route for " .. req.method .. " " .. req.url })
  end
end

--- Run `fn` in a coroutine and wait for it.
local function run(fn)
  local done, res = false, nil
  require("org.utils").run(function()
    res = { fn() }
    done = true
  end)
  vim.wait(5000, function()
    return done
  end, 5)
  ok(done, "coroutine did not finish")
  return unpack(res)
end

local function query_of(url)
  return oauth.parse_query(url:match("%?(.*)$") or "")
end

local function read(path)
  return vim.fn.readfile(path)
end

local function has_line(lines, pat)
  for _, l in ipairs(lines) do
    if l:find(pat) then
      return true
    end
  end
  return false
end

local function ev(id, over)
  return vim.tbl_extend("force", {
    id = id,
    etag = '"etag-' .. id .. '"',
    status = "confirmed",
    summary = "Event " .. id,
    htmlLink = "https://calendar.google.com/event?eid=" .. id,
    start = { dateTime = "2026-09-28T10:00:00Z" },
    ["end"] = { dateTime = "2026-09-28T11:00:00Z" },
  }, over or {})
end

local function valid_tokens()
  oauth.save(gcal.opts(), {
    access_token = "access-token-1",
    refresh_token = "refresh-token-1",
    expires_at = NOW + 3600,
    sync_tokens = {},
  })
end

describe("gcal extension", function()
  local saved_request, saved_confirm, saved_now
  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    requests, routes = {}, {}
    gcal = require("org.extensions.gcal")
    oauth = require("org.extensions.gcal.oauth")
    event = require("org.extensions.gcal.event")
    sync = require("org.extensions.gcal.sync")
    saved_request = gcal._request
    saved_confirm = require("org.utils").confirm
    saved_now = gcal.now
    gcal.now = function()
      return NOW
    end
    setup()
    stub_transport()
    valid_tokens()
  end)
  after_each(function()
    gcal._request = saved_request
    gcal.now = saved_now
    require("org.utils").confirm = saved_confirm
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find(tmp, 1, true) then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
    vim.fn.delete(tmp, "rf")
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      agenda_files = { root .. "/tests/fixtures/*.org" },
    })
  end)

  describe("event -> org", function()
    it("formats a timed event", function()
      eq("<2026-09-28 Mon 10:00-11:00>", event.timestamp({ utc_offset = 0 }, ev("a")))
    end)

    it("converts time zones and splits events across days into a range", function()
      local e = ev("a", {
        start = { dateTime = "2026-09-28T10:00:00-07:00" },
        ["end"] = { dateTime = "2026-09-28T16:00:00-07:00" },
      })
      eq("<2026-09-28 Mon 19:00>--<2026-09-29 Tue 01:00>", event.timestamp({ utc_offset = 120 }, e))
      eq("<2026-09-28 Mon 17:00-23:00>", event.timestamp({ utc_offset = 0 }, e))
    end)

    it("formats all-day and multi-day events (the end date is exclusive)", function()
      local one = ev("a", { start = { date = "2026-09-28" }, ["end"] = { date = "2026-09-29" } })
      eq("<2026-09-28 Mon>", event.timestamp({}, one))
      local three = ev("a", { start = { date = "2026-09-28" }, ["end"] = { date = "2026-10-01" } })
      eq("<2026-09-28 Mon>--<2026-09-30 Wed>", event.timestamp({}, three))
    end)

    it("keeps description lines from becoming headlines or ending the drawer", function()
      local lines = event.description_lines("* not a heading\n:END:\nplain\n")
      eq({ "✱ not a heading", ",:END:", "plain" }, lines)
      eq("* not a heading\n:END:\nplain", event.description_text(lines))
    end)

    it("writes a new entry in org-gcal's format", function()
      route("GET", "/events", function()
        return 200,
          {
            items = {
              ev("a", {
                location = "Room 1\nSecond floor",
                description = "Agenda",
                hangoutLink = "https://meet.example/abc",
                source = { url = "https://example.com/doc", title = "Doc" },
                transparency = "transparent",
              }),
            },
            nextSyncToken = "s",
          }
      end)
      local okx, err = run(function()
        return sync.run({ push = false })
      end)
      ok(okx, err)
      local lines = read(tmp .. "/cal.org")
      eq("* Event a", lines[1])
      ok(has_line(lines, '^:ETag:%s+"etag%-a"$'))
      ok(has_line(lines, "^:LOCATION: Room 1, Second floor$"))
      ok(has_line(lines, "^:calendar%-id: cal@example%.com$"))
      ok(has_line(lines, "^:entry%-id: a/cal@example%.com$"))
      ok(has_line(lines, "^:org%-gcal%-managed: gcal$"))
      ok(has_line(lines, "^:TRANSPARENCY: transparent$"))
      ok(has_line(lines, "^:HANGOUTS:%s+%[%[https://meet%.example/abc%]%[Join Hangouts Meet%]%]$"))
      ok(has_line(lines, "^:link:%s+%[%[https://example%.com/doc%]%[Doc%]%]$"), table.concat(lines, "\n"))
      -- org-gcal reads `link` back as the event's source: the web page
      -- link must not end up there
      ok(not has_line(lines, "calendar%.google%.com"), table.concat(lines, "\n"))
      local d = vim.fn.index(lines, ":org-gcal:") + 1
      eq({ ":org-gcal:", "<2026-09-28 Mon 10:00-11:00>", "", "Agenda", ":END:" }, vim.list_slice(lines, d, d + 4))
    end)

    it("keeps a source without a title in ROAM_REFS, like org-gcal", function()
      local props = event.properties({}, CAL, ev("a", { source = { url = "https://example.com/x" } }), {})
      local found
      for _, p in ipairs(props) do
        if p.name == "ROAM_REFS" then
          found = p.value
        end
      end
      eq("https://example.com/x", found)
    end)

    it("strips HTML from descriptions when asked, per calendar", function()
      local html = "<b>Hi</b> &amp; welcome<br>line two<ul><li>one</li><li>two</li></ul>"
      eq("Hi & welcome\nline two\n- one\n- two", event.strip_html(html))
      local opts = { strip_html_descriptions = true, strip_html_descriptions_overrides = { other = false } }
      eq("Hi", event.description(opts, CAL, { description = "<p>Hi</p>" }))
      eq("<p>Hi</p>", event.description(opts, "other", { description = "<p>Hi</p>" }))
      eq("<p>Hi</p>", event.description({}, CAL, { description = "<p>Hi</p>" }))
    end)

    it("shows times in the event's own zone with time_zone = event", function()
      local e = ev("a", {
        start = { dateTime = "2026-09-28T16:00:00Z", timeZone = "America/New_York" },
        ["end"] = { dateTime = "2026-09-28T17:00:00Z", timeZone = "America/New_York" },
      })
      eq("<2026-09-28 Mon 12:00-13:00>", event.timestamp({ time_zone = "event", utc_offset = 0 }, e))
      eq("<2026-09-28 Mon 16:00-17:00>", event.timestamp({ utc_offset = 0 }, e))
      -- without a readable zone: the offset the API sent
      local f = ev("b", {
        start = { dateTime = "2026-09-28T09:00:00-03:00" },
        ["end"] = { dateTime = "2026-09-28T10:00:00-03:00" },
      })
      eq("<2026-09-28 Mon 09:00-10:00>", event.timestamp({ time_zone = "event", utc_offset = 0 }, f))
    end)

    it("uses busy for events without a title", function()
      eq("busy", event.title({ summary = "" }))
    end)
  end)

  describe("org -> event", function()
    local date = require("org.date")

    it("builds timed start and end in local_timezone, across DST", function()
      local opts = { local_timezone = "America/Chicago" }
      local s, e = event.times(opts, date.parse("<2026-09-28 Mon 10:00-11:30>"))
      -- the other field is a JSON null so a PATCH can switch kinds
      eq({ dateTime = "2026-09-28T10:00:00-05:00", date = vim.NIL, timeZone = "America/Chicago" }, s)
      eq({ dateTime = "2026-09-28T11:30:00-05:00", date = vim.NIL, timeZone = "America/Chicago" }, e)
      local w = event.times(opts, date.parse("<2026-12-01 Tue 10:00>"), nil, 30)
      eq("2026-12-01T10:00:00-06:00", w.dateTime)
    end)

    it("builds all-day events with an exclusive end date", function()
      local s, e = event.times({}, date.parse_all("<2026-09-28 Mon>--<2026-09-30 Wed>")[1].date)
      eq({ date = "2026-09-28", dateTime = vim.NIL }, s)
      eq({ date = "2026-10-01", dateTime = vim.NIL }, e)
    end)

    it("sends a zone for a fixed offset and gives a timestamp without end the default length", function()
      local s, e = event.times({ utc_offset = 120, default_duration = 5 }, date.parse("<2026-09-28 Mon 10:00>"))
      eq("Etc/GMT-2", s.timeZone)
      eq("2026-09-28T10:05:00+02:00", e.dateTime)
    end)

    it("turns an org repeater into an RRULE and keeps other recurrence lines", function()
      local body = event.to_event({ utc_offset = 0 }, {
        title = "Standup",
        timestamp = date.parse("<2026-09-28 Mon 09:00-09:15 +1w>"),
        recurrence = "[RRULE:FREQ=DAILY EXDATE;TZID=UTC:20261005T090000]",
      })
      eq({ "RRULE:FREQ=WEEKLY;INTERVAL=1", "EXDATE;TZID=UTC:20261005T090000" }, body.recurrence)
      eq("UTC", body.start.timeZone)
      local _, err =
        event.to_event({ utc_offset = 0 }, { title = "x", timestamp = date.parse("<2026-09-28 Mon 09:00 +2h>") })
      ok(err and err:find("days or longer"), err)
    end)

    it("leaves a fetched recurring event's times alone when posting it", function()
      local body = event.to_event({}, { title = "Series", recurrence = "[RRULE:FREQ=WEEKLY;BYDAY=MO,WE]" })
      eq({ "RRULE:FREQ=WEEKLY;BYDAY=MO,WE" }, body.recurrence)
      eq(nil, body.start)
    end)

    it("posts the entry's link as the event source", function()
      local body = event.to_event({ utc_offset = 0 }, {
        title = "x",
        timestamp = date.parse("<2026-09-28 Mon>"),
        link = "[[https://example.com/p][Plan]]",
      })
      eq({ url = "https://example.com/p", title = "Plan" }, body.source)
      eq("opaque", event.to_event({ default_transparency = "opaque" }, {
        title = "x",
        timestamp = date.parse("<2026-09-28 Mon>"),
      }).transparency)
    end)

    it("round-trips RFC 3339 times", function()
      local t = event.parse_rfc3339("2026-09-28T10:00:00+02:00")
      eq(event.parse_rfc3339("2026-09-28T08:00:00Z"), t)
      eq("2026-09-28T09:00:00+01:00", event.format_rfc3339({ utc_offset = 60 }, t))
    end)
  end)

  describe("oauth", function()
    it("derives the RFC 7636 S256 challenge", function()
      local verifier, challenge = oauth.pkce("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
      eq("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", verifier)
      eq("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", challenge)
      local v2 = oauth.pkce()
      ok(#v2 >= 43 and v2:match("^[%w%-_]+$"), v2)
    end)

    it("builds the consent URL", function()
      local url = oauth.auth_url({
        client_id = "cid",
        redirect_uri = "http://127.0.0.1:5555",
        challenge = "chal",
        state = "st",
      })
      ok(url:find("^https://accounts%.google%.com/o/oauth2/v2/auth%?"))
      local q = query_of(url)
      eq("cid", q.client_id)
      eq("http://127.0.0.1:5555", q.redirect_uri)
      eq("code", q.response_type)
      eq("S256", q.code_challenge_method)
      eq("chal", q.code_challenge)
      eq("st", q.state)
      eq("offline", q.access_type)
      eq(oauth.SCOPE, q.scope)
    end)

    it("receives the code on the loopback listener", function()
      local got
      local redirect, close = oauth.listen(function(q, err)
        got = q or { err = err }
      end, 5000)
      ok(redirect and redirect:match("^http://127%.0%.0%.1:%d+$"), tostring(close))
      local port = tonumber(redirect:match(":(%d+)$"))
      local client = vim.uv.new_tcp()
      local reply = ""
      client:connect("127.0.0.1", port, function()
        client:write("GET /?code=the-code&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        client:read_start(function(_, chunk)
          if chunk then
            reply = reply .. chunk
          else
            client:close()
          end
        end)
      end)
      vim.wait(3000, function()
        return got ~= nil
      end, 10)
      eq({ code = "the-code", state = "xyz" }, got)
      vim.wait(1000, function()
        return reply:find("Authorization received", 1, true) ~= nil
      end, 10)
      ok(reply:find("^HTTP/1%.1 200"), reply)
    end)

    it("runs the consent flow against the local listener", function()
      local open = vim.ui.open
      local notify = vim.notify
      vim.notify = function() end
      -- play the browser: follow the redirect with a code and the state
      vim.ui.open = function(url)
        local q = query_of(url)
        local port = tonumber(q.redirect_uri:match(":(%d+)$"))
        local client = vim.uv.new_tcp()
        client:connect("127.0.0.1", port, function()
          client:write("GET /?code=granted&state=" .. oauth.urlencode(q.state) .. " HTTP/1.1\r\n\r\n")
          client:read_start(function(_, chunk)
            if not chunk then
              client:close()
            end
          end)
        end)
      end
      route("POST", "/token$", function(req)
        local q = oauth.parse_query(req.body)
        eq("granted", q.code)
        ok(q.redirect_uri:match("^http://127%.0%.0%.1:%d+$"), q.redirect_uri)
        local _, challenge = oauth.pkce(q.code_verifier)
        ok(#challenge == 43)
        return 200, { access_token = "flow-access", refresh_token = "flow-refresh", expires_in = 3600 }
      end)
      local okx, err = run(function()
        return oauth.authorize(gcal.opts())
      end)
      vim.ui.open = open
      vim.notify = notify
      ok(okx, err)
      eq("flow-refresh", oauth.load(gcal.opts()).refresh_token)
    end)

    it("exchanges the code with the verifier", function()
      route("POST", "oauth2%.googleapis%.com/token", function(req)
        local q = oauth.parse_query(req.body)
        eq("authorization_code", q.grant_type)
        eq("the-code", q.code)
        eq("the-verifier", q.code_verifier)
        eq("csecret-value", q.client_secret)
        return 200, { access_token = "new-access", refresh_token = "new-refresh", expires_in = 3599 }
      end)
      local okx, err = run(function()
        return oauth.exchange(gcal.opts(), "the-code", "the-verifier", "http://127.0.0.1:1")
      end)
      ok(okx, err)
      local state = oauth.load(gcal.opts())
      eq("new-access", state.access_token)
      eq("new-refresh", state.refresh_token)
    end)

    it("takes client_secret from a function", function()
      eq("from-fn", oauth.client_secret({ client_secret = function()
        return "from-fn\n"
      end }))
    end)

    it("writes the token file readable only by the user", function()
      local st = vim.uv.fs_stat(tmp .. "/gcal-token.json")
      eq(tonumber("600", 8), bit.band(st.mode, tonumber("777", 8)))
      vim.uv.fs_chmod(tmp .. "/gcal-token.json", tonumber("644", 8))
      valid_tokens()
      st = vim.uv.fs_stat(tmp .. "/gcal-token.json")
      eq(tonumber("600", 8), bit.band(st.mode, tonumber("777", 8)))
    end)

    it("redacts tokens, secrets and codes", function()
      oauth.remember_secret("super-secret-token-value")
      local msg = oauth.redact(
        'x super-secret-token-value {"access_token": "abc123", "refresh_token":"r1"} Bearer ya29.zzz'
          .. " code=4/xyz&state=1 client_secret=shh"
      )
      ok(not msg:find("super-secret-token-value", 1, true), msg)
      ok(not msg:find("abc123", 1, true), msg)
      ok(not msg:find('"r1"', 1, true), msg)
      ok(not msg:find("ya29", 1, true), msg)
      ok(not msg:find("4/xyz", 1, true), msg)
      ok(not msg:find("shh", 1, true), msg)
      ok(msg:find("state=1", 1, true), msg)
    end)

    it("sends requests through curl (to the local listener only)", function()
      if vim.fn.executable("curl") == 0 then
        return
      end
      local redirect = oauth.listen(function() end, 5000)
      local resp, err
      saved_request({
        method = "GET",
        url = redirect .. "/?code=c&state=s",
        headers = { Authorization = "Bearer local-test" },
      }, function(r, e)
        resp, err = r, e
      end)
      vim.wait(5000, function()
        return resp ~= nil or err ~= nil
      end, 10)
      ok(resp, err)
      eq(200, resp.status)
      ok(resp.body:find("Authorization received", 1, true), resp.body)
    end)

    it("keeps tokens out of the curl command line", function()
      local cfg = gcal.curl_config({
        method = "POST",
        url = "https://example.com/x",
        headers = { Authorization = "Bearer tok" },
        body = 'a "quoted"\nbody',
      })
      ok(cfg:find('header = "Authorization: Bearer tok"', 1, true), cfg)
      ok(cfg:find('data-raw = "a \\"quoted\\"\\nbody"', 1, true), cfg)
      ok(cfg:find('request = "POST"', 1, true), cfg)
    end)
  end)

  describe("requests", function()
    it("refreshes an expired access token first", function()
      local state = oauth.load(gcal.opts())
      state.expires_at = NOW - 10
      oauth.save(gcal.opts(), state)
      route("POST", "/token$", function(req)
        eq("refresh_token", oauth.parse_query(req.body).grant_type)
        eq("refresh-token-1", oauth.parse_query(req.body).refresh_token)
        return 200, { access_token = "access-token-2", expires_in = 3600 }
      end)
      route("GET", "/events", function(req)
        eq("Bearer access-token-2", req.headers.Authorization)
        return 200, { items = {}, nextSyncToken = "s1" }
      end)
      local okx, err = run(function()
        return sync.run({ push = false })
      end)
      ok(okx, err)
      eq("access-token-2", oauth.load(gcal.opts()).access_token)
      eq("refresh-token-1", oauth.load(gcal.opts()).refresh_token)
    end)

    it("refreshes and retries once on 401", function()
      local calls = 0
      route("POST", "/token$", function()
        return 200, { access_token = "access-token-3", expires_in = 3600 }
      end)
      route("GET", "/events", function(req)
        calls = calls + 1
        if req.headers.Authorization == "Bearer access-token-1" then
          return 401, { error = { message = "Invalid Credentials" } }
        end
        return 200, { items = {}, nextSyncToken = "s1" }
      end)
      local okx, err = run(function()
        return sync.run({ push = false })
      end)
      ok(okx, err)
      eq(2, calls)
    end)

    it("clears revoked tokens and says to authorize again", function()
      local state = oauth.load(gcal.opts())
      state.expires_at = 0
      oauth.save(gcal.opts(), state)
      route("POST", "/token$", function()
        return 400, { error = "invalid_grant" }
      end)
      local okx, err = run(function()
        return sync.run({ push = false })
      end)
      ok(not okx)
      ok(err:find("gcal_auth", 1, true), err)
      eq(nil, oauth.load(gcal.opts()).refresh_token)
    end)
  end)

  describe("fetch", function()
    it("does a windowed full sync with paging and stores the sync token", function()
      route("GET", "/calendars/cal%%40example%.com/events", function(req)
        local q = query_of(req.url)
        eq("true", q.singleEvents)
        ok(q.timeMin and q.timeMax, req.url)
        eq(nil, q.syncToken)
        if q.pageToken == "p2" then
          return 200, { items = { ev("b") }, nextSyncToken = "sync-1" }
        end
        return 200, { items = { ev("a") }, nextPageToken = "p2" }
      end)
      local okx, err = run(function()
        return sync.run({ push = false })
      end)
      ok(okx, err)
      eq(2, #requests)
      local lines = read(tmp .. "/cal.org")
      eq("* Event a", lines[1])
      ok(has_line(lines, "^%* Event b$"))
      ok(has_line(lines, "^:entry%-id: b/cal@example%.com$"))
      eq("sync-1", oauth.load(gcal.opts()).sync_tokens[CAL].token)
    end)

    it("syncs incrementally, updating entries in place and keeping the user's text", function()
      vim.fn.writefile({
        "* TODO Old title :work:",
        ":PROPERTIES:",
        ':ETag:     "old"',
        ":calendar-id: " .. CAL,
        ":entry-id: a/" .. CAL,
        ":MINE:     keep",
        ":END:",
        ":org-gcal:",
        "<2026-09-01 Tue 09:00-10:00>",
        ":END:",
        "My own notes.",
        "* Other",
        ":PROPERTIES:",
        ":entry-id: gone/" .. CAL,
        ":END:",
        "* Kept cancelled",
        ":PROPERTIES:",
        ":entry-id: c/" .. CAL,
        ":END:",
      }, tmp .. "/cal.org")
      local state = oauth.load(gcal.opts())
      state.sync_tokens[CAL] = { token = "sync-1", expires = NOW + 3600 }
      oauth.save(gcal.opts(), state)
      route("GET", "/events", function(req)
        eq("sync-1", query_of(req.url).syncToken)
        eq(nil, query_of(req.url).timeMin)
        return 200,
          {
            items = {
              ev("a", { summary = "New title", description = "Desc" }),
              { id = "gone", status = "cancelled" },
            },
            nextSyncToken = "sync-2",
          }
      end)
      local okx, err = run(function()
        return sync.run({ push = false })
      end)
      ok(okx, err)
      local lines = read(tmp .. "/cal.org")
      ok(lines[1]:match("^%* TODO New title%s+:work:$"), lines[1])
      ok(has_line(lines, '^:ETag:%s+"etag%-a"$'))
      ok(has_line(lines, "^:MINE:%s+keep$"))
      ok(has_line(lines, "^<2026%-09%-28 Mon 10:00%-11:00>$"))
      ok(not has_line(lines, "2026%-09%-01"))
      ok(has_line(lines, "^Desc$"))
      ok(has_line(lines, "^My own notes%.$"))
      ok(not has_line(lines, "^%* Other"), table.concat(lines, "\n"))
      ok(has_line(lines, "^%* Kept cancelled"))
      eq("sync-2", oauth.load(gcal.opts()).sync_tokens[CAL].token)
    end)

    it("marks cancelled entries with the TODO keyword when not removing them", function()
      setup({ remove_api_cancelled_events = false }, { todo_keywords = { "TODO | DONE CANCELLED" } })
      vim.fn.writefile({ "* Gone", ":PROPERTIES:", ":entry-id: gone/" .. CAL, ":END:" }, tmp .. "/cal.org")
      route("GET", "/events", function()
        return 200, { items = { { id = "gone", status = "cancelled" } }, nextSyncToken = "s" }
      end)
      local okx, err = run(function()
        return sync.run({ push = false })
      end)
      ok(okx, err)
      eq("* CANCELLED Gone", read(tmp .. "/cal.org")[1])
    end)

    it("does a full sync again when the sync token is gone (410)", function()
      local state = oauth.load(gcal.opts())
      state.sync_tokens[CAL] = { token = "stale", expires = NOW + 3600 }
      oauth.save(gcal.opts(), state)
      route("GET", "/events", function(req)
        if query_of(req.url).syncToken then
          return 410, { error = { message = "Sync token is no longer valid" } }
        end
        return 200, { items = { ev("a") }, nextSyncToken = "fresh" }
      end)
      local okx, err = run(function()
        return sync.run({ push = false })
      end)
      ok(okx, err)
      eq(2, #requests)
      ok(query_of(requests[2].url).timeMin)
      eq("fresh", oauth.load(gcal.opts()).sync_tokens[CAL].token)
      eq("* Event a", read(tmp .. "/cal.org")[1])
    end)

    it("pushes entries managed by org when syncing", function()
      vim.fn.writefile({
        "* Local title",
        ":PROPERTIES:",
        ':ETag:     "etag-a"',
        ":calendar-id: " .. CAL,
        ":entry-id: a/" .. CAL,
        ":org-gcal-managed: org",
        ":END:",
        ":org-gcal:",
        "<2026-09-28 Mon 12:00-13:00>",
        ":END:",
      }, tmp .. "/cal.org")
      route("GET", "/events", function()
        return 200, { items = { ev("a") }, nextSyncToken = "s" }
      end)
      route("PATCH", "/events/a$", function(req)
        local body = vim.json.decode(req.body)
        eq("Local title", body.summary)
        eq("2026-09-28T12:00:00+00:00", body.start.dateTime)
        return 200, ev("a", { summary = "Local title", etag = '"etag-a2"', start = body.start, ["end"] = body["end"] })
      end)
      local okx, err = run(function()
        return sync.run({ push = true })
      end)
      ok(okx, err)
      local lines = read(tmp .. "/cal.org")
      eq("* Local title", lines[1])
      ok(has_line(lines, '"etag%-a2"'))
      ok(has_line(lines, "^:org%-gcal%-managed: org$"))
    end)

    it("updates the buffer's entries one by one", function()
      vim.fn.writefile({ "* A", ":PROPERTIES:", ":entry-id: a/" .. CAL, ":END:" }, tmp .. "/other.org")
      local bufnr = require("org.utils").load_buffer(tmp .. "/other.org")
      route("GET", "/events/a$", function()
        return 200, ev("a", { summary = "From server" })
      end)
      local okx, err = run(function()
        return sync.buffer(bufnr, { push = false })
      end)
      ok(okx, err)
      eq("* From server", read(tmp .. "/other.org")[1])
    end)
  end)

  describe("post and delete", function()
    local function open(lines)
      vim.fn.writefile(lines, tmp .. "/cal.org")
      vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/cal.org"))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      return vim.api.nvim_get_current_buf()
    end

    it("creates an event from a SCHEDULED entry", function()
      open({ "* Dentist", "SCHEDULED: <2026-10-02 Fri 15:00-16:00>", "Bring the form." })
      route("POST", "/calendars/cal%%40example%.com/events$", function(req)
        local body = vim.json.decode(req.body)
        eq("Dentist", body.summary)
        eq({ dateTime = "2026-10-02T15:00:00+00:00", date = vim.NIL, timeZone = "UTC" }, body.start)
        eq({ dateTime = "2026-10-02T16:00:00+00:00", date = vim.NIL, timeZone = "UTC" }, body["end"])
        eq("opaque", body.transparency)
        return 200, ev("new1", { summary = "Dentist", start = body.start, ["end"] = body["end"] })
      end)
      local okx, err = run(function()
        return sync.post({ bufnr = 0 })
      end)
      ok(okx, err)
      local lines = read(tmp .. "/cal.org")
      eq("* Dentist", lines[1])
      eq("SCHEDULED: <2026-10-02 Fri 15:00-16:00>", lines[2])
      ok(has_line(lines, "^:entry%-id: new1/cal@example%.com$"))
      ok(has_line(lines, "^:org%-gcal%-managed: org$"))
      ok(has_line(lines, "^Bring the form%.$"))
      -- the time stays on SCHEDULED only, so the agenda shows it once
      local stamps = 0
      for _, l in ipairs(lines) do
        if l:find("<2026-10-02", 1, true) then
          stamps = stamps + 1
        end
      end
      eq(1, stamps)
    end)

    it("updates an event with If-Match and takes the server's version on 412", function()
      open({
        "* Mine",
        ":PROPERTIES:",
        ':ETag:     "stale"',
        ":calendar-id: " .. CAL,
        ":entry-id: a/" .. CAL,
        ":END:",
        ":org-gcal:",
        "<2026-09-28 Mon 10:00-11:00>",
        ":END:",
      })
      route("PATCH", "/events/a$", function(req)
        eq('"stale"', req.headers["If-Match"])
        return 412, { error = { message = "Precondition Failed" } }
      end)
      route("GET", "/events/a$", function()
        return 200, ev("a", { summary = "Server title" })
      end)
      local okx, err = run(function()
        return sync.post({ bufnr = 0 })
      end)
      ok(okx, err)
      local lines = read(tmp .. "/cal.org")
      eq("* Server title", lines[1])
      ok(has_line(lines, '"etag%-a"'))
    end)

    it("reports an entry without a timestamp", function()
      open({ "* No time" })
      local okx, err = run(function()
        return sync.post({ bufnr = 0 })
      end)
      ok(not okx)
      ok(err:find("timestamp", 1, true), err)
      eq(0, #requests)
    end)

    it("deletes the event and the entry after confirming", function()
      open({
        "* Doomed",
        ":PROPERTIES:",
        ':ETag:     "e1"',
        ":entry-id: a/" .. CAL,
        ":END:",
        "* Stays",
      })
      require("org.utils").confirm = function()
        return true
      end
      route("DELETE", "/events/a$", function(req)
        eq('"e1"', req.headers["If-Match"])
        return 204, ""
      end)
      local okx, err = run(function()
        return sync.delete({ bufnr = 0 })
      end)
      ok(okx, err)
      eq({ "* Stays" }, read(tmp .. "/cal.org"))
    end)

    it("does nothing when the delete is not confirmed", function()
      open({ "* Kept", ":PROPERTIES:", ":entry-id: a/" .. CAL, ":END:" })
      require("org.utils").confirm = function()
        return false
      end
      local okx = run(function()
        return sync.delete({ bufnr = 0 })
      end)
      ok(okx)
      eq(0, #requests)
    end)
  end)

  it("puts drawer timestamps in the entry's timestamps (agenda)", function()
    local file = require("org.parser").parse({
      "* Meeting",
      ":org-gcal:",
      "<2026-09-28 Mon 10:00-11:00>",
      ":END:",
      ":LOGBOOK:",
      "CLOCK: [2026-09-28 Mon 10:00]--[2026-09-28 Mon 11:00] =>  1:00",
      ":END:",
    })
    local ts = file.headlines[1].timestamps
    eq(1, #ts)
    eq(3, ts[1].line)
    eq(10, ts[1].date.hour)
    local T = require("org.date").days_from_civil(2026, 9, 28)
    local items = require("org.agenda.items").agenda({ file }, T, T, { today = T })[T]
    eq(1, #items)
    eq("Meeting", items[1].title)
    eq(10 * 60, items[1].time)
  end)

  describe("time zones", function()
    local tz = require("org.extensions.gcal.tz")

    it("reads DST rules from POSIX TZ strings, both hemispheres", function()
      local D = require("org.date").days_from_civil
      local cet = tz.parse_posix("CET-1CEST,M3.5.0,M10.5.0/3")
      local z = { times = {}, types = {}, offsets = {}, footer = cet }
      eq(3600, tz.offset_at(z, D(2030, 1, 15) * 86400))
      eq(7200, tz.offset_at(z, D(2030, 7, 15) * 86400))
      -- 2030-03-31 is the last Sunday of March: 01:00 UTC switches
      eq(3600, tz.offset_at(z, D(2030, 3, 31) * 86400 + 3599))
      eq(7200, tz.offset_at(z, D(2030, 3, 31) * 86400 + 3600))
      local syd = { times = {}, types = {}, offsets = {}, footer = tz.parse_posix("AEST-10AEDT,M10.1.0,M4.1.0/3") }
      eq(11 * 3600, tz.offset_at(syd, D(2030, 1, 15) * 86400))
      eq(10 * 3600, tz.offset_at(syd, D(2030, 7, 15) * 86400))
      eq({ std = -5 * 3600 }, tz.parse_posix("EST5"))
    end)

    it("ignores a zone argument that isn't a name (parse_rfc3339's second value)", function()
      local t = event.parse_rfc3339("2026-09-28T10:00:00Z")
      eq(10, event.epoch_to_local({ utc_offset = 0 }, event.parse_rfc3339("2026-09-28T10:00:00Z")).hour)
      eq(0, event.offset({ utc_offset = 0 }, t, 3600))
    end)

    it("reads the system zone files when they exist", function()
      if not tz.load("America/Chicago") then
        return
      end
      local D = require("org.date").days_from_civil
      eq(-5 * 3600, tz.offset("America/Chicago", D(2026, 9, 28) * 86400))
      eq(-6 * 3600, tz.offset("America/Chicago", D(2026, 12, 1) * 86400))
      eq(nil, tz.offset("No/Such_Zone", 0))
      eq(nil, tz.load("../../etc/passwd"))
    end)
  end)

  describe("security", function()
    it("ignores redirects that carry another state", function()
      local got
      local redirect = oauth.listen(function(q, err)
        got = q or { err = err }
      end, 5000, "good-state")
      local port = tonumber(redirect:match(":(%d+)$"))
      local function hit(qs)
        local client = vim.uv.new_tcp()
        local reply = ""
        local done = false
        client:connect("127.0.0.1", port, function()
          client:write("GET /?" .. qs .. " HTTP/1.1\r\n\r\n")
          client:read_start(function(_, chunk)
            if chunk then
              reply = reply .. chunk
            else
              client:close()
              done = true
            end
          end)
        end)
        vim.wait(2000, function()
          return done
        end, 10)
        return reply
      end
      local r = hit("code=evil&state=other")
      ok(r:find("^HTTP/1%.1 400"), r)
      vim.wait(100)
      eq(nil, got)
      hit("code=real&state=good-state")
      vim.wait(2000, function()
        return got ~= nil
      end, 10)
      eq("real", got.code)
    end)

    it("does not follow a leftover temp file when saving tokens", function()
      local victim = tmp .. "/victim"
      vim.fn.writefile({ "keep" }, victim)
      local path = tmp .. "/gcal-token.json"
      vim.uv.fs_symlink(victim, path .. ".tmp")
      valid_tokens()
      eq({ "keep" }, vim.fn.readfile(victim))
      local st = vim.uv.fs_stat(path)
      eq(tonumber("600", 8), bit.band(st.mode, tonumber("777", 8)))
    end)

    it("scrubs the client secret and codes from curl errors", function()
      oauth.client_secret(gcal.opts())
      local msg = oauth.redact("curl: (7) failed data-raw client_secret=csecret-value&code=abc123 csecret-value")
      ok(not msg:find("csecret-value", 1, true), msg)
      ok(not msg:find("abc123", 1, true), msg)
    end)
  end)

  describe("sync behaviour", function()
    it("skips new events outside the window in incremental syncs and keeps the token's expiry", function()
      local state = oauth.load(gcal.opts())
      state.sync_tokens[CAL] = { token = "sync-1", expires = NOW + 999 }
      oauth.save(gcal.opts(), state)
      route("GET", "/events", function()
        return 200,
          {
            items = {
              ev("near"),
              ev("far", {
                start = { dateTime = "2028-01-01T10:00:00Z" },
                ["end"] = { dateTime = "2028-01-01T11:00:00Z" },
              }),
            },
            nextSyncToken = "sync-2",
          }
      end)
      local okx, err = run(function()
        return sync.run({ push = false })
      end)
      ok(okx, err)
      local lines = read(tmp .. "/cal.org")
      ok(has_line(lines, "^%* Event near$"))
      ok(not has_line(lines, "Event far"), table.concat(lines, "\n"))
      local st = oauth.load(gcal.opts()).sync_tokens[CAL]
      eq("sync-2", st.token)
      eq(NOW + 999, st.expires)
    end)

    it("asks for deleted events in a full fetch and checks entries it didn't list", function()
      vim.fn.writefile({
        "* Deleted meanwhile",
        ":PROPERTIES:",
        ":calendar-id: " .. CAL,
        ":entry-id: gone/" .. CAL,
        ":END:",
        ":org-gcal:",
        "<2026-09-29 Tue 10:00-11:00>",
        ":END:",
        "* Long ago",
        ":PROPERTIES:",
        ":entry-id: old/" .. CAL,
        ":END:",
        ":org-gcal:",
        "<2020-01-01 Wed 10:00-11:00>",
        ":END:",
      }, tmp .. "/cal.org")
      route("GET", "/events%?", function(req)
        eq("true", query_of(req.url).showDeleted)
        return 200, { items = {}, nextSyncToken = "s" }
      end)
      route("GET", "/events/gone$", function()
        return 404, { error = { message = "Not Found" } }
      end)
      local okx, err = run(function()
        return sync.run({ push = false })
      end)
      ok(okx, err)
      local lines = read(tmp .. "/cal.org")
      ok(not has_line(lines, "Deleted meanwhile"), table.concat(lines, "\n"))
      -- outside the window: left alone, not asked for
      ok(has_line(lines, "^%* Long ago$"))
      eq(0, #vim.tbl_filter(function(r)
        return r.url:find("/events/old")
      end, requests))
    end)

    it("retries rate limits and server errors", function()
      local n = 0
      route("GET", "/events", function()
        n = n + 1
        if n == 1 then
          return 429, { error = { message = "slow down" } }
        elseif n == 2 then
          return 403, { error = { errors = { { reason = "rateLimitExceeded" } }, message = "Rate Limit Exceeded" } }
        elseif n == 3 then
          return 503, ""
        end
        return 200, { items = {}, nextSyncToken = "s" }
      end)
      local okx, err = run(function()
        return sync.run({ push = false })
      end)
      ok(okx, err)
      eq(4, n)
    end)

    it("does not retry a plain 403", function()
      route("GET", "/events", function()
        return 403, { error = { message = "Calendar API has not been used" } }
      end)
      local okx, err = run(function()
        return sync.run({ push = false })
      end)
      ok(not okx)
      ok(err:find("403", 1, true), err)
      eq(1, #requests)
    end)

    it("finds an entry refiled to an agenda file instead of adding it again", function()
      vim.fn.writefile({ "* Elsewhere", ":PROPERTIES:", ":entry-id: a/" .. CAL, ":END:" }, tmp .. "/refiled.org")
      setup(nil, { agenda_files = { tmp .. "/refiled.org" } })
      route("GET", "/events", function()
        return 200, { items = { ev("a", { summary = "Moved" }) }, nextSyncToken = "s" }
      end)
      local okx, err = run(function()
        return sync.run({ push = false })
      end)
      ok(okx, err)
      eq("* Moved", read(tmp .. "/refiled.org")[1])
      eq(0, vim.fn.filereadable(tmp .. "/cal.org") == 1 and #vim.tbl_filter(function(l)
        return l:find("^%*")
      end, read(tmp .. "/cal.org")) or 0)
    end)

    it("applies fetch_event_filters, custom property names and the update hooks", function()
      local calls = {}
      setup({
        fetch_event_filters = {
          function(e)
            return e.summary ~= "Skip me"
          end,
        },
        entry_id_property = "gcal-id",
        drawer_name = "cal",
        after_update_entry = function(cal, e, mode)
          calls[#calls + 1] = { cal, e.id, mode }
        end,
      })
      local seen = {}
      local au = vim.api.nvim_create_autocmd("User", {
        pattern = "OrgGcalEntryUpdated",
        callback = function(a)
          seen[#seen + 1] = a.data.mode
        end,
      })
      route("GET", "/events", function()
        return 200, { items = { ev("a"), ev("b", { summary = "Skip me" }) }, nextSyncToken = "s" }
      end)
      local okx, err = run(function()
        return sync.run({ push = false })
      end)
      vim.api.nvim_del_autocmd(au)
      ok(okx, err)
      local lines = read(tmp .. "/cal.org")
      ok(has_line(lines, "^:gcal%-id:%s+a/cal@example%.com$"), table.concat(lines, "\n"))
      ok(has_line(lines, "^:cal:$"))
      ok(not has_line(lines, "Skip me"))
      eq({ { CAL, "a", "newly_fetched" } }, calls)
      eq({ "newly_fetched" }, seen)
    end)

    it("asks before pushing an entry managed by Google, and never pushes it when syncing", function()
      local function open()
        vim.fn.writefile({
          "* Edited here",
          ":PROPERTIES:",
          ':ETag:     "etag-a"',
          ":calendar-id: " .. CAL,
          ":entry-id: a/" .. CAL,
          ":org-gcal-managed: gcal",
          ":END:",
          ":org-gcal:",
          "<2026-09-28 Mon 10:00-11:00>",
          ":END:",
        }, tmp .. "/cal.org")
        vim.cmd("edit! " .. vim.fn.fnameescape(tmp .. "/cal.org"))
      end
      open()
      route("GET", "/events/a$", function()
        return 200, ev("a", { summary = "Server title" })
      end)
      require("org.utils").confirm = function()
        return false
      end
      local okx, err = run(function()
        return sync.post({ bufnr = 0 })
      end)
      ok(okx, err)
      eq(0, #vim.tbl_filter(function(r)
        return r.method == "PATCH"
      end, requests))
      eq("* Server title", read(tmp .. "/cal.org")[1])
      -- during a sync "prompt" means never push: no question at all
      open()
      require("org.utils").confirm = function()
        error("asked")
      end
      okx, err = run(function()
        return sync.buffer(0, { push = true })
      end)
      ok(okx, err)
      eq(0, #vim.tbl_filter(function(r)
        return r.method == "PATCH"
      end, requests))
    end)

    it("keeps the entry of a deleted event when told to, without its calendar data", function()
      setup({ remove_api_cancelled_events = false }, { todo_keywords = { "TODO | DONE CANCELLED" } })
      vim.fn.writefile({
        "* Party",
        ":PROPERTIES:",
        ':ETag:     "e1"',
        ":calendar-id: " .. CAL,
        ":entry-id: a/" .. CAL,
        ":MINE: yes",
        ":END:",
        ":org-gcal:",
        "<2026-09-28 Mon 10:00-11:00>",
        ":END:",
        "Notes",
      }, tmp .. "/cal.org")
      vim.cmd("edit! " .. vim.fn.fnameescape(tmp .. "/cal.org"))
      require("org.utils").confirm = function()
        return true
      end
      route("DELETE", "/events/a$", function()
        return 204, ""
      end)
      local okx, err = run(function()
        return sync.delete({ bufnr = 0 })
      end)
      ok(okx, err)
      local lines = read(tmp .. "/cal.org")
      eq("* CANCELLED Party", lines[1])
      ok(has_line(lines, "^:MINE:%s+yes$"))
      ok(has_line(lines, "^Notes$"))
      ok(not has_line(lines, "entry%-id"), table.concat(lines, "\n"))
      ok(not has_line(lines, ":org%-gcal:"))
    end)

    it("turns a timed event into an all-day one with an explicit null", function()
      vim.fn.writefile({
        "* Offsite",
        ":PROPERTIES:",
        ':ETag:     "etag-a"',
        ":calendar-id: " .. CAL,
        ":entry-id: a/" .. CAL,
        ":org-gcal-managed: org",
        ":END:",
        ":org-gcal:",
        "<2026-09-30 Wed>",
        ":END:",
      }, tmp .. "/cal.org")
      vim.cmd("edit! " .. vim.fn.fnameescape(tmp .. "/cal.org"))
      local sent
      route("PATCH", "/events/a$", function(req)
        sent = req.body
        return 200, ev("a", { start = { date = "2026-09-30" }, ["end"] = { date = "2026-10-01" } })
      end)
      local okx, err = run(function()
        return sync.post({ bufnr = 0 })
      end)
      ok(okx, err)
      ok(sent:find('"dateTime":null', 1, true), sent)
      ok(sent:find('"date":"2026-09-30"', 1, true), sent)
      ok(has_line(read(tmp .. "/cal.org"), "^<2026%-09%-30 Wed>$"))
    end)
  end)

  it("registers its actions only when enabled", function()
    ok(require("org.actions").list.gcal_fetch)
    ok(require("org.actions").list.gcal_post_at_point)
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      agenda_files = { root .. "/tests/fixtures/*.org" },
    })
    eq(nil, require("org.actions").list.gcal_fetch)
  end)
end)
