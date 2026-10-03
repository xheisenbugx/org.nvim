---@mod org.agenda.view.actions Agenda commands and the action table
---
--- Part of org.agenda.view, which loads it.

local config = require("org.config")
local date = require("org.date")
local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.agenda.view.shared")

local M = require("org.agenda.view")

local all_categories_in_view = shared.all_categories_in_view
local all_tags_in_view = shared.all_tags_in_view
local auto_exclude = shared.auto_exclude
local block_starts = shared.block_starts
local call = shared.call
local clocked_item = shared.clocked_item
local do_date_shift = shared.do_date_shift
local empty_filters = shared.empty_filters
local filter_string = shared.filter_string
local finish = shared.finish
local has_agenda_block = shared.has_agenda_block
local item_key = shared.item_key
local move_to_item = shared.move_to_item
local move_to_line = shared.move_to_line
local on_item = shared.on_item
local org_buffers = shared.org_buffers
local other_window = shared.other_window
local redraw_lines = shared.redraw_lines
local set_line_hl = shared.set_line_hl
local set_restrict = shared.set_restrict
local set_span = shared.set_span
local shift_anchor = shared.shift_anchor
local states = shared.states
local todo_names = shared.todo_names
local toggle = shared.toggle
local use = shared.use

---------------------------------------------------------------------------
-- Other commands
---------------------------------------------------------------------------

--- org-agenda-drag-line-forward/backward: move the line at point past the
--- next/previous entry line (the agenda text only, not the files).
function M.drag_line(dir)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local other = lnum + dir
  if not (M.state.line_items[lnum] and M.state.line_items[other]) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(M.state.buf, 0, -1, false)
  vim.bo[M.state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.state.buf, math.min(lnum, other) - 1, math.max(lnum, other), false, {
    lines[math.max(lnum, other)],
    lines[math.min(lnum, other)],
  })
  vim.bo[M.state.buf].modifiable = false
  M.state.line_items[lnum], M.state.line_items[other] = M.state.line_items[other], M.state.line_items[lnum]
  M.state.line_parts[lnum], M.state.line_parts[other] = M.state.line_parts[other], M.state.line_parts[lnum]
  if M.state.line_ctx then
    M.state.line_ctx[lnum], M.state.line_ctx[other] = M.state.line_ctx[other], M.state.line_ctx[lnum]
  end
  local lh = M.state.line_hl_groups or {}
  lh[lnum], lh[other] = lh[other], lh[lnum]
  M.state.line_hl_groups = lh
  set_line_hl(M.state.buf, lnum, lh[lnum])
  set_line_hl(M.state.buf, other, lh[other])
  redraw_lines(M.state.buf, math.min(lnum, other), math.max(lnum, other))
  M.render_marks()
  vim.api.nvim_win_set_cursor(0, { other, 0 })
end

