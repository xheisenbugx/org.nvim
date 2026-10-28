# Feature map

One file per area: how a user reaches the feature, how to drive it with
the verify driver (`scripts/verify/drive.lua`), what success looks like,
and what can mislead a check. Each file starts with a header that
`tests/spec/verify_spec.lua` checks against the code, so a renamed key,
module, spec or help tag fails the suite instead of leaving the map wrong:

| Field | What it lists | Checked against |
| --- | --- | --- |
| `area` | the file's name | the file name |
| `recipe` | the driver recipe | `scripts/verify/recipes/<area>.lua` exists and passes |
| `keys` | `section.name` of the keys a user drives it with | `mappings` in `lua/org/config/mappings.lua`, the actions, and the keys and actions of the extensions |
| `modules` | where the code is | the paths exist |
| `specs` | the specs that pin it | the files exist |
| `doc` | help tags | `*tag*` in `doc/org.txt` |
| `emacs` | the Org source files to compare with | (not checked: Org isn't in the repo) |

| Area | Covers |
| --- | --- |
| [agenda](agenda.md) | the dispatcher, the week agenda, editing entries from it, moving in time |
| [clock](clock.md) | clocking in and out, the CLOCK line, the statusline clock, clock display and clock report |
| [capture](capture.md) | templates, the capture buffer, finalize / kill, targets |
| [columns](columns.md) | column view over the headlines, summaries, editing values |
| [dates](dates.md) | the calendar, inserting timestamps and ranges, scheduling, shifting dates with `S-arrows` |
| [extensions](extensions.md) | enabling an extension in a scenario; the kanban board, the journal, presentations |
| [folding](folding.md) | `Tab` / `S-Tab` cycling, startup visibility, folds after edits |
| [links](links.md) | following heading and file links, storing and inserting links, creating a missing heading |
| [lists](lists.md) | new items, checkboxes and `[n/m]` cookies, numbering and bullets |
| [refile](refile.md) | refile and copy through the target picker, archive file, ARCHIVE tag, Archive sibling |
| [tables](tables.md) | typing and realigning, rows / columns / hlines, `#+TBLFM` formulas |

Areas not mapped yet: babel, export. To add one, write `<area>.md` with
the header above and `scripts/verify/recipes/<area>.lua` with its
scenarios, and add a row here.
