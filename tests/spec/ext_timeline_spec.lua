local date = require("org.date")
local utils = require("org.utils")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

local today = date.today_days()
local function day(offset)
  return date.from_days(today + offset):to_string({ brackets = false })
end
local function ts(offset, extra)
  return "<" .. day(offset) .. (extra and (" " .. extra) or "") .. ">"
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/plan.org"

local LINES = {
  "* NEXT Build the thing :work:",
  "  SCHEDULED: " .. ts(-2) .. " DEADLINE: " .. ts(4),
  "* TODO Late report",
  "  DEADLINE: " .. ts(-3),
  "* TODO Write docs",
  "  SCHEDULED: " .. ts(1),
  "  :PROPERTIES:",
  "  :Effort: 16:00",
  "  :END:",
  "  :LOGBOOK:",
  "  CLOCK: [" .. day(-5) .. " 10:00]--[" .. day(-5) .. " 11:00] =>  1:00",
  "  :END:",
  "* DONE Old task",
  "  CLOSED: [" .. day(-1) .. "] SCHEDULED: " .. ts(-1),
  "* TODO Undated",
  "* TODO Only effort before a deadline :home:",
  "  DEADLINE: " .. ts(10),
  "  :PROPERTIES:",
  "  :Effort: 24:00",
  "  :END:",
}

local function write()
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
  utils.writefile(path, LINES)
  require("org.files").invalidate(path)
end

local function setup(ext)
  require("org").setup({
    org_directory = dir,
    agenda_files = { path },
    todo_keywords = { "TODO NEXT WAITING | DONE CANCELLED" },
    extensions = ext ~= nil and { timeline = ext } or nil,
  })
end

local function restore()
  require("org").setup({
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
  })
end

local timeline = require("org.extensions.timeline")

local function titles(st)
  return vim.tbl_map(function(r)
    return r.title
  end, st.rows)
end

local function row(st, title)
  for _, r in ipairs(st.rows) do
    if r.title == title then
      return r
    end
  end
end

--- The line of the buffer showing `title`.
local function line_of(st, title)
  for i, l in ipairs(buf_lines(st.buf)) do
    if l:find(title, 1, true) then
      return i, l
    end
  end
end

--- The chart part of a row (after the separator).
local function chart(l)
  return l:match("│(.*)$")
end

describe("timeline extension", function()
  after_each(function()
    timeline.close()
    restore()
  end)

  it("is off by default", function()
    setup(nil)
    eq(nil, require("org.actions").list.timeline_open)
    eq(nil, require("org.commands").extra.timeline)
  end)

  it("registers its actions, command and key when enabled", function()
    setup({})
    ok(require("org.actions").list.timeline_open)
    ok(require("org.actions").list.timeline_buffer)
    ok(require("org.commands").extra.timeline)
    eq("<prefix>Vt", require("org.config").opts.mappings.global.timeline_open)
  end)
end)

