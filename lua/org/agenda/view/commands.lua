---@mod org.agenda.view.commands Helpers of the agenda commands: block, day and span at the cursor, marks, queries
---
--- Part of org.agenda.view, which loads it.

local config = require("org.config")
local date = require("org.date")
local files = require("org.files")
local render = require("org.agenda.render")
local utils = require("org.utils")
local shared = require("org.agenda.view.shared")

local M = require("org.agenda.view")

local current_span = shared.current_span
local finish = shared.finish
local has_agenda_block = shared.has_agenda_block
local with_remote_undo = shared.with_remote_undo

--- The type of the block at the cursor ("agenda", "todo", ...).
local function block_type_at_cursor()
  if not (M.state.view and M.state.win and vim.api.nvim_win_is_valid(M.state.win)) then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(M.state.win)[1]
  local idx = 1
  for i, l in ipairs(M.state.block_starts or { 1 }) do
    if l <= lnum then
      idx = i
    end
  end
  local b = M.state.view.blocks[idx] or M.state.view.blocks[1]
  return b and b.type
end
M.block_type_at_cursor = block_type_at_cursor

--- org-agenda-check-type: error unless the block at point is a date agenda.
local function check_agenda_type()
  local t = block_type_at_cursor()
  if t == "agenda" then
    return true
  end
  local names = { tags_todo = "tags", stuck = "tags" }
  utils.error(string.format("Not allowed in ’%s’-type agenda buffer or component", names[t] or t or "nil"))
  return false
end

--- Toggle the display of habits (org-habit-toggle-habits).
function M.toggle_habits()
  if not check_agenda_type() then
    return
  end
  local h = config.opts.agenda.habits
  h.show_habits = not h.show_habits
  M.redo()
  utils.notify("Habits turned " .. (h.show_habits and "on" or "off"))
end

--- Toggle habits, or with `all_today` whether today shows all habits or
--- only the ones due (org-habit-toggle-display-in-agenda, Emacs `K` and
--- `C-u K`).
function M.toggle_habits_display(all_today)
  if not all_today then
    return M.toggle_habits()
  end
  if not check_agenda_type() then
    return
  end
  local h = config.opts.agenda.habits
  h.show_all_today = not h.show_all_today
  if h.show_habits then
    M.redo()
  end
end

local function move_to_item(dir)
  if not M.state.buf then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local count = vim.api.nvim_buf_line_count(M.state.buf)
  local l = lnum + dir
  while l >= 1 and l <= count do
    if M.state.line_items[l] then
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      return
    end
    l = l + dir
  end
end

--- Day of the line at the cursor: the item's day, else the nearest date
--- header above (nil outside date-based blocks).
function M.day_at_cursor()
  if not M.state.win or not vim.api.nvim_win_is_valid(M.state.win) then
    local item = M.item_at_cursor()
    return item and item.day or nil
  end
  return M.day_at_line(vim.api.nvim_win_get_cursor(M.state.win)[1])
end

--- Day of agenda line `lnum`: its item's day, else the nearest date header
--- above (nil outside date-based blocks).
function M.day_at_line(lnum)
  local item = M.state.line_items[lnum]
  if item and item.day then
    return item.day
  end
  for l = lnum, 1, -1 do
    if M.state.day_lines[l] then
      return M.state.day_lines[l]
    end
  end
  return nil
end

--- The date at the cursor for a capture (org-get-cursor-date): the day
--- of the line; with `with_time`, at the time of the item at point, else
--- the current time of day. Nil outside date-based blocks.
---@param with_time? boolean
---@return org.Date|nil
function M.cursor_date(with_time)
  local day = has_agenda_block() and M.day_at_cursor() or nil
  if not day then
    return nil
  end
  if not with_time then
    return date.from_days(day)
  end
  local item = M.item_at_cursor()
  local minutes = item and item.time
  if not minutes then
    local now = os.date("*t")
    minutes = now.hour * 60 + now.min
  end
  return date.from_days(day, { hour = math.floor(minutes / 60), min = minutes % 60 })
