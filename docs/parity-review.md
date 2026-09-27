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

The following findings from PR #36 remain outside this implementation:

| Gap | Current boundary / next work |
| --- | --- |
| RSS/Atom (`org-feed`) | No ingestion, update-all/inbox commands or feed-status deduplication. This is portable missing functionality. |
| Native export backends | ODT and Texinfo remain Pandoc conversions. Native backend option fixtures, `BIND`/eval macro behavior, and broader async export need separate work. |
| Babel | No emacs-lisp execution; persistent sessions cover shell/fish, Python, JS, Ruby and Lua with per-request semantics. |
| Calc/Lisp | The built-in evaluators implement subsets; symbolic algebra, complex numbers, units and arbitrary Emacs Lisp are not fully implemented. |
| Dates and TODO types | Configurable duration units/full formats and distinct `TYP_TODO` type cycling remain missing. |
| Agenda | Arbitrary diary sexps and PDF/PostScript output remain unsupported. |
| Capture/editor integrations | Indirect buffers/`:unnarrowed`, extended-today capture dates, column overlays, some link previews, attachment Git/annex and MobileOrg remain different or absent. |
| Conformance measurement | A finite regression suite is not a complete feature/option/command inventory. No parity percentage is claimed. |

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
