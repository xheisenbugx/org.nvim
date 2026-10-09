# Emacs parity fixtures

These scripts run Emacs Org 9.8.10 in batch over checked-in inputs and
write its output under `tests/fixtures/emacs/`. The
`tests/spec/emacs_*_parity_spec.lua` specs run org.nvim on the same inputs
and compare. The specs only read the fixtures, so CI needs no Emacs.

```sh
make parity-fixtures                                # every area
make parity-fixtures AREAS="agenda lint"            # some of them
ORG_DIR=~/src/org-mode/lisp make parity-fixtures    # Org first on the load-path
EMACS=/path/to/emacs make parity-fixtures
```

`generate.sh` refuses to run unless `(org-version)` is 9.8.10. Emacs
bundles an older Org, so you usually need `ORG_DIR`.

## Areas

| Area | Generator | Inputs | Output |
| --- | --- | --- | --- |
| visibility | `visibility.el` | `visibility/*.org`, `visibility/cases.txt` (file + TAB/S-TAB sequence) | `visibility/expected.txt`: `v`/`h` + each line |
| agenda | `agenda.el` | `agenda/work.org`, `agenda/home.org`, `agenda/cases.txt` (day/week agenda, TODO list, tags match, search) | `agenda/expected.txt`: the view's text at width 80 |
| export | `export.el` | `examples/*.org` listed in `export/cases.txt`, with their backends | `export/<name>.{txt,html,tex,md}`: body-only, Babel off |
| clocktable | `clocktable.el` | `clocktable/{a,b,c}.org`, `clocktable/tables.org` | `clocktable/tables.expected.org`: every block updated |
| lint | `lint.el` | `examples/*.org`, `lint/*.org` | `lint/expected.txt`: `line:col [checker] message` |

Each output file is split into `=== <case>` sections (or files), and each
section is one test.

## Determinism

`common.el` is loaded before every generator. It sets up:

- **Time.** "Now" is frozen at 2026-10-01 Thu 12:00 by advising
  `current-time`, `org-today`, `time-since` and the time functions that
  take a nil time. The specs do the same with `os.time`/`os.date`
  (`P.freeze_time()` in `tests/emacs_parity.lua`).
- **Zone and locale.** `generate.sh` runs Emacs with `TZ=UTC0` and
  `LC_ALL=C`, and the specs use `TZ=UTC0` too.
- **A graphical Emacs's defaults.** Defaults that depend on the display
  (the agenda time grid's `┄`, curved quotes in help strings) take the
  values a graphical Emacs uses, not the ASCII fallbacks of a batch
  terminal.
- **A configured Emacs.** `org-inlinetask` is loaded, and for lint every
  `ob-*` library is loaded, so language-specific header arguments are
  known.
- **Stable ids and paths.** Export reseeds `random` before each file, and
  the specs rename generated `orgXXXXXXX` ids by order of appearance
  anyway. Absolute paths become `@ROOT@/` (export) or `@DIR@/`
  (clocktable links) on both sides.

## When a comparison fails

1. Check what Emacs does (the Org source) and fix org.nvim.
2. If the difference is intentional, document it under
   `:h org-differences` and add a rule to `NORMALISE` in
   `tests/emacs_parity.lua`. That table is the only place outputs are
   rewritten, so keep every rule commented with its reason.
3. If it's a real bug you can't fix now, add the case to the spec's
   `KNOWN` table with the reason. Known cases show as skipped, and the
   spec fails once one of them starts matching, so the entry gets
   removed.

Never edit an expected file by hand. Change the inputs or the generator,
then run `make parity-fixtures` again.

## Adding cases

- visibility, agenda: add a line to the area's `cases.txt` (and an input
  file if you need one).
- export: add a file and its backends to `export/cases.txt`. Keep the
  fixtures small: the whole `tests/fixtures/emacs` tree is about 1.4 MB.
- clocktable: add a block to `tables.org`.
- lint: add a `.org` file to `lint/`.

Then regenerate the fixtures and run
`make test SPEC=tests/spec/emacs_<area>_parity_spec.lua`.

## Differential testing on generated documents

`difftest.el` is the Emacs side of `make difftest` (CONTRIBUTING.md,
"Differential testing"): instead of writing fixtures, it keeps running and
answers requests from `tests/difftest/emacs.lua` on stdin, one per line
(`<oracle> TAB <input.org> TAB <output file>`), with `common.el`'s fixed
"now", zone and locale. The org.nvim side of each oracle is in
`tests/difftest/oracles.lua`; keep the two in step.

```sh
ORG_EMACS=emacs ORG_LISP_DIR=/path/to/org-9.8.10 make difftest SEED=1 COUNT=300
```

`ORG_EMACS` and `ORG_LISP_DIR` default to `EMACS` and `ORG_DIR`. Org
9.8.10 is on GNU ELPA as `https://elpa.gnu.org/packages/org-9.8.10.tar`
(the Difftest workflow fetches and byte-compiles it); a `git clone` of the
`release_9.8.10` tag works too after `make autoloads`, which writes
`org-version.el`.
