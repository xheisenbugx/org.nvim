---@mod org.capture.place Placing the captured text at its target
---
--- Part of org.capture, which loads it: inserting an entry, item,
--- checkitem, table line or plain text at the resolved target.

local config = require("org.config")
local edit = require("org.edit")
local files = require("org.files")
local shared = require("org.capture.shared")

local M = require("org.capture")

local get_line = shared.get_line
local is_blank = shared.is_blank
local is_empty_buffer = shared.is_empty_buffer
local mark_pos = shared.mark_pos
local put = shared.put
local release = shared.release

---------------------------------------------------------------------------
-- Placing the captured text
---------------------------------------------------------------------------

--- Does `org-blank-before-new-entry` let org-back-over-empty-lines move?
local function heading_blank_setting()
  local b = config.opts.blank_before_new_entry
  local v = type(b) == "table" and b.heading or b
  return v ~= false and v ~= nil
end

--- org--blank-before-heading-p at the insertion point after line `at`.
local function blank_before_heading_p(bufnr, at)
  local b = config.opts.blank_before_new_entry
  local v = type(b) == "table" and b.heading or b
  if v ~= "auto" then
    return v == true
  end
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(math.max(at + 1, 1))
  if not hl then
    hl = file.headlines[1]
    if not hl then
      return false
    end
  end
  if hl.line > 1 then
    return is_blank(get_line(bufnr, hl.line - 1))
  end
  local nxt = file.headlines[2]
  return nxt ~= nil and is_blank(get_line(bufnr, nxt.line - 1))
end

