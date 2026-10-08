---@mod org.structure.sort Sorting entries and lists
---
--- org-sort-entries / org-sort-list.
---
--- Part of org.structure, which loads it.

local config = require("org.config")
local date = require("org.date")
local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")
local shared = require("org.structure.shared")

local M = require("org.structure")

local buf = shared.buf
local cursor = shared.cursor
local exit_visual = shared.exit_visual
local get_lines = shared.get_lines
local in_visual = shared.in_visual
local is_blank = shared.is_blank
local set_lines = shared.set_lines

---------------------------------------------------------------------------
-- Sorting (org-sort-entries / org-sort-list)
---------------------------------------------------------------------------

local SORT_ENTRIES = {
  { key = "a", label = "alphabetically", kind = "alpha" },
  { key = "n", label = "numerically", kind = "numeric" },
  { key = "p", label = "by priority", kind = "priority" },
  { key = "r", label = "by property", kind = "property" },
  { key = "o", label = "by TODO order", kind = "todo" },
  { key = "f", label = "by function", kind = "func" },
  { key = "t", label = "by time (first timestamp)", kind = "time" },
  { key = "s", label = "by scheduled date", kind = "scheduled" },
  { key = "d", label = "by deadline", kind = "deadline" },
  { key = "c", label = "by creation time", kind = "created" },
  { key = "k", label = "by clocking time", kind = "clock" },
}

local SORT_LIST = {
  { key = "a", label = "alphabetically", kind = "alpha" },
  { key = "n", label = "numerically", kind = "numeric" },
  { key = "t", label = "by time (first timestamp)", kind = "time" },
  { key = "f", label = "by function", kind = "func" },
  { key = "x", label = "by checkbox status", kind = "checkbox" },
}

--- Text as displayed: link descriptions instead of links
--- (org-sort-remove-invisible).
local function visible_text(s)
  s = s:gsub("%[%[([^%]]-)%]%[([^%]]-)%]%]", "%2"):gsub("%[%[([^%]]-)%]%]", "%1")
  return s
end

--- Emacs `string-to-number`: the number at the start of `s`, else 0.
local function string_to_number(s)
  s = s:gsub("^%s+", "")
  local n = s:match("^[+-]?%d+%.?%d*[eE][+-]?%d+") or s:match("^[+-]?%d*%.%d+") or s:match("^[+-]?%d+")
  return tonumber(n or "") or 0
end

--- Minutes of the first timestamp of `text` (active ones first when
--- `active_first`), or nil.
local function first_ts_minutes(text, active_first)
  local items = date.parse_all(text)
  if active_first then
    for _, it in ipairs(items) do
      if it.date.active then
        return it.date:minutes()
      end
    end
  end
  return items[1] and items[1].date:minutes() or nil
end

local function now_minutes()
  local now = date.now()
  return now:minutes()
end

--- Resolve a key or compare function typed at a prompt: a name in
--- `sort_functions`, or a Lua expression returning a function.
local function read_function(prompt, allow_empty)
  local s = utils.input({ prompt = prompt })
  if s == nil then
    return nil, true
  end
  s = vim.trim(s)
  if s == "" then
    if allow_empty then
      return nil
    end
    utils.warn("Missing key extractor")
    return nil, true
  end
  local fns = config.opts.sort_functions or {}
  if type(fns[s]) == "function" then
    return fns[s]
  end
  local chunk = load("return " .. s)
  local ok, fn = pcall(chunk or function() end)
  if ok and type(fn) == "function" then
    return fn
  end
  utils.warn("Not a function: " .. s)
  return nil, true
end

--- Sort `records` ({ key, lines }) by key like Emacs `sort-subr`: stable,
--- `reverse` sorts in decreasing order keeping equal keys in order.
local function sort_records(records, less, reverse)
  for i, r in ipairs(records) do
    r.idx = i
  end
  table.sort(records, function(a, b)
    local x, y = a.key, b.key
    if reverse then
      x, y = y, x
    end
    if less(x, y) then
      return true
    elseif less(y, x) then
      return false
    end
    return a.idx < b.idx
  end)
end

local function default_less(a, b)
  if type(a) == "number" and type(b) == "number" then
    return a < b
  end
  if a == nil or b == nil then
    return a == nil and b ~= nil
  end
  if type(a) ~= type(b) then
    return type(a) == "number"
  end
  if type(a) == "string" then
    return utils.string_lessp(a, b) -- org-sort-function
  end
  return tostring(a) < tostring(b)
end

