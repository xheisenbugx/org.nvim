-- diary-remind, diary-offset and the diary-*-date functions of org.agenda.sexp,
-- and %%(...) lines before the first heading. Expected values were produced by
-- Emacs 31 / Org 9.8.10 in batch (org-diary-sexp-entry and org-agenda-list).
local sexp = require("org.agenda.sexp")
local date = require("org.date")
local config = require("org.config")
local utils = require("org.utils")

local function day(y, m, d)
  return date.days_from_civil(y, m, d)
end

--- The results of `s` (with entry text `text`) for 2026-09-27 .. 2026-10-03.
local function week(s, text)
  local out = {}
  for i = 0, 6 do
    local r = sexp.eval(s, day(2026, 9, 27) + i, text)
    if r then
      local y, m, d = date.civil_from_days(day(2026, 9, 27) + i)
      out[#out + 1] = string.format("%d-%02d-%02d %s", y, m, d, r)
    end
  end
  return out
end

describe("diary-remind and diary-offset", function()
  it("remind DAYS days before and on the day itself", function()
    eq({ "2026-09-28 Reminder: Only 3 days until Remind me", "2026-10-01 Remind me" },
      week("(diary-remind '(diary-date 10 1 2026) 3)", "Remind me"))
  end)

  it("take a list of days, or -N for 1..N", function()
    eq({
      "2026-09-28 Reminder: Only 4 days until Remind list",
      "2026-09-29 Reminder: Only 3 days until Remind list",
      "2026-10-01 Reminder: Only 1 day until Remind list",
      "2026-10-02 Remind list",
    }, week("(diary-remind '(diary-date 10 2 2026) '(1 3 4))", "Remind list"))
    eq({
      "2026-09-29 Reminder: Only 3 days until Remind neg",
      "2026-09-30 Reminder: Only 2 days until Remind neg",
      "2026-10-01 Reminder: Only 1 day until Remind neg",
      "2026-10-02 Remind neg",
    }, week("(diary-remind '(diary-date 10 2 2026) -3)", "Remind neg"))
  end)

  it("count whole weeks in weeks (diary-remind-message)", function()
    local out = {}
    for i = 0, 20 do
      local r = sexp.eval("(diary-remind '(diary-date 10 15 2026) '(7 14 1))", day(2026, 9, 25) + i, "Taxes")
      if r then
        out[#out + 1] = r
      end
    end
    eq({
      "Reminder: Only 2 weeks until Taxes",
      "Reminder: Only 1 week until Taxes",
      "Reminder: Only 1 day until Taxes",
      "Taxes",
    }, out)
  end)

  it("format the entry of the reminded date", function()
    eq({ "2026-09-28 Reminder: Only 2 days until Anniv 26th", "2026-09-30 Anniv 26th" },
      week("(diary-remind '(diary-anniversary 9 30 2000) 2)", "Anniv %d%s"))
    eq({
      "2026-09-28 Reminder: Only 1 day until Block",
      "2026-09-29 Block",
      "2026-09-30 Block",
    }, week("(diary-remind '(diary-block 9 29 2026 9 30 2026) 1)", "Block"))
    -- MARKING only matters for the Emacs calendar
    eq({ "2026-09-27 Reminder: Only 2 days until Remind marked", "2026-09-29 Remind marked" },
      week("(diary-remind '(diary-date 9 29 2026) 2 t)", "Remind marked"))
  end)

  it("offset a sexp by DAYS days", function()
    eq({ "2026-09-28 Offset" }, week("(diary-offset '(diary-date 9 25 2026) 3)", "Offset"))
    eq({ "2026-10-01 Offset neg" }, week("(diary-offset '(diary-date 10 5 2026) -4)", "Offset neg"))
    local r, err = sexp.eval("(diary-offset '(diary-date 9 25 2026) 1.5)", day(2026, 9, 27), "")
    eq(nil, r)
    eq("Days must be an integer", err)
  end)
end)

describe("diary dates of other calendars", function()
  it("match Emacs's diary-*-date entries", function()
    local d = day(2026, 9, 27)
    local expected = {
      ["(diary-hebrew-date)"] = "Hebrew date (until sunset): Tishri 16, 5787",
      ["(diary-islamic-date)"] = "Islamic date (until sunset): Rabi II 14, 1448",
      ["(diary-bahai-date)"] = "Bahá’í date: Mashíyyat 1, 183",
      ["(diary-chinese-date)"] = "Chinese date: Cycle 78, year 43 (Bing-Wu), month 8 (Ding-You), day 17 (Jia-Chen)",
      ["(diary-julian-date)"] = "Julian date: September 14, 2026",
      ["(diary-iso-date)"] = "ISO date: Day 7 of week 39 of 2026",
      ["(diary-astro-day-number)"] = "Astronomical (Julian) day number at noon UTC: 2461311.0",
      ["(diary-french-date)"] = "French Revolutionary date: Sextidi 6 Vendémiaire an 235 de la Révolution, "
        .. "jour de la Balsamine",
      ["(diary-mayan-date)"] = "Mayan date: Long count = 13.0.13.17.8; tzolkin = 1 Lamat; haab = 1 Yax",
      ["(diary-coptic-date)"] = "Coptic date: Tut 17, 1743",
      ["(diary-ethiopic-date)"] = "Ethiopic date: Maskaram 17, 2019",
      ["(diary-persian-date)"] = "Persian date: Mehr 5, 1405",
      ["(diary-day-of-year)"] = "Day 270 of 2026; 95 days remaining in the year",
    }
    for s, want in pairs(expected) do
      eq(want, sexp.eval(s, d, ""))
    end
    eq("Date is pre-French Revolution", sexp.eval("(diary-french-date)", day(1789, 7, 14), ""))
    eq("Day 365 of 1999; 0 days remaining in the year", sexp.eval("(diary-day-of-year)", day(1999, 12, 31), ""))
  end)

  it("needs the location for diary-sunrise-sunset", function()
    config.setup({})
    local r, err = sexp.eval("(diary-sunrise-sunset)", day(2026, 9, 27), "")
    eq(nil, r)
    ok(err:match("calendar_latitude"))
    config.setup({ agenda = { calendar_latitude = 40.7, calendar_longitude = -74.0 } })
    r = sexp.eval("(diary-sunrise-sunset)", day(2026, 9, 27), "")
    -- the times depend on the system time zone
    ok(r:match("[Ss]unset.* at 40%.7N, 74%.0W %(%d+:%d%d hrs daylight%)$"), r)
    config.setup({})
  end)

  it("finds the phases of the moon", function()
    local n = 0
    for d = day(2026, 9, 1), day(2026, 9, 30) do
      local r = sexp.eval("(diary-lunar-phases)", d, "")
      if r then
        n = n + 1
        ok(r:match("Moon %d+:%d%d[ap]m"), r)
      end
    end
    ok(n >= 3 and n <= 5)
  end)
end)

describe("%%(...) lines before the first heading", function()
  local view = require("org.agenda.view")
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/pre.org"
  after_each(function()
    pcall(view.quit, true)
  end)

  it("are agenda entries with the file's category", function()
    utils.writefile(path, {
      "#+CATEGORY: Pre",
      "#+FILETAGS: :ftag:",
      "%%(diary-block 1 1 2000 12 31 2100) Before the heading",
      "* Heading",
      "%%(diary-block 1 1 2000 12 31 2100) Under the heading",
    })
    config.setup({ agenda_files = { path }, org_directory = dir })
    require("org.agenda").open_agenda({ span = "day" })
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local pre, under
    for l, it in pairs(view.state.line_items) do
      if it.title == "Before the heading" then
        pre = l
      elseif it.title == "Under the heading" then
        under = l
      end
    end
    ok(pre and under and pre < under)
    ok(lines[pre]:match("^%s+Pre:%s+Before the heading%s+:ftag:$"), lines[pre])
    local item = view.state.line_items[pre]
    eq(nil, item.headline)
    eq(3, view.resolve_target(item).lnum)
    -- entry commands need a heading
    vim.api.nvim_win_set_cursor(0, { pre, 0 })
    local errs = {}
    local orig = utils.error
    utils.error = function(msg)
      errs[#errs + 1] = msg
    end
    local okc = pcall(view.actions.todo)
    utils.error = orig
    ok(okc)
    ok(errs[1] and errs[1]:match("Before first headline"))
  end)
end)
