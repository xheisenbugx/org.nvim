-- The Emacs diary file in the date agenda (org-agenda-include-diary).
--
-- Every expected agenda was printed by Emacs 31 / Org 9.8.10 in batch:
--   (setq diary-file ... org-agenda-include-diary t org-agenda-use-time-grid nil
--         org-agenda-start-on-weekday nil)
--   (org-agenda-list nil "2026-09-27" 7)
-- with TZ=America/New_York, the default calendar-holidays and, where noted,
-- calendar-set-date-style, diary-include-other-diary-files in
-- diary-list-entries-hook and the diary-*-list-entries in
-- diary-nongregorian-listing-hook.
local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")
local view = require("org.agenda.view")
local diary = require("org.agenda.diary")
local solar = require("org.agenda.holidays.solar")

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local org_file = dir .. "/a.org"
utils.writefile(org_file, { "* TODO Task", "  SCHEDULED: <2026-09-28 Mon>" })

--- Write `lines` to `name` in the test directory; `eol` false leaves the
--- last line without a newline.
local function write(name, lines, eol)
  local fd = assert(io.open(dir .. "/" .. name, "wb"))
  fd:write(table.concat(lines, "\n") .. (eol == false and "" or "\n"))
  fd:close()
  return dir .. "/" .. name
end

local saved_tz
local function setup(agenda_opts)
  config.setup({
    agenda_files = { org_file },
    org_directory = dir,
    agenda = vim.tbl_extend("force", {
      start_on_weekday = false,
      -- Emacs's org-agenda-time-grid trailing characters, no grid
      time_grid = { enabled = false, separator = "......" },
    }, agenda_opts or {}),
  })
end

--- The agenda of `ndays` days from `start` ("YYYY-MM-DD").
local function agenda(start, ndays)
  local y, m, d = start:match("(%d+)-(%d+)-(%d+)")
  require("org.agenda").open_agenda({
    span = ndays or 7,
    anchor = date.days_from_civil(tonumber(y), tonumber(m), tonumber(d)),
  })
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

local function line_of(lines, text)
  for i, l in ipairs(lines) do
    if l:find(text, 1, true) then
      return i
    end
  end
end

