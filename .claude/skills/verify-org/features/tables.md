---
area: tables
recipe: scripts/verify/recipes/tables.lua
keys: org_insert.insert_tab, org_insert.table_prev_field, org_insert.table_next_row, org.table_insert_hline, org.table_insert_row, org.table_insert_column, org.shift_meta_down, org.shift_meta_right, org.context_action, org.table_recalc, org.table_create
modules: lua/org/table.lua, lua/org/table
specs: tests/spec/table_spec.lua, tests/spec/table_emacs_spec.lua, tests/spec/table_parity_spec.lua, tests/spec/table_more_spec.lua, tests/spec/tblfm_emacs_spec.lua, tests/spec/ui_highlight_table_spec.lua
doc: org-tables, org-tblfm, org-table-formulas
emacs: org-table.el
---

# Tables

Plain-text tables that line themselves up as you type, with rows and
columns added in place and `#+TBLFM:` formulas recalculated
(org-table).

## How to get to it

Start a line with `|` in an org buffer. Most table keys work in Insert
mode (`{{org_insert.insert_tab}}` next field, `{{org_insert.table_prev_field}}`
previous, `{{org_insert.table_next_row}}` same field one row down); the
structure keys are Normal-mode keys. `{{org.table_create}}` makes an
empty table.

## Driving it

| Step | Expected |
| --- | --- |
| Insert mode, type `\|Item\|Qty`, `{{org_insert.insert_tab}}` | `\| Item \| Qty \|` aligned, a new empty row, cursor in its first field |
| type a field, `{{org_insert.insert_tab}}` | the table realigned to the widest field; numbers right-aligned |
| type `\|Item\|Qty\|`, `{{org_insert.table_next_row}}` | a plain new line below the row, no new row (org-return) |
| `{{org.table_insert_hline}}` on a row | `\|--------+-----\|` below it |
| `{{org.shift_meta_down}}` (M-J) | an empty row above the cursor's |
| `{{org.table_insert_row}}`; with a count | an empty row above the cursor's; below it |
| `{{org.shift_meta_right}}` (M-L) | an empty column left of the cursor's |
| `{{org.context_action}}` on `#+TBLFM: $4=$2*$3` | column 4 filled in every data row |
| change a field, `{{org.table_recalc}}` | the formula column recomputed |
| `cmd = "write"` | the file on disk has the table |

## Gotchas

- `{{org_insert.table_next_row}}` (`<CR>` in Insert mode) goes to the
  next row only from inside the row. After the last `|` (only blanks
  after the cursor) or before the first one it is a plain newline that
  splits the table, as Emacs org-return does: typing `|Item|Qty|` then
  `<CR>` leaves the header unaligned on its line until the next
  `{{org_insert.insert_tab}}` or leaving Insert mode. orgtbl-mode's `<CR>`
  (orgtbl-ret) always goes to the next row.
- While typing, the field just grows (`| Apples    |`); the table is
  aligned only on `{{org_insert.insert_tab}}`, `{{org_insert.table_prev_field}}`,
  `{{org_insert.table_next_row}}` or leaving Insert mode. Check the screen
  after one of those.
- `{{org.table_insert_row}}` (`<prefix>Tr`), `{{org.shift_meta_down}}`
  (M-J) and the menu all put the new row above the cursor's, as Emacs
  org-table-insert-row does; with a count (`4{{org.table_insert_row}}`,
  Emacs C-u) the row goes below. `{{org.table_insert_column}}` and
  `{{org.shift_meta_right}}` both insert left of the cursor's column.
- Put the cursor in a field with `at` and `col` (`{ at = "Pears", col = "3" }`):
  the structure keys act on the cursor's row and column.
- Every edit changes the buffer only: write it (`cmd = "write"`) before an
  `expect.file`.
- Alignment, faces and hline drawing are pinned by
  `tests/spec/ui_highlight_table_spec.lua` and the formula language by the
  `tblfm_*` specs; the recipe checks a user's path through it.
