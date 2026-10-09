---@mod org.extensions.timeline Text-mode Gantt chart of planned tasks
---
--- One row per task with a SCHEDULED or DEADLINE date: a bar from the
--- scheduled day to the deadline (or as long as its Effort), the deadline
--- as ◆, today marked, overdue tasks in the error colour and, optionally,
--- the days the task was clocked.
---
--- ```lua
--- require("org").setup({ extensions = { timeline = { zoom = "week" } } })
--- ```

local views = require("org.extensions.views_util")
local date = require("org.date")
local utils = require("org.utils")

local M = {}

local MOD = "org.extensions.timeline"
local ns = vim.api.nvim_create_namespace("org_timeline")
local augroup = vim.api.nvim_create_augroup("OrgTimeline", { clear = true })

--- Zoom levels, finest first: days per cell and cell width.
M.ZOOMS = {
  { name = "hour", days = 1, width = 24 },
  { name = "day", days = 1, width = 3 },
  { name = "week", days = 1, width = 1 },
  { name = "month", days = 7, width = 1 },
}

--- See :h org-extensions-stability (scripts/extension_report.lua measures it).
M.stability = "experimental"

M.defaults = {
  --- Tasks come from: "agenda", "buffer", "subtree", or files / globs.
  source = "agenda",
  --- Only tasks matching this org-ql query (sexp or plain syntax).
  ---@type string|nil
  query = nil,
  --- Only tasks with this tag (inherited tags count).
  ---@type string|nil
  tag = nil,
  --- Also show DONE tasks (dimmed).
  show_done = false,
  --- Starting zoom: "hour" (a column an hour), "day" (3 columns a day),
  --- "week" (a column a day) or "month" (a column a week).
  zoom = "day",
  --- Days before today shown at the left edge when opening.
  days_before = 3,
  --- Width of the task names on the left.
  label_width = 34,
  --- Working hours in a day, to turn an Effort into days for a bar that
  --- has only a start or only an end.
  hours_per_day = 8,
  --- Show the days each task was clocked (▒); `c` toggles it.
  clocks = false,
  --- Show calendar events of the ics extension (when it is on and the
  --- source is the agenda files).
  ics = true,
  --- Window: "float", "tab", "split", "vsplit" or "current".
  layout = "float",
  width = 0.94,
  height = 0.88,
  --- Save the file after S / D; nil follows `agenda.save_after_edit`.
  ---@type boolean|nil
  save = nil,
  --- Keys in the timeline.
  keys = {
    zoom_in = { "+", "=" },
    zoom_out = "-",
    pan_left = "[",
    pan_right = "]",
    today = ".",
    jump = "<CR>",
    schedule = "S",
    deadline = "D",
    clocks = "c",
    refresh = "r",
    quit = { "<Esc>", "q" },
  },
}

M.actions = {
  timeline_open = { MOD, "open", desc = "Timeline (Gantt chart) of scheduled tasks and deadlines" },
  timeline_buffer = { MOD, "open_buffer", desc = "Timeline of the tasks of the current buffer" },
}

M.commands = {
  timeline = {
    MOD,
    "command",
    desc = "Timeline: :Org timeline [agenda|buffer|subtree|<file>] [hour|day|week|month] [filter]",
    complete = function(arglead, cmdline)
      return require(MOD).complete(arglead, cmdline)
    end,
  },
}

M.mappings = { global = { timeline_open = "<prefix>Vt" } }
M.groups = { { "V", "views" } }

---@type table|nil
M.state = nil

local function opts()
  return require("org.extensions").opts("timeline") or M.defaults
end

function M.setup()
  views.highlights(augroup, {
    OrgTimelineTitle = { link = "Title" },
    OrgTimelineHint = { link = "Comment" },
    OrgTimelineAxis = { link = "Comment" },
    OrgTimelineMonth = { link = "Title" },
    OrgTimelineSeparator = { link = "WinSeparator" },
    OrgTimelineBar = { link = "Function" },
    OrgTimelineDone = { link = "Comment" },
    OrgTimelineOverdue = { link = "DiagnosticError" },
    OrgTimelineDeadline = { link = "DiagnosticWarn" },
    OrgTimelineClock = { link = "String" },
    OrgTimelineTodayLabel = { link = "Search" },
    OrgTimelineTask = {},
    OrgTimelineRepeat = { link = "Identifier" },
    OrgTimelineEvent = { link = "Special" },
  })
  views.highlights(augroup, M.column_highlights)
