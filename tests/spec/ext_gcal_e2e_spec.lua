-- The gcal extension end to end: real curl against a local stand-in for
-- Google (tests/support/gcal_server.lua) on 127.0.0.1. No request leaves
-- the machine and no real token is used.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local Server = dofile(root .. "/tests/support/gcal_server.lua")

local CAL = "team@example.com"
local NOW = require("org.date").days_from_civil(2026, 9, 28) * 86400 + 12 * 3600

local tmp, gcal, oauth, sync, srv

local function setup(extra, top)
  require("org").setup(vim.tbl_extend("force", {
    org_directory = tmp,
    agenda_files = { tmp .. "/cal.org" },
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
        timeout = 10,
      }, extra or {}),
    },
  }, top or {}))
end

local function run(fn)
  local done, res = false, nil
  require("org.utils").run(function()
    res = { fn() }
    done = true
  end)
  vim.wait(15000, function()
    return done
  end, 5)
  ok(done, "coroutine did not finish")
  return unpack(res)
end

local function read()
  return vim.fn.readfile(tmp .. "/cal.org")
end

local function text()
  return table.concat(read(), "\n")
end

local function has(pat)
  return text():find(pat) ~= nil
end

local function authorize()
  srv:grant("tok-1", "ref-1")
  oauth.save(gcal.opts(), {
    access_token = "tok-1",
    refresh_token = "ref-1",
    expires_at = NOW + 3600,
    sync_tokens = {},
  })
end

local function timed(id, day, h1, h2, over)
  day = day:find("^%d%d%d%d%-") and day:sub(6) or day
  local year = over and over._year or "2026"
  return vim.tbl_extend("force", {
    id = id,
    summary = "Event " .. id,
    start = { dateTime = string.format("%s-%sT%02d:00:00Z", year, day, h1) },
    ["end"] = { dateTime = string.format("%s-%sT%02d:00:00Z", year, day, h2) },
  }, vim.tbl_extend("force", over or {}, { _year = vim.NIL }))
end

local function fetch(push)
  local okx, err = run(function()
    return sync.run({ push = push or false })
  end)
  ok(okx, err)
end

