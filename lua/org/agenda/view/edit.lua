---@mod org.agenda.view.edit Editing entries from the agenda: line updates, remote undo, dates
---
--- Part of org.agenda.view, which loads it.

local config = require("org.config")
local date = require("org.date")
local files = require("org.files")
local render = require("org.agenda.render")
local utils = require("org.utils")
local shared = require("org.agenda.view.shared")

local M = require("org.agenda.view")

local clocking_pred = shared.clocking_pred
local item_key = shared.item_key
local ns_line = shared.ns_line
local ns_newtime = shared.ns_newtime
local redraw_lines = shared.redraw_lines
local set_line_hl = shared.set_line_hl

---------------------------------------------------------------------------
-- Editing entries from the agenda
---------------------------------------------------------------------------

local function call(mod, fn, ...)
  local ok, m = pcall(require, mod)
  if not ok or type(m[fn]) ~= "function" then
    utils.error(string.format("org agenda: %s.%s is not available", mod, fn))
    return nil
  end
  return m[fn](...)
end
M.call = call

---------------------------------------------------------------------------
-- Updating the lines of one entry (org-agenda-change-all-lines)
---------------------------------------------------------------------------

local clocked_item

--- Is `it` a line of the entry `old` comes from (Emacs compares the
--- org-hd-marker of the lines)?
local function same_entry(it, old)
  if it == old or (old.headline and it.headline == old.headline) then
    return true
  end
  return it.headline ~= nil
    and it.lnum == old.lnum
    and it.raw == old.raw
    and it.filename == old.filename
    and (old.filename ~= nil or it.bufnr == old.bufnr)
end

--- The lines showing the entry of `old` (and passing `pred`), last first.
local function entry_lines(old, pred)
  local out = {}
  for l, it in pairs(M.state.line_items) do
    if same_entry(it, old) and (not pred or pred(it)) then
      out[#out + 1] = l
    end
  end
  table.sort(out, function(a, b)
    return a > b
  end)
  return out
end

--- Drop line `l` of the agenda buffer and of the line maps.
local function delete_line(l)
  local buf = M.state.buf
  vim.api.nvim_buf_clear_namespace(buf, ns_line, l - 1, l)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, l - 1, l, false, {})
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  for _, map in ipairs({
    M.state.line_items,
    M.state.line_parts,
    M.state.line_hl_groups,
    M.state.line_ctx,
    M.state.day_lines,
    M.state.entry_text_lines,
  }) do
    local moved = {}
    for k, v in pairs(map) do
      if k > l then
        moved[k] = v
      end
    end
    map[l] = nil
    for k in pairs(moved) do
      map[k] = nil
    end
    for k, v in pairs(moved) do
      map[k - 1] = v
    end
  end
  for i, s in ipairs(M.state.block_starts or {}) do
    if s > l then
      M.state.block_starts[i] = s - 1
    end
  end
  local cur = M.state.win and vim.api.nvim_win_is_valid(M.state.win) and vim.api.nvim_win_get_cursor(M.state.win)
  if cur and cur[1] > l then
    pcall(vim.api.nvim_win_set_cursor, M.state.win, { cur[1] - 1, cur[2] })
  end
end

--- Draw the highlights of line `l` from `S.line_parts` / `S.line_hl_groups`.
local function draw_line(l)
  set_line_hl(M.state.buf, l, M.state.line_hl_groups[l])
  redraw_lines(M.state.buf, l, l)
end

--- Replace line `l` with `text` and its highlights.
local function set_line(l, text, hls, line_hl)
  local buf = M.state.buf
  if vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] ~= text then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, l - 1, l, false, { text })
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
  end
  vim.api.nvim_buf_clear_namespace(buf, ns_newtime, l - 1, l)
  M.state.line_parts[l] = hls
  M.state.line_hl_groups[l] = line_hl
  draw_line(l)
end