describe("timeline", function()
  before_each(function()
    write()
    setup({})
  end)
  after_each(function()
    timeline.close()
    restore()
  end)

  it("computes bars from SCHEDULED, DEADLINE and Effort", function()
    local st = timeline.open()
    local r = row(st, "Build the thing")
    eq({ today - 2, today + 4, false }, { r.start, r.finish, r.overdue })
    r = row(st, "Write docs")
    -- 16 hours of effort at 8 hours a day
    eq({ today + 1, today + 2 }, { r.start, r.finish })
    r = row(st, "Only effort before a deadline")
    eq({ today + 8, today + 10 }, { r.start, r.finish })
    r = row(st, "Late report")
    eq({ today - 3, today - 3, true }, { r.start, r.finish, r.overdue })
  end)

  it("lists dated tasks by start, without DONE or undated ones", function()
    local st = timeline.open()
    eq({ "Late report", "Build the thing", "Write docs", "Only effort before a deadline" }, titles(st))
  end)

  it("shows DONE tasks with show_done", function()
    setup({ show_done = true })
    local st = timeline.open()
    ok(row(st, "Old task").done)
  end)

  it("draws bars, deadlines and the overdue trail at day zoom", function()
    local st = timeline.open()
    eq("day", timeline.ZOOMS[st.zoom].name)
    -- 3 days before today, 3 columns a day
    eq(today - 3, st.start)
    local _, l = line_of(st, "Build the thing")
    local c = chart(l)
    local cells = vim.fn.split(c, [[\zs]])
    -- scheduled 2 days ago: the bar starts at the second day
    eq(" ", cells[3])
    eq("█", cells[4])
    ok(c:find("◆", 1, true))
    _, l = line_of(st, "Late report")
    c = chart(l)
    ok(c:find("◆", 1, true))
    ok(c:find("┄", 1, true), "overdue trail")
    eq(nil, c:find("█", 1, true))
  end)

  it("highlights overdue tasks, deadlines and today", function()
    local st = timeline.open()
    local groups = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.buf, -1, 0, -1, { details = true })) do
      groups[m[4].hl_group] = true
    end
    ok(groups.OrgTimelineOverdue)
    ok(groups.OrgTimelineDeadline)
    ok(groups.OrgTimelineBar)
    ok(groups.OrgTimelineToday)
    ok(groups.OrgTimelineTodayLabel)
    ok(groups.OrgTodo)
  end)

  it("labels the axis with months, days and weekdays", function()
    local st = timeline.open()
    local lines = buf_lines(st.buf)
    local d = date.from_days(st.start)
    ok(lines[3]:find(date.MONTH_NAMES[d.month], 1, true))
    ok(chart(lines[4]):find(string.format("%2d", d.day), 1, true))
    ok(chart(lines[5]):find(date.DAY_NAMES[d:weekday()]:sub(1, 2), 1, true))
  end)

  it("zooms in and out", function()
    local st = timeline.open()
    local cells = st.cells
    timeline.zoom(1)
    eq("week", timeline.ZOOMS[st.zoom].name)
    ok(st.cells > cells)
    timeline.zoom(1)
    eq("month", timeline.ZOOMS[st.zoom].name)
    -- weeks start on Monday
    eq(1, date.from_days(st.start):weekday())
    timeline.zoom(1)
    eq("month", timeline.ZOOMS[st.zoom].name)
    timeline.zoom(-1)
    timeline.zoom(-1)
    eq("day", timeline.ZOOMS[st.zoom].name)
  end)

  it("pans and goes back to today", function()
    local st = timeline.open()
    local start = st.start
    timeline.pan(1)
    eq(start + math.floor(st.cells / 2), st.start)
    timeline.pan(-1)
    timeline.pan(-1)
    eq(start - math.floor(st.cells / 2), st.start)
    timeline.goto_today()
    eq(start, st.start)
  end)

  it("shows clocked days with c", function()
    local st = timeline.open()
    timeline.pan(-1)
    local _, l = line_of(st, "Write docs")
    eq(nil, l:find("▒", 1, true))
    timeline.toggle_clocks()
    _, l = line_of(st, "Write docs")
    ok(l:find("▒", 1, true))
  end)

  it("reschedules and sets deadlines with S and D", function()
    local st = timeline.open()
    local cal = require("org.calendar")
    local pick = cal.pick
    cal.pick = function()
      return date.from_days(today + 5)
    end
    local lnum = line_of(st, "Write docs")
    vim.api.nvim_win_set_cursor(st.win, { lnum, 0 })
    timeline.plan("scheduled")
    local lnum2 = line_of(st, "Late report")
    vim.api.nvim_win_set_cursor(st.win, { lnum2, 0 })
    timeline.plan("deadline")
    cal.pick = pick
    local text = table.concat(buf_lines(utils.find_buffer(path)), "\n")
    ok(text:find("SCHEDULED: " .. ts(5), 1, true), text)
    ok(text:find("DEADLINE: " .. ts(5), 1, true), text)
    eq(today + 5, row(st, "Write docs").start)
    eq(false, row(st, "Late report").overdue)
  end)

  it("jumps to the task with <CR>", function()
    local st = timeline.open()
    vim.api.nvim_win_set_cursor(st.win, { line_of(st, "Write docs"), 0 })
    timeline.jump()
    ok(not vim.api.nvim_win_is_valid(st.win))
    eq(vim.uv.fs_realpath(path), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)))
    eq(5, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("filters by tag and query", function()
    local st = timeline.open({ tag = "home" })
    eq({ "Only effort before a deadline" }, titles(st))
    st = timeline.open({ filter = '(todo "NEXT")' })
    eq({ "Build the thing" }, titles(st))
  end)

  it("maps its keys", function()
    local st = timeline.open()
    for _, lhs in ipairs({ "+", "-", "[", "]", ".", "<CR>", "S", "D", "c", "r", "<Esc>" }) do
      ok(vim.fn.maparg(lhs, "n", false, true).buffer == 1, lhs)
    end
    vim.api.nvim_feedkeys("-", "x", false)
    eq("week", timeline.ZOOMS[st.zoom].name)
    eq("", vim.fn.maparg("q", "n"))
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    eq(nil, timeline.state)
  end)

  it("re-renders when an org file is written", function()
    local st = timeline.open()
    local b = utils.load_buffer(path)
    vim.api.nvim_buf_set_lines(b, -1, -1, false, { "* TODO Added later", "  DEADLINE: " .. ts(2) })
    vim.api.nvim_buf_call(b, function()
      vim.cmd("silent write")
    end)
    ok(vim.wait(2000, function()
      return row(st, "Added later") ~= nil
    end))
  end)

  it("parses :Org timeline arguments", function()
    eq({}, timeline.parse_args(""))
    eq({ source = "buffer", zoom = "week" }, timeline.parse_args("buffer week"))
    eq({ zoom = "month", filter = "work" }, timeline.parse_args("month work"))
    eq({ filter = '(todo "NEXT")' }, timeline.parse_args('(todo "NEXT")'))
  end)
end)

