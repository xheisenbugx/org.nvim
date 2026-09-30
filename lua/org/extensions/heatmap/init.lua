---@mod org.extensions.heatmap Calendar heatmap of clocked time
---
--- A GitHub-contribution-style calendar: one cell per day, one column per
--- week, shaded by the time clocked that day (CLOCK lines), the tasks
--- closed, or the habits done, with month and weekday labels, totals and
--- streaks.
---
--- ```lua
--- require("org").setup({ extensions = { heatmap = { weeks = 26 } } })
--- ```

local views = require("org.extensions.views_util")
local date = require("org.date")
local utils = require("org.utils")

local M = {}

local MOD = "org.extensions.heatmap"
local ns = vim.api.nvim_create_namespace("org_heatmap")
local detail_ns = vim.api.nvim_create_namespace("org_heatmap_detail")
local augroup = vim.api.nvim_create_augroup("OrgHeatmap", { clear = true })

M.KINDS = { "clock", "closed", "habit" }

local KIND_LABEL = { clock = "clocked time", closed = "tasks closed", habit = "habits done" }

M.defaults = {
  --- What is counted: "clock" (minutes clocked), "closed" (tasks marked
  --- done) or "habit" (habit completions).
  kind = "clock",
  --- Entries come from: "agenda", "buffer", "subtree", or files / globs.
  source = "agenda",
  --- Only entries with this tag (inherited tags count).
  ---@type string|nil
  tag = nil,
  --- Weeks shown, ending with the current one; 0 fits the window (at most 53).
  weeks = 0,
  --- The day cell (two columns with the gap after it).
  cell = "■",
  --- Lower bounds of shades 1 to 4 (minutes for "clock", counts
  --- otherwise); nil splits the days with any value in quartiles.
  ---@type number[]|nil
  thresholds = nil,
  --- Highlight group whose foreground is the darkest shade; the lighter
  --- ones are mixed with the background of Normal.
  color_group = "DiagnosticOk",
  --- Five colours ("#rrggbb", empty day first) to use instead.
  ---@type string[]|nil
  colors = nil,
  --- Window: "float", "tab", "split" or "current".
  layout = "float",
  --- Keys in the heatmap.
  keys = {
    next_kind = "<Tab>",
    prev_week = "h",
    next_week = "l",
    next_day = "j",
    prev_day = "k",
    agenda = "<CR>",
    refresh = "r",
    quit = { "q", "<Esc>" },
  },
}

M.actions = {
  heatmap_open = { MOD, "open", desc = "Heatmap of clocked time per day" },
}

M.commands = {
  heatmap = {
    MOD,
    "command",
    desc = "Calendar heatmap: :Org heatmap [clock|closed|habit] [tag|file]",
    complete = function(arglead, cmdline)
      return require(MOD).complete(arglead, cmdline)
    end,
  },
}

M.mappings = { global = { heatmap_open = "<prefix>Vh" } }
M.groups = { { "V", "views" } }

---@type table|nil
M.state = nil

local function opts()
  return require("org.extensions").opts("heatmap") or M.defaults
end

--- The five shade colours for the current colorscheme.
---@return table<string, table>
function M.shade_highlights()
  local o = opts()
  local out = {}
  if type(o.colors) == "table" and #o.colors >= 5 then
    for i = 0, 4 do
      out["OrgHeatmap" .. i] = { fg = o.colors[i + 1], default = false }
    end
    return out
  end
  local base = views.color(o.color_group or "DiagnosticOk", "fg") or views.color("String", "fg")
  local bg = views.color("Normal", "bg") or (vim.o.background == "light" and 0xffffff or 0x000000)
  local fg = views.color("Normal", "fg") or (vim.o.background == "light" and 0x000000 or 0xffffff)
  local cterm = { 238, 22, 28, 34, 40 }
  if not base then
    for i = 0, 4 do
      out["OrgHeatmap" .. i] = { ctermfg = cterm[i + 1], fg = nil, default = false }
    end
    out.OrgHeatmap0 = { link = "NonText", default = false }
    return out
  end
  out.OrgHeatmap0 = { fg = views.blend(bg, fg, 0.14), ctermfg = cterm[1], default = false }
  for i, t in ipairs({ 0.3, 0.52, 0.76, 1 }) do
    out["OrgHeatmap" .. i] = { fg = views.blend(bg, base, t), ctermfg = cterm[i + 1], default = false }
  end
  return out
