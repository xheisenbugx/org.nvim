---
area: structure
recipe: scripts/verify/recipes/structure.lua
keys: org.meta_return, org.insert_todo_heading, org.insert_subheading, org.promote_heading, org.demote_heading, org.promote_subtree, org.demote_subtree, org.meta_right, org.meta_down, org.move_subtree_up, org.cut_subtree, org.paste_subtree, org.clone_subtree, org.sort, org.narrow_subtree, edit_src.save_exit, org.next_heading, org.prev_heading, org.next_sibling, org.prev_sibling, org.goto_parent
modules: lua/org/structure.lua, lua/org/structure, lua/org/context.lua, lua/org/special.lua
specs: tests/spec/structure_spec.lua, tests/spec/structure_emacs_spec.lua, tests/spec/structure_parity_spec.lua, tests/spec/structure_features_spec.lua
doc: org-structure, org-meta-return, org-promote-demote, org-move-subtree, org-kill-subtree, org-sort, org-narrow, org-motions
emacs: org.el
---

# Outline editing

Inserting headings, changing their level, moving, cutting, pasting and
cloning subtrees, sorting children, narrowing to a subtree and moving
between headings (Emacs's structure editing commands in org.el).

## How to get to it

Normal-mode keys on a headline (or in its body). `{{org.meta_return}}`
(`<M-CR>`) inserts a heading, `{{org.insert_todo_heading}}`
(`<leader>oit`) a TODO heading after the subtree,
`{{org.insert_subheading}}` (`<leader>ois`) a child. `{{org.demote_heading}}`
/ `{{org.promote_heading}}` (`>>` / `<<`) change the headline alone,
`{{org.demote_subtree}}` / `{{org.promote_subtree}}` (`>s` / `<s`) the
subtree, `{{org.meta_right}}` (`<M-l>`) is Emacs's M-Right.
`{{org.meta_down}}` (`<M-j>`) and `{{org.move_subtree_up}}`
(`<leader>oK`) move a subtree past its sibling. `{{org.cut_subtree}}`
(`<leader>ohd`), `{{org.paste_subtree}}` (`<leader>ohp`),
`{{org.clone_subtree}}` (`<leader>ohc`), `{{org.sort}}` (`<leader>ohs`),
`{{org.narrow_subtree}}` (`<leader>ohn`). Motions: `{{org.next_heading}}`
/ `{{org.prev_heading}}` (`]]` / `[[`), `{{org.next_sibling}}` /
`{{org.prev_sibling}}` (`][` / `[]`), `{{org.goto_parent}}` (`g{`).

## Driving it

| Step | Expected |
| --- | --- |
| `{{org.meta_return}}` on `** Laundry` (Normal mode) | `** ` right below the headline line, Insert mode; the body moves under the new heading |
| `{{org.insert_todo_heading}}` | `** TODO ` after the end of the subtree, Insert mode |
| `{{org.insert_subheading}}` on `* Errands` | `** ` as its child, Insert mode |
| `{{org.demote_heading}}` on `** Garden` | `*** Garden`; its children keep their stars |
| `{{org.demote_subtree}}` | the headline and every child one star deeper |
| `{{org.meta_down}}` | the subtree after its next sibling, the cursor still on it |
| `{{org.move_subtree_up}}` on a first child | `Cannot move past superior level or buffer limit`, nothing moves |
| `{{org.cut_subtree}}` | the subtree gone, `Cut: Subtree(s) with N characters` |
| `{{org.paste_subtree}}` in column 0 of `** Kitchen` | the subtree before it at level 2, `Clipboard pasted as level 2 subtree` |
| `{{org.clone_subtree}}`, `2<CR>`, `+1w<CR>` | `Number of clones to produce:`, `Date shift per clone ...`; two copies after it, SCHEDULED a week and two weeks later |
| `{{org.sort}}` on the parent | a `Sort children` menu; `a` sorts case-insensitively, `A` reversed; `Sorting entries...done` |
| `{{org.narrow_subtree}}` | a float titled `narrow <title>` with the subtree only |
| edit there, `{{edit_src.save_exit}}` | the float closes, the edit is in the Org buffer (modified, not saved) |
| `{{org.next_heading}}` and the other motions | the cursor on that headline; the buffer unmodified |

## Gotchas

- `{{org.meta_return}}` in Normal mode acts at the end of the line, and
  on a headline Emacs's org-insert-heading at the end of the title
  inserts right below the headline line: the entry's body ends up under
  the new heading. `{{org.insert_todo_heading}}` respects the content
  (goes after the subtree). Don't expect M-CR to skip the body.
- The new heading's line is `** ` with a trailing space: match it with
  `line = "^%*%* $"`.
- `{{org.meta_down}}` / `<M-k>` on a list item or table row move that
  instead; put the cursor on the headline line.
- `{{org.paste_subtree}}` takes its level from where the cursor is: in
  column 0 of a headline (`at = "** Kitchen"`, which puts the cursor at
  the start of the match), before it at its level; elsewhere before the
  next visible headline at the deeper of the two levels around it.
- The clone prompts are `vim.fn.input` lines in the message area; the
  date shift is asked only when the subtree has a timestamp.
- The narrow window is a float (`win_split_mode` = "float") and its long
  lines cover the buffer behind it: the screen holds both, so check
  `screen = "narrow Garden"` or the window, not that a line is gone.
  `{{edit_src.save_exit}}` writes back into the buffer only: `:write`
  before an `expect.file`.
- The sort menu takes the key as typed; uppercase is the reverse order.
  A count (`1{{org.sort}}`) makes `a` case-sensitive.
- Every edit changes the buffer only: write it (`cmd = "write"`) before an
  `expect.file`.
