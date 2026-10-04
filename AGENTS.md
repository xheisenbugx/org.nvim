# AGENTS.md

Guidance for coding agents working on org.nvim, an Emacs Org mode
implementation for Neovim 0.11+ written in pure Lua with no dependencies.
[CONTRIBUTING.md](CONTRIBUTING.md) is the human-facing version of this file.

## Commands

```sh
make test                                  # all specs, headless
make test SPEC=tests/spec/agenda_spec.lua  # one spec (space-separate several)
make snapshots                             # rewrite the screen snapshot golden files
make lint                                  # stylua --check, then scripts/lint_sources.lua over lua/
make format                                # stylua over the same paths
make site                                  # docs website into site/ (scripts/site/build.lua)
make typecheck                             # lua-language-server --check with .luarc.json
make coverage                              # specs with line coverage; report in coverage/report.md
make fuzz                                  # fuzz specs with 40x the seeds, random start
```

- `make test` runs with a throwaway `XDG_DATA_HOME`, so tests never touch the
  real ID database or clock state. Run specs through `make`, not bare `nvim`.
- With more than one spec file, each file runs in its own Neovim, one per
  CPU (`ORG_TEST_JOBS=N` to change it, `ORG_TEST_JOBS=1` for one process),
  and a file is failed after `ORG_TEST_TIMEOUT` seconds (600). A spec can't
  rely on state left by an earlier file. `perf_budgets_spec.lua` runs
  last, alone; `ORG_TEST_PERF=0` skips it, `ORG_TEST_SHARD=i/n` runs one
  share of the files (CI runs perf in its own job and shards Windows).
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
- `make typecheck` runs lua-language-server (CI pins 3.19.1) over the
  repo with `.luarc.json`. Any warning or error fails it; the type-system
  checks the code isn't annotated well enough for yet (`need-check-nil`,
  `param-type-mismatch`, `undefined-field`, ...) are demoted to hints,
  except in the paths listed in `scripts/typecheck_strict.txt`
  (`lua/org/api/`, `parser.lua`, `element.lua`, `files.lua`, `date.lua`,
  `timestamps.lua`), where they fail it too. Fix a
  new warning (usually a wrong `---@param`/`---@return`, or a missing nil
  check) rather than silencing it. To make a module strict, add its path
  as one line there and fix what `make typecheck` reports; never remove
  a path to get a pass (CONTRIBUTING.md, "Strict paths").

## Layout