--- A copy of the agenda item `old` with what it takes from its entry read
--- again from `hl` (org-agenda-change-all-lines formats NEWHEAD with the
--- line's own extra, level, category, time and format).
local function updated_item(old, hl)
  local it = {}
  for k, v in pairs(old) do
    it[k] = v
  end
  it.headline = hl
  it.filename = hl.file.filename
  it.bufnr = hl.file.bufnr
  it.lnum = hl.line
  it.raw = hl.raw
  it.todo = hl.todo
  it.priority = hl.priority
  it.category = hl:get_category()
  it.tags = hl:get_tags()
  it.done = hl:is_done()
  it.level = hl.level
  local prio = require("org.agenda.items").priority_value(hl)
  it.urgency = (old.urgency or old.prio or 0) - (old.prio or 0) + prio
  it.prio = prio
  if old.fixface then
    -- the undone or done face for the new state (FIXFACE)
    it.face = it.done and "OrgAgendaDone" or old.undone_face
  end
  if old.habit then
    it.habit = require("org.agenda.habits").parse(hl) or old.habit
  end
  return it
end

--- Keep the bulk mark of a line whose item changed.
local function move_mark(old, new)
  local k = item_key(old)
  if M.state.marks[k] then
    M.state.marks[k] = nil
    M.state.marks[item_key(new)] = true
  end
end

--- After a change of the entry of the agenda item `old` (now at line `lnum`
--- of `bufnr`), format every agenda line showing that entry again, like
--- org-agenda-change-all-lines: the lines stay where they are, a line
--- whose item the filters now hide is removed, the clocking highlight is
--- updated. `opts.snapshot` (a repeating entry marked done) shows only the
--- line at point, as `opts.snapshot` (org-agenda-headline-snapshot-before-repeat).
--- Returns false when the lines can't be updated in place (the view is
--- then rebuilt).
---@param old table agenda item
---@param bufnr integer
---@param lnum integer
---@param opts? { snapshot?: string, just_line?: integer }
---@return boolean
function M.change_all_lines(old, bufnr, lnum, opts)
  opts = opts or {}
  if not (M.state.buf and vim.api.nvim_buf_is_valid(M.state.buf)) or not M.state.line_ctx or M.state.entry_text then
    return false
  end
  if not (old.headline and vim.api.nvim_buf_is_valid(bufnr)) then
    return false
  end
  local hl = files.get_buffer(bufnr):headline_at(lnum)
  if not (hl and hl.line == lnum and hl.title == old.headline.title) then
    return false
  end
  local lines = entry_lines(old)
  for _, l in ipairs(lines) do
    if not M.state.line_ctx[l] then
      return false
    end
  end
  local clocking = clocking_pred()
  local changed = {} -- the lines kept, first first
  for _, l in ipairs(lines) do
    if not opts.just_line or opts.just_line == l then
      local prev = M.state.line_items[l]
      local it = updated_item(prev, hl)
      if opts.snapshot then
        it.todo, it.done = opts.snapshot, true
        if prev.fixface then
          it.face = "OrgAgendaDone"
        end
      end
      local ctx = setmetatable({ is_clocking = clocking }, { __index = M.state.line_ctx[l] })
      local text, hls, line_hl
      render.with_block_options(ctx.block or {}, function()
        if not ctx.filter or ctx.filter(it) then
          text, hls, line_hl = render.item_line(it, ctx)
        end
      end)
      move_mark(prev, it)
      if text then
        M.state.line_items[l] = it
        set_line(l, text, hls, line_hl)
        table.insert(changed, 1, l)
      else
        delete_line(l)
        for i, c in ipairs(changed) do
          changed[i] = c > l and c - 1 or c
        end
      end
    end
  end
  M.mark_clocking_task(clocking)
  if next(M.state.marks) then
    M.render_marks()
  end
  local ok, cols = pcall(require, "org.agenda.columns")
  if ok then
    pcall(cols.refresh_if_active)
  end
  -- org-agenda-finalize, narrowed to each line, runs the finalize hook
  local data = { buf = M.state.buf, filters = vim.deepcopy(M.state.filters), filter = M.filter_desc(), lines = changed }
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "OrgAgendaFinalize", data = data, modeline = false })
  return true
