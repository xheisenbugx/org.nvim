---@mod org.columns Column view
---
--- `open()` shows headlines and their properties as a table in a split.
--- The format comes from the nearest COLUMNS property, `#+COLUMNS:`, or
--- `columns_default_format`. Summary operators: {+} {$} {:} {X} {X/} {X%}
--- {min} {max} {mean} {:min} {:max} {:mean} {@min} {@max} {@mean} {est+}
--- (optionally with a format, `{+;%.2f}`).

local config = require("org.config")
local date = require("org.date")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.columns")

--- Special properties: computed, never summarized nor set in a drawer.
M.SPECIAL = {
  ITEM = true,
  TODO = true,
  PRIORITY = true,
  TAGS = true,
  ALLTAGS = true,
  CATEGORY = true,
  LEVEL = true,
  FILE = true,
  SCHEDULED = true,
  DEADLINE = true,
  CLOSED = true,
  TIMESTAMP = true,
  TIMESTAMP_IA = true,
  CLOCKSUM = true,
  CLOCKSUM_T = true,
  BLOCKED = true,
}

--- Summary operators (Emacs org-columns-summary-types-default).
M.SUMMARY_TYPES = {
  "+",
  "$",
  "X",
  "X/",
  "X%",
  "max",
  "mean",
  "min",
  ":",
  ":max",
  ":mean",
  ":min",
  "@max",
  "@mean",
  "@min",
  "est+",
}

