---@mod org.config Configuration
---
--- All options live in `require('org.config').opts`. The table is mutated in
--- place by `setup()`, so modules must read options at call time
--- (`require('org.config').opts.foo`) instead of caching sub-tables.

local M = {}

local data_dir = vim.fn.stdpath("data") .. "/org"

--- Default options. The user-facing option types and docs live in
--- `lua/org/_meta/` (class `org.Config`, every field optional) so that
--- `require("org").setup({...})` gets completion and hover docs. Internal
--- code reads `M.opts`, typed from this table, where every option is set.
---@class org.config.Resolved
M.defaults = {
  --- Base directory for org files. Used to resolve relative paths.
  org_directory = "~/org",
  --- Files scanned by the agenda, refile and id lookups (org-agenda-files).
  --- A directory adds its `*.org` files (not recursively, names not starting
  --- with a dot, like org-agenda-file-regexp); a string naming a non-org
  --- file reads the list from that file, one per line. Glob patterns such
  --- as `~/org/**/*.org` are an extension.
  agenda_files = {},
  --- Default target for capture templates without a `target`
  --- (org-default-notes-file).
  default_notes_file = "~/.notes",

  ---------------------------------------------------------------------------
  -- TODO keywords & logging
  ---------------------------------------------------------------------------
  --- Each string is a sequence, exactly like Emacs `org-todo-keywords`.
  --- `(k)` is a fast-selection key, `!` logs a timestamp, `@` asks for a note.
  --- A flat list containing a `"|"` element is also accepted.
  todo_keywords = { "TODO | DONE" },
  --- State a repeating task returns to: nil = first keyword of its sequence,
  --- true = the state it had before, or a keyword. The REPEAT_TO_STATE
  --- property overrides it.
  todo_repeat_to_state = nil,
  --- Tag changes on TODO state changes (org-todo-state-tags-triggers). Keys
  --- are keywords, `"todo"`, `"done"` or `""` (no keyword); values map tags
  --- to true (add) / false (remove):
  --- `{ CANCELLED = { CANCELLED = true }, done = { WAITING = false } }`.
  todo_state_tags_triggers = {},
  --- Block marking an entry DONE while children are not DONE.
  enforce_todo_dependencies = false,
  --- Block marking an entry DONE while it has unchecked checkboxes.
  enforce_todo_checkbox_dependencies = false,
  --- Functions that can block a TODO state change (org-blocker-hook). Each
  --- receives `{ type = "todo-state-change", from, to, bufnr, lnum }` and
  --- blocks the change by returning `false`.
  todo_blockers = {},
  --- C-c C-t uses the fast-selection menu when keywords have keys
  --- (org-use-fast-todo-selection `auto`); `false` always cycles.
  use_fast_todo_selection = "auto",
  --- Which child headlines statistics cookies count
  --- (org-provide-todo-statistics): `true` (entries with a TODO keyword),
  --- `"all-headlines"`, a list of keywords, or `{ todo_list, done_list }`.
  --- `false` stops updating cookies on state changes.
  provide_todo_statistics = true,
  --- Statistics cookies count direct children only; `false` counts the
  --- whole subtree (org-hierarchical-todo-statistics).
  hierarchical_todo_statistics = true,
  --- Keep CLOSED when the TODO keyword is removed
  --- (org-closed-keep-when-no-todo).
  closed_keep_when_no_todo = false,
  --- `false`, `"time"` (add CLOSED:) or `"note"` (CLOSED: + note).
  log_done = false,
  --- Logging when a repeated task is marked done: false | "time" | "note".
  log_repeat = "time",
  --- Log changes of SCHEDULED / DEADLINE: false | "time" | "note".
  log_reschedule = false,
  log_redeadline = false,
  --- Ask for a note when clocking out (org-log-note-clock-out).
  log_note_clock_out = false,
  --- Drawer used for state changes, notes and clocks. `false` = no drawer.
  log_into_drawer = false,
  --- Newest log entries first (Emacs default).
  log_states_order_reversed = true,
  --- Log notes are typed in a small `*Org Note*` split (<C-c><C-c> stores,
  --- <C-c><C-k> cancels) like Emacs org-add-log-note; `false` asks with a
  --- one-line prompt.
  note_buffer = true,
  --- Headings of log notes (org-log-note-headings). `%t` inactive
  --- timestamp, `%T` active, `%d`/`%D` date only, `%s` new state, `%S` old
  --- state or date (both quoted), `%u`/`%U` user name.
  log_note_headings = {
    done = "CLOSING NOTE %t",
    state = "State %-12s from %-12S %t",
    note = "Note taken on %t",
    reschedule = "Rescheduled from %S on %t",
    delschedule = "Not scheduled, was %S on %t",
    redeadline = "New deadline from %S on %t",
    deldeadline = "Removed deadline, was %S on %t",
    refile = "Refiled on %t",
    ["clock-out"] = "",
  },
  --- Hours after midnight that still belong to the previous day for
  --- "today" in the agenda and date prompts (org-extend-today-until).
  extend_today_until = 0,
  --- With `extend_today_until`, record CLOSED and log times before that
  --- hour as 23:59 of the previous day (org-use-effective-time).
  use_effective_time = false,
  --- In Visual mode, C-c C-t, C-c C-s and C-c C-d act on every headline of
  --- the selection: `true`, `"start-level"` (only headlines of the first
  --- one's level) or `false` (org-loop-over-headlines-in-active-region).
  loop_over_headlines_in_active_region = true,

  ---------------------------------------------------------------------------
  -- Priorities & tags
  ---------------------------------------------------------------------------
  priority_highest = "A",
  priority_lowest = "C",
  priority_default = "B",
  --- Tag groups (`[ GTD : Control Persp ]` in #+TAGS / `tags`) also match
  --- their members in tag searches (org-group-tags); toggled by
  --- `toggle_tags_groups`.
  group_tags = true,
  --- Fast tag selection exits after one key (org-fast-tag-selection-single-key):
  --- `false`, `true`, or `"expert"` (no menu window).
  fast_tag_selection_single_key = false,
  --- Show the TODO keywords with fast keys in the fast tag selection menu
  --- (org-fast-tag-selection-include-todo).
  fast_tag_selection_include_todo = false,
  --- Tag completion offers the tags of every agenda file instead of the
  --- current buffer's (org-complete-tags-always-offer-all-agenda-tags).
  complete_tags_always_offer_all_agenda_tags = false,
  --- Global tag list offered for completion. Strings may contain fast keys,
  --- e.g. `"work(w)"`, and `"{" ... "}"` for mutually exclusive groups.
  tags = {},
  --- Column tags are aligned to. Negative = right-align to that column.
  tags_column = -77,
  --- Tag inheritance (org-use-tag-inheritance): true, false, a list of the
  --- tags that inherit, or a regexp matching them.
  use_tag_inheritance = true,
  --- Tags that never inherit (org-tags-exclude-from-inheritance).
  tags_exclude_from_inheritance = {},
  --- Property inheritance (org-use-property-inheritance): true, false, a
  --- list of property names, or a regexp matching them (ignoring case).
  use_property_inheritance = false,
  --- Format of `:NAME: value` lines in property drawers (org-property-format).
  property_format = "%-10s %s",
  --- Properties that apply to every entry (e.g. `Effort_ALL`).
  global_properties = {},
  --- Constants for table formulas (`$name`), like `org-table-formula-constants`.
  --- `#+CONSTANTS:` lines in a file take precedence.
  table_formula_constants = {},
  --- S-RET (table_copy_down) increments numbers and dates: true (by the
  --- difference to the field above, else 1), a number (fixed step) or false.
  table_copy_increment = true,
  --- A field formula (or C-c =) writing beyond the last column: false
  --- (error), true (add columns), "warn" (add and warn) or "prompt"
  --- (org-table-formula-create-columns). Column formulas always add them.
  table_formula_create_columns = false,
  --- Ask before rewriting #+TBLFM references after inserting, deleting or
  --- moving rows and columns (org-table-fix-formulas-confirm).
  table_fix_formulas_confirm = false,
  --- Output of the `t` formula flag: "hours", "minutes", "seconds" or
  --- "days" (org-table-duration-custom-format).
  table_duration_custom_format = "hours",
  --- Pad hours to two digits in `T` / `U` durations, `01:30:00`
  --- (org-table-duration-hour-zero-padding).
  table_duration_hour_zero_padding = true,
  --- Typing `=formula` / `:=formula` into a field installs it
  --- (org-table-formula-evaluate-inline).
  table_formula_evaluate_inline = true,
  --- Minimum fraction of numbers in a column for right alignment
  --- (org-table-number-fraction).
  table_number_fraction = 0.5,
  --- Text shown at the end of a shrunk column (org-table-shrunk-column-indicator).
  table_shrunk_column_indicator = "…",
  --- Shrink the columns with a width cookie of every table when a file is
  --- opened; `#+STARTUP: shrink` / `noshrink` (org-startup-shrink-all-tables).
  startup_shrink_all_tables = false,
  --- Keep the first table row visible in the winbar when it scrolls out of
  --- view (org-table-header-line-p).
  table_header_line_p = false,
  --- Leaving the table ends follow-field mode
  --- (org-table-exit-follow-field-mode-when-leaving-table).
  table_exit_follow_field_mode_when_leaving_table = true,
  --- A1-style references (B3) in formulas: "from" accepts them when typed,
  --- true also shows them in the formula editor, false never
  --- (org-table-use-standard-references).
  table_use_standard_references = "from",
  --- Format of `table_export` without TABLE_EXPORT_FORMAT: a translator
  --- name like "orgtbl-to-csv" (org-table-export-default-format).
  table_export_default_format = "orgtbl-to-tsv",
  --- The gnuplot program for `table_plot` (gnuplot-program).
  plot_gnuplot_program = "gnuplot",
  --- Text added to every plot script (org-plot/gnuplot-script-preamble).
  plot_gnuplot_script_preamble = "",
  --- Extra `set term` options, e.g. "size 1050,650"
  --- (org-plot/gnuplot-term-extra).
  plot_gnuplot_term_extra = "",
  --- Radio table templates inserted by `orgtbl_insert_radio_table`, per
  --- filetype; `%n` is the table name (orgtbl-radio-table-templates).
  orgtbl_radio_table_templates = {
    tex = "% BEGIN RECEIVE ORGTBL %n\n% END RECEIVE ORGTBL %n\n\\begin{comment}\n"
      .. "#+ORGTBL: SEND %n orgtbl-to-latex :splice nil :skip 0\n| | |\n\\end{comment}\n",
    texinfo = "@c BEGIN RECEIVE ORGTBL %n\n@c END RECEIVE ORGTBL %n\n@ignore\n"
      .. "#+ORGTBL: SEND %n orgtbl-to-html :splice nil :skip 0\n| | |\n@end ignore\n",
    html = "<!-- BEGIN RECEIVE ORGTBL %n -->\n<!-- END RECEIVE ORGTBL %n -->\n<!--\n"
      .. "#+ORGTBL: SEND %n orgtbl-to-html :splice nil :skip 0\n| | |\n-->\n",
    org = "#+ BEGIN RECEIVE ORGTBL %n\n#+ END RECEIVE ORGTBL %n\n\n"
      .. "#+ORGTBL: SEND %n orgtbl-to-orgtbl :splice nil :skip 0\n| | |\n",
  },
  --- Extra summary operators for column view: a map from the operator to
  --- `fun(values: string[], format?: string): string`, e.g.
  --- `{ ["+|"] = function(v) ... end }` (org-columns-summary-types).
  columns_summary_types = {},
  --- `fun(prop: string, value: string): string?` changing values shown in
  --- column view and columnview blocks
  --- (org-columns-modify-value-for-display-function).
  columns_modify_value_for_display_function = nil,
  --- `fun(rows: table, params: table): string[]` writing a columnview
  --- dynamic block instead of the default table, or nil; a block's
  --- `:formatter` names a global Lua function (org-columns-dblock-formatter).
  columns_dblock_formatter = nil,
  --- Values <S-Right> cycles through for checkbox columns
  --- (org-columns-checkbox-allowed-values).
  columns_checkbox_allowed_values = { "[ ]", "[X]" },
  effort_property = "Effort",
  --- Durations in clock tables, clock sums and efforts: "d h:mm" writes
  --- "1d 2:30" from one day on (Emacs `org-duration-format`), "h:mm" "26:30".
  duration_format = "d h:mm",
  columns_default_format = "%25ITEM %TODO %3PRIORITY %TAGS",

  ---------------------------------------------------------------------------
  -- Buffer behaviour
  ---------------------------------------------------------------------------
  --- "overview" | "content" | "showall" | "showeverything" | "nofold"
  --- | "show2levels" .. "show5levels" (org-startup-folded)
  startup_folded = "showeverything",
  --- Fold drawers when the file is opened (org-hide-drawer-startup;
  --- #+STARTUP: hidedrawers / nohidedrawers).
  hide_drawer_startup = true,
  --- Fold `#+begin_...` blocks when the file is opened (org-hide-block-startup;
  --- #+STARTUP: hideblocks).
  hide_block_startup = false,
  --- Let visibility cycling open subtrees tagged :ARCHIVE:
  --- (org-cycle-open-archived-trees).
  cycle_open_archived_trees = false,
  --- Heading that collects footnote definitions (created when missing)
  --- (org-footnote-section; #+STARTUP: fnlocal).
  --- false = put each definition at the end of the reference's section.
  footnote_section = "Footnotes",
  --- Indent body text to the headline level (org-adapt-indentation).
  adapt_indentation = false,
  --- Indentation added to src block contents in the edit buffer
  --- (org-src-content-indentation).
  edit_src_content_indentation = 2,
  --- Keep the indentation of src block lines as written: no common
  --- indentation is removed for evaluation, tangling or editing
  --- (org-src-preserve-indentation). The `-i` switch does it per block.
  src_preserve_indentation = false,
  --- Text appended to folded headlines (org-ellipsis).
  ellipsis = "...",
  --- Blank line handling before new headlines and list items: true | false |
  --- "auto" (org-blank-before-new-entry).
  blank_before_new_entry = { heading = "auto", plain_list_item = "auto" },
  --- M-RET in Insert mode splits the line at the cursor
  --- (org-M-RET-may-split-line): true, false, or per context
  --- `{ headline = false, item = true, default = true }`.
  meta_return_split_line = true,
  --- Clones made by clone_subtree lose their ID instead of getting a new
  --- one (org-clone-delete-id).
  clone_delete_id = false,
  --- Only odd levels: promotion and demotion add or remove two stars
  --- (org-odd-levels-only; #+STARTUP: odd / oddeven).
  odd_levels_only = false,
  --- Named key functions for sorting by function (`f` in sort), called
  --- with the headline (or list item) and its lines:
  --- `{ by_length = function(h, lines) return #lines end }`.
  sort_functions = {},
  --- TAB on a list item folds its children and text
  --- (org-cycle-include-plain-lists).
  cycle_include_plain_lists = true,
  --- Where TAB outside headlines, items, drawers and blocks indents the
  --- line (org-cycle-emulate-tab): true (everywhere), "white" (blank
  --- lines only), "whitestart" (before the first non-blank character),
  --- "exc-hl-bol" (everywhere except at the start of a headline) or false.
  cycle_emulate_tab = true,
  --- Blank lines needed at the end of a subtree for one of them to stay
  --- visible when it is folded (org-cycle-separator-lines).
  cycle_separator_lines = 2,
  --- Edits inside folded text: false (allow), "error", "show" (unfold
  --- first), "show-and-error" or "smart" (unfold, and refuse edits in
  --- text that was hidden) (org-fold-catch-invisible-edits).
  catch_invisible_edits = "smart",
  --- Single-letter commands at the start of a headline
  --- (org-use-speed-commands). See `:h org-speed-commands`.
  use_speed_commands = false,
  --- Extra or changed speed commands: `{ key = action name | function | false }`.
  speed_commands = {},
  --- Headlines of this level or deeper are inline tasks
  --- (org-inlinetask-min-level). false turns inline tasks off, like Emacs
  --- without the org-inlinetask module; Emacs uses 15 once it is loaded.
  inlinetask_min_level = false,
  --- TODO keyword of new inline tasks (org-inlinetask-default-state).
  inlinetask_default_state = nil,
  --- Block types offered by insert_structure_template, by key
  --- (org-structure-template-alist). `false` removes one.
  structure_template_alist = {
    a = "export ascii",
    c = "center",
    C = "comment",
    e = "example",
    E = "export",
    h = "export html",
    l = "export latex",
    q = "quote",
    s = "src",
    v = "verse",
  },
  --- Expand `<s` + TAB (Insert mode) into a block and `<L` + TAB into a
  --- `#+latex: ` keyword (the org-tempo module, off by default like in
  --- Emacs). Blocks come from `structure_template_alist`.
  tempo = false,
  --- Keywords for tempo expansion (org-tempo-keywords-alist).
  tempo_keywords = { L = "latex", H = "html", A = "ascii", i = "index" },
  --- Labels of new footnotes (org-footnote-auto-label): true (fn:N),
  --- false (prompt), "confirm" (prompt with fn:N as default), "random" or
  --- "plain" (like true), "anonymous" (`[fn:: text]`). #+STARTUP: fnauto,
  --- fnprompt, fnconfirm, fnplain, fnanon; fnlocal sets footnote_section = false.
  footnote_auto_label = true,
  --- Renumber and / or sort footnotes after inserting or deleting one
  --- (org-footnote-auto-adjust): false, true, "sort" or "renumber".
  --- #+STARTUP: fnadjust / nofnadjust.
  footnote_auto_adjust = false,
  --- Define new footnotes inline, `[fn:N: text]` at the reference
  --- (org-footnote-define-inline). #+STARTUP: fninline / nofninline.
  footnote_define_inline = false,
  --- Days before a deadline it starts showing up in the agenda.
  deadline_warning_days = 14,
  --- { rounding of the current time in date prompts, minute step of
  --- <S-Up>/<S-Down> } (org-time-stamp-rounding-minutes). A count steps by
  --- exactly that many minutes.
  time_stamp_rounding_minutes = { 0, 5 },
  --- Date prompts interpret incomplete dates in the future: `true` (a past
  --- day/month means next month/year), `"time"` (also a past time today
  --- means tomorrow) or `false` (org-read-date-prefer-future).
  read_date_prefer_future = true,
  --- Display timestamps with `time_stamp_custom_formats` (strftime
  --- formats for dates and date+time, without brackets); toggled by
  --- `toggle_time_stamp_overlays` (org-display-custom-times,
  --- org-timestamp-custom-formats).
  display_custom_times = false,
  time_stamp_custom_formats = { "%m/%d/%y %a", "%m/%d/%y %a %H:%M" },
  --- Where `archive_subtree` sends entries. `%s` = current file name
  --- (org-archive-location).
  archive_location = "%s_archive::",
  --- Context saved as ARCHIVE_* properties (org-archive-save-context-info):
  --- "time", "file", "olpath", "olid", "category", "todo", "itags", "ltags".
  archive_save_context_info = { "time", "file", "olpath", "category", "todo", "itags" },
  --- Heading of the sibling used by `archive_to_sibling` (org-archive-sibling-heading).
  archive_sibling_heading = "Archive",
  --- Add inherited tags to archived entries: "infile" | true | false
  --- (org-archive-subtree-add-inherited-tags).
  archive_subtree_add_inherited_tags = "infile",
  --- Archive as the first child of the archive heading instead of the last
  --- (org-archive-reversed-order).
  archive_reversed_order = false,
  --- Mark archived entries done: false | true (first done keyword) | a done
  --- keyword (org-archive-mark-done).
  archive_mark_done = false,
  --- Text put at the top of a new archive file, `%s` = the source file;
  --- false for none (org-archive-file-header-format).
  archive_file_header_format = "\nArchived entries from file %s\n\n",
  --- Window used for special buffers: "float" | "split" | "vsplit" | "tab" | "current"
  win_split_mode = "float",
  win_border = "rounded",

  ---------------------------------------------------------------------------
  -- Agenda
  ---------------------------------------------------------------------------
  agenda = {
    --- Span of the agenda view (org-agenda-span): "day" | "week" |
    --- "fortnight" | "month" | "year" | number of days.
    span = "week",
    --- Weekday 7 and 14 day spans start on, 1 = Monday; false = today
    --- (org-agenda-start-on-weekday).
    start_on_weekday = 1,
    --- First day as an offset like "-3d" or a date (org-agenda-start-day).
    start_day = nil,
    --- Kinds of dated entries collected (org-agenda-entry-types):
    --- "deadline", "scheduled", "timestamp", "sexp", and "deadline*" /
    --- "scheduled*" for timed ones only.
    entry_types = { "deadline", "scheduled", "timestamp", "sexp" },
    --- Include deadlines in the agenda (org-agenda-include-deadlines).
    include_deadlines = true,
    skip_scheduled_if_done = false, -- org-agenda-skip-scheduled-if-done
    skip_deadline_if_done = false, -- org-agenda-skip-deadline-if-done
    skip_timestamp_if_done = false, -- org-agenda-skip-timestamp-if-done
    --- true | "not-today" (org-agenda-skip-scheduled-if-deadline-is-shown).
    skip_scheduled_if_deadline_is_shown = false,
    skip_timestamp_if_deadline_is_shown = false, -- org-agenda-skip-timestamp-if-deadline-is-shown
    skip_scheduled_repeats_after_deadline = false, -- org-agenda-skip-scheduled-repeats-after-deadline
    skip_additional_timestamps_same_entry = false, -- org-agenda-skip-additional-timestamps-same-entry
    --- true (no pre-warning when scheduled) | number of days | "pre-scheduled"
    --- (org-agenda-skip-deadline-prewarning-if-scheduled).
    skip_deadline_prewarning_if_scheduled = false,
    --- true | number | "post-deadline" (org-agenda-skip-scheduled-delay-if-deadline).
    skip_scheduled_delay_if_deadline = false,
    --- Days an overdue deadline / past scheduled entry keeps being shown
    --- (org-deadline-past-days, org-scheduled-past-days).
    deadline_past_days = 10000,
    scheduled_past_days = 10000,
    --- Show the last repeat instead of the base date: true or a list of
    --- TODO keywords (org-agenda-prefer-last-repeat).
    prefer_last_repeat = false,
    show_future_repeats = true, -- true | false | "next" (org-agenda-show-future-repeats)
    --- Show days without entries (org-agenda-show-all-dates).
    show_all_dates = true,
    --- false | "all" | "future" | "past" | days (org-agenda-todo-ignore-scheduled).
    todo_ignore_scheduled = false,
    --- false | true (= "near") | "near" | "far" | "all" | "future" | "past" | days
    --- (org-agenda-todo-ignore-deadlines).
    todo_ignore_deadlines = false,
    --- false | true | "future" | "past" | days (org-agenda-todo-ignore-timestamp).
    todo_ignore_timestamp = false,
    todo_ignore_with_date = false, -- org-agenda-todo-ignore-with-date
    --- Apply the todo_ignore_* options to tags-todo (M) views too
    --- (org-agenda-tags-todo-honor-ignore-options).
    tags_todo_honor_ignore_options = false,
    --- List TODO children of TODO entries (org-agenda-todo-list-sublevels).
    todo_list_sublevels = true,
    --- List matching children of matching entries (org-tags-match-list-sublevels).
    tags_match_list_sublevels = true,
    time_grid = {
      enabled = true, -- org-agenda-use-time-grid
      --- org-agenda-time-grid flags: "daily", "weekly", "today",
      --- "require-timed", "remove-match".
      type = { "daily", "today", "require-timed" },
      times = { 800, 1000, 1200, 1400, 1600, 1800, 2000 },
      --- Text after the time of grid lines and timed entries (3rd element).
      separator = " ┄┄┄┄┄ ",
      time_string = "┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄",
    },
    --- org-agenda-current-time-string
    current_time_string = "← now ───────────────────────────────────────────────",
    show_current_time_in_grid = true, -- org-agenda-show-current-time-in-grid
    --- Line prefix per view (org-agenda-prefix-format): %c category, %i
    --- icon, %t time, %s leader, %e effort, %l level, %b breadcrumbs,
    --- %T last tag, %(lua expr); a string applies to all views.
    prefix_format = {
      agenda = " %i %-12:c%?-12t% s",
      todo = " %i %-12:c",
      tags = " %i %-12:c",
      search = " %i %-12:c",
    },
    --- org-agenda-scheduled-leaders: { on the day, past (%d = days) }.
    scheduled_leaders = { "Scheduled: ", "Sched.%2dx: " },
    --- org-agenda-deadline-leaders: { due, in %d days, %d days ago }.
    deadline_leaders = { "Deadline:  ", "In %3d d.: ", "%2d d. ago: " },
    --- org-agenda-timerange-leaders: { same day, "(day/days)" }.
    timerange_leaders = { "", "(%d/%d): " },
    inactive_leader = "[", -- org-agenda-inactive-leader
    --- Remove a time shown in the prefix from the headline text: true |
    --- false | "beg" (org-agenda-remove-times-when-in-prefix).
    remove_times_when_in_prefix = true,
    --- Use a time of day found in the headline (org-agenda-search-headline-for-time).
    search_headline_for_time = true,
    --- Minutes added to timed entries without an end time
    --- (org-agenda-default-appointment-duration).
    default_appointment_duration = nil,
    time_leading_zero = false, -- org-agenda-time-leading-zero
    timegrid_use_ampm = false, -- org-agenda-timegrid-use-ampm
    --- Day header: nil (aligned, week number on Mondays), a strftime
    --- format or a function(date) -> string (org-agenda-format-date).
    format_date = nil,
    --- Weekend days, 0 = Sunday (org-agenda-weekend-days).
    weekend_days = { 6, 0 },
    --- Vim regexp; matching tags are not displayed (org-agenda-hide-tags-regexp).
    hide_tags_regexp = nil,
    --- "auto" = right-aligned to the window, N > 0 = start column, N < 0 =
    --- right-aligned to column -N (org-agenda-tags-column).
    tags_column = "auto",
    --- { { vim_regexp, icon_text }, ... } for %i (org-agenda-category-icon-alist).
    category_icons = {},
    --- Echo the outline path of the entry at point (org-agenda-show-outline-path).
    show_outline_path = true,
    breadcrumbs_separator = "->", -- org-agenda-breadcrumbs-separator
    --- Sorting strategies per view (org-agenda-sorting-strategy).
    sorting = {
      agenda = { "habit-down", "time-up", "urgency-down", "category-keep" },
      todo = { "urgency-down", "category-keep" },
      tags = { "urgency-down", "category-keep" },
      search = { "category-keep" },
    },
    --- function(a, b) -> -1 | 1 | nil for "user-defined-up/-down"
    --- (org-agenda-cmp-user-defined).
    cmp_user_defined = nil,
    sort_notime_is_late = true, -- org-agenda-sort-notime-is-late
    sort_noeffort_is_high = true, -- org-agenda-sort-noeffort-is-high
    --- Maximum entries per day or list: a number, or a table per view type
    --- { agenda = n, todo = n, tags = n, search = n } (org-agenda-max-entries,
    --- org-agenda-max-todos, org-agenda-max-tags, org-agenda-max-effort).
    max_entries = nil,
    max_todos = nil,
    max_tags = nil,
    max_effort = nil,
    --- Where the agenda opens: "split" (org-agenda-window-setup
    --- reorganize-frame), "vsplit", "current", "only", "tab", "float".
    window = "split",
    --- Restore the window layout when quitting (org-agenda-restore-windows-after-quit).
    restore_windows_after_quit = false,
    --- One buffer per agenda command, reused until refreshed (org-agenda-sticky).
    sticky = false,
    --- Keep filters when another agenda is built (org-agenda-persistent-filter).
    persistent_filter = false,
    --- function(tag) -> "+tag" | "-tag" | nil, applied by `\` <CR> and 3/
    --- (org-agenda-auto-exclude-function).
    auto_exclude_function = nil,
    --- Keep marks after a bulk action (org-agenda-persistent-marks).
    persistent_marks = false,
    --- Extra bulk actions: { [key] = { fn = function(target, item), desc = "..." } }
    --- (org-agenda-bulk-custom-functions).
    bulk_custom_functions = {},
    --- No block headers and separators (org-agenda-compact-blocks).
    compact_blocks = false,
    log_mode_items = { "closed", "clock" }, -- org-agenda-log-mode-items
    habits = {
      graph_column = 40, -- org-habit-graph-column
      preceding_days = 21, -- org-habit-preceding-days
      following_days = 7, -- org-habit-following-days
      show_habits = true, -- org-habit-show-habits
      show_habits_only_for_today = true, -- org-habit-show-habits-only-for-today
      show_all_today = false, -- org-habit-show-all-today
      show_done_always_green = false, -- org-habit-show-done-always-green
      scheduled_past_days = nil, -- org-habit-scheduled-past-days
      today_glyph = "!", -- org-habit-today-glyph
      completed_glyph = "*", -- org-habit-completed-glyph
    },
    --- org-stuck-projects: projects matching `match` are stuck unless their
    --- subtree has one of `todo_keywords` / `tags` ("*" = any) or text
    --- matching the Vim regexp `text`.
    stuck_projects = {
      match = "+LEVEL=2/-DONE",
      todo_keywords = { "TODO", "NEXT", "NEXTACTION" },
      tags = {},
      text = nil,
    },
    --- Save source buffers after editing them from the agenda. Emacs never
    --- does: edited buffers stay modified until saved (C-x C-s in the agenda).
    save_after_edit = false,
    block_separator = "─", -- org-agenda-block-separator
    show_inherited_tags = true, -- org-agenda-show-inherited-tags
    --- true | false | "prefix" (org-agenda-remove-tags).
    remove_tags = false,
    custom_commands = {}, -- org-agenda-custom-commands
    --- Columns format of the agenda column view; nil = the first agenda
    --- file's (org-agenda-overriding-columns-format).
    overriding_columns_format = nil,
    view_columns_initially = false, -- org-agenda-view-columns-initially
    --- Show column summaries on date lines (org-agenda-columns-show-summaries).
    columns_show_summaries = true,
    --- Extra files for the search view; "agenda-archives" adds the archive
    --- files (org-agenda-text-search-extra-files).
    text_search_extra_files = {},
    search_view_always_boolean = false, -- org-agenda-search-view-always-boolean
    search_view_force_full_words = false, -- org-agenda-search-view-force-full-words
    search_view_max_outline_level = 0, -- org-agenda-search-view-max-outline-level
    --- Body lines shown under each entry in entry text mode (E)
    --- (org-agenda-entry-text-maxlines).
    entry_text_maxlines = 5,
    --- Ask before `<C-k>` deletes an entry longer than this many lines
    --- (org-agenda-confirm-kill). false = never ask.
    confirm_kill = 1,
    start_with_log_mode = false, -- false | true | "all" | "clockcheck" (org-agenda-start-with-log-mode)
    --- Add the first line of a clock or state note to log items
    --- (org-agenda-log-mode-add-notes).
    log_mode_add_notes = true,
    start_with_follow_mode = false, -- org-agenda-start-with-follow-mode
    start_with_clockreport_mode = false, -- org-agenda-start-with-clockreport-mode
    --- Clocktable parameters of the clock report mode
    --- (org-agenda-clockreport-parameter-plist); :scope and the time range
    --- come from the agenda.
    clockreport_parameters = { link = true, maxlevel = 2 },
    --- Text shown above the clock report (org-agenda-clock-report-header).
    clock_report_header = nil,
    --- What the clock check (`vc`) reports (org-agenda-clock-consistency-checks):
    --- clocks longer than max_duration or shorter than min_duration, gaps
    --- longer than max_gap unless they contain a gap_ok_around time of day.
    clock_consistency_checks = {
      max_duration = "10:00",
      min_duration = 0,
      max_gap = "0:05",
      gap_ok_around = { "4:00" },
    },
    start_with_entry_text_mode = false, -- org-agenda-start-with-entry-text-mode
    --- Dim TODOs blocked by enforce_todo_dependencies / checkboxes:
    --- true | false | "invisible" (org-agenda-dim-blocked-tasks).
    dim_blocked_tasks = true,
  },

  ---------------------------------------------------------------------------
  -- Capture
  ---------------------------------------------------------------------------
  capture = {
    --- Templates keyed by selection key (org-capture-templates). See
    --- `:h org-capture-templates`. When empty, the Emacs fallback
    --- `t = { description = "Task", target = "", headline = "Tasks",
    --- template = "* TODO %?\n  %u\n  %a" }` is used.
    templates = {},
    --- Rules making templates available only in some buffers
    --- (org-capture-templates-contexts), e.g.
    --- `{ { "p", { { in_mode = "markdown" } } } }`.
    templates_contexts = {},
    --- Window of the capture buffer: "split" (Emacs splits the frame) |
    --- "float" | "vsplit" | "tab" | "current".
    window = "split",
  },

  ---------------------------------------------------------------------------
  -- Refile
  ---------------------------------------------------------------------------
  refile = {
    --- Target specs (org-refile-targets). Empty = the level-1 headlines of
    --- the current buffer, like Emacs's nil. See `:h org-refile`.
    targets = {},
    --- When set (and `targets` is empty): the agenda files plus the current
    --- file, up to this level (a shortcut for
    --- `{ { files = "agenda", max_level = N }, { files = "current", max_level = N } }`).
    max_level = nil,
    --- With `max_level`: false leaves out the current file.
    include_current_file = nil,
    --- Target labels (org-refile-use-outline-path): false (the heading) |
    --- true (outline path) | "file" | "full-file-path" | "title" |
    --- "buffer-name" (outline path after that prefix; these also offer
    --- the files themselves).
    use_outline_path = false,
    --- With an outline path, choose it one level at a time
    --- (org-outline-path-complete-in-steps).
    outline_path_complete_in_steps = true,
    --- Allow new parent headlines ("Target/New"): false | true | "confirm"
    --- (org-refile-allow-creating-parent-nodes).
    allow_creating_parent_nodes = false,
    --- Refile a Visual selection that does not start at a headline, making
    --- its first line one (org-refile-active-region-within-subtree).
    active_region_within_subtree = false,
    --- function(headline) -> boolean, filters targets (org-refile-target-verify-function).
    verify = nil,
    --- Log refiling: false | "time" | "note" (org-log-refile).
    log = false,
    --- Refile as the first child instead of the last (org-reverse-note-order).
    reverse_note_order = false,
  },

  ---------------------------------------------------------------------------
  -- Clocking
  ---------------------------------------------------------------------------
  clock = {
    --- Clock out when the clocked entry is marked done: true (any done
    --- state) or a list of states (org-clock-out-when-done).
    out_when_done = true,
    --- Drawer for CLOCK lines (org-clock-into-drawer): true = the log
    --- drawer (LOGBOOK), a drawer name, false = none, or a number N = only
    --- once the entry has N clock lines. CLOCK_INTO_DRAWER overrides it.
    into_drawer = true,
    --- Remove CLOCK lines of 0:00 on clock out
    --- (org-clock-out-remove-zero-time-clocks).
    out_remove_zero_time = false,
    --- Round clock-in/out times to this many minutes; 0 = no rounding,
    --- "same-as-time-stamp" = `time_stamp_rounding_minutes[1]`
    --- (org-clock-rounding-minutes).
    rounding_minutes = 0,
    --- Clocking into an entry with an open CLOCK line continues that clock
    --- (org-clock-in-resume).
    in_resume = false,
    --- State to switch to on clock in: a keyword, or function(keyword) -> keyword|nil
    --- (receives the task's current keyword, nil when it has none)
    in_switch_to_state = nil, -- e.g. "NEXT"
    --- State to switch to on clock out: a keyword, or function(keyword) -> keyword|nil
    out_switch_to_state = nil,
    --- Notify once when the clocked time reaches the task's effort.
    notify_effort = true,
    --- Number of tasks remembered for clock_in with a count (clock history).
    history_length = 5,
    --- Start a new clock where the last one stopped (org-clock-continuously).
    continuously = false,
    --- Time shown in the statusline besides the running clock
    --- (org-clock-mode-line-total, CLOCK_MODELINE_TOTAL property):
    --- "current" | "today" | "repeat" (since LAST_REPEAT) | "all" | "auto"
    --- ("repeat" for repeated tasks, else "all").
    mode_line_total = "auto",
    --- Maximum length of the statusline text, 0 = no limit (org-clock-string-limit).
    string_limit = 0,
    --- function(headline) -> string: the task name in the statusline
    --- (org-clock-heading-function).
    heading_function = nil,
    --- Text put before the statusline once the effort is reached
    --- (org-clock-task-overrun-text).
    task_overrun_text = nil,
    --- Sound for the effort notification: true = bell, or a sound file
    --- (org-clock-sound).
    sound = nil,
    --- function(msg) or program called with the message instead of
    --- vim.notify (org-show-notification-handler).
    notification_handler = nil,
    --- Ask how to resolve the running clock after this many idle minutes
    --- (org-clock-idle-time). nil = never.
    idle_time = nil,
    --- Clock out after this many idle seconds (org-clock-auto-clockout-timer).
    auto_clockout_timer = nil,
    --- Resolve dangling clocks when clocking in: "when-no-clock-is-running",
    --- true (always) or false (org-clock-auto-clock-resolution).
    auto_clock_resolution = "when-no-clock-is-running",
    --- Count the running clock in clock tables and sums
    --- (org-clock-report-include-clocking-task).
    report_include_clocking_task = false,
    --- clock_goto falls back to the last clocked task (org-clock-goto-may-find-recent-task).
    goto_may_find_recent_task = true,
    --- Lines shown above the entry after clock_goto (org-clock-goto-before-context).
    goto_before_context = 2,
    --- Range of clock_display without a count (org-clock-display-default-range):
    --- a :block value such as "thisyear", "thismonth", "untilnow".
    display_default_range = "thisyear",
    --- Ask to clock out (and save) when quitting Neovim with a running
    --- clock (org-clock-ask-before-exiting).
    ask_before_exiting = true,
    statusline_icon = "⏱",
    --- Parameters for clocktables that don't set them (org-clocktable-defaults).
    clocktable_default = { maxlevel = 2, scope = "file", block = nil },
    --- Keep the running clock and the clock history across restarts:
    --- true (both), "clock", "history" or false (org-clock-persist).
    persist = false,
    --- Ask before resuming a saved clock after a restart
    --- (org-clock-persist-query-resume).
    persist_query_resume = true,
    persist_file = data_dir .. "/clock.json",
  },

  ---------------------------------------------------------------------------
  -- Encryption (org-crypt)
  ---------------------------------------------------------------------------
  crypt = {
    --- Match expression selecting the entries encrypt_entries,
    --- decrypt_entries and encrypt_on_save work on (org-crypt-tag-matcher).
    tag_matcher = "crypt",
    --- Key(s) to encrypt for, matched against the public keyring; the
    --- CRYPTKEY property overrides it. "" matches no key (symmetric unless
    --- CRYPTKEY is set), false always encrypts symmetrically (org-crypt-key).
    key = "",
    --- Encrypt matching entries before writing the buffer
    --- (org-crypt-use-before-save-magic).
    encrypt_on_save = false,
    --- Before decrypting in a buffer with a swap or undo file: "ask" to turn
    --- them off, true to turn them off, false to keep them
    --- (org-crypt-disable-auto-save). "encrypt" acts like true.
    disable_auto_save = "ask",
    --- The gpg executable (epg-gpg-program).
    gpg_program = "gpg",
  },

  ---------------------------------------------------------------------------
  -- org-protocol
  ---------------------------------------------------------------------------
  protocol = {
    --- Capture template of org-protocol://capture URLs without a template
    --- (org-protocol-default-template-key); nil = choose.
    default_template_key = nil,
    --- URL-to-file mappings for org-protocol://open-source
    --- (org-protocol-project-alist): list of { base_url, working_directory,
    --- online_suffix?, working_suffix?, rewrites? = { [vim regex] = path } }.
    projects = {},
    --- Extra sub-protocols (org-protocol-protocol-alist): list of
    --- { protocol = "name", fn = function(params) end, order? = { keys } }.
    handlers = {},
  },

  ---------------------------------------------------------------------------
  -- Timers
  ---------------------------------------------------------------------------
  timer = {
    --- How timer_insert writes the value, "%s" is the value (org-timer-format).
    format = "%s ",
    --- Countdown suggested at the prompt, minutes or h:mm:ss; "0" = none
    --- (org-timer-default-timer).
    default_timer = "0",
  },

  ---------------------------------------------------------------------------
  -- Links / IDs / attachments
  ---------------------------------------------------------------------------
  links = {
    --- `#+LINK` style abbreviations: { gh = "https://github.com/%s" }
    --- (org-link-abbrev-alist).
    abbreviations = {},
    --- Custom link types (org-link-parameters): a follow function, or a
    --- table { follow, complete, store, export, face, insert_description }.
    types = {},
    --- Ask before running shell: links: true, false or function(cmd) ->
    --- boolean (org-link-shell-confirm-function).
    confirm_shell = true,
    --- Vim regex: shell: links matching it run without asking; "" = none
    --- (org-link-shell-skip-confirm-regexp).
    shell_skip_confirm_regexp = "",
    --- Store links to headlines as id: links (org-id-link-to-org-use-id):
    --- false | true | "create-if-interactive" |
    --- "create-if-interactive-and-no-custom-id" | "use-existing".
    use_id = false,
    --- Open files with an extension via external app: { pdf = "open" };
    --- "vim" forces Neovim (org-file-apps).
    file_apps = {},
    --- Add a search string (the heading, a name, the line or the
    --- selection) to stored file links: true, false, or the number of
    --- selected lines to keep (org-link-context-for-files).
    context_for_files = true,
    --- How inserted file links write paths: "adaptive" (relative below the
    --- file's directory, else absolute), "relative", "absolute",
    --- "noabbrev" or function(path) -> string (org-link-file-path-type).
    file_path_type = "adaptive",
    --- Keep a stored link after inserting it (org-link-keep-stored-after-insertion).
    keep_stored_after_insertion = false,
    --- Fuzzy links in Org files only match headlines, targets and names:
    --- "query-to-create" offers to create a missing heading, true reports
    --- it, false falls back to a text search
    --- (org-link-search-must-match-exact-headline).
    search_must_match_exact_headline = "query-to-create",
    --- Where file: and id: links open: "other-window", "current", "split",
    --- "vsplit", "tab" or function(path) (org-link-frame-setup, `file`).
    frame_setup = { file = "other-window" },
    --- Default description of inserted links: function(link, desc) ->
    --- string|nil (org-link-make-description-function).
    make_description = nil,
    --- Server for doi: links (org-link-doi-server-url).
    doi_server_url = "https://doi.org/",
    --- Functions tried first on a file search string: function(search) ->
    --- true when handled (org-execute-file-search-functions).
    search_functions = {},
    --- function(type, path) -> type, path applied before following a link
    --- (org-link-translation-function).
    translation_function = nil,
  },
  id = {
    --- Where the ID -> file database is kept (org-id-locations-file; JSON,
    --- not shared with Emacs).
    locations_file = data_dir .. "/id-locations.json",
    --- How new IDs are made (org-id-method): "uuid" | "ts" | "org".
    method = "uuid",
    --- Prefix of new IDs (org-id-prefix), e.g. "Org".
    prefix = nil,
    --- Time stamp format of "ts" IDs (org-id-ts-format; %6N = microseconds).
    ts_format = "%Y%m%dT%H%M%S.%6N",
    --- Also scan the archive files of the agenda files (org-id-search-archives).
    search_archives = true,
    --- More files (paths or globs) scanned for IDs (org-id-extra-files).
    extra_files = {},
    --- Add a search string to id: links for a named element or selection
    --- inside the entry (org-id-link-use-context).
    link_use_context = true,
    --- Store id: links using an ancestor's ID plus a search string
    --- (org-id-link-consider-parent-id).
    link_consider_parent_id = false,
  },
  attach = {
    --- Base directory of ID-based attachment directories (org-attach-id-dir).
    dir = "data/",
    --- Default attach method (org-attach-method): "cp" | "mv" | "ln" (hard
    --- link) | "lns" (symbolic link).
    method = "cp",
    --- ID -> subdirectory of `dir` (org-attach-id-to-path-function-list):
    --- functions or the built-ins "uuid" (`ab/cdef...`), "ts"
    --- (`202609/...` for time stamp IDs) and "fallback" (`__/a/abcdef...`). The first result
    --- that exists is used, else the first one.
    id_to_path = { "uuid", "ts", "fallback" },
    --- Inherit the attachment directory from a parent: "selective" (follow
    --- `use_property_inheritance`) | true | false (org-attach-use-inheritance).
    use_inheritance = "selective",
    --- Store DIR relative to the file (org-attach-dir-relative).
    dir_relative = false,
    --- How an entry without a directory gets one
    --- (org-attach-preferred-new-method): "id" | "dir" | "ask" | false.
    preferred_new_method = "id",
    --- Store a link after attaching (org-attach-store-link-p): "attached"
    --- (attachment: link) | "file" (file: link to the attachment) | true
    --- (file: link to the source) | false.
    store_link = "attached",
    --- Delete an empty attachment directory on sync: "query" | true | false
    --- (org-attach-sync-delete-empty-dir).
    sync_delete_empty_dir = "query",
    --- Delete the attachments of archived entries: false | true | "query"
    --- (org-attach-archive-delete).
    archive_delete = false,
    --- Tag of entries with attachments; false for none (org-attach-auto-tag).
    auto_tag = "ATTACH",
  },

  ---------------------------------------------------------------------------
  -- Babel
  ---------------------------------------------------------------------------
  babel = {
    -- Ask before evaluating: true, false, or a function(lang, body) that
    -- returns true to ask (org-confirm-babel-evaluate)
    confirm_evaluate = true,
    -- Results of this many lines or more use an example block
    -- (org-babel-min-lines-for-block-output)
    min_lines_for_block_output = 10,
    -- Kill an evaluation after this many ms (no Emacs counterpart)
    timeout = 30000,
    -- Evaluate code when exporting (org-export-use-babel)
    evaluate_on_export = true,
    -- C-c C-c on a block does not evaluate it (org-babel-no-eval-on-ctrl-c-ctrl-c)
    no_eval_on_ctrl_c_ctrl_c = false,
    -- (org-babel-default-header-args)
    default_header_args = {
      session = "none",
      results = "replace",
      exports = "code",
      cache = "no",
      noweb = "no",
      hlines = "no",
      tangle = "no",
    },
    -- Header args of inline src blocks (org-babel-default-inline-header-args)
    default_inline_header_args = {
      session = "none",
      results = "replace",
      exports = "results",
      hlines = "yes",
    },
    -- Header args of #+CALL lines and call_ (org-babel-default-lob-header-args)
    default_lob_header_args = { exports = "results" },
    -- Keyword of results lines (org-babel-results-keyword)
    results_keyword = "RESULTS",
    -- Inline results inside {{{results(...)}}} (org-babel-inline-result-wrap)
    inline_result_wrap = "=%s=",
    -- Write "(date) " before :cache hashes (org-babel-hash-show-time)
    hash_show_time = false,
    -- Noweb reference delimiters (org-babel-noweb-wrap-start / -end)
    noweb_wrap_start = "<<",
    noweb_wrap_end = ">>",
    -- Tangle link comments use paths relative to the tangled file
    -- (org-babel-tangle-use-relative-file-links)
    tangle_use_relative_file_links = true,
    -- Link comments around tangled blocks, %link / %source-name / %file /
    -- %start-line / %end-line (org-babel-tangle-comment-format-beg / -end)
    tangle_comment_format_beg = "[[%link][%source-name]]",
    tangle_comment_format_end = "%source-name ends here",
    -- Base mode for symbolic :tangle-mode values like u+x, octal string
    -- (org-babel-tangle-default-file-mode)
    tangle_default_file_mode = "644",
    -- Extensions of `:tangle yes` files by language, added to Emacs' list
    -- (org-babel-tangle-lang-exts)
    tangle_lang_exts = {},
    -- Save the Org buffer before tangling (org-babel-pre-tangle-hook)
    tangle_save_buffer = true,
    -- Write tangle comments as they are, without comment syntax
    -- (org-babel-tangle-uncomment-comments)
    tangle_uncomment_comments = false,
    -- Languages that can run, { cmd, ext, default_header_args }
    -- (org-babel-load-languages; default_header_args is
    -- org-babel-default-header-args:LANG). Emacs enables only emacs-lisp,
    -- which cannot run in Neovim, so the common interpreters are enabled.
    languages = {
      sh = { cmd = "sh" },
      shell = { cmd = "sh" },
      bash = { cmd = "bash" },
      zsh = { cmd = "zsh" },
      fish = { cmd = "fish" },
      python = { cmd = "python3", ext = "py" },
      python3 = { cmd = "python3", ext = "py" },
      lua = { cmd = "nvim", ext = "lua" }, -- evaluated inside Neovim
      js = { cmd = "node", ext = "js" },
      javascript = { cmd = "node", ext = "js" },
      typescript = { cmd = "npx tsx", ext = "ts" },
      ts = { cmd = "npx tsx", ext = "ts" },
      ruby = { cmd = "ruby", ext = "rb" },
      perl = { cmd = "perl", ext = "pl" },
      php = { cmd = "php", ext = "php" },
      r = { cmd = "Rscript", ext = "R" },
      R = { cmd = "Rscript", ext = "R" },
      go = { cmd = "go run", ext = "go" },
      rust = { cmd = "rust-script", ext = "rs" },
      sqlite = { cmd = "sqlite3", ext = "sql" },
      -- :engine postgresql|mysql|... runs the engine's client (ob-sql)
      sql = { ext = "sql" },
      -- ob-C: compiled with :flags, :libs, :includes, :defines, :main
      C = { cmd = "gcc", ext = "c" },
      ["C++"] = { cmd = "g++", ext = "cpp" },
      cpp = { cmd = "g++", ext = "cpp" },
      D = { cmd = "rdmd", ext = "d" },
      awk = { cmd = "awk -f", ext = "awk" },
    },
  },

  ---------------------------------------------------------------------------
  -- Export
  ---------------------------------------------------------------------------
  export = {
    --- Directory for exported files (plugin option), relative to the
    --- source file unless absolute; nil = next to the source file.
    output_dir = nil,
    --- Open the exported file with the system opener (plugin option).
    open_after_export = false,
    -- The options below mirror Emacs org-export-* variables; #+OPTIONS,
    -- keywords and EXPORT_* properties override them.
    with_toc = true, -- org-export-with-toc (true, false or a depth)
    with_section_numbers = true, -- org-export-with-section-numbers (true, false or a depth)
    headline_levels = 3, -- org-export-headline-levels
    with_author = true, -- org-export-with-author
    with_date = true, -- org-export-with-date
    with_email = false, -- org-export-with-email
    with_creator = false, -- org-export-with-creator
    with_title = true, -- org-export-with-title
    with_todo_keywords = true, -- org-export-with-todo-keywords
    with_tags = true, -- org-export-with-tags (true, false or "not-in-toc")
    with_priority = false, -- org-export-with-priority
    --- org-export-with-drawers: true, false, a list of drawer names, or
    --- { not = { ... } } to export every drawer but those.
    with_drawers = { ["not"] = { "LOGBOOK" } },
    with_properties = false, -- org-export-with-properties (true, false or a list)
    with_planning = false, -- org-export-with-planning
    with_clocks = false, -- org-export-with-clocks
    --- org-export-with-timestamps: true, false, "active" or "inactive"
    --- (only paragraphs made of timestamps are affected, like Emacs).
    with_timestamps = true,
    with_tasks = true, -- org-export-with-tasks (true, false, "todo", "done" or a list)
    with_archived_trees = "headline", -- org-export-with-archived-trees (true, false, "headline")
    with_emphasize = true, -- org-export-with-emphasize
    with_entities = true, -- org-export-with-entities
    with_fixed_width = true, -- org-export-with-fixed-width
    with_footnotes = true, -- org-export-with-footnotes
    with_inlinetasks = true, -- org-export-with-inlinetasks
    with_latex = true, -- org-export-with-latex (true, false, "verbatim")
    with_smart_quotes = false, -- org-export-with-smart-quotes
    with_special_strings = true, -- org-export-with-special-strings
    with_statistics_cookies = true, -- org-export-with-statistics-cookies
    with_sub_superscripts = true, -- org-export-with-sub-superscripts (true, false, "{}")
    with_tables = true, -- org-export-with-tables
    --- org-export-with-broken-links: false = stop the export with an error,
    --- true = ignore broken links, "mark" = write [BROKEN LINK: path].
    with_broken_links = false,
    preserve_breaks = false, -- org-export-preserve-breaks
    timestamp_file = true, -- org-export-timestamp-file (creation time in the output)
    expand_links = true, -- org-export-expand-links ($VAR in file links)
    select_tags = { "export" }, -- org-export-select-tags
    exclude_tags = { "noexport" }, -- org-export-exclude-tags
    default_language = "en", -- org-export-default-language
    date_timestamp_format = nil, -- org-export-date-timestamp-format
    --- user-full-name: default #+AUTHOR; nil = the system user's full name.
    author = nil,
    email = nil, -- user-mail-address
    creator = nil, -- org-export-creator-string; nil = "Neovim X.Y.Z (org.nvim ...)"
    --- org-export-global-macros: { name = "template $1" | function(...) }.
    global_macros = {},
    snippet_translation = {}, -- org-export-snippet-translation-alist
    inlinetask_min_level = 15, -- org-inlinetask-min-level
    table_number_fraction = 0.5, -- org-table-number-fraction
    --- org-export-before-processing-functions / -before-parsing-functions:
    --- { before_processing = fn, before_parsing = fn }, fn(backend, lines)
    --- returning new lines (or nil).
    hooks = {},
    --- org-export-filter-TYPE-functions as Lua functions:
    --- { [type] = fn | { fn, ... } }, fn(text, backend, info) returning the
    --- new text (nil keeps it). Types are element/object types
    --- ("paragraph", "plain-text", ...) plus "body", "final-output",
    --- "parse-tree" (fn(tree, backend, info)) and "options" (fn(info, backend)).
    filters = {},
    html = {
      doctype = "xhtml-strict", -- org-html-doctype
      html5_fancy = false, -- org-html-html5-fancy
      container = "div", -- org-html-container-element
      content_class = "content", -- org-html-content-class
      extension = "html", -- org-html-extension
      head_include_default_style = true, -- org-html-head-include-default-style
      --- Extra CSS put after the default style (plugin option); false = no
      --- default style (like head_include_default_style = false).
      style = nil,
      head = "", -- org-html-head (string or function(info))
      head_extra = "", -- org-html-head-extra (string or function(info))
      head_include_scripts = false, -- org-html-head-include-scripts
      preamble = true, -- org-html-preamble (true, false, format string, function)
      postamble = "auto", -- org-html-postamble ("auto", true, false, format string, function)
      postamble_format = nil, -- org-html-postamble-format ({ en = "..." }; nil = Emacs default)
      preamble_format = nil, -- org-html-preamble-format
      validation_link = nil, -- org-html-validation-link (nil = Emacs default)
      creator_string = nil, -- org-html-creator-string
      link_home = "", -- org-html-link-home
      link_up = "", -- org-html-link-up
      link_use_abs_url = false, -- org-html-link-use-abs-url
      link_org_files_as_html = true, -- org-html-link-org-files-as-html
      metadata_timestamp_format = "%Y-%m-%d %a %H:%M", -- org-html-metadata-timestamp-format
      toplevel_hlevel = 2, -- org-html-toplevel-hlevel
      self_link_headlines = false, -- org-html-self-link-headlines
      prefer_user_labels = false, -- org-html-prefer-user-labels
      checkbox_type = "ascii", -- org-html-checkbox-type ("ascii", "unicode", "html")
      inline_images = true, -- org-html-inline-images
      table_caption_above = true, -- org-html-table-caption-above
      footnote_format = "<sup>%s</sup>", -- org-html-footnote-format
      footnote_separator = "<sup>, </sup>", -- org-html-footnote-separator
      equation_reference_format = "\\eqref{%s}", -- org-html-equation-reference-format
      use_infojs = "when-configured", -- org-html-use-infojs
      wrap_src_lines = false, -- org-html-wrap-src-lines
      --- Load MathJax for LaTeX fragments (org-html-with-latex = mathjax);
      --- false leaves the math as text.
      mathjax = true,
      mathjax_options = nil, -- org-html-mathjax-options ({ path = ..., scale = 1.0, ... })
      --- function(code, lang) -> HTML to highlight source code (Emacs uses
      --- htmlize; nil = no highlighting).
      fontify = nil,
    },
    latex = {
      default_class = "article", -- org-latex-default-class
      classes = nil, -- org-latex-classes (nil = the Emacs list)
      default_packages = nil, -- org-latex-default-packages-alist (nil = the Emacs list)
      packages = {}, -- org-latex-packages-alist
      compiler = "pdflatex", -- org-latex-compiler
      pdf_process = nil, -- org-latex-pdf-process (nil = latexmk when available, else 3 x %latex)
      bib_compiler = "bibtex", -- org-latex-bib-compiler
      remove_logfiles = true, -- org-latex-remove-logfiles
      --- Compile PDFs in the background with vim.system (plugin option;
      --- Emacs blocks unless the export is asynchronous).
      async_compile = true,
      src_block_backend = "verbatim", -- org-latex-src-block-backend ("verbatim", "listings", "minted")
      caption_above = { "table" }, -- org-latex-caption-above
      prefer_user_labels = false, -- org-latex-prefer-user-labels
      reference_command = "\\ref{%s}", -- org-latex-reference-command
      tables_booktabs = false, -- org-latex-tables-booktabs
      tables_centered = true, -- org-latex-tables-centered
      images_centered = true, -- org-latex-images-centered
      image_default_width = ".9\\linewidth", -- org-latex-image-default-width
      default_figure_position = "htbp", -- org-latex-default-figure-position
      default_table_environment = "tabular", -- org-latex-default-table-environment
      default_table_mode = "table", -- org-latex-default-table-mode
      title_command = "\\maketitle", -- org-latex-title-command
      toc_command = "\\tableofcontents\n\n", -- org-latex-toc-command
      hyperref_template = nil, -- org-latex-hyperref-template (nil = the Emacs template)
      use_sans = false, -- org-latex-use-sans
    },
    md = {
      headline_style = "atx", -- org-md-headline-style ("atx", "setext", "mixed")
      toplevel_hlevel = 1, -- org-md-toplevel-hlevel
      footnote_format = "<sup>%s</sup>", -- org-md-footnote-format
      footnotes_section = "%s%s", -- org-md-footnotes-section
      link_org_files_as_md = true, -- org-md-link-org-files-as-md
    },
    org = {
      with_special_rows = true, -- org-org-with-special-rows
    },
    beamer = {
      frame_level = 1, -- org-beamer-frame-level
      frame_default_options = "", -- org-beamer-frame-default-options
      outline_frame_title = "Outline", -- org-beamer-outline-frame-title
      outline_frame_options = "", -- org-beamer-outline-frame-options
      subtitle_format = "\\subtitle{%s}", -- org-beamer-subtitle-format
      theme = "default", -- org-beamer-theme
      --- org-beamer-environments-extra: { { name, key, open, close }, ... }
      environments_extra = {},
      frame_environment = "orgframe", -- org-beamer-frame-environment
    },
    icalendar = {
      combined_agenda_file = "~/org.ics", -- org-icalendar-combined-agenda-file
      combined_name = "OrgMode", -- org-icalendar-combined-name
      combined_description = "", -- org-icalendar-combined-description
      alarm_time = 0, -- org-icalendar-alarm-time (minutes)
      force_alarm = false, -- org-icalendar-force-alarm
      exclude_tags = {}, -- org-icalendar-exclude-tags
      scheduled_summary_prefix = "S: ", -- org-icalendar-scheduled-summary-prefix
      deadline_summary_prefix = "DL: ", -- org-icalendar-deadline-summary-prefix
      use_deadline = { "event-if-not-todo", "todo-due" }, -- org-icalendar-use-deadline
      use_scheduled = { "todo-start" }, -- org-icalendar-use-scheduled
      categories = { "local-tags", "category" }, -- org-icalendar-categories
      with_timestamps = "active", -- org-icalendar-with-timestamps
      --- org-icalendar-include-todo: false, true, "unblocked", "all" or keywords.
      include_todo = false,
      todo_unscheduled_start = "recurring-deadline-warning", -- org-icalendar-todo-unscheduled-start
      include_sexps = true, -- org-icalendar-include-sexps (diary sexps are not supported)
      include_body = true, -- org-icalendar-include-body (true or a number of characters)
      store_uid = false, -- org-icalendar-store-UID
      timezone = nil, -- org-icalendar-timezone (nil = $TZ)
      date_time_format = ":%Y%m%dT%H%M%S", -- org-icalendar-date-time-format
      ttl = nil, -- org-icalendar-ttl
      default_appointment_duration = nil, -- org-agenda-default-appointment-duration (minutes)
      after_save_hook = nil, -- org-icalendar-after-save-hook: function(path)
    },
    publish = {
      --- org-publish-project-alist: { name = { base_directory = ..., ... } }
      --- or a list of tables with a `name`.
      projects = {},
      --- org-publish-timestamp-directory (Emacs: ~/.org-timestamps/).
      timestamp_directory = vim.fn.stdpath("data") .. "/org-timestamps/",
      use_timestamps_flag = true, -- org-publish-use-timestamps-flag
      list_skipped_files = true, -- org-publish-list-skipped-files
      sitemap_sort_files = "alphabetically", -- org-publish-sitemap-sort-files
      sitemap_sort_folders = "ignore", -- org-publish-sitemap-sort-folders
      sitemap_sort_ignore_case = false, -- org-publish-sitemap-sort-ignore-case
      after_publishing_hook = nil, -- org-publish-after-publishing-hook: function(src, out)
    },
    cite = {
      --- org-cite-export-processors: { [backend] = { name, bibstyle, citestyle } | "name" };
      --- `t` is the fallback. #+CITE_EXPORT overrides it.
      export_processors = { t = { "basic" } },
      global_bibliography = {}, -- org-cite-global-bibliography
      adjust_note_numbers = true, -- org-cite-adjust-note-numbers
      note_rules = nil, -- org-cite-note-rules (nil = the Emacs rules)
      punctuation_marks = { ".", ",", ";", ":", "!", "?" }, -- org-cite-punctuation-marks
      basic_sorting_field = "author", -- org-cite-basic-sorting-field
      basic_author_year_separator = ", ", -- org-cite-basic-author-year-separator
      natbib_options = {}, -- org-cite-natbib-options
      biblatex_options = nil, -- org-cite-biblatex-options
      biblatex_styles = nil, -- org-cite-biblatex-styles (nil = the Emacs table)
      biblatex_style_shortcuts = nil, -- org-cite-biblatex-style-shortcuts (nil = the Emacs table)
    },
    ascii = {
      charset = "ascii", -- org-ascii-charset ("ascii", "latin1", "utf-8")
      text_width = nil, -- org-ascii-text-width (nil = export.text_width, else 72)
      global_margin = 0, -- org-ascii-global-margin
      inner_margin = 2, -- org-ascii-inner-margin
      quote_margin = 6, -- org-ascii-quote-margin
      list_margin = 0, -- org-ascii-list-margin
      inlinetask_width = 30, -- org-ascii-inlinetask-width
      headline_spacing = { 1, 2 }, -- org-ascii-headline-spacing ({ before, after } or false)
      indented_line_width = "auto", -- org-ascii-indented-line-width
      paragraph_spacing = "auto", -- org-ascii-paragraph-spacing
      links_to_notes = true, -- org-ascii-links-to-notes
      table_keep_all_vertical_lines = false, -- org-ascii-table-keep-all-vertical-lines
      table_widen_columns = true, -- org-ascii-table-widen-columns
      table_use_ascii_art = false, -- org-ascii-table-use-ascii-art (not supported)
      caption_above = false, -- org-ascii-caption-above
      verbatim_format = "`%s'", -- org-ascii-verbatim-format
      bullets = nil, -- org-ascii-bullets ({ ascii = {...}, latin1 = {...}, ["utf-8"] = {...} }; nil = Emacs)
      underline = nil, -- org-ascii-underline (same shape; nil = Emacs)
      format_drawer_function = nil, -- org-ascii-format-drawer-function: fn(name, contents, width)
      --- org-ascii-format-inlinetask-function:
      --- fn(todo, todo_type, priority, name, tags, contents, width, inlinetask, info)
      format_inlinetask_function = nil,
    },
    --- Legacy alias of ascii.text_width (org-ascii-text-width).
    text_width = 72,
    pandoc = { cmd = "pandoc", args = {} },
  },

  ---------------------------------------------------------------------------
  -- Notifications (appointment reminders)
  ---------------------------------------------------------------------------
  notifications = {
    enabled = false,
    --- Minutes before a timed scheduled/deadline entry to notify.
    reminder_time = { 12, 9, 6, 3, 0 },
    check_interval = 60,
    --- Also use the OS notifier (osascript / notify-send) when available.
    system_notification = true,
    --- Custom notifier: function({ title, body, item, minutes }). nil = built-in.
    notifier = nil,
  },

  ---------------------------------------------------------------------------
  -- UI
  ---------------------------------------------------------------------------
  ui = {
    --- Conceal link brackets and show only descriptions (org-link-descriptive).
    conceal_links = true,
    --- Hide *, /, _, =, ~, + around emphasized text (org-hide-emphasis-markers).
    hide_emphasis_markers = false,
    --- Show only the last star of each headline (org-hide-leading-stars;
    --- #+STARTUP: hidestars / showstars).
    hide_leading_stars = false,
    --- Replace headline stars with symbols. false or list per level.
    bullets = false, -- e.g. { "◉", "○", "✸", "✿" }
    --- Replace checkboxes with icons. false or { unchecked, partial, checked }
    checkboxes = false, -- e.g. { " ", "◐", "✓" }
    --- Virtual indentation of body text (org-indent-mode, org-startup-indented;
    --- #+STARTUP: indent / noindent).
    indent_mode = false,
    --- Render \alpha etc. as unicode (org-pretty-entities; #+STARTUP:
    --- entitiespretty / entitiesplain, toggle with toggle_pretty_entities).
    pretty_entities = false,
    --- With pretty_entities, also show x^2 and a_{i} as super- and
    --- subscripts (org-pretty-entities-include-sub-superscripts).
    pretty_entities_include_sub_superscripts = true,
    --- Which `^` / `_` are sub/superscripts: true, "{}" (only with braces)
    --- or false (org-use-sub-superscripts; #+OPTIONS: ^:{}).
    use_sub_superscripts = true,
    --- Number headlines with virtual text (org-num-mode, org-startup-numerated;
    --- #+STARTUP: num / nonum). Toggle with num_mode.
    num = false,
    --- Deepest numbered level, nil = all (org-num-max-level).
    num_max_level = nil,
    --- Don't number COMMENT subtrees (org-num-skip-commented).
    num_skip_commented = false,
    --- Don't number the footnote section (org-num-skip-footnotes).
    num_skip_footnotes = false,
    --- Tags whose subtrees are not numbered (org-num-skip-tags).
    num_skip_tags = {},
    --- Don't number subtrees with an UNNUMBERED property (org-num-skip-unnumbered).
    num_skip_unnumbered = false,
    --- function(numbers) -> string, the text shown before the headline
    --- (org-num-format-function). nil = "1.2.3 ".
    num_format_function = nil,
    --- Dim the whole headline of DONE entries (org-fontify-done-headline).
    fontify_done_headline = true,
    --- Syntax-include the languages of src blocks for highlighting
    --- (org-src-fontify-natively).
    src_highlight = true,
    --- Per-keyword faces: { WAITING = ":foreground orange :weight bold" }
    --- or a highlight definition table { fg = "#ff9e64", bold = true } or a group name.
    todo_keyword_faces = {},
    --- Faces of priority cookies, like `todo_keyword_faces`:
    --- `{ A = "ErrorMsg", ["10"] = { fg = "gray" } }` (org-priority-faces).
    priority_faces = {},
    --- Faces of tags, like `todo_keyword_faces`: `{ urgent = ":foreground red" }`
    --- (org-tag-faces).
    tag_faces = {},
  },

  ---------------------------------------------------------------------------
  -- Mappings. Set any mapping to `false` to disable it, or a list of lhs.
  -- `<prefix>` is replaced by `mappings.prefix`.
  ---------------------------------------------------------------------------
  mappings = {
    disable_all = false,
    prefix = "<leader>o",
    global = {
      agenda = "<prefix>a",
      capture = "<prefix>c",
      store_link = "<prefix>ls",
      goto_heading = "<prefix>g",
      clock_goto = "<prefix>xj",
      clock_out = "<prefix>xo",
      clock_cancel = "<prefix>xq",
    },
    org = {
      help = "g?",
      -- visibility
      cycle = "<Tab>",
      global_cycle = "<S-Tab>",
      -- context / links
      context_action = { "<C-c><C-c>", "<prefix><CR>" },
      open_at_point = { "<CR>", "gx", "<prefix>o" },
      -- structure
      meta_return = "<M-CR>",
      meta_shift_return = "<M-S-CR>",
      insert_heading = "<prefix>ih",
      insert_todo_heading = "<prefix>it",
      insert_subheading = "<prefix>is",
      insert_drawer = "<prefix>id",
      insert_structure_template = "<prefix>ib",
      insert_footnote = "<prefix>if",
      promote_heading = "<<",
      demote_heading = ">>",
      promote_subtree = "<s",
      demote_subtree = ">s",
      meta_left = { "<M-h>", "<M-Left>" },
      meta_right = { "<M-l>", "<M-Right>" },
      meta_up = { "<M-k>", "<M-Up>" },
      meta_down = { "<M-j>", "<M-Down>" },
      shift_meta_left = "<M-H>",
      shift_meta_right = "<M-L>",
      shift_meta_up = "<M-K>",
      shift_meta_down = "<M-J>",
      move_subtree_up = "<prefix>K",
      move_subtree_down = "<prefix>J",
      copy_subtree = "<prefix>hy",
      cut_subtree = "<prefix>hd",
      paste_subtree = "<prefix>hp",
      clone_subtree = "<prefix>hc",
      sort = "<prefix>hs",
      narrow_subtree = "<prefix>hn",
      toggle_comment = "<prefix>hC",
      toggle_archive_tag = "<prefix>hA",
      toggle_heading = "<prefix>*",
      toggle_item = "<prefix>-",
      emphasize = "<prefix>E",
      mark_element = "<prefix>v",
      narrow_block = "<prefix>nb",
      narrow_element = "<prefix>ne",
      goto_parent = "g{",
      next_heading = "]]",
      prev_heading = "[[",
      next_sibling = "][",
      prev_sibling = "[]",
      buffer_goto = "<prefix>.",
      -- todo / priority / tags / properties
      todo_next = "cit",
      todo_prev = "ciT",
      shift_right = "<S-Right>",
      shift_left = "<S-Left>",
      todo_select = "<prefix>T",
      shift_up = "<S-Up>",
      shift_down = "<S-Down>",
      increment = "<C-a>",
      decrement = "<C-x>",
      priority = "<prefix>,",
      set_tags = "<prefix>t",
      set_property = "<prefix>p",
      delete_property = "<prefix>P",
      id_get_create = "<prefix>lI",
      -- dates
      schedule = "<prefix>s",
      deadline = "<prefix>d",
      timestamp = "<prefix>i.",
      timestamp_inactive = "<prefix>i!",
      -- lists
      toggle_checkbox = "<C-Space>",
      update_statistics = "<prefix>#",
      cycle_bullet = "<prefix>hb",
      -- clock
      clock_in = "<prefix>xi",
      clock_out = "<prefix>xo",
      clock_cancel = "<prefix>xq",
      clock_goto = "<prefix>xj",
      set_effort = "<prefix>xe",
      inc_effort = "<prefix>xE",
      clock_modify_effort = "<prefix>xm",
      clock_resolve = "<prefix>xz",
      clock_report = "<prefix>xr",
      clock_display = "<prefix>xd",
      dblock_update = "<prefix>xu",
      dblock_update_all = "<prefix>xU",
      column_view = "<prefix>C",
      -- links
      insert_link = "<prefix>li",
      store_link = "<prefix>ls",
      toggle_link_display = "<prefix>lt",
      next_link = "<prefix>ln",
      prev_link = "<prefix>lp",
      insert_last_stored_link = "<prefix>lL",
      insert_all_links = "<prefix>lA",
      id_goto = "<prefix>lg",
      id_copy = "<prefix>ly",
      -- refile / archive / attach
      refile = "<prefix>r",
      refile_copy = "<prefix>R",
      archive_subtree = "<prefix>$",
      attach = "<prefix>A",
      -- search / export
      sparse_tree = "<prefix>/",
      export = "<prefix>e",
      -- tables
      table_create = "<prefix>Tc",
      table_insert_hline = "<prefix>T-",
      table_recalc = "<prefix>Tf",
      table_sort = "<prefix>Ts",
      table_insert_row = "<prefix>Tr",
      table_delete_row = "<prefix>TR",
      table_insert_column = "<prefix>Ti",
      table_delete_column = "<prefix>TI",
      table_copy_down = "<S-CR>",
      table_transpose = "<prefix>Tt",
      table_rotate_marks = "<prefix>T#",
      -- babel
      edit_special = "<prefix>'",
      babel_execute = "<prefix>be",
      babel_execute_buffer = "<prefix>bb",
      babel_execute_subtree = "<prefix>bs",
      babel_tangle = "<prefix>bt",
      babel_remove_result = "<prefix>bk",
      babel_next_block = "<prefix>bn",
      babel_prev_block = "<prefix>bp",
      babel_tangle_file = "<prefix>bf",
      babel_expand = "<prefix>bv",
      babel_view_info = "<prefix>bI",
      babel_check = "<prefix>bc",
      babel_insert_header_arg = "<prefix>bj",
      babel_goto_named = "<prefix>bg",
      babel_goto_named_result = "<prefix>br",
      babel_goto_head = "<prefix>bu",
      babel_open_result = "<prefix>bo",
      babel_demarcate = "<prefix>bd",
      babel_lob_ingest = "<prefix>bi",
      babel_load_in_session = "<prefix>bl",
      babel_switch_to_session = "<prefix>bz",
      babel_switch_to_session_with_code = "<prefix>bZ",
      babel_kill_session = "<prefix>bK",
      babel_sha1_hash = "<prefix>ba",
      babel_describe_bindings = "<prefix>bh",
      babel_mark_block = "<prefix>bm",
      babel_do_key_sequence = "<prefix>bx",
    },
    --- Insert-mode mappings inside org buffers.
    org_insert = {
      meta_return = "<M-CR>",
      --- table: next field; empty headline / item: cycle its level
      insert_tab = "<Tab>",
      table_prev_field = "<S-Tab>",
      table_next_row = "<CR>",
      table_copy_down = "<S-CR>",
    },
    --- Emacs Org keys (org-mode-map), on top of the Vim-style keys above.
    --- Set a section to `false` to disable it, or an entry to `false` to
    --- drop one key.
    emacs_global = {
      agenda = "<C-c>a",
      capture = "<C-c>c",
      store_link = "<C-c>l",
    },
    emacs = {
      -- structure
      insert_heading = "<C-CR>",
      insert_todo_heading = "<C-S-CR>",
      ctrl_c_ret = "<C-c><CR>",
      ctrl_c_star = "<C-c>*",
      table_recalc_buffer = false, -- also C-u C-u C-c * in a table
      ctrl_c_minus = "<C-c>-",
      ctrl_c_caret = "<C-c>^",
      toggle_comment = "<C-c>;",
      insert_structure_template = "<C-c><C-,>",
      insert_drawer = "<C-c><C-x>d",
      insert_footnote = "<C-c><C-x>f",
      emphasize = "<C-c><C-x><C-f>",
      clone_subtree = "<C-c><C-x>c",
      copy_special = "<C-c><C-x><M-w>",
      cut_special = "<C-c><C-x><C-w>",
      paste_special = "<C-c><C-x><C-y>",
      mark_subtree = "<C-c>@",
      indirect_subtree = "<C-c><C-x>b",
      -- elements (M-h org-mark-element is taken by meta_left)
      forward_element = "<M-}>",
      backward_element = "<M-{>",
      up_element = "<C-c><C-^>",
      down_element = "<C-c><C-_>",
      transpose_element = "<C-M-t>",
      next_block = "<C-c><M-f>",
      previous_block = "<C-c><M-b>",
      toggle_fixed_width = "<C-c>:",
      list_make_subtree = "<C-c><C-*>",
      toggle_radio_button = "<C-c><C-x><C-r>",
      toggle_pretty_entities = "<C-c><C-x>\\",
      inlinetask_insert = "<C-c><C-x>t",
      -- visibility
      show_branches = "<C-c><C-k>",
      show_children = "<C-c><Tab>",
      reveal = "<C-c><C-r>",
      force_cycle_archived = "<C-c><C-Tab>",
      copy_visible = "<C-c><C-x>v",
      -- motion
      next_heading = "<C-c><C-n>",
      prev_heading = "<C-c><C-p>",
      next_sibling = "<C-c><C-f>",
      prev_sibling = "<C-c><C-b>",
      goto_parent = "<C-c><C-u>",
      buffer_goto = "<C-c><C-j>",
      -- todo / priority / tags / properties
      todo = "<C-c><C-t>",
      todo_next_sequence = "<C-S-Right>",
      todo_prev_sequence = "<C-S-Left>",
      priority = "<C-c>,",
      set_tags = "<C-c><C-q>",
      set_property = "<C-c><C-x>p",
      set_property_and_value = "<C-c><C-x>P",
      toggle_tags_groups = "<C-c><C-x>q",
      toggle_ordered = "<C-c><C-x>o",
      add_note = "<C-c><C-z>",
      -- dates
      schedule = "<C-c><C-s>",
      deadline = "<C-c><C-d>",
      timestamp = "<C-c>.",
      timestamp_inactive = "<C-c>!",
      toggle_time_stamp_overlays = "<C-c><C-x><C-t>",
      date_today = "<C-c><",
      goto_calendar = "<C-c>>",
      evaluate_time_range = "<C-c><C-y>",
      -- lists
      toggle_checkbox = "<C-c><C-x><C-b>",
      update_statistics = "<C-c>#",
      -- clock / effort / dynamic blocks
      clock_in = { "<C-c><C-x><C-i>", "<C-c><C-x><Tab>" },
      clock_in_last = "<C-c><C-x><C-x>",
      clock_out = "<C-c><C-x><C-o>",
      clock_cancel = "<C-c><C-x><C-q>",
      clock_goto = "<C-c><C-x><C-j>",
      clock_report = "<C-c><C-x><C-r>",
      clock_display = "<C-c><C-x><C-d>",
      set_effort = "<C-c><C-x>e",
      inc_effort = "<C-c><C-x>E",
      clock_modify_effort = "<C-c><C-x><C-e>",
      clock_resolve = "<C-c><C-x><C-z>",
      shift_control_up = "<C-S-Up>",
      shift_control_down = "<C-S-Down>",
      dblock_update = "<C-c><C-x><C-u>",
      column_view = "<C-c><C-x><C-c>",
      insert_columnview = "<C-c><C-x>i",
      insert_dblock = "<C-c><C-x>x",
      -- timers
      timer_start = "<C-c><C-x>0",
      timer_stop = "<C-c><C-x>_",
      timer_pause = "<C-c><C-x>,",
      timer_insert = "<C-c><C-x>.",
      timer_item = "<C-c><C-x>-",
      timer_countdown = "<C-c><C-x>;",
      -- links
      insert_link = "<C-c><C-l>",
      open_link_or_entry = "<C-c><C-o>",
      insert_last_stored_link = "<C-c><M-l>",
      insert_all_links = "<C-c><C-M-l>",
      mark_ring_goto = "<C-c>&",
      next_link = "<C-c><C-x><C-n>",
      prev_link = "<C-c><C-x><C-p>",
      -- refile / archive / attach / agenda files
      refile = "<C-c><C-w>",
      refile_copy = "<C-c><M-w>",
      archive_subtree ={ "<C-c>$", "<C-c><C-x><C-s>", "<C-c><C-x><C-a>" },
      toggle_archive_tag = "<C-c><C-x>a",
      archive_to_sibling = "<C-c><C-x>A",
      attach = "<C-c><C-a>",
      agenda_file_to_front = "<C-c>[",
      agenda_file_remove = "<C-c>]",
      cycle_agenda_files = { "<C-'>", "<C-,>" },
      agenda_set_restriction_lock = "<C-c><C-x><",
      agenda_remove_restriction_lock = "<C-c><C-x>>",
      -- search / export / special
      sparse_tree = "<C-c>/",
      tags_sparse_tree = "<C-c>\\",
      export = "<C-c><C-e>",
      edit_special = "<C-c>'",
      -- tables
      table_create = "<C-c>|",
      table_formula = "<C-c>=",
      table_edit_field = "<C-c>`",
      table_sum = "<C-c>+",
      table_blank_field = "<C-c><Space>",
      table_coordinates = "<C-c>}",
      table_field_info = "<C-c>?",
      table_rotate_marks = "<C-#>",
      table_formula_debugger = "<C-c>{",
      table_ascii_plot = '<C-c>"a',
      table_plot = '<C-c>"g',
      table_el = "<C-c>~",
      -- babel (C-c C-v)
      babel_execute = { "<C-c><C-v>e", "<C-c><C-v><C-e>" },
      babel_execute_buffer = { "<C-c><C-v>b", "<C-c><C-v><C-b>" },
      babel_execute_subtree = { "<C-c><C-v>s", "<C-c><C-v><C-s>" },
      babel_tangle = { "<C-c><C-v>t", "<C-c><C-v><C-t>" },
      babel_remove_result = "<C-c><C-v>k",
      babel_next_block = { "<C-c><C-v>n", "<C-c><C-v><C-n>" },
      babel_prev_block = { "<C-c><C-v>p", "<C-c><C-v><C-p>" },
      babel_tangle_file = { "<C-c><C-v>f", "<C-c><C-v><C-f>" },
      babel_expand = { "<C-c><C-v>v", "<C-c><C-v><C-v>" },
      babel_view_info = "<C-c><C-v>I",
      babel_check = { "<C-c><C-v>c", "<C-c><C-v><C-c>" },
      babel_insert_header_arg = { "<C-c><C-v>j", "<C-c><C-v><C-j>" },
      babel_goto_named = "<C-c><C-v>g",
      babel_goto_named_result = { "<C-c><C-v>r", "<C-c><C-v><C-r>" },
      babel_goto_head = { "<C-c><C-v>u", "<C-c><C-v><C-u>" },
      babel_open_result = { "<C-c><C-v>o", "<C-c><C-v><C-o>" },
      babel_demarcate = { "<C-c><C-v>d", "<C-c><C-v><C-d>" },
      babel_lob_ingest = { "<C-c><C-v>i", "<C-c><C-v><Tab>" },
      babel_load_in_session = { "<C-c><C-v>l", "<C-c><C-v><C-l>" },
      babel_switch_to_session = "<C-c><C-v><C-z>",
      babel_switch_to_session_with_code = "<C-c><C-v>z",
      babel_sha1_hash = { "<C-c><C-v>a", "<C-c><C-v><C-a>" },
      babel_describe_bindings = "<C-c><C-v>h",
      babel_mark_block = "<C-c><C-v><C-M-h>",
      babel_do_key_sequence = { "<C-c><C-v>x", "<C-c><C-v><C-x>" },
    },
    --- Insert-mode Emacs keys.
    emacs_insert = {
      insert_heading = "<C-CR>",
      insert_todo_heading = "<C-S-CR>",
    },
    text_objects = {
      inner_heading = "ih",
      around_heading = "ah",
      inner_subtree = "ir",
      around_subtree = "ar",
    },
    agenda = {
      quit = "q",
      quit_kill = "Q",
      exit = "x",
      redo = "r",
      redo_all = "gr", -- Emacs: g (a Vim prefix key)
      later = "f",
      earlier = "b",
      today = ".",
      goto_date = "gd", -- Emacs: j (kept free for motion)
      day_view = "vd",
      week_view = "vw",
      fortnight_view = "vt",
      month_view = "vm",
      year_view = "vy",
      reset_view = "v<Space>",
      goto = "<Tab>",
      switch_to = "<CR>",
      show = "<Space>",
      show_scroll_down = "<BS>",
      recenter = "L",
      delete_other_windows = "o",
      follow_mode = { "F", "vf" },
      todo = { "t", "<C-c><C-t>" },
      todo_next = "<C-S-Right>",
      todo_prev = "<C-S-Left>",
      priority = { ",", "<C-c>," },
      priority_up = { "+", "<S-Up>" },
      priority_down = { "-", "<S-Down>" },
      set_tags = { ":", "<C-c><C-q>", "<C-c><C-c>" },
      show_tags = "T",
      set_property = "<C-c><C-x>p",
      schedule = { "<C-c><C-s>", "s" },
      deadline = { "<C-c><C-d>", "d" },
      date_later = { "<S-Right>", "<C-c><C-x><Right>" },
      date_earlier = { "<S-Left>", "<C-c><C-x><Left>" },
      date_prompt = ">",
      clock_in = { "I", "<C-c><C-x><C-i>" },
      clock_out = { "O", "<C-c><C-x><C-o>" },
      clock_cancel = { "X", "<C-c><C-x><C-x>" },
      clock_goto = { "J", "<C-c><C-x><C-j>" },
      attach = "<C-c><C-a>",
      set_effort = { "e", "<C-c><C-x>e" },
      timer = ";",
      timer_stop = "<C-c><C-x>_",
      restriction_lock = "<C-c><C-x><",
      remove_restriction_lock = "<C-c><C-x>>",
      refile = { "<C-c><C-w>", "R" },
      archive = { "$", "<C-c>$", "<C-c><C-x><C-s>" },
      archive_default = { "a", "<C-c><C-x><C-a>" },
      archive_sibling = "<C-c><C-x>A",
      toggle_archive_tag = "<C-c><C-x>a",
      kill = "<C-k>",
      open_link = "<C-c><C-o>",
      add_note = { "z", "<C-c><C-z>" },
      log_mode = { "l", "vl" },
      log_all_mode = "vL",
      clockcheck_mode = "vc",
      clockreport_mode = { "C", "vR" },
      entry_text_mode = { "E", "vE" },
      archives_mode = "va",
      archives_files_mode = "vA",
      inactive_mode = "v[",
      time_grid = { "G", "vG" },
      toggle_deadlines = { "!", "v!" },
      dim_blocked = "#",
      filter = "/",
      filter_tag = "\\",
      filter_category = "<",
      filter_regexp = "=",
      filter_effort = "_",
      filter_top_headline = "^",
      filter_remove = "|",
      limit = "~",
      query_add = "[",
      query_subtract = "]",
      query_add_re = "{",
      query_subtract_re = "}",
      mark = "m",
      unmark = "u",
      unmark_all = "U",
      toggle_mark = "<M-m>",
      mark_all = "*",
      toggle_mark_all = "<M-*>",
      mark_regexp = "%",
      bulk_action = "B",
      next_item = "n",
      prev_item = "p",
      next_date_line = "<C-c><C-n>",
      prev_date_line = "<C-c><C-p>",
      forward_block = "<C-Down>",
      backward_block = "<C-Up>",
      drag_line_forward = "<M-Down>",
      drag_line_backward = "<M-Up>",
      append = "A",
      columns = "<C-c><C-x><C-c>",
      calendar = "c",
      save_all = "<C-x><C-s>",
      capture = "K", -- Emacs: k (kept free for motion)
      export = "<C-x><C-w>",
      help = "g?",
    },
    capture = {
      finalize = { "<C-c><C-c>", "<prefix>w" },
      kill = { "<C-c><C-k>", "<prefix>k" },
      refile = { "<C-c><C-w>", "<prefix>r" },
    },
    edit_src = {
      save_exit = { "<C-c>'", "<prefix>'" },
      abort = { "<C-c><C-k>", "<prefix>k" },
    },
  },
}

---@type org.config.Resolved
M.opts = vim.deepcopy(M.defaults)

--- Replace `dst` contents with `src` merged on top, in place.
local function merge_into(dst, src)
  for k, v in pairs(src) do
    -- lists replace, dicts merge
    if type(v) == "table" and type(dst[k]) == "table" and not vim.islist(v) and not vim.islist(dst[k]) then
      merge_into(dst[k], v)
    elseif type(v) == "table" and type(dst[k]) == "table" and vim.tbl_isempty(v) and not vim.islist(dst[k]) then
      -- `{}` given for a dict option: keep defaults
    else
      dst[k] = v
    end
  end
end

--- Merge user options into `M.opts`. Dict options merge key by key; lists
--- (and `capture.templates`) replace the default; `{}` for a dict option
--- keeps its defaults; `babel.languages = { lang = false }` removes a
--- language.
---@param opts? org.Config
---@return org.config.Resolved
function M.setup(opts)
  opts = opts or {}
  -- `capture.templates` and `agenda.custom_commands` are replaced wholesale
  -- when given, so users aren't stuck with the default template.
  local templates = opts.capture and opts.capture.templates
  local fresh = vim.deepcopy(M.defaults)
  for k in pairs(M.opts) do
    M.opts[k] = nil
  end
  merge_into(M.opts, fresh)
  merge_into(M.opts, opts)
  if templates then
    M.opts.capture.templates = templates
  end
  if opts.babel and opts.babel.languages then
    -- languages merge per key; allow `false` to remove one
    for k, v in pairs(opts.babel.languages) do
      if v == false then
        M.opts.babel.languages[k] = nil
      end
    end
  end
  return M.opts
end

--- Resolve a mapping value to a list of lhs (with <prefix> expanded).
---@param value string|string[]|false|nil
---@return string[]
function M.lhs_list(value)
  if not value then
    return {}
  end
  local list = type(value) == "table" and value or { value }
  local prefix = M.opts.mappings.prefix or "<leader>o"
  local out = {}
  for _, lhs in ipairs(list) do
    if lhs then
      out[#out + 1] = (lhs:gsub("<prefix>", prefix))
    end
  end
  return out
end

return M