end

--- Drop the clocking highlight of the lines whose entry is no longer
--- clocked (org-agenda-unmark-clocking-task); the lines of a newly clocked
--- entry get theirs from `change_all_lines`.
---@param clocking? fun(it: table): boolean the clocking predicate
---@return boolean
function M.mark_clocking_task(clocking)
  if not (M.state.buf and vim.api.nvim_buf_is_valid(M.state.buf)) then
    return false
  end
  clocking = clocking or clocking_pred()
  for l, group in pairs(M.state.line_hl_groups or {}) do
    if group == "OrgAgendaClocking" and not (clocking and clocking(M.state.line_items[l] or {})) then
      M.state.line_hl_groups[l] = nil
      draw_line(l)
    end
  end
  return true
end

--- The agenda item of the running clock's entry, with its buffer and
--- headline line.
---@return table|nil item, integer|nil bufnr, integer|nil lnum
clocked_item = function()
  local ok, clock = pcall(require, "org.clock")
  if not (ok and clock.state and type(clock.find_open_clock) == "function") then
    return nil
  end
  local ok2, bufnr, clnum = pcall(clock.find_open_clock)
  if not (ok2 and bufnr) then
    return nil
  end
  local hl = files.get_buffer(bufnr):headline_at(clnum)
  if not hl then
    return nil
  end
  local name = vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))
  for _, it in pairs(M.state.line_items) do
    if
      it.headline
      and it.lnum == hl.line
      and it.raw == hl.raw
      and (it.filename and vim.fs.normalize(it.filename) == name or it.bufnr == bufnr)
    then
      return it, bufnr, hl.line
    end
  end
  return nil
end

--- Show the new date of the lines of the item `old` that come from the
--- same timestamp at the right edge of the window, without moving them
--- (org-agenda-show-new-time): " => <stamp>", after `prefix` (" S" for
--- schedule, " D" for deadline).
---@param old table agenda item
---@param stamp string|nil
---@param prefix? string
function M.show_new_time(old, stamp, prefix)
  if not (M.state.buf and vim.api.nvim_buf_is_valid(M.state.buf)) then
    return
  end
  local text = (prefix or "") .. " => " .. (stamp or "") .. " "
  local kind = old.type
  local lines = entry_lines(old, function(it)
    return it.type == kind and it.ts_index == old.ts_index
  end)
  local width = M.state.win and vim.api.nvim_win_is_valid(M.state.win) and vim.api.nvim_win_get_width(M.state.win)
    or vim.o.columns
  for _, l in ipairs(lines) do
    vim.api.nvim_buf_clear_namespace(M.state.buf, ns_newtime, l - 1, l)
    pcall(vim.api.nvim_buf_set_extmark, M.state.buf, ns_newtime, l - 1, 0, {
      virt_text = { { text, "OrgAgendaNewTime" } },
      virt_text_pos = "overlay",
      virt_text_win_col = math.max(1, width - vim.fn.strdisplaywidth(text)),
      priority = 300,
    })
  end
end

--- The text a line shows over its end after a date change (" => <stamp>"),
--- or nil.
---@param lnum integer
---@return string|nil
function M.new_time_at(lnum)
  if not (M.state.buf and vim.api.nvim_buf_is_valid(M.state.buf)) then
    return nil
  end
  local marks = vim.api.nvim_buf_get_extmarks(
    M.state.buf,
    ns_newtime,
    { lnum - 1, 0 },
    { lnum - 1, -1 },
    { details = true }
  )
  local m = marks[1]
  return m and m[4].virt_text and m[4].virt_text[1][1] or nil
end

--- After an edit: save when `save_after_edit` is set (Emacs leaves the
--- buffers modified) and update the agenda: `update()` changes the lines
--- of the entry in place and returns true, otherwise the view is rebuilt.
---@param bufs? integer[]
---@param update? fun(): boolean
local function finish(bufs, update)
  if config.opts.agenda.save_after_edit then
    for _, b in ipairs(bufs or {}) do
      utils.save_buffer_or_warn(b)
    end
  end
  if M.state.buf and vim.api.nvim_buf_is_valid(M.state.buf) then
    local win = M.state.win
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_set_current_win, win)
    end
    if not (update and update()) then
      M.redo()
    end
  end
