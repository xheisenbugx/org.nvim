---@mod org.lists.convert Bullets and conversions
---
--- Cycling bullets, org-toggle-item, turning a list into a subtree and
--- sorting items (used by org.structure.sort).
--- Part of org.lists, which loads it.

local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")
local shared = require("org.lists.shared")

local M = require("org.lists")

local apply_struct = shared.apply_struct
local bullet_string = shared.bullet_string
local cursor_lnum = shared.cursor_lnum
local fix_bul = shared.fix_bul
local fix_ind = shared.fix_ind
local get_lines = shared.get_lines
local indent_of = shared.indent_of
local is_blank = shared.is_blank
local line_owners = shared.line_owners
local lopt = shared.lopt
local set_lines = shared.set_lines
local use_alpha = shared.use_alpha

--- Cycle the bullet type of the list at cursor (org-cycle-list-bullet)
--- through `-`, `+`, `*` (not at column 0), `1.`, `1)` and, with
--- lists.allow_alphabetical and at most 26 items, `a.`, `A.`, `a)`,
--- `A)`. `dir` is 1 (next), -1
--- (previous), a bullet string or a 0-based index into the sequence.
function M.cycle_bullet(dir)
  dir = dir or 1
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cursor_lnum()
  local struct, item = M.struct_at(bufnr, lnum)
  if not struct then
    return false
  end
  local first = M.siblings(item)[1]
  local bullet = first.bullet
  local alpha = use_alpha(struct, first)
  local current
  if bullet:match("^%l%.") then
    current = "a."
  elseif bullet:match("^%l%)") then
    current = "a)"
  elseif bullet:match("^%u%.") then
    current = "A."
  elseif bullet:match("^%u%)") then
    current = "A)"
  elseif bullet:match("%.") then
    current = "1."
  elseif bullet:match("%)") then
    current = "1)"
  else
    current = bullet
  end
  local term = lopt("ordered_item_terminator")
  -- Emacs means to keep description lists unnumbered, but its test
  -- (org-at-item-description-p) never matches here: they get numbered
  local desc = false
  local list = { "-", "+" }
  if item.indent > 0 then
    list[#list + 1] = "*"
  end
  if not desc and term ~= ")" then
    list[#list + 1] = "1."
  end
  if not desc and term ~= "." then
    list[#list + 1] = "1)"
  end
  if alpha and not desc and term ~= ")" then
    list[#list + 1] = "a."
    list[#list + 1] = "A."
  end
  if alpha and not desc and term ~= "." then
    list[#list + 1] = "a)"
    list[#list + 1] = "A)"
  end
  local n = #list
  local idx = n -- `current` not in the list: as if after the last one
  for i, b in ipairs(list) do
    if b == current then
      idx = i - 1
      break
    end
  end
  local new
  if type(dir) == "string" and vim.tbl_contains(list, dir) then
    new = dir
  elseif type(dir) == "string" then
    new = list[(idx + 1) % n + 1]
  elseif dir == 1 or dir == -1 then
    new = list[(idx + dir) % n + 1]
  else
    new = list[dir % n + 1]
  end
  first.bul = bullet_string(new)
  fix_bul(struct)
  fix_ind(struct)
  apply_struct(struct)
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
    utils.exit_visual()
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
      local desc = text:sub(#it.tag + 1):gsub("^%s+::%s*", "")
      text = " " .. it.tag .. " " .. desc
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