describe("timeline details", function()
  before_each(function()
    write()
    setup({})
  end)
  after_each(function()
    timeline.close()
    restore()
  end)

  local function open_lines(lines, o)
    org_buffer(lines)
    return timeline.open(vim.tbl_extend("force", { source = "buffer" }, o or {}))
  end

  --- The chart characters of the row showing `title`.
  local function cells_of(st, title)
    local _, l = line_of(st, title)
    return vim.fn.split(chart(l), [[\zs]])
  end

  local function groups(st)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.buf, -1, 0, -1, { details = true })) do
      out[m[4].hl_group] = true
    end
    return out
  end

  it("draws the next occurrences of repeating tasks", function()
    local st = open_lines({
      "* TODO Weekly review",
      "  SCHEDULED: " .. ts(1, "+1w"),
      "* TODO Rent",
      "  DEADLINE: " .. ts(2, "+1w"),
    }, { zoom = "week" })
    local c = cells_of(st, "Weekly review")
    local function at(day)
      return c[day - st.start + 1]
    end
    eq("█", at(today + 1))
    eq(" ", at(today + 2))
    eq("█", at(today + 8))
    eq("█", at(today + 15))
    c = cells_of(st, "Rent")
    eq("◆", at(today + 2))
    eq("◆", at(today + 9))
    eq(" ", at(today + 5))
    ok(groups(st).OrgTimelineRepeat)
  end)

  it("places timed tasks in their part of the day at day zoom", function()
    local st = open_lines({
      "* TODO Meeting",
      "  SCHEDULED: " .. ts(0, "14:00-15:00"),
      "* TODO Evening deadline",
      "  DEADLINE: " .. ts(0, "20:00"),
      "* TODO Morning start",
      "  SCHEDULED: " .. ts(0, "07:00"),
    })
    eq("day", timeline.ZOOMS[st.zoom].name)
    local p = (today - st.start) * 3
    local c = cells_of(st, "Meeting")
    eq({ " ", "█", " " }, { c[p + 1], c[p + 2], c[p + 3] })
    c = cells_of(st, "Evening deadline")
    eq({ " ", " ", "◆" }, { c[p + 1], c[p + 2], c[p + 3] })
    c = cells_of(st, "Morning start")
    eq({ "█", "█", "█" }, { c[p + 1], c[p + 2], c[p + 3] })
    eq(" ", c[p + 4])
  end)

  it("pans and zooms without rebuilding", function()
    local st = timeline.open()
    local build = timeline.build
    local n = 0
    timeline.build = function(...)
      n = n + 1
      return build(...)
    end
    timeline.pan(1)
    timeline.zoom(1)
    timeline.goto_today()
    timeline.build = build
    eq(0, n)
    ok(row(st, "Build the thing"))
  end)

  it("narrows the labels in a narrow window", function()
    local columns = vim.o.columns
    vim.o.columns = 40
    local st = timeline.open()
    vim.o.columns = columns
    ok(st.cells >= 5, st.cells)
    local _, l = line_of(st, "NEXT Build")
    ok(vim.fn.strdisplaywidth(l:match("^(.-)│")) <= 16, l)
  end)

  it("shows the filter and the tag", function()
    local st = timeline.open({ tag = "work", filter = '(todo "NEXT")' })
    local head = buf_lines(st.buf)[1]
    ok(head:find("tag work", 1, true), head)
    ok(head:find('(todo "NEXT")', 1, true), head)
  end)

  it("shows calendar events with the ics extension", function()
    local ics = dir .. "/cal.ics"
    local d = date.from_days(today + 1)
    local stamp = string.format("%04d%02d%02d", d.year, d.month, d.day)
    utils.writefile(ics, {
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "BEGIN:VEVENT",
      "UID:dentist-1",
      "DTSTART:" .. stamp .. "T100000",
      "DTEND:" .. stamp .. "T110000",
      "SUMMARY:Dentist",
      "END:VEVENT",
      "END:VCALENDAR",
    })
    require("org").setup({
      org_directory = dir,
      agenda_files = { path },
      todo_keywords = { "TODO NEXT WAITING | DONE CANCELLED" },
      extensions = {
        timeline = {},
        ics = { calendars = { { name = "Home", path = ics } }, auto_refresh = false },
      },
    })
    local st = timeline.open()
    ok(row(st, "Dentist"), vim.inspect(buf_lines(st.buf)))
    local p = (today + 1 - st.start) * 3
    local c = cells_of(st, "Dentist")
    eq({ " ", "█", " " }, { c[p + 1], c[p + 2], c[p + 3] })
    ok(groups(st).OrgTimelineEvent)
    -- nothing to open or reschedule
    vim.api.nvim_win_set_cursor(st.win, { line_of(st, "Dentist"), 0 })
    local notify = vim.notify
    vim.notify = function() end
    timeline.jump()
    timeline.plan("scheduled")
    vim.notify = notify
    ok(vim.api.nvim_win_is_valid(st.win))
  end)

  it("parses a TODO match with a slash as a filter, and completes arguments", function()
    eq({ filter = "work/NEXT" }, timeline.parse_args("work/NEXT"))
    local c = require("org.commands").complete("", "Org timeline ")
    ok(vim.tbl_contains(c, "week"), vim.inspect(c))
    ok(vim.tbl_contains(c, "buffer"), vim.inspect(c))
  end)
end)
