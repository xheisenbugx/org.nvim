# AGENTS.md

Guidance for coding agents working on org.nvim, an Emacs Org mode
implementation for Neovim 0.10+ written in pure Lua with no dependencies.
[CONTRIBUTING.md](CONTRIBUTING.md) is the human-facing version of this file.

## Commands

```sh
make test                                  # all specs, headless
make test SPEC=tests/spec/agenda_spec.lua  # one spec (space-separate several)
make lint                                  # stylua --check lua plugin ftplugin syntax tests
```

- `make test` runs with a throwaway `XDG_DATA_HOME`, so tests never touch the
  real ID database or clock state. Run specs through `make`, not bare `nvim`.
- Run the specs for the area you touched while iterating, and the full suite
  before you finish.
- Formatting follows `stylua.toml`: 2-space indent, 120 columns, double
  quotes. Don't reformat files you didn't change. If your local stylua
  disagrees with the existing code in untouched files, it's the wrong version;
  hand-format your changes to match and say that lint wasn't run.

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
- **Key conflicts matter.** Before adding a default key in `mappings.lua`,
  check it isn't a prefix of, or already taken by, another mapping.

## Emacs parity

The goal is to behave like Emacs Org 9.8. When changing behaviour, check what
Emacs does (the Org source and manual) instead of guessing. Specs named
`*_emacs_spec.lua` and `*_parity_spec.lua` pin Emacs behaviour; don't change
their expectations to make a test pass unless Emacs really does something
else. Intentional differences go under `:h org-differences` in `doc/org.txt`.
`docs/parity-review.md` records past parity reviews.

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
- Document user-visible changes in `doc/org.txt`, and in `README.md` when
  it's a headline feature.
- No new hard dependencies. Optional integrations (blink.cmp, lualine, …)
  must load only when the user has them installed.
- Say in the PR description how the change was tested.
