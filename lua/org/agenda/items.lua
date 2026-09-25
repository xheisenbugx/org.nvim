---@mod org.agenda.items Collecting agenda entries from org files

local config = require("org.config")
local date = require("org.date")
local habits = require("org.agenda.habits")

local M = {}

---@class org.AgendaItem
---@field type string scheduled|deadline|timestamp|range|closed|clock|state|todo|tags|search|stuck
---@field headline org.Headline
---@field filename string|nil
---@field bufnr integer|nil
---@field lnum integer
---@field raw string
---@field title string
---@field todo string|nil
---@field priority string|nil
---@field category string
---@field tags string[]
---@field done boolean
---@field day integer|nil day the item is displayed on
---@field date table|nil the timestamp the item comes from
---@field time integer|nil minutes since midnight
---@field end_time integer|nil
---@field extra string|nil "Scheduled: " etc.
---@field face string|nil highlight group for the text
---@field order integer insertion order (category-keep)

local order = 0

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
  }
  for k, v in pairs(fields or {}) do
    item[k] = v
  end
  return item
end
M.new_item = new_item

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
---@param opts? { restrict?: { filename?: string, range?: integer[] }, skip?: fun(hl): boolean, archives?: string|boolean }
function M.each_headline(files, opts, fn)
  opts = opts or {}
  local r = opts.restrict
  for _, file in ipairs(files) do
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
        fn(hl, file)
      end
    end
  end
end

---------------------------------------------------------------------------
-- Agenda (date based) items
---------------------------------------------------------------------------