--- Parse a column format string.
---@return { width?: integer, prop: string, title: string, summary?: string, summary_fmt?: string }[]
function M.parse_format(fmt)
  local cols = {}
  local specs = {}
  for tok in (fmt or ""):gmatch("%S+") do
    if tok:sub(1, 1) == "%" or #specs == 0 then
      specs[#specs + 1] = tok
    else
      specs[#specs] = specs[#specs] .. " " .. tok
    end
  end
  for _, spec in ipairs(specs) do
    local width, rest = spec:match("^%%(%d*)(.*)$")
    local prop = rest:match("^([%w_%-]+)")
    if prop then
      rest = rest:sub(#prop + 1)
      local title = rest:match("^%(([^%)]*)%)")
      if title then
        rest = rest:sub(#title + 3)
      end
      local summary = rest:match("^{([^}]*)}")
      local sfmt
      if summary then
        summary, sfmt = summary:match("^([^;]*);?(.*)$")
        if sfmt == "" then
          sfmt = nil
        end
      end
      cols[#cols + 1] = {
        width = tonumber(width),
        prop = prop,
        title = title or prop,
        summary = summary,
        summary_fmt = sfmt,
      }
    end
  end
  return cols
end

--- Raw value of a column for a headline (Emacs org-entry-get with
--- selective inheritance). LEVEL is an ordinary property here, like Emacs.
function M.value(hl, prop)
  local key = prop:upper()
  if key == "ITEM" then
    return hl.title
  elseif key == "TODO" then
    return hl.todo or ""
  elseif key == "PRIORITY" then
    return hl.priority or hl.file:priorities().default
  elseif key == "TAGS" then
    return #hl.tags > 0 and (":" .. table.concat(hl.tags, ":") .. ":") or ""
  elseif key == "LEVEL" then
    return hl.properties.LEVEL or ""
  elseif key == "CLOCKSUM" or key == "CLOCKSUM_T" then
    -- time clocked in the subtree (CLOCKSUM_T: today only), org-duration style
    local from, to
    if key == "CLOCKSUM_T" then
      from, to = require("org.clock").special_range("today")
    end
    local m = require("org.clock").sum_minutes(hl, from, to)
    return m > 0 and date.duration_to_string(m) or ""
  end
  return hl:get_property(prop) or ""
end

local function formula()
  return require("org.table.formula")
end

--- Age in minutes as "Nd Nh Nmin" (zero parts dropped), like Emacs'
--- org-columns--format-age.
function M.format_age(minutes)
  minutes = math.floor(minutes + 0.5)
  local d, h, m = math.floor(minutes / 1440), math.floor(minutes % 1440 / 60), minutes % 60
  local parts = {}
  if d > 0 then
    parts[#parts + 1] = d .. "d"
  end
  if h > 0 then
    parts[#parts + 1] = h .. "h"
  end
  if m > 0 or #parts == 0 then
    parts[#parts + 1] = m .. "min"
  end
  return table.concat(parts, " ")
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

--- Whether every value is an H:MM duration (org-duration-h:mm-only-p).
local function hmm_only(values)
  for _, v in ipairs(values) do
    if not vim.trim(v):match("^%d+:%d%d$") and not vim.trim(v):match("^%d+:%d%d:%d%d$") then
      return false
    end
  end
  return true
end

--- Age in minutes of a timestamp or duration (org-columns--age-to-minutes).
local function age_minutes(v)
  local d = date.parse(v)
  if d then
    return os.time() / 60 - d:to_time() / 60
  end
  return date.parse_duration(v) or 0
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
    return date.duration_to_string(s, hmm_only(values) and "h:mm" or nil)
  end,
  [":min"] = function(values)
    local r
    for _, v in ipairs(values) do
      r = math.min(r or math.huge, duration_minutes(v))
    end
    return date.duration_to_string(r, hmm_only(values) and "h:mm" or nil)
  end,
  [":max"] = function(values)
    local r
    for _, v in ipairs(values) do
      r = math.max(r or -math.huge, duration_minutes(v))
    end
    return date.duration_to_string(r, hmm_only(values) and "h:mm" or nil)
  end,
  [":mean"] = function(values)
    local s = 0
    for _, v in ipairs(values) do
      s = s + duration_minutes(v)
    end
    return date.duration_to_string(s / #values, hmm_only(values) and "h:mm" or nil)
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
      else
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
  local summaries = {} -- hl -> { [i] = summary }
  local seen_prop = {}
  for i, col in ipairs(cols) do
    local key = col.prop:upper()
    local fn, collect
    if col.summary and not M.SPECIAL[key] then
      fn, collect = summary_type(col.summary)
    end
    local update = opts.update and not seen_prop[key]
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
        local own = collect and collect(hl, col.prop) or M.value(hl, col.prop)
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
        elseif own ~= "" then
          return own
        end
      end
      for _, r in ipairs(roots) do
        walk(r)
      end
    end
  end
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
--- whose COLUMNS property defines the format (nil for the file format).
local function scope_for(file, lnum)
  local hl = lnum and file:headline_at(lnum)
  local p = hl
  while p do
    if p.properties.COLUMNS then
      return p.properties.COLUMNS, { p }, p
    end
    p = p.parent
  end
  return file.settings.columns or config.opts.columns_default_format, file.children
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

---------------------------------------------------------------------------
-- Dynamic block writer
---------------------------------------------------------------------------

--- Tag/property matcher for `:match`, or nil.
local function matcher(match)
  if type(match) ~= "string" or match == "" then
    return nil
  end
  local ok, pred = pcall(require("org.agenda.search").compile, match)
  if not ok then
    error("invalid :match " .. match)
  end
  return pred
end

--- Tags listed in `:exclude-tags` ("(a b)" or "a b").
local function tag_list(v)
  if type(v) ~= "string" then
    return {}
  end
  local out = {}
  for t in v:gsub('[()"]', " "):gmatch("%S+") do
    out[#out + 1] = t
  end
  return out
end

--- A headline title without the objects that cannot be copied into a
--- table: statistics cookies, footnote references, targets, radio
--- targets, inline src blocks and babel calls; `|` becomes `\vert{}`.
--- Emacs org-columns--clean-item.
function M.clean_item(item)
  local s = item
  s = s:gsub("%s*%[%d*%%%]", ""):gsub("%s*%[%d*/%d*%]", "")
  s = s:gsub("%s*%[fn:[^%]]*%]", "")
  s = s:gsub("%s*<<<[^>]*>>>", ""):gsub("%s*<<[^>]*>>", "")
  s = s:gsub("%s*src_[%w%-]+%b[]%b{}", ""):gsub("%s*src_[%w%-]+%b{}", "")
  s = s:gsub("%s*call_[%w%-_]+%b[]%b()%b[]", ""):gsub("%s*call_[%w%-_]+%b()%b[]", "")
  s = s:gsub("%s*call_[%w%-_]+%b[]%b()", ""):gsub("%s*call_[%w%-_]+%b()", "")
  return (vim.trim(s):gsub("|", "\\vert{}"))
end

--- Search string of a heading link (org-link-heading-search-string).
local function heading_search(title)
  local t = title:gsub("%[%d*%%%]", " "):gsub("%[%d*/%d*%]", " "):gsub("[ \t]+", " ")
  return "*" .. vim.trim(t)
end

--- The rows captured for a columnview block, like Emacs
--- org-columns--capture-view: the titles, "hline", then for every entry
--- `{ level = n, hl = headline, cells... }` (display values; ITEM raw).
local function capture(rows, cols, params)
  local pred = matcher(params.match)
  local exclude = tag_list(params["exclude-tags"])
  local has_item = false
  for _, c in ipairs(cols) do
    has_item = has_item or c.prop:upper() == "ITEM"
  end
  local titles = {}
  for i, c in ipairs(cols) do
    titles[i] = c.title
  end
  local out = { titles, "hline" }
  for _, r in ipairs(rows) do
    local row = { level = r.hl.level, hl = r.hl, rel_level = r.rel_level }
    local distinct = {}
    for i, c in ipairs(cols) do
      row[i] = c.prop:upper() == "ITEM" and r.cells[i] or r.display[i]
      if row[i] ~= "" then
        distinct[row[i]] = true
      end
    end
    local n = vim.tbl_count(distinct)
    local empty = n == 0 or (has_item and n == 1)
    local excluded = false
    if #exclude > 0 then
      local tags = r.hl:get_tags()
      for _, t in ipairs(exclude) do
        excluded = excluded or vim.tbl_contains(tags, t)
      end
    end
    if
      not r.hl:is_hidden_by_ancestor()
      and not (params["skip-empty-rows"] and empty)
      and not excluded
      and (not pred or pred(r.hl))
    then
      out[#out + 1] = row
    end
  end
  return out
end

--- The default columnview writer (org-columns-dblock-write-default): the
--- rows as table lines, with hlines, indented and linked items, column
--- groups and a width cookie row when the format has widths.
local function write_default(captured, cols, params, file)
  local item_index
  for i, c in ipairs(cols) do
    if c.prop:upper() == "ITEM" and not item_index then
      item_index = i
    end
  end
  local hlines, indent = params.hlines, params.indent and params.indent ~= false
  local out = { captured[1], "hline" }
  for k = 3, #captured do
    local row = captured[k]
    local level = row.rel_level or row.level
    if out[#out] ~= "hline" and (hlines == true or (type(hlines) == "number" and row.level <= hlines)) then
      out[#out + 1] = "hline"
    end
    local cells = {}
    for i = 1, #cols do
      cells[i] = row[i] or ""
    end
    if item_index then
      local raw = cells[item_index]
      local item = M.clean_item(raw)
      if params.link then
        local search = heading_search(raw)
        local target = file.filename and ("file:" .. file.filename .. "::" .. search) or search
        -- org-link-make-string escapes brackets in the link
        item = "[[" .. target:gsub("[%[%]]", "\\%0") .. "][" .. item .. "]]"
      end
      if indent and level > 1 then
        item = "\\_" .. string.rep(" ", 2 * (level - 1)) .. item
      end
      cells[item_index] = item
    end
    for i, v in ipairs(cells) do
      if i ~= item_index then
        cells[i] = v:gsub("|", "\\vert{}")
      end
    end
    out[#out + 1] = cells
  end
  if params.vlines then
    for i, row in ipairs(out) do
      if row ~= "hline" then
        out[i] = vim.list_extend({ "" }, row)
      end
    end
    local groups = { "/" }
    for _ = 1, #cols do
      groups[#groups + 1] = "<>"
    end
    out[#out + 1] = groups
  end
  local widths, any = {}, false
  for i, c in ipairs(cols) do
    widths[i] = c.width and ("<" .. c.width .. ">") or ""
    any = any or c.width ~= nil
  end
  if any then
    table.insert(out, 1, widths)
  end
  return out, any
end

function M.dblock(params, ctx)
  local file = files.get_buffer(ctx.bufnr)
  local id = params.id
  local roots, fmt
  if id == "local" or id == nil then
    local hl = file:headline_at(ctx.start_line)
    fmt, roots = scope_for(file, ctx.start_line)
    if hl then
      roots = { hl }
    end
  elseif type(id) == "string" and id:match("^file:") then
    local path = utils.expand(id:sub(6), file.filename and vim.fn.fnamemodify(file.filename, ":h") or nil)
    local f = files.get(path)
    if not f then
      return { "# file not found: " .. path }
    end
    file = f
    fmt, roots = scope_for(f, nil)
  elseif type(id) == "string" and id ~= "global" then
    local found
    for _, f in ipairs(files.agenda_files_with_current()) do
      found = f:find_by_id(id) or f:find_by_custom_id(id)
      if found then
        break
      end
    end
    if not found then
      return { "# no entry with ID " .. id }
    end
    file = found.file
    fmt, roots = scope_for(found.file, found.line)
    roots = { found }
  else
    fmt, roots = scope_for(file, nil)
  end
  if params.format then
    fmt = params.format
  end
  local cols = M.parse_format(fmt)
  local rows = M.compute(roots, cols, { maxlevel = tonumber(params.maxlevel), update = true })
  local captured = capture(rows, cols, params)
  -- :formatter (a global Lua function name) or columns_dblock_formatter
  local formatter = params.formatter
  if type(formatter) == "string" then
    formatter = _G[formatter] or error("unknown :formatter " .. formatter)
  end
  formatter = formatter or config.opts.columns_dblock_formatter
  if type(formatter) == "function" then
    return formatter(captured, params)
  end
  local out, has_widths = write_default(captured, cols, params, file)
  -- Like Emacs, keep the keywords (#+NAME: ...) above the table and the
  -- #+TBLFM lines below it, and recalculate.
  local tbl = require("org.table")
  local keywords, tblfm = {}, {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(ctx.bufnr, ctx.start_line, ctx.end_line - 1, false)) do
    if tbl.is_tblfm(l) then
      tblfm[#tblfm + 1] = vim.trim(l)
    elseif l:match("^%s*#%+") and #tblfm == 0 and not tbl.is_table_line(l) then
      keywords[#keywords + 1] = vim.trim(l)
    end
  end
  local lines = require("org.clock").format_table(out)
  if #tblfm > 0 then
    lines = tbl.recalc_lines(ctx.bufnr, lines, tblfm, ctx.start_line)
  end
  if has_widths then
    -- shrink the columns once the block is written (org-table-shrink)
    local bufnr, start = ctx.bufnr, ctx.start_line + #keywords + 1
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(tbl.shrink, bufnr, start)
      end
    end)
  end
  return vim.list_extend(vim.list_extend(keywords, lines), tblfm)
end

---------------------------------------------------------------------------
-- Interactive view
---------------------------------------------------------------------------

--- Source line of the view's anchor (follows edits in the source buffer).
local function anchor_line(state)
  local pos = vim.api.nvim_buf_get_extmark_by_id(state.src, ns, state.mark, {})
  return (pos[1] or 0) + 1
end

--- Text of cell `i` of row `r` in the view: the displayed value; ITEM
--- with its stars and links shown as their descriptions.
local function view_text(r, i, col)
  local v = r.display[i] or ""
  if col.prop:upper() == "ITEM" and v == r.cells[i] then
    v = v:gsub("%[%[([^%]]-)%]%[(.-)%]%]", "%2"):gsub("%[%[([^%]]-)%]%]", "%1")
    v = string.rep("*", r.hl.level) .. " " .. v
  end
  return v
end

local function render(state)
  local file = files.get_buffer(state.src)
  local fmt, roots, holder = scope_for(file, anchor_line(state))
  state.holder = holder
  state.cols = M.parse_format(fmt)
  -- like Emacs, summaries are written back to existing properties
  local rows = M.compute(roots, state.cols, { update = true })
  state.rows = rows
  local widths = {}
  for i, c in ipairs(state.cols) do
    local w = utils.width(c.title)
    for _, r in ipairs(rows) do
      w = math.max(w, utils.width(view_text(r, i, c)))
    end
    widths[i] = c.width and math.max(c.width, 1) or math.min(w, 60)
  end
  state.widths = widths
  local function line_for(cells)
    local parts = {}
    for i, v in ipairs(cells) do
      parts[i] = utils.pad_right(utils.truncate(v, widths[i]), widths[i])
    end
    return table.concat(parts, " │ ")
  end
  local header = {}
  for i, c in ipairs(state.cols) do
    header[i] = c.title
  end
  local lines = { line_for(header) }
  local sep = {}
  for i = 1, #widths do
    sep[i] = string.rep("─", widths[i])
  end
  lines[2] = table.concat(sep, "─┼─")
  for _, r in ipairs(rows) do
    local cells = {}
    for i, c in ipairs(state.cols) do
      cells[i] = view_text(r, i, c)
    end
    lines[#lines + 1] = line_for(cells)
  end
  local buf = state.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = #lines[1], hl_group = "Title" })
  vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { end_col = #lines[2], hl_group = "Comment" })
  for i, r in ipairs(rows) do
    local grp = "OrgHeadlineLevel" .. (((r.hl.level - 1) % 8) + 1)
    local end_col = math.min(#lines[i + 2], widths[1] + 3)
    vim.api.nvim_buf_set_extmark(buf, ns, i + 1, 0, { end_col = end_col, hl_group = grp })
  end
end

--- Row and column index under the cursor (in the view window).
local function current(state)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local r = state.rows[row - 2]
  if not r then
    return nil
  end
  -- column index from byte offset
  local line = vim.api.nvim_get_current_line()
  local prefix = line:sub(1, col)
  local _, seps = prefix:gsub("│", "")
  return r, math.min(seps + 1, #state.cols)
end

--- Put the cursor on view line `lnum`, column `ci`.
local function goto_cell(state, lnum, ci)
  lnum = math.max(1, math.min(lnum, vim.api.nvim_buf_line_count(state.buf)))
  local line = vim.api.nvim_buf_get_lines(state.buf, lnum - 1, lnum, false)[1] or ""
  local col, n = 0, 1
  while n < ci do
    local _, e = line:find("│", col + 1, true)
    if not e then
      break
    end
    col, n = e + 1, n + 1
  end
  vim.api.nvim_win_set_cursor(0, { lnum, col })
end

--- Re-render, keeping the cursor on its line, in column `ci`.
local function refresh(state, ci)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local _, cur_ci = current(state)
  render(state)
  goto_cell(state, lnum, ci or cur_ci or 1)
end

--- Write a column format back: to the COLUMNS property that defines the
--- view, else the first `#+COLUMNS:` line, else a new `#+COLUMNS:` line
--- before the first heading. Emacs org-columns-store-format.
local function store_format(state, cols)
  local fmt = M.format_string(cols)
  if state.holder then
    require("org.edit").set_property(state.src, state.holder.line, "COLUMNS", fmt)
    return
  end
  local lines = vim.api.nvim_buf_get_lines(state.src, 0, -1, false)
  for i, l in ipairs(lines) do
    local pre = l:match("^(%s*#%+[Cc][Oo][Ll][Uu][Mm][Nn][Ss]:)")
    if pre then
      vim.api.nvim_buf_set_lines(state.src, i - 1, i, false, { pre .. " " .. fmt })
      return
    end
  end
  local at = #lines
  for i, l in ipairs(lines) do
    if l:match("^%*+%s") then
      at = i - 1
      break
    end
  end
  vim.api.nvim_buf_set_lines(state.src, at, at, false, { "#+COLUMNS: " .. fmt })
end

--- Allowed values for column `ci` of row `r`: TODO keywords, priorities,
--- `PROP_ALL`, else checkboxes for checkbox summaries, else the days
--- around a timestamp value (Emacs org-columns-next-allowed-value).
local function allowed_values(state, r, ci)
  local col = state.cols[ci]
  local key = col.prop:upper()
  local file = files.get_buffer(state.src)
  local vals
  if key == "TODO" then
    vals = vim.list_extend(vim.deepcopy(file.settings.todo:names()), { "" })
  elseif key == "PRIORITY" then
    local p = file:priorities()
    vals = {}
    for b = p.highest:byte(), p.lowest:byte() do
      vals[#vals + 1] = string.char(b)
    end
  elseif not M.SPECIAL[key] then
    vals = vim.tbl_filter(function(v)
      return v ~= ":ETC"
    end, r.hl:get_allowed_values(col.prop) or {})
  end
  if (not vals or #vals == 0) and (col.summary == "X" or col.summary == "X/" or col.summary == "X%") then
    vals = vim.deepcopy(config.opts.columns_checkbox_allowed_values or { "[ ]", "[X]" })
  end
  if not vals or #vals == 0 then
    local v = vim.trim(r.cells[ci] or "")
    local item = date.parse_all(v)[1]
    if item and item.raw == v then
      vals = {}
      for d = -1, 1 do
        vals[#vals + 1] = item.date:add(d, "d"):to_string()
      end
    end
  end
  return vals and #vals > 0 and vals or nil
end

--- Set column `ci` of row `r` to `value` in the source buffer.
local function set_value(state, r, ci, value)
  local prop = state.cols[ci].prop
  local key = prop:upper()
  local target = { bufnr = state.src, lnum = r.hl.line }
  if key == "TODO" then
    require("org.todo").change_state(target, value ~= "" and value or nil)
  elseif key == "PRIORITY" then
    require("org.priority").set(target, value)
  else
    require("org.edit").set_property(state.src, r.hl.line, prop, value)
  end
end

--- Switch to the next (`dir` = 1) or previous (-1) allowed value, or to
--- the `nth` one (0 = the last). Emacs n / p / S-<right> / S-<left>
--- (org-columns-next-allowed-value).
local function next_allowed(state, dir, nth)
  local r, ci = current(state)
  if not r then
    return
  end
  local col = state.cols[ci]
  local key = col.prop:upper()
  if key == "ITEM" then
    utils.warn("Cannot edit item headline from here")
    return
  elseif key == "SCHEDULED" or key == "DEADLINE" then
    local d = r.hl.planning[key:lower()]
    if d then
      require("org.edit").set_planning(state.src, r.hl.line, key:lower(), d:add_with_range(dir, "d"))
      refresh(state, ci)
    end
    return
  end
  local allowed = allowed_values(state, r, ci)
  if not allowed then
    utils.warn("Allowed values for this property have not been defined")
    return
  end
  local new
  if nth then
    if nth > #allowed then
      utils.warn(string.format("Only %d allowed values for property `%s'", #allowed, col.prop))
      return
    end
    new = allowed[(nth - 1) % #allowed + 1]
  else
    local list = allowed
    if dir < 0 then
      list = {}
      for i = #allowed, 1, -1 do
        list[#list + 1] = allowed[i]
      end
    end
    local value = vim.trim(r.cells[ci] or "")
    local idx
    for i, v in ipairs(list) do
      if v == value then
        idx = i
      end
    end
    if idx and #list == 1 then
      utils.warn("Only one allowed value for this property")
      return
    end
    new = idx and list[idx % #list + 1] or list[1]
  end
  set_value(state, r, ci, new)
  refresh(state, ci)
end

--- Edit a value with the regular command for the column. Emacs e
--- (org-columns-edit-value).
local function edit_cell(state)
  local r, ci = current(state)
  if not r then
    return
  end
  local col = state.cols[ci]
  local key = col.prop:upper()
  local target = { bufnr = state.src, lnum = r.hl.line }
  if key == "ITEM" then
    local v = utils.input({ prompt = "Headline: ", default = r.hl.title })
    if v then
      require("org.edit").update_headline(state.src, r.hl.line, { title = v })
    end
  elseif key == "TODO" then
    require("org.todo").select(target)
  elseif key == "PRIORITY" then
    require("org.priority").set(target)
  elseif key == "TAGS" then
    require("org.tags").set_tags(target)
  elseif key == "SCHEDULED" then
    require("org.timestamps").schedule(target)
  elseif key == "DEADLINE" then
    require("org.timestamps").deadline(target)
  elseif M.SPECIAL[key] then
    utils.warn("This special column cannot be edited")
    return
  else
    local allowed = allowed_values(state, r, ci)
    local v
    if allowed then
      v = utils.select(allowed, { prompt = col.prop .. " value" })
    else
      v = utils.input({ prompt = "Edit: ", default = r.cells[ci] or "" })
    end
    if v == nil or vim.trim(v) == (r.cells[ci] or "") then
      return
    end
    require("org.edit").set_property(state.src, r.hl.line, col.prop, vim.trim(v))
  end
  refresh(state, ci)
end

--- Edit the allowed values (`PROP_ALL`) of the current column where they
--- are defined, else on the entry that defines the view. Emacs a
--- (org-columns-edit-allowed).
local function edit_allowed(state)
  local r, ci = current(state)
  if not r then
    return
  end
  local prop = state.cols[ci].prop
  local key = prop:upper() .. "_ALL"
  local where = r.hl
  while where and not where.properties[key] do
    where = where.parent
  end
  where = where or state.holder or r.hl
  local cur = r.hl:get_allowed_values(prop)
  local v = utils.input({ prompt = "Allowed: ", default = cur and table.concat(cur, " ") or "" })
  if v == nil then
    return
  end
  require("org.edit").set_property(state.src, where.line, prop .. "_ALL", vim.trim(v))
  refresh(state, ci)
end

--- Prompt for column attributes (defaults from `spec`).
local function read_column(state, spec)
  spec = spec or {}
  local prop = utils.input_complete("Property: ", require("org.properties").known_names(state.src), spec.prop)
  if not prop or vim.trim(prop) == "" then
    return nil
  end
  prop = vim.trim(prop)
  local default_title = spec.title and spec.title ~= spec.prop and spec.title or ""
  local title = utils.input({ prompt = "Column title [" .. prop .. "]: ", default = default_title })
  if title == nil then
    return nil
  end
  local width = utils.input({ prompt = "Column width: ", default = spec.width and tostring(spec.width) or "" })
  if width == nil then
    return nil
  end
  local summary = utils.input_complete("Summary: ", M.SUMMARY_TYPES, spec.summary)
  if summary == nil then
    return nil
  end
  local sfmt = utils.input({ prompt = "Format: ", default = spec.summary_fmt or "" })
  if sfmt == nil then
    return nil
  end
  title, summary, sfmt = vim.trim(title), vim.trim(summary), vim.trim(sfmt)
  return {
    prop = prop,
    title = title ~= "" and title or prop,
    width = tonumber(width),
    summary = summary ~= "" and summary or nil,
    summary_fmt = sfmt ~= "" and sfmt or nil,
  }
end

--- Insert a new column left of the current one or, with `edit`, change
--- the current column's attributes. Emacs M-S-<right> / s
--- (org-columns-new / org-columns-edit-attributes).
local function new_column(state, edit)
  local _, ci = current(state)
  ci = ci or 1
  local spec = read_column(state, edit and state.cols[ci] or nil)
  if not spec then
    return
  end
  local cols = vim.deepcopy(state.cols)
  if edit then
    cols[ci] = spec
  else
    table.insert(cols, ci, spec)
  end
  store_format(state, cols)
  refresh(state, ci)
end

--- Remove the current column from the format. Emacs M-S-<left>
--- (org-columns-delete).
local function delete_column(state)
  local _, ci = current(state)
  ci = ci or 1
  if #state.cols <= 1 then
    utils.warn("Cannot delete the last column")
    return
  end
  if not utils.confirm(string.format("Are you sure you want to remove column %s?", state.cols[ci].title)) then
    return
  end
  local cols = vim.deepcopy(state.cols)
  table.remove(cols, ci)
  store_format(state, cols)
  refresh(state, math.min(ci, #cols))
end

--- Swap the current column with its neighbour. Emacs M-<left> / M-<right>
--- (org-columns-move-left / right).
local function move_column(state, dir)
  local _, ci = current(state)
  ci = ci or 1
  local other = ci + dir
  if other < 1 or other > #state.cols then
    utils.warn("Cannot shift this column further to the " .. (dir < 0 and "left" or "right"))
    return
  end
  local cols = vim.deepcopy(state.cols)
  cols[ci], cols[other] = cols[other], cols[ci]
  store_format(state, cols)
  refresh(state, other)
end

--- Make the current column `delta` characters wider (narrower when
--- negative). Emacs > / < (org-columns-widen / narrow).
local function widen(state, delta)
  local _, ci = current(state)
  ci = ci or 1
  local cols = vim.deepcopy(state.cols)
  cols[ci].width = math.max(1, state.widths[ci] + delta)
  store_format(state, cols)
  refresh(state, ci)
end

--- Move the entry of the current row (with its subtree) up or down. Emacs
--- M-<up> / M-<down> (org-columns-move-row-up / down).
local function move_row(state, dir)
  local r, ci = current(state)
  if not r then
    return
  end
  local win = vim.fn.win_findbuf(state.src)[1]
  if not win then
    utils.warn("The org buffer is not shown in a window")
    return
  end
  local line
  vim.api.nvim_win_call(win, function()
    vim.api.nvim_win_set_cursor(0, { r.hl.line, 0 })
    local structure = require("org.structure")
    if dir < 0 then
      structure.move_subtree_up()
    else
      structure.move_subtree_down()
    end
    line = vim.api.nvim_win_get_cursor(0)[1]
  end)
  render(state)
  for i, row in ipairs(state.rows) do
    if row.hl.line == line then
      goto_cell(state, i + 2, ci)
      return
    end
  end
end

--- Open column view for the current buffer.
function M.open()
  local src = vim.api.nvim_get_current_buf()
  if vim.bo[src].filetype ~= "org" then
    utils.warn("Column view needs an org buffer")
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "orgcolumns"
  local mark = vim.api.nvim_buf_set_extmark(src, ns, lnum - 1, 0, {})
  local state = { src = src, mark = mark, buf = buf }
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.wrap = false
  vim.wo.cursorline = true
  vim.wo.number = false
  vim.wo.relativenumber = false
  render(state)
  vim.api.nvim_win_set_height(0, math.min(#state.rows + 3, math.floor(vim.o.lines / 2)))
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if vim.api.nvim_buf_is_valid(src) then
        pcall(vim.api.nvim_buf_del_extmark, src, ns, mark)
      end
    end,
  })
  local function map(lhs, fn, desc)
    for _, l in ipairs(type(lhs) == "table" and lhs or { lhs }) do
      vim.keymap.set("n", l, fn, { buffer = buf, nowait = true, desc = "org columns: " .. desc })
    end
  end
  --- Mapping callback running `fn(state, ...)` in a coroutine (prompts).
  local function run(fn, ...)
    local args = { ... }
    return function()
      utils.run(fn, state, unpack(args))
    end
  end
  local function quit()
    vim.api.nvim_win_close(0, true)
  end
  map("q", quit, "quit")
  map({ "r", "g" }, function()
    refresh(state)
  end, "refresh")
  map("e", run(edit_cell), "edit value")
  map({ "n", "<S-Right>" }, run(next_allowed, 1), "next allowed value")
  map({ "p", "<S-Left>" }, run(next_allowed, -1), "previous allowed value")
  map("a", run(edit_allowed), "edit allowed values")
  -- 1..9 pick the Nth allowed value (org-columns-next-allowed-value); 0
  -- keeps its Vim meaning
  for i = 1, 9 do
    map(tostring(i), run(next_allowed, 1, i), "allowed value " .. i)
  end
  map("<C-c><C-o>", function()
    local r, ci = current(state)
    if not r then
      return
    end
    local value = r.cells[ci] or ""
    local target = value:match("%[%[(.-)%]%]") or value:match("%[%[(.-)%]%[") or value:match("%a[%w+.-]*:%S+")
    if target then
      target = target:match("^(.-)%]%[") or target
      vim.cmd("wincmd p")
      require("org.links").open(target, { bufnr = state.src })
    else
      utils.warn("No link in this field")
    end
  end, "open link")
  map("s", run(new_column, true), "edit column attributes")
  map({ "<M-S-Right>", "<M-L>" }, run(new_column, false), "new column")
  map({ "<M-S-Left>", "<M-H>" }, run(delete_column), "delete column")
  map({ "<M-Right>", "<M-l>" }, run(move_column, 1), "move column right")
  map({ "<M-Left>", "<M-h>" }, run(move_column, -1), "move column left")
  map({ "<M-Up>", "<M-k>" }, run(move_row, -1), "move row up")
  map({ "<M-Down>", "<M-j>" }, run(move_row, 1), "move row down")
  map(">", function()
    utils.run(widen, state, math.max(vim.v.count, 1))
  end, "widen column")
  map("<", function()
    utils.run(widen, state, -math.max(vim.v.count, 1))
  end, "narrow column")
  map("<C-c><C-c>", function()
    local r, ci = current(state)
    if r and vim.trim(r.cells[ci] or ""):match("^%[[ xX%-]%]$") then
      utils.run(next_allowed, state, 1)
    else
      quit()
    end
  end, "toggle checkbox or quit")
  map("<C-c><C-t>", function()
    local r = current(state)
    if r then
      utils.run(function()
        require("org.todo").select_or_cycle({ bufnr = state.src, lnum = r.hl.line })
        refresh(state)
      end)
    end
  end, "change TODO state")
  map("<CR>", function()
    local r = current(state)
    if not r then
      return
    end
    local path = vim.api.nvim_buf_get_name(state.src)
    vim.cmd("wincmd p")
    if vim.api.nvim_get_current_buf() ~= state.src then
      utils.open_file(path, r.hl.line)
    else
      vim.api.nvim_win_set_cursor(0, { r.hl.line, 0 })
      vim.cmd("normal! zv")
    end
  end, "jump to headline")
  map("v", function()
    local r, ci = current(state)
    if r then
      utils.notify(state.cols[ci].title .. ": " .. (r.cells[ci] or ""))
    end
  end, "show value")
  vim.api.nvim_win_set_cursor(0, { math.min(3, vim.api.nvim_buf_line_count(buf)), 0 })
  return true
end

return M

