---
area: lists
recipe: scripts/verify/recipes/lists.lua
keys: org.meta_return, org.meta_shift_return, org.toggle_checkbox, org.context_action, org.cycle_bullet, org.update_statistics
modules: lua/org/lists.lua, lua/org/lists
specs: tests/spec/lists_spec.lua, tests/spec/lists_emacs_spec.lua, tests/spec/ui_highlight_list_spec.lua
doc: org-lists, org-radio-list
emacs: org-list.el
---

# Plain lists and checkboxes

Bulleted, numbered and checkbox lists that keep their numbers, bullets
and `[n/m]` cookies right as items are added and ticked (org-list).

## How to get to it

Write an item (`- `, `+ `, `1. `, `1) `, optionally `[ ] `) in an org
buffer. The keys are Normal-mode keys on an item's line:
`{{org.meta_return}}` new item, `{{org.toggle_checkbox}}` (`<C-Space>`)
or `{{org.context_action}}` toggle its box, `{{org.cycle_bullet}}`
(`<leader>ohb`) the next bullet style.

## Driving it

| Step | Expected |
| --- | --- |
| `{{org.meta_return}}` on `- [ ] Passport` | a new `- ` item below it, Insert mode, no checkbox |
| `{{org.meta_shift_return}}` on an item | a new `- [ ] ` item |
| `{{org.meta_return}}` on `1. Boil water` | `2. ` below it, the items after renumbered `3.`, `4.` |
| `{{org.toggle_checkbox}}` on `- [ ] Tickets` | `- [X] Tickets`, the headline's `[/]` becomes `[1/3]` |
| `{{org.context_action}}` on an item's first line | the same toggle |
| `{{org.cycle_bullet}}` on `1.` | every item of the list `1)` |
| `cmd = "write"` | the file on disk has the list |

## Gotchas

- `{{org.meta_return}}` on a checkbox item makes an item without a box,
  as Emacs org-insert-item does; `{{org.meta_shift_return}}` adds one
  (org-insert-todo-heading on an item). Don't expect `[ ]` after M-CR.
- The new item's line is `- ` with a trailing space: match it with
  `line = "^%- $"` (or `"^%- %[ %] $"`, `"^2%. $"`).
- A `[/]` cookie fills in on the first toggle; an empty `[/]` in the
  file isn't stale until something changes the list
  (`{{org.update_statistics}}` updates it by hand).
- `{{org.cycle_bullet}}` changes the whole list, not only the item under
  the cursor, and renumbers it in the new style.
- Every edit changes the buffer only: write it (`cmd = "write"`) before an
  `expect.file`.
