---@mod org.table.el table.el tables
---
--- Tables in the format of Emacs's table.el package: a grid of `+`, `-`
--- (or `=`) and `|` characters whose cells can span rows and columns and
--- hold several lines of text:
---
---   +-----+--+
---   |0    |1 |
---   +--+--+  |
---   |2 |3 |  |
---   +--+--+--+
---
--- Org leaves them alone (TAB, C-c C-c and formulas only work in Org
--- tables). This module finds them (org-element's rules), converts between
--- Org tables and table.el (org-table-convert), edits them in a special
--- buffer that realigns the grid (org-edit-table.el) and generates the
--- HTML and LaTeX source the exporters use (table-generate-source).
---
--- Columns are counted in characters: double-width characters in cells
--- are not supported.

local utils = require("org.utils")

local M = {}

---------------------------------------------------------------------------
-- Detection
---------------------------------------------------------------------------

--- A full rule `+--+---+` (org-element: a table.el table starts and ends
--- with one).
function M.is_rule(line)
  local body = line and line:match("^[ \t]*%+([%-+]*)[ \t]*$")
  return body ~= nil and body ~= "" and body:gsub("%-+%+", "") == ""
end

--- A line that can be part of a table.el table.
local function grid_line(line)
  return line ~= nil and line:match("^[ \t]*[+|]") ~= nil
end

--- Last line of the table.el table starting at `i` in `lines` (up to line
--- `e`), or nil when no table starts there (org-element--current-element).
function M.table_end(lines, i, e)
  e = e or #lines
  if not M.is_rule(lines[i]) or i + 1 > e then
    return nil
  end
  local j = i + 1
  while j <= e and grid_line(lines[j]) do
    j = j + 1
  end
  if j == i + 1 or not M.is_rule(lines[j - 1]) then
    return nil
  end
  return j - 1
end

--- The table.el table of `lines` containing line `lnum`: its first and
--- last line numbers, or nil (also inside an Org table).
function M.bounds(lines, lnum)
  if not grid_line(lines[lnum]) then
    return nil
  end
  local s, f = lnum, lnum
  while grid_line(lines[s - 1]) do
    s = s - 1
  end
  while grid_line(lines[f + 1]) do
    f = f + 1
  end
  -- Walk the run as the element parser does: `|` lines start Org tables,
  -- which end before the next `+` line.
  local i = s
  while i <= lnum do
    if lines[i]:match("^[ \t]*|") then
      while i <= f and lines[i]:match("^[ \t]*|") do
        i = i + 1
      end
      if i > lnum then
        return nil
      end
    else
      local last = M.table_end(lines, i, f)
      if last then
        if lnum <= last then
          return i, last
        end
        i = last + 1
      else
        i = i + 1
      end
    end
  end
  return nil
end

--- The table.el table at line `lnum` of a buffer, or nil:
--- `{ start, finish, lines }`.
function M.at(bufnr, lnum)
  bufnr = bufnr or 0
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  if not grid_line(line) then
    return nil
  end
  -- Only the run of grid lines around `lnum` matters.
  local n = vim.api.nvim_buf_line_count(bufnr)
  local s, f = lnum, lnum
  local function get(l)
    return vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]
  end
  while s > 1 and grid_line(get(s - 1)) do
    s = s - 1
  end
  while f < n and grid_line(get(f + 1)) do
    f = f + 1
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, f, false)
  local a, b = M.bounds(lines, lnum - s + 1)
  if not a then
    return nil
  end
  return { start = s + a - 1, finish = s + b - 1, lines = vim.list_slice(lines, a, b) }
end

---------------------------------------------------------------------------
-- Grid analysis
---------------------------------------------------------------------------

