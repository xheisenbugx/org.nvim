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
ORG_TEST_PERF=0 make test                 # all specs but the timed ones (a quicker run)
make lint                                 # stylua --check + source lint rules
make format                               # format with stylua
make typecheck                            # lua-language-server --check
make coverage                             # specs with line coverage of lua/org
make fuzz                                 # the fuzz specs with many more seeds
git config blame.ignoreRevsFile .git-blame-ignore-revs  # blame past the formatting commit
```

`make test` runs each spec file in its own headless Neovim, as many at a
time as there are CPUs (`ORG_TEST_JOBS`), with its own throwaway
`XDG_DATA_HOME`. A file that runs longer than `ORG_TEST_TIMEOUT` seconds
(600) is killed and reported as failed. The timed specs
(`perf_budgets_spec.lua`) start after every other file has finished and
run alone, so no other spec competes with them for the CPUs;
`ORG_TEST_PERF=0` leaves them out (CI runs them in a job of their own).
`ORG_TEST_SHARD=i/n` runs the i-th of n shares of the files, split by size
(CI spreads the slow Windows run over three runners). The run ends with
the five slowest files.

`make coverage` runs the same specs with line coverage of `lua/org`
(`SPEC=` works too). A line hook in `tests/coverage.lua`, loaded only
then, counts the lines each test Neovim runs (with the JIT off, so it's a
few times slower), and `scripts/coverage_report.lua` merges the counts
into `coverage/`: `report.md` lists every module, lowest coverage first,
`summary.md` has the totals and the 20 lowest, and `missed.txt` the line
ranges no spec runs, a list of what to test next. Nothing extra to
install, and nothing of it reaches plugin users. The Coverage workflow
runs it weekly (and from the Actions tab), uploads `coverage/` as an
artifact and puts the summary on the run's page; it never runs on pull
requests.

To try your checkout in your own config, point lazy.nvim at it:

```lua
{ dir = "~/path/to/org.nvim", name = "org.nvim", main = "org", lazy = false, opts = {} }
```

## How the code is organised

| Path | Contents |
| --- | --- |
| `lua/org/` | core: `parser`, `date`, `edit`, `files`, `config`, `actions`, `context`, `mappings` |
| `lua/org/{structure,fold,lists}.lua`, `lua/org/structure/` | outline editing |
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
  [`lua/org/config/`](lua/org/config), one file per area (agenda, export,
  babel, ...). Add new options to the file of their area and document them
  in `:h org-config`.
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
5. Run `make format`, `make test` and `make lint` (and `make typecheck`
   if you have lua-language-server).

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

### Type check

`make typecheck` runs [lua-language-server](https://github.com/LuaLS/lua-language-server)
`--check` over the repository with the settings of `.luarc.json` (LuaJIT,
the Neovim runtime of `nvim`'s `$VIMRUNTIME`, the spec harness's globals),
which editors using LuaLS pick up too. CI runs it with lua-language-server
3.19.1. Every warning or error fails the check: a call with more or fewer
arguments than the function takes, a `---@return` that disagrees with what
the function returns, an annotation LuaLS can't parse, an unknown global.
The checks that need fuller annotations than the code has today
(`need-check-nil`, `param-type-mismatch`, `assign-type-mismatch`,
`cast-local-type`, `undefined-field`, `inject-field`,
`duplicate-set-field`, and `deprecated`, since org.nvim keeps fallbacks
for Neovim 0.11) are hints: your editor shows them, the check ignores
them. Fix what the check reports, usually the annotation, instead of
silencing it.

### Fuzzing

The fuzz specs (`tests/spec/fuzz_*_spec.lua`) generate random Org text
from numbered seeds (`tests/helpers/fuzz.lua`) and check what must hold for
any input: the parser's outline invariants, the incremental fold levels,
editing commands raising no Lua error and undoing cleanly, the structural
merge keeping one-sided changes. The generator is seeded and can be reused
in new specs. `make test` runs a few fixed seeds of each.
More seeds come from the environment:

| Variable | Effect |
| --- | --- |
| `ORG_FUZZ_SEED=N` | only seed `N` (replays a failure) |
| `ORG_FUZZ_ITERATIONS=N` | `N` seeds per spec instead of its default |
| `ORG_FUZZ_SCALE=K` | `K` times each spec's default |
| `ORG_FUZZ_START=S` | start at seed `S` instead of 1 |

`make fuzz` runs the fuzz specs with `ORG_FUZZ_SCALE=40` from a random
first seed (both can be set: `make fuzz ORG_FUZZ_SCALE=100
ORG_FUZZ_START=1`). The Fuzz workflow runs it every night and from the
Actions tab; when it fails, it opens an issue labelled `fuzz`, or comments
on the open one, with the failures.

A failure names its seed, the command that replays it, the generated
input and, when shrinking found one, the minimal input that still fails
the same way (for the editing commands also the minimal step: command,
line and column):

```
seed 4711: element.at(3): attempt to index a nil value
replay: ORG_FUZZ_SEED=4711 make test SPEC=tests/spec/fuzz_parser_spec.lua
input = { ... }
minimal input = {
  "* a",
  "#+begin_src",
}
```

To turn it into a regression case:

1. Replay the seed and check you get the same failure.
2. Copy the minimal input into a new `it` of
   `tests/spec/fuzz_regressions_spec.lua` that checks the expected behaviour
   directly (what Emacs does with that text, or simply that no error is
   raised), as the cases already there do. It should fail.
3. Fix the bug; the new case and the replayed seed now pass. Commit the
   case with the fix.

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

## Screen snapshots

Some bugs only show on screen: headline stars drawn as bold markup, a
folded headline losing the color of its TODO keyword, highlighting that
stops after a very long line. `tests/spec/screen_snapshot_spec.lua` catches
those. [`tests/screen.lua`](tests/screen.lua) opens an Org file in a child
Neovim with a fixed-size screen, attached as a UI over RPC, and writes down
what is drawn: the text, with concealing, folds and virtual text as they
appear, and the highlight group of each run of cells. The result is
compared with a golden file in `tests/fixtures/screen/`:

```
screen 60x12
|{1:* }{2:TODO}{1: }{3:[#A]}{1: Level one }{4::work:}|
|Body text of level one.|

{1} OrgHeadlineLevel1 -> Title [bold]
{2} OrgTodo -> @comment.error
{3} OrgPriorityA -> DiagnosticError
{4} OrgTags -> @property
```

Each screen row is between `|`s, and `{N:text}` is text drawn with
highlight `N`. The legend names the group, the links it has up to the first
group that isn't Org's, and the style (bold, italic, underline, ...).
Colors are left out, so the snapshots don't depend on the colorscheme. A
cell drawn with several groups, such as a folded headline's keyword, lists
them as `Folded | OrgTodo -> @comment.error`.

A failing snapshot prints a diff of the golden file and the screen. If the
change is what you meant, rewrite the golden files and review the result
before committing it:

```sh
make snapshots                     # ORG_UPDATE_SNAPSHOTS=1 for the snapshot spec
git diff tests/fixtures/screen     # check that only what you meant changed
```

A new case is a few lines:

```lua
local Screen = require("tests.screen")
local screen = Screen.new({ width = 60, height = 12, setup = { ui = { hide_emphasis_markers = true } } })
screen:org({ "*** *bold* title" })  -- opens it as a file, like a user would
screen:cmd("normal! zM")            -- or screen:lua(code), screen:input(keys)
screen:expect("my_case")            -- tests/fixtures/screen/my_case.txt
screen:close()                      -- in an after_each, so a failure closes it too
```

`setup` goes to `require("org").setup()`, and `now = { year = 2026, month
= 10, day = 2, hour = 10, min = 0 }` fixes the date for an agenda. Run
`make snapshots` once to create the golden file. Every wait on the child
gives up after `ORG_SCREEN_TIMEOUT` ms (10000), so a prompt in the child
fails the spec instead of hanging it.

## Documentation website

The website at <https://org-nvim.com/> is generated, never
edited by hand: [`scripts/site/build.lua`](scripts/site/build.lua) turns
`doc/org.txt` into one page per chapter (help tags become anchors, `|links|`
hyperlinks and `>lua` blocks highlighted code), renders `README.md` and
`docs/parity-review.md`, scores `docs/parity/inventory.tsv`, and exports
every `examples/*.org` with org.nvim's own HTML exporter. Build it with
nothing but Neovim:

```sh
make site                # into site/ (not committed); open site/index.html
```

The build checks every internal link, `#anchor` and search entry, and
fails on a broken one or on a `|tag|` that is neither an org.nvim nor a
Neovim help tag. `tests/spec/site_spec.lua` runs it too. The look and the
search live in `scripts/site/assets/`.

Pull requests that change the sources run the `Pages` workflow, which only
builds the site. Publishing a release deploys it to GitHub Pages (a
maintainer can also run the workflow by hand from the Actions tab).

## Performance budgets

`tests/spec/perf_budgets_spec.lua` times org.nvim on pathological input
from [`tests/helpers/gen.lua`](tests/helpers/gen.lua): lines of 10,000 to
100,000 characters (prose, dense markup, unclosed markers, a hash),
headlines 60 levels deep, 40-deep lists, nested blocks, 10,000 headlines
with planning, properties and clocks, a 2,000 × 20 table, a 100,000-line
file, thousands of links and footnotes. It checks two kinds of limits:

- **Budgets**: an operation (opening a file, drawing a long line, typing,
  TODO cycling, promoting a subtree, `zM`/`zR`, an agenda view, a lint)
  must finish within about 10× what it takes on a laptop, so slow shared
  CI runners pass.
- **Growth**: the same work at size N and 4N, in processor time; 4N may
  take at most 10× as long. A linear algorithm (4×, up to 7× when it
  allocates a lot) passes on any machine, a quadratic one (16×) fails,
  without depending on how fast the runner is. Work whose input can't
  grow that much (a line within `'synmaxcol'`) is checked at 2N against
  3×.

It also checks outcomes: no E363 or "'redrawtime' exceeded" message
(either turns syntax highlighting off), the lines after a long line still
highlighted, fold levels equal to a full recompute.

```sh
ORG_PERF_REPORT=1 make test SPEC=tests/spec/perf_budgets_spec.lua  # print every timing
ORG_PERF_SCALE=3 make test SPEC=tests/spec/perf_budgets_spec.lua   # 3x the budgets (slow machine)
ORG_PERF_SCALE=0.2 make test SPEC=tests/spec/perf_budgets_spec.lua # strict, to hunt a regression
```

When a budget fails, profile the operation with `require("jit.p")`
(`jit.p.start("Fl3", "/tmp/prof.txt")` … `jit.p.stop()`) and look for
work repeated per line, per headline or per object. For syntax, `:syntime
on`, redraw, then `:syntime report` names the slow patterns. What the
first pass over this input found (Neovim 0.12.5 on a laptop):

| Input | Before | After | Cause |
| --- | --- | --- | --- |
| drawing a 3,000-character line of markup | 123 ms | 14 ms | the list term look-behind ran from every column |
| drawing a 30,000-character line of markup | syntax off ("redrawtime") | 14 ms | the same, and emphasis looked for its end past 'synmaxcol' |
| drawing a 1,000-character headline | E363, syntax off | 6 ms | the ARCHIVE pattern on the NFA engine |
| drawing a table with a 20,000-character cell | E363, syntax off | 86 ms | table formula look-behinds |
| lint, a file of 100,000-character lines | 2.2 s | 0.13 s | emphasis and link types searched to the paragraph end |
| export to Markdown, 10,000 headlines | 453 s | 2.8 s | a whole-tree walk per headline |
| export to HTML, 2,500 footnotes | 34 s | 0.3 s | a whole-tree walk per footnote reference |
| decorations, a 40,000-character hash | 8 s | 34 ms | a backtracking Lua pattern |

The syntax patterns use the backtracking engine (`\%#=1`) where the NFA
engine runs out of 'maxmempattern' on long lines. Note that the
backtracking engine matches what follows a look-behind (`\@<=`, `\@<!`)
before the look-behind itself, from every column of the line, and the
look-behind then goes back to the start of the line: make what follows it
fail fast (a literal character), keep `.*` out of look-behinds (`.\{-}`
stops where the look-behind ends), or use `lc=N` for a fixed leading
context.

## Pull requests

- Keep each PR focused on one change. Small PRs get reviewed faster.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for
  titles, as the history does: `feat(agenda): …`, `fix(capture): …`,
  `docs: …`.
- Describe how you tested the change. For UI changes, a screenshot or
  short recording helps a lot.
- Add an "In plain words" section to the description: a few sentences,
  without code or jargon, that anyone using org.nvim can follow. Say what
  was wrong or missing, what changes for them, and whether they need to do
  anything.
- Keep org.nvim dependency-free. Optional integrations such as blink.cmp or
  lualine are fine, as long as they're loaded only when the user has them.

## Branches, CI and releases

- `dev` is the development branch: open every pull request against `dev`.
- `main` only takes pull requests from `release/vX.Y.Z` branches. A
  `release branch` check fails any other pull request into `main`.
- Pull requests into `dev` and `main` run `make test` on Ubuntu against
  Neovim v0.11.0, stable and nightly (nightly may fail without blocking),
  and on macOS and Windows against stable, plus stylua, `make typecheck`
  and a helptags check; after editing `doc/org.txt`, run
  `nvim --headless -u NONE -c "helptags doc" -c q`. A pull request that
  changes the docs also builds the website. Pushes don't run CI.
- The Fuzz (nightly) and Coverage (weekly) workflows test `dev`. GitHub
  starts scheduled workflows from the default branch, `main`, so a change
  to them takes effect with the next release; both can also be run from
  the Actions tab, on any branch.

To release, branch from `dev`, update the changelog and open a pull
request into `main`:

```sh
git switch -c release/v0.2.0 origin/dev
make changelog                            # adds the ## [v0.2.0] section
git commit -am "release: CHANGELOG for v0.2.0"
git push -u origin release/v0.2.0
gh pr create --base main --title "release: v0.2.0"
```

[`CHANGELOG.md`](CHANGELOG.md) is generated from the history by
`scripts/changelog.lua`: one entry per pull request merged into `dev`, by
its title, grouped by Conventional Commits type, with breaking changes
(`feat!:` or a `BREAKING CHANGE:` footer) first. On a `release/vX.Y.Z`
branch, `make changelog` files the pull requests since the latest tag under
`vX.Y.Z`; elsewhere they go under Unreleased (or pass `VERSION=vX.Y.Z`).
Entries come from the merge commits, so a good pull request title is a
good changelog entry; `make changelog` rewrites the whole file, so don't
edit it by hand. The `release branch` check fails until `CHANGELOG.md` has
a `## [vX.Y.Z]` section.

Merging it tags `v0.2.0` and publishes the GitHub release. The release
notes are the `v0.2.0` section of `CHANGELOG.md`, plus a link to the full
diff (GitHub's generated notes, grouped by `.github/release.yml`, only when
the section is empty), and deploys the documentation website built from
that tag. The tag goes on the release branch's last commit.
There is no version number in the code: `:Org version` reports the latest
`vX.Y.Z` tag of the checkout. Merge release PRs with a merge commit, not a
squash, so that commit is part of `main`. Afterwards, merge the release
branch back into `dev` (a pull request from `release/v0.2.0` into `dev`),
so `dev` gets the changelog and reaches the tag; do the same for any fix
committed to the release branch itself. Pick the version with
[semver](https://semver.org): a breaking change (`feat!:` or a
`BREAKING CHANGE:` footer, listed first in the changelog) bumps the major
version, a `feat` the minor version, and fixes the patch.

Thanks again, and happy hacking! 🦄
