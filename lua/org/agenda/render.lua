---@mod org.agenda.render Turning agenda blocks into buffer lines
---
--- Rendering is a pure function of (view, state, width): it returns lines,
--- highlight ranges and a line -> item map. The buffer side lives in
--- `org.agenda.view`. Lines follow `org-agenda-format-item`: a prefix built
--- from `agenda.prefix_format` (org-agenda-prefix-format), the headline
--- text, and the tags aligned to the right.

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

--- "Wednesday  23 September 2026 W39" (org-agenda-format-date-aligned;
--- the week is shown on Mondays).
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

--- Day header per `agenda.format_date` (org-agenda-format-date): nil for
--- the aligned default, a strftime format, or a function(date) -> string.
function M.format_date(days)
  local f = config.opts.agenda.format_date
  if type(f) == "function" then
    return tostring(f(date.from_days(days)))
  elseif type(f) == "string" and f ~= "" then
    return date.from_days(days):strftime(f)
  end
  local wd = date.from_days(days):weekday()
  return M.date_header(days, wd == 1)
end

local function span_days(span, anchor)
  if span == "day" then
    return 1
  elseif span == "week" then
    return 7
  elseif span == "fortnight" then
    return 14
  elseif span == "month" and anchor then
    local a = date.from_days(anchor)
    return date.days_in_month(a.year, a.month)
  elseif span == "year" and anchor then
    return date.is_leap(date.from_days(anchor).year) and 366 or 365
  end
  return tonumber(span)
end
M.span_days = span_days

--- Compute the [from, to] day range for a span starting on `anchor`
--- (org-agenda-list): a month or year span starts on the anchor and lasts
--- as many days as the anchor's month or year; 7 and 14 day spans start on
--- `start_on_weekday` when `align` is set.
---@param span string|integer
---@param anchor integer day number
---@param align boolean align weeks to start_on_weekday
function M.range(span, anchor, align)
  local acfg = config.opts.agenda
  local a = date.from_days(anchor)
  local n = span_days(span, anchor) or 7
  local start = anchor
  if align and (n == 7 or n == 14) and acfg.start_on_weekday then
    start = anchor - ((a:weekday() - acfg.start_on_weekday) % 7)
  end
  return start, start + n - 1
end

--- The first day of the span containing `day` when the view changes to
--- `span` (org-agenda-compute-starting-span).
function M.starting_day(span, day)
  local acfg = config.opts.agenda
  local d = date.from_days(day)
  if span == "week" or span == "fortnight" or span == 7 or span == 14 then
    if acfg.start_on_weekday then
      return day - ((d:weekday() - acfg.start_on_weekday) % 7)
    end
    return day
  elseif span == "month" then
    return date.days_from_civil(d.year, d.month, 1)
  elseif span == "year" then
    return date.days_from_civil(d.year, 1, 1)
  end
  return day
end

--- Move a starting day by `n` spans (org-agenda-later).
function M.shift_anchor(span, anchor, n)
  if span == "month" then
    return date.from_days(anchor):add(n, "m"):days()
  elseif span == "year" then
    return date.from_days(anchor):add(n, "y"):days()
  end
  return anchor + (span_days(span) or 7) * n
end

--- org-agenda-span-name
local function span_name(span)
  local names = { day = "Day", week = "Week", fortnight = "Fortnight", month = "Month", year = "Year" }
  if names[span] then
    return names[span]
  end
  local n = tonumber(span)
  if n == 1 then
    return "Day"
  elseif n == 7 then
    return "Week"
  elseif n == 14 then
    return "Fortnight"
  end
  return string.format("%d days", n or 0)
end
M.span_name = span_name

---------------------------------------------------------------------------
-- Prefix format (org-agenda-prefix-format, org-compile-prefix-format)
---------------------------------------------------------------------------

local DEFAULT_PREFIX = {
  agenda = " %i %-12:c%?-12t% s",
  todo = " %i %-12:c",
  tags = " %i %-12:c",
  search = " %i %-12:c",
}
M.DEFAULT_PREFIX = DEFAULT_PREFIX

local VARS = {
  c = "category",
  t = "time",
  l = "level",
  s = "extra",
  i = "icon",
  T = "tag",
  e = "effort",
  b = "breadcrumbs",
}

local compiled_cache = {}

