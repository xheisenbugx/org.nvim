---@mod org.agenda.items Collecting agenda entries from org files
---
--- A port of the entry finders of org-agenda.el
--- (`org-agenda-get-deadlines`, `-scheduled`, `-timestamps`, `-blocks`,
--- `-sexps`, `-progress`, `-todos`, `org-scan-tags`, the search view and
--- `org-agenda-list-stuck-projects`) and of the sorting
--- (`org-entries-lessp`). Items carry the text properties Emacs sorts on:
--- time of day, urgency, priority, category, habit, ts-date and type.

local config = require("org.config")
local date = require("org.date")
local habits = require("org.agenda.habits")

local M = {}

-- sexps already reported as bad (org agenda warns once per session)
M._warned_sexps = {}

---@class org.AgendaItem
---@field type string scheduled|deadline|timestamp|range|sexp|closed|clock|state|todo|tags|search|stuck
---@field headline org.Headline
---@field filename string|nil
---@field bufnr integer|nil
---@field lnum integer
---@field raw string
---@field title string headline text without TODO keyword, priority and tags
---@field display_title string|nil title as displayed (times/timestamps removed)
---@field todo string|nil
---@field priority string|nil
---@field category string
---@field tags string[]
---@field done boolean
---@field day integer|nil day the item is displayed on
---@field date table|nil the timestamp the item comes from
---@field time integer|nil minutes since midnight (time-of-day)
---@field end_time integer|nil
---@field extra string|nil leader ("Scheduled: ", "In   3 d.: ", ...)
---@field face string|nil highlight group for the text
---@field urgency number Emacs 'urgency
---@field prio number Emacs 'priority (org-get-priority)
---@field ts_date integer|nil day number used by the ts-*/timestamp-* sorting
---@field ts_type string|nil Emacs 'type ("scheduled", "past-scheduled", "deadline", ...)
---@field ts_index integer|nil index in `headline.timestamps` of a plain timestamp item
---@field order integer insertion order (category-keep)

local order = 0

--- Emacs `org-get-priority`: 1000 * (lowest - priority).
local function pvalue(p)
  return tonumber(p) or (p and p:byte()) or 0
end

local function priority_value(hl)
  local pr = hl.file:priorities()
  local p = hl.priority or pr.default
  return 1000 * (pvalue(pr.lowest) - pvalue(p))
end
M.priority_value = priority_value

local function new_item(hl, fields)
  order = order + 1
  local item = {
    headline = hl,
    filename = hl.file.filename,
    bufnr = hl.file.bufnr,
    lnum = hl.line,
    raw = hl.raw,
    title = hl.title,
    todo = hl.todo,
    priority = hl.priority,
    category = hl:get_category(),
    tags = hl:get_tags(),
    done = hl:is_done(),
    level = hl.level,
    order = order,
    prio = priority_value(hl),
  }
  for k, v in pairs(fields or {}) do
    item[k] = v
  end
  if item.urgency == nil then
    item.urgency = item.prio
  end
  return item
end
M.new_item = new_item

local function acfg_for(opts)
  return vim.tbl_extend("force", config.opts.agenda, (opts or {}).block or {})
end

---------------------------------------------------------------------------
-- Times of day (org-get-time-of-day, org-plain-time-of-day-regexp)
---------------------------------------------------------------------------

local function is_word(c)
  return c ~= nil and c ~= "" and c:match("[%w]") ~= nil
end

--- One time at byte `i` (a word start): "10:00", "9:30am", "8pm".
---@return integer|nil minutes, integer end (exclusive)
local function match_one(s, i)
  if is_word(s:sub(i - 1, i - 1)) then
    return nil
  end
  for _, n in ipairs({ 2, 1 }) do
    local h = s:sub(i, i + n - 1)
    if #h == n and h:match(n == 2 and "^[012]%d$" or "^%d$") then
      local j = i + n
      local hour, min, ampm = tonumber(h), 0, nil
      local mm = s:match("^:([0-5]%d)", j)
      local ok = false
      if mm then
        min = tonumber(mm)
        j = j + 3
        local ap = s:sub(j, j + 1):lower()
        if ap == "am" or ap == "pm" then
          -- `\>` after am/pm, else retry without it
          if not is_word(s:sub(j + 2, j + 2)) then
            ampm = ap
            j = j + 2
            ok = true
          end
        end
        if not ok and not is_word(s:sub(j, j)) then
          ok = true
        end
      else
        local ap = s:sub(j, j + 1):lower()
        if (ap == "am" or ap == "pm") and not is_word(s:sub(j + 2, j + 2)) then
          ampm = ap
          j = j + 2
          ok = true
        end
      end
      if ok then
        if ampm == "am" then
          hour = hour == 12 and 0 or hour
        elseif ampm == "pm" then
          hour = hour == 12 and 12 or hour + 12
        end
        return hour * 60 + min, j
      end
    end
  end
  return nil
end

