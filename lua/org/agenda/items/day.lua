---@mod org.agenda.items.day The day agenda (org-agenda-get-day-entries)
---
--- `M.agenda`: the items of days [from, to] from the agenda files, entry
--- by entry (deadlines, scheduled, timestamps and ranges, sexps, inactive
--- timestamps and log items, from the parts that collect them), then the
--- Emacs diary and the extra day sources, in the order Emacs collects
--- them. Part of org.agenda.items, which loads it.

-- Not compiled by the JIT, like org.agenda.items (see the comment there).
if jit then
  jit.off(true, true)
end

local config = require("org.config")
local date = require("org.date")
local shared = require("org.agenda.items.shared")

local M = require("org.agenda.items")

local acfg_for = shared.acfg_for
local set_time = shared.set_time
local with_candidate = shared.with_candidate

--- What the parts collecting the items of a day agenda share: the options
--- and the range, and `add` to file an item under a day.
---@class org.agenda.items.DayContext
---@field opts table
---@field cfg table config.opts
---@field acfg table the agenda options, with the block's
---@field block_acfg table `acfg` without default_appointment_duration (org-agenda-get-blocks)
---@field today integer
---@field from integer
---@field to integer
---@field types table<string, boolean> entry types (org-agenda-entry-types)
---@field log_items table<string, boolean> log mode items
---@field habit_cfg table
---@field leaders_s string[] scheduled leaders
---@field leaders_d string[] deadline leaders
---@field leaders_r string[] time range leaders
---@field inactive_leader string
---@field dl_past_days integer
---@field sc_past_days integer
---@field fidx integer the index of the file whose items are being collected
---@field add fun(day: integer, item: table)
---@field eval_sexp fun(s: string, day: integer, text?: string): any

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

--- Can the entry show in a day agenda (the timestamps
--- org-agenda-get-day-entries looks at)?
local function has_agenda_date(hl)
  local p = hl.planning
  return p.scheduled or p.deadline or p.closed or #hl.timestamps > 0 or #hl.clocks > 0 or hl.first_inactive
end

-- whether a file's lines contain "%%(" (diary sexps, <%%(...)> stamps),
-- by lines table: most files have none, and then the per-entry line scans
-- for sexps are skipped
local has_sexps_memo = setmetatable({}, { __mode = "k" })

