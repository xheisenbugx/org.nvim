-- org-icalendar-include-sexps: diary sexps become VEVENTs. Expected
-- components from Emacs Org 9.8.10 on Emacs 31.1 (diary-icalendar), run on
-- 2026-09-28; the UID (Emacs 31 ignores Org's), DTSTAMP and the time zone
-- of timed events are left out of the comparison.
local ical = require("org.export.icalendar")
local config = require("org.config")

local function events(lines)
  local out = ical.to_string(lines, { body_only = true })
  local list = {}
  for ev in out:gmatch("BEGIN:VEVENT\n(.-)END:VEVENT") do
    local kept = {}
    for l in ev:gmatch("[^\n]+") do
      if not l:match("^DTSTAMP:") and not l:match("^UID:") then
        kept[#kept + 1] = (l:gsub("^DTSTART;TZID=[^:]*:", "DTSTART:"))
      end
    end
    list[#list + 1] = kept
  end
  return list, out
end

describe("icalendar diary sexps (Emacs parity)", function()
  before_each(function()
    config.opts.babel.evaluate_on_export = false
    ical.reference_year = 2026
  end)
  after_each(function()
    ical.reference_year = nil
    config.opts.export.icalendar.include_sexps = true
  end)

  it("converts the calendar sexps", function()
    local got = events({
      "* Birthday",
      "%%(diary-anniversary 5 10 1980) Bob turns %d",
      "* Block",
      "%%(diary-block 3 1 2026 3 5 2026) blk",
      "* Cyclic",
      "%%(diary-cyclic 7 1 5 2026) Weekly thing",
      "* Float",
      "%%(diary-float t 4 2) Second Thursday",
      "* Date",
      "%%(diary-date 12 25 t) Xmas",
      "* A",
      "%%(diary-float 11 4 4) Thanksgiving",
      "* B",
      "%%(diary-date 7 4 2026) Once",
      "* C",
      "%%(diary-date t 15 t) Mid month",
      "* D",
      "%%(diary-float t 1 -1) Last Monday",
    })
    eq({
      { "SUMMARY:Bob turns %d", "DESCRIPTION:Bob turns %d", "RRULE:FREQ=YEARLY", "DTSTART;VALUE=DATE:19800510" },
      { "SUMMARY:blk", "DESCRIPTION:blk", "RRULE:FREQ=DAILY;UNTIL=20260305", "DTSTART;VALUE=DATE:20260301" },
      {
        "SUMMARY:Weekly thing",
        "DESCRIPTION:Weekly thing",
        "RRULE:FREQ=DAILY;INTERVAL=7",
        "DTSTART;VALUE=DATE:20260105",
      },
      {
        "SUMMARY:Second Thursday",
        "DESCRIPTION:Second Thursday",
        "RRULE:FREQ=MONTHLY;BYDAY=2TH",
        "DTSTART;VALUE=DATE:20250109",
      },
      {
        "SUMMARY:Xmas",
        "DESCRIPTION:Xmas",
        "RRULE:FREQ=YEARLY;BYMONTH=12;BYMONTHDAY=25",
        "DTSTART;VALUE=DATE:20251225",
      },
      {
        "SUMMARY:Thanksgiving",
        "DESCRIPTION:Thanksgiving",
        "RRULE:FREQ=MONTHLY;BYMONTH=11;BYDAY=4TH",
        "DTSTART;VALUE=DATE:20251127",
      },
      { "SUMMARY:Once", "DESCRIPTION:Once", "DTSTART;VALUE=DATE:20260704" },
      {
        "SUMMARY:Mid month",
        "DESCRIPTION:Mid month",
        "RRULE:FREQ=MONTHLY;BYMONTHDAY=15",
        "DTSTART;VALUE=DATE:20250115",
      },
      {
        "SUMMARY:Last Monday",
        "DESCRIPTION:Last Monday",
        "RRULE:FREQ=MONTHLY;BYDAY=-1MO",
        "DTSTART;VALUE=DATE:20250127",
      },
    }, got)
  end)

  it("converts diary timestamps with times, named after the entry", function()
    local got = events({
      "* Timed",
      "<%%(diary-anniversary 5 10 1980) 10:00-11:30>",
      "* E",
      "<%%(diary-cyclic 14 1 5 2026) 09:00>",
    })
    eq({
      { "SUMMARY:Timed", "DESCRIPTION:Timed", "RRULE:FREQ=YEARLY", "DURATION:PT1H30M", "DTSTART:19800510T100000" },
      { "SUMMARY:E", "DESCRIPTION:E", "RRULE:FREQ=DAILY;INTERVAL=14", "DTSTART:20260105T090000" },
    }, got)
  end)

  it("uses DS<n>-<id> uids and follows org-icalendar-include-sexps", function()
    local _, out = events({ "* X", ":PROPERTIES:", ":ID: abc", ":END:", "%%(diary-anniversary 5 10 1980) x" })
    ok(out:find("UID:DS1-abc", 1, true), out)
    config.opts.export.icalendar.include_sexps = false
    local none = events({ "* X", "%%(diary-anniversary 5 10 1980) x" })
    eq({}, none)
  end)
end)
