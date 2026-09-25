---@mod org.agenda.habits Habit consistency graphs (org-habit)
---
--- A port of `org-habit-parse-todo` and `org-habit-build-graph`. Colours:
--- Clear (blue) before the scheduled date, Ready (green) until the end of
--- the repeat interval (or `/max` period), Alert (yellow) on its last day,
--- Overdue (red) after it. Past days that were neither done nor overdue use
--- the lighter `...Future` variant, like Emacs.

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
---@return table|nil { scheduled_days, min_days, max_days, has_max, type, done_days = set }
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
    if not (kw and cfg:is_done(kw)) then
      -- the "done" note heading (CLOSING NOTE %t)
      ts = line:match("^%s*%-%s+CLOSING NOTE%s+(%[%d%d%d%d%-%d%d%-%d%d[^%]]*%])")
    end
    local d = ts and date.parse(ts)
    if d then
      done_days[d:days()] = true
    end
  end
  if hl.planning.closed then
    done_days[hl.planning.closed:days()] = true
  end
  return {
    scheduled_days = s:days(),
    min_days = min_days,
    max_days = max_days,
    has_max = r.max ~= nil and max_days > min_days,
    type = r.type,
    done_days = done_days,
  }
end

--- Faces (group, future group) for a day (org-habit-get-faces).
local function faces(habit, m_days, scheduled_days, donep)
  local s_repeat = habit.min_days
  local d_repeat = habit.has_max and habit.max_days or s_repeat
  local scheduled = scheduled_days or habit.scheduled_days
  local deadline
  if scheduled_days then
    deadline = scheduled_days + (d_repeat - s_repeat)
  elseif habit.has_max then
    deadline = habit.scheduled_days + (habit.max_days - habit.min_days)
  else
    deadline = habit.scheduled_days + s_repeat - 1
  end
  local cfg = require("org.config").opts.agenda.habits or {}
  local name
  if m_days < scheduled then
    name = "Clear"
  elseif m_days < deadline then
    name = "Ready"
  elseif m_days == deadline then
    name = donep and "Ready" or "Alert"
  elseif cfg.show_done_always_green and donep then
    name = "Ready"
  else
    name = "Overdue"
  end
  return "OrgAgendaHabit" .. name, "OrgAgendaHabit" .. name .. "Future"
end

--- Build the graph (org-habit-build-graph). Returns a list of
--- { char, hl_group }, from `preceding_days` before today to
--- `following_days` after it.
---@param habit table from M.parse
---@param today integer day number
function M.graph(habit, today)
  local cfg = require("org.config").opts.agenda.habits or {}
  local start = today - (cfg.preceding_days or 21)
  local stop = today + (cfg.following_days or 7)
  local all = vim.tbl_keys(habit.done_days)
  table.sort(all)
  local s_repeat = habit.min_days
  local scheduled = habit.scheduled_days
  local done = {}
  local last_done
  for _, d in ipairs(all) do
    if d < start then
      last_done = d
    else
      done[#done + 1] = d
    end
  end
  local out = {}
  for day = start, stop do
    local past = day < today
    local donep = done[1] == day
    local face, future
    if past and not last_done and not (scheduled < today) then
      if all[1] == day then
        face, future = "OrgAgendaHabitReady", "OrgAgendaHabitReadyFuture"
      else
        face, future = "OrgAgendaHabitClear", "OrgAgendaHabitClearFuture"
      end
    else
      local sched
      if past and last_done then
        if #done == 0 then
          sched = scheduled
        elseif habit.type == ".+" then
          sched = last_done + s_repeat
        elseif habit.type == "+" then
          sched = scheduled - #done * s_repeat
        else
          local first = all[1]
          local shift = (scheduled - first) % s_repeat
          local s = (shift == 0 and s_repeat or shift) + first
          if first ~= last_done then
            for i = 2, #all do
              s = s + (1 + math.floor(math.max(all[i] - s, 0) / s_repeat)) * s_repeat
              if all[i] == last_done then
                break
              end
            end
          end
          sched = s
        end
      end
      face, future = faces(habit, day, sched, donep)
    end
    local ch = " "
    local marked = false
    if donep then
      ch = "*"
      marked = true
      while done[1] == day do
        last_done = table.remove(done, 1)
      end
    elseif day == today then
      ch = "!"
    end
    local group = (past or day == today) and face or future
    if past and group ~= "OrgAgendaHabitOverdue" and not marked then
      group = future
    end
    out[#out + 1] = { ch, group }
  end
  return out
end

return M
