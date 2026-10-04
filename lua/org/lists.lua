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
---
--- This file holds the parser (items, sections, item_at, a hot path) and
--- the helpers the parts share; it loads the rest from org/lists/: struct
--- (list structures, repair), stats (statistics cookies), checkbox, edit
--- (inserting, indenting, moving items), motion and convert (bullets,
--- toggle item, list to subtree, sorting).

local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")

local M = {}
-- The parts in org/lists/ add their functions to this table and
-- require it back, so it must be in package.loaded before they load.
package.loaded["org.lists"] = M

---@class org.ListItem
---@field lnum integer
---@field end_lnum integer last line of the item, children included (trailing blanks excluded)
---@field indent integer
---@field bullet string "-", "+", "*", "1.", "1)", or "a.", "A)"... (lists.allow_alphabetical)
---@field bullet_ws string the bullet with the whitespace after it
---@field is_ordered boolean
---@field counter string|nil value of a [@N] or [@c] counter
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

--- Whether byte `b` is whitespace (%s).
local function space(b)
  return b == 32 or (b ~= nil and b >= 9 and b <= 13)
end

--- Column (1-based) of the first non-blank character of `line`, or nil.
local function first_nonblank(line)
  local j = 1
  local b = line:byte(1)
  while space(b) do
    j = j + 1
    b = line:byte(j)
  end
  return b and j or nil
end

--- Plain list option `name` (config `lists`), falling back to its default.
function M.opt(name)
  local config = require("org.config")
  local l = config.opts.lists
  local v = l and l[name]
  if v == nil then
    v = config.defaults.lists[name]
  end
  return v
end
local lopt = M.opt

--- Whether byte `b` is an ASCII letter.
local function letter(b)
  return b ~= nil and ((b >= 65 and b <= 90) or (b >= 97 and b <= 122))
end

--- Lua pattern of the ordered bullet terminator
--- (org-plain-list-ordered-item-terminator).
local function term_pattern()
  local t = lopt("ordered_item_terminator")
  if t == "." then
    return "%."
  elseif t == ")" then
    return "%)"
  end
  return "[.)]"
end

--- Parse a single line as an item. Returns nil for non-items.
function M.parse_item_line(line)
  -- most lines aren't items: look at the first character before matching
  -- (byte tests keep loops over large files compiled by LuaJIT)
  local j = first_nonblank(line)
  local b = j and line:byte(j)
  local alpha = false
  if not (b == 45 or b == 43 or b == 42 or (b and b >= 48 and b <= 57)) then
    if not (letter(b) and lopt("allow_alphabetical")) then
      return nil
    end
    alpha = true
  end
  local ind, bullet, gap, rest
  if not alpha then
    ind, bullet, gap, rest = line:match("^(%s*)([%-+*])(%s+)(.*)$")
    if not ind then
      ind, bullet = line:match("^(%s*)([%-+*])$")
      gap, rest = "", ""
    end
  end
  if not ind then
    local num = (alpha and "%a" or "%d+") .. term_pattern()
    ind, bullet, gap, rest = line:match("^(%s*)(" .. num .. ")(%s+)(.*)$")
    if not ind then
      ind, bullet = line:match("^(%s*)(" .. num .. ")$")
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
    is_ordered = bullet:match("^%w") ~= nil,
  }
  local col = #ind + #bullet + #gap
  -- [@N], [@start:N] or [@c] (org-list-full-item-re)
  local body = rest:match("^%[@start:([^%]]*%].*)$") or rest:match("^%[@([^%]]*%].*)$")
  local counter, after
  if body then
    counter, after = body:match("^(%d+)%][ \t]*(.*)$")
    if not counter then
      counter, after = body:match("^(%a)%][ \t]*(.*)$")
    end
  end
  if counter then
    item.counter = counter
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
  -- greedy, like org-list-full-item-re: the term runs to the last " ::"
  local tag = rest:match("^(.*)%s+::$") or rest:match("^(.*)%s+::%s")
  if tag then
    item.tag = tag:gsub("[ \t]+$", "")
  end
  item.text = rest
  item.content_col = col
  return item
end

local function indent_of(line)
  local j = first_nonblank(line)
  return j and j - 1 or #line
end

local function is_blank(line)
  return line == nil or first_nonblank(line) == nil
end

--- When lines[i] opens a forbidden block closed within lines[i+1..to],
--- the line number of its #+end line.
local function forbidden_block_end(lines, i, to)
  local j = first_nonblank(lines[i])
  local name = j and lines[i]:byte(j) == 35 and lines[i]:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)")
  if name and M.forbidden_blocks[name:lower()] then
    local close = ("^%s*#%+end_" .. vim.pesc(name) .. "%s*$"):lower()
    for k = i + 1, to do
      if lines[k]:lower():match(close) then
        return k
      end
    end
  end
end