--- Collect agenda items for days [from, to] (day numbers).
---@param files org.File[]
---@param from integer
---@param to integer
---@param opts? { today?: integer, log_mode?: boolean, restrict?: table, skip?: function, block?: table }
---@return table<integer, org.AgendaItem[]> items by day
function M.agenda(files, from, to, opts)
  opts = opts or {}
  local cfg = config.opts
  local acfg = vim.tbl_extend("force", cfg.agenda, opts.block or {})
  local today = opts.today or date.today_days()
  local by_day = {}
  local function add(day, item)
    if day < from or day > to then
      return
    end
    item.day = day
    by_day[day] = by_day[day] or {}
    table.insert(by_day[day], item)
  end
  local future_repeats = acfg.show_future_repeats
  local log_items = {}
  for _, k in ipairs(acfg.log_mode_items or { "closed", "clock" }) do
    log_items[k] = true
  end
  local habit_cfg = acfg.habits or {}

  M.each_headline(files, opts, function(hl)
    local done = hl:is_done()

    -- deadlines ------------------------------------------------------
    local dl = hl.planning.deadline
    if dl and not (done and acfg.skip_deadline_if_done) then
      local d0 = dl:days()
      local warn = date.warning_days(dl, cfg.deadline_warning_days)
      add(d0, new_item(hl, {
        type = "deadline",
        date = dl,
        time = time_of(dl),
        end_time = end_time_of(dl),
        extra = "Deadline:  ",
        face = done and "OrgAgendaDone" or "OrgAgendaDeadline",
      }))
      if dl.repeater and future_repeats and not done then
        local occ = date.occurrences(dl, math.max(from, today + 1), to)
        for i, o in ipairs(occ) do
          if o:days() ~= d0 and (future_repeats ~= "next" or i == 1) then
            add(o:days(), new_item(hl, {
              type = "deadline",
              date = o,
              time = time_of(o),
              end_time = end_time_of(o),
              extra = "Deadline:  ",
              face = "OrgAgendaDeadline",
              repeat_occurrence = true,
            }))
          end
        end
      end
      if not done and today ~= d0 then
        local diff = d0 - today
        if diff < 0 then
          add(today, new_item(hl, {
            type = "deadline",
            date = dl,
            extra = string.format("%2d d. ago: ", -diff),
            face = "OrgAgendaDeadline",
            reminder = true,
            overdue = true,
          }))
        elseif diff <= warn then
          local sched = hl.planning.scheduled
          local skip = acfg.skip_deadline_prewarning_if_scheduled and sched and sched:days() > today
          if not skip then
            add(today, new_item(hl, {
              type = "deadline",
              date = dl,
              extra = string.format("In %3d d.: ", diff),
              face = "OrgAgendaDeadlineUpcoming",
              reminder = true,
              upcoming = diff,
            }))
          end
        end
      end
    end

    -- scheduled ------------------------------------------------------
    local s = hl.planning.scheduled
    if s and not (done and acfg.skip_scheduled_if_done) then
      local s0 = s:days()
      local habit = habit_cfg.show_habits ~= false and habits.is_habit(hl) and habits.parse(hl) or nil
      if habits.is_habit(hl) and habit_cfg.show_habits == false then
        -- habits hidden
      elseif habit then
        if not done and (s0 <= today or habit_cfg.show_all_today) then
          add(today, new_item(hl, {
            type = "scheduled",
            date = s,
            time = s0 == today and time_of(s) or nil,
            extra = s0 < today and string.format("Sched.%2dx: ", today - s0) or "Scheduled: ",
            face = s0 < today and "OrgAgendaScheduledPast" or "OrgAgendaScheduled",
            habit = habit,
            reminder = s0 ~= today,
          }))
        end
      else
        local delay = 0
        if s.warning then
          delay = date.warning_days(s, 0)
          if acfg.skip_scheduled_delay_if_deadline and hl.planning.deadline then
            delay = 0
          end
        end
        if delay == 0 then
          add(s0, new_item(hl, {
            type = "scheduled",
            date = s,
            time = time_of(s),
            end_time = end_time_of(s),
            extra = "Scheduled: ",
            face = done and "OrgAgendaDone" or "OrgAgendaScheduled",
          }))
        end
        if s.repeater and future_repeats and not done then
          local occ = date.occurrences(s, math.max(from, today + 1), to)
          for i, o in ipairs(occ) do
            if o:days() ~= s0 and (future_repeats ~= "next" or i == 1) then
              add(o:days(), new_item(hl, {
                type = "scheduled",
                date = o,
                time = time_of(o),
                end_time = end_time_of(o),
                extra = "Scheduled: ",
                face = "OrgAgendaScheduled",
                repeat_occurrence = true,
              }))
            end
          end
        end
        if not done and today > s0 and today >= s0 + delay then
          add(today, new_item(hl, {
            type = "scheduled",
            date = s,
            extra = string.format("Sched.%2dx: ", today - s0),
            face = "OrgAgendaScheduledPast",
            reminder = true,
            past = today - s0,
          }))
        end
      end
    end

    -- plain timestamps -----------------------------------------------
    for _, t in ipairs(hl.timestamps) do
      local ts = t.date
      if ts.range_end and ts.range_end:days() ~= ts:days() then
        local a, b = ts:days(), ts.range_end:days()
        local n = b - a + 1
        for d = math.max(a, from), math.min(b, to) do
          add(d, new_item(hl, {
            type = "range",
            date = ts,
            time = d == a and time_of(ts) or nil,
            extra = string.format("(%d/%d): ", d - a + 1, n),
            face = done and "OrgAgendaDone" or "OrgAgendaTimestamp",
          }))
        end
      else
        for _, o in ipairs(date.occurrences(ts, from, to)) do
          add(o:days(), new_item(hl, {
            type = "timestamp",
            date = o,
            time = time_of(o),
            end_time = end_time_of(o),
            extra = "",
            face = done and "OrgAgendaDone" or "OrgAgendaTimestamp",
          }))
        end
      end
    end

    -- inactive timestamps (org-agenda-include-inactive-timestamps) --
    if opts.inactive then
      local lines = hl.file.lines
      local pr = hl.properties_range
      for i = hl.line, hl.body_end do
        local line = lines[i] or ""
        local skip = i == hl.planning_line or (pr and i >= pr[1] and i <= pr[2]) or line:match("^%s*CLOCK:")
        if not skip then
          for _, m in ipairs(date.parse_all(line)) do
            local ts = m.date
            if not ts.active and not ts.range_end then
              add(ts:days(), new_item(hl, {
                type = "timestamp",
                date = ts,
                time = time_of(ts),
                end_time = end_time_of(ts),
                extra = "",
                face = done and "OrgAgendaDone" or "OrgAgendaTimestamp",
                inactive = true,
              }))
            end
          end
        end
      end
    end

    -- log mode -------------------------------------------------------
    if opts.log_mode then
      local closed = hl.planning.closed
      if (log_items.closed or opts.log_mode == "all") and closed then
        add(closed:days(), new_item(hl, {
          type = "closed",
          date = closed,
          time = time_of(closed),
          extra = "Closed:     ",
          face = "OrgAgendaDone",
          log = true,
        }))
      end
      if log_items.clock or opts.log_mode == "all" then
        for _, c in ipairs(hl.clocks) do
          add(c.start:days(), new_item(hl, {
            type = "clock",
            date = c.start,
            time = time_of(c.start),
            end_time = c["end"] and c["end"]:is_same_day(c.start) and time_of(c["end"]) or nil,
            extra = string.format("Clocked:   (%s) ", c.minutes and date.format_duration(c.minutes) or "-"),
            face = "OrgAgendaLog",
            log = true,
            clock_line = c.line,
          }))
        end
      end
      if log_items.state or opts.log_mode == "all" then
        for i = hl.line + 1, hl.body_end do
          local line = hl.file.lines[i]
          local kw, ts = line:match('^%s*%-%s+State%s+"([^"]+)".-(%[%d%d%d%d%-%d%d%-%d%d[^%]]*%])')
          local d = kw and date.parse(ts)
          if d then
            add(d:days(), new_item(hl, {
              type = "state",
              date = d,
              time = time_of(d),
              extra = string.format("State:     (%s) ", kw),
              face = "OrgAgendaLog",
              log = true,
            }))
          end
        end
      end
    end
  end)
  return by_day
