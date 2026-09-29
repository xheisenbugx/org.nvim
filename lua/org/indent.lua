---@mod org.indent Org-aware indentation
---
--- A port of org-indent-line (`'indentexpr'`, TAB in body text),
--- org-indent-region (`=` and the `indent_region` action),
--- org-indent-block, org-indent-drawer and org-unindent-buffer.
---
--- Indentation follows org--get-expected-indentation: headlines, footnote
--- definitions and diary sexps start at column 0; the first line of an
--- element is indented like its previous sibling, else like the contents
--- of its parent (after the bullet of an item, at the headline level + 1
--- when `adapt_indentation` is on); other lines like the first non-blank
--- line above. List items are never re-indented one by one.

local config = require("org.config")
local parser = require("org.parser")

local M = {}

local BLOCKS = {
  ["comment-block"] = true,
  ["example-block"] = true,
  ["export-block"] = true,
  ["src-block"] = true,
  ["verse-block"] = true,
}

local function is_blank(l)
  return l == nil or l:match("^%s*$") ~= nil
end

--- Display width of the leading whitespace of `l`.
local function indentation(l, ts)
  local col = 0
  for i = 1, #(l or "") do
    local c = l:sub(i, i)
    if c == " " then
      col = col + 1
    elseif c == "\t" then
      col = col + ts - col % ts
    else
      break
    end
  end
  return col
end

local function headline(l)
  return l ~= nil and parser.headline_level(l) ~= nil
end

---------------------------------------------------------------------------
-- Context: the section around a line, parsed into elements
---------------------------------------------------------------------------

---@class org.IndentCtx
---@field bufnr integer
---@field offset integer buffer line = local line + offset
---@field lines string[] section lines (local 1..n); local 0 is the headline
---@field n integer
---@field level? integer level of the section's headline
---@field root table
---@field els org.Element[]
---@field ts integer

--- Parse the section containing buffer line `lnum`.
---@return org.IndentCtx
local function context(bufnr, lnum)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local function get(a, b)
    return vim.api.nvim_buf_get_lines(bufnr, a - 1, b, false)
  end
  -- the headline at or above lnum
  local hs = 0
  local l = lnum
  while l >= 1 do
    local from = math.max(1, l - 199)
    local chunk = get(from, l)
    for i = #chunk, 1, -1 do
      if headline(chunk[i]) then
        hs = from + i - 1
        break
      end
    end
    if hs > 0 then
      break
    end
    l = from - 1
  end
  -- the next headline
  local he = total + 1
  l = math.max(lnum, hs) + 1
  while l <= total do
    local to = math.min(total, l + 199)
    local chunk = get(l, to)
    for i = 1, #chunk do
      if headline(chunk[i]) then
        he = l + i - 1
        break
      end
    end
    if he <= total then
      break
    end
    l = to + 1
  end
  local lines = he - 1 >= hs + 1 and get(hs + 1, he - 1) or {}
  local ctx = {
    bufnr = bufnr,
    offset = hs,
    lines = lines,
    n = #lines,
    ts = vim.bo[bufnr].tabstop,
  }
  if hs > 0 then
    ctx.level = parser.headline_level(get(hs, hs)[1])
    ctx.headline_text = get(hs, hs)[1]
  end
  ctx.root = { type = "root", first = 0, post = 0, clast = 0, last = ctx.n, children = {} }
  local els = {}
  local i = 1
  local first = lines[1]
  if
    hs > 0
    and first
    and (first:match("^%s*SCHEDULED:") or first:match("^%s*DEADLINE:") or first:match("^%s*CLOSED:"))
  then
    local j = 2
    while j <= ctx.n and is_blank(lines[j]) do
      j = j + 1
    end
    els[1] = { type = "planning", first = 1, post = 1, clast = 1, last = j - 1, children = {} }
    i = j
  end
  if i <= ctx.n then
    vim.list_extend(els, require("org.element").parse(lines, i, ctx.n))
  end
  local function fix(list, parent)
    for _, el in ipairs(list) do
      el.parent = parent
      if
        (parent.type == "item" or parent.type == "footnote-definition")
        and el.first == parent.first
        and el.type == "paragraph"
      then
        el.midline = true -- starts after the bullet / label
      end
      fix(el.children or {}, el)
    end
  end
  fix(els, ctx.root)
  ctx.root.children = els
  ctx.els = els
  return ctx