local function chars(s)
  local out = {}
  for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    out[#out + 1] = c
  end
  return out
end

local function is_h(c)
  return c == "-" or c == "="
end

local function is_v(c)
  return c == "|" or c == "+"
end

--- Cells of a table.el grid. Each cell is `{ top, left, bottom, right,
--- lines }`: the 1-based line and character indexes of its borders and
--- the text inside them. Cells are sorted by position (the order
--- table-forward-cell visits them). Returns nil when there is none.
---@param lines string[]
function M.parse(lines)
  local g = {}
  for y, l in ipairs(lines) do
    g[y] = chars(l)
  end
  local function at(y, x)
    return g[y] and g[y][x] or nil
  end
  local cells = {}
  for y = 1, #g do
    for x = 1, #g[y] do
      if at(y, x) == "+" and is_h(at(y, x + 1)) and is_v(at(y + 1, x)) then
        -- Right: the first corner of the top border with a border below.
        local x2 = x + 1
        while at(y, x2) and not (at(y, x2) == "+" and is_v(at(y + 1, x2))) do
          if not (is_h(at(y, x2)) or at(y, x2) == "+") then
            x2 = nil
            break
          end
          x2 = x2 + 1
        end
        -- Down: the first corner of the left border with a border right.
        local y2 = y + 1
        while x2 and at(y2, x) and not (at(y2, x) == "+" and (is_h(at(y2, x + 1)) or at(y2, x + 1) == "+")) do
          if not is_v(at(y2, x)) then
            y2 = nil
            break
          end
          y2 = y2 + 1
        end
        local good = x2 and y2 and at(y, x2) and at(y2, x) and at(y2, x2) == "+"
        for k = y + 1, good and y2 - 1 or 0 do
          good = good and is_v(at(k, x2))
        end
        for k = x + 1, good and x2 - 1 or 0 do
          good = good and (is_h(at(y2, k)) or at(y2, k) == "+")
        end
        if good then
          local text = {}
          for k = y + 1, y2 - 1 do
            local row = {}
            for c = x + 1, x2 - 1 do
              row[#row + 1] = at(k, c) or " "
            end
            text[#text + 1] = table.concat(row)
          end
          cells[#cells + 1] = { top = y, left = x, bottom = y2, right = x2, lines = text }
        end
      end
    end
  end
  if #cells == 0 then
    return nil
  end
  return cells, g
end

local function sorted_keys(set)
  local out = vim.tbl_keys(set)
  table.sort(out)
  return out
end

--- The column and row lists of table-generate-source: where cells' text
--- starts.
local function col_row_lists(cells)
  local cols, rows = {}, {}
  for _, c in ipairs(cells) do
    cols[c.left + 1] = true
    rows[c.top + 1] = true
  end
  return sorted_keys(cols), sorted_keys(rows)
end

---------------------------------------------------------------------------
-- Source generation (table-generate-source)
---------------------------------------------------------------------------

--- The comment table.el puts first in generated HTML (Emacs names its
--- version there).
M.html_generator = "org.nvim"

--- HTML for the table.el table in `lines`, like `table-generate-source`
--- (without cell justification: the table is not "recognized" first, so
--- every cell is `align="left" valign="top"`). Nil when `lines` is not a
--- table.el grid.
---@param lines string[]
function M.to_html(lines)
  local cells = M.parse(lines)
  if not cells then
    return nil
  end
  local col_list, row_list = col_row_lists(cells)
  local out = {
    string.format("<!-- This HTML table template is generated by %s -->", M.html_generator),
    '<table border="1">',
  }
  local idx = 1
  for ri = 1, #row_list do
    out[#out + 1] = "  <tr>"
    local ci = 1
    while ci <= #col_list do
      local cell = cells[idx]
      local lu = cell.left + 1
      if lu < col_list[ci] then
        break
      end
      while ci <= #col_list and lu > col_list[ci] do
        ci = ci + 1
      end
      ci = ci + 1
      local colspan, rowspan = 1, 1
      while ci <= #col_list and cell.right + 1 > col_list[ci] do
        colspan = colspan + 1
        ci = ci + 1
      end
      local rj = ri + 1
      while rj <= #row_list and cell.bottom + 1 > row_list[rj] do
        rowspan = rowspan + 1
        rj = rj + 1
      end
      local attrs = (colspan > 1 and string.format(' colspan="%d"', colspan) or "")
        .. (rowspan > 1 and string.format(' rowspan="%d"', rowspan) or "")
      out[#out + 1] = string.format('    <td%s align="left" valign="top">', attrs)
      for k, l in ipairs(cell.lines) do
        l = l:gsub(" ", "&nbsp;") .. (k < #cell.lines and "<br />" or "")
        out[#out + 1] = l == "" and "" or ("      " .. l)
      end
      out[#out + 1] = "    </td>"
      idx = idx % #cells + 1
    end
    out[#out + 1] = "  </tr>"
  end
  out[#out + 1] = "</table>"
  return table.concat(out, "\n")
end

local function latex_escape(s)
  return (
    s:gsub("[#$~_^%%{}&\\<>|]", function(c)
      if c == "\\" then
        return "$\\backslash$"
      elseif c:match("[<>|]") then
        return "$" .. c .. "$"
      end
      return "\\" .. c
    end)
  )
end

--- LaTeX `tabular` for the table.el table in `lines`, like
--- `table-generate-source` scanning it line by line (spanned columns become
--- `\multicolumn`, partial rules `\cline`). Nil when `lines` is not a
--- table.el grid.
---@param lines string[]
function M.to_latex(lines)
  local cells, g = M.parse(lines)
  if not cells then
    return nil
  end
  local col_list, row_list = col_row_lists(cells)
  local is_row = {}
  for _, r in ipairs(row_list) do
    is_row[r] = true
  end
  local origin, tail = cells[1], cells[1]
  for _, c in ipairs(cells) do
    if c.bottom > tail.bottom or (c.bottom == tail.bottom and c.right > tail.right) then
      tail = c
    end
  end
  local function at(y, x)
    return g[y] and g[y][x] or nil
  end
  local buf = { "\\begin{tabular}{|" .. string.rep("l|", #col_list) .. "}\n\\hline\n" }
  local function last_char()
    return buf[#buf]:sub(-1)
  end
  local function put(s)
    if s ~= "" then
      buf[#buf + 1] = s
    end
  end
  local x0, x1 = origin.left + 1, tail.right
  for y = origin.top + 1, tail.bottom - 1 do
    if is_row[y + 1] then
      local bc = {}
      for i, x in ipairs(col_list) do
        bc[i] = at(y, x) or ""
      end
      local uniform = true
      for i = 2, #bc do
        uniform = uniform and bc[i] == bc[1]
      end
      if is_h(bc[1]) and uniform then
        put("\\hline\n")
      else
        local start
        for i, c in ipairs(bc) do
          if start and not is_h(c) then
            put(string.format("\\cline{%d-%d}\n", start, i - 1))
            start = nil
          end
          if not start and is_h(c) then
            start = i
          end
        end
        if start then
          put(string.format("\\cline{%d-%d}\n", start, #bc))
        end
      end
    else
      local span, first, start = 1, true, x0
      local function column(from, to)
        local t = {}
        for x = from, to - 1 do
          t[#t + 1] = at(y, x) or ""
        end
        local text = latex_escape(vim.trim(table.concat(t)))
        if not first then
          put((last_char() == " " and "" or " ") .. "& ")
        end
        if span > 1 then
          put(string.format("\\multicolumn{%d}{%sl|}{%s}", span, first and "|" or "", text))
        else
          put(text)
        end
        first = false
        span = 1
      end
      for i = 2, #col_list do
        if at(y, col_list[i] - 1) == "|" then
          column(start, col_list[i] - 1)
          start = col_list[i]
        else
          span = span + 1
        end
      end
      column(start, x1)
      put((last_char() == " " and "" or " ") .. "\\\\\n")
    end
  end
  put("\\hline\n\\end{tabular}")
  return table.concat(buf)
end

---------------------------------------------------------------------------
-- Conversion (org-table-convert)
---------------------------------------------------------------------------

--- Org table lines (aligned) to a table.el table: horizontal rules are
--- dropped and every row gets a border above and below.
---@param lines string[]
function M.from_org(lines)
  local rows = {}
  for _, l in ipairs(lines) do
    if not l:match("^[ \t]*|%-") then
      rows[#rows + 1] = l
    end
  end
  local function border(row)
    local indent, body = row:match("^([ \t]*)(.-)[ \t]*$")
    body = body:gsub("[^|]", "-"):gsub("|", "+")
    return indent .. body
  end
  local out = {}
  for i, row in ipairs(rows) do
    if i == 1 then
      out[#out + 1] = border(row)
    end
    out[#out + 1] = row
    out[#out + 1] = border(row)
  end
  return out
end

--- table.el lines to an Org table: the lines of `+` borders are removed,
--- the rest is kept as is (so spanned and multi-line cells split).
---@param lines string[]
function M.to_org(lines)
  local out = {}
  for _, l in ipairs(lines) do
    if not l:match("^[ \t]*%+%-") then
      out[#out + 1] = l
    end
  end
  return out
end

--- A new table.el table (table-insert): `widths` and `heights` are lists
--- whose last value repeats.
function M.new(columns, rows, widths, heights, indent)
  indent = indent or ""
  local border, line = { "+" }, { "|" }
  for c = 1, columns do
    local w = widths[math.min(c, #widths)]
    border[#border + 1] = string.rep("-", w) .. "+"
    line[#line + 1] = string.rep(" ", w) .. "|"
  end
  local out = { indent .. table.concat(border) }
  for r = 1, rows do
    for _ = 1, heights[math.min(r, #heights)] do
      out[#out + 1] = indent .. table.concat(line)
    end
    out[#out + 1] = out[1]
  end
  return out
end

local function read_numbers(prompt, default)
  local s = utils.input({ prompt = string.format("%s (default %s): ", prompt, default) })
  if s == nil then
    return nil
  end
  s = s:match("^%s*$") and default or s
  local out = {}
  for n in s:gmatch("%S+") do
    local v = tonumber(n)
    if not v or v < 1 or v % 1 ~= 0 then
      utils.error(prompt .. " must be a positive integer or a list of positive integers")
      return nil
    end
    out[#out + 1] = v
  end
  return #out > 0 and out or nil
end

--- C-c ~ (org-table-create-with-table.el): convert the table at the cursor
--- between Org and table.el, or insert a new table.el table.
function M.create_or_convert()
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local el = M.at(bufnr, lnum)
  if el then
    if utils.confirm("Convert table to Org table? ") then
      vim.api.nvim_buf_set_lines(bufnr, el.start - 1, el.finish, false, M.to_org(el.lines))
      vim.api.nvim_win_set_cursor(0, { el.start, 0 })
    end
    return
  end
  local tbl = require("org.table")
  if tbl.find(bufnr, lnum) and tbl.is_table_line(vim.api.nvim_get_current_line()) then
    if utils.confirm("Convert table to table.el table? ") then
      tbl.align()
      local info = tbl.find(bufnr, lnum)
      vim.api.nvim_buf_set_lines(bufnr, info.start - 1, info.finish, false, M.from_org(info.lines))
      vim.api.nvim_win_set_cursor(0, { info.start, 0 })
    end
    return
  end
  local cols = read_numbers("Number of columns", "3")
  local rows = cols and read_numbers("Number of rows", "3")
  local widths = rows and read_numbers("Cell width(s)", "5")
  local heights = widths and read_numbers("Cell height(s)", "1")
  if not heights then
    return
  end
  -- Emacs draws the table at the cursor, pushing a blank line down; here a
  -- table started on a non-blank line goes below it.
  local line = vim.api.nvim_get_current_line()
  local new = M.new(cols[1], rows[1], widths, heights, line:match("^[ \t]*$") and "" or line:match("^([ \t]*)"))
  if line:match("^[ \t]*$") then
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum - 1, false, new)
    vim.api.nvim_win_set_cursor(0, { lnum + 1, 1 })
  else
    vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, new)
    vim.api.nvim_win_set_cursor(0, { lnum + 2, #new[2]:match("^[ \t]*") + 1 })
  end
end

---------------------------------------------------------------------------
-- Realignment
---------------------------------------------------------------------------

local function index_of(list, v)
  for i, x in ipairs(list) do
    if x == v then
      return i
    end
  end
end

--- The structure of a parsed grid: boundary positions, band sizes and each
--- cell's place in bands, with the character of every horizontal border
--- segment (`-` or `=`).
local function structure(cells, g)
  local xs, ys = {}, {}
  for _, c in ipairs(cells) do
    xs[c.left], xs[c.right], ys[c.top], ys[c.bottom] = true, true, true, true
  end
  xs, ys = sorted_keys(xs), sorted_keys(ys)
  local s = { xs = xs, ys = ys, w = {}, h = {}, cells = {}, hchar = {} }
  for k = 1, #xs - 1 do
    s.w[k] = xs[k + 1] - xs[k] - 1
  end
  for k = 1, #ys - 1 do
    s.h[k] = ys[k + 1] - ys[k] - 1
  end
  for i, c in ipairs(cells) do
    local sc = {
      c0 = index_of(xs, c.left),
      c1 = index_of(xs, c.right),
      r0 = index_of(ys, c.top),
      r1 = index_of(ys, c.bottom),
      lines = c.lines,
    }
    s.cells[i] = sc
    for _, r in ipairs({ sc.r0, sc.r1 }) do
      for k = sc.c0, sc.c1 - 1 do
        local ch = g[ys[r]][xs[k] + 1]
        s.hchar[r .. ":" .. k] = s.hchar[r .. ":" .. k] or (ch == "=" and "=" or nil)
      end
    end
  end
  return s
end

local function rtrim(s)
  return (s:gsub("[ \t]+$", ""))
end

--- Draw a structure, widening bands so every cell's text fits.
local function render(s, indent)
  local w, h = vim.deepcopy(s.w), vim.deepcopy(s.h)
  local function span(sizes, a, b)
    local n = -1
    for k = a, b - 1 do
      n = n + sizes[k] + 1
    end
    return n
  end
  local changed = true
  while changed do
    changed = false
    for _, c in ipairs(s.cells) do
      local need_w, need_h = 0, #c.lines
      for _, l in ipairs(c.lines) do
        need_w = math.max(need_w, #chars(rtrim(l)))
      end
      local have = span(w, c.c0, c.c1)
      if have < need_w then
        w[c.c1 - 1] = w[c.c1 - 1] + need_w - have
        changed = true
      end
      have = span(h, c.r0, c.r1)
      if have < need_h then
        h[c.r1 - 1] = h[c.r1 - 1] + need_h - have
        changed = true
      end
    end
  end
  local X, Y = { 1 }, { 1 }
  for k = 1, #w do
    X[k + 1] = X[k] + w[k] + 1
  end
  for k = 1, #h do
    Y[k + 1] = Y[k] + h[k] + 1
  end
  local canvas = {}
  for y = 1, Y[#Y] do
    canvas[y] = {}
    for x = 1, X[#X] do
      canvas[y][x] = " "
    end
  end
  for _, c in ipairs(s.cells) do
    for _, r in ipairs({ c.r0, c.r1 }) do
      for k = c.c0, c.c1 - 1 do
        for x = X[k], X[k + 1] do
          canvas[Y[r]][x] = s.hchar[r .. ":" .. k] or "-"
        end
      end
    end
    for y = Y[c.r0], Y[c.r1] do
      canvas[y][X[c.c0]] = "|"
      canvas[y][X[c.c1]] = "|"
    end
    for i, l in ipairs(c.lines) do
      for j, ch in ipairs(chars(rtrim(l))) do
        canvas[Y[c.r0] + i][X[c.c0] + j] = ch
      end
    end
  end
  for _, c in ipairs(s.cells) do
    for _, y in ipairs({ Y[c.r0], Y[c.r1] }) do
      canvas[y][X[c.c0]] = "+"
      canvas[y][X[c.c1]] = "+"
    end
  end
  local out = {}
  for y, row in ipairs(canvas) do
    out[y] = (indent or "") .. rtrim(table.concat(row))
  end
  return out
end

--- What each line of a drawn structure holds, left to right: the text of
--- a cell (`{ cell, line }`) or a border segment (`{}`).
local function signatures(s)
  local X, Y = { 1 }, { 1 }
  for k = 1, #s.w do
    X[k + 1] = X[k] + s.w[k] + 1
  end
  for k = 1, #s.h do
    Y[k + 1] = Y[k] + s.h[k] + 1
  end
  local sigs = {}
  for y = 1, Y[#Y] do
    local items = {}
    for i, c in ipairs(s.cells) do
      local top, bottom = Y[c.r0], Y[c.r1]
      if y > top and y < bottom then
        items[#items + 1] = { x = X[c.c0], cell = i, line = y - top }
      elseif y == top or y == bottom then
        items[#items + 1] = { x = X[c.c0], border = true }
      end
    end
    table.sort(items, function(a, b)
      return a.x < b.x
    end)
    -- A border line shared by two cells is one item.
    local merged = {}
    for _, it in ipairs(items) do
      local prev = merged[#merged]
      if not (prev and prev.border and it.border and prev.x == it.x) then
        merged[#merged + 1] = it
      end
    end
    local band
    for k = 1, #Y - 1 do
      if y > Y[k] and y < Y[k + 1] then
        band = k
      end
    end
    local content = band ~= nil
    for _, it in ipairs(merged) do
      content = content and not it.border
    end
    sigs[y] = { items = merged, band = content and band or nil }
  end
  return sigs
end

--- Split an edited line along a signature: the texts of its cells, or nil
--- when the line does not have that shape.
local function split_line(line, sig)
  local cs = chars(line)
  local p = 1
  while cs[p] == " " or cs[p] == "\t" do
    p = p + 1
  end
  local last = #cs
  while last > 0 and (cs[last] == " " or cs[last] == "\t") do
    last = last - 1
  end
  if not is_v(cs[p]) or not is_v(cs[last]) or p == last then
    return nil
  end
  p = p + 1
  local texts = {}
  for n, it in ipairs(sig.items) do
    local nxt = sig.items[n + 1]
    local q
    if it.border then
      q = p
      while q < last and is_h(cs[q]) do
        q = q + 1
      end
      if cs[q] ~= "+" then
        return nil
      end
    elseif not nxt then
      q = last
    else
      q = p
      while q < last do
        if nxt.border and cs[q] == "+" and is_h(cs[q + 1]) or not nxt.border and cs[q] == "|" then
          break
        end
        q = q + 1
      end
      if q >= last then
        return nil
      end
      texts[#texts + 1] = { it, table.concat(cs, "", p, q - 1) }
    end
    if not nxt then
      if q ~= last then
        return nil
      end
      if not it.border then
        texts[#texts + 1] = { it, table.concat(cs, "", p, q - 1) }
      end
    end
    p = q + 1
  end
  -- A `|` typed in a cell would read as a border next time.
  for _, t in ipairs(texts) do
    if t[2]:find("|", 1, true) then
      return nil
    end
  end
  return texts
end

--- Read the cells of an edited drawing of structure `s` back: the lines
--- may be longer or shorter than drawn, and lines holding only cell text
--- may be added (a copy of such a line) or removed. Nil when the lines do
--- not have the table's shape.
local function reread(lines, s)
  local sigs = signatures(s)
  local texts = {}
  for i = 1, #s.cells do
    texts[i] = {}
  end
  local h = vim.deepcopy(s.h)
  local function take(parts)
    for _, part in ipairs(parts) do
      table.insert(texts[part[1].cell], part[2])
    end
  end
  local p = 1
  for _, line in ipairs(lines) do
    local parts = sigs[p] and split_line(line, sigs[p])
    if parts then
      take(parts)
      p = p + 1
    else
      -- A line added to the band of the line above?
      local prev = sigs[p - 1]
      parts = prev and prev.band and split_line(line, prev)
      if parts then
        take(parts)
        h[prev.band] = h[prev.band] + 1
      else
        -- Lines removed from a band.
        while sigs[p] and sigs[p].band and not parts do
          h[sigs[p].band] = h[sigs[p].band] - 1
          p = p + 1
          parts = sigs[p] and split_line(line, sigs[p])
        end
        if not parts then
          return nil
        end
        take(parts)
        p = p + 1
      end
    end
  end
  while sigs[p] and sigs[p].band do
    h[sigs[p].band] = h[sigs[p].band] - 1
    p = p + 1
  end
  if p <= #sigs then
    return nil
  end
  local new = vim.deepcopy(s)
  new.h = h
  for i, c in ipairs(new.cells) do
    c.lines = texts[i]
    if #c.lines == 0 then
      return nil
    end
  end
  return new
end

--- Parse well-formed grid lines into a structure, or nil when the cells do
--- not tile one rectangle.
local function read_grid(lines)
  local cells, g = M.parse(lines)
  if not cells then
    return nil
  end
  local s = structure(cells, g)
  local area = 0
  for _, c in ipairs(s.cells) do
    area = area + (s.xs[c.c1] - s.xs[c.c0]) * (s.ys[c.r1] - s.ys[c.r0])
  end
  if area ~= (s.xs[#s.xs] - s.xs[1]) * (s.ys[#s.ys] - s.ys[1]) or s.ys[1] ~= 1 or s.ys[#s.ys] ~= #lines then
    return nil
  end
  return s
end

--- Realign table.el lines: widen columns and rows so that every cell's
--- text fits again after editing, keeping spanned cells. `before` is the
--- last aligned version of the table, which tells where cells are when the
--- edited lines no longer line up. Returns the new lines, or nil and a
--- message.
---@param lines string[] edited table lines (without indentation)
---@param before? string[] the table before editing
function M.realign(lines, before)
  local s = before and read_grid(before)
  s = s and reread(lines, s)
  s = s or read_grid(lines)
  if not s then
    return nil, "Cannot realign the table.el table: its grid is broken"
  end
  return render(s)
end

---------------------------------------------------------------------------
-- Editing (org-edit-table.el)
---------------------------------------------------------------------------

--- C-c ' on a table.el table: edit it in a special buffer. The grid is
--- realigned when leaving Insert mode and when the buffer is written back
--- (Emacs's table.el resizes cells while typing).
function M.edit(bufnr, lnum)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local el = M.at(bufnr, lnum)
  if not el then
    utils.error("Not in a table.el table")
    return false
  end
  local indent = el.lines[1]:match("^[ \t]*")
  for _, l in ipairs(el.lines) do
    local i = l:match("^[ \t]*")
    if #i < #indent then
      indent = i
    end
  end
  local body = {}
  for i, l in ipairs(el.lines) do
    body[i] = l:sub(#indent + 1)
  end
  local col = vim.api.nvim_get_current_buf() == bufnr and vim.api.nvim_win_get_cursor(0)[2] or 0
  local last = body
  local special = require("org.special")
  local buf
  buf = special.open({
    source_buf = bufnr,
    start_line = el.start,
    end_line = el.finish,
    lines = body,
    filetype = "text",
    name = "table",
    kind = "table.el",
    to_source = function(new)
      local aligned, err = M.realign(new, last)
      if not aligned then
        utils.error(err)
        return nil
      end
      last = aligned
      if buf and not vim.deep_equal(aligned, new) then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, aligned)
      end
      local out = {}
      for i, l in ipairs(aligned) do
        out[i] = indent .. l
      end
      return out
    end,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    buffer = buf,
    callback = function()
      local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local aligned = M.realign(cur, last)
      if aligned then
        last = aligned
        if not vim.deep_equal(aligned, cur) then
          local pos = vim.api.nvim_win_get_cursor(0)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, aligned)
          pos[1] = math.min(pos[1], #aligned)
          pcall(vim.api.nvim_win_set_cursor, 0, pos)
        end
      end
    end,
  })
  if vim.api.nvim_get_current_buf() == buf then
    pcall(vim.api.nvim_win_set_cursor, 0, { lnum - el.start + 1, math.max(0, col - #indent) })
  end
  return true
end

--- The message Emacs gives for TAB and C-c C-c in a table.el table.
function M.hint()
  utils.notify("Use C-c ' to edit table.el tables")
  return true
end

return M
