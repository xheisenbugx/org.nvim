---@mod org.clock Clocking work time
---
--- One clock runs at a time. Its state is `{ path, start (string), title,
--- effort }`; the open `CLOCK: [start]` line in `path` is the source of
--- truth, so the clock survives restarts (`restore()` finds it again).

local config = require("org.config")
local date = require("org.date")
local edit = require("org.edit")
local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")

local M = {}

---@class org.ClockState
---@field path string
---@field start string inactive timestamp string of the clock start
---@field title string
---@field effort integer|nil minutes

---@type org.ClockState|nil
M.state = nil
---@type { path: string, title: string, id?: string }|nil
M.last = nil

local display_ns = vim.api.nvim_create_namespace("org.clock.display")

local function clock_cfg()
  return config.opts.clock or {}
end

local function persist()
  local cfg = clock_cfg()
  if not cfg.persist or not cfg.persist_file then
    return
  end
  pcall(utils.write_json, cfg.persist_file, { state = M.state or vim.NIL, last = M.last or vim.NIL })
end

local function buf_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and vim.fs.normalize(name) or nil
end

--- Format a closed clock line.
function M.format_clock_line(indent, start, stop)
  local minutes = stop:minutes() - start:minutes()
  return string.format(
    "%sCLOCK: %s--%s => %5s",
    indent or "",
    start:clone({ active = false }):to_string({ range = false }),
    stop:clone({ active = false }):to_string({ range = false }),
    date.format_duration(minutes)
  ), minutes
end

--- Locate the open clock line of the running clock.
---@return integer|nil bufnr, integer|nil lnum
function M.find_open_clock()
  local st = M.state
  if not st then
    return nil
  end
  local bufnr = utils.find_buffer(st.path)
  if not bufnr then
    if not utils.exists(st.path) then
      return nil
    end
    bufnr = utils.load_buffer(st.path)
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local pat = "^%s*CLOCK:%s*" .. utils.escape_pattern(st.start) .. "%s*$"
  for i, l in ipairs(lines) do
    if l:match(pat) then
      return bufnr, i
    end
  end
  return nil
end

--- Info about the running clock, or nil.
function M.active()
  local st = M.state
  if not st then
    return nil
  end
  local start = date.parse(st.start)
  if not start then
    return nil
  end
  return {
    path = st.path,
    title = st.title,
    start = start,
    effort = st.effort,
    minutes = date.now():minutes() - start:minutes(),
  }
end

--- Is the running clock inside the headline at (bufnr, lnum)?
function M.is_clocked_headline(bufnr, lnum)
  if not M.state then
    return false
  end
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local path = buf_path(bufnr)
  if not path or path ~= vim.fs.normalize(M.state.path) then
    return false
  end
  local b, clnum = M.find_open_clock()
  if not b or b ~= bufnr then
    return false
  end
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(clnum)
  local target = file:headline_at(lnum)
  return hl ~= nil and target ~= nil and hl.line == target.line
end

local function drawer_name()
  local into = clock_cfg().into_drawer
  if into == false then
    return nil
  end
  if type(into) == "string" then
    return into
  end
  return edit.log_drawer_name() or "LOGBOOK"
end

--- Remove an empty drawer whose start line is `s`.
local function remove_empty_drawer(bufnr, s)
  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, s + 1, false)
  if lines[1] and lines[2] and lines[1]:match("^%s*:[%w_%-]+:%s*$") and lines[2]:match("^%s*:END:%s*$") then
    vim.api.nvim_buf_set_lines(bufnr, s - 1, s + 1, false, {})
  end
end

