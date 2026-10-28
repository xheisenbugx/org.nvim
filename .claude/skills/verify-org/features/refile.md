---
area: refile
recipe: scripts/verify/recipes/refile.lua
keys: org.refile, org.refile_copy, org.archive_subtree, org.toggle_archive_tag, org.cycle, emacs.archive_to_sibling, emacs.force_cycle_archived
modules: lua/org/refile.lua, lua/org/archive.lua
specs: tests/spec/refile_spec.lua, tests/spec/archive_spec.lua, tests/spec/archive_refile_extra_spec.lua
doc: org-refile, org-archive, org-archived-trees
emacs: org-refile.el, org-archive.el
---

# Refile and archive

Move a subtree under another heading, in this file or another one
(org-refile), and put finished subtrees away: in an archive file, under
an Archive sibling, or by tagging them ARCHIVE (org-archive).

## How to get to it

On a headline (or in its body): `{{org.refile}}` (`<leader>or`) refiles,
`{{org.refile_copy}}` (`<leader>oR`) copies, `{{org.archive_subtree}}`
(`<leader>o$`) archives to the archive file, `{{org.toggle_archive_tag}}`
(`<leader>ohA`) toggles the ARCHIVE tag, `{{emacs.archive_to_sibling}}`
(`<C-c><C-x>A`) moves it under the "Archive" sibling. The Emacs keys
(`<C-c><C-w>`, `<C-c>$`, ...) are on by default too.

The target picker is `vim.ui.select`. Under the driver (no picker plugin)
that is Neovim's default: a numbered list in the message area, `Refile
subtree "<title>" to` above it and `Type number and <Enter> (q or empty
cancels):` below. Type the number, then `<CR>`.

## Driving it

| Step | Expected |
| --- | --- |
| `{{org.refile}}` | the numbered list of targets; by default the level-1 headings of the buffer, the subtree's own parent included |
| a number, `<CR>` | the subtree is the last child of that heading; message `Refiled "<title>" to <heading>` |
| `<CR>` alone | cancelled; the buffer is unmodified |
| `{{org.refile_copy}}` | the same list, `Copy subtree "<title>" to`; the original stays |
| `{{org.archive_subtree}}` | the subtree is gone from the buffer; message `Subtree "<title>" archived in <file>_archive` |
| `{{org.toggle_archive_tag}}` | `:ARCHIVE:` at the end of the headline, the subtree folds; `Subtree archived` / `Subtree unarchived` |
| `{{org.cycle}}` on an ARCHIVE subtree | stays folded: `Subtree is archived and stays closed.  Use <C-c><C-Tab> to cycle it anyway.` |
| `{{emacs.force_cycle_archived}}` | opens it anyway |
| `{{emacs.archive_to_sibling}}` | the subtree goes under a new `** Archive  :ARCHIVE:` sibling (folded), with an ARCHIVE_TIME property |

## Gotchas

- Neither refile nor archive saves the source buffer: the file on disk
  still has the subtree until `:write`. What is saved: a refile target in
  another file that isn't shown in a window, and the archive file
  (`archive_subtree_save_file`, "from_org" by default). Check the source
  with `expect.file` only after a `{ cmd = "write" }` step.
- The default targets are the current buffer's level-1 headings
  (Emacs's `org-refile-targets` nil). To offer another file, set
  `refile = { targets = { { files = "{{dir}}/projects.org", max_level = 1 } } }`
  in the scenario's `setup`. Headings of other files are labelled
  `Garden (projects.org)`.
- Every message names the subtree's title (`Refiled "Call the plumber"
  to Kitchen`), so `no_screen = "Call the plumber"` fails after a
  successful refile. Match the headline with its stars and keyword.
- The archive file's header and ARCHIVE_FILE hold the source's full path,
  which is the scratch directory (and has backslashes or a drive on
  Windows). `expect.file` doesn't substitute `{{dir}}`; check those lines
  with a pattern in an `expect.lua`, which gets the directory as `...`.
- A new `tasks.org_archive` starts with `#    -*- mode: org -*-` (four
  spaces), two blank lines, `Archived entries from file <path>`, two blank
  lines, then the entry at level 1 with ARCHIVE_TIME, ARCHIVE_FILE,
  ARCHIVE_OLPATH, ARCHIVE_CATEGORY and ARCHIVE_TODO (the clock's
  `2026-10-12 Mon 09:00`). The mode line is Emacs's too: its
  `auto-mode-alist` has no `.org_archive`, so `org-archive-subtree`
  turns Org mode on with `org-insert-mode-line-in-empty-file` (checked
  with Org 9.8.10 in batch). A target named `*.org` gets no mode line.
- `org_log_done` is off by default, so archiving or refiling adds no
  CLOSED or logbook lines; `refile.log` adds "Refiled on".
- `{{org.toggle_archive_tag}}` folds the subtree and it stays folded after
  untagging (the `...` stays on the headline).
