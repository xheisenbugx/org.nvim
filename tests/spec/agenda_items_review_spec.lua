-- Agenda entry selection checked against Emacs Org 9.8.10 (org-agenda.el).
local date = require("org.date")
local items = require("org.agenda.items")
local parser = require("org.parser")

local function day(s)
  return date.parse("<" .. s .. ">"):days()
end

local function agenda(lines, from, to, today, block)
  local file = parser.parse(lines, "/tmp/review.org")
  return items.agenda({ file }, day(from), day(to), { today = day(today), block = block })
end

local function titles(list)
  local out = {}
  for _, it in ipairs(list or {}) do
    out[#out + 1] = it.title
  end
  return out
end

describe("agenda deadline warning days (org-get-wdays)", function()
  local lines = {
    "* TODO Cookie",
    "DEADLINE: <2026-10-05 Mon -7d>",
    "* TODO Plain",
    "DEADLINE: <2026-10-06 Tue>",
  }

  it("enforces a deadline_warning_days of 0 over -Nd cookies", function()
    local by = agenda(lines, "2026-10-01", "2026-10-01", "2026-10-01", { deadline_warning_days = 0 })
    eq({}, titles(by[day("2026-10-01")]))
  end)

  it("enforces the absolute value of a negative deadline_warning_days", function()
    local by = agenda(lines, "2026-10-01", "2026-10-01", "2026-10-01", { deadline_warning_days = -7 })
    eq({ "Cookie", "Plain" }, titles(by[day("2026-10-01")]))
  end)

  it("uses the cookie over a positive deadline_warning_days", function()
    local by = agenda(lines, "2026-10-01", "2026-10-01", "2026-10-01", { deadline_warning_days = 2 })
    eq({ "Cookie" }, titles(by[day("2026-10-01")]))
  end)
end)

describe("agenda date ranges (org-agenda-get-blocks)", function()
  it("ignores default_appointment_duration on the first and last day", function()
    local by = agenda(
      { "* Trip", "<2026-10-01 Thu 10:00>--<2026-10-03 Sat 12:00>" },
      "2026-10-01",
      "2026-10-03",
      "2026-10-01",
      { default_appointment_duration = 60 }
    )
    local first, middle, last = by[day("2026-10-01")][1], by[day("2026-10-02")][1], by[day("2026-10-03")][1]
    eq({ 600, nil }, { first.time, first.end_time })
    eq({ nil, nil }, { middle.time, middle.end_time })
    eq({ 720, nil }, { last.time, last.end_time })
  end)

  it("still applies it to a plain timestamp", function()
    local by = agenda({ "* Meet", "<2026-10-01 Thu 10:00>" }, "2026-10-01", "2026-10-01", "2026-10-01", {
      default_appointment_duration = 60,
    })
    eq(660, by[day("2026-10-01")][1].end_time)
  end)
end)

describe("agenda sexps", function()
  it("finds %%(sexp) entries and <%%(sexp)> stamps", function()
    local by = agenda({
      "%%(diary-date 10 2 2026) Before heading",
      "* Entry",
      "%%(diary-date 10 1 2026) Diary line",
      "* Stamp <%%(diary-date 10 1 2026)>",
    }, "2026-10-01", "2026-10-02", "2026-10-01")
    eq({ "Stamp <%%(diary-date 10 1 2026)>", "Diary line" }, titles(by[day("2026-10-01")]))
    eq({ "Before heading" }, titles(by[day("2026-10-02")]))
  end)

  -- org-agenda-get-timestamps passes the whole <%%(sexp) time> stamp to
  -- org-agenda-format-item as DOTIME (the manual's example:
  -- "<%%(diary-float t 4 2) 22:00-23:00>"); Emacs 9.8.10 shows it at
  -- 22:00-23:00
  it("takes the time written after the sexp of a <%%(sexp) time> stamp", function()
    local by =
      agenda({ "* Nerd meeting", "  <%%(diary-float t 4 1) 22:00-23:00>" }, "2026-10-01", "2026-10-01", "2026-10-01")
    local it = by[day("2026-10-01")][1]
    eq({ 1320, 1380 }, { it.time, it.end_time })
  end)

  -- org-agenda-get-scheduled / -deadlines take the time from the stamp's
  -- text (" \\([012]?[0-9]:[0-9][0-9]\\)"), a sexp stamp's too
  it("takes the time after the sexp of a SCHEDULED or DEADLINE sexp", function()
    local by = agenda({
      "* TODO Sched",
      "  SCHEDULED: <%%(diary-float t 4 1) 10:00>",
      "* TODO Due",
      "  DEADLINE: <%%(diary-float t 4 1) 15:30-16:00>",
    }, "2026-10-01", "2026-10-01", "2026-10-01")
    local times = {}
    for _, it in ipairs(by[day("2026-10-01")]) do
      times[it.title] = { it.time, it.end_time }
    end
    eq({ Sched = { 600 }, Due = { 930, 960 } }, times)
  end)
end)

describe("global TODO list (org-agenda-get-todos)", function()
  it("skips the subtree of an ignored entry without todo_list_sublevels", function()
    local file = parser.parse({
      "* TODO Parent",
      "SCHEDULED: <2099-10-05 Mon>",
      "** TODO Child",
      "* TODO Other",
      "** TODO Other child",
    }, "/tmp/review.org")
    local block = { todo_list_sublevels = false, todo_ignore_scheduled = "future" }
    eq({ "Other" }, titles(items.todo({ file }, nil, { block = block })))
    block.todo_list_sublevels = true
    eq({ "Child", "Other", "Other child" }, titles(items.todo({ file }, nil, { block = block })))
  end)
end)

-- org-agenda-format-item removes the timestamp that gives the time, with
-- the spaces after it (`(regexp-quote time-string) " *"`), before
-- org-agenda-get-timestamps's REMOVE-RE (org-ts-regexp) takes the other
-- stamps out without their spaces. Emacs 9.8.10 shows "Meeting with Bob",
-- "TODO Lunch at cafe" and "Call  with Ann".
describe("timestamps in an agenda title", function()
  it("are removed with the spaces after the timed one", function()
    local by = agenda({
      "* Meeting <2026-10-01 Thu 10:00> with Bob",
      "* Call <2026-10-01 Thu> with Ann",
      "* TODO Lunch <2026-10-01 Thu 12:00-13:00> at cafe",
      "* Weekly <2026-09-24 Thu 09:00 +1w> sync",
    }, "2026-10-01", "2026-10-01", "2026-10-01")
    local shown = {}
    for _, it in ipairs(by[day("2026-10-01")]) do
      shown[#shown + 1] = it.display_title or it.title
    end
    table.sort(shown)
    eq({ "Call  with Ann", "Lunch at cafe", "Meeting with Bob", "Weekly sync" }, shown)
  end)
end)
