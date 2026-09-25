---@mod org.element Elements: motion, marking, dragging and narrowing
---
--- A line-based parser of Org elements (paragraphs, lists and items,
--- blocks, drawers, tables, fixed-width areas, keywords, ...) inside a
--- section, and the Emacs commands built on it: org-forward-element /
--- org-backward-element (M-} / M-{), org-up-element / org-down-element
--- (C-c C-^ / C-c C-_), org-mark-element (M-h), org-transpose-element
--- (C-M-t), org-drag-element-forward / backward (M-down / M-up outside
--- headlines, items and tables), org-narrow-to-element /
--- org-narrow-to-block, org-next-block / org-previous-block and
--- org-toggle-fixed-width (C-c :).
---
--- Elements are whole lines: the first line of a list item is the item
--- (Emacs gives the paragraph on it when point is after the bullet, which
--- moves the same way). Blank lines after an element belong to it.

local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")

local M = {}

---@class org.Element
---@field type string
---@field first integer first line (affiliated keywords included)
---@field post integer first line after affiliated keywords
---@field clast integer last non-blank line
---@field last integer last line, trailing blank lines included
---@field cfirst? integer first line of the contents (greater elements)
---@field cend? integer last line of the contents
---@field children org.Element[]
---@field parent? org.Element
---@field greater? boolean

local GREATER_BLOCKS_EXCLUDED = { src = true, example = true, export = true, verse = true, comment = true }
local AFFILIATED = {
  NAME = true,
  CAPTION = true,
  HEADER = true,
  RESULTS = true,
  PLOT = true,
  LABEL = true,
  SRCNAME = true,
  TBLNAME = true,
  DATA = true,
  SOURCE = true,
}

local function is_blank(l)
  return l == nil or l:match("^%s*$") ~= nil
end

local function affiliated(line)
  local key = line:match("^%s*#%+([%w_%-]+)[%[:]")
  if not key then
    return false
  end
  key = key:upper()
  return AFFILIATED[key] or key:match("^ATTR_") ~= nil
end

--- Kind of element starting at `line` (nil = paragraph line).
local function starts(line)
  if line:match("^%s*|") then
    return "table"
  elseif line:match("^%s*:%s") or line:match("^%s*:$") then
    return "fixed-width"
  elseif line:match("^%s*#%s") or line:match("^%s*#$") then
    return "comment"
  elseif line:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_") or line:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]:") then
    return "block"
  elseif line:match("^%s*#%+[Cc][Aa][Ll][Ll]:") then
    return "babel-call"
  elseif line:match("^%s*#%+%S+:") then
    return "keyword"
  elseif line:match("^%s*:[%w_%-]+:%s*$") then
    return "drawer"
  elseif line:match("^%s*%-%-%-%-%-+%s*$") then
    return "horizontal-rule"
  elseif line:match("^%s*CLOCK:") then
    return "clock"
  elseif line:match("^%[fn:[^%]]+%]") then
    return "footnote-definition"
  elseif line:match("^%s*\\begin{") then
    return "latex-environment"
  elseif require("org.lists").parse_item_line(line) then
    return "item"
  end
end

local parse

