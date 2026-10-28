---
name: verify-org
description: Verify an org.nvim change in a running Neovim the way a user drives it (keys typed, screen read, files on disk checked), using the feature map in features/ and the recipes in scripts/verify/recipes/. Use after any user-visible change to the agenda, capture or folding (and any area with a feature file), before opening a PR, and whenever asked to verify, smoke test or "check it works".
---

# verify-org

Specs run headless with prompts stubbed, so a change can pass every spec
while what a user sees is broken. This skill checks the real thing: a
child Neovim with an 80x24 screen, keys typed into it, the screen and the
files on disk compared with what should happen. "Specs pass" or "it
loads" is not verification.

## 1. Find the area

Read `features/README.md`, then the area's file (`features/<area>.md`):
how a user reaches the feature, the steps with what each should show,
and the gotchas that make a check pass or fail for the wrong reason. Its
header names the recipe, the modules, the specs, the help tags and the
Emacs source to compare with.

No feature file for the area: verify by hand (section 5), and say in
your report that the area isn't mapped.

## 2. Run what exists

```sh
make verify RECIPE=agenda                 # one recipe
make verify RECIPE="agenda capture"       # several
make verify RECIPE=agenda:week            # one scenario, by the start of its name (no spaces)
make verify                               # every recipe
```

Each scenario runs in its own Neovim with HOME and XDG in a scratch
directory, the clock fixed at Monday 2026-10-12 09:00. The output names
the evidence directory: a screen dump per step (`NN-<step>.txt`, the
buffer, cursor and mode above it) and `report.md`. A failing scenario
keeps its scratch directory and says where.

Read the screens of the steps your change touches, not only PASS: a
scenario can pass while the screen shows something else wrong (an error
in the message area, a misaligned line).

## 3. Add a scenario for your change

In `scripts/verify/recipes/<area>.lua` (the step format is at the top of
`scripts/verify/drive.lua`):

- Drive it as a user does: keys through `{{section.name}}` placeholders
  (`{{org.cycle}}`, `{{agenda.todo}}`), so a changed default key doesn't
  break the recipe.
- Check the outcome and its side effects. A TODO marked done in the
  agenda: the agenda line, then the file on disk after saving. A capture:
  the window gone, then the target file's exact lines.
- For a bug: run the scenario on the code before your fix and see it
  fail. A scenario that never failed proves nothing.
- Never weaken an expectation to get a pass. If the expectation was
  wrong, say what Emacs does (the Org source named in the header) and
  fix it to that.
- `tests/spec/verify_spec.lua` runs every recipe in `make test`, so the
  scenario keeps guarding the change.

## 4. Report

Say what you ran, which scenarios passed, the evidence directory, and
what you didn't check (a terminal-only behaviour, another area your
change touches, an option combination). An inconclusive check counts as
a failure, not a pass.

## 5. What the driver can't do

The driver talks to Neovim over RPC, without a terminal: no image
protocols (kitty graphics), no terminal key encodings, no mouse
selections, no real timing. For those, drive a real terminal in tmux
with a scratch home:

```sh
d=$(mktemp -d); mkdir -p "$d"/{data,state,cache,config}
tmux new-session -d -s verify -x 80 -y 24 \
  "HOME=$d XDG_DATA_HOME=$d/data XDG_STATE_HOME=$d/state XDG_CACHE_HOME=$d/cache XDG_CONFIG_HOME=$d/config \
   nvim --clean --cmd 'set rtp^=$PWD' --cmd 'let mapleader=\" \"' \
   -c 'lua require(\"org\").setup({ org_directory = \"$d\", default_notes_file = \"$d/notes.org\", agenda_files = { \"$d/test.org\" } })' \
   $d/test.org"
tmux send-keys -t verify ' oa'                 # keys as typed (BTab for S-Tab)
tmux capture-pane -p -t verify                 # the screen as text
tmux kill-session -t verify; rm -rf "$d"
```

Leave a second between `send-keys` and `capture-pane` (startup, the
agenda build), and say in the report that the dates are today's: tmux
runs on the real clock.

Never point a check at the real `~/org`, `~/.notes` or the real data
directory. For a PR's GIF, record the same steps with vhs
(`docs/media/tapes/`).

## 6. Keep the map true

When you change an area, update its feature file in the same change:
a key, a step's expected result, a new gotcha you hit. The header is
checked by `tests/spec/verify_spec.lua` (keys, modules, specs and help
tags must exist). To map a new area, follow `features/README.md`.
