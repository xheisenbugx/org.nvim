---@mod org.lists.struct List structures
---
--- org-list-struct / org-list-write-struct: fixing bullets, indentation
--- and checkboxes of a list structure and writing it back, and repair.
--- Part of org.lists, which loads it.

local shared = require("org.lists.shared")

local M = require("org.lists")

local curbuf = shared.curbuf
local cursor_lnum = shared.cursor_lnum
local get_lines = shared.get_lines
local indent_of = shared.indent_of
local is_blank = shared.is_blank
local lopt = shared.lopt
local ordered_p = shared.ordered_p
local set_lines = shared.set_lines

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

local two_spaces_cache = {}

--- Whether `bullet` matches lists.two_spaces_after_bullet_regexp.
local function two_spaces_p(bullet)
  local re = lopt("two_spaces_after_bullet_regexp")
  if not re or re == "" then
    return false
  end
  local rx = two_spaces_cache[re]
  if rx == nil then
    local ok, r = pcall(vim.regex, require("org.agenda.search").emacs_regexp(re))
    rx = ok and r or false
    two_spaces_cache[re] = rx
  end
  return rx and rx:match_str(bullet) ~= nil or false
end

--- Bullet followed by one space, or two when it matches
--- lists.two_spaces_after_bullet_regexp (org-list-bullet-string).
local function bullet_string(b)
  local core = b:match("^(%S+)")
  if not core then
    return b
  end
  return core .. (two_spaces_p(b) and "  " or " ")
end
M.bullet_string = bullet_string

--- Column at which the body of `item` starts (org-list-item-body-column):
--- one space after the bullet, two when it matches
--- lists.two_spaces_after_bullet_regexp.
---@param item org.ListItem
---@return integer
function M.body_column(item)
  return item.indent + #item.bullet + (two_spaces_p(item.bullet) and 2 or 1)
end

--- org-list-inc-bullet-maybe: "1." -> "2.", "a)" -> "b)".
local function inc_bullet(b)
  local n = b:match("%d+")
  if n then
    return (b:gsub("%d+", tostring(tonumber(n) + 1), 1))
  end
  local c = b:match("%a")
  if c then
    return (b:gsub("%a", string.char(c:byte() + 1), 1))
  end
  return b
end

--- Siblings of `first` under the new parents, from `first` on.
local function new_siblings_from(struct, first)
  local out = {}
  for i = first.idx, #struct.items do
    local it = struct.items[i]
    if it.par == first.par then
      out[#out + 1] = it
    end
  end
  return out
end

--- org-list-use-alpha-bul-p: whether the list starting at `first` can
--- have alphabetical bullets (lists.allow_alphabetical, at most 26 items,
--- counters included).
local function use_alpha(struct, first)
  if not lopt("allow_alphabetical") then
    return false
  end
  local ascii = 64
  for _, it in ipairs(new_siblings_from(struct, first)) do
    local c = it.counter
    if c and c:match("%a") then
      ascii = c:upper():byte()
    else
      ascii = ascii + 1
    end
    if ascii > 90 then
      return false
    end
  end
  return true
end

--- The counter's letter in the case of the letter in `bul`.
local function alpha_count(counter, bul)
  if bul:match("%l") then
    return counter:lower()
  end
  return counter:upper()
end

--- org-list-struct-fix-bul.
local function fix_bul(struct)
  for _, it in ipairs(struct.items) do
    local prev = new_prev(struct, it)
    local prev_bul = prev and prev.bul
    local counter = it.counter
    local bullet = it.bul
    local alphap = not prev and use_alpha(struct, it)
    local b
    if prev and counter and counter:match("%a") and prev_bul:match("%a") then
      -- alpha counter in an alpha list
      -- lint: allow gsub: a [@N] counter is digits or a letter
      b = prev_bul:gsub("%a", alpha_count(counter, prev_bul), 1)
    elseif prev and counter and counter:match("%d+") and prev_bul:match("%d+") then
      -- numeric counter in a numbered list
      -- lint: allow gsub: a [@N] counter is digits or a letter
      b = prev_bul:gsub("%d+", counter, 1)
    elseif prev then
      b = inc_bullet(prev_bul)
    elseif counter and use_alpha(struct, it) and counter:match("%a") and bullet:match("%a") then
      -- lint: allow gsub: a [@N] counter is digits or a letter
      b = bullet:gsub("%a", alpha_count(counter, bullet), 1)
    elseif counter and counter:match("%d+") and bullet:match("%d+") then
      -- lint: allow gsub: a [@N] counter is digits or a letter
      b = bullet:gsub("%d+", counter, 1)
    elseif alphap and bullet:match("%u") then
      b = bullet:gsub("%u", "A", 1)
    elseif alphap and bullet:match("%l") then
      b = bullet:gsub("%l", "a", 1)
    elseif bullet:match("^%d") then
      b = bullet:gsub("%d+", "1", 1)
    elseif bullet:match("^%a") then
      -- more than 26 items: back to numbers
      b = bullet:gsub("%a", "1", 1)
    else
      b = bullet
    end
    it.bul = bullet_string(b)
  end
end

--- org-list-struct-fix-ind: items align with their parent's text, plus
--- lists.indent_offset.
local function fix_ind(struct)
  local top_ind = struct.items[1].ind
  local offset = lopt("indent_offset") or 0
  for _, it in ipairs(struct.items) do
    if it.par then
      it.ind = it.par.ind + #it.par.bul + offset
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
    -- [@N], [@c] or [@start:N] (a new box goes right after it)
    local counter = it.counter and rest:match("^%[@[^%]]*%]")
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

shared.apply_struct = apply_struct
shared.bullet_string = bullet_string
shared.fix_box = fix_box
shared.fix_bul = fix_bul
shared.fix_ind = fix_ind
shared.line_owners = line_owners
shared.struct_changed = struct_changed
shared.use_alpha = use_alpha
shared.write_struct = write_struct
