---
area: agenda
recipe: scripts/verify/recipes/agenda.lua
keys: global.agenda, agenda.quit, agenda.todo, agenda.later, agenda.earlier, agenda.today, agenda.save_all, agenda.switch_to, agenda.goto, agenda.redo, agenda.schedule, agenda.deadline, agenda.priority_up, agenda.set_tags, agenda.clock_in, agenda.refile, agenda.archive, agenda.day_view, agenda.week_view
modules: lua/org/agenda, lua/org/agenda/items.lua, lua/org/agenda/render.lua, lua/org/agenda/view.lua
specs: tests/spec/agenda_spec.lua, tests/spec/agenda_view_spec.lua, tests/spec/agenda_dispatch_spec.lua, tests/spec/agenda_emacs_spec.lua, tests/spec/emacs_agenda_parity_spec.lua, tests/spec/ui_agenda_rendering_spec.lua
doc: org-agenda, org-agenda-keys, org-agenda-custom-commands, org-agenda-prefix
emacs: org-agenda.el
---

# Agenda

One view of what is scheduled, due and timestamped across the agenda
files, acted on in place (org-agenda).

## How to get to it

`{{global.agenda}}` (`<leader>oa`) opens the dispatcher, a floating menu.
Its keys are typed as they show, not mappings: `a` week agenda, `t` TODO
list, `m` tags match, `s` search, `<` restricts to the current buffer
first. The view opens in a split under the org window (filetype
`orgagenda`).

## Driving it

| Step | Expected |
| --- | --- |
| `{{global.agenda}}` | the menu, "Agenda for current week or day" |
| `a` | "Week-agenda (W42):", one line per day from Monday 12 October 2026 |
| (on an entry) `{{agenda.todo}}` | the line and the org buffer go TODO → DONE |
| `{{agenda.save_all}}` | the files on disk change |
| `{{agenda.later}}` / `{{agenda.earlier}}` | the next / previous week, header W43 / W42 |
| `{{agenda.switch_to}}` | the org file, cursor on the entry |
| `{{agenda.quit}}` | the agenda window closes |

Entry lines read `  todo:       Scheduled:  TODO Renew the passport`:
the file (category), the time or kind (`Scheduled:`, `Deadline:`,
`In   2 d.:` for a deadline coming up, `14:00 ┄┄┄┄┄` for a time of day),
then the headline.

## Gotchas

- The org window stays on screen above the agenda, so a `no_screen` on a
  headline's text still finds it there. Check the agenda's own lines
  (the header, the date lines), or `buffer` (the current buffer only).
- The agenda edits the org buffers, not the files: save
  (`{{agenda.save_all}}`, org-save-all-org-buffers) before an
  `expect.file`.
- No CLOSED line when marking done unless `log_done = "time"`: it is off
  by default, as `org-log-done` is in Emacs.
- The driver's clock is Monday 2026-10-12 09:00: the week is W42,
  12 – 18 October. Write dates in recipes from that.
- `agenda_files` must list the scenario's files (`"{{dir}}/todo.org"` or
  `"{{dir}}/*.org"`); with none the agenda is empty, which looks like a
  bug and isn't.
- Rendering (faces, the time grid, column alignment) is pinned by screen
  snapshots (`tests/spec/screen_snapshot_spec.lua`), and the lines of a
  view by real Emacs output (`tests/spec/emacs_agenda_parity_spec.lua`).
  The recipe checks a user's path through it; it doesn't replace them.