--- Clock out of the running clock.
---@param opts? { at?: table }
function M.clock_out(opts)
  opts = opts or {}
  if not M.state then
    utils.notify("No running clock")
    return nil
  end
  local bufnr, lnum = M.find_open_clock()
  local st = M.state
  M.state = nil
  persist()
  if not bufnr then
    utils.warn("Could not find the open clock line for " .. st.title)
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  local indent = line:match("^(%s*)")
  local start = date.parse(st.start)
  local stop = opts.at or date.now()
  local new, minutes = M.format_clock_line(indent, start, stop)
  if minutes <= 0 and clock_cfg().out_remove_zero_time ~= false then
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, {})
    local prev = vim.api.nvim_buf_get_lines(bufnr, lnum - 2, lnum - 1, false)[1]
    if prev and prev:match("^%s*:[%w_%-]+:%s*$") then
      remove_empty_drawer(bufnr, lnum - 1)
    end
    utils.notify("Clock stopped: 0:00, line removed")
  else
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new })
    utils.notify(string.format("Clocked out of %s: %s", st.title, date.format_duration(minutes)))
  end
  M.last = { path = st.path, title = st.title }
  persist()
  vim.cmd("redrawstatus")
  return minutes
end

--- Cancel the running clock (remove the open CLOCK line).
function M.clock_cancel()
  if not M.state then
    utils.notify("No running clock")
    return nil
  end
  local bufnr, lnum = M.find_open_clock()
  local st = M.state
  M.state = nil
  persist()
  if bufnr then
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, {})
    local prev = vim.api.nvim_buf_get_lines(bufnr, lnum - 2, lnum - 1, false)[1]
    if prev and prev:match("^%s*:[%w_%-]+:%s*$") then
      remove_empty_drawer(bufnr, lnum - 1)
    end
  end
  utils.notify("Clock canceled: " .. st.title)
  vim.cmd("redrawstatus")
  return true
end

--- Start clocking the headline at target.
---@param target? org.Target
---@param opts? { at?: table }
function M.clock_in(target, opts)
  opts = opts or {}
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local mark_ns = vim.api.nvim_create_namespace("org.clock.target")
  local mark = vim.api.nvim_buf_set_extmark(bufnr, mark_ns, hl.line - 1, 0, {})
  if M.state then
    if M.is_clocked_headline(bufnr, hl.line) then
      vim.api.nvim_buf_del_extmark(bufnr, mark_ns, mark)
      utils.notify("Already clocking this task")
      return nil
    end
    M.clock_out()
  end
  local lnum = vim.api.nvim_buf_get_extmark_by_id(bufnr, mark_ns, mark, {})[1] + 1
  vim.api.nvim_buf_del_extmark(bufnr, mark_ns, mark)
  local file = files.get_buffer(bufnr)
  hl = file:headline_at(lnum)
  local switch = clock_cfg().in_switch_to_state
  if type(switch) == "function" then
    switch = switch(hl.todo)
  end
  if switch and hl.todo ~= switch and file.settings.todo:is_keyword(switch) then
    require("org.todo").change_state({ bufnr = bufnr, lnum = lnum }, switch)
    hl = files.get_buffer(bufnr):headline_at(lnum)
  end
  local start = (opts.at or date.now()):clone({ active = false })
  local start_str = start:to_string({ range = false })
  local drawer = drawer_name()
  if drawer then
    local s = edit.ensure_drawer(bufnr, lnum, drawer)
    local indent = vim.api.nvim_buf_get_lines(bufnr, s - 1, s, false)[1]:match("^(%s*)")
    vim.api.nvim_buf_set_lines(bufnr, s, s, false, { indent .. "CLOCK: " .. start_str })
  else
    hl = files.get_buffer(bufnr):headline_at(lnum)
    local at = edit.meta_end(hl)
    vim.api.nvim_buf_set_lines(bufnr, at, at, false, { edit.body_indent(hl.level) .. "CLOCK: " .. start_str })
  end
  hl = files.get_buffer(bufnr):headline_at(lnum)
  local effort = require("org.properties").effort_minutes(hl)
  M.state = {
    path = buf_path(bufnr) or "",
    start = start_str,
    title = hl:plain_title(),
    effort = effort,
  }
  M.last = { path = M.state.path, title = M.state.title, id = hl.properties.ID }
  persist()
  utils.notify("Clock started: " .. M.state.title)
  vim.cmd("redrawstatus")
  return M.state
end

--- Find the headline of `M.last` (by ID, then title).
local function find_last()
  local last = M.last
  if not last or not utils.exists(last.path) then
    return nil
  end
  local bufnr = utils.load_buffer(last.path)
  local file = files.get_buffer(bufnr)
  local hl = last.id and file:find_by_id(last.id) or nil
  hl = hl or file:find_by_title(last.title)
  if not hl then
    return nil
  end
  return bufnr, hl.line
