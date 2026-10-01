---@mod org.columns Column view
---
--- `open()` shows headlines and their properties as columns drawn over the
--- headlines (like Emacs), or as a table in a split (`columns_view`).
--- The format comes from the nearest COLUMNS property, `#+COLUMNS:`, or
--- `columns_default_format`. Summary operators: {+} {$} {:} {X} {X/} {X%}
--- {min} {max} {mean} {:min} {:max} {:mean} {@min} {@max} {@mean} {est+}
--- (optionally with a format, `{+;%.2f}`).

local config = require("org.config")
local date = require("org.date")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

--- `s` cut to at most `width` display cells (org-columns--truncate-below-width).
local function truncate_below(s, width)
  local out = s
  while utils.width(out) > width do
    out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1)
  end
  return out
end

--- `s` truncated to `width` cells, ending with `columns_ellipses` when cut
--- (org-columns-add-ellipses).
function M.add_ellipses(s, width)
  if utils.width(s) <= width then
    return s
  end
  local ell = require("org.config").opts.columns_ellipses or ".."
  if width <= utils.width(ell) then
    return truncate_below(ell, width)
  end
  return truncate_below(s, width - utils.width(ell)) .. ell
end

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

--- What each summary type computes, shown when choosing one.
M.SUMMARY_DESCRIPTIONS = {
  ["+"] = "sum",
  ["$"] = "sum as currency, two decimals",
  ["X"] = "checkbox: [X] when all children are",
  ["X/"] = "checkbox: [n/m] children done",
  ["X%"] = "checkbox: [n%] children done",
  max = "largest number",
  mean = "arithmetic mean",
  min = "smallest number",
  [":"] = "sum of times, HH:MM",
  [":max"] = "largest time",
  [":mean"] = "mean time",
  [":min"] = "smallest time",
  ["@max"] = "oldest age",
  ["@mean"] = "mean age",
  ["@min"] = "youngest age",
  ["est+"] = "sum of low-high estimates",
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
    local prop = rest and rest:match("^([%w_%-]+)")
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
--- with its stars (the leading ones blank with `hide`, like Emacs with
--- org-hide-leading-stars) and links shown as their descriptions.
local function view_text(r, i, col, hide)
  local v = r.display[i] or ""
  if col.prop:upper() == "ITEM" and v == r.cells[i] then
    v = v:gsub("%[%[([^%]]-)%]%[(.-)%]%]", "%2"):gsub("%[%[([^%]]-)%]%]", "%1")
    v = string.rep(hide and " " or "*", r.hl.level - 1) .. "* " .. v
  end
  return v
end

local function render_table(state)
  local file = files.get_buffer(state.src)
  local fmt, roots, holder = scope_for(file, not state.global and anchor_line(state) or nil)
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
      parts[i] = utils.pad_right(M.add_ellipses(v, widths[i]), widths[i])
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
local function table_current(state)
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
local function table_goto(state, lnum, ci)
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

-- Overlay view (the default, Emacs org-columns): the column row is drawn
-- over every headline of the org buffer itself, as an overlay extmark
-- blanking the rest of the line; the column titles are in the window's
-- winbar (Emacs header-line). Like Emacs' truncate-lines the window gets
-- 'nowrap', and 'virtualedit' so the cursor reaches every column of a
-- short headline.

local ns_ov = vim.api.nvim_create_namespace("org.columns.overlay")

--- Active overlay views by org buffer.
local views = {}

--- Is the overlay column view on in `bufnr`?
---@param bufnr integer
---@return boolean
function M.is_active(bufnr)
  return views[bufnr] ~= nil
end

--- The Column menu comes and goes with the view (org-columns-menu).
local function sync_menus()
  if package.loaded["org.menu"] then
    pcall(require("org.menu").sync)
  end
end

--- What changing a headline line of the view says (Emacs signals
--- text-read-only with this).
local READ_ONLY = "Text is read-only: Type ‘e’ to edit property"

--- Default links of the column view groups (Emacs org-column and
--- org-column-title).
local OV_HL = { OrgColumn = "Pmenu", OrgColumnTitle = "TabLineSel" }

--- Lines (1-based, as keys) showing a column row in `bufnr`, or nil. The
--- decorations leave these lines alone (Emacs turns org-num-mode off).
function M.overlay_lines(bufnr)
  local state = views[bufnr]
  return state and state.row_at
end

--- Is the overlay column view shown in `bufnr` (default: the current
--- buffer)?
function M.active(bufnr)
  return views[bufnr or vim.api.nvim_get_current_buf()] ~= nil
end

--- Faces of a cell (org-columns--overlay-text): the TODO keyword, priority
--- or tag face, else the level face of the headline, over OrgColumn.
local function cell_hl(r, col, value)
  local key = col.prop:upper()
  local v = vim.trim(value or "")
  local ui = config.opts.ui or {}
  local group = "OrgHeadlineLevel" .. (((r.hl.level - 1) % 8) + 1)
  if key == "TODO" and v ~= "" then
    if (ui.todo_keyword_faces or {})[v] then
      group = "orgTodoKw_" .. v:gsub("[^%w_]", "_")
    else
      group = r.hl.file.settings.todo:is_done(v) and "OrgDone" or "OrgTodo"
    end
  elseif key == "PRIORITY" and v ~= "" then
    if (ui.priority_faces or {})[v] then
      group = require("org.highlights").face_group("orgPriorityFace_", v)
    else
      group = ({ A = "OrgPriorityA", B = "OrgPriorityB", C = "OrgPriorityC" })[v] or "OrgPriority"
    end
  elseif key == "TAGS" and v ~= "" then
    group = "OrgTags"
  end
  return { "OrgColumn", group }
end

--- Emacs overlay text of a cell: "%-W.Ws | ", "%-W.Ws |" for the last one.
local function overlay_cell(v, w, last)
  return utils.pad_right(M.add_ellipses(v, w), w) .. (last and " |" or " | ")
end

--- `s` without its first `n` display cells.
local function drop_cells(s, n)
  local i, w, len = 0, 0, vim.fn.strchars(s)
  while i < len and w < n do
    w = w + utils.width(vim.fn.strcharpart(s, i, 1))
    i = i + 1
  end
  return vim.fn.strcharpart(s, i)
end

--- Show the column titles in the view window's winbar, after the number
--- and sign columns and scrolled along with the text (org-columns-hscroll-title).
local function update_winbar(state)
  local win = state.win
  if not state.saved_opts or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= state.src then
    return
  end
  local info = vim.fn.getwininfo(win)[1] or {}
  local leftcol = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().leftcol
  end)
  local title = drop_cells(state.title or "", leftcol):gsub("%%", "%%%%")
  local bar = "%#Normal#" .. string.rep(" ", info.textoff or 0) .. "%#OrgColumnTitle#" .. title .. "%#Normal#"
  vim.api.nvim_set_option_value("winbar", bar, { scope = "local", win = win })
