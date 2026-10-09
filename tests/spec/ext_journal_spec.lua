local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
local date = require("org.date")
local utils = require("org.utils")

local dir
local saved = {}

local function stub(mod, name, fn)
  saved[#saved + 1] = { mod, name, mod[name] }
  mod[name] = fn
end

-- today is Thursday 2026-10-08, 14:05
local T = date.days_from_civil(2026, 10, 8)

local function freeze(days)
  stub(date, "today_days", function()
    return days
  end)
  stub(date, "today", function()
    return date.from_days(days)
  end)
  stub(date, "now", function()
    return date.from_days(days, { hour = 14, min = 5 })
  end)
end

local function setup(opts)
  require("org").setup({
    org_directory = dir,
    agenda_files = {},
    todo_keywords = { "TODO NEXT | DONE" },
    extensions = { journal = vim.tbl_extend("force", { directory = dir }, opts or {}) },
  })
end

local function write(rel, lines)
  local path = dir .. "/" .. rel
  utils.writefile(path, lines)
  return path
end

local function read(rel)
  return utils.readfile(dir .. "/" .. rel) or {}
end

local function wipe()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name ~= "" and name:find(dir, 1, true) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

local function core()
  return require("org.extensions.journal.core")
end

local function cmds()
  return require("org.extensions.journal.commands")
end

local function d(y, m, dd)
  return date.from_days(date.days_from_civil(y, m, dd))
end

local function cur_name()
  return vim.fs.basename(vim.api.nvim_buf_get_name(0))
end

describe("journal extension", function()
  before_each(function()
    dir = vim.fn.tempname() .. "/journal"
    vim.fn.mkdir(dir, "p")
    dir = utils.realpath(dir)
    freeze(T)
    setup()
  end)

  after_each(function()
    vim.cmd("silent! stopinsert")
    wipe()
    for i = #saved, 1, -1 do
      local s = saved[i]
      s[1][s[2]] = s[3]
    end
    saved = {}
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      agenda_files = { root .. "/tests/fixtures/*.org" },
    })
  end)

  describe("registration", function()
    it("adds its actions, commands and global keys", function()
      local actions = require("org.actions")
      for _, name in ipairs({
        "journal_new_entry",
        "journal_open",
        "journal_new_date_entry",
        "journal_new_scheduled_entry",
        "journal_next",
        "journal_previous",
        "journal_search",
        "journal_calendar",
      }) do
        ok(actions.list[name], name)
      end
      ok(require("org.commands").extra.journal_search)
      eq("<prefix>Lj", require("org.config").opts.mappings.global.journal_new_entry)
      eq(true, require("org.extensions").enabled("journal"))
    end)

    it("is gone after a setup without it", function()
      setup({ agenda = true })
      ok(require("org.files").agenda_sources.journal)
      require("org").setup({ org_directory = dir })
      eq(nil, require("org.actions").list.journal_new_entry)
      eq(nil, require("org.files").agenda_sources.journal)
    end)

    it("completes the search ranges", function()
      eq({ "week" }, cmds().complete_search("we"))
    end)

    it("has health checks", function()
      local msgs = {}
      local h = {}
      for _, k in ipairs({ "start", "ok", "info", "warn", "error" }) do
        h[k] = function(m)
          msgs[#msgs + 1] = k .. ": " .. m
        end
      end
      require("org.extensions.journal").health(h, require("org.extensions").opts("journal"))
      local text = table.concat(msgs, "\n")
      ok(text:find("ok: journal directory", 1, true), text)
      ok(text:find("names daily files", 1, true), text)
      ok(not text:find("error:", 1, true), text)
      setup({ file_type = "monthly", file_format = "%Y.org", carryover = "TODO=" })
      msgs = {}
      require("org.extensions.journal").health(h, require("org.extensions").opts("journal"))
      text = table.concat(msgs, "\n")
      ok(text:find("can't name monthly files", 1, true), text)
    end)
  end)

  describe("files", function()
    it("names daily, weekly, monthly and yearly files after the period's first day", function()
      eq(dir .. "/20261008.org", core().path(d(2026, 10, 8)))
      setup({ file_type = "weekly" })
      eq(dir .. "/20261005.org", core().path(d(2026, 10, 8)))
      eq(dir .. "/20261005.org", core().path(d(2026, 10, 11)))
      setup({ file_type = "weekly", start_on_weekday = 7 })
      eq(dir .. "/20261004.org", core().path(d(2026, 10, 8)))
      eq(dir .. "/20261004.org", core().path(d(2026, 10, 4)))
      eq(dir .. "/20260927.org", core().path(d(2026, 10, 3)))
      setup({ file_type = "monthly", file_format = "%Y-%m.org" })
      eq(dir .. "/2026-10.org", core().path(d(2026, 10, 8)))
      setup({ file_type = "yearly", file_format = "%Y.org" })
      eq(dir .. "/2026.org", core().path(d(2026, 10, 8)))
    end)

    it("reads dates back from file names", function()
      eq("2026-10-08", core().date_of_name("20261008.org"):to_date_string())
      eq(nil, (core().date_of_name("notes.org")))
      eq(false, select(2, core().date_of_name("notes.org")))
      setup({ file_format = "%F-%A.org" })
      eq("2026-10-08", core().date_of_name("2026-10-08-Thursday.org"):to_date_string())
      setup({ file_type = "weekly", file_format = "%G-W%V.org" })
      eq(dir .. "/2026-W41.org", core().path(d(2026, 10, 8)))
      eq("2026-10-05", core().date_of_name("2026-W41.org"):to_date_string())
      setup({ file_format = "%Y/%m/%d.org" })
      eq(dir .. "/2026/10/08.org", core().path(d(2026, 10, 8)))
      eq("2026-10-08", core().date_of_name("2026/10/08.org"):to_date_string())
    end)

    it("lists only journal files", function()
      write("20261001.org", { "* Thursday, 2026-10-01" })
      write("notes.org", { "* Notes" })
      write("2026/20261002.org", { "* x" })
      eq({ dir .. "/20261001.org" }, core().files())
      setup({ file_format = "%Y/%Y%m%d.org" })
      eq({ dir .. "/2026/20261002.org" }, core().files())
    end)
  end)

  describe("new entry", function()
    it("makes today's file with its header, day heading and a timed entry", function()
      setup({ file_header = "#+title: Journal %Y-%m-%d" })
      cmds().new_entry()
      eq("20261008.org", cur_name())
      eq("org", vim.bo.filetype)
      eq({ "#+title: Journal 2026-10-08", "* Thursday, 2026-10-08", "** 14:05 " }, buf_lines(0))
      -- Normal mode keeps the cursor on the last character (Insert mode
      -- starts after it with a UI)
      eq({ 3, 8 }, vim.api.nvim_win_get_cursor(0))
      -- another one goes after the first entry and its text
      vim.api.nvim_buf_set_lines(0, 2, 3, false, { "** 14:05 Lunch", "Pasta.", "" })
      cmds().new_entry()
      eq(
        { "#+title: Journal 2026-10-08", "* Thursday, 2026-10-08", "** 14:05 Lunch", "Pasta.", "** 14:05 ", "" },
        buf_lines(0)
      )
      eq({ 5, 8 }, vim.api.nvim_win_get_cursor(0))
    end)

    it("takes a function for the header and day heading", function()
      setup({
        file_header = function(day)
          return "#+title: " .. day:to_date_string() .. "\n#+filetags: :journal:\n"
        end,
        date_format = function(day)
          return "* Day " .. day.day
        end,
        time_format = "",
      })
      cmds().new_entry()
      eq({ "#+title: 2026-10-08", "#+filetags: :journal:", "* Day 8", "** " }, buf_lines(0))
    end)

    it("adds an entry template with the cursor at %?", function()
      setup({ entry_template = "- Mood: %?\n- Weather:" })
      cmds().new_entry()
      eq({ "* Thursday, 2026-10-08", "** 14:05 ", "- Mood: ", "- Weather:" }, buf_lines(0))
      eq({ 3, 7 }, vim.api.nvim_win_get_cursor(0))
    end)

    it("runs a string entry template through format-time-string, keeping %?", function()
      setup({ entry_template = "Logged %F, 100%% sure\n%?" })
      cmds().new_entry()
      eq({ "* Thursday, 2026-10-08", "** 14:05 ", "Logged 2026-10-08, 100% sure", "" }, buf_lines(0))
      eq({ 4, 0 }, vim.api.nvim_win_get_cursor(0))
    end)

    it("writes an untimed entry on another day", function()
      cmds().new_entry("2026-10-01")
      eq("20261001.org", cur_name())
      eq({ "* Thursday, 2026-10-01", "** " }, buf_lines(0))
    end)

    it("opens today without adding an entry", function()
      write("20261008.org", { "* Thursday, 2026-10-08", "** 09:00 Coffee", "Good." })
      cmds().open_today()
      eq({ "* Thursday, 2026-10-08", "** 09:00 Coffee", "Good." }, buf_lines(0))
      eq(1, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("adds the day heading to a daily file without one", function()
      write("20261008.org", { "#+title: Today" })
      cmds().new_entry()
      eq({ "#+title: Today", "* Thursday, 2026-10-08", "** 14:05 " }, buf_lines(0))
    end)

    it("makes the whole daily file the day with a prefix that isn't a heading", function()
      setup({ date_prefix = "#+title: ", time_prefix = "* " })
      cmds().new_entry()
      eq({ "#+title: Thursday, 2026-10-08", "* 14:05 " }, buf_lines(0))
      cmds().new_entry()
      eq({ "#+title: Thursday, 2026-10-08", "* 14:05 ", "* 14:05 " }, buf_lines(0))
      eq(1, #core().days())
    end)

    it("adds the day line after the file header with a prefix that isn't a heading", function()
      setup({ date_prefix = "#+title: ", time_prefix = "* ", file_header = "#+author: me" })
      cmds().new_entry()
      eq({ "#+author: me", "#+title: Thursday, 2026-10-08", "* 14:05 " }, buf_lines(0))
      cmds().new_entry()
      eq({ "#+author: me", "#+title: Thursday, 2026-10-08", "* 14:05 ", "* 14:05 " }, buf_lines(0))
      eq(1, #core().days())
      eq(2, core().days()[1].line)
      -- a file with other text but no day line gets one
      write("20261001.org", { "#+author: me", "* old entry" })
      eq(1, #core().days())
      cmds().new_entry("2026-10-01")
      eq({ "#+author: me", "* old entry", "#+title: Thursday, 2026-10-01", "* " }, buf_lines(0))
    end)

    it("keeps the days of weekly files in date order with a CREATED property", function()
      setup({ file_type = "weekly" })
      cmds().new_entry()
      eq("20261005.org", cur_name())
      cmds().new_entry("2026-10-06")
      eq({
        "* Tuesday, 2026-10-06",
        ":PROPERTIES:",
        ":CREATED:  20261006",
        ":END:",
        "** ",
        "* Thursday, 2026-10-08",
        ":PROPERTIES:",
        ":CREATED:  20261008",
        ":END:",
        "** 14:05 ",
      }, buf_lines(0))
      eq(5, vim.api.nvim_win_get_cursor(0)[1])
      cmds().new_entry("2026-10-10")
      eq("* Saturday, 2026-10-10", buf_lines(0)[11])
      local days = vim.tbl_map(function(day)
        return day.date:to_date_string()
      end, core().days())
      eq({ "2026-10-06", "2026-10-08", "2026-10-10" }, days)
    end)
  end)

  describe("carry-over", function()
    local OLD = {
      "* Wednesday, 2026-10-07",
      "** 09:00 Morning",
      "Coffee.",
      "** Work",
      "*** TODO Fix the bug",
      "    Seen on <2026-10-07 Wed>.",
      "    SCHEDULED: <2026-10-07 Wed>",
      "*** DONE Ship it",
      "** Home",
      "*** TODO Call mom",
      "** NEXT Read",
    }

    it("moves unfinished items, with the headings above them, into today", function()
      write("20261007.org", OLD)
      write("20261001.org", { "* Thursday, 2026-10-01", "** TODO Older" })
      cmds().new_entry()
      eq({
        "* Thursday, 2026-10-08",
        "** Work",
        "*** TODO Fix the bug",
        "    Seen on <2026-10-08 Thu>.",
        "    SCHEDULED: <2026-10-07 Wed>",
        "** Home",
        "*** TODO Call mom",
        "** 14:05 ",
      }, buf_lines(0))
      -- the whole day is unfolded
      eq("expr", vim.wo.foldmethod)
      eq(-1, vim.fn.foldclosed(3))
      eq(-1, vim.fn.foldclosed(7))
      -- moved: Home went with its only item, Work stays for DONE
      eq(
        { "* Wednesday, 2026-10-07", "** 09:00 Morning", "Coffee.", "** Work", "*** DONE Ship it", "** NEXT Read" },
        read("20261007.org")
      )
      -- both files are saved
      eq("** Work", read("20261008.org")[2])
      eq({ "* Thursday, 2026-10-01", "** TODO Older" }, read("20261001.org"))
      -- nothing more to move the second time
      cmds().new_entry()
      eq(9, #buf_lines(0))
    end)

    it("takes any tags/property match", function()
      write("20261007.org", OLD)
      setup({ carryover = 'TODO="TODO"|TODO="NEXT"' })
      cmds().open_today()
      eq({
        "* Thursday, 2026-10-08",
        "** Work",
        "*** TODO Fix the bug",
        "    Seen on <2026-10-08 Thu>.",
        "    SCHEDULED: <2026-10-07 Wed>",
        "** Home",
        "*** TODO Call mom",
        "** NEXT Read",
      }, buf_lines(0))
    end)

    it("is off with carryover = false and for other days", function()
      write("20261007.org", OLD)
      setup({ carryover = false })
      cmds().new_entry()
      eq({ "* Thursday, 2026-10-08", "** 14:05 " }, buf_lines(0))
      setup()
      cmds().new_entry("2026-10-09")
      eq({ "* Friday, 2026-10-09", "** " }, buf_lines(0))
      eq(OLD, read("20261007.org"))
    end)

    it("deletes an empty previous day file with carryover_delete_empty", function()
      write("20261007.org", { "* Wednesday, 2026-10-07", ":PROPERTIES:", ":X: 1", ":END:", "** TODO Only task", "" })
      setup({ carryover_delete_empty = true })
      cmds().new_entry()
      eq(0, vim.fn.filereadable(dir .. "/20261007.org"))
      eq({ "* Thursday, 2026-10-08", "** TODO Only task", "** 14:05 " }, buf_lines(0))
    end)

    it('asks before deleting with "ask", and keeps it by default', function()
      write("20261007.org", { "* Wednesday, 2026-10-07", "** TODO Only task" })
      cmds().open_today()
      eq({ "* Wednesday, 2026-10-07" }, read("20261007.org"))
      wipe()
      write("20261006.org", { "* Tuesday, 2026-10-06", "** TODO Task" })
      vim.fn.delete(dir .. "/20261007.org")
      vim.fn.delete(dir .. "/20261008.org")
      setup({ carryover_delete_empty = "ask" })
      local asked
      stub(utils, "confirm", function(msg)
        asked = msg
        return false
      end)
      cmds().open_today()
      ok(asked)
      eq({ "* Tuesday, 2026-10-06" }, read("20261006.org"))
    end)

    it("deletes only the empty day in a weekly file, from the same buffer", function()
      setup({ file_type = "weekly", carryover_delete_empty = true })
      write("20261005.org", {
        "* Monday, 2026-10-05",
        ":PROPERTIES:",
        ":CREATED:  20261005",
        ":END:",
        "** Done",
        "* Tuesday, 2026-10-06",
        ":PROPERTIES:",
        ":CREATED:  20261006",
        ":END:",
        "** TODO Carry me",
      })
      cmds().open_today()
      eq({
        "* Monday, 2026-10-05",
        ":PROPERTIES:",
        ":CREATED:  20261005",
        ":END:",
        "** Done",
        "* Thursday, 2026-10-08",
        ":PROPERTIES:",
        ":CREATED:  20261008",
        ":END:",
        "** TODO Carry me",
      }, buf_lines(0))
    end)

    it("warns about a bad match", function()
      write("20261007.org", OLD)
      setup({ carryover = "TODO={[}" })
      local warned
      stub(utils, "warn", function(m)
        warned = m
      end)
      cmds().open_today()
      ok(warned and warned:find("carryover", 1, true))
      eq(OLD, read("20261007.org"))
    end)
  end)

  describe("moving between days", function()
    before_each(function()
      write("20261001.org", { "* Thursday, 2026-10-01", "** one" })
      write("20261003.org", { "* Saturday, 2026-10-03", "** three" })
      write("20261007.org", { "#+title: x", "", "* Wednesday, 2026-10-07", "** seven" })
      write("20261012.org", { "* Monday, 2026-10-12", "** TODO twelve" })
    end)

    it("goes to the next and previous day with entries, with a count", function()
      cmds().previous()
      eq("20261007.org", cur_name())
      eq(3, vim.api.nvim_win_get_cursor(0)[1])
      cmds().previous(2)
      eq("20261001.org", cur_name())
      cmds().next()
      eq("20261003.org", cur_name())
      cmds().next("2")
      eq("20261012.org", cur_name())
      local warned
      stub(utils, "warn", function(m)
        warned = m
      end)
      cmds().next()
      eq("20261012.org", cur_name())
      ok(warned and warned:find("no entry after", 1, true))
    end)

    it("starts from today outside the journal", function()
      vim.cmd("enew!")
      cmds().next()
      eq("20261012.org", cur_name())
    end)

    it("moves between the days of a weekly file", function()
      setup({ file_type = "weekly" })
      write("20261005.org", {
        "* Monday, 2026-10-05",
        ":PROPERTIES:",
        ":CREATED:  20261005",
        ":END:",
        "* Wednesday, 2026-10-07",
        ":PROPERTIES:",
        ":CREATED:  20261007",
        ":END:",
      })
      vim.cmd("edit " .. dir .. "/20261005.org")
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      cmds().next()
      eq(5, vim.api.nvim_win_get_cursor(0)[1])
      cmds().previous()
      eq(1, vim.api.nvim_win_get_cursor(0)[1])
    end)
  end)

  describe("calendar", function()
    before_each(function()
      write("20261001.org", { "* Thursday, 2026-10-01", "** one" })
      write("20261012.org", { "* Monday, 2026-10-12", "** TODO twelve" })
    end)

    it("marks past and future days with entries", function()
      local marks = cmds().marks()
      eq("OrgCalendarMarked", marks[date.days_from_civil(2026, 10, 1)])
      eq("OrgCalendarMarkedFuture", marks[date.days_from_civil(2026, 10, 12)])
      local _, hl = require("org.calendar").render(d(2026, 10, 8), { marks = marks, today = d(2026, 10, 8) })
      local found = false
      for _, m in ipairs(hl) do
        if m[4] == "OrgCalendarMarked" then
          found = true
        end
      end
      ok(found)
      eq("2026-10-12", require("org.calendar").next_mark(marks, T, 1):to_date_string())
      eq("2026-10-01", require("org.calendar").next_mark(marks, T, -1):to_date_string())
      eq(nil, require("org.calendar").next_mark(marks, date.days_from_civil(2026, 10, 12), 1))
    end)

    it("moves between marked days with n and p in the calendar", function()
      local keys = { "n", "n", "p", "\r" }
      local hint
      stub(vim.fn, "getcharstr", function()
        if not hint then
          for _, w in ipairs(vim.api.nvim_list_wins()) do
            local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), "\n")
            hint = hint or text:match("n/p next/previous marked day")
          end
        end
        return table.remove(keys, 1) or "\27"
      end)
      local picked = require("org.calendar").pick({ marks = cmds().marks() })
      eq("2026-10-01", picked:to_date_string())
      ok(hint)
    end)

    it("opens the chosen day, asking before making a new one", function()
      local opts
      stub(require("org.calendar"), "pick", function(o)
        opts = o
        return d(2026, 10, 1)
      end)
      cmds().calendar()
      ok(opts.marks[date.days_from_civil(2026, 10, 12)])
      eq("20261001.org", cur_name())
      stub(require("org.calendar"), "pick", function()
        return d(2026, 10, 2)
      end)
      stub(utils, "confirm", function()
        return false
      end)
      cmds().calendar()
      eq("20261001.org", cur_name())
      stub(utils, "confirm", function()
        return true
      end)
      cmds().calendar()
      eq("20261002.org", cur_name())
      eq({ "* Friday, 2026-10-02" }, buf_lines(0))
    end)
  end)

  describe("scheduled entries", function()
    it("writes a TODO with an active timestamp on a future day", function()
      setup({ scheduled_string = "SCHEDULED:" })
      cmds().new_scheduled_entry("2026-10-15")
      eq("20261015.org", cur_name())
      eq({ "* Thursday, 2026-10-15", "** TODO ", "SCHEDULED: <2026-10-15 Thu>" }, buf_lines(0))
      eq({ 2, 7 }, vim.api.nvim_win_get_cursor(0))
    end)

    it("keeps a time", function()
      cmds().new_scheduled_entry("2026-10-15 10:30")
      eq({ "* Thursday, 2026-10-15", "** TODO 10:30 ", "<2026-10-15 Thu 10:30>" }, buf_lines(0))
    end)

    it("puts the timestamp under the heading with %? in the entry template", function()
      setup({ entry_template = "- Note: %?\n- By: %Y" })
      cmds().new_scheduled_entry("2026-10-15")
      eq({ "* Thursday, 2026-10-15", "** TODO ", "<2026-10-15 Thu>", "- Note: ", "- By: 2026" }, buf_lines(0))
      eq({ 4, 7 }, vim.api.nvim_win_get_cursor(0))
    end)

    it("refuses a past date", function()
      local warned
      stub(utils, "warn", function(m)
        warned = m
      end)
      cmds().new_scheduled_entry("2026-10-01")
      ok(warned and warned:find("future", 1, true))
    end)

    it("is what a dated entry in the future makes", function()
      stub(require("org.calendar"), "pick", function()
        return d(2026, 10, 20)
      end)
      cmds().new_date_entry()
      eq({ "* Tuesday, 2026-10-20", "** TODO ", "<2026-10-20 Tue>" }, buf_lines(0))
      stub(require("org.calendar"), "pick", function()
        return d(2026, 10, 2)
      end)
      cmds().new_date_entry()
      eq({ "* Friday, 2026-10-02", "** " }, buf_lines(0))
    end)
  end)

  describe("search", function()
    before_each(function()
      write("20261001.org", { "* Thursday, 2026-10-01", "** 08:00 Gym", "Ran 5k with Ana." })
      write("20261007.org", { "* Wednesday, 2026-10-07", "** 09:00 Lunch with ana" })
      write("20261012.org", { "* Monday, 2026-10-12", "** TODO Dinner with Ana" })
    end)

    local function texts(items)
      return vim.tbl_map(function(it)
        return it.text
      end, items)
    end

    it("finds lines in a date range, ignoring case unless the text has a capital", function()
      eq({
        "Thu 2026-10-01 Ran 5k with Ana.",
        "Wed 2026-10-07 ** 09:00 Lunch with ana",
        "Mon 2026-10-12 ** TODO Dinner with Ana",
      }, texts(cmds().search_items("ana")))
      eq(2, #cmds().search_items("Ana"))
      local from, to = cmds().range("2026-10-02..2026-10-10")
      eq({ "Wed 2026-10-07 ** 09:00 Lunch with ana" }, texts(cmds().search_items("ana", from, to)))
      eq({ "Mon 2026-10-12 ** TODO Dinner with Ana" }, texts(cmds().search_items("ana", cmds().range("future"))))
      -- an empty query lists the entries
      eq(3, #cmds().search_items(""))
      setup({ search_order = "desc" })
      eq("Mon 2026-10-12 ** TODO Dinner with Ana", cmds().search_items("ana")[1].text)
    end)

    it("reads ranges", function()
      eq({ date.days_from_civil(2026, 10, 5), date.days_from_civil(2026, 10, 11) }, { cmds().range("week") })
      eq({ date.days_from_civil(2026, 10, 1), date.days_from_civil(2026, 10, 31) }, { cmds().range("month") })
      eq({ date.days_from_civil(2026, 1, 1), date.days_from_civil(2026, 12, 31) }, { cmds().range("year") })
      eq({ nil, T }, { cmds().range("past") })
      eq({ nil, nil }, { cmds().range("") })
      local _, _, err = cmds().range("someday")
      ok(err)
    end)

    it("shows the matches in a picker that jumps to them", function()
      local spec
      stub(require("org.pickers"), "pick", function(s)
        spec = s
        return "select"
      end)
      cmds().search("month with")
      eq("Journal: with", spec.title)
      eq(3, #spec.items)
      ok(spec.split)
      spec.on_choice({ spec.items[2] })
      eq("20261007.org", cur_name())
      eq(2, vim.api.nvim_win_get_cursor(0)[1])
      -- asks for the text without one
      stub(utils, "input", function()
        return "gym"
      end)
      cmds().search()
      eq(1, #spec.items)
    end)
  end)

  describe("agenda", function()
    it("adds the current and future journal files with agenda = true", function()
      write("20261001.org", { "* Thursday, 2026-10-01", "** TODO old" })
      write("20261008.org", { "* Thursday, 2026-10-08" })
      write("20261012.org", { "* Monday, 2026-10-12", "** TODO twelve" })
      eq({}, require("org.files").agenda_file_paths())
      setup({ agenda = true })
      eq({ dir .. "/20261008.org", dir .. "/20261012.org" }, require("org.files").agenda_file_paths())
      setup({ agenda = "all" })
      eq(3, #require("org.files").agenda_file_paths())
    end)

    it("counts a weekly file until its last day", function()
      setup({ file_type = "weekly", agenda = true })
      write("20260928.org", {})
      write("20261005.org", {})
      eq({ dir .. "/20261005.org" }, require("org.files").agenda_file_paths())
    end)
  end)

  describe("symlinked directory", function()
    local link, target

    before_each(function()
      target = dir .. "/target"
      link = dir .. "/link"
      vim.fn.mkdir(target, "p")
      -- a directory link on Windows is a junction (a plain symlink is a file
      -- link there, and a directory symlink needs admin rights)
      ok(vim.uv.fs_symlink(target, link, { junction = vim.fn.has("win32") == 1 }))
      setup({ directory = link })
    end)

    it("makes entries, finds the day again and moves between days", function()
      local warned
      stub(utils, "warn", function(m)
        warned = m
      end)
      utils.writefile(link .. "/20261007.org", { "* Wednesday, 2026-10-07", "** seven" })
      cmds().new_entry()
      eq(nil, warned)
      eq({ "* Thursday, 2026-10-08", "** 14:05 " }, buf_lines(0))
      cmds().new_entry()
      eq(nil, warned)
      eq({ "* Thursday, 2026-10-08", "** 14:05 ", "** 14:05 " }, buf_lines(0))
      -- the file isn't written yet: still a day
      eq(0, vim.fn.filereadable(target .. "/20261008.org"))
      eq(2, #core().days())
      -- the buffer is in the journal, by either name
      ok(core().is_journal(vim.api.nvim_buf_get_name(0)))
      ok(core().is_journal(link .. "/20261008.org"))
      ok(core().is_journal(target .. "/20261008.org"))
      -- previous starts from this day, not from today outside the journal
      vim.cmd("silent write")
      write("target/20261009.org", { "* Friday, 2026-10-09" })
      vim.cmd("edit " .. link .. "/20261009.org")
      cmds().previous()
      eq("20261008.org", cur_name())
      cmds().previous()
      eq("20261007.org", cur_name())
    end)

    it("fails without a duplicate day when the file is outside the journal", function()
      local warned = {}
      stub(utils, "warn", function(m)
        warned[#warned + 1] = m
      end)
      -- the journal file name opens somewhere else
      stub(utils, "open_file", function()
        vim.cmd("edit " .. dir .. "/elsewhere.org")
      end)
      cmds().new_entry()
      cmds().new_entry()
      eq(2, #warned)
      ok(warned[1]:find("not in the journal directory", 1, true), warned[1])
      ok(not warned[1]:find("table: 0x", 1, true))
      eq({ "" }, buf_lines(0))
    end)
  end)

  describe("many files", function()
    local parses

    before_each(function()
      for i = 0, 199 do
        local day = date.from_days(T - 200 + i)
        write(day:strftime("%Y%m%d.org"), { "* " .. day:strftime("%A, %Y-%m-%d"), "** TODO task " .. i })
      end
      parses = 0
      local files = require("org.files")
      local get, get_buffer = files.get, files.get_buffer
      stub(files, "get", function(...)
        parses = parses + 1
        return get(...)
      end)
      stub(files, "get_buffer", function(...)
        parses = parses + 1
        return get_buffer(...)
      end)
    end)

    it("reads only the files it needs", function()
      local marks = cmds().marks()
      eq(0, parses)
      eq("OrgCalendarMarked", marks[T - 1])
      -- carry-over reads yesterday's file, not the 199 before it
      cmds().open_today()
      eq({ "* Thursday, 2026-10-08", "** TODO task 199" }, buf_lines(0))
      -- (the buffers' own reads count too: far below one per file)
      ok(parses < 50, parses)
      parses = 0
      cmds().previous()
      eq("20261007.org", cur_name())
      ok(parses < 10, parses)
      parses = 0
      local from, to = cmds().range("2026-10-01..2026-10-03")
      eq(3, #cmds().search_items("task", from, to))
      ok(parses < 10, parses)
    end)
  end)

  describe("journal edge cases", function()
    it("skips file names that aren't real dates", function()
      write("20261399.org", { "* bogus" })
      write("20261001.org", { "* Thursday, 2026-10-01" })
      local days = core().days()
      eq(1, #days)
      eq("2026-10-01", days[1].date:to_date_string())
    end)

    it("counts a new day that isn't written yet", function()
      cmds().open_today()
      eq(0, vim.fn.filereadable(dir .. "/20261008.org"))
      eq(1, #core().days())
      eq(cmds().marks()[T], "OrgCalendarMarked")
    end)

    it("doesn't add the day twice", function()
      cmds().open_today()
      cmds().open_today()
      cmds().new_entry()
      eq({ "* Thursday, 2026-10-08", "** 14:05 " }, buf_lines(0))
    end)

    it("carries nothing over without an earlier day", function()
      write("20261012.org", { "* Monday, 2026-10-12", "** TODO Later" })
      cmds().open_today()
      eq({ "* Thursday, 2026-10-08" }, buf_lines(0))
      eq({ "* Monday, 2026-10-12", "** TODO Later" }, read("20261012.org"))
    end)

    it("warns when there are no days to move to", function()
      local warned
      stub(utils, "warn", function(m)
        warned = m
      end)
      eq(false, cmds().step(1))
      ok(warned and warned:find("no entry after", 1, true))
    end)

    it("tells when a search finds nothing and rejects a bad range", function()
      write("20261001.org", { "* Thursday, 2026-10-01", "** Gym" })
      local msgs = {}
      stub(utils, "notify", function(m)
        msgs[#msgs + 1] = m
      end)
      stub(utils, "warn", function(m)
        msgs[#msgs + 1] = m
      end)
      cmds().search("nothing-like-this")
      ok(msgs[1]:find("no matches", 1, true))
      local _, _, err = cmds().range("2026-13-45..x")
      ok(err and err:find("cannot read date", 1, true), err)
    end)

    it("searches for text with .. in it that isn't a date range", function()
      write("20261001.org", { "* Thursday, 2026-10-01", "** Gym", "wait... more reps", "2026-13-45..x gym" })
      write("20261005.org", { "* Monday, 2026-10-05", "** Gym again" })
      local spec
      stub(require("org.pickers"), "pick", function(s)
        spec = s
      end)
      local warned
      stub(utils, "warn", function(m)
        warned = m
      end)
      cmds().search("wait... more")
      eq(nil, warned)
      eq("Journal: wait... more", spec.title)
      eq(1, #spec.items)
      -- a bad date on one side makes it text too
      cmds().search("2026-13-45..x gym")
      eq(nil, warned)
      eq("Journal: 2026-13-45..x gym", spec.title)
      -- a real range still is one
      cmds().search("2026-09-01..2026-10-02 gym")
      eq("Journal: gym", spec.title)
      eq(2, #spec.items)
      cmds().search("..2026-10-02 gym")
      eq("Journal: gym", spec.title)
    end)

    it("keeps a literal %% in file names", function()
      setup({ file_format = "%%%Y%m%d.org" })
      eq(dir .. "/%20261008.org", core().path(d(2026, 10, 8)))
      eq("2026-10-08", core().date_of_name("%20261008.org"):to_date_string())
    end)

    it("reads dashed CREATED values and timestamps", function()
      eq("2026-10-08", core().parse_created("2026-10-08"):to_date_string())
      eq("2026-10-08", core().parse_created("<2026-10-08 Thu>"):to_date_string())
      eq(nil, core().parse_created("20261340"))
      eq(nil, core().parse_created(nil))
    end)
  end)
end)
