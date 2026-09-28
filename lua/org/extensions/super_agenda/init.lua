---@mod org.extensions.super_agenda org-super-agenda: grouped agenda views
---
--- Enable with `extensions = { super_agenda = { groups = { ... } } }` (see
--- `:h org-extensions-super-agenda`). Each day of an agenda block, and each
--- list block (TODO, tags, search, org-ql), is split into groups:
---
--- ```lua
--- groups = {
---   { name = "Today", time_grid = true, date = "today" },
---   { name = "Important", priority = "A" },
---   { name = "Work", tag = { "work", "office" }, order = 1 },
---   { discard = { tag = "someday" } },
---   { auto_category = true, order = 9 },
--- }
--- ```
---
--- An item goes to the first group it matches; the selectors of a group are
--- ORed. Items no group takes are shown last under "Other items". A block
--- can set its own `super_groups` (`false` for none).

local date = require("org.date")

local M = {}

M.defaults = {
  --- The groups (org-super-agenda-groups); empty = the agenda is unchanged.
  groups = {},
  --- Header of the items no group takes (org-super-agenda-unmatched-name).
  unmatched_name = "Other items",
  --- Order of that group (org-super-agenda-unmatched-order).
  unmatched_order = 99,
  --- Before each group header: a string ("\n" = one blank line), or a
  --- single character repeated across the window
  --- (org-super-agenda-header-separator).
  header_separator = "\n",
  --- Text before each group name (org-super-agenda-header-prefix).
  header_prefix = " ",
  --- After the last group (org-super-agenda-final-group-separator).
  final_group_separator = "",
  --- strftime format of :auto_planning and :auto_ts headers
  --- (org-super-agenda-date-format).
  date_format = "%e %B %Y",
  --- Property read by :auto_group (org-super-agenda-group-property-name).
  group_property_name = "agenda-group",
  --- Inherit properties in :property, :auto_property and :auto_group
  --- (org-super-agenda-properties-inherit).
  properties_inherit = true,
}

local function opts()
  return require("org.extensions").opts("super_agenda") or M.defaults
end

---------------------------------------------------------------------------
-- Normalizing groups
---------------------------------------------------------------------------

local SPECIAL = { name = true, face = true, transformer = true, order = true, order_multi = true }

local KEY_ALIASES = {
  ["priority>"] = "priority_gt",
  ["priority>="] = "priority_ge",
  ["priority<"] = "priority_lt",
  ["priority<="] = "priority_le",
  ["effort<"] = "effort_lt",
  ["effort>"] = "effort_gt",
}

local function norm_key(k)
  k = tostring(k):gsub("^:", "")
  return KEY_ALIASES[k] or (k:gsub("%-", "_"))
end

--- A group as a table keyed by selector name. Accepts Lua tables with
--- `snake_case` or Emacs keys and Emacs-style plists
--- (`{ ":name", "Today", ":time-grid", true }`).
---@param g table
---@return table
function M.normalize(g)
  local out = {}
  if vim.islist(g) and type(g[1]) == "string" and g[1]:match("^:") then
    for i = 1, #g, 2 do
      out[norm_key(g[i])] = g[i + 1]
    end
  else
    for k, v in pairs(g) do
      out[norm_key(k)] = v
    end
  end
  for _, k in ipairs({ "and", "not", "discard" }) do
    if type(out[k]) == "table" then
      out[k] = M.normalize(out[k])
    end
  end
  if type(out.take) == "table" and type(out.take[2]) == "table" then
    out.take = { out.take[1], M.normalize(out.take[2]) }
  end
  return out
end

local function list_of(v)
  if type(v) == "table" and vim.islist(v) then
    return v
  end
  return { v }
end

---------------------------------------------------------------------------
-- Item helpers
---------------------------------------------------------------------------

local function entry_text(it)
  local hl = it.headline
  if not hl then
    return it.raw or ""
  end
  return table.concat(vim.list_slice(hl.file.lines, hl.line, hl.body_end or hl.line), "\n")
end

local function regex(re)
  return require("org.agenda.search").compile_emacs_regexp(tostring(re))
end

local function any_regexp(res, s)
  for _, re in ipairs(res) do
    if re:match_str(s) then
      return true
    end
  end
  return false
end

local function today()
  return date.today_days()
end

local function date_days(s)
  if type(s) == "number" then
    return today() + s
  end
  s = tostring(s)
  local d = date.parse(s:match("^[<%[]") and s or ("<" .. s .. ">")) or date.read_date(s)
  if not d then
    error("super_agenda: invalid date " .. s, 0)
  end
  return d:days()