local function has_sexps(file)
  local lines = file.lines or {}
  local v = has_sexps_memo[lines]
  if v == nil then
    v = false
    for i = 1, #lines do
      if lines[i]:find("%%(", 1, true) then
        v = true
        break
      end
    end
    has_sexps_memo[lines] = v
  end
  return v
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
---@param opts? { today?: integer, log_mode?: boolean|string|string[], restrict?: table, skip?: function, block?: table,
---  inactive?: boolean, no_deadlines?: boolean, archives?: string|boolean, include_diary?: boolean }
---@return table<integer, org.AgendaItem[]> items by day
function M.agenda(files, from, to, opts)
  opts = opts or {}
  local acfg = acfg_for(opts)
  local by_day = {}
  -- the clock check lists clocked entries only; log "only" shows log items only
  local clockcheck = opts.log_mode == "clockcheck"
  local log_only = clockcheck or opts.log_mode == "only"
  local ctx
  local function add(day, item)
    if day < from or day > to or (log_only and not item.log) then
      return
    end
    item.day = day
    item.fidx = ctx.fidx
    by_day[day] = by_day[day] or {}
    table.insert(by_day[day], item)
  end
  ---@type org.agenda.items.DayContext
  ctx = {
    opts = opts,
    cfg = config.opts,
    acfg = acfg,
    today = opts.today or date.today_days(),
    from = from,
    to = to,
    types = entry_types(acfg, opts),
    log_items = {},
    habit_cfg = acfg.habits or {},
    leaders_s = acfg.scheduled_leaders or { "Scheduled: ", "Sched.%2dx: " },
    leaders_d = acfg.deadline_leaders or { "Deadline:  ", "In %3d d.: ", "%2d d. ago: " },
    leaders_r = acfg.timerange_leaders or { "", "(%d/%d): " },
    inactive_leader = acfg.inactive_leader or "[",
    dl_past_days = acfg.deadline_past_days or 10000,
    sc_past_days = acfg.scheduled_past_days or 10000,
    -- org-agenda-get-blocks binds org-agenda-default-appointment-duration
    -- to nil: a range's first and last days show only their own time
    block_acfg = vim.tbl_extend("force", acfg, { default_appointment_duration = false }),
    fidx = 0,
    add = add,
    eval_sexp = shared.sexp_evaluator(from, to),
  }
  local log_list = acfg.log_mode_items or { "closed", "clock" }
  local log_mode = opts.log_mode
  if type(log_mode) == "table" then
    log_list = log_mode
  end
  for _, k in ipairs(log_list) do
    ctx.log_items[k] = true
  end
  if clockcheck then
    ctx.log_items = { clock = true }
  end
  local types = ctx.types

  if package.loaded["org.agenda.holidays"] then
    package.loaded["org.agenda.holidays"].reset()
  end

  -- sexp lines before the first heading (Emacs searches the whole buffer;
  -- org-agenda-skip skips a file tagged ARCHIVE, those lines too)
  if types.sexp and not (opts.restrict and opts.restrict.range) then
    for fidx, file in ipairs(files) do
      ctx.fidx = fidx
      if has_sexps(file) and (opts.archives or not M.file_archived(file)) then
        shared.add_sexps(ctx, nil, file, 1, file.preamble_end or 0)
      end
    end
  end

  local parser = require("org.parser")
  -- the text after an inline task's END line is an entry of its own in
  -- Emacs' agenda (see parser.inline_end_entry)
  local function candidate(hl)
    if has_agenda_date(hl) then
      return true
    end
    local tail = hl.inlinetask and parser.inline_end_entry(hl)
    return tail ~= nil and tail ~= false and has_agenda_date(tail)
  end
  M.each_headline(files, with_candidate(opts, candidate), function(hl, _, fidx)
    ctx.fidx = fidx
    local done = hl:is_done()
    local sexps = has_sexps(hl.file)
    -- deadline days of this entry, for the skip-*-if-deadline-is-shown options
    local dl_shown = {}
    -- org-agenda-get-timestamps skips what is before the first heading
    -- (org-before-first-heading-p, which doesn't count inline tasks): an
    -- inline task there gets its date ranges, not its timestamps
    local before_first = hl.inlinetask and not hl.parent or false

    shared.deadlines(ctx, hl, done, dl_shown)
    shared.scheduled(ctx, hl, done, dl_shown)
    shared.timestamps(ctx, hl, done, sexps, dl_shown, before_first)
    if sexps then
      shared.sexp_entries(ctx, hl, done)
    end
    shared.inactive_timestamps(ctx, hl, done, before_first)
    local tail = hl.inlinetask and parser.inline_end_entry(hl)
    if tail then
      shared.timestamps(ctx, tail, false, sexps, {}, before_first)
      shared.inactive_timestamps(ctx, tail, false, before_first)
    end
    if opts.log_mode then
      shared.log_entries(ctx, hl)
    end
  end)
  -- the Emacs diary after the files (org-agenda-include-diary); Emacs adds
  -- it in every log mode too
  local include_diary = opts.include_diary
  if include_diary == nil then
    include_diary = acfg.include_diary
  end
  if include_diary then
    local diary = require("org.agenda.diary")
    -- org-get-entries-from-diary binds org-agenda-search-headline-for-time
    local dcfg = vim.tbl_extend("force", acfg, { search_headline_for_time = true })
    local cache = {}
    for d = from, to do
      for _, l in ipairs(diary.day_lines(d, cache)) do
        local f = l.entry and l.entry.file
        local item = {
          type = "diary",
          ts_type = "diary",
          filename = f and f.path or nil,
          -- holidays have no location
          lnum = f and l.entry.lnum or 0,
          raw = f and diary._line_text(f, l.entry.lnum) or "",
          title = vim.trim(l.text),
          category = "Diary",
          tags = {},
          done = false,
          level = 0,
          order = shared.next_order(),
          prio = 0,
          urgency = 0,
          extra = "",
          face = "OrgAgendaDiary",
          day = d,
          fidx = #files + 1,
        }
        set_time(item, nil, dcfg)
        by_day[d] = by_day[d] or {}
        table.insert(by_day[d], item)
      end
    end
  end
  if next(M.day_sources) and not log_only then
    local names = vim.tbl_keys(M.day_sources)
    table.sort(names)
    for i, name in ipairs(names) do
      local ok, list = pcall(M.day_sources[name], from, to, opts)
      if not ok then
        require("org.utils").error("agenda source " .. name .. ": " .. tostring(list))
      else
        for _, item in ipairs(list or {}) do
          local d = item.day
          if d and d >= from and d <= to then
            item.order = shared.next_order()
            item.fidx = #files + 1 + i
            item.tags = item.tags or {}
            item.prio = item.prio or 0
            item.urgency = item.urgency or item.prio
            item.level = item.level or 0
            item.lnum = item.lnum or 0
            item.raw = item.raw or ""
            by_day[d] = by_day[d] or {}
            table.insert(by_day[d], item)
          end
        end
      end
    end
  end
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
