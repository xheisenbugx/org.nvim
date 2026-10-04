---@mod org.clock.clocking Clocking in and out
---
--- Clock in, out and cancel, picking a task from the history, the
--- default and interrupted tasks, and going to the clocked task.
---
--- Part of org.clock, which loads it.

local date = require("org.date")
local edit = require("org.edit")
local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.clock.shared")

local M = require("org.clock")

local at_minutes = shared.at_minutes
local buf_path = shared.buf_path
local clock_cfg = shared.clock_cfg
local current_time = shared.current_time
local delete_clock_line = shared.delete_clock_line
local fire = shared.fire
local hook_exit = shared.hook_exit
local hook_rename = shared.hook_rename
local insert_clock_line = shared.insert_clock_line
local mark_ns = shared.mark_ns
local mode_line_heading = shared.mode_line_heading
local persist = shared.persist
local push_history = shared.push_history
local start_timers = shared.start_timers
local stop_timers = shared.stop_timers
local task_of = shared.task_of
local total_before = shared.total_before
local unnamed = shared.unnamed

---------------------------------------------------------------------------
-- Clock out / cancel
---------------------------------------------------------------------------

--- Clock out of the running clock. Interactively (no `opts`) with a
--- count, ask for the TODO state to switch the task to (org-clock-out with
--- C-u); otherwise `clock.out_switch_to_state` applies.
---@param opts? { at?: table, switch_to_state?: string|false, note?: string|false }
function M.clock_out(opts)
  local interactive = type(opts) ~= "table"
  opts = type(opts) == "table" and opts or {}
  if not M.state then
    if not opts.quiet then
      utils.notify("No active clock")
    end
    return nil
  end
  local bufnr, lnum = M.find_open_clock()
  local st = M.state
  M.state = nil
  stop_timers()
  persist()
  if not bufnr then
    utils.warn("Clock start time is gone: " .. st.title)
    vim.cmd("redrawstatus")
    return nil
  end
  local switch = opts.switch_to_state
  if switch == nil then
    if interactive and vim.v.count > 0 then
      local todo_cfg = files.get_buffer(bufnr).settings.todo
      switch = require("org.ui").choose({ prompt = "Switch to state: ", items = todo_cfg:names(), default = "DONE" })
    else
      switch = clock_cfg().out_switch_to_state
    end
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  local indent = line:match("^(%s*)")
  local clocked = files.get_buffer(bufnr):headline_at(lnum)
  local start = date.parse(st.start)
  local stop = (opts.at or current_time()):clone({ active = false })
  local new, minutes = M.format_clock_line(indent, start, stop)
  local removed = minutes == 0 and clock_cfg().out_remove_zero_time == true
  local hl_mark = clocked and vim.api.nvim_buf_set_extmark(bufnr, mark_ns, clocked.line - 1, 0, {})
  local clock_mark
  if removed then
    delete_clock_line(bufnr, lnum)
  else
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new })
    clock_mark = vim.api.nvim_buf_set_extmark(bufnr, mark_ns, lnum - 1, 0, {})
  end
  if M.last and M.last.path == st.path then
    M.last = vim.tbl_extend("force", M.last, { out = stop:to_string() })
  else
    M.last = { path = st.path, title = st.title, out = stop:to_string() }
  end
  persist()
  -- org-clock-out-switch-to-state (without clocking out again on DONE)
  local hl_line = hl_mark and vim.api.nvim_buf_get_extmark_by_id(bufnr, mark_ns, hl_mark, {})[1] + 1
  local hl = hl_line and files.get_buffer(bufnr):headline_on(hl_line)
  if hl then
    if type(switch) == "function" then
      switch = switch(hl.todo)
    end
    if type(switch) == "string" and switch ~= "" and hl.todo ~= switch then
      require("org.todo").change_state({ bufnr = bufnr, lnum = hl.line }, switch)
    end
  end
  utils.notify(
    string.format(
      removed and "Clock stopped at %s after %s => LINE REMOVED" or "Clock stopped at %s after %s",
      stop:to_string(),
      date.duration_to_string(minutes)
    )
  )
  fire("OrgClockOut", { path = st.path, title = st.title, minutes = minutes, removed = removed })
  -- org-log-note-clock-out: the note goes right below the CLOCK line
  if clock_mark and opts.note ~= false then
    local cl = vim.api.nvim_buf_get_extmark_by_id(bufnr, mark_ns, clock_mark, {})[1] + 1
    hl = files.get_buffer(bufnr):headline_at(cl)
    if require("org.todo").log_setting(files.get_buffer(bufnr), "clock_out", hl) == "note" then
      local note = opts.note
      if note == nil then
        note = utils.input_note({
          prompt = "Clock-out note (" .. st.title .. "): ",
          purpose = edit.note_purpose("clock-out"),
        })
      end
      -- a cancelled note (C-c C-k) stores nothing, not even the heading
      local out = note and edit.log_entry("clock-out", note)
      if out then
        for i, l in ipairs(out) do
          out[i] = indent .. l
        end
        vim.api.nvim_buf_set_lines(bufnr, cl, cl, false, out)
        -- org-store-log-note runs org-after-note-stored-hook for it too
        edit.note_stored(bufnr, cl + 1, hl and hl.line)
      end
    end
  end
  for _, m in ipairs({ hl_mark, clock_mark }) do
    pcall(vim.api.nvim_buf_del_extmark, bufnr, mark_ns, m)
  end
  vim.cmd("redrawstatus")
  return minutes