end

--- Clock in the most recently clocked task.
function M.clock_in_last()
  local bufnr, lnum = find_last()
  if not bufnr then
    utils.notify("No previously clocked task")
    return nil
  end
  return M.clock_in({ bufnr = bufnr, lnum = lnum })
end

--- Jump to the running (or last) clocked task.
function M.goto_clock()
  if M.state then
    local bufnr, lnum = M.find_open_clock()
    if bufnr then
      local hl = files.get_buffer(bufnr):headline_at(lnum)
      utils.open_file(M.state.path, hl and hl.line or lnum)
      return true
    end
  end
  local bufnr, lnum = find_last()
  if bufnr then
    utils.open_file(vim.api.nvim_buf_get_name(bufnr), lnum)
    return true
  end
  utils.notify("No running or recent clock")
  return nil
end

--- Recompute the duration of a CLOCK line.
function M.update_clock_line(bufnr, lnum)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  local c = line and parser.parse_clock_line(line)
  if not c or not c["end"] then
    return false
  end
  local new = M.format_clock_line(line:match("^(%s*)"), c.start, c["end"])
  if new ~= line then
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new })
  end
  return true
end

--- Minutes clocked in a headline subtree, clipped to [from_min, to_min).
---@param hl org.Headline
---@param from_min? integer
---@param to_min? integer
---@param own_only? boolean exclude children
function M.sum_minutes(hl, from_min, to_min, own_only)
  local total = 0
  local function add(h)
    for _, c in ipairs(h.clocks) do
      if c["end"] then
        if not from_min and not to_min then
          total = total + (c.minutes or 0)
        else
          local s, e = c.start:minutes(), c["end"]:minutes()
          local lo = from_min and math.max(s, from_min) or s
          local hi = to_min and math.min(e, to_min) or e
          if hi > lo then
            total = total + (hi - lo)
          end
        end
      end
    end
    if not own_only then
      for _, child in ipairs(h.children) do
        add(child)
      end
    end
  end
  add(hl)
  return total
end

--- Statusline component: "⏱ 0:25 [0:25/1:00] (Task)".
function M.statusline()
  local a = M.active()
  if not a then
    return ""
  end
  local elapsed = date.format_duration(a.minutes)
  if a.effort then
    return string.format("%s [%s/%s] (%s)", clock_cfg().statusline_icon or "⏱", elapsed, date.format_duration(a.effort), a.title)
  end
  return string.format("%s %s (%s)", clock_cfg().statusline_icon or "⏱", elapsed, a.title)
end

--- Toggle clock-sum virtual text on headlines (org-clock-display).
function M.toggle_display(bufnr)
  if type(bufnr) ~= "number" or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local existing = vim.api.nvim_buf_get_extmarks(bufnr, display_ns, 0, -1, { limit = 1 })
  vim.api.nvim_buf_clear_namespace(bufnr, display_ns, 0, -1)
  if #existing > 0 then
    return true
  end
  local file = files.get_buffer(bufnr)
  local total = 0
  for _, hl in ipairs(file.headlines) do
    local m = M.sum_minutes(hl)
    if hl.level == 1 then
      total = total + m
    end
    if m > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, display_ns, hl.line - 1, 0, {
        virt_text = { { " " .. date.format_duration(m) .. " ", "OrgClockSum" } },
        virt_text_pos = "eol",
      })
    end
  end
  utils.notify("Total file time: " .. date.format_duration(total))
  return true
end

--- Buffer-local setup: clear clock display on edits.
function M.attach(bufnr)
  vim.api.nvim_create_autocmd({ "TextChanged", "InsertEnter" }, {
    buffer = bufnr,
    group = vim.api.nvim_create_augroup("org.clock.buf." .. bufnr, { clear = true }),
    callback = function()
      vim.api.nvim_buf_clear_namespace(bufnr, display_ns, 0, -1)
    end,
  })
  if not vim.api.nvim_get_hl(0, { name = "OrgClockSum" }).link then
    vim.api.nvim_set_hl(0, "OrgClockSum", { link = "Comment", default = true })
  end
