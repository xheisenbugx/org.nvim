-- Ordinary repeat dates checked with Emacs Org 9.8.7 org-closest-date.
local date = require("org.date")
local items = require("org.agenda.items")
local parser = require("org.parser")

local function day(s)
  return date.parse("<" .. s .. ">"):days()
end

describe("agenda recurrence boundaries (Emacs)", function()
  with_config({ extend_today_until = 0 })

  it("finds old monthly repeats without skipping ahead", function()
    local ts = date.parse("<2020-01-15 Wed +1m>")
    eq(day("2026-09-15"), items.last_occ(ts, day("2026-09-26")))
    eq(day("2026-10-15"), items.next_occ(ts, day("2026-09-26")))
    eq(day("2026-09-15"), items.next_occ(ts, day("2026-09-15")))
    eq(day("2026-09-15"), items.last_occ(ts, day("2026-09-15")))
  end)

  it("keeps month-end rollover anchored to the original timestamp", function()
    -- Preserve the existing chronological month-end behavior. Emacs 9.8.7
    -- itself returns a future "past" occurrence for March 1 in this case.
    local ts = date.parse("<2020-01-31 Fri +1m>")
    eq(day("2026-01-31"), items.last_occ(ts, day("2026-03-01")))
    eq(day("2026-03-03"), items.next_occ(ts, day("2026-03-01")))
    eq(day("2026-03-03"), items.last_occ(ts, day("2026-03-20")))
    eq(day("2026-03-31"), items.next_occ(ts, day("2026-03-20")))
  end)

  it("does not turn multi-day hourly repeaters into daily repeats", function()
    local ts = date.parse("<2026-09-23 Wed 09:00 +48h>")
    eq(day("2026-09-25"), items.last_occ(ts, day("2026-09-26")))
    eq(day("2026-09-27"), items.next_occ(ts, day("2026-09-26")))
    eq(day("2026-09-25"), items.last_occ(ts, day("2026-09-25")))
    eq(day("2026-09-25"), items.next_occ(ts, day("2026-09-25")))
  end)

  it("uses the effective agenda day for hourly repeats", function()
    require("org.config").opts.extend_today_until = 6
    local ts = date.parse("<2026-09-23 Wed 02:00 +48h>")
    eq(day("2026-09-24"), items.last_occ(ts, day("2026-09-25")))
    eq(day("2026-09-26"), items.next_occ(ts, day("2026-09-25")))
  end)

  it("shows actual future monthly and hourly entries in the agenda", function()
    local file = parser.parse({
      "* Monthly appointment",
      "<2020-01-15 Wed +1m>",
      "* Every other day",
      "<2026-09-23 Wed 09:00 +48h>",
    }, "/tmp/recurrence.org")
    local by_day = items.agenda({ file }, day("2026-09-26"), day("2026-10-15"), {
      today = day("2026-09-26"),
      block = { show_future_repeats = true, prefer_last_repeat = false },
    })
    eq(nil, by_day[day("2026-09-26")])
    eq("Every other day", by_day[day("2026-09-27")][1].title)
    eq(nil, by_day[day("2026-09-28")])
    ok(vim.tbl_contains(
      vim.tbl_map(function(item)
        return item.title
      end, by_day[day("2026-10-15")]),
      "Monthly appointment"
    ))
  end)
end)
