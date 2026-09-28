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

  it("sums H:MM:SS durations in H:MM:SS (org-duration-h:mm-only-p)", function()
    eq("2:00:30", columns.summarize(":", { "1:30:30", "0:30" }))
    eq("1:30:30", columns.summarize(":max", { "1:30:30", "0:30" }))
    eq("2:00", columns.summarize(":", { "1:30", "0:30" }))
  end)
end)

-- Values from Emacs Org 9.8.10 org-duration.el in batch mode.
describe("org-duration port", function()
  local duration = require("org.duration")
  local config = require("org.config")
  local MINUTES = { 0, 0.5, 45, 90.5, 1439.9, 1440, 1530.5, 3000, 12000, 50000, 600000, -95 }
  local function row(fmt)
    local out = {}
    for _, m in ipairs(MINUTES) do
      out[#out + 1] = duration.from_minutes(m, fmt)
    end
    return out
  end

  it("formats with every org-duration-format form", function()
    eq(
      { "0:00", "0:00", "0:45", "1:30", "23:59", "24:00", "25:30", "50:00", "200:00", "833:20", "10000:00", "-1:35" },
      row("h:mm")
    )
    eq({
      "0:00:00", "0:00:30", "0:45:00", "1:30:30", "23:59:54", "24:00:00",
      "25:30:30", "50:00:00", "200:00:00", "833:20:00", "10000:00:00", "-1:35:00",
    }, row("h:mm:ss"))
    eq({
      "0:00", "0:00", "0:45", "1:30", "23:59", "1d 0:00",
      "1d 1:30", "2d 2:00", "8d 8:00", "34d 17:20", "416d 16:00", "-1:35",
    }, row("d h:mm"))
    eq(row({ { "special", "h:mm" } }), row("h:mm"))
    eq({
      "0:00:00", "0:00:30", "0:45:00", "1:30:30", "23:59:54", "1d 0:00:00",
      "1d 1:30:30", "2d 2:00:00", "8d 8:00:00", "34d 17:20:00", "416d 16:00:00", "-1:35:00",
    }, row({ { "d", false }, { "special", "h:mm:ss" } }))
    eq({
      "0.00h", "0.01h", "0.75h", "1.51h", "24.00h", "24.00h",
      "25.51h", "50.00h", "200.00h", "833.33h", "10000.00h", "-1.58h",
    }, row({ { "h", true }, { "special", 2 } }))
    eq({
      "0.00h", "0.01h", "0.75h", "1.51h", "24.00h", "1.00d",
      "1.06d", "2.08d", "8.33d", "34.72d", "416.67d", "-1.58h",
    }, row({ { "d", false }, { "h", false }, { "special", 2 } }))
    eq({
      "0h 0min", "0h 0min", "0h 45min", "1h 30min", "23h 59min", "1d 0h 0min",
      "1d 1h 30min", "2d 2h 0min", "8d 8h 0min", "34d 17h 20min", "416d 16h 0min", "-1h 35min",
    }, row({ { "d", false }, { "h", true }, { "min", true } }))
    eq({
      "0min", "0min", "45min", "90min", "1439min", "1d",
      "1d 90min", "2d 120min", "8d 480min", "34d 1040min", "416d 960min", "-95min",
    }, row({ { "d" }, { "min" } }))
    eq({
      "0min", "0min", "45min", "1h 30min", "23h 59min", "1d",
      "1d 1h 30min", "2d 2h", "1w 1d 8h", "4w 6d 17h 20min", "1y 7w 2d 10h", "-1h 35min",
    }, row({ { "y" }, { "w" }, { "d" }, { "h" }, { "min" } }))
    eq({
      "0min", "0min", "45min", "1h30min", "23h59min", "1d",
      "1d1h30min", "2d2h", "8d8h", "34d17h20min", "416d16h", "-1h35min",
    }, row({ { "d" }, { "h" }, { "min" }, "compact" }))
    eq({
      "0:00", "0:00", "0:45", "1:30", "23:59", "24:00",
      "25:30", "50:00", "1w32:00", "4w161:20", "59w88:00", "-1:35",
    }, row({ { "w" }, { "special", "h:mm" }, "compact" }))
    eq({ "0h", "0h", "0h", "1h", "23h", "24h", "25h", "50h", "200h", "833h", "10000h", "-1h" }, row({ { "h" } }))
    -- dict form
    eq("1d1:30", duration.from_minutes(1530, { d = false, special = "h:mm", compact = true }))
  end)

  it("parses like org-duration-to-minutes", function()
    local cases = {
      { "1m", 43200 }, { "1min", 1 }, { "3:12", 192 }, { "1:23:45", 83.75 }, { "1y 3d 3h 4min", 530464 },
      { "1d3h5min", 1625 }, { "3d 13:35", 5135 }, { "2.35h", 141 }, { " 90", nil }, { "90 ", nil },
      { "1. h", 60 }, { " 1h ", 60 }, { "1h1:00:30", 120.5 }, { "1mh", nil }, { "1 w", 10080 }, { "", 0 },
      { "1h 30", nil },
    }
    for _, c in ipairs(cases) do
      eq(c[2], duration.to_minutes(c[1]), c[1])
    end
  end)

  it("org-duration-p and org-duration-h:mm-only-p", function()
    local samples = { "1h", "1:00", "1h 30", "1d 1:00:00", "90", "x" }
    eq({ true, true, false, true, false, false }, vim.tbl_map(duration.p, samples))
    eq("h:mm", duration.hmm_only_p({ "1:30", "0:30" }))
    eq("h:mm:ss", duration.hmm_only_p({ "1:30:30", "0:30" }))
    eq(nil, duration.hmm_only_p({ "1:30", "1h" }))
    eq(nil, duration.hmm_only_p({ "0:30", "1d 1:00" }))
  end)

  describe("with custom duration_units", function()
    with_config({ duration_units = { min = 1, h = 60, d = 480, w = 2400, m = 9600, y = 96000, wd = 480 } })

    it("uses them to parse and format, canonical units stay standard", function()
      eq(480, duration.to_minutes("1d"))
      eq(2400, duration.to_minutes("1w"))
      eq(960, duration.to_minutes("2wd"))
      eq(540, duration.to_minutes("1d 1:00"))
      eq(1440, duration.to_minutes("1d", true))
      -- like Emacs, the units of a mixed duration ignore CANONICAL
      eq(540, duration.to_minutes("1d 1:00", true))
      eq(nil, duration.to_minutes("1w", true))
      eq({ "1:30", "1d 0:00", "1d 2:00", "6d 2:00" }, vim.tbl_map(duration.from_minutes, { 90, 480, 600, 3000 }))
      eq("2d 2:00", duration.from_minutes(3000, nil, true))
      eq(true, config.opts.duration_units.wd == 480)
    end)

    it("applies to efforts, column sums and clock sums", function()
      eq("1d 2:00", columns.summarize(":", { "1d", "2h" }))
      eq("0:30", columns.summarize(":", { "0:30" }))
      -- ages ignore the user units (org-columns--age-to-minutes)
      eq("1d", columns.summarize("@min", { "1d" }))
      eq(480, date.parse_duration("1d"))
    end)
  end)

  describe("with a custom duration_format", function()
    with_config({ duration_format = { { "h", true }, { "special", 2 } } })

    it("formats clock sums and effort sums", function()
      eq("1.50h", date.duration_to_string(90))
      eq("2.00h", columns.summarize(":", { "1h", "1h" }))
      -- all H:MM values keep H:MM (org-duration-h:mm-only-p)
      eq("2:00", columns.summarize(":", { "1:00", "1:00" }))
    end)
  end)
end)

