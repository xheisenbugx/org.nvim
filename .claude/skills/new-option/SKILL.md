---
name: new-option
description: Checklist for adding, renaming or changing the default of an org.nvim setup() option, and for an action or default key that comes with it. Use whenever a change adds a key under lua/org/config/, touches lua/org/_meta/, or adds an entry to lua/org/actions.lua or a default key in lua/org/config/mappings.lua. Covers the default, the :h org-config entry, the LuaLS type, :checkhealth, migration, specs, the false-return contract, key conflicts and api.version.
---

# new-option

An option lives in five places, and specs check that they agree. Do
every step; `tests/spec/consistency_spec.lua` and
`tests/spec/health_spec.lua` fail on most of the misses.

## 1. The default

In the file of its area in `lua/org/config/` (`agenda.lua`,
`capture.lua`, `ui.lua`, ...; the list is `M.parts` in
`lua/org/config/init.lua`). Don't make a new file unless it's a new area;
a new file goes in `M.parts` too.

- Put a `---` comment right above the key: what it does, the values it
  takes, and the Emacs variable in parentheses
  (`(org-capture-use-agenda-date)`). `:Org customize` shows that comment.
- Follow Emacs Org 9.8's default unless there is a reason; the reason is
  an entry under `:h org-differences`.
- A new top-level table of sub-options (`capture = { ... }`) also goes
  in `SECTIONS` in `lua/org/config/init.lua`, so `setup()` refuses a
  scalar there with a clear error.
- Code reads the option at call time, `require("org.config").opts.x.y`,
  never a copy taken at load: `setup()` replaces the table's contents.

## 2. The type

A `---@field name? type` in `lua/org/_meta/`, in the class of its
section (`org.Config`, `org.Config.UI`, ...; `grep -n "@class"
lua/org/_meta/*.lua`). The doc line above it ends with the real
default: `(default: \`false\`)`.

- `consistency_spec` fails when an option has no field, or when the
  `(default: ...)` disagrees with the code.
- `:checkhealth org` reports an option without a field as unknown
  (`M.unknown_options` in `lua/org/health/init.lua` reads `_meta`).
- An extension's options go in its own `_meta/<name>.lua`.

## 3. The doc

An entry in `doc/org.txt` under `:h org-config` (chapter "CONFIGURATION
REFERENCE"), in its section's list: `name default (|tag|)`, as the
neighbours do. Describe the behaviour in the feature's own chapter too,
with a `*tag*` if other text links to it. Options most setups change
also go in `*org-config-recommended*`. Then:

```sh
nvim --headless -u NONE -c "helptags doc" -c q
```

`|tag|` links must name a tag that exists (`consistency_spec` checks).
A headline feature also goes in `README.md` and `docs/guide.md`.

## 4. Health check

If the option names a program, a path or a state file, add a check in
`lua/org/health/init.lua` (an extension: its `health(h, opts)`). Fast
(`vim.fn.executable()`, no running programs, no network), no prompts or
notifications, a warning only when the option turns the feature on, the
advice ending in `see :h <tag>`. A spec in `tests/spec/health_spec.lua`,
and a line under `:h org-health` (CONTRIBUTING.md, "Health checks").

## 5. Renaming or removing

There is no alias table for old names: after a rename, the old name is
reported as unknown by `:checkhealth org` and ignored. So:

- Prefer adding the new name and keeping the old one working, read as a
  fallback where the option is used.
- If an nvim-orgmode option maps onto it, update `lua/org/migrate.lua`
  (`:Org migrate_config`) and `tests/spec/migrate_spec.lua`.
- A removed or renamed option, or a changed default that changes
  behaviour, is breaking: `feat!:` or a `BREAKING CHANGE:` footer
  (a major release). For an extension, name it in the footer.

## 6. Spec

At least one spec using `with_config({ ... })` that shows the option
changing the behaviour, and one for the default. For an Emacs variable,
the expected result comes from Emacs (the `emacs-parity` skill).

## 7. An action that comes with it (optional)

- Register it in `lua/org/actions.lua`, in its `group`: `{ module,
  function, desc = ... }`, with `modes`, `global`, `repeatable` as the
  neighbours use them.
- Add its name to the `org.ActionName` alias in
  `lua/org/_meta/mappings.lua` (`consistency_spec` checks).
- The function returns `false` only when it doesn't apply here; the key
  then falls back to Vim's own. Never return `false` after changing the
  buffer.
- A default key goes in `lua/org/config/mappings.lua` (bound by
  `lua/org/mappings.lua`). Before picking one, check it isn't taken and
  isn't a prefix of another key or the other way round:
  `make test SPEC=tests/spec/consistency_spec.lua`. Document the key in
  `doc/org.txt`.
- If a tutor lesson or a verify recipe uses the key, it's referenced as
  `{{section.name}}` and follows on its own; a renamed action breaks
  them, so grep `tutor/`, `scripts/playground/lessons/`,
  `scripts/verify/recipes/` and `.claude/skills/verify-org/features/`.

## 8. The public API

If the option or action shows up in `org.api` (`lua/org/api/`): a new
function, field or event payload raises the minor part of `M.version` in
`lua/org/api/init.lua`, and the doc says `Since API x.y.` Nothing is
removed or changed within a major version (`:h org-api-version`).

## 9. Check

```sh
make test SPEC="tests/spec/consistency_spec.lua tests/spec/health_spec.lua tests/spec/customize_spec.lua"
make format && make lint && make typecheck && make test
```