end

local function compare(cmp, a, b)
  if cmp == "past" or cmp == "before" then
    return a < b
  elseif cmp == "today" or cmp == "on" then
    return a == b
  elseif cmp == "future" or cmp == "after" then
    return a > b
  end
  error("super_agenda: invalid date comparison " .. tostring(cmp), 0)
end

local function effort(it)
  return require("org.agenda.items").effort(it)
end

local function duration(v)
  local m = type(v) == "number" and v or date.parse_duration(tostring(v))
  if not m then
    error("super_agenda: invalid effort " .. tostring(v), 0)
  end
  return m
end

local function property(it, name)
  return it.headline and it.headline:get_property(tostring(name), opts().properties_inherit and true or false)
end

local LOG_TYPES = { closed = "closed", close = "closed", clock = "clock", clocked = "clock", state = "state" }
LOG_TYPES.changed = "state"

---------------------------------------------------------------------------
-- Selectors: name -> { test = fun(arg) -> fun(item): boolean, name = fun(arg) }
---------------------------------------------------------------------------

local S = {}

local function planning_selector(kind, names)
  return {
    name = function(arg)
      local a = list_of(arg)
      local n = names[tostring(a[1])]
      return n and (n .. (a[2] and (" " .. tostring(a[2])) or "")) or names["true"]
    end,
    test = function(arg)
      local a = list_of(arg)
      local cmp = a[1]
      local target = (cmp == "before" or cmp == "on" or cmp == "after") and date_days(a[2]) or nil
      return function(it)
        local ts = it.headline and it.headline.planning and it.headline.planning[kind]
        if cmp == true then
          return ts ~= nil
        elseif cmp == false then
          return ts == nil
        end
        return ts ~= nil and compare(cmp, ts:days(), target or today())
      end
    end,
  }
end

S.deadline = planning_selector("deadline", {
  ["true"] = "Deadline items",
  ["false"] = "Items without deadlines",
  past = "Past due",
  today = "Due today",
  future = "Due soon",
  before = "Due before",
  on = "Due on",
  after = "Due after",
})

S.scheduled = planning_selector("scheduled", {
  ["true"] = "Scheduled items",
  ["false"] = "Unscheduled items",
  past = "Past scheduled",
  today = "Scheduled today",
  future = "Scheduled soon",
  before = "Scheduled before",
  on = "Scheduled on",
  after = "Scheduled after",
})

S.date = {
  name = function()
    return "Dated items"
  end,
  test = function(arg)
    return function(it)
      local d = it.ts_date or it.day
      if arg == true then
        return d ~= nil
      elseif arg == false then
        return d == nil
      elseif arg == "today" then
        return d == today()
      end
      error("super_agenda: date must be true, false or \"today\"", 0)
    end
  end,
}

S.time_grid = {
  name = function()
    return "Timed items"
  end,
  test = function(arg)
    return function(it)
      return (it.time ~= nil) == (arg ~= false)
    end
  end,
}

S.todo = {
  name = function(arg)
    if arg == true then
      return "Any TODO keyword"
    elseif arg == false then
      return "Non-todo items"
    end
    return table.concat(list_of(arg), " and ") .. " items"
  end,
  test = function(arg)
    local set = {}
    for _, k in ipairs(list_of(arg)) do
      set[k] = true
    end
    return function(it)
      if arg == true then
        return it.todo ~= nil
      elseif arg == false then
        return it.todo == nil
      end
      return it.todo ~= nil and set[it.todo] == true
    end
  end,
}

S.tag = {
  name = function(arg)
    return "Tags: " .. table.concat(list_of(arg), " OR ")
  end,
  test = function(arg)
    local want = {}
    for _, t in ipairs(list_of(arg)) do
      want[tostring(t):lower()] = true
    end
    return function(it)
      for _, t in ipairs(it.tags or {}) do
        if want[t:lower()] then
          return true
        end
      end
      return false
    end
  end,
}

S.category = {
  name = function(arg)
    return "Items categorized as: " .. table.concat(list_of(arg), " OR ")
  end,
  test = function(arg)
    local set = {}
    for _, c in ipairs(list_of(arg)) do
      set[c] = true
    end
    return function(it)
      return it.category ~= nil and set[it.category] == true
    end
  end,
}

