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
  { name = "day", days = 1, width = 3 },
  { name = "week", days = 1, width = 1 },
  { name = "month", days = 7, width = 1 },
}

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
  --- Starting zoom: "day" (3 columns a day), "week" (a column a day) or
  --- "month" (a column a week).
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
    quit = { "q", "<Esc>" },
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
    desc = "Timeline: :Org timeline [agenda|buffer|subtree|<file>] [day|week|month] [filter]",
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
    OrgTimelineClock = { link = "DiagnosticHint" },
    OrgTimelineToday = { link = "CursorLine" },
    OrgTimelineTodayLabel = { link = "Search" },
    OrgTimelineWeekend = { link = "ColorColumn" },
    OrgTimelineTask = { link = "Normal" },
  })
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

--- The row of a headline: `{ start, finish, deadline, overdue, done, ... }`
--- (day numbers), or nil when it has no date to show.
---@param hl org.Headline
---@param o table options
---@param today integer
---@param clocks boolean
function M.task(hl, o, today, clocks)
  local s = hl.planning.scheduled and hl.planning.scheduled:days()
  local d = hl.planning.deadline and hl.planning.deadline:days()
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
  local start, finish
  if s and d then
    start, finish = math.min(s, d), math.max(s, d)
  elseif s then
    start, finish = s, s + (ed or 1) - 1
  elseif d then
    start, finish = d - (ed or 1) + 1, d
  end
  local cmin, cmax
  for day in pairs(clock_days or {}) do
    cmin = math.min(cmin or day, day)
    cmax = math.max(cmax or day, day)
  end
  return {
    ref = views.ref(hl),
    todo = hl.todo,
    title = views.title(hl),
    start = start,
    finish = finish,
    scheduled = s,
    deadline = d,
    effort = effort,
    done = done,
    overdue = not done and d ~= nil and d < today,
    clock_days = clock_days,
    first = start or cmin,
    last = finish or cmax,
  }
end