end

--- Restore the running clock after a restart.
function M.restore()
  if M.state then
    return M.state
  end
  local cfg = clock_cfg()
  if cfg.persist and cfg.persist_file then
    local data = utils.read_json(cfg.persist_file)
    if type(data) == "table" then
      if type(data.last) == "table" then
        M.last = data.last
      end
      if type(data.state) == "table" and data.state.path and data.state.start then
        M.state = data.state
        if M.find_open_clock() then
          return M.state
        end
        M.state = nil
      end
    end
  end
  for _, f in ipairs(files.agenda_files()) do
    for _, hl in ipairs(f.headlines) do
      for _, c in ipairs(hl.clocks) do
        if not c["end"] then
          M.state = {
            path = f.filename,
            start = c.start:clone({ active = false }):to_string({ range = false }),
            title = hl:plain_title(),
            effort = require("org.properties").effort_minutes(hl),
          }
          return M.state
        end
      end
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Clock table
---------------------------------------------------------------------------

--- Resolve a :block value to [from_min, to_min) (minutes), plus a label.
function M.block_range(block)
  if not block or block == "" then
    return nil
  end
  block = tostring(block)
  local today = date.today()
  local function span(d1, d2)
    return d1:days() * 1440, d2:days() * 1440
  end
  local rel_n
  local base, n = block:match("^(%a+)%-(%d+)$")
  if base then
    block, rel_n = base, tonumber(n)
  end
  rel_n = rel_n or 0
  if block == "today" then
    local d = today:add(-rel_n, "d")
    return span(d, d:add(1, "d"))
  elseif block == "yesterday" then
    local d = today:add(-1 - rel_n, "d")
    return span(d, d:add(1, "d"))
  elseif block == "thisweek" or block == "lastweek" then
    local s = today:start_of("week"):add(-7 * (rel_n + (block == "lastweek" and 1 or 0)), "d")
    return span(s, s:add(7, "d"))
  elseif block == "thismonth" or block == "lastmonth" then
    local s = today:start_of("month"):add(-(rel_n + (block == "lastmonth" and 1 or 0)), "m")
    return span(s, s:add(1, "m"))
  elseif block == "thisyear" or block == "lastyear" then
    local s = today:start_of("year"):add(-(rel_n + (block == "lastyear" and 1 or 0)), "y")
    return span(s, s:add(1, "y"))
  end
  local y, m, d = block:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y then
    local s = date.Date.new({ year = tonumber(y), month = tonumber(m), day = tonumber(d) })
    return span(s, s:add(1, "d"))
  end
  local wy, w = block:match("^(%d%d%d%d)%-W(%d%d?)$")
  if wy then
    -- ISO week: week 1 contains Jan 4th
    local jan4 = date.Date.new({ year = tonumber(wy), month = 1, day = 4 })
    local s = jan4:start_of("week"):add((tonumber(w) - 1) * 7, "d")
    return span(s, s:add(7, "d"))
  end
  y, m = block:match("^(%d%d%d%d)%-(%d%d?)$")
  if y then
    local s = date.Date.new({ year = tonumber(y), month = tonumber(m), day = 1 })
    return span(s, s:add(1, "m"))
  end
  y = block:match("^(%d%d%d%d)$")
  if y then
    local s = date.Date.new({ year = tonumber(y), month = 1, day = 1 })
    return span(s, s:add(1, "y"))
  end
  return nil
end

local function parse_time_param(v)
  if not v then
    return nil
  end
  v = tostring(v):gsub('^"', ""):gsub('"$', "")
  local d = date.parse(v)
  if not d then
    local inner = v:match("^[<%[](.*)[>%]]$") or v
    d = date.read_date(inner)
  end
  return d and d:minutes() or nil
end

