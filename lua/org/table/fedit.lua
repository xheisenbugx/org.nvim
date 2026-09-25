---@mod org.table.fedit The formula editor (Emacs org-table-edit-formulas)
---
--- C-c ' in a table (or on a #+TBLFM line) opens the formulas of the
--- table's first #+TBLFM line (or of that line) in a split below, one
--- `lhs = rhs` per line under "# Column Formulas", "# Field and Range
--- Formulas" and "# Named Field Formulas". While the cursor moves, the
--- fields the formula refers to are highlighted in the table.
---
--- Keys: <C-c><C-c> <C-c>' <C-c><C-s> <C-x><C-s> or :w finish (with a
--- count also recalculate), <C-c><C-q> abort, <C-c>? show the reference,
--- <S-Up/Down/Left/Right> shift the reference at the cursor, <M-S-Up> /
--- <M-S-Down> change the table row used for column formulas, <M-Up> /
--- <M-Down> scroll the table, <Tab> pretty-print a Lisp formula (lines
--- that start with a blank continue the formula above), <C-c><C-r>
--- toggle A1 references (B3) and <C-c>} the table coordinates.

local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.table.fedit")
local src_ns = vim.api.nvim_create_namespace("org.table.fedit.src")
local anchor_ns = vim.api.nvim_create_namespace("org.table.fedit.anchor")

local function tbl()
  return require("org.table")
end

local function formula()
  return require("org.table.formula")
end

---------------------------------------------------------------------------
-- Buffer contents
---------------------------------------------------------------------------

