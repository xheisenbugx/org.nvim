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
- **Improve the docs.** The README, the [guide](docs/guide.md), `doc/org.txt`,
  `examples/tutorial.org` and the per-feature files in `examples/` are all
  fair game.
- **Build a feature.** The [Roadmap](docs/guide.md#-roadmap) lists what's
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
make coverage-check                       # coverage/ against scripts/coverage_floor.txt
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

#### Flaky specs

`tests/quarantine.lua` lists the spec files known to fail now and then
for reasons outside the change under test (a slow runner, a race with a
child Neovim), each with its reason and, optionally, the one OS it flakes
on. With `ORG_TEST_RERUN_QUARANTINED=1`, which CI sets, a listed file that
fails runs once more in a fresh Neovim: if that run passes, the file is
reported as `FLAKY:` (with the first run's failures, and a warning on the
CI run's page) and doesn't fail the run; if it fails again, a
`QUARANTINED:` line says so and its failures count. Files not on the list
never get a second run, so a flake can't hide a real failure, and a real
breakage of a listed file still fails, twice. Add a file only once CI
history shows it failing on unrelated changes, and take it out once the
flake is fixed; `ORG_TEST_QUARANTINE=a_spec.lua,b_spec.lua` quarantines
files for one run. `tests/spec/test_runner_quarantine_spec.lua` tests the
runner's side of it.

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

#### Coverage floors

`scripts/coverage_floor.txt` gives each strict path (those of
`scripts/typecheck_strict.txt`, a file or a directory) a floor in percent,
and `make coverage-check` (`scripts/coverage_floor.lua`) fails when the
line coverage of a path in `coverage/coverage.json` is below its floor, or
when a path matches no file any more. The Coverage workflow runs it after
`make coverage` and fails the run when a path dropped. The check only
means something after a full run: with `SPEC=` most paths fall short.
After a full `make coverage`, `make coverage-check ARGS=--update` resets
every floor to the path's coverage rounded down, less one point (the slack
for lines that only run on some runs); do that to raise the floors when
coverage went up, or to give a new strict path its floor. Don't lower a
floor just to make the check pass: add the specs, or say in the pull
request why the code can't be covered.

To try your checkout in your own config, point lazy.nvim at it:

```lua
{ dir = "~/path/to/org.nvim", name = "org.nvim", main = "org", lazy = false, opts = {} }
```

## How the code is organised

| Path | Contents |
| --- | --- |
| `lua/org/` | core: `parser`, `date`, `edit`, `files`, `config`, `actions`, `context`, `mappings` |
| `lua/org/{structure,fold,lists}.lua`, `lua/org/structure/`, `lua/org/fold/`, `lua/org/lists/` | outline editing, folding and visibility cycling |
| `lua/org/{todo,priority,tags,properties,timestamps,calendar,clock,dblock,columns,timer}.lua` | task management |
| `lua/org/clock/` | the parts `clock.lua` loads: clocking in and out, clock tables, resolving, timers, display |
| `lua/org/columns/` | the parts `columns.lua` loads: summaries, the columnview dynamic block, drawing, editing and opening the column view |
| `lua/org/mobile.lua`, `lua/org/mobile/` | MobileOrg sync (`mobile.lua` holds MD5, file helpers and encryption and loads index, agenda, push, pull and flagged parts) |
| `lua/org/agenda/` | agenda, search, sparse trees, notifications |
| `lua/org/{capture,refile,archive,links,id,attach,footnotes}.lua`, `lua/org/capture/`, `lua/org/links/` | capture and navigation (links.lua is the facade; links/ holds parsing, search, opening, storing, inserting) |
| `lua/org/table.lua`, `lua/org/table/` | tables and formulas (`table.lua` parses and aligns and loads the commands from `table/`; `table/calc_alg.lua`, the Calc's symbolic algebra, loads its parts from `table/calc_alg/`) |
| `lua/org/babel/` | source blocks |
| `lua/org/export/`, `lua/org/export/{ox,odt,latex,html,ascii,element}/` | exporters (`ox.lua`, `odt.lua`, `latex.lua`, `html.lua`, `ascii.lua` and `element.lua`, the export parser, are facades that load their parts from `ox/`, `odt/`, `latex/`, `html/`, `ascii/` and `element/`) |
| `syntax/`, `lua/org/{syntax,highlights}.lua`, `lua/org/ui/` | highlighting and decorations: the highlighter is `ui/highlight/` and `ui/emphasis.lua`, drawn by the decoration provider in `ui/decorations.lua`; `syntax.lua` only includes the Vim syntax of src block languages; `ui/images.lua` loads its parts from `ui/images/` |
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

4. Document it in `doc/org.txt` (and in the README or `docs/guide.md` if
   it's user-visible).
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
them, except in the strict paths below. Fix what the check reports,
usually the annotation, instead of silencing it.

#### Strict paths

The files and directories listed in `scripts/typecheck_strict.txt`
(`lua/org/api/`, the parser and the core modules around it, structure,
lists, clock, agenda, table, babel, capture, links, columns, mobile,
export, pickers, health, folding, the UI, config migration, file reload
and every extension) are held to those hint checks too: in them, a `need-check-nil` or a `param-type-mismatch` fails
`make typecheck` like any other warning, so code that is already clean
can't slip back. `make typecheck` runs `scripts/typecheck.lua`, which does
one lua-language-server pass over the whole repository with the hint
checks raised to warnings and then drops them outside the listed paths.
The listed files are checked with every module they require loaded, and
only their own diagnostics count, not those of the modules they require.

To make another module strict, add its path (a file, or a directory for
everything under it) on a line of its own in `scripts/typecheck_strict.txt`,
run `make typecheck` and fix what it reports. Prefer a correct
`---@param`/`---@return`/`---@class`, a `---@type` on a local, or a real
nil check (an `assert` where the value can't be nil) over
`---@diagnostic disable`; a disable that stays needs a comment saying why.
Don't take a path off the list to make the check pass.

### Health checks

`:checkhealth org` (`lua/org/health/init.lua`, `:h org-health`) is what a
user runs first when something doesn't work, and what a bug report
includes. A feature that needs an external program, a path or a file of
its own adds a check there, in the section it belongs to (or an
extension's `health(h, opts)` function, which `org.extensions.check` calls
under the extension's name). Checks must be fast and never prompt: look
for programs with `vim.fn.executable()` rather than running them, bound any
file scan, no network. Report only through the `h` reporter: nothing a
check calls may notify, so resolve the picker with `pickers.resolve()`
(which returns the fallback's reason) rather than `pickers.backend()`
(which warns). Warn only when the feature is turned on (a missing
`gpg` is a warning with `crypt.encrypt_on_save`, an info line otherwise),
and say what to do and which option or `:h` tag to read in the advice
(write `see :h tag` at the end: a `)` right after the tag ends up in the
link). Each check is a function taking `vim.health`, so
`tests/spec/health_spec.lua` can run it with a stub and stubbed
executables; document it under `:h org-health`.

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

org.nvim aims to behave like Emacs Org 9.8.12. Besides the hand-written
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
Emacs with Org 9.8.12:

```sh
ORG_DIR=/path/to/org-9.8.12 make parity-fixtures   # or AREAS="agenda lint"
git diff tests/fixtures/emacs                      # review what Emacs changed
```

[`scripts/emacs-parity/README.md`](scripts/emacs-parity/README.md)
explains how to add cases, how the runs are kept deterministic (a fixed
"now", time zone and locale), and what to do when a comparison fails:
fix the bug, document an intended difference, or mark the case as a known
failure.

### Differential testing

`make difftest` goes further than the fixed fixtures: it generates random
Org documents (`tests/difftest/gen.lua`: headlines with TODO keywords,
priorities, tags and COMMENT, planning with repeaters and warnings,
drawers and clocks, lists with checkboxes and counters, tables with
`#+TBLFM`, footnotes, blocks, links, emphasis edge cases, inline tasks),
runs each through Emacs Org 9.8.12 and org.nvim, and compares what a set of
"oracles" print:

| Oracle | Compares |
| --- | --- |
| `export-html`, `export-ascii`, `export-md`, `export-latex`, `export-org` | the body-only export, Babel off |
| `agenda` | week and day agendas, the TODO list, a tags and a tags-todo match over the file |
| `table` | the file after recalculating every table that has a `#+TBLFM` line |
| `visibility` | the visible lines at startup and after each of three S-TABs |
| `commands` | the buffer after each step of one to three editing commands, picked from the seed |

The `commands` oracle (`tests/difftest/commands.lua`) replays editing
commands on the document: promoting, demoting and moving subtrees, `C-c
C-t` (also with `org-log-done` set to `time`), priority up and down,
clocking in and out (at the frozen "now"), toggling a checkbox (statistics
cookies updated), `S-up` / `S-down` on a timestamp's day, sorting entries
alphabetically, `C-RET`, archiving to the Archive sibling and refiling to
another headline of the file. Each step targets the k-th headline,
checkbox item or timestamp of the buffer as it is at that step, so a
shrunk document still replays the same steps; Emacs runs the interactive
commands (`org-promote-subtree`, `org-todo`, `org-clock-in`, ...) and
org.nvim the matching actions of `lua/org/actions.lua`, both with the
document unfolded and inline tasks on. The report shows the steps of a
failure next to its replay command.

It needs Emacs and Org 9.8.12 (see `scripts/emacs-parity/README.md`):

```sh
export ORG_EMACS=emacs ORG_LISP_DIR=/path/to/org-9.8.12
make difftest                                    # 100 documents, random seed
make difftest SEED=1 COUNT=300                   # a reproducible run
make difftest SEED=42 COUNT=1 ORACLES=export-md  # replay one failure
```

Outputs are compared after the `NORMALISE` rules of
`tests/emacs_parity.lua`, as a line diff. A hunk that matches an entry of
`tests/difftest/known.lua` (a known bug, not fixed yet: patterns on either
side of the hunk or on the input, or a rewrite that makes both sides
equal) is counted but doesn't fail the run; any other one does. Failures are grouped by what
differs, and the first of each group is shrunk (whole subtrees, then lines,
then words) to a small input that still differs (the first 20 kinds,
`DIFFTEST_MINIMISE`; the others keep their whole input). `difftest-out/report.md`
lists them with the seed, the replay command, the minimal input and the
diff (`-` Emacs, `+` org.nvim); `difftest-out/repros/` has each input and
diff as files. The output directory (`DIFFTEST_OUT`) is emptied first, so
it must be empty or hold the `.difftest-out` file of an earlier run.
Emacs and org.nvim work in parallel (`DIFFTEST_JOBS` Emacs workers,
default one per CPU up to 8); a request Emacs doesn't answer in 20
seconds counts as an Emacs error, like any input Emacs raises an error on.
An error in one agenda view, S-TAB step, table or command step leaves only that part
out of the comparison; an error in an export leaves out the whole output.
When Emacs errors or times out on more than a tenth of the comparisons
(and more than two), or on every comparison of an oracle, the Emacs side
is taken as broken: the run is an infrastructure failure and the script
exits with 2, where an unknown difference exits with 1 (`make` reports
both as its own status 2).

400 documents take about a minute and a half on four Emacs workers. The
Difftest workflow runs 400 documents every night on `dev` and from the
Actions tab (seed, count and oracles as inputs). When it finds unknown
differences it uploads the report and repros as an artifact and opens an
issue labelled `difftest`, or comments on the open one when the kinds of
failure changed since its last report; an infrastructure failure only
fails the job. To handle a failure:

1. Replay it, and check what Emacs does with the minimal input (the Org
   source).
2. Fix org.nvim, and turn the minimal input into a case of the area's
   `*_emacs_spec.lua`.
3. Or, if it's intentional, document it under `:h org-differences` and add
   a rule to `NORMALISE`; if it's a bug to fix later, add a narrow entry
   to `tests/difftest/known.lua` with the reason, so the nightly run stays
   green until the fix removes it.

`tests/spec/difftest_spec.lua` runs the org.nvim side, the comparison and
the shrinking against a fake Emacs, so pull request CI covers that code
without Emacs.

### Watching for Org releases

org.nvim is measured against one Org release, pinned by `ORG_VERSION` in
`.github/workflows/difftest.yml` (9.8.12; `scripts/emacs-parity/common.el`
and `docs/parity/inventory.el` name it too). Every Monday the Org releases
workflow (`.github/workflows/org-release.yml`, also runnable from the
Actions tab) looks up the latest release, the highest of GNU ELPA's `org`
package and the `release_*` tags of the org-mode git repository. When it
is newer than the pinned one, it lists the commands, options, Babel
executors, link types and export transcoders of both releases with
`docs/parity/inventory.el` and opens an issue labelled `org-release` with
the version and the diff: items added, removed or moved to another
library, and the ones `docs/parity/inventory.tsv` doesn't list yet. While that
issue is open, later runs update it (for a still newer release too) instead of opening
another; once it's closed, the same release isn't reported again. The
workflow can only read the repository and write issues.

[`scripts/emacs-parity/release-watch.sh`](scripts/emacs-parity/release-watch.sh)
does the work, and runs locally too (it needs `curl`, `git`, Emacs and
`make`; the issue step needs `gh`, and `DRY_RUN=1` only prints it):

```sh
w=scripts/emacs-parity/release-watch.sh
$w pinned; $w latest                                    # 9.8.12, the newest
$w inventory 9.8.11 out/old && $w inventory 9.8.12 out/new
$w report out/old out/new 9.8.11 9.8.12 > report.md     # the issue body
$w fetch 9.8.12 ~/org-lisp                              # ~/org-lisp/org-9.8.12
```

A release only tagged in git (GNU ELPA publishes its tarball a little
later) is fetched with `git clone` and `make autoloads`. To move to a new
release: bump `ORG_VERSION`, `ORG_VERSION` in `lua/org/health/init.lua`
and the version check in `scripts/emacs-parity/common.el` (`health_spec`
checks the three agree), regenerate the fixtures (`make parity-fixtures`),
give each new item a status in `docs/parity/inventory.tsv`,
run `make difftest` against it, and close the issue. The workflow lists
commands with Emacs 30.1, so a compat alias of a command Emacs itself
defines (`org-replace-buffer-contents`) can show up there but not with a
newer Emacs: give it a status too.

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

## Verifying in a running Neovim

Specs stub prompts and call functions directly, so they can pass while the
path a user takes is broken: a key that doesn't reach the action, a capture
that files the entry one level too deep, an agenda edit that never reaches
the file. `make verify` checks that path.
[`scripts/verify/drive.lua`](scripts/verify/drive.lua) plays the scenarios
of `scripts/verify/recipes/<area>.lua` in a child Neovim (the screen
snapshots' one, `tests/screen.lua`). It types keys, reads the screen and
the files on disk, and fails a step when what it expects doesn't happen or
the step leaves an error:

```lua
{
  name = "a note goes under its headline",
  files = { ["notes.org"] = { "* Notes", "* Other" } },
  setup = setup, -- capture.templates with n = { ..., target = "{{dir}}/notes.org", headline = "Notes" }
  steps = {
    { key = "{{global.capture}}n", expect = { mode = "i" } },
    { type = "Parking is on level 3" },
    { key = "<Esc>{{capture.finalize}}" },
    { expect = { file = { "notes.org", lines = { "* Notes", "** Parking is on level 3", "* Other" } } } },
  },
}
```

Keys are written as `{{section.name}}` and resolved to the default
mapping, as in the tutor lessons. Each scenario gets HOME and XDG
directories of its own, and the clock is fixed at Monday 2026-10-12 09:00.

```sh
make verify                    # every recipe
make verify RECIPE=capture     # one (or several, space-separated; recipe:scenario-prefix for one scenario)
```

The output names a directory of evidence: the screen as text after every
step, and `report.md`. `tests/spec/verify_spec.lua` runs every recipe, so a
scenario keeps guarding what it checked.

The recipes go with a feature map for coding agents,
[`.claude/skills/verify-org/`](.claude/skills/verify-org/SKILL.md). It has
one file per area: how a user reaches the feature, what each step should
show, the gotchas, and where the code, specs, help and Emacs source are.
The spec checks each file's header against the code. Agents load it as a
skill, and the files are plain markdown that a person can read too. When
you change a mapped area, update its scenarios and feature file with it.

## Documentation website

The website at <https://org-nvim.com/> is generated, never
edited by hand: [`scripts/site/build.lua`](scripts/site/build.lua) turns
`doc/org.txt` into one page per chapter (help tags become anchors, `|links|`
hyperlinks and `>lua` blocks highlighted code), renders `README.md`,
`docs/guide.md` (the setup and reference guide: installation, keys,
options, integrations, extensions, roadmap) and `docs/parity-review.md`, scores `docs/parity/inventory.tsv`, lists the
known differences from Emacs (the items of `:h org-differences`), publishes
the extension promotion report (`scripts/extension_report.lua`, required as
a module) as the "Extensions status" page, and exports every
`examples/*.org` with org.nvim's own HTML exporter. Build it with nothing
but Neovim:

```sh
make site                # into site/ (not committed); open site/index.html
```

The build checks every internal link, `#anchor` and search entry, and
fails on a broken one or on a `|tag|` that is neither an org.nvim nor a
Neovim help tag. `tests/spec/site_spec.lua` runs it too. The look and the
search live in `scripts/site/assets/`.

The Extensions status page measures what the build can see: the history
needs every commit and the release tags (a shallow clone leaves those
criteria at "not measured"), coverage comes from `coverage/coverage.json`
(`make coverage`, or `ORG_SITE_COVERAGE=FILE`), open bugs from `gh`
(`ORG_SITE_ISSUES=0` skips them) and the live demo only from
`ORG_DEMO_CONFIG`. The Pages workflow fetches the full history and the
latest Coverage run's report for it.

### Playground

The site's [playground page](https://org-nvim.com/playground.html) plays
a terminal recording of each `:Org tutor` lesson
(`docs/playground/<lesson>.cast`, asciicast v2 text, committed) next to
the lesson's exercises and their keys. The recordings are generated, never
edited: [`scripts/playground/record.lua`](scripts/playground/record.lua)
opens each lesson in a child Neovim with an 80x24 UI (the one
`tests/screen.lua` drives), plays it with the steps in
`scripts/playground/lessons/<lesson>.lua` (where to put the cursor, the
keys as tutor placeholders such as `{{org.cycle}}`, text to type) and
writes the screen after every key. The clock is fixed and event times come
from the steps, so the output is the same on every run, and the recorder
fails when the steps don't pass an exercise's tutor check.

```sh
make playground                  # rewrite docs/playground/*.cast (about 40 s)
make playground LESSON=workflow  # only that lesson
```

Run it after changing a lesson or adding one (a new lesson needs a steps
file too; see [Writing a tutor lesson](#writing-a-tutor-lesson)); `tests/spec/playground_spec.lua` fails when a lesson has no
recording, when an exercise with a check has no steps, when a recording
is older than its lesson or steps file (the cast header's
`generator.source` is a hash of both), or when a recording has a path of
the machine it was made on. The header's `generator.nvim` is the Neovim
that recorded it: the colors are its default colorscheme's, so re-record
with the same Neovim version (or expect color changes in the diff). The page itself is
`scripts/site/playground.lua`, and its player (no dependencies) is
`scripts/site/assets/playground.js`.

Pull requests that change the sources run the `Pages` workflow, which only
builds the site. Publishing a release deploys it to GitHub Pages (a
maintainer can also run the workflow by hand from the Actions tab).

## Writing a tutor lesson

`:Org tutor` is a course of lessons, each a real org file with exercises
checked as you do them, and each recorded for the
[playground](https://org-nvim.com/playground.html). A lesson is four files
of its own; nothing shared (no list of lessons, no spec, no page code)
needs editing, so lessons written side by side don't conflict:

| File | What it is |
| --- | --- |
| `tutor/org/<name>.org` | the lesson: metadata keywords, text, exercises and their practice material |
| `lua/org/tutor/lessons/<name>.lua` | the exercises' checks and hints |
| `scripts/playground/lessons/<name>.lua` | what the recording does, with its captions |
| `docs/playground/<name>.cast` | the recording, generated by `make playground LESSON=<name>`, never edited |

`<name>` is one lowercase word; it is what readers type (`:Org tutor
<name>`). Read [`tutor/org/basics.org`](tutor/org/basics.org) and
[`workflow.org`](tutor/org/workflow.org) with their two other files
before writing one: they are the reference for everything below.

### The course

Lessons are numbered in the order they are meant to be taken:

| Order | Name | Title (`#+TITLE: org.nvim tutor N: ...`) | Level |
| --- | --- | --- | --- |
| 1 | `basics` | the basics | Beginner |
| 2 | `workflow` | capture, agenda and clocking | Daily workflow |
| 3 | `agenda` | the agenda | Daily workflow |
| 4 | `links` | links, IDs and attachments | Daily workflow |
| 5 | `writing` | writing in org | Beginner |
| 6 | `dates` | dates in depth | Daily workflow |
| 7 | `tables` | tables as a spreadsheet | Power user |
| 8 | `properties` | properties and column view | Power user |
| 9 | `organize` | organize and find | Daily workflow |
| 10 | `code` | code and export | Power user |

The level is one of `Beginner`, `Daily workflow` and `Power user`
(`require("org.tutor").levels`). `:Org tutor` lists the lessons in this
order, the playground groups their cards by level, and when every
exercise of a lesson is ✓ the next one by order is named under its last
line.

### The lesson file

```org
#+TITLE: org.nvim tutor 3: writing
#+TUTOR_ORDER: 3
#+TUTOR_LEVEL: Beginner
#+TUTOR_TOPICS: emphasis, lists, links, footnotes, blocks
#+STARTUP: showall nologdone
#+TODO: TODO | DONE

One or two paragraphs: what this lesson is about. The playground shows
this first paragraph under "Welcome".

- The same reminders as workflow.org's intro: the ✓/✗ marks, keys as
  mapped, the copy (=:Org tutor writing reset=), and =:Org tutor_hint=.

* Lesson 1: a section
A few lines on the idea.

** 1.1 An exercise
What to do, with the keys as placeholders: press ={{org.cycle}}=.

*** Practice material
- or a list after a blank line, or a table

* What next
...
```

- The keywords come before the first headline, in this order. The title
  is `org.nvim tutor N: lowercase title` with N equal to
  `#+TUTOR_ORDER:`. `#+TUTOR_TOPICS:` is a comma-separated list of 3 to 8
  short topics, lowercase; the card on the playground shows them. The
  `#+TUTOR_...:` lines are left out of the reader's copy.
- `* Lesson N: ...` headlines are sections; exercises are exactly the
  level-2 headlines `** N.M Title` (N the section, M from 1), numbers
  unique in the lesson. The playground's exercise text is the
  exercise's text up to its practice material: a table line, a list after
  a blank line, or a headline. So write the instructions first, then the
  material to work on (subheadings, a list or a table).
- Keys are `{{section.action}}` placeholders for the default mappings
  (`{{org.cycle}}`, `{{org_insert.insert_tab}}`, `{{agenda.todo}}`,
  `{{capture.finalize}}`, `{{global.agenda}}`), written between `=` like
  `={{org.cycle}}=`: they become the reader's own keys. Never write a
  mapped key literally (`<leader>`, `<C-`, `<M-`, `<S-`, `<Tab>`); plain
  Vim keys (`=j=`, `=A=`, `=<Esc>=`, `=<CR>=`) and an action without a key
  (`=:Org capture_here=`) are written as they are. `{{leader}}`,
  `{{done}}`, `{{todo}}` and `{{examples}}` are the leader key, the ✓ and
  ✗ marks and a link to the examples.
- The recording is 80 columns by 24 rows with `nowrap`, and each exercise
  is scrolled to the top of the window: keep lines under 76 characters
  (placeholders grow: `{{org.clock_in}}` is `<leader>oxi`), and an
  exercise with its practice material within about 20 lines so what
  changes stays on screen.
- Each exercise teaches one thing, done with one to four keys. 10 to 14
  exercises fit the time budget below.
- End with `* What next`: where to read more (`={{org.help}}=`, `:h org-...`
  topics, `{{examples}}`). Don't name a lesson that may not exist yet:
  the tutor names the next one.
- Everything must work with the default configuration and nothing but
  the lesson file: the agenda and capture are restricted to it as in
  workflow.org, and nothing may touch the reader's notes.

### Checks and hints

`lua/org/tutor/lessons/<name>.lua` returns `{ checks = {...}, hints = {...} }`,
both keyed by exercise number:

```lua
---@type { checks: org.tutor.Checks, hints: table<string, string> }
return {
  checks = {
    ["1.2"] = { heading = "Pears", parent = "Fruit" },
    ["1.3"] = { { heading = "Carrot", parent = "Vegetables" }, { heading = "Spoon", depth = 2 } },
  },
  hints = {
    ["1.2"] = "On Apples press {{org.meta_return}}, type Pears, then <Esc>.",
  },
}
```

A check is a condition or a list of conditions that must all hold, on
the parse of the exercise's subtree (the `org.tutor.Condition` class in
[`lua/org/tutor/init.lua`](lua/org/tutor/init.lua)):

| Field | Holds when |
| --- | --- |
| `heading` | (selects the headline the fields below test: the subtree's headline with this plain title; default the exercise headline) |
| `todo` | its TODO keyword is this (`false`: none) |
| `priority` | its priority is this (`"A"`) |
| `tags` | it has these tags (its own) |
| `parent` | its parent's plain title is this |
| `depth` | it is this many levels below the exercise |
| `children` | its children's plain titles are these, in order |
| `scheduled`, `deadline` | it has (`true`) or hasn't (`false`) one |
| `clocked` | it has a closed `CLOCK:` line |
| `min_headings` | at least this many headlines under it |
| `item` | a list item of the exercise has this text |
| `checked` | a checked item has this text |
| `table_aligned` | the exercise's first table is aligned |
| `table_row` | a table row's first field is this |
| `contains` | the exercise's text contains this (plain) |
| `folded` | it is folded in a window (view) |
| `cursor` | a window has the cursor on the headline with this plain title, anywhere in the file (view) |
| `buffer` | a buffer whose name contains this text exists: an export, a file opened from the lesson (view) |
| `fn` | `fn(ctx)` returns true; `ctx` has `buf`, `file` (`org.File`), `exercise` (`org.Headline`), `lines` (the subtree's) |

Prefer the fields over `fn`, and test the result, not the keys used. The
view conditions (`folded`, `cursor`, `buffer`) are for exercises that change no
text: such an exercise stays done once it has passed. Give every
exercise a check when the result can be seen; `tests/spec/tutor_spec.lua`
fails when a check names no exercise of the lesson.

Every exercise has a hint (the spec fails otherwise), shown by `:Org
tutor_hint` with the cursor in the exercise: one sentence, at most about
100 characters, "On <where> press <keys>, ...", with placeholders for
mapped keys and plain `<CR>`, `<Esc>` for Vim's.

### The recording's steps

`scripts/playground/lessons/<name>.lua` returns the exercises to play, in
the lesson's order (the format is at the top of
[`scripts/playground/record.lua`](scripts/playground/record.lua)):

```lua
return {
  {
    id = "intro",
    title = "Welcome",
    hold = 1.5,
    steps = { { say = "A real org file: do each exercise and a ✓ appears on its headline." } },
  },
  {
    id = "1.2",
    steps = {
      { at = "Apples", col = "Apples" },
      { say = "{{org.meta_return}} opens a new headline below, in Insert mode." },
      { key = "{{org.meta_return}}" },
      { type = "Pears" },
      { key = "<Esc>" },
    },
  },
}
```

- The first entry is always `{ id = "intro", title = "Welcome", hold =
  1.5, steps = { { say = ... } } }`; then one entry per exercise, `id` its
  number. Every exercise with a check must be played (the spec fails
  otherwise), and the recording fails when an exercise's check doesn't
  pass at its end. Play every exercise.
- `at = "text"`: the cursor to the first line, from the exercise on,
  whose text (stars, blanks and a TODO keyword left out) starts with
  `text`, at `col = "text"` on that line if given; `whole = true`
  searches from the top of the file. In another buffer (the agenda, a
  capture window) any line containing the text.
- `key = "keys"`: keys as `nvim_input` takes them, placeholders resolved
  (`{{org.schedule}}`, `<CR>`, `ciw`, `:Org capture_here<CR>`); `<leader>`
  is Space. Shown as one key; follow-along mode asks for each key in it.
  Use one step per key the reader would think of as one.
- `type = "text"`: typed a character at a time, in Insert mode or a
  prompt.
- `wait = minutes`: the clock moves on (for clocking).
- `say = "text"`: a caption, see below.
- `mark = "label"`: a small tick on the timeline at a moment worth
  jumping to inside a long exercise ("The week"); no time.

The clock is fixed at Monday 2026-10-12 09:00, so a date prompt's `<CR>`
is always that day. Messages naming the data directory are rewritten;
avoid anything else that shows a path of the machine (the spec fails).

### Captions

At least one `say` per exercise (and the intro's), placed right before
the key it explains; one or two per exercise. The recording pauses
after a caption and keeps it up until it can be read, until the next
caption or the end of the exercise.

- One line of at most 80 characters once placeholders are resolved (the
  recorder fails otherwise); aim for 40 to 70.
- A plain sentence in the present tense ending with a period, starting
  with the key when there is one: "{{org.todo_next}} cycles the keyword:
  TODO becomes DONE." Say what the key does or why it matters, not what
  the exercise text already says.
- Keys as placeholders; no org markup (`=...=`), no "Now", "Let's",
  "Simply" or exclamation marks.

### Time budget and pacing

A recording lasts at most 150 seconds (`budget` in `record.lua`, the
2-second hold at the end included); `tests/spec/playground_spec.lua`
fails over it. Steps cost (milliseconds, `PACE` in `record.lua`): 1600 at
the start and at the end of each exercise, 700 per `at`, 950 per `key`,
140 per typed character plus 500 per `type`, 900 per `wait`, 1200 per
`say`, and an exercise lasts at least until its last caption has been up
for 1800 + 45 per character. A typical exercise takes 6 to 9 seconds.
Over budget: drop extra keys (one demonstration of a key is enough),
shorten typed text, or move an exercise to another lesson. Don't change
`PACE` or the budget for one lesson.

### Recording and checking

```sh
make playground LESSON=writing                     # record docs/playground/writing.cast
ORG_PLAYGROUND_EXERCISES=intro,1.2 ORG_PLAYGROUND_DEBUG=2 make playground LESSON=writing
                                                   # quick check: only those exercises, the screen after each step on stderr
make playground LESSON=writing                     # again before committing: the full recording
make playground LESSON=writing && git diff --exit-code docs/playground   # recording twice gives the same file
make test SPEC="tests/spec/tutor_spec.lua tests/spec/playground_spec.lua tests/spec/site_spec.lua"
make site                                          # then open site/playground.html
make lint
```

The partial recording of a quick check is not a commit: record the
whole lesson last. The specs check, for every lesson: the metadata
(order unique and equal to the title's number, a known level, topics),
the keys in the text and the hints, the checks' exercises, a hint per
exercise, a recording newer than the lesson and steps, every checked
exercise played, a caption per exercise, captions of at most 80
characters, and the time budget. In the page, check the lesson's card
(group, number, topics, length), its captions while it plays, follow-along
mode on a few exercises, the light theme, and its transcript. Then try
the lesson in Neovim, `:Org tutor <name>`, doing every exercise with its
keys and with `:Org tutor_hint`.

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
  grow that much is checked at 2N against 3×.

It also checks outcomes: the lines after a long line still highlighted,
no "'redrawtime' exceeded" message, fold levels equal to a full
recompute.

```sh
ORG_PERF_REPORT=1 make test SPEC=tests/spec/perf_budgets_spec.lua  # print every timing
ORG_PERF_SCALE=3 make test SPEC=tests/spec/perf_budgets_spec.lua   # 3x the budgets (slow machine)
ORG_PERF_SCALE=0.2 make test SPEC=tests/spec/perf_budgets_spec.lua # strict, to hunt a regression
```

When a budget fails, profile the operation with `require("jit.p")`
(`jit.p.start("Fl3", "/tmp/prof.txt")` … `jit.p.stop()`) and look for
work repeated per line, per headline or per object. What the first pass
over this input found (Neovim 0.12.5 on a laptop):

| Input | Before | After | Cause |
| --- | --- | --- | --- |
| lint, a file of 100,000-character lines | 2.2 s | 0.13 s | emphasis and link types searched to the paragraph end |
| export to Markdown, 10,000 headlines | 453 s | 2.8 s | a whole-tree walk per headline |
| export to HTML, 2,500 footnotes | 34 s | 0.3 s | a whole-tree walk per footnote reference |
| decorations, a 40,000-character hash | 8 s | 34 ms | a backtracking Lua pattern |

### Opening a file

Starting Neovim on an org file runs `setup()` and attaches the buffer:
keymaps, folds, decorations. That path should load only what
editing, folding and drawing a plain file need; everything a command
uses (agenda views, babel, export, the table editor, the clock, image
previews, link following, crypt, pickers, ...) loads on first use.
`tests/spec/first_open_spec.lua` opens `tests/fixtures/first_open.org`
in a Neovim of its own (`tests/helpers/first_open.lua`) and fails when a
module on its deny-list loads, or more than 60 org modules do; it is
deterministic and runs in the main suite. `perf_budgets_spec.lua` times
`setup()` and the first open against budgets (70 ms and 300 ms, times
`ORG_PERF_SCALE`).

When the deny-list fails, find what requires the module (wrap `require`
and print `debug.getinfo(2, "Sl")`) and make that use lazy: keep the
per-buffer part of a subsystem in a small module (`org.table.attach`,
`org.clock.attach`, `org.ui.images.startup`), check the cheap condition
first and require the module only when it holds, or, for a facade whose
own functions are a hot path, load its parts on first use with
`require("org.lazy").parts(M, shared, { ... })` (`org.lists`). What the
first pass found (Neovim 0.13-dev, Apple M1 Ultra, medians of 15 runs
on a machine busy with other jobs, so the times are slower than a
laptop's):

| | Before | After |
| --- | ---: | ---: |
| org modules loaded by `setup()` | 14 | 14 |
| org modules loaded by opening a plain file | 93 | 46 |
| opening a 12-line file | 74 ms | 56 ms |
| opening `tests/fixtures/first_open.org` (35 lines) | 74 ms | 55 ms |

The rest of the first open is mostly Neovim's own work: about 450 buffer
keymaps (`nvim_buf_set_keymap`, about 15 µs each), the first definition
of about 150 highlight groups and the first decoration scan.

### Benchmarks

```sh
make bench                    # 5 runs of each, a table of medians
make bench ARGS="--runs 9"    # more runs
make bench ARGS="--files 50"  # a smaller corpus
make bench ARGS="--json"      # the numbers as JSON
```

[`scripts/bench.lua`](scripts/bench.lua) times the first open and the
agenda over a generated corpus (`gen.agenda_corpus` in
`tests/helpers/gen.lua`: 200 files, 50,000 headlines with TODO keywords,
priorities, tags, SCHEDULED and DEADLINE dates around 2026-05-13 with
times, repeaters and warnings, habits, properties, clocks and plain
timestamps, the same every time). Each measurement runs in a new Neovim
with throwaway data and cache directories, `agenda.index.background` and
`watch` off. `tests/spec/bench_spec.lua` runs it on a tiny corpus so
that it keeps working. Numbers from Neovim 0.13.0-dev on an Apple M1
Ultra (20 threads, 128 GB, macOS 26, load average about 10 from other
jobs), medians of 5:

| Operation | Before | After | Agenda lines |
| --- | ---: | ---: | ---: |
| `setup()` | 8 ms | 9 ms | |
| open the first org file (35 lines) | 57 ms | 55 ms | |
| cold week agenda (no index: 200 files read and parsed) | 2,869 ms | 2,286 ms | 1,627 |
| warm week agenda (from the agenda index) | 1,035 ms | 519 ms | 1,627 |
| hot week agenda (files in memory) | 645 ms | 123 ms | 1,627 |
| tags match `+work-home` | 200 ms | 119 ms | 2,575 |
| TODO list | 471 ms | 339 ms | 17,901 |
| refresh the week after editing one file | 683 ms | 138 ms | 1,628 |

("Before" is the first-open work above without the agenda fixes below.)
The cold view is mostly the parse of 8.8 MB of Org; it varies from
about 1 to 3 seconds from run to run on macOS arm64, with the JIT
(below).

What the agenda pass found:

- **The JIT.** `require("jit.p")` with the `v` mode showed three quarters
  of a week view spent in the JIT compiler. The entry finders and the
  renderer run short, branchy loops (an entry's dates, its tags): most
  traces aborted ("leaving loop in root trace", closures created in a
  loop), and the ones compiled filled the machine-code area, which on
  macOS arm64 often can't grow (`jit.v` logs "failed to allocate mcode
  memory") and then flushes every trace in Neovim, about 100 times per
  view. Interpreted, the same view took a quarter of the time, and still
  less than with a larger machine-code area. `org.agenda.items` (and
  each of its parts in `agenda/items/`: the call covers only the
  functions of the file that makes it), `org.agenda.render` (and its
  parts in `agenda/render/`) and
  `org.agenda.habits` call `jit.off(true, true)`;
  the parser keeps the JIT, which helps it when it doesn't flush. To check
  a module, load it with the JIT off (`jit.off(loadfile(path), true)`
  in `package.preload`) and compare.
- A date-range pattern ran over every planning line on every build;
  it now runs only on lines with a `>-`.
- `utils.find_buffer` resolved each agenda file's path (`realpath`) on
  every build; the result is kept until a shell command or focus change.

## Promoting an extension

Every extension is ✅ stable or 🧪 experimental (`:h
org-extensions-stability`). The source of truth is the `stability` field
of its module (`M.stability = "stable"` in
`lua/org/extensions/<name>/init.lua`; a module without one is
experimental). The README table, the `✅`/`🧪` mark of its entry in
`docs/guide.md`,
the lists and the `Stability:` line of its section in `doc/org.txt` and
`:checkhealth org` follow it, and `tests/spec/ext_stability_spec.lua`
fails when one of them disagrees.

Promotion is checked **at every release**: before cutting a release
branch, run

```sh
make coverage            # optional, but the coverage criterion needs it
make extensions-report   # ARGS="--markdown", "--json", "--no-gh", or names
```

Coverage is read from `coverage/` when `make coverage` has run (its
`coverage.json`, `report.md` or `counts/`); `ARGS="--coverage PATH"` or
`ORG_COVERAGE=PATH` point at another, such as the `coverage` artifact of
the latest Coverage workflow run (`gh run download ID --name coverage
--dir DIR`). Without any, coverage shows `?` and the report says how to
get it.

`scripts/extension_report.lua` measures each criterion below for every
extension and lists the candidates (experimental extensions that pass all
of them), the near misses and stable extensions that have fallen below
the bar. Stable extensions short only of the releases-and-age criterion
are listed apart ("below the bar only by age"): time clears that, so
only the "with work left" list needs specs or docs. For experimental
ones, what only time clears comes after "waits on age". The release
pull request into `main` shows the same report in its job summary (with coverage from the latest Coverage run), and so does
the weekly Coverage workflow; the website publishes it as the
[Extensions status](https://org-nvim.com/extensions.html) page at every
release. An experimental extension becomes stable
when it meets **every** criterion:

| Criterion | Measured as | Bar |
| --- | --- | --- |
| specs | `it(...)` tests in its own spec files: `ext_<name>_spec.lua`, `ext_<name>_<part>_spec.lua`, `fuzz_<name>_spec.lua` | ≥ 25 |
| edge spec | a fuzz spec, a spec file `ext_<name>_{edge,safety,stress,fuzz,robust}…_spec.lua`, or a `describe` in its specs about edge / stress / malformed / fuzz / robust / corner / pathological / safety cases | one |
| coverage | line coverage of `lua/org/extensions/<name>/` by `make coverage` | ≥ 80% |
| docs | every option (each key of its `defaults`, and the keys of a nested table of options, not of a `keys` / `*_keys` table) named in its `doc/org.txt` section (a nested key also counts as `<name>_<key>`); every top-level option a `---@field` of its class in `lua/org/_meta/` | all |
| health | a `health` function (`:checkhealth org`) | yes |
| releases, age | minor or major releases (`vX.Y.0` tags) that contain its first commit, and days since that commit | ≥ 3, ≥ 30 days |
| no break | minor or major releases after the one that shipped its last breaking change: a commit marked breaking (`!` before the colon, or a `BREAKING CHANGE:` footer) whose scope is its name; or whose scope is `extensions` / `ext` and whose subject or footer has its name as a word; or whose footer names it unambiguously (`` `name` ``, "name extension", `extensions.name`); or one that removed a `---@field` from its `_meta` class | ≥ 3 (or never) |
| open bugs | open issues labelled `bug` about it: a label named after it (or `ext:<name>`), its name in the bug form's Extension field, or a title naming it (`name: ...`, `[name] ...`, `fix(name): ...`, `` `name` ``, "name extension"; the bare word only for a name that isn't an everyday word), or a body saying "name extension" or `extensions.name` (needs `gh`; skipped offline) | 0 |
| demo | enabled in the live demo config (`--demo FILE`, `$ORG_DEMO_CONFIG` or `~/demo/config.lua`; skipped when there is none) | yes |

A skipped criterion (no `gh`, no demo config) doesn't block a candidate,
but check it by hand before promoting. The history criteria need every
commit and the release tags: in a shallow clone or one without tags they
are not measured (`?`), and that blocks a promotion. So name the
extension in a breaking commit unambiguously, and when you add an
extension, add it to the Extension dropdown of
`.github/ISSUE_TEMPLATE/bug_report.yml` too. The bar is the `BAR` table at the
top of the script; change it there and here together.

To promote, in a pull request into `dev` titled for the changelog
(`feat(extensions): promote heatmap to stable`): set `M.stability =
"stable"`, move the name to the stable column of the README table and to
`Stable:` in `:h org-extensions-stability`, change its mark in
`docs/guide.md` to ✅
and its `Stability:` line, and run `make test
SPEC=tests/spec/ext_stability_spec.lua`. From then on, a change to its
options, actions or keys is called out in the release notes, and a
breaking one (`feat(<name>)!:` or a `BREAKING CHANGE:` footer) bumps the
major version. Nothing is demoted automatically: a stable extension below
the bar is a prompt to add the missing specs or docs.

## Lessons from past debugging

What cost rounds before and isn't obvious from the code.

### Windows

The Windows job of CI is the only feedback loop for it (about 12 minutes).
A job's log can be read with `gh api repos/<owner>/<repo>/actions/jobs/<id>/logs`
once the job ends, or `gh run view <run> --log-failed` once the whole run
ends.

- Paths: `fs_realpath`, `fnamemodify(":p")` / `(":~")`, `getcompletion()`
  and `expand()` return `\` on Windows, and libuv's home is
  `%USERPROFILE%` (it ignores `$HOME`). In plugin code use
  `utils.realpath`, `utils.abbreviate`, `utils.complete_path`,
  `utils.is_absolute` and `utils.home`, and in specs compare paths through
  `vim.fs.normalize`.
- The runner (`tests/run.lua`) has the helpers: `fake_exe` (a shell
  script plus a `.cmd` launcher), `path_prepend`, `skip_on_windows`,
  `posix_shell()` and `tz()` (America/New_York becomes EST5EDT there).
  `ORG_TEST_PROGRESS=1` (or `2`) names each file (or test) as it starts,
  to find a hang.
- cmd.exe mangles `.cmd` arguments containing `< > '`, and setting
  'shell' to sh for the whole run breaks `.cmd` launches.
- A `term = true` job (ConPTY) in headless Neovim gets EOF at once, so the
  REPL `:session` specs are skipped there. stdin must be `/dev/null`, or an
  unstubbed prompt hangs the job.
- Unsetting `TZ` doesn't reach the MSVC C runtime's copy:
  `date.set_tz(nil)` sets it to `""` first.
- Git's MSYS gpg blocks headless, so the encryption specs are skipped on
  Windows.

### A CI failure on your pull request

Before blaming the change, look for the same failure on unrelated runs:
`gh run view <id> --log-failed | grep FAIL:` over recent failed runs. A
known flake goes in `tests/quarantine.lua` (see "Flaky specs");
`gh run rerun <run> --failed` reruns the failed jobs. GitHub's runners
ship real programs (`psql` and other database clients), so a fake
executable in a spec must be run by its absolute path, not found first on
`PATH`.

### Folds

- Neovim evaluates 'foldexpr' after `on_bytes` but before `on_lines` for
  a normal edit, and before both for undo and redo. That is why
  `lua/org/fold.lua` tracks the changedtick it expects and recomputes
  everything when a change wasn't reported. Resetting 'modified' (a read
  or write) bumps changedtick with no `on_bytes`.
- Neovim re-evaluates 'foldexpr' only near an edit, so the levels of
  distant rows go stale (the end of a block deleted, a headline's depth
  after `J`, `dd` or undo). After every edit `fold.lua` runs
  `vim._foldupdate` over the rows whose levels changed. A Neovim bug
  (0.12, 0.13-dev) also leaves the last row of the outermost fold around
  an edit unevaluated (`fold_ends`). A quick repro on old code: `J` on the
  first headline, then `u`; a later headline gets fold level 0.
- For a fold report, compare `vim.fn.foldlevel(l)` with
  `fold.compute(lines)` after the edits in a real UI. Headless `-l`
  scripts never run `vim.schedule` callbacks until they exit, so use the
  spec runner (`vim.wait`) for a headless repro.

### Typing latency

Measure it in a real UI: Neovim in a detached tmux session, keys sent
with `tmux send-keys`, timed from `vim.on_key` to the decoration
provider's `on_end`, counted from the last key before the redraw. A
`v:lua` 'foldexpr' costs about 1.7 µs a line in bridge overhead, so a
full fold pass over 112,000 lines takes about 200 ms whatever the Lua
function does. Compare with a `git worktree` of `dev`. For the agenda over
many files, see "Benchmarks"; profile with
`require("jit.p").start("Fl3", out)`.

### Trying commands by hand

When you try `bin/org`, the Lua API or a capture by hand, point HOME and
every `XDG_*` directory at a scratch directory and set `org_directory`,
`agenda_files` and `default_notes_file` inside it. With a misspelt option
(`capture_templates` instead of `capture = { templates = ... }`) capture
falls back to Emacs's default template, whose target is
`default_notes_file`: `~/.notes`, your real notes. `make verify` does all
of this for its scenarios.

## Pull requests

- Keep each PR focused on one change. Small PRs get reviewed faster.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for
  titles, as the history does: `feat(agenda): …`, `fix(capture): …`,
  `docs: …`.
- Describe how you tested the change. For UI changes, a screenshot or
  short recording helps a lot. Maintainers record GIFs with vhs (a tape
  that sources `docs/media/tapes/common.tape`) and push them to the
  `media` branch under `pr/<number>/`, linked from the description by
  their `raw.githubusercontent.com` URL; for a fix, one before and one
  after.
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
  and on macOS and Windows against stable, plus `make lint` (stylua and
  the source lint rules), `make typecheck`
  and a helptags check, which fails on an `E154: Duplicate tag`; after
  editing `doc/org.txt`, run `nvim --headless -u NONE -c "helptags doc" -c q`
  and look for that error (it doesn't change the exit status there). A pull request that
  changes the docs also builds the website. Pushes don't run CI.
- The Fuzz and Difftest (nightly) and Coverage (weekly) workflows test `dev`. GitHub
  starts scheduled workflows from the default branch, `main`, so a change
  to them takes effect with the next release; both can also be run from
  the Actions tab, on any branch.

To release, check the extensions first (`make extensions-report`; promote
the candidates in a pull request into `dev`, see "Promoting an
extension"), then branch from `dev`, update the changelog and open a pull
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
squash, so that commit is part of `main`. The Release workflow then
brings the release back into `dev`, so `dev` gets the changelog and
reaches the tag: it makes a `merge-back/v0.2.0` branch at the release
branch's last commit (the release branch may be deleted by then) and opens
a pull request from it into `dev`, titled `release: merge v0.2.0 into dev`
(a `release:` subject, which the changelog leaves out). It skips that when
`dev` already has the commit. Merge that pull request with a merge commit
too, resolving any conflict (usually `CHANGELOG.md`, take the release's)
on the `merge-back` branch; pull requests opened by the workflow don't
start CI. Opening it needs "Allow GitHub Actions to create and approve
pull requests" (Settings > Actions > General); without it, or if the step
fails, the release is still out and the step's warning links to open the
same pull request by hand. Pick the version with
[semver](https://semver.org): a breaking change (`feat!:` or a
`BREAKING CHANGE:` footer, listed first in the changelog) bumps the major
version, a `feat` the minor version, and fixes the patch.

Thanks again, and happy hacking! 🦄