--- Append another agenda view to the current one (org-agenda-append-agenda).
function M.append()
  if not M.state.view then
    return
  end
  local items = {
    { key = "a", label = "Agenda for current week or day", value = { type = "agenda" } },
    { key = "t", label = "List of all TODO entries", value = { type = "todo" } },
    { key = "m", label = "Match a TAGS/PROP/TODO query", value = "m" },
    { key = "M", label = "Like m, but only TODO entries", value = "M" },
    { key = "s", label = "Search for keywords", value = "s" },
    { key = "S", label = "Like s, but only TODO entries", value = "S" },
    { key = "#", label = "List stuck projects", value = { type = "stuck" } },
  }
  for key, cmd in pairs(require("org.agenda").custom_commands()) do
    if type(cmd) == "table" and (cmd.type or cmd.types or cmd.blocks) then
      items[#items + 1] = { key = key, label = cmd.description or key, value = { custom = key } }
    end
  end
  local choice = require("org.ui").menu({ title = "Append to agenda", items = items })
  if not choice then
    return
  end
  local agenda = require("org.agenda")
  local blocks = {}
  if choice == "m" or choice == "M" then
    local m = utils.input({ prompt = choice == "m" and "Match: " or "Match (TODO only): " })
    if not m or m == "" then
      return
    end
    blocks = { { type = choice == "m" and "tags" or "tags_todo", match = m } }
  elseif choice == "s" or choice == "S" then
    local t = utils.input({ prompt = "Search: " })
    if not t or t == "" then
      return
    end
    blocks = { { type = "search", match = t, todo_only = choice == "S" or nil } }
  elseif type(choice) == "table" and choice.custom then
    local cmd = require("org.agenda").custom_commands()[choice.custom]
    blocks = cmd.type and { cmd } or (cmd.blocks or cmd.types)
  elseif type(choice) == "table" then
    blocks = { choice }
  end
  for _, b in ipairs(blocks) do
    M.state.view.blocks[#M.state.view.blocks + 1] = agenda.normalize_block(b)
  end
  M.state.view.multi = true
  M.redo()
end

--- Redo every agenda buffer (org-agenda-redo-all).
function M.redo_all()
  local cur = M.state
  for _, st in pairs(states) do
    if st.buf and vim.api.nvim_buf_is_valid(st.buf) and st.view then
      use(st)
      M.refresh()
    end
  end
  use(cur)
end

M.actions = {
  quit = function()
    M.quit(false)
  end,
  quit_kill = function()
    M.quit(true)
  end,
  exit = function()
    M.exit()
  end,
  redo = function()
    local count = vim.v.count
    if count > 0 and M.state.view then
      local names = todo_names()
      for _, b in ipairs(M.state.view.blocks) do
        if b.type == "todo" then
          b.keywords = names[count] and { names[count] } or nil
        elseif (b.type == "tags" or b.type == "tags_todo") and not M.state.view.multi then
          local m = utils.input({ prompt = "Match: ", default = b.match or "" })
          if m then
            b.match = m
          end
        elseif b.type == "search" and not M.state.view.multi then
          local m = utils.input({ prompt = "Search: ", default = b.match or "" })
          if m then
            b.match = m
          end
        end
      end
    end
    M.undo_list = {}
    M.redo()
  end,
  undo = function()
    M.undo()
  end,
  redo_all = function()
    M.redo_all()
  end,
  later = function()
    shift_anchor(1)
  end,
  earlier = function()
    shift_anchor(-1)
  end,
  today = function()
    if not has_agenda_block() then
      require("org.agenda").open_agenda({})
      return
    end
    M.state.anchor = nil
    M.redo()
    for l, d in pairs(M.state.day_lines) do
      if d == date.today_days() then
        pcall(vim.api.nvim_win_set_cursor, 0, { l, 0 })
      end
    end
  end,
  goto_date = function()
    local d = M.pick_date(date.from_days(M.day_at_cursor() or date.today_days()), "Go to date")
    if not d then
      return
    end
    M.goto_date(d:days())
  end,
  calendar = function()
    local d = M.pick_date(date.from_days(M.day_at_cursor() or date.today_days()), "Calendar")
    if d then
      M.goto_date(d:days())
    end
  end,
  convert_date = function()
    M.convert_date()
  end,
  phases_of_moon = function()
    M.phases_of_moon()
  end,
  sunrise_sunset = function()
    M.sunrise_sunset(vim.v.count > 0)
  end,
  holidays = function()
    M.holidays()
  end,
  day_view = function()
    set_span("day")
  end,
  week_view = function()
    set_span("week")
  end,
  fortnight_view = function()
    set_span("fortnight")
  end,
  month_view = function()
    set_span("month")
  end,
  year_view = function()
    set_span("year")
  end,
  ["goto"] = function()
    M.show_item(true)
  end,
  switch_to = function()
    M.switch_to()
  end,
  tree_to_indirect_buffer = function()
    M.tree_to_indirect_buffer(vim.v.count > 0 and vim.v.count or nil)
  end,
  diary_entry = function()
    require("org.agenda.diary_entry").entry({ region = M._region, nonmarking = vim.v.count > 0 })
  end,
  show = function()
    M.show_and_scroll_up(vim.v.count > 0)
  end,
  show_scroll_down = function()
    M.show_scroll_down()
  end,
  goto_mouse = function()
    if M.mouse_set_point() then
      M.show_item(true)
    end
  end,
  show_mouse = function()
    if M.mouse_set_point() then
      M.show_item(false)
    end
  end,
  show_1 = function()
    M.show_1(math.max(vim.v.count, 1), true)
  end,
  cycle_show = function()
    M.cycle_show(vim.v.count > 0 and vim.v.count or nil)
  end,
  follow_mode = function()
    M.state.follow = not M.state.follow
    utils.notify("Follow mode " .. (M.state.follow and "on" or "off"))
    if M.state.follow then
      M.follow_show()
    end
  end,
  todo = on_item(function(target)
    -- org-agenda-todo runs org-todo: fast selection or cycling in the set
    return call("org.todo", "select_or_cycle", target)
  end, "lines"),
  -- org-agenda-todo-yesterday: org-agenda-todo with the effective time
  -- 23:59 of yesterday (use_effective_time, extend_today_until = hour + 1)
  todo_yesterday = on_item(function(target)
    local opts = config.opts
    local saved = { opts.use_effective_time, opts.extend_today_until }
    opts.use_effective_time = true
    opts.extend_today_until = tonumber(os.date("%H")) + 1
    local ok, res = pcall(call, "org.todo", "select_or_cycle", target)
    opts.use_effective_time, opts.extend_today_until = saved[1], saved[2]
    if not ok then
      error(res, 0)
    end
    return res
  end, "lines"),
  todo_next = on_item(function(target)
    return call("org.todo", "cycle_next", target)
  end, "lines"),
  todo_prev = on_item(function(target)
    return call("org.todo", "cycle_prev", target)
  end, "lines"),
  priority = on_item(function(target)
    call("org.priority", "set", target)
  end, "lines"),
  priority_up = on_item(function(target)
    call("org.priority", "shift", target, 1)
  end, "lines"),
  priority_down = on_item(function(target)
    call("org.priority", "shift", target, -1)
  end, "lines"),
  set_tags = on_item(function(target)
    call("org.tags", "set_tags", target)
  end, "lines"),
  schedule = on_item(function(target)
    call("org.timestamps", "schedule", target)
  end, "schedule"),
  deadline = on_item(function(target)
    call("org.timestamps", "deadline", target)
  end, "deadline"),
  date_later = do_date_shift(1),
  date_earlier = do_date_shift(-1),
  date_later_hours = on_item(function(target, item)
    M.shift_item(target, item, math.max(vim.v.count, 1), true, "h")
  end, "date"),
  date_earlier_hours = on_item(function(target, item)
    M.shift_item(target, item, -math.max(vim.v.count, 1), true, "h")
  end, "date"),
  date_later_minutes = on_item(function(target, item)
    M.shift_item(target, item, math.max(vim.v.count, 1), true, "min")
  end, "date"),
  date_earlier_minutes = on_item(function(target, item)
    M.shift_item(target, item, -math.max(vim.v.count, 1), true, "min")
  end, "date"),
  date_prompt = on_item(function(target, item)
    M.date_prompt(target, item)
  end, "date"),
  clock_in = on_item(function(target)
    call("org.clock", "clock_in", target)
  end, "lines"),
  clock_out = function()
    -- org-agenda-clock-out: the lines of the clocked entry change
    local it, bufnr, lnum = clocked_item()
    call("org.clock", "clock_out")
    finish({}, function()
      if it then
        return M.change_all_lines(it, bufnr, lnum)
      end
      return M.mark_clocking_task()
    end)
  end,
  clock_cancel = function()
    -- org-agenda-clock-cancel only unmarks the clocking task
    call("org.clock", "clock_cancel")
    finish({}, M.mark_clocking_task)
  end,
  clock_goto = function()
    call("org.clock", "goto_clock")
  end,
  set_effort = on_item(function(target)
    call("org.properties", "set_effort", target)
  end, "lines"),
  refile = on_item(function(target)
    call("org.refile", "refile", target)
  end),
  archive = on_item(function(target)
    call("org.archive", "archive_subtree", target, { from_agenda = true })
  end),
  toggle_archive_tag = on_item(function(target)
    call("org.archive", "toggle_archive_tag", target)
  end, "lines"),
  attach = function()
    local w = M.show_item(false)
    if w then
      vim.api.nvim_win_call(w, function()
        call("org.attach", "menu")
      end)
    end
  end,
  add_note = on_item(function(target)
    local ok, todo = pcall(require, "org.todo")
    if ok and todo.add_note then
      todo.add_note(target)
      return
    end
    local note = utils.input({ prompt = "Note: " })
    if note and vim.trim(note) ~= "" then
      local edit = require("org.edit")
      local ts = date.now():clone({ active = false }):to_string()
      edit.add_log_entry(target.bufnr, target.lnum, edit.log_lines("- Note taken on " .. ts, note))
    end
  end, "lines"),
  log_mode = function()
    local count = vim.v.count
    if count > 0 then
      -- C-u l: all log items; C-u C-u l: only log items (org-agenda-log-mode)
      M.state.log_mode = M.state.log_mode ~= (count == 1 and "all" or "only") and (count == 1 and "all" or "only")
        or false
    else
      M.state.log_mode = not M.state.log_mode
    end
    M.redo()
    utils.notify("Log mode " .. (M.state.log_mode and "on" or "off"))
  end,
  clockreport_mode = function()
    M.state.clockreport = not M.state.clockreport
    M.redo()
    utils.notify("Clock report mode " .. (M.state.clockreport and "on" or "off"))
  end,
  filter = function()
    local count = vim.v.count
    if count >= 3 then
      auto_exclude()
      return
    end
    local negate = count == 1
    local input = utils.input_complete(
      (negate and "Negative filter" or "Filter") .. " [+cat-tag<0:10-/regexp/]: ",
      function()
        local list = all_categories_in_view()
        vim.list_extend(list, all_tags_in_view())
        return list
      end,
      filter_string()
    )
    if input == nil then
      return
    end
    local keep = count == 2
    if input:match("^%+[%+%-]") then
      input = input:sub(2)
      keep = true
    end
    local f = M.parse_filter(input, negate)
    local cur = M.state.filters
    M.state.filters = {
      tag = keep and vim.list_extend(vim.list_slice(cur.tag), f.tag) or f.tag,
      category = keep and vim.list_extend(vim.list_slice(cur.category), f.category) or f.category,
      regexp = keep and vim.list_extend(vim.list_slice(cur.regexp), f.regexp) or f.regexp,
      effort = keep and vim.list_extend(vim.list_slice(cur.effort), f.effort) or f.effort,
      top = cur.top,
    }
    M.redo()
  end,
  filter_tag = function()
    M.filter_by_tag(vim.v.count)
  end,
  filter_category = function()
    local count = vim.v.count
    local f = M.state.filters
    -- org-agenda-filtered-by-category: the newest category filter is a
    -- "+" one; then the filter is removed, with or without a count
    local by_cat = #f.category > 0 and f.category[1]:sub(1, 1) == "+"
    if by_cat then
      f.category = {}
    else
      local item = M.item_at_cursor()
      if not item then
        utils.error("No category at point")
        return
      end
      if count > 0 then
        table.insert(f.category, 1, "-" .. item.category)
      else
        f.category = { "+" .. item.category }
      end
    end
    M.redo()
  end,
  filter_regexp = function()
    local count = vim.v.count
    local strip, accumulate = count == 1, count == 2
    if #M.state.filters.regexp > 0 and not accumulate then
      M.state.filters.regexp = {}
      M.redo()
      utils.notify("Regexp filter removed")
      return
    end
    local input = utils.input({
      prompt = strip and "Hide entries matching regexp: " or "Narrow to entries matching regexp: ",
    })
    if input == nil or input == "" then
      return
    end
    local ok = pcall(require("org.agenda.search").compile_emacs_regexp, input)
    if not ok then
      utils.error("Invalid regexp: " .. input)
      return
    end
    table.insert(M.state.filters.regexp, 1, (strip and "-" or "+") .. input)
    M.redo()
  end,
  filter_remove = function()
    M.state.filters = empty_filters()
    M.redo()
    utils.notify("All agenda filters removed")
  end,
  mark = function()
    local item = M.item_at_cursor()
    if item then
      M.state.marks[item_key(item)] = item
      M.render_marks()
    end
    move_to_item(1)
  end,
  unmark = function()
    local item = M.item_at_cursor()
    if item then
      M.state.marks[item_key(item)] = nil
      M.render_marks()
    end
    move_to_item(1)
  end,
  unmark_all = function()
    M.state.marks = {}
    M.render_marks()
  end,
  bulk_action = function()
    M.bulk_action()
  end,
  entry_text_mode = function()
    -- a count N turns it on with N lines (org-agenda-entry-text-mode N)
    local count = vim.v.count
    if count > 0 then
      M.state.entry_text = count
    else
      M.state.entry_text = not M.state.entry_text
    end
    M.redo()
    local max = type(M.state.entry_text) == "number" and M.state.entry_text
      or config.opts.agenda.entry_text_maxlines
      or 5
    utils.notify(
      "Entry text mode is "
        .. (M.state.entry_text and string.format("on (maximum number of lines is %d)", max) or "off")
    )
  end,
  archives_mode = function()
    toggle("archives", "Archived trees", "trees")
  end,
  archives_files_mode = function()
    M.state.archives = M.state.archives ~= "files" and "files" or false
    M.redo()
    utils.notify("Archived trees and archive files " .. (M.state.archives and "on" or "off"))
  end,
  inactive_mode = function()
    toggle("inactive", "Inactive timestamps")
  end,
  log_all_mode = function()
    toggle("log_mode", "Log mode (all entries)", "all")
  end,
  clockcheck_mode = function()
    M.state.log_mode = M.state.log_mode ~= "clockcheck" and "clockcheck" or false
    M.redo()
    utils.notify("Clock check " .. (M.state.log_mode and "on" or "off"))
  end,
  time_grid = function()
    M.state.time_grid_off = not M.state.time_grid_off
    M.redo()
    utils.notify("Time grid " .. (M.state.time_grid_off and "off" or "on"))
  end,
  reset_view = function()
    set_span(nil)
  end,
  toggle_deadlines = function()
    M.state.no_deadlines = not M.state.no_deadlines
    M.redo()
    utils.notify("Deadlines " .. (M.state.no_deadlines and "hidden" or "shown"))
  end,
  toggle_diary = function()
    local on = M.state.include_diary
    if on == nil then
      on = config.opts.agenda.include_diary
    end
    M.state.include_diary = not on
    M.redo()
    utils.notify("Diary inclusion turned " .. (M.state.include_diary and "on" or "off"))
  end,
  toggle_habits = function()
    M.toggle_habits()
  end,
  toggle_habits_display = function()
    M.toggle_habits_display(vim.v.count > 0)
  end,
  dim_blocked = function()
    M.state.dim_blocked = not M.state.dim_blocked
    M.redo()
    utils.notify("Dimming blocked tasks " .. (M.state.dim_blocked and "on" or "off"))
  end,
  filter_effort = function()
    M.filter_by_effort(vim.v.count)
  end,
  filter_top_headline = function()
    if M.state.filters.top then
      M.state.filters.top = nil
    else
      local item = M.item_at_cursor()
      if not item or not item.headline then
        utils.warn("No entry at point to take the top headline from")
        return
      end
      local h = item.headline
      while h.parent do
        h = h.parent
      end
      M.state.filters.top = { key = M.top_key(item), title = h:plain_title() }
    end
    M.redo()
  end,
  limit = function()
    M.limit(vim.v.count)
  end,
  query_add = function()
    M.manipulate_query("+", false)
  end,
  query_subtract = function()
    M.manipulate_query("-", false)
  end,
  query_add_re = function()
    M.manipulate_query("+", true)
  end,
  query_subtract_re = function()
    M.manipulate_query("-", true)
  end,
  mark_all = function()
    for _, item in pairs(M.state.line_items) do
      M.state.marks[item_key(item)] = item
    end
    M.render_marks()
    utils.notify(string.format("%d entries marked", vim.tbl_count(M.state.marks)))
  end,
  toggle_mark = function()
    local item = M.item_at_cursor()
    if item then
      local k = item_key(item)
      M.state.marks[k] = not M.state.marks[k] and item or nil
      M.render_marks()
    end
    move_to_item(1)
  end,
  toggle_mark_all = function()
    for _, item in pairs(M.state.line_items) do
      local k = item_key(item)
      M.state.marks[k] = not M.state.marks[k] and item or nil
    end
    M.render_marks()
  end,
  mark_regexp = function()
    local input = utils.input({ prompt = "Mark entries matching regexp: " })
    if not input or input == "" then
      return
    end
    M.mark_regexp(input)
  end,
  kill = on_item(function(target)
    local file = files.get_buffer(target.bufnr)
    local hl = file:headline_at(target.lnum)
    if not hl then
      return
    end
    local n = hl.end_line - hl.line + 1
    local limit = config.opts.agenda.confirm_kill
    if limit == nil then
      limit = 1
    end
    if limit and n > limit then
      local name = vim.fn.fnamemodify(file.filename or "", ":t")
      if not utils.confirm(string.format('Delete entry with %d lines in "%s"?', n, name)) then
        return
      end
    end
    vim.api.nvim_buf_set_lines(target.bufnr, hl.line - 1, hl.end_line, false, {})
    utils.notify("Agenda item and source killed")
  end),
  open_link = function()
    local item = M.item_at_cursor()
    if not item then
      utils.warn("No agenda entry on this line")
      return
    end
    local target = M.resolve_target(item)
    if not target then
      return
    end
    local list = M.entry_links(target)
    if #list == 0 then
      utils.warn("No link to open here")
      return
    end
    local link = list[1]
    if #list > 1 then
      link = utils.select(list, {
        prompt = "Open link",
        format_item = function(l)
          return l.desc and (l.desc .. " (" .. l.target .. ")") or l.target
        end,
      })
      if not link then
        return
      end
    end
    require("org.links").open(link.target, { bufnr = target.bufnr })
  end,
  set_property = on_item(function(target)
    call("org.properties", "set_property", target)
  end, "lines"),
  show_tags = function()
    local item = M.item_at_cursor()
    if not item then
      return
    end
    local tags = item.tags or {}
    utils.notify(#tags > 0 and ("Tags are :" .. table.concat(tags, ":") .. ":") or "No tags associated with this line")
  end,
  recenter = function()
    M.show_item(false)
    pcall(vim.api.nvim_win_call, other_window(), function()
      vim.cmd("normal! zz")
    end)
  end,
  delete_other_windows = function()
    pcall(vim.cmd, "silent! only")
  end,
  save_all = function()
    local n = 0
    for _, b in ipairs(org_buffers()) do
      if vim.bo[b].modified and utils.save_buffer_or_warn(b) then
        n = n + 1
      end
    end
    utils.notify(string.format("Saved %d org buffer(s)", n))
  end,
  next_date_line = function()
    move_to_line(1, function(l)
      return M.state.day_lines[l] ~= nil
    end)
  end,
  prev_date_line = function()
    move_to_line(-1, function(l)
      return M.state.day_lines[l] ~= nil
    end)
  end,
  forward_block = function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    for _, l in ipairs(block_starts()) do
      if l > lnum and l <= vim.api.nvim_buf_line_count(M.state.buf) then
        vim.api.nvim_win_set_cursor(0, { l, 0 })
        return
      end
    end
  end,
  backward_block = function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local starts = block_starts()
    for i = #starts, 1, -1 do
      if starts[i] < lnum then
        vim.api.nvim_win_set_cursor(0, { starts[i], 0 })
        return
      end
    end
  end,
  drag_line_forward = function()
    M.drag_line(1)
  end,
  drag_line_backward = function()
    M.drag_line(-1)
  end,
  append = function()
    M.append()
  end,
  -- org-agenda-archive-default: org-archive-default-command
  archive_default = on_item(function(target)
    M.archive_with_default(target)
  end),
  -- org-agenda-archive-default-with-confirmation
  archive_default_confirm = on_item(function(target)
    if not utils.confirm("Archive this subtree or entry? ") then
      utils.error("Abort")
      return
    end
    call("org.archive", "archive_subtree_default", target, { from_agenda = true })
  end),
  archive_sibling = on_item(function(target)
    call("org.archive", "archive_to_sibling", target)
  end),
  timer = function()
    call("org.timer", "countdown")
  end,
  timer_stop = function()
    call("org.timer", "stop")
  end,
  restriction_lock = function()
    local item = M.item_at_cursor()
    local target = item and M.resolve_target(item)
    if not target then
      return
    end
    local agenda = require("org.agenda")
    agenda.set_restriction_lock(target)
    set_restrict(agenda.lock_restriction())
    M.redo()
  end,
  remove_restriction_lock = function()
    require("org.agenda").remove_restriction_lock()
    set_restrict(nil)
    M.redo()
  end,
  next_item = function()
    move_to_item(1)
  end,
  prev_item = function()
    move_to_item(-1)
  end,
  capture = function()
    call("org.capture", "prompt", { date = M.cursor_date(vim.v.count == 1) })
  end,
  columns = function()
    call("org.agenda.columns", "toggle")
  end,
  export = function()
    M.export()
  end,
  help = function()
    require("org.mappings").show_help()
  end,
  -- MobileOrg (org-agenda-show-the-flagging-note, org-mobile-pull/push)
  show_flagging_note = function()
    call("org.mobile", "show_flagging_note")
  end,
  mobile_pull = function()
    if call("org.mobile", "pull") then
      M.redo()
    end
  end,
  mobile_push = function()
    call("org.mobile", "push")
    M.redo()
  end,
}
