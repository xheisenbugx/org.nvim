-- Options: Clocking.
--
-- One part of `require("org.config").defaults`, merged in the order of
-- `M.parts` in lua/org/config/init.lua. Keys keep the indentation of the
-- full table: `:Org customize` reads these files for the options and the
-- `---` documentation above each one.

local data_dir = vim.fn.stdpath("data") .. "/org"

---@class org.config.Resolved
local defaults = {
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
}

return defaults
