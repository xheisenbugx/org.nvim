---
area: folding
recipe: scripts/verify/recipes/folding.lua
keys: org.cycle, org.global_cycle, org.show_everything, org.insert_heading
modules: lua/org/fold.lua, lua/org/fold
specs: tests/spec/fold_spec.lua, tests/spec/visibility_spec.lua, tests/spec/ui_folding_visibility_spec.lua, tests/spec/emacs_visibility_parity_spec.lua
doc: org-folding, org-fold-display, org-cycle-level
emacs: org-cycle.el, org-fold.el, org-fold-core.el
---

# Folding and visibility

Hide and show parts of the outline: `Tab` on a heading cycles its subtree,
`S-Tab` the whole buffer, and the file opens as `#+STARTUP:` or
`startup_folded` says (org-cycle, org-global-cycle).

## How to get to it

Open an org file. `{{org.cycle}}` (`Tab`) on a heading, `{{org.global_cycle}}`
(`S-Tab`) anywhere. `startup_folded` (or `#+STARTUP: overview` in the file)
sets what a file shows when it opens.

## Driving it

| Step | Expected |
| --- | --- |
| open with `startup_folded = "overview"` | only the top-level headings |
| `{{org.cycle}}` on a folded heading | its children's headings, no body text |
| `{{org.cycle}}` again | the whole subtree |
| `{{org.cycle}}` again | folded |
| `{{org.global_cycle}}` | overview → contents (every heading) → show all |
| a heading inserted in a folded tree | stays visible, the tree stays folded |

## Gotchas

- Check the screen, not `foldclosed()`: a fold can be closed while the
  window still shows stale lines, and the other way round.
- Expression folds can go stale away from an edit (a Neovim bug worked
  around in `lua/org/fold.lua`'s flush): after an edit, check lines away
  from it too, not only the edited heading.
- `{{org.cycle}}` off a heading isn't org's: it returns "not applicable"
  and `Tab` does what Vim does. A scenario has to put the cursor on the
  heading (`at`) first.
- `startup_folded` defaults to `"showeverything"`, so a scenario that
  starts folded sets it.
- In a real terminal `S-Tab` arrives as `<S-Tab>` only if the terminal
  sends it (tmux: `send-keys BTab`); the driver sends it straight to
  Neovim.
