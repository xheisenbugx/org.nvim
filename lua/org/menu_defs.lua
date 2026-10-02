---@mod org.menu_defs The entries of the Org menus
---
--- One builder per Emacs easymenu, entries in Emacs's order: org-org-menu
--- and org-tbl-menu (org.el), org-agenda-menu (org-agenda.el),
--- org-columns-menu (org-colview.el), org-table-fedit-menu and
--- orgtbl-mode-menu (org-table.el). Each Emacs command is bound to the
--- org.nvim action doing the same; `active` is Emacs's :active form.

local config = require("org.config")
local utils = require("org.utils")

local M = {}

---------------------------------------------------------------------------
-- Predicates (the :active forms)
---------------------------------------------------------------------------

local P = {}
M.predicates = P

local function lnum()
  return vim.api.nvim_win_get_cursor(0)[1]
end

--- org-at-table-p (an Org table, not a table.el one)
function P.at_table()
  return require("org.table").find(0, lnum()) ~= nil
end

--- (org-at-table-p 'any): table.el tables too
function P.at_any_table()
  return P.at_table() or require("org.table.el").at(0, lnum()) and true or false
end

function P.not_at_table()
  return not P.at_table()
end

--- org-at-heading-p
function P.at_heading()
  return require("org.parser").headline_level(vim.api.nvim_get_current_line()) ~= nil
end

--- org-before-first-heading-p
function P.before_first_heading()
  local parser = require("org.parser")
  for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, lnum(), false)) do
    if parser.headline_level(l) then
      return false
    end
  end
  return true
end

function P.after_first_heading()
  return not P.before_first_heading()
end

--- org-in-subtree-not-table-p
function P.in_subtree_not_table()
  return not P.before_first_heading() and not P.at_table()
end

