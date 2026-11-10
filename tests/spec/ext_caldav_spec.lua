-- The caldav extension's parts: WebDAV replies and requests, calendar
-- components as fields, org entries as fields. The sync itself is in
-- ext_caldav_sync_spec.lua.
local http = require("org.extensions.caldav.http")
local ical = require("org.extensions.caldav.ical")
local entry = require("org.extensions.caldav.entry")
local parser = require("org.extensions.ics.parser")
local date = require("org.date")

local function day(s)
  return date.parse("<" .. s .. ">"):days()
end

--- A context: timestamps in `zone`, occurrences listed for November 2026.
local function ctx(zone)
  return {
    timezone = zone or "Europe/Paris",
    tz_aliases = {},
    zone_name = zone or "Europe/Paris",
    from = day("2026-11-01"),
    to = day("2026-11-30"),
    now = parser.naive(2026, 11, 10, 12, 0, 0),
  }
end

local function ics(kind, props)
  local lines = { "BEGIN:VCALENDAR", "VERSION:2.0", "BEGIN:" .. kind }
  vim.list_extend(lines, props)
  vim.list_extend(lines, { "END:" .. kind, "END:VCALENDAR" })
  return table.concat(lines, "\r\n") .. "\r\n"
end

local function has(text, line)
  return vim.tbl_contains(parser.unfold(text), line)
end