end

local function ind(ctx, i)
  if i < 1 then
    return 0
  end
  return indentation(ctx.lines[i], ctx.ts)
end

local function el_end(ctx, el)
  if el.type == "root" then
    return ctx.n + 1
  end
  return el.last + 1
end

--- Column of the body of a list item (org-list-item-body-column).
local function body_column(it)
  return it.indent + #it.bullet + 1
end

--- The node property of a property drawer line (property drawers have no
--- parsed children).
local function node_property(el, i)
  if el.type == "property-drawer" and i > el.post and i < el.clast then
    return { type = "node-property", first = i, post = i, clast = i, last = i, parent = el, children = {} }
  end
end

--- The row of an Org table at line `i`. At the beginning of the first row
--- org-element-at-point gives the table itself (`in_first` = inside it).
local function table_row(el, i, in_first)
  if el.type == "table" and el.cfirst and (i > el.post or (in_first and i == el.post)) and i <= el.clast then
    return { type = "table-row", first = i, post = i, clast = i, last = i, parent = el, children = {} }
  end
end

--- Deepest element at the beginning of local line `i`, like
--- org-element-at-point: the plain list at its first item.
local function at_bol(ctx, i)
  local found = ctx.root
  local function walk(list)
    for _, el in ipairs(list) do
      if el.first <= i and i <= el.last then
        found = el
        if el.type == "plain-list" then
          if i ~= el.post then
            walk(el.children)
          end
        elseif el.children and #el.children > 0 and i > el.post and i <= (el.cend or el.clast) then
          walk(el.children)
        elseif el.type == "item" and i > el.post then
          walk(el.children)
        end
        return
      end
    end
  end
  walk(ctx.els)
  return node_property(found, i) or found
end

--- Deepest element at the end of local line `i` (the paragraph after the
--- bullet on an item line).
local function at_eol(ctx, i)
  if i < 1 then
    return ctx.root
  end
  local found = ctx.root
  local function walk(list)
    for _, el in ipairs(list) do
      if el.first <= i and i <= el.last then
        found = el
        if
          el.children
          and #el.children > 0
          and (el.type == "plain-list" or el.type == "item" or el.type == "footnote-definition" or i > el.post)
          and i <= (el.cend or el.clast)
        then
          walk(el.children)
        end
        return
      end
    end
  end
  walk(ctx.els)
  return node_property(found, i) or table_row(found, i, true) or found
end

local function adapt()
  -- off in indent mode (ui.indent_mode_turns_off_adapt_indentation)
  return require("org.ui.decorations").adapt_indentation(0)
end

--- Whether `el` is headline data: planning, the property drawer, the log
--- drawer, or clock lines right after them (org--at-headline-data-p).
local function at_headline_data(ctx, el)
  if not el or el.type == "root" or not ctx.level then
    return false
  end
  while el.parent and el.parent.type ~= "root" do
    el = el.parent
  end
  if el.type == "planning" or el.type == "property-drawer" then
    return true
  elseif el.type == "drawer" then
    local name = (ctx.lines[el.post] or ""):match("^%s*:([%w_%-]+):")
    local log = config.opts.log_into_drawer
    log = log == true and "LOGBOOK" or log
    return type(log) == "string" and name ~= nil and name:upper() == log:upper()
  elseif el.type == "clock" then
    local p = el.first - 1
    return p < 1 or at_headline_data(ctx, at_eol(ctx, p))
  end
  return false
end

