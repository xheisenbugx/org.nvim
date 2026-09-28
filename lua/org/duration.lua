---@mod org.duration Durations
---
--- A port of Emacs' org-duration.el. A duration is a run of numbers with
--- units (`duration_units`, e.g. `1d 3h`, `2.5h`, `1y3d4min`), optionally
--- followed by an `H:MM` or `H:MM:SS` part (`3d 13:35`), or a bare `H:MM`
--- / `H:MM:SS` (`1:23:45`). `duration_format` controls how minutes are
--- written back (org-duration-format).
---
--- Units (`duration_units`) map a unit string to its value in minutes:
---   { min = 1, h = 60, d = 1440, w = 10080, m = 43200, y = 525960 }
--- (a list of `{ unit, minutes }` pairs is accepted too). The canonical
--- units min/h/d are always understood when parsing.
---
--- Formats (`duration_format`):
---   "h:mm" | "h:mm:ss"          26:30 | 26:30:00
---   "d h:mm"                    shorthand for { { "d", false }, { "special", "h:mm" } }
---   a list of entries           { unit, required? } pairs, { "special", "h:mm" | "h:mm:ss" | digits }
---                               and the string "compact"; a dict form
---                               { d = false, special = "h:mm", compact = true } works too.

local M = {}

local floor = math.floor

M.CANONICAL_UNITS = { { "min", 1 }, { "h", 60 }, { "d", 1440 } }

M.DEFAULT_UNITS = {
  { "min", 1 },
  { "h", 60 },
  { "d", 1440 },
  { "w", 10080 },
  { "m", 43200 },
  { "y", 525960 },
}

--- The default duration format (org-duration-format), "d h:mm".
local DEFAULT_FORMAT = { { "d", false }, { "special", "h:mm" } }

local function opts()
  local ok, config = pcall(require, "org.config")
  return ok and config.opts or {}
end