end

---------------------------------------------------------------------------
-- Remote undo (org-agenda-undo, org-with-remote-undo)
---------------------------------------------------------------------------

--- Source edits made from the agenda, newest first:
--- `{ cmd, line, bufnr, before, after }` with the undo sequence numbers of
--- the buffer before and after the command. Cleared when the agenda is
--- built or rebuilt with `r` (like org-agenda-undo-list).
M.undo_list = {}

--- Close the current undo block of `bufnr` (API edits otherwise join the
--- block of the previous command) and return its undo sequence number.
local function undo_seq(bufnr)
  return vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("let &l:undolevels = &l:undolevels")
    return vim.fn.undotree().seq_cur
  end)
end

--- Run `fn` and remember the change it made to `bufnr` for `M.undo`.
local function with_remote_undo(bufnr, fn)
  local ok, before = pcall(undo_seq, bufnr)
  local line = M.state.win and vim.api.nvim_win_is_valid(M.state.win) and vim.api.nvim_win_get_cursor(M.state.win)[1]
    or 1
  fn()
  if ok and vim.api.nvim_buf_is_valid(bufnr) then
    local after = undo_seq(bufnr)
    if after ~= before then
      table.insert(M.undo_list, 1, {
        cmd = M.this_command or "edit",
        line = line,
        bufnr = bufnr,
        before = before,
        after = after,
      })
    end
  end
end
M.with_remote_undo = with_remote_undo

--- Undo the last source edit made from the agenda (org-agenda-undo): the
--- change in the entry's buffer is undone and the agenda rebuilt. Pressed
--- again, it undoes the edit before that one.
function M.undo()
  local e = table.remove(M.undo_list, 1)
  if not e then
    utils.error("No further undo information")
    return false
  end
  if not vim.api.nvim_buf_is_valid(e.bufnr) then
    utils.error("The buffer of this change is gone")
    return false
  end
  local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(e.bufnr), ":t")
  if undo_seq(e.bufnr) ~= e.after then
    table.insert(M.undo_list, 1, e)
    utils.error(string.format("%s was changed after `%s'; undo it there", name, e.cmd))
    return false
  end
  vim.api.nvim_buf_call(e.bufnr, function()
    vim.cmd("silent undo " .. e.before)
  end)
  if M.state.buf and vim.api.nvim_buf_is_valid(M.state.buf) then
    M.refresh()
    if M.state.win and vim.api.nvim_win_is_valid(M.state.win) then
      pcall(vim.api.nvim_win_set_cursor, M.state.win, { math.min(e.line, vim.api.nvim_buf_line_count(M.state.buf)), 0 })
    end
  end
  utils.notify(string.format("`%s' undone (buffer %s)", e.cmd, name))
  return true
end

local kind_of

--- How the agenda follows an edit of `update` kind made on the entry of
--- `item` (now at `target`): "lines" formats the lines of the entry again
--- (org-agenda-change-all-lines); "schedule", "deadline" and "date" show
--- the new date on the lines of the item (org-agenda-show-new-time);
--- anything else rebuilds the view. `res` is what the edit returned.
local function updater(update, target, item, res, changed)
  if update == "lines" then
    return function()
      local opts
      local cur = M.state.win and vim.api.nvim_win_is_valid(M.state.win) and vim.api.nvim_win_get_cursor(M.state.win)[1]
      if type(res) == "table" and res.repeated and res.done_keyword and item.day == date.today_days() then
        -- a repeating entry done today: the line at point shows it done
        -- until the next rebuild (org-agenda-headline-snapshot-before-repeat)
        opts = { snapshot = res.done_keyword, just_line = cur }
      end
      return M.change_all_lines(item, target.bufnr, target.lnum, opts)
    end
  elseif update == "schedule" or update == "deadline" or update == "date" then
    return function()
      if not changed then
        return true
      end
      if not (M.state.buf and vim.api.nvim_buf_is_valid(M.state.buf)) then
        return false
      end
      local hl = files.get_buffer(target.bufnr):headline_at(target.lnum)
      if not hl then
        return false
      end
      local kind = update == "date" and kind_of(item) or (update == "schedule" and "scheduled" or "deadline")
      local d
      if kind == "timestamp" then
        local t = hl.timestamps[item.ts_index or 1]
        d = t and t.date
      else
        d = hl.planning[kind]
      end
      local prefix = (update == "schedule" and " S") or (update == "deadline" and " D") or nil
      M.show_new_time(item, d and d:to_string() or nil, prefix)
      return true
    end
  end
  return nil