end

--- Cancel the running clock (remove the open CLOCK line).
function M.clock_cancel()
  if not M.state then
    utils.notify("No active clock")
    return nil
  end
  local bufnr, lnum = M.find_open_clock()
  local st = M.state
  M.state = nil
  stop_timers()
  persist()
  if bufnr then
    delete_clock_line(bufnr, lnum)
    utils.notify("Clock canceled")
  else
    utils.notify("Clock gone, cancel the timer anyway")
  end
  fire("OrgClockCancel", { path = st.path, title = st.title })
  vim.cmd("redrawstatus")
  return true
end

---------------------------------------------------------------------------
-- Picking tasks
---------------------------------------------------------------------------

--- Find the headline of a clocked-task entry (by ID, then title).
---@return integer|nil bufnr, integer|nil lnum
local function find_entry(task)
  if not task or not utils.exists(task.path) then
    return nil
  end
  local bufnr = utils.load_buffer(task.path)
  local file = files.get_buffer(bufnr)
  local hl = task.id and file:find_by_id(task.id) or nil
  hl = hl or file:find_by_title(task.title)
  if not hl then
    return nil
  end
  return bufnr, hl.line
end

--- The running clock as a task entry.
local function current_task()
  local bufnr, lnum = M.find_open_clock()
  if not bufnr then
    return nil
  end
  local hl = files.get_buffer(bufnr):headline_at(lnum)
  return hl and task_of(bufnr, hl)
end

--- The running clock's task `{ path, title, id }`, or nil.
function M.current_task()
  return M.state and current_task() or nil
end

--- Clock into a task entry `{ path, title, id }` (e.g. one returned by
--- `current_task`), found by ID or title.
function M.clock_in_task(task, opts)
  local bufnr, lnum = find_entry(task)
  if not bufnr then
    utils.warn("Cannot find task: " .. tostring(task and task.title))
    return nil
  end
  return M.clock_in({ bufnr = bufnr, lnum = lnum }, vim.tbl_extend("force", { no_count = true }, opts or {}))
end

--- Record a closed clock [start, stop] in the entry at (bufnr, lnum),
--- placed like clock_in places CLOCK lines. Returns the minutes, or nil
--- when a zero-length clock was dropped (`clock.out_remove_zero_time`).
function M.add_clock(bufnr, lnum, start, stop)
  local text, minutes = M.format_clock_line("", start, stop)
  if minutes == 0 and clock_cfg().out_remove_zero_time == true then
    return nil
  end
  insert_clock_line(bufnr, lnum, vim.trim(text))
  return minutes
end