--- org--get-expected-indentation for local line `i`.
local function expected(ctx, el, contentsp, i)
  local t = el.type
  if contentsp then
    if t == "footnote-definition" or t == "diary-sexp" then
      return 0
    elseif t == "root" then
      return (adapt() and ctx.level) and ctx.level + 1 or 0
    elseif t == "item" then
      return body_column(el.list_item)
    elseif t == "plain-list" then
      return body_column(el.children[1].list_item)
    end
    return ind(ctx, el.first)
  end
  if t == "root" then
    if is_blank(ctx.lines[i]) then
      return expected(ctx, el, true, i)
    end
    return 0
  elseif t == "footnote-definition" or t == "diary-sexp" then
    return 0
  end
  local start = el.first
  -- first paragraph of an item or footnote definition: like the parent
  if el.midline and i == start then
    return expected(ctx, el.parent, true, i)
  end
  if i == start then
    local s = start
    while true do
      if s + ctx.offset == 1 then
        return 0
      end
      local prev = at_eol(ctx, s - 1)
      local parent = prev
      while parent and el_end(ctx, parent) <= s do
        prev = parent
        parent = parent.parent
      end
      if not prev then
        return 0
      elseif el_end(ctx, prev) > s then
        return expected(ctx, prev, true, i)
      elseif prev.type == "footnote-definition" or prev.type == "inlinetask" then
        s = prev.first
      elseif
        adapt() == "headline-data"
        and not at_headline_data(ctx, el)
        and (s - 1 == 0 or at_headline_data(ctx, at_eol(ctx, s - 1)))
      then
        return 0
      elseif prev.midline then
        return expected(ctx, prev.parent, true, i)
      else
        return ind(ctx, prev.first)
      end
    end
  end
  -- the first non-blank line above
  local p = i - 1
  while p >= 1 and is_blank(ctx.lines[p]) do
    p = p - 1
  end
  if (t == "footnote-definition" or t == "plain-list") and i - p > 2 then
    return ind(ctx, start)
  elseif p < start or (p == start and el.midline) then
    return expected(ctx, el.parent, true, i)
  elseif p == el.post then
    return expected(ctx, el, true, i)
  end
  if el.greater or BLOCKS[t] then
    local cend = el.cend and el.cend + 1 or el.clast
    if cend <= i then
      if t == "footnote-definition" or t == "item" or t == "plain-list" then
        local last = at_eol(ctx, p)
        return expected(ctx, last, last.type == "item", i)
      end
      return ind(ctx, start)
    end
  end
  return ind(ctx, p)
end

--- Whether `el` preserves its indentation (org-src-preserve-indentation-p).
local function preserve(ctx, el)
  if el.type ~= "src-block" and el.type ~= "example-block" then
    return false
  end
  local switches = (ctx.lines[el.post] or ""):match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_%S+%s*(.*)$") or ""
  if (" " .. switches .. " "):match("%s%-i%s") then
    return true
  end
  return config.opts.src_preserve_indentation == true
end

