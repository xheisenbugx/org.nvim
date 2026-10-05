---@mod org.columns.summary Column summaries
---
--- Summary operators (org-columns-summary-types), computing the
--- summaries of a subtree and writing them back, the format in scope.
--- Part of org.columns, which loads it.

local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")
local shared = require("org.columns.shared")

local M = require("org.columns")

local function formula()
  return require("org.table.formula")
end

--- Age in minutes as "Nd Nh Nmin" (zero parts dropped) in canonical
--- units, like Emacs' org-columns--format-age.
function M.format_age(minutes)
  return require("org.duration").from_minutes(minutes, { { "d", false }, { "h", false }, { "min", false } }, true)
end

--- Emacs `(format fmt number)` of a summary number.
local function format_num(fmt, n, isfloat)
  if not fmt then
    return formula().number_to_string(n, isfloat)
  end
  local ok, s = pcall(formula().format_number, fmt, n, isfloat)
  return ok and s or formula().number_to_string(n, isfloat)
end

--- Numbers of `values` (Emacs string-to-number) and whether any is a float.
local function numbers(values)
  local out, anyfloat = {}, false
  for i, v in ipairs(values) do
    local n, fl = formula().string_to_number(v)
    out[i] = { n = n, float = fl }
    anyfloat = anyfloat or fl
  end
  return out, anyfloat
end

--- Emacs `round` (halves to even).
local function round_even(x)
  local f = math.floor(x)
  local d = x - f
  if d > 0.5 or (d == 0.5 and f % 2 == 1) then
    return f + 1
  end
  return f
end

--- Minutes of a duration (org-duration-to-minutes).
local function duration_minutes(v)
  return date.parse_duration(v) or 0
end

--- "h:mm" / "h:mm:ss" when every value is an H:MM[:SS] duration, else nil
--- (org-duration-h:mm-only-p): the format of a duration summary.
local function hmm_only(values)
  return require("org.duration").hmm_only_p(values)
end

--- Age in minutes of a timestamp or a canonical duration, ignoring
--- `duration_units` (org-columns--age-to-minutes).
local function age_minutes(v)
  local d = date.parse(v)
  if d then
    return os.time() / 60 - d:to_time() / 60
  end
  local duration = require("org.duration")
  return duration.p(v) and duration.to_minutes(v, true) or 0
end

