---@mod org.actions Action registry
---
--- Every user-facing operation has a name. Mappings (`mappings.org.<name>`)
--- and `:Org <name>` resolve through this table. Each entry points at a
--- module function that is called with no arguments and operates at the
--- cursor. Returning `false` means "not applicable here": key mappings then
--- fall back to the key's default behaviour.

local M = {}

---@class org.Action
---@field [1] string module
---@field [2] string function name
---@field desc string
---@field modes? string[] default { "n" }
---@field global? boolean available outside org buffers
---@field sync? boolean call synchronously (no coroutine) - for text objects / expr

M.list = {
  -- global
  agenda = { "org.agenda", "prompt", desc = "Agenda dispatcher", global = true },
  capture = { "org.capture", "prompt", desc = "Capture", global = true },
  capture_goto_target = { "org.capture", "goto_target", desc = "Go to a capture template's target", global = true },
  capture_goto_last = { "org.capture", "goto_last_stored", desc = "Go to the last captured entry", global = true },
  store_link = { "org.links", "store_link", desc = "Store link to current location", global = true },
  goto_heading = { "org.agenda.search", "goto_heading", desc = "Go to heading in agenda files", global = true },
  clock_goto = { "org.clock", "goto_clock", desc = "Go to clocked task", global = true },
  clock_out = { "org.clock", "clock_out", desc = "Clock out", global = true },
  clock_cancel = { "org.clock", "clock_cancel", desc = "Cancel clock", global = true },
  help = { "org.mappings", "show_help", desc = "Show org keymaps", global = true },

  -- visibility
  cycle = { "org.fold", "cycle", desc = "Cycle visibility" },
  global_cycle = { "org.fold", "global_cycle", desc = "Cycle global visibility" },
  show_branches = { "org.fold", "show_branches", desc = "Show all branches of subtree" },
  show_children = { "org.fold", "show_children", desc = "Show children" },
  reveal = { "org.fold", "reveal", desc = "Reveal context around cursor" },
  force_cycle_archived = { "org.fold", "force_cycle_archived", desc = "Cycle subtree, even when archived" },
  set_startup_visibility = { "org.fold", "set_startup_visibility", desc = "Restore startup visibility" },
  show_everything = { "org.fold", "show_everything", desc = "Show everything, including drawers" },
  copy_visible = { "org.fold", "copy_visible", desc = "Copy visible text", modes = { "n", "x" } },

  -- context
  context_action = { "org.context", "context_action", desc = "Context action (C-c C-c)" },
  open_at_point = { "org.context", "open_at_point", desc = "Open link / footnote / date at point" },

  -- structure
  meta_return = { "org.context", "meta_return", desc = "New heading / item / row", modes = { "n", "i" } },
  insert_tab = {
    "org.context",
    "insert_tab",
    desc = "Table: next field / empty heading or item: cycle level",
    modes = { "i" },
  },
  meta_shift_return = {
    "org.context",
    "meta_shift_return",
    desc = "New TODO heading / checkbox item",
    modes = { "n", "i" },
  },
  insert_heading = { "org.structure", "insert_heading", desc = "Insert heading after subtree" },
  insert_todo_heading = { "org.structure", "insert_todo_heading", desc = "Insert TODO heading" },
  insert_subheading = { "org.structure", "insert_subheading", desc = "Insert subheading" },
  insert_drawer = { "org.structure", "insert_drawer", desc = "Insert drawer" },
  insert_structure_template = {
    "org.structure",
    "insert_structure_template",
    desc = "Insert block (#+begin_...)",
    modes = { "n", "x" },
  },
  insert_footnote = { "org.footnotes", "footnote_action", desc = "Footnote: jump / new / menu (count)" },
  promote_heading = { "org.context", "promote", desc = "Promote heading / item" },
  demote_heading = { "org.context", "demote", desc = "Demote heading / item" },
  promote_subtree = { "org.context", "promote_subtree", desc = "Promote subtree" },
  demote_subtree = { "org.context", "demote_subtree", desc = "Demote subtree" },
  meta_left = { "org.context", "meta_left", desc = "Promote / move column left", modes = { "n", "x" } },
  meta_right = { "org.context", "meta_right", desc = "Demote / move column right", modes = { "n", "x" } },
  meta_up = { "org.context", "meta_up", desc = "Move subtree / item / row up" },
  meta_down = { "org.context", "meta_down", desc = "Move subtree / item / row down" },
  shift_meta_left = { "org.context", "shift_meta_left", desc = "Promote subtree / delete column" },
  shift_meta_right = { "org.context", "shift_meta_right", desc = "Demote subtree / insert column" },
  shift_meta_up = { "org.context", "shift_meta_up", desc = "Delete table row / move up" },
  shift_meta_down = { "org.context", "shift_meta_down", desc = "Insert table row / move down" },
  move_subtree_up = { "org.structure", "move_subtree_up", desc = "Move subtree up" },
  move_subtree_down = { "org.structure", "move_subtree_down", desc = "Move subtree down" },
  copy_subtree = { "org.structure", "copy_subtree", desc = "Copy subtree" },
  cut_subtree = { "org.structure", "cut_subtree", desc = "Cut subtree" },
  paste_subtree = { "org.structure", "paste_subtree", desc = "Paste subtree" },
  clone_subtree = { "org.structure", "clone_subtree", desc = "Clone subtree with time shift" },
  sort = { "org.structure", "sort", desc = "Sort entries / items" },
  narrow_subtree = { "org.structure", "narrow_subtree", desc = "Narrow to subtree (edit buffer)" },
  indirect_subtree = { "org.structure", "tree_to_indirect_buffer", desc = "Subtree in split edit buffer" },
  mark_subtree = { "org.structure", "mark_subtree", desc = "Select subtree", modes = { "n", "x" } },
  toggle_comment = { "org.structure", "toggle_comment", desc = "Toggle COMMENT keyword" },
  toggle_archive_tag = { "org.archive", "toggle_archive_tag", desc = "Toggle ARCHIVE tag" },
  toggle_heading = { "org.structure", "toggle_heading", desc = "Toggle heading", modes = { "n", "x" } },
  toggle_item = { "org.lists", "toggle_item", desc = "Toggle list item", modes = { "n", "x" } },
  ctrl_c_star = { "org.context", "ctrl_c_star", desc = "Recalc table / toggle heading", modes = { "n", "x" } },
  ctrl_c_minus = {
    "org.context",
    "ctrl_c_minus",
    desc = "Table hline / cycle bullet / toggle item",
    modes = { "n", "x" },
  },
  ctrl_c_ret = { "org.context", "ctrl_c_ret", desc = "Table hline and move / insert heading" },
  copy_special = { "org.context", "copy_special", desc = "Copy table region / subtree", modes = { "n", "x" } },
  cut_special = { "org.context", "cut_special", desc = "Cut table region / subtree", modes = { "n", "x" } },
  paste_special = { "org.context", "paste_special", desc = "Paste table rectangle / subtree" },
  ctrl_c_caret = { "org.context", "ctrl_c_caret", desc = "Sort table column / entries / items" },
  emphasize = { "org.structure", "emphasize", desc = "Emphasize selection", modes = { "x" } },
  goto_parent = { "org.structure", "goto_parent", desc = "Go to parent heading" },
  next_heading = { "org.structure", "next_heading", desc = "Next heading", modes = { "n", "x", "o" } },
  prev_heading = { "org.structure", "prev_heading", desc = "Previous heading", modes = { "n", "x", "o" } },
  next_sibling = { "org.structure", "next_sibling", desc = "Next sibling heading", modes = { "n", "x", "o" } },
  prev_sibling = { "org.structure", "prev_sibling", desc = "Previous sibling heading", modes = { "n", "x", "o" } },
  buffer_goto = { "org.structure", "goto_heading", desc = "Go to heading in buffer" },

  -- todo / priority / tags / properties
  todo_next = { "org.todo", "cycle_next", desc = "Next TODO state" },
  todo_prev = { "org.todo", "cycle_prev", desc = "Previous TODO state" },
  shift_right = { "org.context", "shift_right", desc = "Next TODO / date +1 / bullet" },
  shift_left = { "org.context", "shift_left", desc = "Previous TODO / date -1 / bullet" },
  todo_select = { "org.todo", "select", desc = "Select TODO state" },
  todo_next_sequence = { "org.context", "shift_control_right", desc = "Next TODO keyword set" },
  todo_prev_sequence = { "org.context", "shift_control_left", desc = "Previous TODO keyword set" },
  add_note = { "org.todo", "add_note", desc = "Add note" },
  todo = { "org.todo", "select_or_cycle", desc = "Change TODO state (C-c C-t)" },
  toggle_ordered = { "org.properties", "toggle_ordered", desc = "Toggle ORDERED property" },
  shift_up = { "org.context", "shift_up", desc = "Priority up / timestamp up" },
  shift_down = { "org.context", "shift_down", desc = "Priority down / timestamp down" },
  increment = { "org.context", "increment", desc = "Increment timestamp / priority" },
  decrement = { "org.context", "decrement", desc = "Decrement timestamp / priority" },
  priority = { "org.priority", "set", desc = "Set priority" },
  set_tags = { "org.tags", "set_tags_command", desc = "Set tags (Visual: change tag in region)", modes = { "n", "x" } },
  set_property = { "org.properties", "set_property", desc = "Set property" },
  delete_property = { "org.properties", "delete_property", desc = "Delete property" },
  delete_property_globally = {
    "org.properties",
    "delete_property_globally",
    desc = "Delete a property from all entries",
  },
  id_get_create = { "org.id", "get_create", desc = "Get or create ID" },

  -- dates
  schedule = { "org.timestamps", "schedule", desc = "Schedule" },
  deadline = { "org.timestamps", "deadline", desc = "Deadline" },
  timestamp = { "org.timestamps", "insert_active", desc = "Insert active timestamp" },
  timestamp_inactive = { "org.timestamps", "insert_inactive", desc = "Insert inactive timestamp" },
  date_today = { "org.timestamps", "insert_today", desc = "Insert today's date" },
  goto_calendar = { "org.timestamps", "goto_calendar", desc = "Open calendar" },
  evaluate_time_range = { "org.timestamps", "evaluate_time_range", desc = "Evaluate time range" },

  -- lists
  toggle_checkbox = { "org.lists", "toggle_checkbox", desc = "Toggle checkbox", modes = { "n", "x" } },
  update_statistics = { "org.lists", "update_statistics", desc = "Update statistics cookies" },
  cycle_bullet = { "org.lists", "cycle_bullet", desc = "Cycle list bullet" },

  -- clock
  clock_in = { "org.clock", "clock_in", desc = "Clock in" },
  clock_in_last = { "org.clock", "clock_in_last", desc = "Clock in last task" },
  set_effort = { "org.properties", "set_effort", desc = "Set effort" },
  clock_report = { "org.dblock", "insert_clocktable", desc = "Insert clock report" },
  clock_display = { "org.clock", "toggle_display", desc = "Display clock sums" },
  dblock_update = { "org.dblock", "update_at_cursor", desc = "Update dynamic block" },
  dblock_update_all = { "org.dblock", "update_all", desc = "Update all dynamic blocks" },
  column_view = { "org.columns", "open", desc = "Column view" },
  insert_columnview = { "org.dblock", "insert_columnview", desc = "Insert columnview block" },
  insert_dblock = { "org.dblock", "insert_dblock", desc = "Insert dynamic block" },

  -- timers
  timer_start = { "org.timer", "start", desc = "Start relative timer" },
  timer_stop = { "org.timer", "stop", desc = "Stop timer" },
  timer_pause = { "org.timer", "pause_or_continue", desc = "Pause / continue timer" },
  timer_insert = { "org.timer", "insert", desc = "Insert timer value" },
  timer_item = { "org.timer", "insert_item", desc = "Insert timer list item" },
  timer_countdown = { "org.timer", "countdown", desc = "Start countdown timer" },

  -- links
  insert_link = { "org.links", "insert_link", desc = "Insert link", modes = { "n", "x" } },
  toggle_link_display = { "org.links", "toggle_link_display", desc = "Toggle link display" },
  next_link = { "org.links", "next_link", desc = "Next link" },
  prev_link = { "org.links", "prev_link", desc = "Previous link" },

  -- refile / archive / attach
  refile = { "org.refile", "refile", desc = "Refile subtree" },
  refile_copy = { "org.refile", "refile_copy", desc = "Copy subtree to a refile target" },
  refile_goto = { "org.refile", "goto", desc = "Jump to a refile target", global = true },
  refile_goto_last = { "org.refile", "goto_last_stored", desc = "Jump to last refile / capture", global = true },
  archive_subtree = { "org.archive", "archive_subtree", desc = "Archive subtree" },
  archive_to_sibling = { "org.archive", "archive_to_sibling", desc = "Archive to Archive sibling" },
  archive_all_done = { "org.archive", "archive_all_done", desc = "Archive children without open TODOs" },
  attach = { "org.attach", "menu", desc = "Attachments" },
  agenda_file_to_front = { "org.files", "agenda_file_to_front", desc = "Add file to agenda files" },
  cycle_agenda_files = { "org.agenda", "cycle_files", desc = "Visit next agenda file", global = true },
  agenda_set_restriction_lock = { "org.agenda", "set_restriction_lock", desc = "Lock agenda to subtree / file" },
  agenda_remove_restriction_lock = {
    "org.agenda",
    "remove_restriction_lock",
    desc = "Remove agenda restriction lock",
    global = true,
  },
  agenda_file_remove = { "org.files", "remove_file", desc = "Remove file from agenda files" },

  -- search / export
  sparse_tree = { "org.agenda.sparse", "prompt", desc = "Sparse tree" },
  tags_sparse_tree = { "org.agenda.sparse", "tags_tree", desc = "Tags / property match sparse tree" },
  export = { "org.export", "prompt", desc = "Export dispatcher" },

  -- tables
  table_create = { "org.table", "create_or_convert", desc = "Create table / convert region", modes = { "n", "x" } },
  table_insert_hline = { "org.table", "insert_hline", desc = "Insert table hline" },
  table_recalc = { "org.table", "recalc", desc = "Recalculate table formulas" },
  table_sort = { "org.table", "sort_column", desc = "Sort table by column" },
  table_insert_row = { "org.table", "insert_row", desc = "Insert table row" },
  table_delete_row = { "org.table", "delete_row", desc = "Delete table row" },
  table_insert_column = { "org.table", "insert_column", desc = "Insert table column" },
  table_delete_column = { "org.table", "delete_column", desc = "Delete table column" },
  table_formula = { "org.table", "eval_formula", desc = "Set column / field formula" },
  table_edit_field = { "org.table", "edit_field", desc = "Edit table field" },
  table_sum = { "org.table", "sum", desc = "Sum column / rectangle", modes = { "n", "x" } },
  table_blank_field = { "org.table", "blank_field", desc = "Blank table field(s)", modes = { "n", "x" } },
  table_coordinates = { "org.table", "toggle_coordinate_overlays", desc = "Toggle table coordinates" },
  table_field_info = { "org.table", "field_info", desc = "Table field info" },
  table_recalc_buffer = { "org.table", "recalc_buffer", desc = "Recalculate all tables" },
  table_next_field = { "org.table", "next_field", desc = "Next table field", modes = { "i" } },
  table_prev_field = { "org.table", "prev_field", desc = "Previous table field", modes = { "i" } },
  table_next_row = { "org.table", "next_row", desc = "Next table row", modes = { "i" } },
  table_copy_down = { "org.table", "copy_down", desc = "Copy table field down", modes = { "n", "i" } },
  table_transpose = { "org.table", "transpose", desc = "Transpose table" },
  table_rotate_marks = {
    "org.table",
    "rotate_recalc_marks",
    desc = "Rotate table recalculation mark",
    modes = { "n", "x" },
  },
  table_import = { "org.table", "import", desc = "Import file as table" },
  table_export = { "org.table", "export", desc = "Export table to TSV/CSV file" },

  -- babel
  edit_special = { "org.context", "edit_special", desc = "Edit src block / table formulas" },
  babel_execute = { "org.babel", "execute_block", desc = "Execute src block" },
  babel_execute_buffer = { "org.babel", "execute_buffer", desc = "Execute all src blocks" },
  babel_execute_subtree = { "org.babel", "execute_subtree", desc = "Execute src blocks in subtree" },
  babel_tangle = { "org.babel", "tangle", desc = "Tangle file" },
  babel_remove_result = { "org.babel", "remove_result", desc = "Remove src block result" },
  babel_next_block = { "org.babel", "next_block", desc = "Next src block" },
  babel_prev_block = { "org.babel", "prev_block", desc = "Previous src block" },
}

--- Resolve an action to its function.
---@return function|nil, org.Action|nil
function M.get(name)
  local a = M.list[name]
  if not a then
    return nil
  end
  local ok, mod = pcall(require, a[1])
  if not ok then
    require("org.utils").error("Failed to load " .. a[1] .. ": " .. tostring(mod))
    return nil, a
  end
  local fn = mod[a[2]]
  if type(fn) ~= "function" then
    require("org.utils").error(string.format("Action %s: %s.%s is not implemented", name, a[1], a[2]))
    return nil, a
  end
  return fn, a
end

--- Run an action inside a coroutine. Returns true when handled.
function M.run(name, ...)
  local fn = M.get(name)
  if not fn then
    return true
  end
  local finished, result = require("org.utils").run(fn, ...)
  return not (finished and result == false)
end

return M