--- Content indentation of a src block (org-src-content-indentation past
--- the block's own), or nil when it preserves indentation.
local function src_content_column(ctx, el)
  if preserve(ctx, el) then
    return nil
  end
  return ind(ctx, el.first) + config.opts.edit_src_content_indentation
end

--- Smallest indentation of the non-blank contents of a src block.
local function src_min_indent(ctx, el)
  local min
  for k = el.post + 1, el.clast - 1 do
    if not is_blank(ctx.lines[k]) then
      min = math.min(min or math.huge, ind(ctx, k))
    end
  end
  return min or 0
end

--- Column for buffer line `lnum` (org-indent-line), or nil to leave it.
--- With `keep_verbatim` (for `=`), non-blank lines inside example, export
--- and verse blocks are left alone, so that indenting a region keeps their
--- relative indentation (org-indent-region).
---@param bufnr integer
---@param lnum integer
---@param keep_verbatim? boolean
---@return integer|nil
function M.line_column(bufnr, lnum, keep_verbatim)
  local ctx = context(bufnr, lnum)
  local i = lnum - ctx.offset
  if i < 1 then
    return nil -- a headline
  end
  -- org-element-at-point-no-context gives the row of a table
  local el = at_bol(ctx, i)
  el = table_row(el, i) or el
  local t = el.type
  if adapt() == "headline-data" and ctx.level and not at_headline_data(ctx, el) then
    -- the line before the element (its own line for a paragraph after a bullet)
    local b = el.midline and el.first or el.first - 1
    if t == "root" or b == 0 or at_headline_data(ctx, at_eol(ctx, b)) then
      return nil
    end
  end
  if (t == "plain-list" or t == "item") and i == el.post then
    return nil
  elseif t == "latex-environment" and i >= el.post and i <= el.clast then
    return nil
  elseif
    keep_verbatim
    and (t == "example-block" or t == "export-block" or t == "verse-block")
    and i > el.post
    and i < el.clast
    and not is_blank(ctx.lines[i])
  then
    return nil
  elseif t == "src-block" and i > el.post and i < el.clast and config.opts.src_tab_acts_natively ~= false then
    -- With org-src-tab-acts-natively off, Emacs indents code like any other
    -- line (the expected indentation below). Otherwise it moves the line to
    -- the block's content indentation, then lets
    -- the language's major mode indent it. Keep the code's own relative
    -- indentation instead; blank lines are indented like the code above.
    local target = src_content_column(ctx, el)
    if is_blank(ctx.lines[i]) then
      local p = i - 1
      while p > el.post and is_blank(ctx.lines[p]) do
        p = p - 1
      end
      if p > el.post then
        return ind(ctx, p)
      end
      return target or 0
    end
    if not target then
      return nil
    end
    return target + ind(ctx, i) - src_min_indent(ctx, el)
  end
  return expected(ctx, el, false, i)
end

--- 'indentexpr' of org buffers.
function M.indentexpr()
  local lnum = vim.v.lnum
  local ok, col = pcall(M.line_column, vim.api.nvim_get_current_buf(), lnum, true)
  if not ok or col == nil then
    return -1
  end
  return col
end

local function set_indent(bufnr, lnum, col)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  local ws = line:match("^[ \t]*")
  local new = string.rep(" ", col)
  if ws ~= new and not (indentation(line, vim.bo[bufnr].tabstop) == col and not vim.bo[bufnr].expandtab) then
    vim.api.nvim_buf_set_text(bufnr, lnum - 1, 0, lnum - 1, #ws, { new })
  end
end

--- Align the node property on buffer line `lnum` (org--align-node-property).
local function align_property(bufnr, lnum)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  local ws, key, value = line:match("^([ \t]*):([^%s:]+%+?):%s*(.-)%s*$")
  if not ws or key:upper() == "END" then
    return
  end
  local new = ws .. vim.trim(string.format(config.opts.property_format or "%-10s %s", ":" .. key .. ":", value))
  if new ~= line then
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new })
  end
end

--- Indent line `lnum` of the current buffer like org-indent-line (TAB),
--- keeping the cursor on the same text.
function M.indent_line(lnum)
  local bufnr = vim.api.nvim_get_current_buf()
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local col = M.line_column(bufnr, lnum)
  if not col then
    return
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  local cur = #line:match("^[ \t]*")
  local c = vim.api.nvim_win_get_cursor(0)
  set_indent(bufnr, lnum, col)
  local ctx = context(bufnr, lnum)
  local el = at_bol(ctx, lnum - ctx.offset)
  if el.type == "node-property" then
    align_property(bufnr, lnum)
  end
  if c[1] == lnum then
    local len = #vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    -- point in the indentation goes to the new indentation, else it stays
    -- on the same text
    local newcol = c[2] <= cur and col or c[2] + col - cur
    vim.api.nvim_win_set_cursor(0, { lnum, math.max(0, math.min(newcol, len)) })
  end
end

---------------------------------------------------------------------------
-- Regions
---------------------------------------------------------------------------

