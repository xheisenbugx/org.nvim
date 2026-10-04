-- Options: Agenda.
--
-- One part of `require("org.config").defaults`, merged in the order of
-- `M.parts` in lua/org/config/init.lua. Keys keep the indentation of the
-- full table: `:Org customize` reads these files for the options and the
-- `---` documentation above each one.

---@class org.config.Resolved
local defaults = {
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
    --- In the agenda column view, an entry shows the summary of its
    --- children, computed in its file
    --- (org-agenda-columns-compute-summary-properties).
    columns_compute_summary_properties = true,
    --- In the agenda column view, an appointment without an effort counts
    --- its duration as effort (org-agenda-columns-add-appointments-to-effort-sum).
    columns_add_appointments_to_effort_sum = false,
    --- Extra files for the search view; "agenda-archives" adds the archive
    --- files (org-agenda-text-search-extra-files).
    text_search_extra_files = {},
    --- Skip agenda files that do not exist instead of asking to remove
    --- them (org-agenda-skip-unavailable-files).
    skip_unavailable_files = false,
    --- The agenda index (`:h org-agenda-index`, not in Emacs): agenda files
    --- parsed in the background and kept in stdpath("cache"), so that the
    --- first agenda view over many files doesn't wait for them all.
    index = {
      --- false: agenda files are parsed only when a view needs them.
      enabled = true,
      --- Keep the parse on disk (stdpath("cache")/org/agenda-index.bin).
      cache = true,
      --- Parse the agenda files in the background from the first org
      --- buffer; false: when a view needs them (and add them to the index).
      background = true,
      --- Watch the agenda files' directories to parse changed files early.
      watch = true,
      --- Directories watched at most; the others are polled.
      max_watchers = 32,
      --- Seconds between polls of directories without a watcher (0: none).
      poll_interval = 30,
    },
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
}

return defaults
