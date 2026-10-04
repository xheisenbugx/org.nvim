---@mod org.mappings Keymaps

local actions = require("org.actions")
local config = require("org.config")
local utils = require("org.utils")

local M = {}

--- Feed the key's default behaviour (or a global mapping for it) when an
--- action returned `false`.
local function fallback(lhs, mode)
  -- global (non-buffer) mapping for the same key?
  for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
    if map.lhs == lhs or vim.keycode(map.lhs) == vim.keycode(lhs) then
      if map.callback then
        local ok, res = pcall(map.callback)
        if ok and map.expr == 1 and type(res) == "string" then
          vim.api.nvim_feedkeys(vim.keycode(res), map.noremap == 1 and "n" or "m", false)
        end
        return
      elseif map.rhs and map.rhs ~= "" then
        local rhs = map.rhs
        if map.expr == 1 then
          rhs = vim.api.nvim_eval(rhs)
        end
        vim.api.nvim_feedkeys(vim.keycode(rhs), map.noremap == 1 and "n" or "m", false)
        return
      end
    end
  end
  local keys = vim.keycode(lhs)
  if vim.v.count > 0 and mode == "n" then
    keys = vim.v.count .. keys
  end
  vim.api.nvim_feedkeys(keys, "n", false)
end

-- Dot-repeat (|org-dot-repeat|). After a repeatable action ran from a
-- Normal-mode key, `:normal! {count}g@l` makes "g@l" the change "." redoes,
-- with `operatorfunc` set to run the action again; that first call does
-- nothing (the action already ran). "." then calls it with the original
-- count, or with the count typed before ".".
local repeat_action, skip_next
-- Where the cursor was when "." was typed: an operator on a closed fold
-- covers the whole fold and moves the cursor to its first line before
-- `operatorfunc` runs, so the action would run on another line.
local dot_from
local on_key_ns

--- The `operatorfunc` "." calls.
function M._dot_repeat()
  if skip_next then
    skip_next = false
    return
  end
  local from = dot_from
  dot_from = nil
  if from and from.win == vim.api.nvim_get_current_win() then
    pcall(vim.api.nvim_win_set_cursor, from.win, from.cursor)
  end
  local r = repeat_action
  if r and not actions.run(r.name) then
    fallback(r.lhs, "n")
  end
end

