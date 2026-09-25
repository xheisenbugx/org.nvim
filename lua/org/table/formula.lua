---@mod org.table.formula Spreadsheet formulas (#+TBLFM)
---
--- Formulas are evaluated like Emacs `org-table-eval-formula`: references
--- are replaced by the field text (`(3)`, `[1,2,3]`, `nan` for kept empty
--- fields), and the result is computed by a small GNU Calc
--- (`org.table.calc`) or, for `'(...)` formulas, by the Emacs Lisp subset
--- in `org.table.elisp`.
---
---   column formulas      $3=$1*$2            (rows below the first hline)
---   field formulas       @2$3=..., @>$2=vsum(@I..@II)
---   range targets        @2$3..@4$3=...
---   references           @N$M  $M  @N  @< @> $< $>  @-1 $+1  @0 $0
---                        @I @II @-I (hlines, with +N/-N offsets)
---   ranges               @2$1..@4$1  $1..$3  @I..@II
---   counters             @# (row) $# (column)
---   names                $name: `!` row column names, `^`/`_` field names,
---                        `$` row parameters, #+CONSTANTS, $PROP_x properties,
---                        and (extension) header-row column names
---   remote references    remote(name, @2$1)
---   Lisp formulas        '(+ $1 $2) - Emacs Lisp subset (org.table.elisp)
---   Lua formulas         '(expr) that is not Lisp (extension) - references
---                        substituted as Lua strings (numbers with the N flag)
---   mode flags           ;%.2f  ;%.1f%%  ;p20 n3 f2 s3 e3 (Calc modes)  ;R ;D
---                        ;F (fractions) ;N (numbers) ;E (keep empty)
---                        ;L (Lisp literal) ;T ;t ;U (durations)

local M = {}

--- Split a TBLFM string into formula records.
---@return { lhs: string, rhs: string, flags: string }[]
function M.parse_tblfm(str)
  local out = {}
  for part in (str .. "::"):gmatch("(.-)::") do
    part = vim.trim(part)
    if part ~= "" then
      local lhs, rhs = part:match("^(.-)%s*=%s*(.*)$")
      if lhs then
        local flags = ""
        local body, f = rhs:match("^(.*);([^;]*)$")
        if body and not f:find("[%(%)'\"]") then
          rhs, flags = body, f
        end
        out[#out + 1] = { lhs = vim.trim(lhs), rhs = vim.trim(rhs), flags = flags }
      end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Emacs number/string conversions
---------------------------------------------------------------------------

--- Emacs `string-to-number`: the leading number of `s` (0 when none) and
--- whether it is a float.
---@return number, boolean
function M.string_to_number(s)
  s = (s or ""):gsub("^[ \t\n]+", "")
  local sign, rest = s:match("^([-+]?)(.*)$")
  local int = rest:match("^%d*")
  local frac = rest:sub(#int + 1):match("^%.(%d+)")
  local after = rest:sub(#int + 1 + (frac and #frac + 1 or 0))
  if int == "" and not frac then
    return 0, false
  end
  local exp = (int ~= "" or frac) and after:match("^[eE]([-+]?%d+)")
  local isfloat = frac ~= nil or exp ~= nil
  local v = tonumber((int ~= "" and int or "0") .. (frac and ("." .. frac) or "") .. (exp and ("e" .. exp) or ""))
  if sign == "-" then
    v = -v
  end
  return v, isfloat
end

--- Emacs `number-to-string`.
function M.number_to_string(v, isfloat)
  if not isfloat and v == math.floor(v) and math.abs(v) < 2 ^ 63 then
    return string.format("%d", v)
  end
  if v ~= v then
    return "0.0e+NaN"
  elseif v == math.huge or v == -math.huge then
    return (v < 0 and "-" or "") .. "1.0e+INF"
  end
  local s
  for p = 15, 17 do
    s = string.format("%." .. p .. "g", v)
    if tonumber(s) == v then
      break
    end
  end
  if not s:find("[.e]") then
    s = s .. ".0"
  end
  return s
end

local s2n, n2s = M.string_to_number, M.number_to_string

--- Emacs `org-table-time-string-to-seconds`: H:MM:SS or H:MM as seconds
--- (the first one anywhere in the string; H:MM not inside a timestamp),
--- else the number in the string. "" stays "".
function M.time_string_to_seconds(s)
  if s == "" then
    return s
  end
  local neg, h, mi, se = s:match("(%-?)(%d+):(%d+):(%d+)")
  local res
  if h then
    res = tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(se)
  elseif not s:match("[<%[]%d%d%d%d%-%d%d%-%d%d") then
    neg, h, mi = s:match("(%-?)(%d+):(%d+)")
    if h then
      res = tonumber(h) * 3600 + tonumber(mi) * 60
    end
  end
  if res then
    return string.format("%d", neg == "-" and -res or res)
  end
  return n2s(s2n(s))
end

--- Emacs `org-table-time-seconds-to-string`. `format` is nil (H:MM:SS),
--- "hh:mm", or a custom format "days" / "hours" / "minutes" / "seconds".
function M.seconds_to_string(secs, format)
  local s0 = math.abs(secs)
  local opts = require("org.config").opts
  local pad = opts.table_duration_hour_zero_padding ~= false
  local res
  if format == "days" then
    res = string.format("%.3f", s0 / 86400)
  elseif format == "hours" then
    res = string.format("%.2f", s0 / 3600)
  elseif format == "minutes" then
    res = string.format("%.1f", s0 / 60)
  elseif format == "seconds" then
    res = string.format("%d", math.floor(s0))
  else
    local total = math.floor(s0)
    local h, mi, se = math.floor(total / 3600), math.floor(total % 3600 / 60), total % 60
    res = string.format(pad and "%02d:%02d:%02d" or "%d:%02d:%02d", h, mi, se)
    if format == "hh:mm" then
      res = res:sub(1, -4)
    end
  end
  return secs < 0 and "-" .. res or res
end

--- Emacs `(format fmt number)` for a formula format: integer directives
--- truncate floats, `%s` prints the number like Emacs.
function M.format_number(fmt, v, isfloat)
  local out, i, used = {}, 1, false
  while i <= #fmt do
    local a, b = fmt:find("%%[%-%+ #0]*%d*%.?%d*[a-zA-Z%%]", i)
    if not a then
      out[#out + 1] = fmt:sub(i)
      break
    end
    out[#out + 1] = fmt:sub(i, a - 1)
    local spec = fmt:sub(a, b)
    local conv = spec:sub(-1)
    if conv == "%" then
      out[#out + 1] = "%"
    elseif used then
      error("Not enough arguments for format string")
    else
      used = true
      if conv == "d" or conv == "i" or conv == "x" or conv == "X" or conv == "o" or conv == "c" then
        local n = v < 0 and math.ceil(v) or math.floor(v)
        out[#out + 1] = string.format(spec:gsub("i$", "d"), n)
      elseif conv == "s" or conv == "S" then
        out[#out + 1] = string.format(spec:sub(1, -2) .. "s", n2s(v, isfloat))
      elseif conv:match("[feEgG]") then
        out[#out + 1] = string.format(spec, v)
      else
        error("Invalid format operation %" .. conv)
      end
    end
    i = b + 1
  end
  return table.concat(out)
end

---------------------------------------------------------------------------
-- Table model
---------------------------------------------------------------------------

--- Build a grid view: data rows and hline positions.
local function model(t)
  local m = { data = {}, hlines = {}, ncols = t.ncols, special = {} }
  for _, row in ipairs(t.rows) do
    if row.hline then
      if #m.data > 0 then -- a hline above the first row does not count
        m.hlines[#m.hlines + 1] = #m.data -- data rows before this hline
      end
    else
      m.data[#m.data + 1] = row.cells
    end
  end
  return m
end

local function is_name(s)
  return s and s:match("^[%a_][%w_]*$") ~= nil
end

--- Collect names from the marking column (Emacs `org-table-analyze`):
--- `!` names columns, `^`/`_` name the fields above/below, `$` rows hold
--- `name=value` parameters. As an extension, when no `!` row exists the
--- header row (above the first hline) names columns too. Named fields
--- also keep their value from before the recalculation (Emacs substitutes
--- that value in formulas, so it is only updated by another pass).
local function collect_names(m)
  local cols, fields, params, header = {}, {}, {}, {}
  for r, row in ipairs(m.data) do
    local mark = vim.trim(row[1] or "")
    if mark == "!" or mark == "^" or mark == "_" or mark == "$" or mark == "/" then
      m.special[r] = true
    end
    if mark == "!" or mark == "^" or mark == "_" or mark == "$" then
      for c = 2, m.ncols do
        local v = vim.trim(row[c] or "")
        if mark == "!" and is_name(v) then
          cols[v] = c
        elseif mark == "^" and is_name(v) and r > 1 then
          fields[v] = { r - 1, c }
          params[v] = m.data[r - 1][c] or ""
        elseif mark == "_" and is_name(v) and r < #m.data then
          fields[v] = { r + 1, c }
          params[v] = m.data[r + 1][c] or ""
        elseif mark == "$" then
          local k, val = v:match("^([%a_][%w_]*)%s*=%s*(.-)$")
          if k then
            params[k] = val
          end
        end
      end
    end
  end
  if (m.hlines[1] or 0) > 0 then
    for c, v in ipairs(m.data[1]) do
      v = vim.trim(v)
      if is_name(v) and header[v] == nil then
        header[v] = c
      end
    end
  end
  m.names = { cols = cols, fields = fields, params = params, header = header }
end

---------------------------------------------------------------------------
-- Reference parsing
---------------------------------------------------------------------------

--- Parse a reference at position i of s. Returns spec, next index.
--- spec = { row = {kind, ...}|nil, col = {kind, ...}|nil }
local function parse_ref(s, i)
  local spec = {}
  local j = i
  if s:sub(j, j) == "@" then
    local rest = s:sub(j + 1)
    local m
    m = rest:match("^(%-?I+[%+%-]%d+)") or rest:match("^(%-?I+)")
    if m then
      local neg = m:sub(1, 1) == "-"
      local is = m:match("I+")
      local off = tonumber(m:match("I+([%+%-]%d+)$") or "0")
      spec.row = { kind = "hline", n = #is, relative = neg, offset = off }
    else
      m = rest:match("^(<+)") or rest:match("^(>+)")
      if m then
        spec.row = { kind = m:sub(1, 1) == "<" and "first" or "last", n = #m }
      else
        m = rest:match("^(#)")
        if m then
          spec.row = { kind = "counter" }
        else
          m = rest:match("^([%+%-]%d+)")
          if m then
            spec.row = { kind = "rel", n = tonumber(m) }
          else
            m = rest:match("^(%d+)")
            if m then
              spec.row = { kind = "abs", n = tonumber(m) }
            end
          end
        end
      end
    end
    if not m then
      return nil
    end
    j = j + 1 + #m
  end
  if s:sub(j, j) == "$" and not spec.row then
    local name = s:sub(j + 1):match("^([%a_][%w_]*)")
    if name then
      return { name = name }, j + 1 + #name
    end
  end
  if s:sub(j, j) == "$" then
    local rest = s:sub(j + 1)
    local m = rest:match("^(<+)") or rest:match("^(>+)")
    if m then
      spec.col = { kind = m:sub(1, 1) == "<" and "first" or "last", n = #m }
    else
      m = rest:match("^(#)")
      if m then
        spec.col = { kind = "counter" }
      else
        m = rest:match("^([%+%-]%d+)")
        if m then
          spec.col = { kind = "rel", n = tonumber(m) }
        else
          m = rest:match("^(%d+)")
          if m then
            spec.col = { kind = "abs", n = tonumber(m) }
          end
        end
      end
    end
    if not m then
      if spec.row then
        return spec, j
      end
      return nil
    end
    j = j + 1 + #m
  end
  if not spec.row and not spec.col then
    return nil
  end
  return spec, j
end
M.parse_ref = parse_ref

--- Resolve a row spec to a data row index.
---@param pos "single"|"start"|"end"
local function resolve_row(m, spec, r, pos)
  if not spec then
    return r
  end
  local n = #m.data
  if spec.kind == "abs" then
    return spec.n == 0 and r or spec.n
  elseif spec.kind == "rel" then
    return r + spec.n
  elseif spec.kind == "first" then
    return spec.n
  elseif spec.kind == "last" then
    return n - spec.n + 1
  elseif spec.kind == "hline" then
    local a
    if spec.relative then
      local above = {}
      for _, h in ipairs(m.hlines) do
        if h < r then
          above[#above + 1] = h
        end
      end
      a = above[#above - spec.n + 1]
    else
      a = m.hlines[spec.n]
    end
    if not a then
      error("no hline " .. string.rep("I", spec.n))
    end
    local off = spec.offset or 0
    if off == 0 then
      return pos == "end" and a or a + 1
    elseif off > 0 then
      return a + off
    end
    return a + off + 1
  end
  error("bad row reference")
end

local function resolve_col(m, spec, c)
  if not spec then
    return c
  end
  if spec.kind == "abs" then
    return spec.n == 0 and c or spec.n
  elseif spec.kind == "rel" then
    return c + spec.n
  elseif spec.kind == "first" then
    return spec.n or 1
  elseif spec.kind == "last" then
    return m.ncols - (spec.n or 1) + 1
  end
  error("bad column reference")
end

--- Turn a `$name` spec into a plain reference spec, or return the named
--- value (a string) for parameters, named fields (their value before the
--- recalculation), constants and properties. On a formula's left side
--- (`lhs`), a named field is its location.
local function resolve_name(m, spec, ctx, lhs)
  if not spec or not spec.name then
    return spec
  end
  local name, names = spec.name, m.names
  if names.cols[name] then
    return { col = { kind = "abs", n = names.cols[name] } }
  end
  local f = names.fields[name]
  if f and lhs then
    return { row = { kind = "abs", n = f[1] }, col = { kind = "abs", n = f[2] } }
  end
  local v = names.params[name] or (ctx.constants or {})[name]
  if v == nil and name:match("^PROP_.") and ctx.property then
    v = ctx.property(name:sub(6))
  end
  if v ~= nil then
    return nil, v
  end
  if names.header[name] then
    return { col = { kind = "abs", n = names.header[name] } }
  end
  error("unknown name: $" .. name)
end

---------------------------------------------------------------------------
-- Flags
---------------------------------------------------------------------------

--- Parse the mode string after `;` like Emacs: Calc modes `p20 n3 f2 s3
--- e3` and the letters `tTUNLEDRFSu` are removed wherever they are, and
--- what is left (e.g. `%.1f%%`) is the printf format.
function M.parse_flags(str)
  local f = { raw = str, deg = true }
  local fmt = str or ""
  while true do
    local a, b, c, n = fmt:find("([pnfse])(%-?%d+)")
    if not a then
      break
    end
    n = tonumber(n)
    if c == "p" then
      f.prec = n
    elseif c == "n" then
      f.float_format = { "float", n }
    elseif c == "f" then
      f.float_format = { "fix", n }
    elseif c == "s" then
      f.float_format = { "sci", n }
    elseif c == "e" then
      f.float_format = { "eng", n }
    end
    fmt = fmt:sub(1, a - 1) .. fmt:sub(b + 1)
  end
  fmt = fmt:gsub("[tTUNLEDRFSu]", function(ch)
    if ch == "t" or ch == "T" or ch == "U" then
      f.duration, f.numbers = true, true
      if ch == "t" then
        f.duration_format = require("org.config").opts.table_duration_custom_format or "hours"
      else
        f.duration_format = ch == "U" and "hh:mm" or nil
      end
    elseif ch == "N" then
      f.numbers = true
    elseif ch == "D" or ch == "R" then
      f.deg = ch == "D"
    elseif ch == "F" then
      f.frac = true
    end
    f[ch] = true
    return ""
  end)
  f.format = fmt:find("%S") and fmt or nil
  return f
end
local parse_flags = M.parse_flags

---------------------------------------------------------------------------
-- Lua formulas (extension)
---------------------------------------------------------------------------

--- Convert a cell string into a Lua formula value.
local function cell_value(s, flags)
  s = s or ""
  if flags.N then
    return tonumber(s) or 0
  end
  return s
end

local function lua_literal(v)
  if type(v) == "number" then
    if v ~= v then
      return "(0/0)"
    elseif v == math.huge then
      return "math.huge"
    elseif v == -math.huge then
      return "(-math.huge)"
    end
    return string.format("%.17g", v)
  elseif type(v) == "table" then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = lua_literal(x)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return string.format("%q", tostring(v))
end

local function lua_env()
  local env = {}
  env.math, env.string, env.table, env.os = math, string, table, { date = os.date, time = os.time }
  env.tonumber, env.tostring, env.type = tonumber, tostring, type
  env.ipairs, env.pairs, env.select, env.unpack = ipairs, pairs, select, unpack
  env.concat = function(t, sep)
    return table.concat(t, sep or "")
  end
  return env
end

local function lua_result(v)
  if type(v) == "table" then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = lua_result(x)
    end
    return table.concat(parts, " ")
  elseif type(v) == "boolean" then
    return v and "1" or "0"
  elseif type(v) == "number" then
    if v ~= v then
      return "#ERROR"
    elseif v == math.floor(v) and math.abs(v) < 2 ^ 53 then
      return string.format("%d", v)
    end
    return (string.format("%.8g", v):gsub("e%+?(%-?)0*(%d)", "e%1%2"))
  elseif v == nil then
    return ""
  end
  return tostring(v)
end

---------------------------------------------------------------------------
-- Substitution
---------------------------------------------------------------------------

--- Model of the table named `name` (for remote references).
local function remote_model(ctx, name)
  local rt = ctx.get_table and ctx.get_table(name)
  if not rt then
    error("unknown remote table: " .. name)
  end
  local rm = model(rt)
  collect_names(rm)
  return rm
end

--- The reference or range at position i of s, evaluated in model `m` at
--- (r, c). Returns kind ("counter", "named", "field" or "range"), the
--- value (a string, or a list of strings for ranges; a number for
--- counters) and the next index.
local function read_ref(m, s, i, r, c, ctx)
  local spec, j = parse_ref(s, i)
  if not spec then
    error("bad reference near: " .. s:sub(i, i + 5))
  end
  local named
  spec, named = resolve_name(m, spec, ctx)
  if named then
    return "named", named, j
  end
  if spec.row and spec.row.kind == "counter" and not spec.col then
    return "counter", r, j
  elseif spec.col and spec.col.kind == "counter" and not spec.row then
    return "counter", c, j
  end
  local spec2
  if s:sub(j, j + 1) == ".." then
    spec2, j = parse_ref(s, j + 2)
    spec2 = resolve_name(m, spec2, ctx)
    if not spec2 then
      error("bad range")
    end
  end
  if not spec2 then
    local rr = resolve_row(m, spec.row, r, "single")
    local cc = resolve_col(m, spec.col, c)
    local row = m.data[rr]
    if not row or cc < 1 or cc > m.ncols then
      error("reference out of range")
    end
    return "field", row[cc] or "", j
  end
  local r1 = resolve_row(m, spec.row, r, "start")
  local r2 = resolve_row(m, spec2.row, r, "end")
  local c1 = resolve_col(m, spec.col, c)
  local c2 = resolve_col(m, spec2.col, c)
  if r1 > r2 then
    r1, r2 = r2, r1
  end
  if c1 > c2 then
    c1, c2 = c2, c1
  end
  local vals = {}
  for rr = r1, r2 do
    local row = m.data[rr]
    if not row then
      error("row out of range: " .. rr)
    end
    for cc = c1, c2 do
      if cc < 1 or cc > m.ncols then
        error("reference out of range")
      end
      vals[#vals + 1] = row[cc] or ""
    end
  end
  return "range", vals, j
end

--- Emacs `org-table-make-reference`: the text a field (string) or range
--- (list) becomes in a Calc (`lisp` false) or Lisp formula.
local function make_reference(elements, keep_empty, numbers, lisp)
  local function lisp_item(x)
    if lisp == "literal" then
      return x
    elseif numbers then
      return n2s(s2n(x))
    end
    return '"' .. x:gsub('[\\"]', "\\%0") .. '"'
  end
  if type(elements) == "string" then
    if lisp then
      return lisp_item(elements)
    end
    if elements:find("%S") then
      return "(" .. (numbers and n2s(s2n(elements)) or elements) .. ")"
    end
    return (not keep_empty or numbers) and "(0)" or "nan"
  end
  local items = {}
  for _, x in ipairs(elements) do
    if keep_empty or x:find("%S") then
      items[#items + 1] = x
    end
  end
  local parts = {}
  for i, x in ipairs(items) do
    if lisp then
      parts[i] = lisp_item(x)
    elseif x:find("%S") then
      parts[i] = numbers and n2s(s2n(x)) or x
    else
      parts[i] = (not keep_empty or numbers) and "0" or "nan"
    end
  end
  if lisp then
    return table.concat(parts, " ")
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

--- Text of a reference value in the formula language `mode`.
local function reference_text(kind, v, mode, fl)
  if kind == "counter" then
    return string.format("%d", v)
  end
  if mode == "lua" then
    if kind == "range" then
      local vals = {}
      for _, x in ipairs(v) do
        if x ~= "" or fl.E then
          vals[#vals + 1] = cell_value(x, fl)
        end
      end
      return lua_literal(vals)
    end
    return lua_literal(cell_value(v, fl))
  end
  local lisp = mode == "elisp" and (fl.L and "literal" or true) or false
  if fl.duration then
    if kind == "range" then
      local out = {}
      for i, x in ipairs(v) do
        out[i] = M.time_string_to_seconds(x)
      end
      v = out
    else
      v = M.time_string_to_seconds(v)
    end
  end
  if kind == "named" then
    -- constants are wrapped in parentheses in Calc formulas
    return lisp and v or ("(" .. v .. ")")
  end
  return make_reference(v, fl.E, fl.numbers, lisp)
end

--- Substitute references in `rhs` for evaluation at (r, c). Returns the
--- formula text and the text after `$name` substitution (for the debugger).
---@param mode "calc"|"lua"|"elisp"
local function substitute(m, rhs, r, c, flags, mode, ctx)
  local out = {}
  local i, n = 1, #rhs
  local in_str = nil
  while i <= n do
    local ch = rhs:sub(i, i)
    if in_str then
      out[#out + 1] = ch
      if ch == "\\" then
        out[#out + 1] = rhs:sub(i + 1, i + 1)
        i = i + 1
      elseif ch == in_str then
        in_str = nil
      end
      i = i + 1
    elseif ch == '"' then
      in_str = ch
      out[#out + 1] = ch
      i = i + 1
    elseif rhs:match("^remote%(", i) then
      local name, ref, j = rhs:match("^remote%(%s*([^,%s]+)%s*,%s*([^%)]-)%s*%)()", i)
      if not name then
        error("bad remote reference")
      end
      local rm = remote_model(ctx, name)
      local kind, v, k = read_ref(rm, ref, 1, r, c, {})
      if k <= #ref then
        error("bad remote reference: " .. ref)
      end
      out[#out + 1] = reference_text(kind, v, mode, flags)
      i = j
    elseif ch == "@" or ch == "$" then
      local kind, v, j = read_ref(m, rhs, i, r, c, ctx)
      out[#out + 1] = reference_text(kind, v, mode, flags)
      i = j
    else
      out[#out + 1] = ch
      i = i + 1
    end
  end
  return table.concat(out)
end

---------------------------------------------------------------------------
-- Evaluation
---------------------------------------------------------------------------

local function inactive_timestamps(s)
  return (s:gsub("<(%d%d%d%d%-%d%d%-%d%d[^>\n]*)>", "[%1]"))
end

--- Evaluate a formula RHS for field (r, c). Returns the field text and an
--- error message (or nil). `trace`, when given, receives the steps for the
--- formula debugger (Emacs *Substitution History*).
function M.evaluate(m, rhs, flags, r, c, ctx, trace)
  ctx = ctx or {}
  trace = trace or {}
  trace.orig = rhs
  local mode, body = "calc", rhs
  if rhs:sub(1, 1) == "'" then
    body = rhs:sub(2)
    local has_elisp, elisp = pcall(require, "org.table.elisp")
    mode = (has_elisp and elisp.looks_like(body)) and "elisp" or "lua"
  end
  local ok, expr = pcall(substitute, m, body, r, c, flags, mode, ctx)
  if not ok then
    trace.error = expr
    return "#ERROR", expr
  end
  trace.form = expr
  if mode == "lua" then
    local env = lua_env()
    local chunk, err = load("return " .. expr, "tblfm", "t", env)
    if not chunk then
      return "#ERROR", err
    end
    local ok2, v = pcall(chunk)
    if not ok2 then
      return "#ERROR", v
    end
    if type(v) == "number" and flags.format then
      local okf, s = pcall(M.format_number, flags.format, v, v ~= math.floor(v))
      if okf then
        return s
      end
    end
    return lua_result(v)
  end
  local ev, err
  local fmt = flags.format
  if mode == "elisp" then
    local elisp = require("org.table.elisp")
    local ok2, v = pcall(elisp.eval, expr)
    if not ok2 then
      ev, err = "#ERROR", v
    elseif elisp.is_cons(v) then
      trace.result = elisp.to_string(v)
      return "#ERROR", "the Lisp formula returned a list"
    else
      local n = elisp.tonumber(v)
      ev = n and n2s(n, elisp.is_float(v)) or elisp.to_string(v)
    end
    if flags.duration then
      ev = M.seconds_to_string(s2n(ev), flags.duration_format)
    end
  else
    expr = expr:gsub("%[(%d%d%d%d%-%d%d%-%d%d[^%]\n]*)%]", "<%1>")
    -- `date(<$1>)`: a timestamp field inside a date form
    expr = expr:gsub("<%((<%d%d%d%d%-%d%d%-%d%d[^>\n]*>)%)>", "%1")
    trace.form = expr
    if flags.duration and expr:match("^%d+:%d+$") or expr:match("^%d+:%d+:%d+$") and flags.duration then
      ev = expr
    else
      local calc = require("org.table.calc")
      local ok2, v = pcall(calc.eval, expr, {
        prec = flags.prec,
        float_format = flags.float_format,
        deg = flags.deg,
        frac = flags.frac,
        num = flags.numbers and not flags.E,
      })
      if not ok2 then
        trace.error = v
        return "#ERROR", v
      end
      ev = v
    end
    if flags.duration and ev ~= "" then
      local secs
      if ev:match("^%d+:%d+$") or ev:match("^%d+:%d+:%d+$") then
        secs = tonumber(M.time_string_to_seconds(ev))
      else
        secs = s2n(ev)
      end
      ev = M.seconds_to_string(secs, flags.duration_format)
    end
  end
  trace.result = ev
  trace.format = fmt
  if fmt then
    local n, isfloat = s2n(ev)
    local okf, s = pcall(M.format_number, fmt, n, isfloat)
    if okf then
      ev = s
    else
      err = s
      ev = "#ERROR"
    end
  else
    ev = inactive_timestamps(ev)
  end
  trace.final = ev
  return ev, err
end

--- Parse a formula LHS into a list of target fields {r, c}, and whether it
--- is a column formula.
local function targets(m, lhs, ctx)
  local spec, j = parse_ref(lhs, 1)
  spec = resolve_name(m, spec, ctx, true)
  if not spec then
    error("bad formula target: " .. lhs)
  end
  local spec2
  if lhs:sub(j, j + 1) == ".." then
    spec2, j = parse_ref(lhs, j + 2)
    spec2 = resolve_name(m, spec2, ctx, true)
  end
  if j <= #lhs then
    error("bad formula target: " .. lhs)
  end
  local out = {}
  if not spec2 and spec.col and not spec.row then
    return { col = resolve_col(m, spec.col, 1) }, true
  end
  if spec2 then
    local r1 = resolve_row(m, spec.row, 1, "start")
    local r2 = resolve_row(m, spec2.row, 1, "end")
    local c1 = resolve_col(m, spec.col, 1)
    local c2 = resolve_col(m, spec2.col, 1)
    for r = math.min(r1, r2), math.max(r1, r2) do
      for c = math.min(c1, c2), math.max(c1, c2) do
        out[#out + 1] = { r, c }
      end
    end
    return out, false
  end
  local r = resolve_row(m, spec.row, 1, "single")
  local c = resolve_col(m, spec.col, 1)
  out[1] = { r, c }
  return out, false
end

--- Add empty columns up to `n` (a formula writing beyond the table).
local function add_columns(t, m, n)
  if n > 1000 then
    error("Formula column target too large")
  end
  for _, row in ipairs(m.data) do
    for c = #row + 1, n do
      row[c] = ""
    end
  end
  m.ncols = math.max(m.ncols, n)
  t.ncols = m.ncols
end

--- Whether a field formula may add columns up to `n`
--- (`table_formula_create_columns`, Emacs org-table-formula-create-columns).
local function may_create_columns(ctx)
  local opt = require("org.config").opts.table_formula_create_columns
  if opt == true then
    return true
  elseif opt == "warn" then
    require("org.utils").warn("Out-of-bounds formula added columns")
    return true
  elseif opt == "prompt" then
    if ctx.confirm then
      return ctx.confirm("Out-of-bounds formula.  Add columns?")
    end
    return require("org.utils").confirm("Out-of-bounds formula.  Add columns?")
  end
  return false
end

--- Apply formulas to parsed table `t` in place.
---@param t table from org.table.parse
---@param formulas table from parse_tblfm
---@param ctx? table { get_table = fun(name), constants = table, property = fun(name), row = integer,
---   debug = fun(trace): boolean }
---   `row` (a data row index) recalculates only the column formulas of that
---   row (Emacs C-c * without prefix); field formulas always run. `debug`
---   is called after each evaluation and returns false to abort.
---@return string[] errors
function M.apply(t, formulas, ctx)
  ctx = ctx or {}
  local m = model(t)
  m.ncols = t.ncols
  collect_names(m)
  local errors = {}
  local column, field = {}, {}
  -- like Emacs, formulas run in the order of their sorted left sides
  local sorted = {}
  for i, f in ipairs(formulas) do
    sorted[i] = { f = f, i = i }
  end
  table.sort(sorted, function(a, b)
    if a.f.lhs ~= b.f.lhs then
      return a.f.lhs < b.f.lhs
    end
    return a.i < b.i
  end)
  for _, s in ipairs(sorted) do
    local f = s.f
    local ok, tg, is_col = pcall(targets, m, f.lhs, ctx)
    if not ok then
      errors[#errors + 1] = tg
    elseif is_col then
      column[#column + 1] = { f = f, col = tg.col }
    else
      field[#field + 1] = { f = f, targets = tg }
    end
  end
  -- fields that have explicit field formulas are not touched by column formulas
  local overridden = {}
  for _, ff in ipairs(field) do
    for _, tg in ipairs(ff.targets) do
      overridden[tg[1] .. ":" .. tg[2]] = true
    end
  end
  -- Rows the column formulas apply to (org-table-recalculate): with marks
  -- (`! $ ^ _ # *` in the first column) only `#` and `*` rows, else the
  -- rows below the first hline (all rows without an hline); `_ ^ ! $ /`
  -- rows are never changed.
  local rows = {}
  if ctx.row then
    rows[1] = ctx.row
  else
    local marked = false
    for _, row in ipairs(m.data) do
      if vim.trim(row[1] or ""):match("^[!%$%^_#%*]$") then
        marked = true
      end
    end
    local first = (not marked and m.hlines[1] and m.hlines[1] > 0) and m.hlines[1] + 1 or 1
    for r = first, #m.data do
      local mark = vim.trim(m.data[r][1] or "")
      if not marked or mark == "#" or mark == "*" then
        rows[#rows + 1] = r
      end
    end
  end
  local aborted = false
  local function eval(entry, r, c)
    if aborted or not m.data[r] or c < 1 then
      return
    end
    entry.flags = entry.flags or parse_flags(entry.f.flags or "")
    local trace = { lhs = entry.f.lhs, row = r, col = c }
    local v, err = M.evaluate(m, entry.f.rhs, entry.flags, r, c, ctx, trace)
    if err then
      errors[#errors + 1] = err
    end
    m.data[r][c] = vim.trim(v)
    if ctx.debug and ctx.debug(trace) == false then
      aborted = true
    end
  end
  -- like Emacs: row by row, every column formula in order; then field formulas
  for _, r in ipairs(rows) do
    if not m.special[r] then
      for _, e in ipairs(column) do
        if e.col > m.ncols then
          add_columns(t, m, e.col)
        end
        if not overridden[r .. ":" .. e.col] then
          eval(e, r, e.col)
        end
      end
    end
  end
  for _, e in ipairs(field) do
    for _, tg in ipairs(e.targets) do
      if tg[2] > m.ncols and m.data[tg[1]] then
        if not may_create_columns(ctx) then
          t.ncols = m.ncols
          error("Missing columns in the table.  Aborting", 0)
        end
        add_columns(t, m, tg[2])
      end
      eval(e, tg[1], tg[2])
    end
  end
  t.ncols = m.ncols
  if aborted then
    error("Abort", 0)
  end
  return errors
end

--- Seconds of an H:MM or H:MM:SS string (nil for anything else).
function M._parse_duration(s)
  local neg = s:sub(1, 1) == "-"
  if neg then
    s = s:sub(2)
  end
  local h, mi, se = s:match("^(%d+):(%d%d):(%d%d)$")
  local v
  if h then
    v = tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(se)
  else
    h, mi = s:match("^(%d+):(%d%d)$")
    if h then
      v = tonumber(h) * 3600 + tonumber(mi) * 60
    end
  end
  if v and neg then
    v = -v
  end
  return v
end

M._model = model
M._collect_names = collect_names

return M
