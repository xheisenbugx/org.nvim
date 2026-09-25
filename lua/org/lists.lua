---@mod org.lists Plain lists, checkboxes and statistics cookies
---
--- Lists are parsed on demand per section (the lines between two
--- headlines), following org's rules: an item ends at the first non-blank
--- line indented at or left of its bullet, at a headline, or after two
--- consecutive blank lines. Lines inside example, verse, src and export
--- blocks never hold items (org-list-forbidden-blocks).
---
--- Editing commands work like Emacs org-list: they change a "structure"
--- (indentation, bullet, parent and checkbox of every item of the list)
--- and then write it back, which also renumbers ordered lists, aligns
--- sub-lists under their parent's text and derives parent checkboxes
--- from their children (org-list-write-struct).

local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")

local M = {}

---@class org.ListItem
---@field lnum integer
---@field end_lnum integer last line of the item, children included (trailing blanks excluded)
---@field indent integer
---@field bullet string "-", "+", "*", "1." or "1)"
---@field bullet_ws string the bullet with the whitespace after it
---@field is_ordered boolean
---@field counter integer|nil value of a [@N] counter
---@field checkbox string|nil " ", "X" or "-"
---@field tag string|nil description list term
---@field text string text after bullet/counter/checkbox
---@field content_col integer 0-based column where the item text starts
---@field children org.ListItem[]
---@field parent org.ListItem|nil
---@field list { items: org.ListItem[] }

--- Blocks whose contents are never list items (org-list-forbidden-blocks).
M.forbidden_blocks = { example = true, verse = true, src = true, export = true }

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
  if #gap > 1 and rest:match("^::") then
    -- an empty description term: "-  :: text"
    rest = gap:sub(-1) .. rest
    gap = gap:sub(1, -2)
  end
  local item = {
    indent = #ind,
    bullet = bullet,
    bullet_ws = bullet .. gap,
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
  local tag = rest:match("^(.-)%s+::%s") or rest:match("^(.-)%s+::$")
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
  return line == nil or line:match("^%s*$") ~= nil
end

--- Lines strictly inside a forbidden block within lines[from..to]:
--- set of line numbers.
local function verbatim_lines(lines, from, to)
  local set = {}
  local i = from
  while i <= to do
    local name = lines[i]:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)")
    if name and M.forbidden_blocks[name:lower()] then
      local close = "^%s*#%+[Ee][Nn][Dd]_" .. vim.pesc(name) .. "%s*$"
      local stop
      for j = i + 1, to do
        if lines[j]:lower():match(close:lower()) then
          stop = j
          break
        end
      end
      if stop then
        for j = i + 1, stop - 1 do
          set[j] = true
        end
        i = stop
      end
    end
    i = i + 1
  end
  return set
end

--- Parse all lists within lines[from..to].
---@return { items: org.ListItem[] }[] lists, org.ListItem[] all items (in order)
function M.parse_region(lines, from, to)
  local lists, all = {}, {}
  local stack = {} -- open items
  local current -- current list
  local blanks = 0
  local verbatim = verbatim_lines(lines, from, to)
  for i = from, to do
    local line = lines[i]
    if verbatim[i] then
      -- block contents belong to the enclosing item, whatever their indentation
      blanks = is_blank(line) and blanks + 1 or 0
      if #stack > 0 and not is_blank(line) then
        for _, it in ipairs(stack) do
          it.end_lnum = i
        end
      end
    elseif is_blank(line) then
      blanks = blanks + 1
      if blanks >= 2 then
        stack, current = {}, nil
      end
    else
      blanks = 0
      local ind = indent_of(line)
      local item = M.parse_item_line(line)
      if item then
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

--- Whether `lnum` is inside an example, verse, src or export block.
function M.in_forbidden_block(bufnr, lnum)
  local file = files.get_buffer(bufnr)
  local from, to = section_bounds(file, lnum)
  return verbatim_lines(file.lines, from, to)[lnum] == true
end

--- Item containing `lnum` (innermost), or nil (org-in-item-p).
---@return org.ListItem|nil
function M.item_at(bufnr, lnum)
  bufnr = bufnr or 0
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  if not line or parser.headline_level(line) then
    return nil
  end
  local file = files.get_buffer(bufnr)
  local from, to = section_bounds(file, lnum)
  if verbatim_lines(file.lines, from, to)[lnum] then
    return nil
  end
  local _, all = M.parse_region(file.lines, from, to)
  local found
  for _, it in ipairs(all) do
    if it.lnum <= lnum and lnum <= it.end_lnum then
      found = it -- later items are deeper
    end
  end
  return found
end

--- Item starting on `lnum` (org-at-item-p), or nil.
function M.item_on(bufnr, lnum)
  local it = M.item_at(bufnr, lnum)
  if it and it.lnum == lnum then
    return it
  end
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

local function cursor_lnum()
  return vim.api.nvim_win_get_cursor(0)[1]
end