--- Parse the lines [s, e] into a list of elements with `parent`.
---@param lines string[]
---@return org.Element[]
parse = function(lines, s, e, parent, first_is_item_text)
  local out = {}
  local i = s
  local lists = require("org.lists")
  local function add(el)
    el.parent = parent
    el.children = el.children or {}
    -- trailing blank lines
    local j = el.clast + 1
    while j <= e and is_blank(lines[j]) do
      j = j + 1
    end
    el.last = j - 1
    out[#out + 1] = el
    i = j
  end
  -- leading blank lines are not part of any element
  while i <= e and is_blank(lines[i]) do
    i = i + 1
  end
  while i <= e do
    local line = lines[i]
    local first = i
    -- affiliated keywords attach to the next element
    local j = i
    while j <= e and affiliated(lines[j]) do
      j = j + 1
    end
    if j > i and (j > e or is_blank(lines[j])) then
      j = i -- plain keywords
    end
    local post = j
    line = lines[post]
    local kind = starts(line)
    if first_is_item_text and post == s then
      kind = nil -- text on an item's first line
    end
    if kind == "table" then
      local k = post
      while k + 1 <= e and (lines[k + 1]:match("^%s*|") or lines[k + 1]:match("^%s*#%+[Tt][Bb][Ll][Ff][Mm]:")) do
        k = k + 1
      end
      add({ type = "table", first = first, post = post, clast = k, cfirst = post, cend = k, greater = true })
    elseif kind == "fixed-width" or kind == "comment" then
      local k = post
      while k + 1 <= e and starts(lines[k + 1]) == kind do
        k = k + 1
      end
      add({ type = kind, first = first, post = post, clast = k })
    elseif kind == "block" then
      local name = line:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)")
      local stop
      for k = post + 1, e do
        if name then
          if lines[k]:lower():match("^%s*#%+end_" .. vim.pesc(name:lower()) .. "%s*$") then
            stop = k
            break
          end
        elseif lines[k]:lower():match("^%s*#%+end:") then
          stop = k
          break
        end
      end
      if stop then
        local lname = name and name:lower()
        local type = not name and "dynamic-block"
          or (lname == "src" and "src-block")
          or (lname == "example" and "example-block")
          or (lname == "export" and "export-block")
          or (lname == "verse" and "verse-block")
          or (lname == "comment" and "comment-block")
          or (lname == "quote" and "quote-block")
          or (lname == "center" and "center-block")
          or "special-block"
        local greater = not (name and GREATER_BLOCKS_EXCLUDED[lname])
        local el = { type = type, first = first, post = post, clast = stop, greater = greater }
        if stop > post + 1 then
          el.cfirst, el.cend = post + 1, stop - 1
          if greater then
            el.children = parse(lines, post + 1, stop - 1, el)
          end
        end
        add(el)
      else
        kind = nil
      end
    elseif kind == "drawer" then
      local stop
      for k = post + 1, e do
        if lines[k]:match("^%s*:[Ee][Nn][Dd]:%s*$") then
          stop = k
          break
        end
      end
      if stop then
        local name = line:match("^%s*:([%w_%-]+):"):upper()
        local el = {
          type = name == "PROPERTIES" and "property-drawer" or "drawer",
          first = first,
          post = post,
          clast = stop,
          greater = true,
        }
        if stop > post + 1 then
          el.cfirst, el.cend = post + 1, stop - 1
          if name ~= "PROPERTIES" then
            el.children = parse(lines, post + 1, stop - 1, el)
          end
        end
        add(el)
      else
        kind = nil
      end
    elseif kind == "latex-environment" then
      local env = line:match("\\begin{([^}]+)}")
      local stop
      for k = post, e do
        if lines[k]:find("\\end{" .. env .. "}", 1, true) then
          stop = k
          break
        end
      end
      if stop then
        add({ type = "latex-environment", first = first, post = post, clast = stop })
      else
        kind = nil
      end
    elseif kind == "footnote-definition" then
      local k = post
      while k + 1 <= e do
        local l = lines[k + 1]
        if l:match("^%[fn:[^%]]+%]") or parser.headline_level(l) then
          break
        end
        if is_blank(l) and is_blank(lines[k + 2]) then
          break
        end
        k = k + 1
      end
      while k > post and is_blank(lines[k]) do
        k = k - 1
      end
      local el = { type = "footnote-definition", first = first, post = post, clast = k, greater = true }
      el.cfirst, el.cend = post, k
      el.children = parse(lines, post, k, el, true)
      add(el)
    elseif kind == "item" then
      -- a whole plain list
      local ls = lists.parse_region(lines, post, e)
      local list = ls[1]
      if list and list.items[1].lnum == post then
        local stop = 0
        for _, it in ipairs(list.items) do
          stop = math.max(stop, it.end_lnum)
        end
        local el = { type = "plain-list", first = first, post = post, clast = stop, greater = true }
        el.cfirst, el.cend = post, stop
        el.children = {}
        local function items(its, into, par)
          for idx, it in ipairs(its) do
            local nxt = its[idx + 1]
            local ilast = nxt and nxt.lnum - 1 or it.end_lnum
            local iclast = ilast
            while iclast > it.lnum and is_blank(lines[iclast]) do
              iclast = iclast - 1
            end
            local item = {
              type = "item",
              first = it.lnum,
              post = it.lnum,
              clast = iclast,
              last = ilast,
              cfirst = it.lnum,
              cend = iclast,
              greater = true,
              parent = par,
              list_item = it,
            }
            item.children = parse(lines, it.lnum, iclast, item, true)
            into[#into + 1] = item
          end
        end
        items(list.items, el.children, el)
        add(el)
      else
        kind = nil
      end
    elseif kind then
      add({ type = kind, first = first, post = post, clast = post })
    end
    if not kind then
      -- paragraph
      local k = post
      while k + 1 <= e do
        local l = lines[k + 1]
        if is_blank(l) or parser.headline_level(l) or starts(l) or affiliated(l) then
          break
        end
        k = k + 1
      end
      add({ type = "paragraph", first = first, post = post, clast = k })
    end
  end
  return out
end

--- Parse the section containing `lnum` (the lines after its headline,
--- or the text before the first headline).
---@return org.Element[] elements, integer from, integer to, org.Headline|nil
function M.section(bufnr, lnum)
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  local lines = file.lines
  local from, to
  if hl then
    from, to = hl.line + 1, hl.body_end
  else
    from, to = 1, file.preamble_end
  end
  local els = {}
  local i = from
  local l = lines[i]
  if hl and l and (l:match("^%s*SCHEDULED:") or l:match("^%s*DEADLINE:") or l:match("^%s*CLOSED:")) then
    els[1] = { type = "planning", first = i, post = i, clast = i, children = {} }
    i = i + 1
  end
  local rest = parse(lines, i, to, nil)
  -- fix trailing blanks of the planning line
  if els[1] then
    local j = els[1].clast + 1
    while j <= to and is_blank(lines[j]) do
      j = j + 1
    end
    els[1].last = j - 1
  end
  vim.list_extend(els, rest)
  return els, from, to, hl, lines
end

--- Deepest element containing `lnum`. On the first line of a greater
--- element (a block, drawer or item line), that element.
---@return org.Element|nil
function M.at(bufnr, lnum)
  local els = M.section(bufnr, lnum)
  local found
  local function walk(list)
    for _, el in ipairs(list) do
      if el.first <= lnum and lnum <= el.last then
        found = el
        if lnum > el.post and el.children and lnum <= (el.cend or el.clast) then
          walk(el.children)
        elseif el.type == "plain-list" then
          walk(el.children)
        end
        return
      end
    end
  end
  walk(els)
  return found
end

local function cursor()
  return vim.api.nvim_win_get_cursor(0)
end

local function goto_line(lnum)
  lnum = math.max(1, math.min(lnum, vim.api.nvim_buf_line_count(0)))
  vim.cmd("normal! m'")
  local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
  vim.api.nvim_win_set_cursor(0, { lnum, #(line:match("^%s*")) })
end

local function on_headline(lnum)
  local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1]
  return line and parser.headline_level(line) ~= nil
end

--- Siblings of an element (the list it is part of).
local function siblings(el, bufnr)
  if el.parent then
    return el.parent.children
  end
  return (M.section(bufnr, el.first))
end

--- org-forward-element (M-}).
function M.forward()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cursor()[1]
  local nlines = vim.api.nvim_buf_line_count(0)
  if on_headline(lnum) then
    local file = files.get_buffer(bufnr)
    local hl = file:headline_on(lnum)
    if hl.end_line + 1 > nlines then
      utils.warn("Cannot move further down")
      return
    end
    return goto_line(hl.end_line + 1)
  end
  local el = M.at(bufnr, lnum)
  if not el then
    -- blank lines at the start of a section: to the next element
    local els = M.section(bufnr, lnum)
    for _, e in ipairs(els) do
      if e.first > lnum then
        return goto_line(e.first)
      end
    end
    if lnum >= nlines then
      utils.warn("Cannot move further down")
      return
    end
    return goto_line(math.min(nlines, select(3, M.section(bufnr, lnum)) + 1))
  end
  if lnum >= nlines then
    utils.warn("Cannot move further down")
    return
  end
  local p = el.parent
  if p and (p.cend == el.clast or p.clast == el.clast) and p.type ~= "item" then
    return goto_line(p.last + 1)
  elseif p and p.type == "item" and p.cend == el.clast then
    return goto_line(p.last + 1)
  end
  goto_line(el.last + 1)
end

--- org-backward-element (M-{).
function M.backward()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cursor()[1]
  if lnum == 1 and cursor()[2] == 0 then
    utils.warn("Cannot move further up")
    return
  end
  if on_headline(lnum) then
    local file = files.get_buffer(bufnr)
    local hl = file:headline_on(lnum)
    local sibs = hl.parent and hl.parent.children or file.children
    for i, s in ipairs(sibs) do
      if s.line == hl.line and sibs[i - 1] then
        return goto_line(sibs[i - 1].line)
      end
    end
    if hl.parent then
      return goto_line(hl.parent.line)
    end
    utils.warn("Cannot move further up")
    return
  end
  local el = M.at(bufnr, lnum)
  if el and lnum ~= el.first then
    return goto_line(el.first)
  end
  local beg = el and el.first or lnum
  local l = beg - 1
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  while l >= 1 and is_blank(lines[l]) do
    l = l - 1
  end
  if l < 1 then
    return goto_line(1)
  end
  if parser.headline_level(lines[l]) then
    return goto_line(l)
  end
  local prev = M.at(bufnr, l)
  if not prev then
    return goto_line(l)
  end
  local target = prev
  local up = prev.parent
  while up and up.last < beg do
    target = up
    up = up.parent
  end
  -- ancestors that end before `beg` were climbed; an ancestor that
  -- contains `beg` is the parent: stay at the previous sibling
  goto_line(target.first)
end

--- org-up-element (C-c C-^).
function M.up()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cursor()[1]
  local file = files.get_buffer(bufnr)
  if on_headline(lnum) then
    local hl = file:headline_on(lnum)
    if not hl.parent then
      utils.warn("No surrounding element")
      return
    end
    return goto_line(hl.parent.line)
  end
  local el = M.at(bufnr, lnum)
  local p = el and el.parent
  if p and p.type == "plain-list" and el.type == "item" then
    -- an item's parent is its list: go to the enclosing item, if any
    p = p.parent or p
  end
  if p then
    return goto_line(p.first)
  end
  local hl = file:headline_at(lnum)
  if not hl then
    utils.warn("No surrounding element")
    return
  end
  goto_line(hl.line)
end

--- org-down-element (C-c C-_).
function M.down()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cursor()[1]
  local el
  if on_headline(lnum) then
    local els = M.section(bufnr, lnum + 1)
    local file = files.get_buffer(bufnr)
    local hl = file:headline_on(lnum)
    if hl and els[1] and els[1].first > lnum then
      return goto_line(els[1].first)
    end
    if hl and hl.children[1] then
      return goto_line(hl.children[1].line)
    end
    utils.warn("No inner element")
    return
  end
  el = M.at(bufnr, lnum)
  if el and el.type == "plain-list" then
    return goto_line(el.children[1].first)
  elseif el and el.greater then
    if not el.cfirst then
      utils.warn("No content for this element")
      return
    end
    if vim.fn.foldclosed(el.first) ~= -1 then
      pcall(vim.cmd, el.first .. "foldopen")
    end
    return goto_line(el.cfirst)
  end
  utils.warn("No inner element")
end

--- Visually select lines [s, e].
local function select_lines(s, e)
  if vim.fn.mode():match("^[vV\22]") then
    vim.cmd("normal! \27")
  end
  vim.api.nvim_win_set_cursor(0, { s, 0 })
  vim.cmd("normal! V")
  vim.api.nvim_win_set_cursor(0, { e, 0 })
end

--- org-mark-element (M-h): select the element at the cursor, blank lines
--- after it included. In Visual mode, extend the selection by the next
--- element.
function M.mark()
  local bufnr = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  if mode:match("^[vV\22]") then
    local s, _, e = utils.visual_range()
    local nxt = e + 1
    if nxt > vim.api.nvim_buf_line_count(0) then
      return select_lines(s, e)
    end
    local el = on_headline(nxt) and { last = files.get_buffer(bufnr):headline_on(nxt).end_line } or M.at(bufnr, nxt)
    return select_lines(s, el and el.last or nxt)
  end
  local lnum = cursor()[1]
  if on_headline(lnum) then
    local hl = files.get_buffer(bufnr):headline_on(lnum)
    return select_lines(hl.line, hl.end_line)
  end
  local el = M.at(bufnr, lnum)
  if not el then
    return
  end
  select_lines(el.first, el.last)
end

--- Swap elements A (before) and B, leaving the blank lines after each
--- in place (org-element-swap-A-B). Returns the new first line of A.
local function swap(bufnr, a, b)
  local get = function(s, e)
    return vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  end
  local a_body = get(a.first, a.clast)
  local between = get(a.clast + 1, b.first - 1)
  local b_body = get(b.first, b.clast)
  local new = vim.list_extend(vim.list_extend(vim.deepcopy(b_body), between), a_body)
  vim.api.nvim_buf_set_lines(bufnr, a.first - 1, b.clast, false, new)
  return a.first + #b_body + #between
end

--- Previous element of `el` at the same level (nil when `el` is first).
local function previous_of(bufnr, el)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local l = el.first - 1
  while l >= 1 and is_blank(lines[l]) do
    l = l - 1
  end
  if l < 1 or parser.headline_level(lines[l]) then
    return nil
  end
  local prev = M.at(bufnr, l)
  if not prev then
    return nil
  end
  local up = prev.parent
  while up and up.last < el.first do
    prev = up
    up = up.parent
  end
  return prev
end

local function nested(a, b)
  return (a.first <= b.first and b.last <= a.last) or (b.first <= a.first and a.last <= b.last)
end

--- org-drag-element-backward (M-up outside headlines, items and tables).
function M.drag_backward()
  local bufnr = vim.api.nvim_get_current_buf()
  local pos = cursor()
  if on_headline(pos[1]) then
    return require("org.structure").move_subtree_up()
  end
  local el = M.at(bufnr, pos[1])
  if not el then
    utils.warn("No element at point")
    return
  end
  local prev = previous_of(bufnr, el)
  if not prev or nested(el, prev) then
    utils.warn("Cannot drag element backward")
    return
  end
  swap(bufnr, prev, el)
  vim.api.nvim_win_set_cursor(0, { prev.first + (pos[1] - el.first), pos[2] })
end

--- org-drag-element-forward (M-down outside headlines, items and tables).
function M.drag_forward()
  local bufnr = vim.api.nvim_get_current_buf()
  local pos = cursor()
  if on_headline(pos[1]) then
    return require("org.structure").move_subtree_down()
  end
  local el = M.at(bufnr, pos[1])
  local nlines = vim.api.nvim_buf_line_count(bufnr)
  if not el then
    utils.warn("No element at point")
    return
  end
  if el.last >= nlines then
    utils.warn("Cannot drag element forward")
    return
  end
  local nxt_line = el.last + 1
  local line = vim.api.nvim_buf_get_lines(bufnr, nxt_line - 1, nxt_line, false)[1]
  local nxt = not parser.headline_level(line) and M.at(bufnr, nxt_line) or nil
  if not nxt or nested(el, nxt) or nxt.first ~= nxt_line then
    utils.warn("Cannot drag element forward")
    return
  end
  local new_first = swap(bufnr, el, nxt)
  vim.api.nvim_win_set_cursor(0, { new_first + (pos[1] - el.first), pos[2] })
end

--- org-transpose-element (C-M-t): swap the element at the cursor with
--- the previous one, and move after both.
function M.transpose()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cursor()[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  while lnum < #lines and is_blank(lines[lnum]) do
    lnum = lnum + 1
  end
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  local el = M.at(bufnr, lnum)
  if not el then
    return
  end
  local stop = el.last
  local prev = previous_of(bufnr, el)
  if not prev or nested(el, prev) then
    utils.warn("Cannot drag element backward")
    return
  end
  swap(bufnr, prev, el)
  goto_line(math.min(stop + 1, vim.api.nvim_buf_line_count(bufnr)))
end

--- Edit lines [s, e] in a narrowed edit buffer.
local function narrow(bufnr, s, e, name)
  return require("org.special").open({
    source_buf = bufnr,
    start_line = s,
    end_line = e,
    lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false),
    filetype = "org",
    name = name,
  })
end

--- org-narrow-to-element (C-x n e): edit the element at the cursor (the
--- subtree on a headline, the contents of a greater element) in an edit
--- buffer, like narrow_subtree.
function M.narrow_to_element()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cursor()[1]
  if on_headline(lnum) then
    return require("org.structure").narrow_subtree()
  end
  local el = M.at(bufnr, lnum)
  if not el then
    utils.warn("No element at point")
    return
  end
  if el.greater and el.cfirst then
    return narrow(bufnr, el.cfirst, el.cend, el.type)
  end
  return narrow(bufnr, el.first, el.last, el.type)
end

--- org-narrow-to-block (C-x n b).
function M.narrow_to_block()
  local bufnr = vim.api.nvim_get_current_buf()
  local el = M.at(bufnr, cursor()[1])
  while el and not el.type:match("block") do
    el = el.parent
  end
  if not el then
    utils.warn("Not in a block")
    return
  end
  if el.greater and el.cfirst then
    return narrow(bufnr, el.cfirst, el.cend, el.type)
  end
  return narrow(bufnr, el.first, el.last, el.type)
end

--- org-next-block (C-c M-f) / org-previous-block (C-c M-b) with `dir`
--- 1 / -1: the next `#+begin_...` block (a count skips that many).
function M.next_block(dir)
  dir = dir or 1
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = cursor()[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local count = math.max(vim.v.count, 1)
  local target
  local l = lnum + dir
  while l >= 1 and l <= #lines and count > 0 do
    if lines[l]:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]") then
      local el = M.at(bufnr, l)
      if el and el.post == l and (el.type:match("block")) then
        count = count - 1
        target = l
      end
    end
    l = l + dir
  end
  if count > 0 or not target then
    utils.warn(string.format("No %s code blocks", dir < 0 and "previous" or "further"))
    return
  end
  goto_line(target)
  pcall(vim.cmd, "normal! zv")
end

function M.previous_block()
  return M.next_block(-1)
end

--- Column where the contents of `el` start (org--get-expected-indentation
--- with CONTENTSP).
local function contents_indentation(bufnr, el, lnum)
  if not el then
    local hl = files.get_buffer(bufnr):headline_at(lnum)
    if hl and require("org.config").opts.adapt_indentation then
      return hl.level + 1
    end
    return 0
  end
  if el.type == "footnote-definition" then
    return 0
  elseif el.type == "item" then
    local it = el.list_item
    return it.indent + #it.bullet_ws
  elseif el.type == "plain-list" then
    local it = el.children[1].list_item
    return it.indent + #it.bullet_ws
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, el.first - 1, el.first, false)[1] or ""
  return #line:match("^(%s*)")
end

--- Indent the line like org-indent-line (TAB in body text with
--- `cycle_emulate_tab`): the first line of an element like its previous
--- sibling or its container, other lines like the line above. Lines of
--- src and example blocks and headlines are left alone.
function M.indent_line(lnum)
  local bufnr = vim.api.nvim_get_current_buf()
  lnum = lnum or cursor()[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  if not line or parser.headline_level(line) or is_blank(line) then
    return
  end
  local el = M.at(bufnr, lnum)
  local target
  if el and not el.greater and el.cfirst and lnum > el.post and lnum < el.clast then
    return -- inside a verbatim block
  end
  if el and el.type == "footnote-definition" and lnum == el.first then
    target = 0
  elseif el and lnum == el.first then
    local sibs = siblings(el, bufnr)
    local prev
    for i, s in ipairs(sibs) do
      if s == el then
        prev = sibs[i - 1]
      end
    end
    if el.type == "item" then
      return -- items are indented with M-left / M-right
    elseif prev and prev.type ~= "footnote-definition" then
      local pl = vim.api.nvim_buf_get_lines(bufnr, prev.first - 1, prev.first, false)[1]
      target = #pl:match("^(%s*)")
      if prev.type == "item" or prev.type == "planning" then
        target = contents_indentation(bufnr, el.parent, lnum)
      end
    else
      target = contents_indentation(bufnr, el.parent, lnum)
    end
  else
    -- like the first non-blank line above
    local l = lnum - 1
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, lnum - 1, false)
    while l >= 1 and is_blank(lines[l]) do
      l = l - 1
    end
    if l < 1 then
      target = 0
    elseif el and el.type == "item" and l == el.first then
      target = contents_indentation(bufnr, el, lnum)
    else
      target = #lines[l]:match("^(%s*)")
    end
  end
  local cur = #line:match("^(%s*)")
  if target == cur then
    return
  end
  local col = cursor()[2]
  vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { string.rep(" ", target) .. line:sub(cur + 1) })
  if col < cur then
    col = target
  else
    col = col + target - cur
  end
  vim.api.nvim_win_set_cursor(0, { lnum, math.max(0, col) })
