<div align="center">

# 🦄 org.nvim

### Emacs Org mode, rebuilt for Neovim in pure Lua.

Outlines · TODOs · Agenda · Capture · Clocking · Spreadsheet tables · Babel · Export

[![Neovim 0.10+](https://img.shields.io/badge/Neovim-0.10%2B-57A143?style=for-the-badge&logo=neovim&logoColor=white)](https://neovim.io)
[![Pure Lua](https://img.shields.io/badge/100%25-Lua-2C2D72?style=for-the-badge&logo=lua&logoColor=white)](lua/org)
[![Zero dependencies](https://img.shields.io/badge/dependencies-zero-ff69b4?style=for-the-badge)](#requirements)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-orange?style=for-the-badge)](CONTRIBUTING.md)

**[Install](#-install-in-30-seconds)** ·
**[Tour](#-a-quick-tour)** ·
**[Features](#-features)** ·
**[Docs](doc/org.txt)** ·
**[Contributing](CONTRIBUTING.md)**

</div>

---

Org mode is one of the most loved tools in Emacs. It works as a
plain-text outliner, planner, time tracker, spreadsheet, literate-programming
notebook and publishing system. **org.nvim puts all of that in Neovim.** It
isn't a syntax file with a few keymaps on top. It reimplements Org's
behaviour: the agenda, capture templates, repeaters, clock tables, table
formulas, Babel and export.

- 🪶 **No dependencies.** It's about 24k lines of Lua and needs no
  tree-sitter parser, external binary or companion plugin.
- 🔁 **Works with Emacs.** It reads and writes the same plain-text format,
  so you can edit a file in Emacs today and in Neovim tomorrow.
- ⌨️ **Keys that fit Vim.** Context-aware keys fall back to normal Vim
  behaviour when they don't apply (`>>` still indents, `<C-a>` still
  increments). Press `g?` anywhere to see what's available.
- 💤 **Ready for LazyVim.** It comes with which-key groups, a blink.cmp
  source, `vim.ui.select` pickers and a lualine clock, and it works with
  any other setup too.
- ✅ **Tested.** The headless test suite has 200+ tests across 23 specs.

---

## ⚡ Install in 30 seconds

With [lazy.nvim](https://github.com/folke/lazy.nvim) / LazyVim:

```lua
-- ~/.config/nvim/lua/plugins/org.lua
return {
  "xheisenbugx/org.nvim",
  main = "org",
  lazy = false, -- startup cost is tiny: only :Org and a few global keymaps
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

---

## 🎬 A quick tour

### A real agenda

`<leader>oa` → `a`. This is actual output from org.nvim, not a mockup:

```text
Day-agenda (W39):
Thursday   24 September 2026 W39
                8:00 ┄┄┄┄┄ ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
                8:20 ← now ─────────────────────────────
  work:         9:30...... Scheduled: TODO Standup                          :team:
               10:00 ┄┄┄┄┄ ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
               12:00 ┄┄┄┄┄ ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
  work:        12:30-13:30 Lunch with the team
  work:        14:00-15:00 Scheduled: TODO Review pull requests              :oss:
               16:00 ┄┄┄┄┄ ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
  work:        In   2 d.: NEXT Ship org.nvim v1.0                            :oss:
  work:        Sched. 2x: WAITING Design feedback
  life:        Scheduled: TODO Run 5k                         * ** ** *!   :habit:
  life:        In   8 d.: TODO Renew passport
```

The time grid, current-time line, deadline countdowns, overdue items and
habit consistency graph all work as they do in Emacs. From the agenda you
can change states, reschedule, clock in, refile, filter and run bulk
actions.

### Spreadsheet tables

Type a rough table, press `<C-c><C-c>`, and it aligns itself and evaluates
its formulas:

```org
| Item     | Qty | Price | Total |
|----------+-----+-------+-------|
| Coffee   |   3 |   4.5 |  13.5 |
| Keyboard |   1 |   120 |   120 |
| Stickers |  10 |   0.8 |     8 |
|----------+-----+-------+-------|
| Sum      |     |       | 141.5 |
#+TBLFM: @2$4..@4$4=$2*$3::@5$4=vsum(@2..@4)
```

### Code that runs in your notes

`<C-c><C-c>` on a source block runs it asynchronously and writes the
output back into the file:

```org
#+begin_src python :results output
import sys
print(f"Hello from Python {sys.version_info.major}!")
print(sum(range(1, 101)))
#+end_src

#+RESULTS:
: Hello from Python 3!
: 5050
```

Python, shell, Lua (in-process), Node, Ruby, R, Go, SQLite and more are
supported, along with `:var`, `:noweb`, `#+CALL` and tangling.

### Capture from anywhere

Press `<leader>oc` → `t` in any buffer, type the task, then press
`<C-c><C-c>` or `:w`. The task is filed where your template says:
under a headline, an outline path or a date tree. The capture keeps a link
back to where you were.

---

## ✨ Features

| | Area | Highlights |
| --- | --- | --- |
| 🌳 | **Outline** | Headline folding with Emacs-style `TAB`/`S-TAB` cycling, `#+STARTUP` visibility, motions (`]]` `[[` `g{`), and text objects (`ih` `ah` `ir` `ar`) |
| ✂️ | **Structure editing** | A context-aware `M-RET`, promote and demote, move, cut/copy/paste/clone subtrees, sort, narrow, structure templates |
| 📋 | **Plain lists** | Every bullet style, checkboxes with a `[-]` partial state, `[2/5]` and `[40%]` statistics cookies, renumbering |
| ✅ | **TODO** | Multiple keyword sequences, fast selection, `!`/`@` logging, repeaters (`+1w`, `++1d`, `.+2d`), `ORDERED` dependencies, priorities |
| 🏷️ | **Tags and properties** | Fast tag selection with groups, inheritance, `#+FILETAGS`, property drawers, `Effort`, `_ALL` values |
| 📅 | **Dates** | A floating calendar that understands `+2w`, `fri 14:00` and `sep 15`; `SCHEDULED`/`DEADLINE`; `<C-a>`/`<C-x>` on any part of a timestamp |
| 🗓️ | **Agenda** | Day to year views, a time grid, habits, log and clock-report modes, the full Emacs match syntax, custom composite commands, filters, bulk actions, follow mode |
| 📥 | **Capture** | Grouped templates; entry, item, checkitem and table-line types; file, headline, outline-path, date-tree, regexp and function targets; all the common `%`-escapes |
| 📦 | **Refile and archive** | Refile to any headline in the agenda files; archive with the `ARCHIVE_*` context properties |
| 🔗 | **Links** | `file:` with `::line`, `::*heading`, `::#id` and `::/regex/`; `id:`, `<<targets>>`, `shell:`, `attachment:`, abbreviations, custom types, concealed display |
| ⏱️ | **Clocking** | Clock in/out/cancel/jump, effort estimates, a statusline component, clocks that survive restarts, `clocktable` blocks, column view |
| 🧮 | **Tables** | Automatic alignment, row and column editing, CSV/TSV import, and `#+TBLFM` formulas with ranges, `vsum`/`vmean` and Lua expressions |
| 🧪 | **Babel** | Asynchronous execution in many languages, `:results`, `:var`, `:noweb`, `:dir`, `#+CALL`, tangling, and editing a block in its own buffer with `C-c '` |
| 📤 | **Export** | Native HTML (with a TOC, section numbers and MathJax), Markdown, plain text and LaTeX, plus PDF, DOCX, ODT, EPUB and more through pandoc |
| 🎁 | **And more** | Footnotes, sparse trees, appointment notifications, attachments, IDs, timers, dynamic blocks, completion, `:checkhealth org` |

The full reference is in `:h org.nvim` ([`doc/org.txt`](doc/org.txt)).

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
- [Statusline](#statusline)
- [Differences from Emacs Org mode](#differences-from-emacs-org-mode)
- [Roadmap](#-roadmap)
- [Contributing](#-contributing)

---

## Requirements

- Neovim **0.10+**. Nothing else is required.
- Optional:
  - `pandoc` for LaTeX, PDF, DOCX and ODT export.
  - `latexmk` or `pdflatex` for native PDF.
  - The language interpreters you want Babel to run.

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
require("org").setup({ org_directory = "~/org" })
```

### Local development checkout

Point lazy.nvim at the directory instead of a GitHub repo:

```lua
{
  dir = "~/Workspace/orgmode",
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
2. Type `* TODO Buy milk` and press `<leader>os` to schedule it for today.
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
`C-c C-e`, `C-c '`, `C-c C-v e`, `C-c =`, `C-c -`, `C-c ^` and about 90 more.
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
| `<Tab>` / `<S-Tab>` | Cycle subtree / global visibility *(ctx: table fields in insert mode)* |
| `<C-c><C-c>`, `<prefix><CR>` | Context action: toggle checkbox, align/recalc table, run src block, update dblock/clock line/cookie, set tags on headline… |
| `<CR>`, `gx`, `<prefix>o` | Open link / footnote / date at point *(ctx)* |
| `<M-CR>` / `<M-S-CR>` | New heading, item or row / new TODO heading or checkbox item |
| `<prefix>ih` `it` `is` | Insert heading / TODO heading / subheading |
| `<prefix>id` `ib` `if` | Insert drawer / block template / footnote |
| `<<` `>>` / `<s` `>s` | Promote/demote heading or item / subtree *(ctx)* |
| `<M-h>` `<M-l>` (also `<M-Left>` `<M-Right>`) | Promote / demote heading or item; move table column *(ctx)* |
| `<M-k>` `<M-j>` | Move subtree, item or table row up / down *(ctx)* |
| `<M-H>` `<M-L>` `<M-K>` `<M-J>` | Subtree promote/demote; table delete/insert column, delete/insert row *(ctx)* |
| `<prefix>K` / `<prefix>J` | Move subtree up / down |
| `<prefix>hy` `hd` `hp` `hc` | Copy / cut / paste / clone subtree |
| `<prefix>hs` `hn` `hC` `hA` `hb` | Sort (children, or the selection in Visual mode) / narrow / toggle COMMENT / toggle ARCHIVE tag / cycle bullet |
| `<prefix>*` / `<prefix>-` | Toggle heading / list item |
| `cit` / `ciT` / `<prefix>T` | Next / previous / select TODO state |
| `<S-Right>` `<S-Left>` | Next/previous TODO; date ±1 day; cycle bullet *(ctx)* |
| `<S-Up>` `<S-Down>`, `<C-a>` `<C-x>` | Priority or timestamp part up/down *(ctx)* |
| `<prefix>,` `t` `p` `P` | Priority / tags / set property / delete property |
| `<prefix>s` `d` `i.` `i!` | Schedule / deadline / active / inactive timestamp |
| `<C-Space>`, `<prefix>#` | Toggle checkbox / update statistics cookies |
| `<prefix>xi` `xo` `xq` `xj` `xe` | Clock in / out / cancel / goto / set effort |
| `<prefix>xr` `xd` `xu` `xU` `C` | Insert clocktable / show clock sums / update dblock(s) / column view |
| `<prefix>li` `ls` `lt` `ln` `lp` `lI` | Insert / store link, toggle link display, next/prev link, create ID |
| `<prefix>r` `$` `A` | Refile / archive subtree / attachments |
| `<prefix>/` `e` | Sparse tree / export dispatcher |
| `<prefix>Tc` `T-` `Tf` `Ts` `Tr` `TR` `Ti` `TI` | Table: create/convert, hline, recalc, sort, insert/delete row, insert/delete column |
| `<prefix>'` | Edit src block or table formulas in a separate buffer |
| `<prefix>be` `bb` `bs` `bt` `bk` `bn` `bp` | Babel: execute block/buffer/subtree, tangle, remove result, next/prev block |
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
| `<CR>` / `<Tab>` / `<Space>` | switch to / go to / show entry | `F` | follow mode |
| `t`, `<C-S-Right/Left>` | change TODO | `,` `+` `-` | set/raise/lower priority |
| `:` | tags | `s` / `d` | schedule / deadline |
| `<S-Right>` / `<S-Left>` / `>` | date +1 / −1 / prompt | `e` | effort |
| `I` `O` `X` `J` | clock in / out / cancel / goto | `R` / `$` / `a` | refile / archive / ARCHIVE tag |
| `z` | add note | `c` | capture |
| `l` / `C` | log mode / clock report | `/` `<` `=` `\|` | filter tag / category / regexp / clear |
| `m` `u` `U` `B` | mark / unmark / unmark all / bulk action | `n` / `p` | next / previous item |
| `E` | export agenda | `q` / `x` | quit / quit and wipe |

</details>

<details>
<summary><b>Capture and edit buffers</b> (click to expand)</summary>

| Key | Capture | Edit src (`C-c '`) |
| --- | --- | --- |
| `<C-c><C-c>`, `<prefix>w`, `:w` | finalize | — |
| `<C-c>'`, `<prefix>'` | — | save and exit (`:w` writes back) |
| `<C-c><C-k>`, `<prefix>k` | abort | abort |
| `<C-c><C-w>`, `<prefix>r` | refile | — |

</details>

---

## Configuration

Every option with its default is in [`lua/org/config.lua`](lua/org/config.lua)
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
  window = "float",  -- "float" | "split" | "vsplit" | "current"
}
```

Target options:

- `target`: the file to capture into.
- `headline`: a headline in the target, created if it doesn't exist.
- `olp`: an outline path, as a list of headlines.
- `datetree`: `true`, or `{ tree_type = "week" | "month" }`.
- `regexp`: insert under the first line matching this pattern.

Other options: `type`, `prepend`, `empty_lines`, `properties`,
`immediate_finish`, `jump_to_captured`, `clock_in`, `clock_resume`,
`time_prompt`.

<details>
<summary><b>Template expansions</b> (click to expand)</summary>

| Escape | Inserts |
| --- | --- |
| `%?` | cursor position |
| `%t` `%T` `%u` `%U` | date / date+time, active / inactive |
| `%^t` `%^T` `%^u` `%^U` | same, but prompts with the calendar |
| `%<%Y-%m-%d>` | strftime format |
| `%a` `%A` `%l` | annotation link: plain / with description prompt / bare link |
| `%i` | initial content (the visual selection) |
| `%x` `%c` | clipboard / last yank |
| `%f` `%F` | origin file name / full path |
| `%n` | user name |
| `%^{prompt\|default\|opt}` | prompt with a default and options |
| `%\1` | the answer to the first prompt |
| `%^g` `%^G` | tags prompt |
| `%^{PROP}p` | property prompt |
| `%k` `%K` | the running clock's task / a link to it |
| `%%` | a literal `%` |

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

While a clock runs, it shows something like `⏱ [0:25/1:00] (Write report)`.
It's empty otherwise.

---

## Differences from Emacs Org mode

The goal is feature parity for everyday use, but some things differ:

- **Notes** (state-change notes, `z` in the agenda) are single-line prompts
  instead of a separate note buffer.
- **Table formulas** are evaluated as Lua arithmetic, not Emacs Calc: there
  is no symbolic math, no named fields (`$name`) and no `#+CONSTANTS`.
  Elisp formulas are replaced by `'(lua expression)`.
- **Babel:**
  - There are no `:session` or `:cache` options.
  - Export uses existing `#+RESULTS` blocks and never runs code.
  - `elisp:` links and blocks can't run.
- **Column view** opens as a separate table view instead of overlays.
- **M-RET** always inserts after the current subtree or item; it never
  splits the line at the cursor.
- Minute increments step by one minute (Emacs rounds to five).

The features still missing are listed in the [Roadmap](#-roadmap).

---

## 🗺️ Roadmap

These Emacs features aren't implemented yet. Each one would make a good
first contribution:

- [ ] Inline image and LaTeX previews
- [ ] Clock idle detection
- [ ] `clocktable` `:step`
- [ ] Babel `:session` and `:cache`
- [ ] Multi-line note buffers for state changes
- [ ] Column view as overlays on headlines
- [ ] Diary sexp timestamps `<%%(…)>`
- [ ] Date-tree archive locations
- [ ] `org-crypt` and `org-protocol`

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
make lint                                 # stylua --check
```

[`CONTRIBUTING.md`](CONTRIBUTING.md) explains how the code is organised
and how to add a feature.

---

<div align="center">

**If org.nvim makes your notes, tasks or agenda better, give it a ⭐.**
It helps other Neovim users find it.

</div>
