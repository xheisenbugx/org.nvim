---@mod org.export.ox Generic export engine (port of Emacs ox.el)
---
--- Back-ends are tables of transcoders (one function per element or
--- object type, plus `template` and `inner_template`), registered with
--- `define_backend`. `export_as` runs the Emacs pipeline: #+INCLUDE,
--- COMMENT subtrees, Babel, macros, parsing, pruning according to the
--- export options, then transcoding with `data` (which appends the same
--- blank lines / spaces as the source, like `org-export-data`).

local element = require("org.export.element")
local utils = require("org.utils")

local M = {}

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
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local MONTHS_FULL = {
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
}
local WEEKDAYS_FULL = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }

--- Day of week (1 = Sunday) of a date.
local function weekday(y, m, d)
  local t = os.time({ year = y, month = m, day = d, hour = 12 })
  return tonumber(os.date("%w", t)) + 1
end
M.weekday = weekday

--- format-time-string for the common directives, English names (Emacs in
--- the C locale).
function M.format_time(fmt, t)
  t = t or os.time()
  local d = os.date("*t", t)
  local function pad(n, w)
    return string.format("%0" .. (w or 2) .. "d", n)
  end
  local out = {}
  local i = 1
  while i <= #fmt do
    local ch = fmt:sub(i, i)
    if ch ~= "%" then
      out[#out + 1] = ch
      i = i + 1
    else
      local flag = fmt:sub(i + 1, i + 1)
      if flag == "-" or flag == "_" then
        i = i + 1
      else
        flag = ""
      end
      local c = fmt:sub(i + 1, i + 1)
      i = i + 2
      local v
      if c == "%" then
        v = "%"
      elseif c == "Y" then
        v = tostring(d.year)
      elseif c == "y" then
        v = pad(d.year % 100)
      elseif c == "m" then
        v = pad(d.month)
      elseif c == "d" then
        v = pad(d.day)
      elseif c == "e" then
        v = string.format("%2d", d.day)
      elseif c == "H" then
        v = pad(d.hour)
      elseif c == "I" then
        v = pad(((d.hour + 11) % 12) + 1)
      elseif c == "M" then
        v = pad(d.min)
      elseif c == "S" then
        v = pad(d.sec)
      elseif c == "p" then
        v = d.hour < 12 and "AM" or "PM"
      elseif c == "a" then
        v = WEEKDAYS[d.wday]
      elseif c == "A" then
        v = WEEKDAYS_FULL[d.wday]
      elseif c == "b" or c == "h" then
        v = MONTHS[d.month]
      elseif c == "B" then
        v = MONTHS_FULL[d.month]
      elseif c == "F" then
        v = string.format("%04d-%02d-%02d", d.year, d.month, d.day)
      elseif c == "T" then
        v = string.format("%02d:%02d:%02d", d.hour, d.min, d.sec)
      elseif c == "R" then
        v = string.format("%02d:%02d", d.hour, d.min)
      elseif c == "j" then
        v = pad(d.yday, 3)
      elseif c == "u" then
        v = tostring(d.wday == 1 and 7 or d.wday - 1)
      elseif c == "w" then
        v = tostring(d.wday - 1)
      elseif c == "Z" then
        v = os.date("%Z", t)
      elseif c == "z" then
        v = os.date("%z", t)
      elseif c == "s" then
        v = tostring(t)
      else
        v = "%" .. flag .. c
        flag = ""
      end
      if flag == "-" then
        v = v:gsub("^0+(%d)", "%1")
      elseif flag == "_" then
        v = v:gsub("^0", " ")
      end
      out[#out + 1] = v
    end
  end
  return table.concat(out)
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
    warn = " " .. (ts.warning_type == "first" and "--" or "-") .. ts.warning_value .. (UNIT[ts.warning_unit] or ts.warning_unit)
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

--- Timestamp as displayed in exports (org-timestamp-translate without
--- custom display formats).
function M.timestamp_translate(ts)
  -- org-element-interpret-data keeps the trailing blanks.
  return M.interpret_timestamp(ts) .. string.rep(" ", ts.post_blank or 0)
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

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------

local function cfg()
  return require("org.config").opts.export or {}
end
M.cfg = cfg

--- Normalise an option value given as a Lua config value:
--- with_drawers = true | false | { "A", "B" } | { not = { "LOGBOOK" } }
function M.normalize_list_option(v)
  if type(v) ~= "table" then
    return v
  end
  if v["not"] then
    local l = vim.deepcopy(v["not"])
    l.negate = true
    return l
  end
  return v
end

local full_name_cache

--- The default author, like Emacs `user-full-name`: the full name of the
--- system user (GECOS), else the login name. `export.author` overrides it.
function M.user_full_name()
  local c = cfg().author
  if c ~= nil then
    return c or nil
  end
  if full_name_cache then
    return full_name_cache
  end
  local ok, pw = pcall(vim.uv.os_get_passwd)
  local login = ok and pw and pw.username or vim.env.USER or ""
  local name
  if vim.fn.has("mac") == 1 and vim.fn.executable("id") == 1 then
    local res = vim.system({ "id", "-F" }, { text = true }):wait(2000)
    if res.code == 0 then
      name = vim.trim(res.stdout or "")
    end
  elseif vim.fn.executable("getent") == 1 then
    local res = vim.system({ "getent", "passwd", login }, { text = true }):wait(2000)
    if res.code == 0 then
      local gecos = (res.stdout or ""):match("^[^:]*:[^:]*:[^:]*:[^:]*:([^:]*):")
      name = gecos and gecos:match("^([^,]*)")
    end
  end
  if not name or name == "" then
    name = login
  end
  full_name_cache = name
  return name
end

--- org-export-options-alist: { property, keyword, option, default, behavior }
function M.global_options()
  local c = cfg()
  local function d(v, default)
    if v == nil then
      return default
    end
    return v
  end
  return {
    { "title", "TITLE", nil, nil, "parse" },
    { "date", "DATE", nil, nil, "parse" },
    { "author", "AUTHOR", nil, M.user_full_name(), "parse" },
    { "email", "EMAIL", nil, c.email or "", "t" },
    { "language", "LANGUAGE", nil, d(c.default_language, "en"), "t" },
    { "select_tags", "SELECT_TAGS", nil, d(c.select_tags, { "export" }), "split" },
    { "exclude_tags", "EXCLUDE_TAGS", nil, d(c.exclude_tags, { "noexport" }), "split" },
    { "creator", "CREATOR", nil, d(c.creator, M.creator_string()) },
    { "headline_levels", nil, "H", d(c.headline_levels, 3) },
    { "preserve_breaks", nil, "\\n", d(c.preserve_breaks, false) },
    { "section_numbers", nil, "num", d(c.with_section_numbers, true) },
    { "time_stamp_file", nil, "timestamp", d(c.timestamp_file, true) },
    { "with_archived_trees", nil, "arch", d(c.with_archived_trees, "headline") },
    { "with_author", nil, "author", d(c.with_author, true) },
    { "expand_links", nil, "expand-links", d(c.expand_links, true) },
    { "with_broken_links", nil, "broken-links", d(c.with_broken_links, false) },
    { "with_clocks", nil, "c", d(c.with_clocks, false) },
    { "with_creator", nil, "creator", d(c.with_creator, false) },
    { "with_date", nil, "date", d(c.with_date, true) },
    { "with_drawers", nil, "d", M.normalize_list_option(d(c.with_drawers, { ["not"] = { "LOGBOOK" } })) },
    { "with_email", nil, "email", d(c.with_email, false) },
    { "with_emphasize", nil, "*", d(c.with_emphasize, true) },
    { "with_entities", nil, "e", d(c.with_entities, true) },
    { "with_fixed_width", nil, ":", d(c.with_fixed_width, true) },
    { "with_footnotes", nil, "f", d(c.with_footnotes, true) },
    { "with_inlinetasks", nil, "inline", d(c.with_inlinetasks, true) },
    { "with_latex", nil, "tex", d(c.with_latex, true) },
    { "with_planning", nil, "p", d(c.with_planning, false) },
    { "with_priority", nil, "pri", d(c.with_priority, false) },
    { "with_properties", nil, "prop", M.normalize_list_option(d(c.with_properties, false)) },
    { "with_smart_quotes", nil, "'", d(c.with_smart_quotes, false) },
    { "with_special_strings", nil, "-", d(c.with_special_strings, true) },
    { "with_special_rows", nil, nil, false },
    { "with_statistics_cookies", nil, "stat", d(c.with_statistics_cookies, true) },
    { "with_sub_superscript", nil, "^", d(c.with_sub_superscripts, true) },
    { "with_toc", nil, "toc", d(c.with_toc, true) },
    { "with_tables", nil, "|", d(c.with_tables, true) },
    { "with_tags", nil, "tags", d(c.with_tags, true) },
    { "with_tasks", nil, "tasks", M.normalize_list_option(d(c.with_tasks, true)) },
    { "with_timestamps", nil, "<", d(c.with_timestamps, true) },
    { "with_title", nil, "title", d(c.with_title, true) },
    { "with_todo_keywords", nil, "todo", d(c.with_todo_keywords, true) },
    { "with_cite_processors", nil, nil, true },
    { "cite_export", "CITE_EXPORT", nil, c.cite_export },
  }
end

function M.creator_string()
  local v = vim.version()
  return string.format("Neovim %d.%d.%d (org.nvim, Org mode 9.8 compatible)", v.major, v.minor, v.patch)
end

--- Read one Emacs Lisp value from `s` at `pos` (for #+OPTIONS values).
--- Returns value, next position. t/nil -> true/false, symbols and
--- strings -> strings, lists -> tables (`(not ...)` sets `negate`).
function M.read_sexp(s, pos)
  pos = pos or 1
  local ws = s:match("^%s*", pos)
  pos = pos + #ws
  local c = s:sub(pos, pos)
  if c == "" then
    return nil, pos
  elseif c == '"' then
    local out = {}
    local k = pos + 1
    while k <= #s do
      local ch = s:sub(k, k)
      if ch == "\\" then
        out[#out + 1] = s:sub(k + 1, k + 1)
        k = k + 2
      elseif ch == '"' then
        return table.concat(out), k + 1
      else
        out[#out + 1] = ch
        k = k + 1
      end
    end
    return table.concat(out), k
  elseif c == "(" then
    local list = {}
    local k = pos + 1
    local first = true
    while true do
      local w = s:match("^%s*", k)
      k = k + #w
      if s:sub(k, k) == ")" or k > #s then
        return list, k + 1
      end
      local v, nk = M.read_sexp(s, k)
      if first and v == "not" then
        list.negate = true
      elseif v ~= nil then
        list[#list + 1] = v
      end
      first = false
      k = nk
    end
  elseif c == "'" and s:sub(pos + 1, pos + 1) ~= "" and not s:sub(pos + 1, pos + 1):match("%s") then
    return M.read_sexp(s, pos + 1)
  else
    local tok = s:match("^[^%s%(%)\"]+", pos) or c
    local e = pos + #tok
    if tok == "t" then
      return true, e
    elseif tok == "nil" then
      return false, e
    elseif tonumber(tok) then
      return tonumber(tok), e
    end
    return tok, e
  end
end

--- Parse an #+OPTIONS line into { [option_key] = value }.
function M.parse_option_line(line)
  local out = {}
  local order = {}
  local pos = 1
  while pos <= #line do
    local ws = line:match("^%s*", pos)
    pos = pos + #ws
    if pos > #line then
      break
    end
    local colon = line:find(":", pos + 1, true)
    if not colon then
      break
    end
    local key = line:sub(pos, colon - 1)
    local nxt = line:sub(colon + 1, colon + 1)
    if nxt == "" or nxt:match("%s") then
      -- "key:" followed by blank: skip (looking-at-p "\\S-" fails)
      pos = colon + 1
    else
      local v, e = M.read_sexp(line, colon + 1)
      out[key] = v
      order[#order + 1] = key
      pos = e
    end
  end
  return out, order
end

--- Collect in-buffer keywords: { KEY = { values... } } in buffer order,
--- including #+SETUPFILE files (recursively).
function M.collect_keywords(lines, dir, depth, acc)
  acc = acc or {}
  depth = depth or 0
  local in_block = nil
  for _, l in ipairs(lines) do
    local low = l:lower()
    if in_block then
      if low:match("^[ \t]*#%+end_" .. vim.pesc(in_block) .. "[ \t]*$") then
        in_block = nil
      end
    else
      local b = low:match("^[ \t]*#%+begin_(%S+)")
      if b then
        in_block = b
      else
        local key, value = l:match("^[ \t]*#%+([^%s:]+):[ \t]*(.-)[ \t]*$")
        if key then
          key = key:upper()
          if key == "SETUPFILE" and depth < 10 then
            local path = value:match('^"(.*)"$') or value
            local full = utils.expand(M.expand_env(path), dir)
            local content = utils.readfile(full)
            if content then
              M.collect_keywords(content, vim.fn.fnamemodify(full, ":h"), depth + 1, acc)
            end
          else
            acc[key] = acc[key] or {}
            table.insert(acc[key], value)
          end
        end
      end
    end
  end
  return acc
end

--- Expand $VAR and ${VAR} (substitute-env-in-file-name).
function M.expand_env(s)
  return (s:gsub("%${([%w_]+)}", function(v)
    return vim.env[v] or ""
  end):gsub("%$([%a_][%w_]*)", function(v)
    return vim.env[v] or ("$" .. v)
  end))
end

--- Compute export options (org-export-get-environment).
---@param ctx table { keywords, backend, subtree_props, ext, parser }
function M.environment(ctx)
  local backend = ctx.backend
  local options = vim.list_extend(vim.deepcopy(M.all_options(backend)), M.global_options())
  local info = {}
  local seen = {}
  -- global defaults
  for _, o in ipairs(options) do
    if not seen[o[1]] then
      seen[o[1]] = true
      local v = o[4]
      if type(v) == "function" then
        v = v()
      end
      if o[5] == "parse" and type(v) == "string" then
        v = ctx.parse_secondary(v)
      end
      info[o[1]] = vim.deepcopy(v)
    end
  end
  -- external overrides
  for k, v in pairs(ctx.ext or {}) do
    info[k] = v
  end
  -- in-buffer settings
  local kw = ctx.keywords
  local by_option = {}
  local by_keyword = {}
  local seen2 = {}
  for _, o in ipairs(options) do
    if not seen2[o[1]] then
      seen2[o[1]] = true
      if o[3] then
        by_option[o[3]] = by_option[o[3]] or o
      end
      if o[2] then
        by_keyword[o[2]] = by_keyword[o[2]] or {}
        table.insert(by_keyword[o[2]], o)
      end
    end
  end
  local function apply_options(line)
    local parsed = M.parse_option_line(line)
    for key, v in pairs(parsed) do
      local o = by_option[key]
      if not o then
        -- case-insensitive match (assoc-string ... t)
        for k2, o2 in pairs(by_option) do
          if k2:lower() == key:lower() then
            o = o2
          end
        end
      end
      if o then
        info[o[1]] = v
      end
    end
  end
  for _, v in ipairs(kw.OPTIONS or {}) do
    apply_options(v)
  end
  if kw.FILETAGS then
    local tags, seen3 = {}, {}
    for _, v in ipairs(kw.FILETAGS) do
      for t in v:gmatch("[^:%s]+") do
        if not seen3[t] then
          seen3[t] = true
          tags[#tags + 1] = t
        end
      end
    end
    info.filetags = tags
  end
  for key, list in pairs(by_keyword) do
    local values = kw[key]
    if values then
      for _, o in ipairs(list) do
        local b = o[5]
        local v
        if b == "parse" then
          v = ctx.parse_secondary(table.concat(values, " "))
        elseif b == "space" then
          v = table.concat(values, " ")
        elseif b == "newline" then
          v = table.concat(values, "\n")
        elseif b == "split" then
          v = {}
          for _, x in ipairs(values) do
            vim.list_extend(v, vim.split(x, "%s+", { trimempty = true }))
          end
        elseif b == "t" then
          v = values[#values]
        else
          v = values[1]
        end
        info[o[1]] = v
      end
    end
  end
  -- subtree EXPORT_* properties
  local props = ctx.subtree_props
  if props then
    if props.EXPORT_OPTIONS then
      apply_options(props.EXPORT_OPTIONS)
    end
    local seen4 = {}
    for _, o in ipairs(options) do
      local k = o[2]
      if k and not seen4[o[1]] then
        seen4[o[1]] = true
        local v = props["EXPORT_" .. k]
        if k == "TITLE" and not v then
          v = ctx.subtree_title
        end
        if v then
          if o[5] == "parse" then
            v = ctx.parse_secondary(v)
          elseif o[5] == "split" then
            v = vim.split(v, "%s+", { trimempty = true })
          end
          info[o[1]] = v
        end
      end
    end
  end
  info.with_drawers = M.normalize_list_option(info.with_drawers)
  info.with_properties = M.normalize_list_option(info.with_properties)
  return info
end

---------------------------------------------------------------------------
-- Preprocessing: #+INCLUDE
---------------------------------------------------------------------------

local function escape_code(lines)
  local out = {}
  for i, l in ipairs(lines) do
    if l:match("^[ \t]*,*%*") or l:match("^[ \t]*,*#%+") then
      out[i] = l:gsub("^([ \t]*)", "%1,", 1)
    else
      out[i] = l
    end
  end
  return out
end
M.escape_code = escape_code

--- Parse the value of an #+INCLUDE keyword (org-export-parse-include-value).
function M.parse_include_value(value, dir)
  local p = {}
  value = value:gsub(":coding +%S+", "")
  local file = value:match('^(".-")%s') or value:match('^(".-")$') or value:match("^(%S+)")
  if file then
    value = value:sub(#file + 1)
    local loc = file:match("::(.-)\"?$")
    if loc then
      p.location = loc
      file = file:gsub("::.-(\"?)$", "%1")
    end
    file = file:match('^"(.*)"$') or file
    if file:match("^%a[%w+.-]*://") then
      p.file = file
    else
      p.file = utils.expand(file, dir)
    end
    p.raw_file = file
  end
  local oc = value:match(":only%-contents *([^: \r\t\n]%S*)")
  if value:match(":only%-contents") then
    p.only_contents = oc ~= nil and oc ~= "nil"
    value = value:gsub(":only%-contents *[^: \r\t\n]?%S*", "", 1)
  end
  local lines = value:match(':lines +"(%d*%-%d*)"')
  if lines then
    p.lines = lines
    value = value:gsub(':lines +"%d*%-%d*"', "", 1)
  end
  local env
  if value:match("%f[%w]example%f[%W]") then
    env = "literal"
  elseif value:match("%f[%w]export%f[%W]") then
    env = "literal"
  elseif value:match("%f[%w]src%f[%W]") then
    env = "literal"
  end
  p.env = env
  if not env then
    local ml = value:match(":minlevel +(%d+)")
    if ml then
      p.minlevel = tonumber(ml)
      value = value:gsub(":minlevel +%d+", "", 1)
    end
  end
  if env == "literal" then
    local args = value:match("%f[%w]export +(.-)%s*$") or value:match("%f[%w]src +(.-)%s*$")
    if args and args ~= "" then
      -- stop at the first :keyword
      args = trim(args:gsub("%s:.*$", ""))
      p.args = args ~= "" and args or nil
      if p.args then
        local s, e = value:find(vim.pesc(p.args), 1)
        if s then
          value = value:sub(1, s - 1) .. value:sub(e + 1)
        end
      end
    end
  end
  local block = value:match('"(%S+)"')
  if not block then
    for w, pos in value:gmatch("()(%S+)") do
      _ = w
    end
    local s = 1
    while true do
      local a, b = value:find("%S+", s)
      if not a then
        break
      end
      local word = value:sub(a, b)
      if not word:match("^:") and not (a > 1 and value:sub(a - 1, a - 1) == ":") then
        block = word
        break
      end
      -- skip keyword and its value
      if word:match("^:") then
        local a2, b2 = value:find("%S+", b + 1)
        s = (a2 and not value:sub(a2, b2):match("^:")) and (b2 + 1) or (b + 1)
      else
        s = b + 1
      end
    end
  end
  p.block = block
  return p
end

--- Lines of `file` restricted to `range` ("a-b", b exclusive).
local function restrict_lines(content, range)
  if not range then
    return content
  end
  local a, b = range:match("^(%d*)%-(%d*)$")
  a = tonumber(a) or 0
  b = tonumber(b) or 0
  local s = a == 0 and 1 or a
  local e = b == 0 and #content or (b - 1)
  return vim.list_slice(content, s, e)
end

--- Locate `search` in an org file's lines (org-link-search) and return the
--- lines of the element found (subtree, named element or target paragraph).
function M.include_location(content, search, only_contents)
  local file = require("org.parser").parse(content)
  local hl
  local s = search
  if s:match("^%*") then
    local title = trim(s:sub(2))
    hl = file:find_headline(function(h)
      return h:plain_title() == title or trim(h.title) == title
    end)
  elseif s:match("^#") then
    hl = file:find_by_custom_id(s:sub(2))
  end
  if hl then
    local first = hl.line
    local last = hl.end_line
    if only_contents then
      first = hl.line + 1
      if content[first] and content[first]:match("^[ \t]*[A-Z]+:[ \t]*[<%[]") and content[first]:match("^[ \t]*(%u+):")
        and ({ SCHEDULED = true, DEADLINE = true, CLOSED = true })[content[first]:match("^[ \t]*(%u+):")] then
        first = first + 1
      end
      if content[first] and content[first]:match("^[ \t]*:[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Ii][Ee][Ss]:") then
        while content[first] and not content[first]:match("^[ \t]*:[Ee][Nn][Dd]:") do
          first = first + 1
        end
        first = first + 1
      end
    end
    return vim.list_slice(content, first, last)
  end
  -- named element or dedicated target
  local tree = element.parse(content, {})
  local found
  element.map(tree, "*", function(n)
    if found then
      return
    end
    if n.name == s and element.ELEMENTS[n.type] then
      found = n
    end
  end)
  if found then
    -- rebuild the element's lines: search for its NAME line
    for i, l in ipairs(content) do
      local nm = l:match("^[ \t]*#%+[Nn][Aa][Mm][Ee]:[ \t]*(.-)[ \t]*$")
      if nm == s then
        local j = i + 1
        while content[j] and content[j]:match("^[ \t]*#%+[%w_]+:") and not content[j]:lower():match("^[ \t]*#%+begin") do
          j = j + 1
        end
        local l2 = content[j] or ""
        local bt = l2:match("^[ \t]*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)")
        local last = j
        if bt then
          local endp = "^[ \t]*#%+end_" .. vim.pesc(bt:lower())
          while content[last] and not content[last]:lower():match(endp) do
            last = last + 1
          end
        elseif l2:match("^[ \t]*|") then
          while content[last + 1] and content[last + 1]:match("^[ \t]*[|#]") do
            last = last + 1
          end
        else
          while content[last + 1] and not content[last + 1]:match("^[ \t]*$") do
            last = last + 1
          end
        end
        -- element end includes following blank lines
        while content[last + 1] and content[last + 1]:match("^[ \t]*$") do
          last = last + 1
        end
        if only_contents then
          return vim.list_slice(content, j + 1, last - 1)
        end
        return vim.list_slice(content, i, math.min(last, #content))
      end
    end
  end
  for i, l in ipairs(content) do
    if l:find("<<" .. s .. ">>", 1, true) then
      local a, b = i, i
      while a > 1 and not content[a - 1]:match("^[ \t]*$") do
        a = a - 1
      end
      while content[b + 1] and not content[b + 1]:match("^[ \t]*$") do
        b = b + 1
      end
      return vim.list_slice(content, a, b)
    end
  end
  error(string.format("No match for fuzzy expression: %s", s))
end

--- Expand #+INCLUDE keywords (org-export-expand-include-keyword).
---@param lines string[]
---@param dir string directory of the includer
---@param opts table { included, footnotes, file_prefix, includer, expand_env }
function M.expand_includes(lines, dir, opts)
  opts = opts or {}
  local included = opts.included or {}
  local footnotes = opts.footnotes or { order = {}, map = {} }
  local file_prefix = opts.file_prefix or { n = 0, map = {} }
  local top = opts.included == nil
  local out = {}
  local level = 0
  local in_block
  local commented_level
  local todo = opts.todo
  for _, line in ipairs(lines) do
    local stars = line:match("^(%*+) ")
    if stars then
      level = #stars
      if commented_level and level <= commented_level then
        commented_level = nil
      end
      local parts = require("org.parser").parse_headline_line(line, todo)
      if parts and parts.commented and not commented_level then
        commented_level = level
      end
    end
    local low = line:lower()
    local spec
    if in_block then
      if low:match("^[ \t]*#%+end_" .. vim.pesc(in_block) .. "[ \t]*$") then
        in_block = nil
      end
    else
      local b = low:match("^[ \t]*#%+begin_(%S+)")
      if b then
        in_block = b
      else
        spec = line:match("^[ \t]*#%+[Ii][Nn][Cc][Ll][Uu][Dd][Ee]:[ \t]*(.-)[ \t]*$")
      end
    end
    if spec and not commented_level then
      local ind = #(line:match("^([ \t]*)"))
      local p = M.parse_include_value(opts.expand_env and M.expand_env(spec) or spec, dir)
      local file = p.file
      if file then
        local is_url = file:match("^%a[%w+.-]*://") ~= nil
        local content
        if is_url then
          local res = vim.system({ "curl", "-fsSL", file }, { text = true }):wait(30000)
          if res.code ~= 0 then
            error("Cannot include file " .. file)
          end
          content = vim.split((res.stdout or ""):gsub("\n$", ""), "\n", { plain = true })
        else
          content = utils.readfile(file)
          if not content then
            error("Cannot include file " .. file)
          end
        end
        local key = file .. "\0" .. (p.lines or "")
        if included[key] then
          error("Recursive file inclusion: " .. file)
        end
        local ind_str = string.rep(" ", ind)
        if p.env == "literal" then
          local body = restrict_lines(content, p.lines)
          out[#out + 1] = ind_str .. "#+BEGIN_" .. p.block .. (p.args and (" " .. p.args) or "")
          vim.list_extend(out, escape_code(body))
          out[#out + 1] = ind_str .. "#+END_" .. p.block
        elseif p.block then
          local body = restrict_lines(content, p.lines)
          out[#out + 1] = ind_str .. "#+BEGIN_" .. p.block
          vim.list_extend(out, body)
          out[#out + 1] = ind_str .. "#+END_" .. p.block
        else
          local body = content
          if p.location then
            body = M.include_location(content, p.location, p.only_contents)
          end
          body = restrict_lines(body, p.lines)
          -- links relative to the included file become relative to the includer
          local fdir = vim.fn.fnamemodify(file, ":h")
          if opts.includer and not is_url and vim.fs.normalize(fdir) ~= vim.fs.normalize(dir) then
            for i, l in ipairs(body) do
              body[i] = l:gsub("%[%[file:([^%]:][^%]]-)%]", function(path)
                if path:match("^/") or path:match("^~") then
                  return nil
                end
                local abs = vim.fs.normalize(fdir .. "/" .. path)
                return "[[file:" .. M.relative_path(abs, dir) .. "]"
              end):gsub("%[%[(%.%.?/[^%]]-)%]", function(path)
                local abs = vim.fs.normalize(fdir .. "/" .. path)
                return "[[" .. M.relative_path(abs, dir) .. "]"
              end)
            end
          end
          -- trim blank lines around contents
          while #body > 0 and body[1]:match("^[ \t]*$") do
            table.remove(body, 1)
          end
          while #body > 0 and body[#body]:match("^[ \t]*$") do
            table.remove(body)
          end
          -- keep the keyword indentation until the first headline
          if ind > 0 then
            for i, l in ipairs(body) do
              if l:match("^%*+ ") then
                break
              end
              if not l:match("^%[fn:[%w%-_]+%]") then
                body[i] = ind_str .. l
              end
            end
          end
          local minlevel = p.minlevel or (level + 1)
          local min
          for _, l in ipairs(body) do
            local st = l:match("^(%*+) ")
            if st and (not min or #st < min) then
              min = #st
            end
          end
          if min and minlevel then
            local off = minlevel - min
            if off ~= 0 then
              for i, l in ipairs(body) do
                local st, rest = l:match("^(%*+)( .*)$")
                if st then
                  body[i] = string.rep("*", math.max(1, #st + off)) .. rest
                end
              end
            end
          end
          -- make footnote labels file specific
          local id = file_prefix.map[file]
          if not id then
            id = file_prefix.n
            file_prefix.map[file] = id
            file_prefix.n = file_prefix.n + 1
          end
          local seen = {}
          for i, l in ipairs(body) do
            body[i] = l:gsub("%[fn:([%w%-_]+)([%]:])", function(label, tail)
              local new = "-" .. id .. "-" .. label
              seen[label] = new
              return "[fn:" .. new .. tail
            end)
          end
          -- definitions outside the included part
          if p.location or p.lines then
            local defined = {}
            for _, l in ipairs(body) do
              local lab = l:match("^%[fn:([%w%-_]+)%]")
              if lab then
                defined[lab] = true
              end
            end
            for label, new in pairs(seen) do
              if not defined[new] then
                for ci, l in ipairs(content) do
                  local d = l:match("^%[fn:" .. vim.pesc(label) .. "%][ \t]*(.*)$")
                  if d then
                    local def = { d }
                    local k = ci + 1
                    while content[k] and not content[k]:match("^%[fn:") and not content[k]:match("^%*+ ")
                      and not (content[k]:match("^[ \t]*$") and (content[k + 1] or ""):match("^[ \t]*$")) do
                      def[#def + 1] = content[k]
                      k = k + 1
                    end
                    if not footnotes.map[new] then
                      footnotes.map[new] = table.concat(def, "\n")
                      footnotes.order[#footnotes.order + 1] = new
                    end
                    break
                  end
                end
              end
            end
          end
          local sub_included = vim.deepcopy(included)
          sub_included[key] = true
          body = M.expand_includes(body, is_url and dir or fdir, {
            included = sub_included,
            footnotes = footnotes,
            file_prefix = file_prefix,
            includer = opts.includer,
            expand_env = opts.expand_env,
            todo = todo,
          })
          vim.list_extend(out, body)
        end
      end
    else
      out[#out + 1] = line
    end
  end
  if top and #footnotes.order > 0 then
    for _, label in ipairs(footnotes.order) do
      out[#out + 1] = ""
      out[#out + 1] = "[fn:" .. label .. "] " .. footnotes.map[label]
    end
  end
  return out
end

--- Relative path from `dir` to `path` (file-relative-name).
function M.relative_path(path, dir)
  path = vim.fs.normalize(path)
  dir = vim.fs.normalize(dir)
  local ps = vim.split(path, "/", { plain = true })
  local ds = vim.split(dir, "/", { plain = true })
  local i = 1
  while i <= #ps and i <= #ds and ps[i] == ds[i] do
    i = i + 1
  end
  local out = {}
  for _ = i, #ds do
    out[#out + 1] = ".."
  end
  for k = i, #ps do
    out[#out + 1] = ps[k]
  end
  local r = table.concat(out, "/")
  return r ~= "" and r or "."
end

--- Delete COMMENT subtrees (org-export--delete-comment-trees).
function M.delete_comment_trees(lines, todo)
  local out = {}
  local skip_level
  local parser = require("org.parser")
  for _, l in ipairs(lines) do
    local stars = l:match("^(%*+) ")
    if stars then
      if skip_level and #stars <= skip_level then
        skip_level = nil
      end
      if not skip_level then
        local parts = parser.parse_headline_line(l, todo)
        if parts and parts.commented then
          skip_level = #stars
        end
      end
    end
    if not skip_level then
      out[#out + 1] = l
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Babel (ob-exp)
---------------------------------------------------------------------------

--- Process source blocks, #+CALL lines and inline code for export
--- (org-babel-exp-process-buffer): honour :exports, expand noweb
--- references and drop the code or results as needed.
function M.babel_process(lines, ctx)
  local blocks_mod = require("org.babel.blocks")
  local file = require("org.parser").parse(lines, ctx.filename)
  local all_blocks = blocks_mod.parse_blocks(lines)
  local drop = {}
  local replace = {}
  local function in_archived_or_commented(lnum)
    local hl = file:headline_at(lnum)
    while hl do
      if hl:is_archived() then
        return true
      end
      hl = hl.parent
    end
    return false
  end
  for _, b in ipairs(all_blocks) do
    if not in_archived_or_commented(b.start) then
      if b.call then
        local own = blocks_mod.parse_header_string(table.concat(b.header_lines or {}, " ") .. " " .. (b.params or ""))
        local merged = blocks_mod.merge({ vars = {}, results_spec = {} }, own)
        local exports = merged.exports or "results"
        -- the call line itself is removed with the blank lines after it
        local last = b.finish
        while lines[last + 1] and lines[last + 1]:match("^[ \t]*$") do
          last = last + 1
        end
        if b.name_line then
          drop[b.name_line] = true
        end
        for k = b.start, last do
          drop[k] = true
        end
        if (exports == "code" or exports == "none") and b.results then
          for k = b.results.start, b.results.finish do
            drop[k] = true
          end
        end
      else
        local args = blocks_mod.header_args(b, file)
        local exports = args.exports or "code"
        local keep_code = exports == "code" or exports == "both"
        local keep_results = exports == "results" or exports == "both"
        if not keep_results and b.results then
          for k = b.results.start, b.results.finish do
            drop[k] = true
          end
        end
        if not keep_code then
          local last = b.finish
          while lines[last + 1] and lines[last + 1]:match("^[ \t]*$") do
            last = last + 1
          end
          for k = b.start, last do
            drop[k] = true
          end
        else
          -- rewrite the block with org-babel-exp-code-template
          local body = b.body
          local nw = args.noweb or "no"
          if nw == "strip-export" then
            local out = {}
            for i, l in ipairs(body) do
              out[i] = l:gsub("<<[^\n]->>", "")
            end
            body = out
          elseif nw == "yes" or nw == "strip-tangle" then
            local ok, expanded = pcall(require("org.babel").expand_noweb, lines, body, 0, nil, args, "export")
            if ok and expanded then
              body = expanded
            end
          end
          local head = b.indent
            .. "#+begin_src "
            .. (b.lang or "")
            .. (b.switches and b.switches ~= "" and (" " .. vim.trim(b.switches)) or "")
            .. (b.params and b.params ~= "" and (" " .. vim.trim(b.params)) or "")
          local new = { head }
          for _, l in ipairs(escape_code(body)) do
            new[#new + 1] = (l ~= "" and b.indent or "") .. l
          end
          new[#new + 1] = b.indent .. "#+end_src"
          replace[b.start] = { finish = b.finish, lines = new }
        end
      end
    end
  end
  local out = {}
  local i = 1
  while i <= #lines do
    local r = replace[i]
    if r and not drop[i] then
      vim.list_extend(out, r.lines)
      i = r.finish + 1
    else
      if not drop[i] then
        out[#out + 1] = lines[i]
      end
      i = i + 1
    end
  end
  -- inline src blocks and inline calls
  local literal = blocks_mod.inline_literal_lines(out)
  for k, l in ipairs(out) do
    if not literal[k] and not l:match("^[ \t]*#%+") and not l:match("^[ \t]*: ") then
      out[k] = M.babel_inline(l)
    end
  end
  return out
end

--- Handle inline src blocks and calls of one line.
function M.babel_inline(l)
  if not (l:find("src_", 1, true) or l:find("call_", 1, true)) then
    return l
  end
  local result = {}
  local pos = 1
  local n = #l
  while pos <= n do
    local s1 = l:find("src_", pos, true)
    local s2 = l:find("call_", pos, true)
    local s = (s1 and s2) and math.min(s1, s2) or s1 or s2
    if not s then
      break
    end
    local prev = s > 1 and l:sub(s - 1, s - 1) or ""
    local handled = false
    if not prev:match("%w") then
      if l:sub(s, s + 3) == "src_" then
        local lang = l:match("^src_([^ \t%[{]+)", s)
        if lang then
          local k = s + 4 + #lang
          local params = ""
          if l:sub(k, k) == "[" then
            params = l:match("^%b[]", k)
            if params then
              k = k + #params
              params = params:sub(2, -2)
            end
          end
          local body = params and l:match("^%b{}", k)
          if body then
            local e = k + #body
            local args = require("org.babel.blocks").parse_header_string(params)
            local merged = require("org.babel.blocks").merge({ vars = {}, results_spec = {} }, args)
            local exports = merged.exports or "results"
            -- existing result: " {{{results(...)}}}"
            local res = l:match("^[ \t]*{{{results%(.-%)}}}", e)
            local code = "src_" .. lang .. "[" .. params .. "]" .. body
            local rep
            if exports == "results" then
              rep = res and trim(res) or ""
            elseif exports == "code" then
              rep = code
            elseif exports == "both" then
              rep = code .. (res and (" " .. trim(res)) or "")
            else
              rep = ""
            end
            local stop = res and (e + #res) or e
            if rep == "" then
              local ws = l:match("^[ \t]*", stop)
              stop = stop + #ws
            end
            result[#result + 1] = l:sub(pos, s - 1) .. rep
            pos = stop
            handled = true
          end
        end
      else
        local call = l:match("^(call_[^ \t%(%[]+%b[]%b()%b[])", s)
          or l:match("^(call_[^ \t%(%[]+%b()%b[])", s)
          or l:match("^(call_[^ \t%(%[]+%b[]%b())", s)
          or l:match("^(call_[^ \t%(%[]+%b())", s)
        if call then
          local e = s + #call
          local res = l:match("^[ \t]*{{{results%(.-%)}}}", e)
          local hdr = call:match("%b()(%b[])$")
          local exports = "results"
          if hdr then
            local merged = require("org.babel.blocks").merge(
              { vars = {}, results_spec = {} },
              require("org.babel.blocks").parse_header_string(hdr:sub(2, -2))
            )
            exports = merged.exports or "results"
          end
          local rep = ""
          if res and (exports == "results" or exports == "both") then
            rep = trim(res)
          end
          local stop = res and (e + #res) or e
          if rep == "" then
            local ws = l:match("^[ \t]*", stop)
            stop = stop + #ws
          end
          result[#result + 1] = l:sub(pos, s - 1) .. rep
          pos = stop
          handled = true
        end
      end
    end
    if not handled then
      result[#result + 1] = l:sub(pos, s)
      pos = s + 1
    end
  end
  result[#result + 1] = l:sub(pos)
  return table.concat(result)
end

---------------------------------------------------------------------------
-- Macros
---------------------------------------------------------------------------

--- Build the macro expander (org-macro-initialize-templates). Returns a
--- function(macro_node, parser) -> expansion string or nil (undefined).
function M.macro_expander(ctx)
  local kw = ctx.keywords
  local function kwval(name, collect)
    local v = kw[name]
    if not v then
      return nil
    end
    if collect then
      return trim(table.concat(v, " "))
    end
    return v[1]
  end
  local date = kwval("DATE") or ""
  local templates = {}
  -- global macros from config (org-export-global-macros): strings or Lua functions
  for name, v in pairs(cfg().global_macros or {}) do
    templates[name:lower()] = v
  end
  templates.author = kwval("AUTHOR", true) or ""
  templates.email = kwval("EMAIL") or ""
  templates.title = kwval("TITLE", true) or ""
  templates.date = function(fmt)
    if fmt and M.nw(fmt) then
      local d = element.new({}):parse_timestamp(trim(date), 1)
      if d and trim(date) == d.raw_value then
        return M.format_timestamp(d, fmt)
      end
    end
    return date
  end
  for _, def in ipairs(kw.MACRO or {}) do
    local name, body = def:match("^(%S+)[ \t]*(.*)$")
    if name then
      templates[name:lower()] = body
    end
  end
  local counters = {}
  local file = ctx.filename
  local builtin = {
    keyword = function(args)
      return kwval((args[1] or ""):upper(), true) or ""
    end,
    n = function(args)
      local name = trim(args[1] or "")
      local action = args[2] and trim(args[2]) or nil
      if not M.nw(action) then
        counters[name] = (counters[name] or 0) + 1
      elseif action == "-" then
        counters[name] = counters[name] or 1
      elseif action:match("^%d+$") then
        counters[name] = tonumber(action)
      else
        counters[name] = 1
      end
      return tostring(counters[name])
    end,
    property = function(args, parser)
      local name = (args[1] or ""):upper()
      if ctx.property_lookup then
        return ctx.property_lookup(name, args[2], parser) or ""
      end
      return ""
    end,
    time = function(args)
      return M.format_time(args[1] or "")
    end,
    results = function(args)
      return args[1] or ""
    end,
  }
  if file and vim.fn.filereadable(file) == 1 then
    builtin["input-file"] = function()
      return vim.fn.fnamemodify(file, ":t")
    end
    builtin["modification-time"] = function(args)
      return M.format_time(args[1] or "", vim.fn.getftime(file))
    end
  end
  return function(node, parser)
    local key = node.key
    local args = node.args or {}
    local t = templates[key]
    if t ~= nil then
      if type(t) == "function" then
        local ok, v = pcall(t, unpack(args))
        return ok and tostring(v or "") or ""
      end
      if t:match("^%(eval[%s)]") then
        -- Emacs Lisp macros cannot run here: keep the call as-is
        return nil
      end
      return (t:gsub("%$(%d+)", function(d)
        return args[tonumber(d)] or ""
      end))
    end
    local b = builtin[key]
    if b then
      return b(args, parser)
    end
    return nil
  end
end

---------------------------------------------------------------------------
-- Tree helpers (topology)
---------------------------------------------------------------------------

M.map = element.map
M.lineage = element.lineage
M.parent_element = element.parent_element

function M.get_previous_element(blob, info, n)
  local siblings = element.siblings(blob)
  if not siblings then
    return nil
  end
  local idx
  for i, x in ipairs(siblings) do
    if x == blob then
      idx = i
      break
    end
  end
  local ignore = info and info.ignore or {}
  local prev = {}
  for i = idx - 1, 1, -1 do
    local obj = siblings[i]
    if not ignore[obj] then
      if n == nil then
        return obj
      end
      table.insert(prev, 1, obj)
      if type(n) == "number" and #prev >= n then
        return prev
      end
    end
  end
  if n == nil then
    return nil
  end
  return prev
end

function M.get_next_element(blob, info, n)
  local siblings = element.siblings(blob)
  if not siblings then
    return nil
  end
  local idx
  for i, x in ipairs(siblings) do
    if x == blob then
      idx = i
      break
    end
  end
  local ignore = info and info.ignore or {}
  local nxt = {}
  for i = idx + 1, #siblings do
    local obj = siblings[i]
    if not ignore[obj] then
      if n == nil then
        return obj
      end
      nxt[#nxt + 1] = obj
      if type(n) == "number" and #nxt >= n then
        return nxt
      end
    end
  end
  if n == nil then
    return nil
  end
  return nxt
end

function M.first_sibling_p(blob, info)
  local p = M.get_previous_element(blob, info)
  return p == nil or p.type == "section"
end

function M.last_sibling_p(datum, info)
  local nxt = M.get_next_element(datum, info)
  return nxt == nil or (datum.type == "headline" and nxt.level and datum.level > nxt.level)
end

---------------------------------------------------------------------------
-- Attributes, captions
---------------------------------------------------------------------------

--- org-export-read-attribute: attributes of `attr_name` (e.g. "attr_html")
--- as a table { key = value } (plus an ordered `_keys` list).
function M.read_attribute(attr_name, el, property)
  local value = el[attr_name]
  if not value then
    if property then
      return nil
    end
    return { _keys = {} }
  end
  local s = table.concat(value, " ")
  local out = { _keys = {} }
  local function prep(v)
    v = trim(v)
    if v == "" or v == "nil" then
      return nil
    end
    local q = v:match('^"("*)"$')
    if q then
      return q
    end
    return v
  end
  -- split on :keywords preceded by start or blanks
  local keys = {}
  local pos = 1
  local cur_key
  local cur_start
  while true do
    local a, b, k = s:find("%f[^ \t%z]:([%-%w_]+)", pos)
    local valid = false
    while a do
      local after_c = s:sub(b + 1, b + 1)
      local before_c = a > 1 and s:sub(a - 1, a - 1) or " "
      if (after_c == "" or after_c:match("[ \t]")) and before_c:match("[ \t]") then
        valid = true
        break
      end
      a, b, k = s:find("%f[^ \t%z]:([%-%w_]+)", b + 1)
    end
    if not valid then
      break
    end
    if cur_key then
      keys[#keys + 1] = { cur_key, s:sub(cur_start, a - 1) }
    end
    cur_key = k
    cur_start = b + 1
    pos = b + 1
  end
  if cur_key then
    keys[#keys + 1] = { cur_key, s:sub(cur_start) }
  end
  for _, kv in ipairs(keys) do
    local k = kv[1]
    if out[k] == nil and not vim.tbl_contains(out._keys, k) then
      out._keys[#out._keys + 1] = k
    end
    out[k] = prep(kv[2])
  end
  if property then
    return out[property]
  end
  return out
end

--- Caption of `el` as a secondary string (org-export-get-caption).
function M.get_caption(el, short)
  local full = el.caption
  if not full then
    return nil
  end
  local caption
  for _, line in ipairs(full) do
    local c
    if short then
      c = line[2]
    else
      c = line[1]
    end
    if c and #c > 0 then
      if caption then
        caption[#caption + 1] = element.text(" ", nil)
        vim.list_extend(caption, c)
      else
        caption = vim.list_slice(c)
      end
    end
  end
  return caption
end

---------------------------------------------------------------------------
-- Transcoding
---------------------------------------------------------------------------

local BrokenLink = {}
BrokenLink.__index = BrokenLink

--- Signal a broken link (caught by `data` per :with-broken-links).
function M.broken_link(path)
  error(setmetatable({ broken_link = path }, BrokenLink), 0)
end

function M.transcoder(blob, info)
  if blob.type == "org-data" then
    return function(_, contents)
      return contents
    end
  end
  local t = info.translate[blob.type]
  return t
end

local function keep_spaces(data, info)
  local pb = data.post_blank
  if not pb or pb == 0 or element.ELEMENTS[data.type] then
    return nil
  end
  local prev = M.get_previous_element(data, info)
  if not prev then
    return nil
  end
  if prev.type == "plain-text" then
    if prev.value:match("[ \t\r\n]$") then
      return nil
    end
  elseif (prev.post_blank or 0) > 0 then
    return nil
  end
  return string.rep(" ", pb)
end
M.keep_spaces = keep_spaces

local function apply_filters(filters, value, info)
  for _, f in ipairs(filters or {}) do
    local ok, r = pcall(f, value, info.back_end and info.back_end.name, info)
    if ok and r ~= nil then
      value = r
    elseif not ok then
      error(r, 0)
    end
  end
  return value
end
M.apply_filters = apply_filters

--- Transcode `data` (node, secondary string or string) with the current
--- back-end (org-export-data).
function M.data(data, info)
  if data == nil then
    return ""
  end
  if type(data) == "string" then
    local t = info.translate["plain-text"]
    local r = t and t(data, info, nil) or data
    return apply_filters(info.filters["plain-text"], r, info)
  end
  local cache = info.exported_data
  if data.type ~= nil and cache[data] ~= nil then
    return cache[data]
  end
  if data.type == nil then
    local out = {}
    for _, obj in ipairs(data) do
      out[#out + 1] = M.data(obj, info)
    end
    return table.concat(out)
  end
  local t = data.type
  local results
  local ok, err = pcall(function()
    if info.ignore[data] then
      results = nil
    elseif t == "raw" then
      results = data.value
    elseif t == "plain-text" then
      local tr = info.translate["plain-text"]
      results = apply_filters(info.filters["plain-text"], tr and tr(data.value, info, data) or data.value, info)
    elseif #data.contents == 0 or (t == "headline" and info.with_archived_trees == "headline" and data.archivedp) then
      local tr = M.transcoder(data, info)
      if tr then
        results = tr(data, nil, info)
      end
    else
      local tr = M.transcoder(data, info)
      if tr then
        local greater = element.GREATER[t]
        local parts = {}
        for _, c in ipairs(data.contents) do
          parts[#parts + 1] = M.data(c, info)
        end
        local contents = table.concat(parts)
        if greater then
          contents = M.normalize_string(contents)
        end
        results = tr(data, contents, info)
      end
    end
  end)
  if not ok then
    if type(err) == "table" and err.broken_link then
      local mode = info.with_broken_links
      if mode == "mark" then
        results = M.data("[BROKEN LINK: " .. err.broken_link .. "]", info)
      elseif mode == true or mode == "t" then
        results = nil
      else
        error(
          string.format(
            "Org export aborted.  Unable to resolve link: %q\nSee export.with_broken_links (org-export-with-broken-links)",
            err.broken_link
          ),
          0
        )
      end
    else
      error(err, 0)
    end
  end
  local final
  if results == nil then
    final = keep_spaces(data, info) or ""
  elseif t == "org-data" or t == "plain-text" or t == "raw" then
    final = results
  else
    local blank = data.post_blank or 0
    local v
    if element.ELEMENTS[t] then
      v = M.normalize_string(results) .. string.rep("\n", blank)
    else
      v = results .. string.rep(" ", blank)
    end
    final = apply_filters(info.filters[t], v, info)
  end
  cache[data] = final
  return final
end

--- Transcode with another back-end's full translation table.
function M.data_with_backend(data, backend, info)
  backend = M.get_backend(backend)
  local new = setmetatable({
    back_end = backend,
    translate = M.all_transcoders(backend),
    exported_data = {},
  }, { __index = info })
  return M.data(data, new)
end

--- Call a single transcoder of another back-end (org-export-with-backend).
function M.with_backend(backend, data, contents, info)
  backend = M.get_backend(backend)
  local all = M.all_transcoders(backend)
  local t = data.type
  local tr = all[t]
  if not tr then
    error("No foreign transcoder available")
  end
  local new = setmetatable({ back_end = backend, translate = all, exported_data = {} }, { __index = info })
  if t == "plain-text" then
    return tr(data.value, new, data)
  end
  return tr(data, contents, new)
end

---------------------------------------------------------------------------
-- Footnotes
---------------------------------------------------------------------------

function M.get_footnote_definition(ref, info)
  local label = ref.label
  if not label then
    return ref.contents
  end
  local cache = info.footnote_definition_cache
  if not cache then
    cache = { defs = {}, resolved = {} }
    element.map(info.parse_tree, { ["footnote-definition"] = true, ["footnote-reference"] = true }, function(f)
      if f.fn_type ~= "standard" and f.label and not cache.defs[f.label] then
        cache.defs[f.label] = f
      end
    end, { ignore = info.ignore })
    info.footnote_definition_cache = cache
  end
  local d = cache.defs[label]
  if not d then
    error("Definition not found for footnote " .. label, 0)
  end
  return d.contents
end

--- Apply fn on every footnote reference in data (org-export--footnote-reference-map).
function M.footnote_reference_map(fn, data, info, body_first)
  local definitions = {}
  local seen = {}
  local function search(d, delayp)
    element.map(d, "footnote-reference", function(f)
      fn(f)
      local label = f.label
      if not (label and seen[label]) then
        if label then
          seen[label] = true
        end
        if delayp then
          definitions[#definitions + 1] = M.get_footnote_definition(f, info)
        elseif f.fn_type == "inline" then
          -- inline definitions are traversed at the right time
        else
          search(M.get_footnote_definition(f, info), false)
        end
      end
    end, {
      ignore = info.ignore,
      no_recursion = delayp and { ["footnote-definition"] = true, ["footnote-reference"] = true } or { ["footnote-definition"] = true },
    })
  end
  search(data, body_first)
  for _, d in ipairs(definitions) do
    search(d, false)
  end
end

function M.collect_footnote_definitions(info, data, body_first)
  local n = 0
  local labels = {}
  local out = {}
  M.footnote_reference_map(function(f)
    local l = f.label
    if not (l and labels[l]) then
      n = n + 1
      out[#out + 1] = { n, l, M.get_footnote_definition(f, info) }
    end
    if l then
      labels[l] = true
    end
  end, data or info.parse_tree, info, body_first)
  return out
end

function M.footnote_first_reference_p(ref, info, data, body_first)
  local label = ref.label
  if not label then
    return true
  end
  local result
  local done = false
  local ok, err = pcall(M.footnote_reference_map, function(f)
    if not done and f.label == label then
      result = f == ref
      done = true
      error("__stop__", 0)
    end
  end, data or info.parse_tree, info, body_first)
  if not ok and err ~= "__stop__" then
    error(err, 0)
  end
  return result
end

function M.get_footnote_number(footnote, info, data, body_first)
  local count = 0
  local seen = {}
  local label = footnote.label
  local result
  local ok, err = pcall(M.footnote_reference_map, function(f)
    local l = f.label
    if not l and not label and f == footnote then
      result = count + 1
      error("__stop__", 0)
    elseif label and l == label then
      result = count + 1
      error("__stop__", 0)
    elseif not l then
      count = count + 1
    elseif not seen[l] then
      seen[l] = true
      count = count + 1
    end
  end, data or info.parse_tree, info, body_first)
  if not ok and err ~= "__stop__" then
    error(err, 0)
  end
  return result
end

---------------------------------------------------------------------------
-- Headlines
---------------------------------------------------------------------------

function M.get_relative_level(headline, info)
  return headline.level + (info.headline_offset or 0)
end

function M.low_level_p(headline, info)
  local limit = info.headline_levels
  if type(limit) == "number" and limit >= 0 then
    local level = M.get_relative_level(headline, info)
    if level > limit then
      return level - limit
    end
  end
  return nil
end

--- Inherited node property (org-export-get-node-property).
function M.get_node_property(prop, datum, inherited)
  local hl = datum.type == "headline" and datum or element.lineage(datum, "headline")
  if not inherited then
    return datum.props and datum.props[prop]
  end
  local n = datum.type == "headline" and datum or hl
  while n do
    if n.props and n.props[prop] ~= nil then
      return n.props[prop]
    end
    n = n.parent
  end
  return nil
end

function M.numbered_headline_p(headline, info)
  local un = M.get_node_property("UNNUMBERED", headline, true)
  if un and un ~= "nil" then
    return false
  end
  local sec = info.section_numbers
  local level = M.get_relative_level(headline, info)
  if type(sec) == "number" then
    return level <= sec
  end
  return sec and true or false
end

function M.get_headline_number(headline, info)
  if M.numbered_headline_p(headline, info) then
    return info.headline_numbering[headline]
  end
end

function M.number_to_roman(n)
  local roman = {
    { 1000, "M" },
    { 900, "CM" },
    { 500, "D" },
    { 400, "CD" },
    { 100, "C" },
    { 90, "XC" },
    { 50, "L" },
    { 40, "XL" },
    { 10, "X" },
    { 9, "IX" },
    { 5, "V" },
    { 4, "IV" },
    { 1, "I" },
  }
  if n <= 0 then
    return tostring(n)
  end
  local res = {}
  for _, r in ipairs(roman) do
    while n >= r[1] do
      n = n - r[1]
      res[#res + 1] = r[2]
    end
  end
  return table.concat(res)
end

function M.get_tags(el, info, tags, inherited)
  local drop = {}
  for _, t in ipairs(tags or {}) do
    drop[t] = true
  end
  local list
  if not inherited then
    list = el.tags or {}
  else
    local current = vim.deepcopy(el.tags or {})
    local have = {}
    for _, t in ipairs(current) do
      have[t] = true
    end
    local p = el.parent
    while p do
      if p.type == "headline" or p.type == "inlinetask" then
        for _, t in ipairs(p.tags or {}) do
          if not have[t] then
            have[t] = true
            table.insert(current, 1, t)
          end
        end
      end
      p = p.parent
    end
    list = {}
    local seen = {}
    for _, t in ipairs(vim.list_extend(vim.deepcopy(info.filetags or {}), current)) do
      if not seen[t] then
        seen[t] = true
        list[#list + 1] = t
      end
    end
  end
  local out = {}
  for _, t in ipairs(list) do
    if not drop[t] then
      out[#out + 1] = t
    end
  end
  return out
end

function M.get_category(blob, info)
  local c = M.get_node_property("CATEGORY", blob, true)
  if c then
    return c
  end
  for _, v in ipairs(info.keywords.CATEGORY or {}) do
    return v
  end
  local file = info.input_file
  return file and vim.fn.fnamemodify(file, ":t:r") or "???"
end

function M.get_alt_title(headline)
  return headline.alt_title or headline.title
end

---------------------------------------------------------------------------
-- Dates
---------------------------------------------------------------------------

function M.get_date(info, fmt)
  local date = info.date
  fmt = fmt or cfg().date_timestamp_format
  if not date or #date == 0 then
    return nil
  end
  if fmt and #date == 1 and date[1].type == "timestamp" then
    return M.format_timestamp(date[1], fmt)
  end
  return date
end

---------------------------------------------------------------------------
-- Links
---------------------------------------------------------------------------

--- Custom link export functions (config links.types[type].export).
function M.custom_protocol_maybe(link, desc, backend_name, info)
  local t = link.link_type
  if t == "coderef" or t == "custom-id" or t == "fuzzy" or t == "radio" then
    return nil
  end
  local spec = require("org.links").link_type(t)
  if type(spec) == "table" and type(spec.export) == "function" then
    local ok, r = pcall(spec.export, link.path, desc, backend_name, info)
    if ok then
      return r
    end
  end
  if t == "doi" then
    -- org-link-doi-export
    local uri = ((require("org.config").opts.links or {}).doi_server_url or "https://doi.org/") .. link.path
    if backend_name == "html" then
      return string.format('<a href="%s">%s</a>', uri, desc or uri)
    elseif backend_name == "latex" or backend_name == "beamer" then
      return desc and string.format("\\href{%s}{%s}", uri, desc) or string.format("\\url{%s}", uri)
    elseif backend_name == "ascii" then
      if not desc then
        return "<" .. uri .. ">"
      end
      return "[" .. desc .. "]" .. (info and info.ascii_links_to_notes and "" or (" (<" .. uri .. ">)"))
    end
    return uri
  end
  return nil
end

function M.get_coderef_format(path, desc)
  if not desc then
    return "%s"
  end
  local s, e = desc:find("(" .. path .. ")", 1, true)
  if s then
    return (desc:sub(1, s - 1):gsub("%%", "%%%%")) .. "%s" .. (desc:sub(e + 1):gsub("%%", "%%%%"))
  end
  return (desc:gsub("%%", "%%%%"))
end

M.DEFAULT_IMAGE_EXT = {
  "png",
  "jpeg",
  "jpg",
  "gif",
  "tiff",
  "tif",
  "xbm",
  "xpm",
  "pbm",
  "pgm",
  "ppm",
  "webp",
  "avif",
  "svg",
}

--- rules: { [type] = { ext... } }
function M.inline_image_p(link, rules)
  if #link.contents > 0 then
    return false
  end
  rules = rules or { file = M.DEFAULT_IMAGE_EXT }
  local exts = rules[link.link_type]
  if not exts then
    return false
  end
  local ext = (link.path or ""):match("%.([%w]+)$")
  if not ext then
    return false
  end
  ext = ext:lower()
  for _, e in ipairs(exts) do
    if e == ext then
      return true
    end
  end
  return false
end

--- Links whose description is a plain image link become nested image
--- links (org-export-insert-image-links).
function M.insert_image_links(data, info, rules)
  rules = rules or { file = M.DEFAULT_IMAGE_EXT }
  local parser = info.parser
  element.map(data, "link", function(l)
    if #l.contents == 1 and l.contents[1].type == "plain-text" then
      local text = trim(l.contents[1].value)
      local t, path = text:match("^<?([%w%+%-]+):([^%s>]+)>?$")
      if t and rules[t] then
        local ext = path:match("%.([%w]+)$")
        if ext and vim.tbl_contains(rules[t], ext:lower()) then
          local node = parser:parse_objects(text, { link = true })[1]
          if node and node.type == "link" then
            node.parent = l
            node.post_blank = 0
            l.contents = { node }
          end
        end
      end
    end
  end, { ignore = info.ignore, with_affiliated = true })
  return data
end

--- Resolve a coderef: its line number or the label itself.
function M.resolve_coderef(ref, info)
  local r = element.map(info.parse_tree, { ["example-block"] = true, ["src-block"] = true }, function(el)
    local value = trim(el.value or "")
    local fmt = el.label_fmt or "(ref:%s)"
    local pat = vim.pesc(fmt):gsub("%%%%s", vim.pesc(ref))
    local lines = vim.split(value, "\n", { plain = true })
    for i = #lines, 1, -1 do
      if lines[i]:find(pat .. "[ \t]*$") then
        if el.use_labels then
          return ref
        end
        return (M.get_loc(el, info) or 0) + i
      end
    end
  end, { ignore = info.ignore, first_match = true })
  if r == nil then
    M.broken_link(ref)
  end
  return r
end

local function split_words(s)
  return vim.split(s, "%s+", { trimempty = true })
end

local function upcase_list(l)
  local out = {}
  for i, v in ipairs(l) do
    out[i] = v:upper()
  end
  return out
end

--- Search cells of a datum (org-export-search-cells), as strings.
function M.search_cells(datum)
  local t = datum.type
  if t == nil then
    return {}
  end
  if t == "headline" then
    local raw = (datum.raw_value or ""):gsub("%[%d*%%%]", " "):gsub("%[%d*/%d*%]", " ")
    local title = table.concat(upcase_list(split_words(raw)), " ")
    local out = { "headline\0" .. title, "other\0" .. title }
    if datum.props and datum.props.CUSTOM_ID then
      out[#out + 1] = "custom-id\0" .. datum.props.CUSTOM_ID
    end
    return out
  elseif t == "target" then
    return { "target\0" .. table.concat(upcase_list(split_words(datum.value)), " ") }
  else
    local name = datum.name or (datum.results and datum.results[1])
    if name and type(name) == "string" then
      return { "other\0" .. table.concat(split_words(name), " ") }
    end
  end
  return {}
end

function M.string_to_search_cell(s)
  local c = s:sub(1, 1)
  if c == "*" then
    return { "headline\0" .. table.concat(upcase_list(split_words(s:sub(2))), " ") }
  elseif c == "#" then
    return { "custom-id\0" .. s:sub(2) }
  end
  local words = split_words(s)
  local w = table.concat(words, " ")
  local W = table.concat(upcase_list(words), " ")
  local out = {}
  local seen = {}
  for _, cell in ipairs({ "target\0" .. w, "other\0" .. w, "target\0" .. W, "other\0" .. W }) do
    if not seen[cell] then
      seen[cell] = true
      out[#out + 1] = cell
    end
  end
  return out
end

function M.resolve_fuzzy_link(link, info, pseudo)
  local path = type(link) == "string" and link or link.path
  local cells = M.string_to_search_cell(path)
  local cache = info.resolve_fuzzy_cache
  if not cache then
    cache = {}
    local types = { target = true }
    for k in pairs(element.ELEMENTS) do
      types[k] = true
    end
    for _, p in ipairs(pseudo or {}) do
      types[p] = true
    end
    element.map(info.parse_tree, types, function(d)
      for _, cell in ipairs(M.search_cells(d)) do
        cache[cell] = cache[cell] or {}
        table.insert(cache[cell], d)
      end
    end, { ignore = info.ignore })
    info.resolve_fuzzy_cache = cache
  end
  local matches = {}
  for _, cell in ipairs(cells) do
    for _, d in ipairs(cache[cell] or {}) do
      matches[#matches + 1] = d
    end
  end
  if #matches == 0 then
    M.broken_link(path)
  end
  for _, d in ipairs(matches) do
    if d.type ~= "headline" then
      return d
    end
  end
  return matches[1]
end

function M.resolve_id_link(link, info)
  local id = link.path
  local cache = info.id_local_cache
  if not cache then
    cache = {}
    element.map(info.parse_tree, "headline", function(h)
      local props = h.props or {}
      if props.ID and not cache[props.ID] then
        cache[props.ID] = h
      end
      if props.CUSTOM_ID and not cache[props.CUSTOM_ID] then
        cache[props.CUSTOM_ID] = h
      end
    end, { ignore = info.ignore })
    info.id_local_cache = cache
  end
  if cache[id] then
    return cache[id]
  end
  -- external file with that ID
  if link.link_type == "id" then
    local ok, loc = pcall(function()
      return require("org.id").find(id)
    end)
    if ok and loc then
      local file = type(loc) == "table" and (loc.file or loc[1]) or loc
      if type(file) == "string" then
        local base = info.input_file and vim.fn.fnamemodify(info.input_file, ":p:h") or vim.fn.getcwd()
        return { type = "plain-text", value = M.relative_path(file, base), external = true }
      end
    end
  end
  M.broken_link(id)
end

function M.resolve_radio_link(link, info)
  local function clean(s)
    return trim((s:gsub("%s+", " "))):lower()
  end
  local path = clean(link.path)
  return element.map(info.parse_tree, "radio-target", function(r)
    if clean(r.value) == path then
      return r
    end
  end, { ignore = info.ignore, first_match = true })
end

function M.resolve_link(link, info)
  if type(link) == "string" then
    local node = info.parser:parse_objects("[[" .. link .. "]]", { link = true })[1]
    link = node
  end
  local t = link.link_type
  if t == "custom-id" or t == "id" then
    return M.resolve_id_link(link, info)
  elseif t == "fuzzy" then
    return M.resolve_fuzzy_link(link, info)
  end
  M.broken_link(link.path)
end

function M.file_uri(filename)
  if filename:match("^//") then
    return "file:" .. filename
  end
  if not (filename:match("^/") or filename:match("^~")) then
    return filename
  end
  local full = vim.fn.fnamemodify(vim.fn.expand(filename), ":p")
  return (full:match("^/") and "file://" or "file:///") .. full
end

---------------------------------------------------------------------------
-- References and ordinals
---------------------------------------------------------------------------

--- Unique reference for a datum. Emacs generates random "orgXXXXXXX"
--- references; here they are derived from the datum's position so that
--- exports are reproducible.
function M.get_reference(datum, info)
  local refs = info.internal_references
  if refs.by_datum[datum] then
    return refs.by_datum[datum]
  end
  -- references already used by other published files (:crossrefs)
  if info.crossrefs then
    for _, c in ipairs(M.search_cells(datum)) do
      local r = info.crossrefs[c]
      if r and not refs.used[r] then
        refs.used[r] = true
        refs.by_datum[datum] = r
        return r
      end
    end
  end
  refs.n = refs.n + 1
  local key = (datum.type or "secondary") .. ":" .. refs.n .. ":" .. table.concat(M.search_cells(datum), "|")
  local h = vim.fn.sha256(key)
  local ref = "org" .. h:sub(1, 7)
  local k = 8
  while refs.used[ref] do
    ref = "org" .. h:sub(k, k + 6)
    k = k + 1
  end
  refs.used[ref] = true
  refs.by_datum[datum] = ref
  return ref
end

function M.get_ordinal(el, info, types, predicate)
  if el.type == "target" then
    el = element.lineage(el, {
      ["footnote-definition"] = true,
      ["footnote-reference"] = true,
      headline = true,
      item = true,
      table = true,
    })
    if not el then
      return nil
    end
  end
  local t = el.type
  if t == "headline" then
    return M.get_headline_number(el, info)
  elseif t == "item" then
    -- item number within its list(s)
    local nums = {}
    local it = el
    while it and it.type == "item" do
      local list = it.parent
      local n = 0
      for _, x in ipairs(list.contents) do
        n = x.counter or (n + 1)
        if x == it then
          break
        end
      end
      table.insert(nums, 1, n)
      it = element.lineage(list, "item")
    end
    return nums
  elseif t == "footnote-definition" or t == "footnote-reference" then
    return M.get_footnote_number(el, info)
  end
  local want = { [t] = true }
  for _, x in ipairs(types or {}) do
    want[x] = true
  end
  local counter = 0
  return element.map(info.parse_tree, want, function(x)
    if x == el then
      if not predicate or predicate(x, info) then
        return counter + 1
      end
      return nil
    end
    if not predicate or predicate(x, info) then
      counter = counter + 1
    end
  end, { ignore = info.ignore, first_match = true })
end

---------------------------------------------------------------------------
-- Source code
---------------------------------------------------------------------------

function M.get_loc(el, info)
  local nl = el.number_lines
  if not nl then
    return nil
  end
  if nl[1] == "new" then
    return nl[2]
  end
  local loc = 0
  return element.map(info.parse_tree, { ["src-block"] = true, ["example-block"] = true }, function(x)
    if x == el then
      return loc + nl[2]
    end
    local ln = x.number_lines
    if ln then
      local _, count = (x.value or ""):gsub("\n", "")
      if not (x.value or ""):match("\n$") and (x.value or "") ~= "" then
        count = count + 1
      end
      if ln[1] == "new" then
        loc = ln[2] + count
      else
        loc = loc + ln[2] + count
      end
    end
  end, { ignore = info.ignore, first_match = true })
end

--- Code without coderefs and indentation, plus { [line] = label }
--- (org-export-unravel-code).
function M.unravel_code(el)
  local value = el.value or ""
  local lines = vim.split((value:gsub("\n$", "")), "\n", { plain = true })
  if not el.preserve_indent then
    lines = element.remove_indentation(lines)
  end
  local fmt = el.label_fmt or "(ref:%s)"
  local s, e = fmt:find("%s", 1, true)
  local pre, post = fmt:sub(1, s - 1), fmt:sub(e + 1)
  local pat = "()[ \t]*" .. vim.pesc(pre) .. "([%-%w_][%-%w_ ]*)" .. vim.pesc(post) .. "()[ \t]*$"
  local refs = {}
  for i, l in ipairs(lines) do
    local a, label, b = l:match(pat)
    if a then
      refs[i] = label
      lines[i] = l:sub(1, a - 1) .. l:sub(b)
    end
  end
  return table.concat(lines, "\n"), refs
end

--- Apply fun(line, number|nil, ref|nil) to each line (org-export-format-code).
function M.format_code(code, fun, num_lines, refs)
  local locs = vim.split(code, "\n", { plain = true })
  local out = {}
  for i, loc in ipairs(locs) do
    out[i] = fun(loc, num_lines and (num_lines + i) or nil, refs and refs[i] or nil)
  end
  return table.concat(out, "\n") .. "\n"
end

function M.format_code_default(el, info)
  local code, refs = M.unravel_code(el)
  local code_lines = vim.split(code, "\n", { plain = true })
  if #code_lines == 0 then
    return ""
  end
  local use_refs = el.retain_labels and refs or nil
  local num_start = M.get_loc(el, info)
  local num_fmt = num_start and ("%" .. #tostring(#code_lines + num_start) .. "d  ") or nil
  local max_width = 0
  for _, l in ipairs(code_lines) do
    max_width = math.max(max_width, #l)
  end
  if num_start then
    max_width = max_width + #string.format(num_fmt, num_start)
  end
  return M.format_code(code, function(loc, num, ref)
    local number_str = num_fmt and string.format(num_fmt, num) or ""
    local r = number_str .. loc
    if ref then
      r = r .. string.rep(" ", 6 + max_width - (#loc + #number_str)) .. "(" .. ref .. ")"
    end
    return r
  end, num_start, use_refs)
end

---------------------------------------------------------------------------
-- Tables
---------------------------------------------------------------------------

local function cell_text(cell)
  local c = cell and cell.contents or {}
  if #c == 0 then
    return nil
  end
  if #c == 1 and c[1].type == "plain-text" then
    return c[1].value
  end
  return false
end

function M.table_has_special_column_p(tbl)
  local special = "empty"
  for _, row in ipairs(tbl.contents) do
    if row.row_type == "standard" then
      local v = cell_text(row.contents[1])
      if v and ({ ["/"] = 1, ["#"] = 1, ["!"] = 1, ["$"] = 1, ["*"] = 1, ["_"] = 1, ["^"] = 1 })[v] then
        special = "special"
      elseif v == nil then
        -- empty
      else
        return false
      end
    end
  end
  return special == "special"
end

function M.table_row_is_special_p(row, _)
  if row.row_type ~= "standard" then
    return false
  end
  local first = cell_text(row.contents[1])
  if first == "/" then
    return true
  end
  if M.table_has_special_column_p(row.parent) and ({ ["^"] = 1, ["_"] = 1, ["$"] = 1, ["!"] = 1 })[first or ""] then
    return true
  end
  local special = "empty"
  for _, cell in ipairs(row.contents) do
    local v = cell_text(cell)
    if v == nil then
      -- empty
    elseif v and v:match("^<[lrc]?%d*>$") then
      special = "cookie"
    else
      return false
    end
  end
  return special == "cookie"
end

function M.table_has_header_p(tbl, info)
  local cache = info.table_header_cache
  if cache[tbl] ~= nil then
    return cache[tbl]
  end
  local rowgroup, flag = 1, false
  local result = false
  for _, row in ipairs(tbl.contents) do
    if not info.ignore[row] then
      if rowgroup > 1 then
        result = true
        break
      end
      if flag and row.row_type == "rule" then
        rowgroup = rowgroup + 1
        flag = false
      elseif not flag and row.row_type == "standard" then
        flag = true
      end
    end
  end
  cache[tbl] = result
  return result
end

function M.table_row_group(row, info)
  if row.row_type ~= "standard" then
    return nil
  end
  local cache = info.table_row_group_cache
  if cache[row] == nil then
    local group, flag = 0, false
    for _, r in ipairs(row.parent.contents) do
      if not info.ignore[r] then
        if r.row_type == "rule" then
          flag = false
        else
          if not flag then
            group = group + 1
            flag = true
          end
          cache[r] = group
        end
      end
    end
  end
  return cache[row]
end

local function column_of(cell)
  for i, c in ipairs(cell.parent.contents) do
    if c == cell then
      return i
    end
  end
end

function M.table_cell_width(cell, info)
  local row = cell.parent
  local tbl = row.parent
  local col = column_of(cell)
  local cache = info.table_cell_width_cache
  cache[tbl] = cache[tbl] or {}
  if cache[tbl][col] == nil then
    local w = false
    for _, r in ipairs(tbl.contents) do
      if M.table_row_is_special_p(r, info) then
        local v = cell_text(r.contents[col])
        local n = v and v:match("^<[lrc]?(%d+)>$")
        if n then
          w = tonumber(n)
          break
        end
      end
    end
    cache[tbl][col] = w
  end
  return cache[tbl][col] or nil
end

local NUMBER_RE = {
  "^[<>]?[-+^.0-9]*[0-9][-+^.0-9eEdDx()%%:]*$",
  "^[<>]?[-+]?0[xX][%x.]+$",
  "^[<>]?[-+]?[0-9]+#[0-9a-zA-Z.]+$",
  "^nan$",
  "^[-+u]?inf$",
}
function M.table_number_p(s)
  for _, p in ipairs(NUMBER_RE) do
    if s:match(p) then
      return true
    end
  end
  return false
end

function M.table_cell_alignment(cell, info)
  local row = cell.parent
  local tbl = row.parent
  local col = column_of(cell)
  local cache = info.table_cell_alignment_cache
  cache[tbl] = cache[tbl] or {}
  if cache[tbl][col] then
    return cache[tbl][col]
  end
  local number_cells, total = 0, 0
  local cookie
  local prev_num = false
  for _, r in ipairs(tbl.contents) do
    if M.table_row_is_special_p(r, info) then
      local v = cell_text(r.contents[col])
      local a = v and v:match("^<([lrc])%d*>$")
      if a then
        cookie = a
      end
    elseif r.row_type == "rule" then
      -- ignore
    elseif not cookie then
      local v = M.data(r.contents[col] and r.contents[col].contents or {}, info)
      total = total + 1
      if M.table_number_p(v) or (v == "" and prev_num) then
        prev_num = true
        number_cells = number_cells + 1
      else
        prev_num = false
      end
    end
  end
  local fraction = cfg().table_number_fraction or 0.5
  local a
  if cookie == "l" then
    a = "left"
  elseif cookie == "r" then
    a = "right"
  elseif cookie == "c" then
    a = "center"
  elseif total > 0 and number_cells / total >= fraction then
    a = "right"
  else
    a = "left"
  end
  cache[tbl][col] = a
  return a
end

function M.table_cell_borders(cell, info)
  local row = cell.parent
  local tbl = element.lineage(cell, "table")
  local borders = {}
  local rows = tbl.contents
  local idx
  for i, r in ipairs(rows) do
    if r == row then
      idx = i
    end
  end
  -- above
  local rule = false
  local found = false
  for i = idx - 1, 1, -1 do
    local r = rows[i]
    if r.row_type == "rule" then
      rule = true
    elseif not M.table_row_is_special_p(r, info) then
      if rule then
        borders.above = true
      end
      found = true
      break
    end
  end
  if not found then
    if rule then
      borders.above = true
    end
    borders.top = true
  end
  rule, found = false, false
  for i = idx + 1, #rows do
    local r = rows[i]
    if r.row_type == "rule" then
      rule = true
    elseif not M.table_row_is_special_p(r, info) then
      if rule then
        borders.below = true
      end
      found = true
      break
    end
  end
  if not found then
    if rule then
      borders.below = true
    end
    borders.bottom = true
  end
  -- column groups
  local col = column_of(cell)
  for i = #rows, 1, -1 do
    local r = rows[i]
    if r.row_type ~= "rule" and cell_text(r.contents[1]) == "/" then
      local groups = {}
      for k, c in ipairs(r.contents) do
        local v = cell_text(c)
        if v == "<" or v == "<>" or v == ">" then
          groups[k] = v
        end
      end
      if (col > 1 and (groups[col - 1] == ">" or groups[col - 1] == "<>")) or groups[col] == "<" or groups[col] == "<>" then
        borders.left = true
      end
      if (col < #r.contents and (groups[col + 1] == "<" or groups[col + 1] == "<>")) or groups[col] == ">" or groups[col] == "<>" then
        borders.right = true
      end
      break
    end
  end
  return borders
end

function M.table_cell_starts_colgroup_p(cell, info)
  local first
  for _, c in ipairs(cell.parent.contents) do
    if not info.ignore[c] then
      first = c
      break
    end
  end
  return first == cell or M.table_cell_borders(cell, info).left == true
end

function M.table_cell_ends_colgroup_p(cell, info)
  local cells = cell.parent.contents
  return cells[#cells] == cell or M.table_cell_borders(cell, info).right == true
end

local function first_cell(row, info)
  for _, c in ipairs(row.contents) do
    if not info.ignore[c] then
      return c
    end
  end
  return row.contents[1]
end

function M.table_row_starts_rowgroup_p(row, info)
  if row.row_type == "rule" or M.table_row_is_special_p(row, info) then
    return false
  end
  local b = M.table_cell_borders(first_cell(row, info), info)
  return b.top or b.above or false
end

function M.table_row_ends_rowgroup_p(row, info)
  if row.row_type == "rule" or M.table_row_is_special_p(row, info) then
    return false
  end
  local b = M.table_cell_borders(first_cell(row, info), info)
  return b.bottom or b.below or false
end

function M.table_row_in_header_p(row, info)
  return M.table_has_header_p(element.lineage(row, "table"), info) and M.table_row_group(row, info) == 1
end

function M.table_row_starts_header_p(row, info)
  return M.table_row_in_header_p(row, info) and M.table_row_starts_rowgroup_p(row, info)
end

function M.table_row_ends_header_p(row, info)
  return M.table_row_in_header_p(row, info) and M.table_row_ends_rowgroup_p(row, info)
end

function M.table_row_number(row, info)
  if row.row_type ~= "standard" then
    return nil
  end
  local n = -1
  for _, r in ipairs(row.parent.contents) do
    if r.row_type == "standard" and not info.ignore[r] then
      n = n + 1
      if r == row then
        return n
      end
    end
  end
end

function M.table_dimensions(tbl, info)
  local rows, cols = 0, 0
  local first
  for _, r in ipairs(tbl.contents) do
    if r.row_type == "standard" and not info.ignore[r] then
      rows = rows + 1
      first = first or r
    end
  end
  if first then
    for _, c in ipairs(first.contents) do
      if not info.ignore[c] then
        cols = cols + 1
      end
    end
  end
  return rows, cols
end

function M.table_cell_address(cell, info)
  local row = cell.parent
  local rn = M.table_row_number(row, info)
  if not rn then
    return nil
  end
  local c = 0
  for _, x in ipairs(row.contents) do
    if not info.ignore[x] then
      if x == cell then
        return rn, c
      end
      c = c + 1
    end
  end
end

function M.get_table_cell_at(r, c, tbl, info)
  local n = 0
  for _, row in ipairs(tbl.contents) do
    if row.row_type ~= "rule" and not info.ignore[row] then
      if n == r then
        local k = 0
        for _, x in ipairs(row.contents) do
          if not info.ignore[x] then
            if k == c then
              return x
            end
            k = k + 1
          end
        end
        return nil
      end
      n = n + 1
    end
  end
end

---------------------------------------------------------------------------
-- Tables of contents
---------------------------------------------------------------------------

function M.excluded_from_toc_p(headline, info)
  if headline.footnote_section_p or M.low_level_p(headline, info) then
    return true
  end
  if M.get_node_property("UNNUMBERED", headline, true) == "notoc" then
    return true
  end
  local depth = info.with_toc
  return type(depth) == "number" and M.get_relative_level(headline, info) > depth
end

function M.collect_headlines(info, n, scope)
  if scope and scope.type ~= "headline" then
    scope = element.lineage(scope, "headline")
  end
  local root = scope or info.parse_tree
  local limit = info.headline_levels
  local depth
  if type(n) ~= "number" then
    depth = limit
  else
    depth = math.min(scope and (M.get_relative_level(scope, info) + n) or n, limit)
  end
  return element.map(root.contents, "headline", function(h)
    if not M.excluded_from_toc_p(h, info) and depth >= M.get_relative_level(h, info) then
      return h
    end
  end, { ignore = info.ignore })
end

function M.collect_elements(types, info, predicate)
  return element.map(info.parse_tree, types, function(el)
    if el.caption and (not predicate or predicate(el, info)) then
      return el
    end
  end, { ignore = info.ignore })
end

function M.collect_tables(info)
  return M.collect_elements("table", info)
end

function M.collect_figures(info, predicate)
  return M.collect_elements("paragraph", info, predicate)
end

function M.collect_listings(info)
  return M.collect_elements("src-block", info)
end

--- Back-end for TOC entries: no footnotes/targets, links become text.
function M.toc_entry_backend(parent, extra)
  local t = {
    ["footnote-reference"] = function()
      return nil
    end,
    link = function(l, c, i)
      return c or M.data(l.raw_link, i)
    end,
    ["radio-target"] = function(_, c)
      return c
    end,
    target = function()
      return nil
    end,
  }
  for k, v in pairs(extra or {}) do
    t[k] = v
  end
  return M.create_backend(parent, t)
end

---------------------------------------------------------------------------
-- Smart quotes
---------------------------------------------------------------------------

local function is_word(c)
  return c ~= nil and c ~= "" and (c:match("[%w_]") ~= nil or c:byte() > 127)
end
local function is_space(c)
  return c ~= nil and c:match("^[ \t\n\r]$") ~= nil
end
local function is_punct(c)
  return c ~= nil and c:match("^[%.,;:!%?%-]$") ~= nil
end
local function is_open(c)
  return c ~= nil and c:match("^[%(%[{]$") ~= nil
end
local function is_close(c)
  return c ~= nil and c:match("^[%)%]}]$") ~= nil
end
local function is_quote(c)
  return c == '"'
end

--- Quote status of every quote in plain-text nodes of the same parent.
function M.smart_quote_status(node, info)
  local parent = node.parent
  local cache = info.smart_quote_cache
  local key = parent or node
  local status = cache[key]
  if not status then
    status = {}
    local level1_open = false
    local full = {}
    local list = element.siblings(node) or { node }
    element.map(list, "plain-text", function(text)
      local s = text.value
      local cur = {}
      local start = 1
      while true do
        local a = s:find("['\"]", start)
        if not a then
          break
        end
        local ch = s:sub(a, a)
        local st
        if ch == '"' then
          level1_open = not level1_open
          st = level1_open and "primary_opening" or "primary_closing"
        elseif not level1_open then
          st = "apostrophe"
        else
          local prev
          if a > 1 then
            prev = s:sub(a - 1, a - 1)
          else
            local p = M.get_previous_element(text, info)
            if not p then
              prev = nil
            elseif p.type == "plain-text" then
              prev = p.value:sub(-1)
            elseif (p.post_blank or 0) == 0 then
              prev = "no-blank"
            else
              prev = "blank"
            end
          end
          local nxt
          if a + 1 <= #s then
            nxt = s:sub(a + 1, a + 1)
          else
            local n = M.get_next_element(text, info)
            if not n then
              nxt = nil
            elseif n.type == "plain-text" then
              nxt = n.value:sub(1, 1)
            else
              nxt = "no-blank"
            end
          end
          local function strp(x)
            return x ~= nil and x ~= "blank" and x ~= "no-blank"
          end
          local allow_open = (strp(prev) and (is_quote(prev) or is_space(prev) or is_open(prev)) or (prev == "blank" or prev == nil))
            and (strp(nxt) and (is_word(nxt) or is_punct(nxt)) or nxt == "no-blank")
          local allow_close = (strp(prev) and (is_word(prev) or is_punct(prev)) or prev == "no-blank")
            and (strp(nxt) and (is_space(nxt) or is_close(nxt) or is_punct(nxt) or is_quote(nxt)) or (nxt == "blank" or nxt == nil))
          if allow_open and allow_close then
            st = "apostrophe"
          elseif allow_open then
            st = "secondary_opening"
          elseif allow_close then
            st = "secondary_closing"
          else
            st = "apostrophe"
          end
        end
        cur[#cur + 1] = { st = st }
        start = a + 1
      end
      if #cur > 0 then
        full[#full + 1] = { text, cur }
      end
    end, { no_recursion = element.RECURSIVE_OBJECTS, ignore = info.ignore })
    -- unbalanced quotes become apostrophes
    local primary, secondary = {}, {}
    for _, sub in ipairs(full) do
      for _, q in ipairs(sub[2]) do
        if q.st == "primary_opening" then
          primary[#primary + 1] = q
        elseif q.st == "secondary_opening" then
          secondary[#secondary + 1] = q
        elseif q.st == "secondary_closing" then
          if #secondary > 0 then
            table.remove(secondary)
          else
            q.st = "apostrophe"
          end
        elseif q.st == "primary_closing" then
          for _, o in ipairs(secondary) do
            o.st = "apostrophe"
          end
          secondary = {}
          table.remove(primary)
        end
      end
    end
    if #primary > 0 then
      local marker = primary[#primary]
      marker.st = nil
      local after_marker = false
      for _, sub in ipairs(full) do
        for _, q in ipairs(sub[2]) do
          if q == marker then
            after_marker = true
          end
          if after_marker and (q.st == "secondary_opening" or q.st == "secondary_closing") then
            q.st = "apostrophe"
          end
        end
      end
    end
    for _, sub in ipairs(full) do
      status[sub[1]] = sub[2]
    end
    cache[key] = status
  end
  return status[node]
end

--- Replace quotes of plain text `s` (from `node`) by smart quotes.
function M.activate_smart_quotes(s, encoding, info, node)
  local status = node and M.smart_quote_status(node, info)
  if not status then
    return s
  end
  local quotes = require("org.export.dictionary").smart_quotes[info.language or "en"]
  local i = 0
  return (s:gsub("['\"]", function(m)
    i = i + 1
    local st = status[i] and status[i].st
    local tr = st and quotes and quotes[st] and quotes[st][encoding]
    return tr or m
  end))
end

---------------------------------------------------------------------------
-- Translation
---------------------------------------------------------------------------

function M.translate(s, encoding, info)
  local dict = require("org.export.dictionary").dictionary
  local entry = dict[s]
  local lang = info and info.language or "en"
  local tr = entry and entry[lang]
  if tr then
    return tr[encoding] or tr.default or s
  end
  return s
end

---------------------------------------------------------------------------
-- Pruning (org-export--prune-tree)
---------------------------------------------------------------------------

local function member_ci(s, list)
  for _, x in ipairs(list or {}) do
    if x:lower() == (s or ""):lower() then
      return true
    end
  end
  return false
end

function M.selected_trees(data, info)
  local select = {}
  for _, t in ipairs(info.select_tags or {}) do
    select[t] = true
  end
  for _, t in ipairs(info.filetags or {}) do
    if select[t] then
      return element.map(data, { headline = true, inlinetask = true }, function(h)
        return h
      end)
    end
  end
  local selected = {}
  local function walk(d, genealogy)
    local t = d.type
    if t == "headline" or t == "inlinetask" then
      local hit = false
      for _, tag in ipairs(d.tags or {}) do
        if select[tag] then
          hit = true
        end
      end
      if hit then
        for _, g in ipairs(genealogy) do
          selected[g] = true
        end
        element.map(d, { headline = true, inlinetask = true }, function(h)
          selected[h] = true
        end)
      elseif t == "headline" then
        local g2 = vim.list_extend(vim.deepcopy(genealogy), { d })
        -- (deepcopy of nodes is expensive; use shallow copy)
        g2 = {}
        for _, x in ipairs(genealogy) do
          g2[#g2 + 1] = x
        end
        g2[#g2 + 1] = d
        for _, c in ipairs(d.contents) do
          walk(c, g2)
        end
      end
    elseif t == "org-data" or element.GREATER[t] then
      for _, c in ipairs(d.contents) do
        walk(c, genealogy)
      end
    end
  end
  walk(data, {})
  if next(selected) == nil then
    return nil
  end
  return selected
end

local function skip_timestamp_p(with, ttype)
  if with == false then
    return true
  elseif with == "active" then
    return not (ttype == "active" or ttype == "active-range" or ttype == "diary")
  elseif with == "active-exclude-diary" then
    return not (ttype == "active" or ttype == "active-range")
  elseif with == "inactive" then
    return not (ttype == "inactive" or ttype == "inactive-range")
  end
  return false
end

function M.skip_p(datum, info, selected, excluded)
  local t = datum.type
  if t == "comment" or t == "comment-block" then
    local prev = M.get_previous_element(datum, info)
    if prev then
      prev.post_blank = math.max(prev.post_blank or 0, datum.post_blank or 0, 1)
    end
    return true
  elseif t == "clock" then
    return not info.with_clocks
  elseif t == "drawer" then
    local w = info.with_drawers
    if not w then
      return true
    end
    if type(w) == "table" then
      local name = datum.drawer_name
      if w.negate then
        return member_ci(name, w)
      end
      return not member_ci(name, w)
    end
    return false
  elseif t == "fixed-width" then
    return not info.with_fixed_width
  elseif t == "footnote-definition" or t == "footnote-reference" then
    return not info.with_footnotes
  elseif t == "headline" or t == "inlinetask" then
    local tasks = info.with_tasks
    local todo = datum.todo_keyword
    if t == "inlinetask" and not info.with_inlinetasks then
      return true
    end
    for _, tag in ipairs(M.get_tags(datum, info, nil, true)) do
      if excluded[tag] then
        return true
      end
    end
    if selected and not selected[datum] then
      return true
    end
    if datum.commentedp then
      return true
    end
    if not info.with_archived_trees and datum.archivedp then
      return true
    end
    if todo then
      if not tasks then
        return true
      end
      if (tasks == "todo" or tasks == "done") and datum.todo_type ~= tasks then
        return true
      end
      if type(tasks) == "table" and not vim.tbl_contains(tasks, todo) then
        return true
      end
    end
    return false
  elseif t == "latex-environment" or t == "latex-fragment" then
    return not info.with_latex
  elseif t == "node-property" then
    local set = info.with_properties
    if not set then
      return true
    end
    if type(set) == "table" then
      return not member_ci(datum.key, set)
    end
    return false
  elseif t == "planning" then
    return not info.with_planning
  elseif t == "property-drawer" then
    return not info.with_properties
  elseif t == "statistics-cookie" then
    return not info.with_statistics_cookies
  elseif t == "table" then
    return not info.with_tables
  elseif t == "table-cell" then
    local tbl = element.lineage(datum, "table")
    return M.table_has_special_column_p(tbl) and datum.parent.contents[1] == datum
  elseif t == "table-row" then
    if info.with_special_rows then
      return false
    end
    return M.table_row_is_special_p(datum, info)
  elseif t == "timestamp" then
    local parent = element.parent_element(datum)
    if parent and (parent.type == "paragraph" or parent.type == "verse-block") then
      local only = true
      for _, c in ipairs(parent.contents) do
        if c.type == "plain-text" then
          if c.value:find("[^ \t\n\r]") then
            only = false
          end
        elseif c.type ~= "timestamp" then
          only = false
        end
      end
      if only then
        return skip_timestamp_p(info.with_timestamps, datum.ts_type)
      end
    end
    return false
  end
  return false
end

function M.prune_tree(data, info)
  local ignore = {}
  local selected = M.selected_trees(data, info)
  local excluded = {}
  for _, t in ipairs(info.exclude_tags or {}) do
    excluded[t] = true
  end
  local function walk(d)
    if d == nil then
      return
    end
    if d.type == nil then
      local copy = {}
      for _, x in ipairs(d) do
        copy[#copy + 1] = x
      end
      for _, x in ipairs(copy) do
        walk(x)
      end
      return
    end
    local t = d.type
    if M.skip_p(d, info, selected, excluded) then
      if t == "table-cell" or t == "table-row" then
        ignore[d] = true
      else
        local ks = keep_spaces(d, info)
        if ks then
          -- replace by the spaces
          local sib = element.siblings(d)
          for i, x in ipairs(sib or {}) do
            if x == d then
              sib[i] = element.text(ks, d.parent)
            end
          end
        else
          element.extract(d)
        end
      end
    else
      if t == "headline" and info.with_archived_trees == "headline" and d.archivedp then
        d.contents = {}
      else
        local copy = {}
        for _, x in ipairs(d.contents or {}) do
          copy[#copy + 1] = x
        end
        for _, x in ipairs(copy) do
          walk(x)
        end
      end
      if d.title then
        walk(d.title)
      end
      if d.tag then
        walk(d.tag)
      end
    end
  end
  -- collect definitions before pruning
  local definitions = {}
  element.map(data, { ["footnote-definition"] = true, ["footnote-reference"] = true }, function(f)
    if f.type == "footnote-definition" or (f.fn_type == "inline" and f.label) then
      definitions[#definitions + 1] = f
    end
  end)
  if selected then
    local first = data.contents[1]
    if first and first.type == "section" then
      element.extract(first)
    end
  end
  walk(data)
  -- parsed options
  for _, key in ipairs({ "title", "date", "author", "subtitle" }) do
    if type(info[key]) == "table" then
      walk(info[key])
    end
  end
  -- missing footnote definitions
  local missing = M.missing_definitions(data, definitions)
  for _, d in ipairs(missing) do
    walk(d)
  end
  M.install_footnote_definitions(missing, data)
  info.ignore = ignore
end

function M.missing_definitions(tree, definitions)
  local function labels_in(d)
    return element.map(d, "footnote-reference", function(r)
      if r.fn_type == "standard" then
        return r.label
      end
    end)
  end
  local known = {}
  element.map(tree, { ["footnote-reference"] = true, ["footnote-definition"] = true }, function(f)
    if f.type == "footnote-definition" or f.fn_type == "inline" then
      if f.label then
        known[f.label] = true
      end
    end
  end)
  local defined, undefined = {}, {}
  for _, l in ipairs(labels_in(tree)) do
    if known[l] then
      defined[l] = true
    else
      undefined[#undefined + 1] = l
    end
  end
  local missing = {}
  local queued = {}
  for _, l in ipairs(undefined) do
    queued[l] = true
  end
  while #undefined > 0 do
    local label = table.remove(undefined, 1)
    if not defined[label] then
      local def
      for _, d in ipairs(definitions) do
        if d.label == label then
          def = d
          break
        end
      end
      if not def then
        error("Definition not found for footnote " .. label, 0)
      end
      defined[label] = true
      missing[#missing + 1] = def
      for _, l in ipairs(labels_in(def)) do
        if not defined[l] and not queued[l] then
          queued[l] = true
          undefined[#undefined + 1] = l
        end
      end
    end
  end
  local out = {}
  for _, d in ipairs(missing) do
    if d.type == "footnote-definition" then
      out[#out + 1] = d
    else
      local nd = element.node("footnote-definition", { label = d.label, post_blank = 1 })
      nd.contents = d.contents
      for _, c in ipairs(nd.contents) do
        c.parent = nd
      end
      out[#out + 1] = nd
    end
  end
  return out
end

function M.install_footnote_definitions(definitions, tree)
  if #definitions == 0 then
    return
  end
  local section = element.map(tree, "headline", function(h)
    if h.footnote_section_p then
      return h
    end
  end, { first_match = true })
  if section then
    element.adopt(section, definitions)
    return
  end
  local seen = {}
  local function insert(data)
    element.map(data, "footnote-reference", function(ref)
      if ref.fn_type == "standard" and not seen[ref.label] then
        seen[ref.label] = true
        for _, d in ipairs(definitions) do
          if d.label == ref.label then
            local sec = element.lineage(ref, "section")
            if sec then
              element.adopt(sec, { d })
            end
            insert(d)
            break
          end
        end
      end
    end)
  end
  insert(tree)
end

--- Change uninterpreted elements back into Org syntax
--- (org-export--remove-uninterpreted-data).
function M.remove_uninterpreted(data, info)
  local types = {
    entity = true,
    bold = true,
    italic = true,
    ["latex-environment"] = true,
    ["latex-fragment"] = true,
    ["strike-through"] = true,
    subscript = true,
    superscript = true,
    underline = true,
  }
  local todo = {}
  element.map(data, types, function(d)
    todo[#todo + 1] = d
  end, { with_affiliated = true })
  for _, d in ipairs(todo) do
    local t = d.type
    local pb = d.post_blank or 0
    local blank = string.rep(t == "latex-environment" and "\n" or " ", pb)
    local new
    if t == "entity" then
      if not info.with_entities then
        new = { element.text(element.interpret(d):gsub(" +$", "") .. blank) }
        new[1].value = "\\" .. d.name .. (d.use_brackets and "{}" or "") .. blank
      end
    elseif t == "bold" or t == "italic" or t == "strike-through" or t == "underline" then
      if not info.with_emphasize then
        local m = ({ bold = "*", italic = "/", ["strike-through"] = "+", underline = "_" })[t]
        new = { element.text(m) }
        vim.list_extend(new, d.contents)
        new[#new + 1] = element.text(m .. blank)
      end
    elseif t == "latex-environment" or t == "latex-fragment" then
      if info.with_latex == "verbatim" then
        new = { element.text(d.value .. blank) }
      end
    elseif t == "subscript" or t == "superscript" then
      local ss = info.with_sub_superscript
      if not ss or (ss == "{}" and not d.use_brackets) then
        new = { element.text((t == "subscript" and "_" or "^") .. (d.use_brackets and "{" or "")) }
        vim.list_extend(new, d.contents)
        new[#new + 1] = element.text((d.use_brackets and "}" or "") .. blank)
      end
    end
    if new then
      local sib = element.siblings(d)
      if sib then
        for i, x in ipairs(sib) do
          if x == d then
            table.remove(sib, i)
            local k = i
            for _, e in ipairs(new) do
              if not (e.type == "plain-text" and e.value == "") then
                e.parent = d.parent
                table.insert(sib, k, e)
                k = k + 1
              end
            end
            break
          end
        end
      end
    end
  end
  -- merge adjacent plain text nodes (like buffer text)
  element.map(data, "*", function(d)
    for _, key in ipairs({ "contents", "title", "tag" }) do
      local list = d[key]
      if type(list) == "table" and d.type ~= "plain-text" then
        local i = 1
        while i < #list do
          if list[i].type == "plain-text" and list[i + 1].type == "plain-text" then
            list[i].value = list[i].value .. list[i + 1].value
            table.remove(list, i + 1)
          else
            i = i + 1
          end
        end
      end
    end
  end)
  return data
end

---------------------------------------------------------------------------
-- Tree properties
---------------------------------------------------------------------------

function M.collect_tree_properties(data, info)
  info.parse_tree = data
  local min = 10000
  for _, d in ipairs(data.contents) do
    if d.type == "headline" and not d.footnote_section_p and not info.ignore[d] then
      min = math.min(min, d.level)
    end
  end
  if min == 10000 then
    min = 1
  end
  info.headline_offset = 1 - min
  local numbering = {}
  local counters = {}
  for k = 1, 20 do
    counters[k] = 0
  end
  element.map(data, "headline", function(h)
    if M.numbered_headline_p(h, info) and not h.footnote_section_p then
      local rel = M.get_relative_level(h, info)
      local out = {}
      for idx = 1, 20 do
        if idx < rel then
          out[#out + 1] = counters[idx]
        elseif idx == rel then
          counters[idx] = counters[idx] + 1
          out[#out + 1] = counters[idx]
        else
          counters[idx] = 0
        end
      end
      numbering[h] = out
    end
  end, { ignore = info.ignore })
  info.headline_numbering = numbering
end

---------------------------------------------------------------------------
-- Export
---------------------------------------------------------------------------

--- Lines of the subtree at `line` for export: { lines, props, title }.
local function subtree_region(lines, line, todo)
  local parser = require("org.parser")
  local s = math.min(line, #lines)
  while s >= 1 and not lines[s]:match("^%*+ ") do
    s = s - 1
  end
  if s < 1 then
    return nil
  end
  local parts = parser.parse_headline_line(lines[s], todo)
  local level = parts.level
  local e = s + 1
  while e <= #lines do
    local st = lines[e]:match("^(%*+) ")
    if st and #st <= level then
      break
    end
    e = e + 1
  end
  -- the export starts after the planning line and the property drawer
  local b = s + 1
  local props = {}
  local kw = lines[b] and lines[b]:match("^[ \t]*(%u+):")
  if kw == "SCHEDULED" or kw == "DEADLINE" or kw == "CLOSED" then
    b = b + 1
  end
  if lines[b] and lines[b]:match("^[ \t]*:[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Ii][Ee][Ss]:[ \t]*$") then
    local k = b + 1
    while k < e and not lines[k]:match("^[ \t]*:[Ee][Nn][Dd]:[ \t]*$") do
      local key, value = lines[k]:match("^[ \t]*:(%S+):[ \t]*(.-)[ \t]*$")
      if key then
        props[key:upper()] = value
      end
      k = k + 1
    end
    b = k + 1
  end
  return { lines = vim.list_slice(lines, b, e - 1), props = props, title = parts.title, line = s }
end

--- Hidden lines of a buffer's current window (closed folds), for
--- visible-only export.
function M.visible_lines(bufnr, lines)
  local win
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      win = w
      break
    end
  end
  if not win then
    return lines
  end
  local out = {}
  vim.api.nvim_win_call(win, function()
    local i = 1
    while i <= #lines do
      local fc = vim.fn.foldclosed(i)
      if fc == -1 then
        out[#out + 1] = lines[i]
        i = i + 1
      else
        -- a folded headline stays visible, its contents are hidden
        if lines[i]:match("^%*+ ") then
          out[#out + 1] = lines[i]
        end
        i = vim.fn.foldclosedend(i) + 1
      end
    end
  end)
  return out
end

--- Export Org lines to a string with `backend`.
---@param backend string|table
---@param lines string[]
---@param opts? table { filename, bufnr, subtree_line, body_only, visible_only, ext, hooks }
---@return string output, table info
function M.export_as(backend, lines, opts)
  opts = opts or {}
  backend = M.get_backend(backend)
  if not backend then
    error("Unknown export back-end", 0)
  end
  local c = cfg()
  local parser_mod = require("org.parser")
  local filename = opts.filename
  local dir = filename and vim.fn.fnamemodify(filename, ":p:h") or vim.fn.getcwd()
  local file0 = parser_mod.parse(lines, filename)
  local todo = file0.settings.todo
  local hooks = c.hooks or {}
  -- before-processing hook (org-export-before-processing-functions)
  for _, f in ipairs(M.as_list(hooks.before_processing)) do
    local r = f(backend.name, lines)
    if type(r) == "table" then
      lines = r
    end
  end
  -- keywords are read from the whole buffer
  local keywords = M.collect_keywords(lines, dir)
  local subtree
  if opts.subtree_line then
    subtree = subtree_region(lines, opts.subtree_line, todo)
  end
  local work = subtree and subtree.lines or lines
  if opts.visible_only and opts.bufnr and not subtree then
    work = M.visible_lines(opts.bufnr, work)
  end
  local expand_env = true
  work = M.expand_includes(work, dir, { includer = filename, expand_env = expand_env, todo = todo })
  work = M.delete_comment_trees(work, todo)
  -- Babel
  local babel_cfg = require("org.config").opts.babel or {}
  if babel_cfg.evaluate_on_export and not opts.no_babel then
    local ok, res = pcall(function()
      return require("org.babel").export_evaluate(opts.bufnr, work)
    end)
    if ok and type(res) == "table" then
      work = res
    end
    work = M.babel_process(work, { filename = filename })
  end
  -- before-parsing hook
  for _, f in ipairs(M.as_list(hooks.before_parsing)) do
    local r = f(backend.name, work)
    if type(r) == "table" then
      work = r
    end
  end
  -- radio targets
  local radio = {}
  for _, l in ipairs(work) do
    for r in l:gmatch("<<<([^<>\n]-)>>>") do
      radio[#radio + 1] = r
    end
  end
  local link_types = vim.deepcopy(element.DEFAULT_LINK_TYPES)
  local extra_types = {}
  for t in pairs((require("org.config").opts.links or {}).types or {}) do
    extra_types[t] = true
  end
  local abbrevs = vim.tbl_extend(
    "force",
    (require("org.config").opts.links or {}).abbreviations or {},
    file0.settings.link_abbrevs or {}
  )
  local ctx = { keywords = keywords, filename = filename }
  local expander = M.macro_expander(ctx)
  local popts = {
    todo = todo,
    link_types = link_types,
    extra_link_types = extra_types,
    abbrevs = abbrevs,
    radio = radio,
    macro = expander,
    footnote_section = c.footnote_section or require("org.config").opts.footnote_section,
    inlinetask_min_level = c.inlinetask_min_level or 15,
    alpha = require("org.config").opts.lists and require("org.config").opts.lists.allow_alphabetical or false,
  }
  local parser = element.new(popts)
  -- {{{property(NAME[,search])}}}: the headline being parsed, or a searched one
  local pfile
  ctx.property_lookup = function(name, loc, p)
    if loc and M.nw(loc) then
      pfile = pfile or parser_mod.parse(work, filename)
      loc = trim(loc)
      local hl
      if loc:match("^#") then
        hl = pfile:find_by_custom_id(loc:sub(2))
      elseif loc:match("^id:") then
        hl = pfile:find_by_id(loc:sub(4))
      else
        local t = trim((loc:gsub("^%*", "")))
        hl = pfile:find_headline(function(h)
          return h:plain_title() == t
        end)
      end
      if not hl then
        error("Macro property failed: cannot find location " .. loc, 0)
      end
      if name == "ITEM" then
        return hl:plain_title()
      end
      return hl:get_property(name, false)
    end
    local h = p and p.current_headline
    if h then
      if name == "ITEM" then
        return h.raw_value
      elseif name == "TODO" then
        return h.todo_keyword
      elseif name == "PRIORITY" then
        return h.priority
      end
      return h.props and h.props[name]
    end
    return file0.settings.properties[name]
  end
  local function parse_secondary(s)
    return parser:parse_objects(s, element.RESTRICTIONS.keyword)
  end
  local info = M.environment({
    keywords = keywords,
    backend = backend,
    subtree_props = subtree and subtree.props or nil,
    subtree_title = subtree and subtree.title or nil,
    ext = opts.ext,
    parse_secondary = parse_secondary,
  })
  info.back_end = backend
  info.translate = M.all_transcoders(backend)
  info.exported_data = {}
  info.export_options = { subtree = subtree ~= nil, body_only = opts.body_only, visible_only = opts.visible_only }
  info.input_file = filename
  info.input_buffer = opts.bufnr
  info.keywords = keywords
  info.parser = parser
  info.internal_references = { n = 0, used = {}, by_datum = {} }
  info.table_header_cache = {}
  info.table_row_group_cache = {}
  info.table_cell_width_cache = {}
  info.table_cell_alignment_cache = {}
  info.smart_quote_cache = {}
  info.subtree_props = subtree and subtree.props or nil
  info.todo_done = function(k)
    return todo:is_done(k)
  end
  info.options_filters = {}
  -- filters: back-end first, then user filters (config export.filters)
  local filters = M.all_filters(backend)
  for k, v in pairs(c.filters or {}) do
    filters[k] = filters[k] or {}
    vim.list_extend(filters[k], M.as_list(v))
  end
  -- also accept keys with underscores (plain_text) for hyphenated types
  local norm = {}
  for k, v in pairs(filters) do
    norm[k:gsub("_", "-")] = v
  end
  info.filters = norm
  -- citations: bibliography and processor
  local cite_ok, cite = pcall(require, "org.export.cite")
  if not cite_ok then
    cite = nil
  end
  if info.with_cite_processors and cite then
    cite.store(info)
  end
  -- options filters
  for _, f in ipairs(info.filters.options or {}) do
    local r = f(info, backend.name)
    if type(r) == "table" then
      info = r
    end
  end
  -- parse
  local tree = parser:parse(work)
  -- ALT_TITLE
  element.map(tree, { headline = true, inlinetask = true }, function(h)
    if h.props and h.props.ALT_TITLE then
      h.alt_title = parser:parse_objects(h.props.ALT_TITLE, element.RESTRICTIONS.headline, h)
    end
  end)
  M.prune_tree(tree, info)
  M.remove_uninterpreted(tree, info)
  for _, key in ipairs({ "title", "date", "author", "subtitle" }) do
    if type(info[key]) == "table" and info[key].type == nil then
      M.remove_uninterpreted(info[key], info)
    end
  end
  if info.expand_links then
    element.map(tree, "link", function(l)
      if l.link_type == "file" then
        l.path = M.expand_env(l.path)
      end
    end, { with_affiliated = true })
  end
  tree = apply_filters(info.filters["parse-tree"], tree, info)
  M.collect_tree_properties(tree, info)
  if info.with_cite_processors and cite then
    cite.process(info)
  end
  -- transcode
  local body = M.normalize_string(M.data(tree, info) or "") or ""
  local inner = info.translate.inner_template
  local full = apply_filters(info.filters.body, inner and inner(body, info) or body, info)
  local template = info.translate.template
  local output = (template and not opts.body_only) and template(full, info) or full
  if info.with_cite_processors and cite then
    output = cite.finalize(output, info)
  end
  output = apply_filters(info.filters["final-output"], output, info)
  return output, info
end

function M.as_list(v)
  if v == nil then
    return {}
  end
  if type(v) == "function" then
    return { v }
  end
  return v
end

return M
