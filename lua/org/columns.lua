---@mod org.columns Column view
---
--- `open()` shows headlines and their properties as a table in a split.
--- The format comes from the nearest COLUMNS property, `#+COLUMNS:`, or
--- `columns_default_format`. Summary operators: {+} {:} {X} {X/} {X%}
--- {min} {max} {mean} {:min} {:max} {:mean} (optionally `{+;%.2f}`).

local config = require("org.config")
local date = require("org.date")
local files = require("org.files")
local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.columns")

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
    return hl.priority or ""
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
  if op == "+" or op == "est+" then
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
      return done == #present and "[X]" or "[ ]"
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
      if col.summary and #child_cells > 0 then
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

--- Column format and roots for a buffer/cursor position.
local function scope_for(file, lnum)
  local hl = lnum and file:headline_at(lnum)
  local p = hl
  while p do
    if p.properties.COLUMNS then
      return p.properties.COLUMNS, { p }
    end
    p = p.parent
  end
  return file.settings.columns or config.opts.columns_default_format, file.children
end

---------------------------------------------------------------------------
-- Dynamic block writer
---------------------------------------------------------------------------

function M.dblock(params, ctx)
  local file = files.get_buffer(ctx.bufnr)
  local id = params.id
  local roots, fmt
  if id == "local" then
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
        if indent and r.rel_level > 1 then
          v = "\\_" .. string.rep(" ", 2 * (r.rel_level - 1)) .. v
        end
      elseif v ~= "" then
        empty = false
      end
      cells[i] = v
    end
    if not (params["skip-empty-rows"] and empty) then
      out[#out + 1] = cells
    end
  end
  return require("org.clock").format_table(out)
end

---------------------------------------------------------------------------
-- Interactive view
---------------------------------------------------------------------------

local function render(state)
  local file = files.get_buffer(state.src)
  local fmt, roots = scope_for(file, state.lnum)
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
    vim.api.nvim_buf_set_extmark(buf, ns, i + 1, 0, { end_col = math.min(#lines[i + 2], widths[1] + 3), hl_group = grp })
  end
end

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
  elseif key == "CLOCKSUM" then
    utils.notify("CLOCKSUM is computed")
    return
  else
    require("org.properties").set_property(target, col.prop)
  end
  render(state)
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
  local state = { src = src, lnum = lnum, buf = buf }
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.wrap = false
  vim.wo.cursorline = true
  vim.wo.number = false
  vim.wo.relativenumber = false
  render(state)
  vim.api.nvim_win_set_height(0, math.min(#state.rows + 3, math.floor(vim.o.lines / 2)))
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "org columns: " .. desc })
  end
  map("q", function()
    vim.api.nvim_win_close(0, true)
  end, "quit")
  for _, k in ipairs({ "r", "g" }) do
    map(k, function()
      render(state)
    end, "refresh")
  end
  map("e", function()
    utils.run(edit_cell, state)
  end, "edit value")
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