local function curbuf(bufnr)
  return (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
end

--- Signal an Emacs user-error: warn and stop the command.
local function user_error(msg)
  utils.warn(msg)
  error({ org_user_error = msg }, 0)
end

--- Run `fn`, turning user errors into a `nil` result.
local function protected(fn, ...)
  local res = { pcall(fn, ...) }
  if res[1] then
    return unpack(res, 2)
  end
  local err = res[2]
  if type(err) == "table" and err.org_user_error then
    return nil
  end
  error(err, 0)
end
M._protected = protected

--- The ORDERED property of the entry containing `lnum`.
local function ordered_p(bufnr, lnum)
  local hl = files.get_buffer(bufnr):headline_at(lnum)
  local v = hl and hl.properties and hl.properties.ORDERED
  return v ~= nil and v ~= "" and v ~= "nil"
end

---------------------------------------------------------------------------
-- List structures (org-list-struct / org-list-write-struct)
---------------------------------------------------------------------------

--- The whole list (top-level list with all its sub-lists) containing
--- `lnum`, as a structure: `items` in buffer order, each with its
--- original `indent`, `bullet_ws`, `checkbox` and `parent`, plus the
--- fields `ind`, `bul`, `box` and `par` that editing commands change.
---@return table|nil struct, org.ListItem|nil item innermost item at lnum
function M.struct_at(bufnr, lnum)
  bufnr = curbuf(bufnr)
  local item = M.item_at(bufnr, lnum)
  if not item then
    return nil
  end
  local top = item
  while top.parent do
    top = top.parent
  end
  local list = top.list
  local items = {}
  local function walk(its)
    for _, it in ipairs(its) do
      items[#items + 1] = it
      walk(it.children)
    end
  end
  walk(list.items)
  for i, it in ipairs(items) do
    it.idx = i
    it.ind = it.indent
    it.bul = it.bullet_ws
    it.box = it.checkbox
    it.par = it.parent
  end
  local last = 0
  for _, it in ipairs(items) do
    last = math.max(last, it.end_lnum)
  end
  local struct = {
    bufnr = bufnr,
    items = items,
    first = items[1].lnum,
    last = last,
    lines = get_lines(bufnr, items[1].lnum, last),
  }
  return struct, item
end

--- Children of `it` under the new parents.
local function new_children(struct, it)
  local out = {}
  for _, c in ipairs(struct.items) do
    if c.par == it then
      out[#out + 1] = c
    end
  end
  return out
end

--- Previous sibling of `it` under the new parents.
local function new_prev(struct, it)
  for i = it.idx - 1, 1, -1 do
    local c = struct.items[i]
    if c.par == it.par then
      return c
    end
    if it.par and c == it.par then
      return nil
    end
  end
end

--- Bullet with exactly one space after it (org-list-bullet-string).
local function bullet_string(b)
  local core = b:match("^(%S+)")
  return core and (core .. " ") or b
end

--- org-list-inc-bullet-maybe.
local function inc_bullet(b)
  local n = b:match("%d+")
  if n then
    return (b:gsub("%d+", tostring(tonumber(n) + 1), 1))
  end
  return b
end

--- org-list-struct-fix-bul.
local function fix_bul(struct)
  for _, it in ipairs(struct.items) do
    local prev = new_prev(struct, it)
    local b
    if prev and it.counter and prev.bul:match("%d+") then
      b = prev.bul:gsub("%d+", tostring(it.counter), 1)
    elseif prev then
      b = inc_bullet(prev.bul)
    elseif it.counter and it.bul:match("%d+") then
      b = it.bul:gsub("%d+", tostring(it.counter), 1)
    elseif it.bul:match("%d+") then
      b = it.bul:gsub("%d+", "1", 1)
    else
      b = it.bul
    end
    it.bul = bullet_string(b)
  end
end

--- org-list-struct-fix-ind.
local function fix_ind(struct)
  local top_ind = struct.items[1].ind
  for _, it in ipairs(struct.items) do
    if it.par then
      it.ind = it.par.ind + #it.par.bul
    else
      it.ind = top_ind
    end
  end
end

--- org-list-struct-fix-box: parents with a checkbox follow their
--- children. With `ordered`, boxes after an unchecked one are unchecked.
--- Returns the blocking item.
local function fix_box(struct, ordered)
  local parents = {}
  for _, it in ipairs(struct.items) do
    if it.par and it.par.box and not vim.tbl_contains(parents, it.par) then
      parents[#parents + 1] = it.par
    end
  end
  table.sort(parents, function(a, b)
    if a.ind ~= b.ind then
      return a.ind > b.ind
    end
    return a.idx > b.idx
  end)
  for _, p in ipairs(parents) do
    local has = {}
    for _, c in ipairs(new_children(struct, p)) do
      if c.box then
        has[c.box] = true
      end
    end
    if (has[" "] and has["X"]) or has["-"] then
      p.box = "-"
    elseif has["X"] then
      p.box = "X"
    elseif has[" "] then
      p.box = " "
    end
  end
  if ordered then
    local after_unchecked
    for i, it in ipairs(struct.items) do
      if it.box == " " and not after_unchecked then
        after_unchecked = i
      end
    end
    if after_unchecked then
      local checked_after = false
      for i = after_unchecked, #struct.items do
        if struct.items[i].box == "X" then
          checked_after = true
        end
      end
      if checked_after then
        for i = after_unchecked, #struct.items do
          if struct.items[i].box then
            struct.items[i].box = " "
          end
        end
        fix_box(struct, false)
        return struct.items[after_unchecked]
      end
    end
  end
end

--- Whether the structure differs from the buffer.
local function struct_changed(struct)
  for _, it in ipairs(struct.items) do
    if it.ind ~= it.indent or it.bul ~= it.bullet_ws or it.box ~= it.checkbox then
      return true
    end
  end
  return false
end

--- Rewrite the item's first line for its new indentation, bullet and box.
local function item_line(it, line)
  local rest = line:sub(it.indent + #it.bullet_ws + 1)
  if it.box ~= it.checkbox then
    local counter = rest:match("^%[@%d+%]")
    if it.checkbox and it.box then
      local s = rest:find("%[[ xX%-]%]")
      rest = rest:sub(1, s) .. it.box .. rest:sub(s + 2)
    elseif it.checkbox then
      local s, e = rest:find("[ \t]*%[[ xX%-]%]")
      rest = rest:sub(1, s - 1) .. rest:sub(e + 1)
      if not counter then
        rest = rest:gsub("^[ \t]+", "")
      end
    else
      local box = "[" .. it.box .. "]"
      if counter then
        rest = counter .. box .. rest:sub(#counter + 1)
      else
        rest = box .. " " .. rest
      end
    end
  end
  return string.rep(" ", it.ind) .. it.bul .. rest
end

--- Owner item of each line of the structure (the innermost item whose
--- range contains it).
local function line_owners(struct)
  local owners = {}
  for _, it in ipairs(struct.items) do
    for l = it.lnum, it.end_lnum do
      owners[l] = it -- later (deeper) items override
    end
  end
  return owners
end

--- Apply the structure to the buffer (org-list-struct-apply-struct):
--- item lines get their new indentation, bullet and checkbox, and the
--- other lines of an item move with it.
local function apply_struct(struct)
  local bufnr = struct.bufnr
  local lines = get_lines(bufnr, struct.first, struct.last)
  local owners = line_owners(struct)
  local out = {}
  local cur = vim.api.nvim_get_current_buf() == bufnr and vim.api.nvim_win_get_cursor(0) or nil
  local cur_shift = 0
  for i, line in ipairs(lines) do
    local lnum = struct.first + i - 1
    local owner = owners[lnum]
    local new = line
    if owner and owner.lnum == lnum then
      new = item_line(owner, line)
    elseif owner and not is_blank(line) then
      local delta = (owner.ind + #owner.bul) - (owner.indent + #owner.bullet_ws)
      if delta ~= 0 then
        local ind = indent_of(line)
        local target = math.max(ind + delta, owner.ind + 1)
        new = string.rep(" ", target) .. line:sub(ind + 1)
      end
    end
    out[i] = new
    if cur and cur[1] == lnum and new ~= line then
      local old_ind, new_ind = indent_of(line), indent_of(new)
      if owner and owner.lnum == lnum then
        local old_prefix = owner.indent + #owner.bullet_ws
        local new_prefix = owner.ind + #owner.bul
        if cur[2] >= old_prefix then
          cur_shift = (#new - #line)
        elseif cur[2] >= old_ind then
          cur_shift = new_ind - old_ind
        end
      elseif cur[2] >= old_ind then
        cur_shift = new_ind - old_ind
      end
    end
  end
  local changed = false
  for i = 1, #lines do
    if out[i] ~= lines[i] then
      changed = true
    end
  end
  if changed then
    set_lines(bufnr, struct.first, struct.last, out)
    if cur and cur[1] >= struct.first and cur[1] <= struct.last then
      local l = out[cur[1] - struct.first + 1]
      vim.api.nvim_win_set_cursor(0, { cur[1], math.max(0, math.min(cur[2] + cur_shift, #l)) })
    end
  end
  return changed
end

--- org-list-write-struct: fix indentation, bullets and checkboxes, then
--- apply. Returns the item blocking an ORDERED checkbox, if any.
local function write_struct(struct, ordered)
  fix_ind(struct)
  fix_bul(struct)
  fix_ind(struct)
  local block = fix_box(struct, ordered)
  apply_struct(struct)
  return block
end

---------------------------------------------------------------------------
-- Renumbering / repair
---------------------------------------------------------------------------

--- Repair the list at `lnum` (org-list-repair): renumber ordered lists,
--- make siblings use the same bullet, align sub-lists and fix parent
--- checkboxes. Without `lnum` (or when it is not in a list), repair every
--- list of the section.
function M.repair(bufnr, lnum)
  bufnr = curbuf(bufnr)
  lnum = lnum or cursor_lnum()
  local struct = M.struct_at(bufnr, lnum)
  if struct then
    write_struct(struct, ordered_p(bufnr, lnum))
    return
  end
  local lists = M.section_lists(bufnr, lnum)
  for i = #lists, 1, -1 do
    local s = M.struct_at(bufnr, lists[i].items[1].lnum)
    if s then
      write_struct(s, ordered_p(bufnr, lnum))
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
  bufnr = curbuf(bufnr)
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

--- Update every statistics cookie of the buffer.
function M.update_all_statistics(bufnr)
  bufnr = curbuf(bufnr)
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

--- C-c # (org-update-statistics-cookies): update the cookies of the
--- current entry. On a headline with child entries and no checkboxes, its
--- TODO cookie; on a leaf headline without checkboxes, the cookie becomes
--- [0/0] / [100%]. With a count (C-u), update every cookie of the buffer.
function M.update_statistics()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.v.count > 0 then
    return M.update_all_statistics(bufnr)
  end
  local lnum = cursor_lnum()
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl then
    update_section(bufnr, file, nil, 1, file.preamble_end)
    return
  end
  if hl.line ~= lnum then
    update_section(bufnr, file, hl, hl.line + 1, hl.body_end)
    return
  end
  local _, all = M.parse_region(file.lines, hl.line + 1, hl.body_end)
  local has_boxes = false
  for _, it in ipairs(all) do
    if it.checkbox then
      has_boxes = true
    end
  end
  local todo_cookie = (hl.properties.COOKIE_DATA or ""):lower():find("todo")
  if has_boxes and not todo_cookie then
    update_section(bufnr, file, hl, hl.line + 1, hl.body_end)
  elseif #hl.children > 0 then
    update_section(bufnr, file, hl, hl.line + 1, hl.line)
  else
    local line = file.lines[hl.line]
    local new = line:gsub("%[%d*%%%]", "[100%%]"):gsub("%[%d*/%d*%]", "[0/0]")
    if new ~= line then
      set_lines(bufnr, hl.line, hl.line, { new })
    end
  end
end

---------------------------------------------------------------------------
-- Checkboxes
---------------------------------------------------------------------------

--- Is the list of `item` a radio list (`#+attr_org: :radio t` before it)?
function M.radio_list_p(bufnr, item)
  bufnr = curbuf(bufnr)
  local first = M.siblings(item)[1]
  local l = first.lnum - 1
  while l >= 1 do
    local line = get_lines(bufnr, l, l)[1]
    if not line:match("^%s*#%+[%w_]+") then
      break
    end
    local v = line:lower():match("^%s*#%+attr_org:.* :radio (%S+)")
    if v then
      return v ~= "nil"
    end
    l = l - 1
  end
  return false
end

--- org-toggle-radio-button: check the item at the cursor and uncheck
--- its siblings. `arg`: 4 removes the box, 16 sets `[-]`.
function M.toggle_radio_button(arg)
  arg = arg or (vim.v.count > 0 and vim.v.count or nil)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cursor_lnum()
  local struct, item = M.struct_at(bufnr, lnum)
  if not struct or item.lnum ~= lnum then
    utils.warn("Cannot toggle checkbox outside of a list")
    return
  end
  local cbox = item.checkbox
  local sibs = M.siblings(item)
  local new
  if not (cbox and arg == 4 and sibs[1] == item) then
    new = " "
  end
  for _, s in ipairs(sibs) do
    s.box = new
  end
  if new then
    if arg == 4 then
      item.box = not cbox and " " or nil
    elseif arg == 16 then
      item.box = not cbox and "-" or nil
    else
      item.box = cbox == "X" and " " or "X"
    end
  end
  write_struct(struct, ordered_p(bufnr, lnum))
  M.update_statistics_for(bufnr, lnum)
end

--- C-c C-c on an item (org-ctrl-c-ctrl-c): toggle its checkbox and
--- repair the list. `arg` 4 (C-u) adds or removes the checkbox, 16 (C-u
--- C-u) sets it to `[-]`. A parent checkbox follows its children, so
--- toggling it is refused. On an item without a checkbox, just repair.
function M.ctrl_c_ctrl_c_item(item, arg)
  local bufnr = vim.api.nvim_get_current_buf()
  if M.radio_list_p(bufnr, item) then
    return M.toggle_radio_button(arg)
  end
  local struct, it = M.struct_at(bufnr, item.lnum)
  local box = it.checkbox
  local new
  if arg == 16 then
    new = "-"
  elseif not box and arg == 4 then
    new = " "
  elseif not box or arg == 4 then
    new = nil
  elseif box == "X" then
    new = " "
  else
    new = "X"
  end
  it.box = new
  fix_ind(struct)
  fix_bul(struct)
  fix_ind(struct)
  local block = fix_box(struct, ordered_p(bufnr, item.lnum))
  if box and not struct_changed(struct) then
    if arg == 16 then
      utils.notify("Checkboxes already reset")
    else
      utils.warn("Cannot toggle this checkbox: " .. (box == "X" and "all subitems checked" or "unchecked subitems"))
    end
    return
  end
  apply_struct(struct)
  M.update_statistics_for(bufnr, item.lnum)
  if block then
    utils.notify(string.format("Checkboxes were removed due to empty box at line %d", block.lnum))
  end
end

--- org-toggle-checkbox on the items starting in [s, e] (`singlep` for a
--- single item).
local function toggle_checkbox_range(bufnr, s, e, arg, singlep)
  local lists = M.section_lists(bufnr, s)
  local first
  for _, l in ipairs(lists) do
    local function walk(its)
      for _, it in ipairs(its) do
        if it.lnum >= s and it.lnum <= e and (not first or it.lnum < first.lnum) then
          first = it
        end
        walk(it.children)
      end
    end
    walk(l.items)
  end
  if not first then
    return false
  end
  local ref
  if arg == 16 then
    ref = "-"
  elseif arg == 4 then
    ref = not first.checkbox and " " or nil
  elseif first.checkbox == "X" then
    ref = " "
  else
    ref = "X"
  end
  local ordered = ordered_p(bufnr, s)
  local lnum = first.lnum
  local done = {}
  while lnum and lnum <= e do
    local struct = M.struct_at(bufnr, lnum)
    if not struct or done[struct.first] then
      break
    end
    done[struct.first] = true
    for _, it in ipairs(struct.items) do
      if it.lnum >= s and it.lnum <= e and (it.checkbox or arg == 4) then
        it.box = ref
      end
    end
    fix_ind(struct)
    fix_bul(struct)
    fix_ind(struct)
    local block = fix_box(struct, ordered)
    if singlep and block and s > block.lnum then
      utils.warn(string.format("Checkbox blocked because of unchecked box at line %d", block.lnum))
      return
    elseif block then
      utils.notify(string.format("Checkboxes were removed due to unchecked box at line %d", block.lnum))
    end
    apply_struct(struct)
    -- next list starting in the range
    local next_lnum
    for _, l in ipairs(M.section_lists(bufnr, s)) do
      local fl = l.items[1].lnum
      if fl > struct.last and fl <= e and (not next_lnum or fl < next_lnum) then
        next_lnum = fl
      end
    end
    lnum = next_lnum
  end
  M.update_statistics_for(bufnr, s)
  return true
end

--- Toggle checkboxes (org-toggle-checkbox, C-c C-x C-b): the item at the
--- cursor, every item of the Visual selection (following the first one),
--- or on a headline every item of the entry's text. Items without a
--- checkbox are left alone; with a count of 4 (C-u) checkboxes are added
--- or removed instead, and 16 (C-u C-u) sets them to `[-]`. A radio list
--- (`#+attr_org: :radio t`) toggles like a radio button. Returns false
--- when there is no item.
function M.toggle_checkbox()
  local bufnr = vim.api.nvim_get_current_buf()
  local arg = vim.v.count > 0 and vim.v.count or nil
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local s, _, e = utils.visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    if toggle_checkbox_range(bufnr, s, e, arg, false) == false then
      utils.warn("No item in region")
    end
    return
  end
  local lnum = cursor_lnum()
  local file = files.get_buffer(bufnr)
  local hl = file:headline_on(lnum)
  if hl then
    local from = require("org.edit").meta_end(hl) + 1
    if toggle_checkbox_range(bufnr, from, hl.body_end, arg, false) == false then
      utils.warn("No item in subtree")
    end
    return
  end
  local item = M.item_on(bufnr, lnum)
  if not item then
    return false
  end
  if M.radio_list_p(bufnr, item) then
    return M.toggle_radio_button(arg)
  end
  toggle_checkbox_range(bufnr, lnum, lnum, arg, true)
end

---------------------------------------------------------------------------
-- Item editing
---------------------------------------------------------------------------

--- Number of blank lines to put between items when inserting after
--- `item` (org-list-separating-blank-lines-number).
local function separating_blank_lines(bufnr, item, pos_lnum)
  local b = require("org.config").opts.blank_before_new_entry
  local v = type(b) == "table" and b.plain_list_item
  if not v then
    return 0
  elseif v == true then
    return 1
  end
  local function count_blanks(lnum)
    local n = 0
    local l = lnum - 1
    while l >= 1 and is_blank(get_lines(bufnr, l, l)[1]) do
      n = n + 1
      l = l - 1
    end
    return n
  end
  local sibs = M.siblings(item)
  local idx
  for i, s in ipairs(sibs) do
    if s == item then
      idx = i
    end
  end
  if sibs[idx + 1] then
    return count_blanks(sibs[idx + 1].lnum)
  elseif sibs[idx - 1] then
    return count_blanks(item.lnum)
  end
  if pos_lnum > item.end_lnum then
    local n = count_blanks(pos_lnum)
    if n > 0 then
      return n
    end
  end
  local top = item
  while top.parent do
    top = top.parent
  end
  for l = top.list.items[1].lnum, item.end_lnum do
    if is_blank(get_lines(bufnr, l, l)[1]) then
      return 1
    end
  end
  return 0
end

--- Column right after the bullet, counter, checkbox and description tag
--- of an item line (the match end of org-list-full-item-re).
local function after_bullet_col(line, item)
  local col = item.content_col
  if item.tag then
    local _, e = line:find("^.-%s+::%s*", col + 1)
    if e then
      col = e
    end
  end
  return col
end

--- Insert a new item (org-insert-item). At or before the item's text, the
--- new item goes before it; otherwise the rest of the item after point
--- moves to the new item when the line may be split
--- (`meta_return_split_line`), else the new item goes after the item.
---@param opts? { checkbox?: boolean, pos?: integer[], split?: boolean }
function M.new_item(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local pos = opts.pos or vim.api.nvim_win_get_cursor(0)
  local item = M.item_at(bufnr, pos[1])
  if not item then
    return false
  end
  local first = get_lines(bufnr, item.lnum, item.lnum)[1]
  if first:sub(item.content_col + 1):match("^[-+]?%d+:%d%d:%d%d%s+::") then
    -- timer list: org-timer-item
    return require("org.timer").insert_item()
  end
  local split = opts.split
  if split == nil then
    split = require("org.structure").may_split_line("item")
  end
  local desc = item.tag ~= nil and not item.is_ordered
  local beforep = pos[1] == item.lnum and pos[2] <= after_bullet_col(first, item)
  local blank_nb = separating_blank_lines(bufnr, item, pos[1])
  local body = item.bullet .. " "
  if opts.checkbox then
    body = body .. "[ ] "
  end
  local cursor_col = #body
  if desc then
    body = body .. " :: "
  end
  local prefix = string.rep(" ", item.indent)
  local new_lnum
  if beforep then
    local new = { prefix .. body }
    for _ = 1, blank_nb do
      new[#new + 1] = ""
    end
    set_lines(bufnr, item.lnum, item.lnum - 1, new)
    new_lnum = item.lnum
  else
    -- the text after point (skipping whitespace back) moves to the new item
    local r0, c0 = item.end_lnum, #get_lines(bufnr, item.end_lnum, item.end_lnum)[1]
    if split then
      r0, c0 = pos[1], pos[2]
      local l = get_lines(bufnr, r0, r0)[1]
      if r0 > item.end_lnum then
        r0, c0 = item.end_lnum, #get_lines(bufnr, item.end_lnum, item.end_lnum)[1]
      else
        c0 = math.min(c0, #l)
        while true do
          local cur = get_lines(bufnr, r0, r0)[1]
          while c0 > 0 and cur:sub(c0, c0):match("[ \t]") do
            c0 = c0 - 1
          end
          if c0 == 0 and r0 > item.lnum then
            r0 = r0 - 1
            c0 = #get_lines(bufnr, r0, r0)[1]
          else
            break
          end
        end
      end
    end
    local region = get_lines(bufnr, r0, item.end_lnum)
    local head = region[1]:sub(1, c0)
    local cut_first = region[1]:sub(c0 + 1):gsub("^[ \t]+", "")
    local new = { head }
    for _ = 1, blank_nb do
      new[#new + 1] = ""
    end
    new[#new + 1] = prefix .. body .. cut_first
    new_lnum = r0 + 1 + blank_nb
    for i = 2, #region do
      new[#new + 1] = region[i]
    end
    set_lines(bufnr, r0, item.end_lnum, new)
  end
  M.repair(bufnr, new_lnum)
  local final = get_lines(bufnr, new_lnum, new_lnum)[1]
  local parsed = M.parse_item_line(final)
  local col = indent_of(final) + (parsed and #parsed.bullet_ws or cursor_col)
  if opts.checkbox then
    col = col + 4
  end
  vim.api.nvim_win_set_cursor(0, { new_lnum, math.min(col, #final) })
  if opts.checkbox then
    M.update_statistics_for(bufnr, new_lnum)
  end
end

--- Indent (delta > 0) or outdent (delta < 0) list items
--- (org-list-indent-item-generic): the item at the cursor alone
--- (`with_children` false, M-left/right), with its children (M-S-left/
--- right), or every item starting in `range` ({ first, last } lines, a
--- Visual selection). On the first item of a list, M-S-left/right moves
--- the whole list.
---@return boolean|nil false when not on an item
function M.indent_item(delta, with_children, range)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = range and range[1] or cursor_lnum()
  if range then
    -- the region must start at an item
    local l = range[1]
    while l <= range[2] and is_blank(get_lines(bufnr, l, l)[1]) do
      l = l + 1
    end
    lnum = l
    if not M.item_on(bufnr, lnum) then
      utils.warn("Region not starting at an item")
      return
    end
  end
  local struct, item = M.struct_at(bufnr, lnum)
  if not struct then
    return false
  end
  return protected(function()
    local top = struct.items[1]
    local specialp = not range and item == top
    if specialp and not with_children then
      user_error("At first item: use S-M-<left/right> to move the whole list")
    end
    local zs, ze -- zone of items [zs, ze]
    if range then
      zs, ze = range[1], range[2]
    elseif with_children then
      zs, ze = item.lnum, item.end_lnum
    else
      zs, ze = item.lnum, item.lnum
    end
    local function in_zone(it)
      return it.lnum >= zs and it.lnum <= ze
    end
    if specialp then
      local offset = delta > 0 and M.level_increment() or -M.level_increment()
      if top.indent + offset < 0 then
        user_error("Cannot outdent beyond margin")
      end
      if top.indent + offset == 0 and top.bullet == "*" then
        top.bul = "- "
      end
      for _, it in ipairs(struct.items) do
        it.ind = it.indent + offset
      end
      fix_bul(struct)
      apply_struct(struct)
      return true
    end
    if delta < 0 then
      local last
      for _, it in ipairs(struct.items) do
        if it.lnum <= ze then
          last = it
        end
      end
      if (with_children == false and not range and #item.children > 0) or (last and #last.children > 0) then
        user_error("Cannot outdent an item without its children")
      end
      -- org-list-struct-outdent
      local acc = {}
      for _, it in ipairs(struct.items) do
        local parent = it.parent
        if it.lnum < zs then
          -- keep
        elseif it.lnum > ze then
          if parent and acc[parent] then
            it.par = acc[parent]
          end
        elseif not parent then
          user_error("Cannot outdent top-level items")
        elseif in_zone(parent) then
          acc[parent] = it
        else
          acc[parent] = it
          it.par = parent.parent
        end
      end
    else
      -- org-list-struct-indent
      local acc = {}
      for _, it in ipairs(struct.items) do
        local parent = it.parent
        if it.lnum < zs then
          -- keep
        elseif it.lnum > ze then
          if parent and acc[parent] ~= nil then
            it.par = acc[parent] or nil
          end
        else
          local sibs = M.siblings(it)
          local prev
          for i, s in ipairs(sibs) do
            if s == it then
              prev = sibs[i - 1]
            end
          end
          if not prev and (not parent or parent.lnum < zs) then
            user_error("Cannot indent the first item of a list")
          elseif not prev then
            acc[it] = it.par or false
          elseif prev.lnum < zs then
            it.par = prev
            acc[it] = prev
          else
            it.par = acc[prev] or nil
            acc[it] = acc[prev]
          end
        end
      end
    end
    write_struct(struct, ordered_p(bufnr, lnum))
    M.update_statistics_for(bufnr, lnum)
    return true
  end)
end

--- Indentation step of the whole-list move (org-level-increment).
function M.level_increment()
  return require("org.structure").odd_levels_only() and 2 or 1
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
    utils.warn("Cannot move this item further " .. (dir < 0 and "up" or "down"))
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

--- On an empty item (only a bullet, maybe a checkbox), cycle its
--- indentation (org-cycle-item-indentation, TAB right after M-RET): the
--- first TAB makes it a child of the previous item, the next ones outdent
--- it level by level, then it returns to where it started. Returns false
--- when the item is not empty.
function M.cycle_item_indentation()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cursor_lnum()
  local line = vim.api.nvim_get_current_line()
  local parsed = M.parse_item_line(line)
  local state = vim.b[bufnr].org_tab_ind_state
  local continuing = state
    and state.lnum == lnum
    and state.tick == vim.api.nvim_buf_get_changedtick(bufnr)
  if not continuing then
    if not parsed or vim.trim(parsed.text) ~= "" or parser.headline_level(line) then
      return false
    end
  end
  local item = M.item_at(bufnr, lnum)
  if not item or item.lnum ~= lnum or (not continuing and #item.children > 0) then
    return false
  end
  local function sib_info(it)
    local sibs = M.siblings(it)
    local prev, nxt
    for i, s in ipairs(sibs) do
      if s == it then
        prev, nxt = sibs[i - 1], sibs[i + 1]
      end
    end
    return prev, nxt
  end
  local function allow_outdent(it)
    local _, nxt = sib_info(it)
    return not nxt and #it.children == 0 and it.parent ~= nil
  end
  local function finish()
    local new = vim.api.nvim_get_current_line()
    vim.api.nvim_win_set_cursor(0, { lnum, #new })
  end
  local ok = protected(function()
    if continuing then
      local ind = item.indent
      local prev = sib_info(item)
      if ind > state.ind and prev then
        M.indent_item(1, false)
      elseif ind < state.ind and allow_outdent(item) then
        M.indent_item(-1, false)
      else
        set_lines(bufnr, lnum, lnum, { string.rep(" ", state.ind) .. state.bul .. " " })
        local restored = M.item_at(bufnr, lnum)
        if ind > state.ind and restored and allow_outdent(restored) then
          M.indent_item(-1, false)
        else
          M.repair(bufnr, lnum)
          vim.b[bufnr].org_tab_ind_state = nil
          finish()
          return true
        end
      end
    else
      local prev, nxt = sib_info(item)
      vim.b[bufnr].org_tab_ind_state = { ind = item.indent, bul = vim.trim(line) }
      state = vim.b[bufnr].org_tab_ind_state
      if prev then
        M.indent_item(1, false)
      elseif not nxt and item.parent then
        M.indent_item(-1, false)
      else
        vim.b[bufnr].org_tab_ind_state = nil
        user_error("Cannot move item")
      end
    end
    finish()
    local st = vim.b[bufnr].org_tab_ind_state
    if st then
      st.lnum = lnum
      st.tick = vim.api.nvim_buf_get_changedtick(bufnr)
      vim.b[bufnr].org_tab_ind_state = st
    end
    return true
  end)
  return ok ~= nil and true or nil
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
  local struct = M.struct_at(bufnr, lnum)
  local first = M.siblings(item)[1]
  for _, it in ipairs(struct.items) do
    if it.lnum == first.lnum then
      it.bul = nxt .. " "
    end
  end
  write_struct(struct, ordered_p(bufnr, lnum))
end

--- Shift non-blank, non-headline lines of [s, e] so that the least
--- indented one is at `ind` (the shift-text helper of org-toggle-item).
local function shift_text(lines, s, e, ind)
  local min_i = 1000
  for i = s, e do
    local l = lines[i]
    if not is_blank(l) and not parser.headline_level(l) then
      min_i = math.min(min_i, indent_of(l))
    end
  end
  local delta = ind - min_i
  for i = s, e do
    local l = lines[i]
    if not is_blank(l) and not parser.headline_level(l) then
      local n = indent_of(l)
      lines[i] = string.rep(" ", math.max(0, n + delta)) .. l:sub(n + 1)
    end
  end
end

--- org-toggle-item (C-c -): items become text lines, headlines become
--- items (TODO keywords become checkboxes, tags and planning are dropped,
--- the text of each entry moves into its item), text lines become items.
--- In Visual mode, every line of the selection; with a count (C-u), the
--- first text line becomes one item holding the others.
function M.toggle_item()
  local bufnr = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local arg = vim.v.count > 0
  local s, e
  local region = mode == "v" or mode == "V" or mode == "\22"
  if region then
    s, _, e = utils.visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    while s < e and is_blank(get_lines(bufnr, s, s)[1]) do
      s = s + 1
    end
  else
    s = cursor_lnum()
    e = s
  end
  local file = files.get_buffer(bufnr)
  local todo_cfg = file.settings.todo
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local first = lines[s]
  if M.item_on(bufnr, s) then
    -- 1. de-itemize (the checkbox stays)
    for i = s, e do
      local it = M.parse_item_line(lines[i])
      if it and not parser.headline_level(lines[i]) then
        lines[i] = string.rep(" ", it.indent) .. lines[i]:sub(it.indent + #it.bullet_ws + 1)
      end
    end
    set_lines(bufnr, s, e, vim.list_slice(lines, s, e))
    return
  end
  if parser.headline_level(first) then
    -- 2. headlines to items
    local ref_level = parser.headline_level(first)
    local out = {}
    local i = s
    local last_item_ind = 0
    local pending_start
    local function flush_text(stop)
      if pending_start and pending_start <= stop then
        local seg = vim.list_slice(lines, pending_start, stop)
        shift_text(seg, 1, #seg, last_item_ind)
        vim.list_extend(out, seg)
      end
      pending_start = nil
    end
    local section_last = #lines
    while i <= e do
      local l = lines[i]
      local level = parser.headline_level(l)
      if level then
        flush_text(i - 1)
        if level < ref_level then
          ref_level = level
        end
        local delta = math.max(0, level - ref_level)
        local p = parser.parse_headline_line(l, todo_cfg)
        local text = p.title
        if p.priority then
          text = "[#" .. p.priority .. "] " .. text
        end
        if p.commented then
          text = "COMMENT " .. text
        end
        local ind = delta * 2
        local item = string.rep(" ", ind) .. "- "
        if p.todo then
          item = item .. (todo_cfg:is_done(p.todo) and "[X] " or "[ ] ")
        end
        out[#out + 1] = (item .. text):gsub("%s+$", "")
        last_item_ind = ind + 2
        -- drop planning, property drawer and blank lines after them
        local j = i + 1
        local hl = file:headline_on(i)
        if hl then
          local meta = require("org.edit").meta_end(hl)
          if meta > i then
            j = meta + 1
            while j <= hl.body_end and is_blank(lines[j]) do
              j = j + 1
            end
          end
        end
        i = j
        -- body text down to the region end or the section end
        section_last = e
        for k = i, #lines do
          if parser.headline_level(lines[k]) then
            section_last = math.min(e, k - 1)
            break
          end
        end
        if region then
          pending_start = i
        else
          pending_start = nil
          break
        end
      else
        i = i + 1
      end
    end
    if region then
      flush_text(math.min(e, section_last))
    end
    local stop = region and e or s
    if not region then
      -- only the headline line (and its metadata) changes
      local hl = file:headline_on(s)
      local meta = hl and require("org.edit").meta_end(hl) or s
      stop = meta
      if meta > s then
        while stop + 1 <= (hl and hl.body_end or s) and is_blank(lines[stop + 1]) do
          stop = stop + 1
        end
      end
    end
    set_lines(bufnr, s, stop, out)
    M.repair(bufnr, s)
    return
  end
  if arg then
    -- 3. one item holding the region
    local ind = indent_of(first)
    lines[s] = first:sub(1, ind) .. "- " .. first:sub(ind + 1)
    if e > s then
      shift_text(lines, s + 1, e, ind + 2)
    end
    set_lines(bufnr, s, e, vim.list_slice(lines, s, e))
    return
  end
  -- 4. every text line becomes an item
  for i = s, e do
    local l = lines[i]
    if not is_blank(l) and not parser.headline_level(l) and not M.parse_item_line(l) then
      local ind = l:match("^(%s*)")
      lines[i] = ind .. "- " .. l:sub(#ind + 1)
    end
  end
  set_lines(bufnr, s, e, vim.list_slice(lines, s, e))
end

--- Turn the whole list at the cursor into a subtree (org-list-make-subtree,
--- C-c C-*): each item becomes a headline one level below the current
--- entry, checkboxes become TODO / DONE keywords.
function M.make_subtree()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cursor_lnum()
  local struct = M.struct_at(bufnr, lnum)
  if not struct then
    utils.warn("Not in a list")
    return
  end
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(struct.first)
  local level = hl and hl.level + 1 or 1
  local out = M.list_to_subtree(bufnr, struct, level)
  set_lines(bufnr, struct.first, struct.last, out)
  vim.api.nvim_win_set_cursor(0, { math.min(struct.first + #out, vim.api.nvim_buf_line_count(bufnr)), 0 })
end

--- Headline lines for the items of `struct` (org-list-to-subtree).
---@param items? org.ListItem[] only these top items (default: all)
function M.list_to_subtree(bufnr, struct, level, items)
  local todo_cfg = files.get_buffer(bufnr).settings.todo
  local done_kw = todo_cfg:done_names()[1] or "DONE"
  local todo_kw = todo_cfg:todo_names()[1] or "TODO"
  local out = {}
  local owners = line_owners(struct)
  local lines = get_lines(bufnr, struct.first, struct.last)
  local function emit(it, depth)
    local line = lines[it.lnum - struct.first + 1]
    local text = line:sub(it.content_col + 1)
    if it.tag then
      local term, desc = text:match("^(.-)%s+::%s*(.*)$")
      text = " " .. (term or "") .. " " .. (desc or "")
    end
    local kw = ""
    if it.checkbox == "X" then
      kw = done_kw .. " "
    elseif it.checkbox then
      kw = todo_kw .. " "
    end
    out[#out + 1] = (string.rep("*", level + depth - 1) .. " " .. kw .. text):gsub("%s+$", "")
    for l = it.lnum + 1, it.end_lnum do
      if owners[l] == it and not is_blank(lines[l - struct.first + 1]) then
        out[#out + 1] = vim.trim(lines[l - struct.first + 1])
      end
    end
    for _, c in ipairs(it.children) do
      emit(c, depth + 1)
    end
  end
  for _, it in ipairs(items or struct.items[1].list.items) do
    emit(it, 1)
  end
  return out
end

---------------------------------------------------------------------------
-- Sorting (used by org.structure.sort)
---------------------------------------------------------------------------

--- Sort the sibling group of the item at `lnum`. `keyfn(item, lines)`
--- returns the sort key; `less(a, b)` compares two keys.
function M.sort_items(bufnr, lnum, keyfn, less)
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
  -- the last item has no trailing blank lines: keep the separation of
  -- the others when it moves up
  local sep = {}
  local last = blocks[#blocks].lines
  local b1 = blocks[1].lines
  local k = #b1
  while k > 1 and is_blank(b1[k]) do
    sep[#sep + 1] = ""
    k = k - 1
  end
  table.sort(blocks, function(a, b)
    if less(a.key, b.key) then
      return true
    elseif less(b.key, a.key) then
      return false
    end
    return a.idx < b.idx
  end)
  local out = {}
  for i, b in ipairs(blocks) do
    local lines = vim.deepcopy(b.lines)
    while #lines > 1 and is_blank(lines[#lines]) do
      table.remove(lines)
    end
    vim.list_extend(out, lines)
    if i < #blocks then
      vim.list_extend(out, sep)
    end
  end
  local _ = last
  set_lines(bufnr, sibs[1].lnum, sibs[#sibs].end_lnum, out)
  M.repair(bufnr, sibs[1].lnum)
  return true
end

return M
