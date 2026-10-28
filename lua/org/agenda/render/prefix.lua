---@mod org.agenda.render.prefix The prefix of agenda lines
---
--- `agenda.prefix_format` compiled (org-compile-prefix-format) and
--- filled for an item (org-agenda-format-item): category, time of day,
--- level, extra, icon, tag, effort, breadcrumbs and `%(lua)` elements.
--- Part of org.agenda.render, which loads it.

-- Not compiled by the JIT, like org.agenda.render (see the comment there).
if jit then
  jit.off(true, true)
end

local config = require("org.config")
local utils = require("org.utils")
local shared = require("org.agenda.render.shared")

local M = require("org.agenda.render")

local DEFAULT_PREFIX = {
  agenda = " %i %-12:c%?-12t% s",
  todo = " %i %-12:c",
  tags = " %i %-12:c",
  search = " %i %-12:c",
}
M.DEFAULT_PREFIX = DEFAULT_PREFIX

local VARS = {
  c = "category",
  t = "time",
  l = "level",
  s = "extra",
  i = "icon",
  T = "tag",
  e = "effort",
  b = "breadcrumbs",
}

local compiled_cache = {}

--- Compile a prefix format into a list of literal strings and specs.
function M.compile_prefix(fmt)
  if compiled_cache[fmt] then
    return compiled_cache[fmt]
  end
  local out = { has = {} }
  local i = 1
  local lit = {}
  while i <= #fmt do
    local c = fmt:sub(i, i)
    local spec
    if c == "%" then
      local opt, width, sep, j = fmt:match("^%%(%??)([-+]?[%d%.]*)([ .;,:!?=|/<>]?)()", i)
      local var = fmt:sub(j, j)
      if VARS[var] then
        spec = { opt = opt == "?", width = width, sep = sep, var = VARS[var] }
        i = j + 1
      elseif var == "(" then
        local expr = fmt:match("^%b()", j)
        if expr then
          spec = { opt = opt == "?", width = width, sep = sep, var = "eval", expr = expr:sub(2, -2) }
          i = j + #expr
        end
      elseif sep ~= "" and VARS[sep] and var ~= "" then
        -- e.g. "%-12c": the separator class matched nothing
        spec = nil
      end
    end
    if spec then
      if #lit > 0 then
        out[#out + 1] = table.concat(lit)
        lit = {}
      end
      if spec.var == "time" then
        out.has.time = true
      elseif spec.var == "tag" then
        out.has.tag = true
      elseif spec.var == "category" then
        local prec = spec.width:match("%.(%d+)")
        out.category_max = prec and tonumber(prec) or nil
      end
      out[#out + 1] = spec
    else
      lit[#lit + 1] = c
      i = i + 1
    end
  end
  if #lit > 0 then
    out[#out + 1] = table.concat(lit)
  end
  compiled_cache[fmt] = out
  return out
end

--- `format "%<width>s"` by display width.
local function fmt_width(width, s)
  if width == "" then
    return s
  end
  local left = width:sub(1, 1) == "-"
  local num = tonumber(width:match("^[-+]?(%d+)") or "")
  local prec = tonumber(width:match("%.(%d+)") or "")
  if prec and vim.fn.strchars(s) > prec then
    s = vim.fn.strcharpart(s, 0, prec)
  end
  local w = utils.width(s)
  if num and w < num then
    if left then
      s = s .. string.rep(" ", num - w)
    else
      s = string.rep(" ", num - w) .. s
    end
  end
  return s
end

--- The prefix format for a view type.
function M.prefix_format(kind)
  local pf = config.opts.agenda.prefix_format
  if type(pf) == "string" then
    return pf
  elseif type(pf) == "table" and pf[kind] then
    return pf[kind]
  end
  return DEFAULT_PREFIX[kind] or "  %-12:c%?-12t% s"
end

--- "9:00" / "09:00" (org-agenda-time-leading-zero), "+1:00" after midnight.
local function fmt_hm(m)
  local acfg = config.opts.agenda
  local h, mm = math.floor(m / 60), m % 60
  if h > 24 or (h == 24 and mm > 0) then
    return string.format("+%d:%02d", h - 24, mm)
  end
  if acfg.time_leading_zero then
    return string.format("%02d:%02d", h, mm)
  end
  return string.format("%d:%02d", h, mm)
end

--- org-agenda-time-of-day-to-ampm
local function ampm(s)
  local acfg = config.opts.agenda
  local h, m = s:match("^%s*(%d+):(%d%d)")
  if not h then
    return s
  end
  h = tonumber(h)
  local suffix = "am"
  if h == 12 then
    suffix = "pm"
  elseif h > 12 then
    suffix = "pm"
    h = h - 12
  end
  local hs = acfg.time_leading_zero and string.format("%02d", h) or string.format("%2s", tostring(h))
  return hs .. ":" .. m .. suffix
end

--- The time field of an item (the `%t` value). `wrap`: `stop` is the
--- start plus default_appointment_duration, which Emacs writes as a
--- duration ("1d 0:45") and shows by its time of day ("0:45", not the
--- "+0:45" of an end time written past midnight).
---@param start? integer
---@param stop? integer
---@param wrap? boolean
function M.time_string(start, stop, wrap)
  if not start then
    return ""
  end
  local acfg = config.opts.agenda
  local grid = acfg.time_grid or {}
  local use_ampm = acfg.timegrid_use_ampm
  local s = string.format("%5s", fmt_hm(start))
  if use_ampm then
    s = ampm(s)
  end
  if stop then
    local e = fmt_hm(wrap and stop >= 1440 and stop % 1440 or stop)
    if use_ampm then
      e = ampm(e)
    end
    return s .. "-" .. e .. (use_ampm and " " or "")
  end
  local trail = grid.separator or " ┄┄┄┄┄ "
  return s .. trail .. (use_ampm and " " or "")
end

--- `title` as the agenda shows it: bracket links replaced by their
--- description, or their target (org-link-display-format, which follows
--- org-link-bracket-re: `\\]` in the target, any description up to `]]`).
local function display_title(title)
  return require("org.links").display_format(title or "")
end
M.display_title = display_title

--- Category icon text (org-agenda-category-icon-alist).
local function category_icon(cat)
  for _, e in ipairs(config.opts.agenda.category_icons or {}) do
    local pat, icon = e[1] or e.pattern, e[2] or e.icon
    local ok, re = pcall(vim.regex, pat or "")
    if ok and re:match_str(cat or "") then
      return icon or ""
    end
  end
  return ""
end

local function breadcrumbs(item)
  local hl = item.headline
  if not hl or item.grid then
    return ""
  end
  local sep = config.opts.agenda.breadcrumbs_separator or "->"
  local path = hl:outline_path()
  if #path == 0 then
    return ""
  end
  return table.concat(path, sep) .. sep
end

--- Evaluate a `%(lua expression)` prefix element.
local function eval_expr(expr, item)
  local chunk = loadstring("return " .. expr)
  if not chunk then
    return ""
  end
  local env = setmetatable({ item = item, hl = item.headline }, { __index = _G })
  setfenv(chunk, env)
  local ok, v = pcall(chunk)
  if not ok or v == nil then
    return ""
  end
  return tostring(v)
end

--- Build the prefix string of an item.
---@param kind string "agenda"|"todo"|"tags"|"search"
function M.prefix(item, kind)
  local compiled = M.compile_prefix(M.prefix_format(kind))
  local out = {}
  for _, spec in ipairs(compiled) do
    if type(spec) == "string" then
      out[#out + 1] = spec
    else
      local v
      local var = spec.var
      if var == "category" then
        v = item.category or ""
        local max = compiled.category_max
        if max and vim.fn.strchars(v) >= max then
          v = vim.fn.strcharpart(v, 0, max - 1)
        end
      elseif var == "time" then
        v = M.time_string(item.time, item.end_time, item.end_time_default)
      elseif var == "level" then
        v = item.level_str or (item.level and string.rep(" ", item.level)) or ""
      elseif var == "extra" then
        v = (not item.habit and item.extra) or ""
      elseif var == "icon" then
        v = item.grid and "" or category_icon(item.category)
      elseif var == "tag" then
        local tags = item.tags or {}
        v = tags[#tags] or ""
      elseif var == "effort" then
        v = item.headline and item.headline:get_property(config.opts.effort_property or "Effort") or ""
      elseif var == "breadcrumbs" then
        v = breadcrumbs(item)
      elseif var == "eval" then
        v = item.grid and "" or eval_expr(spec.expr, item)
      end
      v = v or ""
      if spec.opt then
        out[#out + 1] = v == "" and "" or fmt_width(spec.width, v .. spec.sep)
      else
        out[#out + 1] = fmt_width(spec.width, v == "" and "" or (v .. spec.sep))
      end
    end
  end
  return table.concat(out), compiled.has
end

shared.display_title = display_title

return M
