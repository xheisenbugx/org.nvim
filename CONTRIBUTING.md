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
- **Improve the docs.** The README, `doc/org.txt`,
  `examples/tutorial.org` and the per-feature files in `examples/` are all
  fair game.
- **Build a feature.** The [Roadmap](README.md#-roadmap) lists what's
  missing. Check the issues first, or open one, so work isn't duplicated.

## Development setup

You only need Neovim 0.11+. For formatting and linting, you also need
[stylua](https://github.com/JohnnyMorganz/StyLua) 2.5.2, the version CI
checks with (`cargo install stylua --version 2.5.2`, or a release binary;
other versions can format differently).

```sh
git clone https://github.com/xheisenbugx/org.nvim && cd org.nvim
make test                                 # all specs, headless
make test SPEC=tests/spec/agenda_spec.lua # a single spec
ORG_TEST_JOBS=1 make test                 # all specs in one Neovim, one after another
make lint                                 # stylua --check + source lint rules
make format                               # format with stylua
git config blame.ignoreRevsFile .git-blame-ignore-revs  # blame past the formatting commit
```

`make test` runs each spec file in its own headless Neovim, as many at a
time as there are CPUs (`ORG_TEST_JOBS`), with its own throwaway
`XDG_DATA_HOME`. A file that runs longer than `ORG_TEST_TIMEOUT` seconds
(600) is killed and reported as failed.

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
- **Saving goes through `utils.save_buffer`, and write logic through
  `org.write_hooks`.** Org writes the files it edits in the background
  (refile, archive, capture, agenda edits, mobile, tangle, ...) with
  `utils.save_buffer`, which uses `:noautocmd write`, so a `BufWritePre`
  or `BufWritePost` autocommand never sees those saves. Code that must run
  around every write, by `:w` or by org, registers a write hook instead:

  ```lua
  require("org.write_hooks").register("my-ext", {
    order = 50,        -- pre hooks run lowest first, post hooks in reverse
    filetype = "org",  -- optional filter
    pre = function(bufnr, ctx)
      -- change the buffer before it's written; keep what post needs in
      -- ctx.state. Return false, "msg" (or throw) to veto: nothing is
      -- written, :w fails and save_buffer returns false, "msg".
    end,
    post = function(bufnr, ctx)
      -- ctx.ok: whether the file was written. Runs for every hook whose
      -- pre ran, also after a veto or a failed write: restore the buffer
      -- here (and its 'modified' flag).
    end,
  })
  ```

  `ctx.source` is `"write"` or `"save_buffer"`. Unregister in your
  extension's `teardown` with `require("org.write_hooks").unregister("my-ext")`.
  crypt (`encrypt_on_save`, order 50), transclusion (order 10) and roam
  (order 20) are the built-in users. Don't write org buffers yourself with
  `:write` from code: inside an autocommand or a `BufWriteCmd` the hooks
  don't run; call `utils.save_buffer` (or `save_buffer_or_warn`) and check
  its result.

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
5. Run `make format`, `make test` and `make lint`.

### Source lint rules

Besides stylua, `make lint` runs `scripts/lint_sources.lua` over `lua/`
(`tests/spec/lint_sources_spec.lua` runs it too). It reports
`file:line: rule: message` for bug classes that kept turning up in review:

| Rule | Flags | Do instead |
| --- | --- | --- |
| `expand` | `vim.fn.expand(x)` where `x` isn't a string literal. Vim expansion runs `` `backticks` `` as shell commands and globs, and paths often come from the document. | `utils.expand_vars(x)` (only `~` and `$VAR`) or `utils.expand(x, base)` |
| `gsub` | `s:gsub(pat, repl)` / `string.gsub` where `repl` is a variable or a concatenation: a `%` in a path, label or user text is read as a capture. | a literal, a function, a table, or `utils.gsub_escape(value)` |
| `keyword-span` | a value captured from a `#+KEY: value` line located again with `line:find(value)` from the start of the line, which finds `#+name: name` inside the keyword. | capture the column in the same match: `line:match("^#%+name:%s*()(.-)$")` |

When a hit is audited and safe (a config option, a number, a constant),
allow it with a comment on the same line or the line above, and say why:

```lua
-- lint: allow expand: the jar_path option, not document text
local jar = vim.fn.expand(o.jar_path)
```

An allow comment without a reason, or one that no longer allows anything,
is reported too.

## Comparing with Emacs

org.nvim aims to behave like Emacs Org 9.8.10. Besides the hand-written
`*_emacs_spec.lua` and `*_parity_spec.lua` specs, these specs compare
org.nvim with real Emacs output that's checked in under
`tests/fixtures/emacs/`:

| Spec | Compares |
| --- | --- |
| `emacs_visibility_parity_spec.lua` | startup visibility and TAB/S-TAB |
| `emacs_agenda_parity_spec.lua` | agenda views |
| `emacs_export_parity_spec.lua` | exports of `examples/*.org` |
| `emacs_clocktable_parity_spec.lua` | clock tables |
| `emacs_lint_parity_spec.lua` | org-lint reports |

They only read the fixtures, so you don't need Emacs to run them. To
regenerate the fixtures after you change an input or add a case, you need
Emacs with Org 9.8.10:

```sh
ORG_DIR=/path/to/org-9.8.10 make parity-fixtures   # or AREAS="agenda lint"
git diff tests/fixtures/emacs                      # review what Emacs changed
```

[`scripts/emacs-parity/README.md`](scripts/emacs-parity/README.md)
explains how to add cases, how the runs are kept deterministic (a fixed
"now", time zone and locale), and what to do when a comparison fails:
fix the bug, document an intended difference, or mark the case as a known
failure.

## Fuzz tests

The `tests/spec/fuzz_*_spec.lua` specs run the parser, the fold levels,
editing commands and the merge driver on random Org text from
[`tests/helpers/fuzz.lua`](tests/helpers/fuzz.lua), a seeded generator you
can reuse in new specs. `make test` runs a few fixed seeds. To look for
bugs, run many more, or replay the seed a failure names:

```sh
ORG_FUZZ_ITERATIONS=5000 make test SPEC="tests/spec/fuzz_parser_spec.lua tests/spec/fuzz_ops_spec.lua tests/spec/fuzz_merge_spec.lua"
ORG_FUZZ_SEED=640 make test SPEC=tests/spec/fuzz_ops_spec.lua
```

A failure prints the input as a Lua table. Cut it down to the few lines
that still fail and add it to `tests/spec/fuzz_regressions_spec.lua` with
the fix.

## Pull requests

- Keep each PR focused on one change. Small PRs get reviewed faster.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for
  titles, as the history does: `feat(agenda): …`, `fix(capture): …`,
  `docs: …`.
- Describe how you tested the change. For UI changes, a screenshot or
  short recording helps a lot.
- Keep org.nvim dependency-free. Optional integrations such as blink.cmp or
  lualine are fine, as long as they're loaded only when the user has them.

## Branches, CI and releases

- `dev` is the development branch: open every pull request against `dev`.
- `main` only takes pull requests from `release/vX.Y.Z` branches. A
  `release branch` check fails any other pull request into `main`.
- Pull requests into `dev` and `main` run `make test` on Ubuntu against
  Neovim v0.11.0, stable and nightly (nightly may fail without blocking),
  and on macOS against stable. CI also checks that `doc/tags` is up to date;
  after editing `doc/org.txt`, run
  `nvim --headless -u NONE -c "helptags doc" -c q`. Pushes don't run CI.

To release, branch from `dev` and open a pull request into `main`:

```sh
git switch -c release/v0.2.0 origin/dev
git push -u origin release/v0.2.0
gh pr create --base main --title "release: v0.2.0"
```

Merging it tags `v0.2.0` and publishes the GitHub release, with notes
generated from the pull requests merged since the last tag. The tag goes on
the release branch's last commit, so `dev` reaches it as well as `main`.
There is no version number in the code: `:Org version` reports the latest
`vX.Y.Z` tag of the checkout. Merge release PRs with a merge commit, not a
squash, so that commit is part of `main`. If you commit a fix to the
release branch itself, merge the release branch back into `dev` too. Pick the version with [semver](https://semver.org): before 1.0, a
`feat` or a breaking change bumps the minor version, fixes bump the patch.

Thanks again, and happy hacking! 🦄
