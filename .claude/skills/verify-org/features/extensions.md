---
area: extensions
recipe: scripts/verify/recipes/extensions.lua
keys: global.kanban_open, global.journal_new_entry, org.present_start
modules: lua/org/extensions/init.lua, lua/org/extensions/kanban, lua/org/extensions/views_util.lua, lua/org/extensions/journal, lua/org/extensions/present
specs: tests/spec/extensions_spec.lua, tests/spec/ext_kanban_spec.lua, tests/spec/ext_journal_spec.lua, tests/spec/ext_present_spec.lua, tests/spec/ext_present_edge_spec.lua
doc: org-extensions, org-extensions-kanban, org-extensions-views, org-extensions-journal, org-extensions-present
emacs: none (kanban), org-journal (journal), org-present (present)
---

# Extensions

Optional features modelled on third-party Emacs packages, shipped in
`lua/org/extensions/<name>` and loaded only when listed under
`extensions` in `setup()`. The recipe maps three that a user drives with
keys and that need no external program: the kanban board, the journal
and presentations.

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