--- Units as a list of `{ unit, minutes }` (org-duration-units), or the
--- canonical ones. List entries of the option come first, then its dict
--- entries sorted by name, so lookups are deterministic.
---@param canonical? boolean
---@return table[]
function M.units(canonical)
  if canonical then
    return M.CANONICAL_UNITS
  end
  local u = opts().duration_units
  if type(u) ~= "table" or next(u) == nil then
    return M.DEFAULT_UNITS
  end
  local out, named = {}, {}
  for _, p in ipairs(u) do
    if type(p) == "table" and type(p[1]) == "string" and tonumber(p[2]) then
      out[#out + 1] = { p[1], tonumber(p[2]) }
    end
  end
  for k, v in pairs(u) do
    if type(k) == "string" and tonumber(v) then
      named[#named + 1] = { k, tonumber(v) }
    end
  end
  table.sort(named, function(a, b)
    return a[1] < b[1]
  end)
  vim.list_extend(out, named)
  return out
end

--- Minutes of UNIT (org-duration--modifier); raises on unknown units.
local function modifier(unit, canonical)
  for _, p in ipairs(M.units(canonical)) do
    if p[1] == unit then
      return p[2]
    end
  end
  error(string.format('Unknown unit: "%s"', tostring(unit)), 0)
end

--- Unit strings recognised by the regexps: canonical plus user units,
--- longest first (regexp-opt prefers the longer alternative).
local function unit_names()
  local seen, names = {}, {}
  for _, list in ipairs({ M.CANONICAL_UNITS, M.units() }) do
    for _, p in ipairs(list) do
      if not seen[p[1]] then
        seen[p[1]] = true
        names[#names + 1] = p[1]
      end
    end
  end
  table.sort(names, function(a, b)
    return #a > #b
  end)
  return names
end

--- Match `(?:[ \t]*NUM[ \t]*UNIT)+` at `pos`: every possible way, as
--- `{ stop = next position, terms = { {number, unit}, ... } }`, greedy
--- (longest run) first.
local function unit_runs(s, pos, names, out, terms)
  out, terms = out or {}, terms or {}
  local p = pos + #s:match("^[ \t]*", pos)
  local num = s:match("^%d+%.?%d*", p)
  if num then
    local q = p + #num
    q = q + #s:match("^[ \t]*", q)
    for _, u in ipairs(names) do
      if s:sub(q, q + #u - 1) == u then
        local t = vim.list_extend({}, terms)
        t[#t + 1] = { tonumber(num), u }
        unit_runs(s, q + #u, names, out, t)
        out[#out + 1] = { stop = q + #u, terms = t }
      end
    end
  end
  return out
end

local function hms_p(s)
  return s:match("^[ \t]*%d+:%d%d[ \t]*$") or s:match("^[ \t]*%d+:%d%d:%d%d[ \t]*$")
end

--- Parse S: "full" (units only), "mixed" (units then H:MM[:SS]) or nil,
--- with the unit terms and, for mixed, the H:MM part.
local function parse_units(s)
  for _, run in ipairs(unit_runs(s, 1, unit_names())) do
    local rest = s:sub(run.stop)
    if rest:match("^[ \t]*$") then
      return "full", run.terms
    end
    local hms = rest:match("^[ \t]*(%d+:%d%d)[ \t]*$") or rest:match("^[ \t]*(%d+:%d%d:%d%d)[ \t]*$")
    if hms then
      return "mixed", run.terms, hms
    end
  end
end

--- Whether S is a duration (org-duration-p).
---@param s any
---@return boolean
function M.p(s)
  if type(s) ~= "string" then
    return false
  end
  return hms_p(s) ~= nil or parse_units(s) ~= nil
end

--- Minutes of an H:MM[:SS] string.
local function hms_minutes(s)
  local parts = {}
  for x in s:gmatch("%d+") do
    parts[#parts + 1] = tonumber(x)
  end
  return (parts[3] or 0) / 60 + parts[2] + 60 * parts[1]
end

local function sum_terms(terms, canonical)
  local minutes = 0
  for _, t in ipairs(terms) do
    minutes = minutes + t[1] * modifier(t[2], canonical)
  end
  return minutes
end

--- Minutes of DURATION (org-duration-to-minutes): a bare number is
--- minutes, "" is 0. With CANONICAL, units use their standard values
--- (min/h/d) instead of `duration_units`. Returns nil and a message for an
--- invalid duration, where Emacs raises an error.
---@param duration string|number
---@param canonical? boolean
---@return number?, string?
function M.to_minutes(duration, canonical)
  if type(duration) == "number" then
    return duration
  elseif type(duration) ~= "string" then
    return nil, "Invalid duration format: " .. tostring(duration)
  elseif duration == "" then
    return 0
  elseif hms_p(duration) then
    return hms_minutes(duration)
  end
  local kind, terms, hms = parse_units(duration)
  local ok, res = pcall(function()
    if kind == "full" then
      return sum_terms(terms, canonical)
    elseif kind == "mixed" then
      -- like Emacs, the units part ignores CANONICAL here
      return sum_terms(terms) + hms_minutes(hms)
    end
  end)
  if not ok then
    return nil, res
  elseif res then
    return res
  elseif duration:match("^%d+%.?%d*$") then
    return tonumber(duration)
  end
  return nil, string.format('Invalid duration format: "%s"', duration)
end

--- Normalize a duration format: "h:mm", "h:mm:ss" or a list of entries
--- `{ unit, required }`, `{ "special", mode }` and "compact".
---@return string|table
function M.normalize_format(fmt)
  if fmt == nil or fmt == "d h:mm" then
    return DEFAULT_FORMAT
  elseif fmt == "h:mm" or fmt == "h:mm:ss" then
    return fmt
  elseif type(fmt) ~= "table" then
    error("Invalid duration format specification: " .. vim.inspect(fmt), 0)
  end
  local out = {}
  for _, e in ipairs(fmt) do
    if e == "compact" then
      out[#out + 1] = "compact"
    elseif type(e) == "table" and type(e[1]) == "string" then
      out[#out + 1] = { e[1], e[2] or false }
    else
      error("Invalid duration format entry: " .. vim.inspect(e), 0)
    end
  end
  local keys = {}
  for k in pairs(fmt) do
    if type(k) == "string" then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = fmt[k]
    if k == "compact" then
      if v then
        out[#out + 1] = "compact"
      end
    else
      out[#out + 1] = { k, v or false }
    end
  end
  return out
end

--- The `special` entry of a format list, or nil.
local function special(fmt)
  for _, e in ipairs(fmt) do
    if type(e) == "table" and e[1] == "special" then
      return e[2]
    end
  end
end

local function has_compact(fmt)
  for _, e in ipairs(fmt) do
    if e == "compact" then
      return true
    end
  end
  return false
end

--- Integer division like Emacs `/` on integers, float division otherwise.
local function div(a, b)
  if a == floor(a) and b == floor(b) then
    local q = a / b
    return q >= 0 and floor(q) or -floor(-q)
  end
  return a / b
end

--- Duration string for MINUTES (org-duration-from-minutes), formatted by
--- FMT or `duration_format`. With CANONICAL, units use their standard
--- values.
---@param minutes number
---@param fmt? string|table
---@param canonical? boolean
---@return string
function M.from_minutes(minutes, fmt, canonical)
  if minutes < 0 then
    return "-" .. M.from_minutes(math.abs(minutes), fmt, canonical)
  end
  fmt = M.normalize_format(fmt or opts().duration_format)
  if fmt == "h:mm" then
    return string.format("%d:%02d", floor(minutes / 60), floor(math.fmod(minutes, 60)))
  elseif fmt == "h:mm:ss" then
    local whole = floor(minutes)
    local seconds = math.fmod(60 * minutes, 60)
    return string.format("%s:%02d", M.from_minutes(whole, "h:mm"), floor(seconds))
  end
  local mode = special(fmt)
  if mode == "h:mm" or mode == "h:mm:ss" then
    -- Mixed format: units above the hour, then H:MM or H:MM:SS.
    local truncated, min_mod = {}, nil
    for _, e in ipairs(fmt) do
      if type(e) == "table" and e[1] ~= "special" then
        local m = modifier(e[1], canonical)
        if m > 60 then
          truncated[#truncated + 1] = e
          min_mod = math.min(min_mod or m, m)
        end
      end
    end
    if not min_mod or minutes < min_mod then
      return M.from_minutes(minutes, mode, canonical)
    end
    local units_part = min_mod * div(floor(minutes), min_mod)
    local minutes_part = minutes - units_part
    return M.from_minutes(units_part, truncated, canonical)
      .. (has_compact(fmt) and "" or " ")
      .. M.from_minutes(minutes_part, mode)
  end
  -- Units format.
  local fractional
  if mode ~= nil then
    if type(mode) ~= "number" or mode < 0 or mode ~= floor(mode) then
      error("Unknown formatting directive: " .. vim.inspect(mode), 0)
    end
    fractional = "%." .. mode .. "f"
  end
  local selected = {}
  for i, e in ipairs(fmt) do
    if type(e) == "table" and e[1] ~= "special" then
      selected[#selected + 1] = {
        unit = e[1],
        required = e[2] and true or false,
        mod = modifier(e[1], canonical),
        i = i,
      }
    end
  end
  if #selected == 0 then
    error("Invalid duration format specification: " .. vim.inspect(fmt), 0)
  end
  -- larger units first; stable like Emacs' `sort'
  table.sort(selected, function(a, b)
    if a.mod ~= b.mod then
      return a.mod > b.mod
    end
    return a.i < b.i
  end)
  local sep = has_compact(fmt) and "" or " "
  if fractional then
    -- the first unit required or not larger than MINUTES, else the smallest
    local unit = selected[#selected]
    for _, u in ipairs(selected) do
      if u.required or u.mod <= minutes then
        unit = u
        break
      end
    end
    return string.format(fractional, minutes / unit.mod) .. unit.unit
  end
  local parts = {}
  for _, u in ipairs(selected) do
    if u.mod <= minutes then
      local value = floor(minutes / u.mod)
      minutes = minutes - value * u.mod
      parts[#parts + 1] = string.format("%s%d%s", sep, value, u.unit)
    elseif u.required then
      parts[#parts + 1] = sep .. "0" .. u.unit
    end
  end
  local s = vim.trim(table.concat(parts))
  if s ~= "" then
    return s
  end
  return "0" .. selected[#selected].unit
end

--- Whether every duration of TIMES is H:MM or H:MM:SS
--- (org-duration-h:mm-only-p): nil as soon as one uses units, else
--- "h:mm:ss" when one has seconds, else "h:mm".
---@param times string[]
---@return "h:mm"|"h:mm:ss"|nil
function M.hmm_only_p(times)
  local hms
  for _, t in ipairs(times) do
    if parse_units(t) then
      return nil
    elseif not hms and t:match("^[ \t]*%d+:%d%d:%d%d[ \t]*$") then
      hms = "h:mm:ss"
    end
  end
  return hms or "h:mm"
end

return M
