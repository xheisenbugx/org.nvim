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
--- Recently clocked tasks, newest first (org-clock-history).
---@type { path: string, title: string, id?: string }[]
M.history = {}

local display_ns = vim.api.nvim_create_namespace("org.clock.display")

local function clock_cfg()
  return config.opts.clock or {}
end

local function persist()
  local cfg = clock_cfg()
  if not cfg.persist or not cfg.persist_file then
    return
  end
  pcall(utils.write_json, cfg.persist_file, {
    state = M.state or vim.NIL,
    last = M.last or vim.NIL,
    history = M.history,
  })
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

--- Drawer for clock lines (org-clock-into-drawer): the (inherited)
--- CLOCK_INTO_DRAWER property, then `clock.into_drawer`.
---@param hl? org.Headline
local function drawer_name(hl)
  local into = clock_cfg().into_drawer
  local prop = hl and hl:get_property("CLOCK_INTO_DRAWER", true)
  if prop and prop ~= "" then
    if prop == "nil" then
      into = false
    elseif prop == "t" or prop:match("^%d+$") then
      into = true
    else
      into = prop
    end
  end
  if into == false then
    return nil
  end
  if type(into) == "string" then
    return into
  end
  return edit.log_drawer_name(hl) or "LOGBOOK"
end

--- Remember a clocked task in the history (newest first, no duplicates).
local function push_history(entry)
  local max = clock_cfg().history_length or 35
  local out = { entry }
  for _, h in ipairs(M.history) do
    if #out >= max then
      break
    end
    if not (h.path == entry.path and ((entry.id and h.id == entry.id) or h.title == entry.title)) then
      out[#out + 1] = h
    end
  end
  M.history = out
end

---------------------------------------------------------------------------
-- Effort
---------------------------------------------------------------------------

local effort_timer

local function stop_effort_timer()
  if effort_timer then
    effort_timer:stop()
    effort_timer:close()
    effort_timer = nil
  end
end

--- Notify once when the running clock reaches the task's effort
--- (org-clock-notify-once-if-expired).
local function start_effort_timer()
  stop_effort_timer()
  local a = M.active()
  if not a or not a.effort or a.effort <= 0 or clock_cfg().notify_effort == false then
    return
  end
  local remaining = a.effort - a.minutes
  if remaining < 0 then
    return
  end
  local start = M.state.start
  effort_timer = vim.uv.new_timer()
  effort_timer:start(remaining * 60000 + 1000, 0, function()
    vim.schedule(function()
      stop_effort_timer()
      local cur = M.active()
      if cur and M.state.start == start and cur.effort and cur.minutes >= cur.effort then
        utils.notify(
          string.format("Task '%s' should be finished by now. (%s)", cur.title, date.format_duration(cur.effort)),
          vim.log.levels.WARN
        )
      end
    end)
  end)
end

--- Remove an empty drawer whose start line is `s`.
local function remove_empty_drawer(bufnr, s)
  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, s + 1, false)
  if lines[1] and lines[2] and lines[1]:match("^%s*:[%w_%-]+:%s*$") and lines[2]:match("^%s*:END:%s*$") then
    vim.api.nvim_buf_set_lines(bufnr, s - 1, s + 1, false, {})
  end
end

