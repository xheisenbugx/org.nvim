---@mod org.table.tblfm Table formula commands
---
--- Recalculation with the #+TBLFM line (C-c *, C-c C-c), reading and
--- storing formulas (C-c =, inline `=` formulas), the formula debugger,
--- field info (C-c ?), recalculation marks (C-#) and coordinate overlays
--- (C-c }). The formula engine itself is org.table.formula.
---
--- Part of org.table, which loads it.

local utils = require("org.utils")
local shared = require("org.table.shared")

local M = require("org.table")

local current_field = shared.current_field
local cursor_pos = shared.cursor_pos
local dline = shared.dline
local in_visual = shared.in_visual
local is_table_line = shared.is_table_line
local is_tblfm = shared.is_tblfm
local pad_rows = shared.pad_rows
local pipe_positions = shared.pipe_positions
local reload = shared.reload
local restore_cursor = shared.restore_cursor
local set_cursor = shared.set_cursor
local write_table = shared.write_table

---------------------------------------------------------------------------
-- Formulas
---------------------------------------------------------------------------

--- Formulas of the first #+TBLFM line (the active one, like Emacs; the
--- other lines are alternatives applied with <C-c><C-c> on them).
---@param line? integer read this #+TBLFM line instead
local function read_formulas(bufnr, info, line)
  local l = line or info.tblfm[1]
  if not l then
    return ""
  end
  local text = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]
  return text:match("^%s*#%+[Tt][Bb][Ll][Ff][Mm]:%s*(.-)%s*$") or ""
end

--- Constants for `$name` in formulas: the global option, overridden by the
--- buffer's `#+CONSTANTS: name=value ...` lines.
local function formula_constants(bufnr)
  local out = vim.deepcopy(require("org.config").opts.table_formula_constants or {})
  local constants = require("org.files").get_buffer(bufnr).settings.keywords.CONSTANTS or {}
  for _, body in ipairs(constants) do
    for k, v in body:gmatch("([%a_][%w_]*)=(%S+)") do
      out[k] = v
    end
  end
  for k, v in pairs(out) do
    out[k] = tostring(v)
  end
  return out
end