S.priority = {
  name = function(arg)
    return "Priority " .. table.concat(list_of(arg), " and ") .. " items"
  end,
  test = function(arg)
    local set = {}
    for _, p in ipairs(list_of(arg)) do
      set[tostring(p)] = true
    end
    return function(it)
      return it.priority ~= nil and set[it.priority] == true
    end
  end,
}

local function priority_selector(label, cmp)
  return {
    name = function(arg)
      return "Priority " .. label .. " " .. table.concat(list_of(arg), " or ") .. " items"
    end,
    test = function(arg)
      local n = tostring(list_of(arg)[1]):byte()
      return function(it)
        -- a higher priority is a lower letter
        return it.priority ~= nil and cmp(it.priority:byte(), n)
      end
    end,
  }
end

S.priority_gt = priority_selector(">", function(a, b)
  return a < b
end)
S.priority_ge = priority_selector(">=", function(a, b)
  return a <= b
end)
S.priority_lt = priority_selector("<", function(a, b)
  return a > b
end)
S.priority_le = priority_selector("<=", function(a, b)
  return a >= b
end)

local function effort_selector(label, cmp)
  return {
    name = function(arg)
      return "Effort " .. label .. " " .. table.concat(list_of(arg), " or ") .. " items"
    end,
    test = function(arg)
      local n = duration(list_of(arg)[1])
      return function(it)
        local e = effort(it)
        return e ~= nil and cmp(e, n)
      end
    end,
  }
end

S.effort_lt = effort_selector("<", function(a, b)
  return a <= b
end)
S.effort_gt = effort_selector(">", function(a, b)
  return a >= b
end)

S.habit = {
  name = function()
    return "Habits"
  end,
  test = function(arg)
    return function(it)
      local h = it.headline and require("org.agenda.habits").is_habit(it.headline) or false
      return h == (arg ~= false)
    end
  end,
}

S.regexp = {
  name = function(arg)
    return 'Items matching regexps: "' .. table.concat(list_of(arg), '" OR "') .. '"'
  end,
  test = function(arg)
    local res = vim.tbl_map(regex, list_of(arg))
    return function(it)
      return any_regexp(res, entry_text(it))
    end
  end,
}

S.heading_regexp = {
  name = function(arg)
    return 'Headings matching regexps: "' .. table.concat(list_of(arg), '" OR "') .. '"'
  end,
  test = function(arg)
    local res = vim.tbl_map(regex, list_of(arg))
    return function(it)
      return it.headline ~= nil and any_regexp(res, it.headline.title)
    end
  end,
}

S.file_path = {
  name = function(arg)
    return "File path: " .. table.concat(list_of(arg), " OR ")
  end,
  test = function(arg)
    local res = vim.tbl_map(regex, list_of(arg))
    return function(it)
      return it.filename ~= nil and any_regexp(res, it.filename)
    end
  end,
}

S.property = {
  name = function(arg)
    local a = list_of(arg)
    return "Property: " .. tostring(a[1]) .. (type(a[2]) == "string" and (": " .. a[2]) or "")
  end,
  test = function(arg)
    local a = list_of(arg)
    return function(it)
      local v = property(it, a[1])
      if v == nil then
        return false
      elseif a[2] == nil then
        return true
      elseif type(a[2]) == "function" then
        return a[2](v) and true or false
      end
      return v == tostring(a[2])
    end
  end,
}

S.children = {
  name = function(arg)
    if arg == true then
      return "Items with children"
    elseif arg == false then
      return "Items without children"
    elseif arg == "todo" then
      return "Items with children with TODO keywords"
    end
    return "Items with children with keywords: " .. table.concat(list_of(arg), " OR ")
  end,
  test = function(arg)
    local kws = {}
    for _, k in ipairs(list_of(arg)) do
      kws[k] = true
    end
    return function(it)
      local ch = it.headline and it.headline.children or {}
      if arg == true then
        return #ch > 0
      elseif arg == false then
        return #ch == 0
      end
      local function any(list)
        for _, c in ipairs(list) do
          if (arg == "todo" and c:is_todo()) or (c.todo and kws[c.todo]) or any(c.children or {}) then
            return true
          end
        end
        return false
      end
      return any(ch)
    end
  end,
}

