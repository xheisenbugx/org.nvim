---@mod org.agenda.render Turning agenda blocks into buffer lines
---
--- Rendering is a pure function of (view, state, width): it returns lines,
--- highlight ranges and a line -> item map. The buffer side lives in
--- `org.agenda.view`.

local config = require("org.config")
local date = require("org.date")
local habits = require("org.agenda.habits")
local items_mod = require("org.agenda.items")
local utils = require("org.utils")

local M = {}

---------------------------------------------------------------------------
-- Line builder
---------------------------------------------------------------------------

local Builder = {}
Builder.__index = Builder

function M.builder()
  return setmetatable({ lines = {}, hls = {}, items = {}, line_hls = {}, blocks = {} }, Builder)
end

--- Add a line made of parts { text, group? }.
function Builder:add(parts, item, line_hl)
  local text = {}
  local len = 0
  local row = #self.lines
  for _, p in ipairs(parts) do
    local s = p[1] or ""
    if p[2] and #s > 0 then
      self.hls[#self.hls + 1] = { row, len, len + #s, p[2] }
    end
    text[#text + 1] = s
    len = len + #s
  end
  self.lines[#self.lines + 1] = table.concat(text)
  if item then
    self.items[#self.lines] = item
  end
  if line_hl then
    self.line_hls[#self.lines] = line_hl
  end
  return #self.lines
end

function Builder:text(s, group)
  return self:add({ { s, group } })
end

---------------------------------------------------------------------------
-- Dates
---------------------------------------------------------------------------

--- ISO 8601 week number for a day number.
function M.iso_week(days)
  local wd = (days + 3) % 7 + 1
  local thu = days - (wd - 1) + 3
  local y = date.civil_from_days(thu)
  local jan1 = date.days_from_civil(y, 1, 1)
  return math.floor((thu - jan1) / 7) + 1, y
end

--- "Wednesday  23 September 2026 W39"
function M.date_header(days, show_week)
  local d = date.from_days(days)
  local wk = show_week and string.format(" W%02d", (M.iso_week(days))) or ""
  return string.format(
    "%-10s %2d %s %4d%s",
    date.DAY_NAMES_LONG[d:weekday()],
    d.day,
    date.MONTH_NAMES_LONG[d.month],
    d.year,
    wk
  )
end

local function span_days(span)
  if span == "day" then
    return 1
  elseif span == "week" then
    return 7
  elseif span == "fortnight" then
    return 14
  end
  return tonumber(span)
end

--- Compute the [from, to] day range for a span anchored on `anchor`.
---@param span string|integer
---@param anchor integer day number
---@param align boolean align weeks to start_on_weekday
function M.range(span, anchor, align)
  local acfg = config.opts.agenda
  local a = date.from_days(anchor)
  if span == "month" then
    local first = date.Date.new({ year = a.year, month = a.month, day = 1 })
    return first:days(), first:days() + date.days_in_month(a.year, a.month) - 1
  elseif span == "year" then
    local first = date.Date.new({ year = a.year, month = 1, day = 1 })
    return first:days(), first:days() + (date.is_leap(a.year) and 365 or 364)
  end
  local n = span_days(span) or 7
  local start = anchor
  if align and (span == "week" or span == "fortnight") and acfg.start_on_weekday then
    start = anchor - ((a:weekday() - acfg.start_on_weekday) % 7)
  end
  return start, start + n - 1
end

--- Move an anchor by `n` spans.
function M.shift_anchor(span, anchor, n)
  if span == "month" then
    return date.from_days(anchor):add(n, "m"):days()
  elseif span == "year" then
    return date.from_days(anchor):add(n, "y"):days()
  end
  return anchor + (span_days(span) or 7) * n
end

local function span_name(span)
  local names = { day = "Day", week = "Week", fortnight = "Fortnight", month = "Month", year = "Year" }
  return names[span] or (tostring(span) .. "-days")
end

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------

local function fmt_min(m)
  return string.format("%2d:%02d", math.floor(m / 60), m % 60)
end

local function display_title(title)
  local t = title:gsub("%[%[([^%]]-)%]%[([^%]]-)%]%]", "%2")
  t = t:gsub("%[%[([^%]]-)%]%]", "%1")
  return t
end
M.display_title = display_title

--- Build the parts for an item line.
---@param item org.AgendaItem
---@param ctx { agenda?: boolean, width: integer, today: integer }
function M.item_parts(item, ctx)
  local acfg = config.opts.agenda
  local parts = {}
  local width = 0
  local function push(s, group)
    parts[#parts + 1] = { s, group }
    width = width + utils.width(s)
  end
  push("  ")
  push(utils.pad_right(utils.truncate(item.category or "", 11) .. ":", 12) .. " ", "OrgAgendaCategory")
  if ctx.agenda then
    if item.time then
      local t = fmt_min(item.time) .. (item.end_time and ("-" .. fmt_min(item.end_time)) or "......")
      push(utils.pad_right(t, 12))
    end
    if item.extra and item.extra ~= "" then
      push(item.extra, item.face ~= "OrgAgendaTimestamp" and item.face or nil)
    end
  end
  if item.todo then
    push(item.todo, item.done and "OrgAgendaDoneKeyword" or "OrgAgendaTodoKeyword")
    push(" ")
  end
  if item.priority then
    push("[#" .. item.priority .. "]", "OrgAgendaPriority")
    push(" ")
  end
  push(display_title(item.title), item.face)

  if item.habit then
    local gc = (acfg.habits or {}).graph_column or 50
    if width < gc then
      push(string.rep(" ", gc - width))
    else
      push(" ")
    end
    for _, g in ipairs(habits.graph(item.habit, ctx.today)) do
      push(g[1], g[2])
    end
  end

  if acfg.remove_tags ~= true then
    local tags = acfg.show_inherited_tags == false and item.headline.tags or item.tags
    if tags and #tags > 0 then
      local tagstr = ":" .. table.concat(tags, ":") .. ":"
      local pad = (ctx.width - 1) - width - utils.width(tagstr)
      push(string.rep(" ", math.max(pad, 1)))
      push(tagstr, "OrgAgendaTag")
    end
  end
  return parts
end

--- Body text of an entry for org-agenda-entry-text-mode: drawers, planning
--- and properties removed, common indentation stripped.
---@param hl org.Headline
---@param max integer maximum number of lines
---@return string[]
function M.entry_text(hl, max)
  local body = hl:body_lines()
  local out = {}
  local in_drawer = false
  for _, l in ipairs(body) do
    if in_drawer then
      if l:match("^%s*:END:%s*$") then
        in_drawer = false
      end
    elseif l:match("^%s*:[%w_%-]+:%s*$") then
      in_drawer = true
    elseif not l:match("^%s*CLOCK:") then
      out[#out + 1] = l
    end
  end
  while #out > 0 and vim.trim(out[1]) == "" do
    table.remove(out, 1)
  end
  while #out > 0 and vim.trim(out[#out]) == "" do
    table.remove(out)
  end
  local indent
  for _, l in ipairs(out) do
    if vim.trim(l) ~= "" then
      local n = #l:match("^(%s*)")
      indent = indent and math.min(indent, n) or n
    end
  end
  local res = {}
  for i = 1, math.min(#out, max) do
    res[i] = out[i]:sub((indent or 0) + 1)
  end
  if #out > max then
    res[#res + 1] = "..."
  end
  return res
end

--- Add an item line (plus its entry text in entry-text mode).
function M.add_item(b, it, ctx)
  b:add(M.item_parts(it, ctx), it, ctx.is_clocking and ctx.is_clocking(it) and "OrgAgendaClocking" or nil)
  if ctx.entry_text and it.headline then
    local max = config.opts.agenda.entry_text_maxlines or 5
    for _, l in ipairs(M.entry_text(it.headline, max)) do
      b:text("    > " .. l, "OrgAgendaEntryText")
    end
  end
end

---------------------------------------------------------------------------
-- Blocks
---------------------------------------------------------------------------

local function grid_minutes(t)
  return math.floor(t / 100) * 60 + t % 100
end

local function show_grid(grid, d, today, span, has_timed)
  if not grid or grid.enabled == false or grid.hidden then
    return false
  end
  local types = grid.type or { "daily", "today", "require-timed" }
  local set = {}
  for _, t in ipairs(types) do
    set[t] = true
  end
  if set["require-timed"] and not has_timed then
    return false
  end
  return (set.daily and span == "day") or (set.weekly and span ~= "day") or (set.today and d == today)
end

--- Render the item list of one day, with time grid.
local function render_day(b, list, d, ctx)
  local acfg = config.opts.agenda
  local grid = acfg.time_grid
  local has_timed = false
  for _, it in ipairs(list) do
    if it.time then
      has_timed = true
      break
    end
  end
  local rows = {}
  if not ctx.time_grid_off and show_grid(grid, d, ctx.today, ctx.span, has_timed) then
    local timed, untimed = {}, {}
    local occupied = {}
    for _, it in ipairs(list) do
      if it.time then
        timed[#timed + 1] = { min = it.time, kind = 1, item = it }
        occupied[it.time] = true
      else
        untimed[#untimed + 1] = it
      end
    end
    for _, t in ipairs(grid.times or {}) do
      local m = grid_minutes(t)
      if not occupied[m] then
        timed[#timed + 1] = { min = m, kind = 0 }
      end
    end
    if d == ctx.today and ctx.now then
      timed[#timed + 1] = { min = ctx.now, kind = 2 }
    end
    for i, e in ipairs(timed) do
      e.idx = i
    end
    table.sort(timed, function(a, c)
      if a.min ~= c.min then
        return a.min < c.min
      end
      if a.kind ~= c.kind then
        return a.kind < c.kind
      end
      return a.idx < c.idx
    end)
    for _, e in ipairs(timed) do
      rows[#rows + 1] = e
    end
    for _, it in ipairs(untimed) do
      rows[#rows + 1] = { kind = 1, item = it }
    end
  else
    for _, it in ipairs(list) do
      rows[#rows + 1] = { kind = 1, item = it }
    end
  end
  local pad = "  " .. string.rep(" ", 12) .. " "
  for _, r in ipairs(rows) do
    if r.kind == 0 then
      b:add({
        { pad },
        { fmt_min(r.min) .. " " .. (grid.separator or "......") .. " " .. (grid.time_string or ""), "OrgAgendaTimeGrid" },
      })
    elseif r.kind == 2 then
      b:add({ { pad }, { fmt_min(r.min) .. " " .. (acfg.current_time_string or "now"), "OrgAgendaCurrentTime" } })
    else
      M.add_item(b, r.item, ctx)
    end
  end
end

local function filter_list(list, ctx)
  if not ctx.filter then
    return list
  end
  local out = {}
  for _, it in ipairs(list) do
    if ctx.filter(it) then
      out[#out + 1] = it
    end
  end
  return out
end

--- Clock summary for the span (org-agenda-clockreport-mode).
function M.clock_report(b, files, from, to)
  local from_min, to_min = from * 1440, (to + 1) * 1440
  local maxlevel = ((config.opts.clock or {}).clocktable_default or {}).maxlevel or 3
  local rows = {}
  local total = 0
  for _, file in ipairs(files) do
    local file_rows, file_total = {}, 0
    local function walk(hl)
      local m = hl:clocked_minutes(from_min, to_min, true)
      if m > 0 and hl.level <= maxlevel then
        local indent = hl.level > 1 and ("\\_" .. string.rep("  ", hl.level - 2) .. " ") or ""
        file_rows[#file_rows + 1] = { "", indent .. hl:plain_title(), date.format_duration(m) }
        for _, c in ipairs(hl.children) do
          walk(c)
        end
      end
    end
    for _, hl in ipairs(file.children) do
      if not hl:is_hidden_by_ancestor() then
        file_total = file_total + hl:clocked_minutes(from_min, to_min, true)
        walk(hl)
      end
    end
    if file_total > 0 then
      rows[#rows + 1] = "hline"
      rows[#rows + 1] = {
        vim.fn.fnamemodify(file.filename or "buffer", ":t"),
        "*File time*",
        "*" .. date.format_duration(file_total) .. "*",
      }
      vim.list_extend(rows, file_rows)
      total = total + file_total
    end
  end
  b:text("")
  b:text(
    string.format(
      "Clock summary report: [%s]--[%s]",
      date.from_days(from):to_date_string(),
      date.from_days(to):to_date_string()
    ),
    "OrgAgendaHeader"
  )
  local all = {
    { "File", "Headline", "Time" },
    "hline",
    { "", "ALL *Total time*", "*" .. date.format_duration(total) .. "*" },
  }
  vim.list_extend(all, rows)
  local w = { 0, 0, 0 }
  for _, r in ipairs(all) do
    if type(r) == "table" then
      for i = 1, 3 do
        w[i] = math.max(w[i], utils.width(r[i]))
      end
    end
  end
  for _, r in ipairs(all) do
    if r == "hline" then
      b:text("|" .. string.rep("-", w[1] + 2) .. "+" .. string.rep("-", w[2] + 2) .. "+" .. string.rep("-", w[3] + 2) .. "|")
    else
      b:text(string.format(
        "| %s | %s | %s |",
        utils.pad_right(r[1], w[1]),
        utils.pad_right(r[2], w[2]),
        utils.pad_left(r[3], w[3])
      ))
    end
  end
end

--- Render an agenda (date range) block.
---@param block table
---@param ctx table { files, span, anchor, align, today, now, width, log_mode, clockreport, restrict, filter, is_clocking }
function M.agenda_block(b, block, ctx)
  local acfg = config.opts.agenda
  local span = ctx.span or block.span or acfg.span or "week"
  local from, to = M.range(span, ctx.anchor, ctx.align)
  local by_day = items_mod.agenda(ctx.files, from, to, {
    today = ctx.today,
    log_mode = ctx.log_mode,
    inactive = ctx.inactive,
    archives = ctx.archives,
    restrict = ctx.restrict,
    skip = block.skip,
    block = block,
  })
  local header = block.header
  if not header then
    local w1, w2 = M.iso_week(from), M.iso_week(to)
    local wk = w1 == w2 and string.format("W%02d", w1) or string.format("W%02d-W%02d", w1, w2)
    header = string.format("%s-agenda (%s):", span_name(span), wk)
  end
  b:text(header, "OrgAgendaHeader")
  local sorting = block.sorting or (acfg.sorting or {}).agenda or { "time-up", "priority-down", "category-keep" }
  local dctx = vim.tbl_extend("force", ctx, { agenda = true, span = span })
  for d = from, to do
    local wd = (d + 3) % 7 + 1
    local group = "OrgAgendaDate"
    if d == ctx.today then
      group = "OrgAgendaDateToday"
    elseif wd >= 6 then
      group = "OrgAgendaDateWeekend"
    end
    b:add({ { M.date_header(d, wd == 1 or d == from), group } }, nil)
    b.day_lines = b.day_lines or {}
    b.day_lines[#b.lines] = d
    local list = filter_list(by_day[d] or {}, ctx)
    items_mod.sort(list, sorting)
    render_day(b, list, d, dctx)
  end
  if ctx.clockreport then
    M.clock_report(b, ctx.files, from, to)
  end
  return { from = from, to = to, span = span }
end

--- Render a list block (todo / tags / search / stuck).
function M.list_block(b, block, ctx)
  local acfg = config.opts.agenda
  local t = block.type
  local list, header, sorting
  local hint
  local lopts = { restrict = ctx.restrict, skip = block.skip, block = block, archives = ctx.archives }
  if t == "todo" then
    local kws = block.keywords
    if type(kws) == "string" then
      kws = vim.split(kws, "[|%s]+", { trimempty = true })
    end
    if not kws and block.match and block.match ~= "" then
      kws = vim.split(block.match, "[|%s]+", { trimempty = true })
    end
    list = items_mod.todo(ctx.files, kws, lopts)
    header = block.header
      or ("Global list of TODO items of type: " .. ((kws and #kws > 0) and table.concat(kws, "|") or "ALL"))
    local names = {}
    for i, n in ipairs(ctx.todo_names or {}) do
      names[#names + 1] = string.format("(%d)%s", i, n)
    end
    hint = "Available with `N r': (0)[ALL] " .. table.concat(names, " ")
    sorting = block.sorting or (acfg.sorting or {}).todo
  elseif t == "tags" or t == "tags_todo" then
    local pred, err = require("org.agenda.search").try_compile(block.match or "")
    if not pred then
      b:text("Invalid match: " .. tostring(err), "ErrorMsg")
      return
    end
    list = items_mod.tags(ctx.files, pred, t == "tags_todo", lopts)
    header = block.header or ("Headlines with TAGS match: " .. (block.match or ""))
    sorting = block.sorting or (acfg.sorting or {}).tags
  elseif t == "search" then
    local pred = require("org.agenda.search").compile_text(block.match or "")
    list = items_mod.search(ctx.files, pred, lopts)
    header = block.header or ("Search words: " .. (block.match or ""))
    sorting = block.sorting or (acfg.sorting or {}).search
  elseif t == "stuck" then
    list = items_mod.stuck(ctx.files, lopts)
    header = block.header or "List of stuck projects:"
    sorting = block.sorting or (acfg.sorting or {}).tags
  else
    b:text("Unknown agenda block type: " .. tostring(t), "ErrorMsg")
    return
  end
  b:text(header, "OrgAgendaHeader")
  if hint then
    b:text(hint, "OrgAgendaHint")
  end
  list = filter_list(list, ctx)
  items_mod.sort(list, sorting or { "priority-down", "category-keep" })
  for _, it in ipairs(list) do
    M.add_item(b, it, ctx)
  end
end

--- Render a whole view (list of blocks).
---@param view { blocks: table[] }
---@param ctx table (see agenda_block); `files_for(block)` returns files
function M.view(view, ctx)
  local b = M.builder()
  local acfg = config.opts.agenda
  if ctx.filter_desc and ctx.filter_desc ~= "" then
    b:text("Filter: " .. ctx.filter_desc, "OrgAgendaFilter")
  end
  local info = {}
  for i, block in ipairs(view.blocks) do
    if i > 1 then
      b:text(string.rep(acfg.block_separator or "─", math.max(ctx.width - 1, 10)), "OrgAgendaBlockSeparator")
    end
    local bctx = vim.tbl_extend("force", ctx, { files = ctx.files_for(block) })
    if block.type == "agenda" then
      local anchor = ctx.anchor
      local align = ctx.align
      if not ctx.anchor_set and block.start_day then
        local sd = date.read_date(block.start_day)
        if sd then
          anchor = sd:days()
          align = false
        end
      end
      bctx.anchor = anchor
      bctx.align = align
      bctx.span = ctx.span_set and ctx.span or block.span or ctx.span
      info[i] = M.agenda_block(b, block, bctx)
    else
      M.list_block(b, block, bctx)
    end
  end
  b.info = info
  return b
end

return M
