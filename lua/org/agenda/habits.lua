---@mod org.agenda.habits Habit consistency graphs (org-habit)

local date = require("org.date")

local M = {}

local UNIT_DAYS = { h = 1, d = 1, w = 7, m = 30, y = 365 }

local function to_days(value, unit)
  return math.max(1, math.floor(value * (UNIT_DAYS[unit] or 1)))
end

function M.is_habit(hl)
  local style = hl.properties.STYLE
  return style ~= nil and style:lower() == "habit"
end

--- Collect habit data: current schedule, intervals and completion days.
---@return table|nil { scheduled_days, min_days, max_days, done_days = set }
function M.parse(hl)
  local s = hl.planning.scheduled
  if not s or not s.repeater then
    return nil
  end
  local r = s.repeater
  local min_days = to_days(r.value, r.unit)
  local max_days = r.max and to_days(r.max.value, r.max.unit) or min_days
  local done_days = {}
  local cfg = hl.file.settings.todo
  for i = hl.line + 1, hl.body_end do
    local line = hl.file.lines[i]
    local kw, ts = line:match('^%s*%-%s+State%s+"([^"]+)".-(%[%d%d%d%d%-%d%d%-%d%d[^%]]*%])')
    if kw and cfg:is_done(kw) then
      local d = date.parse(ts)
      if d then
        done_days[d:days()] = true
      end
    end
  end
  if hl.planning.closed then
    done_days[hl.planning.closed:days()] = true
  end
  return {
    scheduled_days = s:days(),
    min_days = min_days,
    max_days = max_days,
    done_days = done_days,
  }
end

--- Build the graph. Returns list of { char, hl_group }.
---@param habit table from M.parse
---@param today integer day number
function M.graph(habit, today)
  local cfg = require("org.config").opts.agenda.habits or {}
  local before = cfg.preceding_days or 21
  local after = cfg.following_days or 7
  local done_sorted = vim.tbl_keys(habit.done_days)
  table.sort(done_sorted)
  local out = {}
  for d = today - before, today + after do
    -- schedule relevant for this day: based on the last completion before it
    local sched, due
    if d <= today then
      local last
      for _, dd in ipairs(done_sorted) do
        if dd < d then
          last = dd
        end
      end
      if last then
        sched, due = last + habit.min_days, last + habit.max_days
      else
        sched = habit.scheduled_days
        due = habit.scheduled_days + (habit.max_days - habit.min_days)
      end
    else
      sched = habit.scheduled_days
      due = habit.scheduled_days + (habit.max_days - habit.min_days)
    end
    local group
    if d < sched then
      group = "OrgAgendaHabitClear"
    elseif d < due then
      group = "OrgAgendaHabitReady"
    elseif d == due then
      group = due > sched and "OrgAgendaHabitAlert" or "OrgAgendaHabitReady"
    else
      group = "OrgAgendaHabitOverdue"
    end
    local ch = " "
    if habit.done_days[d] then
      ch = "*"
    elseif d == today then
      ch = "!"
    end
    out[#out + 1] = { ch, group }
  end
  return out
end

return M
