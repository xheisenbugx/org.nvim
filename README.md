<div align="center">

<img src="https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/logo.png" alt="org.nvim logo: an Org outline with headings and a checkbox, and a unicorn" width="200">

# org.nvim

### Emacs Org mode, rebuilt for Neovim in pure Lua.

Outlines · TODOs · Agenda · Capture · Clocking · Spreadsheet tables · Babel · Export

[![Neovim 0.11+](https://img.shields.io/badge/Neovim-0.11%2B-57A143?style=for-the-badge&logo=neovim&logoColor=white)](https://neovim.io)
[![Pure Lua](https://img.shields.io/badge/100%25-Lua-2C2D72?style=for-the-badge&logo=lua&logoColor=white)](lua/org)
[![Release](https://img.shields.io/github/v/release/xheisenbugx/org.nvim?style=for-the-badge&color=blue)](https://github.com/xheisenbugx/org.nvim/releases)
[![MIT license](https://img.shields.io/badge/license-MIT-green?style=for-the-badge)](LICENSE)
[![Zero dependencies](https://img.shields.io/badge/dependencies-zero-ff69b4?style=for-the-badge)](#requirements)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-orange?style=for-the-badge)](CONTRIBUTING.md)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-support-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/xheisenbugx)

**[Install](#-install-in-30-seconds)** ·
**[Tour](#-a-quick-tour)** ·
**[Features](#-features)** ·
**[Docs](https://org-nvim.com/)** ·
**[Changelog](CHANGELOG.md)** ·
**[Contributing](CONTRIBUTING.md)**

<br>

<img src="https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/hero.gif" alt="Cycling an outline, ticking a checkbox and marking a task DONE from the agenda" width="900">

</div>

---

Org mode is one of the most loved tools in Emacs. It works as a
plain-text outliner, planner, time tracker, spreadsheet, literate-programming
notebook and publishing system. **org.nvim puts all of that in Neovim.** It
isn't a syntax file with a few keymaps on top. It reimplements Org's
behaviour: the agenda, capture templates, repeaters, clock tables, table
formulas, Babel and export.

- 🪶 **No dependencies.** It's about 170k lines of Lua and needs no
  tree-sitter parser, external binary or companion plugin.
- 🔁 **Works with Emacs.** It reads and writes the same plain-text format,
  so you can edit a file in Emacs today and in Neovim tomorrow.
- ⌨️ **Keys that fit Vim.** Context-aware keys fall back to normal Vim
  behaviour when they don't apply (`>>` still indents, `<C-a>` still
  increments). Press `g?` in an org or agenda buffer to see what's
  available.
- 💤 **Ready for LazyVim.** It comes with which-key groups, a blink.cmp
  source, pickers for snacks.nvim, fzf-lua, Telescope and mini.pick, and a
  lualine clock, and it works with any other setup too.
- ✅ **Tested.** The headless test suite runs 4,800+ tests from 240+ spec
  files.

---

## 🤔 Why another Org plugin?

There are already good ways to write Org files in Neovim, above all
[nvim-orgmode](https://github.com/nvim-orgmode/orgmode), which has been
around for years and is used by many people. If it does what you need,
keep using it. [Neorg](https://github.com/nvim-neorg/neorg) is another
fine option, though it uses its own format rather than Org.

org.nvim exists because I wanted something those projects don't aim for:

- **Full parity with Emacs Org.** The goal is to behave like Org 9.8,
  including the parts that are hard to port: Babel with sessions and
  `:var`, a port of the export engine, clock tables, `#+TBLFM` formulas
  with a Calc-compatible evaluator, and image and LaTeX previews. Where
  org.nvim differs, it says so ([Differences from Emacs Org
  mode](#differences-from-emacs-org-mode) and `:h org-differences`).
- **A different architecture.** It's pure Lua with its own Org parser,
  where nvim-orgmode is built on a tree-sitter grammar. That's a
  foundational choice, not something a pull request could change.
- **Speed.** Adding everything above to an existing project would mean
  big design changes and a slow review cycle, so I built it separately.
- **Keys that feel right in both worlds.** The Emacs Org keys work as they
  do in Emacs, and the Vim-style keys fall back to normal Vim behaviour
  when they don't apply.

**On AI:** org.nvim is written with AI assistance
([Claude Code](https://claude.com/claude-code)). To keep that honest, its
behaviour is checked against the Emacs Org source rather than guessed,
every feature comes with headless tests (`make test`, 4,800+ of them), and
I review and use every change myself. Bug reports are very welcome,
especially where it doesn't match Emacs.

---

## ⚡ Install in 30 seconds

With [lazy.nvim](https://github.com/folke/lazy.nvim) / LazyVim:

```lua
-- ~/.config/nvim/lua/plugins/org.lua
return {
  "xheisenbugx/org.nvim",
  main = "org",
  lazy = false, -- startup cost is small: heavy modules load on first use
  opts = {
    org_directory = "~/org",
    agenda_files = { "~/org/**/*.org" },
    default_notes_file = "~/org/refile.org",
  },
}
```

Restart Neovim and run `:checkhealth org`. Then open
[`examples/tutorial.org`](examples/tutorial.org), a hands-on tour with a
section and exercises for every feature. To try it without touching your
config or your notes, run it from a checkout with the bundled init file:

```sh
nvim -u examples/minimal_init.lua examples/tutorial.org
```

To go deeper into one feature, open
[`examples/00-index.org`](examples/00-index.org). It links to one file per
feature area (outlines, TODOs, the agenda, tables, spreadsheet formulas,
Babel, export and more), each with many examples, exercises and the result
you should expect.

---

## 🎬 A quick tour

Everything below was recorded in a plain Neovim with only org.nvim
installed. The tapes that produce these GIFs live in
[`docs/media/tapes`](docs/media/tapes), so they can be re-recorded after
every change. They use [`docs/media/demo/init.lua`](docs/media/demo/init.lua),
which changes a few defaults: it logs `CLOSED:` on DONE, opens the agenda
on the day, offers every top-level heading of the agenda files as a refile
target, and puts the clock in the statusline.
In the newer demos, the box in the bottom-right corner shows the key being
pressed.

### Outlines that fold like Emacs

`TAB` cycles a subtree through folded, children and everything.
`S-TAB` does the same for the whole file. You can move a subtree with all
of its children (`<leader>oK` / `<leader>oJ` or `M-k` / `M-j`), promote and
demote it, or cut, paste and sort it.

![Cycling visibility with TAB and S-TAB, then moving a subtree up and down](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/outline.gif)

### Structure editing

`M-RET` adds a heading (or an item) at the right level,
and `<leader>oit` adds a TODO heading. `M-h` / `M-l` promote and demote.
`<leader>ohs` sorts the children (alphabetically, by TODO state, priority,
date and more), and `<leader>ohn` narrows to a subtree so you can edit it
on its own.

![Adding a heading, demoting and promoting it, adding a TODO heading, sorting children and narrowing to a subtree](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/headings.gif)

### TODOs, checklists and priorities

Ticking a checkbox updates the `[2/4]` and `[50%]` cookies of its parents.
Marking a task DONE updates its parent's cookie and, with
`log_done = "time"` (or `#+STARTUP: logdone`), logs a `CLOSED:` timestamp.
Set the state with `cit` or with the fast-selection menu (`<leader>oS`), and the
priority with `<leader>o,`.

![Ticking checkboxes, marking a task DONE and giving another one priority A](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/todo.gif)

### Plain lists

`S-Right` / `S-Left` on an item cycles the bullet style of its list: `-`,
`+`, `*` (in indented lists), `1.` and `1)`. `M-RET` adds an item and
`M-S-RET` adds a checkbox item. `TAB` on a new empty item indents it.
`M-Up` / `M-Down` move an item with its children, and numbered lists are
renumbered as you go. `<leader>o-` turns plain lines into a list.

![Cycling bullet styles, adding and indenting items, moving a numbered item, turning lines into a list and adding a checkbox](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/lists.gif)

### Tags and properties

`<leader>ot` opens fast tag selection: one key per tag, with mutually
exclusive groups like `{ @office @remote }`. `<leader>oxe` sets the effort
from `Effort_ALL`, and `<leader>op` sets any property.

![Setting three tags with fast keys, an effort and an OWNER property](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/tags.gif)

### Dates with a real calendar

`<leader>os` (schedule) and `<leader>od` (deadline) open a floating
calendar with week numbers, today and weekends marked, and a preview of
the chosen date ("in 3 days"). Move around it with `hjkl`, or press `i`
and type a date the way you'd say it: `fri 14:00`, `+2w`, `sep 15`, `w39`.
Its colors are `OrgCalendar*` highlight groups (`:h org-calendar`).

![Scheduling a task from the calendar and typing "fri 14:00" for a deadline](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/dates.gif)

You don't need the calendar to change a date. `S-Right` / `S-Left` move it
by a day, `<C-a>` / `<C-x>` (or `S-Up` / `S-Down`) change the part under
the cursor (year, month, day, hour or minutes, rounded to 5), and `<CR>`
on a date opens the agenda for that day.

![Shifting a date by days, changing the hour and minutes in place, then opening the agenda on a date range](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/timestamps.gif)

### A real agenda

`<leader>oa` → `a` opens the week, or the day with
`agenda = { span = "day" }`. The day view has a time grid, a current-time line, deadline
countdowns, overdue items and a habit consistency graph, the same as in
Emacs. From the agenda you can change states, reschedule, clock in,
refile, filter and run bulk actions. `vd` / `vw` switch between day and
week.

![The agenda day view: marking a task DONE, then switching to the week view](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/agenda.gif)

<details>
<summary>The week view</summary>

![The agenda week view](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/agenda-week.png)

</details>

The dispatcher has the other Emacs views too: every TODO (`t`), a
tags/property match (`m`, here `+oss`) and a word search (`s`).

![The TODO list, a +oss tag match and a word search in the agenda](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/agenda-views.gif)

### Capture from anywhere

Press `<leader>oc` in any buffer and pick a template. Templates can be
grouped under a prefix key (`w` → `t` here). Type the task and finish with
`<C-c><C-c>` or `:w`. It's filed where the template says: under a
headline, an outline path or a date tree.

![Capturing a work task that lands under the Inbox heading of work.org](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/capture.gif)

### Refile and archive

`<leader>or` moves a subtree under another heading: by default a
top-level heading of the current file, or any heading in your agenda files
with `refile = { max_level = N }` (here labelled with the file name,
`use_outline_path = "file"`). `<leader>o$` archives a finished subtree to
`<file>_archive` and keeps its context in `ARCHIVE_*` properties.

![Refiling an inbox task into work.org/Projects and archiving a DONE task](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/refile.gif)

### Spreadsheet tables

Type a rough table, press `<C-c><C-c>` on its `#+TBLFM` line, and it
aligns itself and evaluates its formulas with a Calc-compatible evaluator.
Change a value, recalculate with `<leader>oTf`, and the totals follow.

![Typing a rough table, evaluating its formulas and recalculating after an edit](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/tables.gif)

Rows and columns are easy to edit. `<leader>oTr` / `<leader>oTi` insert a
row or a column, `M-j` / `M-k` and `M-h` / `M-l` move them, and
`<leader>oTR` / `<leader>oTI` delete them. Formulas in `#+TBLFM` are
rewritten to follow the moves.

![Inserting a row and a column, moving them, then deleting a column and a row](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/table-edit.gif)

`<leader>oTs` sorts the rows (alphabetically, numerically, by date or with
a function), and `<leader>oTt` transposes the table. Type `:=` followed by
a formula in a field to add a field formula to `#+TBLFM`.

![Sorting rows by price, adding a Total row with a field formula, then transposing the table](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/table-tools.gif)

### Code that runs in your notes

`<C-c><C-c>` on a source block runs it asynchronously, with a spinner
while it runs (`<prefix>bC` cancels it), and writes the output back into
the file:

![Running Python, shell and Lua blocks and inserting their results](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/babel.gif)

Python, shell, Lua (in-process), Node, Ruby, R, Go, SQLite and more are
supported, along with `:var`, `:noweb`, `:wrap`, `:cache`, `#+CALL`,
inline `src_lang{…}` blocks and tangling. Nothing blocks the editor while
code runs (except Lua, which runs inside Neovim); `:session` keeps a live
REPL between blocks (`C-c C-v C-z` opens it so you can type into it), and
`:session :async` writes a placeholder result right away, as in Emacs.

`<leader>o'` opens a block in its own buffer with the language's filetype,
so it gets that language's highlighting, indentation and filetype plugins.
`<C-c>'` writes it back.

![Editing a Lua block in its own buffer, writing it back and running it](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/src-edit.gif)

### Clocking, clock tables and column view

`<leader>oxi` clocks in, and [`require("org").statusline()`](#statusline)
shows the running total against the effort estimate. `<leader>oxr` inserts
a clock table that matches Emacs's output. `<leader>oC` opens column view,
drawn over the headlines like Emacs, which sums efforts and clocked time
up the tree.

![Clocking in, inserting a clock table, then opening column view](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/clock.gif)

### Images and LaTeX, right in your notes

`<leader>oxv` (`C-c C-x C-v`) shows image links as images in place of the
link, like Emacs, and `<leader>oxl` (`C-c C-x C-l`) renders LaTeX
fragments. On Neovim 0.13+ they're drawn by the built-in `vim.ui.img` in
any terminal with the Kitty graphics protocol (kitty, Ghostty, WezTerm).
They follow scrolling, folds and splits, and the link text comes back on
the cursor line so you can edit it. On older Neovim, or inside tmux,
org.nvim uses [snacks.nvim](https://github.com/folke/snacks.nvim)'s image
module or [image.nvim](https://github.com/3rd/image.nvim) instead.
`#+STARTUP: linkpreviews` and `latexpreview` turn them on when a file
opens.

![Previewing the images of an entry and then the whole buffer, scrolling and folding with them](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/images.gif)

LaTeX is rendered in the background with `latex` + `dvipng` like Emacs, or
with `tectonic` / `pdflatex`, in your colorscheme's text color, and the
results are cached:

![Rendering an inline formula, a displayed integral and an align environment, then hiding one](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/latex.gif)

These two were recorded in a real kitty window
([`docs/media/kitty`](docs/media/kitty)); VHS can't show Kitty graphics.

<details>
<summary><b>Where do image previews work?</b> (tmux, Neovim versions, terminals)</summary>

Previews depend on the Neovim version, the terminal, and what sits
between them. `:checkhealth org` shows what it found, and
`:h org-images-troubleshooting` has the details.

| Setup | What draws the images | Notes |
| --- | --- | --- |
| Neovim 0.13+ in kitty or Ghostty | `vim.ui.img` (built in) | Everything works, including `:align` |
| Neovim 0.13+ in WezTerm | `vim.ui.img` | WezTerm's Kitty graphics support is partial |
| Neovim 0.11–0.12 | snacks.nvim or image.nvim | `vim.ui.img` needs 0.13 |
| Inside **tmux** | snacks.nvim | tmux drops `vim.ui.img`'s images. Add `set -g allow-passthrough on` and install snacks.nvim, or run Neovim outside tmux |
| Inside zellij | nothing | zellij doesn't pass images through |
| Over SSH | `vim.ui.img` or snacks.nvim | Images and LaTeX tools must be on the machine running Neovim |
| Terminal.app, iTerm2, Alacritty, Windows Terminal, GNU screen | image.nvim at best | No Kitty graphics protocol |

With snacks.nvim or image.nvim, `:align` / `org-image-align` are ignored,
and when the link has text around it, snacks.nvim draws the image at the
start of the next line and puts an icon at the link.

</details>

### Jump to any heading

`<leader>o.` (Emacs `C-c C-j`) jumps to a heading of the current file.
By default it opens Emacs's org-goto outline, a read-only copy of the
buffer you browse and jump from. With `goto_interface =
"outline-path-completion"` (shown here) it's a picker instead, and a count
switches to the other interface for one jump. `<leader>og` jumps to any
heading of your agenda files. The pickers use `vim.ui.select`, so they get
your picker: snacks.nvim here, or Telescope / fzf-lua once they're set up
as the `vim.ui.select` provider. The [`pick_*` actions](#pickers) talk to
those pickers directly, with a preview of each heading.

![Fuzzy-finding a heading in the file, then with the Emacs key](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/goto-buffer.gif)

![Jumping to headings in other agenda files](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/goto-agenda.gif)

### Timers

`<C-c><C-x>0` starts a relative timer, and `<C-c><C-x>-` adds a list item
with the elapsed time, handy for meeting notes. `<C-c><C-x>,` pauses and
resumes it, and `<C-c><C-x>_` stops it. The running time is part of the
statusline component.

![Taking timed meeting notes, pausing and stopping the timer](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/timers.gif)

`<C-c><C-x>;` starts a countdown for the current entry and notifies you
when it runs out:

![A six-second countdown that ends with a "time out" notification](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/countdown.gif)

### Appointment reminders

With `notifications.enabled` (or `:Org notifications_start`), org.nvim
checks your agenda for timed entries and reminds you before they start,
by default 12, 9, 6, 3 and 0 minutes before, through `vim.notify` and the
system notifier (`osascript`, `notify-send`, or PowerShell on Windows).

![Reminders for a scheduled call and a deadline, then the same entries in the agenda](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/reminders.gif)

### Footnotes

`<leader>oif` (`C-c C-x f`) inserts a footnote reference and its
definition, in a Footnotes section or inline. `<C-c><C-c>` jumps between a
reference and its definition. A count sorts, renumbers or normalizes them.

![Inserting a footnote and jumping between reference and definition](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/footnotes.gif)

### Checking a file with org-lint

`:Org lint` runs the org-lint checks, such as misplaced planning lines,
broken property drawers, links to missing IDs or files and src blocks
without a language, and lists the problems in the location list.

![org-lint listing five problems of a file and jumping to one](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/lint.gif)

### Speed keys

With `use_speed_commands = true`, single letters typed at the very start
of a heading in Insert mode run commands, like Emacs's speed keys: `n` /
`p` to move, `t` for the TODO state, `U` / `D` to move the subtree, `c` to
cycle, and `?` for the full list.

![Speed keys moving between headings, changing a TODO state, moving a subtree and listing every key](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/speed-keys.gif)

### Links

`<leader>ols` stores a link to the current heading (or file, line or ID),
and `<leader>oli` inserts it with completion. Links show only their
description. `<CR>` follows them, and `<leader>olt` shows the raw text.

![Storing a link to a heading, inserting it elsewhere, following it and showing the raw links](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/links.gif)

### Sparse trees

`<leader>o/` folds the file down to what matters: TODO entries, a regexp,
a tag or property match, or deadlines. The matches are highlighted, and
`<C-c><C-c>` clears the highlights.

![A sparse tree of TODO entries, then one for a regexp](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/sparse.gif)

### Export

`<leader>oe` opens the export dispatcher. The HTML, LaTeX, Beamer, KOMA
letter, man page, Markdown, ASCII, Org, iCalendar, ODT and Texinfo
back-ends are ports of Emacs's, there's a GitHub-flavoured Markdown
back-end, and pandoc handles DOCX, EPUB and more. You can export to a
buffer to check the result:

![Exporting an Org file to a Markdown buffer](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/export-md.gif)

### Every key, one press away

Lost? Press `g?` in any org or agenda buffer to list every keymap
available there, grouped by topic (visibility, structure, dates, clock,
tables, Babel…), with each command's Vim and Emacs keys on one row. `/`
searches it, and `{` / `}` jump between sections:

![The g? keymap help float](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/keymaps.png)

---

## ✨ Features

| | Area | Highlights |
| --- | --- | --- |
| 🌳 | **Outline** | Headline folding with Emacs-style `TAB`/`S-TAB` cycling, `#+STARTUP` and `VISIBILITY` visibility, archived subtrees that stay folded, motions (`]]` `[[` `g{`), and text objects (`ih` `ah` `ir` `ar`) |
| ✂️ | **Structure editing** | A context-aware `M-RET`, promote and demote, move, cut/copy/paste/clone subtrees, sort, narrow, structure templates |
| 📋 | **Plain lists** | Every bullet style, checkboxes with a `[-]` partial state, `[2/5]` and `[40%]` statistics cookies, renumbering, `TAB` on a new item to indent it |
| ✅ | **TODO** | Multiple keyword sequences, fast selection, `!`/`@` logging, `LOGGING` / `LOG_INTO_DRAWER` properties, repeaters (`+1w`, `++1d`, `.+2d`, `REPEAT_TO_STATE`), `ORDERED` / `NOBLOCKING` dependencies, tag triggers, `#+TYP_TODO` type sequences, priorities |
| 🏷️ | **Tags and properties** | Fast tag selection with groups, tag changes over a selection, inheritance, `#+FILETAGS`, property drawers, `Effort`, `_ALL` values cycled with `S-Left`/`S-Right` |
| 📅 | **Dates** | A floating calendar that understands `+2w`, `fri 14:00`, `sep 15` and `w39`; `SCHEDULED`/`DEADLINE` with warning and delay periods; `<C-a>`/`<C-x>` on any part of a timestamp, minutes rounded to 5; custom timestamp formats (`C-c C-x C-t`) in the buffer and in export; Emacs's `org-duration` units and formats |
| 🗓️ | **Agenda** | Day to year views, a time grid, habits, log, clock-report, entry-text and archive modes, the full Emacs match syntax, custom composite commands, tag/category/effort/regexp filters, bulk actions, follow mode, restriction lock, PDF/PostScript export, calendar conversions, moon phases, sunrise/sunset and holidays, the Emacs diary file and every diary sexp of Emacs's calendars |
| 📥 | **Capture** | Grouped templates; entry, item, checkitem and table-line types; file, headline, outline-path, date-tree, regexp, ID, clock and function targets; all the common `%`-escapes; `:unnarrowed` captures in the target file, `org-extend-today-until` for dates, Emacs Lisp `%(sexp)` escapes |
| 📦 | **Refile and archive** | Refile or copy subtrees or regions, with Emacs-style target specs, outline-path completion in steps and refile logging; archive to a file, heading, date tree or Archive sibling with the `ARCHIVE_*` context properties; refile cache; notes in the `*Org Note*` buffer |
| 🔗 | **Links** | `file:` with `::line`, `::*heading`, `::#id` and `::/regex/`; `id:`, `<<targets>>`, `<<<radio targets>>>`, coderefs, `shell:` (with an `*Org Shell Output*` buffer), `elisp:`, wildcard `file:*.org` listings, `attachment:`, abbreviations, custom types, concealed display, store/insert last/all links |
| ⏱️ | **Clocking** | Clock in/out/cancel/jump, clock history with default and interrupted tasks, Emacs's clock resolution (keep, subtract, got-back) for dangling clocks and idle time, auto clock-out, effort estimates with an overrun alert, a statusline component, `clocktable` blocks matching Emacs output (`:step`, `:formula`, `:sort`, `:lang`…), agenda clock check, relative and countdown timers |
| 🧮 | **Tables** | Automatic alignment, column shrinking, row/column/cell editing with formula fixing, copy-down, CSV/TSV import and export, `#+TBLFM` formulas with a Calc-compatible evaluator, a formula editor and debugger, radio tables, orgtbl-mode (including the unicode and table.el translators) and plots (including radar); Calc symbolic algebra (`simplify`, `deriv`, `integ`, `solve`), vectors and matrices, modulo forms, complex numbers, HMS forms, error forms, intervals and units; table.el grid tables (`C-c ~`, `C-c '`, export) |
| 🧪 | **Babel** | Asynchronous execution in many languages (with a spinner, placeholder results and cancelling), `:session` as live REPL buffers (shells, Python, Node, Ruby, R, Lua) with `:async`, inline `src_lang{…}` blocks and `call_name()`, `:results`, `:var` references that evaluate blocks (`name(x=1)`, slices, other files, IDs), `:noweb`, `:wrap`, `:cache`, `:file`, `#+CALL`, Library of Babel, tangling, optional evaluation on export, the `C-c C-v` commands, and editing a block in its own buffer with `C-c '`; `emacs-lisp` blocks run in a separate Emacs when one is installed |
| 📤 | **Export** | A port of Emacs's export engine (with `#+BIND` and `(eval …)` macros): HTML, LaTeX/PDF, Beamer, KOMA letters, man pages, Markdown, ASCII, Org, iCalendar, ODT and Texinfo/Info back-ends matching Emacs output, GitHub-flavoured Markdown, citations with the CSL processor, publishing projects, every `#+OPTIONS` key, plus DOCX, EPUB and more through pandoc |
| 🖼️ | **Images and LaTeX** | Image links and LaTeX fragments previewed in place of the link (`org-link-preview`, `-region`, `-clear`, `-refresh`, `org-latex-preview`) with Neovim 0.13's `vim.ui.img`, or snacks.nvim / image.nvim on older versions; `org-image-actual-width`, `#+ATTR_ORG: :width` / `:align`, images as link descriptions, previews on TAB, `#+STARTUP: linkpreviews latexpreview`, the Emacs LaTeX processes (dvipng, dvisvgm, xelatex, imagemagick) plus tectonic, images in `ltximg/`, preview functions for custom link types, remote http(s) images |
| 🧩 | **[Extensions](#-extensions)** | Optional, off until enabled: slideshows (org-present), queries and saved views (org-ql), linked notes (org-roam), grouped agendas (org-super-agenda), Todoist-style quick add, a guided weekly review, pomodoros (org-pomodoro), flashcards with spaced repetition (org-drill), an in-process language server (symbols, hover, cross-file rename), kanban board, timeline, clock heatmap and Today sidebar, code ↔ notes links and literate Neovim config, a structural git merge driver, iCalendar subscriptions, the `org` command line, mermaid/dot/plantuml diagrams, and live transclusion (org-transclusion) |
| 🎁 | **And more** | Column view, `org-indent` mode, speed keys, footnotes, sparse trees, `org-lint`, entry encryption (`org-crypt`), `org-protocol`, inline tasks, org-num, pretty entities, appointment notifications, attachments (with `org-attach-git`), RSS/Atom feeds (`org-feed`), MobileOrg, IDs, dynamic blocks, BibTeX links (`ol-bibtex`), `org-ctags`, the Org/table/agenda menus and org-mouse, completion, `:checkhealth org` |

The full reference is in `:h org.nvim` ([`doc/org.txt`](doc/org.txt)), and
on the [documentation website](https://org-nvim.com/)
together with the examples, searchable.

---

## 📚 Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Keymaps](#keymaps)
- [Configuration](#configuration)
- [Capture templates](#capture-templates)
- [Custom agenda commands](#custom-agenda-commands)
- [Completion](#completion)
- [Pickers](#pickers)
- [Statusline](#statusline)
- [Outline and breadcrumb plugins](#outline-and-breadcrumb-plugins)
- [Lua API](#lua-api)
- [Parity with Emacs Org](#-parity-with-emacs-org)
- [Differences from Emacs Org mode](#differences-from-emacs-org-mode)
- [Extensions](#-extensions)
- [Roadmap](#-roadmap)
- [Contributing](#-contributing)

---

## Requirements

- Neovim **0.11+** on Linux, macOS or Windows. Nothing else is required
  (Windows notes: `:h org-windows`).
- Optional:
  - `pandoc` for DOCX, EPUB and the other formats without a native
    back-end (HTML, LaTeX, ODT, Texinfo and the rest are built in).
  - `latexmk`, `pdflatex`, `xelatex` or `lualatex` for PDF, and
    `makeinfo` for Info.
  - The language interpreters you want Babel to run.
  - For image and LaTeX previews: Neovim 0.13+ in kitty, Ghostty or
    WezTerm (or snacks.nvim / image.nvim), ImageMagick for non-PNG images,
    and `latex` + `dvipng` or `tectonic` for LaTeX.

---

## Installation

### LazyVim / lazy.nvim, with blink.cmp completion

```lua
-- ~/.config/nvim/lua/plugins/org.lua
return {
  {
    "xheisenbugx/org.nvim",
    main = "org",
    lazy = false,
    opts = {
      org_directory = "~/org",
      agenda_files = { "~/org/**/*.org" },
      default_notes_file = "~/org/refile.org",
    },
  },
  -- completion in blink.cmp (LazyVim default)
  {
    "saghen/blink.cmp",
    optional = true,
    opts = {
      sources = {
        per_filetype = { org = { inherit_defaults = true, "org" } },
        providers = { org = { name = "Org", module = "org.completion.blink" } },
      },
    },
  },
}
```

### Other plugin managers

Add the plugin to your `'runtimepath'` and call:

```lua
require("org").setup({
  org_directory = "~/org",
  agenda_files = { "~/org/**/*.org" },
  default_notes_file = "~/org/refile.org",
})
```

### Local development checkout

Point lazy.nvim at the directory instead of a GitHub repo:

```lua
{
  dir = "~/path/to/org.nvim",
  name = "org.nvim",
  main = "org",
  lazy = false,
  opts = { --[[ … ]] },
}
```

Restart Neovim (or run `:Lazy reload org.nvim`) and check the result with
`:checkhealth org`.

> [!TIP]
> **Keymap prefix.** All org commands live under `<leader>o` by default. If
> another plugin already uses it (obsidian.nvim, overseer), set
> `mappings = { prefix = "<leader>O" }` or any other prefix.

---

## Quick start

1. `mkdir ~/org` and open `~/org/todo.org`.
2. Type `* TODO Buy milk`, press `<Esc>`, then `<leader>os` and `<CR>` to
   schedule it for today.
3. `<leader>oa` → `a` opens the weekly agenda. `t` changes the state of the
   entry under the cursor, and `<CR>` jumps to it.
4. `<leader>oc` → `t` captures a new task from anywhere. Finish with
   `<C-c><C-c>` or `:w`.
5. Press `g?` in any org or agenda buffer to list its keymaps.

---

## Keymaps

`<prefix>` is `mappings.prefix` (default `<leader>o`). Every mapping can be
changed or disabled (`false`) under `mappings.<section>.<action>`. Keys
marked *(ctx)* depend on what's under the cursor. When they don't apply,
they fall back to the normal Vim behaviour (`>>` still indents plain text,
`<C-a>` still increments numbers).

### Emacs keys

Coming from Emacs? The standard Org keys work out of the box, on top of
the Vim-style ones: `C-c C-t`, `C-RET` / `C-S-RET`, `C-c C-s` / `C-c C-d`,
`C-c .`, `C-c C-q`, `C-c C-w`, `C-c C-x C-i` / `C-c C-x C-o`, `C-c C-l`,
`C-c C-e`, `C-c '`, `C-c C-v e`, `C-c =`, `C-c -`, `C-c ^` and about 150 more.
Context-sensitive keys behave as in Emacs (`C-c -` adds an hline in a table,
cycles a bullet on an item and toggles an item elsewhere). Use a count in
place of `C-u`: `4<C-c>.` inserts a timestamp with the time.

The full list is in `:h org-emacs-keys`. Turn them off with
`mappings = { emacs = false, emacs_insert = false, emacs_global = false }`.

### Global

| Key | Action |
| --- | --- |
| `<prefix>a` | Agenda dispatcher |
| `<prefix>c` | Capture |
| `<prefix>g` | Go to any heading in the agenda files |
| `<prefix>ls` | Store a link to the current location |
| `<prefix>xj` / `xo` / `xq` | Go to clocked task / clock out / cancel clock |

<details>
<summary><b>Org buffers</b> (click to expand)</summary>

| Key | Action |
| --- | --- |
| `<Tab>` / `<S-Tab>` | Cycle subtree / global visibility *(ctx: in insert mode, next table field or cycle the level of a new empty heading/item)* |
| `<C-c><C-c>`, `<prefix><CR>` | Context action: toggle checkbox, align/recalc table, run src block, update dblock/clock line/cookie, set tags on headline, property menu on a property line, clear sparse-tree highlights… |
| `<CR>`, `gx`, `<prefix>o` | Open link / footnote / date at point *(ctx)* |
| `<M-CR>` / `<M-S-CR>` | New heading, item or row / new TODO heading or checkbox item |
| `<prefix>ih` `it` `is` | Insert heading / TODO heading / subheading |
| `<prefix>id` `ib` `if` `i@` | Insert drawer / block template / footnote (on a footnote: jump; count: sort/renumber/normalize/delete menu) / citation |
| `<<` `>>` / `<s` `>s` | Promote/demote heading or item / subtree *(ctx)* |
| `<M-h>` `<M-l>` (also `<M-Left>` `<M-Right>`) | Promote / demote heading or item (Visual: every headline); move table column *(ctx)* |
| `<M-k>` `<M-j>` (also `<M-Up>` `<M-Down>`) | Move subtree, item or table row up / down *(ctx)* |
| `<M-H>` `<M-L>` `<M-K>` `<M-J>` | Subtree promote/demote; table delete/insert column, delete/insert row; on a CLOCK timestamp move it and the touching clock; elsewhere drag the line up/down *(ctx)* |
| `<prefix>K` / `<prefix>J` | Move subtree up / down |
| `<prefix>hy` `hd` `hp` `hc` | Copy / cut / paste / clone subtree |
| `<prefix>hs` `hn` `hC` `hA` `hb` | Sort / narrow / toggle COMMENT / toggle ARCHIVE tag / cycle bullet |
| `<prefix>*` / `<prefix>-` | Toggle heading / list item |
| `cit` / `ciT` / `<prefix>S` | Next / previous / select TODO state |
| `<S-Right>` `<S-Left>` | Next/previous TODO; date ±1 day; next/previous allowed property value; cycle bullet *(ctx)* |
| `<S-Up>` `<S-Down>` | Priority or timestamp part up/down; previous/next list item; move table field *(ctx)* |
| `<C-a>` `<C-x>` | Timestamp part or priority cookie up/down; numbers elsewhere *(ctx)* |
| `<prefix>,` `t` `p` `P` | Priority / tags (Visual: add/remove a tag on each headline; count: realign all) / set property / delete property |
| `<prefix>s` `d` `i.` `i!` | Schedule / deadline / active / inactive timestamp |
| `<C-Space>`, `<prefix>#` | Toggle checkbox (Visual: every item; count 4: add/remove the box, 16: `[-]`) / update statistics cookies |
| `<prefix>xi` `xo` `xq` `xj` | Clock in (count: pick from history) / out / cancel / goto |
| `<prefix>xe` `xE` `xm` `xz` | Set effort / next allowed effort / change clocked effort / resolve open clocks |
| `<prefix>xr` `xd` `xu` `xU` `C` | Insert clocktable / show clock sums / update dblock(s) / column view |
| `<prefix>li` `ls` `lt` `ln` `lp` `lI` | Insert / store link, toggle link display, next/prev link, create ID |
| `<prefix>lL` `lA` `lg` `ly` | Insert last / all stored links, go to ID, copy ID |
| `<prefix>r` `R` `$` `A` | Refile / copy to a refile target / archive subtree / attachments |
| `<prefix>/` `e` | Sparse tree / export dispatcher |
| `<prefix>E` `v` `nb` `ne` | Emphasize / mark element / narrow to block / narrow to element |
| `<prefix>xv` `xV` `xl` | Toggle image previews / refresh them / toggle LaTeX previews |
| `<prefix>Tc` `T-` `Tf` `Ts` `Tr` `TR` `Ti` `TI` | Table: create/convert, hline, recalc, sort, insert/delete row, insert/delete column |
| `<prefix>Tt` `T#`, `<S-CR>`, `<S-arrows>` | Table: transpose, rotate recalc mark, copy field down (with increment), swap field with neighbour |
| `<prefix>'` | Edit src block or table formulas in a separate buffer |
| `<prefix>be` `bb` `bs` `bt` `bk` `bn` `bp` | Babel: execute block/buffer/subtree, tangle, remove result, next/prev block |
| `<prefix>bv` `bd` `bg` `br` `bo` `bj` `bi` | Babel: expand, split/wrap, go to named block/result, open result, insert header arg, ingest library |
| `<prefix>bz` `bZ` `bl` `bK` | Babel sessions: show session, show session + edit block, load block into session, kill session |
| `<prefix>bC` | Babel: cancel the running block |
| `]]` `[[` `][` `[]` `g{` `<prefix>.` | Next/prev heading, next/prev sibling, parent, pick heading |
| `ih` `ah` `ir` `ar` | Text objects: heading section / subtree |
| `g?` | Show all keymaps |

</details>

<details>
<summary><b>Agenda buffer</b> (click to expand)</summary>

| Key | Action | Key | Action |
| --- | --- | --- | --- |
| `f` / `b` / `.` | later / earlier / today | `vd` `vw` `vt` `vm` `vy` | day / week / fortnight / month / year |
| `gd` | go to date | `r` | redo |
| `<CR>` / `<Tab>` / `<Space>` / `L` | switch to / go to / show / show and recenter | `F` | follow mode |
| `t`, `<C-S-Right/Left>` | change TODO | `,` `+` `-` | set/raise/lower priority |
| `:` / `T` | set / show tags | `s` / `d` | schedule / deadline |
| `<S-Right>` / `<S-Left>` / `>` | date +1 / −1 / prompt | `e` / `<C-c><C-x>p` | effort / property |
| `I` `O` `X` `J` | clock in / out / cancel / goto | `R` / `$` / `a` | refile / archive / archive with confirmation |
| `<C-c><C-x>A` / `<C-c><C-x>a` | archive sibling / ARCHIVE tag | `<C-k>` / `<C-c><C-o>` | delete entry / open link |
| `z` | add note | `K` / `c` | capture (at the date at point) / jump to a date from the calendar |
| `l` `vL` / `C` | log mode (all) / clock report | `E` / `vG` | entry text / time grid |
| `va` / `vA` / `v[` | archived trees / archive files / inactive timestamps | `/` `\` `<` `=` `_` `^` `\|` | filter / filter tag / category / regexp / effort / top headline / clear |
| `[` `]` `{` `}` | add +word / -word / +{re} / -{re} to the query | `n` / `p`, `<C-c><C-n/p>` | next / previous item, date line |
| `m` `u` `U` `B` | mark / unmark / unmark all / bulk action | `<M-m>` `*` `<M-*>` `%` | toggle / mark all / toggle all / mark regexp |
| `<C-x><C-s>` / `<C-x><C-w>` | save org buffers / export agenda | `q` / `Q` / `x` | quit / quit and wipe / exit (also closes files the agenda opened) |

More agenda keys (habits, diary, follow mode, clock check, block
navigation…): `g?` in the agenda or `:h org-agenda-keys`.

</details>

<details>
<summary><b>Capture and edit buffers</b> (click to expand)</summary>

| Key | Capture | Edit src (`C-c '`) |
| --- | --- | --- |
| `<C-c><C-c>`, `<prefix>w`, `:w` | finalize | — (`<C-c><C-c>`, `<prefix>e`: send to the block's `:session`) |
| `<C-c>'`, `<prefix>'` | — | save and exit (`:w` writes back) |
| `<C-c><C-k>`, `<prefix>k` | abort | abort |
| `<C-c><C-w>`, `<prefix>r` | refile | — |

</details>

---

## Configuration

Every option with its default is in [`lua/org/config/`](lua/org/config)
and documented in `:h org-config`. The most common ones:

```lua
require("org").setup({
  org_directory = "~/org",
  agenda_files = { "~/org/**/*.org", "~/work/notes.org" },
  default_notes_file = "~/org/refile.org",

  todo_keywords = { "TODO(t) NEXT(n) WAITING(w@/!) | DONE(d!) CANCELLED(c@)" },
  log_done = "time",          -- false | "time" | "note"
  log_into_drawer = "LOGBOOK",
  tags = { "work(w)", "home(h)", "{", "@office(o)", "@remote(r)", "}" },
  tags_column = -77,
  startup_folded = "overview",
  deadline_warning_days = 14,

  agenda = { span = "week", start_on_weekday = 1, window = "current" },
  capture = { templates = { --[[ see below ]] } },
  refile = { max_level = 3 },
  notifications = { enabled = true, reminder_time = { 10, 0 } },

  ui = {
    bullets = { "◉", "○", "✸", "✿" },      -- or false
    checkboxes = { " ", "◐", "✓" },        -- or false
    hide_emphasis_markers = false,
    indent_mode = false,                   -- org-indent-mode
    todo_keyword_faces = { WAITING = ":foreground #e0af68 :weight bold" },
  },

  mappings = {
    prefix = "<leader>o",
    org = { toggle_checkbox = "<C-Space>", open_at_point = { "<CR>", "gx" } },
    agenda = { goto_date = "gd" },
  },
})
```

---

## Capture templates

```lua
capture = {
  templates = {
    t = { description = "Task", template = "* TODO %?\n  %U\n  %a", target = "~/org/refile.org" },
    w = "Work",                                          -- a group: w → wt, wm
    wt = { description = "Work task", template = "* TODO %? :work:", target = "~/org/work.org", headline = "Inbox" },
    wm = { description = "Meeting", template = "* %^{Who} %^g\n  %T\n  %?", target = "~/org/work.org", olp = { "Meetings" }, clock_in = true },
    j = { description = "Journal", template = "* %<%H:%M> %?", target = "~/org/journal.org", datetree = true },
    c = { description = "Checklist item", type = "checkitem", template = "[ ] %?", target = "~/org/todo.org", headline = "Shopping" },
    l = { description = "Log line", type = "table-line", template = "| %U | %^{Amount} | %^{What} |", target = "~/org/log.org", headline = "Expenses", immediate_finish = true },
  },
  window = "split",  -- "split" (like Emacs) | "float" | "vsplit" | "tab" | "current"
}
```

Target options:

- `target`: the file to capture into (`""` or none: `default_notes_file`).
- `headline`: a headline in the target, created if it doesn't exist.
- `olp`: an outline path, as a list of headlines (they must exist).
- `datetree`: `true`, or `{ tree_type = "week" | "month" | { "year", "quarter", ... } }`.
- `regexp`: a Vim regexp; the text goes where the first match ends.
- `func` / `location`: functions choosing the position (file+function /
  function targets).
- `id`: insert under the entry with this ID.
- `target = "clock"`: insert under the task being clocked.

Without any template, Emacs's "t" Task template is used (a TODO under
"Tasks" in `default_notes_file`). `capture.templates_contexts` limits
templates to some buffers (org-capture-templates-contexts).

Other options: `type`, `prepend`, `empty_lines`, `table_line_pos`,
`properties`, `immediate_finish`, `jump_to_captured`, `kill_buffer`,
`refile_targets`, `clock_in`, `clock_keep`, `clock_resume`,
`time_prompt`, `no_save`, and the `prepare_finalize`, `before_finalize`
and `after_finalize` hook functions.

<details>
<summary><b>Template expansions</b> (click to expand)</summary>

| Escape | Inserts |
| --- | --- |
| `%?` | cursor position |
| `%t` `%T` `%u` `%U` | date / date+time, active / inactive |
| `%^t` `%^T` `%^u` `%^U` | same, but prompts with the calendar |
| `%<%Y-%m-%d>` | strftime format |
| `%a` `%A` `%l` `%L` | annotation link: plain / with description prompt / without description / bare target |
| `%i` | initial content (the visual selection), the text before it repeated on each line |
| `%x` `%c` | clipboard / last yank |
| `%f` `%F` | origin file name / full path |
| `%n` | your full name |
| `%^{prompt\|default\|opt}` | prompt with a default and options |
| `%\1` `%\*1` | the answer to the first `%^{...}` prompt / to the first prompt of any kind |
| `%^g` `%^G` | tags prompt |
| `%^{PROP}p` | property prompt |
| `%k` `%K` | the running clock's task / a link to it |
| `%(expr)` | the value of an Emacs Lisp form, as in Emacs (a Lisp subset, else a separate Emacs); a Lua expression also works |
| `%[file]` | the contents of a file |
| `\%` | a literal `%` before an escape character (`%%` is not an escape, as in Emacs) |

</details>

---

## Custom agenda commands

```lua
agenda = {
  custom_commands = {
    w = {
      description = "Work overview",
      types = {
        { type = "agenda", span = "day", header = "Today" },
        { type = "tags_todo", match = "+work-someday/!", header = "Open work tasks" },
        { type = "todo", match = "WAITING", header = "Waiting for" },
      },
    },
    u = { description = "Urgent", type = "tags", match = 'PRIORITY="A"|+urgent' },
  },
}
```

Block types: `agenda`, `todo`, `tags`, `tags_todo`, `search`, `stuck`.
Per-block options: `match`, `header`, `span`, `start_day`, `files`,
`skip = function(headline) … end`, and the `todo_ignore_*` flags.
Like Emacs' `org-agenda-skip-entry-if`, `require("org.agenda").skip_entry_if("scheduled", "deadline")`
and `skip_subtree_if("regexp", ":someday:")` build `skip` functions.

The match syntax is the same as in Emacs. Some examples:

- `+work-boss`
- `work|home`
- `LEVEL>1`
- `Effort<"1:00"`
- `SCHEDULED<="<+2d>"`
- `+proj/NEXT|TODO`
- `/!` (only entries that aren't done)

---

## Completion

- **blink.cmp:** add the provider shown in [Installation](#installation).
- **nvim-cmp:**
  ```lua
  require("cmp").register_source("org", require("org.completion.cmp").new())
  ```
  Then add `{ name = "org" }` to your org sources.
- **Built in:** `<C-x><C-o>` (omnifunc).

It completes TODO keywords, tags, `#+` keywords, `#+STARTUP` and
`#+OPTIONS` values, src block languages, property names, link types,
headings (`[[*`), custom IDs (`[[#`) and stored links.

---

## Pickers

The `pick_*` actions open a fuzzy picker with a preview, using the first
one you have installed: [snacks.nvim](https://github.com/folke/snacks.nvim),
[fzf-lua](https://github.com/ibhagwan/fzf-lua),
[telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) or
[mini.pick](https://github.com/echasnovski/mini.pick), else `vim.ui.select`.
Set `picker = "snacks" | "fzf-lua" | "telescope" | "mini" | "select"` to
choose. None of them is required, and none is loaded until a picker opens.

| Action | Picks |
| --- | --- |
| `pick_headline` / `pick_headline_all` | a heading of this file / of the agenda files (TODO, priority and tags shown) |
| `pick_tag` | a tag, then a heading with it |
| `pick_set_tags` | tags to toggle on the heading (multi-select; typing a new one adds it) |
| `pick_agenda` / `pick_agenda_week` / `pick_todo` | an entry of today's agenda / the next 7 days / the TODO list |
| `pick_agenda_file`, `pick_capture_template` | an agenda file, a capture template |

They have no default keys; bind them like any action:

```lua
mappings = { global = { pick_headline_all = "<leader>fo", pick_todo = "<leader>ft" } }
```

Telescope users can also `require("telescope").load_extension("org")` and
run `:Telescope org headlines`. The roam extension's node finder uses the
same picker. See `:h org-pickers`.

---

## Statusline

```lua
-- lualine (LazyVim)
{
  "nvim-lualine/lualine.nvim",
  optional = true,
  opts = function(_, opts)
    table.insert(opts.sections.lualine_x, 1, { function() return require("org").statusline() end })
  end,
}
```

While a clock runs, it shows something like `⏱ [0:25/1:00] (Write report)`,
followed by the timer (`⏲ 0:12:34`) when one runs. It's empty otherwise.

---

## Outline and breadcrumb plugins

Outline windows, breadcrumbs and symbol pickers usually need tree-sitter or
a language server. org.nvim gives them its own outline instead: headings
(with TODO, priority and tags), named src blocks and tables.

- [aerial.nvim](https://github.com/stevearc/aerial.nvim): `backends = { org = { "org" } }`
- [outline.nvim](https://github.com/hedyhli/outline.nvim): add `"org"` to `providers.priority`
- nvim-navic, dropbar.nvim, trouble.nvim and the snacks / fzf-lua / Telescope
  LSP symbol pickers: enable the [`lsp` extension](#-extensions), an
  in-process language server
- your own winbar or statusline: `require("org.api").symbol_path()`

See `:h org-integrations`.

---

## Lua API

`require("org.api")` is a stable, versioned API for plugins and configs:
read files and headlines as plain data, query them, change them (TODO
state, tags, priority, properties, dates, clock, refile, archive, IDs),
run agenda queries without opening the agenda, capture without a window,
store and resolve links, and listen to events such as `OrgTodoStateChange`,
`OrgTagsChanged` or `OrgRefile`. Changes work whether or not the file is
open, and never prompt.

```lua
local api = require("org.api")
for _, h in ipairs(api.headlines({ match = "+work", todo = "WAITING" })) do
  h:set_todo("TODO")
  h:schedule("+1d")
end
api.capture({ template = "* TODO %^{Task}", target = "~/org/inbox.org", values = { Task = "Call the bank" } })
api.on("OrgClockOut", function(data) print(data.title, data.minutes) end)
```

See [`:h org-api`](doc/org.txt) for every function, field and event.

---

## 📊 Parity with Emacs Org

How much of Emacs Org 9.8 works the same way in org.nvim, **measured**
against **Org 9.8.10** (September 2026). Every interactive command and
every user option of Org 9.8.10 (877 commands and 1,055 options, listed by
Emacs itself, plus the `org-overriding-columns-format` variable that the
manual tells users to set) was checked against org.nvim:

| Lens | Parity | What it counts |
| --- | --- | --- |
| **Overall** | `▰▰▰▰▰▰▰▰▰▰` **99.9%** | The 1,806 commands and options (of 1,933) that can exist outside Emacs; Emacs internals are left out |
| **Strict** | `▰▰▰▰▰▰▰▰▰▰` **98.6%** | Also counts the 24 that need Emacs itself (Gnus, BBDB, eww, TRAMP, CDLaTeX...) |

Before this round, the same measurement gave 76.6% overall and 74.3%
strict. The earlier estimates in this README (~92–95%) weighted everyday
features more heavily; this measurement gives every command and option
the same weight.

By area:

| Area | Parity | Before | What's left |
| --- | --- | --- | --- |
| 🌳 Outline, structure, TODO, tags, properties, dates | `▰▰▰▰▰▰▰▰▰▰` 100% | 77% | Nothing that Neovim can do; CDLaTeX, RefTeX and speedbar need Emacs (98% strict) |
| 📋 Plain lists | `▰▰▰▰▰▰▰▰▰▰` 100% | 61% | — |
| 🗓️ Agenda and habits | `▰▰▰▰▰▰▰▰▰▰` 100% | 83% | — |
| 📥 Capture and date trees | `▰▰▰▰▰▰▰▰▰▰` 100% | 71% | — |
| 📦 Refile and archive | `▰▰▰▰▰▰▰▰▰▰` 100% | 91% | — |
| ⏱️ Clocking and timers | `▰▰▰▰▰▰▰▰▰▰` 100% | 91% | — |
| 🧮 Tables and plots | `▰▰▰▰▰▰▰▰▰▰` 99.6% | 88% | Calc's symbolic mode and date format can't be set in `calc_default_modes` |
| 🏛️ Column view | `▰▰▰▰▰▰▰▰▰▰` 100% | 100% | — |
| 🔗 Links | `▰▰▰▰▰▰▰▰▰▰` 100% | 59% | Links to Emacs applications (Gnus, BBDB, MH-E, eww, w3m) need Emacs (84% strict) |
| 📎 Attachments, IDs, footnotes, lint, protocol, crypt | `▰▰▰▰▰▰▰▰▰▰` 100% | 79% | — |
| 🧪 Babel and source editing | `▰▰▰▰▰▰▰▰▰▰` 99.7% | 58% | Common Lisp runs in `sbcl`, not SLIME/SLY; TRAMP and Clojure's CIDER need Emacs |
| 📤 Export and publishing | `▰▰▰▰▰▰▰▰▰▰` 100% | 78% | BBDB anniversaries in iCalendar need Emacs |
| 📚 Citations | `▰▰▰▰▰▰▰▰▰▰` 100% | 39% | — |
| 📰 Feeds and MobileOrg | `▰▰▰▰▰▰▰▰▰▰` 100% | 100% | — |

> [!NOTE]
> **How this is measured.** [`docs/parity/inventory.el`](docs/parity/inventory.el)
> makes Emacs list every command and option of Org 9.8.10, and
> [`docs/parity/inventory.tsv`](docs/parity/inventory.tsv) records, for each
> one, whether org.nvim does the same thing (with the code that does it), or
> why not. A command or option counts as done only when org.nvim behaves
> equivalently, with a spec that exercises it; results that Emacs produces
> (buffer text, export output, agenda lines) are checked against Emacs run in
> batch mode. Partial ones count half; Emacs internals with no user-visible
> effect (byte compilation, caches, obsolete aliases) are left out. Run
> [`docs/parity/score.sh`](docs/parity/score.sh) to recompute the numbers.
>
> A command or option that exists is not the same as every edge case of it
> behaving identically, so this measures coverage, not bug-for-bug
> equality. Where org.nvim differs on purpose (prefix arguments are counts,
> the cursor sits on a character rather than between two), it says so in
> [Differences from Emacs Org mode](#differences-from-emacs-org-mode),
> `:h org-differences` and the [parity review](docs/parity-review.md).
> If something behaves differently from Emacs and isn't listed,
> [please open an issue](https://github.com/xheisenbugx/org.nvim/issues).

## Differences from Emacs Org mode

The goal is Emacs Org 9.8 parity: option defaults are Emacs's (so a fresh
setup behaves like a fresh Emacs: no agenda files, `TODO | DONE`, nothing
logged on DONE, files open expanded), and behaviour is checked against Emacs
run in batch mode. What can't work the same way is listed with the reason in
`:h org-differences`.

The [Org 9.8 review follow-up](docs/parity-review.md) records concrete
regressions, implemented parity work, and remaining feature gaps.
The main differences:

- **Emacs Lisp runs outside the editor.** Capture `%(sexp)`, `(eval ...)`
  macros, table `'(...)` formulas, diary sexps and Lisp in header
  arguments run on a built-in Lisp interpreter first; what it can't do runs
  in a separate `emacs --batch` when Emacs is installed (`elisp:` links and
  emacs-lisp Babel blocks always do). That Emacs can't see or change the
  editor's buffers and has none of your Emacs configuration unless
  `babel.emacs_lisp.args` loads it. `#+BIND` sets the export variables
  that have an org.nvim option. Hooks and functions are Lua functions.
- **Emacs applications** (Gnus, mu4e, BBDB, eww, w3m) and Emacs packages
  (CDLaTeX, RefTeX, SLIME, CIDER, TRAMP) have no counterpart. The Emacs
  diary file is read by the agenda, and `i` adds entries to it.
- **Display:** image and LaTeX previews replace the link, but a terminal
  line can't grow, so a tall image continues in virtual lines under it,
  and they need a terminal image backend. Multi-line fragments are drawn
  in place by hiding their other lines (with image.nvim they stay under
  the line). In indent mode, wrapped rows don't get the virtual
  indentation, and emphasis doesn't nest inside the same emphasis or
  inside verbatim.
- **Point vs cursor:** Emacs acts between characters, Normal mode on a
  character, so commands that insert "at point" act at the end of the line
  in Normal mode (at the cursor in Insert mode).
- **Prefix arguments** are counts (4 = C-u, 16 = C-u C-u, 64 = C-u C-u C-u).
- Babel sessions send each block to the REPL as one "run this file" line
  (the REPL shows that line, not the code), and Lua blocks run inside Neovim.
- Captures without `:unnarrowed` are edited in a separate buffer and show
  up in the target file when they are finished (Neovim has no indirect
  buffers).

---

## 🧩 Extensions

Optional features modelled on popular third-party Emacs Org packages ship
with org.nvim but stay unloaded until you enable them in `extensions`:

```lua
require("org").setup({
  extensions = {
    present = true,                  -- enable with the defaults
    roam = { directory = "~/roam" }, -- options are merged over its defaults
  },
})
```

`false` or `{ enabled = false }` keeps one off, and `:checkhealth org` lists
the enabled ones and checks what each needs. An extension adds its own
actions, `:Org` subcommands and default keys, but never replaces a key you
set. See `:h org-extensions`.

Each extension is marked ✅ **stable** (used daily, well covered by specs;
changes to its options or keys are called out in the release notes) or
🧪 **experimental** (works and is tested, but has seen less real use, so
its options may still change):

| ✅ Stable | 🧪 Experimental |
| --- | --- |
| `ql`, `super_agenda`, `present`, `roam`, `quickadd`, `ics`, `kanban`, `sidebar` | `review`, `pomodoro`, `drill`, `merge`, `cli`, `diagrams`, `code`, `literate`, `lsp`, `transclusion`, `timeline`, `heatmap` |

> [!NOTE]
> 🧪 Experimental extensions are prone to change. Their options, commands,
> keys and output (such as the `org` command line's JSON) can change in any
> release, so read the release notes before you upgrade if a config or a
> script relies on one.

- ✅ **`present`** ([org-present](https://github.com/rlister/org-present)):
  `:Org present` shows the buffer as a slideshow, one top-level heading per
  slide, in its own tab (`:h org-extensions-present`).

  ![Presenting an org file: title slide, content slides with a counter, the whole file on one page, and back to the untouched file](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/present.gif)

- ✅ **`ql`** ([org-ql](https://github.com/alphapapa/org-ql)): queries such as
  `(and (todo "NEXT") (tags "work"))` or `todo:NEXT tags:work !done`,
  `:Org ql_search`, named and saved views, `ql_find`, `ql_refile`,
  `ql_sparse_tree`, recent items, `org-ql` agenda custom commands and
  `#+BEGIN: org-ql` blocks (`:h org-extensions-ql`).

  ![org-ql: a sexp query, changing a result's TODO state, the same search in plain syntax, a saved view sorted by deadline and an org-ql dynamic block](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/ql.gif)

- ✅ **`roam`** ([org-roam](https://github.com/org-roam/org-roam)): org-roam
  v2 notes in the same file format, so a directory can be shared with
  Emacs: find and insert nodes (typing a new title creates one), a
  backlinks, reflinks and unlinked references window, aliases, refs and
  tags, capture templates with org-roam's `:target` forms, extracting and
  refiling subtrees, daily notes, `roam-ref` / `roam-node` org-protocol
  handlers and a Graphviz node graph, over a JSON index that updates
  incrementally. Its keys live under `<prefix>m` (`<prefix>mf` finds a
  node, `<prefix>mi` inserts one, `<prefix>ml` toggles the backlinks
  window, `<prefix>mj` captures to today's daily note and `<prefix>md…`
  goes to the dailies) (`:h org-extensions-roam`).

  ![org-roam: find a node, backlinks, insert a link to a new node, daily notes](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/roam.gif)

- ✅ **`super_agenda`** ([org-super-agenda](https://github.com/alphapapa/org-super-agenda)):
  group agenda days and lists (including org-ql results) by time grid,
  deadline, tag, priority, category and more, with auto groups. `<Tab>` on
  a group header folds the group, and `gj` / `gk` move between headers
  (`:h org-extensions-super-agenda`).

  ![org-super-agenda: the day agenda in groups, moving between headers with gj and folding groups with Tab, then org-ql results grouped by category](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/super-agenda.gif)

- ✅ **`quickadd`** ([Todoist](https://todoist.com/help/articles/use-task-quick-add-in-todoist-va4Lhpzz)-style
  quick add): `:Org quickadd` or `<prefix>q` turns one line such as
  `Call Bob fri 3pm #work !A ~30m @Inbox due mon every week` into an entry
  with SCHEDULED / DEADLINE, repeater, tags, priority and Effort, filed
  under the best-matching heading, with a live preview while you type.
  Capture templates can use the same syntax with `quickadd = true`
  (`:h org-extensions-quickadd`).

  ![Quick add: typing a Todoist-style line with a live preview of the parsed entry, which lands under the matching heading with its date, tags, priority and effort](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/quickadd.gif)

- 🧪 **`review`** (GTD weekly review): `:Org review` (`<prefix>W`) steps
  through a weekly review in a float: empty the inbox (refile, schedule,
  set a state, delete or skip each entry), stuck projects, waiting-for,
  overdue, the next two weeks, someday/maybe, last week's clocked time and
  reflection questions, with a progress line, `n` / `p` between steps and
  resumable progress. Finishing logs the review in a date tree. Steps can
  be reordered or replaced with your own (`:h org-extensions-review`).

  ![Weekly review: scheduling and deleting inbox entries, stepping through stuck projects, waiting, overdue, upcoming, someday and clocked time, answering a reflection question, and the review logged in a date tree](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/review.gif)

- 🧪 **`pomodoro`** ([org-pomodoro](https://github.com/marcinkoziej/org-pomodoro)):
  `<prefix>zs` starts a pomodoro on the heading at the cursor and clocks it
  in; when the 25 minutes are up the entry's `POMODOROS` count goes up, the
  clock stops and a 5-minute break starts (15 minutes after every fourth),
  with notifications and an optional sound. Pause, skip and stop, an
  optional overtime, a session that survives a restart, and a countdown
  in `require("org").statusline()` (`:h org-extensions-pomodoro`).

  ![Pomodoro: starting a pomodoro clocks in the task, the statusline counts down, pause and resume, the pomodoro ends with POMODOROS counted, a break and the next pomodoro](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/pomodoro.gif)

- 🧪 **`drill`** ([org-drill](https://gitlab.com/phillord/org-drill)):
  flashcards with spaced repetition. Headings tagged `:drill:` are cards
  (simple, two-sided, multi-sided and cloze deletions such as
  `[Nile||river]`); `:Org drill` (`<prefix>D`) reviews the due ones in a
  floating window, you grade each answer 0-5, and org-drill's SM-5 (or
  SM-2 / Simple8) schedules the next review in its `DRILL_*` properties,
  so a deck can be shared with Emacs. Leeches, cram mode and org-drill's
  weighted cloze types included (`:h org-extensions-drill`).

  ![org-drill: reviewing due cards in a float, showing answers, grading them 0-5, a cloze card, a two-sided card, a failed card coming back, the session summary and the new schedule in the file](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/drill.gif)

- 🧪 **`merge`**: a structural git merge driver for Org files. `:Org
  merge_install` registers it for the repository (`*.org merge=org`), and
  git then merges org files entry by entry: entries matched by `ID` or
  outline path, refiles followed, properties merged key by key, clocks and
  tags unioned, and a real conflict marked only around the one entry (or
  property) both sides changed. Also usable without org.nvim's setup via
  `bin/org-merge` (`:h org-extensions-merge`).

  ![Structural git merge: two branches edit the same org file, git merge with the Org driver merges tags, properties, clocks and new entries cleanly, and a second merge leaves one conflict around a single headline](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/merge.gif)

- ✅ **`ics`**: subscribe to Google, Outlook or any iCalendar (`.ics`)
  calendar, a secret URL fetched with curl into a cache or a local file,
  and see its events read-only in the agenda day and week views: times
  converted to your zone, repeating events, exceptions and cancellations.
  `ics_import` copies an event into an org file and `ics_refresh` fetches
  the calendars again (`:h org-extensions-ics`).

  ![The week agenda with events from two subscribed calendars next to org tasks, then ics_import copying a meeting into inbox.org as a heading](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/ics.gif)

- 🧪 **`cli`**: an `org` shell command (`bin/org`, a headless Neovim) that
  prints the agenda as text, CSV or JSON, captures with a template, clocks
  in and out, reports the running clock (for tmux, SketchyBar or Raycast),
  searches, queries and exports, and changes headings (TODO state, tags,
  priority, properties, dates, notes, refile, archive) without ever
  prompting, from a config file of its own. With `--json` every command
  prints a versioned envelope with stable error codes, and `org schema`
  describes the commands as JSON Schema, so scripts and AI agents can use
  it as a tool (`:h org-extensions-cli`, `:h org-extensions-cli-json`).

  ![The org command line: the day agenda as text, the agenda as JSON through jq, capturing a task into the inbox, and clocking in, checking the clock for a status line and clocking out](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/org-cli.gif)

- 🧪 **`diagrams`** ([ob-mermaid](https://github.com/arnm/ob-mermaid),
  ob-dot, ob-plantuml): `mermaid` (mmdc) and `dot` (Graphviz) source
  blocks, plus extras for `plantuml`: `C-c C-c` writes the diagram and
  inserts a `file:` link (a name is generated when there's no `:file`),
  renders are cached by content hash, the image is previewed inline when an
  image backend is available, and `render_on_save` re-renders changed
  diagrams on `:w` (`:h org-extensions-diagrams`).

  ![Diagrams: C-c C-c on a mermaid block inserts a file: link to a real PNG, and saving renders every diagram block, re-rendering only the one that changed](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/diagrams.gif)

- 🧪 **`code`**: a bridge between code and notes. `code_capture` turns a
  Visual selection into a `#+begin_src` block with a link back and the git
  branch; `[[code:src/app.lua::M.setup]]` links jump to a symbol through
  LSP (else treesitter or a text search); each repository gets an org file
  (`.org/tasks.org`) with `project_open`, `project_capture` and a
  `project_agenda` that lists the code's `TODO:` / `TODO(org:ID)`
  comments; opt-in clocking by git branch. Keys under `<prefix>j`
  (`:h org-extensions-code`).

  ![code: a Visual selection in a Lua file captured as a src block with a code: link and the branch, the link followed back to the function, and the project agenda with the TODO comments of the repository](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/code.gif)

- 🧪 **`literate`**: a literate Neovim config. Saving `init.org` tangles it
  and runs only the Lua blocks you changed, so an option or keymap applies
  at once; errors are diagnostics on the org line. Plus `literate_reload`,
  `literate_run_block`, `literate_health`, a jump from the tangled file
  back to the block, and `:Org literate_bootstrap` for an init.lua that
  re-tangles a newer init.org on startup (`:h org-extensions-literate`).

  ![literate: editing a Lua block of init.org and saving it changes an option live, then a block with an error shows a diagnostic on its org line](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/literate.gif)

- 🧪 **`lsp`**: a language server for org buffers that runs inside Neovim
  (nothing to install), so every LSP feature and plugin works in Org
  files: the outline as document symbols, headlines of all your files as
  workspace symbols, org-lint diagnostics as you type, hover on
  timestamps ("in 3 days, Friday", repeaters explained), links (a preview
  of the target), clocks and footnotes, go to definition, references, code
  actions (schedule, refile, archive, lint quick fixes) and a rename of a
  headline, CUSTOM_ID, ID or target that rewrites every link to it across
  files, something Emacs can't do (`:h org-extensions-lsp`).

  ![The org language server: org-lint diagnostics inline, the outline as document symbols, hover on a timestamp and on a link, and renaming a CUSTOM_ID updates the links in another file](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/lsp.gif)

- 🧪 **`transclusion`** ([org-transclusion](https://github.com/nobiot/org-transclusion)):
  `#+transclude: [[file:notes.org::*Heading]] :level 2` or
  `[[file:main.py]] :lines 10-24 :src python` shows that text live, as
  virtual lines under the keyword (the file isn't touched) or inserted into
  the buffer like Emacs and taken out again when it's written. `<CR>` edits
  the source in a float and `:w` writes it back and updates every
  transclusion; sources are watched, nested transclusions expand, and
  `#+transclude:` is expanded on export (`:h org-extensions-transclusion`).

  ![Live transclusion: a heading of another file and lines of a Python file shown under their #+transclude: keywords, the heading edited in a float and written back, the text inserted into the buffer and back to virtual lines, then folded away with their headings](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/transclusion.gif)

- ✅ **`kanban`**: a board with a column per TODO keyword (or group of
  keywords, with WIP limits) and a card per heading showing its priority,
  deadline countdown, effort and tags. `h` / `l` move a card to the
  previous / next state through the regular TODO code, so logging, CLOSED
  and repeaters work; `/` filters by tags match or org-ql query, `<CR>`
  opens the heading. Cards come from the agenda files, a buffer, a subtree
  or a query (`:Org kanban`, `<prefix>Vk`, `:h org-extensions-kanban`).

  ![Kanban board: moving a card to NEXT goes over the WIP limit, filtering by a tag, moving a card to DONE and opening its heading with CLOSED logged](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/kanban.gif)

- 🧪 **`timeline`**: a text-mode Gantt chart of the tasks with SCHEDULED,
  DEADLINE or Effort: bars from start to deadline, ◆ deadlines, today's
  column, overdue tasks in red, optional clocked days. `+` / `-` zoom
  (day, week, month), `[` / `]` pan, `S` / `D` reschedule
  (`:Org timeline`, `<prefix>Vt`, `:h org-extensions-timeline`).

  ![Timeline: a Gantt chart of a plan, panning, zooming out to weeks, showing clocked days and moving an overdue deadline with the calendar](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/timeline.gif)

- 🧪 **`heatmap`**: a GitHub-style calendar of the time clocked each day,
  the tasks closed or the habits done, shaded from your colorscheme, with
  totals and streaks; the selected day shows its tasks and `<CR>` opens its
  agenda (`:Org heatmap [clock|closed|habit] [tag]`, `<prefix>Vh`,
  `:h org-extensions-heatmap`).

  ![Heatmap: nine months of clocked time, a day's total and tasks, tasks closed per day, one tag only and the agenda of the selected day](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/heatmap.gif)

- ✅ **`sidebar`**: a narrow "Today" window with the running clock against
  its effort, the next appointment with a countdown, today's items,
  habits due and the inbox count, kept up to date by a timer and on writes
  (`sidebar_toggle`, `<prefix>Vs`, `:h org-extensions-sidebar`).

  ![Today sidebar: clocking in, opening the sidebar, jumping to an overdue task and capturing to the inbox while its count updates](https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/sidebar.gif)

---

## 🧭 Roadmap

The [parity inventory](#-parity-with-emacs-org) leaves only two options
partial (`calc_default_modes` and Common Lisp's evaluator, which is `sbcl`
rather than SLIME/SLY). What's still missing is finer-grained than one
command or option:

- [ ] Calc's symbolic mode and date format in `calc_default_modes`
- [ ] Calc's rule-based `integ`, `factor`, polynomial functions and numeric `solve`/`fsolve` for degree 5 and up
- [ ] table.el's cell commands (split, span, justify) and live realignment in `C-c '`
- [ ] Babel sessions for more languages (Julia, SQL engines)
- [ ] Custom `diary-date-forms` in the Emacs diary file
- [ ] Column view headlines read-only against every kind of edit (Visual, Ex commands, the API)
- [ ] `#+BIND` for export variables that have no org.nvim option
- [ ] More [extensions](#-extensions)

Done in the latest parity round (every command and option of Org 9.8.10
checked, see the
[parity review](docs/parity-review.md#fifth-round-a-measured-inventory)):
citations you can insert, follow and highlight, and the CSL processor
(a port of citeproc-el); KOMA letters and man pages as native export
back-ends; highlighted source code in HTML and engraved LaTeX; Babel for
PlantUML, gnuplot, LaTeX, ditaa, LilyPond, Java, C#, Haskell, Clojure,
Common Lisp, Scheme, Fortran, Julia, OCaml, Groovy, Maxima, Processing and
screen; ol-bibtex; Org-aware `=` indentation and `gq` filling; the agenda's
remote undo, hour and minute date shifts and `i` diary entries;
alphabetical list bullets; the org-goto outline browser; the Org, table and
agenda menus and org-mouse; clipboard image paste; org-ctags. In all, 163
commands and 329 options that were missing, partial or thought to need
Emacs now work like Emacs.
Since then, the [extensions](#-extensions) `present`, `ql`, `roam` and
`super_agenda` have landed.
Sixteen more followed: `lsp`, `kanban`, `timeline`, `heatmap`,
`sidebar`, `quickadd`, `review`, `pomodoro`, `drill`, `code`, `literate`,
`merge`, `ics`, `cli`, `diagrams` and `transclusion`.

What needs Emacs itself (indirect buffers for narrowed captures, Emacs
applications such as Gnus and mu4e, Lisp that must change the editor's
state) isn't planned; see [Differences from Emacs Org mode](#differences-from-emacs-org-mode).

If there's something you'd like that isn't here,
[open an issue](https://github.com/xheisenbugx/org.nvim/issues).

---

## 🤝 Contributing

Contributions of all sizes are welcome: bug reports, docs fixes, new link
types, Babel languages, exporters, or anything on the roadmap. Each piece
of Org lives in its own small module, and there's a fast headless test
suite, so it's easy to get started:

```sh
git clone https://github.com/xheisenbugx/org.nvim && cd org.nvim
make test                                 # run all specs headlessly
make test SPEC=tests/spec/agenda_spec.lua # one spec
make lint                                 # stylua --check + source lint rules
```

[`CONTRIBUTING.md`](CONTRIBUTING.md) explains how the code is organised
and how to add a feature. [`CHANGELOG.md`](CHANGELOG.md) lists what changed
in each release.

## License

org.nvim is released under the [MIT License](LICENSE).

---

<div align="center">

**If org.nvim makes your notes, tasks or agenda better, give it a ⭐.**
It helps other Neovim users find it.

You can also [buy me a coffee on Ko-fi ☕](https://ko-fi.com/xheisenbugx).

</div>
