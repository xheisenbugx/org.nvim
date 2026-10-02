
# Table of Contents

1.  [How to use these files](#org4875214)
2.  [The files](#org1a9b2bc)
    1.  [Writing and structure](#orgafc9f12)
    2.  [Tasks](#org7ce5a9a)
    3.  [Finding things](#orgb4ec9e4)
    4.  [Collecting and organising](#org215ba45)
    5.  [Tables and code](#orge87d85b)
    6.  [Publishing and display](#org99371d7)
    7.  [Everything else](#org1183b91)



<a id="org4875214"></a>

# How to use these files

Each file in this directory covers one feature area of org.nvim in depth.
They are meant to be **worked through**, not just read: every section explains
a feature, shows several examples, and ends with exercises.

-   Lines starting with **Try:** are exercises, with the exact keys to press.
-   Lines starting with **Expect:** say what you should see afterwards, so you can
    check that the feature works.
-   Lines starting with `#` are Org comments that annotate the example next to
    them. They are dimmed, and they are never exported.
-   Keys use `<prefix>` for the org.nvim prefix, `<leader>o` by default.
    Press `g?` in any org buffer to list the keys of that buffer.
-   Nothing breaks if you make a mess: `u` undoes, and
    `git checkout examples/` restores every file.

Start Neovim from the repository root with the bundled init file, so the
examples use a known configuration and your own notes are never touched:

    nvim -u examples/minimal_init.lua examples/00-index.org

It points `agenda_files` at the files of this directory and sends captures to
a scratch directory under `stdpath("state")`. Put the cursor on a link below
and press `<CR>` to open that file. `<C-o>` brings you back here.

The examples use dates around late September 2026. When they are in the
past, press `<C-a>` on the day of a timestamp to move it forward.

If you would rather take a quick tour of everything in one file first, start
with [tutorial.org](tutorial.md).


<a id="org1a9b2bc"></a>

# The files


<a id="orgafc9f12"></a>

## Writing and structure

-   [01 Outline](01-outline.md): headlines, folding, motions, moving and sorting subtrees,
    narrowing.
-   [02 Markup](02-markup.md): emphasis, blocks, comments, entities, sub- and
    superscripts.
-   [03 Lists](03-lists.md): plain lists, bullets, counters, checkboxes and progress
    cookies.


<a id="org7ce5a9a"></a>

## Tasks

-   [04 TODO items](04-todo.md): keywords, logging, repeaters, habits, dependencies,
    priorities.
-   [05 Tags](05-tags.md): fast selection, groups, inheritance, file tags.
-   [06 Properties and column view](06-properties-columns.md): drawers, allowed values, inheritance,
    column summaries.
-   [07 Dates and times](07-dates.md): timestamps, SCHEDULED and DEADLINE, the calendar,
    date input.
-   [08 Clocking](08-clocking.md): clocking in and out, effort estimates, clock tables.
-   [20 Timers and reminders](20-timers-reminders.md): relative and countdown timers, appointment
    notifications.


<a id="orgb4ec9e4"></a>

## Finding things

-   [09 Agenda](09-agenda.md): day and week views, the TODO list, matches, custom commands,
    bulk actions.
-   [10 Sparse trees](10-sparse-trees.md): folding a file down to matches, and the match syntax.


<a id="org215ba45"></a>

## Collecting and organising

-   [11 Capture](11-capture.md): templates, expansions, targets.
-   [12 Refile and archive](12-refile-archive.md): moving subtrees around and out of the way.
-   [13 Links](13-links.md): every link type, IDs, radio targets, attachments.
-   [14 Footnotes](14-footnotes.md): inserting, jumping, renumbering.


<a id="orge87d85b"></a>

## Tables and code

-   [15 Tables](15-tables.md): creating, aligning, editing, moving, sorting, importing.
-   [16 Spreadsheet](16-spreadsheet.md): `#+TBLFM` formulas, references, functions, formats,
    worked sheets.
-   [17 Babel](17-babel.md): running source blocks, results, variables, noweb, tangling.
-   [18 Dynamic blocks](18-dynamic-blocks.md): clock tables, column view blocks, custom blocks.


<a id="org99371d7"></a>

## Publishing and display

-   [19 Export](19-export.md): the dispatcher, back-ends, export settings.
-   [21 Images and LaTeX](21-images-latex.md): inline image and LaTeX previews.


<a id="org1183b91"></a>

## Everything else

-   [22 Extras](22-extras.md): completion, org-lint, speed keys, inline tasks, encryption,
    commands and health checks.

