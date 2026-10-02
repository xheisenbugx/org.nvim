local date = require("org.date")

describe("date.set_tz", function()
  it("makes os.date and os.time follow TZ in a running process", function()
    skip_on_windows("TZ takes no IANA zone names on Windows")
    local saved = vim.env.TZ
    local ok, err = pcall(function()
      date.set_tz("America/New_York")
      eq("1969-12-31 19:00 EST", os.date("%Y-%m-%d %H:%M %Z", 0))
      eq(5 * 3600, os.time({ year = 1970, month = 1, day = 1, hour = 0 }))
      date.set_tz("Asia/Kolkata")
      eq("05:30", os.date("%H:%M", 0))
    end)
    date.set_tz(saved)
    assert(ok, err)
  end)

  it("unsets TZ with nil", function()
    local saved = vim.env.TZ
    date.set_tz("UTC")
    date.set_tz(nil)
    local unset = vim.env.TZ
    date.set_tz(saved)
    eq(nil, unset)
  end)
end)