end

--- Change the span (org-agenda-change-time-span): the span starts where
--- `org-agenda-compute-starting-span` puts it for the day at point.
local function set_span(span)
  if not has_agenda_block() then
    require("org.agenda").open_agenda({ span = span, anchor = M.state.anchor })
    return
  end
  local day = M.day_at_cursor() or M.state.anchor or date.today_days()
  if span then
    M.state.anchor = render.starting_day(span, day)
  else
    M.state.anchor = nil
  end
  M.state.span = span
  M.redo()
  utils.notify("Switched to " .. tostring(span or current_span()) .. " view")
end

local function shift_anchor(dir)
  if not has_agenda_block() then
    utils.warn("Not in a date-based agenda view")
    return
  end
  local n = math.max(vim.v.count, 1) * dir
  local first = M.state.info[1] and M.state.info[1].from
  for _, inf in pairs(M.state.info) do
    first = inf.from
    break
  end
  M.state.anchor = render.shift_anchor(current_span(), first or M.state.anchor or date.today_days(), n)
  M.refresh()
  local l1
  for l in pairs(M.state.day_lines) do
    if not l1 or l < l1 then
      l1 = l
    end
  end
  if l1 then
    pcall(vim.api.nvim_win_set_cursor, 0, { l1, 0 })
  end
end

local function all_tags_in_view()
  local set = {}
  for _, it in pairs(M.state.line_items) do
    for _, t in ipairs(it.tags or {}) do
      set[t] = true
    end
  end
  local out = vim.tbl_keys(set)
  table.sort(out)
  return out
end

--- Tags offered by the tag filter: the view's and, with group_tags, the
--- group tags (which filter for their members, org-agenda-filter-expand-tags).
local function filter_tag_names()
  local set = {}
  for _, t in ipairs(all_tags_in_view()) do
    set[t] = true
  end
  for g in pairs(require("org.tags").match_groups() or {}) do
    set[g] = true
  end
  local out = vim.tbl_keys(set)
  table.sort(out)
  return out
end

local function all_categories_in_view()
  local set = {}
  for _, it in pairs(M.state.line_items) do
    if it.category and it.category ~= "" then
      set[it.category] = true
    end
  end
  local out = vim.tbl_keys(set)
  table.sort(out)
  return out
end

--- Marked entries, parents before children (org-agenda-bulk-action).
local function marked_items()
  local list = vim.tbl_values(M.state.marks)
  table.sort(list, function(a, b)
    local fa, fb = a.filename or "", b.filename or ""
    if fa ~= fb then
      return fa < fb
    end
    return a.lnum > b.lnum
  end)
  return list
end

local function bulk(fn, persistent)
  local list = marked_items()
  local bufs = {}
  local n = 0
  for _, item in ipairs(list) do
    -- a %%(sexp) line before the first heading has no entry to act on
    local target = item.headline and M.resolve_target(item)
    if target then
      with_remote_undo(target.bufnr, function()
        fn(target, item)
      end)
      bufs[target.bufnr] = true
      n = n + 1
    end
  end
  if not persistent then
    M.state.marks = {}
  end
  finish(vim.tbl_keys(bufs))
  utils.notify(string.format("%d entries processed", n))
end