| Path | Contents |
| --- | --- |
| `lua/org/init.lua` | `setup()` entry point |
| `lua/org/config/` | every option and its default, one file per area (`init.lua`: `setup()` merging) |
| `lua/org/actions.lua` | registry of every user-facing operation |
| `lua/org/mappings.lua` | default keys, bound to actions |
| `lua/org/parser.lua`, `element.lua`, `files.lua` | parsing and the per-file cache |
| `lua/org/agenda/`, `babel/`, `capture/`, `export/`, `table/`, `ui/` | larger subsystems |
| `lua/org/fold.lua`, `fold/` | fold levels (`foldexpr` and its cache, a hot path) in `fold.lua`; visibility cycling and commands in `fold/` |
| `lua/org/structure.lua`, `structure/` | outline editing: shared helpers in the facade; heading insertion, templates, promote/demote, moves, kill ring and clone, sorting, narrowing, toggles, motions in the parts |
| `lua/org/links.lua`, `links/` | hyperlinks: the facade, and parse / search / open / shell / store / insert / commands parts |
| `lua/org/lists.lua`, `lists/` | plain lists: the item parser (a hot path) and shared helpers in the facade; list structures, statistics cookies, checkboxes, item editing, motions, bullets and conversions in the parts |
| `lua/org/ui/images.lua`, `ui/images/` | image and LaTeX previews: options, cell size and image files in the facade; element scan, image links, LaTeX rendering, backends, previews, native placement (redrawn every frame, a hot path) and commands in the parts |
| `lua/org/columns.lua`, `columns/` | column view: the format parser and property values in the facade; summaries, the columnview dynamic block, drawing, editing and opening the view in the parts |
| `lua/org/mobile.lua`, `mobile/` | MobileOrg sync: MD5, file helpers and encryption in the facade; index.org, agendas.org, push, pull edits, applying the inbox and flagged entries in the parts |
| `lua/org/export/element.lua`, `export/element/` | the export parser (port of org-element): node and text helpers in the facade; line classification, parser state, blocks, element parsers, lists, markup, links, objects, document and tree helpers in the parts |
| `lua/org/export/odt.lua`, `export/odt/` | ODT export: constants, per-export state and encoding in the facade; headlines, labels, media, LaTeX, source code, timestamps, transcoders, tables, template, back-end, packaging, conversion in the parts |
| `lua/org/api/` | the public Lua API (`:h org-api`); everything else is internal |
| `lua/org/pickers/` | picker sources and the snacks / fzf-lua / telescope / mini.pick / `vim.ui.select` adapters |
| `lua/org/extensions/` | optional extensions, each enabled under `extensions` in `setup()` |
| `lua/org/_meta/` | LuaLS type annotations for `setup()` options (no runtime code) |
| `plugin/`, `ftplugin/`, `syntax/` | Vim runtime files |
| `doc/org.txt` | the user manual (`:h org`); `doc/tags` is its helptags |
| `examples/` | per-feature tutorial `.org` files |
| `tests/run.lua`, `tests/minimal_init.lua` | the test runner and headless init |
| `tests/spec/*_spec.lua`, `tests/fixtures/` | specs and the fixture org files |
| `tests/screen.lua`, `tests/fixtures/screen/` | screen snapshot helper and its golden files |

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
- **Options live in `lua/org/config/`.** A new option needs a default in
  the file of its area there, an entry under `:h org-config` in
  `doc/org.txt`, and a type in `lua/org/_meta/`.
- **`org.api` is a public contract.** Other plugins and user configs call
  it, so follow `:h org-api-version`: an added function, field or event
  payload raises the minor `api.version`; nothing is removed or changed
  within a major version. Other `org.*` modules are internal.
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

Rendering (syntax, conceal, folds, extmark decorations, the agenda
buffer) is checked by screen snapshots: `tests/screen.lua` draws a buffer
in a child Neovim with a fixed-size UI and compares the text and highlight
groups on screen with `tests/fixtures/screen/<name>.txt`
(`tests/spec/screen_snapshot_spec.lua`; the format is in CONTRIBUTING.md).
A rendering bug fix gets a snapshot case. When a snapshot changes on
purpose, run `make snapshots` (`ORG_UPDATE_SNAPSHOTS=1`) and check the
golden file diff; never edit golden files by hand, and don't rewrite them
just to make a failing spec pass.

Fuzz specs (`tests/spec/fuzz_*_spec.lua`) take their seeds from
`tests/helpers/fuzz.lua`; a failure prints its seed, a `replay:` command and
the minimal failing input, which goes into `fuzz_regressions_spec.lua` with
the fix (CONTRIBUTING.md, "Fuzzing").

Every bug fix and feature gets a spec. Tests run headless, so anything that
prompts (`vim.fn.input`, `vim.ui.select`, confirms) has to be stubbed or
turned off, or the run will hang.

`tests/spec/perf_budgets_spec.lua` times pathological input
(`tests/helpers/gen.lua`) against budgets and checks that work grows
linearly; `ORG_PERF_SCALE` scales the budgets, `ORG_PERF_REPORT=1` prints
the timings (CONTRIBUTING.md, "Performance budgets"). Don't set 'lines' or
'columns' in specs: on nightly Neovim that trips grid assertions headless.

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
- Every PR description has an "In plain words" section: a few sentences
  for a reader who doesn't code, saying what was wrong or missing, what
  changes for them, and what they need to do (often nothing). No code,
  file names or jargon there; the technical detail goes in the other
  sections.