--- First plain time or time range in `s` (org-plain-time-of-day-regexp).
---@return { start: integer, stop?: integer, s: integer, e: integer, text: string }|nil
function M.find_time(s)
  if not s then
    return nil
  end
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if c:match("%d") then
      local t1, j = match_one(s, i)
      if t1 then
        local res = { start = t1, s = i, e = j - 1 }
        local dash = s:match("^%-%-?", j)
        if dash then
          local t2, k = match_one(s, j + #dash)
          if t2 then
            res.stop, res.e = t2, k - 1
          end
        end
        res.text = s:sub(res.s, res.e)
        return res
      end
    end
    i = i + 1
  end
  return nil
end

--- Remove active and inactive timestamps from a string.
local function strip_timestamps(s)
  local out = s
  for _, m in ipairs(date.parse_all(s)) do
    out = out:gsub(vim.pesc(m.raw), "", 1)
  end
  return out
end
M.strip_timestamps = strip_timestamps

--- Remove `<...>` active timestamps (org-ts-regexp) from a title.
local function strip_active_timestamps(s)
  local out = s
  for _, m in ipairs(date.parse_all(s)) do
    if m.raw:sub(1, 1) == "<" then
      out = out:gsub(vim.pesc(m.raw), "", 1)
    end
  end
  return (out:gsub("<%%%%%b()[^>\n]*>", ""))
end

local function time_of(d)
  if d and d.hour then
    return d.hour * 60 + (d.min or 0)
  end
end

local function end_time_of(d)
  if d and d.end_hour then
    return d.end_hour * 60 + (d.end_min or 0)
  end
end

--- Set `time`/`end_time` of an item (org-agenda-format-item DOTIME).
--- `stamp` is the date the time comes from (or nil); `with_time` false =
--- no time at all (reminders, middle days of a block). Without a time in
--- the stamp, the headline is searched for one
--- (org-agenda-search-headline-for-time); a time found in the headline is
--- removed from the displayed title (org-agenda-remove-times-when-in-prefix).
local function set_time(item, stamp, acfg, remove_stamps)
  local title = item.title
  if remove_stamps then
    title = strip_active_timestamps(title)
  end
  local found
  if stamp and stamp.hour then
    item.time, item.end_time = time_of(stamp), end_time_of(stamp)
    -- the time as written, e.g. "10:30-11:45", for removal from the title
    local t = string.format("%02d:%02d", stamp.hour, stamp.min or 0)
    if stamp.end_hour then
      t = t .. "-" .. string.format("%02d:%02d", stamp.end_hour, stamp.end_min or 0)
    end
    -- a timestamp item's time comes from the stamp, which is removed
    -- from the text anyway (org-stamp-time-of-day-regexp)
    found = not remove_stamps and { text = t } or nil
  elseif acfg.search_headline_for_time ~= false then
    found = M.find_time(strip_timestamps(title))
    if found then
      item.time, item.end_time = found.start, found.stop
    end
  end
  local rm = acfg.remove_times_when_in_prefix
  if found and rm ~= false and item.prefix_has_time ~= false then
    local s, e = title:find(vim.pesc(found.text) .. " *")
    if s and title:sub(e + 1, e + 1) ~= "]" and (rm ~= "beg" or (s == 1 and not item.todo and not item.priority)) then
      title = title:sub(1, s - 1) .. title:sub(e + 1)
    end
  end
  if item.time and not item.end_time and acfg.default_appointment_duration then
    item.end_time = item.time + acfg.default_appointment_duration
  end
  if title ~= item.title then
    item.display_title = title
  end
end
M.set_time = set_time

---------------------------------------------------------------------------
-- Headline iteration
---------------------------------------------------------------------------

--- Is `hl` inside a COMMENT subtree, or an ARCHIVE-tagged one (unless
--- archived trees are included, org-agenda-archives-mode)?
local function hidden(hl, include_archived)
  local h = hl
  while h do
    if h.commented or (not include_archived and vim.tbl_contains(h.tags, "ARCHIVE")) then
      return true
    end
    h = h.parent
  end
  return false
end

--- Iterate visible headlines of `files` (skipping ARCHIVE/COMMENT subtrees).
---@param files org.File[]
---@param opts? { restrict?: { filename?: string, range?: integer[] }, skip?: (fun(hl): boolean), archives?: string|boolean }
function M.each_headline(files, opts, fn)
  opts = opts or {}
  local r = opts.restrict
  for fidx, file in ipairs(files) do
    for _, hl in ipairs(file.headlines) do
      local ok = not hidden(hl, opts.archives)
      if ok and r and r.range then
        ok = hl.line >= r.range[1] and hl.line <= r.range[2]
      end
      if ok and opts.skip then
        local s_ok, skip = pcall(opts.skip, hl)
        ok = not (s_ok and skip)
      end
      if ok then
        fn(hl, file, fidx)
      end
    end
  end
end

---------------------------------------------------------------------------
-- Repeats (org-closest-date)
---------------------------------------------------------------------------

local function repeating(ts)
  return ts.repeater and ts.repeater.value and ts.repeater.value > 0
end

--- The k-th occurrence day of a repeating timestamp (k = 0 is the base).
local function nth_occ(ts, k)
  local r = ts.repeater
  if r.unit == "d" then
    return ts:days() + k * r.value
  elseif r.unit == "w" then
    return ts:days() + k * r.value * 7
  elseif r.unit == "h" then
    return ts:days() + math.floor(k * r.value / 24)
  end
  return ts:add(k * r.value, r.unit):days()
end

--- Smallest occurrence day >= `day` (the base when it is later).
local function next_occ(ts, day)
  local base = ts:days()
  if not repeating(ts) or base >= day then
    return base
  end
  local r = ts.repeater
  if r.unit == "d" or r.unit == "w" then
    local step = r.value * (r.unit == "w" and 7 or 1)
    return base + math.ceil((day - base) / step) * step
  elseif r.unit == "h" then
    return day
  end
  local k = 0
  local approx = r.unit == "y" and 365 * r.value or 28 * r.value
  k = math.max(0, math.floor((day - base) / approx) - 1)
  while nth_occ(ts, k) < day do
    k = k + 1
  end
  return nth_occ(ts, k)
end

--- Largest occurrence day <= `day` (the base when it is later).
local function last_occ(ts, day)
  local base = ts:days()
  if not repeating(ts) or base >= day then
    return base
  end
  local n = next_occ(ts, day)
  if n == day then
    return day
  end
  local r = ts.repeater
  if r.unit == "d" or r.unit == "w" then
    local step = r.value * (r.unit == "w" and 7 or 1)
    return n - step
  elseif r.unit == "h" then
    return day
  end
  local k = 0
  local approx = r.unit == "y" and 365 * r.value or 28 * r.value
  k = math.max(0, math.floor((day - base) / approx) - 1)
  while nth_occ(ts, k + 1) <= day do
    k = k + 1
  end
  return nth_occ(ts, k)
end
M.next_occ, M.last_occ = next_occ, last_occ

--- A copy of `ts` moved to `day` (keeping the time).
local function at_day(ts, day)
  if ts:days() == day then
    return ts
  end
  local y, m, d = date.civil_from_days(day)
  return ts:clone({ year = y, month = m, day = d })
end

--- Is `kw` in the prefer-last-repeat setting (true or a list of keywords)?
local function prefers_last(acfg, todo)
  local p = acfg.prefer_last_repeat
  if p == true then
    return true
  elseif type(p) == "table" then
    return todo ~= nil and vim.tbl_contains(p, todo)
  elseif type(p) == "string" then
    return p == todo
  end
  return false
end

--- Days with a future repeat shown (org-agenda-show-future-repeats) in
--- [from, to]: every occurrence after today, or only the first one.
local function future_repeats(ts, acfg, today, from, to)
  local out = {}
  local fr = acfg.show_future_repeats
  if not repeating(ts) or fr == false or to <= today then
    return out
  end
  if fr == "next" then
    local d = next_occ(ts, today + 1)
    if d >= from and d <= to then
      out[1] = d
    end
    return out
  end
  local d = next_occ(ts, math.max(from, today + 1))
  local guard = 0
  while d <= to and guard < 2000 do
    out[#out + 1] = d
    local nd = next_occ(ts, d + 1)
    if nd <= d then
      break
    end
    d = nd
    guard = guard + 1
  end
  return out
end

---------------------------------------------------------------------------
-- Agenda (date based) items
---------------------------------------------------------------------------

--- Entry types of a block (org-agenda-entry-types).
local function entry_types(acfg, opts)
  local set = {}
  for _, t in ipairs(acfg.entry_types or { "deadline", "scheduled", "timestamp", "sexp" }) do
    set[(tostring(t):gsub("^:", ""))] = true
  end
  -- starred types override non-starred equivalents
  if set["deadline*"] then
    set.deadline = nil
  end
  if set["scheduled*"] then
    set.scheduled = nil
  end
  if opts.no_deadlines or acfg.include_deadlines == false then
    set.deadline, set["deadline*"] = nil, nil
  end
  return set
end

--- Integer value of an option that may be a number (else nil).
local function int(v)
  return type(v) == "number" and v or nil
end

local SOURCE_RANK = {
  deadline = 1,
  ["upcoming-deadline"] = 1,
  closed = 2,
  clock = 2,
  state = 2,
  scheduled = 3,
  ["past-scheduled"] = 3,
  block = 4,
  timestamp = 5,
  sexp = 6,
}

--- Collect agenda items for days [from, to] (day numbers).
---@param files org.File[]
---@param from integer
---@param to integer
---@param opts? { today?: integer, log_mode?: boolean|string, restrict?: table, skip?: function, block?: table,
---  inactive?: boolean, no_deadlines?: boolean, archives?: string|boolean }
---@return table<integer, org.AgendaItem[]> items by day
function M.agenda(files, from, to, opts)
  opts = opts or {}
  local cfg = config.opts
  local acfg = acfg_for(opts)
  local today = opts.today or date.today_days()
  local by_day = {}
  local types = entry_types(acfg, opts)
  -- the clock check lists clocked entries only; log "only" shows log items only
  local clockcheck = opts.log_mode == "clockcheck"
  local log_only = clockcheck or opts.log_mode == "only"
  local cur_fidx = 0
  local function add(day, item)
    if day < from or day > to or (log_only and not item.log) then
      return
    end
    item.day = day
    item.fidx = cur_fidx
    by_day[day] = by_day[day] or {}
    table.insert(by_day[day], item)
  end
  local log_items = {}
  local log_list = acfg.log_mode_items or { "closed", "clock" }
  if type(opts.log_mode) == "table" then
    log_list = opts.log_mode
  end
  for _, k in ipairs(log_list) do
    log_items[k] = true
  end
  if clockcheck then
    log_items = { clock = true }
  end
  local habit_cfg = acfg.habits or {}
  local leaders_s = acfg.scheduled_leaders or { "Scheduled: ", "Sched.%2dx: " }
  local leaders_d = acfg.deadline_leaders or { "Deadline:  ", "In %3d d.: ", "%2d d. ago: " }
  local leaders_r = acfg.timerange_leaders or { "", "(%d/%d): " }
  local inactive_leader = acfg.inactive_leader or "["
  local dl_past_days = acfg.deadline_past_days or 10000
  local sc_past_days = acfg.scheduled_past_days or 10000
  local sexp_mod

  -- sexps are parsed once; a bad one is reported once per session and
  -- skipped, like Emacs's "Bad sexp ... Skipping"
  local parsed, warned = {}, M._warned_sexps
  if package.loaded["org.agenda.holidays"] then
    package.loaded["org.agenda.holidays"].reset()
  end
  local function warn_once(s, err)
    if not warned[s] then
      warned[s] = true
      vim.schedule(function()
        vim.notify(string.format("org agenda: bad sexp %s: %s; skipping", s, tostring(err)), vim.log.levels.WARN)
      end)
    end
  end
  local function eval_sexp(s, day, text)
    sexp_mod = sexp_mod or require("org.agenda.sexp")
    local node = parsed[s]
    if node == nil then
      local n, err = sexp_mod.parse(s)
      node = n or false
      parsed[s] = node
      if not n then
        warn_once(s, err)
      end
    end
    if not node then
      return nil
    end
    local ok, res, err = pcall(sexp_mod.eval, node, day, text or "")
    if not ok or (res == nil and err) then
      warn_once(s, ok and err or res)
      return nil
    end
    return res
  end

  M.each_headline(files, opts, function(hl, _, fidx)
    cur_fidx = fidx
    local done = hl:is_done()
    -- deadline days of this entry, for the skip-*-if-deadline-is-shown options
    local dl_shown = {}

    -- deadlines ------------------------------------------------------
    local dl = hl.planning.deadline
    local dl_type = types.deadline or (types["deadline*"] and dl and dl.hour)
    if dl and dl.active ~= false and dl_type then
      local base = prefers_last(acfg, hl.todo) and last_occ(dl, today) or dl:days()
      local wdays = acfg.deadline_warning_days or cfg.deadline_warning_days
      local warn = date.warning_days(dl, wdays)
      local skip_pre = acfg.skip_deadline_prewarning_if_scheduled
      local sched = hl.planning.scheduled
      if skip_pre and sched then
        local max
        if int(skip_pre) then
          max = skip_pre
        elseif skip_pre == "pre-scheduled" then
          max = math.min(base - sched:days(), wdays or 14)
        else
          max = 0
        end
        warn = math.min(warn, max)
      end
      local days = { [base] = true }
      for _, d in ipairs(future_repeats(dl, acfg, today, from, to)) do
        days[d] = "repeat"
      end
      if today >= from and today <= to then
        days[today] = days[today] or "today"
      end
      for c, kind in pairs(days) do
        local show = true
        local diff = base - c
        if c ~= base and kind ~= "repeat" then
          -- reminder in today's agenda
          if base > c then
            show = diff <= warn
          else
            show = -diff <= dl_past_days
          end
        end
        if show and done and (acfg.skip_deadline_if_done or base ~= c) then
          show = false
        end
        if show then
          local leader
          if c == today and base < today then
            leader = string.format(leaders_d[3], -diff)
          elseif c == today and base > today then
            leader = string.format(leaders_d[2], diff)
          else
            leader = leaders_d[1]
          end
          local upcoming = c == today and base > today
          local item = new_item(hl, {
            type = "deadline",
            ts_type = upcoming and "upcoming-deadline" or "deadline",
            date = (c == base or kind == "repeat") and at_day(dl, c) or dl,
            ts_date = base,
            extra = leader,
            face = done and "OrgAgendaDone" or (upcoming and "OrgAgendaDeadlineUpcoming" or "OrgAgendaDeadline"),
            reminder = c ~= base and kind ~= "repeat" or nil,
            overdue = c == today and base < today or nil,
            upcoming = upcoming and diff or nil,
            repeat_occurrence = kind == "repeat" or nil,
          })
          item.urgency = item.prio + (c == today and (today - base) or 0)
          if c == base or kind == "repeat" then
            set_time(item, dl, acfg)
          end
          add(c, item)
          dl_shown[c] = true
        end
      end
    end

    -- scheduled ------------------------------------------------------
    local s = hl.planning.scheduled
    local s_type = types.scheduled or (types["scheduled*"] and s and s.hour)
    if s and s.active ~= false and s_type then
      local is_habit = habits.is_habit(hl)
      local habit = is_habit and habits.parse(hl) or nil
      local base = prefers_last(acfg, hl.todo) and last_occ(s, today) or s:days()
      local delay = 0
      if s.warning then
        delay = date.warning_days(s, 0)
        if s.warning.type == "--" and base > s:days() then
          -- a --Xd delay only applies to the first occurrence
          delay = 0
        elseif acfg.skip_scheduled_delay_if_deadline and hl.planning.deadline then
          -- t, an integer or post-deadline: Emacs ends up with no delay
          delay = 0
        end
      end
      local past_days = (is_habit and habit_cfg.scheduled_past_days) or sc_past_days
      local days = { [base] = true }
      for _, d in ipairs(future_repeats(s, acfg, today, from, to)) do
        days[d] = "repeat"
      end
      if today >= from and today <= to then
        days[today] = days[today] or "today"
      end
      local show_all = is_habit and habit_cfg.show_all_today
      for c, kind in pairs(days) do
        local diff = c - base
        local show = true
        if not (c == today and show_all) then
          if (delay > 0 and diff < delay) or diff > past_days or base > c then
            show = false
          elseif c ~= base and c ~= today and kind ~= "repeat" then
            show = false
          end
        end
        if show and done and (acfg.skip_scheduled_if_done or base ~= c) then
          show = false
        end
        if show and acfg.skip_scheduled_repeats_after_deadline and hl.planning.deadline then
          local dld = hl.planning.deadline:days()
          if (s:days() <= dld or base ~= c) and c > dld then
            show = false
          end
        end
        local sid = acfg.skip_scheduled_if_deadline_is_shown
        if show and sid and not is_habit and dl_shown[c] then
          if sid == "not-today" then
            show = not (base < today)
          else
            show = false
          end
        end
        if show and is_habit then
          if done or habit_cfg.show_habits == false or not habit then
            show = false
          elseif c ~= today and habit_cfg.show_habits_only_for_today ~= false then
            show = false
          end
        end
        if show then
          local past = base < today
          local leader = (c == today and past) and string.format(leaders_s[2], diff) or leaders_s[1]
          local face
          if not is_habit and past then
            face = "OrgAgendaScheduledPast"
          elseif is_habit and base > today then
            face = "OrgAgendaDone"
          elseif c == today then
            face = "OrgAgendaScheduled"
          else
            face = "OrgAgendaScheduled"
          end
          local item = new_item(hl, {
            type = "scheduled",
            ts_type = past and "past-scheduled" or "scheduled",
            date = (c == base or kind == "repeat") and at_day(s, c) or s,
            ts_date = base,
            extra = leader,
            face = done and "OrgAgendaDone" or face,
            habit = habit,
            reminder = (c ~= base and kind ~= "repeat") or nil,
            past = (c == today and past) and diff or nil,
            repeat_occurrence = kind == "repeat" or nil,
          })
          if habit then
            item.urgency = habits.urgency(habit, today)
          else
            item.urgency = 99 + diff + item.prio
          end
          if is_habit or c == base or kind == "repeat" then
            set_time(item, s, acfg)
          end
          add(c, item)
        end
      end
    end

    -- plain timestamps and date ranges --------------------------------
    if types.timestamp then
      local seen_day = {}
      for idx, t in ipairs(hl.timestamps) do
        local ts = t.date
        if done and acfg.skip_timestamp_if_done then
          break
        end
        if ts.range_end and types.timestamp then
          -- org-agenda-get-blocks
          local a, b = ts:days(), ts.range_end:days()
          local n = b - a + 1
          for d = math.max(a, from), math.min(b, to) do
            local item = new_item(hl, {
              type = "range",
              ts_type = "block",
              date = ts,
              ts_index = idx,
              extra = string.format(a == b and leaders_r[1] or leaders_r[2], d - a + 1, n),
              face = done and "OrgAgendaDone" or "OrgAgendaTimestamp",
            })
            if d == a and d == b then
              set_time(item, ts.hour and ts:clone({ end_hour = ts.range_end.hour, end_min = ts.range_end.min })
                or ts, acfg)
            elseif d == a then
              set_time(item, ts, acfg)
            elseif d == b then
              set_time(item, ts.range_end, acfg)
            end
            add(d, item)
          end
        elseif not ts.range_end and types.timestamp then
          -- org-agenda-get-timestamps
          local show_days = {}
          if repeating(ts) then
            local last = prefers_last(acfg, hl.todo)
            local seen = {}
            for d = from, math.min(to, today) do
              local past = last_occ(ts, last and today or d)
              if past == d then
                show_days[#show_days + 1] = d
                seen[d] = true
              end
            end
            -- after today: the last repeat before today (the base when it is
            -- in the future) and the future repeats
            local p = last_occ(ts, today)
            if p > today and p >= from and p <= to then
              show_days[#show_days + 1] = p
              seen[p] = true
            end
            for _, d in ipairs(future_repeats(ts, acfg, today, from, to)) do
              if not seen[d] then
                show_days[#show_days + 1] = d
              end
            end
          elseif ts:days() >= from and ts:days() <= to then
            show_days[1] = ts:days()
          end
          for _, d in ipairs(show_days) do
            local skip = (acfg.skip_timestamp_if_deadline_is_shown and dl_shown[d])
              or (acfg.skip_additional_timestamps_same_entry and seen_day[d])
            if not skip then
              seen_day[d] = true
              local item = new_item(hl, {
                type = "timestamp",
                ts_type = "timestamp",
                date = at_day(ts, d),
                ts_date = ts:days(),
                ts_index = idx,
                extra = "",
                face = done and "OrgAgendaDone" or "OrgAgendaTimestamp",
              })
              if habits.is_habit(hl) then
                local h = habits.parse(hl)
                if h then
                  item.urgency = habits.urgency(h, today)
                end
              end
              set_time(item, ts, acfg, true)
              add(d, item)
            end
          end
        end
      end
      -- <%%(sexp)> timestamps
      if types.timestamp then
        local lines = hl.file.lines
        for i = hl.line, hl.body_end do
          local line = lines[i] or ""
          if line:find("<%%(", 1, true) and i ~= hl.planning_line then
            sexp_mod = sexp_mod or require("org.agenda.sexp")
            for _, m in ipairs(sexp_mod.find_all(line)) do
              for d = from, to do
                if eval_sexp(m.sexp, d, "") then
                  local item = new_item(hl, {
                    type = "timestamp",
                    ts_type = "timestamp",
                    extra = "",
                    sexp = m.sexp,
                    face = done and "OrgAgendaDone" or "OrgAgendaTimestamp",
                  })
                  set_time(item, nil, acfg, true)
                  add(d, item)
                end
              end
            end
          end
        end
      end
    end

    -- %%(sexp) entries (org-agenda-get-sexps) ---------------------------
    if types.sexp then
      local lines = hl.file.lines
      for i = hl.line + 1, hl.body_end do
        local line = lines[i] or ""
        if line:match("^&?%%%%%(") then
          sexp_mod = sexp_mod or require("org.agenda.sexp")
          local e = sexp_mod.line_entry(line)
          if e then
            for d = from, to do
              local res = eval_sexp(e.sexp, d, e.text)
              -- a string result is split on "; " into several entries
              local texts = type(res) == "string" and vim.split(res, "; ", { plain = true }) or (res and { e.text })
              for _, text in ipairs(texts or {}) do
                if not text:match("%S") then
                  text = "SEXP entry returned empty string"
                end
                local item = new_item(hl, {
                  type = "sexp",
                  ts_type = "sexp",
                  title = text,
                  extra = "",
                  sexp = e.sexp,
                  lnum_sexp = i,
                  face = "OrgAgendaTimestamp",
                })
                item.todo, item.priority, item.done = nil, nil, false
                set_time(item, nil, acfg)
                add(d, item)
              end
            end
          end
        end
      end
    end
    -- sexp planning dates: SCHEDULED/DEADLINE: <%%(...)>
    for _, kind in ipairs({ "scheduled", "deadline" }) do
      local raw = hl.file.lines[hl.planning_line or (hl.line + 1)]
      local sx = raw and raw:match("^%s*%u+:") and raw:match(kind:upper() .. ":%s*<%%%%(%b())")
      if sx and types[kind] then
        for d = from, to do
          if eval_sexp(sx, d, "") and not (done and (kind == "deadline" and acfg.skip_deadline_if_done or kind ==
            "scheduled" and acfg.skip_scheduled_if_done)) then
            local item = new_item(hl, {
              type = kind,
              ts_type = kind,
              extra = kind == "deadline" and leaders_d[1] or leaders_s[1],
              sexp = sx,
              face = kind == "deadline" and "OrgAgendaDeadline" or "OrgAgendaScheduled",
            })
            item.urgency = kind == "scheduled" and (99 + item.prio) or item.prio
            set_time(item, nil, acfg)
            add(d, item)
          end
        end
      end
    end

    -- inactive timestamps (org-agenda-include-inactive-timestamps) --
    if opts.inactive and types.timestamp then
      local lines = hl.file.lines
      local pr = hl.properties_range
      for i = hl.line, hl.body_end do
        local line = lines[i] or ""
        local skip = i == hl.planning_line or (pr and i >= pr[1] and i <= pr[2]) or line:match("^%s*CLOCK:")
        if not skip then
          for _, m in ipairs(date.parse_all(line)) do
            local ts = m.date
            local last = ts.range_end and ts.range_end:days() or ts:days()
            if not ts.active and last >= from and ts:days() <= to then
              if not (done and acfg.skip_timestamp_if_done) then
                if ts.range_end then
                  local a, b = ts:days(), ts.range_end:days()
                  for d = math.max(a, from), math.min(b, to) do
                    local item = new_item(hl, {
                      type = "range",
                      ts_type = "block",
                      date = ts,
                      extra = inactive_leader
                        .. string.format(a == b and leaders_r[1] or leaders_r[2], d - a + 1, b - a + 1),
                      face = done and "OrgAgendaDone" or "OrgAgendaTimestamp",
                      inactive = true,
                    })
                    set_time(item, d == a and ts or (d == b and ts.range_end) or nil, acfg)
                    add(d, item)
                  end
                else
                  local item = new_item(hl, {
                    type = "timestamp",
                    ts_type = "timestamp",
                    date = ts,
                    ts_date = ts:days(),
                    extra = inactive_leader,
                    face = done and "OrgAgendaDone" or "OrgAgendaTimestamp",
                    inactive = true,
                  })
                  set_time(item, ts, acfg, true)
                  add(ts:days(), item)
                end
              end
            end
          end
        end
      end
    end

    -- log mode (org-agenda-get-progress) ------------------------------
    if opts.log_mode then
      local all = opts.log_mode == "all"
      local no_hl_time = vim.tbl_extend("force", acfg, { search_headline_for_time = false })
      local closed = hl.planning.closed
      if (log_items.closed or all) and closed then
        local item = new_item(hl, {
          type = "closed",
          ts_type = "closed",
          date = closed,
          extra = "Closed:    ",
          face = "OrgAgendaDone",
          log = true,
          urgency = 100000,
          prio = 100000,
        })
        set_time(item, closed, no_hl_time)
        add(closed:days(), item)
      end
      if log_items.clock or all then
        for _, c in ipairs(hl.clocks) do
          local title = hl.title
          -- a clock-out note right below the CLOCK line (org-agenda-log-mode-add-notes)
          local note = acfg.log_mode_add_notes ~= false
            and (hl.file.lines[c.line + 1] or ""):match("^%s*%-%s+([^%-%s].-)%s*$")
          if note then
            title = title .. " - " .. note
          end
          local stamp = c.start
          if c["end"] and c["end"].hour then
            stamp = c.start:clone({ end_hour = c["end"].hour, end_min = c["end"].min })
          end
          local item = new_item(hl, {
            type = "clock",
            ts_type = "clock",
            date = c.start,
            extra = string.format("Clocked:   (%s)", c.minutes and date.format_duration(c.minutes) or "-"),
            face = "OrgAgendaLog",
            log = true,
            clock_line = c.line,
            clock = { start = c.start:minutes(), stop = c["end"] and c["end"]:minutes() or nil },
            title = title,
            urgency = 100000,
            prio = 100000,
          })
          set_time(item, stamp, no_hl_time)
          item.display_title = nil
          add(c.start:days(), item)
        end
      end
      if log_items.state or all then
        for i = hl.line + 1, hl.body_end do
          local line = hl.file.lines[i]
          local kw, ts = line:match('^%s*%-%s+State%s+"([^"]+)".-(%[%d%d%d%d%-%d%d%-%d%d[^%]]*%])')
          local d = kw and date.parse(ts)
          if d then
            local item = new_item(hl, {
              type = "state",
              ts_type = "state",
              date = d,
              extra = string.format("State:     (%s)", kw),
              face = "OrgAgendaLog",
              log = true,
              urgency = 100000,
              prio = 100000,
            })
            set_time(item, d, no_hl_time)
            add(d:days(), item)
          end
        end
      end
    end
  end)
  -- Emacs collects per file: deadlines, log items, scheduled, date
  -- ranges, timestamps, then sexps (org-agenda-get-day-entries)
  for _, list in pairs(by_day) do
    local sorted = {}
    for i, it in ipairs(list) do
      sorted[i] = it
      it.src_rank = SOURCE_RANK[it.ts_type] or SOURCE_RANK[it.type] or 9
    end
    table.sort(sorted, function(a, b)
      if a.fidx ~= b.fidx then
        return a.fidx < b.fidx
      elseif a.src_rank ~= b.src_rank then
        return a.src_rank < b.src_rank
      end
      return a.order < b.order
    end)
    for i, it in ipairs(sorted) do
      list[i] = it
    end
  end
  return by_day
end

---------------------------------------------------------------------------
-- Lists
---------------------------------------------------------------------------

--- org-agenda-todo-custom-ignore-p: is the timestamp at least `n` days
--- away (n >= 0), or at most `n` days (n < 0)?
local function custom_ignore(days, n)
  if n >= 0 then
    return days >= n
  end
  return days <= n
end

--- org-agenda-check-for-timestamp-as-reason-to-ignore-todo-item
local function ignored_by_date(hl, acfg, today)
  local s, dl = hl.planning.scheduled, hl.planning.deadline
  local iw = acfg.todo_ignore_with_date
  if iw then
    if (s and s.active) or (dl and dl.active) or #hl.timestamps > 0 then
      return true
    end
  end
  local is = acfg.todo_ignore_scheduled
  if is and s then
    local diff = s:days() - today
    if is == "future" then
      if diff > 0 then
        return true
      end
    elseif is == "past" then
      if diff <= 0 then
        return true
      end
    elseif int(is) then
      if custom_ignore(diff, is) then
        return true
      end
    else
      return true
    end
  end
  local id = acfg.todo_ignore_deadlines
  if id and dl then
    local diff = dl:days() - today
    local wdays = acfg.deadline_warning_days or config.opts.deadline_warning_days
    local close = diff <= date.warning_days(dl, wdays) and not hl:is_done()
    if id == "all" then
      return true
    elseif id == "far" then
      if not close then
        return true
      end
    elseif id == "future" then
      if diff > 0 then
        return true
      end
    elseif id == "past" then
      if diff <= 0 then
        return true
      end
    elseif int(id) then
      if custom_ignore(diff, id) then
        return true
      end
    elseif close then
      -- t and "near"
      return true
    end
  end
  local it = acfg.todo_ignore_timestamp
  if it and hl.timestamps[1] then
    local diff = hl.timestamps[1].date:days() - today
    if it == "future" then
      return diff > 0
    elseif it == "past" then
      return diff <= 0
    elseif int(it) then
      return custom_ignore(diff, it)
    end
    return true
  end
  return false
end
M.ignored_by_date = ignored_by_date

--- Global TODO list (org-todo-list).
---@param keywords? string[] restrict to these keywords (nil = all not-done; "*" = any keyword)
function M.todo(files, keywords, opts)
  opts = opts or {}
  local acfg = acfg_for(opts)
  local today = date.today_days()
  local set, any
  if keywords and #keywords > 0 then
    set = {}
    for _, k in ipairs(keywords) do
      if k == "*" then
        any = true
      end
      set[k] = true
    end
  end
  local out = {}
  local skip_below
  M.each_headline(files, opts, function(hl)
    if skip_below and hl.file == skip_below.file and hl.line <= skip_below.end_line then
      return
    end
    skip_below = nil
    if not hl.todo then
      return
    end
    if set and not any then
      if not set[hl.todo] then
        return
      end
    elseif not set and not hl:is_todo() then
      return
    end
    if ignored_by_date(hl, acfg, today) then
      return
    end
    local item = new_item(hl, { type = "todo", ts_type = "todo", face = hl:is_done() and "OrgAgendaDone" or nil })
    item.urgency = item.prio + 1
    out[#out + 1] = item
    if acfg.todo_list_sublevels == false then
      skip_below = hl
    end
  end)
  return out
end

--- Tags / property match (org-tags-view, org-scan-tags).
function M.tags(files, predicate, todo_only, opts)
  opts = opts or {}
  local acfg = acfg_for(opts)
  local today = date.today_days()
  local out = {}
  local skip_below
  M.each_headline(files, opts, function(hl)
    if skip_below and hl.file == skip_below.file and hl.line <= skip_below.end_line then
      return
    end
    skip_below = nil
    if todo_only and not hl:is_todo() then
      return
    end
    if todo_only and acfg.tags_todo_honor_ignore_options and ignored_by_date(hl, acfg, today) then
      return
    end
    if predicate(hl) then
      out[#out + 1] =
        new_item(hl, { type = "tags", ts_type = "tagsmatch", face = hl:is_done() and "OrgAgendaDone" or nil })
      if acfg.tags_match_list_sublevels == false then
        skip_below = hl
      end
    end
  end)
  return out
end

--- Text search (org-search-view).
function M.search(files, predicate, opts)
  local out = {}
  M.each_headline(files, opts, function(hl)
    if predicate(hl) then
      out[#out + 1] = new_item(hl, {
        type = "search",
        ts_type = "search",
        face = hl:is_done() and "OrgAgendaDone" or nil,
        urgency = 1000,
        prio = 1000,
      })
    end
  end)
  return out
end

--- Stuck projects (org-agenda-list-stuck-projects). A project matching
--- `match` is not stuck when a heading of its subtree (the project heading
--- included) has one of `todo_keywords` ("*" = any not-done keyword) or
--- one of `tags` ("*" = any tag), or when its subtree text matches `text`.
function M.stuck(files, opts)
  opts = opts or {}
  local sp = vim.tbl_extend("force", config.opts.agenda.stuck_projects or {}, (opts.block or {}).stuck_projects or {})
  local pred = require("org.agenda.search").compile(sp.match or "+LEVEL=2/-DONE")
  local kws, tags = {}, {}
  local any_kw, any_tag = false, false
  for _, k in ipairs(sp.todo_keywords or {}) do
    if k == "*" then
      any_kw = true
    end
    kws[k] = true
  end
  for _, t in ipairs(sp.tags or {}) do
    if t == "*" then
      any_tag = true
    end
    tags[t] = true
  end
  local text_re = sp.text and sp.text ~= "" and vim.regex(sp.text) or nil
  if not next(kws) and not next(tags) and not text_re then
    error("Missing information to identify unstuck projects")
  end
  local function unstuck(h)
    if h.todo and (kws[h.todo] or (any_kw and h:is_todo())) then
      return true
    end
    for _, t in ipairs(h.tags) do
      if tags[t] or any_tag then
        return true
      end
    end
    return false
  end
  local function subtree_active(h)
    if unstuck(h) then
      return true
    end
    for _, c in ipairs(h.children) do
      if subtree_active(c) then
        return true
      end
    end
    return false
  end
  local out = {}
  M.each_headline(files, opts, function(hl)
    if not pred(hl) then
      return
    end
    local active = subtree_active(hl)
    if not active and text_re then
      for i = hl.line, hl.end_line do
        if text_re:match_str(hl.file.lines[i]) then
          active = true
          break
        end
      end
    end
    if not active then
      out[#out + 1] = new_item(hl, { type = "stuck", ts_type = "tagsmatch" })
    end
  end)
  return out
end

---------------------------------------------------------------------------
-- Sorting (org-entries-lessp)
---------------------------------------------------------------------------

local function todo_rank(item)
  -- org-cmp-todo-state: done states first, then by position in the sequence
  local cfg = item.headline and item.headline.file.settings.todo
  local kw = item.todo
  if not cfg or not kw then
    return 0, false
  end
  local names = cfg:names()
  local idx
  for i, n in ipairs(names) do
    if n == kw then
      idx = i
    end
  end
  -- (length (member ta kwds)) = #names - idx + 1; Emacs compares its negation
  return idx and -(#names - idx + 1) or 0, cfg:is_done(kw)
end

--- Effort of an item in minutes, or nil.
function M.effort(item)
  if item.effort_minutes ~= nil then
    return item.effort_minutes or nil
  end
  if not item.headline then
    return nil
  end
  local v = item.headline:get_property(config.opts.effort_property or "Effort")
  local m = v and date.parse_duration(v) or nil
  item.effort_minutes = m or false
  return m
end

--- Statistics cookie of the headline as a percentage (stats-up/-down).
local function stats(item)
  local t = item.title or ""
  local a, b = t:match("%[(%d+)/(%d+)%]")
  if a then
    b = tonumber(b)
    return b > 0 and math.floor(100 * tonumber(a) / b) or 0
  end
  local p = t:match("%[(%d+)%%%]")
  return p and tonumber(p) or 0
end

local function cmp_num(a, b)
  if a > b then
    return 1
  elseif a < b then
    return -1
  end
end

local function lower_title(item)
  -- Emacs strips the TODO keyword but not a "[#A]" cookie (org-cmp-alpha)
  local t = item.display_title or item.title or ""
  if item.priority then
    t = "[#" .. item.priority .. "] " .. t
  end
  return t:lower()
end

local function first_tag(item)
  -- Emacs compares the last tag of the list
  local tags = item.tags or {}
  return tags[#tags]
end

local function ts_value(item, typ)
  local late = config.opts.agenda.sort_notime_is_late ~= false
  local def = late and math.huge or -1
  if not item.ts_date or not item.ts_type then
    return def
  end
  if typ ~= "" and not item.ts_type:find(typ, 1, true) then
    return def
  end
  return item.ts_date
end

local function time_value(item)
  if item.time then
    return item.time
  end
  return config.opts.agenda.sort_notime_is_late ~= false and 99 * 60 + 1 or -1
end

local function effort_value(item)
  local e = M.effort(item)
  if e then
    return e
  end
  return config.opts.agenda.sort_noeffort_is_high ~= false and math.huge or -1
end

local function cat(item)
  return item.category or ""
end

local function string_cmp(a, b)
  if a < b then
    return -1
  elseif b < a then
    return 1
  end
end

local function todo_cmp(a, b)
  local la, da = todo_rank(a)
  local lb, db = todo_rank(b)
  if da and not db then
    return -1
  elseif db and not da then
    return 1
  end
  return cmp_num(la, lb)
end

local function alpha_cmp(a, b)
  local ta, tb = lower_title(a), lower_title(b)
  if not ta and not tb then
    return nil
  elseif not ta then
    return 1
  elseif not tb then
    return -1
  end
  return string_cmp(ta, tb)
end

local function tag_cmp(a, b)
  local ta, tb = first_tag(a), first_tag(b)
  if not ta and not tb then
    return nil
  elseif not ta then
    return 1
  elseif not tb then
    return -1
  end
  return string_cmp(ta:lower(), tb:lower())
end

local function habit_cmp(a, b)
  if a.habit and not b.habit then
    return -1
  elseif b.habit and not a.habit then
    return 1
  end
end

local function user_cmp(a, b)
  local f = config.opts.agenda.cmp_user_defined
  if type(f) ~= "function" then
    error("Please set `agenda.cmp_user_defined' to a function or remove `user-defined-up/down' from the sorting")
  end
  local r = f(a, b)
  if r == true then
    return -1
  elseif r == false then
    return nil
  end
  return r
end

--- Comparators returning -1 (a first), 1 (b first) or nil (undecided).
local strategies = {
  ["timestamp-up"] = function(a, b)
    return cmp_num(ts_value(a, ""), ts_value(b, ""))
  end,
  ["timestamp-down"] = function(a, b)
    return cmp_num(ts_value(b, ""), ts_value(a, ""))
  end,
  ["scheduled-up"] = function(a, b)
    return cmp_num(ts_value(a, "scheduled"), ts_value(b, "scheduled"))
  end,
  ["scheduled-down"] = function(a, b)
    return cmp_num(ts_value(b, "scheduled"), ts_value(a, "scheduled"))
  end,
  ["deadline-up"] = function(a, b)
    return cmp_num(ts_value(a, "deadline"), ts_value(b, "deadline"))
  end,
  ["deadline-down"] = function(a, b)
    return cmp_num(ts_value(b, "deadline"), ts_value(a, "deadline"))
  end,
  ["tsia-up"] = function(a, b)
    return cmp_num(ts_value(a, "timestamp_ia"), ts_value(b, "timestamp_ia"))
  end,
  ["tsia-down"] = function(a, b)
    return cmp_num(ts_value(b, "timestamp_ia"), ts_value(a, "timestamp_ia"))
  end,
  ["ts-up"] = function(a, b)
    return cmp_num(ts_value(a, "timestamp"), ts_value(b, "timestamp"))
  end,
  ["ts-down"] = function(a, b)
    return cmp_num(ts_value(b, "timestamp"), ts_value(a, "timestamp"))
  end,
  ["time-up"] = function(a, b)
    return cmp_num(time_value(a), time_value(b))
  end,
  ["time-down"] = function(a, b)
    return cmp_num(time_value(b), time_value(a))
  end,
  ["stats-up"] = function(a, b)
    return cmp_num(stats(a), stats(b))
  end,
  ["stats-down"] = function(a, b)
    return cmp_num(stats(b), stats(a))
  end,
  ["priority-up"] = function(a, b)
    return cmp_num(a.prio or 0, b.prio or 0)
  end,
  ["priority-down"] = function(a, b)
    return cmp_num(b.prio or 0, a.prio or 0)
  end,
  ["urgency-up"] = function(a, b)
    return cmp_num(a.urgency or 0, b.urgency or 0)
  end,
  ["urgency-down"] = function(a, b)
    return cmp_num(b.urgency or 0, a.urgency or 0)
  end,
  ["effort-up"] = function(a, b)
    return cmp_num(effort_value(a), effort_value(b))
  end,
  ["effort-down"] = function(a, b)
    return cmp_num(effort_value(b), effort_value(a))
  end,
  ["category-up"] = function(a, b)
    return string_cmp(cat(a), cat(b))
  end,
  ["category-down"] = function(a, b)
    return string_cmp(cat(b), cat(a))
  end,
  ["category-keep"] = function(a, b)
    return string_cmp(cat(a), cat(b)) and 1 or nil
  end,
  ["tag-up"] = tag_cmp,
  ["tag-down"] = function(a, b)
    return tag_cmp(b, a)
  end,
  ["todo-state-up"] = todo_cmp,
  ["todo-state-down"] = function(a, b)
    return todo_cmp(b, a)
  end,
  ["habit-up"] = habit_cmp,
  ["habit-down"] = function(a, b)
    return habit_cmp(b, a)
  end,
  ["alpha-up"] = alpha_cmp,
  ["alpha-down"] = function(a, b)
    return alpha_cmp(b, a)
  end,
  ["user-defined-up"] = user_cmp,
  ["user-defined-down"] = function(a, b)
    return user_cmp(b, a)
  end,
}
M.strategies = strategies

local function has_any(strategy, a, b)
  return vim.tbl_contains(strategy, a) or vim.tbl_contains(strategy, b)
end

--- The timestamp of a list entry (TODO, tags) used by the ts-* sorting
--- strategies (org-agenda-entry-get-agenda-timestamp).
function M.set_list_timestamp(item, strategy)
  local hl = item.headline
  if not hl then
    return
  end
  local function first(active)
    for _, t in ipairs(hl.timestamps) do
      if (t.date.active ~= false) == active then
        return t.date
      end
    end
    if not active then
      for i = hl.line, hl.body_end do
        for _, m in ipairs(date.parse_all(hl.file.lines[i] or "")) do
          if not m.date.active and i ~= hl.planning_line and not (hl.file.lines[i] or ""):match("^%s*CLOCK:") then
            return m.date
          end
        end
      end
    end
  end
  local ts, typ
  if has_any(strategy, "scheduled-up", "scheduled-down") then
    ts, typ = hl.planning.scheduled, " scheduled"
  elseif has_any(strategy, "deadline-up", "deadline-down") then
    ts, typ = hl.planning.deadline, " deadline"
  elseif has_any(strategy, "ts-up", "ts-down") then
    ts, typ = first(true), " timestamp"
  elseif has_any(strategy, "tsia-up", "tsia-down") then
    ts, typ = first(false), " timestamp_ia"
  elseif has_any(strategy, "timestamp-up", "timestamp-down") then
    ts = hl.planning.scheduled or hl.planning.deadline or first(true) or first(false)
    typ = ""
  else
    typ = ""
  end
  item.ts_date = ts and ts:days() or nil
  item.ts_type = (item.ts_type or item.type) .. typ
end

--- Check a strategy list, erroring on unknown names like Emacs.
function M.check_strategy(strategy)
  for _, s in ipairs(strategy or {}) do
    if not strategies[s] then
      error(string.format("Invalid value %s in `agenda.sorting'", vim.inspect(s)), 0)
    end
  end
end

--- org-entries-lessp
local function lessp(a, b, strategy)
  for _, s in ipairs(strategy) do
    local r = strategies[s](a, b)
    if r == -1 then
      return true
    elseif r == 1 then
      return false
    end
  end
  return false
end
M.lessp = lessp

--- Stable merge sort (like Emacs `sort` on lists).
local function merge_sort(list, less)
  local n = #list
  if n < 2 then
    return list
  end
  local tmp = {}
  local width = 1
  while width < n do
    local i = 1
    while i <= n do
      local mid = math.min(i + width, n + 1)
      local hi = math.min(i + 2 * width, n + 1)
      local l, r, k = i, mid, i
      while l < mid and r < hi do
        if less(list[r], list[l]) then
          tmp[k] = list[r]
          r = r + 1
        else
          tmp[k] = list[l]
          l = l + 1
        end
        k = k + 1
      end
      while l < mid do
        tmp[k] = list[l]
        l, k = l + 1, k + 1
      end
      while r < hi do
        tmp[k] = list[r]
        r, k = r + 1, k + 1
      end
      i = i + 2 * width
    end
    for j = 1, n do
      list[j] = tmp[j]
    end
    width = width * 2
  end
  return list
end

--- Sort items in place according to a strategy list (org-entries-lessp).
--- Unknown strategies raise an error.
---@param items org.AgendaItem[]
---@param strategy string[]
function M.sort(items, strategy)
  strategy = strategy or {}
  M.check_strategy(strategy)
  return merge_sort(items, function(a, b)
    return lessp(a, b, strategy)
  end)
end

return M
