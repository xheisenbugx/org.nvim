---@mod org.config Configuration
---
--- All options live in `require('org.config').opts`. The table is mutated in
--- place by `setup()`, so modules must read options at call time
--- (`require('org.config').opts.foo`) instead of caching sub-tables.

local M = {}

local data_dir = vim.fn.stdpath("data") .. "/org"

---@class org.Config
M.defaults = {
  --- Base directory for org files. Used to resolve relative paths.
  org_directory = "~/org",
  --- Files and globs scanned by the agenda, refile and id lookups.
  --- Directories are scanned recursively for `*.org` files.
  agenda_files = { "~/org/**/*.org" },
  --- Default target for capture templates without a `target`.
  default_notes_file = "~/org/refile.org",

  ---------------------------------------------------------------------------
  -- TODO keywords & logging
  ---------------------------------------------------------------------------
  --- Each string is a sequence, exactly like Emacs `org-todo-keywords`.
  --- `(k)` is a fast-selection key, `!` logs a timestamp, `@` asks for a note.
  --- A flat list containing a `"|"` element is also accepted.
  todo_keywords = { "TODO(t) NEXT(n) | DONE(d)" },
  --- State a repeating task returns to. nil = previous TODO state (or first).
  todo_repeat_to_state = nil,
  --- Block marking an entry DONE while children are not DONE.
  enforce_todo_dependencies = false,
  --- Block marking an entry DONE while it has unchecked checkboxes.
  enforce_todo_checkbox_dependencies = false,
  --- `false`, `"time"` (add CLOSED:) or `"note"` (CLOSED: + note).
  log_done = "time",
  --- Logging when a repeated task is marked done: false | "time" | "note".
  log_repeat = "time",
  --- Log changes of SCHEDULED / DEADLINE: false | "time" | "note".
  log_reschedule = false,
  log_redeadline = false,
  --- Drawer used for state changes, notes and clocks. `false` = no drawer.
  log_into_drawer = "LOGBOOK",
  --- Newest log entries first (Emacs default).
  log_states_order_reversed = true,

  ---------------------------------------------------------------------------
  -- Priorities & tags
  ---------------------------------------------------------------------------
  priority_highest = "A",
  priority_lowest = "C",
  priority_default = "B",
  --- Global tag list offered for completion. Strings may contain fast keys,
  --- e.g. `"work(w)"`, and `"{" ... "}"` for mutually exclusive groups.
  tags = {},
  --- Column tags are aligned to. Negative = right-align to that column.
  tags_column = -77,
  use_tag_inheritance = true,
  tags_exclude_from_inheritance = {},
  --- true, false, or a list of property names that inherit.
  use_property_inheritance = false,
  --- Properties that apply to every entry (e.g. `Effort_ALL`).
  global_properties = {},
  --- Constants for table formulas (`$name`), like `org-table-formula-constants`.
  --- `#+CONSTANTS:` lines in a file take precedence.
  table_formula_constants = {},
  effort_property = "Effort",
  columns_default_format = "%25ITEM %TODO %3PRIORITY %TAGS",

  ---------------------------------------------------------------------------
  -- Buffer behaviour
  ---------------------------------------------------------------------------
  --- "overview" | "content" | "showall" | "showeverything" | "nofold"
  startup_folded = "overview",
  --- Indent body text to the headline level (org-adapt-indentation).
  adapt_indentation = false,
  --- Indentation added to src block contents in the edit buffer.
  edit_src_content_indentation = 0,
  --- Text appended to folded headlines.
  ellipsis = " …",
  --- Blank line handling before new headlines: true | false | "auto".
  blank_before_new_entry = { heading = "auto", plain_list_item = false },
  --- Days before a deadline it starts showing up in the agenda.
  deadline_warning_days = 14,
  --- Where `archive_subtree` sends entries. `%s` = current file name.
  archive_location = "%s_archive::",
  archive_save_context_info = { "time", "file", "olpath", "category", "todo", "itags" },
  --- Heading of the sibling used by `archive_to_sibling`.
  archive_sibling_heading = "Archive",
  --- Add inherited tags to archived entries: "infile" | true | false.
  archive_subtree_add_inherited_tags = "infile",
  --- Window used for special buffers: "float" | "split" | "vsplit" | "tab" | "current"
  win_split_mode = "float",
  win_border = "rounded",

  ---------------------------------------------------------------------------
  -- Agenda
  ---------------------------------------------------------------------------
  agenda = {
    span = "week", -- "day" | "week" | "fortnight" | "month" | "year" | number of days
    start_on_weekday = 1, -- 1 = Monday, false = start on today
    start_day = nil, -- offset string like "-3d" relative to today
    skip_scheduled_if_done = false,
    skip_deadline_if_done = false,
    skip_deadline_prewarning_if_scheduled = false,
    skip_scheduled_delay_if_deadline = false,
    show_future_repeats = true, -- true | false | "next"
    todo_ignore_scheduled = false, -- false | "all" | "future" | "past"
    todo_ignore_deadlines = false, -- false | "all" | "near" | "far"
    todo_ignore_with_date = false,
    time_grid = {
      enabled = true,
      --- Emacs org-agenda-time-grid type flags.
      type = { "daily", "today", "require-timed" },
      times = { 800, 1000, 1200, 1400, 1600, 1800, 2000 },
      separator = "┄┄┄┄┄",
      time_string = "┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄",
    },
    current_time_string = "← now ─────────────────────────────",
    sorting = {
      agenda = { "time-up", "priority-down", "category-keep" },
      todo = { "priority-down", "category-keep" },
      tags = { "priority-down", "category-keep" },
      search = { "category-keep" },
    },
    --- Where the agenda opens: "current" | "split" | "vsplit" | "tab" | "float"
    window = "current",
    log_mode_items = { "closed", "clock" },
    habits = {
      graph_column = 50,
      preceding_days = 21,
      following_days = 7,
      show_habits = true,
      show_all_today = false,
    },
    stuck_projects = {
      match = "+LEVEL=2/-DONE",
      todo_keywords = { "TODO", "NEXT" },
      tags = {},
      text = nil,
    },
    --- Save source buffers after editing them from the agenda.
    save_after_edit = true,
    block_separator = "─",
    show_inherited_tags = true,
    remove_tags = false,
    custom_commands = {},
    --- Body lines shown under each entry in entry text mode (E).
    entry_text_maxlines = 5,
    --- Ask before `<C-k>` deletes an entry longer than this many lines
    --- (org-agenda-confirm-kill). false = never ask.
    confirm_kill = 1,
    start_with_log_mode = false, -- false | true | "all"
    start_with_follow_mode = false,
    start_with_clockreport_mode = false,
    start_with_entry_text_mode = false,
  },

  ---------------------------------------------------------------------------
  -- Capture
  ---------------------------------------------------------------------------
  capture = {
    --- Templates keyed by selection key. See `:h org-capture-templates`.
    templates = {
      t = { description = "Task", template = "* TODO %?\n  %U" },
    },
    window = "float", -- "float" | "split" | "vsplit" | "current"
  },

  ---------------------------------------------------------------------------
  -- Refile
  ---------------------------------------------------------------------------
  refile = {
    max_level = 3,
    use_outline_path = "file", -- "file" | true | false
    allow_creating_parent_nodes = false,
    include_current_file = true,
  },

  ---------------------------------------------------------------------------
  -- Clocking
  ---------------------------------------------------------------------------
  clock = {
    out_when_done = true,
    into_drawer = true, -- true = log_into_drawer, or a drawer name
    out_remove_zero_time = true,
    --- State to switch to on clock in: a keyword, or function(headline) -> keyword|nil
    in_switch_to_state = nil, -- e.g. "NEXT"
    statusline_icon = "⏱",
    clocktable_default = { maxlevel = 3, scope = "file", block = nil },
    persist = true,
    persist_file = data_dir .. "/clock.json",
  },

  ---------------------------------------------------------------------------
  -- Links / IDs / attachments
  ---------------------------------------------------------------------------
  links = {
    --- `#+LINK` style abbreviations: { gh = "https://github.com/%s" }
    abbreviations = {},
    --- Custom link handlers: { jira = function(path, link) ... end }
    types = {},
    --- Ask before running shell: links.
    confirm_shell = true,
    --- Store links to headlines with an ID (creating one if needed).
    use_id = "create-if-interactive", -- true | false | "create-if-interactive"
    --- Open files with an extension via external app: { pdf = "open" }
    file_apps = {},
  },
  id = {
    locations_file = data_dir .. "/id-locations.json",
    method = "uuid", -- "uuid" | "ts"
  },
  attach = {
    dir = "data/",
    method = "cp", -- "cp" | "mv" | "ln"
  },

  ---------------------------------------------------------------------------
  -- Babel
  ---------------------------------------------------------------------------
  babel = {
    confirm_evaluate = true,
    min_lines_for_block_output = 10,
    timeout = 30000,
    default_header_args = {
      results = "replace",
      exports = "code",
      session = "none",
      noweb = "no",
      tangle = "no",
    },
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
      awk = { cmd = "awk -f", ext = "awk" },
    },
  },

  ---------------------------------------------------------------------------
  -- Export
  ---------------------------------------------------------------------------
  export = {
    output_dir = nil, -- nil = next to the source file
    with_toc = true,
    with_section_numbers = true,
    headline_levels = 3,
    with_author = true,
    with_date = true,
    with_todo_keywords = true,
    with_tags = true,
    with_priority = false,
    with_drawers = false,
    with_planning = false,
    with_timestamps = true,
    select_tags = { "export" },
    exclude_tags = { "noexport" },
    open_after_export = false,
    html = {
      style = nil, -- nil = built-in stylesheet, false = none, string = CSS
      head_extra = "",
      mathjax = true,
    },
    --- Line width of the plain-text (UTF-8) exporter.
    text_width = 72,
    pandoc = { cmd = "pandoc", args = {} },
  },

  ---------------------------------------------------------------------------
  -- Notifications (appointment reminders)
  ---------------------------------------------------------------------------
  notifications = {
    enabled = false,
    --- Minutes before a timed scheduled/deadline entry to notify.
    reminder_time = { 10, 0 },
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
    --- Conceal link brackets and show only descriptions.
    conceal_links = true,
    --- Hide *, /, _, =, ~, + around emphasized text.
    hide_emphasis_markers = false,
    --- Show only the last star of each headline.
    hide_leading_stars = false,
    --- Replace headline stars with symbols. false or list per level.
    bullets = false, -- e.g. { "◉", "○", "✸", "✿" }
    --- Replace checkboxes with icons. false or { unchecked, partial, checked }
    checkboxes = false, -- e.g. { " ", "◐", "✓" }
    --- Virtual indentation of body text (org-indent-mode).
    indent_mode = false,
    --- Render \alpha etc. as unicode (org-pretty-entities).
    pretty_entities = false,
    --- Dim the whole headline of DONE entries.
    fontify_done_headline = true,
    --- Syntax-include the languages of src blocks for highlighting.
    src_highlight = true,
    --- Per-keyword faces: { WAITING = ":foreground orange :weight bold" }
    --- or a highlight definition table { fg = "#ff9e64", bold = true } or a group name.
    todo_keyword_faces = {},
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
      -- refile / archive / attach
      refile = "<prefix>r",
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
      -- babel
      edit_special = "<prefix>'",
      babel_execute = "<prefix>be",
      babel_execute_buffer = "<prefix>bb",
      babel_execute_subtree = "<prefix>bs",
      babel_tangle = "<prefix>bt",
      babel_remove_result = "<prefix>bk",
      babel_next_block = "<prefix>bn",
      babel_prev_block = "<prefix>bp",
    },
    --- Insert-mode mappings inside org buffers.
    org_insert = {
      meta_return = "<M-CR>",
      table_next_field = "<Tab>",
      table_prev_field = "<S-Tab>",
      table_next_row = "<CR>",
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
      -- visibility
      show_branches = "<C-c><C-k>",
      show_children = "<C-c><Tab>",
      reveal = "<C-c><C-r>",
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
      toggle_ordered = "<C-c><C-x>o",
      add_note = "<C-c><C-z>",
      -- dates
      schedule = "<C-c><C-s>",
      deadline = "<C-c><C-d>",
      timestamp = "<C-c>.",
      timestamp_inactive = "<C-c>!",
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
      open_at_point = "<C-c><C-o>",
      next_link = "<C-c><C-x><C-n>",
      prev_link = "<C-c><C-x><C-p>",
      -- refile / archive / attach / agenda files
      refile = "<C-c><C-w>",
      archive_subtree = { "<C-c>$", "<C-c><C-x><C-s>", "<C-c><C-x><C-a>" },
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
      -- babel (C-c C-v)
      babel_execute = { "<C-c><C-v>e", "<C-c><C-v><C-e>" },
      babel_execute_buffer = { "<C-c><C-v>b", "<C-c><C-v><C-b>" },
      babel_execute_subtree = { "<C-c><C-v>s", "<C-c><C-v><C-s>" },
      babel_tangle = { "<C-c><C-v>t", "<C-c><C-v><C-t>" },
      babel_remove_result = "<C-c><C-v>k",
      babel_next_block = { "<C-c><C-v>n", "<C-c><C-v><C-n>" },
      babel_prev_block = { "<C-c><C-v>p", "<C-c><C-v><C-p>" },
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
      exit = "x",
      redo = "r",
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
      set_effort = { "e", "<C-c><C-x>e" },
      timer = ";",
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
      clockreport_mode = { "C", "vR" },
      entry_text_mode = { "E", "vE" },
      archives_mode = "va",
      archives_files_mode = "vA",
      inactive_mode = "v[",
      time_grid = { "G", "vG" },
      filter_tag = "/",
      filter_category = "<",
      filter_regexp = "=",
      filter_effort = "_",
      filter_top_headline = "^",
      filter_remove = "|",
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
      save_all = "<C-x><C-s>",
      capture = "c", -- Emacs: k (kept free for motion)
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

---@type org.Config
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

---@param opts? table
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
