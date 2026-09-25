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

--- Raw value of a column for a headline.
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
  elseif key == "CLOCKSUM" then
    local m = require("org.clock").sum_minutes(hl)
    return m > 0 and date.format_duration(m) or ""
  end
  return hl:get_property(prop) or ""
end

local function checkbox_state(v)
  if v == "[X]" or v == "[x]" then
    return true
  end
  local a, b = v:match("^%[(%d+)/(%d+)%]$")
  if a then
    return a == b and tonumber(b) > 0
  end
  local p = v:match("^%[(%d+)%%%]$")
  if p then
    return tonumber(p) == 100
  end
  return false
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

--- Combine child values with a summary operator.
function M.summarize(op, values, sfmt)
  local present = vim.tbl_filter(function(v)
    return v ~= nil and v ~= ""
  end, values)
  if #present == 0 then
    return ""
  end
  local function fmt_num(n)
    if sfmt then
      return string.format(sfmt, n)
    end
    if n == math.floor(n) then
      return tostring(math.floor(n))
    end
    return string.format("%.2f", n)
  end
  if op == "est+" then
    -- sum of means +/- the square root of the summed variances
    local mean, var = 0, 0
    for _, v in ipairs(present) do
      local low, high = v:match("^%s*([-+]?[%d.]+)%s*%-%s*([-+]?[%d.]+)%s*$")
      if low then
        low, high = tonumber(low), tonumber(high)
        local m = (low + high) / 2
        mean = mean + m
        var = var + (low * low + high * high) / 2 - m * m
      else
        mean = mean + (tonumber(v) or 0)
      end
    end
    local sd = math.sqrt(var)
    return string.format("%.0f-%.0f", mean - sd, mean + sd)
  elseif op == "$" then
    local s = 0
    for _, v in ipairs(present) do
      s = s + (tonumber(v) or 0)
    end
    return string.format("%.2f", s)
  elseif op == "@min" or op == "@max" or op == "@mean" then
    local now = os.time() / 60
    local ages = {}
    for _, v in ipairs(present) do
      local d = date.parse(v)
      ages[#ages + 1] = d and (now - d:to_time() / 60) or date.parse_duration(v) or 0
    end
    local r
    if op == "@min" then
      r = math.min(unpack(ages))
    elseif op == "@max" then
      r = math.max(unpack(ages))
    else
      r = 0
      for _, a in ipairs(ages) do
        r = r + a
      end
      r = r / #ages
    end
    return M.format_age(r)
  elseif op == "+" then
    local s = 0
    for _, v in ipairs(present) do
      s = s + (tonumber(v) or 0)
    end
    return fmt_num(s)
  elseif op == ":" or op == ":min" or op == ":max" or op == ":mean" then
    local nums = {}
    for _, v in ipairs(present) do
      nums[#nums + 1] = date.parse_duration(v) or 0
    end
    local r
    if op == ":" then
      r = 0
      for _, n in ipairs(nums) do
        r = r + n
      end
    elseif op == ":min" then
      r = math.min(unpack(nums))
    elseif op == ":max" then
      r = math.max(unpack(nums))
    else
      r = 0
      for _, n in ipairs(nums) do
        r = r + n
      end
      r = r / #nums
    end
    return date.format_duration(r)
  elseif op == "min" or op == "max" or op == "mean" then
    local nums = {}
    for _, v in ipairs(present) do
      nums[#nums + 1] = tonumber(v) or 0
    end
    if op == "min" then
      return fmt_num(math.min(unpack(nums)))
    elseif op == "max" then
      return fmt_num(math.max(unpack(nums)))
    end
    local s = 0
    for _, n in ipairs(nums) do
      s = s + n
    end
    return fmt_num(s / #nums)
  elseif op == "X" or op == "X/" or op == "X%" then
    local done = 0
    for _, v in ipairs(present) do
      if checkbox_state(v) then
        done = done + 1
      end
    end
    if op == "X" then
      return done == #present and "[X]" or (done > 0 and "[-]" or "[ ]")
    elseif op == "X/" then
      return string.format("[%d/%d]", done, #present)
    end
    return string.format("[%d%%]", math.floor(done * 100 / #present + 0.5))
  end
  return present[1]
end

--- Compute rows for a list of root headlines.
---@param roots org.Headline[]
---@param cols table
---@param opts? { maxlevel?: integer }
---@return { hl: org.Headline, cells: string[] }[]
function M.compute(roots, cols, opts)
  opts = opts or {}
  local rows = {}
  local function effective(hl, maxdepth_ok)
    local cells = {}
    local child_cells = {}
    for _, child in ipairs(hl.children) do
      child_cells[#child_cells + 1] = effective(child, maxdepth_ok)
    end
    for i, col in ipairs(cols) do
      local v = M.value(hl, col.prop)
      if col.summary and not M.SPECIAL[col.prop:upper()] and #child_cells > 0 then
        local vals = {}
        for _, cc in ipairs(child_cells) do
          vals[#vals + 1] = cc[i]
        end
        local s = M.summarize(col.summary, vals, col.summary_fmt)
        if s ~= "" then
          v = s
        end
      end
      cells[i] = v
    end
    hl._column_cells = cells
    return cells
  end
  for _, r in ipairs(roots) do
    effective(r)
  end
  local function walk(hl, base)
    local rel = hl.level - base + 1
    if opts.maxlevel and hl.level > opts.maxlevel then
      return
    end
    rows[#rows + 1] = { hl = hl, cells = hl._column_cells, rel_level = rel }
    for _, c in ipairs(hl.children) do
      walk(c, base)
    end
  end
  for _, r in ipairs(roots) do
    walk(r, r.level)
  end
  for _, r in ipairs(rows) do
    r.hl._column_cells = nil
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
  local rows = M.compute(roots, cols, { maxlevel = tonumber(params.maxlevel) })
  local pred = matcher(params.match)
  local exclude = tag_list(params["exclude-tags"])
  local hlines = params.hlines
  local out = {}
  local header = {}
  for _, c in ipairs(cols) do
    header[#header + 1] = c.title
  end
  out[1] = header
  out[2] = "hline"
  local indent = params.indent and params.indent ~= false
  for _, r in ipairs(rows) do
    local cells = {}
    local empty = true
    for i, c in ipairs(cols) do
      local v = (r.cells[i] or ""):gsub("|", "\\vert{}")
      if c.prop:upper() == "ITEM" then
        if params.link then
          local target = "*" .. r.hl.title
          if file.filename then
            target = "file:" .. file.filename .. "::" .. target
          end
          v = "[[" .. target .. "][" .. v .. "]]"
        end
        if indent and r.rel_level > 1 then
          v = "\\_" .. string.rep(" ", 2 * (r.rel_level - 1)) .. v
        end
      elseif v ~= "" then
        empty = false
      end
      cells[i] = v
    end
    local excluded = false
    for _, t in ipairs(exclude) do
      excluded = excluded or vim.tbl_contains(r.hl.tags, t)
    end
    if not (params["skip-empty-rows"] and empty) and not excluded and (not pred or pred(r.hl)) then
      local level_ok = hlines == true or (type(hlines) == "number" and r.hl.level <= hlines)
      if level_ok and out[#out] ~= "hline" then
        out[#out + 1] = "hline"
      end
      out[#out + 1] = cells
    end
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

local function render(state)
  local file = files.get_buffer(state.src)
  local fmt, roots, holder = scope_for(file, anchor_line(state))
  state.holder = holder
  state.cols = M.parse_format(fmt)
  local rows = M.compute(roots, state.cols)
  state.rows = rows
  local widths = {}
  for i, c in ipairs(state.cols) do
    local w = utils.width(c.title)
    for _, r in ipairs(rows) do
      local v = r.cells[i] or ""
      if c.prop:upper() == "ITEM" then
        v = string.rep("*", r.hl.level) .. " " .. v
      end
      w = math.max(w, utils.width(v))
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
      local v = r.cells[i] or ""
      if c.prop:upper() == "ITEM" then
        v = string.rep("*", r.hl.level) .. " " .. v
      end
      cells[i] = v
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
    vals = { "[ ]", "[X]" }
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