describe("gcal end to end (local server, real curl)", function()
  if vim.fn.executable("curl") == 0 then
    return
  end
  local saved_now, saved_confirm
  before_each(function()
    tmp = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(tmp, "p")
    gcal = require("org.extensions.gcal")
    oauth = require("org.extensions.gcal.oauth")
    sync = require("org.extensions.gcal.sync")
    saved_now, saved_confirm = gcal.now, require("org.utils").confirm
    gcal.now = function()
      return NOW
    end
    srv = Server.start()
    srv:install()
    srv:calendar(CAL, "UTC")
    setup()
  end)
  after_each(function()
    srv:uninstall()
    srv:stop()
    gcal.now = saved_now
    require("org.utils").confirm = saved_confirm
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):find(tmp, 1, true) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    vim.fn.delete(tmp, "rf")
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      agenda_files = { root .. "/tests/fixtures/*.org" },
    })
  end)

  it("authorizes through the consent page and the loopback redirect with PKCE", function()
    local open, notify = vim.ui.open, vim.notify
    vim.notify = function() end
    -- the "browser": follow the consent page's redirect back to Neovim
    vim.ui.open = function(url)
      vim.system({ "curl", "-s", "-L", "-o", "/dev/null", url })
    end
    local okx, err = run(function()
      return oauth.authorize(gcal.opts())
    end)
    vim.ui.open, vim.notify = open, notify
    ok(okx, err)
    local state = oauth.load(gcal.opts())
    ok(state.access_token and state.refresh_token)
    local st = vim.uv.fs_stat(tmp .. "/gcal-token.json")
    eq(tonumber("600", 8), bit.band(st.mode, tonumber("777", 8)))
    -- the token endpoint checked the verifier against the challenge
    eq(1, #srv:requests("POST", "^/token$"))
  end)

  it("fetches with paging, then syncs incrementally, and resyncs after a 410", function()
    authorize()
    srv:put(CAL, timed("a", "09-28", 10, 11, { description = "Bring <b>slides</b>" }))
    srv:put(CAL, { id = "b", summary = "Holiday", start = { date = "2026-09-30" }, ["end"] = { date = "2026-10-02" } })
    srv:put(CAL, timed("c", "10-05", 9, 10, { location = "Room 4" }))
    srv:put(CAL, timed("old", "01-05", 9, 10))
    fetch()
    local s = text()
    ok(s:find("%* Event a"), s)
    ok(s:find("<2026%-09%-30 Wed>%-%-<2026%-10%-01 Thu>"), s)
    ok(s:find(":LOCATION: Room 4"), s)
    ok(not s:find("Event old"), s)
    -- 3 events with pages of 2
    local lists = srv:requests("GET", "/events$")
    eq(2, #lists)
    eq("true", lists[1].query.showDeleted)
    ok(oauth.load(gcal.opts()).sync_tokens[CAL].token)

    -- changes on Google: one edited, one deleted, one new far in the future
    srv:put(CAL, timed("a", "09-28", 14, 15, { summary = "Moved" }))
    srv:remove(CAL, "c")
    srv:put(CAL, timed("far", "12-25", 9, 10))
    srv.log = {}
    fetch()
    lists = srv:requests("GET", "/events$")
    ok(lists[1].query.syncToken, vim.inspect(lists[1].query))
    s = text()
    ok(s:find("%* Moved"), s)
    ok(s:find("<2026%-09%-28 Mon 14:00%-15:00>"), s)
    ok(not s:find("Room 4"), s)
    ok(not s:find("Event far"), s)

    -- the server invalidates sync tokens: a 410, then a full fetch
    srv.min_sync = math.huge
    srv.log = {}
    fetch()
    lists = srv:requests("GET", "/events$")
    ok(lists[1].query.syncToken)
    ok(lists[2].query.timeMin, vim.inspect(lists[2].query))
  end)

  it("creates, updates (timed to all-day) and resolves ETag conflicts through the API", function()
    authorize()
    vim.fn.writefile({ "* Review", "SCHEDULED: <2026-10-01 Thu 15:00-16:00>", "Agenda items." }, tmp .. "/cal.org")
    vim.cmd("edit! " .. vim.fn.fnameescape(tmp .. "/cal.org"))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local okx, err = run(function()
      return sync.post({ bufnr = 0 })
    end)
    ok(okx, err)
    local s = text()
    ok(s:find(":entry%-id:%s+srv%d+/team@example%.com"), s)
    local id = s:match(":entry%-id:%s+(srv%d+)/")
    eq("Review", srv.calendars[CAL].events[id].summary)
    -- like org-gcal, only the drawer holds the description
    eq("", srv.calendars[CAL].events[id].description)

    -- make it an all-day event: the server refuses a start with both kinds
    vim.cmd("edit!")
    local buf = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, l in ipairs(lines) do
      if l:find("^SCHEDULED:") then
        lines[i] = "SCHEDULED: <2026-10-02 Fri>"
      end
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    okx, err = run(function()
      return sync.post({ bufnr = 0 })
    end)
    ok(okx, err)
    eq("2026-10-02", srv.calendars[CAL].events[id].start.date)
    eq(nil, srv.calendars[CAL].events[id].start.dateTime)

    -- changed on Google meanwhile: the local edit loses, the entry follows
    srv:put(CAL, vim.tbl_extend("force", srv.calendars[CAL].events[id], { summary = "Renamed on the web" }))
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "* Local rename" })
    okx, err = run(function()
      return sync.post({ bufnr = buf, lnum = 1 })
    end)
    ok(okx, err)
    eq("* Renamed on the web", read()[1])
    eq("Renamed on the web", srv.calendars[CAL].events[id].summary)
    local patches = srv:requests("PATCH")
    ok(patches[#patches].headers["if-match"], "sent If-Match")
  end)

  it("posts a repeating entry as a recurring event and doesn't duplicate its instances", function()
    authorize()
    vim.fn.writefile({ "* Standup", ":org-gcal:", "<2026-09-28 Mon 09:00-09:15 +1w>", ":END:" }, tmp .. "/cal.org")
    vim.cmd("edit! " .. vim.fn.fnameescape(tmp .. "/cal.org"))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local okx, err = run(function()
      return sync.post({ bufnr = 0 })
    end)
    ok(okx, err)
    local id = text():match(":entry%-id:%s+(srv%d+)/")
    local ev = srv.calendars[CAL].events[id]
    eq({ "RRULE:FREQ=WEEKLY;INTERVAL=1" }, ev.recurrence)
    eq("UTC", ev.start.timeZone)
    ok(has(":recurrence:%s+%[RRULE:FREQ=WEEKLY;INTERVAL=1%]"), text())
    -- the list returns instances; the repeater already stands for them
    oauth.save(gcal.opts(), vim.tbl_extend("force", oauth.load(gcal.opts()), { sync_tokens = {} }))
    fetch()
    local heads = vim.tbl_filter(function(l)
      return l:find("^%*")
    end, read())
    eq({ "* Standup" }, heads)
  end)

  it("nests the instances of a recurring event under its entry in nested mode", function()
    setup({ recurring_events_mode = "nested" })
    authorize()
    srv:put(CAL, {
      id = "weekly",
      summary = "Planning",
      recurrence = { "RRULE:FREQ=WEEKLY;COUNT=3" },
      start = { dateTime = "2026-09-29T10:00:00Z", timeZone = "UTC" },
      ["end"] = { dateTime = "2026-09-29T11:00:00Z", timeZone = "UTC" },
    })
    fetch()
    local heads = vim.tbl_filter(function(l)
      return l:find("^%*")
    end, read())
    eq({ "* Planning", "** Planning", "** Planning", "** Planning" }, heads)
    ok(has(":recurrence:%s+%[RRULE:FREQ=WEEKLY;COUNT=3%]"), text())
    ok(has("<2026%-10%-13 Tue 10:00%-11:00>"), text())
    -- a second fetch changes nothing
    local before = text()
    oauth.save(gcal.opts(), vim.tbl_extend("force", oauth.load(gcal.opts()), { sync_tokens = {} }))
    fetch()
    eq(#vim.split(before, "\n"), #read())
  end)

  it("removes an entry whose event vanished while no sync token was kept", function()
    authorize()
    srv:put(CAL, timed("a", "09-29", 10, 11))
    srv:put(CAL, timed("b", "09-30", 10, 11))
    fetch()
    srv:remove(CAL, "b", true) -- gone for good: not even listed as cancelled
    oauth.save(gcal.opts(), vim.tbl_extend("force", oauth.load(gcal.opts()), { sync_tokens = {} }))
    fetch()
    ok(has("%* Event a"))
    ok(not has("Event b"), text())
  end)

  it("pushes entries managed by org that changed only locally when syncing", function()
    authorize()
    srv:put(CAL, timed("a", "09-29", 10, 11))
    fetch()
    local buf = require("org.utils").load_buffer(tmp .. "/cal.org")
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, l in ipairs(lines) do
      lines[i] = l:gsub("org%-gcal%-managed: gcal", "org-gcal-managed: org"):gsub("^%* Event a", "* Edited in Org")
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    fetch(true)
    eq("Edited in Org", srv.calendars[CAL].events.a.summary)
  end)

  it("posts and deletes from the agenda", function()
    -- the agenda shows the real today
    gcal.now = os.time
    authorize()
    srv:put(CAL, timed("a", os.date("!%m-%d"), 10, 11, { summary = "Dentist", _year = os.date("!%Y") }))
    fetch()
    require("org.utils").confirm = function()
      return true
    end
    require("org.agenda").command("a")
    local view = require("org.agenda.view")
    local line
    for l = 1, vim.api.nvim_buf_line_count(0) do
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      local it = view.item_at_cursor()
      if it and it.title == "Dentist" then
        line = l
        break
      end
    end
    ok(line, "Dentist is in the agenda")
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    local okx, err = run(function()
      return sync.delete()
    end)
    ok(okx, err)
    eq("cancelled", srv.calendars[CAL].events.a.status)
    ok(not has("Dentist"), text())
    view.quit(true)
  end)

  it("retries through rate limits", function()
    authorize()
    srv.fail_next = { 429, 403, 503 }
    srv:put(CAL, timed("a", "09-29", 10, 11))
    fetch()
    ok(has("%* Event a"))
  end)
end)
