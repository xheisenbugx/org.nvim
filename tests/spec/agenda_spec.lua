local date = require("org.date")
local config = require("org.config")
local items = require("org.agenda.items")
local render = require("org.agenda.render")
local parser = require("org.parser")

local today = date.today()
local T = today:days()
local function ts(offset, extra, inactive)
  local d = today:add(offset, "d")
  local s = d:to_string({ brackets = false })
  if extra then
    s = s .. " " .. extra
  end
  return inactive and ("[" .. s .. "]") or ("<" .. s .. ">")
end

local lines = {
  "#+CATEGORY: test",
  "* TODO Scheduled today",
  "  SCHEDULED: " .. ts(0),
  "* TODO Overdue scheduled",
  "  SCHEDULED: " .. ts(-3),
  "* DONE Done scheduled",
  "  SCHEDULED: " .. ts(0),
  "* TODO Deadline soon :work:",
  "  DEADLINE: " .. ts(5),
  "* TODO Deadline past",
  "  DEADLINE: " .. ts(-2),
  "* TODO Deadline far",
  "  DEADLINE: " .. ts(40),
  "* Meeting",
  "  " .. ts(1, "10:00-11:00"),
  "* Trip",
  "  " .. ts(0) .. "--" .. ts(2),
  "* TODO Weekly",
  "  SCHEDULED: " .. ts(-1, "+1w"),
  "* TODO Habit",
  "  SCHEDULED: " .. ts(0, ".+2d"),
  "  :PROPERTIES:",
  "  :STYLE: habit",
  "  :END:",
  "  :LOGBOOK:",
  '  - State "DONE"       from "TODO"       ' .. ts(-2, "Mon 09:00", true),
  "  :END:",
  "* Archived :ARCHIVE:",
  "  SCHEDULED: " .. ts(0),
  "* COMMENT Commented",
  "  SCHEDULED: " .. ts(0),
  "* TODO Clocked",
  "  CLOSED: " .. ts(0, "12:00", true),
  "  :LOGBOOK:",
  "  CLOCK: " .. ts(0, "09:00", true) .. "--" .. ts(0, "10:30", true) .. " =>  1:30",
  "  :END:",
  "* Project",
  "** TODO Has next",
  "* Stuck project",
  "** Some note",
}
local file = parser.parse(lines, "/tmp/agenda_test.org")

