---@mod org.table.formula Spreadsheet formulas (#+TBLFM)
---
--- Supported (Emacs org-table subset, evaluated with Lua arithmetic):
---   column formulas      $3=$1*$2            (rows below the first hline)
---   field formulas       @2$3=..., @>$2=vsum(@I..@II)
---   range targets        @2$3..@4$3=...
---   references           @N$M  $M  @N  @< @> $< $>  @-1 $+1  @0 $0
---                        @I @II @-I (hlines, with +N/-N offsets)
---   ranges               @2$1..@4$1  $1..$3  @I..@II
---   counters             @# (row) $# (column)
---   functions            vsum vmean vmin vmax vcount vprod vmedian vsdev vvar
---                        vpvar vpsdev, abs sqrt exp ln log log10 floor ceil
---                        round idiv min max sin cos tan asin acos atan (in
---                        degrees unless ;R) pow mod, if(c,a,b), [1, 2] vectors
---   names                $name: `!` row column names, `^`/`_` field names,
---                        `$` row parameters, #+CONSTANTS, $PROP_x properties,
---                        and (extension) header-row column names
---   remote references    remote(name, @2$1)
---   Lisp formulas        '(+ $1 $2) - Emacs Lisp subset (org.table.elisp)
---   Lua formulas         '(expr) that is not Lisp - references substituted as
---                        Lua strings (numbers with the N flag)
---   format flags         ;%.2f  ;%.1f%%  ;f2 s3 e3 n4 (Calc modes)  ;R ;D
---                        ;N (non-numbers = 0)  ;E (keep empty)  ;L (Lisp literal)
---                        ;T (H:MM:SS)  ;t (decimal hours)  ;U (H:MM)

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
--- header row (above the first hline) names columns too.
local function collect_names(m)
  local cols, fields, params, header = {}, {}, {}, {}
  for r, row in ipairs(m.data) do
    local mark = vim.trim(row[1] or "")
    if mark == "!" or mark == "^" or mark == "_" or mark == "$" then
      m.special[r] = true
      for c = 2, m.ncols do
        local v = vim.trim(row[c] or "")
        if mark == "!" and is_name(v) then
          cols[v] = c
        elseif mark == "^" and is_name(v) and r > 1 then
          fields[v] = { r - 1, c }
        elseif mark == "_" and is_name(v) and r < #m.data then
          fields[v] = { r + 1, c }
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
--- value (a string) for parameters, constants and properties.
local function resolve_name(m, spec, ctx)
  if not spec or not spec.name then
    return spec
  end
  local name, names = spec.name, m.names
  if names.cols[name] then
    return { col = { kind = "abs", n = names.cols[name] } }
  end
  local f = names.fields[name]
  if f then
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
-- Values
---------------------------------------------------------------------------

local function parse_duration(s)
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

local function format_duration(secs, with_seconds)
  local neg = secs < 0
  secs = math.floor(math.abs(secs) + 0.5)
  local h = math.floor(secs / 3600)
  local mi = math.floor((secs % 3600) / 60)
  local se = secs % 60
  local s
  if with_seconds then
    s = string.format("%02d:%02d:%02d", h, mi, se)
  else
    s = string.format("%02d:%02d", h, mi)
  end
  return neg and "-" .. s or s
end

--- Split a mode string into flags, Calc modes (p20 f2 s3 e3 n4) and a
--- printf format. Like Emacs, flag letters are removed and whatever is
--- left (e.g. `%.1f%%`) is the format.
local function parse_flags(flags)
  local f = { raw = flags }
  local fmt, i = {}, 1
  while i <= #flags do
    local spec = flags:match("^%%%%", i) or flags:match("^%%[%-%+ #0]*%d*%.?%d*[dfeEgGsxXoi]", i)
    local mode, n = flags:match("^([pnfse])(%-?%d+)", i)
    if spec then
      if spec ~= "%%" then
        f.format = true
      end
      fmt[#fmt + 1] = spec
      i = i + #spec
    elseif mode then
      f.calc = { mode = mode, n = tonumber(n) }
      i = i + #mode + #n
    else
      local ch = flags:sub(i, i)
      if ch:match("[DRFSLNEtTU]") then
        f[ch] = true
      else
        fmt[#fmt + 1] = ch
      end
      i = i + 1
    end
  end
  if f.format then
    f.format = table.concat(fmt):gsub("%%i", "%%d")
  end
  return f
end

--- Convert a cell string into a formula value.
local function cell_value(s, flags, lisp)
  s = s or ""
  if lisp then
    if flags.N then
      return tonumber(s) or 0
    end
    return s
  end
  if (flags.T or flags.t or flags.U) and s:find(":") then
    -- org-table-time-string-to-seconds: the first H:MM:SS or H:MM anywhere
    -- in the field ("*1d 11:45*" reads 11:45), but not inside a timestamp
    local neg, h, mi, se = s:match("(%-?)(%d+):(%d+):(%d+)")
    if not h and not s:match("%d%d%d%d%-%d%d%-%d%d") then
      neg, h, mi = s:match("(%-?)(%d+):(%d+)")
    end
    if h then
      local v = tonumber(h) * 3600 + tonumber(mi) * 60 + (tonumber(se) or 0)
      return neg == "-" and -v or v
    end
  end
  if s == "" then
    if flags.E and not flags.N then
      return ""
    end
    return 0
  end
  local n = tonumber(s)
  if n then
    return n
  end
  if flags.N then
    return 0
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
    return "__R({" .. table.concat(parts, ",") .. "})"
  end
  return string.format("%q", tostring(v))
end

---------------------------------------------------------------------------
-- Environment
---------------------------------------------------------------------------

local function nums(v)
  if type(v) ~= "table" then
    v = { v }
  end
  local out = {}
  for _, x in ipairs(v) do
    if type(x) == "number" then
      out[#out + 1] = x
    elseif type(x) == "string" and tonumber(x) then
      out[#out + 1] = tonumber(x)
    end
  end
  return out
end

local function make_env(flags)
  flags = flags or {}
  local env = {}
  env.__R = function(t)
    return setmetatable(t, { __org_range = true })
  end
  env.vsum = function(...)
    local s = 0
    for _, a in ipairs({ ... }) do
      for _, x in ipairs(nums(a)) do
        s = s + x
      end
    end
    return s
  end
  env.vcount = function(...)
    local c = 0
    for _, a in ipairs({ ... }) do
      if type(a) == "table" then
        for _, x in ipairs(a) do
          if x ~= "" then
            c = c + 1
          end
        end
      else
        c = c + 1
      end
    end
    return c
  end
  env.vmean = function(...)
    local all = {}
    for _, a in ipairs({ ... }) do
      vim.list_extend(all, nums(a))
    end
    if #all == 0 then
      return 0
    end
    local s = 0
    for _, x in ipairs(all) do
      s = s + x
    end
    return s / #all
  end
  env.vmin = function(...)
    local all = {}
    for _, a in ipairs({ ... }) do
      vim.list_extend(all, nums(a))
    end
    return #all > 0 and math.min(unpack(all)) or 0
  end
  env.vmax = function(...)
    local all = {}
    for _, a in ipairs({ ... }) do
      vim.list_extend(all, nums(a))
    end
    return #all > 0 and math.max(unpack(all)) or 0
  end
  env.vprod = function(...)
    local p = 1
    for _, a in ipairs({ ... }) do
      for _, x in ipairs(nums(a)) do
        p = p * x
      end
    end
    return p
  end
  env.vmedian = function(...)
    local all = {}
    for _, a in ipairs({ ... }) do
      vim.list_extend(all, nums(a))
    end
    table.sort(all)
    local n = #all
    if n == 0 then
      return 0
    end
    if n % 2 == 1 then
      return all[(n + 1) / 2]
    end
    return (all[n / 2] + all[n / 2 + 1]) / 2
  end
  env.vsdev = function(...)
    local all = {}
    for _, a in ipairs({ ... }) do
      vim.list_extend(all, nums(a))
    end
    local n = #all
    if n < 2 then
      return 0
    end
    local mean = env.vsum(all) / n
    local s = 0
    for _, x in ipairs(all) do
      s = s + (x - mean) ^ 2
    end
    return math.sqrt(s / (n - 1))
  end
  -- variance: sample (vvar) and population (vpvar, vpsdev)
  local function var(pop, ...)
    local all = {}
    for _, a in ipairs({ ... }) do
      vim.list_extend(all, nums(a))
    end
    local n = #all
    if n < (pop and 1 or 2) then
      return 0
    end
    local mean = env.vsum(all) / n
    local s = 0
    for _, x in ipairs(all) do
      s = s + (x - mean) ^ 2
    end
    return s / (pop and n or n - 1)
  end
  env.vvar = function(...)
    return var(false, ...)
  end
  env.vpvar = function(...)
    return var(true, ...)
  end
  env.vpsdev = function(...)
    return math.sqrt(var(true, ...))
  end
  env.__if = function(c, a, b)
    if c and c ~= 0 then
      return a
    end
    return b
  end
  env.abs, env.sqrt, env.exp = math.abs, math.sqrt, math.exp
  env.ln, env.log = math.log, math.log
  env.log10 = function(x)
    return math.log(x) / math.log(10)
  end
  env.floor, env.ceil = math.floor, math.ceil
  -- Calc rounds halves away from zero
  env.round = function(x, d)
    local m = 10 ^ (d or 0)
    local v = math.floor(math.abs(x) * m + 0.5) / m
    return x < 0 and -v or v
  end
  env.trunc = function(x)
    return x < 0 and math.ceil(x) or math.floor(x)
  end
  env.idiv = function(a, b)
    return math.floor(a / b)
  end
  env.min, env.max = math.min, math.max
  -- Org's Calc default is degrees; the R flag switches to radians.
  local k = flags.R and 1 or math.pi / 180
  for _, f in ipairs({ "sin", "cos", "tan" }) do
    env[f] = function(x)
      return math[f](x * k)
    end
  end
  for _, f in ipairs({ "asin", "acos", "atan" }) do
    env["arc" .. f:sub(2)] = function(x)
      return math[f](x) / k
    end
    env[f] = env["arc" .. f:sub(2)]
  end
  env.pow = function(a, b)
    return a ^ b
  end
  env.mod = function(a, b)
    return a % b
  end
  env.pi = math.pi
  env.math, env.string, env.table = math, string, table
  env.tonumber, env.tostring, env.type = tonumber, tostring, type
  env.ipairs, env.pairs, env.select, env.unpack = ipairs, pairs, select, unpack
  env.concat = function(t, sep)
    return table.concat(t, sep or "")
  end
  return env
end

---------------------------------------------------------------------------
-- Evaluation
---------------------------------------------------------------------------

--- Source text for a value in the formula language `mode`:
--- "calc" / "lua" (Lua expressions) or "elisp" (Emacs Lisp, where ranges
--- are space-separated and the L flag inserts fields verbatim).
local function literal(v, mode, flags)
  if mode ~= "elisp" then
    return lua_literal(v)
  end
  if type(v) == "table" then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = literal(x, mode, flags)
    end
    return table.concat(parts, " ")
  end
  if type(v) == "number" then
    return v == math.floor(v) and string.format("%d", v) or string.format("%.17g", v)
  end
  if flags.L then
    return tostring(v)
  end
  return '"' .. tostring(v):gsub('[\\"]', "\\%0") .. '"'
end

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

--- Value of the reference or range at position i of s, evaluated in model
--- `m` at (r, c). Returns the value (a range is a list) and the next index.
local function read_ref(m, s, i, r, c, flags, lisp, ctx)
  local spec, j = parse_ref(s, i)
  if not spec then
    error("bad reference near: " .. s:sub(i, i + 5))
  end
  local named
  spec, named = resolve_name(m, spec, ctx)
  if named then
    return cell_value(named, flags, lisp), j
  end
  if spec.row and spec.row.kind == "counter" and not spec.col then
    return r, j
  elseif spec.col and spec.col.kind == "counter" and not spec.row then
    return c, j
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
    return cell_value(row[cc], flags, lisp), j
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
      local cell = row[cc] or ""
      if cell ~= "" or flags.E then
        vals[#vals + 1] = cell_value(cell, flags, lisp)
      end
    end
  end
  return vals, j
end

--- Substitute references in `rhs` for evaluation at (r, c).
---@param mode "calc"|"lua"|"elisp"
local function substitute(m, rhs, r, c, flags, mode, ctx)
  local lisp = mode ~= "calc"
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
      local v, k = read_ref(rm, ref, 1, r, c, flags, lisp, {})
      if k <= #ref then
        error("bad remote reference: " .. ref)
      end
      out[#out + 1] = literal(v, mode, flags)
      i = j
    elseif mode == "elisp" and ch == "$" and rhs:sub(i + 1, i + 1) == "$" then
      -- `$$2` in org-sbe: a literal `$` (quote the next value as a string)
      out[#out + 1] = "$ "
      i = i + 1
    elseif ch == "@" or ch == "$" then
      local v, j = read_ref(m, rhs, i, r, c, flags, lisp, ctx)
      out[#out + 1] = literal(v, mode, flags)
      i = j
    elseif mode == "calc" and ch == "[" then
      out[#out + 1] = "__R({"
      i = i + 1
    elseif mode == "calc" and ch == "]" then
      out[#out + 1] = "})"
      i = i + 1
    else
      out[#out + 1] = ch
      i = i + 1
    end
  end
  local expr = table.concat(out)
  if mode == "calc" then
    expr = expr:gsub("!=", "~="):gsub("&&", " and "):gsub("||", " or ")
    expr = expr:gsub("%f[%w_]if%s*%(", "__if(")
  end
  return expr
end

local function format_result(v, flags)
  if type(v) == "table" then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = format_result(x, flags)
    end
    return table.concat(parts, " ")
  end
  if type(v) == "boolean" then
    return v and "1" or "0"
  end
  if type(v) == "number" then
    if v ~= v then
      return "#ERROR"
    end
    if flags.T then
      return format_duration(v, true)
    elseif flags.U then
      return format_duration(v, false)
    elseif flags.t then
      return string.format(flags.format or "%.2f", v / 3600)
    end
    if flags.format then
      if flags.format:find("%%[^%%]*[dxXo]") then
        v = v < 0 and math.ceil(v) or math.floor(v)
      end
      local ok, out = pcall(string.format, flags.format, v)
      if ok then
        return out
      end
    end
    local calc = flags.calc
    if calc and calc.mode == "f" then
      return string.format("%." .. math.max(calc.n, 0) .. "f", v)
    elseif calc and (calc.mode == "s" or calc.mode == "e") and v ~= 0 and calc.n > 0 then
      local e = math.floor(math.log10(math.abs(v)))
      if calc.mode == "e" then
        e = math.floor(e / 3) * 3
      end
      local mant = v / 10 ^ e
      local digits = calc.n - 1 - math.floor(math.log10(math.abs(mant)))
      local out = string.format("%." .. math.max(digits, 0) .. "f", mant):gsub("%.?0+$", "")
      return e == 0 and out or (out .. "e" .. e)
    end
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
      return string.format("%d", v)
    end
    -- Calc's default display: 8 significant digits (n mode overrides)
    local digits = (calc and calc.mode == "n" and calc.n > 0) and calc.n or 8
    local out = string.format("%." .. digits .. "g", v)
    return (out:gsub("e%+?(%-?)0*(%d)", "e%1%2"))
  end
  if v == nil then
    return ""
  end
  if flags.format and flags.format:find("%%[^%%]*s") then
    local ok, out = pcall(string.format, flags.format, tostring(v))
    if ok then
      return out
    end
  end
  return tostring(v)
end

--- Evaluate a formula RHS for field (r, c). Returns a string.
function M.evaluate(m, rhs, flags, r, c, ctx)
  local mode, body = "calc", rhs
  if rhs:sub(1, 1) == "'" then
    body = rhs:sub(2)
    local has_elisp, elisp = pcall(require, "org.table.elisp")
    mode = (has_elisp and elisp.looks_like(body)) and "elisp" or "lua"
  end
  local ok, expr = pcall(substitute, m, body, r, c, flags, mode, ctx or {})
  if not ok then
    return "#ERROR", expr
  end
  if mode == "elisp" then
    local elisp = require("org.table.elisp")
    local ok2, v = pcall(elisp.eval, expr)
    if not ok2 then
      return "#ERROR", v
    end
    return elisp.to_string(v)
  end
  local chunk, err = load("return " .. expr, "tblfm", "t", make_env(flags))
  if not chunk then
    return "#ERROR", err
  end
  local ok2, v = pcall(chunk)
  if not ok2 then
    return "#ERROR", v
  end
  return format_result(v, flags)
end

--- Parse a formula LHS into a list of target fields {r, c}, and whether it
--- is a column formula.
local function targets(m, lhs, ctx)
  local spec, j = parse_ref(lhs, 1)
  spec = resolve_name(m, spec, ctx)
  if not spec then
    error("bad formula target: " .. lhs)
  end
  local spec2
  if lhs:sub(j, j + 1) == ".." then
    spec2, j = parse_ref(lhs, j + 2)
    spec2 = resolve_name(m, spec2, ctx)
  end
  if j <= #lhs then
    error("bad formula target: " .. lhs)
  end
  local out = {}
  if not spec2 and spec.col and not spec.row then
    -- column formula: rows below the first hline (or all rows)
    local c = resolve_col(m, spec.col, 1)
    local first = (m.hlines[1] and m.hlines[1] > 0) and m.hlines[1] + 1 or 1
    for r = first, #m.data do
      if not m.special[r] then
        out[#out + 1] = { r, c }
      end
    end
    return out, true
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

--- Apply formulas to parsed table `t` in place.
---@param t table from org.table.parse
---@param formulas table from parse_tblfm
---@param ctx? table { get_table = fun(name), constants = table, property = fun(name) }
---@return string[] errors
function M.apply(t, formulas, ctx)
  ctx = ctx or {}
  local m = model(t)
  collect_names(m)
  local errors = {}
  local column, field = {}, {}
  for _, f in ipairs(formulas) do
    local ok, tg, is_col = pcall(targets, m, f.lhs, ctx)
    if not ok then
      errors[#errors + 1] = tg
    elseif is_col then
      column[#column + 1] = { f = f, targets = tg }
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
  -- with `#`/`*` marks in the first column, unmarked rows are exempt from
  -- column formulas
  local marked
  for _, row in ipairs(m.data) do
    local mark = vim.trim(row[1] or "")
    if mark == "#" or mark == "*" then
      marked = marked or {}
    end
  end
  if marked then
    for r, row in ipairs(m.data) do
      local mark = vim.trim(row[1] or "")
      marked[r] = mark == "#" or mark == "*"
    end
  end
  local function eval(entry, r, c)
    if m.data[r] and c >= 1 and c <= m.ncols then
      entry.flags = entry.flags or parse_flags(entry.f.flags or "")
      local v, err = M.evaluate(m, entry.f.rhs, entry.flags, r, c, ctx)
      if err then
        errors[#errors + 1] = err
      end
      m.data[r][c] = v
    end
  end
  -- like Emacs: row by row, every column formula in order; then field formulas
  for r = 1, #m.data do
    if not marked or marked[r] then
      for _, e in ipairs(column) do
        for _, tg in ipairs(e.targets) do
          if tg[1] == r and not overridden[r .. ":" .. tg[2]] then
            eval(e, r, tg[2])
          end
        end
      end
    end
  end
  for _, e in ipairs(field) do
    for _, tg in ipairs(e.targets) do
      eval(e, tg[1], tg[2])
    end
  end
  return errors
end

M._format_duration = format_duration
M._parse_duration = parse_duration

return M
