---
area: export
recipe: scripts/verify/recipes/export.lua
keys: org.export
modules: lua/org/export/init.lua, lua/org/export/dispatch, lua/org/export/ascii.lua, lua/org/export/html.lua, lua/org/export/markdown.lua
specs: tests/spec/export_spec.lua, tests/spec/export_dispatch_emacs_spec.lua, tests/spec/export_ascii_spec.lua, tests/spec/emacs_export_parity_spec.lua
doc: org-export, org-export-backends, org-export-ascii, org-export-settings
emacs: ox.el, ox-ascii.el, ox-html.el, ox-md.el
---

# Export

Turn an Org file into plain text, HTML, Markdown and other formats,
written next to it (org-export-dispatch and the ox back-ends).

## How to get to it

`{{org.export}}` (`<leader>oe`, Emacs `C-c C-e`) opens the dispatcher, a
floating "Org Export" menu: the option toggles (`b` body only, `s` scope,
`v` visible only, `f` force publishing, `a` async), then a letter per
back-end that opens its submenu. Or `:Org export {format} [subtree]
[body] ...` (`html`, `md`, `ascii`, ...) without the menu.

## Driving it

| Step | Expected |
| --- | --- |
| `{{org.export}}` | the "Org Export" menu: Options, then `h  Export to HTML  ›`, `m  Export to Markdown  ›`, `t  Export to Plain Text  ›`, ... |
| `t` | "Org Export › Export to Plain Text": `A  As ASCII buffer`, `a  As ASCII file`, Latin1, UTF-8 |
| `a` | the menu gone; "Exported to <dir>/trip.txt"; `trip.txt` on disk |
| `h` then `h` | `trip.html` (`H` is the buffer, `o` file and open) |
| `m` | `M  To temporary buffer`, `m  To file`, `o  To file and open`, `G` / `g` GFM |
| `s` in the menu | "Export scope" goes from `buffer` to `subtree` |
| `:Org export md` | `trip.md`, no menu |

## Gotchas

- The output file goes next to the Org file, named after it
  (`trip.org` → `trip.txt` / `trip.html` / `trip.md`), so
  `expect.file` finds it in the scenario directory.
- Give the file a `#+AUTHOR:` (or `export.author` in setup): the author
  otherwise is the system user's full name (`id -F` on macOS, `getent`
  elsewhere), not anything in the scratch HOME, and differs per machine.
  It shows in the ASCII title block and the HTML postamble.
- HTML headline ids are random (`orgc71e7ed`), like Emacs's
  `org-export-new-reference`: match them with a pattern, not
  `lines`. The HTML "Created:" date is the driver's clock
  (`2026-10-12 Mon 09:00`).
- A subtree export drops the headline itself (ox.el removes the top
  heading; it becomes the title). Markdown has no title, so the subtree
  "* Budget" exports as just `About 300 euros.`, as in Emacs.
- Markdown output starts with two empty lines for a file with only
  keywords before its first heading; Emacs 9.8.10 writes the same.
- The ASCII title block is centred on its longest line, so its
  indentation changes with the title and author.
- The menu doesn't fit 24 rows: its last entries, `&` (export stack)
  and `#` (template), are cut off with no sign of more, but their keys
  still work (`&` opens `*Org Export Stack*`). The submenus say what each key does in
  the back-end's own words ("As ASCII file", "To file"): check those,
  not a common label.
- `cmd = "Org export md"` blocks the driver when the export prompts (a
  file whose src blocks have `:exports results`: "Evaluate this lua code
  block on your system?", Babel's `evaluate_on_export`); type
  `:Org export md<CR>` as keys instead, then answer. After `y` the
  "Exported to" message under the prompt leaves a Press ENTER prompt
  (the child stops answering the driver): send `y<CR>`.
- No pandoc or LaTeX here: `d` (DOCX), `p` (pandoc), the PDF entries
  and the "and open" entries need external programs and aren't in the
  recipe. ODT (`o o`) is written natively.