end

--- Backgrounds of the today and weekend columns: faint tints of the
--- window background, so the bars stay readable.
---@return table<string, table>
function M.column_highlights()
  local light = vim.o.background == "light"
  local bg = views.color("NormalFloat", "bg") or views.color("Normal", "bg") or (light and 0xffffff or 0x000000)
  local fg = views.color("Normal", "fg") or (light and 0x000000 or 0xffffff)
  local warn = views.color("DiagnosticWarn", "fg") or 0xd7af00
  return {
    OrgTimelineWeekend = { bg = views.blend(bg, fg, 0.05), ctermbg = light and 255 or 234 },
    OrgTimelineToday = { bg = views.blend(bg, warn, 0.2), ctermbg = light and 230 or 236 },
  }
end

function M.teardown()
  M.close()
  vim.api.nvim_clear_autocmds({ group = augroup })
end

function M.health(h)
  h.ok("timeline: :Org timeline")
end

---------------------------------------------------------------------------
-- Tasks
---------------------------------------------------------------------------

local function effort_days(minutes, o)
  if not minutes or minutes <= 0 then
    return nil
  end
  return math.max(1, math.ceil(minutes / ((o.hours_per_day or 8) * 60)))
end

local function time_of(ts)
  return ts and ts:has_time() and (ts.hour * 60 + (ts.min or 0)) or nil
end

--- The row of a headline, or nil when it has no date to show:
--- `start` / `finish` (day numbers) of its bar with the times of day
--- `start_min` / `finish_min` when known, `deadline` and `deadline_min`,
--- `overdue`, `done`, `clock_days` and, for a repeating task, `rep`
--- (the repeating timestamp, whose later occurrences are drawn too).
---@param hl org.Headline
---@param o table options
---@param today integer
---@param clocks boolean
function M.task(hl, o, today, clocks)
  local sts, dts = hl.planning.scheduled, hl.planning.deadline
  local s = sts and sts:days()
  local d = dts and dts:days()
  local done = hl:is_done()
  local clock_days
  if clocks then
    for _, c in ipairs(hl.clocks) do
      clock_days = clock_days or {}
      clock_days[c.start:days()] = true
    end
  end
  if not s and not d and not clock_days then
    return nil
  end
  local effort = views.effort(hl)
  local ed = effort_days(effort, o)
  local smin, dmin = time_of(sts), time_of(dts)
  local start, finish, start_min, finish_min
  if s and d then
    start, finish = math.min(s, d), math.max(s, d)
    if s <= d then
      start_min, finish_min = smin, dmin
    end
  elseif s then
    start, start_min = s, smin
    if smin and sts.end_hour then
      -- a time range: that part of the day
      finish, finish_min = s, sts.end_hour * 60 + (sts.end_min or 0)
    elseif smin and effort and effort > 0 and smin + effort <= 1440 then
      finish, finish_min = s, smin + effort
    else
      finish = s + (ed or 1) - 1
    end
  elseif d then
    start, finish, finish_min = d - (ed or 1) + 1, d, dmin
  end
  local cmin, cmax
  for day in pairs(clock_days or {}) do
    cmin = math.min(cmin or day, day)
    cmax = math.max(cmax or day, day)
  end
  local rep
  if not done then
    for _, ts in ipairs({ sts or false, dts or false }) do
      if ts and ts.repeater and (ts.repeater.value or 0) > 0 then
        rep = ts
        break
      end
    end
  end
  return {
    ref = views.ref(hl),
    todo = hl.todo,
    title = views.title(hl),
    start = start,
    finish = finish,
    start_min = start_min,
    finish_min = finish_min,
    scheduled = s,
    deadline = d,
    deadline_min = dmin,
    effort = effort,
    done = done,
    overdue = not done and d ~= nil and d < today,
    clock_days = clock_days,
    rep = rep,
    first = start or cmin,
    last = finish or cmax,
  }
end

local function sort_rows(rows)
  table.sort(rows, function(a, b)
    if a.first ~= b.first then
      return a.first < b.first
    end
    if a.last ~= b.last then
      return a.last < b.last
    end
    return a.order < b.order
  end)
end

