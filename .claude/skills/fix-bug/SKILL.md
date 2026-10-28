---
name: fix-bug
description: The loop for fixing an org.nvim bug, from a failing spec to the pull request. Use when asked to fix a bug, an issue, a regression, a fuzz or difftest failure, or "something org.nvim does wrong", before touching the code. Covers the failing spec first, checking Emacs, screen snapshots for rendering bugs, fuzz regressions, verify-org scenarios, lint / typecheck / the full suite, :h org-differences, the branch name and the PR description with GIF evidence.
---

# fix-bug

A fix isn't done when the code changes. It is done when a spec failed
before it and passes after, Emacs agrees (or the doc says why not), and
the pull request shows it. Work through the steps in order.

## 1. Branch

Branch from `dev`, never `main`. The name follows Conventional Commits,
as in the history: `fix/<area>-<what>` (`fix/capture-prompt-after-tags`).
The commit and PR title: `fix(<area>): <what now works>`. One bug per
branch.

## 2. Reproduce it with a failing spec

Write the spec before the fix, run it, and see it fail for the reason
the bug report gives. A spec that never failed proves nothing.

- Put it in the area's spec file in `tests/spec/` (`agenda_spec.lua`,
  `lists_spec.lua`, ...). `ls tests/spec | grep <area>` finds it.
- When the expected result is what Emacs does, put it in the area's
  `*_emacs_spec.lua` or `*_parity_spec.lua` (`lists_emacs_spec.lua`,
  `structure_parity_spec.lua`). Say in a comment which Emacs function the
  expectation comes from. Never change an existing expectation in those
  files to make your spec pass, unless Emacs really does something else
  (check it, step 3).
- Use the harness globals: `org_buffer(lines, cursor)`, `buf_lines(buf)`,
  `eq`, `ok`, `with_config(overrides)` (AGENTS.md, "Tests").
- Stub anything that prompts (`vim.fn.input`, `vim.ui.select`, confirms),
  or the run hangs.
- Don't set 'lines' or 'columns' in a spec.

```sh
make test SPEC=tests/spec/<area>_spec.lua
```

## 3. Check what Emacs does

The goal is Emacs Org 9.8 behaviour. Don't guess: read the Org source
and manual for the command (the `emacs-parity` skill says how to find
them). If org.nvim is right and the report expects something else, say
so instead of "fixing" it.

## 4. Fix it

- Use `org.parser` and `org.files` for headlines, planning, properties,
  clocks and timestamps, not text matching by hand.
- Keep the action contract: an action returns `false` only when it
  didn't apply, never after it changed the buffer.
- Saving goes through `utils.save_buffer`; logic around every write is a
  hook in `lua/org/write_hooks.lua`.
- In a hot path (the decoration provider, `foldexpr`, the list item
  parser, native image placement, the parser cache) don't add work per
  line or per frame. Run `make test SPEC=tests/spec/perf_budgets_spec.lua`.

## 5. Add what the area needs

- **Rendering bug** (highlighting, conceal, folds, extmarks, the agenda
  buffer): a case in `tests/spec/screen_snapshot_spec.lua` (format in
  CONTRIBUTING.md, "Screen snapshots"). Create or update the golden
  file with `make snapshots`, then read `git diff tests/fixtures/screen`.
  Never edit a golden file by hand, and don't rewrite one just to make a
  failing spec pass.
- **Found by fuzzing**: replay the seed (`ORG_FUZZ_SEED=N make test
  SPEC=tests/spec/fuzz_<x>_spec.lua`), copy the minimal input into a new
  `it` of `tests/spec/fuzz_regressions_spec.lua`, see it fail, then fix
  (CONTRIBUTING.md, "Fuzzing").
- **Found by difftest**: turn the minimal input into a case of the area's
  `*_emacs_spec.lua`; drop its entry from `tests/difftest/known.lua` if
  it had one.
- **The area is mapped** (`.claude/skills/verify-org/features/README.md`
  lists agenda, capture, folding): add a scenario to
  `scripts/verify/recipes/<area>.lua`, see it fail on the old code, and
  run `make verify RECIPE=<area>`. Follow the `verify-org` skill.
- **Intentional difference from Emacs**: document it under
  `:h org-differences` in `doc/org.txt`. If a parity spec compares the
  output, the rewrite goes in `NORMALISE` in `tests/emacs_parity.lua`.
- **User-visible change**: say it in `doc/org.txt`. After editing it, run
  `nvim --headless -u NONE -c "helptags doc" -c q`.

## 6. Check everything

```sh
make format
make lint                 # stylua --check, then scripts/lint_sources.lua
make typecheck            # needs lua-language-server
make test                 # the full suite, not only your spec
```

Fix a typecheck warning (usually a wrong `---@param` or a missing nil
check) instead of silencing it. Never take a path off
`scripts/typecheck_strict.txt`. A failing spec you didn't touch: check
`tests/quarantine.lua` and CI history before you blame your change.

## 7. Pull request

Open it against `dev`. The description has:

- **In plain words**: a few sentences for someone who doesn't code: what
  was wrong, what changes for them, what they need to do (often nothing).
  No code, file names or jargon.
- What changed and why, with the Emacs function you compared with.
- **How it was tested**: the specs added, the snapshot, the verify
  scenario, and that lint, typecheck and the full suite pass.
- **GIF evidence**, before and after. Record with vhs: a tape that
  starts with `Source docs/media/tapes/common.tape` (see
  `docs/media/tapes/*.tape` and `docs/media/README.md`). Record "before"
  from a `git worktree` of `origin/dev`, "after" from your branch. Open
  the PR first to get its number, commit the GIFs to the `media` branch
  under `pr/<N>/`, and link them by raw URL:
  `https://raw.githubusercontent.com/xheisenbugx/org.nvim/media/pr/<N>/<name>.gif`.

End the description with the attribution line the session gives.
