---@mod org.lists.edit Editing items
---
--- Inserting items (org-insert-item), indenting and outdenting them,
--- moving them and jumping between siblings.
--- Part of org.lists, which loads it.

local utils = require("org.utils")
local shared = require("org.lists.shared")

local M = require("org.lists")

local apply_struct = shared.apply_struct
local bullet_string = shared.bullet_string
local cursor_lnum = shared.cursor_lnum
local fix_bul = shared.fix_bul
local get_lines = shared.get_lines
local indent_of = shared.indent_of
local is_blank = shared.is_blank
local lopt = shared.lopt
local ordered_p = shared.ordered_p
local protected = shared.protected
local set_lines = shared.set_lines
local user_error = shared.user_error
local write_struct = shared.write_struct

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
    local _, e = line:find("^.*%s+::$", col + 1)
    e = e or select(2, line:find("^.*%s+::%s+", col + 1))
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
    M.update_checkbox_count_maybe(bufnr, new_lnum)
  end
end

--- Whether the automatic list rule `name` ("checkbox" or "indent") is
--- on (org-list-automatic-rules).
function M.automatic_rule(name)
  local rules = lopt("automatic_rules") or {}
  return rules[name] ~= false
end

--- Update checkbox statistics after a list change when the `checkbox`
--- automatic rule is on (org-update-checkbox-count-maybe).
function M.update_checkbox_count_maybe(bufnr, lnum)
  if M.automatic_rule("checkbox") then
    M.update_statistics_for(bufnr, lnum)
  end
end

--- The key of a bullet in lists.demote_modify_bullet ("-", "1.", "a)"...).
local function demote_kind(b)
  if b:match("^%u%.") then
    return "A."
  elseif b:match("^%u%)") then
    return "A)"
  elseif b:match("^%l%.") then
    return "a."
  elseif b:match("^%l%)") then
    return "a)"
  elseif b:match("^%d+%.") then
    return "1."
  elseif b:match("^%d+%)") then
    return "1)"
  end
  return vim.trim(b)
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
    local specialp = not range and item == top and M.automatic_rule("indent")
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
          -- lists.demote_modify_bullet
          local kind = demote_kind(it.bul)
          local to = (lopt("demote_modify_bullet") or {})[kind]
          if to then
            it.bul = bullet_string(to)
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
    M.update_checkbox_count_maybe(bufnr, lnum)
    return true
  end)
end

--- Indentation step of the whole-list move (org-level-increment).
function M.level_increment()
  return require("org.structure").odd_levels_only() and 2 or 1
end

--- With lists.use_circular_motion, moving the last item down sends it to
--- the beginning of its list, and the first item up to the end
--- (org-list-send-item). The blank lines separating items are kept.
local function send_item_around(bufnr, item, sibs, dir)
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local offset = cursor_lnum() - item.lnum
  local body = get_lines(bufnr, item.lnum, item.end_lnum)
  local first, last = sibs[1], sibs[#sibs]
  local new_lnum
  if dir > 0 then
    -- last item: remove it with the blank lines before it
    local prev = sibs[#sibs - 1]
    local nblank = item.lnum - prev.end_lnum - 1
    set_lines(bufnr, prev.end_lnum + 1, item.end_lnum, {})
    local ins = vim.deepcopy(body)
    for _ = 1, nblank do
      ins[#ins + 1] = ""
    end
    set_lines(bufnr, first.lnum, first.lnum - 1, ins)
    new_lnum = first.lnum
  else
    -- first item: remove it with the blank lines after it
    local nxt = sibs[2]
    local nblank = nxt.lnum - item.end_lnum - 1
    local removed = nxt.lnum - item.lnum
    set_lines(bufnr, item.lnum, nxt.lnum - 1, {})
    local ins = {}
    for _ = 1, nblank do
      ins[#ins + 1] = ""
    end
    vim.list_extend(ins, body)
    local after = last.end_lnum - removed
    set_lines(bufnr, after + 1, after, ins)
    new_lnum = after + 1 + nblank
  end
  vim.api.nvim_win_set_cursor(0, { new_lnum + offset, col })
  M.repair(bufnr, new_lnum)
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
  if not other and lopt("use_circular_motion") then
    if #sibs > 1 then
      send_item_around(bufnr, item, sibs, dir)
    end
    return
  end
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
--- list level (org-next-item / org-previous-item). With
--- lists.use_circular_motion, the last item is followed by the first.
--- Returns false when not on a list item.
function M.goto_sibling_item(dir)
  local bufnr = vim.api.nvim_get_current_buf()
  local item = M.item_at(bufnr, cursor_lnum())
  if not item then
    return false
  end
  local circular = lopt("use_circular_motion")
  local target = item
  for _ = 1, math.max(vim.v.count, 1) do
    local sibs = M.siblings(target)
    local idx
    for i, s in ipairs(sibs) do
      if s == target then
        idx = i
      end
    end
    local nxt = sibs[idx + dir]
    if not nxt and circular then
      nxt = dir > 0 and sibs[1] or sibs[#sibs]
    end
    if not nxt then
      break
    end
    target = nxt
  end
  if target == item and not circular then
    utils.warn(dir > 0 and "On last item" or "On first item")
    return
  end
  vim.api.nvim_win_set_cursor(0, { target.lnum, target.indent })
end
