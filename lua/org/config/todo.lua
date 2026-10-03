-- Options: Files, TODO keywords and logging.
--
-- One part of `require("org.config").defaults`, merged in the order of
-- `M.parts` in lua/org/config/init.lua. Keys keep the indentation of the
-- full table: `:Org customize` reads these files for the options and the
-- `---` documentation above each one.

---@class org.config.Resolved
local defaults = {
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
}

return defaults
