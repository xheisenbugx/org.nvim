---
area: todo
recipe: scripts/verify/recipes/todo.lua
keys: org.todo_next, org.todo_prev, org.shift_right, emacs.todo, org.priority, org.shift_up, org.shift_down, org.set_tags
modules: lua/org/todo.lua, lua/org/todo_keywords.lua, lua/org/priority.lua, lua/org/tags.lua
specs: tests/spec/todo_spec.lua, tests/spec/todo_type_spec.lua, tests/spec/log_notes_spec.lua, tests/spec/tags_spec.lua, tests/spec/todo_tags_props_emacs_spec.lua
doc: org-todo, org-priority, org-tags, org-fast-tag-selection
emacs: org.el
---

# TODO states, priorities and tags

Changing a headline's TODO keyword (cycling, fast selection, keyword
sets), logging the change (CLOSED, the LOGBOOK, notes), its `[#A]`
priority and its `:tags:` (org-todo, org-priority, org-set-tags-command).

## How to get to it

Normal-mode keys on a headline. `{{org.todo_next}}` / `{{org.todo_prev}}`
(`cit` / `ciT`) and `{{org.shift_right}}` (`<S-Right>`) cycle the
keyword; `{{emacs.todo}}` (`<C-c><C-t>`) cycles too, or opens the `TODO
state` menu when the keywords have fast keys (`TODO(t)`).
`{{org.priority}}` (`<leader>o,`) asks for a priority,
`{{org.shift_up}}` / `{{org.shift_down}}` (`<S-Up>` / `<S-Down>`) step
it. `{{org.set_tags}}` (`<leader>ot`) asks for tags (`Tags:` with
completion), or opens the `Tags` key menu when some tag has a fast key.

Logging comes from the options: `log_done = "time"` adds CLOSED,
`!` / `@` on a keyword (`"DONE(d!)"`, `"WAITING(w@/!)"`) log a timestamp
or a note, `log_into_drawer = true` puts them in `:LOGBOOK:`.

## Driving it

| Step | Expected |
| --- | --- |
| `{{org.todo_next}}` on `* Water the plants` | `* TODO Water the plants`, then `DONE`, then no keyword |
| `{{org.todo_next}}` to DONE with `log_done = "time"` | `CLOSED: [2026-10-12 Mon 09:00]` on the next line |
| `{{org.todo_prev}}` back to TODO | the CLOSED line removed |
| `{{emacs.todo}}` with fast keys | the `TODO state` menu: the sequences, keys, `(current)`, `SPC (clear keyword)` |
| `d` (DONE is `d!`, `log_into_drawer = true`) | `* DONE ...`, `:LOGBOOK:...` (folded) below it |
| `w` (WAITING is `w@`) | a `*Org Note*` split in Insert mode with `# Insert note for state change from "TODO" to "WAITING".` |
| a note, `<Esc><C-c><C-c>` | the split closes; the note in the LOGBOOK under `- State "WAITING" ... \\` |
| `{{org.priority}}` | `Priority A-C, SPC to remove:`; a letter sets `[#A]`, `<Space>` removes it |
| `{{org.shift_up}}` on a headline without a cookie | `[#B]` (the default), then `[#A]` |
| `{{org.set_tags}}`, `home:money<CR>` | `:home:money:` right-aligned, ending in column 77 |
| `{{org.set_tags}}` with `tags = { "home(h)", ... }` | the `Tags` menu, `Current:` the headline's tags; keys toggle, `<CR>` accepts |

## Gotchas

- `log_done` is off by default: DONE adds no CLOSED line. A `!` on the
  done keyword (`DONE(d!)`) logs the state change only, without CLOSED,
  as Emacs's org-todo does (CLOSED needs org-log-done).
- The LOGBOOK drawer folds as soon as it is made: the screen shows
  `:LOGBOOK:...`, not its lines. Check the entry in the buffer or the
  file, not on the screen.
- The `*Org Note*` keys are `<C-c><C-c>` (store) and `<C-c><C-k>`
  (cancel), set in the note buffer, not mappings: type them literally,
  after `<Esc>`. With `note_buffer = false` it is a one-line prompt.
- The log line pads the states: `- State "DONE"       from "NEXT"       [...]`
  (org-log-note-headings with `%-12s`); a note ends the line with ` \\`
  and goes on the next line, indented two spaces.
- `{{org.shift_right}}` and `{{org.shift_up}}` are context keys: on a
  timestamp they change the date, on a list bullet the bullet. Put the
  cursor on the headline's keyword or title.
- `{{emacs.todo}}` without fast keys cycles like `{{org.todo_next}}`, so
  the menu appears only with keys in `todo_keywords` (or `#+TODO:`).
- Tags align to `tags_column = -77`: the line is exactly 77 columns,
  so an `expect.file` line needs the padding (`string.rep(" ", n)`).
- In the fast tag menu a key toggles the tag; the menu stays open until
  `<CR>` (unless `fast_tag_selection_single_key`).
- Every change is in the buffer only: write it (`cmd = "write"`) before
  an `expect.file`.
