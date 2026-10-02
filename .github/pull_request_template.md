<!-- Pull requests go to dev. Title in Conventional Commits style: fix(agenda): …, feat(capture): …, docs: … -->

## What and why

<!-- What this changes, and the issue it fixes (Fixes #123) -->

## In plain words

<!-- For someone who doesn't code: what was wrong or missing, what changes
for them, and whether they need to do anything. No code or jargon. -->

## How it was tested

<!-- The specs you added or ran, and anything checked by hand -->

## Checklist

- [ ] Branched from and targeting `dev`
- [ ] Added or updated a spec in `tests/spec/`
- [ ] `make test` passes
- [ ] `make lint` passes (`make format` fixes it)
- [ ] Checked what Emacs Org 9.8 does, or noted the difference under `:h org-differences`
- [ ] User-visible changes documented in `doc/org.txt` (new options also in `config.lua` and `lua/org/_meta/`)