describe("caldav http: xml", function()
  it("reads elements whatever their prefix, with attributes, CDATA and entities", function()
    local root = http.xml(table.concat({
      '<?xml version="1.0"?>',
      "<!-- a comment -->",
      '<D:multistatus xmlns:D="DAV:"><D:response a:kind="x &amp; y">',
      "<d:href>/a%20b/</d:href><empty/>",
      "<data><![CDATA[BEGIN:<&>]]></data><t>1 &lt; 2 &#233; &#x41;</t>",
      "</D:response></D:multistatus>",
    }, "\n"))
    local r = http.find(root, "response")
    eq("x & y", r.attrs.kind)
    eq("/a%20b/", http.child(r, "href").text)
    eq("BEGIN:<&>", http.child(r, "data").text)
    eq("1 < 2 é A", http.child(r, "t").text)
    eq({}, http.child(r, "empty").children)
  end)

  it("reads a multistatus: properties found, statuses, hrefs made alike", function()
    local body = [[
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">
 <d:response>
  <d:href>/dav/me@x.org/cal/a.ics</d:href>
  <d:propstat><d:prop><d:getetag>&quot;e1&quot;</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  <d:propstat><d:prop><cal:calendar-data/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
 </d:response>
 <d:response><d:href>http://host/dav/me%40x.org/cal/b.ics</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>
</d:multistatus>]]
    local list = http.multistatus(body)
    eq(2, #list)
    eq("/dav/me%40x.org/cal/a.ics", list[1].href)
    eq('"e1"', vim.trim(list[1].props.getetag.text))
    eq(nil, list[1].props["calendar-data"])
    eq("/dav/me%40x.org/cal/b.ics", list[2].href)
    eq(404, list[2].status)
  end)
end)

describe("caldav http: requests", function()
  it("spells a path one way and builds hrefs for new resources", function()
    eq("/dav/a%40b/x%20y.ics", http.path("https://h:8443/dav/a%40b/x y.ics?q=1"))
    eq("/dav/a%40b/", http.path("/dav/a@b/"))
    eq("/", http.path("https://host"))
    eq("https://h:8443", http.origin("https://h:8443/dav/"))
    eq("https://h/dav/x.ics", http.resolve("https://h/other/", "/dav/x.ics"))
    eq("/cal/8c3a2f7e-1.ics", http.href_for("https://h/cal", "8c3a2f7e-1"))
    local odd = http.href_for("https://h/cal/", "a b/c@d")
    ok(odd:match("^/cal/%x+%.ics$"), odd)
  end)

  it("gives curl the credentials in its config, quoted", function()
    local config = http.curl_config({
      method = "PUT",
      url = "https://h/cal/x.ics",
      headers = { 'If-Match: "e1"' },
      user = "me",
      password = 'pa"ss\\word',
      auth = "digest",
      timeout = 20,
    }, { body = "/tmp/b", out = "/tmp/o", headers = "/tmp/h" })
    local lines = vim.split(config, "\n")
    ok(vim.tbl_contains(lines, 'user = "me:pa\\"ss\\\\word"'), config)
    ok(vim.tbl_contains(lines, "digest"))
    ok(vim.tbl_contains(lines, 'request = "PUT"'))
    ok(vim.tbl_contains(lines, 'header = "If-Match: \\"e1\\""'))
    ok(vim.tbl_contains(lines, 'data-binary = "@/tmp/b"'))
    ok(vim.tbl_contains(lines, "max-time = 20"))
    ok(not vim.tbl_contains(lines, "location"))
  end)

  it("reads the headers of the last reply", function()
    local h = http.parse_headers(
      'HTTP/1.1 301 Moved\r\nLocation: /x\r\n\r\nHTTP/1.1 201 Created\r\nETag: "e9"\r\nX-A:  b \r\n\r\n'
    )
    eq({ etag = '"e9"', ["x-a"] = "b" }, h)
  end)

  it("runs curl with the config on stdin: no password among its arguments", function()
    local dir = vim.fs.normalize(vim.fn.tempname())
    local exe = fake_exe(dir, "curl", 'd=$(dirname "$0")\necho "$@" > "$d/args"\ncat > "$d/config"\nprintf 207\n')
    local reply, err
    http.transport(
      { method = "PROPFIND", url = "http://h/", user = "me", password = "hunter2", curl = { exe, "--netrc" } },
      function(r, e)
        reply, err = r or false, e
      end
    )
    vim.wait(10000, function()
      return reply ~= nil
    end, 5)
    eq(nil, err)
    eq(207, reply.status)
    eq("--netrc --config -", vim.trim(table.concat(vim.fn.readfile(dir .. "/args"), " ")))
    ok(table.concat(vim.fn.readfile(dir .. "/config"), "\n"):find('user = "me:hunter2"', 1, true))
  end)

  it("says so when curl is missing", function()
    local reply, err
    http.transport({ method = "GET", url = "http://h/", curl = { "no-such-curl-program" } }, function(r, e)
      reply, err = r or false, e
    end)
    vim.wait(5000, function()
      return reply ~= nil
    end, 5)
    eq("no-such-curl-program not found", err)
  end)
end)

describe("caldav ical: reading", function()
  it("gives times in the display zone", function()
    local r = ical.read(
      ics("VEVENT", {
        "UID:a",
        "SUMMARY:Call\\, with  Ana",
        "DTSTART;TZID=America/New_York:20261112T100000",
        "DTEND;TZID=America/New_York:20261112T110000",
        "LOCATION:Room 1\\nSecond floor",
        "DESCRIPTION:one  \\n\\ntwo\\n",
      }),
      ctx()
    )
    eq("a", r.uid)
    eq("VEVENT", r.type)
    eq({
      summary = "Call, with  Ana",
      time = "2026-11-12 16:00-17:00",
      location = "Room 1, Second floor",
      description = "one\n\ntwo",
    }, r.fields)
    eq({}, r.ro)
  end)

  it("writes each kind of span as a key", function()
    local function key(props)
      local list = { "UID:a" }
      vim.list_extend(list, props)
      return ical.read(ics("VEVENT", list), ctx("UTC")).fields.time
    end
    eq("2026-11-12", key({ "DTSTART;VALUE=DATE:20261112" }))
    eq("2026-11-12", key({ "DTSTART;VALUE=DATE:20261112", "DTEND;VALUE=DATE:20261113" }))
    eq("2026-11-12--2026-11-14", key({ "DTSTART;VALUE=DATE:20261112", "DTEND;VALUE=DATE:20261115" }))
    eq("2026-11-12 10:00", key({ "DTSTART:20261112T100000Z" }))
    eq("2026-11-12 10:00-10:45", key({ "DTSTART:20261112T100000Z", "DURATION:PT45M" }))
    eq("2026-11-12 22:00--2026-11-13 02:00", key({ "DTSTART:20261112T220000Z", "DTEND:20261113T020000Z" }))
    eq("2026-11-12 10:00", key({ "DTSTART:20261112T100000" }))
  end)

  it("reads a rule a repeater can say as one, and no other", function()
    local start = parser.naive(2026, 11, 12, 10, 0, 0) -- a Thursday
    local function rep(rule)
      local r = ical.repeater(parser.rrule(rule), start)
      return r and (r.value .. r.unit) or nil
    end
    eq("1d", rep("FREQ=DAILY"))
    eq("3d", rep("FREQ=DAILY;INTERVAL=3"))
    eq("1w", rep("FREQ=WEEKLY;BYDAY=TH;WKST=SU"))
    eq("2w", rep("FREQ=WEEKLY;INTERVAL=2"))
    eq("1m", rep("FREQ=MONTHLY;BYMONTHDAY=12"))
    eq("1y", rep("FREQ=YEARLY;BYMONTH=11;BYMONTHDAY=12"))
    eq("4h", rep("FREQ=HOURLY;INTERVAL=4"))
    eq(nil, rep("FREQ=WEEKLY;BYDAY=FR"))
    eq(nil, rep("FREQ=WEEKLY;BYDAY=TU,TH"))
    eq(nil, rep("FREQ=MONTHLY;BYDAY=2TH"))
    eq(nil, rep("FREQ=MONTHLY;BYMONTHDAY=13"))
    eq(nil, rep("FREQ=DAILY;COUNT=5"))
    eq(nil, rep("FREQ=DAILY;UNTIL=20261201T000000Z"))
    eq(nil, rep("FREQ=MINUTELY"))
  end)

  it("reads a changed instance with its event, and an event with exceptions as its occurrences", function()
    local text = table.concat({
      "BEGIN:VCALENDAR",
      "BEGIN:VEVENT",
      "UID:a",
      "RECURRENCE-ID:20261119T100000Z",
      "SUMMARY:Moved",
      "DTSTART:20261119T140000Z",
      "DTEND:20261119T150000Z",
      "END:VEVENT",
      "BEGIN:VEVENT",
      "UID:a",
      "SUMMARY:Weekly",
      "DTSTART:20261112T100000Z",
      "DTEND:20261112T110000Z",
      "RRULE:FREQ=WEEKLY",
      "END:VEVENT",
      "END:VCALENDAR",
    }, "\r\n")
    local r = ical.read(text, ctx("UTC"))
    eq("Weekly", r.fields.summary)
    eq("2026-11-12 10:00-11:00\n2026-11-19 14:00-15:00\n2026-11-26 10:00-11:00", r.fields.time)
    eq({ time = true }, r.ro)
  end)

  it("reads a task", function()
    local r = ical.read(
      ics("VTODO", {
        "UID:t",
        "SUMMARY:Pay rent",
        "DTSTART;VALUE=DATE:20261101",
        "DUE:20261105T170000Z",
        "RRULE:FREQ=MONTHLY",
        "PRIORITY:6",
        "STATUS:IN-PROCESS",
      }),
      ctx()
    )
    eq("VTODO", r.type)
    eq({
      summary = "Pay rent",
      scheduled = "2026-11-01 +1m",
      deadline = "2026-11-05 18:00 +1m",
      status = "todo",
      priority = "5",
      location = "",
      description = "",
    }, r.fields)
    local done = ical.read(ics("VTODO", { "UID:t", "SUMMARY:x", "COMPLETED:20261109T101500Z" }), ctx("UTC"))
    eq("done", done.fields.status)
    eq("2026-11-09 10:15", done.fields._completed)
    eq("cancelled", ical.read(ics("VTODO", { "UID:t", "STATUS:CANCELLED" }), ctx()).fields.status)
  end)

  it("refuses what holds no event or task, or no UID", function()
    local r, err = ical.read("BEGIN:VCALENDAR\r\nBEGIN:VJOURNAL\r\nUID:j\r\nEND:VJOURNAL\r\nEND:VCALENDAR\r\n", ctx())
    eq(nil, r)
    eq("no event or task in it", err)
    r, err = ical.read(ics("VEVENT", { "DTSTART:20261112T100000Z" }), ctx())
    eq(nil, r)
    eq("no UID", err)
  end)
end)

describe("caldav ical: keys", function()
  it("turns a timestamp into a key and back", function()
    local cases = {
      ["<2026-11-12 Thu>"] = "2026-11-12",
      ["<2026-11-12 Thu 10:00>"] = "2026-11-12 10:00",
      ["<2026-11-12 Thu 10:00-11:30>"] = "2026-11-12 10:00-11:30",
      ["<2026-11-12 Thu 10:00-11:30 +1w>"] = "2026-11-12 10:00-11:30 +1w",
      ["<2026-11-12 Thu>--<2026-11-14 Sat>"] = "2026-11-12--2026-11-14",
      ["<2026-11-12 Thu 22:00>--<2026-11-13 Fri 02:00>"] = "2026-11-12 22:00--2026-11-13 02:00",
    }
    for stamp, key in pairs(cases) do
      eq(key, ical.date_key(date.parse(stamp)), stamp)
      eq(stamp, ical.key_date(key):to_string(), key)
    end
    -- other ways to write the same time
    eq("2026-11-12 10:00-11:00", ical.date_key(date.parse("<2026-11-12 Thu 10:00>--<2026-11-12 Thu 11:00>")))
    eq("2026-11-12 +2d", ical.date_key(date.parse("<2026-11-12 Thu .+2d -1d>")))
    eq("2026-11-12 10:00 +1w", ical.point_key(date.parse("<2026-11-12 Thu 10:00-11:00 ++1w>")))
  end)
end)

describe("caldav ical: writing", function()
  local base = ics("VEVENT", {
    "UID:a",
    "SEQUENCE:2",
    "SUMMARY:Old",
    "DTSTART;TZID=America/New_York:20261112T100000",
    "DURATION:PT1H",
    "DESCRIPTION:old text",
    "X-ALT-DESC;FMTTYPE=text/html:<p>old text</p>",
    "ATTENDEE;CN=Ana:mailto:ana@example.com",
    "BEGIN:VALARM",
    "ACTION:DISPLAY",
    "DESCRIPTION:Reminder",
    "TRIGGER:-PT10M",
    "END:VALARM",
  })

  it("replaces only the properties of the changed fields", function()
    local out = ical.patch(
      base,
      "VEVENT",
      { summary = "New; title, here", description = "" },
      { summary = true, description = true },
      ctx()
    )
    ok(has(out, "SUMMARY:New\\; title\\, here"))
    ok(not out:find("DESCRIPTION:old text", 1, true))
    ok(not out:find("X-ALT-DESC", 1, true))
    ok(has(out, "DESCRIPTION:Reminder"), "the alarm's own description stays")
    ok(has(out, "DTSTART;TZID=America/New_York:20261112T100000"))
    ok(has(out, "DURATION:PT1H"))
    ok(has(out, "SEQUENCE:2"))
    ok(has(out, "ATTENDEE;CN=Ana:mailto:ana@example.com"))
    ok(has(out, "LAST-MODIFIED:20261110T120000Z"))
    ok(out:find("\r\nEND:VCALENDAR\r\n$"))
  end)

  it("writes a new time in the zone the event has", function()
    local out = ical.patch(base, "VEVENT", { time = "2026-11-13 09:30-10:00" }, { time = true }, ctx())
    ok(has(out, "DTSTART;TZID=America/New_York:20261113T033000"))
    ok(has(out, "DTEND;TZID=America/New_York:20261113T040000"))
    ok(not out:find("DURATION", 1, true))
    ok(has(out, "SEQUENCE:3"))
    -- all day, and several days
    out = ical.patch(base, "VEVENT", { time = "2026-11-13--2026-11-15" }, { time = true }, ctx())
    ok(has(out, "DTSTART;VALUE=DATE:20261113"))
    ok(has(out, "DTEND;VALUE=DATE:20261116"))
    -- a floating time stays floating, a UTC one UTC
    local floating = ics("VEVENT", { "UID:a", "DTSTART:20261112T100000" })
    ok(
      has(
        ical.patch(floating, "VEVENT", { time = "2026-11-13 09:30" }, { time = true }, ctx()),
        "DTSTART:20261113T093000"
      )
    )
    local utc = ics("VEVENT", { "UID:a", "DTSTART:20261112T100000Z" })
    ok(
      has(ical.patch(utc, "VEVENT", { time = "2026-11-13 09:30" }, { time = true }, ctx()), "DTSTART:20261113T083000Z")
    )
  end)

  it("folds long lines between characters", function()
    local long = string.rep("añ ", 60)
    local out = ical.patch(base, "VEVENT", { description = long }, { description = true }, ctx())
    for line in out:gmatch("[^\r\n]+") do
      ok(#line <= 75, line)
      ok(vim.fn.strchars(line) > 0 and vim.str_utfindex(line, "utf-8") ~= nil)
    end
    eq(vim.trim(long), ical.read(out, ctx()).fields.description)
  end)

  it("builds a new event that reads back as the same fields", function()
    local fields = {
      summary = "Weekly sync",
      time = "2026-11-12 16:00-17:00 +1w",
      location = "Room 4",
      description = "Agenda:\n- one\n- two",
    }
    local out = ical.build("VEVENT", "uid-1", fields, ctx())
    ok(has(out, "UID:uid-1"))
    ok(has(out, "PRODID:-//org.nvim//caldav//EN"))
    -- a repeating time is in the display zone, which is defined
    ok(has(out, "DTSTART;TZID=Europe/Paris:20261112T160000"))
    ok(has(out, "RRULE:FREQ=WEEKLY"))
    ok(has(out, "TZID:Europe/Paris"))
    ok(has(out, "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU"))
    ok(has(out, "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU"))
    ok(out:find("BEGIN:VTIMEZONE", 1, true) < out:find("BEGIN:VEVENT", 1, true))
    eq(fields, ical.read(out, ctx()).fields)
    -- one that doesn't repeat is in UTC
    fields.time = "2026-11-12 16:00-17:00"
    out = ical.build("VEVENT", "uid-1", fields, ctx())
    ok(has(out, "DTSTART:20261112T150000Z"))
    ok(not out:find("VTIMEZONE", 1, true))
    eq(fields, ical.read(out, ctx()).fields)
  end)

  it("builds a task that reads back as the same fields", function()
    local fields = {
      summary = "Pay rent",
      scheduled = "2026-11-01 +1m",
      deadline = "2026-11-05 18:00 +1m",
      status = "done",
      priority = "1",
      location = "",
      description = "",
      _closed = "2026-11-04 09:00",
    }
    local out = ical.build("VTODO", "t-1", fields, ctx("UTC"))
    ok(has(out, "DTSTART;VALUE=DATE:20261101"))
    ok(has(out, "DUE:20261105T180000Z"))
    ok(has(out, "RRULE:FREQ=MONTHLY"))
    ok(has(out, "STATUS:COMPLETED"))
    ok(has(out, "COMPLETED:20261104T090000Z"))
    ok(has(out, "PRIORITY:1"))
    local back = ical.read(out, ctx("UTC")).fields
    eq("2026-11-04 09:00", back._completed)
    back._completed, fields._closed = nil, nil
    eq(fields, back)
  end)

  it("writes the definition of a zone from its rule", function()
    eq({
      "BEGIN:VTIMEZONE",
      "TZID:America/New_York",
      "BEGIN:DAYLIGHT",
      "DTSTART:19700308T020000",
      "TZOFFSETFROM:-0500",
      "TZOFFSETTO:-0400",
      "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU",
      "END:DAYLIGHT",
      "BEGIN:STANDARD",
      "DTSTART:19701101T020000",
      "TZOFFSETFROM:-0400",
      "TZOFFSETTO:-0500",
      "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU",
      "END:STANDARD",
      "END:VTIMEZONE",
    }, ical.vtimezone("America/New_York"))
    eq(nil, ical.vtimezone("No/Such_Zone"))
  end)
end)

describe("caldav entry", function()
  local function read(lines, kind)
    local buf = org_buffer(lines)
    local file = require("org.files").get_buffer(buf)
    return entry.read(file, file.headlines[1], kind or "VEVENT")
  end

  it("reads an event: its timestamp lines, and the text below as the description", function()
    local fields, layout = read({
      "* Review :work:",
      "  :PROPERTIES:",
      "  :ID: a",
      "  :LOCATION: Room 4",
      "  :END:",
      "  :LOGBOOK:",
      "  - Note taken on [2026-11-01 Sun 10:00]",
      "  :END:",
      "  <2026-11-12 Thu 15:00-16:00>",
      "",
      "  Bring the mockups",
      "    indented more",
      "",
      "* Next",
    })
    eq({
      summary = "Review",
      time = "2026-11-12 15:00-16:00",
      location = "Room 4",
      description = "Bring the mockups\n  indented more",
    }, fields)
    eq("block", layout.src)
  end)

  it("finds the time in the heading, in the text, or in the planning line", function()
    local fields, layout = read({ "* Lunch <2026-11-12 Thu 12:00> :food:", "with Ana" })
    eq("Lunch", fields.summary)
    eq("2026-11-12 12:00", fields.time)
    eq("inline", layout.src)
    eq("with Ana", fields.description)
    fields, layout = read({ "* Trip", "We leave on <2026-11-20 Fri> early." })
    eq("2026-11-20", fields.time)
    eq("inline", layout.src)
    fields, layout = read({ "* Standup", "SCHEDULED: <2026-11-11 Wed 09:00 +1d>" })
    eq("2026-11-11 09:00 +1d", fields.time)
    eq("scheduled", layout.src)
    fields = read({ "* Nothing", "[2026-11-11 Wed]" })
    eq("", fields.time)
  end)

  it("says what a new entry would sync as", function()
    local function kind(lines, todos)
      local buf = org_buffer(lines)
      local file = require("org.files").get_buffer(buf)
      return entry.kind(file, file.headlines[1], todos)
    end
    eq("VEVENT", kind({ "* A", "<2026-11-12 Thu>" }, false))
    eq("VEVENT", kind({ "* A", "DEADLINE: <2026-11-12 Thu>" }, false))
    eq(nil, kind({ "* TODO A", "DEADLINE: <2026-11-12 Thu>" }, false))
    eq("VTODO", kind({ "* TODO A", "DEADLINE: <2026-11-12 Thu>" }, true))
    eq("VTODO", kind({ "* DONE A" }, true))
    eq("VEVENT", kind({ "* TODO A <2026-11-12 Thu>" }, false))
    eq(nil, kind({ "* A", "[2026-11-12 Thu]" }, true))
    eq(nil, kind({ "* A", ":PROPERTIES:", ":CREATED: <2026-11-12 Thu>", ":END:" }, true))
  end)

  it("leaves out comments and archived subtrees", function()
    local buf = org_buffer({ "* COMMENT A", "* B :ARCHIVE:", "** C", "* D" })
    local hls = require("org.files").get_buffer(buf).headlines
    eq({ true, true, true, false }, vim.tbl_map(entry.excluded, hls))
  end)

  it("writes changed fields and nothing else", function()
    local buf = org_buffer({
      "* TODO [#A] Review :work:",
      ":PROPERTIES:",
      ":ID:       a",
      ":LOCATION: Room 4",
      ":END:",
      "<2026-11-12 Thu 15:00-16:00 -1d>",
      "",
      "Old text",
      "",
      "* Next",
    })
    entry.apply(buf, "a", "VEVENT", {
      summary = "Design review",
      time = "2026-11-13 10:00-11:00",
      location = "",
      description = "New text\n* not a heading\n\nlast",
    }, { summary = true, time = true, location = true, description = true })
    eq({
      "* TODO [#A] Design review                                              :work:",
      ":PROPERTIES:",
      ":ID:       a",
      ":END:",
      "<2026-11-13 Fri 10:00-11:00 -1d>",
      "",
      "New text",
      " * not a heading",
      "",
      "last",
      "",
      "* Next",
    }, buf_lines(buf))
    -- a description taken away, then given to an entry that had none
    entry.apply(buf, "a", "VEVENT", { description = "" }, { description = true })
    eq("* Next", buf_lines(buf)[8])
    entry.apply(buf, "a", "VEVENT", { description = "back" }, { description = true })
    eq({ "<2026-11-13 Fri 10:00-11:00 -1d>", "back", "", "", "* Next" }, vim.list_slice(buf_lines(buf), 5, 9))
  end)

  it("writes the time where it was: in the heading, or the planning line", function()
    local buf = org_buffer({ "* Lunch <2026-11-12 Thu 12:00> :food:", ":PROPERTIES:", ":ID: a", ":END:" })
    entry.apply(
      buf,
      "a",
      "VEVENT",
      { time = "2026-11-13 13:00", summary = "Lunch out" },
      { time = true, summary = true }
    )
    ok(buf_lines(buf)[1]:match("^%* Lunch out <2026%-11%-13 Fri 13:00>%s+:food:$"), buf_lines(buf)[1])
    buf = org_buffer({ "* Standup", "SCHEDULED: <2026-11-11 Wed 09:00 .+1d>", ":PROPERTIES:", ":ID: a", ":END:" })
    entry.apply(buf, "a", "VEVENT", { time = "2026-11-12 09:30 +1d" }, { time = true })
    eq("SCHEDULED: <2026-11-12 Thu 09:30 .+1d>", buf_lines(buf)[2])
    -- several dates don't fit there: they get lines of their own
    entry.apply(buf, "a", "VEVENT", { time = "2026-11-12 09:30\n2026-11-14 09:30" }, { time = true })
    eq(
      { "* Standup", ":PROPERTIES:", ":ID: a", ":END:", "<2026-11-12 Thu 09:30>", "<2026-11-14 Sat 09:30>" },
      buf_lines(buf)
    )
    entry.apply(buf, "a", "VEVENT", { time = "2026-11-15 10:00" }, { time = true })
    eq({ "* Standup", ":PROPERTIES:", ":ID: a", ":END:", "<2026-11-15 Sun 10:00>" }, buf_lines(buf))
  end)

  it("writes a task's state, priority and dates", function()
    local buf = org_buffer({ "* TODO Pay rent", "DEADLINE: <2026-11-05 Thu -2d>", ":PROPERTIES:", ":ID: t", ":END:" })
    entry.apply(buf, "t", "VTODO", {
      status = "done",
      priority = "9",
      scheduled = "2026-11-01",
      deadline = "2026-11-06 17:00",
      _completed = "2026-11-04 09:00",
    }, { status = true, priority = true, scheduled = true, deadline = true })
    eq({
      "* DONE [#C] Pay rent",
      "CLOSED: [2026-11-04 Wed 09:00] DEADLINE: <2026-11-06 Fri 17:00 -2d> SCHEDULED: <2026-11-01 Sun>",
      ":PROPERTIES:",
      ":ID: t",
      ":END:",
    }, buf_lines(buf))
    entry.apply(
      buf,
      "t",
      "VTODO",
      { status = "todo", priority = "", deadline = "" },
      { status = true, priority = true, deadline = true }
    )
    eq({ "* TODO Pay rent", "SCHEDULED: <2026-11-01 Sun>", ":PROPERTIES:", ":ID: t", ":END:" }, buf_lines(buf))
    local file = require("org.files").get_buffer(buf)
    eq({
      summary = "Pay rent",
      scheduled = "2026-11-01",
      deadline = "",
      status = "todo",
      priority = "",
      location = "",
      description = "",
    }, (entry.read(file, file.headlines[1], "VTODO")))
  end)

  it("uses a cancelled keyword for a cancelled task when the file has one", function()
    local buf = org_buffer({ "#+TODO: TODO | DONE CANCELLED", "* TODO A", ":PROPERTIES:", ":ID: t", ":END:" })
    entry.apply(buf, "t", "VTODO", { status = "cancelled" }, { status = true })
    eq("* CANCELLED A", buf_lines(buf)[2])
    local file = require("org.files").get_buffer(buf)
    eq("cancelled", (entry.read(file, file.headlines[1], "VTODO")).status)
  end)

  it("deletes an entry, but not one with subheadings", function()
    local buf =
      org_buffer({ "* A", ":PROPERTIES:", ":ID: a", ":END:", "* B", ":PROPERTIES:", ":ID: b", ":END:", "** C" })
    eq(true, (entry.delete(buf, "a")))
    local done, why = entry.delete(buf, "b")
    eq(false, done)
    eq("it has subheadings", why)
    eq({ "* B", ":PROPERTIES:", ":ID: b", ":END:", "** C" }, buf_lines(buf))
  end)
end)