end

--- org-toggle-fixed-width (C-c :): remove the `: ` marker in a
--- fixed-width area, add it to other lines. In Visual mode: when the
--- selection holds only fixed-width lines, unmark them all, else mark
--- every other line.
function M.toggle_fixed_width()
  local bufnr = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local function unmark(l)
    local ind, rest = l:match("^(%s*):%s?(.*)$")
    if not ind then
      return l
    end
    if rest == "" then
      return ind
    end
    return ind .. rest
  end
  if mode:match("^[vV\22]") then
    local s, _, e = utils.visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
    while #lines > 1 and is_blank(lines[#lines]) do
      table.remove(lines)
    end
    local all_fixed = false
    for _, l in ipairs(lines) do
      if not is_blank(l) then
        all_fixed = true
      end
    end
    for _, l in ipairs(lines) do
      if not is_blank(l) and not (l:match("^%s*:%s") or l:match("^%s*:$")) then
        all_fixed = false
      end
    end
    local out = {}
    if all_fixed then
      for i, l in ipairs(lines) do
        out[i] = unmark(l)
      end
    else
      local min_ind = math.huge
      for _, l in ipairs(lines) do
        if not is_blank(l) then
          min_ind = math.min(min_ind, #l:match("^(%s*)"))
        end
      end
      if min_ind == math.huge then
        min_ind = 0
      end
      for i, l in ipairs(lines) do
        if l:match("^%s*:%s") or l:match("^%s*:$") then
          out[i] = l
        elseif parser.headline_level(l) then
          out[i] = ": " .. l
        elseif is_blank(l) then
          out[i] = string.rep(" ", min_ind) .. ":"
        else
          out[i] = string.rep(" ", min_ind) .. ": " .. l:sub(min_ind + 1)
        end
      end
    end
    vim.api.nvim_buf_set_lines(bufnr, s - 1, s - 1 + #lines, false, out)
    return
  end
  local lnum = cursor()[1]
  local line = vim.api.nvim_get_current_line()
  if line:match("^%s*:%s") or line:match("^%s*:$") then
    vim.api.nvim_set_current_line(unmark(line))
    return
  end
  local el = M.at(bufnr, lnum)
  local one_line = {
    ["babel-call"] = true,
    clock = true,
    comment = true,
    ["horizontal-rule"] = true,
    keyword = true,
    paragraph = true,
    planning = true,
  }
  if parser.headline_level(line) or (el and one_line[el.type] and not is_blank(line)) then
    local ind = line:match("^(%s*)")
    vim.api.nvim_set_current_line(ind .. ": " .. line:sub(#ind + 1))
    return
  end
  if is_blank(line) then
    local hl = files.get_buffer(bufnr):headline_at(lnum)
    local indent = hl and require("org.edit").body_indent(hl.level) or ""
    vim.api.nvim_set_current_line(indent .. ": ")
    vim.api.nvim_win_set_cursor(0, { lnum, #indent + 2 })
    return
  end
  utils.warn("Cannot insert a fixed-width line here")
end

return M