--- Shift the non-blank lines [s, e] by `offset` columns (indent-rigidly).
local function indent_rigidly(bufnr, s, e, offset)
  if offset == 0 then
    return
  end
  local ts = vim.bo[bufnr].tabstop
  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  for k, l in ipairs(lines) do
    if is_blank(l) then
      lines[k] = ""
    else
      local cur = indentation(l, ts)
      lines[k] = string.rep(" ", math.max(0, cur + offset)) .. l:gsub("^[ \t]*", "")
    end
  end
  vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, lines)
end

--- Indent the non-blank lines [from, to) to `col`.
local function indent_to(bufnr, from, to, col)
  local lines = vim.api.nvim_buf_get_lines(bufnr, from - 1, to - 1, false)
  for k, l in ipairs(lines) do
    if not is_blank(l) then
      set_indent(bufnr, from + k - 1, col)
    end
  end
end

--- org-indent-region: indent every non-blank line of buffer lines [s, e].
--- Contents of example, verse and export blocks keep their relative
--- indentation; plain lists and example blocks move as a whole.
---@param bufnr integer
---@param s integer
---@param e integer
function M.indent_region(bufnr, s, e)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local total = vim.api.nvim_buf_line_count(bufnr)
  e = math.min(e, total)
  local l = s
  local function line(k)
    return vim.api.nvim_buf_get_lines(bufnr, k - 1, k, false)[1]
  end
  while l <= e and is_blank(line(l)) do
    l = l + 1
  end
  local stop = e + 1 -- exclusive
  while l < stop do
    local text = line(l)
    if is_blank(text) or headline(text) then
      l = l + 1
    else
      local ctx = context(bufnr, l)
      local i = l - ctx.offset
      local el = at_bol(ctx, i)
      local t = el.type
      local o = ctx.offset
      local element_end = el_end(ctx, el) + o
      local col = expected(ctx, el, false, i)
      if t == "root" then
        l = l + 1
      elseif
        t == "export-block"
        or t == "latex-environment"
        or (t == "example-block" and not preserve(ctx, el))
      then
        indent_rigidly(bufnr, el.first + o, el.last + o, col - ind(ctx, i))
        l = element_end
      elseif
        t == "paragraph"
        or t == "table"
        or (not el.greater and t ~= "example-block" and t ~= "src-block" and t ~= "verse-block")
        or (el.greater and not el.cfirst and t ~= "plain-list" and t ~= "item")
      then
        if t == "node-property" then
          align_property(bufnr, l)
        end
        indent_to(bufnr, l, math.min(element_end, stop), col)
        l = math.min(element_end, stop)
      else
        local cbeg
        if not el.cfirst and (t == "src-block" or t == "example-block" or t == "verse-block") then
          cbeg = el.post + 1 + o
        elseif t == "footnote-definition" or t == "item" or t == "plain-list" then
          local k = el.post + 1
          while k <= ctx.n and is_blank(ctx.lines[k]) do
            k = k + 1
          end
          cbeg = k + o
        else
          cbeg = (el.cfirst or el.post + 1) + o
        end
        local cend = (el.cend and el.cend + 1 or el.clast) + o
        if t == "plain-list" then
          indent_rigidly(bufnr, el.first + o, el.last + o, col - ind(ctx, i))
          l = cbeg
        elseif t == "item" then
          l = cbeg
        else
          indent_to(bufnr, l, math.min(cbeg, stop), col)
          l = math.min(cbeg, stop)
        end
        if l < stop then
          if t == "src-block" then
            -- Emacs indents the code with the language's major mode; move
            -- it to the content indentation, keeping its own layout
            local target = not preserve(ctx, el) and col + config.opts.edit_src_content_indentation
            if target and l < math.min(cend, stop) then
              indent_rigidly(bufnr, l, math.min(cend, stop) - 1, target - src_min_indent(ctx, el))
            end
          elseif t ~= "example-block" and t ~= "verse-block" and l < math.min(cend, stop) then
            M.indent_region(bufnr, l, math.min(cend, stop) - 1)
          end
          l = math.max(l, math.min(cend, stop))
          if l < stop then
            indent_to(bufnr, l, math.min(element_end, stop), col)
            l = math.min(element_end, stop)
          end
        end
      end
    end
  end
