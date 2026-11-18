---@mod org.agenda.habits Habit consistency graphs (org-habit)
---
--- A port of `org-habit-parse-todo` and `org-habit-build-graph`. Colours:
--- Clear (blue) before the scheduled date, Ready (green) until the end of
--- the repeat interval (or `/max` period), Alert (yellow) on its last day,
--- Overdue (red) after it. Past days that were neither done nor overdue use
--- the lighter `...Future` variant, like Emacs.

-- Not compiled by the JIT: building an agenda over many files ran 3 to 5
-- times faster interpreted. Its loops are short (an entry's dates, its
-- tags) and branch a lot, so most traces aborted ("leaving loop", closures)
-- and the many that were compiled filled the machine-code area, which
-- flushed every compiled trace in Neovim over and over ("failed to allocate
-- mcode memory", on macOS arm64). See "Performance budgets" in
-- CONTRIBUTING.md.
if jit then
  jit.off(true, true)
end

local date = require("org.date")

local M = {}

-- org-habit-duration-to-days: a month is 30.4 days, a year 365.25
local UNIT_DAYS = { h = 1, d = 1, w = 7, m = 30.4, y = 365.25 }

local function to_days(value, unit)
  return math.max(1, math.floor(value * (UNIT_DAYS[unit] or 1)))
end

function M.is_habit(hl)
  local style = hl.properties.STYLE
  return style ~= nil and style:lower() == "habit"
end

--- A state change log line (`- State "DONE" from "TODO" [date]`): the
--- keyword, then the last inactive timestamp of the line, as
--- org-habit-parse-todo's regexp takes it (`State "%s".*` then
--- org-ts-regexp-inactive).
M.STATE_LOG = '^%s*%-%s+State%s+"([^"]+)".*(%[%d%d%d%d%-%d%d%-%d%d[^%]]*%])'

-- org-habit-parse-todo's escapes of the done note heading as Lua patterns
-- (org-replace-escapes): %t / %d an inactive timestamp
-- (org-ts-regexp-inactive), %T / %D an active one (org-ts-regexp), %s / %S
-- a quoted state, %u / %U any text
local NOTE_ESCAPES = {
  t = "(%[%d%d%d%d%-%d%d%-%d%d[^%]]*%])",
  d = "(%[%d%d%d%d%-%d%d%-%d%d[^%]]*%])",
  T = "(<%d%d%d%d%-%d%d%-%d%d[^>]*>)",
  D = "(<%d%d%d%d%-%d%d%-%d%d[^>]*>)",
  s = '"%S+"',
  S = '"%S+"',
  u = ".-",
  U = ".-",
}

-- the length of the Emacs regexp each escape becomes, which a width pads
-- with spaces: org-ts-regexp-inactive, org-ts-regexp, "\"\\S-+\"" and ".*?"
local REGEXP_LENGTH = { t = 69, d = 69, T = 67, D = 67, s = 6, S = 6, u = 3, U = 3 }

-- the patterns built, by heading
local note_patterns = {}

