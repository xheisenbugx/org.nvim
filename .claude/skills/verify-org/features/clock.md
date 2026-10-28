---
area: clock
recipe: scripts/verify/recipes/clock.lua
keys: org.clock_in, org.clock_out, org.clock_cancel, org.clock_display, org.clock_report, global.clock_out, global.clock_goto
modules: lua/org/clock.lua, lua/org/clock
specs: tests/spec/clock_spec.lua, tests/spec/clock_emacs_spec.lua, tests/spec/clock_options_spec.lua, tests/spec/emacs_clocktable_parity_spec.lua, tests/spec/ui_tables_clock_overlays_spec.lua
doc: org-clock, org-clocktable
emacs: org-clock.el
---

# Clocking time

Track the time spent on a task: clock in on its heading, clock out when
done, and see the sums per heading or as a clock table (org-clock-in,
org-clock-out, org-clock-display, org-clock-report).

## How to get to it

Open an org file, the cursor on (or under) a heading.
`{{org.clock_in}}` (`<leader>oxi`) clocks in, `{{org.clock_out}}`
(`<leader>oxo`, also global: `{{global.clock_out}}`) clocks out,
`{{org.clock_cancel}}` (`<leader>oxq`) drops the running clock.
`{{org.clock_display}}` (`<leader>oxd`) shows the time next to each
headline, `{{org.clock_report}}` (`<leader>oxr`) inserts a
`#+BEGIN: clocktable` block. `{{global.clock_goto}}` (`<leader>oxj`)
jumps to the clocked entry. The running clock shows in
`require("org").statusline()`.

## Driving it

| Step | Expected |
| --- | --- |
| `{{org.clock_in}}` | "Clock starts at [2026-10-12 Mon 09:00] - showing entire task time."; `:LOGBOOK:` / `CLOCK: [2026-10-12 Mon 09:00]` / `:END:` under the heading, drawer folded (`:LOGBOOK:...`) |
| statusline set to `%{v:lua.require'org'.statusline()}` | `⏱ [0:00] (Write the report)` |
| `wait = 90`, `redrawstatus` | `⏱ [1:30] (Write the report)` |
| `{{org.clock_out}}` | "Clock stopped at [2026-10-12 Mon 10:30] after 1:30"; the line ends `--[2026-10-12 Mon 10:30] =>  1:30` |
| `{{org.clock_in}}` on another heading | the first clock closed at that time, a new one opened |
| `{{org.clock_display}}` | `* Project····…      2:15` on each headline; "Total file time: 2:15 (2 hours and 15 minutes)" |
| `{{org.clock_report}}` on a heading | a `#+BEGIN: clocktable :scope subtree :maxlevel 2` block under the heading, with a `#+CAPTION: Clock summary at [...]` and the table |

## Gotchas

- The `wait` step moves the clock (`os.time`, `os.date`), not real time:
  the times in the CLOCK line and the duration come from it. Timers
  (the minute tick in `lua/org/clock/timers.lua`, idle detection) still run on real time.
- The driver's statusline (`%t ... %l:%c`) replaces org's clock display.
  Set `statusline` to `%{v:lua.require'org'.statusline()}` with a `cmd`
  step to see it, and `cmd = "redrawstatus"` after a `wait`: the
  driver's `redraw` doesn't redraw a statusline, so it keeps the old
  time (`[0:00]` after 90 minutes) until then.
- Clocking in folds the LOGBOOK drawer: the screen shows `:LOGBOOK:...`,
  never the CLOCK line. Check it with `buffer` or, after a write, `file`.
- The duration has two spaces after `=>` for one-digit hours
  (`=>  1:30`, `=>  0:25`): match it exactly.
- Clock lines go into `:LOGBOOK:` by default (`clock.into_drawer =
  true`), right under the heading.
- Clocking in elsewhere clocks the running task out first: two CLOCK
  lines, the first ending when the second starts. The lines below the
  first heading move down by three (the drawer), so `at` the next
  heading by its text, not a line number.
- The clock table's caption has the driver's clock in it
  (`[2026-10-12 Mon 09:00]`), and its block opens with `:scope subtree`
  on a heading (before the first heading it reports the file).
- `{{org.clock_display}}` draws the sums as virtual text (the `·` dots
  and the time are not in the buffer): check them with `screen`.
- Clocking in and out and the clock report change the buffer only;
  `cmd = "write"` before an `expect.file`. A scenario may end with a
  clock running: the driver closes the child without the
  `clock.ask_before_exiting` question getting in the way (tried).