--- The rows of the timeline's tasks, sorted by start day. Remembers the
--- files shown (`file_set`, `key`) for the redraw watch.
---@param st table
---@return table[] rows, string|nil err
function M.build(st)
  local o = st.opts
  local today = date.today_days()
  local files = views.files(st.src)
  st.file_set = views.file_set(files)
  st.key = views.files_key(files)
  local hls, err = views.collect(st.src, {
    files = files,
    query = o.query,
    filter = st.filter,
    tag = st.tag,
    pred = function(hl)
      return o.show_done or not hl:is_done()
    end,
  })
  local rows = {}
  for i, hl in ipairs(hls) do
    local t = M.task(hl, o, today, st.clocks)
    if t then
      t.order = i
      rows[#rows + 1] = t
    end
  end
  sort_rows(rows)
  return rows, err
end

--- Rows of the calendar events (ics extension) between days `from` and
--- `to`: one per event, a span per occurrence.
---@return table[]
function M.event_rows(from, to)
  local ok, ics = pcall(require, "org.extensions.ics")
  if not ok then
    return {}
  end
  local items_ok, items = pcall(ics.agenda_items, from, to, {})
  if not items_ok then
    return {}
  end
  local by_key, rows = {}, {}
  for _, item in ipairs(items or {}) do
    local x = item.ics
    if x and x.start then
      local ev = x.event or {}
      local key = tostring(x.calendar) .. "|" .. ((ev.uid and ev.uid ~= "") and ev.uid or item.title)
      local row = by_key[key]
      if not row then
        row = { ics = true, title = item.title, spans = {}, seen = {}, order = 1e9 + #rows }
        by_key[key] = row
        rows[#rows + 1] = row
      end
      if not row.seen[x.start] then
        row.seen[x.start] = true
        local sd = math.floor(x.start / 86400)
        local stop = math.max(x.stop or x.start, x.start)
        local fd = stop > x.start and math.floor((stop - 1) / 86400) or sd
        local span = { start = sd, finish = fd }
        if not x.all_day then
          span.start_min = math.floor((x.start % 86400) / 60)
          span.finish_min = stop > x.start and (math.floor(((stop - 1) % 86400) / 60) + 1) or nil
        end
        row.spans[#row.spans + 1] = span
        row.first = math.min(row.first or sd, sd)
        row.last = math.max(row.last or fd, fd)
      end
    end
  end
  for _, row in ipairs(rows) do
    row.seen = nil
  end
  return rows
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local HEADER_LINES = 2

local function zoom(st)
  return M.ZOOMS[st.zoom]
end

local function win_width(st)
  local win = st.win and vim.api.nvim_win_is_valid(st.win) and st.win or nil
  return win and vim.api.nvim_win_get_width(win) or vim.o.columns
end

--- Width of the task names: `label_width`, at most 40% of a narrow window.
local function label_width(st)
  return math.max(8, math.min(st.opts.label_width or 34, math.floor(win_width(st) * 0.4)))
end

--- The drawing characters. The chart has one character per cell, so a
--- glyph two cells wide (box drawing and blocks with 'ambiwidth' "double")
--- falls back to ASCII there; the separators may be wider as long as they
--- line up.
local function glyphs()
  local function pick(ch, alt)
    return utils.width(ch) == 1 and ch or alt
  end
  return {
    v = "│",
    h = "─",
    x = "┼",
    bar = pick("█", "#"),
    diamond = pick("◆", "*"),
    trail = pick("┄", "."),
    clock = pick("▒", ":"),
  }
end
-- the characters of the current draw (set by M.draw)
local G = glyphs()

--- `ch` repeated over `cells` display cells; a cell it can't fill (it is
--- two cells wide) is a space.
local function fill(ch, cells)
  local cw = math.max(1, utils.width(ch))
  local n = math.max(0, math.floor(cells / cw))
  return string.rep(ch, n) .. string.rep(" ", math.max(0, cells - n * cw))
end

--- Number of cells that fit in the chart area: at least 4, or 1 at hour
--- zoom, where a cell is a whole day.
local function cell_count(st)
  local width = win_width(st) - label_width(st) - 2 - utils.width(G.v)
  local w = zoom(st).width
  return math.max(w > 3 and 1 or 4, math.floor(width / w))
end

--- First and last day of cell `i` (0-based).
local function cell_days(st, i)
  local z = zoom(st)
  local a = st.start + i * z.days
  return a, a + z.days - 1
end

-- highlight group lists by background (weekend / today) and foreground,
-- shared so that runs of equal cells merge into one extmark
local BG = {
  we = { "OrgTimelineWeekend" },
  t = { "OrgTimelineToday" },
  wet = { "OrgTimelineWeekend", "OrgTimelineToday" },
}
local combos = {}
local function groups_of(bg, fg)
  local key = (bg or "") .. "|" .. (fg or "")
  local g = combos[key]
  if g == nil then
    g = vim.list_extend({}, BG[bg] or {})
    if fg then
      g[#g + 1] = fg
    end
    g = #g > 0 and g
    combos[key] = g
  end
  return g or nil
end

--- The cells of a row between cells 0 and n-1: `cov[i]` the bar span
--- covering the cell, `dls[i]` a deadline in it, `trail[i]` the overdue
--- trail, `clk[i]` a clocked day.
local function row_features(st, row, n, today, last_day)
  local zd = zoom(st).days
  local s0 = st.start
  local function idx(day)
    return math.floor((day - s0) / zd)
  end
  local cov, dls, trail, clk = {}, {}, {}, {}
  local function cover(span)
    for i = math.max(0, idx(span.start)), math.min(n - 1, idx(span.finish)) do
      if not cov[i] then
        cov[i] = span
      end
    end
  end
  local function deadline(day, min, hl)
    local i = idx(day)
    if i >= 0 and i < n and not dls[i] then
      dls[i] = { min = min, hl = hl }
    end
  end
  local bar_hl = row.done and "OrgTimelineDone" or (row.overdue and "OrgTimelineOverdue") or "OrgTimelineBar"
  if row.ics then
    for _, sp in ipairs(row.spans) do
      sp.hl = "OrgTimelineEvent"
      cover(sp)
    end
    return cov, dls, trail, clk
  end
  if row.start then
    cover({
      start = row.start,
      finish = row.finish,
      start_min = row.start_min,
      finish_min = row.finish_min,
      hl = bar_hl,
      base = true,
    })
  end
  if row.deadline then
    local dl_hl = row.done and "OrgTimelineDone" or (row.overdue and "OrgTimelineOverdue" or "OrgTimelineDeadline")
    deadline(row.deadline, row.deadline_min, dl_hl)
  end
  if row.rep and row.start then
    -- later occurrences: the whole bar (and deadline) shifted
    local base = row.rep:days()
    local len = row.finish - row.start
    for _, occ in ipairs(date.occurrences(row.rep, s0 - len, last_day + len)) do
      local delta = occ:days() - base
      if delta > 0 then
        cover({
          start = row.start + delta,
          finish = row.finish + delta,
          start_min = row.start_min,
          finish_min = row.finish_min,
          hl = "OrgTimelineRepeat",
        })
        if row.deadline then
          deadline(row.deadline + delta, row.deadline_min, "OrgTimelineRepeat")
        end
      end
    end
  end
  if row.overdue then
    -- how late it is: a dashed trail from the deadline to today
    for i = math.max(0, idx(row.deadline) + 1), math.min(n - 1, idx(today)) do
      trail[i] = true
    end
  end
  for day in pairs(row.clock_days or {}) do
    local i = idx(day)
    if i >= 0 and i < n then
      clk[i] = true
    end
  end
  return cov, dls, trail, clk
end

--- Whether column `p` of day `day`, `len` minutes of it (a third at day
--- zoom, an hour at hour zoom), is under `span`.
local function covers(span, day, p, len)
  if span.start_min and day == span.start and (p + 1) * len <= span.start_min then
    return false
  end
  if span.finish_min and day == span.finish and p * len >= span.finish_min then
    return false
  end
  return true
end

--- Draw the chart part of a row into the canvas.
local function draw_row(cv, st, row, n, today, bgs, last_day)
  local z = zoom(st)
  local w = z.width
  -- a day of several columns shows the times of day: each is `len` minutes
  local fine = w > 1 and z.days == 1
  local len = 1440 / w
  local cov, dls, trail, clk = row_features(st, row, n, today, last_day)
  -- runs of equal characters and highlights become one segment
  local run_ch, run_n, run_hl = nil, 0, nil
  local function emit(ch, hl)
    if ch == run_ch and hl == run_hl then
      run_n = run_n + 1
      return
    end
    if run_n > 0 then
      cv:put(string.rep(run_ch, run_n), run_hl)
    end
    run_ch, run_n, run_hl = ch, 1, hl
  end
  local function bar_group(span, bg, clocked)
    if span.base and clocked and not row.done and not row.overdue then
      return groups_of(bg, "OrgTimelineClock")
    end
    return groups_of(bg, span.hl)
  end
  for i = 0, n - 1 do
    local bg = bgs[i]
    local dl, sp = dls[i], cov[i]
    if fine then
      local day = st.start + i
      local dsub = dl and (dl.min and math.min(w - 1, math.floor(dl.min / len)) or math.floor(w / 2)) or nil
      for p = 0, w - 1 do
        if dsub and p == dsub then
          emit(G.diamond, groups_of(bg, dl.hl))
        elseif dsub and (p > dsub or (sp and sp.start == day and not sp.start_min)) then
          -- after the deadline mark, or a bar that only is the deadline day
          emit(" ", groups_of(bg, nil))
        elseif sp and covers(sp, day, p, len) then
          emit(G.bar, bar_group(sp, bg, clk[i]))
        elseif trail[i] then
          emit(G.trail, groups_of(bg, "OrgTimelineOverdue"))
        elseif clk[i] then
          emit(G.clock, groups_of(bg, "OrgTimelineClock"))
        else
          emit(" ", groups_of(bg, nil))
        end
      end
    else
      local ch, g
      if dl then
        ch, g = G.diamond, groups_of(bg, dl.hl)
      elseif sp then
        ch, g = G.bar, bar_group(sp, bg, clk[i])
      elseif trail[i] then
        ch, g = G.trail, groups_of(bg, "OrgTimelineOverdue")
      elseif clk[i] then
        ch, g = G.clock, groups_of(bg, "OrgTimelineClock")
      else
        ch, g = " ", groups_of(bg, nil)
      end
      for _ = 1, w do
        emit(ch, g)
      end
    end
  end
  if run_n > 0 then
    cv:put(string.rep(run_ch, run_n), run_hl)
  end
end

--- The axis lines: months, then day numbers (and weekdays at day zoom;
--- weekdays with the day, then the hours, at hour zoom).
local function axis(st, n, today)
  local z = zoom(st)
  local w = z.width
  local total = n * w
  local months = vim.split(string.rep(" ", total), "")
  local days = vim.split(string.rep(" ", total), "")
  local wdays = (z.name == "day" or z.name == "hour") and vim.split(string.rep(" ", total), "") or nil
  local function write(arr, pos, s)
    local chars = vim.fn.split(s, [[\zs]])
    for k, ch in ipairs(chars) do
      if pos + k - 1 <= #arr then
        arr[pos + k - 1] = ch
      end
    end
  end
  local last_month
  local today_pos
  local labels = {}
  for i = 0, n - 1 do
    local a, b = cell_days(st, i)
    local d = date.from_days(a)
    local pos = i * w + 1
    -- a month label where the month starts (the first cell always)
    local md = i == 0 and d or date.from_days(b)
    local key = md.year * 12 + md.month
    if key ~= last_month then
      labels[#labels + 1] = { pos = pos, month = md.month, year = md.year, first = i == 0 }
      last_month = key
    end
    if z.name == "hour" then
      write(days, pos, string.format("%s %d", date.DAY_NAMES[d:weekday()], d.day))
      for h = 0, 21, 3 do
        write(wdays, pos + h, tostring(h))
      end
    elseif z.name == "day" then
      write(days, pos, string.format("%2d", d.day))
      write(wdays, pos, date.DAY_NAMES[d:weekday()]:sub(1, 2))
    elseif z.name == "week" then
      if d:weekday() == 1 then
        write(days, pos, tostring(d.day))
      end
    else
      if d.day <= 7 then
        write(days, pos, "┊")
      end
    end
    if today >= a and today <= b then
      today_pos = pos
    end
  end
  -- labels that would run into the next one are shortened or left out
  for k, l in ipairs(labels) do
    local room = (labels[k + 1] and labels[k + 1].pos or total + 1) - l.pos - 1
    local label = date.MONTH_NAMES[l.month]
    if (l.first or l.month == 1) and room >= #label + 5 then
      label = label .. " " .. l.year
    end
    if room >= #label then
      write(months, l.pos, label)
    end
  end
  local out = { table.concat(months), table.concat(days) }
  if wdays then
    out[#out + 1] = table.concat(wdays)
  end
  return out, today_pos
end

local function hint(o)
  local k = o.keys or {}
  local function key(name)
    return require("org.extensions.views_util").key_hint(k, name)
  end
  local parts = {}
  for _, p in ipairs({
    { "zoom_in", "zoom_out", "zoom" },
    { "pan_left", "pan_right", "pan" },
    { "today", nil, "today" },
    { "jump", nil, "open" },
    { "schedule", nil, "schedule" },
    { "deadline", nil, "deadline" },
    { "clocks", nil, "clocks" },
    { "quit", nil, "quit" },
  }) do
    local a, b = key(p[1]), p[2] and key(p[2])
    if a then
      parts[#parts + 1] = (b and (a .. "/" .. b) or a) .. " " .. p[3]
    end
  end
  return table.concat(parts, "  ")
end

--- Whether calendar events are drawn: the ics extension is on, `ics` is
--- not false and the source is the agenda files.
local function with_events(st)
  return st.opts.ics ~= false and st.src.kind == "agenda" and require("org.extensions").enabled("ics")
end

--- Draw the timeline from `st.task_rows` (built by `build`).
function M.draw(st)
  if not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  local o = st.opts
  G = glyphs()
  local today = date.today_days()
  local n = cell_count(st)
  st.cells = n
  local z = zoom(st)
  local lw = label_width(st)
  local last_day = select(2, cell_days(st, n - 1))
  local rows = st.task_rows or {}
  if with_events(st) then
    rows = vim.list_extend(vim.list_extend({}, rows), M.event_rows(st.start, last_day))
    sort_rows(rows)
  end
  st.rows = rows
  local cv = views.Canvas.new()
  local first, last = date.from_days(st.start), date.from_days(last_day)
  cv:add({
    { " Timeline", "OrgTimelineTitle" },
    { "  " .. views.source_label(st.src), "OrgTimelineHint" },
    {
      string.format(
        "  · %s · %s – %s",
        z.name,
        first:strftime(first.year == last.year and "%b %d" or "%b %d %Y"),
        last:strftime("%b %d %Y")
      ),
      "OrgTimelineHint",
    },
  })
  for _, f in ipairs({
    o.query and ("query " .. o.query) or false,
    st.tag and ("tag " .. st.tag) or false,
    st.filter or false,
  }) do
    if f then
      cv:put("  · " .. f, "OrgTimelineHint")
    end
  end
  if st.err then
    cv:put("  " .. st.err, "DiagnosticError")
  end
  cv:add({ { " " .. hint(o), "OrgTimelineHint" } })
  local ax, today_pos = axis(st, n, today)
  for li, text in ipairs(ax) do
    cv:line()
    cv:put(string.rep(" ", lw + 1))
    cv:put(G.v, "OrgTimelineSeparator")
    local hl = li == 1 and "OrgTimelineMonth" or "OrgTimelineAxis"
    if today_pos and li > 1 then
      -- the today cell of the day rows stands out
      local chars = vim.fn.split(text, [[\zs]])
      cv:put(table.concat(chars, "", 1, today_pos - 1), hl)
      cv:put(table.concat(chars, "", today_pos, today_pos + z.width - 1), "OrgTimelineTodayLabel")
      cv:put(table.concat(chars, "", today_pos + z.width), hl)
    else
      cv:put(text, hl)
    end
  end
  cv:add({
    { fill(G.h, lw + 1), "OrgTimelineSeparator" },
    { G.x, "OrgTimelineSeparator" },
    { fill(G.h, n * z.width), "OrgTimelineSeparator" },
  })
  -- the background of each cell: weekends (at day zoom) and today
  local bgs = {}
  for i = 0, n - 1 do
    local a, b = cell_days(st, i)
    local we = z.days == 1 and z.width > 1 and date.from_days(a):weekday() >= 6
    local t = today >= a and today <= b
    bgs[i] = (we and t) and "wet" or (we and "we") or (t and "t") or nil
  end
  st.first_row_line = #cv.lines + 1
  st.line_rows = {}
  local todo_cfg = require("org.todo_keywords").global()
  for _, row in ipairs(rows) do
    local lnum = cv:line()
    st.line_rows[lnum] = row
    cv:put(" ")
    -- the label is `lw` cells: keyword and title cut to fit together
    local room = lw
    if row.todo then
      local group = views.todo_group(row.todo, todo_cfg)
      local kw_w = utils.width(row.todo)
      if kw_w < room then
        cv:put(row.todo, group)
        cv:put(" ")
        room = room - kw_w - 1
      else
        cv:put(views.fit(row.todo, room), group)
        room = 0
      end
    end
    local title_hl = row.ics and "OrgTimelineEvent"
      or (row.done and "OrgTimelineDone" or (row.overdue and "OrgTimelineOverdue" or "OrgTimelineTask"))
    if room > 0 then
      cv:put(views.fit(row.title, room), title_hl)
    end
    cv:put(G.v, "OrgTimelineSeparator")
    draw_row(cv, st, row, n, today, bgs, last_day)
  end
  if #rows == 0 then
    cv:add({ { " No scheduled tasks or deadlines", "OrgTimelineHint" } })
  end
  cv:draw(st.buf, ns)
  if st.win and vim.api.nvim_win_is_valid(st.win) then
    local cur = vim.api.nvim_win_get_cursor(st.win)[1]
    local line = math.max(cur, st.first_row_line)
    line = math.min(line, vim.api.nvim_buf_line_count(st.buf))
    pcall(vim.api.nvim_win_set_cursor, st.win, { line, 1 })
  end
end

--- Build and draw the timeline.
function M.render(st)
  if not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  st.task_rows, st.err = M.build(st)
  M.draw(st)
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local function current()
  local st = M.state
  if st and vim.api.nvim_buf_is_valid(st.buf) then
    return st
  end
end

--- The task on the cursor line, or nil.
function M.row_at_cursor()
  local st = current()
  if not st or not (st.win and vim.api.nvim_win_is_valid(st.win)) then
    return nil
  end
  return st.line_rows[vim.api.nvim_win_get_cursor(st.win)[1]]
end

--- Rebuild and redraw. With `lazy` (the redraw watch), nothing happens
--- while the timeline's files are unchanged.
---@param lazy? boolean
function M.refresh(lazy)
  local st = current()
  if not st then
    return
  end
  if lazy == true and st.key and st.key == views.files_key(views.files(st.src)) then
    return
  end
  M.render(st)
end

--- First day of the view so that `day` is `offset` cells from the left.
local function start_for(st, day, offset)
  local z = zoom(st)
  local s = day - offset * z.days
  if z.days == 7 then
    -- weeks start on Monday
    s = s - (date.from_days(s):weekday() - 1)
  end
  return s
end

--- Pan by half a screen: `dir` = -1 to the past, 1 to the future.
function M.pan(dir)
  local st = current()
  if not st then
    return
  end
  st.start = st.start + dir * math.max(1, math.floor(st.cells / 2)) * zoom(st).days
  M.draw(st)
end

--- First day of the view with today `days_before` cells from the left,
--- or in the middle when fewer cells fit (at hour zoom).
local function start_today(st)
  local before = math.min(st.opts.days_before or 3, math.floor((cell_count(st) - 1) / 2))
  return start_for(st, date.today_days(), math.max(0, before))
end

--- Zoom in (`dir` = -1) or out (1), keeping today in view when it is,
--- else the middle day in place.
function M.zoom(dir)
  local st = current()
  if not st then
    return
  end
  local nz = math.max(1, math.min(#M.ZOOMS, st.zoom + dir))
  if nz == st.zoom then
    return
  end
  local today = date.today_days()
  local z = zoom(st)
  local on_screen = today >= st.start and today < st.start + st.cells * z.days
  local mid = st.start + math.floor(st.cells / 2) * z.days
  st.zoom = nz
  if on_screen then
    st.start = start_today(st)
  else
    st.start = start_for(st, mid, math.floor(cell_count(st) / 2))
  end
  M.draw(st)
end

function M.goto_today()
  local st = current()
  if not st then
    return
  end
  st.start = start_today(st)
  M.draw(st)
end

function M.toggle_clocks()
  local st = current()
  if st then
    st.clocks = not st.clocks
    M.render(st)
  end
end

function M.jump()
  local st = current()
  local row = M.row_at_cursor()
  if st and row then
    if not row.ref then
      utils.warn("timeline: a calendar event has no heading to open")
      return
    end
    views.jump(row.ref, st.how)
  end
end

--- Reschedule (`kind` "scheduled") or set the deadline of the task at the
--- cursor with the usual date prompt.
function M.plan(kind)
  local st = current()
  local row = M.row_at_cursor()
  if not st or not row then
    return
  end
  if not row.ref then
    utils.warn("timeline: a calendar event can't be rescheduled here")
    return
  end
  local target = views.target(row.ref)
  if not target then
    return
  end
  local ts = require("org.timestamps")
  local res = kind == "deadline" and ts.deadline(target) or ts.schedule(target)
  if res then
    views.after_edit(target.bufnr, st.opts.save)
  end
  if current() == st then
    M.render(st)
  end
end

function M.close()
  local st = M.state
  M.state = nil
  if not st then
    return
  end
  pcall(vim.api.nvim_del_augroup_by_id, st.watch)
  if vim.api.nvim_buf_is_valid(st.buf) then
    local win = st.how.win
    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == st.buf then
      views.close(st.how)
    end
    if vim.api.nvim_buf_is_valid(st.buf) then
      pcall(vim.api.nvim_buf_delete, st.buf, { force = true })
    end
  end
end

---------------------------------------------------------------------------
-- Opening
---------------------------------------------------------------------------

local function zoom_index(name)
  for i, z in ipairs(M.ZOOMS) do
    if z.name == name then
      return i
    end
  end
end

--- Open the timeline.
---@param o? { source?: any, zoom?: string, filter?: string, tag?: string, query?: string }
function M.open(o)
  o = type(o) == "table" and o or {}
  local eopts = vim.deepcopy(opts())
  if o.query then
    eopts.query = o.query
  end
  local src, err = views.resolve_source(o.source or eopts.source)
  if not src then
    utils.error("timeline: " .. err)
    return
  end
  M.close()
  local buf = views.scratch("org://timeline", "orgtimeline")
  local st = {
    buf = buf,
    src = src,
    opts = eopts,
    filter = o.filter,
    tag = o.tag or eopts.tag,
    clocks = eopts.clocks,
    zoom = zoom_index(o.zoom or eopts.zoom) or zoom_index("day"),
  }
  M.state = st
  st.win, st.how = views.open(buf, eopts.layout, { width = eopts.width, height = eopts.height, title = "Timeline" })
  vim.wo[st.win].cursorline = true
  st.start = start_today(st)
  views.map(buf, eopts.keys, {
    zoom_in = function()
      M.zoom(-1)
    end,
    zoom_out = function()
      M.zoom(1)
    end,
    pan_left = function()
      M.pan(-1)
    end,
    pan_right = function()
      M.pan(1)
    end,
    today = M.goto_today,
    jump = M.jump,
    schedule = function()
      M.plan("scheduled")
    end,
    deadline = function()
      M.plan("deadline")
    end,
    clocks = M.toggle_clocks,
    refresh = function()
      M.refresh()
    end,
    quit = M.close,
  }, "timeline")
  st.watch = views.watch("OrgTimelineWatch", function()
    if current() == st then
      M.refresh(true)
    end
  end, { buf = buf, relevant = views.relevant(st) })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = st.watch,
    callback = function(ev)
      if current() ~= st then
        return
      end
      if ev.event == "WinResized" and not vim.tbl_contains(vim.v.event.windows or {}, st.win) then
        return
      end
      if ev.event == "VimResized" then
        views.relayout(st.how)
      end
      pcall(M.draw, st)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = st.watch,
    buffer = buf,
    callback = function()
      if M.state == st then
        M.state = nil
      end
      vim.schedule(function()
        pcall(vim.api.nvim_del_augroup_by_id, st.watch)
      end)
    end,
  })
  M.render(st)
  return st
end

function M.open_buffer()
  return M.open({ source = "buffer" })
end

--- Parse `:Org timeline` arguments.
function M.parse_args(args)
  local o = {}
  local rest = {}
  for _, w in ipairs(vim.split(vim.trim(args or ""), "%s+", { trimempty = true })) do
    if not o.source and (w == "agenda" or w == "buffer" or w == "subtree") then
      o.source = w
    elseif not o.zoom and zoom_index(w) then
      o.zoom = w
    elseif not o.source and #rest == 0 and views.is_path(w) then
      o.source = utils.expand(w)
    else
      rest[#rest + 1] = w
    end
  end
  if #rest > 0 then
    o.filter = table.concat(rest, " ")
  end
  return o
end

--- Completion of `:Org timeline`: sources, zooms and tags.
function M.complete(arglead)
  local out = views.complete_sources(arglead)
  for _, z in ipairs(M.ZOOMS) do
    out[#out + 1] = z.name
  end
  return vim.list_extend(out, views.complete_tags())
end

--- `:Org timeline [agenda|buffer|subtree|<file>] [hour|day|week|month] [filter]`.
function M.command(args)
  local o = M.parse_args(args)
  if o.filter then
    local _, err = views.compile_filter(o.filter)
    if err then
      utils.error(err)
      return
    end
  end
  return M.open(o)
end

return M