local function titles(list)
  local out = {}
  for _, it in ipairs(list or {}) do
    out[#out + 1] = it.title .. (it.extra and it.extra ~= "" and (" | " .. vim.trim(it.extra)) or "")
  end
  table.sort(out)
  return out
end

describe("agenda.items", function()
  it("collects a day range", function()
    local by_day = items.agenda({ file }, T - 7, T + 7, { today = T })
    local t = titles(by_day[T])
    eq({
      "Deadline past | 2 d. ago:",
      "Deadline soon | In   5 d.:",
      "Done scheduled | Scheduled:",
      "Habit | Scheduled:",
      "Overdue scheduled | Sched. 3x:",
      "Scheduled today | Scheduled:",
      "Trip | (1/3):",
      "Weekly | Sched. 1x:",
    }, t)
    eq({ "Meeting", "Trip | (2/3):" }, titles(by_day[T + 1]))
    eq({ "Deadline soon | Deadline:" }, titles(by_day[T + 5]))
    eq({ "Weekly | Scheduled:" }, titles(by_day[T + 6]))
    eq({ "Overdue scheduled | Scheduled:" }, titles(by_day[T - 3]))
    local meeting = by_day[T + 1][1]
    eq(600, meeting.time)
    eq(660, meeting.end_time)
  end)
  it("skips done items when configured", function()
    config.opts.agenda.skip_scheduled_if_done = true
    local by_day = items.agenda({ file }, T, T, { today = T })
    config.opts.agenda.skip_scheduled_if_done = false
    for _, it in ipairs(by_day[T]) do
      ok(it.title ~= "Done scheduled")
    end
  end)
  it("log mode", function()
    local by_day = items.agenda({ file }, T, T, { today = T, log_mode = true })
    local t = titles(by_day[T])
    ok(vim.tbl_contains(t, "Clocked | Closed:"))
    ok(vim.tbl_contains(t, "Clocked | Clocked:   (1:30)"))
  end)
  it("todo list and ignores", function()
    local list = items.todo({ file })
    ok(#list >= 8)
    local t = titles(list)
    ok(not vim.tbl_contains(t, "Done scheduled"))
    local only = items.todo({ file }, { "DONE" })
    eq({ "Done scheduled" }, titles(only))
    local ign = items.todo({ file }, nil, { block = { todo_ignore_scheduled = "all" } })
    for _, it in ipairs(ign) do
      ok(not it.headline.planning.scheduled)
    end
  end)
  it("stuck projects", function()
    local list = items.stuck({ file }, { block = { stuck_projects = { match = "+LEVEL=1-ARCHIVE", todo_keywords = { "TODO" } } } })
    local t = titles(list)
    ok(vim.tbl_contains(t, "Stuck project"))
    ok(not vim.tbl_contains(t, "Project"))
  end)
  it("sorts", function()
    local by_day = items.agenda({ file }, T + 1, T + 1, { today = T })
    local list = items.sort(by_day[T + 1], { "time-up", "priority-down", "category-keep" })
    eq("Meeting", list[1].title)
  end)
end)

describe("agenda.habits", function()
  it("draws a graph", function()
    local hl = file:find_by_title("Habit")
    local habits = require("org.agenda.habits")
    local h = habits.parse(hl)
    eq(2, h.min_days)
    ok(h.done_days[T - 2])
    local g = habits.graph(h, T)
    eq(29, #g)
    eq("*", g[22 - 2][1])
    eq("!", g[22][1])
  end)
end)

describe("agenda.render", function()
  it("formats date headers", function()
    local d = date.parse("<2026-09-23 Wed>")
    eq("Wednesday  23 September 2026 W39", render.date_header(d:days(), true))
    eq(1, render.iso_week(date.parse("<2026-01-01 Thu>"):days()))
    eq(53, render.iso_week(date.parse("<2020-12-31 Thu>"):days()))
  end)
  it("computes ranges", function()
    local wed = date.parse("<2026-09-23 Wed>"):days()
    local from, to = render.range("week", wed, true)
    eq(wed - 2, from)
    eq(wed + 4, to)
    from, to = render.range("month", wed, true)
    eq(date.parse("<2026-09-01 Tue>"):days(), from)
    eq(date.parse("<2026-09-30 Wed>"):days(), to)
    eq(date.parse("<2026-10-23 Fri>"):days(), render.shift_anchor("month", wed, 1))
  end)
  it("renders a view", function()
    local b = render.view({ blocks = { { type = "agenda", span = "day" }, { type = "todo" } } }, {
      today = T,
      now = 8 * 60,
      width = 100,
      anchor = T,
      align = true,
      files_for = function()
        return { file }
      end,
      todo_names = { "TODO", "DONE" },
    })
    ok(b.lines[1]:match("^Day%-agenda"))
    local text = table.concat(b.lines, "\n")
    ok(text:find("test:%s+Scheduled: TODO Scheduled today"), text)
    ok(text:find("Global list of TODO items of type: ALL"), text)
    local tagline
    for _, l in ipairs(b.lines) do
      if l:find("Deadline soon") then
        tagline = l
      end
    end
    ok(tagline:match(":work:$"))
    eq(99, vim.api.nvim_strwidth(tagline))
    ok(vim.tbl_count(b.items) > 5)
  end)
end)

describe("agenda.view", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/a.org"
  require("org.utils").writefile(path, lines)
  it("opens the agenda buffer and acts on items", function()
    config.opts.agenda_files = { path }
    config.opts.agenda.save_after_edit = true
    require("org.agenda").open_agenda({ span = "day" })
    eq("orgagenda", vim.bo.filetype)
    local view = require("org.agenda.view")
    local target_line
    for l, it in pairs(view.state.line_items) do
      if it.title == "Scheduled today" then
        target_line = l
      end
    end
    ok(target_line)
    vim.api.nvim_win_set_cursor(0, { target_line, 0 })
    local item = view.item_at_cursor()
    local t = view.resolve_target(item)
    eq(2, t.lnum)
    -- filter by tag
    view.state.filters.tags.include.work = true
    view.redo()
    local count = vim.tbl_count(view.state.line_items)
    eq(1, count)
    view.actions.filter_remove()
    ok(vim.tbl_count(view.state.line_items) > 1)
    -- navigation
    view.actions.week_view()
    ok(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:match("^Week%-agenda"))
    view.actions.later()
    view.actions.today()
    -- bulk tag
    for l, it in pairs(view.state.line_items) do
      if it.title == "Meeting" then
        vim.api.nvim_win_set_cursor(0, { l, 0 })
      end
    end
    view.actions.mark()
    eq(1, vim.tbl_count(view.state.marks))
    view.quit(true)
  end)
  it("sparse tree finds matches", function()
    local buf = org_buffer(lines, { 1, 0 })
    local sparse = require("org.agenda.sparse")
    local m = sparse.headlines(function(hl)
      return hl:is_todo()
    end, "todo")
    ok(#m >= 8)
    local r = sparse.regexp("Deadline")
    eq(3, #r)
    eq(3, #vim.fn.getloclist(0))
    local d = sparse.deadlines()
    eq(2, #d)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
  it("notifications", function()
    local n = require("org.agenda.notifications")
    local now = today:add(1, "d"):clone({ hour = 9, min = 52 })
    local up = n.upcoming(now)
    ok(#up >= 1)
    local orig = vim.notify
    local msgs = {}
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    config.opts.notifications.system_notification = false
    eq(1, n.check(now))
    eq(0, n.check(now))
    eq(1, n.check(now:add(8, "min")))
    vim.notify = orig
    ok(msgs[1]:find("Meeting"))
  end)
end)