end

--- Draw the column rows over the headlines of the view's scope. With
--- `update`, summaries are written back to existing properties (on open
--- and redo, like Emacs org-columns-compute-all).
local function overlay_render(state, update)
  local src = state.src
  local file = files.get_buffer(src)
  local fmt, roots, holder = scope_for(file, not state.global and anchor_line(state) or nil)
  state.holder = holder
  state.cols = M.parse_format(fmt)
  local rows = M.compute(roots, state.cols, { update = update })
  state.rows = rows
  local hide = require("org.ui.decorations").ui_options(src).hide_leading_stars
  local texts = {}
  for k, r in ipairs(rows) do
    texts[k] = {}
    for i, c in ipairs(state.cols) do
      texts[k][i] = view_text(r, i, c, hide)
    end
  end
  -- widths: the format's, else the widest value or title (org-columns--set-widths)
  local widths = {}
  for i, c in ipairs(state.cols) do
    local w = utils.width(c.title)
    for k = 1, #rows do
      w = math.max(w, utils.width(texts[k][i]))
    end
    widths[i] = c.width and math.max(c.width, 1) or w
  end
  state.widths = widths
  for group, link in pairs(OV_HL) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
  vim.api.nvim_buf_clear_namespace(src, ns_ov, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(src, 0, -1, false)
  state.row_at = {}
  for k, r in ipairs(rows) do
    local lnum = r.hl.line
    state.row_at[lnum] = r
    local chunks, total = {}, 0
    for i, c in ipairs(state.cols) do
      local s = overlay_cell(texts[k][i], widths[i], i == #state.cols)
      -- the cell face covers the value only: a keyword face with a
      -- background or an italic priority face must not spill onto the
      -- padding and the "|" separator
      local v = M.add_ellipses(texts[k][i], widths[i]):gsub("%s+$", "")
      if v ~= "" then
        chunks[#chunks + 1] = { v, cell_hl(r, c, r.cells[i]) }
      end
      chunks[#chunks + 1] = { s:sub(#v + 1), "OrgColumn" }
      total = total + utils.width(s)
    end
    -- make the rest of the line disappear
    local lw = vim.fn.strdisplaywidth(lines[lnum] or "")
    if lw > total then
      chunks[#chunks + 1] = { string.rep(" ", lw - total), "Normal" }
    end
    pcall(vim.api.nvim_buf_set_extmark, src, ns_ov, lnum - 1, 0, {
      virt_text = chunks,
      virt_text_pos = "overlay",
      hl_mode = "replace",
      priority = 1000,
    })
  end
  local titles = {}
  for i, c in ipairs(state.cols) do
    titles[i] = overlay_cell(c.title, widths[i], i == #state.cols)
  end
  state.title = table.concat(titles)
  update_winbar(state)
  require("org.ui.decorations").render(src)
end

--- Row and column index under the cursor in the org buffer.
local function overlay_current(state)
  if vim.api.nvim_get_current_buf() ~= state.src then
    return nil
  end
  local r = state.row_at and state.row_at[vim.api.nvim_win_get_cursor(0)[1]]
  if not r then
    return nil
  end
  local vcol = vim.fn.virtcol(".") - 1
  local x = 0
  for i, w in ipairs(state.widths) do
    x = x + w + 3
    if vcol < x then
      return r, i
    end
  end
  return r, #state.cols
end

--- Put the cursor on buffer line `lnum`, at the start of column `ci`.
local function overlay_goto(state, lnum, ci)
  lnum = math.max(1, math.min(lnum, vim.api.nvim_buf_line_count(state.src)))
  local x = 0
  for i = 1, math.min(ci or 1, #state.widths) - 1 do
    x = x + state.widths[i] + 3
  end
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  if x > 0 then
    vim.cmd("normal! " .. (x + 1) .. "|")
  end
end

local function render(state)
  if state.mode == "overlay" then
    overlay_render(state, true)
  else
    render_table(state)
  end
end

local function current(state)
  if state.mode == "overlay" then
    return overlay_current(state)
  end
  return table_current(state)
end

local function goto_cell(state, lnum, ci)
  if state.mode == "overlay" then
    overlay_goto(state, lnum, ci)
  else
    table_goto(state, lnum, ci)
  end
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
    require("org.edit").set_property(state.src, state.holder.line or 1, "COLUMNS", fmt)
    return
  end
  local lines = vim.api.nvim_buf_get_lines(state.src, 0, -1, false)
  local file = files.get_buffer(state.src)
  local imported
  for _, entry in ipairs(file.settings.keyword_entries) do
    if entry.key == "COLUMNS" and entry.value ~= "" then
      if entry.filename == file.filename then
        local pre = lines[entry.line]:match("^(%s*#%+[^:]+:)")
        vim.api.nvim_buf_set_lines(state.src, entry.line - 1, entry.line, false, { pre .. " " .. fmt })
        return
      end
      imported = imported or entry
    end
  end
  if imported then
    -- Override the shared setup locally, before the directive that imports
    -- it. Never rewrite the shared file.
    local at = imported.source_line - 1
    vim.api.nvim_buf_set_lines(state.src, at, at, false, { "#+COLUMNS: " .. fmt })
    return
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
    local prio = require("org.priority")
    local range = prio.range(file)
    vals = {}
    for v = range.hi, range.lo do
      vals[#vals + 1] = prio.to_string(v)
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
  if not where and files.get_buffer(state.src).properties[key] then
    where = { line = 1 } -- inherited from the file-level drawer
  end
  where = where or state.holder or r.hl
  -- the raw value keeps quoted items ("Deutsche Grammophon") intact
  local cur = r.hl:get_property(key, true)
  local v = utils.input({ prompt = "Allowed: ", default = cur or "" })
  if v == nil then
    return
  end
  require("org.edit").set_property(state.src, where.line or 1, prop .. "_ALL", vim.trim(v))
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
  local summaries = { { value = "", label = "(none)" } }
  for _, s in ipairs(M.SUMMARY_TYPES) do
    summaries[#summaries + 1] = { value = s, desc = M.SUMMARY_DESCRIPTIONS[s] }
  end
  local summary = require("org.ui").choose({
    prompt = "Summary: ",
    title = "Summary type",
    items = summaries,
    default = spec.summary or "",
  })
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
  local win = state.mode == "overlay" and vim.api.nvim_get_current_win() or vim.fn.win_findbuf(state.src)[1]
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
      goto_cell(state, state.mode == "overlay" and line or i + 2, ci)
      return
    end
  end
end

--- Bind the column view keys with `map(lhs, fn, desc)`; `quit` leaves the
--- view.
local function bind_keys(state, map, quit)
  --- Mapping callback running `fn(state, ...)` in a coroutine (prompts).
  local function run(fn, ...)
    local args = { ... }
    return function()
      utils.run(fn, state, unpack(args))
    end
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
      if state.mode ~= "overlay" then
        vim.cmd("wincmd p")
      end
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
  map("v", function()
    local r, ci = current(state)
    if r then
      utils.notify(state.cols[ci].title .. ": " .. (r.cells[ci] or ""))
    end
  end, "show value")
end

--- Remove the overlay view of `state`: its overlays, winbar and window
--- options and its keys (the buffer's own mappings come back).
local function quit_overlay(state)
  if views[state.src] ~= state then
    return
  end
  views[state.src] = nil
  vim.schedule(sync_menus)
  pcall(vim.api.nvim_del_augroup_by_id, state.group)
  local src = state.src
  if vim.api.nvim_buf_is_valid(src) then
    vim.api.nvim_buf_clear_namespace(src, ns_ov, 0, -1)
    pcall(vim.api.nvim_buf_del_extmark, src, ns, state.mark)
    for _, lhs in ipairs(state.lhs or {}) do
      pcall(vim.keymap.del, "n", lhs, { buffer = src })
    end
    vim.api.nvim_buf_call(src, function()
      for _, m in pairs(state.saved_maps or {}) do
        if m.buffer == 1 then
          pcall(vim.fn.mapset, "n", false, m)
        end
      end
    end)
    require("org.ui.decorations").render(src)
  end
  if state.saved_opts and vim.api.nvim_win_is_valid(state.win) then
    for name, value in pairs(state.saved_opts) do
      pcall(vim.api.nvim_set_option_value, name, value, { scope = "local", win = state.win })
    end
  end
end

--- Leave the overlay column view of `bufnr` (default: the current buffer).
function M.quit(bufnr)
  local state = views[bufnr or vim.api.nvim_get_current_buf()]
  if state then
    quit_overlay(state)
  end
end

--- Run action `idx` of the overlay view of `bufnr` (from its mappings).
function M._key(bufnr, idx)
  local state = views[bufnr]
  local fn = state and state.actions[idx]
  if fn then
    fn()
  end
end

--- Run the mapping that key `idx` of the overlay view of `bufnr` shadows
--- (the key was typed outside a column row).
function M._fallback(bufnr, idx)
  local state = views[bufnr]
  local m = state and state.saved_maps[idx]
  if not m then
    return
  end
  local keys
  if m.callback then
    keys = m.callback()
    keys = m.expr == 1 and type(keys) == "string" and keys or nil
  elseif m.rhs then
    keys = m.expr == 1 and vim.api.nvim_eval(m.rhs) or m.rhs
  end
  if type(keys) == "string" and keys ~= "" then
    vim.api.nvim_feedkeys(vim.keycode(keys), m.noremap == 1 and "n" or "m", false)
  end
end

--- A `map` for `bind_keys` in the org buffer: on a column row the key runs
--- its column view action (Emacs binds them on the overlays), elsewhere it
--- keeps its usual meaning.
local function overlay_mapper(state)
  local src = state.src
  state.actions, state.saved_maps, state.lhs = {}, {}, {}
  return function(lhs, fn, desc)
    for _, l in ipairs(type(lhs) == "table" and lhs or { lhs }) do
      local idx = #state.actions + 1
      state.actions[idx] = fn
      local prev = vim.fn.maparg(l, "n", false, true)
      if prev and prev.lhs then
        state.saved_maps[idx] = prev
      end
      state.lhs[#state.lhs + 1] = l
      vim.keymap.set("n", l, function()
        local st = views[src]
        if st and st.row_at and st.row_at[vim.api.nvim_win_get_cursor(0)[1]] then
          return string.format("<Cmd>lua require('org.columns')._key(%d, %d)<CR>", src, idx)
        elseif st and st.saved_maps[idx] then
          return string.format("<Cmd>lua require('org.columns')._fallback(%d, %d)<CR>", src, idx)
        end
        return l
      end, { buffer = src, expr = true, nowait = true, desc = "org columns: " .. desc })
    end
  end
end

--- Turn on the overlay view in the current window (Emacs org-columns).
local function open_overlay(src, lnum, global)
  if views[src] then
    quit_overlay(views[src])
  end
  local win = vim.api.nvim_get_current_win()
  local mark = vim.api.nvim_buf_set_extmark(src, ns, lnum - 1, 0, {})
  local state = { mode = "overlay", src = src, mark = mark, global = global, win = win }
  overlay_render(state, true)
  if #state.rows == 0 then
    vim.api.nvim_buf_clear_namespace(src, ns_ov, 0, -1)
    pcall(vim.api.nvim_buf_del_extmark, src, ns, mark)
    return nil
  end
  views[src] = state
  state.saved_opts = {}
  -- a headline with a closed fold (drawers, body) is drawn with Folded
  -- across the window, a band under its column row: Emacs shows none
  local whl = vim.api.nvim_get_option_value("winhighlight", { scope = "local", win = win })
  whl = (whl == "" and "" or whl .. ",") .. "Folded:Normal"
  for name, value in pairs({ wrap = false, virtualedit = "all", winbar = "", winhighlight = whl }) do
    state.saved_opts[name] = vim.api.nvim_get_option_value(name, { scope = "local", win = win })
    vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
  end
  update_winbar(state)
  require("org.ui.decorations").render(src)
  local map = overlay_mapper(state)
  bind_keys(state, map, function()
    quit_overlay(state)
  end)
  -- Emacs org-columns-content / org-overview
  map("c", function()
    require("org.fold").content()
  end, "contents view")
  map("o", function()
    require("org.fold").overview()
  end, "overview")
  -- Emacs puts one column on each character, so a motion moves by column
  local function step(dir)
    return function()
      local r, ci = overlay_current(state)
      if r then
        overlay_goto(state, r.hl.line, math.max(1, math.min(#state.cols, ci + dir * vim.v.count1)))
      end
    end
  end
  map({ "l", "<Right>", "w", "<Space>", "<M-f>" }, step(1), "next column")
  map({ "h", "<Left>", "b", "<BS>", "<M-b>" }, step(-1), "previous column")
  map("$", step(math.huge), "last column")
  -- the headline lines are read-only (Emacs gives them a read-only text
  -- property): the keys that change text only say so there
  local changes = { "i", "I", "A", "O", "C", "S", "x", "X", "d", "D", "R", "P", "J", "~", ".", "=", "!", "&" }
  vim.list_extend(changes, { "<Del>", "<Insert>", "<C-a>", "<C-x>" })
  map(changes, function()
    utils.warn(READ_ONLY)
  end, "read-only")
  local group = vim.api.nvim_create_augroup("org.columns.overlay." .. src, { clear = true })
  state.group = group
  -- any other way into Insert mode on a column row is turned back
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = src,
    callback = function()
      if views[src] == state and state.row_at[vim.api.nvim_win_get_cursor(0)[1]] then
        vim.cmd("stopinsert")
        utils.warn(READ_ONLY)
      end
    end,
  })
  -- keep the rows on their headlines when the text changes
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = group,
    buffer = src,
    callback = function()
      vim.schedule(function()
        if views[src] == state and vim.api.nvim_buf_is_valid(src) then
          overlay_render(state, false)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
    group = group,
    callback = function()
      if views[src] == state then
        update_winbar(state)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWinLeave", "BufWipeout", "BufUnload" }, {
    group = group,
    buffer = src,
    callback = function()
      quit_overlay(state)
    end,
  })
  sync_menus()
  return true
end

--- Open column view for the current buffer: over its headlines (Emacs
--- org-columns), or as a table in a split with `columns_view = "table"`.
---@param opts? { global?: boolean, view?: "overlay"|"table" } global (or
--- a count, like C-u in Emacs org-columns): the whole file, with the
--- file-level format; view: overrides `columns_view`
function M.open(opts)
  opts = opts or {}
  local global = opts.global or vim.v.count > 0
  local src = vim.api.nvim_get_current_buf()
  if vim.bo[src].filetype ~= "org" then
    utils.warn("Column view needs an org buffer")
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  if (opts.view or config.opts.columns_view) ~= "table" then
    return open_overlay(src, lnum, global)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "orgcolumns"
  local mark = vim.api.nvim_buf_set_extmark(src, ns, lnum - 1, 0, {})
  local state = { mode = "table", src = src, mark = mark, buf = buf, global = global }
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
  bind_keys(state, map, function()
    vim.api.nvim_win_close(0, true)
  end)
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
  vim.api.nvim_win_set_cursor(0, { math.min(3, vim.api.nvim_buf_line_count(buf)), 0 })
  return true
end

return M