--- Clock out of the running clock. Interactively (no `opts`) with a
--- count, ask for the TODO state to switch the task to (org-clock-out with
--- C-u); otherwise `clock.out_switch_to_state` applies.
---@param opts? { at?: table, switch_to_state?: string|false, note?: string|false }
function M.clock_out(opts)
  local interactive = type(opts) ~= "table"
  opts = type(opts) == "table" and opts or {}
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
    local file = files.get_buffer(bufnr)
    if opts.note ~= false and require("org.todo").log_setting(file, "clock_out", file:headline_at(lnum)) == "note" then
      -- org-log-note-clock-out: the note goes right below the CLOCK line
      local note = opts.note or utils.input({ prompt = "Clock-out note: " })
      if note and vim.trim(note) ~= "" then
        local note_lines = vim.split(note, "\n")
        local out = { indent .. "- " .. note_lines[1] }
        for i = 2, #note_lines do
          out[#out + 1] = indent .. "  " .. note_lines[i]
        end
        vim.api.nvim_buf_set_lines(bufnr, lnum, lnum, false, out)
      end
    end
  end
  local id = M.last and M.last.path == st.path and M.last.title == st.title and M.last.id or nil
  M.last = { path = st.path, title = st.title, id = id, out = stop:clone({ active = false }):to_string() }
  persist()
  stop_effort_timer()
  -- org-clock-out-switch-to-state
  local switch = opts.switch_to_state
  if switch == nil then
    if interactive and vim.v.count > 0 then
      local todo_cfg = files.get_buffer(bufnr).settings.todo
      switch = utils.input_complete("Switch to state: ", todo_cfg:names(), todo_cfg:first_done() or "")
    else
      switch = clock_cfg().out_switch_to_state
    end
  end
  local hl = files.get_buffer(bufnr):headline_at(math.min(lnum, vim.api.nvim_buf_line_count(bufnr)))
  if hl then
    if type(switch) == "function" then
      switch = switch(hl.todo)
    end
    if type(switch) == "string" and switch ~= "" and hl.todo ~= switch then
      require("org.todo").change_state({ bufnr = bufnr, lnum = hl.line }, switch)
    end
  end
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
  stop_effort_timer()
  vim.cmd("redrawstatus")
  return true
end

--- Start clocking the headline at target.
---@param target? org.Target
---@param opts? { at?: table }
function M.clock_in(target, opts)
  opts = opts or {}
  if target == nil and vim.v.count > 0 and not opts.at then
    return M.clock_in_select()
  end
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
    M.clock_out({})
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
  local start = opts.at or date.now()
  if not opts.at and clock_cfg().continuously and M.last and M.last.out then
    -- org-clock-continuously: start where the last clock stopped
    local out = date.parse(M.last.out)
    if out and out:minutes() <= start:minutes() then
      start = out
    end
  end
  start = start:clone({ active = false })
  local start_str = start:to_string({ range = false })
  local drawer = drawer_name(hl)
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
  push_history(M.last)
  persist()
  start_effort_timer()
  utils.notify("Clock started: " .. M.state.title)
  vim.cmd("redrawstatus")
  return M.state
end

--- Find the headline of a clocked-task entry (by ID, then title).
local function find_entry(last)
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

local function find_last()
  return find_entry(M.last)
end

--- Clock in a task picked from the clock history (org-clock-in with C-u).
function M.clock_in_select()
  local items = {}
  for _, h in ipairs(M.history) do
    if utils.exists(h.path) then
      items[#items + 1] = h
    end
  end
  if #items == 0 then
    utils.notify("No clock history")
    return nil
  end
  local choice = utils.select(items, {
    prompt = "Clock in",
    format_item = function(h)
      return h.title .. "  (" .. vim.fn.fnamemodify(h.path, ":t") .. ")"
    end,
  })
  if not choice then
    return nil
  end
  local bufnr, lnum = find_entry(choice)
  if not bufnr then
    utils.warn("Cannot find task: " .. choice.title)
    return nil
  end
  return M.clock_in({ bufnr = bufnr, lnum = lnum })
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

--- Shift both timestamps of the CLOCK line at the cursor by `n` units of
--- the part under the cursor, keeping the duration (org-clock-timestamps-up
--- / -down, C-S-Up / C-S-Down). Returns false when not on a closed clock.
---@param n integer
function M.timestamps_shift(n)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  local c = parser.parse_clock_line(line)
  if not c or not c["end"] then
    return false
  end
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local s1 = line:find("[", 1, true)
  local s2 = line:find("--[", 1, true)
  if not s1 or not s2 then
    return false
  end
  local on_end = col > s2 + 1
  if col < s1 then
    vim.api.nvim_win_set_cursor(0, { lnum, s1 })
  end
  if not require("org.timestamps").increment(n) then
    return false
  end
  local new = parser.parse_clock_line(vim.api.nvim_get_current_line())
  if not new or not new["end"] then
    return true
  end
  local start, stop = new.start, new["end"]
  if on_end then
    start = start:add(stop:minutes() - c["end"]:minutes(), "min")
  else
    stop = stop:add(start:minutes() - c.start:minutes(), "min")
  end
  local text = M.format_clock_line(line:match("^(%s*)"), start, stop)
  local cursor = vim.api.nvim_win_get_cursor(0)
  vim.api.nvim_buf_set_lines(0, lnum - 1, lnum, false, { text })
  vim.api.nvim_win_set_cursor(0, { lnum, math.min(cursor[2], #text - 1) })
  return true
end

--- Open CLOCK lines in the agenda files (and loaded org buffers) other
--- than the running clock: list of { bufnr, lnum, start, title }.
function M.dangling_clocks()
  local out, seen = {}, {}
  local running_buf, running_lnum = M.find_open_clock()
  local function scan(bufnr)
    if seen[bufnr] then
      return
    end
    seen[bufnr] = true
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, l in ipairs(lines) do
      local c = l:find("CLOCK:", 1, true) and parser.parse_clock_line(l)
      if c and not c["end"] and not (bufnr == running_buf and i == running_lnum) then
        local hl = files.get_buffer(bufnr):headline_at(i)
        out[#out + 1] = { bufnr = bufnr, lnum = i, start = c.start, title = hl and hl:plain_title() or "?" }
      end
    end
  end
  for _, f in ipairs(files.agenda_files()) do
    if f.filename and utils.exists(f.filename) then
      scan(utils.load_buffer(f.filename))
    end
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "org" then
      scan(b)
    end
  end
  return out
end

--- Resolve open clocks that are not the running one (org-resolve-clocks):
--- for each, keep it (close it now, or after N minutes), cancel it (remove
--- the line), jump to it, or skip it.
function M.resolve_clocks()
  local list = M.dangling_clocks()
  if #list == 0 then
    utils.notify("No dangling clocks")
    return true
  end
  -- bottom-up per buffer so line numbers stay valid
  table.sort(list, function(a, b)
    return a.bufnr == b.bufnr and a.lnum > b.lnum or a.bufnr < b.bufnr
  end)
  for _, d in ipairs(list) do
    local ago = date.now():minutes() - d.start:minutes()
    local choice = require("org.ui").menu({
      title = string.format("Dangling clock started %d mins ago: %s", ago, d.title),
      items = {
        { key = "k", label = "Keep: clock out now, or after N minutes", value = "k" },
        { key = "C", label = "Cancel: remove the clock line", value = "C" },
        { key = "j", label = "Jump to the clock", value = "j" },
        { key = "i", label = "Ignore", value = "i" },
      },
    })
    local line = vim.api.nvim_buf_get_lines(d.bufnr, d.lnum - 1, d.lnum, false)[1] or ""
    if choice == "k" then
      local keep = utils.input({ prompt = string.format("Keep how many minutes? (default all, %d): ", ago) })
      if keep == nil then
        return nil
      end
      local minutes = tonumber(vim.trim(keep)) or ago
      local stop = d.start:add(math.max(0, math.min(minutes, ago)), "min")
      local text = M.format_clock_line(line:match("^(%s*)"), d.start, stop)
      vim.api.nvim_buf_set_lines(d.bufnr, d.lnum - 1, d.lnum, false, { text })
    elseif choice == "C" then
      vim.api.nvim_buf_set_lines(d.bufnr, d.lnum - 1, d.lnum, false, {})
      local prev = vim.api.nvim_buf_get_lines(d.bufnr, d.lnum - 2, d.lnum - 1, false)[1]
      if prev and prev:match("^%s*:[%w_%-]+:%s*$") then
        remove_empty_drawer(d.bufnr, d.lnum - 1)
      end
    elseif choice == "j" then
      utils.open_file(vim.api.nvim_buf_get_name(d.bufnr), d.lnum)
      return true
    elseif choice == nil then
      return nil
    end
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

--- Headline of the running clock: bufnr, headline (or nil).
local function clocked_headline()
  local bufnr, lnum = M.find_open_clock()
  if not bufnr then
    return nil
  end
  local hl = files.get_buffer(bufnr):headline_at(lnum)
  return hl and bufnr, hl
end

--- Refresh the running clock's effort after the entry's Effort changed.
function M.effort_changed(bufnr, lnum)
  if M.state and M.is_clocked_headline(bufnr, lnum) then
    local hl = files.get_buffer(bufnr):headline_at(lnum)
    M.state.effort = require("org.properties").effort_minutes(hl)
    persist()
    start_effort_timer()
    vim.cmd("redrawstatus")
  end
end

--- Set or change the effort of the clocked task
--- (org-clock-modify-effort-estimate). `value` may be relative: `+0:15`,
--- `-10`. Without a running clock, acts on the entry at the cursor.
---@param value? string
function M.modify_effort(value)
  local bufnr, hl = clocked_headline()
  if not bufnr then
    local _
    bufnr, _, hl = edit.resolve_headline(nil)
    if not bufnr then
      return nil
    end
  end
  local prop = config.opts.effort_property or "Effort"
  local current = hl.properties[prop:upper()]
  if value == nil then
    value = utils.input({
      prompt = "Set effort (hh:mm or mm" .. (current and (", prefix + to add to " .. current) or "") .. "): ",
    })
    if not value or vim.trim(value) == "" then
      return nil
    end
  end
  value = vim.trim(tostring(value))
  local sign = value:sub(1, 1)
  local base = 0
  if sign == "+" or sign == "-" then
    base = current and date.parse_duration(current) or 0
    value = value:sub(2)
  end
  local minutes = date.parse_duration(value)
  if not minutes then
    utils.warn("Invalid effort: " .. value)
    return nil
  end
  if sign == "-" then
    minutes = base - minutes
  elseif sign == "+" then
    minutes = base + minutes
  end
  local str = date.duration_to_string(math.max(0, minutes))
  edit.set_property(bufnr, hl.line, prop, str)
  M.effort_changed(bufnr, hl.line)
  utils.notify("Effort is now " .. str)
  return str
end

--- Set the effort to the next value of `Effort_ALL` (org-inc-effort).
function M.inc_effort(target)
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local prop = config.opts.effort_property or "Effort"
  local allowed = hl:get_allowed_values(prop)
  if not allowed or #allowed == 0 then
    utils.warn("Allowed effort values are not set (" .. prop .. "_ALL)")
    return nil
  end
  local current = hl.properties[prop:upper()]
  local nxt
  if not current then
    nxt = allowed[1]
  else
    for i, v in ipairs(allowed) do
      if v == current then
        nxt = allowed[i + 1]
      end
    end
    if not nxt then
      utils.warn(string.format("Unknown value %q among allowed values", current))
      return nil
    end
  end
  edit.set_property(bufnr, hl.line, prop, nxt)
  M.effort_changed(bufnr, hl.line)
  utils.notify(prop .. " is now " .. nxt)
  return nxt
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
        virt_text = { { " " .. date.duration_to_string(m) .. " ", "OrgClockSum" } },
        virt_text_pos = "eol",
      })
    end
  end
  utils.notify("Total file time: " .. date.duration_to_string(total))
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
      if type(data.history) == "table" and vim.islist(data.history) then
        M.history = data.history
      end
      if type(data.state) == "table" and data.state.path and data.state.start then
        M.state = data.state
        if M.find_open_clock() then
          start_effort_timer()
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
        if c:match("^[*/]?%-?%d+:%d%d[*/]?$") or c:match("^[*/]?%-?%d+d %d+:%d%d[*/]?$") or c:match("^%-?%d+%.?%d*$") then
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

local function param_on(v)
  return v ~= nil and v ~= false and v ~= "nil"
end

--- Emacs `org-shorten-string`: cut at a word boundary and add "...".
local function shorten(s, max)
  if utils.width(s) <= max then
    return s
  end
  local n = math.max(max - 4, 1)
  local cut = s:sub(1, n + 2):match("^(.+[^ ]) ") or s:sub(1, math.max(max - 3, 0))
  return cut .. "..."
end

--- Files and root headlines covered by a clocktable :scope.
local function scope_files(scope, cur, lnum)
  local file_list, roots = {}, nil
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
  elseif scope == "subtree" or scope == "tree" or (type(scope) == "string" and scope:match("^tree%d$")) then
    local hl = cur:headline_at(lnum or 1)
    local level = tonumber(scope:match("^tree(%d)$") or "")
    if scope == "tree" then
      level = 1
    end
    if level then
      while hl and hl.parent and hl.level > level do
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
  return file_list, roots
end

--- One clock table (org-clocktable-write-default) for [from_min, to_min).
---@return string[] lines, integer total minutes
local function clocktable_single(params, bufnr, lnum, from_min, to_min)
  local defaults = clock_cfg().clocktable_default or {}
  local scope = params.scope or defaults.scope or "file"
  local maxlevel = tonumber(params.maxlevel or defaults.maxlevel) or 3
  local pred = matcher(params.match)
  local show_tags = param_on(params.tags)
  local emphasize = param_on(params.emphasize)
  local link = param_on(params.link)
  local fileskip0 = param_on(params.fileskip0)
  local compact = param_on(params.compact)
  local show_level = param_on(params.level) and not compact
  local show_ts = param_on(params.timestamp)
  local indent = compact or params.indent == nil or param_on(params.indent)
  local percent = params.formula == "%"
  local props = {}
  if type(params.properties) == "string" then
    for p in params.properties:gmatch('[^%s%(%)"]+') do
      props[#props + 1] = p
    end
  end
  local inherit_props = param_on(params["inherit-props"])
  local narrow = params.narrow
  if narrow == nil then
    narrow = "40!"
  end
  local narrow_cut = narrow and tostring(narrow):match("^(%d+)!$")
  narrow_cut = tonumber(narrow_cut or (link and tonumber(narrow)) or "")

  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local cur = files.get_buffer(bufnr)
  local file_list, roots = scope_files(scope, cur, lnum)
  local multi = (#file_list > 1 or scope == "agenda") and not param_on(params.hidefiles)

  -- collect rows
  local total_all = 0
  local file_sections = {}
  local depth_used = 1
  for _, f in ipairs(file_list) do
    local rows = {}
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
    for _, hl in ipairs(roots or f.children) do
      walk(hl, 1)
    end
    -- non-overlapping total (filtered tables may skip parents)
    local file_total = 0
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
    total_all = total_all + file_total
    if not (fileskip0 and file_total == 0) then
      file_sections[#file_sections + 1] = { file = f, rows = rows, total = file_total }
    end
  end

  local ncols = (compact or maxlevel < 2) and 1 or math.min(maxlevel, tonumber(params.tcolumns) or 100, depth_used)
  local fmt = date.duration_to_string
  local function pct(m)
    return total_all > 0 and string.format("%.1f", 100 * m / total_all) or "0.0"
  end
  -- leading cells: File, L, Timestamp, Tags, properties
  local function lead(file_cell, level, ts, tags, values)
    local cells = {}
    if multi then
      cells[#cells + 1] = file_cell or ""
    end
    if show_level then
      cells[#cells + 1] = level and tostring(level) or ""
    end
    if show_ts then
      cells[#cells + 1] = ts or ""
    end
    if show_tags then
      cells[#cells + 1] = tags or ""
    end
    for i = 1, #props do
      cells[#cells + 1] = values and values[i] or ""
    end
    return cells
  end
  local function time_cells(cells, col, value)
    for i = 1, ncols do
      cells[#cells + 1] = i == col and value or ""
    end
    return cells
  end

  local header = lead("File", "L", "Timestamp", "Tags", props)
  header[#header + 1] = "Headline"
  time_cells(header, 1, "Time")
  if percent then
    header[#header + 1] = "%"
  end
  local total_row = lead(multi and "ALL" or "")
  total_row[#total_row + 1] = "*Total time*"
  time_cells(total_row, 1, "*" .. fmt(total_all) .. "*")
  if percent then
    total_row[#total_row + 1] = total_all > 0 and "100.0" or "0.0"
  end
  local out_rows = { header, "hline", total_row }
  if total_all > 0 then
    for _, sec in ipairs(file_sections) do
      out_rows[#out_rows + 1] = "hline"
      if multi then
        local fr = lead(vim.fn.fnamemodify(sec.file.filename or "", ":t"))
        fr[#fr + 1] = "*File time*"
        time_cells(fr, 1, "*" .. fmt(sec.total) .. "*")
        if percent then
          fr[#fr + 1] = pct(sec.total)
        end
        out_rows[#out_rows + 1] = fr
      end
      for _, r in ipairs(sec.rows) do
        local hl = r.hl
        local plain = hl:plain_title():gsub("|", "\\vert{}")
        local title = narrow_cut and shorten(plain, narrow_cut) or plain
        if link and sec.file.filename then
          title = string.format("[[file:%s::*%s][%s]]", sec.file.filename, hl:plain_title(), title)
        end
        local function emph(s)
          if emphasize and r.level == 1 then
            return "*" .. s .. "*"
          elseif emphasize and r.level == 2 then
            return "/" .. s .. "/"
          end
          return s
        end
        title = emph(title)
        if indent and r.level > 1 then
          title = "\\_" .. string.rep(" ", 2 * (r.level - 1)) .. title
        end
        local ts
        if show_ts then
          ts = hl:get_property("SCHEDULED") or hl:get_property("DEADLINE") or hl:get_property("TIMESTAMP")
        end
        local values = {}
        for i, p in ipairs(props) do
          values[i] = hl:get_property(p, inherit_props or nil) or ""
        end
        local cells = lead("", r.level, ts, table.concat(hl:get_tags(), ", "), values)
        cells[#cells + 1] = title
        time_cells(cells, math.min(r.level, ncols), emph(fmt(r.minutes)))
        if percent then
          cells[#cells + 1] = pct(r.minutes)
        end
        out_rows[#out_rows + 1] = cells
      end
    end
  end
  local lines = {}
  if params.header then
    if params.header ~= "" then
      vim.list_extend(lines, vim.split((tostring(params.header):gsub("\\n", "\n")), "\n"))
    end
  else
    lines[1] = "#+CAPTION: Clock summary at " .. date.now():clone({ active = false }):to_string()
    if params.block then
      lines[1] = lines[1] .. ", for " .. tostring(params.block) .. "."
    end
  end
  vim.list_extend(lines, M.format_table(out_rows))
  return lines, total_all
end

--- Start of the step period after `d` (org-clocktable-steps).
local function next_step(d, step, wstart)
  if step == "day" then
    return d:add(1, "d")
  elseif step == "week" then
    local dow = d:weekday() % 7 -- 0 = Sunday, like Emacs
    local offset = dow == wstart and 7 or (wstart - dow) % 7
    return d:add(offset, "d")
  elseif step == "semimonth" then
    if d.day < 16 then
      return d:clone({ day = 16 })
    end
    return d:clone({ day = 1 }):add(1, "m")
  elseif step == "month" then
    return d:clone({ day = 1 }):add(1, "m")
  elseif step == "quarter" then
    return d:clone({ day = 1 }):add(3, "m")
  elseif step == "year" then
    return date.Date.new({ year = d.year + 1, month = 1, day = 1 })
  end
end

local STEP_HEADERS = {
  day = "Daily report: ",
  week = "Weekly report starting on: ",
  semimonth = "Semimonthly report starting on: ",
  month = "Monthly report starting on: ",
  quarter = "Quarterly report starting on: ",
  year = "Annual report starting on: ",
}

--- Build clock table lines for a dynamic block. Parameters follow Emacs:
--- :scope :maxlevel :block :tstart :tend :step :stepskip0 :wstart :match
--- :tags :emphasize :link :fileskip0 :hidefiles :level :timestamp
--- :properties :inherit-props :formula % :compact :indent :narrow
--- :tcolumns :header.
---@param params table parsed block parameters
---@param bufnr integer buffer containing the block
---@param lnum? integer line of the block (for :scope subtree)
---@return string[]
function M.clocktable(params, bufnr, lnum)
  params = params or {}
  local defaults = clock_cfg().clocktable_default or {}
  local from_min, to_min = M.block_range(params.block or defaults.block)
  local ts = parse_time_param(params.tstart)
  local te = parse_time_param(params.tend)
  if ts then
    from_min = ts
  end
  if te then
    to_min = te
  end
  local step = params.step and tostring(params.step)
  if not step then
    return (clocktable_single(params, bufnr, lnum, from_min, to_min))
  end
  if not STEP_HEADERS[step] then
    return { "Unknown :step specification: " .. step }
  end
  if not from_min then
    return { ":step needs a :block or :tstart" }
  end
  to_min = to_min or date.now():minutes()
  local wstart = (tonumber(params.wstart) or 1) % 7
  local sub = vim.tbl_extend("force", params, { header = "", block = false })
  local out = {}
  local d = date.from_days(math.floor(from_min / 1440))
  local guard = 0
  while d:minutes() < to_min and guard < 1000 do
    guard = guard + 1
    local nxt = next_step(d, step, wstart)
    local lines, total = clocktable_single(sub, bufnr, lnum, math.max(d:minutes(), from_min), math.min(nxt:minutes(), to_min))
    if not (param_on(params.stepskip0) and total == 0) then
      out[#out + 1] = ""
      out[#out + 1] = STEP_HEADERS[step] .. d:clone({ active = false }):to_string()
      vim.list_extend(out, lines)
    end
    d = nxt
  end
  return out
end

return M