--- The summary functions (Emacs org-columns-summary-types-default).
M.SUMMARIES = {
  ["+"] = function(values, fmt)
    local nums, fl = numbers(values)
    local s = 0
    for _, x in ipairs(nums) do
      s = s + x.n
    end
    return format_num(fmt, s, fl)
  end,
  ["$"] = function(values)
    local s = 0
    for _, x in ipairs(numbers(values)) do
      s = s + x.n
    end
    return string.format("%.2f", s)
  end,
  ["X"] = function(values)
    local done = 0
    for _, v in ipairs(values) do
      if v == "[X]" then
        done = done + 1
      end
    end
    return done == #values and "[X]" or (done > 0 and "[-]" or "[ ]")
  end,
  ["X/"] = function(values)
    local done = 0
    for _, v in ipairs(values) do
      local a, b = v:match("%[([1-9])/([1-9])%]")
      if v == "[X]" or (a and a == b) then
        done = done + 1
      end
    end
    return string.format("[%d/%d]", done, #values)
  end,
  ["X%"] = function(values)
    local done = 0
    for _, v in ipairs(values) do
      if v == "[X]" or v == "[100%]" then
        done = done + 1
      end
    end
    return string.format("[%d%%]", round_even(100 * done / #values))
  end,
  ["min"] = function(values, fmt)
    local best
    for _, x in ipairs(numbers(values)) do
      if not best or x.n < best.n then
        best = x
      end
    end
    return format_num(fmt, best.n, best.float)
  end,
  ["max"] = function(values, fmt)
    local best
    for _, x in ipairs(numbers(values)) do
      if not best or x.n > best.n then
        best = x
      end
    end
    return format_num(fmt, best.n, best.float)
  end,
  ["mean"] = function(values, fmt)
    local s = 0
    for _, x in ipairs(numbers(values)) do
      s = s + x.n
    end
    return format_num(fmt, s / #values, true)
  end,
  [":"] = function(values)
    local s = 0
    for _, v in ipairs(values) do
      s = s + duration_minutes(v)
    end
    return date.duration_to_string(s, hmm_only(values))
  end,
  [":min"] = function(values)
    local r
    for _, v in ipairs(values) do
      r = math.min(r or math.huge, duration_minutes(v))
    end
    return date.duration_to_string(r, hmm_only(values))
  end,
  [":max"] = function(values)
    local r
    for _, v in ipairs(values) do
      r = math.max(r or -math.huge, duration_minutes(v))
    end
    return date.duration_to_string(r, hmm_only(values))
  end,
  [":mean"] = function(values)
    local s = 0
    for _, v in ipairs(values) do
      s = s + duration_minutes(v)
    end
    return date.duration_to_string(s / #values, hmm_only(values))
  end,
  ["@min"] = function(values)
    local r
    for _, v in ipairs(values) do
      r = math.min(r or math.huge, age_minutes(v))
    end
    return M.format_age(r)
  end,
  ["@max"] = function(values)
    local r
    for _, v in ipairs(values) do
      r = math.max(r or -math.huge, age_minutes(v))
    end
    return M.format_age(r)
  end,
  ["@mean"] = function(values)
    local s = 0
    for _, v in ipairs(values) do
      s = s + age_minutes(v)
    end
    return M.format_age(s / #values)
  end,
  ["est+"] = function(values)
    -- sum of means +/- the square root of the summed variances
    local mean, var = 0, 0
    for _, v in ipairs(values) do
      local parts = vim.split(v, "-", { plain = true })
      if #parts == 2 then
        local low, high = formula().string_to_number(parts[1]), formula().string_to_number(parts[2])
        local m = (low + high) / 2
        mean = mean + m
        var = var + (low * low + high * high) / 2 - m * m
      elseif #parts == 1 then
        mean = mean + formula().string_to_number(v)
      end
    end
    local sd = math.sqrt(var)
    return string.format("%.0f-%.0f", mean - sd, mean + sd)
  end,
}

--- Summary and collect functions of operator `op`: a user type from
--- `columns_summary_types` (a function, or `{ summarize, collect }`), else
--- a built-in one.
local function summary_type(op)
  local user = (config.opts.columns_summary_types or {})[op]
  if type(user) == "function" then
    return user
  elseif type(user) == "table" then
    return user[1] or user.summarize, user[2] or user.collect
  end
  return M.SUMMARIES[op]
end

--- Combine child values with a summary operator (nil when there is no
--- value to summarize).
function M.summarize(op, values, sfmt)
  local present = vim.tbl_filter(function(v)
    return v ~= nil and v ~= ""
  end, values)
  if #present == 0 then
    return ""
  end
  local fn = summary_type(op)
  if not fn then
    return present[1]
  end
  return fn(present, sfmt)
end

--- Displayed value of a column (org-columns--displayed-value): the user's
--- display function, active timestamps of SCHEDULED/DEADLINE/TIMESTAMP as
--- inactive ones, and the column's printf format applied to every value.
function M.display_value(col, value)
  local modify = config.opts.columns_modify_value_for_display_function
  if type(modify) == "function" then
    local v = modify(col.title, value)
    if v ~= nil then
      return v
    end
  end
  local key = col.prop:upper()
  if key == "ITEM" then
    return value
  elseif key == "DEADLINE" or key == "SCHEDULED" or key == "TIMESTAMP" then
    return (value:gsub("<(%d%d%d%d%-%d%d%-%d%d[^>]*)>", "[%1]"))
  elseif col.summary_fmt then
    local n, fl = formula().string_to_number(value)
    return format_num(col.summary_fmt, n, fl)
  end
  return value
end

--- Write `value` into the existing property `prop` of `hl` (org-entry-put
--- on an existing property: the key is written upcased and aligned).
local function write_property(hl, prop, value)
  local range = hl.properties_range
  if not range then
    return
  end
  local path = hl.file.filename
  local bufnr = hl.file.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    bufnr = path and utils.find_buffer(path)
  end
  if not bufnr then
    return
  end
  for i = range[1] + 1, range[2] - 1 do
    local line = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
    local indent, key = line:match("^(%s*):([^%s:]+):")
    if key and key:upper() == prop:upper() then
      local new = indent .. string.format("%-10s %s", ":" .. prop:upper() .. ":", value)
      if new ~= line then
        vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { new })
      end
      return
    end
  end
end

--- Summaries of the columns with a summary operator for the trees of
--- `roots` (Emacs org-columns--compute-spec): `{ [hl] = { [i] = summary } }`
--- for the entries that have children with values. With `update`, a
--- summary is written back to the property when the entry has it and
--- it differs (only for the first column of a property).
---@param roots org.Headline[]
---@param cols table
---@param update_props? boolean
---@return table<org.Headline, table<integer, string>>
function M.summaries(roots, cols, update_props)
  local summaries = {} -- hl -> { [i] = summary }
  local seen_prop = {}
  for i, col in ipairs(cols) do
    local key = col.prop:upper()
    local fn, collect
    if col.summary and not M.SPECIAL[key] then
      fn, collect = summary_type(col.summary)
    end
    local update = update_props and not seen_prop[key]
    seen_prop[key] = true
    if fn then
      local function walk(hl)
        local vals = {}
        for _, child in ipairs(hl.children) do
          local v = walk(child)
          if v ~= nil then
            vals[#vals + 1] = v
          end
        end
        -- Emacs reads the entry's own value here (org-entry-get without
        -- inheritance): an inherited one would be counted once per child.
        local own
        if collect then
          own = collect(hl, col.prop)
        else
          own = hl:get_property(col.prop, false) or ""
        end
        local s
        if #vals > 0 then
          s = fn(vals, col.summary_fmt)
          summaries[hl] = summaries[hl] or {}
          summaries[hl][i] = s
          if update and hl.properties[key] ~= nil and hl.properties[key] ~= vim.trim(s) then
            write_property(hl, col.prop, vim.trim(s))
          end
        end
        if s then
          return s
        elseif own and own:match("%S") then
          return own
        end
      end
      for _, r in ipairs(roots) do
        walk(r)
      end
    end
  end
  return summaries
end

--- Compute rows for a list of root headlines. Each row has `cells` (the
--- summary or value of each column) and `display` (what column view
--- shows). With `opts.update`, summaries are written back to properties
--- that exist on the entry and differ (Emacs org-columns-compute-all, done
--- when column view opens and when a columnview block is updated).
---@param roots org.Headline[]
---@param cols table
---@param opts? { maxlevel?: integer, update?: boolean }
---@return { hl: org.Headline, cells: string[], display: string[], rel_level: integer }[]
function M.compute(roots, cols, opts)
  opts = opts or {}
  local summaries = M.summaries(roots, cols, opts.update)
  local rows = {}
  local function walk(hl, base)
    if opts.maxlevel and hl.level > opts.maxlevel then
      return
    end
    local cells, display = {}, {}
    for i, col in ipairs(cols) do
      local s = summaries[hl] and summaries[hl][i]
      cells[i] = s or M.value(hl, col.prop)
      display[i] = M.display_value(col, cells[i])
    end
    rows[#rows + 1] = { hl = hl, cells = cells, display = display, rel_level = hl.level - base + 1 }
    for _, c in ipairs(hl.children) do
      walk(c, base)
    end
  end
  for _, r in ipairs(roots) do
    walk(r, r.level)
  end
  return rows
end

--- Column format and roots for a buffer/cursor position, plus the headline
--- or file whose COLUMNS property defines the format (nil for a keyword).
local function scope_for(file, lnum)
  local hl = lnum and file:headline_at(lnum)
  local p = hl
  while p do
    if p.properties.COLUMNS then
      return p.properties.COLUMNS, { p }, p
    end
    p = p.parent
  end
  local inherited = file:get_property("COLUMNS", true)
  if inherited then
    return inherited, file.children, file
  end
  -- Emacs org-columns-get-format: the buffer's own first non-empty
  -- #+COLUMNS line, then the first one collected from setup files.
  local fmt = file.settings.columns
  for _, entry in ipairs(file.settings.keyword_entries or {}) do
    if entry.key == "COLUMNS" and entry.filename == file.filename and entry.value ~= "" then
      fmt = entry.value
      break
    end
  end
  if fmt == "" then
    fmt = nil
  end
  return fmt or config.opts.columns_default_format, hl and { hl } or file.children
end

--- Column format and roots of a whole file, as Emacs sees them with point
--- before the first headline (org-columns-get-format-and-top-level at
--- point-min, as org-agenda-colview-compute calls it).
---@param file table
---@return string fmt, org.Headline[] roots
function M.file_scope(file)
  local fmt, roots = scope_for(file, nil)
  return fmt, roots
end

--- Compute one property's columns, updating existing drawer values only.
--- The first matching column determines whether/how values are written.
function M.compute_property(file, lnum, name)
  local fmt, roots = scope_for(file, lnum)
  local cols = {}
  for _, col in ipairs(M.parse_format(fmt)) do
    if col.prop:upper() == name:upper() then
      cols[#cols + 1] = col
    end
  end
  local first = cols[1]
  if not first or not first.summary or not summary_type(first.summary) then
    utils.warn("No summary operator defined for property " .. name)
    return nil
  end
  M.compute(roots, cols, { update = true })
  return true
end

--- Column format as a string (Emacs org-columns-uncompile-format).
function M.format_string(cols)
  local out = {}
  for _, c in ipairs(cols) do
    local s = "%" .. (c.width and tostring(c.width) or "") .. c.prop
    if c.title and c.title ~= c.prop then
      s = s .. "(" .. c.title .. ")"
    end
    if c.summary then
      s = s .. "{" .. c.summary .. (c.summary_fmt and (";" .. c.summary_fmt) or "") .. "}"
    end
    out[#out + 1] = s
  end
  return table.concat(out, " ")
end

shared.scope_for = scope_for
