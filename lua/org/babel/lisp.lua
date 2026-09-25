---@mod org.babel.lisp Emacs Lisp values for Babel results and variables
---
--- Emacs Babel turns what a program prints into Lisp data (numbers,
--- strings, lists, the symbol `hline`) and prints Lisp data back as code or
--- table cells. This module reproduces those conversions so results match
--- Emacs: `org-babel-read`, `org-babel-script-escape`,
--- `org-babel-import-elisp-from-file`, `format "%S"` / `"%s"`.
---
--- Values: strings; integers are Lua numbers; floats are the tagged tables
--- of `org.table.elisp` (so `1.0` stays `1.0`); lists are Lua arrays; the
--- symbol `hline` is the string "hline"; other symbols are their name; an
--- empty list (nil) is `{}`.

local el = require("org.table.elisp")

local M = {}

M.float = el.float
M.is_float = el.is_float

--- Integers too large for a Lua number keep their digits (Emacs bignums).
local Big = {}

function M.bignum(digits)
  return setmetatable({ digits = digits }, Big)
end

function M.is_bignum(v)
  return getmetatable(v) == Big
end

--- Is `v` a list value (a Lua array, not a number)?
function M.is_list(v)
  return type(v) == "table" and not el.is_float(v) and getmetatable(v) ~= Big
end

--- The Lua number of an integer or float value, or nil.
function M.tonumber(v)
  if getmetatable(v) == Big then
    return tonumber(v.digits)
  end
  return el.tonumber(v)
end

--- Emacs `prin1` of a float: the shortest of %.15g..%.17g that reads back,
--- always with a `.` or an exponent.
function M.float_str(x)
  return el.to_string(el.float(x))
end

local function int_str(x)
  if x == math.floor(x) and math.abs(x) < 2 ^ 63 then
    return string.format("%d", x)
  end
  return M.float_str(x)
end

--- Convert a value of the Emacs Lisp evaluator (`org.table.elisp`) to a
--- Babel value.
function M.from_elisp(v)
  if v == nil then
    return {}
  elseif v == true then
    return "t"
  elseif type(v) == "number" or type(v) == "string" or el.is_float(v) then
    return v
  elseif type(v) == "table" then
    if v.n ~= nil and getmetatable(v) == nil then
      local out = {}
      for i = 1, v.n do
        out[i] = M.from_elisp(v[i])
      end
      return out
    elseif v.name then
      return v.name
    end
  end
  return el.to_string(v)
end

--- `format "%S"`: strings quoted, lists in parentheses.
function M.prin1(v)
  if type(v) == "string" then
    return '"' .. v:gsub('[\\"]', "\\%0") .. '"'
  elseif type(v) == "number" then
    return int_str(v)
  elseif el.is_float(v) then
    return M.float_str(v.v)
  elseif getmetatable(v) == Big then
    return v.digits
  elseif type(v) == "table" then
    if #v == 0 then
      return "nil"
    end
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = x == "hline" and "hline" or M.prin1(x)
    end
    return "(" .. table.concat(parts, " ") .. ")"
  elseif v == nil then
    return "nil"
  elseif v == true then
    return "t"
  end
  return tostring(v)
end

--- `format "%s"`: strings as they are, lists in parentheses.
function M.princ(v)
  if type(v) == "string" then
    return v
  elseif M.is_list(v) then
    if #v == 0 then
      return "nil"
    end
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = M.princ(x)
    end
    return "(" .. table.concat(parts, " ") .. ")"
  end
  return M.prin1(v)
end

