local date = require("org.date")
local files = require("org.files")
local habits = require("org.agenda.habits")

local T = date.today():days()
local function ts(offset, extra, inactive)
  local s = date.from_days(T + offset):to_string({ brackets = false })
  if extra then
    s = s .. " " .. extra
  end
  return inactive and ("[" .. s .. "]") or ("<" .. s .. ">")
end

describe("habits", function()
  it("parses done states and CLOSING NOTE entries", function()
    local buf = org_buffer({
      "* TODO Run",
      "SCHEDULED: " .. ts(0, ".+2d/4d"),
      ":PROPERTIES:",
      ":STYLE: habit",
      ":END:",
      ":LOGBOOK:",
      '- State "DONE"       from "TODO"       ' .. ts(-2, "09:00", true),
      "- CLOSING NOTE " .. ts(-5, "09:00", true) .. " \\\\",
      "  ran 5k",
      '- State "TODO"       from "DONE"       ' .. ts(-7, "09:00", true),
      ":END:",
    })
    local h = habits.parse(files.get_buffer(buf).headlines[1])
    eq(2, h.min_days)
    eq(4, h.max_days)
    ok(h.has_max)
    eq(".+", h.type)
    ok(h.done_days[T - 2])
    ok(h.done_days[T - 5])
    ok(not h.done_days[T - 7])
  end)

  it("colours the graph like org-habit", function()
    local buf = org_buffer({
      "* TODO Habit",
      "SCHEDULED: " .. ts(0, ".+2d"),
      ":PROPERTIES:",
      ":STYLE: habit",
      ":END:",
      ":LOGBOOK:",
      '- State "DONE"       from "TODO"       ' .. ts(-2, "09:00", true),
      ":END:",
    })
    local g = habits.graph(habits.parse(files.get_buffer(buf).headlines[1]), T)
    eq(29, #g)
    eq({ " ", "OrgAgendaHabitClearFuture" }, g[1])
    eq({ "*", "OrgAgendaHabitReady" }, g[20])
    eq({ " ", "OrgAgendaHabitClearFuture" }, g[21])
    -- due today (org-habit-deadline is the scheduled day without /max)
    eq({ "!", "OrgAgendaHabitAlert" }, g[22])
    eq({ " ", "OrgAgendaHabitOverdueFuture" }, g[23])
    eq({ " ", "OrgAgendaHabitOverdueFuture" }, g[24])
    -- the last day has no face, like org-habit-build-graph
    eq({ " ", nil }, g[29])
  end)

  it("marks overdue past days in red", function()
    local buf = org_buffer({
      "* TODO Habit",
      "SCHEDULED: " .. ts(-4, ".+1d"),
      ":PROPERTIES:",
      ":STYLE: habit",
      ":END:",
      ":LOGBOOK:",
      '- State "DONE"       from "TODO"       ' .. ts(-5, "09:00", true),
      ":END:",
    })
    local g = habits.graph(habits.parse(files.get_buffer(buf).headlines[1]), T)
    eq({ "*", "OrgAgendaHabitClear" }, g[17])
    eq("OrgAgendaHabitOverdue", g[20][2])
    eq({ "!", "OrgAgendaHabitOverdue" }, g[22])
  end)
end)

-- Emacs Org 9.8 parity (expectations checked against Emacs in batch mode)
describe("habits: Emacs parity", function()
  local config = require("org.config")
  local function habit_buf(sched, done_offsets)
    local lines = { "* TODO Habit", "SCHEDULED: " .. sched, ":PROPERTIES:", ":STYLE: habit", ":END:", ":LOGBOOK:" }
    for _, o in ipairs(done_offsets or {}) do
      lines[#lines + 1] = '- State "DONE"       from "TODO"       ' .. ts(o, "09:00", true)
    end
    lines[#lines + 1] = ":END:"
    return org_buffer(lines)
  end

  it("a habit without /max is due on its scheduled day (org-habit-deadline)", function()
    local buf = habit_buf(ts(-5, "++1w"), { -12, -19 })
    local g = habits.graph(habits.parse(files.get_buffer(buf).headlines[1]), T)
    eq({ "!", "OrgAgendaHabitOverdue" }, g[22])
    for i = 23, 28 do
      eq("OrgAgendaHabitOverdueFuture", g[i][2])
    end
    eq({ " ", nil }, g[29])
  end)

  it("months are 30.4 days", function()
    local buf = habit_buf(ts(0, ".+3m"))
    eq(91, habits.parse(files.get_buffer(buf).headlines[1]).min_days)
    eq(91, date.warning_days(date.parse("<2026-01-01 Thu -3m>")))
    eq(365, date.warning_days(date.parse("<2026-01-01 Thu -1y>")))
  end)

  it("today_glyph and completed_glyph", function()
    local saved = vim.deepcopy(config.opts.agenda.habits)
    config.opts.agenda.habits.today_glyph = "T"
    config.opts.agenda.habits.completed_glyph = "D"
    local buf = habit_buf(ts(0, ".+2d"), { -2 })
    local g = habits.graph(habits.parse(files.get_buffer(buf).headlines[1]), T)
    config.opts.agenda.habits = saved
    eq("D", g[20][1])
    eq("T", g[22][1])
  end)

  it("show_habits_only_for_today = false shows a habit on its future day", function()
    local items = require("org.agenda.items")
    local file = require("org.parser").parse({
      "* TODO Habit",
      "SCHEDULED: " .. ts(2, ".+2d"),
      ":PROPERTIES:",
      ":STYLE: habit",
      ":END:",
    }, "/tmp/habit_test.org")
    local by_day = items.agenda({ file }, T, T + 3, { today = T })
    eq(nil, by_day[T + 2])
    config.opts.agenda.habits.show_habits_only_for_today = false
    by_day = items.agenda({ file }, T, T + 3, { today = T })
    config.opts.agenda.habits.show_habits_only_for_today = true
    eq("Habit", by_day[T + 2][1].title)
    ok(by_day[T + 2][1].habit)
  end)
end)
