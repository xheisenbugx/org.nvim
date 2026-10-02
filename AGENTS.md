# AGENTS.md

Guidance for coding agents working on org.nvim, an Emacs Org mode
implementation for Neovim 0.11+ written in pure Lua with no dependencies.
[CONTRIBUTING.md](CONTRIBUTING.md) is the human-facing version of this file.

## Commands

```sh
make test                                  # all specs, headless
make test SPEC=tests/spec/agenda_spec.lua  # one spec (space-separate several)
make lint                                  # stylua --check, then scripts/lint_sources.lua over lua/
make format                                # stylua over the same paths
```

- `make test` runs with a throwaway `XDG_DATA_HOME`, so tests never touch the
  real ID database or clock state. Run specs through `make`, not bare `nvim`.
- Run the specs for the area you touched while iterating, and the full suite
  before you finish.
- Formatting follows `stylua.toml` (2-space indent, 120 columns, double
  quotes, LuaJIT syntax). Run `make format` and make sure `make lint` passes
  before you finish. Don't use `goto` as a field or method name: stylua
  can't parse it (write `M["goto"]`).
- `make lint` also runs `scripts/lint_sources.lua`, which flags bug classes
  that kept coming back: `vim.fn.expand()` on a non-literal (it runs
  `backticks`; use `utils.expand_vars` / `utils.expand`), a `gsub`
  replacement that is a variable or concatenation (`%` in it is a capture;
  wrap it in `utils.gsub_escape`), and a `#+KEY:` value's column found again
  with `line:find(value)` (capture it with `()`). An audited safe use takes
  `-- lint: allow <rule>: <reason>` on its line or the line above.

## Layout

| Path | Contents |
| --- | --- |
| `lua/org/init.lua` | `setup()` entry point |
| `lua/org/config.lua` | every option and its default |
| `lua/org/actions.lua` | registry of every user-facing operation |
| `lua/org/mappings.lua` | default keys, bound to actions |
| `lua/org/parser.lua`, `element.lua`, `files.lua` | parsing and the per-file cache |
| `lua/org/agenda/`, `babel/`, `export/`, `table/`, `ui/` | larger subsystems |
| `lua/org/_meta/` | LuaLS type annotations for `setup()` options (no runtime code) |
| `plugin/`, `ftplugin/`, `syntax/` | Vim runtime files |
| `doc/org.txt` | the user manual (`:h org`); `doc/tags` is its helptags |
| `examples/` | per-feature tutorial `.org` files |
| `tests/run.lua`, `tests/minimal_init.lua` | the test runner and headless init |
| `tests/spec/*_spec.lua`, `tests/fixtures/` | specs and the fixture org files |

## How the code fits together

- **Everything is an action.** User-facing operations are registered by name
  in `lua/org/actions.lua`. Keymaps (`mappings.org.<action>`) and
  `:Org <action>` both go through that registry. An action that returns
  `false` means "not applicable here", and its key falls back to Vim's
  default behaviour. Keep that contract: don't return `false` after you've
  changed the buffer.
- **The parser is the source of truth.** Use `org.parser` and `org.files`
  for headlines, planning, properties, clocks and timestamps rather than
  matching text by hand.
- **Options live in `config.lua`.** A new option needs a default there, an
  entry under `:h org-config` in `doc/org.txt`, and a type in
  `lua/org/_meta/`.
- **Org saves through `utils.save_buffer`.** It writes with `:noautocmd`,
  so logic that must run around every write (`:w` or org's own saves)
  registers a hook in `lua/org/write_hooks.lua`, not a
  BufWritePre/BufWritePost autocommand. See CONTRIBUTING.md.
- **Key conflicts matter.** Before adding a default key in `mappings.lua`,
  check it isn't a prefix of, or already taken by, another mapping.

## Emacs parity

The goal is to behave like Emacs Org 9.8. When changing behaviour, check what
Emacs does (the Org source and manual) instead of guessing. Specs named
`*_emacs_spec.lua` and `*_parity_spec.lua` pin Emacs behaviour; don't change
their expectations to make a test pass unless Emacs really does something
else. Intentional differences go under `:h org-differences` in `doc/org.txt`.
`docs/parity-review.md` records past parity reviews.

`tests/spec/emacs_*_parity_spec.lua` compare org.nvim with real Emacs output
checked in under `tests/fixtures/emacs/` (visibility, agenda, export, clock
tables, org-lint). Regenerate those fixtures with `make parity-fixtures`
(it needs Emacs with Org 9.8.10, see `scripts/emacs-parity/README.md`), never
by hand. Rewrite rules for intentional differences live only in `NORMALISE`
in `tests/emacs_parity.lua`; known bugs go in a spec's `KNOWN` table.

## Tests

The runner is a small busted-style harness (`tests/run.lua`) with globals
`describe`, `it`, `before_each`, `after_each`, `eq(expected, actual)`,
`ok(value)`, `org_buffer(lines, cursor)`, `buf_lines(buf)` and
`with_config(overrides)` (set options for every test in a `describe`).

```lua
describe("tags", function()
  it("sets tags", function()
    local buf = org_buffer({ "* TODO Task" }, { 1, 0 }) -- lines, {lnum, col0}
    require("org.tags").set_tags(nil, { "work" })
    ok(buf_lines(buf)[1]:match(":work:$"))
  end)
end)
```

Every bug fix and feature gets a spec. Tests run headless, so anything that
prompts (`vim.fn.input`, `vim.ui.select`, confirms) has to be stubbed or
turned off, or the run will hang.

## Changes and PRs

- Keep each change focused; one fix or feature per branch and PR.
- Branch names and titles follow Conventional Commits, as in the history:
  `fix/capture-prompt-after-tags` and `fix(capture): …`, `feat(agenda): …`,
  `docs: …`.
- Branch from `dev` and open pull requests against `dev`. `main` only takes
  `release/vX.Y.Z` branches, whose merge tags and publishes the release.
- Document user-visible changes in `doc/org.txt`, and in `README.md` when
  it's a headline feature.
- No new hard dependencies. Optional integrations (blink.cmp, lualine, …)
  must load only when the user has them installed.
- Say in the PR description how the change was tested.
