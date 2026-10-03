---@mod org.export.ox Generic export engine (port of Emacs ox.el)
---
--- Back-ends are tables of transcoders (one function per element or
--- object type, plus `template` and `inner_template`), registered with
--- `define_backend`. `export_as` runs the Emacs pipeline: #+INCLUDE,
--- COMMENT subtrees, Babel, macros, parsing, pruning according to the
--- export options, then transcoding with `data` (which appends the same
--- blank lines / spaces as the source, like `org-export-data`).
---
--- This file holds the helpers, timestamps and back-ends; the rest lives
--- in org.export.ox.* (options, include, babel, macros, transcode, ...),
--- which add their functions to this module.

local M = {}
-- the parts loaded at the end require this module back
package.loaded["org.export.ox"] = M

--- get_reference honours info.crossrefs (used by publishing).
M.supports_crossrefs = true

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function trim(s)
  return (s:gsub("^[ \t\n\r]+", ""):gsub("[ \t\n\r]+$", ""))
end
M.trim = trim

--- Non-blank string or nil (org-string-nw-p).
function M.nw(s)
  if type(s) == "string" and s:find("[^ \t\n\r]") then
    return s
  end
end

--- Ensure `s` ends with exactly one newline (org-element-normalize-string):
--- trailing "\n[ \t]*" groups are replaced by a single newline.
function M.normalize_string(s)
  if type(s) ~= "string" or s == "" then
    return s
  end
  local k = #s
  local cut = k + 1
  while true do
    local j = k
    while j >= 1 and (s:byte(j) == 32 or s:byte(j) == 9) do
      j = j - 1
    end
    if j >= 1 and s:byte(j) == 10 then
      cut = j
      k = j - 1
    else
      break
    end
  end
  return s:sub(1, cut - 1) .. "\n"
end

local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

--- Day of week (1 = Sunday) of a date.
local function weekday(y, m, d)
  local t = os.time({ year = y, month = m, day = d, hour = 12 })
  return tonumber(os.date("%w", t)) + 1
end
M.weekday = weekday

--- format-time-string (Emacs in the C locale), see org.date.format_time_string.
function M.format_time(fmt, t)
  return require("org.date").format_time_string(fmt, t)
end

---------------------------------------------------------------------------
-- Timestamps
---------------------------------------------------------------------------

local UNIT = { hour = "h", day = "d", week = "w", month = "m", year = "y" }

--- Canonical Org syntax of a timestamp node (org-element-timestamp-interpreter).
function M.interpret_timestamp(ts)
  local t = ts.ts_type
  if t == "diary" then
    return ts.raw_value
  end
  if not (ts.year_start and ts.month_start and ts.day_start) then
    return ts.raw_value
  end
  local open, close = "<", ">"
  if t == "inactive" or t == "inactive-range" then
    open, close = "[", "]"
  end
  local function date(y, mo, d, h, mi)
    local s = string.format("%04d-%02d-%02d %s", y, mo, d, WEEKDAYS[weekday(y, mo, d)])
    if h and mi then
      s = s .. string.format(" %02d:%02d", h, mi)
    end
    return s
  end
  local rep = ""
  if ts.repeater_type then
    local sym = ({ cumulate = "+", ["catch-up"] = "++", restart = ".+" })[ts.repeater_type]
    rep = " " .. sym .. ts.repeater_value .. (UNIT[ts.repeater_unit] or ts.repeater_unit)
  end
  local warn = ""
  if ts.warning_type then
    warn = " "
      .. (ts.warning_type == "first" and "--" or "-")
      .. ts.warning_value
      .. (UNIT[ts.warning_unit] or ts.warning_unit)
  end
  local tail = rep .. warn .. close
  local s = open .. date(ts.year_start, ts.month_start, ts.day_start, ts.hour_start, ts.minute_start)
  if t == "active" or t == "inactive" then
    return s .. tail
  end
  if ts.range_type == "timerange" then
    return s
      .. string.format("-%02d:%02d", ts.hour_end or ts.hour_start or 0, ts.minute_end or ts.minute_start or 0)
      .. tail
  end
  return s
    .. tail
    .. "--"
    .. open
    .. date(
      ts.year_end or ts.year_start,
      ts.month_end or ts.month_start,
      ts.day_end or ts.day_start,
      ts.hour_end,
      ts.minute_end
    )
    .. tail
end

--- Whether the buffer being exported shows custom timestamps
--- (org-display-custom-times there); set by |M.export_as|.
M.display_custom_times = false

--- Timestamp as displayed in exports (org-timestamp-translate): in
--- `time_stamp_custom_formats` when custom times are on (brackets in the
--- formats are kept), else in Org syntax. `boundary` ("start" / "end")
--- translates only that part of a range.
---@param boundary? "start"|"end"
function M.timestamp_translate(ts, boundary)
  if not M.display_custom_times or ts.ts_type == "diary" or not ts.year_start then
    -- org-element-interpret-data keeps the trailing blanks.
    return M.interpret_timestamp(ts) .. string.rep(" ", ts.post_blank or 0)
  end
  local fmts = require("org.config").opts.time_stamp_custom_formats or {}
  local fmt = M.timestamp_has_time_p(ts) and (fmts[2] or "%m/%d/%y %a %H:%M") or (fmts[1] or "%m/%d/%y %a")
  if not boundary and (ts.ts_type == "active-range" or ts.ts_type == "inactive-range") then
    return M.format_timestamp(ts, fmt) .. "--" .. M.format_timestamp(ts, fmt, true)
  end
  return M.format_timestamp(ts, fmt, boundary == "end")
