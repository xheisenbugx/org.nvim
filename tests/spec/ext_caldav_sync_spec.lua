-- The caldav extension: syncing a calendar with org files, against an
-- in-process stand-in for a CalDAV server (tests/support/caldav_server.lua).
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
local Server = dofile(root .. "/tests/support/caldav_server.lua")
local date = require("org.date")
local http = require("org.extensions.caldav.http")
local sync = require("org.extensions.caldav.sync")

-- a Tuesday
local TODAY = date.Date.new({ year = 2026, month = 11, day = 10 })

local tmp, srv, path
local real = {}

local function setup(cal, extra)
  local c =
    vim.tbl_extend("force", { name = "Work", url = "http://dav.test" .. srv.home .. "work/", inbox = path }, cal or {})
  require("org").setup({
    org_directory = tmp,
    extensions = {
      caldav = vim.tbl_extend("force", {
        calendars = { c },
        timezone = "UTC",
        state_dir = tmp .. "/state",
        delete_local = "always",
        delete_remote = "always",
      }, extra or {}),
    },
  })
end

--- Sync and wait: the result of the calendar.
local function run(auto)
  local done, results = false, nil
  sync.run(nil, {
    auto = auto,
    done = function(r)
      results, done = r, true
    end,
  })
  vim.wait(10000, function()
    return done
  end, 5)
  ok(done, "the sync did not finish")
  return results and results[1]
end

local function buf()
  return require("org.utils").load_buffer(path)
end

local function org()
  return vim.api.nvim_buf_get_lines(buf(), 0, -1, false)
end

local function set(lines)
  vim.api.nvim_buf_set_lines(buf(), 0, -1, false, lines)
end

--- Replace the first line matching `pat` (plain) with `new` (nil: delete).
local function change(pat, new)
  local lines = org()
  for i, l in ipairs(lines) do
    if l:find(pat, 1, true) then
      vim.api.nvim_buf_set_lines(buf(), i - 1, i, false, new and { new } or {})
      return
    end
  end
  error("no line with " .. pat)
end

local function ics(kind, uid, props)
  local lines = { "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//test//EN", "BEGIN:" .. kind, "UID:" .. uid }
  vim.list_extend(lines, props)
  vim.list_extend(lines, { "END:" .. kind, "END:VCALENDAR" })
  return table.concat(lines, "\r\n") .. "\r\n"
end

local function event(uid, props)
  return ics("VEVENT", uid, props)
end

--- The unfolded lines of a resource on the server.
local function stored(file)
  local text = srv:get("work", file)
  return text and require("org.extensions.ics.parser").unfold(text) or nil
end

local function has(list, line)
  return vim.tbl_contains(list or {}, line)
end

local function before()
  tmp = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(tmp, "p")
  path = tmp .. "/cal.org"
  srv = Server.new()
  srv:calendar("work")
  real.transport, real.today, real.now, real.notify = http.transport, date.today, date.now, vim.notify
  http.transport = srv:transport()
  date.today = function()
    return TODAY:clone()
  end
  date.now = function()
    return TODAY:clone({ hour = 12, min = 0 })
  end
  vim.notify = function() end
end

local function after()
  http.transport, date.today, date.now, vim.notify = real.transport, real.today, real.now, real.notify
  require("org").setup({ extensions = {} })
  local b = vim.fn.bufnr(path)
  if b > 0 then
    vim.api.nvim_buf_delete(b, { force = true })
  end
end

