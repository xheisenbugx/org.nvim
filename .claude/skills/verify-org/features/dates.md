---
area: dates
recipe: scripts/verify/recipes/dates.lua
keys: org.timestamp, org.timestamp_inactive, org.schedule, org.deadline, org.shift_up, org.shift_down, org.shift_right, org.shift_left
modules: lua/org/timestamps.lua, lua/org/date.lua, lua/org/calendar.lua, lua/org/context.lua
specs: tests/spec/timestamps_spec.lua, tests/spec/calendar_spec.lua, tests/spec/calendar_prompt_spec.lua, tests/spec/context_spec.lua, tests/spec/parser_planning_spec.lua
doc: org-dates, org-calendar, org-read-date
emacs: org.el (org-timestamp, org-schedule, org-deadline, org-timestamp-change, org-read-date)
---

# Dates and timestamps

Put a date on an entry (a timestamp, SCHEDULED, DEADLINE), picked in a
calendar or typed, and move it a day or a month at a time (org-timestamp,
org-schedule, org-deadline, org-shiftup / org-shiftright).

## How to get to it

Open an org file. `{{org.timestamp}}` (`<leader>oi.`) inserts an active
timestamp, `{{org.timestamp_inactive}}` (`<leader>oi!`) an inactive one,
`{{org.schedule}}` (`<leader>os`) / `{{org.deadline}}` (`<leader>od`)
add the planning line under the heading. Each opens a floating calendar
(titled "Timestamp", "Schedule", ...). On a timestamp,
`{{org.shift_right}}` / `{{org.shift_left}}` (`S-Right` / `S-Left`) move
it a day, `{{org.shift_up}}` / `{{org.shift_down}}` (`S-Up` / `S-Down`)
change the part under the cursor.

## Driving it

| Step | Expected |
| --- | --- |
| `{{org.timestamp}}` | the calendar: "October 2026", "Monday, 12 October 2026", `<2026-10-12 Mon>  today` |
| `l` (`h`, `j`, `k`: day / week) | "Tuesday, 13 October 2026", "tomorrow" |
| `<CR>` | `<2026-10-13 Tue>` at the cursor, calendar gone |
| `{{org.timestamp}}` again right away, `ll<CR>` | `<2026-10-12 Mon>--<2026-10-14 Wed>`: a range |
| `{{org.schedule}}`, `i` | a "Date:" prompt under the calendar |
| type `fri` | the calendar follows: `=> <2026-10-16 Fri>    in 4 days` |
| `<CR>` | `SCHEDULED: <2026-10-16 Fri>` on the line under the heading |
| `{{org.shift_right}}` on `<2026-10-12 Mon>` | `<2026-10-13 Tue>` |
| `{{org.shift_up}}` on the day | `<2026-10-14 Wed>` |
| `{{org.shift_up}}` on the month | `<2026-11-14 Sat>` (the weekday follows) |

## Gotchas

- The calendar is a float the cursor doesn't enter: while it is open the
  driver's `buffer` / `filetype` still name the org file, and the mode is
  `n` (`c` once `i` opens the "Date:" prompt). Check the calendar on the
  screen.
- The calendar reads its keys itself: send them as `key` steps
  (`l`, `<CR>`), and the typed date with a `type` step after `i`.
- The driver's clock is Monday 2026-10-12 09:00: the calendar opens on
  that day, `fri` is the 16th, and the relative text ("today",
  "tomorrow", "in 4 days") counts from it.
- The planning line is not indented (`adapt_indentation = false`, as
  `org-adapt-indentation` is nil by default): expect
  `SCHEDULED: <...>`, not `  SCHEDULED: <...>`.
- After the prompt closes, its text ("Date: fri") stays in the message
  area; it is not an error.
- `{{org.shift_up}}` / `{{org.shift_down}}` change the part under the
  cursor (year, month, day, hour, minute); `{{org.shift_right}}` /
  `{{org.shift_left}}` always move the day. Put the cursor with
  `{ at = "<2026", col = "10-14" }` (the month) before an up/down step.
  Off a timestamp these keys do other things (TODO state, priority).
- Inserting twice in a row makes a range only when nothing happens in
  between: the same buffer, window, cursor and changedtick
  (`is_repeat` in `lua/org/timestamps.lua`). An `at` step that moves the
  cursor, or any edit, between the two gives a second timestamp instead
  of a range.
- The buffer changes, not the file: `cmd = "write"` before an
  `expect.file`.
- Under heavy machine load a step typed into the "Date:" prompt once
  failed with "the screen didn't settle within 10000 ms" and passed on
  every rerun; rerun before suspecting the calendar.
