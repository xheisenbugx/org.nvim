---@mod org.textobjects Text objects
---
--- The Operator-pending and Visual mode text objects of org buffers
--- (|org-textobj|): heading section, subtree, element, list item, table
--- cell / row / column, link and timestamp, each "inner" and "around".
--- `mappings.text_objects` binds them; `org.mappings` calls `select`.
---
--- A count selects an ancestor for the objects that nest (heading,
--- subtree, element, item: `2ar` is the parent subtree) and that many rows
--- for `aR`; typing the object again in Visual mode when it is already
--- selected grows the selection to the enclosing one, like `ap`.

local files = require("org.files")
local utils = require("org.utils")

local M = {}

---@class org.TextObjectRange
---@field mode string "v", "V" or "\22" (charwise, linewise, blockwise)
---@field s integer[] { lnum, col0 } start
---@field e integer[] { lnum, col0 } end (inclusive)

local function get_line(lnum)
  return vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
end

local function is_blank(line)
  return line == nil or line:match("^%s*$") ~= nil
end

local function lines_range(s, e)
  return { mode = "V", s = { s, 0 }, e = { e, 0 } }
end

local function chars_range(sl, sc, el, ec)
  return { mode = "v", s = { sl, sc }, e = { el, ec } }
end

--- Byte positions (1-based) of the column separators of a table line:
--- `|`, and `+` in a horizontal rule.
local function separators(line)
  local hline = line:match("^%s*|%-") ~= nil
  local out = {}
  for i = 1, #line do
    local c = line:sub(i, i)
    if c == "|" or (hline and c == "+") then
      out[#out + 1] = i
    end
  end
  return out, hline
end

--- The whitespace that "around" adds to a span on one line, like `aw`:
--- the blanks after it, or when there are none, those before it.
local function with_blanks(line, s, e)
  local after = line:match("^[ \t]+", e + 1)
  if after then
    return s, e + #after
  end
  local before = line:sub(1, s - 1):match("[ \t]+$")
  if before and #before < s - 1 then
    return s - #before, e
  end
  return s, e
end

---------------------------------------------------------------------------
-- Objects. Each takes (inner, level) and returns a range or nil; `level`
-- (1 = the innermost) only matters to the ones that nest.
---------------------------------------------------------------------------

local function headline_at(level)
  local hl = files.get_buffer(0):headline_at(vim.api.nvim_win_get_cursor(0)[1])
  for _ = 2, level do
    if not hl or not hl.parent then
      return nil
    end
    hl = hl.parent
  end
  return hl
end

local objects = {}

--- The headline's section: its line (around) and its body up to the first
--- child.
function objects.heading(inner, level)
  local hl = headline_at(level)
  if not hl then
    return nil
  end
  if inner then
    return hl.body_end > hl.line and lines_range(hl.line + 1, hl.body_end) or nil
  end
  return lines_range(hl.line, hl.body_end)
end

--- The subtree: the headline line (around) and everything below it.
function objects.subtree(inner, level)
  local hl = headline_at(level)
  if not hl then
    return nil
  end
  if inner then
    return hl.end_line > hl.line and lines_range(hl.line + 1, hl.end_line) or nil
  end
  return lines_range(hl.line, hl.end_line)
end

--- Elements with a begin and an end line, whose contents are what is
--- between them.
local DELIMITED = {
  ["src-block"] = true,
  ["example-block"] = true,
  ["export-block"] = true,
  ["verse-block"] = true,
  ["comment-block"] = true,
  ["quote-block"] = true,
  ["center-block"] = true,
  ["special-block"] = true,
  ["dynamic-block"] = true,
  ["drawer"] = true,
  ["property-drawer"] = true,
}

--- The element (|org-elements|): inner is the contents of a block or
--- drawer, else the element without its affiliated keywords and the blank
--- lines after it; around is the whole element with both.
function objects.element(inner, level)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local el = require("org.element").at(0, lnum)
  for _ = 2, level do
    if not el or not el.parent then
      return nil
    end
    el = el.parent
  end
  if not el then
    return nil
  end
  if not inner then
    return lines_range(el.first, el.last)
  end
  if DELIMITED[el.type] then
    return el.cfirst and lines_range(el.cfirst, el.cend) or nil
  end
  return lines_range(el.post, el.clast)
end

--- The list item: inner is its text after the bullet and checkbox, up to
--- its first child (charwise); around is the item with its children, and
--- the blank lines before the next item (linewise).
function objects.item(inner, level)
  local lists = require("org.lists")
  local it = lists.item_at(0, vim.api.nvim_win_get_cursor(0)[1])
  for _ = 2, level do
    if not it or not it.parent then
      return nil
    end
    it = it.parent
  end
  if not it then
    return nil
  end
  if inner then
    local last = it.children[1] and it.children[1].lnum - 1 or it.end_lnum
    while last > it.lnum and is_blank(get_line(last)) do
      last = last - 1
    end
    local first_line = get_line(it.lnum)
    local start = it.content_col
    if last == it.lnum and start >= #first_line then
      return nil -- no text
    end
    if start >= #first_line then
      -- the text starts on the next line
      local l = it.lnum + 1
      return chars_range(l, #get_line(l):match("^%s*"), last, math.max(#get_line(last) - 1, 0))
    end
    return chars_range(it.lnum, start, last, math.max(#get_line(last) - 1, 0))
  end
  local stop = it.end_lnum
  local sibs = lists.siblings(it)
  for i, s in ipairs(sibs) do
    if s == it and sibs[i + 1] then
      stop = sibs[i + 1].lnum - 1
    end
  end
  return lines_range(it.lnum, stop)
end

--- The table at the cursor: { start, finish } or nil (not in a table, or
--- in a table.el table).
local function table_at(lnum)
  local line = get_line(lnum)
  if not line or not line:match("^%s*|") then
    return nil
  end
  return require("org.table").find(0, lnum)
end

--- Index of the field the byte column `col` (1-based) is in, given the
--- separator positions: on a separator, the field before it (the first
--- field on the leading one), like the table commands.
local function field_index(seps, col)
  local f = 0
  for _, p in ipairs(seps) do
    if p < col then
      f = f + 1
    end
  end
  return math.max(f, 1)
end

--- Byte span of field `f`: from after its separator through the next one
--- (around), or the trimmed contents (inner). The last field's "around"
--- takes the separator before it instead, so deleting it leaves a table.
local function field_span(line, seps, f, inner)
  local left = seps[f]
  if not left then
    return nil
  end
  local right = seps[f + 1]
  local s, e = left + 1, (right or #line + 1) - 1
  if inner then
    local text = line:sub(s, e)
    local lead = #text:match("^%s*")
    if lead < #text then
      local trail = #text:match("%s*$")
      return s + lead, e - trail
    end
    return s <= e and s or nil, e
  end
  local is_last = not right or not seps[f + 2] and is_blank(line:sub(right + 1))
  if is_last then
    return left, e
  end
  return s, right
end

--- The table field: inner is its text (the blanks of an empty field);
--- around adds the blanks and a separator.
function objects.cell(inner)
  local lnum, col = utils.cursor()
  if not table_at(lnum) then
    return nil
  end
  local line = get_line(lnum)
  local seps, hline = separators(line)
  if hline then
    return nil
  end
  local s, e = field_span(line, seps, field_index(seps, col), inner)
  if not s or e < s then
    return nil
  end
  return chars_range(lnum, s - 1, lnum, e - 1)
end

--- The table row: inner is the text between its first and last separator
--- (charwise); around is the whole line, `count` lines with a count.
function objects.row(inner, _, count)
  local lnum = utils.cursor()
  local tbl = table_at(lnum)
  if not tbl then
    return nil
  end
  if not inner then
    return lines_range(lnum, math.min(lnum + math.max(count, 1) - 1, tbl.finish))
  end
  local line = get_line(lnum)
  local seps = separators(line)
  local s, e = seps[1] + 1, (#seps > 1 and seps[#seps] or #line + 1) - 1
  if #seps > 1 and not is_blank(line:sub(seps[#seps] + 1)) then
    e = #line
  end
  if e < s then
    return nil
  end
  return chars_range(lnum, s - 1, lnum, e - 1)
end

--- The table column, as a block (Visual block mode): the field of every
--- row, rules included; around adds a separator like the field object.
--- The table must be aligned, so the column is a rectangle.
function objects.column(inner)
  local lnum, col = utils.cursor()
  local tbl = table_at(lnum)
  if not tbl then
    return nil
  end
  local line = get_line(lnum)
  local seps = separators(line)
  local f = field_index(seps, col)
  local first, last
  local from, to = tbl.start, tbl.finish
  for l = from, to do
    local text = get_line(l)
    local sp = separators(text)
    if not sp[f] then
      utils.warn("Align the table first: rows have different columns")
      return nil
    end
    local s, e = field_span(text, sp, f, false)
    if inner then
      s, e = sp[f] + 1, (sp[f + 1] or #text + 1) - 1
    end
    if not s or e < s then
      return nil
    end
    local vs, ve = vim.fn.strdisplaywidth(text:sub(1, s - 1)), vim.fn.strdisplaywidth(text:sub(1, e))
    if not first then
      first = { vs, ve, s, e }
    elseif first[1] ~= vs or first[2] ~= ve then
      utils.warn("Align the table first: columns don't line up")
      return nil
    end
    last = { s, e }
  end
  if not first or not last then
    return nil
  end
  return { mode = "\22", s = { from, first[3] - 1 }, e = { to, last[2] - 1 } }
end

--- A link at the cursor, or the first one after it on the line.
local function find_link()
  local lp = require("org.links")
  local lnum, col = utils.cursor()
  local lk = lp.link_at_cursor()
  if lk then
    return lk
  end
  for _, l in ipairs(lp.parse_links(get_line(lnum))) do
    if l.start_col > col then
      l.lnum, l.end_lnum = lnum, lnum
      return l
    end
  end
end

--- The link: inner is its description, or its target when it has none (the
--- text inside `<...>` of an angle link, all of a plain link); around is
--- the whole link and the blanks after it.
function objects.link(inner)
  local lk = find_link()
  if not lk then
    return nil
  end
  local sl, el = lk.lnum, lk.end_lnum or lk.lnum
  local s, e = lk.start_col, lk.end_col
  if inner then
    if lk.plain or lk.type == "radio" then
      return chars_range(sl, s - 1, el, e - 1)
    elseif lk.angle then
      return chars_range(sl, s, el, e - 2)
    elseif lk.desc and sl == el then
      if #lk.desc == 0 then
        return nil
      end
      return chars_range(sl, lk.desc_start - 1, el, lk.desc_start + #lk.desc - 2)
    end
    return chars_range(sl, s + 1, el, e - 3)
  end
  if sl == el then
    s, e = with_blanks(get_line(sl), s, e)
  end
  return chars_range(sl, s - 1, el, e - 1)
end

--- The timestamp (a range `<a>--<b>` as a whole): inner is the text inside
--- its brackets, around the timestamp and the blanks after it.
function objects.timestamp(inner)
  local lnum, col = utils.cursor()
  local line = get_line(lnum)
  local ts
  for _, item in ipairs(require("org.date").parse_all(line)) do
    if col <= item.end_col then
      ts = item
      break
    end
  end
  if not ts then
    return nil
  end
  local s, e = ts.start_col, ts.end_col
  if inner then
    return chars_range(lnum, s, lnum, e - 2)
  end
  s, e = with_blanks(line, s, e)
  return chars_range(lnum, s - 1, lnum, e - 1)
end

--- The objects whose count selects an ancestor.
local NESTING = { heading = true, subtree = true, element = true, item = true }

--- Text object names in display order: { config name, object, inner }.
M.list = {
  { "inner_heading", "heading", true },
  { "around_heading", "heading", false },
  { "inner_subtree", "subtree", true },
  { "around_subtree", "subtree", false },
  { "inner_element", "element", true },
  { "around_element", "element", false },
  { "inner_item", "item", true },
  { "around_item", "item", false },
  { "inner_cell", "cell", true },
  { "around_cell", "cell", false },
  { "inner_row", "row", true },
  { "around_row", "row", false },
  { "inner_column", "column", true },
  { "around_column", "column", false },
  { "inner_link", "link", true },
  { "around_link", "link", false },
  { "inner_timestamp", "timestamp", true },
  { "around_timestamp", "timestamp", false },
}

--- The current Visual selection as a range, or nil outside Visual mode.
---@return org.TextObjectRange|nil
local function visual_selection()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil
  end
  local a, b = vim.fn.getpos("v"), vim.fn.getpos(".")
  if a[2] > b[2] or (a[2] == b[2] and a[3] > b[3]) then
    a, b = b, a
  end
  return { mode = mode, s = { a[2], a[3] - 1 }, e = { b[2], b[3] - 1 } }
end

local function before_or_at(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] <= b[2])
end

--- The last range selected, to tell it from a selection made by hand.
local last

local function same(r1, r2)
  return r1.mode == r2.mode
    and r1.s[1] == r2.s[1]
    and r1.e[1] == r2.e[1]
    and (r1.mode == "V" or (r1.s[2] == r2.s[2] and r1.e[2] == r2.e[2]))
end

--- Whether the Visual selection `sel` already covers range `r`. A
--- selection of one character (or one line) covers nothing yet, as for
--- Vim's own objects, unless a text object just selected it.
local function covers(sel, r)
  local trivial = sel.s[1] == sel.e[1] and (sel.mode == "V" or sel.s[2] == sel.e[2])
  if
    trivial
    and not (
      last
      and last.buf == vim.api.nvim_get_current_buf()
      and last.tick == vim.api.nvim_buf_get_changedtick(0)
      and same(last.range, sel)
    )
  then
    return false
  end
  if r.mode == "V" or sel.mode == "V" then
    return sel.s[1] <= r.s[1] and r.e[1] <= sel.e[1]
  end
  return before_or_at(sel.s, r.s) and before_or_at(r.e, sel.e)
end

--- The range object `kind` covers at the cursor, or nil. In Visual mode
--- a nesting object the selection already covers gives the enclosing one.
---@param kind string heading, subtree, element, item, cell, row, column, link or timestamp
---@param inner boolean
---@param count? integer default: `vim.v.count`
---@return org.TextObjectRange|nil
function M.range(kind, inner, count)
  local fn = objects[kind]
  if not fn then
    return nil
  end
  count = count or vim.v.count
  local level = NESTING[kind] and math.max(count, 1) or 1
  local r = fn(inner, level, count)
  local sel = visual_selection()
  if r and sel and NESTING[kind] then
    while r and covers(sel, r) do
      level = level + 1
      r = fn(inner, level, count)
    end
  end
  return r
end

--- Select a range in Visual mode (in Operator-pending mode, the operator
--- then applies to it).
---@param r org.TextObjectRange
function M.apply(r)
  utils.exit_visual()
  local e = { r.e[1], r.e[2] }
  if r.mode == "v" and vim.o.selection == "exclusive" then
    e[2] = e[2] + 1
  end
  vim.api.nvim_win_set_cursor(0, r.s)
  vim.cmd("normal! " .. r.mode)
  vim.api.nvim_win_set_cursor(0, e)
  last = { buf = vim.api.nvim_get_current_buf(), tick = vim.api.nvim_buf_get_changedtick(0), range = r }
end

--- Select text object `kind` at the cursor. Does nothing when there is
--- none: an operator is then cancelled and a Visual selection kept.
---@param kind string
---@param inner boolean
---@return boolean selected
function M.select(kind, inner)
  local r = M.range(kind, inner)
  if not r then
    return false
  end
  M.apply(r)
  return true
end

return M
