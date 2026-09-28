-- format-time-string and custom timestamp formats (org-display-custom-times);
-- expectations from Emacs 31 / Org 9.8.10 in batch mode (C locale names).
local date = require("org.date")
local export = require("org.export")
local ts = require("org.timestamps")

describe("format_time_string", function()
  local t = os.time({ year = 2021, month = 1, day = 3, hour = 9, min = 5, sec = 7 })

  it("supports the format-time-string directives", function()
    eq(
      "Sun Sunday Jan January Jan Sun Jan  3 09:05:07 2021 20 03 01/03/21  3 2021-01-03 20 2020 09 09 003  9  9 01 05 AM "
        .. "am 1 09:05:07 AM 09:05 07 09:05:07 7 01 53 0 00 01/03/21 09:05:07 21 2021 %",
      date.format_time_string(
        "%a %A %b %B %h %c %C %d %D %e %F %g %G %H %I %j %k %l %m %M %p %P %q %r %R %S %T %u %U %V %w %W %x %X %y %Y %%",
        t
      )
    )
  end)

  it("supports flags, widths and modifiers", function()
    eq(
      "3  3 1  1 003 02021 SUN JANUARY SUN am     Sunday Sunday   9 9 3   3  3 3 03 0000000003 9 03 000000000 000 \t|\n|",
      date.format_time_string(
        "%-d %_d %-m %_m %03d %5Y %^a %^B %#a %#p %10A %-10A %_3H %-I %-j %_j %e %-e %0e %10d %-H %Od %N %3N %t|%n|",
        t
      )
    )
    local z = date.format_time_string("%z", t)
    eq(z, date.format_time_string("%Ez", t))
    eq((z:gsub("(%d%d)(%d%d)$", "%1:%2")), date.format_time_string("%:z", t))
    eq((z:gsub("(%d%d)(%d%d)$", "%1:%2:00")), date.format_time_string("%::z", t))
  end)

  it("computes ISO and week numbers like strftime", function()
    local cases = {
      { { 2024, 12, 30 }, "2025 25 01 52 53 365 1 1" },
      { { 2027, 1, 1 }, "2026 26 53 00 00 001 5 5" },
      { { 2026, 9, 27 }, "2026 26 39 39 38 270 7 0" },
      { { 2020, 12, 31 }, "2020 20 53 52 52 366 4 4" },
    }
    for _, c in ipairs(cases) do
      local tt = os.time({ year = c[1][1], month = c[1][2], day = c[1][3], hour = 12 })
      eq(c[2], date.format_time_string("%G %g %V %U %W %j %u %w", tt))
    end
  end)

  it("Date:strftime uses it", function()
    eq("Tuesday 05 March 2024, 10:00", date.parse("<2024-03-05 Tue 10:00>"):strftime("%A %d %B %Y, %H:%M"))
  end)
end)

describe("custom timestamps in export", function()
  local lines = {
    "* H",
    "",
    "A <2024-03-05 Tue> b [2024-03-05 Tue 10:00-11:30] c <2024-03-05 Tue +1w> d <2024-03-05 Tue 09:00 +1w -2d> "
      .. "e <2024-03-05 Tue>--<2024-03-08 Fri> f [2024-03-05 Tue 10:00 .+2d/3d] g <%%(diary-float t 4 2)>.",
  }

  describe("when display_custom_times is on", function()
    with_config({ display_custom_times = true })

    it("translates timestamps (org-timestamp-translate)", function()
      eq(
        "* H\n\nA 03/05/24 Tue b 03/05/24 Tue 10:00--03/05/24 Tue 11:30 c 03/05/24 Tue d 03/05/24 Tue 09:00 "
          .. "e 03/05/24 Tue--03/08/24 Fri f 03/05/24 Tue 10:00 g <%%(diary-float t 4 2)>.\n",
        export.to_string("org", { lines = lines, body_only = true })
      )
      local html = export.to_string("html", { lines = lines, body_only = true })
      assert(html:find('<span class="timestamp">03/05/24 Tue 10:00&ndash;03/05/24 Tue 11:30</span>', 1, true), html)
    end)
  end)

  describe("with #+STARTUP: customtime and bracketed formats", function()
    with_config({ time_stamp_custom_formats = { "<%A %d %B %Y>", "<%A %d %B %Y, %H:%M>" } })

    it("keeps the brackets of the formats", function()
      local l = vim.list_extend({ "#+STARTUP: customtime" }, lines)
      eq(
        "1 H\n===\n\n  A <Tuesday 05 March 2024> b <Tuesday 05 March 2024, 10:00>--<Tuesday\n"
          .. "  05 March 2024, 11:30> c <Tuesday 05 March 2024> d <Tuesday 05 March\n"
          .. "  2024, 09:00> e <Tuesday 05 March 2024>--<Friday 08 March 2024> f\n"
          .. "  <Tuesday 05 March 2024, 10:00> g <%%(diary-float t 4 2)>.\n",
        export.to_string("ascii", { lines = l, body_only = true })
      )
    end)
  end)

  it("follows the buffer's C-c C-x C-t toggle", function()
    local buf = org_buffer({ "A <2024-03-05 Tue> b" }, { 1, 0 })
    eq("A <2024-03-05 Tue>  b\n", export.to_string("org", { bufnr = buf, body_only = true }))
    ts.toggle_custom_display()
    eq("A 03/05/24 Tue b\n", export.to_string("org", { bufnr = buf, body_only = true }))
    ts.toggle_custom_display()
  end)
end)
