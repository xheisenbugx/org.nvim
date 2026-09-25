---@mod org.lists Plain lists, checkboxes and statistics cookies
---
--- Lists are parsed on demand per section (the lines between two
--- headlines), following org's rules: an item ends at the first non-blank
--- line indented at or left of its bullet, at a headline, or after two
--- consecutive blank lines.

local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")

local M = {}

---@class org.ListItem
---@field lnum integer
---@field end_lnum integer last line of the item, children included (trailing blanks excluded)
---@field indent integer
---@field bullet string "-", "+", "*", "1." or "1)"
---@field is_ordered boolean
---@field counter integer|nil value of a [@N] counter
---@field checkbox string|nil " ", "X" or "-"
---@field tag string|nil description list term
---@field text string text after bullet/counter/checkbox
---@field content_col integer 0-based column where the item text starts
---@field children org.ListItem[]
---@field parent org.ListItem|nil
---@field list { items: org.ListItem[] }

---------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------

--- Parse a single line as an item. Returns nil for non-items.
function M.parse_item_line(line)
  local ind, bullet, gap, rest = line:match("^(%s*)([%-+*])(%s+)(.*)$")
  if not ind then
    ind, bullet = line:match("^(%s*)([%-+*])$")
    gap, rest = "", ""
  end
  if not ind then
    ind, bullet, gap, rest = line:match("^(%s*)(%d+[.)])(%s+)(.*)$")
    if not ind then
      ind, bullet = line:match("^(%s*)(%d+[.)])$")
      gap, rest = "", ""
    end
  end
  if not ind then
    return nil
  end
  if bullet == "*" and ind == "" then
    return nil -- headline
  end
  local item = {
    indent = #ind,
    bullet = bullet,
    is_ordered = bullet:match("^%d") ~= nil,
  }
  local col = #ind + #bullet + #gap
  local counter, after = rest:match("^%[@(%d+)%]%s*(.*)$")
  if counter then
    item.counter = tonumber(counter)
    col = col + (#rest - #after)
    rest = after
  end
  local cb, after2 = rest:match("^%[([ xX%-])%](.*)$")
  if cb and (after2 == "" or after2:match("^%s")) then
    item.checkbox = cb == "x" and "X" or cb
    local stripped = after2:gsub("^%s+", "")
    col = col + (#rest - #stripped)
    rest = stripped
  end
  local tag, desc = rest:match("^(.-)%s+::%s+(.*)$")
  if not tag then
    tag = rest:match("^(.-)%s+::$")
    desc = tag and "" or nil
  end
  if tag then
    item.tag = tag
  end
  item.text = rest
  item.content_col = col
  return item
end

local function indent_of(line)
  return #(line:match("^(%s*)"))
end

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

--- Parse all lists within lines[from..to].
---@return { items: org.ListItem[] }[] lists, org.ListItem[] all items (in order)
function M.parse_region(lines, from, to)
  local lists, all = {}, {}
  local stack = {} -- open items
  local current -- current list
  local blanks = 0
  local in_block = false
  for i = from, to do
    local line = lines[i]
    if is_blank(line) then
      blanks = blanks + 1
      if blanks >= 2 then
        stack, current = {}, nil
      end
    else
      blanks = 0
      local ind = indent_of(line)
      local item = not in_block and M.parse_item_line(line) or nil
      if in_block then
        if line:match("^%s*#%+[Ee][Nn][Dd]") then
          in_block = false
        end
        -- block content belongs to the enclosing item when indented
        while #stack > 0 and ind <= stack[#stack].indent and not line:match("^%s*#%+") do
          table.remove(stack)
        end
      elseif item then
        while #stack > 0 and stack[#stack].indent >= ind do
          table.remove(stack)
        end
        item.lnum = i
        item.end_lnum = i
        item.children = {}
        item.parent = stack[#stack]
        if item.parent then
          table.insert(item.parent.children, item)
          item.list = item.parent.list
        else
          if not current then
            current = { items = {} }
            lists[#lists + 1] = current
          end
          table.insert(current.items, item)
          item.list = current
        end
        stack[#stack + 1] = item
        all[#all + 1] = item
      else
        while #stack > 0 and stack[#stack].indent >= ind do
          table.remove(stack)
        end
        if #stack == 0 then
          current = nil
        end
        if line:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]") and #stack > 0 then
          in_block = true
        end
      end
      for _, it in ipairs(stack) do
        it.end_lnum = i
      end
    end
  end
  return lists, all
end

--- Section boundaries (lines between headlines) containing lnum.
local function section_bounds(file, lnum)
  local hl = file:headline_at(lnum)
  if hl then
    return hl.line + 1, hl.body_end, hl
  end
  return 1, file.preamble_end, nil
end

--- Parse the lists of the section containing `lnum`.
function M.section_lists(bufnr, lnum)
  local file = files.get_buffer(bufnr)
  local from, to, hl = section_bounds(file, lnum)
  local lists, all = M.parse_region(file.lines, from, to)
  return lists, all, file, hl
end

--- Siblings of an item (including itself).
function M.siblings(item)
  return item.parent and item.parent.children or item.list.items
end

--- Item containing `lnum` (innermost), or nil.
---@return org.ListItem|nil
function M.item_at(bufnr, lnum)
  bufnr = bufnr or 0
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  if not line or parser.headline_level(line) then
    return nil
  end
  local _, all = M.section_lists(bufnr, lnum)
  local found
  for _, it in ipairs(all) do
    if it.lnum <= lnum and lnum <= it.end_lnum then
      found = it -- later items are deeper
    end
  end
  return found
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function get_lines(bufnr, s, e)
  return vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
end

local function set_lines(bufnr, s, e, lines)
  vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, lines)
end

--- Shift non-blank lines by `delta` columns.
local function shift(lines, delta)
  local out = {}
  for i, l in ipairs(lines) do
    if delta > 0 and not is_blank(l) then
      out[i] = string.rep(" ", delta) .. l
    elseif delta < 0 then
      local n = math.min(-delta, indent_of(l))
      out[i] = l:sub(n + 1)
    else
      out[i] = l
    end
  end
  return out
end

--- Replace the bullet on an item line, keeping the rest.
local function set_bullet(line, new_bullet)
  local ind, bullet, rest = line:match("^(%s*)(%d+[.)])(.*)$")
  if not ind then
    ind, bullet, rest = line:match("^(%s*)([%-+*])(.*)$")
  end
  if not ind then
    return line
  end
  return ind .. new_bullet .. rest
end

local function set_checkbox(line, state)
  local s, e = line:find("%[[ xX%-]%]")
  local item = M.parse_item_line(line)
  if not item or not item.checkbox or not s then
    return line
  end
  return line:sub(1, s - 1) .. "[" .. state .. "]" .. line:sub(e + 1)
end

local function cursor_lnum()
  return vim.api.nvim_win_get_cursor(0)[1]
end

--- Whether to put a blank line before a new item after `item`
--- (`blank_before_new_entry.plain_list_item`; "auto": when `item` itself
--- is preceded by a blank line).
local function want_blank(bufnr, item)
  local b = require("org.config").opts.blank_before_new_entry
  local v = type(b) == "table" and b.plain_list_item
  if v == true then
    return true
  elseif v == "auto" then
    return item.lnum > 1 and is_blank(get_lines(bufnr, item.lnum - 1, item.lnum - 1)[1])
  end
  return false
end

---------------------------------------------------------------------------
-- Renumbering / repair
---------------------------------------------------------------------------

--- Renumber & unify bullets for one sibling group. Returns true if changed.
local function fix_group(bufnr, items)
  local first = items[1]
  if not first then
    return
  end
  local n = first.counter or 1
  local delim = first.is_ordered and first.bullet:sub(-1) or nil
  -- process bottom-up so width changes don't invalidate line numbers
  local new_bullets = {}
  for i, it in ipairs(items) do
    if it.counter and i > 1 then
      n = it.counter
    end
    if first.is_ordered then
      new_bullets[i] = n .. delim
    else
      new_bullets[i] = first.bullet
    end
    n = n + 1
  end
  for i = #items, 1, -1 do
    local it = items[i]
    local nb = new_bullets[i]
    if nb ~= it.bullet then
      local lines = get_lines(bufnr, it.lnum, it.end_lnum)
      local delta = #nb - #it.bullet
      lines[1] = set_bullet(lines[1], nb)
      if delta ~= 0 and #lines > 1 then
        local rest = shift(vim.list_slice(lines, 2), delta)
        for j, l in ipairs(rest) do
          lines[j + 1] = l
        end
      end
      set_lines(bufnr, it.lnum, it.end_lnum, lines)
    end
  end
end

--- Renumber every ordered list in the section containing `lnum`.
function M.repair(bufnr, lnum)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  lnum = lnum or cursor_lnum()
  -- iterate until stable (width changes shift children)
  for _ = 1, 3 do
    local lists, all = M.section_lists(bufnr, lnum)
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    -- deepest groups first so outer line numbers remain valid
    local groups = {}
    for _, l in ipairs(lists) do
      groups[#groups + 1] = l.items
    end
    for _, it in ipairs(all) do
      if #it.children > 0 then
        groups[#groups + 1] = it.children
      end
    end
    for i = #groups, 1, -1 do
      fix_group(bufnr, groups[i])
    end
    if vim.api.nvim_buf_get_changedtick(bufnr) == tick then
      break
    end
  end
end

---------------------------------------------------------------------------
-- Statistics cookies
---------------------------------------------------------------------------

local function replace_cookies(line, done, total)
  local pct = total == 0 and 0 or math.floor(done * 100 / total)
  line = line:gsub("%[%d*/%d*%]", "[" .. done .. "/" .. total .. "]")
  line = line:gsub("%[%d*%%%]", "[" .. pct .. "%%]")
  return line
end

local function has_cookie(line)
  return line:find("%[%d*/%d*%]") or line:find("%[%d*%%%]")
end

local function count_checkboxes(items, recursive)
  local done, total = 0, 0
  local function walk(list)
    for _, it in ipairs(list) do
      if it.checkbox then
        total = total + 1
        if it.checkbox == "X" then
          done = done + 1
        end
      end
      if recursive then
        walk(it.children)
      end
    end
  end
  walk(items)
  return done, total
end

--- Counts for a headline cookie.
local function headline_counts(file, hl)
  local cookie_data = (hl.properties.COOKIE_DATA or ""):lower()
  local recursive = cookie_data:find("recursive") ~= nil
  local mode
  if cookie_data:find("todo") then
    mode = "todo"
  elseif cookie_data:find("checkbox") then
    mode = "checkbox"
  end
  local lists = M.parse_region(file.lines, hl.line + 1, hl.body_end)
  if not mode then
    local d, t = 0, 0
    for _, l in ipairs(lists) do
      local a, b = count_checkboxes(l.items, recursive)
      d, t = d + a, t + b
    end
    if t > 0 then
      return d, t
    end
    mode = "todo"
  end
  if mode == "checkbox" then
    local d, t = 0, 0
    for _, l in ipairs(lists) do
      local a, b = count_checkboxes(l.items, recursive)
      d, t = d + a, t + b
    end
    return d, t
  end
  local done, total = 0, 0
  local function walk(children)
    for _, c in ipairs(children) do
      if c.todo then
        total = total + 1
        if c:is_done() then
          done = done + 1
        end
      end
      if recursive then
        walk(c.children)
      end
    end
  end
  walk(hl.children)
  return done, total
end

--- Update cookies in list items of lines[from..to] and in headline `hl`.
local function update_section(bufnr, file, hl, from, to)
  local lines = file.lines
  local changes = {}
  local _, all = M.parse_region(lines, from, to)
  for _, it in ipairs(all) do
    if has_cookie(lines[it.lnum]) then
      local d, t = count_checkboxes(it.children, false)
      changes[it.lnum] = replace_cookies(lines[it.lnum], d, t)
    end
  end
  if hl and has_cookie(lines[hl.line]) then
    local d, t = headline_counts(file, hl)
    changes[hl.line] = replace_cookies(lines[hl.line], d, t)
  end
  for lnum, text in pairs(changes) do
    if text ~= lines[lnum] then
      set_lines(bufnr, lnum, lnum, { text })
    end
  end
end

--- Update the cookies relevant to `lnum`: list items in its section, the
--- containing headline and every ancestor headline.
function M.update_statistics_for(bufnr, lnum)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl then
    update_section(bufnr, file, nil, 1, file.preamble_end)
    return
  end
  local chain = {}
  local h = hl
  while h do
    chain[#chain + 1] = h.line
    h = h.parent
  end
  for idx, l in ipairs(chain) do
    file = files.get_buffer(bufnr)
    local cur = file:headline_on(l)
    if cur then
      if idx == 1 then
        update_section(bufnr, file, cur, cur.line + 1, cur.body_end)
      else
        update_section(bufnr, file, cur, cur.line + 1, cur.line)
      end
    end
  end
end

--- Update every statistics cookie in the current buffer.
function M.update_statistics()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = files.get_buffer(bufnr)
  update_section(bufnr, file, nil, 1, file.preamble_end)
  -- deepest headlines first so parents see updated children
  local lines_list = {}
  for _, h in ipairs(file.headlines) do
    lines_list[#lines_list + 1] = { line = h.line, level = h.level }
  end
  table.sort(lines_list, function(a, b)
    return a.level > b.level
  end)
  for _, e in ipairs(lines_list) do
    file = files.get_buffer(bufnr)
    local h = file:headline_on(e.line)
    if h then
      update_section(bufnr, file, h, h.line + 1, h.body_end)
    end
  end
end

---------------------------------------------------------------------------
-- Checkboxes
---------------------------------------------------------------------------

--- Recompute the [ ]/[-]/[X] state of parent items from their children.
local function fix_parent_checkboxes(bufnr, lnum)
  local _, all = M.section_lists(bufnr, lnum)
  -- post-order: children appear after parents in `all`, iterate reversed
  local state = {}
  for i = #all, 1, -1 do
    local it = all[i]
    local cbs = {}
    for _, c in ipairs(it.children) do
      if c.checkbox then
        cbs[#cbs + 1] = state[c] or c.checkbox
      end
    end
    local cur = it.checkbox
    if cur and #cbs > 0 then
      local n_done, n_empty = 0, 0
      for _, s in ipairs(cbs) do
        if s == "X" then
          n_done = n_done + 1
        elseif s == " " then
          n_empty = n_empty + 1
        end
      end
      local new = (n_done == #cbs) and "X" or (n_empty == #cbs) and " " or "-"
      state[it] = new
      if new ~= cur then
        local line = get_lines(bufnr, it.lnum, it.lnum)[1]
        set_lines(bufnr, it.lnum, it.lnum, { set_checkbox(line, new) })
      end
    end
  end
end

--- Add an empty checkbox to an item line.
local function add_checkbox(line, item)
  local prefix_len = item.content_col
  if line:sub(prefix_len + 1) == "" then
    return line:sub(1, prefix_len) .. "[ ]"
  end
  return line:sub(1, prefix_len) .. "[ ] " .. line:sub(prefix_len + 1)
end

--- Remove the checkbox of an item line.
local function remove_checkbox(line)
  local s, e = line:find("%[[ xX%-]%]%s?")
  if not s then
    return line
  end
  return line:sub(1, s - 1) .. line:sub(e + 1)
end

--- Toggle the checkboxes of the items starting in [s, e]
--- (org-toggle-checkbox with an active region): when the first checkbox
--- is checked, uncheck all, else check all. Items without a checkbox get
--- one when none of them has a checkbox.
local function toggle_checkbox_region(bufnr, s, e)
  local _, all = M.section_lists(bufnr, s)
  local items = {}
  for _, it in ipairs(all) do
    if it.lnum >= s and it.lnum <= e then
      items[#items + 1] = it
    end
  end
  if #items == 0 then
    return false
  end
  local first
  for _, it in ipairs(items) do
    if it.checkbox then
      first = first or it
    end
  end
  for _, it in ipairs(items) do
    local line = get_lines(bufnr, it.lnum, it.lnum)[1]
    if not first then
      set_lines(bufnr, it.lnum, it.lnum, { add_checkbox(line, it) })
    elseif it.checkbox then
      set_lines(bufnr, it.lnum, it.lnum, { set_checkbox(line, first.checkbox == "X" and " " or "X") })
    end
  end
  fix_parent_checkboxes(bufnr, items[1].lnum)
  M.update_statistics_for(bufnr, items[1].lnum)
end

--- Toggle the checkbox of the item at cursor. Items without a checkbox get
--- one. With a count of 4 (C-u), add or remove the checkbox; with 16
--- (C-u C-u), set it to `[-]`. In Visual mode, toggle every item of the
--- selection. Returns false when not on a list item.
function M.toggle_checkbox()
  local bufnr = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local s, _, e = utils.visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    return toggle_checkbox_region(bufnr, s, e)
  end
  local lnum = cursor_lnum()
  local item = M.item_at(bufnr, lnum)
  if not item then
    return false
  end
  local line = get_lines(bufnr, item.lnum, item.lnum)[1]
  local count = vim.v.count
  if count == 4 and item.checkbox then
    set_lines(bufnr, item.lnum, item.lnum, { remove_checkbox(line) })
    fix_parent_checkboxes(bufnr, item.lnum)
    M.update_statistics_for(bufnr, item.lnum)
    return
  elseif count == 16 then
    local new = item.checkbox and set_checkbox(line, "-") or add_checkbox(line, item):gsub("%[ %]", "[-]", 1)
    set_lines(bufnr, item.lnum, item.lnum, { new })
    M.update_statistics_for(bufnr, item.lnum)
    return
  end
  if not item.checkbox then
    -- add an empty checkbox after bullet (and counter)
    local prefix_len = item.content_col
    local new = line:sub(1, prefix_len) .. "[ ] " .. line:sub(prefix_len + 1)
    if line:sub(prefix_len + 1) == "" then
      new = line:sub(1, prefix_len) .. "[ ]"
    end
    set_lines(bufnr, item.lnum, item.lnum, { new })
    M.update_statistics_for(bufnr, item.lnum)
    return
  end
  local new_state = item.checkbox == "X" and " " or "X"
  set_lines(bufnr, item.lnum, item.lnum, { set_checkbox(line, new_state) })
  -- propagate to descendants with checkboxes
  local function walk(children)
    for _, c in ipairs(children) do
      if c.checkbox then
        local l = get_lines(bufnr, c.lnum, c.lnum)[1]
        set_lines(bufnr, c.lnum, c.lnum, { set_checkbox(l, new_state) })
      end
      walk(c.children)
    end
  end
  walk(item.children)
  fix_parent_checkboxes(bufnr, item.lnum)
  M.update_statistics_for(bufnr, item.lnum)
end

---------------------------------------------------------------------------
-- Item editing
---------------------------------------------------------------------------

--- Insert a new item after the item at cursor (after its children).
---@param opts { checkbox?: boolean }
function M.new_item(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cursor_lnum()
  local item = M.item_at(bufnr, lnum)
  if not item then
    return false
  end
  local bullet = item.bullet
  if item.is_ordered then
    local n = tonumber(bullet:match("^(%d+)"))
    bullet = (n + 1) .. bullet:sub(-1)
  end
  local text = string.rep(" ", item.indent) .. bullet .. " "
  if opts.checkbox or item.checkbox then
    text = text .. "[ ] "
  end
  if item.tag and not opts.checkbox then
    text = text .. " :: "
  end
  local at = item.end_lnum
  local new_lines = { text }
  if want_blank(bufnr, item) and not is_blank(get_lines(bufnr, at, at)[1]) then
    table.insert(new_lines, 1, "")
  end
  set_lines(bufnr, at + 1, at, new_lines)
  local new_lnum = at + #new_lines
  M.repair(bufnr, new_lnum)
  local final = get_lines(bufnr, new_lnum, new_lnum)[1]
  local col = #final
  if item.tag and not opts.checkbox then
    col = #final - 4
  end
  vim.api.nvim_win_set_cursor(0, { new_lnum, math.max(col, 0) })
  if opts.checkbox then
    M.update_statistics_for(bufnr, new_lnum)
  end
end

--- Indent (delta > 0) or outdent (delta < 0) the item at cursor.
function M.indent_item(delta, with_children)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cursor_lnum()
  local item = M.item_at(bufnr, lnum)
  if not item then
    return false
  end
  local new_indent
  if delta > 0 then
    local sibs = M.siblings(item)
    local prev
    for i, s in ipairs(sibs) do
      if s == item then
        prev = sibs[i - 1]
      end
    end
    if not prev then
      utils.warn("Cannot indent the first item of a list")
      return
    end
    new_indent = prev.content_col
    if prev.checkbox or prev.counter then
      -- children align with the bullet text, not the checkbox
      new_indent = prev.indent + #prev.bullet + 1
    end
  else
    if not item.parent then
      utils.warn("Cannot outdent a top-level item")
      return
    end
    new_indent = item.parent.indent
  end
  local d = new_indent - item.indent
  local last = item.end_lnum
  if not with_children and #item.children > 0 then
    -- move only the item's own lines; children keep their relative place
    last = item.children[1].lnum - 1
  end
  local lines = get_lines(bufnr, item.lnum, last)
  set_lines(bufnr, item.lnum, last, shift(lines, d))
  local col = vim.api.nvim_win_get_cursor(0)[2]
  vim.api.nvim_win_set_cursor(0, { lnum, math.max(0, col + (lnum <= last and d or 0)) })
  M.repair(bufnr, item.lnum)
  if item.parent then
    M.repair(bufnr, item.parent.lnum)
  end
  M.update_statistics_for(bufnr, item.lnum)
end

--- Move the item (with children) up (-1) or down (1) among its siblings.
function M.move_item(dir)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cursor_lnum()
  local item = M.item_at(bufnr, lnum)
  if not item then
    return false
  end
  local sibs = M.siblings(item)
  local idx
  for i, s in ipairs(sibs) do
    if s == item then
      idx = i
    end
  end
  local other = sibs[idx + dir]
  if not other then
    utils.warn("Cannot move item further " .. (dir < 0 and "up" or "down"))
    return
  end
  local a, b = item, other
  if dir < 0 then
    a, b = other, item
  end
  -- a is above b; blank lines between stay in place
  local a_lines = get_lines(bufnr, a.lnum, a.end_lnum)
  local between = get_lines(bufnr, a.end_lnum + 1, b.lnum - 1)
  local b_lines = get_lines(bufnr, b.lnum, b.end_lnum)
  local new = vim.list_extend(vim.list_extend(vim.deepcopy(b_lines), between), a_lines)
  set_lines(bufnr, a.lnum, b.end_lnum, new)
  local offset = lnum - item.lnum
  local new_start
  if dir < 0 then
    new_start = a.lnum
  else
    new_start = a.lnum + #b_lines + #between
  end
  vim.api.nvim_win_set_cursor(0, { new_start + offset, vim.api.nvim_win_get_cursor(0)[2] })
  M.repair(bufnr, new_start)
end

--- Move to the next (dir = 1) or previous (dir = -1) item of the same
--- list level (org-next-item / org-previous-item). Returns false when
--- not on a list item.
function M.goto_sibling_item(dir)
  local bufnr = vim.api.nvim_get_current_buf()
  local item = M.item_at(bufnr, cursor_lnum())
  if not item then
    return false
  end
  local target = item
  for _ = 1, math.max(vim.v.count, 1) do
    local sibs = M.siblings(target)
    local idx
    for i, s in ipairs(sibs) do
      if s == target then
        idx = i
      end
    end
    if not sibs[idx + dir] then
      break
    end
    target = sibs[idx + dir]
  end
  if target == item then
    utils.warn(dir > 0 and "On last item" or "On first item")
    return
  end
  vim.api.nvim_win_set_cursor(0, { target.lnum, target.indent })
end

--- On an empty item (only a bullet, maybe a checkbox), indent it under
--- the previous item, or outdent it back when it can't go deeper
--- (org-cycle-item-indentation, used by TAB right after M-RET). Returns
--- false when the item is not empty.
function M.cycle_item_indentation()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cursor_lnum()
  local line = vim.api.nvim_get_current_line()
  local parsed = M.parse_item_line(line)
  if not parsed or vim.trim(parsed.text) ~= "" or parser.headline_level(line) then
    return false
  end
  local item = M.item_at(bufnr, lnum)
  if not item or item.lnum ~= lnum or #item.children > 0 then
    return false
  end
  local sibs = M.siblings(item)
  if sibs[1] ~= item then
    M.indent_item(1, true)
  elseif item.parent then
    M.indent_item(-1, true)
  else
    return false
  end
  local new = vim.api.nvim_get_current_line()
  vim.api.nvim_win_set_cursor(0, { lnum, #new })
end

function M.next_item()
  return M.goto_sibling_item(1)
end

function M.prev_item()
  return M.goto_sibling_item(-1)
end

local BULLETS = { "-", "+", "*", "1.", "1)" }

--- Cycle the bullet type of the list at cursor.
function M.cycle_bullet(dir)
  dir = dir or 1
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cursor_lnum()
  local item = M.item_at(bufnr, lnum)
  if not item then
    return false
  end
  local cur = item.is_ordered and ("1" .. item.bullet:sub(-1)) or item.bullet
  local idx = 1
  for i, b in ipairs(BULLETS) do
    if b == cur then
      idx = i
    end
  end
  local nxt
  for step = 1, #BULLETS do
    local cand = BULLETS[((idx - 1 + dir * step) % #BULLETS) + 1]
    if not (cand == "*" and item.indent == 0) then
      nxt = cand
      break
    end
  end
  local first = M.siblings(item)[1]
  local line = get_lines(bufnr, first.lnum, first.lnum)[1]
  local delta = #nxt - #first.bullet
  local lines = get_lines(bufnr, first.lnum, first.end_lnum)
  lines[1] = set_bullet(line, nxt)
  if delta ~= 0 and #lines > 1 then
    local rest = shift(vim.list_slice(lines, 2), delta)
    for j, l in ipairs(rest) do
      lines[j + 1] = l
    end
  end
  set_lines(bufnr, first.lnum, first.end_lnum, lines)
  M.repair(bufnr, first.lnum)
end

--- org-toggle-item: convert lines to list items and back.
function M.toggle_item()
  local bufnr = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local s, e
  if mode == "v" or mode == "V" or mode == "\22" then
    s, _, e = utils.visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  else
    s = cursor_lnum()
    e = s
  end
  local lines = get_lines(bufnr, s, e)
  local first_item = M.parse_item_line(lines[1])
  local first_head = parser.parse_headline_line(lines[1])
  local out = {}
  if first_item and not first_head then
    for i, l in ipairs(lines) do
      local it = M.parse_item_line(l)
      if it then
        out[i] = string.rep(" ", it.indent) .. l:sub(it.content_col + 1)
      else
        out[i] = l
      end
    end
  elseif first_head then
    for i, l in ipairs(lines) do
      local h = parser.parse_headline_line(l, files.get_buffer(bufnr).settings.todo)
      if h then
        local text = h.title
        if h.todo then
          text = h.todo .. " " .. text
        end
        out[i] = string.rep(" ", (h.level - 1) * 2) .. "- " .. text
        if #h.tags > 0 then
          out[i] = out[i] .. " :" .. table.concat(h.tags, ":") .. ":"
        end
      else
        out[i] = l
      end
    end
  else
    for i, l in ipairs(lines) do
      if is_blank(l) or M.parse_item_line(l) then
        out[i] = l
      else
        local ind = l:match("^(%s*)")
        out[i] = ind .. "- " .. l:sub(#ind + 1)
      end
    end
  end
  set_lines(bufnr, s, e, out)
end

---------------------------------------------------------------------------
-- Sorting (used by org.structure.sort)
---------------------------------------------------------------------------

--- Sort the sibling group of the item at cursor with `key(item_lines, item)`
--- returning a comparable value (nil sorts last).
function M.sort_items(bufnr, lnum, keyfn, reverse)
  local item = M.item_at(bufnr, lnum)
  if not item then
    return false
  end
  local sibs = M.siblings(item)
  local blocks = {}
  for i, s in ipairs(sibs) do
    local stop = sibs[i + 1] and (sibs[i + 1].lnum - 1) or s.end_lnum
    local lines = get_lines(bufnr, s.lnum, stop)
    blocks[#blocks + 1] = { item = s, lines = lines, key = keyfn(s, lines), idx = i }
  end
  table.sort(blocks, function(a, b)
    local ka, kb = a.key, b.key
    if ka == nil and kb == nil then
      return a.idx < b.idx
    elseif ka == nil then
      return false
    elseif kb == nil then
      return true
    end
    if ka == kb then
      return a.idx < b.idx
    end
    if reverse then
      return ka > kb
    end
    return ka < kb
  end)
  local out = {}
  for _, b in ipairs(blocks) do
    vim.list_extend(out, b.lines)
  end
  set_lines(bufnr, sibs[1].lnum, sibs[#sibs].end_lnum, out)
  M.repair(bufnr, sibs[1].lnum)
  return true
end

return M