--- The Lua pattern of a "done" note line (`- CLOSING NOTE [date]`), its
--- first capture the date, built from `log_note_headings.done` as
--- org-habit-parse-todo builds its regexp; nil when the heading has no
--- timestamp (Emacs signals an error then, |org-differences|).
---
--- An escape with a width (`%-12s`) is padded as org-replace-escapes pads
--- the regexp text it becomes: with the spaces the width leaves over its
--- length (6 for `%s`), after it for `%-12s`, before it for `%12s`. The
--- note written for "DONE" has as many; a longer state has fewer and isn't
--- read, as in Emacs. A precision (`%.3s`) is no escape there (regexp-quote
--- turned its dot into `\.`), so it is text here too.
---@return string|nil
function M.done_note_pattern()
  local heading = (require("org.config").opts.log_note_headings or {}).done
  if type(heading) ~= "string" then
    return nil
  end
  local pat = note_patterns[heading]
  if pat == nil then
    pat = false
    if heading:find("%%%-?%d*[tTdD]") then
      local out, pos = {}, 1
      for s, left, width, key, e in heading:gmatch("()%%(%-?)(%d*)([tTdDsSuU])()") do
        out[#out + 1] = vim.pesc(heading:sub(pos, s - 1))
        local pad = (" "):rep(math.max(0, (tonumber(width) or 0) - REGEXP_LENGTH[key]))
        if left == "-" then
          out[#out + 1] = NOTE_ESCAPES[key] .. pad
        else
          out[#out + 1] = pad .. NOTE_ESCAPES[key]
        end
        pos = e
      end
      out[#out + 1] = vim.pesc(heading:sub(pos))
      pat = "^%s*%-%s+" .. table.concat(out)
    end
    note_patterns[heading] = pat
  end
  return pat or nil
end

--- Collect habit data: current schedule, intervals and completion days.
---
--- The completions are the log lines org-habit-parse-todo reads: changes
--- to a done keyword and "done" notes (`log_note_headings.done`), at most
--- `preceding_days + following_days` of them, from the heading down with
--- `log_states_order_reversed`, else from the end of the entry up. The
--- entry ends at the next heading line, an inline task's included
--- (org-entry-end-position).
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
  local note = M.done_note_pattern()
  local hcfg = require("org.config").opts.agenda.habits or {}
  local maxdays = (hcfg.preceding_days or 21) + (hcfg.following_days or 7)
  local first, last, step = hl.line + 1, hl:entry_end(), 1
  if not require("org.edit").log_states_reversed(hl.file) then
    first, last, step = last, first, -1
  end
  local lines = hl.file.lines
  local count = 0
  for i = first, last, step do
    if count >= maxdays then
      break
    end
    local line = lines[i]
    local kw, ts = line:match(M.STATE_LOG)
    if not (kw and cfg:is_done(kw)) then
      ts = note and line:match(note) or nil
    end
    local d = ts and date.parse(ts)
    if d then
      done_days[d:days()] = true
      count = count + 1
    end
  end
  -- the CLOSED planning stamp is no completion: org-habit-parse-todo only
  -- reads the state-change and "done" note lines
  return {
    scheduled_days = s:days(),
    min_days = min_days,
    max_days = max_days,
    has_max = r.max ~= nil and max_days > min_days,
    type = r.type,
    done_days = done_days,
  }
end

--- The habit's deadline day (org-habit-deadline): the end of the `/max`
--- period, else the scheduled day.
function M.deadline(habit)
  if habit.has_max then
    return habit.scheduled_days + (habit.max_days - habit.min_days)
  end
  return habit.scheduled_days
end

--- Urgency of a habit for sorting (org-habit-get-urgency).
---@param habit table from M.parse
---@param today integer day number
function M.urgency(habit, today)
  local pri = 1000
  local scheduled = habit.scheduled_days
  local deadline = M.deadline(habit)
  pri = pri + (today - scheduled) * 10
  if scheduled ~= deadline and today == deadline then
    pri = pri + 50
  end
  local slip = today - (deadline - 1)
  if slip > 0 then
    pri = pri + slip * 100
  else
    pri = pri + slip * 10
  end
  return pri
end

--- Faces (group, future group) for a day (org-habit-get-faces).
local function faces(habit, m_days, scheduled_days, donep)
  local s_repeat = habit.min_days
  local d_repeat = habit.has_max and habit.max_days or s_repeat
  local scheduled = scheduled_days or habit.scheduled_days
  local deadline
  if scheduled_days then
    deadline = scheduled_days + (d_repeat - s_repeat)
  else
    deadline = M.deadline(habit)
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
  -- like org-habit-build-graph, the last column stays blank
  for day = start, stop - 1 do
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
      ch = cfg.completed_glyph or "*"
      marked = true
      while done[1] == day do
        last_done = table.remove(done, 1)
      end
    elseif day == today then
      ch = cfg.today_glyph or "!"
    end
    local group = (past or day == today) and face or future
    if past and group ~= "OrgAgendaHabitOverdue" and not marked then
      group = future
    end
    out[#out + 1] = { ch, group }
  end
  out[#out + 1] = { " ", nil }
  return out
end

return M
