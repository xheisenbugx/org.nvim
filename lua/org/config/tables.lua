-- Options: Tables, formulas, plots and column view.
--
-- One part of `require("org.config").defaults`, merged in the order of
-- `M.parts` in lua/org/config/init.lua. Keys keep the indentation of the
-- full table: `:Org customize` reads these files for the options and the
-- `---` documentation above each one.

---@class org.config.Resolved
local defaults = {
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
}

return defaults
