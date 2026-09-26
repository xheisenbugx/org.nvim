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

local function wrap(name, lhs, mode)
  return function()
    if not actions.run(name) then
      fallback(lhs, mode)
    end
  end
end

local function set(mode, lhs, rhs, opts)
  vim.keymap.set(mode, lhs, rhs, opts)
end

--- Global keymaps (agenda, capture, ...).
function M.setup_global()
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
              set(mode, lhs, wrap(name, lhs, mode), { desc = "org: " .. a.desc })
            end
          end
        end
      end
    end
  end
  M.register_which_key()
end

--- Buffer-local keymaps for an org buffer.
function M.attach(bufnr)
  local maps = config.opts.mappings
  if maps.disable_all then
    return
  end
  for name, value in pairs(maps.org or {}) do
    local a = actions.list[name]
    if a then
      for _, lhs in ipairs(config.lhs_list(value)) do
        for _, mode in ipairs(a.modes or { "n" }) do
          if mode ~= "i" or name == "meta_return" or name == "meta_shift_return" then
            set(mode, lhs, wrap(name, lhs, mode), { buffer = bufnr, desc = "org: " .. a.desc })
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
            set(mode, lhs, wrap(name, lhs, mode), { buffer = bufnr, desc = "org: " .. a.desc })
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
          set("i", lhs, wrap(name, lhs, "i"), { buffer = bufnr, desc = "org: " .. a.desc })
        end
      end
    end
  end
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
      end, { buffer = bufnr, desc = "org: " .. name:gsub("_", " ") })
    end
  end
end

local groups = {
  { "", "org" },
  { "i", "insert" },
  { "h", "heading/subtree" },
  { "x", "clock" },
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
  for _, g in ipairs(groups) do
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
      { "export", "Write the agenda to a file" },
      { "append", "Append another agenda view" },
      { "delete_other_windows", "Delete other windows" },
      { "capture", "Capture" },
      { "calendar", "Show the date in the calendar" },
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
