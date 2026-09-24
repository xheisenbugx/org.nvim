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
---   functions            vsum vmean vmin vmax vcount vprod vmedian vsdev,
---                        abs sqrt exp ln log log10 floor ceil round min max
---                        sin cos tan asin acos atan pow mod, if(c,a,b)
---   remote references    remote(name, @2$1)
---   Lua formulas         '(expr) - references substituted as Lua strings
---                        (numbers with the N flag)
---   format flags         ;%.2f  ;N (non-numbers = 0)  ;E (keep empty)
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
  local m = { data = {}, hlines = {}, ncols = t.ncols }
  for _, row in ipairs(t.rows) do
    if row.hline then
      m.hlines[#m.hlines + 1] = #m.data -- data rows before this hline
    else
      m.data[#m.data + 1] = row.cells
    end
  end
  return m
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
  if s:sub(j, j) == "$" then
    local rest = s:sub(j + 1)
    local m = rest:match("^([<>])")
    if m then
      spec.col = { kind = m == "<" and "first" or "last" }
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
    return 1
  elseif spec.kind == "last" then
    return m.ncols
  end
  error("bad column reference")
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

local function parse_flags(flags)
  local f = { raw = flags }
  local fmt = flags:match("(%%[%-%+ #0]*%d*%.?%d*[dfeEgGsxXo])")
  if fmt then
    f.format = fmt
    flags = flags:gsub("%%[%-%+ #0]*%d*%.?%d*[dfeEgGsxXo]", "", 1)
  end
  for ch in flags:gmatch(".") do
    f[ch] = true
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
    local d = parse_duration(s)
    if d then
      return d
    end
  end
  if s == "" then
    if flags.E then
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

local function make_env()
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
  env.round = function(x, d)
    local m = 10 ^ (d or 0)
    return math.floor(x * m + 0.5) / m
  end
  env.min, env.max = math.min, math.max
  env.sin, env.cos, env.tan = math.sin, math.cos, math.tan
  env.asin, env.acos, env.atan = math.asin, math.acos, math.atan
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

--- Substitute references in `rhs` for evaluation at (r, c).
local function substitute(m, rhs, r, c, flags, lisp, ctx)
  -- remote(name, ref)
  rhs = rhs:gsub("remote%(%s*([^,%s]+)%s*,%s*([^%)]+)%)", function(name, ref)
    local rows = ctx.get_named_table and ctx.get_named_table(name)
    if not rows then
      error("unknown remote table: " .. name)
    end
    local rt = { rows = {}, ncols = 0 }
    for _, row in ipairs(rows) do
      rt.rows[#rt.rows + 1] = { cells = row }
      rt.ncols = math.max(rt.ncols, #row)
    end
    local rm = model(rt)
    local spec = parse_ref(ref, 1)
    if not spec then
      error("bad remote reference: " .. ref)
    end
    local rr = resolve_row(rm, spec.row, 1, "single")
    local rc = resolve_col(rm, spec.col, 1)
    local v = (rm.data[rr] or {})[rc] or ""
    return lua_literal(cell_value(v, flags, lisp))
  end)

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
    elseif ch == "@" or ch == "$" then
      local spec, j = parse_ref(rhs, i)
      if not spec then
        error("bad reference near: " .. rhs:sub(i, i + 5))
      end
      if spec.row and spec.row.kind == "counter" and not spec.col then
        out[#out + 1] = tostring(r)
        i = j
      elseif spec.col and spec.col.kind == "counter" and not spec.row then
        out[#out + 1] = tostring(c)
        i = j
      else
        local spec2
        if rhs:sub(j, j + 1) == ".." then
          spec2, j = parse_ref(rhs, j + 2)
          if not spec2 then
            error("bad range")
          end
        end
        if spec2 then
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
            for cc = c1, c2 do
              local row = m.data[rr]
              if not row then
                error("row out of range: " .. rr)
              end
              local s = row[cc] or ""
              if s ~= "" or flags.E then
                vals[#vals + 1] = cell_value(s, flags, lisp)
              end
            end
          end
          out[#out + 1] = lua_literal(vals)
        else
          local rr = resolve_row(m, spec.row, r, "single")
          local cc = resolve_col(m, spec.col, c)
          local row = m.data[rr]
          if not row or cc < 1 or cc > m.ncols then
            error("reference out of range")
          end
          out[#out + 1] = lua_literal(cell_value(row[cc], flags, lisp))
        end
        i = j
      end
    else
      out[#out + 1] = ch
      i = i + 1
    end
  end
  local expr = table.concat(out)
  if not lisp then
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
      return string.format(flags.format, v)
    end
    if v == math.floor(v) and math.abs(v) < 1e15 then
      return string.format("%d", v)
    end
    local s = string.format("%.12g", v)
    return s
  end
  if v == nil then
    return ""
  end
  if flags.format and flags.format:match("s$") then
    return string.format(flags.format, tostring(v))
  end
  return tostring(v)
end

--- Evaluate a formula RHS for field (r, c). Returns a string.
function M.evaluate(m, rhs, flags, r, c, ctx)
  local lisp = rhs:sub(1, 1) == "'"
  local body = lisp and rhs:sub(2) or rhs
  local ok, expr = pcall(substitute, m, body, r, c, flags, lisp, ctx or {})
  if not ok then
    return "#ERROR", expr
  end
  local chunk, err = load("return " .. expr, "tblfm", "t", make_env())
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
local function targets(m, lhs)
  local spec, j = parse_ref(lhs, 1)
  if not spec then
    error("bad formula target: " .. lhs)
  end
  local spec2
  if lhs:sub(j, j + 1) == ".." then
    spec2, j = parse_ref(lhs, j + 2)
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
      out[#out + 1] = { r, c }
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
---@param ctx? { get_named_table?: fun(name): string[][] }
---@return string[] errors
function M.apply(t, formulas, ctx)
  local m = model(t)
  local errors = {}
  local column, field = {}, {}
  for _, f in ipairs(formulas) do
    local ok, tg, is_col = pcall(targets, m, f.lhs)
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
  local function run(entry, skip_overridden)
    local flags = parse_flags(entry.f.flags or "")
    for _, tg in ipairs(entry.targets) do
      local r, c = tg[1], tg[2]
      if m.data[r] and c >= 1 and c <= m.ncols and not (skip_overridden and overridden[r .. ":" .. c]) then
        local v, err = M.evaluate(m, entry.f.rhs, flags, r, c, ctx)
        if err then
          errors[#errors + 1] = err
        end
        m.data[r][c] = v
      end
    end
  end
  for _, e in ipairs(column) do
    run(e, true)
  end
  for _, e in ipairs(field) do
    run(e, false)
  end
  return errors
end

M._format_duration = format_duration
M._parse_duration = parse_duration

return M