--- Align a list of rows ("hline" or list of cells) into org table lines.
function M.format_table(rows)
  local widths = {}
  for _, r in ipairs(rows) do
    if r ~= "hline" then
      for i, c in ipairs(r) do
        widths[i] = math.max(widths[i] or 1, utils.width(c))
      end
    end
  end
  local out = {}
  for _, r in ipairs(rows) do
    if r == "hline" then
      local parts = {}
      for i = 1, #widths do
        parts[i] = string.rep("-", widths[i] + 2)
      end
      out[#out + 1] = "|" .. table.concat(parts, "+") .. "|"
    else
      local parts = {}
      for i = 1, #widths do
        local c = r[i] or ""
        if c:match("^%*?%-?%d+:%d%d%*?$") or c:match("^%-?%d+%.?%d*$") then
          parts[i] = " " .. utils.pad_left(c, widths[i]) .. " "
        else
          parts[i] = " " .. utils.pad_right(c, widths[i]) .. " "
        end
      end
      out[#out + 1] = "|" .. table.concat(parts, "|") .. "|"
    end
  end
  return out
end

local function matcher(match)
  if not match or match == "" then
    return nil
  end
  local ok, search = pcall(require, "org.agenda.search")
  if ok and type(search.compile) == "function" then
    local ok2, pred = pcall(search.compile, match)
    if ok2 and pred then
      return pred
    end
  end
  -- fallback: +tag / -tag terms only
  return function(hl)
    local tags = hl:get_tags()
    for sign, tag in match:gmatch("([%+%-]?)([%w_@#%%]+)") do
      local has = vim.tbl_contains(tags, tag)
      if (sign == "-" and has) or (sign ~= "-" and not has) then
        return false
      end
    end
    return true
  end
end

--- Build clock table lines for a dynamic block.
---@param params table parsed block parameters (:scope, :maxlevel, :block, ...)
---@param bufnr integer buffer containing the block
---@param lnum? integer line of the block (for :scope subtree)
---@return string[]
function M.clocktable(params, bufnr, lnum)
  params = params or {}
  local defaults = clock_cfg().clocktable_default or {}
  local scope = params.scope or defaults.scope or "file"
  local maxlevel = tonumber(params.maxlevel or defaults.maxlevel) or 3
  local from_min, to_min = M.block_range(params.block or defaults.block)
  local ts = parse_time_param(params.tstart)
  local te = parse_time_param(params.tend)
  if ts then
    from_min = ts
  end
  if te then
    to_min = te
  end
  local pred = matcher(params.match)
  local show_tags = params.tags and params.tags ~= "nil" and params.tags ~= false
  local emphasize = params.emphasize and params.emphasize ~= "nil" and params.emphasize ~= false
  local link = params.link and params.link ~= "nil" and params.link ~= false
  local fileskip0 = params.fileskip0 and params.fileskip0 ~= "nil" and params.fileskip0 ~= false

  local file_list = {}
  local roots
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local cur = files.get_buffer(bufnr)
  if scope == "agenda" or scope == "agenda-with-archives" then
    file_list = files.agenda_files()
    if scope == "agenda-with-archives" then
      for _, f in ipairs(vim.deepcopy(vim.tbl_map(function(x)
        return x.filename
      end, file_list))) do
        local a = f and files.get(f .. "_archive")
        if a then
          file_list[#file_list + 1] = a
        end
      end
    end
  elseif scope == "subtree" or scope == "tree" then
    local hl = cur:headline_at(lnum or 1)
    if scope == "tree" then
      while hl and hl.parent do
        hl = hl.parent
      end
    end
    file_list = { cur }
    roots = hl and { hl } or {}
  elseif scope == "file-with-archives" then
    file_list = { cur }
    if cur.filename then
      local a = files.get(cur.filename .. "_archive")
      if a then
        file_list[#file_list + 1] = a
      end
    end
  elseif type(scope) == "string" and scope ~= "file" then
    -- explicit file list: ("a.org" "b.org") or a single path
    for p in scope:gmatch('[^%s%(%)"]+') do
      local f = files.get(utils.expand(p, cur.filename and vim.fn.fnamemodify(cur.filename, ":h") or nil))
      if f then
        file_list[#file_list + 1] = f
      end
    end
  else
    file_list = { cur }
  end
  local multi = #file_list > 1 or scope == "agenda"

  -- collect rows
  local total_all = 0
  local file_sections = {}
  local depth_used = 1
  for _, f in ipairs(file_list) do
    local rows = {}
    local file_total = 0
    local function walk(hl, level)
      if hl.level > maxlevel and not roots then
        return
      end
      local m = M.sum_minutes(hl, from_min, to_min)
      if m <= 0 then
        return
      end
      if pred and not pred(hl) then
        -- still descend: children may match
        for _, c in ipairs(hl.children) do
          walk(c, level)
        end
        return
      end
      rows[#rows + 1] = { hl = hl, level = level, minutes = m }
      depth_used = math.max(depth_used, level)
      if level < maxlevel then
        for _, c in ipairs(hl.children) do
          walk(c, level + 1)
        end
      end
    end
    local tops = roots or f.children
    for _, hl in ipairs(tops) do
      walk(hl, 1)
    end
    for _, r in ipairs(rows) do
      if r.level == 1 or not pred then
        if r.level == 1 then
          file_total = file_total + r.minutes
        end
      end
    end
    if pred then
      -- non-overlapping totals for filtered tables
      file_total = 0
      local counted = {}
      for _, r in ipairs(rows) do
        local p, covered = r.hl.parent, false
        while p do
          if counted[p] then
            covered = true
          end
          p = p.parent
        end
        if not covered then
          counted[r.hl] = true
          file_total = file_total + r.minutes
        end
      end
    end
    total_all = total_all + file_total
    if not (fileskip0 and file_total == 0) then
      file_sections[#file_sections + 1] = { file = f, rows = rows, total = file_total }
    end
  end

  local ncols = depth_used
  local header = {}
  if multi then
    header[#header + 1] = "File"
  end
  header[#header + 1] = "Headline"
  if show_tags then
    header[#header + 1] = "Tags"
  end
  header[#header + 1] = "Time"
  for _ = 2, ncols do
    header[#header + 1] = ""
  end
  local width = #header
  local function row(cells)
    for i = #cells + 1, width do
      cells[i] = ""
    end
    return cells
  end
  local fmt = date.format_duration
  local out_rows = { header, "hline" }
  local lead = multi and { "" } or {}
  local total_row = vim.list_extend(vim.deepcopy(lead), { "*Total time*" })
  if show_tags then
    total_row[#total_row + 1] = ""
  end
  total_row[#total_row + 1] = "*" .. fmt(total_all) .. "*"
  out_rows[#out_rows + 1] = row(total_row)
  for _, sec in ipairs(file_sections) do
    out_rows[#out_rows + 1] = "hline"
    if multi then
      local fr = { vim.fn.fnamemodify(sec.file.filename or "", ":t"), "*File time*" }
      if show_tags then
        fr[#fr + 1] = ""
      end
      fr[#fr + 1] = "*" .. fmt(sec.total) .. "*"
      out_rows[#out_rows + 1] = row(fr)
    end
    for _, r in ipairs(sec.rows) do
      local title = r.hl:plain_title():gsub("|", "\\vert{}")
      if link and sec.file.filename then
        title = string.format("[[file:%s::*%s][%s]]", sec.file.filename, r.hl:plain_title(), title)
      end
      if emphasize and r.level == 1 then
        title = "*" .. title .. "*"
      end
      if r.level > 1 then
        title = "\\_" .. string.rep(" ", 2 * (r.level - 1)) .. title
      end
      local cells = vim.deepcopy(lead)
      cells[#cells + 1] = title
      if show_tags then
        cells[#cells + 1] = table.concat(r.hl:get_tags(), ":")
      end
      for lvl = 1, ncols do
        local v = ""
        if lvl == r.level then
          v = fmt(r.minutes)
          if emphasize and r.level == 1 then
            v = "*" .. v .. "*"
          end
        end
        cells[#cells + 1] = v
      end
      out_rows[#out_rows + 1] = row(cells)
    end
  end
  local lines = { "#+CAPTION: Clock summary at " .. date.now():clone({ active = false }):to_string() }
  if params.block then
    lines[1] = lines[1] .. ", for " .. tostring(params.block) .. "."
  end
  vim.list_extend(lines, M.format_table(out_rows))
  return lines
end

return M