--- The rows of the timeline, sorted by start day.
---@param st table
---@return table[] rows, string|nil err
function M.build(st)
  local o = st.opts
  local today = date.today_days()
  local hls, err = views.collect(st.src, {
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
  table.sort(rows, function(a, b)
    if a.first ~= b.first then
      return a.first < b.first
    end
    if a.last ~= b.last then
      return a.last < b.last
    end
    return a.order < b.order
  end)
  return rows, err
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local HEADER_LINES = 2

local function zoom(st)
  return M.ZOOMS[st.zoom]
end

--- Number of cells that fit in the chart area.
local function cell_count(st)
  local win = st.win and vim.api.nvim_win_is_valid(st.win) and st.win or nil
  local width = (win and vim.api.nvim_win_get_width(win) or vim.o.columns) - st.opts.label_width - 3
  return math.max(4, math.floor(width / zoom(st).width))
end

--- First and last day of cell `i` (0-based).
local function cell_days(st, i)
  local z = zoom(st)
  local a = st.start + i * z.days
  return a, a + z.days - 1
end

local function has_day(set, a, b)
  if not set then
    return false
  end
  for d = a, b do
    if set[d] then
      return true
    end
  end
  return false
end

--- The text and highlight of a task's cell.
local function cell(st, row, i, today)
  local z = zoom(st)
  local w = z.width
  local a, b = cell_days(st, i)
  local on_bar = row.start and row.start <= b and row.finish >= a
  local is_dl = row.deadline and row.deadline >= a and row.deadline <= b
  local is_today = today >= a and today <= b
  local weekend = z.days == 1 and w > 1 and date.from_days(a):weekday() >= 6
  local bar_hl = row.done and "OrgTimelineDone" or (row.overdue and "OrgTimelineOverdue" or "OrgTimelineBar")
  local text, hl
  if is_dl then
    local dl_hl = row.done and "OrgTimelineDone" or (row.overdue and "OrgTimelineOverdue" or "OrgTimelineDeadline")
    if w == 1 then
      text = "◆"
    else
      local left = (row.start and row.start < a) and string.rep("█", math.floor((w - 1) / 2))
        or string.rep(" ", math.floor((w - 1) / 2))
      text = left .. "◆" .. string.rep(" ", w - 1 - math.floor((w - 1) / 2))
    end
    hl = dl_hl
  elseif on_bar then
    text, hl = string.rep("█", w), bar_hl
  elseif row.overdue and a > row.deadline and a <= today then
    -- how late it is: a dashed trail from the deadline to today
    text, hl = string.rep("┄", w), "OrgTimelineOverdue"
  elseif has_day(row.clock_days, a, b) then
    text, hl = string.rep("▒", w), "OrgTimelineClock"
  else
    text = string.rep(" ", w)
  end
  local groups = {}
  if weekend then
    groups[#groups + 1] = "OrgTimelineWeekend"
  end
  if is_today then
    groups[#groups + 1] = "OrgTimelineToday"
  end
  if hl then
    groups[#groups + 1] = hl
  end
  return text, #groups > 0 and groups or nil
end

--- The axis lines: months, then day numbers (and weekdays at day zoom).
local function axis(st, n, today)
  local z = zoom(st)
  local w = z.width
  local total = n * w
  local months = vim.split(string.rep(" ", total), "")
  local days = vim.split(string.rep(" ", total), "")
  local wdays = z.name == "day" and vim.split(string.rep(" ", total), "") or nil
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
    if z.name == "day" then
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
    local v = k[name]
    return type(v) == "table" and v[1] or v
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

--- Draw the timeline.
function M.render(st)
  if not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  local o = st.opts
  local today = date.today_days()
  local rows, err = M.build(st)
  st.rows = rows
  local n = cell_count(st)
  st.cells = n
  local z = zoom(st)
  local lw = o.label_width
  local cv = views.Canvas.new()
  local first, last = date.from_days(st.start), date.from_days(select(2, cell_days(st, n - 1)))
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
  if st.filter or st.tag then
    cv:put("  · " .. (st.filter or ("tag " .. st.tag)), "OrgTimelineHint")
  end
  if err then
    cv:put("  " .. err, "DiagnosticError")
  end
  cv:add({ { " " .. hint(o), "OrgTimelineHint" } })
  local ax, today_pos = axis(st, n, today)
  for li, text in ipairs(ax) do
    cv:line()
    cv:put(string.rep(" ", lw + 1))
    cv:put("│", "OrgTimelineSeparator")
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
    { string.rep("─", lw + 1), "OrgTimelineSeparator" },
    { "┼", "OrgTimelineSeparator" },
    { string.rep("─", n * z.width), "OrgTimelineSeparator" },
  })
  st.first_row_line = #cv.lines + 1
  st.line_rows = {}
  local todo_cfg = require("org.todo_keywords").global()
  for _, row in ipairs(rows) do
    local lnum = cv:line()
    st.line_rows[lnum] = row
    cv:put(" ")
    local used = 1
    if row.todo then
      cv:put(row.todo, views.todo_group(row.todo, todo_cfg))
      cv:put(" ")
      used = used + utils.width(row.todo) + 1
    end
    local title_hl = row.done and "OrgTimelineDone" or (row.overdue and "OrgTimelineOverdue" or "OrgTimelineTask")
    cv:put(views.fit(row.title, lw - used + 1), title_hl)
    cv:put("│", "OrgTimelineSeparator")
    for i = 0, n - 1 do
      local text, hl = cell(st, row, i, today)
      cv:put(text, hl)
    end
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

function M.refresh()
  local st = current()
  if st then
    M.render(st)
  end
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

--- Zoom in (`dir` = -1) or out (1), keeping the middle day in place.
function M.zoom(dir)
  local st = current()
  if not st then
    return
  end
  local nz = math.max(1, math.min(#M.ZOOMS, st.zoom + dir))
  if nz == st.zoom then
    return
  end
  local mid = st.start + math.floor(st.cells / 2) * zoom(st).days
  st.zoom = nz
  local n = cell_count(st)
  st.start = start_for(st, mid, math.floor(n / 2))
  M.render(st)
end

--- Pan by half a screen: `dir` = -1 to the past, 1 to the future.
function M.pan(dir)
  local st = current()
  if not st then
    return
  end
  st.start = st.start + dir * math.max(1, math.floor(st.cells / 2)) * zoom(st).days
  M.render(st)
end

function M.goto_today()
  local st = current()
  if not st then
    return
  end
  st.start = start_for(st, date.today_days(), st.opts.days_before or 3)
  M.render(st)
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
    zoom = zoom_index(o.zoom or eopts.zoom) or 1,
  }
  M.state = st
  st.win, st.how = views.open(buf, eopts.layout, { width = eopts.width, height = eopts.height, title = "Timeline" })
  vim.wo[st.win].cursorline = true
  st.start = start_for(st, date.today_days(), eopts.days_before or 3)
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
    refresh = M.refresh,
    quit = M.close,
  }, "timeline")
  st.watch = views.watch("OrgTimelineWatch", function()
    if current() == st then
      M.render(st)
    end
  end)
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = st.watch,
    callback = function()
      if current() == st then
        M.render(st)
      end
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
    elseif not o.source and #rest == 0 and (w:match("%.org$") or w:find("/", 1, true)) and not w:match("^%(") then
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

--- `:Org timeline [agenda|buffer|subtree|<file>] [day|week|month] [filter]`.
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