describe("agenda diary file", function()
  -- Emacs printed these agendas on 2026-09-27; later, the scheduled task
  -- would also show as "Sched. Nx:" on today.
  local saved_today, saved_today_days, saved_now
  before_each(function()
    saved_tz = vim.env.TZ
    date.set_tz("America/New_York")
    solar.reset()
    saved_today, saved_today_days, saved_now = date.today, date.today_days, date.now
    local T = date.days_from_civil(2026, 9, 27)
    date.today_days = function()
      return T
    end
    date.today = function()
      return date.from_days(T)
    end
    date.now = function()
      return date.from_days(T, { hour = 12, min = 0 })
    end
  end)
  after_each(function()
    pcall(view.quit, true)
    date.today, date.today_days, date.now = saved_today, saved_today_days, saved_now
    date.set_tz(saved_tz)
    solar.reset()
    config.setup({})
  end)

  it("lists the entries of the american date forms, sexps and holidays", function()
    local path = write("diary", {
      "9/28 Monday slash entry",
      "9/29/2026 Full slash date",
      "&9/30/26 Nonmarking short year",
      "October 1, 2026 Month name with year",
      "oct 2 abbreviated month",
      "Oct. 3 abbreviated with period",
      "* 29 Every 29th of any month",
      "*/30 star month slash",
      "Tuesday 10:00 weekly meeting",
      "&thu 4pm squash game",
      "sat. abbreviated day with period",
      "9/27",
      " Continuation only entry",
      " 2pm Cognitive Studies",
      " more text line",
      "9/28 First line",
      "  continued second line",
      "  11:30 time line",
      "%%(diary-block 9 27 2026 9 29 2026) Vacation",
      "&%%(diary-anniversary 9 30 1990) Birthday %d%s",
      "%%(diary-float t 4 1) First Thursday",
      "%%(diary-day-of-year)",
      "09/27/2026 zero padded",
      "9/27/2027 other year",
      "Sunday",
      "9/28/2026 8:30-9:15 breakfast",
      "9/29 12:00pm lunch at noon",
    })
    setup({ include_diary = true, diary_file = path })
    eq({
      "Week-agenda (W39-W40):",
      "Sunday     27 September 2026",
      "  Diary:      14:00...... Cognitive Studies; more text line",
      "  Diary:      Vacation",
      "  Diary:      Day 270 of 2026; 95 days remaining in the year; Continuation only entry",
      "  Diary:      zero padded",
      "Monday     28 September 2026 W40",
      "  Diary:       8:30-9:15  breakfast",
      "  Diary:      11:30...... time line",
      "  a:          Scheduled:  TODO Task",
      "  Diary:      Vacation",
      "  Diary:      Day 271 of 2026; 94 days remaining in the year",
      "  Diary:      Monday slash entry",
      "  Diary:      First line; continued second line",
      "Tuesday    29 September 2026",
      "  Diary:      10:00...... weekly meeting",
      "  Diary:      12:00...... lunch at noon",
      "  Diary:      Vacation",
      "  Diary:      Day 272 of 2026; 93 days remaining in the year",
      "  Diary:      Full slash date",
      "  Diary:      Every 29th of any month",
      "Wednesday  30 September 2026",
      "  Diary:      Birthday 36th",
      "  Diary:      Day 273 of 2026; 92 days remaining in the year",
      "  Diary:      star month slash",
      "  Diary:      Nonmarking short year",
      "Thursday    1 October 2026",
      "  Diary:      16:00...... squash game",
      "  Diary:      First Thursday",
      "  Diary:      Day 274 of 2026; 91 days remaining in the year",
      "  Diary:      Month name with year",
      "Friday      2 October 2026",
      "  Diary:      Day 275 of 2026; 90 days remaining in the year",
      "  Diary:      abbreviated month",
      "Saturday    3 October 2026",
      "  Diary:      Shemini Atzeret",
      "  Diary:      Day 276 of 2026; 89 days remaining in the year",
      "  Diary:      abbreviated with period",
      "  Diary:      abbreviated day with period",
    }, agenda("2026-09-27"))
  end)

  it("reads included files and the entries of other calendars", function()
    write("inc1", { "9/29 Included entry", "%%(diary-date 10 1 t) Included sexp", '#include "inc2"' })
    write("inc2", { "Wednesday Nested include" })
    local path = write("diary2", {
      '#include "inc1"',
      '#include "missing-file"',
      "Friday: colon after day name",
      "Tuesday",
      "\ttab continuation for tuesday",
      "\t3:30pm tab time",
      "9/28 ",
      "  trailing space then next line",
      "9/29 [foreground:red] colored entry",
      "%%(diary-block 9 27 2026 10 3 2026)",
      "&%%(diary-cyclic 2 9 27 2026) Cycle %d%s",
      "%%(and (= (calendar-day-of-week date) 3)",
      "       t) Multi-line sexp Wednesday",
      "  with continuation",
      "%%(diary-remind '(diary-date 10 2 2026) 2) Remind",
      "%%(diary-hebrew-parasha)",
      "%%(diary-hebrew-rosh-hodesh)",
      "%%(diary-lunar-phases)",
      "%%(diary-hebrew-omer)",
      "%%(diary-hebrew-yahrzeit 10 3 2000) Grandpa",
      "%%(diary-hebrew-birthday 9 30 2010) Anna",
      "HTishri 16 Hebrew Tishri 16",
      "HTishri 17, 5787 Hebrew with year",
      "H7/18 Hebrew numeric",
      "IRabi II 15 Islamic entry",
      "BMashíyyat 3 Bahai entry",
      "C8/19 Chinese entry",
      "Sept 30 not an abbreviation",
      "sep 30 lower abbrev",
      "SEP. 30 upper abbrev period",
      "10/2/2026 10am-11:30am meeting range",
      "10/3 noon 12:30 lunch",
      "   2pm not a continuation?",
      "wed. 7.30pm dotted time",
      "thursday 9h breakfast",
      "sat 20h00 party",
      "9/30",
      "  first",
      "  second",
      "  9:00 third",
      "  fourth",
      "* * star star entry",
      "10/1 *entry with star text",
      "Oct 1, 26 short year monthname",
      "Friday last line no newline",
    }, false)
    setup({
      include_diary = true,
      diary_file = path,
      diary_include_files = true,
      diary_nongregorian = { "hebrew", "islamic", "bahai", "chinese" },
    })
    diary._warned = {}
    local notify, msgs = vim.notify, {}
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    local lines = agenda("2026-09-27")
    vim.wait(20, function()
      return false
    end)
    vim.notify = notify
    eq({ "org agenda: can't find included diary file missing-file" }, msgs)
    eq({
      "Week-agenda (W39-W40):",
      "Sunday     27 September 2026",
      "  Diary:      Cycle 0th",
      "  Diary:      star star entry",
      "  Diary:      Hebrew Tishri 16",
      "Monday     28 September 2026 W40",
      "  a:          Scheduled:  TODO Task",
      "  Diary:      trailing space then next line",
      "  Diary:      star star entry",
      "  Diary:      Hebrew with year",
      "  Diary:      Islamic entry",
      "Tuesday    29 September 2026",
      "  Diary:      15:30...... tab time",
      "  Diary:      Cycle 1st",
      "  Diary:      colored entry",
      "  Diary:      star star entry; tab continuation for tuesday",
      "  Diary:      Hebrew numeric",
      "  Diary:      Bahai entry",
      "  Diary:      Chinese entry",
      "  Diary:      Included entry",
      "Wednesday  30 September 2026",
      "  Diary:       9:00...... third; fourth",
      "  Diary:      Multi-line sexp Wednesday; with continuation",
      "  Diary:      Reminder: Only 2 days until Remind; first; second",
      "  Diary:      lower abbrev",
      "  Diary:      upper abbrev period",
      "  Diary:      star star entry",
      "  Diary:      7.30pm dotted time",
      "  Diary:      Nested include",
      "Thursday    1 October 2026",
      "  Diary:      Cycle 2nd",
      "  Diary:      *entry with star text",
      "  Diary:      star star entry",
      "  Diary:      short year monthname",
      "  Diary:      9h breakfast",
      "  Diary:      Included sexp",
      "Friday      2 October 2026",
      "  Diary:      10:00-11:30 meeting range",
      "  Diary:      Remind",
      "  Diary:      Anna's 16th Hebrew birthday (evening)",
      "  Diary:      star star entry",
      "  Diary:      last line no newline",
      "Saturday    3 October 2026",
      "  Diary:       9:31...... Last Quarter Moon (EDT)",
      "  Diary:      12:30...... noon lunch",
      "  Diary:      14:00...... not a continuation?",
      "  Diary:      Shemini Atzeret",
      "  Diary:      Cycle 3rd",
      "  Diary:      Anna's 16th Hebrew birthday",
      "  Diary:      star star entry",
      "  Diary:      20h00 party",
    }, lines)

    -- without the holidays, the includes and the other calendars
    setup({ include_diary = true, diary_file = path, diary_show_holidays = false })
    lines = agenda("2026-09-27")
    ok(not line_of(lines, "Shemini Atzeret"))
    ok(not line_of(lines, "Included entry"))
    ok(not line_of(lines, "Hebrew Tishri 16"))
    ok(line_of(lines, "Cycle 3rd"))
  end)

  it("skips a recursive include with a message", function()
    write("rec1", { "9/27 First file", '#include "rec2"' })
    write("rec2", { "9/27 Second file", '#include "rec1"' })
    setup({ include_diary = true, diary_file = dir .. "/rec1", diary_include_files = true })
    diary._warned = {}
    local notify, msgs = vim.notify, {}
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    local lines = agenda("2026-09-27", 1)
    vim.wait(20, function()
      return false
    end)
    vim.notify = notify
    eq({ "org agenda: recursive diary include for rec1" }, msgs)
    ok(line_of(lines, "Diary:      First file") and line_of(lines, "Diary:      Second file"))
  end)

  it("reads the european date style", function()
    local path = write("diary-eu", {
      "28/9 slash day month",
      "29/9/2026 full slash",
      "30/9/26 short year",
      "1 October Birthday of someone",
      "2 oct 10:00 meeting",
      "3 Oct. 2026 with year",
      "27 September 9am breakfast",
      "28 sept not matched?",
      "29 Sep *starred",
      "30 September",
      "  continuation after bare european date",
      "1 oct 2026 year form",
      "2 Oct 26 short year monthname",
      "* 3 star day monthname-less",
      "3 * star monthname",
      "Sonntag not a day",
      "sunday english day",
      "%%(diary-anniversary 30 9 1990) Birthday %d%s",
      "%%(diary-block 1 10 2026 2 10 2026) Block",
      "%%(diary-hebrew-yahrzeit 3 10 2000) Grandpa",
      "&%%(diary-date 27 9 t) Date eu",
    })
    setup({ include_diary = true, diary_file = path, calendar_date_style = "european" })
    eq({
      "Week-agenda (W39-W40):",
      "Sunday     27 September 2026",
      "  Diary:       9:00...... breakfast",
      "  Diary:      Date eu",
      "  Diary:      english day",
      "Monday     28 September 2026 W40",
      "  a:          Scheduled:  TODO Task",
      "  Diary:      slash day month",
      "Tuesday    29 September 2026",
      "  Diary:      full slash",
      "  Diary:      tarred",
      "Wednesday  30 September 2026",
      "  Diary:      Birthday 36th",
      "  Diary:      short year",
      "  Diary:      continuation after bare european date",
      "Thursday    1 October 2026",
      "  Diary:      Block",
      "  Diary:      Birthday of someone",
      "  Diary:      year form",
      "Friday      2 October 2026",
      "  Diary:      10:00...... meeting",
      "  Diary:      Block",
      "  Diary:      short year monthname",
      "Saturday    3 October 2026",
      "  Diary:      Shemini Atzeret",
      "  Diary:      star monthname",
      "  Diary:      with year",
    }, agenda("2026-09-27"))
  end)

  it("reads the iso date style", function()
    local path = write("diary-iso", {
      "9/28 month slash day",
      "9-29 month dash day",
      "2026/9/30 year slash",
      "2026-10-01 full iso",
      "26-10-02 short year",
      "2026 oct 3 year monthname",
      "Sep 27 monthname day",
      "sept 28 no",
      "2026-9-29",
      " continuation after bare iso",
      "*-30 star month",
      "2026-*-01 star month full",
      "Saturday day entry",
      "%%(diary-anniversary 1990 9 30) Birthday %d%s",
      "%%(diary-block 2026 10 1 2026 10 2) Block",
      "%%(diary-date t 9 27) Date iso",
    })
    setup({ include_diary = true, diary_file = path, calendar_date_style = "iso" })
    eq({
      "Week-agenda (W39-W40):",
      "Sunday     27 September 2026",
      "  Diary:      Date iso",
      "  Diary:      monthname day",
      "Monday     28 September 2026 W40",
      "  a:          Scheduled:  TODO Task",
      "  Diary:      month slash day",
      "Tuesday    29 September 2026",
      "  Diary:      month dash day; continuation after bare iso",
      "Wednesday  30 September 2026",
      "  Diary:      Birthday 36th",
      "  Diary:      star month",
      "  Diary:      year slash",
      "Thursday    1 October 2026",
      "  Diary:      Block",
      "  Diary:      full iso",
      "  Diary:      star month full",
      "Friday      2 October 2026",
      "  Diary:      Block",
      "  Diary:      short year",
      "Saturday    3 October 2026",
      "  Diary:      Shemini Atzeret",
      "  Diary:      year monthname",
      "  Diary:      day entry",
    }, agenda("2026-09-27"))
  end)

  it("shows the holidays without a diary file", function()
    setup({ include_diary = true, diary_file = dir .. "/nonexistent" })
    eq({
      "3 days-agenda (W16-W17):",
      "Saturday   19 April 2025",
      "Sunday     20 April 2025",
      "  Diary:      First Day of Ridvan",
      "  Diary:      Easter Sunday",
      "Monday     21 April 2025 W17",
    }, agenda("2025-04-19", 3))
  end)

  it("is toggled with D and jumps to the diary file", function()
    local path = write("diary-toggle", { "9/28 Toggle entry", "  second line" })
    setup({ diary_file = path })
    local lines = agenda("2026-09-27")
    ok(not line_of(lines, "Toggle entry"))
    local msgs = {}
    local orig_notify, orig_error = utils.notify, utils.error
    utils.notify = function(m)
      msgs[#msgs + 1] = m
    end
    utils.error = function(m)
      msgs[#msgs + 1] = m
    end
    view.actions.toggle_diary()
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local l = line_of(lines, "Toggle entry; second line")
    local hol = line_of(lines, "Shemini Atzeret")
    ok(l and hol, vim.inspect(lines))
    -- commands on the entry are not allowed; the location is the last line
    vim.api.nvim_win_set_cursor(0, { l, 0 })
    view.actions.todo()
    local item = view.state.line_items[l]
    eq("diary", item.type)
    eq({ path, 2 }, { item.filename, item.lnum })
    eq(2, view.resolve_target(item).lnum)
    -- a holiday has no location
    eq(nil, view.resolve_target(view.state.line_items[hol]))
    view.actions.toggle_diary()
    utils.notify, utils.error = orig_notify, orig_error
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    ok(not line_of(lines, "Toggle entry"))
    eq({
      "Diary inclusion turned on",
      "Command not allowed in this line",
      "Command not allowed in this line",
      "Diary inclusion turned off",
    }, msgs)
  end)

  it("is an option of agenda blocks", function()
    local path = write("diary-block", { "9/27 Block option entry" })
    setup({ diary_file = path })
    require("org.agenda").open(
      { blocks = { { type = "agenda", span = "day", include_diary = true } } },
      { anchor = date.days_from_civil(2026, 9, 27) }
    )
    ok(line_of(vim.api.nvim_buf_get_lines(0, 0, -1, false), "Diary:      Block option entry"))
  end)

  it("defaults to ~/diary, else the Emacs user directory", function()
    local home = vim.env.HOME
    local fake = dir .. "/home"
    vim.fn.mkdir(fake .. "/.emacs.d", "p")
    vim.env.HOME = fake
    local ok1, f1 = pcall(diary.file)
    utils.writefile(fake .. "/diary", { "9/27 x" })
    local ok2, f2 = pcall(diary.file)
    vim.env.HOME = home
    eq(fake .. "/.emacs.d/diary", ok1 and f1 or tostring(f1))
    eq(fake .. "/diary", ok2 and f2 or tostring(f2))
  end)
end)