--- Compile a prefix format into a list of literal strings and specs.
function M.compile_prefix(fmt)
  if compiled_cache[fmt] then
    return compiled_cache[fmt]
  end
  local out = { has = {} }
  local i = 1
  local lit = {}
  while i <= #fmt do
    local c = fmt:sub(i, i)
    local spec
    if c == "%" then
      local opt, width, sep, j = fmt:match("^%%(%??)([-+]?[%d%.]*)([ .;,:!?=|/<>]?)()", i)
      local var = fmt:sub(j, j)
      if VARS[var] then
        spec = { opt = opt == "?", width = width, sep = sep, var = VARS[var] }
        i = j + 1
      elseif var == "(" then
        local expr = fmt:match("^%b()", j)
        if expr then
          spec = { opt = opt == "?", width = width, sep = sep, var = "eval", expr = expr:sub(2, -2) }
          i = j + #expr
        end
      elseif sep ~= "" and VARS[sep] and var ~= "" then
        -- e.g. "%-12c": the separator class matched nothing
        spec = nil
      end
    end
    if spec then
      if #lit > 0 then
        out[#out + 1] = table.concat(lit)
        lit = {}
      end
      if spec.var == "time" then
        out.has.time = true
      elseif spec.var == "tag" then
        out.has.tag = true
      elseif spec.var == "category" then
        local prec = spec.width:match("%.(%d+)")
        out.category_max = prec and tonumber(prec) or nil
      end
      out[#out + 1] = spec
    else
      lit[#lit + 1] = c
      i = i + 1
    end
  end
  if #lit > 0 then
    out[#out + 1] = table.concat(lit)
  end
  compiled_cache[fmt] = out
  return out
end

--- `format "%<width>s"` by display width.
local function fmt_width(width, s)
  if width == "" then
    return s
  end
  local left = width:sub(1, 1) == "-"
  local num = tonumber(width:match("^[-+]?(%d+)") or "")
  local prec = tonumber(width:match("%.(%d+)") or "")
  if prec and vim.fn.strchars(s) > prec then
    s = vim.fn.strcharpart(s, 0, prec)
  end
  local w = utils.width(s)
  if num and w < num then
    if left then
      s = s .. string.rep(" ", num - w)
    else
      s = string.rep(" ", num - w) .. s
    end
  end
  return s
end

--- The prefix format for a view type.
function M.prefix_format(kind)
  local pf = config.opts.agenda.prefix_format
  if type(pf) == "string" then
    return pf
  elseif type(pf) == "table" and pf[kind] then
    return pf[kind]
  end
  return DEFAULT_PREFIX[kind] or "  %-12:c%?-12t% s"
end

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------

--- "9:00" / "09:00" (org-agenda-time-leading-zero), "+1:00" after midnight.
local function fmt_hm(m)
  local acfg = config.opts.agenda
  local h, mm = math.floor(m / 60), m % 60
  if h > 24 or (h == 24 and mm > 0) then
    return string.format("+%d:%02d", h - 24, mm)
  end
  if acfg.time_leading_zero then
    return string.format("%02d:%02d", h, mm)
  end
  return string.format("%d:%02d", h, mm)
end

--- org-agenda-time-of-day-to-ampm
local function ampm(s)
  local acfg = config.opts.agenda
  local h, m = s:match("^%s*(%d+):(%d%d)")
  if not h then
    return s
  end
  h = tonumber(h)
  local suffix = "am"
  if h == 12 then
    suffix = "pm"
  elseif h > 12 then
    suffix = "pm"
    h = h - 12
  end
  local hs = acfg.time_leading_zero and string.format("%02d", h) or string.format("%2s", tostring(h))
  return hs .. ":" .. m .. suffix
end

--- The time field of an item (the `%t` value).
function M.time_string(start, stop)
  if not start then
    return ""
  end
  local acfg = config.opts.agenda
  local grid = acfg.time_grid or {}
  local use_ampm = acfg.timegrid_use_ampm
  local s = string.format("%5s", fmt_hm(start))
  if use_ampm then
    s = ampm(s)
  end
  if stop then
    local e = fmt_hm(stop)
    if use_ampm then
      e = ampm(e)
    end
    return s .. "-" .. e .. (use_ampm and " " or "")
  end
  local trail = grid.separator or " ┄┄┄┄┄ "
  return s .. trail .. (use_ampm and " " or "")
end

local function display_title(title)
  local t = title:gsub("%[%[([^%]]-)%]%[([^%]]-)%]%]", "%2")
  t = t:gsub("%[%[([^%]]-)%]%]", "%1")
  return t
end
M.display_title = display_title

--- Category icon text (org-agenda-category-icon-alist).
local function category_icon(cat)
  for _, e in ipairs(config.opts.agenda.category_icons or {}) do
    local pat, icon = e[1] or e.pattern, e[2] or e.icon
    local ok, re = pcall(vim.regex, pat or "")
    if ok and re:match_str(cat or "") then
      return icon or ""
    end
  end
  return ""
end

local function breadcrumbs(item)
  local hl = item.headline
  if not hl or item.grid then
    return ""
  end
  local sep = config.opts.agenda.breadcrumbs_separator or "->"
  local path = hl:outline_path()
  if #path == 0 then
    return ""
  end
  return table.concat(path, sep) .. sep
end

--- Evaluate a `%(lua expression)` prefix element.
local function eval_expr(expr, item)
  local chunk = loadstring("return " .. expr)
  if not chunk then
    return ""
  end
  local env = setmetatable({ item = item, hl = item.headline }, { __index = _G })
  setfenv(chunk, env)
  local ok, v = pcall(chunk)
  if not ok or v == nil then
    return ""
  end
  return tostring(v)
end

--- Build the prefix string of an item.
---@param kind string "agenda"|"todo"|"tags"|"search"
function M.prefix(item, kind)
  local compiled = M.compile_prefix(M.prefix_format(kind))
  local out = {}
  for _, spec in ipairs(compiled) do
    if type(spec) == "string" then
      out[#out + 1] = spec
    else
      local v
      local var = spec.var
      if var == "category" then
        v = item.category or ""
        local max = compiled.category_max
        if max and vim.fn.strchars(v) >= max then
          v = vim.fn.strcharpart(v, 0, max - 1)
        end
      elseif var == "time" then
        v = M.time_string(item.time, item.end_time)
      elseif var == "level" then
        v = item.level_str or (item.level and string.rep(" ", item.level)) or ""
      elseif var == "extra" then
        v = (not item.habit and item.extra) or ""
      elseif var == "icon" then
        v = item.grid and "" or category_icon(item.category)
      elseif var == "tag" then
        local tags = item.tags or {}
        v = tags[#tags] or ""
      elseif var == "effort" then
        v = item.headline and item.headline:get_property(config.opts.effort_property or "Effort") or ""
      elseif var == "breadcrumbs" then
        v = breadcrumbs(item)
      elseif var == "eval" then
        v = item.grid and "" or eval_expr(spec.expr, item)
      end
      v = v or ""
      if spec.opt then
        out[#out + 1] = v == "" and "" or fmt_width(spec.width, v .. spec.sep)
      else
        out[#out + 1] = fmt_width(spec.width, v == "" and "" or (v .. spec.sep))
      end
    end
  end
  return table.concat(out), compiled.has
end

--- Tags as displayed (org-agenda-fix-displayed-tags): inherited tags
--- first, then "::" and the entry's own tags; `hide_tags_regexp` drops
--- matching tags.
function M.tags_string(item)
  local acfg = config.opts.agenda
  local hl = item.headline
  local tags = item.tags or {}
  if not hl then
    return #tags > 0 and (":" .. table.concat(tags, ":") .. ":") or nil
  end
  local own = {}
  for _, t in ipairs(hl.tags) do
    own[t] = true
  end
  local hide = acfg.hide_tags_regexp and acfg.hide_tags_regexp ~= "" and vim.regex(acfg.hide_tags_regexp)
  local inh, loc = {}, {}
  local inherited_set = {}
  for _, t in ipairs(hl:get_inherited_tags()) do
    inherited_set[t] = true
  end
  for _, t in ipairs(tags) do
    if not (hide and hide:match_str(t)) then
      if inherited_set[t] and not (own[t] and not inherited_set[t]) then
        if acfg.show_inherited_tags ~= false then
          inh[#inh + 1] = t
        end
      else
        loc[#loc + 1] = t
      end
    end
  end
  if #inh == 0 and #loc == 0 then
    return nil
  end
  if #inh == 0 then
    return ":" .. table.concat(loc, ":") .. ":"
  end
  if #loc == 0 then
    return ":" .. table.concat(inh, ":") .. "::"
  end
  return ":" .. table.concat(inh, ":") .. "::" .. table.concat(loc, ":") .. ":"
end

--- Split parts at display column `col`: (before, after).
local function split_parts(parts, col)
  local before, after = {}, {}
  local w = 0
  for _, p in ipairs(parts) do
    local s = p[1] or ""
    local sw = utils.width(s)
    if w >= col then
      after[#after + 1] = p
    elseif w + sw <= col then
      before[#before + 1] = p
    else
      local n = col - w
      local head = vim.fn.strcharpart(s, 0, n)
      while utils.width(head) > n do
        head = vim.fn.strcharpart(head, 0, vim.fn.strchars(head) - 1)
      end
      local tail = s:sub(#head + 1)
      before[#before + 1] = { head, p[2] }
      if utils.width(head) < n then
        before[#before + 1] = { string.rep(" ", n - utils.width(head)) }
      end
      after[#after + 1] = { tail, p[2] }
    end
    w = w + sw
  end
  if w < col then
    before[#before + 1] = { string.rep(" ", col - w) }
  end
  return before, after
end

--- Drop the first `n` display columns of parts.
local function drop_columns(parts, n)
  local _, after = split_parts(parts, n)
  return after
end

--- Build the parts for an item line.
---@param item org.AgendaItem
---@param ctx { agenda?: boolean, kind?: string, width: integer, today: integer }
function M.item_parts(item, ctx)
  local acfg = config.opts.agenda
  local kind = ctx.kind or (ctx.agenda and "agenda" or "todo")
  local parts = {}
  local width = 0
  local function push(s, group)
    parts[#parts + 1] = { s, group }
    width = width + utils.width(s)
  end
  local prefix = M.prefix(item, kind)
  local cat = item.category or ""
  local ps, pe = prefix:find(cat .. ":", 1, true)
  if cat ~= "" and ps then
    push(prefix:sub(1, ps - 1))
    push(prefix:sub(ps, pe), "OrgAgendaCategory")
    local rest = prefix:sub(pe + 1)
    -- the leader gets the item face (Emacs faces the whole line)
    local ex = item.extra
    local es, ee = nil, nil
    if ex and ex ~= "" and not item.habit then
      es, ee = rest:find(ex, 1, true)
    end
    if es then
      push(rest:sub(1, es - 1))
      push(rest:sub(es, ee), item.face ~= "OrgAgendaTimestamp" and item.face or nil)
      push(rest:sub(ee + 1))
    else
      push(rest)
    end
  else
    push(prefix)
  end
  if item.todo then
    push(item.todo, item.done and "OrgAgendaDoneKeyword" or "OrgAgendaTodoKeyword")
    push(" ")
  end
  if item.priority then
    push("[#" .. item.priority .. "]", "OrgAgendaPriority")
    push(" ")
  end
  push(display_title(item.display_title or item.title or ""), item.face)

  local rt = acfg.remove_tags
  local has_tag = M.compile_prefix(M.prefix_format(kind)).has.tag
  if not (rt == true or (rt == "prefix" and has_tag)) then
    local tagstr = M.tags_string(item)
    if tagstr then
      local col = acfg.tags_column
      local pad
      if type(col) == "number" and col > 0 then
        pad = col - width
      elseif type(col) == "number" and col < 0 then
        pad = -col - width - utils.width(tagstr)
      else
        pad = (ctx.width - 1) - width - utils.width(tagstr)
      end
      push(string.rep(" ", math.max(pad, 1)))
      push(tagstr, "OrgAgendaTag")
    end
  end

  if item.habit then
    -- org-habit-insert-consistency-graphs: the graph overwrites the line
    -- from `graph_column`
    local hcfg = acfg.habits or {}
    local gc = hcfg.graph_column or 40
    local glen = (hcfg.preceding_days or 21) + (hcfg.following_days or 7) + 1
    local before, after = split_parts(parts, gc)
    after = drop_columns(after, glen)
    parts = before
    for _, g in ipairs(habits.graph(item.habit, ctx.today)) do
      parts[#parts + 1] = { g[1], g[2] }
    end
    vim.list_extend(parts, after)
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

--- Is the item a TODO blocked by its children, an ORDERED sibling or
--- unchecked checkboxes (only with the enforce_todo_* options)?
function M.is_blocked(it)
  if not it.headline or not it.todo or it.done then
    return false
  end
  local ok, todo = pcall(require, "org.todo")
  if not ok or type(todo.blocked_reason) ~= "function" then
    return false
  end
  local ok2, reason = pcall(todo.blocked_reason, it.headline)
  return ok2 and reason ~= nil
end

--- Add an item line (plus its entry text in entry-text mode).
function M.add_item(b, it, ctx)
  local parts = M.item_parts(it, ctx)
  if ctx.dim_blocked and M.is_blocked(it) then
    if ctx.dim_blocked == "invisible" then
      return
    end
    for _, p in ipairs(parts) do
      if p[2] ~= "OrgAgendaCategory" then
        p[2] = "OrgAgendaDimmed"
      end
    end
  end
  b:add(parts, it, ctx.is_clocking and ctx.is_clocking(it) and "OrgAgendaClocking" or nil)
  if ctx.entry_text and it.headline then
    local max = config.opts.agenda.entry_text_maxlines or 5
    for _, l in ipairs(M.entry_text(it.headline, max)) do
      b:text("    > " .. l, "OrgAgendaEntryText")
    end
  end
end

---------------------------------------------------------------------------
-- Limits (org-agenda-max-entries, -todos, -tags, -effort)
---------------------------------------------------------------------------

local function limit_value(v, kind)
  if type(v) == "number" then
    return v
  elseif type(v) == "table" then
    return v[kind]
  end
  return nil
end

--- org-agenda-limit-entries
local function limit_entries(list, prop, limit, fn)
  if not limit then
    return list
  end
  fn = fn or function(p)
    return p and 1 or nil
  end
  local include = limit < 0
  local lim = 0
  local out = {}
  for _, e in ipairs(list) do
    local pval = fn(prop(e))
    if pval then
      lim = lim + pval
    end
    if (pval and lim <= math.abs(limit)) or (include and not pval) then
      out[#out + 1] = e
    end
  end
  return out
end

--- Apply the max_* limits of a view type to a sorted list.
function M.apply_limits(list, kind, ctx)
  local acfg = config.opts.agenda
  local limits = (ctx and ctx.limits) or {}
  local function get(name)
    local v = limits[name]
    if v == nil then
      v = acfg[name]
    end
    return limit_value(v, kind)
  end
  local max_effort = get("max_effort")
  if max_effort then
    list = limit_entries(list, function(e)
      return e.grid and nil or items_mod.effort(e)
    end, max_effort, function(e)
      return e or (acfg.sort_noeffort_is_high ~= false and math.huge or -1)
    end)
  end
  local max_todos = get("max_todos")
  if max_todos then
    list = limit_entries(list, function(e)
      return e.todo
    end, max_todos)
  end
  local max_tags = get("max_tags")
  if max_tags then
    list = limit_entries(list, function(e)
      return e.tags and #e.tags > 0 and e.tags or nil
    end, max_tags)
  end
  local max_entries = get("max_entries")
  if max_entries then
    list = limit_entries(list, function(e)
      return e.headline
    end, max_entries)
  end
  return list
end

---------------------------------------------------------------------------
-- Blocks
---------------------------------------------------------------------------

local function grid_minutes(t)
  return math.floor(t / 100) * 60 + t % 100
end

--- org-agenda-add-time-grid-maybe: should the grid be shown?
local function show_grid(grid, d, today, ndays, has_timed)
  if not grid or grid.enabled == false or grid.hidden then
    return false
  end
  local set = {}
  for _, t in ipairs(grid.type or { "daily", "today", "require-timed" }) do
    set[t] = true
  end
  if not ((d == today and set.today) or (ndays == 1 and set.daily) or set.weekly) then
    return false
  end
  if set["require-timed"] and not has_timed then
    return false
  end
  return true, set["remove-match"]
end

--- Minutes of an org-duration value ("10:00", 30, "1d 2:00").
local function duration_minutes(v)
  if type(v) == "number" then
    return v
  end
  return v and date.parse_duration(tostring(v)) or nil
end

--- Does the gap [t1, t2] (minutes) contain one of the `ok` times of day?
--- (org-agenda-check-clock-gap)
local function gap_ok(t1, t2, ok)
  if not ok or #ok == 0 then
    return false
  end
  -- Emacs compares (t / 36000) seconds here, so "more than 24" is 10 days
  if (t2 - t1) / 600 > 24 then
    return true
  end
  local min1, min2 = t1 % 1440, t2 % 1440
  if min2 < min1 then
    min2 = min2 + 1440
  end
  for _, x in ipairs(ok) do
    x = duration_minutes(x) or 0
    if x < min1 then
      x = x + 1440
    end
    if min1 <= x and x <= min2 then
      return true
    end
  end
  return false
end

--- The clocking issue of a clock item for the clock check
--- (org-agenda-show-clocking-issues), or nil. `state.tlend` carries the
--- end of the previous clock across the agenda.
local function clock_issue(it, state)
  local checks = config.opts.agenda.clock_consistency_checks or {}
  local c = it.clock
  if not c.stop then
    return string.format("No end time: (%s)", date.duration_to_string(date.now():minutes() - c.start))
  end
  local maxtime = duration_minutes(checks.max_duration or "24:00") or 1440
  local mintime = duration_minutes(checks.min_duration or 0) or 0
  local maxgap = duration_minutes(checks.max_gap or "30:00") or 1800
  local dt = c.stop - c.start
  local tlend = state.tlend or 0
  local issue
  if dt > maxtime then
    issue = "Clocking interval is very long: " .. date.duration_to_string(dt)
  elseif dt < mintime then
    issue = "Clocking interval is very short: " .. date.duration_to_string(dt)
  elseif tlend > 0 and c.start < tlend then
    issue = string.format("Clocking overlap: %d minutes", tlend - c.start)
  elseif tlend > 0 and c.start > tlend + maxgap and not gap_ok(tlend, c.start, checks.gap_ok_around) then
    issue = string.format("Clocking gap: %d minutes", c.start - tlend)
  end
  state.tlend = c.stop
  return issue
end

--- A time grid line or the current-time line as a pseudo item.
local function grid_item(minutes, text, group)
  return {
    grid = true,
    time = minutes,
    category = "",
    urgency = 0,
    prio = 0,
    title = text,
    face = group,
    tags = {},
    order = 0,
  }
end

--- The sorting strategy of a block type.
local function sorting_for(block, kind)
  local acfg = config.opts.agenda
  local s = block.sorting or acfg.sorting
  if type(s) == "table" and not vim.islist(s) then
    s = s[kind] or s.agenda
  end
  if type(s) == "table" and vim.islist(s) and #s > 0 then
    return s
  end
  local defaults = {
    agenda = { "habit-down", "time-up", "urgency-down", "category-keep" },
    todo = { "urgency-down", "category-keep" },
    tags = { "urgency-down", "category-keep" },
    search = { "category-keep" },
  }
  return defaults[kind] or { "time-up", "category-keep", "urgency-down" }
end
M.sorting_for = sorting_for

--- Render the item list of one day, with time grid.
local function render_day(b, list, d, ctx, sorting)
  local acfg = config.opts.agenda
  local grid = acfg.time_grid or {}
  local have = {}
  local has_timed = false
  for _, it in ipairs(list) do
    if it.time then
      has_timed = true
      have[it.time] = true
    end
  end
  local rows = list
  local shown, remove = false, false
  if not ctx.time_grid_off then
    shown, remove = show_grid(grid, d, ctx.today, ctx.ndays, has_timed)
  end
  if shown then
    local new = {}
    local sep = grid.separator or " ┄┄┄┄┄ "
    local _ = sep
    for _, t in ipairs(grid.times or {}) do
      local m = grid_minutes(t)
      if not (remove and have[m]) then
        table.insert(new, 1, grid_item(m, grid.time_string or "", "OrgAgendaTimeGrid"))
      end
    end
    if d == ctx.today and ctx.now and acfg.show_current_time_in_grid ~= false then
      table.insert(new, 1, grid_item(ctx.now, acfg.current_time_string or "now", "OrgAgendaCurrentTime"))
    end
    rows = {}
    if vim.tbl_contains(sorting, "time-up") then
      vim.list_extend(rows, new)
      vim.list_extend(rows, list)
    else
      vim.list_extend(rows, list)
      vim.list_extend(rows, new)
    end
  else
    rows = vim.list_slice(list)
  end
  items_mod.sort(rows, sorting)
  rows = M.apply_limits(rows, "agenda", ctx)
  for _, it in ipairs(rows) do
    if it.grid then
      local prefix = M.prefix(it, "agenda")
      local ps = #prefix:match("^%s*")
      b:add({ { prefix:sub(1, math.min(ps, 2)) }, { prefix:sub(math.min(ps, 2) + 1) .. it.title, it.face } })
    else
      if ctx.log_mode == "clockcheck" and it.clock then
        local issue = clock_issue(it, ctx.clockcheck)
        if issue then
          b:add({ { string.format("%-43s", " " .. issue), "OrgAgendaClockIssue" } })
        end
      end
      M.add_item(b, it, ctx)
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

--- Clock table for the span (org-agenda-clockreport-mode): a clocktable
--- over the agenda files with `agenda.clockreport_parameters`, from the
--- first day of the span to the end of the last.
function M.clock_report(b, files, from, to)
  local acfg = config.opts.agenda
  local params = vim.deepcopy(acfg.clockreport_parameters or { link = true, maxlevel = 2 })
  params.block, params.step = nil, nil
  params.scope = files
  params.tstart = "[" .. date.from_days(from):to_date_string() .. "]"
  params.tend = "[" .. date.from_days(to + 1):to_date_string() .. "]"
  params.header = ""
  local ok, lines = pcall(require("org.clock").clocktable, params, vim.api.nvim_get_current_buf())
  if acfg.clock_report_header then
    for _, l in ipairs(vim.split(acfg.clock_report_header, "\n", { plain = true, trimempty = true })) do
      b:text(l, "OrgAgendaHeader")
    end
  end
  if not ok then
    b:text("Clock report: " .. tostring(lines), "ErrorMsg")
    return
  end
  for _, l in ipairs(lines) do
    b:text(l)
  end
end

--- Insert a block header (org-agenda--insert-overriding-header): a
--- string, "" for none, or a function returning the header.
local function insert_header(b, block, default)
  local h = block.header
  if h == nil then
    for _, l in ipairs(type(default) == "table" and default or { default }) do
      if type(l) == "table" then
        b:add(l)
      else
        b:text(l, "OrgAgendaHeader")
      end
    end
  elseif h == "" then
    return
  elseif type(h) == "function" then
    local s = h()
    for _, l in ipairs(vim.split(tostring(s or ""), "\n", { trimempty = true })) do
      b:text(l, "OrgAgendaHeader")
    end
  else
    for _, l in ipairs(vim.split(tostring(h), "\n", { trimempty = true })) do
      b:text(l, "OrgAgendaHeader")
    end
  end
end

--- Is `d` (day number) a weekend day (org-agenda-weekend-days, 0 = Sunday)?
local function is_weekend(d)
  local wd = date.from_days(d):weekday() % 7
  for _, w in ipairs(config.opts.agenda.weekend_days or { 6, 0 }) do
    if w == wd then
      return true
    end
  end
  return false
end
M.is_weekend = is_weekend

--- Render an agenda (date range) block.
---@param block table
---@param ctx table { files, span, anchor, align, today, now, width, log_mode, clockreport, restrict, filter, is_clocking }
function M.agenda_block(b, block, ctx)
  local acfg = config.opts.agenda
  local span = ctx.span or block.span or acfg.span or "week"
  local from, to = M.range(span, ctx.anchor, ctx.align)
  local ndays = to - from + 1
  local by_day = items_mod.agenda(ctx.files, from, to, {
    today = ctx.today,
    log_mode = ctx.log_mode,
    inactive = ctx.inactive,
    no_deadlines = ctx.no_deadlines,
    archives = ctx.archives,
    restrict = ctx.restrict,
    skip = block.skip,
    block = block,
  })
  if not acfg.compact_blocks then
    local w1, w2 = M.iso_week(from), M.iso_week(to)
    local wk
    if to - from >= 350 then
      wk = ""
    elseif w1 == w2 then
      wk = string.format(" (W%02d)", w1)
    else
      wk = string.format(" (W%02d-W%02d)", w1, w2)
    end
    insert_header(b, block, span_name(span) .. "-agenda" .. wk .. ":")
  end
  local sorting = sorting_for(block, "agenda")
  local dctx =
    vim.tbl_extend("force", ctx, { agenda = true, kind = "agenda", span = span, ndays = ndays, clockcheck = {} })
  for d = from, to do
    local list = filter_list(by_day[d] or {}, ctx)
    if #list > 0 or acfg.show_all_dates ~= false then
      local group = "OrgAgendaDate"
      if d == ctx.today then
        group = "OrgAgendaDateToday"
      elseif is_weekend(d) then
        group = "OrgAgendaDateWeekend"
      end
      b:add({ { M.format_date(d), group } }, nil)
      b.day_lines = b.day_lines or {}
      b.day_lines[#b.lines] = d
      render_day(b, list, d, dctx, sorting)
    end
  end
  if ctx.clockreport then
    M.clock_report(b, ctx.files, from, to)
  end
  return { from = from, to = to, span = span }
end

--- The key of an agenda mapping for hints (first lhs).
local function key_of(name, default)
  local maps = (config.opts.mappings or {}).agenda or {}
  local lhs = config.lhs_list(maps[name])[1]
  return lhs or default
end

--- Wrap `words` after `start` so lines fit `width` (the TODO list hint).
local function wrapped_hint(start, words, width)
  local lines = {}
  local cur = start
  for _, w in ipairs(words) do
    if utils.width(cur) + utils.width(w) + 1 > width and cur ~= start then
      lines[#lines + 1] = cur
      cur = string.rep(" ", 21)
    end
    cur = cur .. " " .. w
  end
  lines[#lines + 1] = cur
  return lines
end

--- Render a list block (todo / tags / search / stuck).
function M.list_block(b, block, ctx)
  local t = block.type
  local list, sorting
  local kind
  local header
  local lopts = { restrict = ctx.restrict, skip = block.skip, block = block, archives = ctx.archives }
  local redo = key_of("redo", "r")
  if t == "todo" then
    kind = "todo"
    local kws = block.keywords
    if type(kws) == "string" then
      kws = vim.split(kws, "[|%s]+", { trimempty = true })
    end
    if not kws and block.match and block.match ~= "" then
      kws = vim.split(block.match, "[|%s]+", { trimempty = true })
    end
    list = items_mod.todo(ctx.files, kws, lopts)
    local sel = (kws and #kws > 0) and table.concat(kws, "|") or "ALL"
    header = { { { "Global list of TODO items of type: ", "OrgAgendaHeader" }, { sel, "OrgAgendaFilter" } } }
    if not ctx.multi then
      local words = { "(0)[ALL]" }
      for i, n in ipairs(ctx.todo_names or {}) do
        words[#words + 1] = string.format("(%d)%s", i, n)
      end
      local start = string.format("Press ‘N %s’ (e.g. ‘0 %s’) to search again:", redo, redo)
      for _, l in ipairs(wrapped_hint(start, words, ctx.width)) do
        header[#header + 1] = { { l, "OrgAgendaHint" } }
      end
    end
  elseif t == "tags" or t == "tags_todo" then
    kind = "tags"
    local pred, err = require("org.agenda.search").try_compile(block.match or "")
    if not pred then
      b:text("Invalid match: " .. tostring(err), "ErrorMsg")
      return
    end
    list = items_mod.tags(ctx.files, pred, t == "tags_todo", lopts)
    header = { { { "Headlines with TAGS match: ", "OrgAgendaHeader" }, { block.match or "", "OrgAgendaFilter" } } }
    if not ctx.multi then
      header[#header + 1] = { { string.format("Press ‘1 %s’ to search again", redo), "OrgAgendaHint" } }
    end
  elseif t == "search" then
    kind = "search"
    local query = (block.todo_only and "!" or "") .. (block.match or "")
    local pred = require("org.agenda.search").compile_text(query, block)
    list = items_mod.search(ctx.files, pred, lopts)
    header = { { { "Search words: ", "OrgAgendaHeader" }, { block.match or "", "OrgAgendaFilter" } } }
    if not ctx.multi then
      header[#header + 1] = {
        {
          string.format(
            "Press ‘%s’, ‘%s’ to add/sub word, ‘%s’, ‘%s’ to add/sub regexp, ‘1 %s’ for a fresh search",
            key_of("query_add", "["),
            key_of("query_subtract", "]"),
            key_of("query_add_re", "{"),
            key_of("query_subtract_re", "}"),
            redo
          ),
          "OrgAgendaHint",
        },
      }
    end
  elseif t == "stuck" then
    kind = "tags"
    local ok, res = pcall(items_mod.stuck, ctx.files, lopts)
    if not ok then
      b:text(tostring(res), "ErrorMsg")
      return
    end
    list = res
    header = "List of stuck projects: "
  else
    b:text("Unknown agenda block type: " .. tostring(t), "ErrorMsg")
    return
  end
  sorting = sorting_for(block, kind)
  insert_header(b, block, header)
  list = filter_list(list, ctx)
  if kind == "todo" or kind == "tags" then
    for _, it in ipairs(list) do
      items_mod.set_list_timestamp(it, sorting)
    end
  end
  items_mod.sort(list, sorting)
  list = M.apply_limits(list, kind, ctx)
  local lctx = vim.tbl_extend("force", ctx, { kind = kind })
  for _, it in ipairs(list) do
    it.level_str = string.rep(" ", it.level or 0)
    M.add_item(b, it, lctx)
  end
end

-- Block keys that are not agenda options (or are handled by the block).
local BLOCK_KEYS = {
  type = true,
  match = true,
  keywords = true,
  header = true,
  span = true,
  start_day = true,
  files = true,
  skip = true,
  sorting = true,
  todo_only = true,
  stuck_projects = true,
}

-- Agenda options whose default is nil.
local NIL_OPTIONS = {
  start_day = true,
  format_date = true,
  hide_tags_regexp = true,
  default_appointment_duration = true,
  cmp_user_defined = true,
  max_entries = true,
  max_todos = true,
  max_tags = true,
  max_effort = true,
  overriding_columns_format = true,
  clock_report_header = true,
  auto_exclude_function = true,
}

--- Run `fn` with the agenda options set on `block` in effect, like the
--- let-bound options of an Emacs custom command.
function M.with_block_options(block, fn)
  local acfg = config.opts.agenda
  local defaults = config.defaults.agenda
  local saved = {}
  for k, v in pairs(block) do
    if not BLOCK_KEYS[k] and (defaults[k] ~= nil or NIL_OPTIONS[k]) then
      saved[k] = { acfg[k] }
      if type(v) == "table" and type(acfg[k]) == "table" and not vim.islist(v) and not vim.islist(acfg[k]) then
        acfg[k] = vim.tbl_deep_extend("force", acfg[k], v)
      else
        acfg[k] = v
      end
    end
  end
  local ok, err = pcall(fn)
  for k, v in pairs(saved) do
    acfg[k] = v[1]
  end
  if not ok then
    error(err, 0)
  end
end

--- Render a whole view (list of blocks).
---@param view { blocks: table[], multi?: boolean }
---@param ctx table (see agenda_block); `files_for(block)` returns files
function M.view(view, ctx)
  local b = M.builder()
  local acfg = config.opts.agenda
  local info = {}
  local multi = view.multi or #view.blocks > 1
  for i, block in ipairs(view.blocks) do
    if i > 1 and not acfg.compact_blocks and acfg.block_separator ~= false then
      local sep = acfg.block_separator or "─"
      b:text("")
      if vim.fn.strchars(sep) > 1 then
        b:text(sep, "OrgAgendaBlockSeparator")
      else
        b:text(string.rep(sep, math.max(ctx.width - 1, 10)), "OrgAgendaBlockSeparator")
      end
    end
    b.block_starts = b.block_starts or {}
    b.block_starts[#b.block_starts + 1] = #b.lines + 1
    local bctx = vim.tbl_extend("force", ctx, { files = ctx.files_for(block), multi = multi })
    M.with_block_options(block, function()
    if block.type == "agenda" then
      local anchor = ctx.anchor
      local align = ctx.align
      local start_day = block.start_day or acfg.start_day
      if not ctx.anchor_set and start_day then
        local sd = date.read_date(start_day)
        if sd then
          -- org-agenda-list still aligns 7 and 14 day spans
          anchor = sd:days()
        end
      end
      bctx.anchor = anchor
      bctx.align = align
      bctx.span = ctx.span_set and ctx.span or block.span or ctx.span
      info[i] = M.agenda_block(b, block, bctx)
    else
      M.list_block(b, block, bctx)
    end
    end)
  end
  b.info = info
  return b
end

return M
