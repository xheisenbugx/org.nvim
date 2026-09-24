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
  store_link = { "org.links", "store_link", desc = "Store link to current location", global = true },
  goto_heading = { "org.agenda.search", "goto_heading", desc = "Go to heading in agenda files", global = true },
  clock_goto = { "org.clock", "goto_clock", desc = "Go to clocked task", global = true },
  clock_out = { "org.clock", "clock_out", desc = "Clock out", global = true },
  clock_cancel = { "org.clock", "clock_cancel", desc = "Cancel clock", global = true },
  help = { "org.mappings", "show_help", desc = "Show org keymaps", global = true },

  -- visibility
  cycle = { "org.fold", "cycle", desc = "Cycle visibility" },
  global_cycle = { "org.fold", "global_cycle", desc = "Cycle global visibility" },

  -- context
  context_action = { "org.context", "context_action", desc = "Context action (C-c C-c)" },
  open_at_point = { "org.context", "open_at_point", desc = "Open link / footnote / date at point" },

  -- structure
  meta_return = { "org.context", "meta_return", desc = "New heading / item / row", modes = { "n", "i" } },
  meta_shift_return = { "org.context", "meta_shift_return", desc = "New TODO heading / checkbox item", modes = { "n", "i" } },
  insert_heading = { "org.structure", "insert_heading", desc = "Insert heading after subtree" },
  insert_todo_heading = { "org.structure", "insert_todo_heading", desc = "Insert TODO heading" },
  insert_subheading = { "org.structure", "insert_subheading", desc = "Insert subheading" },
  insert_drawer = { "org.structure", "insert_drawer", desc = "Insert drawer" },
  insert_structure_template = { "org.structure", "insert_structure_template", desc = "Insert block (#+begin_...)", modes = { "n", "x" } },
  insert_footnote = { "org.footnotes", "new_footnote", desc = "Insert footnote" },
  promote_heading = { "org.context", "promote", desc = "Promote heading / item" },
  demote_heading = { "org.context", "demote", desc = "Demote heading / item" },
  promote_subtree = { "org.context", "promote_subtree", desc = "Promote subtree" },
  demote_subtree = { "org.context", "demote_subtree", desc = "Demote subtree" },
  meta_left = { "org.context", "meta_left", desc = "Promote / move column left" },
  meta_right = { "org.context", "meta_right", desc = "Demote / move column right" },
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
  toggle_comment = { "org.structure", "toggle_comment", desc = "Toggle COMMENT keyword" },
  toggle_archive_tag = { "org.archive", "toggle_archive_tag", desc = "Toggle ARCHIVE tag" },
  toggle_heading = { "org.structure", "toggle_heading", desc = "Toggle heading", modes = { "n", "x" } },
  toggle_item = { "org.lists", "toggle_item", desc = "Toggle list item", modes = { "n", "x" } },
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
  shift_up = { "org.context", "shift_up", desc = "Priority up / timestamp up" },
  shift_down = { "org.context", "shift_down", desc = "Priority down / timestamp down" },
  increment = { "org.context", "increment", desc = "Increment timestamp / priority" },
  decrement = { "org.context", "decrement", desc = "Decrement timestamp / priority" },
  priority = { "org.priority", "set", desc = "Set priority" },
  set_tags = { "org.tags", "set_tags", desc = "Set tags" },
  set_property = { "org.properties", "set_property", desc = "Set property" },
  delete_property = { "org.properties", "delete_property", desc = "Delete property" },
  id_get_create = { "org.id", "get_create", desc = "Get or create ID" },

  -- dates
  schedule = { "org.timestamps", "schedule", desc = "Schedule" },
  deadline = { "org.timestamps", "deadline", desc = "Deadline" },
  timestamp = { "org.timestamps", "insert_active", desc = "Insert active timestamp" },
  timestamp_inactive = { "org.timestamps", "insert_inactive", desc = "Insert inactive timestamp" },

  -- lists
  toggle_checkbox = { "org.lists", "toggle_checkbox", desc = "Toggle checkbox" },
  update_statistics = { "org.lists", "update_statistics", desc = "Update statistics cookies" },
  cycle_bullet = { "org.lists", "cycle_bullet", desc = "Cycle list bullet" },

  -- clock
  clock_in = { "org.clock", "clock_in", desc = "Clock in" },
  set_effort = { "org.properties", "set_effort", desc = "Set effort" },
  clock_report = { "org.dblock", "insert_clocktable", desc = "Insert clock report" },
  clock_display = { "org.clock", "toggle_display", desc = "Display clock sums" },
  dblock_update = { "org.dblock", "update_at_cursor", desc = "Update dynamic block" },
  dblock_update_all = { "org.dblock", "update_all", desc = "Update all dynamic blocks" },
  column_view = { "org.columns", "open", desc = "Column view" },

  -- links
  insert_link = { "org.links", "insert_link", desc = "Insert link", modes = { "n", "x" } },
  toggle_link_display = { "org.links", "toggle_link_display", desc = "Toggle link display" },
  next_link = { "org.links", "next_link", desc = "Next link" },
  prev_link = { "org.links", "prev_link", desc = "Previous link" },

  -- refile / archive / attach
  refile = { "org.refile", "refile", desc = "Refile subtree" },
  archive_subtree = { "org.archive", "archive_subtree", desc = "Archive subtree" },
  attach = { "org.attach", "menu", desc = "Attachments" },

  -- search / export
  sparse_tree = { "org.agenda.sparse", "prompt", desc = "Sparse tree" },
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
  table_next_field = { "org.table", "next_field", desc = "Next table field", modes = { "i" } },
  table_prev_field = { "org.table", "prev_field", desc = "Previous table field", modes = { "i" } },
  table_next_row = { "org.table", "next_row", desc = "Next table row", modes = { "i" } },

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