end

--- The Visual selection or the whole buffer (org-indent-region / `=`).
function M.indent_region_action()
  local bufnr = vim.api.nvim_get_current_buf()
  local m = vim.fn.mode()
  if m == "v" or m == "V" or m == "\22" then
    local s, _, e = require("org.utils").visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    M.indent_region(bufnr, s, e)
  else
    M.indent_region(bufnr, 1, vim.api.nvim_buf_line_count(bufnr))
  end
end

--- `=` operator: org-indent-region on the lines moved over.
function M.operator(kind)
  local s = vim.api.nvim_buf_get_mark(0, "[")[1]
  local e = vim.api.nvim_buf_get_mark(0, "]")[1]
  M.indent_region(0, s, e)
  return kind
end

local function element_of(types, what)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local ctx = context(bufnr, lnum)
  local i = lnum - ctx.offset
  -- the element at point, like Emacs: inside a quote block that is the
  -- paragraph, inside a property drawer the node property
  local el = i >= 1 and at_bol(ctx, i) or nil
  if not el or not types[el.type] then
    require("org.utils").warn("Not at a " .. what)
    return nil
  end
  M.indent_region(bufnr, el.first + ctx.offset, el.last + ctx.offset)
  return true
end

--- org-indent-block: indent the block at the cursor.
function M.indent_block()
  if
    element_of({
      ["comment-block"] = true,
      ["center-block"] = true,
      ["dynamic-block"] = true,
      ["example-block"] = true,
      ["export-block"] = true,
      ["quote-block"] = true,
      ["special-block"] = true,
      ["src-block"] = true,
      ["verse-block"] = true,
    }, "block")
  then
    require("org.utils").notify("Block at point indented")
  end
end

--- org-indent-drawer: indent the drawer at the cursor.
function M.indent_drawer()
  if element_of({ drawer = true, ["property-drawer"] = true }, "drawer") then
    require("org.utils").notify("Drawer at point indented")
  end
end

--- org-unindent-buffer: remove the common indentation of every top-level
--- element of every section. Relative indentation (between items, inside
--- blocks, ...) is kept.
function M.unindent_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local ts = vim.bo[bufnr].tabstop
  local changed = false
  local function unindent(s, e)
    local min
    for k = s, e do
      if not is_blank(lines[k]) then
        local c = indentation(lines[k], ts)
        if c == 0 then
          return
        end
        min = math.min(min or c, c)
      end
    end
    if not min then
      return
    end
    for k = s, e do
      local c = indentation(lines[k], ts)
      if is_blank(lines[k]) and c < min then
        lines[k] = ""
      else
        lines[k] = string.rep(" ", c - min) .. lines[k]:gsub("^[ \t]*", "")
      end
    end
    changed = true
  end
  local s = 1
  local n = #lines
  while s <= n do
    local e = s
    while e + 1 <= n and not headline(lines[e + 1]) do
      e = e + 1
    end
    local from = headline(lines[s]) and s + 1 or s
    if from <= e then
      local sub = {}
      for k = from, e do
        sub[#sub + 1] = lines[k]
      end
      local els = {}
      local i = 1
      local planning = sub[1]
        and (sub[1]:match("^%s*SCHEDULED:") or sub[1]:match("^%s*DEADLINE:") or sub[1]:match("^%s*CLOSED:"))
      if headline(lines[s]) and planning then
        local j = 2
        while j <= #sub and is_blank(sub[j]) do
          j = j + 1
        end
        els[1] = { first = 1, last = j - 1 }
        i = j
      end
      if i <= #sub then
        vim.list_extend(els, require("org.element").parse(sub, i, #sub))
      end
      for k = #els, 1, -1 do
        unindent(els[k].first + from - 1, els[k].last + from - 1)
      end
    end
    s = e + 1
  end
  if changed then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  end
end

return M