end

--- Wrap `fn(target, item)` as an action on the entry at point; `update`
--- says how the agenda follows the edit (see `updater`), by default it is
--- rebuilt.
---@param update? "lines"|"schedule"|"deadline"|"date"
local function on_item(fn, update)
  return function()
    local item = M.item_at_cursor()
    if not item then
      utils.warn("No agenda entry on this line")
      return
    end
    if item.type == "diary" then
      -- org-agenda-check-no-diary
      utils.error("Command not allowed in this line")
      return
    elseif item.not_org then
      -- an item of an extension's block that is no org entry (a code TODO)
      utils.warn(item.not_org)
      return
    elseif not item.headline then
      -- a %%(sexp) line before the first heading (Emacs: org-back-to-heading)
      utils.error("Before first headline at line " .. item.lnum)
      return
    end
    local target = M.resolve_target(item)
    if not target then
      return
    end
    local res
    local tick = vim.api.nvim_buf_get_changedtick(target.bufnr)
    with_remote_undo(target.bufnr, function()
      res = fn(target, item)
    end)
    local changed = vim.api.nvim_buf_is_valid(target.bufnr) and vim.api.nvim_buf_get_changedtick(target.bufnr) ~= tick
    finish({ target.bufnr }, updater(update, target, item, res, changed))
  end
end
M.on_item = on_item

function kind_of(item)
  if item.type == "deadline" then
    return "deadline"
  elseif item.type == "timestamp" or item.type == "range" then
    return "timestamp"
  end
  return "scheduled"
end

local function pick_date(default, prompt)
  local ok, cal = pcall(require, "org.calendar")
  if ok and cal.pick then
    return cal.pick({ default = default, prompt = prompt })
  end
  local input = utils.input({ prompt = (prompt or "Date") .. ": " })
  if not input then
    return nil
  end
  return date.read_date(input, default)
end
M.pick_date = pick_date

--- The date in the source of an item: its SCHEDULED/DEADLINE, or the
--- plain timestamp it comes from.
local function source_date(target, item)
  -- only SCHEDULED, DEADLINE and active plain timestamps of date views
  local t = item.type
  if
    item.sexp
    or item.inactive
    or item.log
    or not item.day
    or not (t == "scheduled" or t == "deadline" or t == "timestamp" or t == "range")
  then
    return nil, nil
  end
  local file = files.get_buffer(target.bufnr)
  local hl = file:headline_at(target.lnum)
  if not hl then
    return nil, nil
  end
  local kind = kind_of(item)
  if kind == "timestamp" then
    local t = hl.timestamps[item.ts_index or 1]
    return t and t.date, kind
  end
  return hl.planning[kind], kind
end