end

function M.setup()
  views.highlights(augroup, function()
    local t = {
      OrgHeatmapTitle = { link = "Title" },
      OrgHeatmapHint = { link = "Comment" },
      OrgHeatmapLabel = { link = "Comment" },
      OrgHeatmapValue = { link = "Number" },
      OrgHeatmapDetail = { link = "Special" },
    }
    return vim.tbl_extend("force", t, M.shade_highlights())
  end)
end

function M.teardown()
  M.close()
  vim.api.nvim_clear_autocmds({ group = augroup })
end

function M.health(h)
  h.ok("heatmap: :Org heatmap [clock|closed|habit] [tag]")
end

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------

--- Days (day numbers) a headline was marked done: its CLOSED date, the
--- `- State "DONE" ... [date]` and `- CLOSING NOTE [date]` lines of its
--- log (as org-habit reads them) and its LAST_REPEAT property.
---@param hl org.Headline
---@return table<integer, true>
function M.done_days(hl)
  local out = {}
  local cfg = hl.file.settings.todo
  for i = hl.line + 1, hl.body_end or hl.line do
    local line = hl.file.lines[i]
    local kw, ts = line:match('^%s*%-%s+State%s+"([^"]+)".-(%[%d%d%d%d%-%d%d%-%d%d[^%]]*%])')
    if not (kw and cfg:is_done(kw)) then
      ts = line:match("^%s*%-%s+CLOSING NOTE%s+(%[%d%d%d%d%-%d%d%-%d%d[^%]]*%])")
    end
    local d = ts and date.parse(ts)
    if d then
      out[d:days()] = true
    end
  end
  local closed = hl.planning.closed
  if closed then
    out[closed:days()] = true
  end
  -- set when a repeating task is done (with logging or clocks)
  local lr = hl.properties.LAST_REPEAT and date.parse(hl.properties.LAST_REPEAT)
  if lr then
    out[lr:days()] = true
  end
  return out
end

--- Add a clock's minutes to the days it covers, within minutes
--- [lo, hi).
local function add_clock(values, c, now_min, lo, hi)
  local s = c.start:minutes()
  if s >= hi then
    return
  end
  local e = c["end"] and c["end"]:minutes() or now_min
  s, e = math.max(s, lo), math.min(e, hi)
  if e <= s then
    return
  end
  while s < e do
    local day = math.floor(s / 1440)
    local stop = math.min(e, (day + 1) * 1440)
    values[day] = (values[day] or 0) + (stop - s)
    s = stop
  end
end