--- Pick a task among the default, interrupted, current and recent tasks
--- (org-clock-select-task). Returns bufnr, lnum of its headline.
---@param prompt? string
---@return integer|nil bufnr, integer|nil lnum
function M.select_task(prompt)
  local items = {}
  local function add(key, task)
    local bufnr, lnum = find_entry(task)
    if not bufnr then
      return false
    end
    local hl = files.get_buffer(bufnr):headline_at(lnum)
    items[#items + 1] = {
      key = key,
      label = string.format("%-12s  %s", hl:get_category(), hl:plain_title()),
      value = { bufnr = bufnr, lnum = lnum },
    }
    return true
  end
  local function heading(text)
    items[#items + 1] = { heading = true, label = text }
  end
  local function section(text, key, task)
    if task then
      heading(text)
      if not add(key, task) then
        items[#items] = nil
      end
    end
  end
  section("Default Task", "d", M.default_task)
  section("The task interrupted by starting the last one", "i", M.interrupted)
  section("Current Clocking Task", "c", M.state and current_task() or nil)
  local recent, prev = {}, nil
  for _, h in ipairs(M.history) do
    if not (prev and prev.path == h.path and prev.title == h.title) then
      recent[#recent + 1] = h
    end
    prev = h
  end
  if #recent == 0 then
    utils.notify("No recent clock")
    return nil
  end
  heading("Recent Tasks")
  local n = 0
  for _, h in ipairs(recent) do
    local key = n < 9 and tostring(n + 1) or string.char(("A"):byte() + n - 9)
    if n < 35 and add(key, h) then
      n = n + 1
    end
  end
  local choice = require("org.ui").menu({ title = prompt or "Select task for clocking", items = items })
  if type(choice) ~= "table" or not choice.bufnr then
    return nil
  end
  return choice.bufnr, choice.lnum
end

--- Clock in a task picked from the clock history (org-clock-in with C-u).
function M.clock_in_select()
  local bufnr, lnum = M.select_task("Clock-in on task")
  if not bufnr then
    return nil
  end
  return M.clock_in({ bufnr = bufnr, lnum = lnum }, { no_count = true })
end

--- Mark the entry at the cursor as the default task (org-clock-mark-default-task).
function M.mark_default_task(target)
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  M.default_task = task_of(bufnr, hl)
  utils.notify("Default clocking task: " .. M.default_task.title)
  return M.default_task
end

---------------------------------------------------------------------------
-- Clock in
---------------------------------------------------------------------------

--- Start clocking the headline at target (org-clock-in). Interactively
--- (no target) a count picks a task from the history (C-u), 16 also marks
--- the entry at the cursor as the default task (C-u C-u), and 64 starts
--- the clock where the last one stopped (C-u C-u C-u).
---@param target? org.Target
---@param opts? { at?: table, resume?: boolean, switch_to_state?: string, no_count?: boolean }
function M.clock_in(target, opts)
  opts = opts or {}
  local count = (target == nil and not opts.at and not opts.no_count) and vim.v.count or 0
  if count >= 64 then
    local out = M.last and M.last.out and date.parse(M.last.out)
    return M.clock_in(nil, { at = out or nil, no_count = true, continuous = true })
  elseif count > 0 and count < 16 then
    return M.clock_in_select()
  end
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  if count >= 16 then
    M.mark_default_task({ bufnr = bufnr, lnum = hl.line })
  end
  local mark = vim.api.nvim_buf_set_extmark(bufnr, mark_ns, hl.line - 1, 0, {})
  local function target_line()
    return vim.api.nvim_buf_get_extmark_by_id(bufnr, mark_ns, mark, {})[1] + 1
  end
  local interrupting = M.state ~= nil and not opts.resolving_idle
  local leftover = not shared.resolving and M.leftover
  -- org-clock-auto-clock-resolution: resolve dangling clocks first
  local auto = clock_cfg().auto_clock_resolution
  if auto == nil then
    auto = "when-no-clock-is-running"
  end
  if auto and (not interrupting or auto == true) and not shared.resolving and not opts.clocking_in then
    M.leftover = nil
    if not M.resolve_clocks(false, { clocking_in = true, quiet = true }) then
      vim.api.nvim_buf_del_extmark(bufnr, mark_ns, mark)
      return nil
    end
  end
  if M.state and M.is_clocked_headline(bufnr, target_line()) then
    vim.api.nvim_buf_del_extmark(bufnr, mark_ns, mark)
    utils.notify("Clock continues in " .. M.state.title)
    return nil
  end
  if M.state then
    M.interrupted = current_task()
    M.clock_out({ switch_to_state = opts.out_switch_to_state, note = opts.note, quiet = true })
  else
    M.interrupted = nil
  end
  local lnum = target_line()
  fire("OrgClockInPrepare", { bufnr = bufnr, lnum = lnum })
  lnum = target_line()
  local file = files.get_buffer(bufnr)
  hl = file:headline_at(lnum)
  push_history(task_of(bufnr, hl))
  -- org-clock-in-switch-to-state
  local switch = opts.switch_to_state or clock_cfg().in_switch_to_state
  if type(switch) == "function" then
    switch = switch(hl.todo)
  end
  if type(switch) == "string" and switch ~= "" and hl.todo ~= switch and file.settings.todo:is_keyword(switch) then
    require("org.todo").change_state({ bufnr = bufnr, lnum = lnum }, switch)
    lnum = target_line()
  end
  vim.api.nvim_buf_del_extmark(bufnr, mark_ns, mark)
  hl = files.get_buffer(bufnr):headline_at(lnum)
  local start_str
  local resume = opts.resume or clock_cfg().in_resume
  if resume then
    for _, c in ipairs(hl.clocks) do
      if not c["end"] then
        -- org-clock-in-resume: continue the entry's open clock
        start_str = c.start:clone({ active = false }):to_string({ range = false })
        break
      end
    end
  end
  local total, sum_text = total_before(hl)
  if not start_str then
    local start
    local continuous = clock_cfg().continuously or opts.continuous
    local out = continuous and M.last and M.last.out and date.parse(M.last.out)
    if out and out:minutes() <= date.now():minutes() then
      start = out
    elseif leftover then
      local ago = date.elapsed_minutes(at_minutes(leftover), date.now())
      if utils.confirm(string.format("You stopped another clock %d mins ago; start this one from then?", ago)) then
        start = at_minutes(leftover)
      end
      M.leftover = nil
    end
    start = (start or opts.at or current_time(true)):clone({ active = false })
    start_str = start:to_string({ range = false })
    insert_clock_line(bufnr, lnum, "CLOCK: " .. start_str)
    hl = files.get_buffer(bufnr):headline_at(lnum)
  end
  M.state = {
    path = buf_path(bufnr) or "",
    bufnr = unnamed(bufnr),
    start = start_str,
    title = mode_line_heading(hl),
    effort = require("org.properties").effort_minutes(hl),
    total = total,
  }
  M.last = { path = M.state.path, title = hl:plain_title(), id = hl.properties.ID }
  shared.notified = false
  persist()
  start_timers()
  hook_exit()
  hook_rename()
  utils.notify("Clock starts at " .. start_str .. " - " .. sum_text)
  fire("OrgClockIn", { bufnr = bufnr, lnum = lnum, title = M.state.title })
  vim.cmd("redrawstatus")
  return M.state
end

--- Clock in the most recently clocked task (org-clock-in-last). With a
--- count: pick from the history (C-u), start where the last clock stopped
--- (16, C-u C-u), or ask for the TODO state to switch to (64).
function M.clock_in_last()
  local count = vim.v.count
  if count > 0 and count < 16 then
    return M.clock_in_select()
  end
  local task = M.history[1] or M.last
  if not task then
    utils.notify("No last clock")
    return nil
  end
  local bufnr, lnum = find_entry(task)
  if not bufnr then
    utils.notify("No last clock")
    return nil
  end
  local opts = { no_count = true }
  if count == 16 then
    local out = M.last and M.last.out and date.parse(M.last.out)
    opts.at, opts.continuous = out or nil, true
  elseif count >= 64 and not M.state then
    local todo_cfg = files.get_buffer(bufnr).settings.todo
    local s = require("org.ui").choose({ prompt = "Switch to state: ", items = todo_cfg:names() })
    if s and s ~= "" then
      opts.switch_to_state = s
    end
  end
  local already = M.state ~= nil
  local res = M.clock_in({ bufnr = bufnr, lnum = lnum }, opts)
  if res and not already then
    utils.notify(string.format("Clocking back: %s (in %s)", res.title, vim.fn.fnamemodify(res.path, ":t")))
  end
  return res
end

--- Jump to the running (or last) clocked task (org-clock-goto). With a
--- count, pick the task from the history.
function M.goto_clock()
  local bufnr, lnum
  local recent = false
  if vim.v.count > 0 then
    bufnr, lnum = M.select_task("Select task to go to")
    if not bufnr then
      utils.notify("No task selected")
      return nil
    end
  elseif M.state then
    local b, l = M.find_open_clock()
    if b then
      local hl = files.get_buffer(b):headline_at(l)
      bufnr, lnum = b, hl and hl.line or l
    end
  end
  if not bufnr and clock_cfg().goto_may_find_recent_task ~= false then
    bufnr, lnum = find_entry(M.history[1] or M.last)
    recent = bufnr ~= nil
  end
  if not bufnr then
    utils.notify("No active or recent clock task")
    return nil
  end
  utils.open_file(vim.api.nvim_buf_get_name(bufnr), lnum)
  -- org-clock-goto-before-context: lines shown above the entry
  local context = tonumber(clock_cfg().goto_before_context) or 2
  pcall(vim.fn.winrestview, { topline = math.max(1, lnum - context) })
  if recent then
    utils.notify("No running clock, this is the most recently clocked task")
  end
  fire("OrgClockGoto", { bufnr = bufnr, lnum = lnum })
  return true
end

-- for the parts loaded after this one
shared.find_entry = find_entry