--- Key extractor for an entry: `h` is the headline.
local function entry_key(kind, prop, with_case, keyfn)
  local case = with_case and function(s)
    return s
  end or string.lower
  return function(h, lines)
    -- the last record stops before trailing blank lines that `body_end` counts
    local body = table.concat(lines, "\n", 1, math.min((h.body_end - h.line) + 1, #lines))
    if kind == "alpha" then
      return case(visible_text(h.title))
    elseif kind == "numeric" then
      return string_to_number(visible_text(h.title))
    elseif kind == "time" then
      return first_ts_minutes(body, true) or now_minutes()
    elseif kind == "created" then
      for _, l in ipairs(vim.split(body, "\n")) do
        local ts = l:match("^%s*(%[%d%d%d%d%-%d%d%-%d%d[^%]]*%])")
        if ts then
          local d = date.parse(ts)
          if d then
            return d:minutes()
          end
        end
      end
      return now_minutes()
    elseif kind == "scheduled" then
      return h.planning.scheduled and h.planning.scheduled:minutes() or now_minutes()
    elseif kind == "deadline" then
      return h.planning.deadline and h.planning.deadline:minutes() or now_minutes()
    elseif kind == "priority" then
      return require("org.priority").value(h)
    elseif kind == "todo" then
      local todo_cfg = h.file.settings.todo
      local n = #todo_cfg.keywords
      local kw = h.todo and todo_cfg:get(h.todo)
      if not kw then
        return 99
      end
      local len = n - kw.index + 1
      return kw.done and 99 + len or 99 - len
    elseif kind == "property" then
      return h:get_property(prop) or ""
    elseif kind == "clock" then
      return h:clocked_minutes(nil, nil, true) or 0
    elseif kind == "func" then
      local v = keyfn(h, lines)
      if type(v) == "string" then
        v = case(v)
      end
      return v
    end
  end
end

--- Key extractor for a list item.
local function item_key(kind, with_case, keyfn)
  local case = with_case and function(s)
    return s
  end or string.lower
  return function(it, lines)
    local first = lines[1]
    local after = first:match("^%s*[-+*0-9.)]+[ \t]+%[[- X]%][ \t]+(.*)$")
      or first:match("^%s*[-+*0-9.)]+[ \t]+(.*)$")
      or ""
    if kind == "alpha" then
      return case(visible_text(after))
    elseif kind == "numeric" then
      return string_to_number(visible_text(after))
    elseif kind == "time" then
      local timer = after:match("^([-+]?%d+:%d%d:%d%d)%s+::")
      if timer then
        local sign, h, m, s = timer:match("^([-+]?)(%d+):(%d%d):(%d%d)$")
        local secs = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
        return sign == "-" and -secs or secs
      end
      local ts = first_ts_minutes(first, true)
      return ts and ts * 60 or now_minutes() * 60
    elseif kind == "checkbox" then
      local box = first:match("^%s*[-+*0-9.)]+([ \t]+%[[- X]%])[ \t]")
      return box or ""
    elseif kind == "func" then
      local v = keyfn(it, lines)
      if type(v) == "string" then
        v = case(v)
      end
      return v
    end
  end
end

--- Sort the siblings of the list item at `lnum` (org-sort-list).
local function sort_list(bufnr, lnum, choice, with_case)
  local lists = require("org.lists")
  local keyfn, cmp
  if choice.kind == "func" then
    local abort
    keyfn, abort = read_function("Function for extracting keys: ")
    if abort then
      return
    end
    cmp, abort = read_function("Function for comparing keys (empty for default): ", true)
    if abort then
      return
    end
  end
  local item = lists.item_at(bufnr, lnum)
  local sibs = lists.siblings(item)
  local key = item_key(choice.kind, with_case, keyfn)
  -- records are the items without trailing blank lines, which stay put
  local records = {}
  for _, s in ipairs(sibs) do
    local stop = s.end_lnum
    records[#records + 1] = { lines = get_lines(bufnr, s.lnum, stop), s = s.lnum, e = stop }
    records[#records].key = key(s, records[#records].lines)
  end
  local slots = {}
  for i, r in ipairs(records) do
    slots[i] = { s = r.s, e = r.e }
  end
  sort_records(records, cmp or default_less, choice.reverse)
  for i = #slots, 1, -1 do
    set_lines(bufnr, slots[i].s, slots[i].e, records[i].lines)
  end
  lists.repair(bufnr, sibs[1].lnum)
end

--- Sort entries (org-sort-entries): the children of the current headline,
--- the top-level entries before the first headline, or the entries of the
--- Visual selection. With a count (C-u), sorting is case-sensitive.
--- `sorting_type` (a key of the menu, e.g. "a" or "T") sorts entries that
--- way without asking.
---@param sorting_type? string
function M.sort(sorting_type)
  if type(sorting_type) ~= "string" then
    sorting_type = nil
  end
  local bufnr = buf()
  local lnum = cursor()[1]
  local line = vim.api.nvim_get_current_line()
  local lists = require("org.lists")
  local visual = in_visual()
  local vs, ve
  if visual then
    vs, _, ve = utils.visual_range()
    exit_visual()
  end
  local with_case = vim.v.count > 0
  local on_item = not visual and not parser.headline_level(line) and lists.item_at(bufnr, lnum)
  local menu_items = {}
  for _, it in ipairs(on_item and SORT_LIST or SORT_ENTRIES) do
    menu_items[#menu_items + 1] = { key = it.key, label = it.label, value = { kind = it.kind, reverse = false } }
    menu_items[#menu_items + 1] =
      { key = it.key:upper(), label = it.label .. " (reverse)", value = { kind = it.kind, reverse = true } }
  end
  if on_item then
    local choice = require("org.ui").menu({ title = "Sort plain list", items = menu_items })
    if choice then
      sort_list(bufnr, lnum, choice, with_case)
    end
    return
  end
  local file = files.get_buffer(bufnr)
  -- the records: siblings at the level of the first entry in the range
  local start, stop, what
  if visual then
    local first
    for _, h in ipairs(file.headlines) do
      if h.line >= vs then
        first = h
        break
      end
    end
    if not first or first.line > ve then
      utils.warn("Nothing to sort")
      return
    end
    local last_hl = file:headline_at(ve)
    start, stop, what = first.line, last_hl.end_line, "region"
    -- the end of the subtree without its trailing blank lines
    while stop > start and is_blank(get_lines(bufnr, stop, stop)[1]) do
      stop = stop - 1
    end
  else
    local hl = file:headline_at(lnum)
    if hl then
      if #hl.children == 0 then
        utils.warn("Nothing to sort")
        return
      end
      start, stop, what = hl.children[1].line, hl.end_line, "children"
      -- like org-sort-entries: one of the trailing blank lines stays in
      -- the range, so that it goes with the last record
      local trimmed = stop
      while trimmed > start and is_blank(get_lines(bufnr, trimmed, trimmed)[1]) do
        trimmed = trimmed - 1
      end
      stop = math.min(stop, trimmed + 1)
    else
      if not file.headlines[1] then
        utils.warn("Nothing to sort")
        return
      end
      start, stop, what = file.headlines[1].line, vim.api.nvim_buf_line_count(bufnr), "top-level"
    end
  end
  local level = parser.headline_level(get_lines(bufnr, start, start)[1])
  local heads = {}
  for _, h in ipairs(file.headlines) do
    if h.line >= start and h.line <= stop then
      if h.level < level then
        utils.warn("Region to sort contains a level above the first entry")
        return
      end
      if h.level == level then
        heads[#heads + 1] = h
      end
    end
  end
  local choice
  if sorting_type then
    -- (org-sort-entries nil ?a): the sorting type without asking
    for _, it in ipairs(menu_items) do
      if it.key == sorting_type then
        choice = it.value
      end
    end
  else
    choice = require("org.ui").menu({ title = "Sort " .. what, items = menu_items })
  end
  if not choice then
    return
  end
  local prop, keyfn, cmp
  if choice.kind == "property" then
    prop = utils.input({ prompt = "Property: " })
    if not prop or vim.trim(prop) == "" then
      return
    end
    prop = vim.trim(prop)
  elseif choice.kind == "func" then
    local abort
    keyfn, abort = read_function("Function for extracting keys: ")
    if abort then
      return
    end
    cmp, abort = read_function("Function for comparing keys (empty for default): ", true)
    if abort then
      return
    end
  end
  local key = entry_key(choice.kind, prop, with_case, keyfn)
  local records = {}
  for i, h in ipairs(heads) do
    local e = heads[i + 1] and heads[i + 1].line - 1 or stop
    local lines = get_lines(bufnr, h.line, e)
    records[#records + 1] = { lines = lines, key = key(h, lines) }
  end
  sort_records(records, cmp or default_less, choice.reverse)
  local out = {}
  for _, r in ipairs(records) do
    vim.list_extend(out, r.lines)
  end
  set_lines(bufnr, start, stop, out)
  vim.api.nvim_win_set_cursor(0, { math.min(lnum, vim.api.nvim_buf_line_count(bufnr)), cursor()[2] })
  utils.notify("Sorting entries...done")
end
