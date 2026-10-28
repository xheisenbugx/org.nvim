---
area: columns
recipe: scripts/verify/recipes/columns.lua
keys: org.column_view
modules: lua/org/columns.lua, lua/org/columns
specs: tests/spec/columns_spec.lua, tests/spec/columns_overlay_spec.lua, tests/spec/columns_emacs_spec.lua, tests/spec/columns_parity_spec.lua
doc: org-columns, org-properties
emacs: org-colview.el
---

# Column view

Headlines and their properties shown as a table drawn over the outline,
with summaries on parents, and values edited in place (org-columns).

## How to get to it

`{{org.column_view}}` (`<leader>oC`) in an org buffer. The format is the
nearest `COLUMNS` property (its subtree), else `#+COLUMNS:`, else
`columns_default_format`. The view's keys (`e`, `n`, `p`, `l`, `h`, `$`,
`q`, ...) are not mappings: they're typed as they are, and only while the
view is on.

## Driving it

| Step | Expected |
| --- | --- |
| `{{org.column_view}}` on a file with `:COLUMNS: %25ITEM %TODO %Effort{:}` | `ITEM \| TODO \| Effort \|` on the top row, each headline as `** Plant the bulbs        \| TODO \| 1:00   \|`, the parent with the `{:}` sum |
| `l` / `h`, `$` | the next / previous column, the last column |
| `n` on the Effort column (with `Effort_ALL`) | the next allowed value; the parent's summary follows |
| `e` on it | "Effort value" and a numbered list of the allowed values; a number and `<CR>` sets it |
| `n` on the TODO column | TODO → DONE in the row |
| `x` (any key that edits text) on a row | "Text is read-only: Type ‘e’ to edit property", nothing changes |
| `q` | the headlines back as text, with the new values |
| `cmd = "write"` | the property drawer (or headline) on disk has the value |

## Gotchas

- The column titles are in the window's winbar, the first row of the
  screen dump; the rows are extmarks over the headlines. `screen` sees
  both; `buffer` and `line` see the headline text, which the view doesn't
  change.
- Move between columns with `l` / `h` / `$`, not by counting characters:
  the view gives each column one buffer character past the headline
  (with 'virtualedit'), so the cursor column in the evidence header (the
  byte column) is the same on every column after the end of the line.
  Which column you're on shows in what `e` asks or `n` changes.
- `e` on a property with allowed values (`PROP_ALL`) goes through
  `vim.ui.select`, which in the driver (no picker plugin) is Neovim's
  numbered inputlist: answer with `key = "3<CR>"`. Without allowed values
  it is an `Edit: ` input line (`lua/org/columns/edit.lua`).
- The "Text is read-only" message isn't an error: the step passes without
  `allow_error`, so check it with `screen`.
- Values change the buffer right away (also the parent's summary in the
  view); write it (`cmd = "write"`) before an `expect.file`. A summary is
  written to the parent only when the parent already has that property.
- `n` on the TODO column marks DONE without a CLOSED line: `log_done` is
  off by default, as `org-log-done` is in Emacs.