--- Lines strictly inside a forbidden block within lines[from..to]:
--- set of line numbers.
local function verbatim_lines(lines, from, to)
  local set = {}
  local i = from
  while i <= to do
    local stop = forbidden_block_end(lines, i, to)
    if stop then
      for j = i + 1, stop - 1 do
        set[j] = true
      end
      i = stop
    end
    i = i + 1
  end
  return set
end

--- Parse all lists within lines[from..to]. With `first_only`, stop at
--- the end of the first list (the element parser asks for one list at a
--- time: scanning the rest of the section made it quadratic).
---@param first_only? boolean
---@return { items: org.ListItem[] }[] lists, org.ListItem[] all items (in order)
function M.parse_region(lines, from, to, first_only)
  local lists, all = {}, {}
  local stack = {} -- open items
  local current -- current list
  local blanks = 0
  -- lines [verbatim_from, verbatim_to] are inside a forbidden block
  local verbatim_from, verbatim_to = 0, -1
  for i = from, to do
    if first_only and lists[1] and not current then
      break
    end
    local line = lines[i]
    if i > verbatim_to then
      local stop = forbidden_block_end(lines, i, to)
      if stop then
        verbatim_from, verbatim_to = i + 1, stop - 1
      end
    end
    if i >= verbatim_from and i <= verbatim_to then
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

--- The lines of the section containing `lnum` (see `section_bounds`),
--- indexed by line number, and its bounds. Without inline tasks a section
--- runs from one headline to the next, so it is read from the buffer
--- around `lnum` instead of parsing the whole file (large files).
---@return table<integer, string> lines, integer from, integer to
local function section_text(bufnr, lnum)
  if parser.inlinetask_min_level() then
    local file = files.get_buffer(bufnr)
    local from, to = section_bounds(file, lnum)
    return file.lines, from, to
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  local CHUNK = 256
  local from, to = 1, n
  local e = math.min(lnum, n)
  while e >= 1 do
    local s = math.max(1, e - CHUNK + 1)
    local chunk = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
    local found
    for i = #chunk, 1, -1 do
      if chunk[i]:byte(1) == 42 and parser.headline_level(chunk[i]) then
        found = s + i - 1
        break
      end
    end
    if found then
      from = found + 1
      break
    end
    e = s - 1
  end
  local s = math.max(from, lnum + 1)
  while s <= n do
    local e2 = math.min(n, s + CHUNK - 1)
    local chunk = vim.api.nvim_buf_get_lines(bufnr, s - 1, e2, false)
    local found
    for i, l in ipairs(chunk) do
      if l:byte(1) == 42 and parser.headline_level(l) then
        found = s + i - 1
        break
      end
    end
    if found then
      to = found - 1
      break
    end
    s = e2 + 1
  end
  local lines = {}
  if from <= to then
    for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, from - 1, to, false)) do
      lines[from + i - 1] = l
    end
  end
  return lines, from, to
end

--- Whether `lnum` is inside an example, verse, src or export block.
function M.in_forbidden_block(bufnr, lnum)
  bufnr = bufnr or 0
  local lines, from, to = section_text(bufnr, lnum)
  return verbatim_lines(lines, from, to)[lnum] == true
end

--- Item containing `lnum` (innermost), or nil (org-in-item-p).
---@return org.ListItem|nil
function M.item_at(bufnr, lnum)
  bufnr = bufnr or 0
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  if not line or parser.headline_level(line) then
    return nil
  end
  local lines, from, to = section_text(bufnr, lnum)
  if verbatim_lines(lines, from, to)[lnum] then
    return nil
  end
  local _, all = M.parse_region(lines, from, to)
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
  local v
  if parser.inlinetask_min_level() then
    local hl = files.get_buffer(bufnr):headline_at(lnum)
    v = hl and hl.properties and hl.properties.ORDERED
  else
    -- read only the entry's property drawer, after its headline and
    -- planning line (like parse_section)
    local lines, from, to = section_text(bufnr, lnum)
    if from > 1 then
      local i = from
      if i <= to and parser.parse_planning(lines[i]) then
        i = i + 1
      end
      local drawer = parser.parse_property_drawer(lines, i, to)
      v = drawer and drawer.properties.ORDERED
    end
  end
  return v ~= nil and v ~= "" and v ~= "nil"
end

-- Local functions the parts below share
local shared = require("org.lists.shared")
shared.curbuf = curbuf
shared.cursor_lnum = cursor_lnum
shared.get_lines = get_lines
shared.indent_of = indent_of
shared.is_blank = is_blank
shared.lopt = lopt
shared.ordered_p = ordered_p
shared.protected = protected
shared.set_lines = set_lines
shared.user_error = user_error
shared.verbatim_lines = verbatim_lines

require("org.lists.struct")
require("org.lists.stats")
require("org.lists.checkbox")
require("org.lists.edit")
require("org.lists.motion")
require("org.lists.convert")

return M
