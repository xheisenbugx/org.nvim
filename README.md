# org.nvim

Org mode for Neovim, written in pure Lua with no dependencies. It aims to
cover everyday Emacs Org mode: outlines, TODOs, scheduling, agenda, capture,
clocking, tables with formulas, links, Babel and export.

It works with any setup. There is first-class support for LazyVim
(which-key groups, blink.cmp completion, `vim.ui.select` pickers through
snacks).

> Full reference: `:h org.nvim` (see [`doc/org.txt`](doc/org.txt)).
> Hands-on tour: open [`examples/tutorial.org`](examples/tutorial.org).

---

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
  - [LazyVim / lazy.nvim](#lazyvim--lazynvim)
  - [Local development checkout](#local-development-checkout)
- [Quick start](#quick-start)
- [Keymaps](#keymaps)
- [Configuration](#configuration)
- [Capture templates](#capture-templates)
- [Custom agenda commands](#custom-agenda-commands)
- [Completion](#completion)
- [Statusline](#statusline)
- [Differences from Emacs Org mode](#differences-from-emacs-org-mode)
- [Development](#development)

---

## Features

| Area | What you get |
| --- | --- |
| **Outline** | Folding by headline, with drawers and blocks folding one level deeper. `TAB` subtree cycling and `S-TAB` global cycling, like Emacs. `#+STARTUP` visibility. Motions (`]]`, `[[`, `][`, `[]`, `g{`) and text objects (`ih`, `ah`, `ir`, `ar`). |
| **Structure editing** | `M-RET` inserts a heading, list item or table row depending on context. Promote and demote headings or subtrees, move subtrees, cut/copy/paste them with level adjustment, clone with a time shift. Sort by alpha, numeric, time, priority, TODO or property. Narrow to a subtree. Toggle headings, items and `COMMENT`. Structure templates (`#+begin_src` and friends). Emphasis. |
| **Plain lists** | `-`, `+`, `*`, `1.` and `1)` bullets, `[@N]` counters, description lists, checkboxes with `[-]` partial state. Statistics cookies (`[2/5]`, `[40%]`) with `COOKIE_DATA` support. Renumbering, indent/outdent, move, bullet cycling. |
| **TODO** | Multiple keyword sequences, fast-selection keys, per-file `#+TODO`, and logging with `!` (timestamp) and `@` (note) on entering and leaving a state. `CLOSED:` timestamps. Repeaters `+1w`, `++1d` and `.+2d` with `LAST_REPEAT`. `ORDERED` and checkbox dependencies. Priorities with `#+PRIORITIES`. |
| **Tags and properties** | Fast tag selection with `#+TAGS` groups, inheritance, `#+FILETAGS`, automatic alignment. Property drawers with inheritance, `_ALL` allowed values, `Effort`, and special properties. |
| **Dates** | Active and inactive timestamps, ranges, times and time ranges, repeaters, warning periods. A floating calendar that accepts Org's date input (`+2w`, `fri 14:00`, `sep 15`). `SCHEDULED` and `DEADLINE` with reschedule logging. `C-a`, `C-x` and the shift-arrows change whichever part of the timestamp is under the cursor. |
| **Agenda** | Day, week, fortnight, month and year views, with a time grid and current-time line. Deadline warnings, overdue scheduled items and repeaters. Habits with the Emacs consistency graph. Log mode and clock report mode. The global TODO list, tags and property matches (the full Emacs match syntax), text search and stuck projects. Custom commands with composite blocks. Filters, bulk actions and follow mode. You can edit entries straight from the agenda. |
| **Capture** | Templates with key groups. Entry, item, checkitem, table-line and plain types. Targets can be a file, a headline, an outline path, a date tree, a regexp or a function. All the common `%`-escapes. Finalize, abort or refile from the capture window, or finish with `:w`. |
| **Refile and archive** | Refile to any headline in the agenda files, with outline paths, or create new parent nodes. Archive to `%s_archive::` or a custom location with the `ARCHIVE_*` context properties, plus the `ARCHIVE` tag. |
| **Links** | `[[target][desc]]`, plain and `<angle>` links. `file:` links with `::line`, `::*heading`, `::#id` or `::/regex/`. Also `id:`, `#custom-id`, `*heading`, `<<targets>>`, `http(s)`, `mailto`, `shell:`, `help:` and `attachment:`, plus abbreviations and custom link types. Store and insert links. Concealed display. |
| **Clocking** | Clock in, out, cancel and jump, with effort estimates. A statusline component. The running clock survives restarts. Clock sums shown as virtual text. `clocktable` dynamic blocks with scope, block and match (no `:step` yet). Column view and `columnview` blocks. |
| **Tables** | Automatic alignment. `TAB`, `S-TAB` and `RET` navigation. Insert, delete and move rows and columns. Hlines, sorting, and converting CSV or TSV to a table. Formulas in `#+TBLFM` using `$`/`@` references, ranges, `vsum`/`vmean`/…, and Lua expressions. |
| **Babel** | Run source blocks asynchronously: sh, bash, zsh, python, lua (in-process), node, ruby, R, go, sqlite and more. `:results` handling with all common options. `:var` accepts values, tables or other blocks' results. `:noweb`, `:dir`, `#+CALL`. Tangling with `:tangle`, `:mkdirp` and `:shebang`. Edit a block in a native buffer with `C-c '`. |
| **Export** | Native HTML (standalone, with a table of contents, section numbers and MathJax), GitHub-flavoured Markdown, plain UTF-8 text and LaTeX. Everything else goes through pandoc: PDF, DOCX, ODT, EPUB, RST and more. Handles `#+OPTIONS`, `export`/`noexport` tags, `:exports`, `#+INCLUDE` and macros. |
| **More** | Footnotes, sparse trees, appointment notifications, attachments, IDs, relative and countdown timers, dynamic blocks, completion (blink.cmp, nvim-cmp or omnifunc), and `:checkhealth org`. |

---

## Requirements

- Neovim **0.10+**.
- Optional:
  - `pandoc` for LaTeX, PDF, DOCX and ODT export.
  - `latexmk` or `pdflatex` for native PDF.
  - The language interpreters you want Babel to run.

---

## Installation

### LazyVim / lazy.nvim

```lua
-- ~/.config/nvim/lua/plugins/org.lua
return {
  {
    "xheisenbugx/org.nvim",
    main = "org",
    lazy = false, -- startup cost is tiny: only :Org and a few global keymaps
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

### Global

| Key | Action |
| --- | --- |
| `<prefix>a` | Agenda dispatcher |
| `<prefix>c` | Capture |
| `<prefix>g` | Go to any heading in the agenda files |
| `<prefix>ls` | Store a link to the current location |
| `<prefix>xj` / `xo` / `xq` | Go to clocked task / clock out / cancel clock |

### Org buffers

| Key | Action |
| --- | --- |
| `<Tab>` / `<S-Tab>` | Cycle subtree / global visibility *(ctx: table fields in insert mode)* |
| `<C-c><C-c>`, `<prefix><CR>` | Context action: toggle checkbox, align/recalc table, run src block, update dblock/clock line/cookie, set tags on headline… |
| `<CR>`, `gx`, `<prefix>o` | Open link / footnote / date at point *(ctx)* |
| `<M-CR>` / `<M-S-CR>` | New heading, item or row / new TODO heading or checkbox item |
| `<prefix>ih` `it` `is` | Insert heading / TODO heading / subheading |
| `<prefix>id` `ib` `if` | Insert drawer / block template / footnote |
| `<<` `>>` / `<s` `>s` | Promote/demote heading or item / subtree *(ctx)* |
| `<M-h>` `<M-l>` `<M-k>` `<M-j>` | Promote, demote, move up, move down: heading, item or table column/row *(ctx)* |
| `<M-H>` `<M-L>` `<M-K>` `<M-J>` | Subtree promote/demote; table delete/insert column, delete/insert row *(ctx)* |
| `<prefix>K` / `<prefix>J` | Move subtree up / down |
| `<prefix>hy` `hd` `hp` `hc` | Copy / cut / paste / clone subtree |
| `<prefix>hs` `hn` `hC` `hA` `hb` | Sort / narrow / toggle COMMENT / toggle ARCHIVE tag / cycle bullet |
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

### Agenda buffer

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

### Capture and edit buffers

| Key | Capture | Edit src (`C-c '`) |
| --- | --- | --- |
| `<C-c><C-c>`, `<prefix>w`, `:w` | finalize | — |
| `<C-c>'`, `<prefix>'` | — | save and exit (`:w` writes back) |
| `<C-c><C-k>`, `<prefix>k` | abort | abort |
| `<C-c><C-w>`, `<prefix>r` | refile | — |

---

## Configuration

Every option with its default is in [`lua/org/config.lua`](lua/org/config.lua)
and documented in `:h org-config`. Most common:

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

Expansions:

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

The match syntax is Emacs'. Some examples:

- `+work-boss`
- `work|home`
- `LEVEL>1`
- `Effort<"1:00"`
- `SCHEDULED<="<+2d>"`
- `+proj/NEXT|TODO`
- `/!` (only entries that aren't done)

---

## Completion

- **blink.cmp:** add the provider shown in [Installation](#lazyvim--lazynvim).
- **nvim-cmp:**
  ```lua
  require("cmp").register_source("org", require("org.completion.cmp").new())
  ```
  Then add `{ name = "org" }` to your org sources.
- **Built in:** `<C-x><C-o>` (omnifunc).

It completes:

- TODO keywords
- tags
- `#+` keywords
- `#+STARTUP` and `#+OPTIONS` values
- src block languages
- property names
- link types, headings (`[[*`), custom IDs (`[[#`) and stored links

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

Output looks like `⏱ [0:25/1:00] (Write report)` while a clock runs, and
is empty otherwise.

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
- **Not implemented:**
  - diary sexp timestamps `<%%(…)>`
  - clock idle detection
  - `org-crypt`, `org-protocol`, MobileOrg
  - inline image and LaTeX previews
  - column view as overlays (it opens as a separate table view instead)
- **M-RET** always inserts after the current subtree or item; it never
  splits the line at the cursor.
- Minute increments step by one minute (Emacs rounds to five).

---

## Development

```sh
make test                                 # run all specs headlessly
make test SPEC=tests/spec/agenda_spec.lua # one spec
```

Layout:

| Path | Contents |
| --- | --- |
| `lua/org/` | core: `parser`, `date`, `edit`, `files`, `config`, `actions`, `context`, `mappings` |
| `lua/org/{structure,fold,lists}.lua` | outline editing |
| `lua/org/{todo,priority,tags,properties,timestamps,calendar,clock,dblock,columns,timer}.lua` | task management |
| `lua/org/agenda/` | agenda, search, sparse trees, notifications |
| `lua/org/{capture,refile,archive,links,id,attach,footnotes}.lua` | capture and navigation |
| `lua/org/table.lua`, `lua/org/table/` | tables and formulas |
| `lua/org/babel/` | source blocks |
| `lua/org/export/` | exporters |
| `syntax/`, `lua/org/{syntax,highlights}.lua`, `lua/org/ui/` | highlighting and decorations |
| `tests/` | headless test runner and specs |

Every user-facing operation is a named **action** in `lua/org/actions.lua`.
Keymaps (`mappings.org.<action>`) and `:Org <action>` both go through that
registry.