end

---------------------------------------------------------------------------
-- Lists
---------------------------------------------------------------------------

local function ignored_by_date(hl, acfg, today)
  local s, dl = hl.planning.scheduled, hl.planning.deadline
  local is = acfg.todo_ignore_scheduled
  if is and s then
    if is == "all" or is == true then
      return true
    elseif is == "future" and s:days() > today then
      return true
    elseif is == "past" and s:days() <= today then
      return true
    end
  end
  local id = acfg.todo_ignore_deadlines
  if id and dl then
    local warn = date.warning_days(dl, config.opts.deadline_warning_days)
    local diff = dl:days() - today
    if id == "all" or id == true then
      return true
    elseif id == "near" and diff <= warn then
      return true
    elseif id == "far" and diff > warn then
      return true
    elseif id == "past" and diff <= 0 then
      return true
    elseif id == "future" and diff > 0 then
      return true
    end
  end
  local iw = acfg.todo_ignore_with_date
  if iw and (s or dl or #hl.timestamps > 0) then
    return true
  end
  return false
end

--- Global TODO list.
---@param keywords? string[] restrict to these keywords (nil = all not-done)
function M.todo(files, keywords, opts)
  opts = opts or {}
  local acfg = vim.tbl_extend("force", config.opts.agenda, opts.block or {})
  local today = date.today_days()
  local set
  if keywords and #keywords > 0 then
    set = {}
    for _, k in ipairs(keywords) do
      set[k] = true
    end
  end
  local out = {}
  M.each_headline(files, opts, function(hl)
    if not hl.todo then
      return
    end
    if set then
      if not set[hl.todo] then
        return
      end
    elseif not hl:is_todo() then
      return
    end
    if ignored_by_date(hl, acfg, today) then
      return
    end
    out[#out + 1] = new_item(hl, { type = "todo", face = hl:is_done() and "OrgAgendaDone" or nil })
  end)
  return out
end

--- Tags / property match.
function M.tags(files, predicate, todo_only, opts)
  opts = opts or {}
  local acfg = vim.tbl_extend("force", config.opts.agenda, opts.block or {})
  local today = date.today_days()
  local out = {}
  M.each_headline(files, opts, function(hl)
    if todo_only and not hl:is_todo() then
      return
    end
    if todo_only and ignored_by_date(hl, acfg, today) then
      return
    end
    if predicate(hl) then
      out[#out + 1] = new_item(hl, { type = "tags", face = hl:is_done() and "OrgAgendaDone" or nil })
    end
  end)
  return out
end

--- Text search.
function M.search(files, predicate, opts)
  local out = {}
  M.each_headline(files, opts, function(hl)
    if predicate(hl) then
      out[#out + 1] = new_item(hl, { type = "search", face = hl:is_done() and "OrgAgendaDone" or nil })
    end
  end)
  return out
end

local function subtree_descendants(hl, fn)
  for _, c in ipairs(hl.children) do
    if fn(c) then
      return true
    end
    if subtree_descendants(c, fn) then
      return true
    end
  end
  return false
end

--- Stuck projects (org-stuck-projects).
function M.stuck(files, opts)
  opts = opts or {}
  local sp = vim.tbl_extend("force", config.opts.agenda.stuck_projects or {}, (opts.block or {}).stuck_projects or {})
  local pred = require("org.agenda.search").compile(sp.match or "+LEVEL=2/-DONE")
  local kws, tags = {}, {}
  for _, k in ipairs(sp.todo_keywords or {}) do
    kws[k] = true
  end
  for _, t in ipairs(sp.tags or {}) do
    tags[t] = true
  end
  local text_re = sp.text and sp.text ~= "" and vim.regex(sp.text) or nil
  local out = {}
  M.each_headline(files, opts, function(hl)
    if not pred(hl) then
      return
    end
    local active = subtree_descendants(hl, function(c)
      if c.todo and kws[c.todo] then
        return true
      end
      for _, t in ipairs(c.tags) do
        if tags[t] then
          return true
        end
      end
      return false
    end)
    if not active and text_re then
      for i = hl.line + 1, hl.end_line do
        if text_re:match_str(hl.file.lines[i]) then
          active = true
          break
        end
      end
    end
    if not active then
      out[#out + 1] = new_item(hl, { type = "stuck" })
    end
  end)
  return out
end

---------------------------------------------------------------------------
-- Sorting
---------------------------------------------------------------------------

local function prio_rank(item)
  local p = item.priority
  local f = item.headline.file
  local pr = f:priorities()
  p = p or pr.default
  -- higher rank = more important
  return -(p:byte() or 0)
end

local function todo_rank(item)
  local kw = item.todo and item.headline.file.settings.todo:get(item.todo)
  return kw and kw.index or 1000
end

local function effort(item)
  local v = item.headline:get_property(config.opts.effort_property or "Effort")
  return v and date.parse_duration(v) or nil
end

local function urgency(item)
  local u = prio_rank(item) * 100
  local dl = item.headline.planning.deadline
  if dl then
    u = u + math.max(0, 100 - (dl:days() - date.today_days()) * 5)
  end
  return u
end

local HUGE = math.huge

local strategies = {
  ["time-up"] = function(a, b)
    return (a.time or HUGE), (b.time or HUGE)
  end,
  ["time-down"] = function(a, b)
    return -(a.time or -HUGE), -(b.time or -HUGE)
  end,
  ["priority-down"] = function(a, b)
    return -prio_rank(a), -prio_rank(b)
  end,
  ["priority-up"] = function(a, b)
    return prio_rank(a), prio_rank(b)
  end,
  ["urgency-down"] = function(a, b)
    return -urgency(a), -urgency(b)
  end,
  ["urgency-up"] = function(a, b)
    return urgency(a), urgency(b)
  end,
  ["category-up"] = function(a, b)
    return a.category:lower(), b.category:lower()
  end,
  ["category-down"] = function(a, b)
    return b.category:lower(), a.category:lower()
  end,
  ["todo-state-up"] = function(a, b)
    return todo_rank(a), todo_rank(b)
  end,
  ["todo-state-down"] = function(a, b)
    return -todo_rank(a), -todo_rank(b)
  end,
  ["alpha-up"] = function(a, b)
    return a.title:lower(), b.title:lower()
  end,
  ["alpha-down"] = function(a, b)
    return b.title:lower(), a.title:lower()
  end,
  ["habit-up"] = function(a, b)
    return a.habit and 0 or 1, b.habit and 0 or 1
  end,
  ["habit-down"] = function(a, b)
    return a.habit and 1 or 0, b.habit and 1 or 0
  end,
  ["deadline-up"] = function(a, b)
    local da, db = a.headline.planning.deadline, b.headline.planning.deadline
    return da and da:minutes() or HUGE, db and db:minutes() or HUGE
  end,
  ["deadline-down"] = function(a, b)
    local da, db = a.headline.planning.deadline, b.headline.planning.deadline
    return da and -da:minutes() or HUGE, db and -db:minutes() or HUGE
  end,
  ["scheduled-up"] = function(a, b)
    local da, db = a.headline.planning.scheduled, b.headline.planning.scheduled
    return da and da:minutes() or HUGE, db and db:minutes() or HUGE
  end,
  ["scheduled-down"] = function(a, b)
    local da, db = a.headline.planning.scheduled, b.headline.planning.scheduled
    return da and -da:minutes() or HUGE, db and -db:minutes() or HUGE
  end,
  ["tag-up"] = function(a, b)
    return (a.tags[1] or "~"):lower(), (b.tags[1] or "~"):lower()
  end,
  ["tag-down"] = function(a, b)
    return (b.tags[1] or ""):lower(), (a.tags[1] or ""):lower()
  end,
  ["effort-up"] = function(a, b)
    return effort(a) or HUGE, effort(b) or HUGE
  end,
  ["effort-down"] = function(a, b)
    return -(effort(a) or -HUGE), -(effort(b) or -HUGE)
  end,
}
M.strategies = strategies

--- Sort items in place according to a strategy list.
---@param items org.AgendaItem[]
---@param strategy string[]
function M.sort(items, strategy)
  table.sort(items, function(a, b)
    for _, s in ipairs(strategy or {}) do
      local f = strategies[s]
      if f then
        local x, y = f(a, b)
        if x ~= y then
          return x < y
        end
      end
    end
    return a.order < b.order
  end)
  return items
end

return M