end

function M.timestamp_has_time_p(ts)
  return ts.hour_start ~= nil
end

--- Format a timestamp with format-time-string directives (org-format-timestamp).
function M.format_timestamp(ts, fmt, use_end)
  if ts.ts_type == "diary" then
    return ts.raw_value
  end
  local y = use_end and ts.year_end or ts.year_start
  local mo = use_end and ts.month_end or ts.month_start
  local d = use_end and ts.day_end or ts.day_start
  local h = (use_end and ts.hour_end or ts.hour_start) or 0
  local mi = (use_end and ts.minute_end or ts.minute_start) or 0
  local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = 0 })
  return M.format_time(fmt, t)
end

--- Time (seconds) of a timestamp's start or end.
function M.timestamp_time(ts, use_end)
  local y = use_end and ts.year_end or ts.year_start
  local mo = use_end and ts.month_end or ts.month_start
  local d = use_end and ts.day_end or ts.day_start
  local h = (use_end and ts.hour_end or ts.hour_start) or 0
  local mi = (use_end and ts.minute_end or ts.minute_start) or 0
  return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = 0 })
end

---------------------------------------------------------------------------
-- Back-ends
---------------------------------------------------------------------------

M.backends = {}

--- Register a back-end.
---@param name string
---@param spec table { transcoders = table, options = table[], filters = table, parent = string|nil }
function M.define_backend(name, spec)
  spec.name = name
  spec.transcoders = spec.transcoders or {}
  spec.options = spec.options or {}
  spec.filters = spec.filters or {}
  M.backends[name] = spec
  return spec
end

--- Create an anonymous back-end inheriting from `parent`.
function M.create_backend(parent, transcoders)
  return { name = "anonymous", parent = parent, transcoders = transcoders or {}, options = {}, filters = {} }
end

function M.get_backend(name)
  if type(name) == "table" then
    return name
  end
  local b = M.backends[name]
  if not b then
    local mod = ({
      html = "org.export.html",
      latex = "org.export.latex",
      beamer = "org.export.beamer",
      md = "org.export.markdown",
      gfm = "org.export.gfm",
      ascii = "org.export.ascii",
      org = "org.export.org",
      icalendar = "org.export.icalendar",
      texinfo = "org.export.texinfo",
      ["koma-letter"] = "org.export.koma",
      man = "org.export.man",
    })[name]
    if mod then
      require(mod)
      b = M.backends[name]
    end
  end
  return b
end

--- All transcoders of a back-end, including inherited ones.
function M.all_transcoders(backend)
  backend = M.get_backend(backend)
  local out = {}
  local chain = {}
  local b = backend
  while b do
    table.insert(chain, 1, b)
    b = b.parent and M.get_backend(b.parent) or nil
  end
  for _, x in ipairs(chain) do
    for k, v in pairs(x.transcoders) do
      out[k] = v
    end
  end
  return out
end

--- All back-end specific options (derived first).
function M.all_options(backend)
  local out = {}
  local b = backend and M.get_backend(backend)
  while b do
    local o = b.options
    if type(o) == "function" then
      o = o()
    end
    vim.list_extend(out, o or {})
    b = b.parent and M.get_backend(b.parent) or nil
  end
  return out
end

function M.all_filters(backend)
  local out = {}
  local b = backend and M.get_backend(backend)
  local chain = {}
  while b do
    table.insert(chain, 1, b)
    b = b.parent and M.get_backend(b.parent) or nil
  end
  for _, x in ipairs(chain) do
    for k, v in pairs(x.filters) do
      out[k] = out[k] or {}
      -- back-end filters are applied first
      for i = #v, 1, -1 do
        table.insert(out[k], 1, v[i])
      end
    end
  end
  return out
end

--- Is `backend` derived from any of `names`?
function M.derived_backend_p(backend, ...)
  local names = { ... }
  local b = M.get_backend(backend)
  while b do
    for _, n in ipairs(names) do
      if b.name == n then
        return true
      end
    end
    b = b.parent and M.get_backend(b.parent) or nil
  end
  return false
end

-- in the order they had in one file: a part can use what an earlier one defines
require("org.export.ox.options")
require("org.export.ox.include")
require("org.export.ox.babel")
require("org.export.ox.macros")
require("org.export.ox.transcode")
require("org.export.ox.footnotes")
require("org.export.ox.headlines")
require("org.export.ox.links")
require("org.export.ox.code")
require("org.export.ox.tables")
require("org.export.ox.toc")
require("org.export.ox.quotes")
require("org.export.ox.prune")
require("org.export.ox.pipeline")

return M
