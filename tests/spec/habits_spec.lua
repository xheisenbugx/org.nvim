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
    eq({ "!", "OrgAgendaHabitReady" }, g[22])
    eq({ " ", "OrgAgendaHabitAlertFuture" }, g[23])
    eq({ " ", "OrgAgendaHabitOverdueFuture" }, g[24])
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