--- Formula debugging (Emacs org-table-formula-debug, toggled by C-c {).
M.formula_debug = false

--- Show one step of the formula debugger (Emacs *Substitution History*)
--- and ask whether to go on. Returns false to abort.
local function debug_step(trace)
  local lines = {
    "Substitution history of formula",
    "Orig:   " .. tostring(trace.orig),
    "$xyz->  " .. tostring(trace.orig),
    "@r$c->  " .. tostring(trace.form or ""),
    "$1->    " .. tostring(trace.form or ""),
  }
  if trace.error then
    lines[#lines + 1] = "Error:  " .. tostring(trace.error)
  else
    lines[#lines + 1] = "Result: " .. tostring(trace.result or "")
    lines[#lines + 1] = "Format: " .. tostring(trace.format or "NONE")
    lines[#lines + 1] = "Final:  " .. tostring(trace.final or "")
  end
  M.debug_history = lines
  local buf = vim.fn.bufnr("*Substitution History*")
  if buf < 0 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "*Substitution History*")
    vim.bo[buf].bufhidden = "wipe"
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local win = vim.fn.bufwinid(buf)
  if win < 0 then
    local cur = vim.api.nvim_get_current_win()
    vim.cmd("botright " .. #lines .. "split")
    vim.api.nvim_win_set_buf(0, buf)
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(cur)
  end
  vim.cmd("redraw")
  local go_on = utils.confirm("Debugging Formula.  Continue to next?")
  if vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  return go_on
end

--- Recalculate the table at the cursor (or at `lnum`) with its first
--- #+TBLFM line. Options: `line` recalculates only the column formulas of
--- that buffer line (Emacs C-c * without prefix; field formulas always
--- run), `tblfm_line` uses the formulas of that #+TBLFM line instead
--- (org-table-calc-current-TBLFM).
---@param opts? { line?: integer, tblfm_line?: integer }
function M.recalc(bufnr, lnum, opts)
  bufnr = (type(bufnr) == "number" and bufnr) or 0
  opts = type(opts) == "table" and opts or {}
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local info = M.find(bufnr, lnum)
  if not info then
    return false
  end
  local row
  if opts.line and opts.line >= info.start and opts.line <= info.finish then
    local t = M.parse(info.lines)
    if not t.rows[opts.line - info.start + 1].hline then
      row = dline(t, opts.line - info.start + 1)
    end
  end
  local lines = M.recalc_lines(bufnr, info.lines, read_formulas(bufnr, info, opts.tblfm_line), info.start, {
    row = row,
    only_row = opts.line ~= nil,
  })
  if not vim.deep_equal(lines, info.lines) then
    vim.api.nvim_buf_set_lines(bufnr, info.start - 1, info.finish, false, lines)
  end
  return true
end

--- Recalculate the current row (C-c *), the whole table (count 4, C-u
--- C-c *) or iterate the table until it is stable (count 16, C-u C-u C-c
--- *). Emacs org-table-recalculate.
function M.recalculate(count)
  count = count or vim.v.count
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local info = M.find(0, lnum)
  if not info then
    utils.warn("Not at a table")
    return false
  end
  local row, field = cursor_pos(info)
  if count >= 16 then
    M.iterate(0, lnum)
  elseif count >= 4 then
    M.recalc(0, lnum)
  else
    M.recalc(0, lnum, { line = lnum })
  end
  restore_cursor(info.start, row, field)
end

--- Recalculate the table until it does not change any more, at most `n`
--- (10) times. Emacs org-table-iterate.
function M.iterate(bufnr, lnum, n)
  bufnr = (type(bufnr) == "number" and bufnr) or 0
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  n = n or 10
  local info = M.find(bufnr, lnum)
  if not info then
    return false
  end
  local last = info.lines
  for i = 1, n do
    M.recalc(bufnr, info.start)
    local now = M.find(bufnr, info.start).lines
    if vim.deep_equal(now, last) then
      utils.notify(i > 1 and ("Convergence after " .. i .. " iterations") or "Table was already stable")
      return true
    end
    last = now
  end
  utils.warn("No convergence after " .. n .. " iterations")
  return false
end

--- Apply the formulas of the #+TBLFM line at `lnum` (not only the first
--- one) to its table. Emacs org-table-calc-current-TBLFM (C-c C-c on a
--- #+TBLFM line).
function M.calc_current_tblfm(bufnr, lnum)
  bufnr = (type(bufnr) == "number" and bufnr) or 0
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  if not is_tblfm(line) then
    utils.warn("Not at a #+TBLFM line")
    return false
  end
  local ok = M.recalc(bufnr, lnum, { tblfm_line = lnum })
  if ok then
    require("org.table.orgtbl").maybe_send(bufnr, lnum)
  end
  return ok
end

--- Apply formulas to table `lines` and return the aligned result. `tblfm`
--- is the formula string or a list of `#+TBLFM:` lines (only the first one
--- is used, like Emacs); `lnum` locates the table in `bufnr` (for $PROP_
--- lookups). `opts.row` limits column formulas to that data row.
---@param tblfm string|string[]
---@param opts? { row?: integer, only_row?: boolean }
function M.recalc_lines(bufnr, lines, tblfm, lnum, opts)
  opts = opts or {}
  if type(tblfm) == "table" then
    tblfm = tblfm[1] and tblfm[1]:match("^%s*#%+[Tt][Bb][Ll][Ff][Mm]:%s*(.-)%s*$") or ""
  end
  local t = M.parse(lines)
  pad_rows(t)
  if tblfm ~= "" then
    local formula = require("org.table.formula")
    local ok, err = pcall(formula.apply, t, formula.parse_tblfm(tblfm), {
      bufnr = bufnr,
      row = opts.row or (opts.only_row and 0) or nil,
      get_table = function(name)
        return M.find_named_table(bufnr, name)
      end,
      constants = formula_constants(bufnr),
      property = function(name)
        local hl = require("org.files").get_buffer(bufnr):headline_at(lnum)
        return hl and hl:get_property(name, true)
      end,
      debug = M.formula_debug and debug_step or nil,
    })
    if not ok then
      if err ~= "Abort" then
        utils.error("Table formula error: " .. tostring(err))
      end
    end
    pad_rows(t)
  end
  return M.render(t)
end

--- Toggle the formula debugger: while on, every formula evaluation shows
--- its substitution steps and asks whether to go on. Emacs C-c {
--- (org-table-toggle-formula-debugger).
function M.toggle_formula_debugger()
  M.formula_debug = not M.formula_debug
  utils.notify("Formula debugging has been turned " .. (M.formula_debug and "on" or "off"))
  return M.formula_debug
end

--- Edit the formulas of the table at the cursor (or of the #+TBLFM line
--- at the cursor) in the formula editor, see |org-table-formula-editor|.
--- Emacs C-c ' (org-table-edit-formulas).
function M.edit_formulas()
  return require("org.table.fedit").open()
end

--- Rows (list of list of strings) of the table named `name` (#+NAME:).
--- Hlines are skipped. When `keep_header` is false and the first row is
--- followed by an hline, that header row is dropped (org-babel behaviour).
function M.get_named_table(bufnr, name, keep_header)
  local t = M.find_named_table(bufnr, name)
  if not t then
    return nil
  end
  local rows = {}
  local drop_header = not keep_header and #t.rows > 2 and not t.rows[1].hline and t.rows[2].hline
  for idx, r in ipairs(t.rows) do
    if not r.hline and not (drop_header and idx == 1) then
      rows[#rows + 1] = vim.deepcopy(r.cells)
    end
  end
  return rows
end

--- The parsed table (hlines included) after `#+NAME: name`, or nil.
function M.find_named_table(bufnr, name)
  bufnr = bufnr or 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    local n = line:match("^%s*#%+[Nn][Aa][Mm][Ee]:%s*(.-)%s*$")
    if n and n == name then
      local j = i + 1
      while lines[j] and lines[j]:match("^%s*#%+") do
        j = j + 1
      end
      if lines[j] and is_table_line(lines[j]) then
        local tl = {}
        while lines[j] and is_table_line(lines[j]) do
          tl[#tl + 1] = lines[j]
          j = j + 1
        end
        local t = M.parse(tl)
        pad_rows(t)
        return t
      end
      return nil
    end
  end
  return nil
end

--- Render rows (list of lists) as aligned table lines.
---@param rows (string[]|string)[] use the string "hline" for separators
function M.rows_to_lines(rows, indent)
  local t = { indent = indent or "", rows = {}, ncols = 1 }
  for _, r in ipairs(rows) do
    if r == "hline" then
      t.rows[#t.rows + 1] = { hline = true }
    else
      local cells = {}
      for i, v in ipairs(r) do
        cells[i] = tostring(v):gsub("\n", " "):gsub("|", "\\vert{}")
      end
      t.rows[#t.rows + 1] = { cells = cells }
      t.ncols = math.max(t.ncols, #cells)
    end
  end
  pad_rows(t)
  return M.render(t)
end

---------------------------------------------------------------------------
-- Field commands (Emacs C-c =, C-c `, C-c +, C-c SPC, C-c ?, regions ...)
---------------------------------------------------------------------------

--- Emacs-style column letter (A, B, ..., Z, AA, ...) for column `c`.
local function col_letter(c)
  local s = ""
  while c > 0 do
    local r = (c - 1) % 26
    s = string.char(65 + r) .. s
    c = math.floor((c - 1) / 26)
  end
  return s
end

--- Individual `lhs=rhs` formulas of the first #+TBLFM line (or of line
--- `line`), verbatim.
local function formula_parts(bufnr, info, line)
  local parts = {}
  for part in (read_formulas(bufnr, info, line) .. "::"):gmatch("(.-)::") do
    part = vim.trim(part)
    if part ~= "" then
      parts[#parts + 1] = part
    end
  end
  return parts
end
M.formula_parts = formula_parts

--- Index of the formula whose target is exactly `lhs`, or nil.
local function find_formula(parts, lhs)
  for i, p in ipairs(parts) do
    if vim.trim(p:match("^(.-)=") or "") == lhs then
      return i
    end
  end
end

--- Sort key of a formula's left side (Emacs
--- org-table-formula-make-cmp-string): `$<`/`$>` last, numbers padded.
local function formula_cmp_string(lhs)
  local arrows = lhs:match("^%$([<>]+)$")
  if arrows then
    return string.format("$%05d", 10000 + (arrows:sub(1, 1) == "<" and -1000 or 0) + #arrows)
  end
  local row = lhs:match("^@(%d+)")
  local rest = row and lhs:sub(#row + 2) or lhs
  local col = rest:match("^%$?(%d+)")
  rest = col and rest:sub(#rest:match("^%$?%d+") + 1) or rest
  local name = rest:match("^(%$?[%w]+)")
  if not row and not col and not name then
    return nil
  end
  return (row and string.format("@%05d", tonumber(row)) or "")
    .. (col and string.format("$%05d", tonumber(col)) or "")
    .. (name and ("@@" .. name) or "")
end

--- Sort formulas like Emacs stores them (org-table-formula-less-p; stable).
function M.sort_formulas(parts)
  local keyed = {}
  for i, p in ipairs(parts) do
    keyed[i] = { p = p, k = formula_cmp_string(vim.trim(p:match("^(.-)=") or "")), i = i }
  end
  table.sort(keyed, function(a, b)
    if a.k and b.k and a.k ~= b.k then
      return a.k < b.k
    end
    return a.i < b.i
  end)
  local out = {}
  for i, e in ipairs(keyed) do
    out[i] = e.p
  end
  return out
end

--- Store `parts` in the first #+TBLFM line of table `info` (or in line
--- `line`), sorted and as `lhs=rhs`, like Emacs org-table-store-formulas.
--- Other #+TBLFM lines are left alone.
local function write_formulas(bufnr, info, parts, line)
  local indent = info.lines[1]:match("^(%s*)")
  local norm = {}
  for i, p in ipairs(M.sort_formulas(parts)) do
    local lhs, rhs = p:match("^(.-)%s*=%s*(.-)%s*$")
    norm[i] = lhs and (vim.trim(lhs) .. "=" .. rhs) or p
  end
  local l = line or info.tblfm[1]
  if l then
    local old = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]
    local prefix = old:match("^(%s*#%+[Tt][Bb][Ll][Ff][Mm]:)") or (indent .. "#+TBLFM:")
    vim.api.nvim_buf_set_lines(bufnr, l - 1, l, false, { prefix .. " " .. table.concat(norm, "::") })
  elseif #norm > 0 then
    local line_text = indent .. "#+TBLFM: " .. table.concat(norm, "::")
    vim.api.nvim_buf_set_lines(bufnr, info.finish, info.finish, false, { line_text })
  end
end
M._write_formulas = write_formulas

--- Convert A1-style references (`B3`, `C&`) to `@3$2` / `$3` (Emacs
--- org-table-convert-refs-to-rc).
function M.refs_to_rc(s)
  local function col(letters)
    local n = 0
    for i = 1, #letters do
      n = n * 26 + (letters:upper():byte(i) - 64)
    end
    return n
  end
  local out, i = {}, 1
  while i <= #s do
    local pre = i == 1 and "" or s:sub(i - 1, i - 1)
    local letters, digits = s:match("^(%a%a?)(%d+)", i)
    local after = letters and s:sub(i + #letters + #digits, i + #letters + #digits) or ""
    if letters and not pre:match("[%w_@$]") and not after:match("[%w_]") then
      out[#out + 1] = "@" .. digits .. "$" .. col(letters)
      i = i + #letters + #digits
    else
      local amp = s:match("^(%a%a?)&", i)
      if amp and not pre:match("[%w_@$]") then
        out[#out + 1] = "$" .. col(amp)
        i = i + #amp + 1
      else
        out[#out + 1] = s:sub(i, i)
        i = i + 1
      end
    end
  end
  return table.concat(out)
end

--- Convert `@3$2` references to `B3` (Emacs org-table-convert-refs-to-an).
function M.refs_to_an(s)
  return (
    s:gsub("@(%d+)%$(%d+)", function(r, c)
      return col_letter(tonumber(c)) .. r
    end):gsub("%$(%d+)", function(c)
      return col_letter(tonumber(c)) .. "&"
    end)
  )
end

--- A formula typed by the user, with A1-style references converted when
--- `table_use_standard_references` allows it (org-table-formula-from-user).
local function formula_from_user(s)
  if require("org.config").opts.table_use_standard_references then
    return M.refs_to_rc(s)
  end
  return s
end

--- Name of the field at data row `dl`, column `c` (a `^`/`_` name), or nil.
local function field_name(t, dl, c)
  local formula = require("org.table.formula")
  local m = formula._model(t)
  formula._collect_names(m)
  for name, pos in pairs(m.names.fields) do
    if pos[1] == dl and pos[2] == c then
      return name
    end
  end
end

--- The formula applying to data row `dl`, column `c`: its left side,
--- right side and whether it is a field formula.
local function field_formula_of(t, parts, dl, c, row)
  local name = field_name(t, dl, c)
  for _, lhs in ipairs({ name or false, "@" .. dl .. "$" .. c }) do
    local idx = lhs and find_formula(parts, lhs)
    if idx then
      return lhs, parts[idx]:match("^.-=%s*(.*)$"), true
    end
  end
  -- column formulas apply below the first hline (or to all rows)
  local first_hline = 0
  for i, r in ipairs(t.rows) do
    if r.hline and i > 1 then
      first_hline = i
      break
    end
  end
  if row > first_hline then
    local idx = find_formula(parts, "$" .. c)
    if idx then
      return "$" .. c, parts[idx]:match("^.-=%s*(.*)$"), false
    end
  end
end

--- Evaluate formula `eq` (`rhs;flags`) for one field of the table at the
--- cursor and write the result there (Emacs evaluates only the current
--- field; C-c * recalculates the rest).
local function eval_one(info, row, field, eq)
  local formula = require("org.table.formula")
  local t = info.tbl
  local f = formula.parse_tblfm("@" .. dline(t, row) .. "$" .. field .. "=" .. eq)
  if #f == 0 then
    return
  end
  local ok, err = pcall(formula.apply, t, f, {
    bufnr = 0,
    get_table = function(name)
      return M.find_named_table(0, name)
    end,
    constants = formula_constants(0),
    property = function(name)
      local hl = require("org.files").get_buffer(0):headline_at(info.start)
      return hl and hl:get_property(name, true)
    end,
    debug = M.formula_debug and debug_step or nil,
    -- a single evaluation (C-c =, an inline formula) substitutes names only
    -- with table_formula_use_constants (org-table-formula-use-constants)
    no_names = require("org.config").opts.table_formula_use_constants == false,
  })
  if not ok and err ~= "Abort" then
    utils.error("Table formula error: " .. tostring(err))
  end
  pad_rows(t)
  write_table(info, t)
end

--- Read and store the formula of the current column (a field formula with
--- `field_formula`, or count 4: C-u C-c =) and compute the current field
--- with it. An empty formula removes it. Count 16 (C-u C-u C-c =) puts
--- the formula of the field into the field as `=...` / `:=...` for
--- editing. Setting a column formula removes the field's own formula.
--- Emacs `C-c =` (org-table-eval-formula).
---@param field_formula? boolean
function M.eval_formula(field_formula)
  local info, row, field = current_field()
  if not info then
    return false
  end
  local t = info.tbl
  if t.rows[row].hline then
    utils.warn("Not in a table data field")
    return
  end
  local count = vim.v.count
  local dl = dline(t, row)
  local parts = formula_parts(0, info)
  if count >= 16 and field_formula == nil then
    local _, rhs, is_field = field_formula_of(t, parts, dl, field, row)
    if not rhs then
      utils.warn("No formula active for the current field")
      return
    end
    t.rows[row].cells[field] = (is_field and ":=" or "=") .. rhs
    local lines = write_table(info, t)
    set_cursor(info, lines, row, field, 0)
    return
  end
  if field_formula == nil then
    field_formula = count > 0
  end
  local name = field_name(t, dl, field)
  local ref = "@" .. dl .. "$" .. field
  local lhs = field_formula and (name or ref) or ("$" .. field)
  local idx = find_formula(parts, lhs)
  local default = idx and parts[idx]:match("^.-=%s*(.*)$") or ""
  local to_user = require("org.config").opts.table_use_standard_references == true and M.refs_to_an
    or function(s)
      return s
    end
  local rhs = utils.input({
    prompt = to_user((field_formula and "Field" or "Column") .. " formula " .. lhs .. "="),
    default = to_user(default),
  })
  if rhs == nil then
    return
  end
  rhs = vim.trim(formula_from_user(rhs)):gsub("^=%s*", "")
  if rhs == "" then
    if idx then
      table.remove(parts, idx)
      write_formulas(0, info, parts)
    end
    utils.notify("Formula removed")
    return
  end
  if idx then
    parts[idx] = lhs .. "=" .. rhs
  else
    parts[#parts + 1] = lhs .. "=" .. rhs
  end
  if not field_formula then
    -- the column formula replaces the field's own formula
    local own = find_formula(parts, name or ref)
    if own then
      table.remove(parts, own)
    end
  end
  write_formulas(0, info, parts)
  info = reload(info)
  eval_one(info, row, field, rhs)
  restore_cursor(info.start, row, field)
end

--- When field `field` of row `row` holds `=formula` (or `:=formula`),
--- install it as the column (or field) formula in #+TBLFM and compute the
--- field. Emacs org-table-maybe-eval-formula (typing a formula into a
--- field and pressing <Tab>, <CR> or C-c C-c).
---@return boolean installed
local function maybe_eval_formula(info, row, field)
  local t = info.tbl
  local r = t.rows[row]
  if not r or r.hline or require("org.config").opts.table_formula_evaluate_inline == false then
    return false
  end
  local named, rhs = vim.trim(r.cells[field] or ""):match("^(:?)=(.*[^=])$")
  if not rhs then
    return false
  end
  local dl = dline(t, row)
  local lhs = named == ":" and (field_name(t, dl, field) or ("@" .. dl .. "$" .. field)) or ("$" .. field)
  rhs = vim.trim(formula_from_user(rhs))
  r.cells[field] = ""
  write_table(info, t)
  local parts = formula_parts(0, info)
  local idx = find_formula(parts, lhs)
  parts[idx or (#parts + 1)] = lhs .. "=" .. rhs
  if named ~= ":" then
    -- the column formula replaces the field's own formula
    -- (org-table-get-formula)
    local own = find_formula(parts, field_name(t, dl, field) or ("@" .. dl .. "$" .. field))
    if own then
      table.remove(parts, own)
    end
  end
  write_formulas(0, info, parts)
  info = reload(info)
  eval_one(info, row, field, rhs)
  return true
end

--- Recalculate row `row` when it is marked with `#` in its first column.
--- Emacs org-table-maybe-recalculate-line.
local function maybe_recalc_line(info, row)
  local r = info.tbl.rows[row]
  if require("org.config").opts.table_allow_automatic_line_recalculation == false then
    return false
  end
  if r and not r.hline and vim.trim(r.cells[1] or "") == "#" and #info.tblfm > 0 then
    M.recalc(0, info.start, { line = info.start + row - 1 })
    return true
  end
  return false
end

--- Run before <Tab>/<S-Tab>/<CR>/C-c RET/C-c C-c: evaluate an inline
--- formula and auto-recalculate `#` rows. Returns fresh table info.
local function before_move(info, row, field, no_formula)
  if (not no_formula and maybe_eval_formula(info, row, field)) or maybe_recalc_line(info, row) then
    return reload(info)
  end
  return info
end

--- C-c C-c in a table: install an inline `=`/`:=` formula, then with a
--- count recalculate (4: the table, 16: iterate), else recalculate a
--- `#`-marked row, else realign (org-ctrl-c-ctrl-c).
function M.ctrl_c_ctrl_c()
  local info = M.at_cursor()
  if not info then
    return false
  end
  local row, field, offset = cursor_pos(info)
  local count = vim.v.count
  if count > 0 then
    maybe_eval_formula(info, row, field)
    M.recalculate(count)
    return
  end
  info = before_move(info, row, field)
  local lines = write_table(info, info.tbl)
  set_cursor(info, lines, row, math.min(field, info.tbl.ncols), offset)
end

--- The active formula of the current field as `$2=...` / `@3$2=...`, or
--- nil. Emacs org-table-current-field-formula.
function M.current_field_formula()
  local info, row, field = current_field()
  if not info or info.tbl.rows[row].hline then
    return nil
  end
  local lhs, rhs = field_formula_of(info.tbl, formula_parts(0, info), dline(info.tbl, row), field, row)
  return lhs and (lhs .. "=" .. rhs) or nil
end

--- Show the reference of the current field and the formula applying to
--- it. Emacs `C-c ?` (org-table-field-info).
function M.field_info()
  local info, row, field = current_field()
  if not info then
    return false
  end
  local t = info.tbl
  if t.rows[row].hline then
    utils.notify("Not in a table data field")
    return
  end
  local dl = dline(t, row)
  local ref = "@" .. dl .. "$" .. field
  local msg = string.format("line @%d, col $%d, ref %s or %s%d", dl, field, ref, col_letter(field), dl)
  local parts = formula_parts(0, info)
  local idx = find_formula(parts, ref)
  if not idx then
    -- column formulas apply below the first hline (or to all rows without one)
    local first_hline = 0
    for i, r in ipairs(t.rows) do
      if r.hline and i > 1 then
        first_hline = i
        break
      end
    end
    if row > first_hline then
      idx = find_formula(parts, "$" .. field)
    end
  end
  if idx then
    msg = msg .. ", formula: " .. parts[idx]
  end
  utils.notify(msg)
  return msg
end

--- Recalculation marks, in rotation order (Emacs org-recalc-marks).
local RECALC_MARKS = { " ", "#", "*", "!", "$", "_", "^" }
local MARK_HELP = {
  [" "] = "Unmarked: no special line, no automatic recalculation",
  ["#"] = "Automatically recalculate this line upon TAB, RET, and C-c C-c in the line",
  ["*"] = "Recalculate only when entire table is recalculated with C-u C-c *",
  ["!"] = "Column name definition line. Reference in formula as $name.",
  ["$"] = "Parameter definition line name=value. Reference in formula as $name.",
  ["_"] = "Names for values in row below this one.",
  ["^"] = "Names for values in row above this one.",
}

--- Rotate the recalculation mark (` # * ! $ _ ^`) in the first column of
--- the current row (or set `mark` on every row of the visual selection,
--- after prompting). A marker column is inserted when the table has none.
--- Emacs C-# (org-table-rotate-recalc-marks).
---@param mark? string
function M.rotate_recalc_marks(mark)
  local visual = in_visual()
  local srow, erow
  if visual then
    local s, _, e = utils.visual_range()
    srow, erow = s, e
    utils.exit_visual()
  end
  local info, row, field = current_field()
  if not info then
    return false
  end
  local t = info.tbl
  if t.rows[row].hline then
    utils.warn("Not at a table data line")
    return
  end
  if visual and not mark then
    mark = utils.getchar("Change region to what mark?  Type # * ! $ or SPC: ")
    if not mark then
      return
    end
  end
  if mark and not MARK_HELP[mark] then
    utils.warn("Invalid recalculation mark: " .. mark)
    return
  end
  local has_marks = true
  for _, r in ipairs(t.rows) do
    if not r.hline and not MARK_HELP[r.cells[1] == "" and " " or r.cells[1]] then
      has_marks = false
      break
    end
  end
  if not has_marks then
    for _, r in ipairs(t.rows) do
      if not r.hline then
        table.insert(r.cells, 1, "")
      end
    end
    t.ncols = t.ncols + 1
    field = field + 1
  end
  local new = mark
  if not new then
    local current = t.rows[row].cells[1]
    current = current == "" and " " or current
    if not has_marks or not MARK_HELP[current] then
      new = "#"
    else
      for i, m in ipairs(RECALC_MARKS) do
        if m == current then
          new = RECALC_MARKS[i % #RECALC_MARKS + 1]
        end
      end
    end
  end
  local r1, r2 = row, row
  if visual then
    r1 = math.max(srow, info.start) - info.start + 1
    r2 = math.min(erow, info.finish) - info.start + 1
  end
  for r = r1, r2 do
    if not t.rows[r].hline then
      t.rows[r].cells[1] = new == " " and "" or new
    end
  end
  local lines = write_table(info, t)
  set_cursor(info, lines, row, field, 0)
  utils.notify(MARK_HELP[new])
  return new
end

---------------------------------------------------------------------------
-- Coordinate overlays (Emacs C-c })
---------------------------------------------------------------------------

local coord_ns = vim.api.nvim_create_namespace("org.table.coordinates")

--- Toggle virtual text showing row (`@N`) and column (`$N`) references on
--- the table at the cursor. Emacs `C-c }`
--- (org-table-toggle-coordinate-overlays).
function M.toggle_coordinate_overlays()
  local bufnr = vim.api.nvim_get_current_buf()
  if #vim.api.nvim_buf_get_extmarks(bufnr, coord_ns, 0, -1, { limit = 1 }) > 0 then
    vim.api.nvim_buf_clear_namespace(bufnr, coord_ns, 0, -1)
    return
  end
  local info = M.at_cursor()
  if not info then
    return false
  end
  local t = info.tbl
  local n = 0
  for i, r in ipairs(t.rows) do
    local lnum = info.start + i - 1
    if not r.hline then
      n = n + 1
      vim.api.nvim_buf_set_extmark(bufnr, coord_ns, lnum - 1, 0, {
        virt_text = { { "@" .. n, "OrgTableFormula" } },
        virt_text_pos = "eol",
      })
    end
  end
  -- column labels above the first row, each over its field
  local line = info.lines[1]
  local pipes = pipe_positions(line)
  local label = ""
  -- (measured on the displayed row: a concealed link is narrower)
  local o = require("org.ui").conceal_opts(bufnr)
  for c = 1, t.ncols do
    local p = pipes[c]
    if not p then
      break
    end
    local col = vim.fn.strdisplaywidth(require("org.ui").visible_text(line:sub(1, p), o)) + 1
    local text = "$" .. c
    label = label .. string.rep(" ", math.max(col - vim.fn.strdisplaywidth(label), c > 1 and 1 or 0)) .. text
  end
  vim.api.nvim_buf_set_extmark(bufnr, coord_ns, info.start - 1, 0, {
    virt_lines = { { { label, "OrgTableFormula" } } },
    virt_lines_above = true,
  })
end

--- Recalculate every table with #+TBLFM formulas in the buffer, iterating
--- until the results are stable (at most 10 passes). Emacs `C-u C-u C-c *`
--- (org-table-iterate-buffer-tables).
function M.recalc_buffer(bufnr)
  bufnr = (type(bufnr) == "number" and bufnr) or 0
  for _ = 1, 10 do
    local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local l = 1
    while l <= vim.api.nvim_buf_line_count(bufnr) do
      local line = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]
      local info = is_table_line(line) and M.find(bufnr, l)
      if info then
        if #info.tblfm > 0 then
          M.recalc(bufnr, l)
          info = M.find(bufnr, l)
        end
        l = (info.tblfm[#info.tblfm] or info.finish) + 1
      else
        l = l + 1
      end
    end
    if vim.deep_equal(before, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) then
      return
    end
  end
  utils.warn("Table formulas did not converge after 10 iterations")
end

shared.before_move = before_move
shared.maybe_recalc_line = maybe_recalc_line
