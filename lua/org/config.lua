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
  --- A flat list containing a `"|"` element is also accepted, and
  --- `{ type = "Fred Sara | DONE" }` is a type sequence (Emacs `(type ...)`).
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
  --- Functions(new, old) -> string|nil choosing the state a change goes to
  --- (org-todo-get-default-hook): the first string returned replaces the
  --- new state ("" = no keyword). Also used for M-S-RET (old is nil).
  todo_get_default_hooks = {},
  --- Functions(n_done, n_not_done, target) called for every ancestor whose
  --- TODO statistics cookie is updated after a state change, with the
  --- ancestor as `target` { bufnr, lnum } (org-after-todo-statistics-hook).
  after_todo_statistics_hooks = {},
  --- Functions(target) called after each state change that updates TODO
  --- statistics, even without a cookie (org-todo-statistics-hook).
  todo_statistics_hooks = {},
  --- C-c C-t uses the fast-selection menu when keywords have keys
  --- (org-use-fast-todo-selection `auto`); `false` always cycles.
  use_fast_todo_selection = "auto",
  --- <S-Left>/<S-Right> on a headline are real state changes (logged and
  --- blocked); `false` changes the keyword without logging or blocking
  --- (org-treat-S-cursor-todo-selection-as-state-change).
  treat_S_cursor_todo_selection_as_state_change = true,
  --- M-S-RET / C-S-RET set the new heading's keyword as a state change, so
  --- it is logged (org-treat-insert-todo-heading-as-state-change).
  treat_insert_todo_heading_as_state_change = false,
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
  --- CLOSED records the time too; `false` records the date only
  --- (org-log-done-with-time).
  log_done_with_time = true,
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
  --- Without a log drawer, notes go after the clock lines and drawers
  --- that follow the headline (org-log-state-notes-insert-after-drawers).
  log_state_notes_insert_after_drawers = false,
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
  --- CLOSED and log notes of a TODO state change record the last clock-out
  --- time of the subtree (org-use-last-clock-out-time-as-effective-time).
  use_last_clock_out_time_as_effective_time = false,
  --- In Visual mode, C-c C-t, C-c C-s, C-c C-d and the archiving commands
  --- act on every headline of the selection: `true`, `"start-level"` (only
  --- headlines of the first one's level) or `false`; a match string acts
  --- like `true`, as in Emacs 9.8
  --- (org-loop-over-headlines-in-active-region).
  loop_over_headlines_in_active_region = true,

  ---------------------------------------------------------------------------
  -- Priorities & tags
  ---------------------------------------------------------------------------
  priority_highest = "A",
  priority_lowest = "C",
  priority_default = "B",
  --- `false` disables the priority commands (org-priority-enable-commands).
  priority_enable_commands = true,
  --- Shifting a headline without cookie starts at the default priority;
  --- `false` starts one step past it (org-priority-start-cycle-with-default).
  priority_start_cycle_with_default = true,
  --- fn(headline_line) -> number replacing the priority value used for
  --- sorting (org-priority-get-priority-function); nil uses the cookie.
  priority_get_priority_function = nil,
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
  --- Fast tag selection (org-use-fast-tag-selection): `"auto"` when some
  --- tag has a key, `true` always, `false` never.
  use_fast_tag_selection = "auto",
  --- Tags without a key shown by fast selection, counting the tags with
  --- keys and the tags in groups (org-fast-tag-selection-maximum-tags).
  fast_tag_selection_maximum_tags = 56,
  --- Tag completion offers the tags of every agenda file instead of the
  --- current buffer's (org-complete-tags-always-offer-all-agenda-tags).
  complete_tags_always_offer_all_agenda_tags = false,
  --- Global tag list offered for completion. Strings may contain fast keys,
  --- e.g. `"work(w)"`, and `"{" ... "}"` for mutually exclusive groups.
  tags = {},
  --- Tags always available, like `tags` but not replaced by #+TAGS
  --- (org-tag-persistent-alist); `#+STARTUP: noptag` turns them off.
  tags_persistent = {},
  --- Comparator fn(a, b) -> boolean, or a list of them, sorting the tags
  --- set on a headline (org-tags-sort-function); "hierarchy", "string<"
  --- and "string>" name org-tags-sort-hierarchy, org-string< and
  --- org-string>. nil keeps their order.
  tags_sort_function = nil,
  --- Column tags are aligned to. Negative = right-align to that column.
  tags_column = -77,
  --- Realign tags after edits (org-auto-align-tags).
  auto_align_tags = true,
  --- Toggling ORDERED (C-c C-x o) also toggles a tag: `true` (ORDERED) or
  --- a tag name (org-track-ordered-property-with-tag).
  track_ordered_property_with_tag = false,
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
  --- Functions adjusting values set with set_property, by property name:
  --- `{ Remaining = function(value) return ... end }`
  --- (org-properties-postprocess-alist).
  properties_postprocess = {},
  --- Separators joining `PROP` and `PROP+` values: a list of
  --- `{ { "NAME", ... } or "regexp", "separator" }`; a space otherwise
  --- (org-property-separators).
  property_separators = {},
  --- Properties hidden and shown again by
  --- toggle_custom_properties_visibility (org-custom-properties).
  custom_properties = {},
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
  --- Emacs regexp of the cells that count as numbers for right alignment
  --- (org-table-number-regexp).
  table_number_regexp = "^\\([<>]?[-+^.0-9]*[0-9][-+^.0-9eEdDx()%:]*\\|[<>]?[-+]?0[xX][[:xdigit:].]+"
    .. "\\|[<>]?[-+]?[0-9]+#[0-9a-zA-Z.]+\\|nan\\|[-+u]?inf\\)$",
  --- Realign the table on <Tab>, <S-Tab>, <CR> and when leaving Insert
  --- mode (org-table-automatic-realign).
  table_automatic_realign = true,
  --- <Tab> jumps over an hline instead of adding a row before it
  --- (org-table-tab-jumps-over-hlines).
  table_tab_jumps_over_hlines = true,
  --- Typing right after <Tab>, <S-Tab>, <CR> or C-c C-c in Insert mode
  --- replaces the field's text (org-table-auto-blank-field).
  table_auto_blank_field = true,
  --- Recalculate a `#` row on <Tab>, <CR> and C-c C-c
  --- (org-table-allow-automatic-line-recalculation).
  table_allow_automatic_line_recalculation = true,
  --- Size of a new table, "COLUMNSxROWS" (org-table-default-size).
  table_default_size = "5x2",
  --- Largest region `create_or_convert` turns into a table
  --- (org-table-convert-region-max-lines).
  table_convert_region_max_lines = 999,
  --- Format of formula results, `%s` being the value, e.g. "~%s~"
  --- (org-table-formula-field-format).
  table_formula_field_format = "%s",
  --- Replace `$name` constants, parameters and column names in formulas
  --- (org-table-formula-use-constants).
  table_formula_use_constants = true,
  --- Relative row references crossing an hline: true (allowed), false
  --- (stop at the hline) or "error" (org-table-relative-ref-may-cross-hline).
  table_relative_ref_may_cross_hline = true,
  --- Calc modes of table formulas (org-calc-default-modes): working
  --- precision, float display `{ "float"|"fix"|"sci"|"eng", digits }`,
  --- "deg" or "rad", and fractions.
  calc_default_modes = { internal_prec = 12, float_format = { "float", 8 }, angle_mode = "deg", prefer_frac = false },
  --- In orgtbl-mode, typing into a field overwrites its padding so the
  --- table keeps its alignment, and auto-blanks fields (orgtbl-optimized).
  orgtbl_optimized = true,
  --- Text shown at the end of a shrunk column (org-table-shrunk-column-indicator).
  table_shrunk_column_indicator = "…",
  --- Shrink the columns with a width cookie of every table when a file is
  --- opened; `#+STARTUP: shrink` / `noshrink` (org-startup-shrink-all-tables).
  startup_shrink_all_tables = false,
  --- Align every table when a file is opened; `#+STARTUP: align` /
  --- `noalign` (org-startup-align-all-tables).
  startup_align_all_tables = false,
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
  --- Extra (or replaced) `#+PLOT: type:NAME` plot types
  --- (org-plot/preset-plot-types): `{ NAME = { plot_func = fun(rows,
  --- data_file, ncols, opts, plot_str): string[], plot_cmd?, plot_str?,
  --- plot_pre? (string or function), data_dump? (function returning the
  --- data text), check_ind_type? } }`. 2d, 3d, grid and radar are built in.
  plot_preset_plot_types = {},
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
  --- Column view display: "overlay" draws the columns over the headlines
  --- of the org buffer like Emacs org-columns, "table" shows a table in a
  --- split.
  columns_view = "overlay",
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
  --- Text ending a truncated column view field (org-columns-ellipses).
  columns_ellipses = "..",
  effort_property = "Effort",
  --- Durations in clock tables, clock sums, column summaries and efforts
  --- (Emacs `org-duration-format`): "d h:mm" (the Emacs default
  --- `(("d" . nil) (special . h:mm))`) writes "1d 2:30" from one day on,
  --- "h:mm" "26:30", "h:mm:ss" "26:30:00", or a list of `{ unit, required }`
  --- entries plus `{ "special", "h:mm" | "h:mm:ss" | decimals }` and
  --- "compact", e.g. `{ { "h", true }, { "special", 2 } }` → "26.50h".
  duration_format = "d h:mm",
  --- Minutes per duration unit (Emacs `org-duration-units`); add units or
  --- change values, e.g. `d = 480` for 8-hour work days. min/h/d keep their
  --- standard values for timestamp ages (canonical units).
  duration_units = { min = 1, h = 60, d = 1440, w = 10080, m = 43200, y = 525960 },
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
  --- Turn on the Beamer editing mode when a file is opened
  --- (org-startup-with-beamer-mode; #+STARTUP: beamer).
  startup_with_beamer_mode = false,
  --- Let visibility cycling open subtrees tagged :ARCHIVE:
  --- (org-cycle-open-archived-trees).
  cycle_open_archived_trees = false,
  --- Sparse trees open subtrees tagged :ARCHIVE: to show matches in them;
  --- false keeps them folded (org-sparse-tree-open-archived-trees).
  sparse_tree_open_archived_trees = false,
  --- Dates the before/after/range sparse trees look at: nil (SCHEDULED and
  --- DEADLINE), "all", "active", "inactive", "scheduled", "deadline" or
  --- "closed"; `c` in the sparse-tree menu cycles them
  --- (org-sparse-tree-default-date-type).
  sparse_tree_default_date_type = nil,
  --- Heading that collects footnote definitions (created when missing)
  --- (org-footnote-section; #+STARTUP: fnlocal).
  --- false = put each definition at the end of the reference's section.
  footnote_section = "Footnotes",
  --- Indent body text to the headline level (org-adapt-indentation).
  adapt_indentation = false,
  --- A new day node of a date tree gets a time stamp of its date
  --- (org-datetree-add-timestamp): false | "active" | "inactive".
  datetree_add_timestamp = false,
  --- Indentation added to src block contents in the edit buffer
  --- (org-src-content-indentation).
  edit_src_content_indentation = 2,
  --- Keep the indentation of src block lines as written: no common
  --- indentation is removed for evaluation, tangling or editing
  --- (org-src-preserve-indentation). The `-i` switch does it per block.
  src_preserve_indentation = false,
  --- Show "Edit, then exit with ... or abort with ..." in the winbar of
  --- edit buffers (org-edit-src-persistent-message).
  edit_src_persistent_message = true,
  --- Write an edit buffer back to the Org buffer after this many seconds
  --- without changes; 0 = never (org-edit-src-auto-save-idle-delay).
  edit_src_auto_save_idle_delay = 0,
  --- Auto-save the contents of edit buffers to an org-src-XXXXXX-%Y-%d-%m.txt
  --- file next to the Org file (org-edit-src-turn-on-auto-save).
  edit_src_turn_on_auto_save = false,
  --- C-c ' on a block that already has an edit buffer asks before going back
  --- to it ("n" discards it and opens a new one); false = go back at once
  --- (org-src-ask-before-returning-to-edit-buffer).
  src_ask_before_returning_to_edit_buffer = true,
  --- Filetype (or function(bufnr)) of the edit buffer of `: ` fixed-width
  --- areas; nil = none (org-edit-fixed-width-region-mode; Emacs: artist-mode).
  edit_fixed_width_region_mode = nil,
  --- Filetype of the edit buffer and highlighting of src blocks by language;
  --- "" = none (org-src-lang-modes). Other languages use the filetype of
  --- their extension.
  src_lang_modes = {
    C = "c",
    ["C++"] = "cpp",
    asymptote = "asy",
    beamer = "tex",
    calc = "",
    cpp = "cpp",
    ditaa = "",
    desktop = "desktop",
    dot = "dot",
    elisp = "lisp",
    ocaml = "ocaml",
    screen = "sh",
    sqlite = "sql",
    toml = "toml",
    shell = "sh",
    ash = "sh",
    sh = "sh",
    bash = "sh",
    jsh = "sh",
    bash2 = "sh",
    dash = "sh",
    dtksh = "sh",
    ksh = "sh",
    es = "sh",
    rc = "sh",
    itcsh = "tcsh",
    tcsh = "tcsh",
    jcsh = "csh",
    csh = "csh",
    ksh88 = "sh",
    oash = "sh",
    pdksh = "sh",
    mksh = "sh",
    posix = "sh",
    wksh = "sh",
    wsh = "sh",
    zsh = "zsh",
    rpm = "sh",
  },
  --- TAB on a line of a src block indents it with the language's indentation
  --- (indentexpr of its filetype) (org-src-tab-acts-natively).
  src_tab_acts_natively = true,
  --- Default format of coderef labels in src and example blocks; `-l "fmt"`
  --- overrides it per block (org-coderef-label-format).
  coderef_label_format = "(ref:%s)",
  --- Text appended to folded headlines (org-ellipsis).
  ellipsis = "...",
  --- Entities of your own, before the built-in ones (org-entities-user):
  --- `{ { name, latex, latex_math, html, ascii, latin1, utf8 } }`, e.g.
  --- `{ { "snowman", "\\diamond", true, "&#9731;", "[snowman]", "", "☃" } }`.
  entities_user = {},
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
  --- Names of the bookmarks capture and refile set, saved across sessions
  --- (org-bookmark-names-plist); false for none.
  bookmark_names = {
    last_capture = "org-capture-last-stored",
    last_refile = "org-refile-last-stored",
    last_capture_marker = "org-capture-last-stored-marker",
  },
  --- buffer_goto (org-goto-interface): "outline" (browse a copy of the
  --- buffer in overview, <CR> jumps) or "outline-path-completion".
  goto_interface = "outline",
  --- Deepest headlines offered by the completion interface of buffer_goto
  --- (org-goto-max-level).
  goto_max_level = 5,
  --- In the outline interface, typing searches the headlines
  --- (org-goto-auto-isearch); else n p f b u move and q quits.
  goto_auto_isearch = true,
  --- How sorting compares text (org-sort-function): "collate" (the
  --- collation locale, like string-collate-lessp), "fallback" (character
  --- codes, org-sort-function-fallback) or function(a, b, ignore_case).
  --- On macOS "collate" compares character codes, like Emacs there.
  sort_function = "collate",
  --- TAB on a list item folds its children and text
  --- (org-cycle-include-plain-lists); "integrate" also treats items as
  --- children of their headline when cycling it; false never folds items.
  cycle_include_plain_lists = true,
  --- Plain lists (org-list-*).
  lists = {
    --- Single-letter bullets `a.`, `B)` and counters `[@c]`
    --- (org-list-allow-alphabetical).
    allow_alphabetical = false,
    --- Ordered bullet terminators: true (both), "." or ")"
    --- (org-plain-list-ordered-item-terminator).
    ordered_item_terminator = true,
    --- Bullet given to items when they are demoted, e.g.
    --- `{ ["-"] = "+", ["+"] = "-" }` (org-list-demote-modify-bullet).
    demote_modify_bullet = {},
    --- Emacs regexp matching bullets followed by two spaces, or nil
    --- (org-list-two-spaces-after-bullet-regexp).
    two_spaces_after_bullet_regexp = nil,
    --- Extra indentation of sub-lists (org-list-indent-offset).
    indent_offset = 0,
    --- Automatic rules (org-list-automatic-rules): `checkbox` updates
    --- statistics cookies after checkbox changes, `indent` lets the first
    --- item move the whole list and turns `*` into `-` at column 0.
    automatic_rules = { checkbox = true, indent = true },
    --- Item motions and moves wrap around the list (org-list-use-circular-motion).
    use_circular_motion = false,
    --- Checkbox cookies count direct children only; false counts every box
    --- below (org-checkbox-hierarchical-statistics).
    checkbox_hierarchical_statistics = true,
  },
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
  --- The edits catch_invisible_edits checks, by command: `self_insert`
  --- (typed text), `delete_backward_char` (<BS> in Insert mode),
  --- `delete_char` (<Del>), `return` (<CR>) or any action name, each
  --- "insert", "delete" or "delete-backward"; false removes one
  --- (org-fold-catch-invisible-edits-commands).
  catch_invisible_edits_commands = {
    self_insert = "insert",
    delete_backward_char = "delete-backward",
    delete_char = "delete",
    meta_return = "insert",
    ["return"] = "insert",
  },
  --- TAB at the very start of the buffer, not on a headline, cycles the
  --- global visibility (org-cycle-global-at-bob).
  cycle_global_at_bob = false,
  --- Deepest level cycled as a headline; deeper ones are text for TAB.
  --- nil = all (org-cycle-max-level).
  cycle_max_level = nil,
  --- TAB on an entry without children goes from FOLDED straight to
  --- SUBTREE (org-cycle-skip-children-state-if-no-children).
  cycle_skip_children_state_if_no_children = true,
  --- How much is shown around a location reached by a jump, per context
  --- (agenda, org-goto, occur-tree, tags-tree, link-search, mark-goto,
  --- bookmark-jump, isearch, default): "minimal", "local", "ancestors",
  --- "ancestors-full", "lineage", "tree" or "canonical"; or one of them
  --- for every context (org-fold-show-context-detail).
  fold_show_context_detail = {
    agenda = "local",
    ["bookmark-jump"] = "lineage",
    isearch = "lineage",
    default = "ancestors",
  },
  --- Sparse-tree regexp searches ignore case: true, false or "smart"
  --- (only when the regexp has no upper case) (org-occur-case-fold-search).
  occur_case_fold_search = true,
  --- Any change to the buffer removes the highlights of sparse-tree
  --- searches and clock_display; else C-c C-c does
  --- (org-remove-highlights-with-change).
  remove_highlights_with_change = true,
  --- `beginning_of_line` / `end_of_line` (C-a / C-e) on headlines and
  --- items (org-special-ctrl-a/e): false, true (first to the title start /
  --- before the tags), "reversed" (there on a repeated key), or
  --- `{ a = ..., e = ... }` per key.
  special_ctrl_a_e = false,
  --- `kill_line` (C-k) in a headline title kills up to the tags, on the
  --- tags the tags (org-special-ctrl-k).
  special_ctrl_k = false,
  --- `kill_line` on a folded headline kills its hidden subtree: false
  --- (allow), true (ask) or "error" (org-ctrl-k-protect-subtree).
  ctrl_k_protect_subtree = false,
  --- Setting the org filetype on an empty file that is not named *.org
  --- inserts the Emacs mode line `#    -*- mode: org -*-`, which makes it
  --- open as org from then on (org-insert-mode-line-in-empty-file).
  insert_mode_line_in_empty_file = false,
  --- <M-CR> and the other heading insertions put the new headline after
  --- the current subtree, like <C-CR> (org-insert-heading-respect-content).
  insert_heading_respect_content = false,
  --- Promoting a level-1 headline turns its `* ` into `# ` (a comment)
  --- instead of refusing (org-allow-promoting-top-level-subtree).
  allow_promoting_top_level_subtree = false,
  --- Keep the Visual selection after <M-h> / <M-l> / <M-k> / <M-j>
  --- (org-edit-keep-region): true, false, or per command.
  edit_keep_region = { meta_left = true, meta_right = true, meta_up = true, meta_down = true },
  --- `p` / `P` of whole subtrees folds them, unless that would hide the
  --- text after them (org-yank-folded-subtrees).
  yank_folded_subtrees = true,
  --- `p` / `P` of whole subtrees adjusts their level to the visible
  --- headlines around, like paste_subtree (org-yank-adjusted-subtrees).
  yank_adjusted_subtrees = false,
  --- Single-letter commands at the start of a headline
  --- (org-use-speed-commands). See `:h org-speed-commands`.
  use_speed_commands = false,
  --- Extra or changed speed commands: `{ key = action name | function | false }`.
  speed_commands = {},
  --- Functions(key) deciding which speed command a key runs, tried in
  --- order until one returns a command (an action name or a function); the
  --- names of the built-in ones: headline commands and the Babel keys at a
  --- `#+begin_src` line (org-speed-command-hook).
  speed_command_hook = { "org-speed-command-activate", "org-babel-speed-command-activate" },
  --- Headlines of this level or deeper are inline tasks
  --- (org-inlinetask-min-level). false turns inline tasks off, like Emacs
  --- without the org-inlinetask module; Emacs uses 15 once it is loaded.
  inlinetask_min_level = false,
  --- Show the first star of inline tasks as a marker
  --- (org-inlinetask-show-first-star).
  inlinetask_show_first_star = false,
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
  --- Refill the paragraphs that lost an inline footnote when normalizing
  --- (org-footnote-fill-after-inline-note-extraction), at `textwidth`
  --- (70 when 0).
  footnote_fill_after_inline_note_extraction = false,
  --- Days before a deadline it starts showing up in the agenda.
  deadline_warning_days = 14,
  --- Days a scheduled entry is hidden after its date unless it has its own
  --- `-Nd` delay; a negative value applies even then
  --- (org-scheduled-delay-days).
  scheduled_delay_days = 0,
  --- { rounding of the current time in date prompts, minute step of
  --- <S-Up>/<S-Down> } (org-time-stamp-rounding-minutes). A count steps by
  --- exactly that many minutes.
  time_stamp_rounding_minutes = { 0, 5 },
  --- Date prompts interpret incomplete dates in the future: `true` (a past
  --- day/month means next month/year), `"time"` (also a past time today
  --- means tomorrow) or `false` (org-read-date-prefer-future).
  read_date_prefer_future = true,
  --- Date prompts show the calendar; false = only a "Date+time [default]: "
  --- prompt (org-read-date-popup-calendar; the Emacs alias
  --- `popup_calendar_for_date_prompt = false` works too).
  read_date_popup_calendar = true,
  --- Show what a typed date means while typing it in the calendar
  --- (org-read-date-display-live).
  read_date_display_live = true,
  --- Key of the calendar opened by `goto_calendar` that shows the agenda of
  --- its date: "default" (`c`), another key, or false
  --- (org-calendar-to-agenda-key).
  calendar_to_agenda_key = "default",
  --- Key of that calendar adding a diary entry for its date to
  --- `agenda.diary_entry_file`, when that is an Org file
  --- (org-calendar-insert-diary-entry-key).
  calendar_insert_diary_entry_key = "i",
  --- <S-Down> makes timestamps later and <S-Up> earlier
  --- (org-edit-timestamp-down-means-later).
  edit_timestamp_down_means_later = false,
  --- Display timestamps with `time_stamp_custom_formats` (format-time-string
  --- formats for dates and date+time; brackets around them are dropped in
  --- the buffer and kept in exports); toggled by `toggle_time_stamp_overlays`
  --- (org-display-custom-times, org-timestamp-custom-formats). Exports of a
  --- buffer with the display on use the formats (org-timestamp-translate).
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
  --- What `archive_subtree_default` (C-c C-x C-a, the agenda's `a`) does
  --- (org-archive-default-command): "archive_subtree" | "archive_to_sibling"
  --- | "set_tag" | function(target).
  archive_default_command = "archive_subtree",
  --- Save the archive file after `archive_subtree` (org-archive-subtree-save-file-p):
  --- true | false | "from_org" (not from the agenda) | "from_agenda" (only
  --- from the agenda). A location in the same buffer is never saved.
  archive_subtree_save_file = "from_org",
  --- Mark archived entries done: false | true (first done keyword) | a done
  --- keyword (org-archive-mark-done).
  archive_mark_done = false,
  --- Text put at the top of a new archive file, `%s` = the source file;
  --- false for none (org-archive-file-header-format).
  archive_file_header_format = "\nArchived entries from file %s\n\n",
  --- Window used for special buffers: "float" | "split" | "vsplit" | "tab" | "current"
  win_split_mode = "float",
  --- Where indirect_subtree shows the subtree (org-indirect-buffer-display):
  --- "other-window" (a split: `win_split_mode` when it is "split", "vsplit"
  --- or "tab"), "current-window", "new-frame" (a new tab) or
  --- "dedicated-frame" (one tab, reused).
  indirect_buffer_display = "other-window",
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
    --- Leave out COMMENT subtrees (org-agenda-skip-comment-trees).
    skip_comment_trees = true,
    --- function(headline) -> true to leave the entry out of every agenda
    --- view, before a block's `skip` (org-agenda-skip-function-global).
    skip_function_global = nil,
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
    --- The todo_ignore_* options compare times to now in seconds, not in
    --- days (org-agenda-todo-ignore-time-comparison-use-seconds).
    todo_ignore_time_comparison_use_seconds = false,
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
    --- Format of the TODO keyword, e.g. "%-12s"; "" hides it
    --- (org-agenda-todo-keyword-format).
    todo_keyword_format = "%-1s",
    --- Highlight priorities: "cookies" (the cookie), true (from the cookie
    --- to the end of the line), a table { A = face, ... } (faces like
    --- `ui.priority_faces`, to the end of the line) or false
    --- (org-agenda-fontify-priorities). The highest priority is bold, the
    --- lowest italic.
    fontify_priorities = "cookies",
    --- { fraction, highlight group } pairs for deadline lines: the first
    --- whose fraction is at most the part of the warning period that has
    --- passed (org-agenda-deadline-faces).
    deadline_faces = {
      { 1.0, "OrgAgendaDeadline" },
      { 0.5, "OrgAgendaDeadlineUpcoming" },
      { 0.0, "OrgAgendaDeadlineDistant" },
    },
    --- function(date) -> highlight group or nil for a day header
    --- (org-agenda-day-face-function).
    day_face_function = nil,
    --- Emacs regexp: its match in the text of a %%(diary sexp) entry is
    --- shown as the leader (org-agenda-diary-sexp-prefix).
    diary_sexp_prefix = nil,
    --- Remove the date range from the text of block entries
    --- (org-agenda-remove-timeranges-from-blocks).
    remove_timeranges_from_blocks = false,
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
    --- Highlight the whole subtree of a restriction lock, not only its
    --- headline (org-agenda-restriction-lock-highlight-subtree).
    restriction_lock_highlight_subtree = true,
    --- Where the agenda opens: "split" (org-agenda-window-setup
    --- reorganize-frame), "vsplit", "current", "only", "tab", "float".
    window = "split",
    --- { min, max } height of the "split" agenda window as fractions of
    --- the editor height; it fits its lines in between
    --- (org-agenda-window-frame-fractions).
    window_frame_fractions = { 0.5, 0.75 },
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
    bulk_mark_char = ">", -- org-agenda-bulk-mark-char
    --- Commands (schedule, deadline, >, t, archive, <C-k>, set property /
    --- effort) act on every entry of a Visual selection: true, false,
    --- "start-level" (entries of the first one's level) or an Emacs regexp
    --- the agenda lines must match
    --- (org-agenda-loop-over-headlines-in-active-region).
    loop_over_headlines_in_active_region = true,
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
    --- Rules offering custom commands only in some buffers
    --- (org-agenda-custom-commands-contexts), e.g.
    --- `{ { "p", { { in_mode = "org" } } }, { "q", "r", { { in_file = "work" } } } }`.
    custom_commands_contexts = {},
    --- Show the match of custom commands in the dispatcher
    --- (org-agenda-menu-show-matcher).
    menu_show_matcher = true,
    --- Custom commands in two columns in the dispatcher
    --- (org-agenda-menu-two-columns).
    menu_two_columns = false,
    --- Columns format of the agenda column view; nil = the first agenda
    --- file's (org-agenda-overriding-columns-format).
    overriding_columns_format = nil,
    view_columns_initially = false, -- org-agenda-view-columns-initially
    --- Show column summaries on date lines (org-agenda-columns-show-summaries).
    columns_show_summaries = true,
    --- In the agenda column view, an appointment without an effort counts
    --- its duration as effort (org-agenda-columns-add-appointments-to-effort-sum).
    columns_add_appointments_to_effort_sum = false,
    --- Extra files for the search view; "agenda-archives" adds the archive
    --- files (org-agenda-text-search-extra-files).
    text_search_extra_files = {},
    --- Skip agenda files that do not exist instead of asking to remove
    --- them (org-agenda-skip-unavailable-files).
    skip_unavailable_files = false,
    search_view_always_boolean = false, -- org-agenda-search-view-always-boolean
    --- Register receiving the search query built with [ ] { }
    --- (org-agenda-query-register); false for none.
    query_register = "o",
    search_view_force_full_words = false, -- org-agenda-search-view-force-full-words
    search_view_max_outline_level = 0, -- org-agenda-search-view-max-outline-level
    --- Body lines shown under each entry in entry text mode (E)
    --- (org-agenda-entry-text-maxlines).
    entry_text_maxlines = 5,
    --- Emacs regexps whose matches are removed from the entry text
    --- (org-agenda-entry-text-exclude-regexps).
    entry_text_exclude_regexps = {},
    --- Text before each entry text line (org-agenda-entry-text-leaders).
    entry_text_leaders = "    > ",
    --- Body lines added under each entry when the agenda is written to a
    --- file (org-agenda-add-entry-text-maxlines).
    add_entry_text_maxlines = 0,
    --- function(lines, path) run before the agenda is written: changes
    --- `lines` or returns new ones (org-agenda-before-write-hook; the User
    --- autocmd OrgAgendaBeforeWrite fires too).
    before_write_hook = nil,
    --- Replaces the <style> section of agendas written as HTML
    --- (org-agenda-export-html-style).
    export_html_style = nil,
    --- Ask before `<C-k>` deletes an entry longer than this many lines
    --- (org-agenda-confirm-kill). false = never ask.
    confirm_kill = 1,
    --- One <S-Right> on a date in the past moves it to today
    --- (org-agenda-move-date-from-past-immediately-to-today).
    move_date_from_past_immediately_to_today = true,
    start_with_log_mode = false, -- false | true | "all" | "clockcheck" (org-agenda-start-with-log-mode)
    --- Add the first line of a clock or state note to log items
    --- (org-agenda-log-mode-add-notes).
    log_mode_add_notes = true,
    start_with_follow_mode = false, -- org-agenda-start-with-follow-mode
    --- Follow mode shows the entry's subtree in an edit buffer
    --- (org-agenda-follow-indirect).
    follow_indirect = false,
    --- A left click goes to the entry like a middle click
    --- (org-agenda-mouse-1-follows-link).
    mouse_1_follows_link = false,
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
    --- false | "trees" (archived trees, `va`) | true (also the archive
    --- files, `vA`) (org-agenda-start-with-archives-mode).
    start_with_archives_mode = false,
    --- Dim TODOs blocked by enforce_todo_dependencies / checkboxes:
    --- true | false | "invisible" (org-agenda-dim-blocked-tasks).
    dim_blocked_tasks = true,
    --- Location for sunrise and sunset (`S` in the agenda): degrees, north
    --- and east positive (calendar-latitude, calendar-longitude); asked for
    --- when unset. The name defaults to "40.7N, 74.0W"
    --- (calendar-location-name).
    calendar_latitude = nil,
    calendar_longitude = nil,
    calendar_location_name = nil,
    --- How dates are written in the diary file and in diary sexp arguments,
    --- and shown by the calendar strings: "american" (month/day/year),
    --- "european" (day/month/year) or "iso" (calendar-date-style).
    calendar_date_style = "american",
    --- Minutes before sunset of `%%(diary-hebrew-sabbath-candles)`
    --- (diary-hebrew-sabbath-candles-minutes).
    hebrew_sabbath_candles_minutes = 18,
    --- Show the entries of the Emacs diary file in the date agenda
    --- (org-agenda-include-diary); `D` toggles it.
    include_diary = false,
    --- The Emacs diary file (diary-file); nil = ~/diary if it exists, else
    --- the diary file of the Emacs user directory (~/.emacs.d/diary or
    --- ~/.config/emacs/diary).
    diary_file = nil,
    --- Where `i` in the agenda adds entries (org-agenda-diary-file):
    --- "diary-file" (the Emacs diary file, `diary_file`) or an Org file.
    diary_entry_file = "diary-file",
    --- Where entries go in an Org `diary_entry_file`: "date-tree" (first
    --- child of the date), "date-tree-last" or "top-level"
    --- (org-agenda-insert-diary-strategy).
    insert_diary_strategy = "date-tree",
    --- Move a time at the start of a day entry into its timestamp
    --- (org-agenda-insert-diary-extract-time).
    insert_diary_extract_time = false,
    --- Show the day's holidays as diary entries (diary-show-holidays-flag).
    diary_show_holidays = true,
    --- Read `#include "FILE"` lines of the diary file (Emacs:
    --- diary-include-other-diary-files in diary-list-entries-hook).
    diary_include_files = false,
    --- Also read Hebrew (H), Islamic (I), Bahá’í (B) and Chinese (C) date
    --- entries: a list of "hebrew", "islamic", "bahai", "chinese"
    --- (diary-nongregorian-listing-hook).
    diary_nongregorian = {},
    --- Holidays shown by `%%(org-calendar-holiday)` (calendar-holidays): one
    --- list per holiday-*-holidays variable, with Emacs's defaults. Set a
    --- group to `{}` to drop it; add your own to `local`/`other`. See
    --- `:h org-agenda-holidays`.
    holidays = {
      -- holiday-general-holidays (the United States)
      general = {
        { "holiday-fixed", 1, 1, "New Year's Day" },
        { "holiday-float", 1, 1, 3, "Martin Luther King Day" },
        { "holiday-fixed", 2, 2, "Groundhog Day" },
        { "holiday-fixed", 2, 14, "Valentine's Day" },
        { "holiday-float", 2, 1, 3, "President's Day" },
        { "holiday-fixed", 3, 17, "St. Patrick's Day" },
        { "holiday-fixed", 4, 1, "April Fools' Day" },
        { "holiday-float", 5, 0, 2, "Mother's Day" },
        { "holiday-float", 5, 1, -1, "Memorial Day" },
        { "holiday-fixed", 6, 14, "Flag Day" },
        { "holiday-float", 6, 0, 3, "Father's Day" },
        { "holiday-fixed", 7, 4, "Independence Day" },
        { "holiday-float", 9, 1, 1, "Labor Day" },
        { "holiday-float", 10, 1, 2, "Columbus Day" },
        { "holiday-fixed", 10, 31, "Halloween" },
        { "holiday-fixed", 11, 11, "Veteran's Day" },
        { "holiday-float", 11, 4, 4, "Thanksgiving" },
      },
      ["local"] = {}, -- holiday-local-holidays
      other = {}, -- holiday-other-holidays
      -- holiday-christian-holidays
      christian = {
        { "holiday-easter-etc" },
        { "holiday-fixed", 12, 25, "Christmas" },
        {
          "if",
          "christian_all",
          { "holiday-fixed", 1, 6, "Epiphany" },
          { "holiday-julian", 12, 25, "Christmas (Julian calendar)" },
          { "holiday-greek-orthodox-easter" },
          { "holiday-fixed", 8, 15, "Assumption" },
          { "holiday-advent", 0, "Advent" },
        },
      },
      -- holiday-hebrew-holidays
      hebrew = {
        { "holiday-hebrew-passover" },
        { "holiday-hebrew-rosh-hashanah" },
        { "holiday-hebrew-hanukkah" },
        { "if", "hebrew_all", { "holiday-hebrew-tisha-b-av" }, { "holiday-hebrew-misc" } },
      },
      -- holiday-islamic-holidays
      islamic = {
        { "holiday-islamic-new-year" },
        { "holiday-islamic", 9, 1, "Ramadan Begins" },
        {
          "if",
          "islamic_all",
          { "holiday-islamic", 1, 10, "Ashura" },
          { "holiday-islamic", 3, 12, "Mulad-al-Nabi" },
          { "holiday-islamic", 7, 26, "Shab-e-Mi'raj" },
          { "holiday-islamic", 8, 15, "Shab-e-Bara't" },
          { "holiday-islamic", 9, 27, "Shab-e Qadr" },
          { "holiday-islamic", 10, 1, "Id-al-Fitr" },
          { "holiday-islamic", 12, 10, "Id-al-Adha" },
        },
      },
      -- holiday-bahai-holidays
      bahai = {
        { "holiday-bahai-new-year" },
        { "holiday-bahai-ridvan" },
        { "holiday-bahai", 4, 8, "Declaration of the Báb" },
        { "holiday-bahai", 4, 13, "Ascension of Bahá’u’lláh" },
        { "holiday-bahai", 6, 17, "Martyrdom of the Báb" },
        { "holiday-bahai-twin-holy-birthdays" },
        {
          "if",
          "bahai_all",
          { "holiday-bahai", 14, 4, "Day of the Covenant" },
          { "holiday-bahai", 14, 6, "Ascension of ‘Abdu’l-Bahá" },
        },
      },
      -- holiday-oriental-holidays
      oriental = {
        { "holiday-chinese-new-year" },
        {
          "if",
          "chinese_all",
          { "holiday-chinese", 1, 15, "Lantern Festival" },
          { "holiday-chinese-qingming" },
          { "holiday-chinese", 5, 5, "Dragon Boat Festival" },
          { "holiday-chinese", 7, 7, "Double Seventh Festival" },
          { "holiday-chinese", 8, 15, "Mid-Autumn Festival" },
          { "holiday-chinese", 9, 9, "Double Ninth Festival" },
          { "holiday-chinese-winter-solstice" },
        },
      },
      -- holiday-solar-holidays (times in the local time zone)
      solar = {
        { "solar-equinoxes-solstices" },
        { "holiday-daylight-saving" },
      },
      christian_all = false, -- calendar-christian-all-holidays-flag
      hebrew_all = false, -- calendar-hebrew-all-holidays-flag
      islamic_all = false, -- calendar-islamic-all-holidays-flag
      bahai_all = false, -- calendar-bahai-all-holidays-flag
      chinese_all = false, -- calendar-chinese-all-holidays-flag
    },
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
    --- Capturing from the agenda (the global capture key) uses the date at
    --- point as the default date; with count 1 also the time of the item
    --- at point or the current time (org-capture-use-agenda-date). The
    --- agenda's own capture key always does.
    use_agenda_date = false,
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
    --- Keep the targets between refiles (org-refile-use-cache); a count of
    --- 64 (C-u C-u C-u C-c C-w) or `:Org refile_cache_clear` clears it.
    use_cache = false,
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
    --- Parameters written into the header of a new clock table
    --- (org-clock-clocktable-default-properties); `scope` defaults to
    --- "subtree" on a headline and "file" before the first one.
    clocktable_default_properties = { maxlevel = 2 },
    --- function(tables, params) -> string[] writing clock tables instead of
    --- the default (org-clock-clocktable-formatter); nil = the default.
    clocktable_formatter = nil,
    --- Format of the total time cells ("Total time" and its time), and of
    --- the "File time" cells (org-clock-total-time-cell-format,
    --- org-clock-file-time-cell-format).
    total_time_cell_format = "*%s*",
    file_time_cell_format = "*%s*",
    --- Resolve clocks without the help window, just a prompt
    --- (org-clock-resolve-expert).
    resolve_expert = false,
    --- Program printing the X11 idle time in milliseconds
    --- (org-clock-x11idle-program-name); nil = xprintidle when installed,
    --- else x11idle.
    x11idle_program_name = nil,
    --- Keep the running clock and the clock history across restarts:
    --- true (both), "clock", "history" or false (org-clock-persist).
    persist = false,
    --- Ask before resuming a saved clock after a restart
    --- (org-clock-persist-query-resume).
    persist_query_resume = true,
    --- Ask on exit whether to keep the running clock for the next session
    --- (org-clock-persist-query-save).
    persist_query_save = false,
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
    --- Vim regex splitting the data of old-style URLs
    --- (`org-protocol://sub://a/b/c`) (org-protocol-data-separator).
    data_separator = [[/\+\|?]],
  },

  ---------------------------------------------------------------------------
  -- Pasting images and files (yank-media, drag and drop)
  ---------------------------------------------------------------------------
  yank = {
    --- Where `yank_media` puts a clipboard image (org-yank-image-save-method):
    --- "attach" (an attachment of the entry) | a directory (relative to the
    --- file's) | function() returning one.
    image_save_method = "attach",
    --- function() returning the image's name without extension
    --- (org-yank-image-file-name-function); nil = "clipboard-<time stamp>".
    image_file_name_function = nil,
    --- What a dropped or pasted file does (org-yank-dnd-method): "attach" |
    --- "open" | "file-link" | "ask".
    dnd_method = "ask",
    --- Attach method for dropped files (org-yank-dnd-default-attach-method):
    --- nil = `attach.method`, or "cp" | "mv" | "ln" | "lns".
    dnd_default_attach_method = nil,
    --- Treat a paste of existing file paths in an Org buffer (what a
    --- terminal sends for a file drop) as a drop.
    dnd_paste = true,
  },

  ---------------------------------------------------------------------------
  -- Plain links through tags files (org-ctags)
  ---------------------------------------------------------------------------
  ctags = {
    --- Look up plain links in the tags files (Emacs: org-ctags-enable).
    enabled = false,
    --- The ctags program (org-ctags-path-to-ctags); nil = ctags-exuberant
    --- when installed, else ctags.
    path_to_ctags = nil,
    --- Tried in order for a plain link until one returns true
    --- (org-ctags-open-link-functions): names from
    --- `require("org.ctags").link_functions` or function(name).
    open_link_functions = { "find_tag", "ask_rebuild_tags_file_then_find_tag", "ask_append_topic" },
    --- Text of a new topic, `%t` = the capitalized title
    --- (org-ctags-new-topic-template).
    new_topic_template = "* <<%t>>\n\n\n\n\n\n",
    --- The --regex-orgmode given to ctags (org-ctags-tag-regexp).
    tag_regexp = [[/<<([^<>]+)>>/\1/d,definition/]],
  },

  ---------------------------------------------------------------------------
  -- RSS / Atom feeds (org-feed)
  ---------------------------------------------------------------------------
  feed = {
    --- Feeds (org-feed-alist): list of { name = "", url = "", file = "",
    --- headline = "", ...options } or { name, url, file, headline, ... }.
    --- See |org-feed| for the options.
    feeds = {},
    --- Template of a new item (org-feed-default-template).
    default_template = "\n* %h\n  %U\n  %description\n  %a\n",
    --- Drawer holding the feed status (org-feed-drawer).
    drawer = "FEEDSTATUS",
    --- Save the file after adding items (org-feed-save-after-adding).
    save_after_adding = true,
    --- "curl", "wget" or a function(url) returning the feed text
    --- (org-feed-retrieve-method); file:// URLs are always read directly.
    retrieve_method = "curl",
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

  --- org-mouse (see `:h org-mouse`).
  mouse = {
    --- Load org-mouse: context menus, dragging subtrees, clickable stars,
    --- bullets and checkboxes. Emacs loads it with (require 'org-mouse).
    org_mouse = false,
    --- Its parts (org-mouse-features): "context-menu", "move-tree",
    --- "yank-link", "activate-stars", "activate-bullets",
    --- "activate-checkboxes".
    features = { "context-menu", "yank-link", "activate-stars", "activate-bullets", "activate-checkboxes" },
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
    --- Where shell: links run: "buffer" collects the output in a new
    --- `*Org Shell Output*` buffer like Emacs' shell-command (one line is
    --- only echoed; a command ending in `&` shows the buffer at once),
    --- "terminal" runs the command in a terminal window.
    shell_output = "buffer",
    --- Ask before running elisp: links: true, false or function(sexp) ->
    --- boolean (org-link-elisp-confirm-function).
    confirm_elisp = true,
    --- Vim regex: elisp: links matching it run without asking; "" = none
    --- (org-link-elisp-skip-confirm-regexp).
    elisp_skip_confirm_regexp = "",
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
    --- A mouse click on a link follows it: true, "double" (a double click)
    --- or the longest click in ms that still follows it; false = never
    --- (org-mouse-1-follows-link). Middle click opens the link, right
    --- click opens it in Neovim (org-open-at-mouse, org-find-file-at-mouse).
    mouse_1_follows_link = 450,
    --- <Tab> on a link follows it instead of cycling (org-tab-follows-link).
    tab_follows_link = false,
    --- Links to a directory open its index.org
    --- (org-open-directory-means-index-dot-org).
    open_directory_means_index_dot_org = false,
    --- Let external apps (file_apps) open files that don't exist; false =
    --- an error (org-open-non-existing-files).
    open_non_existing_files = false,
    --- URLs of Texinfo manuals for info: links exported to HTML, by manual
    --- name (org-info-other-documents).
    info_other_documents = {
      dir = "https://www.gnu.org/manual/manual.html",
      libc = "https://www.gnu.org/software/libc/manual/html_mono/libc.html",
      make = "https://www.gnu.org/software/make/manual/make.html",
    },
  },
  --- BibTeX entries as headlines (ol-bibtex, `:h org-bibtex`).
  bibtex = {
    --- Generate the keys of new entries (org-bibtex-autogen-keys).
    autogen_keys = false,
    --- Prefix of the field properties, e.g. "BIB_" (org-bibtex-prefix).
    prefix = nil,
    --- The headline is the title when there is no TITLE property
    --- (org-bibtex-treat-headline-as-title).
    treat_headline_as_title = true,
    --- function(fields) -> headline text of written entries; nil = the
    --- title (org-bibtex-headline-format-function).
    headline_format_function = nil,
    --- Export every prefixed property, not only BibTeX fields; needs
    --- `prefix` (org-bibtex-export-arbitrary-fields).
    export_arbitrary_fields = false,
    --- Property holding the key (org-bibtex-key-property).
    key_property = "CUSTOM_ID",
    --- Tags added to new entries (org-bibtex-tags).
    tags = {},
    --- keywords field <-> tags (org-bibtex-tags-are-keywords).
    tags_are_keywords = false,
    --- Tags not exported as keywords (org-bibtex-no-export-tags).
    no_export_tags = {},
    --- Export inherited tags as keywords too (org-bibtex-inherit-tags).
    inherit_tags = false,
    --- Property holding the entry type (org-bibtex-type-property-name).
    type_property_name = "btype",
  },
  --- Downloading remote resources (a URL in #+INCLUDE on export)
  --- (org-resource-download-policy): "prompt" asks for URLs that are not
  --- safe, "safe" only fetches safe ones, true always fetches (dangerous),
  --- false never does.
  resource_download_policy = "prompt",
  --- Vim regexes of safe URLs, matched against the URL and against
  --- "file://" .. the requesting file (org-safe-remote-resources). Answers
  --- `!`, `d` and `f` at the prompt add to it and are remembered in
  --- stdpath("data")/org/safe-remote-resources.json.
  safe_remote_resources = {},
  id = {
    --- Where the ID -> file database is kept (org-id-locations-file). Point
    --- it at Emacs's file (`~/.emacs.d/.org-id-locations`) to share it.
    locations_file = data_dir .. "/id-locations.json",
    --- Format of `locations_file`: "auto" (what the file holds; else JSON
    --- for a `.json` name and Emacs's `print`ed alist otherwise), "json"
    --- or "emacs".
    locations_format = "auto",
    --- Emacs format: store file names relative to the database's
    --- directory (org-id-locations-file-relative).
    locations_file_relative = false,
    --- How new IDs are made (org-id-method): "uuid" | "ts" | "org".
    method = "uuid",
    --- Add "@" and the host name to new "ts" and "org" IDs
    --- (org-id-include-domain).
    include_domain = false,
    --- Headings offered when completing an id: link, as refile target specs
    --- (`:h org-refile`; `files = "id"` = the files holding known IDs); the
    --- chosen heading gets an ID when it has none (org-id-completion-targets).
    completion_targets = { { files = "current" }, { files = "id" } },
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
    --- Extra dispatcher commands (org-attach-commands), by key:
    --- `{ fn = function(target) end, desc = "..." }`; `false` removes a
    --- built-in command.
    commands = {},
    --- Ask for the dispatcher key at a one-line prompt instead of showing
    --- the command menu (org-attach-expert).
    expert = false,
    --- Commit attachment changes to git (org-attach-git; Emacs turns it on
    --- with `(require 'org-attach-git)`).
    git = false,
    --- Files of at least this many bytes go to git-annex when the
    --- repository uses it; false never annexes (org-attach-git-annex-cutoff).
    git_annex_cutoff = 32 * 1024,
    --- Fetch missing git-annex content when opening an attachment:
    --- "ask" | true | false (org-attach-git-annex-auto-get).
    git_annex_auto_get = "ask",
    --- Repository used: "default" (the one containing `dir`) or
    --- "individual-repository" (the entry's attachment directory)
    --- (org-attach-git-dir).
    git_dir = "default",
  },

  ---------------------------------------------------------------------------
  -- MobileOrg (org-mobile)
  ---------------------------------------------------------------------------
  mobile = {
    --- Staging directory shared with the mobile application
    --- (org-mobile-directory). Required by push and pull.
    directory = nil,
    --- Files to stage (org-mobile-files): "agenda_files",
    --- "text_search_extra_files", files and directories (their `*.org`).
    files = { "agenda_files" },
    --- Emacs regexp of files not to stage (org-mobile-files-exclude-regexp).
    files_exclude_regexp = "",
    --- File the captured entries and edit requests are moved to on pull
    --- (org-mobile-inbox-for-pull); relative to `org_directory`.
    inbox_for_pull = "~/org/from-mobile.org",
    --- Name of the index file (org-mobile-index-file).
    index_file = "index.org",
    --- The #+ALLPRIORITIES of the index file (org-mobile-allpriorities).
    allpriorities = "A B C",
    --- Agendas written to agendas.org (org-mobile-agendas): "default" (week
    --- agenda and TODO list), "custom" (`agenda.custom_commands`), "all",
    --- or a list of command keys.
    agendas = "all",
    --- Give every agenda entry an ID on push (org-mobile-force-id-on-agenda-items).
    force_id_on_agenda_items = true,
    --- Apply mobile edits even when the entry changed on the computer too
    --- (org-mobile-force-mobile-change): true, false or a list of
    --- "todo", "tags", "priority", "heading", "body".
    force_mobile_change = false,
    --- Encrypt the staged files with openssl (org-mobile-use-encryption).
    use_encryption = false,
    --- Password for the encryption; asked once per session when empty
    --- (org-mobile-encryption-password).
    encryption_password = "",
    --- Program for file checksums; nil finds shasum, sha1sum, md5sum or md5
    --- (org-mobile-checksum-binary).
    checksum_binary = nil,
    --- Extra `F(action:data)` actions (org-mobile-action-alist):
    --- `{ name = function(data, old, new, target) end }`.
    action_alist = {},
    --- Show the flagged entries in an agenda after a pull.
    show_flagged = true,
    --- Hooks (functions; the User autocmds OrgMobilePrePush, OrgMobilePostPush,
    --- OrgMobilePrePull, OrgMobileBeforeProcessCapture and OrgMobilePostPull
    --- fire too).
    pre_push_hook = nil,
    post_push_hook = nil,
    pre_pull_hook = nil,
    before_process_capture_hook = nil,
    post_pull_hook = nil,
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
    -- Overwrite an existing tangle target: "auto" (delete it first only when
    -- read-only), true (always delete and recreate), false (replace the
    -- contents) (org-babel-tangle-remove-file-before-write)
    tangle_remove_file_before_write = "auto",
    -- function(text) -> text applied to the Org text of :comments org|both;
    -- nil removes its common indentation (org-babel-process-comment-text)
    process_comment_text = nil,
    -- Write #+BEGIN_EXAMPLE / #+END_EXAMPLE around results
    -- (org-babel-uppercase-example-markers)
    uppercase_example_markers = false,
    -- Templates of exported code, filled with %lang, %name, %body, %switches,
    -- %header-args and %<header argument> (org-babel-exp-code-template,
    -- org-babel-exp-inline-code-template), and of exported #+CALL lines and
    -- call_ objects, with %line (org-babel-exp-call-line-template)
    exp_code_template = "#+begin_src %lang%switches%header-args\n%body\n#+end_src",
    exp_inline_code_template = "src_%lang[%switches%header-args]{%body}",
    exp_call_line_template = "",
    -- Languages run as a shell, like sh (org-babel-shell-names)
    shell_names = { "sh", "bash", "zsh", "fish", "csh", "ash", "dash", "ksh", "mksh", "posh" },
    -- Shell blocks without :results words give their output; false: their
    -- exit status (org-babel-shell-results-defaults-to-output)
    shell_results_defaults_to_output = true,
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
      -- hline_to: an hline of a table variable (org-babel-python-hline-to);
      -- None_to: a None of a list result (org-babel-python-None-to);
      -- session_cmd: the REPL of sessions, as it is (org-babel-python-command-session)
      python = { cmd = "python3", ext = "py", hline_to = "None", None_to = "hline", session_cmd = nil },
      python3 = { cmd = "python3", ext = "py" },
      -- evaluated inside Neovim; another cmd ("lua", "luajit") runs it
      -- like ob-lua (org-babel-lua-command). hline_to / None_to /
      -- multiple_values_separator: org-babel-lua-*
      lua = { cmd = "nvim", ext = "lua", hline_to = "None", None_to = "hline", multiple_values_separator = ", " },
      js = { cmd = "node", ext = "js" },
      javascript = { cmd = "node", ext = "js" },
      typescript = { cmd = "npx tsx", ext = "ts" },
      ts = { cmd = "npx tsx", ext = "ts" },
      -- org-babel-ruby-hline-to / org-babel-ruby-nil-to
      ruby = { cmd = "ruby", ext = "rb", hline_to = "nil", nil_to = "hline" },
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
      -- ports of ob-LANG.el (see |org-babel-languages|); the other keys are
      -- that file's options
      plantuml = {
        default_header_args = { results = "file", exports = "results" },
        exec_mode = "jar", -- org-plantuml-exec-mode: "jar" or "plantuml"
        jar_path = "", -- org-plantuml-jar-path
        executable_path = "plantuml", -- org-plantuml-executable-path
        args = { "-headless" }, -- org-plantuml-args
        svg_text_to_path = false, -- org-babel-plantuml-svg-text-to-path
      },
      ditaa = {
        default_header_args = { results = "file graphics", exports = "results", ["file-ext"] = "png" },
        exec_mode = "jar", -- org-ditaa-default-exec-mode: "jar" or "ditaa"
        exec = "ditaa", -- org-ditaa-exec
        java_exec = "java", -- org-ditaa-java-exec
        jar_path = "", -- org-ditaa-jar-path
        eps_jar_path = nil, -- org-ditaa-eps-jar-path (nil: DitaaEps.jar next to jar_path)
      },
      -- backend (org-babel-clojure-backend): "babashka", "clojure-cli" or
      -- "nbb"; nil picks babashka or clojure-cli when installed.
      -- babashka_command / cli_command / nbb_command: ob-clojure-*-command
      -- (nil: bb, clojure -M, nbb or npx nbb found on $PATH)
      clojure = { ext = "clj", default_ns = "user" }, -- default_ns: org-babel-clojure-default-ns
      -- backend (org-babel-clojurescript-backend): nil is nbb when installed
      clojurescript = { ext = "cljs" },
      -- org-babel-csharp-*: compiler; default_target_framework (nil: "netN.0"
      -- of the newest SDK); additional_project_flags (XML); functions
      -- generate_compile_command(project, bin_dir) and
      -- generate_restore_command(project) returning shell commands
      csharp = { ext = "cs", compiler = "dotnet" },
      fortran = { cmd = "gfortran", ext = "F90" }, -- cmd: org-babel-fortran-compiler
      java = {
        default_header_args = { results = "output", dir = "." },
        cmd = "java", -- org-babel-java-command
        compiler = "javac", -- org-babel-java-compiler
        hline_to = "null", -- org-babel-java-hline-to
        null_to = "hline", -- org-babel-java-null-to
      },
      groovy = { cmd = "groovy" }, -- org-babel-groovy-command
      -- cmd: the interpreter of blocks (Emacs: an inf-haskell session);
      -- compiler: org-babel-haskell-compiler (:compile yes);
      -- lhs2tex: org-babel-haskell-lhs2tex-command
      haskell = {
        default_header_args = { padline = "no" },
        cmd = "ghci -v0 -ignore-dot-ghci",
        compiler = "ghc",
        lhs2tex = "lhs2tex",
      },
      -- Common Lisp: cmd evaluates in place of SLIME (org-babel-lisp-eval-fn);
      -- dir_fmt: org-babel-lisp-dir-fmt
      lisp = {
        cmd = "sbcl --script",
        ext = "lisp",
        dir_fmt = "(cl:let ((cl:*default-pathname-defaults* #P%S\n)) %%s\n)",
      },
      -- js_filename: org-babel-processing-processing-js-filename; cmd runs
      -- babel_processing_view_sketch (processing-java)
      processing = {
        default_header_args = { results = "html", exports = "results" },
        js_filename = "processing.js",
        cmd = "processing-java",
      },
      -- location: org-babel-screen-location
      screen = {
        default_header_args = {
          results = "silent",
          session = "default",
          cmd = "sh",
          terminal = "xterm",
          screenrc = "/dev/null",
        },
        location = "screen",
      },
      -- impl: the implementation without a :scheme header (Geiser's
      -- default); commands: implementation -> command; null_to:
      -- org-babel-scheme-null-to
      scheme = { impl = "guile", commands = {}, null_to = "hline" },
      julia = { cmd = "julia" }, -- org-babel-julia-command
      -- org-babel-latex-*: preamble, begin_env and end_env are strings or
      -- functions(header_args) returning one; htlatex, htlatex_packages;
      -- pdf_svg_process (%f the PDF, %O the SVG); process_alist = { png =
      -- {...} } like ui.latex_preview.processes (nil: latex + dvipng)
      latex = {
        ext = "tex",
        default_header_args = { results = "latex", exports = "results" },
        preamble = "\\documentclass[preview]{standalone}\n",
        begin_env = "\\begin{document}",
        end_env = "\\end{document}",
        htlatex = "htlatex",
        htlatex_packages = { "[usenames]{color}", "{tikz}", "{color}", "{listings}", "{amsmath}" },
        pdf_svg_process = "inkscape --pdf-poppler --export-area-drawing --export-text-to-path "
          .. "--export-plain-svg --export-filename=%O %f",
        process_alist = nil,
      },
      -- commands: org-babel-lilypond-commands, { lilypond, PDF viewer, MIDI
      -- player } (nil: the platform's default); the other keys are the
      -- org-babel-lilypond-* variables the toggle commands change
      lilypond = {
        ext = "ly",
        default_header_args = { results = "file", exports = "results" },
        commands = nil,
        arrange_mode = false,
        gen_png = false,
        gen_svg = false,
        gen_html = false,
        gen_pdf = false,
        use_eps = false,
        compile_post_tangle = true,
        display_pdf_post_tangle = true,
        play_midi_post_tangle = true,
      },
      maxima = { cmd = "maxima" }, -- org-babel-maxima-command
      ocaml = { cmd = "ocaml" }, -- org-babel-ocaml-command
      gnuplot = {
        cmd = "gnuplot",
        default_header_args = { results = "file", exports = "results" },
        terms = { eps = "postscript eps" }, -- *org-babel-gnuplot-terms*
      },
    },
    -- emacs-lisp blocks, elisp: links and the Lisp forms the interpreter of
    -- table formulas can't evaluate (macros, capture, diary sexps, headers)
    -- run in a separate Emacs process (`command` false: never)
    emacs_lisp = { command = "emacs", args = { "-Q", "--batch" } },
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
    --- org-export-allow-bind-keywords: honor #+BIND: (org-export-* and
    --- back-end variables become these options during the export).
    allow_bind_keywords = false,
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
    initial_scope = "buffer", -- org-export-initial-scope: dispatcher scope at start ("buffer" or "subtree")
    body_only = false, -- org-export-body-only: dispatcher "body only" at start
    visible_only = false, -- org-export-visible-only: dispatcher "visible only" at start
    force_publishing = false, -- org-export-force-publishing: dispatcher "force publishing" at start
    --- org-export-in-background: dispatcher "async" at start; results go to
    --- the export stack (:Org export_stack).
    in_background = false,
    --- org-export-async-init-file: a Lua file run by the Neovim that makes
    --- asynchronous exports (Lua functions of the options don't reach it).
    async_init_file = nil,
    dispatch_use_expert_ui = false, -- org-export-dispatch-use-expert-ui (a prompt instead of the menu)
    show_temporary_export_buffer = true, -- org-export-show-temporary-export-buffer
    copy_to_kill_ring = false, -- org-export-copy-to-kill-ring (true, "if-interactive" or false)
    coding_system = nil, -- org-export-coding-system (an iconv encoding of output files; nil = UTF-8)
    process_citations = true, -- org-export-process-citations
    replace_macros = true, -- org-export-replace-macros
    --- org-export-smart-quotes-alist: { [lang] = { primary_opening = { ["utf-8"] =,
    --- html =, latex =, texinfo = }, primary_closing, secondary_opening,
    --- secondary_closing, apostrophe } }; a language set here replaces its
    --- Emacs entry, the others keep the Emacs table.
    smart_quotes_alist = nil,
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
      --- org-html-with-latex: true/"mathjax", "html", "dvipng", "dvisvgm",
      --- "imagemagick" (pictures in ltximg/), "verbatim" or false; nil =
      --- export.with_latex. #+OPTIONS: tex: overrides it.
      with_latex = nil,
      --- org-latex-to-html-convert-command for tex:html, %i = the fragment
      --- (shell-quoted), e.g. "latexmlmath %i --presentationmathml=-".
      latex_to_html_convert_command = nil,
      mathjax_options = nil, -- org-html-mathjax-options ({ path = ..., scale = 1.0, ... })
      --- function(code, lang) -> HTML to highlight source code, used instead
      --- of the built-in highlighting (plugin option).
      fontify = nil,
      --- org-html-htmlize-output-type: how source code is coloured from its
      --- tree-sitter highlights (Emacs uses htmlize): "inline-css" (style
      --- attributes with the colour scheme's colours), "css" (classes, see
      --- :Org html_htmlize_generate_css) or false (plain text).
      htmlize_output_type = "inline-css",
      htmlize_font_prefix = "org-", -- org-html-htmlize-font-prefix (CSS class prefix)
      allow_name_attribute_in_anchors = false, -- org-html-allow-name-attribute-in-anchors
      coding_system = "utf-8", -- org-html-coding-system (charset of the <meta> and XML declaration)
      datetime_formats = { "%F", "%FT%T" }, -- org-html-datetime-formats ({ date, date and time })
      indent = false, -- org-html-indent (indent the generated HTML like Emacs' mhtml-mode)
      --- org-html-divs: { preamble = { "div", "preamble" }, content = { "div",
      --- "content" }, postamble = { "div", "postamble" } } (nil = that value).
      divs = nil,
      footnotes_section = nil, -- org-html-footnotes-section (nil = the Emacs format)
      format_drawer_function = nil, -- org-html-format-drawer-function: fn(name, contents)
      format_headline_function = nil, -- org-html-format-headline-function: fn(todo, todo_type, priority, text, tags, info)
      --- org-html-format-inlinetask-function:
      --- fn(todo, todo_type, priority, text, tags, contents, info)
      format_inlinetask_function = nil,
      home_up_format = nil, -- org-html-home/up-format (nil = the Emacs format)
      infojs_template = nil, -- org-html-infojs-template (nil = the Emacs template)
      inline_image_rules = nil, -- org-html-inline-image-rules (nil = the Emacs rules)
      klipsify_src = false, -- org-html-klipsify-src
      klipse_css = "https://storage.googleapis.com/app.klipse.tech/css/codemirror.css", -- org-html-klipse-css
      klipse_js = "https://storage.googleapis.com/app.klipse.tech/plugin_prod/js/klipse_plugin.min.js", -- org-html-klipse-js
      klipse_selection_script = nil, -- org-html-klipse-selection-script (nil = the Emacs script)
      mathjax_template = nil, -- org-html-mathjax-template (nil = the Emacs template)
      meta_tags = nil, -- org-html-meta-tags ({ { attr, name, content }, ... } or function(info); nil = Emacs)
      scripts = nil, -- org-html-scripts (nil = the Emacs script)
      table_align_individual_fields = true, -- org-html-table-align-individual-fields
      table_data_tags = { "<td%s>", "</td>" }, -- org-html-table-data-tags
      table_header_tags = { '<th scope="%s"%s>', "</th>" }, -- org-html-table-header-tags
      table_default_attributes = nil, -- org-html-table-default-attributes ({ { name, value }, ... }; nil = Emacs)
      table_row_open_tag = "<tr>", -- org-html-table-row-open-tag (string or function)
      table_row_close_tag = "</tr>", -- org-html-table-row-close-tag (string or function)
      table_use_header_tags_for_first_column = false, -- org-html-table-use-header-tags-for-first-column
      tag_class_prefix = "", -- org-html-tag-class-prefix
      todo_kwd_class_prefix = "", -- org-html-todo-kwd-class-prefix
      text_markup_alist = nil, -- org-html-text-markup-alist ({ bold = "<b>%s</b>", ... }; nil = Emacs)
      viewport = nil, -- org-html-viewport ({ { name, value }, ... }; nil = Emacs, false = no tag)
      xml_declaration = nil, -- org-html-xml-declaration ({ html = ..., php = ... }; nil = Emacs)
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
      src_block_backend = "verbatim", -- org-latex-src-block-backend ("verbatim", "listings", "minted", "engraved")
      engraved_options = nil, -- org-latex-engraved-options ({ { key, value }, ... }; nil = the Emacs list)
      engraved_preamble = nil, -- org-latex-engraved-preamble (nil = the Emacs preamble)
      --- org-latex-engraved-theme (#+LATEX_ENGRAVED_THEME): nil/"default" = engrave-faces'
      --- default colours, true = the current colour scheme, a name = that colour scheme.
      engraved_theme = nil,
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
      active_timestamp_format = "\\textit{%s}", -- org-latex-active-timestamp-format
      inactive_timestamp_format = "\\textit{%s}", -- org-latex-inactive-timestamp-format
      diary_timestamp_format = "\\textit{%s}", -- org-latex-diary-timestamp-format
      --- org-latex-compiler-file-string: the "Intended LaTeX compiler" line
      --- (%s = the compiler); false/"" = none.
      compiler_file_string = "%% Intended LaTeX compiler: %s\n",
      --- org-latex-known-warnings: { { vim_regex, message }, ... } reported
      --- after a compilation (nil = the Emacs list).
      known_warnings = nil,
      custom_lang_environments = {}, -- org-latex-custom-lang-environments ({ [lang] = env | { ... } })
      default_footnote_command = "\\footnote{%s%s}", -- org-latex-default-footnote-command
      default_quote_environment = "quote", -- org-latex-default-quote-environment
      footnote_defined_format = "\\textsuperscript{\\ref{%s}}", -- org-latex-footnote-defined-format
      footnote_separator = "\\textsuperscript{,}\\,", -- org-latex-footnote-separator
      format_drawer_function = nil, -- org-latex-format-drawer-function: fn(name, contents)
      format_headline_function = nil, -- org-latex-format-headline-function: fn(todo, todo_type, priority, text, tags, info)
      --- org-latex-format-inlinetask-function:
      --- fn(todo, todo_type, priority, name, tags, contents, info)
      format_inlinetask_function = nil,
      image_default_scale = "", -- org-latex-image-default-scale
      image_default_height = "", -- org-latex-image-default-height
      image_default_option = "", -- org-latex-image-default-option
      inline_image_rules = nil, -- org-latex-inline-image-rules (nil = the Emacs rules)
      inputenc_alist = {}, -- org-latex-inputenc-alist ({ [coding] = inputenc })
      link_with_unknown_path_format = "\\texttt{%s}", -- org-latex-link-with-unknown-path-format
      listings_langs = nil, -- org-latex-listings-langs ({ { lang, listings_lang }, ... }; nil = Emacs)
      listings_options = {}, -- org-latex-listings-options ({ { key, value }, ... })
      listings_src_omit_language = false, -- org-latex-listings-src-omit-language
      logfiles_extensions = nil, -- org-latex-logfiles-extensions (nil = the Emacs list)
      minted_langs = nil, -- org-latex-minted-langs ({ { lang, minted_lang }, ... }; nil = Emacs)
      minted_options = {}, -- org-latex-minted-options ({ { key, value }, ... })
      subtitle_format = "\\\\\\medskip\n\\large %s", -- org-latex-subtitle-format
      subtitle_separate = false, -- org-latex-subtitle-separate
      table_scientific_notation = nil, -- org-latex-table-scientific-notation (e.g. "%s\\,(%s)")
      text_markup_alist = nil, -- org-latex-text-markup-alist ({ bold = "\\textbf{%s}", ... }; nil = Emacs)
      toc_include_unnumbered = false, -- org-latex-toc-include-unnumbered
    },
    texinfo = {
      default_class = "info", -- org-texinfo-default-class
      classes = nil, -- org-texinfo-classes (nil = the Emacs list)
      coding_system = "UTF-8", -- org-texinfo-coding-system (@documentencoding)
      node_description_column = 32, -- org-texinfo-node-description-column
      table_default_markup = "@asis", -- org-texinfo-table-default-markup
      compact_itemx = false, -- org-texinfo-compact-itemx
      --- org-texinfo-with-latex: true, false or "detect" (@math when makeinfo
      --- supports it); nil = "detect" unless export.with_latex is false.
      with_latex = nil,
      info_process = nil, -- org-texinfo-info-process (nil = { "makeinfo --no-split %f" })
      remove_logfiles = true, -- org-texinfo-remove-logfiles
      logfiles_extensions = nil, -- org-texinfo-logfiles-extensions (nil = aux toc cp fn ky pg tp vr)
      active_timestamp_format = "@emph{%s}", -- org-texinfo-active-timestamp-format
      inactive_timestamp_format = "@emph{%s}", -- org-texinfo-inactive-timestamp-format
      diary_timestamp_format = "@emph{%s}", -- org-texinfo-diary-timestamp-format
      link_with_unknown_path_format = "@indicateurl{%s}", -- org-texinfo-link-with-unknown-path-format
      tables_verbatim = false, -- org-texinfo-tables-verbatim
      table_scientific_notation = nil, -- org-texinfo-table-scientific-notation
      --- org-texinfo-text-markup-alist: { bold = "@strong{%s}", code = "code",
      --- italic = "@emph{%s}", verbatim = "samp" } (nil = that value).
      text_markup_alist = nil,
      format_headline_function = nil, -- org-texinfo-format-headline-function: fn(todo, todo_type, priority, text, tags)
      format_drawer_function = nil, -- org-texinfo-format-drawer-function: fn(name, contents)
      --- org-texinfo-format-inlinetask-function:
      --- fn(todo, todo_type, priority, title, tags, contents)
      format_inlinetask_function = nil,
      --- Export Texinfo through pandoc instead of the native back-end.
      use_pandoc = false,
    },
    koma_letter = {
      default_class = "default-koma-letter", -- org-koma-letter-default-class
      class_option_file = "NF", -- org-koma-letter-class-option-file (#+LCO)
      --- org-koma-letter-author: a string, a function returning one, or false
      --- (nil = export.author / the user's full name)
      author = nil,
      --- org-koma-letter-email: a string, a function returning one, or false
      --- (nil = export.email)
      email = nil,
      from_address = "", -- org-koma-letter-from-address
      phone_number = "", -- org-koma-letter-phone-number
      url = "", -- org-koma-letter-url
      from_logo = "", -- org-koma-letter-from-logo
      place = "", -- org-koma-letter-place
      location = "", -- org-koma-letter-location
      opening = "", -- org-koma-letter-opening
      closing = "", -- org-koma-letter-closing
      signature = "", -- org-koma-letter-signature
      prefer_special_headings = false, -- org-koma-letter-prefer-special-headings
      --- org-koma-letter-subject-format: true, false or a list of
      --- "afteropening", "beforeopening", "centered", "left", "right",
      --- "titled", "underlined", "untitled"
      subject_format = true,
      use_backaddress = false, -- org-koma-letter-use-backaddress
      --- org-koma-letter-use-foldmarks: true, false or a list of marks
      --- ("B", "b", "H", "h", "L", "l", "M", "m", "P", "p", "T", "t", "V", "v")
      use_foldmarks = true,
      use_phone = false, -- org-koma-letter-use-phone
      use_url = false, -- org-koma-letter-use-url
      use_from_logo = false, -- org-koma-letter-use-from-logo
      use_email = false, -- org-koma-letter-use-email
      use_place = true, -- org-koma-letter-use-place
      headline_is_opening_maybe = true, -- org-koma-letter-headline-is-opening-maybe
      prefer_subject = false, -- org-koma-letter-prefer-subject
    },
    man = {
      tables_centered = true, -- org-man-tables-centered
      tables_verbatim = false, -- org-man-tables-verbatim
      table_scientific_notation = "%sE%s", -- org-man-table-scientific-notation (false = none)
      source_highlight = false, -- org-man-source-highlight (GNU source-highlight)
      source_highlight_langs = nil, -- org-man-source-highlight-langs (nil = the Emacs map)
      --- org-man-pdf-process: shell commands with %f %F %b %o %O, or a
      --- function(file) (nil = three runs of "tbl %f | eqn | groff -man | ps2pdf - > %b.pdf")
      pdf_process = nil,
      logfiles_extensions = { "log", "out", "toc" }, -- org-man-logfiles-extensions
      remove_logfiles = true, -- org-man-remove-logfiles
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
      --- org-org-htmlized-css-url: stylesheet linked instead of the embedded
      --- one in FILE.org.html of `htmlized_source` publishing.
      htmlized_css_url = nil,
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
      include_sexps = true, -- org-icalendar-include-sexps (diary-anniversary, -block, -cyclic, -float, -date)
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
      --- Processors of the buffer capabilities (false = none; for
      --- activation, false = highlighting without checking keys).
      activate_processor = "basic", -- org-cite-activate-processor
      follow_processor = "basic", -- org-cite-follow-processor
      insert_processor = "basic", -- org-cite-insert-processor
      basic_max_key_distance = 2, -- org-cite-basic-max-key-distance
      basic_author_column_end = 25, -- org-cite-basic-author-column-end
      basic_column_separator = "  ", -- org-cite-basic-column-separator
      --- org-cite-basic-complete-key-crm-separator: nil (one prompt per key),
      --- a Vim regexp separating keys typed at one prompt, or "dynamic".
      basic_complete_key_crm_separator = nil,
      --- Highlight group of the citation key under the mouse ("highlight",
      --- Emacs's face, is OrgCiteMouseOver); false = none. Turns
      --- 'mousemoveevent' on (org-cite-basic-mouse-over-key-face).
      basic_mouse_over_key_face = "highlight",
      -- csl processor (oc-csl)
      csl_styles_dir = nil, -- org-cite-csl-styles-dir
      csl_locales_dir = nil, -- org-cite-csl-locales-dir (nil: en-US only)
      csl_link_cites = true, -- org-cite-csl-link-cites
      csl_no_citelinks_backends = { "ascii" }, -- org-cite-csl-no-citelinks-backends
      csl_html_hanging_indent = "1.5em", -- org-cite-csl-html-hanging-indent
      csl_html_label_width_per_char = "0.6em", -- org-cite-csl-html-label-width-per-char
      csl_latex_hanging_indent = "1.5em", -- org-cite-csl-latex-hanging-indent
      csl_latex_label_separator = "0.6em", -- org-cite-csl-latex-label-separator
      csl_latex_label_width_per_char = "0.45em", -- org-cite-csl-latex-label-width-per-char
      csl_latex_preamble = nil, -- org-cite-csl-latex-preamble (nil = the Emacs preamble)
      csl_bibtex_titles_to_sentence_case = true, -- org-cite-csl-bibtex-titles-to-sentence-case
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
      table_use_ascii_art = false, -- org-ascii-table-use-ascii-art (box characters for table.el tables, UTF-8)
      caption_above = false, -- org-ascii-caption-above
      verbatim_format = "`%s'", -- org-ascii-verbatim-format
      bullets = nil, -- org-ascii-bullets ({ ascii = {...}, latin1 = {...}, ["utf-8"] = {...} }; nil = Emacs)
      underline = nil, -- org-ascii-underline (same shape; nil = Emacs)
      format_drawer_function = nil, -- org-ascii-format-drawer-function: fn(name, contents, width)
      --- org-ascii-format-inlinetask-function:
      --- fn(todo, todo_type, priority, name, tags, contents, width, inlinetask, info)
      format_inlinetask_function = nil,
    },
    odt = {
      --- Export ODT with pandoc instead of the native back-end (plugin option).
      use_pandoc = false,
      --- org-odt-styles-file: nil (factory styles), a styles.xml, .odt or
      --- .ott file, or { "file.ott", { "styles.xml", "image/hdr.png" } }.
      styles_file = nil,
      extra_styles = nil, -- XML added to <office:styles> (plugin option, also #+ODT_EXTRA_STYLES)
      content_template_file = nil, -- org-odt-content-template-file (nil = OrgOdtContentTemplate.xml)
      display_outline_level = 2, -- org-odt-display-outline-level
      fontify_srcblocks = true, -- org-odt-fontify-srcblocks (tree-sitter highlights)
      create_custom_styles_for_srcblocks = true, -- org-odt-create-custom-styles-for-srcblocks
      pixels_per_inch = 96, -- org-odt-pixels-per-inch
      use_date_fields = false, -- org-odt-use-date-fields
      with_forbidden_chars = "", -- org-odt-with-forbidden-chars (replacement, true = keep, false = error)
      with_latex = nil, -- org-odt-with-latex (nil = export.with_latex; true/"mathml", "dvipng", ..., "verbatim")
      --- org-latex-to-mathml-convert-command, e.g. "latexmlmath %i --presentationmathml=%o"
      --- (%i fragment, %I input file, %o output file, %j jar file).
      latex_to_mathml_convert_command = nil,
      latex_to_mathml_jar_file = nil, -- org-latex-to-mathml-jar-file
      latex_mathml_directory = "ltxmathml/", -- org-latex-mathml-directory (MathML cache, relative to the Org file)
      inline_image_rules = nil, -- org-odt-inline-image-rules ({ file = { "png", ... } })
      inline_formula_rules = nil, -- org-odt-inline-formula-rules ({ file = { "mathml", "mml", "odf" } })
      table_styles = nil, -- org-odt-table-styles ({ { name, template, { use_first_row_styles = true, ... } } })
      category_map_alist = nil, -- org-odt-category-map-alist ({ __Figure__ = { "Illustration", "value", "Figure" } })
      format_drawer_function = nil, -- org-odt-format-drawer-function: fn(name, contents)
      format_headline_function = nil, -- org-odt-format-headline-function: fn(todo, todo_type, priority, text, tags)
      format_inlinetask_function = nil, -- org-odt-format-inlinetask-function: fn(todo, type, pri, name, tags, contents)
      preferred_output_format = nil, -- org-odt-preferred-output-format (e.g. "pdf", "docx")
      convert_process = "LibreOffice", -- org-odt-convert-process
      convert_processes = nil, -- org-odt-convert-processes ({ { name, cmd }, ... }; nil = Emacs list)
      convert_capabilities = nil, -- org-odt-convert-capabilities (nil = Emacs list)
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
    --- The Org, Table, Agenda, Column, Edit-Formulas and OrgTbl menus
    --- (Emacs's easymenus), added while a buffer they belong to is current;
    --- false = none. Emacs has no option for them.
    menus = true,
    --- How to ask for one of a fixed set of values (a table export format,
    --- a column summary type, …): "float" = a floating list picked with
    --- j/k and <CR> or a key; "input" = the command line with <Tab>
    --- completion, like Emacs's completing-read.
    choice_prompt = "float",
    --- Headline levels listed by `imenu` (gO) (org-imenu-depth).
    imenu_depth = 2,
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
    --- Columns of virtual indentation per level in indent mode; 0 turns
    --- it off (org-indent-indentation-per-level).
    indent_indentation_per_level = 2,
    --- Indent mode turns adapt_indentation off in its buffer
    --- (org-indent-mode-turns-off-org-adapt-indentation).
    indent_mode_turns_off_adapt_indentation = true,
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
    --- Highlight the text of TODO headlines with OrgHeadlineTodo
    --- (org-fontify-todo-headline).
    fontify_todo_headline = false,
    --- The headline level color on the stars only (org-level-color-stars-only).
    level_color_stars_only = false,
    --- Keywords shown without their "#+KEYWORD:" part: any of "title",
    --- "subtitle", "author", "date", "email" (org-hidden-keywords).
    hidden_keywords = {},
    --- Hide the {{{ }}} around macro calls (org-hide-macro-markers).
    hide_macro_markers = false,
    --- LaTeX-related syntax highlighted: any of "latex" (fragments and
    --- environments, OrgLatex), "native" (the same with the tex syntax),
    --- "script" (sub/superscripts), "entities" (org-highlight-latex-and-related).
    highlight_latex_and_related = {},
    --- Syntax-include the languages of src blocks for highlighting
    --- (org-src-fontify-natively).
    src_highlight = true,
    --- Per-language face of src block bodies, like `todo_keyword_faces`:
    --- `{ python = { bg = "#e5ffb8" }, [""] = "CursorLine" }` ("" = blocks
    --- without a language) (org-src-block-faces).
    src_block_faces = {},
    --- Per-keyword faces: { WAITING = ":foreground orange :weight bold" }
    --- or a highlight definition table { fg = "#ff9e64", bold = true } or a group name.
    todo_keyword_faces = {},
    --- Faces of priority cookies, like `todo_keyword_faces`:
    --- `{ A = "ErrorMsg", ["10"] = { fg = "gray" } }` (org-priority-faces).
    priority_faces = {},
    --- Faces of tags, like `todo_keyword_faces`: `{ urgent = ":foreground red" }`
    --- (org-tag-faces).
    tag_faces = {},
    --- Inline image previews (org-link-preview, <C-c><C-x><C-v>). See
    --- `:h org-images`.
    images = {
      --- "auto" | "native" (vim.ui.img: Neovim 0.13+ in a terminal with the
      --- Kitty graphics protocol) | "snacks" (Snacks.image) | "image.nvim" |
      --- false. "auto" uses the first that works.
      backend = "auto",
      --- Where images go: "inline" draws them in place of the link or
      --- fragment (its text is hidden until the cursor is on the line, like
      --- Emacs), "below" under the line with the text left as it is.
      placement = "inline",
      --- Links previewed at once; the rest follow in batches every
      --- `preview_delay` seconds (org-link-preview-batch-size,
      --- org-link-preview-delay). 0 = all at once.
      batch_size = 6,
      preview_delay = 0.05,
      --- Images of http(s) links (org-display-remote-inline-images): "skip",
      --- "download" (fetched with curl on every preview) or "cache" (fetched
      --- once into stdpath("cache"), again on link_preview_refresh).
      remote = "skip",
      --- Width of images (org-image-actual-width): true = their own size;
      --- a number = that many pixels; false or { n } = the `:width` of
      --- #+ATTR_ORG (else of another #+ATTR_x), else n pixels. `:width`
      --- takes pixels (300, 300px), a percentage or a fraction (0.5) of the
      --- text width, or t. An ORG-IMAGE-ACTUAL-WIDTH property overrides it.
      actual_width = true,
      --- Widest image (org-image-max-width): "fill-column" ('textwidth',
      --- else 70), "window", a number of pixels, a fraction of the window,
      --- or false (the window).
      max_width = "fill-column",
      --- Tallest image, in rows.
      max_height = 24,
      --- Alignment of images alone in their paragraph (org-image-align):
      --- "left" | "center" | "right". #+ATTR_ORG: :align / :center t
      --- override it.
      align = "left",
      --- Preview image links when a file opens (org-startup-with-link-previews;
      --- #+STARTUP: linkpreviews / nolinkpreviews, inlineimages / noinlineimages).
      startup = false,
      --- Preview the links of an entry when TAB shows it, and remove them
      --- when it folds (org-cycle-link-previews-display).
      cycle_display = false,
      --- File extensions previewed (Emacs `image-file-name-regexp`).
      extensions = {
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "tif", "tiff", "avif",
        "xbm", "xpm", "pbm", "pgm", "ppm", "pnm",
      },
    },
    --- LaTeX fragment previews (org-latex-preview, <C-c><C-x><C-l>), drawn by
    --- the `images` backend.
    latex_preview = {
      --- How fragments are rendered (org-preview-latex-default-process): a
      --- name from `processes`, or "auto" for the first one installed
      --- (dvipng, dvisvgm, tectonic, pdflatex, imagemagick).
      process = "auto",
      --- Extra or replaced processes (org-preview-latex-process-alist), e.g.
      --- { mine = { programs = { "latex", "dvipng" }, image_input_type = "dvi",
      --- image_output_type = "png", latex_compiler = { "latex %f" },
      --- image_converter = { "dvipng -D %D -T tight -o %O %f" } } }. Commands
      --- run in a shell; %f %F %b %o %O %D %S as in Emacs. See `:h org-images`.
      processes = {},
      --- Size of the formulas relative to the text (org-format-latex-options :scale).
      scale = 1.0,
      --- Color of the formulas (:foreground): "default" (the Normal text),
      --- "auto" (the text at the fragment), a color name or "#rrggbb".
      foreground = "default",
      --- Background (:background): "default" (Normal), "Transparent", a color
      --- name or "#rrggbb".
      background = "default",
      --- LaTeX preamble (org-format-latex-header), with [DEFAULT-PACKAGES] and
      --- [PACKAGES] replaced by `export.latex` packages and the file's
      --- #+LATEX_HEADER lines added. nil = the Emacs header.
      header = nil,
      --- Where rendered images go (org-preview-latex-image-directory): relative
      --- to the file's directory, or absolute. Buffers without a file use
      --- stdpath("cache") .. "/org/ltximg".
      image_directory = "ltximg/",
      --- An absolute directory used instead of `image_directory` for every file.
      cache_dir = nil,
      --- Preview every fragment when a file opens (org-startup-with-latex-preview;
      --- #+STARTUP: latexpreview / nolatexpreview).
      startup = false,
    },
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
      open_at_mouse = "<MiddleMouse>",
      find_file_at_mouse = "<RightMouse>",
      -- structure
      meta_return = "<M-CR>",
      meta_shift_return = "<M-S-CR>",
      insert_heading = "<prefix>ih",
      insert_todo_heading = "<prefix>it",
      insert_subheading = "<prefix>is",
      insert_drawer = "<prefix>id",
      insert_structure_template = "<prefix>ib",
      insert_footnote = "<prefix>if",
      cite_insert = "<prefix>i@",
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
      yank = "p", -- org-yank: folds / adjusts pasted subtrees
      yank_before = "P",
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
      imenu = "gO", -- like gO in help and markdown buffers
      -- todo / priority / tags / properties
      todo_next = "cit",
      todo_prev = "ciT",
      shift_right = "<S-Right>",
      shift_left = "<S-Left>",
      todo_select = "<prefix>S",
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
      link_preview = "<prefix>xv",
      link_preview_refresh = "<prefix>xV",
      latex_preview = "<prefix>xl",
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
      cite_insert = "<C-c><C-x>@",
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
      -- no key in Emacs: C-c C-x C-r is org-toggle-radio-button (above);
      -- insert a clocktable with <C-c><C-x>x or <prefix>xr
      clock_report = false,
      clock_display = "<C-c><C-x><C-d>",
      link_preview = "<C-c><C-x><C-v>",
      link_preview_refresh = "<C-c><C-x><C-M-v>",
      latex_preview = "<C-c><C-x><C-l>",
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
      -- feeds
      feed_update_all = "<C-c><C-x>g",
      feed_goto_inbox = "<C-c><C-x>G",
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
      refile_reverse = "<C-c><C-M-w>",
      archive_subtree = { "<C-c>$", "<C-c><C-x><C-s>" },
      archive_subtree_default = "<C-c><C-x><C-a>",
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
      show_1 = false, -- Emacs: unbound
      cycle_show = false, -- Emacs: unbound
      goto_mouse = "<MiddleMouse>", -- Emacs: mouse-2
      show_mouse = "<RightMouse>", -- Emacs: mouse-3
      recenter = "L",
      delete_other_windows = "o",
      follow_mode = { "F", "vf" },
      tree_to_indirect_buffer = "<C-c><C-x>b",
      todo = { "t", "<C-c><C-t>" },
      todo_yesterday = false, -- Emacs: unbound
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
      -- Emacs: unbound (C-u / C-u C-u <S-Right>, here counts 4 / 16)
      date_later_hours = false,
      date_earlier_hours = false,
      date_later_minutes = false,
      date_earlier_minutes = false,
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
      archive_default = "<C-c><C-x><C-a>",
      archive_default_confirm = "a",
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
      toggle_diary = "D",
      diary_entry = "i", -- org-agenda-diary-entry (also in Visual mode)
      toggle_habits_display = "vh", -- Emacs: K (capture here)
      toggle_habits = false, -- Emacs: unbound
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
      convert_date = "gC", -- Emacs: C (the clock report here)
      phases_of_moon = "M",
      sunrise_sunset = "S",
      holidays = "H",
      save_all = "<C-x><C-s>",
      undo = { "<C-_>", "<C-/>", "<C-x>u" }, -- org-agenda-undo (Emacs undo keys)
      capture = "K", -- Emacs: k (kept free for motion)
      export = "<C-x><C-w>",
      help = "g?",
      show_flagging_note = "?",
      mobile_pull = "<C-c><C-x><CR>g",
      mobile_push = "<C-c><C-x><CR>p",
    },
    capture = {
      finalize = { "<C-c><C-c>", "<prefix>w" },
      kill = { "<C-c><C-k>", "<prefix>k" },
      refile = { "<C-c><C-w>", "<prefix>r" },
    },
    edit_src = {
      save_exit = { "<C-c>'", "<prefix>'" },
      abort = { "<C-c><C-k>", "<prefix>k" },
      -- the block has a :session: send the buffer (Visual: the lines) to it
      -- (org-src-associate-babel-session)
      send_to_session = { "<C-c><C-c>", "<prefix>e" },
    },
    --- Keys of the Beamer mode (org-beamer-mode-map), only while it is on.
    beamer = {
      beamer_select_environment = "<C-c><C-b>",
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
