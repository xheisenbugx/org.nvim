# Org 9.8 review follow-up

This review compares changes with `main` at
[`a2f0ad7`](https://github.com/xheisenbugx/org.nvim/commit/a2f0ad74346a6ab4fa9ed9fde770bd13c9f0412b),
including merged PRs [#36](https://github.com/xheisenbugx/org.nvim/pull/36),
[#37](https://github.com/xheisenbugx/org.nvim/pull/37), and
[#39](https://github.com/xheisenbugx/org.nvim/pull/39). It revisits their
findings and audits related settings, property, column, clock, export,
special-edit, capture, refile, and archive paths. It is a scoped behavioral
review, not an exhaustive conformance score.

Reference behavior was checked with local Emacs Org **9.8.7** source and
batch probes, and re-checked against Org **9.8.10** in the second review
below. The [settings contract](https://orgmode.org/manual/In_002dbuffer-Settings.html)
and [property commands](https://orgmode.org/manual/Property-Syntax.html) also
describe the functionality implemented here.

## Functionality and correctness changes

| Area | Behavior on main | Follow-up and regression coverage |
| --- | --- | --- |
| Core setup files | Shared TODO states, tags and properties do not reach the editing/agenda model. | Recursive local settings collection, relative/quoted paths, cycle detection, dependency cache invalidation, and consistent lint settings. [Setup-file specs](../tests/spec/setupfile_spec.lua). |
| Setting precedence and consumers | Repeated unique settings use the last value; conflicting STARTUP flags coexist; tables and image startup scan literal examples and miss imported settings. | First unique setting wins; the last mutually exclusive startup flag wins; consumers use parsed settings. Setup-file specs cover these paths. |
| Property commands | File-level drawer actions and allowed-value cycling are ignored; compute-property is missing; global deletion skips the file drawer. | Shared file/headline context, `C-c C-c c` and `:Org compute_property_at_point`, file-drawer deletion and cycling. [Property-command specs](../tests/spec/property_commands_spec.lua). |
| Column scope and format editing | Opening column view can rewrite unrelated siblings' summaries; malformed format text crashes; storing a format can edit a literal example. | Current-subtree scope unless a COLUMNS property defines a wider scope; safe format parsing; correct property/keyword destination and local overrides of imported formats. Property-command specs. |
| Clock consistency and idle resolution | The agenda clock check (`vc`) and idle/dangling resolution use civil-time arithmetic across DST (clock-line updates and clock display were already DST-correct); future idle-resolution targets can be written. | Unix-time duration calculations, local-time gap allowances, validation before clock mutation. [DST specs](../tests/spec/clock_dst_spec.lua), [resolution specs](../tests/spec/clock_resolution_spec.lua). |
| Export escaping | Nested escapes such as `,,*` keep one comma too many. | Export shares Babel's single-comma unescape. [Export follow-up specs](../tests/spec/export_followups_spec.lua). |
| Export setup collection | A separate collector evaluates Vim filename expressions, caps legitimate nesting at 10, and handles cycles/literal boundaries differently. | Export, publishing and preview preambles share the bounded, non-evaluating local settings collector. Export follow-up specs. |
| Special editing | Fake ending delimiters truncate blocks; nested-looking literal text is edited as a different element; tab-after-colon paragraphs lose text; example indentation options are ignored. | Exact boundaries and containing-element lookup; fixed-width syntax validation; shared indentation rules. [Special-edit specs](../tests/spec/special_regressions_spec.lua). |
| Special-edit conflict recovery | There is no intentional conflict overwrite. | `:write!`/`:wq!` overwrite content conflicts only while the source range remains intact. A failed `:wq`/`:wq!` already kept the edit buffer on main; the spec now guards it. Special-edit specs. |
| Capture, archive and refile preservation | Capture cancellation can discard unrelated target edits; archive accepts destinations inside the source subtree; save errors are hidden before destructive follow-up actions. | Targeted capture rollback, destination validation, and persistence checks before source removal. [Data-preservation specs](../tests/spec/data_preservation_spec.lua). |
| Agenda test reliability | On Sunday, tomorrow's meeting lies outside the current week, so the bulk-mark test fails. | Pin the fixture date and assert the intended target was found. [Agenda spec](../tests/spec/agenda_spec.lua). |

## Second review (Org 9.8.10)

Every claim above was reproduced on `main` with a headless script, compared
with Emacs Org 9.8.10 (source and `emacs --batch` probes), and checked on the
PR. All reproduced on main and are fixed, with these corrections: the DST
fix is limited to the agenda clock check and resolution (see the table), and
`:wq!` keeping a failed edit buffer is not a behavior change. Archiving into
the source subtree is refused although Emacs `org-archive-subtree` has no
guard (Emacs empties the buffer in that case); the check follows `org-refile`.

The review also found issues in the first follow-up commit, fixed with
regression specs (each fails on `0ba4940`):

| Area | Problem in `0ba4940` | Fix |
| --- | --- | --- |
| Save errors | `save_buffer` raised, so failures showed a Lua traceback; agenda save-all stopped at the first read-only buffer; a refile copy to a hidden read-only target raised. | `save_buffer` returns `ok, err` with a one-line message; data-moving callers roll back, others warn and continue. |
| Capture abort | Writing the target during a capture, then aborting, marked the buffer unmodified while the file still held the capture. | The flag is cleared only when the file matches the restored text. |
| Special edit | Every failed `:w` showed a BufWriteCmd traceback and a hit-enter prompt. | One-line error; the buffer stays modified, so `:wq` still refuses. |
| CATEGORY | The first value won, including one from a setup file. | Emacs `org-element--get-category`: the buffer's last `#+CATEGORY`, else the first collected, else the file name. |
| COLUMNS | A setup file's format beat the buffer's own `#+COLUMNS`; an empty first `#+COLUMNS:` crashed column view. | Emacs `org-columns-get-format`: the first non-empty local keyword, then the collected default. Format edits change that local line. |
| Column view | Subtree scope left no whole-file view; allowed values defined in the file drawer were copied to the entry. | A count opens the global view (`C-u` `org-columns`); `a` edits the file drawer (`org-columns-edit-allowed`). |
| Setup paths | `$VAR` was expanded, unlike Emacs and lint; `a:b.setup` was treated as remote; each cached parse resolved every loaded buffer's real path. | Only `~` is expanded; URLs follow `org-url-p`; resolved names are cached per buffer (4.6 ms → 62 µs per cached parse with 300 buffers). |
| Path expansion | `#+INCLUDE`, columnview/clocktable scopes and Babel paths went through `vim.fn.expand`, which evaluates backticks and `%`/`#`. | `utils.expand` expands only `~` and environment variables. |
| Lint | The macro checker scanned setup files separately (literal blocks, unsaved buffers); INCLUDE searches ignored the target's setup files; its unescape dropped a comma before any comma. | Lint uses the shared keyword collector and Babel's unescape. |
| Clock resolution errors | A rejected resolution (future target) raised a Lua traceback from `resolve_clocks` and the idle timer. | One-line error; clocking in stops when resolution fails, like Emacs. |
| Clock rounding | Resolving "now" (keep all, `J`) skipped `rounding_minutes` (existing gap). | Clock out through the normal rounded path, like `org-clock-clock-out`. |

## Boundaries and remaining work

Local setup imports are limited to 64 nesting levels and 256 imports per
parse. URLs are not fetched. Missing/unreadable local files are ignored by
the core parser; lint reports missing paths. Settings dependencies include
unsaved loaded-buffer contents. A changed dependency refreshes document
metadata when it is next requested; this is not a live refresh of every
already-open agenda or export view.

Forced special writes cannot recover a deleted, wholly replaced, or wiped
source range. Both versions must be reconciled manually in that case.

One reproduced clock limitation on main remains: offsetless timestamps in
the repeated autumn DST hour cannot distinguish its two occurrences. For
example, New York 2026-11-01 00:30 through the **second** 01:30 can still
record `1:00` instead of `2:00` after resolution. The elapsed-time fixes and
tests cover unambiguous local timestamps crossing DST transitions; they
do not add timezone/fold identity to the stored Org timestamp model.

The findings from PR #36 that remained outside this implementation were
addressed in the [third round](#third-round-closing-the-roadmap-gaps)
below, except where noted there.

See [`:h org-differences`](../doc/org.txt) for the existing detailed
compatibility notes. Each larger missing feature needs its own contract,
fixtures and review; the table distinguishes remaining work from the
specific fixes above.

## Validation against main

| Check | Main (`a2f0ad7`) | Follow-up |
| --- | --- | --- |
| Unmodified full suite | 2,150 passed, 1 Sunday-dependent agenda failure | 2,240 passed, 0 failed on Neovim 0.12.5 and 0.13.0-dev-1473 (after the second review) |
| Same seven regression specs | 15 passed, 71 failed | 86 passed, 0 failed |
| `make lint`, StyLua 2.3.1 | 91 files with style differences; 7 parser errors | 89 files with existing style differences; the same 7 parser errors; no new failing file |

The main regression comparison was also run one spec per Neovim process.
The 71 failures are regression cases, not 71 distinct bugs. The DST wrapper
counts as one top-level test and runs 13 checks in `America/New_York`.
New regression files and the shared keyword collector pass StyLua, and
`git diff --check` passes. Existing repository formatting debt was retained.
The isolated runtimes emit a missing Markdown Tree-sitter parser diagnostic;
write-failure tests intentionally emit write errors. These are local tests,
not a claim about CI or every supported Neovim release/operating system.

## Third round: closing the roadmap gaps

This round implemented the roadmap and the remaining PR #36 gaps. Each
area was compared with Org 9.8.10 source and `emacs -Q --batch` probes;
where Emacs output could be produced, specs compare against it.

| Area | Implemented | Remaining difference |
| --- | --- | --- |
| Column view | Overlays over the headlines (default, `columns_view = "table"` keeps the old view), winbar header, all in-view keys; agenda header in the winbar. [Spec](../tests/spec/columns_overlay_spec.lua). | The cursor moves by character, not by column; headlines are not read-only. |
| RSS/Atom (`org-feed`) | Full port: `feed.feeds`, templates, filters and handlers, RSS 2.0 and Atom, FEEDSTATUS drawers byte-identical to Emacs (SHA-1 included), `C-c C-x g` / `G`. [Spec](../tests/spec/feed_spec.lua). | Fetched with curl/wget instead of url.el. Some org-feed.el bugs are fixed, not copied (listed in `:h org-differences`). |
| ODT export | Native port of ox-odt with a pure-Lua zip writer; content.xml matches Emacs on four fixtures; MathML/picture LaTeX, styles files, LibreOffice conversion. [Spec](../tests/spec/export_odt_spec.lua). | Pandoc is optional (`export.odt.use_pandoc`). Real LaTeX pictures and soffice conversion were tested with fake processes only. |
| Texinfo export | Native port of ox-texinfo; golden files from Emacs; the whole Org manual exports identically. Info through makeinfo. [Spec](../tests/spec/export_texinfo_spec.lua). | `(eval (org-texinfo-kbd-macro ...))` needs a Lua macro. makeinfo was not installed for the tests. |
| Durations and dates | `org-duration` port (`duration_units`, every `duration_format` form) used by clocks, clock tables, efforts and columns; `format-time-string` port; custom timestamps in export like `org-timestamp-translate`. [Specs](../tests/spec/duration_spec.lua), [custom time](../tests/spec/custom_time_spec.lua). | The date-prompt preview does not use the custom format. |
| `#+TYP_TODO` | Type sequences jump to DONE; a repeated `C-c C-t` walks the types. [Spec](../tests/spec/todo_type_spec.lua). | "Repeated" means no edit or cursor motion since the last press, not `last-command`. |
| Capture | `:unnarrowed` edits the capture in the target buffer with targeted rollback; `org-extend-today-until` for capture dates, clock blocks, clocktable steps and repeaters; `:hook`. [Spec](../tests/spec/capture_spec.lua). | Narrowed captures still use a separate buffer (no indirect buffers). |
| Images and LaTeX | Drawn in place of the link (`ui.images.placement`), text shown on the cursor line; per-link-type preview functions; remote http(s) images; batching. [Spec](../tests/spec/images_spec.lua). | Multi-line fragments and image.nvim stay below the line. Not verified in a real kitty terminal in this round. |
| Agenda | Pure-Lua PostScript/PDF output in ps-print's layout, `agenda.exporter_settings`; `gC`/`M`/`S`/`H` calendar commands with 14 calendars; group tags in the tag filter; sexps before the first heading; `diary-remind`, `diary-offset` and the other calendars' `diary-*-date`. [Specs](../tests/spec/agenda_print_spec.lua), [calendars](../tests/spec/agenda_calendars_spec.lua). | `gC` instead of `C` (the clock report). Anniversary sexps of other calendars and the Emacs diary file are missing. |
| MobileOrg and attach-git | `org-mobile` push/pull/apply with byte-identical staging files, encryption and flagged agenda; `org-attach-git` commits and git-annex. [Specs](../tests/spec/mobile_spec.lua), [attach-git](../tests/spec/attach_git_spec.lua). | The staging directory must be local. git-annex paths were not exercised (not installed). |
| Babel, Calc and tables | emacs-lisp blocks and `elisp:` links in a separate `emacs --batch` (Lisp-subset fallback); Calc complex numbers, HMS, error forms, intervals, units and ~40 functions; orgtbl-to-unicode, orgtbl-to-table.el; radar plots. [Specs](../tests/spec/babel_elisp_spec.lua), [Calc](../tests/spec/calc_ext_spec.lua). | No symbolic algebra, matrices or modulo forms; `'(...)` table formulas stay on the internal interpreter. |

Still out of reach after this round: Elisp that must run inside the
editor (`#+BIND`, `%(sexp)` capture escapes, arbitrary diary sexps), Emacs
applications (Gnus, mu4e, BBDB), table.el-format tables, and Babel
sessions as full REPLs. The [fourth round](#fourth-round-roadmap-and-org-differences)
closed all of these except the Emacs applications.

The branches were developed in parallel and merged; the full suite on
the merged branch is reported in the pull request. StyLua was not run
(the local version differs from the one the repository uses).

## Fourth round: roadmap and `org-differences`

This round took every roadmap item and every fixable entry of
`:h org-differences`. Each area was compared with Org 9.8.10 (and Emacs 31
for Calc, table.el and the calendar libraries) using the source and
`emacs -Q --batch` probes; the specs' expected strings come from those
probes.

| Area | Implemented | Remaining difference |
| --- | --- | --- |
| Calc in table formulas | Ports of Calc's normalization and printing, `simplify`, `expand`, `collect`, `subst`, `deriv`, `solve` (up to quartics, inequalities); vectors and matrices (`det`, `inv`, LU division, `trn`, `cross`, `map`/`reduce`...); modulo forms; temperature and more units in `usimplify`; `frac` fixed. 306 formulas identical to `calc-eval`. [Spec](../tests/spec/calc_symbolic_spec.lua). | `integ` is a custom integrator (other forms, fewer integrals); no `factor`, polynomial functions, `taylor`, `fsolve` or degree-5 roots; a few last-digit float differences. |
| Babel sessions | Live REPLs in terminal buffers named like Emacs (`*Python*`, `*shell*`...) for shells, python, ruby (irb), node and R; state shared with typed input; ob-comint style markers; kill/exit handling. [Spec](../tests/spec/babel_repl_spec.lua). | A block reaches the REPL as one "run this file" line; shells start without rc files; no julia/SQL sessions; R and fish untested here (not installed). |
| Diary | `diary-hebrew-birthday`/`-yahrzeit`/`-omer`/`-rosh-hodesh`/`-parasha`/`-sabbath-candles`, `diary-chinese-anniversary`, `calendar_date_style`; the Emacs diary file in the agenda (`include_diary`, `D`, `#include`, other-calendar entries). Parasha, Rosh Hodesh and Omer match Emacs over 1950–2049; eight agendas match line for line. [Specs](../tests/spec/agenda_diary_file_spec.lua), [calendars](../tests/spec/agenda_calendars_spec.lua). | No `i` key; custom `diary-date-forms` and comments; a bad `#include` warns instead of stopping. |
| table.el tables | Recognized like org-element and left alone by Org table commands; `C-c ~` both ways and `table-insert`; `C-c '` editor with realignment; HTML/Markdown/LaTeX export byte-identical to Emacs on 18 tables. [Spec](../tests/spec/table_el_spec.lua). | The editor realigns on leaving Insert mode, never shrinks cells and has no table.el cell commands; double-width characters break the grid. |
| Display | Custom timestamp formats in the date prompt preview; multi-line LaTeX fragments drawn in place (0.11+); column view moves a column at a time and refuses typing on its rows. [Specs](../tests/spec/images_spec.lua), [columns](../tests/spec/columns_overlay_spec.lua), [calendar](../tests/spec/calendar_spec.lua). | The plain preview shows repeaters; image.nvim draws below; column rows can still be changed by edits started elsewhere (Visual, Ex, API). |
| Emacs Lisp | `#+BIND` (`export.allow_bind_keywords`); `(eval ...)` macros with `$1..$n` bound as in 9.8.10 and `org-texinfo-kbd-macro`; capture `%(sexp)` as Lisp; diary sexps, `%(fn)` abbreviations, `elisp:` commands and header forms in a separate Emacs when the interpreter can't. [Specs](../tests/spec/export_bind_spec.lua), [macros](../tests/spec/export_macro_eval_spec.lua), [capture](../tests/spec/capture_sexp_spec.lua), [fallbacks](../tests/spec/elisp_fallback_spec.lua). | The separate Emacs has no editor state; `#+BIND` only sets variables with an org.nvim option; an unsupported `(eval)` macro without Emacs exports empty with a warning. |
| Smaller differences | Clock-out and refile notes in `*Org Note*` (C-c C-k logs nothing); file-level `id:` links before the first heading; the Emacs `org-id-locations-file` format; wildcard `file:` listings; `*Org Shell Output*`; archiving over a Visual selection; `checkbox_radio_mode`; `refile.use_cache`; TODO default/statistics hooks. [Spec](../tests/spec/log_notes_spec.lua) and existing specs. | The note is taken before the change is applied; the ID file is last-writer-wins; the refile cache stores line numbers; the wildcard listing is not Dired. |

A match string in `loop_over_headlines_in_active_region` now acts like
`true`: the option's docstring describes matching, but a probe showed that
Emacs 9.8.10's commands pass nil as the match and change every headline.

Validation: the merged branch passes the full suite (2508 passed, 0
failed, Neovim 0.13.0-dev). StyLua was not run (the local version differs
from the one the repository uses); new code is formatted by hand.

## Fifth round: a measured inventory

The earlier rounds reported estimates. This round measures parity. Emacs
lists every interactive command and every user option that Org 9.8.10
defines ([`parity/inventory.el`](parity/inventory.el): 877 commands and
1,055 options, obsolete aliases left out), and each of the 1,932 was
classified against org.nvim in [`parity/inventory.tsv`](parity/inventory.tsv):

| Status | Meaning |
| --- | --- |
| done | Equivalent behaviour, with the code that does it and a spec that exercises it |
| vim | Stock Neovim does the same (a motion, undo, `:help`) |
| partial | Exists, with a gap named in the note; counts half |
| missing | Not implemented |
| emacs-only | Needs an Emacs application or package (Gnus, BBDB, TRAMP, CDLaTeX...) |
| na | No user-visible effect outside Emacs (byte compilation, caches, obsolete aliases); not counted |

Overall parity is (done + vim + partial/2) / (total − na − emacs-only);
strict parity also keeps emacs-only in the denominator.
[`parity/score.sh`](parity/score.sh) computes both, per area, for
`inventory.tsv` or for the classification of `main` before this round,
[`parity/inventory-baseline.tsv`](parity/inventory-baseline.tsv). The
evidence column points at code as it was when classified; line numbers
drift.

| | Items | done | vim | partial | missing | emacs-only | na | Overall | Strict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Before this round (`main` at `6815b25`) | 1,932 | 1,242 | 70 | 100 | 365 | 55 | 100 | 76.6% | 74.3% |
| After | 1,932 | 1,733 | 70 | 2 | 0 | 24 | 103 | 99.9% | 98.6% |

### How the gaps were closed

The 465 missing or partial items were split into twelve workstreams by
module, each on its own branch, then merged. Each workstream compared its
items with Org 9.8.10 source and `emacs -Q --batch -L org-9.8.10` probes;
where Emacs produces text (buffers, exports, agenda lines, results), the
spec's expectation is the probe's output and says so.

| Workstream | Items | Highlights |
| --- | --- | --- |
| Structure editing | 37 | Org `indentexpr` and `formatexpr` (`=` and `gq` like org-indent-line and org-fill-paragraph, compared line by line with Emacs on 27 indentation and 10 filling cases), the org-goto outline browser, org-yank on `p`/`P`, saved agenda-file lists, special C-a/C-e/C-k, bookmarks, `:Org version` |
| Display and folding | 31 | Cycling options and hooks, hide-entry/block/drawer commands, context detail per jump, user entities and the entities help, hidden keywords, macro markers, indent-mode options, Babel speed keys |
| TODO, tags, properties | 21 | `todo_yesterday`, logging options, priority functions, persistent tags, tag sorting (with `hierarchy`), property separators and post-processing |
| Dates and links | 22 | Live date interpretation and the plain prompt, calendar keys, sparse-tree date types (and Emacs's date comparisons), mouse and TAB following, `open_at_point_global`, the remote resource policy |
| Agenda | 56 | Remote undo, hour and minute shifts, habit toggles, `i` diary entries, entry text options, custom-command contexts, global skip function, hooks, show/cycle commands |
| Tables and lists | 37 | Alphabetical bullets, bullet and indentation options, item motions, checkbox reset, table typing (auto-blank, BS/Del keeping alignment), wrap region, goto column, every hard-coded table option |
| Capture, clock and others | 42 | Global capture hooks, `capture_string`, date tree cleanup and time stamps, clocktable formatter and cell formats, `refile_reverse`, attach dispatcher, `id:` completion by heading, org-ctags, clipboard images and dropped files |
| Babel languages | 64 | ob-plantuml, gnuplot, latex, ditaa, lilypond, java, csharp, haskell, clojure, lisp, scheme, fortran, processing, screen; julia, groovy, ocaml and maxima with `:var` and value results; Python/Ruby/Lua value options |
| Source editing, Babel core, links | 47 | Edit-buffer reuse, auto-save, session association, TAB in blocks, export templates, `babel_remove_inline_result`, ol-bibtex |
| Export | 51 | Convert region for every back-end, htmlize-style HTML highlighting, LaTeX images in HTML, dispatcher options, the export stack, Beamer mode, ODT extras, iCalendar diary sexps, HTML indentation; about 70 options that were read but undocumented |
| KOMA letters and man pages | 37 | Native ports of ox-koma-letter and ox-man with golden files from Emacs |
| Citations | 20 | Insert, follow and activate processors, and the CSL processor: a port of citeproc-el that gives citeproc-el's output on 840 of the 845 CSL test-suite cases |

A second wave took the items first marked emacs-only that Neovim can do
after all: the Org, table, agenda, column, formula and OrgTbl menus
(`:menu`, the PopUp menu), org-mouse, `:Org customize`, `:Org bug_report`,
the calendar's agenda and diary keys, `gO` headline index (org-imenu-depth),
the mouse-over citation face, and engraved LaTeX source blocks.

### Independent verification

The workstreams graded their own items, so separate agents re-checked
every one on the merged branch: the code must change behaviour (an option
that is only declared does not count), a spec must exercise it, and at
least one item in eight was probed against Emacs 9.8.10 and compared with
org.nvim's output. Of the 465 first-wave items, 446 were confirmed, 15 were
partial and none were missing. The partial items and the bugs found on
the way were then fixed with regression specs (each fails without its
fix), except three that stay open (below). Bugs the verification caught:

- Agenda `show_1`/`cycle_show` folded the entry itself or its parent;
  a background `bufload` never applied the startup visibility.
- A buffer-local `g` in the lint report list swallowed `gg`; the refresh
  key is `r` (a mapping of `g` always takes the first `g`).
- The citation click and the link click both mapped `<LeftRelease>`; the
  link handler shadowed citations.
- A TODO headline with a priority cookie lost `fontify_todo_headline`.
- `%flags` and `%results` in export code templates differed from Emacs.
- The agenda's missing-file prompt used a removal list that the new saved
  agenda-file list replaced.
- `indirect_buffer_display` "dedicated-frame" opened an edit buffer and
  "other-window" kept adding splits.
- The ClojureScript backend fell back to the Clojure one; the "dynamic"
  citation separator read keys instead of the completion strings;
  `edit_headline` ignored `auto_align_tags`; `ctags.append_topic` placed
  the cursor for the default template only.
- Specs that failed depending on run order (a modified `bufhidden=wipe`
  buffer in the agenda's other window, temp files deleted under loaded
  buffers).

### Changes to defaults (all to Emacs's)

- Sparse-tree regexp searches ignore case (`occur_case_fold_search`).
- LaTeX fragments are not highlighted unless `highlight_latex_and_related`
  asks for it.
- A short click on a link follows it (`links.mouse_1_follows_link = 450`),
  and so does one on an agenda entry.
- `p`/`P` of a whole subtree fold it (org-yank, `yank_folded_subtrees`);
  other puts are Vim's.
- The Visual selection stays after `M-h`/`M-l`/`M-k`/`M-j` (`edit_keep_region`).
- `C-c C-x C-a` runs `archive_default_command`; the sparse-tree menu's
  `c` cycles the date type (clearing highlights moved to `C`).
- Remote `#+INCLUDE` and `#+SETUPFILE` URLs are fetched only as
  `resource_download_policy` allows ("prompt" by default).
- `columns_ellipses` is `..`.

### What is left

- Partial: `org-calc-default-modes` (Calc's symbolic mode and date format
  can't be set) and `org-babel-lisp-eval-fn` (Common Lisp runs in `sbcl`,
  not SLIME or SLY).
- Emacs-only (24): Gnus, BBDB, MH-E, eww and w3m links and the mail link
  formats; CDLaTeX and RefTeX; speedbar; TRAMP directories for Babel;
  CIDER's Clojure namespace; the calendar following a changed time stamp
  (the date picker is modal); dropping text with org-mouse.
- The measurement counts commands and options. It says that a feature
  exists and behaves like Emacs where it was checked, not that every edge
  case matches.

Validation: the merged branch passes the full suite (3,349 passed, 0
failed; `main` had 2,554), on Neovim 0.13.0-dev. StyLua was not run
over existing files (the local version differs from the repository's);
the files added in this round were formatted with StyLua 2.3.1.