describe("caldav: from the calendar", function()
  before_each(before)
  after_each(after)

  it("adds the calendar's events to the inbox as headings", function()
    srv:put(
      "work",
      "a.ics",
      event("uid-a", {
        "SUMMARY:Design review",
        "DTSTART:20261112T150000Z",
        "DTEND:20261112T160000Z",
        "LOCATION:Room 4",
        "DESCRIPTION:Bring the mockups\\nand the notes",
      })
    )
    srv:put(
      "work",
      "b.ics",
      event("uid-b", { "SUMMARY:Conference", "DTSTART;VALUE=DATE:20261120", "DTEND;VALUE=DATE:20261123" })
    )
    setup()
    local res = run()
    eq(nil, res.failed)
    eq(2, res.pulled)
    eq({
      "* Design review",
      ":PROPERTIES:",
      ":ID:       uid-a",
      ":LOCATION: Room 4",
      ":END:",
      "<2026-11-12 Thu 15:00-16:00>",
      "Bring the mockups",
      "and the notes",
      "* Conference",
      ":PROPERTIES:",
      ":ID:       uid-b",
      ":END:",
      "<2026-11-20 Fri>--<2026-11-22 Sun>",
    }, org())
    eq(org(), vim.fn.readfile(path), "the file is saved")
    -- nothing to do the second time, and nothing is sent
    res = run()
    eq(0, res.pulled + res.pushed)
    eq(0, #srv:requests("PUT"))
  end)

  it("puts new events under the inbox headline", function()
    vim.fn.writefile({ "* Notes", "text", "* Calendar", "** Old" }, path)
    srv:put("work", "a.ics", event("uid-a", { "SUMMARY:Lunch", "DTSTART:20261112T120000Z" }))
    setup({ inbox = { file = path, headline = "Calendar" } })
    run()
    eq({
      "* Notes",
      "text",
      "* Calendar",
      "** Old",
      "** Lunch",
      ":PROPERTIES:",
      ":ID:       uid-a",
      ":END:",
      "<2026-11-12 Thu 12:00>",
    }, org())
  end)

  it("writes a change of the calendar into the entry, a field at a time", function()
    srv:put("work", "a.ics", event("uid-a", { "SUMMARY:Lunch", "DTSTART:20261112T120000Z", "DTEND:20261112T130000Z" }))
    setup()
    run()
    -- the user's own additions to the entry stay
    change("* Lunch", "* Lunch :food:")
    srv:put(
      "work",
      "a.ics",
      event(
        "uid-a",
        { "SUMMARY:Lunch with Ana", "DTSTART:20261113T123000Z", "DTEND:20261113T133000Z", "LOCATION:Cafe" }
      )
    )
    local res = run()
    eq(1, res.pulled)
    eq(0, res.pushed)
    local lines = org()
    ok(lines[1]:match("^%* Lunch with Ana%s+:food:$"), lines[1])
    ok(has(lines, ":LOCATION: Cafe"))
    ok(has(lines, "<2026-11-13 Fri 12:30-13:30>"))
  end)

  it("leaves out events that ended before past_days, and keeps one that grew old", function()
    srv:put("work", "old.ics", event("uid-old", { "SUMMARY:Long ago", "DTSTART:20260101T100000Z" }))
    srv:put("work", "new.ics", event("uid-new", { "SUMMARY:Soon", "DTSTART:20261111T100000Z" }))
    setup()
    run()
    eq({ "* Soon", ":PROPERTIES:", ":ID:       uid-new", ":END:", "<2026-11-11 Wed 10:00>" }, org())
    -- 60 days later the event is out of the days asked for, but it still
    -- exists: the entry stays
    TODAY = date.Date.new({ year = 2027, month = 1, day = 20 })
    local res = run()
    TODAY = date.Date.new({ year = 2026, month = 11, day = 10 })
    eq(0, res.deleted_local)
    eq("* Soon", org()[1])
    eq(1, #srv:requests("PROPFIND"))
  end)
end)

describe("caldav: to the calendar", function()
  before_each(before)
  after_each(after)

  it("sends new entries as events, with a new ID as their UID", function()
    vim.fn.writefile({
      "* Dentist",
      "<2026-11-12 Thu 15:00-16:00>",
      "Bring the x-rays",
      "* Trip :travel:",
      "<2026-11-20 Fri>--<2026-11-22 Sun>",
      "* Just a note",
      "* Standup",
      "SCHEDULED: <2026-11-11 Wed 09:00 +1d>",
    }, path)
    setup()
    local res = run()
    eq(nil, res.failed)
    eq(3, res.pushed)
    local lines = org()
    local ids = {}
    for _, l in ipairs(lines) do
      ids[#ids + 1] = l:match("^:ID:%s+(%S+)")
    end
    eq(3, #ids)
    eq(3, #srv:files("work"))
    local dentist = stored(ids[1] .. ".ics")
    ok(has(dentist, "UID:" .. ids[1]))
    ok(has(dentist, "SUMMARY:Dentist"))
    ok(has(dentist, "DTSTART:20261112T150000Z"))
    ok(has(dentist, "DTEND:20261112T160000Z"))
    ok(has(dentist, "DESCRIPTION:Bring the x-rays"))
    local trip = stored(ids[2] .. ".ics")
    ok(has(trip, "DTSTART;VALUE=DATE:20261120"))
    ok(has(trip, "DTEND;VALUE=DATE:20261123"))
    local standup = stored(ids[3] .. ".ics")
    ok(has(standup, "RRULE:FREQ=DAILY"))
    -- "Just a note" has no date: it is not an event
    ok(not table.concat(lines, "\n"):find("Just a note\n:PROPERTIES:", 1, true))
    -- and nothing more the second time
    res = run()
    eq(0, res.pulled + res.pushed)
    eq(3, #srv:requests("PUT"))
  end)

  it("sends a change of the entry, and leaves the rest of the event alone", function()
    srv:put(
      "work",
      "a.ics",
      event("uid-a", {
        "SUMMARY:Review",
        "DTSTART;TZID=Europe/Paris:20261112T160000",
        "DTEND;TZID=Europe/Paris:20261112T170000",
        "ATTENDEE;CN=Ana:mailto:ana@example.com",
        "X-CUSTOM:kept",
        "BEGIN:VALARM",
        "ACTION:DISPLAY",
        "TRIGGER:-PT10M",
        "END:VALARM",
      })
    )
    setup()
    run()
    ok(has(org(), "<2026-11-12 Thu 15:00-16:00>"))
    change("* Review", "* Design review")
    local res = run()
    eq(1, res.pushed)
    local put = srv:requests("PUT")[1]
    ok(put.headers["if-match"], "the change is conditional on the etag")
    local lines = stored("a.ics")
    ok(has(lines, "SUMMARY:Design review"))
    ok(has(lines, "DTSTART;TZID=Europe/Paris:20261112T160000"), "the time was not touched")
    ok(has(lines, "ATTENDEE;CN=Ana:mailto:ana@example.com"))
    ok(has(lines, "X-CUSTOM:kept"))
    ok(has(lines, "TRIGGER:-PT10M"))
    -- a new time is written in the zone the event has
    change("<2026-11-12 Thu 15:00-16:00>", "<2026-11-13 Fri 09:30-10:00>")
    run()
    lines = stored("a.ics")
    ok(has(lines, "DTSTART;TZID=Europe/Paris:20261113T103000"))
    ok(has(lines, "DTEND;TZID=Europe/Paris:20261113T110000"))
  end)

  it("sends the first of several timestamp lines of an entry as the event's time", function()
    vim.fn.writefile(
      { "* Workshop", "<2026-11-12 Thu 09:00-12:00>", "<2026-11-13 Fri 09:00-12:00>", "Bring a laptop" },
      path
    )
    setup()
    local res = run()
    eq({}, res.errors)
    eq(1, res.pushed)
    local id = org()[3]:match("^:ID:%s+(%S+)")
    local lines = stored(id .. ".ics")
    ok(has(lines, "DTSTART:20261112T090000Z"), vim.inspect(lines))
    ok(has(lines, "DESCRIPTION:Bring a laptop"))
    -- both lines stay in org, and nothing more is sent
    ok(has(org(), "<2026-11-13 Fri 09:00-12:00>"))
    eq(0, run().pushed)
  end)

  it("keeps a change it could not send and sends it the next time", function()
    srv:put("work", "a.ics", event("uid-a", { "SUMMARY:Review", "DTSTART:20261112T150000Z" }))
    setup()
    run()
    change("* Review", "* Design review")
    srv.fail = function(method)
      return method == "PUT" and 500 or nil
    end
    local res = run()
    eq(0, res.pushed)
    eq(1, #res.errors)
    ok(has(stored("a.ics"), "SUMMARY:Review"))
    srv.fail = nil
    res = run()
    eq(1, res.pushed)
    ok(has(stored("a.ics"), "SUMMARY:Design review"))
  end)
end)

describe("caldav: both ways", function()
  before_each(before)
  after_each(after)

  local function start()
    srv:put(
      "work",
      "a.ics",
      event("uid-a", { "SUMMARY:Review", "DTSTART:20261112T150000Z", "DTEND:20261112T160000Z", "LOCATION:Room 1" })
    )
  end

  it("merges changes of different fields", function()
    start()
    setup()
    run()
    change("* Review", "* Design review")
    srv:put(
      "work",
      "a.ics",
      event("uid-a", { "SUMMARY:Review", "DTSTART:20261112T150000Z", "DTEND:20261112T160000Z", "LOCATION:Room 9" })
    )
    local res = run()
    eq(0, res.conflicts)
    eq(1, res.pulled)
    eq(1, res.pushed)
    ok(has(org(), ":LOCATION: Room 9"))
    eq("* Design review", org()[1])
    ok(has(stored("a.ics"), "SUMMARY:Design review"))
    ok(has(stored("a.ics"), "LOCATION:Room 9"))
  end)

  it("org wins when the same field changed on both sides", function()
    start()
    setup()
    run()
    change("* Review", "* Org title")
    srv:put(
      "work",
      "a.ics",
      event(
        "uid-a",
        { "SUMMARY:Calendar title", "DTSTART:20261112T150000Z", "DTEND:20261112T160000Z", "LOCATION:Room 1" }
      )
    )
    local res = run()
    eq(1, res.conflicts)
    eq("* Org title", org()[1])
    ok(has(stored("a.ics"), "SUMMARY:Org title"))
  end)

  it("the calendar wins with conflict = 'remote'", function()
    start()
    setup({ conflict = "remote" })
    run()
    change("* Review", "* Org title")
    srv:put(
      "work",
      "a.ics",
      event(
        "uid-a",
        { "SUMMARY:Calendar title", "DTSTART:20261112T150000Z", "DTEND:20261112T160000Z", "LOCATION:Room 1" }
      )
    )
    local res = run()
    eq(1, res.conflicts)
    eq(0, res.pushed)
    eq("* Calendar title", org()[1])
  end)

  it("deletes the entry of an event deleted in the calendar", function()
    start()
    srv:put("work", "b.ics", event("uid-b", { "SUMMARY:Other", "DTSTART:20261113T150000Z" }))
    setup()
    run()
    srv:remove("work", "a.ics")
    local res = run()
    eq(1, res.deleted_local)
    eq({ "* Other", ":PROPERTIES:", ":ID:       uid-b", ":END:", "<2026-11-13 Fri 15:00>" }, org())
  end)

  it("deletes the event of an entry deleted in org", function()
    start()
    srv:put("work", "b.ics", event("uid-b", { "SUMMARY:Other", "DTSTART:20261113T150000Z" }))
    setup()
    run()
    set({ "* Other", ":PROPERTIES:", ":ID:       uid-b", ":END:", "<2026-11-13 Fri 15:00>" })
    local res = run()
    eq(1, res.deleted_remote)
    eq({ "b.ics" }, srv:files("work"))
  end)

  it("never deletes with 'never', and waits with 'ask' when nobody can answer", function()
    start()
    srv:put("work", "b.ics", event("uid-b", { "SUMMARY:Other", "DTSTART:20261113T150000Z" }))
    setup({ delete_remote = "never", delete_local = "ask" })
    run()
    set({ "* Other", ":PROPERTIES:", ":ID:       uid-b", ":END:", "<2026-11-13 Fri 15:00>" })
    local res = run()
    eq(0, res.deleted_remote)
    eq({ "a.ics", "b.ics" }, srv:files("work"))
    srv:remove("work", "b.ics")
    res = run(true)
    eq(0, res.deleted_local)
    eq("* Other", org()[1])
    ok(res.notes[1]:find("wait for :Org caldav_sync", 1, true), res.notes[1])
  end)

  it("matches entries and events by ID when the state is lost, without duplicates", function()
    start()
    setup()
    run()
    vim.fn.delete(tmp .. "/state", "rf")
    local res = run()
    eq(0, res.pulled + res.pushed)
    eq(6, #org())
    eq({ "a.ics" }, srv:files("work"))
  end)
end)

describe("caldav: repeating events", function()
  before_each(before)
  after_each(after)

  it("reads a plain rule as a repeater and sends a repeater as a rule", function()
    srv:put(
      "work",
      "a.ics",
      event(
        "uid-a",
        { "SUMMARY:Weekly", "DTSTART:20261112T150000Z", "DTEND:20261112T160000Z", "RRULE:FREQ=WEEKLY;BYDAY=TH" }
      )
    )
    setup()
    run()
    ok(has(org(), "<2026-11-12 Thu 15:00-16:00 +1w>"))
    change("<2026-11-12 Thu 15:00-16:00 +1w>", "<2026-11-13 Fri 10:00-11:00 +2w>")
    local res = run()
    eq(1, res.pushed)
    local lines = stored("a.ics")
    ok(has(lines, "RRULE:FREQ=WEEKLY;INTERVAL=2"), vim.inspect(lines))
    ok(has(lines, "DTSTART:20261113T100000Z"))
  end)

  it("writes a weekly rule on several days as one repeater per day", function()
    srv:put(
      "work",
      "a.ics",
      event(
        "uid-a",
        { "SUMMARY:Standup", "DTSTART:20261109T090000Z", "DURATION:PT15M", "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR" }
      )
    )
    setup()
    run()
    eq({
      "* Standup",
      ":PROPERTIES:",
      ":ID:       uid-a",
      ":END:",
      "<2026-11-09 Mon 09:00-09:15 +1w>",
      "<2026-11-11 Wed 09:00-09:15 +1w>",
      "<2026-11-13 Fri 09:00-09:15 +1w>",
    }, org())
  end)

  it("lists the occurrences of a rule a repeater can't say, and takes no dates for it from org", function()
    srv:put(
      "work",
      "a.ics",
      event("uid-a", {
        "SUMMARY:Course",
        "DTSTART:20261111T180000Z",
        "DTEND:20261111T190000Z",
        "RRULE:FREQ=DAILY;COUNT=4",
        "EXDATE:20261112T180000Z",
      })
    )
    setup()
    run()
    eq({
      "* Course",
      ":PROPERTIES:",
      ":ID:       uid-a",
      ":END:",
      "<2026-11-11 Wed 18:00-19:00>",
      "<2026-11-13 Fri 18:00-19:00>",
      "<2026-11-14 Sat 18:00-19:00>",
    }, org())
    -- a date changed in org is put back; the title still goes to the calendar
    change("<2026-11-13 Fri 18:00-19:00>", "<2026-11-13 Fri 20:00-21:00>")
    change("* Course", "* Evening course")
    local res = run()
    eq(1, res.pushed)
    ok(has(org(), "<2026-11-13 Fri 18:00-19:00>"))
    ok(res.notes[1]:find("follow a rule of the calendar", 1, true), vim.inspect(res.notes))
    local lines = stored("a.ics")
    ok(has(lines, "SUMMARY:Evening course"))
    ok(has(lines, "RRULE:FREQ=DAILY;COUNT=4"))
    ok(has(lines, "DTSTART:20261111T180000Z"))
    ok(has(lines, "EXDATE:20261112T180000Z"))
  end)
end)

describe("caldav: tasks", function()
  before_each(before)
  after_each(after)

  local function todo(uid, props)
    return ics("VTODO", uid, props)
  end

  it("leaves tasks out unless todos is on", function()
    srv:put("work", "t.ics", todo("t1", { "SUMMARY:Buy milk", "DUE;VALUE=DATE:20261115" }))
    vim.fn.writefile({ "* TODO Call Bob" }, path)
    setup()
    local res = run()
    eq(0, res.pulled + res.pushed)
    eq({ "* TODO Call Bob" }, org())
  end)

  it("syncs tasks with TODO entries: state, priority, dates", function()
    srv:put(
      "work",
      "t1.ics",
      todo("t1", {
        "SUMMARY:Buy milk",
        "DTSTART;VALUE=DATE:20261114",
        "DUE;VALUE=DATE:20261115",
        "PRIORITY:1",
        "STATUS:NEEDS-ACTION",
      })
    )
    srv:put(
      "work",
      "t2.ics",
      todo("t2", { "SUMMARY:Send report", "STATUS:COMPLETED", "COMPLETED:20261109T101500Z", "PERCENT-COMPLETE:100" })
    )
    vim.fn.writefile({ "* TODO Call Bob" }, path)
    setup({ todos = true })
    local res = run()
    eq(2, res.pulled)
    eq(1, res.pushed)
    local lines = org()
    local id = lines[3]:match("^:ID:%s+(%S+)")
    eq({
      "* TODO Call Bob",
      ":PROPERTIES:",
      ":ID:       " .. tostring(id),
      ":END:",
      "* TODO [#A] Buy milk",
      "DEADLINE: <2026-11-15 Sun> SCHEDULED: <2026-11-14 Sat>",
      ":PROPERTIES:",
      ":ID:       t1",
      ":END:",
      "* DONE Send report",
      "CLOSED: [2026-11-09 Mon 10:15]",
      ":PROPERTIES:",
      ":ID:       t2",
      ":END:",
    }, lines)
    local sent = stored(id .. ".ics")
    ok(has(sent, "BEGIN:VTODO"))
    ok(has(sent, "SUMMARY:Call Bob"))
    ok(has(sent, "STATUS:NEEDS-ACTION"))

    -- done in org: completed in the calendar
    change("* TODO [#A] Buy milk", "* DONE [#B] Buy milk")
    res = run()
    eq(1, res.pushed)
    local t1 = stored("t1.ics")
    ok(has(t1, "STATUS:COMPLETED"))
    ok(has(t1, "PERCENT-COMPLETE:100"))
    ok(has(t1, "PRIORITY:5"))
    ok(has(t1, "DUE;VALUE=DATE:20261115"))

    -- reopened in the calendar: a TODO again in org
    srv:put("work", "t2.ics", todo("t2", { "SUMMARY:Send report", "STATUS:NEEDS-ACTION", "DUE:20261116T120000Z" }))
    res = run()
    eq(1, res.pulled)
    lines = org()
    ok(has(lines, "* TODO Send report"), vim.inspect(lines))
    ok(has(lines, "DEADLINE: <2026-11-16 Mon 12:00>"), vim.inspect(lines))
  end)
end)

describe("caldav: direction", function()
  before_each(before)
  after_each(after)

  it("pull: the calendar's changes come, org's stay here", function()
    srv:put("work", "a.ics", event("uid-a", { "SUMMARY:Review", "DTSTART:20261112T150000Z" }))
    vim.fn.writefile({ "* Local only", "<2026-11-12 Thu>" }, path)
    setup({ direction = "pull" })
    local res = run()
    eq(1, res.pulled)
    eq(0, res.pushed)
    eq("* Local only", org()[1])
    eq("<2026-11-12 Thu>", org()[2])
    change("* Review", "* Changed here")
    res = run()
    eq(0, res.pushed)
    eq(0, #srv:requests("PUT"))
    srv:put("work", "a.ics", event("uid-a", { "SUMMARY:Review", "DTSTART:20261112T170000Z" }))
    res = run()
    eq(1, res.pulled)
    ok(has(org(), "<2026-11-12 Thu 17:00>"))
    ok(has(org(), "* Changed here"))
  end)

  it("push: org's changes go, the calendar's stay there", function()
    srv:put("work", "a.ics", event("uid-a", { "SUMMARY:Theirs", "DTSTART:20261112T150000Z" }))
    vim.fn.writefile({ "* Mine", "<2026-11-12 Thu>" }, path)
    setup({ direction = "push" })
    local res = run()
    eq(0, res.pulled)
    eq(1, res.pushed)
    eq(2, #srv:files("work"))
    ok(not table.concat(org(), "\n"):find("Theirs", 1, true))
    -- and the event that is not in org is not fetched again
    local before_n = #srv:requests("REPORT")
    run()
    eq(before_n + 1, #srv:requests("REPORT"))
  end)
end)

describe("caldav: safety", function()
  before_each(before)
  after_each(after)

  local function two()
    srv:put("work", "a.ics", event("uid-a", { "SUMMARY:One", "DTSTART:20261112T150000Z" }))
    srv:put("work", "b.ics", event("uid-b", { "SUMMARY:Two", "DTSTART:20261113T150000Z" }))
  end

  it("asks before deleting everything, even with 'always'", function()
    two()
    setup()
    run()
    set({ "" })
    local res = run(true)
    eq(0, res.deleted_remote)
    eq(2, #srv:files("work"))
    local utils = require("org.utils")
    local confirm, asked = utils.confirm, nil
    utils.confirm = function(msg)
      asked = msg
      return true
    end
    res = run()
    utils.confirm = confirm
    ok(asked:find("2 entries were deleted in the org files", 1, true), asked)
    eq(2, res.deleted_remote)
    eq(0, #srv:files("work"))
  end)

  it("keeps an entry with subheadings", function()
    two()
    setup()
    run()
    vim.api.nvim_buf_set_lines(buf(), 5, 5, false, { "** Notes of the meeting" })
    srv:remove("work", "a.ics")
    local res = run()
    eq(0, res.deleted_local)
    ok(res.notes[1]:find("it has subheadings", 1, true), vim.inspect(res.notes))
    eq("* One", org()[1])
  end)

  it("stops at a wrong password, and sends the right one", function()
    srv.opts.user, srv.opts.password = "me", "secret"
    two()
    setup({ user = "me", password = "wrong" })
    local res = run()
    ok(res.failed:find("401", 1, true), res.failed)
    eq(nil, vim.uv.fs_stat(path))
    setup({
      user = "me",
      password = function()
        return "secret"
      end,
    })
    res = run()
    eq(nil, res.failed)
    eq(2, res.pulled)
  end)

  it("sends a bearer token, and reads it again when it stopped working", function()
    srv.opts.token = "tok-2"
    two()
    local n = 0
    setup({
      token = function()
        n = n + 1
        return "tok-" .. n
      end,
    })
    local res = run()
    eq(nil, res.failed)
    eq(2, res.pulled)
    eq(2, n)
  end)

  it("takes the password from a command's first line of output", function()
    srv.opts.user, srv.opts.password = "me", "from the command"
    two()
    local exe = fake_exe(tmp .. "/bin", "print-password", 'echo "from the command"\necho "a second line"\n')
    setup({ user = "me", password = { exe } })
    local res = run()
    eq(nil, res.failed)
    eq(2, res.pulled)
    -- a command that fails says so, and nothing is asked of the server
    local n = #srv.log
    setup({ user = "me", password = { fake_exe(tmp .. "/bin", "no-password", "echo locked >&2\nexit 3\n") } })
    res = run()
    ok(res.failed:find("the password command failed: locked", 1, true), res.failed)
    eq(n, #srv.log)
  end)

  it("keeps the line endings of a file with CRLF, and sends none of them", function()
    local fh = assert(io.open(path, "wb"))
    fh:write("* Dentist\r\n<2026-11-12 Thu 09:00>\r\nBring the x-rays\r\n")
    fh:close()
    srv:put("work", "a.ics", event("uid-a", { "SUMMARY:Review", "DTSTART:20261113T150000Z" }))
    setup()
    local res = run()
    eq(1, res.pulled)
    eq(1, res.pushed)
    eq("dos", vim.bo[buf()].fileformat)
    local id = org()[3]:match("^:ID:%s+(%S+)$")
    ok(id, vim.inspect(org()))
    local sent = srv:get("work", id .. ".ics")
    ok(sent:find("SUMMARY:Dentist\r\n", 1, true), sent)
    ok(sent:find("DTSTART:20261112T090000Z\r\n", 1, true), sent)
    ok(sent:find("DESCRIPTION:Bring the x-rays\r\n", 1, true), sent)
    ok(not sent:find("\r\r", 1, true) and not sent:find("\\r", 1, true), sent)
    fh = assert(io.open(path, "rb"))
    local text = fh:read("*a")
    fh:close()
    ok(text:find("* Review\r\n", 1, true), "the new entry has the file's line endings")
    ok(not text:find("[^\r]\n"), "every line of the file still ends in CRLF")
  end)

  it("fails without asking the server when a file of the calendar is missing", function()
    two()
    setup({ files = { tmp .. "/nope.org" } })
    local res = run()
    ok(res.failed:find("nope.org not found", 1, true), res.failed)
    eq(0, #srv.log)
  end)

  it("learns the etag when the server gives none after a change", function()
    srv.no_etag = true
    vim.fn.writefile({ "* Mine", "<2026-11-12 Thu>" }, path)
    setup()
    local res = run()
    eq(1, res.pushed)
    res = run()
    eq(0, res.pulled + res.pushed)
    eq(1, #srv:requests("PUT"))
  end)
end)

describe("caldav: commands and health", function()
  before_each(before)
  after_each(after)

  it("registers its actions only when on", function()
    setup()
    local actions = require("org.actions").list
    ok(actions.caldav_sync)
    ok(actions.caldav_discover)
    require("org").setup({ extensions = {} })
    eq(nil, actions.caldav_sync)
  end)

  it("lists the calendars of the account", function()
    srv:calendar("tasks", { display = "My tasks", components = { "VTODO" } })
    setup({ url = "http://dav.test/dav/" })
    local lines
    require("org.extensions.caldav").discover(nil, function(l)
      lines = l
    end)
    vim.wait(5000, function()
      return lines ~= nil
    end, 5)
    eq({
      "CalDAV calendars at http://dav.test/dav/",
      "",
      "My tasks",
      "  url    http://dav.test/dav/calendars/me/tasks/",
      "  holds  tasks",
      "",
      "work",
      "  url    http://dav.test/dav/calendars/me/work/",
      "  holds  events, tasks",
      "",
    }, lines)
  end)

  it("reports each calendar in :checkhealth", function()
    setup({ direction = "sideways", todoz = true })
    local out = {}
    local h = {}
    for _, level in ipairs({ "ok", "info", "warn", "error" }) do
      h[level] = function(msg)
        out[#out + 1] = level .. ": " .. msg
      end
    end
    local caldav = require("org.extensions.caldav")
    caldav.health(h, caldav.opts())
    ok(
      out[#out]:find('error: caldav: Work: direction = "sideways" is not one of twoway, pull, push', 1, true),
      vim.inspect(out)
    )
    ok(out[#out]:find("todoz is not an option of a calendar", 1, true), vim.inspect(out))
    setup()
    out = {}
    caldav.health(h, caldav.opts())
    ok(out[#out]:find("not synced yet", 1, true), vim.inspect(out))
    run()
    out = {}
    caldav.health(h, caldav.opts())
    ok(out[#out]:find("ok: caldav: Work: 0 synced, last on ", 1, true), vim.inspect(out))
  end)

  it("syncs one calendar by name from :Org, and says when there is none of that name", function()
    srv:put("work", "a.ics", event("uid-a", { "SUMMARY:Review", "DTSTART:20261112T150000Z" }))
    setup()
    local msgs = {}
    vim.notify = function(msg)
      msgs[#msgs + 1] = msg
    end
    vim.cmd("Org caldav_sync Nope")
    eq({ "caldav: no calendar named Nope" }, msgs)
    vim.cmd("Org caldav_sync Work")
    vim.wait(5000, function()
      return #msgs > 1
    end, 5)
    eq("caldav: Work: 1 from the calendar", msgs[2])
    eq("* Review", org()[1])
  end)

  it("shows the calendars of another address in a window that q closes", function()
    setup()
    require("org.extensions.caldav").discover("http://dav.test/dav/")
    vim.wait(5000, function()
      return vim.api.nvim_buf_get_name(0):find("CalDAV calendars", 1, true) ~= nil
    end, 5)
    eq("CalDAV calendars at http://dav.test/dav/", buf_lines()[1])
    eq("  url    http://dav.test/dav/calendars/me/work/", buf_lines()[4])
    eq(false, vim.bo.modifiable)
    vim.api.nvim_feedkeys("q", "x", false)
    ok(not vim.api.nvim_buf_get_name(0):find("CalDAV calendars", 1, true))
    -- an address that isn't one says why
    local lines
    require("org.extensions.caldav").discover("http://dav.test/nowhere/", function(l)
      lines = l
    end)
    vim.wait(5000, function()
      return lines ~= nil
    end, 5)
    ok(lines[3]:find("Failed: 404", 1, true), vim.inspect(lines))
  end)

  it("tells the name of the zone from the option or $TZ", function()
    local caldav = require("org.extensions.caldav")
    setup(nil, { timezone = "Europe/Paris" })
    eq("Europe/Paris", caldav.zone_name())
    setup(nil, { timezone = "No/Such_Zone" })
    eq(nil, caldav.zone_name())
    local tz = vim.env.TZ
    setup(nil, { timezone = vim.NIL })
    require("org.extensions").opts("caldav").timezone = nil
    vim.env.TZ = ":America/New_York"
    eq("America/New_York", caldav.zone_name())
    vim.env.TZ = tz
  end)
end)

describe("caldav: in the background", function()
  before_each(before)
  after_each(after)

  it("syncs on the timer's tick without asking, with one line of message", function()
    srv:put("work", "a.ics", event("uid-a", { "SUMMARY:Review", "DTSTART:20261112T150000Z" }))
    srv:put("work", "b.ics", event("uid-b", { "SUMMARY:Other", "DTSTART:20261113T150000Z" }))
    setup({ delete_remote = "ask" }, { interval = 5 })
    local msgs = {}
    vim.notify = function(msg, level)
      msgs[#msgs + 1] = { msg, level }
    end
    local function tick()
      require("org.extensions.caldav")._tick()
      vim.wait(5000, function()
        return not sync.running()
      end, 5)
    end
    tick()
    eq({ { "caldav: Work: 2 from the calendar", vim.log.levels.INFO } }, msgs)
    -- nothing changed: nothing said
    tick()
    eq(1, #msgs)
    -- a deletion that needs an answer waits, and is mentioned in one line
    vim.api.nvim_buf_set_lines(buf(), 0, 4, false, {})
    change("* Other", "* Other one")
    tick()
    eq("caldav: Work: 1 to the calendar (1 note: :Org caldav_sync shows them)", msgs[2][1])
    eq(2, #srv:files("work"))
    -- a failure is said once
    srv.fail = function()
      return 500
    end
    tick()
    tick()
    eq(3, #msgs)
    eq({ "caldav: Work: HTTP 500", vim.log.levels.WARN }, msgs[3])
  end)

  it("says a sync is running instead of starting a second one", function()
    setup()
    local msgs = {}
    vim.notify = function(msg)
      msgs[#msgs + 1] = msg
    end
    local done = 0
    sync.run(nil, {
      done = function()
        done = done + 1
      end,
    })
    sync.run(nil, {
      done = function(r)
        eq(nil, r)
        done = done + 1
      end,
    })
    vim.wait(5000, function()
      return done == 2 and not sync.running()
    end, 5)
    eq("caldav: a sync is already running", msgs[1])
  end)
end)

describe("caldav: matching and coming back", function()
  before_each(before)
  after_each(after)

  it("fills what one side lacks when an entry and an event meet for the first time", function()
    srv:put(
      "work",
      "a.ics",
      event("uid-a", { "SUMMARY:Review", "DTSTART:20261112T150000Z", "DESCRIPTION:from the calendar" })
    )
    vim.fn.writefile(
      { "* Review", ":PROPERTIES:", ":ID: uid-a", ":LOCATION: Room 4", ":END:", "<2026-11-12 Thu 15:00>" },
      path
    )
    setup()
    local res = run()
    eq(0, res.conflicts)
    eq(1, res.pulled)
    eq(1, res.pushed)
    eq("from the calendar", org()[7])
    ok(has(stored("a.ics"), "LOCATION:Room 4"))
    ok(has(stored("a.ics"), "DESCRIPTION:from the calendar"))
  end)

  it("puts an event back that was deleted in the calendar and changed in org", function()
    srv:put("work", "a.ics", event("uid-a", { "SUMMARY:Review", "DTSTART:20261112T150000Z" }))
    srv:put("work", "b.ics", event("uid-b", { "SUMMARY:Other", "DTSTART:20261113T150000Z" }))
    setup()
    run()
    srv:remove("work", "a.ics")
    change("* Review", "* Review, again")
    local res = run()
    eq(0, res.deleted_local)
    eq(1, res.pushed)
    eq({ "b.ics", "uid-a.ics" }, srv:files("work"))
    ok(has(stored("uid-a.ics"), "SUMMARY:Review\\, again"))
    eq(0, run().pushed)
  end)

  it("brings an entry back that was deleted in org and changed in the calendar", function()
    srv:put("work", "a.ics", event("uid-a", { "SUMMARY:Review", "DTSTART:20261112T150000Z" }))
    srv:put("work", "b.ics", event("uid-b", { "SUMMARY:Other", "DTSTART:20261113T150000Z" }))
    setup()
    run()
    vim.api.nvim_buf_set_lines(buf(), 0, 5, false, {})
    srv:put("work", "a.ics", event("uid-a", { "SUMMARY:Review moved", "DTSTART:20261114T150000Z" }))
    local res = run()
    eq(0, res.deleted_remote)
    eq(1, res.pulled)
    eq("* Review moved", org()[6])
    eq(2, #srv:files("work"))
  end)

  it("forgets a state file it can't read and matches by ID again", function()
    srv:put("work", "a.ics", event("uid-a", { "SUMMARY:Review", "DTSTART:20261112T150000Z" }))
    setup()
    run()
    local file = sync.state_file(require("org.extensions.caldav").calendars()[1])
    vim.fn.writefile({ '{"version":1,"items":{"uid-a":{"href":"/x"}},"skipped":[]}' }, file)
    local res = run()
    eq(nil, res.failed)
    eq(0, res.pulled + res.pushed)
    eq(5, #org())
    vim.fn.writefile({ "not json" }, file)
    eq(nil, run().failed)
    eq(5, #org())
  end)

  it("leaves old entries and tasks closed long ago where they are", function()
    srv:put(
      "work",
      "t.ics",
      ics("VTODO", "t-old", { "SUMMARY:Done long ago", "STATUS:COMPLETED", "COMPLETED:20260301T100000Z" })
    )
    vim.fn.writefile({
      "* Last year",
      "<2025-11-12 Wed>",
      "* DONE Old task",
      "CLOSED: [2026-01-05 Mon 10:00]",
      "* Every year",
      "<2020-11-20 Fri +1y>",
    }, path)
    setup({ todos = true })
    local res = run()
    eq(0, res.pulled)
    eq(1, res.pushed)
    local text = table.concat(org(), "\n")
    ok(not text:find("Done long ago", 1, true))
    ok(text:find("* Every year\n:PROPERTIES:", 1, true), text)
    ok(not text:find("* Last year\n:PROPERTIES:", 1, true), text)
    -- everything, with past_days = false
    setup({ todos = true, past_days = false })
    res = run()
    eq(1, res.pulled)
    eq(2, res.pushed)
  end)

  it("syncs the first of two entries with the same ID and says so", function()
    vim.fn.writefile({
      "* One",
      ":PROPERTIES:",
      ":ID: same",
      ":END:",
      "<2026-11-12 Thu>",
      "* Two",
      ":PROPERTIES:",
      ":ID: same",
      ":END:",
      "<2026-11-13 Fri>",
    }, path)
    setup()
    local res = run()
    eq(1, res.pushed)
    ok(res.notes[1]:find("two entries have the ID same", 1, true), vim.inspect(res.notes))
    ok(has(stored("same.ics"), "SUMMARY:One"))
  end)
end)
