-- Values checked with Emacs Org 9.8.7 org-duration-to/from-minutes.
local date = require("org.date")
local columns = require("org.columns")

describe("Org duration grammar", function()
  it("uses m for months and min for minutes", function()
    eq(43200, date.parse_duration("1m"))
    eq(1, date.parse_duration("1min"))
    eq(525960, date.parse_duration("1y"))
  end)

  it("supports units followed by H:MM or H:MM:SS", function()
    eq(90, date.parse_duration("1h 0:30"))
    eq(1530.5, date.parse_duration("1d 1:30:30"))
    eq(2970, date.parse_duration("2d1h0:30"))
  end)

  it("preserves fractions until durations are displayed", function()
    eq(0.5, date.parse_duration("0.5min"))
    eq(90.5, date.parse_duration("1:30:30"))
    eq("1:30", date.duration_to_string(90.5))
    eq("-1:30", date.duration_to_string(-90.5))
    eq("23:59", date.duration_to_string(1439.9))
    eq("1d 0:00", date.duration_to_string(1440.9))
  end)

  it("rejects partial matches and unknown units", function()
    for _, text in ipairs({ "garbage 1h", "1h garbage", "-1h", "1h 30", "1mon", "1s", "1h,30min" }) do
      eq(nil, date.parse_duration(text), text)
    end
  end)

  it("accepts bare minutes, numbers and the empty duration", function()
    eq(90.5, date.parse_duration("90.5"))
    eq(90.5, date.parse_duration(90.5))
    eq(0, date.parse_duration(""))
    eq(nil, date.parse_duration(nil))
  end)

  it("sums effort units and second precision before formatting", function()
    eq("2:00", columns.summarize(":", { "1h 0:30", "0:30" }))
    eq("0:01", columns.summarize(":", { "0.5min", "0.5min" }))
    eq("30d 0:00", columns.summarize(":", { "1m" }))
  end)
end)