S.log = {
  name = function(arg)
    local names = {
      closed = "Log: Closed",
      clock = "Log: Clocked",
      state = "Log: State changes",
    }
    if arg == true then
      return "Log items"
    elseif arg == false then
      return "Non-log items"
    end
    return names[LOG_TYPES[tostring(arg)] or ""] or "Log items"
  end,
  test = function(arg)
    local want = arg ~= true and arg ~= false and LOG_TYPES[tostring(arg)] or nil
    return function(it)
      local is_log = it.type == "closed" or it.type == "clock" or it.type == "state"
      if arg == false then
        return not is_log
      elseif want then
        return it.type == want
      end
      return is_log
    end
  end,
}

S.anything = {
  name = function()
    return ""
  end,
  test = function()
    return function()
      return true
    end
  end,
}

S.pred = {
  name = function()
    return "Predicate-matching items"
  end,
  test = function(arg)
    local fns = type(arg) == "function" and { arg } or arg
    return function(it)
      for _, fn in ipairs(fns) do
        if fn(it) then
          return true
        end
      end
      return false
    end
  end,
}

M.selectors = S

local compile_group

S["and"] = {
  name = function(arg)
    return select(2, compile_group(arg, " AND "))
  end,
  test = function(arg)
    local tests = {}
    for k, v in pairs(arg) do
      if not SPECIAL[k] then
        local sel = S[k]
        if not sel then
          error("super_agenda: unknown selector " .. k, 0)
        end
        tests[#tests + 1] = sel.test(v)
      end
    end
    return function(it)
      for _, t in ipairs(tests) do
        if not t(it) then
          return false
        end
      end
      return true
    end
  end,
}

S["not"] = {
  name = function(arg)
    return select(2, compile_group(arg))
  end,
  test = function(arg)
    local t = compile_group(arg)
    return function(it)
      return not t(it)
    end
  end,
}

--- Compile the selectors of a group into one OR test and its default name.
---@return fun(it: table): boolean test
---@return string name
compile_group = function(g, joiner)
  local keys = {}
  for k in pairs(g) do
    if not SPECIAL[k] then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  local tests, names = {}, {}
  for _, k in ipairs(keys) do
    local sel = S[k]
    if not sel then
      error("super_agenda: unknown selector " .. k, 0)
    end
    tests[#tests + 1] = sel.test(g[k])
    local n = sel.name(g[k])
    if n and n ~= "" then
      names[#names + 1] = n
    end
  end
  return function(it)
    for _, t in ipairs(tests) do
      if t(it) then
        return true
      end
    end
    return false
  end, table.concat(names, joiner or " and ")
end

---------------------------------------------------------------------------
-- Auto groups: name -> fun(item, arg) -> key|nil, header(key, arg), sort
---------------------------------------------------------------------------

local function earliest_planning(it)
  local hl = it.headline
  local best
  for _, k in ipairs({ "scheduled", "deadline" }) do
    local ts = hl and hl.planning and hl.planning[k]
    if ts and (not best or ts:days() < best:days()) then
      best = ts
    end
  end
  return best
end

local function latest_ts(it)
  local hl = it.headline
  if not hl then
    return nil
  end
  local best
  for _, l in ipairs(vim.list_slice(hl.file.lines, hl.line, hl.body_end or hl.line)) do
    for _, t in ipairs(date.parse_all(l)) do
      local d = t.date
      local v = d:days() * 1440 + (d.hour and d:minutes() or 0)
      if not best or v > best.v then
        best = { v = v, date = d }
      end
    end
  end
  return best and best.date
end

local function day_key(d)
  -- sortable key, shown with date_format
  return string.format("%08d", d:days())
end

local function format_day(key)
  return vim.trim(date.from_days(tonumber(key)):strftime(opts().date_format or "%e %B %Y"))
end

local AUTO = {}

AUTO.auto_category = {
  key = function(it)
    return it.category
  end,
  header = function(k)
    return "Category: " .. k
  end,
}

AUTO.auto_tags = {
  key = function(it)
    local tags = vim.deepcopy(it.tags or {})
    if #tags == 0 then
      return nil
    end
    table.sort(tags)
    return "Tags: " .. table.concat(tags, ", ")
  end,
}

AUTO.auto_todo = {
  key = function(it)
    return it.todo
  end,
  header = function(k)
    return "To-do: " .. k
  end,
}

AUTO.auto_priority = {
  key = function(it)
    return it.priority
  end,
  header = function(k)
    return "Priority: " .. k
  end,
}

AUTO.auto_property = {
  key = function(it, arg)
    return property(it, arg)
  end,
  header = function(k, arg)
    return string.format("%s: %s", arg, k)
  end,
}

AUTO.auto_group = {
  key = function(it)
    return property(it, opts().group_property_name or "agenda-group")
  end,
  header = function(k)
    return "Group: " .. k
  end,
}

AUTO.auto_parent = {
  key = function(it)
    local p = it.headline and it.headline.parent
    return p and p.title or nil
  end,
}

AUTO.auto_outline_path = {
  key = function(it)
    if not it.headline then
      return nil
    end
    local olp = it.headline:outline_path()
    return #olp > 0 and table.concat(olp, "/") or "Top-level headings"
  end,
}

AUTO.auto_dir_name = {
  key = function(it)
    if not it.filename then
      return nil
    end
    return "Directory: " .. vim.fn.fnamemodify(it.filename, ":h:t")
  end,
}

AUTO.auto_planning = {
  key = function(it)
    local d = earliest_planning(it)
    return d and day_key(d) or nil
  end,
  header = format_day,
}

AUTO.auto_ts = {
  key = function(it)
    local d = latest_ts(it)
    return d and day_key(d) or nil
  end,
  header = format_day,
  reverse = function(arg)
    return arg == "reverse"
  end,
}

AUTO.auto_map = {
  key = function(it, arg)
    local ok, v = pcall(arg, it)
    return ok and v ~= nil and v ~= false and tostring(v) or nil
  end,
}

AUTO.ancestor_with_todo = {
  key = function(it, arg)
    local kw, limit, nearest = arg, nil, false
    if type(arg) == "table" then
      kw, limit, nearest = arg[1] or arg.todo, arg.limit, arg.nearest or arg.nearestp
    end
    local found
    local h = it.headline and it.headline.parent
    local hops = 0
    while h and (not limit or hops < limit) do
      hops = hops + 1
      if h.todo == kw then
        found = h.title
        if nearest then
          break
        end
      end
      h = h.parent
    end
    return found
  end,
  header = function(k, arg)
    local kw = type(arg) == "table" and (arg[1] or arg.todo) or arg
    local nearest = type(arg) == "table" and (arg.nearest or arg.nearestp)
    return string.format("%s %s: %s", nearest and "Nearest" or "Ancestor", kw, k)
  end,
}

M.auto = AUTO

---------------------------------------------------------------------------
-- Grouping
---------------------------------------------------------------------------

--- Split `items` into sections (org-super-agenda--group-items).
---@param items table[] agenda items, in display order
---@param groups table[] group specs
---@return { name: string|false, items: table[], order: number, face?: string, transformer?: function }[]
function M.group(items, groups)
  local o = opts()
  local rest = items
  local sections = {}
  local expanded = {}
  for _, raw in ipairs(groups) do
    local g = M.normalize(raw)
    if g.order_multi then
      local om = g.order_multi
      for i = 2, #om do
        local sub = M.normalize(om[i])
        sub.order = sub.order or om[1]
        expanded[#expanded + 1] = sub
      end
    else
      expanded[#expanded + 1] = g
    end
  end
  for _, g in ipairs(expanded) do
    local order = g.order or 0
    local auto_key
    for k in pairs(g) do
      if AUTO[k] then
        auto_key = k
      end
    end
    if auto_key then
      local auto, arg = AUTO[auto_key], g[auto_key]
      local by_key, keys, left = {}, {}, {}
      for _, it in ipairs(rest) do
        local k = not it.grid and auto.key(it, arg) or nil
        if k then
          if not by_key[k] then
            by_key[k] = {}
            keys[#keys + 1] = k
          end
          table.insert(by_key[k], it)
        else
          left[#left + 1] = it
        end
      end
      table.sort(keys)
      if auto.reverse and auto.reverse(arg) then
        keys = vim.fn.reverse(keys)
      end
      for _, k in ipairs(keys) do
        sections[#sections + 1] = {
          name = auto.header and auto.header(k, arg) or k,
          items = by_key[k],
          order = order,
          face = g.face,
          transformer = g.transformer,
        }
      end
      rest = left
    elseif g.discard then
      local test = compile_group(g.discard)
      rest = vim.tbl_filter(function(it)
        return not test(it)
      end, rest)
    else
      local take
      local sel = g
      if g.take then
        take, sel = tonumber(g.take[1]), g.take[2]
      end
      local test, auto_name = compile_group(sel)
      local matching, left = {}, {}
      for _, it in ipairs(rest) do
        if test(it) then
          matching[#matching + 1] = it
        else
          left[#left + 1] = it
        end
      end
      if take then
        auto_name = string.format("%s %d %s", take < 0 and "Last" or "First", math.abs(take), auto_name)
        matching = take < 0 and vim.list_slice(matching, math.max(#matching + take + 1, 1), #matching)
          or vim.list_slice(matching, 1, take)
      end
      local name = g.name
      if name == nil then
        name = auto_name
      end
      sections[#sections + 1] =
        { name = name, items = matching, order = order, face = g.face, transformer = g.transformer }
      rest = left
    end
  end
  sections[#sections + 1] = { name = o.unmatched_name or "Other items", items = rest, order = o.unmatched_order or 99 }
  -- stable sort by order; equal non-zero orders sort by name
  local indexed = {}
  for i, s in ipairs(sections) do
    indexed[i] = { s, i }
  end
  table.sort(indexed, function(a, b)
    local sa, sb = a[1], b[1]
    if sa.order ~= sb.order then
      return sa.order < sb.order
    end
    if sa.order ~= 0 and type(sa.name) == "string" and type(sb.name) == "string" and sa.name ~= sb.name then
      return sa.name < sb.name
    end
    return a[2] < b[2]
  end)
  return vim.tbl_map(function(p)
    return p[1]
  end, indexed)
end

local function add_separator(b, sep, width)
  if sep == nil or sep == "" then
    return
  end
  if vim.fn.strchars(sep) == 1 and sep ~= "\n" then
    b:text(string.rep(sep, math.max((width or 80) - 1, 10)), "OrgSuperAgendaSeparator")
    return
  end
  -- a string: its newlines end lines, as when Emacs inserts it
  local parts = vim.split(sep, "\n", { plain = true })
  for i = 1, #parts - 1 do
    b:text(parts[i], "OrgSuperAgendaSeparator")
  end
  if parts[#parts] ~= "" then
    b:text(parts[#parts], "OrgSuperAgendaSeparator")
  end
end

-- Apply a group's face and transformer to the lines `from`..#b.lines.
local function decorate(b, from, section, it)
  if not (section.face or section.transformer) then
    return
  end
  local row = from - 1
  local line = b.lines[from]
  if not line then
    return
  end
  if section.transformer then
    local ok, new = pcall(section.transformer, line, it)
    if ok and type(new) == "string" then
      b.lines[from] = new
      b.hls = vim.tbl_filter(function(h)
        return h[1] ~= row
      end, b.hls)
      line = new
    end
  end
  if section.face then
    b.hls[#b.hls + 1] = { row, 0, #line, section.face }
  end
end

--- The `org.agenda.render` grouper: renders `rows` as groups.
function M.grouper(b, rows, block, ctx, add)
  if not require("org.extensions").enabled("super_agenda") then
    return false
  end
  local groups = block.super_groups
  if groups == nil then
    groups = opts().groups
  end
  if not groups or groups == false or #groups == 0 or #rows == 0 then
    return false
  end
  local o = opts()
  -- `default` links survive user colors; set here as colorschemes clear them
  vim.api.nvim_set_hl(0, "OrgSuperAgendaHeader", { link = "OrgAgendaHeader", default = true })
  vim.api.nvim_set_hl(0, "OrgSuperAgendaSeparator", { link = "OrgAgendaBlockSeparator", default = true })
  local ok, sections = pcall(M.group, rows, groups)
  if not ok then
    b:text("super_agenda: " .. tostring(sections), "ErrorMsg")
    return false
  end
  for _, s in ipairs(sections) do
    if #s.items > 0 then
      if s.name and s.name ~= "none" and s.name ~= "" then
        add_separator(b, o.header_separator, ctx.width)
        b:add({ { (o.header_prefix or "") .. s.name, "OrgSuperAgendaHeader" } })
      end
      for _, it in ipairs(s.items) do
        local from = #b.lines + 1
        add(it)
        decorate(b, from, s, it)
      end
    end
  end
  add_separator(b, o.final_group_separator, ctx.width)
  return true
end

---------------------------------------------------------------------------
-- Extension
---------------------------------------------------------------------------

function M.setup()
  require("org.agenda.render").grouper = M.grouper
end

function M.health(h, o)
  local ok, err = pcall(M.group, {}, o.groups or {})
  if ok then
    h.ok(string.format("super_agenda: %d group(s)", #(o.groups or {})))
  else
    h.error("super_agenda groups: " .. tostring(err))
  end
end

return M
