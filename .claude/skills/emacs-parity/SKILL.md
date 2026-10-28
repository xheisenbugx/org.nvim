---
name: emacs-parity
description: Check org.nvim's behaviour against Emacs Org 9.8 (the pinned release) and pin it in a spec. Use when a bug report or change says "Emacs does X", when writing or changing a *_emacs_spec.lua / *_parity_spec.lua, when a parity spec, make difftest or make parity-fixtures fails, and whenever you would otherwise guess how Org behaves. Covers finding the Emacs function, reading the source and manual, NORMALISE vs KNOWN vs known.lua, :h org-differences and docs/parity-review.md.
---

# emacs-parity

org.nvim aims to behave like Emacs Org 9.8: the pinned release is what
`scripts/emacs-parity/release-watch.sh pinned` prints (also `ORG_VERSION`
in `lua/org/health/init.lua`). Check what Emacs does; never guess, and
never change an Emacs spec's expectation to make a test pass.

## 1. Get the Org source

The Org source isn't in the repo. In order:

1. `$ORG_LISP_DIR` or `$ORG_DIR`, if set: the Lisp directory of an Org
   release (`org.el`, `org-agenda.el`, `ox-*.el`, `ob-*.el`). Its
   `org-version.el` names the release.
2. Fetch the pinned one:
   ```sh
   v=$(scripts/emacs-parity/release-watch.sh pinned)
   scripts/emacs-parity/release-watch.sh fetch "$v" ~/org-lisp   # ~/org-lisp/org-$v
   ```
   It needs `curl` and `git`.
3. If neither works, ask for the path. Don't fall back to memory of
   Org's code.

The manual is the Org manual (`doc/org-manual.org` in an org-mode git
checkout, or the Info manual). Emacs's own bundled Org is older than the
pinned release: `emacs -Q --batch` needs `-L <lisp dir>`, and
`(org-version)` should print the pinned version.

## 2. Find the function behind the feature

- Start from the key or command: `doc/org.txt` and the action's `desc`
  in `lua/org/actions.lua` often name the Emacs command
  (`org-capture`, `org-cycle`). For a mapped area, the `emacs` field of
  `.claude/skills/verify-org/features/<area>.md` lists the files.
- `grep -n "(defun org-<name>" <lisp dir>/*.el`, then follow the calls.
  Options are `defcustom`s; `docs/parity/inventory.tsv` lists every
  command and option with its status in org.nvim.
- Read the docstring, the manual section, and the code. Edge cases live
  in the code: blank lines, the end of the buffer, inline tasks,
  `org-odd-levels-only`, a narrowed buffer.

## 3. Compare behaviour

Run Emacs when the code doesn't settle it:

```sh
emacs -Q --batch -L "$ORG_LISP_DIR" --eval '(progn (require (quote org)) ...)'
```

Write the same input to a scratch file, run the command in both, and
compare the buffer (or the export, the agenda text) line by line.

## 4. Pin it in a spec

- Hand-written cases go in the area's `tests/spec/<area>_emacs_spec.lua`
  (or `*_parity_spec.lua`). A comment says which Emacs function the
  expected lines come from, and that they are Emacs's output
  (`tests/spec/tag_order_emacs_spec.lua` is a short example).
- Comparisons against real Emacs output use the fixtures under
  `tests/fixtures/emacs/`, read by `tests/spec/emacs_*_parity_spec.lua`
  (visibility, agenda, export, clocktable, lint, faces). To add a case,
  change the inputs (`scripts/emacs-parity/README.md`, "Adding cases")
  and regenerate:
  ```sh
  ORG_DIR=/path/to/org-<v> make parity-fixtures AREAS="agenda"
  git diff tests/fixtures/emacs
  ```
  Never edit the fixtures by hand (a Claude Code hook refuses it).
- Random documents against Emacs: `make difftest` (needs `ORG_EMACS` and
  `ORG_LISP_DIR`). Replay one failure with `make difftest SEED=N COUNT=1
  ORACLES=<oracle>`; the minimal input in `difftest-out/report.md`
  becomes a case of the area's `*_emacs_spec.lua`.

## 5. When org.nvim and Emacs differ

Pick one. Each has one place:

| Case | Do |
| --- | --- |
| a bug you fix now | fix it (the `fix-bug` skill); the spec pins Emacs's result |
| an intended difference | document it under `:h org-differences` in `doc/org.txt`; if a parity spec compares it, add a commented rule to `NORMALISE` in `tests/emacs_parity.lua` (the only place outputs are rewritten) |
| a bug you can't fix now, in a fixture comparison | add the case to that spec's `KNOWN` table with the reason; it fails once it matches, so the entry gets removed |
| a bug you can't fix now, found by difftest | a narrow entry in `tests/difftest/known.lua` with the reason |

Never add a `NORMALISE` rule to hide a bug. A difference Neovim forces
(no indirect buffers, no per-line wrap prefix) is an intended one, and
needs the doc entry.

## 6. Record the review

A larger review of an area (many commands, a whole option group) gets a
section in `docs/parity-review.md`, like the ones there: what was
compared, what was fixed, what stays different and why. New or changed
commands and options get their status in `docs/parity/inventory.tsv`.