--- Per-day values of `kind` over the headlines `hls`: `values[day]` and
--- `details[day]` (a list of `{ title, value }`, largest first), for the
--- days `first` to `last` (all days when not given).
---@param kind "clock"|"closed"|"habit"
---@param hls org.Headline[]
---@param first? integer
---@param last? integer
---@return table<integer, number> values, table<integer, table[]> details
function M.data(kind, hls, first, last)
  local values, details = {}, {}
  local now_min = date.now():minutes()
  first, last = first or -math.huge, last or math.huge
  local lo, hi = first * 1440, (last + 1) * 1440
  local first_key = -math.huge
  if first > -math.huge then
    local f = date.from_days(first)
    first_key = f.year * 10000 + f.month * 100 + f.day
  end
  local order = 0
  -- called once per headline and day (its values are summed first), so
  -- no search of the day's list: that made busy days quadratic
  local function detail(day, hl, v)
    local list = details[day]
    if not list then
      list = {}
      details[day] = list
    end
    list[#list + 1] = { hl = hl, value = v, order = order }
  end
  for i, hl in ipairs(hls) do
    order = i
    if kind == "clock" then
      local own
      for _, c in ipairs(hl.clocks) do
        -- a cheap test first: clocks that ended before the range (years of
        -- them) are left without computing day numbers
        local e = c["end"]
        if not (e and (e.year * 10000 + e.month * 100 + e.day) < first_key) then
          own = own or {}
          add_clock(own, c, now_min, lo, hi)
        end
      end
      for day, v in pairs(own or {}) do
        values[day] = (values[day] or 0) + v
        detail(day, hl, v)
      end
    elseif kind == "closed" or (kind == "habit" and require("org.agenda.habits").is_habit(hl)) then
      for day in pairs(M.done_days(hl)) do
        if day >= first and day <= last then
          values[day] = (values[day] or 0) + 1
          detail(day, hl, 1)
        end
      end
    end
  end
  -- a detail's title is made when it is shown (a few a day), not for
  -- every entry of the year
  local titles = {}
  local lazy = {
    __index = function(d, k)
      if k == "title" then
        local t = titles[d.hl] or views.title(d.hl)
        titles[d.hl] = t
        return t
      end
    end,
  }
  for _, list in pairs(details) do
    for _, d in ipairs(list) do
      setmetatable(d, lazy)
    end
    table.sort(list, function(a, b)
      if a.value ~= b.value then
        return a.value > b.value
      end
      return a.order < b.order
    end)
  end
  return values, details
end

--- Shade level (0-4) of each value: fixed `thresholds`, or quartiles of
--- the values above 0.
---@param values number[] the values of the days shown
---@param thresholds? number[]
---@return fun(v: number): integer
function M.leveler(values, thresholds)
  local bounds = thresholds
  if not bounds or #bounds < 4 then
    local list = {}
    for _, v in ipairs(values) do
      if v > 0 then
        list[#list + 1] = v
      end
    end
    table.sort(list)
    if #list == 0 then
      return function()
        return 0
      end
    end
    local function q(p)
      return list[math.max(1, math.ceil(#list * p))]
    end
    -- the upper bounds of levels 1-3
    local q1, q2, q3 = q(0.25), q(0.5), q(0.75)
    return function(v)
      if not v or v <= 0 then
        return 0
      elseif v <= q1 then
        return 1
      elseif v <= q2 then
        return 2
      elseif v <= q3 then
        return 3
      end
      return 4
    end
  end
  return function(v)
    local level = 0
    if not v or v <= 0 then
      return 0
    end
    for i = 1, 4 do
      if v >= bounds[i] then
        level = i
      end
    end
    return math.max(1, level)
  end
end

--- Totals and streaks of `values` over [first, last] (day numbers).
---@return { total: number, active: integer, best: number, best_day: integer|nil, streak: integer, longest: integer }
function M.stats(values, first, last)
  local s = { total = 0, active = 0, best = 0, streak = 0, longest = 0 }
  local run = 0
  for day = first, last do
    local v = values[day] or 0
    if v > 0 then
      s.total = s.total + v
      s.active = s.active + 1
      run = run + 1
      s.longest = math.max(s.longest, run)
      if v > s.best then
        s.best, s.best_day = v, day
      end
    else
      run = 0
    end
  end
  -- the current streak ends today, or yesterday when nothing is logged yet
  local day = last
  if (values[day] or 0) <= 0 then
    day = day - 1
  end
  while day >= first and (values[day] or 0) > 0 do
    s.streak = s.streak + 1
    day = day - 1
  end
  return s
end

local function fmt_value(kind, v)
  if kind == "clock" then
    return v > 0 and views.short_duration(v) or "0m"
  end
  local n = math.floor(v + 0.5)
  local noun = kind == "habit" and "habit" or "task"
  return n .. " " .. noun .. (n == 1 and "" or "s")
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local LABEL_W = 5

local function weeks_for(o)
  local w = tonumber(o.weeks) or 0
  if w <= 0 then
    w = math.floor((vim.o.columns - 6 - LABEL_W - 4) / 2)
  end
  return math.max(4, math.min(53, w))
end

--- Size of the float for the drawn heatmap.
local function float_size(st)
  return { width = math.min(vim.o.columns - 4, math.max(st.width + 2, 60)), height = st.height }
end

--- The first and last day shown (Monday of the first week, today).
function M.range(weeks, today)
  local wd = date.from_days(today):weekday()
  local monday = today - (wd - 1)
  return monday - (weeks - 1) * 7, today
end

local function hint(o)
  local k = o.keys or {}
  local function key(name)
    local v = k[name]
    return type(v) == "table" and v[1] or v
  end
  local parts = {}
  for _, p in ipairs({
    { "next_kind", nil, "kind" },
    { "prev_week", "next_week", "week" },
    { "next_day", "prev_day", "day" },
    { "agenda", nil, "agenda" },
    { "refresh", nil, "refresh" },
    { "quit", nil, "quit" },
  }) do
    local a, b = key(p[1]), p[2] and key(p[2])
    if a then
      parts[#parts + 1] = (b and (a .. "/" .. b) or a) .. " " .. p[3]
    end
  end
  return table.concat(parts, "  ")
end

--- Draw the heatmap.
function M.render(st)
  if not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  local o = st.opts
  local today = date.today_days()
  local files = views.files(st.src)
  st.file_set = views.file_set(files)
  st.key = views.files_key(files)
  local hls, err = views.collect(st.src, { tag = st.tag, files = files })
  local first, last = M.range(st.weeks, today)
  st.first, st.last = first, last
  local values, details = M.data(st.kind, hls, first, last)
  st.values, st.details = values, details
  local shown = {}
  for day = first, last do
    shown[#shown + 1] = values[day] or 0
  end
  local level = M.leveler(shown, o.thresholds)
  local cellc = o.cell or "■"

  local cv = views.Canvas.new()
  cv:add({ { " Heatmap", "OrgHeatmapTitle" }, { "  " .. KIND_LABEL[st.kind], "OrgHeatmapValue" } })
  cv:put("  · " .. views.source_label(st.src), "OrgHeatmapHint")
  if st.tag then
    cv:put("  · tag " .. st.tag, "OrgHeatmapHint")
  end
  if err then
    cv:put("  " .. err, "DiagnosticError")
  end
  cv:add({ { " " .. hint(o), "OrgHeatmapHint" } })
  cv:add("")
  -- month labels over the week where a month starts
  local months = string.rep(" ", st.weeks * 2)
  local chars = vim.split(months, "")
  local last_m, next_free = nil, 1
  for w = 0, st.weeks - 1 do
    local monday = date.from_days(first + w * 7)
    local key = monday.year * 12 + monday.month
    if key ~= last_m then
      local pos = w * 2 + 1
      local label = date.MONTH_NAMES[monday.month]
      if pos >= next_free and pos + #label - 1 <= #chars then
        for k = 1, #label do
          chars[pos + k - 1] = label:sub(k, k)
        end
        next_free = pos + #label + 1
      end
      last_m = key
    end
  end
  cv:add({ { string.rep(" ", LABEL_W) }, { table.concat(chars), "OrgHeatmapLabel" } })
  st.grid_top = #cv.lines + 1
  local day_labels = { "Mon", "", "Wed", "", "Fri", "", "Sun" }
  for wd = 1, 7 do
    cv:line()
    cv:put(utils.pad_right(" " .. day_labels[wd], LABEL_W), "OrgHeatmapLabel")
    for w = 0, st.weeks - 1 do
      local day = first + w * 7 + wd - 1
      if day > last then
        cv:put("  ")
      else
        cv:put(cellc, "OrgHeatmap" .. level(values[day]))
        cv:put(" ")
      end
    end
  end
  -- legend
  cv:line()
  local legend_w = st.weeks * 2 + LABEL_W
  local legend = { { "Less ", "OrgHeatmapLabel" } }
  for i = 0, 4 do
    legend[#legend + 1] = { cellc, "OrgHeatmap" .. i }
    legend[#legend + 1] = { " " }
  end
  legend[#legend + 1] = { "More", "OrgHeatmapLabel" }
  local lw = 5 + 10 + 4
  cv:put(string.rep(" ", math.max(0, legend_w - lw)))
  for _, s in ipairs(legend) do
    cv:put(s[1], s[2])
  end
  -- stats
  local s = M.stats(values, first, last)
  cv:add("")
  local stat = {
    { " Total ", "OrgHeatmapLabel" },
    { fmt_value(st.kind, s.total), "OrgHeatmapValue" },
    { "  ·  ", "OrgHeatmapLabel" },
    { tostring(s.active), "OrgHeatmapValue" },
    { " active days", "OrgHeatmapLabel" },
  }
  if s.active > 0 then
    vim.list_extend(stat, {
      { "  ·  avg ", "OrgHeatmapLabel" },
      {
        st.kind == "clock" and fmt_value("clock", s.total / s.active) or string.format("%.1f", s.total / s.active),
        "OrgHeatmapValue",
      },
      { " a day", "OrgHeatmapLabel" },
    })
  end
  cv:add(stat)
  local stat2 = {
    { " Streak ", "OrgHeatmapLabel" },
    { s.streak .. (s.streak == 1 and " day" or " days"), "OrgHeatmapValue" },
    { "  ·  longest ", "OrgHeatmapLabel" },
    { s.longest .. (s.longest == 1 and " day" or " days"), "OrgHeatmapValue" },
  }
  if s.best_day then
    vim.list_extend(stat2, {
      { "  ·  best ", "OrgHeatmapLabel" },
      { fmt_value(st.kind, s.best), "OrgHeatmapValue" },
      { " on " .. date.from_days(s.best_day):strftime("%a %b %d"), "OrgHeatmapLabel" },
    })
  end
  cv:add(stat2)
  cv:add("")
  st.detail_line = cv:line()
  st.stats = s
  cv:draw(st.buf, ns)
  st.width = 0
  for _, l in ipairs(cv:strings()) do
    st.width = math.max(st.width, utils.width(l))
  end
  st.height = #cv.lines
end

--- Grid position (line, virtual column) of a day.
local function pos_of(st, day)
  local off = day - st.first
  local w, wd = math.floor(off / 7), off % 7
  return st.grid_top + wd, LABEL_W + w * 2 + 1
end

--- The day at a grid position, or nil.
function M.day_at(st, lnum, vcol)
  local wd = lnum - st.grid_top
  if wd < 0 or wd > 6 or vcol <= LABEL_W then
    return nil
  end
  local w = math.floor((vcol - LABEL_W - 1) / 2)
  if w < 0 or w >= st.weeks then
    return nil
  end
  local day = st.first + w * 7 + wd
  if day > st.last then
    return nil
  end
  return day
end

--- Show the selected day's value and its biggest entries.
local function show_detail(st)
  if not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(st.buf, detail_ns, 0, -1)
  local day = st.day
  if not day then
    return
  end
  local v = st.values[day] or 0
  local chunks = {
    { " ▸ " .. date.from_days(day):strftime("%a %Y-%m-%d") .. "  ", "OrgHeatmapDetail" },
    { fmt_value(st.kind, v), "OrgHeatmapValue" },
  }
  local list = st.details[day] or {}
  for i = 1, math.min(3, #list) do
    local d = list[i]
    local val = st.kind == "clock" and (" " .. views.short_duration(d.value)) or ""
    chunks[#chunks + 1] = { (i == 1 and "  ·  " or ", ") .. utils.truncate(d.title, 28) .. val, "OrgHeatmapLabel" }
  end
  if #list > 3 then
    chunks[#chunks + 1] = { string.format(", +%d more", #list - 3), "OrgHeatmapLabel" }
  end
  vim.api.nvim_buf_set_extmark(
    st.buf,
    detail_ns,
    st.detail_line - 1,
    0,
    { virt_text = chunks, virt_text_pos = "overlay" }
  )
end

local function place(st)
  if not (st.win and vim.api.nvim_win_is_valid(st.win)) or not st.day then
    return
  end
  local lnum, vcol = pos_of(st, st.day)
  local col = vim.fn.virtcol2col(st.win, lnum, vcol)
  st.placing = true
  pcall(vim.api.nvim_win_set_cursor, st.win, { lnum, math.max(0, col - 1) })
  st.placing = false
  show_detail(st)
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

--- Redraw. With `lazy` (the redraw watch), nothing happens while the
--- heatmap's files are unchanged.
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
  place(st)
end

--- Move the selected day by `n` days.
function M.move(n)
  local st = current()
  if not st then
    return
  end
  st.day = math.max(st.first, math.min(st.last, (st.day or st.last) + n))
  place(st)
end

--- Show the next kind of data (clock, closed, habit).
function M.next_kind()
  local st = current()
  if not st then
    return
  end
  local i = 1
  for k, name in ipairs(M.KINDS) do
    if name == st.kind then
      i = k
    end
  end
  st.kind = M.KINDS[i % #M.KINDS + 1]
  M.refresh()
end

--- Open the agenda for the selected day.
function M.agenda()
  local st = current()
  if not st or not st.day then
    return
  end
  local day = st.day
  if st.how.layout ~= "split" and st.how.layout ~= "vsplit" then
    M.close()
  end
  require("org.agenda").open_day(day)
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

--- Open the heatmap.
---@param o? { kind?: string, tag?: string, source?: any }
function M.open(o)
  o = type(o) == "table" and o or {}
  local eopts = vim.deepcopy(opts())
  local src, err = views.resolve_source(o.source or eopts.source)
  if not src then
    utils.error("heatmap: " .. err)
    return
  end
  local kind = o.kind or eopts.kind
  if not vim.tbl_contains(M.KINDS, kind) then
    utils.error("heatmap: unknown kind " .. tostring(kind))
    return
  end
  M.close()
  local buf = views.scratch("org://heatmap", "orgheatmap")
  local st = {
    buf = buf,
    src = src,
    opts = eopts,
    kind = kind,
    tag = o.tag or eopts.tag,
    weeks = weeks_for(eopts),
  }
  M.state = st
  -- draw first: the float is sized to the content
  M.render(st)
  local size = float_size(st)
  st.win, st.how = views.open(buf, eopts.layout, { width = size.width, height = size.height, title = "Heatmap" })
  st.day = date.today_days()
  views.map(buf, eopts.keys, {
    next_kind = M.next_kind,
    prev_week = function()
      M.move(-7)
    end,
    next_week = function()
      M.move(7)
    end,
    next_day = function()
      M.move(1)
    end,
    prev_day = function()
      M.move(-1)
    end,
    agenda = M.agenda,
    refresh = function()
      M.refresh()
    end,
    quit = M.close,
  }, "heatmap")
  st.watch = views.watch("OrgHeatmapWatch", function()
    if current() == st then
      M.refresh(true)
    end
  end, { buf = buf, relevant = views.relevant(st) })
  vim.api.nvim_create_autocmd("VimResized", {
    group = st.watch,
    callback = function()
      if current() ~= st then
        return
      end
      -- weeks = 0 fits the window: fewer or more weeks, then a new size
      local weeks = weeks_for(st.opts)
      if weeks ~= st.weeks then
        st.weeks = weeks
        pcall(M.render, st)
      end
      views.relayout(st.how, float_size(st))
      place(st)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = st.watch,
    buffer = buf,
    callback = function()
      if st.placing then
        return
      end
      local day = M.day_at(st, vim.api.nvim_win_get_cursor(0)[1], vim.fn.virtcol("."))
      if day and day ~= st.day then
        st.day = day
        show_detail(st)
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
  place(st)
  return st
end

--- Parse `:Org heatmap` arguments: a kind, then a tag or a file.
function M.parse_args(args)
  local o = {}
  for _, w in ipairs(vim.split(vim.trim(args or ""), "%s+", { trimempty = true })) do
    if vim.tbl_contains(M.KINDS, w) then
      o.kind = w
    elseif w == "agenda" or w == "buffer" or w == "subtree" then
      o.source = w
    elseif views.is_path(w) then
      o.source = utils.expand(w)
    else
      o.tag = (w:gsub("^[+:]", ""):gsub(":$", ""))
    end
  end
  return o
end

--- Completion of `:Org heatmap`: kinds, sources and tags.
function M.complete(arglead)
  local out = vim.list_extend(vim.deepcopy(M.KINDS), views.complete_sources(arglead))
  return vim.list_extend(out, views.complete_tags())
end

--- `:Org heatmap [clock|closed|habit] [tag|file]`.
function M.command(args)
  return M.open(M.parse_args(args))
end

return M