--- org-capture-empty-lines-before: replace the blank lines before the
--- insertion point (after line `at`) by `n` blank lines. Returns the new
--- insertion point.
local function empty_lines_before(bufnr, at, n)
  if heading_blank_setting() then
    local b = at
    while b > 0 and is_blank(get_line(bufnr, b)) do
      b = b - 1
    end
    if b < at then
      vim.api.nvim_buf_set_lines(bufnr, b, at, false, {})
      at = b
    end
  end
  if n > 0 and not is_empty_buffer(bufnr) then
    local blanks = {}
    for _ = 1, n do
      blanks[#blanks + 1] = ""
    end
    vim.api.nvim_buf_set_lines(bufnr, at, at, false, blanks)
    at = at + n
  end
  return at
end

--- org-capture-empty-lines-after: exactly `n` blank lines after line `last`.
local function empty_lines_after(bufnr, last, n)
  local e = last
  local count = vim.api.nvim_buf_line_count(bufnr)
  while e < count and is_blank(get_line(bufnr, e + 1)) do
    e = e + 1
  end
  local blanks = {}
  if e < count or n > 0 then
    for _ = 1, n do
      blanks[#blanks + 1] = ""
    end
  end
  vim.api.nvim_buf_set_lines(bufnr, last, e, false, blanks)
end

--- Split the line at (line, col) when col is inside it (Emacs inserts a
--- newline at the exact position); returns the insertion point (the text
--- goes after the returned line number).
local function split_at(bufnr, line, col)
  local l = get_line(bufnr, line) or ""
  if col <= 0 then
    return line - 1
  end
  if col >= #l then
    return line
  end
  vim.api.nvim_buf_set_lines(bufnr, line - 1, line, false, { l:sub(1, col), l:sub(col + 1) })
  return line
end

local function first_list(bufnr, s, e)
  if e < s then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local lists = require("org.lists").parse_region(lines, s, e)
  local l = lists[1]
  if not l then
    return nil
  end
  local first, last = l.items[1], l.items[1]
  for _, it in ipairs(l.items) do
    if it.end_lnum > last.end_lnum then
      last = it
    end
  end
  return {
    first = first.lnum,
    last = math.max(last.end_lnum, last.lnum),
    indent = first.indent,
    ordered = first.is_ordered,
  }
end

--- End of the metadata after a headline (org-end-of-meta-data): planning
--- and properties; with `full`, also clock lines, drawers and blank lines.
local function meta_end(bufnr, hl, full)
  local at = edit.meta_end(hl)
  if not full then
    return at
  end
  local n = hl.body_end
  local i = at + 1
  while i <= n do
    local l = get_line(bufnr, i)
    if is_blank(l) or l:match("^%s*CLOCK:") then
      i = i + 1
    elseif l:match("^%s*:[%w_-]+:%s*$") and not l:match("^%s*:END:%s*$") then
      local j = i + 1
      while j <= n and not get_line(bufnr, j):match("^%s*:END:%s*$") do
        j = j + 1
      end
      if j > n then
        break
      end
      i = j + 1
    else
      break
    end
  end
  return i - 1
end

local function place_entry(bufnr, loc, tpl, lines, pos_line, pos_col)
  local file = files.get_buffer(bufnr)
  local level, at
  if loc.insert_here then
    local hl = file:headline_at(pos_line)
    level = hl and hl.level or 1
    at = pos_col == 0 and pos_line - 1 or pos_line
  elseif loc.target_entry_p then
    local hl = file:headline_at(pos_line)
    level = hl.level + 1
    at = tpl.prepend and hl.body_end or hl.end_line
  elseif tpl.prepend then
    at = file.headlines[1] and file.preamble_end or #file.lines
    level = 1
  else
    at = #file.lines
    level = 1
  end
  if is_empty_buffer(bufnr) then
    at = 0
  end
  local n = tpl.empty_lines_before or tpl.empty_lines
  if n == nil and blank_before_heading_p(bufnr, at) and not is_blank(get_line(bufnr, at)) and at > 0 then
    n = 1
  end
  at = empty_lines_before(bufnr, at, n or 0)
  local new = edit.relevel(lines, level)
  at = put(bufnr, at, new)
  empty_lines_after(bufnr, at + #new, tpl.empty_lines_after or tpl.empty_lines or 0)
  return at + 1
end

local function place_plain(bufnr, loc, tpl, lines, pos_line, pos_col)
  local file = files.get_buffer(bufnr)
  local at
  if loc.insert_here then
    at = pos_col == 0 and pos_line - 1 or pos_line
  elseif loc.target_entry_p then
    local hl = file:headline_at(pos_line)
    at = tpl.prepend and meta_end(bufnr, hl, true) or hl.body_end
  elseif loc.exact then
    at = split_at(bufnr, pos_line, pos_col)
  else
    at = tpl.prepend and 0 or #file.lines
  end
  if is_empty_buffer(bufnr) then
    at = 0
  end
  at = empty_lines_before(bufnr, at, tpl.empty_lines_before or tpl.empty_lines or 0)
  at = put(bufnr, at, lines)
  empty_lines_after(bufnr, at + #lines, tpl.empty_lines_after or tpl.empty_lines or 0)
  return at + 1
end

local function place_item(bufnr, loc, tpl, lines, pos_line, pos_col)
  local lists = require("org.lists")
  local file = files.get_buffer(bufnr)
  local s, e
  if loc.insert_here then
    s, e = pos_line, pos_line
  elseif loc.target_entry_p then
    local hl = file:headline_at(pos_line)
    s, e = hl.line + 1, hl.body_end
  elseif loc.exact then
    local hl = file:headline_at(pos_line)
    s, e = pos_line, hl and hl.body_end or #file.lines
  else
    s, e = 1, #file.lines
  end
  local list = not loc.insert_here and first_list(bufnr, s, e) or nil
  local at
  if list then
    at = tpl.prepend and list.first - 1 or list.last
  elseif loc.insert_here then
    at = pos_col == 0 and pos_line - 1 or pos_line
  elseif not tpl.prepend then
    at = e
  elseif loc.target_entry_p then
    at = math.max(meta_end(bufnr, file:headline_at(pos_line), false), s - 1)
  elseif not file:headline_at(s) then
    at = s - 1
  else
    at = math.max(meta_end(bufnr, file:headline_at(s), false), s - 1)
  end
  if is_empty_buffer(bufnr) then
    at = 0
  end
  local eb = tpl.empty_lines_before or tpl.empty_lines
  local ea = tpl.empty_lines_after or tpl.empty_lines
  if not (list and tpl.prepend) then
    at = empty_lines_before(bufnr, at, list and math.min(1, eb or 0) or (eb or 0))
  end
  local new = vim.deepcopy(lines)
  -- the template's own indentation is removed (org-remove-indentation)
  local common
  for _, l in ipairs(new) do
    if not is_blank(l) then
      local ind = #l:match("^%s*")
      common = common and math.min(common, ind) or ind
    end
  end
  for i, l in ipairs(new) do
    new[i] = l:sub((common or 0) + 1)
    if list and not is_blank(new[i]) then
      new[i] = string.rep(" ", list.indent) .. new[i]
    end
  end
  if list and tpl.prepend then
    -- prepending must not change the type of the existing list
    local item = lists.parse_item_line(new[1])
    if item and item.is_ordered ~= list.ordered then
      new[1] = new[1]:gsub("^(%s*)(%S+)", "%1" .. (list.ordered and "1." or "-"), 1)
    end
  end
  at = put(bufnr, at, new)
  if list then
    lists.repair(bufnr, at + 1)
  end
  if not (list and not tpl.prepend) then
    local n = list and math.min(1, ea or 0) or (ea or 0)
    empty_lines_after(bufnr, at + #new, n)
  end
  return at + 1
end

local function place_table_line(bufnr, loc, tpl, lines, pos_line)
  local file = files.get_buffer(bufnr)
  local s, e
  if loc.insert_here then
    s, e = pos_line, pos_line
  elseif not loc.target_entry_p then
    s, e = 1, #file.lines
  else
    local hl = file:headline_at(pos_line)
    s, e = hl.line + 1, hl.body_end
  end
  if loc.exact and not loc.insert_here then
    local hl = file:headline_at(pos_line)
    s, e = pos_line, hl and hl.body_end or #file.lines
  end
  -- the first table (with a data line) in the region
  local ts, te
  local i = s
  while i <= e do
    local l = get_line(bufnr, i)
    if l and l:match("^%s*|") then
      local j = i
      local has_data = false
      while j + 1 <= #file.lines and (get_line(bufnr, j + 1) or ""):match("^%s*|") do
        j = j + 1
      end
      for k = i, j do
        if not get_line(bufnr, k):match("^%s*|%-") then
          has_data = true
        end
      end
      if has_data then
        ts, te = i, j
        break
      end
      i = j + 1
    else
      i = i + 1
    end
  end
  if not ts then
    -- no table: create one with an empty header
    local at = loc.insert_here and pos_line - 1 or e
    if is_empty_buffer(bufnr) then
      at = 0
    end
    at = put(bufnr, at, { "|   |", "|---|" })
    ts, te = at + 1, at + 2
  end
  local at
  local pos = tpl.table_line_pos
  if loc.insert_here then
    at = te
  elseif pos and pos:match("^(I+)([-+]%d+)") then
    local roman, delta = pos:match("^(I+)([-+]%d+)")
    delta = tonumber(delta)
    local nth, hline = 0, nil
    for k = ts, te do
      if get_line(bufnr, k):match("^%s*|%-") then
        nth = nth + 1
        if nth == #roman then
          hline = k - ts + 1
          break
        end
      end
    end
    if not hline then
      error(string.format("Invalid table line specification %q", pos), 0)
    end
    at = ts - 1 + hline + delta + (delta < 0 and 1 or 0) - 1
  elseif tpl.prepend then
    at = ts - 1
    for k = ts, te do
      if get_line(bufnr, k):match("^%s*|%-") then
        at = te
        for k2 = k + 1, te do
          if not get_line(bufnr, k2):match("^%s*|%-") then
            at = k2 - 1
            break
          end
        end
        break
      end
    end
  else
    at = te
  end
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, lines)
  pcall(require("org.table").align_at, bufnr, at + 1)
  return at + 1
end

--- Store `lines` at a resolved location. Returns the first stored line.
function M.place(loc, tpl, lines)
  local bufnr = loc.bufnr
  local line, col = mark_pos(loc)
  if loc.mark and not line then
    return nil
  end
  if loc.target_entry_p and not loc.insert_here then
    local hl = line and files.get_buffer(bufnr):headline_at(line)
    if not hl or hl.line ~= line then
      return nil
    end
  end
  line, col = line or 1, col or 0
  local ttype = tpl.type or "entry"
  local first
  if ttype == "entry" then
    first = place_entry(bufnr, loc, tpl, lines, line, col)
  elseif ttype == "item" or ttype == "checkitem" then
    first = place_item(bufnr, loc, tpl, lines, line, col)
  elseif ttype == "table-line" then
    first = place_table_line(bufnr, loc, tpl, lines, line)
  else
    first = place_plain(bufnr, loc, tpl, lines, line, col)
  end
  -- update statistics cookies around the new text
  pcall(require("org.lists").update_statistics_for, bufnr, first)
  return first
end

--- Resolve the target of `tpl` and insert `lines` there (no capture
--- buffer). Returns the first inserted line.
function M.insert(bufnr, tpl, lines, ctx)
  ctx = ctx or {}
  local loc, err = M.resolve_target(tpl, ctx)
  if not loc then
    error(err, 0)
  end
  if bufnr and loc.bufnr ~= bufnr then
    error("capture target is not in buffer " .. bufnr, 0)
  end
  local l = M.place(loc, tpl, lines)
  release(loc)
  return l
end