--- (org-at-timestamp-p 'lax)
function P.at_timestamp()
  return require("org.timestamps").at_cursor() ~= nil
end

--- org-region-active-p
function P.region()
  local m = vim.fn.mode()
  return m == "v" or m == "V" or m == "\22"
end

--- (> (length org-todo-sets) 1) at a heading
function P.todo_sets_at_heading()
  if not P.at_heading() then
    return false
  end
  local file = require("org.files").get_buffer(0)
  return file ~= nil and #file.settings.todo.sequences > 1
end

--- (org-agenda-check-type nil 'agenda)
function P.agenda_view()
  return require("org.agenda.view").has_agenda_block()
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

--- `org-show-todo-tree`: sparse tree of the TODO entries.
local function todo_tree()
  require("org.agenda.sparse").headlines(function(hl)
    return hl:is_todo()
  end, "TODO entries")
end

--- Toggle a boolean option for this session and say so.
local function toggle_option(path, what)
  local t = config.opts
  for i = 1, #path - 1 do
    t = t[path[i]]
  end
  local key = path[#path]
  t[key] = not t[key]
  utils.notify(string.format("%s %s", what, t[key] and "on" or "off"))
end

--- The customize buffer at an option (Emacs: customize-variable).
local function customize(path)
  return function()
    require("org.customize").open({ option = path })
  end
end

--- The agenda files, one entry each (org-file-menu-entry: find-file).
local function file_entries()
  local ok, list = pcall(require("org.files").agenda_file_paths)
  local out = {}
  for _, f in ipairs(ok and list or {}) do
    out[#out + 1] = {
      utils.abbreviate(f),
      fn = function()
        utils.open_file(f)
      end,
      hint = false,
    }
  end
  return out
end

--- org-install-agenda-files-menu: "File List for Agenda".
local function agenda_files_menu()
  return vim.list_extend({
    { "Edit File List", action = "edit_agenda_file_list" },
    { "Add/Move Current File to Front", action = "agenda_file_to_front" },
    { "Remove Current File", action = "agenda_file_remove" },
    { "Cycle Through Files", action = "cycle_agenda_files" },
    {
      "Occur in Files",
      fn = function()
        -- org-occur-in-agenda-files: the agenda's regexp search
        require("org.agenda").command("/")
      end,
    },
    "--",
  }, file_entries())
end

--- An entry that is always greyed out.
local function greyed(label)
  return {
    label,
    fn = function() end,
    active = function()
      return false
    end,
  }
end

local function clock_in(count)
  return { action = "clock_in", count = count }
end

---------------------------------------------------------------------------
-- org-org-menu
---------------------------------------------------------------------------

function M.org()
  local function e(label, spec)
    spec[1] = label
    return spec
  end
  return {
    {
      "Show/Hide",
      items = {
        {
          "Cycle Visibility",
          action = "cycle",
          active = function()
            return lnum() == 1 or P.at_heading()
          end,
        },
        { "Cycle Global Visibility", action = "global_cycle", active = P.not_at_table },
        { "Sparse Tree...", action = "sparse_tree" },
        { "Reveal Context", action = "reveal" },
        { "Show All", action = "show_everything" },
        "--",
        { "Subtree to Indirect Buffer", action = "indirect_subtree" },
      },
    },
    "--",
    {
      "New Heading",
      fn = function()
        -- org-insert-heading
        require("org.structure").meta_return_heading({})
        utils.start_insert()
      end,
      hint = M.key_or_nil("meta_return"),
    },
    {
      "Navigate Headings",
      items = {
        { "Up", action = "goto_parent" },
        { "Next", action = "next_heading" },
        { "Previous", action = "prev_heading" },
        { "Next Same Level", action = "next_sibling" },
        { "Previous Same Level", action = "prev_sibling" },
        "--",
        { "Jump", action = "buffer_goto" },
      },
    },
    {
      "Edit Structure",
      items = {
        { "Move Subtree Up", action = "meta_up", active = P.at_heading },
        { "Move Subtree Down", action = "meta_down", active = P.at_heading },
        "--",
        { "Copy Subtree", action = "copy_special", active = P.in_subtree_not_table },
        { "Cut Subtree", action = "cut_special", active = P.in_subtree_not_table },
        { "Paste Subtree", action = "paste_special", active = P.not_at_table },
        "--",
        { "Clone Subtree, Shift Time", action = "clone_subtree" },
        "--",
        { "Copy Visible Text", action = "copy_visible" },
        "--",
        { "Promote Heading", action = "meta_left", active = P.in_subtree_not_table },
        { "Promote Subtree", action = "shift_meta_left", active = P.in_subtree_not_table },
        { "Demote Heading", action = "meta_right", active = P.in_subtree_not_table },
        { "Demote Subtree", action = "shift_meta_right", active = P.in_subtree_not_table },
        "--",
        { "Sort Region/Children", action = "sort" },
        "--",
        { "Convert to Odd Levels", action = "convert_to_odd_levels" },
        { "Convert to Odd/Even Levels", action = "convert_to_oddeven_levels" },
      },
    },
    {
      "Editing",
      items = {
        { "Emphasis...", action = "emphasize" },
        { "Add Block Structure", action = "insert_structure_template" },
        { "Edit Source Example", action = "edit_special" },
        "--",
        { "Footnote New/Jump", action = "insert_footnote" },
        { "Footnote Extra", action = "insert_footnote", count = 4 },
      },
    },
    {
      "Archive",
      items = {
        { "Archive (Default Method)", action = "archive_subtree_default", active = P.in_subtree_not_table },
        "--",
        { "Move Subtree to Archive File", action = "archive_subtree", active = P.in_subtree_not_table },
        { "Toggle ARCHIVE Tag", action = "toggle_archive_tag", active = P.in_subtree_not_table },
        { "Move Subtree to Archive Sibling", action = "archive_to_sibling", active = P.in_subtree_not_table },
      },
    },
    "--",
    {
      "Hyperlinks",
      items = {
        { "Store Link (Global)", action = "store_link" },
        { "Find Existing Link to Here", action = "occur_link_in_agenda_files" },
        { "Insert Link", action = "insert_link" },
        { "Follow Link", action = "open_at_point" },
        "--",
        { "Next Link", action = "next_link" },
        { "Previous Link", action = "prev_link" },
        "--",
        { "Descriptive Links", action = "toggle_link_display" },
        { "Literal Links", action = "toggle_link_display" },
      },
    },
    "--",
    {
      "TODO Lists",
      items = {
        { "TODO/DONE/-", action = "todo" },
        {
          "Select Keyword",
          items = {
            { "Next Keyword", action = "shift_right", active = P.at_heading },
            { "Previous Keyword", action = "shift_left", active = P.at_heading },
            {
              "Complete Keyword",
              -- pcomplete on a TODO keyword: the omni completion
              keys = "a<C-x><C-o>",
              hint = false,
              active = P.at_heading,
            },
            { "Next Keyword Set", action = "todo_next_sequence", active = P.todo_sets_at_heading },
            { "Previous Keyword Set", action = "todo_prev_sequence", active = P.todo_sets_at_heading },
          },
        },
        { "Show TODO Tree", fn = todo_tree, hint = false },
        {
          "Global TODO List",
          fn = function()
            require("org.agenda").command("t")
          end,
          hint = false,
        },
        "--",
        { "Enforce Dependencies", fn = customize({ "enforce_todo_dependencies" }) },
        { "Settings for Tree at Point", title = true },
        "--",
        {
          "Enforce TODO Completion Order",
          action = "toggle_ordered",
          active = function()
            return config.opts.enforce_todo_dependencies == true
          end,
        },
        "--",
        { "Set Priority", action = "priority" },
        { "Priority Up", action = "shift_up" },
        { "Priority Down", action = "shift_down" },
        "--",
        { "Get News From All Feeds", action = "feed_update_all" },
        { "Go to Inbox of Feed...", action = "feed_goto_inbox" },
        { "Customize Feeds", fn = customize({ "feed", "alist" }) },
      },
    },
    {
      "Tags and Properties",
      items = {
        { "Set Tags", action = "set_tags", active = P.after_first_heading },
        { "Change Tag in Region", action = "set_tags", visual = true, active = P.region },
        "--",
        { "Set Property", action = "set_property", active = P.after_first_heading },
        { "Column View of Properties", action = "column_view" },
        { "Insert Column View DBlock", action = "insert_columnview" },
      },
    },
    {
      "Dates and Scheduling",
      items = {
        { "Timestamp", action = "timestamp", active = P.after_first_heading },
        { "Timestamp (Inactive)", action = "timestamp_inactive", active = P.after_first_heading },
        {
          "Change Date",
          items = {
            { "1 Day Later", action = "shift_right", active = P.at_timestamp },
            { "1 Day Earlier", action = "shift_left", active = P.at_timestamp },
            { "1 ... Later", action = "shift_up", active = P.at_timestamp },
            { "1 ... Earlier", action = "shift_down", active = P.at_timestamp },
          },
        },
        { "Compute Time Range", action = "evaluate_time_range" },
        { "Schedule Item", action = "schedule", active = P.after_first_heading },
        { "Deadline", action = "deadline", active = P.after_first_heading },
        "--",
        { "Custom Time Format", action = "toggle_time_stamp_overlays" },
        "--",
        { "Go to Calendar", action = "goto_calendar" },
        { "Date from Calendar", action = "date_today" },
        "--",
        { "Start/Restart Timer", action = "timer_start" },
        { "Pause/Continue Timer", action = "timer_pause" },
        { "Stop Timer", action = "timer_stop" },
        { "Insert Timer String", action = "timer_insert" },
        { "Insert Timer Item", action = "timer_item" },
      },
    },
    {
      "Logging work",
      items = {
        e("Clock In", clock_in(nil)),
        e("Switch Task", clock_in(4)),
        { "Clock Out", action = "clock_out" },
        { "Clock Cancel", action = "clock_cancel" },
        "--",
        { "Mark as Default Task", action = "clock_mark_default_task" },
        e("Clock In, Mark as Default", clock_in(16)),
        { "Go to Running Clock", action = "clock_goto" },
        "--",
        { "Display Times", action = "clock_display" },
        { "Create Clock Table", action = "clock_report" },
        "--",
        {
          "Record DONE Time",
          fn = function()
            config.opts.log_done = not config.opts.log_done
            local file = require("org.files").get_buffer(0)
            local done = file and file.settings.todo.keywords or {}
            local first
            for _, kw in ipairs(done) do
              if kw.done then
                first = kw.name
                break
              end
            end
            utils.notify(
              string.format(
                "Switching to %s will %s record a timestamp",
                first or "DONE",
                config.opts.log_done and "automatically" or "not"
              )
            )
          end,
        },
      },
    },
    "--",
    { "Agenda Command...", action = "agenda" },
    { "Set Restriction Lock", action = "agenda_set_restriction_lock" },
    { "File List for Agenda", dynamic = agenda_files_menu },
    {
      "Special Views Current File",
      items = {
        { "TODO Tree", fn = todo_tree },
        {
          "Check Deadlines",
          fn = function()
            require("org.agenda.sparse").deadlines()
          end,
        },
        { "Tags/Property Tree", action = "tags_sparse_tree" },
      },
    },
    "--",
    { "Export/Publish...", action = "export" },
    {
      "LaTeX",
      -- CDLaTeX and RefTeX are Emacs packages: greyed out, as in an Emacs
      -- without them
      items = {
        greyed("Org CDLaTeX mode"),
        greyed("Insert Environment"),
        greyed("Insert Math Symbol"),
        greyed("Modify Math Symbol"),
        greyed("Insert Citation"),
      },
    },
    "--",
    {
      "Documentation",
      items = {
        { "Show Version", action = "version" },
        {
          "Show Org Manual",
          fn = function()
            vim.cmd("help org")
          end,
        },
        {
          "Browse Org News",
          fn = function()
            vim.ui.open("https://github.com/xheisenbugx/org.nvim/releases")
          end,
        },
      },
    },
    {
      "Customize",
      dynamic = function()
        if require("org.customize").menu_expanded then
          -- org-create-customize-menu
          return {
            { "Browse Org group", action = "customize" },
            "--",
            { "Org", items = require("org.customize").menu_items() },
          }
        end
        return {
          { "Browse Org Group", action = "customize" },
          "--",
          { "Expand This Menu", action = "customize_menu" },
        }
      end,
    },
    { "Send Bug Report", action = "bug_report" },
    "--",
    {
      "Restart/Reload",
      items = {
        {
          "Restart Org in Current Buffer",
          fn = function()
            -- org-mode-restart: set the mode up again
            local buf = vim.api.nvim_get_current_buf()
            vim.b[buf].org_attached = nil
            vim.b[buf].did_ftplugin = nil
            vim.bo[buf].filetype = "org"
            utils.notify("Org mode restarted")
          end,
        },
        "--",
        {
          "Reload Org",
          fn = function()
            -- org-reload: load the Lua modules again, with the options in
            -- effect; the state of a running clock would be lost
            if require("org.clock").active() then
              utils.warn("A clock is running: clock out before reloading Org")
              return
            end
            local opts = vim.deepcopy(config.opts)
            for name in pairs(package.loaded) do
              if name == "org" or name:match("^org%.") then
                package.loaded[name] = nil
              end
            end
            require("org").setup(opts)
            utils.notify("Successfully reloaded Org\n" .. require("org.version").string(true))
          end,
        },
      },
    },
  }
end

--- The first key of an action (for entries that run a function).
function M.key_or_nil(name)
  return require("org.menu").key_for(name) or false
end

---------------------------------------------------------------------------
-- org-tbl-menu
---------------------------------------------------------------------------

--- An entry active in a table.
local function T(label, spec)
  spec[1] = label
  spec.active = spec.active or P.at_table
  return spec
end

function M.table()
  return {
    T("Align", { action = "context_action" }),
    T("Next Field", { action = "table_next_field" }),
    T("Previous Field", { action = "table_prev_field" }),
    T("Next Row", { action = "table_next_row" }),
    "--",
    T("Blank Field", { action = "table_blank_field" }),
    T("Edit Field", { action = "table_edit_field" }),
    T("Copy Field from Above", { action = "table_copy_down" }),
    "--",
    {
      "Column",
      items = {
        T("Move Column Left", { action = "meta_left" }),
        T("Move Column Right", { action = "meta_right" }),
        T("Delete Column", { action = "shift_meta_left" }),
        T("Insert Column", { action = "shift_meta_right" }),
        T("Shrink Column", { action = "table_toggle_column_width" }),
      },
    },
    {
      "Row",
      items = {
        T("Move Row Up", { action = "meta_up" }),
        T("Move Row Down", { action = "meta_down" }),
        T("Delete Row", { action = "shift_meta_up" }),
        T("Insert Row", { action = "shift_meta_down" }),
        T("Sort Lines in Region", { action = "table_sort" }),
        "--",
        T("Insert Horizontal Line", { action = "ctrl_c_minus" }),
      },
    },
    {
      "Rectangle",
      items = {
        T("Copy Rectangle", { action = "copy_special", visual = true }),
        T("Cut Rectangle", { action = "cut_special", visual = true }),
        T("Paste Rectangle", { action = "paste_special" }),
        T("Fill Rectangle", { action = "table_wrap_region", visual = true }),
      },
    },
    "--",
    {
      "Calculate",
      items = {
        T("Set Column Formula", { action = "table_formula" }),
        T("Set Field Formula", { action = "table_formula", count = 4 }),
        T("Edit Formulas", { action = "edit_special" }),
        "--",
        T("Recalculate Line", { action = "table_recalculate" }),
        T("Recalculate All", { action = "table_recalculate", count = 4 }),
        T("Iterate All", { action = "table_recalculate", count = 16 }),
        "--",
        T("Toggle Recalculate Mark", { action = "table_rotate_marks" }),
        "--",
        T("Sum Column/Rectangle", {
          action = "table_sum",
          visual = true,
          active = function()
            return P.at_table() or P.region()
          end,
        }),
        T("Which Column?", { fn = M.which_column }),
      },
    },
    { "Debug Formulas", action = "table_formula_debugger" },
    { "Show Column/Row Numbers", action = "table_coordinates" },
    "--",
    { "Create", action = "table_create", active = P.not_at_table },
    {
      "Convert Region",
      action = "table_create",
      visual = true,
      active = function()
        return not P.at_any_table()
      end,
    },
    { "Import from File", action = "table_import", active = P.not_at_table },
    T("Export to File", { action = "table_export" }),
    "--",
    { "Create/Convert 'table.el' Table", action = "table_el" },
    "--",
    {
      "Plot",
      items = {
        T("ASCII Plot", { action = "table_ascii_plot" }),
        T("Gnuplot Plot", { action = "table_plot" }),
      },
    },
  }
end

--- org-table-current-column: the column of the cursor (0 before the
--- first "|").
function M.which_column()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = line:sub(1, col)
  local n = 0
  if before:find("|", 1, true) then
    local sep = line:match("^%s*|%-") and "[+|]" or "|"
    for _ in before:gmatch(sep) do
      n = n + 1
    end
  end
  utils.notify(string.format("Column %d", n))
  return n
end

---------------------------------------------------------------------------
-- org-agenda-menu
---------------------------------------------------------------------------

local function A(label, name, spec)
  spec = spec or {}
  spec[1], spec.agenda = label, name
  return spec
end

local function AA(label, name)
  return A(label, name, { active = P.agenda_view })
end

--- An entry acting on the agenda item (org-agenda-* commands that are
--- not agenda keys here).
local function on_item(label, fn)
  return {
    label,
    fn = function()
      require("org.agenda.view").on_item(fn)()
    end,
  }
end

function M.agenda()
  return {
    {
      "Agenda Files",
      dynamic = function()
        local restricted = require("org.agenda").lock ~= nil
        return vim.list_extend({
          {
            restricted and "Restricted to Single File" or "Edit File List",
            action = "edit_agenda_file_list",
            active = function()
              return not restricted
            end,
          },
          "--",
        }, file_entries())
      end,
    },
    "--",
    {
      "Agenda Dates",
      items = {
        AA("Goto Today", "today"),
        AA("Next Dates", "later"),
        AA("Previous Dates", "earlier"),
        AA("Jump to date", "goto_date"),
      },
    },
    "--",
    {
      "View",
      items = {
        AA("Day View", "day_view"),
        AA("Week View", "week_view"),
        AA("Fortnight View", "fortnight_view"),
        AA("Month View", "month_view"),
        AA("Year View", "year_view"),
        "--",
        AA("Include Diary", "toggle_diary"),
        AA("Include Deadlines", "toggle_deadlines"),
        AA("Use Time Grid", "time_grid"),
        "--",
        AA("Show clock report", "clockreport_mode"),
        A("Show some entry text", "entry_text_mode"),
        "--",
        AA("Show Logbook entries", "log_mode"),
        A("Include archived trees", "archives_mode"),
        A("Include archive files", "archives_files_mode"),
        "--",
        A("Remove Restriction", "remove_restriction_lock", {
          active = function()
            return require("org.agenda").lock ~= nil
          end,
        }),
      },
    },
    {
      "Filter current view",
      items = {
        A("with generic interface", "filter"),
        "--",
        A("by category at cursor", "filter_category"),
        A("by tag", "filter_tag"),
        A("by effort", "filter_effort"),
        A("by regexp", "filter_regexp"),
        A("by top-level headline", "filter_top_headline"),
        "--",
        A("Remove all filtering", "filter_remove"),
        "--",
        A("limit", "limit"),
      },
    },
    A("Rebuild buffer", "redo"),
    A("Write view to file", "export"),
    A("Save all Org buffers", "save_all"),
    "--",
    A("Show original entry", "show"),
    A("Go To (other window)", "goto"),
    A("Go To (this window)", "switch_to"),
    A("Capture with cursor date", "capture"),
    A("Follow Mode", "follow_mode"),
    "--",
    {
      "TODO",
      items = {
        A("Cycle TODO", "todo"),
        on_item("Next TODO set", function(target)
          require("org.todo").next_sequence(target, 1)
        end),
        on_item("Previous TODO set", function(target)
          require("org.todo").next_sequence(target, -1)
        end),
        A("Add note", "add_note"),
      },
    },
    {
      "Archive/Refile/Delete",
      items = {
        A("Archive default", "archive_default"),
        -- Emacs names both entries "Archive default"; a menu path is unique
        A("Archive default ", "archive_default_confirm"),
        A("Toggle ARCHIVE tag", "toggle_archive_tag"),
        A("Move to archive sibling", "archive_sibling"),
        A("Archive subtree", "archive"),
        "--",
        A("Refile", "refile"),
        "--",
        A("Delete subtree", "kill"),
      },
    },
    {
      "Bulk action",
      items = {
        A("Mark entry", "mark"),
        A("Mark all", "mark_all"),
        A("Unmark entry", "unmark"),
        A("Unmark all", "unmark_all"),
        A("Toggle mark", "toggle_mark"),
        A("Toggle all", "toggle_mark_all"),
        A("Mark regexp", "mark_regexp"),
      },
    },
    A("Act on all marked", "bulk_action"),
    "--",
    {
      "Tags and Properties",
      items = {
        A("Show all Tags", "show_tags"),
        A("Set Tags current line", "set_tags", {
          active = function()
            return not P.region()
          end,
        }),
        A("Change tag in region", "set_tags", { visual = true, active = P.region }),
        "--",
        A("Column View", "columns"),
      },
    },
    {
      "Deadline/Schedule",
      items = {
        A("Schedule", "schedule"),
        A("Set Deadline", "deadline"),
        "--",
        AA("Change Date +1 day", "date_later"),
        AA("Change Date -1 day", "date_earlier"),
        AA("Change Time +1 hour", "date_later_hours"),
        AA("Change Time -1 hour", "date_earlier_hours"),
        AA("Change Time +  min", "date_later_minutes"),
        AA("Change Time -  min", "date_earlier_minutes"),
        AA("Change Date to ...", "date_prompt"),
      },
    },
    {
      "Clock and Effort",
      items = {
        A("Clock in", "clock_in"),
        A("Clock out", "clock_out"),
        A("Clock cancel", "clock_cancel"),
        A("Goto running clock", "clock_goto"),
        "--",
        A("Set Effort", "set_effort"),
        {
          "Change clocked effort",
          action = "clock_modify_effort",
          active = function()
            return require("org.clock").active() and true or false
          end,
        },
      },
    },
    {
      "Priority",
      items = {
        A("Set Priority", "priority"),
        A("Increase Priority", "priority_up"),
        A("Decrease Priority", "priority_down"),
        on_item("Show Priority", function(target)
          require("org.priority").show(target)
        end),
      },
    },
    {
      "Calendar/Diary",
      items = {
        AA("New Diary Entry", "diary_entry"),
        AA("Goto Calendar", "calendar"),
        AA("Phases of the Moon", "phases_of_moon"),
        AA("Sunrise/Sunset", "sunrise_sunset"),
        AA("Holidays", "holidays"),
        AA("Convert", "convert_date"),
        "--",
        {
          "Create iCalendar File",
          fn = function()
            require("org.export.icalendar").combine_agenda_files({})
          end,
        },
      },
    },
    "--",
    A("Undo Remote Editing", "undo", {
      active = function()
        return #require("org.agenda.view").undo_list > 0
      end,
    }),
    "--",
    {
      "MobileOrg",
      items = {
        A("Push Files and Views", "mobile_push"),
        A("Get Captured and Flagged", "mobile_pull"),
        {
          "Find FLAGGED Tasks",
          fn = function()
            require("org.agenda").command("?")
          end,
        },
        A("Show note / unflag", "show_flagging_note"),
        "--",
        { "Setup", fn = customize({ "mobile" }) },
      },
    },
    "--",
    A("Quit", "quit"),
    A("Exit and Release Buffers", "exit"),
  }
end

---------------------------------------------------------------------------
-- org-columns-menu (the view's own keys)
---------------------------------------------------------------------------

local function overlay_view()
  return vim.bo.filetype ~= "orgcolumns"
end

function M.columns()
  local function K(label, keys, spec)
    spec = spec or {}
    spec[1], spec.keys = label, keys
    return spec
  end
  return {
    K("Edit property", "e"),
    K("Next allowed value", "n"),
    K("Previous allowed value", "p"),
    K("Show full value", "v"),
    K("Edit allowed values", "a"),
    "--",
    K("Edit column attributes", "s"),
    K("Increase column width", ">"),
    K("Decrease column width", "<"),
    "--",
    K("Move column right", "<M-Right>"),
    K("Move column left", "<M-Left>"),
    K("Move row up", "<M-Up>"),
    K("Move row down", "<M-Down>"),
    K("Add column", "<M-S-Right>"),
    K("Delete column", "<M-S-Left>"),
    "--",
    K("CONTENTS", "c", { active = overlay_view }),
    K("OVERVIEW", "o", { active = overlay_view }),
    K("Refresh columns display", "r"),
    "--",
    K("Open link", "<C-c><C-o>"),
    "--",
    K("Quit", "q"),
  }
end

---------------------------------------------------------------------------
-- org-table-fedit-menu (the formula editor's keys)
---------------------------------------------------------------------------

function M.fedit()
  local function K(label, keys, spec)
    spec = spec or {}
    spec[1], spec.keys = label, keys
    return spec
  end
  return {
    K("Finish and Install", "<C-c><C-c>"),
    K("Finish, Install, and Apply", "<C-c><C-c>", { count = 4 }),
    K("Abort", "<C-c><C-q>"),
    "--",
    K("Pretty-Print Lisp Formula", "<Tab>"),
    K("Complete Lisp Symbol", "a<C-x><C-o>", {
      hint = false,
      active = function()
        return vim.bo.omnifunc ~= ""
      end,
    }),
    "--",
    { "Shift Reference at Point", title = true },
    K("Up", "<S-Up>"),
    K("Down", "<S-Down>"),
    K("Left", "<S-Left>"),
    K("Right", "<S-Right>"),
    "-",
    { "Change Test Row for Column Formulas", title = true },
    -- two entries named Up and Down: the second pair is set apart
    K("Up ", "<M-S-Up>"),
    K("Down ", "<M-S-Down>"),
    "--",
    K("Scroll Table Window", "<M-Down>"),
    K("Scroll Table Window down", "<M-Up>"),
    K("Show Table Grid", "<C-c>}"),
    "--",
    K("Standard Refs (B3 instead of @3$2)", "<C-c><C-r>"),
  }
end

---------------------------------------------------------------------------
-- orgtbl-mode-menu (buffers of any filetype)
---------------------------------------------------------------------------

function M.orgtbl()
  local function t()
    return require("org.table")
  end
  local function F(label, fn, spec)
    spec = spec or {}
    spec[1], spec.fn, spec.hint = label, fn, spec.hint or false
    spec.active = spec.active or P.at_table
    return spec
  end
  local function call(name, ...)
    local args = { ... }
    return function()
      return t()[name](unpack(args))
    end
  end
  return {
    F("Create or convert", call("create_or_convert"), { visual = true, active = P.not_at_table, hint = "<C-c>|" }),
    "--",
    F("Align", function()
      require("org.table.orgtbl").ctrl_c_ctrl_c()
    end, { hint = "<C-c><C-c>" }),
    F("Next Field", call("next_field"), { hint = "<Tab>" }),
    F("Previous Field", call("prev_field"), { hint = "<S-Tab>" }),
    F("Next Row", call("next_row"), { hint = "<CR>" }),
    "--",
    F("Blank Field", call("blank_field"), { visual = true, hint = "<C-c><Space>" }),
    F("Edit Field", call("edit_field"), { hint = "<C-c>`" }),
    F("Copy Field from Above", call("copy_down"), { hint = "<S-CR>" }),
    "--",
    {
      "Column",
      items = {
        F("Move Column Left", call("move_column", -1), { hint = "<M-Left>" }),
        F("Move Column Right", call("move_column", 1), { hint = "<M-Right>" }),
        F("Delete Column", call("delete_column"), { hint = "<M-S-Left>" }),
        F("Insert Column", call("insert_column"), { hint = "<M-S-Right>" }),
      },
    },
    {
      "Row",
      items = {
        F("Move Row Up", call("move_row", -1), { hint = "<M-Up>" }),
        F("Move Row Down", call("move_row", 1), { hint = "<M-Down>" }),
        F("Delete Row", call("delete_row"), { hint = "<M-S-Up>" }),
        F("Insert Row", call("insert_row", true), { hint = "<M-S-Down>" }),
        F("Sort lines in region", call("sort_column"), { hint = "<C-c>^" }),
        "--",
        F("Insert Hline", call("insert_hline", false), { hint = "<C-c>-" }),
      },
    },
    {
      "Rectangle",
      items = {
        F("Copy Rectangle", call("copy_region"), { visual = true }),
        F("Cut Rectangle", call("cut_region"), { visual = true }),
        F("Paste Rectangle", call("paste_rectangle")),
        F("Fill Rectangle", call("wrap_region"), { visual = true }),
      },
    },
    "--",
    {
      "Radio tables",
      items = {
        {
          "Insert table template",
          fn = function()
            require("org.table.orgtbl").insert_radio_table()
          end,
          active = function()
            return (config.opts.orgtbl_radio_table_templates or {})[vim.bo.filetype] ~= nil
          end,
        },
        {
          "Comment/uncomment table",
          fn = function()
            require("org.table.orgtbl").toggle_comment()
          end,
        },
      },
    },
    "--",
    F("Set Column Formula", call("eval_formula"), { hint = "<C-c>=" }),
    F("Set Field Formula", call("eval_formula", true), { hint = "4<C-c>=" }),
    F("Edit Formulas", call("edit_formulas"), { hint = "<C-c>'" }),
    F("Recalculate line", call("recalculate", 0), { hint = "<C-c>*" }),
    F("Recalculate all", call("recalculate", 4), { hint = "4<C-c>*" }),
    F("Iterate all", call("recalculate", 16), { hint = "16<C-c>*" }),
    F("Toggle Recalculate Mark", call("rotate_recalc_marks"), { hint = "<C-#>" }),
    F("Sum Column/Rectangle", call("sum"), {
      visual = true,
      hint = "<C-c>+",
      active = function()
        return P.at_table() or P.region()
      end,
    }),
    F("Which Column?", M.which_column, { hint = "<C-c>?" }),
    F("Debug Formulas", call("toggle_formula_debugger"), { hint = "<C-c>{" }),
    F("Show Col/Row Numbers", call("toggle_coordinate_overlays"), { hint = "<C-c>}" }),
    "--",
    {
      "Plot",
      items = {
        F("Ascii plot", function()
          require("org.table.plot").ascii_plot()
        end),
        F("Gnuplot", function()
          require("org.table.plot").gnuplot()
        end),
      },
    },
  }
end

return M
