# Contributing to org.nvim

Thanks for your interest in org.nvim! Contributions of every size are
welcome, from fixing a typo to adding an exporter. This guide covers what
you need to get started.

## Ways to help

- **Report bugs.** Please include the org snippet that triggers the bug, the
  keys you pressed, what you expected, and the output of `:checkhealth org`.
- **Compare with Emacs.** If org.nvim does something differently from Emacs
  Org mode and the doc doesn't mention it
  ([`:h org-differences`](doc/org.txt)), please open an issue.
- **Improve the docs.** The README, `doc/org.txt` and
  `examples/tutorial.org` are all fair game.
- **Build a feature.** The [Roadmap](README.md#-roadmap) lists what's
  missing. Check the issues first, or open one, so work isn't duplicated.

## Development setup

You only need Neovim 0.10+. For linting, you also need
[stylua](https://github.com/JohnnyMorganz/StyLua).

```sh
git clone https://github.com/xheisenbugx/org.nvim && cd org.nvim
make test                                 # all specs, headless
make test SPEC=tests/spec/agenda_spec.lua # a single spec
make lint                                 # stylua --check
```

To try your checkout in your own config, point lazy.nvim at it:

```lua
{ dir = "~/path/to/org.nvim", name = "org.nvim", main = "org", lazy = false, opts = {} }
```

## How the code is organised

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

Some things to know before you start:

- **Everything is an action.** Every user-facing operation is registered by
  name in [`lua/org/actions.lua`](lua/org/actions.lua). Keymaps
  (`mappings.org.<action>`) and `:Org <action>` both go through that
  registry. An action that returns `false` means "not applicable here", and
  its key then falls back to Vim's default behaviour.
- **The parser is the source of truth.** `org.parser` turns lines into
  headlines, planning, properties, clocks and timestamps, and `org.files`
  caches the result per file. Build on those instead of matching text by
  hand.
- **Defaults live in one place.** Every option and its default is in
  [`lua/org/config.lua`](lua/org/config.lua). Add new options there and
  document them in `:h org-config`.

## Adding a feature

1. Implement it in the module it belongs to, or add a new one.
2. If users can trigger it, register an action in `lua/org/actions.lua`,
   and give it a default key in `lua/org/mappings.lua` if it needs one.
3. Add a spec under `tests/spec/`. The helpers make buffer tests short:

   ```lua
   describe("tags", function()
     it("sets tags", function()
       local buf = org_buffer({ "* TODO Task" }, { 1, 0 }) -- lines, cursor
       require("org.tags").set_tags(nil, { "work" })
       ok(buf_lines(buf)[1]:match(":work:$"))
     end)
   end)
   ```

4. Document it in `doc/org.txt` (and in the README if it's user-visible).
5. Run `make test` and `make lint`.

## Pull requests

- Keep each PR focused on one change. Small PRs get reviewed faster.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for
  titles, as the history does: `feat(agenda): …`, `fix(capture): …`,
  `docs: …`.
- Describe how you tested the change. For UI changes, a screenshot or
  short recording helps a lot.
- Keep org.nvim dependency-free. Optional integrations such as blink.cmp or
  lualine are fine, as long as they're loaded only when the user has them.

Thanks again, and happy hacking! 🦄
