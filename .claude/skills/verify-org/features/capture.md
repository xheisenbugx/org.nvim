---
area: capture
recipe: scripts/verify/recipes/capture.lua
keys: global.capture, capture.finalize, capture.kill, capture.refile, org.capture
modules: lua/org/capture.lua, lua/org/capture
specs: tests/spec/capture_spec.lua, tests/spec/capture_hooks_spec.lua, tests/spec/capture_visual_spec.lua
doc: org-capture, org-capture-templates, org-capture-expansions, org-capture-hooks
emacs: org-capture.el
---

# Capture

Note something down from anywhere with a template and file it where it
belongs, without leaving what you were doing (org-capture).

## How to get to it

`{{global.capture}}` (`<leader>oc`) opens the template menu: a key per
template in `capture.templates`, letters typed as they show. The template
opens in a capture window, in Insert mode where `%?` is.

## Driving it

| Step | Expected |
| --- | --- |
| `{{global.capture}}` | the menu with each template's description |
| `t` (a template's key) | a capture buffer with the template expanded, Insert mode |
| type the entry | the text in the capture buffer |
| `{{capture.finalize}}` | the window closes; the entry is in the target file on disk |
| `{{capture.kill}}` | the window closes; the target file is unchanged |
| `{{capture.refile}}` | asks for a refile target (stub the picker in a recipe) |

## Gotchas

- `capture.templates` replaces the default. With no templates the Emacs
  fallback "Task" files under "Tasks" in `default_notes_file`; the driver
  points that at the scenario's `notes.org`, never `~/.notes`.
- Give targets as `"{{dir}}/inbox.org"`; a relative target is relative to
  `org_directory`.
- Keys starting with Ctrl (`<C-c><C-c>`, `<C-c><C-k>`) work in Insert
  mode too, and wait for their second key past 'timeoutlen' (the
  prefix is mapped on its own); `<leader>ow` / `<leader>ok` are
  Normal-mode keys only.
- `%U` / `%u` / `%t` use the driver's clock: `[2026-10-12 Mon 09:00]`.
- A `headline` target puts the entry one level under that headline, at
  the end of its subtree; a `datetree` target makes the year / month /
  day headlines first.
- Finalizing saves the target file: check it with `expect.file`, which
  reads the disk, not the buffer.
- Templates that prompt (`%^{Prompt}`, `%^g`) open an input line; type the
  answer and `<CR>` as separate steps.