--- A table cell as `orgtbl-to-orgtbl` writes it: strings as they are,
--- numbers like Emacs, nil as "".
function M.cell(v)
  if v == nil or (M.is_list(v) and #v == 0) then
    return ""
  end
  return M.princ(v)
end

--- Parse a number token like the Emacs reader (`1`, `-2`, `1.`, `1.5`,
--- `.5`, `1e3`), or nil.
local function read_number(tok)
  if tok:match("^0[xX]") or tok:match("^[+-]0[xX]") then
    return nil
  end
  local n = tonumber(tok)
  if not n or not tok:match("^[+-]?%.?%d") then
    return nil
  end
  if tok:match("^[+-]?%d+%.?$") then
    if math.abs(n) >= 2 ^ 53 then
      return M.bignum((tok:gsub("^%+", ""):gsub("%.$", "")))
    end
    return n
  end
  return el.float(n)
end

--- `org-babel--string-to-number`: the number `s` represents, or nil.
function M.string_to_number(s)
  if type(s) ~= "string" then
    return nil
  end
  local t = vim.trim(s)
  if t:match("%s") or not s:match("^[0-9e.+ %-]+$") then
    return nil
  end
  return read_number(t)
end

local function nw(s)
  return type(s) == "string" and s:match("%S") ~= nil
end

--- Evaluate Lisp source with the `org.table.elisp` interpreter and convert
--- the result. Raises an error when it cannot.
function M.eval(src)
  return M.from_elisp(el.eval(src))
end

--- `org-babel-read`: numbers become numbers, `"strings"` are read, Lisp
--- forms (`(...)`, `'...`, `` `... ``, `[...]`) are evaluated unless
--- `inhibit_lisp`; anything else is returned as it is.
function M.read(cell, inhibit_lisp)
  if not nw(cell) then
    return cell
  end
  local n = M.string_to_number(cell)
  if n then
    return n
  end
  local c = cell:sub(1, 1)
  if not inhibit_lisp and (c == "(" or c == "'" or c == "`" or c == "[") then
    local ok, v = pcall(el.eval, cell)
    if ok then
      return M.from_elisp(v)
    end
    -- `read` takes the first form only: 'abc' is the symbol abc
    local sym = cell:match("^'([^%s()\"';`]+)")
    if sym then
      return sym
    end
    error(tostring(v), 0)
  end
  if cell:match('^%s*".*"%s*$') then
    local ok, v = pcall(el.eval, cell)
    if ok and type(v) == "string" then
      return v
    end
  end
  return cell
end

--- `org-babel--script-escape-inner`: turn Python/Ruby/JSON-like data into
--- Lisp syntax (brackets and braces become parentheses, commas spaces,
--- single-quoted strings double-quoted).
local function script_escape_inner(str)
  local in_single, in_double, backslash = false, false, false
  local out = {}
  local function push(s)
    out[#out + 1] = s
  end
  for ch in str:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    if backslash then
      backslash = false
      if in_single and ch == "'" then
        push("'")
      elseif ch == '"' then
        push(in_single and '\\\\\\"' or '\\"')
      elseif ch == "\\" then
        push("\\\\")
      else
        push("\\\\" .. ch)
      end
    elseif ch == "[" or ch == "{" then
      push((in_double or in_single) and ch or "(")
    elseif ch == "]" or ch == "}" then
      push((in_double or in_single) and ch or ")")
    elseif ch == "," then
      push((in_double or in_single) and "," or " ")
    elseif ch == "'" then
      if in_double then
        push("'")
      else
        in_single = not in_single
        push('"')
      end
    elseif ch == '"' then
      if in_single then
        push('\\"')
      else
        in_double = not in_double
        push('"')
      end
    elseif ch == "\\" then
      if not (in_single or in_double) then
        error("Can't handle backslash outside string in `org-babel-script-escape'", 0)
      end
      backslash = true
    else
      push(ch)
    end
  end
  if in_single or in_double then
    error("Unterminated string in `org-babel-script-escape'", 0)
  end
  return table.concat(out)
end

--- `org-babel-script-escape`: read the printed form of a Python/Ruby value
--- as Lisp data. Returns the raw `org.table.elisp` value (so callers can
--- map symbols such as `None` before converting with `from_elisp`), or the
--- string itself when it does not read as data.
function M.script_escape_raw(str, force)
  local escaped
  local first, last = str:sub(1, 1), str:sub(-1)
  local ok, err = pcall(function()
    if
      #str >= 2
      and ((first == "[" and last == "]") or (first == "{" and last == "}") or (first == "(" and last == ")"))
    then
      escaped = "'" .. script_escape_inner(str)
    elseif force or (#str > 2 and ((first == "'" and last == "'") or (first == '"' and last == '"'))) then
      escaped = script_escape_inner(str)
    else
      escaped = str
    end
  end)
  if not ok then
    error(err, 0)
  end
  -- org-babel-read, keeping raw elisp values
  if not nw(escaped) then
    return escaped
  end
  local n = M.string_to_number(escaped)
  if n then
    return n
  end
  local c = escaped:sub(1, 1)
  if c == "(" or c == "'" or c == "`" or c == "[" or escaped:match('^%s*".*"%s*$') then
    local rok, v = pcall(el.eval, escaped)
    if rok then
      return v
    end
  end
  return escaped
end

--- `org-babel-script-escape`, converted to a Babel value.
function M.script_escape(str, force)
  return M.from_elisp(M.script_escape_raw(str, force))
end

--- Is `v` the elisp symbol `name`?
function M.is_symbol(v, name)
  return type(v) == "table" and getmetatable(v) ~= nil and v.name == name
end

--- Is `v` a raw elisp list?
function M.is_elisp_list(v)
  return type(v) == "table" and v.n ~= nil and getmetatable(v) == nil
end

---------------------------------------------------------------------------
-- org-babel-import-elisp-from-file
---------------------------------------------------------------------------

--- Split a CSV line (org-table-convert-region with a comma separator).
local function csv_fields(line)
  local fields, i, n = {}, 1, #line
  while true do
    local s = line:match("^[ \t]*", i)
    i = i + #s
    local field
    if line:sub(i, i) == '"' then
      local j = line:find('"', i + 1, true)
      if j then
        field = line:sub(i + 1, j - 1)
        i = j + 1
        local rest = line:match("^[^,]*", i)
        field = field .. rest
        i = i + #rest
      else
        field = line:match("^[^,]*", i)
        i = i + #field
      end
    else
      field = line:match("^[^,]*", i)
      i = i + #field
    end
    fields[#fields + 1] = field
    if line:sub(i, i) == "," then
      i = i + 1
    else
      break
    end
  end
  return fields
end

--- Cells of a line once it is an Org table row: split at `|`, trimmed.
local function row_cells(line)
  local cells = vim.split(line, "|", { plain = true })
  for i, c in ipairs(cells) do
    cells[i] = vim.trim(c)
  end
  return cells
end

--- `org-babel-string-read`: strip surrounding double quotes, then read
--- numbers (no Lisp evaluation).
function M.string_read(cell)
  local inner = type(cell) == "string" and cell:match('^%s*"(.+)"%s*$')
  return M.read(inner or cell, true)
end

--- Rows of `text` split like `org-table-convert-region` with `separator`
--- (nil = `babel-auto`: tabs, else commas, else runs of spaces except on
--- a single line; a string = a Lua pattern).
function M.text_to_rows(text, separator)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  if #lines == 0 then
    return {}
  end
  local mode = separator
  if mode == nil then
    local all_tab, all_comma = true, true
    for _, l in ipairs(lines) do
      if l ~= "" and not l:find("\t", 1, true) then
        all_tab = false
      end
      if l ~= "" and not l:find(",", 1, true) then
        all_comma = false
      end
    end
    if all_tab then
      mode = "tab"
    elseif all_comma then
      mode = "csv"
    elseif #lines == 1 then
      mode = "none"
    else
      mode = "space"
    end
  end
  local rows = {}
  for _, l in ipairs(lines) do
    local cells
    if mode == "csv" then
      cells = {}
      for _, f in ipairs(csv_fields(l)) do
        vim.list_extend(cells, row_cells(f))
      end
    elseif mode == "tab" then
      cells = {}
      for _, f in ipairs(vim.split(l, "\t", { plain = true })) do
        vim.list_extend(cells, row_cells(f))
      end
    elseif mode == "space" then
      local t = l:gsub("^ *", "")
      cells = {}
      -- " *\t *" and runs of spaces separate fields
      for _, f in ipairs(vim.split(t:gsub(" *\t *", "\1"):gsub(" +", "\1"), "\1", { plain = true })) do
        vim.list_extend(cells, row_cells(f))
      end
    elseif mode == "none" then
      cells = row_cells((l:gsub("^ *", "")))
    else
      cells = {}
      for _, f in ipairs(vim.split(l, separator)) do
        vim.list_extend(cells, row_cells(f))
      end
    end
    -- trailing empty cell of a row ending with a separator stays, like Org
    rows[#rows + 1] = cells
  end
  return rows
end

--- `org-babel-import-elisp-from-file` on `text`: a table (list of rows of
--- read cells), a scalar for a one-cell table, or nil for no text.
function M.import_table(text, separator)
  if text == nil or text == "" then
    return nil
  end
  local rows = M.text_to_rows(text, separator)
  local out = {}
  for _, r in ipairs(rows) do
    local cells = {}
    for i, c in ipairs(r) do
      cells[i] = M.string_read(c)
    end
    out[#out + 1] = cells
  end
  if #out == 1 and #out[1] == 1 then
    return out[1][1]
  end
  return out
end

return M