local function add_remove_tag(target, tag, add)
  local file = files.get_buffer(target.bufnr)
  local hl = file:headline_at(target.lnum)
  if not hl then
    return
  end
  local tags = vim.deepcopy(hl.tags)
  local idx
  for i, t in ipairs(tags) do
    if t == tag then
      idx = i
    end
  end
  if add and not idx then
    tags[#tags + 1] = tag
  elseif not add and idx then
    table.remove(tags, idx)
  else
    return
  end
  require("org.edit").update_headline(target.bufnr, hl.line, { tags = tags })
end

local function toggle(field, label, value)
  if M.state[field] then
    M.state[field] = false
  else
    M.state[field] = value == nil and true or value
  end
  M.redo()
  utils.notify(label .. (M.state[field] and " on" or " off"))
end

--- Move to the next/previous line for which `pred(lnum)` holds.
local function move_to_line(dir, pred)
  if not M.state.buf then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local count = vim.api.nvim_buf_line_count(M.state.buf)
  local l = lnum + dir
  while l >= 1 and l <= count do
    if pred(l) then
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      return true
    end
    l = l + dir
  end
  return false
end

--- First lines of the agenda blocks.
local function block_starts()
  return M.state.block_starts or { 1 }
end

--- The first query block (search / tags) of the view.
local function query_block()
  for _, b in ipairs(M.state.view and M.state.view.blocks or {}) do
    if b.type == "search" or b.type == "tags" or b.type == "tags_todo" then
      return b
    end
  end
end

--- org-agenda-manipulate-query: add a term to a search or tags view.
---@param sign "+"|"-"
---@param regexp boolean
---@param term? string prompted for when nil
function M.manipulate_query(sign, regexp, term)
  local b = query_block()
  if not b and has_agenda_block() then
    -- like Emacs: in a date agenda, [ ] { } include inactive timestamps
    M.state.inactive = true
    M.redo()
    utils.notify("Display now includes inactive timestamps as well")
    return
  elseif not b then
    utils.warn("Can only manipulate a search or tags query")
    return
  end
  if not term then
    local what = regexp and "regexp" or (b.type == "search" and "word" or "tag")
    local prompt = string.format("%s %s: ", sign == "+" and "Add" or "Exclude", what)
    if regexp or b.type == "search" then
      term = utils.input({ prompt = prompt })
    else
      term = utils.input_complete(prompt, all_tags_in_view())
    end
  end
  if not term or vim.trim(term) == "" then
    return
  end
  term = vim.trim(term)
  local add = sign .. (regexp and ("{" .. term .. "}") or term)
  local match = b.match or ""
  if b.type == "search" then
    match = vim.trim(match)
    local flags, rest = match:match("^([%*!:]*)%s*(.*)$")
    if rest ~= "" and not rest:match("^[%+%-{]") then
      -- turn a plain phrase into a boolean query term
      rest = rest:find("%s") and ('+"' .. rest .. '"') or ("+" .. rest)
    end
    b.match = vim.trim(flags .. rest .. " " .. add)
    -- the query is kept in a register for custom commands
    -- (org-agenda-query-register)
    local reg = config.opts.agenda.query_register
    if type(reg) == "string" and reg ~= "" then
      pcall(vim.fn.setreg, reg, b.match)
    end
  else
    local tags_part, todo_part = match:match("^(.-)(/.*)$")
    b.match = (tags_part or match) .. add .. (todo_part or "")
  end
  M.redo()
end

local function org_buffers()
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "org" then
      out[#out + 1] = b
    end
  end
  return out
end

--- Links in an entry's headline and body (headline first).
function M.entry_links(target)
  local file = files.get_buffer(target.bufnr)
  local hl = file:headline_at(target.lnum)
  if not hl then
    return {}
  end
  local links = require("org.links")
  local out = {}
  for i = hl.line, hl.body_end do
    vim.list_extend(out, links.parse_links(file.lines[i] or ""))
  end
  return out
end

shared.add_remove_tag = add_remove_tag
shared.all_categories_in_view = all_categories_in_view
shared.all_tags_in_view = all_tags_in_view
shared.block_starts = block_starts
shared.bulk = bulk
shared.filter_tag_names = filter_tag_names
shared.move_to_item = move_to_item
shared.move_to_line = move_to_line
shared.org_buffers = org_buffers
shared.set_span = set_span
shared.shift_anchor = shift_anchor
shared.toggle = toggle