local function set_repeat(name, lhs, count)
  repeat_action = { name = name, lhs = lhs }
  dot_from = nil
  if not on_key_ns then
    on_key_ns = vim.api.nvim_create_namespace("org.dot_repeat")
    vim.on_key(function(key)
      if key == "." and repeat_action and vim.api.nvim_get_mode().mode == "n" then
        local win = vim.api.nvim_get_current_win()
        dot_from = { win = win, cursor = vim.api.nvim_win_get_cursor(win) }
      end
    end, on_key_ns)
  end
  vim.go.operatorfunc = "v:lua.require'org.mappings'._dot_repeat"
  -- (g@l on a closed fold moves the cursor to the fold's first line)
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  skip_next = true
  pcall(vim.cmd, "normal! " .. (count > 0 and count or "") .. "g@l")
  skip_next = false
  pcall(vim.api.nvim_win_set_cursor, win, cursor)
end

--- Run the action of a key: its default behaviour when the action doesn't
--- apply, and a "." that repeats it when it is a repeatable edit.
---@param name string
---@param lhs string
---@param mode string
function M._run_key(name, lhs, mode)
  local count = vim.v.count
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local handled, completed = actions.run(name)
  if not handled then
    fallback(lhs, mode)
    return
  end
  local a = actions.list[name]
  if
    mode == "n"
    and completed
    and a
    and a.repeatable
    and vim.api.nvim_get_mode().mode == "n"
    and vim.api.nvim_get_current_win() == win
    and vim.api.nvim_get_current_buf() == buf
  then
    set_repeat(name, lhs, count)
  end
end

local function wrap(name, lhs, mode)
  return function()
    M._run_key(name, lhs, mode)
  end
end

--- The global keymaps set by `setup_global`: { mode, lhs, desc }.
local global_maps = {}

--- Set a keymap and remember it in `record` (a list of { mode, lhs, desc })
--- so that a later `setup()` can remove it.
local function set(mode, lhs, rhs, opts, record)
  vim.keymap.set(mode, lhs, rhs, opts)
  for _, m in ipairs(type(mode) == "table" and mode or { mode }) do
    record[#record + 1] = { m, lhs, opts.desc }
  end
end

--- Delete the keymaps of `record` that are still ours (same desc), so a
--- mapping the user has since put on the same key is left alone.
local function unset(record, bufnr)
  -- mode -> { [keycode(lhs) .. NUL .. desc] = true }, read once per mode
  local current = {}
  local function ours(mode, key, desc)
    if not current[mode] then
      local set_ = {}
      local maps = bufnr and vim.api.nvim_buf_get_keymap(bufnr, mode) or vim.api.nvim_get_keymap(mode)
      for _, m in ipairs(maps) do
        if m.desc then
          set_[vim.keycode(m.lhs) .. "\0" .. m.desc] = true
        end
      end
      current[mode] = set_
    end
    return current[mode][key .. "\0" .. desc]
  end
  for _, r in ipairs(record or {}) do
    local mode, lhs, desc = r[1], r[2], r[3]
    if desc and ours(mode, vim.keycode(lhs), desc) then
      pcall(vim.keymap.del, mode, lhs, bufnr and { buffer = bufnr } or nil)
    end
  end
end

--- Global keymaps (agenda, capture, ...). Calling it again (`setup()`
--- twice) first removes the keymaps of the previous call.
function M.setup_global()
  unset(global_maps)
  global_maps = {}
  local maps = config.opts.mappings
  if maps.disable_all then
    return
  end
  for _, section in ipairs({ maps.global or {}, maps.emacs_global or {} }) do
    for name, value in pairs(section) do
      local a = actions.list[name]
      if a then
        for _, lhs in ipairs(config.lhs_list(value)) do
          for _, mode in ipairs(a.modes or { "n" }) do
            if mode ~= "i" then
              set(mode, lhs, wrap(name, lhs, mode), { desc = "org: " .. a.desc }, global_maps)
            end
          end
        end
      end
    end
  end
  M.register_which_key()
end

--- Buffer-local keymaps for an org buffer. Calling it again (`setup()`
--- re-attaching open buffers) first removes the keymaps it set before.
function M.attach(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  unset(vim.b[bufnr].org_keymaps, bufnr)
  local record = {}
  local maps = config.opts.mappings
  if maps.disable_all then
    vim.b[bufnr].org_keymaps = record
    return
  end
  for name, value in pairs(maps.org or {}) do
    local a = actions.list[name]
    if a then
      for _, lhs in ipairs(config.lhs_list(value)) do
        for _, mode in ipairs(a.modes or { "n" }) do
          if mode ~= "i" or name == "meta_return" or name == "meta_shift_return" then
            set(mode, lhs, wrap(name, lhs, mode), { buffer = bufnr, desc = "org: " .. a.desc }, record)
          end
        end
      end
    end
  end
  -- Emacs keys: the action's non-insert modes (insert mode has its own section)
  for name, value in pairs(maps.emacs or {}) do
    local a = actions.list[name]
    if a then
      for _, lhs in ipairs(config.lhs_list(value)) do
        for _, mode in ipairs(a.modes or { "n" }) do
          if mode ~= "i" then
            set(mode, lhs, wrap(name, lhs, mode), { buffer = bufnr, desc = "org: " .. a.desc }, record)
          end
        end
      end
    end
  end
  for _, section in ipairs({ maps.org_insert or {}, maps.emacs_insert or {} }) do
    for name, value in pairs(section) do
      local a = actions.list[name]
      if a then
        for _, lhs in ipairs(config.lhs_list(value)) do
          set("i", lhs, wrap(name, lhs, "i"), { buffer = bufnr, desc = "org: " .. a.desc }, record)
        end
      end
    end
  end
  -- a click on a link follows it (links.mouse_1_follows_link)
  require("org.mouse").attach(bufnr)
  -- text objects (synchronous)
  local to = maps.text_objects or {}
  local objs = {
    inner_heading = { "select_heading", true },
    around_heading = { "select_heading", false },
    inner_subtree = { "select_subtree", true },
    around_subtree = { "select_subtree", false },
  }
  for name, spec in pairs(objs) do
    for _, lhs in ipairs(config.lhs_list(to[name])) do
      set({ "o", "x" }, lhs, function()
        require("org.structure")[spec[1]](spec[2])
      end, { buffer = bufnr, desc = "org: " .. name:gsub("_", " ") }, record)
    end
  end
  vim.b[bufnr].org_keymaps = record
end

local groups = {
  { "", "org" },
  { "i", "insert" },
  { "h", "heading/subtree" },
  { "x", "clock/effort/preview" },
  { "n", "narrow" },
  { "l", "links" },
  { "b", "babel" },
  { "T", "table" },
}

function M.register_which_key()
  local ok, wk = pcall(require, "which-key")
  if not ok or not wk.add then
    return
  end
  local prefix = config.opts.mappings.prefix or "<leader>o"
  local spec = {}
  local all = vim.list_extend({}, groups)
  -- groups of the enabled extensions (org.Extension.groups)
  local loaded = require("org.extensions").loaded
  local names = vim.tbl_keys(loaded)
  table.sort(names)
  for _, name in ipairs(names) do
    vim.list_extend(all, loaded[name].groups or {})
  end
  for _, g in ipairs(all) do
    spec[#spec + 1] = { prefix .. g[1], group = g[2], mode = { "n", "x" } }
  end
  pcall(wk.add, spec)
end

--- Agenda keys for `g?`, in display order: { section, { { name, desc }... } }.
--- Mapped names missing here are listed under "Other".
local agenda_help = {
  {
    "Agenda buffer",
    {
      { "redo", "Rebuild the agenda" },
      { "redo_all", "Rebuild every agenda buffer" },
      { "quit", "Quit" },
      { "quit_kill", "Quit and kill the agenda buffer" },
      { "exit", "Exit and kill buffers the agenda opened" },
      { "save_all", "Save all org buffers" },
      { "undo", "Undo the last edit made from the agenda" },
      { "diary_entry", "Add a diary entry for the date" },
      { "export", "Write the agenda to a file" },
      { "append", "Append another agenda view" },
      { "delete_other_windows", "Delete other windows" },
      { "capture", "Capture" },
      { "calendar", "Show the date in the calendar" },
      { "convert_date", "The date in other calendars" },
      { "phases_of_moon", "Phases of the moon" },
      { "sunrise_sunset", "Sunrise and sunset" },
      { "holidays", "Holidays around the date" },
      { "columns", "Column view" },
      { "help", "Show agenda keymaps" },
    },
  },
  {
    "Dates & span",
    {
      { "today", "Go to today" },
      { "goto_date", "Go to a date" },
      { "later", "Later (next span)" },
      { "earlier", "Earlier (previous span)" },
      { "day_view", "Day view" },
      { "week_view", "Week view" },
      { "fortnight_view", "Fortnight view" },
      { "month_view", "Month view" },
      { "year_view", "Year view" },
      { "reset_view", "Reset the span" },
    },
  },
  {
    "Motion",
    {
      { "next_item", "Next item" },
      { "prev_item", "Previous item" },
      { "next_date_line", "Next date line" },
      { "prev_date_line", "Previous date line" },
      { "forward_block", "Next agenda block" },
      { "backward_block", "Previous agenda block" },
      { "drag_line_forward", "Drag the line down" },
      { "drag_line_backward", "Drag the line up" },
    },
  },
  {
    "Entry at point",
    {
      { "switch_to", "Go to the entry (this window)" },
      { "goto", "Go to the entry (other window)" },
      { "show", "Show the entry in the other window" },
      { "show_scroll_down", "Scroll the entry window back" },
      { "recenter", "Show the entry, centered" },
      { "follow_mode", "Toggle follow mode" },
      { "cycle_show", "Show the entry, cycling its visibility" },
      { "show_1", "Show the entry with a level of detail" },
      { "tree_to_indirect_buffer", "Edit the subtree in the other window" },
      { "goto_mouse", "Go to the entry clicked" },
      { "show_mouse", "Show the entry clicked" },
      { "open_link", "Open a link in the entry" },
      { "kill", "Delete the entry" },
    },
  },
  {
    "Edit entry",
    {
      { "todo", "Change the TODO state" },
      { "todo_next", "Next TODO state" },
      { "todo_prev", "Previous TODO state" },
      { "todo_yesterday", "Change the TODO state, logged yesterday 23:59" },
      { "priority", "Set the priority" },
      { "priority_up", "Raise the priority" },
      { "priority_down", "Lower the priority" },
      { "set_tags", "Set tags" },
      { "show_tags", "Show tags" },
      { "set_property", "Set a property" },
      { "set_effort", "Set the effort" },
      { "add_note", "Add a note" },
      { "attach", "Attachments" },
    },
  },
  {
    "Dates of the entry",
    {
      { "schedule", "Schedule" },
      { "deadline", "Set a deadline" },
      { "date_later", "Date one day later" },
      { "date_earlier", "Date one day earlier" },
      { "date_later_hours", "Time one hour later" },
      { "date_earlier_hours", "Time one hour earlier" },
      { "date_later_minutes", "Time a few minutes later" },
      { "date_earlier_minutes", "Time a few minutes earlier" },
      { "date_prompt", "Change the date" },
    },
  },
  {
    "Clock & timer",
    {
      { "clock_in", "Clock in" },
      { "clock_out", "Clock out" },
      { "clock_cancel", "Cancel the clock" },
      { "clock_goto", "Go to the clocked task" },
      { "timer", "Set a countdown timer" },
      { "timer_stop", "Stop the timer" },
    },
  },
  {
    "Refile & archive",
    {
      { "refile", "Refile" },
      { "archive", "Archive the subtree" },
      { "archive_default", "Archive (default command)" },
      { "archive_default_confirm", "Archive (default command), after confirmation" },
      { "archive_sibling", "Archive to the Archive sibling" },
      { "toggle_archive_tag", "Toggle the ARCHIVE tag" },
    },
  },
  {
    "Display",
    {
      { "log_mode", "Toggle log mode" },
      { "log_all_mode", "Toggle log mode (all states)" },
      { "clockcheck_mode", "Check clock consistency" },
      { "clockreport_mode", "Toggle the clock report" },
      { "entry_text_mode", "Toggle entry text" },
      { "archives_mode", "Toggle archived trees" },
      { "archives_files_mode", "Toggle archive files" },
      { "inactive_mode", "Toggle inactive timestamps" },
      { "time_grid", "Toggle the time grid" },
      { "toggle_deadlines", "Toggle upcoming deadlines" },
      { "toggle_diary", "Toggle the Emacs diary" },
      { "toggle_habits_display", "Toggle habits (count: all habits today)" },
      { "toggle_habits", "Toggle habits" },
      { "dim_blocked", "Toggle dimming blocked tasks" },
    },
  },
  {
    "Filter & limit",
    {
      { "filter", "Filter" },
      { "filter_tag", "Filter by tag" },
      { "filter_category", "Filter by category" },
      { "filter_regexp", "Filter by regexp" },
      { "filter_effort", "Filter by effort" },
      { "filter_top_headline", "Filter by top headline" },
      { "filter_remove", "Remove all filters" },
      { "limit", "Limit the number of entries" },
      { "query_add", "Search: add a word" },
      { "query_subtract", "Search: exclude a word" },
      { "query_add_re", "Search: add a regexp" },
      { "query_subtract_re", "Search: exclude a regexp" },
      { "restriction_lock", "Restrict to the subtree / file" },
      { "remove_restriction_lock", "Remove the restriction" },
    },
  },
  {
    "Bulk",
    {
      { "mark", "Mark" },
      { "unmark", "Unmark" },
      { "unmark_all", "Unmark all" },
      { "toggle_mark", "Toggle the mark" },
      { "mark_all", "Mark all" },
      { "toggle_mark_all", "Toggle all marks" },
      { "mark_regexp", "Mark by regexp" },
      { "bulk_action", "Bulk action on marked entries" },
    },
  },
}

--- "some_name" -> "Some name"
local function humanize(name)
  local s = name:gsub("_", " ")
  return (s:gsub("^%l", string.upper))
end

---@return org.HelpRow[]
local function agenda_help_rows()
  local maps = config.opts.mappings.agenda or {}
  local rows, seen = {}, {}
  for _, sec in ipairs(agenda_help) do
    local heading = { heading = sec[1] }
    for _, e in ipairs(sec[2]) do
      seen[e[1]] = true
      local lhs = config.lhs_list(maps[e[1]])
      if #lhs > 0 then
        if heading then
          rows[#rows + 1], heading = heading, nil
        end
        rows[#rows + 1] = { lhs, e[2] }
      end
    end
  end
  local other = {}
  for name, value in pairs(maps) do
    local lhs = config.lhs_list(value)
    if not seen[name] and #lhs > 0 then
      other[#other + 1] = { lhs, humanize(name) }
    end
  end
  table.sort(other, function(a, b)
    return a[2] < b[2]
  end)
  if #other > 0 then
    rows[#rows + 1] = { heading = "Other" }
    vim.list_extend(rows, other)
  end
  return rows
end

---@return org.HelpRow[]
local function org_help_rows()
  local maps = config.opts.mappings
  -- action name -> keys, merged across sections and deduplicated
  local keys = {}
  local function add(name, lhs)
    keys[name] = keys[name] or {}
    if not vim.tbl_contains(keys[name], lhs) then
      table.insert(keys[name], lhs)
    end
  end
  for _, sec in ipairs({
    { maps.global, false },
    { maps.org, false },
    { maps.org_insert, true },
    { maps.emacs_global, false },
    { maps.emacs, false },
    { maps.emacs_insert, true },
  }) do
    for name, value in pairs(sec[1] or {}) do
      if actions.list[name] then
        for _, lhs in ipairs(config.lhs_list(value)) do
          add(name, sec[2] and ("i_" .. lhs) or lhs)
        end
      end
    end
  end
  local by_group = {}
  for name, lhs in pairs(keys) do
    local a = actions.list[name]
    local g = a.group or "Other"
    by_group[g] = by_group[g] or {}
    table.insert(by_group[g], { lhs, a.desc })
  end
  local objects = {}
  for _, name in ipairs({ "inner_heading", "around_heading", "inner_subtree", "around_subtree" }) do
    local lhs = config.lhs_list((maps.text_objects or {})[name])
    if #lhs > 0 then
      objects[#objects + 1] = { lhs, humanize(name) }
    end
  end
  local rows = {}
  local order = vim.list_extend(vim.list_extend({}, actions.groups), { "Other" })
  for _, g in ipairs(order) do
    local list = by_group[g]
    if list then
      table.sort(list, function(a, b)
        return a[2] < b[2]
      end)
      rows[#rows + 1] = { heading = g }
      vim.list_extend(rows, list)
    end
  end
  if #objects > 0 then
    rows[#rows + 1] = { heading = "Text objects" }
    vim.list_extend(rows, objects)
  end
  return rows
end

--- `g?` help float for the current buffer kind: keys grouped by topic, one
--- row per action with all of its keys (`i_` marks Insert-mode keys).
function M.show_help()
  if vim.bo.filetype == "orgagenda" then
    require("org.ui").help("org agenda keymaps", agenda_help_rows())
  else
    require("org.ui").help("org keymaps", org_help_rows())
  end
end

return M