--- Lines of the editor for formula parts (sorted, with section titles).
function M.editor_lines(parts, an)
  local titles = {
    column = "# Column Formulas",
    field = "# Field and Range Formulas",
    named = "# Named Field Formulas",
  }
  local lines = {}
  for _, p in ipairs(tbl().sort_formulas(parts)) do
    local lhs, rhs = p:match("^(.-)%s*=%s*(.*)$")
    if lhs then
      local kind = (lhs:match("^%$%d+$") or lhs:match("^%$[<>]+$")) and "column"
        or (lhs:sub(1, 1) == "@" and "field" or "named")
      if titles[kind] then
        if #lines > 0 then
          lines[#lines + 1] = ""
        end
        lines[#lines + 1] = titles[kind]
        titles[kind] = nil
      end
      if kind == "named" and lhs:sub(1, 1) ~= "$" then
        lhs = "$" .. lhs
      end
      local line = lhs .. " = " .. rhs
      lines[#lines + 1] = an and tbl().refs_to_an(line) or line
    end
  end
  return lines
end

--- Formula parts from the editor lines (org-table-fedit-finish): comment
--- lines are skipped, indented lines continue the formula above, Lisp
--- whitespace is collapsed and A1 references converted.
function M.parse_lines(lines, an)
  local parts, cur = {}, nil
  local function flush()
    if cur then
      local lhs, rhs = cur:match("^(%S-)%s*=%s*(.-)%s*$")
      if lhs then
        if rhs:sub(1, 2) == "'(" then
          rhs = rhs:gsub("%s+", " "):gsub("%(%s+", "("):gsub("%s+%)", ")")
        end
        local f = lhs .. "=" .. rhs
        if an or require("org.config").opts.table_use_standard_references then
          f = tbl().refs_to_rc(f)
        end
        parts[#parts + 1] = f
      end
    end
    cur = nil
  end
  for _, l in ipairs(lines) do
    if l:match("^%s*#") or l:match("^%s*$") then
      flush()
    elseif l:match("^%s") and cur then
      cur = cur .. " " .. vim.trim(l)
    else
      flush()
      cur = vim.trim(l)
    end
  end
  flush()
  return parts
end

---------------------------------------------------------------------------
-- Lisp pretty printing
---------------------------------------------------------------------------

local function read_sexp(s, i)
  i = s:find("%S", i) or #s + 1
  local ch = s:sub(i, i)
  if ch == "(" then
    local items = {}
    i = i + 1
    while true do
      local j = s:find("%S", i)
      if not j then
        error("unbalanced")
      end
      if s:sub(j, j) == ")" then
        return { list = items }, j + 1
      end
      local item
      item, i = read_sexp(s, j)
      items[#items + 1] = item
    end
  elseif ch == '"' then
    local j = i + 1
    while j <= #s and s:sub(j, j) ~= '"' do
      j = j + (s:sub(j, j) == "\\" and 2 or 1)
    end
    return s:sub(i, j), j + 1
  elseif ch == "'" then
    local item, j = read_sexp(s, i + 1)
    return { quote = item }, j
  end
  local tok = s:match("^[^%s()]+", i)
  if not tok then
    error("unbalanced")
  end
  return tok, i + #tok
end

local function flat(x)
  if type(x) == "string" then
    return x
  elseif x.quote then
    return "'" .. flat(x.quote)
  end
  local parts = {}
  for i, it in ipairs(x.list) do
    parts[i] = flat(it)
  end
  return "(" .. table.concat(parts, " ") .. ")"
end

--- Pretty-print sexp `x` starting at column `col` (lines, no indent on
--- the first one).
local function pp(x, col, width)
  local f = flat(x)
  if type(x) == "string" or col + #f <= width or (x.list and #x.list <= 1) then
    return { f }
  end
  if x.quote then
    local inner = pp(x.quote, col + 1, width)
    inner[1] = "'" .. inner[1]
    return inner
  end
  local head = flat(x.list[1])
  local lines = {}
  local arg_col = col + 2 + #head
  local first = pp(x.list[2], arg_col, width)
  lines[1] = "(" .. head .. " " .. first[1]
  for k = 2, #first do
    lines[#lines + 1] = first[k]
  end
  for n = 3, #x.list do
    local sub = pp(x.list[n], arg_col, width)
    lines[#lines + 1] = string.rep(" ", arg_col) .. sub[1]
    for k = 2, #sub do
      lines[#lines + 1] = sub[k]
    end
  end
  lines[#lines] = lines[#lines] .. ")"
  return lines
end

--- The formula at editor line `lnum`: its first line and last line.
local function formula_extent(buf, lnum)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local s = lnum
  while s > 1 and lines[s]:match("^%s") and lines[s]:match("%S") do
    s = s - 1
  end
  local e = s
  while lines[e + 1] and lines[e + 1]:match("^%s") and lines[e + 1]:match("%S") do
    e = e + 1
  end
  return s, e, lines
end

--- Pretty-print (or re-indent) the Lisp formula at the cursor
--- (org-table-fedit-lisp-indent).
function M.lisp_indent(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local s, e, lines = formula_extent(buf, lnum)
  local text = {}
  for i = s, e do
    text[#text + 1] = vim.trim(lines[i])
  end
  local joined = table.concat(text, " ")
  local lhs, rhs = joined:match("^(%S+%s*=%s*)'(%(.*)$")
  if not lhs then
    return false
  end
  local ok, sexp = pcall(read_sexp, rhs, 1)
  if not ok then
    utils.warn("Unbalanced parentheses in the Lisp formula")
    return
  end
  local out = pp(sexp, #lhs + 1, 70)
  out[1] = lhs .. "'" .. out[1]
  if e == s and #out == 1 then
    return
  end
  vim.api.nvim_buf_set_lines(buf, s - 1, e, false, out)
end

---------------------------------------------------------------------------
-- Reference display
---------------------------------------------------------------------------

--- Byte range {line, start_col, end_col} (0-based line/cols) of the field
--- at data row `dl`, column `c` of the table starting at `start`.
local function field_range(bufnr, start, dl, c)
  local info = tbl().find(bufnr, start)
  if not info then
    return nil
  end
  local d = 0
  for i, line in ipairs(info.lines) do
    if not line:match("^%s*|%-") then
      d = d + 1
      if d == dl then
        local pipes = {}
        for p in line:gmatch("()|") do
          pipes[#pipes + 1] = p
        end
        if pipes[c] and pipes[c + 1] then
          return { info.start + i - 2, pipes[c], pipes[c + 1] - 1 }
        end
        return nil
      end
    end
  end
end

--- The test row (data row) of the table: the one of the table window's
--- cursor, else the first below the header.
local function test_row(st)
  local info = tbl().find(st.src, st.start())
  if not info then
    return 1
  end
  local t = tbl().parse(info.lines)
  local m = formula()._model(t)
  local lnum = st.twin and vim.api.nvim_win_is_valid(st.twin) and vim.api.nvim_win_get_cursor(st.twin)[1] or 0
  if lnum >= info.start and lnum <= info.finish and not t.rows[lnum - info.start + 1].hline then
    local d = 0
    for i = 1, lnum - info.start + 1 do
      if not t.rows[i].hline then
        d = d + 1
      end
    end
    return d, m, info
  end
  return (m.hlines[1] and m.hlines[1] > 0) and m.hlines[1] + 1 or 1, m, info
end

--- Highlight the fields the formula on the editor's current line refers
--- to (org-table-show-reference). Returns a description.
function M.show_reference(st, move)
  local buf = st.buf
  vim.api.nvim_buf_clear_namespace(st.src, src_ns, 0, -1)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local s, e, lines = formula_extent(buf, lnum)
  local text = {}
  for i = s, e do
    text[#text + 1] = lines[i]
  end
  local f = table.concat(text, " ")
  if st.an then
    f = tbl().refs_to_rc(f)
  end
  local lhs, rhs = f:match("^%s*(%S-)%s*=%s*(.*)$")
  if not lhs then
    return nil
  end
  local r, m, info = test_row(st)
  if not m then
    return nil
  end
  formula()._collect_names(m)
  local col = tonumber(lhs:match("^%$(%d+)$")) or 1
  local ok, tgt = pcall(function()
    local spec = formula().parse_ref(lhs, 1)
    return spec
  end)
  local marks = {}
  local function mark(dl, c, group)
    local rg = field_range(st.src, info.start, dl, c)
    if rg then
      vim.api.nvim_buf_set_extmark(st.src, src_ns, rg[1], rg[2], { end_col = rg[3], hl_group = group })
      marks[#marks + 1] = { dl, c }
    end
  end
  -- the target field(s)
  if ok and tgt and tgt.row then
    local row = tgt.row.kind == "abs" and tgt.row.n or r
    col = tgt.col and tgt.col.kind == "abs" and tgt.col.n or col
    mark(row, col, "OrgTableFormulaTarget")
    r = row
  elseif ok and tgt and tgt.col then
    mark(r, col, "OrgTableFormulaTarget")
  end
  -- references in the right side
  local cursor_col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local line_text = lines[lnum]
  local at_cursor
  local i = 1
  while i <= #rhs do
    local ch = rhs:sub(i, i)
    if ch == "@" or ch == "$" then
      local spec, j = formula().parse_ref(rhs, i)
      if spec and not spec.name then
        local spec2, k
        if rhs:sub(j, j + 1) == ".." then
          spec2, k = formula().parse_ref(rhs, j + 2)
        end
        local okr = pcall(function()
          local function rowof(sp, pos)
            if not sp.row then
              return r
            elseif sp.row.kind == "abs" then
              return sp.row.n == 0 and r or sp.row.n
            elseif sp.row.kind == "rel" then
              return r + sp.row.n
            elseif sp.row.kind == "first" then
              return sp.row.n
            elseif sp.row.kind == "last" then
              return #m.data - sp.row.n + 1
            elseif sp.row.kind == "hline" then
              local a = m.hlines[sp.row.n] or 0
              return pos == "end" and a or a + 1
            end
            return r
          end
          local function colof(sp)
            if not sp.col then
              return col
            elseif sp.col.kind == "abs" then
              return sp.col.n == 0 and col or sp.col.n
            elseif sp.col.kind == "rel" then
              return col + sp.col.n
            elseif sp.col.kind == "first" then
              return sp.col.n
            elseif sp.col.kind == "last" then
              return m.ncols - sp.col.n + 1
            end
            return col
          end
          local r1, c1 = rowof(spec, "start"), colof(spec)
          local r2, c2 = r1, c1
          if spec2 then
            r2, c2 = rowof(spec2, "end"), colof(spec2)
          end
          local ref_text = rhs:sub(i, (spec2 and k or j) - 1)
          local here = line_text:find(ref_text, 1, true)
          local under = here and cursor_col >= here and cursor_col < here + #ref_text
          for rr = math.min(r1, r2), math.max(r1, r2) do
            for cc = math.min(c1, c2), math.max(c1, c2) do
              mark(rr, cc, under and "OrgTableFormulaRefCursor" or "OrgTableFormulaRef")
            end
          end
          if under then
            at_cursor = { r1, c1 }
          end
        end)
        local _ = okr
        i = spec2 and k or j
      else
        i = (j or i) + 1
      end
    else
      i = i + 1
    end
  end
  if move and at_cursor and st.twin and vim.api.nvim_win_is_valid(st.twin) then
    local rg = field_range(st.src, info.start, at_cursor[1], at_cursor[2])
    if rg then
      vim.api.nvim_win_set_cursor(st.twin, { rg[1] + 1, rg[2] + 1 })
    end
  end
  return marks
end

--- Shift the reference at the cursor (org-table-fedit-shift-reference).
---@param dir "up"|"down"|"left"|"right"
function M.shift_reference(dir)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local d = (dir == "up" or dir == "left") and -1 or 1
  local vertical = dir == "up" or dir == "down"
  -- find the reference around the cursor
  local best
  for s, ref, e in line:gmatch("()(@?[-+]?I*[-+]?%d*%$?[-+]?%d*)()") do
    if ref:match("[@$]") and ref:match("%d") and col >= s and col <= e then
      best = { s, ref, e }
    end
  end
  -- A1 references (B3)
  if not best then
    for s, letters, digits, e in line:gmatch("()(%u%u?)(%d+)()") do
      if col >= s and col <= e then
        best = { s, letters .. digits, e, a1 = true }
      end
    end
  end
  if not best then
    utils.warn("No reference at point")
    return false
  end
  local s, ref, e = best[1], best[2], best[3]
  local new
  if best.a1 then
    local letters, digits = ref:match("^(%u+)(%d+)$")
    if vertical then
      new = letters .. math.max(1, tonumber(digits) + d)
    else
      local n = 0
      for k = 1, #letters do
        n = n * 26 + letters:byte(k) - 64
      end
      n = math.max(1, n + d)
      local out = ""
      while n > 0 do
        out = string.char(65 + (n - 1) % 26) .. out
        n = math.floor((n - 1) / 26)
      end
      new = out .. digits
    end
  else
    local row, colpart = ref:match("^(@[^$]*)(.*)$")
    if not row then
      row, colpart = "", ref
    end
    local function bump(part, sigil)
      local sign, n = part:match("^" .. sigil .. "([-+]?)(%d+)$")
      if not n then
        return nil
      end
      local v = tonumber(n)
      if sign == "" then
        return sigil .. math.max(1, v + d)
      end
      local rel = (sign == "-" and -v or v) + d
      if rel == 0 then
        return sigil .. "0"
      end
      return sigil .. (rel > 0 and "+" or "-") .. math.abs(rel)
    end
    if vertical then
      local r = bump(row, "@")
      if not r then
        utils.warn("Cannot shift reference in this direction")
        return false
      end
      new = r .. colpart
    else
      local c = bump(colpart, "%$")
      if not c then
        utils.warn("Cannot shift reference in this direction")
        return false
      end
      new = row .. c:gsub("^%%", "")
    end
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  vim.api.nvim_set_current_line(line:sub(1, s - 1) .. new .. line:sub(e))
  vim.api.nvim_win_set_cursor(0, { lnum, s - 1 })
  return true
end

---------------------------------------------------------------------------
-- The editor
---------------------------------------------------------------------------

--- Open the formula editor for the table at the cursor (or the #+TBLFM
--- line at the cursor). Emacs org-table-edit-formulas.
function M.open()
  local src = vim.api.nvim_get_current_buf()
  local twin = vim.api.nvim_get_current_win()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local info = tbl().find(src, lnum)
  if not info then
    utils.warn("Not at a table")
    return
  end
  local cur_line = vim.api.nvim_get_current_line()
  local tblfm_line = tbl().is_tblfm(cur_line) and lnum or info.tblfm[1]
  local key = not tbl().is_tblfm(cur_line) and tbl().current_field_formula() or nil
  local parts = tbl().formula_parts(src, info, tblfm_line)
  local cfg = require("org.config").opts
  local st = { src = src, twin = twin, an = cfg.table_use_standard_references == true }
  -- anchors in the source: the table start and the #+TBLFM line
  st.table_mark = vim.api.nvim_buf_set_extmark(src, anchor_ns, info.start - 1, 0, { right_gravity = false })
  if tblfm_line then
    st.tblfm_mark = vim.api.nvim_buf_set_extmark(src, anchor_ns, tblfm_line - 1, 0, { right_gravity = false })
  end
  st.start = function()
    return vim.api.nvim_buf_get_extmark_by_id(src, anchor_ns, st.table_mark, {})[1] + 1
  end
  -- when the cursor was in a table, it is the test row
  if tbl().is_tblfm(cur_line) then
    vim.api.nvim_win_set_cursor(0, { info.start, 0 })
  end
  local buf = vim.api.nvim_create_buf(false, true)
  st.buf = buf
  pcall(vim.api.nvim_buf_set_name, buf, "*Edit Formulas*#" .. buf)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  local lines = M.editor_lines(parts, st.an)
  if #lines == 0 then
    lines = { "" }
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].filetype = "orgformulas"
  vim.cmd("botright " .. math.max(math.min(#lines + 2, 15), 5) .. "split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  st.win = win
  -- start on the formula of the current field
  local start_line = 1
  for i, l in ipairs(lines) do
    if key and l:gsub("%s*=%s*", "=", 1) == key then
      start_line = i
      break
    elseif start_line == 1 and not l:match("^#") and l ~= "" then
      start_line = i
    end
  end
  vim.api.nvim_win_set_cursor(win, { start_line, 0 })
  M.state = st

  local closed = false
  local function cleanup()
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_buf_is_valid(src) then
      vim.api.nvim_buf_clear_namespace(src, src_ns, 0, -1)
      vim.api.nvim_buf_clear_namespace(src, anchor_ns, 0, -1)
    end
    M.state = nil
  end
  local function close()
    cleanup()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    if vim.api.nvim_win_is_valid(twin) then
      vim.api.nvim_set_current_win(twin)
    end
  end
  --- Store the formulas in the source #+TBLFM line.
  local function store()
    local new = M.parse_lines(vim.api.nvim_buf_get_lines(buf, 0, -1, false), st.an)
    local start = st.start()
    local tinfo = tbl().find(src, start)
    if not tinfo then
      utils.warn("The table is gone")
      return false
    end
    local line
    if st.tblfm_mark then
      line = vim.api.nvim_buf_get_extmark_by_id(src, anchor_ns, st.tblfm_mark, {})[1] + 1
      if not tbl().is_tblfm(vim.api.nvim_buf_get_lines(src, line - 1, line, false)[1]) then
        line = nil
      end
    end
    tbl()._write_formulas(src, tinfo, new, line)
    if not st.tblfm_mark then
      tinfo = tbl().find(src, start)
      if tinfo.tblfm[1] then
        st.tblfm_mark = vim.api.nvim_buf_set_extmark(src, anchor_ns, tinfo.tblfm[1] - 1, 0, { right_gravity = false })
      end
    end
    vim.bo[buf].modified = false
    return true
  end
  local function finish()
    local apply = vim.v.count > 0
    if not store() then
      return
    end
    local start = st.start()
    close()
    if apply then
      tbl().recalc(src, start)
    end
  end
  st.finish, st.close = finish, close
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = store })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = cleanup })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = buf,
    callback = function()
      pcall(M.show_reference, st, false)
    end,
  })
  local function map(lhs, fn, desc, modes)
    for _, l in ipairs(type(lhs) == "table" and lhs or { lhs }) do
      vim.keymap.set(modes or "n", l, fn, { buffer = buf, nowait = true, desc = "org formulas: " .. desc })
    end
  end
  map({ "<C-c><C-c>", "<C-c>'", "<C-c><C-s>", "<C-x><C-s>" }, finish, "finish (count: and apply)")
  for _, l in ipairs(require("org.config").lhs_list((cfg.mappings.edit_src or {}).save_exit)) do
    map(l, finish, "finish")
  end
  map("<C-c><C-q>", close, "abort")
  for _, l in ipairs(require("org.config").lhs_list((cfg.mappings.edit_src or {}).abort)) do
    map(l, close, "abort")
  end
  map("<C-c>?", function()
    local marks = M.show_reference(st, true)
    utils.notify(marks and (#marks .. " field(s) referenced") or "No formula on this line")
  end, "show reference")
  for _, d in ipairs({ "Up", "Down", "Left", "Right" }) do
    map("<S-" .. d .. ">", function()
      M.shift_reference(d:lower())
      pcall(M.show_reference, st, true)
    end, "shift reference " .. d:lower())
  end
  map("<M-S-Up>", function()
    M.move_test_row(st, -1)
  end, "test row up")
  map("<M-S-Down>", function()
    M.move_test_row(st, 1)
  end, "test row down")
  map("<M-Up>", function()
    M.scroll_table(st, -1)
  end, "scroll table down")
  map("<M-Down>", function()
    M.scroll_table(st, 1)
  end, "scroll table")
  map("<Tab>", function()
    M.lisp_indent(buf)
  end, "pretty-print Lisp formula")
  map("<C-c><C-r>", function()
    M.toggle_ref_type(st)
  end, "toggle A1 references")
  map("<C-c>}", function()
    if vim.api.nvim_win_is_valid(twin) then
      vim.api.nvim_win_call(twin, function()
        tbl().toggle_coordinate_overlays()
      end)
    end
  end, "toggle table coordinates")
  pcall(M.show_reference, st, false)
  utils.notify("Edit formulas, finish with <C-c><C-c> or <C-c>'")
  return buf, st
end

--- Move the table window's cursor to the previous/next data row: the row
--- column formulas are shown for (org-table-fedit-line-up/down).
function M.move_test_row(st, dir)
  if not (st.twin and vim.api.nvim_win_is_valid(st.twin)) then
    return
  end
  local info = tbl().find(st.src, st.start())
  local l = vim.api.nvim_win_get_cursor(st.twin)[1] + dir
  while info and l >= info.start and l <= info.finish do
    local line = vim.api.nvim_buf_get_lines(st.src, l - 1, l, false)[1]
    if not line:match("^%s*|%-") then
      vim.api.nvim_win_set_cursor(st.twin, { l, 1 })
      break
    end
    l = l + dir
  end
  pcall(M.show_reference, st, false)
end

--- Scroll the table window (org-table-fedit-scroll).
function M.scroll_table(st, dir)
  if st.twin and vim.api.nvim_win_is_valid(st.twin) then
    vim.api.nvim_win_call(st.twin, function()
      vim.cmd("normal! " .. vim.keycode(dir > 0 and "<C-e>" or "<C-y>"))
    end)
  end
end

--- Toggle the display of references between @3$2 and B3
--- (org-table-fedit-toggle-ref-type).
function M.toggle_ref_type(st)
  local lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
  for i, l in ipairs(lines) do
    if not l:match("^%s*#") then
      lines[i] = st.an and tbl().refs_to_rc(l) or tbl().refs_to_an(l)
    end
  end
  st.an = not st.an
  local modified = vim.bo[st.buf].modified
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, lines)
  vim.bo[st.buf].modified = modified
  utils.notify(st.an and "Standard references (B3)" or "@row$column references")
end

M.ns = ns
M.src_ns = src_ns

return M
