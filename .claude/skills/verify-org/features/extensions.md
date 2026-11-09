---
area: extensions
recipe: scripts/verify/recipes/extensions.lua
keys: global.kanban_open, global.journal_new_entry, org.present_start
modules: lua/org/extensions/init.lua, lua/org/extensions/kanban, lua/org/extensions/views_util.lua, lua/org/extensions/journal, lua/org/extensions/present, lua/org/extensions/caldav
specs: tests/spec/extensions_spec.lua, tests/spec/ext_kanban_spec.lua, tests/spec/ext_journal_spec.lua, tests/spec/ext_present_spec.lua, tests/spec/ext_present_edge_spec.lua, tests/spec/ext_caldav_spec.lua, tests/spec/ext_caldav_sync_spec.lua, tests/spec/ext_caldav_e2e_spec.lua
doc: org-extensions, org-extensions-kanban, org-extensions-views, org-extensions-journal, org-extensions-present, org-extensions-caldav
emacs: none (kanban), org-journal (journal), org-present (present), org-caldav (caldav)
---

# Extensions

Optional features modelled on third-party Emacs packages, shipped in
`lua/org/extensions/<name>` and loaded only when listed under
`extensions` in `setup()`. The recipe maps three that a user drives with
keys and that need no external program: the kanban board, the journal
and presentations; and the CalDAV sync, against a stand-in for the
server that runs inside the child.

## How to get to it

Enable the extension in the scenario's `setup`; the driver passes it to
`require("org").setup()` in the child:

```lua
setup = { extensions = { kanban = { save = true } } }   -- options merged over its defaults
setup = { extensions = { present = true } }             -- the defaults
```

An enabled extension registers its actions, `:Org` subcommands and
default keys, so `{{global.kanban_open}}` (`<leader>oVk`) and
`{{global.journal_new_entry}}` (`<leader>oLj`) exist only in a scenario
that enables them. `present_start` has no default key:
`{{org.present_start}}` becomes `:Org present_start<CR>`.

## Driving it

Kanban (`extensions = { kanban = { save = true } }`, `agenda_files` set):

| Step | Expected |
| --- | --- |
| `{{global.kanban_open}}` | a float `Kanban`, filetype `orgkanban`; a column per keyword with its count (`TODO  2`, `DONE  1`), a card per heading; the first card selected |
| `l` | the card moves to the next column (`TODO  1`, `DONE  2`), the selection follows it; with `save = true` the file on disk has the new keyword |
| `q` | the board closes, back in the org buffer |

Journal (`extensions = { journal = { directory = "{{dir}}/journal" } }`):

| Step | Expected |
| --- | --- |
| `{{global.journal_new_entry}}` | `20261012.org` opens with `* Monday, 2026-10-12` and `** 09:00 `, Insert mode after the time |
| type, `<Esc>`, `:write` | the file is on disk with the entry |
| again later (`wait`) | a new `** 10:30 ` entry at the end of the day |

Present (`extensions = { present = true }`):

| Step | Expected |
| --- | --- |
| `{{org.present_start}}` | a slide tab: the counter `1/3` top right; the title slide shows the `#+TITLE` value, not the keyword |
| `n` / `p` | next / previous slide: `2/3`, the headline without its stars, a rule under it, its body only |
| `q` | the source buffer as it was, the cursor on the headline of the slide that was shown |

CalDAV (`extensions = { caldav = { calendars = { { name = "Home", url =
"http://dav.test/dav/calendars/me/home/", inbox = "{{dir}}/calendar.org" } },
timezone = "UTC", state_dir = "{{dir}}/state" } }`), after a `lua` step
that starts the stand-in and makes it the transport:

```lua
local srv = dofile(vim.api.nvim_get_runtime_file("tests/support/caldav_server.lua", false)[1]).new()
srv:calendar("home")
srv:put("home", "a.ics", ics_text)          -- an event "another client" stored
require("org.extensions.caldav.http").transport = srv:transport()
_G.__caldav = srv                           -- for later `expect = { lua = ... }`
```

| Step | Expected |
| --- | --- |
| `:Org caldav_sync` | `caldav: Home: 1 from the calendar, 1 to the calendar`; the event is a new heading at the end of the inbox with its timestamp line, ID and LOCATION in the (folded) drawer; the file's own dated entry got an ID and is on the server (`srv:files("home")`); the file is saved |
| change the heading, `:Org caldav_sync` | `caldav: Home: 1 to the calendar`; on the server only SUMMARY changed (the ATTENDEE line is still there) |
| delete the entry's lines, `:Org caldav_sync` | a question: `1 entry was deleted in the org files. Delete it from the calendar too?` with the title below and `(Y)es, [N]o:` |
| `y` (a `type` step) | `caldav: Home: 1 deleted in the calendar`, no Press ENTER; the resource is gone from the server |

## Gotchas

- The header's `keys` may name an extension's keys and actions
  (`tests/spec/verify_spec.lua` reads them from each extension module),
  but they resolve only when the scenario enables the extension.
- Kanban `save` defaults to `agenda.save_after_edit`; without
  `save = true` a moved card changes the buffer only, and the file on
  disk is unchanged until it is written.
- The board's own keys (`h`/`l`, `j`/`k`, `q`) are buffer-local keys of
  the board, typed as they are, not `mappings` entries.
- `org_log_done` is off by default: a card moved to DONE gets no CLOSED
  line.
- The journal doesn't write the new file: it is a `[New]` buffer until
  `:write`. Each entry's time is the driver's clock, so `{ wait = 90 }`
  makes the next one `10:30`.
- The present slide buffer is named after the source (the state line
  says `buffer talk.org` in the slides too); tell slides from the source
  by the counter (`2/3`) or the missing stars. The `:Org present_start`
  command stays in the message area on the first slide.
- The kanban float covers the buffer but the status line under it still
  names the org file.
- CalDAV: the sync is asynchronous, so the `:Org caldav_sync` step
  returns at once; put the `expect` on that step (it waits) rather than
  reading the buffer right after. Property drawers are folded on screen:
  check `:ID:` and `:LOCATION:` with `buffer`, not `screen`.
- CalDAV: the delete question is `vim.fn.confirm()`. While it waits,
  Neovim answers no request that runs Lua, so a `key` step (it resolves
  placeholders in the child first) times out: answer with `type = "y"`.
- CalDAV: the recipe's stand-in replaces the transport, so curl isn't
  run; `tests/spec/ext_caldav_e2e_spec.lua` is what goes through real
  curl. Neither talks to a real server.