--- Shift the date of the item at point by `n` days (org-agenda-date-later):
--- the timestamp the item comes from. With
--- `agenda.move_date_from_past_immediately_to_today`, a single step on a
--- past date moves it to today. `unit` "h" shifts by hours and "min" by
--- steps of `time_stamp_rounding_minutes[2]` minutes
--- (org-agenda-date-later-hours / -minutes); a timestamp without a time
--- keeps none (Emacs shifts its midnight).
---@param unit? "d"|"h"|"min"
function M.shift_item(target, item, n, explicit_count, unit)
  unit = unit or "d"
  if item.sexp or item.inactive or item.log or not item.day then
    utils.warn("Cannot change this date from the agenda line")
    return
  end
  local d, kind = source_date(target, item)
  if not d then
    utils.warn("No timestamp to shift")
    return
  end
  if
    unit == "d"
    and not explicit_count
    and n == 1
    and not d.range_end
    and config.opts.agenda.move_date_from_past_immediately_to_today ~= false
  then
    local today = date.today_days()
    if d:days() < today then
      n = today - d:days()
    end
  end
  local t = vim.tbl_extend("force", target, { ts_index = item.ts_index })
  if unit == "d" then
    call("org.timestamps", "shift", t, kind, n, "d")
    return
  end
  if unit == "min" then
    n = n * math.max((config.opts.time_stamp_rounding_minutes or { 0, 5 })[2] or 5, 1)
  else
    n = n * 60
  end
  local function shift(x)
    local new = x:add(n, "min")
    if not x.hour then
      new = new:clone({ hour = vim.NIL, min = vim.NIL, end_hour = vim.NIL, end_min = vim.NIL })
    end
    return new
  end
  local new = shift(d)
  if d.range_end then
    new.range_end = shift(d.range_end)
  end
  call("org.timestamps", "set_date", t, kind, new)
end

--- Change the date of the item at point (org-agenda-date-prompt): the time
--- of the timestamp is kept unless a new one is given.
function M.date_prompt(target, item)
  local d, kind = source_date(target, item)
  if not kind then
    utils.warn("Cannot change this date from the agenda line")
    return
  end
  if kind ~= "timestamp" then
    if kind == "deadline" then
      call("org.timestamps", "deadline", target)
    else
      call("org.timestamps", "schedule", target)
    end
    return
  end
  if not d then
    utils.warn("No timestamp to change")
    return
  end
  local picked = M.pick_date(d, "Change date")
  if not picked or picked.remove then
    return
  end
  local new = d:clone({ year = picked.year, month = picked.month, day = picked.day })
  if picked.hour then
    new.hour, new.min, new.end_hour, new.end_min = picked.hour, picked.min, picked.end_hour, picked.end_min
  end
  if d.range_end then
    new.range_end = d.range_end:add(new:days() - d:days(), "d")
  end
  call("org.timestamps", "set_date", vim.tbl_extend("force", target, { ts_index = item.ts_index }), "timestamp", new)
end

--- Archive the entry with `archive_default_command` (org-agenda-archive-with
--- org-archive-default-command).
function M.archive_with_default(target)
  return call("org.archive", "archive_subtree_default", target, { from_agenda = true })
end

local HOUR_SHIFTS = { date_later_hours = true, date_earlier_hours = true }
local MINUTE_SHIFTS = { date_later_minutes = true, date_earlier_minutes = true }

--- S-Right / S-Left (org-agenda-do-date-later / -earlier): a count shifts
--- by that many days, except 4 (C-u), one hour, and 16 (C-u C-u), one
--- rounding step of minutes. Right after an hour or minute shift (no
--- cursor motion since), the keys keep shifting in that unit.
local function do_date_shift(sign)
  return on_item(function(target, item)
    local count = vim.v.count
    local dir = sign > 0 and "later" or "earlier"
    if count == 16 or MINUTE_SHIFTS[M.last_command] then
      M.this_command = "date_" .. dir .. "_minutes"
      M.shift_item(target, item, sign, true, "min")
    elseif count == 4 or HOUR_SHIFTS[M.last_command] then
      M.this_command = "date_" .. dir .. "_hours"
      M.shift_item(target, item, sign, true, "h")
    else
      M.shift_item(target, item, sign * math.max(count, 1), sign < 0 or count > 0)
    end
  end, "date")
end

shared.call = call
shared.clocked_item = clocked_item
shared.do_date_shift = do_date_shift
shared.finish = finish
shared.on_item = on_item
shared.with_remote_undo = with_remote_undo
